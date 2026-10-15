import Foundation

/// T05：全书三阶段分析流水线（窗口规划 -> 提取 -> 归并 -> 逐段标注）、检查点持久化与配置冻结守卫。
public struct AudiobookAnalysisSummary: Codable, Equatable, Sendable {
    public var bookID: UUID
    public var totalWindows: Int
    public var completedWindows: Int
    public var reusedCheckpointWindows: Int
    public var unknownSpeakerCount: Int
    public var unresolvedCollisionCount: Int
    public var analysisState: AudiobookAnalysisState
    public var isAllWindowsValidated: Bool {
        analysisState == .allWindowsValidated && totalWindows > 0 && completedWindows == totalWindows
    }

    public init(
        bookID: UUID,
        totalWindows: Int,
        completedWindows: Int,
        reusedCheckpointWindows: Int = 0,
        unknownSpeakerCount: Int,
        unresolvedCollisionCount: Int = 0,
        analysisState: AudiobookAnalysisState
    ) {
        self.bookID = bookID
        self.totalWindows = totalWindows
        self.completedWindows = completedWindows
        self.reusedCheckpointWindows = reusedCheckpointWindows
        self.unknownSpeakerCount = unknownSpeakerCount
        self.unresolvedCollisionCount = unresolvedCollisionCount
        self.analysisState = analysisState
    }
}

