import Foundation

/// T09：候选采用、一键撤销、不可变章节版本投影与重启恢复计划。
public struct AudiobookResumePlan: Codable, Equatable, Sendable {
    public var bookID: UUID
    public var reusableFragmentIDs: [UUID]
    public var redoFragmentIDs: [UUID]
    public var damagedCandidateIDs: [UUID]
    public var readyChapterIDs: [UUID]
    public var incompleteChapterIDs: [UUID]

    public init(
        bookID: UUID,
        reusableFragmentIDs: [UUID],
        redoFragmentIDs: [UUID],
        damagedCandidateIDs: [UUID] = [],
        readyChapterIDs: [UUID] = [],
        incompleteChapterIDs: [UUID] = []
    ) {
        self.bookID = bookID
        self.reusableFragmentIDs = reusableFragmentIDs
        self.redoFragmentIDs = redoFragmentIDs
        self.damagedCandidateIDs = damagedCandidateIDs
        self.readyChapterIDs = readyChapterIDs
        self.incompleteChapterIDs = incompleteChapterIDs
    }
}

public enum AudiobookRevisionError: LocalizedError, Equatable, Sendable {
    case candidateNotFound(UUID)
    case fragmentNotFound(UUID)
    case staleCandidateDependency(candidateID: UUID)
    case unverifiedCandidateProvenance(candidateID: UUID)
    case expectedRevisionMismatch(expected: UUID, actual: UUID?)
    case incompleteChapterCoverage(chapterID: UUID, missingFragmentIDs: [UUID])
    case noPreviousChapterRevisionToUndo(chapterID: UUID)

    public var errorDescription: String? {
        switch self {
        case .candidateNotFound:
            return "找不到指定的重制候选音频。"
        case .fragmentNotFound:
            return "找不到对应的章节片段。"
        case .staleCandidateDependency:
            return "该候选音频对应的说话人或音色已变更，无法直接采用到当前版本。"
        case .unverifiedCandidateProvenance:
            return "该候选音频的回执或摘要尚未通过核验，不能作为正式章节版本。"
        case .expectedRevisionMismatch:
            return "当前章节版本已变更，请刷新后重试采用。"
        case .incompleteChapterCoverage:
            return "当前章节仍有缺失或待更新的片段，暂不能发布为完整章节版本。"
        case .noPreviousChapterRevisionToUndo:
            return "当前章节没有可回退的上一版本。"
        }
    }
}

