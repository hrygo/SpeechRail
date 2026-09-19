import Foundation

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

    private let selection: Selection
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    /// 采集**自己停下来**的原因（来源 App 全退、设备被拔…）。`nil` = 用户让它停的。
    public private(set) var stopReason: String?

    public init(selection: Selection) {
        self.selection = selection
    }

    deinit {
        stop()
    }

    public func start() async throws -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        adopt(continuation)

        let connection = NSXPCConnection(serviceName: CaptureHelperConstants.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: SpeechRailCaptureHelperProtocol.self)
        connection.exportedInterface = NSXPCInterface(
            with: SpeechRailCaptureHelperClientProtocol.self
        )
        connection.exportedObject = Receiver(owner: self)
        connection.invalidationHandler = { [weak self] in
            self?.receiveStopped(reason: "采集服务退出了。")
        }
        connection.interruptionHandler = { [weak self] in
            self?.receiveStopped(reason: "采集服务中断了。")
        }
        connection.resume()
        attach(connection)

        do {
            try await requestStart(on: connection)
        } catch {
            stop()
            throw error
        }
        return stream
    }

    public func stop() {
        let (connection, continuation) = detach()

        continuation?.finish()
        guard let connection else { return }
        // `stop` 的 reply 故意不等：App 退出路径上不允许被一个不响应的 helper 挂住。
        // 连接一作废，helper 的 `invalidationHandler` 会替我们收尾（幂等）。
        (connection.remoteObjectProxyWithErrorHandler { _ in } as? SpeechRailCaptureHelperProtocol)?
            .stop {}
        connection.invalidate()
    }

    private func requestStart(on connection: NSXPCConnection) async throws {
        // 连接错误回调与 `start` 的 reply 都可能到，所以用一次性闸门包住续体：
        // 两次 `resume` 会直接把 App 打崩。
        let once = OnceContinuation(continuation: nil)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            once.attach(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                once.resume(throwing: Failure.helperUnavailable(error.localizedDescription))
            }) as? SpeechRailCaptureHelperProtocol
            guard let proxy else {
                once.resume(throwing: Failure.helperUnavailable("拿不到采集服务的代理。"))
                return
            }
            proxy.start(
                bundleIDs: selection.bundleIDs,
                deviceUID: selection.deviceUID,
                label: selection.label
            ) { error in
                if let error {
                    once.resume(
                        throwing: Failure.helperUnavailable(error.localizedDescription)
                    )
                } else {
                    once.resume(returning: ())
                }
            }
        }
    }

    fileprivate func deliver(pcm: Data, level: Double) {
        let continuation = currentContinuation()
        continuation?.yield(AudioChunk(pcm: pcm, level: level))
    }

    fileprivate func receiveStopped(reason: String) {
        let (_, continuation) = fail(reason: reason)
        continuation?.finish()
    }

    // 锁只用在这几个**同步**的小函数里：`start()` 是 async，而
    // `NSLock.lock()` 在异步上下文里被标成不可用（`noasync`），
    // 在 async 函数体里直接加锁会被编译器拒掉。

    private func adopt(_ continuation: AsyncStream<AudioChunk>.Continuation) {
        lock.lock()
        self.continuation = continuation
        stopReason = nil
        lock.unlock()
    }

    private func attach(_ connection: NSXPCConnection) {
        lock.lock()
        self.connection = connection
        lock.unlock()
    }

    private func detach() -> (NSXPCConnection?, AsyncStream<AudioChunk>.Continuation?) {
        lock.lock()
        defer { lock.unlock() }
        let pair = (connection, continuation)
        connection = nil
        continuation = nil
        return pair
    }

    private func currentContinuation() -> AsyncStream<AudioChunk>.Continuation? {
        lock.lock()
        defer { lock.unlock() }
        return continuation
    }

    private func fail(
        reason: String
    ) -> (NSXPCConnection?, AsyncStream<AudioChunk>.Continuation?) {
        lock.lock()
        defer { lock.unlock() }
        let pair = (connection, continuation)
        if continuation != nil { stopReason = reason }
        continuation = nil
        return pair
    }

    /// 上行回调的落地对象。XPC 要求 `exportedObject` 是 `NSObject`。
    private final class Receiver: NSObject, SpeechRailCaptureHelperClientProtocol {
        private weak var owner: SystemAudioCapture?

        init(owner: SystemAudioCapture) {
            self.owner = owner
        }

        func deliver(pcm: Data, level: Double) {
            owner?.deliver(pcm: pcm, level: level)
        }

        func captureStopped(reason: String) {
            owner?.receiveStopped(reason: reason)
        }
    }
}

/// 只允许第一次 `resume` 生效的续体闸门（XPC 的两条回调路径会竞争）。
private final class OnceContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    init(continuation: CheckedContinuation<Void, Error>?) {
        self.continuation = continuation
    }

    func attach(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume(returning value: Void) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(throwing: error)
    }
}
