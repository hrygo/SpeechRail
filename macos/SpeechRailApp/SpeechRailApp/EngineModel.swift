import Foundation
import Observation
import SpeechRailControlKit

@MainActor
public protocol EngineCapabilityReading: AnyObject {
    var capabilityFacade: AppCapabilityFacade { get }
    var discoveryState: CapabilityDiscoveryState { get }
    var safeVoiceCatalog: SafeVoiceList? { get }
    var effectiveCapabilities: EffectiveCapabilitySnapshot? { get }
    func refreshDiscovery() async
    func speechRequestOptions(for voiceID: String) async throws -> SpeechRailRequestOptions
}

/// Owns engine observations, capability identity and control operations.
@MainActor
@Observable
public final class EngineModel: EngineCapabilityReading {

    public init(
        transport: any SpeechRailControlTransport,
        apiClient: any ServiceDiagnosticsClient,
        discoveryClient: (any ServiceCapabilityDiscoveryClient)? = nil,
        observabilityLocation: ObservabilityLocation = .default,
        registration: ControlAgentRegistration? = nil
    ) {
        self.transport = transport
        self.apiClient = apiClient
        self.discoveryClient = discoveryClient ?? UnavailableServiceCapabilityDiscoveryClient()
        self.observabilityLocation = observabilityLocation
        self.registration = registration
        self.controlAgentStatus = registration?.statusSnapshot ?? ControlAgentStatusSnapshot(kind: .local)
    }

    public private(set) var service = ServiceSnapshot(serviceState: "unknown")
    /// 服务端口行的 `host` 部分：`ServiceSnapshot` 只带端口，主机名由诊断客户端给出。
    public var serviceConnectionHost: String? { apiClient.connectionHost }
    public private(set) var profiles: [ProfileSummary] = []
    public private(set) var profile: ProfileSnapshot?
    public private(set) var operation: OperationSnapshot?
    public private(set) var health: HealthSnapshot?
    public private(set) var metrics: RuntimeMetricsSnapshot?
    public private(set) var modelCatalog: ModelCatalogSnapshot?
    public private(set) var modelStatus: ModelStatusSnapshot?
    public private(set) var modelAvailability: ModelAvailabilityState = .unknown
    public private(set) var preflightChecks: [PreflightCheckSnapshot] = []
    public private(set) var preflightMessage: String?
    public private(set) var lastPreflightRefresh: Date?
    public private(set) var preflightRequestID: UUID?
    public private(set) var monitoringSamples: [RuntimeMetricsSample] = []
    /// 服务落盘的历史指标（`state/metrics-rollup`）。App 自己的采样只覆盖 5 分钟，
    /// 「上周快不快」这类问题只能由这份数据回答；它跨服务重启保留。
    public private(set) var monitoringHistory: MetricsHistory?
    public private(set) var message: String?
    public private(set) var monitoringMessage: String? = nil
    public private(set) var monitoringHistoryMessage: String? = nil
    public private(set) var healthMessage: String? = nil
    public private(set) var healthFailure: ServiceHealthFailureKind? = nil
    public private(set) var controlPlaneMessage: String? = nil
    private var hasControlPlaneObservation = false
    public var controlConnectionSummary: String {
        guard hasControlPlaneObservation else { return "未读取" }
        return controlPlaneMessage == nil ? "已响应" : "不可用"
    }
    public var jobQueueSummary: String {
        guard healthFailure == nil, let ready = health?.jobSpoolReady else { return "未读取" }
        return ready ? "可用" : "未就绪"
    }
    public private(set) var metricsMessage: String? = nil
    public private(set) var lastHealthRefresh: Date?
    public private(set) var lastMetricsRefresh: Date?
    public private(set) var isBusy = false
    public private(set) var isRefreshingService = false
    public private(set) var isRefreshingModels = false
    public private(set) var isRefreshingMonitoring = false
    public private(set) var isRefreshingMonitoringHistory = false
    public private(set) var isRefreshingPreflight = false
    public private(set) var controlAgentStatus: ControlAgentStatusSnapshot
    public private(set) var serviceOperation: ServiceOperationStatus?
    /// The effective snapshot is the only capability and revision source.
    public private(set) var effectiveCapabilities: EffectiveCapabilitySnapshot?
    public private(set) var safeVoiceCatalog: SafeVoiceList?
    public private(set) var discoveryState: CapabilityDiscoveryState = .idle
    public private(set) var discoveryMetadata: ServiceResponseMetadata?
    public private(set) var isRefreshingDiscovery = false
    public var capabilityFacade: AppCapabilityFacade {
        AppCapabilityFacade(snapshot: effectiveCapabilities, discoveryState: discoveryState)
    }