public actor AudiobookRevisionController {
    private let store: AudiobookProjectStore
    private let policy: AudiobookRenderPolicy

    public init(
        store: AudiobookProjectStore,
        policy: AudiobookRenderPolicy = .standard
    ) {
        self.store = store
        self.policy = policy
    }

    /// 首次制作完成某章全部片段且尚无历史版本时，自动组装并发布初始章节版本。
    public func promoteInitialChapterIfComplete(
        bookID: UUID,
        chapterID: UUID
    ) async throws -> AudiobookChapterRevision? {
        let chapters = try await store.chapters(for: bookID)
        guard let chapter = chapters.first(where: { $0.id == chapterID }) else {
            throw AudiobookStoreError.chapterNotFound(chapterID)
        }
        let fragments = try await currentPlannedFragments(bookID: bookID, chapter: chapter)
        let candidates = try await store.candidates(for: bookID)

        var orderedBindings: [AudiobookFragmentCandidateBinding] = []
        var totalFrames: Int64 = 0

        for fragment in fragments {
            guard let matching = candidates
                .filter({
                    $0.fragmentID == fragment.id
                        && $0.dependencyDigest == fragment.dependencyDigest
                        && $0.isReceiptVerified
                })
                .sorted(by: { $0.createdAt > $1.createdAt })
                .first,
                  try await store.verifyCandidateAsset(matching)
            else {
                return nil
            }
            orderedBindings.append(
                AudiobookFragmentCandidateBinding(
                    fragmentID: fragment.id,
                    candidateID: matching.id,
                    sourceRange: fragment.sourceRange,
                    dependencyDigest: fragment.dependencyDigest
                )
            )
            totalFrames += matching.frameCount
        }

        let existingRevs = try await store.chapterRevisions(for: bookID, chapterID: chapterID)
        let nextRevNumber = (existingRevs.map(\.revisionNumber).max() ?? 0) + 1
        let revision = AudiobookChapterRevision(
            bookID: bookID,
            chapterID: chapterID,
            sourceID: chapter.sourceID,
            revisionNumber: nextRevNumber,
            orderedBindings: orderedBindings,
            totalFrameCount: totalFrames,
            sampleRate: policy.sampleRate
        )
        try await store.saveChapterRevision(revision, makeCurrent: true)
        try await refreshBookProductionRevisionIfApplicable(bookID: bookID)
        return revision
    }

    /// 显式采用某个返修候选：校验 expectedRevisionID 与当前 dependencyDigest，幂等防重复。
    public func adopt(
        bookID: UUID,
        candidateID: UUID,
        expectedRevisionID: UUID
    ) async throws {
        let chapters = try await store.chapters(for: bookID)
        let candidates = try await store.candidates(for: bookID)
        guard let targetCandidate = candidates.first(where: { $0.id == candidateID }) else {
            throw AudiobookRevisionError.candidateNotFound(candidateID)
        }
        guard targetCandidate.isReceiptVerified,
              try await store.verifyCandidateAsset(targetCandidate)
        else {
            throw AudiobookRevisionError.unverifiedCandidateProvenance(candidateID: candidateID)
        }
        guard let chapter = chapters.first(where: { $0.id == targetCandidate.chapterID }) else {
            throw AudiobookStoreError.chapterNotFound(targetCandidate.chapterID)
        }

        let existingRevisions = try await store.chapterRevisions(for: bookID, chapterID: chapter.id)
        if let currentID = chapter.currentChapterRevisionID,
           let currentRev = existingRevisions.first(where: { $0.id == currentID }),
           currentRev.orderedBindings.contains(where: { $0.candidateID == candidateID })
        {
            // 幂等重入：该 candidate 已经是当前章节版本的采用项，不重复创建新版本
            return
        }

        guard chapter.currentChapterRevisionID == expectedRevisionID else {
            throw AudiobookRevisionError.expectedRevisionMismatch(
                expected: expectedRevisionID,
                actual: chapter.currentChapterRevisionID
            )
        }

        let currentFragments = try await currentPlannedFragments(bookID: bookID, chapter: chapter)
        guard let targetFragment = currentFragments.first(where: { $0.id == targetCandidate.fragmentID }) else {
            throw AudiobookRevisionError.fragmentNotFound(targetCandidate.fragmentID)
        }
        guard targetCandidate.dependencyDigest == targetFragment.dependencyDigest else {
            throw AudiobookRevisionError.staleCandidateDependency(candidateID: candidateID)
        }

        let currentRev = existingRevisions.first(where: { $0.id == expectedRevisionID })
        let previousBindingsByFragment = Dictionary(
            uniqueKeysWithValues: (currentRev?.orderedBindings ?? []).map { ($0.fragmentID, $0) }
        )

        var newBindings: [AudiobookFragmentCandidateBinding] = []
        var totalFrames: Int64 = 0
        var missingFragments: [UUID] = []

        for fragment in currentFragments {
            let chosenCandidate: AudiobookRenderCandidate?
            if fragment.id == targetFragment.id {
                chosenCandidate = targetCandidate
            } else if let prevBinding = previousBindingsByFragment[fragment.id],
                      prevBinding.dependencyDigest == fragment.dependencyDigest,
                      let prevCandidate = candidates.first(where: { $0.id == prevBinding.candidateID }),
                      prevCandidate.isReceiptVerified,
                      (try? await store.verifyCandidateAsset(prevCandidate)) == true
            {
                chosenCandidate = prevCandidate
            } else {
                chosenCandidate = candidates
                    .filter {
                        $0.fragmentID == fragment.id
                            && $0.dependencyDigest == fragment.dependencyDigest
                            && $0.isReceiptVerified
                    }
                    .sorted { $0.createdAt > $1.createdAt }
                    .first
            }

            guard let validCandidate = chosenCandidate,
                  (try? await store.verifyCandidateAsset(validCandidate)) == true
            else {
                missingFragments.append(fragment.id)
                continue
            }

            newBindings.append(
                AudiobookFragmentCandidateBinding(
                    fragmentID: fragment.id,
                    candidateID: validCandidate.id,
                    sourceRange: fragment.sourceRange,
                    dependencyDigest: fragment.dependencyDigest
                )
            )
            totalFrames += validCandidate.frameCount
        }

        guard missingFragments.isEmpty else {
            throw AudiobookRevisionError.incompleteChapterCoverage(
                chapterID: chapter.id,
                missingFragmentIDs: missingFragments
            )
        }

        let nextNumber = (existingRevisions.map(\.revisionNumber).max() ?? 0) + 1
        let newRevision = AudiobookChapterRevision(
            bookID: bookID,
            chapterID: chapter.id,
            sourceID: chapter.sourceID,
            revisionNumber: nextNumber,
            orderedBindings: newBindings,
            totalFrameCount: totalFrames,
            sampleRate: policy.sampleRate
        )
        try await store.saveChapterRevision(newRevision, makeCurrent: true)
        try await refreshBookProductionRevisionIfApplicable(bookID: bookID)
    }

    public func undoAdoption(
        bookID: UUID,
        chapterID: UUID
    ) async throws {
        var chapters = try await store.chapters(for: bookID)
        guard let index = chapters.firstIndex(where: { $0.id == chapterID }) else {
            throw AudiobookStoreError.chapterNotFound(chapterID)
        }
        let chapter = chapters[index]
        guard let previousID = chapter.previousChapterRevisionID else {
            throw AudiobookRevisionError.noPreviousChapterRevisionToUndo(chapterID: chapterID)
        }
        let revisions = try await store.chapterRevisions(for: bookID, chapterID: chapterID)
        guard let previousRev = revisions.first(where: { $0.id == previousID }) else {
            throw AudiobookRevisionError.noPreviousChapterRevisionToUndo(chapterID: chapterID)
        }

        var updatedChapter = chapter
        updatedChapter.currentChapterRevisionID = previousRev.id
        updatedChapter.previousChapterRevisionID = nil
        chapters[index] = updatedChapter
        try await store.saveChapterRevision(previousRev, makeCurrent: true)
        try await refreshBookProductionRevisionIfApplicable(bookID: bookID)
    }

    /// 返回当前语义依然有效的章节版本；若某章已发生说话人/声音变更导致当前版本失效，返回 nil（历史版本通过 `previousListenableChapter` 读取并显示“之前的版本”）。
    public func currentChapter(
        bookID: UUID,
        chapterID: UUID
    ) async throws -> AudiobookChapterRevision? {
        let chapters = try await store.chapters(for: bookID)
        guard let chapter = chapters.first(where: { $0.id == chapterID }),
              let currentRevID = chapter.currentChapterRevisionID
        else {
            return nil
        }
        let revisions = try await store.chapterRevisions(for: bookID, chapterID: chapterID)
        guard let revision = revisions.first(where: { $0.id == currentRevID }) else {
            return nil
        }

        guard let plannedFragments = try? await currentPlannedFragments(bookID: bookID, chapter: chapter) else {
            return nil
        }
        guard revision.orderedBindings.count == plannedFragments.count else {
            return nil
        }

        let candidates = try await store.candidates(for: bookID)
        let candidatesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })

        for (binding, planned) in zip(revision.orderedBindings, plannedFragments) {
            guard binding.sourceRange == planned.sourceRange,
                  binding.dependencyDigest == planned.dependencyDigest,
                  let candidate = candidatesByID[binding.candidateID],
                  candidate.isReceiptVerified,
                  (try? await store.verifyCandidateAsset(candidate)) == true
            else {
                return nil
            }
        }
        return revision
    }

    /// 当章节因返修待更新时，返回最新一份完整可听的历史章节版本（界面标记“之前的版本”）。
    public func previousListenableChapter(
        bookID: UUID,
        chapterID: UUID
    ) async throws -> AudiobookChapterRevision? {
        let revisions = try await store.chapterRevisions(for: bookID, chapterID: chapterID)
            .sorted { $0.revisionNumber > $1.revisionNumber }
        let candidates = try await store.candidates(for: bookID)
        let candidatesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })

        for rev in revisions {
            var allAssetsValid = true
            for binding in rev.orderedBindings {
                guard let candidate = candidatesByID[binding.candidateID],
                      candidate.isReceiptVerified,
                      (try? await store.verifyCandidateAsset(candidate)) == true
                else {
                    allAssetsValid = false
                    break
                }
            }
            if allAssetsValid {
                return rev
            }
        }
        return nil
    }

    public func resumePlan(bookID: UUID) async throws -> AudiobookResumePlan {
        let recovery = try await store.recover()
        let chapters = try await store.chapters(for: bookID).sorted { $0.ordinal < $1.ordinal }
        let candidates = try await store.candidates(for: bookID)

        var reusableIDs: [UUID] = []
        var redoIDs: [UUID] = []
        var readyChapterIDs: [UUID] = []
        var incompleteChapterIDs: [UUID] = []

        for chapter in chapters {
            guard let plannedFragments = try? await currentPlannedFragments(bookID: bookID, chapter: chapter) else {
                incompleteChapterIDs.append(chapter.id)
                continue
            }

            var chapterAllReusable = true
            for fragment in plannedFragments {
                try await store.saveFragments(bookID: bookID, chapterID: chapter.id, fragments: plannedFragments)
                if let validCandidate = candidates.first(where: {
                    $0.fragmentID == fragment.id
                        && $0.dependencyDigest == fragment.dependencyDigest
                        && $0.isReceiptVerified
                        && !recovery.damagedCandidateIDs.contains($0.id)
                }),
                   (try? await store.verifyCandidateAsset(validCandidate)) == true
                {
                    reusableIDs.append(fragment.id)
                } else {
                    redoIDs.append(fragment.id)
                    chapterAllReusable = false
                }
            }

            if chapterAllReusable,
               (try? await currentChapter(bookID: bookID, chapterID: chapter.id)) != nil
            {
                readyChapterIDs.append(chapter.id)
            } else {
                incompleteChapterIDs.append(chapter.id)
            }
        }

        return AudiobookResumePlan(
            bookID: bookID,
            reusableFragmentIDs: reusableIDs,
            redoFragmentIDs: redoIDs,
            damagedCandidateIDs: recovery.damagedCandidateIDs,
            readyChapterIDs: readyChapterIDs,
            incompleteChapterIDs: incompleteChapterIDs
        )
    }

    // MARK: - Helpers

    private func currentPlannedFragments(
        bookID: UUID,
        chapter: AudiobookChapter
    ) async throws -> [AudiobookFragment] {
        let source = try await store.sourceIndex(for: bookID)
        let annotations = try await store.annotations(for: bookID, chapterID: chapter.id)
        let bindings = try await store.voiceBindings(for: bookID)
        let atoms = try await store.atoms(for: bookID, chapterID: chapter.id)
        let planned = try AudiobookFragmentPlanner.plan(
            chapter: chapter,
            annotations: annotations,
            bindings: bindings,
            policy: policy,
            source: source,
            atoms: atoms
        )
        try await store.saveFragments(bookID: bookID, chapterID: chapter.id, fragments: planned)
        return planned
    }

    private func refreshBookProductionRevisionIfApplicable(bookID: UUID) async throws {
        let chapters = try await store.chapters(for: bookID).sorted { $0.ordinal < $1.ordinal }
        guard !chapters.isEmpty else { return }

        var currentMap: [UUID: UUID] = [:]
        for chapter in chapters {
            if let validRev = try await currentChapter(bookID: bookID, chapterID: chapter.id) {
                currentMap[chapter.id] = validRev.id
            }
        }

        var book = try await store.book(id: bookID)
        if currentMap.count == chapters.count {
            let prodRev = AudiobookProductionRevision(
                bookID: bookID,
                sourceID: book.sourceID,
                chapterRevisionIDsByChapter: currentMap
            )
            try await store.saveProductionRevision(prodRev, makeCurrent: true)
            book = try await store.book(id: bookID)
            book.productionState = .fullBookProduced
            book.listenableState = .fullBookListenable
            try await store.updateBook(book)
        } else if !currentMap.isEmpty {
            book.currentProductionRevisionID = nil
            book.productionState = .partialChaptersReady
            book.listenableState = .partialChaptersListenable
            try await store.updateBook(book)
        } else {
            book.currentProductionRevisionID = nil
            var hasPrevious = false
            for chapter in chapters {
                if (try? await previousListenableChapter(bookID: bookID, chapterID: chapter.id)) != nil {
                    hasPrevious = true
                    break
                }
            }
            book.listenableState = hasPrevious ? .previousRevisionAvailable : .noneAvailable
            try await store.updateBook(book)
        }
    }
}
