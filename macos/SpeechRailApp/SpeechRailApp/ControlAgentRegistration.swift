import Foundation
import ServiceManagement

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

    public func unregister() throws {
        try service.unregister()
    }
}
