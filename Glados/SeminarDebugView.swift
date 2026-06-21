import SwiftUI
import UIKit
import PDFKit
import UniformTypeIdentifiers

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
    @EnvironmentObject var viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var figures: [DebugFigure] = []
    @State private var index = 0
    @State private var status = ""
    @State private var loading = false
    @State private var showPronunciations = false
    @State private var savedItems: [LibraryItem] = []
    /// A loaded PDF whose pages we inspect via the text layer (no OCR).
    @State private var pdfDoc: PDFDocument?
    @State private var showPDFImporter = false

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

                if let pdfDoc {
                    PDFPageView(doc: pdfDoc, pageIndex: index)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    pagerControl(count: pdfDoc.pageCount,
                                 label: "Page \(index + 1) / \(pdfDoc.pageCount)")
                } else if !figures.isEmpty {
                    LabeledFigureView(figure: figures[index])
                        .id(figures[index].id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    pagerControl(count: figures.count,
                                 label: "Figure \(figures[index].id)  ·  \(index + 1) / \(figures.count)")
                } else if !loading {
                    Spacer()
                    Text("Open a PDF (its panel letters come straight from the text layer), or load a paper by URL / pick a saved one to inspect the scraped figures.")
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
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showPDFImporter = true } label: {
                        Image(systemName: "doc.richtext")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showPronunciations = true } label: {
                        Image(systemName: "character.book.closed")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showPronunciations) { PronunciationManagerView() }
            .fileImporter(isPresented: $showPDFImporter, allowedContentTypes: [.pdf]) { result in
                if case .success(let url) = result { loadPDF(url) }
            }
            .onAppear {
                Task { await loadSavedItems() }
                consumeDebugRequest()   // handle a request set before this tab existed
            }
            .onChange(of: viewModel.debugFigureURL) { _, _ in consumeDebugRequest() }
        }
    }

    /// If Seminarize (or anything) requested a figure URL, load it here and
    /// auto-run the agent on the first figure.
    private func consumeDebugRequest() {
        guard let url = viewModel.debugFigureURL else { return }
        urlText = url.absoluteString
        loadFigures()
        viewModel.debugFigureURL = nil
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

    private func pagerControl(count: Int, label: String) -> some View {
        HStack(spacing: 16) {
            Button { if index > 0 { index -= 1 } } label: {
                Image(systemName: "chevron.backward")
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Circle())
            }
            .disabled(index == 0)

            Text(label)
                .font(.subheadline.weight(.semibold).monospacedDigit())

            Button { if index < count - 1 { index += 1 } } label: {
                Image(systemName: "chevron.forward")
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Circle())
            }
            .disabled(index >= count - 1)
        }
        .padding(.bottom, 12)
    }

    /// Opens a local PDF and inspects its pages via the text layer.
    private func loadPDF(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let doc = PDFDocument(data: data) else {
            status = "Couldn't open that PDF."
            return
        }
        figures = []
        index = 0
        pdfDoc = doc
        status = "\(url.lastPathComponent) · \(doc.pageCount) page(s)."
    }

    private func loadFigures() {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)) else {
            status = "Invalid URL."
            return
        }
        loading = true
        status = "Fetching figures…"
        figures = []
        pdfDoc = nil
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
        pdfDoc = nil
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
    @State private var rects: [CGRect] = []
    @State private var crops: [(char: Character, color: Color, image: UIImage)] = []
    @State private var detail = "Loading…"
    @State private var agentRunning = false

    private var legendChars: String {
        let s = figure.expectedLabels.map { $0.lowercased() }.joined(separator: " ")
        return s.isEmpty ? "—" : s
    }

    var body: some View {
        VStack(spacing: 6) {
            if let image {
                PanelOverlay(image: image, boxes: boxes, rects: rects)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

            PanelCropsRow(crops: crops)
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
                Label(agentRunning ? "Asking Claude…" : "Re-run agent", systemImage: "sparkles")
                    .font(.caption2)
            }
            .disabled(image == nil || agentRunning)

            if agentRunning { ProgressView().scaleEffect(0.7) }
        }
        .padding(.bottom, 8)
    }

    private func load() async {
        detail = "Loading image…"
        let url = Self.ocrURL(figure.imageURL)
        guard let img = await FigureImageCache.shared.image(for: url) else {
            detail = "Image failed to load."
            return
        }
        image = img
        await runAgent()   // the agent is the default detector
    }

    /// Default: ask the Claude vision agent for the located panels and drive the
    /// overlay + crops from it; fall back to Vision OCR if the agent is
    /// unavailable (e.g. no Anthropic key).
    private func runAgent() async {
        guard let image else { return }
        agentRunning = true
        detail = "Identifying panels (Claude)…"
        let result = await PanelLetterAgent.shared.identifyPanels(in: image)
        agentRunning = false

        guard let result else { await runOCRFallback(); return }
        let W = image.size.width, H = image.size.height
        boxes = result.panels.compactMap { p in
            guard let ch = p.letter.first else { return nil }
            return LabelBox(char: ch, rect: CGRect(x: p.box.minX * W, y: p.box.minY * H,
                                                   width: p.box.width * W, height: p.box.height * H))
        }
        rects = PanelGeometry.panelRects(boxes: boxes, image: image)
        crops = PanelGeometry.crops(image: image, boxes: boxes, rects: rects)
        let agentChars = boxes.map { String($0.char) }.joined(separator: " ")
        detail = "Agent: \(agentChars.isEmpty ? "none" : agentChars)   ·   Legend: \(legendChars)"
    }

    private func runOCRFallback() async {
        guard let image else { return }
        detail = "Agent unavailable — using OCR…"
        let expected = Set(figure.expectedLabels.compactMap { $0.lowercased().first })
        let found = await FigurePanelCropper.detectLabels(in: image, expected: expected)
        boxes = found
        rects = PanelGeometry.panelRects(boxes: found, image: image)
        crops = PanelGeometry.crops(image: image, boxes: found, rects: rects)
        let foundChars = found.map { String($0.char) }.sorted().joined(separator: " ")
        detail = "OCR: \(foundChars.isEmpty ? "none" : foundChars)   ·   Legend: \(legendChars)"
    }

    /// Higher-resolution springer variant for legible OCR (mirrors CroppedFigureImage).
    private static func ocrURL(_ u: URL) -> URL {
        let s = u.absoluteString.replacingOccurrences(
            of: #"/lw\d+/"#, with: "/lw1500/", options: .regularExpression)
        return URL(string: s) ?? u
    }
}

