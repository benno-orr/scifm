import SwiftUI
import Combine
import UniformTypeIdentifiers

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
    @Published var mode: AppMode = .narration
    @Published var exportMarkdown: String = ""
    @Published var featuredImageURL: URL? = nil
    // Narration mode
    @Published var sentences: [SentenceTimestamp] = []
    @Published var currentSentenceIndex: Int = 0
    // Figure mode
    @Published var panels: [FigurePanel] = []
    @Published var panelTimestamps: [PanelTimestamp] = []
    @Published var currentPanelIndex: Int = 0

    let player = AudioPlayer()
    private let processor = ArticleProcessor()
    private let deepgramTTS = DeepgramTTS()
    private let openAITTS = OpenAITTS()
    private var cancellables = Set<AnyCancellable>()
    private var currentSourceURL: String = ""
    private var currentLibraryItemID: UUID? = nil
    private(set) var pendingURL: URL? = nil

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

    func load(url: URL) {
        pendingURL = url
        currentSourceURL = url.absoluteString
        if mode == .figure {
            Task { await loadFigures(url: url) }
        } else {
            showWebReader = true
        }
    }

    func processWebContent(title: String, bodyText: String) {
        showWebReader = false
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
        player.stop()
        status = .idle
    }

    func loadLibraryItem(_ item: LibraryItem) async {
        if let id = currentLibraryItemID {
            let t = player.currentTime
            await LibraryManager.shared.updateLastPlayedTime(id, time: t)
        }
        player.stop()
        sentences = []
        currentSentenceIndex = 0
        status = .fetching
        errorMessage = nil

        guard let wavData = await LibraryManager.shared.audioData(for: item) else {
            errorMessage = "Could not load audio file."
            status = .idle
            return
        }
        do {
            sentences = item.sentences.map { SentenceTimestamp(text: $0.text, startTime: $0.startTime) }
            articleTitle = item.title
            currentLibraryItemID = item.id
            currentSourceURL = item.sourceURL
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
        player.stop()
        panels = []
        panelTimestamps = []
        currentPanelIndex = 0
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
            status = .idle
        } catch {
            errorMessage = error.localizedDescription
            status = .idle
        }
    }

    private func generateFigureAudio(_ panels: [FigurePanel]) async throws {
        var allPCM = Data()
        var cumulativeTime: TimeInterval = 0
        var timestamps: [PanelTimestamp] = []

        status = .generating(0, panels.count)
        for (i, panel) in panels.enumerated() {
            guard case .generating = status else { return }
            status = .generating(i + 1, panels.count)
            timestamps.append(PanelTimestamp(panelIndex: i, figureNumber: panel.figureNumber,
                                             panelLabel: panel.label, startTime: cumulativeTime))

            // Build figure label prefix, then merge legend + body context via LLM
            let figLabel = panel.label.isEmpty
                ? "Figure \(panel.figureNumber)."
                : "Figure \(panel.figureNumber), panel \(panel.label)."
            let figRef = panel.label.isEmpty
                ? "Figure \(panel.figureNumber)"
                : "Figure \(panel.figureNumber)\(panel.label)"
            let merged = await LLMCleaner.shared.mergeForFigure(
                figureRef: figRef,
                legendText: panel.legendText,
                contextSentences: panel.textReferences
            )
            let narration = ScientificPronunciation.rewrite("\(figLabel) \(merged)")

            var chunkPCM = Data()
            for chunk in TextChunker.chunk(narration) {
                let stream = try await streamTTS(chunk)
                for try await data in stream { chunkPCM.append(data) }
            }
            cumulativeTime += TimeInterval(chunkPCM.count) / TimeInterval(24000 * 2)
            allPCM.append(chunkPCM)
        }

        panelTimestamps = timestamps
        let wav = WAVBuilder.make(pcmData: allPCM)
        try player.load(wavData: wav)
        player.setNowPlaying(title: articleTitle)
        status = .ready
        player.play()
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

    func updateCurrentPanel(at time: TimeInterval) {
        guard !panelTimestamps.isEmpty else { return }
        var idx = 0
        for (i, ts) in panelTimestamps.enumerated() {
            if ts.startTime <= time { idx = i } else { break }
        }
        if idx != currentPanelIndex { currentPanelIndex = idx }
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
        player.stop()
        sentences = []; currentSentenceIndex = 0
        currentLibraryItemID = nil; exportMarkdown = ""; featuredImageURL = nil
        articleTitle = title; errorMessage = nil
        Task {
            do {
                let chunks = TextChunker.chunk(ScientificPronunciation.rewrite(text))
                var allPCM = Data()
                var cumulativeTime: TimeInterval = 0
                var built: [SentenceTimestamp] = []
                status = .generating(0, chunks.count)
                player.startStreaming()
                for (i, chunk) in chunks.enumerated() {
                    guard case .generating = status else { player.stop(); return }
                    status = .generating(i + 1, chunks.count)
                    built.append(SentenceTimestamp(text: chunk, startTime: cumulativeTime))
                    var chunkPCM = Data()
                    let stream = try await streamTTS(chunk)
                    for try await data in stream {
                        chunkPCM.append(data)
                        player.appendPCM(data)
                    }
                    cumulativeTime += TimeInterval(chunkPCM.count) / TimeInterval(24000 * 2)
                    allPCM.append(chunkPCM)
                    if i == 0 {
                        player.setNowPlaying(title: title)
                        status = .ready
                    }
                }
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

    private func buildMarkdown(title: String, body: String) -> String {
        // Trailing space on each paragraph gives ElevenReader a natural pause at paragraph breaks
        let paddedBody = body
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) + " " }
            .filter { $0.count > 1 }
            .joined(separator: "\n\n")

        var parts: [String] = ["# \(title)"]
        if !currentSourceURL.isEmpty {
            parts.append("> \(currentSourceURL)")
        }
        if let img = featuredImageURL {
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
        player.stop()
        sentences = []
        currentSentenceIndex = 0
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
        exportMarkdown = buildMarkdown(title: article.title, body: llmCleaned)
        let chunks = TextChunker.chunk(llmCleaned)
        var allPCM = Data()
        var cumulativeTime: TimeInterval = 0
        var built: [SentenceTimestamp] = []

        status = .generating(0, chunks.count)
        player.startStreaming()

        for (i, chunk) in chunks.enumerated() {
            guard case .generating = status else { player.stop(); return }
            status = .generating(i + 1, chunks.count)
            built.append(SentenceTimestamp(text: chunk, startTime: cumulativeTime))
            var chunkPCM = Data()
            let stream = try await streamTTS(chunk)
            for try await data in stream {
                chunkPCM.append(data)
                player.appendPCM(data)
            }
            cumulativeTime += TimeInterval(chunkPCM.count) / TimeInterval(24000 * 2)
            allPCM.append(chunkPCM)
            sentences = built  // Update transcript incrementally

            // Switch to ready layout after first chunk so user gets immediate UI access
            if i == 0 {
                player.setNowPlaying(title: article.title)
                status = .ready
            }
        }

        player.finalizeStreaming()
        player.setNowPlaying(title: article.title)  // Update duration in Now Playing

        // Save complete WAV to library in background
        let wav = WAVBuilder.make(pcmData: allPCM)
        let stored = built.map { StoredSentence(text: $0.text, startTime: $0.startTime) }
        let savedItem = await LibraryManager.shared.save(
            title: article.title, sourceURL: currentSourceURL,
            wavData: wav, sentences: stored, duration: player.duration
        )
        currentLibraryItemID = savedItem.id
    }
}

enum PlayerStatus: Equatable {
    case idle, fetching, cleaning, ready
    case generating(Int, Int)
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

// MARK: - View

struct PlayerView: View {
    @Binding var incomingURL: URL?
    @EnvironmentObject var viewModel: PlayerViewModel
    @State private var sliderValue: Double = 0
    @State private var isDragging = false
    @State private var isAutoScrolling = true

    var body: some View {
        Group {
            if case .ready = viewModel.status {
                if viewModel.mode == .figure {
                    FigurePlayerView()
                } else {
                    readyLayout
                }
            } else {
                loadingLayout
            }
        }
        .onChange(of: incomingURL) { _, url in
            if let url { viewModel.load(url: url); incomingURL = nil }
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
                WebReaderSheet(url: url) { title, body in
                    viewModel.processWebContent(title: title, bodyText: body)
                }
            }
        }
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
                Button { viewModel.showAPIKeySetup = true } label: {
                    Image(systemName: "key").font(.caption).foregroundColor(.secondary)
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

    private var loadingLayout: some View {
        NavigationView {
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
                            Label("Open in browser", systemImage: "safari")
                                .font(.subheadline)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(Color.accentColor.opacity(0.12))
                                .cornerRadius(10)
                        }
                        .padding(.top, 4)
                    }
                }

                Spacer()

                if viewModel.status == .idle {
                    Picker("Mode", selection: $viewModel.mode) {
                        Text("Narration").tag(AppMode.narration)
                        Text("Figures").tag(AppMode.figure)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    pasteURLField
                    Spacer()
                }
            }
            .navigationTitle("sciFM")
            .navigationBarItems(trailing:
                Button { viewModel.showAPIKeySetup = true } label: {
                    Image(systemName: "key")
                }
            )
        }
    }

    @State private var pastedURL = ""
    private var pasteURLField: some View {
        HStack {
            TextField("https://pubmed.ncbi.nlm.nih.gov/…", text: $pastedURL)
                .font(.caption).keyboardType(.URL).autocorrectionDisabled()
                .padding(8).background(Color(.secondarySystemBackground)).cornerRadius(8)
            Button("Go") {
                if let url = URL(string: pastedURL.trimmingCharacters(in: .whitespaces)) {
                    viewModel.load(url: url)
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
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch viewModel.status {
        case .idle, .ready: EmptyView()
        case .fetching:
            Text("Fetching article…").font(.subheadline).foregroundColor(.secondary)
        case .cleaning:
            Text("Polishing text…").font(.subheadline).foregroundColor(.secondary)
        case .generating(let done, let total):
            Text("Generating audio… (\(done)/\(total))").font(.subheadline).foregroundColor(.secondary)
        }
    }
}
