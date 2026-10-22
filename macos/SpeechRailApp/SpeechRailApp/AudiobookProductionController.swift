import AVFoundation
import Foundation
import SpeechRailControlKit

/// T08：有声书正式制作队列、冻结条件核验、租约准入、有限重试与暂停收尾。
public enum AudiobookProductionError: LocalizedError, Equatable, Sendable {
    case globalAnalysisNotCompleted
    case castNotConfirmed
    case auditionNotConfirmed
    case chapterBlockedByUnknownSpeakers(chapterID: UUID)
    case noReadyChaptersSelected
    case admissionBusy
    case taskScopeChanged
    case capabilityVoiceUnavailable(voiceID: String, reason: String)
    case capabilityRevisionMismatch(voiceID: String, expected: String?, actual: String?)
    case unauthorizedService
    case transientRetriesExhausted(fragmentID: UUID, lastReason: String)
    case checkpointNotSaved(reason: String)
    case pauseWithUnconfirmedRemoteStop(fragmentID: UUID)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .globalAnalysisNotCompleted:
            return "请先完成全书分析，再开始正式制作。"
        case .castNotConfirmed:
            return "请先确认全书角色与配声绑定。"
        case .auditionNotConfirmed:
            return "请先试听并确认旁白与主要角色声音，再开始正式制作。"
        case .chapterBlockedByUnknownSpeakers:
            return "所选章节仍包含未确认的说话人，请先确认说话人后继续。"
        case .noReadyChaptersSelected:
            return "没有已就绪的可制作章节。"
        case .taskScopeChanged:
            return "制作条件或原任务范围已变化，请恢复原条件或重新预览范围。已有音频保留。"
        case .admissionBusy:
            return "当前已有另一个语音制作任务正在运行，请稍候再试。"
        case let .capabilityVoiceUnavailable(voiceID, reason):
            return "角色绑定的音色「\(voiceID)」当前不可用于正式制作（\(reason)）。"
        case let .capabilityRevisionMismatch(voiceID, expected, _):
            return "音色「\(voiceID)」或模型版本已发生变化（期望 \(expected ?? "未声明")），请重新确认声音后再继续。"
        case .unauthorizedService:
            return "本机语音服务鉴权未通过，请检查服务连接。"
        case let .transientRetriesExhausted(_, reason):
            return "语音服务繁忙或暂态错误已达重试上限：\(reason)"
        case let .checkpointNotSaved(reason):
            return "制作已停止，但任务记录未能保存，重新打开后可能无法接着制作。请检查磁盘空间和作品库的写入权限：\(reason)"
        case .pauseWithUnconfirmedRemoteStop:
            return "制作已暂停；当前在途片段的服务端停止状态尚未确认，稍后继续时将自动核对。"
        case .cancelled:
            return "章节制作已暂停。"
        }
    }
}

public enum AudiobookProductionPhase: String, Codable, Sendable {
    case preparing, checkingSavedAudio, rendering, waitingForService, saving, assemblingChapter, completed

    public var title: String {
        switch self {
        case .preparing: "正在准备制作"
        case .checkingSavedAudio: "正在核对已保存的声音"
        case .rendering: "正在生成声音"
        case .waitingForService: "语音服务暂忙，正在重试"
        case .saving: "正在保存声音"
        case .assemblingChapter: "正在整理章节音频"
        case .completed: "本次制作已完成"
        }
    }
}

public struct AudiobookProductionProgress: Codable, Equatable, Sendable {
    public var bookID: UUID
    public var state: AudiobookProductionState
    public var currentChapterID: UUID?
    public var currentFragmentID: UUID?
    public var completedFragments: Int
    public var totalFragments: Int
    public var unconfirmedRemoteStopFragmentID: UUID?
    public var lastErrorMessage: String?
    public var phase: AudiobookProductionPhase
    public var currentChapterOrdinal: Int?
    public var totalChapters: Int
    public var reusedFragments: Int
    public var retryAttempt: Int
    public var startedAt: Date
    public var updatedAt: Date

    public init(
        bookID: UUID,
        state: AudiobookProductionState,
        currentChapterID: UUID? = nil,
        currentFragmentID: UUID? = nil,
        completedFragments: Int = 0,
        totalFragments: Int = 0,
        unconfirmedRemoteStopFragmentID: UUID? = nil,
        lastErrorMessage: String? = nil,
        phase: AudiobookProductionPhase = .preparing,
        currentChapterOrdinal: Int? = nil,
        totalChapters: Int = 0,
        reusedFragments: Int = 0,
        retryAttempt: Int = 0,
        startedAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.bookID = bookID
        self.state = state
        self.currentChapterID = currentChapterID
        self.currentFragmentID = currentFragmentID
        self.completedFragments = completedFragments
        self.totalFragments = totalFragments
        self.unconfirmedRemoteStopFragmentID = unconfirmedRemoteStopFragmentID
        self.lastErrorMessage = lastErrorMessage
        self.phase = phase
        self.currentChapterOrdinal = currentChapterOrdinal
        self.totalChapters = totalChapters
        self.reusedFragments = reusedFragments
        self.retryAttempt = retryAttempt
        self.startedAt = startedAt
        self.updatedAt = updatedAt ?? startedAt
    }

    public var fraction: Double {
        totalFragments > 0 ? min(1, max(0, Double(completedFragments) / Double(totalFragments))) : 0
    }

    public var statusTitle: String {
        switch state {
        case .pausing: "正在暂停制作…"
        case .paused: "制作已暂停"
        case .failed: "制作遇到问题"
        default: phase.title
        }
    }

    public var savedFragmentsText: String {
        totalFragments > 0 ? "已保存 \(completedFragments)/\(totalFragments) 段" : "正在确认本次制作范围"
    }

    public func elapsedSeconds(at now: Date) -> Int {
        let end = state == .running || state == .pausing ? now : updatedAt
        return max(0, Int(end.timeIntervalSince(startedAt)))
    }

    public func isStalled(at now: Date) -> Bool {
        state == .running && now.timeIntervalSince(updatedAt) >= 60
    }

    public var canResume: Bool {
        state == .paused || state == .pausing || state == .running || state == .failed
    }
}

/// Explicit regeneration is distinct from filling missing or outdated audio.
public enum AudiobookRegenerationScope: Codable, Equatable, Sendable {
    case chapters
    case fragments(Set<UUID>)
}

public enum AudiobookProductionIntent: String, Codable, Equatable, Sendable {
    case missingOnly
    case updateOutdated
    case regenerate

    public var title: String {
        switch self {
        case .missingOnly: "只补缺失音频"
        case .updateOutdated: "更新待更新音频"
        case .regenerate: "重新制作"
        }
    }

