import Foundation
import Synchronization
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

private final class WaveformScanProbe: Sendable {
    private struct State {
        var started = 0
        var nextIndex = 0
        var active = 0
        var peak = 0
        var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    }
    private let state = Mutex(State())
    var started: Int { state.withLock { $0.started } }
    var peak: Int { state.withLock { $0.peak } }
    func scan(_ url: URL, _ buckets: Int) async throws -> [Double] {
        let index = state.withLock { value in value.nextIndex += 1; return value.nextIndex }
        defer { state.withLock { $0.active -= 1; $0.gates.removeValue(forKey: index) } }
        // Suspend without occupying a cooperative executor thread. Cancellation
        // remains unobserved until the simulated physical reader is released.
        await withCheckedContinuation { continuation in
            state.withLock { value in
                value.gates[index] = continuation
                value.started += 1; value.active += 1
                value.peak = max(value.peak, value.active)
            }
        }
        try Task.checkCancellation()
        return Array(repeating: 0.5, count: buckets)
    }
    func open(_ index: Int) { state.withLock { $0.gates.removeValue(forKey: index) }?.resume() }
    func openAll() {
        let gates = state.withLock { value in
            let gates = Array(value.gates.values); value.gates.removeAll(); return gates
        }
        gates.forEach { $0.resume() }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct WaveformEnvelopeLoaderTests {
    private let url = URL(fileURLWithPath: "/synthetic/owned-work.wav")
    private func key(_ id: String = "work", revision: String = "1", buckets: Int = 32) -> WaveformKey {
        .init(assetID: id, revision: revision, fileIdentity: "immutable-\(revision)", bucketCount: buckets)
    }
    private func lease(_ request: WaveformRequest) throws -> UUID {
        guard case let .pending(id) = request else { Issue.record("Expected pending lease"); throw WaveformLoadError.invalidLease }
        return id
    }
    private func wait(sourceLocation: SourceLocation = #_sourceLocation, _ condition: @Sendable () async -> Bool) async throws {
        // Full-suite MainActor work can delay scheduling for several seconds.
        // This is a liveness bound, not a waveform performance assertion.
        let end = ContinuousClock.now + .seconds(15)
        while !(await condition()), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
        try #require(await condition(), sourceLocation: sourceLocation)
    }

    @Test func testSameKeyHasOnePhysicalScan() async throws {
        let probe = WaveformScanProbe(); defer { probe.openAll() }
        let loader = WaveformEnvelopeLoader(scanner: { try await probe.scan($0, $1) })
        let first = try lease(await loader.acquire(key: key(), fileURL: url))
        let second = try lease(await loader.acquire(key: key(), fileURL: url))
        try await wait { probe.started == 1 }
        #expect(await loader.snapshot().leaseCount == 2)
        probe.open(1)
        #expect(try await loader.result(leaseID: first) == Array(repeating: 0.5, count: 32))
        #expect(try await loader.result(leaseID: second) == Array(repeating: 0.5, count: 32))
        await loader.release(leaseID: first); await loader.release(leaseID: second)
        #expect(probe.started == 1 && probe.peak == 1)
        guard case .ready = await loader.acquire(key: key(), fileURL: url) else { Issue.record("Cache miss"); return }
        #expect(await loader.snapshot().ownedTaskCount == 0)
    }

    @Test func testOneActiveAndEightPendingLimit() async throws {
        let probe = WaveformScanProbe(); defer { probe.openAll() }
        let loader = WaveformEnvelopeLoader(scanner: { try await probe.scan($0, $1) })
        let active = try lease(await loader.acquire(key: key("active"), fileURL: url))
        try await wait { probe.started == 1 }
        var queued: [UUID] = []
        for i in 0..<8 { queued.append(try lease(await loader.acquire(key: key("queued-\(i)"), fileURL: url))) }
        let overflow = await loader.acquire(key: key("overflow"), fileURL: url)
        if case .deferred = overflow {} else {
            Issue.record("Queue exceeded limit")
            if case let .pending(id) = overflow { queued.append(id) }
        }
        #expect(await loader.snapshot().activeCount == 1)
        #expect(await loader.snapshot().queuedCount == 8)
        for id in queued { await loader.release(leaseID: id) }
        let release = Task { await loader.release(leaseID: active) }
        try await wait { await loader.snapshot().retiring }
        probe.open(1); await release.value
        #expect(await loader.snapshot().leaseCount == 0)
        #expect(await loader.snapshot().ownedTaskCount == 0)
        #expect(probe.started == 1)
    }

    @Test func testLastOwnerReleaseCancelsScanAndKeepsSlotUntilRealExit() async throws {
        let probe = WaveformScanProbe(); defer { probe.openAll() }
        let loader = WaveformEnvelopeLoader(scanner: { try await probe.scan($0, $1) })
        let old = try lease(await loader.acquire(key: key(revision: "old"), fileURL: url))
        try await wait { probe.started == 1 }
        let release = Task { await loader.release(leaseID: old) }
        try await wait { await loader.snapshot().retiring }
        let next = try lease(await loader.acquire(key: key(revision: "new"), fileURL: url))
        #expect(await loader.snapshot().activeCount == 1)
        #expect(await loader.snapshot().queuedCount == 1)
        #expect(probe.started == 1)
        probe.open(1); await release.value
        try await wait { probe.started == 2 }
        #expect(await loader.snapshot().cacheEntries == 0)
        probe.open(2)
        _ = try await loader.result(leaseID: next); await loader.release(leaseID: next)
        #expect(probe.peak == 1)
        #expect(await loader.snapshot().cacheEntries == 1)
        #expect(await loader.snapshot().ownedTaskCount == 0)
    }

    @Test func testCancelledWaiterCanReleaseWhilePhysicalReaderIsBlocked() async throws {
        let probe = WaveformScanProbe(); defer { probe.openAll() }
        let loader = WaveformEnvelopeLoader(scanner: { try await probe.scan($0, $1) })
        let id = try lease(await loader.acquire(key: key(), fileURL: url))
        try await wait { probe.started == 1 }
        let waiter = Task { try await loader.result(leaseID: id) }
        waiter.cancel()
        do { _ = try await waiter.value; Issue.record("Cancelled wait succeeded") } catch is CancellationError {} catch { Issue.record("Unexpected cancellation error") }
        let release = Task { await loader.release(leaseID: id) }
        try await wait { let snapshot = await loader.snapshot(); return snapshot.retiring && snapshot.leaseCount == 0 }
        #expect(probe.started == 1)
        probe.open(1); await release.value
        #expect(await loader.snapshot().cacheEntries == 0)
        #expect(await loader.snapshot().ownedTaskCount == 0)
    }

    @Test func testCacheEvictsByBothCountAndBytesAndRevisionIsPartOfKey() async throws {
        let loader = WaveformEnvelopeLoader(scanner: { _, buckets in Array(repeating: 0.25, count: buckets) })
        for i in 0..<70 {
            let id = try lease(await loader.acquire(key: key("work-\(i)"), fileURL: url))
            _ = try await loader.result(leaseID: id); await loader.release(leaseID: id)
        }
        #expect(await loader.snapshot().cacheEntries == 64)
        let recent = try lease(await loader.acquire(key: key("work-69", revision: "2"), fileURL: url))
        _ = try await loader.result(leaseID: recent); await loader.release(leaseID: recent)
        for i in 0..<3 {
            let id = try lease(await loader.acquire(key: key("large-\(i)", buckets: 16_384), fileURL: url))
            _ = try await loader.result(leaseID: id); await loader.release(leaseID: id)
        }
        let snapshot = await loader.snapshot()
        #expect(snapshot.cachePayloadBytes == 256 * 1_024)
        #expect(snapshot.cacheEntries == 2)
        #expect(snapshot.leaseCount == 0 && snapshot.ownedTaskCount == 0)
    }

    @Test func testFailureDoesNotCacheEmptySuccessOrCreateTemporaryAudio() async throws {
        let loader = WaveformEnvelopeLoader()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let id = try lease(await loader.acquire(key: key(), fileURL: missing))
        do { _ = try await loader.result(leaseID: id); Issue.record("Missing file succeeded") } catch {}
        await loader.release(leaseID: id)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(await loader.snapshot().cacheEntries == 0)
        #expect(await loader.snapshot().ownedTaskCount == 0)
    }

    @Test func testPersistedScanAndReferenceAnalysisHaveIdenticalNormalizedPeaks() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: file) }
        var pcm = Data()
        for frame in 0..<40_000 {
            var sample = Int16(frame < 20_000 ? 8_000 : 24_000).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        let wav = try DubbingAudioExport.makeWAV(from: [.init(pcm: pcm, format: .init(sampleRate: 24_000, channels: 1, bitsPerSample: 16))])
        try wav.write(to: file)
        let levels = try await scanWaveformEnvelope(fileURL: file, buckets: SpeechRailDesignTokens.Waveform.envelopeBuckets)
        #expect(levels.count == SpeechRailDesignTokens.Waveform.envelopeBuckets)
        #expect(levels.first == Double(Float(8_000) / Float(24_000)))
        #expect(levels.last == 1)
        let analysis = try #require(AudioReferenceCheck.analyze(fileAt: file))
        #expect(analysis.envelope == levels.map { CGFloat($0) })
    }

