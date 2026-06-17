import SwiftUI
import Combine
import UniformTypeIdentifiers
import UIKit

// MARK: - Model

struct SentenceTimestamp {
    let text: String
    let startTime: TimeInterval
}

enum AppMode: Equatable { case narration, figure }

// MARK: - ViewModel

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var status: PlayerStatus = .idle
    @Published var articleTitle: String = ""
    @Published var errorMessage: String? = nil
    @Published var showAPIKeySetup = false
    @Published var showWebReader = false
    @Published var costPrompt: CostPrompt? = nil
    @Published var mode: AppMode = .narration
    /// Drives the full-screen seminar cover presented over the whole app.
    @Published var showSeminar = false
    /// Set to route the Debug tab to a paper's figures (e.g. from Seminarize).
    @Published var debugFigureURL: URL? = nil
    @Published var exportMarkdown: String = ""
    @Published var featuredImageURL: URL? = nil
    // Narration mode
    @Published var sentences: [SentenceTimestamp] = []
    @Published var currentSentenceIndex: Int = 0
    // Figure mode
    @Published var panels: [FigurePanel] = []
    @Published var panelTimestamps: [PanelTimestamp] = []
    @Published var currentPanelIndex: Int = 0
    /// Presents the "fix pronunciation" sheet (from either player).
    @Published var showPronunciationSheet = false

    // Document export (cleaned .md for third-party readers like ElevenReader) —
    // independent of the audio pipeline, so it doesn't disturb playback.
    @Published var showDocumentSheet = false
    @Published var documentExport: DocumentExport? = nil
    @Published var documentStatus = ""
    @Published var documentError: String? = nil

    /// Full narration plan of the current article, so a pronunciation fix can
    /// regenerate the rest of it — including not-yet-generated chunks.
    private var narrationPlan: [NarrationUnit] = []
    /// Per-panel narration text captured during seminar generation, so a fix can
    /// re-speak the remaining panels without re-calling the LLM.
    private var panelNarrations: [Int: String] = [:]

    let player = AudioPlayer()
    private let processor = ArticleProcessor()
    private let deepgramTTS = DeepgramTTS()
    private let openAITTS = OpenAITTS()
    private var cancellables = Set<AnyCancellable>()
    private var currentSourceURL: String = ""
    private var currentLibraryItemID: UUID? = nil
    private var currentKind: ContentKind = .other
    private(set) var pendingURL: URL? = nil
    /// Identifies the active TTS generation. Refreshed whenever playback is
    /// stopped or replaced, so in-flight generation loops abort instead of
    /// appending into (or stopping) a newer session's engine.
    private var generationToken = UUID()
    /// Below this estimate, skip the confirm dialog and just play.
    private static let costPromptThreshold = 0.02
    private var costPromptContinuation: CheckedContinuation<Bool, Never>?

    /// Asks the user to confirm a TTS spend. Returns true to proceed. Trivially
    /// cheap reads (< threshold) proceed without prompting.
    private func confirmCost(chars: Int) async -> Bool {
        let provider = AppSettings.ttsProvider
        let estimate = Pricing.ttsCost(chars: chars, provider: provider)
        guard estimate >= Self.costPromptThreshold else { return true }
        costPromptContinuation?.resume(returning: false)   // defensively clear any stale prompt
        return await withCheckedContinuation { cont in
            costPromptContinuation = cont
            costPrompt = CostPrompt(chars: chars, estimate: estimate, provider: provider.displayName)
        }
    }

    func resolveCostPrompt(_ proceed: Bool) {
        costPrompt = nil
        costPromptContinuation?.resume(returning: proceed)
        costPromptContinuation = nil
    }

    init() {
        player.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        player.onPlaybackFinished = { [weak self] in
            guard let self, let id = self.currentLibraryItemID else { return }
            let full = self.player.duration
            Task { await LibraryManager.shared.updateLastPlayedTime(id, time: full) }
        }
    }

    func load(url: URL, kind: ContentKind = .other) {
        pendingURL = url
        currentSourceURL = url.absoluteString
        currentKind = kind
        mode = (kind == .seminar) ? .figure : .narration
        if mode == .figure {
            // Present the full-screen seminar cover immediately and clear stale
            // panel state before loadFigures (async) runs.
            showSeminar = true
            status = .fetching
            panels = []
            panelTimestamps = []
            currentPanelIndex = 0
            Task { await loadFigures(url: url) }
        } else {
            showWebReader = true
        }
    }

    /// Clears a failed-load screen and returns the Player tab to the Library home.
    func dismissFailure() {
        errorMessage = nil
        pendingURL = nil
        status = .idle
    }

    /// Dismisses the seminar cover (playback continues underneath). If the load
    /// failed, also resets so the cover starts clean next time.
    func dismissSeminar() {
        showSeminar = false
        if status == .failed { dismissFailure() }
    }

    /// Cancels an in-progress seminar: aborts generation, stops audio, and
    /// dismisses the cover.
    func cancelSeminar() {
        stop()
        showSeminar = false
    }

    /// Progress text shown on the seminar cover while it generates.
    var seminarStatusText: String {
        switch status {
        case .fetching:               return "Fetching figures…"
        case .cleaning:               return "Preparing…"
        case .generating(let d, let t): return "Generating audio… (\(d)/\(t))"
        default:                      return "Loading…"
        }
    }

    func processWebContent(title: String, bodyText: String) {
        showWebReader = false
        showSeminar = false   // switching to narration; leave the seminar cover
        Task {
            articleTitle = title
            currentLibraryItemID = nil
            exportMarkdown = ""
            status = .generating(0, 1)
            errorMessage = nil
            do {
                let cleaned = await processor.cleanText(bodyText)
                let article = ProcessedArticle(title: title, authors: [], abstract: "", bodyText: cleaned)
                try await generateAudio(article)
            } catch let err as DeepgramError {
                if case .missingAPIKey = err { showAPIKeySetup = true }
                errorMessage = err.localizedDescription
                status = .idle
            } catch {
                errorMessage = error.localizedDescription
                status = .idle
            }
        }
    }

    func stop() {
        if let id = currentLibraryItemID {
            let t = player.currentTime
            Task { await LibraryManager.shared.updateLastPlayedTime(id, time: t) }
        }
        generationToken = UUID()   // abort any in-flight generation
        player.stop()
        status = .idle
    }

    // MARK: - Document export (cleaned .md, no TTS)

    /// Fetches + cleans an article and produces a pronunciation-corrected Markdown
    /// document for export to third-party readers (e.g. ElevenReader) — no audio
    /// is generated and current playback is left untouched.
    func generateDocument(url: URL) {
        pendingURL = url
        documentExport = nil
        documentError = nil
        documentStatus = "Fetching article…"
        showDocumentSheet = true
        Task {
            do {
                async let imageURL = processor.extractFeaturedImage(from: url)
                let article = try await processor.process(url: url)
                documentStatus = "Cleaning text…"
                await buildDocument(title: article.title, rawBody: article.fullText,
                                    sourceURL: url.absoluteString, imageURL: await imageURL)
            } catch let err as DeepgramError {
                if case .missingAPIKey = err { showAPIKeySetup = true }
                documentError = err.localizedDescription
            } catch {
                documentError = error.localizedDescription
            }
        }
    }

    /// Builds a document from text already extracted in the in-app browser (the
    /// fallback when a direct fetch fails — common for Nature/Cell pages).
    func generateDocumentFromText(title: String, bodyText: String) {
        showWebReader = false
        documentExport = nil
        documentError = nil
        documentStatus = "Cleaning text…"
        showDocumentSheet = true
        Task {
            let cleaned = await processor.cleanText(bodyText)
            await buildDocument(title: title, rawBody: cleaned,
                                sourceURL: pendingURL?.absoluteString ?? "", imageURL: nil)
        }
    }

    /// Shared tail of document generation: LLM cleanup, then pronunciation rewrite
    /// applied LAST so the corrections (and the user dictionary) survive into the
    /// exported text verbatim.
    private func buildDocument(title: String, rawBody: String, sourceURL: String, imageURL: URL?) async {
        let cleaned = await LLMCleaner.shared.clean(title: title, text: rawBody)
        let pronounced = ScientificPronunciation.rewrite(cleaned)
        let md = buildMarkdown(title: title, body: pronounced, sourceURL: sourceURL, imageURL: imageURL)
        documentExport = DocumentExport(title: title, markdown: md)
    }

    /// From the document error screen: retry by extracting the text in the browser
    /// (where the user can tap "Export .md").
    func startDocFromBrowser() {
        showDocumentSheet = false
        showWebReader = true
    }

    func loadLibraryItem(_ item: LibraryItem) async {
        // Already the active item (still generating or just paused) — resume in
        // place rather than reloading or regenerating.
        if item.id == currentLibraryItemID, status != .idle {
            if !player.isPlaying { player.play() }
            return
        }
        await LibraryManager.shared.markTouched(item.id)
        if let id = currentLibraryItemID {
            let t = player.currentTime
            await LibraryManager.shared.updateLastPlayedTime(id, time: t)
        }
        generationToken = UUID()   // abort any in-flight generation
        player.stop()
        sentences = []; currentSentenceIndex = 0
        panels = []; panelTimestamps = []; currentPanelIndex = 0
        narrationPlan = []; panelNarrations = [:]
        status = .fetching
        errorMessage = nil

        guard let wavData = await LibraryManager.shared.audioData(for: item) else {
            // Entry created but audio not yet generated (e.g. interrupted) —
            // regenerate from the original source.
            if let url = URL(string: item.sourceURL) {
                load(url: url, kind: item.contentKind)
            } else {
                errorMessage = "Could not load audio file."
                status = .idle
            }
            return
        }
        do {
            articleTitle = item.title
            currentLibraryItemID = item.id
            currentSourceURL = item.sourceURL
            currentKind = item.contentKind

            if item.contentKind == .seminar, let stored = item.panels, !stored.isEmpty {
                mode = .figure
                showSeminar = true
                panels = stored.map {
                    FigurePanel(figureNumber: $0.figureNumber, figureTitle: $0.figureTitle,
                                label: $0.label, legendText: $0.legendText,
                                textReferences: [], imageURL: $0.imageURL.flatMap { URL(string: $0) })
                }
                panelTimestamps = stored.enumerated().map { i, p in
                    PanelTimestamp(panelIndex: i, figureNumber: p.figureNumber,
                                   panelLabel: p.label, startTime: p.startTime)
                }
            } else {
                mode = .narration
                sentences = item.sentences.map { SentenceTimestamp(text: $0.text, startTime: $0.startTime) }
            }

            try player.load(wavData: wavData)
            if item.lastPlayedTime > 0 { player.seekAbsolute(to: item.lastPlayedTime) }
            player.setNowPlaying(title: item.title)
            status = .ready
            player.play()
        } catch {
            errorMessage = error.localizedDescription
            status = .idle
        }
    }

    var progress: Double {
        guard player.duration > 0 else { return 0 }
        return player.currentTime / player.duration
    }
    var currentTimeFormatted: String { formatTime(player.currentTime) }
    var durationFormatted: String { formatTime(player.duration) }

    // MARK: - Figure mode

    private func loadFigures(url: URL) async {
        if let id = currentLibraryItemID {
            let t = player.currentTime
            await LibraryManager.shared.updateLastPlayedTime(id, time: t)
        }
        generationToken = UUID()   // abort any in-flight generation
        player.stop()
        panels = []
        panelTimestamps = []
        currentPanelIndex = 0
        panelNarrations = [:]
        narrationPlan = []
        currentLibraryItemID = nil
        status = .fetching
        errorMessage = nil
        do {
            let result = try await processor.processFigures(url: url)
            articleTitle = result.title
            panels = result.panels
            try await generateFigureAudio(result.panels)
        } catch let err as DeepgramError {
            if case .missingAPIKey = err { showAPIKeySetup = true }
            errorMessage = err.localizedDescription
            status = .failed
        } catch {
            errorMessage = error.localizedDescription
            status = .failed
        }
    }

    private func generateFigureAudio(_ panels: [FigurePanel]) async throws {
        var allPCM = Data()
        var cumulativeTime: TimeInterval = 0
        var timestamps: [PanelTimestamp] = []
        var started = false
        let gen = UUID()
        generationToken = gen
        status = .generating(0, panels.count)
        player.startStreaming()   // stream into the engine as audio generates

        // Register the seminar in the Library immediately and update it after each
        // section, so a TTS timeout (or leaving mid-generation) keeps everything
        // produced so far rather than losing the whole thing.
        let entry = await LibraryManager.shared.startEntry(
            title: articleTitle, sourceURL: currentSourceURL, kind: .seminar)
        currentLibraryItemID = entry.id

        func beginPlaybackIfNeeded() {
            guard !started else { return }
            started = true
            player.setNowPlaying(title: articleTitle)
            status = .ready
            player.play()
        }

        func persistProgress() async {
            let wav = WAVBuilder.make(pcmData: allPCM)
            let stored = zip(panels, timestamps).map { panel, ts in
                StoredPanel(figureNumber: panel.figureNumber, label: panel.label,
                            figureTitle: panel.figureTitle, legendText: panel.legendText,
                            imageURL: panel.imageURL?.absoluteString, startTime: ts.startTime)
            }
            await LibraryManager.shared.finalizeEntry(
                entry.id, wavData: wav, sentences: [], duration: player.duration, panels: stored)
        }

        // Timeline = leading text sections (Abstract, Introduction) then figures.
        for (i, panel) in panels.enumerated() {
            guard generationToken == gen else { return }
            status = .generating(i + 1, panels.count)

            // Record this panel's start before generating it; publish incrementally
            // so the section indicator / figure view sync during streaming.
            timestamps.append(PanelTimestamp(panelIndex: i, figureNumber: panel.figureNumber,
                                             panelLabel: panel.label, startTime: cumulativeTime))
            panelTimestamps = timestamps

            let narration = await panelNarration(panel)
            panelNarrations[i] = narration

            var chunkPCM = Data()
            for chunk in TextChunker.chunk(narration) {
                guard generationToken == gen else { return }
                // Fetch the whole chunk (with one retry) before feeding it to the
                // player, so a transient TTS timeout can be retried/skipped rather
                // than aborting the entire seminar.
                guard let pcm = await ttsChunk(chunk, token: gen) else { continue }
                guard generationToken == gen else { return }
                player.appendPCM(pcm)
                chunkPCM.append(pcm)
                CostTracker.shared.record(Pricing.ttsCost(chars: chunk.count, provider: AppSettings.ttsProvider))
                beginPlaybackIfNeeded()
            }
            cumulativeTime += TimeInterval(chunkPCM.count) / TimeInterval(24000 * 2)
            allPCM.append(chunkPCM)
            beginPlaybackIfNeeded()

            // Save at each section boundary, bounding how much a failure can lose.
            let isLast = i == panels.count - 1
            if isLast || panels[i + 1].sectionKey != panel.sectionKey { await persistProgress() }
        }

        guard generationToken == gen else { return }
        // If every chunk failed (e.g. no connection), surface a clear error.
        guard !allPCM.isEmpty else {
            throw NSError(domain: "Seminar", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't generate audio — check your connection and try again."])
        }
        player.finalizeStreaming()
        player.setNowPlaying(title: articleTitle)   // refresh Now Playing duration
        await persistProgress()
    }

    /// Streams one TTS chunk to completion and returns its PCM, retrying once on
    /// failure (e.g. a request timeout). Returns nil if it ultimately fails or the
    /// generation was superseded.
    private func ttsChunk(_ chunk: String, token: UUID) async -> Data? {
        for attempt in 0..<2 {
            guard generationToken == token else { return nil }
            do {
                var pcm = Data()
                let stream = try await streamTTS(chunk)
                for try await data in stream {
                    guard generationToken == token else { return nil }
                    pcm.append(data)
                }
                return pcm
            } catch {
                if attempt == 1 { return nil }   // gave up after a retry
            }
        }
        return nil
    }

    private func buildNarration(for panel: FigurePanel) -> String {
        var parts: [String] = []
        let figLabel = panel.label.isEmpty
            ? "Figure \(panel.figureNumber)."
            : "Figure \(panel.figureNumber), panel \(panel.label)."
        parts.append(figLabel)
        if !panel.figureTitle.isEmpty { parts.append(panel.figureTitle) }
        if !panel.legendText.isEmpty  { parts.append(panel.legendText) }
        parts.append(contentsOf: panel.textReferences)
        return parts.joined(separator: " ")
    }

    /// The narration for one seminar panel (section title + LLM-merged legend),
    /// pronunciation-rewritten. The LLM merge is the expensive part — cached into
    /// `panelNarrations` during generation so a fix can re-speak without re-calling.
    private func panelNarration(_ panel: FigurePanel) async -> String {
        if panel.isTextSection {
            return ScientificPronunciation.rewrite("\(panel.figureTitle). \(panel.legendText)")
        }
        let figLabel = panel.label.isEmpty
            ? "Figure \(panel.figureNumber)."
            : "Figure \(panel.figureNumber), panel \(panel.label)."
        let figRef = panel.label.isEmpty
            ? "Figure \(panel.figureNumber)"
            : "Figure \(panel.figureNumber)\(panel.label)"
        let merged = await LLMCleaner.shared.mergeForFigure(
            figureRef: figRef, legendText: panel.legendText, contextSentences: panel.textReferences)
        return ScientificPronunciation.rewrite("\(figLabel) \(merged)")
    }

    // MARK: - Live pronunciation fixes

    /// Text shown in the fix sheet to help the listener spot the offending word.
    var currentNarrationContext: String {
        guard currentSentenceIndex < sentences.count else { return "" }
        return sentences[currentSentenceIndex].text
    }
    var currentSeminarContext: String {
        guard currentPanelIndex < panels.count else { return "" }
        let p = panels[currentPanelIndex]
        return p.legendText.isEmpty ? p.figureTitle : p.legendText
    }

    /// Saves a pronunciation to the dictionary and regenerates the rest of the
    /// current article (from the current position) with the fix applied.
    func applyPronunciation(word: String, sayAs: String) {
        PronunciationStore.shared.add(word: word, replacement: sayAs)
        switch mode {
        case .narration: regenerateNarrationTail()
        case .figure:    regenerateSeminarTail()
        }
    }

    /// Suffix of a narration plan starting at the `cut`-th speak unit (inclusive),
    /// dropping any pause that immediately precedes it (already in the kept head).
    private static func planSuffix(_ plan: [NarrationUnit], fromSpeakIndex cut: Int) -> [NarrationUnit] {
        var speakSeen = -1
        for (i, u) in plan.enumerated() {
            if case .speak = u {
                speakSeen += 1
                if speakSeen == cut { return Array(plan[i...]) }
            }
        }
        return []
    }

    private func regenerateNarrationTail() {
        guard mode == .narration, !sentences.isEmpty else { return }
        let t = player.currentTime
        var cut = 0
        for (i, s) in sentences.enumerated() { if s.startTime <= t { cut = i } else { break } }
        let cutTime = sentences[cut].startTime
        guard let head = player.currentPCMHead(upTo: cutTime) else { return }
        let kept = Array(sentences[0..<cut])
        // Prefer the full plan (covers chunks not yet generated); otherwise fall
        // back to the generated sentences (a replayed library item).
        let tail: [NarrationUnit] = narrationPlan.isEmpty
            ? sentences[cut...].map { .speak($0.text) }
            : Self.planSuffix(narrationPlan, fromSpeakIndex: cut)
        generationToken = UUID()
        let gen = generationToken
        Task { await streamNarrationTail(head: head, cutTime: cutTime, kept: kept, tail: tail, gen: gen) }
    }

    private func streamNarrationTail(head: Data, cutTime: TimeInterval,
                                     kept: [SentenceTimestamp], tail: [NarrationUnit], gen: UUID) async {
        player.startStreaming(seeded: true)
        player.appendPCM(head)
        player.seekAbsolute(to: cutTime)   // resume from the splice; head plays from here

        var allPCM = head
        var rebuilt = kept
        var cumulative = cutTime
        status = .ready
        for unit in tail {
            guard generationToken == gen else { return }
            switch unit {
            case .pause(let secs):
                player.appendSilence(secs)
                allPCM.append(Data(count: Int(secs * 24000) * 2))
                cumulative += secs
            case .speak(let original):
                rebuilt.append(SentenceTimestamp(text: original, startTime: cumulative))
                sentences = rebuilt
                var chunkPCM = Data()
                for piece in TextChunker.chunk(ScientificPronunciation.rewrite(original)) {
                    guard generationToken == gen else { return }
                    guard let pcm = await ttsChunk(piece, token: gen) else { continue }
                    guard generationToken == gen else { return }
                    player.appendPCM(pcm)
                    chunkPCM.append(pcm)
                    CostTracker.shared.record(Pricing.ttsCost(chars: piece.count, provider: AppSettings.ttsProvider))
                }
                cumulative += TimeInterval(chunkPCM.count) / TimeInterval(24000 * 2)
                allPCM.append(chunkPCM)
            }
        }
        guard generationToken == gen else { return }
        player.finalizeStreaming()
        player.setNowPlaying(title: articleTitle)
        sentences = rebuilt
        if let id = currentLibraryItemID {
            let wav = WAVBuilder.make(pcmData: allPCM)
            let stored = rebuilt.map { StoredSentence(text: $0.text, startTime: $0.startTime) }
            await LibraryManager.shared.finalizeEntry(id, wavData: wav, sentences: stored, duration: player.duration)
        }
    }

    private func regenerateSeminarTail() {
        guard mode == .figure, !panels.isEmpty, currentPanelIndex < panelTimestamps.count else { return }
        let cut = currentPanelIndex
        let cutTime = panelTimestamps[cut].startTime
        guard let head = player.currentPCMHead(upTo: cutTime) else { return }
        generationToken = UUID()
        let gen = generationToken
        Task { await streamSeminarTail(fromIndex: cut, head: head, cutTime: cutTime, gen: gen) }
    }

    private func streamSeminarTail(fromIndex cut: Int, head: Data, cutTime: TimeInterval, gen: UUID) async {
        player.startStreaming(seeded: true)
        player.appendPCM(head)
        player.seekAbsolute(to: cutTime)

        var allPCM = head
        var timestamps = Array(panelTimestamps[0..<cut])
        var cumulative = cutTime
        status = .ready
        for i in cut..<panels.count {
            guard generationToken == gen else { return }
            let panel = panels[i]
            timestamps.append(PanelTimestamp(panelIndex: i, figureNumber: panel.figureNumber,
                                             panelLabel: panel.label, startTime: cumulative))
            panelTimestamps = timestamps
            // Re-speak from the cached narration (re-applying the rewrite so the new
            // entry takes), rebuilding via the LLM only for any panel not yet cached.
            let base: String
            if let cached = panelNarrations[i] { base = cached }
            else { base = await panelNarration(panel) }
            panelNarrations[i] = base
            var chunkPCM = Data()
            for piece in TextChunker.chunk(ScientificPronunciation.rewrite(base)) {
                guard generationToken == gen else { return }
                guard let pcm = await ttsChunk(piece, token: gen) else { continue }
                guard generationToken == gen else { return }
                player.appendPCM(pcm)
                chunkPCM.append(pcm)
                CostTracker.shared.record(Pricing.ttsCost(chars: piece.count, provider: AppSettings.ttsProvider))
            }
            cumulative += TimeInterval(chunkPCM.count) / TimeInterval(24000 * 2)
            allPCM.append(chunkPCM)
        }
        guard generationToken == gen else { return }
        player.finalizeStreaming()
        player.setNowPlaying(title: articleTitle)
        if let id = currentLibraryItemID {
            let wav = WAVBuilder.make(pcmData: allPCM)
            let stored = zip(panels, timestamps).map { panel, ts in
                StoredPanel(figureNumber: panel.figureNumber, label: panel.label,
                            figureTitle: panel.figureTitle, legendText: panel.legendText,
                            imageURL: panel.imageURL?.absoluteString, startTime: ts.startTime)
            }
            await LibraryManager.shared.finalizeEntry(
                id, wavData: wav, sentences: [], duration: player.duration, panels: stored)
        }
    }

    func updateCurrentPanel(at time: TimeInterval) {
        guard !panelTimestamps.isEmpty else { return }
        var idx = 0
        for (i, ts) in panelTimestamps.enumerated() {
            if ts.startTime <= time { idx = i } else { break }
        }
        if idx != currentPanelIndex { currentPanelIndex = idx }
    }

    // MARK: - Seminar sections

    /// Label for the current section, e.g. "Abstract", "Introduction", "Figure 1 · A".
    var currentSectionLabel: String {
        guard currentPanelIndex < panels.count else { return "" }
        let p = panels[currentPanelIndex]
        if p.isTextSection { return p.sectionTitle }
        return p.label.isEmpty ? p.sectionTitle : "\(p.sectionTitle) · \(p.label)"
    }

    /// "3 / 24" — current step among the whole timeline (Intro, Fig 1a, Fig 1b, …, Discussion).
    var stepProgressLabel: String {
        guard !panels.isEmpty, currentPanelIndex < panels.count else { return "" }
        return "\(currentPanelIndex + 1) / \(panels.count)"
    }

    var canStepBackward: Bool { player.canSeek && currentPanelIndex > 0 }
    var canStepForward: Bool {
        guard player.canSeek, currentPanelIndex + 1 < panelTimestamps.count else { return false }
        // Only allow stepping to a section whose audio has been generated.
        return panelTimestamps[currentPanelIndex + 1].startTime <= player.duration + 0.5
    }

    /// Steps one entry forward (Intro → Fig 1a → Fig 1b → Fig 2a → … → Discussion).
    /// Seeking is only possible off the streaming engine (i.e. on replay).
    func stepForward() {
        guard player.canSeek else { return }
        let next = currentPanelIndex + 1
        guard next < panelTimestamps.count else { return }
        player.seekAbsolute(to: panelTimestamps[next].startTime)
        currentPanelIndex = next
    }

    /// Steps one entry backward in the timeline.
    func stepBackward() {
        guard player.canSeek else { return }
        let prev = currentPanelIndex - 1
        guard prev >= 0, prev < panelTimestamps.count else { return }
        player.seekAbsolute(to: panelTimestamps[prev].startTime)
        currentPanelIndex = prev
    }

    func updateCurrentSentence(at time: TimeInterval) {
        guard !sentences.isEmpty else { return }
        var idx = 0
        for (i, s) in sentences.enumerated() {
            if s.startTime <= time { idx = i } else { break }
        }
        if idx != currentSentenceIndex { currentSentenceIndex = idx }
    }

    /// Plays a short text (e.g. an abstract) directly without the full article pipeline.
    /// Reads a short, already-resolved text (abstract/briefing/generated summary).
    /// Feed read-text resolution lives in `FeedManager.readingText(for:)`.
    func readText(_ text: String, title: String) {
        if let id = currentLibraryItemID {
            let t = player.currentTime
            Task { await LibraryManager.shared.updateLastPlayedTime(id, time: t) }
        }
        generationToken = UUID()   // abort any in-flight generation
        player.stop()
        sentences = []; currentSentenceIndex = 0
        narrationPlan = []
        currentLibraryItemID = nil; exportMarkdown = ""; featuredImageURL = nil
        articleTitle = title; errorMessage = nil
        Task {
            do {
                let rewritten = ScientificPronunciation.rewrite(text)
                let chunks = TextChunker.chunk(rewritten)
                guard await confirmCost(chars: rewritten.count) else { status = .idle; return }
                var allPCM = Data()
                var cumulativeTime: TimeInterval = 0
                var built: [SentenceTimestamp] = []
                status = .generating(0, chunks.count)
                let gen = UUID()
                generationToken = gen
                player.startStreaming()
                for (i, chunk) in chunks.enumerated() {
                    guard generationToken == gen else { return }
                    if case .generating = status { status = .generating(i + 1, chunks.count) }
                    built.append(SentenceTimestamp(text: chunk, startTime: cumulativeTime))
                    var chunkPCM = Data()
                    let stream = try await streamTTS(chunk)
                    for try await data in stream {
                        guard generationToken == gen else { return }
                        chunkPCM.append(data)
                        player.appendPCM(data)
                    }
                    CostTracker.shared.record(Pricing.ttsCost(chars: chunk.count, provider: AppSettings.ttsProvider))
                    cumulativeTime += TimeInterval(chunkPCM.count) / TimeInterval(24000 * 2)
                    allPCM.append(chunkPCM)
                    if i == 0 {
                        player.setNowPlaying(title: title)
                        status = .ready
                    }
                }
                guard generationToken == gen else { return }
                sentences = built
                player.finalizeStreaming()
                player.setNowPlaying(title: title)
            } catch let err as TTSError {
                if case .missingAPIKey = err { showAPIKeySetup = true }
                errorMessage = err.localizedDescription; status = .idle
            } catch {
                errorMessage = error.localizedDescription; status = .idle
            }
        }
    }

    private func buildMarkdown(title: String, body: String, sourceURL: String, imageURL: URL?) -> String {
        // Trailing space on each paragraph gives ElevenReader a natural pause at paragraph breaks
        let paddedBody = body
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) + " " }
            .filter { $0.count > 1 }
            .joined(separator: "\n\n")

        var parts: [String] = ["# \(title)"]
        if !sourceURL.isEmpty {
            parts.append("> \(sourceURL)")
        }
        if let img = imageURL {
            parts.append("![\(title)](\(img.absoluteString))")
        }
        parts.append("---")
        parts.append(paddedBody)
        return parts.joined(separator: "\n\n")
    }

    private func streamTTS(_ text: String) async throws -> AsyncThrowingStream<Data, Error> {
        switch AppSettings.ttsProvider {
        case .deepgram: return try await deepgramTTS.stream(text: text)
        case .openai:   return try await openAITTS.stream(text: text)
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }

    private func loadArticle(url: URL) async {
        if let id = currentLibraryItemID {
            let t = player.currentTime
            await LibraryManager.shared.updateLastPlayedTime(id, time: t)
        }
        generationToken = UUID()   // abort any in-flight generation
        player.stop()
        sentences = []
        currentSentenceIndex = 0
        narrationPlan = []
        currentLibraryItemID = nil
        exportMarkdown = ""
        featuredImageURL = nil
        status = .fetching
        errorMessage = nil
        do {
            async let imageURL = processor.extractFeaturedImage(from: url)
            let article = try await processor.process(url: url)
            featuredImageURL = await imageURL
            articleTitle = article.title
            try await generateAudio(article)
        } catch let err as DeepgramError {
            if case .missingAPIKey = err { showAPIKeySetup = true }
            errorMessage = err.localizedDescription
            status = .idle
        } catch {
            errorMessage = error.localizedDescription
            status = .idle
        }
    }

    private func generateAudio(_ article: ProcessedArticle) async throws {
        // LLM cleanup pass (no-op if no OpenAI key)
        let pronounced = ScientificPronunciation.rewrite(article.fullText)
        status = .cleaning
        let llmCleaned = await LLMCleaner.shared.clean(title: article.title, text: pronounced)
        exportMarkdown = buildMarkdown(title: article.title, body: llmCleaned,
                                       sourceURL: currentSourceURL, imageURL: featuredImageURL)
        // Split into speak chunks + pauses (a long pause follows each section title).
        let units = NarrationBuilder.units(from: llmCleaned)
        narrationPlan = units   // retained so a pronunciation fix can regenerate the tail
        let speakCount = units.filter { if case .speak = $0 { return true } else { return false } }.count

        // Estimate the TTS spend and let the user cancel before we make the call.
        guard await confirmCost(chars: llmCleaned.count) else { status = .idle; return }

        // Record the doc in the library now (under Reading) so it's tracked even
        // before generation finishes; audio is filled in by finalizeEntry below.
        let entry = await LibraryManager.shared.startEntry(
            title: article.title, sourceURL: currentSourceURL, kind: currentKind)
        currentLibraryItemID = entry.id

        var allPCM = Data()
        var cumulativeTime: TimeInterval = 0
        var built: [SentenceTimestamp] = []
        var spoken = 0

        status = .generating(0, speakCount)
        let gen = UUID()
        generationToken = gen
        player.startStreaming()

        for unit in units {
            guard generationToken == gen else { return }
            switch unit {
            case .pause(let seconds):
                player.appendSilence(seconds)
                allPCM.append(Data(count: Int(seconds * 24000) * 2))   // keep saved WAV in sync
                cumulativeTime += seconds
            case .speak(let chunk):
                spoken += 1
                if case .generating = status { status = .generating(spoken, speakCount) }
                built.append(SentenceTimestamp(text: chunk, startTime: cumulativeTime))
                var chunkPCM = Data()
                let stream = try await streamTTS(chunk)
                for try await data in stream {
                    guard generationToken == gen else { return }
                    chunkPCM.append(data)
                    player.appendPCM(data)
                }
                CostTracker.shared.record(Pricing.ttsCost(chars: chunk.count, provider: AppSettings.ttsProvider))
                cumulativeTime += TimeInterval(chunkPCM.count) / TimeInterval(24000 * 2)
                allPCM.append(chunkPCM)
                sentences = built  // Update transcript incrementally

                if spoken == 1 {
                    player.setNowPlaying(title: article.title)
                    status = .ready
                }
            }
        }

        guard generationToken == gen else { return }
        player.finalizeStreaming()
        player.setNowPlaying(title: article.title)  // Update duration in Now Playing

        // Fill in the audio + transcript for the entry created at the start.
        let wav = WAVBuilder.make(pcmData: allPCM)
        let stored = built.map { StoredSentence(text: $0.text, startTime: $0.startTime) }
        await LibraryManager.shared.finalizeEntry(
            entry.id, wavData: wav, sentences: stored, duration: player.duration)
    }
}

