import SwiftUI
import SpeechRailControlKit

public struct WorkspaceTitleLockup: View {
    public let route: AppRoute

    /// REDESIGN-SPEC §6.2：工具栏 principal 只有「这是哪一页」这一个信息，
    /// 单行、固定槽位、尾截断。服务是否就绪由侧边栏底部状态区独家承担
    /// （§6.4 / D9），标题不再重复一遍状态。
    public init(route: AppRoute) {
        self.route = route
    }

    public var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            RouteIconView(
                route: route,
                selected: false,
                presentation: .toolbar
            )
            Text(route.workspaceTitle)
                .font(SpeechRailDesignTokens.Typography.toolbarTitle)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(SpeechRailDesignTokens.Toolbar.titleMinimumScaleFactor)
                .allowsTightening(true)
        }
        .frame(
            width: SpeechRailDesignTokens.Toolbar.titleMaximumWidth,
            height: SpeechRailDesignTokens.Toolbar.titleHeight,
            alignment: .center
        )
        // Keep unusually long localized titles inside the fixed toolbar slot;
        // the text already uses a single line and tail truncation above.
        .clipped()
        .id(route.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(route.workspaceTitle)
        .accessibilityIdentifier("workspace-title")
        .accessibilityValue(route.contextTitle)
    }
}

public enum RouteIconPresentation: Sendable {
    case navigation
    case toolbar
}

public struct RouteIconView: View {
    public let route: AppRoute
    public let selected: Bool
    public let presentation: RouteIconPresentation

    public init(
        route: AppRoute,
        selected: Bool,
        presentation: RouteIconPresentation = .navigation
    ) {
        self.route = route
        self.selected = selected
        self.presentation = presentation
    }

    public var body: some View {
        Image(systemName: route.systemImage)
            .font(.system(size: iconSize, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(selected ? SpeechRailDesignTokens.Navigation.selectedForeground : foregroundColor)
            .frame(
                width: iconFrame,
                height: iconFrame
            )
            .accessibilityHidden(true)
    }

    private var iconSize: CGFloat {
        switch presentation {
        case .navigation:
            SpeechRailDesignTokens.Icon.navigationSize
        case .toolbar:
            SpeechRailDesignTokens.Icon.toolbarSize
        }
    }

    private var iconFrame: CGFloat {
        switch presentation {
        case .navigation:
            SpeechRailDesignTokens.Icon.navigationFrame
        case .toolbar:
            SpeechRailDesignTokens.Icon.toolbarFrame
        }
    }

    private var foregroundColor: Color {
        switch presentation {
        case .navigation:
            SpeechRailDesignTokens.Navigation.secondaryForeground
        case .toolbar:
            SpeechRailDesignTokens.Color.inkSecondary
        }
    }
}