    public var hasActiveMutation: Bool {
        guard let state = operation?.state else { return false }
        return state == .accepted || state == .running
    }

    /// 会话占用时的切档拦截原因（识别中 / 朗读中 / 制作中）。
    ///
    /// 由 App 装配层注入：会话进行中切档会重启本地服务并丢开正在跑的模型，
    /// 所以这里**排队而不是偷偷热切**，并且要给出「下一步做什么」。
    /// `nil` 表示现在可以切。
    public var sessionActivity: (@MainActor () -> String?)?

    /// 当前是否被会话占用挡住切档；挡住时返回给用户的那句人话。
    public var profileSwitchBlockedReason: String? {
        sessionActivity?()
    }

    private let transport: any SpeechRailControlTransport
    private let apiClient: any ServiceDiagnosticsClient
    private let discoveryClient: any ServiceCapabilityDiscoveryClient
    private let observabilityLocation: ObservabilityLocation
    private let registration: ControlAgentRegistration?
    private var healthRefreshGeneration: UInt64 = 0
    private var metricsRefreshGeneration: UInt64 = 0
    private var monitoringHistoryGeneration: UInt64 = 0
    private var discoveryRefreshGeneration: UInt64 = 0
    /// 模型准备的操作代数：`execute` / `cancelCurrentOperation` / `refreshModels`
    /// 每次进入都会递增。取消链在发起时记住自己的代数，等待与刷新期间一旦有更新
    /// 入口 bump，就自认过期、不再落地状态，避免覆盖更新的终态（issue #88）。
    private var operationGeneration: UInt64 = 0
    /// 模型数据的刷新代际：并发刷新时只有最新一代可以落地，旧读取不得覆盖新结果（issue #87）。
    private var modelRefreshGeneration: UInt64 = 0
    /// 预检读取的刷新代际（issue #87）。
    private var preflightRefreshGeneration: UInt64 = 0
    /// 共享 `message` 的代际令牌：刷新 / 操作入口开始时 bump，使过期链已写或待写的
    /// 文案失效，过期链的写入一律丢弃（issue #87）。
    private var messageGeneration: UInt64 = 0
    private var capabilitySnapshotStore = CapabilitySnapshotStore()
    private var safeVoiceCatalogETag: String?

    public func realtimeCapabilityBinding(for voiceID: String? = nil) async -> RealtimeCapabilityBinding? {
        if let binding = capabilityFacade.realtimeBinding(for: voiceID) {
            return binding
        }
        await refreshDiscovery()
        return capabilityFacade.realtimeBinding(for: voiceID)
    }

    public func speechRequestOptions(for voiceID: String) async throws -> SpeechRailRequestOptions {
        if let options = capabilityFacade.speechRequestOptions(for: voiceID) {
            return options
        }

        await refreshDiscovery()
        guard let options = capabilityFacade.speechRequestOptions(for: voiceID) else {
            throw SpeechBindingUnavailableError(unauthorized: discoveryState == .unauthorized)
        }
        return options
    }

