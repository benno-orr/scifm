import SwiftUI

// MARK: - Playlists tab
//
// A Spotify-style set of playlists over the scraped feeds. "Recent" is the
// built-in default (recent editorials). Users can create their own playlists
// filtered by scientific field (LLM-matched), document type, and sort order.
// Tracks stream back to back via `PlaylistPlayer`.

struct PlaylistsView: View {
    @Binding var selectedTab: Int
    @ObservedObject private var store = PlaylistStore.shared
    @ObservedObject private var player = PlaylistPlayer.shared
    @State private var showingCreate = false
    @State private var showLibrary = false
    @State private var path: [PlaylistDef] = []

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                List {
                    ForEach(store.all) { def in
                        NavigationLink(value: def) {
                            PlaylistRow(def: def)
                        }
                        .listRowBackground(Color.rowTranslucent)
                    }
                    .onDelete(perform: deleteCustom)
                }
                .listStyle(.plain)

                if player.isActive { NowPlayingBar() }
            }
            .charcoalBackdrop()
            .navigationTitle("Radio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        ForEach(store.all) { def in
                            Button {
                                if path.last != def { path.append(def) }
                            } label: {
                                Label(def.name, systemImage: def.builtIn ? "newspaper" : "shuffle")
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingCreate = true } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { withAnimation(.easeInOut(duration: 0.25)) { showLibrary = true } } label: {
                        Image(systemName: "books.vertical")
                    }
                }
            }
            .navigationDestination(for: PlaylistDef.self) { def in
                PlaylistDetailView(def: def)
            }
            .sheet(isPresented: $showingCreate) {
                PlaylistEditorSheet { store.add($0) }
            }
        }
        .rightDrawer(isOpen: $showLibrary, widthFraction: 0.75) {
            LibraryDrawer(close: { withAnimation(.easeInOut(duration: 0.25)) { showLibrary = false } })
        }
    }

    /// Only user-created playlists (offset by 1 for the built-in "Recent") delete.
    private func deleteCustom(at offsets: IndexSet) {
        for i in offsets where i >= 1 { store.delete(store.all[i]) }
    }
}

// MARK: - Right-side Library drawer (Feedly-style)

/// The Library shown in a slide-out drawer (used from the Radio tab).
struct LibraryDrawer: View {
    let close: () -> Void
    var body: some View {
        NavigationView {
            LibraryListView()
                .navigationTitle("Library")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { close() } label: { Image(systemName: "xmark") }
                    }
                }
        }
    }
}

extension View {
    /// Presents `drawer` as a panel sliding in from the right edge, covering
    /// `widthFraction` of the width, with a dimmed tap-to-dismiss backdrop.
    func rightDrawer<DrawerContent: View>(
        isOpen: Binding<Bool>, widthFraction: CGFloat,
        @ViewBuilder drawer: @escaping () -> DrawerContent) -> some View {
        modifier(RightDrawerModifier(isOpen: isOpen, widthFraction: widthFraction, drawer: drawer))
    }
}

private struct RightDrawerModifier<DrawerContent: View>: ViewModifier {
    @Binding var isOpen: Bool
    let widthFraction: CGFloat
    let drawer: () -> DrawerContent

    func body(content: Content) -> some View {
        content.overlay {
            if isOpen {
                GeometryReader { geo in
                    ZStack(alignment: .trailing) {
                        Color.black.opacity(0.35)
                            .ignoresSafeArea()
                            .onTapGesture { withAnimation(.easeInOut(duration: 0.25)) { isOpen = false } }
                            .transition(.opacity)
                        drawer()
                            .frame(width: geo.size.width * widthFraction)
                            .frame(maxHeight: .infinity)
                            .background(Color(.systemBackground))
                            .transition(.move(edge: .trailing))
                            .gesture(
                                DragGesture().onEnded { v in
                                    if v.translation.width > 60 {
                                        withAnimation(.easeInOut(duration: 0.25)) { isOpen = false }
                                    }
                                }
                            )
                    }
                }
            }
        }
    }
}

// MARK: - Playlist row

