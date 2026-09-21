import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

struct TeleprompterTimingPolicyTests {
    @Test func metricsSeparateHanAndLatinWords() {
        let text = "你好 World，这是一个 test 123。"
        let metrics = TeleprompterTimingPolicy.countMetrics(in: text)
        // Han: 你 好 这 是 一 个 (6); digits are unresolved rather than
        // pretending that their pronunciation is one known Latin word.
        #expect(metrics.hanCount == 6)
        #expect(metrics.latinWordCount == 2)
        #expect(metrics.totalUnits == 8)
        #expect(metrics.hasUnresolvedPronunciation)
        #expect(!metrics.isEmpty)
    }

    @Test func unknownPronunciationMakesPreflightUncertain() {
        let metrics = TeleprompterTimingPolicy.countMetrics(in: "版本 2.0，访问 https://example.com")
        #expect(metrics.hasUnresolvedPronunciation)
        #expect(metrics.uncertaintyReasons.contains("unresolvedPronunciation"))
        #expect(metrics.uncertaintyReasons.contains("url"))

        let estimate = TeleprompterTimingPolicy.estimateDuration(metrics: metrics, pace: .natural)
        #expect(estimate.pointSeconds == nil)
        #expect(estimate.knownPartSeconds > 0)
        #expect(estimate.isUncertain)
    }

    @Test func estimateDurationCalculatesPaceAndCalibration() {
        // 220 Han characters at natural pace (220 words/min) = 60 seconds
        let text = String(repeating: "中", count: 220)
        let metrics = TeleprompterTimingPolicy.countMetrics(in: text)

        let naturalEst = TeleprompterTimingPolicy.estimateDuration(metrics: metrics, pace: .natural, calibrationFactor: 1.0)
        #expect(naturalEst.pointSeconds != nil)
        #expect(abs((naturalEst.pointSeconds ?? 0) - 60.0) < 0.1)
        #expect(naturalEst.rangeSeconds != nil)
        #expect(abs((naturalEst.rangeSeconds?.lowerBound ?? 0) - 48.0) < 0.1) // 0.8 * 60
        #expect(abs((naturalEst.rangeSeconds?.upperBound ?? 0) - 75.0) < 0.1) // 1.25 * 60

        // With calibration factor 1.2 (slower, takes 1.2x time)
        let calibratedEst = TeleprompterTimingPolicy.estimateDuration(metrics: metrics, pace: .natural, calibrationFactor: 1.2)
        #expect(abs((calibratedEst.pointSeconds ?? 0) - 72.0) < 0.1)

        // At brisk pace (260 words/min): 60 * (220 / 260) ≈ 50.77s
        let briskEst = TeleprompterTimingPolicy.estimateDuration(metrics: metrics, pace: .brisk, calibrationFactor: 1.0)
        #expect(abs((briskEst.pointSeconds ?? 0) - (60.0 * 220.0 / 260.0)) < 0.1)
    }

    @Test func preflightEvaluatesFeasibilityBands() {
        // Target 1 minute = 60s, budget B = 0.95 * 60 = 57s

        // 1. Empty text -> emptyText
        let emptyConclusion = TeleprompterTimingPolicy.evaluatePreflight(text: "", targetMinutes: 1, pace: .natural)
        #expect(emptyConclusion == .emptyText)

        // 2. Invalid target (< 1 or > 120) -> invalidTarget
        let invalidConclusion = TeleprompterTimingPolicy.evaluatePreflight(text: "你好", targetMinutes: 0, pace: .natural)
        if case .invalidTarget = invalidConclusion {
            #expect(true)
        } else {
            Issue.record("Expected invalidTarget")
        }

        // 3. Underfilled: D / B < 0.75 -> D < 42.75s (e.g. 50 characters at 220/min ≈ 13.6s)
        let underfilledText = String(repeating: "字", count: 50)
        let underfilledConclusion = TeleprompterTimingPolicy.evaluatePreflight(text: underfilledText, targetMinutes: 1, pace: .natural)
        if case .underfilled = underfilledConclusion {
            #expect(true)
        } else {
            Issue.record("Expected underfilled, got \(underfilledConclusion)")
        }

        // 4. Matching: 0.75 <= D / B <= 1.00 -> 42.75s <= D <= 57s (e.g. 180 characters ≈ 49.1s)
        let matchingText = String(repeating: "字", count: 180)
        let matchingConclusion = TeleprompterTimingPolicy.evaluatePreflight(text: matchingText, targetMinutes: 1, pace: .natural)
        if case .matching = matchingConclusion {
            #expect(true)
        } else {
            Issue.record("Expected matching, got \(matchingConclusion)")
        }

        // 5. Slightly Over: 1.00 < D / B <= 1.15 -> 57s < D <= 65.55s (e.g. 230 characters ≈ 62.7s)
        let slightlyOverText = String(repeating: "字", count: 230)
        let slightlyOverConclusion = TeleprompterTimingPolicy.evaluatePreflight(text: slightlyOverText, targetMinutes: 1, pace: .natural)
        if case .slightlyOver = slightlyOverConclusion {
            #expect(true)
        } else {
            Issue.record("Expected slightlyOver, got \(slightlyOverConclusion)")
        }

        // 6. Tight: D / B > 1.15 -> D > 65.55s (e.g. 350 characters ≈ 95.5s)
        let tightText = String(repeating: "字", count: 350)
        let tightConclusion = TeleprompterTimingPolicy.evaluatePreflight(text: tightText, targetMinutes: 1, pace: .natural)
        if case .tight = tightConclusion {
            #expect(true)
        } else {
            Issue.record("Expected tight, got \(tightConclusion)")
        }
    }
}
