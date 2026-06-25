import SwiftUI

// MARK: - Article tap flow
//
// Tapping an article runs: open the page in the in-app browser (shares cookies,
// so it gets past paywalls) → auto-scrape it on load → swap the browser out for
// the scraped document → offer "Read" (narrate) or "Export" (.md). If auto-scrape
// fails, the browser stays up with manual Read / Export buttons as a fallback.

/// Identifies an article to run the flow on (used with `.fullScreenCover(item:)`).
struct ArticleFlowTarget: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

struct ArticleFlowView: View {
    let target: ArticleFlowTarget
    /// (title, body) → narrate the scraped text.
    let onRead: (String, String) -> Void
    /// (title, body) → export cleaned Markdown.
    let onExport: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scraped: (title: String, body: String)? = nil

    var body: some View {
        NavigationView {
            Group {
                if let scraped {
                    ScrapedDocView(
                        title: scraped.title.isEmpty ? target.title : scraped.title,
                        bodyText: scraped.body,
                        onRead: { onRead(scraped.title.isEmpty ? target.title : scraped.title, scraped.body); dismiss() },
                        onExport: { onExport(scraped.title.isEmpty ? target.title : scraped.title, scraped.body); dismiss() }
                    )
                } else {
                    WebReaderView(
                        url: target.url,
                        onRead: { title, body in onRead(title, body); dismiss() },
                        onExportDoc: { title, body in onExport(title, body); dismiss() },
                        autoScrape: true,
                        onScraped: { title, body in scraped = (title, body) }
                    )
                    .ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationTitle(scraped == nil ? "Loading…" : "Article")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

// MARK: - Scraped document preview

private struct ScrapedDocView: View {
    let title: String
    let bodyText: String
    let onRead: () -> Void
    let onExport: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(title).font(.title3).fontWeight(.bold)
                    Divider()
                    Text(bodyText).font(.body)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Read / Export action bar
            HStack(spacing: 12) {
                Button(action: onRead) {
                    Label("Read", systemImage: "waveform")
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color.accentColor).foregroundColor(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                Button(action: onExport) {
                    Label("Export .md", systemImage: "doc.badge.arrow.up")
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color.accentColor.opacity(0.15)).foregroundColor(.accentColor)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 12)
            .background(.ultraThinMaterial)
        }
    }
}
