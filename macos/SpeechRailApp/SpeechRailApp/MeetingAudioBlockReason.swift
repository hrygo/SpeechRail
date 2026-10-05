import Foundation

/// 采集受阻的原因与错误。**一律给可读结论 + 一个出口**（§6.4 的同一套结论条）。
///
/// 这两个类型原先嵌在 `AudioSourceCoordinator` 里。那个类是 App-only（要碰
/// CoreAudio / AVFoundation），而 `MeetingSession` 要进单测目标就得能看见受阻原因——
/// "麦克风没授权"和"没选来源"是两种完全不同的用户出口，测试必须能分别构造它们。
/// 所以定义在这里，`AudioSourceCoordinator` 那边保留同名嵌套别名，既有调用点不用改。
public enum MeetingAudioBlockReason: Equatable, Sendable {
    case noSourceSelected
    case microphoneDenied
    case systemAudioUnavailable(String)
    case engineFailed(String)

    public var title: String {
        switch self {
        case .noSourceSelected: "还没有选声音从哪来"
        case .microphoneDenied: "麦克风未授权"
        case .systemAudioUnavailable: "本机音频拿不到"
        case .engineFailed: "音频没有开始"
        }
    }

    public var detail: String {
        switch self {
        case .noSourceSelected:
            "这场会要录什么？选「麦克风」（屋里的人）、或勾上一个正在放声音的 App"
                + "（线上的会、正在播的音乐）。两个都选就会自动合到一起。"
        case .microphoneDenied:
            "在系统设置里允许 SpeechRail 使用麦克风，然后回来重试。"
        case .systemAudioUnavailable(let message):
            "\(message)系统第一次会问一次录音权限；拒绝之后就只有麦克风这一路。"
        case .engineFailed(let message):
            message
        }
    }
}

public struct MeetingAudioBlocked: LocalizedError, Equatable, Sendable {
    public var reason: MeetingAudioBlockReason
    public var errorDescription: String? { "\(reason.title)。\(reason.detail)" }

    public init(reason: MeetingAudioBlockReason) {
        self.reason = reason
    }
}
