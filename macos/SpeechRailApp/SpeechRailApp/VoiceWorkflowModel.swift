import Foundation
import Observation
import SpeechRailControlKit

@MainActor
public protocol CreatorVoiceReading: AnyObject {
    var creatorVoices: [CreatorVoice] { get }
    var creatorVoicesLoadState: CreatorVoicesLoadState { get }
}

@MainActor
@Observable
public final class VoiceWorkflowModel: CreatorVoiceReading {

    private let capabilities: any EngineCapabilityReading
    private let playback: SharedPlaybackOwner
    private let admission: SpeechCreationAdmission
    private let feedback: CreatorFeedback
    public private(set) var creatorMessage: String? {
        get { feedback.message }
        set { feedback.publish(newValue) }
    }
    public var isCreatingSpeech: Bool { admission.isBusy }
    public var isAudioPlaying: Bool { playback.isPlaying }
    public var playingVoiceID: String? { playback.playingVoiceID }
    private var capabilityFacade: AppCapabilityFacade { capabilities.capabilityFacade }
    private var discoveryState: CapabilityDiscoveryState { capabilities.discoveryState }
    private var safeVoiceCatalog: SafeVoiceList? { capabilities.safeVoiceCatalog }
    private var effectiveCapabilities: EffectiveCapabilitySnapshot? { capabilities.effectiveCapabilities }
    private func refreshDiscovery() async { await capabilities.refreshDiscovery() }
    private func speechRequestOptions(for voiceID: String) async throws -> SpeechRailRequestOptions {
        try await capabilities.speechRequestOptions(for: voiceID)
    }
    public func stopAudio() { playback.stop() }
    private func clearPlaybackState() { playback.stop() }
    private static func envelopeKey(kind: String, id: String) -> String { "\(kind):\(id)" }
    private func cacheEnvelope(key: String, compute: @escaping @Sendable (Int) -> [CGFloat]?) {
        playback.cacheEnvelope(key: key, compute: compute)
    }
    public func audioDuration(for data: Data) -> TimeInterval? { playback.duration(for: data) }

    public init(
        capabilities: any EngineCapabilityReading,
        playback: SharedPlaybackOwner,
        admission: SpeechCreationAdmission,
        feedback: CreatorFeedback,
        voiceDirectoryClient: (any SpeechRailVoiceDirectoryClient)? = nil,
        speechRenderClient: (any SpeechRailSpeechRenderClient)? = nil,
        voiceDesignClient: (any SpeechRailVoiceDesignClient)? = nil,
        voiceCloneClient: (any SpeechRailVoiceCloneClient)? = nil,
        voiceEditingClient: (any SpeechRailVoiceEditingClient)? = nil,
        voiceQualityClient: (any SpeechRailVoiceQualityClient)? = nil
    ) {
        self.capabilities = capabilities
        self.playback = playback
        self.admission = admission
        self.feedback = feedback
        self.voiceDirectoryClient = voiceDirectoryClient
        self.speechRenderClient = speechRenderClient
        self.voiceDesignClient = voiceDesignClient
        self.voiceCloneClient = voiceCloneClient
        self.voiceEditingClient = voiceEditingClient
        self.voiceQualityClient = voiceQualityClient
    }

    private var voiceDesignPlaybackIdentity: VoiceDesignPlaybackIdentity? {
        switch playback.target {
        case let .designReference(id, revision): return .reference(candidateID: id, revision: revision)
        case let .designValidation(id, revision, validationID):
            return .validation(candidateID: id, revision: revision, validationID: validationID)
        default: return nil
        }
    }
    func noteVoiceDesignAudioPlaybackFinished(successfully: Bool) {
        guard let identity = voiceDesignPlaybackIdentity else { return }
        playback.stop()
        finishVoiceDesignPlayback(identity: identity, successfully: successfully)
    }
    private func playVoiceAudio(data: Data, voiceID: String) throws {
        try playback.play(data: data, target: .voice(voiceID)) { [weak self] success in
            if !success { self?.creatorMessage = "音频播放失败，请重试。" }
        }
    }
    public var isVoiceDesignAudioPlaying: Bool {
        isAudioPlaying && voiceDesignPlaybackIdentity != nil
    }
    public private(set) var creatorVoices: [CreatorVoice] = []
    public private(set) var creatorVoicesLoadState: CreatorVoicesLoadState = .unknown
    public private(set) var isRefreshingCreatorVoiceDetail = false
    public private(set) var creatorVoiceDetailMessage: String?
    public private(set) var isRefreshingCreatorVoices = false
    public private(set) var previewingVoiceID: String?

