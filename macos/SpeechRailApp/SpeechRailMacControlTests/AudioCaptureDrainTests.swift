import AVFoundation
import Foundation
import Synchronization
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

@Suite(.timeLimit(.minutes(1)))
struct AudioCaptureDrainTests {
    @Test func testRawTimelineKeepsOldestUnreadCaptureAcrossCallbackPause() throws {
        let ring = AudioSampleRing(capacity: 15)
        #expect(ring.beginCapture(uptimeNanoseconds: 1_000_000_000))
        ring.write([1, 2, 3, 4])
        #expect(ring.beginCapture(uptimeNanoseconds: 2_000_000_000))
        ring.write([5, 6, 7, 8])
        #expect(ring.oldestCaptureUptimeNanoseconds(sampleRate: 24_000) == 1_000_000_000)
        _ = ring.read(maxCount: 2)
        #expect(ring.oldestCaptureUptimeNanoseconds(sampleRate: 24_000) == 1_000_083_333)
        _ = ring.read(maxCount: 2)
        #expect(ring.oldestCaptureUptimeNanoseconds(sampleRate: 24_000) == 2_000_000_000)
        ring.discardPending()
        #expect(ring.beginCapture(uptimeNanoseconds: 3_000_000_000))
        ring.write([9])
        #expect(ring.oldestCaptureUptimeNanoseconds(sampleRate: 24_000) == 3_000_000_000)
    }

    @Test func testNormalStopConvertsTheFiniteRawTailBeforeCompleting() async throws {
        let pair = AudioChunkStream.makeStream(now: { 1_000_000_000 })
        let drain = try AudioCaptureDrain(inputSampleRate: 24_000, automaticDrain: false, continuation: pair.continuation)
        drain.copyInput(buffer(frames: 1_200), capturedUptimeNanoseconds: 1_000_000_000)
        await drain.stop(drainPending: true)
        var bytes = 0
        for try await chunk in pair.stream { bytes += chunk.pcm.count }
        #expect(bytes == 2_400)
        #expect(drain.snapshot.rawSamples == 0)
    }

    @Test func testCallbackMetadataHasAHardCapacityEvenForTinyBuffers() async throws {
        let pair = AudioChunkStream.makeStream()
        let drain = try AudioCaptureDrain(inputSampleRate: 24_000, automaticDrain: false, continuation: pair.continuation)
        let oneFrame = buffer(frames: 1)
        for _ in 0..<65 { drain.copyInput(oneFrame) }
        #expect(drain.snapshot.rawSamples == 64)
        #expect(drain.snapshot.droppedSamples == 1)
        await drain.stop()
    }

    private func buffer(frames: Int = 960, sampleRate: Double = 24_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        result.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames { result.floatChannelData![0][index] = 0.25 }
        return result
    }

    @Test func testTapOnlyCopiesIntoPreallocatedRing() async throws {
        let conversions = Mutex(0)
        let pair = AudioChunkStream.makeStream(now: { 1_000_000_000 })
        let drain = try AudioCaptureDrain(inputSampleRate: 24_000, automaticDrain: false,
            continuation: pair.continuation, beforeConvert: { conversions.withLock { $0 += 1 } })
        drain.copyInput(buffer(), capturedUptimeNanoseconds: 1_000_000_000)
        #expect(conversions.withLock { $0 } == 0)
        #expect(drain.snapshot.rawSamples == 960)
        await drain.drainOnce()
        #expect(conversions.withLock { $0 } == 1)
        var reader = pair.stream.makeAsyncIterator()
        let chunk = try #require(try await reader.next())
        #expect(chunk.captureStamp?.capturedUptimeNanoseconds == 1_000_000_000)
        #expect(chunk.droppedSamplesBefore == 0)
        await drain.stop()
        #expect(drain.snapshot.rawSamples == 0)
    }

    @Test func testOverflowAdvancesDroppedSampleWatermark() async throws {
        let pair = AudioChunkStream.makeStream()
        let drain = try AudioCaptureDrain(inputSampleRate: 24_000, ringCapacity: 1_024,
            automaticDrain: false, continuation: pair.continuation)
        drain.copyInput(buffer(frames: 4_096))
        #expect(drain.snapshot.droppedSamples > 0)
        await drain.drainOnce()
        var reader = pair.stream.makeAsyncIterator()
        do { _ = try await reader.next(); Issue.record("Raw-ring loss became complete input") }
        catch { #expect((error as? AudioStreamError)?.reason == .droppedSamples) }
        await drain.stop()
    }

    @Test func testConvertedSampleTimelineMatchesReference() async throws {
        for rate in [24_000.0, 48_000.0] {
            let pair = AudioChunkStream.makeStream(now: { 1_100_000_000 })
            let drain = try AudioCaptureDrain(inputSampleRate: rate, automaticDrain: false, continuation: pair.continuation)
            drain.copyInput(buffer(frames: Int(rate / 10), sampleRate: rate), capturedUptimeNanoseconds: 1_000_000_000)
            await drain.drainOnce()
            var reader = pair.stream.makeAsyncIterator()
            let chunk = try #require(try await reader.next())
            #expect(chunk.captureStamp?.capturedUptimeNanoseconds == 1_000_000_000)
            #expect(chunk.pcm.count <= 4_928)
            #expect(chunk.pcm.count > 4_000)
            let samples = chunk.pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            #expect(samples.dropFirst(64).allSatisfy { abs(Int($0) - 8_192) <= 2 })
            await drain.stop()
        }
    }

    @Test func testStopWaitsForInFlightDrain() async throws {
        let entered = Mutex(false), stopped = Mutex(false), release = DispatchSemaphore(value: 0)
        let pair = AudioChunkStream.makeStream()
        let drain = try AudioCaptureDrain(inputSampleRate: 24_000, automaticDrain: false,
            continuation: pair.continuation, beforeConvert: { entered.withLock { $0 = true }; release.wait() })
        drain.copyInput(buffer())
        let work = Task { await drain.drainOnce() }
        while !entered.withLock({ $0 }) { await Task.yield() }
        let stop = Task { await drain.stop(); stopped.withLock { $0 = true } }
        while drain.snapshot.accepting { await Task.yield() }
        #expect(!stopped.withLock { $0 })
        release.signal()
        await work.value; await stop.value
        #expect(stopped.withLock { $0 })
        #expect(drain.snapshot.rawSamples == 0)
        #expect(!drain.snapshot.timerActive)
    }

    @Test func testFormatChangeRetiresOldEpoch() async throws {
        let pair = AudioChunkStream.makeStream()
        let drain = try AudioCaptureDrain(inputSampleRate: 24_000, automaticDrain: false, continuation: pair.continuation)
        drain.copyInput(buffer(sampleRate: 48_000))
        await drain.drainOnce()
        var reader = pair.stream.makeAsyncIterator()
        do { _ = try await reader.next(); Issue.record("Changed format entered the old epoch") }
        catch { #expect((error as? AudioStreamError)?.reason == .sourceLost) }
        await drain.stop()
    }
}
