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

    public private(set) var isPlaying = false
    public var onPlaybackFinished: (@MainActor (_ successfully: Bool) -> Void)?

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
    }

    public func stop() {
        player?.stop()
        player = nil
        isPlaying = false
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
            self.player = nil
            self.isPlaying = false
            self.onPlaybackFinished?(flag)
        }
    }
}
