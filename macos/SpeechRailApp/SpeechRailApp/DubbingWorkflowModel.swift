import Foundation
import Observation
import SpeechRailControlKit

@MainActor
@Observable
public final class DubbingWorkflowModel {

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
    public var playingWorkID: String? { playback.playingWorkID }
    public var playingDubbingCandidateID: String? { playback.playingDubbingCandidateID }
    private var capabilityFacade: AppCapabilityFacade { capabilities.capabilityFacade }
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
        voices: any CreatorVoiceReading,
        playback: SharedPlaybackOwner,
        admission: SpeechCreationAdmission,
        feedback: CreatorFeedback,
        speechRenderClient: (any SpeechRailSpeechRenderClient)? = nil,
        receiptClient: (any SpeechRailReceiptClient)? = nil,
        workStore: CreativeWorkStore = CreativeWorkStore(),
        dubbingProjectStore: DubbingProjectStore? = nil
    ) {
        self.capabilities = capabilities
        self.voices = voices
        self.playback = playback
        self.admission = admission
        self.feedback = feedback
        self.speechRenderClient = speechRenderClient
        self.receiptClient = receiptClient
        self.workStore = workStore
        self.dubbingProjectStore = dubbingProjectStore ?? DubbingProjectStore(
            directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SpeechRail/DubbingProjects", isDirectory: true)
        )
        self.works = (try? workStore.list()) ?? []
    }
    private let speechRenderClient: (any SpeechRailSpeechRenderClient)?
    private let voices: any CreatorVoiceReading
    private var creatorVoices: [CreatorVoice] { voices.creatorVoices }
    private var creatorVoicesLoadState: CreatorVoicesLoadState { voices.creatorVoicesLoadState }

    private func playDubbingAudio(data: Data, target: PlaybackTarget) throws {
        try playback.play(data: data, target: target) { [weak self] success in
            guard let self, !success else { return }
            if case .work = target {
                self.workPlaybackMessage = "作品播放失败，请重新试听或重新生成。"
            } else {
                self.creatorMessage = "音频播放失败，请重试。"
            }
        }
    }
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
    public private(set) var works: [CreativeWork] = []
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
    public private(set) var dubbingExportBundle: DubbingExportBundle?
    private var dubbingExportPreparedSelection: [String]?
    private var dubbingExportedSelection: [String]?
    public private(set) var worksMessage: String?
    /// Result of an explicit work action (delete/rename). Kept apart from
    /// `worksMessage`, which reports that the history itself is unreadable.
    public private(set) var workActionMessage: String?
    public private(set) var workPlaybackMessage: String?
    private let receiptClient: (any SpeechRailReceiptClient)?
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
    private var synthesisTask: Task<Void, Never>?

    /// 作品详情面板选中的作品：把它的包络先算出来（命中缓存立即返回）。
    /// 读文件是同步的本机小 I/O（与 `playWork` 同量级），解码放到主线程之外。
    public func prepareWaveform(for work: CreativeWork) {
        let key = Self.envelopeKey(kind: "work", id: work.id)
        guard playback.waveformEnvelope(key: key) == nil,
              let url = try? workStore.audioURL(for: work)
        else { return }
        cacheEnvelope(key: key) { buckets in
            AudioEnvelope.levels(forAudioFileAt: url, buckets: buckets)
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

    /// Own the request task within this workflow so navigating between pages
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
            try playDubbingAudio(data: pending.audioData, target: .pendingDubbing(pending.renderID))

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
                durationSeconds: playback.duration(for: render.audioData)
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
            dubbingMessage = CreatorWorkflowErrors.message(for: error)
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
            try playDubbingAudio(data: data, target: .dubbingCandidate(candidate.id))

            workPlaybackMessage = nil
        } catch {
            clearPlaybackState()

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
        guard admission.acquire(.dubbing) else { return nil }
        creatorMessage = nil
        defer { admission.release(.dubbing) }

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
               durationSeconds: playback.duration(for: data),
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
                try playDubbingAudio(data: data, target: .pendingDubbing(pending.renderID))

            } catch {
                clearPlaybackState()
                workPlaybackMessage = "音频已生成，但本次无法播放；可以重新生成后试听。"
            }
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            creatorMessage = CreatorWorkflowErrors.message(for: error)
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
                try playDubbingAudio(data: data, target: .work(work.id))
            } catch {
                clearPlaybackState()
                throw error
            }

            // 播放控制器只有一个，动手播作品就说明音色试听已经结束：留下旧的
            // playingVoiceID 会让音色库显示一个并不在响的“停止试听”状态
            // (REDESIGN-SPEC §7.1：全 App 同一时刻只有一个声音)。

            workPlaybackMessage = nil
            cacheEnvelope(key: Self.envelopeKey(kind: "work", id: work.id)) { buckets in
                AudioEnvelope.levels(forAudioData: data, buckets: buckets)
            }
        } catch {
            workPlaybackMessage = "作品音频暂时不可用，请重新生成或确认本机作品文件仍在。"
        }
    }

}
