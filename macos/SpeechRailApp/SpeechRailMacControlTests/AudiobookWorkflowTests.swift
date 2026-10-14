import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

@MainActor
final class AudiobookWorkflowTests: XCTestCase {
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

    private final class WorkflowFakeRenderer: AudiobookSpeechRenderer, @unchecked Sendable {
        func fetchEffectiveCapabilities() async throws -> EffectiveCapabilitySnapshot {
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
            let model = ConfiguredModelIdentity(
                assurance: .configuredCatalog,
                runtimeRevision: "qwen3-tts-v1",
                catalogRevision: "qwen3-tts-v1"
            )
            return EffectiveCapabilitySnapshot(
                serviceInstanceEpoch: "e1",
                catalogRevision: "c1",
                snapshotID: "s1",
                profile: "quality",
                models: ["tts": model],
                voices: [
                    SafeVoiceEntry(
                        id: "v-narrator",
                        name: "旁白",
                        mode: "instruction",
                        available: true,
                        availabilityReason: .available,
                        voiceRevision: "v1",
                        voiceIdentityAssurance: .contentAddressed,
                        model: model,
                        descriptors: desc,
                        operations: [:],
                        productionReady: true
                    )
                ],
                operations: [:],
                guarantees: [:]
            )
        }

        func renderFragment(_ request: AudiobookRenderCallRequest) async throws -> AudiobookRenderCallOutput {
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

    private func makeWorkflow(
        driver: FakeDriver = FakeDriver()
    ) -> (AudiobookWorkflowModel, FakeDriver) {
        let root = tempRoot!
        let config = LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "test-model")
        let deps = AudiobookDependencies(
            makeStore: { try AudiobookProjectStore(root: root) },
            makeAnalysisClient: { snap in
                throw AudiobookAnalysisError.notConfigured
            },
            resolveAnalysisSnapshot: { gen in
                AudiobookAnalysisConfigSnapshot(configuration: config, generation: gen)
            },
            speechRenderer: WorkflowFakeRenderer()
        )
        let owner = SharedPlaybackOwner(driver: driver)
        let model = AudiobookWorkflowModel(
            dependencies: deps,
            playbackOwner: owner,
            admission: SpeechCreationAdmission()
        )
        return (model, driver)
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
                voiceRevision: "v1",
                modelRevision: "qwen3-tts-v1"
            )
        )
        await workflow.confirmCastAndAudition()
        XCTAssertEqual(workflow.selectedBookPrimaryAction, .makeConfirmedChapters)
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
            binding: AudiobookVoiceBinding(roleID: narrator.id, voiceID: "v-narrator", voiceRevision: "v1", modelRevision: "qwen3-tts-v1")
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
            voiceRevision: "v1",
            modelRevision: "qwen3-tts-v1",
            isSynthesisReady: true
        )
        await workflow.completeVoiceRoundTrip(binding: returnedBinding, context: context)
        XCTAssertEqual(workflow.voiceBindings[narrator.id]?.voiceID, "v-designed-narrator")
        XCTAssertTrue(workflow.voiceReturnBannerMessage?.contains("已将新音色绑定给角色") == true)
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
}
