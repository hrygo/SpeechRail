import Foundation
import XCTest
import SpeechRailControlKit
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

final class AudiobookRevisionTests: XCTestCase {
    nonisolated(unsafe) private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiobookRevisionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    private func makeWAV(frameCount: Int, sampleValue: Int16) -> Data {
        let pcmByteCount = frameCount * 2
        var data = Data(capacity: 44 + pcmByteCount)
        data.append(contentsOf: "RIFF".utf8)
        var riffSize = UInt32(36 + pcmByteCount).littleEndian
        data.append(Data(bytes: &riffSize, count: 4))
        data.append(contentsOf: "WAVEfmt ".utf8)
        var fmtChunkSize = UInt32(16).littleEndian
        var audioFormat = UInt16(1).littleEndian
        var numChannels = UInt16(1).littleEndian
        var sampleRate = UInt32(48_000).littleEndian
        var byteRate = UInt32(48_000 * 2).littleEndian
        var blockAlign = UInt16(2).littleEndian
        var bitsPerSample = UInt16(16).littleEndian
        data.append(Data(bytes: &fmtChunkSize, count: 4))
        data.append(Data(bytes: &audioFormat, count: 2))
        data.append(Data(bytes: &numChannels, count: 2))
        data.append(Data(bytes: &sampleRate, count: 4))
        data.append(Data(bytes: &byteRate, count: 4))
        data.append(Data(bytes: &blockAlign, count: 2))
        data.append(Data(bytes: &bitsPerSample, count: 2))
        data.append(contentsOf: "data".utf8)
        var dataChunkSize = UInt32(pcmByteCount).littleEndian
        data.append(Data(bytes: &dataChunkSize, count: 4))
        var sample = sampleValue.littleEndian
        let sampleBytes = Data(bytes: &sample, count: 2)
        for _ in 0..<frameCount {
            data.append(sampleBytes)
        }
        return data
    }

    private func setupSingleChapterWithTwoFragments(
        store: AudiobookProjectStore
    ) async throws -> (
        bookID: UUID,
        chapter: AudiobookChapter,
        fragments: [AudiobookFragment],
        narrator: AudiobookCharacter,
        hero: AudiobookCharacter
    ) {
        let text = "第一章 渡口\n风声紧迫。\n“快上船！”林远喊道。\n"
        let url = tempRoot.appendingPathComponent("rev.txt")
        try Data(text.utf8).write(to: url)
        let preview = try await AudiobookTXTImporter.prepare(fileURL: url, encoding: .utf8)
        let bookID = try await store.importBook(preview)
        let chapter = try await store.chapters(for: bookID)[0]

        var characters = try await store.characters(for: bookID)
        let narrator = characters[0]
        let hero = AudiobookCharacter(bookID: bookID, displayName: "林远", isNarrator: false, isMajor: true, chapterIDs: [chapter.id])
        characters.append(hero)
        try await store.saveCharacters(bookID: bookID, characters: characters)

        try await store.saveVoiceBinding(
            bookID: bookID,
            binding: AudiobookVoiceBinding(roleID: narrator.id, voiceID: "v-narr", voiceRevision: "1", modelRevision: "m1")
        )
        try await store.saveVoiceBinding(
            bookID: bookID,
            binding: AudiobookVoiceBinding(roleID: hero.id, voiceID: "v-hero", voiceRevision: "1", modelRevision: "m1")
        )

        let atoms = try await store.atoms(for: bookID, chapterID: chapter.id).filter { $0.kind != .formatting }
        let anns = atoms.enumerated().map { idx, atom in
            AudiobookAnnotation(
                bookID: bookID,
                chapterID: chapter.id,
                windowID: UUID(),
                atomID: atom.id,
                sourceRange: atom.sourceRange,
                assignment: .assigned(roleID: idx == atoms.count - 1 ? hero.id : narrator.id)
            )
        }
        try await store.saveAnnotations(bookID: bookID, annotations: anns)

        let bindings = try await store.voiceBindings(for: bookID)
        let source = try await store.sourceIndex(for: bookID)
        let allAtoms = try await store.atoms(for: bookID, chapterID: chapter.id)
        let fragments = try AudiobookFragmentPlanner.plan(
            chapter: chapter,
            annotations: anns,
            bindings: bindings,
            policy: .standard,
            source: source,
            atoms: allAtoms
        )
        try await store.saveFragments(bookID: bookID, chapterID: chapter.id, fragments: fragments)
        return (bookID, chapter, fragments, narrator, hero)
    }

