import Foundation

@objc public protocol SpeechRailControlXPCProtocol {
    func send(_ request: Data, reply: @escaping (Data?, NSError?) -> Void)
}

public enum XPCControlTransportError: Error, Equatable, Sendable {
    case invalidProxy
    case connectionInterrupted
    case connectionInvalidated
    case remote(String)
    case invalidResponse
}

public final class NSXPCControlTransport: NSObject, SpeechRailControlTransport, @unchecked Sendable {
    private let connection: NSXPCConnection

    public init(
        machServiceName: String = ControlConstants.agentMachServiceName,
        codeSigningRequirement: String? = nil
    ) {
        let connection = NSXPCConnection(machServiceName: machServiceName, options: [])
        if let codeSigningRequirement {
            connection.setCodeSigningRequirement(codeSigningRequirement)
        }
        connection.remoteObjectInterface = NSXPCInterface(with: SpeechRailControlXPCProtocol.self)
        connection.resume()
        self.connection = connection
        super.init()
    }

    deinit {
        connection.invalidate()
    }

    public func send(_ request: ControlRequest) async throws -> ControlResponse {
        do {
            try request.validate()
        } catch let error as ControlProtocolError {
            throw error
        }
        let encodedRequest = try ControlWireCodec.encode(request)
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<ControlResponse, Error>) in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: XPCControlTransportError.remote(error.localizedDescription))
            }
            guard let proxy = proxy as? SpeechRailControlXPCProtocol else {
                continuation.resume(throwing: XPCControlTransportError.invalidProxy)
                return
            }
            proxy.send(encodedRequest) { responseData, error in
                if let error {
                    continuation.resume(
                        throwing: XPCControlTransportError.remote(error.localizedDescription)
                    )
                    return
                }
                guard let responseData else {
                    continuation.resume(throwing: XPCControlTransportError.invalidResponse)
                    return
                }
                do {
                    let response = try ControlWireCodec.decode(ControlResponse.self, from: responseData)
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: XPCControlTransportError.invalidResponse)
                }
            }
        }
    }
}
