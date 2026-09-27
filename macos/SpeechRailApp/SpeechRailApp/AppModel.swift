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

public enum AppCapabilityAvailability: Equatable, Sendable {
    case available
    case unsupported
    case checking
    case unknown
    case unavailable
}

public struct RealtimeCapabilityBinding: Equatable, Sendable {
    public let asrModelRevision: String
    public let canonicalVoiceID: String?
    public let voiceRevision: String?
    public let ttsModelRevision: String?

    public var includesSpeech: Bool {
        canonicalVoiceID != nil
            && voiceRevision != nil
            && ttsModelRevision != nil
    }

    public init(
        asrModelRevision: String,
        canonicalVoiceID: String? = nil,
        voiceRevision: String? = nil,
        ttsModelRevision: String? = nil
    ) {
        self.asrModelRevision = asrModelRevision
        self.canonicalVoiceID = canonicalVoiceID
        self.voiceRevision = voiceRevision
        self.ttsModelRevision = ttsModelRevision
    }
}

/// Pure interpretation of one effective capability snapshot.
///
/// Views and request builders use this same value so discovery errors, declared
/// support, and per-voice operations cannot drift into separate gates.
public struct AppCapabilityFacade: Equatable, Sendable {
    public let snapshot: EffectiveCapabilitySnapshot?
    public let discoveryState: CapabilityDiscoveryState

    public init(
        snapshot: EffectiveCapabilitySnapshot?,
        discoveryState: CapabilityDiscoveryState
    ) {
        self.snapshot = snapshot
        self.discoveryState = discoveryState
    }

    public func availability(ofTopLevelOperation name: String) -> AppCapabilityAvailability {
        guard discoveryState == .loaded else { return availabilityWithoutSnapshot }
        guard let snapshot else { return availabilityWithoutSnapshot }
        guard let value = snapshot.operations[name] else { return .unknown }
        return Self.status(value)
    }

    public func availability(
        ofVoiceOperation name: String,
        voiceID: String
    ) -> AppCapabilityAvailability {
        guard discoveryState == .loaded else { return availabilityWithoutSnapshot }
        guard let snapshot else { return availabilityWithoutSnapshot }
        guard let voice = Self.matchingVoice(voiceID, in: snapshot) else { return .unknown }
        guard voice.available else { return .unsupported }
        guard let operation = voice.operations[name] else { return .unsupported }
        return Self.declaredVoiceOperationStatus(operation)
    }

    public var voiceCloneAvailability: AppCapabilityAvailability {
        guard discoveryState == .loaded else { return availabilityWithoutSnapshot }
        guard let snapshot else { return availabilityWithoutSnapshot }
        guard let model = snapshot.models["tts_clone"] else { return .unsupported }
        switch model.assurance {
        case .unknown:
            return .unsupported
        case .unknownValue:
            return .unknown
        case .configuredCatalog:
            guard Self.nonEmpty(model.artifact) != nil,
                  Self.nonEmpty(model.catalogRevision) != nil
            else {
                return .unknown
            }
        }
        return .available
    }

    public var voiceDesignCreationAvailability: AppCapabilityAvailability {
        combined(
            availability(ofTopLevelOperation: "voice_preview"),
            availability(ofTopLevelOperation: "transcription")
        )
    }

    public var voiceDesignValidationAvailability: AppCapabilityAvailability {
        combined(
            voiceCloneAvailability,
            availability(ofTopLevelOperation: "transcription")
        )
    }

    public func speechRequestOptions(for voiceID: String) -> SpeechRailRequestOptions? {
        guard discoveryState == .loaded else { return nil }
        return SpeechRailCapabilityRevisionSelector.creatorRequestOptions(
            voiceID: voiceID,
            in: snapshot
        )
    }

    public func realtimeBinding(for voiceID: String? = nil) -> RealtimeCapabilityBinding? {
        guard discoveryState == .loaded,
              let snapshot,
              Self.status(snapshot.operations["realtime_transcription"]) == .available,
              let asrRevision = Self.nonEmpty(snapshot.models["asr"]?.catalogRevision)
        else {
            return nil
        }
        guard let voiceID else {
            return RealtimeCapabilityBinding(asrModelRevision: asrRevision)
        }
        guard let voice = Self.matchingVoice(voiceID, in: snapshot),
              voice.available,
              let realtimeSpeech = voice.operations["realtime_speech"],
              Self.declaredVoiceOperationStatus(realtimeSpeech) == .available,
              let voiceRevision = Self.nonEmpty(voice.voiceRevision),
              let ttsModelRevision = Self.nonEmpty(voice.model.catalogRevision)
        else {
            return nil
        }
        return RealtimeCapabilityBinding(
            asrModelRevision: asrRevision,
            canonicalVoiceID: voice.id,
            voiceRevision: voiceRevision,
            ttsModelRevision: ttsModelRevision
        )
    }

    private var availabilityWithoutSnapshot: AppCapabilityAvailability {
        switch discoveryState {
        case .idle, .loading:
            .checking
        case .loaded:
            .unknown
        case .notSupported, .notReady, .unauthorized, .invalidContract, .failed:
            .unavailable
        }
    }

    private func combined(
        _ lhs: AppCapabilityAvailability,
        _ rhs: AppCapabilityAvailability
    ) -> AppCapabilityAvailability {
        if lhs == .unavailable || rhs == .unavailable { return .unavailable }
        if lhs == .unsupported || rhs == .unsupported { return .unsupported }
        if lhs == .checking || rhs == .checking { return .checking }
        if lhs == .unknown || rhs == .unknown { return .unknown }
        return .available
    }

    private static func status(_ value: JSONValue?) -> AppCapabilityAvailability {
        guard let value else { return .unknown }
        let rawStatus: String
        switch value.storage {
        case let .string(value):
            rawStatus = value
        case let .object(fields):
            guard case let .string(value)? = fields["status"]?.storage else {
                return .unknown
            }
            rawStatus = value
        default:
            return .unknown
        }
        switch rawStatus {
        case "supported": return AppCapabilityAvailability.available
        case "unsupported": return AppCapabilityAvailability.unsupported
        default: return AppCapabilityAvailability.unknown
        }
    }

    private static func declaredVoiceOperationStatus(
        _ value: JSONValue
    ) -> AppCapabilityAvailability {
        guard case let .object(fields) = value.storage,
              case .object? = fields["parameters"]?.storage
        else {
            return .unknown
        }
        return .available
    }

