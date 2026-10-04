import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

@MainActor
final class AssistantInputPersistenceQueueTests: XCTestCase {
    func testKeyboardAndMicrophoneInputsShareQueueOrderAndWaitForProjection() async {
        var savedLineIDs: [String] = []
        var savedSources: [SessionLineSource] = []
        var savedTStarts: [TimeInterval?] = []
        var projectedLineIDs: [String] = []
        let queue = AssistantInputPersistenceQueue(
            save: { command in
                savedLineIDs.append(command.lineID)
                savedSources.append(command.source)
                savedTStarts.append(command.tStart)
                return savedLineIDs.count
            },
            didSave: { command, _ in
                projectedLineIDs.append(command.lineID)
            }
        )
        let microphone = AssistantInputPersistenceQueue.Command(
            sessionID: "record",
            connection: 1,
            itemID: "asr-item",
            lineID: "asr-line",
            text: "语音先到",
            formal: true,
            observedAt: observedAt
        )
        let keyboard = AssistantInputPersistenceQueue.Command(
            sessionID: "record",
            connection: 1,
            itemID: "",
            lineID: "typed-line",
            text: "键盘后到",
            source: .keyboard,
            tStart: 3.5,
            formal: true,
            observedAt: observedAt
        )

        XCTAssertEqual(microphone.source, .microphone, "省略 source 时沿用 ASR 的默认来源")
        XCTAssertEqual(keyboard.source, .keyboard)
        XCTAssertEqual(queue.enqueue(microphone), .accepted)
        XCTAssertEqual(queue.enqueue(keyboard), .accepted)

        let result = await queue.waitForResult(lineID: keyboard.lineID)

        XCTAssertEqual(result, .saved(ordinal: 2))
        XCTAssertEqual(savedLineIDs, ["asr-line", "typed-line"])
        XCTAssertEqual(projectedLineIDs, ["asr-line", "typed-line"], "保存结果要等成功投影完成后才释放")
        XCTAssertEqual(savedSources, [.microphone, .keyboard])
        XCTAssertEqual(savedTStarts, [nil, 3.5], "源与相对时间必须随接纳命令固定")
        let microphoneResult = await queue.waitForResult(lineID: microphone.lineID)
        if case .saved = microphoneResult {
            XCTFail("没有等待者的 ASR 命令不应长期保留 SaveResult")
        }
    }

    func testKeyboardResultCanBeConsumedAfterSaveAndIsRemovedAfterConsumption() async {
        var didSaveLineIDs: [String] = []
        let queue = AssistantInputPersistenceQueue(
            save: { _ in 7 },
            didSave: { command, _ in
                didSaveLineIDs.append(command.lineID)
            }
        )
        let keyboard = command(
            sessionID: "record",
            connection: 1,
            itemID: "",
            lineID: "keyboard-line",
            source: .keyboard
        )
        XCTAssertEqual(queue.enqueue(keyboard), .accepted)

        let report = await queue.waitUntilSettled(sessionID: keyboard.sessionID)
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(didSaveLineIDs, [keyboard.lineID])
        let savedResult = await queue.waitForResult(lineID: keyboard.lineID)
        XCTAssertEqual(savedResult, .saved(ordinal: 7))

        let consumedAgain = await queue.waitForResult(lineID: keyboard.lineID)
        if case .saved = consumedAgain {
            XCTFail("SaveResult 消费后应移除")
        }
    }

