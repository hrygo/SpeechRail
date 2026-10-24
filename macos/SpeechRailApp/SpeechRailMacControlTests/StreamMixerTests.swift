import Foundation
import Testing
import Synchronization
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

@Suite(.timeLimit(.minutes(1)))
struct StreamMixerTests {
    @Test func testSchedulerDoesNotAccumulateSmallWakeDelays() async throws {
        let clock = Mutex((now: UInt64(1_000_000_000), deadlines: [UInt64]()))
        let mixer = StreamMixer(now: { clock.withLock { $0.now } }, sleepUntil: { deadline in
            let count = clock.withLock {
                $0.deadlines.append(deadline)
                $0.now = deadline + 2_000_000
                return $0.deadlines.count
            }
            if count >= 50 { try await Task.sleep(for: .seconds(60)) }
            else { await Task.yield() }
        })
        _ = await mixer.start()
        while clock.withLock({ $0.deadlines.count }) < 50 { await Task.yield() }
        await mixer.stop()
        let deadlines = clock.withLock { Array($0.deadlines.prefix(50)) }
        #expect(deadlines == (1...50).map { 1_000_000_000 + UInt64($0) * 40_000_000 })
        #expect(await mixer.snapshot().activeTasks == 0)
    }

    @Test func testSchedulerSkipsExpiredDeadlinesAfterLargeWakeDelay() async throws {
        let clock = Mutex((now: UInt64(1_000_000_000), deadlines: [UInt64]()))
        let mixer = StreamMixer(now: { clock.withLock { $0.now } }, sleepUntil: { deadline in
            let count = clock.withLock {
                $0.deadlines.append(deadline)
                $0.now = deadline + ($0.deadlines.count == 1 ? 1_000_000_000 : 0)
                return $0.deadlines.count
            }
            if count >= 2 { try await Task.sleep(for: .seconds(60)) }
        })
        _ = await mixer.start()
        while clock.withLock({ $0.deadlines.count }) < 2 { await Task.yield() }
        await mixer.stop()
        #expect(clock.withLock { $0.deadlines } == [1_040_000_000, 2_080_000_000])
        #expect(await mixer.snapshot().tickCount == 2)
    }

    private func pcm(_ value: Int16, frames: Int = 960) -> Data {
        [Int16](repeating: value.littleEndian, count: frames).withUnsafeBytes { Data($0) }
    }

    @Test func testMixedPCMMatchesReferenceAndKeepsSourceWatermarks() async throws {
        let a = AudioChunkStream.makeStream(now: { 1_000 }), b = AudioChunkStream.makeStream(now: { 1_000 })
        let firstID = UUID(), secondID = UUID(), epoch = UUID()
        let metrics = AppPerformanceMetrics(collecting: true, signposting: false)
        let mixer = StreamMixer(automaticTicks: false, now: { 1_000 }, metrics: metrics)
        let output = await mixer.start()
        try await mixer.attach(sourceID: firstID, stream: a.stream)
        try await mixer.attach(sourceID: secondID, stream: b.stream)
        for (pair, id, value) in [(a, firstID, Int16(25_000)), (b, secondID, Int16(20_000))] {
            pair.continuation.offer(.init(pcm: pcm(value), level: 1,
                captureStamp: .init(captureEpoch: epoch, sourceID: id, sourceSequence: 1, capturedUptimeNanoseconds: 1_000)))
        }
        while await mixer.snapshot().queuedBytes < 3_840 { await Task.yield() }
        await mixer.tick(at: 1_000)
        var reader = output.makeAsyncIterator()
        let mixed = try #require(try await reader.next())
        #expect(mixed.pcm == pcm(32_767))
        #expect(Set(mixed.sourceWatermarks.map(\.sourceID)) == [firstID, secondID])
        #expect(mixed.captureStamp?.capturedUptimeNanoseconds == 1_000)
        let summary = metrics.snapshot(for: .mixerTick)
        #expect(summary.samples == 1 && summary.bytes == 1_920 && summary.count == 2)
        #expect(summary.failed == 0)
        await mixer.stop()
        #expect(await mixer.snapshot().activeTasks == 0)
        #expect(await mixer.snapshot().queuedBytes == 0)
    }

    @Test func testHundredReconnectsKeepTwoSlots() async throws {
        let mixer = StreamMixer(automaticTicks: false)
        _ = await mixer.start()
        let mic = UUID(), system = UUID()
        let microphone = AudioChunkStream.makeStream()
        try await mixer.attach(sourceID: mic, stream: microphone.stream)
        for _ in 0..<100 {
            let source = AudioChunkStream.makeStream()
            try await mixer.attach(sourceID: system, stream: source.stream)
            let snapshot = await mixer.snapshot()
            #expect(snapshot.allocatedSlots == 2)
            #expect(snapshot.activeTasks <= 2)
        }
        await mixer.stop()
        #expect(await mixer.snapshot().activeTasks == 0)
        #expect(await mixer.snapshot().activeSlots == 0)
    }

