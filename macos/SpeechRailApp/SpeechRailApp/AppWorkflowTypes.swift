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

struct SpeechBindingUnavailableError: LocalizedError {
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

struct CloneRegistrationContext: Equatable, Sendable {
    let audio: Data
    let referenceText: String
    let name: String
    let voiceID: String
    let idempotencyKey: String
}

struct VoiceDesignPublicationContext: Equatable, Sendable {
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

enum VoiceDesignPublicationRetryStep: Equatable {
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

enum VoiceDesignPublicationTaskStep {
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

enum VoiceDesignPlaybackIdentity: Equatable {
    case reference(candidateID: String, revision: String)
    case validation(candidateID: String, revision: String, validationID: String)
}

enum CloneIdempotencyLookup {
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

enum OperationWaitResult {
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
