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
        case .local: "本地控制通道已就绪"
        case .enabled: "控制 Agent 已启用"
        case .notRegistered: "控制 Agent 未启用"
        case .requiresApproval: "等待系统批准"
        case .notFound: "控制 Agent 未找到"
        case .unknown: "控制 Agent 状态未知"
        }
    }

    public var detail: String {
        switch kind {
        case .local:
            "当前构建使用内嵌 XPC 控制通道。"
        case .enabled:
            "可以执行服务、档位和模型控制操作。"
        case .notRegistered:
            "首次使用控制台前，需要明确启用登录项中的控制 Agent。"
        case .requiresApproval:
            "请在系统设置的登录项中允许 SpeechRail 控制 Agent。"
        case .notFound:
            "应用包中没有找到控制 Agent，请重新安装 SpeechRail。"
        case .unknown:
            "系统没有返回可识别的授权状态，当前控制操作已安全停用。"
        }
    }

    public var impact: String {
        switch kind {
        case .local, .enabled: "控制台操作可用"
        case .notRegistered, .requiresApproval, .notFound, .unknown: "只读诊断可用，变更操作不可用"
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
