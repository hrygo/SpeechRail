import SwiftUI

public struct ServiceRoutePreviewView: View {
    @Environment(AppModel.self) private var model
    public let route: AppRoute

    public init(route: AppRoute) {
        self.route = route
    }

    public var body: some View {
        PageScaffold(route: route) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
                Label("服务状态", systemImage: AppRoute.overview.systemImage)
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                Text("这里是统一的服务页面承载区。运行监控、模型管理和预检诊断会在同一处解释本机服务正在做什么；页面不会伪造没有读取到的运行数据。")
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    Text("当前状态")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    Text(SpeechRailRuntimeStatePresentation.text(model.service.serviceState))
                        .font(SpeechRailDesignTokens.Typography.technical)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.lg)
            .speechRailContentSurface()
        }
    }
}
