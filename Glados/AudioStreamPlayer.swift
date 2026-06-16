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
    private var loadedPCM: Data?              // PCM of a loaded WAV, for tail regeneration
    private var ticker: AnyCancellable?

    // Streaming mode (AVAudioEngine)
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var streamData = Data()           // accumulated int16 PCM, enables seeking
    private var streamBaseTime: TimeInterval = 0  // time offset of the current schedule origin
    private var scheduleEpoch = 0             // bumped on seek to ignore stale buffer callbacks
    private var streamingStarted = false
    private var streamingFinalized = false
    private var pendingBuffers = 0      // scheduled but not yet played out
    private var userPaused = false      // explicit pause — don't auto-start on new buffers
    /// Audio buffered before playback begins, to ride out TTS/network gaps.
    private static let prebufferSeconds: TimeInterval = 1.5
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
        // Keep the raw PCM (strip the 44-byte WAV header) so a pronunciation fix
        // can regenerate the article tail even from a replayed library item.
        loadedPCM = wavData.count > 44 ? wavData.subdata(in: 44..<wavData.count) : nil
    }

    /// Raw int16 PCM from the start up to `time`, from whichever source is active
    /// (the live streaming buffer or a loaded WAV). Used to keep the already-heard
    /// portion when regenerating the rest of the article. nil if no audio is loaded.
    func currentPCMHead(upTo time: TimeInterval) -> Data? {
        let source: Data
        if engine != nil { source = streamData }
        else if let pcm = loadedPCM { source = pcm }
        else { return nil }
        let byteOffset = min(max(0, Int(time * 24000) * 2), source.count)
        return source.subdata(in: 0..<byteOffset)
    }

    /// Seeking is supported both for a loaded WAV and the live streaming engine
    /// (within already-generated audio).
    var canSeek: Bool { avPlayer != nil || engine != nil }

    func play() {
        userPaused = false
        if engine != nil {
            if streamingStarted {
                playerNode?.play()
            } else {
                startStreamingPlayback()   // user opted in before the prebuffer filled
            }
        } else {
            avPlayer?.play()
        }
        isPlaying = true
        startTicker()
        syncNowPlaying()
    }

    func pause() {
        userPaused = true
        playerNode?.pause()
        avPlayer?.pause()
        isPlaying = false
        stopTicker()
        syncNowPlaying()
    }

    func togglePlayPause() { isPlaying ? pause() : play() }

    func seek(to fraction: Double) {
        guard duration > 0 else { return }
        seekAbsolute(to: fraction * duration)
    }

    func seekAbsolute(to time: TimeInterval) {
        if engine != nil {
            seekStreaming(to: time)
        } else if let p = avPlayer {
            let t = max(0, min(time, p.duration))
            p.currentTime = t
            currentTime = t
            syncNowPlaying()
        }
    }

    /// Seeks within already-generated streaming audio by re-scheduling the
    /// remaining PCM from the target time. Forward seeks clamp to what's generated.
    private func seekStreaming(to time: TimeInterval) {
        guard let pn = playerNode, engine != nil else { return }
        let total = Double(streamData.count) / Double(24000 * 2)
        let t = max(0, min(time, total))
        var byteOffset = Int(t * 24000) * 2
        if byteOffset > streamData.count { byteOffset = streamData.count }

        scheduleEpoch += 1          // ignore completion callbacks from the old schedule
        pn.stop()
        pendingBuffers = 0
        streamBaseTime = t
        currentTime = t
        if byteOffset < streamData.count {
            scheduleInt16(streamData.subdata(in: byteOffset..<streamData.count), on: pn)
        }
        userPaused = false
        pn.play()
        streamingStarted = true
        isPlaying = true
        startTicker()
        syncNowPlaying()
    }

    func stop() {
        playerNode?.stop()
        engine?.stop()
        engine = nil; playerNode = nil
        streamData = Data(); streamBaseTime = 0
        streamingStarted = false; streamingFinalized = false
        pendingBuffers = 0; userPaused = false

        avPlayer?.stop()
        avPlayer = nil
        loadedPCM = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        stopTicker()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Streaming

    /// Call before generating the first TTS chunk. Pass `seeded: true` when
    /// pre-loading already-generated audio (a regeneration), so playback doesn't
    /// auto-start from the beginning before the caller seeks to the splice point.
    func startStreaming(seeded: Bool = false) {
        stop()
        streamData = Data(); streamBaseTime = 0; scheduleEpoch += 1
        streamingStarted = false; streamingFinalized = false
        pendingBuffers = 0; userPaused = seeded
        let e = AVAudioEngine()
        let pn = AVAudioPlayerNode()
        e.attach(pn)
        e.connect(pn, to: e.mainMixerNode, format: AudioPlayer.streamFmt)
        try? e.start()
        engine = e; playerNode = pn
    }

    /// Append a raw int16 24 kHz PCM chunk. Playback begins automatically once
    /// `prebufferSeconds` of audio is queued (or on finalize, for shorter clips).
    func appendPCM(_ data: Data) {
        guard let pn = playerNode, engine != nil, !data.isEmpty else { return }
        streamData.append(data)
        duration = Double(streamData.count) / Double(24000 * 2)
        scheduleInt16(data, on: pn)
    }

    /// Schedules `seconds` of silence — used to bridge TTS underruns and to
    /// insert deliberate pauses (e.g. after a section title).
    func appendSilence(_ seconds: Double) {
        guard seconds > 0, let pn = playerNode, engine != nil else { return }
        let frameCount = Int(seconds * 24000)
        guard frameCount > 0 else { return }
        let zeros = Data(count: frameCount * 2)
        streamData.append(zeros)
        duration = Double(streamData.count) / Double(24000 * 2)
        scheduleInt16(zeros, on: pn)
    }

    /// Builds a float buffer from int16 PCM and schedules it on the node.
    private func scheduleInt16(_ data: Data, on pn: AVAudioPlayerNode) {
        let frameCount = data.count / 2
        guard frameCount > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: AudioPlayer.streamFmt,
                                         frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buf.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            let dst = buf.floatChannelData![0]
            for i in 0..<frameCount { dst[i] = Float(src[i]) / 32768.0 }
        }
        pendingBuffers += 1
        let epoch = scheduleEpoch
        pn.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, epoch == self.scheduleEpoch else { return }   // ignore stale (pre-seek) callbacks
                self.pendingBuffers -= 1
                self.checkStreamingComplete()
            }
        }
        if !streamingStarted && !userPaused && duration >= Self.prebufferSeconds {
            startStreamingPlayback()
        }
    }

    /// Call after all chunks have been appended.
    func finalizeStreaming() {
        streamingFinalized = true
        // Clips shorter than the prebuffer threshold never auto-started.
        if !streamingStarted && !userPaused { startStreamingPlayback() }
        checkStreamingComplete()
    }

    private func startStreamingPlayback() {
        guard let pn = playerNode, !streamingStarted else { return }
        pn.play()
        streamingStarted = true
        isPlaying = true
        startTicker()
    }

    /// Streamed playback is finished when generation is done and every scheduled
    /// buffer has played out. (AVAudioPlayerNode.isPlaying stays true after the
    /// queue drains, so buffer accounting is the only reliable signal.)
    private func checkStreamingComplete() {
        // Generation fell behind playback — bridge with a short silence so the
        // node keeps playing (rather than glitching/stopping) until the next
        // chunk arrives.
        if streamingStarted, !streamingFinalized, !userPaused, pendingBuffers == 0, engine != nil {
            appendSilence(0.6)
            return
        }
        guard streamingFinalized, streamingStarted, pendingBuffers == 0 else { return }
        isPlaying = false
        streamingStarted = false
        streamingFinalized = false
        stopTicker()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        onPlaybackFinished?()
    }

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
                    // Streaming mode: read time from node.
                    // Completion is detected via buffer playback callbacks
                    // (checkStreamingComplete), not here — the node's isPlaying
                    // stays true even after its queue drains.
                    if let lastRender = pn.lastRenderTime,
                       let pt = pn.playerTime(forNodeTime: lastRender) {
                        // sampleTime resets to 0 after a seek's stop()/play(); add the seek offset.
                        self.currentTime = min(self.streamBaseTime + Double(pt.sampleTime) / pt.sampleRate, self.duration)
                    }
                    self.syncNowPlaying()
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
