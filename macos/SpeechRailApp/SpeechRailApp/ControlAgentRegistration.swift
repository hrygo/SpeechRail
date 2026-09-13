import Foundation
import ServiceManagement
import SpeechRailControlKit
import CryptoKit

@MainActor
public final class ControlAgentRegistration {
    private let service: SMAppService

    public init() {
        service = .agent(plistName: ControlConstants.agentPlistName)
    }

    public var status: SMAppService.Status {
        service.status
    }

    public var statusText: String {
        switch status {
        case .notRegistered: "未注册"
        case .enabled: "已启用"
        case .requiresApproval: "等待系统批准"
        case .notFound: "未找到"
        @unknown default: "未知"
        }
    }

    public func register() throws {
        try service.register()
    }

    public func ensureRegisteredForCurrentBundle() throws {
        let fingerprint = try helperFingerprint()
        let storedFingerprint = UserDefaults.standard.string(forKey: fingerprintKey)
        let fingerprintChanged = storedFingerprint != fingerprint
        if status == .enabled {
            if fingerprintChanged {
                try reregister()
            }
        } else {
            if fingerprintChanged {
                // A failed item can be reported as notRegistered after launchd
                // removes it. Best-effort unregister clears that stale record.
                try? unregister()
            }
            try register()
        }
        UserDefaults.standard.set(fingerprint, forKey: fingerprintKey)
    }

    public func reregister() throws {
        if status == .enabled {
            try service.unregister()
        }
        try service.register()
    }

    public func unregister() throws {
        try service.unregister()
    }

    private let fingerprintKey = "SpeechRail.control-agent.fingerprint"

    private func helperFingerprint() throws -> String {
        let bundleURL = Bundle.main.bundleURL
        let relativePaths = [
            "Contents/MacOS/SpeechRail",
            "Contents/Resources/SpeechRailControlAgent",
            "Contents/Frameworks/SpeechRailControlKit.framework/Versions/A/SpeechRailControlKit",
            "Contents/Frameworks/SpeechRailControlAgentCore.framework/Versions/A/SpeechRailControlAgentCore",
            "Contents/Library/LaunchAgents/\(ControlConstants.agentPlistName)",
        ]
        var data = Data()
        for relativePath in relativePaths {
            let component = try Data(
                contentsOf: bundleURL.appendingPathComponent(relativePath)
            )
            data.append(component)
            data.append(0)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
