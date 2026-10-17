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

    public static let audiobookInlineCastColumnMinimumWidth: CGFloat = 1_120
    /// 当左侧章节目录栏被收起时，仅需保障主画布最小可读宽度（500pt）+ 间距 + 右栏检查器（360pt），内联阈值降至 880pt。
    public static let audiobookInlineCastColumnCollapsedSidebarMinimumWidth: CGFloat = 880

    public static func audiobookShowsInlineCastColumn(
        forWidth width: CGFloat,
        isChapterSidebarCollapsed: Bool = false,
        isCastInspectorCollapsed: Bool = false
    ) -> Bool {
        guard !isCastInspectorCollapsed else { return false }
        let threshold = isChapterSidebarCollapsed
            ? audiobookInlineCastColumnCollapsedSidebarMinimumWidth
            : audiobookInlineCastColumnMinimumWidth
        return width >= threshold
    }

    /// 遵循“自动准备、关键处确认”原则：计算阶段切换时右侧人物与声音检查器的推荐折叠态。
    /// - 当存在用户手动显隐偏好（`userOverride`）时，严格尊重用户选择；
    /// - 在 `.preparation`（准备与角色）阶段默认展开（`false`），便于对照原文确认说话人与试听配声；
    /// - 在 `.production`（制作与返修）阶段，若全书无待确认说话人且已完成配声确认，则自动收起右侧人物栏（`true`），聚焦「章节目录 + 音频片段流」两栏制作；若仍有待确认项或尚未确认配声，则保持展开以便即时处理。
    public static func audiobookRecommendedCastInspectorCollapsed(
        forTab workbenchTab: AudiobookWorkflowModel.WorkbenchTab,
        hasUnresolvedUnknownSpeakers: Bool,
        isCastConfirmed: Bool,
        userOverride: Bool? = nil
    ) -> Bool {
        if let userOverride {
            return userOverride
        }
        switch workbenchTab {
        case .preparation:
            return false
        case .production:
            return !hasUnresolvedUnknownSpeakers && isCastConfirmed
        }
    }
}
