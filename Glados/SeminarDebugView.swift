import SwiftUI
import UIKit

// MARK: - Debug tab
//
// A developer tool for inspecting the figure pipeline. Load a paper by URL, or
// pick one already saved in the Library, then page through its figures with the
// OCR-recognized panel letters underlined in place. Each figure can also be sent
// to the panel-letter agent (Claude vision) to compare what the LLM reads vs. the
// legend's labels and Vision's OCR.

/// One whole figure for the debug view: its image plus the panel letters the
/// legend says it should contain.
private struct DebugFigure: Identifiable {
    let id: Int            // figure number
    let imageURL: URL
    let expectedLabels: [String]
    let title: String
}

struct SeminarDebugView: View {
    @State private var urlText = ""
    @State private var figures: [DebugFigure] = []
    @State private var index = 0
    @State private var status = ""
    @State private var loading = false
    @State private var showPronunciations = false
    @State private var savedItems: [LibraryItem] = []

    private let processor = ArticleProcessor()

    var body: some View {
        NavigationView {
            VStack(spacing: 10) {
                inputRow

                if loading {
                    ProgressView().padding(.top, 8)
                }
                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                if !figures.isEmpty {
                    LabeledFigureView(figure: figures[index])
                        .id(figures[index].id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    pager
                } else if !loading {
                    Spacer()
                    Text("Load a paper by URL, or pick a saved one, to inspect its figures — Vision OCR underlines, and the panel-letter agent reads each figure.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Spacer()
                }
            }
            .charcoalBackdrop()
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { savedMenu }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showPronunciations = true } label: {
                        Image(systemName: "character.book.closed")
                    }
                }
            }
            .sheet(isPresented: $showPronunciations) { PronunciationManagerView() }
            .onAppear { Task { await loadSavedItems() } }
        }
    }

    /// Menu of locally-saved seminars (papers with stored figure panels).
    private var savedMenu: some View {
        Menu {
            if savedItems.isEmpty {
                Text("No saved papers")
            } else {
                ForEach(savedItems) { item in
                    Button(item.title) { loadSaved(item) }
                }
            }
        } label: {
            Image(systemName: "tray.full")
        }
    }

    private var inputRow: some View {
        HStack {
            TextField("Paper URL (Nature, PMC, …)", text: $urlText)
                .font(.caption)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
            Button("Load") { loadFigures() }
                .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || loading)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var pager: some View {
        HStack(spacing: 16) {
            Button { if index > 0 { index -= 1 } } label: {
                Image(systemName: "chevron.backward")
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Circle())
            }
            .disabled(index == 0)

            Text("Figure \(figures[index].id)  ·  \(index + 1) / \(figures.count)")
                .font(.subheadline.weight(.semibold).monospacedDigit())

            Button { if index < figures.count - 1 { index += 1 } } label: {
                Image(systemName: "chevron.forward")
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Circle())
            }
            .disabled(index >= figures.count - 1)
        }
        .padding(.bottom, 12)
    }

    private func loadFigures() {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)) else {
            status = "Invalid URL."
            return
        }
        loading = true
        status = "Fetching figures…"
        figures = []
        index = 0
        Task {
            do {
                let result = try await processor.processFigures(url: url)
                let grouped = Self.group(result.panels)
                figures = grouped
                status = grouped.isEmpty
                    ? "No figures with images found."
                    : "\(grouped.count) figure(s) found."
            } catch {
                status = error.localizedDescription
            }
            loading = false
        }
    }

    private func loadSavedItems() async {
        savedItems = await LibraryManager.shared.loadAll()
            .filter { $0.contentKind == .seminar && ($0.panels?.isEmpty == false) }
    }

    /// Loads a saved seminar's stored figures (built offline from its panels).
    private func loadSaved(_ item: LibraryItem) {
        status = ""
        index = 0
        let grouped = Self.group(stored: item.panels ?? [])
        figures = grouped
        status = grouped.isEmpty
            ? "“\(item.title)” has no figures with images."
            : "\(item.title) · \(grouped.count) figure(s)."
    }

    /// Collapses the per-panel timeline into one entry per figure: a single image
    /// and the union of the panel letters the legend lists for that figure.
    private static func group(_ panels: [FigurePanel]) -> [DebugFigure] {
        var byFigure: [Int: (url: URL?, labels: [String], title: String)] = [:]
        for p in panels where !p.isTextSection {
            var e = byFigure[p.figureNumber] ?? (nil, [], p.figureTitle)
            if e.url == nil { e.url = p.imageURL }
            if !p.label.isEmpty, !e.labels.contains(p.label) { e.labels.append(p.label) }
            byFigure[p.figureNumber] = e
        }
        return byFigure
            .sorted { $0.key < $1.key }
            .compactMap { num, v in
                guard let url = v.url else { return nil }
                return DebugFigure(id: num, imageURL: url, expectedLabels: v.labels, title: v.title)
            }
    }

    /// Same as `group`, but from a saved seminar's stored panels.
    private static func group(stored panels: [StoredPanel]) -> [DebugFigure] {
        var byFigure: [Int: (url: URL?, labels: [String], title: String)] = [:]
        for p in panels where p.figureNumber > 0 {
            var e = byFigure[p.figureNumber] ?? (nil, [], p.figureTitle)
            if e.url == nil { e.url = p.imageURL.flatMap { URL(string: $0) } }
            if !p.label.isEmpty, !e.labels.contains(p.label) { e.labels.append(p.label) }
            byFigure[p.figureNumber] = e
        }
        return byFigure
            .sorted { $0.key < $1.key }
            .compactMap { num, v in
                guard let url = v.url else { return nil }
                return DebugFigure(id: num, imageURL: url, expectedLabels: v.labels, title: v.title)
            }
    }
}