public actor AudiobookAnalysisPipeline {
    public typealias ClientFactory = @Sendable (AudiobookAnalysisConfigSnapshot) async throws -> any AudiobookAnalysisClient

    private let store: AudiobookProjectStore
    private let clientFactory: ClientFactory
    private let policy: AudiobookAnalysisPolicy
    private var progressSink: AudiobookAnalysisProgressSink
    private var cancelledBookIDs: Set<UUID> = []
    private var activeGenerationsByBook: [UUID: Int] = [:]
    /// 阶段一提取结果缓存（按 windowID + policyFingerprint + configurationDigest 键控），暂停或阶段三中断重跑时免除重复提取。
    private var extractionCacheByWindowKey: [String: [AudiobookExtractionResponse.Mention]] = [:]

    public init(
        store: AudiobookProjectStore,
        policy: AudiobookAnalysisPolicy = .standard,
        progressSink: AudiobookAnalysisProgressSink = .ignored,
        clientFactory: @escaping ClientFactory
    ) {
        self.store = store
        self.policy = policy
        self.progressSink = progressSink
        self.clientFactory = clientFactory
    }

    public func cancel(bookID: UUID) {
        cancelledBookIDs.insert(bookID)
        activeGenerationsByBook[bookID, default: 1] += 1
    }

    /// 安装本次 run 的进度投递目标。管线一次只跑一个 run，
    /// 每次 `beginAnalysis` 都重新安装，不会有跨 run 串扰。
    ///
    /// 注意：安装与 `run()` 是两次 actor 调用，必然存在竞态窗口；
    /// 生产调用方应使用 `run(bookID:config:progressSink:)` 把 sink 随 run 一起传入。
    /// 该方法仅保留给需要先装后跑的调用方。
    public func setProgressSink(_ sink: AudiobookAnalysisProgressSink) {
        progressSink = sink
    }

    public func run(
        bookID: UUID,
        config: AudiobookAnalysisConfigSnapshot,
        progressSink: AudiobookAnalysisProgressSink? = nil
    ) async throws -> AudiobookAnalysisSummary {
        guard config.isConfigured else {
            throw AudiobookAnalysisError.notConfigured
        }
        cancelledBookIDs.remove(bookID)
        let runGeneration = max(config.generation, (activeGenerationsByBook[bookID] ?? 0) + 1)
        activeGenerationsByBook[bookID] = runGeneration

        var frozenSnapshot = config
        frozenSnapshot.generation = runGeneration

        let client = try await clientFactory(frozenSnapshot)
        guard client.configurationDigest == frozenSnapshot.configurationDigest else {
            throw AudiobookAnalysisError.configurationChangedDuringRun
        }

        var book = try await store.book(id: bookID)
        book.analysisState = .running
        try await store.updateBook(book)

        let emitter = AudiobookAnalysisEventEmitter(
            runID: UUID().uuidString,
            bookID: bookID,
            sink: progressSink ?? self.progressSink
        )
        emitter.setPlan(totalWindows: 0, reusedCheckpointWindows: 0, maxAttempts: policy.maxCallsPerRootWindow)
        let chapterOrdinalByID = Dictionary(
            uniqueKeysWithValues: (try? await store.chapters(for: bookID))?.map { ($0.id, $0.ordinal + 1) } ?? []
        )

        do {
            let source = try await store.sourceIndex(for: bookID)
            let chapters = try await store.chapters(for: bookID)
            let allAtoms = try await store.atoms(for: bookID)
            let atomsByID = Dictionary(uniqueKeysWithValues: allAtoms.map { ($0.id, $0) })

            let plannedWindows = try Self.planRootWindows(
                bookID: bookID,
                chapters: chapters,
                atoms: allAtoms,
                source: source,
                policy: policy,
                config: frozenSnapshot
            )

            let existingWindows = try await store.analysisWindows(for: bookID)
            let existingAnnotations = try await store.annotations(for: bookID)
            let annotationsByWindowID = Dictionary(grouping: existingAnnotations, by: \.windowID)

            var reusedCheckpointCount = 0
            var extractedMentions: [AudiobookExtractionResponse.Mention] = []
            var extractionCallCounters: [UUID: Int] = [:]
            var annotationCallCounters: [UUID: Int] = [:]
            var validatedAnnotationsByWindowID: [UUID: [AudiobookAnnotation]] = [:]

            // Phase 1: Extraction across windows (skipping windows that already have matching valid checkpoints)
            var windowsNeedingWork: [AudiobookAnalysisWindow] = []
            for planned in plannedWindows {
                try checkNotCancelled(bookID: bookID, expectedGeneration: runGeneration, client: client, snapshot: frozenSnapshot)
                if let existing = existingWindows.first(where: {
                    $0.primaryAtomIDs == planned.primaryAtomIDs
                        && $0.policyFingerprint == planned.policyFingerprint
                        && $0.configurationDigest == planned.configurationDigest
                        && $0.isCompleted
                }),
                   let savedAnns = annotationsByWindowID[existing.id],
                   Self.validateWindowAnnotationsCoverPrimaryAtoms(
                       primaryAtomIDs: existing.primaryAtomIDs,
                       annotations: savedAnns
                   )
                {
                    reusedCheckpointCount += 1
                    validatedAnnotationsByWindowID[planned.id] = savedAnns
                } else {
                    windowsNeedingWork.append(planned)
                    try await store.saveAnalysisWindow(planned)
                }
            }
            emitter.setPlan(
                totalWindows: plannedWindows.count,
                reusedCheckpointWindows: reusedCheckpointCount,
                maxAttempts: policy.maxCallsPerRootWindow
            )
            emitter.emit(.planned)

            for window in windowsNeedingWork {
                try checkNotCancelled(bookID: bookID, expectedGeneration: runGeneration, client: client, snapshot: frozenSnapshot)
                emitter.setCurrentWindow(
                    chapterOrdinal: chapterOrdinalByID[window.chapterID] ?? 1,
                    windowOrdinal: window.ordinal + 1
                )
                let cacheKey = Self.extractionCacheKey(for: window)
                if let cachedMentions = extractionCacheByWindowKey[cacheKey] {
                    extractedMentions.append(contentsOf: cachedMentions)
                    emitter.noteExtracted()
                    emitter.emit(.windowExtracted)
                    continue
                }
                let primaryItems = try makePromptAtomItems(
                    ids: window.primaryAtomIDs,
                    atomsByID: atomsByID,
                    source: source,
                    assignLocalIndices: true
                )
                let leadingItems = try makePromptAtomItems(
                    ids: window.leadingContextAtomIDs,
                    atomsByID: atomsByID,
                    source: source
                )
                let trailingItems = try makePromptAtomItems(
                    ids: window.trailingContextAtomIDs,
                    atomsByID: atomsByID,
                    source: source
                )

                let mentions = try await executeExtractionWithSplitFallback(
                    rootWindowID: window.rootWindowID,
                    primaryItems: primaryItems,
                    leadingItems: leadingItems,
                    trailingItems: trailingItems,
                    client: client,
                    snapshot: frozenSnapshot,
                    bookID: bookID,
                    runGeneration: runGeneration,
                    callCounters: &extractionCallCounters,
                    emitter: emitter,
                    diagnostics: client.callDiagnostics
                )
                emitter.emitLLMCalls(client.callDiagnostics?.takeAll())
                extractionCacheByWindowKey[cacheKey] = mentions
                extractedMentions.append(contentsOf: mentions)
                emitter.noteExtracted()
                emitter.emit(.windowExtracted)
            }

            // Phase 2: Bounded cast consolidation (32 candidates per batch, with local alias pre-clustering & source excerpts)
            var characters = try await store.characters(for: bookID)
            if !characters.contains(where: \.isNarrator) {
                let narrator = AudiobookCharacter(
                    bookID: bookID,
                    displayName: "旁白",
                    aliases: ["叙述"],
                    isNarrator: true,
                    isMajor: true,
                    chapterIDs: chapters.map(\.id)
                )
                characters.insert(narrator, at: 0)
            }

            var unresolvedCollisions = Set<String>()
            let mentionBatches = AudiobookCastRegistry.batchMentions(
                extractedMentions,
                batchSize: policy.maxMergeCandidatesPerBatch,
                atomsByID: atomsByID,
                source: source
            )
            emitter.setMergeBatches(total: mentionBatches.count)
            for (batchIndex, batch) in mentionBatches.enumerated() {
                try checkNotCancelled(bookID: bookID, expectedGeneration: runGeneration, client: client, snapshot: frozenSnapshot)
                let batchEvidenceChapterIDs = Set(
                    batch.flatMap(\.evidenceAtomIDs).compactMap { atomsByID[$0]?.chapterID }
                )
                let existingSummaries = AudiobookCastRegistry.selectCandidateSummariesForEvidence(
                    characters: characters,
                    chapterIDs: batchEvidenceChapterIDs,
                    windowText: batch.map(\.surfaceName).joined(separator: " "),
                    policy: policy
                )
                let safeExistingSummaries = AudiobookCastRegistry.clampSummariesToBudget(
                    existingSummaries,
                    maxScalars: policy.maxCharacterSummaryScalars,
                    maxCandidates: policy.maxMergeCandidatesPerBatch
                )
                let mergeRootID = UUID()
                var mergePrompt = try AudiobookAnalysisPrompts.makeMergePrompt(
                    rootWindowID: mergeRootID,
                    candidates: batch,
                    existingCharacters: safeExistingSummaries,
                    policy: policy
                )
                // run 关联：把本次 runID 写进 prompt，供 live 链路做 LLM 观测 sessionID。
                mergePrompt.observationSessionID = emitter.runID
                // awaitingLLM 不是窗口口径：归并阶段的等待由随后的 castBatchMerged 与
                // 心跳表达，避免 attempt 计数在 batch 之间串扰。
                let rawMerge: String
                do {
                    rawMerge = try await client.complete(mergePrompt)
                } catch {
                    emitter.emitLLMCalls(client.callDiagnostics?.takeAll())
                    throw error
                }
                emitter.emitLLMCalls(client.callDiagnostics?.takeAll())
                try checkNotCancelled(bookID: bookID, expectedGeneration: runGeneration, client: client, snapshot: frozenSnapshot)
                let mergeResponse = try decodeMergeResponse(from: rawMerge, fallbackMentions: batch)
                let outcome = AudiobookCastRegistry.applyMergeBatch(
                    bookID: bookID,
                    existingCharacters: characters,
                    batchMentions: batch,
                    mergeGroups: mergeResponse.groups,
                    atomsByID: atomsByID,
                    source: source
                )
                characters = outcome.characters
                unresolvedCollisions.formUnion(outcome.unresolvedCollisionNames)
                _ = batchIndex
                emitter.noteBatchMerged()
                emitter.emit(.castBatchMerged)
            }
            try await store.saveCharacters(bookID: bookID, characters: characters)

            let narratorID = characters.first(where: \.isNarrator)?.id ?? UUID()
            let roleNameByID = Dictionary(uniqueKeysWithValues: characters.map { ($0.id, $0.displayName) })

            // 初始化跨窗口已解析说话人状态表（包含已复用的检查点窗口）
            var resolvedSpeakerByAtomID: [UUID: String] = [:]
            for savedAnns in validatedAnnotationsByWindowID.values {
                for ann in savedAnns {
                    if let roleID = ann.assignment.roleID, let name = roleNameByID[roleID] {
                        resolvedSpeakerByAtomID[ann.atomID] = name
                    }
                }
            }

            // Phase 3: Per-window speaker annotation with strict primary atom coverage and checkpoint commit
            for var window in windowsNeedingWork {
                try checkNotCancelled(bookID: bookID, expectedGeneration: runGeneration, client: client, snapshot: frozenSnapshot)
                emitter.setCurrentWindow(
                    chapterOrdinal: chapterOrdinalByID[window.chapterID] ?? 1,
                    windowOrdinal: window.ordinal + 1
                )
                let primaryItems = try makePromptAtomItems(
                    ids: window.primaryAtomIDs,
                    atomsByID: atomsByID,
                    source: source,
                    assignLocalIndices: true
                )
                let leadingItems = try makePromptAtomItems(
                    ids: window.leadingContextAtomIDs,
                    atomsByID: atomsByID,
                    source: source,
                    resolvedSpeakerByAtomID: resolvedSpeakerByAtomID
                )
                let trailingItems = try makePromptAtomItems(
                    ids: window.trailingContextAtomIDs,
                    atomsByID: atomsByID,
                    source: source
                )
                let windowText = primaryItems.map(\.text).joined(separator: "\n")
                let candidateSummaries = AudiobookCastRegistry.selectCandidateSummariesForWindow(
                    characters: characters,
                    chapterID: window.chapterID,
                    windowText: windowText,
                    policy: policy
                )

                let annotations = try await executeAnnotationWithSplitFallback(
                    window: window,
                    primaryItems: primaryItems,
                    leadingItems: leadingItems,
                    trailingItems: trailingItems,
                    candidateSummaries: candidateSummaries,
                    characters: characters,
                    narratorID: narratorID,
                    roleNameByID: roleNameByID,
                    atomsByID: atomsByID,
                    client: client,
                    snapshot: frozenSnapshot,
                    bookID: bookID,
                    runGeneration: runGeneration,
                    callCounters: &annotationCallCounters,
                    emitter: emitter,
                    diagnostics: client.callDiagnostics
                )
                emitter.emitLLMCalls(client.callDiagnostics?.takeAll())

                guard Self.validateWindowAnnotationsCoverPrimaryAtoms(
                    primaryAtomIDs: window.primaryAtomIDs,
                    annotations: annotations
                ) else {
                    book.analysisState = .failed
                    try await store.updateBook(book)
                    throw AudiobookAnalysisError.atomCoverageViolation("窗口 \(window.id) 标注未完整覆盖 primary atoms。")
                }

                for ann in annotations {
                    if let roleID = ann.assignment.roleID, let name = roleNameByID[roleID] {
                        resolvedSpeakerByAtomID[ann.atomID] = name
                    }
                }

                window.isCompleted = true
                try checkNotCancelled(bookID: bookID, expectedGeneration: runGeneration, client: client, snapshot: frozenSnapshot)
                try await store.saveAnnotations(bookID: bookID, annotations: annotations)
                try await store.saveAnalysisWindow(window)
                emitter.noteAnnotated()
                emitter.emit(.windowAnnotated)
            }

            // Verify all windows for the book are completed and refresh character major/minor status
            let finalAnnotations = try await store.annotations(for: bookID)
            characters = AudiobookCastRegistry.refreshCharacterMajorStatusAndOrder(
                characters: characters,
                annotations: finalAnnotations
            )
            try await store.saveCharacters(bookID: bookID, characters: characters)

            let unknownCount = finalAnnotations.filter { $0.assignment.isUnknown }.count
            let completedWindowCount = reusedCheckpointCount + windowsNeedingWork.count
            let isAllComplete = completedWindowCount == plannedWindows.count && !plannedWindows.isEmpty

            book.analysisState = isAllComplete ? .allWindowsValidated : .paused
            try await store.updateBook(book)

            emitter.emitRunEnded(outcome: .completed)
            return AudiobookAnalysisSummary(
                bookID: bookID,
                totalWindows: plannedWindows.count,
                completedWindows: completedWindowCount,
                reusedCheckpointWindows: reusedCheckpointCount,
                unknownSpeakerCount: unknownCount,
                unresolvedCollisionCount: unresolvedCollisions.count,
                analysisState: book.analysisState
            )
        } catch {
            if var latestBook = try? await store.book(id: bookID) {
                let isCancelError = (error as? AudiobookAnalysisError) == .cancelled
                    || error is CancellationError
                latestBook.analysisState = isCancelError ? .paused : .failed
                try? await store.updateBook(latestBook)
                emitter.emitRunEnded(
                    outcome: isCancelError ? .cancelled : .failed,
                    errorCode: AudiobookAnalysisErrorCode.code(for: error)
                )
            }
            throw error
        }
    }

    // MARK: - Window Planning

    public static func planRootWindows(
        bookID: UUID,
        chapters: [AudiobookChapter],
        atoms: [AudiobookTextAtom],
        source: AudiobookSourceIndex,
        policy: AudiobookAnalysisPolicy,
        config: AudiobookAnalysisConfigSnapshot
    ) throws -> [AudiobookAnalysisWindow] {
        let atomsByChapter = Dictionary(grouping: atoms, by: \.chapterID)
        var windows: [AudiobookAnalysisWindow] = []
        var globalOrdinal = 0

        for chapter in chapters.sorted(by: { $0.ordinal < $1.ordinal }) {
            let excludedSet = Set(chapter.excludedRanges)
            let chapterAtoms = (atomsByChapter[chapter.id] ?? [])
                .sorted { $0.ordinal < $1.ordinal }
                .filter { atom in
                    atom.kind != .formatting && !excludedSet.contains(atom.sourceRange)
                }

            guard !chapterAtoms.isEmpty else { continue }

            var startIndex = 0
            while startIndex < chapterAtoms.count {
                var endIndex = startIndex
                var scalarCount = 0

                while endIndex < chapterAtoms.count {
                    let atom = chapterAtoms[endIndex]
                    let atomText = try source.text(in: atom.sourceRange)
                    let atomScalars = atomText.unicodeScalars.count
                    let nextCount = endIndex - startIndex + 1
                    if endIndex > startIndex,
                       (scalarCount + atomScalars > policy.maxPrimaryScalars || nextCount > policy.maxPrimaryAtoms)
                    {
                        break
                    }
                    scalarCount += atomScalars
                    endIndex += 1
                }

                let primarySlice = Array(chapterAtoms[startIndex..<endIndex])
                let leadingSlice = selectContextAtoms(
                    from: chapterAtoms,
                    beforeIndex: startIndex,
                    source: source,
                    maxScalars: policy.maxContextScalarsPerSide
                )
                let trailingSlice = selectTrailingContextAtoms(
                    from: chapterAtoms,
                    afterIndex: endIndex,
                    source: source,
                    maxScalars: policy.maxContextScalarsPerSide
                )

                let windowID = deterministicWindowID(
                    bookID: bookID,
                    chapterID: chapter.id,
                    primaryAtomIDs: primarySlice.map(\.id),
                    policyFingerprint: policy.policyDigest,
                    configurationDigest: config.configurationDigest
                )

                let window = AudiobookAnalysisWindow(
                    id: windowID,
                    rootWindowID: windowID,
                    bookID: bookID,
                    chapterID: chapter.id,
                    ordinal: globalOrdinal,
                    primaryAtomIDs: primarySlice.map(\.id),
                    leadingContextAtomIDs: leadingSlice.map(\.id),
                    trailingContextAtomIDs: trailingSlice.map(\.id),
                    policyFingerprint: policy.policyDigest,
                    configurationDigest: config.configurationDigest,
                    generation: config.generation,
                    isCompleted: false
                )
                windows.append(window)
                globalOrdinal += 1
                startIndex = endIndex
            }
        }

        return windows
    }

    // MARK: - Split Fallback & Strict Validation

    private func executeExtractionWithSplitFallback(
        rootWindowID: UUID,
        primaryItems: [AudiobookPromptAtomItem],
        leadingItems: [AudiobookPromptAtomItem],
        trailingItems: [AudiobookPromptAtomItem],
        client: any AudiobookAnalysisClient,
        snapshot: AudiobookAnalysisConfigSnapshot,
        bookID: UUID,
        runGeneration: Int,
        callCounters: inout [UUID: Int],
        emitter: AudiobookAnalysisEventEmitter?,
        diagnostics: AudiobookAnalysisCallDiagnosticsCollector?
    ) async throws -> [AudiobookExtractionResponse.Mention] {
        try checkNotCancelled(bookID: bookID, expectedGeneration: runGeneration, client: client, snapshot: snapshot)
        let usedCalls = callCounters[rootWindowID, default: 0]
        guard usedCalls < policy.maxCallsPerRootWindow else {
            throw AudiobookAnalysisError.rootCallBudgetExhausted(rootWindowID: rootWindowID)
        }
        callCounters[rootWindowID] = usedCalls + 1
        let attempt = usedCalls + 1
        emitter?.emit(.awaitingLLM, attempt: attempt)

        var prompt = try AudiobookAnalysisPrompts.makeExtractionPrompt(
            rootWindowID: rootWindowID,
            primaryAtoms: primaryItems,
            leadingContext: leadingItems,
            trailingContext: trailingItems,
            policy: policy
        )
        // run 关联：把本次 runID 写进 prompt，供 live 链路做 LLM 观测 sessionID。
        prompt.observationSessionID = emitter?.runID

        do {
            let raw = try await client.complete(prompt)
            emitter?.emitLLMCalls(diagnostics?.takeAll())
            try checkNotCancelled(bookID: bookID, expectedGeneration: runGeneration, client: client, snapshot: snapshot)
            let response = try decodeExtractionResponse(from: raw, primaryItems: primaryItems)
            return response.mentions
        } catch let error as AudiobookAnalysisError {
            // 失败调用的诊断回执（错误码）在进入拆窗重试前必须先发射，
            // 否则 takeAll 永远取不到失败回执，开发者详情的"上次错误码"恒为空。
            emitter?.emitLLMCalls(diagnostics?.takeAll())
            if case .cancelled = error { throw error }
            if case .configurationChangedDuringRun = error { throw error }
            return try await splitOrFailExtraction(
                error: error,
                rootWindowID: rootWindowID,
                primaryItems: primaryItems,
                leadingItems: leadingItems,
                trailingItems: trailingItems,
                client: client,
                snapshot: snapshot,
                bookID: bookID,
                runGeneration: runGeneration,
                callCounters: &callCounters,
                emitter: emitter,
                diagnostics: diagnostics
            )
        } catch {
            // 非 AnalysisError 同样先发射诊断回执再拆窗。
            emitter?.emitLLMCalls(diagnostics?.takeAll())
            return try await splitOrFailExtraction(
                error: error,
                rootWindowID: rootWindowID,
                primaryItems: primaryItems,
                leadingItems: leadingItems,
                trailingItems: trailingItems,
                client: client,
                snapshot: snapshot,
                bookID: bookID,
                runGeneration: runGeneration,
                callCounters: &callCounters,
                emitter: emitter,
                diagnostics: diagnostics
            )
        }
    }

    private func splitOrFailExtraction(
        error: Error,
        rootWindowID: UUID,
        primaryItems: [AudiobookPromptAtomItem],
        leadingItems: [AudiobookPromptAtomItem],
        trailingItems: [AudiobookPromptAtomItem],
        client: any AudiobookAnalysisClient,
        snapshot: AudiobookAnalysisConfigSnapshot,
        bookID: UUID,
        runGeneration: Int,
        callCounters: inout [UUID: Int],
        emitter: AudiobookAnalysisEventEmitter?,
        diagnostics: AudiobookAnalysisCallDiagnosticsCollector?
    ) async throws -> [AudiobookExtractionResponse.Mention] {
        let totalScalars = primaryItems.reduce(0) { $0 + $1.text.unicodeScalars.count }
        guard primaryItems.count > 1,
              totalScalars >= policy.minWindowScalars * 2,
              (callCounters[rootWindowID] ?? 0) < policy.maxCallsPerRootWindow
        else {
            throw AudiobookAnalysisError.windowFailed(
                windowID: rootWindowID,
                reason: error.localizedDescription
            )
        }
        emitter?.emit(.retryingSplit, attempt: (callCounters[rootWindowID] ?? 0) + 1)
        let mid = primaryItems.count / 2
        let left = Self.reindexPromptAtomItems(Array(primaryItems[..<mid]))
        let right = Self.reindexPromptAtomItems(Array(primaryItems[mid...]))
        let leftMentions = try await executeExtractionWithSplitFallback(
            rootWindowID: rootWindowID,
            primaryItems: left,
            leadingItems: leadingItems,
            trailingItems: Array(right.prefix(2)),
            client: client,
            snapshot: snapshot,
            bookID: bookID,
            runGeneration: runGeneration,
            callCounters: &callCounters,
            emitter: emitter,
            diagnostics: diagnostics
        )
        let rightMentions = try await executeExtractionWithSplitFallback(
            rootWindowID: rootWindowID,
            primaryItems: right,
            leadingItems: Array(left.suffix(2)),
            trailingItems: trailingItems,
            client: client,
            snapshot: snapshot,
            bookID: bookID,
            runGeneration: runGeneration,
            callCounters: &callCounters,
            emitter: emitter,
            diagnostics: diagnostics
        )
        return leftMentions + rightMentions
    }

    private func executeAnnotationWithSplitFallback(
        window: AudiobookAnalysisWindow,
        primaryItems: [AudiobookPromptAtomItem],
        leadingItems: [AudiobookPromptAtomItem],
        trailingItems: [AudiobookPromptAtomItem],
        candidateSummaries: [AudiobookPromptCharacterSummary],
        characters: [AudiobookCharacter],
        narratorID: UUID,
        roleNameByID: [UUID: String],
        atomsByID: [UUID: AudiobookTextAtom],
        client: any AudiobookAnalysisClient,
        snapshot: AudiobookAnalysisConfigSnapshot,
        bookID: UUID,
        runGeneration: Int,
        callCounters: inout [UUID: Int],
        emitter: AudiobookAnalysisEventEmitter?,
        diagnostics: AudiobookAnalysisCallDiagnosticsCollector?
    ) async throws -> [AudiobookAnnotation] {
        try checkNotCancelled(bookID: bookID, expectedGeneration: runGeneration, client: client, snapshot: snapshot)
        let usedCalls = callCounters[window.rootWindowID, default: 0]
        guard usedCalls < policy.maxCallsPerRootWindow else {
            throw AudiobookAnalysisError.rootCallBudgetExhausted(rootWindowID: window.rootWindowID)
        }
        callCounters[window.rootWindowID] = usedCalls + 1
        let attempt = usedCalls + 1
        emitter?.emit(.awaitingLLM, attempt: attempt)

        let safeCandidates = AudiobookCastRegistry.clampSummariesToBudget(
            candidateSummaries,
            maxScalars: policy.maxCharacterSummaryScalars,
            maxCandidates: policy.maxMergeCandidatesPerBatch
        )

        var prompt = try AudiobookAnalysisPrompts.makeAnnotationPrompt(
            rootWindowID: window.rootWindowID,
            primaryAtoms: primaryItems,
            leadingContext: leadingItems,
            trailingContext: trailingItems,
            candidateCharacters: safeCandidates,
            policy: policy
        )
        // run 关联：把本次 runID 写进 prompt，供 live 链路做 LLM 观测 sessionID。
        prompt.observationSessionID = emitter?.runID

        do {
            let raw = try await client.complete(prompt)
            emitter?.emitLLMCalls(diagnostics?.takeAll())
            try checkNotCancelled(bookID: bookID, expectedGeneration: runGeneration, client: client, snapshot: snapshot)
            return try decodeAndValidateAnnotations(
                from: raw,
                window: window,
                primaryItems: primaryItems,
                candidateSummaries: candidateSummaries,
                characters: characters,
                narratorID: narratorID,
                atomsByID: atomsByID
            )
        } catch let error as AudiobookAnalysisError {
            // 失败调用的诊断回执（错误码）在进入拆窗重试前必须先发射，
            // 否则 takeAll 永远取不到失败回执，开发者详情的"上次错误码"恒为空。
            emitter?.emitLLMCalls(diagnostics?.takeAll())
            if case .cancelled = error { throw error }
            if case .configurationChangedDuringRun = error { throw error }
            return try await splitOrFailAnnotation(
                error: error,
                window: window,
                primaryItems: primaryItems,
                leadingItems: leadingItems,
                trailingItems: trailingItems,
                candidateSummaries: candidateSummaries,
                characters: characters,
                narratorID: narratorID,
                roleNameByID: roleNameByID,
                atomsByID: atomsByID,
                client: client,
                snapshot: snapshot,
                bookID: bookID,
                runGeneration: runGeneration,
                callCounters: &callCounters,
                emitter: emitter,
                diagnostics: diagnostics
            )
        } catch {
            // 非 AnalysisError 同样先发射诊断回执再拆窗。
            emitter?.emitLLMCalls(diagnostics?.takeAll())
            return try await splitOrFailAnnotation(
                error: error,
                window: window,
                primaryItems: primaryItems,
                leadingItems: leadingItems,
                trailingItems: trailingItems,
                candidateSummaries: candidateSummaries,
                characters: characters,
                narratorID: narratorID,
                roleNameByID: roleNameByID,
                atomsByID: atomsByID,
                client: client,
                snapshot: snapshot,
                bookID: bookID,
                runGeneration: runGeneration,
                callCounters: &callCounters,
                emitter: emitter,
                diagnostics: diagnostics
            )
        }
    }

    private func splitOrFailAnnotation(
        error: Error,
        window: AudiobookAnalysisWindow,
        primaryItems: [AudiobookPromptAtomItem],
        leadingItems: [AudiobookPromptAtomItem],
        trailingItems: [AudiobookPromptAtomItem],
        candidateSummaries: [AudiobookPromptCharacterSummary],
        characters: [AudiobookCharacter],
        narratorID: UUID,
        roleNameByID: [UUID: String],
        atomsByID: [UUID: AudiobookTextAtom],
        client: any AudiobookAnalysisClient,
        snapshot: AudiobookAnalysisConfigSnapshot,
        bookID: UUID,
        runGeneration: Int,
        callCounters: inout [UUID: Int],
        emitter: AudiobookAnalysisEventEmitter?,
        diagnostics: AudiobookAnalysisCallDiagnosticsCollector?
    ) async throws -> [AudiobookAnnotation] {
        let totalScalars = primaryItems.reduce(0) { $0 + $1.text.unicodeScalars.count }
        guard primaryItems.count > 1,
              totalScalars >= policy.minWindowScalars * 2,
              (callCounters[window.rootWindowID] ?? 0) < policy.maxCallsPerRootWindow
        else {
            var book = try await store.book(id: bookID)
            book.analysisState = .failed
            try await store.updateBook(book)
            throw AudiobookAnalysisError.windowFailed(
                windowID: window.id,
                reason: error.localizedDescription
            )
        }
        emitter?.emit(.retryingSplit, attempt: (callCounters[window.rootWindowID] ?? 0) + 1)
        let mid = primaryItems.count / 2
        let left = Self.reindexPromptAtomItems(Array(primaryItems[..<mid]))
        let right = Self.reindexPromptAtomItems(Array(primaryItems[mid...]))
        let leftAnns = try await executeAnnotationWithSplitFallback(
            window: window,
            primaryItems: left,
            leadingItems: leadingItems,
            trailingItems: Array(right.prefix(2)),
            candidateSummaries: candidateSummaries,
            characters: characters,
            narratorID: narratorID,
            roleNameByID: roleNameByID,
            atomsByID: atomsByID,
            client: client,
            snapshot: snapshot,
            bookID: bookID,
            runGeneration: runGeneration,
            callCounters: &callCounters,
            emitter: emitter,
            diagnostics: diagnostics
        )

        var leftSpeakersByAtom: [UUID: String] = [:]
        for ann in leftAnns {
            if let roleID = ann.assignment.roleID, let name = roleNameByID[roleID] {
                leftSpeakersByAtom[ann.atomID] = name
            }
        }
        let rightLeading = Array(left.suffix(2)).map { item -> AudiobookPromptAtomItem in
            var copy = item
            copy.localIndex = nil
            copy.resolvedSpeakerName = leftSpeakersByAtom[item.atomID]
            return copy
        }

        let rightAnns = try await executeAnnotationWithSplitFallback(
            window: window,
            primaryItems: right,
            leadingItems: rightLeading,
            trailingItems: trailingItems,
            candidateSummaries: candidateSummaries,
            characters: characters,
            narratorID: narratorID,
            roleNameByID: roleNameByID,
            atomsByID: atomsByID,
            client: client,
            snapshot: snapshot,
            bookID: bookID,
            runGeneration: runGeneration,
            callCounters: &callCounters,
            emitter: emitter,
            diagnostics: diagnostics
        )
        return leftAnns + rightAnns
    }

    private func decodeExtractionResponse(
        from raw: String,
        primaryItems: [AudiobookPromptAtomItem]
    ) throws -> AudiobookExtractionResponse {
        let cleaned = Self.stripMarkdownCodeFences(raw)
        guard let data = cleaned.data(using: .utf8),
              var decoded = try? JSONDecoder().decode(AudiobookExtractionResponse.self, from: data)
        else {
            throw AudiobookAnalysisError.invalidStructuredOutput("人物提取 JSON 解码失败。")
        }

        let atomIDByRef = Self.buildAtomLookupTable(for: primaryItems)
        let allowedAtomIDs = Set(primaryItems.map(\.atomID))

        // 支持完整 UUID 与短索引（如 "1"、"#2"），并过滤掉模型误引用的上下文 atomID
        decoded.mentions = decoded.mentions.map { mention in
            var copy = mention
            var resolvedIDs: [UUID] = []
            let rawTokens = !mention.evidenceAtomRefs.isEmpty
                ? mention.evidenceAtomRefs
                : mention.evidenceAtomIDs.map(\.uuidString)
            for token in rawTokens {
                if let resolved = Self.resolveAtomID(from: token, lookup: atomIDByRef, allowedAtomIDs: allowedAtomIDs),
                   !resolvedIDs.contains(resolved)
                {
                    resolvedIDs.append(resolved)
                }
            }
            copy.evidenceAtomIDs = resolvedIDs
            copy.evidenceAtomRefs = resolvedIDs.map(\.uuidString)
            return copy
        }
        return decoded
    }

    private func decodeMergeResponse(
        from raw: String,
        fallbackMentions: [AudiobookExtractionResponse.Mention]
    ) throws -> AudiobookMergeResponse {
        let cleaned = Self.stripMarkdownCodeFences(raw)
        guard let data = cleaned.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AudiobookMergeResponse.self, from: data)
        else {
            throw AudiobookAnalysisError.invalidStructuredOutput("角色归并 JSON 解码失败。")
        }
        if decoded.groups.isEmpty && !fallbackMentions.isEmpty {
            let defaultGroups = fallbackMentions.map { mention in
                AudiobookMergeResponse.Group(
                    canonicalName: mention.surfaceName,
                    memberSurfaceNames: [mention.surfaceName],
                    aliases: mention.aliases,
                    isCollisionUnresolved: false,
                    evidenceSummary: mention.voiceTraitEvidence
                )
            }
            return AudiobookMergeResponse(groups: defaultGroups)
        }
        return decoded
    }

    private func decodeAndValidateAnnotations(
        from raw: String,
        window: AudiobookAnalysisWindow,
        primaryItems: [AudiobookPromptAtomItem],
        candidateSummaries: [AudiobookPromptCharacterSummary],
        characters: [AudiobookCharacter],
        narratorID: UUID,
        atomsByID: [UUID: AudiobookTextAtom]
    ) throws -> [AudiobookAnnotation] {
        let cleaned = Self.stripMarkdownCodeFences(raw)
        guard let data = cleaned.data(using: .utf8),
              let response = try? JSONDecoder().decode(AudiobookAnnotationResponse.self, from: data)
        else {
            throw AudiobookAnalysisError.invalidStructuredOutput("段落标注 JSON 解码失败。")
        }

        let expectedIDSet = Set(primaryItems.map(\.atomID))
        let atomIDByRef = Self.buildAtomLookupTable(for: primaryItems)
        let roleIDByRef = Self.buildRoleLookupTable(
            characters: characters,
            candidateSummaries: candidateSummaries
        )
        let validRoleIDs = Set(characters.map(\.id))

        var itemsByAtomID: [UUID: AudiobookAnnotationResponse.Item] = [:]
        for item in response.items {
            let rawToken = item.atomRef ?? item.atomID.uuidString
            guard let resolvedAtomID = Self.resolveAtomID(
                from: rawToken,
                lookup: atomIDByRef,
                allowedAtomIDs: expectedIDSet
            ) else {
                continue
            }
            if itemsByAtomID[resolvedAtomID] == nil {
                var normalized = item
                normalized.atomID = resolvedAtomID
                if let rawRole = item.roleRef,
                   let resolvedRole = Self.resolveRoleID(from: rawRole, lookup: roleIDByRef, validRoleIDs: validRoleIDs)
                {
                    normalized.roleID = resolvedRole
                }
                let resolvedCandidates = item.candidateRoleRefs.compactMap { ref in
                    Self.resolveRoleID(from: ref, lookup: roleIDByRef, validRoleIDs: validRoleIDs)
                }
                if !resolvedCandidates.isEmpty {
                    normalized.candidateRoleIDs = resolvedCandidates
                }
                itemsByAtomID[resolvedAtomID] = normalized
            }
        }

        let hasAnyDialogueAtom = primaryItems.contains { $0.containsDirectDialogue && $0.kind != .heading }
        guard !itemsByAtomID.isEmpty || primaryItems.isEmpty || !hasAnyDialogueAtom else {
            throw AudiobookAnalysisError.atomCoverageViolation("返回的 atomID 序列与主窗口不匹配。")
        }

        var annotations: [AudiobookAnnotation] = []
        annotations.reserveCapacity(primaryItems.count)

        for primaryItem in primaryItems {
            guard let atom = atomsByID[primaryItem.atomID] else {
                throw AudiobookAnalysisError.atomCoverageViolation("未知的 atomID \(primaryItem.atomID)")
            }

            let assignment: AudiobookSpeakerAssignment
            let evidence: String?

            if atom.kind == .heading {
                assignment = .assigned(roleID: narratorID)
                evidence = itemsByAtomID[primaryItem.atomID]?.evidence ?? "章节标题"
            } else if let item = itemsByAtomID[primaryItem.atomID] {
                evidence = item.evidence
                switch item.speakerKind {
                case .narrator:
                    assignment = .assigned(roleID: narratorID)
                case .character:
                    if let roleID = item.roleID, validRoleIDs.contains(roleID) {
                        assignment = .assigned(roleID: roleID)
                    } else {
                        let validCandidates = item.candidateRoleIDs.filter { validRoleIDs.contains($0) }
                        assignment = .unknown(
                            reason: item.evidence ?? "未能确认具体角色",
                            candidateRoleIDs: validCandidates
                        )
                    }
                case .unknown:
                    let validCandidates = item.candidateRoleIDs.filter { validRoleIDs.contains($0) }
                    assignment = .unknown(
                        reason: item.evidence ?? "嵌套引号或多角色对白待确认",
                        candidateRoleIDs: validCandidates
                    )
                }
            } else if !primaryItem.containsDirectDialogue {
                // 纯叙述段默认确定性归属给旁白，保持 100% 原文覆盖且节省大模型对白标注开销
                assignment = .assigned(roleID: narratorID)
                evidence = "纯叙述段默认归属旁白"
            } else {
                // 模型未返回直接对白标注时必须待确认，避免把遗漏静默归入旁白。
                assignment = .unknown(reason: "模型未返回该段直接对白的标注，待确认", candidateRoleIDs: [])
                evidence = nil
            }

            annotations.append(
                AudiobookAnnotation(
                    id: deterministicAnnotationID(windowID: window.id, atomID: atom.id),
                    bookID: window.bookID,
                    chapterID: window.chapterID,
                    windowID: window.id,
                    atomID: atom.id,
                    sourceRange: atom.sourceRange,
                    assignment: assignment,
                    evidence: evidence,
                    userConfirmed: false,
                    annotationRevision: 1
                )
            )
        }

        return annotations
    }

    // MARK: - Short Index & Role Key Resolution Helpers

    private static func buildAtomLookupTable(
        for primaryItems: [AudiobookPromptAtomItem]
    ) -> [String: UUID] {
        var table: [String: UUID] = [:]
        for (offset, item) in primaryItems.enumerated() {
            let uuidKey = item.atomID.uuidString.lowercased()
            table[uuidKey] = item.atomID
            let indexVal = item.localIndex ?? (offset + 1)
            for aliasKey in ["\(indexVal)", "#\(indexVal)", "a\(indexVal)", "p\(indexVal)", "q\(indexVal)", "idx:\(indexVal)"] {
                table[aliasKey] = item.atomID
            }
        }
        return table
    }

    private static func resolveAtomID(
        from rawToken: String,
        lookup: [String: UUID],
        allowedAtomIDs: Set<UUID>
    ) -> UUID? {
        let trimmed = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let uuid = UUID(uuidString: trimmed), allowedAtomIDs.contains(uuid) {
            return uuid
        }
        return lookup[trimmed.lowercased()]
    }

    private static func buildRoleLookupTable(
        characters: [AudiobookCharacter],
        candidateSummaries: [AudiobookPromptCharacterSummary]
    ) -> [String: UUID] {
        var table: [String: UUID] = [:]
        for character in characters {
            table[character.id.uuidString.lowercased()] = character.id
            table[character.displayName.lowercased()] = character.id
            for alias in character.aliases where !alias.isEmpty {
                table[alias.lowercased()] = character.id
            }
        }
        for (offset, summary) in candidateSummaries.enumerated() {
            table[summary.roleID.uuidString.lowercased()] = summary.roleID
            table[summary.canonicalName.lowercased()] = summary.roleID
            let key = (summary.roleKey ?? "R\(offset + 1)").lowercased()
            table[key] = summary.roleID
            table["#\(key)"] = summary.roleID
        }
        return table
    }

    private static func resolveRoleID(
        from rawToken: String,
        lookup: [String: UUID],
        validRoleIDs: Set<UUID>
    ) -> UUID? {
        let trimmed = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let uuid = UUID(uuidString: trimmed), validRoleIDs.contains(uuid) {
            return uuid
        }
        return lookup[trimmed.lowercased()]
    }

    private static func reindexPromptAtomItems(_ items: [AudiobookPromptAtomItem]) -> [AudiobookPromptAtomItem] {
        items.enumerated().map { offset, item in
            var copy = item
            if copy.localIndex != nil {
                copy.localIndex = offset + 1
            }
            return copy
        }
    }

    private static func extractionCacheKey(for window: AudiobookAnalysisWindow) -> String {
        "\(window.id.uuidString)|\(window.policyFingerprint)|\(window.configurationDigest)"
    }

    private static func stripMarkdownCodeFences(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var lines = trimmed.components(separatedBy: .newlines)
        if !lines.isEmpty, lines.first?.hasPrefix("```") == true {
            lines.removeFirst()
        }
        if !lines.isEmpty, lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func validateWindowAnnotationsCoverPrimaryAtoms(
        primaryAtomIDs: [UUID],
        annotations: [AudiobookAnnotation]
    ) -> Bool {
        guard !primaryAtomIDs.isEmpty, annotations.count == primaryAtomIDs.count else {
            return false
        }
        let sortedAnns = annotations.sorted { $0.sourceRange < $1.sourceRange }
        return sortedAnns.map(\.atomID) == primaryAtomIDs
    }

    // MARK: - Private Helpers

    private func checkNotCancelled(
        bookID: UUID,
        expectedGeneration: Int,
        client: any AudiobookAnalysisClient,
        snapshot: AudiobookAnalysisConfigSnapshot
    ) throws {
        if Task.isCancelled || cancelledBookIDs.contains(bookID) {
            throw AudiobookAnalysisError.cancelled
        }
        if activeGenerationsByBook[bookID] != expectedGeneration {
            throw AudiobookAnalysisError.cancelled
        }
        if client.configurationDigest != snapshot.configurationDigest {
            throw AudiobookAnalysisError.configurationChangedDuringRun
        }
    }

    private func makePromptAtomItems(
        ids: [UUID],
        atomsByID: [UUID: AudiobookTextAtom],
        source: AudiobookSourceIndex,
        assignLocalIndices: Bool = false,
        resolvedSpeakerByAtomID: [UUID: String] = [:]
    ) throws -> [AudiobookPromptAtomItem] {
        try ids.enumerated().map { offset, id in
            guard let atom = atomsByID[id] else {
                throw AudiobookSourceError.unknownAtomID(id)
            }
            let text = try source.text(in: atom.sourceRange)
            return AudiobookPromptAtomItem(
                atomID: atom.id,
                kind: atom.kind,
                text: text,
                localIndex: assignLocalIndices ? (offset + 1) : nil,
                resolvedSpeakerName: resolvedSpeakerByAtomID[atom.id]
            )
        }
    }

    private static func selectContextAtoms(
        from chapterAtoms: [AudiobookTextAtom],
        beforeIndex: Int,
        source: AudiobookSourceIndex,
        maxScalars: Int
    ) -> [AudiobookTextAtom] {
        guard beforeIndex > 0, maxScalars > 0 else { return [] }
        var selected: [AudiobookTextAtom] = []
        var scalars = 0
        var index = beforeIndex - 1
        while index >= 0 {
            let atom = chapterAtoms[index]
            let count = (try? source.text(in: atom.sourceRange).unicodeScalars.count) ?? 0
            if scalars + count > maxScalars { break }
            selected.insert(atom, at: 0)
            scalars += count
            index -= 1
        }
        return selected
    }

    private static func selectTrailingContextAtoms(
        from chapterAtoms: [AudiobookTextAtom],
        afterIndex: Int,
        source: AudiobookSourceIndex,
        maxScalars: Int
    ) -> [AudiobookTextAtom] {
        guard afterIndex < chapterAtoms.count, maxScalars > 0 else { return [] }
        var selected: [AudiobookTextAtom] = []
        var scalars = 0
        var index = afterIndex
        while index < chapterAtoms.count {
            let atom = chapterAtoms[index]
            let count = (try? source.text(in: atom.sourceRange).unicodeScalars.count) ?? 0
            if scalars + count > maxScalars { break }
            selected.append(atom)
            scalars += count
            index += 1
        }
        return selected
    }

    private static func deterministicWindowID(
        bookID: UUID,
        chapterID: UUID,
        primaryAtomIDs: [UUID],
        policyFingerprint: String,
        configurationDigest: String
    ) -> UUID {
        let joinedIDs = primaryAtomIDs.map(\.uuidString).joined(separator: ",")
        let seed = "window|\(bookID.uuidString)|\(chapterID.uuidString)|\(joinedIDs)|\(policyFingerprint)|\(configurationDigest)"
        let hex = AudiobookDigest.sha256Hex(Data(seed.utf8))
        return uuidFromHexPrefix(hex)
    }

    private func deterministicAnnotationID(windowID: UUID, atomID: UUID) -> UUID {
        let seed = "ann|\(windowID.uuidString)|\(atomID.uuidString)"
        let hex = AudiobookDigest.sha256Hex(Data(seed.utf8))
        return Self.uuidFromHexPrefix(hex)
    }

    private static func uuidFromHexPrefix(_ hex: String) -> UUID {
        let chars = Array(hex.prefix(32))
        let formatted = String(chars[0..<8]) + "-"
            + String(chars[8..<12]) + "-"
            + String(chars[12..<16]) + "-"
            + String(chars[16..<20]) + "-"
            + String(chars[20..<32])
        return UUID(uuidString: formatted) ?? UUID()
    }

    // MARK: - Secondary Targeted LLM Pass for Unknown Speakers

    public struct SecondaryResolutionResult: Codable, Equatable, Sendable {
        public let initialUnknownCount: Int
        public let resolvedCount: Int
        public let remainingUnknownCount: Int

        public init(
            initialUnknownCount: Int,
            resolvedCount: Int,
            remainingUnknownCount: Int
        ) {
            self.initialUnknownCount = initialUnknownCount
            self.resolvedCount = resolvedCount
            self.remainingUnknownCount = remainingUnknownCount
        }
    }

    /// 对未确认（`unknown`）的说话人段落执行二次定向 LLM 消歧分析：
    /// 利用全书已归并确认的完整角色列表（含别称与声线画像）以及未知段落前后的双向已确认说话人上下文，
    /// 自动消解跨窗口断句或后文揭示身份的对白，并为仍需人工确认的段落收敛候选角色。
    public func resolveUnknownSpeakers(
        bookID: UUID,
        config: AudiobookAnalysisConfigSnapshot
    ) async throws -> SecondaryResolutionResult {
        guard config.isConfigured else {
            throw AudiobookAnalysisError.notConfigured
        }
        let allAnnotations = try await store.annotations(for: bookID)
        let initialUnknowns = allAnnotations.filter { $0.assignment.isUnknown && !$0.userConfirmed }
        guard !initialUnknowns.isEmpty else {
            return SecondaryResolutionResult(initialUnknownCount: 0, resolvedCount: 0, remainingUnknownCount: 0)
        }

        let source = try await store.sourceIndex(for: bookID)
        let chapters = try await store.chapters(for: bookID).sorted { $0.ordinal < $1.ordinal }
        let allAtoms = try await store.atoms(for: bookID)
        let atomsByID = Dictionary(uniqueKeysWithValues: allAtoms.map { ($0.id, $0) })
        let atomsByChapter = Dictionary(grouping: allAtoms, by: \.chapterID)
        let characters = try await store.characters(for: bookID)
        let narratorID = characters.first(where: \.isNarrator)?.id ?? UUID()
        let roleNameByID = Dictionary(uniqueKeysWithValues: characters.map { ($0.id, $0.displayName) })
        let validRoleIDs = Set(characters.map(\.id))

        var annotationsByAtomID = Dictionary(uniqueKeysWithValues: allAnnotations.map { ($0.atomID, $0) })
        var resolvedSpeakerByAtomID: [UUID: String] = [:]
        for ann in allAnnotations {
            if let roleID = ann.assignment.roleID, let name = roleNameByID[roleID] {
                resolvedSpeakerByAtomID[ann.atomID] = name
            }
        }

        let client = try await clientFactory(config)
        var updatedAnnotations: [AudiobookAnnotation] = []
        var newlyResolvedCount = 0

        for chapter in chapters {
            let excludedSet = Set(chapter.excludedRanges)
            let chapterAtoms = (atomsByChapter[chapter.id] ?? [])
                .sorted { $0.ordinal < $1.ordinal }
                .filter { $0.kind != .formatting && !excludedSet.contains($0.sourceRange) }
            guard !chapterAtoms.isEmpty else { continue }

            let unknownIndices = chapterAtoms.indices.filter { idx in
                guard let ann = annotationsByAtomID[chapterAtoms[idx].id] else { return false }
                return ann.assignment.isUnknown && !ann.userConfirmed
            }
            guard !unknownIndices.isEmpty else { continue }

            // 将同章相邻（间距 <= 4 个段落且总跨度 <= 10 个段落）的未知对白聚合成紧凑上下文簇
            var clusters: [(startIdx: Int, endIdx: Int)] = []
            for uIdx in unknownIndices {
                if var last = clusters.popLast() {
                    let spanCount = uIdx - last.startIdx + 1
                    if uIdx - last.endIdx <= 4 && spanCount <= 10 {
                        last.endIdx = uIdx
                        clusters.append(last)
                        continue
                    }
                    clusters.append(last)
                }
                clusters.append((startIdx: uIdx, endIdx: uIdx))
            }

            for cluster in clusters {
                let primarySlice = Array(chapterAtoms[cluster.startIdx...cluster.endIdx])
                let primaryScalars = primarySlice.reduce(0) {
                    $0 + ((try? source.text(in: $1.sourceRange).unicodeScalars.count) ?? 0)
                }
                guard primaryScalars <= policy.maxPrimaryScalars,
                      primarySlice.count <= policy.maxPrimaryAtoms
                else {
                    continue
                }

                let leadingSlice = Self.selectContextAtoms(
                    from: chapterAtoms,
                    beforeIndex: cluster.startIdx,
                    source: source,
                    maxScalars: policy.maxContextScalarsPerSide
                )
                let trailingSlice = Self.selectTrailingContextAtoms(
                    from: chapterAtoms,
                    afterIndex: cluster.endIdx + 1,
                    source: source,
                    maxScalars: policy.maxContextScalarsPerSide
                )

                let primaryItems = try makePromptAtomItems(
                    ids: primarySlice.map(\.id),
                    atomsByID: atomsByID,
                    source: source,
                    assignLocalIndices: true,
                    resolvedSpeakerByAtomID: resolvedSpeakerByAtomID
                )
                let leadingItems = try makePromptAtomItems(
                    ids: leadingSlice.map(\.id),
                    atomsByID: atomsByID,
                    source: source,
                    resolvedSpeakerByAtomID: resolvedSpeakerByAtomID
                )
                let trailingItems = try makePromptAtomItems(
                    ids: trailingSlice.map(\.id),
                    atomsByID: atomsByID,
                    source: source,
                    resolvedSpeakerByAtomID: resolvedSpeakerByAtomID
                )

                let combinedText = (leadingItems + primaryItems + trailingItems).map(\.text).joined(separator: "\n")
                let candidateSummaries = AudiobookCastRegistry.selectCandidateSummariesForWindow(
                    characters: characters,
                    chapterID: chapter.id,
                    windowText: combinedText,
                    policy: policy
                )
                let safeCandidates = AudiobookCastRegistry.clampSummariesToBudget(
                    candidateSummaries,
                    maxScalars: policy.maxCharacterSummaryScalars,
                    maxCandidates: policy.maxMergeCandidatesPerBatch
                )

                guard let prompt = try? AudiobookAnalysisPrompts.makeSecondaryUnknownResolutionPrompt(
                    rootWindowID: UUID(),
                    primaryAtoms: primaryItems,
                    leadingContext: leadingItems,
                    trailingContext: trailingItems,
                    candidateCharacters: safeCandidates,
                    policy: policy
                ),
                      let raw = try? await client.complete(prompt)
                else {
                    continue
                }

                let cleaned = Self.stripMarkdownCodeFences(raw)
                guard let data = cleaned.data(using: .utf8),
                      let response = try? JSONDecoder().decode(AudiobookAnnotationResponse.self, from: data)
                else {
                    continue
                }

                let expectedIDSet = Set(primaryItems.map(\.atomID))
                let atomIDByRef = Self.buildAtomLookupTable(for: primaryItems)
                let roleIDByRef = Self.buildRoleLookupTable(
                    characters: characters,
                    candidateSummaries: safeCandidates
                )

                for item in response.items {
                    let rawToken = item.atomRef ?? item.atomID.uuidString
                    guard let resolvedAtomID = Self.resolveAtomID(
                        from: rawToken,
                        lookup: atomIDByRef,
                        allowedAtomIDs: expectedIDSet
                    ),
                          var existingAnn = annotationsByAtomID[resolvedAtomID],
                          existingAnn.assignment.isUnknown,
                          !existingAnn.userConfirmed
                    else {
                        continue
                    }

                    let resolvedRole: UUID? = {
                        if let direct = item.roleID, validRoleIDs.contains(direct) {
                            return direct
                        }
                        if let rawRole = item.roleRef {
                            return Self.resolveRoleID(from: rawRole, lookup: roleIDByRef, validRoleIDs: validRoleIDs)
                        }
                        return nil
                    }()
                    let resolvedCandidates: [UUID] = {
                        let mapped = item.candidateRoleRefs.compactMap {
                            Self.resolveRoleID(from: $0, lookup: roleIDByRef, validRoleIDs: validRoleIDs)
                        }
                        let base = mapped.isEmpty ? item.candidateRoleIDs.filter { validRoleIDs.contains($0) } : mapped
                        return Array(NSOrderedSet(array: base)) as? [UUID] ?? base
                    }()

                    switch item.speakerKind {
                    case .narrator:
                        guard item.confidence >= 0.65 else { continue }
                        existingAnn.assignment = .assigned(roleID: narratorID)
                        if let ev = item.evidence, !ev.isEmpty {
                            existingAnn.evidence = ev
                        }
                        existingAnn.annotationRevision += 1
                        annotationsByAtomID[resolvedAtomID] = existingAnn
                        resolvedSpeakerByAtomID[resolvedAtomID] = roleNameByID[narratorID]
                        updatedAnnotations.append(existingAnn)
                        newlyResolvedCount += 1

                    case .character:
                        if let roleID = resolvedRole, item.confidence >= 0.60 {
                            existingAnn.assignment = .assigned(roleID: roleID)
                            if let ev = item.evidence, !ev.isEmpty {
                                existingAnn.evidence = ev
                            }
                            existingAnn.annotationRevision += 1
                            annotationsByAtomID[resolvedAtomID] = existingAnn
                            resolvedSpeakerByAtomID[resolvedAtomID] = roleNameByID[roleID]
                            updatedAnnotations.append(existingAnn)
                            newlyResolvedCount += 1
                        } else if !resolvedCandidates.isEmpty {
                            existingAnn.assignment = .unknown(
                                reason: item.evidence ?? existingAnn.evidence ?? "二次分析建议人工从候选角色中确认",
                                candidateRoleIDs: resolvedCandidates
                            )
                            if let ev = item.evidence, !ev.isEmpty {
                                existingAnn.evidence = ev
                            }
                            existingAnn.annotationRevision += 1
                            annotationsByAtomID[resolvedAtomID] = existingAnn
                            updatedAnnotations.append(existingAnn)
                        }

                    case .unknown:
                        if !resolvedCandidates.isEmpty || item.evidence != nil {
                            let existingCandidates: [UUID] = {
                                if case let .unknown(_, cands) = existingAnn.assignment { return cands }
                                return []
                            }()
                            existingAnn.assignment = .unknown(
                                reason: item.evidence ?? existingAnn.evidence ?? "多角色对话需人工确认",
                                candidateRoleIDs: resolvedCandidates.isEmpty ? existingCandidates : resolvedCandidates
                            )
                            if let ev = item.evidence, !ev.isEmpty {
                                existingAnn.evidence = ev
                            }
                            existingAnn.annotationRevision += 1
                            annotationsByAtomID[resolvedAtomID] = existingAnn
                            updatedAnnotations.append(existingAnn)
                        }
                    }
                }
            }
        }

        if !updatedAnnotations.isEmpty {
            try await store.saveAnnotations(bookID: bookID, annotations: updatedAnnotations)
            let refreshedAnnotations = try await store.annotations(for: bookID)
            let refreshedCharacters = AudiobookCastRegistry.refreshCharacterMajorStatusAndOrder(
                characters: characters,
                annotations: refreshedAnnotations
            )
            try await store.saveCharacters(bookID: bookID, characters: refreshedCharacters)
        }

        let remainingCount = max(0, initialUnknowns.count - newlyResolvedCount)
        return SecondaryResolutionResult(
            initialUnknownCount: initialUnknowns.count,
            resolvedCount: newlyResolvedCount,
            remainingUnknownCount: remainingCount
        )
    }
}