// MARK: - Panel geometry (shared)

/// Panel-region math, per-letter colors, and cropping — shared by the overlay
/// and the crop strip so both agree on what region each letter owns.
enum PanelGeometry {
    /// Distinct colors cycled one-per-letter.
    static let palette: [Color] = [
        .red, .blue, .green, .orange, .purple, .pink,
        .teal, .yellow, .cyan, .mint, .indigo, .brown,
    ]

    /// The figure region this panel's letter owns. It expands right until it
    /// reaches another label in the same row (else the page edge), and down until
    /// it reaches another label within its own column span (else the page edge).
    /// Bounding by the *label* — not another panel's box — and restricting the
    /// down-search to the column means a shared region is claimed by the panel
    /// whose label sits above/left of it, which resolves the overlaps.
    static func panelRect(for box: LabelBox, among boxes: [LabelBox], imageSize: CGSize) -> CGRect {
        let W = imageSize.width, H = imageSize.height
        let lx = box.rect.minX, ly = box.rect.minY
        let rowTol = H * 0.05

        // Right edge: nearest label to the right that's on the same row.
        let rightBound = boxes
            .filter { abs($0.rect.minY - ly) < rowTol && $0.rect.minX > lx + W * 0.02 }
            .map { $0.rect.minX }.min() ?? W

        // Bottom edge: nearest label below whose x falls within this panel's
        // column span [lx, rightBound). Labels in other columns don't cap it.
        let bottomBound = boxes
            .filter { $0.rect.minY > ly + rowTol
                      && $0.rect.minX >= lx - W * 0.02
                      && $0.rect.minX < rightBound - W * 0.01 }
            .map { $0.rect.minY }.min() ?? H

        // Generous margin above/left of the label (~half inch) so the whole label
        // is captured even when a detection box undershoots its top corner.
        let pad = max(box.rect.height * 1.5, min(W, H) * 0.04)
        let x0 = max(0, lx - pad)
        let y0 = max(0, ly - pad)
        return CGRect(x: x0, y: y0,
                      width: min(rightBound, W) - x0, height: min(bottomBound, H) - y0)
    }

    /// Crops `image` to a pixel rect (image-space, top-left origin) and frames it
    /// in a white border so labels near an edge aren't flush against dark content.
    static func crop(_ image: UIImage, to rect: CGRect) -> UIImage? {
        let r = rect.integral.intersection(CGRect(origin: .zero, size: image.size))
        guard r.width > 1, r.height > 1, let cg = image.cgImage?.cropping(to: r) else { return nil }
        let panel = UIImage(cgImage: cg)
        let m = max(8, min(r.width, r.height) * 0.06)
        let size = CGSize(width: panel.size.width + 2 * m, height: panel.size.height + 2 * m)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            panel.draw(in: CGRect(x: m, y: m, width: panel.size.width, height: panel.size.height))
        }
    }

    /// Panel rects for each label. These may overlap — each label simply owns the
    /// region from itself to the next label (right/down) or the page edge.
    static func panelRects(boxes: [LabelBox], image: UIImage) -> [CGRect] {
        boxes.map { panelRect(for: $0, among: boxes, imageSize: image.size) }
    }

    /// One cropped panel per detected letter, with its color.
    static func crops(image: UIImage, boxes: [LabelBox], rects: [CGRect])
        -> [(char: Character, color: Color, image: UIImage)] {
        zip(boxes, rects).enumerated().compactMap { i, pair in
            guard let img = crop(image, to: pair.1) else { return nil }
            return (pair.0.char, palette[i % palette.count], img)
        }
    }
}

