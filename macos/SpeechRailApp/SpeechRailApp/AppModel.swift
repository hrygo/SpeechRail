import Foundation
import Observation
import SpeechRailControlKit

@MainActor
@Observable
public final class AppModel {
    public private(set) var service = ServiceSnapshot(serviceState: "unknown")
    public private(set) var profiles: [ProfileSummary] = []
    public private(set) var profile: ProfileSnapshot?
    public private(set) var operation: OperationSnapshot?
    public private(set) var message: String?
    public private(set) var isBusy = false

    private let transport: any SpeechRailControlTransport
    private let apiClient: ServiceAPIClient
    private let registration: ControlAgentRegistration?

    public init(
        transport: any SpeechRailControlTransport,
        apiClient: ServiceAPIClient,
        registration: ControlAgentRegistration? = nil
    ) {
        self.transport = transport
        self.apiClient = apiClient
        self.registration = registration
    }

    public func refresh() async {
        do {
            service = try await apiClient.fetchHealth()
        } catch {
            service = ServiceSnapshot(serviceState: "unavailable")
        }
        do {
            let list = try await transport.send(ControlRequest(command: .profileList))
            profiles = list.profiles ?? []
            let status = try await transport.send(ControlRequest(command: .profileStatus))
            profile = status.profile
        } catch {
            message = "控制 Agent 尚未连接"
        }
    }

    public func execute(
        _ command: ControlCommand,
        profile selectedProfile: SpeechRailProfile? = nil
    ) async {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        defer { isBusy = false }

        do {
            if let registration, registration.status != .enabled {
                try registration.register()
            }
            let response = try await transport.send(
                ControlRequest(
                    command: command,
                    profile: selectedProfile,
                    confirmation: command.requiresConfirmation
                )
            )
            operation = response.operation
            if response.status == .failed {
                message = response.message ?? "操作失败"
                return
            }
            if let operationID = response.operation?.operationID {
                await waitForOperation(operationID)
            }
            await refresh()
        } catch {
            message = "控制 Agent 不可用"
        }
    }

    private func waitForOperation(_ operationID: String) async {
        for _ in 0..<120 {
            guard !Task.isCancelled else { return }
            do {
                try await Task.sleep(for: .milliseconds(500))
                let response = try await transport.send(
                    ControlRequest(command: .operationStatus, operationID: operationID)
                )
                operation = response.operation
                if let state = response.operation?.state,
                   state == .committed || state == .failed || state == .cancelled
                {
                    return
                }
            } catch {
                message = "无法读取操作状态"
                return
            }
        }
        message = "操作仍在后台运行"
    }
}