// MARK: - Whole figure + detected-letter underlines

/// Renders a whole figure scaled to fit and underlines each OCR-detected panel
/// letter in place (mapping Vision's pixel rects onto the displayed image).
private struct LabeledFigureView: View {
    let figure: DebugFigure

    @State private var image: UIImage?
    @State private var boxes: [LabelBox] = []
    @State private var detail = "Loading…"
    @State private var agentLetters: [String]?
    @State private var agentRunning = false

    var body: some View {
        VStack(spacing: 6) {
            if let image {
                GeometryReader { geo in
                    let fit = Self.fittedRect(imageSize: image.size, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                        ForEach(Array(boxes.enumerated()), id: \.offset) { _, box in
                            let r = Self.map(box.rect, imageSize: image.size, into: fit)
                            // Box outline + underline + the recognized letter.
                            Rectangle()
                                .stroke(Color.green, lineWidth: 1.5)
                                .frame(width: r.width, height: r.height)
                                .position(x: r.midX, y: r.midY)
                            Rectangle()
                                .fill(Color.green)
                                .frame(width: r.width, height: 3)
                                .position(x: r.midX, y: r.maxY + 2)
                            Text(String(box.char).uppercased())
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.green)
                                .padding(.horizontal, 3)
                                .background(Color.black.opacity(0.6))
                                .position(x: r.midX, y: max(8, r.minY - 8))
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            } else {
                Spacer()
                ProgressView()
                Spacer()
            }
            Text(detail)
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            agentRow
        }
        .task { await load() }
    }

    @ViewBuilder
    private var agentRow: some View {
        HStack(spacing: 8) {
            Button {
                Task { await runAgent() }
            } label: {
                Label(agentRunning ? "Asking Claude…" : "Identify panels (Claude)",
                      systemImage: "sparkles")
                    .font(.caption2)
            }
            .disabled(image == nil || agentRunning)

            if agentRunning { ProgressView().scaleEffect(0.7) }

            if let agentLetters {
                Text("Agent: \(agentLetters.isEmpty ? "none" : agentLetters.map { $0.uppercased() }.joined(separator: " "))")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.purple)
            }
        }
        .padding(.bottom, 8)
    }

    private func runAgent() async {
        guard let image else { return }
        agentRunning = true
        let result = await PanelLetterAgent.shared.identifyPanels(in: image)
        agentLetters = result?.panels ?? []
        agentRunning = false
    }

    private func load() async {
        detail = "Loading image…"
        let ocr = Self.ocrURL(figure.imageURL)
        guard let img = await FigureImageCache.shared.image(for: ocr) else {
            detail = "Image failed to load."
            return
        }
        image = img
        detail = "Running OCR…"
        let expected = Set(figure.expectedLabels.compactMap { $0.lowercased().first })
        let found = await FigurePanelCropper.detectLabels(in: img, expected: expected)
        boxes = found
        let foundChars = found.map { String($0.char).uppercased() }.sorted().joined(separator: " ")
        let expectedChars = figure.expectedLabels.map { $0.uppercased() }.joined(separator: " ")
        detail = "Expected: \(expectedChars.isEmpty ? "—" : expectedChars)   ·   "
            + "Found: \(foundChars.isEmpty ? "none" : foundChars)"
    }

    /// Higher-resolution springer variant for legible OCR (mirrors CroppedFigureImage).
    private static func ocrURL(_ u: URL) -> URL {
        let s = u.absoluteString.replacingOccurrences(
            of: #"/lw\d+/"#, with: "/lw1500/", options: .regularExpression)
        return URL(string: s) ?? u
    }

    /// The centered rect a scaledToFit image of `imageSize` occupies in `container`.
    private static func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * scale, h = imageSize.height * scale
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    /// Maps a pixel rect (top-left origin, image space) into the displayed `fit` rect.
    private static func map(_ r: CGRect, imageSize: CGSize, into fit: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let sx = fit.width / imageSize.width, sy = fit.height / imageSize.height
        return CGRect(x: fit.minX + r.minX * sx, y: fit.minY + r.minY * sy,
                      width: r.width * sx, height: r.height * sy)
    }
}
