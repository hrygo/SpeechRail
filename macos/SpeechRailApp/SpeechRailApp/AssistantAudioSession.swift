import AVFoundation
import Foundation

/// Audio session used by the assistant when capture and TTS playback must share
/// one engine. Keeping this boundary separate from `AssistantSession` lets the
/// orchestration layer remain unaware of AVAudioEngine's real-time details.
/// 一次设备重建的结果。`recovered` 为 false 时上层要停止采集与连接，
/// 并把这一场记成可重试的语音中断，而不是只改一句错误文案。
struct AssistantAudioInvalidation: Sendable, Equatable {
    /// 每次重建 +1。旧 epoch 的播放回调据此失效。
    let deviceGeneration: Int
    let recovered: Bool
    let message: String?
}

protocol AssistantAudioSession: AnyObject, AudioChunkSource {
    func configure(mode: AssistantMode)
    var onPlaybackDrained: (@MainActor () -> Void)? { get set }
    /// 每一块设备播放完成（M0d 用 `dataPlayedBack`，不是 `.dataConsumed`）时回调一次，
    /// 带回入队时的 epoch、帧数与 chunkID。增量 TTS 的播放预算靠它逐块归还，
    /// played 水位靠它累计；"排空"与"播完"是两件事，而 epoch 让迟到的回调
    /// 无法改动新一轮的账本，chunkID 让重复回调只归还一次。
    /// 单次 schedule 只选一种 completion 类型，不假设同一块回调两次。
    var onPlaybackBufferRendered: (@MainActor (Int, Int, UUID) -> Void)? { get set }
    var onFailure: (@MainActor (String) -> Void)? { get set }
    /// 设备重建（切换输出设备/耳机）把这一轮**还没播完**的缓冲丢掉了（D05）。
    ///
    /// 这不是"播完了"：旧 epoch 的 rendered 回调会被代次过滤掉，永远不会回来，
    /// 所以账本预算如果不等这次通知，就永远排不空。**不要**用伪造的 rendered
    /// 回调把预算骗回来——那会让"用户其实没听到"显示成"读完了"。
    /// 上层据此中止本轮朗读、作废账本，并把回复按打断收尾。
    var onPlaybackInvalidated: (@MainActor (AssistantAudioInvalidation) async -> Void)? { get set }
    /// 返回 `false` 表示这一块**没有**进播放队列（已停止/设备不可用），
    /// 调用方必须把已经预约的播放预算还回去。
    /// `epoch` 是调用方给这一块贴的账本身份，`chunkID` 是该块的唯一身份，
    /// 两者必须原样在 `onPlaybackBufferRendered` 里带回。
    @discardableResult
    func enqueuePlayback(_ pcm: Data, epoch: Int, chunkID: UUID) async -> Bool
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
                "这个输入设备的格式转不成 24 kHz 单声道。"
            case .voiceProcessingUnavailable(let message):
                "系统语音处理不可用：\(message)"
            case .engineFailed(let message):
                "共享音频引擎没有开始：\(message)"
            }
        }
    }

    /// 近端采集与 wire 同一个采样率；播放侧另有自己的协商格式。
    private static let captureSampleRate: Double = 24_000
    private static let playbackSampleRate: Double = 24_000
    private static let chunkDuration: DispatchTimeInterval = .milliseconds(100)
    private static let ringCapacity = 131_072

    private let queue = DispatchQueue(
        label: "com.speechrail.app.assistant.audio-engine",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private var captureDrain: AudioCaptureDrain?
    private var captureEpoch = UUID()
    private let captureSourceID = UUID()
    private let playbackFormat: AVAudioFormat?

    private var mode: AssistantMode = .duplex
    private var stopTask: Task<Void, Never>?
    private var stopped = false
    private var started = false
    private var continuation: AudioChunkStream.Continuation?

    // AVAudioEngine objects and conversion buffers are owned by `queue`.
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    private var configurationObserver: NSObjectProtocol?

    private var playbackGeneration = 0
    private var pendingBuffers = 0
    private var playbackDrainedHandler: (@MainActor () -> Void)?
    private var playbackBufferRenderedHandler: (@MainActor (Int, Int, UUID) -> Void)?
    private var failureHandler: (@MainActor (String) -> Void)?
    private var playbackInvalidatedHandler: (@MainActor (AssistantAudioInvalidation) async -> Void)?

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

    var onPlaybackBufferRendered: (@MainActor (Int, Int, UUID) -> Void)? {
        get { stateLock.withLock { playbackBufferRenderedHandler } }
        set { stateLock.withLock { playbackBufferRenderedHandler = newValue } }
    }

    var onPlaybackInvalidated: (@MainActor (AssistantAudioInvalidation) async -> Void)? {
        get { stateLock.withLock { playbackInvalidatedHandler } }
        set { stateLock.withLock { playbackInvalidatedHandler = newValue } }
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

    func start() async throws -> AudioChunkStream {
        guard await MicrophoneCapture.requestPermission() else {
            throw Failure.permissionDenied
        }
        let canStart = stateLock.withLock { () -> Bool in
            guard !stopped && !started else { return false }; started = true; return true
        }
        guard canStart else {
            throw Failure.engineFailed("一个音频会话实例只能启动一次。")
        }

        let (stream, continuation) = AudioChunkStream.makeStream(
            sourceID: captureSourceID, onTermination: { [weak self] _ in self?.requestStop() })
        stateLock.withLock { self.continuation = continuation }

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
        } catch { await stop(); throw error }

        let canDrain = stateLock.withLock { !stopped && started }
        guard canDrain else {
            await stop()
            throw Failure.engineFailed("音频会话在启动时被取消。")
        }
        return stream
    }

    func requestStop() {
        let result = stateLock.withLock { () -> (Bool, AudioChunkStream.Continuation?) in
            guard !stopped else { return (false, nil) }
            stopped = true; started = false; playbackGeneration += 1; pendingBuffers = 0
            let continuation = self.continuation; self.continuation = nil
            return (true, continuation)
        }
        guard result.0 else { return }
        result.1?.finish(.cancelled)
        queue.async { [weak self] in self?.tearDownEngineOnQueue(cancelDrainTimer: true) }
    }

    func stop() async {
        let task = stateLock.withLock { () -> Task<Void, Never> in
            if let stopTask { return stopTask }
            stopped = true; started = false; playbackGeneration += 1; pendingBuffers = 0
            let task = Task { [self] in await performStop() }
            stopTask = task
            return task
        }
        await task.value
    }

    private func performStop() async {
        let old: AudioCaptureDrain? = await withCheckedContinuation { done in
            queue.async { [self] in
                let old = captureDrain
                tearDownEngineOnQueue(cancelDrainTimer: false)
                captureDrain = nil
                done.resume(returning: old)
            }
        }
        await old?.stop(drainPending: true)
        stateLock.withLock { continuation }?.finish(.completed)
        stateLock.withLock { continuation = nil }
    }

    deinit { requestStop() }

    @discardableResult
    func enqueuePlayback(_ pcm: Data, epoch: Int, chunkID: UUID) async -> Bool {
        guard !pcm.isEmpty, let playbackFormat else { return false }
        let frameCount = pcm.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: playbackFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
              )
        else { return false }
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
        guard let reservation else { return false }
        let boxedBuffer = AssistantPCMBufferBox(buffer)

        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            queue.async { [weak self] in
                guard let self else {
                    done.resume(returning: false)
                    return
                }
                let accepted = self.stateLock.withLock {
                    !self.stopped
                        && self.started
                        && reservation.generation == self.playbackGeneration
                }
                guard accepted, let player = self.player else {
                    self.cancelPlaybackReservation(generation: reservation.generation)
                    done.resume(returning: false)
                    return
                }
                if reservation.resetCapture {
                    self.captureDrain?.discardPending()
                }
                // M0d：用 `.dataPlayedBack`（计入下游处理与设备延迟）记 played。
                // 单次 schedule 只选一种 completion 类型，不假设同一块回调两次；
                // 首版只认 played，同时记录"渲染时点未单独观测"。
                player.scheduleBuffer(
                    boxedBuffer.buffer,
                    completionCallbackType: .dataPlayedBack
                ) { [weak self] _ in
                    self?.didFinishPlaybackBuffer(
                        epoch: epoch,
                        generation: reservation.generation,
                        frames: frameCount,
                        chunkID: chunkID
                    )
                }
                if !player.isPlaying { player.play() }
                done.resume(returning: true)
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
                    self.captureDrain?.discardPending()
                }
                self.player?.stop()
                self.player?.reset()
                done.resume()
            }
        }
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
        guard let continuation = stateLock.withLock({ self.continuation }) else { throw CancellationError() }
        captureEpoch = UUID()
        let captureDrain = try AudioCaptureDrain(inputSampleRate: inputFormat.sampleRate,
            ringCapacity: Self.ringCapacity, epoch: captureEpoch, sourceID: captureSourceID,
            continuation: continuation, onFailure: { [weak self] _ in self?.requestStop() })
        self.captureDrain = captureDrain
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        input.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { buffer, _ in
            captureDrain.copyInput(buffer)
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
        player.play()
        installConfigurationObserver(for: engine)
    }

    /// Kept as the tested callback downmix boundary; production also records capture-time metadata.
    @inline(__always)
    static func copyInputToRing(_ buffer: AVAudioPCMBuffer, into ring: AudioSampleRing) {
        AudioCaptureDrain.copyInputToRing(buffer, into: ring)
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
        let (generation, invalidationHandler) = stateLock.withLock {
            () -> (Int, (@MainActor (AssistantAudioInvalidation) async -> Void)?) in
            playbackGeneration += 1
            pendingBuffers = 0
            return (playbackGeneration, playbackInvalidatedHandler)
        }
        stateLock.withLock { continuation }?.finish(.sourceLost)
        tearDownEngineOnQueue(cancelDrainTimer: true)
        stateLock.withLock { started = false }
        Task { @MainActor in
            await invalidationHandler?(AssistantAudioInvalidation(deviceGeneration: generation,
                recovered: false, message: "音频设备已切换，请重试语音。"))
        }
    }

    private func tearDownEngineOnQueue(cancelDrainTimer: Bool) {
        if cancelDrainTimer { captureDrain?.requestStop() }
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
    }

    private func cancelPlaybackReservation(generation: Int) {
        stateLock.withLock {
            guard generation == playbackGeneration else { return }
            pendingBuffers = max(0, pendingBuffers - 1)
        }
    }

    private func didFinishPlaybackBuffer(epoch: Int, generation: Int, frames: Int, chunkID: UUID) {
        let handlers: (
            rendered: (@MainActor (Int, Int, UUID) -> Void)?,
            drained: (@MainActor () -> Void)?,
            discardCapture: Bool
        )? = stateLock.withLock {
            guard generation == playbackGeneration, !stopped else { return nil }
            pendingBuffers = max(0, pendingBuffers - 1)
            return (
                rendered: playbackBufferRenderedHandler,
                drained: pendingBuffers == 0 ? playbackDrainedHandler : nil,
                discardCapture: !mode.allowsBargeIn
            )
        }
        guard let handlers else { return }
        if let rendered = handlers.rendered {
            Task { @MainActor in rendered(epoch, frames, chunkID) }
        }
        guard let drained = handlers.drained else { return }
        queue.async { [weak self] in
            if handlers.discardCapture {
                self?.captureDrain?.discardPending()
            }
            Task { @MainActor in drained() }
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
