import Foundation

// `CaptureHelper` 的双向 XPC 约定（`TECHNICAL-DESIGN` §3.2）。
//
// 这个文件**同时编进 App 与 helper**：两侧必须看到同一份协议名与同一组方法签名，
// 否则 `NSXPCInterface` 在运行时才会拒绝调用——那是最不容易查的一种失败。
//
// 两条设计约束：
//
//   1. **helper 不做会话决策**。它只认识"给我这些 bundle id、按这个输出设备出 PCM"和
//      "停"，不认识会话、不解析文本、不落盘、不联网。
//   2. **上行携带 PCM、电平与采集证据**。每一块就是 40 ms 的 24 kHz 单声道 PCM16；
//      没有控制消息混在音频里（控制走另一条方法的 reply）。

/// App → helper。方法都是显式的：`NSXPCConnection` 的 `remoteObjectProxy` 只转发
/// 这里声明过的东西，所以"能做的事"就是这张表。
@objc public protocol SpeechRailCaptureHelperProtocol {
    /// 建立 tap 并开始上行 PCM。
    ///
    /// 失败一律走 `reply(NSError?)`：**不抛异常、不静默**。调用方拿到错误之后
    /// 显示受阻条（§9 第 4 / 19 行），而不是继续录一条没有本机音频的轨。
    func start(
        bundleIDs: [String],
        deviceUID: String?,
        label: String,
        epoch: String,
        reply: @escaping (NSError?) -> Void
    )

    func acknowledge(epoch: String, throughSequence: UInt64)

    /// 停采集并释放 tap / aggregate device。**幂等**：没起来过也能调。
    func stop(reply: @escaping () -> Void)

    /// 诊断用：helper 的一次一句话状态。
    func status(reply: @escaping (String) -> Void)
}

/// helper → App。helper 侧的 `remoteObjectProxy` 就是这个协议。
@objc public protocol SpeechRailCaptureHelperClientProtocol {
    /// 一块 PCM（24 kHz / 单声道 / PCM16）+ 这一块的真实电平（0…1）。
    func deliver(pcm: Data, level: Double, epoch: String, sourceID: String, sequence: UInt64,
                 capturedUptimeNanoseconds: UInt64, droppedSamplesBefore: UInt64)

    /// 采集**自己停下来了**（来源 App 全退、设备被拔、tap 失效）。
    /// 这不是错误而是一个事实：`source_lost` 的中断区间就是由它记下的（§5.6）。
    func captureStopped(epoch: String, evidence: Data)
}

/// XPC 服务名。它必须与 `Resources/XPCServices/<name>.xpc/Contents/Info.plist` 的
/// `CFBundleIdentifier` 一致：`NSXPCConnection(serviceName:)` 按名字在 App bundle 的
/// `Contents/XPCServices` 里找这个包（Apple「Creating XPC services」的口径）。
public enum CaptureHelperConstants {
    public static let serviceName = "com.speechrail.desktop.capture-helper"
    public static let executableName = "SpeechRailCaptureHelper"
}

/// Explicit secure-coding classes for every collection/object argument; primitive integers use XPC's scalar encoding.
public enum CaptureHelperInterfaces {
    public static func helper() -> NSXPCInterface {
        let interface = NSXPCInterface(with: SpeechRailCaptureHelperProtocol.self)
        let start = #selector(SpeechRailCaptureHelperProtocol.start(bundleIDs:deviceUID:label:epoch:reply:))
        interface.setClasses(NSSet(objects: NSArray.self, NSString.self) as! Set<AnyHashable>, for: start, argumentIndex: 0, ofReply: false)
        for index in 1...3 { interface.setClasses(NSSet(object: NSString.self) as! Set<AnyHashable>, for: start, argumentIndex: index, ofReply: false) }
        interface.setClasses(NSSet(object: NSError.self) as! Set<AnyHashable>, for: start, argumentIndex: 0, ofReply: true)
        interface.setClasses(NSSet(object: NSString.self) as! Set<AnyHashable>, for: #selector(SpeechRailCaptureHelperProtocol.acknowledge(epoch:throughSequence:)), argumentIndex: 0, ofReply: false)
        return interface
    }
    public static func client() -> NSXPCInterface {
        let interface = NSXPCInterface(with: SpeechRailCaptureHelperClientProtocol.self)
        let deliver = #selector(SpeechRailCaptureHelperClientProtocol.deliver(pcm:level:epoch:sourceID:sequence:capturedUptimeNanoseconds:droppedSamplesBefore:))
        interface.setClasses(NSSet(object: NSData.self) as! Set<AnyHashable>, for: deliver, argumentIndex: 0, ofReply: false)
        for index in [2, 3] { interface.setClasses(NSSet(object: NSString.self) as! Set<AnyHashable>, for: deliver, argumentIndex: index, ofReply: false) }
        let stopped = #selector(SpeechRailCaptureHelperClientProtocol.captureStopped(epoch:evidence:))
        interface.setClasses(NSSet(object: NSString.self) as! Set<AnyHashable>, for: stopped, argumentIndex: 0, ofReply: false)
        interface.setClasses(NSSet(object: NSData.self) as! Set<AnyHashable>, for: stopped, argumentIndex: 1, ofReply: false)
        return interface
    }
}

struct CaptureStartTimeout: LocalizedError {
    var errorDescription: String? {
        "本机音频准备超时，尚未开始记录。请重试；若仍失败，请查看系统录音权限与音频设备。"
    }
}

/// XPC replies, cancellation and a deadline compete for exactly one outcome.
/// Cancellation can arrive before the continuation is attached.
final class CaptureStartContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func attach(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resume(returning value: Void) { complete(.success(value)) }
    func resume(throwing error: Error) { complete(.failure(error)) }

    private func complete(_ value: Result<Void, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: value)
    }

    static func wait(
        timeout: Duration = .seconds(45),
        start: (CaptureStartContinuation) -> Void
    ) async throws {
        let once = CaptureStartContinuation()
        let timer = Task {
            do {
                try await Task.sleep(for: timeout)
                once.resume(throwing: CaptureStartTimeout())
            } catch { /* Successful start or cancellation owns the outcome. */ }
        }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                once.attach(continuation)
                if Task.isCancelled { once.resume(throwing: CancellationError()) }
                else { start(once) }
            }
        } onCancel: {
            once.resume(throwing: CancellationError())
        }
    }
}

/// The helper's watchdog runs outside its possibly blocked CoreAudio queue.
final class CaptureOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// Connection acceptance may race with queued starts or old invalidation
/// callbacks. An old connection can clean up only the capture it owns.
final class CaptureConnectionOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UUID?
    private var active: UUID?
    private var activeConnectionValid = false

    func attach() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let owner = UUID()
        current = owner
        return owner
    }

    func isCurrent(_ owner: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return current == owner
    }

    /// A live owner must stop or invalidate before a different connection can
    /// start. Replacing a live stream would trigger its automatic reconnect.
    func acceptStart(_ owner: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return current == owner && (active == nil || active == owner || !activeConnectionValid)
    }

    func activate(_ owner: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard current == owner,
              active == nil || active == owner || !activeConnectionValid else { return false }
        active = owner
        activeConnectionValid = true
        return true
    }

    func invalidate(_ owner: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if current == owner { current = nil }
        if active == owner { activeConnectionValid = false }
    }

    func ownsCapture(_ owner: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active == owner
    }

    // The serial capture lifecycle calls this only after releasing its capture.
    func clearActive() {
        lock.lock()
        active = nil
        activeConnectionValid = false
        lock.unlock()
    }
}
