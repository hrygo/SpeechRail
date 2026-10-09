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

/// 配音台结果位现在该显示什么。
///
/// 这里**故意没有失败分支**：失败提示与结果是并排的两件事，不是互斥的三选一。
/// 上一次成功留下的 `lastCreatedWork` 会一直存在到那件作品被删除，若把失败塞进
/// 同一条互斥链，它会被旧成品遮住——用户按下生成、按钮恢复原样，页面既没有
/// 新成品也没有任何提示。失败请读 `creatorMessage`，与本投影并排渲染。
public enum DubbingDeskSlot: Equatable, Sendable {
    /// 什么都没有：还没生成过，或失败后还没重试。
    case none
    /// 已生成但用户还没决定保存还是放弃。
    case unsaved
    /// 上一次生成并保存成功的结果。
    case savedWork(CreativeWork)
}

/// 配音台音色选择器面对的情况。
///
/// 视图不再自己算 `creatorVoices.isEmpty`：空列表同时是「还没读到」「读取失败」
/// 和「确实没有音色」三种状态，而这三种给用户的动作完全相反——前两种该**重新
/// 加载**，只有第三种才该去**音色创作**。`refreshCreatorVoices()` 的 catch 分支
/// 会把 `creatorVoices` 清空并置为 `.failed`，所以这不是理论情形。
public enum CreatorVoicePickerState: Equatable, Sendable {
    case reading
    case unreadable
    case noneAvailable
    case available

    /// 胶囊上的标题。选中音色时视图用音色名，不用这里的。
    public var title: String {
        switch self {
        case .reading: return "正在读取音色…"
        case .unreadable: return "没能读到音色"
        case .noneAvailable: return "没有可用音色"
        case .available: return "选择音色"
        }
    }

    /// 空态里那句话。`.available` 不会出现空态。
    public var emptyDescription: String {
        switch self {
        case .reading: return "正在从服务读取音色列表。"
        case .unreadable: return "没能从服务读到音色列表。你可能本来就有音色，先重新加载一次。"
        case .noneAvailable: return "服务当前没有返回可用于配音的音色。"
        case .available: return ""
        }
    }

    /// 空态该不该把用户送去音色创作。只有「确实没有」才该去。
    public var suggestsCreatingVoice: Bool { self == .noneAvailable }

    /// 空态该给的恢复动作。只有「没读到」才该重新加载。
    public var offersReload: Bool { self == .unreadable }

    /// 由加载状态与列表内容决定。抽成静态函数是为了能逐个取值直接测，
    /// 而不必把 App 真的停在"正在读取"这种瞬时状态上。
    ///
    /// `loadState` 的四个取值全部列举，没有 `default`——漏掉一个会被安静地
    /// 当成"确实没有音色"，也就是 #183 本身。
    public static func resolve(
        loadState: CreatorVoicesLoadState,
        voices: [CreatorVoice]
    ) -> CreatorVoicePickerState {
        switch loadState {
        case .unknown, .loading:
            return .reading
        case .failed:
            return .unreadable
        case .loaded:
            return voices.contains(where: \.available) ? .available : .noneAvailable
        }
    }
}

/// 段落返修弹层副标题里关于音色的那半句。
///
/// 四种状态必须分开说。把「不知道」说成「原音色」是一句我们**没有依据**的断言
/// （#184）；尤其在「音色不在列表里」时，副标题会先承诺一个音色，紧接着第一次
/// 返修就被 `startDubbingSegmentRedo` 拒绝——用户看到的是自相矛盾。
public enum DubbingProjectVoice: Equatable, Sendable {
    /// 查到了音色名。
    case named(String)
    /// 配方里没有记录音色。
    case notRecorded
    /// 音色列表没读到（还没读、正在读或读失败）。
    case listUnread
    /// 列表读到了，这件作品用的音色不在其中。
    case notInLibrary

    /// 直接接在副标题逗号后的那半句。
    public var text: String {
        switch self {
        case .named(let name): return "音色为「\(name)」"
        case .notRecorded: return "这件作品没有记录使用的音色"
        case .listUnread: return "音色待确认（还没读到音色列表）"
        case .notInLibrary: return "音色不在当前的音色列表里"
        }
    }

    /// `loadState` 的四个取值全部列举，没有 `default`。
    public static func resolve(
        voiceID: String?,
        voicesLoadState: CreatorVoicesLoadState,
        voices: [CreatorVoice]
    ) -> DubbingProjectVoice {
        guard let voiceID else { return .notRecorded }
        switch voicesLoadState {
        case .unknown, .loading, .failed:
            return .listUnread
        case .loaded:
            guard let voice = voices.first(where: { $0.id == voiceID }) else {
                return .notInLibrary
            }
            return .named(voice.name)
        }
    }
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

    /// Whether this binding covers a full speech round trip (ASR + spoken reply).
    ///
    /// `voiceRevision` is deliberately **not** part of this: OpenAPI declares
    /// `voice_revision` nullable ("legacy voices remain null"), and the HTTP
    /// synthesis path already treats it as optional
    /// (`SpeechRailCapabilityRevisionSelector.creatorRequestOptions`). A missing
    /// revision only means the pin is omitted, not that the voice is unusable.
    public var includesSpeech: Bool {
        canonicalVoiceID != nil
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
              // 服务端按 voice mode 选 TTS 制品（system→tts，clone→tts_clone，
              // 见 artifact_for_voice_mode）：pin 必须取同一份制品的号，
              // 取 voice 自带的 model 号在 clone 音色上永不对等，直接 409。
              let ttsModelRevision = Self.ttsModelRevision(for: voice, in: snapshot)
        else {
            return nil
        }
        return RealtimeCapabilityBinding(
            asrModelRevision: asrRevision,
            canonicalVoiceID: voice.id,
            // Legacy system voices legitimately publish no acoustic revision;
            // the pin is then omitted rather than blocking admission.
            voiceRevision: Self.nonEmpty(voice.voiceRevision),
            ttsModelRevision: ttsModelRevision
        )
    }

