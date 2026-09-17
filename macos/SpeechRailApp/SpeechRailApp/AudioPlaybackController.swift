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
    ///
    /// 2026-09-16 新增（REDESIGN-SPEC §11.6 第五十七轮）：详情面板的波形此前只知道
    /// 「在播」，画不出「播到哪了」。这是真实进度，不是按固定时长自走的动画——
    /// 播放器一暂停、一结束、一换曲，值就跟着变。
    public private(set) var progress: Double = 0
    public var onPlaybackFinished: (@MainActor (_ successfully: Bool) -> Void)?
    public var onProgress: (@MainActor (_ progress: Double) -> Void)?

    public override init() {
        super.init()
    }

    public func play(data: Data) throws {
        stop()
        let nextPlayer = try AVAudioPlayer(data: data)
        nextPlayer.delegate = self
        nextPlayer.prepareToPlay()
        guard nextPlayer.play() else {
            throw AudioPlaybackError.playbackFailed
        }
        player = nextPlayer
        isPlaying = true
        updateProgress()
        startProgressTask()
    }

    public func stop() {
        stopProgressTask()
        player?.stop()
        player = nil
        isPlaying = false
        setProgress(0)
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
            self.onPlaybackFinished?(flag)
        }
    }

    /// 20Hz 采样 `currentTime`：波形的进度要跟得上人耳，但也没必要每帧去问。
    private func startProgressTask() {
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isPlaying else { return }
                self.updateProgress()
                try? await Task.sleep(for: .seconds(SpeechRailDesignTokens.Waveform.progressInterval))
            }
        }
    }

    private func stopProgressTask() {
        progressTask?.cancel()
        progressTask = nil
    }

    private func updateProgress() {
        guard let player, player.duration > 0 else { return }
        setProgress(min(max(player.currentTime / player.duration, 0), 1))
    }

    private func setProgress(_ value: Double) {
        guard value != progress else { return }
        progress = value
        onProgress?(value)
    }
}
