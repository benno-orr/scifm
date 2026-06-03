import Foundation
import UIKit
import PDFKit
import NaturalLanguage

actor ArticleProcessor {

    // MARK: - Public

    func process(url: URL) async throws -> ProcessedArticle {
        // Try full-text pipeline first
        if let doi = try? await extractDOI(from: url),
           let article = try? await fetchAndClean(doi: doi) {
            return article
        }
        // Fallback: PubMed abstract (always available for any PMID)
        let urlString = url.absoluteString
        if urlString.contains("pubmed.ncbi.nlm.nih.gov"),
           let pmid = extractPMID(from: urlString),
           let article = await fetchAbstractFromPMID(pmid) {
            return article
        }
        throw ArticleError.fetchFailure
    }

    private func fetchAbstractFromPMID(_ pmid: String) async -> ProcessedArticle? {
        let urlStr = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=pubmed&id=\(pmid)&rettype=xml&retmode=xml"
        guard let url = URL(string: urlStr),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let xml = String(data: data, encoding: .utf8)
        else { return nil }

        guard let title = extractXMLContent(tag: "ArticleTitle", from: xml) else { return nil }

        let abstractPattern = #"<AbstractText(?:[^>]*)>([\s\S]*?)</AbstractText>"#
        var abstractParts: [String] = []
        if let regex = try? NSRegularExpression(pattern: abstractPattern) {
            let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
            abstractParts = matches.compactMap { match in
                guard let r = Range(match.range(at: 1), in: xml) else { return nil }
                return String(xml[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let abstract = abstractParts.joined(separator: " ")
        guard !abstract.isEmpty else { return nil }

        return ProcessedArticle(title: title, authors: [], abstract: await cleanText(abstract), bodyText: "")
    }

    private func extractXMLContent(tag: String, from xml: String) -> String? {
        let pattern = "<\(tag)(?:[^>]*)>([\\s\\S]*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml)
        else { return nil }
        return String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fetches the page at `url` and returns the og:image or twitter:image URL if present.
    func extractFeaturedImage(from url: URL) async -> URL? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }
        let patterns = [
            #"<meta[^>]+property="og:image"[^>]+content="([^"]+)""#,
            #"<meta[^>]+content="([^"]+)"[^>]+property="og:image""#,
            #"<meta[^>]+name="twitter:image"[^>]+content="([^"]+)""#,
            #"<meta[^>]+content="([^"]+)"[^>]+name="twitter:image""#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html)
            else { continue }
            let raw = String(html[range])
            if let imgURL = URL(string: raw) { return imgURL }
        }
        return nil
    }

    func cleanText(_ text: String) async -> String {
        var result = text
        result = truncateAtReferences(result)
        result = stripFigureRefs(result)
        result = stripAuthorYearCitations(result)
        result = stripUnicodeSuperscripts(result)
        result = await stripGluedNumericCitations(result)
        result = stripBracketedCitations(result)
        result = cleanWhitespace(result)
        return result
    }

    // MARK: - DOI Extraction

    private func extractDOI(from url: URL) async throws -> String {
        let urlString = url.absoluteString

        // 1. DOI in URL string
        if let doi = doiRegex(in: urlString) { return doi }

        // 2. PubMed URL
        if urlString.contains("pubmed.ncbi.nlm.nih.gov"),
           let pmid = extractPMID(from: urlString) {
            if let doi = try? await doiFromPMID(pmid) { return doi }
        }

        // 3. PMC URL
        if urlString.contains("pmc") || urlString.contains("ncbi.nlm.nih.gov/pmc"),
           let pmcid = extractPMCID(from: urlString) {
            if let doi = try? await doiFromPMCID(pmcid) { return doi }
        }

        // 4. Page scrape
        if let doi = try? await doiFromPageScrape(url: url) { return doi }

        throw ArticleError.doiNotFound
    }

    private func doiRegex(in string: String) -> String? {
        let pattern = #"10\.\d{4,9}/[^\s"<>]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let range = Range(match.range, in: string)
        else { return nil }
        return String(string[range])
    }

    private func extractPMID(from url: String) -> String? {
        let pattern = #"pubmed\.ncbi\.nlm\.nih\.gov/(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
              let range = Range(match.range(at: 1), in: url)
        else { return nil }
        return String(url[range])
    }

    private func extractPMCID(from url: String) -> String? {
        let pattern = #"PMC(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
              let range = Range(match.range(at: 1), in: url)
        else { return nil }
        return String(url[range])
    }

    private func doiFromPMID(_ pmid: String) async throws -> String? {
        let urlStr = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?db=pubmed&id=\(pmid)&retmode=json"
        guard let url = URL(string: urlStr) else { return nil }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = (json["result"] as? [String: Any])?[pmid] as? [String: Any],
              let doi = (result["articleids"] as? [[String: Any]])?.first(where: { $0["idtype"] as? String == "doi" })?["value"] as? String
        else { return nil }
        return doi
    }

    private func doiFromPMCID(_ pmcid: String) async throws -> String? {
        let urlStr = "https://www.ncbi.nlm.nih.gov/pmc/utils/idconv/v1.0/?ids=PMC\(pmcid)&format=json"
        guard let url = URL(string: urlStr) else { return nil }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = json["records"] as? [[String: Any]],
              let doi = records.first?["doi"] as? String
        else { return nil }
        return doi
    }

    private func doiFromPageScrape(url: URL) async throws -> String? {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let html = String(data: data, encoding: .utf8) else { return nil }

        // Check meta citation_doi
        let metaPattern = #"<meta[^>]+name="citation_doi"[^>]+content="([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: metaPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            return String(html[range])
        }

        // Bare DOI pattern
        return doiRegex(in: html)
    }

    // MARK: - Fetch

    private func fetchAndClean(doi: String) async throws -> ProcessedArticle {
        if let article = try? await fetchFromPMC(doi: doi) { return article }
        if let article = try? await fetchFromEuropePMC(doi: doi) { return article }
        return try await fetchFromUnpaywall(doi: doi)
    }

    private func fetchFromEuropePMC(doi: String) async throws -> ProcessedArticle {
        let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? doi
        let searchURL = URL(string: "https://www.ebi.ac.uk/europepmc/webservices/rest/search?query=DOI:\(encoded)&resultType=lite&format=json")!
        let (searchData, _) = try await URLSession.shared.data(from: searchURL)
        guard let json = try? JSONSerialization.jsonObject(with: searchData) as? [String: Any],
              let results = (json["resultList"] as? [String: Any])?["result"] as? [[String: Any]],
              let first = results.first,
              let pmcid = first["pmcid"] as? String
        else { throw ArticleError.notInPMC }

        let xmlURL = URL(string: "https://www.ebi.ac.uk/europepmc/webservices/rest/\(pmcid)/fullTextXML")!
        let (xmlData, _) = try await URLSession.shared.data(from: xmlURL)
        let parser = PMCXMLParser()
        guard let article = parser.parse(data: xmlData) else { throw ArticleError.parseFailure }
        let cleanedBody = await cleanText(article.bodyText)
        return ProcessedArticle(title: article.title, authors: article.authors, abstract: article.abstract, bodyText: cleanedBody)
    }

    private func fetchFromPMC(doi: String) async throws -> ProcessedArticle {
        let pmcid = try await findPMCID(doi: doi)
        let fetchURL = URL(string: "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=pmc&id=\(pmcid)&rettype=xml")!
        let (xmlData, _) = try await URLSession.shared.data(from: fetchURL)
        let parser = PMCXMLParser()
        guard let raw = parser.parse(data: xmlData) else { throw ArticleError.parseFailure }
        let cleanedBody = await cleanText(raw.bodyText)
        return ProcessedArticle(title: raw.title, authors: raw.authors, abstract: raw.abstract, bodyText: cleanedBody)
    }

    private func findPMCID(doi: String) async throws -> String {
        let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? doi
        let url = URL(string: "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pmc&term=\(encoded)[doi]&retmode=json")!
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let esearch = json["esearchresult"] as? [String: Any],
              let ids = esearch["idlist"] as? [String],
              let pmcid = ids.first, !pmcid.isEmpty
        else { throw ArticleError.notInPMC }
        return pmcid
    }

    // MARK: - Figure Mode

    func processFigures(url: URL) async throws -> ProcessedFigures {
        // Prefer a PMCID directly in the URL (avoids a DOI round-trip)
        let pmcid: String
        let urlStr = url.absoluteString
        if let direct = extractPMCID(from: urlStr) {
            pmcid = direct
        } else {
            guard let doi = try? await extractDOI(from: url) else {
                throw ArticleError.figuresUnavailable
            }
            do { pmcid = try await findPMCID(doi: doi) }
            catch { throw ArticleError.figuresUnavailable }
        }

        let fetchURL = URL(string: "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=pmc&id=\(pmcid)&rettype=xml")!
        let (xmlData, _) = try await URLSession.shared.data(from: fetchURL)
        let parser = PMCXMLParser()
        guard let raw = parser.parse(data: xmlData) else { throw ArticleError.parseFailure }
        guard !raw.figures.isEmpty else { throw ArticleError.figuresUnavailable }

        let contextGroups = extractFigureContextGroups(from: raw.bodyText)

        var allPanels: [FigurePanel] = []
        for rawFig in raw.figures where rawFig.number > 0 {
            let imgURL = figureImageURL(href: rawFig.graphicHref, pmcid: pmcid)
            var panels = splitPanels(caption: rawFig.fullCaption,
                                     figureNumber: rawFig.number,
                                     figureTitle: rawFig.title,
                                     imageURL: imgURL)
            panels = panels.map { panel in
                // Prefer panel-specific context (e.g. "4F"), fall back to whole-figure (e.g. "4")
                let panelKey  = "\(rawFig.number)\(panel.label.uppercased())"
                let figKey    = "\(rawFig.number)"
                let sentences = contextGroups[panelKey] ?? contextGroups[figKey] ?? []
                return FigurePanel(figureNumber: panel.figureNumber,
                                   figureTitle: panel.figureTitle,
                                   label: panel.label,
                                   legendText: panel.legendText,
                                   textReferences: sentences,
                                   imageURL: panel.imageURL)
            }
            allPanels.append(contentsOf: panels)
        }

        guard !allPanels.isEmpty else { throw ArticleError.figuresUnavailable }
        return ProcessedFigures(title: raw.title, panels: allPanels)
    }

    private func figureImageURL(href: String, pmcid: String) -> URL? {
        guard !href.isEmpty else { return nil }
        return URL(string: "https://www.ncbi.nlm.nih.gov/pmc/articles/PMC\(pmcid)/bin/\(href).jpg")
    }

    private func splitPanels(caption: String, figureNumber: Int, figureTitle: String, imageURL: URL?) -> [FigurePanel] {
        let pattern = #"\(([A-Z])\)"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let matches = regex.matches(in: caption, range: NSRange(caption.startIndex..., in: caption))
            if !matches.isEmpty {
                var panels: [FigurePanel] = []
                for (i, match) in matches.enumerated() {
                    guard let labelRange = Range(match.range(at: 1), in: caption),
                          let matchRange  = Range(match.range, in: caption) else { continue }
                    let label = String(caption[labelRange])
                    let textStart = matchRange.upperBound
                    let textEnd: String.Index
                    if i + 1 < matches.count, let nextRange = Range(matches[i + 1].range, in: caption) {
                        textEnd = nextRange.lowerBound
                    } else {
                        textEnd = caption.endIndex
                    }
                    let legendText = String(caption[textStart..<textEnd])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    panels.append(FigurePanel(figureNumber: figureNumber, figureTitle: figureTitle,
                                              label: label, legendText: legendText,
                                              textReferences: [], imageURL: imageURL))
                }
                if !panels.isEmpty { return panels }
            }
        }
        return [FigurePanel(figureNumber: figureNumber, figureTitle: figureTitle,
                            label: "", legendText: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                            textReferences: [], imageURL: imageURL)]
    }

    /// Returns a dict mapping "figureNumber+panelLabel" (e.g. "4F", "4", "5A") to the
    /// group of body sentences that discuss each figure/panel.
    ///
    /// A group starts at any sentence containing a figure callout (e.g. "(Figure 4F)") and
    /// continues through subsequent sentences until the next callout sentence.
    func extractFigureContextGroups(from bodyText: String) -> [String: [String]] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = bodyText
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: bodyText.startIndex..<bodyText.endIndex) { range, _ in
            sentences.append(String(bodyText[range]))
            return true
        }

        // Matches "(Figure 4F)", "(Fig. 4f)", "(Fig 4)", "(Extended Data Figure 4A)", etc.
        // Capture group 1 = figure number, group 2 = panel label (may be empty)
        let pattern = #"\((?:Extended\s+Data\s+|Supplementary\s+)?Fig(?:ures?|s)?\.?\s*(\d+)([A-Za-z]?)(?:[^)]*)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [:] }

        var groups: [String: [String]] = [:]
        var currentKey: String? = nil

        for sentence in sentences {
            let nsRange = NSRange(sentence.startIndex..., in: sentence)
            let matches = regex.matches(in: sentence, range: nsRange)

            if matches.isEmpty {
                if let key = currentKey {
                    groups[key, default: []].append(sentence)
                }
            } else {
                // Sentence has at least one callout — it belongs to the FIRST callout's group
                if let first = matches.first,
                   let numRange = Range(first.range(at: 1), in: sentence),
                   let figNum = Int(sentence[numRange]) {
                    let panelRange = Range(first.range(at: 2), in: sentence)
                    let panel = panelRange.map { String(sentence[$0]).uppercased() } ?? ""
                    let key = "\(figNum)\(panel)"
                    // Also add to current key if switching (the callout sentence wraps up prior context too)
                    if let prev = currentKey, prev != key {
                        groups[prev, default: []].append(sentence)
                    }
                    currentKey = key
                    groups[key, default: []].append(sentence)
                }
            }
        }
        return groups
    }

    private func fetchFromUnpaywall(doi: String) async throws -> ProcessedArticle {
        let encodedDOI = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
        let urlStr = "https://api.unpaywall.org/v2/\(encodedDOI)?email=paperaudio@example.com"
        guard let url = URL(string: urlStr) else { throw ArticleError.fetchFailure }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ArticleError.fetchFailure
        }

        let title = json["title"] as? String ?? "Unknown Title"

        // Try to retrieve full text from the best OA location
        if let bestLocation = json["best_oa_location"] as? [String: Any] {
            // 1. Try PDF URL
            if let pdfStr = bestLocation["url_for_pdf"] as? String,
               let pdfURL = URL(string: pdfStr),
               let article = try? await fetchFromOAPDF(url: pdfURL, title: title) {
                return article
            }
            // 2. Try HTML landing page
            let htmlStr = bestLocation["url"] as? String ?? bestLocation["url_for_landing_page"] as? String
            if let htmlStr,
               let htmlURL = URL(string: htmlStr),
               let article = try? await fetchFromOAHTML(url: htmlURL, title: title) {
                return article
            }
        }

        throw ArticleError.fetchFailure
    }

    private func fetchFromOAPDF(url: URL, title: String) async throws -> ProcessedArticle {
        let (data, _) = try await URLSession.shared.data(from: url)
        // Try PDFDocument regardless of content-type — redirects can obscure the header
        guard let document = PDFDocument(data: data) else { throw ArticleError.parseFailure }
        var pages: [String] = []
        for i in 0..<document.pageCount {
            if let page = document.page(at: i), let text = page.string, !text.isEmpty {
                pages.append(text)
            }
        }
        let fullText = pages.joined(separator: "\n")
        guard !fullText.isEmpty else { throw ArticleError.parseFailure }
        let cleaned = await cleanText(fullText)
        return ProcessedArticle(title: title, authors: [], abstract: "", bodyText: cleaned)
    }

    private func fetchFromOAHTML(url: URL, title: String) async throws -> ProcessedArticle {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ArticleError.parseFailure
        }
        let bodyText = extractArticleTextFromHTML(html)
        guard bodyText.count > 200 else { throw ArticleError.parseFailure }
        let cleaned = await cleanText(bodyText)
        return ProcessedArticle(title: title, authors: [], abstract: "", bodyText: cleaned)
    }

    private func extractArticleTextFromHTML(_ html: String) -> String {
        // Try common article container patterns, largest match wins
        let containerPatterns = [
            #"<article[^>]*>([\s\S]*?)</article>"#,
            #"<div[^>]+class="[^"]*(?:article-body|article-content|article-text|fulltext|full-text|main-content)[^"]*"[^>]*>([\s\S]*?)</div>"#,
            #"<div[^>]+id="[^"]*(?:article-body|articleBody|full-text|fulltext|main-text)[^"]*"[^>]*>([\s\S]*?)</div>"#,
            #"<section[^>]+class="[^"]*(?:article-body|body|content)[^"]*"[^>]*>([\s\S]*?)</section>"#,
        ]

        var best = ""
        for pattern in containerPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) {
                let captureIdx = match.numberOfRanges > 1 ? 1 : 0
                if let range = Range(match.range(at: captureIdx), in: html) {
                    let candidate = String(html[range])
                    if candidate.count > best.count { best = candidate }
                }
            }
        }

        let source = best.isEmpty ? html : best

        // Strip script/style blocks
        var text = source
        for tag in ["script", "style", "nav", "header", "footer"] {
            let tagPattern = "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>"
            text = (try? NSRegularExpression(pattern: tagPattern, options: .caseInsensitive))?
                .stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "") ?? text
        }

        // Strip remaining HTML tags
        text = (try? NSRegularExpression(pattern: "<[^>]+>"))?
            .stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ") ?? text

        // Decode common HTML entities
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&nbsp;", " "), ("&quot;", "\""), ("&#x27;", "'"),
            ("&#39;", "'"), ("&apos;", "'"), ("&mdash;", "—"),
            ("&ndash;", "–"), ("&hellip;", "…"),
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        // Numeric HTML entities
        text = (try? NSRegularExpression(pattern: "&#(\\d+);"))?
            .stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ") ?? text

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Cleaning

    private let citationStripBlocklist: Set<String> = [
        "figure", "table", "fig", "equation", "eq", "section",
        "chapter", "appendix", "step", "phase", "stage",
        "type", "grade", "day", "week", "month", "year",
        "group", "arm", "cohort", "patient", "subject"
    ]

    private func truncateAtReferences(_ text: String) -> String {
        let headers = ["References", "Bibliography", "Literature Cited", "Works Cited", "REFERENCES"]
        for header in headers {
            if let range = text.range(of: "\n\(header)\n") {
                return String(text[..<range.lowerBound])
            }
            if let range = text.range(of: "\n\(header.uppercased())\n") {
                return String(text[..<range.lowerBound])
            }
        }
        return text
    }

    private func stripFigureRefs(_ text: String) -> String {
        let pattern = #"\((?:Fig(?:ure|s)?\.?|Table|Supplementary|Suppl\.?|S)\s*[\w,\s.–\-]+\)"#
        return (try? NSRegularExpression(pattern: pattern))?.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "") ?? text
    }

    private func stripAuthorYearCitations(_ text: String) -> String {
        let pattern = #"\([A-Z][a-z]+(?:\s+et\s+al\.)?(?:,\s*\d{4})?(?:;\s*[A-Z][a-z]+(?:\s+et\s+al\.)?(?:,\s*\d{4})?)*\)"#
        return (try? NSRegularExpression(pattern: pattern))?.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "") ?? text
    }

    private func stripUnicodeSuperscripts(_ text: String) -> String {
        let pattern = "[¹²³⁴⁵⁶⁷⁸⁹⁰]+"
        return (try? NSRegularExpression(pattern: pattern))?.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "") ?? text
    }

    private func stripGluedNumericCitations(_ text: String) async -> String {
        let pattern = #"([a-zA-Z]{3,})(\d+(?:[,–\-]\d+)*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var result = text
        var offset = 0
        for match in matches {
            guard let wordRange = Range(match.range(at: 1), in: text) else { continue }
            let word = String(text[wordRange]).lowercased()
            guard !citationStripBlocklist.contains(word) else { continue }
            // Check for hyphen before digits
            let beforeDigits = text.index(wordRange.upperBound, offsetBy: -1, limitedBy: text.startIndex) ?? text.startIndex
            if text[beforeDigits] == "-" { continue }
            if await isRealEnglishWord(word) {
                let adjustedRange = NSRange(location: match.range.location + offset, length: match.range.length)
                let replacement = String(nsText.substring(with: NSRange(location: match.range(at: 1).location + offset, length: match.range(at: 1).length)))
                result = (result as NSString).replacingCharacters(in: adjustedRange, with: replacement)
                offset += replacement.count - match.range.length
            }
        }
        return result
    }

    private func isRealEnglishWord(_ word: String) async -> Bool {
        await MainActor.run {
            let checker = UITextChecker()
            let range = NSRange(location: 0, length: word.utf16.count)
            let misspelledRange = checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: "en")
            return misspelledRange.location == NSNotFound
        }
    }

    private func stripBracketedCitations(_ text: String) -> String {
        let pattern = #"\[\d+(?:[,–\-]\d+)*\]"#
        return (try? NSRegularExpression(pattern: pattern))?.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "") ?? text
    }

    private func cleanWhitespace(_ text: String) -> String {
        var result = text
        // Collapse multiple spaces
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        // Collapse 3+ newlines to double
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Models

struct ProcessedArticle {
    let title: String
    let authors: [String]
    let abstract: String
    let bodyText: String

    var fullText: String {
        var parts: [String] = []
        if !title.isEmpty { parts.append(title) }
        if !abstract.isEmpty { parts.append(abstract) }
        if !bodyText.isEmpty { parts.append(bodyText) }
        return parts.joined(separator: "\n\n")
    }
}

enum ArticleError: LocalizedError {
    case doiNotFound
    case notInPMC
    case parseFailure
    case fetchFailure
    case figuresUnavailable

    var errorDescription: String? {
        switch self {
        case .doiNotFound: return "Could not extract a DOI from this URL."
        case .notInPMC: return "Article not found in PubMed Central open access."
        case .parseFailure: return "Failed to parse article XML."
        case .fetchFailure: return "Failed to fetch article."
        case .figuresUnavailable: return "Figure data is not available for this paper. Try Narration mode."
        }
    }
}

// MARK: - PMC XML Parser

private struct RawFigure {
    var number: Int = 0
    var labelText: String = ""
    var title: String = ""
    var fullCaption: String = ""
    var graphicHref: String = ""
}

private struct RawArticle {
    var title: String = ""
    var authors: [String] = []
    var abstract: String = ""
    var bodyText: String = ""
    var figures: [RawFigure] = []
}

private class PMCXMLParser: NSObject, XMLParserDelegate {
    private var article = RawArticle()
    private var currentElement = ""
    private var inAbstract = false
    private var inBody = false
    private var inRefList = false
    private var inContrib = false
    private var currentSurname = ""
    private var currentGivenNames = ""
    // Figure tracking
    private var inFig = false
    private var inFigLabel = false
    private var inFigCaption = false
    private var inFigCaptionTitle = false
    private var currentFig = RawFigure()

    func parse(data: Data) -> RawArticle? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { return nil }
        return article
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        switch elementName {
        case "abstract":  inAbstract = true
        case "body":      inBody = true
        case "ref-list":  inRefList = true; inBody = false
        case "contrib":   inContrib = true; currentSurname = ""; currentGivenNames = ""
        case "fig":
            inFig = true
            currentFig = RawFigure()
        case "label":
            if inFig { inFigLabel = true }
        case "caption":
            if inFig { inFigCaption = true }
        case "title":
            if inFig && inFigCaption { inFigCaptionTitle = true }
        case "graphic":
            if inFig {
                currentFig.graphicHref = attributeDict["xlink:href"] ?? attributeDict["href"] ?? ""
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inFig {
            if inFigLabel { currentFig.labelText += string }
            if inFigCaptionTitle { currentFig.title += string }
            else if inFigCaption { currentFig.fullCaption += string }
            return
        }
        if inAbstract && !inRefList { article.abstract += string }
        if inBody && !inRefList { article.bodyText += string }
        switch currentElement {
        case "article-title": if article.title.isEmpty { article.title += string }
        case "surname":       if inContrib { currentSurname += string }
        case "given-names":   if inContrib { currentGivenNames += string }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch elementName {
        case "abstract":  inAbstract = false
        case "body":      inBody = false
        case "ref-list":  inRefList = false
        case "contrib":
            inContrib = false
            let name = [currentGivenNames, currentSurname].filter { !$0.isEmpty }.joined(separator: " ")
            if !name.isEmpty { article.authors.append(name) }
        case "fig":
            inFig = false
            let digits = currentFig.labelText.filter { $0.isNumber }
            if let n = Int(digits) { currentFig.number = n }
            article.figures.append(currentFig)
        case "label":           inFigLabel = false
        case "caption":         inFigCaption = false
        case "title":           inFigCaptionTitle = false
        default: break
        }
        currentElement = ""
    }
}
