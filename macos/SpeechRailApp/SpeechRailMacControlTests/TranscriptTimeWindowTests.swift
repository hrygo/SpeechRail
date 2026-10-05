import Foundation
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

    func testQualityCannotBeAlignedWithoutAnAcousticRange() {
        // 类型层面就不存在"有对齐质量但没有声学区间"的组合。
        let forged = TranscriptTimeWindow(observedStart: 0, observedEnd: 5, acousticRange: nil)
        XCTAssertEqual(forged.quality, .unavailable)
        XCTAssertNil(forged.speechRange)
    }
}
