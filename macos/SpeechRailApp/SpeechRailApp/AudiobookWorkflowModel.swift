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
                return "正在暂停…"
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
    public var selectedChapterID: UUID? {
        didSet {
            if selectedChapterID != oldValue {
                Task { await reloadSelectedChapterDetails() }
            }
        }
    }
    public enum CastFilterScope: String, CaseIterable, Equatable, Sendable, Identifiable {
        case all
        case leads
        case inCurrentChapter
        case minorEnsemble

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .all: return "全部"
            case .leads: return "核心主角"
            case .inCurrentChapter: return "本章出场"
            case .minorEnsemble: return "配角群像"
            }
        }
    }

    public private(set) var characters: [AudiobookCharacter] = []
    public var selectedRoleID: UUID?
    public var castFilterScope: CastFilterScope = .all
    public private(set) var roleStatsByID: [UUID: AudiobookRoleDialogueStats] = [:]
    public private(set) var voiceBindings: [UUID: AudiobookVoiceBinding] = [:]
    public private(set) var chapterReadinessByID: [UUID: AudiobookChapterReadinessState] = [:]
    public private(set) var chapterAtoms: [AudiobookTextAtom] = []
    public private(set) var chapterAnnotations: [AudiobookAnnotation] = []
    public private(set) var chapterFragments: [AudiobookFragment] = []
    public private(set) var chapterCandidates: [AudiobookRenderCandidate] = []
    public private(set) var atomTextsByID: [UUID: String] = [:]
    public private(set) var fragmentTextsByID: [UUID: String] = [:]
    public var selectedFragmentID: UUID?
    public var selectedAtomIDs: Set<UUID> = []

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
    public private(set) var productionProgress: AudiobookProductionProgress?
    public private(set) var resumePlan: AudiobookResumePlan?
    public private(set) var exportCapabilities: MediaCapabilitiesSnapshot = .init(
        available: false,
        encoders: [],
        supportsM4B: false,
        supportsMP3: false
    )
    public var preparedExport: AudiobookPreparedExport?
    public private(set) var isPreparingExport: Bool = false
    public private(set) var exportRecords: [AudiobookExportRecord] = []

    public var importPreview: AudiobookImportPreview?
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

    public private(set) var listeningController: AudiobookListeningController?

    // MARK: - Internal Actors & Tasks

    private let dependencies: AudiobookDependencies
    private let playbackOwner: SharedPlaybackOwner
    private let admission: SpeechCreationAdmission
    private var store: AudiobookProjectStore?
    private var analysisPipeline: AudiobookAnalysisPipeline?
    private var castController: AudiobookCastController?
    private var revisionController: AudiobookRevisionController?
    private var productionController: AudiobookProductionController?
    private var exportController: AudiobookExportController?

    private var analysisTask: Task<Void, Never>?
    private var productionTask: Task<Void, Never>?
    private var analysisGeneration: Int = 1

    public init(
        dependencies: AudiobookDependencies = .unavailable,
        playbackOwner: SharedPlaybackOwner = SharedPlaybackOwner(),
        admission: SpeechCreationAdmission = SpeechCreationAdmission()
    ) {
        self.dependencies = dependencies
        self.playbackOwner = playbackOwner
        self.admission = admission
        bootstrapIfPossible()
    }

    private func bootstrapIfPossible() {
        guard store == nil else { return }
        guard let createdStore = try? dependencies.makeStore() else { return }
        self.store = createdStore
        let cast = AudiobookCastController(store: createdStore)
        let rev = AudiobookRevisionController(store: createdStore)
        let prod = AudiobookProductionController(
            store: createdStore,
            castController: cast,
            revisionController: rev,
            renderer: dependencies.speechRenderer,
            admission: admission,
            clock: dependencies.clock
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
        self.castController = cast
        self.revisionController = rev
        self.productionController = prod
        self.exportController = exp
        self.analysisPipeline = pipe
        self.listeningController = listen
    }

    // MARK: - Computed Projections & Next Action Resolution

    public var currentAnalysisConfigSnapshot: AudiobookAnalysisConfigSnapshot {
        dependencies.resolveAnalysisSnapshot(analysisGeneration)
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
        guard let selectedBook else { return 0 }
        return shelfBooks.first(where: { $0.id == selectedBook.id })?.unknownSpeakerCount
            ?? unknownAnnotationsInSelectedChapter.count
    }

    public var isAuditionConfirmedForSelectedBook: Bool {
        guard let book = selectedBook else { return false }
        return book.confirmedCastRevisionID != nil && book.confirmedAuditionVoiceSetDigest != nil
    }

    /// 严格唯一主动作推导：任何状态下只突出下一步最合理的动作。
    public func nextPrimaryAction(for summary: AudiobookBookSummary) -> PrimaryBookAction {
        let book = summary.book
        if isAnalyzing && selectedBook?.id == book.id {
            return .pauseAnalysis
        }
        if isPausingProduction && selectedBook?.id == book.id {
            return .pauseProduction
        }
        if isProducing && selectedBook?.id == book.id {
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

    public func refreshShelf() async {
        bootstrapIfPossible()
        guard let store else { return }
        do {
            _ = try await store.recover()
            shelfBooks = try await store.listBooks()
            trashedBooks = try await store.listTrashedBooks()
            if let exp = exportController {
                exportCapabilities = await exp.checkCapabilities()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func prepareImport(fileURL: URL, encoding: AudiobookTextEncoding? = nil) async {
        do {
            errorMessage = nil
            let preview = try await AudiobookTXTImporter.prepare(fileURL: fileURL, encoding: encoding)
            importFileURL = fileURL
            importPreview = preview
            isShowingImportSheet = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func confirmImport() async {
        bootstrapIfPossible()
        guard let store, let preview = importPreview else { return }
        do {
            let bookID = try await store.importBook(preview)
            isShowingImportSheet = false
            importPreview = nil
            await refreshShelf()
            await openBook(bookID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func openBook(_ bookID: UUID) async {
        bootstrapIfPossible()
        guard let store else { return }
        do {
            errorMessage = nil
            let book = try await store.book(id: bookID)
            let loadedChapters = try await store.chapters(for: bookID).sorted { $0.ordinal < $1.ordinal }
            let loadedCharacters = try await store.characters(for: bookID)
            let loadedBindings = try await store.voiceBindings(for: bookID)
            let loadedExports = try await store.exportRecords(for: bookID)
            let allAnnotations = (try? await store.annotations(for: bookID)) ?? []
            let (_, computedStats, _) = AudiobookCastRegistry.computeRoleDialogueStats(
                characters: loadedCharacters,
                annotations: allAnnotations
            )
            selectedBook = book
            chapters = loadedChapters
            characters = loadedCharacters
            roleStatsByID = computedStats
            voiceBindings = loadedBindings
            exportRecords = loadedExports
            if selectedChapterID == nil || !chapters.contains(where: { $0.id == selectedChapterID }) {
                selectedChapterID = chapters.first?.id
            }
            if selectedRoleID == nil {
                selectedRoleID = characters.first?.id
            }
            if let rev = revisionController {
                resumePlan = try? await rev.resumePlan(bookID: bookID)
            }
            await reloadSelectedChapterDetails()
            await refreshChapterReadinessMap(for: bookID)
            surfaceMode = .workspace
            if book.analysisState == .allWindowsValidated
                && book.confirmedCastRevisionID != nil
                && book.confirmedAuditionVoiceSetDigest != nil
            {
                workbenchTab = .production
            } else {
                workbenchTab = .preparation
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func trashBook(_ bookID: UUID) async {
        guard let store else { return }
        do {
            if selectedBook?.id == bookID {
                await listeningController?.leaveWorkshop()
            }
            try await store.trashBook(id: bookID)
            if selectedBook?.id == bookID {
                selectedBook = nil
                surfaceMode = .shelf
            }
            await refreshShelf()
            bannerMessage = "已移入有声书废纸篓，原始 TXT 与已导出的外部文件不受影响。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func restoreTrashedBook(_ bookID: UUID) async {
        guard let store else { return }
        do {
            try await store.restoreTrashedBook(id: bookID)
            await refreshShelf()
            bannerMessage = "已从废纸篓恢复书籍及其音频片段。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Analysis Lifecycle

    public func beginAnalysis(_ bookID: UUID? = nil) {
        let targetID = bookID ?? selectedBook?.id
        guard let targetID, let pipeline = analysisPipeline else { return }
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
                let summary = try await pipeline.run(bookID: targetID, config: snapshot, progressSink: runSink)
                guard self.analysisInstallEpoch == installEpoch else { return }
                self.analysisSummary = summary
                self.isAnalyzing = false
                self.stopAnalysisClock()
                await self.autoAssignRecommendedVoices(for: targetID)
                await self.refreshShelf()
                if self.selectedBook?.id == targetID {
                    await self.openBook(targetID)
                }
                self.bannerMessage = "全书分析已完成（共 \(summary.completedWindows) 个窗口，待确认说话人 \(summary.unknownSpeakerCount) 处）。"
            } catch {
                guard self.analysisInstallEpoch == installEpoch else { return }
                let failureDescription = error.localizedDescription
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
        analysisClockTick = Date()
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

    /// 分析时钟：每秒 tick 一次，仅用于渲染"已用/上次进展"相对时间，
    /// 不轮询管线、不读库；分析结束/暂停即停。
    public private(set) var analysisClockTick: Date = Date()
    private var analysisClockTask: Task<Void, Never>?

    private func startAnalysisClock() {
        analysisClockTask?.cancel()
        analysisClockTick = Date()
        analysisClockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.analysisClockTick = Date()
            }
        }
    }

    private func stopAnalysisClock() {
        analysisClockTask?.cancel()
        analysisClockTask = nil
    }

    /// 根据全书角色声线线索与当前可用音色目录，为尚未配声的角色自动推荐并预绑定音色（含四级分层、双池隔离、同场图着色与微语速错位）。
    public func autoAssignRecommendedVoices(
        for bookID: UUID? = nil,
        availableVoices: [SafeVoiceEntry]? = nil
    ) async {
        let targetID = bookID ?? selectedBook?.id
        guard let targetID, let store, let castController else { return }
        let candidateVoices: [SafeVoiceEntry]
        if let availableVoices, !availableVoices.isEmpty {
            candidateVoices = availableVoices
        } else if let fetched = (try? await dependencies.speechRenderer.fetchEffectiveCapabilities())?.voices,
                  !fetched.isEmpty
        {
            candidateVoices = fetched
        } else {
            return
        }

        guard let chars = try? await store.characters(for: targetID),
              let existing = try? await store.voiceBindings(for: targetID)
        else { return }
        let allAnnotations = (try? await store.annotations(for: targetID)) ?? []

        let (stratifiedChars, stats, _) = AudiobookCastRegistry.computeRoleDialogueStats(
            characters: chars,
            annotations: allAnnotations,
            availableVoiceCount: candidateVoices.count
        )

        let recommended = AudiobookCastRegistry.recommendVoiceBindings(
            characters: stratifiedChars,
            availableVoices: candidateVoices,
            existingBindings: existing,
            annotations: allAnnotations,
            bookID: targetID
        )

        // 若某音色在推荐方案中被多个非旁白角色共用，自动确保持有该音色的角色均开启 allowSharedMinorVoice = true
        var voiceUsageCount: [String: Int] = [:]
        for (_, b) in recommended {
            voiceUsageCount[b.voiceID, default: 0] += 1
        }
        var updatedChars = stratifiedChars
        var didModifyCharFlags = (updatedChars != chars)
        for idx in updatedChars.indices where !updatedChars[idx].isNarrator {
            let rid = updatedChars[idx].id
            if let rec = recommended[rid], (voiceUsageCount[rec.voiceID] ?? 0) > 1 {
                if !updatedChars[idx].allowSharedMinorVoice {
                    updatedChars[idx].isMajor = false
                    updatedChars[idx].allowSharedMinorVoice = true
                    didModifyCharFlags = true
                }
            }
        }
        if didModifyCharFlags {
            try? await store.saveCharacters(bookID: targetID, characters: updatedChars)
        }

        var newlyBoundCount = 0
        for role in updatedChars {
            guard existing[role.id]?.isSynthesisReady != true,
                  let binding = recommended[role.id]
            else { continue }
            if (try? await castController.bindVoice(bookID: targetID, roleID: role.id, binding: binding)) != nil {
                newlyBoundCount += 1
            }
        }

        if selectedBook?.id == targetID {
            characters = (try? await store.characters(for: targetID)) ?? updatedChars
            roleStatsByID = stats
            voiceBindings = (try? await store.voiceBindings(for: targetID)) ?? voiceBindings
            selectedBook = (try? await store.book(id: targetID)) ?? selectedBook
            await refreshChapterReadinessMap(for: targetID)
        }
    }

    // MARK: - Stratified Cast Helpers & Batch Archetype Binding

    public var filteredCharacters: [AudiobookCharacter] {
        switch castFilterScope {
        case .all:
            return characters
        case .leads:
            return characters.filter { role in
                role.isNarrator
                    || roleStatsByID[role.id]?.tier == .lead
                    || !role.allowSharedMinorVoice
            }
        case .inCurrentChapter:
            guard let chapterID = selectedChapterID else { return characters }
            let chapterSpeakerIDs = Set(chapterAnnotations.compactMap(\.assignment.roleID))
            return characters.filter { role in
                role.isNarrator
                    || chapterSpeakerIDs.contains(role.id)
                    || roleStatsByID[role.id]?.speakingChapterIDs.contains(chapterID) == true
                    || role.chapterIDs.contains(chapterID)
            }
        case .minorEnsemble:
            return characters.filter { !$0.isNarrator && $0.allowSharedMinorVoice }
        }
    }

    /// 返回与指定角色在同一场戏直接交谈且绑定了相同 voiceID 的对手角色名称列表（用于实时同场撞音预警）。
    public func sceneConflictPartnerNames(for roleID: UUID) -> [String] {
        guard let myVoiceID = voiceBindings[roleID]?.voiceID,
              let stat = roleStatsByID[roleID],
              !stat.scenePartnerRoleIDs.isEmpty
        else { return [] }

        return stat.scenePartnerRoleIDs.compactMap { partnerID -> String? in
            guard voiceBindings[partnerID]?.voiceID == myVoiceID else { return nil }
            return characters.first(where: { $0.id == partnerID })?.displayName
        }.sorted()
    }

    /// 统计全书存在同场紧邻对手戏撞音的角色数量。
    public var totalSceneVoiceConflictCount: Int {
        characters.filter { !sceneConflictPartnerNames(for: $0.id).isEmpty }.count
    }

    /// 按声部行当一键批量换绑配角音色（保护核心主角不被覆盖）。
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
                bannerMessage = "已将 \(count) 名「\(archetype.shortBadgeTitle)」配角批量绑定为「\(voice.name)」，并自动配置微语速区分。"
            } else {
                bannerMessage = "当前没有属于「\(archetype.shortBadgeTitle)」且开启共享声线的次要角色。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 调整单个角色已绑定音色的微语速档位。
    public func updateRoleAllowedSpeed(roleID: UUID, speed: Double) async {
        guard let existing = voiceBindings[roleID] else { return }
        let clamped = min(Double(AudiobookLimits.maxPlaybackRate), max(Double(AudiobookLimits.minPlaybackRate), speed))
        let updated = AudiobookVoiceBinding(
            roleID: existing.roleID,
            voiceID: existing.voiceID,
            voiceRevision: existing.voiceRevision,
            modelRevision: existing.modelRevision,
            isSynthesisReady: existing.isSynthesisReady,
            allowedSpeed: clamped,
            callerSeed: existing.callerSeed
        )
        await bindVoice(roleID: roleID, binding: updated)
    }

    // MARK: - Cast, Speaker Resolution & Voice Round-Trip

    public func assignSpeaker(atomIDs: [UUID], roleID: UUID) async {
        guard let bookID = selectedBook?.id, let castController else { return }
        do {
            try await castController.assignRole(bookID: bookID, atomIDs: atomIDs, roleID: roleID)
            await reloadSelectedChapterDetails()
            await refreshChapterReadinessMap(for: bookID)
            await refreshShelf()
            bannerMessage = "已更新 \(atomIDs.count) 处段落的说话人归属。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func undoLastSpeakerAssignment() async {
        guard let bookID = selectedBook?.id, let castController else { return }
        do {
            try await castController.undoLastAssignment(bookID: bookID)
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
            await reloadSelectedChapterDetails()
            await refreshChapterReadinessMap(for: bookID)
            await refreshShelf()
            bannerMessage = "已拆分出新角色「\(newRole.displayName)」。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func bindVoice(roleID: UUID, binding: AudiobookVoiceBinding) async {
        guard let bookID = selectedBook?.id, let castController, let store else { return }
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

    public func toggleSharedMinorVoice(roleID: UUID, allowed: Bool) async {
        guard let bookID = selectedBook?.id, let castController, let store else { return }
        do {
            try await castController.setAllowSharedMinorVoice(bookID: bookID, roleID: roleID, allowed: allowed)
            characters = try await store.characters(for: bookID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func confirmCastAndAudition() async {
        guard let bookID = selectedBook?.id, let castController, let store else { return }
        do {
            errorMessage = nil
            let castRev = try await castController.currentCastRevisionID(for: bookID)
            try await castController.confirmCast(bookID: bookID, revisionID: castRev)
            let voiceDigest = try await castController.currentVoiceSetDigest(for: bookID)
            try await castController.confirmAudition(bookID: bookID, voiceSetDigest: voiceDigest)
            selectedBook = try await store.book(id: bookID)
            await refreshChapterReadinessMap(for: bookID)
            await refreshShelf()
            workbenchTab = .production
            bannerMessage = "已确认全书人物与试听声音，可开始制作已确认章节。"
        } catch {
            errorMessage = error.localizedDescription
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
        binding: AudiobookVoiceBinding,
        context: AudiobookVoiceReturnContext? = nil
    ) async {
        guard let targetContext = context ?? pendingVoiceReturnContext,
              let castController,
              let store
        else { return }

        guard let activeBookID = selectedBook?.id else {
            voiceReturnBannerMessage = "新音色已保存到音色库；重新打开对应书籍后可手动选择绑定。"
            pendingVoiceReturnContext = nil
            return
        }

        do {
            try await castController.completeVoiceReturn(
                context: targetContext,
                activeBookID: activeBookID,
                binding: binding
            )
            voiceBindings = try await store.voiceBindings(for: activeBookID)
            selectedBook = try await store.book(id: activeBookID)
            pendingVoiceReturnContext = nil
            let roleName = characters.first(where: { $0.id == targetContext.roleID })?.displayName ?? "当前角色"
            voiceReturnBannerMessage = "已将新音色「\(binding.voiceID)」绑定给角色「\(roleName)」。"
            await refreshChapterReadinessMap(for: activeBookID)
            await refreshShelf()
        } catch {
            pendingVoiceReturnContext = nil
            voiceReturnBannerMessage = error.localizedDescription
        }
    }

    // MARK: - Production & Revision Actions

    public func makeConfirmedChapters(chapterIDs: [UUID]? = nil) {
        guard let bookID = selectedBook?.id, let productionController else { return }
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
            errorMessage = AudiobookProductionError.noReadyChaptersSelected.errorDescription
            return
        }

        productionTask?.cancel()
        isProducing = true
        isPausingProduction = false
        errorMessage = nil

        productionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await productionController.start(bookID: bookID, chapterIDs: targetChapterIDs)
                self.isProducing = false
                self.isPausingProduction = false
                self.productionProgress = await productionController.progress(for: bookID)
                await self.openBook(bookID)
                await self.refreshShelf()
                self.bannerMessage = "所选章节制作已完成，可立即进入听书或导出。"
            } catch let error as AudiobookProductionError where error == .cancelled {
                self.isProducing = false
                self.isPausingProduction = false
                self.productionProgress = await productionController.progress(for: bookID)
                await self.openBook(bookID)
                await self.refreshShelf()
            } catch {
                self.isProducing = false
                self.isPausingProduction = false
                self.productionProgress = await productionController.progress(for: bookID)
                self.errorMessage = error.localizedDescription
                await self.openBook(bookID)
                await self.refreshShelf()
            }
        }
    }

    public func pauseProduction() async {
        guard let productionController else { return }
        isPausingProduction = true
        await productionController.pause()
        productionTask?.cancel()
        isProducing = false
        isPausingProduction = false
        if let bookID = selectedBook?.id {
            productionProgress = await productionController.progress(for: bookID)
            await openBook(bookID)
            await refreshShelf()
        }
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
        guard let bookID = selectedBook?.id,
              let targetChapterID = chapterID ?? selectedChapterID ?? chapters.first?.id,
              let listeningController
        else { return }
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
        do {
            await listeningController?.prepareForExternalPreview()
            let url = try await store.resolveAssetFileURL(for: candidate)
            let data = try Data(contentsOf: url)
            try playbackOwner.play(data: data, target: .dubbingCandidate(candidate.id.uuidString))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Export Actions

    public func prepareExport(profile: AudiobookExportProfile, chapterIDs: [UUID]?) async {
        guard let bookID = selectedBook?.id, let exportController else { return }
        isPreparingExport = true
        errorMessage = nil
        do {
            let prepared = try await exportController.prepare(
                bookID: bookID,
                chapterIDs: chapterIDs,
                profile: profile
            )
            preparedExport = prepared
            isPreparingExport = false
        } catch {
            isPreparingExport = false
            errorMessage = error.localizedDescription
        }
    }

    public func commitPreparedExport(destination: URL, overwriteConsent: AudiobookOverwriteConsent? = nil) async {
        guard let prepared = preparedExport, let exportController, let bookID = selectedBook?.id else { return }
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
        }
    }

    // MARK: - Route Leave & App Shutdown

    /// 切换路由离开有声书工坊：制作队列继续在后台运行，但听书立即保存书签并释放共享播放器。
    public func leaveWorkshop() async {
        await listeningController?.leaveWorkshop()
    }

    /// 应用退出或停止：保存听书书签，优雅暂停在途分析与制作并持久化检查点。
    public func shutdown() async {
        await listeningController?.leaveWorkshop()
        if let bookID = selectedBook?.id {
            await analysisPipeline?.cancel(bookID: bookID)
        }
        analysisTask?.cancel()
        await productionController?.shutdown()
        productionTask?.cancel()
        isAnalyzing = false
        isProducing = false
        isPausingProduction = false
    }

    // MARK: - Private Data Reload Helpers

    private func reloadSelectedChapterDetails() async {
        guard let store, let bookID = selectedBook?.id, let chapterID = selectedChapterID else {
            chapterAtoms = []
            chapterAnnotations = []
            chapterFragments = []
            chapterCandidates = []
            atomTextsByID = [:]
            fragmentTextsByID = [:]
            return
        }
        do {
            let source = try await store.sourceIndex(for: bookID)
            let atoms = try await store.atoms(for: bookID, chapterID: chapterID)
                .filter { $0.kind != .formatting }
                .sorted { $0.ordinal < $1.ordinal }
            let annotations = try await store.annotations(for: bookID, chapterID: chapterID)
                .sorted { $0.sourceRange < $1.sourceRange }
            let fragments = try await store.fragments(for: bookID, chapterID: chapterID)
                .sorted { $0.ordinal < $1.ordinal }
            let allCandidates = try await store.candidates(for: bookID)
            let fragmentIDSet = Set(fragments.map(\.id))

            var atomMap: [UUID: String] = [:]
            for atom in atoms {
                atomMap[atom.id] = (try? source.text(in: atom.sourceRange)) ?? ""
            }
            var fragMap: [UUID: String] = [:]
            for frag in fragments {
                fragMap[frag.id] = (try? source.text(in: frag.sourceRange)) ?? ""
            }

            chapterAtoms = atoms
            chapterAnnotations = annotations
            chapterFragments = fragments
            chapterCandidates = allCandidates.filter { fragmentIDSet.contains($0.fragmentID) }
            atomTextsByID = atomMap
            fragmentTextsByID = fragMap
            if selectedFragmentID == nil || !fragmentIDSet.contains(selectedFragmentID!) {
                selectedFragmentID = fragments.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshChapterReadinessMap(for bookID: UUID) async {
        guard let castController else { return }
        var map: [UUID: AudiobookChapterReadinessState] = [:]
        for chapter in chapters {
            if let state = try? await castController.chapterReadiness(bookID: bookID, chapterID: chapter.id) {
                map[chapter.id] = state
            }
        }
        chapterReadinessByID = map
    }
}