// MARK: - Color-coded panel overlay

/// Draws an image with, per detected letter: a solid box around the letter and a
/// dashed box around the figure region that letter owns — one color per letter.
/// Shared by the figure-image and PDF-page debug views.
private struct PanelOverlay: View {
    let image: UIImage
    let boxes: [LabelBox]
    let rects: [CGRect]

    var body: some View {
        GeometryReader { geo in
            let fit = Self.fittedRect(imageSize: image.size, in: geo.size)
            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                ForEach(Array(boxes.enumerated()), id: \.offset) { i, box in
                    let color = PanelGeometry.palette[i % PanelGeometry.palette.count]
                    let letterR = Self.map(box.rect, imageSize: image.size, into: fit)
                    let panelSrc = i < rects.count ? rects[i]
                        : PanelGeometry.panelRect(for: box, among: boxes, imageSize: image.size)
                    let panelR = Self.map(panelSrc, imageSize: image.size, into: fit)
                    Rectangle()
                        .stroke(color, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: panelR.width, height: panelR.height)
                        .position(x: panelR.midX, y: panelR.midY)
                    // The letter, recolored in place on top of the figure's letter.
                    Text(String(box.char))
                        .font(.system(size: max(12, letterR.height), weight: .bold))
                        .foregroundColor(color)
                        .position(x: letterR.midX, y: letterR.midY)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// The rect a scaledToFit image of `imageSize` occupies — anchored top-leading
    /// to match the ZStack's alignment (the image is pinned top-left, not centered).
    private static func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        return CGRect(x: 0, y: 0, width: imageSize.width * scale, height: imageSize.height * scale)
    }

    /// Maps a pixel rect (top-left origin, image space) into the displayed `fit` rect.
    private static func map(_ r: CGRect, imageSize: CGSize, into fit: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let sx = fit.width / imageSize.width, sy = fit.height / imageSize.height
        return CGRect(x: fit.minX + r.minX * sx, y: fit.minY + r.minY * sy,
                      width: r.width * sx, height: r.height * sy)
    }
}

// MARK: - Cropped panels strip

/// A horizontal strip of the individual panels, cropped as the cropper would.
/// Tapping a panel opens a full-screen pager to view the crops one at a time.
private struct PanelCropsRow: View {
    let crops: [(char: Character, color: Color, image: UIImage)]
    @State private var selection: CropSelection?

    var body: some View {
        if !crops.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(Array(crops.enumerated()), id: \.offset) { i, c in
                        Button { selection = CropSelection(id: i) } label: {
                            VStack(spacing: 2) {
                                Image(uiImage: c.image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 96, height: 96)
                                    .background(Color(.secondarySystemBackground))
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(c.color, lineWidth: 2))
                                Text(String(c.char)).font(.caption2.bold()).foregroundColor(c.color)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(height: 122)
            .fullScreenCover(item: $selection) { sel in
                CropPager(crops: crops, start: sel.id)
            }
        }
    }
}

private struct CropSelection: Identifiable { let id: Int }

/// Full-screen viewer showing the cropped panels alone, one at a time (swipe).
private struct CropPager: View {
    let crops: [(char: Character, color: Color, image: UIImage)]
    let start: Int
    @State private var index: Int
    @Environment(\.dismiss) private var dismiss

    init(crops: [(char: Character, color: Color, image: UIImage)], start: Int) {
        self.crops = crops
        self.start = start
        _index = State(initialValue: start)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(crops.enumerated()), id: \.offset) { i, c in
                    VStack(spacing: 16) {
                        Image(uiImage: c.image)
                            .resizable()
                            .scaledToFit()
                            .padding()
                        Text(String(c.char)).font(.title2.bold()).foregroundColor(c.color)
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundColor(.white.opacity(0.85))
            }
            .padding()
        }
    }
}

// MARK: - PDF page (panel letters straight from the text layer)

/// Renders one PDF page and overlays the standalone letters from its text layer.
private struct PDFPageView: View {
    let doc: PDFDocument
    let pageIndex: Int

    @State private var image: UIImage?
    @State private var boxes: [LabelBox] = []
    @State private var rects: [CGRect] = []
    @State private var crops: [(char: Character, color: Color, image: UIImage)] = []

    var body: some View {
        VStack(spacing: 6) {
            if let image {
                PanelOverlay(image: image, boxes: boxes, rects: rects)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer(); ProgressView(); Spacer()
            }
            Text(boxes.isEmpty
                 ? "No standalone a–h letters on this page"
                 : "Letters: " + boxes.map { String($0.char) }.joined(separator: " "))
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
            PanelCropsRow(crops: crops)
        }
        .task(id: pageIndex) {
            image = nil; boxes = []; rects = []; crops = []
            if let r = PDFLetterExtractor.page(doc, index: pageIndex) {
                let rk = PanelGeometry.panelRects(boxes: r.boxes, image: r.image)
                image = r.image; boxes = r.boxes; rects = rk
                crops = PanelGeometry.crops(image: r.image, boxes: r.boxes, rects: rk)
            }
        }
    }
}