enum PlayerStatus: Equatable {
    case idle, fetching, cleaning, ready, failed
    case generating(Int, Int)
}

// MARK: - Narration units (speak chunks + deliberate pauses)

enum NarrationUnit {
    case speak(String)
    case pause(Double)
}

enum NarrationBuilder {
    /// Long pause inserted after a section title.
    static let sectionPause: Double = 1.2
    private static let marker = "\u{1}§\u{1}"
    private static let headers = [
        "Abstract", "Summary", "Introduction", "Background",
        "Materials and Methods", "Methods", "Results and Discussion", "Results",
        "Discussion", "Conclusions", "Conclusion", "Significance",
        "Acknowledgements", "Acknowledgments", "References"
    ]

    /// Turns article text into speak/pause units: each recognized section title
    /// is spoken on its own and followed by a long pause.
    static func units(from text: String) -> [NarrationUnit] {
        let marked = insertSectionPauses(text)
        var out: [NarrationUnit] = []
        let parts = marked.components(separatedBy: marker)
        for (i, part) in parts.enumerated() {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            for chunk in TextChunker.chunk(trimmed) where !chunk.isEmpty {
                out.append(.speak(chunk))
            }
            if i < parts.count - 1 { out.append(.pause(sectionPause)) }
        }
        return out
    }

