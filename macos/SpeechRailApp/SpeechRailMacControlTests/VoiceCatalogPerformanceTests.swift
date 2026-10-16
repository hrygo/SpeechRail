import XCTest
import Synchronization

#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

@MainActor
final class VoiceCatalogPerformanceTests: XCTestCase {
    private final class ReadGate: Sendable {
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let release = DispatchSemaphore(value: 0)
        func block() {
            entered.continuation.yield(())
            release.wait()
        }
    }
    private final class Counter: Sendable {
        let value = Mutex(0)
        func increment() { value.withLock { $0 += 1 } }
        var count: Int { value.withLock { $0 } }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testThousandMetadataReadsDoNotReadOrDecodeFile() async throws {
        let url = try directory().appendingPathComponent("catalog.json")
        let reads = Counter()
        let metrics = AppPerformanceMetrics(collecting: true, signposting: false)
        let store = VoiceCatalogStore(storageURL: url, readContents: {
            reads.increment()
            return try Data(contentsOf: $0)
        }, metrics: metrics)
        _ = try await store.registerGlobalVoice(voiceID: "voice", creationSource: .voiceDesign)
        let model = VoiceCatalogModel(store: store)
        await model.refresh()
        let baseline = reads.count
        let measured = metrics.snapshot(for: .catalogRefresh).samples
        for _ in 0..<1_000 {
            XCTAssertEqual(model.snapshot.state.metadataByVoiceID["voice"]?.voiceID, "voice")
            XCTAssertFalse(model.snapshot.revision.isEmpty)
        }
        XCTAssertEqual(reads.count, baseline)
        XCTAssertEqual(metrics.snapshot(for: .catalogRefresh).samples, measured)
        await model.stop()
    }

    func testRevisionIsBuiltOncePerSnapshot() {
        let builds = Counter()
        let snapshot = VoiceCatalogSnapshot(state: .init(), loadState: .ready, makeRevision: { _, _ in
            builds.increment()
            return "revision"
        })
        for _ in 0..<1_000 { XCTAssertEqual(snapshot.revision, "revision") }
        XCTAssertEqual(builds.count, 1)
    }

    func testInitDoesNotReadAndConcurrentRefreshesCoalesceOffMainActor() async throws {
        let url = try directory().appendingPathComponent("catalog.json")
        try JSONEncoder().encode(VoiceCatalogStore.PersistedState()).write(to: url)
        let reads = Counter(), mainThreadReads = Counter(), gate = ReadGate()
        let store = VoiceCatalogStore(storageURL: url, readContents: { url in
            if Thread.isMainThread { mainThreadReads.increment() }
            reads.increment()
            if reads.count == 1 { gate.block() }
            return try Data(contentsOf: url)
        })
        XCTAssertEqual(reads.count, 0)
        let model = VoiceCatalogModel(store: store)
        let first = Task { await model.refresh() }
        var entry = gate.entered.stream.makeAsyncIterator()
        _ = await entry.next()
        let started = AsyncStream<Void>.makeStream()
        let requests = (0..<100).map { _ in
            Task {
                started.continuation.yield(())
                await model.refresh()
            }
        }
        var starts = started.stream.makeAsyncIterator()
        for _ in requests { _ = await starts.next() }
        gate.release.signal()
        await first.value
        for request in requests { await request.value }
        XCTAssertEqual(reads.count, 2, "One in-flight read and one dirty follow-up")
        XCTAssertEqual(mainThreadReads.count, 0)
        await model.stop()
    }

    func testExternalAtomicReplaceWithSameSizeInvalidates() async throws {
        let url = try directory().appendingPathComponent("catalog.json")
        let store = VoiceCatalogStore(storageURL: url)
        _ = try await store.registerGlobalVoice(voiceID: "first", creationSource: .voiceDesign)
        let model = VoiceCatalogModel(store: store)
        let initial = try await model.requireFreshSnapshot()
        let data = try Data(contentsOf: url)
        let replacement = Data(String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "first", with: "other").utf8)
        XCTAssertEqual(data.count, replacement.count)
        try replacement.write(to: url, options: .atomic)
        let updated = try await model.requireFreshSnapshot()
        XCTAssertNotEqual(updated.revision, initial.revision)
        XCTAssertNil(updated.state.metadataByVoiceID["first"])
        XCTAssertEqual(updated.state.metadataByVoiceID["other"]?.voiceID, "other")
        await model.stop()
    }

    func testCorruptFileIsNotEmptyReady() async throws {
        let url = try directory().appendingPathComponent("catalog.json")
        try Data("not-json".utf8).write(to: url)
        let model = VoiceCatalogModel(store: VoiceCatalogStore(storageURL: url))
        do {
            _ = try await model.requireFreshSnapshot()
            XCTFail("Corrupt catalog must not authorize an action")
        } catch { XCTAssertEqual(error as? VoiceCatalogError, .unavailable) }
        XCTAssertEqual(model.snapshot.loadState, .unreadable)
        XCTAssertEqual(try Data(contentsOf: url), Data("not-json".utf8))
        await model.stop()
    }

