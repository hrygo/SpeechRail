import SwiftUI
import SpeechRailControlKit

public struct WorkspaceTitleLockup: View {
    public let route: AppRoute
    public let service: ServiceSnapshot?
    public let health: HealthSnapshot?
    public let healthMessage: String?
    public let operation: ServiceOperationStatus?
    public let controlPlaneMessage: String?

    public init(
        route: AppRoute,
        service: ServiceSnapshot? = nil,
        health: HealthSnapshot? = nil,
        healthMessage: String? = nil,
        operation: ServiceOperationStatus? = nil,
        controlPlaneMessage: String? = nil
    ) {
        self.route = route
        self.service = service
        self.health = health
        self.healthMessage = healthMessage
        self.operation = operation
        self.controlPlaneMessage = controlPlaneMessage
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
                .minimumScaleFactor(0.82)
                .layoutPriority(1)
        }
        .frame(
            maxWidth: SpeechRailDesignTokens.Toolbar.titleMaximumWidth,
            minHeight: SpeechRailDesignTokens.Toolbar.titleHeight,
            alignment: .center
        )
        .contentShape(Rectangle())
        .id(route.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(route.workspaceTitle)
        .accessibilityIdentifier("workspace-title")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        guard route.group == .service, let service else {
            return route.contextTitle
        }
        return "\(route.contextTitle)，\(serviceStatusText(service))"
    }

    private func serviceStatusText(_ service: ServiceSnapshot) -> String {
        if operation?.phase.isActive == true { return "服务操作进行中" }
        if healthMessage != nil { return "健康状态不可用" }
        if controlPlaneMessage != nil { return "控制通道不可用" }
        if health?.ready == true || (health == nil && service.ready == true) {
            return "服务已就绪"
        }
        if service.serviceState == "unavailable" { return "服务不可用" }
        return "服务未就绪"
    }
}

/// Source-compatible wrapper for older call sites while the shared lockup is migrated.
public struct WorkspaceTitleView: View {
    private let route: AppRoute
    private let service: ServiceSnapshot?
    private let health: HealthSnapshot?
    private let healthMessage: String?
    private let operation: ServiceOperationStatus?
    private let controlPlaneMessage: String?

    public init(
        route: AppRoute,
        service: ServiceSnapshot? = nil,
        health: HealthSnapshot? = nil,
        healthMessage: String? = nil,
        operation: ServiceOperationStatus? = nil,
        controlPlaneMessage: String? = nil
    ) {
        self.route = route
        self.service = service
        self.health = health
        self.healthMessage = healthMessage
        self.operation = operation
        self.controlPlaneMessage = controlPlaneMessage
    }

    public var body: some View {
        WorkspaceTitleLockup(
            route: route,
            service: service,
            health: health,
            healthMessage: healthMessage,
            operation: operation,
            controlPlaneMessage: controlPlaneMessage
        )
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

public struct SurfaceHeaderView: View {
    public let route: AppRoute

    public init(route: AppRoute) {
        self.route = route
    }

    public var body: some View {
        PageIntroView(route: route)
    }
}
