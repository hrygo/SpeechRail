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

public enum ServiceHealthFailureKind: Equatable, Sendable {
    case connection
    case timeout
    case invalidResponse
    case server(code: String)
}

public enum CreatorVoicesLoadState: Equatable, Sendable {
    case unknown
    case loading
    case loaded
    case failed
}

/// 服务级能力声明（`GET /v1/models`）的读取状态。能力结论只有“读到服务声明”
/// 与“还没读到”两种前提，不能让空列表冒充“服务不支持”。
public enum ServiceCapabilitiesLoadState: Equatable, Sendable {
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

public enum VoiceDesignCandidateStatus: Equatable, Sendable {
    case loading
    case ready
    case cancelled
    case failed(String)
}

public struct VoiceDesignCandidateSnapshot: Equatable, Identifiable, Sendable {
    public let slot: String
    public let seed: Int
    public let title: String
    public let instructionSnapshot: String
    public let referenceTextSnapshot: String
    public var status: VoiceDesignCandidateStatus
    public var audioData: Data?
    public var durationSeconds: TimeInterval?

    public var id: String { slot }

    public init(
        slot: String,
        seed: Int,
        title: String,
        instructionSnapshot: String,
        referenceTextSnapshot: String,
        status: VoiceDesignCandidateStatus,
        audioData: Data? = nil,
        durationSeconds: TimeInterval? = nil
    ) {
        self.slot = slot
        self.seed = seed
        self.title = title
        self.instructionSnapshot = instructionSnapshot
        self.referenceTextSnapshot = referenceTextSnapshot
        self.status = status
        self.audioData = audioData
        self.durationSeconds = durationSeconds
    }
}

private enum OperationWaitResult {
    case committed
    case failed
    case stillRunning
    case cancelled
    /// 等待期间有更新的 execute / cancel / refresh 入口 bump 了操作代数：
    /// 这条链已经过期，不得再用自己的结果覆盖新状态（issue #88）。
    case superseded
}

/// 提词稿列表的读取状态。`empty` 与 `failed` 必须分开：服务端资产缺失时返回的是空数组
/// （「没有官方提词稿」），连接失败才是「读不到」——两者的下一步动作不同。
public enum ClonePromptLoadState: Equatable, Sendable {
    case unknown
    case empty
    case ready
    case failed(String)
}

@MainActor
@Observable
public final class AppModel {
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
    public private(set) var isAudioPlaying = false
    /// 当前音频的**真实**播放进度 0…1（`AVAudioPlayer.currentTime / duration`）。
    /// 详情面板的波形用它表示「播到哪了」（REDESIGN-SPEC §11.6 第五十七轮）。
    public private(set) var playbackProgress: Double = 0
    /// 服务公开的 TTS 能力（`/v1/models.capabilities`）。`nil` 表示还没有读到
    /// 结论，界面此时只能说“未读取”，不能把“没有克隆音色”当成“没有能力”。
    public private(set) var serviceCapabilities: ServiceModelCapabilities?
    public private(set) var serviceCapabilitiesLoadState: ServiceCapabilitiesLoadState = .unknown
    public private(set) var isRefreshingServiceCapabilities = false
    /// 同一代、最小披露的能力快照。能力发现只认这里或服务明确提供的 legacy 投影，
    /// 不把音色用户数据拼成能力结论。
    public private(set) var effectiveCapabilities: EffectiveCapabilitySnapshot?
    public private(set) var safeVoiceCatalog: SafeVoiceList?
    public private(set) var discoveryState: CapabilityDiscoveryState = .idle
    public private(set) var discoveryMetadata: ServiceResponseMetadata?
    public private(set) var isRefreshingDiscovery = false
    public private(set) var creatorVoices: [CreatorVoice] = []
    public private(set) var creatorVoicesLoadState: CreatorVoicesLoadState = .unknown
    public private(set) var isRefreshingCreatorVoiceDetail = false
    public private(set) var creatorVoiceDetailMessage: String?
    public private(set) var works: [CreativeWork] = []
    public private(set) var creatorMessage: String?
    public private(set) var isRefreshingCreatorVoices = false
    public private(set) var isCreatingSpeech = false
    public private(set) var previewingVoiceID: String?
    public private(set) var lastCreatedWork: CreativeWork?
    public private(set) var isCreatingVoicePreview = false
    public private(set) var voiceDesignCandidates: [VoiceDesignCandidateSnapshot] = []
    public private(set) var voiceDesignSavedSlots: Set<String> = []
    public private(set) var voiceDesignSavingSlot: String?
    public private(set) var isGeneratingVoiceDesign = false
    public private(set) var voiceDesignErrorMessage: String?
    public private(set) var voiceDesignSuccessMessage: String?
    public private(set) var isRegisteringVoice = false
    public private(set) var isUpdatingVoice = false
    public private(set) var isDeletingVoice = false
    // MARK: 音色克隆（录音 → 回听 → 核对 → 注册）

    /// 录音通道。视图直接观察它（`isRecording` / `elapsed` / `level`），因为电平表
    /// 必须以 20Hz 更新，走 AppModel 中转只会多一层无用的拷贝。
    public let recording = VoiceRecordingController()
    public private(set) var clonePrompts: [ClonePrompt] = []
    public private(set) var clonePromptLoadState: ClonePromptLoadState = .unknown
    /// 最近一次本地检查的结果（`nil` = 还没有录音，或这段录音解不开）。
    public private(set) var cloneReferenceAnalysis: AudioReferenceAnalysis?
    /// 这次录音的字节。**只在内存里**：文件读过就删，注册成功后连内存也放掉，
    /// 应用不保存用户的原始录音（§13.2）。
    public private(set) var cloneRecordingAudio: Data?
    /// 服务端预检报告（`/v1/voices/clone/validate`）。它不是注册结果：
    /// 注册会重新走一遍同样的门（用户可能在预检后又改过文本或重录）。
    public private(set) var cloneEvaluation: VoiceQualityReportSnapshot?
    public private(set) var isEvaluatingCloneReference = false
    public private(set) var isRegisteringCloneVoice = false
    public private(set) var cloneMessage: String?
    public private(set) var lastRegisteredCloneVoice: CreatorVoice?
    /// 一次逻辑注册的稳定身份：响应丢失后重试必须带同一个 `id` 与 `Idempotency-Key`，
    /// 否则服务端会把同一次注册再建一遍（§13.2 / `POST /v1/voices/clone`）。
    public private(set) var cloneRegistrationID: String?
    public private(set) var cloneIdempotencyKey: String?
    public private(set) var playingWorkID: String?
    public private(set) var playingVoiceID: String?
    /// 真实音频实时电平 0…1，由播放器实时功率（metering）驱动。
    public private(set) var playbackLevel: Float = 0
    public private(set) var worksMessage: String?
    /// Result of an explicit work action (delete/rename). Kept apart from
    /// `worksMessage`, which reports that the history itself is unreadable.
    public private(set) var workActionMessage: String?
    public private(set) var workPlaybackMessage: String?

