import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 段落重做、采用与导出的确定性回归：不合成、不播放、不碰真实作品库。
@MainActor
final class DubbingProjectStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechrail-dubbing-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Fixtures

    private func provenance(digest: String, state: RenderRecipeSnapshot.State = .complete)
    -> RenderProvenanceSnapshot {
        RenderProvenanceSnapshot(
            state: state == .complete ? .verified : .partial,
            reason: nil,
            recipe: RenderRecipeSnapshot(
                state: state,
                missingFields: state == .complete ? [] : ["model.engine_revision"],
                digest: state == .complete ? digest : nil,
                voiceID: "ryan"
            )
        )
    }

    private func makeProject(
        recipeDigest: String = "a",
        state: RenderRecipeSnapshot.State = .complete,
        segments: [DubbingSegment] = [
            DubbingSegment(id: "seg_first", text: "第一段。"),
            DubbingSegment(id: "seg_second", text: "第二段。"),
        ]
    ) -> DubbingProject {
        DubbingProject(
            id: "project_one",
            title: "示例配音",
            scriptText: "第一段。\n第二段。",
            recipe: provenance(digest: recipeDigest, state: state),
            segments: segments,
            createdAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
    }

    private func makeCandidate(
        id: String,
        segmentID: String,
        text: String,
        recipeDigest: String = "a",
        state: RenderRecipeSnapshot.State = .complete
    ) -> DubbingCandidate {
        DubbingCandidate(
            id: id,
            segmentID: segmentID,
            text: text,
            audioFileName: "\(id).wav",
            provenance: provenance(digest: recipeDigest, state: state)
        )
    }

    private func wav(_ marker: UInt8, samples: Int = 4) -> Data {
        var pcm = Data()
        for index in 0..<samples {
            pcm.append(marker)
            pcm.append(UInt8(index))
        }
        return (try? DubbingAudioExport.makeWAV(from: [pcm], sampleRate: 24_000)) ?? Data()
    }

    // MARK: - 候选与采用

    func testSavingACandidateDoesNotAdoptIt() throws {
        let store = DubbingProjectStore(directory: directory)
        let project = makeProject()
        try store.save(project)

        let candidate = try store.addCandidate(
            makeCandidate(id: "cand_a", segmentID: "seg_first", text: "第一段。"),
            audioData: wav(0x11),
            toProject: project.id
        )

        XCTAssertEqual(candidate.provenance.audioFileSHA256?.count, 64)
        let reloaded = try XCTUnwrap(store.list().first)
        XCTAssertNil(
            reloaded.segments[0].acceptedCandidateID,
            "保存候选只是新增资产，采用必须由用户显式决定"
        )
        XCTAssertEqual(try store.candidates(forProject: project.id).map(\.id), ["cand_a"])
    }

    func testAdoptingSwitchesTheReferenceAndKeepsTheEarlierAudio() throws {
        let store = DubbingProjectStore(directory: directory)
        let project = makeProject()
        try store.save(project)
        let first = try store.addCandidate(
            makeCandidate(id: "cand_a", segmentID: "seg_first", text: "第一段。"),
            audioData: wav(0x11),
            toProject: project.id
        )
        let second = try store.addCandidate(
            makeCandidate(id: "cand_b", segmentID: "seg_first", text: "第一段。"),
            audioData: wav(0x22),
            toProject: project.id
        )

        let adopted = try store.adopt(
            candidateID: first.id,
            inSegment: "seg_first",
            ofProject: project.id
        )
        let readopted = try store.adopt(
            candidateID: second.id,
            inSegment: "seg_first",
            ofProject: project.id
        )

        XCTAssertEqual(readopted.segments[0].acceptedCandidateID, second.id)
        XCTAssertEqual(
            try store.loadAudio(for: first),
            wav(0x11),
            "采用只改引用，旧候选的音频不能被销毁"
        )
        XCTAssertEqual(
            adopted.segments[0].adoptionHistory,
            [nil],
            "第一次采用要记住此前什么都没采用，否则撤销会退到不存在的版本"
        )
        XCTAssertEqual(readopted.segments[0].adoptionHistory, [nil, first.id])
    }

    func testUndoReturnsToThePreviousAdoptionAndStopsAtTheStart() throws {
        let store = DubbingProjectStore(directory: directory)
        let project = makeProject()
        try store.save(project)
        let first = try store.addCandidate(
            makeCandidate(id: "cand_a", segmentID: "seg_first", text: "第一段。"),
            audioData: wav(0x11),
            toProject: project.id
        )
        let second = try store.addCandidate(
            makeCandidate(id: "cand_b", segmentID: "seg_first", text: "第一段。"),
            audioData: wav(0x22),
            toProject: project.id
        )
        try store.adopt(candidateID: first.id, inSegment: "seg_first", ofProject: project.id)
        try store.adopt(candidateID: second.id, inSegment: "seg_first", ofProject: project.id)

        let undone = try store.undoAdoption(inSegment: "seg_first", ofProject: project.id)
        XCTAssertEqual(undone.segments[0].acceptedCandidateID, first.id)

        let undoneAgain = try store.undoAdoption(
            inSegment: "seg_first",
            ofProject: project.id
        )
        XCTAssertNil(
            undoneAgain.segments[0].acceptedCandidateID,
            "没有历史时保持未采用，而不是回到一个不存在的版本"
        )
    }

    func testACandidateFromAnotherRecipeCannotBeAdopted() throws {
        let store = DubbingProjectStore(directory: directory)
        let project = makeProject(recipeDigest: "a")
        try store.save(project)
        let foreign = try store.addCandidate(
            makeCandidate(id: "cand_a", segmentID: "seg_first", text: "第一段。", recipeDigest: "b"),
            audioData: wav(0x11),
            toProject: project.id
        )

        XCTAssertThrowsError(
            try store.adopt(
                candidateID: foreign.id,
                inSegment: "seg_first",
                ofProject: project.id
            )
        ) { error in
            XCTAssertEqual(error as? DubbingProjectError, .candidateNotAdoptable)
        }
        XCTAssertNil(try XCTUnwrap(store.list().first).segments[0].acceptedCandidateID)
    }

    func testAnIncompleteRecipeMakesEveryCandidateUnusable() throws {
        let store = DubbingProjectStore(directory: directory)
        let project = makeProject(state: .partial)
        try store.save(project)
        let candidate = try store.addCandidate(
            makeCandidate(id: "cand_a", segmentID: "seg_first", text: "第一段。", state: .partial),
            audioData: wav(0x11),
            toProject: project.id
        )

        XCTAssertThrowsError(
            try store.adopt(
                candidateID: candidate.id,
                inSegment: "seg_first",
                ofProject: project.id
            )
        ) { error in
            XCTAssertEqual(error as? DubbingProjectError, .candidateNotAdoptable)
        }
    }

    func testACandidateWhoseTextNoLongerMatchesIsNotAdoptable() throws {
        let store = DubbingProjectStore(directory: directory)
        let project = makeProject()
        try store.save(project)
        let stale = try store.addCandidate(
            makeCandidate(id: "cand_a", segmentID: "seg_first", text: "改过的第一段。"),
            audioData: wav(0x11),
            toProject: project.id
        )

        XCTAssertThrowsError(
            try store.adopt(
                candidateID: stale.id,
                inSegment: "seg_first",
                ofProject: project.id
            )
        )
    }

    func testSavingTheSameCandidateTwiceIsIdempotent() throws {
        let store = DubbingProjectStore(directory: directory)
        try store.save(makeProject())
        let candidate = makeCandidate(id: "cand_a", segmentID: "seg_first", text: "第一段。")
        let audio = wav(0x11)

        let first = try store.addCandidate(candidate, audioData: audio, toProject: "project_one")
        let retried = try store.addCandidate(candidate, audioData: audio, toProject: "project_one")

        XCTAssertEqual(first, retried)
        XCTAssertEqual(try store.candidates(forProject: "project_one").count, 1)
    }

    func testReusingACandidateIDForDifferentAudioIsRefused() throws {
        let store = DubbingProjectStore(directory: directory)
        try store.save(makeProject())
        let candidate = makeCandidate(id: "cand_a", segmentID: "seg_first", text: "第一段。")
        try store.addCandidate(candidate, audioData: wav(0x11), toProject: "project_one")

        XCTAssertThrowsError(
            try store.addCandidate(candidate, audioData: wav(0x99), toProject: "project_one")
        ) { error in
            XCTAssertEqual(error as? DubbingProjectError, .candidateNotAdoptable)
        }
        XCTAssertEqual(try store.loadAudio(for: candidate), wav(0x11))
    }

    // MARK: - 导出

    func testExportJoinsOnlyAdoptedSegmentsAndMatchesTheScript() throws {
        let store = DubbingProjectStore(directory: directory)
        let project = makeProject()
        try store.save(project)
        let first = try store.addCandidate(
            makeCandidate(id: "cand_a", segmentID: "seg_first", text: "第一段。"),
            audioData: wav(0x11),
            toProject: project.id
        )
        let second = try store.addCandidate(
            makeCandidate(id: "cand_b", segmentID: "seg_second", text: "第二段。"),
            audioData: wav(0x22, samples: 6),
            toProject: project.id
        )
        try store.adopt(candidateID: first.id, inSegment: "seg_first", ofProject: project.id)

        XCTAssertNil(
            try store.export(projectID: project.id),
            "有一段还没采用时不能导出半成品"
        )

        try store.adopt(candidateID: second.id, inSegment: "seg_second", ofProject: project.id)
        let exported = try XCTUnwrap(try store.export(projectID: project.id))

        let expectedPCM = try DubbingAudioExport.pcmData(fromWAV: wav(0x11))
            + DubbingAudioExport.pcmData(fromWAV: wav(0x22, samples: 6))
        XCTAssertEqual(
            try DubbingAudioExport.pcmData(fromWAV: exported.audio),
            expectedPCM,
            "导出音频必须是被采用候选的样本按段落顺序拼接"
        )
        XCTAssertEqual(exported.script, "第一段。\n第二段。")
    }

    func testExportStopsWhenAnAdoptedCandidateLostItsRecipe() throws {
        let store = DubbingProjectStore(directory: directory)
        let project = makeProject()
        try store.save(project)
        let first = try store.addCandidate(
            makeCandidate(id: "cand_a", segmentID: "seg_first", text: "第一段。"),
            audioData: wav(0x11),
            toProject: project.id
        )
        try store.adopt(candidateID: first.id, inSegment: "seg_first", ofProject: project.id)

        // 项目配方变了：旧候选不再代表当前制作条件。
        try store.save(makeProject(recipeDigest: "b"))

        XCTAssertNil(try store.export(projectID: project.id))
    }

    func testWAVExportRewritesTheHeaderForTheJoinedAudio() throws {
        let pcm = Data([0x01, 0x00, 0x02, 0x00])
        let exported = try DubbingAudioExport.makeWAV(from: [pcm, pcm], sampleRate: 16_000)

        XCTAssertEqual(exported.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(exported.subdata(in: 8..<12), Data("WAVE".utf8))
        XCTAssertEqual(
            Int(exported.subdata(in: 40..<44).littleEndianUInt32ForTest),
            pcm.count * 2
        )
        XCTAssertEqual(try DubbingAudioExport.pcmData(fromWAV: exported), pcm + pcm)
        XCTAssertEqual(exported.count, 44 + pcm.count * 2)
    }

    func testOddSizedSamplesAreRefusedInsteadOfSilentlyPadded() throws {
        XCTAssertThrowsError(
            try DubbingAudioExport.makeWAV(from: [Data([0x01])], sampleRate: 24_000)
        )
        XCTAssertThrowsError(
            try DubbingAudioExport.pcmData(fromWAV: Data("not a wav at all".utf8))
        )
    }

    // MARK: - 恢复

    func testRestartReclaimsAnUncommittedCandidate() throws {
        let store = DubbingProjectStore(directory: directory)
        let project = makeProject()
        try store.save(project)
        let interrupting = CreativeWorkFileOperations(
            syncInterceptor: { url in
                if url.lastPathComponent == "cand_crash.wav" {
                    throw CreativeWorkTransactionInterruption.simulatedProcessExit
                }
            }
        )
        let crashing = DubbingProjectStore(
            directory: directory,
            fileOperations: interrupting
        )

        XCTAssertThrowsError(
            try crashing.addCandidate(
                makeCandidate(id: "cand_crash", segmentID: "seg_first", text: "第一段。"),
                audioData: wav(0x11),
                toProject: project.id
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("cand_crash.wav").path
            ),
            "模拟中断发生在音频发布之后"
        )

        let reopened = DubbingProjectStore(directory: directory)
        XCTAssertEqual(try reopened.list().map(\.id), [project.id])
        XCTAssertTrue(try reopened.candidates(forProject: project.id).isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("cand_crash.wav").path
            ),
            "索引没提交，重启必须回收刚发布的音频"
        )
    }

    func testRestartKeepsACommittedCandidate() throws {
        let armed = ArmedInterruption()
        let interrupting = CreativeWorkFileOperations(
            syncInterceptor: { url in
                if armed.isArmed, url.lastPathComponent == "projects.json" {
                    throw CreativeWorkTransactionInterruption.simulatedProcessExit
                }
            }
        )
        let store = DubbingProjectStore(
            directory: directory,
            fileOperations: interrupting
        )
        try store.save(makeProject())
        armed.isArmed = true

        XCTAssertThrowsError(
            try store.addCandidate(
                makeCandidate(id: "cand_done", segmentID: "seg_first", text: "第一段。"),
                audioData: wav(0x11),
                toProject: "project_one"
            )
        )

        let reopened = DubbingProjectStore(directory: directory)
        XCTAssertEqual(try reopened.candidates(forProject: "project_one").map(\.id), ["cand_done"])
        XCTAssertEqual(try reopened.loadAudio(for: try XCTUnwrap(
 reopened.candidates(forProject: "project_one").first)), wav(0x11))
    }
}

