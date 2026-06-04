import Foundation

extension Notification.Name {
    static let libraryDidChange = Notification.Name("libraryDidChange")
}

// MARK: - Models

struct LibraryItem: Codable, Identifiable {
    var id: UUID
    var title: String
    var sourceURL: String
    var dateAdded: Date
    var duration: TimeInterval
    var audioFileName: String
    var sentences: [StoredSentence]
    var lastPlayedTime: TimeInterval

    /// Fraction listened, 0...1.
    var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, lastPlayedTime / duration))
    }

    /// "Read" once playback has reached the final stretch; otherwise "Reading".
    var isFinished: Bool {
        duration > 0 && lastPlayedTime >= duration * 0.97
    }
}

struct StoredSentence: Codable {
    var text: String
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

    func loadAll() -> [LibraryItem] {
        if !isLoaded {
            if let data = try? Data(contentsOf: metadataURL),
               let decoded = try? JSONDecoder().decode([LibraryItem].self, from: data) {
                items = decoded
            }
            isLoaded = true
        }
        return items
    }

    func save(title: String, sourceURL: String, wavData: Data,
              sentences: [StoredSentence], duration: TimeInterval) -> LibraryItem {
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let id = UUID()
        let fileName = "\(id.uuidString).wav"
        try? wavData.write(to: audioDir.appendingPathComponent(fileName))

        let item = LibraryItem(id: id, title: title, sourceURL: sourceURL,
                               dateAdded: Date(), duration: duration,
                               audioFileName: fileName, sentences: sentences, lastPlayedTime: 0)
        items.insert(item, at: 0)
        persist()
        return item
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
