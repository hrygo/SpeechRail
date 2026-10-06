import Testing
import SpeechRailControlKit
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

struct ASRScenePresetTests {
    @Test func fiveScenePresetsShareOneExplicitPolicyMapping() {
        let expected: [(ASRScenePreset, SpeechRailSessionUpdate.Task, Int, Int, String)] = [
            (.assistantTurnTaking, .conversation, 1_200, 20_000, "full_segment"),
            (.assistantDuplex, .conversation, 900, 20_000, "full_segment"),
            (.meeting, .transcription, 900, 20_000, "full_segment"),
            (.caption, .caption, 400, 8_000, "full_segment"),
            (.teleprompter, .transcription, 400, 8_000, "streaming_finalize"),
        ]

        #expect(ASRScenePreset.allCases.count == 5)

        for (preset, task, silence, maxSegment, finalization) in expected {
            #expect(preset.task == task)
            #expect(preset.silenceDurationMilliseconds == silence)
            #expect(preset.policy.maxSegmentMilliseconds == maxSegment)
            #expect(preset.policy.finalization.rawValue == finalization)
            #expect(preset.policy.finalDeadlineMilliseconds == nil)
        }

        #expect(ASRScenePreset.assistant(.turnTaking) == .assistantTurnTaking)
        #expect(ASRScenePreset.assistant(.duplex) == .assistantDuplex)
    }

    @Test func presetsUseTheSpecifiedPreviewIntervalsAndEndpointingThreshold() {
        let expected: [(ASRScenePreset, Int)] = [
            (.assistantTurnTaking, 800),
            (.assistantDuplex, 600),
            (.meeting, 1_000),
            (.caption, 500),
            (.teleprompter, 400),
        ]

        for (preset, previewInterval) in expected {
            #expect(preset.policy.previewIntervalMilliseconds == previewInterval)
            #expect(preset.threshold == 0.5)
            #expect(preset.prefixPaddingMilliseconds == 300)
        }
    }
}
