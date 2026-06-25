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
struct PlaylistDef: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    /// Free-text scientific domain/field to filter on (LLM-matched). "" = no filter.
    var topic: String = ""
    var sources: [PlaylistSource] = [.articles]
    var sorts: [PlaylistSort] = [.date]
    /// Per-journal included article types (journal name → type labels). Empty =
    /// no journal/type restriction (everything from `sources`).
    var journalTypes: [String: [String]] = [:]
    var builtIn: Bool = false

    /// The default playlist: recent editorials, newest first, no domain filter.
    static let recent = PlaylistDef(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Recent", topic: "", sources: [.articles], sorts: [.date], builtIn: true)

    /// One-line description of the filters, shown under the playlist name.
    var filterSummary: String {
        var parts: [String] = []
        if !topic.isEmpty { parts.append(topic) }
        if journalTypes.isEmpty {
            parts.append(sources.map(\.label).joined(separator: " + "))
        } else {
            parts.append(journalTypes.keys.sorted().joined(separator: ", "))
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
    ]),
    JournalGroup(journal: "Science", types: [
        CatalogType(label: "Perspective", source: .articles),
        CatalogType(label: "Research Article", source: .abstracts),
    ]),
    JournalGroup(journal: "Cell", types: [
        CatalogType(label: "Highlights", source: .articles),
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
    }

    func delete(_ def: PlaylistDef) {
        custom.removeAll { $0.id == def.id }; save()
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

// MARK: - Builder

/// Resolves a `PlaylistDef` into a concrete, filtered, sorted list of articles.
enum PlaylistBuilder {
    static func articles(for def: PlaylistDef) async -> [FeedArticle] {
        var items: [FeedArticle] = []
        if def.sources.contains(.articles)  { items += await FeedManager.shared.fetchAll() }
        if def.sources.contains(.abstracts) { items += await FeedManager.shared.fetchPrimary() }

        // De-dupe by id (a paper could appear in more than one feed).
        var seen = Set<String>()
        items = items.filter { seen.insert($0.id).inserted }

        // Journal / article-type filter (per-journal allowed type labels).
        if !def.journalTypes.isEmpty {
            items = items.filter { def.journalTypes[$0.source]?.contains($0.label) == true }
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