    /// 读取一次同代的 capability snapshot 与安全音色目录。
    ///
    /// 能力快照是唯一的跨对象发现真相；ETag/304 只复用上一份完整快照，加载中和
    /// 失败时不会把旧结论清空，也不会用 legacy `/v1/models` 伪造一个新的 snapshot。
    public func refreshDiscovery() async {
        discoveryRefreshGeneration &+= 1
        let refreshGeneration = discoveryRefreshGeneration
        isRefreshingDiscovery = true
        defer {
            if refreshGeneration == discoveryRefreshGeneration {
                isRefreshingDiscovery = false
            }
        }
        let requestToken = capabilitySnapshotStore.beginRefresh()
        discoveryState = .loading
        let cachedSnapshot = capabilitySnapshotStore.snapshot
        let etag = capabilitySnapshotStore.etag

        do {
            let response = try await discoveryClient.fetchEffectiveCapabilities(
                ifNoneMatch: etag,
                cachedValue: cachedSnapshot
            )
            guard refreshGeneration == discoveryRefreshGeneration else { return }
            capabilitySnapshotStore.apply(response, requestToken: requestToken)
            effectiveCapabilities = capabilitySnapshotStore.snapshot
            discoveryState = capabilitySnapshotStore.state
            discoveryMetadata = response.metadata
        } catch is CancellationError {
            guard refreshGeneration == discoveryRefreshGeneration else { return }
            discoveryState = effectiveCapabilities == nil ? .idle : .loaded
            return
        } catch {
            guard refreshGeneration == discoveryRefreshGeneration else { return }
            applyDiscoveryFailure(error, requestToken: requestToken)
        }

        // The safe voice list is an independent, minimal-disclosure projection. A
        // failure here must not replace an otherwise valid effective snapshot.
        do {
            let response = try await discoveryClient.fetchSafeVoices(
                ifNoneMatch: safeVoiceCatalogETag,
                cachedValue: safeVoiceCatalog
            )
            guard refreshGeneration == discoveryRefreshGeneration else { return }
            if let value = response.value {
                safeVoiceCatalog = value
                safeVoiceCatalogETag = response.metadata.etag ?? safeVoiceCatalogETag
            }
        } catch is CancellationError {
            return
        } catch {
            // Keep the last safe catalog. The atomic capability state above is
            // still authoritative and carries its own diagnostic metadata.
        }
    }

    private func applyDiscoveryFailure(
        _ error: Error,
        requestToken: UInt64
    ) {
        let contractError: ServiceAPIClientError
        switch error {
        case let error as ServiceAPIClientError:
            contractError = error
        case let error as ServiceContractDecodingError:
            contractError = .invalidContract(String(describing: error))
        default:
            contractError = .requestFailed
        }

        if let statusCode = contractError.statusCode, statusCode == 404 || statusCode == 405 {
            capabilitySnapshotStore.markUnsupported(requestToken: requestToken)
        } else {
            capabilitySnapshotStore.markFailure(contractError, requestToken: requestToken)
        }
        effectiveCapabilities = capabilitySnapshotStore.snapshot
        discoveryState = capabilitySnapshotStore.state
    }

    public func refresh() async {
        guard !isRefreshingService else { return }
        isRefreshingService = true
        defer { isRefreshingService = false }
        healthRefreshGeneration &+= 1
        let refreshGeneration = healthRefreshGeneration
        refreshControlAgentStatus()
        let messageGeneration = beginMessageGeneration()
        do {
            let snapshot = try await apiClient.fetchHealthSnapshot()
            guard refreshGeneration == healthRefreshGeneration else { return }
            health = snapshot
            healthMessage = nil
            healthFailure = nil
            lastHealthRefresh = Date()
            service = ServiceSnapshot(
                serviceState: snapshot.status ?? "unknown",
                ready: Self.serviceReady(from: snapshot),
                port: apiClient.port
            )
        } catch is CancellationError {
            return
        } catch {
            guard refreshGeneration == healthRefreshGeneration else { return }
            healthFailure = Self.healthFailureKind(for: error)
            healthMessage = Self.healthFailureMessage(for: error)
            service = ServiceSnapshot(serviceState: "unavailable", port: apiClient.port)
        }
        // 能力结论只读 effective snapshot；失败时保留健康快照，但不准入需要能力的动作。
        await refreshDiscovery()
        do {
            let list = try await transport.send(ControlRequest(command: .profileList))
            guard refreshGeneration == healthRefreshGeneration else { return }
            let status = try await transport.send(ControlRequest(command: .profileStatus))
            guard refreshGeneration == healthRefreshGeneration else { return }
            profiles = list.profiles ?? []
            profile = status.profile
            hasControlPlaneObservation = true
            controlPlaneMessage = nil
            setMessage(nil, generation: messageGeneration)
        } catch is CancellationError {
            return
        } catch {
            guard refreshGeneration == healthRefreshGeneration else { return }
            hasControlPlaneObservation = true
            controlPlaneMessage = Self.controlErrorMessage(for: error, fallback: "控制 Agent 尚未连接")
            setMessage(controlPlaneMessage, generation: messageGeneration)
        }
    }

    /// Refresh model existence and runtime usage from the same point in time.
    ///
    /// Model catalog/status comes from the control Agent while lifecycle usage
    /// comes from the service health endpoint. Keeping this orchestration
    /// explicit prevents the model page from presenting a fresh disk state
    /// beside a stale ASR/TTS worker state.
    public func refreshModelsAndHealth() async {
        await refresh()
        await refreshModels()
    }

