import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

final class AudiobookAnalysisTests: XCTestCase {
    nonisolated(unsafe) private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiobookAnalysisTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    private final class ScriptedAnalysisClient: AudiobookAnalysisClient, @unchecked Sendable {
        let configurationDigest: String
        private let lock = NSLock()
        private(set) var prompts: [AudiobookAnalysisPrompt] = []
        var failAnnotationWindowID: UUID?
        var onPrompt: (@Sendable (AudiobookAnalysisPrompt) async throws -> Void)?
        var simulateAliasCollision = false
        var markDialogueUnknown = false

        init(configurationDigest: String) {
            self.configurationDigest = configurationDigest
        }

        func complete(_ prompt: AudiobookAnalysisPrompt) async throws -> String {
            if let onPrompt {
                try await onPrompt(prompt)
            }
            lock.withLock {
            prompts.append(prompt)
            }

            switch prompt.stage {
            case .extraction:
                let atomIDs = Self.extractPrimaryAtomIDs(from: prompt.input)
                let firstAtom = atomIDs.first.map { [$0] } ?? []
                let mentions: [AudiobookExtractionResponse.Mention] = [
                    .init(
                        surfaceName: "林远",
                        aliases: ["阿远"],
                        evidenceAtomIDs: firstAtom,
                        voiceTraitEvidence: "青年低沉嗓音"
                    ),
                    .init(
                        surfaceName: "老周",
                        aliases: ["周掌柜"],
                        evidenceAtomIDs: firstAtom,
                        voiceTraitEvidence: nil
                    )
                ]
                let resp = AudiobookExtractionResponse(mentions: mentions)
                let data = try JSONEncoder().encode(resp)
                return String(decoding: data, as: UTF8.self)

            case .castMerge:
                let groups: [AudiobookMergeResponse.Group] = [
                    .init(
                        canonicalName: "林远",
                        memberSurfaceNames: ["林远", "阿远"],
                        aliases: ["阿远"],
                        isCollisionUnresolved: simulateAliasCollision,
                        evidenceSummary: "青年低沉嗓音"
                    ),
                    .init(
                        canonicalName: "老周",
                        memberSurfaceNames: ["老周", "周掌柜"],
                        aliases: ["周掌柜"],
                        isCollisionUnresolved: false,
                        evidenceSummary: nil
                    )
                ]
                let resp = AudiobookMergeResponse(groups: groups)
                let data = try JSONEncoder().encode(resp)
                return String(decoding: data, as: UTF8.self)

            case .annotation:
                if failAnnotationWindowID == prompt.rootWindowID {
                    throw AudiobookAnalysisError.invalidStructuredOutput("模拟窗口标注失败")
                }
                let atomIDs = Self.extractPrimaryAtomIDs(from: prompt.input)
                let roleIDs = Self.extractCandidateRoleIDs(from: prompt.input)
                let items = atomIDs.enumerated().map { idx, atomID -> AudiobookAnnotationResponse.Item in
                    if markDialogueUnknown && idx == 1 {
                        return AudiobookAnnotationResponse.Item(
                            atomID: atomID,
                            speakerKind: .unknown,
                            roleID: nil,
                            candidateRoleIDs: roleIDs,
                            confidence: 0.42,
                            evidence: "嵌套引号内说话人指代不明"
                        )
                    }
                    if let firstRole = roleIDs.first, idx % 2 == 1 {
                        return AudiobookAnnotationResponse.Item(
                            atomID: atomID,
                            speakerKind: .character,
                            roleID: firstRole,
                            candidateRoleIDs: [firstRole],
                            confidence: 0.95,
                            evidence: "林远开口说道"
                        )
                    }
                    return AudiobookAnnotationResponse.Item(
                        atomID: atomID,
                        speakerKind: .narrator,
                        roleID: nil,
                        candidateRoleIDs: [],
                        confidence: 0.99,
                        evidence: "旁白叙述"
                    )
                }
                let resp = AudiobookAnnotationResponse(items: items)
                let data = try JSONEncoder().encode(resp)
                return String(decoding: data, as: UTF8.self)
            }
        }

        private static func extractPrimaryAtomIDs(from inputJSON: String) -> [UUID] {
            guard let data = inputJSON.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [] }
            let list = (obj["primary_atoms_required"] as? [[String: Any]])
                ?? (obj["primary_atoms"] as? [[String: Any]])
                ?? []
            return list.compactMap { item in
                (item["atomID"] as? String).flatMap(UUID.init(uuidString:))
            }
        }

