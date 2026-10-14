import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

final class AudiobookExportTests: XCTestCase {
    nonisolated(unsafe) private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiobookExportTests-\(UUID().uuidString)", isDirectory: true)
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

    private func makeTwoChapterExportFixture(
        store: AudiobookProjectStore,
        revisionController: AudiobookRevisionController,
        completeSecondChapter: Bool
    ) async throws -> (bookID: UUID, chapter1: AudiobookChapter, chapter2: AudiobookChapter, hero: AudiobookCharacter) {
        let text = """
        第一章 启航
        海风习习。
        “出发！”林远喊道。
        第二章 远洋
        巨浪拍打着甲板。
        “抓稳船舷！”
        """
        let url = tempRoot.appendingPathComponent("export_book.txt")
        try Data(text.utf8).write(to: url)
        let preview = try await AudiobookTXTImporter.prepare(fileURL: url, encoding: .utf8)
        let bookID = try await store.importBook(preview)
        let chapters = try await store.chapters(for: bookID).sorted { $0.ordinal < $1.ordinal }
        let ch1 = chapters[0]
        let ch2 = chapters[1]

        var characters = try await store.characters(for: bookID)
        let narrator = characters[0]
        let hero = AudiobookCharacter(bookID: bookID, displayName: "林远", isNarrator: false, isMajor: true, chapterIDs: [ch1.id, ch2.id])
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

        let source = try await store.sourceIndex(for: bookID)
        let bindings = try await store.voiceBindings(for: bookID)

        for (cIdx, ch) in [ch1, ch2].enumerated() {
            let atoms = try await store.atoms(for: bookID, chapterID: ch.id).filter { $0.kind != .formatting }
            let anns = atoms.enumerated().map { idx, atom in
                let isUnknown = (!completeSecondChapter && cIdx == 1 && idx == atoms.count - 1)
                return AudiobookAnnotation(
                    bookID: bookID,
                    chapterID: ch.id,
                    windowID: UUID(),
                    atomID: atom.id,
                    sourceRange: atom.sourceRange,
                    assignment: isUnknown
                        ? .unknown(reason: "未指明说话人", candidateRoleIDs: [hero.id])
                        : .assigned(roleID: idx == atoms.count - 1 ? hero.id : narrator.id)
                )
            }
            try await store.saveAnnotations(bookID: bookID, annotations: anns)

            if cIdx == 0 || completeSecondChapter {
                let allAtoms = try await store.atoms(for: bookID, chapterID: ch.id)
                let fragments = try AudiobookFragmentPlanner.plan(
                    chapter: ch,
                    annotations: anns,
                    bindings: bindings,
                    policy: .standard,
                    source: source,
                    atoms: allAtoms
                )
                try await store.saveFragments(bookID: bookID, chapterID: ch.id, fragments: fragments)
                for fragment in fragments {
                    let wav = makeWAV(frameCount: 4_800, sampleValue: 400)
                    let cid = UUID()
                    let candidate = AudiobookRenderCandidate(
                        id: cid,
                        bookID: bookID,
                        chapterID: ch.id,
                        fragmentID: fragment.id,
                        generation: 1,
                        relativeAssetPath: "books/\(bookID.uuidString)/audio/\(cid.uuidString).wav",
                        fileSHA256: AudiobookDigest.sha256Hex(wav),
                        pcmSHA256: try AudioDigest.sha256HexOfPCM(in: wav),
                        frameCount: 4_800,
                        dependencyDigest: fragment.dependencyDigest
                    )
                    try await store.commitCandidate(candidate, wav: wav)
                }
                _ = try await revisionController.promoteInitialChapterIfComplete(bookID: bookID, chapterID: ch.id)
            }
        }
        return (bookID, ch1, ch2, hero)
    }

    private static let fakeStageEncoder: AudiobookExportController.StageEncoderHandler = { manifest, exportReqDir in
        let stageDir = exportReqDir.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        let totalFrames = manifest.chapters.flatMap(\.fragments).reduce(Int64(0)) { $0 + $1.frameCount }

        if manifest.profile == "m4b" {
            let m4bURL = stageDir.appendingPathComponent("book.m4b", isDirectory: false)
            let data = Data("FAKE_M4B_\(manifest.requestID.uuidString)".utf8)
            try data.write(to: m4bURL, options: .atomic)
            let rel = "exports/\(manifest.requestID.uuidString)/stage/book.m4b"
            return MediaExportResultSnapshot(
                requestID: manifest.requestID,
                profile: manifest.profile,
                relativeOutputs: [rel],
                totalFrameCount: totalFrames,
                sampleRate: 48_000,
                chapterCount: manifest.chapters.count,
                outputSHA256s: [rel: AudiobookDigest.sha256Hex(data)]
            )
        } else {
            let chDir = stageDir.appendingPathComponent("chapters", isDirectory: true)
            try FileManager.default.createDirectory(at: chDir, withIntermediateDirectories: true)
            var rels: [String] = []
            var shas: [String: String] = [:]
            for ch in manifest.chapters {
                let filename = String(format: "chapter_%04d.mp3", ch.ordinal + 1)
                let mp3URL = chDir.appendingPathComponent(filename, isDirectory: false)
                let data = Data("FAKE_MP3_\(ch.title)".utf8)
                try data.write(to: mp3URL, options: .atomic)
                let rel = "exports/\(manifest.requestID.uuidString)/stage/chapters/\(filename)"
                rels.append(rel)
                shas[rel] = AudiobookDigest.sha256Hex(data)
            }
            return MediaExportResultSnapshot(
                requestID: manifest.requestID,
                profile: manifest.profile,
                relativeOutputs: rels,
                totalFrameCount: totalFrames,
                sampleRate: 48_000,
                chapterCount: manifest.chapters.count,
                outputSHA256s: shas
            )
        }
    }