    public func refreshModels() async {
        operationGeneration &+= 1
        await refreshModels(
            expectedGeneration: operationGeneration,
            messageGeneration: beginMessageGeneration()
        )
    }

    /// - Parameter expectedGeneration: 发起这次刷新的操作链所持有的操作代数。等待响应期间
    ///   只要有更新的 execute / cancel / refresh 入口 bump 过代数，这次刷新就不再落地，
    ///   过期的取消链因此无法覆盖新状态（issue #88）。
    /// - Parameter messageGeneration: 写入共享 `message` 时持有的文案代际；被更新的刷新
    ///   bump 后不得再落地（issue #87）。
    private func refreshModels(
        expectedGeneration: UInt64,
        messageGeneration: UInt64
    ) async {
        guard expectedGeneration == operationGeneration else { return }
        modelRefreshGeneration &+= 1
        let refreshGeneration = modelRefreshGeneration
        isRefreshingModels = true
        defer {
            if refreshGeneration == modelRefreshGeneration {
                isRefreshingModels = false
            }
        }
        refreshControlAgentStatus()
        do {
            let catalog = try await transport.send(ControlRequest(command: .modelCatalog))
            guard expectedGeneration == operationGeneration,
                  refreshGeneration == modelRefreshGeneration
            else { return }
            guard !handleModelResponseFailure(catalog, messageGeneration: messageGeneration) else {
                return
            }
            guard let catalogSnapshot = catalog.modelCatalog else {
                markModelUnavailable(
                    state: .failed,
                    message: "模型目录暂时不可用",
                    messageGeneration: messageGeneration
                )
                return
            }
            let status = try await transport.send(ControlRequest(command: .modelStatus))
            guard expectedGeneration == operationGeneration,
                  refreshGeneration == modelRefreshGeneration
            else { return }
            guard !handleModelResponseFailure(status, messageGeneration: messageGeneration) else {
                return
            }
            guard let statusSnapshot = status.modelStatus else {
                markModelUnavailable(
                    state: .notReady,
                    message: "模型状态暂时不可用",
                    messageGeneration: messageGeneration
                )
                return
            }
            modelCatalog = catalogSnapshot
            modelStatus = statusSnapshot
            modelAvailability = .available
            if let activeOperation = statusSnapshot.activeOperation {
                operation = activeOperation
            } else if operation?.command == .modelPrepare {
                switch operation?.state {
                case .some(.accepted), .some(.running),
                     .some(.failed), .some(.cancelled), .some(.interrupted):
                    break
                default:
                    operation = nil
                }
            }
            if let warning = status.message, !warning.isEmpty {
                setMessage(warning, generation: messageGeneration)
            } else {
                setMessage(nil, generation: messageGeneration)
            }
        } catch is CancellationError {
            return
        } catch {
            guard expectedGeneration == operationGeneration,
                  refreshGeneration == modelRefreshGeneration
            else { return }
            modelCatalog = nil
            modelStatus = nil
            preserveRecoverableModelOperation()
            modelAvailability = .failed
            setMessage(
                Self.controlErrorMessage(for: error, fallback: "模型状态暂时不可用"),
                generation: messageGeneration
            )
        }
    }

    public func refreshControlAgentStatus() {
        controlAgentStatus = registration?.statusSnapshot
            ?? ControlAgentStatusSnapshot(kind: .local)
    }

    public func enableControlAgent() {
        guard let registration else { return }
        refreshControlAgentStatus()
        guard controlAgentStatus.kind == .notRegistered else { return }
        let messageGeneration = beginMessageGeneration()
        do {
            try registration.register()
            refreshControlAgentStatus()
            setMessage(controlAgentStatus.title, generation: messageGeneration)
        } catch {
            setMessage(
                "无法启用控制 Agent：\(Self.controlAgentErrorMessage(for: error))",
                generation: messageGeneration
            )
        }
    }

    public func openControlAgentSettings() {
        registration?.openLoginItemsSettings()
    }

    /// 本机落盘产物（历史指标、日志）的位置，供页面显示与排障。
    public var observability: ObservabilityLocation { observabilityLocation }