    func testSaveFailureReturnsToWaiterKeepsCommandAndRetryReturnsSameLine() async {
        enum SaveError: Error {
            case unavailable
        }

        var attemptedCommands: [AssistantInputPersistenceQueue.Command] = []
        var didSaveLineIDs: [String] = []
        let queue = AssistantInputPersistenceQueue(
            save: { command in
                attemptedCommands.append(command)
                if attemptedCommands.count == 1 { throw SaveError.unavailable }
                return 9
            },
            didSave: { command, _ in
                didSaveLineIDs.append(command.lineID)
            }
        )
        let keyboard = command(
            sessionID: "record",
            connection: 1,
            itemID: "",
            lineID: "keyboard-failed",
            source: .keyboard
        )
        XCTAssertEqual(queue.enqueue(keyboard), .accepted)

        let failedResult = await queue.waitForResult(lineID: keyboard.lineID)
        guard case .failed(let failureMessage) = failedResult else {
            XCTFail("保存失败必须通知 keyboard waiter")
            return
        }
        XCTAssertFalse(failureMessage.isEmpty)
        XCTAssertEqual(queue.failures(sessionID: keyboard.sessionID).map(\.command.lineID), [keyboard.lineID])
        XCTAssertEqual(queue.outstandingCommandCount, 1, "失败命令需保留以便恢复")

        XCTAssertTrue(queue.retry(sessionID: keyboard.sessionID, lineID: keyboard.lineID))
        let retriedResult = await queue.waitForResult(lineID: keyboard.lineID)

        XCTAssertEqual(retriedResult, .saved(ordinal: 9))
        XCTAssertEqual(attemptedCommands, [keyboard, keyboard], "重试必须重用固定正文、来源、时间和 lineID")
        XCTAssertEqual(didSaveLineIDs, [keyboard.lineID])
        XCTAssertEqual(queue.outstandingCommandCount, 0)
    }