    public var hasActiveMutation: Bool {
        guard let state = operation?.state else { return false }
        return state == .accepted || state == .running
    }

    private let transport: any SpeechRailControlTransport
    private let apiClient: any ServiceDiagnosticsClient
    private let capabilityClient: any ServiceModelCapabilityClient
    private let discoveryClient: any ServiceCapabilityDiscoveryClient
    private let creatorClient: any SpeechRailCreatorClient
    private let audioPlaybackController: AudioPlaybackController
    private let workStore: CreativeWorkStore
    private let observabilityLocation: ObservabilityLocation
    private let registration: ControlAgentRegistration?
    private var healthRefreshGeneration: UInt64 = 0
    private var metricsRefreshGeneration: UInt64 = 0
    private var monitoringHistoryGeneration: UInt64 = 0
    private var creatorVoiceDetailGeneration: UInt64 = 0
    private var discoveryRefreshGeneration: UInt64 = 0
    /// 模型准备的操作代数：`execute` / `cancelCurrentOperation` / `refreshModels`
    /// 每次进入都会递增。取消链在发起时记住自己的代数，等待与刷新期间一旦有更新
    /// 入口 bump，就自认过期、不再落地状态，避免覆盖更新的终态（issue #88）。
    private var operationGeneration: UInt64 = 0
    private var capabilitySnapshotStore = CapabilitySnapshotStore()
    private var safeVoiceCatalogETag: String?
    private var synthesisTask: Task<Void, Never>?
    /// 波形包络缓存（key = `voice:<id>` / `work:<id>`）。分辨率固定
    /// `Waveform.envelopeBuckets`，视图按自己的排布重采样——同一段包络因此能给
    /// 12 / 16 / 18 根三种波形用（REDESIGN-SPEC §11.6 第五十七轮）。
    private var waveformEnvelopes: [String: [CGFloat]] = [:]
    /// 试听音频内存缓存（key = `\(voiceID):\(speed):\(text)`），同音色试听即点即播，0 延迟
    private var previewAudioCache: [String: Data] = [:]
    private var voicePreviewTask: Task<Void, Never>?
    private var voiceDesignGenerationTask: Task<Void, Never>?
    private var voiceDesignSaveTask: Task<Void, Never>?

    /// 槽位编号与 Figma `Candidate Tile` 一致：候选 1–4 配 seed 101/202/303/404。
    private static let voiceDesignCandidateSpecs: [(slot: String, seed: Int, title: String)] = [
        ("1", 101, "候选 1"),
        ("2", 202, "候选 2"),
        ("3", 303, "候选 3"),
        ("4", 404, "候选 4")
    ]

    public init(
        transport: any SpeechRailControlTransport,
        apiClient: any ServiceDiagnosticsClient,
        capabilityClient: (any ServiceModelCapabilityClient)? = nil,
        discoveryClient: (any ServiceCapabilityDiscoveryClient)? = nil,
        creatorClient: (any SpeechRailCreatorClient)? = nil,
        audioPlaybackController: AudioPlaybackController = AudioPlaybackController(),
        workStore: CreativeWorkStore = CreativeWorkStore(),
        observabilityLocation: ObservabilityLocation = .default,
        registration: ControlAgentRegistration? = nil
    ) {
        self.transport = transport
        self.apiClient = apiClient
        self.capabilityClient = capabilityClient ?? UnavailableModelCapabilityClient()
        self.discoveryClient = discoveryClient ?? UnavailableServiceCapabilityDiscoveryClient()
        self.creatorClient = creatorClient ?? UnavailableCreatorClient()
        self.audioPlaybackController = audioPlaybackController
        self.workStore = workStore
        self.observabilityLocation = observabilityLocation
        self.registration = registration
        self.controlAgentStatus = registration?.statusSnapshot
            ?? ControlAgentStatusSnapshot(kind: .local)
        self.works = (try? workStore.list()) ?? []
        self.audioPlaybackController.onPlaybackFinished = { [weak self] successfully in
            guard let self else { return }
            let workWasPlaying = self.playingWorkID != nil
            self.isAudioPlaying = false
            self.playingWorkID = nil
            self.playingVoiceID = nil
            self.playbackProgress = 0
            self.playbackLevel = 0
            guard !successfully else { return }
            if workWasPlaying {
                self.workPlaybackMessage = "作品播放失败，请重新试听或重新生成。"
            } else {
                self.creatorMessage = "音频播放失败，请重试。"
            }
        }
        self.audioPlaybackController.onProgress = { [weak self] value in
            self?.playbackProgress = value
        }
        self.audioPlaybackController.onLevel = { [weak self] value in
            self?.playbackLevel = value
        }
    }

    public func fetchCreatorVoices() async throws -> [CreatorVoice] {
        try await creatorClient.fetchVoices()
    }

    private func speechRequestOptions(
        for voiceID: String,
        fallbackVoiceRevision: String? = nil
    ) -> SpeechRailRequestOptions {
        SpeechRailCapabilityRevisionSelector.creatorRequestOptions(
            voiceID: voiceID,
            fallbackVoiceRevision: fallbackVoiceRevision,
            in: effectiveCapabilities
        )
    }

    private func speechRequestOptions(for voice: CreatorVoice) -> SpeechRailRequestOptions {
        speechRequestOptions(for: voice.id, fallbackVoiceRevision: voice.revision)
    }

    public func createSpeech(
        text: String,
        voiceID: String,
        speed: Double
    ) async throws -> Data {
        try await creatorClient.createSpeech(
            text: text,
            voiceID: voiceID,
            speed: speed,
            options: speechRequestOptions(for: voiceID)
        )
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

    public func startVoiceDesignGeneration(
        instruction: String,
        referenceText: String,
        speed: Double = 1.0
    ) {
        guard voiceDesignGenerationTask == nil, !isGeneratingVoiceDesign else { return }

        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReferenceText = referenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstruction.isEmpty else {
            voiceDesignErrorMessage = "请先填写音色描述"
            return
        }
        guard trimmedReferenceText.count >= SpeechRailCreatorLimits.referenceTextMinimumLength,
              trimmedReferenceText.count <= SpeechRailCreatorLimits.referenceTextMaximumLength
        else {
            voiceDesignErrorMessage = "试听与注册参考文案需要 20–240 个字符"
            return
        }
        guard trimmedInstruction.count <= SpeechRailCreatorLimits.voiceInstructionMaximumLength else {
            voiceDesignErrorMessage = "音色描述不能超过 \(SpeechRailCreatorLimits.voiceInstructionMaximumLength) 个字符"
            return
        }

        voiceDesignErrorMessage = nil
        voiceDesignSuccessMessage = nil
        voiceDesignSavedSlots.removeAll()
        voiceDesignCandidates = Self.voiceDesignCandidateSpecs.map {
            VoiceDesignCandidateSnapshot(
                slot: $0.slot,
                seed: $0.seed,
                title: $0.title,
                instructionSnapshot: trimmedInstruction,
                referenceTextSnapshot: trimmedReferenceText,
                status: .loading
            )
        }
        stopAudio()
        isGeneratingVoiceDesign = true
        voiceDesignGenerationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.generateVoiceDesignCandidates(
                instruction: trimmedInstruction,
                referenceText: trimmedReferenceText,
                speed: speed
            )
            self.voiceDesignGenerationTask = nil
        }
    }

