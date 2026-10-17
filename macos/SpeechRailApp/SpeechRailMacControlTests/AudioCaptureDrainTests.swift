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
        let metrics = AppPerformanceMetrics(collecting: true, signposting: false)
        let drain = try AudioCaptureDrain(inputSampleRate: 24_000, automaticDrain: false,
            continuation: pair.continuation, metrics: metrics)
        drain.copyInput(buffer(frames: 1_200), capturedUptimeNanoseconds: 1_000_000_000)
        await drain.stop(drainPending: true)
        var bytes = 0
        for try await chunk in pair.stream { bytes += chunk.pcm.count }
        #expect(bytes == 2_400)
        #expect(drain.snapshot.rawSamples == 0)
        let summary = metrics.snapshot(for: .captureStop)
        #expect(summary.samples == 1 && summary.bytes == 4_800 && summary.count == 1_200)
    }

    @Test func testNormalStopFlushesResamplerTailAgainstWholeStreamReference() async throws {
        for sampleRate in [24_000.0, 44_100.0, 48_000.0] {
            let sampleCount = Int(sampleRate * 0.237) + 1
            let samples = (0..<sampleCount).map { index in
                Float(sin(Double(index) * 0.071) * 0.28 + (index.isMultiple(of: 97) ? 0.08 : 0))
            }
            let expected = try referencePCM(samples, inputSampleRate: sampleRate)
            let now: UInt64 = 9_000_000_000
            let duration = UInt64(Double(sampleCount) / sampleRate * 1_000_000_000)
            let captureStart = now - duration - 1_000_000
            let pair = AudioChunkStream.makeStream(now: { now })
            let drain = try AudioCaptureDrain(inputSampleRate: sampleRate, automaticDrain: false,
                continuation: pair.continuation)

            var offset = 0
            for requestedCount in [997, 2_311, 17, 4_093, 1, 509] {
                guard offset < samples.count else { break }
                let count = min(requestedCount, samples.count - offset)
                let input = Array(samples[offset..<(offset + count)])
                let capturedAt = captureStart + UInt64(Double(offset) / sampleRate * 1_000_000_000)
                drain.copyInput(buffer(samples: input, sampleRate: sampleRate),
                    capturedUptimeNanoseconds: capturedAt)
                offset += count
            }
            if offset < samples.count {
                let input = Array(samples[offset...])
                let capturedAt = captureStart + UInt64(Double(offset) / sampleRate * 1_000_000_000)
                drain.copyInput(buffer(samples: input, sampleRate: sampleRate),
                    capturedUptimeNanoseconds: capturedAt)
            }

            await drain.stop(drainPending: true)
            var chunks: [AudioChunk] = []
            for try await chunk in pair.stream { chunks.append(chunk) }
            let actual = chunks.flatMap { chunk in
                chunk.pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            }

            #expect(actual.count == expected.count)
            for (actualSample, expectedSample) in zip(actual, expected) {
                #expect(abs(Int(actualSample) - Int(expectedSample)) <= 3)
            }
            #expect(chunks.allSatisfy { $0.droppedSamplesBefore == 0 })
            #expect(chunks.enumerated().allSatisfy { $0.element.sequenceNumber == $0.offset + 1 })
            #expect(chunks.last?.captureStamp?.capturedUptimeNanoseconds ?? now < now)
            #expect(pair.stream.snapshot.termination == .completed)
            if sampleRate != 24_000 {
                let expectedLastFrame = captureStart + UInt64(Double(sampleCount - 1) / sampleRate * 1_000_000_000)
                let actualLastFrame = try #require(chunks.last?.captureStamp?.capturedUptimeNanoseconds)
                #expect(actualLastFrame >= expectedLastFrame - 2_000)
                #expect(actualLastFrame <= expectedLastFrame + 2_000)
            }
            #expect(drain.snapshot.rawSamples == 0)
        }
    }

    @Test func testCancelDoesNotFlushOrCompletePendingCapture() async throws {
        let pair = AudioChunkStream.makeStream()
        let metrics = AppPerformanceMetrics(collecting: true, signposting: false)
        let drain = try AudioCaptureDrain(inputSampleRate: 44_100, automaticDrain: false,
            continuation: pair.continuation, metrics: metrics)
        drain.copyInput(buffer(frames: 1_201, sampleRate: 44_100))

        await drain.stop()

        var reader = pair.stream.makeAsyncIterator()
        do {
            _ = try await reader.next()
            Issue.record("Cancelled capture published buffered samples")
        } catch is CancellationError {
            #expect(pair.stream.snapshot.termination == .cancelled)
        }
        #expect(drain.snapshot.rawSamples == 0)
        #expect(metrics.snapshot(for: .captureStop).cancelled == 1)
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

    private func buffer(samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        result.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() { result.floatChannelData![0][index] = sample }
        return result
    }

    private func referencePCM(_ samples: [Float], inputSampleRate: Double) throws -> [Int16] {
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputSampleRate,
                channels: 1, interleaved: false),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000,
                channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(max(2_048, Int(ceil(Double(samples.count) * 24_000 / inputSampleRate)) + 2_048))) else {
            throw ReferenceConversionFailure.setup
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() { input.floatChannelData![0][index] = sample }

        var result: [Int16] = []
        for _ in 0..<16 {
            output.frameLength = 0
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                guard !supplied else { inputStatus.pointee = .endOfStream; return nil }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            if let error { throw error }
            guard status != .error else { throw ReferenceConversionFailure.conversion }
            if output.frameLength > 0, let converted = output.int16ChannelData?[0] {
                result.append(contentsOf: UnsafeBufferPointer(start: converted, count: Int(output.frameLength)))
            }
            if status == .endOfStream { return result }
            guard status == .haveData, output.frameLength > 0 else { throw ReferenceConversionFailure.noProgress }
        }
        throw ReferenceConversionFailure.noProgress
    }

    private enum ReferenceConversionFailure: Error {
        case setup, conversion, noProgress
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
        let metrics = AppPerformanceMetrics(collecting: true, signposting: false)
        let drain = try AudioCaptureDrain(inputSampleRate: 24_000, automaticDrain: false,
            continuation: pair.continuation, metrics: metrics)
        drain.copyInput(buffer(sampleRate: 48_000))
        await drain.drainOnce()
        var reader = pair.stream.makeAsyncIterator()
        do { _ = try await reader.next(); Issue.record("Changed format entered the old epoch") }
        catch { #expect((error as? AudioStreamError)?.reason == .sourceLost) }
        await drain.stop(drainPending: true)
        #expect(pair.stream.snapshot.termination == .sourceLost)
        #expect(metrics.snapshot(for: .captureStop).failed == 1)
    }
}
