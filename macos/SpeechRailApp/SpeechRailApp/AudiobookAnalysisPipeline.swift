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
    private var cancelledBookIDs: Set<UUID> = []
    private var activeGenerationsByBook: [UUID: Int] = [:]

    public init(
        store: AudiobookProjectStore,
        policy: AudiobookAnalysisPolicy = .standard,
        clientFactory: @escaping ClientFactory
    ) {
        self.store = store
        self.policy = policy
        self.clientFactory = clientFactory
    }

    public func cancel(bookID: UUID) {
        cancelledBookIDs.insert(bookID)
        activeGenerationsByBook[bookID, default: 1] += 1
    }

    public func run(
        bookID: UUID,
        config: AudiobookAnalysisConfigSnapshot
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
                } else {
                    windowsNeedingWork.append(planned)
                    try await store.saveAnalysisWindow(planned)
                }
            }

            for window in windowsNeedingWork {
                try checkNotCancelled(bookID: bookID, expectedGeneration: runGeneration, client: client, snapshot: frozenSnapshot)
                let primaryItems = try makePromptAtomItems(ids: window.primaryAtomIDs, atomsByID: atomsByID, source: source)
                let leadingItems = try makePromptAtomItems(ids: window.leadingContextAtomIDs, atomsByID: atomsByID, source: source)
                let trailingItems = try makePromptAtomItems(ids: window.trailingContextAtomIDs, atomsByID: atomsByID, source: source)

                let mentions = try await executeExtractionWithSplitFallback(
                    rootWindowID: window.rootWindowID,
                    primaryItems: primaryItems,
                    leadingItems: leadingItems,
                    trailingItems: trailingItems,
                    client: client,
                    snapshot: frozenSnapshot,
                    bookID: bookID,
                    runGeneration: runGeneration,
                    callCounters: &extractionCallCounters
                )
                extractedMentions.append(contentsOf: mentions)
            }

            // Phase 2: Bounded cast consolidation (32 candidates per batch)
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
                batchSize: policy.maxMergeCandidatesPerBatch
            )
            for batch in mentionBatches {
                try checkNotCancelled(bookID: bookID, expectedGeneration: runGeneration, client: client, snapshot: frozenSnapshot)
                let existingSummaries = AudiobookCastRegistry.selectCandidateSummariesForWindow(
                    characters: characters,
                    chapterID: chapters.first?.id ?? UUID(),
                    windowText: batch.map(\.surfaceName).joined(separator: " "),
                    policy: policy
                )
                let mergeRootID = UUID()
                let mergePrompt = try AudiobookAnalysisPrompts.makeMergePrompt(
                    rootWindowID: mergeRootID,
                    candidates: batch,
                    existingCharacters: existingSummaries,
                    policy: policy
                )
                let rawMerge = try await client.complete(mergePrompt)
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
            }
            try await store.saveCharacters(bookID: bookID, characters: characters)

            let narratorID = characters.first(where: \.isNarrator)?.id ?? UUID()

            // Phase 3: Per-window speaker annotation with strict primary atom coverage and checkpoint commit
            for var window in windowsNeedingWork {
                try checkNotCancelled(bookID: bookID, expectedGeneration: runGeneration, client: client, snapshot: frozenSnapshot)
                let primaryItems = try makePromptAtomItems(ids: window.primaryAtomIDs, atomsByID: atomsByID, source: source)
                let leadingItems = try makePromptAtomItems(ids: window.leadingContextAtomIDs, atomsByID: atomsByID, source: source)
                let trailingItems = try makePromptAtomItems(ids: window.trailingContextAtomIDs, atomsByID: atomsByID, source: source)
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
                    atomsByID: atomsByID,
                    client: client,
                    snapshot: frozenSnapshot,
                    bookID: bookID,
                    runGeneration: runGeneration,
                    callCounters: &annotationCallCounters
                )

                guard Self.validateWindowAnnotationsCoverPrimaryAtoms(
                    primaryAtomIDs: window.primaryAtomIDs,
                    annotations: annotations
                ) else {
                    book.analysisState = .failed
                    try await store.updateBook(book)
                    throw AudiobookAnalysisError.atomCoverageViolation("窗口 \(window.id) 标注未完整覆盖 primary atoms。")
                }

                window.isCompleted = true
                try checkNotCancelled(bookID: bookID, expectedGeneration: runGeneration, client: client, snapshot: frozenSnapshot)
                try await store.saveAnnotations(bookID: bookID, annotations: annotations)
                try await store.saveAnalysisWindow(window)
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
        callCounters: inout [UUID: Int]
    ) async throws -> [AudiobookExtractionResponse.Mention] {
        try checkNotCancelled(bookID: bookID, expectedGeneration: runGeneration, client: client, snapshot: snapshot)
        let usedCalls = callCounters[rootWindowID, default: 0]
        guard usedCalls < policy.maxCallsPerRootWindow else {
            throw AudiobookAnalysisError.rootCallBudgetExhausted(rootWindowID: rootWindowID)
        }
        callCounters[rootWindowID] = usedCalls + 1

        let prompt = try AudiobookAnalysisPrompts.makeExtractionPrompt(
            rootWindowID: rootWindowID,
            primaryAtoms: primaryItems,
            leadingContext: leadingItems,
            trailingContext: trailingItems,
            policy: policy
        )

        do {
            let raw = try await client.complete(prompt)
            try checkNotCancelled(bookID: bookID, expectedGeneration: runGeneration, client: client, snapshot: snapshot)
            let response = try decodeExtractionResponse(from: raw, allowedAtomIDs: Set(primaryItems.map(\.atomID)))
            return response.mentions
        } catch let error as AudiobookAnalysisError {
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
                callCounters: &callCounters
            )
        } catch {
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
                callCounters: &callCounters
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
        callCounters: inout [UUID: Int]
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
        let mid = primaryItems.count / 2
        let left = Array(primaryItems[..<mid])
        let right = Array(primaryItems[mid...])
        let leftMentions = try await executeExtractionWithSplitFallback(
            rootWindowID: rootWindowID,
            primaryItems: left,
            leadingItems: leadingItems,
            trailingItems: Array(right.prefix(2)),
            client: client,
            snapshot: snapshot,
            bookID: bookID,
            runGeneration: runGeneration,
            callCounters: &callCounters
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
            callCounters: &callCounters
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
        atomsByID: [UUID: AudiobookTextAtom],
        client: any AudiobookAnalysisClient,
        snapshot: AudiobookAnalysisConfigSnapshot,
        bookID: UUID,
        runGeneration: Int,
        callCounters: inout [UUID: Int]
    ) async throws -> [AudiobookAnnotation] {
        try checkNotCancelled(bookID: bookID, expectedGeneration: runGeneration, client: client, snapshot: snapshot)
        let usedCalls = callCounters[window.rootWindowID, default: 0]
        guard usedCalls < policy.maxCallsPerRootWindow else {
            throw AudiobookAnalysisError.rootCallBudgetExhausted(rootWindowID: window.rootWindowID)
        }
        callCounters[window.rootWindowID] = usedCalls + 1

        let prompt = try AudiobookAnalysisPrompts.makeAnnotationPrompt(
            rootWindowID: window.rootWindowID,
            primaryAtoms: primaryItems,
            leadingContext: leadingItems,
            trailingContext: trailingItems,
            candidateCharacters: candidateSummaries,
            policy: policy
        )

        do {
            let raw = try await client.complete(prompt)
            try checkNotCancelled(bookID: bookID, expectedGeneration: runGeneration, client: client, snapshot: snapshot)
            return try decodeAndValidateAnnotations(
                from: raw,
                window: window,
                primaryItems: primaryItems,
                characters: characters,
                narratorID: narratorID,
                atomsByID: atomsByID
            )
        } catch let error as AudiobookAnalysisError {
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
                atomsByID: atomsByID,
                client: client,
                snapshot: snapshot,
                bookID: bookID,
                runGeneration: runGeneration,
                callCounters: &callCounters
            )
        } catch {
            return try await splitOrFailAnnotation(
                error: error,
                window: window,
                primaryItems: primaryItems,
                leadingItems: leadingItems,
                trailingItems: trailingItems,
                candidateSummaries: candidateSummaries,
                characters: characters,
                narratorID: narratorID,
                atomsByID: atomsByID,
                client: client,
                snapshot: snapshot,
                bookID: bookID,
                runGeneration: runGeneration,
                callCounters: &callCounters
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
        atomsByID: [UUID: AudiobookTextAtom],
        client: any AudiobookAnalysisClient,
        snapshot: AudiobookAnalysisConfigSnapshot,
        bookID: UUID,
        runGeneration: Int,
        callCounters: inout [UUID: Int]
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
        let mid = primaryItems.count / 2
        let left = Array(primaryItems[..<mid])
        let right = Array(primaryItems[mid...])
        let leftAnns = try await executeAnnotationWithSplitFallback(
            window: window,
            primaryItems: left,
            leadingItems: leadingItems,
            trailingItems: Array(right.prefix(2)),
            candidateSummaries: candidateSummaries,
            characters: characters,
            narratorID: narratorID,
            atomsByID: atomsByID,
            client: client,
            snapshot: snapshot,
            bookID: bookID,
            runGeneration: runGeneration,
            callCounters: &callCounters
        )
        let rightAnns = try await executeAnnotationWithSplitFallback(
            window: window,
            primaryItems: right,
            leadingItems: Array(left.suffix(2)),
            trailingItems: trailingItems,
            candidateSummaries: candidateSummaries,
            characters: characters,
            narratorID: narratorID,
            atomsByID: atomsByID,
            client: client,
            snapshot: snapshot,
            bookID: bookID,
            runGeneration: runGeneration,
            callCounters: &callCounters
        )
        return leftAnns + rightAnns
    }

    private func decodeExtractionResponse(
        from raw: String,
        allowedAtomIDs: Set<UUID>
    ) throws -> AudiobookExtractionResponse {
        let cleaned = Self.stripMarkdownCodeFences(raw)
        guard let data = cleaned.data(using: .utf8),
              var decoded = try? JSONDecoder().decode(AudiobookExtractionResponse.self, from: data)
        else {
            throw AudiobookAnalysisError.invalidStructuredOutput("人物提取 JSON 解码失败。")
        }
        // 过滤掉模型误引用的上下文 atomID，保留合法的当前主窗口 atomID
        decoded.mentions = decoded.mentions.map { mention in
            var copy = mention
            copy.evidenceAtomIDs = mention.evidenceAtomIDs.filter { allowedAtomIDs.contains($0) }
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
        var itemsByAtomID: [UUID: AudiobookAnnotationResponse.Item] = [:]
        for item in response.items where expectedIDSet.contains(item.atomID) {
            if itemsByAtomID[item.atomID] == nil {
                itemsByAtomID[item.atomID] = item
            }
        }
        guard !itemsByAtomID.isEmpty || primaryItems.isEmpty else {
            throw AudiobookAnalysisError.atomCoverageViolation("返回的 atomID 序列与主窗口不匹配。")
        }

        let validRoleIDs = Set(characters.map(\.id))
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
            } else if !Self.containsDirectDialogueQuote(in: primaryItem.text) {
                // 纯叙述段若被模型省略，确定性归属给旁白，保持 100% 原文覆盖
                assignment = .assigned(roleID: narratorID)
                evidence = "纯叙述段默认归属旁白"
            } else {
                throw AudiobookAnalysisError.atomCoverageViolation(
                    "返回的 atomID 序列遗漏了对白段落 \(primaryItem.atomID)。"
                )
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

    private static func containsDirectDialogueQuote(in text: String) -> Bool {
        let quoteScalars: Set<UnicodeScalar> = ["“", "”", "「", "」", "『", "』", "\""]
        return text.unicodeScalars.contains { quoteScalars.contains($0) }
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
        source: AudiobookSourceIndex
    ) throws -> [AudiobookPromptAtomItem] {
        try ids.map { id in
            guard let atom = atomsByID[id] else {
                throw AudiobookSourceError.unknownAtomID(id)
            }
            let text = try source.text(in: atom.sourceRange)
            return AudiobookPromptAtomItem(atomID: atom.id, kind: atom.kind, text: text)
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
}
