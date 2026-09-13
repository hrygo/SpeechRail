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
    public private(set) var health: HealthSnapshot?
    public private(set) var metrics: RuntimeMetricsSnapshot?
    public private(set) var modelCatalog: ModelCatalogSnapshot?
    public private(set) var modelStatus: ModelStatusSnapshot?
    public private(set) var preflightChecks: [PreflightCheckSnapshot] = []
    public private(set) var monitoringSamples: [RuntimeMetricsSample] = []
    public private(set) var message: String?
    public private(set) var isBusy = false

    private let transport: any SpeechRailControlTransport
    private let apiClient: any ServiceDiagnosticsClient
    private let registration: ControlAgentRegistration?

    public init(
        transport: any SpeechRailControlTransport,
        apiClient: any ServiceDiagnosticsClient,
        registration: ControlAgentRegistration? = nil
    ) {
        self.transport = transport
        self.apiClient = apiClient
        self.registration = registration
    }

    public func refresh() async {
        do {
            let snapshot = try await apiClient.fetchHealthSnapshot()
            health = snapshot
            service = ServiceSnapshot(
                serviceState: snapshot.status ?? "unknown",
                ready: snapshot.ready ?? snapshot.asrReady ?? snapshot.ttsReady,
                port: apiClient.port
            )
        } catch {
            health = nil
            service = ServiceSnapshot(serviceState: "unavailable")
        }
        do {
            let list = try await transport.send(ControlRequest(command: .profileList))
            profiles = list.profiles ?? []
            let status = try await transport.send(ControlRequest(command: .profileStatus))
            profile = status.profile
        } catch {
            message = Self.controlErrorMessage(for: error, fallback: "控制 Agent 尚未连接")
        }
    }

    public func refreshModels() async {
        do {
            let catalog = try await transport.send(ControlRequest(command: .modelCatalog))
            if let modelCatalog = catalog.modelCatalog {
                self.modelCatalog = modelCatalog
            }
            let status = try await transport.send(ControlRequest(command: .modelStatus))
            if let modelStatus = status.modelStatus {
                self.modelStatus = modelStatus
            }
        } catch {
            message = Self.controlErrorMessage(for: error, fallback: "模型状态暂时不可用")
        }
    }

    public func refreshMonitoring() async {
        do {
            let snapshot = try await apiClient.fetchHealthSnapshot()
            health = snapshot
            service = ServiceSnapshot(
                serviceState: snapshot.status ?? "unknown",
                ready: snapshot.ready ?? snapshot.asrReady ?? snapshot.ttsReady,
                port: apiClient.port
            )
            let metrics = try await apiClient.fetchMetrics()
            self.metrics = metrics
            monitoringSamples.append(RuntimeMetricsSampler.makeSample(from: metrics))
            if monitoringSamples.count > 60 {
                monitoringSamples.removeFirst(monitoringSamples.count - 60)
            }
        } catch {
            // Monitoring is observational. Keep the last valid sample and let
            // the page explain that the next sample could not be read.
            message = Self.controlErrorMessage(for: error, fallback: "运行数据暂时不可用")
        }
    }

    public func refreshPreflight() async {
        do {
            let response = try await transport.send(ControlRequest(command: .preflight))
            preflightChecks = response.checks ?? []
            if response.status == .failed {
                message = response.message ?? "预检未通过"
            }
        } catch {
            message = Self.controlErrorMessage(for: error, fallback: "预检暂时不可用")
        }
    }

    public func prepareModels(for profile: SpeechRailProfile) async {
        await execute(.modelPrepare, profile: profile)
    }

    public func cancelCurrentOperation() async {
        guard let operationID = operation?.operationID else { return }
        do {
            let response = try await transport.send(
                ControlRequest(command: .operationCancel, operationID: operationID)
            )
            operation = response.operation ?? operation
            if response.status == .failed {
                message = response.message ?? "无法取消操作"
            }
        } catch {
            message = Self.controlErrorMessage(for: error, fallback: "无法取消操作")
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
            try registration?.ensureRegisteredForCurrentBundle()
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
            if command == .modelPrepare {
                await refreshModels()
            }
        } catch {
            message = Self.controlErrorMessage(for: error, fallback: "控制 Agent 不可用")
        }
    }

    private func waitForOperation(_ operationID: String) async {
        let maxPolls = operation?.command == .modelPrepare ? 43_200 : 120
        for _ in 0..<maxPolls {
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
                    if state == .failed || state == .cancelled {
                        message = response.operation?.message ?? response.message ?? "操作失败"
                    }
                    return
                }
            } catch {
                message = Self.controlErrorMessage(for: error, fallback: "无法读取操作状态")
                return
            }
        }
        message = "操作仍在后台运行"
    }

    private static func controlErrorMessage(for error: Error, fallback: String) -> String {
        guard let error = error as? XPCControlTransportError else { return fallback }
        switch error {
        case .timeout:
            return "控制 Agent 响应超时，请重新打开 SpeechRail"
        case let .remote(detail) where !detail.isEmpty:
            return "控制 Agent 不可用：\(detail)"
        default:
            return fallback
        }
    }
}
