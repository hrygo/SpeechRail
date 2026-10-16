import Foundation
import Synchronization

// App 侧的 `CaptureHelper` 客户端（`TECHNICAL-DESIGN` §5.4 的"本机音频"一路）。
//
// 它对上一层的长相与 `MicrophoneCapture` 完全一样（都是 `AudioChunkSource`）：
// 会议与字幕的分流逻辑因此**不需要知道**这一路来自另一个进程。
//
// 三件事只在这一层处理：
//
//   1. **授权与失败**：`start` 的 reply 带 `NSError` 时**原样透出**——受阻条要用它写
//      「系统录音未授权」那一句（§9 第 4 / 19 行）。这里不回退去抓整机（§14.1）。
//   2. **采集自己断了**：helper 回 `captureStopped` 时把流收掉，并留下一句可读原因。
//      `source_lost` 是四类中断里唯一自动接回的一类，接回由上层做（§5.6）。
//   3. **连接生命周期**：`stop()` 之后连接立刻作废，helper 随空闲退出——
//      「按功能启用、功能离开即释放」在进程这一层的落点（§3.5）。

public final class SystemAudioCapture: AudioChunkSource, @unchecked Sendable {
    public struct Selection: Sendable, Equatable {
        /// 要抓的 App（bundle identifier）。**按 App 抓，不抓整机**（§14.1）。
        public var bundleIDs: [String]
        /// 目标输出设备。`nil` = 系统默认输出。
        public var deviceUID: String?
        public var label: String

        public init(bundleIDs: [String], deviceUID: String? = nil, label: String = "本机音频") {
            self.bundleIDs = bundleIDs
            self.deviceUID = deviceUID
            self.label = label
        }
    }

    public enum Failure: LocalizedError, Equatable {
        case helperUnavailable(String)
        case cannotReceiveAudio(String)

        public var errorDescription: String? {
            switch self {
            case .helperUnavailable(let reason):
                "本机音频的采集服务没有起来：\(reason)"
            case .cannotReceiveAudio(let reason):
                "本机音频的采集通道中断了：\(reason)"
            }
        }
    }

    private struct State {
        var connection: NSXPCConnection?
        var continuation: AudioChunkStream.Continuation?
        var stopTask: Task<Void, Never>?
        var epoch: UUID?
        var stopReason: String?
        var stopped = false, stopping = false
        var cleanupConfirmed: Bool?
    }
    private let selection: Selection
    // NSXPCConnection is an ObjC proxy boundary. All ownership stays behind this existing unchecked adapter's lock.
    private let lock = NSLock()
    private var state = State()
    private func withState<Result>(_ body: (inout State) -> Result) -> Result { lock.withLock { body(&state) } }
    public var stopReason: String? { withState { $0.stopReason } }
    /// nil: no stop requested; false: bounded RPC timed out, helper cleanup is unconfirmed.
    public var cleanupConfirmed: Bool? { withState { $0.cleanupConfirmed } }

    public init(selection: Selection) { self.selection = selection }
    deinit { requestStop(immediate: true) }

    public func start() async throws -> AudioChunkStream {
        let epoch = UUID()
        let pair = AudioChunkStream.makeStream(epoch: epoch,
            onDequeue: { [weak self] chunk in self?.acknowledge(chunk) },
            onTermination: { [weak self] _ in self?.requestStop() })
        let connection = NSXPCConnection(serviceName: CaptureHelperConstants.serviceName)
        connection.remoteObjectInterface = CaptureHelperInterfaces.helper()
        connection.exportedInterface = CaptureHelperInterfaces.client()
        connection.exportedObject = Receiver(owner: self, epoch: epoch)
        connection.invalidationHandler = { [weak self] in self?.receiveStopped(epoch: epoch, reason: .sourceLost) }
        connection.interruptionHandler = { [weak self] in self?.receiveStopped(epoch: epoch, reason: .sourceLost) }
        let accepted = withState { value in
            guard !value.stopped, value.connection == nil else { return false }
            value.connection = connection; value.continuation = pair.continuation; value.epoch = epoch
            return true
        }
        guard accepted else { connection.invalidate(); throw CancellationError() }
        connection.resume()
        do {
            try await XPCReplyLatch.perform(
                timeout: .seconds(45),
                timeoutError: Failure.cannotReceiveAudio("采集服务未按时确认。")
            ) { [self] latch in
                sendStart(epoch: epoch, latch: latch)
            }
            guard withState({ !$0.stopped && $0.epoch == epoch }) else { throw CancellationError() }
            return pair.stream
        } catch { await stop(); throw error }
    }

