import Foundation
import AVFoundation

/// Spotify-style sequential TTS player for a list of feed articles. Synthesizes
/// each article's reading text (abstract / lede) to speech and plays them back
/// to back, advancing automatically, with play/pause and skip controls. Runs
/// independently of `PlayerViewModel` (which owns the full-article pipeline).
@MainActor
final class PlaylistPlayer: ObservableObject {
    static let shared = PlaylistPlayer()

    enum State { case idle, loading, playing, paused }

    @Published private(set) var state: State = .idle
    @Published private(set) var queue: [FeedArticle] = []
    @Published private(set) var index: Int = 0
    @Published private(set) var playlistName: String = ""

    private var audioPlayer: AVAudioPlayer?
    private let deepgramTTS = DeepgramTTS()
    private let openAITTS   = OpenAITTS()
    private var loadTask: Task<Void, Never>? = nil
    private let delegate = PlaylistDelegate()
    /// article.id → Library entry id, so a finished track can be marked read
    /// and replays in one session don't duplicate the entry.
    private var libraryIDs: [String: UUID] = [:]
    /// article.id → pre-synthesized WAV, prepared while the prior track plays.
    private var prefetched: [String: Data] = [:]
    private var prefetchTask: Task<Void, Never>? = nil
    /// Polls playback position to trigger prefetch near the end of a track.
    private var progressTimer: Timer?
    /// Seconds before a track ends at which we begin prepping the next one.
    private let prefetchLead: TimeInterval = 30

    /// The article currently cued/playing, if any.
    var current: FeedArticle? { queue.indices.contains(index) ? queue[index] : nil }
    var isActive: Bool { state != .idle }

    init() {
        delegate.onFinish = { [weak self] in
            Task { @MainActor in self?.handleTrackFinished() }
        }
    }

    /// Starts a playlist from the given index.
    func play(playlist name: String, articles: [FeedArticle], startAt: Int = 0) {
        guard !articles.isEmpty else { return }
        stop()
        playlistName = name
        queue = articles
        index = max(0, min(startAt, articles.count - 1))
        loadAndPlayCurrent()
    }

    /// True if `id` is the track currently cued/playing in this playlist.
    func isCurrent(_ id: String) -> Bool { current?.id == id }

    func togglePlayPause() {
        switch state {
        case .playing: audioPlayer?.pause(); state = .paused
        case .paused:  audioPlayer?.play();  state = .playing
        case .idle:    if !queue.isEmpty { loadAndPlayCurrent() }
        case .loading: break
        }
    }

    func next() {
        guard index + 1 < queue.count else { stop(); return }
        index += 1
        loadAndPlayCurrent()
    }

    func previous() {
        // More than 3s into a track restarts it; otherwise step back.
        if let p = audioPlayer, p.currentTime > 3 { p.currentTime = 0; return }
        guard index > 0 else { audioPlayer?.currentTime = 0; return }
        index -= 1
        loadAndPlayCurrent()
    }

    func jump(to i: Int) {
        guard queue.indices.contains(i) else { return }
        index = i
        loadAndPlayCurrent()
    }

    func stop() {
        loadTask?.cancel(); loadTask = nil
        prefetchTask?.cancel(); prefetchTask = nil
        prefetched.removeAll()
        progressTimer?.invalidate(); progressTimer = nil
        audioPlayer?.stop(); audioPlayer = nil
        state = .idle
    }

    /// Natural end of a track: mark it read in the Library, then advance.
    private func handleTrackFinished() {
        if let article = current, let id = libraryIDs[article.id] {
            Task { await LibraryManager.shared.setFinished(id, true) }
        }
        advance()
    }

    /// Auto-advance at end of a track; stops at the end of the playlist.
    private func advance() {
        guard index + 1 < queue.count else { stop(); return }
        index += 1
        loadAndPlayCurrent()
    }

    private func loadAndPlayCurrent() {
        guard let article = current else { stop(); return }
        loadTask?.cancel()
        progressTimer?.invalidate()
        audioPlayer?.stop(); audioPlayer = nil
        state = .loading
        loadTask = Task {
            // Use the prefetched audio if it's ready; otherwise synthesize now.
            let wav: Data?
            if let cached = prefetched[article.id] {
                wav = cached
            } else {
                wav = await synthesizeWav(for: article)
            }
            prefetched[article.id] = nil
            guard !Task.isCancelled else { return }
            guard let wav else { advance(); return }   // skip a track that fails
            do {
                let player = try AVAudioPlayer(data: wav)
                player.delegate = delegate
                player.play()
                audioPlayer = player
                state = .playing
                startProgressMonitor()
                await saveToLibrary(article, wav: wav, duration: player.duration)
            } catch {
                guard !Task.isCancelled else { return }
                advance()
            }
        }
    }

    /// Fetches reading text and synthesizes it to a WAV, or nil if empty/failed.
    private func synthesizeWav(for article: FeedArticle) async -> Data? {
        let text = await FeedManager.shared.readingText(for: article)
        guard !text.isEmpty else { return nil }
        return try? await synthesize(text)
    }

    /// Polls the current track's position; once within `prefetchLead` of the end,
    /// begins synthesizing the next track so playback is gapless.
    private func startProgressMonitor() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let p = audioPlayer, state == .playing else { return }
        if p.duration - p.currentTime <= prefetchLead { prefetchNext() }
    }

    /// Synthesizes the next track in the background (once), caching its WAV.
    private func prefetchNext() {
        let n = index + 1
        guard queue.indices.contains(n), prefetchTask == nil else { return }
        let next = queue[n]
        guard prefetched[next.id] == nil else { return }
        prefetchTask = Task {
            let wav = await synthesizeWav(for: next)
            if let wav { prefetched[next.id] = wav }
            prefetchTask = nil
        }
    }

    /// Persists a now-playing track to the Library as a Playlist-tagged entry
    /// (begun). Skips if already saved this session. Marked read on completion.
    private func saveToLibrary(_ article: FeedArticle, wav: Data, duration: TimeInterval) async {
        guard libraryIDs[article.id] == nil else { return }
        let item = await LibraryManager.shared.save(
            title: article.title, sourceURL: article.url.absoluteString,
            wavData: wav, sentences: [], duration: duration,
            kind: .editorial, fromPlaylist: true, finished: false)
        libraryIDs[article.id] = item.id
    }

    /// Streams the whole text to a single in-memory WAV (same path as AbstractPlayer).
    private func synthesize(_ text: String) async throws -> Data {
        let chunks = TextChunker.chunk(ScientificPronunciation.rewrite(text))
        var pcm = Data()
        for chunk in chunks {
            try Task.checkCancellation()
            let stream: AsyncThrowingStream<Data, Error>
            switch AppSettings.ttsProvider {
            case .deepgram: stream = try await deepgramTTS.stream(text: chunk)
            case .openai:   stream = try await openAITTS.stream(text: chunk)
            }
            for try await data in stream { pcm.append(data) }
            CostTracker.shared.record(Pricing.ttsCost(chars: chunk.count, provider: AppSettings.ttsProvider))
        }
        return WAVBuilder.make(pcmData: pcm)
    }
}

/// Bridges `AVAudioPlayerDelegate` (end-of-track) to the playlist player.
private final class PlaylistDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        DispatchQueue.main.async { self.onFinish?() }
    }
}
