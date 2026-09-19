import AVFoundation

public enum AudioPlaybackError: Error, LocalizedError, Sendable {
    case playbackFailed

    public var errorDescription: String? {
        "音频无法播放"
    }
}

@MainActor
public final class AudioPlaybackController: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var progressTask: Task<Void, Never>?

    public private(set) var isPlaying = false
    /// 当前播放进度 0…1，取自播放器自己的 `currentTime / duration`。
    public private(set) var progress: Double = 0
    /// 当前真实音频电平 0…1，由播放器实时功率（metering）驱动。
    public private(set) var level: Float = 0
    public var onPlaybackFinished: (@MainActor (_ successfully: Bool) -> Void)?
    public var onProgress: (@MainActor (_ progress: Double) -> Void)?
    public var onLevel: (@MainActor (_ level: Float) -> Void)?

    public override init() {
        super.init()
    }

    public func play(data: Data) throws {
        stop()
        let nextPlayer = try AVAudioPlayer(data: data)
        nextPlayer.delegate = self
        nextPlayer.isMeteringEnabled = true
        nextPlayer.prepareToPlay()
        guard nextPlayer.play() else {
            throw AudioPlaybackError.playbackFailed
        }
        player = nextPlayer
        isPlaying = true
        updateProgressAndMeter()
        startProgressTask()
    }

    public func stop() {
        stopProgressTask()
        player?.stop()
        player = nil
        isPlaying = false
        setProgress(0)
        setLevel(0)
    }

    public func duration(for data: Data) -> TimeInterval? {
        try? AVAudioPlayer(data: data).duration
    }

    public nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        let finishedPlayerID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self,
                  let currentPlayer = self.player,
                  ObjectIdentifier(currentPlayer) == finishedPlayerID
            else { return }
            self.stopProgressTask()
            self.player = nil
            self.isPlaying = false
            self.setLevel(0)
            self.onPlaybackFinished?(flag)
        }
    }

    /// 20Hz 采样 `currentTime` 与实时电平：波形的进度与振幅跟得上人耳，能耗极低。
    private func startProgressTask() {
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isPlaying else { return }
                self.updateProgressAndMeter()
                try? await Task.sleep(for: .seconds(SpeechRailDesignTokens.Waveform.progressInterval))
            }
        }
    }

    private func stopProgressTask() {
        progressTask?.cancel()
        progressTask = nil
    }

    private func updateProgressAndMeter() {
        guard let player, player.duration > 0 else { return }
        setProgress(min(max(player.currentTime / player.duration, 0), 1))
        player.updateMeters()
        let power = player.averagePower(forChannel: 0)
        // power: -160dB ~ 0dB。通常语音人声感知在 -45dB ~ 0dB
        let minDb: Float = -45.0
        let rawLevel = max(0.0, min(1.0, (power - minDb) / (-minDb)))
        // 适当平滑避免生硬抖动
        let smoothed = level * 0.35 + rawLevel * 0.65
        setLevel(smoothed)
    }

    private func setProgress(_ value: Double) {
        guard value != progress else { return }
        progress = value
        onProgress?(value)
    }

    private func setLevel(_ value: Float) {
        guard abs(value - level) > 0.001 || value == 0 else { return }
        level = value
        onLevel?(value)
    }
}
