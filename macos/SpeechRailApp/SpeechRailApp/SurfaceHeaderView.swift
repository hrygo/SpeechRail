import SwiftUI
import SpeechRailControlKit

public struct SurfaceHeaderView: View {
    public let route: AppRoute

    public init(route: AppRoute) {
        self.route = route
    }

    public var body: some View {
        PageIntroView(route: route)
    }
}

@available(*, deprecated, message: "Use ServiceStatusBadge in the toolbar or page status banner")
public struct ServiceStatusFooterView: View {
    public init() {}

    public var body: some View {
        ServiceStatusBadge()
            .accessibilityHint("服务状态已移动到页面顶部和工具栏")
    }
}