    func testPredecessorFailureReleasesLaterKeyboardWaiterAndRetryKeepsOrder() async {
        enum SaveError: Error {
            case unavailable
        }

        let gate = SaveGate()
        var attemptedLineIDs: [String] = []
        var didSaveLineIDs: [String] = []
        let queue = AssistantInputPersistenceQueue(
            save: { command in
                attemptedLineIDs.append(command.lineID)
                if command.lineID == "earlier-line",
                   attemptedLineIDs.filter({ $0 == "earlier-line" }).count == 1
                {
                    _ = await gate.wait()
                    throw SaveError.unavailable
                }
                return attemptedLineIDs.count
            },
            didSave: { command, _ in
                didSaveLineIDs.append(command.lineID)
            }
        )
        let earlier = command(
            sessionID: "record",
            connection: 1,
            itemID: "asr-earlier",
            lineID: "earlier-line"
        )
        let keyboard = command(
            sessionID: "record",
            connection: 1,
            itemID: "",
            lineID: "keyboard-after-earlier",
            source: .keyboard
        )
        XCTAssertEqual(queue.enqueue(earlier), .accepted)
        XCTAssertEqual(queue.enqueue(keyboard), .accepted)

        var waiterStarted = false
        let waiter = Task { @MainActor in
            waiterStarted = true
            return await queue.waitForResult(lineID: keyboard.lineID)
        }
        await gate.waitUntilEntered()
        var didStartWaiter = false
        for _ in 0..<200 {
            if waiterStarted {
                didStartWaiter = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(didStartWaiter, "前序失败前应先启动 keyboard waiter")
        gate.release(ordinal: 1)
        let result = await resultWithin(waiter)

        XCTAssertEqual(result, .some(.blocked(byLineID: earlier.lineID)))
        XCTAssertEqual(queue.failures(sessionID: earlier.sessionID).map(\.command.lineID), [earlier.lineID])
        XCTAssertEqual(queue.pendingCommands(sessionID: keyboard.sessionID).map(\.lineID), [keyboard.lineID])
        XCTAssertEqual(attemptedLineIDs, [earlier.lineID], "失败前序未恢复时不能保存后续行")

        XCTAssertTrue(queue.retry(sessionID: earlier.sessionID, lineID: earlier.lineID))
        let report = await queue.waitUntilSettled(sessionID: earlier.sessionID)

        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(attemptedLineIDs, [earlier.lineID, earlier.lineID, keyboard.lineID])
        XCTAssertEqual(didSaveLineIDs, [earlier.lineID, keyboard.lineID])
        let consumedBlockedResult = await queue.waitForResult(lineID: keyboard.lineID)
        if case .saved = consumedBlockedResult {
            XCTFail("blocked 结果消费后不得在后续保存时再保留一份结果")
        }
    }

    func testWaitForResultImmediatelyReportsAnExistingFailedPredecessor() async {
        enum SaveError: Error {
            case unavailable
        }

        var attemptedLineIDs: [String] = []
        let queue = AssistantInputPersistenceQueue(
            save: { command in
                attemptedLineIDs.append(command.lineID)
                if command.lineID == "failed-before-enqueue" && attemptedLineIDs.count == 1 {
                    throw SaveError.unavailable
                }
                return attemptedLineIDs.count
            },
            didSave: { _, _ in }
        )
        let earlier = command(
            sessionID: "record",
            connection: 1,
            itemID: "asr-failed",
            lineID: "failed-before-enqueue"
        )
        XCTAssertEqual(queue.enqueue(earlier), .accepted)
        let failedReport = await queue.waitUntilSettled(sessionID: earlier.sessionID)
        XCTAssertEqual(failedReport.failures.map(\.command.lineID), [earlier.lineID])

        let keyboard = command(
            sessionID: earlier.sessionID,
            connection: 1,
            itemID: "",
            lineID: "keyboard-after-known-failure",
            source: .keyboard
        )
        XCTAssertEqual(queue.enqueue(keyboard), .accepted)
        let waiter = Task { @MainActor in
            await queue.waitForResult(lineID: keyboard.lineID)
        }
        let result = await resultWithin(waiter)

        XCTAssertEqual(result, .some(.blocked(byLineID: earlier.lineID)))
        XCTAssertEqual(queue.pendingCommands(sessionID: keyboard.sessionID).map(\.lineID), [keyboard.lineID])
        XCTAssertTrue(queue.retry(sessionID: earlier.sessionID, lineID: earlier.lineID))
        let report = await queue.waitUntilSettled(sessionID: earlier.sessionID)
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(attemptedLineIDs, [earlier.lineID, earlier.lineID, keyboard.lineID])
    }

    func testCancelledResultWaiterDoesNotCancelAcceptedSaveOrRetainResult() async {
        let gate = SaveGate()
        let queue = AssistantInputPersistenceQueue(
            save: { _ in await gate.wait() },
            didSave: { _, _ in }
        )
        let keyboard = command(
            sessionID: "record",
            connection: 1,
            itemID: "",
            lineID: "keyboard-cancelled-waiter",
            source: .keyboard
        )
        XCTAssertEqual(queue.enqueue(keyboard), .accepted)

        let waiter = Task { @MainActor in
            await queue.waitForResult(lineID: keyboard.lineID)
        }
        await gate.waitUntilEntered()
        waiter.cancel()
        let cancelledResult = await waiter.value
        guard case .failed = cancelledResult else {
            XCTFail("取消等待应结束 waiter")
            return
        }

        gate.release(ordinal: 11)
        let report = await queue.waitUntilSettled(sessionID: keyboard.sessionID)
        XCTAssertTrue(report.isComplete, "取消 waiter 不得取消已接纳的保存")
        let abandonedResult = await queue.waitForResult(lineID: keyboard.lineID)
        if case .saved = abandonedResult {
            XCTFail("取消后的键盘 waiter 不应留下无人消费的结果")
        }
    }

    func testAcceptedCommandsSaveInOrderAndProjectReturnedOrdinals() async {
        var savedLineIDs: [String] = []
        var projectedLineIDs: [String] = []
        var projectedOrdinals: [Int] = []
        let queue = AssistantInputPersistenceQueue(
            save: { command in
                savedLineIDs.append(command.lineID)
                return savedLineIDs.count
            },
            didSave: { command, ordinal in
                projectedLineIDs.append(command.lineID)
                projectedOrdinals.append(ordinal)
            }
        )

        let accepted = [
            queue.enqueue(command(sessionID: "record", connection: 1, itemID: "one", lineID: "line-1", text: "第一句")),
            queue.enqueue(command(sessionID: "record", connection: 1, itemID: "two", lineID: "line-2", text: "第二句")),
            queue.enqueue(command(sessionID: "record", connection: 1, itemID: "three", lineID: "line-3", text: "第三句"))
        ]
        XCTAssertEqual(accepted, [.accepted, .accepted, .accepted])

        let report = await queue.waitUntilSettled(sessionID: "record")

        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(savedLineIDs, ["line-1", "line-2", "line-3"])
        XCTAssertEqual(projectedLineIDs, ["line-1", "line-2", "line-3"])
        XCTAssertEqual(projectedOrdinals, [1, 2, 3], "投影必须使用 Store 返回的 ordinal")
        XCTAssertEqual(queue.outstandingCommandCount, 0)
        XCTAssertEqual(queue.outstandingTextScalarCount, 0)
    }

    func testDuplicateItemsAreConnectionScopedAndMissingItemIDsGetUniqueAcceptances() async {
        var savedLineIDs: [String] = []
        let queue = AssistantInputPersistenceQueue(
            save: { command in
                savedLineIDs.append(command.lineID)
                return savedLineIDs.count
            },
            didSave: { _, _ in }
        )
        let first = command(sessionID: "record", connection: 7, itemID: "same", lineID: "line-old")
        let duplicate = command(sessionID: "record", connection: 7, itemID: "same", lineID: "line-duplicate")
        let reconnected = command(sessionID: "record", connection: 8, itemID: "same", lineID: "line-new")
        let missingID1 = command(sessionID: "record", connection: 8, itemID: "", lineID: "line-empty-1")
        let missingID2 = command(sessionID: "record", connection: 8, itemID: "", lineID: "line-empty-2")

        XCTAssertEqual(queue.enqueue(first), .accepted)
        XCTAssertEqual(queue.enqueue(duplicate), .duplicate(existingLineID: "line-old"))
        XCTAssertEqual(queue.enqueue(reconnected), .accepted)
        XCTAssertEqual(queue.enqueue(missingID1), .accepted)
        XCTAssertEqual(queue.enqueue(missingID2), .accepted)
        XCTAssertNotEqual(missingID1.acceptanceID, missingID2.acceptanceID)

        let report = await queue.waitUntilSettled(sessionID: "record")

        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(savedLineIDs, ["line-old", "line-new", "line-empty-1", "line-empty-2"])
    }

    func testFailureRetainsCapacityAndBlocksOnlyItsRecordUntilExplicitRetry() async {
        enum SaveError: Error {
            case unavailable
        }

        var shouldFailFirstRecord = true
        var attemptedLineIDs: [String] = []
        var savedLineIDs: [String] = []
        let queue = AssistantInputPersistenceQueue(
            configuration: .init(
                maximumPendingCommands: 4,
                maximumPendingTextScalars: 4
            ),
            save: { command in
                attemptedLineIDs.append(command.lineID)
                if command.sessionID == "record-a",
                   command.lineID == "a-1",
                   shouldFailFirstRecord
                {
                    shouldFailFirstRecord = false
                    throw SaveError.unavailable
                }
                savedLineIDs.append(command.lineID)
                return savedLineIDs.count
            },
            didSave: { _, _ in }
        )

        let firstA = command(sessionID: "record-a", connection: 1, itemID: "a1", lineID: "a-1", text: "😀")
        let secondA = command(sessionID: "record-a", connection: 1, itemID: "a2", lineID: "a-2", text: "后续")
        let firstB = command(sessionID: "record-b", connection: 1, itemID: "b1", lineID: "b-1", text: "B")
        XCTAssertEqual(queue.enqueue(firstA), .accepted)
        XCTAssertEqual(queue.enqueue(secondA), .accepted)
        XCTAssertEqual(queue.enqueue(firstB), .accepted)

        let reportB = await queue.waitUntilSettled(sessionID: "record-b")
        XCTAssertTrue(reportB.isComplete, "另一个记录不应被失败队列永久阻塞")
        XCTAssertEqual(savedLineIDs, ["b-1"])

        let reportA = await queue.waitUntilSettled(sessionID: "record-a")
        XCTAssertEqual(reportA.failures.map(\.command.lineID), ["a-1"])
        XCTAssertEqual(reportA.pendingCommands.map(\.lineID), ["a-2"])
        XCTAssertEqual(queue.outstandingCommandCount, 2, "失败与后继命令都继续占用命令预算")
        XCTAssertEqual(queue.outstandingTextScalarCount, 3, "😀 按一个 Unicode scalar 计入预算")
        XCTAssertEqual(
            queue.enqueue(command(sessionID: "record-a", connection: 1, itemID: "a3", lineID: "a-3", text: "xy")),
            .capacityExceeded,
            "失败项仍占用正文预算"
        )

        XCTAssertTrue(queue.retry(sessionID: "record-a", lineID: "a-1"))
        let retriedReport = await queue.waitUntilSettled(sessionID: "record-a")

        XCTAssertTrue(retriedReport.isComplete)
        XCTAssertEqual(attemptedLineIDs, ["a-1", "b-1", "a-1", "a-2"])
        XCTAssertEqual(savedLineIDs, ["b-1", "a-1", "a-2"])
        XCTAssertFalse(queue.retry(sessionID: "record-a", lineID: "a-1"), "成功后不再存在可重试项")
    }

    func testPartialAndFormalFlagsAndObservationTimeReachTheSaveCallback() async {
        var savedCommands: [AssistantInputPersistenceQueue.Command] = []
        let queue = AssistantInputPersistenceQueue(
            save: { command in
                savedCommands.append(command)
                return savedCommands.count
            },
            didSave: { _, _ in }
        )
        let partial = command(
            sessionID: "record",
            connection: 1,
            itemID: "partial",
            lineID: "partial-line",
            text: "未定稿",
            formal: false
        )
        let formal = command(
            sessionID: "record",
            connection: 1,
            itemID: "formal",
            lineID: "formal-line",
            text: "已定稿",
            formal: true
        )
        XCTAssertEqual(queue.enqueue(partial), .accepted)
        XCTAssertEqual(queue.enqueue(formal), .accepted)
        let report = await queue.waitUntilSettled(sessionID: "record")

        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(savedCommands.map(\.formal), [false, true])
        XCTAssertEqual(savedCommands.map(\.observedAt), [observedAt, observedAt])
    }

    private var observedAt: Date {
        Date(timeIntervalSince1970: 1_791_081_600)
    }

    private func resultWithin(
        _ waiter: Task<AssistantInputPersistenceQueue.SaveResult, Never>,
        timeoutIterations: Int = 200
    ) async -> AssistantInputPersistenceQueue.SaveResult? {
        var observedResult: AssistantInputPersistenceQueue.SaveResult?
        let observer = Task { @MainActor in
            observedResult = await waiter.value
        }

        for _ in 0..<timeoutIterations {
            if let observedResult { return observedResult }
            await Task.yield()
        }

        waiter.cancel()
        for _ in 0..<20 {
            if let observedResult { return observedResult }
            await Task.yield()
        }
        observer.cancel()
        return nil
    }

    private func command(
        sessionID: String,
        connection: Int,
        itemID: String,
        lineID: String,
        text: String = "输入",
        formal: Bool = true,
        source: SessionLineSource = .microphone,
        tStart: TimeInterval? = nil
    ) -> AssistantInputPersistenceQueue.Command {
        AssistantInputPersistenceQueue.Command(
            sessionID: sessionID,
            connection: connection,
            itemID: itemID,
            acceptanceID: "accept-\(lineID)",
            lineID: lineID,
            text: text,
            source: source,
            tStart: tStart,
            formal: formal,
            observedAt: observedAt
        )
    }

    @MainActor
    private final class SaveGate {
        private var continuation: CheckedContinuation<Int, Never>?
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var entered = false

        func wait() async -> Int {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered = true
                for waiter in entryWaiters {
                    waiter.resume()
                }
                entryWaiters.removeAll()
            }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        func release(ordinal: Int) {
            continuation?.resume(returning: ordinal)
            continuation = nil
        }
    }
}
