import Foundation

/// Owns physical reads/projections; the workflow's selection owner decides publication.
actor AudiobookWorkspaceReader {
    private enum Domain: Hashable, Sendable { case book, chapter }
    private enum Loaded: Sendable {
        case book(AudiobookWorkspaceResult)
        case chapter(AudiobookChapterWorkspaceResult)
    }
    private struct Operation {
        let id: UUID
        let task: Task<Loaded, Error>
    }
    private struct Pending {
        let id: UUID
        let continuation: AsyncStream<Void>.Continuation
    }
    private struct ChapterCache {
        let chapterID: UUID?
        let revision: AudiobookWorkspaceRevision
        let token: AudiobookWorkspaceChangeToken
        let snapshot: AudiobookChapterDetailsSnapshot
    }
    struct CacheState: Sendable {
        let bookID: UUID?
        let chapterIDs: [UUID]
        let activeOperations: Int
        let waitingDomains: Int
    }

    private let store: AudiobookProjectStore
    private let cast: AudiobookCastController?
    private let revisions: AudiobookRevisionController?
    private let metrics: AppPerformanceMetrics
    private let readBoundary: (@Sendable (Int) async throws -> Void)?
    private let queueObserver: (@Sendable (UInt64) -> Void)?
    private let projectionBatch: (@Sendable (Int) -> Void)?
    private var generation = UUID()
    private var latest: [Domain: UUID] = [:]
    private var active: [Domain: Operation] = [:]
    private var pending: [Domain: Pending] = [:]
    private var bookID: UUID?
    private var chapterCache: [ChapterCache] = []
    private var recoveredBooks: Set<UUID> = []

    init(store: AudiobookProjectStore, cast: AudiobookCastController? = nil,
         revisions: AudiobookRevisionController? = nil, metrics: AppPerformanceMetrics = .shared,
         readBoundary: (@Sendable (Int) async throws -> Void)? = nil,
         queueObserver: (@Sendable (UInt64) -> Void)? = nil,
         projectionBatch: (@Sendable (Int) -> Void)? = nil) {
        self.store = store
        self.cast = cast
        self.revisions = revisions
        self.metrics = metrics
        self.readBoundary = readBoundary
        self.queueObserver = queueObserver
        self.projectionBatch = projectionBatch
    }

    func load(_ request: AudiobookWorkspaceRequest) async throws -> AudiobookWorkspaceResult {
        guard case .book(let result) = try await perform(request, domain: .book) else { throw CancellationError() }
        return result
    }

    func loadChapter(_ request: AudiobookWorkspaceRequest) async throws -> AudiobookChapterWorkspaceResult {
        guard case .chapter(let result) = try await perform(request, domain: .chapter) else { throw CancellationError() }
        return result
    }

    func cacheState() -> CacheState {
        .init(bookID: bookID, chapterIDs: chapterCache.compactMap(\.chapterID),
              activeOperations: active.count, waitingDomains: pending.count)
    }

    func stop() async {
        generation = UUID()
        latest.removeAll()
        let waiters = pending.values.map(\.continuation)
        pending.removeAll()
        waiters.forEach { $0.finish() }
        let operations = Array(active.values)
        chapterCache.removeAll()
        bookID = nil
        operations.forEach { $0.task.cancel() }
        for operation in operations {
            _ = try? await operation.task.value
            for domain in [Domain.book, .chapter] where active[domain]?.id == operation.id { active[domain] = nil }
        }
    }

    private func perform(_ request: AudiobookWorkspaceRequest, domain: Domain) async throws -> Loaded {
        try Task.checkCancellation()
        let requestID = UUID(), epoch = generation
        latest[domain] = requestID
        defer {
            if pending[domain]?.id == requestID {
                pending.removeValue(forKey: domain)?.continuation.finish()
            }
        }
        while let previous = active[domain] {
            let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            pending[domain]?.continuation.finish()
            pending[domain] = .init(id: requestID, continuation: signal.continuation)
            queueObserver?(request.selectionGeneration)
            previous.task.cancel()
            for await _ in signal.stream { break }
            guard generation == epoch, latest[domain] == requestID else { throw CancellationError() }
            try Task.checkCancellation()
        }
        guard generation == epoch, latest[domain] == requestID else { throw CancellationError() }
        if bookID != request.bookID {
            bookID = request.bookID
            chapterCache.removeAll()
        }
        let operationID = UUID()
        let operation = Task { [weak self] in
            guard let self else { throw CancellationError() }
            switch domain {
            case .book: return Loaded.book(try await self.readBook(request))
            case .chapter: return Loaded.chapter(try await self.readChapter(request))
            }
        }
        active[domain] = .init(id: operationID, task: operation)
        defer {
            if active[domain]?.id == operationID {
                active[domain] = nil
                if let waiter = pending.removeValue(forKey: domain) {
                    waiter.continuation.yield(())
                    waiter.continuation.finish()
                }
            }
        }
        let result = try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: { operation.cancel() }
        try Task.checkCancellation()
        guard generation == epoch, latest[domain] == requestID else { throw CancellationError() }
        return result
    }

    private func readBook(_ request: AudiobookWorkspaceRequest) async throws -> AudiobookWorkspaceResult {
        if !recoveredBooks.contains(request.bookID) {
            try await cast?.recoverVoiceRegistrations(bookID: request.bookID)
            try Task.checkCancellation()
            recoveredBooks.insert(request.bookID)
        }
        for attempt in 0..<2 {
            var input = try await store.loadWorkspaceInput(bookID: request.bookID, chapterID: request.chapterID)
            try await readBoundary?(attempt)
            try Task.checkCancellation()
            let started = input.book.productionState != .idle
                || input.chapters.contains { $0.currentChapterRevisionID != nil || $0.previousChapterRevisionID != nil }
            let resume = started ? try? await revisions?.resumePlan(bookID: request.bookID) : nil
            try Task.checkCancellation()
            let readiness = (try? await cast?.chapterReadinessMap(for: request.bookID)) ?? [:]
            try Task.checkCancellation()
            if try await store.workspaceChangeToken() != input.changeToken {
                let verification = try await store.loadWorkspaceInput(bookID: request.bookID, chapterID: request.chapterID)
                guard verification.revision == input.revision else { continue }
                input = verification
            }
            let chapter = try await projectChapter(input.chapter, request: request)
            let snapshot = try await AudiobookWorkspaceProjection.book(input, chapter: chapter, resumePlan: resume,
                readiness: readiness, metrics: metrics)
            try Task.checkCancellation()
            if try await store.workspaceChangeToken() != input.changeToken {
                let verification = try await store.loadWorkspaceInput(bookID: request.bookID, chapterID: request.chapterID)
                guard verification.revision == input.revision else { continue }
            }
            try Task.checkCancellation()
            return .init(request: request, revision: input.revision, snapshot: snapshot)
        }
        throw AudiobookWorkspaceError.staleInput
    }

    private func readChapter(_ request: AudiobookWorkspaceRequest) async throws -> AudiobookChapterWorkspaceResult {
        let token = try await store.workspaceChangeToken()
        try Task.checkCancellation()
        if bookID == request.bookID,
           let index = chapterCache.firstIndex(where: { $0.chapterID == request.chapterID && $0.token == token }) {
            let cached = chapterCache.remove(at: index)
            chapterCache.append(cached)
            return .init(request: request, revision: cached.revision,
                snapshot: select(cached.snapshot, preferred: request.preferredFragmentID))
        }
        for _ in 0..<2 {
            let input = try await store.loadChapterWorkspaceInput(bookID: request.bookID, chapterID: request.chapterID)
            let snapshot = try await projectChapter(input, request: request)
            if try await store.workspaceChangeToken() != input.changeToken {
                let verification = try await store.loadChapterWorkspaceInput(bookID: request.bookID, chapterID: request.chapterID)
                guard verification.revision == input.revision else { continue }
            }
            try Task.checkCancellation()
            return .init(request: request, revision: input.revision, snapshot: snapshot)
        }
        throw AudiobookWorkspaceError.staleInput
    }

    private func projectChapter(_ input: AudiobookChapterWorkspaceInput, request: AudiobookWorkspaceRequest) async throws -> AudiobookChapterDetailsSnapshot {
        try Task.checkCancellation()
        let cached = bookID == request.bookID ? chapterCache.first(where: { $0.chapterID == input.chapterID }) : nil
        let snapshot: AudiobookChapterDetailsSnapshot
        if let cached, cached.revision == input.revision {
            snapshot = select(cached.snapshot, preferred: request.preferredFragmentID)
        } else {
            snapshot = try await AudiobookWorkspaceProjection.chapter(input, preferredFragmentID: request.preferredFragmentID, metrics: metrics, onBatch: projectionBatch)
        }
        try Task.checkCancellation()
        if bookID == request.bookID {
            chapterCache.removeAll { $0.chapterID == input.chapterID }
            chapterCache.append(.init(chapterID: input.chapterID, revision: input.revision, token: input.changeToken, snapshot: snapshot))
            if chapterCache.count > 2 { chapterCache.removeFirst(chapterCache.count - 2) }
        }
        return snapshot
    }

    private func select(_ snapshot: AudiobookChapterDetailsSnapshot, preferred: UUID?) -> AudiobookChapterDetailsSnapshot {
        .init(chapterID: snapshot.chapterID, atoms: snapshot.atoms, annotations: snapshot.annotations,
            fragments: snapshot.fragments, candidates: snapshot.candidates, atomTextsByID: snapshot.atomTextsByID,
            fragmentTextsByID: snapshot.fragmentTextsByID,
            selectedFragmentID: snapshot.fragments.first(where: { $0.id == preferred })?.id ?? snapshot.fragments.first?.id,
            revision: snapshot.revision)
    }
}
