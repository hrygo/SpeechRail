import Foundation
import SpeechRailControlAgentCore
import SpeechRailControlKit

let runner = ProcessManagedCommandRunner()
let store = AgentOperationStore(runner: runner)
let teamIdentifier = ProcessInfo.processInfo.environment["SPEECHRAIL_DEVELOPMENT_TEAM"] ?? ""
let peerPolicy: XPCPeerPolicy
if !teamIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    peerPolicy = XPCPeerPolicy(
        teamIdentifier: teamIdentifier,
        appIdentifier: ControlConstants.appBundleIdentifier
    )
} else if ProcessInfo.processInfo.environment["SPEECHRAIL_ALLOW_UNSIGNED_XPC"] == "1" {
    // Debug-only local mode. Distribution builds must provide a team identifier.
    peerPolicy = XPCPeerPolicy(developmentAppIdentifier: ControlConstants.appBundleIdentifier)
} else {
    peerPolicy = XPCPeerPolicy(requirement: "")
}
let listener = NSXPCListener(machServiceName: ControlConstants.agentMachServiceName)
let service = XPCControlService(store: store, peerPolicy: peerPolicy)
listener.delegate = service
listener.resume()
RunLoop.current.run()
