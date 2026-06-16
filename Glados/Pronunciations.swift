import Foundation
import SwiftUI
import UIKit
import os

let pronLog = Logger(subsystem: "com.borr.scifm", category: "pronunciation")

/// A user-added pronunciation: a word "as written" mapped to a "say it like"
/// phonetic spelling that gets substituted before text is sent to the TTS API.
struct UserPronunciation: Codable, Identifiable, Equatable {
    let word: String          // e.g. "TGF-β"
    let replacement: String   // e.g. "T G F beta"
    var dateAdded: Date = Date()
    var id: String { word.lowercased() }
}

/// Nonisolated storage for the user pronunciation dictionary, readable from any
/// thread so `ScientificPronunciation.rewrite` can apply it wherever it runs.
/// Persists to UserDefaults (fast, synchronous) and mirrors a JSON copy into the
/// Documents container so the dictionary can be pulled off-device while debugging.
enum UserPronunciationData {
    static let key = "userPronunciations"

    static func all() -> [UserPronunciation] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let arr = try? JSONDecoder().decode([UserPronunciation].self, from: data)
        else { return [] }
        return arr
    }

    static func save(_ entries: [UserPronunciation]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pronunciations.json")
        try? data.write(to: url)
    }
}

/// Observable wrapper over the dictionary for SwiftUI (the add sheet + the debug
/// manager). Reads/writes the same store `ScientificPronunciation` consults.
@MainActor
final class PronunciationStore: ObservableObject {
    static let shared = PronunciationStore()
    @Published private(set) var entries: [UserPronunciation]

    private init() { entries = UserPronunciationData.all() }

    func add(word: String, replacement: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !r.isEmpty else { return }
        var list = entries.filter { $0.word.lowercased() != w.lowercased() }   // replace any prior entry
        list.insert(UserPronunciation(word: w, replacement: r), at: 0)
        entries = list
        UserPronunciationData.save(list)
        #if DEBUG
        // Paste-ready line so debug entries can be promoted into the global list.
        pronLog.log("saved \(ScientificPronunciation.swiftLine(word: w, replacement: r), privacy: .public)")
        #endif
    }

    func remove(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        UserPronunciationData.save(entries)
    }

    /// Paste-ready Swift for promoting the whole dictionary into the global
    /// hardcoded list (`ScientificPronunciation.substitutions`).
    var swiftExport: String {
        entries
            .map { ScientificPronunciation.swiftLine(word: $0.word, replacement: $0.replacement) }
            .joined(separator: "\n")
    }
}

// MARK: - Add-pronunciation sheet (from the player)

/// Presented when the listener pauses on a mispronounced word. Captures the word
/// and its phonetic spelling, saves it, and (via the view model) regenerates the
/// rest of the current article with the fix applied.
struct PronunciationSheet: View {
    @EnvironmentObject var viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    let context: String          // current sentence / legend, to help pick the word

    @State private var word = ""
    @State private var sayAs = ""

    private var canSave: Bool {
        !word.trimmingCharacters(in: .whitespaces).isEmpty
            && !sayAs.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationView {
            Form {
                if !context.isEmpty {
                    Section("Currently playing") {
                        Text(context).font(.footnote).foregroundColor(.secondary)
                    }
                }
                Section {
                    TextField("Word as written (e.g. TGF-β)", text: $word)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Say it like (e.g. T G F beta)", text: $sayAs)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Replaces the word in the rest of this article, and saves it for future ones.")
                }
            }
            .navigationTitle("Fix Pronunciation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        viewModel.applyPronunciation(word: word, sayAs: sayAs)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}

// MARK: - Debug: manage + promote the dictionary

/// Lists saved pronunciations and offers a paste-ready Swift export for promoting
/// them into the global hardcoded list. Reached from the Seminar Debug tab.
struct PronunciationManagerView: View {
    @ObservedObject private var store = PronunciationStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationView {
            List {
                if store.entries.isEmpty {
                    Text("No saved pronunciations yet. Add them from the player while listening — tap the speech-bubble button when you hear a word that's read wrong.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    Section("Saved (\(store.entries.count))") {
                        ForEach(store.entries) { e in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.word).font(.subheadline.bold())
                                Text("→ \(e.replacement)")
                                    .font(.footnote).foregroundColor(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                        .onDelete { store.remove(at: $0) }
                    }

                    Section {
                        Text(store.swiftExport)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = store.swiftExport
                            copied = true
                        } label: {
                            Label(copied ? "Copied!" : "Copy Swift", systemImage: "doc.on.doc")
                        }
                    } header: {
                        Text("Promote to global")
                    } footer: {
                        Text("Paste these into ScientificPronunciation.substitutions to ship them as built-in app pronunciations. The dictionary is also mirrored to pronunciations.json in the app's Documents.")
                    }
                }
            }
            .navigationTitle("My Pronunciations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
