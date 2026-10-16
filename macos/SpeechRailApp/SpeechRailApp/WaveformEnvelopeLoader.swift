import Foundation

public struct WaveformKey: Hashable, Sendable {
    public let assetID: String
    public let revision: String
    public let fileIdentity: String
    public let bucketCount: Int
    public init(assetID: String, revision: String, fileIdentity: String, bucketCount: Int) {
        self.assetID = assetID; self.revision = revision
        self.fileIdentity = fileIdentity; self.bucketCount = bucketCount
    }
}

public enum WaveformLoadError: Error, Sendable {
    case invalidRequest, invalidLease, readFailed, invalidAudio, expired, cancelled
}

public enum WaveformRequest: Sendable {
    case ready(levels: [Double])
    case pending(leaseID: UUID)
    case deferred
    case failed(WaveformLoadError)
}

/// Only immutable persisted audio is admitted. No audio or path is logged.
public actor WaveformEnvelopeLoader {
    public typealias Scanner = @Sendable (URL, Int) async throws -> [Double]
    public struct Snapshot: Sendable {
        public let activeCount: Int
        public let queuedCount: Int
        public let leaseCount: Int
        public let ownedTaskCount: Int
        public let retiring: Bool
        public let cacheEntries: Int
        public let cachePayloadBytes: Int
    }
    private enum Completion: Sendable { case success, failed(WaveformLoadError) }
    private struct Lease {
        let operationID: UUID
        let key: WaveformKey
        let stream: AsyncStream<Completion>
        let continuation: AsyncStream<Completion>.Continuation
        var waiting = false
    }
    private struct Operation {
        let id: UUID
        let key: WaveformKey
        let fileURL: URL
        var owners: Set<UUID>
        var retiring = false
    }
    private let scanner: Scanner
    private var active: Operation?
    private var queued: [Operation] = []
    private var operationByKey: [WaveformKey: UUID] = [:]
    private var leases: [UUID: Lease] = [:]
    private var activeTask: Task<[Double], Error>?
    private var completionTask: Task<Void, Never>?
    private var cache: [WaveformKey: [Double]] = [:]
    private var lru: [WaveformKey] = []
    private var payloadBytes = 0

    public init(scanner: @escaping Scanner = { try await scanWaveformEnvelope(fileURL: $0, buckets: $1) }) {
        self.scanner = scanner
    }

    public func acquire(key: WaveformKey, fileURL: URL) -> WaveformRequest {
        guard !Task.isCancelled else { return .failed(.cancelled) }
        guard fileURL.isFileURL, !key.assetID.isEmpty, !key.revision.isEmpty, !key.fileIdentity.isEmpty,
              (1...32_768).contains(key.bucketCount) else { return .failed(.invalidRequest) }
        if let levels = cached(key) { return .ready(levels: levels) }
        // A caller must release even a completed lease. Bound its notification metadata too.
        guard leases.count < 256 else { return .deferred }
        let leaseID = UUID()
        if let operationID = operationByKey[key] {
            if active?.id == operationID { active?.owners.insert(leaseID) }
            else if let index = queued.firstIndex(where: { $0.id == operationID }) { queued[index].owners.insert(leaseID) }
            else { return .failed(.invalidRequest) }
            addLease(leaseID, operationID: operationID, key: key)
            return .pending(leaseID: leaseID)
        }
        guard active == nil || queued.count < 8 else { return .deferred }
        let operation = Operation(id: UUID(), key: key, fileURL: fileURL, owners: [leaseID])
        addLease(leaseID, operationID: operation.id, key: key)
        operationByKey[key] = operation.id
        if active == nil { start(operation) } else { queued.append(operation) }
        return .pending(leaseID: leaseID)
    }

    /// Cancellation wakes the stream waiter immediately; the owner then awaits release.
    /// Completion signals contain no arrays, so unreleased leases cannot retain evicted payloads.
    public func result(leaseID: UUID) async throws -> [Double] {
        try Task.checkCancellation()
        guard var lease = leases[leaseID], !lease.waiting else { throw WaveformLoadError.invalidLease }
        lease.waiting = true; leases[leaseID] = lease
        var iterator = lease.stream.makeAsyncIterator()
        guard let completion = await iterator.next() else { throw CancellationError() }
        try Task.checkCancellation()
        guard leases[leaseID] != nil else { throw CancellationError() }
        switch completion {
        case .success:
            guard let levels = cached(lease.key) else { throw WaveformLoadError.expired }
            return levels
        case let .failed(error):
            if case .cancelled = error { throw CancellationError() }
            throw error
        }
    }

    /// Last-owner cancellation retains the physical slot until the reader really exits.
    public func release(leaseID: UUID) async {
        guard let lease = leases.removeValue(forKey: leaseID) else { return }
        lease.continuation.finish()
        if active?.id == lease.operationID {
            active?.owners.remove(leaseID)
            guard active?.owners.isEmpty == true, let worker = activeTask else { return }
            active?.retiring = true
            if operationByKey[lease.key] == lease.operationID { operationByKey.removeValue(forKey: lease.key) }
            let monitor = completionTask
            worker.cancel()
            let result = await worker.result
            finished(operationID: lease.operationID, result: result)
            await monitor?.value
        } else if let index = queued.firstIndex(where: { $0.id == lease.operationID }) {
            queued[index].owners.remove(leaseID)
            if queued[index].owners.isEmpty {
                queued.remove(at: index)
                if operationByKey[lease.key] == lease.operationID { operationByKey.removeValue(forKey: lease.key) }
            }
        }
    }

    public func snapshot() -> Snapshot {
        .init(activeCount: active == nil ? 0 : 1, queuedCount: queued.count, leaseCount: leases.count,
              ownedTaskCount: (activeTask == nil ? 0 : 1) + (completionTask == nil ? 0 : 1),
              retiring: active?.retiring ?? false, cacheEntries: cache.count, cachePayloadBytes: payloadBytes)
    }

    private func addLease(_ id: UUID, operationID: UUID, key: WaveformKey) {
        let pair = AsyncStream<Completion>.makeStream(bufferingPolicy: .bufferingNewest(1))
        leases[id] = Lease(operationID: operationID, key: key, stream: pair.stream, continuation: pair.continuation)
    }

    private func start(_ operation: Operation) {
        active = operation
        let scanner = scanner
        let worker = Task(priority: .utility) {
            try await performWaveformScan(scanner: scanner, fileURL: operation.fileURL, buckets: operation.key.bucketCount)
        }
        activeTask = worker
        completionTask = Task {
            let result = await worker.result
            finished(operationID: operation.id, result: result)
        }
    }

    private func finished(operationID: UUID, result: Result<[Double], Error>) {
        guard let operation = active, operation.id == operationID else { return }
        let completion: Completion
        switch result {
        case let .success(levels) where !operation.retiring && !operation.owners.isEmpty:
            if levels.count == operation.key.bucketCount, levels.allSatisfy({ $0.isFinite && (0...1).contains($0) }) {
                insert(levels, for: operation.key); completion = .success
            } else { completion = .failed(.invalidAudio) }
        case .success: completion = .failed(.cancelled)
        case let .failure(error): completion = .failed(error is CancellationError ? .cancelled : .readFailed)
        }
        for id in operation.owners {
            leases[id]?.continuation.yield(completion)
            leases[id]?.continuation.finish()
        }
        if operationByKey[operation.key] == operationID { operationByKey.removeValue(forKey: operation.key) }
        active = nil; activeTask = nil; completionTask = nil
        if !queued.isEmpty { start(queued.removeFirst()) }
    }

    private func cached(_ key: WaveformKey) -> [Double]? {
        guard let levels = cache[key] else { return nil }
        lru.removeAll { $0 == key }; lru.append(key)
        return levels
    }

    private func insert(_ levels: [Double], for key: WaveformKey) {
        if let old = cache.removeValue(forKey: key) { payloadBytes -= old.count * MemoryLayout<Double>.stride }
        lru.removeAll { $0 == key }
        cache[key] = levels; lru.append(key)
        payloadBytes += levels.count * MemoryLayout<Double>.stride
        while cache.count > 64 || payloadBytes > 256 * 1_024 {
            let evicted = lru.removeFirst()
            if let old = cache.removeValue(forKey: evicted) { payloadBytes -= old.count * MemoryLayout<Double>.stride }
        }
    }
}

@concurrent
private func performWaveformScan(scanner: WaveformEnvelopeLoader.Scanner, fileURL: URL, buckets: Int) async throws -> [Double] {
    try Task.checkCancellation()
    return try await scanner(fileURL, buckets)
}
