import Foundation

/// 听写的产品语义：一次按下开始、一次按下结束，只交付这一段冻结后的正式文字。
///
/// 与字幕/会议的区别只有一条：**目标不是本 App 的窗口**。所以这里把"目标应用身份"
/// 做成一等值类型，交付前重新核对；识别完成不等于交付成功。
public struct DictationTarget: Equatable, Sendable {
    public let processIdentifier: pid_t
    public let bundleIdentifier: String?
    public let displayName: String

    public init(processIdentifier: pid_t, bundleIdentifier: String?, displayName: String) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }
}

/// 一段听写录音：24 kHz / 单声道 / PCM16，只在内存里活到识别结束。
public struct DictationRecording: Equatable, Sendable {
    public let pcm: Data
    public let sampleRate: Int

    public init(pcm: Data, sampleRate: Int = DictationLimits.sampleRate) {
        self.pcm = pcm
        self.sampleRate = sampleRate
    }

    public var frameCount: Int { pcm.count / 2 }

    public var durationSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(frameCount) / Double(sampleRate)
    }

    /// 识别接口要的是可播放容器，这里补一个最小的 RIFF/WAVE 头。
    public func wavData() -> Data {
        var data = Data(capacity: 44 + pcm.count)
        data.append(contentsOf: "RIFF".utf8)
        var riffSize = UInt32(36 + pcm.count).littleEndian
        data.append(Data(bytes: &riffSize, count: 4))
        data.append(contentsOf: "WAVEfmt ".utf8)
        var fmtChunkSize = UInt32(16).littleEndian
        var audioFormat = UInt16(1).littleEndian
        var channels = UInt16(1).littleEndian
        var rate = UInt32(max(0, sampleRate)).littleEndian
        var byteRate = UInt32(max(0, sampleRate) * 2).littleEndian
        var blockAlign = UInt16(2).littleEndian
        var bitsPerSample = UInt16(16).littleEndian
        data.append(Data(bytes: &fmtChunkSize, count: 4))
        data.append(Data(bytes: &audioFormat, count: 2))
        data.append(Data(bytes: &channels, count: 2))
        data.append(Data(bytes: &rate, count: 4))
        data.append(Data(bytes: &byteRate, count: 4))
        data.append(Data(bytes: &blockAlign, count: 2))
        data.append(Data(bytes: &bitsPerSample, count: 2))
        data.append(contentsOf: "data".utf8)
        var dataChunkSize = UInt32(pcm.count).littleEndian
        data.append(Data(bytes: &dataChunkSize, count: 4))
        data.append(pcm)
        return data
    }
}

public enum DictationLimits {
    public static let sampleRate = 24_000
    /// 一段听写的上限：5 分钟。超限就明确失败，不把半小时的录音塞进一次批量识别。
    public static let maximumDuration: TimeInterval = 300
    /// 5 分钟 × 24 kHz × 2 字节。
    public static let maximumByteCount = Int(maximumDuration) * sampleRate * 2
    /// 交付失败时留在剪贴板里的文字上限，避免把整段长文写进别人的剪贴板历史。
    public static let maximumClipboardCharacters = 20_000
}

/// 交付结果：插入成功，或明确说明为什么只能复制。
public enum DictationDelivery: Equatable, Sendable {
    case inserted
    case copied(DictationCopyReason)

    public var isInserted: Bool { self == .inserted }
}

public enum DictationCopyReason: String, Equatable, Sendable {
    /// 结束时目标应用已经不是开始时的那个。
    case targetChanged
    /// 目标控件不接受文字（非文本输入区、只读文档等）。
    case unsupportedTarget
    /// 没有辅助功能授权，无法代写。
    case permissionDenied
    /// 代写本身失败（控件拒绝、应用无响应等）。
    case insertionFailed
}

public enum DictationDeliveryAttempt: Equatable, Sendable {
    case inserted
    case targetChanged
    case unsupportedTarget
    case permissionDenied
    case failed(String)
}

public struct DictationOutcome: Equatable, Sendable {
    public let text: String
    public let target: DictationTarget
    public let delivery: DictationDelivery

    public init(text: String, target: DictationTarget, delivery: DictationDelivery) {
        self.text = text
        self.target = target
        self.delivery = delivery
    }
}

public enum DictationFailure: Equatable, Sendable {
    case noTarget
    case microphoneDenied
    case captureFailed(String)
    case tooLong
    case emptyTranscript
    case serviceBusy(String)
    case transcriptionFailed(String)
    case cancelled

    public var message: String {
        switch self {
        case .noTarget:
            "没有找到可以输入文字的前台应用。"
        case .microphoneDenied:
            "麦克风未授权；请在系统设置里允许 SpeechRail 使用麦克风。"
        case let .captureFailed(detail):
            "麦克风没有开始采集：\(detail)"
        case .tooLong:
            "这段听写超过 \(Int(DictationLimits.maximumDuration / 60)) 分钟，没有上传识别。"
        case .emptyTranscript:
            "这次没有识别到文字。"
        case let .serviceBusy(detail):
            "语音服务正忙：\(detail)。等当前会话结束后再试。"
        case let .transcriptionFailed(detail):
            "识别没有完成：\(detail)"
        case .cancelled:
            "已取消，没有插入或复制任何文字。"
        }
    }
}

// MARK: - 可替换的边界

/// 采集边界：开始、收尾取走 PCM、取消。实现负责真正释放设备。
public protocol DictationAudioCapturing: AnyObject, Sendable {
    func startRecording() async throws
    func finishRecording() async -> DictationCaptureResult
    func cancelRecording() async
}

/// 采集起步失败。**领域自己的词汇**：系统侧的 `MicrophoneCapture.Failure`
/// 由接线层翻译成这两种，会话层不必认识采集实现。
public enum DictationCaptureError: Error, Equatable, Sendable {
    case permissionDenied
    case failed(String)
}

public enum DictationCaptureResult: Equatable, Sendable {
    case recorded(DictationRecording)
    /// 一句话都没录到（立刻又按了一次）。
    case empty
    /// 超过单段上限，已经在采集侧停掉，不截断成"看起来完整"的半段。
    case tooLong
    case cancelled
}

/// 识别边界：拿到冻结的整段录音，返回正式文字。
public protocol DictationTranscribing: Sendable {
    func transcribe(_ recording: DictationRecording) async throws -> String
}

/// 目标应用解析：只在开始的那一刻解析一次，之后按它核对。
public protocol DictationTargetResolving: Sendable {
    func currentTarget() async -> DictationTarget?
}

/// 交付边界：把文字写进目标应用；实现必须在写入前重新核对目标。
public protocol DictationTextDelivering: Sendable {
    func deliver(_ text: String, to target: DictationTarget) async -> DictationDeliveryAttempt
}

/// 剪贴板兜底：只在插入失败时写入，不自动恢复旧内容（那会覆盖用户后来复制的东西）。
public protocol DictationClipboardStaging: Sendable {
    func stage(_ text: String) async
}
