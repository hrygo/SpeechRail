import Foundation
import SQLite3
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

    @MainActor
    private final class WorkflowLoadGate {
        private(set) var isSuspended = false
        private(set) var didResume = false
        private var continuation: CheckedContinuation<Void, Never>?

        func suspend() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                isSuspended = true
            }
            didResume = true
        }

        func resume() {
            continuation?.resume()
            continuation = nil
            isSuspended = false
        }
    }

    private final class WorkflowFakeRenderer: AudiobookSpeechRenderer, @unchecked Sendable {
        private let beforeRender: (@Sendable () async -> Void)?

        init(beforeRender: (@Sendable () async -> Void)? = nil) {
            self.beforeRender = beforeRender
        }

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

    private func makeWorkflow(
        driver: FakeDriver = FakeDriver(),
        renderer: WorkflowFakeRenderer = WorkflowFakeRenderer(),
        store: AudiobookProjectStore? = nil
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
            speechRenderer: renderer
        )
        let owner = SharedPlaybackOwner(driver: driver)
        let model = AudiobookWorkflowModel(
            dependencies: deps,
            playbackOwner: owner,
            admission: SpeechCreationAdmission()
        )
        return (model, driver)
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
        for _ in 0..<1_000 {
            if gate.isSuspended { return }
            await Task.yield()
        }
        XCTFail("测试读取门未被触发", file: file, line: line)
    }

    private func waitForResume(
        _ gate: WorkflowLoadGate,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if gate.didResume { return }
            await Task.yield()
        }
        XCTFail("测试读取门未恢复", file: file, line: line)
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
            await Task.yield()
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
                voiceRevision: "v1",
                modelRevision: "qwen3-tts-v1"
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
                voiceRevision: "v1",
                modelRevision: "qwen3-tts-v1"
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

    func testLatestBookOpenWinsWhenOlderResumeAndReadinessFinishLate() async throws {
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
                  checkpoint == .afterResumePlanRead
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
                  checkpoint == .beforeChapterDetailsProjection
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
                  checkpoint == .beforeChapterDetailsProjection
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
        XCTAssertEqual(try sourceAfter.text(in: sourceAfter.wholeRange), text)
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
                      checkpoint == .afterResumePlanRead else { return }
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
            for _ in 0..<1_000 {
                if workflow.isPausingProduction { break }
                await Task.yield()
            }
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
        XCTAssertTrue(workflow.voiceReturnBannerMessage?.contains("已将本书专用新音色「v-designed-narrator」绑定给角色") == true)
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
}
