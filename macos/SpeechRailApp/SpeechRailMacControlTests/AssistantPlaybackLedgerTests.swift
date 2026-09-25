import XCTest
@testable import SpeechRailAppSupport

/// 播放预算与"整轮结束"判定的纯状态测试：不启动音频设备，不涉及可听延迟。
final class AssistantPlaybackLedgerTests: XCTestCase {
    func testReservationStaysWithinTheQueuedSampleBudget() {
        var ledger = AssistantPlaybackLedger()
        ledger.begin(generation: 3)

        XCTAssertTrue(ledger.reserve(samples: 12_000))
        XCTAssertEqual(ledger.queuedSamples, 12_000)
        XCTAssertTrue(ledger.reserve(samples: 12_000))
        XCTAssertFalse(ledger.reserve(samples: 1), "超过一秒的排队预算必须被拒绝")
        XCTAssertEqual(ledger.queuedSamples, 24_000)
    }

    func testCompletionFromAStaleGenerationIsIgnored() {
        var ledger = AssistantPlaybackLedger()
        ledger.begin(generation: 4)
        XCTAssertTrue(ledger.reserve(samples: 480))

        XCTAssertFalse(ledger.complete(samples: 480, generation: 3))
        XCTAssertEqual(ledger.queuedSamples, 480, "旧代的 completion 不能清掉新一代的排队")

        XCTAssertTrue(ledger.complete(samples: 480, generation: 4))
        XCTAssertEqual(ledger.queuedSamples, 0)
    }

    func testTemporaryDrainIsNotAFinishedUtterance() {
        var ledger = AssistantPlaybackLedger()
        ledger.begin(generation: 1)
        XCTAssertTrue(ledger.reserve(samples: 240))
        XCTAssertFalse(ledger.isUtteranceFinished)

        XCTAssertTrue(ledger.complete(samples: 240, generation: 1))
        XCTAssertTrue(ledger.isDrained)
        XCTAssertFalse(ledger.isUtteranceFinished, "只是暂时排空：服务端还没给终态")

        XCTAssertTrue(ledger.markServerTerminal(status: "completed", generation: 1))
        XCTAssertTrue(ledger.isUtteranceFinished)
        XCTAssertEqual(ledger.terminalStatus, "completed")
    }

    func testServerTerminalBeforeDrainStillWaitsForPlayback() {
        var ledger = AssistantPlaybackLedger()
        ledger.begin(generation: 9)
        XCTAssertTrue(ledger.reserve(samples: 4_800))
        XCTAssertTrue(ledger.markServerTerminal(status: "completed", generation: 9))

        XCTAssertFalse(ledger.isUtteranceFinished)
        XCTAssertTrue(ledger.complete(samples: 4_800, generation: 9))
        XCTAssertTrue(ledger.isUtteranceFinished)
    }

    func testTerminalFromAnotherGenerationDoesNotApply() {
        var ledger = AssistantPlaybackLedger()
        ledger.begin(generation: 2)
        XCTAssertFalse(ledger.markServerTerminal(status: "completed", generation: 1))
        XCTAssertNil(ledger.terminalStatus)
    }

    func testInvalidateDropsQueuedSamplesAndAdvancesTheGeneration() {
        var ledger = AssistantPlaybackLedger()
        ledger.begin(generation: 5)
        XCTAssertTrue(ledger.reserve(samples: 1_000))
        ledger.markInputClosed()
        XCTAssertTrue(ledger.markServerTerminal(status: "completed", generation: 5))

        ledger.invalidate()
        XCTAssertEqual(ledger.generation, 6)
        XCTAssertEqual(ledger.queuedSamples, 0)
        XCTAssertFalse(ledger.serverTerminal)
        XCTAssertFalse(ledger.inputClosed)
    }
}
