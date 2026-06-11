import SwiftUI

/// Primary research papers — a feed of recent Nature/Science/Cell research
/// articles, plus Europe PMC search (by keyword, author, DOI, or pasted URL).
struct PrimaryView: View {
    @EnvironmentObject var viewModel: PlayerViewModel
    @Binding var selectedTab: Int

    @State private var searchQuery = ""
    @State private var results: [PaperSearchResult] = []
    @State private var isSearching = false
    @State private var hasSearched = false

    @State private var feed: [FeedArticle] = []
    @State private var isLoadingFeed = false
    @State private var feedError = false
    @State private var selectedArticle: FeedArticle? = nil

    private var isSearchActive: Bool {
        !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationView {
            Group {
                if isSearchActive {
                    searchResults
                } else {
                    feedList
                }
            }
            .charcoalBackdrop()
            .navigationTitle("Papers")
            .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Title, keyword, author, DOI…")
            .onSubmit(of: .search) { Task { await search() } }
            .onChange(of: searchQuery) { _, q in
                if q.trimmingCharacters(in: .whitespaces).isEmpty { results = []; hasSearched = false }
            }
            .onAppear { if feed.isEmpty { Task { await loadFeed() } } }
            .refreshable { await loadFeed() }
            .sheet(item: $selectedArticle) { article in
                ArticleDetailSheet(
                    article: article,
                    onReadAbstract: { _ in
                        selectedArticle = nil
                        selectedTab = 0
                        viewModel.status = .fetching
                        Task {
                            let text = await FeedManager.shared.readingText(for: article)
                            viewModel.readText(text, title: article.title)
                        }
                    },
                    onReadFull: {
                        selectedArticle = nil
                        viewModel.load(url: article.url, kind: .primary)
                        selectedTab = 0
                    }
                )
            }
        }
    }

    // MARK: - Feed

    @ViewBuilder
    private var feedList: some View {
        if isLoadingFeed && feed.isEmpty {
            ProgressView("Loading papers…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if feedError && feed.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "wifi.slash").font(.system(size: 44)).foregroundColor(.secondary)
                Text("Could not load papers").font(.subheadline).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(feed) { article in
                ArticleRow(
                    article: article,
                    onTap: { selectedArticle = article },
                    onReadFull: { viewModel.load(url: article.url, kind: .primary); selectedTab = 0 },
                    abstractText: { await FeedManager.shared.readingText(for: article) },
                    onSeminarize: { viewModel.load(url: article.url, kind: .seminar); selectedTab = 0 }
                )
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Search

    @ViewBuilder
    private var searchResults: some View {
        if isSearching {
            ProgressView("Searching Europe PMC…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if hasSearched && results.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 40)).foregroundColor(.secondary)
                Text("No results for \"\(searchQuery)\"").font(.subheadline).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(results) { result in
                SearchResultRow(
                    result: result,
                    onReadFull: { viewModel.load(url: result.articleURL, kind: .primary); selectedTab = 0 },
                    onSeminarize: { viewModel.load(url: result.articleURL, kind: .seminar); selectedTab = 0 }
                )
            }
            .listStyle(.plain)
        }
    }

    private func loadFeed() async {
        isLoadingFeed = true; feedError = false
        let fetched = await FeedManager.shared.fetchPrimary()
        feed = fetched; feedError = fetched.isEmpty
        isLoadingFeed = false
    }

    private func search() async {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        // Pasted URL/DOI → load directly
        if q.hasPrefix("http://") || q.hasPrefix("https://") || q.contains("doi.org") {
            if let url = URL(string: q) {
                viewModel.load(url: url, kind: .primary)
                selectedTab = 0
                searchQuery = ""
                return
            }
        }
        isSearching = true
        results = await FeedManager.shared.search(query: q)
        hasSearched = true
        isSearching = false
    }
}
