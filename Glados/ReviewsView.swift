import SwiftUI

struct ReviewsView: View {
    @EnvironmentObject var viewModel: PlayerViewModel
    @Binding var selectedTab: Int

    @State private var articles: [FeedArticle] = []
    @State private var isLoading = false
    @State private var loadError = false
    @State private var flowTarget: ArticleFlowTarget? = nil

    var body: some View {
        NavigationView {
            Group {
                if isLoading && articles.isEmpty {
                    ProgressView("Loading reviews…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if loadError && articles.isEmpty {
                    emptyError
                } else {
                    List(articles) { article in
                        ArticleRow(
                            article: article,
                            onTap: { flowTarget = ArticleFlowTarget(url: article.url, title: article.title) },
                            onReadFull: { viewModel.load(url: article.url, kind: .review); selectedTab = 0 },
                            abstractText: { await resolveAbstract(article) }
                        )
                        .listRowBackground(Color.rowTranslucent)
                        .swipeActions(edge: .trailing) {
                            Button {
                                viewModel.generateDocument(url: article.url)
                                selectedTab = 0
                            } label: { Label("Markdown", systemImage: "doc.badge.arrow.up") }
                            .tint(.accentColor)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .charcoalBackdrop()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isLoading {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button { Task { await loadFeed() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .onAppear { if articles.isEmpty { Task { await loadFeed() } } }
            .refreshable { await loadFeed() }
            .fullScreenCover(item: $flowTarget) { target in
                ArticleFlowView(
                    target: target,
                    onRead: { title, body in
                        viewModel.processWebContent(title: title, bodyText: body)
                        selectedTab = 0
                    },
                    onExport: { title, body in
                        viewModel.generateDocumentFromText(title: title, bodyText: body, sourceURL: target.url)
                        selectedTab = 0
                    }
                )
            }
        }
    }

    private var emptyError: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash").font(.system(size: 48)).foregroundColor(.secondary)
            Text("Could not load reviews").font(.headline)
            Text("Check your connection and pull to refresh.")
                .font(.subheadline).foregroundColor(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
    }

    private func loadFeed() async {
        isLoading = true; loadError = false
        let fetched = await FeedManager.shared.fetchReviews()
        articles = fetched; loadError = fetched.isEmpty
        isLoading = false
    }

    private func resolveAbstract(_ article: FeedArticle) async -> String {
        if article.doi != nil, let abstract = await FeedManager.shared.fetchAbstract(for: article) {
            return abstract
        }
        return article.summary
    }
}
