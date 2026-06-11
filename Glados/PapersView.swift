import SwiftUI

struct PapersView: View {
    @EnvironmentObject var viewModel: PlayerViewModel
    @Binding var selectedTab: Int

    @State private var searchQuery = ""
    @State private var results: [PaperSearchResult] = []
    @State private var isSearching = false
    @State private var hasSearched = false

    var body: some View {
        NavigationView {
            Group {
                if isSearching {
                    ProgressView("Searching Europe PMC…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if hasSearched && results.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").font(.system(size: 40)).foregroundColor(.secondary)
                        Text("No results for \"\(searchQuery)\"").font(.subheadline).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !results.isEmpty {
                    List(results) { result in
                        SearchResultRow(result: result) {
                            viewModel.load(url: result.articleURL, kind: .primary)
                            selectedTab = 0
                        }
                    }
                    .listStyle(.plain)
                } else {
                    prompt
                }
            }
            .navigationTitle("Papers")
            .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .always), prompt: "Title, keyword, author, DOI…")
            .onSubmit(of: .search) { Task { await search() } }
            .onChange(of: searchQuery) { _, q in
                if q.trimmingCharacters(in: .whitespaces).isEmpty { results = []; hasSearched = false }
            }
        }
    }

    private var prompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 52)).foregroundColor(.accentColor)
            Text("Search Papers").font(.headline)
            Text("Search by title, keyword, author, or DOI.\nOr paste any paper URL and press return.")
                .font(.subheadline).foregroundColor(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func search() async {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }

        // URL pasted → load directly
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

// MARK: - Search result row

struct SearchResultRow: View {
    let result: PaperSearchResult
    let onReadFull: () -> Void
    var onSeminarize: (() -> Void)? = nil
    /// Papers layout: tapping the row reads the full doc; speaker + seminarize
    /// stacked vertically on the right (no doc button).
    var stacked: Bool = false

    @ObservedObject private var abstractPlayer = AbstractPlayer.shared
    @State private var thumbnailURL: URL? = nil

    private var isThisPlaying: Bool { abstractPlayer.playingID == result.id }
    private var isThisLoading: Bool { abstractPlayer.state == .loading && abstractPlayer.playingID == result.id }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onReadFull) { ThumbnailView(url: thumbnailURL) }
                .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                Button(action: onReadFull) {
                    Text(result.title)
                        .font(.subheadline).lineLimit(3)
                        .foregroundColor(.primary).multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                if !result.authors.isEmpty {
                    Text(result.authors).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if !result.journal.isEmpty {
                        Text(result.journal).fontWeight(.semibold).foregroundColor(.accentColor).lineLimit(1)
                    }
                    if !result.year.isEmpty { Text("·"); Text(result.year) }
                    if !stacked {
                        Spacer()
                        if !result.abstract.isEmpty { speakerButton }
                        Button(action: onReadFull) {
                            Image(systemName: "doc.text").foregroundColor(.secondary).frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        if let onSeminarize { seminarizeButton(onSeminarize) }
                    }
                }
                .font(.caption2).foregroundColor(.secondary)
            }

            if stacked {
                Spacer(minLength: 4)
                VStack(spacing: 12) {
                    if !result.abstract.isEmpty { speakerButton }
                    if let onSeminarize { seminarizeButton(onSeminarize) }
                }
            }
        }
        .padding(.vertical, 6)
        .task { if thumbnailURL == nil { thumbnailURL = await FeedManager.shared.fetchThumbnail(for: result.articleURL) } }
    }

    private var speakerButton: some View {
        Button {
            abstractPlayer.toggle(id: result.id, text: result.abstract)
        } label: {
            Group {
                if isThisLoading { ProgressView().scaleEffect(0.7) }
                else if isThisPlaying { Image(systemName: "speaker.wave.2.fill") }
                else { Image(systemName: "speaker.wave.2") }
            }
            .foregroundColor(.accentColor)
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
    }

    private func seminarizeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "rectangle.3.group").foregroundColor(.secondary).frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
    }
}
