import Foundation
import XCTest
import SpeechRailControlKit
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

@MainActor
final class AudiobookListeningTests: XCTestCase {
    nonisolated(unsafe) private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiobookListeningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    @MainActor
    private final class FakeFilePlaybackDriver: SharedAudioPlaybackDriver {
        var isPlaying = false
        var playedFileURLs: [URL] = []
        var playedDataBlobs: [Data] = []
        var startOffsets: [TimeInterval] = []
        var rates: [Float] = []
        var seekTimes: [TimeInterval] = []
        var onPlaybackFinished: (@MainActor (Bool) -> Void)?
        var onProgress: (@MainActor (Double) -> Void)?
        var onLevel: (@MainActor (Float) -> Void)?

        func play(data: Data) throws {
            playedDataBlobs.append(data)
            isPlaying = true
        }

        func play(fileURL: URL, startAt: TimeInterval, rate: Float) throws {
            playedFileURLs.append(fileURL)
            startOffsets.append(startAt)
            rates.append(rate)
            isPlaying = true
        }

        func pause() {
            isPlaying = false
        }

        func resume() throws {
            isPlaying = true
        }

        func seek(to time: TimeInterval) {
            seekTimes.append(time)
        }

        func setRate(_ rate: Float) {
            rates.append(rate)
        }

        func stop() {
            isPlaying = false
        }

        func duration(for data: Data) -> TimeInterval? { 10.0 }
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

    private func createListenableBook(
        store: AudiobookProjectStore,
        revisionController: AudiobookRevisionController
    ) async throws -> (
        bookID: UUID,
        chapter: AudiobookChapter,
        fragments: [AudiobookFragment],
        revision: AudiobookChapterRevision,
        hero: AudiobookCharacter
    ) {
        let text = "第一章 听书测试\n第一段十秒旁白。\n“第二段十秒对白。”\n"
        let url = tempRoot.appendingPathComponent("listen.txt")
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

        // 每个片段 480,000 frames @ 48kHz = 10.0 秒
        let tenSecWAV = makeWAV(frameCount: 4_800, sampleValue: 512)
        for (idx, fragment) in fragments.enumerated() {
            let cid = UUID()
            let candidate = AudiobookRenderCandidate(
                id: cid,
                bookID: bookID,
                chapterID: chapter.id,
                fragmentID: fragment.id,
                generation: 1,
                relativeAssetPath: "books/\(bookID.uuidString)/audio/\(cid.uuidString).wav",
                fileSHA256: AudiobookDigest.sha256Hex(tenSecWAV),
                pcmSHA256: try AudioDigest.sha256HexOfPCM(in: tenSecWAV),
                frameCount: Int64(480_000 + idx * 0),
                sampleRate: 48_000,
                dependencyDigest: fragment.dependencyDigest
            )
            try await store.commitCandidate(candidate, wav: tenSecWAV)
        }
        let maybeRev = try await revisionController.promoteInitialChapterIfComplete(bookID: bookID, chapterID: chapter.id)
        let rev = try XCTUnwrap(maybeRev)
        return (bookID, chapter, fragments, rev, hero)
    }

    func testFilePlaybackUsesSingleOwnerAndPreviewKeepsBookmark() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let revisionController = AudiobookRevisionController(store: store)
        let driver = FakeFilePlaybackDriver()
        let owner = SharedPlaybackOwner(driver: driver)
        let listening = AudiobookListeningController(
            store: store,
            revisionController: revisionController,
            playbackOwner: owner
        )

        let fixture = try await createListenableBook(store: store, revisionController: revisionController)
        try await listening.play(bookID: fixture.bookID, chapterID: fixture.chapter.id)

        XCTAssertTrue(driver.playedDataBlobs.isEmpty, "有声书播放必须使用文件 URL 驱动，不载入整书 Data")
        XCTAssertEqual(driver.playedFileURLs.count, 1)
        XCTAssertNotNil(listening.activePlayback?.nextPreloadedFileURL, "仅预载下一片段文件 URL")

        // 模拟收听到第 4 秒，此时用户点击角色试听（抢占唯一 SharedPlaybackOwner）
        try await listening.skip(seconds: 4.0)
        await listening.prepareForExternalPreview()
        try owner.play(data: Data("preview".utf8), target: .voice("v-hero"))

        XCTAssertTrue(listening.canResumeInterruptedListening)
        let savedBookmark = try await store.bookmark(for: fixture.bookID)
        XCTAssertEqual(try XCTUnwrap(savedBookmark?.fragmentOffsetSeconds), 4.0, accuracy: 0.01)

