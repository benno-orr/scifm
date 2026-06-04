import AVFoundation
import MediaPlayer
import Combine

// MARK: - WAVBuilder

enum WAVBuilder {
    static func make(pcmData: Data, sampleRate: Int32 = 24000, channels: Int16 = 1, bitsPerSample: Int16 = 16) -> Data {
        var wav = Data()
        let dataSize = Int32(pcmData.count)
        let byteRate = sampleRate * Int32(channels) * Int32(bitsPerSample) / 8
        let blockAlign = Int16(channels) * bitsPerSample / 8

        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }

        wav.append(contentsOf: "RIFF".utf8); le(dataSize + 36)
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8); le(Int32(16)); le(Int16(1))
        le(channels); le(sampleRate); le(byteRate); le(blockAlign); le(bitsPerSample)
        wav.append(contentsOf: "data".utf8); le(dataSize)
        wav.append(pcmData)
        return wav
    }
}

// MARK: - AudioPlayer

@MainActor
final class AudioPlayer: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0

    /// Fires once when playback reaches the end naturally (not on pause/stop).
    var onPlaybackFinished: (() -> Void)?

    private var avPlayer: AVAudioPlayer?
    private var ticker: AnyCancellable?

    // Streaming mode (AVAudioEngine)
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var streamingDuration: TimeInterval = 0
    private var streamingStarted = false
    private var streamingFinalized = false
    private static let streamFmt = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!

    init() {
        configureSession()
        setupRemoteCommands()
    }

    func load(wavData: Data) throws {
        avPlayer = try AVAudioPlayer(data: wavData)
        avPlayer?.prepareToPlay()
        duration = avPlayer?.duration ?? 0
        currentTime = 0
    }

    func play() {
        avPlayer?.play()
        isPlaying = true
        startTicker()
        syncNowPlaying()
    }

    func pause() {
        avPlayer?.pause()
        isPlaying = false
        stopTicker()
        syncNowPlaying()
    }

    func togglePlayPause() { isPlaying ? pause() : play() }

    func seek(to fraction: Double) {
        guard !streamingStarted, duration > 0 else { return }
        let t = fraction * duration
        avPlayer?.currentTime = t
        currentTime = t
        syncNowPlaying()
    }

    func seekAbsolute(to time: TimeInterval) {
        guard !streamingStarted else { return }
        avPlayer?.currentTime = time
        currentTime = time
        syncNowPlaying()
    }

    func stop() {
        playerNode?.stop()
        engine?.stop()
        engine = nil; playerNode = nil
        streamingDuration = 0; streamingStarted = false; streamingFinalized = false

        avPlayer?.stop()
        avPlayer = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        stopTicker()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Streaming

    /// Call before generating the first TTS chunk.
    func startStreaming() {
        stop()
        streamingDuration = 0; streamingStarted = false; streamingFinalized = false
        let e = AVAudioEngine()
        let pn = AVAudioPlayerNode()
        e.attach(pn)
        e.connect(pn, to: e.mainMixerNode, format: AudioPlayer.streamFmt)
        try? e.start()
        engine = e; playerNode = pn
    }

    /// Append a raw int16 24 kHz PCM chunk. Playback begins automatically after the first call.
    func appendPCM(_ data: Data) {
        guard let pn = playerNode, let _ = engine, !data.isEmpty else { return }
        let frameCount = data.count / 2
        guard let buf = AVAudioPCMBuffer(pcmFormat: AudioPlayer.streamFmt,
                                         frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buf.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            let dst = buf.floatChannelData![0]
            for i in 0..<frameCount { dst[i] = Float(src[i]) / 32768.0 }
        }
        streamingDuration += Double(frameCount) / 24000.0
        duration = streamingDuration
        pn.scheduleBuffer(buf, completionHandler: nil)
        if !streamingStarted {
            pn.play()
            isPlaying = true
            streamingStarted = true
            startTicker()
        }
    }

    /// Call after all chunks have been appended.
    func finalizeStreaming() { streamingFinalized = true }

    func setNowPlaying(title: String) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "sciFM",
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0
        ]
    }

    // MARK: - Private

    private func configureSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.allowBluetoothHFP, .allowBluetoothA2DP])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func startTicker() {
        ticker = Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                if let pn = self.playerNode, self.streamingStarted {
                    // Streaming mode: read time from node
                    if let lastRender = pn.lastRenderTime,
                       let pt = pn.playerTime(forNodeTime: lastRender) {
                        self.currentTime = min(Double(pt.sampleTime) / pt.sampleRate, self.duration)
                    }
                    self.syncNowPlaying()
                    // Detect playback finished after all buffers drained
                    if self.streamingFinalized && !pn.isPlaying {
                        self.isPlaying = false
                        self.streamingStarted = false
                        self.stopTicker()
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                        self.onPlaybackFinished?()
                    }
                } else if let p = self.avPlayer {
                    self.currentTime = p.currentTime
                    if !p.isPlaying && self.isPlaying {
                        self.isPlaying = false
                        self.stopTicker()
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                        self.onPlaybackFinished?()
                    }
                    self.syncNowPlaying()
                }
            }
    }

    private func stopTicker() { ticker?.cancel(); ticker = nil }

    private func syncNowPlaying() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor [weak self] in self?.play() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor [weak self] in self?.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor [weak self] in self?.togglePlayPause() }; return .success }
        c.stopCommand.addTarget { [weak self] _ in Task { @MainActor [weak self] in self?.stop() }; return .success }
        c.changePlaybackPositionCommand.isEnabled = true
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor [weak self] in self?.seekAbsolute(to: e.positionTime) }
            return .success
        }
    }
}
