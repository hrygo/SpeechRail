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
    case capabilityVoiceUnavailable(voiceID: String, reason: String)
    case capabilityRevisionMismatch(voiceID: String, expected: String, actual: String?)
    case unauthorizedService
    case transientRetriesExhausted(fragmentID: UUID, lastReason: String)
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
        case .admissionBusy:
            return "当前已有另一个语音制作任务正在运行，请稍候再试。"
        case let .capabilityVoiceUnavailable(voiceID, reason):
            return "角色绑定的音色「\(voiceID)」当前不可用于正式制作（\(reason)）。"
        case let .capabilityRevisionMismatch(voiceID, expected, _):
            return "音色「\(voiceID)」或模型版本已发生变化（期望 \(expected)），请重新确认声音后再继续。"
        case .unauthorizedService:
            return "本机语音服务鉴权未通过，请检查服务连接。"
        case let .transientRetriesExhausted(_, reason):
            return "语音服务繁忙或暂态错误已达重试上限：\(reason)"
        case .pauseWithUnconfirmedRemoteStop:
            return "制作已暂停；当前在途片段的服务端停止状态尚未确认，稍后继续时将自动核对。"
        case .cancelled:
            return "章节制作已暂停。"
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

    public init(
        bookID: UUID,
        state: AudiobookProductionState,
        currentChapterID: UUID? = nil,
        currentFragmentID: UUID? = nil,
        completedFragments: Int = 0,
        totalFragments: Int = 0,
        unconfirmedRemoteStopFragmentID: UUID? = nil,
        lastErrorMessage: String? = nil
    ) {
        self.bookID = bookID
        self.state = state
        self.currentChapterID = currentChapterID
        self.currentFragmentID = currentFragmentID
        self.completedFragments = completedFragments
        self.totalFragments = totalFragments
        self.unconfirmedRemoteStopFragmentID = unconfirmedRemoteStopFragmentID
        self.lastErrorMessage = lastErrorMessage
    }
}

