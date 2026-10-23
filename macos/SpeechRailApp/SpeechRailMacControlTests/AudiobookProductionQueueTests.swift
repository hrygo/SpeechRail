import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// T17 队列回归：全部用 fake 执行器与隔离存储，不打开麦克风、不联网、不碰真实作品库。
final class AudiobookProductionQueueTests: XCTestCase {
    nonisolated(unsafe) private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiobookProductionQueueTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    // MARK: - Fakes

    private final class FixedClock: AudiobookClock, @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_700_000_000)

        func advance(seconds: TimeInterval) {
            lock.withLock { current = current.addingTimeInterval(seconds) }
        }

        func now() -> Date {
            lock.withLock { current }
        }

        func sleep(seconds: TimeInterval) async throws {}
    }

    /// 一道可以手动放开的闸门，用来把某一项压在「正在运行」状态里。
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var opened = false

        func wait() async {
            let alreadyOpen: Bool = lock.withLock { opened }
            if alreadyOpen { return }
            await withCheckedContinuation { continuation in
                let shouldResume: Bool = lock.withLock {
                    if opened { return true }
                    continuations.append(continuation)
                    return false
                }
                if shouldResume { continuation.resume() }
            }
        }

        func open() {
            let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
                opened = true
                let pending = continuations
                continuations = []
                return pending
            }
            pending.forEach { $0.resume() }
        }
    }

    private struct QueueFailure: LocalizedError, Equatable {
        var message: String
        var errorDescription: String? { message }
    }

    private final class FakeExecutor: AudiobookProductionQueueExecutor, @unchecked Sendable {
        private let lock = NSLock()
        private var records: [(itemID: UUID, bookID: UUID, continuesTaskID: UUID?)] = []
        private var active = 0
        private var maxActive = 0
        private var cancelRequests = 0

        var startedItemIDs: [UUID] { lock.withLock { records.map(\.itemID) } }
        var maxConcurrent: Int { lock.withLock { maxActive } }
        var cancelRequestCount: Int { lock.withLock { cancelRequests } }
        var failureByBook: [UUID: String] = [:]
        var unconfirmedStopByBook: Set<UUID> = []
        var gate: Gate?
        private var lastTaskID: UUID?

        func execute(_ request: AudiobookProductionQueueRequest) async throws -> AudiobookProductionQueueOutcome {
            let taskID = lock.withLock { () -> UUID in
                active += 1
                maxActive = max(maxActive, active)
                records.append((request.itemID, request.plan.bookID, request.continuesTaskID))
                lastTaskID = UUID()
                return lastTaskID!
            }
            defer { lock.withLock { active -= 1 } }

            if let gate { await gate.wait() }
            if let message = lock.withLock({ failureByBook[request.plan.bookID] }) {
                throw QueueFailure(message: message)
            }
            let unconfirmed = lock.withLock { unconfirmedStopByBook.contains(request.plan.bookID) }
            return AudiobookProductionQueueOutcome(
                taskID: taskID,
                completedFragments: request.plan.fragments.count,
                reusedFragments: 0,
                unconfirmedRemoteStopFragmentID: unconfirmed ? UUID() : nil
            )
        }

        func lastAttemptTaskID(for bookID: UUID) async -> UUID? {
            lock.withLock { lastTaskID }
        }

        func cancelActive() async {
            lock.withLock { cancelRequests += 1 }
        }

        func requests(for bookID: UUID) -> [(itemID: UUID, continuesTaskID: UUID?)] {
            lock.withLock { records.filter { $0.bookID == bookID }.map { ($0.itemID, $0.continuesTaskID) } }
        }
    }

    private final class FailAfterFirstSaveStore: AudiobookProductionQueuePersisting, @unchecked Sendable {
        private let lock = NSLock()
        private var saves = 0

        func load() throws -> AudiobookProductionQueuePlan? { nil }

        func save(_ plan: AudiobookProductionQueuePlan) throws {
            let count = lock.withLock { () -> Int in
                saves += 1
                return saves
            }
            if count > 1 { throw AudiobookProductionQueueStoreError.atomicWriteFailed }
        }
    }

    // MARK: - Helpers

    private func makePlan(bookID: UUID, chapterCount: Int = 1, fragmentsPerChapter: Int = 2) -> AudiobookProductionPlan {
        var fragments: [AudiobookFragment] = []
        for chapter in 0..<chapterCount {
            let chapterID = UUID()
            for ordinal in 0..<fragmentsPerChapter {
                fragments.append(AudiobookFragment(
                    bookID: bookID,
                    chapterID: chapterID,
                    ordinal: ordinal,
                    roleID: UUID(),
                    sourceRange: AudiobookSourceRange(lowerBound: Int64(ordinal * 10), upperBound: Int64(ordinal * 10 + 10)),
                    atomIDs: [],
                    localAssignmentDigest: "la",
                    voiceBindingDigest: "vb",
                    policyDigest: "pd",
                    dependencyDigest: "dep-\(chapter)-\(ordinal)"
                ))
            }
        }
        let chapterIDs = Array(Set(fragments.map(\.chapterID)))
        return AudiobookProductionPlan(
            id: UUID(),
            bookID: bookID,
            sourceID: UUID(),
            intent: .missingOnly,
            chapterIDs: chapterIDs,
            chapterTitles: Dictionary(uniqueKeysWithValues: chapterIDs.map { ($0, "章") }),
            fragments: fragments,
            preservedAudioCount: 0,
            preservedOutdatedAudioCount: 0,
            missingAudioCount: fragments.count
        )
    }

    private func makeQueue(
        executor: FakeExecutor,
        store: AudiobookProductionQueuePersisting,
        clock: FixedClock,
        restored: AudiobookProductionQueuePlan? = nil
    ) -> AudiobookProductionQueue {
        AudiobookProductionQueue(executor: executor, persistence: store, clock: clock, restoredPlan: restored)
    }

    /// actor 方法的抛错调用不能塞进 XCTAssert 的 autoclosure，单独包一层。
    private func assertQueueError(
        _ expected: AudiobookProductionQueueError,
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("期望 \(expected)，但调用没有抛错", file: file, line: line)
        } catch let error as AudiobookProductionQueueError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("期望 \(expected)，得到 \(error)", file: file, line: line)
        }
    }

    private func queueSnapshot(_ queue: AudiobookProductionQueue) async -> AudiobookProductionQueuePlan {
        await queue.snapshot()
    }

    /// 等队列真正停下。必须先确认循环跑起来再等它结束——否则第一次采样
    /// 可能什么都还没发生，后面的断言就会读到还没开始的状态。
    private func waitUntilQueueStops(_ queue: AudiobookProductionQueue, _ executor: FakeExecutor) async {
        for _ in 0..<400 {
            let snapshot = await queueSnapshot(queue)
            if snapshot.activeItem != nil { break }
            if executor.startedItemIDs.isEmpty, !snapshot.items.contains(where: { $0.state == .queued }) { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        for _ in 0..<800 {
            if (await queueSnapshot(queue)).activeItem == nil { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - 顺序、去重与执行身份

    func testThreeReadyBooksFinishInConfirmedOrder() async throws {
        let executor = FakeExecutor()
        let store = try AudiobookProductionQueueFileStore(rootURL: tempRoot)
        let queue = makeQueue(executor: executor, store: store, clock: FixedClock())

        let books = (0..<3).map { _ in UUID() }
        for (index, book) in books.enumerated() {
            try await queue.enqueue(bookID: book, title: "作品\(index + 1)", plan: makePlan(bookID: book))
        }
        await waitUntilQueueStops(queue, executor)

        let snapshot = await queue.snapshot()
        XCTAssertEqual(executor.startedItemIDs, snapshot.items.map(\.id))
        XCTAssertEqual(snapshot.items.map(\.state), [.completed, .completed, .completed])
        XCTAssertEqual(snapshot.items.map(\.bookID), books)
        // 一次只跑一项，不存在第二个执行身份。
        XCTAssertEqual(executor.maxConcurrent, 1)
    }

    func testReorderingQueuedItemsChangesTheConfirmedOrder() async throws {
        let executor = FakeExecutor()
        executor.gate = Gate()
        let store = try AudiobookProductionQueueFileStore(rootURL: tempRoot)
        let queue = makeQueue(executor: executor, store: store, clock: FixedClock())

        let first = UUID(), second = UUID(), third = UUID()
        try await queue.enqueue(bookID: first, title: "一", plan: makePlan(bookID: first))
        // 第一项被闸门压在运行中，后两项才排得到它后面。
        try await Task.sleep(for: .milliseconds(50))
        try await queue.enqueue(bookID: second, title: "二", plan: makePlan(bookID: second))
        try await queue.enqueue(bookID: third, title: "三", plan: makePlan(bookID: third))

        let queuedIDs = (await queue.snapshot()).queuedItems.map(\.id)
        try await queue.reorder(queuedIDs: queuedIDs.reversed())
        executor.gate?.open()
        await waitUntilQueueStops(queue, executor)

        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.items.map(\.state), [.completed, .completed, .completed])
        XCTAssertEqual(snapshot.items[1].bookID, third)
        XCTAssertEqual(snapshot.items[2].bookID, second)
    }

    func testReorderRefusesAnythingThatIsNotTheFullQueuedSet() async throws {
        let executor = FakeExecutor()
        let store = try AudiobookProductionQueueFileStore(rootURL: tempRoot)
        let queue = makeQueue(executor: executor, store: store, clock: FixedClock())
        let a = UUID(), b = UUID()
        try await queue.enqueue(bookID: a, title: "a", plan: makePlan(bookID: a))
        try await queue.enqueue(bookID: b, title: "b", plan: makePlan(bookID: b))
        let queued = (await queue.snapshot()).queuedItems.map(\.id)

        await assertQueueError(.reorderMismatch) { try await queue.reorder(queuedIDs: [queued[0]]) }
        await assertQueueError(.reorderMismatch) { try await queue.reorder(queuedIDs: queued + [UUID()]) }
        await waitUntilQueueStops(queue, executor)
    }

    func testAFinishedBookCanBeEnqueuedAgainButALiveOneCannot() async throws {
        let executor = FakeExecutor()
        let store = try AudiobookProductionQueueFileStore(rootURL: tempRoot)
        let queue = makeQueue(executor: executor, store: store, clock: FixedClock())

        let book = UUID()
        try await queue.enqueue(bookID: book, title: "一", plan: makePlan(bookID: book))
        await waitUntilQueueStops(queue, executor)
        // 已完成不再占名额，重新确认一份新范围可以入队。
        try await queue.enqueue(bookID: book, title: "一（重做）", plan: makePlan(bookID: book))
        await waitUntilQueueStops(queue, executor)
        let probe1 = await queueSnapshot(queue)
        XCTAssertEqual(probe1.items.count, 2)
        let probe2 = await queueSnapshot(queue)
        XCTAssertEqual(probe2.items.map(\.state), [.completed, .completed])
    }

    func testDuplicateEnqueueWhileAnItemIsLiveIsRefused() async throws {
        let executor = FakeExecutor()
        executor.gate = Gate()
        let store = try AudiobookProductionQueueFileStore(rootURL: tempRoot)
        let queue = makeQueue(executor: executor, store: store, clock: FixedClock())

        let book = UUID()
        try await queue.enqueue(bookID: book, title: "忙", plan: makePlan(bookID: book))
        try await Task.sleep(for: .milliseconds(50))
        do {
            try await queue.enqueue(bookID: book, title: "重复", plan: makePlan(bookID: book))
            XCTFail("未结束的同一部作品不应允许重复入队")
        } catch let error as AudiobookProductionQueueError {
            XCTAssertEqual(error, .duplicateBook)
        }
        executor.gate?.open()
        await waitUntilQueueStops(queue, executor)
        let probe3 = await queueSnapshot(queue)
        XCTAssertEqual(probe3.items.count, 1)
    }

    func testNoTwoItemsEverExecuteAtTheSameTime() async throws {
        let executor = FakeExecutor()
        let store = try AudiobookProductionQueueFileStore(rootURL: tempRoot)
        let queue = makeQueue(executor: executor, store: store, clock: FixedClock())
        for index in 0..<5 {
            let book = UUID()
            try await queue.enqueue(bookID: book, title: "作品\(index)", plan: makePlan(bookID: book))
        }
        await waitUntilQueueStops(queue, executor)
        XCTAssertEqual(executor.maxConcurrent, 1)
        XCTAssertEqual(executor.startedItemIDs.count, 5)
    }

    // MARK: - 失败、取消与停止屏障

    func testSecondFailureKeepsTheFirstOutputAndStopsTheQueue() async throws {
        let executor = FakeExecutor()
        let store = try AudiobookProductionQueueFileStore(rootURL: tempRoot)
        let queue = makeQueue(executor: executor, store: store, clock: FixedClock())

        let first = UUID(), second = UUID(), third = UUID()
        executor.failureByBook[second] = "语音服务返回 503"
        try await queue.enqueue(bookID: first, title: "一", plan: makePlan(bookID: first))
        try await queue.enqueue(bookID: second, title: "二", plan: makePlan(bookID: second))
        try await queue.enqueue(bookID: third, title: "三", plan: makePlan(bookID: third))
        await waitUntilQueueStops(queue, executor)

        let snapshot = await queue.snapshot()
        // 第一项产物保留，第二项带原因失败，第三项原样等待。
        XCTAssertEqual(snapshot.items[0].state, .completed)
        XCTAssertEqual(snapshot.items[1].state, .failed)
        XCTAssertEqual(snapshot.items[1].failureReason, "语音服务返回 503")
        XCTAssertEqual(snapshot.items[2].state, .queued)
        XCTAssertEqual(executor.startedItemIDs.count, 2)
    }

    func testRetryingAFailedItemContinuesTheSameRunInsteadOfRestartingIt() async throws {
        let executor = FakeExecutor()
        let store = try AudiobookProductionQueueFileStore(rootURL: tempRoot)
        let queue = makeQueue(executor: executor, store: store, clock: FixedClock())

        let book = UUID()
        executor.failureByBook[book] = "磁盘写入失败"
        try await queue.enqueue(bookID: book, title: "一", plan: makePlan(bookID: book))
        await waitUntilQueueStops(queue, executor)
        let probe1 = await queueSnapshot(queue)
        XCTAssertEqual(probe1.items[0].state, .failed)
        let firstTaskID = (await queue.snapshot()).items[0].lastTaskID
        XCTAssertNotNil(firstTaskID)

        executor.failureByBook.removeAll()
        try await queue.retryFailedItems()
        await waitUntilQueueStops(queue, executor)

        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.items[0].state, .completed)
        // 重试必须带着上一次的任务身份，执行器才能复用已提交片段。
        let requests = executor.requests(for: book)
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[0].continuesTaskID)
        XCTAssertEqual(requests[1].continuesTaskID, firstTaskID)
    }

    func testRetryWithoutAnyFailureIsRefused() async throws {
        let executor = FakeExecutor()
        let store = try AudiobookProductionQueueFileStore(rootURL: tempRoot)
        let queue = makeQueue(executor: executor, store: store, clock: FixedClock())
        await assertQueueError(.nothingToRetry) { try await queue.retryFailedItems() }
    }

    func testPauseWaitsForTheActiveWrapUpBeforeAnythingElseStarts() async throws {
        let executor = FakeExecutor()
        executor.gate = Gate()
        let store = try AudiobookProductionQueueFileStore(rootURL: tempRoot)
        let queue = makeQueue(executor: executor, store: store, clock: FixedClock())

        let first = UUID(), second = UUID()
        try await queue.enqueue(bookID: first, title: "一", plan: makePlan(bookID: first))
        try await Task.sleep(for: .milliseconds(50))
        try await queue.enqueue(bookID: second, title: "二", plan: makePlan(bookID: second))

        let pauseTask = Task { try? await queue.pause() }
        // 等 pause 真正发出停止请求。
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(executor.cancelRequestCount, 1)
        // 闸门还没开：第二项不许开始。
        XCTAssertEqual(executor.startedItemIDs.count, 1)

        executor.gate?.open()
        try await pauseTask.value
        await waitUntilQueueStops(queue, executor)

        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.items[0].state, .paused)
        XCTAssertEqual(snapshot.items[0].failureReason, "已取消。")
        // 队列停在第一项，第二项仍在等，没有悄悄做完。
        XCTAssertEqual(snapshot.items[1].state, .queued)
        XCTAssertEqual(executor.startedItemIDs.count, 1)

        // 明确恢复后才继续：暂停是整队动作，继续也是——第一项回到未开始接着做，
        // 然后才轮到第二项。
        try await queue.resume()
        await waitUntilQueueStops(queue, executor)
        let probe2 = await queueSnapshot(queue)
        XCTAssertEqual(probe2.items[0].state, .completed)
        XCTAssertEqual(probe2.items[1].state, .completed)
        XCTAssertEqual(executor.startedItemIDs.count, 3)
    }

    func testAnUnconfirmedRemoteStopRefusesToStartTheNextItem() async throws {
        let executor = FakeExecutor()
        let store = try AudiobookProductionQueueFileStore(rootURL: tempRoot)
        let queue = makeQueue(executor: executor, store: store, clock: FixedClock())

        let first = UUID(), second = UUID()
        executor.unconfirmedStopByBook = [first]
        try await queue.enqueue(bookID: first, title: "一", plan: makePlan(bookID: first))
        try await queue.enqueue(bookID: second, title: "二", plan: makePlan(bookID: second))
        await waitUntilQueueStops(queue, executor)

        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.items[0].state, .paused)
        XCTAssertEqual(snapshot.items[0].failureReason, "在途片段的停止状态尚未确认，继续前请先核对。")
        XCTAssertEqual(snapshot.items[1].state, .queued)
        XCTAssertEqual(executor.startedItemIDs.count, 1)
        let probe3 = await queue.isQueuePaused()
        XCTAssertTrue(probe3)
    }

    func testCancellingTheRunningItemNeverClaimsCompletion() async throws {
        let executor = FakeExecutor()
        executor.gate = Gate()
        let store = try AudiobookProductionQueueFileStore(rootURL: tempRoot)
        let queue = makeQueue(executor: executor, store: store, clock: FixedClock())

        let book = UUID()
        try await queue.enqueue(bookID: book, title: "一", plan: makePlan(bookID: book))
        try await Task.sleep(for: .milliseconds(50))
        let itemID = (await queue.snapshot()).items[0].id

        let cancelTask = Task { try? await queue.cancelItem(itemID: itemID) }
        try await Task.sleep(for: .milliseconds(50))
        executor.gate?.open()
        try await cancelTask.value

        let snapshot = await queue.snapshot()
        // 取消的项不冒充完成，也不留在队列里占位：已提交片段在作品库里，
        // 重新入队会从检查点继续。
        XCTAssertEqual(snapshot.items.count, 0)
        let probe4 = await queue.activeQueueItemID()
        XCTAssertNil(probe4)

        // 离开队列意味着这部作品可以重新入队，不会被 duplicateBook 永久挡着。
        try await queue.enqueue(bookID: book, title: "一", plan: makePlan(bookID: book))
    }

    func testCancellingAQueuedItemRemovesItFromTheQueue() async throws {
        let executor = FakeExecutor()
        executor.gate = Gate()
        let store = try AudiobookProductionQueueFileStore(rootURL: tempRoot)
        let queue = makeQueue(executor: executor, store: store, clock: FixedClock())

        let first = UUID(), second = UUID()
        try await queue.enqueue(bookID: first, title: "一", plan: makePlan(bookID: first))
        try await Task.sleep(for: .milliseconds(50))
        try await queue.enqueue(bookID: second, title: "二", plan: makePlan(bookID: second))
        let queuedID = (await queue.snapshot()).queuedItems[0].id

        try await queue.cancelItem(itemID: queuedID)
        var snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items[0].bookID, first)

        executor.gate?.open()
        await waitUntilQueueStops(queue, executor)
        snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.items[0].state, .completed)
    }

    func testCancellingSomethingThatIsNotRunningIsRefused() async throws {
        let executor = FakeExecutor()
        let store = try AudiobookProductionQueueFileStore(rootURL: tempRoot)
        let queue = makeQueue(executor: executor, store: store, clock: FixedClock())
        let book = UUID()
        try await queue.enqueue(bookID: book, title: "一", plan: makePlan(bookID: book))
        await waitUntilQueueStops(queue, executor)
        let itemID = (await queue.snapshot()).items[0].id
        await assertQueueError(.itemNotActive(itemID)) { try await queue.cancelItem(itemID: itemID) }
    }

    // MARK: - 重启与持久化

    func testRestartMarksUnconfirmedTerminalsAsInterruptedAndDoesNotAutoStart() async throws {
        let executor = FakeExecutor()
        let store = try AudiobookProductionQueueFileStore(rootURL: tempRoot)
        let clock = FixedClock()

        let first = UUID(), second = UUID()
        let runningPlan = makePlan(bookID: first)
        let restored = AudiobookProductionQueuePlan(items: [
            AudiobookProductionQueueItem(bookID: first, title: "一", plan: runningPlan, state: .running, startedAt: clock.now()),
            AudiobookProductionQueueItem(bookID: second, title: "二", plan: makePlan(bookID: second), state: .queued),
            AudiobookProductionQueueItem(bookID: UUID(), title: "三", plan: makePlan(bookID: UUID()), state: .completed),
        ])
        let queue = makeQueue(executor: executor, store: store, clock: clock, restored: restored)

        // 打开 App 不得自行开始制作。
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(executor.startedItemIDs.count, 0)
        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.items[0].state, .interrupted)
        XCTAssertEqual(snapshot.items[0].failureReason, "App 上次退出时这一项还在制作，终态尚未确认。请核对后再继续。")
        XCTAssertEqual(snapshot.items[1].state, .queued)
        XCTAssertEqual(snapshot.items[2].state, .completed)
        XCTAssertEqual(snapshot.interruptedItems.count, 1)
    }

    func testConfirmingAnInterruptedItemLetsItContinue() async throws {
        let executor = FakeExecutor()
        let store = try AudiobookProductionQueueFileStore(rootURL: tempRoot)
        let clock = FixedClock()

        let book = UUID()
        let restored = AudiobookProductionQueuePlan(items: [
            AudiobookProductionQueueItem(bookID: book, title: "一", plan: makePlan(bookID: book), state: .running, startedAt: clock.now(), lastTaskID: UUID()),
        ])
        let queue = makeQueue(executor: executor, store: store, clock: clock, restored: restored)
        let itemID = (await queue.snapshot()).items[0].id
        let previousTaskID = (await queue.snapshot()).items[0].lastTaskID

        // 没确认前恢复整条队列也不该捡起这一项。
        await assertQueueError(.queueNotPaused) { try await queue.resume() }
        try await queue.confirmInterrupted(itemID: itemID)
        await waitUntilQueueStops(queue, executor)

        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.items[0].state, .completed)
        // 续跑带着原来的任务身份，已提交片段被复用。
        XCTAssertEqual(executor.requests(for: book)[0].continuesTaskID, previousTaskID)
    }

    func testConfirmingSomethingThatIsNotInterruptedIsRefused() async throws {
        let executor = FakeExecutor()
        let store = try AudiobookProductionQueueFileStore(rootURL: tempRoot)
        let queue = makeQueue(executor: executor, store: store, clock: FixedClock())
        let book = UUID()
        try await queue.enqueue(bookID: book, title: "一", plan: makePlan(bookID: book))
        let itemID = (await queue.snapshot()).items[0].id
        await assertQueueError(.itemNotInterrupted(itemID)) { try await queue.confirmInterrupted(itemID: itemID) }
        await waitUntilQueueStops(queue, executor)
    }

    func testPlanRoundTripsThroughTheFileStore() throws {
        let store = try AudiobookProductionQueueFileStore(rootURL: tempRoot)
        let book = UUID()
        let plan = AudiobookProductionQueuePlan(items: [
            AudiobookProductionQueueItem(bookID: book, title: "一", plan: makePlan(bookID: book), state: .completed, lastTaskID: UUID()),
        ])
        try store.save(plan)
        let loaded = try store.load()
        XCTAssertEqual(loaded, plan)
    }

    func testAMissingFileLoadsAsAnEmptyQueueRatherThanAnError() throws {
        let store = try AudiobookProductionQueueFileStore(rootURL: tempRoot)
        XCTAssertNil(try store.load())
    }

    func testACorruptPlanFileIsRefusedInsteadOfBeingSilentlyDropped() throws {
        let store = try AudiobookProductionQueueFileStore(rootURL: tempRoot)
        let file = tempRoot.appendingPathComponent("production-queue.json")
        try Data("not a plan".utf8).write(to: file)
        XCTAssertThrowsError(try store.load()) { error in
            guard case AudiobookProductionQueueStoreError.unreadable = error else {
                return XCTFail("期望 unreadable，得到 \(error)")
            }
        }
    }

    func testAnUnknownSchemaIsRefusedWithoutTouchingTheFile() throws {
        let store = try AudiobookProductionQueueFileStore(rootURL: tempRoot)
        let file = tempRoot.appendingPathComponent("production-queue.json")
        let original = Data("""
        {"schema":"audiobook_production_queue_v99","items":[],"updatedAt":0}
        """.utf8)
        try original.write(to: file)
        XCTAssertThrowsError(try store.load()) { error in
            guard case let AudiobookProductionQueueStoreError.unsupportedSchema(schema) = error else {
                return XCTFail("期望 unsupportedSchema，得到 \(error)")
            }
            XCTAssertEqual(schema, "audiobook_production_queue_v99")
        }
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testAFailedSaveLeavesThePreviousPlanIntact() throws {
        let store = try AudiobookProductionQueueFileStore(rootURL: tempRoot)
        let book = UUID()
        let first = AudiobookProductionQueuePlan(items: [
            AudiobookProductionQueueItem(bookID: book, title: "一", plan: makePlan(bookID: book)),
        ])
        try store.save(first)

        // 把父路径换成一个普通文件：createDirectory 与 replaceItemAt 都会失败。
        let blocked = tempRoot.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocked)
        let blockedStore = AudiobookProductionQueueFileStore(rootURL: blocked)
        XCTAssertThrowsError(try blockedStore.save(first)) { error in
            guard case AudiobookProductionQueueStoreError.atomicWriteFailed = error else {
                return XCTFail("期望 atomicWriteFailed，得到 \(error)")
            }
        }
        // 第一份计划完整保留，没有被半份写坏。
        XCTAssertEqual(try store.load(), first)
    }

    func testAPersistenceFailureDoesNotStopTheRunOrFakeCompletion() async throws {
        // 只在第一次保存之后失败：入队本身能落地，运行中途的存盘失败不该
        // 把已经在做的那一项说成失败，也不该把它冒充成完成。
        let store = FailAfterFirstSaveStore()
        let executor = FakeExecutor()
        let clock = FixedClock()
        let book = UUID()
        let restored = AudiobookProductionQueuePlan(items: [
            AudiobookProductionQueueItem(bookID: book, title: "一", plan: makePlan(bookID: book)),
        ])
        let queue = makeQueue(executor: executor, store: store, clock: clock, restored: restored)

        try await queue.start()
        await waitUntilQueueStops(queue, executor)

        let snapshot = await queueSnapshot(queue)
        XCTAssertEqual(snapshot.items[0].state, .completed)
        XCTAssertEqual(executor.startedItemIDs.count, 1)
    }

    func testShutdownLeavesNoItemClaimingToRun() async throws {
        let executor = FakeExecutor()
        executor.gate = Gate()
        let store = try AudiobookProductionQueueFileStore(rootURL: tempRoot)
        let queue = makeQueue(executor: executor, store: store, clock: FixedClock())

        let book = UUID()
        try await queue.enqueue(bookID: book, title: "一", plan: makePlan(bookID: book))
        try await Task.sleep(for: .milliseconds(50))
        let shutdownTask = Task { await queue.shutdown() }
        try await Task.sleep(for: .milliseconds(50))
        executor.gate?.open()
        await shutdownTask.value

        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.items[0].state, .paused)
        let probe2 = await queue.activeQueueItemID()
        XCTAssertNil(probe2)
    }

    func testEnqueueingAnEmptyPreviewIsRefused() async throws {
        let executor = FakeExecutor()
        let store = try AudiobookProductionQueueFileStore(rootURL: tempRoot)
        let queue = makeQueue(executor: executor, store: store, clock: FixedClock())
        let book = UUID()
        let empty = AudiobookProductionPlan(
            id: UUID(), bookID: book, sourceID: UUID(), intent: .missingOnly,
            chapterIDs: [], chapterTitles: [:], fragments: [],
            preservedAudioCount: 0, preservedOutdatedAudioCount: 0, missingAudioCount: 0
        )
        await assertQueueError(.emptyPlan) { try await queue.enqueue(bookID: book, title: "空", plan: empty) }
        let other = UUID()
        await assertQueueError(.planBookMismatch) { try await queue.enqueue(bookID: other, title: "错配", plan: makePlan(bookID: book)) }
        let probe3 = await queueSnapshot(queue)
        XCTAssertEqual(probe3.items.count, 0)
    }

    func testStartingAnEmptyQueueIsRefused() async throws {
        let executor = FakeExecutor()
        let store = try AudiobookProductionQueueFileStore(rootURL: tempRoot)
        let queue = makeQueue(executor: executor, store: store, clock: FixedClock())
        await assertQueueError(.emptyPlan) { try await queue.start() }
    }
}