    func testRepeatedAdoptionAndCrashCannotDuplicateCurrentVersion() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let controller = AudiobookRevisionController(store: store)
        let fixture = try await setupSingleChapterWithTwoFragments(store: store)

        for (idx, fragment) in fixture.fragments.enumerated() {
            let wav = makeWAV(frameCount: 2_400 + idx * 100, sampleValue: Int16(500 + idx))
            let candidateID = UUID()
            let candidate = AudiobookRenderCandidate(
                id: candidateID,
                bookID: fixture.bookID,
                chapterID: fixture.chapter.id,
                fragmentID: fragment.id,
                generation: 1,
                relativeAssetPath: "books/\(fixture.bookID.uuidString)/audio/\(candidateID.uuidString).wav",
                fileSHA256: AudiobookDigest.sha256Hex(wav),
                pcmSHA256: try AudioDigest.sha256HexOfPCM(in: wav),
                frameCount: Int64(2_400 + idx * 100),
                dependencyDigest: fragment.dependencyDigest
            )
            try await store.commitCandidate(candidate, wav: wav)
        }

        let initialRev = try await XCTUnwrapAsync(
            await controller.promoteInitialChapterIfComplete(bookID: fixture.bookID, chapterID: fixture.chapter.id)
        )
        let firstCandidateID = initialRev.orderedBindings[0].candidateID