    /// Inserts a pause marker after section-title lines (e.g. "Abstract").
    private static func insertSectionPauses(_ text: String) -> String {
        var result = text
        for header in headers {
            let pattern = "(?im)^[ \\t]*\(NSRegularExpression.escapedPattern(for: header))[ \\t]*:?[ \\t]*$"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = re.stringByReplacingMatches(in: result, range: range, withTemplate: "\(header).\(marker)")
        }
        return result
    }
}

struct CostPrompt: Identifiable {
    let id = UUID()
    let chars: Int
    let estimate: Double
    let provider: String
}

/// A generated, pronunciation-corrected Markdown document ready to export.
struct DocumentExport: Identifiable {
    let id = UUID()
    let title: String
    let markdown: String
    var filename: String {
        let safe = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return "\(safe.isEmpty ? "document" : safe).md"
    }
}

// MARK: - Markdown export file

struct MarkdownExportFile: Transferable {
    let markdown: String
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: UTType(filenameExtension: "md") ?? .plainText) { file in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.filename)
            try file.markdown.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

// MARK: - Document export sheet

/// Shows document generation progress, then a preview + share/export of the
/// cleaned `.md` (for ElevenReader and other third-party readers).
struct DocumentExportSheet: View {
    @EnvironmentObject var viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationView {
            Group {
                if let doc = viewModel.documentExport {
                    ready(doc)
                } else if let err = viewModel.documentError {
                    errorView(err)
                } else {
                    progress
                }
            }
            .navigationTitle("Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var progress: some View {
        VStack(spacing: 14) {
            ProgressView().scaleEffect(1.3)
            Text(viewModel.documentStatus).font(.subheadline).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func ready(_ doc: DocumentExport) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(doc.markdown)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            Divider()
            HStack(spacing: 12) {
                ShareLink(
                    item: MarkdownExportFile(markdown: doc.markdown, filename: doc.filename),
                    preview: SharePreview(doc.title, image: Image(systemName: "doc.plaintext"))
                ) {
                    Label("Export .md", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.accentColor.opacity(0.15))
                        .cornerRadius(10)
                }
                Button {
                    UIPasteboard.general.string = doc.markdown
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor.opacity(0.15))
                        .cornerRadius(10)
                }
            }
            .padding()
        }
    }

