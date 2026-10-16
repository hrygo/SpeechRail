import Foundation
import Synchronization
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

@Suite(.timeLimit(.minutes(1)))
struct LLMStreamDeliveryTests {
    @Test
    func testSlowConsumerOverflowPreservesFailure() async throws {
        let delivery = LLMStreamDelivery(maxEvents: 2, maxPayloadBytes: 100)
        try delivery.yield("甲")
        try delivery.yield("乙")
        #expect(throws: LLMError.self) { try delivery.yield("丙") }
        var prefix = "", failure: LLMError?
        do { for try await delta in delivery.stream { prefix += delta } }
        catch { failure = error as? LLMError }
        #expect(prefix == "甲乙")
        guard case .streamBudgetExceeded = failure else { Issue.record("Overflow must remain an error"); return }
        #expect(delivery.payloadBytes == 6)
    }

    @Test
    func testEmptyDeltaCannotBypassEventLimit() async throws {
        let delivery = LLMStreamDelivery(maxEvents: 2, maxPayloadBytes: 0)
        try delivery.yield("")
        try delivery.yield("")
        #expect(throws: LLMError.self) { try delivery.yield("") }
        var count = 0, failed = false
        do { for try await _ in delivery.stream { count += 1 } }
        catch { failed = true }
        #expect(count == 2)
        #expect(failed)
    }

    @Test
    func testPayloadBudgetCountsUTF8AndKeepsAcceptedPrefix() async throws {
        let delivery = LLMStreamDelivery(maxEvents: 128, maxPayloadBytes: 4)
        try delivery.yield("A你")
        #expect(throws: LLMError.self) { try delivery.yield("B") }
        var text = ""
        do { for try await delta in delivery.stream { text += delta } } catch {}
        #expect(text == "A你")
        #expect(delivery.payloadBytes == 4)
    }

    @Test
    func testCancellationDoesNotReportCompletion() async throws {
        let delivery = LLMStreamDelivery()
        try delivery.yield("前缀")
        delivery.finish(throwing: LLMError.cancelled)
        var text = "", failure: LLMError?
        do { for try await delta in delivery.stream { text += delta } }
        catch { failure = error as? LLMError }
        #expect(text == "前缀")
        #expect(failure == .cancelled)
    }

    @Test
    func testEventAtDeadlineHasDeterministicOutcome() throws {
        let now = ContinuousClock.now
        var state = StreamDeadlineState(firstProgressDeadline: now + .seconds(1), stallTimeout: .seconds(2))
        #expect(throws: LLMError.self) { try state.advance(event: .text, now: now + .seconds(1)) }
        #expect(!state.firstTextSeen)
        var earlier = StreamDeadlineState(firstProgressDeadline: now + .seconds(1), stallTimeout: .seconds(2))
        try earlier.advance(event: .text, now: now + .milliseconds(999))
        #expect(earlier.firstTextSeen)
        #expect(earlier.expiry(now: now + .seconds(1)) == nil)
    }

    @Test
    func testReasoningPreservesExistingProgressSemantics() throws {
        let now = ContinuousClock.now
        var state = StreamDeadlineState(firstProgressDeadline: now + .seconds(1), stallTimeout: .seconds(2))
        try state.advance(event: .reasoning, now: now + .milliseconds(900))
        #expect(!state.firstTextSeen)
        #expect(state.expiry(now: now + .seconds(1)) != nil)
        var speaking = StreamDeadlineState(firstProgressDeadline: nil, stallTimeout: .seconds(2))
        try speaking.advance(event: .text, now: now)
        try speaking.advance(event: .reasoning, now: now + .seconds(1))
        #expect(speaking.expiry(now: now + .seconds(2)) == nil)
        #expect(speaking.expiry(now: now + .seconds(3)) != nil)
    }

    @Test @MainActor
    func testPreviewHasOneLatestSnapshotAndOneTimer() async throws {
        var published: [String] = []
        let preview = LLMTextPreview { published.append($0) }
        for i in 0..<2_000 { preview.submit("夹具 \(i)") }
        #expect(published.isEmpty)
        #expect(preview.timerStartCount == 1)
        #expect(preview.pendingText == "夹具 1999")
        preview.flushPending()
        #expect(published == ["夹具 1999"])
        preview.submit("终态")
        await preview.finish()
        #expect(published == ["夹具 1999", "终态"])
        #expect(!preview.hasTimer)
        #expect(preview.pendingText == nil)
    }

    @Test @MainActor
    func testCancelledPreviewLeavesNoOwnedTaskOrLatePublication() async throws {
        var published: [String] = []
        let preview = LLMTextPreview { published.append($0) }
        preview.submit("待显示")
        await preview.cancel()
        preview.submit("迟到")
        #expect(published.isEmpty)
        #expect(!preview.hasTimer)
        #expect(preview.pendingText == nil)
    }

    @Test
    func testFirstTextReschedulesTheEarlierStallDeadline() throws {
        let now = ContinuousClock.now
        let timer = StreamTimer(firstDeadline: now + .seconds(30), stallTimeout: .seconds(15), initialStall: nil)
        defer { timer.stop() }
        #expect(timer.scheduledWake == now + .seconds(30))
        try timer.advance(events: [.text], now: now)
        #expect(timer.scheduledWake == now + .seconds(15))
        #expect(timer.scheduleCount == 2)
        #expect(timer.eventChecks == 1)
    }

