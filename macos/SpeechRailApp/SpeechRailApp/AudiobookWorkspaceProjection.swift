import Foundation
import SpeechRailControlKit

struct AudiobookRoleStatsWork: Equatable, Sendable {
    var annotationVisits = 0
    var edgeVisits = 0
    var rangeVisits = 0
}

struct AudiobookChapterDetailsSnapshot: Sendable {
    let chapterID: UUID?
    let atoms: [AudiobookTextAtom]
    let annotations: [AudiobookAnnotation]
    let fragments: [AudiobookFragment]
    let candidates: [AudiobookRenderCandidate]
    let atomTextsByID: [UUID: String]
    let fragmentTextsByID: [UUID: String]
    let selectedFragmentID: UUID?
    let revision: AudiobookWorkspaceRevision?

    static let empty = AudiobookChapterDetailsSnapshot(
        chapterID: nil,
        atoms: [],
        annotations: [],
        fragments: [],
        candidates: [],
        atomTextsByID: [:],
        fragmentTextsByID: [:],
        selectedFragmentID: nil,
        revision: nil
    )
}

struct AudiobookBookWorkspaceSnapshot: Sendable {
    let book: AudiobookBook
    let chapters: [AudiobookChapter]
    let characters: [AudiobookCharacter]
    let roleStatsByID: [UUID: AudiobookRoleDialogueStats]
    let voiceBindings: [UUID: AudiobookVoiceBinding]
    let exportRecords: [AudiobookExportRecord]
    let allAnnotations: [AudiobookAnnotation]
    let resumePlan: AudiobookResumePlan?
    let productionCheckpoint: AudiobookProductionCheckpoint?
    let chapterReadinessByID: [UUID: AudiobookChapterReadinessState]
    let chapterDetails: AudiobookChapterDetailsSnapshot
    let workbenchTab: AudiobookWorkflowModel.WorkbenchTab
    let unknownSpeakers: AudiobookUnknownSpeakerIndex
}


struct AudiobookWorkspaceRequest: Equatable, Sendable {
    let bookID: UUID
    let chapterID: UUID?
    let preferredFragmentID: UUID?
    let selectionGeneration: UInt64
}

struct AudiobookWorkspaceRevision: Equatable, Sendable {
    let sourceSHA: String
    let contentDigest: String
}

struct AudiobookWorkspaceChangeToken: Equatable, Sendable {
    let localChanges: Int64
    let externalVersion: Int
}

struct AudiobookWorkspaceReadWork: Equatable, Sendable {
    var candidateRowsRead = 0
    var candidateQueries = 0
    var candidateVMSteps = 0
    var candidateFullScanSteps = 0
}

struct AudiobookChapterWorkspaceInput: Sendable {
    let bookID: UUID
    let chapterID: UUID?
    let source: AudiobookSourceIndex
    let atoms: [AudiobookTextAtom]
    let annotations: [AudiobookAnnotation]
    let fragments: [AudiobookFragment]
    let candidates: [AudiobookRenderCandidate]
    let revision: AudiobookWorkspaceRevision
    let work: AudiobookWorkspaceReadWork
    let changeToken: AudiobookWorkspaceChangeToken
}

struct AudiobookWorkspaceInput: Sendable {
    let book: AudiobookBook
    let chapters: [AudiobookChapter]
    let characters: [AudiobookCharacter]
    let bindings: [UUID: AudiobookVoiceBinding]
    let exports: [AudiobookExportRecord]
    let checkpoint: AudiobookProductionCheckpoint?
    let annotations: [AudiobookAnnotation]
    let chapter: AudiobookChapterWorkspaceInput
    let changeToken: AudiobookWorkspaceChangeToken
    let revision: AudiobookWorkspaceRevision
}

struct AudiobookWorkspaceResult: Sendable {
    let request: AudiobookWorkspaceRequest
    let revision: AudiobookWorkspaceRevision
    let snapshot: AudiobookBookWorkspaceSnapshot
}

struct AudiobookChapterWorkspaceResult: Sendable {
    let request: AudiobookWorkspaceRequest
    let revision: AudiobookWorkspaceRevision
    let snapshot: AudiobookChapterDetailsSnapshot
}

struct AudiobookUnknownSpeakerIndex: Sendable {
    let countsByChapterID: [UUID: Int]
    let annotations: [AudiobookAnnotation]
    let atomIDs: Set<UUID>
}

enum AudiobookWorkspaceError: Error, LocalizedError {
    case staleInput
    var errorDescription: String? { "工作区内容正在更新，请稍后重试。" }
}