    func testFullExportRejectsMissingStaleOrUnknownChapter() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let castController = AudiobookCastController(store: store)
        let revisionController = AudiobookRevisionController(store: store)
        let exportController = AudiobookExportController(
            store: store,
            castController: castController,
            revisionController: revisionController,
            customStageEncoder: Self.fakeStageEncoder
        )

        // 第二章包含 unknown 且未生成音频：整本 M4B 导出必须拒绝
        let fixture = try await makeTwoChapterExportFixture(
            store: store,
            revisionController: revisionController,
            completeSecondChapter: false
        )

        do {
            _ = try await exportController.prepare(
                bookID: fixture.bookID,
                chapterIDs: nil,
                profile: .m4b
            )
            XCTFail("存在未完成或含 unknown 的章节时，整本 M4B 导出必须拒绝")
        } catch let error as AudiobookExportError {
            guard case let .fullBookExportBlocked(reasons) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(reasons.count, 1)
            XCTAssertEqual(reasons[0].chapterID, fixture.chapter2.id)
        }
    }

    func testPartialExportListsActualAndOmittedChapters() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let castController = AudiobookCastController(store: store)
        let revisionController = AudiobookRevisionController(store: store)
        let exportController = AudiobookExportController(
            store: store,
            castController: castController,
            revisionController: revisionController,
            customStageEncoder: Self.fakeStageEncoder
        )

        let fixture = try await makeTwoChapterExportFixture(
            store: store,
            revisionController: revisionController,
            completeSecondChapter: false
        )

        // 分章 MP3 导出：自动导出已就绪的第一章，并明确记录第二章的遗漏原因
        let prepared = try await exportController.prepare(
            bookID: fixture.bookID,
            chapterIDs: [fixture.chapter1.id, fixture.chapter2.id],
            profile: .chapterMP3
        )
        XCTAssertEqual(prepared.exportedChapters.map(\.id), [fixture.chapter1.id])
        XCTAssertEqual(prepared.omittedChapters.count, 1)
        XCTAssertEqual(prepared.omittedChapters[0].chapterID, fixture.chapter2.id)
        XCTAssertTrue(prepared.omittedChapters[0].reason.contains("说话人"))

        let bundleDest = tempRoot.appendingPathComponent("ExportedMP3Bundle", isDirectory: true)
        try await exportController.commit(prepared, destination: bundleDest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleDest.appendingPathComponent("chapter_0001.mp3").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleDest.appendingPathComponent("chapters-manifest.json").path))
    }

    func testTargetChangedAfterConsentPreservesExistingFileAndCancellationNeverCommitsStage() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let castController = AudiobookCastController(store: store)
        let revisionController = AudiobookRevisionController(store: store)
        let exportController = AudiobookExportController(
            store: store,
            castController: castController,
            revisionController: revisionController,
            customStageEncoder: Self.fakeStageEncoder
        )

        let fixture = try await makeTwoChapterExportFixture(
            store: store,
            revisionController: revisionController,
            completeSecondChapter: true
        )

        let prepared = try await exportController.prepare(
            bookID: fixture.bookID,
            chapterIDs: nil,
            profile: .m4b
        )

        let targetURL = tempRoot.appendingPathComponent("ExistingBook.m4b", isDirectory: false)
        let originalContent = Data("ORIGINAL_USER_FILE".utf8)
        try originalContent.write(to: targetURL)
        let consent = try AudiobookOverwriteConsent.capture(at: targetURL)

        // 用户确认覆盖后，外部程序修改了目标文件 -> commit 必须拒绝并完整保留修改后的外部文件
        let externallyModified = Data("MODIFIED_BY_ANOTHER_APP_AFTER_CONSENT".utf8)
        try externallyModified.write(to: targetURL)

        do {
            try await exportController.commit(
                prepared,
                destination: targetURL,
                overwriteConsent: consent
            )
            XCTFail("目标文件在同意后被外部修改时，不得覆盖该文件")
        } catch let error as AudiobookExportError {
            XCTAssertEqual(error, .destinationModifiedAfterConsent(targetURL.standardizedFileURL))
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), externallyModified)

        // 取消导出请求后调用 commit，绝不提交舞台文件
        let cancelDest = tempRoot.appendingPathComponent("CancelledBook.m4b", isDirectory: false)
        await exportController.cancel(requestID: prepared.requestID)
        do {
            try await exportController.commit(prepared, destination: cancelDest)
            XCTFail("已取消的导出请求不应提交到目标位置")
        } catch let error as AudiobookExportError {
            XCTAssertEqual(error, .exportCancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelDest.path))
    }
}