    public func cancelVoiceDesignGeneration() {
        voiceDesignGenerationTask?.cancel()
    }

    /// Regenerate a single candidate in place, reusing its own instruction,
    /// reference text and seed so a failed card can recover without throwing
    /// away its three siblings (REDESIGN-SPEC §7.2).
    public func retryVoiceDesignCandidate(slot: String) {
        guard voiceDesignGenerationTask == nil, !isGeneratingVoiceDesign else { return }
        guard let candidate = voiceDesignCandidates.first(where: { $0.slot == slot }),
              !candidate.instructionSnapshot.isEmpty
        else {
            return
        }

        voiceDesignErrorMessage = nil
        voiceDesignSuccessMessage = nil
        updateVoiceDesignCandidate(slot: slot, status: .loading)
        stopAudio()
        isGeneratingVoiceDesign = true
        voiceDesignGenerationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let data = await self.previewDesignedVoice(
                text: candidate.referenceTextSnapshot,
                instruction: candidate.instructionSnapshot,
                speed: 1.0,
                seed: candidate.seed
            )
            if Task.isCancelled {
                self.updateVoiceDesignCandidate(slot: slot, status: .cancelled)
            } else if let data {
                self.updateVoiceDesignCandidate(
                    slot: slot,
                    status: .ready,
                    audioData: data,
                    durationSeconds: self.audioDuration(for: data)
                )
            } else {
                self.updateVoiceDesignCandidate(
                    slot: slot,
                    status: .failed(self.creatorMessage ?? "预览未生成，请稍后重试")
                )
            }
            self.isGeneratingVoiceDesign = false
            self.voiceDesignGenerationTask = nil
        }
    }

    public func saveVoiceDesignCandidate(
        _ candidate: VoiceDesignCandidateSnapshot,
        name: String
    ) {
        guard voiceDesignSaveTask == nil, voiceDesignSavingSlot == nil else { return }
        guard case .ready = candidate.status, candidate.audioData != nil else { return }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            voiceDesignErrorMessage = "请先填写保存名称"
            return
        }