private struct PlaylistRow: View {
    let def: PlaylistDef
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.5)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 52, height: 52)
                .overlay(Image(systemName: def.builtIn ? "newspaper.fill" : "shuffle")
                    .font(.headline).foregroundColor(.white))
            VStack(alignment: .leading, spacing: 3) {
                Text(def.name).font(.subheadline).fontWeight(.semibold)
                Text(def.filterSummary)
                    .font(.caption2).foregroundColor(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Playlist detail (track list)

struct PlaylistDetailView: View {
    @State var def: PlaylistDef
    @ObservedObject private var player = PlaylistPlayer.shared
    @ObservedObject private var store = PlaylistStore.shared

    @State private var articles: [FeedArticle] = []   // shown (finished ones removed)
    @State private var allBuilt: [FeedArticle] = []   // full built list
    @State private var finishedURLs: Set<String> = []
    @State private var isLoading = false
    @State private var loadError = false
    @State private var showingEdit = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if isLoading && articles.isEmpty {
                    ProgressView(def.topic.isEmpty ? "Loading…" : "Finding \(def.topic)…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if loadError && articles.isEmpty {
                    emptyError
                } else {
                    list
                }
            }
            if player.isActive { NowPlayingBar() }
        }
        .charcoalBackdrop()
        .navigationTitle(def.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !def.builtIn {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Edit") { showingEdit = true }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if isLoading { ProgressView().scaleEffect(0.8) }
                else { Button { Task { await load(forceRebuild: true) } } label: { Image(systemName: "arrow.clockwise") } }
            }
        }
        .sheet(isPresented: $showingEdit) {
            PlaylistEditorSheet(editing: def) { updated in
                store.update(updated)
                def = updated
                Task { await load() }
            }
        }
        .onAppear { if allBuilt.isEmpty { Task { await load() } } }
        .refreshable { await load(forceRebuild: true) }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in
            Task { finishedURLs = await LibraryManager.shared.finishedSourceURLs(); applyFilter() }
        }
    }

    /// Hides articles already listened to the end (marked read in the Library).
    private func applyFilter() {
        articles = allBuilt.filter { !finishedURLs.contains($0.url.absoluteString) }
    }

    private var list: some View {
        List {
            Section { headerCard.listRowBackground(Color.clear) }
            Section {
                ForEach(Array(articles.enumerated()), id: \.element.id) { idx, article in
                    trackRow(index: idx, article: article)
                        .listRowBackground(Color.rowTranslucent)
                        .contentShape(Rectangle())
                        .onTapGesture { player.play(playlist: def.name, articles: articles, startAt: idx) }
                }
            } header: {
                Text("\(articles.count) item\(articles.count == 1 ? "" : "s")")
                    .foregroundColor(.secondary)
            }
        }
        .listStyle(.plain)
    }

    private var headerCard: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.5)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 84, height: 84)
                .overlay(Image(systemName: def.builtIn ? "newspaper.fill" : "shuffle")
                    .font(.system(size: 32)).foregroundColor(.white))
            VStack(alignment: .leading, spacing: 4) {
                Text(def.name).font(.title3).fontWeight(.bold)
                Text(def.filterSummary).font(.caption).foregroundColor(.secondary).lineLimit(2)
                Button {
                    if isActivePlaylist { player.togglePlayPause() }
                    else { player.play(playlist: def.name, articles: articles, startAt: 0) }
                } label: {
                    Label(playLabel, systemImage: playIcon)
                        .font(.subheadline).fontWeight(.semibold)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(Color.accentColor).foregroundColor(.white).clipShape(Capsule())
                }
                .buttonStyle(.plain).padding(.top, 2)
                .disabled(articles.isEmpty)
            }
            Spacer(minLength: 0)
        }
    }

    private var isActivePlaylist: Bool { player.isActive && player.playlistName == def.name }
    private var playLabel: String {
        if isActivePlaylist && player.state == .playing { return "Pause" }
        if isActivePlaylist && player.state == .paused { return "Resume" }
        return "Play All"
    }
    private var playIcon: String {
        isActivePlaylist && player.state == .playing ? "pause.fill" : "play.fill"
    }

    private func trackRow(index: Int, article: FeedArticle) -> some View {
        let isCurrent = player.playlistName == def.name && player.isCurrent(article.id)
        return HStack(spacing: 12) {
            ZStack {
                if isCurrent {
                    Image(systemName: player.state == .loading ? "waveform"
                          : player.state == .playing ? "speaker.wave.2.fill" : "speaker.fill")
                        .foregroundColor(.accentColor)
                } else {
                    Text("\(index + 1)").foregroundColor(.secondary).font(.footnote.monospacedDigit())
                }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(article.title).font(.subheadline).lineLimit(2)
                    .foregroundColor(isCurrent ? .accentColor : .primary)
                HStack(spacing: 4) {
                    Text(article.source); Text("·"); Text(article.label)
                }
                .font(.caption2).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var emptyError: some View {
        VStack(spacing: 16) {
            Image(systemName: def.topic.isEmpty ? "wifi.slash" : "magnifyingglass")
                .font(.system(size: 48)).foregroundColor(.secondary)
            Text(def.topic.isEmpty ? "Could not load" : "Nothing matched \"\(def.topic)\"")
                .font(.headline)
            Text("Pull to refresh.")
                .font(.subheadline).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load(forceRebuild: Bool = false) async {
        isLoading = true; loadError = false

        // Prefer the saved snapshot: reopening a station loads instantly with no
        // feed re-fetch, no LLM re-classification, and no re-scrape. Only rebuild
        // when explicitly refreshed or when there's no snapshot yet.
        if !forceRebuild, let saved = await PlaylistSnapshotStore.shared.articles(for: def.id.uuidString) {
            allBuilt = saved
        } else {
            allBuilt = await PlaylistBuilder.articles(for: def)
            if !allBuilt.isEmpty {
                await PlaylistSnapshotStore.shared.store(allBuilt, for: def.id.uuidString)
            }
        }

        finishedURLs = await LibraryManager.shared.finishedSourceURLs()
        applyFilter()
        loadError = allBuilt.isEmpty
        isLoading = false
        // Pre-scrape full text + images for every article now, so playback never
        // hits a paywall (uses the logged-in session via hidden web views).
        // Cached URLs are skipped, so this is a no-op once everything is scraped.
        HeadlessScraper.shared.enqueue(articles.map(\.url))
    }
}

// MARK: - Landscape full-screen artwork

/// When the phone is rotated to landscape while a playlist is playing, the
/// current track's scraped image fills the screen (tap to play/pause).
struct LandscapeArtworkOverlay: View {
    @ObservedObject private var player = PlaylistPlayer.shared
    @Environment(\.verticalSizeClass) private var vSize
    @State private var artworkURL: URL? = nil

    var body: some View {
        if vSize == .compact, player.isActive {
            ZStack {
                Color.black.ignoresSafeArea()
                if let artworkURL {
                    AsyncImage(url: artworkURL) { phase in
                        if case .success(let img) = phase {
                            img.resizable().scaledToFit()
                        } else {
                            Image(systemName: "newspaper").font(.system(size: 60)).foregroundColor(.secondary)
                        }
                    }
                } else {
                    Image(systemName: "newspaper").font(.system(size: 60)).foregroundColor(.secondary)
                }
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { player.togglePlayPause() }
            .task(id: player.current?.id) {
                if let a = player.current {
                    if let local = await ScrapedStore.shared.imageURL(for: a.url.absoluteString) {
                        artworkURL = local
                    } else {
                        artworkURL = await FeedManager.shared.fetchThumbnail(for: a)
                    }
                }
            }
        }
    }
}

// MARK: - Now-playing bar (shared)

struct NowPlayingBar: View {
    @ObservedObject private var player = PlaylistPlayer.shared
    @State private var artworkURL: URL? = nil

    var body: some View {
        VStack(spacing: 12) {
            artwork
            VStack(spacing: 3) {
                Text(player.current?.title ?? "—")
                    .font(.subheadline).fontWeight(.semibold).lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(player.state == .loading ? "Loading…" : (player.current?.source ?? player.playlistName))
                    .font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            HStack(spacing: 44) {
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill").font(.title2).frame(width: 44, height: 44)
                }.buttonStyle(.plain)
                Button { player.togglePlayPause() } label: {
                    if player.state == .loading {
                        ProgressView().scaleEffect(0.9).frame(width: 48, height: 48)
                    } else {
                        Image(systemName: player.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 46)).frame(width: 48, height: 48)
                    }
                }.buttonStyle(.plain)
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.title2).frame(width: 44, height: 44)
                }.buttonStyle(.plain)
            }
        }
        .foregroundColor(.primary)
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .topLeading) {
            Button { player.toggleReadLaterForCurrent() } label: {
                Image(systemName: player.isCurrentReadLater ? "bookmark.fill" : "bookmark")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundColor(player.isCurrentReadLater ? .accentColor : .secondary)
            .padding(10)
        }
        .overlay(alignment: .topTrailing) {
            Button { player.stop() } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                .buttonStyle(.plain).foregroundColor(.secondary).padding(10)
        }
        .task(id: player.current?.id) { await loadArtwork() }
    }

    @ViewBuilder private var artwork: some View {
        if let artworkURL {
            AsyncImage(url: artworkURL) { phase in
                switch phase {
                case .success(let img): img.resizable().aspectRatio(contentMode: .fit)
                case .empty: ProgressView()
                default: placeholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 180)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            placeholder
                .frame(maxWidth: .infinity).frame(height: 120)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var placeholder: some View {
        Image(systemName: "newspaper").font(.largeTitle).foregroundColor(.secondary)
    }

    private func loadArtwork() async {
        guard let article = player.current else { artworkURL = nil; return }
        if let local = await ScrapedStore.shared.imageURL(for: article.url.absoluteString) {
            artworkURL = local
        } else {
            artworkURL = await FeedManager.shared.fetchThumbnail(for: article)
        }
    }
}

// MARK: - Create / edit playlist sheet

struct PlaylistEditorSheet: View {
    /// When non-nil, the sheet edits this playlist instead of creating one.
    var editing: PlaylistDef? = nil
    let onSave: (PlaylistDef) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var id = UUID()
    @State private var name = ""
    @State private var topic = ""
    @State private var journals: [String] = []
    @State private var sources: Set<PlaylistSource> = [.articles]
    @State private var sorts: [PlaylistSort] = [.date]
    /// journal → explicit type-label override (absent = derive from `sources`).
    @State private var journalTypes: [String: [String]] = [:]
    @State private var detailExpanded = false

    private let fieldSuggestions = ["Biology", "Chemistry", "Physics", "Medicine",
                                    "Neuroscience", "Genetics", "Immunology", "Climate"]

    var body: some View {
        NavigationView {
            Form {
                Section("Name") {
                    TextField("Station name", text: $name)
                }

                Section {
                    TextField("e.g. immunology, CRISPR, astrophysics", text: $topic)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(fieldSuggestions, id: \.self) { f in
                                Button { topic = f } label: {
                                    Text(f).font(.caption)
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(topic.caseInsensitiveCompare(f) == .orderedSame
                                                    ? Color.accentColor : Color.accentColor.opacity(0.15))
                                        .foregroundColor(topic.caseInsensitiveCompare(f) == .orderedSame
                                                         ? .white : .accentColor)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Field / domain")
                } footer: {
                    Text("Leave blank for everything. Can be broad (biology) or specific (single-cell RNA-seq). Matched by an LLM.")
                }

                // 1) Journals to include (empty = all journals). Multi-select menu.
                Section {
                    Menu {
                        ForEach(journalCatalog.map(\.journal), id: \.self) { j in
                            Button { toggleJournal(j) } label: {
                                Label(j, systemImage: journals.contains(j) ? "checkmark" : "")
                            }
                        }
                    } label: {
                        HStack {
                            Text("Journals")
                            Spacer()
                            Text(journals.isEmpty ? "All" : journals.joined(separator: ", "))
                                .foregroundColor(.secondary).lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                } footer: {
                    Text(journals.isEmpty ? "No journals selected — includes all journals." : "Only the selected journals are included.")
                }

                // 2) General rules: which content types to include by default.
                Section {
                    ForEach(PlaylistSource.allCases) { src in
                        Button { toggleSource(src) } label: {
                            HStack {
                                Text(src.label).foregroundColor(.primary)
                                Spacer()
                                if sources.contains(src) {
                                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Include")
                } footer: {
                    Text("Sets the default article types per journal below.")
                }

                // 3) Per-journal override (collapsed by default).
                if !journals.isEmpty {
                    Section {
                        DisclosureGroup("Detailed selection", isExpanded: $detailExpanded) {
                            ForEach(journals, id: \.self) { j in
                                Text(j).font(.caption.weight(.semibold)).foregroundColor(.secondary)
                                ForEach(typesFor(j), id: \.self) { t in
                                    Button { toggleType(j, t) } label: {
                                        HStack {
                                            Text(t.label).foregroundColor(.primary)
                                            Spacer()
                                            if isTypeChecked(j, t) {
                                                Image(systemName: "checkmark").foregroundColor(.accentColor)
                                            }
                                        }
                                        .padding(.leading, 8)
                                    }
                                }
                            }
                        }
                    } footer: {
                        Text("Overrides the general rules for specific journals. Defaults match the Include settings above.")
                    }
                }

                Section {
                    ForEach(PlaylistSort.allCases) { s in
                        Button { toggleSort(s) } label: {
                            HStack {
                                Text(s.label).foregroundColor(.primary)
                                Spacer()
                                if let pos = sorts.firstIndex(of: s) {
                                    Text("\(pos + 1)")
                                        .font(.caption.monospacedDigit()).foregroundColor(.white)
                                        .frame(width: 20, height: 20)
                                        .background(Color.accentColor).clipShape(Circle())
                                }
                            }
                        }
                    }
                } header: {
                    Text("Sort by")
                } footer: {
                    Text("Tap in the order you want applied (first = primary sort).")
                }
            }
            .navigationTitle(editing == nil ? "New Station" : "Edit Station")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
            .onAppear(perform: prefill)
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !sources.isEmpty
    }

    private func prefill() {
        guard let e = editing else { return }
        id = e.id; name = e.name; topic = e.topic
        journals = e.journals
        sources = Set(e.sources); sorts = e.sorts.isEmpty ? [.date] : e.sorts
        journalTypes = e.journalTypes
    }

    // Journals
    private func toggleJournal(_ j: String) {
        if journals.contains(j) {
            journals.removeAll { $0 == j }
            journalTypes[j] = nil          // drop any per-journal override
        } else {
            journals.append(j)
        }
    }
    private func typesFor(_ journal: String) -> [CatalogType] {
        journalCatalog.first { $0.journal == journal }?.types ?? []
    }

    private func toggleSource(_ s: PlaylistSource) {
        if sources.contains(s) { sources.remove(s) } else { sources.insert(s) }
    }
    private func toggleSort(_ s: PlaylistSort) {
        if let i = sorts.firstIndex(of: s) { sorts.remove(at: i) } else { sorts.append(s) }
    }

    /// Default included labels for a journal from the general rules (no override).
    private func defaultLabels(_ journal: String) -> [String] {
        typesFor(journal).filter { sources.contains($0.source) }.map(\.label)
    }
    /// Checked = explicit override membership, else the general-rule default.
    private func isTypeChecked(_ journal: String, _ t: CatalogType) -> Bool {
        if let override = journalTypes[journal] { return override.contains(t.label) }
        return sources.contains(t.source)
    }
    /// Toggling a type makes the journal's selection an explicit override.
    private func toggleType(_ journal: String, _ t: CatalogType) {
        var set = journalTypes[journal] ?? defaultLabels(journal)
        if let i = set.firstIndex(of: t.label) { set.remove(at: i) } else { set.append(t.label) }
        journalTypes[journal] = set
    }

    private func save() {
        // Drop overrides for journals no longer selected.
        let pruned = journalTypes.filter { journals.contains($0.key) }
        let def = PlaylistDef(
            id: id,
            name: name.trimmingCharacters(in: .whitespaces),
            topic: topic.trimmingCharacters(in: .whitespacesAndNewlines),
            journals: journals,
            sources: PlaylistSource.allCases.filter { sources.contains($0) },
            sorts: sorts.isEmpty ? [.date] : sorts,
            journalTypes: pruned)
        onSave(def)
        dismiss()
    }
}
