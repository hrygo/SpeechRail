import Foundation
import Observation
import SpeechRailControlKit

@MainActor
@Observable
public final class TeleprompterSession {
    public enum Phase: String, Sendable, Equatable {
        case draft
        case analyzing
        case review
        case ready
        case preparing
        case following
        case paused
        case uncertain
        case manual
        case ended
    }

    public enum BlockReason: Equatable, Sendable {
        case noActiveVersion
        case microphoneDenied
        case serviceNotReady(String)
        case serviceBusy(String)
        case occupiedBy(SessionKind)
        case streamFailed(String)
        case aiUnavailable(String)
        case storeUnavailable(String)

        public var title: String {
            switch self {
            case .noActiveVersion: "还没有可跟读的稿子"
            case .microphoneDenied: "麦克风权限受限"
            case .serviceNotReady: "语音识别服务未就绪"
            case .serviceBusy: "语音识别正在被其他功能占用"
            case .occupiedBy(let kind): "\(kind.title)正在使用麦克风"
            case .streamFailed: "语音跟读连接中断"
            case .aiUnavailable: "AI 整理暂时不可用"
            case .storeUnavailable: "稿件保存失败"
            }
        }

        public var detail: String {
            switch self {
            case .noActiveVersion:
                "先确认一份用于跟读的稿子，或直接按原文分段。"
            case .microphoneDenied:
                "请在系统设置中允许 SpeechRail 使用麦克风，然后再试。你也可以先手动提词。"
            case .serviceNotReady:
                "语音识别服务暂不可用。稍后重试，或选择手动看稿。"
            case .serviceBusy:
                "语音识别正在处理其他任务。稍后重试，或先手动看稿。"
            case .streamFailed:
                "语音跟读已中断。当前稿件仍保留，你可以重新连接，或继续手动看稿。"
            case .aiUnavailable(let message):
                Self.friendlyAIMessage(message)
            case .storeUnavailable(let message):
                message
            case .occupiedBy(let kind):
                "结束\(kind.title)后才能开始跟读；现在仍可以手动提词。"
            }
        }

        private static func friendlyAIMessage(_ raw: String) -> String {
            if raw.contains("error") || raw.contains("fail") {
                return "AI 整理服务暂时不可用，你可以直接使用原稿进行跟读，或稍后重试。"
            }
            return raw.isEmpty ? "AI 整理服务暂时不可用，可直接使用原稿。" : raw
        }
    }

    public enum ServiceReadiness: Sendable {
        case ready(profile: String?)
        case notReady(String)
    }

    public private(set) var phase: Phase = .draft
    public private(set) var blocked: BlockReason?
    public var voiceAssistState: TeleprompterVoiceAssistState { voiceLifecycle.state }
    public var isMicrophoneCapturing: Bool { source != nil }
    public private(set) var document: TeleprompterDocument?
    public private(set) var versions: [TeleprompterVersion] = []
    public private(set) var unavailableDocuments: [TeleprompterV2DocumentListItem] = []
    public private(set) var pendingVersion: TeleprompterVersion?
    public private(set) var partialText: String?
    public private(set) var currentSegmentIndex = 0
    public private(set) var uncertainty: Double?
    public private(set) var lastFailure: String?
    public private(set) var readingOffset = 0
    public private(set) var isResuming = false
    public private(set) var hasHeardSpeech = false
    public private(set) var followState: TeleprompterFollowState = .waitingForSpeech
    public private(set) var followStatusText = TeleprompterFollowPresentation.statusText(for: .waitingForSpeech)
    /// In-memory timing evidence for diagnosing follow lag; no text or IDs are retained.
    public private(set) var followLatencyDiagnostics = TeleprompterLatencyDiagnostics()

    // MARK: - 终版规格状态与参数
    public var targetMinutes: Int = TeleprompterTimingPolicy.defaultTargetMinutes
    public var pace: TeleprompterPace = .natural
    public var calibrationFactor: Double = 1.0
    public var contentSelection: TeleprompterContentSelection = TeleprompterContentSelection()
    public private(set) var reviewItems: [TeleprompterReviewItem] = []
    public private(set) var readingBlocks: [TeleprompterReadingBlock] = []
    public private(set) var runClock: TeleprompterRunClockState = TeleprompterRunClockState()
    private var clockTask: Task<Void, Never>?
    private var stageGeneration: UUID?
    private var stageCloseToken: UUID?

    public var canEdit: Bool {
        source == nil && client == nil && runningVersion == nil
            && phase != .preparing && !isResuming && !isStoppingIntentionally
            && !isTightening && !isAnnotating
    }
    public var isCapturing: Bool { source != nil }
    /// True only while this stage owns the monotonic run clock. Re-fronting a
    /// window must not reset it, and closing retires it with the stage session.
    public var isStageOpen: Bool { clockTask != nil }
    public var isClosingStage: Bool { stageCloseToken != nil }
    public var isPreparingDraft: Bool { phase == .analyzing }

    public var hasUncheckedPreparationBoundaries: Bool {
        preparationResult?.status == .boundaryUnchecked
    }

    public var hasLocalPreparationFallback: Bool {
        if preparationResult?.hasLocalFallback == true { return true }
        return phase == .review && readingBlocks.contains {
            $0.origin == .deterministic && $0.disposition == .unresolved
        }
    }

    public var isFullyLocalPreparationFallback: Bool {
        if let result = preparationResult {
            return result.fallbackBlockCount == result.draft.blocks.count
        }
        return hasLocalPreparationFallback
            && !readingBlocks.isEmpty
            && readingBlocks.allSatisfy { $0.origin == .deterministic }
    }

    public var sourceValidationError: TeleprompterPreparationError? {
        guard let sourceText = document?.sourceText,
              !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        do {
            _ = try TeleprompterSourceImporter.importData(Data(sourceText.utf8))
            return nil
        } catch let error as TeleprompterPreparationError {
            return error
        } catch {
            return .invalidUTF8
        }
    }

    public var unresolvedReviewItemCount: Int {
        reviewItems.filter { !$0.isResolved }.count
    }

    public var canAcceptPendingVersion: Bool {
        unresolvedReviewItemCount == 0 && pendingVersion != nil
    }

    public var preflightConclusion: TeleprompterTimingPolicy.PreflightConclusion {
        TeleprompterTimingPolicy.evaluatePreflight(
            text: effectiveSourceText,
            targetMinutes: targetMinutes,
            pace: pace,
            calibrationFactor: calibrationFactor
        )
    }

    public var effectiveSourceText: String {
        guard let sourceText = document?.sourceText else { return "" }
        if contentSelection.isAllSelected || !contentSelection.hasExclusions {
            return sourceText
        }
        let paragraphs = sourceText.components(separatedBy: "\n\n")
        let selected = paragraphs.enumerated().compactMap { offset, element in
            contentSelection.selectedParagraphIndices.contains(offset) ? element : nil
        }
        return selected.joined(separator: "\n\n")
    }

    public var activeVersion: TeleprompterVersion? {
        if let runningVersion { return runningVersion }
        guard let activeID = document?.activeVersionID else { return nil }
        return versions.first { $0.id == activeID }
    }

    public var currentSegment: TeleprompterSegment? {
        guard let segments = activeVersion?.segments, segments.indices.contains(currentSegmentIndex) else {
            return nil
        }
        return segments[currentSegmentIndex]
    }

    public var progressText: String {
        guard let count = activeVersion?.segments.count, count > 0 else { return "未开始" }
        return "第 \(min(currentSegmentIndex + 1, count)) / \(count) 段"
    }

    public var serviceReadiness: (@MainActor () async -> ServiceReadiness)?
    public var audioSourceFactory: @MainActor () -> AudioChunkSource = { MicrophoneCapture() }
    /// Transport injection keeps the production lifecycle testable without a
    /// socket, model, microphone, or audio file.
    public var realtimeClientFactory: (@MainActor (Int, String?) -> any TeleprompterRealtimeClientProtocol)?
    /// MapReduce preparation is injected so the session never knows provider,
    /// endpoint, credential, or response transport details.
    public var preparationClient: TeleprompterPreparationClient?
    public var aiClient: TeleprompterAIClient?
    public private(set) var preparationProgress: TeleprompterPreparationProgress?
    public private(set) var preparationResult: TeleprompterPreparationResult?
    public private(set) var isTightening = false
    public private(set) var isAnnotating = false

    private let coordinator: SessionCoordinator
    private let v2Store: TeleprompterV2Store
    private let port: Int
    private let apiKey: String?
    private var source: AudioChunkSource?
    private var client: (any TeleprompterRealtimeClientProtocol)?
    private var pump: Task<Void, Never>?
    private var followController = TeleprompterFollowController()
    private let followAdapter = TeleprompterRealtimeFollowAdapter()
    private var isStoppingIntentionally = false
    private var runningVersion: TeleprompterVersion?
    private var voiceLifecycle = TeleprompterVoiceAssistLifecycle()
    private var voiceStopTask: Task<Void, Never>?
    private var lastVoiceStopFailure: String?
    private var draftGeneration = UUID()
    private var preparationTask: Task<TeleprompterPreparationResult, Error>?
    private var tightenTask: Task<TeleprompterPreparationResult, Error>?
    private var annotationTask: Task<TeleprompterAnalysis, Error>?
    private var draftSaveTask: Task<Void, Never>?
    private var clockLastInstant: ContinuousClock.Instant?
    private var clockAdaptiveFactor = 1.0
    private var clockSamples: [Double] = []
    private var clockSampleStartSegment = 0
    private var clockSampleStartElapsed = 0.0
    private var savedRunState: TeleprompterRunState?
    private var importedSource: TeleprompterImportedSource?

    public init(
        coordinator: SessionCoordinator,
        v2Store: TeleprompterV2Store,
        port: Int = 8201,
        apiKey: String? = nil,
        audioSourceFactory: (@MainActor () -> AudioChunkSource)? = nil
    ) {
        self.coordinator = coordinator
        self.v2Store = v2Store
        self.port = port
        self.apiKey = apiKey
        if let audioSourceFactory {
            self.audioSourceFactory = audioSourceFactory
        }
    }

    public func listDocuments() throws -> [TeleprompterDocument] {
        let items = try v2Store.listDocuments()
        unavailableDocuments = items.filter { !$0.isAvailable }
        return items.compactMap { item in
            guard item.isAvailable else { return nil }
            return try? legacyDocument(from: v2Store.load(documentID: item.id))
        }
    }

    public func load(documentID: String) throws {
        guard canEdit else { return }
        invalidateAnalysis()
        applyV2Bundle(try v2Store.load(documentID: documentID))
    }

