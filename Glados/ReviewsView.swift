import SwiftUI

struct ReviewsView: View {
    @EnvironmentObject var viewModel: PlayerViewModel
    @Binding var selectedTab: Int

    @State private var articles: [FeedArticle] = []
    @State private var isLoading = false
    @State private var loadError = false
    @State private var selectedArticle: FeedArticle? = nil

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
                            onTap: { selectedArticle = article },
                            onReadFull: { viewModel.load(url: article.url, kind: .review); selectedTab = 0 },
                            abstractText: { await resolveAbstract(article) }
                        )
                    }
                    .listStyle(.plain)
                }
            }
            .charcoalBackdrop()
            .navigationTitle("Reviews")
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
            .sheet(item: $selectedArticle) { article in
                ArticleDetailSheet(
                    article: article,
                    onReadAbstract: { abstract in
                        selectedArticle = nil
                        viewModel.readText(abstract, title: article.title)
                        selectedTab = 0
                    },
                    onReadFull: {
                        selectedArticle = nil
                        viewModel.load(url: article.url, kind: .review)
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