public actor AudiobookProductionController {
    private let store: AudiobookProjectStore
    private let castController: AudiobookCastController
    private let revisionController: AudiobookRevisionController
    private let renderer: any AudiobookSpeechRenderer
    private let admission: SpeechCreationAdmission
    private let clock: any AudiobookClock
    private let policy: AudiobookRenderPolicy
    private let candidateCommitter: @Sendable (AudiobookRenderCandidate, Data) async throws -> Void

    private var generation: Int = 0
    private var inFlightTask: Task<AudiobookRenderCallOutput, Error>?
    private var inFlightFragmentID: UUID?
    private var isPauseRequested: Bool = false
    private var isStartActive: Bool = false
    private var activeBookID: UUID?
    private var latestProgressByBook: [UUID: AudiobookProductionProgress] = [:]

    public init(
        store: AudiobookProjectStore,
        castController: AudiobookCastController,
        revisionController: AudiobookRevisionController,
        renderer: any AudiobookSpeechRenderer,
        admission: SpeechCreationAdmission,
        clock: any AudiobookClock = SystemAudiobookClock(),
        policy: AudiobookRenderPolicy = .standard
    ) {
        self.store = store
        self.castController = castController
        self.revisionController = revisionController
        self.renderer = renderer
        self.admission = admission
        self.clock = clock
        self.policy = policy
        self.candidateCommitter = { candidate, wav in
            try await store.commitCandidate(candidate, wav: wav)
        }
    }

    // Internal injection keeps persistence-boundary tests deterministic without
    // allowing production callers to replace durable candidate commits.
    init(
        store: AudiobookProjectStore,
        castController: AudiobookCastController,
        revisionController: AudiobookRevisionController,
        renderer: any AudiobookSpeechRenderer,
        admission: SpeechCreationAdmission,
        clock: any AudiobookClock = SystemAudiobookClock(),
        policy: AudiobookRenderPolicy = .standard,
        candidateCommitter: @escaping @Sendable (AudiobookRenderCandidate, Data) async throws -> Void
    ) {
        self.store = store
        self.castController = castController
        self.revisionController = revisionController
        self.renderer = renderer
        self.admission = admission
        self.clock = clock
        self.policy = policy
        self.candidateCommitter = candidateCommitter
    }

    public func progress(for bookID: UUID) -> AudiobookProductionProgress? {
        latestProgressByBook[bookID]
    }

    public func regenerateFragment(
        bookID: UUID,
        chapterID: UUID,
        fragmentID: UUID
    ) async throws {
        try await produce(bookID: bookID, chapterIDs: [chapterID], regeneratingFragmentID: fragmentID)
    }

    public func start(
        bookID: UUID,
        chapterIDs: [UUID]
    ) async throws {
        try await produce(bookID: bookID, chapterIDs: chapterIDs, regeneratingFragmentID: nil)
    }

    private func produce(
        bookID: UUID,
        chapterIDs: [UUID],
        regeneratingFragmentID: UUID?
    ) async throws {
        // Actor methods are reentrant across `await`. Reserve the run before the first
        // suspension so a second start cannot invalidate its generation or strand its lease.
        guard !isStartActive else {
            throw AudiobookProductionError.admissionBusy
        }
        isStartActive = true
        activeBookID = bookID
        defer {
            isStartActive = false
            activeBookID = nil
            candidateWAVCache.removeAll()
        }
        generation += 1
        let runGeneration = generation
        isPauseRequested = false

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
        let selectedChapters = try chapterIDs.map { id -> AudiobookChapter in
            guard let chapter = chaptersByID[id] else {
                throw AudiobookStoreError.chapterNotFound(id)
            }
            return chapter
        }.sorted { $0.ordinal < $1.ordinal }

        for chapter in selectedChapters {
            let readiness = try await castController.chapterReadiness(bookID: bookID, chapterID: chapter.id)
            if readiness == .blockedByUnknownSpeakers {
                throw AudiobookProductionError.chapterBlockedByUnknownSpeakers(chapterID: chapter.id)
            }
        }

        // 2. Plan fragments for selected chapters, collect active role IDs, and verify pinned capabilities
        let source = try await store.sourceIndex(for: bookID)
        let frozenBindings = try await store.voiceBindings(for: bookID)
        var plannedFragmentsByChapter: [UUID: [AudiobookFragment]] = [:]
        var activeRoleIDs: Set<UUID> = []
        var totalFragmentCount = 0

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
                atoms: chapterAtoms
            )
            let selectedFragments: [AudiobookFragment]
            if let regeneratingFragmentID {
                guard let target = fragments.first(where: { $0.id == regeneratingFragmentID }) else {
                    throw AudiobookRevisionError.fragmentNotFound(regeneratingFragmentID)
                }
                selectedFragments = [target]
            } else {
                selectedFragments = fragments
            }
            plannedFragmentsByChapter[chapter.id] = selectedFragments
            activeRoleIDs.formUnion(selectedFragments.map(\.roleID))
            totalFragmentCount += selectedFragments.count
            try checkRunIsActive(runGeneration)
            try await store.saveFragments(bookID: bookID, chapterID: chapter.id, fragments: fragments)
        }

        let capabilities = try await renderer.fetchEffectiveCapabilities()
        try checkRunIsActive(runGeneration)
        try Self.verifyPinnedBindingsAgainstCapabilities(
            bindings: frozenBindings,
            activeRoleIDs: activeRoleIDs,
            capabilities: capabilities
        )

        book.productionState = .running
        try await store.updateBook(book)
        if isPauseRequested || Task.isCancelled || generation != runGeneration {
            try await markBookPaused(bookID: bookID, completed: 0, total: totalFragmentCount)
            throw AudiobookProductionError.cancelled
        }

        var completedCount = 0
        latestProgressByBook[bookID] = AudiobookProductionProgress(
            bookID: bookID,
            state: .running,
            completedFragments: 0,
            totalFragments: totalFragmentCount
        )

        do {
            // 3. Sequentially render fragments (reusing valid existing candidates when dependencyDigest matches)
            let existingCandidates = try await store.candidates(for: bookID)
            for chapter in selectedChapters {
                let fragments = plannedFragmentsByChapter[chapter.id] ?? []
                for fragment in fragments {
                    if isPauseRequested || Task.isCancelled || generation != runGeneration {
                        try await markBookPaused(bookID: bookID, completed: completedCount, total: totalFragmentCount)
                        throw AudiobookProductionError.cancelled
                    }

                    // Reuse already committed & verified candidate with identical dependencyDigest
                    if regeneratingFragmentID == nil,
                       let reusable = existingCandidates.first(where: {
                        $0.fragmentID == fragment.id
                            && $0.dependencyDigest == fragment.dependencyDigest
                            && $0.isReceiptVerified
                    }),
                       (try? await store.verifyCandidateAsset(reusable)) == true
                    {
                        completedCount += 1
                        latestProgressByBook[bookID]?.completedFragments = completedCount
                        continue
                    }

                    guard let binding = frozenBindings[fragment.roleID] else {
                        throw AudiobookFragmentPlanningError.missingVoiceBinding(roleID: fragment.roleID)
                    }
                    let fragmentText = try source.text(in: fragment.sourceRange)

                    latestProgressByBook[bookID] = AudiobookProductionProgress(
                        bookID: bookID,
                        state: .running,
                        currentChapterID: chapter.id,
                        currentFragmentID: fragment.id,
                        completedFragments: completedCount,
                        totalFragments: totalFragmentCount
                    )

                    let candidate = try await renderSingleFragmentWithFiniteRetry(
                        bookID: bookID,
                        chapter: chapter,
                        fragment: fragment,
                        text: fragmentText,
                        binding: binding,
                        runGeneration: runGeneration
                    )

                    // Guard against late response after pause/cancel before committing to SQLite/disk
                    if isPauseRequested || Task.isCancelled || generation != runGeneration {
                        try await markBookPaused(bookID: bookID, completed: completedCount, total: totalFragmentCount)
                        throw AudiobookProductionError.cancelled
                    }

                    try await candidateCommitter(candidate, candidateWAVCache[candidate.id] ?? Data())
                    candidateWAVCache.removeValue(forKey: candidate.id)

                    completedCount += 1
                    latestProgressByBook[bookID]?.completedFragments = completedCount
                    try checkRunIsActive(runGeneration)
                }

                // If all fragments in the chapter now have verified candidates and no previous revision exists,
                // automatically promote initial chapter revision (or keep as candidate if repairing an existing chapter).
                let existingRevs = try await store.chapterRevisions(for: bookID, chapterID: chapter.id)
                try checkRunIsActive(runGeneration)
                if regeneratingFragmentID == nil, existingRevs.isEmpty {
                    _ = try await revisionController.promoteInitialChapterIfComplete(
                        bookID: bookID,
                        chapterID: chapter.id
                    )
                    try checkRunIsActive(runGeneration)
                }
            }
        } catch {
            if (error as? AudiobookProductionError) == .cancelled || error is CancellationError {
                try await markBookPaused(bookID: bookID, completed: completedCount, total: totalFragmentCount)
                throw AudiobookProductionError.cancelled
            } else {
                if var failedBook = try? await store.book(id: bookID) {
                    let hasCompletedAnyChapter = allChapters.contains { $0.currentChapterRevisionID != nil }
                    failedBook.productionState = (completedCount > 0 || hasCompletedAnyChapter) ? .paused : .idle
                    try? await store.updateBook(failedBook)
                }
                latestProgressByBook[bookID] = AudiobookProductionProgress(
                    bookID: bookID,
                    state: .paused,
                    completedFragments: completedCount,
                    totalFragments: totalFragmentCount,
                    lastErrorMessage: error.localizedDescription
                )
            }
            throw error
        }

        do {
            // A pause can arrive during persistence or chapter promotion, after rendering ends.
            // Keep any committed assets, but never let the old run overwrite the paused state.
            try checkRunIsActive(runGeneration)
            let updatedChapters = try await store.chapters(for: bookID)
            try checkRunIsActive(runGeneration)
            let readyChaptersCount = updatedChapters.filter { $0.currentChapterRevisionID != nil }.count
            var finalBook = try await store.book(id: bookID)
            try checkRunIsActive(runGeneration)
            if readyChaptersCount == updatedChapters.count && !updatedChapters.isEmpty {
                finalBook.productionState = .fullBookProduced
                finalBook.listenableState = .fullBookListenable
            } else if readyChaptersCount > 0 {
                finalBook.productionState = .partialChaptersReady
                finalBook.listenableState = .partialChaptersListenable
            } else {
                finalBook.productionState = .allConfirmedChaptersProduced
            }
            try await store.updateBook(finalBook)
            try checkRunIsActive(runGeneration)
            latestProgressByBook[bookID] = AudiobookProductionProgress(
                bookID: bookID,
                state: finalBook.productionState,
                completedFragments: completedCount,
                totalFragments: totalFragmentCount
            )
        } catch {
            if (error as? AudiobookProductionError) == .cancelled || error is CancellationError {
                try await markBookPaused(bookID: bookID, completed: completedCount, total: totalFragmentCount)
                throw AudiobookProductionError.cancelled
            }
            throw error
        }
    }

    public func pause() async {
        guard let bookID = activeBookID else { return }
        isPauseRequested = true
        generation += 1
        let activeFrag = inFlightFragmentID
        inFlightTask?.cancel()
        if let task = inFlightTask {
            _ = try? await task.value
        }
        inFlightTask = nil
        inFlightFragmentID = nil
        await MainActor.run {
            admission.release(.audiobook)
        }
        var progress = latestProgressByBook[bookID] ?? AudiobookProductionProgress(bookID: bookID, state: .paused)
        progress.state = .paused
        progress.unconfirmedRemoteStopFragmentID = activeFrag
        latestProgressByBook[bookID] = progress
        if var book = try? await store.book(id: bookID) {
            book.productionState = .paused
            try? await store.updateBook(book)
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
        runGeneration: Int
    ) async throws -> AudiobookRenderCandidate {
        let effectiveSpeed = min(
            Double(AudiobookLimits.maxPlaybackRate),
            max(Double(AudiobookLimits.minPlaybackRate), binding.allowedSpeed)
        )
        let request = AudiobookRenderCallRequest(
            text: text,
            voiceID: binding.voiceID,
            speed: effectiveSpeed,
            expectedVoiceRevision: binding.voiceRevision,
            expectedModelRevision: binding.modelRevision,
            seed: binding.callerSeed
        )

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
                try await clock.sleep(seconds: 0.25 * Double(attempt))
                continue
            }
            if isPauseRequested || Task.isCancelled || generation != runGeneration {
                await MainActor.run { admission.release(.audiobook) }
                throw AudiobookProductionError.cancelled
            }

            inFlightFragmentID = fragment.id
            let renderTask = Task<AudiobookRenderCallOutput, Error> { [renderer] in
                try await renderer.renderFragment(request)
            }
            inFlightTask = renderTask

            do {
                let output = try await renderTask.value
                inFlightTask = nil
                inFlightFragmentID = nil
                if generation == runGeneration {
                    await MainActor.run {
                        admission.release(.audiobook)
                    }
                } else {
                    throw AudiobookProductionError.cancelled
                }

                // The service receipt describes the original PCM. Verify it before
                // normalizing the local asset to the render policy's sample rate.
                let receivedPCMSHA = try AudioDigest.sha256HexOfPCM(in: output.wavData)
                let receiptVerified = output.isProvenanceVerified
                    && (output.pcmSHA256 == nil || output.pcmSHA256 == receivedPCMSHA)
                    && (output.voiceRevision == nil || binding.voiceRevision == "v1" || output.voiceRevision == binding.voiceRevision)
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
                    taskID: UUID(),
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
                if generation == runGeneration {
                    await MainActor.run {
                        admission.release(.audiobook)
                    }
                }
                if isPauseRequested || Task.isCancelled || error is CancellationError || generation != runGeneration {
                    throw AudiobookProductionError.cancelled
                }
                if error is AudioNormalizationError || error is AudioDigest.Failure {
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
                        if attempt < maxRetries {
                            attempt += 1
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
        var book = try await store.book(id: bookID)
        book.productionState = .paused
        try await store.updateBook(book)
        latestProgressByBook[bookID] = AudiobookProductionProgress(
            bookID: bookID,
            state: .paused,
            completedFragments: completed,
            totalFragments: total
        )
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
            guard let voice = capabilities.voices.first(where: {
                $0.id == binding.voiceID || $0.aliases.contains(binding.voiceID)
            }) else {
                throw AudiobookProductionError.capabilityVoiceUnavailable(
                    voiceID: binding.voiceID,
                    reason: "音色不在当前能力目录中"
                )
            }
            guard voice.available else {
                throw AudiobookProductionError.capabilityVoiceUnavailable(
                    voiceID: binding.voiceID,
                    reason: voice.availabilityReason.rawValue
                )
            }
            if voice.productionReady == false {
                let reason = voice.productionReadyReason ?? voice.availabilityReason.rawValue
                let nonBlockingReasons: Set<String> = [
                    "reference_validation_not_passed",
                    "model_runtime_identity_unknown"
                ]
                if !nonBlockingReasons.contains(reason) {
                    throw AudiobookProductionError.capabilityVoiceUnavailable(
                        voiceID: binding.voiceID,
                        reason: reason
                    )
                }
            }
            if let actualVoiceRev = voice.voiceRevision,
               binding.voiceRevision != "v1",
               actualVoiceRev != binding.voiceRevision
            {
                throw AudiobookProductionError.capabilityRevisionMismatch(
                    voiceID: binding.voiceID,
                    expected: binding.voiceRevision,
                    actual: actualVoiceRev
                )
            }
            let voiceModelRev = voice.model.catalogRevision ?? voice.model.runtimeRevision
            let slotModelRev = SpeechRailCapabilityRevisionSelector.ttsArtifactSlot(forVoiceMode: voice.mode)
                .flatMap { capabilities.models[$0]?.catalogRevision }
            if let actualModelRev = voiceModelRev,
               binding.modelRevision != "qwen3-tts-v1",
               actualModelRev != binding.modelRevision,
               slotModelRev != binding.modelRevision
            {
                throw AudiobookProductionError.capabilityRevisionMismatch(
                    voiceID: binding.voiceID,
                    expected: binding.modelRevision,
                    actual: actualModelRev
                )
            }
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
