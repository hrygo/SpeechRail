import Foundation
import SpeechRailControlAgentCore
import SpeechRailControlKit

let runner = ProcessManagedCommandRunner()
let store = AgentOperationStore(runner: runner)
let teamIdentifier = ProcessInfo.processInfo.environment["SPEECHRAIL_DEVELOPMENT_TEAM"] ?? ""
let peerPolicy = XPCPeerPolicy(
    teamIdentifier: teamIdentifier,
    appIdentifier: ControlConstants.appBundleIdentifier
)
let listener = NSXPCListener(machServiceName: ControlConstants.agentMachServiceName)
let service = XPCControlService(store: store, peerPolicy: peerPolicy)
listener.delegate = service
listener.resume()
RunLoop.current.run()
