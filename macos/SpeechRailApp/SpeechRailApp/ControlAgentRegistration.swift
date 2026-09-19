import Foundation
import ServiceManagement
import SpeechRailControlKit

public enum ControlAgentStatusKind: String, Equatable, Sendable {
    case local
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
    case unknown
}

public enum ControlAgentRegistrationAction: String, Equatable, Sendable {
    case none
    case register
    case openLoginItems
    case installAgent
    case unavailable
}

public struct ControlAgentStatusSnapshot: Equatable, Sendable {
    public let kind: ControlAgentStatusKind

    public init(kind: ControlAgentStatusKind) {
        self.kind = kind
    }

    public var title: String {
        switch kind {
        // 这三句是**用户**在这一页要读的结论：说的是"能不能在这里管服务"，
        // 不是"哪条通道起来了"（2026-09-19 离屏走查：原句把 XPC / Agent 摆在首屏）。
        case .local: "可以在这里管理服务"
        case .enabled: "可以在这里管理服务"
        case .notRegistered: "还不能在这里管理服务"
        case .requiresApproval: "等待系统批准"
        case .notFound: "控制组件未找到"
        case .unknown: "控制组件状态未知"
        }
    }

    public var detail: String {
        switch kind {
        case .local:
            "控制通道内嵌在应用里，不需要额外的登录项。"
        case .enabled:
            "登录项里的 SpeechRail 控制组件已启用。"
        case .notRegistered:
            "先去系统设置的「登录项」里允许 SpeechRail，才能在这一页启动或停止服务。"
        case .requiresApproval:
            "去系统设置的「登录项」里允许 SpeechRail。"
        case .notFound:
            "应用包里没有找到控制组件，请重新安装 SpeechRail。"
        case .unknown:
            "系统没有返回可识别的授权状态，当前控制操作已安全停用。"
        }
    }

    public var impact: String {
        switch kind {
        case .local, .enabled: "影响：启动、停止、换档都能用"
        case .notRegistered, .requiresApproval, .notFound, .unknown: "影响：只能看状态，不能改"
        }
    }

    public var allowsMutation: Bool {
        kind == .local || kind == .enabled
    }

    public var action: ControlAgentRegistrationAction {
        switch kind {
        case .local, .enabled: .none
        case .notRegistered: .register
        case .requiresApproval: .openLoginItems
        case .notFound: .installAgent
        case .unknown: .unavailable
        }
    }
}

public enum ControlAgentRegistrationError: Error, Equatable, Sendable {
    case notEnabled(ControlAgentStatusKind)
}

@MainActor
public protocol ControlAgentRegistrationClient: AnyObject {
    var status: ControlAgentStatusKind { get }
    func register() throws
    func unregister() throws
}

@MainActor
public final class ControlAgentRegistration {
    private let client: any ControlAgentRegistrationClient

    public init() {
        client = SystemControlAgentRegistrationClient()
    }

    public init(client: any ControlAgentRegistrationClient) {
        self.client = client
    }

    public var status: ControlAgentStatusKind {
        client.status
    }

    public var statusSnapshot: ControlAgentStatusSnapshot {
        ControlAgentStatusSnapshot(kind: status)
    }

    public var statusText: String {
        statusSnapshot.title
    }

    public func register() throws {
        try client.register()
    }

    public func ensureRegisteredForCurrentBundle() throws {
        guard status == .enabled else {
            throw ControlAgentRegistrationError.notEnabled(status)
        }
    }

    public func reregister() throws {
        guard status == .enabled else {
            throw ControlAgentRegistrationError.notEnabled(status)
        }
        try client.unregister()
        try client.register()
    }

    public func unregister() throws {
        try client.unregister()
    }

    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
private final class SystemControlAgentRegistrationClient: ControlAgentRegistrationClient {
    private let service: SMAppService

    init() {
        service = .agent(plistName: ControlConstants.agentPlistName)
    }

    var status: ControlAgentStatusKind {
        switch service.status {
        case .enabled: .enabled
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }
}
