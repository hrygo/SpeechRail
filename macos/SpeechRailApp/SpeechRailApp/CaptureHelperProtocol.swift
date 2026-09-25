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
//   2. **上行只有 PCM 与电平**。每一块就是 40 ms 的 24 kHz 单声道 PCM16；
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
        reply: @escaping (NSError?) -> Void
    )

    /// 停采集并释放 tap / aggregate device。**幂等**：没起来过也能调。
    func stop(reply: @escaping () -> Void)

    /// 诊断用：helper 的一次一句话状态。
    func status(reply: @escaping (String) -> Void)
}

/// helper → App。helper 侧的 `remoteObjectProxy` 就是这个协议。
@objc public protocol SpeechRailCaptureHelperClientProtocol {
    /// 一块 PCM（24 kHz / 单声道 / PCM16）+ 这一块的真实电平（0…1）。
    func deliver(pcm: Data, level: Double)

    /// 采集**自己停下来了**（来源 App 全退、设备被拔、tap 失效）。
    /// 这不是错误而是一个事实：`source_lost` 的中断区间就是由它记下的（§5.6）。
    func captureStopped(reason: String)
}

/// XPC 服务名。它必须与 `Resources/XPCServices/<name>.xpc/Contents/Info.plist` 的
/// `CFBundleIdentifier` 一致：`NSXPCConnection(serviceName:)` 按名字在 App bundle 的
/// `Contents/XPCServices` 里找这个包（Apple「Creating XPC services」的口径）。
public enum CaptureHelperConstants {
    public static let serviceName = "com.speechrail.desktop.capture-helper"
    public static let executableName = "SpeechRailCaptureHelper"
}
