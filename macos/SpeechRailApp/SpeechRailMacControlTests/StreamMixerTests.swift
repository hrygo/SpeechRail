import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

@Suite(.timeLimit(.minutes(1)))
struct StreamMixerTests {
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

    @Test func testInputOverflowPropagatesInsteadOfDroppingOldPCM() async throws {
        let mixer = StreamMixer(automaticTicks: false)
        let output = await mixer.start(), source = AudioChunkStream.makeStream()
        try await mixer.attach(sourceID: UUID(), stream: source.stream)
        source.continuation.offer(.init(pcm: pcm(1, frames: 9_601), level: 0))
        while output.snapshot.termination == nil { await Task.yield() }
        var reader = output.makeAsyncIterator()
        do { _ = try await reader.next(); Issue.record("Mixer discarded old PCM silently") }
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
}
