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

    /// The article currently cued/playing, if any.
    var current: FeedArticle? { queue.indices.contains(index) ? queue[index] : nil }
    var isActive: Bool { state != .idle }

    init() {
        delegate.onFinish = { [weak self] in
            Task { @MainActor in self?.advance() }
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
        audioPlayer?.stop(); audioPlayer = nil
        state = .idle
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
        audioPlayer?.stop(); audioPlayer = nil
        state = .loading
        loadTask = Task {
            let text = await FeedManager.shared.readingText(for: article)
            guard !Task.isCancelled else { return }
            guard !text.isEmpty else { advance(); return }
            do {
                let wav = try await synthesize(text)
                guard !Task.isCancelled else { return }
                let player = try AVAudioPlayer(data: wav)
                player.delegate = delegate
                player.play()
                audioPlayer = player
                state = .playing
            } catch {
                guard !Task.isCancelled else { return }
                advance()   // skip a track that fails to synthesize
            }
        }
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
