import SwiftUI
import SpeechRailControlKit

public struct WorkspaceTitleLockup: View {
    public let route: AppRoute
    public let service: ServiceSnapshot?

    public init(route: AppRoute, service: ServiceSnapshot? = nil) {
        self.route = route
        self.service = service
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            titleVariant(includeIcon: true, includeContext: true)
                .fixedSize(horizontal: true, vertical: false)
            titleVariant(includeIcon: true, includeContext: false)
                .fixedSize(horizontal: true, vertical: false)
            minimalTitleVariant
        }
        .frame(
            maxWidth: SpeechRailDesignTokens.Toolbar.titleMaximumWidth,
            minHeight: SpeechRailDesignTokens.Toolbar.titleHeight,
            alignment: .center
        )
        .clipped()
        .id(route.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(route.workspaceTitle)
        .accessibilityIdentifier("workspace-title")
        .accessibilityValue(accessibilityValue)
    }

    private var minimalTitleVariant: some View {
        Text(route.workspaceTitle)
            .font(SpeechRailDesignTokens.Typography.toolbarTitle)
            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func titleVariant(includeIcon: Bool, includeContext: Bool) -> some View {
        HStack(spacing: SpeechRailDesignTokens.Toolbar.itemSpacing) {
            if includeIcon {
                RouteIconView(
                    route: route,
                    selected: false,
                    presentation: .toolbar
                )
            }
            Text(route.workspaceTitle)
                .font(SpeechRailDesignTokens.Typography.toolbarTitle)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            if includeContext {
                Text("·")
                    .font(SpeechRailDesignTokens.Typography.workspaceContext)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .accessibilityHidden(true)
                Text(route.contextTitle)
                    .font(SpeechRailDesignTokens.Typography.workspaceContext)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityHidden(true)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var accessibilityValue: String {
        guard route.group == .service, let service else {
            return route.contextTitle
        }
        return "\(route.contextTitle)，\(serviceStatusText(service))"
    }

    private func serviceStatusText(_ service: ServiceSnapshot) -> String {
        if service.ready == true { return "服务已就绪" }
        if service.serviceState == "unavailable" { return "服务不可用" }
        return "服务未就绪"
    }
}

/// Source-compatible wrapper for older call sites while the shared lockup is migrated.
public struct WorkspaceTitleView: View {
    private let route: AppRoute
    private let service: ServiceSnapshot?

    public init(route: AppRoute, service: ServiceSnapshot? = nil) {
        self.route = route
        self.service = service
    }

    public var body: some View {
        WorkspaceTitleLockup(route: route, service: service)
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
            .font(.system(size: iconSize, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(
                selected
                    ? SpeechRailDesignTokens.Navigation.selectedForeground
                    : SpeechRailDesignTokens.Color.inkSecondary
            )
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
}

public struct SurfaceHeaderView: View {
    public let route: AppRoute

    public init(route: AppRoute) {
        self.route = route
    }

    public var body: some View {
        PageIntroView(route: route)
    }
}
