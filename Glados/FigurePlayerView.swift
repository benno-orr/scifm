import SwiftUI
import UIKit
import Vision

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
                        CroppedFigureImage(url: url, panelLabel: panel.label)
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
                WebReaderSheet(url: url) { title, body in
                    viewModel.processWebContent(title: title, bodyText: body)
                }
            }
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

    @State private var full: UIImage?
    @State private var cropped: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let img = cropped ?? full {
                Image(uiImage: img).resizable().scaledToFit()
            } else if failed {
                Color(.secondarySystemBackground)
                    .overlay(Image(systemName: "photo").font(.system(size: 40)).foregroundColor(.secondary))
            } else {
                Color(.secondarySystemBackground).overlay(ProgressView())
            }
        }
        // Load + show the whole figure as soon as it arrives (don't wait on OCR).
        .task(id: url) {
            full = await FigureImageCache.shared.image(for: url)
            failed = (full == nil)
        }
        // Then refine to the cropped panel in the background.
        .task(id: "\(url.absoluteString)#\(panelLabel)") {
            cropped = nil
            guard !panelLabel.isEmpty, let f = await FigureImageCache.shared.image(for: url) else { return }
            let labels = await FigureImageCache.shared.labelBoxes(for: url, image: f)
            let result = FigurePanelCropper.crop(f, label: panelLabel, labelBoxes: labels)
            // Only show a crop if it actually narrowed the figure.
            cropped = result.size == f.size ? nil : result
        }
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
    private var inflight: [URL: Task<UIImage?, Never>] = [:]
    private var labels: [URL: [LabelBox]] = [:]

    func image(for url: URL) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        if let task = inflight[url] { return await task.value }
        let task = Task<UIImage?, Never> {
            var req = URLRequest(url: url)
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
                         forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 30
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let img = UIImage(data: data) else { return nil }
            return img
        }
        inflight[url] = task
        let img = await task.value
        inflight[url] = nil
        if let img { cache.setObject(img, forKey: url as NSURL) }
        return img
    }

    /// OCR'd single-letter panel labels for an image, computed once and cached.
    func labelBoxes(for url: URL, image: UIImage) async -> [LabelBox] {
        if let hit = labels[url] { return hit }
        let found = await FigurePanelCropper.detectLabels(in: image)
        labels[url] = found
        return found
    }
}

/// Experimental per-panel cropping: locate the panel's letter in the figure via
/// Vision OCR, then crop the region from that letter to its right/below
/// neighbours. Best-effort — falls back to the whole figure when unsure.
enum FigurePanelCropper {
    /// Detects isolated single-letter labels and returns their pixel rects
    /// (top-left origin). Runs OCR off the main thread.
    static func detectLabels(in image: UIImage) async -> [LabelBox] {
        guard let cg = image.cgImage else { return [] }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        return await Task.detached(priority: .userInitiated) {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            try? handler.perform([req])
            var out: [LabelBox] = []
            for obs in (req.results ?? []) {
                guard let cand = obs.topCandidates(1).first else { continue }
                let t = cand.string.trimmingCharacters(in: .whitespaces)
                let letters = t.filter { $0.isLetter }
                guard t.count <= 2, letters.count == 1, let ch = letters.first else { continue }
                let b = obs.boundingBox    // normalized, origin bottom-left
                let rect = CGRect(x: b.minX * W, y: (1 - b.maxY) * H, width: b.width * W, height: b.height * H)
                out.append(LabelBox(char: Character(ch.lowercased()), rect: rect))
            }
            return out
        }.value
    }

    static func crop(_ image: UIImage, label: String, labelBoxes: [LabelBox]) -> UIImage {
        guard let cg = image.cgImage, let target = label.lowercased().first, !labelBoxes.isEmpty
        else { return image }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)

        // Pick the topmost-leftmost occurrence of this letter (panel labels sit at
        // the top-left of their panel).
        let matches = labelBoxes.filter { $0.char == target }.sorted {
            $0.rect.minY != $1.rect.minY ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX
        }
        guard let lab = matches.first else { return image }
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
        else { return image }
        return UIImage(cgImage: sub, scale: image.scale, orientation: image.imageOrientation)
    }
}
