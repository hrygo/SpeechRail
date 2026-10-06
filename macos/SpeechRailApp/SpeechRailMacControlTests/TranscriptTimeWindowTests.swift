import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 时间证据（方案 MA-02 / MC-15）。
///
/// 钉的是**不许对着用户谎报说话时刻**：客户端只在定稿那一刻知道
/// "什么时候收到的"，把那个间隔当发声时间就是编造精度。
final class TranscriptTimeWindowTests: XCTestCase {
    func testObservedOnlyHasNoSpeechRange() {
        let window = TranscriptTimeWindow.observedOnly(start: 0, end: 12.4)
        // 没有对齐证据时"什么时候说的"是未知的，不是 0，也不是 12.4。
        XCTAssertNil(window.speechRange)
    }

    func testObservedOnlyIsMarkedUnavailable() {
        let window = TranscriptTimeWindow.observedOnly(start: 0, end: 12.4)
        XCTAssertEqual(window.quality, .unavailable)
    }

    func testObservedOnlySaysItDoesNotKnowWhenItWasSpoken() {
        let window = TranscriptTimeWindow.observedOnly(start: 0, end: 12.4)
        let text = window.displayText
        XCTAssertTrue(text.contains("未知"), "未知发声时刻必须说出来，实际：\(text)")
        XCTAssertFalse(text.contains("00:00"), "没有对齐证据就不许出现 00:00 这种精确值：\(text)")
    }

    func testAlignedKeepsItsAcousticRange() {
        let window = TranscriptTimeWindow.aligned(
            observedStart: 0, observedEnd: 20, acoustic: 3.5...9.25
        )
        XCTAssertEqual(window.speechRange, 3.5...9.25)
        XCTAssertEqual(window.quality, .aligned)
    }

    func testAlignedDisplaysTheAcousticRangeNotTheReceiptInterval() {
        let window = TranscriptTimeWindow.aligned(
            observedStart: 0, observedEnd: 600, acoustic: 3.5...9.25
        )
        // 显示的必须是发声区间，不是"收了两分钟才等到"那个观测区间。
        XCTAssertTrue(window.displayText.contains("00:04"))  // 3.5s 四舍五入
        XCTAssertTrue(window.displayText.contains("00:09"))  // 9.25s 四舍五入
        XCTAssertFalse(window.displayText.contains("10:00"))
    }

    func testObservedRangeIsStillAvailableForHonestDisplay() {
        let window = TranscriptTimeWindow.observedOnly(start: 65, end: 78)
        // 观测区间诚实地说"这段是在这时被记下来的"。
        XCTAssertEqual(window.observedText, "01:05–01:18")
    }

    func testAlignedStillRemembersItsObservationWindow() {
        let window = TranscriptTimeWindow.aligned(
            observedStart: 65, observedEnd: 78, acoustic: 66...70
        )
        XCTAssertEqual(window.observedText, "01:05–01:18")
        XCTAssertEqual(window.speechRange, 66...70)
    }

    func testNegativeValuesAreClampedToZeroInDisplay() {
        // 对齐器给出负时刻时不能显示 "-01:-30" 这种东西。
        let window = TranscriptTimeWindow.aligned(
            observedStart: -5, observedEnd: -1, acoustic: (-3 ... -1)
        )
        XCTAssertEqual(window.observedText, "00:00–00:00")
        XCTAssertFalse(window.displayText.contains("-"))
    }

    func testSubSecondRoundsInsteadOfTruncatingAway() {
        let window = TranscriptTimeWindow.aligned(
            observedStart: 0, observedEnd: 1, acoustic: (0 ... 59.6)
        )
        XCTAssertTrue(window.displayText.contains("01:00"))
    }

    // MARK: - 从对齐证据升级

    private func unit(
        start: Int?,
        end: Int?,
        quality: String? = "aligned"
    ) -> RealtimeASRClient.AttributionUnit {
        RealtimeASRClient.AttributionUnit(
            segmentUID: "seg",
            audioStartSample: start,
            audioEndSample: end,
            timingQuality: quality
        )
    }

    func testAlignedUnitsUpgradeTheWindow() {
        let observed = TranscriptTimeWindow.observedOnly(start: 0, end: 20)
        let upgraded = TranscriptTimeWindow.aligned(
            observed: observed,
            units: [unit(start: 24_000, end: 48_000)],  // 1s → 2s @24k
            sampleRate: 24_000
        )
        XCTAssertEqual(upgraded?.speechRange, 1 ... 2)
        XCTAssertEqual(upgraded?.quality, .aligned)
    }

    func testUnitsWithoutAlignedQualityDoNotUpgrade() {
        let observed = TranscriptTimeWindow.observedOnly(start: 0, end: 20)
        // 服务端自己都说没对齐，就不许我们替它宣布对齐了。
        XCTAssertNil(TranscriptTimeWindow.aligned(
            observed: observed,
            units: [unit(start: 24_000, end: 48_000, quality: "unavailable")],
            sampleRate: 24_000
        ))
    }