    public func createDocument(title: String, sourceText: String) {
        guard canEdit else { return }
        invalidateAnalysis()
        savedRunState = nil
        let now = Date()
        document = TeleprompterDocument(
            id: UUID().uuidString,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名稿子" : title,
            sourceText: sourceText,
            createdAt: now,
            updatedAt: now
        )
        importedSource = nil
        contentSelection = TeleprompterContentSelection()
        versions = []
        readingBlocks = []
        reviewItems = []
        pendingVersion = nil
        currentSegmentIndex = 0
        readingOffset = 0
        phase = .draft
        blocked = nil
        lastFailure = nil
        persistDraft()
    }

    /// Validates pasted/drop text through the same strict importer as files.
    /// Blank documents remain available through `createDocument` for the empty editor state.
    public func createDocumentValidated(title: String, sourceText: String) throws {
        let imported = try TeleprompterSourceImporter.importData(Data(sourceText.utf8))
        createDocument(title: title, importedSource: imported)
    }

    public func createDocument(title: String, importedSource: TeleprompterImportedSource) {
        guard canEdit else { return }
        invalidateAnalysis()
        savedRunState = nil
        let now = Date()
        document = TeleprompterDocument(
            id: UUID().uuidString,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名稿子" : title,
            sourceText: importedSource.sourceText,
            createdAt: now,
            updatedAt: now
        )
        self.importedSource = importedSource
        contentSelection = TeleprompterContentSelection()
        versions = []
        pendingVersion = nil
        readingBlocks = []
        reviewItems = []
        currentSegmentIndex = 0
        readingOffset = 0
        phase = .draft
        blocked = nil
        lastFailure = nil
        persistDraft()
    }

    public func deleteDocument(documentID: String) throws {
        guard canEdit else { return }
        guard phase != .following, phase != .paused, phase != .uncertain else { return }
        try v2Store.delete(documentID: documentID)
        if document?.id == documentID {
            let remaining = try listDocuments()
            if let first = remaining.first {
                try load(documentID: first.id)
            } else {
                document = nil
                versions = []
                pendingVersion = nil
                currentSegmentIndex = 0
                phase = .draft
                blocked = nil
            }
        }
    }

    public func duplicateDocument(documentID: String) throws -> TeleprompterDocument {
        guard canEdit else { throw TeleprompterTextError.invalidAnalysis }
        guard phase != .following, phase != .paused, phase != .uncertain else {
            throw TeleprompterTextError.emptySource
        }
        let newBundle = try v2Store.duplicate(documentID: documentID)
        try load(documentID: newBundle.document.id)
        return try legacyDocument(from: newBundle)
    }

    public func exportMarkdown() -> String? {
        guard let document else { return nil }
        do {
            let bundle = try v2Store.load(documentID: document.id)
            let body = try v2Store.exportReading(bundle)
            return "# \(document.title)\n\n\(body)"
        } catch {
            return nil
        }
    }

    public func exportSourceData() -> Data? {
        guard let document else { return nil }
        return try? v2Store.exportSource(v2Store.load(documentID: document.id))
    }

    public func updateTitle(_ title: String) {
        guard canEdit else { return }
        guard phase != .following, phase != .paused, phase != .uncertain else { return }
        document?.title = title
        document?.updatedAt = Date()
        scheduleDraftSave()
    }

    public func updateSourceText(_ sourceText: String) {
        guard canEdit else { return }
        invalidateAnalysis()
        guard phase != .following, phase != .paused, phase != .uncertain else { return }
        document?.sourceText = sourceText
        document?.updatedAt = Date()
        importedSource = nil
        contentSelection = TeleprompterContentSelection()
        pendingVersion = nil
        phase = .draft
        scheduleDraftSave()
    }

    public func useDeterministicFallback() throws {
        guard canEdit else { return }
        invalidateAnalysis()
        savedRunState = nil
        guard var document else { throw TeleprompterTextError.emptySource }
        let imported = try TeleprompterSourceImporter.importData(Data(document.sourceText.utf8))
        let sourceUnits = try TeleprompterSourceUnitBuilder().build(imported)
        let selectedUnitIDs = try selectedSourceUnitIDs(
            sourceUnits: sourceUnits,
            sourceText: imported.sourceText
        )
        let segments = try deterministicSegments(
            sourceUnits: sourceUnits,
            selectedUnitIDs: selectedUnitIDs,
            sourceText: imported.sourceText
        )
        self.readingBlocks = segments.map { seg in
            TeleprompterReadingBlock(
                id: seg.id,
                ordinal: seg.ordinal,
                sourceRange: seg.sourceRange,
                text: seg.text,
                rawSourceText: text(in: seg.sourceRange, source: imported.sourceText) ?? seg.text,
                disposition: .speak,
                origin: .deterministic
            )
        }
        self.reviewItems = []
        let version = TeleprompterVersion(
            id: UUID().uuidString,
            documentID: document.id,
            sourceText: effectiveSourceText,
            segments: segments,
            analysisSource: .deterministic
        )
        versions.append(version)
        document.activeVersionID = version.id
        document.updatedAt = Date()
        self.document = document
        pendingVersion = nil
        currentSegmentIndex = 0
        followController = TeleprompterFollowController()
        syncFollowState()
        phase = .ready
        blocked = nil
        try saveBundle()
    }

    public func analyzeDraft() async {
        guard canEdit, phase != .analyzing else { return }
        guard let document else {
            blocked = .aiUnavailable("请先创建一份稿子。")
            return
        }
        guard let preparationClient else {
            blocked = .aiUnavailable("AI 整理服务不可用；你可以直接按原文分段。")
            return
        }
        await prepareDraft(document: document, preparationClient: preparationClient)
    }

