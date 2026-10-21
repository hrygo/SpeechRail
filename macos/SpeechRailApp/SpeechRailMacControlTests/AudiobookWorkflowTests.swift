import Foundation
import SQLite3
import SpeechRailControlKit
import XCTest
import Synchronization
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

@MainActor
final class AudiobookWorkflowTests: XCTestCase {
    private final class WorkCounter: Sendable {
        let value = Mutex(0)
        func increment() -> Int { value.withLock { $0 += 1; return $0 } }
        var count: Int { value.withLock { $0 } }
    }

    nonisolated(unsafe) private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiobookWorkflowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    @MainActor
    private final class FakeDriver: SharedAudioPlaybackDriver {
        var isPlaying = false
        var playedFileURLs: [URL] = []
        var onPlaybackFinished: (@MainActor (Bool) -> Void)?
        var onProgress: (@MainActor (Double) -> Void)?
        var onLevel: (@MainActor (Float) -> Void)?

        func play(data: Data) throws { isPlaying = true }
        func play(fileURL: URL, startAt: TimeInterval, rate: Float) throws {
            playedFileURLs.append(fileURL)
            isPlaying = true
        }
        func pause() { isPlaying = false }
        func resume() throws { isPlaying = true }
        func seek(to time: TimeInterval) {}
        func setRate(_ rate: Float) {}
        func stop() { isPlaying = false }
        func duration(for data: Data) -> TimeInterval? { 5.0 }
    }

    @MainActor
    private final class WorkflowLoadGate {
        let suspended = XCTestExpectation(description: "workflow checkpoint suspended")
        let resumed = XCTestExpectation(description: "workflow checkpoint resumed")
        private var continuation: CheckedContinuation<Void, Never>?

        func suspend() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                suspended.fulfill()
            }
            resumed.fulfill()
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    private final class WorkflowFakeVoiceQualityClient: SpeechRailVoiceQualityClient, @unchecked Sendable {
        private let lock = NSLock()
        private var requested: [String] = []
        private var failing: Set<String> = []
        private let onValidated: (@Sendable (String) -> Void)?

        init(failing: Set<String> = [], onValidated: (@Sendable (String) -> Void)? = nil) {
            self.failing = failing
            self.onValidated = onValidated
        }

        var requestedVoiceIDs: [String] { lock.withLock { requested } }

        func runVoiceQuality(id: String, request: VoiceQualityRunRequest) async throws -> VoiceQualityRunResponse {
            lock.withLock { requested.append(id) }
            if lock.withLock({ failing.contains(id) }) {
                throw ServiceAPIClientError.requestFailed
            }
            onValidated?(id)
            return VoiceQualityRunResponse(
                legacyReport: VoiceQualityReportSnapshotV2(
                    status: .pass,
                    runID: "vq_0123456789abcdef0123456789abcdef"
                ),
                validationPersisted: true
            )
        }
    }

    private final class WorkflowFakeRenderer: AudiobookSpeechRenderer, @unchecked Sendable {
        private let beforeRender: (@Sendable () async -> Void)?
        private let leadLock = NSLock()
        private var leadRequests = 0
        var leadRequestCount: Int { leadLock.withLock { leadRequests } }
        private var capturedVoiceRequests: [AudiobookLeadVoiceCreationRequest] = []
        var voiceCreationRequests: [AudiobookLeadVoiceCreationRequest] { leadLock.withLock { capturedVoiceRequests } }
        private var fragmentRequests = 0
        var fragmentRequestCount: Int { leadLock.withLock { fragmentRequests } }
        private var capturedAuditions: [AudiobookRenderCallRequest] = []
        var auditionRequests: [AudiobookRenderCallRequest] { leadLock.withLock { capturedAuditions } }

        var auditionRenderHandler: (@Sendable (AudiobookRenderCallRequest) async throws -> Data)?
        var beforeCapabilityFetch: (@Sendable () async -> Void)?

        func renderAudition(_ request: AudiobookRenderCallRequest) async throws -> Data {
            leadLock.withLock { capturedAuditions.append(request) }
            if let handler = auditionRenderHandler {
                return try await handler(request)
            }
            return Self.makeWAV(frameCount: 4_800)
        }

        init(beforeRender: (@Sendable () async -> Void)? = nil) {
            self.beforeRender = beforeRender
        }

        var leadVoiceCreationHandler: (@Sendable (AudiobookLeadVoiceCreationRequest, Int) async throws -> AudiobookLeadVoiceCreationOutput)?

        private var dynamicVoices: [SafeVoiceEntry] = []
        private var modelRevisionValue = String(repeating: "a", count: 40)
        private var voicesProductionReady = true

        /// Drops (or restores) the stored output evidence for every fixed voice, the way
        /// a runtime upgrade invalidates validation recorded against an older engine.
        func setVoicesProductionReady(_ ready: Bool) {
            leadLock.withLock { voicesProductionReady = ready }
        }

        /// Moves the artifact revision without touching any voice identity, the way a
        /// runtime upgrade changes the engine while every locked voice stays the same.
        func setModelRevision(_ value: String) {
            leadLock.withLock { modelRevisionValue = value }
        }

        func createAndPublishLeadVoice(_ request: AudiobookLeadVoiceCreationRequest) async throws -> AudiobookLeadVoiceCreationOutput {
            let count = leadLock.withLock {
                leadRequests += 1
                capturedVoiceRequests.append(request)
                return leadRequests
            }
            let output: AudiobookLeadVoiceCreationOutput
            if let handler = leadVoiceCreationHandler {
                output = try await handler(request, count)
            } else {
                output = .init(voiceID: "v-designed-narrator", voiceName: "设计旁白",
                    voiceRevision: "vr_0123456789abcdef0123456789abcdef", modelRevision: String(repeating: "a", count: 40))
            }
            leadLock.withLock {
                let model = ConfiguredModelIdentity(
                    assurance: .configuredCatalog,
                    runtimeRevision: output.modelRevision,
                    catalogRevision: output.modelRevision
                )
                let desc = SafeVoiceDescriptor(
                    voiceMode: "instruction",
                    locales: ["zh-CN"],
                    styleTags: [],
                    pitchBand: "unknown",
                    timbreFamily: "unknown",
                    baselinePace: "unknown",
                    sourceType: "instruction_profile",
                    metadataMethod: "declared_only"
                )
                dynamicVoices.removeAll { $0.id == output.voiceID }
                dynamicVoices.append(SafeVoiceEntry(
                    id: output.voiceID,
                    name: output.voiceName,
                    mode: "clone",
                    available: true,
                    availabilityReason: .available,
                    voiceRevision: output.voiceRevision,
                    voiceIdentityAssurance: .contentAddressed,
                    model: model,
                    descriptors: desc,
                    operations: ["http_speech": JSONValue(.object(["parameters": JSONValue(.object(["speed": JSONValue(.object(["status": JSONValue(.string("supported")), "minimum": JSONValue(.number(0.25)), "maximum": JSONValue(.number(4))]))]))]))],
                    productionReady: true
                ))
            }
            return output
        }

        func fetchEffectiveCapabilities() async throws -> EffectiveCapabilitySnapshot {
            await beforeCapabilityFetch?()
            let desc = SafeVoiceDescriptor(
                voiceMode: "instruction",
                locales: ["zh-CN"],
                styleTags: [],
                pitchBand: "unknown",
                timbreFamily: "unknown",
                baselinePace: "unknown",
                sourceType: "instruction_profile",
                metadataMethod: "declared_only"
            )
            let revision = leadLock.withLock { modelRevisionValue }
            let productionReady = leadLock.withLock { voicesProductionReady }
            let model = ConfiguredModelIdentity(
                assurance: .configuredCatalog,
                runtimeRevision: revision,
                catalogRevision: revision
            )
            let dynamic = leadLock.withLock { dynamicVoices }
            return EffectiveCapabilitySnapshot(
                serviceInstanceEpoch: "e1",
                catalogRevision: "c1",
                snapshotID: "s1",
                profile: "quality",
                models: ["tts": model, "tts_clone": model],
                voices: [
                    SafeVoiceEntry(
                        id: "v-narrator",
                        name: "旁白",
                        mode: "system", isSystem: true, isDefault: true,
                        available: true,
                        availabilityReason: .available,
                        voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                        voiceIdentityAssurance: .contentAddressed,
                        model: model,
                        descriptors: desc,
                        operations: ["http_speech": JSONValue(.object(["parameters": JSONValue(.object(["speed": JSONValue(.object(["status": JSONValue(.string("supported")), "minimum": JSONValue(.number(0.25)), "maximum": JSONValue(.number(4))]))]))]))],
                        productionReady: productionReady
                    ),
                    SafeVoiceEntry(id: "v-designed-narrator", name: "设计旁白", mode: "clone", available: true,
                        availabilityReason: .available, voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                        voiceIdentityAssurance: .contentAddressed, model: model, descriptors: desc,
                        operations: ["http_speech": JSONValue(.object(["parameters": JSONValue(.object(["speed": JSONValue(.object(["status": JSONValue(.string("supported")), "values": JSONValue(.array([JSONValue(.number(1))]))]))]))]))], productionReady: true)
                ] + dynamic,
                operations: [:],
                guarantees: [:]
            )
        }

        func renderFragment(_ request: AudiobookRenderCallRequest) async throws -> AudiobookRenderCallOutput {
            leadLock.withLock { fragmentRequests += 1 }
            await beforeRender?()
            let wav = Self.makeWAV(frameCount: 4_800)
            return AudiobookRenderCallOutput(
                wavData: wav,
                voiceRevision: request.expectedVoiceRevision,
                modelRevision: request.expectedModelRevision,
                pcmSHA256: try AudioDigest.sha256HexOfPCM(in: wav),
                requestID: "req-wf",
                receiptID: "rr_0123456789abcdef0123456789abcdef",
                recipeSummary: "ok",
                isProvenanceVerified: true
            )
        }

        static func makeWAV(frameCount: Int) -> Data {
            let pcmBytes = frameCount * 2
            var data = Data(capacity: 44 + pcmBytes)
            data.append(contentsOf: "RIFF".utf8)
            var riffSize = UInt32(36 + pcmBytes).littleEndian
            data.append(Data(bytes: &riffSize, count: 4))
            data.append(contentsOf: "WAVEfmt ".utf8)
            var fmtSize = UInt32(16).littleEndian
            var fmt = UInt16(1).littleEndian
            var ch = UInt16(1).littleEndian
            var sr = UInt32(48_000).littleEndian
            var br = UInt32(96_000).littleEndian
            var align = UInt16(2).littleEndian
            var bps = UInt16(16).littleEndian
            data.append(Data(bytes: &fmtSize, count: 4))
            data.append(Data(bytes: &fmt, count: 2))
            data.append(Data(bytes: &ch, count: 2))
            data.append(Data(bytes: &sr, count: 4))
            data.append(Data(bytes: &br, count: 4))
            data.append(Data(bytes: &align, count: 2))
            data.append(Data(bytes: &bps, count: 2))
            data.append(contentsOf: "data".utf8)
            var dataSize = UInt32(pcmBytes).littleEndian
            data.append(Data(bytes: &dataSize, count: 4))
            data.append(Data(repeating: 0x08, count: pcmBytes))
            return data
        }
    }

