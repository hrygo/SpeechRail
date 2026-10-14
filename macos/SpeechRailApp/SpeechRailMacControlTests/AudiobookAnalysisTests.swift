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
            runtimeRevision: "qwen3-tts-v1",
            catalogRevision: "qwen3-tts-v1"
        )
        let voices: [SafeVoiceEntry] = [
            SafeVoiceEntry(
                id: "uncle_fu",
                name: "醇厚中文男声",
                mode: "system",
                available: true,
                availabilityReason: .available,
                voiceRevision: "v1",
                voiceIdentityAssurance: .contentAddressed,
                model: model,
                descriptors: desc,
                operations: [:],
                productionReady: true
            ),
            SafeVoiceEntry(
                id: "dylan",
                name: "北京青年男声",
                mode: "system",
                available: true,
                availabilityReason: .available,
                voiceRevision: "v1",
                voiceIdentityAssurance: .contentAddressed,
                model: model,
                descriptors: desc,
                operations: [:],
                productionReady: true
            ),
            SafeVoiceEntry(
                id: "serena",
                name: "温柔中文女声",
                mode: "system",
                available: true,
                availabilityReason: .available,
                voiceRevision: "v1",
                voiceIdentityAssurance: .contentAddressed,
                model: model,
                descriptors: desc,
                operations: [:],
                productionReady: true
            )
        ]

        let recommended = AudiobookCastRegistry.recommendVoiceBindings(
            characters: characters,
            availableVoices: voices
        )
        XCTAssertEqual(recommended.count, characters.count)
        let assignedVoiceIDs = Set(recommended.values.map(\.voiceID))
        XCTAssertEqual(assignedVoiceIDs.count, characters.count, "主要角色与旁白应优先分配互不相同的独立音色")
    }
}
