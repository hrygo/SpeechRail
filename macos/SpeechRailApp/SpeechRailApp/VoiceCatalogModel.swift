import Darwin
import Dispatch
import Foundation
import Observation

/// UI reads this immutable value; all file access belongs to VoiceCatalogStore.
@MainActor
@Observable
public final class VoiceCatalogModel {
    public let store: VoiceCatalogStore
    public private(set) var snapshot = VoiceCatalogSnapshot(loadState: .loading)
    @ObservationIgnored var onSnapshotChange: (@MainActor (VoiceCatalogSnapshot) -> Void)?
    @ObservationIgnored private let watcher: VoiceCatalogFileWatcher
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var deferredRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsRefresh = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var observationGeneration: UUID?
    @ObservationIgnored private var stopping = false

    public init(store: VoiceCatalogStore) {
        self.store = store
        self.watcher = VoiceCatalogFileWatcher()
    }

    init(store: VoiceCatalogStore, watcher: VoiceCatalogFileWatcher) {
        self.store = store
        self.watcher = watcher
    }

    deinit {
        refreshTask?.cancel()
        watchTask?.cancel()
        deferredRefreshTask?.cancel()
    }

    public func metadata(for voiceID: String) -> VoiceAssetMetadata? {
        snapshot.state.metadataByVoiceID[voiceID]
    }

    /// One in-flight refresh and at most one dirty follow-up per batch.
    public func refresh() async {
        guard !stopping else { return }
        needsRefresh = true
        if let task = refreshTask {
            await task.value
            return
        }
        let requestGeneration = generation
        let task = Task { [weak self] in
            defer { self?.finishRefresh(generation: requestGeneration) }
            for _ in 0..<2 {
                guard let self, self.generation == requestGeneration, !Task.isCancelled else { return }
                self.needsRefresh = false
                let loaded = await self.store.refresh()
                guard self.generation == requestGeneration, !Task.isCancelled else { return }
                if loaded != self.snapshot {
                    self.snapshot = loaded
                    self.onSnapshotChange?(loaded)
                }
                if !self.needsRefresh { return }
            }
        }
        refreshTask = task
        await task.value
    }

    private func finishRefresh(generation: UUID) {
        guard self.generation == generation else { return }
        refreshTask = nil
        if needsRefresh { scheduleDeferredRefresh() }
    }

    /// Never uses a previously started read as the authority for a new action.
    public func requireFreshSnapshot() async throws -> VoiceCatalogSnapshot {
        try Task.checkCancellation()
        let requestGeneration = generation
        if let task = refreshTask { await task.value }
        await refresh()
        try Task.checkCancellation()
        guard !stopping, generation == requestGeneration else { throw CancellationError() }
        guard snapshot.loadState == .ready || snapshot.loadState == .missing else {
            throw VoiceCatalogError.unavailable
        }
        return snapshot
    }

    public func startObserving() async {
        guard observationGeneration == nil else { return }
        stopping = false
        let ticket = UUID()
        observationGeneration = ticket
        let events = await watcher.events(for: store, generation: ticket)
        guard observationGeneration == ticket else {
            await watcher.stop(generation: ticket)
            return
        }
        let watcher = watcher
        watchTask = Task { [weak self] in
            for await _ in events {
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { break }
                guard let self, self.observationGeneration == ticket, !Task.isCancelled else { break }
                await self.refresh()
                await watcher.retargetDirectory(generation: ticket)
            }
            await watcher.stop(generation: ticket)
        }
        await refresh()
    }

    public func stop() async {
        stopping = true
        generation = UUID()
        let observation = observationGeneration
        observationGeneration = nil
        let refresh = refreshTask
        let watch = watchTask
        let deferred = deferredRefreshTask
        refreshTask = nil
        watchTask = nil
        deferredRefreshTask = nil
        needsRefresh = false
        refresh?.cancel()
        watch?.cancel()
        deferred?.cancel()
        if let observation { await watcher.stop(generation: observation) }
        await refresh?.value
        await watch?.value
        await deferred?.value
    }

    private func scheduleDeferredRefresh() {
        guard deferredRefreshTask == nil else { return }
        deferredRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.deferredRefreshTask = nil
            await self.refresh()
        }
    }
}

/// Parent-directory events cover atomic file replacement; the event queue holds one Void.
/// Notification and descriptor handles never leave this actor.
actor VoiceCatalogFileWatcher {
    private var notification: CatalogNotificationHandle?
    private var directory: CatalogDirectoryHandle?
    private var targetDirectory: URL?
    private var continuation: AsyncStream<Void>.Continuation?
    private var generation: UUID?
    var isObserving: Bool { notification != nil }

    func events(for store: VoiceCatalogStore, generation: UUID) -> AsyncStream<Void> {
        reset()
        self.generation = generation
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation = pair.continuation
        targetDirectory = store.storageURL?.deletingLastPathComponent()
        notification = CatalogNotificationHandle(catalog: store, continuation: pair.continuation)
        retargetDirectory(generation: generation)
        return pair.stream
    }

    func retargetDirectory(generation: UUID) {
        guard self.generation == generation else { return }
        guard var target = targetDirectory, let continuation else { return }
        // The catalog's directory may not exist yet; watch its nearest existing parent.
        while !FileManager.default.fileExists(atPath: target.path) {
            let parent = target.deletingLastPathComponent()
            guard parent != target else { return }
            target = parent
        }
        let descriptor = Darwin.open(target.path, O_EVTONLY)
        guard descriptor >= 0 else { directory = nil; return }
        directory = CatalogDirectoryHandle(descriptor: descriptor, continuation: continuation)
    }

    func stop(generation: UUID) {
        guard self.generation == generation else { return }
        reset()
    }

    private func reset() {
        continuation?.finish()
        continuation = nil
        directory = nil
        notification = nil
        targetDirectory = nil
        generation = nil
    }
}

private final class CatalogNotificationHandle {
    private let token: NSObjectProtocol
    init(catalog: VoiceCatalogStore, continuation: AsyncStream<Void>.Continuation) {
        token = NotificationCenter.default.addObserver(
            forName: VoiceCatalogStore.didChange, object: catalog, queue: nil
        ) { _ in continuation.yield(()) }
    }
    deinit { NotificationCenter.default.removeObserver(token) }
}

private final class CatalogDirectoryHandle {
    private let source: DispatchSourceFileSystemObject
    init(descriptor: Int32, continuation: AsyncStream<Void>.Continuation) {
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { continuation.yield(()) }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.activate()
    }
    deinit { source.cancel() }
}
