import Foundation
import Observation
import SpeechRailControlKit

public enum ModelAvailabilityState: Equatable, Sendable {
    case unknown
    case available
    case unsupported
    case notReady
    case failed
}

public enum CreatorVoicesLoadState: Equatable, Sendable {
    case unknown
    case loading
    case loaded
    case failed
}

public enum ServiceOperationPhase: Equatable, Sendable {
    case starting
    case stopping
    case restarting
    case healthChecking
    case completed
    case failed

    public var isActive: Bool {
        switch self {
        case .starting, .stopping, .restarting, .healthChecking:
            true
        case .completed, .failed:
            false
        }
    }
}

public struct ServiceOperationStatus: Equatable, Sendable {
    public let command: ControlCommand
    public let phase: ServiceOperationPhase
    public let message: String?

    public init(
        command: ControlCommand,
        phase: ServiceOperationPhase,
        message: String? = nil
    ) {
        self.command = command
        self.phase = phase
        self.message = message
    }
}

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
    public private(set) var modelAvailability: ModelAvailabilityState = .unknown
    public private(set) var preflightChecks: [PreflightCheckSnapshot] = []
    public private(set) var monitoringSamples: [RuntimeMetricsSample] = []
    public private(set) var message: String?
    public private(set) var monitoringMessage: String? = nil
    public private(set) var healthMessage: String? = nil
    public private(set) var metricsMessage: String? = nil
    public private(set) var lastHealthRefresh: Date?
    public private(set) var lastMetricsRefresh: Date?
    public private(set) var isBusy = false
    public private(set) var isRefreshingService = false
    public private(set) var isRefreshingModels = false
    public private(set) var isRefreshingMonitoring = false
    public private(set) var isRefreshingPreflight = false
    public private(set) var controlAgentStatus: ControlAgentStatusSnapshot
    public private(set) var serviceOperation: ServiceOperationStatus?
    public private(set) var isAudioPlaying = false
    public private(set) var creatorVoices: [CreatorVoice] = []
    public private(set) var creatorVoicesLoadState: CreatorVoicesLoadState = .unknown
    public private(set) var works: [CreativeWork] = []
    public private(set) var creatorMessage: String?
    public private(set) var isRefreshingCreatorVoices = false
    public private(set) var isCreatingSpeech = false
    public private(set) var isCreatingVoicePreview = false
    public private(set) var isRegisteringVoice = false
    public private(set) var playingWorkID: String?
    public private(set) var playingVoiceID: String?

    public var hasActiveMutation: Bool {
        guard let state = operation?.state else { return false }
        return state == .accepted || state == .running
    }

    private let transport: any SpeechRailControlTransport
    private let apiClient: any ServiceDiagnosticsClient
    private let creatorClient: any SpeechRailCreatorClient
    private let audioPlaybackController: AudioPlaybackController
    private let workStore: CreativeWorkStore
    private let registration: ControlAgentRegistration?
    private var healthRefreshGeneration: UInt64 = 0
    private var metricsRefreshGeneration: UInt64 = 0

    public init(
        transport: any SpeechRailControlTransport,
        apiClient: any ServiceDiagnosticsClient,
        creatorClient: (any SpeechRailCreatorClient)? = nil,
        audioPlaybackController: AudioPlaybackController = AudioPlaybackController(),
        workStore: CreativeWorkStore = CreativeWorkStore(),
        registration: ControlAgentRegistration? = nil
    ) {
        self.transport = transport
        self.apiClient = apiClient
        self.creatorClient = creatorClient ?? UnavailableCreatorClient()
        self.audioPlaybackController = audioPlaybackController
        self.workStore = workStore
        self.registration = registration
        self.controlAgentStatus = registration?.statusSnapshot
            ?? ControlAgentStatusSnapshot(kind: .local)
        self.works = (try? workStore.list()) ?? []
        self.audioPlaybackController.onPlaybackFinished = { [weak self] in
            self?.isAudioPlaying = false
            self?.playingWorkID = nil
            self?.playingVoiceID = nil
        }
    }

    public func fetchCreatorVoices() async throws -> [CreatorVoice] {
        try await creatorClient.fetchVoices()
    }

    public func createSpeech(
        text: String,
        voiceID: String,
        speed: Double
    ) async throws -> Data {
        try await creatorClient.createSpeech(text: text, voiceID: voiceID, speed: speed)
    }

    public func createVoicePreview(
        text: String,
        instruction: String,
        speed: Double,
        seed: Int?
    ) async throws -> Data {
        try await creatorClient.createVoicePreview(
            text: text,
            instruction: instruction,
            speed: speed,
            seed: seed
        )
    }

    public func previewDesignedVoice(
        text: String,
        instruction: String,
        speed: Double,
        seed: Int?
    ) async -> Data? {
        guard !isCreatingVoicePreview else { return nil }
        let previewText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previewText.isEmpty, !voiceInstruction.isEmpty else {
            creatorMessage = "请先填写音色描述和试听文案"
            return nil
        }

        isCreatingVoicePreview = true
        creatorMessage = nil
        defer { isCreatingVoicePreview = false }
        do {
            return try await creatorClient.createVoicePreview(
                text: previewText,
                instruction: voiceInstruction,
                speed: speed,
                seed: seed
            )
        } catch is CancellationError {
            return nil
        } catch {
            creatorMessage = Self.creatorErrorMessage(for: error)
            return nil
        }
    }

    public func saveDesignedVoice(
        name: String,
        instruction: String,
        referenceText: String,
        seed: Int
    ) async -> CreatorVoice? {
        guard !isRegisteringVoice else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReferenceText = referenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            creatorMessage = "请先为音色命名"
            return nil
        }
        guard !trimmedInstruction.isEmpty else {
            creatorMessage = "请先填写音色描述"
            return nil
        }
        guard (20...240).contains(trimmedReferenceText.count) else {
            creatorMessage = "参考文案需要 20–240 个字符"
            return nil
        }

        isRegisteringVoice = true
        creatorMessage = nil
        defer { isRegisteringVoice = false }
        do {
            let id = "voice_design_" + UUID().uuidString
                .replacingOccurrences(of: "-", with: "")
                .lowercased()
            let voice = try await creatorClient.registerVoiceDesign(
                id: id,
                name: trimmedName,
                instruction: trimmedInstruction,
                referenceText: trimmedReferenceText,
                seed: max(0, seed)
            )
            await refreshCreatorVoices()
            creatorMessage = nil
            return voice
        } catch is CancellationError {
            return nil
        } catch {
            creatorMessage = Self.creatorErrorMessage(for: error)
            return nil
        }
    }

    public func previewVoice(
        _ voice: CreatorVoice,
        text: String = "这是 SpeechRail 的音色试听。清晰、自然的声音，让每一句表达都恰到好处。",
        speed: Double = 1.0
    ) async {
        guard !isCreatingSpeech else { return }
        guard voice.available else {
            creatorMessage = "当前音色暂不可用于试听"
            return
        }
        let previewText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previewText.isEmpty else {
            creatorMessage = "试听文案不能为空"
            return
        }

        isCreatingSpeech = true
        creatorMessage = nil
        defer { isCreatingSpeech = false }
        do {
            let data = try await creatorClient.createSpeech(
                text: previewText,
                voiceID: voice.id,
                speed: speed
            )
            try audioPlaybackController.play(data: data)
            isAudioPlaying = audioPlaybackController.isPlaying
            playingWorkID = nil
            playingVoiceID = voice.id
        } catch is CancellationError {
            return
        } catch {
            creatorMessage = Self.creatorErrorMessage(for: error)
        }
    }

    public func registerVoiceDesign(
        id: String,
        name: String,
        instruction: String,
        referenceText: String,
        seed: Int
    ) async throws -> CreatorVoice {
        try await creatorClient.registerVoiceDesign(
            id: id,
            name: name,
            instruction: instruction,
            referenceText: referenceText,
            seed: seed
        )
    }

    public func playAudio(data: Data) throws {
        try audioPlaybackController.play(data: data)
        isAudioPlaying = audioPlaybackController.isPlaying
        playingWorkID = nil
        playingVoiceID = nil
    }

    public func audioDuration(for data: Data) -> TimeInterval? {
        audioPlaybackController.duration(for: data)
    }

    public func stopAudio() {
        audioPlaybackController.stop()
        isAudioPlaying = false
        playingWorkID = nil
        playingVoiceID = nil
    }

    public func refreshCreatorVoices() async {
        guard !isRefreshingCreatorVoices else { return }
        isRefreshingCreatorVoices = true
        creatorVoicesLoadState = .loading
        defer { isRefreshingCreatorVoices = false }
        do {
            creatorVoices = try await creatorClient.fetchVoices()
                .sorted { lhs, rhs in
                    if lhs.isSystem != rhs.isSystem { return lhs.isSystem }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            creatorVoicesLoadState = .loaded
            creatorMessage = nil
        } catch is CancellationError {
            creatorVoicesLoadState = .unknown
            return
        } catch {
            creatorVoicesLoadState = .failed
            creatorMessage = Self.creatorErrorMessage(for: error)
        }
    }

    public func refreshWorks() {
        do {
            works = try workStore.list()
        } catch {
            creatorMessage = "作品历史暂时不可用"
        }
    }

    public func synthesizeAndSave(
        text: String,
        voice: CreatorVoice,
        speed: Double
    ) async -> CreativeWork? {
        guard !isCreatingSpeech else { return nil }
        let scriptText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scriptText.isEmpty else {
            creatorMessage = "请先输入配音文稿"
            return nil
        }
        guard voice.available else {
            creatorMessage = "当前音色暂不可用于配音"
            return nil
        }

        isCreatingSpeech = true
        creatorMessage = nil
        defer { isCreatingSpeech = false }

        do {
            let data = try await creatorClient.createSpeech(
                text: scriptText,
                voiceID: voice.id,
                speed: speed
            )
            let workID = "work_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let work = CreativeWork(
                id: workID,
                title: Self.workTitle(for: scriptText),
                scriptText: scriptText,
                voiceID: voice.id,
                voiceName: voice.name,
                durationSeconds: audioPlaybackController.duration(for: data),
                audioFileName: "\(workID).wav"
            )
            try workStore.save(work, audioData: data)
            works = try workStore.list()
            do {
                try audioPlaybackController.play(data: data)
                isAudioPlaying = audioPlaybackController.isPlaying
                playingWorkID = work.id
            } catch {
                creatorMessage = "作品已保存，但音频无法播放"
            }
            return work
        } catch is CancellationError {
            return nil
        } catch {
            creatorMessage = Self.creatorErrorMessage(for: error)
            return nil
        }
    }

    public func playWork(_ work: CreativeWork) {
        if playingWorkID == work.id, isAudioPlaying {
            stopAudio()
            return
        }
        do {
            let data = try workStore.loadAudio(for: work)
            try audioPlaybackController.play(data: data)
            isAudioPlaying = audioPlaybackController.isPlaying
            playingWorkID = work.id
            creatorMessage = nil
        } catch {
            creatorMessage = "作品音频暂时不可用"
        }
    }

    public func refresh() async {
        guard !isRefreshingService else { return }
        isRefreshingService = true
        defer { isRefreshingService = false }
        healthRefreshGeneration &+= 1
        let refreshGeneration = healthRefreshGeneration
        refreshControlAgentStatus()
        message = nil
        do {
            let snapshot = try await apiClient.fetchHealthSnapshot()
            guard refreshGeneration == healthRefreshGeneration else { return }
            health = snapshot
            healthMessage = nil
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
            healthMessage = Self.controlErrorMessage(for: error, fallback: "运行状态暂时不可用")
            service = ServiceSnapshot(serviceState: "unavailable", port: apiClient.port)
        }
        do {
            let list = try await transport.send(ControlRequest(command: .profileList))
            guard refreshGeneration == healthRefreshGeneration else { return }
            profiles = list.profiles ?? []
            let status = try await transport.send(ControlRequest(command: .profileStatus))
            guard refreshGeneration == healthRefreshGeneration else { return }
            profile = status.profile
            message = nil
        } catch is CancellationError {
            return
        } catch {
            guard refreshGeneration == healthRefreshGeneration else { return }
            message = Self.controlErrorMessage(for: error, fallback: "控制 Agent 尚未连接")
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
        guard !isRefreshingModels else { return }
        isRefreshingModels = true
        defer { isRefreshingModels = false }
        refreshControlAgentStatus()
        do {
            let catalog = try await transport.send(ControlRequest(command: .modelCatalog))
            guard !handleModelResponseFailure(catalog) else {
                return
            }
            guard let catalogSnapshot = catalog.modelCatalog else {
                markModelUnavailable(
                    state: .failed,
                    message: "模型目录暂时不可用"
                )
                return
            }
            let status = try await transport.send(ControlRequest(command: .modelStatus))
            guard !handleModelResponseFailure(status) else {
                return
            }
            guard let statusSnapshot = status.modelStatus else {
                markModelUnavailable(
                    state: .notReady,
                    message: "模型状态暂时不可用"
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
                message = warning
            } else {
                message = nil
            }
        } catch {
            modelCatalog = nil
            modelStatus = nil
            preserveRecoverableModelOperation()
            modelAvailability = .failed
            message = Self.controlErrorMessage(for: error, fallback: "模型状态暂时不可用")
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
        do {
            try registration.register()
            refreshControlAgentStatus()
            message = controlAgentStatus.title
        } catch {
            message = "无法启用控制 Agent：\(Self.controlAgentErrorMessage(for: error))"
        }
    }

    public func openControlAgentSettings() {
        registration?.openLoginItemsSettings()
    }

    public func refreshMonitoring() async {
        guard !isRefreshingMonitoring else { return }
        isRefreshingMonitoring = true
        defer { isRefreshingMonitoring = false }
        healthRefreshGeneration &+= 1
        let healthGeneration = healthRefreshGeneration
        metricsRefreshGeneration &+= 1
        let metricsGeneration = metricsRefreshGeneration

        do {
            let snapshot = try await apiClient.fetchHealthSnapshot()
            guard healthGeneration == healthRefreshGeneration else { return }
            health = snapshot
            healthMessage = nil
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
            healthMessage = Self.controlErrorMessage(for: error, fallback: "运行状态暂时不可用")
            service = ServiceSnapshot(serviceState: "unavailable", port: apiClient.port)
            monitoringMessage = healthMessage
            return
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
            monitoringMessage = nil
        } catch is CancellationError {
            return
        } catch {
            // Monitoring is observational. Keep the last valid sample and let
            // the page explain that the next sample could not be read.
            guard healthGeneration == healthRefreshGeneration,
                  metricsGeneration == metricsRefreshGeneration
            else { return }
            metricsMessage = Self.controlErrorMessage(for: error, fallback: "运行数据暂时不可用")
            monitoringMessage = metricsMessage
        }
    }

    public func refreshPreflight() async {
        guard !isRefreshingPreflight else { return }
        isRefreshingPreflight = true
        defer { isRefreshingPreflight = false }
        refreshControlAgentStatus()
        message = nil
        do {
            let response = try await transport.send(ControlRequest(command: .preflight))
            if let checks = response.checks {
                preflightChecks = checks
            } else if response.status != .failed {
                preflightChecks = []
            }
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
        guard canExecuteMutation(for: .operationCancel) else { return }
        guard let operationID = operation?.operationID else { return }
        message = "正在停止模型准备…"
        do {
            let response = try await transport.send(
                ControlRequest(command: .operationCancel, operationID: operationID)
            )
            operation = response.operation ?? operation
            if response.status == .failed {
                message = response.message ?? "无法取消操作"
            } else if response.operation?.phase?.lowercased() == "cancelling" {
                await waitForOperation(operationID)
                await refreshModels()
            } else if response.status == .cancelled {
                message = "模型准备已取消"
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
        guard canExecuteMutation(for: command) else { return }
        isBusy = true
        message = nil
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
                    profile: selectedProfile,
                    confirmation: command.requiresConfirmation
                )
            )
            operation = response.operation
            if response.status == .failed {
                let failureMessage = response.message ?? "操作失败"
                message = failureMessage
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
                await waitForOperation(operationID)
            }
            if let serviceMutation {
                serviceOperation = ServiceOperationStatus(
                    command: command,
                    phase: .healthChecking,
                    message: "命令已完成，正在读取最新服务状态…"
                )
            }
            await refresh()
            if let serviceMutation {
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
        } catch {
            let failureMessage = Self.controlErrorMessage(for: error, fallback: "控制 Agent 不可用")
            message = failureMessage
            if serviceMutation != nil {
                serviceOperation = ServiceOperationStatus(
                    command: command,
                    phase: .failed,
                    message: failureMessage
                )
            }
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
                   state == .committed || state == .failed || state == .cancelled || state == .interrupted
                {
                    if state == .failed || state == .cancelled || state == .interrupted {
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
        if let error = error as? ControlAgentRegistrationError {
            return controlAgentErrorMessage(for: error)
        }
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

    private static func creatorErrorMessage(for error: Error) -> String {
        guard let error = error as? ServiceAPIClientError else {
            return "创作服务暂时不可用"
        }
        switch error {
        case let .server(code, _, _):
            switch code {
            case "backend_not_ready":
                return "语音服务尚未就绪，请先检查服务状态"
            case "voice_store_unavailable":
                return "音色库暂时不可用，请稍后重试"
            case "voice_not_found", "voice_not_available":
                return "所选音色当前不可用，请重新选择"
            case "voice_preview_unsupported":
                return "当前档位不支持音色预览"
            case "queue_full", "backend_busy":
                return "语音资源正忙，请稍后重试"
            case "backend_timeout":
                return "语音处理超时，请重试"
            case "audio_encode_failed", "backend_error":
                return "音频生成失败，请重试"
            case "voice_design_registration_unsupported":
                return "当前档位不支持音色保存"
            case "voice_already_exists":
                return "音色标识已存在，请换一个名称"
            default:
                return "创作服务暂时不可用"
            }
        case .invalidURL, .invalidResponse, .requestFailed:
            return "无法连接本机 SpeechRail 创作服务"
        }
    }

    private static func workTitle(for text: String) -> String {
        let firstLine = text.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 24 { return trimmed }
        return String(trimmed.prefix(24)) + "…"
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
    private func handleModelResponseFailure(_ response: ControlResponse) -> Bool {
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
        markModelUnavailable(state: state, message: response.message ?? fallback)
        return true
    }

    private func markModelUnavailable(
        state: ModelAvailabilityState,
        message: String
    ) {
        modelCatalog = nil
        modelStatus = nil
        preserveRecoverableModelOperation()
        modelAvailability = state
        self.message = message
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

    private func canExecuteMutation(for command: ControlCommand) -> Bool {
        guard command.isMutation else { return true }
        refreshControlAgentStatus()
        if command != .operationCancel && hasActiveMutation {
            message = "已有操作正在进行，请等待当前操作完成。"
            return false
        }
        guard controlAgentStatus.allowsMutation else {
            message = "\(controlAgentStatus.title)：\(controlAgentStatus.detail)"
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