    func testActionRefreshDoesNotReuseReadStartedBeforeAction() async throws {
        let url = try directory().appendingPathComponent("catalog.json")
        let seed = VoiceCatalogStore(storageURL: url)
        _ = try await seed.registerGlobalVoice(voiceID: "first", creationSource: .voiceDesign)
        let reads = Counter(), gate = ReadGate()
        let store = VoiceCatalogStore(storageURL: url, readContents: { url in
            let data = try Data(contentsOf: url)
            reads.increment()
            if reads.count == 1 { gate.block() }
            return data
        })
        let model = VoiceCatalogModel(store: store)
        let oldRead = Task { await model.refresh() }
        var entered = gate.entered.stream.makeAsyncIterator()
        _ = await entered.next()
        let replacement = Data(String(decoding: try Data(contentsOf: url), as: UTF8.self)
            .replacingOccurrences(of: "first", with: "other").utf8)
        try replacement.write(to: url, options: .atomic)
        let started = AsyncStream<Void>.makeStream()
        let action = Task {
            started.continuation.yield(())
            return try await model.requireFreshSnapshot()
        }
        var starts = started.stream.makeAsyncIterator()
        _ = await starts.next()
        gate.release.signal()
        let snapshot = try await action.value
        await oldRead.value
        XCTAssertEqual(reads.count, 2)
        XCTAssertNil(snapshot.state.metadataByVoiceID["first"])
        XCTAssertNotNil(snapshot.state.metadataByVoiceID["other"])
        await model.stop()
    }

    func testCorruptionRevokesPreviouslyCachedPermission() async throws {
        let url = try directory().appendingPathComponent("catalog.json")
        let store = VoiceCatalogStore(storageURL: url)
        _ = try await store.registerGlobalVoice(voiceID: "voice", creationSource: .voiceDesign)
        let model = VoiceCatalogModel(store: store)
        let initial = try await model.requireFreshSnapshot()
        XCTAssertTrue(initial.isVoiceActiveForBook(voiceID: "voice", currentBookID: nil))
        try Data("broken".utf8).write(to: url, options: .atomic)
        do {
            _ = try await model.requireFreshSnapshot()
            XCTFail("A cached permission cannot authorize work after a failed read")
        } catch { XCTAssertEqual(error as? VoiceCatalogError, .unavailable) }
        XCTAssertFalse(model.snapshot.isVoiceActiveForBook(voiceID: "voice", currentBookID: nil))
        await model.stop()
    }

    func testCommitFailureDoesNotPublish() async throws {
        enum DiskError: Error { case full }
        let url = try directory().appendingPathComponent("catalog.json")
        let seed = VoiceCatalogStore(storageURL: url)
        _ = try await seed.registerGlobalVoice(voiceID: "first", creationSource: .voiceDesign)
        let store = VoiceCatalogStore(storageURL: url, writeAtomically: { _, _ in throw DiskError.full })
        let before = await store.refresh()
        do {
            _ = try await store.registerGlobalVoice(voiceID: "other", creationSource: .voiceDesign)
            XCTFail("Disk failure must propagate")
        } catch is DiskError {}
        let after = await store.snapshot()
        XCTAssertEqual(after, before)
        XCTAssertNil(after.state.metadataByVoiceID["other"])
    }

    func testDeletedCatalogDoesNotRetainPreviousPermission() async throws {
        let url = try directory().appendingPathComponent("catalog.json")
        let store = VoiceCatalogStore(storageURL: url)
        _ = try await store.registerGlobalVoice(voiceID: "first", creationSource: .voiceDesign)
        try FileManager.default.removeItem(at: url)
        let snapshot = await store.refresh()
        XCTAssertEqual(snapshot.loadState, .missing)
        XCTAssertTrue(snapshot.state.metadataByVoiceID.isEmpty)
    }

    func testWatcherStopsWithOwner() async throws {
        let url = try directory().appendingPathComponent("catalog.json")
        let watcher = VoiceCatalogFileWatcher()
        let model = VoiceCatalogModel(store: VoiceCatalogStore(storageURL: url), watcher: watcher)
        await model.startObserving()
        let started = await watcher.isObserving
        XCTAssertTrue(started)
        await model.stop()
        let stopped = await watcher.isObserving
        XCTAssertFalse(stopped)
    }

    func testRetiredWatcherCannotStopNewObservation() async throws {
        let watcher = VoiceCatalogFileWatcher()
        let store = VoiceCatalogStore(storageURL: try directory().appendingPathComponent("catalog.json"))
        let old = UUID(), current = UUID()
        _ = await watcher.events(for: store, generation: old)
        _ = await watcher.events(for: store, generation: current)
        await watcher.stop(generation: old)
        let active = await watcher.isObserving
        XCTAssertTrue(active)
        await watcher.stop(generation: current)
        let stopped = await watcher.isObserving
        XCTAssertFalse(stopped)
    }

    func testCommittedMutationNotifiesWatcherWithoutFilePolling() async throws {
        let watcher = VoiceCatalogFileWatcher(), ticket = UUID()
        let store = VoiceCatalogStore()
        let events = await watcher.events(for: store, generation: ticket)
        _ = try await store.registerGlobalVoice(voiceID: "voice", creationSource: .voiceDesign)
        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertNotNil(event)
        await watcher.stop(generation: ticket)
    }
}
