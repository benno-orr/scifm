import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var viewModel: PlayerViewModel
    @Binding var selectedTab: Int
    @State private var items: [LibraryItem] = []

    var body: some View {
        NavigationView {
            Group {
                if items.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Library")
            .onAppear { Task { items = await LibraryManager.shared.loadAll() } }
            .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in
                Task { items = await LibraryManager.shared.loadAll() }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 52))
                .foregroundColor(.secondary)
            Text("No articles yet")
                .font(.headline)
            Text("Paste a paper URL to get started.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private var list: some View {
        List {
            ForEach(items) { item in
                Button {
                    Task {
                        await viewModel.loadLibraryItem(item)
                        selectedTab = 0
                    }
                } label: {
                    row(item)
                }
                .buttonStyle(.plain)
            }
            .onDelete { indexSet in
                Task {
                    for idx in indexSet { await LibraryManager.shared.delete(items[idx].id) }
                    items = await LibraryManager.shared.loadAll()
                }
            }
        }
        .listStyle(.plain)
    }

    private func row(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
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
        }
        .padding(.vertical, 4)
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let m = Int(t) / 60; let s = Int(t) % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}
