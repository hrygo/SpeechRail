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

    /// 倍率 1.0 既可能是没人试读过的默认值，也可能是某次试读的真实结果。
    /// 只看倍率时两者无法区分，未测过的估计会被当成实测的显示（#111 步骤 5）。
    @Test func theSameFactorCarriesItsProvenance() {
        let text = String(repeating: "中", count: 220)
        let metrics = TeleprompterTimingPolicy.countMetrics(in: text)

        let uncalibrated = TeleprompterTimingPolicy.estimateDuration(metrics: metrics, pace: .natural)
        #expect(uncalibrated.pointSeconds != nil)
        #expect(!uncalibrated.isCalibrated)

        // 一次真实的 60 秒试读：点估计同为 60 秒，但这次它是被测过的。
        let measured = TeleprompterTimingPolicy.estimateDuration(
            metrics: metrics,
            pace: .natural,
            calibrationFactor: 1.0,
            calibrationSource: .manualTrial(durationSeconds: 60)
        )
        #expect(measured.isCalibrated)
        #expect(abs((measured.pointSeconds ?? 0) - 60.0) < 0.1)

        // 校准过的估计即使遇到读法不确定的文本，也仍然带着「测过」这一事实。
        let measuredWithDigits = TeleprompterTimingPolicy.estimateDuration(
            metrics: TeleprompterTimingPolicy.countMetrics(in: "版本 2.0"),
            pace: .natural,
            calibrationFactor: 1.0,
            calibrationSource: .manualTrial(durationSeconds: 20)
        )
        #expect(measuredWithDigits.isUncertain)
        #expect(measuredWithDigits.isCalibrated)
    }

    /// 只有带分钟数的结论需要标注「未试读校准」。「无内容」「目标无效」「无法预估」
    /// 本来就没有时长数字，标了反而变成噪声（#111 步骤 5）。
    @Test func onlyDurationBearingConclusionsAskForACalibrationNote() {
        let underfilled = TeleprompterTimingPolicy.PreflightConclusion
            .underfilled(estimateMinutes: 2, targetMinutes: 5)
        let matching = TeleprompterTimingPolicy.PreflightConclusion
            .matching(estimateMinutes: 5, targetMinutes: 5)
        let slightlyOver = TeleprompterTimingPolicy.PreflightConclusion
            .slightlyOver(estimateMinutes: 5.4, targetMinutes: 5)
        let tight = TeleprompterTimingPolicy.PreflightConclusion
            .tight(estimateMinutes: 8, targetMinutes: 5)

        for conclusion in [underfilled, matching, slightlyOver, tight] {
            #expect(conclusion.showsDurationEstimate)
        }
        for conclusion in [
            TeleprompterTimingPolicy.PreflightConclusion.emptyText,
            .invalidTarget("目标时长应在 1–120 分钟之间。"),
            .uncertain("包含数字、网址或非中英文本，无法可靠预估整稿时长"),
        ] {
            #expect(!conclusion.showsDurationEstimate)
        }
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

    @Test func anOutOfRangeCalibrationFactorIsClampedToThePolicyBounds() {
        // 校准倍率来自试读实测，异常值必须夹在策略区间内。断言钉的是**算出来的秒数**
        // 而不是「夹取后等于边界值」——后者在边界本身被改动时两边一起动，永远成立。
        // 变异探针 M4 把下界从 0.5 放到 0.0 时，此前全量 712 项无人变红：
        // 没有任何用例传过区间外的倍率。
        let metrics = TeleprompterTimingPolicy.countMetrics(
            in: String(repeating: "中", count: 220)
        )
        // 220 汉字、自然档 220 字/分 ⇒ 基准 60 秒；下界 0.5 ⇒ 30 秒，上界 2.0 ⇒ 120 秒。
        let tooFast = TeleprompterTimingPolicy.estimateDuration(
            metrics: metrics, pace: .natural, calibrationFactor: 0.1
        )
        #expect(abs((tooFast.pointSeconds ?? 0) - 30.0) < 0.1)

        let tooSlow = TeleprompterTimingPolicy.estimateDuration(
            metrics: metrics, pace: .natural, calibrationFactor: 9.0
        )
        #expect(abs((tooSlow.pointSeconds ?? 0) - 120.0) < 0.1)
    }

    @Test func theTrialGuidanceComesFromThePolicyRatherThanBeingHardcoded() {
        // 「建议 60–90 秒」此前是 sheet 里的字面量，而策略里那个 60 是全仓无人读取的
        // 孤立常量。变异 M5 把常量改成 30 全量无人变红，说明二者从未连在一起。
        #expect(TeleprompterTimingPolicy.trialGuidanceText == "建议 60–90 秒")
        #expect(
            TeleprompterTimingPolicy.minimumTrialDurationSeconds
                < TeleprompterTimingPolicy.suggestedTrialDurationRange.lowerBound
        )
    }
}
