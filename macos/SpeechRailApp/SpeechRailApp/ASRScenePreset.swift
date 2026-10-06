import Foundation
import SpeechRailControlKit

/// The App's only mapping from a caller scenario to Realtime ASR policy.
public enum ASRScenePreset: String, CaseIterable, Equatable, Sendable {
    case assistantTurnTaking
    case assistantDuplex
    case meeting
    case caption
    case teleprompter

    static func assistant(_ mode: AssistantMode) -> Self {
        mode == .turnTaking ? .assistantTurnTaking : .assistantDuplex
    }

    public var task: SpeechRailSessionUpdate.Task {
        switch self {
        case .assistantTurnTaking, .assistantDuplex:
            .conversation
        case .meeting, .teleprompter:
            .transcription
        case .caption:
            .caption
        }
    }

    public var policy: SpeechRailASRPolicy {
        let previewInterval: Int
        let maxSegment: Int
        let finalization: SpeechRailASRPolicy.Finalization

        switch self {
        case .assistantTurnTaking:
            previewInterval = 800
            maxSegment = 20_000
            finalization = .fullSegment
        case .assistantDuplex:
            previewInterval = 600
            maxSegment = 20_000
            finalization = .fullSegment
        case .meeting:
            previewInterval = 1_000
            maxSegment = 20_000
            finalization = .fullSegment
        case .caption:
            previewInterval = 500
            maxSegment = 8_000
            finalization = .fullSegment
        case .teleprompter:
            previewInterval = 500
            maxSegment = 8_000
            finalization = .streamingFinalize
        }

        return SpeechRailASRPolicy(
            previewIntervalMilliseconds: previewInterval,
            maxSegmentMilliseconds: maxSegment,
            finalization: finalization,
            finalDeadlineMilliseconds: nil
        )
    }

    /// Shared VAD starting points; these remain App decisions.
    public var silenceDurationMilliseconds: Int {
        switch self {
        case .assistantTurnTaking:
            1_200
        case .assistantDuplex, .meeting:
            900
        case .caption, .teleprompter:
            400
        }
    }

    public var threshold: Double { 0.5 }

    public var prefixPaddingMilliseconds: Int { 300 }
}
