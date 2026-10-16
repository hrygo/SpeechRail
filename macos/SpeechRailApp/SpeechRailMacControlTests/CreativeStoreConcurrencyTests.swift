import Foundation
import Synchronization
import Testing
import SpeechRailControlKit
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

@Suite(.timeLimit(.minutes(1)))
struct CreativeStoreConcurrencyTests {
    private final class Directory {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private final class Gate: Sendable {
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let release = DispatchSemaphore(value: 0)
        let mainThread = Mutex(false)
        func block() throws {
            let main = Thread.isMainThread
            mainThread.withLock { $0 = main }
            entered.continuation.yield(())
            // The old MainActor implementation must fail instead of deadlocking the test runner.
            if main { throw CocoaError(.featureUnsupported) }
            release.wait()
        }
    }

    private func work(_ id: String) -> CreativeWork {
        .init(id: id, title: "并发夹具", scriptText: "合成测试文本", voiceID: "fixture", voiceName: "夹具",
              audioFileName: "\(id).wav")
    }

    @Test @MainActor
    func testSlowFilesystemDoesNotBlockMainActor() async throws {
        let directory = Directory(), gate = Gate(), item = work("slow")
        defer { gate.release.signal() }
        let store = CreativeWorkStore(directory: directory.url, fileOperations: .init(syncInterceptor: { url in
            if url.lastPathComponent == "works.json" { try gate.block() }
        }))
        let write = Task { try await store.save(item, audioData: Data([1, 2]), operationID: UUID()) }
        var entered = gate.entered.stream.makeAsyncIterator()
        _ = await entered.next()
        let heartbeat = Task { @MainActor in 1 }
        #expect(await heartbeat.value == 1)
        #expect(!gate.mainThread.withLock { $0 })
        gate.release.signal()
        let saved = try await write.value
        #expect(saved.receipt.committed)
        #expect(saved.value.id == item.id)
    }

    @Test @MainActor
    func testCancelAtCommitReturnsActualReceipt() async throws {
        let directory = Directory(), gate = Gate(), item = work("cancel"), id = UUID()
        defer { gate.release.signal() }
        let store = CreativeWorkStore(directory: directory.url, fileOperations: .init(syncInterceptor: { url in
            if url.lastPathComponent == "works.json" { try gate.block() }
        }))
        let write = Task { try await store.save(item, audioData: Data([3, 4]), operationID: id) }
        var entered = gate.entered.stream.makeAsyncIterator()
        _ = await entered.next()
        write.cancel()
        gate.release.signal()
        let saved = try await write.value
        #expect(saved.receipt.operationID == id)
        #expect(saved.receipt.committed)
        #expect(await store.receipt(operationID: id) == saved.receipt)
        #expect(try await store.list().map(\.id) == [item.id])
    }

    @Test
    func testConcurrentWritesRemainSerialized() async throws {
        let directory = Directory(), store = CreativeWorkStore(directory: directory.url)
        let first = work("first"), second = work("second")
        async let one = store.save(first, audioData: Data([1]), operationID: UUID())
        async let two = store.save(second, audioData: Data([2]), operationID: UUID())
        let saved = try await [one, two]
        #expect(saved.allSatisfy { $0.receipt.committed })
        #expect(Set(try await store.list().map(\.id)) == [first.id, second.id])
        #expect(try await store.loadAudio(for: first) == Data([1]))
        #expect(try await store.loadAudio(for: second) == Data([2]))
    }

    @Test
    func testReceiptHistoryIsBounded() async throws {
        let directory = Directory(), store = CreativeWorkStore(directory: directory.url)
        let item = work("receipts"), firstID = UUID()
        _ = try await store.save(item, audioData: Data([1]), operationID: firstID)
        var latestID = firstID
        for i in 0..<80 {
            latestID = UUID()
            _ = try await store.rename(item, title: "夹具 \(i)", operationID: latestID)
        }
        #expect(await store.receiptHistoryCount == 64)
        #expect(await store.receipt(operationID: firstID) == nil)
        #expect(await store.receipt(operationID: latestID)?.committed == true)
    }

    @Test
    func testInjectedDiskFailurePreservesRecoverableIndex() async throws {
        let directory = Directory(), item = work("retained")
        let seed = CreativeWorkStore(directory: directory.url)
        _ = try await seed.save(item, audioData: Data([1]), operationID: UUID())
        let failing = CreativeWorkStore(directory: directory.url, fileOperations: .init(writeInterceptor: { url, _ in
            if url.lastPathComponent == "works.json" { throw CocoaError(.fileWriteOutOfSpace) }
        }))
        await #expect(throws: (any Error).self) {
            try await failing.save(work("failed"), audioData: Data([2]), operationID: UUID())
        }
        let reopened = CreativeWorkStore(directory: directory.url)
        #expect(try await reopened.list().map(\.id) == [item.id])
        #expect(try await reopened.loadAudio(for: item) == Data([1]))
    }

    private func project(_ id: String = "project") -> DubbingProject {
        .init(id: id, title: "夹具项目", scriptText: "合成测试文本", recipe: .legacyUnknown,
              segments: [.init(id: "segment", text: "合成测试文本")])
    }

