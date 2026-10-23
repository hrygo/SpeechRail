import Foundation
import Observation
import SpeechRailControlKit

/// 听写会话：切换录制、识别、交付三段状态机。
///
/// 三条硬约束（issue #414）：
///
///   1. **一次只跑一段**。识别/交付未完成时再按热键不排队、不打断，只说明"上一段还在识别"，
///      于是"两次听写交错"在状态层面不可能发生。
///   2. **迟到的结果不落地**。每次开始都换一个会话号，任何 `await` 之后都先核对会话号，
///      旧结果既不会插进新目标，也不会重复插入。
///   3. **识别完成不等于交付成功**。插入失败一律明确降级为"已复制"，并把原因写进状态。
@MainActor
@Observable
public final class DictationSession {
    public enum Phase: Equatable, Sendable {
        case idle
        case recording(DictationTarget)
        case transcribing(DictationTarget)
        case delivering(DictationTarget)
        case finished(DictationOutcome)
        case failed(DictationFailure)

        public var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }

        public var isBusy: Bool {
            switch self {
            case .transcribing, .delivering: true
            default: false
            }
        }
    }

    public private(set) var phase: Phase = .idle
    /// 一段听写结束后的说明（成功或失败）。它只描述刚刚发生的事，不承载队列状态。
    public private(set) var lastOutcome: DictationOutcome?
    public private(set) var lastFailure: DictationFailure?
    /// 热键在忙碌时被忽略的提示；用户下一次按下后清除。
    public private(set) var notice: String?

    private let audio: any DictationAudioCapturing
    private let transcriber: any DictationTranscribing
    private let targets: any DictationTargetResolving
    private let deliverer: any DictationTextDelivering
    private let clipboard: any DictationClipboardStaging
    private var sessionID = UUID()

    public init(
        audio: any DictationAudioCapturing,
        transcriber: any DictationTranscribing,
        targets: any DictationTargetResolving,
        deliverer: any DictationTextDelivering,
        clipboard: any DictationClipboardStaging
    ) {
        self.audio = audio
        self.transcriber = transcriber
        self.targets = targets
        self.deliverer = deliverer
        self.clipboard = clipboard
    }

    /// 热键与菜单的唯一入口：空闲时开始，录制中结束，识别中只提示。
    public func toggle() async {
        switch phase {
        case .idle, .finished, .failed:
            await start()
        case .recording:
            await stop()
        case .transcribing, .delivering:
            notice = "上一段还在识别，完成后会自动交付。"
        }
    }

    public func start() async {
        guard !phase.isRecording, !phase.isBusy else { return }
        notice = nil
        lastOutcome = nil
        lastFailure = nil
        guard let target = await targets.currentTarget() else {
            fail(.noTarget)
            return
        }
        do {
            try await audio.startRecording()
        } catch let error as DictationCaptureError {
            switch error {
            case .permissionDenied:
                fail(.microphoneDenied)
            case let .failed(detail):
                fail(.captureFailed(detail))
            }
            return
        } catch {
            fail(.captureFailed(error.localizedDescription))
            return
        }
        sessionID = UUID()
        phase = .recording(target)
    }

    public func stop() async {
        guard case let .recording(target) = phase else { return }
        let id = sessionID
        phase = .transcribing(target)

        let recording: DictationRecording
        switch await audio.finishRecording() {
        case let .recorded(value):
            recording = value
        case .empty:
            guard isCurrent(id) else { return }
            fail(.emptyTranscript)
            return
        case .tooLong:
            guard isCurrent(id) else { return }
            fail(.tooLong)
            return
        case .cancelled:
            guard isCurrent(id) else { return }
            fail(.cancelled)
            return
        }
        guard isCurrent(id) else { return }
        guard !recording.pcm.isEmpty else {
            fail(.emptyTranscript)
            return
        }
        guard recording.durationSeconds <= DictationLimits.maximumDuration else {
            fail(.tooLong)
            return
        }

        let raw: String
        do {
            raw = try await transcriber.transcribe(recording)
        } catch {
            guard isCurrent(id) else { return }
            fail(Self.failure(for: error))
            return
        }
        guard isCurrent(id) else { return }

        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            fail(.emptyTranscript)
            return
        }

        phase = .delivering(target)
        let attempt = await deliverer.deliver(text, to: target)
        guard isCurrent(id) else { return }

        let delivery: DictationDelivery
        switch attempt {
        case .inserted:
            delivery = .inserted
        case .targetChanged:
            delivery = .copied(.targetChanged)
        case .unsupportedTarget:
            delivery = .copied(.unsupportedTarget)
        case .permissionDenied:
            delivery = .copied(.permissionDenied)
        case .failed:
            delivery = .copied(.insertionFailed)
        }
        if case .copied = delivery {
            await clipboard.stage(Self.clipboardText(text))
        }
        let outcome = DictationOutcome(text: text, target: target, delivery: delivery)
        lastOutcome = outcome
        phase = .finished(outcome)
    }

    /// 录制中取消：不识别、不交付、不留文字。
    public func cancel() async {
        switch phase {
        case .recording:
            sessionID = UUID()
            await audio.cancelRecording()
            fail(.cancelled)
        case .transcribing, .delivering:
            // 已经进入识别/交付的结果不再撤回：那时文字已经冻结，撤回只会制造"半交付"。
            notice = "这一段已经在识别，结束后会给出结果。"
        case .idle, .finished, .failed:
            break
        }
    }

    /// 面板关闭或路由离开时复位展示状态，不影响正在进行的识别。
    public func dismissOutcome() {
        if case .finished = phase { phase = .idle }
        if case .failed = phase { phase = .idle }
        notice = nil
    }

    private func isCurrent(_ id: UUID) -> Bool { sessionID == id }

    private func fail(_ failure: DictationFailure) {
        lastFailure = failure
        phase = .failed(failure)
    }

    /// 剪贴板兜底只写正文本身；超长时截断，避免把整本书塞进别人的剪贴板历史。
    static func clipboardText(_ text: String) -> String {
        guard text.count > DictationLimits.maximumClipboardCharacters else { return text }
        return String(text.prefix(DictationLimits.maximumClipboardCharacters))
    }

    static func failure(for error: Error) -> DictationFailure {
        if let error = error as? ServiceAPIClientError, case let .http(statusCode, code, message, _, _) = error {
            // 批量识别与流式会话共用同一条准入：另一个会话占着引擎时服务端明确说忙。
            if statusCode == 409 || statusCode == 503 || code == "backend_busy" {
                return .serviceBusy(message.isEmpty ? "当前有其它语音会话正在运行" : message)
            }
            return .transcriptionFailed(message.isEmpty ? "服务返回 \(statusCode)" : message)
        }
        return .transcriptionFailed(error.localizedDescription)
    }
}
