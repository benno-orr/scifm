import Foundation

extension Notification.Name {
    static let libraryDidChange = Notification.Name("libraryDidChange")
}

// MARK: - Models

/// What kind of content a library entry is, surfaced as a badge.
enum ContentKind: String, Codable, CaseIterable {
    case editorial, primary, review, seminar, other

    var label: String {
        switch self {
        case .editorial: return "Editorial"
        case .primary:   return "Primary"
        case .review:    return "Review"
        case .seminar:   return "Seminar"
        case .other:     return "Article"
        }
    }

    var symbol: String {
        switch self {
        case .editorial: return "newspaper"
        case .primary:   return "doc.text.magnifyingglass"
        case .review:    return "text.book.closed"
        case .seminar:   return "rectangle.3.group"
        case .other:     return "doc.text"
        }
    }
}

struct LibraryItem: Codable, Identifiable {
    var id: UUID
    var title: String
    var sourceURL: String
    var dateAdded: Date
    var duration: TimeInterval
    var audioFileName: String
    var sentences: [StoredSentence]
    var lastPlayedTime: TimeInterval
    /// Optional for backward-compatibility with items saved before tags existed.
    var kind: ContentKind?
    /// Set for saved seminars; lets the figure player be rebuilt on replay.
    var panels: [StoredPanel]?
    /// True if this entry was created by Playlist mode (auto-narrated queue).
    var fromPlaylist: Bool?
    /// User bookmarked this to come back to ("Read Later").
    var readLater: Bool?

    var contentKind: ContentKind { kind ?? .other }

    /// Whether the user explicitly marked this finished, independent of position.
    var markedFinished: Bool?
    /// Last time the item was created/opened/progressed; drives 7-day eviction.
    var lastTouched: Date?

    var touchedDate: Date { lastTouched ?? dateAdded }

    /// Fraction listened, 0...1.
    var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, lastPlayedTime / duration))
    }

    /// "Read" once playback reaches the final stretch or the user marks it done.
    var isFinished: Bool {
        if markedFinished == true { return true }
        return duration > 0 && lastPlayedTime >= duration * 0.97
    }
}

struct StoredSentence: Codable {
    var text: String
    var startTime: TimeInterval
}

/// A figure panel persisted with a saved seminar, enough to rebuild the
/// figure player on replay.
struct StoredPanel: Codable {
    var figureNumber: Int
    var label: String
    var figureTitle: String
    var legendText: String
    var imageURL: String?
    var startTime: TimeInterval
}

// MARK: - Manager

actor LibraryManager {
    static let shared = LibraryManager()

    private var items: [LibraryItem] = []
    private var isLoaded = false

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var metadataURL: URL { documentsURL.appendingPathComponent("library.json") }
    private var audioDir: URL { documentsURL.appendingPathComponent("audio") }

    /// Cached audio is evicted this long after an item was last touched.
    private let evictionInterval: TimeInterval = 7 * 24 * 3600

    func loadAll() -> [LibraryItem] {
        if !isLoaded {
            if let data = try? Data(contentsOf: metadataURL),
               let decoded = try? JSONDecoder().decode([LibraryItem].self, from: data) {
                items = decoded
            }
            isLoaded = true
        }
        pruneStale()
        return items
    }

    /// Removes items (audio + metadata) not touched within `evictionInterval`.
    private func pruneStale() {
        let cutoff = Date().addingTimeInterval(-evictionInterval)
        let stale = items.filter { $0.touchedDate < cutoff }
        guard !stale.isEmpty else { return }
        for item in stale {
            try? FileManager.default.removeItem(at: audioDir.appendingPathComponent(item.audioFileName))
        }
        items.removeAll { $0.touchedDate < cutoff }
        persist()
    }

    /// Bumps an item's last-touched time (e.g. when opened) to defer eviction.
    func markTouched(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].lastTouched = Date()
        persist()
    }

    func save(title: String, sourceURL: String, wavData: Data,
              sentences: [StoredSentence], duration: TimeInterval,
              kind: ContentKind = .other, panels: [StoredPanel]? = nil,
              fromPlaylist: Bool = false, finished: Bool = false) -> LibraryItem {
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let id = UUID()
        let fileName = "\(id.uuidString).wav"
        try? wavData.write(to: audioDir.appendingPathComponent(fileName))

        let item = LibraryItem(id: id, title: title, sourceURL: sourceURL,
                               dateAdded: Date(), duration: duration,
                               audioFileName: fileName, sentences: sentences,
                               lastPlayedTime: finished ? duration : 0,
                               kind: kind, panels: panels, fromPlaylist: fromPlaylist,
                               readLater: false,
                               markedFinished: finished, lastTouched: Date())
        items.insert(item, at: 0)
        persist()
        return item
    }

    /// Creates a Library entry the moment generation starts, so the doc shows
    /// up (under Reading) immediately. Audio is written later by `finalizeEntry`.
    func startEntry(title: String, sourceURL: String, kind: ContentKind) -> LibraryItem {
        let id = UUID()
        let item = LibraryItem(id: id, title: title, sourceURL: sourceURL,
                               dateAdded: Date(), duration: 0,
                               audioFileName: "\(id.uuidString).wav", sentences: [],
                               lastPlayedTime: 0, kind: kind, panels: nil,
                               fromPlaylist: false, readLater: false,
                               markedFinished: false, lastTouched: Date())
        items.insert(item, at: 0)
        persist()
        return item
    }

    /// Writes the finished audio + metadata for an entry created by `startEntry`.
    func finalizeEntry(_ id: UUID, wavData: Data, sentences: [StoredSentence],
                       duration: TimeInterval, panels: [StoredPanel]? = nil) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try? wavData.write(to: audioDir.appendingPathComponent(items[idx].audioFileName))
        items[idx].sentences = sentences
        items[idx].duration = duration
        items[idx].lastTouched = Date()
        if let panels { items[idx].panels = panels }
        persist()
    }

    /// Bookmark / un-bookmark an item for "Read Later".
    func setReadLater(_ id: UUID, _ on: Bool) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].readLater = on
        items[idx].lastTouched = Date()
        persist()
    }

    /// Explicitly mark an item read/unread (manual button).
    func setFinished(_ id: UUID, _ finished: Bool) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].markedFinished = finished
        if finished {
            items[idx].lastPlayedTime = items[idx].duration
        } else if items[idx].lastPlayedTime >= items[idx].duration * 0.97 {
            items[idx].lastPlayedTime = 0   // so it leaves the Read tab
        }
        items[idx].lastTouched = Date()
        persist()
    }

    func delete(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let file = items[idx].audioFileName
        try? FileManager.default.removeItem(at: audioDir.appendingPathComponent(file))
        items.remove(at: idx)
        persist()
    }

    func updateLastPlayedTime(_ id: UUID, time: TimeInterval) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].lastPlayedTime = time
        items[idx].lastTouched = Date()
        persist()
    }

    func audioData(for item: LibraryItem) -> Data? {
        try? Data(contentsOf: audioDir.appendingPathComponent(item.audioFileName))
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: metadataURL)
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }
}