    @Test @MainActor
    func testCancelledBeforeAcceptanceDoesNotCreateACommit() async throws {
        let directory = Directory(), id = UUID(), item = work("not_accepted")
        let store = CreativeWorkStore(directory: directory.url)
        #expect(!FileManager.default.fileExists(atPath: directory.url.path))
        let write = Task { try await store.save(item, audioData: Data([1]), operationID: id) }
        write.cancel()
        await #expect(throws: CancellationError.self) { try await write.value }
        #expect(await store.receipt(operationID: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.url.path))
    }

    @Test @MainActor
    func testDubbingCancelAtCommitReturnsActualReceipt() async throws {
        let directory = Directory(), gate = Gate(), id = UUID(), item = project()
        defer { gate.release.signal() }
        let store = DubbingProjectStore(directory: directory.url, fileOperations: .init(syncInterceptor: { url in
            if url.lastPathComponent == "projects.json" { try gate.block() }
        }))
        let write = Task { try await store.save(item, operationID: id) }
        var entered = gate.entered.stream.makeAsyncIterator()
        _ = await entered.next()
        #expect(!gate.mainThread.withLock { $0 })
        write.cancel()
        gate.release.signal()
        let result = try await write.value
        #expect(result.receipt.committed)
        #expect(await store.receipt(operationID: id) == result.receipt)
        #expect(try await store.list().map(\.id) == [item.id])
    }

    @Test @MainActor
    func testCloseViewDoesNotLeaveOrphanCommit() async throws {
        let directory = Directory(), gate = Gate()
        defer { gate.release.signal() }
        let projects = DubbingProjectStore(directory: directory.url.appendingPathComponent("projects"),
            fileOperations: .init(syncInterceptor: { url in
                if url.lastPathComponent == "projects.json" { try gate.block() }
            }))
        let model = AppModel(
            transport: ClosureControlTransport { request in
                ControlResponse(requestID: request.requestID, command: request.command, status: .completed)
            }, apiClient: StoreDiagnosticsStub(),
            workStore: CreativeWorkStore(directory: directory.url.appendingPathComponent("works")),
            dubbingProjectStore: projects
        )
        let source = work("source")
        let opening = Task { await model.startDubbingProject(for: source) }
        var entered = gate.entered.stream.makeAsyncIterator()
        _ = await entered.next()
        model.closeDubbingProject()
        opening.cancel()
        gate.release.signal()
        let committed = try #require(await opening.value)
        #expect(model.dubbingProject == nil)
        #expect(model.dubbingWorkflow.lastStoreReceipt?.committed == true)
        #expect(try await projects.list().map(\.id) == [committed.id])
        #expect(await model.openDubbingProject(committed.id))
        #expect(model.dubbingProject?.id == committed.id)
        model.closeDubbingProject()
    }

    @Test
    func testPostCommitValidationErrorStillReportsCommittedReceipt() async throws {
        let directory = Directory(), item = work("validation"), id = UUID(), root = directory.url
        let store = CreativeWorkStore(directory: root, fileOperations: .init(syncInterceptor: { url in
            if url.lastPathComponent == "works.json" {
                try Data([9]).write(to: root.appendingPathComponent(item.audioFileName))
            }
        }))
        await #expect(throws: CreativeWorkStoreError.self) {
            try await store.save(item, audioData: Data([1]), operationID: id)
        }
        let receipt = try #require(await store.receipt(operationID: id))
        #expect(receipt.committed)
        #expect(receipt.indexDigest == CreativeWorkTransaction.digest(try Data(contentsOf: root.appendingPathComponent("works.json"))))
        await #expect(throws: CreativeWorkStoreError.self) { try await store.list() }
    }

    @Test
    func testDubbingCleanupErrorStillReportsCommittedReceipt() async throws {
        let directory = Directory(), root = directory.url, item = project()
        let seed = DubbingProjectStore(directory: root)
        _ = try await seed.save(item, operationID: UUID())
        let candidate = DubbingCandidate(id: "candidate", segmentID: "segment", text: "合成测试文本",
            audioFileName: "candidate.wav", provenance: .legacyUnknown)
        _ = try await seed.addCandidate(candidate, audioData: Data([1]), toProject: item.id, operationID: UUID())
        let failing = DubbingProjectStore(directory: root, fileOperations: .init(removeInterceptor: { url in
            if url.pathExtension == "wav" { throw CocoaError(.fileWriteNoPermission) }
        }))
        let id = UUID()
        await #expect(throws: DubbingProjectError.self) {
            try await failing.deleteCandidate(candidate.id, fromProject: item.id, operationID: id)
        }
        #expect(await failing.receipt(operationID: id)?.committed == true)
        let reopened = DubbingProjectStore(directory: root)
        #expect(try await reopened.candidates(forProject: item.id).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate.audioFileName).path))
    }

}

private struct StoreDiagnosticsStub: ServiceDiagnosticsClient {
    var port: Int? { nil }
    func fetchHealthSnapshot() async throws -> HealthSnapshot { throw ServiceAPIClientError.requestFailed }
    func fetchMetrics() async throws -> RuntimeMetricsSnapshot { throw ServiceAPIClientError.requestFailed }
}