    public func refreshMonitoring() async {
        guard !isRefreshingMonitoring else { return }
        isRefreshingMonitoring = true
        defer { isRefreshingMonitoring = false }
        healthRefreshGeneration &+= 1
        let healthGeneration = healthRefreshGeneration
        metricsRefreshGeneration &+= 1
        let metricsGeneration = metricsRefreshGeneration
        var healthReadFailed = false

        do {
            let snapshot = try await apiClient.fetchHealthSnapshot()
            guard healthGeneration == healthRefreshGeneration else { return }
            health = snapshot
            healthMessage = nil
            healthFailure = nil
            lastHealthRefresh = Date()
            service = ServiceSnapshot(
                serviceState: snapshot.status ?? "unknown",
                ready: Self.serviceReady(from: snapshot),
                port: apiClient.port
            )
        } catch is CancellationError {
            return
        } catch {
            guard healthGeneration == healthRefreshGeneration else { return }
            healthFailure = Self.healthFailureKind(for: error)
            healthMessage = Self.healthFailureMessage(for: error)
            service = ServiceSnapshot(serviceState: "unavailable", port: apiClient.port)
            healthReadFailed = true
        }

        do {
            let metrics = try await apiClient.fetchMetrics()
            guard healthGeneration == healthRefreshGeneration,
                  metricsGeneration == metricsRefreshGeneration
            else { return }
            self.metrics = metrics
            metricsMessage = nil
            lastMetricsRefresh = Date()
            let capturedAt = Date()
            monitoringSamples.append(
                RuntimeMetricsSampler.makeSample(
                    from: metrics,
                    capturedAt: capturedAt,
                    previous: monitoringSamples.last
                )
            )
            if monitoringSamples.count > 60 {
                monitoringSamples.removeFirst(monitoringSamples.count - 60)
            }
            // health and metrics are independent observations. A fresh
            // metrics sample must not make a failed health read look healthy.
            monitoringMessage = healthReadFailed ? healthMessage : nil
        } catch is CancellationError {
            return
        } catch {
            // Monitoring is observational. Keep the last valid sample and let
            // the page explain that the next sample could not be read.
            guard healthGeneration == healthRefreshGeneration,
                  metricsGeneration == metricsRefreshGeneration
            else { return }
            metricsMessage = Self.controlErrorMessage(for: error, fallback: "运行数据暂时不可用")
            let messages = [healthMessage, metricsMessage].compactMap { $0 }
            monitoringMessage = messages.isEmpty
                ? "运行数据暂时不可用"
                : messages.joined(separator: "；")
        }
    }

    /// 读取服务落盘的历史指标（`state/metrics-rollup`）。
    ///
    /// 走文件而不是 HTTP 是有意的：这份数据跨服务重启保留，所以服务刚换版重启、
    /// 甚至停着的时候，历史仍然看得到；代价是路径按服务的落盘约定解析。
    /// 读盘放到后台（30 天约 4 万行），主线程只接结果。
    public func refreshMonitoringHistory(
        windowSeconds: Double,
        bucketSeconds: Double? = nil,
        now: Date = Date()
    ) async {
        let location = observabilityLocation
        monitoringHistoryGeneration &+= 1
        let generation = monitoringHistoryGeneration
        isRefreshingMonitoringHistory = true
        defer { isRefreshingMonitoringHistory = false }
        let history = await Task.detached(priority: .utility) {
            MetricsHistoryLoader.load(
                directory: location.historyDirectory,
                now: now,
                windowSeconds: windowSeconds,
                bucketSeconds: bucketSeconds
            )
        }.value
        guard generation == monitoringHistoryGeneration else { return }
        monitoringHistory = history
        monitoringHistoryMessage = history.directoryExists
            ? nil
            : "服务还没有写过历史指标；它每次运行会往 \(history.directoryPath) 追加 60 秒一行。"
    }

    public func refreshPreflight() async {
        preflightRefreshGeneration &+= 1
        let refreshGeneration = preflightRefreshGeneration
        isRefreshingPreflight = true
        defer {
            if refreshGeneration == preflightRefreshGeneration {
                isRefreshingPreflight = false
            }
        }
        refreshControlAgentStatus()
        preflightMessage = nil
        preflightRequestID = nil
        do {
            let response = try await transport.send(ControlRequest(command: .preflight))
            guard refreshGeneration == preflightRefreshGeneration else { return }
            preflightRequestID = response.requestID
            lastPreflightRefresh = Date()
            // A response without checks is still a new observation. Never
            // leave the previous run visible beside a failed/empty result.
            preflightChecks = response.checks ?? []
            if response.status == .failed {
                preflightMessage = response.message ?? "预检未通过"
            }
        } catch is CancellationError {
            return
        } catch {
            guard refreshGeneration == preflightRefreshGeneration else { return }
            preflightChecks = []
            preflightMessage = Self.controlErrorMessage(for: error, fallback: "预检暂时不可用")
        }
    }

