import Foundation

// `CaptureHelper`：本机音频采集的宿主进程（`TECHNICAL-DESIGN` §3.2、裁决 `T1`）。
//
// 它的存在只为一件事：**把 tap 与崩溃面从 App 进程里挪出去**。它的生命周期交给
// launchd——App 第一次 `NSXPCConnection(serviceName:)` 时它才起来，App 停采集之后
// 空闲退出（Apple「Creating XPC services」的口径）。所以它自己**不写任何生命周期逻辑**：
// 没有 keep-alive、没有定时器、没有后台任务。
//
// 它做三件事，不做别的：
//   1. 收 `start` → 建 tap 与 aggregate device → 把 40 ms 一块的 PCM 上行；
//   2. 收 `stop` → 释放设备（幂等）；
//   3. 采集自己断了 → 回一条 `captureStopped`，让 App 记一条 `source_lost`。

/// `@unchecked Sendable` 说的不是"可以并发访问"，而是"这里的并发已经由别的东西管住了"：
/// 三处可变状态各有一条明确的归属——`capture` 只被 `queue` 动，`client` 只在
/// `listener` 收连接时写一次（写在 `connection.resume()` 之前，之后的读都在 `queue` 上），
/// `startedAt` 是 `let`。XPC 的 `reply` 块由系统保证"任意线程调用一次"，
/// 但它不是 `Sendable`，所以跨到 `queue` 之前用 `nonisolated(unsafe)` 显式声明一次
/// ——这与 `SessionStore` 里那条注释是同一条口径。
final class CaptureHelperService: NSObject, SpeechRailCaptureHelperProtocol, @unchecked Sendable {
    /// 采集的生命周期串行化：`start` / `stop` 只在这条队列上跑，
    /// 于是"边启边停"不会留下半张设备图。
    private let queue = DispatchQueue(label: "com.speechrail.capture-helper")
    private var capture: CoreAudioTapCapture?
    /// 上行代理**必须强引用**：`remoteObjectProxy` 返回的对象一旦释放，回调就悄悄没了
    /// （这是 XPC 最常见的"调用成功但对面收不到"）。
    private var client: SpeechRailCaptureHelperClientProtocol?

    private let startedAt = Date()

    func attach(client: SpeechRailCaptureHelperClientProtocol) {
        self.client = client
    }

    func start(
        bundleIDs: [String],
        deviceUID: String?,
        label: String,
        reply: @escaping (NSError?) -> Void
    ) {
        nonisolated(unsafe) let reply = reply
        queue.async { [self] in
            // 先停掉上一条：一次连接只应该有一路 tap，重复 start 是调用方的错，
            // 但这里不能让它变成两条 tap 同时往同一处写。
            capture?.stop()
            capture = nil

            let capture = CoreAudioTapCapture(
                configuration: .init(bundleIDs: bundleIDs, outputDeviceUID: deviceUID, name: label)
            )
            nonisolated(unsafe) let client = self.client
            do {
                try capture.start { pcm, level in
                    client?.deliver(pcm: pcm, level: level)
                }
            } catch {
                reply(error as NSError)
                return
            }
            self.capture = capture
            reply(nil)
        }
    }

    func stop(reply: @escaping () -> Void) {
        nonisolated(unsafe) let reply = reply
        queue.async { [self] in
            capture?.stop()
            capture = nil
            reply()
        }
    }

    func status(reply: @escaping (String) -> Void) {
        nonisolated(unsafe) let reply = reply
        queue.async { [self] in
            let uptime = Int(Date().timeIntervalSince(startedAt))
            let running = capture?.isRunningCapture == true ? "在采" : "空闲"
            reply("SpeechRailCaptureHelper · \(running) · 已运行 \(uptime)s")
        }
    }
}

final class CaptureHelperListener: NSObject, NSXPCListenerDelegate {
    private let service = CaptureHelperService()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: SpeechRailCaptureHelperProtocol.self)
        connection.exportedObject = service
        connection.remoteObjectInterface = NSXPCInterface(
            with: SpeechRailCaptureHelperClientProtocol.self
        )
        service.attach(
            client: connection.remoteObjectProxy as? SpeechRailCaptureHelperClientProtocol
                ?? NullCaptureClient()
        )
        connection.invalidationHandler = { [service] in
            // App 走了：采集必须跟着停（按功能启用、功能离开即释放，§3.5）。
            // 这里不接受"等下次连接再来收尾"——那正是常占的形态。
            service.stop {}
        }
        connection.resume()
        return true
    }
}

/// 连接建立之前的占位：XPC 的代理可能尚未就绪，丢掉几块 PCM 远好过崩溃。
private final class NullCaptureClient: NSObject, SpeechRailCaptureHelperClientProtocol {
    func deliver(pcm: Data, level: Double) {}
    func captureStopped(reason: String) {}
}

let listener = NSXPCListener.service()
let delegate = CaptureHelperListener()
listener.delegate = delegate
listener.resume()
