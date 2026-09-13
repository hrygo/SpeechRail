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