        private static func extractCandidateRoleIDs(from inputJSON: String) -> [UUID] {
            guard let data = inputJSON.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = obj["candidate_characters"] as? [[String: Any]]
            else { return [] }
            return list.compactMap { item in
                (item["roleID"] as? String).flatMap(UUID.init(uuidString:))
            }
        }
    }

    func testMillionCharacterBookUsesBoundedWindows() async throws {
        // 构造百万字合成文本，验证窗口规划严格遵守 4,000 primary scalars / 256 atoms / 16,000 总请求上限，且每个非格式 atom 恰出现一次
        let unitParagraph = "第一章 雾港夜航\n夜色笼罩着码头，林远站在甲板上望向远处的灯塔。“今晚风浪不小，大家守好船舵！”老周在舱门口高声提醒道。\n"
        let repeatCount = 20_500 // ~1,004,500 scalars
        let millionText = String(repeating: unitParagraph, count: repeatCount)
        let utf8 = Data(millionText.utf8)
        XCTAssertGreaterThanOrEqual(millionText.unicodeScalars.count, 1_000_000)

        let source = try AudiobookSourceIndex(utf8: utf8)
        let bookID = UUID()
        let chapter = AudiobookChapter(
            bookID: bookID,
            sourceID: UUID(),
            ordinal: 0,
            title: "全书",
            sourceRange: AudiobookSourceRange(lowerBound: 0, upperBound: Int64(utf8.count))
        )
        let atoms = try source.buildAtoms(for: chapter)
        let config = AudiobookAnalysisConfigSnapshot(
            configuration: LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "test-model")
        )
        let policy = AudiobookAnalysisPolicy.standard

        let windows = try AudiobookAnalysisPipeline.planRootWindows(
            bookID: bookID,
            chapters: [chapter],
            atoms: atoms,
            source: source,
            policy: policy,
            config: config
        )

        XCTAssertGreaterThan(windows.count, 200)
        var seenPrimaryAtomIDs: [UUID] = []
        for window in windows {
            XCTAssertLessThanOrEqual(window.primaryAtomIDs.count, policy.maxPrimaryAtoms)
            seenPrimaryAtomIDs.append(contentsOf: window.primaryAtomIDs)
        }
        let expectedReadableIDs = atoms.filter { $0.kind != .formatting }.map(\.id)
        XCTAssertEqual(seenPrimaryAtomIDs, expectedReadableIDs, "每个可读 primary atom 必须且只能被规划一次")
    }

    func testSkippedChapterPlansNoWindows() throws {
        let utf8 = Data("第一章 渡口\n夜色深沉。\n钟声响起。\n".utf8)
        let source = try AudiobookSourceIndex(utf8: utf8)
        let bookID = UUID()
        let chapter = AudiobookChapter(
            bookID: bookID,
            sourceID: UUID(),
            ordinal: 0,
            title: "第一章 渡口",
            sourceRange: AudiobookSourceRange(lowerBound: 0, upperBound: Int64(utf8.count)),
            isSkipped: true
        )
        let atoms = try source.buildAtoms(for: chapter)
        XCTAssertFalse(atoms.isEmpty)
        let windows = try AudiobookAnalysisPipeline.planRootWindows(
            bookID: bookID,
            chapters: [chapter],
            atoms: atoms,
            source: source,
            policy: .standard,
            config: AudiobookAnalysisConfigSnapshot(
                configuration: LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "test-model")
            )
        )
        XCTAssertTrue(windows.isEmpty, "跳过的章节不应产生分析窗口")
    }

    func testAnalysisReceivesManuallyEditedWorkingRevision() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let preview = try AudiobookTXTImporter.prepare(rawData: Data("第一章\n导入时的旧正文。".utf8))
        let bookID = try await store.importBook(preview)
        let draft = try await store.chapterEditDraft(bookID: bookID, chapterID: preview.chapters[0].id)
        let userText = "用户唯一正文👋哨兵，老監生寒暄之后长胖了。"
        let edited = try await store.saveChapterEdit(draft, title: "用户篇名哨兵", body: userText)
        let config = AudiobookAnalysisConfigSnapshot(configuration: LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "test-model"))
        let client = ScriptedAnalysisClient(configurationDigest: config.configurationDigest)
        let pipeline = AudiobookAnalysisPipeline(store: store) { _ in client }
        _ = try await pipeline.run(bookID: bookID, config: config)
        let inputs = client.prompts.map(\.input).joined()
        let receivedText = try client.prompts.filter { $0.stage == .extraction }.flatMap { prompt -> [String] in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(prompt.input.utf8)) as? [String: Any])
            return ((object["primary_atoms"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }
        }.joined()
        XCTAssertEqual(receivedText, userText)
        XCTAssertFalse(inputs.contains("导入时的旧正文"))
        let source = try await store.workingSourceSnapshot(bookID: bookID)
        XCTAssertEqual(source.sourceID, edited.sourceID)
        XCTAssertEqual(try source.sourceIndex.text(in: source.sourceIndex.wholeRange), userText)
        let reference = try await store.referenceSourceIndex(for: bookID)
        XCTAssertEqual(reference.utf8Data, preview.referenceUTF8)
    }

    func testAnalysisReceivesPreparedParagraphTextWithoutChangingSource() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let text = "第一章 夜行\r\n\r\n        他站在門邊，聽見了一陣腳步聲，便順著窗外的微弱燈光望\r\n向遠方。\r\n"
        let preview = try AudiobookTXTImporter.prepare(rawData: Data(text.utf8))
        let bookID = try await store.importBook(preview)
        let config = AudiobookAnalysisConfigSnapshot(
            configuration: LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "test-model")
        )
        let client = ScriptedAnalysisClient(configurationDigest: config.configurationDigest)
        let pipeline = AudiobookAnalysisPipeline(store: store) { _ in client }
        _ = try await pipeline.run(bookID: bookID, config: config)
        let texts = try client.prompts.filter { $0.stage == .extraction }.flatMap { prompt -> [String] in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(prompt.input.utf8)) as? [String: Any])
            let items = (object["primary_atoms"] as? [[String: Any]]) ?? []
            return items.compactMap { $0["text"] as? String }
        }
        let source = try await store.sourceIndex(for: bookID)
        let atoms = try await store.atoms(for: bookID)
        let atomsByID = Dictionary(uniqueKeysWithValues: atoms.map { ($0.id, $0) })
        for prompt in client.prompts {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(prompt.input.utf8)) as? [String: Any])
            for key in ["primary_atoms", "primary_atoms_required", "leading_context", "trailing_context", "leading_context_readonly", "trailing_context_readonly"] {
                for item in (object[key] as? [[String: Any]]) ?? [] {
                    guard let string = item["atomID"] as? String, let id = UUID(uuidString: string), let atom = atomsByID[id] else { continue }
                    XCTAssertEqual(item["text"] as? String, try source.text(in: atom.sourceRange))
                }
            }
        }
        XCTAssertTrue(texts.contains { $0.contains("望向遠方。") })
        XCTAssertFalse(texts.contains { $0.contains("\r") })
        XCTAssertEqual(preview.referenceUTF8, Data(text.utf8))
    }

    func testNestedQuotesAndAliasCollisionRemainReviewable() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let text = """
        第一章 客栈夜话
        林远推门走进客栈。“掌柜的，刚才有人传话：‘阿远今晚别去北码头’，这话是谁留下的？”
        老周摇了摇头没有直接回答。
        """
        let txtURL = tempRoot.appendingPathComponent("nested.txt")
        try Data(text.utf8).write(to: txtURL)
        let preview = try await AudiobookTXTImporter.prepare(fileURL: txtURL, encoding: .utf8)
        let bookID = try await store.importBook(preview)

        let config = AudiobookAnalysisConfigSnapshot(
            configuration: LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "test-model")
        )
        let fakeClient = ScriptedAnalysisClient(configurationDigest: config.configurationDigest)
        fakeClient.simulateAliasCollision = true
        fakeClient.markDialogueUnknown = true

        let pipeline = AudiobookAnalysisPipeline(store: store) { _ in fakeClient }
        let summary = try await pipeline.run(bookID: bookID, config: config)

        XCTAssertTrue(summary.isAllWindowsValidated)
        XCTAssertEqual(summary.unknownSpeakerCount, 1)
        XCTAssertGreaterThanOrEqual(summary.unresolvedCollisionCount, 1)

        let annotations = try await store.annotations(for: bookID)
        XCTAssertTrue(annotations.contains(where: { $0.assignment.isUnknown }))
    }

    func testFailedWindowBlocksWholeBookCompletion() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let text = "第一章 迷雾\n林远走上石阶。\n“谁在那里？”他低声喝道。\n"
        let txtURL = tempRoot.appendingPathComponent("fail.txt")
        try Data(text.utf8).write(to: txtURL)
        let preview = try await AudiobookTXTImporter.prepare(fileURL: txtURL, encoding: .utf8)
        let bookID = try await store.importBook(preview)

        let config = AudiobookAnalysisConfigSnapshot(
            configuration: LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "test-model")
        )
        let fakeClient = ScriptedAnalysisClient(configurationDigest: config.configurationDigest)
        let chapters = try await store.chapters(for: bookID)
        let atoms = try await store.atoms(for: bookID)
        let source = try await store.sourceIndex(for: bookID)
        let planned = try AudiobookAnalysisPipeline.planRootWindows(
            bookID: bookID,
            chapters: chapters,
            atoms: atoms,
            source: source,
            policy: .standard,
            config: config
        )
        fakeClient.failAnnotationWindowID = try XCTUnwrap(planned.first?.rootWindowID)

        let pipeline = AudiobookAnalysisPipeline(store: store) { _ in fakeClient }
        do {
            _ = try await pipeline.run(bookID: bookID, config: config)
            XCTFail("失败窗口不应允许全书分析完成")
        } catch {
            let book = try await store.book(id: bookID)
            XCTAssertEqual(book.analysisState, .failed)
            XCTAssertEqual(book.analysisFailure?.code, "invalid_structured_output")
            XCTAssertNotNil(book.analysisFailure?.failedWindowOrdinal)
            XCTAssertFalse(book.analysisFailure?.message.isEmpty ?? true)
            XCTAssertFalse(book.analysisFailure?.message.contains(text) ?? false, "失败摘要不得回显原文")
        }
    }

    func testResumeReusesOnlyMatchingCheckpoint() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let text = "第一章 启程\n林远背起行囊。\n“保重！”老周挥手道别。\n"
        let txtURL = tempRoot.appendingPathComponent("resume.txt")
        try Data(text.utf8).write(to: txtURL)
        let preview = try await AudiobookTXTImporter.prepare(fileURL: txtURL, encoding: .utf8)
        let bookID = try await store.importBook(preview)

        let configA = AudiobookAnalysisConfigSnapshot(
            configuration: LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "model-a")
        )
        let clientA = ScriptedAnalysisClient(configurationDigest: configA.configurationDigest)
        let pipeline = AudiobookAnalysisPipeline(store: store) { snap in
            ScriptedAnalysisClient(configurationDigest: snap.configurationDigest)
        }

        let firstRun = try await AudiobookAnalysisPipeline(store: store, clientFactory: { _ in clientA })
            .run(bookID: bookID, config: configA)
        XCTAssertEqual(firstRun.reusedCheckpointWindows, 0)
        let firstCallCount = clientA.prompts.count
        XCTAssertGreaterThan(firstCallCount, 0)

        // 相同配置重跑应复用全部已完成检查点
        let secondRun = try await AudiobookAnalysisPipeline(store: store, clientFactory: { _ in clientA })
            .run(bookID: bookID, config: configA)
        XCTAssertEqual(secondRun.reusedCheckpointWindows, firstRun.totalWindows)
        XCTAssertEqual(clientA.prompts.count, firstCallCount)

        // 切换模型配置后检查点指纹不同，必须重新执行
        let configB = AudiobookAnalysisConfigSnapshot(
            configuration: LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "model-b")
        )
        let thirdRun = try await pipeline.run(bookID: bookID, config: configB)
        XCTAssertEqual(thirdRun.reusedCheckpointWindows, 0)
    }

    func testStandardPolicyRerunsLegacyV1Checkpoint() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let text = "第一章 启程\n林远背起行囊。\n“保重！”老周挥手道别。\n"
        let txtURL = tempRoot.appendingPathComponent("legacy-policy.txt")
        try Data(text.utf8).write(to: txtURL)
        let preview = try await AudiobookTXTImporter.prepare(fileURL: txtURL, encoding: .utf8)
        let bookID = try await store.importBook(preview)
        let config = AudiobookAnalysisConfigSnapshot(
            configuration: LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "legacy-policy-model")
        )

        let legacyPolicy = AudiobookAnalysisPolicy(version: "audiobook_analysis_policy_v1")
        let legacyClient = ScriptedAnalysisClient(configurationDigest: config.configurationDigest)
        let legacyPipeline = AudiobookAnalysisPipeline(store: store, policy: legacyPolicy) { _ in legacyClient }
        let legacyRun = try await legacyPipeline.run(bookID: bookID, config: config)
        XCTAssertEqual(legacyRun.reusedCheckpointWindows, 0)
        XCTAssertGreaterThan(legacyClient.prompts.count, 0)

        let standardClient = ScriptedAnalysisClient(configurationDigest: config.configurationDigest)
        let standardPipeline = AudiobookAnalysisPipeline(store: store, policy: .standard) { _ in standardClient }
        let standardRun = try await standardPipeline.run(bookID: bookID, config: config)

        XCTAssertEqual(standardRun.reusedCheckpointWindows, 0)
        XCTAssertGreaterThan(standardClient.prompts.count, 0, "新策略必须重新分析旧策略创建的检查点")
    }

    func testSourceSwitchDuringClientFactoryDoesNotMarkNewRevisionRunning() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let preview = try AudiobookTXTImporter.prepare(rawData: Data("第一章 夜巡\n林远提灯前行。".utf8))
        let bookID = try await store.importBook(preview)
        let config = AudiobookAnalysisConfigSnapshot(configuration: LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "test"))
        let client = ScriptedAnalysisClient(configurationDigest: config.configurationDigest)
        let pipeline = AudiobookAnalysisPipeline(store: store) { _ in
            _ = try await store.prepareWorkingRevision(bookID: bookID, expectedSourceID: preview.sourceID)
            return client
        }
        do { _ = try await pipeline.run(bookID: bookID, config: config); XCTFail("Stale run accepted") } catch {}
        let book = try await store.book(id: bookID)
        XCTAssertEqual(book.analysisState, .notStarted)
    }

    private final class ClientSequence: @unchecked Sendable {
        let lock = NSLock()
        var clients: [ScriptedAnalysisClient]
        init(_ clients: [ScriptedAnalysisClient]) { self.clients = clients }
        func next() -> ScriptedAnalysisClient { lock.withLock { clients.removeFirst() } }
    }

    func testCancelledRunCannotOverwriteRestartedRunOnSameSource() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let preview = try AudiobookTXTImporter.prepare(rawData: Data("第一章 夜巡\n林远提灯前行。\n“跟紧我。”他说。".utf8))
        let bookID = try await store.importBook(preview)
        let config = AudiobookAnalysisConfigSnapshot(configuration: LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "test"))
        let old = ScriptedAnalysisClient(configurationDigest: config.configurationDigest)
        let fresh = ScriptedAnalysisClient(configurationDigest: config.configurationDigest)
        let clients = ClientSequence([old, fresh])
        let pipeline = AudiobookAnalysisPipeline(store: store) { _ in clients.next() }
        old.onPrompt = { prompt in
            if prompt.stage == .annotation {
                await pipeline.cancel(bookID: bookID)
                _ = try await pipeline.run(bookID: bookID, config: config)
            }
        }
        do { _ = try await pipeline.run(bookID: bookID, config: config); XCTFail("Cancelled run accepted") } catch {}
        let book = try await store.book(id: bookID)
        XCTAssertEqual(book.analysisState, .allWindowsValidated)
        XCTAssertNil(book.analysisFailure)
    }

    func testLateAnalysisFailureDoesNotChangeNewWorkingRevision() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let preview = try AudiobookTXTImporter.prepare(rawData: Data("第一章 夜巡\n林远提灯前行。\n“跟紧我。”他说。".utf8))
        let bookID = try await store.importBook(preview)
        let config = AudiobookAnalysisConfigSnapshot(configuration: LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "test-model"))
        let client = ScriptedAnalysisClient(configurationDigest: config.configurationDigest)
        client.onPrompt = { prompt in
            if prompt.stage == .annotation {
                _ = try await store.prepareWorkingRevision(bookID: bookID, expectedSourceID: preview.sourceID)
                throw ServiceAPIClientError.invalidResponse
            }
        }
        let pipeline = AudiobookAnalysisPipeline(store: store) { _ in client }
        do { _ = try await pipeline.run(bookID: bookID, config: config); XCTFail("Stale analysis accepted") } catch {}
        let book = try await store.book(id: bookID)
        XCTAssertNotEqual(book.sourceID, preview.sourceID)
        XCTAssertEqual(book.analysisState, .notStarted)
        XCTAssertNil(book.analysisFailure)
        let annotations = try await store.annotations(for: bookID)
        XCTAssertTrue(annotations.isEmpty)
    }

    func testCancelRejectsLateAnalysisAndSettingsChangeNeverChangesInFlightProvider() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let text = "第一章 夜巡\n林远提灯前行。\n“跟紧我。”他说。\n"
        let txtURL = tempRoot.appendingPathComponent("cancel.txt")
        try Data(text.utf8).write(to: txtURL)
        let preview = try await AudiobookTXTImporter.prepare(fileURL: txtURL, encoding: .utf8)
        let bookID = try await store.importBook(preview)

        let config = AudiobookAnalysisConfigSnapshot(
            configuration: LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "model-a")
        )
        let client = ScriptedAnalysisClient(configurationDigest: config.configurationDigest)
        let pipeline = AudiobookAnalysisPipeline(store: store) { _ in client }
        client.onPrompt = { _ in
            await pipeline.cancel(bookID: bookID)
        }

        do {
            _ = try await pipeline.run(bookID: bookID, config: config)
            XCTFail("取消后应抛出 cancelled")
        } catch let error as AudiobookAnalysisError {
            XCTAssertEqual(error, .cancelled)
        }

        // 若 factory 返回的 client digest 与 snapshot 不匹配（企图在途偷换 provider），立即拒绝
        let mismatchedClient = ScriptedAnalysisClient(configurationDigest: "mismatched-digest")
        let mismatchedPipeline = AudiobookAnalysisPipeline(store: store) { _ in mismatchedClient }
        do {
            _ = try await mismatchedPipeline.run(bookID: bookID, config: config)
            XCTFail("配置摘要不匹配应立即拒绝")
        } catch let error as AudiobookAnalysisError {
            XCTAssertEqual(error, .configurationChangedDuringRun)
        }
    }

    func testVoiceTraitPreservationAndAutoVoiceRecommendation() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let text = """
        第一章 雾港重逢
        海风吹拂着木栈道。
        “老周，这盏灯亮了一整夜。”林远低声说道。
        “是啊，苏晴姑娘天没亮就来过了。”老周感叹道。
        """
        let txtURL = tempRoot.appendingPathComponent("traits.txt")
        try Data(text.utf8).write(to: txtURL)
        let preview = try await AudiobookTXTImporter.prepare(fileURL: txtURL, encoding: .utf8)
        let bookID = try await store.importBook(preview)

        let config = AudiobookAnalysisConfigSnapshot(
            configuration: LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "model-traits")
        )
        let client = ScriptedAnalysisClient(configurationDigest: config.configurationDigest)
        let pipeline = AudiobookAnalysisPipeline(store: store) { _ in client }
        let summary = try await pipeline.run(bookID: bookID, config: config)
        XCTAssertTrue(summary.isAllWindowsValidated)

        let characters = try await store.characters(for: bookID)
        let linyuan = try XCTUnwrap(characters.first(where: { $0.displayName == "林远" }))
        XCTAssertEqual(linyuan.primaryVoiceTraitSummary, "青年低沉嗓音")

        let desc = SafeVoiceDescriptor(
            voiceMode: "system",
            locales: ["zh-CN"],
            styleTags: [],
            pitchBand: "unknown",
            timbreFamily: "unknown",
            baselinePace: "unknown",
            sourceType: "system_preset",
            metadataMethod: "declared_only"
        )
        let model = ConfiguredModelIdentity(
            assurance: .configuredCatalog,
            runtimeRevision: String(repeating: "a", count: 40),
            catalogRevision: String(repeating: "a", count: 40)
        )
        let voices: [SafeVoiceEntry] = [
            SafeVoiceEntry(
                id: "uncle_fu",
                name: "醇厚中文男声",
                mode: "system", isSystem: true, isDefault: true,
                available: true,
                availabilityReason: .available,
                voiceRevision: nil,
                voiceIdentityAssurance: .contentAddressed,
                model: model,
                descriptors: desc,
                operations: ["http_speech": JSONValue(.object(["parameters": JSONValue(.object(["speed": JSONValue(.object(["status": JSONValue(.string("supported")), "minimum": JSONValue(.number(0.25)), "maximum": JSONValue(.number(4))]))]))]))],
                productionReady: true
            ),
            SafeVoiceEntry(
                id: "dylan",
                name: "北京青年男声",
                mode: "system", isSystem: true, isDefault: true,
                available: true,
                availabilityReason: .available,
                voiceRevision: nil,
                voiceIdentityAssurance: .contentAddressed,
                model: model,
                descriptors: desc,
                operations: ["http_speech": JSONValue(.object(["parameters": JSONValue(.object(["speed": JSONValue(.object(["status": JSONValue(.string("supported")), "minimum": JSONValue(.number(0.25)), "maximum": JSONValue(.number(4))]))]))]))],
                productionReady: true
            ),
            SafeVoiceEntry(
                id: "serena",
                name: "温柔中文女声",
                mode: "system", isSystem: true, isDefault: true,
                available: true,
                availabilityReason: .available,
                voiceRevision: nil,
                voiceIdentityAssurance: .contentAddressed,
                model: model,
                descriptors: desc,
                operations: ["http_speech": JSONValue(.object(["parameters": JSONValue(.object(["speed": JSONValue(.object(["status": JSONValue(.string("supported")), "minimum": JSONValue(.number(0.25)), "maximum": JSONValue(.number(4))]))]))]))],
                productionReady: true
            )
        ]

        let recommended = AudiobookCastRegistry.recommendVoiceBindings(
            characters: characters, annotations: [],
            snapshot: EffectiveCapabilitySnapshot(serviceInstanceEpoch: "fixture", catalogRevision: "fixture", snapshotID: "fixture", profile: "fixture", models: ["tts": model], voices: voices, operations: [:], guarantees: [:]),
            catalog: .init(), bookID: bookID, existingBindings: [:]
        ).proposedBindings
        XCTAssertEqual(recommended.count, characters.count)
        let assignedVoiceIDs = Set(recommended.values.map(\.voiceID))
        XCTAssertEqual(assignedVoiceIDs.count, characters.count, "主要角色与旁白应优先分配互不相同的独立音色")
    }

    func testShortIndexDialogueOnlyAnnotationSlidingSpeakerAndExtractionCache() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let text = """
        第一章 雾港重逢
        海风吹拂着木栈道，远处传来低沉的汽笛声。
        “老周，这盏灯亮了一整夜。”林远低声说道。
        夜雾渐渐浓重，灯影在海面上轻轻摇晃。
        “是啊，阿远，北码头的船快靠岸了。”老周应道。
        """
        let txtURL = tempRoot.appendingPathComponent("optimized_pipeline.txt")
        try Data(text.utf8).write(to: txtURL)
        let preview = try await AudiobookTXTImporter.prepare(fileURL: txtURL, encoding: .utf8)
        let bookID = try await store.importBook(preview)

        // 使用较小窗口迫使同一章拆分为多个连续窗口，测试跨窗口说话人状态传递与阶段一缓存
        var multiWindowPolicy = AudiobookAnalysisPolicy.standard
        multiWindowPolicy.maxPrimaryAtoms = 3
        multiWindowPolicy.minWindowScalars = 10

        let config = AudiobookAnalysisConfigSnapshot(
            configuration: LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "model-opt")
        )

        final class OptimizedMockClient: AudiobookAnalysisClient, @unchecked Sendable {
            let configurationDigest: String
            private let lock = NSLock()
            var extractionCallCount = 0
            var mergePayloads: [String] = []
            var annotationInputs: [String] = []
            var shouldFailSecondWindow = true

            init(configurationDigest: String) {
                self.configurationDigest = configurationDigest
            }

            func complete(_ prompt: AudiobookAnalysisPrompt) async throws -> String {
                switch prompt.stage {
                case .extraction:
                    lock.withLock { extractionCallCount += 1 }
                    // 使用短序号 "1"、"2" 返回证据，且分别返回「林远（含别称阿远）」与独立「阿远」以测试本地别名预聚类
                    return """
                    {
                      "schema_version": "audiobook.extract.v1",
                      "mentions": [
                        {
                          "surfaceName": "林远",
                          "aliases": ["阿远"],
                          "evidenceAtomIDs": ["1", "2"],
                          "voiceTraitEvidence": "青年清朗男声"
                        },
                        {
                          "surfaceName": "阿远",
                          "aliases": [],
                          "evidenceAtomIDs": ["2"],
                          "voiceTraitEvidence": null
                        },
                        {
                          "surfaceName": "老周",
                          "aliases": ["周叔"],
                          "evidenceAtomIDs": ["2"],
                          "voiceTraitEvidence": "苍老沙哑男声"
                        }
                      ]
                    }
                    """
                case .castMerge:
                    lock.withLock { mergePayloads.append(prompt.input) }
                    return """
                    {
                      "schema_version": "audiobook.merge.v1",
                      "groups": [
                        {
                          "canonicalName": "林远",
                          "memberSurfaceNames": ["林远", "阿远"],
                          "aliases": ["阿远"],
                          "isCollisionUnresolved": false,
                          "evidenceSummary": "青年清朗男声"
                        },
                        {
                          "canonicalName": "老周",
                          "memberSurfaceNames": ["老周", "周叔"],
                          "aliases": ["周叔"],
                          "isCollisionUnresolved": false,
                          "evidenceSummary": "苍老沙哑男声"
                        }
                      ]
                    }
                    """
                case .annotation:
                    let (currentCount, failNow) = lock.withLock { () -> (Int, Bool) in
                        annotationInputs.append(prompt.input)
                        return (annotationInputs.count, shouldFailSecondWindow)
                    }
                    if currentCount >= 2 && failNow {
                        throw AudiobookAnalysisError.invalidStructuredOutput("模拟第二窗口首次中断")
                    }
                    // 仅对含对白的短序号段落返回标注（使用短序号 "1".."3" 与短角色代号 "R1"），省略纯叙述段
                    let data = Data(prompt.input.utf8)
                    let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                    let dialogueIndices = (obj["target_dialogue_indices"] as? [Int]) ?? [2, 3]
                    let itemsJSON = dialogueIndices.map { idx in
                        """
                        {
                          "atomID": "\(idx)",
                          "speakerKind": "character",
                          "roleID": "R1",
                          "candidateRoleIDs": ["R1"],
                          "confidence": 0.96,
                          "evidence": "短序号与短角色代号归属"
                        }
                        """
                    }.joined(separator: ",")
                    return """
                    {
                      "schema_version": "audiobook.annotate.v1",
                      "items": [\(itemsJSON)]
                    }
                    """
                }
            }
        }

        let client = OptimizedMockClient(configurationDigest: config.configurationDigest)
        let pipeline = AudiobookAnalysisPipeline(store: store, policy: multiWindowPolicy) { _ in client }

        // 首次运行：第 1 个窗口完成检查点落盘，第 2 个窗口模拟失败
        do {
            _ = try await pipeline.run(bookID: bookID, config: config)
            XCTFail("首次运行在第 2 窗口应抛出错误")
        } catch {
            // Expected
        }
        let firstPhase1Calls = client.extractionCallCount
        XCTAssertGreaterThanOrEqual(firstPhase1Calls, 2, "多窗口在首次运行时各执行 1 次提取")

        // 第二次重跑：窗口 1 走持久化检查点跳过，其余未完成窗口命中阶段一内存提取缓存（extractionCallCount 不再增加）
        client.shouldFailSecondWindow = false
        let summary = try await pipeline.run(bookID: bookID, config: config)
        XCTAssertTrue(summary.isAllWindowsValidated)
        XCTAssertEqual(summary.reusedCheckpointWindows, 1)
        XCTAssertEqual(client.extractionCallCount, firstPhase1Calls, "中断重跑应命中阶段一窗口提取缓存，不重复请求提取")

        // 验证阶段二归并输入：阿远已被本地预聚类进林远，且注入了 evidence_excerpts
        let mergeInput = try XCTUnwrap(client.mergePayloads.first)
        XCTAssertTrue(mergeInput.contains("evidence_excerpts"), "归并提示词应包含原文微摘要 evidence_excerpts")
        let mergeObj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(mergeInput.utf8)) as? [String: Any])
        let mergeCandidates = try XCTUnwrap(mergeObj["candidates"] as? [[String: Any]])
        XCTAssertEqual(mergeCandidates.count, 2, "『阿远』与『林远』在本地预聚类后只剩『林远』与『老周』2 个归并候选")

        // 验证阶段三跨窗口说话人状态传递：第 2 个窗口的 leading_context_readonly 中包含前序窗口已解析的 speaker
        let secondWindowPromptInput = try XCTUnwrap(client.annotationInputs.last)
        XCTAssertTrue(secondWindowPromptInput.contains("\"speaker\""), "后序窗口的 leading_context_readonly 应携带前序已解析说话人状态")

        // 验证纯叙述段自动归属旁白，对白段通过短序号与 R1 归属角色，实现 100% 覆盖
        let annotations = try await store.annotations(for: bookID)
        let allAtoms = try await store.atoms(for: bookID).filter { $0.kind != .formatting }
        XCTAssertEqual(annotations.count, allAtoms.count)
        XCTAssertEqual(summary.unknownSpeakerCount, 0)
    }

    func testInlineQuoteNarrativeGracefulFallbackWithoutCoverageViolation() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let text = """
        第一章 年底
        灰白色的沉重的晚云中间时时发出闪光，是四叔家正在“祝福”了。
        “我真傻，真的，”祥林嫂抬起她没有神采的眼睛来。
        """
        let txtURL = tempRoot.appendingPathComponent("inline_quote_test.txt")
        try Data(text.utf8).write(to: txtURL)
        let preview = try await AudiobookTXTImporter.prepare(fileURL: txtURL, encoding: .utf8)
        let bookID = try await store.importBook(preview)

        let config = AudiobookAnalysisConfigSnapshot(
            configuration: LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "model-inline")
        )

        final class InlineQuoteClient: AudiobookAnalysisClient, @unchecked Sendable {
            let configurationDigest: String
            init(configurationDigest: String) { self.configurationDigest = configurationDigest }

            func complete(_ prompt: AudiobookAnalysisPrompt) async throws -> String {
                switch prompt.stage {
                case .extraction:
                    return """
                    {
                      "schema_version": "audiobook.extract.v1",
                      "mentions": [
                        { "surfaceName": "祥林嫂", "aliases": [], "evidenceAtomIDs": ["2"], "voiceTraitEvidence": "中年悲凉妇人" }
                      ]
                    }
                    """
                case .castMerge:
                    return """
                    {
                      "schema_version": "audiobook.merge.v1",
                      "groups": [
                        { "canonicalName": "祥林嫂", "memberSurfaceNames": ["祥林嫂"], "aliases": [], "isCollisionUnresolved": false, "evidenceSummary": "中年悲凉妇人" }
                      ]
                    }
                    """
                case .annotation:
                    // 模型只标注真正的对白（第 2 段），对包含“祝福”专有名词引用的第 1 段纯叙述完全不输出
                    return """
                    {
                      "schema_version": "audiobook.annotate.v1",
                      "items": [
                        {
                          "atomID": "2",
                          "speakerKind": "character",
                          "roleID": "R1",
                          "candidateRoleIDs": ["R1"],
                          "confidence": 0.98,
                          "evidence": "祥林嫂独白"
                        }
                      ]
                    }
                    """
                }
            }
        }

        let client = InlineQuoteClient(configurationDigest: config.configurationDigest)
        let pipeline = AudiobookAnalysisPipeline(store: store) { _ in client }

        // 验证：即使第 1 段包含引号“祝福”且大模型未返回其标注，管线也绝不抛出 atomCoverageViolation 或耗尽重试
        let summary = try await pipeline.run(bookID: bookID, config: config)
        XCTAssertTrue(summary.isAllWindowsValidated)
        XCTAssertEqual(summary.completedWindows, 1)

        let annotations = try await store.annotations(for: bookID)
        let readableAtoms = try await store.atoms(for: bookID).filter { $0.kind != .formatting }
        XCTAssertEqual(annotations.count, readableAtoms.count)

        // 验证第 1 段被安全判定为旁白，第 2 段指派给祥林嫂
        let characters = try await store.characters(for: bookID)
        let xianglin = try XCTUnwrap(characters.first(where: { $0.displayName == "祥林嫂" }))
        let narrator = try XCTUnwrap(characters.first(where: { $0.isNarrator }))

        let ann1 = annotations.first(where: { $0.sourceRange == readableAtoms[0].sourceRange })
        let ann2 = annotations.first(where: { $0.sourceRange == readableAtoms[1].sourceRange })

        XCTAssertEqual(ann1?.assignment.roleID, narrator.id)
        XCTAssertEqual(ann2?.assignment.roleID, xianglin.id)
    }

    func testOmittedDirectDialogueRemainsUnknownInsteadOfNarrator() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let text = """
        第一章 夜谈
        “你来了。”林远望向门口。
        “我回来了。”阿远轻声回答。
        """
        let txtURL = tempRoot.appendingPathComponent("omitted_dialogue.txt")
        try Data(text.utf8).write(to: txtURL)
        let preview = try await AudiobookTXTImporter.prepare(fileURL: txtURL, encoding: .utf8)
        let bookID = try await store.importBook(preview)
        let config = AudiobookAnalysisConfigSnapshot(
            configuration: LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "model-omission")
        )

        final class OmittedDialogueClient: AudiobookAnalysisClient, @unchecked Sendable {
            let configurationDigest: String
            init(configurationDigest: String) { self.configurationDigest = configurationDigest }

            func complete(_ prompt: AudiobookAnalysisPrompt) async throws -> String {
                switch prompt.stage {
                case .extraction:
                    return """
                    {
                      "schema_version": "audiobook.extract.v1",
                      "mentions": [
                        { "surfaceName": "林远", "aliases": [], "evidenceAtomIDs": ["1"], "voiceTraitEvidence": "青年男声" }
                      ]
                    }
                    """
                case .castMerge:
                    return """
                    {
                      "schema_version": "audiobook.merge.v1",
                      "groups": [
                        { "canonicalName": "林远", "memberSurfaceNames": ["林远"], "aliases": [], "isCollisionUnresolved": false, "evidenceSummary": "青年男声" }
                      ]
                    }
                    """
                case .annotation:
                    let data = Data(prompt.input.utf8)
                    let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                    let dialogueIndices = object["target_dialogue_indices"] as? [Int] ?? []
                    guard let firstDialogueIndex = dialogueIndices.first else {
                        return """
                        { "schema_version": "audiobook.annotate.v1", "items": [] }
                        """
                    }
                    // 故意漏掉其余直接对白，模拟模型只返回部分标注。
                    return """
                    {
                      "schema_version": "audiobook.annotate.v1",
                      "items": [
                        {
                          "atomID": "\(firstDialogueIndex)",
                          "speakerKind": "character",
                          "roleID": "R1",
                          "candidateRoleIDs": ["R1"],
                          "confidence": 0.96,
                          "evidence": "林远发言"
                        }
                      ]
                    }
                    """
                }
            }
        }

        let client = OmittedDialogueClient(configurationDigest: config.configurationDigest)
        let pipeline = AudiobookAnalysisPipeline(store: store) { _ in client }
        let summary = try await pipeline.run(bookID: bookID, config: config)
        let annotations = try await store.annotations(for: bookID)
        let source = try await store.sourceIndex(for: bookID)
        let atoms = try await store.atoms(for: bookID)
            .filter { $0.kind == .body }
            .sorted { $0.sourceRange < $1.sourceRange }
        let dialogueAtoms = try atoms.filter {
            AudiobookPromptAtomItem.isDirectDialogue(in: try source.text(in: $0.sourceRange))
        }
        let omittedDialogue = try XCTUnwrap(dialogueAtoms.dropFirst().first)
        let omittedAnnotation = try XCTUnwrap(annotations.first { $0.atomID == omittedDialogue.id })

        XCTAssertTrue(summary.isAllWindowsValidated)
        XCTAssertEqual(dialogueAtoms.count, 2)
        XCTAssertTrue(
            omittedAnnotation.assignment.isUnknown,
            "模型漏标的直接对白必须进入待确认状态，不能静默改派旁白"
        )
        XCTAssertEqual(summary.unknownSpeakerCount, 1)
    }

    func testMergeBatchUsesEvidenceChapterWhenSelectingExistingCast() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let text = """
        第一章 港口
        灯塔照亮了空荡的码头。
        第二章 重逢
        阿远沿着岸边走去。
        """
        let txtURL = tempRoot.appendingPathComponent("merge_context.txt")
        try Data(text.utf8).write(to: txtURL)
        let preview = try await AudiobookTXTImporter.prepare(fileURL: txtURL, encoding: .utf8)
        let bookID = try await store.importBook(preview)
        let chapters = try await store.chapters(for: bookID)
        XCTAssertEqual(chapters.count, 2)
        let targetRole = AudiobookCharacter(
            bookID: bookID,
            displayName: "林远",
            aliases: [],
            isMajor: true,
            chapterIDs: [chapters[1].id]
        )
        let firstChapterRoles = (0..<32).map { index in
            AudiobookCharacter(
                bookID: bookID,
                displayName: String(format: "先行角色%02d", index),
                isMajor: true,
                chapterIDs: [chapters[0].id]
            )
        }
        try await store.saveCharacters(bookID: bookID, characters: firstChapterRoles + [targetRole])

        let config = AudiobookAnalysisConfigSnapshot(
            configuration: LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "model-merge-context")
        )
        final class MergeContextClient: AudiobookAnalysisClient, @unchecked Sendable {
            let configurationDigest: String
            init(configurationDigest: String) { self.configurationDigest = configurationDigest }

            func complete(_ prompt: AudiobookAnalysisPrompt) async throws -> String {
                switch prompt.stage {
                case .extraction:
                    let data = Data(prompt.input.utf8)
                    let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                    let atoms = object["primary_atoms"] as? [[String: Any]] ?? []
                    guard let evidenceAtom = atoms.first(where: {
                        ($0["text"] as? String)?.contains("阿远") == true
                    }) else {
                        return """
                        { "schema_version": "audiobook.extract.v1", "mentions": [] }
                        """
                    }
                    let atomRef = (evidenceAtom["idx"] as? Int).map { String($0) }
                        ?? (evidenceAtom["atomID"] as? String ?? "1")
                    return """
                    {
                      "schema_version": "audiobook.extract.v1",
                      "mentions": [
                        { "surfaceName": "阿远", "aliases": [], "evidenceAtomIDs": ["\(atomRef)"], "voiceTraitEvidence": "青年男声" }
                      ]
                    }
                    """
                case .castMerge:
                    // The fake can only resolve the alias to the existing role when that role is present in context.
                    let canonicalName = prompt.input.contains("林远") ? "林远" : "阿远"
                    return """
                    {
                      "schema_version": "audiobook.merge.v1",
                      "groups": [
                        { "canonicalName": "\(canonicalName)", "memberSurfaceNames": ["阿远"], "aliases": [], "isCollisionUnresolved": false, "evidenceSummary": "青年男声" }
                      ]
                    }
                    """
                case .annotation:
                    return """
                    { "schema_version": "audiobook.annotate.v1", "items": [] }
                    """
                }
            }
        }

        let client = MergeContextClient(configurationDigest: config.configurationDigest)
        let pipeline = AudiobookAnalysisPipeline(store: store) { _ in client }
        let summary = try await pipeline.run(bookID: bookID, config: config)
        let characters = try await store.characters(for: bookID)
        let sameIdentity = characters.filter {
            !$0.isNarrator
                && ($0.id == targetRole.id || $0.displayName == "阿远" || $0.aliases.contains("阿远"))
        }

        XCTAssertTrue(summary.isAllWindowsValidated)
        XCTAssertEqual(
            sameIdentity.map(\.id),
            [targetRole.id],
            "归并批次应看到目标证据章节中的既有角色，避免为同一人物新增重复角色"
        )
        XCTAssertTrue(try XCTUnwrap(sameIdentity.first).aliases.contains("阿远"))
    }

    func testExactNameMatchOutranksMultiChapterEvidenceOverlap() throws {
        let bookID = UUID()
        let evidenceChapters = Set([UUID(), UUID(), UUID()])
        let broadChapterRole = AudiobookCharacter(
            bookID: bookID,
            displayName: "候选角色",
            isMajor: true,
            chapterIDs: Array(evidenceChapters)
        )
        let exactNameRole = AudiobookCharacter(
            bookID: bookID,
            displayName: "阿远",
            chapterIDs: []
        )

        let selected = AudiobookCastRegistry.selectCandidateSummariesForEvidence(
            characters: [broadChapterRole, exactNameRole],
            chapterIDs: evidenceChapters,
            windowText: "阿远",
            policy: .standard
        )

        XCTAssertEqual(selected.first?.roleID, exactNameRole.id)
    }
}