    /// 按 voice mode 取服务端比对用的那份 TTS 制品 revision。
    ///
    /// canonical 映射见 `SpeechRailCapabilityRevisionSelector.ttsArtifactSlot`：
    /// Realtime 握手按同一 mode 比对（见 `artifact_for_voice_mode`），这里按
    /// mode 取顶层槽位，保证 pin 与服务端比对的是同一份制品。
    /// instruction 音色没有 runtime 合成角色，返回 nil 调用方 fail-closed。
    private static func ttsModelRevision(
        for voice: SafeVoiceEntry,
        in snapshot: EffectiveCapabilitySnapshot
    ) -> String? {
        guard let slot = SpeechRailCapabilityRevisionSelector.ttsArtifactSlot(forVoiceMode: voice.mode) else {
            return nil
        }
        return Self.nonEmpty(snapshot.models[slot]?.catalogRevision)
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
        // 音色级 operation 在契约里**没有** `status` 字段：服务把某个 operation 列进
        // `voices[].operations` 本身就是「这个音色支持它」的声明，`parameters` 是可选的
        // 参数说明。HTTP 合成路径读的一直是这个键（`creatorRequestOptions` 的
        // `voice.operations["http_speech"] != nil`）；这里曾额外要求 `parameters`
        // 子对象，于是服务少列一项参数就把整个音色判成「无法确认」。
        guard case .object = value.storage else {
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
    /// 候选已进入 `failed` 终态：复验不再受理，只能重新生成候选。
    case regenerateCandidate
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
    case regenerateCandidate
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

/// 「检查配音效果」的状态机。
///
/// 关键区分：机器报告通过 ≠ 已保存。`validation_persisted == false` 的运行
/// 是一次真实观测，但不能提升为「已验收」——证据没落盘，下次严格合成仍然拒绝。
public enum VoiceOutputCheckState: Equatable, Sendable {
    case idle
    case running(voiceID: String)
    /// 机器报告 pass 且证据已保存。
    case passed(voiceID: String, voiceRevision: String?, runID: String?)
    /// 机器报告通过，但结果未保存：显示「检查已完成，但结果未保存，请重试」。
    case passedNotPersisted(voiceID: String, voiceRevision: String?)
    /// 机器报告未通过（warn/reject）。
    case failed(voiceID: String, voiceRevision: String?, message: String)
    /// 请求本身失败（网络、契约、取消之外的错误）。
    case error(voiceID: String, voiceRevision: String?, message: String)

    public var voiceID: String? {
        switch self {
        case .idle:
            nil
        case let .running(voiceID),
             let .passed(voiceID, _, _),
             let .passedNotPersisted(voiceID, _),
             let .failed(voiceID, _, _),
             let .error(voiceID, _, _):
            voiceID
        }
    }

    public var voiceRevision: String? {
        switch self {
        case .idle, .running:
            nil
        case let .passed(_, voiceRevision, _),
             let .passedNotPersisted(_, voiceRevision),
             let .failed(_, voiceRevision, _),
             let .error(_, voiceRevision, _):
            voiceRevision
        }
    }

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// 面向用户的一句话结果。检查成功只代表这一次运行通过并落盘，
    /// 生成时仍会确认当前声音环境。
    public var resultMessage: String? {
        switch self {
        case .idle, .running:
            nil
        case let .passed(_, _, runID):
            if let runID, !runID.isEmpty {
                "本次检查通过（\(runID)）。生成时仍会确认当前声音环境。"
            } else {
                "本次检查通过。生成时仍会确认当前声音环境。"
            }
        case .passedNotPersisted:
            "检查已完成，但结果未保存，请重试。"
        case let .failed(_, _, message):
            message
        case let .error(_, _, message):
            message
        }
    }
}

@MainActor
@Observable
public final class AppModel {
    /// 一次配音生成的待保存结果：音频只在内存，身份已固定。
    /// 只有用户显式保存后才写入作品库。
    ///
    /// 这里的每一个字段都在**生成结束的那一刻**定下来。保存时不得回头读取 UI
    /// 当前的语速、音色或文稿去重写身份——那样存下来的作品会描述一次根本没发生
    /// 过的生成。
    public struct PendingDubbingRender: Hashable, Sendable {
        /// 本次生成的轻量代号。UI 的比较与动画只看它，不深比较音频字节。
        public let renderID: String
        /// 幂等键：同一次生成无论保存多少次重试，都落到同一个作品 ID。
        public let workID: String
        public let scriptText: String
        public let voiceID: String
        public let voiceName: String
        public let voiceRevision: String?
        public let planID: String?
        public let speed: Double
        public let responseFormat: String
        /// 同文稿同音色的第几次渲染，生成时定下，不在保存时重算。
        public let renderRevision: Int
        public let durationSeconds: Double?
        public let audioData: Data
        /// 生成时就固定的制作配方与追溯状态；保存时原样落盘，不在保存时补算。
        public let provenance: RenderProvenanceSnapshot

        public init(
            renderID: String,
            workID: String,
            scriptText: String,
            voiceID: String,
            voiceName: String,
            voiceRevision: String?,
            planID: String?,
            speed: Double,
            responseFormat: String = "wav",
            renderRevision: Int,
            durationSeconds: Double?,
            audioData: Data,
            provenance: RenderProvenanceSnapshot = .legacyUnknown
        ) {
            self.renderID = renderID
            self.workID = workID
            self.scriptText = scriptText
            self.voiceID = voiceID
            self.voiceName = voiceName
            self.voiceRevision = voiceRevision
            self.planID = planID
            self.speed = speed
            self.responseFormat = responseFormat
            self.renderRevision = renderRevision
            self.durationSeconds = durationSeconds
            self.audioData = audioData
            self.provenance = provenance
        }

        public var generatedTitle: String {
            CreativeWork.generatedTitle(fromScript: scriptText)
        }

        public var durationText: String? {
            guard let durationSeconds else { return nil }
            let totalSeconds = max(0, Int(durationSeconds.rounded()))
            return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
        }

        /// 身份相同即视为同一次生成：比较 `renderID` 而不是整段音频。
        public static func == (lhs: PendingDubbingRender, rhs: PendingDubbingRender) -> Bool {
            lhs.renderID == rhs.renderID
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(renderID)
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
    public private(set) var isAudioPlaying = false
    public var isVoiceDesignAudioPlaying: Bool {
        isAudioPlaying && voiceDesignPlaybackIdentity != nil
    }
    /// 当前音频的**真实**播放进度 0…1（`AVAudioPlayer.currentTime / duration`）。
    /// 详情面板的波形用它表示「播到哪了」（REDESIGN-SPEC §11 第五十七轮）。
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
    /// 用户距离"第一条真实结果"还差什么。
    ///
    /// 只读投影：它读的都是 App 已经知道的事实，不安装、不下载、不改配置。服务
    /// 探针通过不等于这一步满足——真实结果是用户按下生成后听到的音频。
    public var firstResultReadiness: FirstResultReadiness {
        FirstResultReadinessBuilder.evaluate(
            hasHealth: health != nil,
            healthFailure: healthFailure,
            hasProfile: profile != nil,
            modelAvailability: modelAvailability,
            modelStatusMessage: modelStatus?.activeOperation?.message
                ?? operation?.message,
            voices: creatorVoices,
            voicesLoadState: creatorVoicesLoadState,
            discoveryState: discoveryState
        )
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

    /// 配音台结果位。只描述"有没有结果、是哪一种"，不描述失败——见 `DubbingDeskSlot`。
    public var dubbingDeskSlot: DubbingDeskSlot {
        if pendingDubbing != nil { return .unsaved }
        if let work = lastCreatedWork { return .savedWork(work) }
        return .none
    }

    /// 配音台音色选择器的状态。四个取值穷举 `CreatorVoicesLoadState`，
    /// 不留 `default`：漏掉一个取值会被安静地当成"没有音色"。
    public var creatorVoicePickerState: CreatorVoicePickerState {
        CreatorVoicePickerState.resolve(
            loadState: creatorVoicesLoadState,
            voices: creatorVoices
        )
    }

    // MARK: 段落返修（D）

    /// 当前打开的配音项目：把一件已保存作品按段落拆开，逐段重做、试听、采用。
    ///
    /// 项目**不含**原作品音频。它只记录每段当前采用哪个候选，音频一律留在候选里；
    /// 导出的成品由被采用的候选按顺序拼成，正文与音频因此始终一一对应。
    public private(set) var dubbingProject: DubbingProject?
    public private(set) var dubbingProjects: [DubbingProject] = []
    public private(set) var dubbingCandidates: [DubbingCandidate] = []
    /// 正在重做的段落 ID。同一时间只允许一段在飞，避免两次生成互相覆盖状态。
    public private(set) var dubbingBusySegmentID: String?
    public private(set) var dubbingMessage: String?
    public private(set) var playingDubbingCandidateID: String?
    public private(set) var dubbingExportBundle: DubbingExportBundle?
    private var dubbingExportPreparedSelection: [String]?
    private var dubbingExportedSelection: [String]?
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
    /// 「检查配音效果」的结果状态。绑定到 voice ID + revision + 请求代际：
    /// 切换选择、删除或改版后的迟到结果不得污染新选择（issue: 质量检查陈旧响应）。
    public private(set) var voiceOutputCheck: VoiceOutputCheckState = .idle
    /// 正在检查的 voice ID：用于阻止重复提交。
    public private(set) var voiceOutputCheckInFlightVoiceID: String?
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
    private let voiceDirectoryClient: (any SpeechRailVoiceDirectoryClient)?
    private let speechRenderClient: (any SpeechRailSpeechRenderClient)?
    private let voiceDesignClient: (any SpeechRailVoiceDesignClient)?
    private let voiceCloneClient: (any SpeechRailVoiceCloneClient)?
    private let voiceEditingClient: (any SpeechRailVoiceEditingClient)?
    private let voiceQualityClient: (any SpeechRailVoiceQualityClient)?
    private let receiptClient: (any SpeechRailReceiptClient)?
    private let audioPlaybackController: AudioPlaybackController
    private let workStore: CreativeWorkStore
    private let dubbingProjectStore: DubbingProjectStore
    /// 拥有 `dubbingRedoTask` 句柄的那一代任务。取消或重新开始都会推进它，
    /// 使旧任务的收尾无法清空新任务的句柄。
    ///
    /// 这是**纵深防御**，不是当前唯一的那道防线：`startDubbingSegmentRedo` 里的
    /// `guard dubbingBusySegmentID == nil` 已经让两段重做无法并发，
    /// `cancelDubbingSegmentRedo` 也只取消 task、不清在途标记，
    /// 所以从取消到 `defer` 执行之间 busy 仍然占位。在 MainActor 上这些步骤串行，
    /// 代次相等检查因此在当前代码路径上不会被触发。
    ///
    /// 若将来放宽并发（例如允许「取消后立即重做」），这道检查才真正开始起作用，
    /// 且需要配套测试——目前没有测试覆盖它，正是因为触发不了。
    private var dubbingRedoGeneration: UInt64 = 0
    private var dubbingRedoTask: Task<Void, Never>?
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
    /// 质量检查的请求代际：只有最新一次请求可以落地结果。
    private var voiceOutputCheckGeneration: UInt64 = 0
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
    /// 12 / 16 / 18 根三种波形用（REDESIGN-SPEC §11 第五十七轮）。
    private var waveformEnvelopes: [String: [CGFloat]] = [:]
    /// 试听音频内存缓存，同音色试听即点即播，0 延迟。
    ///
    /// 键包含音色与模型的**版本**：只用 `voiceID + speed + text` 时，音色被撤销
    /// 或服务换用另一份模型之后仍会命中并播放旧音频。
    private var previewAudioCache = VoicePreviewAudioCache(
        byteLimit: VoicePreviewCacheLimits.byteLimit
    )
    /// 单调递增的试听请求代号。取消、切换或开始新请求都会推进它，迟到的成功 /
    /// 失败 / defer 因此无法覆盖新请求的状态、播放句柄或缓存。
    private var voicePreviewToken: UInt64 = 0
    /// 拥有 `voicePreviewTask` 句柄的那一代任务。取消或重新开始都会推进它，
    /// 使旧任务的收尾无法清空新任务的句柄。
    private var voicePreviewTaskGeneration: UInt64 = 0
    private var voicePreviewTask: Task<Void, Never>?
    private var voiceDesignGenerationTask: Task<Void, Never>?
    private var voiceDesignSaveTask: Task<Void, Never>?

    /// 推进试听请求代号，使此前所有在途请求的迟到回包失效。
    private func invalidateVoicePreview() {
        voicePreviewToken &+= 1
    }

    /// 构造试听缓存身份。
    ///
    /// 声学音色有 revision 时用它；系统 / legacy 音色没有 revision，改用模型
    /// catalog revision 作为 epoch 隔离，**不制造假 revision**。`planID` 与
    /// receipt 是生成之后才拿到的，只用于结果校验，不参与前置键。
    static func previewCacheKey(
        voice: CreatorVoice,
        options: SpeechRailRequestOptions,
        catalogRevision: String?,
        input: String,
        languageOverride: String?,
        speed: Double
    ) -> VoicePreviewCacheKey {
        VoicePreviewCacheKey(
            canonicalVoiceID: voice.id,
            voiceRevision: options.expectedVoiceRevision ?? voice.revision,
            catalogEpoch: options.expectedModelRevision ?? catalogRevision,
            runtimeEpoch: nil,
            input: input,
            languageOverride: languageOverride,
            speed: speed,
            responseFormat: "wav"
        )
    }

    /// 槽位编号与稿 `Candidate Tile` 一致：候选 1–4 配 seed 101/202/303/404。
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
        voiceDirectoryClient: (any SpeechRailVoiceDirectoryClient)? = nil,
        speechRenderClient: (any SpeechRailSpeechRenderClient)? = nil,
        voiceDesignClient: (any SpeechRailVoiceDesignClient)? = nil,
        voiceCloneClient: (any SpeechRailVoiceCloneClient)? = nil,
        voiceEditingClient: (any SpeechRailVoiceEditingClient)? = nil,
        voiceQualityClient: (any SpeechRailVoiceQualityClient)? = nil,
        receiptClient: (any SpeechRailReceiptClient)? = nil,
        audioPlaybackController: AudioPlaybackController = AudioPlaybackController(),
        workStore: CreativeWorkStore = CreativeWorkStore(),
        dubbingProjectStore: DubbingProjectStore? = nil,
        observabilityLocation: ObservabilityLocation = .default,
        registration: ControlAgentRegistration? = nil
    ) {
        self.transport = transport
        self.apiClient = apiClient
        self.discoveryClient = discoveryClient ?? UnavailableServiceCapabilityDiscoveryClient()
        self.voiceDirectoryClient = voiceDirectoryClient
        self.speechRenderClient = speechRenderClient
        self.voiceDesignClient = voiceDesignClient
        self.voiceCloneClient = voiceCloneClient
        self.voiceEditingClient = voiceEditingClient
        self.voiceQualityClient = voiceQualityClient
        self.receiptClient = receiptClient
        self.audioPlaybackController = audioPlaybackController
        self.workStore = workStore
        self.dubbingProjectStore = dubbingProjectStore ?? DubbingProjectStore(
            directory: FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SpeechRail/DubbingProjects", isDirectory: true)
        )
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
            self.playingDubbingCandidateID = nil
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
        try await requireCreatorCapability(voiceDirectoryClient).fetchVoices()
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
        return try await requireCreatorCapability(speechRenderClient).createSpeech(
            text: text,
            voiceID: voiceID,
            speed: speed,
            options: language.map { options.with(languageOverride: $0) } ?? options
        )
    }

    public func createVoicePreview(
        text: String,
        instruction: String,
        speed: Double,
        seed: Int?
    ) async throws -> Data {
        try await requireCreatorCapability(voiceDesignClient).createVoicePreview(
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
        case .regenerateCandidate:
            step = .regenerateCandidate
        case .cancelCandidate:
            step = .cancelCandidate
            voiceDesignPublication.phase = .cancelling
        }
        scheduleVoiceDesignPublicationTask(
            step,
            generation: voiceDesignPublicationGeneration
        )
    }

    /// `failed` 是候选终态：此时唯一有效的动作是重新生成候选，而不是重复一次
    /// 必然被服务拒绝的复验。UI 据此显示正确按钮，避免展示无效重试。
    public var voiceDesignPublicationRetryActionTitle: String {
        voiceDesignPublicationRetryStep == .regenerateCandidate
            ? "重新生成候选"
            : "重试这一步"
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
                let candidate = try await requireCreatorCapability(voiceDesignClient).createVoiceDesignCandidate(
                    voiceID: context.voiceID,
                    name: context.name,
                    instruction: context.instruction,
                    referenceText: context.referenceText,
                    seed: context.seed,
                    idempotencyKey: context.idempotencyKey
                )
                guard isCurrentVoiceDesignPublication(generation) else {
                    _ = try? await requireCreatorCapability(voiceDesignClient).cancelVoiceDesignCandidate(id: candidate.id)
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
                let confirmed = try await requireCreatorCapability(voiceDesignClient).confirmVoiceDesignCandidate(
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
                let latest = try await requireCreatorCapability(voiceDesignClient).fetchVoiceDesignCandidate(id: candidateID)
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
                        // `failed` is terminal on the service side; anything else
                        // that ended early is still worth one plain retry.
                        retryStep: state == .failed ? .regenerateCandidate : .validate,
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

        case .regenerateCandidate:
            regenerateFailedVoiceDesignCandidate(context)

        case .cancelCandidate:
            await cancelVoiceDesignCandidate(context, generation: generation)
        }
    }

    /// `failed` 是候选的终态：服务不再受理对该候选的复验或发布，所以重试必须
    /// 换一个新候选，而不是重复一次必然被拒的调用。这里结束当前 publication
    /// context（不复用 failed 的 candidate ID / target voice ID / idempotency key），
    /// 保留服务端失败候选与证据供排查，再复用现有候选 slot 的生成方法。
    private func regenerateFailedVoiceDesignCandidate(
        _ context: VoiceDesignPublicationContext
    ) {
        let slot = voiceDesignSavingSlot ?? context.slot
        // `retryVoiceDesignCandidate` silently no-ops while another generation is
        // running. Check first so the button never clears the failure state and
        // then does nothing: if we cannot start, the terminal action stays
        // visible and retryable.
        guard voiceDesignGenerationTask == nil, !isGeneratingVoiceDesign else {
            voiceDesignPublication.message =
                "正在生成其他候选，请等它结束后再重新生成这一个。"
            return
        }
        guard let candidate = voiceDesignCandidates.first(where: { $0.slot == slot }),
              !candidate.instructionSnapshot.isEmpty
        else {
            voiceDesignPublication.message =
                "候选信息已变化，无法就地重新生成；请重新填写描述后生成新候选。"
            return
        }
        voiceDesignPublicationContext = nil
        voiceDesignPublicationRetryStep = nil
        voiceDesignSavingSlot = nil
        voiceDesignPublication = VoiceDesignPublicationSnapshot(phase: .idle)
        voiceDesignErrorMessage = nil
        retryVoiceDesignCandidate(slot: slot)
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
                let recovered = try await requireCreatorCapability(voiceDesignClient).createVoiceDesignCandidate(
                    voiceID: context.voiceID,
                    name: context.name,
                    instruction: context.instruction,
                    referenceText: context.referenceText,
                    seed: context.seed,
                    idempotencyKey: context.idempotencyKey
                )
                guard isCurrentVoiceDesignPublication(generation) else {
                    _ = try? await requireCreatorCapability(voiceDesignClient).cancelVoiceDesignCandidate(id: recovered.id)
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

            let current = try await requireCreatorCapability(voiceDesignClient).fetchVoiceDesignCandidate(id: candidateID)
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

            let cancelled = try await requireCreatorCapability(voiceDesignClient).cancelVoiceDesignCandidate(id: candidateID)
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
              let current = try? await requireCreatorCapability(voiceDesignClient).fetchVoiceDesignCandidate(id: candidateID)
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
              let voice = try? await requireCreatorCapability(voiceDirectoryClient).fetchVoice(id: context.voiceID)
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
            let candidate = try await requireCreatorCapability(voiceDesignClient).fetchVoiceDesignCandidate(id: candidateID)
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
            let audio = try await requireCreatorCapability(voiceDesignClient).fetchVoiceDesignReferenceAudio(
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
            let current = try await requireCreatorCapability(voiceDesignClient).fetchVoiceDesignCandidate(id: candidateID)
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
            // The service commits `validating` *before* it synthesizes, so a run
            // that dies mid-flight (transport error, 502) leaves the candidate
            // parked there. Re-issuing validation is the documented recovery and
            // `resumeValidation` already accepts this state, so this gate has to
            // agree with it — otherwise "重试这一步" is a dead end.
            guard current.knownState == .confirmed || current.knownState == .validating
            else {
                failVoiceDesignPublication(
                    current.knownState == .failed
                        ? "这个候选没有通过机器验收，不能继续复验；请重新生成候选。"
                        : current.knownState == nil
                        ? "服务返回了未知候选状态；保留候选信息，不能继续复验。"
                        : "候选状态已变化，请重新读取后再复验。",
                    retryStep: current.knownState == .failed
                        ? .regenerateCandidate
                        : .validate,
                    generation: generation
                )
                return
            }
            let validated = try await requireCreatorCapability(voiceDesignClient).validateVoiceDesignCandidate(
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
                    // The service moves a machine-rejected candidate to `failed`,
                    // which is terminal: re-validating it is rejected every time.
                    // Offer a new candidate instead of a dead retry.
                    retryStep: validated.knownState == .failed
                        ? .regenerateCandidate
                        : .validate,
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
            let candidate = try await requireCreatorCapability(voiceDesignClient).fetchVoiceDesignCandidate(id: candidateID)
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
            let audio = try await requireCreatorCapability(voiceDesignClient).fetchVoiceDesignValidationAudio(
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
            let candidate = try await requireCreatorCapability(voiceDesignClient).fetchVoiceDesignCandidate(id: candidateID)
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
            let reviewed = try await requireCreatorCapability(voiceDesignClient).validateVoiceDesignCandidate(
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
            let current = try await requireCreatorCapability(voiceDesignClient).fetchVoiceDesignCandidate(id: candidateID)
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
            let result = try await requireCreatorCapability(voiceDesignClient).publishVoiceDesignCandidate(
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
            if let current = try? await requireCreatorCapability(voiceDesignClient).fetchVoiceDesignCandidate(id: candidateID),
               current.state == "published",
               current.publishedVoiceRevision == expectedRevision,
               let voice = try? await requireCreatorCapability(voiceDirectoryClient).fetchVoice(id: context.voiceID)
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
            let data = try await requireCreatorCapability(voiceDesignClient).createVoicePreview(
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
            let prompts = try await requireCreatorCapability(voiceCloneClient).fetchClonePrompts()
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
            let report = try await requireCreatorCapability(voiceCloneClient).validateVoiceClone(
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
            // A durable pending record is recoverable by replaying the exact
            // same POST. The service keeps create-only + fingerprint checks, so
            // this cannot create a second logical voice.
            break
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
            if Self.isDefinitiveCloneRejection(error) {
                releaseRejectedCloneRegistrationForRetry()
            }
            cloneMessage = Self.creatorErrorMessage(for: error)
            return nil
        }
    }

    private func submitCloneRegistration(
        _ context: CloneRegistrationContext
    ) async throws -> CreatorVoice {
        try await requireCreatorCapability(voiceCloneClient).registerVoiceClone(
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
            let status = try await requireCreatorCapability(voiceCloneClient).fetchCloneIdempotencyStatus(
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
                    return .completed(try await requireCreatorCapability(voiceDirectoryClient).fetchVoice(id: resultID))
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

    private static let definitiveCloneRejectionCodes: Set<String> = [
        "invalid_name",
        "invalid_ref_text",
        "invalid_voice_id",
        "invalid_audio",
        "audio_too_short",
        "audio_too_long",
        "voice_quality_reject",
    ]

    private static func isDefinitiveCloneRejection(_ error: Error) -> Bool {
        guard let error = error as? ServiceAPIClientError else { return false }
        guard case let .http(_, code, _, _, _) = error else { return false }
        return definitiveCloneRejectionCodes.contains(code)
    }

    /// Release only the operation identity. The captured recording stays audible
    /// so a definite pre-commit rejection can be corrected without discarding the
    /// user's take; the next submission receives a new logical operation key.
    private func releaseRejectedCloneRegistrationForRetry() {
        cloneRegistrationContext = nil
        cloneRegistrationID = Self.makeCloneRegistrationID()
        cloneIdempotencyKey = UUID().uuidString.lowercased()
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
            try await requireCreatorCapability(voiceEditingClient).deleteVoice(id: voice.id)
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
            _ = try await requireCreatorCapability(voiceEditingClient).updateVoice(
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
            invalidateVoicePreview()
            stopAudio()
            return
        }
        guard !isCreatingSpeech else {
            // 如果正在生成该音色，再次点击取消
            if previewingVoiceID == voice.id {
                invalidateVoicePreview()
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
        // 未显式给文案时用服务端声明的默认示例：英语/日语/韩语音色不该被中文文案硬读。
        let previewText = Self.resolvedPreviewText(for: voice, text: text)
        guard !previewText.isEmpty else {
            creatorMessage = "试听文案不能为空"
            return
        }
        guard previewText.count <= SpeechRailCreatorLimits.speechTextMaximumLength else {
            creatorMessage = "试听文案不能超过 \(SpeechRailCreatorLimits.speechTextMaximumLength) 个字符"
            return
        }

        stopAudio()
        let previewLanguage = Self.previewLanguage(for: voice)

        // 先解析当前有效版本，再谈缓存：音色被撤销或服务换用另一份模型之后，
        // 不应该复用旧音频。
        let options: SpeechRailRequestOptions
        do {
            options = try await speechRequestOptions(for: voice.id)
        } catch {
            creatorMessage = Self.creatorErrorMessage(for: error)
            return
        }
        guard !Task.isCancelled else { return }

        let cacheKey = Self.previewCacheKey(
            voice: voice,
            options: options,
            catalogRevision: capabilityFacade.snapshot?.catalogRevision,
            input: previewText,
            languageOverride: previewLanguage,
            speed: speed
        )

        // 本次请求的代号。此后任何状态写入都必须先确认自己仍是最新请求，
        // 否则迟到的成功 / 失败 / defer 会覆盖新请求的进度与播放句柄。
        invalidateVoicePreview()
        let token = voicePreviewToken

        // 优先命中本地内存缓存：0 毫秒即点即播，彻底免除反复生成延迟
        if let cachedData = previewAudioCache.data(for: cacheKey) {
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
            // 只有仍是最新请求时才允许清理共享状态。
            if token == voicePreviewToken {
                isCreatingSpeech = false
                previewingVoiceID = nil
            }
        }
        do {
            let data = try await requireCreatorCapability(speechRenderClient).createSpeech(
                text: previewText,
                voiceID: voice.id,
                speed: speed,
                options: options.with(languageOverride: previewLanguage)
            )
            try Task.checkCancellation()
            guard token == voicePreviewToken else { return }
            // 只缓存解码通过、非空的完整结果；空音频不入缓存。
            previewAudioCache.insert(data, for: cacheKey)
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
            // 迟到的失败同样不能覆盖新请求的提示。
            guard token == voicePreviewToken else { return }
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
            invalidateVoicePreview()
            stopAudio()
            return
        }
        guard voicePreviewTask == nil, !isCreatingSpeech else { return }
        voicePreviewTaskGeneration &+= 1
        let generation = voicePreviewTaskGeneration
        voicePreviewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.previewVoice(voice, text: text, speed: speed)
            // 期间若已取消并开启新任务，旧任务的收尾无权清空新句柄。
            if self.voicePreviewTaskGeneration == generation {
                self.voicePreviewTask = nil
            }
        }
    }

    public func cancelVoicePreview() {
        // `isCreatingSpeech` 也要纳入判断：助手等入口直接 `await previewVoice`，
        // 不经过 `startVoicePreview`，此时没有 task 句柄，但请求确实在途。
        guard voicePreviewTask != nil || isCreatingSpeech || isAudioPlaying else { return }
        invalidateVoicePreview()
        voicePreviewTaskGeneration &+= 1
        voicePreviewTask?.cancel()
        voicePreviewTask = nil
        // 被取消的请求其 defer 已因代号失效而不再清理，这里由取消方负责收尾；
        // 只在确实是试听在途时清，避免踩到并行的正式合成。
        if previewingVoiceID != nil {
            previewingVoiceID = nil
            isCreatingSpeech = false
        }
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
            let voices = try await requireCreatorCapability(voiceDirectoryClient).fetchVoices()
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
            let voice = try await requireCreatorCapability(voiceDirectoryClient).fetchVoice(id: id)
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

    public func lookupWorkReceipt(_ work: CreativeWork) async throws -> RenderReceipt {
        guard let receiptClient else { throw SavedRenderReceiptError.clientUnavailable }
        return try await SavedRenderReceiptLookup.fetch(snapshot: work.provenance, client: receiptClient)
    }

    public func refreshWorks() {
        do {
            works = try workStore.list()
            worksMessage = nil
        } catch {
            works = []
            worksMessage = "作品历史暂时不可用"
        }
        refreshDeletedWorks()
    }

    public private(set) var deletedWorksSummary: CreativeWorkRecoverySummary?
    public private(set) var deletedWorksMessage: String?

    public func refreshDeletedWorks() {
        do {
            deletedWorksSummary = try workStore.deletedWorksSummary()
            deletedWorksMessage = nil
        } catch {
            deletedWorksSummary = nil
            deletedWorksMessage = "已删除作品暂时无法读取，请保留恢复区并打开诊断。"
        }
    }

    @discardableResult
    public func trashDeletedWorks() -> Bool {
        do {
            let count = try workStore.trashDeletedWorks()
            refreshDeletedWorks()
            workActionMessage = "已将 \(count) 件已删除作品移入系统废纸篓；清空废纸篓后才会永久移除。"
            return true
        } catch {
            refreshDeletedWorks()
            workActionMessage = "音频转移尚未完成；剩余内容仍在本机恢复区，请重新读取后重试。"
            return false
        }
    }

    public func loadWorkAudio(_ work: CreativeWork) throws -> Data {
        try workStore.loadAudio(for: work)
    }

    /// Where a saved work's audio lives, for reveal-in-Finder and export.
    public func workAudioURL(_ work: CreativeWork) -> URL? {
        try? workStore.audioURL(for: work)
    }

    /// Deletes a saved work, then transfers its recoverable transaction to Trash.
    /// The caller must still confirm because the work disappears from the list.
    @discardableResult
    public func deleteWork(_ work: CreativeWork) -> Bool {
        if playingWorkID == work.id {
            stopAudio()
        }
        do {
            let transactionID = try workStore.delete(work)
            works.removeAll { $0.id == work.id }
            if let refreshed = try? workStore.list() { works = refreshed }
            worksMessage = nil
            workPlaybackMessage = nil
            do {
                if let transactionID {
                    try workStore.trashDeletedWorks(transactionIDs: [transactionID])
                }
                workActionMessage = transactionID == nil
                    ? "作品已不在列表中；仍待转移的音频可在「已删除作品」中重试。"
                    : "“\(work.displayTitle)”已从作品列表删除；音频已移入系统废纸篓。"
            } catch {
                workActionMessage = "作品已从列表删除，音频转移尚未完成；请在「已删除作品」中重试。"
            }
            refreshDeletedWorks()
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

    /// 服务端下发的试听文案是唯一事实源；只有它缺失时才退回本地兜底。
    ///
    /// 兜底文案只用于填充界面，不写回元数据，也不因为它存在就断言音色只能
    /// 读这一种语言。
    public static func resolvedPreviewText(for voice: CreatorVoice, text: String?) -> String {
        let candidate =
            text ?? voice.preview?.text ?? defaultPreviewText(forVoiceID: voice.id)
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 这次试听要发送的目标语言。
    ///
    /// 服务端已声明 `preview.locale` 时直接用它，缺失时退回本地映射。注意这里
    /// 选的是**本次生成的目标语言**，不是音色的母语，也不会翻译用户文案。
    public static func previewLanguage(for voice: CreatorVoice) -> String {
        if let locale = voice.preview?.locale, !locale.isEmpty {
            return locale
        }
        return previewLanguage(forVoiceID: voice.id).rawValue
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
        // 已完成但未保存的结果不能被新一次生成静默顶掉：用户要先保存或明确放弃。
        guard pendingDubbing == nil else {
            creatorMessage = "当前还有一段未保存的配音，请先保存或放弃后再重新生成。"
            return
        }
        workPlaybackMessage = nil
        synthesisTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.synthesizeAndSave(text: text, voice: voice, speed: speed)
            self.synthesisTask = nil
        }
    }

    /// 取消进行中的生成。已经生成完成、只是还没保存的结果不受影响——那是用户
    /// 的数据，不该因为取消另一次生成而被顺带丢掉。
    public func cancelSynthesis() {
        synthesisTask?.cancel()
    }

    /// 显式放弃未保存的配音。只有用户点了"放弃"才会走到这里。
    public func discardPendingDubbing() {
        pendingDubbing = nil
        workPlaybackMessage = nil
    }

    /// 把已生成的待保存配音写入作品库。返回 nil 表示没有待保存内容或保存失败。
    ///
    /// 幂等：`workID` 在生成时就冻结了，所以双击、重试、以及"写入成功但列表刷新
    /// 失败后再点一次"都只会得到同一条作品，而不是每次多一条。
    @discardableResult
    public func savePendingDubbing() -> CreativeWork? {
        guard let pending = pendingDubbing else { return nil }
        let work = CreativeWork(
            id: pending.workID,
            title: pending.generatedTitle,
            scriptText: pending.scriptText,
            voiceID: pending.voiceID,
            voiceName: pending.voiceName,
            voiceRevision: pending.voiceRevision,
            planID: pending.planID,
            renderRevision: pending.renderRevision,
            durationSeconds: pending.durationSeconds,
            audioFileName: "\(pending.workID).wav",
            provenance: pending.provenance
        )
        let committed: CreativeWork
        do {
            committed = try workStore.save(work, audioData: pending.audioData)
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
        lastCreatedWork = committed
        return committed
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

    // MARK: - 段落返修

    private var dubbingSelection: [String]? {
        guard let project = dubbingProject else { return nil }
        return [project.id] + project.segments.map { $0.acceptedCandidateID ?? "" }
    }

    public var dubbingHasUnexportedAdoptions: Bool {
        guard let project = dubbingProject,
              project.segments.contains(where: { $0.acceptedCandidateID != nil }) else { return false }
        return dubbingSelection != dubbingExportedSelection
    }

    public var unusedDubbingCandidateCount: Int {
        guard let project = dubbingProject else { return 0 }
        return dubbingCandidates.filter { !project.isUsingCandidate($0.id) }.count
    }

    public func refreshDubbingProjects() {
        do { dubbingProjects = try dubbingProjectStore.list() }
        catch { dubbingMessage = Self.dubbingErrorMessage(for: error) }
    }

    @discardableResult
    public func openDubbingProject(_ id: String) -> Bool {
        closeDubbingProject()
        do {
            guard let project = try dubbingProjectStore.list().first(where: { $0.id == id }) else {
                throw DubbingProjectError.candidateNotFound
            }
            let candidates = try dubbingProjectStore.candidates(forProject: id)
            dubbingProject = project
            dubbingCandidates = candidates
            refreshDubbingProjects()
            return true
        } catch {
            dubbingMessage = Self.dubbingErrorMessage(for: error)
            return false
        }
    }

    @discardableResult
    public func deleteDubbingCandidate(_ candidate: DubbingCandidate) -> Bool {
        guard let project = dubbingProject, dubbingBusySegmentID == nil else { return false }
        do {
            try dubbingProjectStore.deleteCandidate(candidate.id, fromProject: project.id)
            if playingDubbingCandidateID == candidate.id { stopAudio() }
            dubbingCandidates = try dubbingProjectStore.candidates(forProject: project.id)
            dubbingMessage = "已删除这个未采用候选及其音频。"
            return true
        } catch {
            dubbingMessage = Self.dubbingErrorMessage(for: error)
            return false
        }
    }

    @discardableResult
    public func discardUnusedDubbingCandidates() -> Bool {
        guard let project = dubbingProject, dubbingBusySegmentID == nil else { return false }
        do {
            let count = try dubbingProjectStore.discardUnusedCandidates(inProject: project.id)
            if let id = playingDubbingCandidateID, !project.isUsingCandidate(id) { stopAudio() }
            dubbingCandidates = try dubbingProjectStore.candidates(forProject: project.id)
            dubbingMessage = "已清理 \(count) 个未采用候选及其音频，采用和撤销记录已保留。"
            return true
        } catch {
            dubbingMessage = Self.dubbingErrorMessage(for: error)
            return false
        }
    }

    @discardableResult
    public func deleteCurrentDubbingProject() -> Bool {
        guard let project = dubbingProject, dubbingBusySegmentID == nil else { return false }
        do {
            try dubbingProjectStore.deleteProject(project.id)
            closeDubbingProject()
            refreshDubbingProjects()
            dubbingMessage = "已删除项目及候选音频，原作品仍保留。"
            return true
        } catch {
            dubbingMessage = Self.dubbingErrorMessage(for: error)
            return false
        }
    }

    /// 只报告可比的当前模型事实；缺少身份时不推断版本相同或不同。
    public var dubbingConditionsMessage: String? {
        guard let recipe = dubbingProject?.recipe.recipe,
              let mode = recipe.voiceMode,
              let slot = SpeechRailCapabilityRevisionSelector.ttsArtifactSlot(forVoiceMode: mode),
              let current = capabilityFacade.snapshot?.models[slot] else { return nil }
        let pairs: [(String?, String?)] = [
            (recipe.engineRevision, current.runtimeRevision),
            (recipe.modelArtifactRevision, current.catalogRevision),
            (recipe.modelArtifact, current.artifact)
        ]
        guard pairs.contains(where: { previous, observed in
            guard let previous, let observed else { return false }
            return previous != observed
        }) else { return nil }
        return "这件作品的制作版本与当前服务不同。新生成的版本可能无法直接采用；可在候选中按新条件建立项目。"
    }

    @discardableResult
    public func rebuildDubbingProject(using candidate: DubbingCandidate) -> Bool {
        guard let project = dubbingProject else { return false }
        guard dubbingBusySegmentID == nil else {
            dubbingMessage = "请先完成或取消正在进行的重做，再建立新项目。"
            return false
        }
        do {
            let rebuilt = try dubbingProjectStore.rebuild(
                projectID: project.id, usingCandidateID: candidate.id
            )
            closeDubbingProject()
            dubbingProject = rebuilt
            dubbingCandidates = []
            refreshDubbingProjects()
            dubbingMessage = "已按这次生成的制作条件建立新项目。各段需要重新生成和采用，旧项目和音频已保留。"
            return true
        } catch {
            dubbingMessage = Self.dubbingErrorMessage(for: error)
            return false
        }
    }

    /// 从一件已保存作品打开段落编辑。
    ///
    /// 原作品音频原地不动：项目只记录"每段现在用哪个候选"，导出时才按段落顺序拼装。
    /// 段落边界只来自文稿本身——没有可靠时序，就不推断某段在音频里的位置。
    @discardableResult
    public func startDubbingProject(for work: CreativeWork) -> DubbingProject? {
        closeDubbingProject()
        let texts = DubbingSegmentPlanner.segments(from: work.scriptText)
        guard !texts.isEmpty else {
            dubbingMessage = "这件作品的文稿是空的，无法按段落返修。"
            return nil
        }
        let projectID = "dub_" + UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        let project = DubbingProject(
            id: projectID,
            title: work.displayTitle,
            scriptText: work.scriptText,
            recipe: work.provenance,
            segments: texts.enumerated().map { index, text in
                DubbingSegment(id: "\(projectID)_s\(index + 1)", text: text)
            }
        )
        do {
            let committed = try dubbingProjectStore.save(project)
            dubbingProject = committed
            dubbingCandidates = try dubbingProjectStore.candidates(forProject: committed.id)
            refreshDubbingProjects()
            dubbingMessage = nil
            return committed
        } catch {
            dubbingMessage = "无法建立段落项目，请检查磁盘权限和可用空间后重试。"
            return nil
        }
    }

    /// 关闭当前段落项目。在途的重做立刻作废，落地结果不会写进下一个项目。
    public func closeDubbingProject() {
        dubbingRedoGeneration &+= 1
        dubbingRedoTask?.cancel()
        dubbingRedoTask = nil
        dubbingProject = nil
        dubbingCandidates = []
        dubbingBusySegmentID = nil
        dubbingMessage = nil
        dubbingExportBundle = nil
        dubbingExportPreparedSelection = nil
        dubbingExportedSelection = nil
        if playingDubbingCandidateID != nil {
            stopAudio()
        }
        playingDubbingCandidateID = nil
    }

    /// 当前项目用到的音色。查不到、没记录、不在列表里是三件事，各自照实说——
    /// 见 `DubbingProjectVoice`。
    public var dubbingProjectVoice: DubbingProjectVoice {
        DubbingProjectVoice.resolve(
            voiceID: dubbingProject?.recipe.recipe?.voiceID,
            voicesLoadState: creatorVoicesLoadState,
            voices: creatorVoices
        )
    }

    /// 重新生成一段。其余段落、已有候选与采用关系全部原样保留。
    public func startDubbingSegmentRedo(_ segmentID: String) {
        guard let project = dubbingProject else { return }
        guard dubbingBusySegmentID == nil else {
            dubbingMessage = "已有一段在重做，请等它完成或先取消。"
            return
        }
        guard let segment = project.segments.first(where: { $0.id == segmentID }) else {
            return
        }
        // 没有配方摘要就无法证明"这次重做与原作品是同一制作条件"，因此整段拒绝。
        guard project.recipe.recipe?.digest != nil else {
            dubbingMessage = "这件作品没有记录完整的制作配方，无法安全地只重做其中一段。"
            return
        }
        // 「列表没读到」与「音色不在列表里」是两件事：前者是我们还不知道，
        // 后者才是这件作品的条件变了。把前者说成后者，会让用户去「音色库」
        // 修一个根本没坏的音色。
        guard creatorVoicesLoadState == .loaded else {
            dubbingMessage = "还没读到音色列表，无法确认这件作品用的音色是否可用，请先刷新一次。"
            return
        }
        guard let voiceID = project.recipe.recipe?.voiceID,
              let voice = creatorVoices.first(where: { $0.id == voiceID })
        else {
            dubbingMessage = "这件作品使用的音色不在当前的音色列表里，无法重做段落。"
            return
        }
        guard voice.available else {
            dubbingMessage = "这件作品使用的音色当前暂不可用，无法重做段落。"
            return
        }
        let speed = project.recipe.recipe?.effectiveSpeed ?? 1.0
        dubbingBusySegmentID = segmentID
        dubbingMessage = nil
        dubbingRedoGeneration &+= 1
        let generation = dubbingRedoGeneration
        dubbingRedoTask = Task { @MainActor [weak self] in
            await self?.performDubbingSegmentRedo(
                segmentID: segmentID,
                text: segment.text,
                voice: voice,
                speed: speed,
                generation: generation
            )
        }
    }

    /// 取消进行中的段落重做。已保存的候选与采用关系不受影响。
    public func cancelDubbingSegmentRedo() {
        dubbingRedoTask?.cancel()
    }

    private func performDubbingSegmentRedo(
        segmentID: String,
        text: String,
        voice: CreatorVoice,
        speed: Double,
        generation: UInt64
    ) async {
        defer { finishDubbingSegmentRedo(generation: generation) }
        do {
            let options = try await speechRequestOptions(for: voice.id)
            let render = try await requireCreatorCapability(speechRenderClient).createSpeechRender(
                text: text,
                voiceID: voice.id,
                speed: speed,
                options: options.withValidationPolicy("require_output_pass")
            )
            try Task.checkCancellation()
            // 生成期间用户可能已经切换或关闭项目：过期的结果不写进任何项目。
            guard dubbingRedoGeneration == generation,
                  let project = dubbingProject,
                  project.segments.contains(where: { $0.id == segmentID })
            else { return }
            let candidateID = "cand_" + UUID().uuidString
                .replacingOccurrences(of: "-", with: "")
                .lowercased()
            let candidate = DubbingCandidate(
                id: candidateID,
                segmentID: segmentID,
                text: text,
                audioFileName: "\(candidateID).wav",
                provenance: RenderProvenanceSnapshot(
                    state: render.provenance.state,
                    reason: render.provenance.reason,
                    planSHA256: render.planSHA256,
                    recipe: render.recipe,
                    pcmSHA256: render.pcmSHA256,
                    requestID: render.requestID,
                    receiptID: render.receiptID,
                    receiptStatus: render.receiptStatus,
                    receiptCompletedAt: render.receiptCompletedAt
                ),
                durationSeconds: audioPlaybackController.duration(for: render.audioData)
            )
            _ = try dubbingProjectStore.addCandidate(
                candidate,
                audioData: render.audioData,
                toProject: project.id
            )
            dubbingCandidates = try dubbingProjectStore.candidates(forProject: project.id)
            let position = (project.segments.firstIndex { $0.id == segmentID } ?? 0) + 1
            dubbingMessage = "第 \(position) 段已生成新版本，试听满意后再采用。"
        } catch is CancellationError {
            return
        } catch let error as DubbingProjectError {
            guard dubbingRedoGeneration == generation else { return }
            // 音频已经生成、只是落盘失败：说清是本机存储，不要推给创作服务。
            dubbingMessage = Self.dubbingErrorMessage(for: error)
        } catch {
            guard dubbingRedoGeneration == generation else { return }
            dubbingMessage = Self.creatorErrorMessage(for: error)
        }
    }

    private func finishDubbingSegmentRedo(generation: UInt64) {
        guard dubbingRedoGeneration == generation else { return }
        dubbingBusySegmentID = nil
        dubbingRedoTask = nil
    }

    /// 试听一个候选。播放的是候选自己的音频，不动任何采用关系。
    public func playDubbingCandidate(_ candidate: DubbingCandidate) {
        do {
            let data = try dubbingProjectStore.loadAudio(for: candidate)
            try audioPlaybackController.play(data: data)
            isAudioPlaying = audioPlaybackController.isPlaying
            playingDubbingCandidateID = candidate.id
            playingWorkID = nil
            playingVoiceID = nil
            workPlaybackMessage = nil
        } catch {
            clearPlaybackState()
            playingDubbingCandidateID = nil
            dubbingMessage = "这个候选的音频无法播放，请重新生成这一段。"
        }
    }

    /// 采用一个候选：只改引用，旧音频不删除，撤销可以回到上一版。
    @discardableResult
    public func adoptDubbingCandidate(_ candidate: DubbingCandidate) -> Bool {
        guard let project = dubbingProject else { return false }
        do {
            let updated = try dubbingProjectStore.adopt(
                candidateID: candidate.id,
                inSegment: candidate.segmentID,
                ofProject: project.id
            )
            dubbingProject = updated
            dubbingCandidates = try dubbingProjectStore.candidates(forProject: project.id)
            dubbingMessage = "已采用这一段的新版本。"
            return true
        } catch {
            dubbingMessage = Self.dubbingErrorMessage(for: error)
            return false
        }
    }

    /// 撤销一步采用。没有可撤销的历史时不改变当前采用项。
    @discardableResult
    public func undoDubbingAdoption(inSegment segmentID: String) -> Bool {
        guard let project = dubbingProject else { return false }
        let previous = project.segments.first { $0.id == segmentID }?.acceptedCandidateID
        do {
            let updated = try dubbingProjectStore.undoAdoption(
                inSegment: segmentID,
                ofProject: project.id
            )
            dubbingProject = updated
            dubbingCandidates = try dubbingProjectStore.candidates(forProject: project.id)
            guard updated.segments.first(where: { $0.id == segmentID })?.acceptedCandidateID
                != previous
            else {
                dubbingMessage = "这一段已经是最早的版本，没有更早的可回到。"
                return false
            }
            dubbingMessage = "已回到上一个版本。"
            return true
        } catch {
            dubbingMessage = Self.dubbingErrorMessage(for: error)
            return false
        }
    }

    /// 准备导出成品。音频与正文出自同一次采用决策，因此必然一一对应。
    ///
    /// 还有段落没采用版本时直接拒绝：宁可不出货，也不导出与正文对不上的音频。
    public func prepareDubbingExport() {
        guard let project = dubbingProject else { return }
        do {
            guard let exported = try dubbingProjectStore.export(projectID: project.id) else {
                dubbingMessage = "还有段落没有采用版本，全部采用后才能导出成品。"
                return
            }
            dubbingExportBundle = DubbingExportBundle(
                baseName: Self.exportBaseName(for: project.title),
                audio: exported.audio,
                script: exported.script
            )
            dubbingExportPreparedSelection = dubbingSelection
            dubbingMessage = nil
        } catch {
            dubbingMessage = Self.dubbingErrorMessage(for: error)
        }
    }

    /// 把准备好的成品写到用户选定的目录：一份 WAV，一份对应正文。
    @discardableResult
    public func writeDubbingExport(to directory: URL) -> Bool {
        guard let bundle = dubbingExportBundle else { return false }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try bundle.audio.write(
                to: directory.appendingPathComponent(bundle.audioFileName),
                options: .atomic
            )
        } catch {
            dubbingMessage = "导出失败，请确认目标位置可写后重试。"
            return false
        }
        do {
            try Data(bundle.script.utf8).write(
                to: directory.appendingPathComponent(bundle.scriptFileName),
                options: .atomic
            )
        } catch {
            // 音频已经落地、正文没有。照实说：用户需要知道目标目录里现在有一份
            // 没有对应文案的成品，而不是被引导去检查一个其实可写的目录。
            dubbingMessage = "已写入 \(bundle.audioFileName)，但正文没能写入：目标位置可能被占用或空间不足。"
            return false
        }
        dubbingExportedSelection = dubbingExportPreparedSelection
        dubbingExportPreparedSelection = nil
        dubbingExportBundle = nil
        dubbingMessage = "已导出 \(bundle.audioFileName) 和 \(bundle.scriptFileName)。"
        return true
    }

    /// 放弃这次导出准备。用户改了主意时清空，避免下一次导出写出一份旧的成品。
    public func discardDubbingExport() {
        dubbingExportBundle = nil
        dubbingExportPreparedSelection = nil
    }

    private static func exportBaseName(for title: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r")
        let cleaned = title
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 以点开头的名字在 macOS 上是隐藏文件：导出明明报了成功，用户在自己选的
        // 目录里却什么都看不到。去掉前导点，名字仍然是可认的。
        let visible = cleaned.drop(while: { $0 == "." })
        return visible.isEmpty ? "SpeechRail-配音" : String(visible.prefix(80))
    }

    /// 段落返修的错误归属。文案提到的成因必须与用户实际能修的方向一致——
    /// 把数据异常说成磁盘问题，会把用户送去检查一个没坏的方向（#186）。
    static func dubbingErrorMessage(for error: Error) -> String {
        if let projectError = error as? DubbingProjectError {
            return switch projectError {
            case .candidateNotAdoptable:
                "这个候选无法安全采用，请保留音频并检查项目记录。"
            case .candidateRecipeMissing, .candidateTextChanged,
                 .candidateRuntimeChanged, .candidateConditionsChanged,
                 .candidateInUse, .projectHasAdoptedCandidates, .cleanupRequired:
                projectError.errorDescription ?? "这个候选无法安全采用。"
            case .recoveryRequired:
                "配音项目音频未通过完整性校验，请保留项目并打开诊断。"
            case .candidateNotFound, .segmentNotFound:
                "找不到这一段或这个候选，请刷新后重试。"
            case .invalidIdentifier:
                // 这里不是磁盘问题。"检查权限和空间"会把用户送去检查一个没坏的
                // 方向，而真正的成因是这份段落数据自身不自洽——重试无用，
                // 要重新生成这一段（#186）。
                "这件作品的段落数据不一致，无法只重做其中一段。请重新生成这一段后再导出。"
            case .audioFormatUnsupported:
                "这一段的音频格式与其它段落不同，不能拼成一个成品。请重新生成这一段后再导出。"
            case .audioFormatMismatch:
                "各段的音频格式不一致，不能拼成一个成品。请用同一音色与设置重新生成后再导出。"
            }
        }
        // 真正的存储失败不走 DubbingProjectError：DubbingProjectStore 不包装
        // 底层 I/O 错误，磁盘满、没权限会以 CocoaError 原样冒出来。
        if Self.isStorageFailure(error) {
            return "本机存储写入失败，请检查磁盘权限和可用空间后重试。"
        }
        return "段落操作失败，请重试。"
    }

    /// 只认磁盘满与权限两类——文案里承诺的就是这两件，别把别的失败也
    /// 说成它们（判据：文案提到的成因必须与实际可修的方向一致）。
    private static func isStorageFailure(_ error: Error) -> Bool {
        guard let code = (error as? CocoaError)?.code else { return false }
        return code == .fileWriteOutOfSpace
            || code == .fileWriteNoPermission
            || code == .fileReadNoPermission
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
            let render = try await requireCreatorCapability(speechRenderClient).createSpeechRender(
                text: scriptText,
                voiceID: voice.id,
                speed: speed,
                // Formal production states its validation policy here as well as
                // at the client boundary, so a creator client that falls back to
                // the plain speech primitive still produces a checked render.
                options: options.withValidationPolicy("require_output_pass")
            )
            let data = render.audioData
            try Task.checkCancellation()
            // #189：落盘前在后台（非 MainActor）算出本地 PCM 摘要。
            // `synthesizeAndSave` 跑在 `@MainActor` 上；几十秒 PCM 的 SHA-256
            // 是同步开销，必须 `detached` 出去算，主线程只等结果，不占着跑哈希。
            // 口径与服务端一致：WAV 解析 data chunk 的 PCM 字节，而非整个文件。
            // 摘要算不出（非 WAV/损坏）不断然丢音频：provenance 记
            // `audio_digest_unverified`，核对逻辑（`FullTextReceiptCheck`）不判
            // deliverable；摘要对不上记 `audio_digest_mismatch`，音频保留、
            // provenance 降为 `.partial`。缺失与不匹配是两件事，不合并原因码。
            let localDigest: String? = await Task.detached(priority: .utility) {
                try? AudioDigest.sha256HexOfPCM(in: data)
            }.value
            var provenanceState = render.provenance.state
            var provenanceReason = render.provenance.reason
            if let serverDigest = render.pcmSHA256, !serverDigest.isEmpty {
                if localDigest == nil {
                    provenanceReason = "audio_digest_unverified"
                    if provenanceState == .verified { provenanceState = .partial }
                } else if localDigest!.lowercased() != serverDigest.lowercased() {
                    provenanceState = .partial
                    provenanceReason = "audio_digest_mismatch"
                }
                // 一致：保留服务端 provenance 原样，不做任何改动。
            }
            // 生成结果只放内存：用户显式保存后才进入作品库。身份在此刻定下，
            // 之后无论 UI 怎么改，保存的元数据都描述这一次真实的生成。
            let workID = "work_" + UUID().uuidString
                .replacingOccurrences(of: "-", with: "")
                .lowercased()
            let pending = PendingDubbingRender(
                renderID: "render_" + UUID().uuidString
                    .replacingOccurrences(of: "-", with: "")
                    .lowercased(),
                workID: workID,
                scriptText: scriptText,
                voiceID: voice.id,
                voiceName: voice.name,
                voiceRevision: render.voiceRevision,
                planID: render.planID,
                speed: speed,
                renderRevision: (try? workStore.nextRenderRevision(
                    scriptText: scriptText,
                    voiceID: voice.id
               )) ?? 1,
               durationSeconds: audioPlaybackController.duration(for: data),
               audioData: data,
               provenance: RenderProvenanceSnapshot(
                   state: provenanceState,
                   reason: provenanceReason,
                   planSHA256: render.planSHA256,
                   recipe: render.recipe,
                   pcmSHA256: render.pcmSHA256,
                   requestID: render.requestID,
                   receiptID: render.receiptID,
                   receiptStatus: render.receiptStatus,
                   receiptCompletedAt: render.receiptCompletedAt
               )
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

    /// 对克隆音色执行一次输出验收（`POST /v1/speechrail/voices/{id}/quality-runs`）。
    ///
    /// 状态绑定到 voice ID + revision + 请求代际：切换选择、删除或改版后，
    /// 迟到的结果不会污染新的选择。检查通过只代表这一次运行通过并落盘，
    /// 生成时仍会确认当前声音环境。
    @discardableResult
    public func checkVoiceOutput(voiceID: String) async -> VoiceOutputCheckState {
        // A duplicate submission for the same voice is ignored while its check
        // runs; checking a *different* voice supersedes the in-flight request so
        // the stale result can never land on the newly selected voice.
        guard voiceOutputCheckInFlightVoiceID != voiceID else {
            return voiceOutputCheck
        }
        guard !Task.isCancelled else { return voiceOutputCheck }
        let voiceRevision = creatorVoices.first { $0.id == voiceID }?.revision
        voiceOutputCheckGeneration &+= 1
        let generation = voiceOutputCheckGeneration
        voiceOutputCheck = .running(voiceID: voiceID)
        voiceOutputCheckInFlightVoiceID = voiceID
        defer {
            if voiceOutputCheckGeneration == generation {
                voiceOutputCheckInFlightVoiceID = nil
            }
        }
        do {
            let response = try await requireCreatorCapability(voiceQualityClient).runVoiceQuality(
                id: voiceID,
                request: VoiceQualityRunRequest()
            )
            try Task.checkCancellation()
            guard voiceOutputCheckGeneration == generation else { return voiceOutputCheck }
            // 刷新后运行时未知不能把刚结束的检查改判为失败，也不显示「当前生产已确认」。
            _ = await refreshCapabilitySet()
            let refreshedRevision = creatorVoices.first { $0.id == voiceID }?.revision
            guard voiceOutputCheckGeneration == generation else { return voiceOutputCheck }
            guard let voiceRevision, refreshedRevision == voiceRevision else {
                voiceOutputCheck = .error(
                    voiceID: voiceID,
                    voiceRevision: refreshedRevision,
                    message: "检查期间音色版本发生变化，请重新检查。"
                )
                return voiceOutputCheck
            }
            if response.isRecordedOutputPass {
                voiceOutputCheck = .passed(
                    voiceID: voiceID,
                    voiceRevision: voiceRevision,
                    runID: response.legacyReport.runID
                )
            } else if response.legacyReport.status == .pass {
                voiceOutputCheck = .passedNotPersisted(
                    voiceID: voiceID,
                    voiceRevision: voiceRevision
                )
            } else {
                voiceOutputCheck = .failed(
                    voiceID: voiceID,
                    voiceRevision: voiceRevision,
                    message: Self.voiceOutputCheckFailureMessage(response.legacyReport)
                )
            }
        } catch is CancellationError {
            guard voiceOutputCheckGeneration == generation else { return voiceOutputCheck }
            voiceOutputCheck = .idle
        } catch {
            guard voiceOutputCheckGeneration == generation else { return voiceOutputCheck }
            voiceOutputCheck = .error(
                voiceID: voiceID,
                voiceRevision: voiceRevision,
                message: Self.creatorErrorMessage(for: error)
            )
        }
        return voiceOutputCheck
    }

    private static func voiceOutputCheckFailureMessage(
        _ report: VoiceQualityReportSnapshotV2
    ) -> String {
        let codes = report.failureCodes
        if codes.contains("output_invalid") {
            return "配音效果检查未通过：服务生成的参考音频无效，请重试或打开诊断"
        }
        if codes.contains("transcript_mismatch") {
            return "配音效果检查未通过：生成音频与参考文案未能匹配，请重试"
        }
        return "配音效果检查未通过，请重试或打开诊断"
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

    private static func creatorErrorMessage(for error: Error) -> String {
        if let error = error as? CreatorCapabilityUnavailableError {
            return error.errorDescription ?? "当前连接未提供这项创作能力。"
        }
        if let workStoreError = error as? CreativeWorkStoreError {
            return switch workStoreError {
            case .invalidWorkID:
                "生成结果的作品标识无效，请重试"
            case .invalidTitle:
                "作品名称不能为空"
            case .workConflict:
                "作品库已有另一份同名标识的音频，未覆盖现有作品"
            case .storageUnavailable:
                "音频已生成，但本机作品库未能完成保存；请检查磁盘权限和可用空间后重试"
            case .recoveryRequired:
                "作品库需要先完成恢复，请重新打开我的作品后重试"
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
            case "voice_not_production_ready":
                return "该音色还没有通过配音效果检查。请到音色库点「检查配音效果」，通过后即可正式制作。"
            case "voice_validation_runtime_changed":
                return "检查期间服务重新加载了语音模型，本次结果已作废。请重新检查配音效果。"
            case "voice_validation_store_unavailable":
                return "音色验收记录暂时不可读，请检查服务状态后重试"
            case "voice_validation_runtime_unavailable":
                return "语音服务尚未就绪，无法确认音色当前可用性；请先检查服务状态"
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
