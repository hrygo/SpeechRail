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
    public private(set) var characters: [AudiobookCharacter] = []
    public var selectedRoleID: UUID?
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
            selectedBook = book
            chapters = loadedChapters
            characters = loadedCharacters
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

        analysisTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let summary = try await pipeline.run(bookID: targetID, config: snapshot)
                self.analysisSummary = summary
                self.isAnalyzing = false
                await self.autoAssignRecommendedVoices(for: targetID)
                await self.refreshShelf()
                if self.selectedBook?.id == targetID {
                    await self.openBook(targetID)
                }
                self.bannerMessage = "全书分析已完成（共 \(summary.completedWindows) 个窗口，待确认说话人 \(summary.unknownSpeakerCount) 处）。"
            } catch {
                let failureDescription = error.localizedDescription
                self.isAnalyzing = false
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
        await pipeline.cancel(bookID: bookID)
        analysisTask?.cancel()
        isAnalyzing = false
        await refreshShelf()
        await openBook(bookID)
        bannerMessage = "全书分析已暂停，已完成的窗口检查点已保存。"
    }

    /// 根据全书角色声线线索与当前可用音色目录，为尚未配声的角色自动推荐并预绑定音色。
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

        let recommended = AudiobookCastRegistry.recommendVoiceBindings(
            characters: chars,
            availableVoices: candidateVoices,
            existingBindings: existing
        )

        var newlyBoundCount = 0
        for role in chars {
            guard existing[role.id]?.isSynthesisReady != true,
                  let binding = recommended[role.id]
            else { continue }
            if (try? await castController.bindVoice(bookID: targetID, roleID: role.id, binding: binding)) != nil {
                newlyBoundCount += 1
            }
        }

        if newlyBoundCount > 0, selectedBook?.id == targetID {
            voiceBindings = (try? await store.voiceBindings(for: targetID)) ?? voiceBindings
            selectedBook = (try? await store.book(id: targetID)) ?? selectedBook
            await refreshChapterReadinessMap(for: targetID)
        }
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
            voiceReturnBannerMessage = "已将新音色绑定给角色「\(roleName)」。"
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
