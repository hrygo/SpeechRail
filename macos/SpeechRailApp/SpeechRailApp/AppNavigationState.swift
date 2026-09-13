import Observation

@MainActor
@Observable
public final class AppNavigationState {
    public static let controlCenterWindowID = "control-center"

    public private(set) var requestedRoute: AppRoute?

    public init() {}

    public func request(_ route: AppRoute) {
        requestedRoute = route
    }

    public func consumeRequestedRoute() -> AppRoute? {
        defer { requestedRoute = nil }
        return requestedRoute
    }
}
