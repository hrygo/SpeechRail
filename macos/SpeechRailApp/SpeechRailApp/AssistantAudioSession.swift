import AVFoundation
import Foundation

/// Audio session used by the assistant when capture and TTS playback must share
/// one engine. Keeping this boundary separate from `AssistantSession` lets the
/// orchestration layer remain unaware of AVAudioEngine's real-time details.
protocol AssistantAudioSession: AnyObject, AudioChunkSource {
    func configure(mode: AssistantMode)
    var onPlaybackDrained: (@MainActor () -> Void)? { get set }
    var onFailure: (@MainActor (String) -> Void)? { get set }
    func enqueuePlayback(_ pcm: Data) async
    func stopPlayback() async
}

/// One assistant audio engine for both near-end capture and far-end playback.
///
/// Duplex mode enables voice processing on both I/O nodes before the engine is
/// started, so the system can use the rendered signal as its AEC reference.
/// The input tap only copies native-rate samples into a preallocated SPSC ring;
/// conversion, allocation and network-facing chunk creation happen on the
/// serial drain queue.
final class AudioEngineSession: AssistantAudioSession, @unchecked Sendable {
    enum Failure: LocalizedError, Equatable {
        case permissionDenied
        case unsupportedInput
        case converterUnavailable
        case voiceProcessingUnavailable(String)
        case engineFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                "麦克风未授权。"
            case .unsupportedInput:
                "输入设备没有可用的采样率。"
            case .converterUnavailable:
                "这个输入设备的格式转不成 16 kHz 单声道。"
            case .voiceProcessingUnavailable(let message):
                "系统语音处理不可用：\(message)"
            case .engineFailed(let message):
                "共享音频引擎没有开始：\(message)"
            }
        }
    }

    private static let captureSampleRate: Double = 16_000
    private static let playbackSampleRate: Double = 24_000
    private static let chunkDuration: DispatchTimeInterval = .milliseconds(100)
    private static let ringCapacity = 131_072

    private let queue = DispatchQueue(
        label: "com.speechrail.app.assistant.audio-engine",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private let ring = AudioSampleRing(capacity: AudioEngineSession.ringCapacity)
    private let playbackFormat: AVAudioFormat?

    private var mode: AssistantMode = .duplex
    private var stopped = false
    private var started = false
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    // AVAudioEngine objects and conversion buffers are owned by `queue`.
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var converter: AVAudioConverter?
    private var conversionInputBuffer: AVAudioPCMBuffer?
    private var conversionOutputBuffer: AVAudioPCMBuffer?
    private var configurationObserver: NSObjectProtocol?
    private var drainTimer: DispatchSourceTimer?

    private var playbackGeneration = 0
    private var pendingBuffers = 0
    private var playbackDrainedHandler: (@MainActor () -> Void)?
    private var failureHandler: (@MainActor (String) -> Void)?

    init() {
        playbackFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.playbackSampleRate,
            channels: 1,
            interleaved: true
        )
    }

    var onPlaybackDrained: (@MainActor () -> Void)? {
        get { stateLock.withLock { playbackDrainedHandler } }
        set { stateLock.withLock { playbackDrainedHandler = newValue } }
    }

    var onFailure: (@MainActor (String) -> Void)? {
        get { stateLock.withLock { failureHandler } }
        set { stateLock.withLock { failureHandler = newValue } }
    }

    func configure(mode: AssistantMode) {
        stateLock.withLock {
            guard !started else { return }
            self.mode = mode
        }
    }

    func start() async throws -> AsyncStream<AudioChunk> {
        guard await MicrophoneCapture.requestPermission() else {
            throw Failure.permissionDenied
        }
        let canStart = stateLock.withLock { !stopped && !started }
        guard canStart else {
            throw Failure.engineFailed("一个音频会话实例只能启动一次。")
        }

        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        stateLock.withLock { self.continuation = continuation }
        ring.reset()

        do {
            try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
                queue.async { [weak self] in
                    guard let self else {
                        result.resume(throwing: Failure.engineFailed("音频会话已释放。"))
                        return
                    }
                    do {
                        try self.startEngineOnQueue()
                        self.stateLock.withLock { self.started = true }
                        result.resume()
                    } catch {
                        result.resume(throwing: error)
                    }
                }
            }
        } catch {
            stateLock.withLock { self.continuation = nil }
            continuation.finish()
            throw error
        }

        let canDrain = stateLock.withLock { !stopped && started }
        guard canDrain else {
            continuation.finish()
            throw Failure.engineFailed("音频会话在启动时被取消。")
        }
        startDraining(into: continuation)
        return stream
    }

    func stop() {
        let continuation = stateLock.withLock {
            stopped = true
            started = false
            playbackGeneration += 1
            pendingBuffers = 0
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.finish()
        queue.async { [weak self] in
            self?.tearDownEngineOnQueue(cancelDrainTimer: true)
        }
    }

    func enqueuePlayback(_ pcm: Data) async {
        guard !pcm.isEmpty, let playbackFormat else { return }
        let frameCount = pcm.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: playbackFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
              )
        else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        if let destination = buffer.int16ChannelData?[0] {
            pcm.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                destination.update(
                    from: base.assumingMemoryBound(to: Int16.self),
                    count: frameCount
                )
            }
        }

        let reservation: (generation: Int, resetCapture: Bool)? = stateLock.withLock {
            guard !stopped, started else { return nil }
            let resetCapture = !mode.allowsBargeIn && pendingBuffers == 0
            pendingBuffers += 1
            return (playbackGeneration, resetCapture)
        }
        guard let reservation else { return }
        let boxedBuffer = AssistantPCMBufferBox(buffer)

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self else {
                    done.resume()
                    return
                }
                let accepted = self.stateLock.withLock {
                    !self.stopped
                        && self.started
                        && reservation.generation == self.playbackGeneration
                }
                guard accepted, let player = self.player else {
                    self.cancelPlaybackReservation(generation: reservation.generation)
                    done.resume()
                    return
                }
                if reservation.resetCapture {
                    self.ring.discardPending()
                }
                player.scheduleBuffer(
                    boxedBuffer.buffer,
                    completionCallbackType: .dataConsumed
                ) { [weak self] _ in
                    self?.didFinishPlaybackBuffer(generation: reservation.generation)
                }
                if !player.isPlaying { player.play() }
                done.resume()
            }
        }
    }

    func stopPlayback() async {
        let resetCapture = stateLock.withLock {
            playbackGeneration += 1
            pendingBuffers = 0
            return !mode.allowsBargeIn
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self else {
                    done.resume()
                    return
                }
                if resetCapture {
                    self.ring.discardPending()
                }
                self.player?.stop()
                self.player?.reset()
                done.resume()
            }
        }
    }

    private func startDraining(into continuation: AsyncStream<AudioChunk>.Continuation) {
        queue.async { [weak self] in
            guard let self,
                  self.stateLock.withLock({ !self.stopped && self.started })
            else { return }

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(
                deadline: .now() + Self.chunkDuration,
                repeating: Self.chunkDuration
            )
            timer.setEventHandler { [weak self] in
                self?.drainAudioOnQueue(into: continuation)
            }
            self.drainTimer = timer
            timer.resume()
        }
    }

    private func drainAudioOnQueue(into continuation: AsyncStream<AudioChunk>.Continuation) {
        guard stateLock.withLock({ !stopped && started }),
              let converter,
              let inputBuffer = conversionInputBuffer,
              let outputBuffer = conversionOutputBuffer,
              let inputSamples = inputBuffer.floatChannelData?[0]
        else { return }

        let frameCount = ring.read(into: inputSamples, maxCount: Int(inputBuffer.frameCapacity))
        guard frameCount > 0 else { return }
        inputBuffer.frameLength = AVAudioFrameCount(frameCount)
        outputBuffer.frameLength = 0

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error,
              outputBuffer.frameLength > 0,
              let samples = outputBuffer.int16ChannelData?[0]
        else { return }

        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        let data = Data(bytes: samples, count: byteCount)
        let level = data.withUnsafeBytes { raw in
            AudioLevel.peak(raw.bindMemory(to: Int16.self))
        }
        continuation.yield(AudioChunk(pcm: data, level: level))
    }

    /// Builds the graph only on the serial audio queue. In duplex mode voice
    /// processing is enabled on both I/O nodes before the engine starts so the
    /// output render is available as the system AEC reference.
    private func startEngineOnQueue() throws {
        guard !stateLock.withLock({ stopped }) else {
            throw Failure.engineFailed("音频会话已停止。")
        }
        guard let playbackFormat else { throw Failure.converterUnavailable }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let output = engine.outputNode
        let mode = stateLock.withLock { self.mode }

        if mode.allowsBargeIn {
            do {
                try input.setVoiceProcessingEnabled(true)
                try output.setVoiceProcessingEnabled(true)
            } catch {
                throw Failure.voiceProcessingUnavailable(error.localizedDescription)
            }
            guard input.isVoiceProcessingEnabled, output.isVoiceProcessingEnabled else {
                throw Failure.voiceProcessingUnavailable("当前输入/输出节点拒绝启用 voice processing。")
            }
        }

        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw Failure.unsupportedInput }
        guard let converterInputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ),
        let converter = AVAudioConverter(from: converterInputFormat, to: Self.captureFormat)
        else {
            throw Failure.converterUnavailable
        }

        let inputFrameCapacity = AVAudioFrameCount(
            max(1_024, Int((inputFormat.sampleRate * 0.1).rounded()))
        )
        let outputFrameCapacity = AVAudioFrameCount(
            max(
                1_024,
                Int(ceil(Double(inputFrameCapacity) * Self.captureSampleRate / inputFormat.sampleRate)) + 64
            )
        )
        guard let conversionInputBuffer = AVAudioPCMBuffer(
            pcmFormat: converterInputFormat,
            frameCapacity: inputFrameCapacity
        ),
        let conversionOutputBuffer = AVAudioPCMBuffer(
            pcmFormat: Self.captureFormat,
            frameCapacity: outputFrameCapacity
        )
        else {
            throw Failure.converterUnavailable
        }

        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        input.installTap(onBus: 0, bufferSize: inputFrameCapacity, format: inputFormat) { [weak self] buffer, _ in
            self?.copyInputToRing(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            player.stop()
            player.reset()
            engine.detach(player)
            throw Failure.engineFailed(error.localizedDescription)
        }

        self.engine = engine
        self.player = player
        self.converter = converter
        self.conversionInputBuffer = conversionInputBuffer
        self.conversionOutputBuffer = conversionOutputBuffer
        player.play()
        installConfigurationObserver(for: engine)
    }

    private static let captureFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: captureSampleRate,
        channels: 1,
        interleaved: true
    )!

    /// Copies and mixes the native input buffer into the preallocated ring.
    /// This function runs on the audio callback and deliberately does no
    /// allocation, locking, conversion or UI/network work.
    @inline(__always)
    private func copyInputToRing(_ buffer: AVAudioPCMBuffer) {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0,
              let destination = ring.writableSpan()
        else { return }

        let accepted = min(frameCount, destination.count)
        let channels = max(1, Int(buffer.format.channelCount))
        if let source = buffer.floatChannelData {
            copyFloatChannels(source, channels: channels, frames: accepted, to: destination.pointer)
        } else if let source = buffer.int16ChannelData {
            copyInt16Channels(source, channels: channels, frames: accepted, to: destination.pointer)
        } else if let source = buffer.int32ChannelData {
            copyInt32Channels(source, channels: channels, frames: accepted, to: destination.pointer)
        } else if buffer.format.isInterleaved {
            guard buffer.audioBufferList.pointee.mNumberBuffers == 1,
                  let raw = buffer.audioBufferList.pointee.mBuffers.mData
            else { return }
            switch buffer.format.commonFormat {
            case .pcmFormatFloat32:
                copyInterleavedFloat(
                    UnsafePointer(raw.assumingMemoryBound(to: Float.self)),
                    channels: channels,
                    frames: accepted,
                    to: destination.pointer
                )
            case .pcmFormatInt16:
                copyInterleavedInt16(
                    UnsafePointer(raw.assumingMemoryBound(to: Int16.self)),
                    channels: channels,
                    frames: accepted,
                    to: destination.pointer
                )
            case .pcmFormatInt32:
                copyInterleavedInt32(
                    UnsafePointer(raw.assumingMemoryBound(to: Int32.self)),
                    channels: channels,
                    frames: accepted,
                    to: destination.pointer
                )
            default:
                return
            }
        } else {
            return
        }
        ring.commitWrite(accepted)
    }

    @inline(__always)
    private func copyFloatChannels(
        _ source: UnsafePointer<UnsafeMutablePointer<Float>>,
        channels: Int,
        frames: Int,
        to destination: UnsafeMutablePointer<Float>
    ) {
        if channels == 1 {
            destination.update(from: source[0], count: frames)
            return
        }
        let scale = 1 / Float(channels)
        for frame in 0..<frames {
            var sample: Float = 0
            for channel in 0..<channels {
                sample += source[channel][frame]
            }
            destination[frame] = sample * scale
        }
    }

    @inline(__always)
    private func copyInt16Channels(
        _ source: UnsafePointer<UnsafeMutablePointer<Int16>>,
        channels: Int,
        frames: Int,
        to destination: UnsafeMutablePointer<Float>
    ) {
        let scale = 1 / Float(channels * 32_768)
        for frame in 0..<frames {
            var sample: Int32 = 0
            for channel in 0..<channels {
                sample += Int32(source[channel][frame])
            }
            destination[frame] = Float(sample) * scale
        }
    }

    @inline(__always)
    private func copyInt32Channels(
        _ source: UnsafePointer<UnsafeMutablePointer<Int32>>,
        channels: Int,
        frames: Int,
        to destination: UnsafeMutablePointer<Float>
    ) {
        let scale = 1 / Float(channels) / (Float(Int32.max) + 1)
        for frame in 0..<frames {
            var sample: Int64 = 0
            for channel in 0..<channels {
                sample += Int64(source[channel][frame])
            }
            destination[frame] = Float(sample) * scale
        }
    }

    @inline(__always)
    private func copyInterleavedFloat(
        _ source: UnsafePointer<Float>,
        channels: Int,
        frames: Int,
        to destination: UnsafeMutablePointer<Float>
    ) {
        if channels == 1 {
            destination.update(from: source, count: frames)
            return
        }
        let scale = 1 / Float(channels)
        for frame in 0..<frames {
            var sample: Float = 0
            let frameOffset = frame * channels
            for channel in 0..<channels {
                sample += source[frameOffset + channel]
            }
            destination[frame] = sample * scale
        }
    }

    @inline(__always)
    private func copyInterleavedInt16(
        _ source: UnsafePointer<Int16>,
        channels: Int,
        frames: Int,
        to destination: UnsafeMutablePointer<Float>
    ) {
        let scale = 1 / Float(channels * 32_768)
        for frame in 0..<frames {
            var sample: Int32 = 0
            let frameOffset = frame * channels
            for channel in 0..<channels {
                sample += Int32(source[frameOffset + channel])
            }
            destination[frame] = Float(sample) * scale
        }
    }

    @inline(__always)
    private func copyInterleavedInt32(
        _ source: UnsafePointer<Int32>,
        channels: Int,
        frames: Int,
        to destination: UnsafeMutablePointer<Float>
    ) {
        let scale = 1 / Float(channels) / (Float(Int32.max) + 1)
        for frame in 0..<frames {
            var sample: Int64 = 0
            let frameOffset = frame * channels
            for channel in 0..<channels {
                sample += Int64(source[frameOffset + channel])
            }
            destination[frame] = Float(sample) * scale
        }
    }

    private func installConfigurationObserver(for engine: AVAudioEngine) {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in
                self?.rebuildAfterConfigurationChangeOnQueue()
            }
        }
    }

    /// Rebuilds the input tap, conversion buffers and player after a route
    /// change while preserving the same AsyncStream and session ownership.
    private func rebuildAfterConfigurationChangeOnQueue() {
        guard stateLock.withLock({ !stopped && started }) else { return }
        stateLock.withLock {
            playbackGeneration += 1
            pendingBuffers = 0
        }
        tearDownEngineOnQueue(cancelDrainTimer: false)
        do {
            try startEngineOnQueue()
        } catch {
            let message = error.localizedDescription
            let (continuation, handler) = stateLock.withLock {
                started = false
                pendingBuffers = 0
                let continuation = self.continuation
                self.continuation = nil
                return (continuation, failureHandler)
            }
            cancelDrainTimerOnQueue()
            continuation?.finish()
            Task { @MainActor in handler?("音频设备切换后无法恢复：\(message)") }
        }
    }

    private func tearDownEngineOnQueue(cancelDrainTimer: Bool) {
        if cancelDrainTimer {
            cancelDrainTimerOnQueue()
        }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            if let player {
                player.stop()
                player.reset()
                engine.detach(player)
            }
            engine.stop()
        }
        engine = nil
        player = nil
        converter = nil
        conversionInputBuffer = nil
        conversionOutputBuffer = nil
        ring.reset()
    }

    private func cancelDrainTimerOnQueue() {
        guard let drainTimer else { return }
        drainTimer.setEventHandler {}
        drainTimer.cancel()
        self.drainTimer = nil
    }

    private func cancelPlaybackReservation(generation: Int) {
        stateLock.withLock {
            guard generation == playbackGeneration else { return }
            pendingBuffers = max(0, pendingBuffers - 1)
        }
    }

    private func didFinishPlaybackBuffer(generation: Int) {
        let result: (@MainActor () -> Void)? = stateLock.withLock {
            guard generation == playbackGeneration, !stopped else { return nil }
            pendingBuffers = max(0, pendingBuffers - 1)
            guard pendingBuffers == 0 else { return nil }
            return playbackDrainedHandler
        }
        guard let result else { return }
        let shouldDiscardCapture = stateLock.withLock { !mode.allowsBargeIn }
        queue.async { [weak self] in
            if shouldDiscardCapture {
                self?.ring.discardPending()
            }
            Task { @MainActor in result() }
        }
    }
}

/// AVFAudio's buffer is managed by the ObjC framework. This box only transfers
/// ownership from the async caller to the engine's serial queue.
private final class AssistantPCMBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