enum AudiobookWorkspaceProjection {
    @concurrent
    static func chapter(_ input: AudiobookChapterWorkspaceInput, preferredFragmentID: UUID?,
        metrics: AppPerformanceMetrics = .shared,
        onBatch: (@Sendable (Int) -> Void)? = nil) async throws -> AudiobookChapterDetailsSnapshot {
        try metrics.measure(.workspaceProject, count: input.atoms.count + input.fragments.count) {
            try Task.checkCancellation()
            guard input.chapterID != nil else { return .empty }
            var atomMap: [UUID: String] = [:], fragmentMap: [UUID: String] = [:]
            atomMap.reserveCapacity(input.atoms.count)
            fragmentMap.reserveCapacity(input.fragments.count)
            for (index, atom) in input.atoms.enumerated() {
                if index.isMultiple(of: 128) { try Task.checkCancellation(); onBatch?(index) }
                atomMap[atom.id] = (try? input.source.text(in: atom.sourceRange)) ?? ""
            }
            for (index, fragment) in input.fragments.enumerated() {
                if index.isMultiple(of: 128) { try Task.checkCancellation() }
                fragmentMap[fragment.id] = (try? input.source.text(in: fragment.sourceRange)) ?? ""
            }
            try Task.checkCancellation()
            return AudiobookChapterDetailsSnapshot(chapterID: input.chapterID, atoms: input.atoms,
                annotations: input.annotations, fragments: input.fragments, candidates: input.candidates,
                atomTextsByID: atomMap, fragmentTextsByID: fragmentMap,
                selectedFragmentID: input.fragments.first(where: { $0.id == preferredFragmentID })?.id ?? input.fragments.first?.id,
                revision: input.revision)
        }
    }

    @concurrent
    static func book(_ input: AudiobookWorkspaceInput, chapter: AudiobookChapterDetailsSnapshot,
        resumePlan: AudiobookResumePlan?, readiness: [UUID: AudiobookChapterReadinessState],
        metrics: AppPerformanceMetrics = .shared) async throws -> AudiobookBookWorkspaceSnapshot {
        try metrics.measure(.workspaceProject, count: input.characters.count + input.annotations.count) {
            try Task.checkCancellation()
            var work = AudiobookRoleStatsWork()
            let (_, stats, _) = try AudiobookCastRegistry.computeRoleDialogueStats(characters: input.characters,
                annotations: input.annotations, work: &work, checkCancellation: { try Task.checkCancellation() })
            let unknowns = try unknownIndex(annotations: input.annotations, chapters: input.chapters)
            try Task.checkCancellation()
            let tab: AudiobookWorkflowModel.WorkbenchTab = input.book.analysisState == .allWindowsValidated
                && input.book.confirmedCastRevisionID != nil && input.book.confirmedAuditionVoiceSetDigest != nil
                && unknowns.annotations.isEmpty ? .production : .preparation
            return AudiobookBookWorkspaceSnapshot(book: input.book, chapters: input.chapters, characters: input.characters,
                roleStatsByID: stats, voiceBindings: input.bindings, exportRecords: input.exports, allAnnotations: input.annotations,
                resumePlan: resumePlan, productionCheckpoint: input.checkpoint, chapterReadinessByID: readiness,
                chapterDetails: chapter, workbenchTab: tab, unknownSpeakers: unknowns)
        }
    }

    @concurrent
    static func roleStatistics(characters: [AudiobookCharacter], annotations: [AudiobookAnnotation],
        availableVoiceCount: Int = 8) async throws -> (updatedCharacters: [AudiobookCharacter],
        statsByRoleID: [UUID: AudiobookRoleDialogueStats], conflictWeights: [UUID: [UUID: Int]]) {
        try Task.checkCancellation()
        var work = AudiobookRoleStatsWork()
        let result = try AudiobookCastRegistry.computeRoleDialogueStats(characters: characters, annotations: annotations,
            availableVoiceCount: availableVoiceCount, work: &work, checkCancellation: { try Task.checkCancellation() })
        try Task.checkCancellation()
        return result
    }

    @concurrent
    static func unknownSpeakers(annotations: [AudiobookAnnotation], chapters: [AudiobookChapter]) async throws -> AudiobookUnknownSpeakerIndex {
        try unknownIndex(annotations: annotations, chapters: chapters)
    }

    private static func unknownIndex(annotations: [AudiobookAnnotation], chapters: [AudiobookChapter]) throws -> AudiobookUnknownSpeakerIndex {
        let ordinals = Dictionary(uniqueKeysWithValues: chapters.map { ($0.id, $0.ordinal) })
        var counts: [UUID: Int] = [:], unknowns: [AudiobookAnnotation] = [], atomIDs: Set<UUID> = []
        for (index, annotation) in annotations.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            guard annotation.assignment.isUnknown else { continue }
            counts[annotation.chapterID, default: 0] += 1
            unknowns.append(annotation)
            atomIDs.insert(annotation.atomID)
        }
        unknowns.sort {
            let left = ordinals[$0.chapterID] ?? 0, right = ordinals[$1.chapterID] ?? 0
            return left == right ? $0.sourceRange < $1.sourceRange : left < right
        }
        try Task.checkCancellation()
        return .init(countsByChapterID: counts, annotations: unknowns, atomIDs: atomIDs)
    }
}