/// Lets a test interrupt exactly one later commit instead of the first one.
private final class ArmedInterruption {
    var isArmed = false
}

private extension Data {
    var littleEndianUInt32ForTest: UInt32 {
        UInt32(self[0]) | UInt32(self[1]) << 8 | UInt32(self[2]) << 16 | UInt32(self[3]) << 24
    }
}

// MARK: - 切分：只用文稿，不产生任何时间戳

final class DubbingSegmentPlannerTests: XCTestCase {
    func testParagraphsSplitOnLineBreaksAndBlankLinesAreDropped() {
        let segments = DubbingSegmentPlanner.segments(
            from: "第一段正文。\n\n  第二段正文。  \n\n"
        )
        XCTAssertEqual(segments, ["第一段正文。", "第二段正文。"])
    }

    func testEmptyScriptProducesNoSegments() {
        XCTAssertEqual(DubbingSegmentPlanner.segments(from: "   \n\n  "), [])
    }

    func testLongParagraphSplitsAtSentenceBoundariesWithinTheLimit() {
        let sentence = String(repeating: "这是一个句子。", count: 40)
        let segments = DubbingSegmentPlanner.segments(from: sentence)

        XCTAssertGreaterThan(segments.count, 1, "超长段落必须可切分，否则无法局部返修")
        for segment in segments {
            XCTAssertLessThanOrEqual(
                segment.count,
                DubbingSegmentPlanner.maximumCharactersPerSegment
            )
            XCTAssertTrue(
                sentence.contains(segment),
                "切分不得丢字或改写：\(segment)"
            )
        }
        XCTAssertEqual(
            segments.joined(),
            sentence,
            "所有段落拼回去必须等于原文"
        )
    }

    /// 没有标点的超长文本也要能切：按字数硬切，不产生空白段或空段。
    func testUnpunctuatedLongTextSplitsWithoutEmptySegments() {
        let segments = DubbingSegmentPlanner.segments(
            from: String(repeating: "字", count: 500)
        )

        XCTAssertEqual(segments.joined(), String(repeating: "字", count: 500))
        XCTAssertFalse(segments.contains { $0.isEmpty })
        XCTAssertEqual(segments.count, 3)
    }
}
