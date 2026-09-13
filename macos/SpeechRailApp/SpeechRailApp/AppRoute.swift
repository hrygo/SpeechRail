import Foundation

public enum AppRouteGroup: String, CaseIterable, Sendable {
    case creator
    case service

    public var title: String {
        switch self {
        case .creator:
            "创作"
        case .service:
            "服务"
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
            "本机服务总览"
        case .monitoring:
            "运行监控"
        case .models:
            "模型管理"
        case .diagnostics:
            "预检与诊断"
        }
    }

    public var systemImage: String {
        switch self {
        case .dubbing:
            "text.bubble"
        case .voiceDesign:
            "waveform.badge.magic"
        case .voiceLibrary:
            "books.vertical"
        case .works:
            "folder"
        case .overview:
            "rectangle.3.group"
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
