import Foundation
import WebKit
import UIKit

// MARK: - Local scraped-article cache

/// One article's locally-stored content (full text scraped past the paywall,
/// plus a cached cover image file).
struct ScrapedArticle: Codable {
    var title: String
    var body: String
    var imageFile: String?    // file name under the scraped-images dir
}

/// Persists scraped article text + images so Radio playback never has to hit a
/// paywalled page again. Keyed by source URL.
actor ScrapedStore {
    static let shared = ScrapedStore()

    private var map: [String: ScrapedArticle] = [:]
    private var loaded = false

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var jsonURL: URL { documentsURL.appendingPathComponent("scraped.json") }
    private var imageDir: URL { documentsURL.appendingPathComponent("scraped_images") }

    private func loadIfNeeded() {
        guard !loaded else { return }
        if let data = try? Data(contentsOf: jsonURL),
           let decoded = try? JSONDecoder().decode([String: ScrapedArticle].self, from: data) {
            map = decoded
        }
        loaded = true
    }

    func has(_ url: String) -> Bool { loadIfNeeded(); return map[url] != nil }

    /// Cached full text for a URL, if scraped (and substantial).
    func text(for url: String) -> String? {
        loadIfNeeded()
        guard let a = map[url], a.body.count > 200 else { return nil }
        return a.body
    }

    /// Local file URL of the cached cover image, if any.
    func imageURL(for url: String) -> URL? {
        loadIfNeeded()
        guard let file = map[url]?.imageFile else { return nil }
        let u = imageDir.appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func store(url: String, title: String, body: String, imageData: Data?) {
        loadIfNeeded()
        var imageFile: String? = map[url]?.imageFile
        if let imageData {
            try? FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
            let name = "\(abs(url.hashValue)).img"
            try? imageData.write(to: imageDir.appendingPathComponent(name))
            imageFile = name
        }
        map[url] = ScrapedArticle(title: title, body: body, imageFile: imageFile)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: jsonURL) }
    }
}

// MARK: - Headless scraper

/// Loads article pages in an off-screen WKWebView (sharing the app's cookies, so
/// logged-in Nature/Cell/Science access gets past paywalls), scrapes the full
/// text + cover image, and caches them via `ScrapedStore`. Processes a queue
/// one page at a time. No user input needed while the user stays logged in.
@MainActor
final class HeadlessScraper: NSObject, ObservableObject {
    static let shared = HeadlessScraper()

    @Published private(set) var remaining = 0
    @Published private(set) var isScraping = false

    private var webView: WKWebView?
    private var pending: [URL] = []
    private var queued = Set<String>()
    private var processing = false
    private var navContinuation: CheckedContinuation<Void, Never>?
    private var didResume = false

    /// Queues URLs to scrape (skipping already-cached / already-queued ones).
    func enqueue(_ urls: [URL]) {
        Task {
            for url in urls {
                let key = url.absoluteString
                if queued.contains(key) { continue }
                if await ScrapedStore.shared.has(key) { continue }
                queued.insert(key)
                pending.append(url)
            }
            remaining = pending.count
            if !processing { await run() }
        }
    }

    private func run() async {
        processing = true
        isScraping = true
        setupWebView()
        while !pending.isEmpty {
            let url = pending.removeFirst()
            remaining = pending.count
            await scrape(url)
        }
        processing = false
        isScraping = false
        teardownWebView()
    }

    // MARK: WebView lifecycle

    private func setupWebView() {
        guard webView == nil else { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()          // shares Safari/app cookies (login)
        let wv = WKWebView(frame: keyWindow?.bounds ?? UIScreen.main.bounds, configuration: config)
        wv.navigationDelegate = self
        wv.isUserInteractionEnabled = false
        wv.alpha = 0.01                                // rendered (so JS runs) but invisible
        keyWindow?.insertSubview(wv, at: 0)
        webView = wv
    }

    private func teardownWebView() {
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
    }

    private var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    // MARK: Single-page scrape

    private func scrape(_ url: URL) async {
        guard let webView else { return }
        didResume = false
        webView.load(URLRequest(url: url))
        // Wait for the page to finish (or a 25s timeout).
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            navContinuation = cont
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                self?.resumeNav()
            }
        }
        // Let late content render, then extract (one retry).
        var body = ""
        var title = ""
        for attempt in 0..<2 {
            try? await Task.sleep(nanoseconds: attempt == 0 ? 1_500_000_000 : 2_000_000_000)
            if let r = await extract() {
                title = r.title; body = r.body
                if body.count > 200 { break }
            }
        }
        guard body.count > 200 else { return }   // paywalled / logged out → skip, fall back later

        // Cover image (og:image), downloaded for offline artwork.
        var imageData: Data?
        if let imgURL = await FeedManager.shared.fetchThumbnail(for: url),
           let (data, _) = try? await URLSession.shared.data(from: imgURL) {
            imageData = data
        }
        await ScrapedStore.shared.store(url: url.absoluteString, title: title, body: body, imageData: imageData)
    }

    private func resumeNav() {
        guard !didResume, let cont = navContinuation else { return }
        didResume = true
        navContinuation = nil
        cont.resume()
    }

    private func extract() async -> (title: String, body: String)? {
        guard let webView else { return nil }
        return await withCheckedContinuation { cont in
            webView.evaluateJavaScript(Self.extractionJS) { result, _ in
                guard let s = result as? String, let data = s.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                      let title = json["title"], let body = json["body"]
                else { cont.resume(returning: nil); return }
                cont.resume(returning: (title, body))
            }
        }
    }

    /// Same extraction logic as the in-app reader.
    private static let extractionJS = """
    (function() {
        var title = (document.querySelector('h1.c-article-title') ||
                     document.querySelector('h1[class*="title"]') ||
                     document.querySelector('h1'))?.innerText?.trim() || document.title;
        var STRIP_TAGS = ['figure','figcaption','sup','aside','nav'];
        var STRIP_SELECTORS = ['[data-title="References"]','[data-title="Author information"]',
            '[data-title="Ethics declarations"]','[data-title="Supplementary information"]',
            '.c-article-references','.c-article-author-information','.c-article-peer-review',
            '[class*="reference-list"]','[class*="ref-list"]','[id*="ref-list"]',
            '[class*="author-info"]','[class*="copyright"]','[class*="footnote"]'];
        function cleanClone(el){var c=el.cloneNode(true);
            STRIP_TAGS.forEach(function(t){c.querySelectorAll(t).forEach(function(n){n.remove();});});
            STRIP_SELECTORS.forEach(function(s){try{c.querySelectorAll(s).forEach(function(n){n.remove();});}catch(e){}});
            return c;}
        function filterLines(t){return t.split('\\n').filter(function(l){var x=l.trim();
            if(/^[\\d,;.\\s–\\-]+$/.test(x))return false; if(x.length>0&&x.length<4)return false; return true;}).join('\\n');}
        var selectors=['.c-article-body','[class*="article-body"]','[class*="article-content"]','article .body','article','main'];
        var body='';
        for(var i=0;i<selectors.length;i++){var el=document.querySelector(selectors[i]);
            if(el){var t=filterLines(cleanClone(el).innerText.trim()); if(t.length>500){body=t;break;}}}
        if(!body) body=filterLines(document.body.innerText);
        return JSON.stringify({title:title, body:body});
    })();
    """
}

extension HeadlessScraper: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { resumeNav() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { resumeNav() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { resumeNav() }
}
