import Foundation
import AVFoundation

/// Lightweight TTS player for short texts (abstracts).
/// Runs independently of PlayerViewModel — no navigation, no progress UI.
@MainActor
final class AbstractPlayer: ObservableObject {
    static let shared = AbstractPlayer()

    enum State { case idle, loading, playing }

    @Published private(set) var state: State = .idle
    @Published private(set) var playingID: String? = nil

    private var audioPlayer: AVAudioPlayer?
    private let deepgramTTS = DeepgramTTS()
    private let openAITTS   = OpenAITTS()
    private var currentTask: Task<Void, Never>? = nil

    func toggle(id: String, text: String) {
        if playingID == id {
            stop()
        } else {
            play(id: id, text: text)
        }
    }

    func stop() {
        currentTask?.cancel()
        currentTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        state = .idle
        playingID = nil
    }

    private func play(id: String, text: String) {
        stop()
        state = .loading
        playingID = id
        currentTask = Task {
            do {
                let chunks = TextChunker.chunk(ScientificPronunciation.rewrite(text))
                var allPCM = Data()
                for chunk in chunks {
                    guard !Task.isCancelled else { return }
                    let stream: AsyncThrowingStream<Data, Error>
                    switch AppSettings.ttsProvider {
                    case .deepgram: stream = try await deepgramTTS.stream(text: chunk)
                    case .openai:   stream = try await openAITTS.stream(text: chunk)
                    }
                    for try await data in stream {
                        guard !Task.isCancelled else { return }
                        allPCM.append(data)
                    }
                    CostTracker.shared.record(Pricing.ttsCost(chars: chunk.count, provider: AppSettings.ttsProvider))
                }
                guard !Task.isCancelled else { return }
                let wav = WAVBuilder.make(pcmData: allPCM)
                let player = try AVAudioPlayer(data: wav)
                player.delegate = Coordinator.shared
                player.enableRate = true
                player.rate = AppSettings.playbackRate
                player.play()
                audioPlayer = player
                state = .playing
                Coordinator.shared.onFinish = { [weak self] in
                    self?.state = .idle
                    self?.playingID = nil
                    self?.audioPlayer = nil
                }
            } catch {
                state = .idle
                playingID = nil
            }
        }
    }
}

// Bridges AVAudioPlayerDelegate to AbstractPlayer
private final class Coordinator: NSObject, AVAudioPlayerDelegate {
    static let shared = Coordinator()
    var onFinish: (() -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        DispatchQueue.main.async { self.onFinish?() }
    }
}
