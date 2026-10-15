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
        private var continuation: CheckedContinuation<Void, Never>?

        func suspend() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                isSuspended = true
            }
        }

        func hasSuspended() -> Bool { isSuspended }

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

        let secondBook = try await importBook(
            into: workflow,
            fileName: "production_second_book.txt",
            text: "第一章 乙书\n乙书正文。\n"
        )
        try await markBookReadyForProduction(secondBook.bookID, workflow: workflow, store: store)

        XCTAssertEqual(workflow.selectedBook?.id, secondBook.bookID)
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
