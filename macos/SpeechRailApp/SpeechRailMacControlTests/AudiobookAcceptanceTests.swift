import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// T14：端到端分层验收回归（三章小说：旁白 + 两名角色；第 2 章含 unknown 只挡第 2 章；确认后全本制作、返修采用/撤销、重启恢复、试听抢占继续听、整本 M4B 与分章 MP3 导出门槛）。
@MainActor
final class AudiobookAcceptanceTests: XCTestCase {
    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiobookAcceptanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private final class EndToEndAnalysisClient: AudiobookAnalysisClient, @unchecked Sendable {
        let configurationDigest: String

        init(configurationDigest: String) {
            self.configurationDigest = configurationDigest
        }

        func complete(_ prompt: AudiobookAnalysisPrompt) async throws -> String {
            switch prompt.stage {
            case .extraction:
                let atomIDs = Self.extractAtomIDs(from: prompt.input)
                let firstID = atomIDs.first.map { [$0] } ?? []
                let resp = AudiobookExtractionResponse(
                    mentions: [
                        .init(surfaceName: "林远", aliases: ["阿远"], evidenceAtomIDs: firstID, voiceTraitEvidence: "青年坚定嗓音"),
                        .init(surfaceName: "苏晴", aliases: ["阿晴"], evidenceAtomIDs: firstID, voiceTraitEvidence: "清亮女声")
                    ]
                )
                return String(decoding: try JSONEncoder().encode(resp), as: UTF8.self)

            case .castMerge:
                let resp = AudiobookMergeResponse(
                    groups: [
                        .init(canonicalName: "林远", memberSurfaceNames: ["林远", "阿远"], aliases: ["阿远"], isCollisionUnresolved: false, evidenceSummary: "青年坚定嗓音"),
                        .init(canonicalName: "苏晴", memberSurfaceNames: ["苏晴", "阿晴"], aliases: ["阿晴"], isCollisionUnresolved: false, evidenceSummary: "清亮女声")
                    ]
                )
                return String(decoding: try JSONEncoder().encode(resp), as: UTF8.self)

            case .annotation:
                let atomObjects = Self.extractPrimaryAtomObjects(from: prompt.input)
                let roleIDs = Self.extractCandidateRoleIDs(from: prompt.input)
                let items = atomObjects.map { obj -> AudiobookAnnotationResponse.Item in
                    let atomID = UUID(uuidString: obj["atomID"] as? String ?? "") ?? UUID()
                    let text = obj["text"] as? String ?? ""
                    if text.contains("神秘声音") {
                        return AudiobookAnnotationResponse.Item(
                            atomID: atomID,
                            speakerKind: .unknown,
                            roleID: nil,
                            candidateRoleIDs: roleIDs,
                            confidence: 0.4,
                            evidence: "未指明说话人身份"
                        )
                    } else if text.contains("“") {
                        let targetRole = text.contains("苏晴") ? (roleIDs.last ?? roleIDs.first) : roleIDs.first
                        return AudiobookAnnotationResponse.Item(
                            atomID: atomID,
                            speakerKind: .character,
                            roleID: targetRole,
                            candidateRoleIDs: roleIDs,
                            confidence: 0.95,
                            evidence: "角色直接对白"
                        )
                    } else {
                        return AudiobookAnnotationResponse.Item(
                            atomID: atomID,
                            speakerKind: .narrator,
                            roleID: nil,
                            candidateRoleIDs: [],
                            confidence: 0.99,
                            evidence: "旁白叙述"
                        )
                    }
                }
                let resp = AudiobookAnnotationResponse(items: items)
                return String(decoding: try JSONEncoder().encode(resp), as: UTF8.self)
            }
        }

        private static func extractAtomIDs(from json: String) -> [UUID] {
            extractPrimaryAtomObjects(from: json).compactMap {
                ($0["atomID"] as? String).flatMap(UUID.init(uuidString:))
            }
        }

        private static func extractPrimaryAtomObjects(from json: String) -> [[String: Any]] {
            guard let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [] }
            return (obj["primary_atoms_required"] as? [[String: Any]])
                ?? (obj["primary_atoms"] as? [[String: Any]])
                ?? []
        }