    public var impact: String {
        switch self {
        case .missingOnly:
            "仅为没有可用音频的片段生成声音。已有音频（包括待更新的旧声音和未采用候选）全部保留，不重新生成。缺失或损坏的文件会生成新的修复候选。"
        case .updateOutdated:
            "只处理已有音频且制作条件已变化的片段，不补缺失。生成新的声音候选，当前采用版本保持不变；试听并采用后才替换。"
        case .regenerate:
            "为所选片段生成新的声音候选，已有音频和历史版本保留。已有章节在试听并采用后才替换，尚无音频的章节可完成首次制作。"
        }
    }
}

/// The approved fragment identities and dependencies are also the durable resume boundary.
public struct AudiobookProductionPlan: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let bookID: UUID
    public let sourceID: UUID
    public let intent: AudiobookProductionIntent
    public let chapterIDs: [UUID]
    public let chapterTitles: [UUID: String]
    public let fragments: [AudiobookFragment]
    public let preservedAudioCount: Int
    public let preservedOutdatedAudioCount: Int
    public let missingAudioCount: Int
}

/// Task identity, scope, counters and timestamps are durable; audio remains in the asset journal.
public struct AudiobookProductionCheckpoint: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { taskID }
    public let taskID: UUID
    public let chapterIDs: [UUID]
    public let regeneratingFragmentID: UUID?
    public let regenerationScope: AudiobookRegenerationScope?
    public let productionPlan: AudiobookProductionPlan?
    public let sourceID: UUID?
    public let preparationVersion: String?
    public var progress: AudiobookProductionProgress

    public init(taskID: UUID = UUID(), chapterIDs: [UUID], regeneratingFragmentID: UUID? = nil, progress: AudiobookProductionProgress, sourceID: UUID? = nil, preparationVersion: String? = nil, regenerationScope: AudiobookRegenerationScope? = nil, productionPlan: AudiobookProductionPlan? = nil) {
        self.taskID = taskID
        self.chapterIDs = chapterIDs
        if case .fragments(let ids) = regenerationScope, ids.count == 1 {
            self.regeneratingFragmentID = ids.first
        } else {
            self.regeneratingFragmentID = regeneratingFragmentID
        }
        self.regenerationScope = regenerationScope
        self.productionPlan = productionPlan
        self.progress = progress
        self.sourceID = sourceID
        self.preparationVersion = preparationVersion
    }

    public var effectiveRegenerationScope: AudiobookRegenerationScope? {
        regenerationScope ?? regeneratingFragmentID.map { .fragments([$0]) }
    }
}

