import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var viewModel: PlayerViewModel
    @Binding var selectedTab: Int
    @State private var items: [LibraryItem] = []
    @State private var filter: Filter = .reading

    enum Filter: String, CaseIterable { case reading = "Reading", read = "Read" }

    private var reading: [LibraryItem] { items.filter { !$0.isFinished } }
    private var read: [LibraryItem]    { items.filter { $0.isFinished } }
    private var shown: [LibraryItem]   { filter == .reading ? reading : read }

    var body: some View {
        NavigationView {
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
            .navigationTitle("Library")
            .onAppear { Task { items = await LibraryManager.shared.loadAll() } }
            .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in
                Task { items = await LibraryManager.shared.loadAll() }
            }
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
                let toDelete = indexSet.map { shown[$0].id }
                Task {
                    for id in toDelete { await LibraryManager.shared.delete(id) }
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

            if item.isFinished {
                Label("Finished", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundColor(.accentColor)
            } else if item.progressFraction > 0 {
                ProgressView(value: item.progressFraction)
                    .tint(.accentColor)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let m = Int(t) / 60; let s = Int(t) % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}
