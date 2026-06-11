import SwiftUI

/// The Reading/Read list. Embedded in the Library (home) tab beneath the
/// paste-URL field and cost box; tapping an item starts playback in place.
struct LibraryListView: View {
    @EnvironmentObject var viewModel: PlayerViewModel
    @State private var items: [LibraryItem] = []
    @State private var filter: Filter = .reading

    enum Filter: String, CaseIterable { case reading = "Reading", read = "Read" }

    private var reading: [LibraryItem] { items.filter { !$0.isFinished } }
    private var read: [LibraryItem]    { items.filter { $0.isFinished } }
    private var shown: [LibraryItem]   { filter == .reading ? reading : read }

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
            Image(systemName: filter == .reading ? "headphones" : "checkmark.circle")
                .font(.system(size: 52))
                .foregroundColor(.secondary)
            Text(filter == .reading ? "Nothing in progress" : "Nothing finished yet")
                .font(.headline)
            Text(filter == .reading
                 ? "Articles you start appear here until you finish them."
                 : "Articles you listen to the end move here.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
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
            kindBadge(item.contentKind)

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

            if item.isFinished {
                Button { setFinished(item.id, false) } label: {
                    Label("Finished", systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            } else {
                if item.progressFraction > 0 {
                    ProgressView(value: item.progressFraction)
                        .tint(.accentColor)
                        .padding(.top, 2)
                }
                Button { setFinished(item.id, true) } label: {
                    Label("Mark as read", systemImage: "checkmark.circle")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    private func kindBadge(_ kind: ContentKind) -> some View {
        Label(kind.label.uppercased(), systemImage: kind.symbol)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.accentColor)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let m = Int(t) / 60; let s = Int(t) % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}
