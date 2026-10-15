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
        let outputSampleRate: Int
        private(set) var requests: [AudiobookRenderCallRequest] = []
        var scriptedErrors: [Error] = []
        var onCapabilitiesFetch: (@Sendable () async throws -> Void)?
        var onRenderStart: (@Sendable (AudiobookRenderCallRequest) async throws -> Void)?

        init(capabilities: EffectiveCapabilitySnapshot, outputSampleRate: Int = 48_000) {
            self.capabilities = capabilities
            self.outputSampleRate = outputSampleRate
        }

        func fetchEffectiveCapabilities() async throws -> EffectiveCapabilitySnapshot {
            if let onCapabilitiesFetch {
                try await onCapabilitiesFetch()
            }
            return capabilities
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

            let wav = Self.makePCM16MonoWAV(
                frameCount: outputSampleRate / 10,
                sampleValue: 1_024,
                sampleRate: outputSampleRate
            )
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

        static func makePCM16MonoWAV(
            frameCount: Int,
            sampleValue: Int16,
            sampleRate: Int = 48_000
        ) -> Data {
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
            var encodedSampleRate = UInt32(sampleRate).littleEndian
            var byteRate = UInt32(sampleRate * 2).littleEndian
            var blockAlign = UInt16(2).littleEndian
            var bitsPerSample = UInt16(16).littleEndian
            data.append(Data(bytes: &fmtChunkSize, count: 4))
            data.append(Data(bytes: &audioFormat, count: 2))
            data.append(Data(bytes: &numChannels, count: 2))
            data.append(Data(bytes: &encodedSampleRate, count: 4))
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

    private actor AsyncGate {
        private var isOpen = false
        private var continuations: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }

        func open() {
            guard !isOpen else { return }
            isOpen = true
            let waiting = continuations
            continuations.removeAll()
            waiting.forEach { $0.resume() }
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

    private func wavSampleRate(_ wav: Data) -> Int {
        guard wav.count >= 28 else { return 0 }
        return Int(wav[24])
            | (Int(wav[25]) << 8)
            | (Int(wav[26]) << 16)
            | (Int(wav[27]) << 24)
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

        await production.shutdown()
        let bookAfterShutdown = try await store.book(id: bookID)
        XCTAssertEqual(bookAfterShutdown.productionState, .fullBookProduced,
                       "无进行中任务时关闭制作器不得把已完成书籍改为暂停")
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
    func testConcurrentStartDoesNotInvalidateFirstRunOrLeakAdmission() async throws {
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

        let text = "第一章 并发制作测试\n夜色渐浓。\n"
        let url = tempRoot.appendingPathComponent("concurrent-start.txt")
        try Data(text.utf8).write(to: url)
        let preview = try await AudiobookTXTImporter.prepare(fileURL: url, encoding: .utf8)
        let bookID = try await store.importBook(preview)
        let chapter = try await store.chapters(for: bookID)[0]

        var book = try await store.book(id: bookID)
        book.analysisState = .allWindowsValidated
        try await store.updateBook(book)

        let narrator = try await store.characters(for: bookID)[0]
        let atoms = try await store.atoms(for: bookID, chapterID: chapter.id).filter { $0.kind != .formatting }
        let annotations = atoms.map { atom in
            AudiobookAnnotation(
                bookID: bookID,
                chapterID: chapter.id,
                windowID: UUID(),
                atomID: atom.id,
                sourceRange: atom.sourceRange,
                assignment: .assigned(roleID: narrator.id)
            )
        }
        try await store.saveAnnotations(bookID: bookID, annotations: annotations)
        try await castController.bindVoice(
            bookID: bookID,
            roleID: narrator.id,
            binding: AudiobookVoiceBinding(
                roleID: narrator.id,
                voiceID: "v-narrator",
                voiceRevision: "rev-n1",
                modelRevision: "qwen3-tts-v1"
            )
        )
        let castRevisionID = try await castController.currentCastRevisionID(for: bookID)
        try await castController.confirmCast(bookID: bookID, revisionID: castRevisionID)
        let voiceSetDigest = try await castController.currentVoiceSetDigest(for: bookID)
        try await castController.confirmAudition(bookID: bookID, voiceSetDigest: voiceSetDigest)

        let renderStarted = AsyncGate()
        let finishRender = AsyncGate()
        renderer.onRenderStart = { _ in
            await renderStarted.open()
            await finishRender.wait()
        }

        let firstRun = Task {
            try await production.start(bookID: bookID, chapterIDs: [chapter.id])
        }
        await renderStarted.wait()

        do {
            try await production.start(bookID: bookID, chapterIDs: [chapter.id])
            XCTFail("已有制作运行时，第二次 start 必须稳定返回 busy")
        } catch let error as AudiobookProductionError {
            XCTAssertEqual(error, .admissionBusy)
        }

        await finishRender.open()
        do {
            try await firstRun.value
        } catch {
            XCTFail("第二次 start 不得使第一条制作失效：\(error)")
        }

        XCTAssertFalse(admission.isBusy, "拒绝并发 start 后，第一条任务完成仍须释放 creation admission")
        let candidates = try await store.candidates(for: bookID)
        let finalBook = try await store.book(id: bookID)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(finalBook.productionState, .fullBookProduced)
    }

    @MainActor
    func testPauseDuringPreflightIsNotClearedBeforeRenderingStarts() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let castController = AudiobookCastController(store: store)
        let revisionController = AudiobookRevisionController(store: store)
        let admission = SpeechCreationAdmission()
        let renderer = ScriptedSpeechRenderer(capabilities: makeDefaultCapabilities())
        let production = AudiobookProductionController(
            store: store,
            castController: castController,
            revisionController: revisionController,
            renderer: renderer,
            admission: admission,
            clock: FakeAudiobookClock()
        )

        let url = tempRoot.appendingPathComponent("pause-during-preflight.txt")
        try Data("第一章 暂停测试\n夜色渐浓。\n".utf8).write(to: url)
        let preview = try await AudiobookTXTImporter.prepare(fileURL: url, encoding: .utf8)
        let bookID = try await store.importBook(preview)
        let chapter = try await store.chapters(for: bookID)[0]
        var book = try await store.book(id: bookID)
        book.analysisState = .allWindowsValidated
        try await store.updateBook(book)

        let narrator = try await store.characters(for: bookID)[0]
        let atoms = try await store.atoms(for: bookID, chapterID: chapter.id)
            .filter { $0.kind != .formatting }
        let annotations = atoms.map { atom in
            AudiobookAnnotation(
                bookID: bookID,
                chapterID: chapter.id,
                windowID: UUID(),
                atomID: atom.id,
                sourceRange: atom.sourceRange,
                assignment: .assigned(roleID: narrator.id)
            )
        }
        try await store.saveAnnotations(bookID: bookID, annotations: annotations)
        try await castController.bindVoice(
            bookID: bookID,
            roleID: narrator.id,
            binding: AudiobookVoiceBinding(
                roleID: narrator.id,
                voiceID: "v-narrator",
                voiceRevision: "rev-n1",
                modelRevision: "qwen3-tts-v1"
            )
        )
        let castRevisionID = try await castController.currentCastRevisionID(for: bookID)
        try await castController.confirmCast(bookID: bookID, revisionID: castRevisionID)
        let voiceSetDigest = try await castController.currentVoiceSetDigest(for: bookID)
        try await castController.confirmAudition(bookID: bookID, voiceSetDigest: voiceSetDigest)

        let capabilitiesFetchStarted = AsyncGate()
        let finishCapabilitiesFetch = AsyncGate()
        renderer.onCapabilitiesFetch = {
            await capabilitiesFetchStarted.open()
            await finishCapabilitiesFetch.wait()
        }
        let productionRun = Task {
            try await production.start(bookID: bookID, chapterIDs: [chapter.id])
        }
        await capabilitiesFetchStarted.wait()
        await production.pause()
        await finishCapabilitiesFetch.open()

        do {
            try await productionRun.value
            XCTFail("预检期间请求暂停后，启动流程不得清除暂停并开始渲染")
        } catch let error as AudiobookProductionError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertTrue(renderer.requests.isEmpty, "预检阶段暂停后不得提交语音渲染请求")
        XCTAssertFalse(admission.isBusy, "预检阶段暂停不得留下 creation admission 租约")
    }

    @MainActor
    func testProductionResamplesTwentyFourKRenderToPolicyRate() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let castController = AudiobookCastController(store: store)
        let revisionController = AudiobookRevisionController(store: store)
        let admission = SpeechCreationAdmission()
        let renderer = ScriptedSpeechRenderer(
            capabilities: makeDefaultCapabilities(),
            outputSampleRate: 24_000
        )
        let production = AudiobookProductionController(
            store: store,
            castController: castController,
            revisionController: revisionController,
            renderer: renderer,
            admission: admission,
            clock: FakeAudiobookClock()
        )

        let url = tempRoot.appendingPathComponent("resample-24k.txt")
        try Data("第一章 采样率测试\n测试正文。\n".utf8).write(to: url)
        let preview = try await AudiobookTXTImporter.prepare(fileURL: url, encoding: .utf8)
        let bookID = try await store.importBook(preview)
        let chapter = try await store.chapters(for: bookID)[0]
        var book = try await store.book(id: bookID)
        book.analysisState = .allWindowsValidated
        try await store.updateBook(book)

        let narrator = try await store.characters(for: bookID)[0]
        let atoms = try await store.atoms(for: bookID, chapterID: chapter.id)
            .filter { $0.kind != .formatting }
        let annotations = atoms.map { atom in
            AudiobookAnnotation(
                bookID: bookID,
                chapterID: chapter.id,
                windowID: UUID(),
                atomID: atom.id,
                sourceRange: atom.sourceRange,
                assignment: .assigned(roleID: narrator.id)
            )
        }
        try await store.saveAnnotations(bookID: bookID, annotations: annotations)
        try await castController.bindVoice(
            bookID: bookID,
            roleID: narrator.id,
            binding: AudiobookVoiceBinding(
                roleID: narrator.id,
                voiceID: "v-narrator",
                voiceRevision: "rev-n1",
                modelRevision: "qwen3-tts-v1"
            )
        )
        let castRevisionID = try await castController.currentCastRevisionID(for: bookID)
        try await castController.confirmCast(bookID: bookID, revisionID: castRevisionID)
        let voiceSetDigest = try await castController.currentVoiceSetDigest(for: bookID)
        try await castController.confirmAudition(bookID: bookID, voiceSetDigest: voiceSetDigest)

        // Legacy policy stored the service's 24 kHz bytes while labelling them 48 kHz.
        // A new production run must preserve that asset but render a corrected candidate.
        let source = try await store.sourceIndex(for: bookID)
        let bindings = try await store.voiceBindings(for: bookID)
        let allAtoms = try await store.atoms(for: bookID, chapterID: chapter.id)
        let legacyFragments = try AudiobookFragmentPlanner.plan(
            chapter: chapter,
            annotations: annotations,
            bindings: bindings,
            policy: AudiobookRenderPolicy(version: "audiobook_render_policy_v1"),
            source: source,
            atoms: allAtoms
        )
        let legacyWAV = ScriptedSpeechRenderer.makePCM16MonoWAV(
            frameCount: 2_400,
            sampleValue: 1_024,
            sampleRate: 24_000
        )
        for fragment in legacyFragments {
            let candidateID = UUID()
            let candidate = AudiobookRenderCandidate(
                id: candidateID,
                bookID: bookID,
                chapterID: chapter.id,
                fragmentID: fragment.id,
                taskID: UUID(),
                generation: 0,
                relativeAssetPath: "books/\(bookID.uuidString)/audio/\(candidateID.uuidString).wav",
                fileSHA256: AudiobookDigest.sha256Hex(legacyWAV),
                pcmSHA256: try AudioDigest.sha256HexOfPCM(in: legacyWAV),
                frameCount: 2_400,
                sampleRate: 48_000,
                dependencyDigest: fragment.dependencyDigest,
                requestID: "legacy-rate-metadata",
                receiptDigest: nil,
                recipeSummary: nil,
                isReceiptVerified: true,
                createdAt: Date()
            )
            try await store.commitCandidate(candidate, wav: legacyWAV)
        }

        try await production.start(bookID: bookID, chapterIDs: [chapter.id])
        let candidates = try await store.candidates(for: bookID)
        XCTAssertFalse(renderer.requests.isEmpty, "不能复用旧策略中采样率标记错误的候选")
        let candidate = try XCTUnwrap(candidates.first { $0.requestID != "legacy-rate-metadata" })
        let assetURL = try await store.resolveAssetFileURL(for: candidate)
        let wav = try Data(contentsOf: assetURL)

        XCTAssertEqual(wavSampleRate(wav), 48_000, "持久化 WAV 头和候选元数据必须都是真实 48 kHz")
        XCTAssertEqual(candidate.sampleRate, 48_000)
        XCTAssertEqual(candidate.frameCount, 4_800, "24 kHz 的 0.1 秒输入应重采样为 48 kHz 的 0.1 秒")
        XCTAssertEqual(Double(candidate.frameCount) / Double(candidate.sampleRate), 0.1, accuracy: 0.001)
        XCTAssertTrue(candidate.isReceiptVerified, "回执应按服务端原始 PCM 核验，再对重采样产物单独计算本地摘要")
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
