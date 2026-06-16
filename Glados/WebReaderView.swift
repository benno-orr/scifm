import SwiftUI
import WebKit

// MARK: - SwiftUI wrapper

struct WebReaderSheet: View {
    let url: URL
    let onRead: (String, String) -> Void        // (title, bodyText) → narrate
    let onExportDoc: (String, String) -> Void    // (title, bodyText) → cleaned .md
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            WebReaderView(
                url: url,
                onRead: { title, body in onRead(title, body); dismiss() },
                onExportDoc: { title, body in onExportDoc(title, body); dismiss() }
            )
            .navigationTitle("Browse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }
}

// MARK: - UIViewControllerRepresentable

struct WebReaderView: UIViewControllerRepresentable {
    let url: URL
    let onRead: (String, String) -> Void
    let onExportDoc: (String, String) -> Void

    func makeUIViewController(context: Context) -> _WebReaderVC {
        _WebReaderVC(url: url, onRead: onRead, onExportDoc: onExportDoc)
    }
    func updateUIViewController(_ vc: _WebReaderVC, context: Context) {}
}

// MARK: - UIViewController

final class _WebReaderVC: UIViewController, WKNavigationDelegate {
    private let url: URL
    private let onRead: (String, String) -> Void
    private let onExportDoc: (String, String) -> Void

    private var webView: WKWebView!
    private var readButton: UIButton!
    private var exportButton: UIButton!
    private var buttonStack: UIStackView!
    private var spinner: UIActivityIndicatorView!
    /// Which action the in-flight extraction should fire on completion.
    private var pendingForDoc = false

    init(url: URL,
         onRead: @escaping (String, String) -> Void,
         onExportDoc: @escaping (String, String) -> Void) {
        self.url = url
        self.onRead = onRead
        self.onExportDoc = onExportDoc
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // WKWebView — use default data store so it shares cookies with Safari
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        // "Read this article" (narrate) — primary, filled.
        var readCfg = UIButton.Configuration.filled()
        readCfg.title = "Read this article"
        readCfg.image = UIImage(systemName: "waveform")
        readCfg.imagePadding = 6
        readCfg.cornerStyle = .capsule
        readButton = UIButton(configuration: readCfg)
        readButton.addTarget(self, action: #selector(readTapped), for: .touchUpInside)

        // "Export .md" — secondary, tinted.
        var exportCfg = UIButton.Configuration.tinted()
        exportCfg.title = "Export .md"
        exportCfg.image = UIImage(systemName: "doc.badge.arrow.up")
        exportCfg.imagePadding = 6
        exportCfg.cornerStyle = .capsule
        exportButton = UIButton(configuration: exportCfg)
        exportButton.addTarget(self, action: #selector(exportTapped), for: .touchUpInside)

        buttonStack = UIStackView(arrangedSubviews: [readButton, exportButton])
        buttonStack.axis = .horizontal
        buttonStack.spacing = 10
        buttonStack.distribution = .fillProportionally
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(buttonStack)

        // Loading spinner shown over the buttons while extracting
        spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            buttonStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            buttonStack.heightAnchor.constraint(equalToConstant: 44),
            buttonStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            buttonStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),

            spinner.centerXAnchor.constraint(equalTo: buttonStack.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: buttonStack.centerYAnchor),
        ])

        webView.load(URLRequest(url: url))
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        setButtonsEnabled(false)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        setButtonsEnabled(true)
    }

    private func setButtonsEnabled(_ on: Bool) {
        readButton.isEnabled = on
        exportButton.isEnabled = on
    }

    // MARK: - Extraction

    @objc private func readTapped()   { extract(forDoc: false) }
    @objc private func exportTapped() { extract(forDoc: true) }

    private func extract(forDoc: Bool) {
        pendingForDoc = forDoc
        buttonStack.isHidden = true
        spinner.startAnimating()

        let js = """
        (function() {
            var title = (
                document.querySelector('h1.c-article-title') ||
                document.querySelector('h1[class*="title"]') ||
                document.querySelector('h1')
            )?.innerText?.trim() || document.title;

            // Tags and selectors to strip before extracting text
            var STRIP_TAGS = ['figure', 'figcaption', 'sup', 'aside', 'nav'];
            var STRIP_SELECTORS = [
                // Reference lists
                '[data-title="References"]',
                '[data-title="Peer review information"]',
                '[data-title="Author information"]',
                '[data-title="Ethics declarations"]',
                '[data-title="Additional information"]',
                '[data-title="Supplementary information"]',
                '[data-title="Rights and permissions"]',
                '.c-article-references',
                '.c-article-author-information',
                '.c-article-peer-review',
                '.c-article-ethics',
                '#additional-information',
                '#peer-review-information',
                // Generic
                '[class*="reference-list"]',
                '[class*="ref-list"]',
                '[id*="ref-list"]',
                '[class*="author-info"]',
                '[class*="copyright"]',
                '[class*="footnote"]',
            ];

            function cleanClone(el) {
                var clone = el.cloneNode(true);
                STRIP_TAGS.forEach(function(tag) {
                    clone.querySelectorAll(tag).forEach(function(n) { n.remove(); });
                });
                STRIP_SELECTORS.forEach(function(sel) {
                    try { clone.querySelectorAll(sel).forEach(function(n) { n.remove(); }); } catch(e) {}
                });
                return clone;
            }

            function filterLines(text) {
                return text.split('\\n')
                    .filter(function(line) {
                        var t = line.trim();
                        // Drop lines that are only numbers/punctuation (stray ref numbers)
                        if (/^[\\d,;.\\s–\\-]+$/.test(t)) return false;
                        // Drop very short lines (nav artifacts), keep empty lines for spacing
                        if (t.length > 0 && t.length < 4) return false;
                        return true;
                    })
                    .join('\\n');
            }

            var selectors = [
                '.c-article-body',
                '[class*="article-body"]',
                '[class*="article-content"]',
                'article .body',
                'article',
                'main'
            ];
            var body = '';
            for (var i = 0; i < selectors.length; i++) {
                var el = document.querySelector(selectors[i]);
                if (el) {
                    var t = filterLines(cleanClone(el).innerText.trim());
                    if (t.length > 500) { body = t; break; }
                }
            }
            if (!body) body = filterLines(document.body.innerText);
            return JSON.stringify({ title: title, body: body });
        })();
        """

        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else { return }
            self.spinner.stopAnimating()
            self.buttonStack.isHidden = false

            guard let jsonStr = result as? String,
                  let data = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let title = json["title"],
                  let body = json["body"], body.count > 200
            else {
                // Show brief error feedback on the button that was tapped
                let btn = self.pendingForDoc ? self.exportButton : self.readButton
                var cfg = btn?.configuration ?? .filled()
                cfg.title = "Couldn't extract — scroll to the article first"
                btn?.configuration = cfg
                return
            }

            let forDoc = self.pendingForDoc
            DispatchQueue.main.async {
                if forDoc { self.onExportDoc(title, body) } else { self.onRead(title, body) }
            }
        }
    }
}
