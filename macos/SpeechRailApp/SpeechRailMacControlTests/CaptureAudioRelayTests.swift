import Foundation
import Synchronization
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

@Suite(.timeLimit(.minutes(1)))
struct CaptureAudioRelayTests {
    @Test func testLateAckRequestsStaleCaptureCleanupWithoutWaitingForTimer() async {
        let epoch = UUID(), time = Mutex<UInt64>(10), stops = Mutex<[AudioStreamTermination]>([])
        let pair = AudioChunkStream.makeStream(now: { time.withLock { $0 } })
        let relay = CaptureAudioRelay(epoch: epoch, stream: pair.stream, now: { time.withLock { $0 } },
            deliver: { _ in }, stopCapture: { reason in stops.withLock { $0.append(reason) }; pair.continuation.finish(reason) })
        relay.start()
        pair.continuation.offer(.init(pcm: Data(count: 1_920), level: 0,
            captureStamp: .init(captureEpoch: epoch, sourceID: UUID(), sourceSequence: 1, capturedUptimeNanoseconds: 10)))
        while relay.snapshot.inFlightChunks == 0 { await Task.yield() }
        time.withLock { $0 += 1_000_000_000 }
        relay.acknowledge(epoch: epoch, throughSequence: 1)
        #expect(stops.withLock { $0 } == [.staleInput])
        await relay.stop()
        #expect(stops.withLock { $0 } == [.staleInput])
        #expect(pair.stream.snapshot.queuedBytes == 0)
        #expect(!relay.isPumpActive)
    }

    @Test func testNativeFailureEvidenceSurvivesHelperRelay() async throws {
        let epoch = UUID(), source = UUID(), stopped = Mutex(false)
        let pair = AudioChunkStream.makeStream(epoch: epoch, sourceID: source)
        let failure = AudioStreamError(reason: .droppedSamples, captureEpoch: epoch, sourceID: source, droppedSamples: 128)
        let relay = CaptureAudioRelay(epoch: epoch, stream: pair.stream, deliver: { _ in }, stopCapture: { _ in stopped.withLock { $0 = true } })
        relay.start(); pair.continuation.finish(failure)
        while !stopped.withLock({ $0 }) { await Task.yield() }
        await relay.stop()
        #expect(relay.terminalError == failure)
        let wire = try JSONEncoder().encode(try #require(relay.terminalError))
        #expect(wire.count < 1_024)
        #expect(try JSONDecoder().decode(AudioStreamError.self, from: wire) == failure)
    }

    @Test func testGracefulHelperStopWaitsUntilAppHasDequeuedAllDeliveredPCM() async throws {
        let epoch = UUID(), sourceID = UUID(), holder = Mutex<CaptureAudioRelay?>(nil)
        let metrics = AppPerformanceMetrics(collecting: true, signposting: false)
        let helper = AudioChunkStream.makeStream(epoch: epoch, now: { 1_000 })
        let app = AudioChunkStream.makeStream(epoch: epoch, now: { 1_000 }, onDequeue: { chunk in
            if let sequence = chunk.captureStamp?.sourceSequence { holder.withLock { $0 }?.acknowledge(epoch: epoch, throughSequence: sequence) }
        })
        let relay = CaptureAudioRelay(epoch: epoch, stream: helper.stream, now: { 1_000 }, deliver: { app.continuation.offer($0) },
            stopCapture: { app.continuation.finish($0) }, metrics: metrics)
        holder.withLock { $0 = relay }; relay.start()
        helper.continuation.offer(.init(pcm: Data(count: 1_920), level: 0,
            captureStamp: .init(captureEpoch: epoch, sourceID: sourceID, sourceSequence: 1, capturedUptimeNanoseconds: 1_000)))
        helper.continuation.finish(.completed)
        while relay.snapshot.waitingDrainers == 0 { await Task.yield() }
        #expect(relay.isPumpActive)
        #expect(app.stream.snapshot.termination == nil)
        var reader = app.stream.makeAsyncIterator()
        #expect(try await reader.next()?.pcm.count == 1_920)
        await relay.finishAndWait()
        #expect(try await reader.next() == nil)
        #expect(!relay.isPumpActive)
        let summary = metrics.snapshot(for: .captureEnqueue)
        #expect(summary.samples == 1 && summary.bytes == 1_920 && summary.count == 1)
        holder.withLock { $0 = nil }
    }

    @Test func testAppDequeueIsTheOnlyWayToReleaseFifthDelivery() async throws {
        let epoch = UUID(), source = UUID(), sent = Mutex(0), stops = Mutex(0)
        let helper = AudioChunkStream.makeStream(epoch: epoch, now: { 1_000 })
        let holder = Mutex<CaptureAudioRelay?>(nil)
        let app = AudioChunkStream.makeStream(epoch: epoch, now: { 1_000 }, onDequeue: { chunk in
            if let sequence = chunk.captureStamp?.sourceSequence { holder.withLock { $0 }?.acknowledge(epoch: epoch, throughSequence: sequence) }
        })
        let relay = CaptureAudioRelay(epoch: epoch, stream: helper.stream, now: { 1_000 }, deliver: { chunk in
            sent.withLock { $0 += 1 }; app.continuation.offer(chunk)
        }, stopCapture: { _ in stops.withLock { $0 += 1 }; helper.continuation.finish(.cancelled) })
        holder.withLock { $0 = relay }; relay.start()
        for sequence in 1...5 {
            helper.continuation.offer(.init(pcm: Data(count: 1_920), level: 0,
                captureStamp: .init(captureEpoch: epoch, sourceID: source, sourceSequence: UInt64(sequence), capturedUptimeNanoseconds: 1_000)))
        }
        while relay.snapshot.waitingSenders == 0 { await Task.yield() }
        #expect(sent.withLock { $0 } == 4)
        #expect(helper.stream.snapshot.queuedChunks == 1)
        #expect(app.stream.snapshot.queuedChunks == 4)
        var reader = app.stream.makeAsyncIterator()
        _ = try await reader.next()
        while sent.withLock({ $0 }) < 5 { await Task.yield() }
        #expect(relay.snapshot.inFlightChunks == 4)
        await relay.stop()
        #expect(stops.withLock { $0 } == 1)
        #expect(!relay.isPumpActive)
        #expect(relay.snapshot.inFlightBytes == 0)
        holder.withLock { $0 = nil }
    }

    @Test func testAckTimeoutRequestsActualCaptureCleanupAndJoinsPump() async {
        let epoch = UUID(), time = Mutex<UInt64>(10), stops = Mutex<[AudioStreamTermination]>([])
        let pair = AudioChunkStream.makeStream(now: { time.withLock { $0 } })
        let relay = CaptureAudioRelay(epoch: epoch, stream: pair.stream, now: { time.withLock { $0 } },
            deliver: { _ in }, stopCapture: { reason in stops.withLock { $0.append(reason) }; pair.continuation.finish(reason) })
        relay.start()
        pair.continuation.offer(.init(pcm: Data(count: 1_920), level: 0,
            captureStamp: .init(captureEpoch: epoch, sourceID: UUID(), sourceSequence: 1, capturedUptimeNanoseconds: 10)))
        while relay.snapshot.inFlightChunks == 0 { await Task.yield() }
        time.withLock { $0 += 1_000_000_001 }
        relay.checkDeadline()
        await relay.stop()
        #expect(stops.withLock { $0 } == [.staleInput])
        #expect(pair.stream.snapshot.queuedBytes == 0)
        #expect(!relay.isPumpActive)
    }
}
