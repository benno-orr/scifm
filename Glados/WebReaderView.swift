import SwiftUI
import WebKit

// MARK: - SwiftUI wrapper

struct WebReaderSheet: View {
    let url: URL
    let onExtract: (String, String) -> Void   // (title, bodyText)
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            WebReaderView(url: url, onExtract: { title, body in
                onExtract(title, body)
                dismiss()
            })
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
    let onExtract: (String, String) -> Void

    func makeUIViewController(context: Context) -> _WebReaderVC {
        _WebReaderVC(url: url, onExtract: onExtract)
    }
    func updateUIViewController(_ vc: _WebReaderVC, context: Context) {}
}

// MARK: - UIViewController

final class _WebReaderVC: UIViewController, WKNavigationDelegate {
    private let url: URL
    private let onExtract: (String, String) -> Void

    private var webView: WKWebView!
    private var readButton: UIButton!
    private var spinner: UIActivityIndicatorView!

    init(url: URL, onExtract: @escaping (String, String) -> Void) {
        self.url = url
        self.onExtract = onExtract
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

        // "Read this article" pill button floating over the bottom
        var cfg = UIButton.Configuration.filled()
        cfg.title = "Read this article"
        cfg.image = UIImage(systemName: "waveform")
        cfg.imagePadding = 8
        cfg.cornerStyle = .capsule
        readButton = UIButton(configuration: cfg)
        readButton.translatesAutoresizingMaskIntoConstraints = false
        readButton.addTarget(self, action: #selector(readTapped), for: .touchUpInside)
        view.addSubview(readButton)

        // Loading spinner shown over button while extracting
        spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            readButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            readButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            readButton.heightAnchor.constraint(equalToConstant: 44),
            readButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),

            spinner.centerXAnchor.constraint(equalTo: readButton.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: readButton.centerYAnchor),
        ])

        webView.load(URLRequest(url: url))
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        readButton.isEnabled = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        readButton.isEnabled = true
    }

    // MARK: - Extraction

    @objc private func readTapped() {
        readButton.isHidden = true
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
            self.readButton.isHidden = false

            guard let jsonStr = result as? String,
                  let data = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let title = json["title"],
                  let body = json["body"], body.count > 200
            else {
                // Show brief error feedback
                var cfg = self.readButton.configuration ?? .filled()
                cfg.title = "Couldn't extract text — try scrolling to article first"
                self.readButton.configuration = cfg
                return
            }

            DispatchQueue.main.async { self.onExtract(title, body) }
        }
    }
}