    private func errorView(_ err: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 44)).foregroundColor(.orange)
            Text(err)
                .font(.callout).foregroundColor(.red)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
            if viewModel.pendingURL != nil {
                Button { viewModel.startDocFromBrowser() } label: {
                    Label("Read full text in browser", systemImage: "safari")
                        .font(.subheadline)
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(Color.accentColor.opacity(0.12)).cornerRadius(10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - View

struct PlayerView: View {
    @Binding var incomingURL: URL?
    @EnvironmentObject var viewModel: PlayerViewModel
    @ObservedObject private var costTracker = CostTracker.shared
    @State private var sliderValue: Double = 0
    @State private var isDragging = false
    @State private var isAutoScrolling = true

    var body: some View {
        Group {
            if viewModel.mode == .figure {
                // Seminars play in a full-screen cover; the Home tab stays on the library.
                homeLayout
            } else if case .ready = viewModel.status {
                readyLayout
            } else {
                loadingLayout
            }
        }
        .onChange(of: incomingURL) { _, url in
            if let url { viewModel.load(url: url, kind: .primary); incomingURL = nil }
        }
        .onChange(of: viewModel.status) { _, s in
            if case .ready = s { isAutoScrolling = true }
        }
        .onReceive(viewModel.player.$currentTime) { time in
            if !isDragging { sliderValue = viewModel.progress }
            switch viewModel.mode {
            case .narration: viewModel.updateCurrentSentence(at: time)
            case .figure:    viewModel.updateCurrentPanel(at: time)
            }
        }
        .onChange(of: sliderValue) { _, val in
            guard isDragging else { return }
            viewModel.updateCurrentSentence(at: val * viewModel.player.duration)
        }
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
            PronunciationSheet(context: viewModel.currentNarrationContext)
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $viewModel.showDocumentSheet) {
            DocumentExportSheet().environmentObject(viewModel)
        }
        .alert("Generate narration?", isPresented: Binding(
            get: { viewModel.costPrompt != nil },
            set: { if !$0 { viewModel.resolveCostPrompt(false) } }
        ), presenting: viewModel.costPrompt) { prompt in
            Button("Cancel", role: .cancel) { viewModel.resolveCostPrompt(false) }
            Button("Play (~\(currency(prompt.estimate)))") { viewModel.resolveCostPrompt(true) }
        } message: { prompt in
            Text("Estimated \(prompt.provider) cost: \(currency(prompt.estimate)) for \(prompt.chars.formatted()) characters.")
        }
    }

    private func currency(_ v: Double) -> String {
        // Plain "$" — avoid the locale-dependent "US$" prefix that .currency adds.
        "$" + v.formatted(.number.precision(.fractionLength(v < 1 ? 3 : 2)))
    }

    // MARK: - Ready layout

    private var readyLayout: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Text(viewModel.articleTitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if !viewModel.exportMarkdown.isEmpty {
                    let safeTitle = viewModel.articleTitle
                        .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
                        .joined(separator: "-")
                        .trimmingCharacters(in: .whitespaces)
                    ShareLink(
                        item: MarkdownExportFile(
                            markdown: viewModel.exportMarkdown,
                            filename: "\(safeTitle).md"
                        ),
                        preview: SharePreview(
                            viewModel.articleTitle,
                            image: Image(systemName: "doc.plaintext")
                        )
                    ) {
                        Image(systemName: "square.and.arrow.up").font(.caption).foregroundColor(.secondary)
                    }
                }
                Button {
                    viewModel.player.pause()
                    viewModel.showPronunciationSheet = true
                } label: {
                    Image(systemName: "character.bubble").font(.caption).foregroundColor(.secondary)
                }
                Button { viewModel.showAPIKeySetup = true } label: {
                    Image(systemName: "gearshape").font(.caption).foregroundColor(.secondary)
                }
                Button { viewModel.stop() } label: {
                    Image(systemName: "xmark").font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Divider()

            ZStack(alignment: .bottom) {
                transcriptView
                if !isAutoScrolling {
                    Button { isAutoScrolling = true } label: {
                        Label("Back to current", systemImage: "arrow.down.to.line")
                            .font(.caption2)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button { viewModel.player.togglePlayPause() } label: {
                    Image(systemName: viewModel.player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18))
                        .frame(width: 36, height: 36)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Circle())
                }
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

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(viewModel.sentences.enumerated()), id: \.offset) { i, sentence in
                        Text(sentence.text)
                            .font(.footnote)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                i == viewModel.currentSentenceIndex
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.clear
                            )
                            .id(i)
                    }
                }
                .padding(.vertical, 4)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 8).onChanged { _ in
                    withAnimation { isAutoScrolling = false }
                }
            )
            .onChange(of: viewModel.currentSentenceIndex) { _, idx in
                guard isAutoScrolling || isDragging else { return }
                withAnimation(.easeInOut(duration: isDragging ? 0.1 : 0.35)) {
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
            .onChange(of: isAutoScrolling) { _, auto in
                guard auto else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(viewModel.currentSentenceIndex, anchor: .center)
                }
            }
        }
    }

    // MARK: - Loading layout

    // Home tab kept on the library while a seminar plays in its cover.
    private var homeLayout: some View {
        NavigationView {
            libraryHome
                .charcoalBackdrop()
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarItems(
                    leading: costRibbon,
                    trailing: Button { viewModel.showAPIKeySetup = true } label: {
                        Image(systemName: "gearshape")
                    })
        }
    }

    private var loadingLayout: some View {
        NavigationView {
            Group {
                if viewModel.status == .idle {
                    libraryHome
                } else {
                    loadingProgress
                }
            }
            .charcoalBackdrop()
            .navigationTitle(viewModel.status == .idle ? "" : "sciFM")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: costRibbon,
                trailing: Button { viewModel.showAPIKeySetup = true } label: {
                    Image(systemName: "gearshape")
                }
            )
        }
    }

    // Idle: the home / Library tab — Reading/Read/Saved list, paste field at the
    // bottom. (Cost + gear live in the header ribbon; no title — the tab bar names it.)
    private var libraryHome: some View {
        VStack(spacing: 0) {
            LibraryListView()
            pasteURLField.padding(.vertical, 8)
        }
    }

    private var loadingProgress: some View {
        VStack(spacing: 24) {
            Spacer()
            statusIcon.frame(height: 80)

            if !viewModel.articleTitle.isEmpty {
                Text(viewModel.articleTitle)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            statusLabel

            if viewModel.errorMessage == nil && viewModel.status != .failed {
                Button { viewModel.stop() } label: {
                    Text("Cancel")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 9)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(10)
                }
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if viewModel.pendingURL != nil {
                    Button {
                        viewModel.showWebReader = true
                    } label: {
                        Label("Read full text in browser", systemImage: "safari")
                            .font(.subheadline)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.accentColor.opacity(0.12))
                            .cornerRadius(10)
                    }
                    .padding(.top, 4)
                }

                if viewModel.status == .failed {
                    Button {
                        viewModel.dismissFailure()
                    } label: {
                        Text("Back to Library")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer()
        }
    }

    // API-spend readout for the header ribbon: today (accent) and all-time
    // (muted) values, shown inline.
    private var costRibbon: some View {
        HStack(spacing: 8) {
            Text(currency(costTracker.todayTotal))
                .foregroundColor(.accentColor)
            Text(currency(costTracker.allTimeTotal))
                .foregroundColor(.secondary)
        }
        .font(.subheadline.monospacedDigit())
        .lineLimit(1)
        .fixedSize()   // show the full spend; don't clip/constrain it
    }

    @State private var pastedURL = ""
    private var pasteURLField: some View {
        HStack {
            TextField("https://pubmed.ncbi.nlm.nih.gov/…", text: $pastedURL)
                .font(.caption).keyboardType(.URL).autocorrectionDisabled()
                .padding(8).background(Color(.secondarySystemBackground)).cornerRadius(8)
            Button {
                if let url = URL(string: pastedURL.trimmingCharacters(in: .whitespaces)) {
                    viewModel.generateDocument(url: url)
                    pastedURL = ""
                }
            } label: {
                Image(systemName: "doc.badge.arrow.up")
            }
            .disabled(pastedURL.isEmpty)
            .help("Export a cleaned .md (no audio)")

            Button("Go") {
                if let url = URL(string: pastedURL.trimmingCharacters(in: .whitespaces)) {
                    viewModel.load(url: url, kind: .primary)
                    pastedURL = ""
                }
            }
            .disabled(pastedURL.isEmpty)
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch viewModel.status {
        case .idle:
            Image(systemName: "doc.text").font(.system(size: 64)).foregroundColor(.accentColor)
        case .fetching:
            ProgressView().scaleEffect(2)
        case .cleaning:
            Image(systemName: "brain").font(.system(size: 64)).foregroundColor(.accentColor)
                .symbolEffect(.pulse)
        case .generating:
            Image(systemName: "waveform").font(.system(size: 64)).foregroundColor(.accentColor)
                .symbolEffect(.variableColor.iterative)
        case .ready:
            EmptyView()
        case .failed:
            Image(systemName: "exclamationmark.triangle").font(.system(size: 56)).foregroundColor(.orange)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch viewModel.status {
        case .idle, .ready, .failed: EmptyView()
        case .fetching:
            Text("Fetching article…").font(.subheadline).foregroundColor(.secondary)
        case .cleaning:
            Text("Polishing text…").font(.subheadline).foregroundColor(.secondary)
        case .generating(let done, let total):
            Text("Generating audio… (\(done)/\(total))").font(.subheadline).foregroundColor(.secondary)
        }
    }
}
