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
    private let machServiceName: String
    private let codeSigningRequirement: String?

    public init(
        machServiceName: String = ControlConstants.agentMachServiceName,
        codeSigningRequirement: String? = nil
    ) {
        self.machServiceName = machServiceName
        self.codeSigningRequirement = codeSigningRequirement
        super.init()
    }

    public func send(_ request: ControlRequest) async throws -> ControlResponse {
        do {
            try request.validate()
        } catch let error as ControlProtocolError {
            throw error
        }
        let encodedRequest = try ControlWireCodec.encode(request)
        let connection = NSXPCConnection(machServiceName: machServiceName, options: [])
        if let codeSigningRequirement {
            connection.setCodeSigningRequirement(codeSigningRequirement)
        }
        connection.remoteObjectInterface = NSXPCInterface(with: SpeechRailControlXPCProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<ControlResponse, Error>) in
            let continuationBox = ContinuationBox(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuationBox.resume(
                    throwing: XPCControlTransportError.remote(error.localizedDescription)
                )
            }
            guard let proxy = proxy as? SpeechRailControlXPCProtocol else {
                continuationBox.resume(throwing: XPCControlTransportError.invalidProxy)
                return
            }
            proxy.send(encodedRequest) { responseData, error in
                if let error {
                    continuationBox.resume(
                        throwing: XPCControlTransportError.remote(error.localizedDescription)
                    )
                    return
                }
                guard let responseData else {
                    continuationBox.resume(throwing: XPCControlTransportError.invalidResponse)
                    return
                }
                do {
                    let response = try ControlWireCodec.decode(ControlResponse.self, from: responseData)
                    guard response.schemaVersion == ControlConstants.schemaVersion,
                          response.requestID == request.requestID,
                          response.command == request.command
                    else {
                        continuationBox.resume(
                            throwing: XPCControlTransportError.invalidResponse
                        )
                        return
                    }
                    continuationBox.resume(returning: response)
                } catch {
                    continuationBox.resume(throwing: XPCControlTransportError.invalidResponse)
                }
            }
        }
    }
}

private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: CheckedContinuation<ControlResponse, Error>
    private var didResume = false

    init(_ continuation: CheckedContinuation<ControlResponse, Error>) {
        self.continuation = continuation
    }

    func resume(returning response: ControlResponse) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()
        continuation.resume(returning: response)
    }

    func resume(throwing error: Error) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()
        continuation.resume(throwing: error)
    }
}