    private static func matchingVoice(
        _ voiceID: String,
        in snapshot: EffectiveCapabilitySnapshot
    ) -> SafeVoiceEntry? {
        let matches = snapshot.voices.filter {
            $0.id == voiceID || $0.aliases.contains(voiceID)
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

private struct SpeechBindingUnavailableError: LocalizedError {
    let unauthorized: Bool

    init(unauthorized: Bool = false) {
        self.unauthorized = unauthorized
    }

    var errorDescription: String? {
        if unauthorized {
            return "本机服务凭据不可用，请检查服务配置后重试。"
        }
        return "无法确认所选音色的当前版本，请刷新音色和服务信息后重试。"
    }
}

private struct CloneRegistrationContext: Equatable, Sendable {
    let audio: Data
    let referenceText: String
    let name: String
    let voiceID: String
    let idempotencyKey: String
}

private struct VoiceDesignPublicationContext: Equatable, Sendable {
    let slot: String
    let name: String
    let instruction: String
    let referenceText: String
    let seed: Int
    let voiceID: String
    let idempotencyKey: String
    var candidateID: String?
    var candidateRevision: String?
    var validationID: String?
}

private enum VoiceDesignPublicationRetryStep: Equatable {
    case createCandidate
    case loadReferenceAudio
    case confirmReference
    case validate
    case loadValidationAudio
    case submitReview
    case publish
    case cancelCandidate
}

private enum VoiceDesignPublicationTaskStep {
    case createCandidate
    case confirmReference
    case loadReferenceAudio
    case validate
    case resumeValidation
    case loadValidationAudio
    case submitReviewAndPublish
    case publish
    case cancelCandidate
}

private enum VoiceDesignPlaybackIdentity: Equatable {
    case reference(candidateID: String, revision: String)
    case validation(candidateID: String, revision: String, validationID: String)
}

private enum CloneIdempotencyLookup {
    case new
    case pending
    case completed(CreatorVoice)
    case notFound
    case unknown(String)
    case failed(String)
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

public enum VoiceDesignPublicationPhase: Equatable, Sendable {
    case idle
    case creatingCandidate
    case loadingReferenceAudio
    case awaitingReferenceReview
    case confirmingReference
    case validating
    case loadingValidationAudio
    case awaitingValidationReview
    case submittingReview
    case publishing
    case cancelling
    case published
    case failed
}

public struct VoiceDesignPublicationSnapshot: Equatable, Sendable {
    public var phase: VoiceDesignPublicationPhase
    public var candidateID: String?
    public var candidateRevision: String?
    public var validationID: String?
    public var referenceAudioData: Data?
    public var validationAudioData: Data?
    public var referenceAudioWasPlayed: Bool
    public var validationAudioWasPlayed: Bool
    public var message: String?

    public init(
        phase: VoiceDesignPublicationPhase = .idle,
        candidateID: String? = nil,
        candidateRevision: String? = nil,
        validationID: String? = nil,
        referenceAudioData: Data? = nil,
        validationAudioData: Data? = nil,
        referenceAudioWasPlayed: Bool = false,
        validationAudioWasPlayed: Bool = false,
        message: String? = nil
    ) {
        self.phase = phase
        self.candidateID = candidateID
        self.candidateRevision = candidateRevision
        self.validationID = validationID
        self.referenceAudioData = referenceAudioData
        self.validationAudioData = validationAudioData
        self.referenceAudioWasPlayed = referenceAudioWasPlayed
        self.validationAudioWasPlayed = validationAudioWasPlayed
        self.message = message
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
    /// 一次配音生成的待保存结果：音频只在内存，身份已固定。
    /// 只有用户显式保存后才写入作品库；取消、失败或离开页面即丢弃。
    public struct PendingDubbingRender: Equatable, Sendable {
        public let scriptText: String
        public let voiceID: String
        public let voiceName: String
        public let voiceRevision: String?
        public let planID: String?
        public let speed: Double
        public let durationSeconds: Double?
        public let audioData: Data

        public var generatedTitle: String {
            CreativeWork.generatedTitle(fromScript: scriptText)
        }

        public var durationText: String? {
            guard let durationSeconds else { return nil }
            let totalSeconds = max(0, Int(durationSeconds.rounded()))
            return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
        }
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
    public var isVoiceDesignAudioPlaying: Bool {
        isAudioPlaying && voiceDesignPlaybackIdentity != nil
    }
    /// 当前音频的**真实**播放进度 0…1（`AVAudioPlayer.currentTime / duration`）。
    /// 详情面板的波形用它表示「播到哪了」（REDESIGN-SPEC §11.6 第五十七轮）。
    public private(set) var playbackProgress: Double = 0
    /// The effective snapshot is the only capability and revision source.
    public private(set) var effectiveCapabilities: EffectiveCapabilitySnapshot?
    public private(set) var safeVoiceCatalog: SafeVoiceList?
    public private(set) var discoveryState: CapabilityDiscoveryState = .idle
    public private(set) var discoveryMetadata: ServiceResponseMetadata?
    public private(set) var isRefreshingDiscovery = false
    public var capabilityFacade: AppCapabilityFacade {
        AppCapabilityFacade(snapshot: effectiveCapabilities, discoveryState: discoveryState)
    }
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
    /// 配音台已生成、尚未显式保存的内存音频及制作身份。
    /// 只有用户点击保存后才写入作品库；取消、失败或离开页面即丢弃。
    public private(set) var pendingDubbing: PendingDubbingRender?
    public private(set) var isCreatingVoicePreview = false
    public private(set) var voiceDesignCandidates: [VoiceDesignCandidateSnapshot] = []
    public private(set) var voiceDesignSavedSlots: Set<String> = []
    public private(set) var voiceDesignSavingSlot: String?
    public private(set) var isGeneratingVoiceDesign = false
    public private(set) var voiceDesignErrorMessage: String?
    public private(set) var voiceDesignSuccessMessage: String?
    public private(set) var voiceDesignPublication = VoiceDesignPublicationSnapshot()
    public private(set) var isRegisteringVoice = false
    public var isCancellingVoiceDesignPublication: Bool {
        voiceDesignPublication.phase == .cancelling
    }
    public var canRetryVoiceDesignCancellation: Bool {
        voiceDesignPublication.phase == .failed
            && voiceDesignPublicationRetryStep == .cancelCandidate
    }
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
    private let creatorClient: any SpeechRailCreatorClient
    private let audioPlaybackController: AudioPlaybackController
    private let workStore: CreativeWorkStore
    private let observabilityLocation: ObservabilityLocation
    private let registration: ControlAgentRegistration?
    private var cloneRegistrationContext: CloneRegistrationContext?
    private var voiceDesignPublicationContext: VoiceDesignPublicationContext?
    private var voiceDesignPublicationRetryStep: VoiceDesignPublicationRetryStep?
    private var voiceDesignPublicationGeneration: UInt64 = 0
    private var voiceDesignPlaybackIdentity: VoiceDesignPlaybackIdentity?
    private var healthRefreshGeneration: UInt64 = 0
    private var metricsRefreshGeneration: UInt64 = 0
    private var monitoringHistoryGeneration: UInt64 = 0
    private var creatorVoiceDetailGeneration: UInt64 = 0
    private var creatorVoiceRefreshGeneration: UInt64 = 0
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
        discoveryClient: (any ServiceCapabilityDiscoveryClient)? = nil,
        creatorClient: (any SpeechRailCreatorClient)? = nil,
        audioPlaybackController: AudioPlaybackController = AudioPlaybackController(),
        workStore: CreativeWorkStore = CreativeWorkStore(),
        observabilityLocation: ObservabilityLocation = .default,
        registration: ControlAgentRegistration? = nil
    ) {
        self.transport = transport
        self.apiClient = apiClient
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
            self.noteVoiceDesignAudioPlaybackFinished(successfully: successfully)
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

    public func realtimeCapabilityBinding(for voiceID: String? = nil) async -> RealtimeCapabilityBinding? {
        if let binding = capabilityFacade.realtimeBinding(for: voiceID) {
            return binding
        }
        await refreshDiscovery()
        return capabilityFacade.realtimeBinding(for: voiceID)
    }

    private func speechRequestOptions(for voiceID: String) async throws -> SpeechRailRequestOptions {
        if let options = capabilityFacade.speechRequestOptions(for: voiceID) {
            return options
        }

        await refreshDiscovery()
        guard let options = capabilityFacade.speechRequestOptions(for: voiceID) else {
            throw SpeechBindingUnavailableError(unauthorized: discoveryState == .unauthorized)
        }
        return options
    }

    public func createSpeech(
        text: String,
        voiceID: String,
        speed: Double,
        language: String? = nil
    ) async throws -> Data {
        let options = try await speechRequestOptions(for: voiceID)
        return try await creatorClient.createSpeech(
            text: text,
            voiceID: voiceID,
            speed: speed,
            options: options,
            language: language
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

    public func startVoiceDesignPublication(
        _ candidate: VoiceDesignCandidateSnapshot,
        name: String
    ) {
        guard voiceDesignSaveTask == nil,
              voiceDesignSavingSlot == nil,
              voiceDesignPublicationContext == nil
        else {
            return
        }
        guard case .ready = candidate.status, candidate.audioData != nil else { return }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            voiceDesignErrorMessage = "请先填写保存名称"
            return
        }
        guard !candidate.instructionSnapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            voiceDesignErrorMessage = "请先填写音色描述"
            return
        }
        guard (SpeechRailCreatorLimits.referenceTextMinimumLength...SpeechRailCreatorLimits.referenceTextMaximumLength)
            .contains(candidate.referenceTextSnapshot.trimmingCharacters(in: .whitespacesAndNewlines).count)
        else {
            voiceDesignErrorMessage = "参考文案需要 20–240 个字符"
            return
        }

        let voiceID = "voice_design_" + UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        let idempotencyKey = "voice-design-" + UUID().uuidString.lowercased()
        voiceDesignPublicationContext = VoiceDesignPublicationContext(
            slot: candidate.slot,
            name: trimmedName,
            instruction: candidate.instructionSnapshot.trimmingCharacters(in: .whitespacesAndNewlines),
            referenceText: candidate.referenceTextSnapshot.trimmingCharacters(in: .whitespacesAndNewlines),
            seed: max(0, candidate.seed),
            voiceID: voiceID,
            idempotencyKey: idempotencyKey
        )
        voiceDesignPublicationGeneration &+= 1
        let generation = voiceDesignPublicationGeneration
        voiceDesignPublicationRetryStep = nil
        voiceDesignPublication = VoiceDesignPublicationSnapshot(phase: .creatingCandidate)
        voiceDesignErrorMessage = nil
        voiceDesignSuccessMessage = nil
        voiceDesignSavingSlot = candidate.slot
        stopAudio()
        scheduleVoiceDesignPublicationTask(.createCandidate, generation: generation)
    }

    public func confirmVoiceDesignReference() {
        guard voiceDesignPublication.phase == .awaitingReferenceReview else { return }
        guard voiceDesignPublication.referenceAudioWasPlayed else {
            voiceDesignPublication.message = "请先完整试听这段候选参考音频，再继续复验。"
            return
        }
        voiceDesignPublication.message = nil
        voiceDesignPublication.phase = .confirmingReference
        scheduleVoiceDesignPublicationTask(
            .confirmReference,
            generation: voiceDesignPublicationGeneration
        )
    }

    public func publishVoiceDesignPublication(
        identityConfirmed: Bool,
        naturalnessConfirmed: Bool
    ) {
        guard voiceDesignPublication.phase == .awaitingValidationReview else { return }
        guard voiceDesignPublication.validationAudioWasPlayed else {
            voiceDesignPublication.message = "请先试听本次复验输出，再提交人工确认。"
            return
        }
        guard identityConfirmed, naturalnessConfirmed else {
            voiceDesignPublication.message = "请确认音色身份与自然度后再保存。"
            return
        }
        voiceDesignPublication.message = nil
        voiceDesignPublication.phase = .submittingReview
        scheduleVoiceDesignPublicationTask(
            .submitReviewAndPublish,
            generation: voiceDesignPublicationGeneration
        )
    }

    public func retryVoiceDesignPublication() {
        guard voiceDesignPublication.phase == .failed,
              let retryStep = voiceDesignPublicationRetryStep,
              voiceDesignSaveTask == nil
        else {
            return
        }
        voiceDesignPublication.message = nil
        voiceDesignErrorMessage = nil
        let step: VoiceDesignPublicationTaskStep
        switch retryStep {
        case .createCandidate:
            step = .createCandidate
        case .loadReferenceAudio:
            step = .loadReferenceAudio
        case .confirmReference:
            step = .confirmReference
        case .validate:
            step = .resumeValidation
        case .loadValidationAudio:
            step = .loadValidationAudio
        case .submitReview:
            step = .submitReviewAndPublish
        case .publish:
            step = .publish
        case .cancelCandidate:
            step = .cancelCandidate
            voiceDesignPublication.phase = .cancelling
        }
        scheduleVoiceDesignPublicationTask(
            step,
            generation: voiceDesignPublicationGeneration
        )
    }

    public func cancelVoiceDesignPublication() {
        guard voiceDesignPublication.phase != .published,
              voiceDesignPublication.phase != .cancelling
        else {
            return
        }
        let context = voiceDesignPublicationContext
        voiceDesignPublicationGeneration &+= 1
        let generation = voiceDesignPublicationGeneration
        voiceDesignSaveTask?.cancel()
        voiceDesignSaveTask = nil
        voiceDesignPlaybackIdentity = nil
        stopAudio()
        voiceDesignErrorMessage = nil
        guard let context else {
            voiceDesignPublicationRetryStep = nil
            voiceDesignPublication = VoiceDesignPublicationSnapshot()
            voiceDesignSavingSlot = nil
            isRegisteringVoice = false
            return
        }
        voiceDesignPublicationRetryStep = .cancelCandidate
        voiceDesignPublication = VoiceDesignPublicationSnapshot(
            phase: .cancelling,
            candidateID: context.candidateID,
            candidateRevision: context.candidateRevision
        )
        scheduleVoiceDesignPublicationTask(.cancelCandidate, generation: generation)
    }

    func markVoiceDesignReferenceAudioPlaybackFinished(successfully: Bool) {
        guard successfully,
              voiceDesignPublication.phase == .awaitingReferenceReview,
              voiceDesignPublication.referenceAudioData != nil
        else {
            return
        }
        voiceDesignPublication.referenceAudioWasPlayed = true
    }

    func markVoiceDesignValidationAudioPlaybackFinished(successfully: Bool) {
        guard successfully,
              voiceDesignPublication.phase == .awaitingValidationReview,
              voiceDesignPublication.validationAudioData != nil
        else {
            return
        }
        voiceDesignPublication.validationAudioWasPlayed = true
    }

    private func scheduleVoiceDesignPublicationTask(
        _ step: VoiceDesignPublicationTaskStep,
        generation: UInt64
    ) {
        guard voiceDesignSaveTask == nil,
              generation == voiceDesignPublicationGeneration,
              voiceDesignPublicationContext != nil
        else {
            return
        }
        isRegisteringVoice = true
        voiceDesignSavingSlot = voiceDesignPublicationContext?.slot
        voiceDesignSaveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performVoiceDesignPublicationTask(step, generation: generation)
            guard self.voiceDesignPublicationGeneration == generation else { return }
            self.isRegisteringVoice = false
            self.voiceDesignSaveTask = nil
        }
    }

    private func performVoiceDesignPublicationTask(
        _ step: VoiceDesignPublicationTaskStep,
        generation: UInt64
    ) async {
        guard isCurrentVoiceDesignPublication(generation),
              var context = voiceDesignPublicationContext
        else {
            return
        }

        switch step {
        case .createCandidate:
            voiceDesignPublication.phase = .creatingCandidate
            do {
                let candidate = try await creatorClient.createVoiceDesignCandidate(
                    voiceID: context.voiceID,
                    name: context.name,
                    instruction: context.instruction,
                    referenceText: context.referenceText,
                    seed: context.seed,
                    idempotencyKey: context.idempotencyKey
                )
                guard isCurrentVoiceDesignPublication(generation) else {
                    _ = try? await creatorClient.cancelVoiceDesignCandidate(id: candidate.id)
                    return
                }
                context.candidateID = candidate.id
                context.candidateRevision = candidate.revision
                voiceDesignPublicationContext = context
                voiceDesignPublication.candidateID = candidate.id
                voiceDesignPublication.candidateRevision = candidate.revision
                await loadVoiceDesignReferenceAudio(context, generation: generation)
            } catch {
                failVoiceDesignPublication(
                    error,
                    retryStep: .createCandidate,
                    generation: generation
                )
            }

        case .confirmReference:
            guard let candidateID = context.candidateID else {
                failVoiceDesignPublication(
                    "找不到这次创建的候选音色，请重试。",
                    retryStep: .createCandidate,
                    generation: generation
                )
                return
            }
            voiceDesignPublication.phase = .confirmingReference
            do {
                let confirmed = try await creatorClient.confirmVoiceDesignCandidate(
                    id: candidateID,
                    referenceText: nil
                )
                guard isCurrentVoiceDesignPublication(generation) else { return }
                guard confirmed.knownState == .confirmed else {
                    failVoiceDesignPublication(
                        "服务返回了未知候选状态；保留候选信息，不能继续复验。",
                        retryStep: .confirmReference,
                        generation: generation
                    )
                    return
                }
                let revisionChanged = context.candidateRevision != confirmed.revision
                context.candidateRevision = confirmed.revision
                context.validationID = nil
                voiceDesignPublicationContext = context
                voiceDesignPublication.candidateRevision = confirmed.revision
                voiceDesignPublication.validationID = nil
                voiceDesignPublication.validationAudioData = nil
                voiceDesignPublication.validationAudioWasPlayed = false
                if revisionChanged {
                    voiceDesignPublication.referenceAudioData = nil
                    voiceDesignPublication.referenceAudioWasPlayed = false
                    await loadVoiceDesignReferenceAudio(context, generation: generation)
                    return
                }
                await validateVoiceDesignCandidate(context, generation: generation)
            } catch {
                failVoiceDesignPublication(
                    error,
                    retryStep: .confirmReference,
                    generation: generation
                )
            }

        case .loadReferenceAudio:
            await loadVoiceDesignReferenceAudio(context, generation: generation)

        case .validate:
            await validateVoiceDesignCandidate(context, generation: generation)

        case .resumeValidation:
            guard let candidateID = context.candidateID,
                  let expectedRevision = context.candidateRevision
            else {
                failVoiceDesignPublication(
                    "候选版本信息缺失，请重试。",
                    retryStep: .createCandidate,
                    generation: generation
                )
                return
            }
            voiceDesignPublication.phase = .validating
            do {
                let latest = try await creatorClient.fetchVoiceDesignCandidate(id: candidateID)
                guard isCurrentVoiceDesignPublication(generation) else { return }
                guard let state = latest.knownState else {
                    failVoiceDesignPublication(
                        "服务返回了未知候选状态；保留候选信息，不能继续复验。",
                        retryStep: .validate,
                        generation: generation
                    )
                    return
                }
                if state == .published {
                    await reconcilePublishedVoiceDesignCandidate(
                        latest,
                        context: context,
                        generation: generation
                    )
                    return
                }
                guard [.confirmed, .validating, .publishable].contains(state) else {
                    failVoiceDesignPublication(
                        "这个候选状态已结束，不能继续复验。",
                        retryStep: .validate,
                        generation: generation
                    )
                    return
                }
                guard latest.revision == expectedRevision else {
                    context.candidateRevision = latest.revision
                    context.validationID = nil
                    voiceDesignPublicationContext = context
                    voiceDesignPublication.candidateRevision = latest.revision
                    voiceDesignPublication.validationID = nil
                    voiceDesignPublication.referenceAudioData = nil
                    voiceDesignPublication.referenceAudioWasPlayed = false
                    voiceDesignPublication.validationAudioData = nil
                    voiceDesignPublication.validationAudioWasPlayed = false
                    await loadVoiceDesignReferenceAudio(context, generation: generation)
                    return
                }
                if let validation = latest.latestValidation,
                   validation.candidateRevision == expectedRevision,
                   validation.machineStatus == VoiceDesignReview.pass.rawValue
                {
                    context.validationID = validation.validationID
                    voiceDesignPublicationContext = context
                    voiceDesignPublication.validationID = validation.validationID
                    await loadVoiceDesignValidationAudio(context, generation: generation)
                    return
                }
                await validateVoiceDesignCandidate(context, generation: generation)
            } catch {
                failVoiceDesignPublication(
                    error,
                    retryStep: .validate,
                    generation: generation
                )
            }

        case .loadValidationAudio:
            await loadVoiceDesignValidationAudio(context, generation: generation)

        case .submitReviewAndPublish:
            await submitVoiceDesignReviewAndPublish(context, generation: generation)

        case .publish:
            await publishVoiceDesignCandidate(context, generation: generation)

        case .cancelCandidate:
            await cancelVoiceDesignCandidate(context, generation: generation)
        }
    }

    private func cancelVoiceDesignCandidate(
        _ initialContext: VoiceDesignPublicationContext,
        generation: UInt64
    ) async {
        guard isCurrentVoiceDesignPublication(generation) else { return }
        var context = initialContext
        do {
            if context.candidateID == nil {
                // Recover a create whose response raced with cancellation by
                // replaying the same logical request with its original key.
                let recovered = try await creatorClient.createVoiceDesignCandidate(
                    voiceID: context.voiceID,
                    name: context.name,
                    instruction: context.instruction,
                    referenceText: context.referenceText,
                    seed: context.seed,
                    idempotencyKey: context.idempotencyKey
                )
                guard isCurrentVoiceDesignPublication(generation) else {
                    _ = try? await creatorClient.cancelVoiceDesignCandidate(id: recovered.id)
                    return
                }
                context.candidateID = recovered.id
                context.candidateRevision = recovered.revision
                voiceDesignPublicationContext = context
                voiceDesignPublication.candidateID = recovered.id
                voiceDesignPublication.candidateRevision = recovered.revision
            }
            guard let candidateID = context.candidateID else {
                failVoiceDesignPublication(
                    "无法确认候选 ID，取消操作可重试。",
                    retryStep: .cancelCandidate,
                    generation: generation
                )
                return
            }

            let current = try await creatorClient.fetchVoiceDesignCandidate(id: candidateID)
            guard isCurrentVoiceDesignPublication(generation) else { return }
            if current.knownState == .cancelled {
                finishVoiceDesignCancellation(generation: generation)
                return
            }
            if current.knownState == .published {
                await reconcilePublishedVoiceDesignCandidate(
                    current,
                    context: context,
                    generation: generation
                )
                return
            }
            guard current.knownState?.canCancel == true else {
                failVoiceDesignPublication(
                    "服务返回了未知候选状态；保留候选信息，刷新后再重试取消。",
                    retryStep: .cancelCandidate,
                    generation: generation
                )
                return
            }

            let cancelled = try await creatorClient.cancelVoiceDesignCandidate(id: candidateID)
            guard isCurrentVoiceDesignPublication(generation) else { return }
            if cancelled.knownState == .cancelled {
                finishVoiceDesignCancellation(generation: generation)
            } else if cancelled.knownState == .published {
                await reconcilePublishedVoiceDesignCandidate(
                    cancelled,
                    context: context,
                    generation: generation
                )
            } else {
                throw ServiceAPIClientError.invalidResponse
            }
        } catch {
            if await reconcileVoiceDesignCancellationOutcome(
                context: context,
                generation: generation
            ) {
                return
            }
            failVoiceDesignPublication(
                error,
                retryStep: .cancelCandidate,
                generation: generation
            )
        }
    }

    private func reconcileVoiceDesignCancellationOutcome(
        context: VoiceDesignPublicationContext,
        generation: UInt64
    ) async -> Bool {
        guard isCurrentVoiceDesignPublication(generation),
              let candidateID = context.candidateID,
              let current = try? await creatorClient.fetchVoiceDesignCandidate(id: candidateID)
        else {
            return false
        }
        guard isCurrentVoiceDesignPublication(generation) else { return true }
        if current.knownState == .cancelled {
            finishVoiceDesignCancellation(generation: generation)
            return true
        }
        if current.knownState == .published {
            await reconcilePublishedVoiceDesignCandidate(
                current,
                context: context,
                generation: generation
            )
            return true
        }
        return false
    }

    private func reconcilePublishedVoiceDesignCandidate(
        _ candidate: VoiceDesignCandidate,
        context: VoiceDesignPublicationContext,
        generation: UInt64
    ) async {
        guard isCurrentVoiceDesignPublication(generation) else { return }
        let expectedRevision = context.candidateRevision ?? candidate.revision
        guard candidate.revision == expectedRevision,
              candidate.publishedVoiceRevision == expectedRevision,
              candidate.targetVoiceID == context.voiceID,
              let voice = try? await creatorClient.fetchVoice(id: context.voiceID)
        else {
            failVoiceDesignPublication(
                "候选已发布但无法确认音色版本；请刷新音色库确认结果。",
                retryStep: .publish,
                generation: generation
            )
            await refreshCreatorVoices()
            return
        }
        await finishVoiceDesignPublication(
            voice,
            context: context,
            generation: generation
        )
    }

    private func finishVoiceDesignCancellation(generation: UInt64) {
        guard generation == voiceDesignPublicationGeneration else { return }
        voiceDesignPublicationContext = nil
        voiceDesignPublicationRetryStep = nil
        voiceDesignPublication = VoiceDesignPublicationSnapshot()
        voiceDesignSavingSlot = nil
        voiceDesignErrorMessage = nil
    }

    private func loadVoiceDesignReferenceAudio(
        _ context: VoiceDesignPublicationContext,
        generation: UInt64
    ) async {
        guard isCurrentVoiceDesignPublication(generation),
              let candidateID = context.candidateID,
              let expectedRevision = context.candidateRevision
        else {
            return
        }
        voiceDesignPublication.phase = .loadingReferenceAudio
        do {
            let candidate = try await creatorClient.fetchVoiceDesignCandidate(id: candidateID)
            guard isCurrentVoiceDesignPublication(generation) else { return }
            guard candidate.knownState?.canReadReferenceAudio == true else {
                let message = candidate.knownState == nil
                    ? "服务返回了未知候选状态；保留候选信息，不能继续试听。"
                    : "这个候选已结束，不能继续试听和发布。"
                failVoiceDesignPublication(
                    message,
                    retryStep: .loadReferenceAudio,
                    generation: generation
                )
                return
            }
            if candidate.revision != expectedRevision {
                var updated = context
                updated.candidateRevision = candidate.revision
                updated.validationID = nil
                voiceDesignPublicationContext = updated
                voiceDesignPublication.candidateRevision = candidate.revision
                voiceDesignPublication.validationID = nil
                voiceDesignPublication.validationAudioData = nil
                voiceDesignPublication.validationAudioWasPlayed = false
                voiceDesignPublication.referenceAudioWasPlayed = false
            }
            let currentRevision = candidate.revision
            let audio = try await creatorClient.fetchVoiceDesignReferenceAudio(
                id: candidateID,
                expectedRevision: currentRevision
            )
            guard isCurrentVoiceDesignPublication(generation) else { return }
            voiceDesignPublication.phase = .awaitingReferenceReview
            voiceDesignPublication.candidateRevision = currentRevision
            voiceDesignPublication.referenceAudioData = audio
            voiceDesignPublication.referenceAudioWasPlayed = false
            voiceDesignPublication.validationID = nil
            voiceDesignPublication.validationAudioData = nil
            voiceDesignPublication.validationAudioWasPlayed = false
            voiceDesignPublication.message = nil
        } catch {
            failVoiceDesignPublication(
                error,
                retryStep: .loadReferenceAudio,
                generation: generation
            )
        }
    }

    private func validateVoiceDesignCandidate(
        _ context: VoiceDesignPublicationContext,
        generation: UInt64
    ) async {
        guard isCurrentVoiceDesignPublication(generation),
              let candidateID = context.candidateID,
              let expectedRevision = context.candidateRevision
        else {
            return
        }
        voiceDesignPublication.phase = .validating
        do {
            let current = try await creatorClient.fetchVoiceDesignCandidate(id: candidateID)
            guard isCurrentVoiceDesignPublication(generation) else { return }
            guard current.revision == expectedRevision else {
                var updated = context
                updated.candidateRevision = current.revision
                updated.validationID = nil
                voiceDesignPublicationContext = updated
                voiceDesignPublication.candidateRevision = current.revision
                voiceDesignPublication.validationID = nil
                await loadVoiceDesignReferenceAudio(updated, generation: generation)
                return
            }
            guard current.knownState == .confirmed else {
                failVoiceDesignPublication(
                    current.knownState == nil
                        ? "服务返回了未知候选状态；保留候选信息，不能继续复验。"
                        : "候选状态已变化，请重新读取后再复验。",
                    retryStep: .validate,
                    generation: generation
                )
                return
            }
            let validated = try await creatorClient.validateVoiceDesignCandidate(
                id: candidateID,
                testText: nil,
                capabilityKey: nil,
                humanReview: nil
            )
            guard isCurrentVoiceDesignPublication(generation) else { return }
            guard validated.knownState == .validating
                    || validated.knownState == .failed
            else {
                failVoiceDesignPublication(
                    "服务返回了未知候选状态；保留候选信息，不能继续听审。",
                    retryStep: .validate,
                    generation: generation
                )
                return
            }
            guard validated.revision == expectedRevision,
                  let validation = validated.latestValidation,
                  validation.candidateRevision == expectedRevision
            else {
                failVoiceDesignPublication(
                    "服务返回的复验结果与当前候选版本不一致，请重新读取候选。",
                    retryStep: .validate,
                    generation: generation
                )
                return
            }
            guard validation.machineStatus == VoiceDesignReview.pass.rawValue else {
                failVoiceDesignPublication(
                    Self.voiceDesignValidationMessage(validation),
                    retryStep: .validate,
                    generation: generation
                )
                return
            }
            var updated = context
            updated.validationID = validation.validationID
            voiceDesignPublicationContext = updated
            voiceDesignPublication.validationID = validation.validationID
            await loadVoiceDesignValidationAudio(updated, generation: generation)
        } catch {
            failVoiceDesignPublication(
                error,
                retryStep: .validate,
                generation: generation
            )
        }
    }

    private func loadVoiceDesignValidationAudio(
        _ context: VoiceDesignPublicationContext,
        generation: UInt64
    ) async {
        guard isCurrentVoiceDesignPublication(generation),
              let candidateID = context.candidateID,
              let expectedRevision = context.candidateRevision,
              let validationID = context.validationID
        else {
            return
        }
        voiceDesignPublication.phase = .loadingValidationAudio
        do {
            let candidate = try await creatorClient.fetchVoiceDesignCandidate(id: candidateID)
            guard isCurrentVoiceDesignPublication(generation) else { return }
            guard candidate.knownState?.canReadValidationAudio == true,
                  candidate.revision == expectedRevision,
                  let validation = candidate.validations.first(where: {
                      $0.validationID == validationID
                          && $0.candidateRevision == expectedRevision
                  }),
                  validation.machineStatus == VoiceDesignReview.pass.rawValue
            else {
                failVoiceDesignPublication(
                    "复验结果已变化，请重新确认候选版本。",
                    retryStep: .validate,
                    generation: generation
                )
                return
            }
            let audio = try await creatorClient.fetchVoiceDesignValidationAudio(
                id: candidateID,
                validationID: validationID,
                expectedRevision: expectedRevision
            )
            guard isCurrentVoiceDesignPublication(generation) else { return }
            voiceDesignPublication.phase = .awaitingValidationReview
            voiceDesignPublication.validationAudioData = audio
            voiceDesignPublication.validationAudioWasPlayed = false
            voiceDesignPublication.message = nil
        } catch {
            failVoiceDesignPublication(
                error,
                retryStep: .loadValidationAudio,
                generation: generation
            )
        }
    }

    private func submitVoiceDesignReviewAndPublish(
        _ context: VoiceDesignPublicationContext,
        generation: UInt64
    ) async {
        guard isCurrentVoiceDesignPublication(generation),
              let candidateID = context.candidateID,
              let expectedRevision = context.candidateRevision,
              let validationID = context.validationID
        else {
            failVoiceDesignPublication(
                "候选或复验身份缺失，请重新读取后再试。",
                retryStep: .loadValidationAudio,
                generation: generation
            )
            return
        }
        do {
            let candidate = try await creatorClient.fetchVoiceDesignCandidate(id: candidateID)
            guard isCurrentVoiceDesignPublication(generation) else { return }
            guard candidate.knownState == .validating
                    || candidate.knownState == .publishable,
                  candidate.revision == expectedRevision,
                  candidate.latestValidation?.validationID == validationID,
                  candidate.latestValidation?.machineStatus == VoiceDesignReview.pass.rawValue
            else {
                failVoiceDesignPublication(
                    "候选版本或复验结果已经变化，请重新试听当前输出。",
                    retryStep: .loadValidationAudio,
                    generation: generation
                )
                return
            }
            let review = VoiceDesignHumanReview(
                validationID: validationID,
                identity: .pass,
                naturalness: .pass
            )
            let reviewed = try await creatorClient.validateVoiceDesignCandidate(
                id: candidateID,
                testText: nil,
                capabilityKey: nil,
                humanReview: review
            )
            guard isCurrentVoiceDesignPublication(generation) else { return }
            guard reviewed.knownState == .publishable,
                  reviewed.publishable,
                  reviewed.revision == expectedRevision,
                  reviewed.latestValidation?.validationID == validationID
            else {
                failVoiceDesignPublication(
                    "人工复核尚未绑定到当前复验结果，暂时不能发布。",
                    retryStep: .submitReview,
                    generation: generation
                )
                return
            }
            voiceDesignPublication.phase = .publishing
            await publishVoiceDesignCandidate(context, generation: generation)
        } catch {
            failVoiceDesignPublication(
                error,
                retryStep: .submitReview,
                generation: generation
            )
        }
    }

    private func publishVoiceDesignCandidate(
        _ context: VoiceDesignPublicationContext,
        generation: UInt64
    ) async {
        guard let candidateID = context.candidateID,
              let expectedRevision = context.candidateRevision,
              let validationID = context.validationID
        else {
            failVoiceDesignPublication(
                "候选版本信息缺失，暂时不能发布。",
                retryStep: .publish,
                generation: generation
            )
            return
        }
        voiceDesignPublication.phase = .publishing
        do {
            let current = try await creatorClient.fetchVoiceDesignCandidate(id: candidateID)
            guard isCurrentVoiceDesignPublication(generation) else { return }
            if current.knownState == .published {
                await reconcilePublishedVoiceDesignCandidate(
                    current,
                    context: context,
                    generation: generation
                )
                return
            }
            guard current.knownState == .publishable,
                  current.publishable,
                  current.revision == expectedRevision,
                  current.latestValidation?.validationID == validationID,
                  current.latestValidation?.machineStatus == VoiceDesignReview.pass.rawValue,
                  current.latestValidation?.identityStatus == .pass,
                  current.latestValidation?.naturalnessStatus == .pass
            else {
                failVoiceDesignPublication(
                    current.knownState == nil
                        ? "服务返回了未知候选状态；保留候选信息，不能发布。"
                        : "当前候选尚未处于可发布状态，请重新读取后再试。",
                    retryStep: .publish,
                    generation: generation
                )
                return
            }
            let result = try await creatorClient.publishVoiceDesignCandidate(
                id: candidateID,
                expectedCandidateRevision: expectedRevision
            )
            guard result.voice.id == context.voiceID,
                  result.voice.revision == expectedRevision,
                  result.candidate.publishedVoiceRevision == expectedRevision
            else {
                failVoiceDesignPublication(
                    "服务已返回发布结果，但音色版本与复核版本不一致。请刷新音色库确认状态。",
                    retryStep: .publish,
                    generation: generation
                )
                await refreshCreatorVoices()
                return
            }
            await finishVoiceDesignPublication(
                result.voice,
                context: context,
                generation: generation
            )
        } catch {
            if let current = try? await creatorClient.fetchVoiceDesignCandidate(id: candidateID),
               current.state == "published",
               current.publishedVoiceRevision == expectedRevision,
               let voice = try? await creatorClient.fetchVoice(id: context.voiceID)
            {
                await finishVoiceDesignPublication(
                    voice,
                    context: context,
                    generation: generation
                )
                return
            }
            failVoiceDesignPublication(
                error,
                retryStep: .publish,
                generation: generation
            )
        }
    }

    private func finishVoiceDesignPublication(
        _ voice: CreatorVoice,
        context: VoiceDesignPublicationContext,
        generation: UInt64
    ) async {
        let isCurrentGeneration = generation == voiceDesignPublicationGeneration
        if isCurrentGeneration {
            voiceDesignSavedSlots.insert(context.slot)
            voiceDesignSuccessMessage = "“\(voice.name)” 已完成复核并保存到音色库，可以开始使用。"
            voiceDesignSavingSlot = nil
            voiceDesignPublicationRetryStep = nil
            voiceDesignPublicationContext = nil
            voiceDesignPublication.phase = .published
            voiceDesignPublication.message = nil
        }

        // A completed server request can arrive after the user dismisses the
        // workflow. Refresh shared catalog state, but never let that old result
        // write into a newer publication flow or its candidate slot.
        let refreshed = await refreshCapabilitySet()
        await refreshCreatorVoices()
        if generation == voiceDesignPublicationGeneration, !refreshed {
            voiceDesignPublication.message = "音色已保存，但服务状态尚未刷新；请重新读取后再进行下一次修改。"
        }
    }

    private func failVoiceDesignPublication(
        _ error: Error,
        retryStep: VoiceDesignPublicationRetryStep,
        generation: UInt64
    ) {
        failVoiceDesignPublication(
            Self.creatorErrorMessage(for: error),
            retryStep: retryStep,
            generation: generation
        )
    }

    private func failVoiceDesignPublication(
        _ message: String,
        retryStep: VoiceDesignPublicationRetryStep,
        generation: UInt64
    ) {
        guard generation == voiceDesignPublicationGeneration else { return }
        voiceDesignPublication.phase = .failed
        voiceDesignPublication.message = message
        voiceDesignPublicationRetryStep = retryStep
        voiceDesignSavingSlot = nil
        isRegisteringVoice = false
        voiceDesignErrorMessage = message
    }

    private func isCurrentVoiceDesignPublication(_ generation: UInt64) -> Bool {
        generation == voiceDesignPublicationGeneration && !Task.isCancelled
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
        guard cloneRegistrationContext == nil else {
            try? FileManager.default.removeItem(at: url)
            cloneMessage = "上一次注册结果尚未确认；请先查询或重试原注册，再录制新的音色。"
            return
        }
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
        cloneRegistrationContext = nil
    }

    /// 丢弃这次录音（重录、离开页面、注册完成）。
    @discardableResult
    public func discardCloneRecording() -> Bool {
        guard cloneRegistrationContext == nil else {
            cloneMessage = "上一次注册结果尚未确认。请先恢复原名称和朗读文本，再查询或重试这次注册。"
            return false
        }
        cloneRecordingAudio = nil
        cloneReferenceAnalysis = nil
        cloneEvaluation = nil
        cloneRegistrationID = nil
        cloneIdempotencyKey = nil
        return true
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

        guard let voiceID = cloneRegistrationID,
              let idempotencyKey = cloneIdempotencyKey
        else {
            cloneMessage = "这次注册身份缺失，请重新录制后再试。"
            return nil
        }

        let context: CloneRegistrationContext
        if let existing = cloneRegistrationContext {
            guard existing.referenceText == trimmedReference,
                  existing.name == trimmedName,
                  existing.voiceID == voiceID,
                  existing.idempotencyKey == idempotencyKey
            else {
                cloneMessage = "这次注册结果尚未确认。请恢复原名称和朗读文本，再查询或重试；不要更换注册内容。"
                return nil
            }
            context = existing
        } else {
            context = CloneRegistrationContext(
                audio: audio,
                referenceText: trimmedReference,
                name: trimmedName,
                voiceID: voiceID,
                idempotencyKey: idempotencyKey
            )
            cloneRegistrationContext = context
        }

        isRegisteringCloneVoice = true
        cloneMessage = nil
        defer { isRegisteringCloneVoice = false }

        if context.audio != audio {
            cloneMessage = "注册录音已变化；请保持原录音并查询或重试这次注册。"
            return nil
        }

        // Resolve the stable operation key before each POST. Only new/not-found
        // permits resubmitting the captured payload; pending/unknown never
        // creates another logical registration.
        switch await lookupCloneRegistration(context) {
        case let .completed(voice):
            return await finishCloneRegistration(voice)
        case .pending:
            cloneMessage = "音色注册仍在处理中；请稍后重新检查。"
            return nil
        case .new, .notFound:
            break
        case let .unknown(state):
            cloneMessage = "服务返回了无法识别的注册状态（\(state)）；请稍后重新检查。"
            return nil
        case let .failed(message):
            cloneMessage = message
            return nil
        }

        do {
            let voice = try await submitCloneRegistration(context)
            return await finishCloneRegistration(voice)
        } catch is CancellationError {
            return nil
        } catch {
            if Self.isUncertainCloneRegistrationError(error) {
                switch await lookupCloneRegistration(context) {
                case let .completed(voice):
                    return await finishCloneRegistration(voice)
                case .pending:
                    cloneMessage = "注册请求已送达，服务仍在处理；请稍后重新检查。"
                case .new, .notFound:
                    cloneMessage = "暂时没有查到注册结果。重试会沿用同一注册身份和内容，不会新建第二个音色。"
                case let .unknown(state):
                    cloneMessage = "服务返回了无法识别的注册状态（\(state)）；请稍后重新检查。"
                case let .failed(message):
                    cloneMessage = "注册结果尚未确认：" + message
                }
                return nil
            }
            if let serviceError = error as? ServiceAPIClientError,
               serviceError.statusCode == 409
            {
                cloneMessage = "这次注册与服务端已记录的操作冲突。请保留当前内容和注册身份，再重新检查状态。"
                return nil
            }
            cloneMessage = Self.creatorErrorMessage(for: error)
            return nil
        }
    }

    private func submitCloneRegistration(
        _ context: CloneRegistrationContext
    ) async throws -> CreatorVoice {
        try await creatorClient.registerVoiceClone(
            audio: context.audio,
            referenceText: context.referenceText,
            name: context.name,
            voiceID: context.voiceID,
            idempotencyKey: context.idempotencyKey
        )
    }

    private func lookupCloneRegistration(
        _ context: CloneRegistrationContext
    ) async -> CloneIdempotencyLookup {
        do {
            let status = try await creatorClient.fetchCloneIdempotencyStatus(
                idempotencyKey: context.idempotencyKey
            )
            switch status.state {
            case .new:
                return .new
            case .pending:
                return .pending
            case .completed:
                guard let resultID = status.resultID,
                      resultID == context.voiceID
                else {
                    return .unknown("completed_without_expected_result_id")
                }
                do {
                    return .completed(try await creatorClient.fetchVoice(id: resultID))
                } catch {
                    return .failed("注册已确认，但暂时无法读取该音色。请重新检查音色列表。")
                }
            case let .unknown(value):
                return .unknown(value)
            }
        } catch let error as ServiceAPIClientError
            where error.statusCode == 404 && error.code == "idempotency_not_found"
        {
            return .notFound
        } catch {
            return .failed(Self.creatorErrorMessage(for: error))
        }
    }

    private func finishCloneRegistration(_ voice: CreatorVoice) async -> CreatorVoice {
        lastRegisteredCloneVoice = voice
        cloneRegistrationContext = nil
        // Release the original recording only after the server confirms success.
        cloneRecordingAudio = nil
        let refreshed = await refreshCapabilitySet()
        if !refreshed {
            cloneMessage = "音色已注册，但服务状态尚未刷新；请重新读取后再进行下一次修改。"
        }
        return voice
    }

    private static func isUncertainCloneRegistrationError(_ error: Error) -> Bool {
        guard let error = error as? ServiceAPIClientError else { return true }
        return switch error {
        case .requestFailed, .requestTimedOut:
            true
        case let .http(statusCode, _, _, _, retryable):
            statusCode >= 500 || retryable
        case .invalidURL, .invalidResponse, .notModifiedWithoutCache, .invalidContract:
            false
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
            let refreshed = await refreshCapabilitySet()
            if !refreshed {
                creatorMessage = "音色已删除，但服务状态尚未刷新；请重新读取后再进行下一次修改。"
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

        var expectedRevision = voice.revision?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if expectedRevision?.isEmpty == true {
            expectedRevision = nil
        }
        if expectedRevision == nil {
            _ = await refreshCreatorVoices()
            expectedRevision = creatorVoices.first(where: { $0.id == voice.id })?.revision?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if expectedRevision?.isEmpty == true {
                expectedRevision = nil
            }
        }
        guard let expectedRevision else {
            creatorMessage = "无法确认这条音色的当前版本；请重新读取音色列表后再保存。"
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
                seed: seed,
                expectedRevision: expectedRevision
            )
            let refreshed = await refreshCapabilitySet()
            if !refreshed {
                creatorMessage = "音色已更新，但服务状态尚未刷新；请重新读取后再进行下一次修改。"
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            if let serviceError = error as? ServiceAPIClientError,
               serviceError.statusCode == 409
            {
                _ = await refreshCapabilitySet()
                creatorMessage = "音色状态已变化。你的修改草稿仍保留；请核对最新音色信息后重试。"
                return false
            }
            creatorMessage = Self.creatorErrorMessage(for: error)
            return false
        }
    }

    public func previewVoice(
        _ voice: CreatorVoice,
        text: String? = nil,
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
        // 未显式给文案时按音色语种取默认：英语/日语/韩语音色不该被中文文案硬读。
        let previewText = Self.resolvedPreviewText(forVoiceID: voice.id, text: text)
        guard !previewText.isEmpty else {
            creatorMessage = "试听文案不能为空"
            return
        }
        guard previewText.count <= SpeechRailCreatorLimits.speechTextMaximumLength else {
            creatorMessage = "试听文案不能超过 \(SpeechRailCreatorLimits.speechTextMaximumLength) 个字符"
            return
        }

        stopAudio()
        let previewLanguage = Self.previewLanguage(forVoiceID: voice.id).rawValue
        let cacheKey = "\(voice.id):\(speed):\(previewLanguage):\(previewText)"

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
            let options = try await speechRequestOptions(for: voice.id)
            let data = try await creatorClient.createSpeech(
                text: previewText,
                voiceID: voice.id,
                speed: speed,
                options: options,
                language: previewLanguage
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
        text: String? = nil,
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

    public func playAudio(data: Data) throws {
        voiceDesignPlaybackIdentity = nil
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

    public func playVoiceDesignReferenceAudio() {
        guard voiceDesignPublication.phase == .awaitingReferenceReview,
              let candidateID = voiceDesignPublication.candidateID,
              let revision = voiceDesignPublication.candidateRevision,
              let audio = voiceDesignPublication.referenceAudioData
        else {
            return
        }
        do {
            try playAudio(data: audio)
            voiceDesignPlaybackIdentity = .reference(
                candidateID: candidateID,
                revision: revision
            )
        } catch {
            voiceDesignPublication.message = "候选参考音频无法播放，请重新读取后重试。"
        }
    }

    public func playVoiceDesignValidationAudio() {
        guard voiceDesignPublication.phase == .awaitingValidationReview,
              let candidateID = voiceDesignPublication.candidateID,
              let revision = voiceDesignPublication.candidateRevision,
              let validationID = voiceDesignPublication.validationID,
              let audio = voiceDesignPublication.validationAudioData
        else {
            return
        }
        do {
            try playAudio(data: audio)
            voiceDesignPlaybackIdentity = .validation(
                candidateID: candidateID,
                revision: revision,
                validationID: validationID
            )
        } catch {
            voiceDesignPublication.message = "复验音频无法播放，请重新读取后重试。"
        }
    }

    public func audioDuration(for data: Data) -> TimeInterval? {
        audioPlaybackController.duration(for: data)
    }

    public func stopAudio() {
        voiceDesignPlaybackIdentity = nil
        audioPlaybackController.stop()
        clearPlaybackState()
    }

    func noteVoiceDesignAudioPlaybackFinished(successfully: Bool) {
        guard let identity = voiceDesignPlaybackIdentity else { return }
        voiceDesignPlaybackIdentity = nil
        guard successfully else { return }
        switch identity {
        case let .reference(candidateID, revision):
            guard voiceDesignPublication.phase == .awaitingReferenceReview,
                  voiceDesignPublication.candidateID == candidateID,
                  voiceDesignPublication.candidateRevision == revision
            else {
                return
            }
            markVoiceDesignReferenceAudioPlaybackFinished(successfully: true)
        case let .validation(candidateID, revision, validationID):
            guard voiceDesignPublication.phase == .awaitingValidationReview,
                  voiceDesignPublication.candidateID == candidateID,
                  voiceDesignPublication.candidateRevision == revision,
                  voiceDesignPublication.validationID == validationID
            else {
                return
            }
            markVoiceDesignValidationAudioPlaybackFinished(successfully: true)
        }
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
        creatorVoiceRefreshGeneration &+= 1
        let refreshGeneration = creatorVoiceRefreshGeneration
        // A directory refresh is the authoritative list snapshot. Invalidate
        // any in-flight single-voice read before starting it, otherwise a late
        // detail response can overwrite the newer list and leave the inspector
        // stuck in a loading state.
        creatorVoiceDetailGeneration &+= 1
        isRefreshingCreatorVoiceDetail = false
        creatorVoiceDetailMessage = nil
        isRefreshingCreatorVoices = true
        creatorVoicesLoadState = .loading
        defer {
            if refreshGeneration == creatorVoiceRefreshGeneration {
                isRefreshingCreatorVoices = false
            }
        }
        do {
            let voices = try await creatorClient.fetchVoices()
                .sorted { lhs, rhs in
                    if lhs.isSystem != rhs.isSystem { return lhs.isSystem }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            guard refreshGeneration == creatorVoiceRefreshGeneration else { return false }
            creatorVoices = voices
            creatorVoicesLoadState = .loaded
            creatorMessage = nil
            return true
        } catch is CancellationError {
            guard refreshGeneration == creatorVoiceRefreshGeneration else { return false }
            creatorVoicesLoadState = .unknown
            return false
        } catch {
            guard refreshGeneration == creatorVoiceRefreshGeneration else { return false }
            creatorVoices = []
            creatorVoicesLoadState = .failed
            creatorMessage = Self.creatorErrorMessage(for: error)
            return false
        }
    }

    /// Refresh rich voices and effective capability projections after a voice
    /// mutation. These requests are independent; one retry repairs a safe-list
    /// and effective-snapshot identity mismatch without inventing a remote
    /// transaction.
    @discardableResult
    public func refreshCapabilitySet() async -> Bool {
        async let richVoicesLoaded = refreshCreatorVoices()
        async let discoveryRefresh: Void = refreshDiscovery()

        let richLoaded = await richVoicesLoaded
        await discoveryRefresh
        guard richLoaded else { return false }

        if safeVoiceCatalog?.snapshotID != effectiveCapabilities?.snapshotID {
            await refreshDiscovery()
        }

        return creatorVoicesLoadState == .loaded
            && discoveryState == .loaded
            && safeVoiceCatalog?.snapshotID == effectiveCapabilities?.snapshotID
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

    /// 音色试听语种：服务端 system voice 无 language 字段，按音色 ID 映射。
    /// 与服务端 `_LANGUAGE_ALIASES` 对齐；未知/自定义音色默认中文。
    public enum VoicePreviewLanguage: String, Sendable {
        case chinese = "chinese"
        case english = "english"
        case japanese = "japanese"
        case korean = "korean"
    }

    public static func previewLanguage(forVoiceID voiceID: String) -> VoicePreviewLanguage {
        switch voiceID {
        case "ryan", "aiden":
            return .english
        case "ono_anna":
            return .japanese
        case "sohee":
            return .korean
        default:
            return .chinese
        }
    }

    /// 解析一次试听实际使用的文案：未显式给出时按音色语种取默认。
    /// 助手等没有试听文案输入的入口依赖这里，不能退回硬编码中文。
    public static func resolvedPreviewText(forVoiceID voiceID: String, text: String?) -> String {
        let candidate = text ?? defaultPreviewText(forVoiceID: voiceID)
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func defaultPreviewText(forVoiceID voiceID: String) -> String {
        switch previewLanguage(forVoiceID: voiceID) {
        case .english:
            return "This is a SpeechRail voice preview. Clear, natural voice, every word just right."
        case .japanese:
            return "こちらはSpeechRailの音声プレビューです。クリアで自然な声をお届けします。"
        case .korean:
            return "SpeechRail 음성 미리듣기입니다. 맑고 자연스러운 목소리를 들어보세요."
        case .chinese:
            return "这是 SpeechRail 的音色试听。清晰、自然的声音，让每一句表达都恰到好处。"
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
        pendingDubbing = nil
        workPlaybackMessage = nil
        synthesisTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.synthesizeAndSave(text: text, voice: voice, speed: speed)
            self.synthesisTask = nil
        }
    }

    public func cancelSynthesis() {
        synthesisTask?.cancel()
        pendingDubbing = nil
    }

    /// 把已生成的待保存配音写入作品库。返回 nil 表示没有待保存内容或保存失败。
    @discardableResult
    public func savePendingDubbing() -> CreativeWork? {
        guard let pending = pendingDubbing else { return nil }
        let workID = "work_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let work = CreativeWork(
            id: workID,
            title: pending.generatedTitle,
            scriptText: pending.scriptText,
            voiceID: pending.voiceID,
            voiceName: pending.voiceName,
            voiceRevision: pending.voiceRevision,
            planID: pending.planID,
            renderRevision: (try? workStore.nextRenderRevision(
                scriptText: pending.scriptText,
                voiceID: pending.voiceID
            )) ?? 1,
            durationSeconds: pending.durationSeconds,
            audioFileName: "\(workID).wav"
        )
        do {
            try workStore.save(work, audioData: pending.audioData)
        } catch {
            creatorMessage = "作品保存失败，请检查磁盘权限和可用空间后重试"
            return nil
        }
        do {
            works = try workStore.list()
            worksMessage = nil
        } catch {
            worksMessage = "作品已保存，但作品列表暂时无法刷新"
        }
        pendingDubbing = nil
        lastCreatedWork = work
        return work
    }

    /// 未保存的配音试听音频：从内存播放，不经过作品库。
    public func playPendingDubbing() {
        guard let pending = pendingDubbing else { return }
        do {
            try audioPlaybackController.play(data: pending.audioData)
            isAudioPlaying = audioPlaybackController.isPlaying
            playingWorkID = nil
            playingVoiceID = nil
            workPlaybackMessage = nil
        } catch {
            clearPlaybackState()
            workPlaybackMessage = "试听音频无法播放，请重新生成。"
        }
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
            let options = try await speechRequestOptions(for: voice.id)
            let render = try await creatorClient.createSpeechRender(
                text: scriptText,
                voiceID: voice.id,
                speed: speed,
                options: options
            )
            let data = render.audioData
            try Task.checkCancellation()
            // 生成结果只放内存：用户显式保存后才进入作品库。
            let pending = PendingDubbingRender(
                scriptText: scriptText,
                voiceID: voice.id,
                voiceName: voice.name,
                voiceRevision: render.voiceRevision,
                planID: render.planID,
                speed: speed,
                durationSeconds: audioPlaybackController.duration(for: data),
                audioData: data
            )
            pendingDubbing = pending
            workPlaybackMessage = nil
            do {
                try audioPlaybackController.play(data: data)
                isAudioPlaying = audioPlaybackController.isPlaying
                playingWorkID = nil
                playingVoiceID = nil
            } catch {
                clearPlaybackState()
                workPlaybackMessage = "音频已生成，但本次无法播放；可以重新生成后试听。"
            }
            return nil
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
        controlPlaneMessage = nil
        profiles = []
        profile = nil
        // 能力结论只读 effective snapshot；失败时保留健康快照，但不准入需要能力的动作。
        await refreshDiscovery()
        do {
            let list = try await transport.send(ControlRequest(command: .profileList))
            guard refreshGeneration == healthRefreshGeneration else { return }
            profiles = list.profiles ?? []
            let status = try await transport.send(ControlRequest(command: .profileStatus))
            guard refreshGeneration == healthRefreshGeneration else { return }
            profile = status.profile
            setMessage(nil, generation: messageGeneration)
        } catch is CancellationError {
            return
        } catch {
            guard refreshGeneration == healthRefreshGeneration else { return }
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
        if let error = error as? SpeechBindingUnavailableError {
            return error.errorDescription ?? "无法确认所选音色的当前版本，请刷新音色和服务信息后重试。"
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
            case "voice_design_unsupported":
                return "当前档位未提供音色创作能力，请到模型页核对当前档位"
            case "voice_design_unavailable":
                return "音色创作服务尚未就绪，请检查服务状态后重试"
            case "voice_design_validation_required", "voice_design_machine_validation_required":
                return "这次音色还没有完成复验，请重新保存并完成两项试听确认"
            case "voice_design_state_conflict", "voice_design_revision_conflict", "voice_design_publish_conflict":
                return "音色状态已经变化，请重新生成候选后再保存"
            case "voice_design_validation_not_found", "voice_design_candidate_not_found":
                return "候选音色已经过期，请重新生成候选"
            case "voice_design_target_in_use", "voice_already_exists":
                return "音色标识已存在，请换一个名称"
            default:
                return "创作服务暂时不可用"
            }
        }
    }

    private static func voiceDesignValidationMessage(_ validation: VoiceDesignValidation) -> String {
        if validation.failureCodes.contains("transcript_mismatch") {
            return "服务端复验发现读出的内容和参考文案不一致，请调整描述或参考文案后重新生成。"
        }
        if validation.failureCodes.contains("output_invalid") {
            return "生成的声音没有通过质量检查，请调整描述后重新生成。"
        }
        if validation.failureCodes.contains("transcription_unavailable")
            || validation.failureCodes.contains("model_runtime_identity_unknown")
        {
            return "服务端复验没有完成，请确认当前档位所需能力可用后重试。"
        }
        return "这次音色没有通过服务端复验，请调整描述或参考文案后重新生成。"
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
