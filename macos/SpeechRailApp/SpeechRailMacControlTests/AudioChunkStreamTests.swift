import Foundation
import Synchronization
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

@Suite(.timeLimit(.minutes(1)))
struct AudioChunkStreamTests {
    @Test func testExplicitNativeDropErrorRetainsNumericEvidenceAndIdentity() async throws {
        let epoch = UUID(), source = UUID()
        let pair = AudioChunkStream.makeStream(epoch: epoch, sourceID: source)
        let failure = AudioStreamError(reason: .droppedSamples, captureEpoch: epoch, sourceID: source, droppedSamples: 64)
        pair.continuation.finish(failure)
        var reader = pair.stream.makeAsyncIterator()
        do { _ = try await reader.next(); Issue.record("Native drop evidence disappeared") }
        catch { #expect(error as? AudioStreamError == failure) }
    }

    private func chunk(epoch: UUID, source: UUID, sequence: UInt64, uptime: UInt64 = 1_000,
                       dropped: Int = 0) -> AudioChunk {
        .init(pcm: Data([1, 0]), level: 0.5, sequenceNumber: Int(sequence), droppedSamplesBefore: dropped,
              captureStamp: .init(captureEpoch: epoch, sourceID: source, sourceSequence: sequence,
                                  capturedUptimeNanoseconds: uptime))
    }

    @Test
    func testOverflowTerminatesOutOfBandWithoutSilentDrop() async throws {
        let epoch = UUID(), source = UUID()
        let pair = AudioChunkStream.makeStream(epoch: epoch, limits: .init(maxBytes: 4, maxChunks: 2), now: { 1_000 })
        #expect(pair.continuation.offer(chunk(epoch: epoch, source: source, sequence: 1)) == .accepted)
        #expect(pair.continuation.offer(chunk(epoch: epoch, source: source, sequence: 2)) == .accepted)
        #expect(pair.continuation.offer(chunk(epoch: epoch, source: source, sequence: 3)) == .overflow)
        #expect(pair.stream.snapshot.queuedBytes == 0)
        #expect(pair.stream.snapshot.queuedChunks == 0)
        var reader = pair.stream.makeAsyncIterator()
        do { _ = try await reader.next(); Issue.record("Overflow was hidden by buffered PCM") }
        catch {
            let error = try #require(error as? AudioStreamError)
            #expect(error.reason == .overflow)
            #expect(error.captureEpoch == epoch)
            #expect(error.sourceID == source)
        }
    }

    @Test
    func testCountLimitIsIndependentOfByteLimit() async throws {
        let epoch = UUID(), source = UUID()
        let pair = AudioChunkStream.makeStream(epoch: epoch, limits: .init(maxBytes: 100, maxChunks: 2), now: { 1_000 })
        _ = pair.continuation.offer(chunk(epoch: epoch, source: source, sequence: 1))
        _ = pair.continuation.offer(chunk(epoch: epoch, source: source, sequence: 2))
        #expect(pair.continuation.offer(chunk(epoch: epoch, source: source, sequence: 3)) == .overflow)
        #expect(pair.stream.snapshot.peakQueuedChunks == 2)
        #expect(pair.stream.snapshot.peakQueuedBytes == 4)
    }

    @Test
    func testOldEpochCannotPublish() async throws {
        let epoch = UUID(), source = UUID()
        let pair = AudioChunkStream.makeStream(epoch: epoch, now: { 1_000 })
        #expect(pair.continuation.offer(chunk(epoch: UUID(), source: source, sequence: 1)) == .closed)
        #expect(pair.stream.snapshot.queuedBytes == 0)
        #expect(pair.continuation.offer(chunk(epoch: epoch, source: source, sequence: 1)) == .accepted)
        pair.continuation.finish(.completed)
        var reader = pair.stream.makeAsyncIterator()
        #expect(try await reader.next()?.captureStamp?.captureEpoch == epoch)
        #expect(try await reader.next() == nil)
    }

    @Test
    func testGatePreservesAllSourceEvidence() async throws {
        let epoch = UUID(), source = UUID()
        let pair = AudioChunkStream.makeStream(epoch: epoch, now: { 1_000 })
        var original = chunk(epoch: epoch, source: source, sequence: 42)
        original.capturedAt = .now
        original.sourceWatermarks = [.init(captureEpoch: epoch, sourceID: source, sourceSequence: 42, droppedSamplesBefore: 0)]
        #expect(pair.continuation.offer(original) == .accepted)
        pair.continuation.finish(.completed)
        let gate = pair.stream.mapChunks { $0.muted() }
        var reader = gate.makeAsyncIterator()
        let muted = try #require(try await reader.next())
        #expect(muted.pcm == Data([0, 0]))
        #expect(muted.level == 0)
        #expect(muted.captureStamp == original.captureStamp)
        #expect(muted.sequenceNumber == original.sequenceNumber)
        #expect(muted.droppedSamplesBefore == original.droppedSamplesBefore)
        #expect(muted.capturedAt == original.capturedAt)
        #expect(muted.sourceWatermarks == original.sourceWatermarks)
    }

    @Test
    func testChunkAgeOver750msFails() async throws {
        let epoch = UUID(), source = UUID(), clock = Mutex<UInt64>(1_000_000_000)
        let pair = AudioChunkStream.makeStream(epoch: epoch, now: { clock.withLock { $0 } })
        #expect(pair.continuation.offer(chunk(epoch: epoch, source: source, sequence: 1, uptime: 1_000_000_000)) == .accepted)
        clock.withLock { $0 += 750_000_001 }
        var reader = pair.stream.makeAsyncIterator()
        do { _ = try await reader.next(); Issue.record("Stale PCM was delivered") }
        catch { #expect((error as? AudioStreamError)?.reason == .staleInput) }
        #expect(pair.stream.snapshot.queuedBytes == 0)
    }

    @Test
    func testUnknownSequenceIsNotClaimedContinuous() async throws {
        let pair = AudioChunkStream.makeStream()
        #expect(pair.continuation.offer(.init(pcm: Data([0, 0]), level: 0)) == .accepted)
        #expect(!pair.stream.snapshot.sourceContinuityKnown)
        pair.continuation.finish(.cancelled)
        #expect(pair.stream.snapshot.queuedBytes == 0)
    }

    @Test
    func testSequenceGapAndDropsAreExplicitFailures() async throws {
        let epoch = UUID(), source = UUID()
        let pair = AudioChunkStream.makeStream(epoch: epoch, now: { 1_000 })
        _ = pair.continuation.offer(chunk(epoch: epoch, source: source, sequence: 1))
        #expect(pair.continuation.offer(chunk(epoch: epoch, source: source, sequence: 3)) == .closed)
        var reader = pair.stream.makeAsyncIterator()
        do { _ = try await reader.next(); Issue.record("Sequence gap was hidden") }
        catch {
            let error = try #require(error as? AudioStreamError)
            #expect(error.reason == .droppedSamples)
            #expect(error.expectedSequence == 2)
            #expect(error.receivedSequence == 3)
        }
        let dropped = AudioChunkStream.makeStream(epoch: epoch, now: { 1_000 })
        #expect(dropped.continuation.offer(chunk(epoch: epoch, source: source, sequence: 1, dropped: 8)) == .closed)
        var second = dropped.stream.makeAsyncIterator()
        do { _ = try await second.next(); Issue.record("Dropped samples were hidden") }
        catch { #expect((error as? AudioStreamError)?.droppedSamples == 8) }
    }

    @Test
    func testCancelledReadReleasesTheWaiter() async throws {
        let pair = AudioChunkStream.makeStream()
        let read = Task { var iterator = pair.stream.makeAsyncIterator(); return try await iterator.next() }
        read.cancel()
        do { _ = try await read.value; Issue.record("Cancelled read reported completion") }
        catch { #expect(error is CancellationError) }
        #expect(pair.stream.snapshot.waitingConsumers == 0)
        #expect(pair.stream.snapshot.queuedBytes == 0)
    }

    @Test
    func testSourceLostCarriesKnownIdentityToWaitingConsumer() async throws {
        let epoch = UUID(), source = UUID()
        let pair = AudioChunkStream.makeStream(epoch: epoch, now: { 1_000 })
        _ = pair.continuation.offer(chunk(epoch: epoch, source: source, sequence: 1))
        var first = pair.stream.makeAsyncIterator()
        _ = try await first.next()
        let waiting = Task { () -> AudioStreamError? in
            var reader = pair.stream.makeAsyncIterator()
            do { _ = try await reader.next(); return nil }
            catch { return error as? AudioStreamError }
        }
        while pair.stream.snapshot.waitingConsumers == 0 { await Task.yield() }
        pair.continuation.finish(.sourceLost)
        let failure = try #require(await waiting.value)
        #expect(failure.reason == .sourceLost)
        #expect(failure.captureEpoch == epoch)
        #expect(failure.sourceID == source)
    }

    @Test
    func testCreditCallbackOnlyRunsAfterConsumerDequeues() async throws {
        let dequeued = Mutex(0)
        let pair = AudioChunkStream.makeStream(onDequeue: { _ in dequeued.withLock { $0 += 1 } })
        _ = pair.continuation.offer(.init(pcm: Data([0, 0]), level: 0))
        #expect(dequeued.withLock { $0 } == 0)
        #expect(pair.stream.snapshot.queuedChunks == 1)
        var reader = pair.stream.makeAsyncIterator()
        _ = try await reader.next()
        #expect(dequeued.withLock { $0 } == 1)
        #expect(pair.stream.snapshot.queuedChunks == 0)
        pair.continuation.finish(.cancelled)
    }

}
