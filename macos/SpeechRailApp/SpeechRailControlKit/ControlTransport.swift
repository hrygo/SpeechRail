import Foundation

public protocol SpeechRailControlTransport: Sendable {
    func send(_ request: ControlRequest) async throws -> ControlResponse
}

public struct ClosureControlTransport: SpeechRailControlTransport, Sendable {
    private let handler: @Sendable (ControlRequest) async throws -> ControlResponse

    public init(
        handler: @escaping @Sendable (ControlRequest) async throws -> ControlResponse
    ) {
        self.handler = handler
    }

    public func send(_ request: ControlRequest) async throws -> ControlResponse {
        try await handler(request)
    }
}
