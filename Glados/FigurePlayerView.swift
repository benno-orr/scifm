import SwiftUI
import UIKit
import Vision
import os

let figLog = Logger(subsystem: "com.borr.scifm", category: "figures")

struct FigurePlayerView: View {
    @EnvironmentObject var viewModel: PlayerViewModel
    @State private var sliderValue: Double = 0
    @State private var isDragging = false

    private var currentPanel: FigurePanel? {
        guard viewModel.currentPanelIndex < viewModel.panels.count else { return nil }
        return viewModel.panels[viewModel.currentPanelIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            sectionBar
            figureArea
            Divider()
            controls
        }
        .onReceive(viewModel.player.$currentTime) { _ in
            if !isDragging { sliderValue = viewModel.progress }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(viewModel.articleTitle)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                viewModel.player.pause()
                viewModel.showPronunciationSheet = true
            } label: {
                Image(systemName: "character.bubble").font(.caption).foregroundColor(.secondary)
            }
            Button { viewModel.showAPIKeySetup = true } label: {
                Image(systemName: "gearshape").font(.caption).foregroundColor(.secondary)
            }
            Button { viewModel.dismissSeminar() } label: {
                Image(systemName: "chevron.down").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: - Section indicator

    private var sectionBar: some View {
        HStack(spacing: 8) {
            Image(systemName: (currentPanel?.isTextSection ?? true) ? "text.alignleft" : "photo")
                .font(.caption).foregroundColor(.accentColor)
            Text(viewModel.currentSectionLabel)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Text(viewModel.stepProgressLabel)
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Figure / text area

    @ViewBuilder
    private var figureArea: some View {
        if let panel = currentPanel {
            if panel.isTextSection {
                textSection(panel)
            } else {
                figureSection(panel)
            }
        } else {
            Spacer()
            Text("No figure data available.")
                .font(.subheadline).foregroundColor(.secondary)
            Spacer()
        }
    }

    private func textSection(_ panel: FigurePanel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(panel.figureTitle).font(.title3.bold())
                Text(panel.legendText).font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private func figureSection(_ panel: FigurePanel) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let url = panel.imageURL {
                        CroppedFigureImage(url: url, panelLabel: panel.label,
                                           figureLabels: viewModel.panels
                                               .filter { $0.figureNumber == panel.figureNumber && !$0.label.isEmpty }
                                               .map(\.label))
                    } else {
                        Color(.secondarySystemBackground)
                            .overlay(Image(systemName: "photo").font(.system(size: 40)).foregroundColor(.secondary))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 260)
                .clipped()

                panelBadge(panel: panel)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if !panel.figureTitle.isEmpty {
                        Text(panel.figureTitle)
                            .font(.footnote.bold())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !panel.legendText.isEmpty {
                        Text(panel.legendText)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private func panelBadge(panel: FigurePanel) -> some View {
        let label = panel.label.isEmpty
            ? "Fig. \(panel.figureNumber)"
            : "Fig. \(panel.figureNumber)\(panel.label)"
        return Text(label)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            .padding(8)
    }

    // MARK: - Playback controls

    private var controls: some View {
        HStack(spacing: 10) {
            Button { viewModel.stepBackward() } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Circle())
            }
            .disabled(!viewModel.canStepBackward)

            Button { viewModel.player.togglePlayPause() } label: {
                Image(systemName: viewModel.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Circle())
            }

            Button { viewModel.stepForward() } label: {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Circle())
            }
            .disabled(!viewModel.canStepForward)

            VStack(spacing: 2) {
                Slider(value: $sliderValue, in: 0...1) { editing in
                    isDragging = editing
                    if !editing { viewModel.player.seek(to: sliderValue) }
                }
                HStack {
                    Text(viewModel.currentTimeFormatted)
                    Spacer()
                    Text(viewModel.durationFormatted)
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Full-screen seminar cover

/// Hosts the seminar full-screen over the whole app: the generation progress
/// while it loads, then the figure player once it's ready.
struct SeminarCover: View {
    @EnvironmentObject var viewModel: PlayerViewModel

    var body: some View {
        ZStack {
            if case .ready = viewModel.status, viewModel.mode == .figure {
                FigurePlayerView()
            } else {
                loading
            }
        }
        .charcoalBackdrop()
        .sheet(isPresented: $viewModel.showAPIKeySetup) {
            APIKeySetupView(isPresented: $viewModel.showAPIKeySetup)
        }
        .sheet(isPresented: $viewModel.showWebReader) {
            if let url = viewModel.pendingURL {
                WebReaderSheet(
                    url: url,
                    onRead: { title, body in viewModel.processWebContent(title: title, bodyText: body) },
                    onExportDoc: { title, body in viewModel.generateDocumentFromText(title: title, bodyText: body) }
                )
            }
        }
        .sheet(isPresented: $viewModel.showPronunciationSheet) {
            PronunciationSheet(context: viewModel.currentSeminarContext)
                .environmentObject(viewModel)
        }
    }

    private var loading: some View {
        VStack(spacing: 18) {
            HStack {
                Spacer()
                Button { viewModel.dismissSeminar() } label: {
                    Image(systemName: "xmark").font(.title3).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer()

            if viewModel.status == .failed {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 50)).foregroundColor(.orange)
                if let e = viewModel.errorMessage {
                    Text(e).font(.callout).foregroundColor(.red)
                        .multilineTextAlignment(.center).padding(.horizontal, 32)
                }
                if viewModel.pendingURL != nil {
                    Button { viewModel.showWebReader = true } label: {
                        Label("Read full text in browser", systemImage: "safari")
                            .font(.subheadline).padding(.horizontal, 20).padding(.vertical, 10)
                            .background(Color.accentColor.opacity(0.12)).cornerRadius(10)
                    }
                }
            } else {
                ProgressView().scaleEffect(1.6)
                Text(viewModel.seminarStatusText).font(.subheadline).foregroundColor(.secondary)
            }

            if !viewModel.articleTitle.isEmpty {
                Text(viewModel.articleTitle).font(.headline)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
            }

            Spacer()
        }
    }
}

// MARK: - Auto-cropping figure image

/// Loads a figure image (cached) and crops it to the region around the current
/// panel's letter (found via OCR). Falls back to the whole figure when the
/// letter can't be located.
struct CroppedFigureImage: View {
    let url: URL
    let panelLabel: String
    let figureLabels: [String]   // all panel letters in this figure (from the legend)

    @State private var cropped: UIImage?

    var body: some View {
        ZStack {
            // The whole figure always renders via AsyncImage (reliable).
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    Color(.secondarySystemBackground)
                        .overlay(Image(systemName: "photo").font(.system(size: 40)).foregroundColor(.secondary))
                default:
                    Color(.secondarySystemBackground).overlay(ProgressView())
                }
            }
            // When a panel crop is computed, overlay it (opaque) on top.
            if let cropped {
                Color(.secondarySystemBackground)
                Image(uiImage: cropped).resizable().scaledToFit()
            }
        }
        .task(id: "\(url.absoluteString)#\(panelLabel)") {
            cropped = nil
            guard !panelLabel.isEmpty else { return }
            let expected = Set(figureLabels.compactMap { $0.lowercased().first })
            let ocr = Self.ocrURL(url)
            guard let img = await FigureImageCache.shared.image(for: ocr) else { return }
            let boxes = await FigureImageCache.shared.labelBoxes(for: ocr, image: img, expected: expected)
            if let c = FigurePanelCropper.crop(img, label: panelLabel, labelBoxes: boxes) { cropped = c }
        }
    }

    /// Higher-resolution variant of a springer image, for legible OCR + crisp crop.
    private static func ocrURL(_ u: URL) -> URL {
        let s = u.absoluteString.replacingOccurrences(of: #"/lw\d+/"#, with: "/lw1500/", options: .regularExpression)
        return URL(string: s) ?? u
    }
}

/// A single detected panel-letter label and its pixel rect (top-left origin).
struct LabelBox { let char: Character; let rect: CGRect }

/// In-memory cache + de-duplicated loader for figure images (with a browser
/// User-Agent — some publishers reject the default agent), plus a per-image
/// cache of OCR'd panel-letter positions.
@MainActor
final class FigureImageCache {
    static let shared = FigureImageCache()
    private let cache = NSCache<NSURL, UIImage>()
    private var labels: [URL: [LabelBox]] = [:]

    func image(for url: URL) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
                     forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let img = UIImage(data: data) else {
                figLog.log("img DECODE FAIL \(url.absoluteString, privacy: .public) bytes=\(data.count)")
                return nil
            }
            cache.setObject(img, forKey: url as NSURL)
            figLog.log("img OK \(url.absoluteString, privacy: .public) \(Int(img.size.width))x\(Int(img.size.height))")
            return img
        } catch {
            figLog.log("img LOAD FAIL \(url.absoluteString, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// OCR'd positions of the figure's known panel letters, computed once + cached.
    func labelBoxes(for url: URL, image: UIImage, expected: Set<Character>) async -> [LabelBox] {
        if let hit = labels[url] { return hit }
        let found = await FigurePanelCropper.detectLabels(in: image, expected: expected)
        labels[url] = found
        return found
    }
}

/// Experimental per-panel cropping: locate the panel's letter in the figure via
/// Vision OCR, then crop the region from that letter to its right/below
/// neighbours. Best-effort — falls back to the whole figure when unsure.
enum FigurePanelCropper {
    /// Locates the figure's known panel letters (`expected`) in the image and
    /// returns one pixel rect per letter (top-left origin). Runs OCR off-main.
    static func detectLabels(in image: UIImage, expected: Set<Character>) async -> [LabelBox] {
        guard let cg = image.cgImage, !expected.isEmpty else { return [] }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        return await Task.detached(priority: .userInitiated) {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = false
            req.recognitionLanguages = ["en-US"]
            req.minimumTextHeight = 0.008
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            try? handler.perform([req])

            var candidates: [LabelBox] = []
            for obs in (req.results ?? []) {
                for cand in obs.topCandidates(3) {
                    let t = cand.string.trimmingCharacters(in: .whitespaces)
                    // Panel marker: an expected letter standing alone or leading a
                    // clause ("a", "a.", "a Schematic of…").
                    guard let ch = t.first, ch.isLetter else { continue }
                    let lower = Character(ch.lowercased())
                    guard expected.contains(lower) else { continue }
                    if t.count > 1 {
                        let second = t[t.index(after: t.startIndex)]
                        if second.isLetter || second.isNumber { continue }
                    }
                    let b = obs.boundingBox
                    candidates.append(LabelBox(char: lower,
                                               rect: CGRect(x: b.minX * W, y: (1 - b.maxY) * H,
                                                            width: b.width * W, height: b.height * H)))
                    break
                }
            }
            // Keep the topmost-leftmost occurrence of each letter (the panel label
            // rather than an incidental letter elsewhere in the figure).
            var best: [Character: LabelBox] = [:]
            for lb in candidates {
                if let e = best[lb.char],
                   !(lb.rect.minY < e.rect.minY || (lb.rect.minY == e.rect.minY && lb.rect.minX < e.rect.minX)) {
                    continue
                }
                best[lb.char] = lb
            }
            return Array(best.values)
        }.value
    }

    /// Crops to the panel for `label`, or nil if it can't be located/sized.
    static func crop(_ image: UIImage, label: String, labelBoxes: [LabelBox]) -> UIImage? {
        guard let cg = image.cgImage, let target = label.lowercased().first, !labelBoxes.isEmpty
        else { return nil }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)

        // Pick the topmost-leftmost occurrence of this letter (panel labels sit at
        // the top-left of their panel).
        let matches = labelBoxes.filter { $0.char == target }.sorted {
            $0.rect.minY != $1.rect.minY ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX
        }
        guard let lab = matches.first else { return nil }
        let lx = lab.rect.minX, ly = lab.rect.minY
        let rowTol = H * 0.05

        // Panel extends right to the next label in the same row, and down to the
        // next row of labels.
        let rightBound = labelBoxes
            .filter { abs($0.rect.minY - ly) < rowTol && $0.rect.minX > lx + W * 0.02 }
            .map { $0.rect.minX }.min() ?? W
        let bottomBound = labelBoxes
            .filter { $0.rect.minY > ly + rowTol }
            .map { $0.rect.minY }.min() ?? H

        let x0 = max(0, lx - W * 0.015)
        let y0 = max(0, ly - H * 0.015)
        let rect = CGRect(x: x0, y: y0,
                          width: min(rightBound, W) - x0,
                          height: min(bottomBound, H) - y0).integral
        // Don't crop to a sliver — require a sensible region.
        guard rect.width > W * 0.1, rect.height > H * 0.1, let sub = cg.cropping(to: rect)
        else { return nil }
        return UIImage(cgImage: sub, scale: image.scale, orientation: image.imageOrientation)
    }
}