public actor AudiobookProductionController {
    private let store: AudiobookProjectStore
    private let castController: AudiobookCastController
    private let revisionController: AudiobookRevisionController
    private let renderer: any AudiobookSpeechRenderer
    private let admission: SpeechCreationAdmission
    private let clock: any AudiobookClock
    private let voiceCatalog: VoiceCatalogStore
    private let policy: AudiobookRenderPolicy
    private let candidateCommitter: @Sendable (AudiobookRenderCandidate, Data) async throws -> Void
    private let completionCommitter: @Sendable (AudiobookProductionCheckpoint, AudiobookListenableState?) async throws -> Void

    private var generation: Int = 0
    private var inFlightTask: Task<AudiobookRenderCallOutput, Error>?
    private var inFlightFragmentID: UUID?
    private var isPauseRequested: Bool = false
    private var isStartActive: Bool = false
    private var isCommittingCompletion: Bool = false
    private var activeBookID: UUID?
    private var latestProgressByBook: [UUID: AudiobookProductionProgress] = [:]
    private var activeWorkingSource: AudiobookWorkingSourceSnapshot?
    private var activeCheckpoint: AudiobookProductionCheckpoint?

    public init(
        store: AudiobookProjectStore,
        castController: AudiobookCastController,
        revisionController: AudiobookRevisionController,
        renderer: any AudiobookSpeechRenderer,
        admission: SpeechCreationAdmission,
        clock: any AudiobookClock = SystemAudiobookClock(),
        policy: AudiobookRenderPolicy = .standard,
        voiceCatalog: VoiceCatalogStore = VoiceCatalogStore()
    ) {
        self.store = store
        self.castController = castController
        self.revisionController = revisionController
        self.renderer = renderer
        self.admission = admission
        self.clock = clock
        self.voiceCatalog = voiceCatalog
        self.policy = policy
        self.candidateCommitter = { candidate, wav in
            try await store.commitCandidate(candidate, wav: wav, requireCurrentSource: true)
        }
        self.completionCommitter = { checkpoint, listenableState in
            try await store.saveProductionCheckpoint(checkpoint, listenableState: listenableState)
        }
    }

    // Internal injection keeps persistence-boundary tests deterministic without
    // allowing production callers to replace durable commits.
    init(
        store: AudiobookProjectStore,
        castController: AudiobookCastController,
        revisionController: AudiobookRevisionController,
        renderer: any AudiobookSpeechRenderer,
        admission: SpeechCreationAdmission,
        clock: any AudiobookClock = SystemAudiobookClock(),
        policy: AudiobookRenderPolicy = .standard,
        voiceCatalog: VoiceCatalogStore = VoiceCatalogStore(),
        candidateCommitter: @escaping @Sendable (AudiobookRenderCandidate, Data) async throws -> Void,
        completionCommitter: (@Sendable (AudiobookProductionCheckpoint, AudiobookListenableState?) async throws -> Void)? = nil
    ) {
        self.store = store
        self.castController = castController
        self.revisionController = revisionController
        self.renderer = renderer
        self.admission = admission
        self.clock = clock
        self.voiceCatalog = voiceCatalog
        self.policy = policy
        self.candidateCommitter = candidateCommitter
        self.completionCommitter = completionCommitter ?? { checkpoint, listenableState in
            try await store.saveProductionCheckpoint(checkpoint, listenableState: listenableState)
        }
    }

    public func progress(for bookID: UUID) -> AudiobookProductionProgress? {
        latestProgressByBook[bookID]
    }

    /// Read-only: no fragment/checkpoint writes and no online capability requests.
    public func previewProduction(
        bookID: UUID, chapterIDs: [UUID], intent: AudiobookProductionIntent
    ) async throws -> AudiobookProductionPlan {
        guard !chapterIDs.isEmpty else { throw AudiobookProductionError.noReadyChaptersSelected }
        let snapshot = try await store.workingSourceSnapshot(bookID: bookID)
        let book = try await store.book(id: bookID)
        guard book.analysisState == .allWindowsValidated else { throw AudiobookProductionError.globalAnalysisNotCompleted }
        guard try await castController.currentCastRevisionID(for: bookID) == book.confirmedCastRevisionID else {
            throw AudiobookProductionError.castNotConfirmed
        }
        guard try await castController.currentVoiceSetDigest(for: bookID) == book.confirmedAuditionVoiceSetDigest else {
            throw AudiobookProductionError.auditionNotConfirmed
        }
        let requested = Set(chapterIDs)
        let chapters = try await store.chapters(for: bookID)
            .filter { requested.contains($0.id) && !$0.isSkipped }.sorted { $0.ordinal < $1.ordinal }
        guard !chapters.isEmpty else { throw AudiobookProductionError.noReadyChaptersSelected }
        guard chapters.count == requested.count else { throw AudiobookProductionError.taskScopeChanged }
        let bindings = try await store.voiceBindings(for: bookID)
        let pronunciation = try await store.pronunciationBinding(for: bookID)
        var fragmentsByChapter: [UUID: [AudiobookFragment]] = [:]
        for chapter in chapters {
            if try await castController.chapterReadiness(bookID: bookID, chapterID: chapter.id) == .blockedByUnknownSpeakers {
                throw AudiobookProductionError.chapterBlockedByUnknownSpeakers(chapterID: chapter.id)
            }
            fragmentsByChapter[chapter.id] = try AudiobookFragmentPlanner.plan(chapter: chapter,
                annotations: await store.annotations(for: bookID, chapterID: chapter.id), bindings: bindings,
                policy: policy, source: snapshot.sourceIndex,
                atoms: await store.atoms(for: bookID, chapterID: chapter.id), pronunciation: pronunciation)
        }
        // Regeneration approves text and dependencies; unrelated historical audio
        // cannot affect its range and must not be read just to classify availability.
        let selection: (targets: [AudiobookFragment], preserved: Int, outdated: Int, missing: Int)
        if intent == .regenerate {
            selection = (chapters.flatMap { fragmentsByChapter[$0.id, default: []] }, 0, 0, 0)
        } else {
            selection = try await classifyExistingAudio(bookID: bookID, chapterIDs: chapters.map(\.id),
                fragmentsByChapter: fragmentsByChapter, onlyMissing: intent == .missingOnly)
        }
        try await store.validateWorkingSource(snapshot)
        return .init(id: UUID(), bookID: bookID, sourceID: snapshot.sourceID, intent: intent,
            chapterIDs: chapters.map(\.id), chapterTitles: Dictionary(uniqueKeysWithValues: chapters.map { ($0.id, $0.title) }),
            fragments: selection.targets, preservedAudioCount: selection.preserved,
            preservedOutdatedAudioCount: selection.outdated, missingAudioCount: selection.missing)
    }

    private func classifyExistingAudio(
        bookID: UUID, chapterIDs: [UUID], fragmentsByChapter: [UUID: [AudiobookFragment]], onlyMissing: Bool
    ) async throws -> (targets: [AudiobookFragment], preserved: Int, outdated: Int, missing: Int) {
        let requested = Set(chapterIDs)
        let candidates = try await store.candidates(for: bookID)
        var valid: [AudiobookRenderCandidate] = []
        for candidate in candidates where requested.contains(candidate.chapterID) {
            try Task.checkCancellation()
            // Missing provenance does not authorize replacing an existing playable asset.
            if try await store.verifyCandidateAsset(candidate) { valid.append(candidate) }
        }
        let validByChapter = Dictionary(grouping: valid, by: \.chapterID)
        let savedByChapter = Dictionary(grouping: try await store.fragments(for: bookID), by: \.chapterID)
        var targets: [AudiobookFragment] = []
        var preserved = 0, outdated = 0, missing = 0
        for chapterID in chapterIDs {
            let fragments = fragmentsByChapter[chapterID, default: []]
            let audio = validByChapter[chapterID, default: []]
            var ranges = Dictionary(uniqueKeysWithValues: savedByChapter[chapterID, default: []].map { ($0.id, $0.sourceRange) })
            for revision in try await store.chapterRevisions(for: bookID, chapterID: chapterID) {
                for binding in revision.orderedBindings { ranges[binding.fragmentID] = binding.sourceRange }
            }
            let plannedIDs = Set(fragments.map(\.id))
            // Audio with an unknown historical range must never silently become a new gap.
            let hasUnmappedAudio = audio.contains { ranges[$0.fragmentID] == nil && !plannedIDs.contains($0.fragmentID) }
            for fragment in fragments {
                let isCurrent = audio.contains {
                    $0.fragmentID == fragment.id && $0.dependencyDigest == fragment.dependencyDigest && $0.isReceiptVerified
                }
                let hasAudio = hasUnmappedAudio || audio.contains { candidate in
                    if candidate.fragmentID == fragment.id { return true }
                    guard let range = ranges[candidate.fragmentID] else { return false }
                    return range.lowerBound < fragment.sourceRange.upperBound && fragment.sourceRange.lowerBound < range.upperBound
                }
                if !hasAudio { missing += 1 }
                let shouldRender = onlyMissing ? !hasAudio : hasAudio && !isCurrent
                if shouldRender { targets.append(fragment) }
                else if hasAudio {
                    preserved += 1
                    if !isCurrent { outdated += 1 }
                }
            }
        }
        return (targets, preserved, outdated, missing)
    }

    public func regenerateFragment(
        bookID: UUID,
        chapterID: UUID,
        fragmentID: UUID,
        resumingTaskID: UUID? = nil
    ) async throws {
        try await start(bookID: bookID, chapterIDs: [chapterID], resumingTaskID: resumingTaskID, regenerationScope: .fragments([fragmentID]))
    }

    public func start(
        bookID: UUID,
        chapterIDs: [UUID],
        resumingTaskID: UUID? = nil,
        regenerationScope: AudiobookRegenerationScope? = nil,
        expectedSourceID: UUID? = nil,
        intent: AudiobookProductionIntent = .missingOnly,
        approvedPlan: AudiobookProductionPlan? = nil
    ) async throws {
        guard !isStartActive else { throw AudiobookProductionError.admissionBusy }
        let plan: AudiobookProductionPlan
        if let resumingTaskID {
            guard let saved = try await store.productionCheckpoint(for: bookID), saved.taskID == resumingTaskID,
                  let savedPlan = saved.productionPlan,
                  approvedPlan == nil || approvedPlan == savedPlan else {
                throw AudiobookProductionError.taskScopeChanged
            }
            plan = savedPlan
        } else if let approvedPlan {
            plan = approvedPlan
        } else {
            let preview = try await previewProduction(bookID: bookID, chapterIDs: chapterIDs,
                intent: regenerationScope == nil ? intent : .regenerate)
            if case .fragments(let ids) = regenerationScope {
                guard !ids.isEmpty else { throw AudiobookProductionError.noReadyChaptersSelected }
                let targets = preview.fragments.filter { ids.contains($0.id) }
                if let missing = ids.subtracting(Set(targets.map(\.id))).first {
                    throw AudiobookRevisionError.fragmentNotFound(missing)
                }
                plan = .init(id: preview.id, bookID: preview.bookID, sourceID: preview.sourceID,
                    intent: preview.intent, chapterIDs: preview.chapterIDs, chapterTitles: preview.chapterTitles,
                    fragments: targets, preservedAudioCount: preview.preservedAudioCount,
                    preservedOutdatedAudioCount: preview.preservedOutdatedAudioCount,
                    missingAudioCount: preview.missingAudioCount)
            } else {
                plan = preview
            }
        }
        guard (plan.intent == .regenerate) == (regenerationScope != nil),
              plan.bookID == bookID, Set(plan.chapterIDs) == Set(chapterIDs),
              Set(plan.fragments.map(\.id)).count == plan.fragments.count,
              plan.fragments.allSatisfy({ $0.bookID == bookID && plan.chapterIDs.contains($0.chapterID) }) else {
            throw AudiobookProductionError.taskScopeChanged
        }
        if plan.fragments.isEmpty { return }
        try await produce(bookID: bookID, chapterIDs: chapterIDs, regenerationScope: regenerationScope,
            resumingTaskID: resumingTaskID, expectedSourceID: expectedSourceID, productionPlan: plan)
    }

    private func produce(
        bookID: UUID,
        chapterIDs: [UUID],
        regenerationScope: AudiobookRegenerationScope?,
        resumingTaskID: UUID?,
        expectedSourceID: UUID?,
        productionPlan: AudiobookProductionPlan
    ) async throws {
        // Actor methods are reentrant across `await`. Reserve the run before the first
        // suspension so a second start cannot invalidate its generation or strand its lease.
        guard !isStartActive else {
            throw AudiobookProductionError.admissionBusy
        }
        isStartActive = true
        activeBookID = bookID
        defer {
            isCommittingCompletion = false
            isStartActive = false
            activeBookID = nil
            activeCheckpoint = nil
            activeWorkingSource = nil
            candidateWAVCache.removeAll()
        }
        generation += 1
        let runGeneration = generation
        isPauseRequested = false
        latestProgressByBook[bookID] = AudiobookProductionProgress(
            bookID: bookID, state: .running, totalChapters: chapterIDs.count, startedAt: clock.now()
        )

        do {
            let snapshot = try await store.workingSourceSnapshot(bookID: bookID)
            activeWorkingSource = snapshot
            if let expectedSourceID, snapshot.sourceID != expectedSourceID {
                throw AudiobookStoreError.workingSourceChanged
            }
            if productionPlan.sourceID != snapshot.sourceID {
                if resumingTaskID != nil { throw AudiobookStoreError.workingSourceChanged }
                throw AudiobookProductionError.taskScopeChanged
            }
            if let resumingTaskID {
                guard let checkpoint = try await store.productionCheckpoint(for: bookID), checkpoint.taskID == resumingTaskID,
                      checkpoint.sourceID == snapshot.sourceID, checkpoint.preparationVersion == snapshot.preparationVersion,
                      checkpoint.chapterIDs == chapterIDs, checkpoint.effectiveRegenerationScope == regenerationScope,
                      checkpoint.productionPlan == productionPlan else {
                    throw AudiobookStoreError.workingSourceChanged
                }
                let availableIDs = Set(try await store.chapters(for: bookID).filter { !$0.isSkipped }.map(\.id))
                guard Set(chapterIDs).isSubset(of: availableIDs) else {
                    throw AudiobookProductionError.taskScopeChanged
                }
            }
            try await performProduction(
                bookID: bookID, chapterIDs: chapterIDs,
                regenerationScope: regenerationScope, runGeneration: runGeneration,
                taskID: resumingTaskID ?? UUID(), productionPlan: productionPlan
            )
        } catch {
            if let snapshot = activeWorkingSource,
               let current = try? await store.book(id: bookID), current.sourceID != snapshot.sourceID {
                updateProgress(bookID) { $0.state = .failed; $0.lastErrorMessage = error.localizedDescription }
                throw error
            }
            let cancelled = isPauseRequested || Task.isCancelled
                || error is CancellationError || (error as? AudiobookProductionError) == .cancelled
            if activeCheckpoint != nil || cancelled {
                if activeCheckpoint == nil, let progress = latestProgressByBook[bookID] {
                    activeCheckpoint = .init(taskID: resumingTaskID ?? UUID(), chapterIDs: chapterIDs, progress: progress, sourceID: activeWorkingSource?.sourceID, preparationVersion: activeWorkingSource?.preparationVersion, regenerationScope: regenerationScope, productionPlan: productionPlan)
                }
                let progress = latestProgressByBook[bookID]
                try await markBookPaused(bookID: bookID, completed: progress?.completedFragments ?? 0, total: progress?.totalFragments ?? 0)
                if !cancelled {
                    updateProgress(bookID) { $0.lastErrorMessage = error.localizedDescription }
                }
            } else {
                updateProgress(bookID) {
                    $0.state = .failed
                    $0.lastErrorMessage = error.localizedDescription
                }
            }
            if cancelled { throw AudiobookProductionError.cancelled }
            throw error
        }
    }

    private func performProduction(
        bookID: UUID, chapterIDs: [UUID], regenerationScope: AudiobookRegenerationScope?, runGeneration: Int, taskID: UUID,
        productionPlan: AudiobookProductionPlan
    ) async throws {
        try checkRunIsActive(runGeneration)

        guard !chapterIDs.isEmpty else {
            throw AudiobookProductionError.noReadyChaptersSelected
        }

        // 1. Verify global analysis, cast confirmation, and audition gate before acquiring lease
        var book = try await store.book(id: bookID)
        guard book.analysisState == .allWindowsValidated else {
            throw AudiobookProductionError.globalAnalysisNotCompleted
        }
        let expectedCastRev = try await castController.currentCastRevisionID(for: bookID)
        guard book.confirmedCastRevisionID == expectedCastRev else {
            throw AudiobookProductionError.castNotConfirmed
        }
        let expectedVoiceSetDigest = try await castController.currentVoiceSetDigest(for: bookID)
        guard book.confirmedAuditionVoiceSetDigest == expectedVoiceSetDigest else {
            throw AudiobookProductionError.auditionNotConfirmed
        }

        let allChapters = try await store.chapters(for: bookID)
        let chaptersByID = Dictionary(uniqueKeysWithValues: allChapters.map { ($0.id, $0) })
        let selectedChapters = try Array(Set(chapterIDs)).map { id -> AudiobookChapter in
            guard let chapter = chaptersByID[id] else {
                throw AudiobookStoreError.chapterNotFound(id)
            }
            return chapter
        }.filter { !$0.isSkipped }.sorted { $0.ordinal < $1.ordinal }

        guard !selectedChapters.isEmpty else {
            throw AudiobookProductionError.noReadyChaptersSelected
        }

        guard selectedChapters.count == Set(chapterIDs).count else {
            throw AudiobookProductionError.noReadyChaptersSelected
        }
        for chapter in selectedChapters {
            let readiness = try await castController.chapterReadiness(bookID: bookID, chapterID: chapter.id)
            if readiness == .blockedByUnknownSpeakers {
                throw AudiobookProductionError.chapterBlockedByUnknownSpeakers(chapterID: chapter.id)
            }
        }

        // 2. Plan fragments for selected chapters, collect active role IDs, and verify pinned capabilities
        guard let snapshot = activeWorkingSource else { throw AudiobookStoreError.workingTextPreparationRequired }
        try await store.validateWorkingSource(snapshot)
        let source = snapshot.sourceIndex
        let frozenBindings = try await store.voiceBindings(for: bookID)
        let pronunciation = try await store.pronunciationBinding(for: bookID)
        try AudiobookCastRegistry.validateBindingSet(characters: await store.characters(for: bookID), bindings: frozenBindings,
            requiredRoleIDs: await store.requiredCastingRoleIDs(bookID: bookID))
        var plannedFragmentsByChapter: [UUID: [AudiobookFragment]] = [:]
        var activeRoleIDs: Set<UUID> = []
        var totalFragmentCount = 0
        var allPlannedFragmentsByChapter: [UUID: [AudiobookFragment]] = [:]
        let current = try await previewProduction(bookID: bookID, chapterIDs: chapterIDs, intent: productionPlan.intent)
        guard current.sourceID == productionPlan.sourceID else { throw AudiobookProductionError.taskScopeChanged }
        let currentlyEligibleIDs = Set(current.fragments.map(\.id))
        if case .fragments(let ids) = regenerationScope, ids.isEmpty {
            throw AudiobookProductionError.noReadyChaptersSelected
        }

        for chapter in selectedChapters {
            try checkRunIsActive(runGeneration)
            let chapterAnns = try await store.annotations(for: bookID, chapterID: chapter.id)
            let chapterAtoms = try await store.atoms(for: bookID, chapterID: chapter.id)
            let fragments = try AudiobookFragmentPlanner.plan(
                chapter: chapter,
                annotations: chapterAnns,
                bindings: frozenBindings,
                policy: policy,
                source: source,
                atoms: chapterAtoms,
                pronunciation: pronunciation
            )
            let selectedFragments = productionPlan.fragments.filter { $0.chapterID == chapter.id }
            let byID = Dictionary(uniqueKeysWithValues: fragments.map { ($0.id, $0) })
            guard selectedFragments.allSatisfy({ byID[$0.id] == $0 }) else { throw AudiobookProductionError.taskScopeChanged }
            allPlannedFragmentsByChapter[chapter.id] = fragments
            plannedFragmentsByChapter[chapter.id] = selectedFragments
            activeRoleIDs.formUnion(selectedFragments.filter { currentlyEligibleIDs.contains($0.id) }.map(\.roleID))
            totalFragmentCount += selectedFragments.count
            updateProgress(bookID) {
                $0.currentChapterID = chapter.id
                $0.currentChapterOrdinal = chapter.ordinal + 1
                $0.totalFragments = totalFragmentCount
            }
            try checkRunIsActive(runGeneration)
        }
        if case .fragments(let ids) = regenerationScope {
            let plannedIDs = Set(plannedFragmentsByChapter.values.flatMap { $0.map(\.id) })
            if let missing = ids.subtracting(plannedIDs).first {
                throw AudiobookRevisionError.fragmentNotFound(missing)
            }
        }
        guard totalFragmentCount > 0 else { throw AudiobookProductionError.noReadyChaptersSelected }
        for chapter in selectedChapters {
            try checkRunIsActive(runGeneration)
            try await store.saveFragments(bookID: bookID, chapterID: chapter.id,
                                          fragments: allPlannedFragmentsByChapter[chapter.id] ?? [])
        }

        try checkRunIsActive(runGeneration)
        if let progress = latestProgressByBook[bookID] {
            activeCheckpoint = .init(taskID: taskID, chapterIDs: selectedChapters.map(\.id), progress: progress, sourceID: activeWorkingSource?.sourceID, preparationVersion: activeWorkingSource?.preparationVersion, regenerationScope: regenerationScope, productionPlan: productionPlan)
            try await persistProgress(bookID)
        }
        let capabilities = activeRoleIDs.isEmpty ? nil : try await renderer.fetchEffectiveCapabilities()
        try checkRunIsActive(runGeneration)
        if let capabilities {
            try Self.verifyPinnedBindingsAgainstCapabilities(bindings: frozenBindings,
                activeRoleIDs: activeRoleIDs, capabilities: capabilities)
        }

        book.productionState = .running
        try await store.updateBook(book)
        if isPauseRequested || Task.isCancelled || generation != runGeneration {
            try await markBookPaused(bookID: bookID, completed: 0, total: totalFragmentCount)
            throw AudiobookProductionError.cancelled
        }

        var completedCount = 0
        updateProgress(bookID) { $0.totalFragments = totalFragmentCount }
        try await persistProgress(bookID)

        do {
            // 3. Sequentially render fragments (reusing valid existing candidates when dependencyDigest matches)
            let existingCandidates = try await store.candidates(for: bookID)
            // 片段复用按 fragmentID 建索引，避免每个片段线性扫描全书的候选列表。
            let existingCandidatesByFragmentID = Dictionary(grouping: existingCandidates, by: \.fragmentID)
            for chapter in selectedChapters {
                let fragments = plannedFragmentsByChapter[chapter.id] ?? []
                for fragment in fragments {
                    if isPauseRequested || Task.isCancelled || generation != runGeneration {
                        try await markBookPaused(bookID: bookID, completed: completedCount, total: totalFragmentCount)
                        throw AudiobookProductionError.cancelled
                    }
                    updateProgress(bookID) {
                        $0.phase = .checkingSavedAudio
                        $0.currentChapterID = chapter.id
                        $0.currentChapterOrdinal = chapter.ordinal + 1
                        $0.currentFragmentID = fragment.id
                        $0.retryAttempt = 0
                    }

                    // Targets can disappear after preview (another candidate was saved), never grow.
                    if productionPlan.intent == .missingOnly {
                        let latest = try await store.candidates(for: bookID, fragmentID: fragment.id)
                        var hasSavedAudio = false
                        for candidate in latest {
                            if try await store.verifyCandidateAsset(candidate) { hasSavedAudio = true; break }
                        }
                        if hasSavedAudio {
                            completedCount += 1
                            updateProgress(bookID) { $0.completedFragments = completedCount; $0.reusedFragments += 1 }
                            try await persistProgress(bookID)
                            continue
                        }
                    }
                    if !currentlyEligibleIDs.contains(fragment.id) {
                        completedCount += 1
                        updateProgress(bookID) { $0.completedFragments = completedCount; $0.reusedFragments += 1 }
                        try await persistProgress(bookID)
                        continue
                    }

                    // Reuse already committed & verified candidate with identical dependencyDigest
                    if let reusable = existingCandidatesByFragmentID[fragment.id]?.first(where: {
                        $0.dependencyDigest == fragment.dependencyDigest
                            && $0.isReceiptVerified
                            && (regenerationScope == nil || $0.taskID == taskID)
                    }),
                       (try? await store.verifyCandidateAsset(reusable)) == true
                    {
                        completedCount += 1
                        updateProgress(bookID) {
                            $0.completedFragments = completedCount
                            $0.reusedFragments += 1
                        }
                        try await persistProgress(bookID)
                        continue
                    }

                    guard let binding = frozenBindings[fragment.roleID] else {
                        throw AudiobookFragmentPlanningError.missingVoiceBinding(roleID: fragment.roleID)
                    }
                    let fragmentText = try source.text(in: fragment.sourceRange)

                    updateProgress(bookID) { $0.phase = .rendering }

                    let candidate = try await renderSingleFragmentWithFiniteRetry(
                        bookID: bookID,
                        chapter: chapter,
                        fragment: fragment,
                        text: fragmentText,
                        binding: binding,
                        pronunciation: pronunciation,
                        runGeneration: runGeneration
                    )

                    // Guard against late response after pause/cancel before committing to SQLite/disk
                    if isPauseRequested || Task.isCancelled || generation != runGeneration {
                        try await markBookPaused(bookID: bookID, completed: completedCount, total: totalFragmentCount)
                        throw AudiobookProductionError.cancelled
                    }

                    updateProgress(bookID) { $0.phase = .saving }
                    try await store.validateWorkingSource(snapshot)
                    try await candidateCommitter(candidate, candidateWAVCache[candidate.id] ?? Data())
                    candidateWAVCache.removeValue(forKey: candidate.id)
                    if let voice = capabilities?.voices.first(where: { $0.id == binding.voiceID }), !(await voiceCatalog.refresh()).permits(voice, bookID: bookID) {
                        throw AudiobookProductionError.capabilityVoiceUnavailable(voiceID: binding.voiceID, reason: "声音归属已变化，本段已保存为待复核候选。")
                    }

                    completedCount += 1
                    updateProgress(bookID) { $0.completedFragments = completedCount }
                    try checkRunIsActive(runGeneration)
                    try await persistProgress(bookID)
                }

                // If all fragments in the chapter now have verified candidates and no previous revision exists,
                // automatically promote initial chapter revision (or keep as candidate if repairing an existing chapter).
                updateProgress(bookID) { $0.phase = .assemblingChapter }
                let existingRevs = try await store.chapterRevisions(for: bookID, chapterID: chapter.id)
                try checkRunIsActive(runGeneration)
                if (regenerationScope == nil || regenerationScope == .chapters), existingRevs.isEmpty {
                    _ = try await revisionController.promoteInitialChapterIfComplete(
                        bookID: bookID,
                        chapterID: chapter.id,
                        updateBookProductionState: false
                    )
                    try checkRunIsActive(runGeneration)
                }
            }
        }

        do {
            // Honor a pause during rendering or chapter publication before committing completion.
            try checkRunIsActive(runGeneration)
            let updatedChapters = try await store.chapters(for: bookID).filter { !$0.isSkipped }
            try checkRunIsActive(runGeneration)
            let readyChaptersCount = updatedChapters.filter { $0.currentChapterRevisionID != nil }.count
            let finalState: AudiobookProductionState
            let listenableState: AudiobookListenableState?
            if readyChaptersCount == updatedChapters.count && !updatedChapters.isEmpty {
                finalState = .fullBookProduced
                listenableState = .fullBookListenable
            } else if readyChaptersCount > 0 {
                finalState = .partialChaptersReady
                listenableState = .partialChaptersListenable
            } else {
                finalState = .allConfirmedChaptersProduced
                listenableState = nil
            }
            guard var checkpoint = activeCheckpoint, var progress = latestProgressByBook[bookID] else {
                throw AudiobookProductionError.checkpointNotSaved(reason: "未找到当前制作记录。")
            }
            progress.state = finalState
            progress.phase = .completed
            progress.completedFragments = completedCount
            progress.totalFragments = totalFragmentCount
            progress.currentFragmentID = nil
            progress.updatedAt = clock.now()
            checkpoint.progress = progress

            // No render remains in flight. Let this final atomic save settle even if
            // the parent is cancelled; a committed completion must not become paused.
            isCommittingCompletion = true
            try await completionCommitter(checkpoint, listenableState)
            activeCheckpoint = checkpoint
            latestProgressByBook[bookID] = progress
        }
    }

    public func pause() async {
        guard let bookID = activeBookID, !isCommittingCompletion else { return }
        isPauseRequested = true
        generation += 1
        let pauseGeneration = generation
        let activeFrag = inFlightFragmentID
        updateProgress(bookID) { $0.state = .pausing }
        inFlightTask?.cancel()
        if let task = inFlightTask {
            _ = try? await task.value
        }
        inFlightTask = nil
        inFlightFragmentID = nil
        await MainActor.run {
            admission.release(.audiobook)
        }
        guard activeBookID == bookID, generation == pauseGeneration else { return }
        updateProgress(bookID) {
            $0.state = .paused
            $0.unconfirmedRemoteStopFragmentID = activeFrag
        }
        // The owning run also persists its paused terminal before releasing its reservation.
        do {
            try await persistProgress(bookID)
        } catch {
            _ = recordCheckpointSaveFailure(bookID, error: error)
        }
    }

    public func shutdown() async {
        await pause()
    }

    // MARK: - Internal Render & Retry

    private var candidateWAVCache: [UUID: Data] = [:]

    private func renderSingleFragmentWithFiniteRetry(
        bookID: UUID,
        chapter: AudiobookChapter,
        fragment: AudiobookFragment,
        text: String,
        binding: AudiobookVoiceBinding,
        pronunciation: AudiobookPronunciationBinding?,
        runGeneration: Int
    ) async throws -> AudiobookRenderCandidate {
        let effectiveSpeed = binding.allowedSpeed
        let request = AudiobookRenderCallRequest(
            bookID: bookID,
            text: text,
            voiceID: binding.voiceID,
            speed: effectiveSpeed,
            expectedVoiceRevision: binding.voiceRevision,
            expectedModelRevision: binding.modelRevision,
            seed: binding.callerSeed,
            pronunciationSet: pronunciation?.headerValue
        )

        // 能力快照与声音归属只在进入重试循环前解析一次。暂态能力读取失败应直接失败，
        // 而不是被当成一次可重试的合成失败并消耗片段的重试预算。
        let current = try await renderer.fetchEffectiveCapabilities()
        try AudiobookCastRegistry.validateRenderBinding(binding, snapshot: current)
        guard let voice = current.voices.first(where: { $0.id == binding.voiceID }),
              (await voiceCatalog.refresh()).permits(voice, bookID: bookID)
        else {
            throw AudiobookProductionError.capabilityVoiceUnavailable(voiceID: binding.voiceID, reason: "声音归属已变化，请重新确认。")
        }

        var attempt = 0
        let maxRetries = AudiobookLimits.maxRenderTransientRetries

        while true {
            if isPauseRequested || Task.isCancelled || generation != runGeneration {
                throw AudiobookProductionError.cancelled
            }

            // Acquire single-lane creation admission for this fragment
            let acquired = await MainActor.run {
                admission.acquire(.audiobook)
            }
            if !acquired {
                if attempt >= maxRetries {
                    throw AudiobookProductionError.admissionBusy
                }
                attempt += 1
                updateProgress(bookID) {
                    $0.phase = .waitingForService
                    $0.retryAttempt = attempt
                }
                try await clock.sleep(seconds: 0.25 * Double(attempt))
                continue
            }
            if isPauseRequested || Task.isCancelled || generation != runGeneration {
                await MainActor.run { admission.release(.audiobook) }
                throw AudiobookProductionError.cancelled
            }

            var admissionReleased = false
            do {
                if let snapshot = activeWorkingSource { try await store.validateWorkingSource(snapshot) }
                inFlightFragmentID = fragment.id
                updateProgress(bookID) { $0.phase = .rendering }
                let renderTask = Task<AudiobookRenderCallOutput, Error> { [renderer] in
                    try await renderer.renderFragment(request)
                }
                inFlightTask = renderTask

                let output = try await renderTask.value
                inFlightTask = nil
                inFlightFragmentID = nil
                if generation == runGeneration {
                    admissionReleased = true
                    await MainActor.run {
                        admission.release(.audiobook)
                    }
                } else {
                    throw AudiobookProductionError.cancelled
                }
                if let snapshot = activeWorkingSource { try await store.validateWorkingSource(snapshot) }
                updateProgress(bookID) { $0.retryAttempt = 0 }

                // The service receipt describes the original PCM. Verify it before
                // normalizing the local asset to the render policy's sample rate.
                let receivedPCMSHA = try AudioDigest.sha256HexOfPCM(in: output.wavData)
                let scopeStillValid = (await voiceCatalog.refresh()).permits(voice, bookID: bookID)
                let receiptVerified = scopeStillValid && output.isProvenanceVerified
                    && (output.pcmSHA256 == nil || output.pcmSHA256 == receivedPCMSHA)
                    && output.voiceRevision == binding.voiceRevision
                    && output.modelRevision == binding.modelRevision
                    && output.pcmSHA256 != nil
                let normalizedWAV = try Self.normalizePCM16MonoWAV(output.wavData, sampleRate: policy.sampleRate)
                let fileSHA = AudiobookDigest.sha256Hex(normalizedWAV)
                let computedPCMSHA = try AudioDigest.sha256HexOfPCM(in: normalizedWAV)
                let frameCount = Self.extractPCM16MonoFrameCount(from: normalizedWAV)

                let candidateID = UUID()
                let relPath = "books/\(bookID.uuidString)/audio/\(candidateID.uuidString).wav"
                let candidate = AudiobookRenderCandidate(
                    id: candidateID,
                    bookID: bookID,
                    chapterID: chapter.id,
                    fragmentID: fragment.id,
                    taskID: activeCheckpoint?.taskID ?? UUID(),
                    generation: runGeneration,
                    relativeAssetPath: relPath,
                    fileSHA256: fileSHA,
                    pcmSHA256: computedPCMSHA,
                    frameCount: frameCount,
                    sampleRate: policy.sampleRate,
                    dependencyDigest: fragment.dependencyDigest,
                    requestID: output.requestID,
                    receiptDigest: output.receiptID,
                    recipeSummary: output.recipeSummary,
                    isReceiptVerified: receiptVerified,
                    createdAt: clock.now()
                )
                candidateWAVCache[candidateID] = normalizedWAV
                return candidate
            } catch {
                inFlightTask = nil
                inFlightFragmentID = nil
                if generation == runGeneration && !admissionReleased {
                    await MainActor.run { admission.release(.audiobook) }
                }
                if isPauseRequested || Task.isCancelled || error is CancellationError || generation != runGeneration {
                    throw AudiobookProductionError.cancelled
                }
                if error is AudiobookStoreError || error is AudioNormalizationError || error is AudioDigest.Failure {
                    throw error
                }

                if let apiError = error as? ServiceAPIClientError {
                    let category = ServiceErrorClassifier.category(for: apiError)
                    switch category {
                    case .unauthorized:
                        throw AudiobookProductionError.unauthorizedService
                    case .conflict, .voiceRevoked:
                        throw AudiobookProductionError.capabilityRevisionMismatch(
                            voiceID: binding.voiceID,
                            expected: binding.voiceRevision,
                            actual: nil
                        )
                    case .busy, .notReady, .connection:
                        if case let .http(_, _, _, _, retryable) = apiError, !retryable { throw apiError }
                        if attempt < maxRetries {
                            attempt += 1
                            updateProgress(bookID) {
                                $0.phase = .waitingForService
                                $0.retryAttempt = attempt
                            }
                            try await clock.sleep(seconds: 0.5 * Double(attempt))
                            continue
                        }
                        throw AudiobookProductionError.transientRetriesExhausted(
                            fragmentID: fragment.id,
                            lastReason: apiError.localizedDescription
                        )
                    case .unsupported, .invalidContract:
                        throw apiError
                    }
                }

                if attempt < maxRetries {
                    attempt += 1
                    updateProgress(bookID) {
                        $0.phase = .waitingForService
                        $0.retryAttempt = attempt
                    }
                    try await clock.sleep(seconds: 0.5 * Double(attempt))
                    continue
                }
                throw AudiobookProductionError.transientRetriesExhausted(
                    fragmentID: fragment.id,
                    lastReason: error.localizedDescription
                )
            }
        }
    }

    private func markBookPaused(bookID: UUID, completed: Int, total: Int) async throws {
        updateProgress(bookID) {
            $0.state = .paused
            $0.completedFragments = completed
            $0.totalFragments = total
        }
        do {
            try await persistProgress(bookID)
        } catch {
            throw recordCheckpointSaveFailure(bookID, error: error)
        }
    }

    private func recordCheckpointSaveFailure(_ bookID: UUID, error: any Error) -> AudiobookProductionError {
        let failure = AudiobookProductionError.checkpointNotSaved(reason: error.localizedDescription)
        updateProgress(bookID) {
            $0.state = .failed
            $0.lastErrorMessage = failure.localizedDescription
        }
        return failure
    }

    private func updateProgress(_ bookID: UUID, _ update: (inout AudiobookProductionProgress) -> Void) {
        guard var progress = latestProgressByBook[bookID] else { return }
        update(&progress)
        progress.updatedAt = clock.now()
        latestProgressByBook[bookID] = progress
    }

    private func persistProgress(_ bookID: UUID) async throws {
        guard var checkpoint = activeCheckpoint, let progress = latestProgressByBook[bookID] else { return }
        checkpoint.progress = progress
        activeCheckpoint = checkpoint
        try await store.saveProductionCheckpoint(checkpoint)
    }

    private func checkRunIsActive(_ runGeneration: Int) throws {
        guard !isPauseRequested, !Task.isCancelled, generation == runGeneration else {
            throw AudiobookProductionError.cancelled
        }
    }

    private static func verifyPinnedBindingsAgainstCapabilities(
        bindings: [UUID: AudiobookVoiceBinding],
        activeRoleIDs: Set<UUID>,
        capabilities: EffectiveCapabilitySnapshot
    ) throws {
        for (roleID, binding) in bindings {
            guard activeRoleIDs.isEmpty || activeRoleIDs.contains(roleID) else { continue }
            try AudiobookCastRegistry.validateRenderBinding(binding, snapshot: capabilities)
        }
    }

    public static func extractPCM16MonoFrameCount(from wav: Data) -> Int64 {
        guard let range = try? AudioDigest.pcmRange(in: wav), range.count.isMultiple(of: 2) else { return 0 }
        return Int64(range.count / 2)
    }

    private enum AudioNormalizationError: LocalizedError {
        case invalidPCM
        case conversionFailed

        var errorDescription: String? {
            switch self {
            case .invalidPCM: "语音服务返回的音频格式无效，请重试。"
            case .conversionFailed: "无法整理语音片段的音频格式，请重试。"
            }
        }
    }

    /// Decode the service's PCM16 mono contract and store a real policy-rate WAV.
    /// RIFF chunks may contain metadata, so neither format nor PCM starts at a fixed offset.
    private static func normalizePCM16MonoWAV(_ wav: Data, sampleRate: Int) throws -> Data {
        guard wav.count >= 12, wav.count <= AudiobookLimits.maxWAVResponseBytes,
              wav.prefix(4).elementsEqual("RIFF".utf8),
              wav[8..<12].elementsEqual("WAVE".utf8), (1...192_000).contains(sampleRate)
        else { throw AudioNormalizationError.invalidPCM }

        func uint16(at offset: Int) -> Int {
            Int(wav[offset]) | (Int(wav[offset + 1]) << 8)
        }
        func uint32(at offset: Int) -> Int {
            uint16(at: offset) | (uint16(at: offset + 2) << 16)
        }
        var sourceRate: Int?
        var cursor = 12
        while cursor <= wav.count - 8 {
            let size = uint32(at: cursor + 4)
            let start = cursor + 8
            guard size <= wav.count - start else { throw AudioNormalizationError.invalidPCM }
            if wav[cursor..<cursor + 4].elementsEqual("fmt ".utf8) {
                guard size >= 16, uint16(at: start) == 1, uint16(at: start + 2) == 1,
                      uint16(at: start + 12) == 2, uint16(at: start + 14) == 16
                else { throw AudioNormalizationError.invalidPCM }
                sourceRate = uint32(at: start + 4)
                break
            }
            cursor = start + size + size % 2
        }
        guard let sourceRate, (1...192_000).contains(sourceRate),
              let range = try? AudioDigest.pcmRange(in: wav), !range.isEmpty,
              range.count.isMultiple(of: 2)
        else { throw AudioNormalizationError.invalidPCM }
        if sourceRate == sampleRate { return wav }

        let frameCount = range.count / 2
        let scaledFrames = (Double(frameCount) * Double(sampleRate) / Double(sourceRate)).rounded()
        // Bound the allocation before converting to an integer or asking AVFoundation
        // for buffers. The 24→48 kHz contract needs at most twice the response budget.
        guard scaledFrames.isFinite, scaledFrames > 0,
              scaledFrames <= Double(AudiobookLimits.maxWAVResponseBytes)
        else { throw AudioNormalizationError.invalidPCM }
        let expectedFrames = Int(scaledFrames)
        guard frameCount <= Int(UInt32.max), expectedFrames <= Int(UInt32.max) - 32,
              let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sourceRate), channels: 1, interleaved: true),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frameCount)),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(expectedFrames + 32)),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw AudioNormalizationError.conversionFailed }
        input.frameLength = AVAudioFrameCount(frameCount)
        wav[range].withUnsafeBytes { bytes in
            input.mutableAudioBufferList.pointee.mBuffers.mData?.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        converter.primeMethod = .none
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil, expectedFrames > 0,
              output.frameLength >= expectedFrames,
              let samples = output.audioBufferList.pointee.mBuffers.mData
        else { throw AudioNormalizationError.conversionFailed }
        // A finite converter may drain filter-padding samples after end-of-stream.
        // Keep the original duration rather than accumulating that tail per fragment.
        let pcm = Data(bytes: samples, count: expectedFrames * 2)
        guard pcm.count <= Int(UInt32.max) - 36 else { throw AudioNormalizationError.conversionFailed }
        var result = Data()
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { result.append(contentsOf: $0) }
        }
        result.append(contentsOf: "RIFF".utf8)
        appendLE(UInt32(36 + pcm.count))
        result.append(contentsOf: "WAVEfmt ".utf8)
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(UInt16(1))
        appendLE(UInt32(sampleRate))
        appendLE(UInt32(sampleRate * 2))
        appendLE(UInt16(2))
        appendLE(UInt16(16))
        result.append(contentsOf: "data".utf8)
        appendLE(UInt32(pcm.count))
        result.append(pcm)
        return result
    }
}
