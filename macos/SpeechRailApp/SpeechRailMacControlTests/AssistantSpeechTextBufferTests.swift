import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

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

    // MARK: - D11：开嗓时机与原始空白

    func testLeadingWhitespaceIsBufferedUntilRealTextArrives() {
        var gate = AssistantSpeechStartGate()

        XCTAssertEqual(gate.offer(" "), .buffered)
        XCTAssertEqual(gate.offer("\n"), .buffered)
        XCTAssertFalse(gate.isStarted, "只有空白时不能开嗓")

        XCTAssertEqual(
            gate.offer("你好"),
            .start(pending: " \n你好"),
            "开嗓时要把之前缓冲的空白原样一起交出去，不能吃掉"
        )
        XCTAssertTrue(gate.isStarted)
        XCTAssertEqual(gate.pendingScalars, 0)
    }

    /// 曾经的缺陷：`delta` 去掉空白后非空才 offer，于是分隔空白被丢掉，
    /// 分段到达的正文在朗读输入里粘成一个词。
    func testWhitespaceBetweenDeltasReachesTheUtteranceUnchanged() {
        var gate = AssistantSpeechStartGate()
        var spoken: [String] = []

        for delta in ["Hello", " ", "", "\n", "world", " ", "again"] {
            switch gate.offer(delta) {
            case .buffered:
                continue
            case .start(let pending):
                spoken.append(pending)
            case .speak(let text):
                spoken.append(text)
            }
        }

        XCTAssertEqual(
            spoken.joined(),
            "Hello \nworld again",
            "清洗前的原始增量拼接必须与输入完全一致：无重复、无丢失"
        )
    }

    func testWholeWhitespaceTurnNeverStarts() {
        var gate = AssistantSpeechStartGate()
        var starts = 0

        for delta in [" ", "\n", "\t", "  \n "] {
            if case .start = gate.offer(delta) { starts += 1 }
        }

        XCTAssertEqual(starts, 0, "纯空白的一轮不许启动朗读")
        XCTAssertFalse(gate.isStarted)
    }

    func testUnicodeAndMarkdownAdjacencyIsPreserved() {
        var gate = AssistantSpeechStartGate()
        var spoken: [String] = []
        for delta in ["**粗**", " ", "与", " ", "emoji 🎧", "\n", "结束"] {
            switch gate.offer(delta) {
            case .buffered: continue
            case .start(let pending): spoken.append(pending)
            case .speak(let text): spoken.append(text)
            }
        }

        XCTAssertEqual(spoken.joined(), "**粗** 与 emoji 🎧\n结束")
    }

    /// 开嗓失败之后不许反复尝试 start，但正文继续。
    func testDisabledStartingNeverStartsAgain() {
        var gate = AssistantSpeechStartGate()
        XCTAssertEqual(gate.offer("你好"), .start(pending: "你好"))
        // 真实流程里 start 失败后调用方会立刻 disableStarting()。
        gate.disableStarting()

        XCTAssertEqual(gate.offer("还有"), .buffered)
        XCTAssertEqual(gate.offer("。"), .buffered)
        XCTAssertFalse(gate.isStarted)
    }

    func testPendingBufferIsBoundedAndReportsTheLimit() {
        var configuration = AssistantSpeechStartGate.Configuration.default
        configuration.maximumPendingScalars = 8
        var gate = AssistantSpeechStartGate(configuration: configuration)

        // 只用空白把缓冲顶到上限：这正是开嗓前缓冲最坏的情况。
        XCTAssertEqual(gate.offer("        "), .buffered)
        XCTAssertEqual(gate.offer(" "), .buffered, "超限之后不再继续吞文本")
        XCTAssertEqual(gate.lastLimit, .pending(offered: 9, limit: 8))
        XCTAssertFalse(gate.isStarted)
    }
}