    private func prepareDraft(
        document: TeleprompterDocument,
        preparationClient: TeleprompterPreparationClient
    ) async {
        phase = .analyzing
        preparationProgress = nil
        preparationResult = nil
        let generation = draftGeneration
        blocked = nil

        do {
            let source = try TeleprompterSourceImporter.importData(Data(document.sourceText.utf8))
            let sourceUnits = try TeleprompterSourceUnitBuilder().build(source)
            let selectedUnitIDs = try selectedSourceUnitIDs(sourceUnits: sourceUnits, sourceText: source.sourceText)
            let estimates = sourceUnits.map { unit in
                TeleprompterDurationEstimator.estimate(
                    unit.rawText,
                    pace: pace,
                    calibrationFactor: calibrationFactor
                ).pointSeconds
            }
            let timingPlan = try TeleprompterTimingPlanner.plan(
                sourceUnits: sourceUnits,
                estimates: estimates,
                targetMinutes: targetMinutes,
                selectedUnitIDs: selectedUnitIDs
            )
            let input = TeleprompterPreparationInput(
                source: source,
                sourceUnits: sourceUnits,
                timingPlan: timingPlan,
                pace: pace,
                calibrationFactor: calibrationFactor,
                selectedUnitIDs: selectedUnitIDs
            )
            let progressSink: TeleprompterPreparationPipeline.ProgressHandler = { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.draftGeneration == generation else { return }
                    self.preparationProgress = progress
                }
            }
            let task = Task.detached(priority: .userInitiated) {
                try await preparationClient.prepare(input, onProgress: progressSink)
            }
            preparationTask = task
            let result = try await task.value
            guard generation == draftGeneration,
                  self.document?.id == document.id,
                  canEdit else { return }
            preparationTask = nil
            preparationResult = result
            preparationProgress = .init(phase: .finalizing, completed: 1, total: 1)
            applyPreparationResult(result, sourceText: effectiveSourceText, document: document)
            persistDraft()
        } catch is CancellationError {
            guard generation == draftGeneration else { return }
            preparationTask = nil
            preparationProgress = nil
            phase = activeVersion == nil ? .draft : .ready
        } catch {
            guard generation == draftGeneration,
                  self.document?.id == document.id,
                  canEdit else { return }
            preparationTask = nil
            preparationProgress = nil
            blocked = .aiUnavailable(Self.aiFailureMessage(for: error))
            phase = .draft
        }
    }

    private func applyPreparationResult(
        _ result: TeleprompterPreparationResult,
        sourceText: String,
        document: TeleprompterDocument
    ) {
        readingBlocks = result.draft.blocks
        reviewItems = []
        for block in readingBlocks where block.disposition == .unresolved || !block.reviewIssues.isEmpty {
            let issue = block.reviewIssues.first ?? .uncertainMeaning
            reviewItems.append(
                TeleprompterReviewItem(
                    blockID: block.id,
                    issue: issue,
                    suggestedText: block.text,
                    sourceSnippet: block.rawSourceText
                )
            )
        }
        for boundary in result.boundaries where !boundary.reviewBlockIDs.isEmpty {
            for blockID in boundary.reviewBlockIDs
                where !reviewItems.contains(where: { $0.blockID == blockID }) {
                let block = readingBlocks.first { $0.id == blockID }
                reviewItems.append(
                    TeleprompterReviewItem(
                        blockID: blockID,
                        issue: .uncertainMeaning,
                        suggestedText: block?.text ?? "",
                        sourceSnippet: block?.rawSourceText ?? ""
                    )
                )
            }
        }
        let segments = localSegments(from: readingBlocks)
        pendingVersion = TeleprompterVersion(
            id: UUID().uuidString,
            documentID: document.id,
            sourceText: sourceText,
            segments: segments,
            analysisSource: result.fallbackBlockCount == result.draft.blocks.count ? .deterministic : .ai
        )
        phase = .review
    }

    public func acceptPendingVersion() throws {
        guard canEdit, let pendingVersion, var document,
              pendingVersion.documentID == document.id else {
            throw TeleprompterTextError.invalidAnalysis
        }
        guard canAcceptPendingVersion else {
            throw TeleprompterTextError.invalidAnalysis
        }
        versions.append(pendingVersion)
        savedRunState = nil
        document.activeVersionID = pendingVersion.id
        document.updatedAt = Date()
        self.document = document
        self.pendingVersion = nil
        currentSegmentIndex = 0
        followController = TeleprompterFollowController()
        syncFollowState()
        phase = .ready
        blocked = nil
        cancelScheduledDraftSave()
        try saveBundle()
    }

    public func discardPendingVersion() {
        guard canEdit else { return }
        invalidateAnalysis()
        pendingVersion = nil
        reviewItems = []
        phase = activeVersion == nil ? .draft : .ready
    }

    // MARK: - 目标时长、节奏与校准

    public func setTargetMinutes(_ minutes: Int) {
        targetMinutes = min(
            max(minutes, TeleprompterTimingPolicy.minimumTargetMinutes),
            TeleprompterTimingPolicy.maximumTargetMinutes
        )
        runClock.targetSeconds = Double(targetMinutes * 60)
        recalculateCurrentDraftBudget()
        scheduleDraftSave()
    }

    /// 根据当前原稿可靠估算得出的建议目标分钟数（预填 max(1, ceil(D/60))）。
    public var suggestedTargetMinutes: Int? {
        guard let text = document?.sourceText, !text.isEmpty else { return nil }
        let metrics = TeleprompterTimingPolicy.countMetrics(in: text)
        guard metrics.totalUnits > 0 else { return nil }
        let estimate = TeleprompterTimingPolicy.estimateDuration(
            metrics: metrics,
            pace: pace,
            calibrationFactor: calibrationFactor
        )
        guard let duration = estimate.pointSeconds, duration > 0 else { return nil }
        return max(1, Int(ceil(duration / 60.0)))
    }

    public func setPace(_ pace: TeleprompterPace) {
        self.pace = pace
        recalculateCurrentDraftBudget()
        scheduleDraftSave()
    }

    public func applyTrialCalibration(k: Double) {
        calibrationFactor = min(max(k, TeleprompterTimingPolicy.minimumCalibrationFactor), TeleprompterTimingPolicy.maximumCalibrationFactor)
        recalculateCurrentDraftBudget()
        scheduleDraftSave()
    }

    public func updateContentSelection(_ selection: TeleprompterContentSelection) {
        self.contentSelection = selection
        if pendingVersion != nil || !readingBlocks.isEmpty {
            invalidateAnalysis()
            pendingVersion = nil
            reviewItems = []
            readingBlocks = []
            phase = activeVersion == nil ? .draft : .ready
        }
        scheduleDraftSave()
    }

    // MARK: - 待确认事项处理

    public func resolveReviewItem(id: String, action: TeleprompterReviewAction, customText: String? = nil) {
        guard let index = reviewItems.firstIndex(where: { $0.id == id }) else { return }
        reviewItems[index].resolvedAction = action
        let item = reviewItems[index]
        if let blockIndex = readingBlocks.firstIndex(where: { $0.id == item.blockID }) {
            switch action {
            case .accept:
                readingBlocks[blockIndex].text = item.suggestedText
                readingBlocks[blockIndex].disposition = .speak
            case .edit:
                if let customText, !customText.isEmpty {
                    readingBlocks[blockIndex].text = customText
                }
                readingBlocks[blockIndex].disposition = .speak
                readingBlocks[blockIndex].origin = .user
            case .keepSource:
                readingBlocks[blockIndex].text = readingBlocks[blockIndex].rawSourceText
                readingBlocks[blockIndex].disposition = .speak
            case .convertToCue:
                readingBlocks[blockIndex].disposition = .cue
            case .skip:
                readingBlocks[blockIndex].disposition = .skip
            }
        }
        syncPendingVersionFromBlocks()
        scheduleDraftSave()
    }

    // MARK: - 再精简表达 (Tighten)

    public var canTighten: Bool {
        preparationClient != nil
            && phase == .review
            && !isTightening
            && readingBlocks.contains { $0.disposition == .speak && $0.origin == .ai }
    }

    public func tightenReadingBlocks() async -> String? {
        guard canTighten else {
            return "没有符合条件的 AI 整理段落可供自动精简，请手动编辑文本。"
        }
        guard let preparationClient, let document else {
            return "AI 整理服务不可用，请手动编辑文本。"
        }

        let candidateIndices = readingBlocks.indices.filter {
            readingBlocks[$0].disposition == .speak && readingBlocks[$0].origin == .ai
        }
        guard !candidateIndices.isEmpty else {
            return "没有符合条件的 AI 整理段落可供自动精简，请手动编辑文本。"
        }

        isTightening = true
        let generation = draftGeneration
        preparationProgress = nil
        defer {
            isTightening = false
            tightenTask = nil
            preparationProgress = nil
        }

        do {
            let source = try TeleprompterSourceImporter.importData(Data(document.sourceText.utf8))
            let sourceUnits = try TeleprompterSourceUnitBuilder().build(source)
            let sourceUnitIDs = try selectedSourceUnitIDs(sourceUnits: sourceUnits, sourceText: source.sourceText)
            let estimates = sourceUnits.map { unit in
                TeleprompterDurationEstimator.estimate(
                    unit.rawText,
                    pace: pace,
                    calibrationFactor: calibrationFactor
                ).pointSeconds
            }
            let timingPlan = try TeleprompterTimingPlanner.plan(
                sourceUnits: sourceUnits,
                estimates: estimates,
                targetMinutes: targetMinutes,
                selectedUnitIDs: sourceUnitIDs
            )
            let candidates = candidateIndices.compactMap { index -> (Int, [Int])? in
                let block = readingBlocks[index]
                let ids = sourceUnits.filter { unit in
                    unit.sourceRange.start < block.sourceRange.end
                        && block.sourceRange.start < unit.sourceRange.end
                }.map(\.id).filter(sourceUnitIDs.contains)
                guard !ids.isEmpty else { return nil }
                return (index, ids)
            }
            let rankedCandidates = candidates.sorted { lhs, rhs in
                let leftEstimate = TeleprompterDurationEstimator.estimate(
                    readingBlocks[lhs.0].text,
                    pace: pace,
                    calibrationFactor: calibrationFactor
                ).pointSeconds ?? 0
                let rightEstimate = TeleprompterDurationEstimator.estimate(
                    readingBlocks[rhs.0].text,
                    pace: pace,
                    calibrationFactor: calibrationFactor
                ).pointSeconds ?? 0
                let leftExcess = max(0, leftEstimate - readingBlocks[lhs.0].budgetSeconds)
                let rightExcess = max(0, rightEstimate - readingBlocks[rhs.0].budgetSeconds)
                if leftExcess != rightExcess { return leftExcess > rightExcess }
                return readingBlocks[lhs.0].ordinal < readingBlocks[rhs.0].ordinal
            }
            let selectedCandidates = Array(rankedCandidates.prefix(3))
            let selectedIDs = Set(selectedCandidates.flatMap(\.1)).intersection(sourceUnitIDs)
            guard !selectedIDs.isEmpty else {
                return "当前 AI 段落没有可用来源坐标，请手动编辑文本。"
            }
            let currentBlocks = selectedCandidates.map { index, ids in
                TeleprompterMapCurrentBlock(
                    startUnit: ids.first!,
                    endUnit: ids.last! + 1,
                    text: readingBlocks[index].text
                )
            }
            let input = TeleprompterPreparationInput(
                source: source,
                sourceUnits: sourceUnits,
                timingPlan: timingPlan,
                pace: pace,
                calibrationFactor: calibrationFactor,
                operation: .tighten,
                selectedUnitIDs: selectedIDs,
                currentBlocks: currentBlocks
            )
            let progressSink: TeleprompterPreparationPipeline.ProgressHandler = { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.draftGeneration == generation else { return }
                    self.preparationProgress = progress
                }
            }
            let task = Task.detached(priority: .userInitiated) {
                try await preparationClient.prepare(input, onProgress: progressSink)
            }
            tightenTask = task
            let result = try await task.value
            guard generation == draftGeneration, self.document?.id == document.id else { return nil }

            var replacements: [Int: [String]] = [:]
            for resultBlock in result.draft.blocks where resultBlock.disposition == .speak {
                    let matching = selectedCandidates.filter { _, ids in
                    let range = sourceUnits.filter { ids.contains($0.id) }
                        .map(\.sourceRange)
                    guard let first = range.map(\.start).min(), let last = range.map(\.end).max() else {
                        return false
                    }
                    return first < resultBlock.sourceRange.end && resultBlock.sourceRange.start < last
                }.map(\.0)
                // A candidate spanning two existing blocks is ambiguous; do not
                // apply a model merge across an explicit user-facing boundary.
                guard matching.count == 1, let index = matching.first else { continue }
                replacements[index, default: []].append(resultBlock.text)
            }
            for (index, texts) in replacements {
                let candidate = texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !candidate.isEmpty else { continue }
                let oldEstimate = TeleprompterDurationEstimator.estimate(
                    readingBlocks[index].text,
                    pace: pace,
                    calibrationFactor: calibrationFactor
                ).pointSeconds
                let newEstimate = TeleprompterDurationEstimator.estimate(
                    candidate,
                    pace: pace,
                    calibrationFactor: calibrationFactor
                ).pointSeconds
                guard let oldEstimate, let newEstimate, newEstimate < oldEstimate else {
                    continue
                }
                readingBlocks[index].text = candidate
            }
            syncPendingVersionFromBlocks()
            scheduleDraftSave()
            return replacements.isEmpty ? "这次没有找到安全的精简改动。" : nil
        } catch is CancellationError {
            return "已取消精简。"
        } catch {
            return Self.aiFailureMessage(for: error)
        }
    }

    // MARK: - 来源组/块级编辑操作

    public func updateBlockText(id: String, text: String) {
        guard let index = readingBlocks.firstIndex(where: { $0.id == id }) else { return }
        readingBlocks[index].text = text
        readingBlocks[index].origin = .user
        syncPendingVersionFromBlocks()
        scheduleDraftSave()
    }

    public func mergeBlock(at index: Int) {
        guard index >= 0, index + 1 < readingBlocks.count else { return }
        var current = readingBlocks[index]
        let next = readingBlocks[index + 1]
        current.text = current.text + "\n" + next.text
        current.rawSourceText = current.rawSourceText + "\n" + next.rawSourceText
        current.sourceRange = TeleprompterSourceRange(start: current.sourceRange.start, end: next.sourceRange.end)
        current.reviewIssues.append(contentsOf: next.reviewIssues)
        current.budgetSeconds += next.budgetSeconds
        current.origin = .user
        readingBlocks.remove(at: index + 1)
        readingBlocks[index] = current
        for i in index..<readingBlocks.count {
            readingBlocks[i].ordinal = i
        }
        syncPendingVersionFromBlocks()
        scheduleDraftSave()
    }

    public func splitBlock(at index: Int, splitPoint: Int? = nil) {
        guard index >= 0, index < readingBlocks.count else { return }
        let current = readingBlocks[index]
        let text = current.text
        guard text.count > 4 else { return }
        let point = splitPoint ?? (text.count / 2)
        let firstText = String(text.prefix(point)).trimmingCharacters(in: .whitespacesAndNewlines)
        let secondText = String(text.dropFirst(point)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !firstText.isEmpty, !secondText.isEmpty else { return }

        let block1 = TeleprompterReadingBlock(
            id: current.id,
            ordinal: index,
            sourceRange: current.sourceRange,
            text: firstText,
            rawSourceText: current.rawSourceText,
            disposition: current.disposition,
            origin: .user,
            budgetSeconds: current.budgetSeconds / 2
        )
        let block2 = TeleprompterReadingBlock(
            id: UUID().uuidString,
            ordinal: index + 1,
            sourceRange: current.sourceRange,
            text: secondText,
            rawSourceText: current.rawSourceText,
            disposition: current.disposition,
            origin: .user,
            budgetSeconds: current.budgetSeconds / 2
        )
        readingBlocks[index] = block1
        readingBlocks.insert(block2, at: index + 1)
        for i in (index + 1)..<readingBlocks.count {
            readingBlocks[i].ordinal = i
        }
        syncPendingVersionFromBlocks()
        scheduleDraftSave()
    }

    public func insertBlock(after index: Int) {
        let newOrdinal = index + 1
        let newBlock = TeleprompterReadingBlock(
            id: UUID().uuidString,
            ordinal: newOrdinal,
            sourceRange: TeleprompterSourceRange(start: 0, end: 0),
            text: "",
            rawSourceText: "",
            disposition: .speak,
            origin: .user,
            budgetSeconds: 0
        )
        if newOrdinal <= readingBlocks.count {
            readingBlocks.insert(newBlock, at: newOrdinal)
        } else {
            readingBlocks.append(newBlock)
        }
        for i in newOrdinal..<readingBlocks.count {
            readingBlocks[i].ordinal = i
        }
        syncPendingVersionFromBlocks()
        scheduleDraftSave()
    }

    private func syncPendingVersionFromBlocks() {
        guard let document else { return }
        let segments = localSegments(from: readingBlocks)
        pendingVersion = TeleprompterVersion(
            id: pendingVersion?.id ?? UUID().uuidString,
            documentID: document.id,
            sourceText: effectiveSourceText,
            segments: segments,
            analysisSource: .user,
            createdAt: pendingVersion?.createdAt ?? .now
        )
    }

    private func recalculateCurrentDraftBudget() {
        guard !readingBlocks.isEmpty, let document else { return }
        do {
            let source = try TeleprompterSourceImporter.importData(Data(document.sourceText.utf8))
            let sourceUnits = try TeleprompterSourceUnitBuilder().build(source)
            let selectedIDs = try selectedSourceUnitIDs(sourceUnits: sourceUnits, sourceText: source.sourceText)
            let estimates = sourceUnits.map { unit in
                TeleprompterDurationEstimator.estimate(
                    unit.rawText,
                    pace: pace,
                    calibrationFactor: calibrationFactor
                ).pointSeconds
            }
            let plan = try TeleprompterTimingPlanner.plan(
                sourceUnits: sourceUnits,
                estimates: estimates,
                targetMinutes: targetMinutes,
                selectedUnitIDs: selectedIDs
            )
            for index in readingBlocks.indices {
                let ids = sourceUnits.filter { unit in
                    unit.sourceRange.start < readingBlocks[index].sourceRange.end
                        && readingBlocks[index].sourceRange.start < unit.sourceRange.end
                }.map(\.id)
                readingBlocks[index].budgetSeconds = plan.budget(for: ids)
            }
        } catch {
            // Invalid editor text is surfaced by sourceValidationError; keep the
            // previous in-memory allocation until the user fixes the source.
        }
    }

    private func scheduleDraftSave() {
        guard document != nil else { return }
        draftSaveTask?.cancel()
        draftSaveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard let self else { return }
            self.persistDraft()
            self.draftSaveTask = nil
        }
    }

    private func cancelScheduledDraftSave() {
        draftSaveTask?.cancel()
        draftSaveTask = nil
    }

    private func localSegments(from blocks: [TeleprompterReadingBlock]) -> [TeleprompterSegment] {
        var segments: [TeleprompterSegment] = []
        for block in blocks where block.disposition == .speak {
            let local = (try? TeleprompterSegmenter.segment(sourceText: block.text)) ?? []
            if local.isEmpty {
                segments.append(
                    TeleprompterSegment(
                        id: "\(block.id):0",
                        ordinal: segments.count,
                        sourceRange: block.sourceRange,
                        text: block.text,
                        pauseHint: .medium
                    )
                )
                continue
            }
            for (index, segment) in local.enumerated() {
                segments.append(
                    TeleprompterSegment(
                        id: "\(block.id):\(index)",
                        ordinal: segments.count,
                        sourceRange: block.sourceRange,
                        text: segment.text,
                        keywords: segment.keywords,
                        matchPhrases: segment.matchPhrases,
                        pauseHint: segment.pauseHint
                    )
                )
            }
        }
        return segments
    }

    private func deterministicSegments(
        sourceUnits: [TeleprompterSourceUnit],
        selectedUnitIDs: Set<Int>,
        sourceText: String
    ) throws -> [TeleprompterSegment] {
        let selectedUnits = sourceUnits.filter { selectedUnitIDs.contains($0.id) }
        guard !selectedUnits.isEmpty else { throw TeleprompterPreparationError.invalidTimingPlan }

        var runs: [[TeleprompterSourceUnit]] = []
        for unit in selectedUnits {
            if let lastIndex = runs.indices.last,
               runs[lastIndex].last?.id == unit.id - 1 {
                runs[lastIndex].append(unit)
            } else {
                runs.append([unit])
            }
        }

        var result: [TeleprompterSegment] = []
        for run in runs {
            let runText = run.map(\.rawText).joined()
            let localSegments = try TeleprompterSegmenter.segment(sourceText: runText)
            guard let baseOffset = run.first?.sourceRange.start else {
                throw TeleprompterPreparationError.invalidSourceUnits
            }
            for local in localSegments {
                let globalRange = TeleprompterSourceRange(
                    start: baseOffset + local.sourceRange.start,
                    end: baseOffset + local.sourceRange.end
                )
                result.append(
                    TeleprompterSegment(
                        id: "fallback-\(result.count)",
                        ordinal: result.count,
                        sourceRange: globalRange,
                        text: local.text,
                        keywords: local.keywords,
                        matchPhrases: local.matchPhrases,
                        pauseHint: local.pauseHint
                    )
                )
            }
        }
        guard !result.isEmpty,
              result.allSatisfy({ $0.sourceRange.isValid(in: sourceText) }) else {
            throw TeleprompterPreparationError.emptySource
        }
        return result
    }

    private func selectedSourceUnitIDs(
        sourceUnits: [TeleprompterSourceUnit],
        sourceText: String
    ) throws -> Set<Int> {
        let allIDs = Set(sourceUnits.map(\.id))
        guard contentSelection.hasExclusions else { return allIDs }

        let paragraphRanges = paragraphRanges(in: sourceText)
        let selectedRanges = paragraphRanges.enumerated().compactMap { index, range in
            contentSelection.selectedParagraphIndices.contains(index) ? range : nil
        }
        guard !selectedRanges.isEmpty else {
            throw TeleprompterPreparationError.invalidTimingPlan
        }

        let selectedIDs = Set(sourceUnits.compactMap { unit in
            unitContainsOnlySelectedContent(unit, sourceText: sourceText, selectedRanges: selectedRanges)
                ? unit.id
                : nil
        })
        guard !selectedIDs.isEmpty else {
            throw TeleprompterPreparationError.invalidTimingPlan
        }
        return selectedIDs
    }

    public func annotateActiveVersion() async -> String? {
        guard !isAnnotating else { return "朗读提示正在生成。" }
        guard let aiClient, let active = activeVersion, let document else {
            return "当前没有可添加朗读提示的已确认稿件。"
        }
        let readingText = active.segments.map(\.text).joined(separator: "\n\n")
        guard !readingText.isEmpty else { return "当前稿件没有可标注的正文。" }

        isAnnotating = true
        let generation = draftGeneration
        defer {
            isAnnotating = false
            annotationTask = nil
        }

        do {
            let task = Task {
                try await aiClient.analyze(
                    TeleprompterAnalysisRequest(
                        sourceText: readingText,
                        language: "跟随原稿",
                        style: "只添加关键词和停顿提示，不改写正文"
                    )
                )
            }
            annotationTask = task
            let analysis = try await task.value
            guard generation == draftGeneration, self.document?.id == document.id else {
                return "朗读提示已取消。"
            }

            var readingRanges: [TeleprompterSourceRange] = []
            var offset = 0
            for (index, segment) in active.segments.enumerated() {
                readingRanges.append(.init(start: offset, end: offset + segment.text.utf16.count))
                offset += segment.text.utf16.count
                if index < active.segments.count - 1 { offset += 2 }
            }

            var updatedSegments = active.segments
            var matchedCount = 0
            for index in updatedSegments.indices {
                let range = readingRanges[index]
                guard let annotation = analysis.segments.max(by: { left, right in
                    overlap(left.sourceRange, range) < overlap(right.sourceRange, range)
                }), overlap(annotation.sourceRange, range) > 0 else { continue }
                updatedSegments[index].keywords = annotation.keywords
                updatedSegments[index].matchPhrases = annotation.matchPhrases
                updatedSegments[index].pauseHint = annotation.pauseHint
                matchedCount += 1
            }
            guard matchedCount > 0 else { return "AI 没有返回可应用的朗读提示。" }

            guard let versionIndex = versions.firstIndex(where: { $0.id == active.id }) else {
                return "找不到当前朗读版本。"
            }
            versions[versionIndex] = TeleprompterVersion(
                id: active.id,
                documentID: active.documentID,
                sourceText: active.sourceText,
                segments: updatedSegments,
                analysisSource: active.analysisSource,
                createdAt: active.createdAt
            )
            self.document?.updatedAt = Date()
            try saveBundle()
            return nil
        } catch is CancellationError {
            return "朗读提示已取消。"
        } catch {
            return Self.aiFailureMessage(for: error)
        }
    }

    private func overlap(_ lhs: TeleprompterSourceRange, _ rhs: TeleprompterSourceRange) -> Int {
        max(0, min(lhs.end, rhs.end) - max(lhs.start, rhs.start))
    }

    // MARK: - 舞台单调运行计时器

    private func startRunClock() {
        clockTask?.cancel()
        runClock.elapsedSeconds = 0
        runClock.targetSeconds = Double(targetMinutes * 60)
        runClock.estimatedRemainingSeconds = remainingTextEstimate()
        runClock.isPaused = false
        clockLastInstant = ContinuousClock.now
        resetAdaptiveClockSamples()
        clockSampleStartSegment = currentSegmentIndex
        clockSampleStartElapsed = 0
        clockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
                guard let self else { return }
                self.advanceRunClock()
            }
        }
    }

    private func stopRunClock() {
        clockTask?.cancel()
        clockTask = nil
        clockLastInstant = nil
        runClock.isPaused = true
    }

    private func pauseRunClock() {
        advanceRunClock()
        runClock.isPaused = true
        clockLastInstant = nil
        resetAdaptiveClockSamples()
    }

    private func resumeRunClock() {
        runClock.isPaused = false
        clockLastInstant = ContinuousClock.now
        resetAdaptiveClockSamples()
    }

    private func advanceRunClock() {
        guard !runClock.isPaused, let last = clockLastInstant else { return }
        let now = ContinuousClock.now
        let duration = last.duration(to: now)
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
        guard seconds.isFinite, seconds >= 0 else {
            clockLastInstant = now
            return
        }
        runClock.elapsedSeconds += seconds
        clockLastInstant = now
        runClock.estimatedRemainingSeconds = remainingTextEstimate()
    }

    private func resetAdaptiveClockSamples() {
        clockSamples.removeAll(keepingCapacity: true)
        clockAdaptiveFactor = 1.0
        clockSampleStartSegment = currentSegmentIndex
        clockSampleStartElapsed = runClock.elapsedSeconds
    }

    private func remainingTextEstimate() -> TimeInterval {
        guard let version = activeVersion, !version.segments.isEmpty else { return 0 }
        var remaining = ""
        for index in version.segments.indices where index >= currentSegmentIndex {
            var text = version.segments[index].text
            if index == currentSegmentIndex,
               readingOffset > 0,
               let range = Range(
                NSRange(location: min(readingOffset, text.utf16.count), length: max(0, text.utf16.count - readingOffset)),
                in: text
               ) {
                text = String(text[range])
            }
            if !text.isEmpty {
                if !remaining.isEmpty { remaining += "\n\n" }
                remaining += text
            }
        }
        guard !remaining.isEmpty else { return 0 }
        let estimate = TeleprompterDurationEstimator.estimate(
            remaining,
            pace: pace,
            calibrationFactor: calibrationFactor
        )
        let base = estimate.pointSeconds ?? estimate.knownPartSeconds
        return max(0, base * clockAdaptiveFactor)
    }

    public func updatePendingSegment(id: String, text: String) {
        guard canEdit, let pendingVersion,
              let index = pendingVersion.segments.firstIndex(where: { $0.id == id }) else { return }
        var segments = pendingVersion.segments
        segments[index].text = text
        segments[index].keywords = []
        segments[index].matchPhrases = []
        self.pendingVersion = TeleprompterVersion(
            id: pendingVersion.id,
            documentID: pendingVersion.documentID,
            sourceText: pendingVersion.sourceText,
            segments: segments,
            analysisSource: .user,
            createdAt: pendingVersion.createdAt
        )
    }

    /// Opens the reading surface without touching microphone or ASR state.
    /// Existing saved position is preserved; a non-empty draft can use the
    /// deterministic fallback, but an unaccepted AI draft is never adopted.
    public func openForManualReading() throws {
        if isClosingStage {
            throw TeleprompterStageOpenError.closing
        }
        guard canEdit else {
            throw TeleprompterStageOpenError.busy
        }
        if activeVersion == nil || phase == .draft {
            try useDeterministicFallback()
        }
        guard activeVersion != nil else {
            throw TeleprompterTextError.emptySource
        }
        if stageGeneration == nil {
            stageGeneration = UUID()
        }
        followController.enterManual()
        syncFollowState()
        phase = .manual
        blocked = nil
        lastFailure = nil
        if clockTask == nil {
            startRunClock()
        }
        saveProgress()
    }

    /// Idempotent entry for the prepare page and stage window. Re-fronting an
    /// already open stage must not reset position, timer, or voice state.
    public func openForManualReadingIfNeeded() throws {
        guard !isStageOpen else { return }
        try openForManualReading()
    }

    /// Explicitly starts voice assistance at the current reading position.
    public func beginFollowing() async {
        await enableVoiceAssist()
    }

    public func enableVoiceAssist() async {
        guard !isResuming, !isStoppingIntentionally else { return }
        if activeVersion == nil || phase == .draft {
            do { try useDeterministicFallback() }
            catch {
                blocked = .noActiveVersion
                return
            }
        }
        guard activeVersion != nil else {
            blocked = .noActiveVersion
            phase = .manual
            return
        }
        if let occupancy = coordinator.occupancy, occupancy.kind != .teleprompter {
            let reason = BlockReason.occupiedBy(occupancy.kind)
            _ = voiceLifecycle.markUnavailable(reason: reason.title)
            blocked = reason
            phase = .manual
            return
        }
        guard let token = voiceLifecycle.beginStart() else {
            if case .stopFailed = voiceLifecycle.state {
                blocked = .streamFailed("上一次停止未完成，请先重试停止。")
            }
            return
        }
        blocked = nil
        lastFailure = nil
        phase = .preparing
        do {
            try await startVoiceAssistPipeline(generation: token)
            guard voiceLifecycle.isCurrent(token) else { throw CancellationError() }
            guard voiceLifecycle.markFollowing(token: token) else {
                throw CancellationError()
            }
            phase = .following
            if clockTask == nil { startRunClock() }
            saveProgress()
        } catch is CancellationError {
            if voiceLifecycle.isCurrent(token), voiceLifecycle.state == .starting {
                _ = voiceLifecycle.markStartFailed(
                    token: token,
                    reason: "语音跟随已取消。"
                )
            }
            phase = .manual
        } catch {
            let reason = Self.blockReason(for: error)
            blocked = reason
            if voiceLifecycle.isCurrent(token), voiceLifecycle.state == .starting {
                _ = voiceLifecycle.markStartFailed(
                    token: token,
                    reason: reason.title
                )
            }
            phase = .manual
            saveProgress()
        }
    }

    /// Reconciles the explicit request with SessionCoordinator. The coordinator
    /// executes `beginCapture`, so ownership and device release stay on the
    /// existing single path.
    private func startVoiceAssistPipeline(generation: UUID) async throws {
        guard voiceLifecycle.isCurrent(generation) else {
            throw CancellationError()
        }
        await coordinator.requestStart(.teleprompter)
        guard voiceLifecycle.isCurrent(generation) else {
            throw CancellationError()
        }
        guard client != nil, source != nil else {
            throw Blocked(reason: blocked ?? .serviceNotReady("语音跟随没有启动。"))
        }
    }

    /// Coordinator starter. The generation was issued synchronously by the
    /// voice lifecycle before ownership was requested.
    public func beginCapture() async throws {
        guard client == nil,
              voiceLifecycle.state == .starting,
              let activeVersion else {
            throw Blocked(reason: .noActiveVersion)
        }
        let generation = voiceLifecycle.generation
        runningVersion = activeVersion
        invalidateAnalysis()
        phase = .preparing
        blocked = nil
        lastFailure = nil
        do {
            try await startPipeline(generation: generation)
            guard voiceLifecycle.isCurrent(generation) else {
                throw CancellationError()
            }
        } catch {
            guard voiceLifecycle.isCurrent(generation) else { throw error }
            runningVersion = nil
            let reason = Self.blockReason(for: error)
            blocked = reason
            phase = .manual
            throw Blocked(reason: reason)
        }
    }

    public func pauseFollowing() {
        _ = requestVoiceStop(destination: .pausedByUser)
    }

    public func resumeFollowing() async {
        await enableVoiceAssist()
    }

    /// Manual movement is always immediate. A live or starting voice session
    /// loses its generation synchronously, then cleans up without blocking the
    /// new reading position.
    private func beginManualMovement() {
        resetAdaptiveClockSamples()
        if voiceLifecycle.state == .starting || voiceLifecycle.state == .following {
            _ = requestVoiceStop(destination: .pausedByUser)
        }
    }

    private func finishManualMovement() {
        syncFollowState()
        phase = .manual
        saveProgress()
    }

    private func takeOverAndMove(to index: Int) {
        guard let count = activeVersion?.segments.count, count > 0 else { return }
        beginManualMovement()
        followController.manualMove(to: index, segmentCount: count)
        finishManualMovement()
    }

    /// Positions the reader at a visual line while retaining the existing
    /// segment-plus-UTF-16-offset progress model.
    public func moveToReadingPosition(_ position: TeleprompterAligner.Position) {
        guard let segments = activeVersion?.segments, !segments.isEmpty else { return }
        beginManualMovement()
        followController.manualMove(
            to: position,
            segmentCount: segments.count,
            segmentUTF16Lengths: segments.map { $0.text.utf16.count }
        )
        finishManualMovement()
    }

    public func moveToPrevious() {
        takeOverAndMove(to: max(0, currentSegmentIndex - 1))
    }

    public func moveToSegment(_ index: Int) {
        takeOverAndMove(to: index)
    }

    public func restartToBeginning() {
        takeOverAndMove(to: 0)
    }

    public func moveToNext() {
        guard let count = activeVersion?.segments.count, count > 0 else { return }
        takeOverAndMove(to: min(count - 1, currentSegmentIndex + 1))
    }

    /// Scroll gestures stop automatic advancement but never mutate the segment
    /// index on their own.
    public func takeOverForManualScroll() {
        if phase == .manual,
           voiceLifecycle.state != .starting,
           voiceLifecycle.state != .following {
            followController.enterManual()
            syncFollowState()
            return
        }
        guard voiceLifecycle.state == .starting || voiceLifecycle.state == .following else {
            followController.enterManual()
            syncFollowState()
            phase = .manual
            return
        }
        _ = requestVoiceStop(destination: .pausedByUser)
        followController.enterManual()
        syncFollowState()
        phase = .manual
        saveProgress()
    }

    @discardableResult
    private func requestVoiceStop(
        destination: TeleprompterVoiceAssistState
    ) -> Task<Void, Never>? {
        guard let token = voiceLifecycle.beginStop(destination: destination) else {
            return nil
        }
        followController.enterManual()
        syncFollowState()
        phase = .manual
        blocked = nil
        saveProgress()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performVoiceStop(token: token)
        }
        voiceStopTask = task
        return task
    }

    private func performVoiceStop(token: UUID) async {
        guard voiceLifecycle.isCurrent(token) else { return }
        if coordinator.occupancy?.kind == .teleprompter {
            await coordinator.stopCapture(endingWith: .user)
        } else {
            await stopCapture()
        }
        let failure = lastVoiceStopFailure
        let accepted = voiceLifecycle.markStopped(
            token: token,
            failureReason: failure
        )
        guard accepted else { return }
        switch voiceLifecycle.state {
        case .off, .unavailable:
            phase = isStageOpen
                ? .manual
                : (activeVersion == nil ? .draft : .ready)
        case .pausedByUser, .stopFailed, .stopping, .starting, .following:
            phase = .manual
        }
        if let failure {
            blocked = .streamFailed(failure)
        }
        saveProgress()
    }

    public func disableVoiceAssist() async {
        if let task = requestVoiceStop(destination: .off) {
            await task.value
        } else if let task = voiceStopTask {
            await task.value
        }
    }

    public func retryStopVoiceAssist() async {
        guard case .stopFailed = voiceLifecycle.state,
              let destination = voiceLifecycle.pendingStopDestination,
              let task = requestVoiceStop(destination: destination) else {
            return
        }
        await task.value
    }

    public func clearBlocked() {
        blocked = nil
    }

    public func resetFollow() async {
        await enableVoiceAssist()
    }

    /// Starts the close transition synchronously so a window-close delegate can
    /// invalidate the stage before any asynchronous drain begins.
    @discardableResult
    func beginStageClose() -> Bool {
        guard stageCloseToken == nil else { return false }
        guard isStageOpen || voiceLifecycle.state != .off || source != nil || client != nil else {
            return false
        }
        stageCloseToken = UUID()
        stageGeneration = nil
        stopRunClock()
        _ = requestVoiceStop(destination: .off)
        return true
    }

    /// Completes a close started by `beginStageClose()`. Reading remains blocked
    /// during this transition so an old drain cannot retire a newer stage.
    func finishStageClose() async {
        guard let token = stageCloseToken else { return }
        await disableVoiceAssist()
        guard stageCloseToken == token else { return }
        // `stopCapture` always closes the local client/source even when the
        // drain barrier reports a failure. Once cleanup has run and no
        // occupancy remains, a later reopen starts from a clean `off`.
        if source == nil, client == nil, coordinator.occupancy == nil {
            _ = voiceLifecycle.resetToOff()
            blocked = nil
        }
        if stageGeneration == nil {
            phase = activeVersion == nil ? .draft : .ready
        }
        saveProgress()
        stageCloseToken = nil
    }

    /// Closing always stops this stage's resources and keeps the current
    /// reading position. It never presents a completion summary and never
    /// affects resources owned by another capability.
    public func closeStage() async {
        guard beginStageClose() else { return }
        await finishStageClose()
    }

    public func endFollowing() async {
        await closeStage()
    }

    /// SessionCoordinator stopper: stop capture, close ASR, preserve position.
    public func stopCapture() async {
        guard !isStoppingIntentionally else { return }
        isStoppingIntentionally = true
        defer { isStoppingIntentionally = false }
        lastVoiceStopFailure = nil
        source?.stop()
        source = nil
        if let client {
            do {
                try await client.drainAndClear(timeout: .seconds(8))
            } catch {
                lastVoiceStopFailure = error.localizedDescription
                lastFailure = error.localizedDescription
            }
            await client.close()
        }
        client = nil
        pump?.cancel()
        pump = nil
        partialText = nil
        followController.enterManual()
        syncFollowState()
        saveProgress()
        runningVersion = nil
    }

    private func startPipeline(generation: UUID) async throws {
        if let serviceReadiness {
            switch await serviceReadiness() {
            case .ready:
                break
            case .notReady(let message):
                throw Blocked(reason: .serviceNotReady(message))
            }
        }

        guard generation == voiceLifecycle.generation else { throw CancellationError() }

        let client: any TeleprompterRealtimeClientProtocol = realtimeClientFactory?(port, apiKey)
            ?? RealtimeASRClient(
                port: port,
                silenceDurationMilliseconds: 400,
                diarizationEnabled: false,
                apiKey: apiKey,
                partialMode: .snapshot,
                chunkDurationMilliseconds: 500
            )
        do {
            try await client.connect()
        } catch {
            throw Blocked(reason: .serviceNotReady(error.localizedDescription))
        }
        guard generation == voiceLifecycle.generation else {
            await client.close()
            throw CancellationError()
        }

        let source = audioSourceFactory()
        self.source = source
        let stream: AsyncStream<AudioChunk>
        do {
            stream = try await source.start()
        } catch {
            await client.close()
            if generation == voiceLifecycle.generation { self.source = nil }
            throw Blocked(reason: Self.blockReason(for: error))
        }
        guard generation == voiceLifecycle.generation else {
            source.stop()
            await client.close()
            throw CancellationError()
        }

        self.client = client
        followLatencyDiagnostics = TeleprompterLatencyDiagnostics()
        isStoppingIntentionally = false
        partialText = nil
        uncertainty = nil
        hasHeardSpeech = false
        coordinator.sessionDidStartRecording(id: nil)
        followController.resume()
        if clockTask == nil { startRunClock() }
        syncFollowState()
        phase = .following
        startPump(stream: stream, client: client)
    }

    private func startPump(
        stream: AsyncStream<AudioChunk>,
        client: any TeleprompterRealtimeClientProtocol
    ) {
        pump?.cancel()
        let generation = voiceLifecycle.generation
        pump = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    for await chunk in stream {
                        guard let self else { return }
                        await self.upload(chunk, to: client, generation: generation)
                    }
                }
                group.addTask { [weak self] in
                    let events = await client.events()
                    for await envelope in events {
                        guard let self else { return }
                        await self.handle(envelope, generation: generation)
                    }
                }
                await group.waitForAll()
            }
        }
    }

    private func upload(
        _ chunk: AudioChunk,
        to client: any TeleprompterRealtimeClientProtocol,
        generation: UUID
    ) async {
        guard voiceLifecycle.acceptsVoiceEvents(token: generation), !isStoppingIntentionally,
              !isResuming, followController.mode == .following else { return }
        do {
            try await client.append(chunk.pcm)
            if let capturedAt = chunk.capturedAt {
                followLatencyDiagnostics.recordCaptureToSend(
                    milliseconds: Self.milliseconds(capturedAt.duration(to: ContinuousClock().now))
                )
            }
        } catch {
            guard generation == voiceLifecycle.generation else { return }
            await enterManual(.streamFailed("语音连接中断，可以手动继续或重新开始。"))
        }
    }

    private func handle(
        _ envelope: RealtimeEventEnvelope<RealtimeASRClient.Event>, generation: UUID
    ) async {
        guard voiceLifecycle.acceptsVoiceEvents(token: generation), !isStoppingIntentionally else { return }
        let handleStartedAt = ContinuousClock().now
        var didAlign = false
        defer {
            if didAlign {
                followLatencyDiagnostics.recordAlignment(
                    queueAgeMilliseconds: Self.milliseconds(
                        envelope.receivedAt.duration(to: handleStartedAt)
                    ),
                    matchMilliseconds: Self.milliseconds(
                        handleStartedAt.duration(to: ContinuousClock().now)
                    )
                )
            }
        }
        switch envelope.payload {
        case .speechStarted:
            guard !isResuming else { return }
            _ = followAdapter.apply(
                envelope.payload,
                metadata: envelope.metadata,
                segments: activeVersion?.segments ?? [],
                to: &followController
            )
            if followController.mode == .following { hasHeardSpeech = true }
            syncFollowState()
        case .partial(_, _), .partialSnapshot(_, _, _):
            guard !isResuming, let activeVersion else { return }
            _ = followAdapter.apply(
                envelope.payload,
                metadata: envelope.metadata,
                segments: activeVersion.segments,
                to: &followController
            )
            syncFollowState()
            didAlign = true
        case .completed(_, _, _):
            guard !isResuming, let activeVersion else { return }
            _ = followAdapter.apply(
                envelope.payload,
                metadata: envelope.metadata,
                segments: activeVersion.segments,
                to: &followController
            )
            syncFollowState()
            if followController.mode == .following {
                phase = uncertainty == nil ? .following : .uncertain
            }
            didAlign = true
        case .serverError(let code, let message, _, _, _, _):
            if code == "backend_busy" {
                await enterManual(.serviceBusy(message))
            } else {
                lastFailure = message
            }
        case .failed(_, let code, let message):
            _ = followAdapter.apply(
                envelope.payload,
                metadata: envelope.metadata,
                segments: activeVersion?.segments ?? [],
                to: &followController
            )
            await enterManual(.streamFailed("\(code)：\(message)"))
        case .closed:
            _ = followAdapter.apply(
                envelope.payload,
                metadata: envelope.metadata,
                segments: activeVersion?.segments ?? [],
                to: &followController
            )
            if !isStoppingIntentionally {
                await enterManual(.streamFailed("Realtime 连接已断开，可以手动继续或重试。"))
            }
        default:
            break
        }
    }

    private func enterManual(_ reason: BlockReason) async {
        source?.stop()
        source = nil
        await client?.close()
        client = nil
        pump?.cancel()
        pump = nil
        if coordinator.occupancy?.kind == .teleprompter {
            await coordinator.stopCapture(endingWith: .user)
        }
        _ = voiceLifecycle.invalidateAfterFailure(reason: reason.title)
        followController.enterManual()
        syncFollowState()
        blocked = reason
        phase = .manual
        saveProgress()
        runningVersion = nil
    }

    private func syncFollowState() {
        let previousIndex = currentSegmentIndex
        currentSegmentIndex = followController.currentIndex
        readingOffset = followController.position.utf16Offset
        partialText = followController.partialPreview
        uncertainty = followController.uncertainty
        followState = followController.followState
        followStatusText = TeleprompterFollowPresentation.statusText(for: followState)
        if uncertainty != nil {
            resetAdaptiveClockSamples()
            runClock.estimatedRemainingSeconds = remainingTextEstimate()
        } else if currentSegmentIndex != previousIndex {
            observeClockProgress()
            runClock.estimatedRemainingSeconds = remainingTextEstimate()
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        let value = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return max(0, value)
    }

    private func observeClockProgress() {
        guard currentSegmentIndex > clockSampleStartSegment,
              let version = activeVersion,
              clockSampleStartSegment < version.segments.count else {
            if currentSegmentIndex < clockSampleStartSegment {
                clockSamples.removeAll()
                clockAdaptiveFactor = 1.0
                clockSampleStartSegment = currentSegmentIndex
                clockSampleStartElapsed = runClock.elapsedSeconds
            }
            return
        }
        let elapsed = runClock.elapsedSeconds - clockSampleStartElapsed
        guard elapsed >= TeleprompterTimingPolicy.minimumTrialDurationSeconds else { return }
        let end = min(currentSegmentIndex, version.segments.count)
        let text = version.segments[clockSampleStartSegment..<end]
            .map(\.text)
            .joined(separator: "\n\n")
        let estimate = TeleprompterDurationEstimator.estimate(
            text,
            pace: pace,
            calibrationFactor: calibrationFactor
        ).pointSeconds
        if let estimate, estimate > 0 {
            let factor = elapsed / estimate
            if factor.isFinite, (0.5...2.0).contains(factor) {
                clockSamples.append(factor)
                if clockSamples.count > 3 { clockSamples.removeFirst() }
                let sorted = clockSamples.sorted()
                clockAdaptiveFactor = sorted[sorted.count / 2]
            }
        }
        clockSampleStartSegment = end
        clockSampleStartElapsed = runClock.elapsedSeconds
    }

    private func saveProgress() {
        guard let document, let activeVersion else { return }
        cancelScheduledDraftSave()
        do {
            let state = TeleprompterRunState(
                    documentID: document.id,
                    versionID: activeVersion.id,
                    currentSegmentID: currentSegment?.id,
                    mode: followController.mode
                )
            savedRunState = state
            try saveBundle()
            savedRunState = state
        } catch {
            lastFailure = error.localizedDescription
        }
    }

    private func saveBundle() throws {
        guard var document else { throw TeleprompterV2StoreError.invalidBundle }
        if document.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            document.title = "未命名稿子"
        }
        try v2Store.save(try makeV2Bundle(document: document))
    }

    /// 显式保存当前稿件，供工作台的失败恢复动作使用。
    public func save() throws {
        try saveBundle()
    }

    // MARK: - v2 持久化桥接

    private func applyV2Bundle(_ bundle: TeleprompterV2DocumentBundle) {
        let currentSource = bundle.sourceRevisions.first {
            $0.id == bundle.document.currentSourceRevisionID
        }
        let loadedDocument = TeleprompterDocument(
            id: bundle.document.id,
            title: bundle.document.title,
            sourceText: currentSource?.sourceText ?? "",
            activeVersionID: bundle.document.activeVersionID,
            createdAt: bundle.document.createdAt,
            updatedAt: bundle.document.updatedAt
        )
        document = loadedDocument
        if let currentSource {
            let body = Data(currentSource.sourceText.utf8)
            importedSource = TeleprompterImportedSource(
                sourceRevisionID: currentSource.id,
                sourceText: currentSource.sourceText,
                formatHint: currentSource.formatHint,
                hasBOM: currentSource.hasBOM,
                originalUTF8Data: currentSource.hasBOM
                    ? Data([0xEF, 0xBB, 0xBF]) + body
                    : body,
                sourceSHA256: currentSource.utf8SHA256,
                builderVersion: currentSource.builderVersion,
                referenceSeconds: TeleprompterDurationEstimator.referenceSeconds(for: currentSource.sourceText)
            )
        } else {
            importedSource = nil
        }
        versions = bundle.versions.map { legacyVersion(from: $0, sources: bundle.sourceRevisions) }
        savedRunState = bundle.lastRun.flatMap { run in
            guard let mode = TeleprompterRunMode(rawValue: run.endedReason) else { return nil }
            return TeleprompterRunState(
                documentID: bundle.document.id,
                versionID: run.versionID,
                currentSegmentID: run.lastSegmentID,
                mode: mode
            )
        }

        if let draft = bundle.draft {
            let source = bundle.sourceRevisions.first { $0.id == draft.sourceRevisionID }
            readingBlocks = legacyBlocks(
                from: draft.blocks,
                reviews: draft.reviewIssues,
                source: source
            )
            reviewItems = draft.reviewIssues
            if let source {
                contentSelection = contentSelection(
                    selectedUnitIDs: Set(draft.blocks.flatMap(\.sourceUnitIDs)),
                    source: source
                )
            }
            let speakBlocks = readingBlocks.filter { $0.disposition == .speak }
            let segments = speakBlocks.enumerated().map { index, block in
                TeleprompterSegment(
                    id: block.id,
                    ordinal: index,
                    sourceRange: block.sourceRange,
                    text: block.text,
                    pauseHint: .medium
                )
            }
            pendingVersion = TeleprompterVersion(
                id: draft.id,
                documentID: bundle.document.id,
                sourceText: speakBlocks.map(\.text).joined(separator: "\n\n"),
                segments: segments,
                analysisSource: .ai
            )
            targetMinutes = max(
                TeleprompterTimingPolicy.minimumTargetMinutes,
                min(
                    TeleprompterTimingPolicy.maximumTargetMinutes,
                    Int((draft.goal.targetSeconds / 60).rounded())
                )
            )
            pace = draft.pace
            phase = .review
        } else {
            readingBlocks = []
            reviewItems = []
            pendingVersion = nil
            phase = activeVersion == nil ? .draft : .ready
            if let selectionVersion = bundle.versions.first(where: {
                $0.id == bundle.document.activeVersionID
            }), let source = currentSource {
                contentSelection = legacySelection(
                    from: selectionVersion.selectionSnapshot,
                    source: source
                )
            } else {
                contentSelection = TeleprompterContentSelection()
            }
        }

        let restoredIndex = savedRunState.flatMap { state in
            versions.first { $0.id == state.versionID }?.segments.firstIndex {
                $0.id == state.currentSegmentID
            }
        } ?? 0
        currentSegmentIndex = restoredIndex
        followController = TeleprompterFollowController(
            currentIndex: restoredIndex,
            mode: savedRunState?.mode ?? .manual
        )
        blocked = nil
        lastFailure = nil
        syncFollowState()
    }

    private func legacyDocument(from bundle: TeleprompterV2DocumentBundle) throws -> TeleprompterDocument {
        guard let source = bundle.sourceRevisions.first(where: {
            $0.id == bundle.document.currentSourceRevisionID
        }) else {
            throw TeleprompterV2StoreError.invalidBundle
        }
        return TeleprompterDocument(
            id: bundle.document.id,
            title: bundle.document.title,
            sourceText: source.sourceText,
            activeVersionID: bundle.document.activeVersionID,
            createdAt: bundle.document.createdAt,
            updatedAt: bundle.document.updatedAt
        )
    }

    private func legacyVersion(
        from version: TeleprompterV2ReadingVersion,
        sources: [TeleprompterV2SourceRevision]
    ) -> TeleprompterVersion {
        let source = sources.first { $0.id == version.sourceRevisionID }
        let segments = version.segments.enumerated().map { index, segment in
            let block = version.blocks.first { $0.id == segment.id }
                ?? (version.blocks.indices.contains(index) ? version.blocks[index] : nil)
            let sourceRange = block.flatMap {
                self.sourceRange(for: $0.sourceUnitIDs, source: source)
            } ?? TeleprompterSourceRange(
                start: 0,
                end: min(segment.text.utf16.count, source?.sourceText.utf16.count ?? 0)
            )
            return TeleprompterSegment(
                id: segment.id,
                ordinal: index,
                sourceRange: sourceRange,
                text: segment.text,
                keywords: segment.keywords,
                matchPhrases: segment.matchPhrases,
                pauseHint: segment.pauseHint
            )
        }
        return TeleprompterVersion(
            id: version.id,
            documentID: version.documentID,
            sourceText: source?.sourceText ?? version.readingText,
            segments: segments,
            analysisSource: version.analysisSource,
            createdAt: version.createdAt
        )
    }

    private func legacyBlocks(
        from blocks: [TeleprompterV2ReadingBlock],
        reviews: [TeleprompterReviewItem],
        source: TeleprompterV2SourceRevision?
    ) -> [TeleprompterReadingBlock] {
        blocks.enumerated().map { index, block in
            let range = sourceRange(for: block.sourceUnitIDs, source: source)
            let rawText = text(in: range, source: source?.sourceText) ?? block.text
            return TeleprompterReadingBlock(
                id: block.id,
                ordinal: index,
                sourceRange: range,
                text: block.text,
                rawSourceText: rawText,
                disposition: block.disposition,
                origin: block.origin,
                reviewIssues: reviews.filter { $0.blockID == block.id }.map(\.issue),
                budgetSeconds: block.budgetShare
            )
        }
    }

    private func legacySelection(
        from snapshot: TeleprompterV2SelectionRevision,
        source: TeleprompterV2SourceRevision
    ) -> TeleprompterContentSelection {
        let paragraphRanges = paragraphRanges(in: source.sourceText)
        let selected: Set<Int> = Set(paragraphRanges.enumerated().compactMap { (index, range) -> Int? in
            snapshot.selectedRanges.contains { selectedRange in
                selectedRange.start <= range.start && selectedRange.end >= range.end
            } ? index : nil
        })
        guard !paragraphRanges.isEmpty else { return .init() }
        return TeleprompterContentSelection(
            totalParagraphCount: paragraphRanges.count,
            selectedParagraphIndices: selected
        )
    }

    private func contentSelection(
        selectedUnitIDs: Set<Int>,
        source: TeleprompterV2SourceRevision
    ) -> TeleprompterContentSelection {
        let paragraphRanges = paragraphRanges(in: source.sourceText)
        let selected: Set<Int> = Set(paragraphRanges.enumerated().compactMap { (index, range) -> Int? in
            let relevantUnits = source.sourceUnits.filter { unit in
                unit.sourceRange.start < range.end && range.start < unit.sourceRange.end
            }
            guard !relevantUnits.isEmpty else { return nil }
            return relevantUnits.allSatisfy { selectedUnitIDs.contains($0.id) } ? index : nil
        })
        guard !paragraphRanges.isEmpty else { return .init() }
        return TeleprompterContentSelection(
            totalParagraphCount: paragraphRanges.count,
            selectedParagraphIndices: selected
        )
    }

    private func makeV2Bundle(document: TeleprompterDocument) throws -> TeleprompterV2DocumentBundle {
        let existing = try? v2Store.load(documentID: document.id)
        var sources = existing?.sourceRevisions ?? []

        let currentSource = sourceRevision(
            for: document.sourceText,
            metadata: importedSource,
            sources: &sources
        )
        let selection = selectionSnapshot(
            source: currentSource,
            sourceText: document.sourceText
        )
        let v2Versions = try versions.map { version in
            try v2Version(
                from: version,
                source: currentSource,
                selection: selection,
                existing: existing?.versions.first { $0.id == version.id }
            )
        }
        let draft: TeleprompterV2ReadingDraft?
        if pendingVersion != nil && !readingBlocks.isEmpty {
            draft = try v2Draft(
                source: currentSource,
                selection: selection,
                existing: existing?.draft
            )
        } else {
            draft = nil
        }
        let v2Document = TeleprompterV2Document(
            id: document.id,
            title: document.title,
            currentSourceRevisionID: currentSource.id,
            activeVersionID: document.activeVersionID,
            createdAt: document.createdAt,
            updatedAt: Date()
        )
        let run = savedRunState.map { state in
            TeleprompterV2RunSummary(
                versionID: state.versionID,
                targetSeconds: runClock.targetSeconds,
                elapsedSeconds: runClock.elapsedSeconds,
                lastSegmentID: state.currentSegmentID,
                endedReason: state.mode.rawValue,
                completedReading: activeVersion.map {
                    currentSegmentIndex >= max(0, $0.segments.count - 1)
                } ?? false
            )
        }
        return TeleprompterV2DocumentBundle(
            document: v2Document,
            sourceRevisions: sources,
            draft: draft,
            versions: v2Versions,
            lastRun: run
        )
    }

    private func sourceRevision(
        for text: String,
        metadata: TeleprompterImportedSource? = nil,
        sources: inout [TeleprompterV2SourceRevision]
    ) -> TeleprompterV2SourceRevision {
        if let existing = sources.first(where: { $0.sourceText == text }) {
            return existing
        }
        let data = Data(text.utf8)
        let hash = TeleprompterV2Hash.sha256(data)
        var id = "source-\(hash.prefix(16))"
        if sources.contains(where: { $0.id == id && $0.sourceText != text }) {
            id = "source-\(hash.prefix(16))-\(UUID().uuidString.prefix(8))"
        }
        let units: [TeleprompterSourceUnit]
        let imported: TeleprompterImportedSource?
        if let metadata, metadata.sourceText == text {
            imported = TeleprompterImportedSource(
                sourceRevisionID: id,
                sourceText: text,
                formatHint: metadata.formatHint,
                hasBOM: metadata.hasBOM,
                originalUTF8Data: metadata.originalUTF8Data,
                sourceSHA256: hash,
                builderVersion: metadata.builderVersion,
                referenceSeconds: metadata.referenceSeconds
            )
        } else {
            imported = try? TeleprompterSourceImporter.importData(data)
        }
        var formatHint = imported?.formatHint ?? .unknown
        if let imported, let built = try? TeleprompterSourceUnitBuilder().build(imported) {
            units = built.map { unit in
                TeleprompterSourceUnit(
                    id: unit.id,
                    ordinal: unit.ordinal,
                    sourceRevisionID: id,
                    sourceRange: unit.sourceRange,
                    rawText: unit.rawText,
                    continuation: unit.continuation,
                    budgetUnits: unit.budgetUnits
                )
            }
        } else if text.isEmpty {
            formatHint = .unknown
            units = []
        } else {
            formatHint = .unknown
            let range = TeleprompterSourceRange(start: 0, end: text.utf16.count)
            units = [TeleprompterSourceUnit(
                id: 0,
                ordinal: 0,
                sourceRevisionID: id,
                sourceRange: range,
                rawText: text,
                continuation: false,
                budgetUnits: max(1, text.utf8.count)
            )]
        }
        let revision = TeleprompterV2SourceRevision(
            id: id,
            sourceText: text,
            utf8SHA256: hash,
            formatHint: formatHint,
            sourceUnits: units
        )
        sources.append(revision)
        return revision
    }

    private func selectionSnapshot(
        source: TeleprompterV2SourceRevision,
        sourceText: String
    ) -> TeleprompterV2SelectionRevision {
        let allUnits = source.sourceUnits
        let paragraphRanges = paragraphRanges(in: sourceText)
        let selectedParagraphs: [TeleprompterSourceRange]
        let excludedParagraphs: [TeleprompterSourceRange]
        if contentSelection.isAllSelected || !contentSelection.hasExclusions || paragraphRanges.isEmpty {
            selectedParagraphs = sourceText.isEmpty
                ? []
                : [TeleprompterSourceRange(start: 0, end: sourceText.utf16.count)]
            excludedParagraphs = []
        } else {
            selectedParagraphs = paragraphRanges.enumerated().compactMap { index, range in
                contentSelection.selectedParagraphIndices.contains(index) ? range : nil
            }
            excludedParagraphs = paragraphRanges.enumerated().compactMap { index, range in
                contentSelection.selectedParagraphIndices.contains(index) ? nil : range
            }
        }
        let selectedIDs = allUnits.compactMap { unit in
            unitContainsOnlySelectedContent(
                unit,
                sourceText: sourceText,
                selectedRanges: selectedParagraphs
            ) ? unit.id : nil
        }
        return TeleprompterV2SelectionRevision(
            id: "selection-\(UUID().uuidString)",
            sourceUnitRevision: source.id,
            selectedUnitIDs: selectedIDs,
            selectedRanges: selectedParagraphs,
            userExcludedRanges: excludedParagraphs
        )
    }

    private func unitContainsOnlySelectedContent(
        _ unit: TeleprompterSourceUnit,
        sourceText: String,
        selectedRanges: [TeleprompterSourceRange]
    ) -> Bool {
        guard let swiftRange = Range(
            NSRange(
                location: unit.sourceRange.start,
                length: unit.sourceRange.end - unit.sourceRange.start
            ),
            in: sourceText
        ) else { return false }

        var offset = unit.sourceRange.start
        var containsContent = false
        for character in sourceText[swiftRange] {
            let length = String(character).utf16.count
            let isWhitespace = String(character).rangeOfCharacter(from: .whitespacesAndNewlines) != nil
            if !isWhitespace {
                containsContent = true
                guard selectedRanges.contains(where: {
                    $0.start <= offset && offset + length <= $0.end
                }) else {
                    return false
                }
            }
            offset += length
        }
        return containsContent
    }

    private func v2Version(
        from version: TeleprompterVersion,
        source: TeleprompterV2SourceRevision,
        selection: TeleprompterV2SelectionRevision,
        existing: TeleprompterV2ReadingVersion?
    ) throws -> TeleprompterV2ReadingVersion {
        let blocks = version.segments.map { segment in
            TeleprompterV2ReadingBlock(
                id: segment.id,
                revision: 0,
                sourceUnitIDs: sourceUnitIDs(for: segment.sourceRange, units: source.sourceUnits),
                text: segment.text,
                disposition: .speak,
                origin: v2Origin(version.analysisSource),
                budgetShare: TeleprompterDurationEstimator.estimate(segment.text).pointSeconds ?? 0
            )
        }
        let readingText = version.segments.map(\.text).joined(separator: "\n\n")
        var readingOffset = 0
        let segments = version.segments.enumerated().map { index, segment in
            let start = readingOffset
            readingOffset += segment.text.utf16.count
            if index < version.segments.count - 1 { readingOffset += 2 }
            return TeleprompterV2ReadingSegment(
                id: segment.id,
                ordinal: index,
                readingRange: .init(start: start, end: start + segment.text.utf16.count),
                text: segment.text,
                keywords: segment.keywords,
                matchPhrases: segment.matchPhrases,
                pauseHint: segment.pauseHint
            )
        }
        let estimate = existing?.estimate ?? TeleprompterDurationEstimator.estimate(readingText)
        let goal = existing?.goalSnapshot ?? .init(
            targetSeconds: Double(targetMinutes * 60),
            goalRevision: 0
        )
        return TeleprompterV2ReadingVersion(
            id: version.id,
            documentID: version.documentID,
            sourceRevisionID: source.id,
            selectionSnapshot: .init(
                id: selection.id,
                sourceUnitRevision: selection.sourceUnitRevision,
                selectedUnitIDs: selection.selectedUnitIDs,
                selectedRanges: selection.selectedRanges,
                userExcludedRanges: selection.userExcludedRanges
            ),
            readingText: readingText,
            blocks: blocks,
            segments: segments,
            goalSnapshot: goal,
            paceSnapshot: existing?.paceSnapshot ?? pace,
            estimate: estimate,
            analysisSource: version.analysisSource,
            createdAt: existing?.createdAt ?? version.createdAt
        )
    }

    private func v2Draft(
        source: TeleprompterV2SourceRevision,
        selection: TeleprompterV2SelectionRevision,
        existing: TeleprompterV2ReadingDraft?
    ) throws -> TeleprompterV2ReadingDraft {
        let blocks = readingBlocks.map { block in
            TeleprompterV2ReadingBlock(
                id: block.id,
                revision: 0,
                sourceUnitIDs: sourceUnitIDs(for: block.sourceRange, units: source.sourceUnits),
                text: block.text,
                disposition: block.disposition,
                origin: v2Origin(block.origin),
                budgetShare: block.budgetSeconds
            )
        }
        let estimates = source.sourceUnits.map { unit in
            TeleprompterDurationEstimator.estimate(
                unit.rawText,
                pace: pace,
                calibrationFactor: calibrationFactor
            ).pointSeconds
        }
        let selectedUnitIDs = Set(selection.selectedUnitIDs)
        let plan: TeleprompterTimingPlan
        if source.sourceUnits.isEmpty {
            plan = .init(
                targetMinutes: targetMinutes,
                targetSeconds: Double(targetMinutes * 60),
                budgetSeconds: Double(targetMinutes * 60) * TeleprompterTimingPolicy.budgetRatio,
                weightMode: .proxyCharacters,
                allocations: []
            )
        } else {
            plan = try TeleprompterTimingPlanner.plan(
                sourceUnits: source.sourceUnits,
                estimates: estimates,
                targetMinutes: targetMinutes,
                selectedUnitIDs: selectedUnitIDs
            )
        }
        return TeleprompterV2ReadingDraft(
            id: pendingVersion?.id ?? existing?.id ?? UUID().uuidString,
            draftRevision: (existing?.draftRevision ?? 0) + 1,
            sourceRevisionID: source.id,
            selectionRevisionID: selection.id,
            blocks: blocks,
            reviewIssues: reviewItems,
            goal: .init(
                targetSeconds: Double(targetMinutes * 60),
                goalRevision: existing?.goal.goalRevision ?? 0
            ),
            pace: pace,
            timingAllocation: .init(
                allocationRevision: (existing?.timingAllocation.allocationRevision ?? 0) + 1,
                plan: plan
            )
        )
    }

    private func sourceUnitIDs(
        for range: TeleprompterSourceRange,
        units: [TeleprompterSourceUnit]
    ) -> [Int] {
        units.filter { unit in
            unit.sourceRange.start < range.end && range.start < unit.sourceRange.end
        }.map(\.id)
    }

    private func sourceRange(
        for ids: [Int],
        source: TeleprompterV2SourceRevision?
    ) -> TeleprompterSourceRange {
        let ranges = source?.sourceUnits.filter { ids.contains($0.id) }.map(\.sourceRange) ?? []
        guard let first = ranges.map(\.start).min(), let last = ranges.map(\.end).max() else {
            return .init(start: 0, end: 0)
        }
        return .init(start: first, end: last)
    }

    private func text(in range: TeleprompterSourceRange, source: String?) -> String? {
        guard let source,
              range.start >= 0,
              range.end >= range.start,
              let swiftRange = Range(
                NSRange(location: range.start, length: range.end - range.start),
                in: source
              ) else { return nil }
        return String(source[swiftRange])
    }

    private func paragraphRanges(in source: String) -> [TeleprompterSourceRange] {
        let parts = source.components(separatedBy: "\n\n")
        var offset = 0
        return parts.enumerated().compactMap { index, part in
            let start = offset
            offset += part.utf16.count
            if index < parts.count - 1 { offset += 2 }
            guard !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .init(start: start, end: start + part.utf16.count)
        }
    }

    private func v2Origin(_ origin: TeleprompterBlockOrigin) -> TeleprompterBlockOrigin {
        origin
    }

    private func v2Origin(_ source: TeleprompterAnalysisSource) -> TeleprompterBlockOrigin {
        switch source {
        case .ai: .ai
        case .deterministic: .deterministic
        case .user: .user
        }
    }

    private func persistDraft() {
        do {
            try saveBundle()
            if case .storeUnavailable = blocked { blocked = nil }
        }
        catch { blocked = .storeUnavailable("稿子暂时没能保存，请稍后重试。") }
    }

    private func invalidateAnalysis() {
        cancelScheduledDraftSave()
        preparationTask?.cancel()
        preparationTask = nil
        tightenTask?.cancel()
        tightenTask = nil
        isTightening = false
        annotationTask?.cancel()
        annotationTask = nil
        isAnnotating = false
        preparationProgress = nil
        preparationResult = nil
        draftGeneration = UUID()
    }

    private static func blockReason(for error: Error) -> BlockReason {
        if let failure = error as? MicrophoneCapture.Failure, failure == .permissionDenied {
            return .microphoneDenied
        }
        if let blocked = error as? Blocked { return blocked.reason }
        return .serviceNotReady(error.localizedDescription)
    }

    private static func aiFailureMessage(for error: Error) -> String {
        if let error = error as? LLMError,
           error == .unsupportedStructuredOutput {
            return "当前 AI 服务暂时无法整理这份稿子。请在设置中更换 AI 服务，或直接按原文分段；原稿没有变化。"
        }
        return "AI 暂时没能整理这份稿子，原稿没有变化。你可以重试，或直接按原文分段。"
    }

    private struct Blocked: Error {
        let reason: BlockReason
    }
}
