import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

final class AudiobookProductionTests: XCTestCase {
    nonisolated(unsafe) private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiobookProductionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    private final class FakeAudiobookClock: AudiobookClock, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var sleptSeconds: [TimeInterval] = []

        func now() -> Date { Date(timeIntervalSince1970: 1_700_000_000) }

        func sleep(seconds: TimeInterval) async throws {
            lock.withLock {
            sleptSeconds.append(seconds)
            }
        }
    }

    private final class ScriptedSpeechRenderer: AudiobookSpeechRenderer, @unchecked Sendable {
        private let lock = NSLock()
        var capabilities: EffectiveCapabilitySnapshot
        private(set) var requests: [AudiobookRenderCallRequest] = []
        var scriptedErrors: [Error] = []
        var onRenderStart: (@Sendable (AudiobookRenderCallRequest) async throws -> Void)?

        init(capabilities: EffectiveCapabilitySnapshot) {
            self.capabilities = capabilities
        }

        func fetchEffectiveCapabilities() async throws -> EffectiveCapabilitySnapshot {
            capabilities
        }

        func renderFragment(_ request: AudiobookRenderCallRequest) async throws -> AudiobookRenderCallOutput {
            let nextError: Error? = lock.withLock {
                requests.append(request)
                return scriptedErrors.isEmpty ? nil : scriptedErrors.removeFirst()
            }

            if let onRenderStart {
                try await onRenderStart(request)
            }
            if let nextError {
                throw nextError
            }

            let wav = Self.makePCM16MonoWAV(frameCount: 4_800, sampleValue: 1_024)
            let pcmSHA = try AudioDigest.sha256HexOfPCM(in: wav)
            return AudiobookRenderCallOutput(
                wavData: wav,
                voiceRevision: request.expectedVoiceRevision,
                modelRevision: request.expectedModelRevision,
                pcmSHA256: pcmSHA,
                requestID: "req-\(UUID().uuidString.prefix(8))",
                receiptID: "rr_0123456789abcdef0123456789abcdef",
                recipeSummary: "verified",
                isProvenanceVerified: true
            )
        }

        static func makePCM16MonoWAV(frameCount: Int, sampleValue: Int16) -> Data {
            let pcmByteCount = frameCount * 2
            let totalByteCount = 44 + pcmByteCount
            var data = Data(capacity: totalByteCount)
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
    }

    private func makeDefaultCapabilities() -> EffectiveCapabilitySnapshot {
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
        let voices = [
            SafeVoiceEntry(
                id: "v-narrator",
                name: "沉稳旁白",
                mode: "instruction",
                available: true,
                availabilityReason: .available,
                voiceRevision: "rev-n1",
                voiceIdentityAssurance: .contentAddressed,
                model: model,
                descriptors: desc,
                operations: [:],
                productionReady: true
            ),
            SafeVoiceEntry(
                id: "v-hero",
                name: "青年林远",
                mode: "instruction",
                available: true,
                availabilityReason: .available,
                voiceRevision: "rev-h1",
                voiceIdentityAssurance: .contentAddressed,
                model: model,
                descriptors: desc,
                operations: [:],
                productionReady: true
            )
        ]
        return EffectiveCapabilitySnapshot(
            serviceInstanceEpoch: "epoch-1",
            catalogRevision: "cat-1",
            snapshotID: "snap-1",
            profile: "quality",
            models: ["tts": model],
            voices: voices,
            operations: [:],
            guarantees: [:]
        )
    }

    @MainActor
    func testFormalRenderRequiresAnalysisCastAuditionAndChapterReadiness() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let castController = AudiobookCastController(store: store)
        let revisionController = AudiobookRevisionController(store: store)
        let admission = SpeechCreationAdmission()
        let renderer = ScriptedSpeechRenderer(capabilities: makeDefaultCapabilities())
        let clock = FakeAudiobookClock()
        let production = AudiobookProductionController(
            store: store,
            castController: castController,
            revisionController: revisionController,
            renderer: renderer,
            admission: admission,
            clock: clock
        )

        let text = "第一章 潮起\n海风吹过礁石。\n“准备起航！”林远喊道。\n"
        let url = tempRoot.appendingPathComponent("book.txt")
        try Data(text.utf8).write(to: url)
        let preview = try await AudiobookTXTImporter.prepare(fileURL: url, encoding: .utf8)
        let bookID = try await store.importBook(preview)
        let chapters = try await store.chapters(for: bookID)
        let chapter = try XCTUnwrap(chapters.first)

        // 1. 未完成全书分析时拒绝正式制作
        do {
            try await production.start(bookID: bookID, chapterIDs: [chapter.id])
            XCTFail("未完成全书分析不应开始制作")
        } catch let error as AudiobookProductionError {
            XCTAssertEqual(error, .globalAnalysisNotCompleted)
        }

        // 2. 标记全书分析完成，但未确认角色时拒绝
        var book = try await store.book(id: bookID)
        book.analysisState = .allWindowsValidated
        try await store.updateBook(book)

        var characters = try await store.characters(for: bookID)
        let narrator = try XCTUnwrap(characters.first(where: \.isNarrator))
        let hero = AudiobookCharacter(bookID: bookID, displayName: "林远", isNarrator: false, isMajor: true, chapterIDs: [chapter.id])
        characters.append(hero)
        try await store.saveCharacters(bookID: bookID, characters: characters)

        let atoms = try await store.atoms(for: bookID, chapterID: chapter.id).filter { $0.kind != .formatting }
        let anns = atoms.enumerated().map { idx, atom in
            AudiobookAnnotation(
                bookID: bookID,
                chapterID: chapter.id,
                windowID: UUID(),
                atomID: atom.id,
                sourceRange: atom.sourceRange,
                assignment: idx == atoms.count - 1
                    ? .unknown(reason: "未知对白", candidateRoleIDs: [hero.id])
                    : .assigned(roleID: narrator.id)
            )
        }
        try await store.saveAnnotations(bookID: bookID, annotations: anns)

        try await castController.bindVoice(
            bookID: bookID,
            roleID: narrator.id,
            binding: AudiobookVoiceBinding(roleID: narrator.id, voiceID: "v-narrator", voiceRevision: "rev-n1", modelRevision: "qwen3-tts-v1")
        )
        try await castController.bindVoice(
            bookID: bookID,
            roleID: hero.id,
            binding: AudiobookVoiceBinding(roleID: hero.id, voiceID: "v-hero", voiceRevision: "rev-h1", modelRevision: "qwen3-tts-v1")
        )

        let castRev = try await castController.currentCastRevisionID(for: bookID)
        try await castController.confirmCast(bookID: bookID, revisionID: castRev)

        // 3. 未确认试听门槛时拒绝
        do {
            try await production.start(bookID: bookID, chapterIDs: [chapter.id])
            XCTFail("未完成试听确认不应开始制作")
        } catch let error as AudiobookProductionError {
            XCTAssertEqual(error, .auditionNotConfirmed)
        }

        let voiceDigest = try await castController.currentVoiceSetDigest(for: bookID)
        try await castController.confirmAudition(bookID: bookID, voiceSetDigest: voiceDigest)

        // 4. 章节存在 unknown 说话人时拒绝
        do {
            try await production.start(bookID: bookID, chapterIDs: [chapter.id])
            XCTFail("包含 unknown 说话人的章节不应开始制作")
        } catch let error as AudiobookProductionError {
            XCTAssertEqual(error, .chapterBlockedByUnknownSpeakers(chapterID: chapter.id))
        }

        // 5. 解决 unknown 后正式制作成功，固定 speed=1.0 且核验 pins
        try await castController.assignRole(
            bookID: bookID,
            atomIDs: [atoms.last!.id],
            roleID: hero.id
        )
        try await production.start(bookID: bookID, chapterIDs: [chapter.id])

        XCTAssertEqual(renderer.requests.count, 2)
        XCTAssertEqual(renderer.requests[0].voiceID, "v-narrator")
        XCTAssertEqual(renderer.requests[0].expectedVoiceRevision, "rev-n1")
        XCTAssertEqual(renderer.requests[0].speed, 1.0)
        XCTAssertEqual(renderer.requests[1].voiceID, "v-hero")
        XCTAssertFalse(admission.isBusy)

        let finalBook = try await store.book(id: bookID)
        XCTAssertEqual(finalBook.productionState, .fullBookProduced)
        XCTAssertEqual(finalBook.listenableState, .fullBookListenable)
    }

    @MainActor
    func testPauseWaitsForInFlightAndRejectsLateCommit() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let castController = AudiobookCastController(store: store)
        let revisionController = AudiobookRevisionController(store: store)
        let admission = SpeechCreationAdmission()
        let renderer = ScriptedSpeechRenderer(capabilities: makeDefaultCapabilities())
        let clock = FakeAudiobookClock()
        let production = AudiobookProductionController(
            store: store,
            castController: castController,
            revisionController: revisionController,
            renderer: renderer,
            admission: admission,
            clock: clock
        )

        let text = "第一章 暂停测试\n第一段旁白。\n“第二段主角说话。”\n"
        let url = tempRoot.appendingPathComponent("pause.txt")
        try Data(text.utf8).write(to: url)
        let preview = try await AudiobookTXTImporter.prepare(fileURL: url, encoding: .utf8)
        let bookID = try await store.importBook(preview)
        let chapter = try await store.chapters(for: bookID)[0]

        var book = try await store.book(id: bookID)
        book.analysisState = .allWindowsValidated
        try await store.updateBook(book)

        let narrator = try await store.characters(for: bookID)[0]
        let atoms = try await store.atoms(for: bookID, chapterID: chapter.id).filter { $0.kind != .formatting }
        let anns = atoms.map { atom in
            AudiobookAnnotation(
                bookID: bookID,
                chapterID: chapter.id,
                windowID: UUID(),
                atomID: atom.id,
                sourceRange: atom.sourceRange,
                assignment: .assigned(roleID: narrator.id)
            )
        }
        try await store.saveAnnotations(bookID: bookID, annotations: anns)
        try await castController.bindVoice(
            bookID: bookID,
            roleID: narrator.id,
            binding: AudiobookVoiceBinding(roleID: narrator.id, voiceID: "v-narrator", voiceRevision: "rev-n1", modelRevision: "qwen3-tts-v1")
        )
        let castRev = try await castController.currentCastRevisionID(for: bookID)
        try await castController.confirmCast(bookID: bookID, revisionID: castRev)
        let voiceDigest = try await castController.currentVoiceSetDigest(for: bookID)
        try await castController.confirmAudition(bookID: bookID, voiceSetDigest: voiceDigest)

        renderer.onRenderStart = { _ in
            Task {
                await production.pause()
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        do {
            try await production.start(bookID: bookID, chapterIDs: [chapter.id])
            XCTFail("暂停后应抛出 cancelled")
        } catch let error as AudiobookProductionError {
            XCTAssertEqual(error, .cancelled)
        }

        let candidatesAfterPause = try await store.candidates(for: bookID)
        XCTAssertTrue(candidatesAfterPause.isEmpty, "暂停后迟到的音频绝不能写入候选库或标记完成")
        XCTAssertFalse(admission.isBusy, "暂停后必须释放 creation admission 租约")
    }

    @MainActor
    func testBusyHasFiniteRetryAndNoSilentVoiceChange() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let castController = AudiobookCastController(store: store)
        let revisionController = AudiobookRevisionController(store: store)
        let admission = SpeechCreationAdmission()
        let renderer = ScriptedSpeechRenderer(capabilities: makeDefaultCapabilities())
        let clock = FakeAudiobookClock()
        let production = AudiobookProductionController(
            store: store,
            castController: castController,
            revisionController: revisionController,
            renderer: renderer,
            admission: admission,
            clock: clock
        )

        let text = "第一章 重试测试\n夜色渐浓。\n"
        let url = tempRoot.appendingPathComponent("retry.txt")
        try Data(text.utf8).write(to: url)
        let preview = try await AudiobookTXTImporter.prepare(fileURL: url, encoding: .utf8)
        let bookID = try await store.importBook(preview)
        let chapter = try await store.chapters(for: bookID)[0]

        var book = try await store.book(id: bookID)
        book.analysisState = .allWindowsValidated
        try await store.updateBook(book)

        let narrator = try await store.characters(for: bookID)[0]
        let atoms = try await store.atoms(for: bookID, chapterID: chapter.id).filter { $0.kind != .formatting }
        let anns = atoms.map { atom in
            AudiobookAnnotation(
                bookID: bookID,
                chapterID: chapter.id,
                windowID: UUID(),
                atomID: atom.id,
                sourceRange: atom.sourceRange,
                assignment: .assigned(roleID: narrator.id)
            )
        }
        try await store.saveAnnotations(bookID: bookID, annotations: anns)
        try await castController.bindVoice(
            bookID: bookID,
            roleID: narrator.id,
            binding: AudiobookVoiceBinding(roleID: narrator.id, voiceID: "v-narrator", voiceRevision: "rev-n1", modelRevision: "qwen3-tts-v1")
        )
        let castRev = try await castController.currentCastRevisionID(for: bookID)
        try await castController.confirmCast(bookID: bookID, revisionID: castRev)
        let voiceDigest = try await castController.currentVoiceSetDigest(for: bookID)
        try await castController.confirmAudition(bookID: bookID, voiceSetDigest: voiceDigest)

        let busyError = ServiceAPIClientError.http(
            statusCode: 429,
            code: "backend_busy",
            message: "busy",
            requestID: "req-busy",
            retryable: true
        )
        // 连续 4 次 busy（初试 1 次 + 最多 3 次自动重试）必须明确失败，绝不无限循环
        renderer.scriptedErrors = [busyError, busyError, busyError, busyError]

        do {
            try await production.start(bookID: bookID, chapterIDs: [chapter.id])
            XCTFail("超过 3 次自动恢复后应停止并报错")
        } catch let error as AudiobookProductionError {
            if case .transientRetriesExhausted = error {
                // expected
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(renderer.requests.count, 4)
        XCTAssertTrue(renderer.requests.allSatisfy { $0.voiceID == "v-narrator" && $0.expectedVoiceRevision == "rev-n1" })
    }
}