        // 对已经采用的同一 candidate 重复调用 adopt，幂等不新增重复章节版本
        try await controller.adopt(
            bookID: fixture.bookID,
            candidateID: firstCandidateID,
            expectedRevisionID: initialRev.id
        )
        let revisions = try await store.chapterRevisions(for: fixture.bookID, chapterID: fixture.chapter.id)
        XCTAssertEqual(revisions.count, 1)
    }

    func testRepairNeedsExplicitAdoptionAndUndoRestoresHistory() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let controller = AudiobookRevisionController(store: store)
        let fixture = try await setupSingleChapterWithTwoFragments(store: store)

        for (idx, fragment) in fixture.fragments.enumerated() {
            let wav = makeWAV(frameCount: 2_400, sampleValue: Int16(300 + idx))
            let cid = UUID()
            let candidate = AudiobookRenderCandidate(
                id: cid,
                bookID: fixture.bookID,
                chapterID: fixture.chapter.id,
                fragmentID: fragment.id,
                generation: 1,
                relativeAssetPath: "books/\(fixture.bookID.uuidString)/audio/\(cid.uuidString).wav",
                fileSHA256: AudiobookDigest.sha256Hex(wav),
                pcmSHA256: try AudioDigest.sha256HexOfPCM(in: wav),
                frameCount: 2_400,
                dependencyDigest: fragment.dependencyDigest
            )
            try await store.commitCandidate(candidate, wav: wav)
        }
        let rev1 = try await XCTUnwrapAsync(
            await controller.promoteInitialChapterIfComplete(bookID: fixture.bookID, chapterID: fixture.chapter.id)
        )

        // 生成第 2 个片段的返修新候选：在用户显式调用 adopt 前，当前版本仍保持 rev1
        let targetFrag = fixture.fragments[1]
        let repairWAV = makeWAV(frameCount: 3_600, sampleValue: 900)
        let repairCandidateID = UUID()
        let repairCandidate = AudiobookRenderCandidate(
            id: repairCandidateID,
            bookID: fixture.bookID,
            chapterID: fixture.chapter.id,
            fragmentID: targetFrag.id,
            generation: 2,
            relativeAssetPath: "books/\(fixture.bookID.uuidString)/audio/\(repairCandidateID.uuidString).wav",
            fileSHA256: AudiobookDigest.sha256Hex(repairWAV),
            pcmSHA256: try AudioDigest.sha256HexOfPCM(in: repairWAV),
            frameCount: 3_600,
            dependencyDigest: targetFrag.dependencyDigest
        )
        try await store.commitCandidate(repairCandidate, wav: repairWAV)

        let beforeAdopt = try await controller.currentChapter(bookID: fixture.bookID, chapterID: fixture.chapter.id)
        XCTAssertEqual(beforeAdopt?.id, rev1.id)

        // 用户试听后显式采用新候选
        try await controller.adopt(
            bookID: fixture.bookID,
            candidateID: repairCandidateID,
            expectedRevisionID: rev1.id
        )
        let afterAdopt = try await XCTUnwrapAsync(
            await controller.currentChapter(bookID: fixture.bookID, chapterID: fixture.chapter.id)
        )
        XCTAssertNotEqual(afterAdopt.id, rev1.id)
        XCTAssertEqual(afterAdopt.orderedBindings[1].candidateID, repairCandidateID)

        // 一键撤销后恢复为 rev1
        try await controller.undoAdoption(bookID: fixture.bookID, chapterID: fixture.chapter.id)
        let afterUndo = try await XCTUnwrapAsync(
            await controller.currentChapter(bookID: fixture.bookID, chapterID: fixture.chapter.id)
        )
        XCTAssertEqual(afterUndo.id, rev1.id)
    }

    func testRestartReusesValidFragmentsAndRetriesInterruptedOne() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let controller = AudiobookRevisionController(store: store)
        let fixture = try await setupSingleChapterWithTwoFragments(store: store)

        // 仅提交第 1 个片段，模拟第 2 个片段在重启前中断
        let firstFrag = fixture.fragments[0]
        let wav = makeWAV(frameCount: 2_400, sampleValue: 400)
        let cid = UUID()
        let candidate = AudiobookRenderCandidate(
            id: cid,
            bookID: fixture.bookID,
            chapterID: fixture.chapter.id,
            fragmentID: firstFrag.id,
            generation: 1,
            relativeAssetPath: "books/\(fixture.bookID.uuidString)/audio/\(cid.uuidString).wav",
            fileSHA256: AudiobookDigest.sha256Hex(wav),
            pcmSHA256: try AudioDigest.sha256HexOfPCM(in: wav),
            frameCount: 2_400,
            dependencyDigest: firstFrag.dependencyDigest
        )
        try await store.commitCandidate(candidate, wav: wav)

        let plan = try await controller.resumePlan(bookID: fixture.bookID)
        XCTAssertEqual(plan.reusableFragmentIDs, [fixture.fragments[0].id])
        XCTAssertEqual(plan.redoFragmentIDs, [fixture.fragments[1].id])
        XCTAssertEqual(plan.incompleteChapterIDs, [fixture.chapter.id])
    }

    func testStaleCandidateCannotCompleteOrExportCurrentBook() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let controller = AudiobookRevisionController(store: store)
        let fixture = try await setupSingleChapterWithTwoFragments(store: store)

        for (idx, fragment) in fixture.fragments.enumerated() {
            let wav = makeWAV(frameCount: 2_400, sampleValue: Int16(200 + idx))
            let cid = UUID()
            let candidate = AudiobookRenderCandidate(
                id: cid,
                bookID: fixture.bookID,
                chapterID: fixture.chapter.id,
                fragmentID: fragment.id,
                generation: 1,
                relativeAssetPath: "books/\(fixture.bookID.uuidString)/audio/\(cid.uuidString).wav",
                fileSHA256: AudiobookDigest.sha256Hex(wav),
                pcmSHA256: try AudioDigest.sha256HexOfPCM(in: wav),
                frameCount: 2_400,
                dependencyDigest: fragment.dependencyDigest
            )
            try await store.commitCandidate(candidate, wav: wav)
        }
        let rev1 = try await XCTUnwrapAsync(
            await controller.promoteInitialChapterIfComplete(bookID: fixture.bookID, chapterID: fixture.chapter.id)
        )

        // 更换主角音色版本后，旧章节版本不能冒充当前最新完整版本，但可作为“之前的版本”保留收听
        try await store.saveVoiceBinding(
            bookID: fixture.bookID,
            binding: AudiobookVoiceBinding(
                roleID: fixture.hero.id,
                voiceID: "v-hero-v2",
                voiceRevision: "2",
                modelRevision: "m1"
            )
        )

        let currentAfterVoiceChange = try await controller.currentChapter(
            bookID: fixture.bookID,
            chapterID: fixture.chapter.id
        )
        XCTAssertNil(currentAfterVoiceChange, "音色改变后旧版不得继续冒充当前有效章节版本")

        let previousRev = try await controller.previousListenableChapter(
            bookID: fixture.bookID,
            chapterID: fixture.chapter.id
        )
        XCTAssertEqual(previousRev?.id, rev1.id, "历史完整版本仍可作为『之前的版本』收听")
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }
}
