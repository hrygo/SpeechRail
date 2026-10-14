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

    private var generation: Int = 0
    private var inFlightTask: Task<AudiobookRenderCallOutput, Error>?
    private var inFlightFragmentID: UUID?
    private var isPauseRequested: Bool = false
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
    }

    public func progress(for bookID: UUID) -> AudiobookProductionProgress? {
        latestProgressByBook[bookID]
    }

    public func start(
        bookID: UUID,
        chapterIDs: [UUID]
    ) async throws {
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

        // 2. Freeze atomic capability snapshot and verify all role voice/model pins upfront
        let capabilities = try await renderer.fetchEffectiveCapabilities()
        let frozenBindings = try await store.voiceBindings(for: bookID)
        try Self.verifyPinnedBindingsAgainstCapabilities(
            bindings: frozenBindings,
            capabilities: capabilities
        )

        // 3. Plan fragments for selected chapters and persist fragment definitions
        let source = try await store.sourceIndex(for: bookID)
        var plannedFragmentsByChapter: [UUID: [AudiobookFragment]] = [:]
        var totalFragmentCount = 0

        for chapter in selectedChapters {
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
            plannedFragmentsByChapter[chapter.id] = fragments
            totalFragmentCount += fragments.count
            try await store.saveFragments(bookID: bookID, chapterID: chapter.id, fragments: fragments)
        }

        generation += 1
        let runGeneration = generation
        isPauseRequested = false

        book.productionState = .running
        try await store.updateBook(book)

        var completedCount = 0
        latestProgressByBook[bookID] = AudiobookProductionProgress(
            bookID: bookID,
            state: .running,
            completedFragments: 0,
            totalFragments: totalFragmentCount
        )

        // 4. Sequentially render fragments (reusing valid existing candidates when dependencyDigest matches)
        let existingCandidates = try await store.candidates(for: bookID)
        for chapter in selectedChapters {
            let fragments = plannedFragmentsByChapter[chapter.id] ?? []
            for fragment in fragments {
                if isPauseRequested || Task.isCancelled || generation != runGeneration {
                    try await markBookPaused(bookID: bookID, completed: completedCount, total: totalFragmentCount)
                    throw AudiobookProductionError.cancelled
                }

                // Reuse already committed & verified candidate with identical dependencyDigest
                if let reusable = existingCandidates.first(where: {
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

                try await store.commitCandidate(candidate, wav: candidateWAVCache[candidate.id] ?? Data())
                candidateWAVCache.removeValue(forKey: candidate.id)

                completedCount += 1
                latestProgressByBook[bookID]?.completedFragments = completedCount
            }

            // If all fragments in the chapter now have verified candidates and no previous revision exists,
            // automatically promote initial chapter revision (or keep as candidate if repairing an existing chapter).
            let existingRevs = try await store.chapterRevisions(for: bookID, chapterID: chapter.id)
            if existingRevs.isEmpty {
                _ = try await revisionController.promoteInitialChapterIfComplete(
                    bookID: bookID,
                    chapterID: chapter.id
                )
            }
        }

        // Update book production & listenable state
        let updatedChapters = try await store.chapters(for: bookID)
        let readyChaptersCount = updatedChapters.filter { $0.currentChapterRevisionID != nil }.count
        var finalBook = try await store.book(id: bookID)
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
        latestProgressByBook[bookID] = AudiobookProductionProgress(
            bookID: bookID,
            state: finalBook.productionState,
            completedFragments: completedCount,
            totalFragments: totalFragmentCount
        )
    }

    public func pause() async {
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
        for (bookID, var prog) in latestProgressByBook {
            prog.state = .paused
            prog.unconfirmedRemoteStopFragmentID = activeFrag
            latestProgressByBook[bookID] = prog
            if var book = try? await store.book(id: bookID) {
                book.productionState = .paused
                try? await store.updateBook(book)
            }
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
        let request = AudiobookRenderCallRequest(
            text: text,
            voiceID: binding.voiceID,
            speed: policy.defaultSpeed,
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

                let fileSHA = AudiobookDigest.sha256Hex(output.wavData)
                let computedPCMSHA = try AudioDigest.sha256HexOfPCM(in: output.wavData)
                let frameCount = Self.extractPCM16MonoFrameCount(from: output.wavData)
                let receiptVerified = output.isProvenanceVerified
                    && (output.pcmSHA256 == nil || output.pcmSHA256 == computedPCMSHA)
                    && (output.voiceRevision == nil || output.voiceRevision == binding.voiceRevision)

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
                candidateWAVCache[candidateID] = output.wavData
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

    private static func verifyPinnedBindingsAgainstCapabilities(
        bindings: [UUID: AudiobookVoiceBinding],
        capabilities: EffectiveCapabilitySnapshot
    ) throws {
        let voicesByID = Dictionary(uniqueKeysWithValues: capabilities.voices.map { ($0.id, $0) })
        for (_, binding) in bindings {
            guard let voice = voicesByID[binding.voiceID] else {
                throw AudiobookProductionError.capabilityVoiceUnavailable(
                    voiceID: binding.voiceID,
                    reason: "音色不在当前能力目录中"
                )
            }
            guard voice.available, voice.productionReady != false else {
                throw AudiobookProductionError.capabilityVoiceUnavailable(
                    voiceID: binding.voiceID,
                    reason: voice.productionReadyReason ?? voice.availabilityReason.rawValue
                )
            }
            if let actualVoiceRev = voice.voiceRevision, actualVoiceRev != binding.voiceRevision {
                throw AudiobookProductionError.capabilityRevisionMismatch(
                    voiceID: binding.voiceID,
                    expected: binding.voiceRevision,
                    actual: actualVoiceRev
                )
            }
            if let actualModelRev = voice.model.catalogRevision ?? voice.model.runtimeRevision,
               actualModelRev != binding.modelRevision
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
        guard wav.count >= 44 else { return 0 }
        let pcmBytes = max(0, wav.count - 44)
        return Int64(pcmBytes / 2)
    }
}