    @Test func testLateTickDoesNotReplayMissedDeadlines() async throws {
        let mixer = StreamMixer(automaticTicks: false, now: { 31_000_000_000 })
        let output = await mixer.start()
        let source = AudioChunkStream.makeStream()
        try await mixer.attach(sourceID: UUID(), stream: source.stream)
        source.continuation.offer(.init(pcm: pcm(10, frames: 9_600), level: 0))
        while await mixer.snapshot().queuedBytes == 0 { await Task.yield() }
        await mixer.tick(at: 31_000_000_000)
        #expect(output.snapshot.queuedChunks == 1)
        #expect(await mixer.snapshot().tickCount == 1)
        #expect(await mixer.snapshot().nextTickUptimeNanoseconds == 31_040_000_000)
        await mixer.stop()
    }

    @Test func testNoSourceDoesNotEmitSyntheticSilence() async {
        let mixer = StreamMixer(automaticTicks: false)
        let output = await mixer.start()
        await mixer.tick(at: 1)
        #expect(output.snapshot.queuedChunks == 0)
        await mixer.stop()
    }

    // 单个 chunk 比整个混音窗口还大时没有地方安放它，只能整块拒绝。
    // 环形缓冲满（多个 chunk 叠加）走的是另一条路：丢最旧的，见下面的突发测试。
    @Test func testSingleOversizedChunkIsRejectedAsOverflow() async throws {
        let mixer = StreamMixer(automaticTicks: false)
        let output = await mixer.start(), source = AudioChunkStream.makeStream()
        try await mixer.attach(sourceID: UUID(), stream: source.stream)
        source.continuation.offer(.init(pcm: pcm(1, frames: 9_601), level: 0))
        while output.snapshot.termination == nil { await Task.yield() }
        var reader = output.makeAsyncIterator()
        do { _ = try await reader.next(); Issue.record("Mixer accepted an oversized chunk instead of reporting overflow") }
        catch { #expect((error as? AudioStreamError)?.reason == .overflow) }
        await mixer.stop()
        #expect(await mixer.snapshot().queuedBytes == 0)
    }

    @Test func testSourceLostCanBeReplacedWithoutEndingOtherSource() async throws {
        let mixer = StreamMixer(automaticTicks: false)
        let output = await mixer.start(), source = AudioChunkStream.makeStream()
        let id = UUID()
        try await mixer.attach(sourceID: id, stream: source.stream)
        source.continuation.finish(.sourceLost)
        while await mixer.snapshot().activeSlots > 0 { await Task.yield() }
        #expect(output.snapshot.termination == nil)
        let replacement = AudioChunkStream.makeStream()
        try await mixer.attach(sourceID: id, stream: replacement.stream)
        #expect(await mixer.snapshot().allocatedSlots == 1)
        await mixer.stop()
    }

    @Test func testNormalStopDrainsCompleteAndPartialTailWithoutInventingSilence() async throws {
        let source = AudioChunkStream.makeStream()
        let mixer = StreamMixer(automaticTicks: false)
        let output = await mixer.start()
        try await mixer.attach(sourceID: UUID(), stream: source.stream)
        source.continuation.offer(.init(pcm: pcm(123, frames: 1_200), level: 0))
        source.continuation.finish(.completed)
        await mixer.stop(drainPending: true)
        var received = Data()
        for try await chunk in output { received.append(chunk.pcm) }
        #expect(received == pcm(123, frames: 1_200))
        #expect(await mixer.snapshot().activeTasks == 0)
        #expect(await mixer.snapshot().queuedBytes == 0)
    }

    @Test func testStaleInputIsDiscardedWithoutFailingMixer() async throws {
        let clock = Mutex(UInt64(1_000_000_000))
        let source = AudioChunkStream.makeStream(now: { clock.withLock { $0 } })
        let mixer = StreamMixer(automaticTicks: false, now: { clock.withLock { $0 } })
        let output = await mixer.start()
        let sourceID = UUID(), epoch = UUID()
        try await mixer.attach(sourceID: sourceID, stream: source.stream)

        // Offer a chunk at sourceTime = 1_000_000_000
        source.continuation.offer(.init(pcm: pcm(100), level: 0.5,
            captureStamp: .init(captureEpoch: epoch, sourceID: sourceID, sourceSequence: 1, capturedUptimeNanoseconds: 1_000_000_000)))

        while await mixer.snapshot().queuedBytes == 0 { await Task.yield() }

        // Advance mixer clock to 2_000_000_000 (1 second later, > 750ms threshold)
        clock.withLock { $0 = 2_000_000_000 }
        await mixer.tick(at: 2_000_000_000)

        // Stale chunk should be discarded, mixer output must remain healthy
        #expect(output.snapshot.termination == nil)
        var reader = output.makeAsyncIterator()
        _ = try await reader.next()
        #expect(await mixer.snapshot().queuedBytes == 0)

        // Verify mixer can still receive fresh chunk and continue normally
        source.continuation.offer(.init(pcm: pcm(200), level: 0.5,
            captureStamp: .init(captureEpoch: epoch, sourceID: sourceID, sourceSequence: 2, capturedUptimeNanoseconds: 2_000_000_000)))
        while await mixer.snapshot().queuedBytes == 0 { await Task.yield() }

        await mixer.tick(at: 2_000_000_000)
        #expect(output.snapshot.termination == nil)

        // Even if an input source ends with .staleInput, the mixer itself does not fail
        source.continuation.finish(.staleInput)
        while await mixer.snapshot().activeSlots > 0 { await Task.yield() }
        #expect(output.snapshot.termination == nil)

        await mixer.stop()
    }

    @Test func testBurstOfChunksEvictsOldestInsteadOfFailingMixer() async throws {
        let mixer = StreamMixer(automaticTicks: false)
        let output = await mixer.start()
        let source = AudioChunkStream.makeStream()
        try await mixer.attach(sourceID: UUID(), stream: source.stream)

        // Offer 20 valid 40ms chunks (more than 16 slots ring capacity)
        for seq in 1...20 {
            source.continuation.offer(.init(pcm: pcm(Int16(seq)), level: 0.1, sequenceNumber: seq))
        }

        // Give the ingest task time to process all chunks
        for _ in 0..<10 { await Task.yield() }

        // The mixer must NOT have failed with .overflow
        #expect(output.snapshot.termination == nil)
        #expect(await mixer.snapshot().queuedBytes <= 19_200)

        await mixer.stop()
    }

    @Test func testSilentSlotDoesNotAccumulateGapsEveryTick() async throws {
        let mixer = StreamMixer(automaticTicks: false)
        let output = await mixer.start()
        var reader = output.makeAsyncIterator()
        let mic = AudioChunkStream.makeStream()
        let sys = AudioChunkStream.makeStream()
        let micID = UUID(), sysID = UUID()
        try await mixer.attach(sourceID: micID, stream: mic.stream)
        try await mixer.attach(sourceID: sysID, stream: sys.stream)

        // Mic delivers 5 chunks while Sys delivers nothing (Sys is silent/idle from beginning)
        for seq in 1...5 {
            mic.continuation.offer(.init(pcm: pcm(100), level: 0.5, sequenceNumber: seq))
        }
        while await mixer.snapshot().queuedBytes < 5 * 1_920 { await Task.yield() }

        // Process 5 ticks with active Mic and silent Sys
        for _ in 1...5 {
            await mixer.tick(at: 1_000)
            _ = try await reader.next()
        }

        // Silent slot should NOT accumulate gaps every tick
        #expect(await mixer.snapshot().gaps == 0)

        // Now Sys delivers 1 chunk, followed by a gap
        sys.continuation.offer(.init(pcm: pcm(50), level: 0.2, sequenceNumber: 1))
        mic.continuation.offer(.init(pcm: pcm(100), level: 0.5, sequenceNumber: 6))
        while await mixer.snapshot().queuedBytes < 2 * 1_920 { await Task.yield() }

        // Tick with both producing
        await mixer.tick(at: 1_040)
        _ = try await reader.next()
        #expect(await mixer.snapshot().gaps == 0)

        // Next tick: Mic delivers, but Sys drops (transition to gap)
        mic.continuation.offer(.init(pcm: pcm(100), level: 0.5, sequenceNumber: 7))
        while await mixer.snapshot().queuedBytes < 1_920 { await Task.yield() }
        await mixer.tick(at: 1_080)
        _ = try await reader.next()
        #expect(await mixer.snapshot().gaps == 1)

        // Following ticks: Sys stays silent. Gaps must NOT repeatedly increment!
        for tick in 8...12 {
            mic.continuation.offer(.init(pcm: pcm(100), level: 0.5, sequenceNumber: tick))
            while await mixer.snapshot().queuedBytes < 1_920 { await Task.yield() }
            await mixer.tick(at: 1_080 + UInt64(tick - 7) * 40_000_000)
            _ = try await reader.next()
        }
        #expect(await mixer.snapshot().gaps == 1)

        await mixer.stop()
    }
}
