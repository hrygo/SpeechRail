import Foundation

public struct AppRouteShortcutSpec: Hashable, Sendable {
    public enum Modifiers: String, Hashable, Sendable {
        case command
        case commandShift
    }

    public let key: String
    public let modifiers: Modifiers

    public init(key: String, modifiers: Modifiers) {
        self.key = key
        self.modifiers = modifiers
    }
}

public enum AppRouteGroup: String, CaseIterable, Sendable {
    case creator
    case session
    case service

    public var title: String {
        switch self {
        case .creator:
            "创作"
        case .session:
            // 它是「用引擎」的事，与「管引擎」的页面不是同一件事，所以独立成组，
            // 且插在创作之后、引擎之前（SESSIONS-SPEC §5.1）。
            "会话"
        case .service:
            // 技术页与服务状态同组，沿用 Figma shell 的分组名（REDESIGN-SPEC §6.1）。
            "引擎"
        }
    }
}

public enum AppRoute: String, CaseIterable, Identifiable, Hashable, Sendable {
    case dubbing
    case voiceDesign
    case voiceClone
    case voiceLibrary
    case works
    case assistant
    case meeting
    case captions
    case teleprompter
    case overview
    case monitoring
    case models
    case diagnostics
    case developerDocs

    public var id: String { rawValue }

    public var group: AppRouteGroup {
        switch self {
        case .dubbing, .voiceDesign, .voiceClone, .voiceLibrary, .works:
            .creator
        case .assistant, .meeting, .captions, .teleprompter:
            .session
        case .overview, .monitoring, .models, .diagnostics, .developerDocs:
            .service
        }
    }

    public var title: String {
        switch self {
        case .dubbing:
            "配音台"
        case .voiceDesign:
            "音色创作"
        case .voiceClone:
            "音色克隆"
        case .voiceLibrary:
            "音色库"
        case .works:
            "我的作品"
        case .assistant:
            "语音助手"
        case .meeting:
            "会议助手"
        case .captions:
            "实时字幕"
        case .teleprompter:
            "AI 提词器"
        case .overview:
            "服务状态"
        case .monitoring:
            "运行监控"
        case .models:
            "模型"
        case .diagnostics:
            "诊断"
        case .developerDocs:
            "开发者文档"
        }
    }

    /// 页首那一句话说明（`PageScaffold(purpose:)` 的默认值），与 Figma `pageHead`
    /// 的第二行逐字一致；运行监控的动态采样状态由页面自己覆盖。
    /// 注意这里只是**说明**：页面名不在这条链上——它在工具栏的身份槽（§6.2）。
    public var pageSubtitle: String {
        switch self {
        case .dubbing:
            "输入文稿、选择音色，直接生成可交付的语音。"
        case .voiceDesign:
            "用一句话描述你想要的音色，从真实预览里挑一个保存进音色库。"
        case .voiceClone:
            "读一段提词稿，用你自己的声音注册一个可复用的音色。"
        case .voiceLibrary:
            "管理系统音色，以及用参考音频复刻出来的音色。"
        case .works:
            "本机生成过的音频都留在这里，可随时播放、导出或删除。"
        case .assistant:
            "用这台 Mac 的语音能力对话：你说、它听、它答。原始音频不留存。"
        case .meeting:
            "边开会边记：谁说了什么、说了哪些要点，都留在本机记录库里。"
        case .captions:
            "字幕带贴在屏幕上看；记录长期留在记录库，这里回看、搜索和导出。"
        case .teleprompter:
            "准备一份稿件，在独立舞台窗口中跟读；直播软件请使用摄像头或目标窗口采集。"
        case .overview:
            "本机语音引擎的当前结论与运行事实。"
        case .monitoring:
            "服务最近在做什么、快不快、占多少内存；实时看最近 5 分钟，也能回看服务落盘的 30 天历史。"
        case .models:
            "先下载并校验，再应用到运行档位；两者是独立操作。"
        case .diagnostics:
            "本机检查的结论与每一步可以照做的修复动作。"
        case .developerDocs:
            "把本机语音能力接入你的应用：地址、接口、示例与排查。"
        }
    }

    public var contextTitle: String {
        group.title
    }

    public var systemImage: String {
        switch self {
        case .dubbing:
            "waveform.and.mic"
        case .voiceDesign:
            "waveform.badge.plus"
        case .voiceClone:
            "mic"
        case .voiceLibrary:
            "music.note.list"
        case .works:
            "square.stack.3d.up"
        case .assistant:
            "message.circle"
        case .meeting:
            "person.2"
        case .captions:
            "captions.bubble"
        case .teleprompter:
            "text.bubble"
        case .overview:
            "server.rack"
        case .monitoring:
            "chart.xyaxis.line"
        case .models:
            "shippingbox"
        case .diagnostics:
            "stethoscope"
        case .developerDocs:
            "book"
        }
    }

    public var shortcutSpec: AppRouteShortcutSpec? {
        switch self {
        case .dubbing:
            .init(key: "1", modifiers: .command)
        case .voiceDesign:
            .init(key: "2", modifiers: .command)
        case .voiceClone:
            .init(key: "3", modifiers: .command)
        case .voiceLibrary:
            .init(key: "4", modifiers: .command)
        case .works:
            .init(key: "5", modifiers: .command)
        case .assistant:
            .init(key: "6", modifiers: .command)
        case .meeting:
            .init(key: "7", modifiers: .command)
        case .captions:
            .init(key: "8", modifiers: .command)
        case .teleprompter:
            .init(key: "t", modifiers: .commandShift)
        case .overview:
            .init(key: "9", modifiers: .command)
        case .monitoring:
            .init(key: "0", modifiers: .command)
        case .models:
            .init(key: "m", modifiers: .commandShift)
        case .diagnostics:
            .init(key: "d", modifiers: .commandShift)
        case .developerDocs:
            .init(key: "h", modifiers: .commandShift)
        }
    }

    public var purpose: String {
        switch self {
        case .dubbing:
            "把保存的音色用于配音工作"
        case .voiceDesign:
            "描述、试听并保存新的音色"
        case .voiceClone:
            "用自己的录音复刻一个音色"
        case .voiceLibrary:
            "管理可复用的已保存音色"
        case .works:
            "回看 SpeechRail 创作的作品"
        case .assistant:
            "和这台 Mac 上的语音助手对话"
        case .meeting:
            "记录会议、标注说话人并生成纪要"
        case .captions:
            "把正在说的话变成屏幕上的字幕"
        case .teleprompter:
            "把自己的稿件放进独立舞台窗口，按讲话进度自动跟读"
        case .overview:
            "确认本机语音服务能否使用"
        case .monitoring:
            "看清服务最近的使用、速度与内存占用"
        case .models:
            "下载并校验模型能力"
        case .diagnostics:
            "解释异常原因和下一步动作"
        case .developerDocs:
            "查阅本机服务的接入方式"
        }
    }

    public static func routes(in group: AppRouteGroup) -> [AppRoute] {
        allCases.filter { $0.group == group }
    }

    /// 这个路由属于哪条会话能力；不是会话页时为 `nil`。
    public var sessionKind: SessionKind? {
        switch self {
        case .assistant: .assistant
        case .meeting: .meeting
        case .captions: .captions
        case .teleprompter: .teleprompter
        default: nil
        }
    }
}
