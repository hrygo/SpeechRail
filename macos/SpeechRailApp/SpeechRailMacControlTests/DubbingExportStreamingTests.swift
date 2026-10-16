import Foundation
import Synchronization
import Testing
import SpeechRailControlKit
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

@Suite(.timeLimit(.minutes(1)))
struct DubbingExportStreamingTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func wav(_ value: UInt8, frames: Int = 200_000, rate: Int = 24_000) throws -> Data {
        try DubbingAudioExport.makeWAV(from: [.init(pcm: Data(repeating: value, count: frames * 2),
            format: .init(sampleRate: rate, channels: 1, bitsPerSample: 16))])
    }
    @Test func testStreamingWAVMatchesReferencePCMAndReadBound() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let inputs = [directory.appendingPathComponent("a.wav"), directory.appendingPathComponent("b.wav")]
        try wav(7).write(to: inputs[0]); try wav(9).write(to: inputs[1])
        let largestRead = Mutex(0)
        let output = directory.appendingPathComponent("out.wav")
        let bytes = try DubbingStreamingWAV.write(inputs: inputs, output: output, onRead: { count in
            largestRead.withLock { $0 = max($0, count) }
        })
        let result = try DubbingAudioExport.clip(fromWAV: Data(contentsOf: output))
        #expect(result.pcm == Data(repeating: 7, count: 400_000) + Data(repeating: 9, count: 400_000))
        #expect(bytes == 800_044)
        #expect(largestRead.withLock { $0 } <= 262_144)
    }
    @Test func testFormatMismatchAndRIFFOverflowFailBeforePublishing() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let a = directory.appendingPathComponent("a.wav"), b = directory.appendingPathComponent("b.wav")
        let output = directory.appendingPathComponent("out.wav")
        try wav(1, rate: 16_000).write(to: a); try wav(2).write(to: b)
        #expect(throws: DubbingProjectError.audioFormatMismatch) { try DubbingStreamingWAV.write(inputs: [a,b], output: output) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(throws: DubbingExportError.riffOverflow) { try DubbingStreamingWAV.validatePCMSize(UInt64(UInt32.max) - 35) }
    }
    @Test func testCopyNeverReadsMoreThan256KiBAndReportsBothCommits() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let prepared = try exportFixture(directory)
        let largestRead = Mutex(0)
        let writer = DubbingExportWriter(onRead: { count in largestRead.withLock { $0 = max($0, count) } })
        let audio = directory.appendingPathComponent("saved.wav"), script = directory.appendingPathComponent("saved.txt")
        let receipt = try await writer.copyPrepared(prepared, audioDestination: audio, scriptDestination: script)
        #expect(receipt.audioCommitted && receipt.scriptCommitted)
        #expect(try Data(contentsOf: audio) == Data(contentsOf: prepared.audioURL))
        #expect(largestRead.withLock { $0 } <= 262_144)
        #expect(await writer.activeFileHandles == 0)
    }
    @Test @MainActor func testSlowExportCopyDoesNotBlockMainActorAndCancellationPreservesDestination() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let prepared = try exportFixture(directory), gate = ExportCopyGate()
        let writer = DubbingExportWriter(beforePublish: { _ in try gate.block() })
        let destination = directory.appendingPathComponent("saved.wav")
        let original = Data("existing".utf8); try original.write(to: destination)
        let task = Task { try await writer.copyPrepared(prepared, audioDestination: destination,
            scriptDestination: directory.appendingPathComponent("saved.txt")) }
        while !gate.entered.withLock({ $0 }) { await Task.yield() }
        #expect(!gate.wasMainThread.withLock { $0 })
        task.cancel(); gate.release.signal()
        do { _ = try await task.value; Issue.record("cancelled copy published") } catch {}
        #expect(try Data(contentsOf: destination) == original)
        #expect(await writer.activeFileHandles == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".speechrail-export-") })
    }
    @Test func testFailureOfSecondDestinationReportsPartialSuccess() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let prepared = try exportFixture(directory), writer = DubbingExportWriter()
        let audio = directory.appendingPathComponent("saved.wav"), script = directory.appendingPathComponent("saved.txt")
        try FileManager.default.createDirectory(at: script, withIntermediateDirectories: true)
        do { _ = try await writer.copyPrepared(prepared, audioDestination: audio, scriptDestination: script); Issue.record("expected partial failure") }
        catch let error as ExportCopyFailure {
            #expect(error.receipt.audioCommitted && !error.receipt.scriptCommitted)
        }
        #expect(FileManager.default.fileExists(atPath: audio.path))
        #expect(await writer.activeFileHandles == 0)
    }
    @Test func testOnlyOneExportLeaseAndReleaseRemovesTemporaryFiles() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = DubbingProjectStore(directory: directory)
        let provenance = RenderProvenanceSnapshot(state: .verified, reason: nil,
            recipe: RenderRecipeSnapshot(state: .complete, missingFields: [], digest: "recipe", voiceID: "fixture"))
        let project = DubbingProject(id: "fixture", title: "fixture", scriptText: "synthetic", recipe: provenance,
            segments: [.init(id: "segment", text: "synthetic")])
        _ = try await store.save(project, operationID: UUID())
        let candidate = DubbingCandidate(id: "candidate", segmentID: "segment", text: "synthetic", audioFileName: "candidate.wav", provenance: provenance)
        _ = try await store.addCandidate(candidate, audioData: wav(4), toProject: project.id, operationID: UUID())
        _ = try await store.adopt(candidateID: candidate.id, inSegment: "segment", ofProject: project.id, operationID: UUID())
        let prepared = try await store.prepareExport(projectID: project.id)
        do { _ = try await store.prepareExport(projectID: project.id); Issue.record("accepted a second lease") }
        catch { #expect(error as? DubbingExportError == .exportBusy) }
        try await store.releaseExport(leaseID: prepared.leaseID)
        #expect(!FileManager.default.fileExists(atPath: prepared.audioURL.path))
        let again = try await store.prepareExport(projectID: project.id)
        try await store.releaseExport(leaseID: again.leaseID)
    }
    @Test @MainActor func testPreviewUsesURLAndSharedRequestCannotResumeAfterStopOrOtherOwner() throws {
        let driver = ExportPlaybackDriver(), playback = SharedPlaybackOwner(driver: driver)
        let url = URL(fileURLWithPath: "/nonexistent-synthetic-preview.wav")
        let late = playback.beginPlaybackRequest()
        playback.stop()
        try playback.play(fileURL: url, target: .work("old"), requestID: late)
        #expect(driver.urls.isEmpty)
        let older = playback.beginPlaybackRequest()
        try playback.play(data: Data([1]), target: .voice("new"))
        try playback.play(fileURL: url, target: .work("old"), requestID: older)
        #expect(playback.target == .voice("new"))
        #expect(driver.urls.isEmpty)
        let current = playback.beginPlaybackRequest()
        try playback.play(fileURL: url, target: .work("current"), requestID: current)
        #expect(driver.urls == [url])
        #expect(driver.dataPlays == 1)
        playback.stop()
    }
    @Test func testMissingCandidateFailsWithoutSilenceAndPrepareCancellationLeavesNoLease() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = DubbingProjectStore(directory: directory)
        let provenance = RenderProvenanceSnapshot(state: .verified, reason: nil,
            recipe: RenderRecipeSnapshot(state: .complete, missingFields: [], digest: "recipe", voiceID: "fixture"))
        let project = DubbingProject(id: "fixture", title: "fixture", scriptText: "synthetic", recipe: provenance,
            segments: [.init(id: "segment", text: "synthetic")])
        _ = try await store.save(project, operationID: UUID())
        let candidate = DubbingCandidate(id: "candidate", segmentID: "segment", text: "synthetic", audioFileName: "candidate.wav", provenance: provenance)
        let data = try wav(4)
        _ = try await store.addCandidate(candidate, audioData: data, toProject: project.id, operationID: UUID())
        _ = try await store.adopt(candidateID: candidate.id, inSegment: "segment", ofProject: project.id, operationID: UUID())
        let audio = directory.appendingPathComponent("candidate.wav")
        try FileManager.default.removeItem(at: audio)
        await #expect(throws: (any Error).self) { try await store.prepareExport(projectID: project.id) }
        try data.write(to: audio)
        let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await store.prepareExport(projectID: project.id) }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let prepared = try await store.prepareExport(projectID: project.id)
        try await store.releaseExport(leaseID: prepared.leaseID)
        #expect(!FileManager.default.fileExists(atPath: prepared.scriptURL.path))
    }
    private func exportFixture(_ directory: URL) throws -> PreparedDubbingExport {
        let audio = directory.appendingPathComponent("source.wav"), script = directory.appendingPathComponent("source.txt")
        let data = try wav(3); try data.write(to: audio); try Data("synthetic".utf8).write(to: script)
        return .init(leaseID: UUID(), audioURL: audio, scriptURL: script, sourceRevision: "fixture", audioBytes: UInt64(data.count), baseName: "fixture")
    }
}
private final class ExportCopyGate: Sendable {
    let entered = Mutex(false), wasMainThread = Mutex(false)
    let release = DispatchSemaphore(value: 0)
    func block() throws {
        wasMainThread.withLock { $0 = Thread.isMainThread }; entered.withLock { $0 = true }
        if Thread.isMainThread { throw DubbingExportError.invalidWAV }
        release.wait()
    }
}

@MainActor private final class ExportPlaybackDriver: SharedAudioPlaybackDriver {
    var isPlaying = false
    var urls: [URL] = []
    var dataPlays = 0
    var onPlaybackFinished: (@MainActor (Bool) -> Void)?
    var onProgress: (@MainActor (Double) -> Void)?
    var onLevel: (@MainActor (Float) -> Void)?
    func play(data: Data) throws { dataPlays += 1; isPlaying = true }
    func play(fileURL: URL, startAt: TimeInterval, rate: Float) throws { urls.append(fileURL); isPlaying = true }
    func stop() { isPlaying = false }
    func duration(for data: Data) -> TimeInterval? { nil }
}
