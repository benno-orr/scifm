import SwiftUI

/// The Reading/Read list. Embedded in the Library (home) tab beneath the
/// paste-URL field and cost box; tapping an item starts playback in place.
struct LibraryListView: View {
    @EnvironmentObject var viewModel: PlayerViewModel
    @State private var items: [LibraryItem] = []
    @State private var filter: Filter = .reading

    enum Filter: String, CaseIterable {
        case reading = "Reading", read = "Read", readLater = "Read Later", saved = "Seminars"
    }

    // Seminars live in their own Saved section; Reading/Read are the narration docs.
    private var shown: [LibraryItem] {
        switch filter {
        case .reading:   return items.filter { $0.contentKind != .seminar && !$0.isFinished }
        case .read:      return items.filter { $0.contentKind != .seminar && $0.isFinished }
        case .readLater: return items.filter { $0.readLater == true }
        case .saved:     return items.filter { $0.contentKind == .seminar }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            Group {
                if shown.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
        }
        .onAppear { Task { items = await LibraryManager.shared.loadAll() } }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in
            Task { items = await LibraryManager.shared.loadAll() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: emptyIcon)
                .font(.system(size: 52))
                .foregroundColor(.secondary)
            Text(emptyTitle).font(.headline)
            Text(emptyDetail)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyIcon: String {
        switch filter {
        case .reading: return "headphones"
        case .read: return "checkmark.circle"
        case .readLater: return "bookmark"
        case .saved: return "rectangle.3.group"
        }
    }
    private var emptyTitle: String {
        switch filter {
        case .reading: return "Nothing in progress"
        case .read: return "Nothing finished yet"
        case .readLater: return "Nothing saved yet"
        case .saved: return "No seminars yet"
        }
    }
    private var emptyDetail: String {
        switch filter {
        case .reading: return "Articles you start appear here until you finish them."
        case .read:    return "Articles you listen to the end move here."
        case .readLater: return "Tap the bookmark while a station track plays to save it here."
        case .saved:   return "Seminars you generate from the Papers tab are saved here."
        }
    }

    private var list: some View {
        List {
            ForEach(shown) { item in
                Button {
                    Task { await viewModel.loadLibraryItem(item) }
                } label: {
                    row(item)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.rowTranslucent)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if item.contentKind != .seminar {
                        if item.isFinished {
                            Button {
                                setFinished(item.id, false)
                            } label: { Label("Mark unread", systemImage: "arrow.uturn.backward") }
                            .tint(.orange)
                        } else {
                            Button {
                                setFinished(item.id, true)
                            } label: { Label("Mark read", systemImage: "checkmark") }
                            .tint(.accentColor)
                        }
                    }
                }
            }
            .onDelete { indexSet in
                let toDelete = indexSet.map { shown[$0].id }
                Task {
                    for id in toDelete { await LibraryManager.shared.delete(id) }
                    items = await LibraryManager.shared.loadAll()
                }
            }
        }
        .listStyle(.plain)
    }

    private func setFinished(_ id: UUID, _ finished: Bool) {
        Task {
            await LibraryManager.shared.setFinished(id, finished)
            items = await LibraryManager.shared.loadAll()
        }
    }

    private func row(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                kindBadge(item.contentKind)
                if item.fromPlaylist == true { playlistBadge }
            }

            Text(item.title)
                .font(.subheadline)
                .lineLimit(2)
                .foregroundColor(.primary)
            HStack(spacing: 4) {
                Image(systemName: "clock").font(.caption2)
                Text(formatDuration(item.duration))
                Text("·")
                Text(item.dateAdded, style: .relative)
                Text("ago")
            }
            .font(.caption)
            .foregroundColor(.secondary)

            if item.contentKind == .seminar {
                if item.progressFraction > 0 {
                    ProgressView(value: item.progressFraction).tint(.accentColor).padding(.top, 2)
                }
            } else {
                if !item.isFinished, item.progressFraction > 0 {
                    ProgressView(value: item.progressFraction).tint(.accentColor).padding(.top, 2)
                }
                // Always-visible read/unread toggle.
                Button { setFinished(item.id, !item.isFinished) } label: {
                    Label(item.isFinished ? "Read — mark unread" : "Mark as read",
                          systemImage: item.isFinished ? "checkmark.circle.fill" : "circle")
                        .font(.caption2)
                        .foregroundColor(item.isFinished ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .leading) {
            if item.contentKind != .seminar {
                Button { setFinished(item.id, !item.isFinished) } label: {
                    Label(item.isFinished ? "Unread" : "Read",
                          systemImage: item.isFinished ? "circle" : "checkmark.circle")
                }
                .tint(item.isFinished ? .gray : .accentColor)
            }
        }
    }

    private func kindBadge(_ kind: ContentKind) -> some View {
        Label(kind.label.uppercased(), systemImage: kind.symbol)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.accentColor)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
    }

    /// Marks an entry that was queued/played in Radio mode.
    private var playlistBadge: some View {
        Label("RADIO", systemImage: "dot.radiowaves.left.and.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.orange)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.orange.opacity(0.14), in: Capsule())
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let m = Int(t) / 60; let s = Int(t) % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}
