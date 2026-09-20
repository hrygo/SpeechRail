import Foundation

public struct TeleprompterFollowController: Sendable {
    public private(set) var currentIndex: Int
    public private(set) var mode: TeleprompterRunMode
    public private(set) var uncertainty: Double?
    public private(set) var partialPreview: String?

    private var followEpoch = 0

    public init(
        currentIndex: Int = 0,
        mode: TeleprompterRunMode = .following
    ) {
        self.currentIndex = max(0, currentIndex)
        self.mode = mode
    }

    public mutating func receivePartial(_ text: String) {
        guard mode == .following else { return }
        partialPreview = text
    }

    public mutating func receiveCompleted(
        _ text: String,
        segments: [TeleprompterSegment],
        aligner: TeleprompterAligner
    ) {
        guard mode == .following, !segments.isEmpty else { return }
        partialPreview = nil
        let result = aligner.evaluate(
            completedTranscript: text,
            segments: segments,
            currentIndex: min(currentIndex, segments.count - 1)
        )
        switch result.decision {
        case let .stay(confidence):
            uncertainty = confidence < aligner.configuration.minimumConfidence
                ? confidence
                : nil
        case let .advance(to, _):
            currentIndex = min(max(0, to), segments.count - 1)
            uncertainty = nil
        case let .uncertain(_, confidence):
            uncertainty = confidence
        }
    }

    public mutating func pause() {
        mode = .paused
        partialPreview = nil
        followEpoch += 1
    }

    public mutating func resume() {
        mode = .following
        uncertainty = nil
        partialPreview = nil
        followEpoch += 1
    }

    public mutating func move(to index: Int, segmentCount: Int) {
        guard segmentCount > 0 else { return }
        currentIndex = min(max(0, index), segmentCount - 1)
        mode = .manual
        uncertainty = nil
        partialPreview = nil
        followEpoch += 1
    }

    public mutating func enterManual() {
        mode = .manual
        uncertainty = nil
        partialPreview = nil
        followEpoch += 1
    }

    public mutating func resetFollowWindow() {
        mode = .following
        uncertainty = nil
        partialPreview = nil
        followEpoch += 1
    }
}
