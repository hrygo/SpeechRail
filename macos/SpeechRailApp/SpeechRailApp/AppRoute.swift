import Foundation

public enum AppRouteGroup: String, CaseIterable, Sendable {
    case creator
    case service

    public var title: String {
        switch self {
        case .creator:
            "创作"
        case .service:
            // 技术页与服务状态同组，沿用 Figma shell 的分组名（REDESIGN-SPEC §6.1）。
            "引擎"
        }
    }
}

public enum AppRoute: String, CaseIterable, Identifiable, Hashable, Sendable {
    case dubbing
    case voiceDesign
    case voiceLibrary
    case works
    case overview
    case monitoring
    case models
    case diagnostics

    public var id: String { rawValue }

    public var group: AppRouteGroup {
        switch self {
        case .dubbing, .voiceDesign, .voiceLibrary, .works:
            .creator
        case .overview, .monitoring, .models, .diagnostics:
            .service
        }
    }

    public var title: String {
        switch self {
        case .dubbing:
            "配音台"
        case .voiceDesign:
            "音色创作"
        case .voiceLibrary:
            "音色库"
        case .works:
            "我的作品"
        case .overview:
            "服务状态"
        case .monitoring:
            "运行监控"
        case .models:
            "模型"
        case .diagnostics:
            "诊断"
        }
    }

    /// 页头第二行，与 Figma `pageHead` 的副标题逐字一致；运行监控的动态采样
    /// 状态由页面自己覆盖（`PageScaffold(subtitle:)`）。
    public var pageSubtitle: String {
        switch self {
        case .dubbing:
            "输入文稿、选择音色，直接生成可交付的语音。"
        case .voiceDesign:
            "用一句话描述你想要的音色，从真实预览里挑一个保存进音色库。"
        case .voiceLibrary:
            "管理系统音色，以及用参考音频复刻出来的音色。"
        case .works:
            "本机生成过的音频都留在这里，可随时播放、导出或删除。"
        case .overview:
            "本机语音引擎的当前结论与运行事实。"
        case .monitoring:
            "最近的内存样本与刷新间隔。"
        case .models:
            "先下载并校验，再应用到运行档位；两者是独立操作。"
        case .diagnostics:
            "本机自检结论与可执行的修复动作。"
        }
    }

    public var contextTitle: String {
        group.title
    }

    public var workspaceTitle: String {
        switch self {
        case .dubbing:
            "配音台"
        case .voiceDesign:
            "音色创作"
        case .voiceLibrary:
            "音色库"
        case .works:
            "我的作品"
        case .overview:
            "服务状态"
        case .monitoring:
            "运行监控"
        case .models:
            "模型管理"
        case .diagnostics:
            "系统诊断"
        }
    }

    public var systemImage: String {
        switch self {
        case .dubbing:
            "waveform.and.mic"
        case .voiceDesign:
            "waveform.badge.plus"
        case .voiceLibrary:
            "music.note.list"
        case .works:
            "square.stack.3d.up"
        case .overview:
            "server.rack"
        case .monitoring:
            "chart.xyaxis.line"
        case .models:
            "shippingbox"
        case .diagnostics:
            "stethoscope"
        }
    }

    public var purpose: String {
        switch self {
        case .dubbing:
            "把保存的音色用于配音工作"
        case .voiceDesign:
            "描述、试听并保存新的音色"
        case .voiceLibrary:
            "管理可复用的已保存音色"
        case .works:
            "回看 SpeechRail 创作的作品"
        case .overview:
            "确认本机语音服务能否使用"
        case .monitoring:
            "观察请求、延迟和资源状态"
        case .models:
            "下载并校验模型能力"
        case .diagnostics:
            "解释异常原因和下一步动作"
        }
    }

    public static var creatorRoutes: [AppRoute] {
        [.dubbing, .voiceDesign, .voiceLibrary, .works]
    }

    public static var serviceRoutes: [AppRoute] {
        [.overview, .monitoring, .models, .diagnostics]
    }
}