        voiceDesignErrorMessage = nil
        voiceDesignSuccessMessage = nil
        voiceDesignSavingSlot = candidate.slot
        voiceDesignSaveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let voice = await self.saveDesignedVoice(
                name: trimmedName,
                instruction: candidate.instructionSnapshot,
                referenceText: candidate.referenceTextSnapshot,
                seed: candidate.seed
            )
            if let voice {
                self.voiceDesignSavedSlots.insert(candidate.slot)
                self.voiceDesignSuccessMessage = "“\(voice.name)” 已按候选 \(candidate.slot) 的 seed 注册，可在音色库中复用。"
            } else if !Task.isCancelled {
                self.voiceDesignErrorMessage = self.creatorMessage ?? "候选音色注册未完成，请重试"
            }
            self.voiceDesignSavingSlot = nil
            self.voiceDesignSaveTask = nil
        }
    }

    private func generateVoiceDesignCandidates(
        instruction: String,
        referenceText: String,
        speed: Double
    ) async {
        defer {
            if Task.isCancelled {
                markLoadingVoiceDesignCandidatesCancelled()
                voiceDesignErrorMessage = "本次候选生成已停止；已保留已完成候选，可继续试听或重新生成。"
            }
            isGeneratingVoiceDesign = false
        }
        var failedSlots: [String] = []
        for spec in Self.voiceDesignCandidateSpecs {
            guard !Task.isCancelled else { return }
            updateVoiceDesignCandidate(slot: spec.slot, status: .loading)
            guard let data = await previewDesignedVoice(
                text: referenceText,
                instruction: instruction,
                speed: speed,
                seed: spec.seed
            ) else {
                guard !Task.isCancelled else { return }
                let message = creatorMessage ?? "预览未生成，请稍后重试"
                updateVoiceDesignCandidate(
                    slot: spec.slot,
                    status: .failed(message)
                )
                failedSlots.append(spec.slot)
                continue
            }
            guard !Task.isCancelled else { return }
            updateVoiceDesignCandidate(
                slot: spec.slot,
                status: .ready,
                audioData: data,
                durationSeconds: audioDuration(for: data)
            )
        }
        if !failedSlots.isEmpty, !Task.isCancelled {
            voiceDesignErrorMessage = "候选 \(failedSlots.joined(separator: "、")) 未生成；已保留其他成功候选，可重新生成。"
        }
    }

    private func markLoadingVoiceDesignCandidatesCancelled() {
        for index in voiceDesignCandidates.indices {
            if case .loading = voiceDesignCandidates[index].status {
                voiceDesignCandidates[index].status = .cancelled
            }
        }
    }

    private func updateVoiceDesignCandidate(
        slot: String,
        status: VoiceDesignCandidateStatus,
        audioData: Data? = nil,
        durationSeconds: TimeInterval? = nil
    ) {
        guard let index = voiceDesignCandidates.firstIndex(where: { $0.slot == slot }) else {
            return
        }
        voiceDesignCandidates[index].status = status
        if let audioData {
            voiceDesignCandidates[index].audioData = audioData
        }
        if let durationSeconds {
            voiceDesignCandidates[index].durationSeconds = durationSeconds
        }
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
        guard previewText.count <= SpeechRailCreatorLimits.speechTextMaximumLength else {
            creatorMessage = "试听文案不能超过 \(SpeechRailCreatorLimits.speechTextMaximumLength) 个字符"
            return nil
        }
        guard voiceInstruction.count <= SpeechRailCreatorLimits.voiceInstructionMaximumLength else {
            creatorMessage = "音色描述不能超过 \(SpeechRailCreatorLimits.voiceInstructionMaximumLength) 个字符"
            return nil
        }

        isCreatingVoicePreview = true
        creatorMessage = nil
        defer { isCreatingVoicePreview = false }
        do {
            let data = try await creatorClient.createVoicePreview(
                text: previewText,
                instruction: voiceInstruction,
                speed: speed,
                seed: seed
            )
            try Task.checkCancellation()
            return data
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
        guard trimmedInstruction.count <= SpeechRailCreatorLimits.voiceInstructionMaximumLength else {
            creatorMessage = "音色描述不能超过 \(SpeechRailCreatorLimits.voiceInstructionMaximumLength) 个字符"
            return nil
        }
        guard (SpeechRailCreatorLimits.referenceTextMinimumLength...SpeechRailCreatorLimits.referenceTextMaximumLength)
            .contains(trimmedReferenceText.count)
        else {
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
            let refreshed = await refreshCreatorVoices()
            if !refreshed {
                let refreshMessage = creatorMessage ?? "请重新读取音色列表"
                creatorMessage = "音色已保存，但列表刷新失败：" + refreshMessage
            }
            return voice
        } catch is CancellationError {
            return nil
        } catch {
            creatorMessage = Self.creatorErrorMessage(for: error)
            return nil
        }
    }

    // MARK: - 音色克隆

    /// 读取官方提词稿（`GET /v1/voices/clone/prompts`）。
    public func refreshClonePrompts() async {
        do {
            let prompts = try await creatorClient.fetchClonePrompts()
            clonePrompts = prompts
            clonePromptLoadState = prompts.isEmpty ? .empty : .ready
        } catch {
            clonePrompts = []
            clonePromptLoadState = .failed(Self.creatorErrorMessage(for: error))
        }
    }

    /// 收下一段刚录完的临时文件：读字节 → 本地量测（主线程之外）→ **删掉磁盘上的原文件**。
    ///
    /// 同一段录音只生成一次注册身份（`cloneRegistrationID` + `cloneIdempotencyKey`），
    /// 重录才会换新的——这正是「一次逻辑注册」的边界。
    public func acceptCloneRecording(fileAt url: URL) async {
        let audio = try? Data(contentsOf: url)
        let analysis = await Task.detached(priority: .userInitiated) {
            AudioReferenceCheck.analyze(fileAt: url)
        }.value
        try? FileManager.default.removeItem(at: url)
        cloneRecordingAudio = audio
        cloneReferenceAnalysis = analysis
        cloneEvaluation = nil
        cloneMessage = analysis == nil ? "这段录音无法解码，请重录。" : nil
        cloneRegistrationID = Self.makeCloneRegistrationID()
        cloneIdempotencyKey = UUID().uuidString.lowercased()
    }

    /// 丢弃这次录音（重录、离开页面、注册完成）。
    public func discardCloneRecording() {
        cloneRecordingAudio = nil
        cloneReferenceAnalysis = nil
        cloneEvaluation = nil
        cloneRegistrationID = nil
        cloneIdempotencyKey = nil
    }

    /// 服务端预检：与注册同一条管线，但不创建任何档案。
    @discardableResult
    public func evaluateCloneReference(
        referenceText: String,
        name: String
    ) async -> VoiceQualityReportSnapshot? {
        guard let audio = cloneRecordingAudio else {
            cloneMessage = "请先录一段参考音频"
            return nil
        }
        guard !isEvaluatingCloneReference else { return nil }
        isEvaluatingCloneReference = true
        cloneMessage = nil
        defer { isEvaluatingCloneReference = false }
        do {
            let report = try await creatorClient.validateVoiceClone(
                audio: audio,
                referenceText: referenceText,
                name: name,
                voiceID: cloneRegistrationID
            )
            cloneEvaluation = report
            return report
        } catch is CancellationError {
            return nil
        } catch {
            cloneMessage = Self.creatorErrorMessage(for: error)
            return nil
        }
    }

    /// 注册克隆音色。校验留在本地一遍，是为了让「名称没填」这类问题不用花一次上传
    /// 就能说清楚；服务端仍会独立校验全部字段。
    public func registerCloneVoice(
        referenceText: String,
        name: String
    ) async -> CreatorVoice? {
        guard !isRegisteringCloneVoice else { return nil }
        guard let audio = cloneRecordingAudio else {
            cloneMessage = "请先录一段参考音频"
            return nil
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReference = referenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            cloneMessage = "请先为音色命名"
            return nil
        }
        guard trimmedName.count <= SpeechRailCreatorLimits.cloneNameMaximumLength else {
            cloneMessage = "音色名称不能超过 \(SpeechRailCreatorLimits.cloneNameMaximumLength) 个字符"
            return nil
        }
        guard !trimmedReference.isEmpty else {
            cloneMessage = "请填写你实际朗读的文本"
            return nil
        }
        guard trimmedReference.count <= SpeechRailCreatorLimits.cloneReferenceTextMaximumLength else {
            cloneMessage = "朗读文本不能超过 \(SpeechRailCreatorLimits.cloneReferenceTextMaximumLength) 个字符"
            return nil
        }
        guard !audio.isEmpty else {
            cloneMessage = "这段录音是空的，请重录"
            return nil
        }

        isRegisteringCloneVoice = true
        cloneMessage = nil
        defer { isRegisteringCloneVoice = false }
        do {
            let voice = try await creatorClient.registerVoiceClone(
                audio: audio,
                referenceText: trimmedReference,
                name: trimmedName,
                voiceID: cloneRegistrationID,
                idempotencyKey: cloneIdempotencyKey
            )
            lastRegisteredCloneVoice = voice
            // 注册成功后放掉内存里的原始录音：档案里留下的是服务端生成的参考音频，
            // 不是用户这次读的那一段。
            cloneRecordingAudio = nil
            let refreshed = await refreshCreatorVoices()
            if !refreshed {
                cloneMessage = "音色已注册，但列表刷新失败：" + (creatorMessage ?? "请重新读取音色列表")
            }
            return voice
        } catch is CancellationError {
            return nil
        } catch {
            cloneMessage = Self.creatorErrorMessage(for: error)
            return nil
        }
    }

    public func clearCloneMessage() {
        cloneMessage = nil
    }

    private static func makeCloneRegistrationID() -> String {
        "voice_clone_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    public func deleteVoice(_ voice: CreatorVoice) async -> Bool {
        guard !voice.isSystem else {
            creatorMessage = "系统音色受保护，不能删除"
            return false
        }
        guard !isDeletingVoice else { return false }

        isDeletingVoice = true
        creatorMessage = nil
        defer { isDeletingVoice = false }
        do {
            try await creatorClient.deleteVoice(id: voice.id)
            if playingVoiceID == voice.id {
                stopAudio()
            }
            let refreshed = await refreshCreatorVoices()
            if !refreshed {
                let refreshMessage = creatorMessage ?? "请重新读取音色列表"
                creatorMessage = "音色已删除，但列表刷新失败：" + refreshMessage
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            creatorMessage = Self.creatorErrorMessage(for: error)
            return false
        }
    }

    public func updateVoice(
        _ voice: CreatorVoice,
        name: String?,
        instruction: String?,
        seed: Int?
    ) async -> Bool {
        guard !voice.isSystem else {
            creatorMessage = "系统音色受保护，不能修改"
            return false
        }
        guard !isUpdatingVoice else { return false }
        guard name != nil || instruction != nil || seed != nil else {
            creatorMessage = "没有可保存的音色修改"
            return false
        }

        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstruction = instruction?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, trimmedName.isEmpty {
            creatorMessage = "音色名称不能为空"
            return false
        }
        if let trimmedInstruction, trimmedInstruction.isEmpty {
            creatorMessage = "音色描述不能为空"
            return false
        }
        if let trimmedInstruction,
           trimmedInstruction.count > SpeechRailCreatorLimits.voiceInstructionMaximumLength
        {
            creatorMessage = "音色描述不能超过 \(SpeechRailCreatorLimits.voiceInstructionMaximumLength) 个字符"
            return false
        }
        if voice.mode == "clone", trimmedInstruction != nil || seed != nil {
            creatorMessage = "参考音色的来源和采样参数不可修改"
            return false
        }
        if let seed, seed < 0 || seed > Int(UInt32.max) {
            creatorMessage = "采样种子必须在 0–4294967295 之间"
            return false
        }

        isUpdatingVoice = true
        creatorMessage = nil
        defer { isUpdatingVoice = false }
        do {
            _ = try await creatorClient.updateVoice(
                id: voice.id,
                name: trimmedName,
                instruction: trimmedInstruction,
                seed: seed
            )
            let refreshed = await refreshCreatorVoices()
            if !refreshed {
                let refreshMessage = creatorMessage ?? "请重新读取音色列表"
                creatorMessage = "音色已更新，但列表刷新失败：" + refreshMessage
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            creatorMessage = Self.creatorErrorMessage(for: error)
            return false
        }
    }

    public func previewVoice(
        _ voice: CreatorVoice,
        text: String = "你好，这是我的声音。",
        speed: Double = 1.0
    ) async {
        // 如果当前正在播放该音色，再次点击即为停止
        if isAudioPlaying && playingVoiceID == voice.id {
            stopAudio()
            return
        }
        guard !isCreatingSpeech else {
            // 如果正在生成该音色，再次点击取消
            if previewingVoiceID == voice.id {
                voicePreviewTask?.cancel()
                voicePreviewTask = nil
                isCreatingSpeech = false
                previewingVoiceID = nil
            }
            return
        }
        guard voice.available else {
            creatorMessage = "当前音色暂不可用于试听"
            return
        }
        let previewText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previewText.isEmpty else {
            creatorMessage = "试听文案不能为空"
            return
        }
        guard previewText.count <= SpeechRailCreatorLimits.speechTextMaximumLength else {
            creatorMessage = "试听文案不能超过 \(SpeechRailCreatorLimits.speechTextMaximumLength) 个字符"
            return
        }

        stopAudio()
        let cacheKey = "\(voice.id):\(speed):\(previewText)"

        // 优先命中本地内存缓存：0 毫秒即点即播，彻底免除反复生成延迟
        if let cachedData = previewAudioCache[cacheKey] {
            do {
                try audioPlaybackController.play(data: cachedData)
                isAudioPlaying = audioPlaybackController.isPlaying
                playingWorkID = nil
                playingVoiceID = voice.id
                cacheEnvelope(key: Self.envelopeKey(kind: "voice", id: voice.id)) { buckets in
                    AudioEnvelope.levels(forAudioData: cachedData, buckets: buckets)
                }
            } catch {
                clearPlaybackState()
                creatorMessage = "音频播放失败，请重试。"
            }
            return
        }

        isCreatingSpeech = true
        previewingVoiceID = voice.id
        creatorMessage = nil
        defer {
            isCreatingSpeech = false
            previewingVoiceID = nil
        }
        do {
            let data = try await creatorClient.createSpeech(
                text: previewText,
                voiceID: voice.id,
                speed: speed,
                options: speechRequestOptions(for: voice)
            )
            try Task.checkCancellation()
            // 写入本地内存缓存
            previewAudioCache[cacheKey] = data
            do {
                try audioPlaybackController.play(data: data)
            } catch {
                clearPlaybackState()
                throw error
            }
            isAudioPlaying = audioPlaybackController.isPlaying
            playingWorkID = nil
            playingVoiceID = voice.id
            // 顺手将真实音频包络算出来，让声波呈现当前真实声音的轮廓
            cacheEnvelope(key: Self.envelopeKey(kind: "voice", id: voice.id)) { buckets in
                AudioEnvelope.levels(forAudioData: data, buckets: buckets)
            }
        } catch is CancellationError {
            return
        } catch {
            creatorMessage = Self.creatorErrorMessage(for: error)
        }
    }

    /// Own voice-library preview requests at the app-model level so a request
    /// cannot outlive the page that started it and begin playback after the
    /// user has navigated elsewhere.
    public func startVoicePreview(
        _ voice: CreatorVoice,
        text: String = "你好，这是我的声音。",
        speed: Double = 1.0
    ) {
        if isAudioPlaying && playingVoiceID == voice.id {
            stopAudio()
            return
        }
        guard voicePreviewTask == nil, !isCreatingSpeech else { return }
        voicePreviewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.previewVoice(voice, text: text, speed: speed)
            self.voicePreviewTask = nil
        }
    }

    public func cancelVoicePreview() {
        guard voicePreviewTask != nil || isAudioPlaying else { return }
        voicePreviewTask?.cancel()
        voicePreviewTask = nil
        stopAudio()
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
        do {
            try audioPlaybackController.play(data: data)
        } catch {
            clearPlaybackState()
            throw error
        }
        isAudioPlaying = audioPlaybackController.isPlaying
        playingWorkID = nil
        playingVoiceID = nil
    }

    public func audioDuration(for data: Data) -> TimeInterval? {
        audioPlaybackController.duration(for: data)
    }

    public func stopAudio() {
        audioPlaybackController.stop()
        clearPlaybackState()
    }

    private func clearPlaybackState() {
        isAudioPlaying = false
        playbackProgress = 0
        playbackLevel = 0
        playingWorkID = nil
        playingVoiceID = nil
    }

    // MARK: - 波形包络（真实音频）

    /// 详情面板那排波形要用的包络；`nil` 表示这段音频还没算过（视图退回稿的固定图形）。
    public func waveformEnvelope(forVoiceID id: String) -> [CGFloat]? {
        waveformEnvelopes[Self.envelopeKey(kind: "voice", id: id)]
    }

    public func waveformEnvelope(forWorkID id: String) -> [CGFloat]? {
        waveformEnvelopes[Self.envelopeKey(kind: "work", id: id)]
    }

    /// 作品详情面板选中的作品：把它的包络先算出来（命中缓存立即返回）。
    /// 读文件是同步的本机小 I/O（与 `playWork` 同量级），解码放到主线程之外。
    public func prepareWaveform(for work: CreativeWork) {
        let key = Self.envelopeKey(kind: "work", id: work.id)
        guard waveformEnvelopes[key] == nil,
              let url = try? workStore.audioURL(for: work)
        else { return }
        cacheEnvelope(key: key) { buckets in
            AudioEnvelope.levels(forAudioFileAt: url, buckets: buckets)
        }
    }

    private static func envelopeKey(kind: String, id: String) -> String {
        "\(kind):\(id)"
    }

    /// 解码放到主线程之外：这是 I/O 加解码，不该占用界面线程；算完再回主线程写缓存。
    private func cacheEnvelope(
        key: String,
        compute: @escaping @Sendable (Int) -> [CGFloat]?
    ) {
        guard waveformEnvelopes[key] == nil else { return }
        let buckets = SpeechRailDesignTokens.Waveform.envelopeBuckets
        Task.detached(priority: .utility) { [weak self] in
            guard let levels = compute(buckets) else { return }
            await MainActor.run { self?.waveformEnvelopes[key] = levels }
        }
    }

    @discardableResult
    public func refreshCreatorVoices() async -> Bool {
        guard !isRefreshingCreatorVoices else { return false }
        // A directory refresh is the authoritative list snapshot. Invalidate
        // any in-flight single-voice read before starting it, otherwise a late
        // detail response can overwrite the newer list and leave the inspector
        // stuck in a loading state.
        creatorVoiceDetailGeneration &+= 1
        isRefreshingCreatorVoiceDetail = false
        creatorVoiceDetailMessage = nil
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
            return true
        } catch is CancellationError {
            creatorVoicesLoadState = .unknown
            return false
        } catch {
            creatorVoices = []
            creatorVoicesLoadState = .failed
            creatorMessage = Self.creatorErrorMessage(for: error)
            return false
        }
    }

    /// Read one authoritative voice profile when the user selects it. The
    /// directory response remains the list source, while this request keeps
    /// the inspector backed by the service's single-resource endpoint.
    @discardableResult
    public func refreshCreatorVoiceDetail(id: String) async -> Bool {
        creatorVoiceDetailGeneration &+= 1
        let generation = creatorVoiceDetailGeneration
        isRefreshingCreatorVoiceDetail = true
        creatorVoiceDetailMessage = nil
        defer {
            if creatorVoiceDetailGeneration == generation {
                isRefreshingCreatorVoiceDetail = false
            }
        }

        do {
            let voice = try await creatorClient.fetchVoice(id: id)
            try Task.checkCancellation()
            guard creatorVoiceDetailGeneration == generation else { return false }
            if let index = creatorVoices.firstIndex(where: { $0.id == id }) {
                creatorVoices[index] = voice
            } else {
                // A concurrent service-side create may race the directory
                // refresh. Keep the returned profile available to the user;
                // the next list refresh will establish canonical ordering.
                creatorVoices.append(voice)
                creatorVoices.sort { lhs, rhs in
                    if lhs.isSystem != rhs.isSystem { return lhs.isSystem }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard creatorVoiceDetailGeneration == generation else { return false }
            creatorVoiceDetailMessage = Self.creatorErrorMessage(for: error)
            return false
        }
    }

    public func refreshWorks() {
        do {
            works = try workStore.list()
            worksMessage = nil
        } catch {
            works = []
            worksMessage = "作品历史暂时不可用"
        }
    }

    public func loadWorkAudio(_ work: CreativeWork) throws -> Data {
        try workStore.loadAudio(for: work)
    }

    /// Where a saved work's audio lives, for reveal-in-Finder and export.
    public func workAudioURL(_ work: CreativeWork) -> URL? {
        try? workStore.audioURL(for: work)
    }

    /// Deletes a saved work and the audio file it owns. The audio is gone for
    /// good, so the caller must confirm before calling this
    /// (REDESIGN-SPEC §7.4 / D12).
    @discardableResult
    public func deleteWork(_ work: CreativeWork) -> Bool {
        if playingWorkID == work.id {
            stopAudio()
        }
        do {
            try workStore.delete(work)
            works = try workStore.list()
            worksMessage = nil
            workPlaybackMessage = nil
            workActionMessage = "“\(work.displayTitle)” 及其音频文件已从本机删除。"
            if lastCreatedWork?.id == work.id {
                lastCreatedWork = nil
            }
            return true
        } catch {
            workActionMessage = (error as? CreativeWorkStoreError)?.errorDescription
                ?? "作品删除失败，请重试"
            return false
        }
    }

    /// Renames a saved work. The audio file is not moved or rewritten.
    @discardableResult
    public func renameWork(_ work: CreativeWork, title: String) -> Bool {
        do {
            let updated = try workStore.rename(work, title: title)
            works = try workStore.list()
            worksMessage = nil
            workActionMessage = "作品已重命名为“\(updated.title)”。"
            return true
        } catch {
            workActionMessage = (error as? CreativeWorkStoreError)?.errorDescription
                ?? "作品重命名失败，请重试"
            return false
        }
    }

    /// Own the request task at the app-model level so navigating between pages
    /// cannot orphan a submitted generation or remove its cancellation handle.
    public func startSynthesisAndSave(
        text: String,
        voice: CreatorVoice,
        speed: Double
    ) {
        guard synthesisTask == nil, !isCreatingSpeech else { return }
        lastCreatedWork = nil
        workPlaybackMessage = nil
        synthesisTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.synthesizeAndSave(text: text, voice: voice, speed: speed)
            self.synthesisTask = nil
        }
    }

    public func cancelSynthesis() {
        synthesisTask?.cancel()
    }

    public func synthesizeAndSave(
        text: String,
        voice: CreatorVoice,
        speed: Double
    ) async -> CreativeWork? {
        guard !isCreatingSpeech else { return nil }
        guard !Task.isCancelled else { return nil }
        let scriptText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scriptText.isEmpty else {
            creatorMessage = "请先输入配音文稿"
            return nil
        }
        guard scriptText.count <= SpeechRailCreatorLimits.speechTextMaximumLength else {
            creatorMessage = "配音文稿不能超过 \(SpeechRailCreatorLimits.speechTextMaximumLength) 个字符"
            return nil
        }
        guard voice.available else {
            creatorMessage = "当前音色暂不可用于配音"
            return nil
        }
        guard voice.mode != "clone" || speed == 1.0 else {
            creatorMessage = "参考音色当前只支持 1.0x 语速"
            return nil
        }

        stopAudio()
        isCreatingSpeech = true
        creatorMessage = nil
        defer { isCreatingSpeech = false }

        do {
            let data = try await creatorClient.createSpeech(
                text: scriptText,
                voiceID: voice.id,
                speed: speed,
                options: speechRequestOptions(for: voice)
            )
            try Task.checkCancellation()
            let workID = "work_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let work = CreativeWork(
                id: workID,
                // 名称取文稿首行的整行：截断由行内按可用宽度做，不在写入时预截
                // （用户反馈「文本应随 UI 宽度自然截断，见 `CreativeWork.generatedTitle`」）。
                title: CreativeWork.generatedTitle(fromScript: scriptText),
                scriptText: scriptText,
                voiceID: voice.id,
                voiceName: voice.name,
                durationSeconds: audioPlaybackController.duration(for: data),
                audioFileName: "\(workID).wav"
            )
            try workStore.save(work, audioData: data)
            do {
                works = try workStore.list()
                worksMessage = nil
            } catch {
                // The audio and index write already succeeded. Keep the
                // generated work as the authoritative result and surface the
                // list refresh problem separately instead of reporting a
                // successful synthesis as a failed request.
                worksMessage = "作品已保存，但作品列表暂时无法刷新"
            }
            workPlaybackMessage = nil
            do {
                try audioPlaybackController.play(data: data)
                isAudioPlaying = audioPlaybackController.isPlaying
                playingWorkID = work.id
                cacheEnvelope(key: Self.envelopeKey(kind: "work", id: work.id)) { buckets in
                    AudioEnvelope.levels(forAudioData: data, buckets: buckets)
                }
            } catch {
                clearPlaybackState()
                workPlaybackMessage = "作品已保存，但本次音频无法播放；可以在“我的作品”中重新试听。"
            }
            lastCreatedWork = work
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
            do {
                try audioPlaybackController.play(data: data)
            } catch {
                clearPlaybackState()
                throw error
            }
            isAudioPlaying = audioPlaybackController.isPlaying
            playingWorkID = work.id
            // 播放控制器只有一个，动手播作品就说明音色试听已经结束：留下旧的
            // playingVoiceID 会让音色库显示一个并不在响的“停止试听”状态
            // (REDESIGN-SPEC §7.1：全 App 同一时刻只有一个声音)。
            playingVoiceID = nil
            workPlaybackMessage = nil
            cacheEnvelope(key: Self.envelopeKey(kind: "work", id: work.id)) { buckets in
                AudioEnvelope.levels(forAudioData: data, buckets: buckets)
            }
        } catch {
            workPlaybackMessage = "作品音频暂时不可用，请重新生成或确认本机作品文件仍在。"
        }
    }

    /// 读取一次同代的 capability snapshot 与安全音色目录。
    ///
    /// 能力快照是唯一的跨对象发现真相；ETag/304 只复用上一份完整快照，加载中和
    /// 失败时不会把旧结论清空，也不会用 legacy `/v1/models` 伪造一个新的 snapshot。
    public func refreshDiscovery() async {
        guard !isRefreshingDiscovery else { return }
        isRefreshingDiscovery = true
        defer { isRefreshingDiscovery = false }

        discoveryRefreshGeneration &+= 1
        let refreshGeneration = discoveryRefreshGeneration
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

    /// 读取服务公开的 legacy 能力投影（`GET /v1/models`）。
    ///
    /// 新服务先从 atomic snapshot 的显式 operations/model identity 生成兼容视图；
    /// 只有旧服务返回 404/405 或 snapshot schema 无法识别时，才读取 `/v1/models`。
    /// 鉴权、冲突、未就绪和其他服务错误不会静默降级成成功。
    public func refreshServiceCapabilities() async {
        guard !isRefreshingServiceCapabilities else { return }
        isRefreshingServiceCapabilities = true
        serviceCapabilitiesLoadState = .loading
        defer { isRefreshingServiceCapabilities = false }

        if discoveryState.shouldRetryOnRefresh {
            await refreshDiscovery()
        }

        if discoveryState == .loaded, let snapshot = effectiveCapabilities {
            serviceCapabilities = Self.legacyCapabilities(from: snapshot)
            serviceCapabilitiesLoadState = .loaded
            return
        }

        guard discoveryState == .notSupported || discoveryState == .invalidContract else {
            serviceCapabilities = nil
            serviceCapabilitiesLoadState = switch discoveryState {
            case .unauthorized, .notReady, .failed:
                .failed
            default:
                .unknown
            }
            return
        }

        do {
            serviceCapabilities = try await capabilityClient.fetchModelCapabilities()
            serviceCapabilitiesLoadState = .loaded
        } catch is CancellationError {
            // 取消不是结论：丢掉未完成的读取，回到“还没有读到”。
            serviceCapabilitiesLoadState = .unknown
        } catch {
            serviceCapabilities = nil
            serviceCapabilitiesLoadState = .failed
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

    private static func legacyCapabilities(
        from snapshot: EffectiveCapabilitySnapshot
    ) -> ServiceModelCapabilities {
        let preview = operationStatus(snapshot.operations["voice_preview"]) == "supported"
        let instruction = operationStatus(
            operationObject(snapshot.operations["voice_preview"])?["instruction"]
        ) == "supported"
        // `tts_clone` is a configured capability identity, not an inference from
        // whether a user currently owns a clone voice.
        let clone = snapshot.models["tts_clone"]?.artifact != nil
        return ServiceModelCapabilities(
            supportsPreview: preview,
            supportsClone: clone,
            supportsInstruction: instruction
        )
    }

    private static func operationObject(
        _ value: JSONValue?
    ) -> [String: JSONValue]? {
        guard let value,
              case let .object(object) = value.storage
        else { return nil }
        return object
    }

    private static func operationStatus(
        _ value: JSONValue?
    ) -> String? {
        guard let object = operationObject(value),
              case let .string(status) = object["status"]?.storage
        else { return nil }
        return status
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
        controlPlaneMessage = nil
        profiles = []
        profile = nil
        // 能力清单与健康快照同源（都是本机服务），一次刷新一起更新。能力读取失败
        // 只影响能力结论，不回退已经读到的健康快照。
        await refreshServiceCapabilities()
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
            controlPlaneMessage = Self.controlErrorMessage(for: error, fallback: "控制 Agent 尚未连接")
            message = controlPlaneMessage
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
        operationGeneration &+= 1
        await refreshModels(expectedGeneration: operationGeneration)
    }

    /// - Parameter expectedGeneration: 发起这次刷新的操作链所持有的代数。等待响应期间
    ///   只要有更新的 execute / cancel / refresh 入口 bump 过代数，这次刷新就不再落地，
    ///   过期的取消链因此无法覆盖新状态（issue #88）。
    private func refreshModels(expectedGeneration: UInt64) async {
        guard expectedGeneration == operationGeneration else { return }
        guard !isRefreshingModels else { return }
        isRefreshingModels = true
        defer { isRefreshingModels = false }
        refreshControlAgentStatus()
        do {
            let catalog = try await transport.send(ControlRequest(command: .modelCatalog))
            guard expectedGeneration == operationGeneration else { return }
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
            guard expectedGeneration == operationGeneration else { return }
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
        } catch is CancellationError {
            return
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
        guard !isRefreshingPreflight else { return }
        isRefreshingPreflight = true
        defer { isRefreshingPreflight = false }
        refreshControlAgentStatus()
        preflightMessage = nil
        preflightRequestID = nil
        do {
            let response = try await transport.send(ControlRequest(command: .preflight))
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
            preflightChecks = []
            preflightMessage = Self.controlErrorMessage(for: error, fallback: "预检暂时不可用")
        }
    }

    public func prepareModels(for profile: SpeechRailProfile) async {
        await execute(.modelPrepare, profile: profile)
    }

    public func cancelCurrentOperation() async {
        guard canExecuteMutation(for: .operationCancel) else { return }
        guard let operationID = operation?.operationID else { return }
        operationGeneration &+= 1
        let generation = operationGeneration
        message = "正在停止模型准备…"
        do {
            let response = try await transport.send(
                ControlRequest(command: .operationCancel, operationID: operationID)
            )
            guard generation == operationGeneration else { return }
            operation = response.operation ?? operation
            if response.status == .failed {
                message = response.message ?? "无法取消操作"
            } else if response.operation?.phase?.lowercased() == "cancelling" {
                if case .superseded = await waitForOperation(operationID, generation: generation) {
                    return
                }
                await refreshModels(expectedGeneration: generation)
            } else if response.status == .cancelled {
                message = "模型准备已取消"
            } else {
                // 确认收到但既无 cancelling 相位也无终态快照（如旧 UI 测试替身）：
                // 刷新一次，别把「正在停止…」的待定文案永久留在界面上。
                await refreshModels(expectedGeneration: generation)
            }
        } catch is CancellationError {
            return
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
        operationGeneration &+= 1
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
            if response.status == .failed
                || response.status == .cancelled
                || response.status == .rolledBack
            {
                let fallbackMessage = response.status == .cancelled ? "操作已取消" : "操作未完成"
                let failureMessage = response.message ?? fallbackMessage
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
                switch await waitForOperation(operationID) {
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

    private func waitForOperation(
        _ operationID: String,
        generation: UInt64? = nil
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
                        message = response.operation?.message ?? response.message ?? "操作失败"
                        return .failed
                    }
                    return .committed
                }
            } catch is CancellationError {
                return .cancelled
            } catch {
                message = Self.controlErrorMessage(for: error, fallback: "无法读取操作状态")
                return .failed
            }
        }
        message = "操作仍在后台运行"
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

    private static func creatorErrorMessage(for error: Error) -> String {
        if let workStoreError = error as? CreativeWorkStoreError {
            return switch workStoreError {
            case .invalidWorkID:
                "生成结果的作品标识无效，请重试"
            case .invalidTitle:
                "作品名称不能为空"
            case .storageUnavailable:
                "音频已生成，但本机作品库未能完成保存；请检查磁盘权限和可用空间后重试"
            case .audioUnavailable:
                "服务没有返回可保存音频，请检查服务状态后重试"
            }
        }
        guard let error = error as? ServiceAPIClientError else {
            return "创作服务暂时不可用"
        }
        switch error {
        case .invalidURL:
            return "创作服务地址无效，请检查服务状态"
        case .invalidResponse:
            return "创作服务返回了无法识别的结果，请运行诊断后重试"
        case .requestFailed:
            return "无法连接本机 SpeechRail 服务，请检查服务状态后重试"
        case .requestTimedOut:
            return "创作服务响应超时，请稍后重试"
        case .notModifiedWithoutCache:
            return "创作服务缓存已失效，请重新读取后重试"
        case .invalidContract:
            return "创作服务版本不匹配，请运行诊断后重试"
        case let .http(_, code, _, _, _):
            switch code {
            case "invalid_api_key":
                return "本机服务凭据不可用，请检查服务配置后重试"
            case "model_not_found":
                return "当前模型未在服务端登记，请到模型页核对模型目录"
            case "backend_not_ready":
                return "语音服务尚未就绪，请先检查服务状态"
            case "dependency_missing":
                return "语音服务依赖未就绪，请运行诊断后重试"
            case "voice_store_unavailable":
                return "音色库暂时不可用，请稍后重试"
            case "voice_in_use":
                return "该音色正在使用，暂时无法删除；停止相关任务后重试"
            case "voice_deletion_failed":
                return "音色删除未完成，请重试或打开诊断"
            case "voice_creation_failed":
                return "音色创建未完成，请检查输入后重试"
            case "voice_update_unsupported":
                return "该音色的来源或系统属性不可修改"
            case "voice_update_failed":
                return "音色修改未保存，请检查输入后重试"
            case "invalid_name":
                return "音色名称不能为空，请修改后重试"
            case "invalid_instruction":
                return "音色描述无效，请检查内容后重试"
            case "invalid_seed":
                return "采样种子无效，请填写 0–4294967295 之间的整数"
            case "invalid_ref_text":
                return "参考文案需要 20–240 个字符，请调整后重试"
            case "voice_not_found", "voice_not_available":
                return "所选音色当前不可用，请重新选择"
            case "clone_speed_unsupported":
                return "参考音色当前只支持 1.0x 语速"
            case "voice_preview_unsupported":
                return "当前档位不支持音色预览"
            case "voice_cloning_unsupported":
                return "当前档位未提供参考音色能力；请到模型管理查看服务公布的可用档位"
            case "voice_quality_reject":
                return "生成的参考音频未通过质量检查，请调整描述或参考文案后重试"
            case "transcript_mismatch":
                return "生成音频与参考文案未能匹配，请调整参考文案后重试"
            case "transcription_unavailable":
                return "本地语音识别校验暂不可用，请检查服务状态后重试"
            case "output_invalid":
                return "服务生成的参考音频无效，请重试或打开诊断"
            case "audio_too_short":
                return "参考音频过短，请使用更完整的音频后重试"
            case "audio_too_long":
                return "参考音频过长，请缩短音频后重试"
            case "voice_reference_too_short":
                return "服务生成的参考音频过短，请调整描述或参考文案后重试"
            case "invalid_audio", "audio_decode_failed":
                return "参考音频无法识别，请检查文件格式后重试"
            case "empty_audio", "tts_audio_invalid":
                return "服务没有返回可播放音频，请检查服务状态后重试"
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
        guard controlPlaneMessage == nil else {
            message = "控制 Agent 不可用，请重新读取或运行诊断"
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