    private func sendStart(epoch: UUID, latch: XPCReplyLatch) {
        guard let connection = withState({ $0.connection }) else { latch.resolve(.failure(CancellationError())); return }
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in latch.resolve(.failure(error)) } as? SpeechRailCaptureHelperProtocol
        guard let proxy else { latch.resolve(.failure(Failure.helperUnavailable("拿不到采集服务的代理。"))); return }
        proxy.start(bundleIDs: selection.bundleIDs, deviceUID: selection.deviceUID, label: selection.label, epoch: epoch.uuidString) { error in
            if let error { latch.resolve(.failure(error)) } else { latch.resolve(.success(())) }
        }
    }

    public func requestStop(immediate: Bool = false) {
        if immediate {
            let pair = withState { value in
                let pair = (value.connection, value.continuation)
                value.stopped = true; value.connection = nil; value.continuation = nil; value.epoch = nil
                return pair
            }
            pair.1?.finish(.cancelled); pair.0?.invalidate()
        } else { _ = beginStop(graceful: false) }
    }

    private func sendStop(latch: XPCReplyLatch) {
        guard let connection = withState({ $0.connection }) else { latch.resolve(.success(())); return }
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in latch.resolve(.failure(error)) } as? SpeechRailCaptureHelperProtocol
        guard let proxy else { latch.resolve(.failure(CancellationError())); return }
        proxy.stop { latch.resolve(.success(())) }
    }

    private func beginStop(graceful: Bool) -> Task<Void, Never>? {
        withState { value in
            if let task = value.stopTask { return task }
            guard !value.stopped else { return nil }
            value.stopping = true
            if !graceful { value.stopped = true }
            let task = Task { [weak self] in
                guard let self else { return }
                var confirmed = false
                do {
                    try await XPCReplyLatch.perform(
                        timeout: .seconds(2),
                        timeoutError: Failure.cannotReceiveAudio("采集服务未按时确认。")
                    ) { [self] latch in sendStop(latch: latch) }
                    confirmed = true
                } catch { }
                let pair = withState { value in
                    let pair = (value.connection, value.continuation)
                    value.stopped = true; value.connection = nil; value.continuation = nil; value.epoch = nil
                    value.cleanupConfirmed = confirmed
                    if !confirmed { value.stopReason = "采集服务未确认释放，连接已关闭。" }
                    return pair
                }
                pair.1?.finish(graceful ? (confirmed ? .completed : .staleInput) : .cancelled)
                pair.0?.invalidate()
            }
            value.stopTask = task
            return task
        }
    }

    public func stop() async {
        let task = beginStop(graceful: true)
        await task?.value
        withState { $0.stopTask = nil }
    }

    private func acknowledge(_ chunk: AudioChunk) {
        guard let stamp = chunk.captureStamp else { return }
        let connection = withState { $0.epoch == stamp.captureEpoch && !$0.stopped ? $0.connection : nil }
        guard let connection else { return }
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in self?.receiveStopped(epoch: stamp.captureEpoch, reason: .sourceLost) } as? SpeechRailCaptureHelperProtocol
        proxy?.acknowledge(epoch: stamp.captureEpoch.uuidString, throughSequence: stamp.sourceSequence)
    }

    fileprivate func deliver(pcm: Data, level: Double, epoch: UUID, sourceID: String, sequence: UInt64,
                             capturedUptimeNanoseconds: UInt64, droppedSamplesBefore: UInt64) {
        let continuation = withState { $0.epoch == epoch && !$0.stopped ? $0.continuation : nil }
        guard let continuation else { return }
        guard let sourceID = UUID(uuidString: sourceID), !pcm.isEmpty, pcm.count <= 1_920, pcm.count.isMultiple(of: 2),
              level.isFinite, (0...1).contains(level), sequence <= UInt64(Int.max), droppedSamplesBefore <= UInt64(Int.max) else {
            receiveStopped(epoch: epoch, reason: .sourceLost); return
        }
        continuation.offer(.init(pcm: pcm, level: level, sequenceNumber: Int(sequence), droppedSamplesBefore: Int(droppedSamplesBefore),
            captureStamp: .init(captureEpoch: epoch, sourceID: sourceID, sourceSequence: sequence,
                capturedUptimeNanoseconds: capturedUptimeNanoseconds)))
    }

    fileprivate func receiveStopped(epoch: UUID, reason: AudioStreamTermination, evidence: AudioStreamError? = nil) {
        let continuation = withState { value -> AudioChunkStream.Continuation? in
            guard value.epoch == epoch, !value.stopped else { return nil }
            if reason != .completed { value.stopReason = AudioStreamError(reason: reason).localizedDescription }
            return value.continuation
        }
        let normalCompletion = withState { $0.stopping && reason == .completed }
        if let evidence, !normalCompletion { continuation?.finish(evidence) }
        else { continuation?.finish(normalCompletion ? .completed : (reason == .completed || reason == .cancelled ? .sourceLost : reason)) }
    }

    private final class Receiver: NSObject, SpeechRailCaptureHelperClientProtocol {
        private weak var owner: SystemAudioCapture?
        private let epoch: UUID
        init(owner: SystemAudioCapture, epoch: UUID) { self.owner = owner; self.epoch = epoch }
        func deliver(pcm: Data, level: Double, epoch: String, sourceID: String, sequence: UInt64,
                     capturedUptimeNanoseconds: UInt64, droppedSamplesBefore: UInt64) {
            guard UUID(uuidString: epoch) == self.epoch else { return }
            owner?.deliver(pcm: pcm, level: level, epoch: self.epoch, sourceID: sourceID, sequence: sequence,
                capturedUptimeNanoseconds: capturedUptimeNanoseconds, droppedSamplesBefore: droppedSamplesBefore)
        }
        func captureStopped(epoch: String, evidence: Data) {
            guard UUID(uuidString: epoch) == self.epoch else { return }
            guard evidence.count <= 1_024, let error = try? JSONDecoder().decode(AudioStreamError.self, from: evidence),
                  error.captureEpoch == self.epoch else { owner?.receiveStopped(epoch: self.epoch, reason: .sourceLost); return }
            owner?.receiveStopped(epoch: self.epoch, reason: error.reason, evidence: error)
        }
    }
}
