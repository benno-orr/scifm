import SwiftUI

struct DiscoverView: View {
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
                    ProgressView("Loading feeds…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if loadError && articles.isEmpty {
                    emptyError
                } else {
                    List(articles) { article in
                        ArticleRow(
                            article: article,
                            onTap: { selectedArticle = article },
                            onReadFull: { viewModel.load(url: article.url); selectedTab = 0 },
                            abstractText: { await resolveAbstract(article) }
                        )
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Digest")
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
                        viewModel.load(url: article.url)
                        selectedTab = 0
                    }
                )
            }
        }
    }

    private var emptyError: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash").font(.system(size: 48)).foregroundColor(.secondary)
            Text("Could not load feeds").font(.headline)
            Text("Check your connection and pull to refresh.")
                .font(.subheadline).foregroundColor(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
    }

    private func loadFeed() async {
        isLoading = true; loadError = false
        let fetched = await FeedManager.shared.fetchAll()
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

// MARK: - Article row (shared with PapersView)

struct ArticleRow: View {
    let article: FeedArticle
    let onTap: () -> Void
    let onReadFull: () -> Void
    let abstractText: () async -> String

    @ObservedObject private var abstractPlayer = AbstractPlayer.shared
    @State private var thumbnailURL: URL? = nil

    private var isThisPlaying: Bool { abstractPlayer.playingID == article.id }
    private var isThisLoading: Bool { abstractPlayer.state == .loading && abstractPlayer.playingID == article.id }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Thumbnail
            Button(action: onTap) {
                ThumbnailView(url: thumbnailURL)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                // Title
                Button(action: onTap) {
                    Text(article.title)
                        .font(.subheadline).lineLimit(3)
                        .foregroundColor(.primary).multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)

                // Meta + action icons
                HStack(spacing: 6) {
                    Text(article.source).fontWeight(.semibold).foregroundColor(.accentColor)
                    Text("·")
                    Text(article.label)
                    if let date = article.publishedDate {
                        Text("·")
                        Text(date, style: .relative)
                        Text("ago")
                    }
                    Spacer()
                    // Speaker icon — play/stop abstract
                    Button {
                        Task {
                            if isThisPlaying { abstractPlayer.stop(); return }
                            let text = await abstractText()
                            guard !text.isEmpty else { return }
                            abstractPlayer.toggle(id: article.id, text: text)
                        }
                    } label: {
                        Group {
                            if isThisLoading {
                                ProgressView().scaleEffect(0.7)
                            } else if isThisPlaying {
                                Image(systemName: "speaker.wave.2.fill")
                            } else {
                                Image(systemName: "speaker.wave.2")
                            }
                        }
                        .foregroundColor(.accentColor)
                        .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)

                    // Full article
                    Button(action: onReadFull) {
                        Image(systemName: "doc.text")
                            .foregroundColor(.secondary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                }
                .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 6)
        .task { if thumbnailURL == nil { thumbnailURL = await FeedManager.shared.fetchThumbnail(for: article) } }
    }
}

// MARK: - Shared thumbnail view

struct ThumbnailView: View {
    let url: URL?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color(.secondarySystemBackground))
            if let url {
                AsyncImage(url: url) { phase in
                    if case .success(let img) = phase {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "doc.richtext").font(.title2).foregroundColor(.secondary)
                    }
                }
            } else {
                Image(systemName: "doc.richtext").font(.title2).foregroundColor(.secondary)
            }
        }
        .frame(width: 70, height: 70).clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Detail sheet

struct ArticleDetailSheet: View {
    let article: FeedArticle
    let onReadAbstract: (String) -> Void
    let onReadFull: () -> Void

    @State private var abstract: String? = nil
    @State private var isFetching = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 6) {
                        Text(article.source).fontWeight(.semibold).foregroundColor(.accentColor)
                        Text("·"); Text(article.label)
                        if let date = article.publishedDate {
                            Text("·"); Text(date, style: .relative); Text("ago")
                        }
                    }
                    .font(.caption).foregroundColor(.secondary)

                    Text(article.title).font(.headline)
                    Divider()

                    if isFetching {
                        HStack { ProgressView(); Text("Fetching abstract…").font(.caption).foregroundColor(.secondary) }
                    } else if let abstract {
                        Text(abstract).font(.subheadline)
                    } else {
                        Text(article.summary.isEmpty ? "Abstract not available." : article.summary)
                            .font(.subheadline).foregroundColor(.secondary)
                    }

                    Divider()
                    VStack(spacing: 10) {
                        if let abstract, !abstract.isEmpty {
                            Button { onReadAbstract(abstract) } label: {
                                Label("Read Abstract", systemImage: "text.bubble")
                                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                                    .background(Color.accentColor.opacity(0.12)).cornerRadius(10)
                            }
                        }
                        Button { onReadFull() } label: {
                            Label("Read Full Article", systemImage: "doc.text")
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(Color.accentColor).foregroundColor(.white).cornerRadius(10)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Abstract").navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("Done") { dismiss() })
        }
        .onAppear { Task { await fetchAbstract() } }
    }

    private func fetchAbstract() async {
        guard abstract == nil, article.doi != nil else { return }
        isFetching = true
        abstract = await FeedManager.shared.fetchAbstract(for: article)
        isFetching = false
    }
}
