import SwiftUI
import SpeechRailControlKit

public struct SurfaceHeaderView: View {
    public let route: AppRoute

    public init(route: AppRoute) {
        self.route = route
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            Text(route.group.title)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
            Label(route.title, systemImage: route.systemImage)
                .font(SpeechRailDesignTokens.Typography.pageTitle)
                .foregroundStyle(SpeechRailDesignTokens.Palette.primaryText)
            Text(route.purpose)
                .font(SpeechRailDesignTokens.Typography.secondary)
                .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(route.title)，\(route.purpose)")
    }
}

public struct ServiceStatusFooterView: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Circle()
                .fill(model.service.ready == true ? SpeechRailDesignTokens.Palette.success : SpeechRailDesignTokens.Palette.warning)
                .frame(width: SpeechRailDesignTokens.Spacing.xs, height: SpeechRailDesignTokens.Spacing.xs)
                .accessibilityHidden(true)
            Text(model.service.ready == true ? "服务已就绪" : "服务状态：\(model.service.serviceState)")
                .font(SpeechRailDesignTokens.Typography.caption)
            Spacer()
            if let port = model.service.port {
                Text("端口 \(port)")
                    .font(SpeechRailDesignTokens.Typography.technical)
                    .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        .speechRailSurface(.elevated)
        .accessibilityElement(children: .combine)
    }
}
