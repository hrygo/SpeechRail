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

    func testHistoricalExportUsesSelectedRevisionAfterWorkingPreparation() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let revisions = AudiobookRevisionController(store: store)
        let fixture = try await makeTwoChapterExportFixture(store: store, revisionController: revisions, completeSecondChapter: true)
        let before = try await store.book(id: fixture.bookID)
        let productionID = try XCTUnwrap(before.currentProductionRevisionID)
        _ = try await store.prepareWorkingRevision(bookID: fixture.bookID, expectedSourceID: before.sourceID)
        let cast = AudiobookCastController(store: store, capabilityProvider: { throw ServiceAPIClientError.invalidResponse })
        let export = AudiobookExportController(store: store, castController: cast, revisionController: revisions)
        let audit = try await export.audit(bookID: fixture.bookID, chapterIDs: nil, profile: .m4b, productionRevisionID: productionID)
        XCTAssertEqual(audit.readyChapterIDs, [fixture.chapter1.id, fixture.chapter2.id])
        XCTAssertTrue(audit.blockers.isEmpty)
        let current = try await store.book(id: fixture.bookID)
        XCTAssertNotEqual(current.sourceID, before.sourceID)
        XCTAssertEqual(current.currentProductionRevisionID, productionID)
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

    private actor PrepareVerificationGate {
        let entered = AsyncGate()
        let released = AsyncGate()
        private(set) var requestID: UUID?
        private(set) var stageURL: URL?

        func waitInVerification(url: URL, requestID: UUID) async {
            self.requestID = requestID
            stageURL = url.deletingLastPathComponent()
            await entered.open()
            await released.wait()
        }
    }

    private func makePlayableAACFile(frameCount: AVAudioFrameCount, name: String) throws -> URL {
        let sampleRate = 48_000.0
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: true
            )
        )
        let wavURL = tempRoot.appendingPathComponent("\(name)-source.wav")
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

        let m4aURL = tempRoot.appendingPathComponent("\(name).m4a")
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

        return m4aURL
    }

    private func makePlayableM4BWithoutChapterMetadata(frameCount: AVAudioFrameCount) throws -> URL {
        let m4aURL = try makePlayableAACFile(frameCount: frameCount, name: "unmarked")
        let m4bURL = tempRoot.appendingPathComponent("unmarked.m4b")
        try FileManager.default.moveItem(at: m4aURL, to: m4bURL)
        return m4bURL
    }

    private func makePlayableM4BWithChapters(
        _ chapters: [(title: String, frameCount: Int64)]
    ) async throws -> URL {
        let sampleRate: Int32 = 48_000
        var totalFrameCount: Int64 = 0
        for chapter in chapters {
            guard chapter.frameCount > 0 else {
                throw NSError(domain: "AudiobookExportTests", code: 3)
            }
            let (updatedTotal, overflow) = totalFrameCount.addingReportingOverflow(chapter.frameCount)
            guard !overflow else {
                throw NSError(domain: "AudiobookExportTests", code: 2)
            }
            totalFrameCount = updatedTotal
        }
        guard totalFrameCount > 0, totalFrameCount <= Int64(AVAudioFrameCount.max) else {
            throw NSError(domain: "AudiobookExportTests", code: 2)
        }
        let sourceURL = try makePlayableAACFile(
            frameCount: AVAudioFrameCount(totalFrameCount),
            name: "chaptered-source"
        )
        guard let searchPath = ProcessInfo.processInfo.environment["PATH"] else {
            throw XCTSkip("PATH 未配置，跳过依赖 ffmpeg 的合成章节夹具。")
        }
        let ffmpegURL = searchPath
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { component in
                URL(fileURLWithPath: component.isEmpty ? "." : String(component))
                    .appendingPathComponent("ffmpeg", isDirectory: false)
            }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard let ffmpegURL else {
            throw XCTSkip("PATH 中未找到可执行的 ffmpeg；未下载工具，跳过合成章节夹具。")
        }

        func escapeFFMetadataValue(_ value: String) -> String {
            let normalized = value
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            var escaped = normalized.replacingOccurrences(of: "\\", with: "\\\\")
            for character in ["=", ";", "#"] {
                escaped = escaped.replacingOccurrences(of: character, with: "\\" + character)
            }
            return escaped.replacingOccurrences(of: "\n", with: "\\\n")
        }

        var metadataLines = [";FFMETADATA1"]
        var cursorFrame: Int64 = 0
        for chapter in chapters {
            let (endFrame, overflow) = cursorFrame.addingReportingOverflow(chapter.frameCount)
            guard !overflow else {
                throw NSError(domain: "AudiobookExportTests", code: 2)
            }
            metadataLines.append(contentsOf: [
                "[CHAPTER]",
                "TIMEBASE=1/\(sampleRate)",
                "START=\(cursorFrame)",
                "END=\(endFrame)",
                "title=\(escapeFFMetadataValue(chapter.title))"
            ])
            cursorFrame = endFrame
        }

        let metadataURL = tempRoot.appendingPathComponent("chaptered-source.ffmetadata")
        try Data((metadataLines.joined(separator: "\n") + "\n").utf8).write(to: metadataURL, options: .atomic)
        let m4bURL = tempRoot.appendingPathComponent("chaptered-output.m4b")
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
            "-i", sourceURL.path,
            "-f", "ffmetadata", "-i", metadataURL.path,
            "-map", "0:a:0", "-map_chapters", "1",
            "-c:a", "copy",
            "-movflags", "+faststart+disable_chpl",
            m4bURL.path
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "AudiobookExportTests",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "ffmpeg 无法生成合成章节 M4B（退出码 \(process.terminationStatus)）。"]
            )
        }
        return m4bURL
    }

    private func makeTestChapters(bookID: UUID, titles: [String]) -> [AudiobookChapter] {
        let sourceID = UUID()
        return titles.enumerated().map { index, title in
            AudiobookChapter(
                bookID: bookID,
                sourceID: sourceID,
                ordinal: index,
                title: title,
                sourceRange: AudiobookSourceRange(lowerBound: Int64(index), upperBound: Int64(index + 1))
            )
        }
    }

    private func makeExpectedM4B(
        mediaURL: URL,
        chapters: [AudiobookChapter],
        chapterFrameCounts: [Int64],
        expectedFrameCount: Int64? = nil
    ) -> AudiobookPreparedExport {
        var expectedChapterFrameCounts: [UUID: Int64] = [:]
        for (chapter, frameCount) in zip(chapters, chapterFrameCounts) {
            expectedChapterFrameCounts[chapter.id] = frameCount
        }
        let totalFrames = chapterFrameCounts.reduce(Int64(0), +)
        return AudiobookPreparedExport(
            requestID: UUID(),
            bookID: chapters[0].bookID,
            productionRevisionID: UUID(),
            profile: .m4b,
            bookTitle: "测试书",
            author: nil,
            exportedChapters: chapters,
            omittedChapters: [],
            stageURL: mediaURL,
            expectedFrameCount: expectedFrameCount ?? totalFrames,
            expectedSampleRate: 48_000,
            expectedChapterFrameCounts: expectedChapterFrameCounts
        )
    }

    private func assertMediaVerificationFails(
        url: URL,
        expected: AudiobookPreparedExport,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await AudiobookMediaVerifier.verify(url: url, expected: expected)
            XCTFail("M4B 章节或时长与预期不符时必须拒绝", file: file, line: line)
        } catch let error as AudiobookExportError {
            guard case .verificationFailed = error else {
                XCTFail("应返回 verificationFailed，实际为：\(error)", file: file, line: line)
                return
            }
        } catch {
            XCTFail("应返回 AudiobookExportError，实际为：\(error)", file: file, line: line)
        }
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

    func testMediaVerifierRejectsPlayableM4BWithoutChapterMetadata() async throws {
        let mediaURL = try makePlayableM4BWithoutChapterMetadata(frameCount: 48_000)
        let bookID = UUID()
        let chapters = makeTestChapters(bookID: bookID, titles: ["第一章"])
        let expected = makeExpectedM4B(
            mediaURL: mediaURL,
            chapters: chapters,
            chapterFrameCounts: [48_000]
        )

        await assertMediaVerificationFails(url: mediaURL, expected: expected)
    }

    func testMediaVerifierReadsRealM4BChapterMarkersAndRejectsMismatches() async throws {
        let titles = ["第一章", "第二章"]
        let chapterFrames: [Int64] = [48_000, 48_000]
        let mediaURL = try await makePlayableM4BWithChapters(
            zip(titles, chapterFrames).map { (title: $0.0, frameCount: $0.1) }
        )
        let bookID = UUID()
        let chapters = makeTestChapters(bookID: bookID, titles: titles)
        let expected = makeExpectedM4B(
            mediaURL: mediaURL,
            chapters: chapters,
            chapterFrameCounts: chapterFrames
        )

        let verification = try await AudiobookMediaVerifier.verify(url: mediaURL, expected: expected)
        XCTAssertEqual(verification.codec, "aac")
        XCTAssertEqual(verification.frameCount, 96_000)
        XCTAssertEqual(verification.chapterTitles, titles)
        XCTAssertEqual(verification.durationSeconds, 2, accuracy: 0.1)

        var wrongTitles = chapters
        wrongTitles[0].title = "错误标题"
        await assertMediaVerificationFails(
            url: mediaURL,
            expected: makeExpectedM4B(
                mediaURL: mediaURL,
                chapters: wrongTitles,
                chapterFrameCounts: chapterFrames
            )
        )

        var wrongOrder = chapters
        wrongOrder[0].title = titles[1]
        wrongOrder[1].title = titles[0]
        await assertMediaVerificationFails(
            url: mediaURL,
            expected: makeExpectedM4B(
                mediaURL: mediaURL,
                chapters: wrongOrder,
                chapterFrameCounts: chapterFrames
            )
        )

        await assertMediaVerificationFails(
            url: mediaURL,
            expected: makeExpectedM4B(
                mediaURL: mediaURL,
                chapters: chapters,
                chapterFrameCounts: [36_000, 60_000]
            )
        )

        let mergedChapter = makeTestChapters(bookID: bookID, titles: ["合并章节"])
        await assertMediaVerificationFails(
            url: mediaURL,
            expected: makeExpectedM4B(
                mediaURL: mediaURL,
                chapters: mergedChapter,
                chapterFrameCounts: [96_000]
            )
        )

        await assertMediaVerificationFails(
            url: mediaURL,
            expected: makeExpectedM4B(
                mediaURL: mediaURL,
                chapters: chapters,
                chapterFrameCounts: chapterFrames,
                expectedFrameCount: 48_000
            )
        )
    }

    func testExportReadinessIgnoresSkippedChaptersAndBlocksMissingAudio() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let revisionController = AudiobookRevisionController(store: store)
        let fixture = try await makeTwoChapterExportFixture(
            store: store,
            revisionController: revisionController,
            completeSecondChapter: false
        )
        let chapters = try await store.chapters(for: fixture.bookID).sorted { $0.ordinal < $1.ordinal }
        var ready = chapters[0]
        ready.currentChapterRevisionID = UUID()
        let blocked = chapters[1]
        var skipped = chapters[1]
        skipped.isSkipped = true

        let partial = AudiobookExportReadiness(chapters: [ready, blocked])
        XCTAssertEqual(partial.readyChapterIDs, [ready.id])
        XCTAssertEqual(partial.blockingChapterIDs, [blocked.id])
        XCTAssertFalse(partial.isFullBookReady)

        let skippedPartial = AudiobookExportReadiness(chapters: [ready, skipped])
        XCTAssertEqual(skippedPartial.readyChapterIDs, [ready.id])
        XCTAssertTrue(skippedPartial.blockingChapterIDs.isEmpty)
        XCTAssertTrue(skippedPartial.isFullBookReady)

        let noAudio = AudiobookExportReadiness(chapters: [skipped])
        XCTAssertFalse(noAudio.isFullBookReady)
    }

    func testExportAuditMatchesReadyAndBlockedChaptersWithoutPreparing() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let revisionController = AudiobookRevisionController(store: store)
        let controller = AudiobookExportController(
            store: store,
            castController: AudiobookCastController(store: store),
            revisionController: revisionController,
            customStageEncoder: Self.fakeStageEncoder,
            mediaVerifier: { url, expected in
                try Self.makeFakeMediaVerification(url: url, expected: expected)
            }
        )
        let fixture = try await makeTwoChapterExportFixture(
            store: store,
            revisionController: revisionController,
            completeSecondChapter: false
        )

        let full = try await controller.audit(bookID: fixture.bookID, chapterIDs: nil, profile: .m4b)
        XCTAssertEqual(full.readyChapterIDs, [fixture.chapter1.id])
        XCTAssertEqual(full.blockers.map(\.reason), [.unknownSpeaker])
        XCTAssertEqual(full.blockers.map(\.chapterID), [fixture.chapter2.id])
        XCTAssertFalse(full.isFullBookReady)

        let selected = try await controller.audit(
            bookID: fixture.bookID,
            chapterIDs: [fixture.chapter1.id],
            profile: .chapterMP3
        )
        XCTAssertEqual(selected.readyChapterIDs, [fixture.chapter1.id])
        XCTAssertTrue(selected.blockers.isEmpty)
        XCTAssertTrue(selected.isFullBookReady)
    }

    func testExportAuditReportsMissingCandidateAsset() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let revisionController = AudiobookRevisionController(store: store)
        let controller = AudiobookExportController(
            store: store,
            castController: AudiobookCastController(store: store),
            revisionController: revisionController
        )
        let fixture = try await makeTwoChapterExportFixture(
            store: store,
            revisionController: revisionController,
            completeSecondChapter: true
        )
        let candidates = try await store.candidates(for: fixture.bookID)
            .filter { $0.chapterID == fixture.chapter2.id }
        let candidate = try XCTUnwrap(candidates.first)
        let storeRoot = await store.rootURL
        try FileManager.default.removeItem(at: storeRoot.appendingPathComponent(candidate.relativeAssetPath))

        let audit = try await controller.audit(bookID: fixture.bookID, chapterIDs: nil, profile: .m4b)
        XCTAssertEqual(audit.readyChapterIDs, [fixture.chapter1.id])
        XCTAssertEqual(audit.blockers.map(\.reason), [.missingAsset])
        XCTAssertEqual(audit.blockers.first?.chapterID, fixture.chapter2.id)
    }

    func testPreCancelledRequestRejectsBeforePreparing() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let revisionController = AudiobookRevisionController(store: store)
        let controller = AudiobookExportController(
            store: store,
            castController: AudiobookCastController(store: store),
            revisionController: revisionController,
            customStageEncoder: Self.fakeStageEncoder,
            mediaVerifier: { url, expected in
                try Self.makeFakeMediaVerification(url: url, expected: expected)
            }
        )
        let fixture = try await makeTwoChapterExportFixture(
            store: store,
            revisionController: revisionController,
            completeSecondChapter: true
        )
        let requestID = UUID()
        await controller.cancel(requestID: requestID)
        do {
            _ = try await controller.prepare(
                bookID: fixture.bookID,
                chapterIDs: nil,
                profile: .m4b,
                requestID: requestID
            )
            XCTFail("已取消的请求不应继续准备导出")
        } catch let error as AudiobookExportError {
            XCTAssertEqual(error, .exportCancelled)
        }
    }

    func testCancellationDuringPrepareVerificationRejectsPreparedAndCleansStage() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let castController = AudiobookCastController(store: store)
        let revisionController = AudiobookRevisionController(store: store)
        let fixture = try await makeTwoChapterExportFixture(
            store: store,
            revisionController: revisionController,
            completeSecondChapter: true
        )
        for cancelTask in [false, true] {
            let gate = PrepareVerificationGate()
            let controller = AudiobookExportController(
                store: store,
                castController: castController,
                revisionController: revisionController,
                customStageEncoder: Self.fakeStageEncoder,
                mediaVerifier: { url, expected in
                    let verification = try Self.makeFakeMediaVerification(url: url, expected: expected)
                    await gate.waitInVerification(url: url, requestID: expected.requestID)
                    return verification
                }
            )
            let task = Task {
                try await controller.prepare(bookID: fixture.bookID, chapterIDs: nil, profile: .m4b)
            }
            await gate.entered.wait()
            let requestID = await gate.requestID
            if cancelTask {
                task.cancel()
            } else if let requestID {
                await controller.cancel(requestID: requestID)
            } else {
                XCTFail("校验器必须收到导出请求编号")
            }
            await gate.released.open()
            do {
                _ = try await task.value
                XCTFail("媒体校验期间取消后不能返回已准备好的导出")
            } catch let error as AudiobookExportError {
                XCTAssertEqual(error, .exportCancelled)
            }
            let stageURL = await gate.stageURL
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(stageURL).path))
        }
    }

    func testPrepareMapsVerifierCancellationToExportCancelled() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let revisionController = AudiobookRevisionController(store: store)
        let controller = AudiobookExportController(
            store: store,
            castController: AudiobookCastController(store: store),
            revisionController: revisionController,
            customStageEncoder: Self.fakeStageEncoder,
            mediaVerifier: { _, _ in throw CancellationError() }
        )
        let fixture = try await makeTwoChapterExportFixture(
            store: store,
            revisionController: revisionController,
            completeSecondChapter: true
        )
        do {
            _ = try await controller.prepare(bookID: fixture.bookID, chapterIDs: nil, profile: .m4b)
            XCTFail("校验器取消必须停止准备导出")
        } catch let error as AudiobookExportError {
            XCTAssertEqual(error, .exportCancelled)
        } catch {
            XCTFail("应返回稳定的导出取消错误，实际：\(type(of: error))")
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

    // MARK: - 导出清单 loudness 字段

    private func readManifestJSON(
        store: AudiobookProjectStore,
        requestID: UUID
    ) async throws -> [String: Any] {
        let rootURL = await store.rootURL
        let url = rootURL
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent(requestID.uuidString, isDirectory: true)
            .appendingPathComponent("request.json", isDirectory: false)
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeLoudnessExportController(
        store: AudiobookProjectStore,
        revisionController: AudiobookRevisionController
    ) -> AudiobookExportController {
        AudiobookExportController(
            store: store,
            castController: AudiobookCastController(store: store),
            revisionController: revisionController,
            customStageEncoder: Self.fakeStageEncoder,
            mediaVerifier: Self.fakeMediaVerifier
        )
    }

    func testExportWithoutLoudnessWritesV1ManifestWithoutLoudnessKey() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let revisionController = AudiobookRevisionController(store: store)
        let controller = makeLoudnessExportController(store: store, revisionController: revisionController)
        let fixture = try await makeTwoChapterExportFixture(
            store: store,
            revisionController: revisionController,
            completeSecondChapter: true
        )

        let prepared = try await controller.prepare(
            bookID: fixture.bookID,
            chapterIDs: nil,
            profile: .m4b
        )

        let json = try await readManifestJSON(store: store, requestID: prepared.requestID)
        XCTAssertEqual(json["schema_version"] as? String, AudiobookExportManifestPayload.v1SchemaVersion)
        XCTAssertNil(json["loudness"])
    }

    func testExportWithLoudnessWritesV2ManifestContainingObject() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let revisionController = AudiobookRevisionController(store: store)
        let controller = makeLoudnessExportController(store: store, revisionController: revisionController)
        let fixture = try await makeTwoChapterExportFixture(
            store: store,
            revisionController: revisionController,
            completeSecondChapter: true
        )

        let prepared = try await controller.prepare(
            bookID: fixture.bookID,
            chapterIDs: nil,
            profile: .m4b,
            loudness: AudiobookLoudnessSettings()
        )

        let json = try await readManifestJSON(store: store, requestID: prepared.requestID)
        XCTAssertEqual(json["schema_version"] as? String, AudiobookExportManifestPayload.v2SchemaVersion)
        let loudness = try XCTUnwrap(json["loudness"] as? [String: Any])
        XCTAssertEqual(loudness["unit"] as? String, "lufs")
        XCTAssertEqual(loudness["target_i"] as? Double, -16)
        XCTAssertEqual(loudness["true_peak_db"] as? Double, -1.5)
        XCTAssertEqual(loudness["loudness_range"] as? Double, 11)
    }

    func testCoverAndLoudnessOnM4BWritesBoth() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let revisionController = AudiobookRevisionController(store: store)
        let controller = makeLoudnessExportController(store: store, revisionController: revisionController)
        let fixture = try await makeTwoChapterExportFixture(
            store: store,
            revisionController: revisionController,
            completeSecondChapter: true
        )
        let cover = AudiobookCoverAsset(
            bookID: fixture.bookID,
            relativePath: "books/\(fixture.bookID.uuidString.lowercased())/cover/cover.jpg",
            fileSHA256: String(repeating: "a", count: 64),
            byteCount: 1024
        )

        let prepared = try await controller.prepare(
            bookID: fixture.bookID,
            chapterIDs: nil,
            profile: .m4b,
            cover: cover,
            loudness: AudiobookLoudnessSettings()
        )

        let json = try await readManifestJSON(store: store, requestID: prepared.requestID)
        XCTAssertEqual(json["schema_version"] as? String, AudiobookExportManifestPayload.v2SchemaVersion)
        let coverJSON = try XCTUnwrap(json["cover"] as? [String: Any])
        XCTAssertEqual(coverJSON["relative_path"] as? String, cover.relativePath)
        XCTAssertNotNil(json["loudness"])
    }
}