    /// 下载并校验一对规格要用的制品；不改变服务运行态。
    public func prepareModels(_ selection: SpecSelection) async {
        await execute(.modelPrepare, selection: selection)
    }

    public func cancelCurrentOperation() async {
        guard canExecuteMutation(for: .operationCancel) else { return }
        guard let operationID = operation?.operationID else { return }
        operationGeneration &+= 1
        let generation = operationGeneration
        let messageGeneration = beginMessageGeneration()
        setMessage("正在停止模型准备…", generation: messageGeneration)
        do {
            let response = try await transport.send(
                ControlRequest(command: .operationCancel, operationID: operationID)
            )
            guard generation == operationGeneration else { return }
            operation = response.operation ?? operation
            if response.status == .failed {
                setMessage(response.message ?? "无法取消操作", generation: messageGeneration)
            } else if response.operation?.phase?.lowercased() == "cancelling" {
                if case .superseded = await waitForOperation(
                    operationID,
                    generation: generation,
                    messageGeneration: messageGeneration
                ) {
                    return
                }
                await refreshModels(
                    expectedGeneration: generation,
                    messageGeneration: beginMessageGeneration()
                )
            } else if response.status == .cancelled {
                setMessage("模型准备已取消", generation: messageGeneration)
            } else {
                // 确认收到但既无 cancelling 相位也无终态快照（如旧 UI 测试替身）：
                // 刷新一次，别把「正在停止…」的待定文案永久留在界面上。
                await refreshModels(
                    expectedGeneration: generation,
                    messageGeneration: beginMessageGeneration()
                )
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == operationGeneration else { return }
            setMessage(
                Self.controlErrorMessage(for: error, fallback: "无法取消操作"),
                generation: messageGeneration
            )
        }
    }

    public func execute(
        _ command: ControlCommand,
        selection: SpecSelection? = nil
    ) async {
        guard !isBusy else { return }
        guard canExecuteMutation(for: command) else { return }
        operationGeneration &+= 1
        isBusy = true
        let messageGeneration = beginMessageGeneration()
        let serviceMutation = Self.serviceOperationPhase(for: command)
        if let serviceMutation {
            serviceOperation = ServiceOperationStatus(
                command: command,
                phase: serviceMutation
            )
        }
        defer { isBusy = false }

        do {
            if command.isMutation {
                try registration?.ensureRegisteredForCurrentBundle()
            }
            let response = try await transport.send(
                ControlRequest(
                    command: command,
                    selection: selection,
                    confirmation: command.requiresConfirmation
                )
            )
            operation = response.operation
            if response.status == .failed
                || response.status == .cancelled
                || response.status == .rolledBack
            {
                let fallbackMessage = response.status == .cancelled ? "操作已取消" : "操作未完成"
                let failureMessage = response.message ?? fallbackMessage
                setMessage(failureMessage, generation: messageGeneration)
                if serviceMutation != nil {
                    serviceOperation = ServiceOperationStatus(
                        command: command,
                        phase: .failed,
                        message: failureMessage
                    )
                }
                return
            }
            if let operationID = response.operation?.operationID {
                // 服务变更的等待不传 operation generation：服务启停永远优先于模型刷新，
                // 日常 refreshModels 的 bump 不得把一次服务变更的终态处理打成 superseded，
                // 否则 serviceOperation 会卡在进行中（issue #88 评审决议）。
                switch await waitForOperation(
                    operationID,
                    messageGeneration: messageGeneration
                ) {
                case .committed:
                    break
                case .failed:
                    if serviceMutation != nil {
                        serviceOperation = ServiceOperationStatus(
                            command: command,
                            phase: .failed,
                            message: SpeechRailOperationMessagePresentation.text(
                                message ?? "操作未完成"
                            )
                        )
                    }
                    if command == .modelPrepare {
                        await refreshModels()
                    }
                    return
                case .stillRunning:
                    if let serviceMutation {
                        serviceOperation = ServiceOperationStatus(
                            command: command,
                            phase: serviceMutation,
                            message: "操作仍在后台运行，请稍后重新读取。"
                        )
                    }
                    return
                case .cancelled:
                    // Local task cancellation only stops this client's wait;
                    // it does not claim that the remote operation was undone.
                    return
                case .superseded:
                    return
                }
            }
            if serviceMutation != nil {
                serviceOperation = ServiceOperationStatus(
                    command: command,
                    phase: .healthChecking,
                    message: "命令已完成，正在读取最新服务状态…"
                )
            }
            await refresh()
            if serviceMutation != nil {
                await refreshPreflight()
            }
            if serviceMutation != nil {
                let message = healthMessage == nil
                    ? "服务命令已完成，状态已刷新。"
                    : "服务命令已完成，但健康检查暂时不可用，请重新读取。"
                serviceOperation = ServiceOperationStatus(
                    command: command,
                    phase: .completed,
                    message: message
                )
            }
            if command == .modelPrepare {
                await refreshModels()
            }
        } catch is CancellationError {
            return
        } catch {
            let failureMessage = Self.controlErrorMessage(for: error, fallback: "控制 Agent 不可用")
            setMessage(failureMessage, generation: messageGeneration)
            if serviceMutation != nil {
                serviceOperation = ServiceOperationStatus(
                    command: command,
                    phase: .failed,
                    message: failureMessage
                )
            }
        }
    }

    private func waitForOperation(
        _ operationID: String,
        generation: UInt64? = nil,
        messageGeneration: UInt64
    ) async -> OperationWaitResult {
        let maxPolls = operation?.command == .modelPrepare ? 43_200 : 120
        for _ in 0..<maxPolls {
            if let generation, generation != operationGeneration { return .superseded }
            guard !Task.isCancelled else { return .cancelled }
            do {
                try await Task.sleep(for: .milliseconds(500))
                if let generation, generation != operationGeneration { return .superseded }
                let response = try await transport.send(
                    ControlRequest(command: .operationStatus, operationID: operationID)
                )
                if let generation, generation != operationGeneration { return .superseded }
                operation = response.operation
                if let state = response.operation?.state,
                   state == .committed || state == .failed || state == .cancelled || state == .interrupted
                {
                    if state == .failed || state == .cancelled || state == .interrupted {
                        setMessage(
                            response.operation?.message ?? response.message ?? "操作失败",
                            generation: messageGeneration
                        )
                        return .failed
                    }
                    return .committed
                }
            } catch is CancellationError {
                return .cancelled
            } catch {
                setMessage(
                    Self.controlErrorMessage(for: error, fallback: "无法读取操作状态"),
                    generation: messageGeneration
                )
                return .failed
            }
        }
        setMessage("操作仍在后台运行", generation: messageGeneration)
        return .stillRunning
    }

    private static func controlErrorMessage(for error: Error, fallback: String) -> String {
        if let error = error as? ControlAgentRegistrationError {
            return controlAgentErrorMessage(for: error)
        }
        guard let error = error as? XPCControlTransportError else { return fallback }
        switch error {
        case .timeout:
            return "控制 Agent 响应超时，请重新打开 SpeechRail"
        case .remote:
            return "控制 Agent 不可用，请重新打开 SpeechRail 或运行诊断"
        default:
            return fallback
        }
    }

    private static func healthFailureKind(for error: Error) -> ServiceHealthFailureKind {
        guard let error = error as? ServiceAPIClientError else {
            return .connection
        }
        switch error {
        case .requestTimedOut:
            return .timeout
        case .invalidResponse:
            return .invalidResponse
        case .notModifiedWithoutCache:
            return .connection
        case .invalidContract:
            return .invalidResponse
        case let .http(_, code, _, _, _):
            return .server(code: code)
        case .invalidURL, .requestFailed:
            return .connection
        }
    }

    private static func healthFailureMessage(for error: Error) -> String {
        guard let error = error as? ServiceAPIClientError else {
            return "无法连接本机 SpeechRail 服务，请先启动服务或运行预检。"
        }
        switch error {
        case .invalidURL:
            return "服务地址无效，请打开诊断检查本机配置。"
        case .requestFailed:
            return "无法连接本机 SpeechRail 服务，请先启动服务或运行预检。"
        case .requestTimedOut:
            return "服务健康检查超时，可能正在启动或负载较高，请稍后重新读取。"
        case .invalidResponse:
            return "服务返回无法识别的健康状态，请运行预检检查版本和运行时。"
        case .notModifiedWithoutCache:
            return "服务健康缓存已失效，请重新读取后重试。"
        case .invalidContract:
            return "服务返回的契约版本无法识别，请运行预检检查版本。"
        case let .http(_, code, _, _, _):
            switch code {
            case "backend_not_ready":
                return "服务已连接，但语音运行时尚未就绪，请运行预检查看阻塞项。"
            case "service_unavailable":
                return "服务已连接，但当前运行时不可用，请打开诊断查看恢复路径。"
            default:
                return "服务健康检查未通过，请打开诊断查看恢复路径。"
            }
        }
    }

    private static func controlAgentErrorMessage(for error: Error) -> String {
        guard let error = error as? ControlAgentRegistrationError else {
            return "系统授权状态不可用"
        }
        switch error {
        case let .notEnabled(kind):
            return ControlAgentStatusSnapshot(kind: kind).detail
        }
    }

    @discardableResult
    private func handleModelResponseFailure(
        _ response: ControlResponse,
        messageGeneration: UInt64
    ) -> Bool {
        guard response.status == .failed else { return false }
        let state: ModelAvailabilityState = switch response.errorCode {
        case .unsupported:
            .unsupported
        case .managedRuntimeMissing, .serviceUnavailable, .transportUnavailable, .modelUnavailable:
            .notReady
        default:
            .failed
        }
        let fallback = state == .unsupported
            ? "模型管理暂不可用：服务组件版本不匹配"
            : "模型状态暂时不可用"
        markModelUnavailable(
            state: state,
            message: response.message ?? fallback,
            messageGeneration: messageGeneration
        )
        return true
    }

    private func markModelUnavailable(
        state: ModelAvailabilityState,
        message: String,
        messageGeneration: UInt64
    ) {
        modelCatalog = nil
        modelStatus = nil
        preserveRecoverableModelOperation()
        modelAvailability = state
        setMessage(message, generation: messageGeneration)
    }

    private func preserveRecoverableModelOperation() {
        guard operation?.command == .modelPrepare else { return }
        switch operation?.state {
        case .some(.accepted), .some(.running),
             .some(.failed), .some(.cancelled), .some(.interrupted):
            break
        default:
            operation = nil
        }
    }

    /// 开启一个新的共享文案代际：使此前写入的文案失效，并返回本次代际供写入方持有。
    private func beginMessageGeneration() -> UInt64 {
        messageGeneration &+= 1
        message = nil
        return messageGeneration
    }

    /// 只在调用方仍持有最新文案代际时落地；过期链的写入被静默丢弃（issue #87）。
    private func setMessage(_ value: String?, generation: UInt64) {
        guard generation == messageGeneration else { return }
        message = value
    }

    private func canExecuteMutation(for command: ControlCommand) -> Bool {
        guard command.isMutation else { return true }
        refreshControlAgentStatus()
        if command != .operationCancel && hasActiveMutation {
            setMessage("已有操作正在进行，请等待当前操作完成。", generation: messageGeneration)
            return false
        }
        if command == .profileApply, let reason = sessionActivity?() {
            setMessage(reason, generation: messageGeneration)
            return false
        }
        guard controlAgentStatus.allowsMutation else {
            setMessage(
                "\(controlAgentStatus.title)：\(controlAgentStatus.detail)",
                generation: messageGeneration
            )
            return false
        }
        guard controlPlaneMessage == nil else {
            setMessage("控制 Agent 不可用，请重新读取或运行诊断", generation: messageGeneration)
            return false
        }
        return true
    }

    private static func serviceOperationPhase(for command: ControlCommand) -> ServiceOperationPhase? {
        switch command {
        case .start:
            .starting
        case .stop:
            .stopping
        case .restart:
            .restarting
        default:
            nil
        }
    }

    private static func serviceReady(from snapshot: HealthSnapshot) -> Bool? {
        if let ready = snapshot.ready {
            return ready
        }
        switch (snapshot.asrReady, snapshot.ttsReady) {
        case let (.some(asr), .some(tts)):
            return asr && tts
        case let (.some(asr), .none):
            return asr
        case let (.none, .some(tts)):
            return tts
        case (.none, .none):
            return nil
        }
    }
}
