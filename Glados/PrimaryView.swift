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

    @ObservedObject private var hidden = HiddenPapers.shared
    @AppStorage("showHiddenPapers") private var showHidden = false

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
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Title, keyword, author, DOI…")
            .onSubmit(of: .search) { Task { await search() } }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showHidden.toggle() } label: {
                        Image(systemName: showHidden ? "eye" : "eye.slash")
                    }
                }
            }
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
            // When "show hidden" is off, drop hidden papers entirely; when on,
            // keep them but render greyed.
            let shown = showHidden ? feed : feed.filter { !hidden.isHidden($0.id) }
            List(shown) { article in
                let isHidden = hidden.isHidden(article.id)
                ArticleRow(
                    article: article,
                    onTap: { viewModel.load(url: article.url, kind: .primary); selectedTab = 0 },
                    onReadFull: { viewModel.load(url: article.url, kind: .primary); selectedTab = 0 },
                    abstractText: { await FeedManager.shared.readingText(for: article) },
                    onSeminarize: { viewModel.debugFigureURL = article.url; selectedTab = 4 },
                    stacked: true
                )
                .listRowBackground(Color.rowTranslucent)
                .grayscale(isHidden ? 1 : 0)
                .opacity(isHidden ? 0.45 : 1)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if isHidden {
                        Button { hidden.unhide(article.id) } label: { Label("Unhide", systemImage: "eye") }
                            .tint(.blue)
                    } else {
                        Button { hidden.hide(article.id) } label: { Label("Hide", systemImage: "eye.slash") }
                            .tint(.gray)
                    }
                }
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
                    onSeminarize: { viewModel.debugFigureURL = result.articleURL; selectedTab = 4 },
                    stacked: true
                )
                .listRowBackground(Color.rowTranslucent)
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

// MARK: - Hidden papers store

/// Persists the set of paper IDs the user has hidden from the Papers feed.
@MainActor
final class HiddenPapers: ObservableObject {
    static let shared = HiddenPapers()
    @Published private(set) var ids: Set<String> = []
    private let key = "hiddenPaperIDs"

    private init() {
        if let arr = UserDefaults.standard.array(forKey: key) as? [String] { ids = Set(arr) }
    }

    func isHidden(_ id: String) -> Bool { ids.contains(id) }
    func hide(_ id: String)   { ids.insert(id); save() }
    func unhide(_ id: String) { ids.remove(id); save() }

    private func save() { UserDefaults.standard.set(Array(ids), forKey: key) }
}
