import Foundation
import SpeechRailControlKit

public final class XPCControlService: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let store: AgentOperationStore
    private let peerPolicy: XPCPeerPolicy

    public init(store: AgentOperationStore, peerPolicy: XPCPeerPolicy) {
        self.store = store
        self.peerPolicy = peerPolicy
        super.init()
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard peerPolicy.isConfigured else {
            return false
        }
        newConnection.setCodeSigningRequirement(peerPolicy.requirement)
        newConnection.exportedInterface = NSXPCInterface(with: SpeechRailControlXPCProtocol.self)
        newConnection.exportedObject = RequestHandler(store: store)
        newConnection.resume()
        return true
    }
}

private final class RequestHandler: NSObject, SpeechRailControlXPCProtocol, @unchecked Sendable {
    private let store: AgentOperationStore

    init(store: AgentOperationStore) {
        self.store = store
    }

    func send(_ requestData: Data, reply: @escaping (Data?, NSError?) -> Void) {
        let replyBox = ReplyBox(reply)
        Task { [store, replyBox] in
            let response: ControlResponse
            do {
                let request = try ControlWireCodec.decode(ControlRequest.self, from: requestData)
                response = await store.handle(request)
            } catch {
                response = .failure(
                    for: ControlRequest(command: .status),
                    code: .invalidRequest,
                    message: "invalid control request"
                )
            }
            do {
                replyBox.call(try ControlWireCodec.encode(response), nil)
            } catch {
                replyBox.call(nil, NSError(domain: "SpeechRailControl", code: 1))
            }
        }
    }
}

private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private let reply: (Data?, NSError?) -> Void
    private var didReply = false

    init(_ reply: @escaping (Data?, NSError?) -> Void) {
        self.reply = reply
    }

    func call(_ data: Data?, _ error: NSError?) {
        lock.lock()
        guard !didReply else {
            lock.unlock()
            return
        }
        didReply = true
        lock.unlock()
        reply(data, error)
    }
}
