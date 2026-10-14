import Foundation
import SpeechRailControlKit
import XCTest
@testable import SpeechRailAppSupport

final class AudiobookStoreTests: XCTestCase {
    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiobookStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeDeterministicWAV(pcmSamples: [Int16], sampleRate: Int = 48_000) -> Data {
        var pcmData = Data(capacity: pcmSamples.count * 2)
        for sample in pcmSamples {
            var le = sample.littleEndian
            withUnsafeBytes(of: &le) { pcmData.append(contentsOf: $0) }
        }

        let dataSize = UInt32(pcmData.count)
        let riffSize = 36 + dataSize
        let byteRate = UInt32(sampleRate * 2)
        let blockAlign: UInt16 = 2
        let bitsPerSample: UInt16 = 16

        var wav = Data()
        wav.append(contentsOf: "RIFF".utf8)
        withUnsafeBytes(of: riffSize.littleEndian) { wav.append(contentsOf: $0) }
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8)
        var fmtSize: UInt32 = 16
        withUnsafeBytes(of: &fmtSize) { wav.append(contentsOf: $0) }
        var audioFormat: UInt16 = 1
        withUnsafeBytes(of: &audioFormat) { wav.append(contentsOf: $0) }
        var channels: UInt16 = 1
        withUnsafeBytes(of: &channels) { wav.append(contentsOf: $0) }
        var sr = UInt32(sampleRate).littleEndian
        withUnsafeBytes(of: &sr) { wav.append(contentsOf: $0) }
        var br = byteRate.littleEndian
        withUnsafeBytes(of: &br) { wav.append(contentsOf: $0) }
        var ba = blockAlign.littleEndian
        withUnsafeBytes(of: &ba) { wav.append(contentsOf: $0) }
        var bps = bitsPerSample.littleEndian
        withUnsafeBytes(of: &bps) { wav.append(contentsOf: $0) }
        wav.append(contentsOf: "data".utf8)
        var ds = dataSize.littleEndian
        withUnsafeBytes(of: &ds) { wav.append(contentsOf: $0) }
        wav.append(pcmData)
        return wav
    }

    func testAssetCommitRecoversEveryCrashBoundary() async throws {
        for stage in AudiobookCommitCrashStage.allCases {
            let root = try makeTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }

            let store = try AudiobookProjectStore(root: root)
            let preview = try AudiobookTXTImporter.prepare(
                rawData: Data("第1章 灯塔\n海雾在午夜漫过栈桥。".utf8),
                suggestedTitle: "雾港"
            )
            let bookID = try await store.importBook(preview)
            let chapter = try await store.chapters(for: bookID)[0]
            let wav = Self.makeDeterministicWAV(pcmSamples: Array(repeating: 1200, count: 480))
            let fileSHA = AudiobookDigest.sha256Hex(wav)
            let pcmSHA = try AudioDigest.sha256HexOfPCM(in: wav)

            let candidate = AudiobookRenderCandidate(
                bookID: bookID,
                chapterID: chapter.id,
                fragmentID: UUID(),
                generation: 1,
                relativeAssetPath: "books/\(bookID.uuidString)/audio/cand-\(stage.rawValue).wav",
                fileSHA256: fileSHA,
                pcmSHA256: pcmSHA,
                frameCount: 480,
                dependencyDigest: "dep-1"
            )

            await store.setSimulatedCrashStage(stage)
            do {
                try await store.commitCandidate(candidate, wav: wav)
                XCTFail("Expected simulated crash at \(stage)")
            } catch let error as AudiobookStoreError {
                XCTAssertEqual(error, .simulatedCrash(stage))
            }

            // Reopen store and run recover()
            let reopened = try AudiobookProjectStore(root: root)
            let report = try await reopened.recover()

            switch stage {
            case .afterJournalStarted:
                // Temp WAV had not been written yet; no phantom completion
                let candidates = try await reopened.candidates(for: bookID)
                XCTAssertTrue(candidates.isEmpty)
            case .afterTempAssetWritten, .afterAssetRenamed, .afterDatabaseCommitted, .afterJournalCompleted:
                // Valid asset existed in temp or final location; recovery must leave exactly 1 verifiable reference
                let candidates = try await reopened.candidates(for: bookID)
                XCTAssertEqual(candidates.count, 1)
                let isVerified = try await reopened.verifyCandidateAsset(candidates[0])
                XCTAssertTrue(isVerified)
                XCTAssertTrue(
                    report.recoveredCandidateIDs.contains(candidate.id)
                        || report.verifiedCandidateIDs.contains(candidate.id)
                )
            }
        }
    }

    func testDiskFullNeverMarksFragmentComplete() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try AudiobookProjectStore(root: root)
        let preview = try AudiobookTXTImporter.prepare(
            rawData: Data("第1章 灯塔\n海雾漫过栈桥。".utf8),
            suggestedTitle: "雾港"
        )
        let bookID = try await store.importBook(preview)
        let chapter = try await store.chapters(for: bookID)[0]
        let wav = Self.makeDeterministicWAV(pcmSamples: [100, 200, 300, 400])
        let candidate = AudiobookRenderCandidate(
            bookID: bookID,
            chapterID: chapter.id,
            fragmentID: UUID(),
            generation: 1,
            relativeAssetPath: "books/\(bookID.uuidString)/audio/cand-diskfull.wav",
            fileSHA256: AudiobookDigest.sha256Hex(wav),
            pcmSHA256: try AudioDigest.sha256HexOfPCM(in: wav),
            frameCount: 4,
            dependencyDigest: "dep-1"
        )

        await store.setSimulateDiskFull(true)
        do {
            try await store.commitCandidate(candidate, wav: wav)
            XCTFail("Expected diskFull error")
        } catch let error as AudiobookStoreError {
            XCTAssertEqual(error, .diskFull)
        }

        let candidates = try await store.candidates(for: bookID)
        XCTAssertTrue(candidates.isEmpty)
    }

    func testMissingOrTamperedAssetNeedsRepair() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try AudiobookProjectStore(root: root)
        let preview = try AudiobookTXTImporter.prepare(
            rawData: Data("第1章 灯塔\n海雾漫过栈桥。".utf8),
            suggestedTitle: "雾港"
        )
        let bookID = try await store.importBook(preview)
        let chapter = try await store.chapters(for: bookID)[0]
        let wav = Self.makeDeterministicWAV(pcmSamples: [500, -500, 500, -500])
        let candidate = AudiobookRenderCandidate(
            bookID: bookID,
            chapterID: chapter.id,
            fragmentID: UUID(),
            generation: 1,
            relativeAssetPath: "books/\(bookID.uuidString)/audio/cand-tamper.wav",
            fileSHA256: AudiobookDigest.sha256Hex(wav),
            pcmSHA256: try AudioDigest.sha256HexOfPCM(in: wav),
            frameCount: 4,
            dependencyDigest: "dep-1"
        )
        try await store.commitCandidate(candidate, wav: wav)

        // Also place an unknown file in audio/ — recover() must preserve it, never delete it
        let unknownRel = "books/\(bookID.uuidString)/audio/user-note.txt"
        let unknownURL = try await store.resolveOwnedURL(relativePath: unknownRel)
        try Data("keep me".utf8).write(to: unknownURL)

        // Tamper with the committed WAV file on disk
        let wavURL = try await store.resolveOwnedURL(relativePath: candidate.relativeAssetPath)
        try Data("corrupted-bytes".utf8).write(to: wavURL)

        let report = try await store.recover()
        XCTAssertTrue(report.damagedCandidateIDs.contains(candidate.id))
        XCTAssertTrue(report.preservedUnknownRelativePaths.contains(unknownRel))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknownURL.path))
    }

    func testTrashBookPreservesOriginalExportsAndDubbing() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let externalDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiobookExternal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalDir) }

        let originalTXT = externalDir.appendingPathComponent("original-book.txt")
        let exportedM4B = externalDir.appendingPathComponent("exported-book.m4b")
        let dubbingWork = externalDir.appendingPathComponent("dubbing-work.wav")
        try Data("第1章 原书\n正文内容。".utf8).write(to: originalTXT)
        try Data("m4b-content".utf8).write(to: exportedM4B)
        try Data("dubbing-content".utf8).write(to: dubbingWork)

        let store = try AudiobookProjectStore(root: root)
        let preview = try await AudiobookTXTImporter.prepare(fileURL: originalTXT)
        let bookID = try await store.importBook(preview)

        var books = try await store.listBooks()
        XCTAssertEqual(books.count, 1)

        try await store.trashBook(id: bookID)
        books = try await store.listBooks()
        XCTAssertTrue(books.isEmpty)

        // External source TXT, exported M4B, and dubbing files are untouched
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalTXT.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportedM4B.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dubbingWork.path))

        // Recoverable from trash
        let trashed = try await store.listTrashedBooks()
        XCTAssertEqual(trashed.count, 1)
        try await store.restoreTrashedBook(id: bookID)
        books = try await store.listBooks()
        XCTAssertEqual(books.count, 1)
    }
}
