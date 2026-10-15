import Foundation
import AVFoundation
import AudioToolbox
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
            let rel = "exports/\(manifest.requestID.uuidString.lowercased())/stage/book.m4b"
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
                let rel = "exports/\(manifest.requestID.uuidString.lowercased())/stage/chapters/\(filename)"
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

    /// Used only with `fakeStageEncoder`; production's default verifier always inspects media.
    private static let fakeMediaVerifier: AudiobookExportController.MediaVerifierHandler = { url, expected in
        try makeFakeMediaVerification(url: url, expected: expected)
    }

    private static func makeFakeMediaVerification(
        url: URL,
        expected: AudiobookPreparedExport
    ) throws -> AudiobookMediaVerification {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw AudiobookExportError.verificationFailed("fake media is missing")
        }
        if isDir.boolValue {
            let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "mp3" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            let digests = try files.map { fileURL -> String in
                let data = try Data(contentsOf: fileURL)
                return "\(fileURL.lastPathComponent):\(AudiobookDigest.sha256Hex(data))"
            }
            return AudiobookMediaVerification(
                codec: "mp3",
                frameCount: expected.expectedFrameCount,
                durationSeconds: Double(expected.expectedFrameCount) / Double(expected.expectedSampleRate),
                chapterTitles: expected.exportedChapters.map(\.title),
                fileSHA256: AudiobookDigest.sha256Hex(Data(digests.joined(separator: "|").utf8))
            )
        }
        let data = try Data(contentsOf: url)
        return AudiobookMediaVerification(
            codec: "aac",
            frameCount: expected.expectedFrameCount,
            durationSeconds: Double(expected.expectedFrameCount) / Double(expected.expectedSampleRate),
            chapterTitles: expected.exportedChapters.map(\.title),
            fileSHA256: AudiobookDigest.sha256Hex(data)
        )
    }

    private actor AsyncGate {
        private var isOpen = false
        private var continuations: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuations.append($0) }
        }

        func open() {
            guard !isOpen else { return }
            isOpen = true
            let waiting = continuations
            continuations.removeAll()
            waiting.forEach { $0.resume() }
        }
    }

    private actor CommitVerificationGate {
        private let verifierEntered = AsyncGate()
        private let allowVerifierToFinish = AsyncGate()
        private var invocationCount = 0

        func beforeVerification() async {
            invocationCount += 1
            guard invocationCount == 2 else { return }
            await verifierEntered.open()
            await allowVerifierToFinish.wait()
        }

        func waitForCommitVerification() async {
            await verifierEntered.wait()
        }

        func release() async {
            await allowVerifierToFinish.open()
        }
    }

    private func makePlayableSingleChapterM4B(frameCount: AVAudioFrameCount) async throws -> URL {
        let sampleRate = 48_000.0
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: true
            )
        )
        let wavURL = tempRoot.appendingPathComponent("single-chapter-source.wav")
        do {
            let audioFile = try AVAudioFile(
                forWriting: wavURL,
                settings: format.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
            buffer.frameLength = frameCount
            let samples = try XCTUnwrap(buffer.int16ChannelData).pointee
            for index in 0..<Int(frameCount) {
                samples[index] = index.isMultiple(of: 2) ? 700 : -700
            }
            try audioFile.write(from: buffer)
        }

        let m4aURL = tempRoot.appendingPathComponent("single-chapter.m4a")
        do {
            let inputFile = try AVAudioFile(
                forReading: wavURL,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            let aacSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000
            ]
            let outputFile = try AVAudioFile(
                forWriting: m4aURL,
                settings: aacSettings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            let inputFormat = inputFile.processingFormat
            let outputFormat = outputFile.processingFormat
            guard inputFormat.commonFormat == outputFormat.commonFormat,
                  inputFormat.isInterleaved == outputFormat.isInterleaved,
                  inputFormat.sampleRate == outputFormat.sampleRate,
                  inputFormat.channelCount == outputFormat.channelCount else {
                throw NSError(
                    domain: "AudiobookExportTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "AAC fixture input/output processing formats differ"]
                )
            }
            let chunkCapacity: AVAudioFrameCount = 4_096
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: chunkCapacity))
            while inputFile.framePosition < inputFile.length {
                let remainingFrames = AVAudioFrameCount(inputFile.length - inputFile.framePosition)
                try inputFile.read(into: buffer, frameCount: min(chunkCapacity, remainingFrames))
                guard buffer.frameLength > 0 else { break }
                try outputFile.write(from: buffer)
            }
        }

        let m4bURL = tempRoot.appendingPathComponent("single-chapter.m4b")
        try FileManager.default.moveItem(at: m4aURL, to: m4bURL)
        return m4bURL
    }

    func testMediaVerifierRejectsNonPlayableM4BAndMP3Bundle() async throws {
        let bookID = UUID()
        let sourceID = UUID()
        let chapter = AudiobookChapter(
            bookID: bookID,
            sourceID: sourceID,
            ordinal: 0,
            title: "第一章",
            sourceRange: AudiobookSourceRange(lowerBound: 0, upperBound: 1)
        )
        let requestID = UUID()
        let productionRevisionID = UUID()
        let m4bURL = tempRoot.appendingPathComponent("not-a-book.m4b")
        try Data("NOT AN M4B".utf8).write(to: m4bURL)
        let m4bExpected = AudiobookPreparedExport(
            requestID: requestID,
            bookID: bookID,
            productionRevisionID: productionRevisionID,
            profile: .m4b,
            bookTitle: "测试书",
            author: nil,
            exportedChapters: [chapter],
            omittedChapters: [],
            stageURL: m4bURL,
            expectedFrameCount: 48_000,
            expectedSampleRate: 48_000,
            expectedChapterFrameCounts: [chapter.id: 48_000]
        )

        do {
            _ = try await AudiobookMediaVerifier.verify(url: m4bURL, expected: m4bExpected)
            XCTFail("非空但不可播放的 M4B 字节不得通过正式媒体校验")
        } catch let error as AudiobookExportError {
            guard case .verificationFailed = error else {
                return XCTFail("应返回 verificationFailed，实际为：\(error)")
            }
        }

        let mp3BundleURL = tempRoot.appendingPathComponent("not-an-mp3-bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: mp3BundleURL, withIntermediateDirectories: true)
        try Data("NOT AN MP3".utf8).write(
            to: mp3BundleURL.appendingPathComponent("chapter_0001.mp3")
        )
        let mp3Expected = AudiobookPreparedExport(
            requestID: UUID(),
            bookID: bookID,
            productionRevisionID: productionRevisionID,
            profile: .chapterMP3,
            bookTitle: "测试书",
            author: nil,
            exportedChapters: [chapter],
            omittedChapters: [],
            stageURL: mp3BundleURL,
            expectedFrameCount: 48_000,
            expectedSampleRate: 48_000,
            expectedChapterFrameCounts: [chapter.id: 48_000]
        )

        do {
            _ = try await AudiobookMediaVerifier.verify(url: mp3BundleURL, expected: mp3Expected)
            XCTFail("非空但不可播放的分章 MP3 不得通过正式媒体校验")
        } catch let error as AudiobookExportError {
            guard case .verificationFailed = error else {
                return XCTFail("应返回 verificationFailed，实际为：\(error)")
            }
        }
    }

    func testMediaVerifierAcceptsPlayableSingleChapterM4BAndRejectsDurationMismatch() async throws {
        let frameCount: AVAudioFrameCount = 48_000
        let mediaURL = try await makePlayableSingleChapterM4B(frameCount: frameCount)
        let bookID = UUID()
        let chapter = AudiobookChapter(
            bookID: bookID,
            sourceID: UUID(),
            ordinal: 0,
            title: "第一章",
            sourceRange: AudiobookSourceRange(lowerBound: 0, upperBound: 1)
        )
        let expected = AudiobookPreparedExport(
            requestID: UUID(),
            bookID: bookID,
            productionRevisionID: UUID(),
            profile: .m4b,
            bookTitle: "测试书",
            author: nil,
            exportedChapters: [chapter],
            omittedChapters: [],
            stageURL: mediaURL,
            expectedFrameCount: Int64(frameCount),
            expectedSampleRate: 48_000,
            expectedChapterFrameCounts: [chapter.id: Int64(frameCount)]
        )

        let verification = try await AudiobookMediaVerifier.verify(url: mediaURL, expected: expected)
        XCTAssertEqual(verification.codec, "aac")
        XCTAssertEqual(verification.frameCount, Int64(frameCount))
        XCTAssertEqual(verification.chapterTitles, [chapter.title])
        XCTAssertEqual(verification.durationSeconds, 1, accuracy: 0.1)

        let wrongDuration = AudiobookPreparedExport(
            requestID: expected.requestID,
            bookID: expected.bookID,
            productionRevisionID: expected.productionRevisionID,
            profile: expected.profile,
            bookTitle: expected.bookTitle,
            author: expected.author,
            exportedChapters: expected.exportedChapters,
            omittedChapters: expected.omittedChapters,
            stageURL: expected.stageURL,
            expectedFrameCount: 24_000,
            expectedSampleRate: expected.expectedSampleRate,
            expectedChapterFrameCounts: expected.expectedChapterFrameCounts
        )
        do {
            _ = try await AudiobookMediaVerifier.verify(url: mediaURL, expected: wrongDuration)
            XCTFail("单章 M4B 的实际时长偏离预期时必须拒绝")
        } catch let error as AudiobookExportError {
            guard case .verificationFailed = error else {
                return XCTFail("应返回 verificationFailed，实际为：\(error)")
            }
        }
    }

    func testCancellationDuringCommitVerificationDoesNotInstallDestination() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let castController = AudiobookCastController(store: store)
        let revisionController = AudiobookRevisionController(store: store)
        let verificationGate = CommitVerificationGate()
        let exportController = AudiobookExportController(
            store: store,
            castController: castController,
            revisionController: revisionController,
            customStageEncoder: Self.fakeStageEncoder,
            mediaVerifier: { url, expected in
                await verificationGate.beforeVerification()
                return try Self.makeFakeMediaVerification(url: url, expected: expected)
            }
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
        let destination = tempRoot.appendingPathComponent("cancelled-export.m4b")
        let commitTask = Task {
            try await exportController.commit(prepared, destination: destination)
        }

        await verificationGate.waitForCommitVerification()
        await exportController.cancel(requestID: prepared.requestID)
        await verificationGate.release()

        do {
            try await commitTask.value
            XCTFail("校验期间取消导出后不得继续安装目标文件")
        } catch let error as AudiobookExportError {
            XCTAssertEqual(error, .exportCancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testPrepareRejectsEncoderOutputChecksumMismatch() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let castController = AudiobookCastController(store: store)
        let revisionController = AudiobookRevisionController(store: store)
        let mismatchedChecksumEncoder: AudiobookExportController.StageEncoderHandler = { manifest, requestDir in
            let result = try await Self.fakeStageEncoder(manifest, requestDir)
            let incorrectSHA256s = Dictionary(
                uniqueKeysWithValues: result.outputSHA256s.keys.map { ($0, String(repeating: "0", count: 64)) }
            )
            return MediaExportResultSnapshot(
                requestID: result.requestID,
                profile: result.profile,
                relativeOutputs: result.relativeOutputs,
                totalFrameCount: result.totalFrameCount,
                sampleRate: result.sampleRate,
                chapterCount: result.chapterCount,
                outputSHA256s: incorrectSHA256s
            )
        }
        let exportController = AudiobookExportController(
            store: store,
            castController: castController,
            revisionController: revisionController,
            customStageEncoder: mismatchedChecksumEncoder,
            mediaVerifier: Self.fakeMediaVerifier
        )
        let fixture = try await makeTwoChapterExportFixture(
            store: store,
            revisionController: revisionController,
            completeSecondChapter: true
        )

        do {
            _ = try await exportController.prepare(
                bookID: fixture.bookID,
                chapterIDs: nil,
                profile: .m4b
            )
            XCTFail("舞台媒体 SHA-256 与导出结果清单不一致时必须拒绝")
        } catch let error as AudiobookExportError {
            guard case .verificationFailed = error else {
                return XCTFail("应返回 verificationFailed，实际为：\(error)")
            }
        }
    }

    func testCommitRejectsStageChangedAfterPrepareVerification() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let castController = AudiobookCastController(store: store)
        let revisionController = AudiobookRevisionController(store: store)
        let exportController = AudiobookExportController(
            store: store,
            castController: castController,
            revisionController: revisionController,
            customStageEncoder: Self.fakeStageEncoder,
            mediaVerifier: Self.fakeMediaVerifier
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
        let preparedSHA256 = try XCTUnwrap(prepared.verification?.fileSHA256)
        try Data("FAKE_M4B_CHANGED_AFTER_PREPARE".utf8).write(to: prepared.stageURL, options: .atomic)
        let destination = tempRoot.appendingPathComponent("changed-stage.m4b")

        do {
            try await exportController.commit(prepared, destination: destination)
            XCTFail("commit 必须拒绝与 prepare 校验摘要不同的 stage copy")
        } catch let error as AudiobookExportError {
            guard case .verificationFailed = error else {
                return XCTFail("应返回 verificationFailed，实际为：\(error)")
            }
        }
        XCTAssertNotEqual(AudiobookDigest.sha256Hex(try Data(contentsOf: prepared.stageURL)), preparedSHA256)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testFullExportRejectsMissingStaleOrUnknownChapter() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let castController = AudiobookCastController(store: store)
        let revisionController = AudiobookRevisionController(store: store)
        let exportController = AudiobookExportController(
            store: store,
            castController: castController,
            revisionController: revisionController,
            customStageEncoder: Self.fakeStageEncoder,
            mediaVerifier: Self.fakeMediaVerifier
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
            customStageEncoder: Self.fakeStageEncoder,
            mediaVerifier: Self.fakeMediaVerifier
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
            customStageEncoder: Self.fakeStageEncoder,
            mediaVerifier: Self.fakeMediaVerifier
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
