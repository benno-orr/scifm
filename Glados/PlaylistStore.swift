import Foundation

// MARK: - Playlist definition

/// Which kinds of documents a playlist pulls in.
enum PlaylistSource: String, Codable, CaseIterable, Identifiable {
    case articles    // editorials / commentaries (the Comms feed)
    case abstracts   // abstracts of primary research papers
    var id: String { rawValue }
    var label: String {
        switch self {
        case .articles:  return "Articles"
        case .abstracts: return "Abstracts (primary papers)"
        }
    }
}

/// A sort dimension. Playlists can combine several in priority order.
enum PlaylistSort: String, Codable, CaseIterable, Identifiable {
    case date, type
    var id: String { rawValue }
    var label: String { self == .date ? "Date (newest first)" : "Type" }
    var shortLabel: String { self == .date ? "Date" : "Type" }
}

/// A user-defined (or built-in) playlist: a filter over the scraped feeds.
struct PlaylistDef: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// Free-text scientific domain/field to filter on (LLM-matched). "" = no filter.
    var topic: String = ""
    /// Journals included in this station. Empty = all journals (the default feed).
    var journals: [String] = []
    /// General content-type rules. Default included types per selected journal are
    /// derived from this (overridable per-journal via `journalTypes`).
    var sources: [PlaylistSource] = [.articles]
    var sorts: [PlaylistSort] = [.date]
    /// Per-journal article-type override (journal name → type labels). A journal
    /// absent here uses the default derived from `sources`; present = explicit override.
    var journalTypes: [String: [String]] = [:]
    var builtIn: Bool = false

    /// The default station: recent editorials, newest first, no domain filter.
    static let recent = PlaylistDef(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Recent", topic: "", journals: [], sources: [.articles], sorts: [.date], builtIn: true)

    /// Article types included for `journal` by the general rules alone (no override):
    /// every catalog type of that journal whose content source is enabled.
    func defaultTypes(for journal: String) -> [String] {
        journalCatalog.first { $0.journal == journal }?.types
            .filter { sources.contains($0.source) }.map(\.label) ?? []
    }

    /// The effective included types for `journal`: the explicit override if set,
    /// else the general-rule default.
    func resolvedTypes(for journal: String) -> [String] {
        journalTypes[journal] ?? defaultTypes(for: journal)
    }

    /// One-line description of the filters, shown under the station name.
    var filterSummary: String {
        var parts: [String] = []
        if !topic.isEmpty { parts.append(topic) }
        if journals.isEmpty {
            parts.append(sources.map(\.label).joined(separator: " + "))
        } else {
            parts.append(journals.joined(separator: ", "))
        }
        if !sorts.isEmpty { parts.append("by " + sorts.map(\.shortLabel).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Journal / article-type catalog

/// One selectable article type and which content source it comes from.
struct CatalogType: Hashable { let label: String; let source: PlaylistSource }

/// A journal and the article types it publishes into the playlist feeds.
struct JournalGroup: Identifiable {
    var id: String { journal }
    let journal: String
    let types: [CatalogType]
}

/// The journals (matching `FeedArticle.source`) and article types available to
/// playlists, grouped for the editor's nested checkboxes.
let journalCatalog: [JournalGroup] = [
    JournalGroup(journal: "Nature", types: [
        CatalogType(label: "Research Briefing", source: .articles),
        CatalogType(label: "Research Highlight", source: .articles),
        CatalogType(label: "Research Article", source: .abstracts),
    ]),
    JournalGroup(journal: "Science", types: [
        CatalogType(label: "Perspective", source: .articles),
        CatalogType(label: "Research Article", source: .abstracts),
    ]),
    JournalGroup(journal: "Cell", types: [
        CatalogType(label: "Highlights", source: .articles),
        CatalogType(label: "Article", source: .abstracts),
    ]),
    JournalGroup(journal: "Nature Biotechnology", types: [
        CatalogType(label: "Article", source: .abstracts),
    ]),
]

// MARK: - Store

/// Persists user-created playlists in UserDefaults. The built-in "Recent"
/// playlist is always first and is not stored.
@MainActor
final class PlaylistStore: ObservableObject {
    static let shared = PlaylistStore()

    @Published private(set) var custom: [PlaylistDef] = []
    private let key = "userPlaylists.v1"

    var all: [PlaylistDef] { [.recent] + custom }

    init() { load() }

    func add(_ def: PlaylistDef) { custom.append(def); save() }

    func update(_ def: PlaylistDef) {
        guard let i = custom.firstIndex(where: { $0.id == def.id }) else { return }
        custom[i] = def; save()
        // Filters changed → the saved article list is stale.
        let id = def.id.uuidString
        Task { await PlaylistSnapshotStore.shared.remove(id) }
    }

    func delete(_ def: PlaylistDef) {
        custom.removeAll { $0.id == def.id }; save()
        let id = def.id.uuidString
        Task { await PlaylistSnapshotStore.shared.remove(id) }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([PlaylistDef].self, from: data) else { return }
        custom = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - Snapshot store

/// Persists the *resolved* article list for each station to disk, so reopening a
/// station loads instantly (no feed re-fetch, no LLM re-classification, no
/// re-scrape). Rebuilt only on an explicit refresh. Keyed by playlist id.
actor PlaylistSnapshotStore {
    static let shared = PlaylistSnapshotStore()

    private var map: [String: [FeedArticle]] = [:]
    private var loaded = false

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("playlist_snapshots.json")
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: [FeedArticle]].self, from: data) {
            map = decoded
        }
        loaded = true
    }

    /// Saved article list for a station, if one exists.
    func articles(for id: String) -> [FeedArticle]? {
        loadIfNeeded()
        return map[id]
    }

    func store(_ articles: [FeedArticle], for id: String) {
        loadIfNeeded()
        map[id] = articles
        persist()
    }

    func remove(_ id: String) {
        loadIfNeeded()
        map[id] = nil
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: fileURL) }
    }
}

// MARK: - Builder

/// Resolves a `PlaylistDef` into a concrete, filtered, sorted list of articles.
enum PlaylistBuilder {
    static func articles(for def: PlaylistDef) async -> [FeedArticle] {
        // Which content sources we actually need to fetch. With journals chosen,
        // it's the union of their resolved types' sources; otherwise the general rules.
        let neededSources: Set<PlaylistSource>
        if def.journals.isEmpty {
            neededSources = Set(def.sources)
        } else {
            neededSources = Set(def.journals.flatMap { j in
                def.resolvedTypes(for: j).compactMap { label in
                    journalCatalog.first { $0.journal == j }?.types.first { $0.label == label }?.source
                }
            })
        }

        var items: [FeedArticle] = []
        if neededSources.contains(.articles)  { items += await FeedManager.shared.fetchAll() }
        if neededSources.contains(.abstracts) { items += await FeedManager.shared.fetchPrimary() }

        // Radio never includes review papers.
        items = items.filter { !$0.label.localizedCaseInsensitiveContains("review") }

        // De-dupe by id (a paper could appear in more than one feed).
        var seen = Set<String>()
        items = items.filter { seen.insert($0.id).inserted }

        // Journal + article-type filter. With journals selected, keep only items
        // from those journals whose type is in that journal's resolved set. With
        // none selected (the default feed), keep everything already fetched.
        if !def.journals.isEmpty {
            let allowed: [String: Set<String>] = Dictionary(uniqueKeysWithValues:
                def.journals.map { ($0, Set(def.resolvedTypes(for: $0))) })
            items = items.filter { allowed[$0.source]?.contains($0.label) == true }
        }

        // Domain/field filter via the LLM, if a topic is set.
        if !def.topic.isEmpty, !items.isEmpty,
           let keep = await PlaylistFilterAgent.shared.matchingIndices(items, topic: def.topic) {
            let set = Set(keep)
            items = items.enumerated().filter { set.contains($0.offset) }.map(\.element)
        }

        return applySorts(items, def.sorts)
    }

    /// Stable multi-key sort in the given priority order.
    static func applySorts(_ items: [FeedArticle], _ sorts: [PlaylistSort]) -> [FeedArticle] {
        guard !sorts.isEmpty else { return items }
        return items.sorted { a, b in
            for s in sorts {
                switch s {
                case .date:
                    let da = a.publishedDate ?? .distantPast
                    let db = b.publishedDate ?? .distantPast
                    if da != db { return da > db }       // newest first
                case .type:
                    if a.label != b.label { return a.label < b.label }
                }
            }
            return false
        }
    }
}
