import AppKit
import ApplicationServices
import Foundation
import SpeechRailControlKit

// 听写需要的四处系统接线：麦克风、前台应用、辅助功能代写、剪贴板兜底。
//
// 四条都不含业务判断——"能不能开始""要不要复制"都在 `DictationSession` 里，
// 这里只负责把系统事实翻译成会话认识的值。

// MARK: - 麦克风

/// 麦克风 → 一段 24 kHz / 单声道 / PCM16。
///
/// 复用字幕/会议同一个 `MicrophoneCapture`（权限口径、24 kHz 归一、停止时真正释放设备），
/// 差别只在这里把 PCM 攒进内存而不是送 WebSocket。攒到上限就停采集并报"太长"，
/// 不截断成一段看起来完整的录音。
public final class MicrophoneDictationCapture: DictationAudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var capture: MicrophoneCapture?
    private var pump: Task<Void, Never>?
    private var buffer = Data()
    private var overflowed = false
    private var cancelled = false

    public init() {}

    public func startRecording() async throws {
        let source = MicrophoneCapture()
        let stream: AudioChunkStream
        do {
            stream = try await source.start()
        } catch let error as MicrophoneCapture.Failure {
            // 系统事实 → 领域词汇：会话层只关心"没授权"和"起不来"两种。
            switch error {
            case .permissionDenied:
                throw DictationCaptureError.permissionDenied
            case .engineFailed, .converterUnavailable:
                throw DictationCaptureError.failed(error.localizedDescription)
            }
        }
        lock.withLock {
            capture = source
            buffer = Data(capacity: DictationLimits.sampleRate * 2 * 30)
            overflowed = false
            cancelled = false
        }
        pump = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                for try await chunk in stream {
                    guard let self else { return }
                    guard self.append(chunk.pcm) else {
                        // 到上限就**真的停采集**，不是只停止消费：否则麦克风会一直开着，
                        // 用户看到"已停止"而设备还在工作。
                        await self.stopCapture()
                        return
                    }
                }
            } catch {
                // 采集侧的错误由 `finishRecording` 的空结果表达，不在这里另造状态。
            }
        }
    }

    /// 只停设备，不动缓冲区：上限触发与正常收尾都走这里，`MicrophoneCapture.stop()` 本身幂等。
    private func stopCapture() async {
        let source = lock.withLock { capture }
        await source?.stop()
    }

    private func append(_ pcm: Data) -> Bool {
        lock.withLock {
            guard buffer.count + pcm.count <= DictationLimits.maximumByteCount else {
                overflowed = true
                return false
            }
            buffer.append(pcm)
            return true
        }
    }

    public func finishRecording() async -> DictationCaptureResult {
        let (source, pump) = lock.withLock { (capture, self.pump) }
        await source?.stop()
        await pump?.value
        let snapshot = lock.withLock { () -> (Data, Bool, Bool) in
            let value = (buffer, overflowed, cancelled)
            buffer = Data()
            capture = nil
            self.pump = nil
            overflowed = false
            cancelled = false
            return value
        }
        if snapshot.2 { return .cancelled }
        if snapshot.1 { return .tooLong }
        guard !snapshot.0.isEmpty else { return .empty }
        return .recorded(DictationRecording(pcm: snapshot.0))
    }

    public func cancelRecording() async {
        lock.withLock { cancelled = true }
        _ = await finishRecording()
    }
}

// MARK: - 前台应用

/// 开始的那一刻记下前台应用；结束交付前再核对一次。
public struct FrontmostApplicationTargetResolver: DictationTargetResolving {
    public init() {}

    public func currentTarget() async -> DictationTarget? {
        await MainActor.run {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            // 自己在前台时说明用户还没切到目标应用，此时不该开始。
            guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
            return DictationTarget(
                processIdentifier: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                displayName: app.localizedName ?? app.bundleIdentifier ?? "前台应用"
            )
        }
    }
}

// MARK: - 辅助功能代写

/// 把文字写进目标应用当前焦点控件。
///
/// 顺序是"先插入到选区、再整段替换"，两条都不成立就明确返回不可写：
/// 宁可让用户看到"已复制"，也不要在不支持文字的地方假装插入成功。
public struct AccessibilityDictationDeliverer: DictationTextDelivering {
    public init() {}

    public func deliver(_ text: String, to target: DictationTarget) async -> DictationDeliveryAttempt {
        await MainActor.run { Self.deliverOnMain(text, target: target) }
    }

    private static func deliverOnMain(_ text: String, target: DictationTarget) -> DictationDeliveryAttempt {
        guard AXIsProcessTrusted() else { return .permissionDenied }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier == target.processIdentifier
        else { return .targetChanged }

        let app = AXUIElementCreateApplication(target.processIdentifier)
        var focusedRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRaw) == .success,
              let focusedRaw
        else { return .unsupportedTarget }
        let element = focusedRaw as! AXUIElement

        if AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success {
            return .inserted
        }

        guard let replaced = replacingSelection(in: element, with: text) else {
            return .unsupportedTarget
        }
        if AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            replaced as CFTypeRef
        ) == .success {
            return .inserted
        }
        return .failed("目标控件不接受写入")
    }

    /// 读全文与选区，把选区换成新文字。任何一步读不到就返回 nil（不猜位置）。
    private static func replacingSelection(in element: AXUIElement, with text: String) -> String? {
        var valueRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRaw) == .success,
              let value = valueRaw as? String
        else { return nil }

        var rangeRaw: CFTypeRef?
        var range = CFRange(location: 0, length: 0)
        if AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRaw
        ) == .success, let rangeRaw,
           CFGetTypeID(rangeRaw) == AXValueGetTypeID(),
           AXValueGetValue(rangeRaw as! AXValue, .cfRange, &range) {
            // 有选区：替换选区。
        } else {
            // 没有选区：插到末尾。
            range = CFRange(location: (value as NSString).length, length: 0)
        }

        let nsValue = value as NSString
        guard range.location >= 0,
              range.length >= 0,
              range.location + range.length <= nsValue.length
        else { return nil }
        return nsValue.replacingCharacters(
            in: NSRange(location: range.location, length: range.length),
            with: text
        )
    }
}

// MARK: - 剪贴板

/// 只在交付失败时写入正文。**不暂存、不自动恢复旧剪贴板**：
/// 听写结束后用户可能马上复制了别的东西，一次迟到的恢复会把它冲掉。
public struct PasteboardDictationClipboard: DictationClipboardStaging {
    public init() {}

    public func stage(_ text: String) async {
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }
}

// MARK: - 识别

/// 批量识别：停止后整段上传，只取正式文字。
///
/// 与字幕/会议共用同一条服务准入（同一台机器一次只跑一个重计算任务），
/// 冲突时服务端返回忙，会话层据此给出"等当前会话结束"的明确提示。
public struct ServiceDictationTranscriber: DictationTranscribing {
    private let client: ServiceAPIClient

    public init(client: ServiceAPIClient) {
        self.client = client
    }

    public func transcribe(_ recording: DictationRecording) async throws -> String {
        let response = try await client.transcribe(
            TranscriptionRequest(
                audio: recording.wavData(),
                filename: "dictation.wav",
                contentType: "audio/wav",
                model: RealtimeASRClient.canonicalASRModel
            )
        )
        return response.text
    }
}
