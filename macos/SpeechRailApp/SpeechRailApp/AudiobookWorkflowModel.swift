import Foundation
import Observation
import SpeechRailControlKit

/// T13：有声书工坊唯一功能 Owner（管理书架、导入预览、全书分析、角色确认、逐章制作、返修版本、共享听书与导出状态，视图不持有长任务）。
@MainActor
@Observable
public final class AudiobookWorkflowModel {
    public enum SurfaceMode: String, Codable, CaseIterable, Equatable, Sendable {
        case shelf
        case workspace
        case listening
    }

    enum LoadCheckpoint: Equatable {
        case beforeBookWorkspacePublication
        case beforeChapterDetailsPublication
    }

    public enum WorkbenchTab: String, Codable, CaseIterable, Equatable, Sendable {
        case preparation
        case production

        public var title: String {
            switch self {
            case .preparation: "准备与角色"
            case .production: "制作与返修"
            }
        }
    }

    private let bookSelectionLoad = SpeechRailSelectionLoad<AudiobookBookWorkspaceSnapshot>()
    private let chapterSelectionLoad = SpeechRailSelectionLoad<AudiobookChapterDetailsSnapshot>()
    private let readinessSelectionLoad = SpeechRailSelectionLoad<[UUID: AudiobookChapterReadinessState]>()

