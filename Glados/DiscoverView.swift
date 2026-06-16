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
                            onReadFull: { viewModel.load(url: article.url, kind: .editorial); selectedTab = 0 },
                            abstractText: { await resolveAbstract(article) }
                        )
                        .listRowBackground(Color.rowTranslucent)
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
                        viewModel.load(url: article.url, kind: .editorial)
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
        await FeedManager.shared.readingText(for: article)
    }
}

// MARK: - Article row (shared with PapersView)

struct ArticleRow: View {
    let article: FeedArticle
    let onTap: () -> Void
    let onReadFull: () -> Void
    let abstractText: () async -> String
    var onSeminarize: (() -> Void)? = nil
    /// Papers layout: tapping the row reads the full doc, and the speaker +
    /// seminarize actions are stacked vertically on the right (no doc button).
    var stacked: Bool = false

    @ObservedObject private var abstractPlayer = AbstractPlayer.shared
    @State private var thumbnailURL: URL? = nil

    private var isThisPlaying: Bool { abstractPlayer.playingID == article.id }
    private var isThisLoading: Bool { abstractPlayer.state == .loading && abstractPlayer.playingID == article.id }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onTap) { ThumbnailView(url: thumbnailURL) }
                .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Button(action: onTap) {
                    Text(article.title)
                        .font(.subheadline).lineLimit(3)
                        .foregroundColor(.primary).multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)

                HStack(alignment: .center, spacing: 6) {
                    // Journal and article type on sequential lines
                    VStack(alignment: .leading, spacing: 1) {
                        Text(article.source).fontWeight(.semibold).foregroundColor(.accentColor)
                        HStack(spacing: 4) {
                            Text(article.label)
                            if let date = article.publishedDate {
                                Text("·"); Text(timeSince(date))
                            }
                        }
                        .foregroundColor(.secondary)
                    }
                    .font(.caption2)

                    if !stacked {
                        Spacer()
                        speakerButton
                        Button(action: onReadFull) {
                            Image(systemName: "doc.text").foregroundColor(.secondary).frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        if let onSeminarize { seminarizeButton(onSeminarize) }
                    }
                }
            }

            if stacked {
                Spacer(minLength: 4)
                VStack(spacing: 12) {
                    speakerButton
                    if let onSeminarize { seminarizeButton(onSeminarize) }
                }
            }
        }
        .padding(.vertical, 6)
        .task { if thumbnailURL == nil { thumbnailURL = await FeedManager.shared.fetchThumbnail(for: article) } }
    }

    /// Compact time since publication, no "ago". Past 24h, days only.
    private func timeSince(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }

    private var speakerButton: some View {
        Button {
            Task {
                if isThisPlaying { abstractPlayer.stop(); return }
                let text = await abstractText()
                guard !text.isEmpty else { return }
                abstractPlayer.toggle(id: article.id, text: text)
            }
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
    var onExportDoc: (() -> Void)? = nil

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
                        if let onExportDoc {
                            Button { onExportDoc() } label: {
                                Label("Export Markdown", systemImage: "doc.badge.arrow.up")
                                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                                    .background(Color.accentColor.opacity(0.12)).cornerRadius(10)
                            }
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

// MARK: - Charcoal theme

extension View {
    /// Charcoal gradient backdrop with a transparent scroll background, for the
    /// app's dark theme. No-op on non-scrolling views beyond the background.
    func charcoalBackdrop() -> some View { modifier(CharcoalBackdrop()) }
}

extension Color {
    /// Semi-transparent row fill so the background watermark shows through.
    static let rowTranslucent = Color(white: 0.10).opacity(0.4)
}

private struct CharcoalBackdrop: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(
                ZStack {
                    LinearGradient(
                        colors: [Color(red: 0.11, green: 0.11, blue: 0.12),
                                 Color(red: 0.04, green: 0.04, blue: 0.05)],
                        startPoint: .top, endPoint: .bottom)
                    RadialGradient(
                        colors: [Color.white.opacity(0.05), .clear],
                        center: .top, startRadius: 0, endRadius: 520)
                    GeometryReader { geo in
                        Image("LogoMark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width * 1.5)
                            .opacity(0.25)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
                .ignoresSafeArea()
            )
    }
}
