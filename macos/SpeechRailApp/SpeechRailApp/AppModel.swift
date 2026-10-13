import Foundation
import Observation
import SpeechRailControlKit

@MainActor
@Observable
public final class AppModel {
    public let engine: EngineModel
    public let voiceWorkflow: VoiceWorkflowModel
    public let dubbingWorkflow: DubbingWorkflowModel
    public let playback: SharedPlaybackOwner
    private let admission: SpeechCreationAdmission
    private let feedback: CreatorFeedback
    public typealias PendingDubbingRender = DubbingWorkflowModel.PendingDubbingRender
    public typealias VoicePreviewLanguage = VoiceWorkflowModel.VoicePreviewLanguage

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
        let engine = EngineModel(transport: transport, apiClient: apiClient,
                                 discoveryClient: discoveryClient,
                                 observabilityLocation: observabilityLocation, registration: registration)
        let playback = SharedPlaybackOwner(driver: audioPlaybackController)
        let admission = SpeechCreationAdmission()
        let feedback = CreatorFeedback()
        let voices = VoiceWorkflowModel(capabilities: engine, playback: playback,
            admission: admission, feedback: feedback, voiceDirectoryClient: voiceDirectoryClient,
            speechRenderClient: speechRenderClient, voiceDesignClient: voiceDesignClient,
            voiceCloneClient: voiceCloneClient, voiceEditingClient: voiceEditingClient,
            voiceQualityClient: voiceQualityClient)
        self.engine = engine
        self.playback = playback
        self.admission = admission
        self.feedback = feedback
        self.voiceWorkflow = voices
        self.dubbingWorkflow = DubbingWorkflowModel(capabilities: engine, voices: voices,
            playback: playback, admission: admission, feedback: feedback,
            speechRenderClient: speechRenderClient, receiptClient: receiptClient,
            workStore: workStore, dubbingProjectStore: dubbingProjectStore)
    }

    public var service: ServiceSnapshot { engine.service }

    public var serviceConnectionHost: String? { engine.serviceConnectionHost }

    public var profiles: [ProfileSummary] { engine.profiles }

    public var profile: ProfileSnapshot? { engine.profile }

    public var operation: OperationSnapshot? { engine.operation }

    public var health: HealthSnapshot? { engine.health }

    public var metrics: RuntimeMetricsSnapshot? { engine.metrics }

    public var modelCatalog: ModelCatalogSnapshot? { engine.modelCatalog }

    public var modelStatus: ModelStatusSnapshot? { engine.modelStatus }

    public var modelAvailability: ModelAvailabilityState { engine.modelAvailability }

    public var preflightChecks: [PreflightCheckSnapshot] { engine.preflightChecks }

    public var preflightMessage: String? { engine.preflightMessage }

    public var lastPreflightRefresh: Date? { engine.lastPreflightRefresh }

    public var preflightRequestID: UUID? { engine.preflightRequestID }

    public var monitoringSamples: [RuntimeMetricsSample] { engine.monitoringSamples }

    public var monitoringHistory: MetricsHistory? { engine.monitoringHistory }

    public var message: String? { engine.message }

    public var monitoringMessage: String? { engine.monitoringMessage }

    public var monitoringHistoryMessage: String? { engine.monitoringHistoryMessage }

    public var healthMessage: String? { engine.healthMessage }

    public var healthFailure: ServiceHealthFailureKind? { engine.healthFailure }

    public var controlPlaneMessage: String? { engine.controlPlaneMessage }

    public var controlConnectionSummary: String { engine.controlConnectionSummary }

    public var jobQueueSummary: String { engine.jobQueueSummary }

    public var metricsMessage: String? { engine.metricsMessage }

    public var lastHealthRefresh: Date? { engine.lastHealthRefresh }

    public var lastMetricsRefresh: Date? { engine.lastMetricsRefresh }

    public var isBusy: Bool { engine.isBusy }

    public var isRefreshingService: Bool { engine.isRefreshingService }

    public var isRefreshingModels: Bool { engine.isRefreshingModels }

    public var isRefreshingMonitoring: Bool { engine.isRefreshingMonitoring }

    public var isRefreshingMonitoringHistory: Bool { engine.isRefreshingMonitoringHistory }

    public var isRefreshingPreflight: Bool { engine.isRefreshingPreflight }

    public var controlAgentStatus: ControlAgentStatusSnapshot { engine.controlAgentStatus }

    public var serviceOperation: ServiceOperationStatus? { engine.serviceOperation }

    public var isAudioPlaying: Bool { playback.isPlaying }

    public var isVoiceDesignAudioPlaying: Bool { voiceWorkflow.isVoiceDesignAudioPlaying }

    public var playbackProgress: Double { playback.progress }

    public var effectiveCapabilities: EffectiveCapabilitySnapshot? { engine.effectiveCapabilities }

    public var safeVoiceCatalog: SafeVoiceList? { engine.safeVoiceCatalog }

    public var discoveryState: CapabilityDiscoveryState { engine.discoveryState }

    public var discoveryMetadata: ServiceResponseMetadata? { engine.discoveryMetadata }

    public var isRefreshingDiscovery: Bool { engine.isRefreshingDiscovery }

    public var capabilityFacade: AppCapabilityFacade { engine.capabilityFacade }
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

    public var creatorVoices: [CreatorVoice] { voiceWorkflow.creatorVoices }

    public var creatorVoicesLoadState: CreatorVoicesLoadState { voiceWorkflow.creatorVoicesLoadState }

    public var isRefreshingCreatorVoiceDetail: Bool { voiceWorkflow.isRefreshingCreatorVoiceDetail }

    public var creatorVoiceDetailMessage: String? { voiceWorkflow.creatorVoiceDetailMessage }

    public var works: [CreativeWork] { dubbingWorkflow.works }

    public var creatorMessage: String? { feedback.message }

    public var isRefreshingCreatorVoices: Bool { voiceWorkflow.isRefreshingCreatorVoices }

    public var isCreatingSpeech: Bool { admission.isBusy }

    public var previewingVoiceID: String? { voiceWorkflow.previewingVoiceID }

    public var lastCreatedWork: CreativeWork? { dubbingWorkflow.lastCreatedWork }

    public var pendingDubbing: PendingDubbingRender? { dubbingWorkflow.pendingDubbing }

    public var dubbingDeskSlot: DubbingDeskSlot { dubbingWorkflow.dubbingDeskSlot }

    public var creatorVoicePickerState: CreatorVoicePickerState { voiceWorkflow.creatorVoicePickerState }

    public var dubbingProject: DubbingProject? { dubbingWorkflow.dubbingProject }

    public var dubbingProjects: [DubbingProject] { dubbingWorkflow.dubbingProjects }

    public var dubbingCandidates: [DubbingCandidate] { dubbingWorkflow.dubbingCandidates }

    public var dubbingBusySegmentID: String? { dubbingWorkflow.dubbingBusySegmentID }

    public var dubbingMessage: String? { dubbingWorkflow.dubbingMessage }

    public var playingDubbingCandidateID: String? { playback.playingDubbingCandidateID }

    public var dubbingExportBundle: DubbingExportBundle? { dubbingWorkflow.dubbingExportBundle }

    public var isCreatingVoicePreview: Bool { voiceWorkflow.isCreatingVoicePreview }

    public var voiceDesignCandidates: [VoiceDesignCandidateSnapshot] { voiceWorkflow.voiceDesignCandidates }

    public var voiceDesignSavedSlots: Set<String> { voiceWorkflow.voiceDesignSavedSlots }

    public var voiceDesignSavingSlot: String? { voiceWorkflow.voiceDesignSavingSlot }

    public var isGeneratingVoiceDesign: Bool { voiceWorkflow.isGeneratingVoiceDesign }

    public var voiceDesignErrorMessage: String? { voiceWorkflow.voiceDesignErrorMessage }

    public var voiceDesignSuccessMessage: String? { voiceWorkflow.voiceDesignSuccessMessage }

    public var voiceDesignPublication: VoiceDesignPublicationSnapshot { voiceWorkflow.voiceDesignPublication }

    public var isRegisteringVoice: Bool { voiceWorkflow.isRegisteringVoice }

    public var isCancellingVoiceDesignPublication: Bool { voiceWorkflow.isCancellingVoiceDesignPublication }

    public var canRetryVoiceDesignCancellation: Bool { voiceWorkflow.canRetryVoiceDesignCancellation }

    public var isUpdatingVoice: Bool { voiceWorkflow.isUpdatingVoice }

    public var isDeletingVoice: Bool { voiceWorkflow.isDeletingVoice }

    public var recording: VoiceRecordingController { voiceWorkflow.recording }

    public var clonePrompts: [ClonePrompt] { voiceWorkflow.clonePrompts }

    public var clonePromptLoadState: ClonePromptLoadState { voiceWorkflow.clonePromptLoadState }

    public var cloneReferenceAnalysis: AudioReferenceAnalysis? { voiceWorkflow.cloneReferenceAnalysis }

    public var cloneRecordingAudio: Data? { voiceWorkflow.cloneRecordingAudio }

    public var cloneEvaluation: VoiceQualityReportSnapshot? { voiceWorkflow.cloneEvaluation }

    public var isEvaluatingCloneReference: Bool { voiceWorkflow.isEvaluatingCloneReference }

    public var isRegisteringCloneVoice: Bool { voiceWorkflow.isRegisteringCloneVoice }

    public var cloneMessage: String? { voiceWorkflow.cloneMessage }

    public var lastRegisteredCloneVoice: CreatorVoice? { voiceWorkflow.lastRegisteredCloneVoice }

    public var voiceOutputCheck: VoiceOutputCheckState { voiceWorkflow.voiceOutputCheck }

    public var voiceOutputCheckInFlightVoiceID: String? { voiceWorkflow.voiceOutputCheckInFlightVoiceID }

    public var cloneRegistrationID: String? { voiceWorkflow.cloneRegistrationID }

    public var cloneIdempotencyKey: String? { voiceWorkflow.cloneIdempotencyKey }

    public var playingWorkID: String? { playback.playingWorkID }

    public var playingVoiceID: String? { playback.playingVoiceID }

    public var playbackLevel: Float { playback.level }

    public var worksMessage: String? { dubbingWorkflow.worksMessage }

    public var workActionMessage: String? { dubbingWorkflow.workActionMessage }

    public var workPlaybackMessage: String? { dubbingWorkflow.workPlaybackMessage }

    public var hasActiveMutation: Bool { engine.hasActiveMutation }

    public var sessionActivity: (@MainActor () -> String?)? {
        get { engine.sessionActivity }
        set { engine.sessionActivity = newValue }
    }

    public var profileSwitchBlockedReason: String? { engine.profileSwitchBlockedReason }

    static func previewCacheKey(
        voice: CreatorVoice,
        options: SpeechRailRequestOptions,
        catalogRevision: String?,
        input: String,
        languageOverride: String?,
        speed: Double
    ) -> VoicePreviewCacheKey {
        VoiceWorkflowModel.previewCacheKey(voice: voice, options: options, catalogRevision: catalogRevision, input: input, languageOverride: languageOverride, speed: speed)
    }

    public func fetchCreatorVoices() async throws -> [CreatorVoice] {
        try await voiceWorkflow.fetchCreatorVoices()
    }

    public func realtimeCapabilityBinding(for voiceID: String? = nil) async -> RealtimeCapabilityBinding? {
        await engine.realtimeCapabilityBinding(for: voiceID)
    }

    public func createSpeech(
        text: String,
        voiceID: String,
        speed: Double,
        language: String? = nil
    ) async throws -> Data {
        try await voiceWorkflow.createSpeech(text: text, voiceID: voiceID, speed: speed, language: language)
    }

    public func createVoicePreview(
        text: String,
        instruction: String,
        speed: Double,
        seed: Int?
    ) async throws -> Data {
        try await voiceWorkflow.createVoicePreview(text: text, instruction: instruction, speed: speed, seed: seed)
    }

    public func startVoiceDesignGeneration(
        instruction: String,
        referenceText: String,
        speed: Double = 1.0
    ) {
        voiceWorkflow.startVoiceDesignGeneration(instruction: instruction, referenceText: referenceText, speed: speed)
    }

    public func cancelVoiceDesignGeneration() {
        voiceWorkflow.cancelVoiceDesignGeneration()
    }

    public func retryVoiceDesignCandidate(slot: String) {
        voiceWorkflow.retryVoiceDesignCandidate(slot: slot)
    }

    public func startVoiceDesignPublication(
        _ candidate: VoiceDesignCandidateSnapshot,
        name: String
    ) {
        voiceWorkflow.startVoiceDesignPublication(candidate, name: name)
    }

    public func confirmVoiceDesignReference() {
        voiceWorkflow.confirmVoiceDesignReference()
    }

    public func publishVoiceDesignPublication(
        identityConfirmed: Bool,
        naturalnessConfirmed: Bool
    ) {
        voiceWorkflow.publishVoiceDesignPublication(identityConfirmed: identityConfirmed, naturalnessConfirmed: naturalnessConfirmed)
    }

    public func retryVoiceDesignPublication() {
        voiceWorkflow.retryVoiceDesignPublication()
    }

    public var voiceDesignPublicationRetryActionTitle: String { voiceWorkflow.voiceDesignPublicationRetryActionTitle }

    public func cancelVoiceDesignPublication() {
        voiceWorkflow.cancelVoiceDesignPublication()
    }

    func markVoiceDesignReferenceAudioPlaybackFinished(successfully: Bool) {
        voiceWorkflow.markVoiceDesignReferenceAudioPlaybackFinished(successfully: successfully)
    }

    func markVoiceDesignValidationAudioPlaybackFinished(successfully: Bool) {
        voiceWorkflow.markVoiceDesignValidationAudioPlaybackFinished(successfully: successfully)
    }

    public func previewDesignedVoice(
        text: String,
        instruction: String,
        speed: Double,
        seed: Int?
    ) async -> Data? {
        await voiceWorkflow.previewDesignedVoice(text: text, instruction: instruction, speed: speed, seed: seed)
    }

    public func refreshClonePrompts() async {
        await voiceWorkflow.refreshClonePrompts()
    }

    public func acceptCloneRecording(fileAt url: URL) async {
        await voiceWorkflow.acceptCloneRecording(fileAt: url)
    }

    @discardableResult
    public func discardCloneRecording() -> Bool {
        voiceWorkflow.discardCloneRecording()
    }

    @discardableResult
    public func evaluateCloneReference(
        referenceText: String,
        name: String
    ) async -> VoiceQualityReportSnapshot? {
        await voiceWorkflow.evaluateCloneReference(referenceText: referenceText, name: name)
    }

    public func registerCloneVoice(
        referenceText: String,
        name: String
    ) async -> CreatorVoice? {
        await voiceWorkflow.registerCloneVoice(referenceText: referenceText, name: name)
    }

    public func clearCloneMessage() {
        voiceWorkflow.clearCloneMessage()
    }

    public func deleteVoice(_ voice: CreatorVoice) async -> Bool {
        await voiceWorkflow.deleteVoice(voice)
    }

    public func updateVoice(
        _ voice: CreatorVoice,
        name: String?,
        instruction: String?,
        seed: Int?
    ) async -> Bool {
        await voiceWorkflow.updateVoice(voice, name: name, instruction: instruction, seed: seed)
    }

    public func previewVoice(
        _ voice: CreatorVoice,
        text: String? = nil,
        speed: Double = 1.0
    ) async {
        await voiceWorkflow.previewVoice(voice, text: text, speed: speed)
    }

    public func startVoicePreview(
        _ voice: CreatorVoice,
        text: String? = nil,
        speed: Double = 1.0
    ) {
        voiceWorkflow.startVoicePreview(voice, text: text, speed: speed)
    }

    public func cancelVoicePreview() {
        voiceWorkflow.cancelVoicePreview()
    }

    public func playAudio(data: Data) throws {
        try voiceWorkflow.playAudio(data: data)
    }

    public func playVoiceDesignReferenceAudio() {
        voiceWorkflow.playVoiceDesignReferenceAudio()
    }

    public func playVoiceDesignValidationAudio() {
        voiceWorkflow.playVoiceDesignValidationAudio()
    }

    public func audioDuration(for data: Data) -> TimeInterval? { playback.duration(for: data) }

    public func stopAudio() { playback.stop() }

    func noteVoiceDesignAudioPlaybackFinished(successfully: Bool) {
        voiceWorkflow.noteVoiceDesignAudioPlaybackFinished(successfully: successfully)
    }

    public func waveformEnvelope(forVoiceID id: String) -> [CGFloat]? { playback.waveformEnvelope(kind: "voice", id: id) }

    public func waveformEnvelope(forWorkID id: String) -> [CGFloat]? { playback.waveformEnvelope(kind: "work", id: id) }

    public func prepareWaveform(for work: CreativeWork) {
        dubbingWorkflow.prepareWaveform(for: work)
    }

    @discardableResult
    public func refreshCreatorVoices() async -> Bool {
        await voiceWorkflow.refreshCreatorVoices()
    }

    @discardableResult
    public func refreshCapabilitySet() async -> Bool {
        await voiceWorkflow.refreshCapabilitySet()
    }

    @discardableResult
    public func refreshCreatorVoiceDetail(id: String) async -> Bool {
        await voiceWorkflow.refreshCreatorVoiceDetail(id: id)
    }

    public func lookupWorkReceipt(_ work: CreativeWork) async throws -> RenderReceipt {
        try await dubbingWorkflow.lookupWorkReceipt(work)
    }

    public func refreshWorks() {
        dubbingWorkflow.refreshWorks()
    }

    public var deletedWorksSummary: CreativeWorkRecoverySummary? { dubbingWorkflow.deletedWorksSummary }

    public var deletedWorksMessage: String? { dubbingWorkflow.deletedWorksMessage }

    public func refreshDeletedWorks() {
        dubbingWorkflow.refreshDeletedWorks()
    }

    @discardableResult
    public func trashDeletedWorks() -> Bool {
        dubbingWorkflow.trashDeletedWorks()
    }

    public func loadWorkAudio(_ work: CreativeWork) throws -> Data {
        try dubbingWorkflow.loadWorkAudio(work)
    }

    public func workAudioURL(_ work: CreativeWork) -> URL? {
        dubbingWorkflow.workAudioURL(work)
    }

    @discardableResult
    public func deleteWork(_ work: CreativeWork) -> Bool {
        dubbingWorkflow.deleteWork(work)
    }

    @discardableResult
    public func renameWork(_ work: CreativeWork, title: String) -> Bool {
        dubbingWorkflow.renameWork(work, title: title)
    }

    public static func previewLanguage(forVoiceID voiceID: String) -> VoicePreviewLanguage {
        VoiceWorkflowModel.previewLanguage(forVoiceID: voiceID)
    }

    public static func resolvedPreviewText(forVoiceID voiceID: String, text: String?) -> String {
        VoiceWorkflowModel.resolvedPreviewText(forVoiceID: voiceID, text: text)
    }

    public static func resolvedPreviewText(for voice: CreatorVoice, text: String?) -> String {
        VoiceWorkflowModel.resolvedPreviewText(for: voice, text: text)
    }

    public static func previewLanguage(for voice: CreatorVoice) -> String {
        VoiceWorkflowModel.previewLanguage(for: voice)
    }

    public static func defaultPreviewText(forVoiceID voiceID: String) -> String {
        VoiceWorkflowModel.defaultPreviewText(forVoiceID: voiceID)
    }

    public func startSynthesisAndSave(
        text: String,
        voice: CreatorVoice,
        speed: Double
    ) {
        dubbingWorkflow.startSynthesisAndSave(text: text, voice: voice, speed: speed)
    }

    public func cancelSynthesis() {
        dubbingWorkflow.cancelSynthesis()
    }

    public func discardPendingDubbing() {
        dubbingWorkflow.discardPendingDubbing()
    }

    @discardableResult
    public func savePendingDubbing() -> CreativeWork? {
        dubbingWorkflow.savePendingDubbing()
    }

    public func playPendingDubbing() {
        dubbingWorkflow.playPendingDubbing()
    }

    public var dubbingHasUnexportedAdoptions: Bool { dubbingWorkflow.dubbingHasUnexportedAdoptions }

    public var unusedDubbingCandidateCount: Int { dubbingWorkflow.unusedDubbingCandidateCount }

    public func refreshDubbingProjects() {
        dubbingWorkflow.refreshDubbingProjects()
    }

    @discardableResult
    public func openDubbingProject(_ id: String) -> Bool {
        dubbingWorkflow.openDubbingProject(id)
    }

    @discardableResult
    public func deleteDubbingCandidate(_ candidate: DubbingCandidate) -> Bool {
        dubbingWorkflow.deleteDubbingCandidate(candidate)
    }

    @discardableResult
    public func discardUnusedDubbingCandidates() -> Bool {
        dubbingWorkflow.discardUnusedDubbingCandidates()
    }

    @discardableResult
    public func deleteCurrentDubbingProject() -> Bool {
        dubbingWorkflow.deleteCurrentDubbingProject()
    }

    public var dubbingConditionsMessage: String? { dubbingWorkflow.dubbingConditionsMessage }

    @discardableResult
    public func rebuildDubbingProject(using candidate: DubbingCandidate) -> Bool {
        dubbingWorkflow.rebuildDubbingProject(using: candidate)
    }

    @discardableResult
    public func startDubbingProject(for work: CreativeWork) -> DubbingProject? {
        dubbingWorkflow.startDubbingProject(for: work)
    }

    public func closeDubbingProject() {
        dubbingWorkflow.closeDubbingProject()
    }

    public var dubbingProjectVoice: DubbingProjectVoice { dubbingWorkflow.dubbingProjectVoice }

    public func startDubbingSegmentRedo(_ segmentID: String) {
        dubbingWorkflow.startDubbingSegmentRedo(segmentID)
    }

    public func cancelDubbingSegmentRedo() {
        dubbingWorkflow.cancelDubbingSegmentRedo()
    }

    public func playDubbingCandidate(_ candidate: DubbingCandidate) {
        dubbingWorkflow.playDubbingCandidate(candidate)
    }

    @discardableResult
    public func adoptDubbingCandidate(_ candidate: DubbingCandidate) -> Bool {
        dubbingWorkflow.adoptDubbingCandidate(candidate)
    }

    @discardableResult
    public func undoDubbingAdoption(inSegment segmentID: String) -> Bool {
        dubbingWorkflow.undoDubbingAdoption(inSegment: segmentID)
    }

    public func prepareDubbingExport() {
        dubbingWorkflow.prepareDubbingExport()
    }

    @discardableResult
    public func writeDubbingExport(to directory: URL) -> Bool {
        dubbingWorkflow.writeDubbingExport(to: directory)
    }

    public func discardDubbingExport() {
        dubbingWorkflow.discardDubbingExport()
    }

    static func dubbingErrorMessage(for error: Error) -> String {
        DubbingWorkflowModel.dubbingErrorMessage(for: error)
    }

    public func synthesizeAndSave(
        text: String,
        voice: CreatorVoice,
        speed: Double
    ) async -> CreativeWork? {
        await dubbingWorkflow.synthesizeAndSave(text: text, voice: voice, speed: speed)
    }

    @discardableResult
    public func checkVoiceOutput(voiceID: String) async -> VoiceOutputCheckState {
        await voiceWorkflow.checkVoiceOutput(voiceID: voiceID)
    }

    public func playWork(_ work: CreativeWork) {
        dubbingWorkflow.playWork(work)
    }

    public func refreshDiscovery() async {
        await engine.refreshDiscovery()
    }

    public func refresh() async {
        await engine.refresh()
    }

    public func refreshModelsAndHealth() async {
        await engine.refreshModelsAndHealth()
    }

    public func refreshModels() async {
        await engine.refreshModels()
    }

    public func refreshControlAgentStatus() {
        engine.refreshControlAgentStatus()
    }

    public func enableControlAgent() {
        engine.enableControlAgent()
    }

    public func openControlAgentSettings() {
        engine.openControlAgentSettings()
    }

    public var observability: ObservabilityLocation { engine.observability }

    public func refreshMonitoring() async {
        await engine.refreshMonitoring()
    }

    public func refreshMonitoringHistory(
        windowSeconds: Double,
        bucketSeconds: Double? = nil,
        now: Date = Date()
    ) async {
        await engine.refreshMonitoringHistory(windowSeconds: windowSeconds, bucketSeconds: bucketSeconds, now: now)
    }

    public func refreshPreflight() async {
        await engine.refreshPreflight()
    }

    public func prepareModels(_ selection: SpecSelection) async {
        await engine.prepareModels(selection)
    }

    public func cancelCurrentOperation() async {
        await engine.cancelCurrentOperation()
    }

    public func execute(
        _ command: ControlCommand,
        selection: SpecSelection? = nil
    ) async {
        await engine.execute(command, selection: selection)
    }

}