        // 试听结束后点击“继续听”，从书签的 4.0 秒位置恢复
        try await listening.resume()
        XCTAssertEqual(driver.startOffsets.last ?? 0, 4.0, accuracy: 0.01)
    }

    func testSkipFifteenSecondsAcrossFragmentsAndRateNeverChangesRenderSpeed() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let revisionController = AudiobookRevisionController(store: store)
        let driver = FakeFilePlaybackDriver()
        let owner = SharedPlaybackOwner(driver: driver)
        let listening = AudiobookListeningController(
            store: store,
            revisionController: revisionController,
            playbackOwner: owner
        )

        let fixture = try await createListenableBook(store: store, revisionController: revisionController)
        try await listening.play(bookID: fixture.bookID, chapterID: fixture.chapter.id)

        // 第一片段长 10 秒，快进 15 秒应跳到第二片段的第 5 秒
        try await listening.skip(seconds: 15.0)
        XCTAssertEqual(listening.activePlayback?.fragmentIndex, 1)
        XCTAssertEqual(listening.currentFragmentElapsedSeconds, 5.0, accuracy: 0.01)
        XCTAssertEqual(listening.chapterElapsedSeconds, 15.0, accuracy: 0.01)

        // 调整收听倍速为 1.5x 只改变播放器 rate，不改变 AudiobookRenderPolicy.standard.defaultSpeed
        await listening.setRate(1.5)
        XCTAssertEqual(listening.playbackRate, 1.5, accuracy: 0.001)
        XCTAssertEqual(driver.rates.last ?? 0, 1.5, accuracy: 0.001)
        XCTAssertEqual(AudiobookRenderPolicy.standard.defaultSpeed, 1.0)
    }

    func testRepairedChapterResumesAtSourceFragmentStartAndLeavingReleasesPlayer() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let revisionController = AudiobookRevisionController(store: store)
        let driver = FakeFilePlaybackDriver()
        let owner = SharedPlaybackOwner(driver: driver)
        let listening = AudiobookListeningController(
            store: store,
            revisionController: revisionController,
            playbackOwner: owner
        )

        let fixture = try await createListenableBook(store: store, revisionController: revisionController)
        try await listening.play(bookID: fixture.bookID, chapterID: fixture.chapter.id)
        // 快进到第 2 片段的第 3 秒（总第 13 秒）并暂停保存书签
        try await listening.skip(seconds: 13.0)
        await listening.pause()

        // 返修并采用第 2 片段的新候选，产生新的 chapterRevisionID
        let frag2 = fixture.fragments[1]
        let newWAV = makeWAV(frameCount: 4_800, sampleValue: 777)
        let newCID = UUID()
        let newCandidate = AudiobookRenderCandidate(
            id: newCID,
            bookID: fixture.bookID,
            chapterID: fixture.chapter.id,
            fragmentID: frag2.id,
            generation: 2,
            relativeAssetPath: "books/\(fixture.bookID.uuidString)/audio/\(newCID.uuidString).wav",
            fileSHA256: AudiobookDigest.sha256Hex(newWAV),
            pcmSHA256: try AudioDigest.sha256HexOfPCM(in: newWAV),
            frameCount: 480_000,
            sampleRate: 48_000,
            dependencyDigest: frag2.dependencyDigest
        )
        try await store.commitCandidate(newCandidate, wav: newWAV)
        try await revisionController.adopt(
            bookID: fixture.bookID,
            candidateID: newCID,
            expectedRevisionID: fixture.revision.id
        )

        // 重新播放该章：按来源锚点定位到第 2 片段开头（0.0s），并提示“章节已更新”
        try await listening.play(bookID: fixture.bookID, chapterID: fixture.chapter.id)
        XCTAssertEqual(listening.activePlayback?.fragmentIndex, 1)
        XCTAssertEqual(listening.currentFragmentElapsedSeconds, 0.0, accuracy: 0.01)
        XCTAssertNotNil(listening.chapterUpdatedBannerMessage)

        // 离开有声书工坊：保存书签、释放播放器，且迟到的完成回调被忽略
        await listening.leaveWorkshop()
        XCTAssertFalse(listening.isPlaying)
        XCTAssertNil(listening.activePlayback)
        driver.onPlaybackFinished?(true)
        XCTAssertFalse(listening.isPlaying)
    }
}