    private struct SegmentedBytes: AsyncSequence, Sendable {
        typealias Element = UInt8
        let chunks: [[UInt8]]
        struct AsyncIterator: AsyncIteratorProtocol {
            let chunks: [[UInt8]]
            var chunk = 0, offset = 0
            mutating func next() async -> UInt8? {
                while chunk < chunks.count {
                    if offset < chunks[chunk].count {
                        defer { offset += 1 }
                        return chunks[chunk][offset]
                    }
                    chunk += 1; offset = 0
                }
                return nil
            }
        }
        func makeAsyncIterator() -> AsyncIterator { .init(chunks: chunks) }
    }

    @Test
    func testDeadlineChecksScaleWithEventsNotBytes() async throws {
        let data = Array((String(repeating: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"你好\"}\n\n", count: 80)
            + "data: {\"type\":\"response.completed\"}\n\n").utf8)
        for chunkSize in [1, 7, 4096] {
            let chunks = stride(from: 0, to: data.count, by: chunkSize).map { Array(data[$0..<min($0 + chunkSize, data.count)]) }
            let timer = StreamTimer(firstDeadline: nil, stallTimeout: nil, initialStall: nil)
            let sink = Mutex("")
            let work = StreamRunWork()
            let result = try await StreamRace.run(bytes: SegmentedBytes(chunks: chunks), onDelta: { delta in
                sink.withLock { $0 += delta }
            }, timer: timer, cancelTransport: {}, work: work)
            #expect(work.activeTasks == 0)
            #expect(work.peakTasks <= 2)
            #expect(work.peakTasks > 0)
            #expect(result.state.isFinished)
            #expect(sink.withLock { $0 } == String(repeating: "你好", count: 80))
            #expect(timer.eventChecks == 81)
            #expect(timer.wakeCount == 0)
            #expect(result.byteCount == data.count)
        }
    }

    private final class StalledBytes: AsyncSequence, Sendable {
        typealias Element = UInt8
        struct AsyncIterator: AsyncIteratorProtocol {
            let owner: StalledBytes
            mutating func next() async throws -> UInt8? { try await owner.read() }
        }
        private struct State { var cancelled = false; var waiter: CheckedContinuation<UInt8?, any Error>? }
        private let state = Mutex(State())
        let cancellations = Mutex(0)
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        func makeAsyncIterator() -> AsyncIterator { .init(owner: self) }
        func read() async throws -> UInt8? {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = state.withLock { state in
                    if state.cancelled { return true }
                    state.waiter = continuation
                    return false
                }
                if cancelled { continuation.resume(throwing: URLError(.cancelled)) }
                else { entered.continuation.yield(()) }
            }
        }
        func cancel() {
            cancellations.withLock { $0 += 1 }
            let waiter = state.withLock { state in
                state.cancelled = true
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(throwing: URLError(.cancelled))
        }
    }

    @Test
    func testStalledReadIsCancelledWithoutAnotherByte() async throws {
        let source = StalledBytes()
        let work = StreamRunWork()
        let timer = StreamTimer(firstDeadline: .now + .milliseconds(20), stallTimeout: nil, initialStall: nil)
        await #expect(throws: LLMError.self) {
            try await StreamRace.run(bytes: source, onDelta: { _ in }, timer: timer, cancelTransport: { source.cancel() }, work: work)
        }
        #expect(work.activeTasks == 0)
        #expect(work.peakTasks <= 2)
        #expect(source.cancellations.withLock { $0 } == 1)
        #expect(timer.wakeCount == 1)
        #expect(timer.eventChecks == 0)
    }

    @Test
    func testCancellingRunStopsUncooperativeReadAndDrainsTasks() async throws {
        let source = StalledBytes(), work = StreamRunWork()
        let timer = StreamTimer(firstDeadline: nil, stallTimeout: nil, initialStall: nil)
        let run = Task {
            try await StreamRace.run(bytes: source, onDelta: { _ in }, timer: timer,
                cancelTransport: { source.cancel() }, work: work)
        }
        var entered = source.entered.stream.makeAsyncIterator()
        _ = await entered.next()
        run.cancel()
        do { _ = try await run.value; Issue.record("Cancelled run reported success") }
        catch { #expect(error as? LLMError == .cancelled) }
        #expect(work.activeTasks == 0)
        #expect(work.peakTasks <= 2)
        #expect(source.cancellations.withLock { $0 } == 1)
    }

    @Test
    func testEOFMissingTerminalIsFailure() async throws {
        let source = SegmentedBytes(chunks: [Array("data: {\"type\":\"response.output_text.delta\",\"delta\":\"片段\"}\n\n".utf8)])
        let timer = StreamTimer(firstDeadline: nil, stallTimeout: nil, initialStall: nil)
        await #expect(throws: LLMError.self) {
            try await StreamRace.run(bytes: source, onDelta: { _ in }, timer: timer, cancelTransport: {})
        }
    }
}
