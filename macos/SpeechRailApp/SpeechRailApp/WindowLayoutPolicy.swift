import CoreGraphics

/// Window-level layout tiers shared by the control-center shell and session pages.
public enum WindowLayoutTier: String, Sendable, Equatable {
    /// Keep the sidebar, main workspace, and inspector visible together.
    case expanded
    /// Hide the navigation sidebar while keeping the assistant inspector available.
    case medium
    /// Keep only the primary workspace visible; secondary panels remain recoverable.
    case compact
}

/// The shell behavior that a window tier delegates to each panel.
public enum WindowPanelBehavior: String, Equatable, Sendable {
    case visible
    case collapsed
    case pageControlled
}

/// The view-free contract shared by the AppKit shell and session pages.
public struct WindowLayoutContract: Equatable, Sendable {
    public let sidebar: WindowPanelBehavior
    public let inspector: WindowPanelBehavior
    public let minimumPrimaryContentWidth: CGFloat

    public init(
        sidebar: WindowPanelBehavior,
        inspector: WindowPanelBehavior,
        minimumPrimaryContentWidth: CGFloat
    ) {
        self.sidebar = sidebar
        self.inspector = inspector
        self.minimumPrimaryContentWidth = minimumPrimaryContentWidth
    }
}

/// Hysteresis policy for window-resize driven layout changes.
///
/// The policy is pure so threshold behavior can be tested without constructing
/// SwiftUI or AppKit views. The current tier is part of the input because the
/// collapse and restore thresholds intentionally differ.
public enum WindowLayoutPolicy {
    public static let expandedToMediumThreshold: CGFloat = 1_260
    public static let mediumToExpandedThreshold: CGFloat = 1_340
    public static let mediumToCompactThreshold: CGFloat = 960
    public static let compactToMediumThreshold: CGFloat = 1_020

    public static func contract(for tier: WindowLayoutTier) -> WindowLayoutContract {
        switch tier {
        case .expanded:
            WindowLayoutContract(
                sidebar: .visible,
                inspector: .pageControlled,
                minimumPrimaryContentWidth: 500
            )
        case .medium:
            WindowLayoutContract(
                sidebar: .collapsed,
                inspector: .pageControlled,
                minimumPrimaryContentWidth: 500
            )
        case .compact:
            WindowLayoutContract(
                sidebar: .collapsed,
                inspector: .collapsed,
                minimumPrimaryContentWidth: 500
            )
        }
    }

    public static func nextTier(
        from current: WindowLayoutTier,
        width: CGFloat
    ) -> WindowLayoutTier {
        guard width > 0 else { return current }

        switch current {
        case .expanded:
            if width < mediumToCompactThreshold {
                return .compact
            } else if width < expandedToMediumThreshold {
                return .medium
            } else {
                return .expanded
            }
        case .medium:
            if width >= mediumToExpandedThreshold {
                return .expanded
            } else if width < mediumToCompactThreshold {
                return .compact
            } else {
                return .medium
            }
        case .compact:
            if width >= mediumToExpandedThreshold {
                return .expanded
            } else if width >= compactToMediumThreshold {
                return .medium
            } else {
                return .compact
            }
        }
    }
}