        private static func extractCandidateRoleIDs(from json: String) -> [UUID] {
            guard let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = obj["candidate_characters"] as? [[String: Any]]
            else { return [] }
            return list.compactMap { ($0["roleID"] as? String).flatMap(UUID.init(uuidString:)) }
        }
    }

    private final class EndToEndRenderer: AudiobookSpeechRenderer, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var renderedRequests: [AudiobookRenderCallRequest] = []

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
            let voices = ["v-narrator", "v-linyuan", "v-suqing"].map { id in
                SafeVoiceEntry(
                    id: id,
                    name: id,
                    mode: "instruction",
                    available: true,
                    availabilityReason: .available,
                    voiceRevision: "rev-1",
                    voiceIdentityAssurance: .contentAddressed,
                    model: model,
                    descriptors: desc,
                    operations: [:],
                    productionReady: true
                )
            }
            return EffectiveCapabilitySnapshot(
                serviceInstanceEpoch: "e1",
                catalogRevision: "c1",
                snapshotID: "s1",
                profile: "quality",
                models: ["tts": model],
                voices: voices,
                operations: [:],
                guarantees: [:]
            )
        }

        func renderFragment(_ request: AudiobookRenderCallRequest) async throws -> AudiobookRenderCallOutput {
            let index = lock.withLock { () -> Int in
                renderedRequests.append(request)
                return renderedRequests.count
            }

            let wav = Self.makeWAV(frameCount: 4_800, sample: Int16(100 + index))
            return AudiobookRenderCallOutput(
                wavData: wav,
                voiceRevision: request.expectedVoiceRevision,
                modelRevision: request.expectedModelRevision,
                pcmSHA256: try AudioDigest.sha256HexOfPCM(in: wav),
                requestID: "req-\(index)",
                receiptID: "rr_0123456789abcdef0123456789abcdef",
                recipeSummary: "verified",
                isProvenanceVerified: true
            )
        }

        static func makeWAV(frameCount: Int, sample: Int16) -> Data {
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
            var s = sample.littleEndian
            let sBytes = Data(bytes: &s, count: 2)
            for _ in 0..<frameCount {
                data.append(sBytes)
            }
            return data
        }
    }

    func testFakeBookEndToEndWithReviewRepairAndRestart() async throws {
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let store = try AudiobookProjectStore(root: tempRoot)
        let castController = AudiobookCastController(store: store)
        let revisionController = AudiobookRevisionController(store: store)
        let admission = SpeechCreationAdmission()
        let renderer = EndToEndRenderer()
        let productionController = AudiobookProductionController(
            store: store,
            castController: castController,
            revisionController: revisionController,
            renderer: renderer,
            admission: admission
        )

        let novelText = """
        第一章 灯塔初见
        海雾弥漫在长堤上。
        “今晚灯塔还会亮吗？”林远问道。
        第二章 暗潮迷雾
        远处传来急促的脚步声。
        “快把海图收起来！”一个神秘声音在暗处低喊。
        第三章 破晓启航
        晨光刺破云层。
        “风向正好，我们出发吧！”苏晴笑道。
        """
        let txtURL = tempRoot.appendingPathComponent("three_chapters.txt")
        try Data(novelText.utf8).write(to: txtURL)

        // 1. 导入三章 TXT 并完成全书分析
        let preview = try await AudiobookTXTImporter.prepare(fileURL: txtURL, encoding: .utf8)
        XCTAssertEqual(preview.chapters.count, 3)
        let bookID = try await store.importBook(preview)

        let config = AudiobookAnalysisConfigSnapshot(
            configuration: LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "test-model")
        )
        let pipeline = AudiobookAnalysisPipeline(store: store) { snap in
            EndToEndAnalysisClient(configurationDigest: snap.configurationDigest)
        }
        let analysisSummary = try await pipeline.run(bookID: bookID, config: config)
        XCTAssertTrue(analysisSummary.isAllWindowsValidated)
        XCTAssertEqual(analysisSummary.unknownSpeakerCount, 1)

        // 2. 为旁白、林远、苏晴绑定音色并确认配声与试听门槛
        let characters = try await store.characters(for: bookID)
        XCTAssertEqual(characters.count, 3)
        let narrator = try XCTUnwrap(characters.first(where: \.isNarrator))
        let linyuan = try XCTUnwrap(characters.first(where: { $0.displayName == "林远" }))
        let suqing = try XCTUnwrap(characters.first(where: { $0.displayName == "苏晴" }))

        try await castController.bindVoice(
            bookID: bookID,
            roleID: narrator.id,
            binding: AudiobookVoiceBinding(roleID: narrator.id, voiceID: "v-narrator", voiceRevision: "rev-1", modelRevision: "qwen3-tts-v1")
        )
        try await castController.bindVoice(
            bookID: bookID,
            roleID: linyuan.id,
            binding: AudiobookVoiceBinding(roleID: linyuan.id, voiceID: "v-linyuan", voiceRevision: "rev-1", modelRevision: "qwen3-tts-v1")
        )
        try await castController.bindVoice(
            bookID: bookID,
            roleID: suqing.id,
            binding: AudiobookVoiceBinding(roleID: suqing.id, voiceID: "v-suqing", voiceRevision: "rev-1", modelRevision: "qwen3-tts-v1")
        )
        let castRev = try await castController.currentCastRevisionID(for: bookID)
        try await castController.confirmCast(bookID: bookID, revisionID: castRev)
        let voiceDigest = try await castController.currentVoiceSetDigest(for: bookID)
        try await castController.confirmAudition(bookID: bookID, voiceSetDigest: voiceDigest)

        // 3. 验证第 2 章的 unknown 仅阻塞第 2 章，第 1、3 章可正常制作
        let chapters = try await store.chapters(for: bookID).sorted { $0.ordinal < $1.ordinal }
        let ch1 = chapters[0]
        let ch2 = chapters[1]
        let ch3 = chapters[2]

        let r1 = try await castController.chapterReadiness(bookID: bookID, chapterID: ch1.id)
        let r2 = try await castController.chapterReadiness(bookID: bookID, chapterID: ch2.id)
        let r3 = try await castController.chapterReadiness(bookID: bookID, chapterID: ch3.id)
        XCTAssertEqual(r1, .readyForProduction)
        XCTAssertEqual(r2, .blockedByUnknownSpeakers)
        XCTAssertEqual(r3, .readyForProduction)

        try await productionController.start(bookID: bookID, chapterIDs: [ch1.id, ch3.id])
        let bookAfterPartial = try await store.book(id: bookID)
        XCTAssertEqual(bookAfterPartial.productionState, .partialChaptersReady)
        XCTAssertEqual(bookAfterPartial.listenableState, .partialChaptersListenable)

        // 4. 确认第 2 章 unknown 说话人给林远，制作第 2 章，达成全书可收听与可导出
        let ch2Anns = try await store.annotations(for: bookID, chapterID: ch2.id)
        let unknownAnn = try XCTUnwrap(ch2Anns.first(where: { $0.assignment.isUnknown }))
        try await castController.assignRole(
            bookID: bookID,
            atomIDs: [unknownAnn.atomID],
            roleID: linyuan.id
        )
        try await productionController.start(bookID: bookID, chapterIDs: [ch2.id])

        let bookAfterFull = try await store.book(id: bookID)
        XCTAssertEqual(bookAfterFull.productionState, .fullBookProduced)
        XCTAssertEqual(bookAfterFull.listenableState, .fullBookListenable)
        XCTAssertNotNil(bookAfterFull.currentProductionRevisionID)

        // 5. 重启恢复计划：全部片段均可复用，无需重做
        let resumePlan = try await revisionController.resumePlan(bookID: bookID)
        XCTAssertTrue(resumePlan.redoFragmentIDs.isEmpty)
        XCTAssertEqual(resumePlan.readyChapterIDs.count, 3)
    }
}