    func testMissingSamplesDoNotUpgrade() {
        let observed = TranscriptTimeWindow.observedOnly(start: 0, end: 20)
        XCTAssertNil(TranscriptTimeWindow.aligned(
            observed: observed,
            units: [unit(start: nil, end: 48_000)],
            sampleRate: 24_000
        ))
        XCTAssertNil(TranscriptTimeWindow.aligned(
            observed: observed,
            units: [unit(start: 24_000, end: nil)],
            sampleRate: 24_000
        ))
    }

    func testZeroOrInvertedSampleRangeDoesNotUpgrade() {
        let observed = TranscriptTimeWindow.observedOnly(start: 0, end: 20)
        XCTAssertNil(TranscriptTimeWindow.aligned(
            observed: observed,
            units: [unit(start: 48_000, end: 24_000)],
            sampleRate: 24_000
        ))
        XCTAssertNil(TranscriptTimeWindow.aligned(
            observed: observed,
            units: [unit(start: 48_000, end: 48_000)],
            sampleRate: 24_000
        ))
    }

    func testEmptyUnitsDoNotUpgrade() {
        let observed = TranscriptTimeWindow.observedOnly(start: 0, end: 20)
        XCTAssertNil(TranscriptTimeWindow.aligned(observed: observed, units: [], sampleRate: 24_000))
    }

    func testNonPositiveSampleRateDoesNotUpgrade() {
        let observed = TranscriptTimeWindow.observedOnly(start: 0, end: 20)
        XCTAssertNil(TranscriptTimeWindow.aligned(
            observed: observed,
            units: [unit(start: 24_000, end: 48_000)],
            sampleRate: 0
        ))
    }

    func testSpanningUnitsUseTheWholeSpan() {
        let observed = TranscriptTimeWindow.observedOnly(start: 0, end: 30)
        let upgraded = TranscriptTimeWindow.aligned(
            observed: observed,
            units: [unit(start: 72_000, end: 96_000), unit(start: 24_000, end: 48_000)],
            sampleRate: 24_000
        )
        // 跨多个单元时取整段跨度，不取某一个单元。
        XCTAssertEqual(upgraded?.speechRange, 1 ... 4)
    }

    func testOutOfRangeSamplesAreClampedIntoTheObservedWindow() {
        let observed = TranscriptTimeWindow.observedOnly(start: 5, end: 10)
        let upgraded = TranscriptTimeWindow.aligned(
            observed: observed,
            // 0s–120s：远超这场会的观测窗口。
            units: [unit(start: 0, end: 2_880_000)],
            sampleRate: 24_000
        )
        // 夹进观测区间，不制造越界的时间。
        XCTAssertEqual(upgraded?.speechRange, 5 ... 10)
    }

    func testUpgradeKeepsTheObservedWindow() {
        let observed = TranscriptTimeWindow.observedOnly(start: 5, end: 10)
        let upgraded = TranscriptTimeWindow.aligned(
            observed: observed,
            units: [unit(start: 120_000, end: 144_000)],
            sampleRate: 24_000
        )
        XCTAssertEqual(upgraded?.observedStart, 5)
        XCTAssertEqual(upgraded?.observedEnd, 10)
        XCTAssertEqual(upgraded?.speechRange, 5 ... 6)
    }

    // MARK: - 界面呈现

    func testTimecodeColumnShowsNothingFakeWithoutAlignment() {
        // 那一列如果写着 00:12，用户只会读成"这句话是 12 秒时说的"。
        XCTAssertEqual(
            TranscriptTimeWindow.timecodeColumn(observed: 12, quality: .unavailable),
            "—"
        )
        XCTAssertEqual(TranscriptTimeWindow.timecodeColumn(observed: 12, quality: nil), "—")
    }

    func testTimecodeColumnShowsTheTimeOnceAligned() {
        XCTAssertEqual(
            TranscriptTimeWindow.timecodeColumn(observed: 12.4, quality: .aligned),
            "00:12"
        )
    }

    func testAccessibilityTextSaysBothThingsWhenUnknown() {
        let text = TranscriptTimeWindow.accessibilityText(
            observedStart: 60, observedEnd: 78, quality: .unavailable
        )
        XCTAssertTrue(text.contains("未知"), text)
        XCTAssertTrue(text.contains("记下来"), "必须说明这是记录时刻而不是说话时刻：\(text)")
    }

    func testAccessibilityTextReportsTheSpokenRangeWhenAligned() {
        let text = TranscriptTimeWindow.accessibilityText(
            observedStart: 60, observedEnd: 78, quality: .aligned
        )
        XCTAssertTrue(text.contains("说话时刻"), text)
        XCTAssertFalse(text.contains("未知"), text)
    }

    func testQualityCannotBeAlignedWithoutAnAcousticRange() {
        // 类型层面就不存在"有对齐质量但没有声学区间"的组合。
        let forged = TranscriptTimeWindow(observedStart: 0, observedEnd: 5, acousticRange: nil)
        XCTAssertEqual(forged.quality, .unavailable)
        XCTAssertNil(forged.speechRange)
    }
}