    /// 配音台音色选择器的状态。四个取值穷举 `CreatorVoicesLoadState`，
    /// 不留 `default`：漏掉一个取值会被安静地当成"没有音色"。
    public var creatorVoicePickerState: CreatorVoicePickerState {
        CreatorVoicePickerState.resolve(
            loadState: creatorVoicesLoadState,
            voices: creatorVoices
        )
    }
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
    /// 必须以 20Hz 更新，走组合层中转只会多一层无用的拷贝。
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
    private let voiceDirectoryClient: (any SpeechRailVoiceDirectoryClient)?
    private let speechRenderClient: (any SpeechRailSpeechRenderClient)?
    private let voiceDesignClient: (any SpeechRailVoiceDesignClient)?
    private let voiceCloneClient: (any SpeechRailVoiceCloneClient)?
    private let voiceEditingClient: (any SpeechRailVoiceEditingClient)?
    private let voiceQualityClient: (any SpeechRailVoiceQualityClient)?
    private var cloneRegistrationContext: CloneRegistrationContext?
    private var voiceDesignPublicationContext: VoiceDesignPublicationContext?
    private var voiceDesignPublicationRetryStep: VoiceDesignPublicationRetryStep?
    private var voiceDesignPublicationGeneration: UInt64 = 0
    private var creatorVoiceDetailGeneration: UInt64 = 0
    private var creatorVoiceRefreshGeneration: UInt64 = 0
    /// 质量检查的请求代际：只有最新一次请求可以落地结果。
    private var voiceOutputCheckGeneration: UInt64 = 0
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

    public func fetchCreatorVoices() async throws -> [CreatorVoice] {
        try await requireCreatorCapability(voiceDirectoryClient).fetchVoices()
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
            CreatorWorkflowErrors.message(for: error),
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
            creatorMessage = CreatorWorkflowErrors.message(for: error)
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
            clonePromptLoadState = .failed(CreatorWorkflowErrors.message(for: error))
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
            cloneMessage = CreatorWorkflowErrors.message(for: error)
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
            cloneMessage = CreatorWorkflowErrors.message(for: error)
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
            return .failed(CreatorWorkflowErrors.message(for: error))
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
            creatorMessage = CreatorWorkflowErrors.message(for: error)
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
            creatorMessage = CreatorWorkflowErrors.message(for: error)
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
                admission.release(.voice)
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
        invalidateVoicePreview()
        let token = voicePreviewToken

        // 先解析当前有效版本，再谈缓存：音色被撤销或服务换用另一份模型之后，
        // 不应该复用旧音频。
        let options: SpeechRailRequestOptions
        do {
            options = try await speechRequestOptions(for: voice.id)
        } catch {
            guard token == voicePreviewToken, !Task.isCancelled else { return }
            creatorMessage = CreatorWorkflowErrors.message(for: error)
            return
        }
        guard token == voicePreviewToken, !Task.isCancelled, !admission.isBusy else { return }

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
        // 优先命中本地内存缓存：0 毫秒即点即播，彻底免除反复生成延迟
        if let cachedData = previewAudioCache.data(for: cacheKey) {
            do {
                try playVoiceAudio(data: cachedData, voiceID: voice.id)

                cacheEnvelope(key: Self.envelopeKey(kind: "voice", id: voice.id)) { buckets in
                    AudioEnvelope.levels(forAudioData: cachedData, buckets: buckets)
                }
            } catch {
                clearPlaybackState()
                creatorMessage = "音频播放失败，请重试。"
            }
            return
        }

        guard admission.acquire(.voice) else { return }
        previewingVoiceID = voice.id
        creatorMessage = nil
        defer {
            // 只有仍是最新请求时才允许清理共享状态。
            if token == voicePreviewToken {
                admission.release(.voice)
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
                try playVoiceAudio(data: data, voiceID: voice.id)
            } catch {
                clearPlaybackState()
                throw error
            }

            // 顺手将真实音频包络算出来，让声波呈现当前真实声音的轮廓
            cacheEnvelope(key: Self.envelopeKey(kind: "voice", id: voice.id)) { buckets in
                AudioEnvelope.levels(forAudioData: data, buckets: buckets)
            }
        } catch is CancellationError {
            return
        } catch {
            // 迟到的失败同样不能覆盖新请求的提示。
            guard token == voicePreviewToken else { return }
            creatorMessage = CreatorWorkflowErrors.message(for: error)
        }
    }

    /// Own voice-library preview requests within this workflow so a request
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
            admission.release(.voice)
        }
        stopAudio()
    }

    public func playAudio(data: Data) throws {
        try playback.play(data: data, target: .generic) { [weak self] success in
            if !success { self?.creatorMessage = "音频播放失败，请重试。" }
        }
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
            let identity = VoiceDesignPlaybackIdentity.reference(candidateID: candidateID, revision: revision)
            try playback.play(data: audio, target: .designReference(candidateID: candidateID, revision: revision)) { [weak self] success in
                self?.finishVoiceDesignPlayback(identity: identity, successfully: success)
            }
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
            let identity = VoiceDesignPlaybackIdentity.validation(candidateID: candidateID, revision: revision, validationID: validationID)
            try playback.play(data: audio, target: .designValidation(candidateID: candidateID, revision: revision, validationID: validationID)) { [weak self] success in
                self?.finishVoiceDesignPlayback(identity: identity, successfully: success)
            }
        } catch {
            voiceDesignPublication.message = "复验音频无法播放，请重新读取后重试。"
        }
    }

    private func finishVoiceDesignPlayback(identity: VoiceDesignPlaybackIdentity, successfully: Bool) {

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
            creatorMessage = CreatorWorkflowErrors.message(for: error)
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
            creatorVoiceDetailMessage = CreatorWorkflowErrors.message(for: error)
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
                message: CreatorWorkflowErrors.message(for: error)
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

}
