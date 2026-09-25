import XCTest
@testable import SpeechRailAppSupport

/// 纯状态测试：注入手动时钟，不实际 sleep。只验证"什么时候切、
/// 切在哪、按什么单位算限额"，不涉及任何模型的声学表现。
final class AssistantSpeechTextBufferTests: XCTestCase {
    private final class ManualClock {
        private(set) var now = ContinuousClock().now
        func advance(_ duration: Duration) { now = now.advanced(by: duration) }
    }

    private func makeBuffer(
        clock: ManualClock,
        configuration: AssistantSpeechTextBuffer.Configuration = .default
    ) -> AssistantSpeechTextBuffer {
        AssistantSpeechTextBuffer(configuration: configuration, now: { clock.now })
    }

    func testCompleteSentenceIsReadyWithoutWaiting() {
        let clock = ManualClock()
        var buffer = makeBuffer(clock: clock)
        buffer.append("你好。")

        XCTAssertEqual(buffer.readyChunks(now: clock.now), ["你好。"])
        XCTAssertFalse(buffer.hasPendingText)
    }

    func testNumberAndUnitAcrossDeltasStayTogether() {
        let clock = ManualClock()
        var buffer = makeBuffer(clock: clock)

        buffer.append("3")
        XCTAssertEqual(buffer.readyChunks(now: clock.now), [])
        buffer.append(".5")
        XCTAssertEqual(buffer.readyChunks(now: clock.now), [])
        buffer.append("kg")
        XCTAssertEqual(
            buffer.readyChunks(now: clock.now),
            [],
            "数字和单位还在长的时候不能提前切"
        )

        clock.advance(.milliseconds(150))
        XCTAssertEqual(buffer.readyChunks(now: clock.now), ["3.5kg"])
    }

    func testEnglishTailWaitsForTheDeadline() {
        let clock = ManualClock()
        var buffer = makeBuffer(clock: clock)
        buffer.append("Hello wor")

        XCTAssertEqual(buffer.readyChunks(now: clock.now), [])

        clock.advance(.milliseconds(150))
        XCTAssertEqual(buffer.readyChunks(now: clock.now), ["Hello "])
        XCTAssertEqual(buffer.pendingText, "wor")
    }

    func testDeadlineIsBoundedByTheInjectedClockNotRealTime() {
        let clock = ManualClock()
        var buffer = makeBuffer(clock: clock)
        buffer.append("abc")
        XCTAssertEqual(buffer.readyChunks(now: clock.now), [])

        clock.advance(.milliseconds(149))
        XCTAssertEqual(buffer.readyChunks(now: clock.now), [])
        clock.advance(.milliseconds(1))
        XCTAssertEqual(buffer.readyChunks(now: clock.now), ["abc"])
    }

    func testUnclosedMarkdownIsHeldUntilItCloses() {
        let clock = ManualClock()
        var buffer = makeBuffer(clock: clock)
        buffer.append("**bold")

        XCTAssertEqual(buffer.readyChunks(now: clock.now), [])
        clock.advance(.seconds(5))
        XCTAssertEqual(
            buffer.readyChunks(now: clock.now),
            [],
            "闭合之前即使等到超时也不能把 Markdown 切开"
        )

        buffer.append("**")
        XCTAssertEqual(buffer.readyChunks(now: clock.now), ["**bold**"])
    }

    func testForcedUrgencyBreaksStuckMarkdownInsteadOfStallingTheTurn() {
        let clock = ManualClock()
        var buffer = makeBuffer(clock: clock)
        buffer.append("**bold")
        clock.advance(.seconds(10))

        XCTAssertEqual(buffer.readyChunks(now: clock.now, force: true), ["**bold"])
        XCTAssertFalse(buffer.hasPendingText)
    }

    func testChunkCapIsCountedInUnicodeScalars() {
        XCTAssertEqual(AssistantSpeechTextBuffer.scalarCount("👨‍👩‍👧‍👦"), 7)
        XCTAssertEqual("👨‍👩‍👧‍👦".count, 1, "String.count 是 grapheme，不能拿来当线上限额")

        var configuration = AssistantSpeechTextBuffer.Configuration.default
        configuration.maximumChunkScalars = 8
        configuration.minimumChunkScalars = 8
        let clock = ManualClock()
        var buffer = makeBuffer(clock: clock, configuration: configuration)

        buffer.append("0123456789abcdef")
        let chunks = buffer.readyChunks(now: clock.now)
        XCTAssertEqual(chunks, ["01234567", "89abcdef"], "超过单片上限必须切开，不能无界攒文本")
    }

    func testWhitespaceInsideAChunkIsPreserved() {
        var configuration = AssistantSpeechTextBuffer.Configuration.default
        configuration.minimumChunkScalars = 4
        let clock = ManualClock()
        var buffer = makeBuffer(clock: clock, configuration: configuration)
        buffer.append("one two three ")

        XCTAssertEqual(buffer.readyChunks(now: clock.now), ["one two three "])
    }

    func testLimitsAreReportedInScalars() {
        var configuration = AssistantSpeechTextBuffer.Configuration.default
        configuration.maximumChunkScalars = 4
        configuration.maximumTotalScalars = 6
        let clock = ManualClock()
        var buffer = makeBuffer(clock: clock, configuration: configuration)

        XCTAssertEqual(buffer.append("abcde"), .append(offered: 5, limit: 4))
        buffer.reset()
        XCTAssertEqual(buffer.append("abc"), nil)
        XCTAssertEqual(buffer.append("defg"), .total(offered: 7, limit: 6))
    }
}