    private actor WorkflowRendererGate {
        private var isSuspended = false
        private var wasCancelled = false
        private var continuation: CheckedContinuation<Void, Never>?

        func suspend() async {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                    isSuspended = true
                }
            } onCancel: {
                Task { await self.markCancelled() }
            }
        }

        func hasSuspended() -> Bool { isSuspended }
        func hasBeenCancelled() -> Bool { wasCancelled }
        private func markCancelled() { wasCancelled = true }

        func resume() {
            continuation?.resume()
            continuation = nil
            isSuspended = false
        }
    }

    private final class RecipeRecordingDesignClient: SpeechRailVoiceDesignClient, Sendable {
        struct Entry: Sendable { let text: String; let idempotencyKey: String? }
        let entries = Mutex<[Entry]>([])
        let cancels: Bool
        init(cancels: Bool = false) { self.cancels = cancels }
        func createVoiceDesignCandidate(voiceID: String, name: String, instruction: String,
            referenceText: String, seed: Int, idempotencyKey: String?) async throws -> VoiceDesignCandidate {
            entries.withLock { $0.append(.init(text: referenceText, idempotencyKey: idempotencyKey)) }
            if cancels { throw CancellationError() }
            throw ServiceAPIClientError.requestFailed
        }
        func createVoicePreview(text: String, instruction: String, speed: Double, seed: Int?) async throws -> Data { throw ServiceAPIClientError.requestFailed }
        func confirmVoiceDesignCandidate(id: String, referenceText: String?) async throws -> VoiceDesignCandidate { throw ServiceAPIClientError.requestFailed }
        func validateVoiceDesignCandidate(id: String, testText: String?, capabilityKey: String?, mode: VoiceDesignValidationMode) async throws -> VoiceDesignCandidate { throw ServiceAPIClientError.requestFailed }
        func fetchVoiceDesignCandidates() async throws -> [VoiceDesignCandidate] { throw ServiceAPIClientError.requestFailed }
        func fetchVoiceDesignCandidate(id: String) async throws -> VoiceDesignCandidate { throw ServiceAPIClientError.requestFailed }
        func fetchVoiceDesignReferenceAudio(id: String, expectedRevision: String) async throws -> Data { throw ServiceAPIClientError.requestFailed }
        func fetchVoiceDesignValidationAudio(id: String, validationID: String, expectedRevision: String) async throws -> Data { throw ServiceAPIClientError.requestFailed }
        func cancelVoiceDesignCandidate(id: String) async throws -> VoiceDesignCandidate { throw ServiceAPIClientError.requestFailed }
        func publishVoiceDesignCandidate(id: String, expectedCandidateRevision: String?) async throws -> VoiceDesignPublishResult { throw ServiceAPIClientError.requestFailed }
    }

    /// Replays completed idempotency keys, including cancelled candidates, like the service.
    private actor VoiceDesignLifecycleClient: SpeechRailVoiceDesignClient, ServiceCapabilityDiscoveryClient, SpeechRailVoiceQualityClient {
        struct Entry: Sendable { let voiceID: String; let seed: Int; let key: String? }
        private(set) var entries: [Entry] = []
        private var candidates: [String: VoiceDesignCandidate] = [:]
        private var candidateIDsByKey: [String: String] = [:]
        private var rejectedIDs: Set<String> = []
        private var rejectNextDesign: Bool
        private let publishedVoices = WorkflowFakeRenderer()
        private var hasPublished = false
        private var didHoldDiscovery = false
        private let postPublishGate: WorkflowRendererGate?
        private let revision = "vr_0123456789abcdef0123456789abcdef"
        private let requiresOutputCheck: Bool
        private let outputPersisted: Bool
        private let readyAfterOutputPass: Bool
        private var outputRejectsRemaining: Int
        private var validatedIDs: Set<String> = []
        private(set) var outputCheckIDs: [String] = []

        init(rejectNextDesign: Bool = false, postPublishGate: WorkflowRendererGate? = nil,
            requiresOutputCheck: Bool = false, outputRejectsRemaining: Int = 0,
            outputPersisted: Bool = true, readyAfterOutputPass: Bool = true) {
            self.rejectNextDesign = rejectNextDesign
            self.postPublishGate = postPublishGate
            self.requiresOutputCheck = requiresOutputCheck
            self.outputRejectsRemaining = outputRejectsRemaining
            self.outputPersisted = outputPersisted
            self.readyAfterOutputPass = readyAfterOutputPass
        }

        func createVoiceDesignCandidate(voiceID: String, name: String, instruction: String,
            referenceText: String, seed: Int, idempotencyKey: String?) async throws -> VoiceDesignCandidate {
            entries.append(.init(voiceID: voiceID, seed: seed, key: idempotencyKey))
            if let key = idempotencyKey, let id = candidateIDsByKey[key], let previous = candidates[id] { return previous }
            let id = "candidate_\(candidates.count)"
            let candidate = VoiceDesignCandidate(id: id, targetVoiceID: voiceID, name: name, state: "generated",
                revision: revision, publishedVoiceRevision: nil,
                reference: .init(audioSHA256: "synthetic", textSHA256: "synthetic", transcriptSHA256: "synthetic", durationSeconds: 5),
                validations: [], publishable: false)
            candidates[id] = candidate
            if let key = idempotencyKey { candidateIDsByKey[key] = id }
            if rejectNextDesign { rejectedIDs.insert(id); rejectNextDesign = false }
            return candidate
        }

        private func update(_ id: String, state: String, validations: [VoiceDesignValidation]? = nil) throws -> VoiceDesignCandidate {
            guard let old = candidates[id] else { throw ServiceAPIClientError.invalidResponse }
            let updated = VoiceDesignCandidate(id: id, targetVoiceID: old.targetVoiceID, name: old.name, state: state,
                revision: revision, publishedVoiceRevision: state == "published" ? revision : nil, reference: old.reference,
                validations: validations ?? old.validations, publishable: state == "publishable" || state == "published")
            candidates[id] = updated
            return updated
        }

        func confirmVoiceDesignCandidate(id: String, referenceText: String?) async throws -> VoiceDesignCandidate {
            guard candidates[id]?.knownState != .cancelled, candidates[id]?.knownState != .failed else {
                throw ServiceAPIClientError.invalidContract("voice_design_invalid_state")
            }
            return try update(id, state: "confirmed")
        }

        func validateVoiceDesignCandidate(id: String, testText: String?, capabilityKey: String?,
            mode: VoiceDesignValidationMode) async throws -> VoiceDesignCandidate {
            let rejected = rejectedIDs.contains(id)
            let accepted: Bool
            if case .automatedAcceptance = mode { accepted = true } else { accepted = false }
            let validation = VoiceDesignValidation(validationID: "validation_\(id)", candidateRevision: revision,
                status: rejected ? "reject" : "pass", machineStatus: rejected ? "reject" : "pass",
                identityStatus: .notReviewed, naturalnessStatus: .notReviewed, automatedAcceptance: accepted,
                failureCodes: rejected ? ["output_invalid"] : [], capabilityKey: "reference.render",
                modelArtifact: "synthetic", modelCatalogRevision: String(repeating: "a", count: 40),
                transcriptMatch: rejected ? 0.2 : 1, createdAt: 1, updatedAt: 1)
            return try update(id, state: rejected ? "failed" : (accepted ? "publishable" : "validating"), validations: [validation])
        }

        func cancelVoiceDesignCandidate(id: String) async throws -> VoiceDesignCandidate { try update(id, state: "cancelled") }

        func publishVoiceDesignCandidate(id: String, expectedCandidateRevision: String?) async throws -> VoiceDesignPublishResult {
            guard candidates[id]?.knownState == .publishable else { throw ServiceAPIClientError.invalidResponse }
            let published = try update(id, state: "published")
            publishedVoices.leadVoiceCreationHandler = { request, _ in
                .init(voiceID: request.targetVoiceID, voiceName: request.voiceName,
                    voiceRevision: "vr_0123456789abcdef0123456789abcdef", modelRevision: String(repeating: "a", count: 40))
            }
            _ = try await publishedVoices.createAndPublishLeadVoice(.init(bookID: UUID(), roleID: UUID(),
                targetVoiceID: published.targetVoiceID, voiceName: published.name, instruction: "合成测试声音",
                referenceTextCandidates: [], seed: 42))
            hasPublished = true
            return .init(candidate: published, voice: .init(id: published.targetVoiceID, name: published.name,
                available: true, revision: revision))
        }

        func fetchEffectiveCapabilities(ifNoneMatch: String?, cachedValue: EffectiveCapabilitySnapshot?) async throws -> ServiceConditionalResponse<EffectiveCapabilitySnapshot> {
            try Task.checkCancellation()
            if hasPublished, !didHoldDiscovery, let postPublishGate {
                didHoldDiscovery = true
                await postPublishGate.suspend()
            }
            try Task.checkCancellation()
            let snapshot = try await publishedVoices.fetchEffectiveCapabilities()
            guard requiresOutputCheck else { return .init(value: snapshot, metadata: .init(statusCode: 200)) }
            let publishedIDs = Set(candidates.values.filter { $0.knownState == .published }.map(\.targetVoiceID))
            var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
            payload["voices"] = (payload["voices"] as? [[String: Any]] ?? []).map { original in
                var voice = original
                if let id = voice["id"] as? String, publishedIDs.contains(id), !validatedIDs.contains(id) {
                    voice["production_ready"] = false
                    voice["production_ready_reason"] = "synthesis_validation_not_run"
                }
                return voice
            }
            let value = try JSONDecoder().decode(EffectiveCapabilitySnapshot.self, from: JSONSerialization.data(withJSONObject: payload))
            return .init(value: value, metadata: .init(statusCode: 200))
        }

        func runVoiceQuality(id: String, request: VoiceQualityRunRequest) async throws -> VoiceQualityRunResponse {
            outputCheckIDs.append(id)
            let rejected = outputRejectsRemaining > 0
            if rejected { outputRejectsRemaining -= 1 }
            // Advertise readiness optimistically even when this report was not
            // recorded: the workflow must still require its durable evidence.
            if !rejected, readyAfterOutputPass { validatedIDs.insert(id) }
            return .init(legacyReport: .init(status: rejected ? .reject : .pass,
                runID: "vq_0123456789abcdef0123456789abcdef"), validationPersisted: outputPersisted)
        }

        func fetchSafeVoices(ifNoneMatch: String?, cachedValue: SafeVoiceList?) async throws -> ServiceConditionalResponse<SafeVoiceList> { throw ServiceAPIClientError.requestFailed }
        func fetchReadiness() async throws -> ReadySnapshot { throw ServiceAPIClientError.requestFailed }
        func createVoicePreview(text: String, instruction: String, speed: Double, seed: Int?) async throws -> Data { throw ServiceAPIClientError.requestFailed }
        func fetchVoiceDesignCandidates() async throws -> [VoiceDesignCandidate] { Array(candidates.values) }
        func fetchVoiceDesignCandidate(id: String) async throws -> VoiceDesignCandidate {
            guard let candidate = candidates[id] else { throw ServiceAPIClientError.invalidResponse }
            return candidate
        }
        func fetchVoiceDesignReferenceAudio(id: String, expectedRevision: String) async throws -> Data { throw ServiceAPIClientError.requestFailed }
        func fetchVoiceDesignValidationAudio(id: String, validationID: String, expectedRevision: String) async throws -> Data { throw ServiceAPIClientError.requestFailed }
    }

    func testReviewedRecipeReachesDesignUnchangedAndHasDistinctIdempotency() async throws {
        let client = RecipeRecordingDesignClient()
        let renderer = AudiobookProductionWiring.LiveAudiobookSpeechRenderer(
            discoveryClient: UnavailableServiceCapabilityDiscoveryClient(), renderClient: ServiceAPIClient(),
            voiceDesignClient: client, voiceCatalog: VoiceCatalogStore())
        var request = AudiobookLeadVoiceCreationRequest(bookID: UUID(), roleID: UUID(), targetVoiceID: "ab_recipe_a",
            voiceName: "原声", instruction: "温暖的中文声音", referenceTextCandidates: ["海风轻轻吹过宁静的渡口，远处的灯光一点点亮了起来。"], seed: 42)
        _ = try? await renderer.createAndPublishLeadVoice(request)
        request.targetVoiceID = "ab_recipe_b"
        request.instruction = "清亮有力的中文声音"
        _ = try? await renderer.createAndPublishLeadVoice(request)
        let entries = client.entries.withLock { $0 }
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.text, request.referenceTextCandidates.first, "已确认的合法文稿不能再被隐藏追加或截断")
        XCTAssertNotEqual(entries[0].idempotencyKey, entries[1].idempotencyKey, "同角色不同物料不能复用旧候选")
    }

    func testVoiceDesignCancellationDoesNotStartNextCandidate() async throws {
        let client = RecipeRecordingDesignClient(cancels: true)
        let renderer = AudiobookProductionWiring.LiveAudiobookSpeechRenderer(
            discoveryClient: UnavailableServiceCapabilityDiscoveryClient(), renderClient: ServiceAPIClient(),
            voiceDesignClient: client, voiceCatalog: VoiceCatalogStore())
        let request = AudiobookLeadVoiceCreationRequest(bookID: UUID(), roleID: UUID(), targetVoiceID: "ab_cancel",
            voiceName: "旁白", instruction: "温暖的中文声音", referenceTextCandidates: ["第一份试听文稿", "第二份试听文稿"], seed: 42)
        do {
            _ = try await renderer.createAndPublishLeadVoice(request)
            XCTFail("取消应传播到批量任务")
        } catch is CancellationError {} catch { XCTFail("应保留取消语义") }
        XCTAssertEqual(client.entries.withLock { $0.count }, 1)
    }

    func testBatchQualityFailureCreatesFreshCandidateWhenRetried() async throws {
        let client = VoiceDesignLifecycleClient(rejectNextDesign: true), catalog = VoiceCatalogStore()
        let renderer = AudiobookProductionWiring.LiveAudiobookSpeechRenderer(discoveryClient: client,
            renderClient: ServiceAPIClient(), voiceDesignClient: client, voiceCatalog: catalog)
        let (workflow, _) = makeWorkflow(renderer: renderer, catalog: catalog)
        _ = try await importBook(into: workflow, fileName: "quality-retry.txt", text: "第一章\n海风吹来。")
        await workflow.prepareVoiceCreationDrafts()
        await workflow.createSelectedVoiceDrafts()
        XCTAssertTrue(workflow.voiceCreationDrafts.first?.status.isFailure == true)

        await workflow.createSelectedVoiceDrafts(retryFailuresOnly: true)

        let entries = await client.entries
        XCTAssertEqual(entries.count, 2)
        XCTAssertNotEqual(entries[0].key, entries[1].key, "终止失败不能重放已经取消的候选")
        XCTAssertNotEqual(entries[0].seed, entries[1].seed, "质量失败重试需要新候选")
        XCTAssertTrue(workflow.voiceCreationDrafts.first?.status.isCreated == true)
        await workflow.createSelectedVoiceDrafts(retryFailuresOnly: true)
        let finalCount = await client.entries.count
        XCTAssertEqual(finalCount, 2, "成功后不再创建")
    }

    func testBatchCancellationAfterPublicationStillRegistersCompletedVoice() async throws {
        let gate = WorkflowRendererGate(), catalog = VoiceCatalogStore()
        let client = VoiceDesignLifecycleClient(postPublishGate: gate)
        let renderer = AudiobookProductionWiring.LiveAudiobookSpeechRenderer(discoveryClient: client,
            renderClient: ServiceAPIClient(), voiceDesignClient: client, voiceCatalog: catalog)
        let (workflow, _) = makeWorkflow(renderer: renderer, catalog: catalog)
        let imported = try await importBook(into: workflow, fileName: "published-cancel.txt", text: "第一章\n海风吹来。")
        await workflow.prepareVoiceCreationDrafts()
        let voiceID = try XCTUnwrap(workflow.voiceCreationDrafts.first?.request.targetVoiceID)
        let creation = Task { await workflow.createSelectedVoiceDrafts() }
        await waitForRenderSuspension(gate)
        workflow.cancelVoiceDraftCreation()
        await gate.resume()
        await creation.value

        let snapshot = await catalog.refresh()
        XCTAssertEqual(snapshot.state.metadataByVoiceID[voiceID]?.originBookID, imported.bookID)
        XCTAssertTrue(workflow.voiceCreationDrafts.first?.status.isCreated == true)
        XCTAssertTrue(workflow.voiceBindings.isEmpty, "停止后只保留资产，不自动绑定")
    }

    func testBatchPublishedVoiceRunsOutputCheckBeforeBinding() async throws {
        let client = VoiceDesignLifecycleClient(requiresOutputCheck: true), catalog = VoiceCatalogStore()
        let renderer = AudiobookProductionWiring.LiveAudiobookSpeechRenderer(discoveryClient: client,
            renderClient: ServiceAPIClient(), voiceDesignClient: client, voiceCatalog: catalog)
        let (workflow, _) = makeWorkflow(renderer: renderer, catalog: catalog, voiceValidationClient: client)
        _ = try await importBook(into: workflow, fileName: "output-check.txt", text: "第一章\n海风吹来。")
        await workflow.prepareVoiceCreationDrafts()
        let voiceID = try XCTUnwrap(workflow.voiceCreationDrafts.first?.request.targetVoiceID)

        await workflow.createSelectedVoiceDrafts()

        let checks = await client.outputCheckIDs
        XCTAssertEqual(checks, [voiceID], "发布可路由的声音后仍需完成输出验收")
        XCTAssertTrue(workflow.voiceCreationDrafts.first?.status.isCreated == true)
        XCTAssertEqual(workflow.voiceBindings.values.first?.voiceID, voiceID)
        XCTAssertNil(workflow.chapters.first?.currentChapterRevisionID, "创建音色不启动章节制作")
    }

    func testBatchOutputFailureKeepsAssetAndRetriesWithoutRegeneration() async throws {
        let client = VoiceDesignLifecycleClient(requiresOutputCheck: true, outputRejectsRemaining: 1)
        let catalog = VoiceCatalogStore()
        let persistedStore = try AudiobookProjectStore(root: tempRoot)
        let renderer = AudiobookProductionWiring.LiveAudiobookSpeechRenderer(discoveryClient: client,
            renderClient: ServiceAPIClient(), voiceDesignClient: client, voiceCatalog: catalog)
        let (workflow, _) = makeWorkflow(renderer: renderer, store: persistedStore, catalog: catalog, voiceValidationClient: client)
        let book = try await importBook(into: workflow, fileName: "output-retry.txt", text: "第一章\n海风吹来。")
        await workflow.prepareVoiceCreationDrafts()
        let voiceID = try XCTUnwrap(workflow.voiceCreationDrafts.first?.request.targetVoiceID)
        await workflow.createSelectedVoiceDrafts()

        let assets = await catalog.refresh()
        XCTAssertEqual(assets.state.metadataByVoiceID[voiceID]?.originBookID, book.bookID)
        XCTAssertTrue(workflow.voiceCreationDrafts.first?.status.isCreated == true, "输出失败不能把已发布的声音报为未创建")
        XCTAssertTrue(workflow.voiceCreationDrafts.first?.status.isFailure == true)
        XCTAssertTrue(workflow.voiceBindings.isEmpty)
        XCTAssertEqual(workflow.voiceCreationDrafts.first?.generationAttempt, 0)
        let intents = try await persistedStore.voiceRegistrationIntents(bookID: book.bookID, includeCompleted: true)
        XCTAssertEqual(intents.count, 1)
        XCTAssertNil(intents.first?.binding, "检查未通过时只能记录资产，不能留下恢复时可自动应用的绑定意图")
        let restoredController = AudiobookCastController(store: persistedStore, capabilityProvider: {
            try await renderer.fetchEffectiveCapabilities()
        }, voiceCatalog: catalog)
        try await restoredController.recoverVoiceRegistrations(bookID: book.bookID)
        let restoredBindings = try await persistedStore.voiceBindings(for: book.bookID)
        XCTAssertTrue(restoredBindings.isEmpty)
        let otherRole = AudiobookCharacter(bookID: book.bookID, displayName: "另一个角色")
        try await persistedStore.upsertCharacter(otherRole)
        let otherBinding = AudiobookVoiceBinding(roleID: otherRole.id, voiceID: "v-narrator",
            voiceRevision: nil, modelRevision: String(repeating: "a", count: 40))
        try await persistedStore.saveVoiceBinding(bookID: book.bookID, binding: otherBinding)

        await workflow.createSelectedVoiceDrafts(retryFailuresOnly: true)

        let entries = await client.entries, checks = await client.outputCheckIDs
        XCTAssertEqual(entries.count, 1, "重试检查必须复用已发布声音")
        XCTAssertEqual(checks, [voiceID, voiceID])
        XCTAssertFalse(workflow.voiceCreationDrafts.first?.status.isFailure == true)
        XCTAssertTrue(workflow.voiceBindings.values.contains { $0.voiceID == voiceID })
    }

    func testBatchUnrecordedOutputPassDoesNotBind() async throws {
        let client = VoiceDesignLifecycleClient(requiresOutputCheck: true, outputPersisted: false)
        let catalog = VoiceCatalogStore()
        let renderer = AudiobookProductionWiring.LiveAudiobookSpeechRenderer(discoveryClient: client,
            renderClient: ServiceAPIClient(), voiceDesignClient: client, voiceCatalog: catalog)
        let (workflow, _) = makeWorkflow(renderer: renderer, catalog: catalog, voiceValidationClient: client)
        _ = try await importBook(into: workflow, fileName: "output-unrecorded.txt", text: "第一章\n海风吹来。")
        await workflow.prepareVoiceCreationDrafts()
        await workflow.createSelectedVoiceDrafts()

        let checks = await client.outputCheckIDs
        XCTAssertEqual(checks.count, 1)
        XCTAssertTrue(workflow.voiceCreationDrafts.first?.status.isCreated == true)
        XCTAssertTrue(workflow.voiceCreationDrafts.first?.status.title.contains("保存") == true)
        XCTAssertTrue(workflow.voiceBindings.isEmpty, "没有持久化检查证据不能应用声音")
    }

    func testBatchOutputPassRequiresFreshProductionReadiness() async throws {
        let client = VoiceDesignLifecycleClient(requiresOutputCheck: true, readyAfterOutputPass: false)
        let catalog = VoiceCatalogStore()
        let renderer = AudiobookProductionWiring.LiveAudiobookSpeechRenderer(discoveryClient: client,
            renderClient: ServiceAPIClient(), voiceDesignClient: client, voiceCatalog: catalog)
        let (workflow, _) = makeWorkflow(renderer: renderer, catalog: catalog, voiceValidationClient: client)
        _ = try await importBook(into: workflow, fileName: "output-not-ready.txt", text: "第一章\n海风吹来。")
        await workflow.prepareVoiceCreationDrafts()
        await workflow.createSelectedVoiceDrafts()

        let checks = await client.outputCheckIDs
        XCTAssertEqual(checks.count, 1)
        XCTAssertTrue(workflow.voiceCreationDrafts.first?.status.isCreated == true)
        XCTAssertTrue(workflow.voiceCreationDrafts.first?.status.isFailure == true)
        XCTAssertTrue(workflow.voiceBindings.isEmpty, "报告通过不能替代当前正式制作准入")
    }

    func testBatchEnsembleOutputRetrySurvivesOtherRoleBinding() async throws {
        let client = VoiceDesignLifecycleClient(requiresOutputCheck: true, outputRejectsRemaining: 1)
        let catalog = VoiceCatalogStore(), store = try AudiobookProjectStore(root: tempRoot)
        let renderer = AudiobookProductionWiring.LiveAudiobookSpeechRenderer(discoveryClient: client,
            renderClient: ServiceAPIClient(), voiceDesignClient: client, voiceCatalog: catalog)
        let (workflow, _) = makeWorkflow(renderer: renderer, store: store, catalog: catalog, voiceValidationClient: client)
        let roles = try await prepareAutomaticCastingBook(workflow: workflow, store: store, roleCount: 4)
        await workflow.prepareVoiceCreationDrafts()
        let ensemble = try XCTUnwrap(workflow.voiceCreationDrafts.first { if case .ensemble = $0.target { true } else { false } })
        for var draft in workflow.voiceCreationDrafts {
            draft.isSelected = draft.id == ensemble.id
            workflow.updateVoiceCreationDraft(draft)
        }
        await workflow.createSelectedVoiceDrafts()
        XCTAssertTrue(workflow.voiceCreationDrafts.first { $0.id == ensemble.id }?.status.isFailure == true)
        let narrator = try XCTUnwrap(roles.first(where: \.isNarrator))
        try await store.saveVoiceBinding(bookID: ensemble.bookID, binding: .init(roleID: narrator.id,
            voiceID: "v-narrator", voiceRevision: nil, modelRevision: String(repeating: "a", count: 40)))

        await workflow.createSelectedVoiceDrafts(retryFailuresOnly: true)

        let checks = await client.outputCheckIDs, entries = await client.entries
        XCTAssertEqual(checks, [ensemble.request.targetVoiceID, ensemble.request.targetVoiceID])
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(workflow.voiceCreationDrafts.first { $0.id == ensemble.id }?.status.isComplete == true)
        XCTAssertEqual(workflow.voiceBindings[narrator.id]?.voiceID, "v-narrator")
    }

    private func makeWorkflow(
        driver: FakeDriver = FakeDriver(),
        renderer: any AudiobookSpeechRenderer = WorkflowFakeRenderer(),
        store: AudiobookProjectStore? = nil,
        catalog: VoiceCatalogStore = VoiceCatalogStore(),
        voiceValidationClient: (any SpeechRailVoiceQualityClient)? = nil
    ) -> (AudiobookWorkflowModel, FakeDriver) {
        let root = tempRoot!
        let config = LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "test-model")
        let deps = AudiobookDependencies(
            makeStore: {
                if let store { return store }
                return try AudiobookProjectStore(root: root)
            },
            makeAnalysisClient: { snap in
                throw AudiobookAnalysisError.notConfigured
            },
            resolveAnalysisSnapshot: { gen in
                AudiobookAnalysisConfigSnapshot(configuration: config, generation: gen)
            },
            speechRenderer: renderer,
            voiceValidationClient: voiceValidationClient,
            voiceCatalog: catalog
        )
        let owner = SharedPlaybackOwner(driver: driver)
        let model = AudiobookWorkflowModel(
            dependencies: deps,
            playbackOwner: owner,
            admission: SpeechCreationAdmission()
        )
        return (model, driver)
    }

    func testProductionBlockerExplainsCastConfirmationBeforeChaptersAreReady() async throws {
        let (workflow, _) = makeWorkflow()
        _ = try await importBook(into: workflow, fileName: "blocked.txt", text: "第一章\n海风吹来。")

        XCTAssertEqual(workflow.productionBlocker, .castNotConfirmed)
    }

    func testRecommendationExplainsEmptyPoolAndRecovery() async throws {
        let catalog = VoiceCatalogStore()
        let (workflow, _) = makeWorkflow(catalog: catalog)
        _ = try await importBook(into: workflow, fileName: "empty.txt", text: "第一章\n海风吹来。")
        try await catalog.archiveVoices(voiceIDs: ["v-narrator", "v-designed-narrator"])
        await workflow.previewRecommendedVoices()
        XCTAssertFalse(workflow.castingRecommendation?.isApplicable ?? true)
        XCTAssertFalse(workflow.castingRecommendation?.recoveryActions.isEmpty ?? true)
        XCTAssertTrue(workflow.voiceBindings.isEmpty)
    }

    func testStaleRecommendationCannotApply() async throws {
        let catalog = VoiceCatalogStore()
        let (workflow, _) = makeWorkflow(catalog: catalog)
        _ = try await importBook(into: workflow, fileName: "stale.txt", text: "第一章\n海风吹来。")
        await workflow.previewRecommendedVoices()
        XCTAssertNotNil(workflow.pendingCastingPlan)
        try await catalog.archiveVoices(voiceIDs: ["v-narrator"])
        await workflow.applyPendingCastingPlan(acknowledgedIssueIDs: [])
        XCTAssertTrue(workflow.voiceBindings.isEmpty)
        XCTAssertNotNil(workflow.errorMessage)
    }

    /// 引擎升级只改变制品版本：已选好的声音必须原样保留，确认一次即可继续制作，
    /// 而不是把整本书的每个角色都变成阻塞错误。
    func testEngineUpgradeReconfirmsLockedVoicesWithoutReSelection() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let renderer = WorkflowFakeRenderer(), catalog = VoiceCatalogStore()
        let (workflow, _) = makeWorkflow(renderer: renderer, store: store, catalog: catalog)
        _ = try await importBook(into: workflow, fileName: "upgrade.txt", text: "第一章\n海风拂过窗前。")

        let role = try XCTUnwrap(workflow.characters.first)
        await workflow.bindVoice(roleID: role.id, voiceID: "v-narrator")
        let applied = try XCTUnwrap(workflow.voiceBindings[role.id])
        XCTAssertEqual(applied.modelRevision, String(repeating: "a", count: 40))

        renderer.setModelRevision(String(repeating: "c", count: 40))
        await workflow.previewRecommendedVoices()
        let plan = try XCTUnwrap(workflow.pendingCastingPlan)
        XCTAssertTrue(plan.isApplicable, "引擎升级不能把已选好的声音变成阻塞错误")
        XCTAssertFalse(workflow.castingPlanNeedsRefresh, "用当前目录算出的方案不该显示目录已变化")
        let reconfirmation = try XCTUnwrap(plan.issues.first { $0.code == .castRevisionChanged })
        XCTAssertFalse(reconfirmation.isBlocking)
        XCTAssertEqual(reconfirmation.roleIDs, [role.id])
        XCTAssertTrue(plan.affectedRoleIDs.contains(role.id))
        XCTAssertEqual(plan.proposedBindings[role.id]?.voiceID, applied.voiceID, "不能替用户换声音")

        await workflow.applyPendingCastingPlan(acknowledgedIssueIDs: plan.requiredAcknowledgements)
        XCTAssertNil(workflow.pendingCastingPlan)
        XCTAssertEqual(workflow.voiceBindings[role.id]?.voiceID, applied.voiceID)
        XCTAssertEqual(workflow.voiceBindings[role.id]?.voiceRevision, applied.voiceRevision)
        XCTAssertEqual(workflow.voiceBindings[role.id]?.modelRevision, String(repeating: "c", count: 40))
    }

    /// 引擎升级让已有音色的输出验收失效时：方案要求按当前引擎重新验收，界面给出
    /// 就地修复动作；验收通过后同一批声音继续可用，不需要重新选声。
    func testStaleVoiceValidationIsRepairedInPlace() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let renderer = WorkflowFakeRenderer(), catalog = VoiceCatalogStore()
        let client = WorkflowFakeVoiceQualityClient(onValidated: { _ in
            renderer.setVoicesProductionReady(true)
        })
        let (workflow, _) = makeWorkflow(renderer: renderer, store: store, catalog: catalog,
                                         voiceValidationClient: client)
        _ = try await importBook(into: workflow, fileName: "stale-evidence.txt", text: "第一章\n海风拂过窗前。")
        let role = try XCTUnwrap(workflow.characters.first)
        await workflow.bindVoice(roleID: role.id, voiceID: "v-narrator")
        let applied = try XCTUnwrap(workflow.voiceBindings[role.id])

        renderer.setVoicesProductionReady(false)
        await workflow.previewRecommendedVoices()
        let blocked = try XCTUnwrap(workflow.pendingCastingPlan)
        XCTAssertFalse(blocked.isApplicable)
        XCTAssertEqual(blocked.voicesNeedingValidation, ["v-narrator"])
        XCTAssertFalse(blocked.issues.contains { $0.code == .voiceIdentityUnknown && $0.roleIDs.contains(role.id) },
                       "声音没变，只是验收失效，不能说成身份未知")
        XCTAssertEqual(blocked.proposedBindings, workflow.voiceBindings, "规划阶段不能改绑定")

        await workflow.revalidateCastVoices(blocked.voicesNeedingValidation)
        XCTAssertEqual(client.requestedVoiceIDs, ["v-narrator"])
        let repaired = try XCTUnwrap(workflow.pendingCastingPlan)
        XCTAssertTrue(repaired.isApplicable, "验收通过后应恢复可制作")
        XCTAssertTrue(repaired.voicesNeedingValidation.isEmpty)
        XCTAssertEqual(repaired.proposedBindings[role.id]?.voiceID, applied.voiceID)
        XCTAssertEqual(workflow.errorMessage, nil)
    }

    /// 重新验收失败要如实报告，不能假装可制作，也不能动用户已选的声音。
    func testFailedVoiceRevalidationKeepsBlockingAndVoice() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let renderer = WorkflowFakeRenderer(), catalog = VoiceCatalogStore()
        let client = WorkflowFakeVoiceQualityClient(failing: ["v-narrator"])
        let (workflow, _) = makeWorkflow(renderer: renderer, store: store, catalog: catalog,
                                         voiceValidationClient: client)
        _ = try await importBook(into: workflow, fileName: "revalidate-fail.txt", text: "第一章\n海风拂过窗前。")
        let role = try XCTUnwrap(workflow.characters.first)
        await workflow.bindVoice(roleID: role.id, voiceID: "v-narrator")
        renderer.setVoicesProductionReady(false)
        await workflow.previewRecommendedVoices()
        let blocked = try XCTUnwrap(workflow.pendingCastingPlan)

        await workflow.revalidateCastVoices(blocked.voicesNeedingValidation)
        XCTAssertEqual(client.requestedVoiceIDs, ["v-narrator"])
        XCTAssertEqual(workflow.voiceBindings[role.id]?.voiceID, "v-narrator")
        XCTAssertEqual(workflow.pendingCastingPlan?.voicesNeedingValidation, ["v-narrator"])
        XCTAssertNotNil(workflow.errorMessage)
    }

    func testCatalogChangesRefreshProjection() async throws {
        let catalog = VoiceCatalogStore()
        let (workflow, _) = makeWorkflow(catalog: catalog)
        _ = try await importBook(into: workflow, fileName: "refresh.txt", text: "第一章\n海风吹来。")
        _ = await workflow.refreshAvailableVoices()
        let before = workflow.voiceCatalogRevision
        try await catalog.archiveVoices(voiceIDs: ["v-narrator"])
        await workflow.voiceCatalogModel.refresh()
        XCTAssertNotEqual(workflow.voiceCatalogRevision, before)
        XCTAssertFalse(workflow.mergedAvailableVoices().contains { $0.id == "v-narrator" })
    }

    func testSameTextAuditionKeepsSourceAndFrozenParametersWithoutCommitting() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let renderer = WorkflowFakeRenderer(), catalog = VoiceCatalogStore()
        let (workflow, driver) = makeWorkflow(renderer: renderer, store: store, catalog: catalog)
        let imported = try await importBook(into: workflow, fileName: "audition.txt", text: "第一章\n海风拂过窗前，远处传来了熟悉的钟声。")
        let role = try XCTUnwrap(workflow.characters.first)
        try await catalog.registerBookExclusiveVoice(voiceID: "v-designed-narrator", bookID: imported.bookID,
            bookTitle: nil, roleID: role.id, roleName: nil, archetype: nil, creationSource: .instantClone)
        await workflow.previewRecommendedVoices()
        await workflow.prepareCastingAudition(kind: .sameTextComparison, roleID: role.id,
            comparisonVoiceIDs: ["v-narrator", "v-designed-narrator"])
        let audition = try XCTUnwrap(workflow.castingAudition)
        XCTAssertEqual(audition.items.count, 2)
        let source = try await store.sourceIndex(for: imported.bookID)
        for item in audition.items { XCTAssertEqual(item.text, try source.text(in: item.sourceRange)) }
        XCTAssertEqual(audition.items[0].text, audition.items[1].text)
        await workflow.playCastingAudition(itemIndex: 0)
        await workflow.playCastingAudition(itemIndex: 1)
        XCTAssertEqual(renderer.auditionRequests.count, 2)
        XCTAssertTrue(renderer.auditionRequests.allSatisfy { $0.speed == 1 && $0.seed == nil && $0.expectedModelRevision == String(repeating: "a", count: 40) })
        XCTAssertTrue(driver.isPlaying)
        let candidates = try await store.candidates(for: imported.bookID)
        let bindings = try await store.voiceBindings(for: imported.bookID)
        XCTAssertTrue(candidates.isEmpty)
        XCTAssertTrue(bindings.isEmpty)
        try await catalog.archiveVoices(voiceIDs: ["v-designed-narrator"])
        await workflow.playCastingAudition(itemIndex: 1)
        XCTAssertEqual(renderer.auditionRequests.count, 2, "变更后的目录不能继续旧试听")
    }

    func testSavedRoleAuditionSucceedsWithoutPendingCastingPlan() async throws {
        let renderer = WorkflowFakeRenderer(), catalog = VoiceCatalogStore()
        let store = try AudiobookProjectStore(root: tempRoot)
        let (workflow, driver) = makeWorkflow(renderer: renderer, store: store, catalog: catalog)
        _ = try await importBook(into: workflow, fileName: "audition_saved.txt", text: "第一章\n海风拂过窗前，远处传来了熟悉的钟声。")
        let role = try XCTUnwrap(workflow.characters.first)

        await workflow.bindVoice(roleID: role.id, voiceID: "v-narrator")
        XCTAssertNil(workflow.pendingCastingPlan, "已保存绑定后不存在待决选角方案")
        XCTAssertNotNil(workflow.voiceBindings[role.id])

        await workflow.prepareCastingAudition(kind: .sameTextComparison, roleID: role.id, comparisonVoiceIDs: ["v-narrator"])
        let audition = try XCTUnwrap(workflow.castingAudition)
        XCTAssertEqual(audition.items.count, 1)
        XCTAssertEqual(audition.items[0].voiceID, "v-narrator")

        await workflow.playCastingAudition(itemIndex: 0)
        XCTAssertEqual(renderer.auditionRequests.count, 1)
        XCTAssertTrue(driver.isPlaying)
        XCTAssertNil(workflow.errorMessage)
    }

    func testSavedRoleAuditionIgnoresPreviousBooksPendingPlan() async throws {
        let (workflow, driver) = makeWorkflow()
        _ = try await importBook(into: workflow, fileName: "planned_book.txt", text: "第一章\n旧书中还没有应用配声方案。")
        await workflow.previewRecommendedVoices()
        XCTAssertNotNil(workflow.pendingCastingPlan)

        _ = try await importBook(into: workflow, fileName: "bound_book.txt", text: "第一章\n新书已经保存了旁白声音。")
        let role = try XCTUnwrap(workflow.characters.first)
        await workflow.bindVoice(roleID: role.id, voiceID: "v-narrator")
        await workflow.prepareCastingAudition(kind: .sameTextComparison, roleID: role.id)
        XCTAssertNotNil(workflow.castingAudition)
        await workflow.playCastingAudition(itemIndex: 0)

        XCTAssertTrue(driver.isPlaying)
        XCTAssertNil(workflow.pendingCastingPlan)
    }

    func testStopAuditionPlaybackPreventsLateResultsFromStarting() async throws {
        let renderer = WorkflowFakeRenderer(), catalog = VoiceCatalogStore()
        let store = try AudiobookProjectStore(root: tempRoot)
        let (workflow, driver) = makeWorkflow(renderer: renderer, store: store, catalog: catalog)
        _ = try await importBook(into: workflow, fileName: "audition_stop.txt", text: "第一章\n海风拂过窗前，远处传来了熟悉的钟声。")
        let role = try XCTUnwrap(workflow.characters.first)

        await workflow.bindVoice(roleID: role.id, voiceID: "v-narrator")
        await workflow.prepareCastingAudition(kind: .sameTextComparison, roleID: role.id, comparisonVoiceIDs: ["v-narrator"])
        XCTAssertNotNil(workflow.castingAudition)

        final class StartGate: @unchecked Sendable {
            private let lock = NSLock()
            private var started = false
            var isStarted: Bool { lock.withLock { started } }
            func markStarted() { lock.withLock { started = true } }
        }
        let gate = StartGate()
        renderer.auditionRenderHandler = { _ in
            gate.markStarted()
            try? await Task.sleep(for: .milliseconds(50))
            return WorkflowFakeRenderer.makeWAV(frameCount: 4_800)
        }

        let playTask = Task {
            await workflow.playCastingAudition(itemIndex: 0)
        }

        for _ in 0..<100 {
            if gate.isStarted { break }
            try? await Task.sleep(for: .milliseconds(2))
        }

        workflow.stopAuditionPlayback()
        await playTask.value

        XCTAssertFalse(driver.isPlaying, "停止试听后迟到结果不得播放")
        XCTAssertNil(workflow.errorMessage, "主动停止试听不应报告错误")
    }

    func testSavedAuditionDoesNotStartAfterLeavingWorkshop() async throws {
        try await assertSavedAuditionInvalidatedBy { workflow, _ in
            await workflow.leaveWorkshop()
        }
    }

    func testSavedAuditionDoesNotStartAfterSwitchingBooks() async throws {
        try await assertSavedAuditionInvalidatedBy { workflow, _ in
            _ = try await self.importBook(into: workflow, fileName: "other_book.txt", text: "第一章\n另一部书的故事。")
        }
    }

    func testSavedAuditionDoesNotStartAfterVoiceBindingChanges() async throws {
        try await assertSavedAuditionInvalidatedBy { workflow, _ in
            let role = try XCTUnwrap(workflow.characters.first)
            await workflow.bindVoice(roleID: role.id, voiceID: "v-designed-narrator")
        }
    }

    func testSavedAuditionDoesNotStartAfterVoiceIsArchived() async throws {
        try await assertSavedAuditionInvalidatedBy { _, catalog in
            try await catalog.archiveVoices(voiceIDs: ["v-narrator"])
        }
    }

    func testStoppingAuditionPreservesAnotherPlaybackTarget() throws {
        let driver = FakeDriver()
        let playback = SharedPlaybackOwner(driver: driver)
        let workflow = AudiobookWorkflowModel(playbackOwner: playback)
        try playback.play(data: WorkflowFakeRenderer.makeWAV(frameCount: 4_800), target: .work("saved-work"))

        workflow.stopAuditionPlayback()

        XCTAssertTrue(driver.isPlaying)
        XCTAssertEqual(playback.target, .work("saved-work"))
    }

    func testReplacingCastingPlanStopsActiveAudition() async throws {
        for replaceBindings in [false, true] {
            let (workflow, driver) = makeWorkflow()
            _ = try await importBook(into: workflow, fileName: "plan_\(replaceBindings).txt", text: "第一章\n海风拂过窗前，远处传来了熟悉的钟声。")
            let role = try XCTUnwrap(workflow.characters.first)
            await workflow.bindVoice(roleID: role.id, voiceID: "v-narrator")
            await workflow.prepareCastingAudition(kind: .sameTextComparison, roleID: role.id)
            await workflow.playCastingAudition(itemIndex: 0)
            XCTAssertTrue(driver.isPlaying)

            if replaceBindings {
                await workflow.previewVoiceReplacement(Array(workflow.voiceBindings.values))
            } else {
                await workflow.previewRecommendedVoices()
            }

            XCTAssertNotNil(workflow.pendingCastingPlan)
            XCTAssertNil(workflow.castingAudition)
            XCTAssertFalse(driver.isPlaying, "生成新配声方案时应停止旧方案的试听")
        }
    }

    private func assertSavedAuditionInvalidatedBy(
        _ invalidate: (AudiobookWorkflowModel, VoiceCatalogStore) async throws -> Void
    ) async throws {
        let renderer = WorkflowFakeRenderer(), catalog = VoiceCatalogStore()
        let (workflow, driver) = makeWorkflow(renderer: renderer, catalog: catalog)
        _ = try await importBook(into: workflow, fileName: "saved_audition.txt", text: "第一章\n海风拂过窗前，远处传来了熟悉的钟声。")
        let role = try XCTUnwrap(workflow.characters.first)
        await workflow.bindVoice(roleID: role.id, voiceID: "v-narrator")
        await workflow.prepareCastingAudition(kind: .sameTextComparison, roleID: role.id)
        XCTAssertNotNil(workflow.castingAudition)

        let gate = WorkflowRendererGate()
        renderer.auditionRenderHandler = { _ in
            await gate.suspend()
            return WorkflowFakeRenderer.makeWAV(frameCount: 4_800)
        }
        let playTask = Task { await workflow.playCastingAudition(itemIndex: 0) }
        for _ in 0..<1_000 {
            if await gate.hasSuspended() { break }
            await Task.yield()
        }
        let suspended = await gate.hasSuspended()
        XCTAssertTrue(suspended)
        try await invalidate(workflow, catalog)
        await gate.resume()
        await playTask.value

        XCTAssertFalse(driver.isPlaying, "已失效的试听结果不能接管共享播放器")
        XCTAssertNil(workflow.castingAudition)
    }

    func testDialogueAuditionUsesOrderedAdjacentSourceWithoutChangingAssignments() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let catalog = VoiceCatalogStore()
        let (workflow, _) = makeWorkflow(store: store, catalog: catalog)
        let imported = try await importBook(into: workflow, fileName: "dialogue.txt", text: "第一章\n“海风来了，你听见了吗？”\n“我听见了，我们走吧。”\n")
        let chapter = try XCTUnwrap(workflow.chapters.first)
        let roles = [AudiobookCharacter(bookID: imported.bookID, displayName: "甲", chapterIDs: [chapter.id]),
                     AudiobookCharacter(bookID: imported.bookID, displayName: "乙", chapterIDs: [chapter.id])]
        try await store.saveCharacters(bookID: imported.bookID, characters: workflow.characters + roles)
        let source = try await store.sourceIndex(for: imported.bookID)
        let atoms = try await store.atoms(for: imported.bookID, chapterID: chapter.id)
        let spoken = try atoms.filter { try source.text(in: $0.sourceRange).contains("“") }
        XCTAssertEqual(spoken.count, 2)
        let annotations = zip(spoken, roles).map { atom, role in AudiobookAnnotation(bookID: imported.bookID,
            chapterID: chapter.id, windowID: UUID(), atomID: atom.id, sourceRange: atom.sourceRange, assignment: .assigned(roleID: role.id)) }
        try await store.saveAnnotations(bookID: imported.bookID, annotations: annotations)
        try await catalog.registerBookExclusiveVoice(voiceID: "v-designed-narrator", bookID: imported.bookID,
            bookTitle: nil, roleID: roles[1].id, roleName: nil, archetype: nil, creationSource: .instantClone)
        await workflow.openBook(imported.bookID)
        await workflow.previewVoiceReplacement(zip(roles, ["v-narrator", "v-designed-narrator"]).map { role, id in
            AudiobookVoiceBinding(roleID: role.id, voiceID: id, voiceRevision: "vr_0123456789abcdef0123456789abcdef", modelRevision: String(repeating: "a", count: 40))
        })
        await workflow.prepareCastingAudition(kind: .dialogueComparison, roleID: roles[0].id)
        let audition = try XCTUnwrap(workflow.castingAudition)
        XCTAssertEqual(audition.items.map(\.roleID), roles.map(\.id))
        XCTAssertEqual(audition.items.map(\.sourceRange), spoken.map(\.sourceRange))
        let unchanged = try await store.annotations(for: imported.bookID)
        XCTAssertEqual(unchanged, annotations)
    }

    func testVoiceReturnUsesActualCloneIdentityAndCreationSource() async throws {
        let store = try AudiobookProjectStore(root: tempRoot), catalog = VoiceCatalogStore()
        let (workflow, _) = makeWorkflow(store: store, catalog: catalog)
        let imported = try await importBook(into: workflow, fileName: "clone-return.txt", text: "第一章\n海风吹来。")
        let role = try XCTUnwrap(workflow.characters.first)
        let pendingContext = await workflow.beginVoiceRoundTrip(for: role.id)
        let context = try XCTUnwrap(pendingContext)
        await workflow.completeVoiceRoundTrip(voiceID: "v-designed-narrator", creationSource: .instantClone, context: context)
        let binding = try XCTUnwrap(workflow.voiceBindings[role.id])
        XCTAssertNil(binding.callerSeed)
        XCTAssertEqual(binding.voiceRevision, "vr_0123456789abcdef0123456789abcdef")
        XCTAssertEqual(binding.modelRevision, String(repeating: "a", count: 40))
        let catalogActual1 = await catalog.metadata(for: binding.voiceID)?.creationSource
        XCTAssertEqual(catalogActual1, .instantClone)
        let catalogActual2 = await catalog.metadata(for: binding.voiceID)?.originBookID
        XCTAssertEqual(catalogActual2, imported.bookID)
    }

    private func importBook(
        into workflow: AudiobookWorkflowModel,
        fileName: String,
        text: String
    ) async throws -> (bookID: UUID, chapterIDs: [UUID], roleIDs: [UUID]) {
        let txtURL = tempRoot.appendingPathComponent(fileName)
        try Data(text.utf8).write(to: txtURL)
        await workflow.prepareImport(fileURL: txtURL, encoding: .utf8)
        await workflow.confirmImport()

        let bookID = try XCTUnwrap(workflow.selectedBook?.id)
        return (
            bookID,
            workflow.chapters.map(\.id),
            workflow.characters.map(\.id)
        )
    }

    private func waitForSuspension(
        _ gate: WorkflowLoadGate,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let result = await XCTWaiter.fulfillment(of: [gate.suspended], timeout: 10)
        XCTAssertEqual(result, .completed, "测试读取门未被触发", file: file, line: line)
    }

    private func waitForResume(
        _ gate: WorkflowLoadGate,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let result = await XCTWaiter.fulfillment(of: [gate.resumed], timeout: 10)
        XCTAssertEqual(result, .completed, "测试读取门未恢复", file: file, line: line)
    }

    /// 跑通全书分析的最小 fake client（提取/归并/标注均返回合法结构化 JSON）。
    private final class WorkflowLiveProgressClient: AudiobookAnalysisClient, @unchecked Sendable {
        let configurationDigest: String

        init(configurationDigest: String) {
            self.configurationDigest = configurationDigest
        }

        func complete(_ prompt: AudiobookAnalysisPrompt) async throws -> String {
            switch prompt.stage {
            case .extraction:
                let atomIDs = Self.extractPrimaryAtomIDs(from: prompt.input)
                let firstAtom = atomIDs.first.map { [$0] } ?? []
                let resp = AudiobookExtractionResponse(mentions: [
                    .init(surfaceName: "林远", aliases: ["阿远"], evidenceAtomIDs: firstAtom, voiceTraitEvidence: "青年低沉嗓音"),
                ])
                return String(decoding: try JSONEncoder().encode(resp), as: UTF8.self)
            case .castMerge:
                let resp = AudiobookMergeResponse(groups: [
                    .init(canonicalName: "林远", memberSurfaceNames: ["林远", "阿远"], aliases: ["阿远"], isCollisionUnresolved: false, evidenceSummary: "青年低沉嗓音"),
                ])
                return String(decoding: try JSONEncoder().encode(resp), as: UTF8.self)
            case .annotation:
                let atomIDs = Self.extractPrimaryAtomIDs(from: prompt.input)
                let roleIDs = Self.extractCandidateRoleIDs(from: prompt.input)
                var items: [AudiobookAnnotationResponse.Item] = []
                for (idx, atomID) in atomIDs.enumerated() {
                    if let roleID = roleIDs.first, idx % 2 == 1 {
                        items.append(.init(atomID: atomID, speakerKind: .character, roleID: roleID, candidateRoleIDs: [roleID], confidence: 0.95, evidence: "林远开口说道"))
                    } else {
                        items.append(.init(atomID: atomID, speakerKind: .narrator, roleID: nil, candidateRoleIDs: [], confidence: 0.99, evidence: "旁白叙述"))
                    }
                }
                let resp = AudiobookAnnotationResponse(items: items)
                return String(decoding: try JSONEncoder().encode(resp), as: UTF8.self)
            }
        }

        private static func extractPrimaryAtomIDs(from inputJSON: String) -> [UUID] {
            guard let data = inputJSON.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [] }
            let list = (obj["primary_atoms_required"] as? [[String: Any]])
                ?? (obj["primary_atoms"] as? [[String: Any]])
                ?? []
            return list.compactMap { ($0["atomID"] as? String).flatMap(UUID.init(uuidString:)) }
        }

        private static func extractCandidateRoleIDs(from inputJSON: String) -> [UUID] {
            guard let data = inputJSON.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = obj["candidate_characters"] as? [[String: Any]]
            else { return [] }
            return list.compactMap { ($0["roleID"] as? String).flatMap(UUID.init(uuidString:)) }
        }
    }

    private func makeWorkingWorkflow() -> AudiobookWorkflowModel {
        let root = tempRoot!
        let config = LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "test-model")
        let deps = AudiobookDependencies(
            makeStore: { try AudiobookProjectStore(root: root) },
            makeAnalysisClient: { snap in
                WorkflowLiveProgressClient(configurationDigest: snap.configurationDigest)
            },
            resolveAnalysisSnapshot: { gen in
                AudiobookAnalysisConfigSnapshot(configuration: config, generation: gen)
            },
            speechRenderer: WorkflowFakeRenderer()
        )
        return AudiobookWorkflowModel(
            dependencies: deps,
            playbackOwner: SharedPlaybackOwner(driver: FakeDriver()),
            admission: SpeechCreationAdmission()
        )
    }

    private func waitForRenderSuspension(
        _ gate: WorkflowRendererGate,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if await gate.hasSuspended() { return }
            await Task.yield()
        }
        XCTFail("制作器未进入渲染等待点", file: file, line: line)
    }

    private func waitForProductionToFinish(
        _ workflow: AudiobookWorkflowModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if !workflow.isProducing { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("有声书制作任务未结束", file: file, line: line)
    }

    private func markBookReadyForProduction(
        _ bookID: UUID,
        workflow: AudiobookWorkflowModel,
        store: AudiobookProjectStore
    ) async throws {
        var book = try await store.book(id: bookID)
        book.analysisState = .allWindowsValidated
        try await store.updateBook(book)
        let characters = try await store.characters(for: bookID)
        let narrator = try XCTUnwrap(characters.first(where: { $0.isNarrator }))
        let chapters = try await store.chapters(for: bookID)
        for chapter in chapters {
            let atoms = try await store.atoms(for: bookID, chapterID: chapter.id)
                .filter { $0.kind != .formatting }
            let annotations = atoms.map { atom in
                AudiobookAnnotation(
                    bookID: bookID,
                    chapterID: chapter.id,
                    windowID: UUID(),
                    atomID: atom.id,
                    sourceRange: atom.sourceRange,
                    assignment: .assigned(roleID: narrator.id)
                )
            }
            XCTAssertFalse(annotations.isEmpty, "制作夹具必须为章节准备可核验的标注")
            try await store.saveAnnotations(bookID: bookID, annotations: annotations)
            let storedAnnotations = try await store.annotations(for: bookID, chapterID: chapter.id)
            XCTAssertEqual(storedAnnotations.count, annotations.count,
                           "制作夹具必须通过工作流共用的 Store 持久化标注")
        }

        let readyBook = try await store.book(id: bookID)
        XCTAssertEqual(readyBook.analysisState, .allWindowsValidated)

        await workflow.openBook(bookID)
        await workflow.bindVoice(
            roleID: narrator.id,
            binding: AudiobookVoiceBinding(
                roleID: narrator.id,
                voiceID: "v-narrator",
                voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                modelRevision: String(repeating: "a", count: 40)
            )
        )
        await workflow.confirmCastAndAudition()
        for chapter in chapters {
            XCTAssertEqual(
                workflow.chapterReadinessByID[chapter.id],
                .readyForProduction,
                "制作测试夹具必须在当前工作区发布可制作状态；错误：\(workflow.errorMessage ?? "无")"
            )
        }
    }

    /// 接线回归：beginAnalysis 必须在 run 启动前装好 sink，
    /// 首个 planned 事件不得丢失，终态必须收敛为 completed。
    func testBeginAnalysisDeliversLiveProgressBeforeCompletion() async throws {
        let workflow = makeWorkingWorkflow()
        let txtURL = tempRoot.appendingPathComponent("live_progress.txt")
        try Data("第一章 归来\n林远站在桥头。\n“跟紧我。”他回头说道。\n".utf8).write(to: txtURL)

        await workflow.prepareImport(fileURL: txtURL, encoding: .utf8)
        await workflow.confirmImport()
        let bookID = try XCTUnwrap(workflow.selectedBook?.id)

        workflow.beginAnalysis(bookID)
        XCTAssertTrue(workflow.isAnalyzing)
        for _ in 0..<200 {
            if !workflow.isAnalyzing, workflow.analysisProgress?.outcome != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertFalse(workflow.isAnalyzing)
        let progress = try XCTUnwrap(workflow.analysisProgress)
        XCTAssertEqual(progress.outcome, .completed)
        XCTAssertEqual(progress.fraction, 1.0, accuracy: 0.0001)
        let events = workflow.analysisEventBuffer.events
        XCTAssertEqual(events.first?.kind, .planned)
        XCTAssertEqual(events.last?.kind, .runEnded)
        let runID = try XCTUnwrap(events.first?.runID)
        XCTAssertTrue(events.allSatisfy { $0.runID == runID })
    }

    /// 代次隔离回归：暂停→重跑时旧 run 的迟到事件不得污染新投影，
    /// 缓冲里只保留新 run 的事件且 runID 唯一。
    func testPauseThenResumeKeepsOnlyNewRunEvents() async throws {
        let workflow = makeWorkingWorkflow()
        let txtURL = tempRoot.appendingPathComponent("pause_resume.txt")
        // 足够多的段落，保证第一次 begin 后暂停时 run 还没跑完。
        var lines = ["第一章 代次隔离"]
        for index in 0..<40 {
            lines.append("林远沿着石阶第\(index)次登高远望。")
            lines.append("“跟紧我。”他回头说道。")
        }
        try Data(lines.joined(separator: "\n").utf8).write(to: txtURL)

        await workflow.prepareImport(fileURL: txtURL, encoding: .utf8)
        await workflow.confirmImport()
        let bookID = try XCTUnwrap(workflow.selectedBook?.id)

        workflow.beginAnalysis(bookID)
        XCTAssertTrue(workflow.isAnalyzing)
        await workflow.pauseAnalysis()
        XCTAssertFalse(workflow.isAnalyzing)

        // 重跑到完成：旧 run 的事件（包括可能的 runEnded）不得混入。
        workflow.beginAnalysis(bookID)
        for _ in 0..<400 {
            if !workflow.isAnalyzing, workflow.analysisProgress?.outcome != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertFalse(workflow.isAnalyzing)
        let progress = try XCTUnwrap(workflow.analysisProgress)
        XCTAssertEqual(progress.outcome, .completed)
        let events = workflow.analysisEventBuffer.events
        XCTAssertFalse(events.isEmpty)
        XCTAssertEqual(events.first?.kind, .planned)
        XCTAssertEqual(events.last?.kind, .runEnded)
        let runID = try XCTUnwrap(events.first?.runID)
        XCTAssertTrue(events.allSatisfy { $0.runID == runID }, "缓冲不得混入旧 run 事件")
    }

    func testLegacyBookHasExplicitPreparationRouteAndOpeningDoesNotPrepareIt() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let (workflow, driver) = makeWorkflow(store: store)
        let imported = try await importBook(into: workflow, fileName: "legacy.txt", text: "第一章\n原稿正文。")
        let originalSourceID = try XCTUnwrap(workflow.selectedBook?.sourceID)
        try await markBookReadyForProduction(imported.bookID, workflow: workflow, store: store)
        workflow.makeConfirmedChapters(chapterIDs: imported.chapterIDs)
        await waitForProductionToFinish(workflow)
        let preservedCandidates = try await store.candidates(for: imported.bookID)
        XCTAssertFalse(preservedCandidates.isEmpty)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(tempRoot.appendingPathComponent("library.sqlite3").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "UPDATE sources SET source_kind = 'reference', reference_source_id = NULL, preparation_version = NULL, source_map_rel_path = NULL, source_map_sha256 = NULL WHERE id = '\(originalSourceID)';", nil, nil, nil), SQLITE_OK)
        await workflow.openBook(imported.bookID)
        XCTAssertTrue(workflow.requiresWorkingTextPreparation)
        XCTAssertEqual(workflow.selectedBook?.sourceID, originalSourceID)
        await workflow.startListening()
        XCTAssertNil(workflow.errorMessage)
        XCTAssertTrue(driver.isPlaying)
        await workflow.prepareSelectedBookWorkingText()
        XCTAssertNil(workflow.errorMessage)
        XCTAssertFalse(workflow.requiresWorkingTextPreparation)
        XCTAssertNotEqual(workflow.selectedBook?.sourceID, originalSourceID)
        XCTAssertEqual(workflow.selectedBook?.analysisState, .notStarted)
        XCTAssertNil(workflow.selectedBook?.confirmedCastRevisionID)
        let source = try await store.workingSourceSnapshot(bookID: imported.bookID)
        XCTAssertEqual(source.sourceID, workflow.selectedBook?.sourceID)
        let remainingCandidates = try await store.candidates(for: imported.bookID)
        XCTAssertEqual(remainingCandidates, preservedCandidates)
    }

    func testPreparationKeepsPartialHistoricalAudioReachableWithoutChangingWorkspaceCoordinates() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let (workflow, driver) = makeWorkflow(store: store)
        let imported = try await importBook(into: workflow, fileName: "history.txt",
            text: "第一章 起程\n林远走出家门。\n第二章 归途\n远方传来钟声。")
        try await markBookReadyForProduction(imported.bookID, workflow: workflow, store: store)
        let firstChapter = try XCTUnwrap(workflow.chapters.first)
        workflow.makeConfirmedChapters(chapterIDs: [firstChapter.id])
        await waitForProductionToFinish(workflow)
        let oldSource = try await store.sourceIndex(for: imported.bookID)
        let candidates = try await store.candidates(for: imported.bookID)
        XCTAssertFalse(candidates.isEmpty)
        await workflow.prepareSelectedBookWorkingText()
        XCTAssertNil(workflow.errorMessage)
        XCTAssertNotEqual(workflow.selectedBook?.sourceID, firstChapter.sourceID)
        XCTAssertFalse(workflow.chapters.contains { $0.id == firstChapter.id })
        XCTAssertTrue(workflow.hasListenableChapter)
        let historyID = try XCTUnwrap(workflow.selectedAudioRevisionID)
        XCTAssertTrue(workflow.audioRevisions.contains { $0.id == historyID })
        await workflow.startListening(chapterID: firstChapter.id)
        XCTAssertNil(workflow.errorMessage)
        XCTAssertTrue(driver.isPlaying)
        XCTAssertEqual(workflow.listeningController?.activePlayback?.chapterID, firstChapter.id)
        XCTAssertFalse(workflow.chapters.contains { $0.id == workflow.listeningChapterID })
        XCTAssertFalse(workflow.listeningTexts.isEmpty)
        for item in workflow.listeningTexts {
            XCTAssertEqual(item.text, try oldSource.text(in: item.sourceRange))
        }
        await workflow.refreshExportAudit(profile: .chapterMP3, chapterIDs: [firstChapter.id])
        XCTAssertEqual(workflow.exportAudit?.readyChapterIDs, [firstChapter.id])
        let preserved = try await store.candidates(for: imported.bookID)
        XCTAssertEqual(preserved, candidates)
        await workflow.selectAudioRevision(nil)
        XCTAssertFalse(workflow.hasListenableChapter)
        XCTAssertTrue(workflow.listeningTexts.isEmpty)
        XCTAssertTrue(workflow.exportChapters.allSatisfy { $0.sourceID == workflow.selectedBook?.sourceID })
    }

    func testWorkflowOnlyShowsNextValidAction() async throws {
        let (workflow, _) = makeWorkflow()
        let txtURL = tempRoot.appendingPathComponent("book.txt")
        try Data("第一章 晨雾\n海风徐来。\n".utf8).write(to: txtURL)

        await workflow.prepareImport(fileURL: txtURL, encoding: .utf8)
        await workflow.confirmImport()

        // 刚导入尚未分析：唯一主动作是「分析全书」
        XCTAssertEqual(workflow.selectedBookPrimaryAction, .analyzeWholeBook)

        // 全书窗口分析完成但尚未确认配声与试听：唯一主动作是「确认人物与声音」
        let store = try AudiobookProjectStore(root: tempRoot)
        let bookID = try XCTUnwrap(workflow.selectedBook?.id)
        var book = try await store.book(id: bookID)
        book.analysisState = .allWindowsValidated
        try await store.updateBook(book)
        await workflow.refreshShelf()
        await workflow.openBook(bookID)
        XCTAssertEqual(workflow.selectedBookPrimaryAction, .confirmCastAndVoices)

        // 绑定旁白声音并确认全书角色与试听后，章节未制作：唯一主动作是「制作已确认章节」
        let narrator = try XCTUnwrap(workflow.characters.first)
        let chapter = try XCTUnwrap(workflow.chapters.first)
        let atoms = try await store.atoms(for: bookID, chapterID: chapter.id).filter { $0.kind != .formatting }
        let anns = atoms.map { atom in
            AudiobookAnnotation(
                bookID: bookID,
                chapterID: chapter.id,
                windowID: UUID(),
                atomID: atom.id,
                sourceRange: atom.sourceRange,
                assignment: .assigned(roleID: narrator.id)
            )
        }
        try await store.saveAnnotations(bookID: bookID, annotations: anns)
        await workflow.bindVoice(
            roleID: narrator.id,
            binding: AudiobookVoiceBinding(
                roleID: narrator.id,
                voiceID: "v-narrator",
                voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                modelRevision: String(repeating: "a", count: 40)
            )
        )
        await workflow.confirmCastAndAudition()
        XCTAssertEqual(workflow.selectedBookPrimaryAction, .makeConfirmedChapters)
    }

    func testConfirmCastAndAuditionRollsBackWhenAuditionPersistenceFails() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let (workflow, _) = makeWorkflow(store: store)
        let imported = try await importBook(
            into: workflow,
            fileName: "confirmation-atomicity.txt",
            text: "第一章 灯塔\n海雾漫过栈桥。\n灯塔的光照亮了归途。\n"
        )
        let importedCharacters = try await store.characters(for: imported.bookID)
        let narrator = try XCTUnwrap(importedCharacters.first(where: \.isNarrator))
        let chapters = try await store.chapters(for: imported.bookID)
        for chapter in chapters {
            let atoms = try await store.atoms(for: imported.bookID, chapterID: chapter.id)
                .filter { $0.kind != .formatting }
            let annotations = atoms.map { atom in
                AudiobookAnnotation(
                    bookID: imported.bookID,
                    chapterID: chapter.id,
                    windowID: UUID(),
                    atomID: atom.id,
                    sourceRange: atom.sourceRange,
                    assignment: .assigned(roleID: narrator.id)
                )
            }
            XCTAssertFalse(annotations.isEmpty, "确认回归必须包含已分析的对白归属")
            try await store.saveAnnotations(bookID: imported.bookID, annotations: annotations)
        }
        var analyzedBook = try await store.book(id: imported.bookID)
        analyzedBook.analysisState = .allWindowsValidated
        try await store.updateBook(analyzedBook)

        await workflow.openBook(imported.bookID)
        await workflow.bindVoice(
            roleID: narrator.id,
            binding: AudiobookVoiceBinding(
                roleID: narrator.id,
                voiceID: "v-narrator",
                voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                modelRevision: String(repeating: "a", count: 40)
            )
        )
        XCTAssertNil(workflow.errorMessage, "测试夹具必须先成功保存旁白绑定")

        let originalBook = try await store.book(id: imported.bookID)
        let originalCharacters = try await store.characters(for: imported.bookID)
        let originalBindings = try await store.voiceBindings(for: imported.bookID)
        let originalAnnotations = try await store.annotations(for: imported.bookID)
        XCTAssertNil(originalBook.confirmedCastRevisionID)
        XCTAssertNil(originalBook.confirmedAuditionVoiceSetDigest)

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(tempRoot.appendingPathComponent("library.sqlite3").path, &database), SQLITE_OK)
        let handle = try XCTUnwrap(database)
        defer { sqlite3_close(handle) }
        let installTriggerSQL = """
        CREATE TRIGGER injected_audition_failure_before_insert
        BEFORE INSERT ON books
        WHEN NEW.confirmed_audition_digest IS NOT NULL
        BEGIN SELECT RAISE(ABORT, 'injected_confirmation_failure'); END;
        CREATE TRIGGER injected_audition_failure_before_update
        BEFORE UPDATE ON books
        WHEN NEW.confirmed_audition_digest IS NOT NULL
          AND NEW.confirmed_audition_digest IS NOT OLD.confirmed_audition_digest
        BEGIN SELECT RAISE(ABORT, 'injected_confirmation_failure'); END;
        """
        XCTAssertEqual(sqlite3_exec(handle, installTriggerSQL, nil, nil, nil), SQLITE_OK,
                       String(cString: sqlite3_errmsg(handle)))

        await workflow.confirmCastAndAudition()

        XCTAssertTrue(
            workflow.errorMessage?.contains("injected_confirmation_failure") == true,
            "第二次确认必须由注入的 SQLite 故障明确失败；实际：\(workflow.errorMessage ?? "无错误")"
        )
        let bookAfterFailure = try await store.book(id: imported.bookID)
        XCTAssertEqual(
            bookAfterFailure.confirmedCastRevisionID,
            originalBook.confirmedCastRevisionID,
            "试听写入失败后不得留下先行提交的角色确认；实际：\(String(describing: bookAfterFailure.confirmedCastRevisionID))"
        )
        XCTAssertEqual(bookAfterFailure.confirmedAuditionVoiceSetDigest, originalBook.confirmedAuditionVoiceSetDigest)
        XCTAssertEqual(bookAfterFailure.updatedAt, originalBook.updatedAt,
                       "复合确认失败必须回滚首次书籍写入的更新时间")
        XCTAssertEqual(bookAfterFailure, originalBook, "两项确认必须在同一事务中原子提交")
        let charactersAfterFailure = try await store.characters(for: imported.bookID)
        let bindingsAfterFailure = try await store.voiceBindings(for: imported.bookID)
        let annotationsAfterFailure = try await store.annotations(for: imported.bookID)
        XCTAssertEqual(charactersAfterFailure, originalCharacters)
        XCTAssertEqual(bindingsAfterFailure, originalBindings)
        XCTAssertEqual(annotationsAfterFailure, originalAnnotations)

        let reopenedStore = try AudiobookProjectStore(root: tempRoot)
        let reopenedBookAfterFailure = try await reopenedStore.book(id: imported.bookID)
        let reopenedCharactersAfterFailure = try await reopenedStore.characters(for: imported.bookID)
        let reopenedBindingsAfterFailure = try await reopenedStore.voiceBindings(for: imported.bookID)
        let reopenedAnnotationsAfterFailure = try await reopenedStore.annotations(for: imported.bookID)
        XCTAssertEqual(reopenedBookAfterFailure, originalBook, "重开数据库后也不得留下半确认状态")
        XCTAssertEqual(reopenedCharactersAfterFailure, originalCharacters)
        XCTAssertEqual(reopenedBindingsAfterFailure, originalBindings)
        XCTAssertEqual(reopenedAnnotationsAfterFailure, originalAnnotations)

        let removeTriggerSQL = """
        DROP TRIGGER injected_audition_failure_before_insert;
        DROP TRIGGER injected_audition_failure_before_update;
        """
        XCTAssertEqual(sqlite3_exec(handle, removeTriggerSQL, nil, nil, nil), SQLITE_OK,
                       String(cString: sqlite3_errmsg(handle)))
        await workflow.confirmCastAndAudition()
        XCTAssertNil(workflow.errorMessage, "移除故障后，同一工作流必须能重试确认")

        let confirmedBook = try await store.book(id: imported.bookID)
        let castController = AudiobookCastController(store: store)
        let currentCastRevisionID = try await castController.currentCastRevisionID(for: imported.bookID)
        let currentVoiceSetDigest = try await castController.currentVoiceSetDigest(for: imported.bookID)
        XCTAssertEqual(confirmedBook.confirmedCastRevisionID, currentCastRevisionID)
        XCTAssertEqual(confirmedBook.confirmedAuditionVoiceSetDigest, currentVoiceSetDigest)
        for chapter in chapters {
            XCTAssertEqual(workflow.chapterReadinessByID[chapter.id], .readyForProduction,
                           "重试后角色确认和试听确认均应对当前章节生效")
        }
    }

    func testOpeningAnotherBookSelectsARoleFromThatBook() async throws {
        let (workflow, _) = makeWorkflow()
        let firstBook = try await importBook(
            into: workflow,
            fileName: "role_first_book.txt",
            text: "第一章 甲书\n甲书正文。\n"
        )
        XCTAssertEqual(workflow.selectedRoleID, firstBook.roleIDs.first)

        let secondBook = try await importBook(
            into: workflow,
            fileName: "role_second_book.txt",
            text: "第一章 乙书\n乙书正文。\n"
        )

        XCTAssertEqual(workflow.selectedBook?.id, secondBook.bookID)
        XCTAssertEqual(workflow.selectedRoleID.map { secondBook.roleIDs.contains($0) }, true,
                        "切换书籍后，选中人物必须属于当前书籍")
        XCTAssertNotEqual(firstBook.bookID, secondBook.bookID)
    }

    func testStaleWorkspaceRetriesOnceAndContinuousChangesStop() async throws {
        for continuousChanges in [false, true] {
            let store = try AudiobookProjectStore(root: tempRoot.appendingPathComponent(UUID().uuidString))
            let (workflow, _) = makeWorkflow(store: store)
            let imported = try await importBook(into: workflow, fileName: UUID().uuidString + ".txt", text: "第一章\n海风吹来。\n")
            let reads = WorkCounter()
            let reader = AudiobookWorkspaceReader(store: store, readBoundary: { _ in
                let count = reads.increment()
                if continuousChanges || count <= 2 {
                    var book = try await store.book(id: imported.bookID)
                    book.title = "boundary-\(count)"
                    try await store.updateBook(book)
                }
            })
            workflow.replaceWorkspaceReaderForTesting(reader)
            workflow.workspaceRefreshDelay = .zero
            await workflow.openBook(imported.bookID)
            let pending = try XCTUnwrap(workflow.pendingWorkspaceRefreshForTesting)
            await pending.value
            XCTAssertNil(workflow.pendingWorkspaceRefreshForTesting)
            XCTAssertEqual(reads.count, continuousChanges ? 4 : 3)
            if continuousChanges {
                XCTAssertNotNil(workflow.errorMessage, "Repeated changes stop after one owner retry")
            } else {
                XCTAssertEqual(workflow.selectedBook?.title, "boundary-2")
                XCTAssertNil(workflow.errorMessage)
            }
            await workflow.shutdown()
        }
    }

    func testLeavingWorkshopCancelsDeferredWorkspaceRefresh() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let (workflow, _) = makeWorkflow(store: store)
        let imported = try await importBook(into: workflow, fileName: "deferred-stop.txt", text: "第一章\n海风吹来。\n")
        let reads = WorkCounter()
        workflow.replaceWorkspaceReaderForTesting(AudiobookWorkspaceReader(store: store, readBoundary: { _ in
            _ = reads.increment()
            var book = try await store.book(id: imported.bookID)
            book.title += "."
            try await store.updateBook(book)
        }))
        workflow.workspaceRefreshDelay = .seconds(60)
        await workflow.openBook(imported.bookID)
        let pending = try XCTUnwrap(workflow.pendingWorkspaceRefreshForTesting)
        await workflow.leaveWorkshop()
        await pending.value
        XCTAssertEqual(reads.count, 2)
        XCTAssertNil(workflow.pendingWorkspaceRefreshForTesting)
    }

    func testLatestBookOpenWinsWhenOlderWorkspacePublishesLate() async throws {
        let (workflow, _) = makeWorkflow()
        let firstBook = try await importBook(
            into: workflow,
            fileName: "late_first_book.txt",
            text: "第一章 旧书\n旧书正文。\n"
        )
        let secondBook = try await importBook(
            into: workflow,
            fileName: "late_second_book.txt",
            text: "第一章 新书\n新书正文。\n"
        )
        let store = try AudiobookProjectStore(root: tempRoot)
        var persistedFirstBook = try await store.book(id: firstBook.bookID)
        persistedFirstBook.analysisState = .allWindowsValidated
        persistedFirstBook.productionState = .paused
        persistedFirstBook.confirmedCastRevisionID = UUID()
        persistedFirstBook.confirmedAuditionVoiceSetDigest = "first-book-digest"
        try await store.updateBook(persistedFirstBook)

        let gate = WorkflowLoadGate()
        workflow.loadCheckpointForTesting = { bookID, chapterID, checkpoint in
            guard bookID == firstBook.bookID,
                  chapterID == nil,
                  checkpoint == .beforeBookWorkspacePublication
            else { return }
            await gate.suspend()
        }

        let olderOpen = Task { await workflow.openBook(firstBook.bookID) }
        await waitForSuspension(gate)

        await workflow.openBook(secondBook.bookID)
        XCTAssertEqual(workflow.selectedBook?.id, secondBook.bookID)
        XCTAssertEqual(workflow.workbenchTab, .preparation)
        XCTAssertNil(workflow.resumePlan)
        XCTAssertEqual(Set(workflow.chapterReadinessByID.keys), Set(secondBook.chapterIDs))

        gate.resume()
        await olderOpen.value

        XCTAssertEqual(workflow.selectedBook?.id, secondBook.bookID)
        XCTAssertEqual(workflow.workbenchTab, .preparation,
                        "旧书迟到的工作台状态不能覆盖当前书籍")
        XCTAssertNil(workflow.resumePlan, "旧书迟到的恢复计划不能覆盖当前书籍状态")
        XCTAssertEqual(
            Set(workflow.chapterReadinessByID.keys),
            Set(secondBook.chapterIDs),
            "旧书迟到的就绪状态不能替换当前书籍的章节状态"
        )
        XCTAssertEqual(workflow.selectedRoleID.map { secondBook.roleIDs.contains($0) }, true)
    }

    func testTrashingBookInvalidatesItsPendingOpenSnapshot() async throws {
        let (workflow, _) = makeWorkflow()
        let currentBook = try await importBook(
            into: workflow,
            fileName: "trash_pending_current.txt",
            text: "第一章 当前书\n当前书正文。\n"
        )
        let targetBook = try await importBook(
            into: workflow,
            fileName: "trash_pending_target.txt",
            text: "第一章 待打开书\n待打开书正文。\n"
        )
        await workflow.openBook(currentBook.bookID)

        let gate = WorkflowLoadGate()
        workflow.loadCheckpointForTesting = { bookID, chapterID, checkpoint in
            guard bookID == targetBook.bookID,
                  chapterID == targetBook.chapterIDs.first,
                  checkpoint == .beforeChapterDetailsPublication
            else { return }
            await gate.suspend()
        }

        let pendingOpen = Task { await workflow.openBook(targetBook.bookID) }
        await waitForSuspension(gate)
        XCTAssertEqual(workflow.selectedBook?.id, currentBook.bookID,
                       "快照暂停期间，当前工作区仍应属于原书")

        await workflow.trashBook(targetBook.bookID)
        XCTAssertTrue(workflow.trashedBooks.contains(where: { $0.id == targetBook.bookID }))
        XCTAssertFalse(workflow.shelfBooks.contains(where: { $0.id == targetBook.bookID }))

        gate.resume()
        await pendingOpen.value

        XCTAssertEqual(workflow.selectedBook?.id, currentBook.bookID,
                       "已移入废纸篓的待打开快照不能重新进入工作区")
        XCTAssertFalse(workflow.shelfBooks.contains(where: { $0.id == targetBook.bookID }))
    }

    func testListeningModeShowsGuidanceWhenNoChapterHasAudio() async throws {
        let (workflow, _) = makeWorkflow()
        _ = try await importBook(
            into: workflow,
            fileName: "listening_empty.txt",
            text: "第一章 静默\n尚未制作音频。\n"
        )
        XCTAssertFalse(workflow.hasListenableChapter)

        await workflow.startListening()
        XCTAssertEqual(workflow.surfaceMode, .listening)
        XCTAssertNil(workflow.errorMessage)
    }

    func testRepeatedOperationFeedbackRestartsItsPresentationIdentity() {
        let (workflow, _) = makeWorkflow()
        workflow.bannerMessage = "已更新角色名称。"
        let firstID = workflow.bannerNoticeID
        workflow.bannerMessage = "已更新角色名称。"
        XCTAssertNotEqual(workflow.bannerNoticeID, firstID,
                          "相同文案的新操作也必须重新开始四秒计时")
        XCTAssertFalse(workflow.bannerRequiresAction)
    }

    func testPreparationFeedbackStaysPersistentUntilReplacedByAnOperationReceipt() {
        let (workflow, _) = makeWorkflow()
        workflow.showPersistentBanner("请重新分析全书后继续制作。")
        XCTAssertTrue(workflow.bannerRequiresAction)
        workflow.errorMessage = "服务未连接，请重试。"
        workflow.bannerMessage = "章节名称已更新。"
        XCTAssertFalse(workflow.bannerRequiresAction)
        workflow.bannerMessage = nil
        XCTAssertEqual(workflow.errorMessage, "服务未连接，请重试。",
                       "临时反馈收起不能顺带清除需要处理的错误")
    }

    func testTrashingBookOffersUndoAndRestoresExactlyThatBook() async throws {
        let (workflow, _) = makeWorkflow()
        let firstBook = try await importBook(
            into: workflow,
            fileName: "trash_undo_first.txt",
            text: "第一章 第一本\n第一本正文。\n"
        )
        _ = try await importBook(
            into: workflow,
            fileName: "trash_undo_second.txt",
            text: "第一章 第二本\n第二本正文。\n"
        )

        await workflow.trashBook(firstBook.bookID)
        XCTAssertEqual(workflow.lastTrashedBookID, firstBook.bookID)
        XCTAssertTrue(workflow.trashUndoMessage?.contains("trash_undo_first") == true)
        XCTAssertFalse(workflow.shelfBooks.contains(where: { $0.id == firstBook.bookID }))

        workflow.dismissTrashUndoMessage()
        XCTAssertNil(workflow.trashUndoMessage)
        XCTAssertEqual(workflow.lastTrashedBookID, firstBook.bookID,
                       "自动收起反馈不应改变废纸篓或撤销目标")
        await workflow.undoLastTrash()
        XCTAssertNil(workflow.lastTrashedBookID)
        XCTAssertNil(workflow.trashUndoMessage)
        XCTAssertTrue(workflow.shelfBooks.contains(where: { $0.id == firstBook.bookID }))
        XCTAssertFalse(workflow.trashedBooks.contains(where: { $0.id == firstBook.bookID }))
    }

    func testLateChapterReadCannotReplaceTheNewBooksChapterContent() async throws {
        let (workflow, _) = makeWorkflow()
        let firstBook = try await importBook(
            into: workflow,
            fileName: "chapter_first_book.txt",
            text: "第一章 旧书\n旧书第一章。\n第二章 旧书续篇\n旧书第二章。\n"
        )
        let secondBook = try await importBook(
            into: workflow,
            fileName: "chapter_second_book.txt",
            text: "第一章 新书\n新书正文。\n"
        )
        XCTAssertEqual(firstBook.chapterIDs.count, 2)

        await workflow.openBook(firstBook.bookID)
        workflow.selectedAtomIDs = Set(workflow.chapterAtoms.map(\.id))
        XCTAssertFalse(workflow.chapterAtoms.isEmpty)
        let selectedOldChapterID = try XCTUnwrap(firstBook.chapterIDs.last)
        let gate = WorkflowLoadGate()
        workflow.loadCheckpointForTesting = { bookID, chapterID, checkpoint in
            guard bookID == firstBook.bookID,
                  chapterID == selectedOldChapterID,
                  checkpoint == .beforeChapterDetailsPublication
            else { return }
            await gate.suspend()
        }

        workflow.selectedChapterID = selectedOldChapterID
        XCTAssertTrue(workflow.chapterAtoms.isEmpty, "旧章节正文必须在新章节读取前清空")
        XCTAssertTrue(workflow.atomTextsByID.isEmpty)
        XCTAssertTrue(workflow.chapterAnnotationsByAtomID.isEmpty)
        XCTAssertTrue(workflow.selectedAtomIDs.isEmpty, "不能把旧章节选区带到新章节")
        XCTAssertTrue(workflow.isLoadingChapterDetails)
        await waitForSuspension(gate)
        XCTAssertTrue(workflow.chapterFragments.isEmpty)
        XCTAssertTrue(workflow.isLoadingChapterDetails)
        await workflow.openBook(secondBook.bookID)

        let store = try AudiobookProjectStore(root: tempRoot)
        let expectedNewBookAtoms = try await store.atoms(
            for: secondBook.bookID,
            chapterID: try XCTUnwrap(secondBook.chapterIDs.first)
        ).filter { $0.kind != .formatting }
        XCTAssertEqual(Set(workflow.chapterAtoms.map(\.id)), Set(expectedNewBookAtoms.map(\.id)))
        XCTAssertFalse(workflow.isLoadingChapterDetails)

        gate.resume()
        // didSet 启动的 reload 是独立任务；等它离开读取门后再核对投影。
        await waitForResume(gate)

        XCTAssertEqual(workflow.selectedBook?.id, secondBook.bookID)
        XCTAssertEqual(workflow.selectedChapterID, secondBook.chapterIDs.first)
        XCTAssertEqual(
            Set(workflow.chapterAtoms.map(\.id)),
            Set(expectedNewBookAtoms.map(\.id)),
            "旧书迟到的章节读取不能覆盖新书内容"
        )
    }

    func testProductionRunKeepsItsBookIdentityAndBlocksAnotherBooksStart() async throws {
        let renderGate = WorkflowRendererGate()
        let renderer = WorkflowFakeRenderer(beforeRender: { await renderGate.suspend() })
        let store = try AudiobookProjectStore(root: tempRoot)
        let (workflow, _) = makeWorkflow(renderer: renderer, store: store)
        let firstBook = try await importBook(
            into: workflow,
            fileName: "production_first_book.txt",
            text: "第一章 甲书\n甲书正文。\n"
        )
        try await markBookReadyForProduction(firstBook.bookID, workflow: workflow, store: store)

        workflow.makeConfirmedChapters()
        workflow.makeConfirmedChapters()
        XCTAssertTrue(workflow.isProducing)
        XCTAssertEqual(workflow.productionBookID, firstBook.bookID)
        await waitForRenderSuspension(renderGate)
        XCTAssertNotNil(workflow.productionProgress, "点击制作后立即有准备状态")
        for _ in 0..<100 {
            if workflow.productionProgress?.currentFragmentID != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(workflow.productionProgress?.currentFragmentID, "第一段仍在制作时就必须收到实时进度")
        XCTAssertEqual(workflow.productionProgress?.phase, .rendering)

        let secondBook = try await importBook(
            into: workflow,
            fileName: "production_second_book.txt",
            text: "第一章 乙书\n乙书正文。\n"
        )
        try await markBookReadyForProduction(secondBook.bookID, workflow: workflow, store: store)

        XCTAssertEqual(workflow.selectedBook?.id, secondBook.bookID)
        XCTAssertEqual(workflow.productionProgress?.bookID, firstBook.bookID,
                       "打开另一本书不能覆盖当前任务的实时快照")
        XCTAssertNil(workflow.selectedBookProductionProgress)
        XCTAssertEqual(workflow.selectedBookPrimaryAction, .makeConfirmedChapters)
        XCTAssertTrue(workflow.isProductionBlocked(for: secondBook.bookID))
        let firstBookSummary = try XCTUnwrap(workflow.shelfBooks.first(where: { $0.id == firstBook.bookID }))
        XCTAssertEqual(workflow.nextPrimaryAction(for: firstBookSummary), .pauseProduction)
        workflow.makeConfirmedChapters()
        XCTAssertEqual(workflow.productionBookID, firstBook.bookID,
                       "制作中的书籍归属不能被第二本书的点击替换")

        await renderGate.resume()
        await waitForProductionToFinish(workflow)
        XCTAssertEqual(workflow.selectedBook?.id, secondBook.bookID,
                       "第一本书的终态刷新不能把工作台切回旧书")
        XCTAssertFalse(workflow.isProductionBlocked(for: secondBook.bookID))
    }

    func testAnalyzedChapterLayoutUpdateIsRejectedWithoutDestroyingAnnotations() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let (workflow, _) = makeWorkflow(store: store)
        let text = "第一章 雾港\n海雾漫过栈桥。\n灯塔亮了。\n"
        let url = tempRoot.appendingPathComponent("analyzed_chapter_edit.txt")
        try Data(text.utf8).write(to: url)
        let preview = try await AudiobookTXTImporter.prepare(fileURL: url, encoding: .utf8)
        let bookID = try await store.importBook(preview)
        let importedChapters = try await store.chapters(for: bookID)
        let chapter = try XCTUnwrap(importedChapters.first)
        let importedCharacters = try await store.characters(for: bookID)
        let narrator = try XCTUnwrap(importedCharacters.first(where: \.isNarrator))
        let importedAtoms = try await store.atoms(for: bookID, chapterID: chapter.id)
        let atom = try XCTUnwrap(importedAtoms.first(where: { $0.kind != .formatting }))
        let annotation = AudiobookAnnotation(
            bookID: bookID,
            chapterID: chapter.id,
            windowID: UUID(),
            atomID: atom.id,
            sourceRange: atom.sourceRange,
            assignment: .assigned(roleID: narrator.id),
            userConfirmed: true
        )
        try await store.saveAnnotations(bookID: bookID, annotations: [annotation])
        var analyzedBook = try await store.book(id: bookID)
        analyzedBook.analysisState = .allWindowsValidated
        try await store.updateBook(analyzedBook)
        await workflow.openBook(bookID)
        XCTAssertFalse(workflow.canEditChapterStructure,
                       "分析完成后工作流也应关闭拆分/合并入口")
        workflow.selectedAtomIDs = [atom.id]
        XCTAssertFalse(workflow.canSplitSelectedChapterBeforeSelectedAtom)
        XCTAssertFalse(workflow.canMergeSelectedChapterWithPrevious)
        XCTAssertTrue(workflow.canRenameSelectedChapter,
                      "重命名只改标题，分析完成后仍可用")

        var editedChapters = try await store.chapters(for: bookID)
        editedChapters[0].title = "改名后的章节"
        do {
            try await store.updateChapters(bookID: bookID, chapters: editedChapters)
            XCTFail("分析完成后不能通过重建目录静默清空分析与返修历史")
        } catch {
            // Expected: analyzed books require the non-destructive chapter-edit path.
        }

        let chaptersAfter = try await store.chapters(for: bookID)
        let annotationsAfter = try await store.annotations(for: bookID, chapterID: chapter.id)
        let sourceAfter = try await store.sourceIndex(for: bookID)
        let bookAfter = try await store.book(id: bookID)
        XCTAssertEqual(chaptersAfter.first?.title, chapter.title)
        XCTAssertEqual(annotationsAfter, [annotation])
        XCTAssertEqual(sourceAfter.utf8Data, preview.canonicalUTF8)
        XCTAssertEqual(bookAfter.analysisState, .allWindowsValidated)
    }

    func testWorkflowChapterSplitMergeKeepsSelectionAndCanonicalSource() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let (workflow, _) = makeWorkflow(store: store)
        let text = "开场第一段。\n继续第二段。\n最后第三段。"
        let imported = try await importBook(
            into: workflow,
            fileName: "workflow_chapter_edits.txt",
            text: text
        )
        let originalChapterID = try XCTUnwrap(imported.chapterIDs.first)
        let originalChapter = try XCTUnwrap(workflow.chapters.first(where: { $0.id == originalChapterID }))
        let sourceBefore = try await store.sourceIndex(for: imported.bookID)
        let sourceTextBefore = try sourceBefore.text(in: sourceBefore.wholeRange)

        XCTAssertTrue(workflow.canEditChapterStructure)
        XCTAssertFalse(workflow.canMergeSelectedChapterWithPrevious)
        let splitAtom = try XCTUnwrap(workflow.chapterAtoms.first(where: {
            $0.kind != .formatting && $0.sourceRange.lowerBound > originalChapter.sourceRange.lowerBound
        }))
        workflow.selectedAtomIDs = [splitAtom.id]
        XCTAssertTrue(workflow.canSplitSelectedChapterBeforeSelectedAtom,
                      "选中一段章节中间的原文后，菜单应开放拆分")

        await workflow.splitSelectedChapterBeforeSelectedAtom()

        let splitChapters = try await store.chapters(for: imported.bookID)
        let splitSelection = try XCTUnwrap(workflow.selectedChapterID)
        XCTAssertEqual(splitChapters.count, 2)
        XCTAssertEqual(splitSelection, splitChapters.last?.id,
                       "拆分后工作台应定位到新章节，而不是沿用旧章节投影")
        XCTAssertTrue(workflow.canMergeSelectedChapterWithPrevious)
        let sourceAfterSplit = try await store.sourceIndex(for: imported.bookID)
        XCTAssertEqual(try sourceAfterSplit.text(in: sourceAfterSplit.wholeRange), sourceTextBefore,
                       "拆分只调整章节目录，规范化原文必须保持逐字不变")

        await workflow.mergeSelectedChapterWithPrevious()

        let mergedChapters = try await store.chapters(for: imported.bookID)
        let mergedChapter = try XCTUnwrap(mergedChapters.first)
        XCTAssertEqual(mergedChapters.count, 1)
        XCTAssertEqual(mergedChapter.id, originalChapterID,
                       "合并后保留上一章身份，避免章节选择跳到失效 ID")
        XCTAssertEqual(workflow.selectedChapterID, originalChapterID)
        let sourceAfterMerge = try await store.sourceIndex(for: imported.bookID)
        XCTAssertEqual(try sourceAfterMerge.text(in: sourceAfterMerge.wholeRange), sourceTextBefore,
                       "合并不能覆盖规范化原文")

        await workflow.renameChapter(chapterID: originalChapterID, title: "整理后的章节")
        let renamedChapters = try await store.chapters(for: imported.bookID)
        XCTAssertEqual(renamedChapters.first?.title, "整理后的章节")
        let sourceAfterRename = try await store.sourceIndex(for: imported.bookID)
        XCTAssertEqual(try sourceAfterRename.text(in: sourceAfterRename.wholeRange), sourceTextBefore,
                       "重命名不能改写规范化原文")
    }

    func testSingleFragmentRerecordKeepsCurrentRevisionUntilExplicitAdoption() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let (workflow, _) = makeWorkflow(store: store)
        let imported = try await importBook(
            into: workflow,
            fileName: "single_fragment_rerecord.txt",
            text: "第一章 渡口\n风声紧迫。\n“快上船！”林远喊道。\n"
        )
        try await markBookReadyForProduction(imported.bookID, workflow: workflow, store: store)
        let chapterID = try XCTUnwrap(imported.chapterIDs.first)
        let chapterForPlanning = try XCTUnwrap(workflow.chapters.first(where: { $0.id == chapterID }))
        let sourceForPlanning = try await store.sourceIndex(for: imported.bookID)
        let atomsForPlanning = try await store.atoms(for: imported.bookID, chapterID: chapterID)
        let annotationsForPlanning = try await store.annotations(for: imported.bookID, chapterID: chapterID)
        let bindingsForPlanning = try await store.voiceBindings(for: imported.bookID)
        let plannedFragments = try AudiobookFragmentPlanner.plan(
            chapter: chapterForPlanning,
            annotations: annotationsForPlanning,
            bindings: bindingsForPlanning,
            policy: .standard,
            source: sourceForPlanning,
            atoms: atomsForPlanning
        )
        try await store.saveFragments(bookID: imported.bookID, chapterID: chapterID, fragments: plannedFragments)
        await workflow.openBook(imported.bookID)
        let fragmentBeforeFirstProduction = try XCTUnwrap(workflow.chapterFragments.first)
        let candidatesBeforeFirstProduction = try await store.candidates(for: imported.bookID)
        XCTAssertFalse(workflow.canRegenerateFragment(fragmentBeforeFirstProduction.id),
                       "尚无已采用章节版本时不能进入单段重录")
        workflow.regenerateFragment(fragmentID: fragmentBeforeFirstProduction.id)
        XCTAssertFalse(workflow.isProducing, "首次制作前的重录操作不得启动生产请求")
        XCTAssertNil(workflow.productionBookID)
        let candidatesAfterRejectedRerecord = try await store.candidates(for: imported.bookID)
        XCTAssertEqual(candidatesAfterRejectedRerecord.map(\.id), candidatesBeforeFirstProduction.map(\.id))

        workflow.makeConfirmedChapters(chapterIDs: [chapterID])
        await waitForProductionToFinish(workflow)

        let initialChapters = try await store.chapters(for: imported.bookID)
        let originalChapter = try XCTUnwrap(initialChapters.first)
        let originalRevisionID = try XCTUnwrap(originalChapter.currentChapterRevisionID)
        let fragment = try XCTUnwrap(workflow.chapterFragments.first)
        XCTAssertTrue(workflow.canRegenerateFragment(fragment.id),
                      "首次制作并生成已采用章节版本后才开放单段重录")
        let originalCandidates = try await store.candidates(for: imported.bookID)
        let originalSource = try await store.sourceIndex(for: imported.bookID)
        let originalSourceText = try originalSource.text(in: originalSource.wholeRange)

        await workflow.renameChapter(chapterID: chapterID, title: "渡口（修订标题）")
        let chaptersAfterRename = try await store.chapters(for: imported.bookID)
        let chapterAfterRename = try XCTUnwrap(chaptersAfterRename.first)
        XCTAssertEqual(chapterAfterRename.title, "渡口（修订标题）")
        XCTAssertEqual(chapterAfterRename.currentChapterRevisionID, originalRevisionID,
                       "有音频后重命名不得改变当前采用版本")
        let candidatesAfterRename = try await store.candidates(for: imported.bookID)
        XCTAssertEqual(candidatesAfterRename.map(\.id), originalCandidates.map(\.id),
                       "重命名不得删除或替换已有音频候选")
        let sourceAfterRename = try await store.sourceIndex(for: imported.bookID)
        XCTAssertEqual(try sourceAfterRename.text(in: sourceAfterRename.wholeRange), originalSourceText)

        workflow.regenerateFragment(fragmentID: fragment.id)
        await waitForProductionToFinish(workflow)

        let rerecordedCandidates = try await store.candidates(for: imported.bookID)
        XCTAssertEqual(rerecordedCandidates.count, originalCandidates.count + 1,
                       "独立重录必须生成一个同依赖的新候选，而不是复用旧音频")
        let chaptersBeforeAdoption = try await store.chapters(for: imported.bookID)
        let chapterBeforeAdoption = try XCTUnwrap(chaptersBeforeAdoption.first)
        XCTAssertEqual(chapterBeforeAdoption.currentChapterRevisionID, originalRevisionID,
                       "生成新候选不能自动替换用户正在采用的章节版本")

        let newCandidate = try XCTUnwrap(rerecordedCandidates.first { candidate in
            candidate.fragmentID == fragment.id && candidate.id != originalCandidates.first(where: { $0.fragmentID == fragment.id })?.id
        })
        XCTAssertEqual(newCandidate.dependencyDigest, fragment.dependencyDigest)
        await workflow.adoptCandidate(newCandidate.id)
        let chaptersAfterAdoption = try await store.chapters(for: imported.bookID)
        let chapterAfterAdoption = try XCTUnwrap(chaptersAfterAdoption.first)
        XCTAssertNotEqual(chapterAfterAdoption.currentChapterRevisionID, originalRevisionID,
                          "只有用户显式采用后才切换当前章节版本")
    }

    func testPausedSingleFragmentContinuesAfterWorkflowReopensWithoutExpandingScope() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let (initialWorkflow, _) = makeWorkflow(store: store)
        let imported = try await importBook(
            into: initialWorkflow, fileName: "resume-rerecord.txt",
            text: "第一章 渡口\n风吹过港口。\n第二章 山路\n月亮照亮远山。\n"
        )
        try await markBookReadyForProduction(imported.bookID, workflow: initialWorkflow, store: store)
        initialWorkflow.makeConfirmedChapters()
        await waitForProductionToFinish(initialWorkflow)
        let chaptersBefore = try await store.chapters(for: imported.bookID)
        let candidatesBefore = try await store.candidates(for: imported.bookID)

        let gate = WorkflowRendererGate()
        let (pausedWorkflow, _) = makeWorkflow(
            renderer: WorkflowFakeRenderer(beforeRender: { await gate.suspend() }), store: store
        )
        await pausedWorkflow.openBook(imported.bookID)
        let target = try XCTUnwrap(pausedWorkflow.chapterFragments.first)
        pausedWorkflow.regenerateFragment(fragmentID: target.id)
        await waitForRenderSuspension(gate)
        let pauseTask = Task { await pausedWorkflow.pauseProduction() }
        for _ in 0..<1_000 {
            if pausedWorkflow.isPausingProduction { break }
            await Task.yield()
        }
        await gate.resume()
        await pauseTask.value
        XCTAssertEqual(pausedWorkflow.selectedBook?.productionState, .paused)

        let reopenedStore = try AudiobookProjectStore(root: tempRoot)
        let (reopenedWorkflow, _) = makeWorkflow(store: reopenedStore)
        await reopenedWorkflow.refreshShelf()
        await reopenedWorkflow.openBook(imported.bookID)
        XCTAssertEqual(reopenedWorkflow.selectedBookPrimaryAction, .resumeProduction)
        reopenedWorkflow.makeConfirmedChapters()
        await waitForProductionToFinish(reopenedWorkflow)

        let candidatesAfter = try await reopenedStore.candidates(for: imported.bookID)
        let newCandidates = candidatesAfter.filter { candidate in
            !candidatesBefore.contains(where: { $0.id == candidate.id })
        }
        XCTAssertEqual(newCandidates.count, 1, "继续单段重录必须生成一个新候选")
        XCTAssertEqual(newCandidates.first?.fragmentID, target.id, "不能把续作扩大到其他片段或章节")
        let chaptersAfter = try await reopenedStore.chapters(for: imported.bookID)
        XCTAssertEqual(chaptersAfter.map(\.currentChapterRevisionID), chaptersBefore.map(\.currentChapterRevisionID),
                       "续作重录仍须显式采用，不能替换正在使用的版本")
        XCTAssertNil(reopenedWorkflow.errorMessage)
    }

    func testFinalProductionRefreshPublishesCandidatesWithoutDependingOnIntermediateProgress() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let (workflow, _) = makeWorkflow(store: store)
        let imported = try await importBook(into: workflow, fileName: "final-refresh.txt", text: "第一章 渡口\n海风吹来。\n灯光亮起。\n")
        try await markBookReadyForProduction(imported.bookID, workflow: workflow, store: store)
        let gate = WorkflowLoadGate()
        workflow.loadCheckpointForTesting = { bookID, chapterID, checkpoint in
            if bookID == imported.bookID, chapterID == nil, checkpoint == .beforeBookWorkspacePublication {
                await gate.suspend()
            }
        }
        workflow.makeConfirmedChapters()
        await waitForSuspension(gate)
        let saved = try await store.candidates(for: imported.bookID)
        XCTAssertFalse(saved.isEmpty)
        XCTAssertTrue(workflow.isProducing, "Final publication belongs to the production owner")
        gate.resume()
        await waitForProductionToFinish(workflow)
        XCTAssertEqual(Set(workflow.chapterCandidates.map(\.id)), Set(saved.map(\.id)))
        XCTAssertEqual(workflow.productionProgress?.phase, .completed)
        XCTAssertNil(workflow.errorMessage)
        await workflow.shutdown()
    }

    func testPreparationPauseReportsCheckpointWriteFailureInsteadOfSuccess() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let (workflow, _) = makeWorkflow(store: store)
        let imported = try await importBook(
            into: workflow, fileName: "pause-checkpoint-failure.txt",
            text: "第一章 渡口\n风吹过港口。\n第二章 山路\n月亮照亮远山。\n"
        )
        try await markBookReadyForProduction(imported.bookID, workflow: workflow, store: store)

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(tempRoot.appendingPathComponent("library.sqlite3").path, &database), SQLITE_OK)
        let handle = try XCTUnwrap(database)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, """
            CREATE TRIGGER reject_checkpoint_write BEFORE INSERT ON production_checkpoints
            BEGIN SELECT RAISE(FAIL, 'simulated checkpoint write failure'); END;
            """, nil, nil, nil), SQLITE_OK)

        workflow.makeConfirmedChapters(chapterIDs: [try XCTUnwrap(imported.chapterIDs.first)])
        // Cancel before the MainActor production task reaches its first preparation await.
        await workflow.pauseProduction()

        XCTAssertFalse(workflow.isProductionBusy)
        XCTAssertEqual(workflow.productionProgress?.state, .failed)
        XCTAssertTrue(workflow.errorMessage?.contains("任务记录未能保存") == true,
                      "任务范围未可靠保存时必须明确告知用户")
        XCTAssertNil(workflow.bannerMessage, "存储失败不能显示暂停成功或可恢复的承诺")
        let checkpoint = try await store.productionCheckpoint(for: imported.bookID)
        XCTAssertNil(checkpoint)
        XCTAssertEqual(workflow.selectedBook?.productionState, .idle)
    }

    func testPauseDuringCompletedProductionRefreshKeepsCompletionResult() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let (workflow, _) = makeWorkflow(store: store)
        let imported = try await importBook(
            into: workflow, fileName: "completed-production-pause.txt",
            text: "第一章 渡口\n风吹过港口。\n"
        )
        try await markBookReadyForProduction(imported.bookID, workflow: workflow, store: store)
        var adoptedRevisionID: UUID?

        for isFragmentRegeneration in [false, true] {
            let gate = WorkflowLoadGate()
            var shouldSuspend = true
            workflow.loadCheckpointForTesting = { bookID, chapterID, checkpoint in
                guard shouldSuspend, bookID == imported.bookID, chapterID == nil,
                      checkpoint == .beforeBookWorkspacePublication else { return }
                shouldSuspend = false
                await gate.suspend()
            }
            if isFragmentRegeneration {
                workflow.regenerateFragment(fragmentID: try XCTUnwrap(workflow.chapterFragments.first?.id))
            } else {
                workflow.makeConfirmedChapters()
            }
            await waitForSuspension(gate)
            XCTAssertTrue(workflow.isProducing)
            XCTAssertEqual(workflow.productionProgress?.phase, .completed)
            let pauseTask = Task { await workflow.pauseProduction() }
            let pauseDeadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !workflow.isPausingProduction, ContinuousClock.now < pauseDeadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(workflow.isPausingProduction, "暂停请求必须在读取门释放前进入制作 owner")
            gate.resume()
            await pauseTask.value

            XCTAssertEqual(workflow.selectedBook?.productionState, .fullBookProduced)
            XCTAssertEqual(workflow.selectedBookProductionProgress?.phase, .completed)
            XCTAssertFalse(workflow.bannerMessage?.contains("制作已暂停") == true,
                           "已完成制作不能提示用户点击不存在的继续按钮")
            if isFragmentRegeneration {
                XCTAssertTrue(workflow.bannerMessage?.contains("采用此候选") == true,
                              "单段重录完成后仍须引导试听和显式采用")
                XCTAssertEqual(workflow.chapters.first?.currentChapterRevisionID, adoptedRevisionID)
            } else {
                XCTAssertTrue(workflow.bannerMessage?.contains("制作已完成") == true)
                adoptedRevisionID = workflow.chapters.first?.currentChapterRevisionID
                XCTAssertNotNil(adoptedRevisionID)
            }
        }
    }

    func testFinalCheckpointFailureRollsBackCompletionAndResumesSavedAudioAfterReopen() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let (workflow, _) = makeWorkflow(store: store)
        let imported = try await importBook(
            into: workflow, fileName: "completion-transaction-failure.txt",
            text: "第一章 渡口\n风吹过港口。\n"
        )
        try await markBookReadyForProduction(imported.bookID, workflow: workflow, store: store)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(tempRoot.appendingPathComponent("library.sqlite3").path, &database), SQLITE_OK)
        let handle = try XCTUnwrap(database)
        defer { sqlite3_close(handle) }
        // Reject both final completion and fallback pause saves, so reopening must
        // recover the last running checkpoint after a persistent storage failure.
        XCTAssertEqual(sqlite3_exec(handle, """
            CREATE TRIGGER reject_completed_checkpoint BEFORE INSERT ON production_checkpoints
            WHEN json_extract(NEW.checkpoint_json, '$.progress.phase') = 'completed'
              OR json_extract(NEW.checkpoint_json, '$.progress.state') = 'paused'
            BEGIN SELECT RAISE(FAIL, 'simulated final checkpoint failure'); END;
            """, nil, nil, nil), SQLITE_OK)

        workflow.makeConfirmedChapters()
        await waitForProductionToFinish(workflow)
        XCTAssertEqual(workflow.productionProgress?.state, .failed)
        let interruptedBook = try await store.book(id: imported.bookID)
        let interruptedCheckpoint = try await store.productionCheckpoint(for: imported.bookID)
        XCTAssertEqual(interruptedBook.productionState, .running,
                       "最终检查点未提交时，书籍不能单独提交完成状态")
        XCTAssertEqual(interruptedBook.listenableState, .fullBookListenable,
                       "已经发布的章节仍可收听，不随制作收尾失败而撤销")
        XCTAssertEqual(interruptedCheckpoint?.progress.state, .running)
        let savedCandidates = try await store.candidates(for: imported.bookID)
        XCTAssertFalse(savedCandidates.isEmpty, "已提交片段不能随制作终态写入失败而丢失")

        let reopenedStore = try AudiobookProjectStore(root: tempRoot)
        _ = try await reopenedStore.recover()
        let (reopened, _) = makeWorkflow(store: reopenedStore)
        await reopened.refreshShelf()
        await reopened.openBook(imported.bookID)
        XCTAssertEqual(reopened.selectedBook?.productionState, .paused)
        XCTAssertEqual(reopened.selectedBookProductionProgress?.state, .paused)
        XCTAssertEqual(reopened.selectedBookPrimaryAction, .resumeProduction)

        XCTAssertEqual(sqlite3_exec(handle, "DROP TRIGGER reject_completed_checkpoint;", nil, nil, nil), SQLITE_OK)
        await reopened.resumeProduction()
        await waitForProductionToFinish(reopened)
        let completedBook = try await reopenedStore.book(id: imported.bookID)
        let completedCheckpoint = try await reopenedStore.productionCheckpoint(for: imported.bookID)
        let candidatesAfterResume = try await reopenedStore.candidates(for: imported.bookID)
        XCTAssertEqual(completedBook.productionState, .fullBookProduced)
        XCTAssertEqual(completedBook.listenableState, .fullBookListenable)
        XCTAssertEqual(completedCheckpoint?.progress.state, completedBook.productionState)
        XCTAssertEqual(completedCheckpoint?.progress.phase, .completed)
        XCTAssertEqual(Set(candidatesAfterResume.map(\.id)), Set(savedCandidates.map(\.id)),
                       "恢复只补齐制作收尾，应复用已经保存的音频")
        XCTAssertNil(reopened.errorMessage)
    }

    func testShutdownPreservesSelectedChapterScopeForResume() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let gate = WorkflowRendererGate()
        let (workflow, _) = makeWorkflow(renderer: WorkflowFakeRenderer(beforeRender: { await gate.suspend() }), store: store)
        let imported = try await importBook(
            into: workflow, fileName: "shutdown-production.txt",
            text: "第一章 渡口\n风吹过港口。\n第二章 山路\n月亮照亮远山。\n"
        )
        try await markBookReadyForProduction(imported.bookID, workflow: workflow, store: store)
        let targetChapterID = try XCTUnwrap(imported.chapterIDs.first)
        workflow.makeConfirmedChapters(chapterIDs: [targetChapterID])
        await waitForRenderSuspension(gate)
        let shutdown = Task { await workflow.shutdown() }
        for _ in 0..<1_000 {
            if await gate.hasBeenCancelled() { break }
            await Task.yield()
        }
        let cancelled = await gate.hasBeenCancelled()
        XCTAssertTrue(cancelled, "退出应用必须取消在途制作请求")
        await gate.resume()
        await shutdown.value
        XCTAssertFalse(workflow.isProducing)

        let reopenedStore = try AudiobookProjectStore(root: tempRoot)
        let (reopened, _) = makeWorkflow(store: reopenedStore)
        await reopened.refreshShelf()
        await reopened.openBook(imported.bookID)
        XCTAssertEqual(reopened.selectedBookPrimaryAction, .resumeProduction)
        reopened.makeConfirmedChapters()
        await waitForProductionToFinish(reopened)
        let candidates = try await reopenedStore.candidates(for: imported.bookID)
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.allSatisfy { $0.chapterID == targetChapterID },
                      "退出后继续不能把原来只选中的一章扩大为整本书")
        let chapters = try await reopenedStore.chapters(for: imported.bookID)
        XCTAssertNotNil(chapters.first?.currentChapterRevisionID)
        XCTAssertNil(chapters.last?.currentChapterRevisionID)
    }

    func testRouteChangeKeepsProductionButReleasesListeningAndShutdownCheckpoints() async throws {
        let (workflow, driver) = makeWorkflow()
        let store = try AudiobookProjectStore(root: tempRoot)
        let txtURL = tempRoot.appendingPathComponent("listen_route.txt")
        try Data("第一章 启航\n船帆升起。\n".utf8).write(to: txtURL)

        await workflow.prepareImport(fileURL: txtURL, encoding: .utf8)
        await workflow.confirmImport()
        let bookID = try XCTUnwrap(workflow.selectedBook?.id)
        let chapter = try XCTUnwrap(workflow.chapters.first)
        let narrator = try XCTUnwrap(workflow.characters.first)

        var book = try await store.book(id: bookID)
        book.analysisState = .allWindowsValidated
        try await store.updateBook(book)

        let atoms = try await store.atoms(for: bookID, chapterID: chapter.id).filter { $0.kind != .formatting }
        let anns = atoms.map { atom in
            AudiobookAnnotation(
                bookID: bookID,
                chapterID: chapter.id,
                windowID: UUID(),
                atomID: atom.id,
                sourceRange: atom.sourceRange,
                assignment: .assigned(roleID: narrator.id)
            )
        }
        try await store.saveAnnotations(bookID: bookID, annotations: anns)
        await workflow.bindVoice(
            roleID: narrator.id,
            binding: AudiobookVoiceBinding(roleID: narrator.id, voiceID: "v-narrator", voiceRevision: "vr_0123456789abcdef0123456789abcdef", modelRevision: String(repeating: "a", count: 40))
        )
        await workflow.confirmCastAndAudition()

        // 写入一个可收听的章节版本
        let source = try await store.sourceIndex(for: bookID)
        let allAtoms = try await store.atoms(for: bookID, chapterID: chapter.id)
        let bindings = try await store.voiceBindings(for: bookID)
        let fragments = try AudiobookFragmentPlanner.plan(
            chapter: chapter,
            annotations: anns,
            bindings: bindings,
            policy: .standard,
            source: source,
            atoms: allAtoms
        )
        try await store.saveFragments(bookID: bookID, chapterID: chapter.id, fragments: fragments)
        let wav = WorkflowFakeRenderer.makeWAV(frameCount: 48_000)
        let cid = UUID()
        let candidate = AudiobookRenderCandidate(
            id: cid,
            bookID: bookID,
            chapterID: chapter.id,
            fragmentID: fragments[0].id,
            generation: 1,
            relativeAssetPath: "books/\(bookID.uuidString)/audio/\(cid.uuidString).wav",
            fileSHA256: AudiobookDigest.sha256Hex(wav),
            pcmSHA256: try AudioDigest.sha256HexOfPCM(in: wav),
            frameCount: 48_000,
            dependencyDigest: fragments[0].dependencyDigest
        )
        try await store.commitCandidate(candidate, wav: wav)
        let revController = AudiobookRevisionController(store: store)
        _ = try await revController.promoteInitialChapterIfComplete(bookID: bookID, chapterID: chapter.id)

        await workflow.openBook(bookID)
        await workflow.startListening(chapterID: chapter.id)
        XCTAssertTrue(driver.isPlaying)

        // 切换路由离开有声书工坊：听书立即停止并释放播放器
        await workflow.leaveWorkshop()
        XCTAssertFalse(driver.isPlaying)

        // 应用退出 shutdown()：确保听书与制作安全停止且检查点保留，下次启动需用户显式恢复
        await workflow.shutdown()
        XCTAssertFalse(workflow.isProducing)
        XCTAssertFalse(workflow.isAnalyzing)
    }

    func testManualVoiceSelectionUsesSnapshotIdentityAndRejectsMissingVoice() async throws {
        let (workflow, _) = makeWorkflow()
        let url = tempRoot.appendingPathComponent("manual.txt")
        try Data("第一章 归来\n林远站在桥头。\n".utf8).write(to: url)
        await workflow.prepareImport(fileURL: url, encoding: .utf8)
        await workflow.confirmImport()
        let narrator = try XCTUnwrap(workflow.characters.first)
        await workflow.bindVoice(roleID: narrator.id, voiceID: "v-narrator")
        let binding = try XCTUnwrap(workflow.voiceBindings[narrator.id])
        XCTAssertEqual(binding.voiceRevision, "vr_0123456789abcdef0123456789abcdef")
        XCTAssertEqual(binding.modelRevision, String(repeating: "a", count: 40))
        await workflow.bindVoice(roleID: narrator.id, voiceID: "missing-preset")
        XCTAssertEqual(workflow.voiceBindings[narrator.id], binding)
        XCTAssertNotNil(workflow.errorMessage)
    }

    func testManualRenderSpeedUsesDeclaredDomainWithoutClamping() async throws {
        let (workflow, _) = makeWorkflow()
        let url = tempRoot.appendingPathComponent("speed.txt")
        try Data("第一章 渡口\n夜色深沉。\n".utf8).write(to: url)
        await workflow.prepareImport(fileURL: url, encoding: .utf8); await workflow.confirmImport()
        let role = try XCTUnwrap(workflow.characters.first)
        await workflow.bindVoice(roleID: role.id, voiceID: "v-narrator")
        await workflow.updateRoleAllowedSpeed(roleID: role.id, speed: 3)
        XCTAssertEqual(workflow.voiceBindings[role.id]?.allowedSpeed, 3)
        for speed in [0.1, Double.nan] {
            await workflow.updateRoleAllowedSpeed(roleID: role.id, speed: speed)
            XCTAssertEqual(workflow.voiceBindings[role.id]?.allowedSpeed, 3)
            XCTAssertNotNil(workflow.errorMessage)
        }
    }

    func testAutomaticLeadCreationPreservesExistingSystemBinding() async throws {
        let renderer = WorkflowFakeRenderer()
        let (workflow, _) = makeWorkflow(renderer: renderer)
        let imported = try await importBook(into: workflow, fileName: "protected.txt", text: "第一章 渡口\n夜色深沉。\n")
        let role = try XCTUnwrap(workflow.characters.first)
        await workflow.bindVoice(roleID: role.id, voiceID: "v-narrator")
        let original = try XCTUnwrap(workflow.voiceBindings[role.id])
        let count = await workflow.createExclusiveVoicesForLeadCharacters(for: imported.bookID)
        XCTAssertEqual(count, 0)
        XCTAssertEqual(renderer.leadRequestCount, 0, "自动补全不能生成并替换已有声音，即使新声音已就绪")
        XCTAssertEqual(workflow.voiceBindings[role.id], original)
    }

    func testLeadVoiceCreationGracefulFallbackOnTimeout() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let renderer = WorkflowFakeRenderer()
        let (workflow, _) = makeWorkflow(renderer: renderer, store: store)
        let text = "第一章 渡口\n“我们走吧。”\n“好，这就出发。”\n"
        let imported = try await importBook(into: workflow, fileName: "lead_fallback.txt", text: text)
        let chapter = try XCTUnwrap(workflow.chapters.first)
        let role1 = AudiobookCharacter(bookID: imported.bookID, displayName: "林远", chapterIDs: [chapter.id])
        let role2 = AudiobookCharacter(bookID: imported.bookID, displayName: "苏月", chapterIDs: [chapter.id])
        try await store.saveCharacters(bookID: imported.bookID, characters: workflow.characters + [role1, role2])
        let source = try await store.sourceIndex(for: imported.bookID)
        let atoms = try await store.atoms(for: imported.bookID, chapterID: chapter.id)
        let spoken = try atoms.filter { try source.text(in: $0.sourceRange).contains("“") }
        let annotations = [
            AudiobookAnnotation(bookID: imported.bookID, chapterID: chapter.id, windowID: UUID(), atomID: spoken[0].id, sourceRange: spoken[0].sourceRange, assignment: .assigned(roleID: role1.id)),
            AudiobookAnnotation(bookID: imported.bookID, chapterID: chapter.id, windowID: UUID(), atomID: spoken[1].id, sourceRange: spoken[1].sourceRange, assignment: .assigned(roleID: role2.id))
        ]
        try await store.saveAnnotations(bookID: imported.bookID, annotations: annotations)
        await workflow.openBook(imported.bookID)
        _ = await workflow.ensureSixArchetypeVoicesForBook(for: imported.bookID, quietBanner: true)

        renderer.leadVoiceCreationHandler = { request, count in
            if request.roleID == role2.id {
                throw ServiceAPIClientError.requestTimedOut
            }
            return .init(
                voiceID: "v-exclusive-\(request.targetVoiceID)",
                voiceName: request.voiceName,
                voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                modelRevision: String(repeating: "a", count: 40)
            )
        }

        let createdCount = await workflow.createExclusiveVoicesForLeadCharacters(for: imported.bookID)
        XCTAssertGreaterThanOrEqual(createdCount, 1)
        guard let summary = workflow.lastLeadVoiceCreationSummary else {
            XCTFail("Expected lastLeadVoiceCreationSummary")
            return
        }
        XCTAssertFalse(summary.fallbacks.isEmpty)
        let fallbackID = summary.fallbacks.first!.roleID
        XCTAssertEqual(fallbackID, role2.id)
        XCTAssertTrue(workflow.fallbackRoleIDs.contains(fallbackID))

        for character in workflow.characters {
            let binding = workflow.voiceBindings[character.id]
            XCTAssertNotNil(binding, "角色 \(character.displayName) 必须具备合法音色绑定")
        }

        let fallbackBinding = workflow.voiceBindings[fallbackID]
        XCTAssertNotNil(fallbackBinding)
        XCTAssertTrue(fallbackBinding!.isSynthesisReady)

        let banner = workflow.bannerMessage ?? ""
        XCTAssertTrue(banner.contains("专属音色"))
        XCTAssertTrue(banner.contains("已回退为"))
    }

    func testVoiceDesignReturnPreservesBookAndRole() async throws {
        let (workflow, _) = makeWorkflow()
        let txtURL = tempRoot.appendingPathComponent("voice_return.txt")
        try Data("第一章 归来\n林远站在桥头。\n".utf8).write(to: txtURL)

        await workflow.prepareImport(fileURL: txtURL, encoding: .utf8)
        await workflow.confirmImport()
        let narrator = try XCTUnwrap(workflow.characters.first)

        let context = await workflow.beginVoiceRoundTrip(for: narrator.id)
        XCTAssertNotNil(context)
        XCTAssertEqual(context?.roleID, narrator.id)

        let returnedBinding = AudiobookVoiceBinding(
            roleID: narrator.id,
            voiceID: "v-designed-narrator",
            voiceRevision: "vr_0123456789abcdef0123456789abcdef",
            modelRevision: String(repeating: "a", count: 40),
            isSynthesisReady: true
        )
        await workflow.completeVoiceRoundTrip(binding: returnedBinding, context: context)
        XCTAssertEqual(workflow.voiceBindings[narrator.id], returnedBinding)
        XCTAssertFalse(workflow.voiceReturnRequiresAction, "音色登记成功属于临时操作反馈")
        XCTAssertNil(workflow.pendingVoiceReturnContext)
    }

    func testBeginAnalysisFailurePreservesErrorMessageInsteadOfBeingClearedByOpenBook() async throws {
        let (workflow, _) = makeWorkflow()
        let txtURL = tempRoot.appendingPathComponent("unconfigured.txt")
        try Data("第一章 夜雨\n雨声淅沥。\n".utf8).write(to: txtURL)

        await workflow.prepareImport(fileURL: txtURL, encoding: .utf8)
        await workflow.confirmImport()
        let bookID = try XCTUnwrap(workflow.selectedBook?.id)

        workflow.beginAnalysis(bookID)
        // 等待异步分析任务完成报错回写
        for _ in 0..<50 {
            if !workflow.isAnalyzing { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertFalse(workflow.isAnalyzing)
        XCTAssertNotNil(workflow.errorMessage, "openBook 不得清空分析失败后的错误提示")
        XCTAssertTrue(workflow.errorMessage?.contains("AI") == true)
    }

    /// 种子 fixture 契约锁：UI 测试的种子 TXT 必须经真实导入产出 3 章，
    /// 且真实规划器必须产出 3 窗（每章 1 窗）。文本与
    /// `SpeechRailApp.seedUITestAudiobookBook` 逐字一致，两边任一漂移
    /// 这里先红——前台授权跑 T05d 前的最后一道静态门。
    func testSeededFixtureTextYieldsThreeChaptersAndThreeWindows() async throws {
        let (workflow, _) = makeWorkflow()
        var lines: [String] = []
        for chapter in 1...3 {
            lines.append("第\(chapter)章 种子回声")
            lines.append("林远站在桥头望向远山。")
            lines.append("“跟紧我。”他回头说道。")
            lines.append("阿远点头，风穿过竹林。")
            lines.append("")
        }
        let txtURL = tempRoot.appendingPathComponent("seed_contract.txt")
        try Data(lines.joined(separator: "\n").utf8).write(to: txtURL)

        await workflow.prepareImport(fileURL: txtURL, encoding: .utf8)
        let preview = try XCTUnwrap(workflow.importPreview)
        XCTAssertEqual(preview.chapters.count, 3, "种子文本必须被识别为 3 章")
        await workflow.confirmImport()
        let bookID = try XCTUnwrap(workflow.selectedBook?.id)
        XCTAssertEqual(workflow.chapters.count, 3, "导入后工作台应有 3 章")

        let store = try AudiobookProjectStore(root: tempRoot)
        let chapters = try await store.chapters(for: bookID)
        let atoms = try await store.atoms(for: bookID)
        let source = try await store.sourceIndex(for: bookID)
        let config = LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "test-model")
        let snapshot = AudiobookAnalysisConfigSnapshot(configuration: config, generation: 1)
        let windows = try AudiobookAnalysisPipeline.planRootWindows(
            bookID: bookID,
            chapters: chapters,
            atoms: atoms,
            source: source,
            policy: .standard,
            config: snapshot
        )
        XCTAssertEqual(windows.count, 3, "种子书必须规划为 3 窗（每章 1 窗）")
        XCTAssertEqual(Set(windows.map(\.chapterID)).count, 3, "3 窗应分属 3 个不同章节")
    }

    func testResolvingLastUnknownSpeakerAutoConfirmsCastAndEnablesProduction() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let (workflow, _) = makeWorkflow(store: store)
        let txtURL = tempRoot.appendingPathComponent("resolve_unknown_test.txt")
        try Data("第一章 试炼\n林远站在长阶下。\n“准备好了吗？”老者问道。\n".utf8).write(to: txtURL)

        await workflow.prepareImport(fileURL: txtURL, encoding: .utf8)
        await workflow.confirmImport()
        let bookID = try XCTUnwrap(workflow.selectedBook?.id)

        let chapters = try await store.chapters(for: bookID)
        let chapter = try XCTUnwrap(chapters.first)
        let atoms = try await store.atoms(for: bookID, chapterID: chapter.id)
            .filter { $0.kind != .formatting }
        XCTAssertGreaterThanOrEqual(atoms.count, 2)

        let characters = try await store.characters(for: bookID)
        let narrator = try XCTUnwrap(characters.first(where: { $0.isNarrator }))

        // 绑定旁白音色
        await workflow.bindVoice(
            roleID: narrator.id,
            binding: AudiobookVoiceBinding(
                roleID: narrator.id,
                voiceID: "v-narrator",
                voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                modelRevision: String(repeating: "a", count: 40)
            )
        )

        // 段落 1 分配给旁白，段落 2 为未分配（待确认）
        let ann1 = AudiobookAnnotation(
            bookID: bookID,
            chapterID: chapter.id,
            windowID: UUID(),
            atomID: atoms[0].id,
            sourceRange: atoms[0].sourceRange,
            assignment: .assigned(roleID: narrator.id)
        )
        let ann2 = AudiobookAnnotation(
            bookID: bookID,
            chapterID: chapter.id,
            windowID: UUID(),
            atomID: atoms[1].id,
            sourceRange: atoms[1].sourceRange,
            assignment: .unknown(reason: "歧义对白", candidateRoleIDs: [])
        )
        try await store.saveAnnotations(bookID: bookID, annotations: [ann1, ann2])
        var book = try await store.book(id: bookID)
        book.analysisState = .allWindowsValidated
        try await store.updateBook(book)

        await workflow.leaveWorkshop()
        await workflow.openBook(bookID)
        XCTAssertFalse(workflow.isAuditionConfirmedForSelectedBook)
        XCTAssertEqual(workflow.allUnknownAnnotations.count, 1)

        // 人工确认最后一个未知对白
        await workflow.assignSpeakerAndAdvanceToNextUnknown(atomID: atoms[1].id, roleID: narrator.id)

        // 断言自动锁定与文案 (AC-1.1, AC-1.2, AC-1.3)
        XCTAssertTrue(workflow.allUnknownAnnotations.isEmpty)
        XCTAssertTrue(workflow.isAuditionConfirmedForSelectedBook)
        XCTAssertNotNil(workflow.selectedBook?.confirmedAuditionVoiceSetDigest)
        XCTAssertEqual(
            workflow.bannerMessage,
            "全部台词已确认完毕，角色与音色已自动锁定，可直接开始制作章节。"
        )
        XCTAssertNil(workflow.errorMessage)
    }

    private func prepareAutomaticCastingBook(
        workflow: AudiobookWorkflowModel,
        store: AudiobookProjectStore,
        roleCount: Int,
        sameChapter: Bool = false
    ) async throws -> [AudiobookCharacter] {
        let text = sameChapter
            ? "第一章\n" + (1..<roleCount).map { "“这是角色\($0)的台词。”" }.joined(separator: "\n")
            : (1..<roleCount).map { "第\($0)章\n“这是角色\($0)的台词。”" }.joined(separator: "\n\n")
        _ = try await importBook(into: workflow, fileName: "automatic-casting.txt", text: text)
        let bookID = try XCTUnwrap(workflow.selectedBook?.id)
        let chapters = try await store.chapters(for: bookID)
        XCTAssertEqual(chapters.count, sameChapter ? 1 : roleCount - 1)
        let narrator = try XCTUnwrap(workflow.characters.first(where: \.isNarrator))
        var roles = [narrator]
        for index in 1..<roleCount {
            roles.append(.init(bookID: bookID, displayName: "人物\(index)", isMajor: index < 8))
        }
        try await store.saveCharacters(bookID: bookID, characters: roles)
        var annotations: [AudiobookAnnotation] = []
        for (index, chapter) in chapters.enumerated() {
            let atoms = try await store.atoms(for: bookID, chapterID: chapter.id).filter { $0.kind != .formatting }
            for (atomIndex, atom) in atoms.enumerated() {
                let roleIndex = sameChapter ? min(atomIndex + 1, roleCount - 1) : index + 1
                annotations.append(.init(bookID: bookID, chapterID: chapter.id, windowID: UUID(),
                    atomID: atom.id, sourceRange: atom.sourceRange, assignment: .assigned(roleID: roles[roleIndex].id)))
            }
        }
        try await store.saveAnnotations(bookID: bookID, annotations: annotations)
        var book = try await store.book(id: bookID)
        book.analysisState = .allWindowsValidated
        try await store.updateBook(book)
        await workflow.openBook(bookID)
        return roles
    }

    func testMissingVoicesPrepareEditableMaterialsWithoutCreatingAudio() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let renderer = WorkflowFakeRenderer(), catalog = VoiceCatalogStore()
        let (workflow, _) = makeWorkflow(renderer: renderer, store: store, catalog: catalog)
        let roles = try await prepareAutomaticCastingBook(workflow: workflow, store: store, roleCount: 54)
        try await catalog.archiveVoices(voiceIDs: ["v-narrator", "v-designed-narrator"])

        await workflow.autoAssignRecommendedVoices(consentsToSharedMinorVoices: true)

        XCTAssertFalse(workflow.voiceCreationDrafts.isEmpty)
        XCTAssertLessThan(workflow.voiceCreationDrafts.count, roles.count, "可共享角色合并准备，避免逐人创建")
        XCTAssertEqual(Set(workflow.voiceCreationDrafts.flatMap(\.roleIDs)), Set(roles.map(\.id)))
        for draft in workflow.voiceCreationDrafts {
            XCTAssertFalse(draft.voiceName.isEmpty)
            XCTAssertFalse(draft.instruction.isEmpty)
            XCTAssertTrue((20...240).contains(draft.referenceText.unicodeScalars.count))
            XCTAssertNil(draft.validationMessage)
        }
        XCTAssertTrue(workflow.voiceCreationDrafts.contains { !$0.sourceEvidence.isEmpty })
        XCTAssertEqual(renderer.leadRequestCount, 0)
        XCTAssertEqual(renderer.fragmentRequestCount, 0)
        XCTAssertTrue(workflow.voiceBindings.isEmpty)
    }

    func testBatchVoiceCreationUsesReviewedSelectionAndEditedMaterials() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let renderer = WorkflowFakeRenderer(), catalog = VoiceCatalogStore()
        let (workflow, _) = makeWorkflow(renderer: renderer, store: store, catalog: catalog)
        _ = try await prepareAutomaticCastingBook(workflow: workflow, store: store, roleCount: 4)
        await workflow.prepareVoiceCreationDrafts()
        XCTAssertGreaterThanOrEqual(workflow.voiceCreationDrafts.count, 2)
        let first = try XCTUnwrap(workflow.voiceCreationDrafts.first)
        for var draft in workflow.voiceCreationDrafts {
            draft.isSelected = draft.id == first.id
            if draft.isSelected {
                draft.voiceName = "我确认的旁白"
                draft.instruction = "成熟、从容、清晰而温暖的中文叙述声音。"
                draft.referenceText = "傍晚的风吹过渡口，灯光渐渐亮起，久别的人终于踏上了归家的小路。"
            }
            workflow.updateVoiceCreationDraft(draft)
        }
        renderer.leadVoiceCreationHandler = { request, _ in
            .init(voiceID: request.targetVoiceID, voiceName: request.voiceName,
                voiceRevision: "vr_0123456789abcdef0123456789abcdef", modelRevision: String(repeating: "a", count: 40))
        }

        await workflow.createSelectedVoiceDrafts()

        let request = try XCTUnwrap(renderer.voiceCreationRequests.first)
        XCTAssertEqual(renderer.leadRequestCount, 1)
        XCTAssertEqual(request.voiceName, "我确认的旁白")
        XCTAssertEqual(request.instruction, "成熟、从容、清晰而温暖的中文叙述声音。")
        XCTAssertEqual(request.referenceTextCandidates, ["傍晚的风吹过渡口，灯光渐渐亮起，久别的人终于踏上了归家的小路。"])
        XCTAssertEqual(workflow.voiceCreationDrafts.first?.referenceTextSource, "创作者编辑的试听文稿")
        XCTAssertTrue(workflow.voiceCreationDrafts.first?.status.isCreated == true)
        XCTAssertEqual(renderer.fragmentRequestCount, 0)
        XCTAssertEqual(workflow.workbenchTab, .preparation)
        await workflow.createSelectedVoiceDrafts()
        XCTAssertEqual(renderer.leadRequestCount, 1, "成功项目不能重复提交")
    }

    func testBatchVoiceCreationRetainsSuccessAndRetriesOnlyFailures() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let renderer = WorkflowFakeRenderer()
        let (workflow, _) = makeWorkflow(renderer: renderer, store: store)
        _ = try await prepareAutomaticCastingBook(workflow: workflow, store: store, roleCount: 4)
        await workflow.prepareVoiceCreationDrafts()
        let count = workflow.voiceCreationDrafts.count
        renderer.leadVoiceCreationHandler = { request, ordinal in
            if ordinal == 2 { throw ServiceAPIClientError.requestTimedOut }
            return .init(voiceID: request.targetVoiceID, voiceName: request.voiceName,
                voiceRevision: "vr_0123456789abcdef0123456789abcdef", modelRevision: String(repeating: "a", count: 40))
        }

        await workflow.createSelectedVoiceDrafts()
        XCTAssertEqual(workflow.voiceCreationDrafts.filter { $0.status.isCreated }.count, count - 1)
        XCTAssertEqual(workflow.voiceCreationDrafts.filter { $0.status.isFailure }.count, 1)
        await workflow.createSelectedVoiceDrafts(retryFailuresOnly: true)

        XCTAssertEqual(renderer.leadRequestCount, count + 1)
        XCTAssertEqual(renderer.voiceCreationRequests[1].targetVoiceID, renderer.voiceCreationRequests.last?.targetVoiceID,
            "传输失败重试应复用同一创建身份")
        XCTAssertTrue(workflow.voiceCreationDrafts.allSatisfy { $0.status.isCreated })
        XCTAssertEqual(renderer.fragmentRequestCount, 0)
    }

    func testBatchVoiceCreationRejectsInvalidMaterialsBeforeStarting() async throws {
        let renderer = WorkflowFakeRenderer()
        let (workflow, _) = makeWorkflow(renderer: renderer)
        _ = try await importBook(into: workflow, fileName: "invalid-voice.txt", text: "第一章\n风吹过渡口。")
        await workflow.prepareVoiceCreationDrafts()
        var draft = try XCTUnwrap(workflow.voiceCreationDrafts.first)
        draft.referenceText = "太短"
        workflow.updateVoiceCreationDraft(draft)
        await workflow.createSelectedVoiceDrafts()
        XCTAssertEqual(renderer.leadRequestCount, 0)
        XCTAssertNotNil(workflow.voiceCreationErrorMessage)
    }

    func testBatchVoiceCreationRejectsChangedSourceAssignments() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let renderer = WorkflowFakeRenderer()
        let (workflow, _) = makeWorkflow(renderer: renderer, store: store)
        let roles = try await prepareAutomaticCastingBook(workflow: workflow, store: store, roleCount: 4)
        await workflow.prepareVoiceCreationDrafts()
        let annotations = try await store.annotations(for: roles[0].bookID)
        var annotation = try XCTUnwrap(annotations.first)
        annotation.assignment = .unknown(reason: "重新分析中", candidateRoleIDs: [])
        try await store.saveAnnotations(bookID: roles[0].bookID, annotations: [annotation])

        await workflow.createSelectedVoiceDrafts()

        XCTAssertEqual(renderer.leadRequestCount, 0, "原文角色归属变化后必须重新准备，不能用旧材料开始生成")
        XCTAssertTrue(workflow.voiceCreationDrafts.allSatisfy { $0.status.isFailure })
    }

    func testBatchVoiceLateResultPreservesNewSelectionAndRegistersAsset() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let renderer = WorkflowFakeRenderer(), catalog = VoiceCatalogStore()
        let (workflow, _) = makeWorkflow(renderer: renderer, store: store, catalog: catalog)
        let imported = try await importBook(into: workflow, fileName: "voice-new-selection.txt", text: "第一章\n海风吹来。")
        let narrator = try XCTUnwrap(workflow.characters.first)
        await workflow.prepareVoiceCreationDrafts(scope: .role(narrator.id))
        let gate = WorkflowRendererGate()
        renderer.leadVoiceCreationHandler = { request, _ in
            await gate.suspend()
            return .init(voiceID: request.targetVoiceID, voiceName: request.voiceName,
                voiceRevision: "vr_0123456789abcdef0123456789abcdef", modelRevision: String(repeating: "a", count: 40))
        }
        let task = Task { await workflow.createSelectedVoiceDrafts() }
        await waitForRenderSuspension(gate)
        await workflow.bindVoice(roleID: narrator.id, voiceID: "v-narrator")
        await gate.resume()
        await task.value

        XCTAssertEqual(workflow.voiceBindings[narrator.id]?.voiceID, "v-narrator")
        let createdID = try XCTUnwrap(renderer.voiceCreationRequests.first?.targetVoiceID)
        let snapshot = await catalog.refresh()
        XCTAssertEqual(snapshot.state.metadataByVoiceID[createdID]?.originBookID, imported.bookID)
        XCTAssertTrue(workflow.voiceCreationDrafts.first?.status.isCreated == true)
    }

    func testVoiceMaterialsSupportUnicodeLimitsAndPreserveEditsOnReopen() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let (workflow, _) = makeWorkflow(store: store)
        let imported = try await importBook(into: workflow, fileName: "unicode-voice.txt", text: "第一章\n海风吹来。")
        var book = try await store.book(id: imported.bookID)
        book.title = String(repeating: "长书名🎙️", count: 30)
        try await store.updateBook(book)
        await workflow.prepareVoiceCreationDrafts()
        var draft = try XCTUnwrap(workflow.voiceCreationDrafts.first)
        XCTAssertNil(draft.validationMessage)
        XCTAssertLessThanOrEqual(draft.voiceName.unicodeScalars.count, 64)
        XCTAssertTrue(draft.voiceName.contains("旁白"), "长书名也不能挤掉用于区分声音的角色名称")
        XCTAssertTrue(draft.referenceTextSource.contains("建议"))
        let originalID = draft.request.targetVoiceID
        draft.instruction = "我希望保留的声音描述"
        workflow.updateVoiceCreationDraft(draft)
        XCTAssertNotEqual(draft.request.targetVoiceID, originalID)
        await workflow.prepareVoiceCreationDrafts()
        XCTAssertEqual(workflow.voiceCreationDrafts.first?.instruction, "我希望保留的声音描述")
    }

    func testMissingVoiceMaterialsRespectExplicitTraitsAndExistingVoices() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let (workflow, _) = makeWorkflow(store: store)
        var roles = try await prepareAutomaticCastingBook(workflow: workflow, store: store, roleCount: 4)
        var traits = AudiobookVoiceTraits()
        traits.gender = .init(value: "female", source: .manual, confidence: 1)
        traits.pitch = .init(value: "low", source: .manual, confidence: 1)
        roles[1].requiredVoiceTraits = traits
        try await store.saveCharacters(bookID: roles[0].bookID, characters: roles)
        await workflow.openBook(roles[0].bookID)
        await workflow.bindVoice(roleID: roles[0].id, voiceID: "v-narrator")
        await workflow.prepareVoiceCreationDrafts()

        XCTAssertFalse(workflow.voiceCreationDrafts.flatMap(\.roleIDs).contains(roles[0].id))
        let explicit = try XCTUnwrap(workflow.voiceCreationDrafts.first { $0.roleIDs.contains(roles[1].id) })
        XCTAssertEqual(explicit.target, .role(roles[1].id), "明确声音要求不能被混入通用群像描述")
        XCTAssertTrue(explicit.instruction.contains("女性"))
        XCTAssertTrue(explicit.instruction.contains("低音"))
    }

    func testUnavailableExistingVoiceGetsReplacementMaterialsBeforeConfirmation() async throws {
        let renderer = WorkflowFakeRenderer(), catalog = VoiceCatalogStore()
        let (workflow, _) = makeWorkflow(renderer: renderer, catalog: catalog)
        _ = try await importBook(into: workflow, fileName: "missing-existing-voice.txt", text: "第一章\n海风吹来。")
        let narrator = try XCTUnwrap(workflow.characters.first)
        await workflow.bindVoice(roleID: narrator.id, voiceID: "v-narrator")
        let original = workflow.voiceBindings[narrator.id]
        try await catalog.archiveVoices(voiceIDs: ["v-narrator", "v-designed-narrator"])

        await workflow.autoAssignRecommendedVoices(consentsToSharedMinorVoices: true)

        let draft = try XCTUnwrap(workflow.voiceCreationDrafts.first)
        XCTAssertEqual(draft.target, .role(narrator.id))
        XCTAssertTrue(draft.replacesExistingVoice)
        XCTAssertEqual(workflow.voiceBindings[narrator.id], original, "浏览物料不能替换原选择")
        XCTAssertEqual(renderer.leadRequestCount, 0)
    }

    func testBatchVoiceCancellationStopsFollowingItemsAndProtectsNewSelection() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let renderer = WorkflowFakeRenderer()
        let (workflow, _) = makeWorkflow(renderer: renderer, store: store)
        let roles = try await prepareAutomaticCastingBook(workflow: workflow, store: store, roleCount: 4)
        await workflow.prepareVoiceCreationDrafts()
        let gate = WorkflowRendererGate()
        renderer.leadVoiceCreationHandler = { request, _ in
            await gate.suspend()
            return .init(voiceID: request.targetVoiceID, voiceName: request.voiceName,
                voiceRevision: "vr_0123456789abcdef0123456789abcdef", modelRevision: String(repeating: "a", count: 40))
        }
        let task = Task { await workflow.createSelectedVoiceDrafts() }
        await waitForRenderSuspension(gate)
        await workflow.bindVoice(roleID: roles[0].id, voiceID: "v-narrator")
        workflow.cancelVoiceDraftCreation()
        await gate.resume()
        await task.value

        XCTAssertEqual(renderer.leadRequestCount, 1)
        XCTAssertEqual(workflow.voiceBindings[roles[0].id]?.voiceID, "v-narrator")
        XCTAssertFalse(workflow.isCreatingVoiceDrafts)
        XCTAssertEqual(renderer.fragmentRequestCount, 0)
    }

    func testBatchVoiceSwitchingBooksDoesNotAffectNewBook() async throws {
        let renderer = WorkflowFakeRenderer()
        let (workflow, _) = makeWorkflow(renderer: renderer)
        let first = try await importBook(into: workflow, fileName: "voice-first.txt", text: "第一章\n甲书正文。")
        let second = try await importBook(into: workflow, fileName: "voice-second.txt", text: "第一章\n乙书正文。")
        await workflow.openBook(first.bookID)
        await workflow.prepareVoiceCreationDrafts()
        let gate = WorkflowRendererGate()
        renderer.leadVoiceCreationHandler = { request, _ in
            await gate.suspend()
            return .init(voiceID: request.targetVoiceID, voiceName: request.voiceName,
                voiceRevision: "vr_0123456789abcdef0123456789abcdef", modelRevision: String(repeating: "a", count: 40))
        }
        let creation = Task { await workflow.createSelectedVoiceDrafts() }
        await waitForRenderSuspension(gate)
        let loadGate = WorkflowLoadGate()
        workflow.loadCheckpointForTesting = { bookID, chapterID, checkpoint in
            if bookID == second.bookID, chapterID == nil, checkpoint == .beforeBookWorkspacePublication {
                await loadGate.suspend()
            }
        }
        let switching = Task { await workflow.openBook(second.bookID) }
        await waitForSuspension(loadGate)
        XCTAssertEqual(workflow.selectedBook?.id, first.bookID, "新作品仍在加载")
        await gate.resume()
        await creation.value
        XCTAssertNil(workflow.voiceCreationSummary, "切书开始后，旧书迟到结果不能恢复已清空的界面状态")
        loadGate.resume()
        await switching.value
        XCTAssertEqual(workflow.selectedBook?.id, second.bookID)
        XCTAssertTrue(workflow.voiceCreationDrafts.isEmpty)
        XCTAssertTrue(workflow.voiceBindings.isEmpty)
        XCTAssertNil(workflow.voiceCreationErrorMessage)
        XCTAssertNil(workflow.voiceCreationSummary)
        XCTAssertEqual(renderer.fragmentRequestCount, 0)
    }

    func testOneClickPreparesFiftyFourCharactersWithoutCreatingVoicesOrAudio() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let renderer = WorkflowFakeRenderer(), catalog = VoiceCatalogStore()
        try await catalog.registerGlobalVoice(voiceID: "v-designed-narrator", creationSource: .instantClone)
        let (workflow, _) = makeWorkflow(renderer: renderer, store: store, catalog: catalog)
        let roles = try await prepareAutomaticCastingBook(workflow: workflow, store: store, roleCount: 54)
        await workflow.bindVoice(roleID: roles[0].id, voiceID: "v-narrator")
        let originalNarrator = try XCTUnwrap(workflow.voiceBindings[roles[0].id])
        XCTAssertEqual(workflow.primaryActionTitle(.confirmCastAndVoices, for: roles[0].bookID), "一键智能配声")

        await workflow.autoAssignRecommendedVoices(consentsToSharedMinorVoices: true)

        XCTAssertNil(workflow.errorMessage)
        XCTAssertNil(workflow.pendingCastingPlan)
        XCTAssertEqual(workflow.voiceBindings.count, 54)
        XCTAssertEqual(workflow.voiceBindings[roles[0].id], originalNarrator)
        XCTAssertTrue(workflow.isAuditionConfirmedForSelectedBook)
        XCTAssertEqual(workflow.workbenchTab, .preparation)
        XCTAssertEqual(workflow.selectedBook?.productionState, .idle)
        XCTAssertNil(workflow.productionProgress)
        XCTAssertEqual(renderer.leadRequestCount, 0)
        XCTAssertEqual(renderer.fragmentRequestCount, 0)
        XCTAssertTrue(renderer.auditionRequests.isEmpty)

        let firstBindings = workflow.voiceBindings
        await workflow.autoAssignRecommendedVoices(consentsToSharedMinorVoices: true)
        XCTAssertEqual(workflow.voiceBindings, firstBindings, "再次点击不能改写已经采用的声音")
    }

    func testOneClickSharingConsentDoesNotAcceptSceneCollisions() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let renderer = WorkflowFakeRenderer(), catalog = VoiceCatalogStore()
        try await catalog.registerGlobalVoice(voiceID: "v-designed-narrator", creationSource: .instantClone)
        let (workflow, _) = makeWorkflow(renderer: renderer, store: store, catalog: catalog)
        _ = try await prepareAutomaticCastingBook(workflow: workflow, store: store, roleCount: 4, sameChapter: true)

        await workflow.autoAssignRecommendedVoices(consentsToSharedMinorVoices: true)

        let plan = try XCTUnwrap(workflow.pendingCastingPlan)
        XCTAssertTrue(plan.isApplicable)
        XCTAssertTrue(plan.issues.contains { $0.code == .sharedSceneRisk })
        XCTAssertTrue(workflow.castingPlanNeedsSeparateConfirmation)
        XCTAssertEqual(workflow.primaryActionTitle(.confirmCastAndVoices, for: try XCTUnwrap(workflow.selectedBook).id), "查看配声方案")
        XCTAssertTrue(workflow.voiceBindings.isEmpty, "一键允许配角共享不等于确认同章撞音")
        XCTAssertEqual(renderer.leadRequestCount, 0)
        XCTAssertEqual(renderer.fragmentRequestCount, 0)

        await workflow.applyPendingCastingPlan(acknowledgedIssueIDs: plan.requiredAcknowledgements)
        XCTAssertNil(workflow.pendingCastingPlan)
        XCTAssertFalse(workflow.castingPlanNeedsSeparateConfirmation)
        XCTAssertTrue(workflow.isAuditionConfirmedForSelectedBook, "集中确认后应完成配声准备，无需再点人物确认")
        XCTAssertEqual(workflow.selectedBook?.productionState, .idle)
        XCTAssertEqual(renderer.fragmentRequestCount, 0)
    }

    func testOneClickShowsProgressAndRejectsDuplicatePreparation() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let renderer = WorkflowFakeRenderer(), counter = WorkCounter()
        let (workflow, _) = makeWorkflow(renderer: renderer, store: store)
        _ = try await importBook(into: workflow, fileName: "casting-progress.txt", text: "第一章\n海风吹来。")
        let gate = WorkflowRendererGate()
        renderer.beforeCapabilityFetch = {
            _ = counter.increment()
            await gate.suspend()
        }
        let preparation = Task { await workflow.autoAssignRecommendedVoices(consentsToSharedMinorVoices: true) }
        await waitForRenderSuspension(gate)

        XCTAssertTrue(workflow.isAssigningRecommendedVoices)
        XCTAssertEqual(workflow.primaryActionTitle(.confirmCastAndVoices, for: try XCTUnwrap(workflow.selectedBook).id), "正在准备配声…")
        XCTAssertTrue(workflow.castingPreparationProgressText?.contains("1/4") == true)
        await workflow.autoAssignRecommendedVoices(consentsToSharedMinorVoices: true)
        XCTAssertEqual(counter.count, 1, "重复点击不能开始第二次准备")

        preparation.cancel()
        renderer.beforeCapabilityFetch = nil
        await gate.resume()
        await preparation.value
        XCTAssertFalse(workflow.isAssigningRecommendedVoices)
        XCTAssertNil(workflow.castingPreparationProgressText)
        XCTAssertTrue(workflow.voiceBindings.isEmpty)
        XCTAssertEqual(renderer.fragmentRequestCount, 0)
    }

    func testSwitchingBooksDuringOneClickDoesNotApplyOrReplaceCurrentProjection() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let renderer = WorkflowFakeRenderer()
        let (workflow, _) = makeWorkflow(renderer: renderer, store: store)
        let first = try await importBook(into: workflow, fileName: "casting-first.txt", text: "第一章\n甲书正文。")
        let second = try await importBook(into: workflow, fileName: "casting-second.txt", text: "第一章\n乙书正文。")
        await workflow.openBook(first.bookID)
        let gate = WorkflowRendererGate()
        renderer.beforeCapabilityFetch = { await gate.suspend() }
        let preparation = Task { await workflow.autoAssignRecommendedVoices(consentsToSharedMinorVoices: true) }
        await waitForRenderSuspension(gate)

        renderer.beforeCapabilityFetch = nil
        await workflow.openBook(second.bookID)
        let previousBanner = workflow.bannerMessage
        await gate.resume()
        await preparation.value

        XCTAssertEqual(workflow.selectedBook?.id, second.bookID)
        XCTAssertTrue(workflow.voiceBindings.isEmpty)
        XCTAssertTrue(workflow.pendingCastingPlan == nil)
        XCTAssertNil(workflow.errorMessage)
        XCTAssertEqual(workflow.bannerMessage, previousBanner)
        let originalBindings = try await store.voiceBindings(for: first.bookID)
        XCTAssertTrue(originalBindings.isEmpty)
    }

    func testAC13_to_AC15_SilentRoleFoldingDefaultScopeAndLegacyOneClickAutoCast() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let renderer = WorkflowFakeRenderer()
        renderer.leadVoiceCreationHandler = { req, count in
            .init(
                voiceID: "v-archetype-\(count)",
                voiceName: req.voiceName,
                voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                modelRevision: String(repeating: "a", count: 40)
            )
        }
        let (workflow, _) = makeWorkflow(renderer: renderer, store: store)
        let txtURL = tempRoot.appendingPathComponent("ac13_15_test.txt")
        var lines: [String] = ["第一章 七星鲁王宫"]
        for i in 1...40 {
            lines.append("“第\(i)句对白，准备下墓。”")
        }
        try Data(lines.joined(separator: "\n").utf8).write(to: txtURL)

        // AC-1.4: Default filter scope is .inCurrentChapter and order matches spec
        XCTAssertEqual(workflow.castFilterScope, AudiobookWorkflowModel.CastFilterScope.inCurrentChapter)
        XCTAssertEqual(
            AudiobookWorkflowModel.CastFilterScope.allCases,
            [.inCurrentChapter, .leads, .minorEnsemble, .all]
        )

        await workflow.prepareImport(fileURL: txtURL, encoding: .utf8)
        await workflow.confirmImport()
        let bookID = try XCTUnwrap(workflow.selectedBook?.id)

        let chapters = try await store.chapters(for: bookID)
        let chapter = try XCTUnwrap(chapters.first)
        let atoms = try await store.atoms(for: bookID, chapterID: chapter.id)
            .filter { $0.kind != .formatting }

        var characters = try await store.characters(for: bookID)
        let narrator = try XCTUnwrap(characters.first(where: \.isNarrator))

        // Simulate a legacy unstratified book where 10 roles were all saved with isMajor=true, allowSharedMinorVoice=false
        var customRoles: [AudiobookCharacter] = []
        for idx in 1...10 {
            let role = AudiobookCharacter(
                bookID: bookID,
                displayName: "测试人物_\(idx)",
                isNarrator: false,
                isMajor: true,
                allowSharedMinorVoice: false,
                chapterIDs: [chapter.id]
            )
            customRoles.append(role)
            characters.append(role)
        }
        try await store.saveCharacters(bookID: bookID, characters: characters)

        // Role 1 gets 10 lines, Role 2 gets 8 lines, Roles 3..7 get 1 line each, Roles 8..10 get 0 lines (silent mentions)
        var annotations: [AudiobookAnnotation] = []
        let winID = UUID()
        var atomCursor = 0
        func assignLines(_ count: Int, to roleID: UUID) {
            for _ in 0..<count where atomCursor < atoms.count {
                let atom = atoms[atomCursor]
                atomCursor += 1
                annotations.append(
                    AudiobookAnnotation(
                        bookID: bookID,
                        chapterID: chapter.id,
                        windowID: winID,
                        atomID: atom.id,
                        sourceRange: atom.sourceRange,
                        assignment: .assigned(roleID: roleID)
                    )
                )
            }
        }
        assignLines(5, to: narrator.id)
        assignLines(10, to: customRoles[0].id)
        assignLines(8, to: customRoles[1].id)
        for idx in 2...6 {
            assignLines(1, to: customRoles[idx].id)
        }
        while atomCursor < atoms.count {
            assignLines(1, to: narrator.id)
        }
        try await store.saveAnnotations(bookID: bookID, annotations: annotations)

        var book = try await store.book(id: bookID)
        book.analysisState = .allWindowsValidated
        try await store.updateBook(book)

        await workflow.leaveWorkshop()
        await workflow.openBook(bookID)

        // AC-1.3: Silent characters (Roles 8..10 with 0 lines) are hidden by default and counted in silentCharacterCount
        XCTAssertEqual(workflow.silentCharacterCount, 3)
        XCTAssertFalse(workflow.showSilentCharacters)
        workflow.castFilterScope = .all
        XCTAssertEqual(workflow.filteredCharacters.count, 8, "AC-1.3: 默认隐藏 3 个 0 句台词人物，仅展示旁白 + 7 个有台词角色")
        workflow.showSilentCharacters = true
        XCTAssertEqual(workflow.filteredCharacters.count, 11, "AC-1.3: 开启显示无对白人物后展示全部 11 个角色")
        workflow.showSilentCharacters = false

        // AC-1.5: Legacy unstratified book is automatically healed and one-click autoAssignRecommendedVoices() succeeds immediately
        _ = await workflow.ensureSixArchetypeVoicesForBook(for: bookID, quietBanner: true)
        _ = await workflow.refreshAvailableVoices()
        await workflow.autoAssignRecommendedVoices(for: bookID, consentsToSharedMinorVoices: true)
        XCTAssertNil(workflow.errorMessage, "AC-1.5: 一键智能配声不应因历史全员核心角色而报独立音色不足")
        if let plan = workflow.pendingCastingPlan {
            XCTAssertTrue(plan.isApplicable, "容量不足时可共享，不应卡在独占门禁")
            XCTAssertTrue(plan.issues.contains { $0.code == .sharedSceneRisk }, "同章撞音仍应集中确认")
            await workflow.applyPendingCastingPlan(acknowledgedIssueIDs: plan.requiredAcknowledgements)
        }
        XCTAssertNil(workflow.pendingCastingPlan, "AC-1.5: 无阻断冲突的智能配声应直接生效，不卡在二次确认弹窗")
        XCTAssertGreaterThanOrEqual(workflow.voiceBindings.count, 8, "AC-1.5: 所有有台词角色均已自动绑定音色")
    }

    func testAC51_to_AC55_AdaptiveWorkspaceLayoutPolicyAndRecoverablePhaseTransition() async throws {
        // AC-5.1: Dynamic inline cast column threshold & manual collapse behavior
        XCTAssertTrue(
            WindowLayoutPolicy.audiobookShowsInlineCastColumn(
                forWidth: 1_120,
                isChapterSidebarCollapsed: false,
                isCastInspectorCollapsed: false
            )
        )
        XCTAssertFalse(
            WindowLayoutPolicy.audiobookShowsInlineCastColumn(
                forWidth: 1_000,
                isChapterSidebarCollapsed: false,
                isCastInspectorCollapsed: false
            ),
            "AC-5.1: 左栏展开时 1000pt 宽度不足以同时保证 240pt 左栏 + 500pt 主区 + 360pt 右栏"
        )
        XCTAssertTrue(
            WindowLayoutPolicy.audiobookShowsInlineCastColumn(
                forWidth: 920,
                isChapterSidebarCollapsed: true,
                isCastInspectorCollapsed: false
            ),
            "AC-5.1: 收起左栏后 920pt 宽度（>= 880pt）可并排展示 500pt 主画布与 360pt 右栏"
        )
        XCTAssertFalse(
            WindowLayoutPolicy.audiobookShowsInlineCastColumn(
                forWidth: 1_440,
                isChapterSidebarCollapsed: false,
                isCastInspectorCollapsed: true
            ),
            "AC-5.1: 当右侧人物与声音栏处于收起态时，任何宽度下均不展示内联右栏，将空间释放给主画布"
        )

        // AC-5.2: Stage-aware automatic collapse & user override preservation
        XCTAssertFalse(
            WindowLayoutPolicy.audiobookRecommendedCastInspectorCollapsed(
                forTab: .preparation,
                hasUnresolvedUnknownSpeakers: false,
                isCastConfirmed: true,
                userOverride: nil
            ),
            "AC-5.2: 准备与角色阶段默认展开右侧人物栏"
        )
        XCTAssertTrue(
            WindowLayoutPolicy.audiobookRecommendedCastInspectorCollapsed(
                forTab: .production,
                hasUnresolvedUnknownSpeakers: false,
                isCastConfirmed: true,
                userOverride: nil
            ),
            "AC-5.2: 切入制作与返修阶段且无待确认说话人、已确认配声时，自动收起右侧人物栏聚焦音频片段"
        )
        XCTAssertFalse(
            WindowLayoutPolicy.audiobookRecommendedCastInspectorCollapsed(
                forTab: .production,
                hasUnresolvedUnknownSpeakers: true,
                isCastConfirmed: false,
                userOverride: nil
            ),
            "AC-5.2: 若仍有待确认说话人或未确认配声，切入制作阶段仍保持右栏展开以便即时处理"
        )
        XCTAssertFalse(
            WindowLayoutPolicy.audiobookRecommendedCastInspectorCollapsed(
                forTab: .production,
                hasUnresolvedUnknownSpeakers: false,
                isCastConfirmed: true,
                userOverride: false
            ),
            "AC-5.2: 用户手动展开右栏后（userOverride == false），阶段切换严格尊重用户显隐选择"
        )

        // Verify workflow state recoverability across workbenchTab transitions
        let store = try AudiobookProjectStore(root: tempRoot)
        let (workflow, _) = makeWorkflow(store: store)
        let txtURL = tempRoot.appendingPathComponent("ac5_state_recovery.txt")
        try Data("第一章 雾起\n“快看前面。”\n第二章 灯塔\n“到了。”\n".utf8).write(to: txtURL)
        await workflow.prepareImport(fileURL: txtURL, encoding: .utf8)
        await workflow.confirmImport()

        workflow.castFilterScope = .leads
        workflow.workbenchTab = .production
        XCTAssertEqual(workflow.castFilterScope, .leads, "切换至制作阶段必须完整保留角色筛选上下文")
        workflow.workbenchTab = .preparation
        XCTAssertEqual(workflow.castFilterScope, .leads, "切回准备阶段必须完整恢复选角上下文")
    }

    @MainActor
    func testAC61_to_AC65_ChapterProductionButtonTitleAndSplitMergeBannerCopy() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let (workflow, _) = makeWorkflow(store: store)
        let txtURL = tempRoot.appendingPathComponent("ac6_copy_contract.txt")
        try Data("第一章 启程\n第一段旁白。\n第二段旁白。\n第三段旁白。\n第二章 归途\n第四段旁白。\n".utf8).write(to: txtURL)
        await workflow.prepareImport(fileURL: txtURL, encoding: .utf8)
        await workflow.confirmImport()

        let firstChapterID = try XCTUnwrap(workflow.chapters.first?.id)
        XCTAssertEqual(
            workflow.chapterProductionButtonTitle(for: firstChapterID),
            "生成本章音频",
            "AC-6.4: 未生成成片的章节主按钮应明确为「生成本章音频」，不再使用「制作/更新本章」"
        )

        // Split chapter before middle atom and verify user-facing banner copy avoids internal jargon
        workflow.selectedChapterID = firstChapterID
        let middleAtomID = try XCTUnwrap(workflow.chapterAtoms.dropFirst().first?.id)
        workflow.selectedAtomIDs = [middleAtomID]
        await workflow.splitSelectedChapterBeforeSelectedAtom()
        XCTAssertEqual(
            workflow.bannerMessage,
            "章节已拆分，原文内容保持不变。请重新分析全书后继续制作。",
            "AC-6.1: 拆分章节反馈不得暴露「规范化原文」内部术语"
        )
        XCTAssertTrue(workflow.bannerRequiresAction, "需要重新分析的提示必须持续显示")
        XCTAssertFalse(workflow.bannerMessage?.contains("规范化原文") == true)

        await workflow.mergeSelectedChapterWithPrevious()
        XCTAssertEqual(
            workflow.bannerMessage,
            "章节已合并，原文内容保持不变。请重新分析全书后继续制作。",
            "AC-6.1: 合并章节反馈不得暴露「规范化原文」内部术语"
        )
        XCTAssertTrue(workflow.bannerRequiresAction, "需要重新分析的提示必须持续显示")
        XCTAssertFalse(workflow.bannerMessage?.contains("规范化原文") == true)

        // Simulate an adopted chapter revision and verify button title transitions to 更新本章音频
        var updatedChapters = workflow.chapters
        updatedChapters[0].currentChapterRevisionID = UUID()
        let bookID = try XCTUnwrap(workflow.selectedBook?.id)
        try await store.updateChapters(bookID: bookID, chapters: updatedChapters)
        await workflow.openBook(bookID)
        XCTAssertEqual(
            workflow.chapterProductionButtonTitle(for: updatedChapters[0].id),
            "更新本章音频",
            "AC-6.4: 已有成片的章节主按钮应动态切换为「更新本章音频」"
        )
    }

    // MARK: - 导出清单 loudness 接线

    private final class MediaRequestRecorder: Sendable {
        let mediaRequestIDs = Mutex<[UUID]>([])
        func append(_ id: UUID) { mediaRequestIDs.withLock { $0.append(id) } }
        func latest() -> UUID? { mediaRequestIDs.withLock { $0.last } }
    }

    private func makeExportWorkflow(
        store: AudiobookProjectStore,
        transport: any SpeechRailControlTransport
    ) -> AudiobookWorkflowModel {
        let config = LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "test-model")
        let deps = AudiobookDependencies(
            makeStore: { store },
            makeAnalysisClient: { _ in throw AudiobookAnalysisError.notConfigured },
            resolveAnalysisSnapshot: { generation in
                AudiobookAnalysisConfigSnapshot(configuration: config, generation: generation)
            },
            speechRenderer: WorkflowFakeRenderer(),
            controlTransport: transport
        )
        return AudiobookWorkflowModel(
            dependencies: deps,
            playbackOwner: SharedPlaybackOwner(driver: FakeDriver()),
            admission: SpeechCreationAdmission()
        )
    }

    @discardableResult
    private func makeExportableSingleChapterBook(
        workflow: AudiobookWorkflowModel,
        store: AudiobookProjectStore,
        fileName: String,
        text: String
    ) async throws -> UUID {
        let imported = try await importBook(into: workflow, fileName: fileName, text: text)
        let bookID = imported.bookID
        let chapterID = try XCTUnwrap(imported.chapterIDs.first)
        let chapters = try await store.chapters(for: bookID)
        let chapter = try XCTUnwrap(chapters.first { $0.id == chapterID })
        let characters = try await store.characters(for: bookID)
        let narrator = try XCTUnwrap(characters.first { $0.isNarrator })

        var book = try await store.book(id: bookID)
        book.analysisState = .allWindowsValidated
        try await store.updateBook(book)

        let atoms = try await store.atoms(for: bookID, chapterID: chapterID).filter { $0.kind != .formatting }
        let annotations = atoms.map { atom in
            AudiobookAnnotation(
                bookID: bookID,
                chapterID: chapterID,
                windowID: UUID(),
                atomID: atom.id,
                sourceRange: atom.sourceRange,
                assignment: .assigned(roleID: narrator.id)
            )
        }
        try await store.saveAnnotations(bookID: bookID, annotations: annotations)
        await workflow.bindVoice(
            roleID: narrator.id,
            binding: AudiobookVoiceBinding(
                roleID: narrator.id,
                voiceID: "v-narrator",
                voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                modelRevision: String(repeating: "a", count: 40)
            )
        )
        await workflow.confirmCastAndAudition()

        let source = try await store.sourceIndex(for: bookID)
        let allAtoms = try await store.atoms(for: bookID, chapterID: chapterID)
        let bindings = try await store.voiceBindings(for: bookID)
        let fragments = try AudiobookFragmentPlanner.plan(
            chapter: chapter,
            annotations: annotations,
            bindings: bindings,
            policy: .standard,
            source: source,
            atoms: allAtoms
        )
        try await store.saveFragments(bookID: bookID, chapterID: chapterID, fragments: fragments)

        let wav = WorkflowFakeRenderer.makeWAV(frameCount: 4_800)
        let candidateID = UUID()
        let candidate = AudiobookRenderCandidate(
            id: candidateID,
            bookID: bookID,
            chapterID: chapterID,
            fragmentID: fragments[0].id,
            generation: 1,
            relativeAssetPath: "books/\(bookID.uuidString)/audio/\(candidateID.uuidString).wav",
            fileSHA256: AudiobookDigest.sha256Hex(wav),
            pcmSHA256: try AudioDigest.sha256HexOfPCM(in: wav),
            frameCount: 4_800,
            dependencyDigest: fragments[0].dependencyDigest
        )
        try await store.commitCandidate(candidate, wav: wav)
        _ = try await AudiobookRevisionController(store: store)
            .promoteInitialChapterIfComplete(bookID: bookID, chapterID: chapterID)
        await workflow.openBook(bookID)
        return bookID
    }

    private func makeLoudnessExportScenario(
        fileName: String,
        text: String
    ) async throws -> (workflow: AudiobookWorkflowModel, store: AudiobookProjectStore, recorder: MediaRequestRecorder) {
        let store = try AudiobookProjectStore(root: tempRoot)
        let recorder = MediaRequestRecorder()
        let transport = ClosureControlTransport { request in
            if request.command == .mediaExport, let id = request.mediaRequestID {
                recorder.append(id)
            }
            return ControlResponse(
                requestID: request.requestID,
                command: request.command,
                status: .failed,
                errorCode: .unsupported,
                message: "测试桩：不执行真实编码"
            )
        }
        let workflow = makeExportWorkflow(store: store, transport: transport)
        _ = try await makeExportableSingleChapterBook(
            workflow: workflow,
            store: store,
            fileName: fileName,
            text: text
        )
        return (workflow, store, recorder)
    }

    private func readManifestJSON(
        store: AudiobookProjectStore,
        requestID: UUID
    ) async throws -> [String: Any] {
        let rootURL = await store.rootURL
        let url = rootURL
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent(requestID.uuidString, isDirectory: true)
            .appendingPathComponent("request.json", isDirectory: false)
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testPrepareExportLoudnessToggleDefaultsOffAndWritesV1() async throws {
        let scenario = try await makeLoudnessExportScenario(
            fileName: "loudness_off.txt",
            text: "第一章 归航\n海风停了。\n"
        )

        await scenario.workflow.prepareExport(profile: .m4b, chapterIDs: nil, loudnessEnabled: false)

        let requestID = try XCTUnwrap(scenario.recorder.latest())
        let json = try await readManifestJSON(store: scenario.store, requestID: requestID)
        XCTAssertEqual(json["schema_version"] as? String, AudiobookExportManifestPayload.v1SchemaVersion)
        XCTAssertNil(json["loudness"])
    }

    func testPrepareExportLoudnessToggleForwardsSettingsAndWritesV2() async throws {
        let scenario = try await makeLoudnessExportScenario(
            fileName: "loudness_on.txt",
            text: "第一章 扬帆\n海风起了。\n"
        )

        await scenario.workflow.prepareExport(profile: .m4b, chapterIDs: nil, loudnessEnabled: true)

        let requestID = try XCTUnwrap(scenario.recorder.latest())
        let json = try await readManifestJSON(store: scenario.store, requestID: requestID)
        XCTAssertEqual(json["schema_version"] as? String, AudiobookExportManifestPayload.v2SchemaVersion)
        let loudness = try XCTUnwrap(json["loudness"] as? [String: Any])
        XCTAssertEqual(loudness["unit"] as? String, "lufs")
        XCTAssertEqual(loudness["target_i"] as? Double, -16)
        XCTAssertEqual(loudness["true_peak_db"] as? Double, -1.5)
        XCTAssertEqual(loudness["loudness_range"] as? Double, 11)
    }
}
