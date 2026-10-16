import AVFoundation
import Foundation
import Synchronization

/// Callback copies native mono samples into the fixed ring. Its serial queue alone converts PCM.
final class AudioCaptureDrain: Sendable {
    struct Snapshot: Sendable {
        let accepting: Bool, timerActive: Bool
        let rawSamples: Int, droppedSamples: Int, rawStorageBytes: Int, scratchBytes: Int
    }
    private struct State {
        var converter: AVAudioConverter?
        var input: AVAudioPCMBuffer?
        var output: AVAudioPCMBuffer?
        var timer: DispatchSourceTimer?
        var sequence: UInt64 = 0
    }
    private let queue = DispatchQueue(label: "com.speechrail.app.capture-drain", qos: .userInitiated)
    private let state: Mutex<State>
    private let accepting = Atomic<Bool>(true), changedFormat = Atomic<Bool>(false), timerActive = Atomic<Bool>(false)
    private let ring: AudioSampleRing
    private let sampleRate: Double, scratchBytes: Int
    private let epoch: UUID, sourceID: UUID
    private let continuation: AudioChunkStream.Continuation
    private let beforeConvert: (@Sendable () -> Void)?
    private let onFailure: (@Sendable (AudioStreamTermination) -> Void)?

    init(inputSampleRate: Double, ringCapacity: Int = 131_072, epoch: UUID = UUID(), sourceID: UUID = UUID(),
         automaticDrain: Bool = true, continuation: AudioChunkStream.Continuation,
         beforeConvert: (@Sendable () -> Void)? = nil, onFailure: (@Sendable (AudioStreamTermination) -> Void)? = nil) throws {
        guard inputSampleRate.isFinite, inputSampleRate > 0, inputSampleRate <= 384_000,
              let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputSampleRate, channels: 1, interleaved: false),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { throw MicrophoneCapture.Failure.converterUnavailable }
        let frames = max(1_024, Int(ceil(inputSampleRate / 10)))
        let convertedCapacity = ceil(Double(frames) * 24_000 / inputSampleRate) + 64
        guard convertedCapacity.isFinite, convertedCapacity > 0, convertedCapacity <= 24_000 else {
            throw MicrophoneCapture.Failure.converterUnavailable
        }
        let convertedFrames = Int(convertedCapacity)
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(convertedFrames)) else {
            throw MicrophoneCapture.Failure.converterUnavailable
        }
        self.sampleRate = inputSampleRate; self.epoch = epoch; self.sourceID = sourceID
        self.continuation = continuation; self.beforeConvert = beforeConvert; self.onFailure = onFailure
        ring = AudioSampleRing(capacity: ringCapacity)
        scratchBytes = frames * MemoryLayout<Float>.stride + convertedFrames * MemoryLayout<Int16>.stride
        state = Mutex(State(converter: converter, input: input, output: output))
        if automaticDrain { start() }
    }

    deinit {
        requestStop()
        state.withLock { $0.timer?.setEventHandler {}; $0.timer?.cancel(); $0.timer = nil }
    }
    var snapshot: Snapshot {
        .init(accepting: accepting.load(ordering: .acquiring), timerActive: timerActive.load(ordering: .acquiring),
            rawSamples: ring.availableSampleCount, droppedSamples: ring.droppedSampleCount,
            rawStorageBytes: ring.allocatedBytes, scratchBytes: scratchBytes)
    }

    /// Audio callback: bounded copies/downmix only, no converter, Data, Task, allocation or lock.
    @inline(__always)
    func copyInput(_ buffer: AVAudioPCMBuffer, capturedUptimeNanoseconds: UInt64? = nil) {
        guard accepting.load(ordering: .acquiring) else { return }
        guard buffer.format.sampleRate == sampleRate else {
            changedFormat.store(true, ordering: .releasing); accepting.store(false, ordering: .releasing); return
        }
        let callbackUptime = DispatchTime.now().uptimeNanoseconds
        let duration = UInt64(Double(buffer.frameLength) / sampleRate * 1_000_000_000)
        let origin = capturedUptimeNanoseconds ?? (callbackUptime > duration ? callbackUptime - duration : 0)
        guard ring.beginCapture(uptimeNanoseconds: origin) else {
            ring.recordDroppedSamples(Int(buffer.frameLength)); return
        }
        Self.copyInputToRing(buffer, into: ring)
    }

    func discardPending() {
        queue.async { [ring] in ring.discardPending() }
    }

    func requestStop() {
        accepting.store(false, ordering: .releasing)
        continuation.finish(.cancelled)
        queue.async { [weak self] in
            guard let self else { return }
            state.withLock { $0.timer?.setEventHandler {}; $0.timer?.cancel(); $0.timer = nil }
            timerActive.store(false, ordering: .releasing)
        }
    }

    func stop(drainPending: Bool = false) async {
        accepting.store(false, ordering: .releasing)
        await withCheckedContinuation { done in
            queue.async { [self] in
                if drainPending {
                    // Producer is already detached by the source. This bounded ring is now a finite tail.
                    while ring.availableSampleCount > 0 {
                        let previous = ring.availableSampleCount
                        drainOnQueue(whileStopping: true)
                        if ring.availableSampleCount >= previous { break }
                    }
                }
                continuation.finish(drainPending ? .completed : .cancelled)
                state.withLock { value in
                    value.timer?.setEventHandler {}; value.timer?.cancel(); value.timer = nil
                    value.converter = nil; value.input = nil; value.output = nil
                }
                timerActive.store(false, ordering: .releasing)
                ring.discardPending()
                done.resume()
            }
        }
    }

    func drainOnce() async {
        await withCheckedContinuation { done in queue.async { [self] in drainOnQueue(); done.resume() } }
    }

    private func start() {
        queue.async { [self] in
            guard accepting.load(ordering: .acquiring) else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in self?.drainOnQueue() }
            state.withLock { $0.timer = timer }
            timerActive.store(true, ordering: .releasing)
            timer.resume()
        }
    }

    private func fail(_ reason: AudioStreamTermination) {
        accepting.store(false, ordering: .releasing)
        continuation.finish(AudioStreamError(reason: reason, captureEpoch: epoch, sourceID: sourceID,
            droppedSamples: reason == .droppedSamples ? UInt64(max(0, ring.droppedSampleCount)) : nil))
        state.withLock { $0.timer?.setEventHandler {}; $0.timer?.cancel(); $0.timer = nil }
        timerActive.store(false, ordering: .releasing)
        ring.discardPending()
        onFailure?(reason)
    }

    private func drainOnQueue(whileStopping: Bool = false) {
        if changedFormat.load(ordering: .acquiring) { fail(.sourceLost); return }
        guard whileStopping || accepting.load(ordering: .acquiring) else { return }
        guard ring.droppedSampleCount == 0 else { fail(.droppedSamples); return }
        guard ring.availableSampleCount > 0 else { return }
        let captured = ring.oldestCaptureUptimeNanoseconds(sampleRate: sampleRate)
        var conversionFailed = false
        let chunk: AudioChunk? = state.withLock { value in
            guard let converter = value.converter, let input = value.input, let output = value.output,
                  let destination = input.floatChannelData?[0] else { return nil }
            let count = ring.read(into: destination, maxCount: Int(input.frameCapacity))
            guard count > 0 else { return nil }
            input.frameLength = AVAudioFrameCount(count); output.frameLength = 0
            beforeConvert?()
            var supplied = false, error: NSError?
            let status = converter.convert(to: output, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return input
            }
            guard status != .error, error == nil else { conversionFailed = true; return nil }
            guard output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return nil }
            value.sequence &+= 1
            let pcm = Data(bytes: samples, count: Int(output.frameLength) * 2)
            let level = AudioLevel.peak(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
            let stamp = captured.map { AudioCaptureStamp(captureEpoch: epoch, sourceID: sourceID,
                sourceSequence: value.sequence, capturedUptimeNanoseconds: $0) }
            return .init(pcm: pcm, level: level, capturedAt: stamp?.capturedInstant, sequenceNumber: Int(exactly: value.sequence),
                droppedSamplesBefore: ring.droppedSampleCount, captureStamp: stamp)
        }
        if conversionFailed { fail(.sourceLost); return }
        guard (whileStopping || accepting.load(ordering: .acquiring)), let chunk else { return }
        let result = continuation.offer(chunk)
        if result != .accepted { fail(result == .overflow ? .overflow : .sourceLost) }
    }

    @inline(__always)
    static func copyInputToRing(_ buffer: AVAudioPCMBuffer, into ring: AudioSampleRing) {
        let frames = Int(buffer.frameLength), channels = Int(buffer.format.channelCount), stride = buffer.stride
        guard frames > 0, channels > 0 else { return }
        var consumed = 0
        while consumed < frames, let span = ring.writableSpan() {
            let take = min(frames - consumed, span.count), scale = 1 / Float(channels)
            if let source = buffer.floatChannelData {
                for frame in 0..<take {
                    var sum: Float = 0
                    for channel in 0..<channels { sum += source[channel][(consumed + frame) * stride] }
                    span.pointer[frame] = sum * scale
                }
            } else if let source = buffer.int16ChannelData {
                for frame in 0..<take {
                    var sum: Int64 = 0
                    for channel in 0..<channels { sum += Int64(source[channel][(consumed + frame) * stride]) }
                    span.pointer[frame] = Float(sum) * scale / 32_768
                }
            } else if let source = buffer.int32ChannelData {
                for frame in 0..<take {
                    var sum: Int64 = 0
                    for channel in 0..<channels { sum += Int64(source[channel][(consumed + frame) * stride]) }
                    span.pointer[frame] = Float(sum) * scale / 2_147_483_648
                }
            } else { ring.recordDroppedSamples(frames - consumed); return }
            ring.commitWrite(take); consumed += take
        }
        ring.recordDroppedSamples(frames - consumed)
    }
}
