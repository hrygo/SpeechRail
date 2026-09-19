import CoreGraphics
import Foundation
import Observation

/// 窗口响应式布局阶梯（中央单一权威数据源，消除子视图双重测量引发的抖动）
public enum WindowLayoutTier: String, Sendable, Equatable {
    /// 宽屏全景（Window Width ≥ 1360 pt）：边栏(240) + 主工作台(720+) + 辅助面板(360)全部并排从容容纳
    case expanded
    /// 标准中屏（860 pt ≤ Window Width < 1360 pt）：
    /// 【核心策略】：优先收起左侧主边栏！释放 240pt 空间，主工作台完全不受任何挤压变小，辅助面板保留
    case medium
    /// 紧凑窄屏（Window Width < 860 pt）：双侧收起，主工作台单栏全景对讲
    case compact
}

@MainActor
@Observable
public final class AppNavigationState {
    public static let controlCenterWindowID = "control-center"

    public private(set) var requestedRoute: AppRoute?
    public private(set) var layoutTier: WindowLayoutTier = .expanded
    public private(set) var windowWidth: CGFloat = 1355

    public init() {}

    public func request(_ route: AppRoute) {
        requestedRoute = route
    }

    public func consumeRequestedRoute() -> AppRoute? {
        defer { requestedRoute = nil }
        return requestedRoute
    }

    /// 根据当前窗口实时物理宽度，采用双阈值迟滞状态机驱动布局等级迁移
    public func updateWindowWidth(_ width: CGFloat) {
        guard width > 0 else { return }
        windowWidth = width
        let newTier: WindowLayoutTier
        switch layoutTier {
        case .expanded:
            // 只要离开大宽屏（< 1280pt），立刻优先收起边栏！
            if width < 1280 {
                newTier = .medium
            } else {
                newTier = .expanded
            }
        case .medium:
            // 只有当重新拉大至 1360pt 以上时才展开边栏（80pt 迟滞缓冲，杜绝临界抖动）
            if width >= 1360 {
                newTier = .expanded
            } else if width < 860 {
                newTier = .compact
            } else {
                newTier = .medium
            }
        case .compact:
            // 只有当拉大至 940pt 以上时才恢复辅助面板（80pt 缓冲）
            if width >= 940 {
                newTier = .medium
            } else {
                newTier = .compact
            }
        }

        if newTier != layoutTier {
            layoutTier = newTier
        }
    }
}