    @Test func testLeaseNotificationMetadataIsBoundedAndReleasedOwnersDoNotCancelOtherOwners() async throws {
        let probe = WaveformScanProbe(); defer { probe.openAll() }
        let loader = WaveformEnvelopeLoader(scanner: { try await probe.scan($0, $1) })
        var ids: [UUID] = []
        for _ in 0..<256 { ids.append(try lease(await loader.acquire(key: key(), fileURL: url))) }
        guard case .deferred = await loader.acquire(key: key(), fileURL: url) else { Issue.record("Unbounded owners"); return }
        try await wait { probe.started == 1 }
        for id in ids.dropLast() { await loader.release(leaseID: id) }
        #expect(await loader.snapshot().leaseCount == 1)
        #expect(await loader.snapshot().retiring == false)
        probe.open(1)
        _ = try await loader.result(leaseID: ids.last!)
        await loader.release(leaseID: ids.last!)
        #expect(await loader.snapshot().ownedTaskCount == 0)
    }

    @Test @MainActor func testViewCancellationDrainsAndOldRevisionCannotPublishOverNewSelection() async throws {
        let probe = WaveformScanProbe(); defer { probe.openAll() }
        let loader = WaveformEnvelopeLoader(scanner: { try await probe.scan($0, $1) })
        let owner = SharedPlaybackOwner(driver: WaveformPlaybackStub(), waveformLoader: loader)
        let old = Task { await owner.prepareWaveform(key: key("work:item", revision: "old"), fileURL: url) }
        try await wait { probe.started == 1 }
        old.cancel()
        try await wait { await loader.snapshot().retiring }
        let next = Task { await owner.prepareWaveform(key: key("work:item", revision: "new"), fileURL: url) }
        try await wait { await loader.snapshot().queuedCount == 1 }
        probe.open(1); await old.value
        #expect(owner.waveformEnvelope(kind: "work", id: "item") == nil)
        try await wait { probe.started == 2 }
        probe.open(2); await next.value
        #expect(owner.waveformEnvelope(kind: "work", id: "item")?.count == 32)
        #expect(await loader.snapshot().ownedTaskCount == 0)
        #expect(await loader.snapshot().leaseCount == 0)
        #expect(probe.peak == 1)
    }
}

@MainActor private final class WaveformPlaybackStub: SharedAudioPlaybackDriver {
    var isPlaying = false
    var onPlaybackFinished: (@MainActor (Bool) -> Void)?
    var onProgress: (@MainActor (Double) -> Void)?
    var onLevel: (@MainActor (Float) -> Void)?
    func play(data: Data) throws {}
    func stop() {}
    func duration(for data: Data) -> TimeInterval? { nil }
}