    public enum ShelfFilter: String, CaseIterable, Equatable, Sendable, Identifiable {
        case all
        case preparing
        case producing
        case listenable

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .all: "全部书籍"
            case .preparing: "待准备"
            case .producing: "制作中"
            case .listenable: "可收听"
            }
        }
    }

    public enum PrimaryBookAction: Equatable, Sendable {
        case analyzeWholeBook
        case resumeAnalysis
        case pauseAnalysis
        case confirmSpeakers(count: Int)
        case confirmCastAndVoices
        case makeConfirmedChapters
        case resumeProduction
        case pauseProduction
        case continueListening

        public var title: String {
            switch self {
            case .analyzeWholeBook:
                return "分析全书"
            case .resumeAnalysis:
                return "继续分析全书"
            case .pauseAnalysis:
                return "暂停分析"
            case let .confirmSpeakers(count):
                return "确认说话人后继续（\(count)）"
            case .confirmCastAndVoices:
                return "确认人物与声音"
            case .makeConfirmedChapters:
                return "制作已确认章节"
            case .resumeProduction:
                return "继续制作"
            case .pauseProduction:
                return "暂停制作"
            case .continueListening:
                return "继续听"
            }
        }

        public var systemImage: String {
            switch self {
            case .analyzeWholeBook, .resumeAnalysis:
                return "sparkles"
            case .pauseAnalysis:
                return "pause.circle"
            case .confirmSpeakers:
                return "person.crop.circle.badge.questionmark"
            case .confirmCastAndVoices:
                return "person.wave.2"
            case .makeConfirmedChapters, .resumeProduction:
                return "waveform.badge.plus"
            case .pauseProduction:
                return "pause.circle"
            case .continueListening:
                return "headphones"
            }
        }
    }

    // MARK: - Observable Projections

    public var surfaceMode: SurfaceMode = .shelf
    public var workbenchTab: WorkbenchTab = .preparation
    public var shelfFilter: ShelfFilter = .all
    public var searchQuery: String = ""

    public private(set) var shelfBooks: [AudiobookBookSummary] = []
    public private(set) var trashedBooks: [AudiobookTrashedBookEntry] = []
    public private(set) var selectedBook: AudiobookBook?
    public private(set) var chapters: [AudiobookChapter] = []
    private var isSuppressingChapterAutoReload: Bool = false
    private var hasRecoveredOnBootstrap: Bool = false
    @ObservationIgnored private var storeRecoveryTask: Task<Void, Error>?
    @ObservationIgnored private var storeRecoveryRequestID: UUID?
    public private(set) var isLoadingChapterDetails: Bool = false
    public var selectedChapterID: UUID? {
        didSet {
            if selectedChapterID != oldValue && !isSuppressingChapterAutoReload {
                chapterSelectionLoad.reset()
                applyChapterDetails(.empty)
                selectedAtomIDs.removeAll()
                isLoadingChapterDetails = selectedBook != nil && selectedChapterID != nil
                Task { await reloadSelectedChapterDetails() }
            }
        }
    }
    public enum CastFilterScope: String, CaseIterable, Equatable, Sendable, Identifiable {
        case inCurrentChapter
        case leads
        case minorEnsemble
        case all

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .inCurrentChapter: return "本章出场"
            case .leads: return "核心主角"
            case .minorEnsemble: return "配角群像"
            case .all: return "全部"
            }
        }
    }

    public private(set) var characters: [AudiobookCharacter] = [] {
        didSet {
            charactersByID = Dictionary(uniqueKeysWithValues: characters.map { ($0.id, $0) })
            rebuildMinorCharactersByArchetype()
            rebuildSceneConflictCache()
            rebuildChapterCharacterBuckets()
        }
    }
    public private(set) var charactersByID: [UUID: AudiobookCharacter] = [:]
    public private(set) var minorCharactersByArchetype: [AudiobookVoiceArchetype: [AudiobookCharacter]] = [:]
    public private(set) var sceneConflictPartnersByRoleID: [UUID: [String]] = [:]
    public private(set) var totalSceneVoiceConflictCount: Int = 0
    public private(set) var currentChapterCharacters: [AudiobookCharacter] = []
    public private(set) var remainingBookCharacters: [AudiobookCharacter] = []
    public var selectedRoleID: UUID?
    public var castFilterScope: CastFilterScope = .inCurrentChapter
    public var showSilentCharacters: Bool = false
    public private(set) var roleStatsByID: [UUID: AudiobookRoleDialogueStats] = [:] {
        didSet {
            rebuildMinorCharactersByArchetype()
            rebuildSceneConflictCache()
        }
    }
    public private(set) var voiceBindings: [UUID: AudiobookVoiceBinding] = [:] {
        didSet {
            rebuildSceneConflictCache()
        }
    }
    public private(set) var chapterReadinessByID: [UUID: AudiobookChapterReadinessState] = [:]
    public private(set) var chapterAtoms: [AudiobookTextAtom] = []
    public private(set) var chapterAnnotations: [AudiobookAnnotation] = [] {
        didSet {
            var map: [UUID: AudiobookAnnotation] = [:]
            map.reserveCapacity(chapterAnnotations.count)
            for ann in chapterAnnotations {
                map[ann.atomID] = ann
            }
            chapterAnnotationsByAtomID = map
            rebuildChapterCharacterBuckets()
        }
    }
    public private(set) var chapterAnnotationsByAtomID: [UUID: AudiobookAnnotation] = [:]
    public private(set) var chapterFragments: [AudiobookFragment] = []
    public private(set) var chapterCandidates: [AudiobookRenderCandidate] = [] {
        didSet {
            var grouped = Dictionary(grouping: chapterCandidates, by: \.fragmentID)
            for key in grouped.keys {
                grouped[key]?.sort { $0.createdAt > $1.createdAt }
            }
            chapterCandidatesByFragmentID = grouped
        }
    }
    public private(set) var chapterCandidatesByFragmentID: [UUID: [AudiobookRenderCandidate]] = [:]
    public private(set) var atomTextsByID: [UUID: String] = [:]
    public private(set) var fragmentTextsByID: [UUID: String] = [:]
    public var selectedFragmentID: UUID?
    public var selectedAtomIDs: Set<UUID> = []

    /// 全书各章节待确认说话人计数与有序定位索引（用于跨章/章内快速定位待确认位置）。
    public private(set) var unknownCountByChapterID: [UUID: Int] = [:]
    public private(set) var allUnknownAnnotations: [AudiobookAnnotation] = []
    public var focusedUnknownAtomID: UUID?
    public var showOnlyUnknownAtomsInChapter: Bool = false
    public private(set) var isResolvingUnknownSpeakers: Bool = false

    /// 主要角色专属音色与六类群像音色自动/一键生成状态。
    public private(set) var isCreatingLeadExclusiveVoices: Bool = false
    public private(set) var leadVoiceCreationProgressText: String?

    public struct LeadVoiceCreationSummary: Sendable, Equatable {
        public var attemptedCount: Int
        public var succeededCount: Int
        public var fallbacks: [(roleID: UUID, roleName: String, fallbackArchetypeName: String)]

        public init(
            attemptedCount: Int = 0,
            succeededCount: Int = 0,
            fallbacks: [(roleID: UUID, roleName: String, fallbackArchetypeName: String)] = []
        ) {
            self.attemptedCount = attemptedCount
            self.succeededCount = succeededCount
            self.fallbacks = fallbacks
        }

        public static func == (lhs: LeadVoiceCreationSummary, rhs: LeadVoiceCreationSummary) -> Bool {
            lhs.attemptedCount == rhs.attemptedCount &&
            lhs.succeededCount == rhs.succeededCount &&
            lhs.fallbacks.map(\.roleID) == rhs.fallbacks.map(\.roleID)
        }
    }

    /// 最近一次主要角色专属音色生成的统计摘要与优雅降级记录。
    public private(set) var lastLeadVoiceCreationSummary: LeadVoiceCreationSummary?
    /// 自动回退为群像音色的角色集合（用于展示重试标识）。
    public private(set) var fallbackRoleIDs: Set<UUID> = []

    /// 当前从引擎实时拉取并缓存的全部可用音色目录（含系统预置、克隆音色、六类群像音色与本书专属音色）。
    public private(set) var catalogVoices: [SafeVoiceEntry] = []

    public static let builtInSystemVoiceIDs: Set<String> = [
        "vivian", "serena", "uncle_fu", "ryan", "aiden",
        "ono_anna", "sohee", "eric", "dylan"
    ]

    public private(set) var analysisSummary: AudiobookAnalysisSummary?
    public private(set) var isAnalyzing: Bool = false
    /// 当前分析 run 的 live 进度投影（事件流收敛结果）；非分析中为 nil。
    public private(set) var analysisProgress: AudiobookAnalysisProgress?
    /// 开发者详情用的最近事件缓冲（内存，不落盘）。
    public private(set) var analysisEventBuffer = AudiobookAnalysisEventBuffer()
    /// 进度投影的安装代次：每次 beginAnalysis 递增，旧 sink 的迟到事件按代次丢弃，
    /// 防止暂停→重跑时上一次的 runEnded/窗口事件污染新投影。
    private var analysisInstallEpoch: Int = 0
    public private(set) var isProducing: Bool = false
    public private(set) var isPausingProduction: Bool = false
    public private(set) var productionBookID: UUID?
    public private(set) var productionFragmentID: UUID?
    public private(set) var productionProgress: AudiobookProductionProgress?
    private var selectedProductionCheckpoint: AudiobookProductionCheckpoint?
    public private(set) var isEditingChapterLayout: Bool = false
    public private(set) var resumePlan: AudiobookResumePlan?
    public private(set) var exportCapabilities: MediaCapabilitiesSnapshot = .init(
        available: false,
        encoders: [],
        supportsM4B: false,
        supportsMP3: false
    )
    public var preparedExport: AudiobookPreparedExport?
    public private(set) var isPreparingExport: Bool = false
    /// 导出面板内联错误：主页面横幅会被 sheet 遮住，导出失败必须在当前上下文可见。
    public var exportErrorMessage: String?
    @ObservationIgnored private var exportPreparationRequestID: UUID?
    @ObservationIgnored private var secondaryResolutionTask: Task<Void, Never>?
    public private(set) var exportRecords: [AudiobookExportRecord] = []
    public private(set) var exportCover: AudiobookCoverAsset?
    public private(set) var exportCoverPreviewURL: URL?
    public private(set) var exportCoverErrorMessage: String?

    public var importPreview: AudiobookImportPreview?
    public var importErrorMessage: String?
    public var importFileURL: URL?
    public var isShowingImportSheet: Bool = false
    public var isShowingTrashSheet: Bool = false
    public var isShowingExportSheet: Bool = false
    public var isShowingCastMergeSheet: Bool = false
    public var isCastInspectorPresented: Bool = false

    public private(set) var pendingVoiceReturnContext: AudiobookVoiceReturnContext?
    public private(set) var voiceReturnBannerMessage: String?
    public var bannerMessage: String?
    public var errorMessage: String?
    public private(set) var lastTrashedBookID: UUID?
    public private(set) var lastTrashedBookTitle: String?
    public private(set) var trashUndoMessage: String?

    public private(set) var listeningController: AudiobookListeningController?
    public private(set) var pronunciationController: AudiobookPronunciationController?
    public var isPronunciationSheetPresented: Bool = false

    // MARK: - Internal Actors & Tasks

    private let dependencies: AudiobookDependencies
    private let playbackOwner: SharedPlaybackOwner
    private let admission: SpeechCreationAdmission
    private var store: AudiobookProjectStore?
    private var workspaceReader: AudiobookWorkspaceReader?
    @ObservationIgnored private var workspaceRequestGeneration: UInt64 = 0
    @ObservationIgnored private var unknownSpeakerProjectionGeneration: UInt64 = 0
    @ObservationIgnored private var workspaceRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var workspaceRefreshID: UUID?
    @ObservationIgnored var workspaceRefreshDelay: Duration = .milliseconds(50)
    var pendingWorkspaceRefreshForTesting: Task<Void, Never>? { workspaceRefreshTask }
    func replaceWorkspaceReaderForTesting(_ reader: AudiobookWorkspaceReader) { workspaceReader = reader }
    private var analysisPipeline: AudiobookAnalysisPipeline?
    private var castController: AudiobookCastController?
    private var revisionController: AudiobookRevisionController?
    private var productionController: AudiobookProductionController?
    private var exportController: AudiobookExportController?
    private var coverStore: AudiobookCoverAssetStore?

    public let voiceCatalogModel: VoiceCatalogModel
    public private(set) var voiceCatalogRevision: String = ""
    public private(set) var castingPlanNeedsRefresh = false
    public var castingRecommendation: AudiobookCastingRecommendation? { pendingCastingPlan.map(AudiobookCastingRecommendation.init) }
    public private(set) var castingAudition: AudiobookCastingAudition?
    private var auditionPlaybackGeneration: UInt64 = 0
    private var castingAuditionCatalogRevision: String?

    private var analysisTask: Task<Void, Never>?
    private var productionTask: Task<Void, Never>?
    private var productionProgressPollTask: Task<Void, Never>?
    private var productionRunID: UUID?
    private var analysisGeneration: Int = 1
    @ObservationIgnored
    var loadCheckpointForTesting: (@MainActor (UUID, UUID?, LoadCheckpoint) async -> Void)?

    public init(
        dependencies: AudiobookDependencies = .unavailable,
        playbackOwner: SharedPlaybackOwner = SharedPlaybackOwner(),
        admission: SpeechCreationAdmission = SpeechCreationAdmission()
    ) {
        self.dependencies = dependencies
        self.voiceCatalogModel = VoiceCatalogModel(store: dependencies.voiceCatalog)
        self.playbackOwner = playbackOwner
        self.admission = admission
        bootstrapIfPossible()
        voiceCatalogRevision = voiceCatalogModel.snapshot.revision
        voiceCatalogModel.onSnapshotChange = { [weak self] snapshot in
            self?.catalogDidChange(snapshot)
        }
    }

    private func catalogDidChange(_ snapshot: VoiceCatalogSnapshot) {
        voiceCatalogRevision = snapshot.revision
        castingPlanNeedsRefresh = pendingCastingPlan?.voiceCatalogRevision != voiceCatalogRevision
        invalidateCastingAudition()
    }

    private func bootstrapIfPossible() {
        guard store == nil else { return }
        guard let createdStore = try? dependencies.makeStore() else { return }
        self.store = createdStore
        self.coverStore = AudiobookCoverAssetStore(root: createdStore.rootURL)
        let renderer = dependencies.speechRenderer
        let cast = AudiobookCastController(store: createdStore, capabilityProvider: { try await renderer.fetchEffectiveCapabilities() }, voiceCatalog: dependencies.voiceCatalog)
        let rev = AudiobookRevisionController(store: createdStore)
        self.workspaceReader = AudiobookWorkspaceReader(store: createdStore, cast: cast, revisions: rev)
        let prod = AudiobookProductionController(
            store: createdStore,
            castController: cast,
            revisionController: rev,
            renderer: dependencies.speechRenderer,
            admission: admission,
            clock: dependencies.clock,
            voiceCatalog: dependencies.voiceCatalog
        )
        let exp = AudiobookExportController(
            store: createdStore,
            castController: cast,
            revisionController: rev,
            controlTransport: dependencies.controlTransport
        )
        let pipe = AudiobookAnalysisPipeline(
            store: createdStore,
            clientFactory: dependencies.makeAnalysisClient
        )
        let listen = AudiobookListeningController(
            store: createdStore,
            revisionController: rev,
            playbackOwner: playbackOwner
        )
        let pronunciation = AudiobookPronunciationController(
            store: createdStore,
            client: dependencies.pronunciationClient
        )
        self.castController = cast
        self.revisionController = rev
        self.productionController = prod
        self.exportController = exp
        self.analysisPipeline = pipe
        self.listeningController = listen
        self.pronunciationController = pronunciation
    }

    // MARK: - Computed Projections & Next Action Resolution

    public var currentAnalysisConfigSnapshot: AudiobookAnalysisConfigSnapshot {
        dependencies.resolveAnalysisSnapshot(analysisGeneration)
    }

    public var exportReadiness: AudiobookExportReadiness {
        AudiobookExportReadiness(chapters: chapters)
    }

    public var exportReadyChapters: [AudiobookChapter] {
        let ready = Set(exportReadiness.readyChapterIDs)
        return chapters.filter { ready.contains($0.id) }
    }

    public var exportBlockingChapters: [AudiobookChapter] {
        let blocking = Set(exportReadiness.blockingChapterIDs)
        return chapters.filter { blocking.contains($0.id) }
    }

    public var hasListenableChapter: Bool {
        chapters.contains {
            !$0.isSkipped && ($0.currentChapterRevisionID != nil || $0.previousChapterRevisionID != nil)
        }
    }

    public var filteredShelfBooks: [AudiobookBookSummary] {
        shelfBooks.filter { summary in
            let matchesFilter: Bool = switch shelfFilter {
            case .all:
                true
            case .preparing:
                summary.book.analysisState != .allWindowsValidated
                    || summary.book.confirmedCastRevisionID == nil
                    || summary.book.confirmedAuditionVoiceSetDigest == nil
                    || summary.unknownSpeakerCount > 0
            case .producing:
                summary.book.productionState == .running
                    || summary.book.productionState == .paused
                    || summary.book.productionState == .partialChaptersReady
            case .listenable:
                summary.book.listenableState != .noneAvailable
            }
            guard matchesFilter else { return false }
            let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return true }
            return summary.book.title.localizedCaseInsensitiveContains(trimmed)
                || (summary.book.author?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    public var unknownAnnotationsInSelectedChapter: [AudiobookAnnotation] {
        chapterAnnotations.filter { $0.assignment.isUnknown }
    }

    public var totalUnknownSpeakerCount: Int {
        if !allUnknownAnnotations.isEmpty {
            return allUnknownAnnotations.count
        }
        guard let selectedBook else { return 0 }
        return shelfBooks.first(where: { $0.id == selectedBook.id })?.unknownSpeakerCount
            ?? unknownAnnotationsInSelectedChapter.count
    }

    /// 当开启「仅看待确认对白」时，仅保留本章未确认段落及其前后各 1 段紧邻上下文，方便用户一眼核对前后文并一键确认。
    public var displayedChapterAtoms: [AudiobookTextAtom] {
        guard showOnlyUnknownAtomsInChapter else { return chapterAtoms }
        let unknownIDs = Set(unknownAnnotationsInSelectedChapter.map(\.atomID))
        guard !unknownIDs.isEmpty else { return [] }
        var includedIndices = Set<Int>()
        for (idx, atom) in chapterAtoms.enumerated() where unknownIDs.contains(atom.id) {
            if idx > 0 { includedIndices.insert(idx - 1) }
            includedIndices.insert(idx)
            if idx + 1 < chapterAtoms.count { includedIndices.insert(idx + 1) }
        }
        return chapterAtoms.enumerated().compactMap { idx, atom in
            includedIndices.contains(idx) ? atom : nil
        }
    }

    /// 当前聚焦的待确认说话人在全书待确认列表中的 1-based 序号。
    public var currentUnknownSpeakerGlobalIndex: Int? {
        guard !allUnknownAnnotations.isEmpty else { return nil }
        if let focusedID = focusedUnknownAtomID,
           let idx = allUnknownAnnotations.firstIndex(where: { $0.atomID == focusedID })
        {
            return idx + 1
        }
        if let firstInChapter = unknownAnnotationsInSelectedChapter.first,
           let idx = allUnknownAnnotations.firstIndex(where: { $0.atomID == firstInChapter.atomID })
        {
            return idx + 1
        }
        return 1
    }

    public var isAuditionConfirmedForSelectedBook: Bool {
        guard let book = selectedBook else { return false }
        return book.confirmedCastRevisionID != nil && book.confirmedAuditionVoiceSetDigest != nil
    }

    public var isProductionBusy: Bool {
        isProducing || isPausingProduction
    }

    public var selectedBookProductionProgress: AudiobookProductionProgress? {
        guard let book = selectedBook else { return nil }
        if let productionProgress, productionProgress.bookID == book.id { return productionProgress }
        var saved = selectedProductionCheckpoint?.progress
        if book.productionState == .paused { saved?.state = .paused }
        return saved
    }

    public var canEditChapterStructure: Bool {
        guard let book = selectedBook,
              book.analysisState == .notStarted,
              book.productionState == .idle,
              book.currentProductionRevisionID == nil,
              !isAnalyzing,
              !isProductionBusy,
              !isEditingChapterLayout,
              !isLoadingChapterDetails
        else { return false }
        return true
    }

    public var canRenameSelectedChapter: Bool {
        selectedBook != nil
            && selectedChapterID.map { id in chapters.contains(where: { $0.id == id }) } == true
            && !isAnalyzing
            && !isProductionBusy
            && !isEditingChapterLayout
            && !isLoadingChapterDetails
    }

    public var chapterStructureEditingStatus: String {
        guard let book = selectedBook else { return "请先打开一本书。" }
        if isEditingChapterLayout { return "正在保存章节更改…" }
        if isAnalyzing || book.analysisState != .notStarted {
            return "全书分析开始后不能拆分或合并章节；请在分析前整理目录。"
        }
        if isProductionBusy || book.productionState != .idle || book.currentProductionRevisionID != nil {
            return "已有制作任务或章节音频，不能调整章节范围；重命名仍会保留现有音频。"
        }
        if isLoadingChapterDetails { return "正在读取本章，请稍候。" }
        return "拆分前先在原文勾选一个中间段落；合并会保留上一章名称。目录调整不会改写原文。"
    }

    public var canMergeSelectedChapterWithPrevious: Bool {
        guard canEditChapterStructure,
              let selectedChapterID,
              let index = chapters.firstIndex(where: { $0.id == selectedChapterID }),
              index > chapters.startIndex
        else { return false }
        return chapters[index - 1].sourceRange.upperBound == chapters[index].sourceRange.lowerBound
    }

    public var canSplitSelectedChapterBeforeSelectedAtom: Bool {
        guard canEditChapterStructure,
              selectedAtomIDs.count == 1,
              let selectedChapterID,
              let chapter = chapters.first(where: { $0.id == selectedChapterID }),
              let atomID = selectedAtomIDs.first,
              let atom = chapterAtoms.first(where: { $0.id == atomID }),
              atom.kind != .formatting
        else { return false }
        return atom.sourceRange.lowerBound > chapter.sourceRange.lowerBound
            && atom.sourceRange.lowerBound < chapter.sourceRange.upperBound
    }

    public func canRegenerateFragment(_ fragmentID: UUID) -> Bool {
        guard !isProductionBusy,
              productionRunID == nil,
              !isAnalyzing,
              !isEditingChapterLayout,
              !isLoadingChapterDetails,
              let book = selectedBook,
              book.analysisState == .allWindowsValidated,
              isAuditionConfirmedForSelectedBook,
              let selectedChapterID,
              let selectedChapter = chapters.first(where: { $0.id == selectedChapterID }),
              selectedChapter.bookID == book.id,
              !selectedChapter.isSkipped,
              selectedChapter.currentChapterRevisionID != nil,
              let fragment = chapterFragments.first(where: { $0.id == fragmentID }),
              fragment.bookID == book.id,
              fragment.chapterID == selectedChapterID,
              let readiness = chapterReadinessByID[selectedChapterID]
        else { return false }
        return readiness != .awaitingGlobalAnalysis
            && readiness != .awaitingCastConfirmation
            && readiness != .blockedByUnknownSpeakers
            && readiness != .producing
    }

    public func isRegeneratingFragment(_ fragmentID: UUID) -> Bool {
        isProducing
            && productionBookID == selectedBook?.id
            && productionFragmentID == fragmentID
    }

    public func isProductionBlocked(for bookID: UUID) -> Bool {
        isProductionBusy && productionBookID != bookID
    }

    public var isSelectedBookBlockedByProduction: Bool {
        guard let bookID = selectedBook?.id else { return false }
        return isProductionBlocked(for: bookID)
    }

    public func primaryActionTitle(_ action: PrimaryBookAction, for bookID: UUID) -> String {
        if action == .pauseProduction, isPausingProduction, productionBookID == bookID {
            return "正在暂停…"
        }
        if isProductionBlocked(for: bookID),
           (action == .makeConfirmedChapters || action == .resumeProduction)
        {
            return "另一部有声书正在制作"
        }
        return action.title
    }

    public func chapterProductionButtonTitle(for chapterID: UUID?) -> String {
        if isSelectedBookBlockedByProduction {
            return "另一部有声书正在制作"
        }
        guard let chapterID,
              let chapter = chapters.first(where: { $0.id == chapterID }),
              chapter.currentChapterRevisionID != nil
        else {
            return "生成本章音频"
        }
        return "更新本章音频"
    }

    /// 严格唯一主动作推导：任何状态下只突出下一步最合理的动作。
    public func nextPrimaryAction(for summary: AudiobookBookSummary) -> PrimaryBookAction {
        let book = summary.book
        if isAnalyzing && selectedBook?.id == book.id {
            return .pauseAnalysis
        }
        if isPausingProduction && productionBookID == book.id {
            return .pauseProduction
        }
        if isProducing && productionBookID == book.id {
            return .pauseProduction
        }
        switch book.analysisState {
        case .notStarted, .failed:
            return .analyzeWholeBook
        case .running, .paused:
            return .resumeAnalysis
        case .allWindowsValidated:
            break
        }

        if book.confirmedCastRevisionID == nil || book.confirmedAuditionVoiceSetDigest == nil {
            return .confirmCastAndVoices
        }
        if summary.unknownSpeakerCount > 0 && summary.completedChapterCount == 0 {
            return .confirmSpeakers(count: summary.unknownSpeakerCount)
        }
        if book.productionState == .paused {
            return .resumeProduction
        }
        if summary.completedChapterCount < summary.totalChapterCount {
            return .makeConfirmedChapters
        }
        return .continueListening
    }

    public var selectedBookPrimaryAction: PrimaryBookAction? {
        guard let book = selectedBook else { return nil }
        if let summary = shelfBooks.first(where: { $0.id == book.id }) {
            return nextPrimaryAction(for: summary)
        }
        let fallbackSummary = AudiobookBookSummary(
            book: book,
            totalChapterCount: chapters.count,
            completedChapterCount: chapters.filter { $0.currentChapterRevisionID != nil }.count,
            unknownSpeakerCount: unknownAnnotationsInSelectedChapter.count,
            characterCount: characters.count
        )
        return nextPrimaryAction(for: fallbackSummary)
    }

    // MARK: - Shelf & Import Lifecycle

    private func recoverStoreIfNeeded(_ store: AudiobookProjectStore) async throws {
        guard !hasRecoveredOnBootstrap else { return }

        let requestID: UUID
        let task: Task<Void, Error>
        if let inFlight = storeRecoveryTask, let inFlightID = storeRecoveryRequestID {
            requestID = inFlightID
            task = inFlight
        } else {
            requestID = UUID()
            let recoveryTask = Task<Void, Error> {
                _ = try await store.recover()
            }
            storeRecoveryRequestID = requestID
            storeRecoveryTask = recoveryTask
            task = recoveryTask
        }

        do {
            try await task.value
            hasRecoveredOnBootstrap = true
            if storeRecoveryRequestID == requestID {
                storeRecoveryTask = nil
                storeRecoveryRequestID = nil
            }
        } catch {
            if storeRecoveryRequestID == requestID {
                storeRecoveryTask = nil
                storeRecoveryRequestID = nil
            }
            throw error
        }
    }

    public func refreshShelf() async {
        bootstrapIfPossible()
        guard let store else { return }
        do {
            try await recoverStoreIfNeeded(store)
            shelfBooks = try await store.listBooks()
            trashedBooks = try await store.listTrashedBooks()
            if let exp = exportController {
                exportCapabilities = await exp.checkCapabilities()
            }
            if catalogVoices.isEmpty {
                _ = await refreshAvailableVoices()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func prepareImport(fileURL: URL, encoding: AudiobookTextEncoding? = nil) async {
        do {
            let preview = fileURL.pathExtension.lowercased() == "epub"
                ? try await AudiobookTXTImporter.prepareEPUB(fileURL: fileURL)
                : try await AudiobookTXTImporter.prepare(fileURL: fileURL, encoding: encoding)
            importFileURL = fileURL
            importPreview = preview
            importErrorMessage = nil
            errorMessage = nil
            isShowingImportSheet = true
        } catch {
            errorMessage = error.localizedDescription
            importErrorMessage = error.localizedDescription
            // 已打开预览后切换编码失败时，保留预览和用户填写内容，错误显示在导入面板内而不是被遮挡。
            if importPreview == nil {
                isShowingImportSheet = false
            }
        }
    }

    public func confirmImport() async {
        bootstrapIfPossible()
        guard let store, let preview = importPreview else { return }
        guard preview.canConfirmImport else {
            errorMessage = "请先核对重复内容，并确认保留后再导入。"
            return
        }
        do {
            let bookID = try await store.importBook(preview)
            isShowingImportSheet = false
            importPreview = nil
            importErrorMessage = nil
            await refreshShelf()
            await openBook(bookID)
        } catch {
            errorMessage = error.localizedDescription
            importErrorMessage = error.localizedDescription
        }
    }

    public func openBook(_ bookID: UUID) async {
        cancelWorkspaceRefresh()
        await openBookWorkspace(bookID, retryStaleInput: true)
    }

    private func openBookWorkspace(_ bookID: UUID, retryStaleInput: Bool) async {
        bootstrapIfPossible()
        guard let store else { return }
        invalidateCastingAudition()
        if let plan = pendingCastingPlan, plan.bookID != bookID {
            pendingCastingPlan = nil
            castingPlanNeedsRefresh = false
        }
        chapterSelectionLoad.reset()
        readinessSelectionLoad.reset()
        let preferredChapterID = selectedChapterID
        let preferredFragmentID = selectedFragmentID
        do {
            guard let snapshot = try await bookSelectionLoad.load(id: bookID.uuidString, operation: {
                await self.voiceCatalogModel.startObserving()
                await self.voiceCatalogModel.refresh()
                try Task.checkCancellation()
                return try await self.readBookWorkspaceSnapshot(
                    bookID: bookID,
                    preferredChapterID: preferredChapterID,
                    preferredFragmentID: preferredFragmentID,
                    store: store
                )
            }) else { return }

            errorMessage = nil
            if snapshot.book.analysisState == .failed, let failure = snapshot.book.analysisFailure {
                bannerMessage = "上次分析未完成：\(failure.message)"
            }
            let latestChapterSelection = selectedBook?.id == bookID
                ? selectedChapterID.flatMap { chapterID in
                    snapshot.chapters.contains(where: { $0.id == chapterID }) ? chapterID : nil
                }
                : nil
            let committedChapterID = latestChapterSelection ?? snapshot.chapterDetails.chapterID
            let mustReloadChapterDetails = committedChapterID != snapshot.chapterDetails.chapterID
            selectedBook = snapshot.book
            await reloadExportCover(for: bookID)
            chapters = snapshot.chapters
            roleStatsByID = snapshot.roleStatsByID
            characters = snapshot.characters
            voiceBindings = snapshot.voiceBindings
            await normalizeLegacyUnstratifiedCharactersIfNeeded(bookID: bookID)
            exportRecords = snapshot.exportRecords
            unknownSpeakerProjectionGeneration &+= 1
            applyUnknownSpeakerIndex(snapshot.unknownSpeakers)
            if let currentRoleID = selectedRoleID,
               !snapshot.characters.contains(where: { $0.id == currentRoleID })
            {
                self.selectedRoleID = snapshot.characters.first?.id
            } else if selectedRoleID == nil {
                selectedRoleID = snapshot.characters.first?.id
            }
            isSuppressingChapterAutoReload = true
            selectedChapterID = committedChapterID
            isSuppressingChapterAutoReload = false
            applyChapterDetails(mustReloadChapterDetails ? .empty : snapshot.chapterDetails)
            isLoadingChapterDetails = mustReloadChapterDetails
            resumePlan = snapshot.resumePlan
            selectedProductionCheckpoint = snapshot.productionCheckpoint
            if !isProductionBusy {
                productionProgress = snapshot.productionCheckpoint?.progress
                if snapshot.book.productionState == .paused {
                    productionProgress?.state = .paused
                }
            }
            chapterReadinessByID = snapshot.chapterReadinessByID
            selectedAtomIDs.removeAll()
            surfaceMode = .workspace
            workbenchTab = snapshot.workbenchTab
            _ = await refreshAvailableVoices()
            if mustReloadChapterDetails {
                await reloadSelectedChapterDetails()
            }
        } catch {
            guard bookSelectionLoad.requestedID == bookID.uuidString else { return }
            if retryStaleInput, error is AudiobookWorkspaceError {
                scheduleWorkspaceRefresh(bookID: bookID, selection: bookSelectionLoad.requestGeneration)
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleWorkspaceRefresh(bookID: UUID, selection: UUID) {
        cancelWorkspaceRefresh()
        let id = UUID(), delay = workspaceRefreshDelay
        workspaceRefreshID = id
        workspaceRefreshTask = Task { [weak self] in
            defer {
                if self?.workspaceRefreshID == id {
                    self?.workspaceRefreshTask = nil
                    self?.workspaceRefreshID = nil
                }
            }
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled,
                  self.bookSelectionLoad.requestGeneration == selection,
                  self.bookSelectionLoad.requestedID == bookID.uuidString else { return }
            await self.openBookWorkspace(bookID, retryStaleInput: false)
        }
    }

    @discardableResult
    private func cancelWorkspaceRefresh() -> Task<Void, Never>? {
        let task = workspaceRefreshTask
        task?.cancel()
        workspaceRefreshTask = nil
        workspaceRefreshID = nil
        return task
    }

    public func trashBook(_ bookID: UUID) async {
        guard let store else { return }
        let title = (try? await store.book(id: bookID))?.title
            ?? shelfBooks.first(where: { $0.id == bookID })?.book.title
            ?? (selectedBook?.id == bookID ? selectedBook?.title : nil)
        do {
            if bookSelectionLoad.requestedID == bookID.uuidString {
                cancelWorkspaceRefresh()
                bookSelectionLoad.reset()
            }
            if selectedBook?.id == bookID {
                invalidateCastingAudition()
                await listeningController?.leaveWorkshop()
            }
            try await store.trashBook(id: bookID)
            if selectedBook?.id == bookID {
                selectedBook = nil
                surfaceMode = .shelf
                exportCover = nil
                exportCoverPreviewURL = nil
                exportCoverErrorMessage = nil
            }
            await refreshShelf()
            lastTrashedBookID = bookID
            lastTrashedBookTitle = title
            trashUndoMessage = "《\(title ?? "该书")》已移入有声书废纸篓，原始 TXT 与已导出的外部文件不受影响。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func restoreTrashedBook(_ bookID: UUID) async {
        guard let store else { return }
        do {
            try await store.restoreTrashedBook(id: bookID)
            if lastTrashedBookID == bookID {
                lastTrashedBookID = nil
                lastTrashedBookTitle = nil
                trashUndoMessage = nil
            }
            await refreshShelf()
            bannerMessage = "已从废纸篓恢复书籍及其音频片段。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 书架上的「撤销」入口；只恢复刚刚移入废纸篓的那一本，不触碰更早的作品。
    public func undoLastTrash() async {
        guard let bookID = lastTrashedBookID else { return }
        await restoreTrashedBook(bookID)
    }

    // MARK: - Analysis Lifecycle

    public func beginAnalysis(_ bookID: UUID? = nil) {
        let targetID = bookID ?? selectedBook?.id
        guard let targetID, let pipeline = analysisPipeline else { return }
        guard !isEditingChapterLayout else {
            errorMessage = "正在整理章节目录，请完成后再开始分析。"
            return
        }
        analysisTask?.cancel()
        let snapshot = dependencies.resolveAnalysisSnapshot(analysisGeneration)
        isAnalyzing = true
        errorMessage = nil
        if selectedBook?.id == targetID {
            selectedBook?.analysisState = .running
        }
        installAnalysisProgressProjection(for: targetID, pipeline: pipeline)
        let installEpoch = analysisInstallEpoch
        let runSink = makeAnalysisProgressSink(for: targetID, installEpoch: installEpoch)

        analysisTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var summary = try await pipeline.run(bookID: targetID, config: snapshot, progressSink: runSink)
                guard self.analysisInstallEpoch == installEpoch else { return }
                var resolvedInSecondPass = 0
                if summary.unknownSpeakerCount > 0 {
                    self.isResolvingUnknownSpeakers = true
                    if let secondPass = try? await pipeline.resolveUnknownSpeakers(bookID: targetID, config: snapshot) {
                        resolvedInSecondPass = secondPass.resolvedCount
                        summary.unknownSpeakerCount = secondPass.remainingUnknownCount
                    }
                    self.isResolvingUnknownSpeakers = false
                }
                self.analysisSummary = summary
                self.isAnalyzing = false
                self.stopAnalysisClock()
                let createdArchetypeVoices = await self.ensureSixArchetypeVoicesForBook(for: targetID, quietBanner: true)
                let createdLeadVoices = await self.createExclusiveVoicesForLeadCharacters(for: targetID, quietBanner: true)
                _ = await self.refreshAvailableVoices()
                await self.autoAssignRecommendedVoices(for: targetID)
                await self.refreshShelf()
                var autoConfirmSucceeded = false
                if self.selectedBook?.id == targetID {
                    await self.openBook(targetID)
                    if summary.unknownSpeakerCount > 0 {
                        await self.jumpToFirstUnknownSpeaker()
                    } else {
                        autoConfirmSucceeded = await self.confirmCastAndAudition()
                    }
                }
                var notes: [String] = ["全书分析已完成（共 \(summary.completedWindows) 个窗口"]
                if resolvedInSecondPass > 0 {
                    notes.append("AI 二次复核自动消解 \(resolvedInSecondPass) 处疑难对白")
                }
                if createdArchetypeVoices > 0 {
                    notes.append("已补全 \(createdArchetypeVoices) 类小说群像音色")
                }
                if let leadSummary = self.lastLeadVoiceCreationSummary, leadSummary.attemptedCount > 0 {
                    if leadSummary.fallbacks.isEmpty {
                        notes.append("已为 \(leadSummary.succeededCount) 名主要角色生成专属音色")
                    } else if leadSummary.succeededCount > 0 {
                        let names = leadSummary.fallbacks.map(\.roleName).joined(separator: "、")
                        let firstArchetype = (leadSummary.fallbacks.first?.fallbackArchetypeName ?? "群像") + "群像音色"
                        notes.append("已为 \(leadSummary.succeededCount) 名主角生成专属音色，\(leadSummary.fallbacks.count) 名角色（\(names)）已回退为\(firstArchetype)")
                    } else {
                        let names = leadSummary.fallbacks.map(\.roleName).joined(separator: "、")
                        let firstArchetype = (leadSummary.fallbacks.first?.fallbackArchetypeName ?? "群像") + "群像音色"
                        notes.append("\(leadSummary.fallbacks.count) 名角色（\(names)）已回退为\(firstArchetype)")
                    }
                } else if createdLeadVoices > 0 {
                    notes.append("已为 \(createdLeadVoices) 名主要角色生成专属音色")
                }
                if summary.unknownSpeakerCount == 0 {
                    if autoConfirmSucceeded && (self.selectedBook?.confirmedAuditionVoiceSetDigest != nil) {
                        notes.append("角色与音色已自动锁定，可直接开始制作章节）")
                    } else {
                        notes.append("配声完成但自动锁定未确认，请在右侧检查声音）")
                    }
                } else {
                    notes.append("剩余待人工确认 \(summary.unknownSpeakerCount) 处）")
                }
                if self.errorMessage == nil {
                    self.bannerMessage = notes.joined(separator: "，") + "。"
                }
            } catch {
                guard self.analysisInstallEpoch == installEpoch else { return }
                let failureDescription = error.localizedDescription
                self.isResolvingUnknownSpeakers = false
                self.isAnalyzing = false
                self.stopAnalysisClock()
                await self.refreshShelf()
                if self.selectedBook?.id == targetID {
                    await self.openBook(targetID)
                }
                self.errorMessage = failureDescription
            }
        }
    }

    public func pauseAnalysis() async {
        guard let bookID = selectedBook?.id, let pipeline = analysisPipeline else { return }
        analysisGeneration += 1
        analysisInstallEpoch += 1
        await pipeline.cancel(bookID: bookID)
        analysisTask?.cancel()
        isAnalyzing = false
        stopAnalysisClock()
        await refreshShelf()
        await openBook(bookID)
        bannerMessage = "全书分析已暂停，已完成的窗口检查点已保存。"
    }

    // MARK: - Analysis Progress Projection

    /// 进度事件收敛：run 外事件直接丢弃；首事件建快照，后续事件折叠。
    /// 该回调运行在管线侧任意线程，经 Task 跳回 MainActor 后再写 @Observable 字段。
    ///
    /// sink 随 `run(bookID:config:progressSink:)` 一起传入，不经过先装后跑的两步调用，
    /// 因此不存在安装竞态：run 发出的首个事件必然落到本次的投影上。
    private func installAnalysisProgressProjection(for bookID: UUID, pipeline: AudiobookAnalysisPipeline) {
        analysisInstallEpoch += 1
        let installEpoch = analysisInstallEpoch
        analysisProgress = nil
        analysisEventBuffer.reset()
        startAnalysisClock()
        // 兼容兜底：旧路径（不传 sink 的 run）仍走 actor 上的安装值。
        let sink = makeAnalysisProgressSink(for: bookID, installEpoch: installEpoch)
        Task {
            await pipeline.setProgressSink(sink)
        }
    }

    private func makeAnalysisProgressSink(
        for bookID: UUID,
        installEpoch: Int
    ) -> AudiobookAnalysisProgressSink {
        AudiobookAnalysisProgressSink { [weak self] event in
            guard event.bookID == bookID else { return }
            Task { @MainActor [weak self] in
                guard let self, self.analysisInstallEpoch == installEpoch else { return }
                self.applyAnalysisEvent(event)
            }
        }
    }

    private func applyAnalysisEvent(_ event: AudiobookAnalysisEvent) {
        analysisEventBuffer.append(event)
        if var progress = analysisProgress {
            progress.apply(event)
            analysisProgress = progress
        } else {
            analysisProgress = AudiobookAnalysisProgress(firstEvent: event)
        }
        if event.kind == .runEnded {
            stopAnalysisClock()
        }
    }

    /// Only lifecycle boundaries are observed. The visible rail owns its local timeline.
    public private(set) var analysisClockStoppedAt: Date? = Date()
    private func startAnalysisClock() { analysisClockStoppedAt = nil }
    private func stopAnalysisClock() {
        if analysisClockStoppedAt == nil { analysisClockStoppedAt = Date() }
    }

    /// 从后端能力快照刷新当前全部可用音色目录（包含自建/克隆/六类群像/专属音色与系统预置音色）。
    @discardableResult
    public func refreshAvailableVoices() async -> [SafeVoiceEntry] {
        if let fetched = (try? await dependencies.speechRenderer.fetchEffectiveCapabilities())?.voices,
           !fetched.isEmpty
        {
            catalogVoices = fetched.filter(\.available)
        }
        await voiceCatalogModel.refresh()
        return catalogVoices
    }

    /// 合并外部传入的音色快照与工作坊缓存的音色目录，去重并按「本书专属 -> 六类群像/自建定制 -> 系统默认」排序，确保音色选择器不局限于 10 个系统默认音色。
    public func mergedAvailableVoices(externalVoices: [SafeVoiceEntry] = []) -> [SafeVoiceEntry] {
        var byID: [String: SafeVoiceEntry] = [:]
        for voice in externalVoices where voice.available {
            byID[voice.id] = voice
        }
        for voice in catalogVoices where voice.available {
            byID[voice.id] = voice
        }
        let activeBookID = selectedBook?.id
        let catalog = voiceCatalogModel.snapshot
        let metadataMap = catalog.state.metadataByVoiceID
        return byID.values.filter { voice in
            if let activeBookID { return catalog.permits(voice, bookID: activeBookID) }
            return catalog.permitsSurface(voice, bookID: nil)
        }.sorted { lhs, rhs in
            let metaL = metadataMap[lhs.id]
            let metaR = metadataMap[rhs.id]
            let isBookExL = (metaL?.visibilityScope == .bookExclusive && metaL?.originBookID == activeBookID)
            let isBookExR = (metaR?.visibilityScope == .bookExclusive && metaR?.originBookID == activeBookID)
            if isBookExL != isBookExR { return isBookExL }

            let isCustomL = !Self.builtInSystemVoiceIDs.contains(lhs.id.lowercased()) && lhs.id.lowercased() != "v-narrator"
            let isCustomR = !Self.builtInSystemVoiceIDs.contains(rhs.id.lowercased()) && rhs.id.lowercased() != "v-narrator"
            if isCustomL != isCustomR { return isCustomL }

            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// 为尚未配声的角色生成方案；保留已有绑定，共享风险须另行确认，默认不启用微语速。
    public private(set) var pendingCastingPlan: AudiobookCastingPlan?

    public func previewRecommendedVoices(strategy: AudiobookCastingStrategy = .sceneAware) async {
        guard let bookID = selectedBook?.id, let store else { return }
        do {
            let snapshot = try await dependencies.speechRenderer.fetchEffectiveCapabilities()
            guard selectedBook?.id == bookID else { return }
            let plan = try await store.prepareCastingPlan(bookID: bookID, snapshot: snapshot, catalog: try await voiceCatalogModel.requireFreshSnapshot(), strategy: strategy)
            guard selectedBook?.id == bookID else { return }
            invalidateCastingAudition()
            pendingCastingPlan = plan
            castingPlanNeedsRefresh = false
            errorMessage = plan.issues.first(where: \.isBlocking)?.nextAction
        } catch { errorMessage = error.localizedDescription }
    }

    public func previewVoiceReplacement(_ bindings: [AudiobookVoiceBinding]) async {
        guard let bookID = selectedBook?.id, let store else { return }
        do {
            let snapshot = try await dependencies.speechRenderer.fetchEffectiveCapabilities()
            let plan = try await store.prepareVoiceReplacement(bookID: bookID, bindings: bindings, snapshot: snapshot, catalog: try await voiceCatalogModel.requireFreshSnapshot())
            guard selectedBook?.id == bookID else { return }
            invalidateCastingAudition()
            pendingCastingPlan = plan
            castingPlanNeedsRefresh = false
        } catch { errorMessage = error.localizedDescription }
    }

    public func undoLastCastingChange() async {
        guard let bookID = selectedBook?.id, let castController else { return }
        do {
            try await castController.undoLastCastingChange(bookID: bookID)
            pendingCastingPlan = nil; castingAudition = nil
            await openBook(bookID)
            bannerMessage = "已恢复上次配声；已采用音频和历史候选均已保留。"
        } catch { errorMessage = error.localizedDescription }
    }

    public func prepareCastingAudition(kind: AudiobookCastingAudition.Kind, roleID: UUID, comparisonVoiceIDs: [String] = []) async {
        guard let book = selectedBook, let store else { return }
        let plan = pendingCastingPlan
        guard plan == nil || plan?.bookID == book.id else { return }
        await voiceCatalogModel.refresh()
        invalidateCastingAudition()
        let generation = auditionPlaybackGeneration
        let catalogRevision = voiceCatalogModel.snapshot.revision
        let savedBindings = voiceBindings
        do {
            let targetBookID = book.id
            let effectiveSnapshot: EffectiveCapabilitySnapshot
            let effectiveCatalog: VoiceCatalogSnapshot
            let effectiveBindings: [UUID: AudiobookVoiceBinding]
            let planDigest: String

            if let plan {
                try await store.validateCastingPlanInput(plan)
                guard voiceCatalogModel.snapshot.revision == plan.voiceCatalogRevision else { throw AudiobookCastError.castRevisionMismatch }
                effectiveSnapshot = plan.snapshot
                effectiveCatalog = plan.catalog
                effectiveBindings = plan.proposedBindings
                planDigest = plan.inputDigest
            } else {
                effectiveSnapshot = try await dependencies.speechRenderer.fetchEffectiveCapabilities()
                effectiveCatalog = try await voiceCatalogModel.requireFreshSnapshot()
                effectiveBindings = savedBindings
                planDigest = "saved-bindings-\(targetBookID.uuidString)"
            }

            let source = try await store.sourceIndex(for: targetBookID)
            let annotations = try await store.annotations(for: targetBookID).sorted { $0.sourceRange < $1.sourceRange }
            let atoms = try await store.atoms(for: targetBookID)
            let roles = try await store.characters(for: targetBookID)
            func item(roleID: UUID, voiceID: String, range: AudiobookSourceRange) throws -> AudiobookCastingAudition.Item {
                guard let start = source.scalarIndex(forByteOffset: range.lowerBound),
                      let end = source.scalarIndex(forByteOffset: range.upperBound), end > start,
                      let voice = effectiveSnapshot.voices.first(where: { $0.id == voiceID }), effectiveCatalog.permits(voice, bookID: targetBookID),
                      let options = SpeechRailCapabilityRevisionSelector.creatorRequestOptions(voiceID: voiceID, in: effectiveSnapshot),
                      let model = options.expectedModelRevision else { throw ServiceAPIClientError.invalidContract("audition_unavailable") }
                let excerpt = AudiobookSourceRange(lowerBound: range.lowerBound, upperBound: source.scalarByteOffsets[min(end, start + 240)])
                let binding = effectiveBindings[roleID].flatMap { $0.voiceID == voiceID ? $0 : nil }
                    ?? .init(roleID: roleID, voiceID: voiceID, voiceRevision: options.expectedVoiceRevision, modelRevision: model)
                try AudiobookCastRegistry.validateRenderBinding(binding, snapshot: effectiveSnapshot, requireProductionReady: false)
                return .init(roleID: roleID, voiceID: voiceID, sourceRange: excerpt, text: try source.text(in: excerpt), binding: binding)
            }
            let items: [AudiobookCastingAudition.Item]
            switch kind {
            case .sameTextComparison:
                let range = annotations.first { $0.assignment.roleID == roleID }?.sourceRange
                    ?? (roles.first { $0.id == roleID }?.isNarrator == true ? atoms.first { $0.kind == .body }?.sourceRange : nil)
                    ?? atoms.first?.sourceRange
                guard let range else { throw ServiceAPIClientError.invalidContract("audition_source_missing") }
                var seen: Set<String> = []
                let voiceIDs = (comparisonVoiceIDs.isEmpty ? [effectiveBindings[roleID]?.voiceID].compactMap { $0 } : comparisonVoiceIDs)
                    .filter { seen.insert($0).inserted }.prefix(4)
                guard !voiceIDs.isEmpty else { throw ServiceAPIClientError.invalidContract("audition_voice_missing") }
                items = try voiceIDs.map { try item(roleID: roleID, voiceID: $0, range: range) }
            case .dialogueComparison:
                let narratorIDs = Set(roles.filter(\.isNarrator).map(\.id))
                let spoken = annotations.filter { row in row.assignment.roleID.map { !narratorIDs.contains($0) } ?? false }
                let graph = AudiobookSceneConflictGraph.build(characters: roles, annotations: annotations, atoms: atoms)
                var pair: [AudiobookAnnotation] = []
                for (left, right) in zip(spoken, spoken.dropFirst()) {
                    guard left.chapterID == right.chapterID, let a = left.assignment.roleID, let b = right.assignment.roleID,
                          a != b, a == roleID || b == roleID,
                          graph.edges.contains(where: { $0.kind == .directDialogue && Set([$0.roleA, $0.roleB]) == Set([a, b]) }),
                          let posA = atoms.firstIndex(where: { $0.id == left.atomID }), let posB = atoms.firstIndex(where: { $0.id == right.atomID }),
                          abs(posB - posA) <= 6 else { continue }
                    pair = [left, right]; break
                }
                guard pair.count == 2 else { throw ServiceAPIClientError.invalidContract("audition_dialogue_missing") }
                items = try pair.map { row in
                    guard let role = row.assignment.roleID, let voice = effectiveBindings[role]?.voiceID else { throw ServiceAPIClientError.invalidContract("audition_voice_missing") }
                    return try item(roleID: role, voiceID: voice, range: row.sourceRange)
                }
            }
            guard auditionPlaybackGeneration == generation,
                  selectedBook?.id == targetBookID,
                  pendingCastingPlan?.inputDigest == plan?.inputDigest,
                  voiceCatalogModel.snapshot.revision == catalogRevision,
                  plan != nil || voiceBindings == savedBindings else { return }
            castingAudition = .init(kind: kind, items: items, planDigest: planDigest)
            castingAuditionCatalogRevision = catalogRevision
            errorMessage = nil
        } catch {
            guard auditionPlaybackGeneration == generation, selectedBook?.id == book.id else { return }
            castingAudition = nil
            errorMessage = "暂时无法准备这段试听，请确认角色对白和可用声音后重新推荐。"
        }
    }

    public func playCastingAudition(itemIndex: Int) async {
        await voiceCatalogModel.refresh()
        auditionPlaybackGeneration &+= 1
        let generation = auditionPlaybackGeneration
        guard let audition = castingAudition, let store, let book = selectedBook,
              audition.items.indices.contains(itemIndex) else { return }
        guard voiceCatalogModel.snapshot.revision == castingAuditionCatalogRevision else {
            invalidateCastingAudition()
            return
        }
        let catalogRevision = castingAuditionCatalogRevision
        let plan = pendingCastingPlan
        if let plan {
            guard book.id == plan.bookID, audition.planDigest == plan.inputDigest else { return }
        } else {
            guard audition.planDigest == "saved-bindings-\(book.id.uuidString)" else { return }
        }
        do {
            if let plan {
                try await store.validateCastingPlanInput(plan)
                guard voiceCatalogModel.snapshot.revision == plan.voiceCatalogRevision else { throw AudiobookCastError.castRevisionMismatch }
            }
            guard auditionPlaybackGeneration == generation, castingAudition == audition else { return }
            let item = audition.items[itemIndex], binding = item.binding
            let snapshot = try await dependencies.speechRenderer.fetchEffectiveCapabilities()
            let catalog = try await voiceCatalogModel.requireFreshSnapshot()
            guard catalog.revision == catalogRevision,
                  let voice = snapshot.voices.first(where: { $0.id == binding.voiceID }),
                  catalog.permits(voice, bookID: book.id) else { throw VoiceCatalogError.revisionChanged }
            if let plan {
                guard voiceCatalogModel.snapshot.revision == plan.voiceCatalogRevision else { throw AudiobookCastError.castRevisionMismatch }
            }
            try AudiobookCastRegistry.validateRenderBinding(binding, snapshot: snapshot, requireProductionReady: false)
            guard auditionPlaybackGeneration == generation, castingAudition == audition else { return }
            let data = try await dependencies.speechRenderer.renderAudition(.init(
                bookID: book.id,
                text: item.text,
                voiceID: binding.voiceID,
                speed: binding.allowedSpeed,
                expectedVoiceRevision: binding.voiceRevision,
                expectedModelRevision: binding.modelRevision,
                seed: binding.callerSeed
            ))
            try Task.checkCancellation()
            _ = try await voiceCatalogModel.requireFreshSnapshot()
            guard auditionPlaybackGeneration == generation, castingAudition == audition,
                  selectedBook?.id == book.id,
                  voiceCatalogModel.snapshot.revision == catalogRevision else { return }
            if let plan {
                try await store.validateCastingPlanInput(plan)
                guard selectedBook?.id == plan.bookID, pendingCastingPlan?.inputDigest == plan.inputDigest,
                      voiceCatalogModel.snapshot.revision == plan.voiceCatalogRevision else { throw AudiobookCastError.castRevisionMismatch }
            }
            guard auditionPlaybackGeneration == generation, castingAudition == audition else { return }
            try playbackOwner.play(data: data, target: .dubbingCandidate("casting-audition:\(audition.planDigest):\(itemIndex)"))
            errorMessage = nil
        } catch is CancellationError {
            // 用户主动取消，不展示报错
        } catch {
            guard auditionPlaybackGeneration == generation else { return }
            errorMessage = "试听未完成，声音或配声方案可能已变化，请刷新后重试。"
        }
    }

    public func stopAuditionPlayback() {
        auditionPlaybackGeneration &+= 1
        if case let .dubbingCandidate(tag) = playbackOwner.target,
           tag.hasPrefix("casting-audition:") {
            playbackOwner.stop()
        }
    }

    private func invalidateCastingAudition() {
        stopAuditionPlayback()
        castingAudition = nil
        castingAuditionCatalogRevision = nil
    }

    public func isAuditionPlaying(for roleID: UUID) -> Bool {
        guard playbackOwner.isPlaying, let target = playbackOwner.target else { return false }
        switch target {
        case .dubbingCandidate(let tag):
            guard let audition = castingAudition else { return false }
            return audition.items.contains(where: { $0.roleID == roleID && tag.hasPrefix("casting-audition:\(audition.planDigest):") })
        default:
            return false
        }
    }

    /// 当检测到存量已分析书籍因早期版本将全部非旁白角色置为 `isMajor == true && !allowSharedMinorVoice` 时，自动按对白分布修复主次分层，解除配声容量死锁。
    private func normalizeLegacyUnstratifiedCharactersIfNeeded(
        bookID: UUID,
        availableVoiceCount: Int? = nil
    ) async {
        guard let store else { return }
        let loaded: [AudiobookCharacter]
        let annotations: [AudiobookAnnotation]
        do {
            loaded = try await store.characters(for: bookID)
            annotations = try await store.annotations(for: bookID)
        } catch {
            if selectedBook?.id == bookID {
                errorMessage = "无法读取存量角色分层，已保留原有数据。请重试打开此书。"
            }
            return
        }
        let nonNarrators = loaded.filter { !$0.isNarrator }
        guard nonNarrators.count > 6,
              nonNarrators.allSatisfy({ $0.isMajor && !$0.allowSharedMinorVoice && $0.voicePolicy == nil && $0.manualTier == nil }),
              !annotations.isEmpty
        else { return }
        let effectiveVoiceCount = availableVoiceCount ?? (catalogVoices.isEmpty ? 6 : catalogVoices.count)
        let stratified = AudiobookCastRegistry.refreshCharacterMajorStatusAndOrder(
            characters: loaded,
            annotations: annotations,
            availableVoiceCount: effectiveVoiceCount
        )
        guard stratified != loaded else { return }
        do {
            try await store.saveCharacters(bookID: bookID, characters: stratified)
        } catch {
            if selectedBook?.id == bookID {
                errorMessage = "存量角色分层修复未能保存，原有数据仍保留。请重试智能配声。"
            }
            return
        }
        if selectedBook?.id == bookID {
            characters = stratified
        }
    }

    public func autoAssignRecommendedVoices(
        for bookID: UUID? = nil,
        availableVoices: [SafeVoiceEntry]? = nil,
        consentsToSharedMinorVoices: Bool = true
    ) async {
        let targetID = bookID ?? selectedBook?.id
        guard let targetID, let store, let castController else { return }
        do {
            let snapshot = try await dependencies.speechRenderer.fetchEffectiveCapabilities()
            await normalizeLegacyUnstratifiedCharactersIfNeeded(
                bookID: targetID,
                availableVoiceCount: snapshot.voices.filter(\.available).count
            )
            let catalog = try await voiceCatalogModel.requireFreshSnapshot()
            let plan = try await store.prepareCastingPlan(bookID: targetID, snapshot: snapshot, catalog: catalog)
            guard plan.isApplicable else {
                pendingCastingPlan = plan
                errorMessage = (plan.issues.first(where: \.isBlocking) ?? plan.issues.first(where: { $0.severity == .warning }))?.nextAction ?? "请先处理尚未完成的选角。"
                return
            }
            let sharedVoiceConsentIDs = Set(
                plan.issues
                    .filter { $0.code == .sharedVoiceConsentRequired }
                    .map(\.id)
            )
            let acknowledgedIssueIDs = consentsToSharedMinorVoices
                ? plan.requiredAcknowledgements.union(sharedVoiceConsentIDs)
                : []
            guard plan.requiredAcknowledgements.isSubset(of: acknowledgedIssueIDs) else {
                pendingCastingPlan = plan
                errorMessage = "智能配声建议需要你检查并确认共享音色或同场角色风险后，才会写入。"
                return
            }
            try await castController.applyCastingPlan(
                bookID: targetID,
                plan: plan,
                acknowledgedIssueIDs: acknowledgedIssueIDs
            )
            pendingCastingPlan = nil
            errorMessage = nil
            if selectedBook?.id == targetID {
                let loadedCharacters = try await store.characters(for: targetID)
                let loadedBindings = try await store.voiceBindings(for: targetID)
                let loadedBook = try await store.book(id: targetID)
                let annotations = try await store.annotations(for: targetID)
                let stats = try await AudiobookWorkspaceProjection.roleStatistics(
                    characters: loadedCharacters, annotations: annotations, availableVoiceCount: plan.eligibleVoiceCount
                ).statsByRoleID
                guard selectedBook?.id == targetID else { return }
                characters = loadedCharacters
                voiceBindings = loadedBindings
                selectedBook = loadedBook
                roleStatsByID = stats
                await refreshChapterReadinessMap(for: targetID)
                if totalUnknownSpeakerCount == 0 {
                    _ = await confirmCastAndAudition(switchToProduction: false)
                }
            }
        } catch { errorMessage = "配声方案未应用，请刷新后重新确认。" }
    }

    public func applyPendingCastingPlan(acknowledgedIssueIDs: Set<UUID>) async {
        guard let plan = pendingCastingPlan, let castController, selectedBook?.id == plan.bookID else { errorMessage = "请先重新推荐声音。"; return }
        do {
            try await castController.applyCastingPlan(bookID: plan.bookID, plan: plan, acknowledgedIssueIDs: acknowledgedIssueIDs)
            pendingCastingPlan = nil
            await openBook(plan.bookID)
        } catch { errorMessage = "配声方案已失效或仍需确认，请重新推荐。" }
    }

    public func resolvedRoleTier(for role: AudiobookCharacter) -> AudiobookRoleTier {
        if role.isNarrator { return .narrator }
        if let manual = role.manualTier { return manual }
        if let statTier = roleStatsByID[role.id]?.tier { return statTier }
        return role.allowSharedMinorVoice ? .supporting : (role.isMajor ? .lead : .ensemble)
    }

    public func isSilentCharacter(_ role: AudiobookCharacter) -> Bool {
        guard !role.isNarrator else { return false }
        guard selectedBook?.analysisState == .allWindowsValidated,
              let stat = roleStatsByID[role.id]
        else { return false }
        return stat.dialogueAtomCount == 0
    }

    public var activeSpeakingCharacters: [AudiobookCharacter] {
        characters.filter { !isSilentCharacter($0) }
    }

    public var silentCharacterCount: Int {
        max(0, characters.count - activeSpeakingCharacters.count)
    }

    public var leadCharacterCount: Int {
        activeSpeakingCharacters.filter { role in
            let tier = resolvedRoleTier(for: role)
            return tier == .narrator || tier == .lead
        }.count
    }

    public var minorCharacterCount: Int {
        max(0, activeSpeakingCharacters.count - leadCharacterCount)
    }

    private func rebuildMinorCharactersByArchetype() {
        var grouped: [AudiobookVoiceArchetype: [AudiobookCharacter]] = [:]
        for role in characters where !role.isNarrator && !isSilentCharacter(role) {
            let tier = resolvedRoleTier(for: role)
            guard role.allowSharedMinorVoice || tier == .supporting || tier == .ensemble else { continue }
            let arch = roleStatsByID[role.id]?.archetype ?? role.inferredVoiceArchetype()
            grouped[arch, default: []].append(role)
        }
        minorCharactersByArchetype = grouped
    }

    private func rebuildSceneConflictCache() {
        guard !characters.isEmpty, !voiceBindings.isEmpty else {
            sceneConflictPartnersByRoleID = [:]
            totalSceneVoiceConflictCount = 0
            return
        }
        var map: [UUID: [String]] = [:]
        var count = 0
        for role in characters {
            guard let myVoiceID = voiceBindings[role.id]?.voiceID,
                  let stat = roleStatsByID[role.id],
                  !stat.scenePartnerRoleIDs.isEmpty
            else { continue }
            let partners = stat.scenePartnerRoleIDs.compactMap { partnerID -> String? in
                guard voiceBindings[partnerID]?.voiceID == myVoiceID else { return nil }
                return charactersByID[partnerID]?.displayName
            }.sorted()
            if !partners.isEmpty {
                map[role.id] = partners
                count += 1
            }
        }
        sceneConflictPartnersByRoleID = map
        totalSceneVoiceConflictCount = count
    }

    private func rebuildChapterCharacterBuckets() {
        guard !characters.isEmpty else {
            currentChapterCharacters = []
            remainingBookCharacters = []
            return
        }
        let chapterID = selectedChapterID
        let chapterSpeakerIDs = Set(chapterAnnotations.compactMap(\.assignment.roleID))
        let speakingPool = activeSpeakingCharacters
        var primary: [AudiobookCharacter] = []
        var secondary: [AudiobookCharacter] = []
        for role in speakingPool {
            let tier = resolvedRoleTier(for: role)
            let inChapter = role.isNarrator
                || chapterSpeakerIDs.contains(role.id)
                || (chapterID.map { roleStatsByID[role.id]?.speakingChapterIDs.contains($0) == true } == true)
                || (roleStatsByID.isEmpty && chapterID.map { role.chapterIDs.contains($0) } == true)
                || tier == .lead
            if inChapter && primary.count < 16 {
                primary.append(role)
            } else {
                secondary.append(role)
            }
        }
        if primary.isEmpty {
            primary = Array(speakingPool.prefix(16))
            secondary = Array(speakingPool.dropFirst(16))
        }
        currentChapterCharacters = primary
        remainingBookCharacters = secondary
    }

    // MARK: - Stratified Cast Helpers & Batch Archetype Binding

    public var filteredCharacters: [AudiobookCharacter] {
        let basePool = showSilentCharacters ? characters : activeSpeakingCharacters
        switch castFilterScope {
        case .inCurrentChapter:
            guard let chapterID = selectedChapterID else { return basePool }
            let chapterSpeakerIDs = Set(chapterAnnotations.compactMap(\.assignment.roleID))
            let inChapter = basePool.filter { role in
                role.isNarrator
                    || chapterSpeakerIDs.contains(role.id)
                    || roleStatsByID[role.id]?.speakingChapterIDs.contains(chapterID) == true
                    || (roleStatsByID.isEmpty && role.chapterIDs.contains(chapterID))
            }
            return inChapter.isEmpty ? basePool : inChapter
        case .leads:
            return basePool.filter { role in
                let tier = resolvedRoleTier(for: role)
                return role.isNarrator || tier == .lead
            }
        case .minorEnsemble:
            return basePool.filter { role in
                guard !role.isNarrator else { return false }
                let tier = resolvedRoleTier(for: role)
                return tier == .supporting || tier == .ensemble || role.allowSharedMinorVoice
            }
        case .all:
            return basePool
        }
    }

    /// 返回与指定角色在同一场戏直接交谈且绑定了相同 voiceID 的对手角色名称列表（用于实时同场撞音预警）。
    public func sceneConflictPartnerNames(for roleID: UUID) -> [String] {
        sceneConflictPartnersByRoleID[roleID] ?? []
    }

    /// 按声部行当补全尚未配声的配角。
    public func batchBindArchetype(_ archetype: AudiobookVoiceArchetype, to voice: SafeVoiceEntry) async {
        guard let bookID = selectedBook?.id, let castController, let store else { return }
        do {
            errorMessage = nil
            let count = try await castController.batchBindArchetypeVoice(
                bookID: bookID,
                archetype: archetype,
                voice: voice
            )
            voiceBindings = try await store.voiceBindings(for: bookID)
            selectedBook = try await store.book(id: bookID)
            await refreshChapterReadinessMap(for: bookID)
            await refreshShelf()
            if count > 0 {
                bannerMessage = "已为 \(count) 名未配声的「\(archetype.shortBadgeTitle)」配角选择「\(voice.name)」。"
            } else {
                bannerMessage = "当前没有需要补全「\(archetype.shortBadgeTitle)」声音的次要角色。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 调整单个角色已绑定音色的微语速档位。
    public func updateRoleAllowedSpeed(roleID: UUID, speed: Double) async {
        guard let existing = voiceBindings[roleID] else { return }
        let updated = AudiobookVoiceBinding(
            roleID: existing.roleID,
            voiceID: existing.voiceID,
            voiceRevision: existing.voiceRevision,
            modelRevision: existing.modelRevision,
            isSynthesisReady: existing.isSynthesisReady,
            allowedSpeed: speed,
            callerSeed: existing.callerSeed
        )
        await bindVoice(roleID: roleID, binding: updated)
    }

    // MARK: - Cast, Speaker Resolution & Voice Round-Trip

    public func assignSpeaker(atomIDs: [UUID], roleID: UUID) async {
        guard let bookID = selectedBook?.id, let castController, let store else { return }
        do {
            try await castController.assignRole(bookID: bookID, atomIDs: atomIDs, roleID: roleID)
            if let allAnns = try? await store.annotations(for: bookID) {
                await rebuildUnknownSpeakerIndex(from: allAnns, chapters: chapters)
            }
            await reloadSelectedChapterDetails()
            await refreshChapterReadinessMap(for: bookID)
            await refreshShelf()
            if allUnknownAnnotations.isEmpty {
                focusedUnknownAtomID = nil
                showOnlyUnknownAtomsInChapter = false
                let autoConfirmed = await confirmCastAndAudition(switchToProduction: false)
                if autoConfirmed && isAuditionConfirmedForSelectedBook {
                    bannerMessage = "全部台词已确认完毕，角色与音色已自动锁定，可直接开始制作章节。"
                } else {
                    bannerMessage = "已更新 \(atomIDs.count) 处段落的说话人归属。全书待确认说话人已全部确认完毕！"
                }
            } else {
                bannerMessage = "已更新 \(atomIDs.count) 处段落的说话人归属。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 人工确认单处未知说话人后，自动定位到下一处待确认位置（若本章已无待确认则自动跨章跳转）。
    public func assignSpeakerAndAdvanceToNextUnknown(atomID: UUID, roleID: UUID) async {
        guard let bookID = selectedBook?.id, let castController, let store else { return }
        let currentIdx = allUnknownAnnotations.firstIndex(where: { $0.atomID == atomID })
        do {
            try await castController.assignRole(bookID: bookID, atomIDs: [atomID], roleID: roleID)
            if let allAnns = try? await store.annotations(for: bookID) {
                await rebuildUnknownSpeakerIndex(from: allAnns, chapters: chapters)
            }
            await reloadSelectedChapterDetails()
            await refreshChapterReadinessMap(for: bookID)
            await refreshShelf()

            if !allUnknownAnnotations.isEmpty {
                let nextIdx = min(currentIdx ?? 0, allUnknownAnnotations.count - 1)
                let nextTarget = allUnknownAnnotations[nextIdx]
                await focusUnknownAnnotation(nextTarget)
                bannerMessage = "已确认该处说话人，已自动定位至下一处（剩余 \(allUnknownAnnotations.count) 处）。"
            } else {
                focusedUnknownAtomID = nil
                showOnlyUnknownAtomsInChapter = false
                let autoConfirmed = await confirmCastAndAudition(switchToProduction: false)
                if autoConfirmed && isAuditionConfirmedForSelectedBook {
                    bannerMessage = "全部台词已确认完毕，角色与音色已自动锁定，可直接开始制作章节。"
                } else {
                    bannerMessage = "全书所有待确认说话人已全部确认完毕！"
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 为待确认段落提供最多 5 个一键归属候选角色（优先 LLM 推荐的 candidateRoleIDs，其次本章高频出场角色与旁白）。
    public func quickCandidateRoles(for annotation: AudiobookAnnotation) -> [AudiobookCharacter] {
        var result: [AudiobookCharacter] = []
        var seen = Set<UUID>()
        if case let .unknown(_, candidateIDs) = annotation.assignment {
            for cid in candidateIDs {
                if let role = charactersByID[cid], !seen.contains(cid) {
                    result.append(role)
                    seen.insert(cid)
                }
            }
        }
        for role in currentChapterCharacters where !role.isNarrator {
            guard result.count < 4 else { break }
            if !seen.contains(role.id) {
                result.append(role)
                seen.insert(role.id)
            }
        }
        if let narrator = characters.first(where: \.isNarrator), !seen.contains(narrator.id) {
            result.append(narrator)
        }
        return result
    }

    public func jumpToFirstUnknownSpeaker() async {
        if let firstInChapter = unknownAnnotationsInSelectedChapter.first {
            await focusUnknownAnnotation(firstInChapter)
        } else if let firstGlobal = allUnknownAnnotations.first {
            await focusUnknownAnnotation(firstGlobal)
        }
    }

    public func jumpToNextUnknownSpeaker() async {
        guard !allUnknownAnnotations.isEmpty else { return }
        if let currentID = focusedUnknownAtomID,
           let idx = allUnknownAnnotations.firstIndex(where: { $0.atomID == currentID })
        {
            let nextIdx = (idx + 1) % allUnknownAnnotations.count
            await focusUnknownAnnotation(allUnknownAnnotations[nextIdx])
        } else {
            await jumpToFirstUnknownSpeaker()
        }
    }

    public func jumpToPreviousUnknownSpeaker() async {
        guard !allUnknownAnnotations.isEmpty else { return }
        if let currentID = focusedUnknownAtomID,
           let idx = allUnknownAnnotations.firstIndex(where: { $0.atomID == currentID })
        {
            let prevIdx = (idx - 1 + allUnknownAnnotations.count) % allUnknownAnnotations.count
            await focusUnknownAnnotation(allUnknownAnnotations[prevIdx])
        } else if let lastGlobal = allUnknownAnnotations.last {
            await focusUnknownAnnotation(lastGlobal)
        }
    }

    private func focusUnknownAnnotation(_ annotation: AudiobookAnnotation) async {
        workbenchTab = .preparation
        if selectedChapterID != annotation.chapterID {
            isSuppressingChapterAutoReload = true
            selectedChapterID = annotation.chapterID
            isSuppressingChapterAutoReload = false
            await reloadSelectedChapterDetails()
        }
        focusedUnknownAtomID = annotation.atomID
        selectedAtomIDs = [annotation.atomID]
    }

    /// 对当前书中尚未确认的 `unknown` 说话人段落运行二次定向 LLM 消歧分析。
    public func resolveUnknownSpeakersWithLLM(for bookID: UUID? = nil) async {
        guard secondaryResolutionTask == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performUnknownSpeakerResolution(for: bookID)
        }
        secondaryResolutionTask = task
        await task.value
        secondaryResolutionTask = nil
    }

    /// 取消正在进行的二次复核；已保存的确认结果不受影响。
    public func cancelSecondaryResolution() {
        secondaryResolutionTask?.cancel()
    }

    private func performUnknownSpeakerResolution(for bookID: UUID?) async {
        let targetID = bookID ?? selectedBook?.id
        guard let targetID, let pipeline = analysisPipeline, let store else { return }
        guard !isResolvingUnknownSpeakers else { return }
        isResolvingUnknownSpeakers = true
        errorMessage = nil
        let snapshot = dependencies.resolveAnalysisSnapshot(analysisGeneration)
        do {
            let outcome = try await pipeline.resolveUnknownSpeakers(bookID: targetID, config: snapshot)
            isResolvingUnknownSpeakers = false
            if let allAnns = try? await store.annotations(for: targetID) {
                await rebuildUnknownSpeakerIndex(from: allAnns, chapters: chapters)
            }
            if selectedBook?.id == targetID {
                characters = (try? await store.characters(for: targetID)) ?? characters
                await reloadSelectedChapterDetails()
                await refreshChapterReadinessMap(for: targetID)
                await refreshShelf()
                if outcome.remainingUnknownCount > 0 {
                    await jumpToFirstUnknownSpeaker()
                } else {
                    focusedUnknownAtomID = nil
                    showOnlyUnknownAtomsInChapter = false
                    let autoConfirmed = await confirmCastAndAudition(switchToProduction: false)
                    if autoConfirmed && isAuditionConfirmedForSelectedBook {
                        bannerMessage = "全部台词已确认完毕，角色与音色已自动锁定，可直接开始制作章节。"
                        return
                    }
                }
            }
            if outcome.resolvedCount > 0 {
                bannerMessage = "AI 二次复核已自动确认 \(outcome.resolvedCount) 处对白，剩余 \(outcome.remainingUnknownCount) 处需人工确认。"
            } else if outcome.remainingUnknownCount > 0 {
                bannerMessage = "AI 二次复核已完成，剩余 \(outcome.remainingUnknownCount) 处多角色歧义对白请通过上方定位栏人工一键确认。"
            } else {
                bannerMessage = "全书所有对白说话人均已确认完毕。"
            }
        } catch is CancellationError {
            isResolvingUnknownSpeakers = false
            bannerMessage = "已取消 AI 复核；已有确认结果保持不变。"
        } catch {
            isResolvingUnknownSpeakers = false
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Six-Archetype Ensemble & Lead Character Voice Creation

    /// 分析当前系统是否已存在满足本小说场景的完整六类群像音色（旁白叙事、青年男声、中老年男声、青年女声、成熟女声、特色群像），返回尚缺失的声部行当列表。
    public func missingArchetypesForBook(
        bookID: UUID? = nil,
        availableVoices: [SafeVoiceEntry]? = nil
    ) -> [AudiobookVoiceArchetype] {
        let targetBookID = bookID ?? selectedBook?.id
        let pool = mergedAvailableVoices(externalVoices: availableVoices ?? catalogVoices)
        let metadataMap = voiceCatalogModel.snapshot.state.metadataByVoiceID

        var coveredArchetypes = Set<AudiobookVoiceArchetype>()
        for voice in pool where voice.available {
            let lowerID = voice.id.lowercased()
            let isBuiltInDefault = Self.builtInSystemVoiceIDs.contains(lowerID) || lowerID == "v-narrator"
            guard !isBuiltInDefault else { continue }
            guard voiceCatalogModel.snapshot.isVoiceActiveForBook(voiceID: voice.id, currentBookID: targetBookID) else {
                continue
            }
            let meta = metadataMap[voice.id]
            let arch = AudiobookCastRegistry.resolveVoiceArchetype(for: voice, metadata: meta)
            coveredArchetypes.insert(arch)
        }

        return AudiobookVoiceArchetype.allCases.filter { !coveredArchetypes.contains($0) }
    }

    /// 检查当前系统是否已存在满足此小说场景的完整六类群像音色；若不完整，则结合小说角色特征与原书台词自动创建并发布缺失的群像音色。
    @discardableResult
    public func ensureSixArchetypeVoicesForBook(
        for bookID: UUID? = nil,
        quietBanner: Bool = false
    ) async -> Int {
        let targetID = bookID ?? selectedBook?.id
        guard let targetID, let store, let castController else { return 0 }
        guard !isCreatingLeadExclusiveVoices else { return 0 }

        let currentVoices = await refreshAvailableVoices()
        let missing = missingArchetypesForBook(bookID: targetID, availableVoices: currentVoices)
        guard !missing.isEmpty else {
            if !quietBanner {
                bannerMessage = "当前系统已具备完整的六类群像音色。"
            }
            return 0
        }

        let loadedChars = (try? await store.characters(for: targetID)) ?? characters
        let allAnnotations = (try? await store.annotations(for: targetID)) ?? []
        let bookTitle = (try? await store.book(id: targetID).title) ?? selectedBook?.title ?? "有声书"
        guard let (stratifiedChars, stats, _) = try? await AudiobookWorkspaceProjection.roleStatistics(
            characters: loadedChars,
            annotations: allAnnotations,
            availableVoiceCount: max(8, currentVoices.count)
        ), !isCreatingLeadExclusiveVoices else { return 0 }

        isCreatingLeadExclusiveVoices = true
        var createdCount = 0
        let bookPrefix = targetID.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(6)

        for (idx, archetype) in missing.enumerated() {
            leadVoiceCreationProgressText = "正在补全六类群像音色「\(archetype.shortBadgeTitle)」(\(idx + 1)/\(missing.count))…"

            let matchingRoles = stratifiedChars.filter { role in
                let roleArch = stats[role.id]?.archetype ?? role.inferredVoiceArchetype(peers: stratifiedChars)
                return roleArch == archetype
            }
            let representativeRole = matchingRoles.first(where: { $0.allowSharedMinorVoice }) ?? matchingRoles.first

            let instruction: String = {
                let baseInstruction = archetype.defaultScenarioInstruction(forBookTitle: bookTitle)
                guard let rep = representativeRole else { return baseInstruction }
                let persona = AudiobookVoicePersona.infer(for: rep, peers: stratifiedChars, recompute: false)
                if let summary = rep.primaryVoiceTraitSummary, !summary.isEmpty {
                    return "\(baseInstruction) 契合书中「\(rep.displayName)」等角色特征（\(summary)，\(persona.timbreAndTexture)）。"
                }
                return baseInstruction
            }()

            var refCandidates: [String] = []
            for role in matchingRoles.prefix(3) {
                let roleQuotes = AudiobookAuditionScriptSelector.selectCandidates(
                    from: role.evidences.map(\.quoteExcerpt),
                    roleName: role.displayName,
                    aliases: role.aliases,
                    isNarrator: role.isNarrator,
                    maxCandidates: 1
                )
                for quote in roleQuotes where !refCandidates.contains(quote) {
                    refCandidates.append(quote)
                }
            }
            let defaultRef = archetype.defaultScenarioReferenceText(forBookTitle: bookTitle)
            if !refCandidates.contains(defaultRef) {
                refCandidates.append(defaultRef)
            }

            let targetVoiceID = "ab_arch_\(bookPrefix)_\(archetype.shortCode)"
            let voiceName = "\(bookTitle)·群像·\(archetype.shortBadgeTitle)"
            let seedHash = AudiobookDigest.sha256Hex(Data("\(targetID.uuidString)|arch|\(archetype.rawValue)".utf8))
            let baseSeed = (Int(seedHash.prefix(6), radix: 16) ?? 2048) + idx * 37

            let request = AudiobookLeadVoiceCreationRequest(
                bookID: targetID,
                roleID: representativeRole?.id ?? targetID,
                targetVoiceID: targetVoiceID,
                voiceName: voiceName,
                instruction: instruction,
                referenceTextCandidates: refCandidates,
                seed: baseSeed
            )

            if let output = try? await dependencies.speechRenderer.createAndPublishLeadVoice(request) {
                do { try await castController.registerEnsembleAsset(bookID: targetID, voiceID: output.voiceID, bookTitle: bookTitle, archetype: archetype)
                createdCount += 1
                } catch { errorMessage = error.localizedDescription }
            }
        }

        leadVoiceCreationProgressText = nil
        isCreatingLeadExclusiveVoices = false
        _ = await refreshAvailableVoices()

        if !quietBanner {
            await autoAssignRecommendedVoices(for: targetID)
            if selectedBook?.id == targetID {
                voiceBindings = (try? await store.voiceBindings(for: targetID)) ?? voiceBindings
                selectedBook = (try? await store.book(id: targetID)) ?? selectedBook
                await refreshChapterReadinessMap(for: targetID)
                await refreshShelf()
            }
            if createdCount > 0 {
                bannerMessage = "已为《\(bookTitle)》创建并补全 \(createdCount) 类群像音色。"
            } else {
                errorMessage = "当前语音服务未开启音色设计（VoiceDesign）能力或生成未通过校验，未能自动创建缺失的群像音色。"
            }
        }
        return createdCount
    }

    /// 为主要角色（旁白与核心主角 `.lead`）自动创建并发布本书专属音色（基于六维声学人设指令与原书对白试听稿），避免仅使用默认系统音色。
    @discardableResult
    public func createExclusiveVoicesForLeadCharacters(
        for bookID: UUID? = nil,
        quietBanner: Bool = false
    ) async -> Int {
        let targetID = bookID ?? selectedBook?.id
        guard let targetID, let store, castController != nil else { return 0 }
        guard !isCreatingLeadExclusiveVoices else { return 0 }

        guard let loadedChars = try? await store.characters(for: targetID),
              let existingBindings = try? await store.voiceBindings(for: targetID)
        else { return 0 }
        let allAnnotations = (try? await store.annotations(for: targetID)) ?? []
        let bookTitle = (try? await store.book(id: targetID).title) ?? selectedBook?.title ?? "有声书"

        guard let (stratifiedChars, stats, _) = try? await AudiobookWorkspaceProjection.roleStatistics(
            characters: loadedChars,
            annotations: allAnnotations
        ), !isCreatingLeadExclusiveVoices else { return 0 }

        // 自动补全只处理没有绑定的角色；已有声音即使待复核也由用户明确处理。
        let leadCandidates = stratifiedChars.filter { role in
            let stat = stats[role.id]
            let isLeadRole = role.isNarrator || stat?.tier == .lead || !role.allowSharedMinorVoice
            let hasLines = role.isNarrator || (stat?.dialogueAtomCount ?? 0) > 0
            guard isLeadRole && hasLines else { return false }
            return existingBindings[role.id] == nil
        }.prefix(6)

        guard !leadCandidates.isEmpty else {
            if !quietBanner {
                bannerMessage = "主要角色已有声音；如需更换，请选择对应角色。"
            }
            return 0
        }

        isCreatingLeadExclusiveVoices = true
        var createdCount = 0
        var fallbackRoles: [(roleID: UUID, roleName: String, fallbackArchetypeName: String)] = []

        for (idx, role) in leadCandidates.enumerated() {
            leadVoiceCreationProgressText = "正在为「\(role.displayName)」创建专属音色 (\(idx + 1)/\(leadCandidates.count))…"
            if let _ = await createExclusiveVoiceForRoleInternal(
                bookID: targetID,
                bookTitle: bookTitle,
                role: role,
                peers: stratifiedChars,
                slotOffset: idx,
                onlyIfUnbound: true
            ) {
                createdCount += 1
                fallbackRoleIDs.remove(role.id)
            } else {
                let archetype = roleStatsByID[role.id]?.archetype ?? role.inferredVoiceArchetype(peers: stratifiedChars)
                fallbackRoles.append((roleID: role.id, roleName: role.displayName, fallbackArchetypeName: archetype.shortBadgeTitle))
                fallbackRoleIDs.insert(role.id)
            }
        }

        lastLeadVoiceCreationSummary = LeadVoiceCreationSummary(
            attemptedCount: leadCandidates.count,
            succeededCount: createdCount,
            fallbacks: fallbackRoles
        )

        leadVoiceCreationProgressText = nil
        isCreatingLeadExclusiveVoices = false
        _ = await refreshAvailableVoices()

        // 为其余配角与群像角色执行双池智能配声
        await autoAssignRecommendedVoices(for: targetID)

        if selectedBook?.id == targetID {
            voiceBindings = (try? await store.voiceBindings(for: targetID)) ?? voiceBindings
            selectedBook = (try? await store.book(id: targetID)) ?? selectedBook
            await refreshChapterReadinessMap(for: targetID)
            await refreshShelf()
        }

        if !quietBanner {
            if createdCount > 0 && fallbackRoles.isEmpty {
                bannerMessage = "已为 \(createdCount) 名主要角色生成专属音色。"
            } else if !fallbackRoles.isEmpty {
                let names = fallbackRoles.map(\.roleName).joined(separator: "、")
                let archetypeName = (fallbackRoles.first?.fallbackArchetypeName ?? "群像") + "群像音色"
                if createdCount > 0 {
                    bannerMessage = "已为 \(createdCount) 名主角生成专属音色，\(fallbackRoles.count) 名角色（\(names)）已回退为\(archetypeName)。"
                } else {
                    bannerMessage = "\(fallbackRoles.count) 名角色（\(names)）专属音色生成未通过，已回退为\(archetypeName)。"
                }
            } else {
                errorMessage = "当前语音服务未开启音色设计（VoiceDesign）能力或生成未通过校验，已保留推荐音色。"
            }
        }
        return createdCount
    }

    /// 为指定单个角色一键创建并绑定本书专属音色。
    public func createExclusiveVoiceForRole(_ roleID: UUID) async {
        guard let bookID = selectedBook?.id,
              let store,
              let role = charactersByID[roleID],
              !isCreatingLeadExclusiveVoices
        else { return }

        isCreatingLeadExclusiveVoices = true
        leadVoiceCreationProgressText = "正在为「\(role.displayName)」生成专属音色…"
        errorMessage = nil
        let bookTitle = selectedBook?.title ?? "有声书"

        let created = await createExclusiveVoiceForRoleInternal(
            bookID: bookID,
            bookTitle: bookTitle,
            role: role,
            peers: characters,
            slotOffset: 0
        )

        leadVoiceCreationProgressText = nil
        isCreatingLeadExclusiveVoices = false
        _ = await refreshAvailableVoices()

        if let created {
            fallbackRoleIDs.remove(roleID)
            voiceBindings = (try? await store.voiceBindings(for: bookID)) ?? voiceBindings
            selectedBook = (try? await store.book(id: bookID)) ?? selectedBook
            await refreshChapterReadinessMap(for: bookID)
            await refreshShelf()
            bannerMessage = "已为角色「\(role.displayName)」生成并绑定专属音色「\(created.voiceName)」。"
        } else {
            errorMessage = "未能为「\(role.displayName)」自动生成专属音色，可点击「微调新音色」前往工作台微调。"
        }
    }

    private func createExclusiveVoiceForRoleInternal(
        bookID: UUID,
        bookTitle: String,
        role: AudiobookCharacter,
        peers: [AudiobookCharacter],
        slotOffset: Int,
        onlyIfUnbound: Bool = false
    ) async -> AudiobookLeadVoiceCreationOutput? {
        guard let castController else { return nil }
        guard let context = try? await castController.makeVoiceReturnContext(bookID: bookID, roleID: role.id) else {
            return nil
        }

        let persona = AudiobookVoicePersona.infer(for: role, peers: peers, recompute: false)
        let instruction = context.suggestedInstruction
            ?? persona.compiledVoiceDesignInstruction(roleName: role.displayName, isNarrator: role.isNarrator)
        var candidates = context.suggestedReferenceTextCandidates
        if let primaryRef = context.suggestedReferenceText, !primaryRef.isEmpty, !candidates.contains(primaryRef) {
            candidates.insert(primaryRef, at: 0)
        }
        if candidates.isEmpty {
            candidates = AudiobookAuditionScriptSelector.selectCandidates(
                from: role.evidences.map(\.quoteExcerpt),
                roleName: role.displayName,
                aliases: role.aliases,
                isNarrator: role.isNarrator,
                maxCandidates: 2
            )
        }

        let bookPrefix = bookID.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(6)
        let rolePrefix = role.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(6)
        let targetVoiceID = "ab_\(bookPrefix)_\(rolePrefix)"
        let voiceName = "\(bookTitle)·\(role.displayName)"
        let seedHash = AudiobookDigest.sha256Hex(Data("\(bookID.uuidString)|\(role.id.uuidString)".utf8))
        let baseSeed = (Int(seedHash.prefix(6), radix: 16) ?? 1024) + slotOffset * 31

        let request = AudiobookLeadVoiceCreationRequest(
            bookID: bookID,
            roleID: role.id,
            targetVoiceID: targetVoiceID,
            voiceName: voiceName,
            instruction: instruction,
            referenceTextCandidates: candidates,
            seed: baseSeed
        )

        guard let output = try? await dependencies.speechRenderer.createAndPublishLeadVoice(request) else {
            return nil
        }

        let binding = AudiobookVoiceBinding(
            roleID: role.id,
            voiceID: output.voiceID,
            voiceRevision: output.voiceRevision,
            modelRevision: output.modelRevision,
            isSynthesisReady: true,
            allowedSpeed: AudiobookLimits.defaultRenderSpeed,
            callerSeed: nil
        )
        do {
            try await castController.registerVoiceReturn(context: context, activeBookID: bookID, binding: binding, creationSource: .voiceDesign, onlyIfUnbound: onlyIfUnbound)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
        return output
    }

    public func undoLastSpeakerAssignment() async {
        guard let bookID = selectedBook?.id, let castController, let store else { return }
        do {
            try await castController.undoLastAssignment(bookID: bookID)
            if let allAnns = try? await store.annotations(for: bookID) {
                await rebuildUnknownSpeakerIndex(from: allAnns, chapters: chapters)
            }
            await reloadSelectedChapterDetails()
            await refreshChapterReadinessMap(for: bookID)
            await refreshShelf()
            bannerMessage = "已撤销上一处说话人归属修改。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func renameCharacter(roleID: UUID, newName: String, aliases: [String]) async {
        guard let bookID = selectedBook?.id, let castController, let store else { return }
        do {
            try await castController.renameCharacter(bookID: bookID, roleID: roleID, newName: newName, aliases: aliases)
            characters = try await store.characters(for: bookID)
            bannerMessage = "已更新角色名称与别称，已生成的角色音频保持有效。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func mergeCharacters(sourceRoleID: UUID, intoTargetRoleID: UUID) async {
        guard let bookID = selectedBook?.id, let castController, let store else { return }
        do {
            let impact = try await castController.mergeCharacters(
                bookID: bookID,
                sourceRoleID: sourceRoleID,
                intoTargetRoleID: intoTargetRoleID
            )
            characters = try await store.characters(for: bookID)
            selectedRoleID = intoTargetRoleID
            if let allAnns = try? await store.annotations(for: bookID) {
                await rebuildUnknownSpeakerIndex(from: allAnns, chapters: chapters)
            }
            await reloadSelectedChapterDetails()
            await refreshChapterReadinessMap(for: bookID)
            await refreshShelf()
            bannerMessage = "已合并角色（共更新 \(impact.affectedQuotesCount) 处对白归属）。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func splitCharacter(sourceRoleID: UUID, newDisplayName: String, atomIDs: [UUID]) async {
        guard let bookID = selectedBook?.id, let castController, let store else { return }
        do {
            let newRole = try await castController.splitCharacter(
                bookID: bookID,
                sourceRoleID: sourceRoleID,
                newDisplayName: newDisplayName,
                atomIDs: atomIDs
            )
            characters = try await store.characters(for: bookID)
            selectedRoleID = newRole.id
            if let allAnns = try? await store.annotations(for: bookID) {
                await rebuildUnknownSpeakerIndex(from: allAnns, chapters: chapters)
            }
            await reloadSelectedChapterDetails()
            await refreshChapterReadinessMap(for: bookID)
            await refreshShelf()
            bannerMessage = "已拆分出新角色「\(newRole.displayName)」。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// A new, explicit selection resolves identity from one full snapshot. Frozen bindings use the overload below.
    public func bindVoice(roleID: UUID, voiceID: String) async {
        guard let bookID = selectedBook?.id else { return }
        do {
            let snapshot = try await dependencies.speechRenderer.fetchEffectiveCapabilities()
            guard selectedBook?.id == bookID,
                  let voice = snapshot.voices.first(where: { $0.id == voiceID }),
                  let options = SpeechRailCapabilityRevisionSelector.creatorRequestOptions(voiceID: voice.id, in: snapshot),
                  let modelRevision = options.expectedModelRevision else { throw ServiceAPIClientError.invalidContract("voice_identity_unknown") }
            let old = voiceBindings[roleID]
            let binding: AudiobookVoiceBinding
            if let old, old.voiceID == voice.id, (try? AudiobookCastRegistry.validateRenderBinding(old, snapshot: snapshot)) != nil {
                binding = old
            } else {
                binding = AudiobookVoiceBinding(roleID: roleID, voiceID: voice.id,
                    voiceRevision: options.expectedVoiceRevision, modelRevision: modelRevision)
            }
            await bindVoice(roleID: roleID, binding: binding)
        } catch { errorMessage = "所选声音当前不可用于制作，请刷新声音列表后重新选择。" }
    }

    public func bindVoice(roleID: UUID, binding: AudiobookVoiceBinding) async {
        guard let bookID = selectedBook?.id, let castController, let store else { return }
        invalidateCastingAudition()
        do {
            errorMessage = nil
            try await castController.bindVoice(bookID: bookID, roleID: roleID, binding: binding)
            voiceBindings = try await store.voiceBindings(for: bookID)
            selectedBook = try await store.book(id: bookID)
            await refreshChapterReadinessMap(for: bookID)
            await refreshShelf()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 跳过/恢复整章。跳过只影响分析与制作，原文和章节结构不变。
    public func setChapterSkipped(chapterID: UUID, skipped: Bool) async {
        guard let bookID = selectedBook?.id, let store else { return }
        do {
            try await store.setChapterSkipped(bookID: bookID, chapterID: chapterID, skipped: skipped)
            chapters = try await store.chapters(for: bookID)
            selectedBook = try await store.book(id: bookID)
            await refreshChapterReadinessMap(for: bookID)
            await refreshShelf()
            let title = chapters.first(where: { $0.id == chapterID })?.title ?? "本章"
            bannerMessage = skipped
                ? "已跳过《\(title)》：不参与分析与制作，之后可随时恢复。"
                : "已恢复《\(title)》，会重新纳入分析与制作。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Pronunciation Rules

    public var pronunciationRuleCount: Int { pronunciationController?.ruleCount ?? 0 }
    public var isPronunciationAvailable: Bool { pronunciationController?.isAvailable ?? false }

    public func presentPronunciationRules() {
        guard let bookID = selectedBook?.id else { return }
        isPronunciationSheetPresented = true
        Task { await pronunciationController?.load(bookID: bookID) }
    }

    public func toggleSharedMinorVoice(roleID: UUID, allowed: Bool) async {
        guard let bookID = selectedBook?.id, let castController, let store else { return }
        do {
            try await castController.setAllowSharedMinorVoice(bookID: bookID, roleID: roleID, allowed: allowed)
            characters = try await store.characters(for: bookID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    public func confirmCastAndAudition(switchToProduction: Bool = true) async -> Bool {
        guard let bookID = selectedBook?.id, let castController, let store else { return false }
        do {
            errorMessage = nil
            // 若确认角色时仍存在未确认的说话人，先用确认后的完整角色表自动执行一次 AI 二次消歧
            var resolvedBySecondPass = 0
            if !allUnknownAnnotations.isEmpty, let pipeline = analysisPipeline {
                isResolvingUnknownSpeakers = true
                let snapshot = dependencies.resolveAnalysisSnapshot(analysisGeneration)
                if let outcome = try? await pipeline.resolveUnknownSpeakers(bookID: bookID, config: snapshot) {
                    resolvedBySecondPass = outcome.resolvedCount
                }
                isResolvingUnknownSpeakers = false
                if let allAnns = try? await store.annotations(for: bookID) {
                    await rebuildUnknownSpeakerIndex(from: allAnns, chapters: chapters)
                }
                characters = (try? await store.characters(for: bookID)) ?? characters
                await reloadSelectedChapterDetails()
            }

            let castRev = try await castController.currentCastRevisionID(for: bookID)
            let voiceDigest = try await castController.currentVoiceSetDigest(for: bookID)
            try await castController.confirmCastAndAudition(
                bookID: bookID, revisionID: castRev, voiceSetDigest: voiceDigest
            )
            selectedBook = try await store.book(id: bookID)
            await refreshChapterReadinessMap(for: bookID)
            await refreshShelf()

            if !allUnknownAnnotations.isEmpty {
                workbenchTab = .preparation
                await jumpToFirstUnknownSpeaker()
                if resolvedBySecondPass > 0 {
                    bannerMessage = "已确认人物与声音，AI 二次复核消解了 \(resolvedBySecondPass) 处对白；剩余 \(allUnknownAnnotations.count) 处已为您定位，请点击候选角色芯片快速确认。"
                } else {
                    bannerMessage = "已确认人物与声音；全书仍有 \(allUnknownAnnotations.count) 处待确认说话人，已为您定位至第 1 处。"
                }
            } else {
                if switchToProduction {
                    workbenchTab = .production
                }
                bannerMessage = "已确认全书人物与试听声音，可开始制作已确认章节。"
            }
            return true
        } catch {
            isResolvingUnknownSpeakers = false
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func beginVoiceRoundTrip(for roleID: UUID) async -> AudiobookVoiceReturnContext? {
        guard let bookID = selectedBook?.id, let castController else { return nil }
        guard let context = try? await castController.makeVoiceReturnContext(bookID: bookID, roleID: roleID) else {
            return nil
        }
        pendingVoiceReturnContext = context
        return context
    }

    public func cancelVoiceRoundTrip() {
        pendingVoiceReturnContext = nil
    }

    public func dismissVoiceReturnBanner() {
        voiceReturnBannerMessage = nil
    }

    public func completeVoiceRoundTrip(
        voiceID: String, creationSource: VoiceCreationSource, context: AudiobookVoiceReturnContext? = nil
    ) async {
        guard let targetContext = context ?? pendingVoiceReturnContext else { return }
        do {
            let snapshot = try await dependencies.speechRenderer.fetchEffectiveCapabilities()
            guard let voice = snapshot.voices.first(where: { $0.id == voiceID }),
                  let options = SpeechRailCapabilityRevisionSelector.creatorRequestOptions(voiceID: voiceID, in: snapshot),
                  let model = options.expectedModelRevision else { throw ServiceAPIClientError.invalidContract("voice_identity_unknown") }
            let binding = AudiobookVoiceBinding(roleID: targetContext.roleID, voiceID: voice.id,
                voiceRevision: options.expectedVoiceRevision, modelRevision: model)
            try AudiobookCastRegistry.validateRenderBinding(binding, snapshot: snapshot)
            await completeVoiceRoundTrip(binding: binding, context: targetContext, creationSource: creationSource)
        } catch { voiceReturnBannerMessage = "新声音暂时未完成登记，请刷新声音列表后重新选择。" }
    }

    public func completeVoiceRoundTrip(
        binding: AudiobookVoiceBinding,
        context: AudiobookVoiceReturnContext? = nil,
        creationSource: VoiceCreationSource = .voiceDesign
    ) async {
        guard let targetContext = context ?? pendingVoiceReturnContext,
              let castController,
              let store
        else { return }

        let matchedRole = characters.first(where: { $0.id == targetContext.roleID })
        let roleName = targetContext.roleDisplayName ?? matchedRole?.displayName ?? "当前角色"

        guard let activeBookID = selectedBook?.id else {
            voiceReturnBannerMessage = "请重新打开对应书籍后登记新声音。"
            return
        }

        do {
            try await castController.registerVoiceReturn(context: targetContext, activeBookID: activeBookID, binding: binding, creationSource: creationSource)
            _ = await refreshAvailableVoices()
            voiceBindings = try await store.voiceBindings(for: activeBookID)
            selectedBook = try await store.book(id: activeBookID)
            pendingVoiceReturnContext = nil
            voiceReturnBannerMessage = voiceBindings[targetContext.roleID] == binding
                ? "已为角色「\(roleName)」配上本书专用的新声音。"
                : "新声音已登记为本书专用；角色选择已变化，请在选角器中确认是否使用。"
            await refreshChapterReadinessMap(for: activeBookID)
            await refreshShelf()
        } catch {
            pendingVoiceReturnContext = nil
            voiceReturnBannerMessage = error.localizedDescription
        }
    }

    // MARK: - Production & Revision Actions

    public func renameChapter(chapterID: UUID, title: String) async {
        guard canRenameSelectedChapter,
              let bookID = selectedBook?.id,
              let store,
              chapters.contains(where: { $0.id == chapterID })
        else { return }
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            errorMessage = "章节名称不能为空。"
            return
        }

        isEditingChapterLayout = true
        errorMessage = nil
        defer { isEditingChapterLayout = false }
        do {
            try await store.renameChapter(bookID: bookID, chapterID: chapterID, title: normalizedTitle)
            if selectedBook?.id == bookID {
                await openBook(bookID)
            }
            await refreshShelf()
            if selectedBook?.id == bookID {
                bannerMessage = "章节名称已更新，原文和已有音频保持不变。"
            }
        } catch {
            if selectedBook?.id == bookID {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func splitSelectedChapterBeforeSelectedAtom() async {
        guard canSplitSelectedChapterBeforeSelectedAtom,
              let bookID = selectedBook?.id,
              let chapterID = selectedChapterID,
              let atomID = selectedAtomIDs.first,
              let atom = chapterAtoms.first(where: { $0.id == atomID }),
              let store
        else {
            errorMessage = chapterStructureEditingStatus
            return
        }

        isEditingChapterLayout = true
        errorMessage = nil
        defer { isEditingChapterLayout = false }
        do {
            let latestChapters = try await store.chapters(for: bookID)
            let source = try await store.sourceIndex(for: bookID)
            guard let selectedIndex = latestChapters.firstIndex(where: { $0.id == chapterID }) else {
                throw AudiobookChapterEditError.chapterNotFound(chapterID)
            }
            let updated = try AudiobookChapterPlanner.splitChapter(
                latestChapters,
                chapterID: chapterID,
                atByteOffset: atom.sourceRange.lowerBound,
                secondTitle: "新章节",
                source: source
            )
            guard updated.count == latestChapters.count + 1,
                  updated.indices.contains(selectedIndex + 1)
            else {
                throw AudiobookChapterEditError.chapterNotFound(chapterID)
            }
            let newChapterID = updated[selectedIndex + 1].id
            try await store.updateChapters(bookID: bookID, chapters: updated)
            if selectedBook?.id == bookID {
                selectedAtomIDs.removeAll()
                if selectedChapterID == chapterID {
                    selectedChapterID = newChapterID
                }
                await openBook(bookID)
            }
            await refreshShelf()
            if selectedBook?.id == bookID {
                bannerMessage = "章节已拆分，原文内容保持不变。请重新分析全书后继续制作。"
            }
        } catch {
            if selectedBook?.id == bookID {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func mergeSelectedChapterWithPrevious() async {
        guard canMergeSelectedChapterWithPrevious,
              let bookID = selectedBook?.id,
              let chapterID = selectedChapterID,
              let store,
              let selectedIndex = chapters.firstIndex(where: { $0.id == chapterID }),
              selectedIndex > chapters.startIndex
        else {
            errorMessage = chapterStructureEditingStatus
            return
        }
        let previousChapterID = chapters[selectedIndex - 1].id

        isEditingChapterLayout = true
        errorMessage = nil
        defer { isEditingChapterLayout = false }
        do {
            let latestChapters = try await store.chapters(for: bookID)
            let source = try await store.sourceIndex(for: bookID)
            let updated = try AudiobookChapterPlanner.mergeChapterWithPrevious(
                latestChapters,
                chapterID: chapterID,
                source: source
            )
            try await store.updateChapters(bookID: bookID, chapters: updated)
            if selectedBook?.id == bookID {
                selectedAtomIDs.removeAll()
                if selectedChapterID == chapterID {
                    selectedChapterID = previousChapterID
                }
                await openBook(bookID)
            }
            await refreshShelf()
            if selectedBook?.id == bookID {
                bannerMessage = "章节已合并，原文内容保持不变。请重新分析全书后继续制作。"
            }
        } catch {
            if selectedBook?.id == bookID {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func regenerateFragment(fragmentID: UUID) {
        guard let bookID = selectedBook?.id,
              let chapterID = selectedChapterID,
              let fragment = chapterFragments.first(where: { $0.id == fragmentID }),
              fragment.bookID == bookID,
              fragment.chapterID == chapterID
        else {
            errorMessage = "当前片段已不在所选章节中，请刷新后重试。"
            return
        }
        guard !isProductionBusy, productionRunID == nil else {
            errorMessage = productionBookID == bookID
                ? "本书已有制作任务，请等待完成或暂停后再重录。"
                : "另一部有声书正在制作，请等待完成或暂停后再重录。"
            return
        }
        guard canRegenerateFragment(fragmentID) else {
            if !isAuditionConfirmedForSelectedBook {
                errorMessage = AudiobookProductionError.auditionNotConfirmed.errorDescription
            } else if chapterReadinessByID[chapterID] == .blockedByUnknownSpeakers {
                errorMessage = AudiobookProductionError.chapterBlockedByUnknownSpeakers(chapterID: chapterID).errorDescription
            } else if chapters.first(where: { $0.id == chapterID })?.isSkipped == true {
                errorMessage = "本章已跳过，先恢复本章后才能重录。"
            } else if chapters.first(where: { $0.id == chapterID })?.currentChapterRevisionID == nil {
                errorMessage = "请先完成本章首次制作，再重录单段。"
            } else {
                errorMessage = "当前章节还未准备好重录，请先完成角色确认和声音试听。"
            }
            return
        }
        startProductionRun(bookID: bookID, chapterIDs: [chapterID], regeneratingFragmentID: fragmentID)
    }

    public func makeConfirmedChapters(chapterIDs: [UUID]? = nil) {
        guard let bookID = selectedBook?.id else { return }
        if chapterIDs == nil, selectedBook?.productionState == .paused,
           let checkpoint = selectedProductionCheckpoint, checkpoint.progress.canResume
        {
            startProductionRun(bookID: bookID, chapterIDs: checkpoint.chapterIDs,
                               regeneratingFragmentID: checkpoint.regeneratingFragmentID,
                               resumingTaskID: checkpoint.taskID)
            return
        }
        guard !isEditingChapterLayout else {
            errorMessage = "正在整理章节目录，请完成后再开始制作。"
            return
        }
        guard !isProductionBusy, productionRunID == nil else {
            if productionBookID != bookID {
                errorMessage = "另一部有声书正在制作，请等待完成或暂停后再开始。"
            }
            return
        }
        let targetChapterIDs: [UUID]
        if let chapterIDs, !chapterIDs.isEmpty {
            targetChapterIDs = chapterIDs
        } else {
            targetChapterIDs = chapters.compactMap { ch in
                let state = chapterReadinessByID[ch.id]
                if state == .readyForProduction || state == .needsUpdate || state == .paused {
                    return ch.id
                }
                return nil
            }
        }
        guard !targetChapterIDs.isEmpty else {
            if !allUnknownAnnotations.isEmpty {
                errorMessage = "当前仍有 \(allUnknownAnnotations.count) 处待确认说话人阻碍章节就绪，请先在「准备与角色」页快速确认说话人。"
                Task { await jumpToFirstUnknownSpeaker() }
            } else if !isAuditionConfirmedForSelectedBook {
                errorMessage = AudiobookProductionError.castNotConfirmed.errorDescription
                workbenchTab = .preparation
            } else {
                errorMessage = AudiobookProductionError.noReadyChaptersSelected.errorDescription
            }
            return
        }

        startProductionRun(bookID: bookID, chapterIDs: targetChapterIDs)
    }

    public func resumeProduction() async {
        guard let bookID = selectedBook?.id, let store, !isProductionBusy else { return }
        do {
            let checkpoint = try await store.productionCheckpoint(for: bookID)
            guard selectedBook?.id == bookID, !isProductionBusy else { return }
            if let checkpoint, checkpoint.progress.canResume {
                startProductionRun(
                    bookID: bookID, chapterIDs: checkpoint.chapterIDs,
                    regeneratingFragmentID: checkpoint.regeneratingFragmentID,
                    resumingTaskID: checkpoint.taskID
                )
            } else {
                // Books created before task checkpoints still resume via verified candidates.
                let readyIDs = chapters.compactMap { chapter in
                    let readiness = chapterReadinessByID[chapter.id]
                    return readiness == .readyForProduction || readiness == .needsUpdate || readiness == .paused
                        ? chapter.id : nil
                }
                makeConfirmedChapters(chapterIDs: readyIDs)
            }
        } catch {
            if selectedBook?.id == bookID { errorMessage = error.localizedDescription }
        }
    }

    private func startProductionRun(
        bookID: UUID,
        chapterIDs: [UUID],
        regeneratingFragmentID: UUID? = nil,
        resumingTaskID: UUID? = nil
    ) {
        guard let productionController else { return }
        guard !isEditingChapterLayout else {
            errorMessage = "正在整理章节目录，请完成后再开始制作。"
            return
        }
        guard !isProductionBusy, productionRunID == nil else {
            if productionBookID != bookID {
                errorMessage = "另一部有声书正在制作，请等待完成或暂停后再开始。"
            }
            return
        }
        guard !chapterIDs.isEmpty else {
            errorMessage = AudiobookProductionError.noReadyChaptersSelected.errorDescription
            return
        }

        let runID = UUID()
        productionRunID = runID
        productionBookID = bookID
        productionFragmentID = regeneratingFragmentID
        productionProgress = AudiobookProductionProgress(bookID: bookID, state: .running, totalChapters: chapterIDs.count)
        productionProgressPollTask?.cancel()
        isProducing = true
        isPausingProduction = false
        errorMessage = nil

        productionProgressPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled,
                      let self,
                      self.isProducing,
                      self.productionRunID == runID,
                      self.productionBookID == bookID
                else { return }
                let progress = await productionController.progress(for: bookID)
                guard !Task.isCancelled, self.productionRunID == runID else { return }
                if let progress {
                    self.productionProgress = progress
                    if self.selectedBook?.id == bookID {
                        await self.reloadSelectedChapterDetails(onlyIfChanged: true)
                    }
                }
            }
        }

        productionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let regeneratingFragmentID {
                    guard chapterIDs.count == 1, let chapterID = chapterIDs.first else {
                        throw AudiobookProductionError.noReadyChaptersSelected
                    }
                    try await productionController.regenerateFragment(
                        bookID: bookID,
                        chapterID: chapterID,
                        fragmentID: regeneratingFragmentID,
                        resumingTaskID: resumingTaskID
                    )
                } else {
                    try await productionController.start(bookID: bookID, chapterIDs: chapterIDs, resumingTaskID: resumingTaskID)
                }
                let progress = await productionController.progress(for: bookID)
                guard self.productionRunID == runID, !self.isPausingProduction else { return }
                self.productionProgress = progress
                await self.refreshProductionBook(bookID)
                guard self.productionRunID == runID, !self.isPausingProduction else { return }
                self.finishProductionRun(runID)
                self.showProductionCompletionMessage(bookID: bookID, isFragmentRegeneration: regeneratingFragmentID != nil)
            } catch {
                guard self.productionRunID == runID, !self.isPausingProduction else { return }
                let progress = await productionController.progress(for: bookID)
                guard self.productionRunID == runID, !self.isPausingProduction else { return }
                self.productionProgress = progress
                await self.refreshProductionBook(bookID)
                guard self.productionRunID == runID, !self.isPausingProduction else { return }
                self.finishProductionRun(runID)
                if (error as? AudiobookProductionError) != .cancelled,
                   !(error is CancellationError)
                {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    public func pauseProduction() async {
        guard let productionController,
              isProducing,
              !isPausingProduction,
              let bookID = productionBookID,
              let runID = productionRunID
        else { return }
        let isFragmentRegeneration = productionFragmentID != nil
        isPausingProduction = true
        productionProgressPollTask?.cancel()
        productionProgress?.state = .pausing
        let task = productionTask
        task?.cancel()
        await productionController.pause()
        if let task { await task.value }
        guard productionRunID == runID else { return }
        let finalProgress = await productionController.progress(for: bookID)
        productionProgress = finalProgress
        await refreshProductionBook(bookID)
        guard productionRunID == runID else { return }
        finishProductionRun(runID)
        switch finalProgress?.state {
        case .failed:
            bannerMessage = nil
            errorMessage = finalProgress?.lastErrorMessage
        case .paused:
            if selectedBook?.id == bookID {
                bannerMessage = "制作已暂停，已保存的声音会保留。点击“继续制作”即可接着完成。"
            }
        case .fullBookProduced, .partialChaptersReady, .allConfirmedChaptersProduced:
            showProductionCompletionMessage(bookID: bookID, isFragmentRegeneration: isFragmentRegeneration)
        default:
            bannerMessage = nil
        }
    }

    private func showProductionCompletionMessage(bookID: UUID, isFragmentRegeneration: Bool) {
        guard selectedBook?.id == bookID, surfaceMode == .workspace else { return }
        bannerMessage = isFragmentRegeneration
            ? "本段新候选已生成；当前章节版本保持不变。请试听后选择“采用此候选”。"
            : "所选章节制作已完成，可立即进入听书或导出。"
    }

    private func finishProductionRun(_ runID: UUID) {
        guard productionRunID == runID else { return }
        productionProgressPollTask?.cancel()
        productionProgressPollTask = nil
        productionTask = nil
        productionRunID = nil
        productionBookID = nil
        productionFragmentID = nil
        isProducing = false
        isPausingProduction = false
    }

    private func refreshProductionBook(_ bookID: UUID) async {
        await refreshShelf()
        guard selectedBook?.id == bookID, surfaceMode == .workspace else { return }
        await openBook(bookID)
    }

    public func adoptCandidate(_ candidateID: UUID) async {
        guard let bookID = selectedBook?.id,
              let chapterID = selectedChapterID,
              let chapter = chapters.first(where: { $0.id == chapterID }),
              let expectedRevID = chapter.currentChapterRevisionID,
              let revisionController
        else { return }
        do {
            try await revisionController.adopt(
                bookID: bookID,
                candidateID: candidateID,
                expectedRevisionID: expectedRevID
            )
            await openBook(bookID)
            await refreshShelf()
            bannerMessage = "已采用新候选音频并更新当前章节版本。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func undoChapterAdoption(chapterID: UUID? = nil) async {
        guard let bookID = selectedBook?.id,
              let targetChapterID = chapterID ?? selectedChapterID,
              let revisionController
        else { return }
        do {
            try await revisionController.undoAdoption(bookID: bookID, chapterID: targetChapterID)
            await openBook(bookID)
            await refreshShelf()
            bannerMessage = "已撤销本章最近一次候选采用，恢复上一章节版本。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Listening & Previews

    public func startListening(chapterID: UUID? = nil) async {
        let requested = chapterID ?? selectedChapterID
        let requestedChapter = requested.flatMap { id in
            chapters.first {
                $0.id == id && !$0.isSkipped
                    && ($0.currentChapterRevisionID != nil || $0.previousChapterRevisionID != nil)
            }
        }
        if chapterID != nil, requestedChapter == nil {
            errorMessage = "该章节还没有可收听的音频，或已按你的设置跳过。"
            return
        }
        let fallbackChapter = chapters.first {
            !$0.isSkipped && ($0.currentChapterRevisionID != nil || $0.previousChapterRevisionID != nil)
        }
        guard let bookID = selectedBook?.id, let listeningController else { return }
        guard let targetChapterID = (requestedChapter ?? fallbackChapter)?.id else {
            errorMessage = nil
            surfaceMode = .listening
            return
        }
        do {
            errorMessage = nil
            try await listeningController.play(bookID: bookID, chapterID: targetChapterID)
            selectedChapterID = targetChapterID
            surfaceMode = .listening
            await reloadSelectedChapterDetails()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func previewCandidateAudio(_ candidate: AudiobookRenderCandidate) async {
        guard let store else { return }
        let request = playbackOwner.beginPlaybackRequest()
        do {
            await listeningController?.prepareForExternalPreview()
            let url = try await store.resolveAssetFileURL(for: candidate)
            guard playbackOwner.isCurrentPlaybackRequest(request), !Task.isCancelled else { return }
            try playbackOwner.play(fileURL: url, target: .dubbingCandidate(candidate.id.uuidString), requestID: request)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Export Actions

    public func setExportCover(sourceURL: URL) async {
        guard let bookID = selectedBook?.id, let coverStore else { return }
        exportCoverErrorMessage = nil
        do {
            exportCover = try await coverStore.install(bookID: bookID, sourceURL: sourceURL)
            exportCoverPreviewURL = await coverStore.coverFileURL(bookID: bookID)
        } catch {
            exportCover = nil
            exportCoverPreviewURL = nil
            exportCoverErrorMessage = error.localizedDescription
        }
    }

    public func clearExportCover() async {
        guard let bookID = selectedBook?.id, let coverStore else {
            exportCover = nil
            exportCoverPreviewURL = nil
            return
        }
        exportCover = nil
        exportCoverPreviewURL = nil
        exportCoverErrorMessage = nil
        try? await coverStore.remove(bookID: bookID)
    }

    private func reloadExportCover(for bookID: UUID) async {
        guard let coverStore else {
            exportCover = nil
            exportCoverPreviewURL = nil
            return
        }
        exportCoverErrorMessage = nil
        if let asset = try? await coverStore.existing(bookID: bookID) {
            exportCover = asset
            exportCoverPreviewURL = await coverStore.coverFileURL(bookID: bookID)
        } else {
            exportCover = nil
            exportCoverPreviewURL = nil
        }
    }

    public func clearExportError() {
        exportErrorMessage = nil
    }

    /// 导出面板的“去制作”动作：关掉面板，定位到第一处未就绪章节。
    public func focusFirstExportBlockingChapter() {
        guard let chapter = exportBlockingChapters.first else { return }
        isShowingExportSheet = false
        preparedExport = nil
        surfaceMode = .workspace
        workbenchTab = .production
        selectedChapterID = chapter.id
    }

    public func prepareExport(
        profile: AudiobookExportProfile,
        chapterIDs: [UUID]?,
        loudnessEnabled: Bool = false
    ) async {
        guard let bookID = selectedBook?.id, let exportController, !isPreparingExport else { return }
        isPreparingExport = true
        errorMessage = nil
        exportErrorMessage = nil
        if let exportCover, exportCover.bookID != bookID {
            self.exportCover = nil
        }
        let scopedCover = exportCover.flatMap { $0.bookID == bookID ? $0 : nil }
        let requestID = UUID()
        exportPreparationRequestID = requestID
        do {
            let prepared = try await exportController.prepare(
                bookID: bookID,
                chapterIDs: chapterIDs,
                profile: profile,
                cover: scopedCover,
                loudness: loudnessEnabled ? AudiobookLoudnessSettings() : nil,
                requestID: requestID
            )
            if exportPreparationRequestID == requestID {
                preparedExport = prepared
            }
        } catch let error as AudiobookExportError where error == .exportCancelled {
            bannerMessage = "已取消导出准备，未生成任何文件。"
        } catch {
            errorMessage = error.localizedDescription
            exportErrorMessage = error.localizedDescription
        }
        if exportPreparationRequestID == requestID {
            exportPreparationRequestID = nil
        }
        isPreparingExport = false
    }

    public func cancelExportPreparation() async {
        guard let requestID = exportPreparationRequestID, let exportController else { return }
        await exportController.cancel(requestID: requestID)
        isPreparingExport = false
        exportPreparationRequestID = nil
    }

    public func commitPreparedExport(destination: URL, overwriteConsent: AudiobookOverwriteConsent? = nil) async {
        guard let prepared = preparedExport, let exportController, let bookID = selectedBook?.id else { return }
        exportErrorMessage = nil
        do {
            try await exportController.commit(
                prepared,
                destination: destination,
                overwriteConsent: overwriteConsent
            )
            preparedExport = nil
            isShowingExportSheet = false
            await openBook(bookID)
            bannerMessage = "已成功导出至 \(destination.lastPathComponent)。"
        } catch {
            errorMessage = error.localizedDescription
            exportErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Route Leave & App Shutdown

    /// 切换路由离开有声书工坊：制作队列继续在后台运行，但听书立即保存书签并释放共享播放器。
    public func leaveWorkshop() async {
        let deferredRefresh = cancelWorkspaceRefresh()
        invalidateCastingAudition()
        bookSelectionLoad.reset()
        chapterSelectionLoad.reset()
        readinessSelectionLoad.reset()
        isLoadingChapterDetails = false
        await workspaceReader?.stop()
        await deferredRefresh?.value
        await listeningController?.leaveWorkshop()
    }

    /// 应用退出或停止：保存听书书签，优雅暂停在途分析与制作并持久化检查点。
    public func shutdown() async {
        let deferredRefresh = cancelWorkspaceRefresh()
        bookSelectionLoad.reset()
        chapterSelectionLoad.reset()
        readinessSelectionLoad.reset()
        unknownSpeakerProjectionGeneration &+= 1
        await workspaceReader?.stop()
        await deferredRefresh?.value
        await voiceCatalogModel.stop()
        invalidateCastingAudition()
        await listeningController?.leaveWorkshop()
        if let bookID = selectedBook?.id {
            await analysisPipeline?.cancel(bookID: bookID)
        }
        analysisTask?.cancel()
        productionRunID = nil
        productionProgressPollTask?.cancel()
        await productionController?.shutdown()
        let task = productionTask
        task?.cancel()
        if let task { await task.value }
        productionProgressPollTask = nil
        productionTask = nil
        productionBookID = nil
        isAnalyzing = false
        isProducing = false
        isPausingProduction = false
    }

    // MARK: - Private Data Reload Helpers

    private func readBookWorkspaceSnapshot(
        bookID: UUID,
        preferredChapterID: UUID?,
        preferredFragmentID: UUID?,
        store: AudiobookProjectStore
    ) async throws -> AudiobookBookWorkspaceSnapshot {
        guard let workspaceReader else { throw AudiobookWorkspaceError.staleInput }
        workspaceRequestGeneration &+= 1
        let request = AudiobookWorkspaceRequest(bookID: bookID, chapterID: preferredChapterID,
            preferredFragmentID: preferredFragmentID, selectionGeneration: workspaceRequestGeneration)
        let result = try await workspaceReader.load(request)
        // Publication gates keep late-result regressions independent of worker timing.
        await loadCheckpointForTesting?(bookID, nil, .beforeBookWorkspacePublication)
        await loadCheckpointForTesting?(bookID, result.snapshot.chapterDetails.chapterID, .beforeChapterDetailsPublication)
        try Task.checkCancellation()
        return result.snapshot
    }

    private func readChapterDetailsSnapshot(
        bookID: UUID,
        chapterID: UUID?,
        preferredFragmentID: UUID?,
        store: AudiobookProjectStore
    ) async throws -> AudiobookChapterDetailsSnapshot {
        guard let workspaceReader else { throw AudiobookWorkspaceError.staleInput }
        workspaceRequestGeneration &+= 1
        let request = AudiobookWorkspaceRequest(bookID: bookID, chapterID: chapterID,
            preferredFragmentID: preferredFragmentID, selectionGeneration: workspaceRequestGeneration)
        let result = try await workspaceReader.loadChapter(request)
        await loadCheckpointForTesting?(bookID, chapterID, .beforeChapterDetailsPublication)
        try Task.checkCancellation()
        return result.snapshot
    }

    @ObservationIgnored private var appliedChapterRevision: AudiobookWorkspaceRevision?

    private func applyChapterDetails(_ snapshot: AudiobookChapterDetailsSnapshot) {
        appliedChapterRevision = snapshot.revision
        chapterAtoms = snapshot.atoms
        chapterAnnotations = snapshot.annotations
        chapterFragments = snapshot.fragments
        chapterCandidates = snapshot.candidates
        atomTextsByID = snapshot.atomTextsByID
        fragmentTextsByID = snapshot.fragmentTextsByID
        selectedFragmentID = snapshot.selectedFragmentID
    }

    private func rebuildUnknownSpeakerIndex(
        from allAnnotations: [AudiobookAnnotation],
        chapters: [AudiobookChapter]
    ) async {
        unknownSpeakerProjectionGeneration &+= 1
        let generation = unknownSpeakerProjectionGeneration
        let bookID = selectedBook?.id
        guard let index = try? await AudiobookWorkspaceProjection.unknownSpeakers(annotations: allAnnotations, chapters: chapters),
              generation == unknownSpeakerProjectionGeneration, selectedBook?.id == bookID else { return }
        applyUnknownSpeakerIndex(index)
    }

    private func applyUnknownSpeakerIndex(_ index: AudiobookUnknownSpeakerIndex) {
        unknownCountByChapterID = index.countsByChapterID
        allUnknownAnnotations = index.annotations
        if let focused = focusedUnknownAtomID, !index.atomIDs.contains(focused) {
            focusedUnknownAtomID = index.annotations.first?.atomID
        }
    }

    private func reloadSelectedChapterDetails(onlyIfChanged: Bool = false) async {
        guard let store, let bookID = selectedBook?.id, let chapterID = selectedChapterID else {
            chapterSelectionLoad.reset()
            applyChapterDetails(.empty)
            isLoadingChapterDetails = false
            return
        }
        if onlyIfChanged && isLoadingChapterDetails { return }
        if !onlyIfChanged { isLoadingChapterDetails = true }
        let preferredFragmentID = selectedFragmentID
        do {
            guard let snapshot = try await chapterSelectionLoad.load(
                id: "\(bookID.uuidString):\(chapterID.uuidString)",
                operation: {
                    try await self.readChapterDetailsSnapshot(
                        bookID: bookID,
                        chapterID: chapterID,
                        preferredFragmentID: preferredFragmentID,
                        store: store
                    )
                }
            ) else { return }
            guard selectedBook?.id == bookID, selectedChapterID == chapterID else { return }
            if !onlyIfChanged || snapshot.revision != appliedChapterRevision { applyChapterDetails(snapshot) }
            isLoadingChapterDetails = false
        } catch {
            guard selectedBook?.id == bookID, selectedChapterID == chapterID else { return }
            applyChapterDetails(.empty)
            isLoadingChapterDetails = false
            errorMessage = error.localizedDescription
        }
    }

    private func refreshChapterReadinessMap(for bookID: UUID) async {
        guard let castController, selectedBook?.id == bookID else { return }
        guard let map = try? await readinessSelectionLoad.load(
            id: bookID.uuidString,
            operation: { try await castController.chapterReadinessMap(for: bookID) }
        ) else { return }
        guard selectedBook?.id == bookID else { return }
        chapterReadinessByID = map
    }
}
