import Foundation
import Observation

@MainActor
@Observable
public final class AppNavigationState {
    public static let controlCenterWindowID = "control-center"

    public private(set) var requestedRoute: AppRoute?
    public private(set) var layoutTier: WindowLayoutTier = .expanded
    public private(set) var windowWidth: CGFloat = 1355
    /// 有声书工坊前往「音色创作」或「音色库」时的固定返回上下文。
    public var audiobookVoiceReturnContext: AudiobookVoiceReturnContext?

    public var layoutContract: WindowLayoutContract {
        WindowLayoutPolicy.contract(for: layoutTier)
    }

    public init() {}

    public func request(_ route: AppRoute) {
        requestedRoute = route
    }

    public func requestVoiceDesignForAudiobook(context: AudiobookVoiceReturnContext) {
        audiobookVoiceReturnContext = context
        requestedRoute = .voiceDesign
    }

    public func requestVoiceLibraryForAudiobook(context: AudiobookVoiceReturnContext) {
        audiobookVoiceReturnContext = context
        requestedRoute = .voiceLibrary
    }

    public func consumeRequestedRoute() -> AppRoute? {
        defer { requestedRoute = nil }
        return requestedRoute
    }

    /// 根据当前窗口实时物理宽度，采用双阈值迟滞状态机驱动布局等级迁移。
    /// 阈值集中在 `WindowLayoutPolicy`，因此 AppKit/SwiftUI 入口共享同一份策略。
    public func updateWindowWidth(_ width: CGFloat) {
        guard width > 0 else { return }
        windowWidth = width
        let newTier = WindowLayoutPolicy.nextTier(from: layoutTier, width: width)

        if newTier != layoutTier {
            layoutTier = newTier
        }
    }
}
