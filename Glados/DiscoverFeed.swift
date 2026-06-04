import Foundation

// MARK: - Models

struct PaperSearchResult: Identifiable {
    let id: String
    let title: String
    let authors: String
    let journal: String
    let year: String
    let abstract: String
    let doi: String?
    let articleURL: URL
}

struct FeedSource {
    let name: String
    let label: String
    let rssURL: URL
    /// Only include items whose URL contains this substring (nil = no filter)
    let urlMustContain: String?
    /// Only include items whose dc:type is in this set (nil = allow all)
    let dcTypesAllowed: Set<String>?
}

struct FeedArticle: Identifiable {
    let id: String
    let title: String
    let summary: String
    let url: URL
    let source: String
    let label: String
    let publishedDate: Date?
    let doi: String?
}

// MARK: - Manager

actor FeedManager {
    static let shared = FeedManager()

    private var thumbnailCache: [String: URL] = [:]
    private let briefingProcessor = ArticleProcessor()

    private let reviewSources: [FeedSource] = [
        FeedSource(
            name: "Nat Rev Genetics", label: "Review",
            rssURL: URL(string: "https://feeds.nature.com/nrg/rss/current")!,
            urlMustContain: nil, dcTypesAllowed: nil
        ),
        FeedSource(
            name: "Nat Rev Cancer", label: "Review",
            rssURL: URL(string: "https://feeds.nature.com/nrc/rss/current")!,
            urlMustContain: nil, dcTypesAllowed: nil
        ),
        FeedSource(
            name: "Nat Rev Mol Cell Bio", label: "Review",
            rssURL: URL(string: "https://feeds.nature.com/nrm/rss/current")!,
            urlMustContain: nil, dcTypesAllowed: nil
        ),
        FeedSource(
            name: "Nat Rev Immunology", label: "Review",
            rssURL: URL(string: "https://feeds.nature.com/nri/rss/current")!,
            urlMustContain: nil, dcTypesAllowed: nil
        ),
        FeedSource(
            name: "Nature Genetics", label: "Article",
            rssURL: URL(string: "https://feeds.nature.com/ng/rss/current")!,
            urlMustContain: nil, dcTypesAllowed: nil
        ),
        FeedSource(
            name: "Nature Biotechnology", label: "Article",
            rssURL: URL(string: "https://feeds.nature.com/nbt/rss/current")!,
            urlMustContain: nil, dcTypesAllowed: nil
        ),
        FeedSource(
            name: "Cell", label: "Article",
            rssURL: URL(string: "https://www.cell.com/cell/rss")!,
            urlMustContain: nil, dcTypesAllowed: nil
        ),
        FeedSource(
            name: "Science", label: "Perspective",
            rssURL: URL(string: "https://www.science.org/action/showFeed?type=etoc&feed=rss&jc=science")!,
            urlMustContain: nil,
            dcTypesAllowed: ["Perspective", "Review"]
        ),
    ]

    // Digest = Nature Research Briefings (scraped, plain-language summaries)
    // plus Science Perspectives and Cell highlights from RSS.
    // The Nature RSS feed routes through an auth/cookie redirect that URLSession
    // can't reliably follow, so the briefings are scraped from the HTML listing.
    private let sources: [FeedSource] = [
        // Science Perspectives and In Depth are their N&V equivalents
        FeedSource(
            name: "Science", label: "Perspectives",
            rssURL: URL(string: "https://www.science.org/action/showFeed?type=etoc&feed=rss&jc=science")!,
            urlMustContain: nil,
            dcTypesAllowed: ["Perspective", "In Depth", "Feature", "Research Highlights"]
        ),
        // Cell eTOC — URLSession bypasses the Cloudflare challenge curl hits
        FeedSource(
            name: "Cell", label: "Highlights",
            rssURL: URL(string: "https://www.cell.com/cell/rss")!,
            urlMustContain: nil,
            dcTypesAllowed: nil
        ),
    ]

    private static let iPhoneUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    func fetchReviews() async -> [FeedArticle] {
        await withTaskGroup(of: [FeedArticle].self) { group in
            for source in reviewSources {
                group.addTask { await self.fetch(source: source) }
            }
            var all: [FeedArticle] = []
            for await articles in group { all.append(contentsOf: articles) }
            return all.sorted { ($0.publishedDate ?? .distantPast) > ($1.publishedDate ?? .distantPast) }
        }
    }

    func fetchAll() async -> [FeedArticle] {
        await withTaskGroup(of: [FeedArticle].self) { group in
            group.addTask { await self.scrapeNatureBriefings() }
            for source in sources {
                group.addTask { await self.fetch(source: source) }
            }
            var all: [FeedArticle] = []
            for await articles in group { all.append(contentsOf: articles) }
            return all.sorted { ($0.publishedDate ?? .distantPast) > ($1.publishedDate ?? .distantPast) }
        }
    }

    // MARK: - Nature Research Briefings (HTML scrape)

    /// Scrapes Nature's Research Briefing listing — short, plain-language digests
    /// of recent papers. Returns newest-first FeedArticles with the briefing text
    /// as the summary (read directly, no DOI/abstract round-trip needed).
    func scrapeNatureBriefings() async -> [FeedArticle] {
        guard let url = URL(string: "https://www.nature.com/nature/articles?type=research-briefing") else { return [] }
        var request = URLRequest(url: url)
        request.setValue(Self.iPhoneUA, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return [] }

        var out: [FeedArticle] = []
        var seen = Set<String>()
        // Each article card is an <article> ... block on the listing page.
        for block in html.components(separatedBy: "<article").dropFirst() {
            guard let link = Self.firstGroup(#"href="(/articles/d41586-[^"]+)""#, block),
                  !seen.contains(link),
                  let rawTitle = Self.firstGroup(#"name headline">\s*<a\b[^>]*>(.*?)</a>"#, block)
            else { continue }
            let title = Self.decodeEntities(rawTitle.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, let articleURL = URL(string: "https://www.nature.com\(link)") else { continue }
            seen.insert(link)

            let dateStr = Self.firstGroup(#"datetime="([^"]+)""#, block) ?? ""
            let rawDesc = Self.firstGroup(#"data-test="article-description"[^>]*>(.*?)</div>"#, block) ?? ""
            let summary = Self.decodeEntities(rawDesc.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression))
                .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")

            out.append(FeedArticle(
                id: link, title: title, summary: summary, url: articleURL,
                source: "Nature", label: "Research Briefing",
                publishedDate: parseFeedDate(dateStr), doi: nil
            ))
        }
        return out
    }

    /// Cleans a scraped briefing summary for narration the same way full articles
    /// are prepared: strip citations/figure refs, then the LLM tidy pass.
    /// `LLMCleaner.clean` is a no-op (returns input) when no LLM provider is set.
    func tidyForReading(_ text: String, title: String) async -> String {
        let stripped = await briefingProcessor.cleanText(text)
        return await LLMCleaner.shared.clean(title: title, text: stripped)
    }

    private static func firstGroup(_ pattern: String, _ s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    private static func decodeEntities(_ s: String) -> String {
        var t = s
        for (a, b) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                       ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t.replacingOccurrences(of: "&#\\d+;", with: "", options: .regularExpression)
    }

    // MARK: - PubMed search

    /// Searches Europe PMC — covers PubMed, PMC full-text, bioRxiv, medRxiv, and more.
    func search(query: String) async -> [PaperSearchResult] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlStr = "https://www.ebi.ac.uk/europepmc/webservices/rest/search?query=\(encoded)&resultType=core&pageSize=25&format=json&sort=relevance"
        guard let url = URL(string: urlStr),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resultList = json["resultList"] as? [String: Any],
              let results = resultList["result"] as? [[String: Any]]
        else { return [] }

        return results.compactMap { r -> PaperSearchResult? in
            guard let title = r["title"] as? String, !title.isEmpty else { return nil }

            let pmid    = r["pmid"]    as? String ?? ""
            let pmcid   = r["pmcid"]   as? String ?? ""
            let doi     = r["doi"]     as? String
            let source  = r["source"]  as? String ?? "MED"
            let extID   = r["id"]      as? String ?? pmid
            let authors = r["authorString"] as? String ?? ""
            let journal = r["journalTitle"] as? String ?? r["bookOrReportDetails"] as? String ?? ""
            let year    = r["pubYear"]      as? String ?? ""
            let abstract = r["abstractText"] as? String ?? ""

            // Build the best available article URL
            let articleURL: URL
            if !pmid.isEmpty {
                articleURL = URL(string: "https://pubmed.ncbi.nlm.nih.gov/\(pmid)/")!
            } else if !pmcid.isEmpty {
                articleURL = URL(string: "https://www.ncbi.nlm.nih.gov/pmc/articles/\(pmcid)/")!
            } else if let doi, let u = URL(string: "https://doi.org/\(doi)") {
                articleURL = u
            } else {
                articleURL = URL(string: "https://europepmc.org/article/\(source)/\(extID)")!
            }

            // Trim author list to 3 + et al.
            let authorParts = authors.components(separatedBy: ", ")
            let authorsStr = authorParts.count > 3
                ? authorParts.prefix(3).joined(separator: ", ") + " et al."
                : authors

            let uid = pmid.isEmpty ? extID : pmid
            return PaperSearchResult(
                id: uid.isEmpty ? title : uid,
                title: title,
                authors: authorsStr,
                journal: journal,
                year: year,
                abstract: abstract,
                doi: doi,
                articleURL: articleURL
            )
        }
    }

    /// Returns the og:image URL for any page URL, fetching and caching on first call.
    func fetchThumbnail(for pageURL: URL) async -> URL? {
        let key = pageURL.absoluteString
        if let cached = thumbnailCache[key] { return cached }
        var request = URLRequest(url: pageURL)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
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
            if let url = URL(string: String(html[range])) {
                thumbnailCache[key] = url
                return url
            }
        }
        return nil
    }

    func fetchThumbnail(for article: FeedArticle) async -> URL? {
        return await fetchThumbnail(for: article.url)
    }

    /// Fetches the abstract for an article via PubMed DOI lookup.
    /// Returns nil if the article has no DOI or isn't indexed in PubMed.
    func fetchAbstract(for article: FeedArticle) async -> String? {
        guard let doi = article.doi else { return nil }
        let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? doi
        let searchStr = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed&term=\(encoded)%5BDOI%5D&retmode=json"
        guard let searchURL = URL(string: searchStr),
              let (searchData, _) = try? await URLSession.shared.data(from: searchURL),
              let json = try? JSONSerialization.jsonObject(with: searchData) as? [String: Any],
              let result = json["esearchresult"] as? [String: Any],
              let ids = result["idlist"] as? [String],
              let pmid = ids.first
        else { return nil }

        let fetchStr = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=pubmed&id=\(pmid)&rettype=xml&retmode=xml"
        guard let fetchURL = URL(string: fetchStr),
              let (xmlData, _) = try? await URLSession.shared.data(from: fetchURL),
              let xml = String(data: xmlData, encoding: .utf8)
        else { return nil }

        let pattern = #"<AbstractText(?:[^>]*)>([\s\S]*?)</AbstractText>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
        let parts = matches.compactMap { m -> String? in
            guard let r = Range(m.range(at: 1), in: xml) else { return nil }
            return String(xml[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let abstract = parts.joined(separator: " ")
        return abstract.isEmpty ? nil : abstract
    }

    private func fetch(source: FeedSource) async -> [FeedArticle] {
        var request = URLRequest(url: source.rssURL)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return [] }
        let parser = RSSParser(source: source)
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return parser.articles
    }
}

// MARK: - RSS/Atom Parser (handles RSS 1.0 RDF, RSS 2.0, Atom)

private class RSSParser: NSObject, XMLParserDelegate {
    let source: FeedSource
    var articles: [FeedArticle] = []

    private var insideItem = false
    private var currentElement = ""
    private var currentTitle = ""
    private var currentLink = ""
    private var currentDescription = ""
    private var currentPubDate = ""
    private var currentDCType = ""
    private var currentDCIdentifier = ""

    init(source: FeedSource) { self.source = source }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName _: String?,
                attributes attrs: [String: String] = [:]) {
        currentElement = elementName

        if elementName == "item" || elementName == "entry" {
            insideItem = true
            currentTitle = ""; currentLink = ""; currentDescription = ""
            currentPubDate = ""; currentDCType = ""; currentDCIdentifier = ""
        }

        // RDF RSS 1.0: link is in rdf:about attribute on <item>
        if elementName == "item", let about = attrs["rdf:about"], !about.isEmpty, currentLink.isEmpty {
            currentLink = about
        }
        // Atom-style <link href="..."/>
        if insideItem && elementName == "link", let href = attrs["href"], !href.isEmpty {
            currentLink = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideItem else { return }
        switch currentElement {
        case "title":
            currentTitle += string
        case "link":
            if currentLink.isEmpty { currentLink += string }
        case "description", "summary", "content", "content:encoded":
            currentDescription += string
        case "pubDate", "published", "updated", "dc:date", "date":
            currentPubDate += string
        case "dc:type", "type":
            currentDCType += string
        case "dc:identifier", "identifier":
            currentDCIdentifier += string
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        guard insideItem else { return }
        let s = String(data: data, encoding: .utf8) ?? ""
        switch currentElement {
        case "description", "summary", "content", "content:encoded":
            currentDescription += s
        default:
            break
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI _: String?,
                qualifiedName _: String?) {
        guard insideItem, elementName == "item" || elementName == "entry" else { return }
        defer { insideItem = false }

        let link = currentLink.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let url = URL(string: link) else { return }

        // Apply URL filter
        if let mustContain = source.urlMustContain, !link.contains(mustContain) { return }

        // Apply dc:type filter
        let itemType = currentDCType.trimmingCharacters(in: .whitespacesAndNewlines)
        if let allowed = source.dcTypesAllowed, !itemType.isEmpty, !allowed.contains(itemType) { return }

        // Extract DOI from dc:identifier (e.g. "doi:10.1038/s41586-026-10692-4")
        let rawID = currentDCIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let doi: String? = rawID.hasPrefix("doi:") ? String(rawID.dropFirst(4)) : nil

        articles.append(FeedArticle(
            id: link,
            title: title,
            summary: stripHTML(currentDescription).trimmingCharacters(in: .whitespacesAndNewlines),
            url: url,
            source: source.name,
            label: source.label,
            publishedDate: parseDate(currentPubDate.trimmingCharacters(in: .whitespacesAndNewlines)),
            doi: doi
        ))
    }

    private func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#\\d+;", with: "", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func parseDate(_ raw: String) -> Date? { parseFeedDate(raw) }
}

// Shared date parser for RSS/Atom and scraped pages.
private let iso8601Parser: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()
private let iso8601FractionalParser: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func parseFeedDate(_ raw: String) -> Date? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return nil }
    // ISO 8601 with a literal "Z" (e.g. 2026-05-28T06:00:06Z) — handled natively
    // here because DateFormatter's "Z" pattern expects "+0000", not a literal Z.
    if s.contains("T") {
        if let d = iso8601Parser.date(from: s) { return d }
        if let d = iso8601FractionalParser.date(from: s) { return d }
    }
    let formats = [
        "EEE, dd MMM yyyy HH:mm:ss Z",    // RSS 2.0
        "yyyy-MM-dd'T'HH:mm:ssZ",          // ISO 8601 with numeric offset
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        "yyyy-MM-dd",                       // dc:date / <time datetime> short form
    ]
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    for fmt in formats {
        f.dateFormat = fmt
        if let d = f.date(from: s) { return d }
    }
    return nil
}
