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

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                List {
                    ForEach(store.all) { def in
                        NavigationLink {
                            PlaylistDetailView(def: def)
                        } label: {
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
            .navigationTitle("Playlists")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingCreate = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingCreate) {
                PlaylistEditorSheet { store.add($0) }
            }
        }
    }

    /// Only user-created playlists (offset by 1 for the built-in "Recent") delete.
    private func deleteCustom(at offsets: IndexSet) {
        for i in offsets where i >= 1 { store.delete(store.all[i]) }
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

    @State private var articles: [FeedArticle] = []
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
                else { Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") } }
            }
        }
        .sheet(isPresented: $showingEdit) {
            PlaylistEditorSheet(editing: def) { updated in
                store.update(updated)
                def = updated
                Task { await load() }
            }
        }
        .onAppear { if articles.isEmpty { Task { await load() } } }
        .refreshable { await load() }
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

    private func load() async {
        isLoading = true; loadError = false
        let built = await PlaylistBuilder.articles(for: def)
        articles = built; loadError = built.isEmpty
        isLoading = false
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
        artworkURL = await FeedManager.shared.fetchThumbnail(for: article)
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
    @State private var sources: Set<PlaylistSource> = [.articles]
    @State private var sorts: [PlaylistSort] = [.date]
    /// journal → selected type labels (a journal with ≥1 type is "included").
    @State private var journalTypes: [String: [String]] = [:]

    private let fieldSuggestions = ["Biology", "Chemistry", "Physics", "Medicine",
                                    "Neuroscience", "Genetics", "Immunology", "Climate"]

    var body: some View {
        NavigationView {
            Form {
                Section("Name") {
                    TextField("Playlist name", text: $name)
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

                Section("Include") {
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
                }

                // Journals & per-journal article types
                ForEach(journalCatalog) { group in
                    Section {
                        Button { toggleJournal(group) } label: {
                            HStack {
                                Text(group.journal).fontWeight(.semibold).foregroundColor(.primary)
                                Spacer()
                                Text(isJournalIncluded(group) ? "All" : "Off")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        ForEach(group.types, id: \.self) { t in
                            Button { toggleType(group.journal, t) } label: {
                                HStack {
                                    Text(t.label).foregroundColor(.primary)
                                    Spacer()
                                    if isTypeOn(group.journal, t.label) {
                                        Image(systemName: "checkmark").foregroundColor(.accentColor)
                                    }
                                }
                                .padding(.leading, 8)
                            }
                        }
                    } header: {
                        Text(group.journal)
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
                    Text("Tap in the order you want applied (first = primary sort). Journals/types left untouched include everything.")
                }
            }
            .navigationTitle(editing == nil ? "New Playlist" : "Edit Playlist")
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
        sources = Set(e.sources); sorts = e.sorts.isEmpty ? [.date] : e.sorts
        journalTypes = e.journalTypes
    }

    private func toggleSource(_ s: PlaylistSource) {
        if sources.contains(s) { sources.remove(s) } else { sources.insert(s) }
    }
    private func toggleSort(_ s: PlaylistSort) {
        if let i = sorts.firstIndex(of: s) { sorts.remove(at: i) } else { sorts.append(s) }
    }

    private func isTypeOn(_ journal: String, _ label: String) -> Bool {
        journalTypes[journal]?.contains(label) ?? false
    }
    private func isJournalIncluded(_ g: JournalGroup) -> Bool {
        !(journalTypes[g.journal]?.isEmpty ?? true)
    }
    /// Toggle a single type; also ensure its content source is fetched.
    private func toggleType(_ journal: String, _ t: CatalogType) {
        var arr = journalTypes[journal] ?? []
        if let i = arr.firstIndex(of: t.label) { arr.remove(at: i) } else { arr.append(t.label); sources.insert(t.source) }
        if arr.isEmpty { journalTypes[journal] = nil } else { journalTypes[journal] = arr }
    }
    /// Toggle all of a journal's types on/off.
    private func toggleJournal(_ g: JournalGroup) {
        if isJournalIncluded(g) {
            journalTypes[g.journal] = nil
        } else {
            journalTypes[g.journal] = g.types.map(\.label)
            for t in g.types { sources.insert(t.source) }
        }
    }

    private func save() {
        let def = PlaylistDef(
            id: id,
            name: name.trimmingCharacters(in: .whitespaces),
            topic: topic.trimmingCharacters(in: .whitespacesAndNewlines),
            sources: PlaylistSource.allCases.filter { sources.contains($0) },
            sorts: sorts.isEmpty ? [.date] : sorts,
            journalTypes: journalTypes)
        onSave(def)
        dismiss()
    }
}
