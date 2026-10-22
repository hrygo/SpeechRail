import Foundation
import SQLite3
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

    private static func makeDefaultCapabilities() -> EffectiveCapabilitySnapshot {
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
            runtimeRevision: String(repeating: "a", count: 40),
            catalogRevision: String(repeating: "a", count: 40)
        )
        let voices = [
            SafeVoiceEntry(
                id: "v-narrator",
                name: "沉稳旁白",
                mode: "system", isSystem: true, isDefault: true,
                available: true,
                availabilityReason: .available,
                voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                voiceIdentityAssurance: .contentAddressed,
                model: model,
                descriptors: desc,
                operations: ["http_speech": JSONValue(.object(["parameters": JSONValue(.object(["speed": JSONValue(.object(["status": JSONValue(.string("supported")), "minimum": JSONValue(.number(0.25)), "maximum": JSONValue(.number(4))]))]))]))],
                productionReady: true
            ),
            SafeVoiceEntry(
                id: "v-hero",
                name: "青年林远",
                mode: "system", isSystem: true, isDefault: true,
                available: true,
                availabilityReason: .available,
                voiceRevision: "vr_1123456789abcdef0123456789abcdef",
                voiceIdentityAssurance: .contentAddressed,
                model: model,
                descriptors: desc,
                operations: ["http_speech": JSONValue(.object(["parameters": JSONValue(.object(["speed": JSONValue(.object(["status": JSONValue(.string("supported")), "minimum": JSONValue(.number(0.25)), "maximum": JSONValue(.number(4))]))]))]))],
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
    private func makePreparedFixture(admission: SpeechCreationAdmission = SpeechCreationAdmission(), editedText: String? = nil, rawText: String? = nil,
                                     catalog: VoiceCatalogStore = VoiceCatalogStore()) async throws -> (AudiobookProjectStore, AudiobookProductionController, ScriptedSpeechRenderer, UUID, AudiobookChapter) {
        let store = try AudiobookProjectStore(root: tempRoot)
        let capabilities = Self.makeDefaultCapabilities()
        let renderer = ScriptedSpeechRenderer(capabilities: capabilities)
        let cast = AudiobookCastController(store: store, capabilityProvider: { capabilities }, voiceCatalog: catalog)
        let raw = "第一章 渡口\r\n他走進大廳之後提到鄉間那位住了許多年又講理學的老監\r\n生，每次見到他時都是先說幾句客氣的話，互相寒\r\n暄，之後才坐下談話。"
        let preview = try AudiobookTXTImporter.prepare(rawData: Data((rawText ?? raw).utf8))
        let bookID = try await store.importBook(preview)
        if let editedText {
            let draft = try await store.chapterEditDraft(bookID: bookID, chapterID: preview.chapters[0].id)
            _ = try await store.saveChapterEdit(draft, title: "人工目录名", body: editedText)
        }
        let chapter = try await store.chapters(for: bookID)[0]
        let narrators = try await store.characters(for: bookID)
        let narrator = try XCTUnwrap(narrators.first)
        let atoms = try await store.atoms(for: bookID, chapterID: chapter.id).filter { $0.kind != .formatting }
        try await store.saveAnnotations(bookID: bookID, annotations: atoms.map {
            .init(bookID: bookID, chapterID: chapter.id, windowID: UUID(), atomID: $0.id,
                  sourceRange: $0.sourceRange, assignment: .assigned(roleID: narrator.id))
        })
        for otherChapter in try await store.chapters(for: bookID).dropFirst() {
            let otherAtoms = try await store.atoms(for: bookID, chapterID: otherChapter.id).filter { $0.kind != .formatting }
            try await store.saveAnnotations(bookID: bookID, annotations: otherAtoms.map {
                .init(bookID: bookID, chapterID: otherChapter.id, windowID: UUID(), atomID: $0.id,
                    sourceRange: $0.sourceRange, assignment: .assigned(roleID: narrator.id))
            })
        }
        var book = try await store.book(id: bookID); book.analysisState = .allWindowsValidated
        try await store.updateBook(book)
        try await cast.bindVoice(bookID: bookID, roleID: narrator.id, binding: .init(roleID: narrator.id,
            voiceID: "v-narrator", voiceRevision: "vr_0123456789abcdef0123456789abcdef", modelRevision: String(repeating: "a", count: 40)))
        try await cast.confirmCast(bookID: bookID, revisionID: cast.currentCastRevisionID(for: bookID))
        try await cast.confirmAudition(bookID: bookID, voiceSetDigest: cast.currentVoiceSetDigest(for: bookID))
        let production = AudiobookProductionController(store: store, castController: cast,
            revisionController: AudiobookRevisionController(store: store), renderer: renderer,
            admission: admission, clock: FakeAudiobookClock(), voiceCatalog: catalog)
        return (store, production, renderer, bookID, chapter)
    }

    @MainActor
    func testScopedRegenerationPreservesEditionAndResumesOnlyItsOwnCandidates() async throws {
        let text = (0..<40).map { "第\($0)段，风从遥远的山间吹来，船上的旅客安静地听着岸边的钟声，等待出发。" }.joined(separator: "\n\n")
        let (store, production, renderer, bookID, chapter) = try await makePreparedFixture(editedText: text)
        try await production.start(bookID: bookID, chapterIDs: [chapter.id])
        let originalCandidates = try await store.candidates(for: bookID)
        let originalChapters = try await store.chapters(for: bookID)
        let originalRevisions = try await store.chapterRevisions(for: bookID, chapterID: chapter.id)
        let fragments = try await store.fragments(for: bookID, chapterID: chapter.id)
        XCTAssertGreaterThan(fragments.count, 2)
        let targets = Set(fragments.prefix(2).map(\.id))
        let scope = AudiobookRegenerationScope.fragments(targets)
        let firstRequestCount = renderer.requests.count
        renderer.onRenderStart = { _ in
            if renderer.requests.count == firstRequestCount + 2 { throw CancellationError() }
        }
        do {
            try await production.start(bookID: bookID, chapterIDs: [chapter.id], regenerationScope: scope)
            XCTFail("应在第二段请求时暂停")
        } catch { XCTAssertEqual(error as? AudiobookProductionError, .cancelled) }
        renderer.onRenderStart = nil
        let savedCheckpoint = try await store.productionCheckpoint(for: bookID)
        let checkpoint = try XCTUnwrap(savedCheckpoint)
        XCTAssertEqual(checkpoint.effectiveRegenerationScope, scope)
        let encoded = try JSONEncoder().encode(checkpoint)
        let restored = try JSONDecoder().decode(AudiobookProductionCheckpoint.self, from: encoded)
        try await production.start(bookID: bookID, chapterIDs: restored.chapterIDs,
            resumingTaskID: restored.taskID, regenerationScope: restored.effectiveRegenerationScope)
        let candidates = try await store.candidates(for: bookID)
        let added = candidates.filter { c in !originalCandidates.contains { $0.id == c.id } }
        XCTAssertEqual(added.count, 2)
        XCTAssertEqual(Set(added.map(\.fragmentID)), targets)
        XCTAssertEqual(Set(added.compactMap(\.taskID)), [checkpoint.taskID])
        let afterChapters = try await store.chapters(for: bookID)
        let afterRevisions = try await store.chapterRevisions(for: bookID, chapterID: chapter.id)
        XCTAssertEqual(afterChapters.map(\.currentChapterRevisionID), originalChapters.map(\.currentChapterRevisionID))
        XCTAssertEqual(afterRevisions, originalRevisions)
        for candidate in originalCandidates {
            let valid = try await store.verifyCandidateAsset(candidate)
            XCTAssertTrue(valid)
        }
        // A deliberate chapter remake produces all-new candidates but does not adopt them.
        let beforeCount = candidates.count
        try await production.start(bookID: bookID, chapterIDs: [chapter.id], regenerationScope: .chapters)
        let afterAll = try await store.candidates(for: bookID)
        XCTAssertEqual(afterAll.count - beforeCount, fragments.count)
        let finalRevisions = try await store.chapterRevisions(for: bookID, chapterID: chapter.id)
        XCTAssertEqual(finalRevisions, originalRevisions)
    }

    @MainActor
    func testRegenerationRejectsEmptyAndForeignFragmentScopesWithoutRendering() async throws {
        let (store, production, renderer, bookID, chapter) = try await makePreparedFixture()
        try await production.start(bookID: bookID, chapterIDs: [chapter.id])
        let before = renderer.requests.count
        for ids in [Set<UUID>(), Set([UUID()])] {
            do {
                try await production.start(bookID: bookID, chapterIDs: [chapter.id], regenerationScope: .fragments(ids))
                XCTFail("空范围或其他章节的片段必须拒绝")
            } catch { }
        }
        XCTAssertEqual(renderer.requests.count, before)
        let chapters = try await store.chapters(for: bookID)
        XCTAssertNotNil(chapters.first?.currentChapterRevisionID)
    }

    @MainActor
    func testRegenerationRejectsChangedSourceWithoutReplacingCheckpointOrAudio() async throws {
        let (store, production, renderer, bookID, chapter) = try await makePreparedFixture()
        try await production.start(bookID: bookID, chapterIDs: [chapter.id])
        let checkpoint = try await store.productionCheckpoint(for: bookID)
        let candidates = try await store.candidates(for: bookID)
        let count = renderer.requests.count
        do {
            try await production.start(bookID: bookID, chapterIDs: [chapter.id],
                regenerationScope: .chapters, expectedSourceID: UUID())
            XCTFail("预览与当前稿件版本不同必须拒绝")
        } catch { XCTAssertEqual(error as? AudiobookStoreError, .workingSourceChanged) }
        let after = try await store.productionCheckpoint(for: bookID)
        let candidatesAfter = try await store.candidates(for: bookID)
        XCTAssertEqual(after, checkpoint)
        XCTAssertEqual(candidatesAfter, candidates)
        XCTAssertEqual(renderer.requests.count, count)
    }

    @MainActor
    func testUpdatedAudioAwaitingAdoptionDoesNotCreateAnotherTask() async throws {
        let (store, production, renderer, bookID, chapter) = try await makePreparedFixture(editedText: "港口的风吹过窗前。")
        try await production.start(bookID: bookID, chapterIDs: [chapter.id])
        try await store.savePronunciationBinding(.init(setID: AudiobookPronunciationBinding.makeSetID(bookID: bookID),
            revision: "pr_changed", entries: [.init(id: "wind", surface: "风", spoken: "fēng")]), bookID: bookID)
        try await production.start(bookID: bookID, chapterIDs: [chapter.id])
        let checkpoint = try await store.productionCheckpoint(for: bookID)
        let count = renderer.requests.count
        try await production.start(bookID: bookID, chapterIDs: [chapter.id])
        let after = try await store.productionCheckpoint(for: bookID)
        XCTAssertEqual(after, checkpoint, "完整候选等待采用时不能重复创建任务")
        XCTAssertEqual(renderer.requests.count, count)
    }

    @MainActor
    func testResumeRejectsSkippedOriginalScopeWithoutReplacingCheckpoint() async throws {
        let (store, production, renderer, bookID, chapter) = try await makePreparedFixture(
            rawText: "第一章 渡口\n风吹过港口。\n第二章 归途\n夜色深沉。")
        let chapterIDs = try await store.chapters(for: bookID).map(\.id)
        renderer.onRenderStart = { _ in throw CancellationError() }
        do { try await production.start(bookID: bookID, chapterIDs: chapterIDs) }
        catch { XCTAssertEqual(error as? AudiobookProductionError, .cancelled) }
        renderer.onRenderStart = nil
        let saved = try await store.productionCheckpoint(for: bookID)
        let checkpoint = try XCTUnwrap(saved)
        try await store.setChapterSkipped(bookID: bookID, chapterID: chapter.id, skipped: true)
        do {
            try await production.start(bookID: bookID, chapterIDs: checkpoint.chapterIDs,
                resumingTaskID: checkpoint.taskID)
            XCTFail("原章节被跳过后不能静默缩小恢复范围")
        } catch { XCTAssertEqual(error as? AudiobookProductionError, .taskScopeChanged) }
        let after = try await store.productionCheckpoint(for: bookID)
        XCTAssertEqual(after, checkpoint)
    }

    @MainActor
    func testRegenerationOfSelectedChaptersAndWholeBookKeepsOtherAudioAndHistory() async throws {
        let (store, production, renderer, bookID, _) = try await makePreparedFixture(
            rawText: "第一章 渡口\n风吹过港口。\n第二章 山路\n夜色深沉。\n第三章 归途\n钟声响起。")
        let chapters = try await store.chapters(for: bookID)
        try await production.start(bookID: bookID, chapterIDs: chapters.map(\.id))
        let adopted = try await store.chapters(for: bookID).map(\.currentChapterRevisionID)
        let before = try await store.candidates(for: bookID)
        let targets = [chapters[0].id, chapters[2].id]
        try await production.start(bookID: bookID, chapterIDs: targets, regenerationScope: .chapters)
        let selectedResult = try await store.candidates(for: bookID)
        let added = selectedResult.filter { c in !before.contains { $0.id == c.id } }
        XCTAssertEqual(Set(added.map(\.chapterID)), Set(targets))
        let saved = try await store.productionCheckpoint(for: bookID)
        XCTAssertEqual(saved?.chapterIDs, targets)
        let beforeWholeCount = renderer.requests.count
        try await production.start(bookID: bookID, chapterIDs: chapters.map(\.id), regenerationScope: .chapters)
        XCTAssertEqual(renderer.requests.count - beforeWholeCount, before.count)
        let after = try await store.chapters(for: bookID)
        XCTAssertEqual(after.map(\.currentChapterRevisionID), adopted)
        for candidate in before {
            let valid = try await store.verifyCandidateAsset(candidate)
            XCTAssertTrue(valid)
        }
    }

    @MainActor
    func testOrdinaryProductionReplayPreservesCompletedTaskAndAudio() async throws {
        let (store, production, renderer, bookID, chapter) = try await makePreparedFixture()
        try await production.start(bookID: bookID, chapterIDs: [chapter.id])
        let checkpoint = try await store.productionCheckpoint(for: bookID)
        let candidates = try await store.candidates(for: bookID)
        let revisions = try await store.chapterRevisions(for: bookID, chapterID: chapter.id)
        let requestCount = renderer.requests.count
        try await production.start(bookID: bookID, chapterIDs: [chapter.id])
        let after = try await store.productionCheckpoint(for: bookID)
        let candidatesAfter = try await store.candidates(for: bookID)
        let revisionsAfter = try await store.chapterRevisions(for: bookID, chapterID: chapter.id)
        XCTAssertEqual(after, checkpoint, "有效成品的重复制作不能新建或替换任务")
        XCTAssertEqual(candidatesAfter, candidates)
        XCTAssertEqual(revisionsAfter, revisions)
        XCTAssertEqual(renderer.requests.count, requestCount)
    }

    @MainActor
    func testProductionAndRerecordReuseHistoricalCastVoiceAndStillRejectArchival() async throws {
        let catalog = VoiceCatalogStore(), historicalBook = UUID(), historicalRole = UUID()
        try await catalog.registerBookExclusiveVoice(voiceID: "v-narrator", bookID: historicalBook,
            bookTitle: "历史文稿", roleID: historicalRole, roleName: "旁白", archetype: .narrator)
        let beforeCatalog = await catalog.refresh()
        let (store, production, renderer, bookID, chapter) = try await makePreparedFixture(catalog: catalog)
        XCTAssertNotEqual(bookID, historicalBook)
        let beforeBindings = try await store.voiceBindings(for: bookID)
        try await production.start(bookID: bookID, chapterIDs: [chapter.id])
        XCTAssertFalse(renderer.requests.isEmpty)
        XCTAssertTrue(renderer.requests.allSatisfy { $0.voiceID == "v-narrator" })
        let fragments = try await store.fragments(for: bookID, chapterID: chapter.id)
        let fragment = try XCTUnwrap(fragments.first)
        try await production.regenerateFragment(bookID: bookID, chapterID: chapter.id, fragmentID: fragment.id)
        let afterCatalog = await catalog.refresh()
        XCTAssertEqual(afterCatalog.state, beforeCatalog.state)
        let afterBindings = try await store.voiceBindings(for: bookID)
        XCTAssertEqual(afterBindings, beforeBindings)
        let requestCount = renderer.requests.count
        try await catalog.archiveVoices(voiceIDs: ["v-narrator"])
        do {
            try await production.regenerateFragment(bookID: bookID, chapterID: chapter.id, fragmentID: fragment.id)
            XCTFail("跨书可用不能绕过归档门禁")
        } catch {}
        XCTAssertEqual(renderer.requests.count, requestCount)
        let archived = await catalog.metadata(for: "v-narrator")
        XCTAssertEqual(archived?.originBookID, historicalBook)
        XCTAssertEqual(archived?.originRoleID, historicalRole)
    }

    @MainActor
    func testProductionAndRerecordUseUserRevisionAndPronunciationMatches() async throws {
        let body = "用户修改👋哨兵：老監生寒暄之后长胖了。"
        let (store, production, renderer, bookID, chapter) = try await makePreparedFixture(editedText: body)
        let source = try await store.workingSourceSnapshot(bookID: bookID)
        let binding = AudiobookPronunciationBinding(setID: AudiobookPronunciationBinding.makeSetID(bookID: bookID), revision: "pr_user",
            entries: [.init(id: "e1", surface: "用户修改👋哨兵", spoken: "用户修改哨兵的读法")])
        let reference = try await store.referenceSourceIndex(for: bookID)
        XCTAssertNil(binding.dependencyComponent(in: try reference.text(in: reference.wholeRange)))
        XCTAssertNotNil(binding.dependencyComponent(in: try source.sourceIndex.text(in: source.sourceIndex.wholeRange)))
        try await store.savePronunciationBinding(binding, bookID: bookID)
        try await production.start(bookID: bookID, chapterIDs: [chapter.id])
        XCTAssertEqual(renderer.requests.map(\.text).joined(), body)
        XCTAssertTrue(renderer.requests.allSatisfy { $0.pronunciationSet == binding.headerValue })
        let fragments = try await store.fragments(for: bookID, chapterID: chapter.id)
        let fragment = try XCTUnwrap(fragments.first)
        try await production.regenerateFragment(bookID: bookID, chapterID: chapter.id, fragmentID: fragment.id)
        XCTAssertEqual(renderer.requests.last?.text, try source.sourceIndex.text(in: fragment.sourceRange))
        let chapters = try await store.chapters(for: bookID)
        XCTAssertEqual(chapters.first?.title, "人工目录名")
        XCTAssertEqual(chapters.first?.sourceID, source.sourceID)
    }

    @MainActor
    func testProductionUsesPreparedTextForBothInitialAndSingleFragmentRender() async throws {
        let (store, production, renderer, bookID, chapter) = try await makePreparedFixture()
        let source = try await store.sourceIndex(for: bookID)
        try await production.start(bookID: bookID, chapterIDs: [chapter.id])
        let fragments = try await store.fragments(for: bookID, chapterID: chapter.id)
        let expected = try fragments.map { try source.text(in: $0.sourceRange) }
        XCTAssertEqual(renderer.requests.map(\.text), expected)
        XCTAssertTrue(expected.joined().contains("老監生"))
        XCTAssertTrue(expected.joined().contains("寒暄"))
        let fragment = try XCTUnwrap(fragments.first)
        try await production.regenerateFragment(bookID: bookID, chapterID: chapter.id, fragmentID: fragment.id)
        XCTAssertEqual(renderer.requests.last?.text, try source.text(in: fragment.sourceRange))
    }

    @MainActor
    func testReferenceSourceBlocksNewProductionAndPreservesExistingAudio() async throws {
        let (store, production, _, bookID, chapter) = try await makePreparedFixture()
        try await production.start(bookID: bookID, chapterIDs: [chapter.id])
        let candidates = try await store.candidates(for: bookID)
        XCTAssertFalse(candidates.isEmpty)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(tempRoot.appendingPathComponent("library.sqlite3").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "UPDATE sources SET source_kind = 'reference' WHERE id = '\(chapter.sourceID)';", nil, nil, nil), SQLITE_OK)
        do { try await production.start(bookID: bookID, chapterIDs: [chapter.id]); XCTFail("Reference text accepted") }
        catch { XCTAssertEqual(error as? AudiobookStoreError, .workingTextPreparationRequired) }
        let preserved = try await store.candidates(for: bookID)
        XCTAssertEqual(preserved, candidates)
        for candidate in preserved { let valid = try await store.verifyCandidateAsset(candidate); XCTAssertTrue(valid) }
    }

    private actor FetchCounter {
        var count = 0
        func next() -> Int { count += 1; return count }
    }

    @MainActor
    func testSourceSwitchBeforeRenderReleasesCreationAdmission() async throws {
        let admission = SpeechCreationAdmission()
        let (store, production, renderer, bookID, chapter) = try await makePreparedFixture(admission: admission)
        let counter = FetchCounter()
        renderer.onCapabilitiesFetch = {
            if await counter.next() == 2 {
                _ = try await store.prepareWorkingRevision(bookID: bookID, expectedSourceID: chapter.sourceID)
            }
        }
        do { try await production.start(bookID: bookID, chapterIDs: [chapter.id]); XCTFail("Stale run accepted") } catch {}
        XCTAssertTrue(renderer.requests.isEmpty)
        XCTAssertTrue(admission.acquire(.audiobook))
        admission.release(.audiobook)
    }

    @MainActor
    func testLateRenderCannotCommitAcrossWorkingRevision() async throws {
        let (store, production, renderer, bookID, chapter) = try await makePreparedFixture()
        renderer.onRenderStart = { _ in
            _ = try await store.prepareWorkingRevision(bookID: bookID, expectedSourceID: chapter.sourceID)
        }
        do { try await production.start(bookID: bookID, chapterIDs: [chapter.id]); XCTFail("Stale render accepted") }
        catch { XCTAssertEqual(error as? AudiobookStoreError, .workingSourceChanged) }
        let candidates = try await store.candidates(for: bookID)
        XCTAssertTrue(candidates.isEmpty)
        let book = try await store.book(id: bookID)
        XCTAssertEqual(book.analysisState, .notStarted)
        XCTAssertEqual(book.productionState, .idle)
    }

    @MainActor
    func testResumeRejectsCheckpointFromDifferentPreparedSource() async throws {
        let (store, production, _, bookID, chapter) = try await makePreparedFixture()
        try await production.start(bookID: bookID, chapterIDs: [chapter.id])
        let checkpointValue = try await store.productionCheckpoint(for: bookID)
        let checkpoint = try XCTUnwrap(checkpointValue)
        XCTAssertEqual(checkpoint.sourceID, chapter.sourceID)
        XCTAssertEqual(checkpoint.preparationVersion, AudiobookTextPreparation.version)
        _ = try await store.prepareWorkingRevision(bookID: bookID, expectedSourceID: chapter.sourceID)
        do {
            try await production.start(bookID: bookID, chapterIDs: [chapter.id], resumingTaskID: checkpoint.taskID)
            XCTFail("Stale checkpoint resumed")
        } catch { XCTAssertEqual(error as? AudiobookStoreError, .workingSourceChanged) }
    }

    @MainActor
    func testHistoricalAudioRemainsPlayableAndCandidatesAreIsolatedAfterPreparation() async throws {
        let (store, production, _, bookID, chapter) = try await makePreparedFixture()
        try await production.start(bookID: bookID, chapterIDs: [chapter.id])
        let revisionController = AudiobookRevisionController(store: store)
        let before = try await revisionController.currentChapter(bookID: bookID, chapterID: chapter.id)
        let candidates = try await store.candidates(for: bookID)
        _ = try await store.prepareWorkingRevision(bookID: bookID, expectedSourceID: chapter.sourceID)
        let preparedBook = try await store.book(id: bookID)
        XCTAssertEqual(preparedBook.listenableState, .previousRevisionAvailable)
        let history = try await revisionController.previousListenableChapter(bookID: bookID, chapterID: chapter.id)
        XCTAssertEqual(history, before)
        for candidate in candidates {
            let valid = try await store.verifyCandidateAsset(candidate)
            XCTAssertTrue(valid)
        }
        let working = try await store.workingSourceSnapshot(bookID: bookID)
        try await store.trashBook(id: bookID)
        try await store.restoreTrashedBook(id: bookID)
        let restored = try await store.workingSourceSnapshot(bookID: bookID)
        XCTAssertEqual(restored, working)
        let restoredHistory = try await revisionController.previousListenableChapter(bookID: bookID, chapterID: chapter.id)
        XCTAssertEqual(restoredHistory, before)
        let plan = try await revisionController.resumePlan(bookID: bookID)
        XCTAssertTrue(plan.reusableFragmentIDs.isEmpty)
        let roles = try await store.characters(for: bookID)
        let bindings = try await store.voiceBindings(for: bookID)
        let annotations = try await store.annotations(for: bookID)
        XCTAssertEqual(roles.count, 1)
        XCTAssertTrue(bindings.isEmpty)
        XCTAssertTrue(annotations.isEmpty)
    }

    @MainActor
    func testSkippedChapterIsExcludedFromReadinessAndProduction() async throws {
        let store = try AudiobookProjectStore(root: tempRoot), catalog = VoiceCatalogStore()
        let snapshot = Self.makeDefaultCapabilities()
        let renderer = ScriptedSpeechRenderer(capabilities: snapshot)
        let cast = AudiobookCastController(store: store, capabilityProvider: { snapshot }, voiceCatalog: catalog)
        let preview = try await AudiobookTXTImporter.prepare(
            rawData: Data("第一章 渡口\n夜色深沉。\n第二章 归途\n钟声响起。\n".utf8),
            suggestedTitle: "跳过章节夹具"
        )
        let bookID = try await store.importBook(preview)
        let chapters = try await store.chapters(for: bookID)
        XCTAssertEqual(chapters.count, 2)
        let skipped = chapters[1]
        try await store.setChapterSkipped(bookID: bookID, chapterID: skipped.id, skipped: true)

        let reloaded = try await store.chapters(for: bookID)
        XCTAssertTrue(reloaded.first(where: { $0.id == skipped.id })?.isSkipped == true)
        XCTAssertFalse(reloaded.first(where: { $0.id == chapters[0].id })?.isSkipped == true)

        var book = try await store.book(id: bookID)
        book.analysisState = .allWindowsValidated
        try await store.updateBook(book)

        let characters = try await store.characters(for: bookID)
        let narrator = try XCTUnwrap(characters.first)
        try await cast.bindVoice(
            bookID: bookID, roleID: narrator.id,
            binding: AudiobookVoiceBinding(
                roleID: narrator.id, voiceID: "v-narrator",
                voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                modelRevision: String(repeating: "a", count: 40)
            )
        )
        try await cast.confirmCast(bookID: bookID, revisionID: cast.currentCastRevisionID(for: bookID))
        try await cast.confirmAudition(bookID: bookID, voiceSetDigest: cast.currentVoiceSetDigest(for: bookID))

        let readiness = try await cast.chapterReadinessMap(for: bookID)
        XCTAssertEqual(readiness[skipped.id], .skipped)

        let production = AudiobookProductionController(
            store: store, castController: cast, revisionController: AudiobookRevisionController(store: store),
            renderer: renderer, admission: SpeechCreationAdmission(),
            clock: FakeAudiobookClock(), voiceCatalog: catalog
        )
        do {
            try await production.start(bookID: bookID, chapterIDs: [skipped.id])
            XCTFail("跳过的章节不应开始制作")
        } catch let error as AudiobookProductionError {
            XCTAssertEqual(error, .noReadyChaptersSelected)
        }
        XCTAssertTrue(renderer.requests.isEmpty)

        try await store.setChapterSkipped(bookID: bookID, chapterID: skipped.id, skipped: false)
        let restored = try await cast.chapterReadinessMap(for: bookID)
        XCTAssertNotEqual(restored[skipped.id], .skipped)
    }

    @MainActor
    func testProductionPinsPronunciationSetAndInvalidatesMatchingFragments() async throws {
        let store = try AudiobookProjectStore(root: tempRoot), catalog = VoiceCatalogStore()
        let snapshot = Self.makeDefaultCapabilities()
        let renderer = ScriptedSpeechRenderer(capabilities: snapshot)
        let cast = AudiobookCastController(store: store, capabilityProvider: { snapshot }, voiceCatalog: catalog)
        let preview = try await AudiobookTXTImporter.prepare(
            rawData: Data("第一章 渡口\n夜色深沉。\n钟声响起。\n".utf8),
            suggestedTitle: "发音规则夹具"
        )
        let bookID = try await store.importBook(preview)
        let chapter = try await store.chapters(for: bookID)[0]
        let roles = try await store.characters(for: bookID)
        let narrator = try XCTUnwrap(roles.first)
        let atoms = try await store.atoms(for: bookID, chapterID: chapter.id)
        let annotations = atoms.filter { $0.kind != .formatting }.map { atom in
            AudiobookAnnotation(
                bookID: bookID, chapterID: chapter.id, windowID: UUID(), atomID: atom.id,
                sourceRange: atom.sourceRange, assignment: .assigned(roleID: narrator.id)
            )
        }
        try await store.saveAnnotations(bookID: bookID, annotations: annotations)
        var book = try await store.book(id: bookID)
        book.analysisState = .allWindowsValidated
        try await store.updateBook(book)
        try await cast.bindVoice(
            bookID: bookID, roleID: narrator.id,
            binding: AudiobookVoiceBinding(
                roleID: narrator.id, voiceID: "v-narrator",
                voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                modelRevision: String(repeating: "a", count: 40)
            )
        )
        try await cast.confirmCast(bookID: bookID, revisionID: cast.currentCastRevisionID(for: bookID))
        try await cast.confirmAudition(bookID: bookID, voiceSetDigest: cast.currentVoiceSetDigest(for: bookID))

        let binding = AudiobookPronunciationBinding(
            setID: AudiobookPronunciationBinding.makeSetID(bookID: bookID),
            revision: "pr_1",
            entries: [PronunciationEntry(id: "e1", surface: "钟声", spoken: "zhōng shēng")]
        )
        try await store.savePronunciationBinding(binding, bookID: bookID)

        let bindings = try await store.voiceBindings(for: bookID)
        let source = try await store.sourceIndex(for: bookID)
        let withoutRules = try AudiobookFragmentPlanner.plan(
            chapter: chapter, annotations: annotations, bindings: bindings, source: source, atoms: atoms
        )
        let withRules = try AudiobookFragmentPlanner.plan(
            chapter: chapter, annotations: annotations, bindings: bindings, source: source,
            atoms: atoms, pronunciation: binding
        )
        XCTAssertNotEqual(
            withoutRules.map(\.dependencyDigest), withRules.map(\.dependencyDigest),
            "命中发音规则的片段必须进入待重做状态"
        )

        let production = AudiobookProductionController(
            store: store, castController: cast, revisionController: AudiobookRevisionController(store: store),
            renderer: renderer, admission: SpeechCreationAdmission(),
            clock: FakeAudiobookClock(), voiceCatalog: catalog
        )
        try await production.start(bookID: bookID, chapterIDs: [chapter.id])

        XCTAssertFalse(renderer.requests.isEmpty)
        XCTAssertTrue(renderer.requests.allSatisfy { $0.pronunciationSet == binding.headerValue })
        let saved = try await store.fragments(for: bookID, chapterID: chapter.id)
        XCTAssertEqual(saved.map(\.dependencyDigest), withRules.map(\.dependencyDigest))

        // 改读法后重录：新的 revision 必须进入请求，且不能复用旧依赖的候选。
        let updated = AudiobookPronunciationBinding(
            setID: binding.setID, revision: "pr_2",
            entries: [PronunciationEntry(id: "e1", surface: "钟声", spoken: "zhòng shēng")]
        )
        try await store.savePronunciationBinding(updated, bookID: bookID)
        let countBefore = renderer.requests.count
        try await production.regenerateFragment(bookID: bookID, chapterID: chapter.id, fragmentID: saved[0].id)
        XCTAssertEqual(renderer.requests.count, countBefore + 1)
        XCTAssertEqual(renderer.requests.last?.pronunciationSet, updated.headerValue)
    }

    @MainActor
    func testArchiveDuringRenderKeepsCandidateForReviewAndStopsNewRequests() async throws {
        let store = try AudiobookProjectStore(root: tempRoot), catalog = VoiceCatalogStore()
        let snapshot = Self.makeDefaultCapabilities()
        let renderer = ScriptedSpeechRenderer(capabilities: snapshot)
        let cast = AudiobookCastController(store: store, capabilityProvider: { snapshot }, voiceCatalog: catalog)
        let preview = try await AudiobookTXTImporter.prepare(rawData: Data("第一章 渡口\n夜色深沉。\n钟声响起。\n".utf8), suggestedTitle: "夹具")
        let bookID = try await store.importBook(preview), chapter = try await store.chapters(for: bookID)[0]
        var roles = try await store.characters(for: bookID)
        let narrator = try XCTUnwrap(roles.first), hero = AudiobookCharacter(bookID: bookID, displayName: "甲", isMajor: true)
        roles.append(hero); try await store.saveCharacters(bookID: bookID, characters: roles)
        let atoms = try await store.atoms(for: bookID, chapterID: chapter.id).filter { $0.kind != .formatting }
        try await store.saveAnnotations(bookID: bookID, annotations: atoms.enumerated().map { i, atom in
            AudiobookAnnotation(bookID: bookID, chapterID: chapter.id, windowID: UUID(), atomID: atom.id, sourceRange: atom.sourceRange,
                assignment: .assigned(roleID: i == atoms.count - 1 ? hero.id : narrator.id))
        })
        var book = try await store.book(id: bookID); book.analysisState = .allWindowsValidated
        try await store.updateBook(book)
        _ = try await cast.bindVoicesBatch(bookID: bookID, bindings: [
            .init(roleID: narrator.id, voiceID: "v-narrator", voiceRevision: "vr_0123456789abcdef0123456789abcdef", modelRevision: String(repeating: "a", count: 40)),
            .init(roleID: hero.id, voiceID: "v-hero", voiceRevision: "vr_1123456789abcdef0123456789abcdef", modelRevision: String(repeating: "a", count: 40))
        ])
        try await cast.confirmCast(bookID: bookID, revisionID: cast.currentCastRevisionID(for: bookID))
        try await cast.confirmAudition(bookID: bookID, voiceSetDigest: cast.currentVoiceSetDigest(for: bookID))
        let previous = AudiobookChapterRevision(bookID: bookID, chapterID: chapter.id, sourceID: chapter.sourceID, revisionNumber: 1, orderedBindings: [], totalFrameCount: 0)
        try await store.saveChapterRevision(previous, makeCurrent: true)
        renderer.onRenderStart = { request in do { try await catalog.archiveVoices(voiceIDs: [request.voiceID]) } catch { XCTFail("临时目录归档失败") } }
        let production = AudiobookProductionController(store: store, castController: cast,
            revisionController: AudiobookRevisionController(store: store), renderer: renderer,
            admission: SpeechCreationAdmission(), clock: FakeAudiobookClock(), voiceCatalog: catalog)
        do { try await production.start(bookID: bookID, chapterIDs: [chapter.id]); XCTFail("archive must stop further rendering") }
        catch let error as AudiobookProductionError { guard case .capabilityVoiceUnavailable = error else { return XCTFail("Unexpected: \(error)") } }
        XCTAssertEqual(renderer.requests.count, 1)
        let candidates = try await store.candidates(for: bookID)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertFalse(try XCTUnwrap(candidates.first).isReceiptVerified)
        let assetIntact = try await store.verifyCandidateAsset(try XCTUnwrap(candidates.first))
        XCTAssertTrue(assetIntact)
        let saved = try await store.chapters(for: bookID)[0]
        XCTAssertEqual(saved.currentChapterRevisionID, previous.id)
    }

    @MainActor
    func testFormerlySilentRoleMustRecheckExclusivePolicyBeforeProduction() async throws {
        let store = try AudiobookProjectStore(root: tempRoot), snapshot = Self.makeDefaultCapabilities()
        let cast = AudiobookCastController(store: store, capabilityProvider: { snapshot })
        let renderer = ScriptedSpeechRenderer(capabilities: snapshot)
        let preview = try AudiobookTXTImporter.prepare(rawData: Data("第一章 渡口\n夜色深沉。\n钟声响起。\n".utf8))
        let bookID = try await store.importBook(preview), chapter = try await store.chapters(for: bookID)[0]
        var roles = try await store.characters(for: bookID)
        let narrator = try XCTUnwrap(roles.first), silent = AudiobookCharacter(bookID: bookID, displayName: "甲", isMajor: true)
        roles.append(silent); try await store.saveCharacters(bookID: bookID, characters: roles)
        let atoms = try await store.atoms(for: bookID, chapterID: chapter.id).filter { $0.kind != .formatting }
        var anns = atoms.map { AudiobookAnnotation(bookID: bookID, chapterID: chapter.id, windowID: UUID(), atomID: $0.id,
            sourceRange: $0.sourceRange, assignment: .assigned(roleID: narrator.id)) }
        try await store.saveAnnotations(bookID: bookID, annotations: anns)
        var book = try await store.book(id: bookID); book.analysisState = .allWindowsValidated; try await store.updateBook(book)
        let binding = AudiobookVoiceBinding(roleID: silent.id, voiceID: "v-narrator", voiceRevision: "vr_0123456789abcdef0123456789abcdef", modelRevision: String(repeating: "a", count: 40))
        try await store.saveVoiceBinding(bookID: bookID, binding: binding)
        try await cast.bindVoice(bookID: bookID, roleID: narrator.id, binding: .init(roleID: narrator.id, voiceID: binding.voiceID, voiceRevision: binding.voiceRevision, modelRevision: binding.modelRevision))
        try await cast.confirmCast(bookID: bookID, revisionID: cast.currentCastRevisionID(for: bookID))
        try await cast.confirmAudition(bookID: bookID, voiceSetDigest: cast.currentVoiceSetDigest(for: bookID))
        anns[anns.count - 1].assignment = .assigned(roleID: silent.id)
        try await store.saveAnnotations(bookID: bookID, annotations: anns)
        let production = AudiobookProductionController(store: store, castController: cast,
            revisionController: AudiobookRevisionController(store: store), renderer: renderer,
            admission: SpeechCreationAdmission(), clock: FakeAudiobookClock())
        do { try await production.start(bookID: bookID, chapterIDs: [chapter.id]); XCTFail("新发声角色的独占冲突必须阻断") }
        catch let error as AudiobookCastError { guard case .duplicateVoiceRequiresSharedMinorConsent = error else { return XCTFail("Unexpected: \(error)") } }
        XCTAssertTrue(renderer.requests.isEmpty)
    }

    private func wavSampleRate(_ wav: Data) -> Int {
        guard wav.count >= 28 else { return 0 }
        return Int(wav[24])
            | (Int(wav[25]) << 8)
            | (Int(wav[26]) << 16)
            | (Int(wav[27]) << 24)
    }

    @MainActor
    func testPreparationPublishesProgressBeforeCapabilitiesReturn() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let cast = AudiobookCastController(store: store, capabilityProvider: { Self.makeDefaultCapabilities() })
        let renderer = ScriptedSpeechRenderer(capabilities: Self.makeDefaultCapabilities())
        let fetching = AsyncGate()
        let allowFetch = AsyncGate()
        renderer.onCapabilitiesFetch = {
            await fetching.open()
            await allowFetch.wait()
        }
        let url = tempRoot.appendingPathComponent("visible-preparation.txt")
        try Data("第一章 准备\n风吹过港口。\n".utf8).write(to: url)
        let preview = try await AudiobookTXTImporter.prepare(fileURL: url, encoding: .utf8)
        let bookID = try await store.importBook(preview)
        let chapter = try await store.chapters(for: bookID)[0]
        let narrator = try await store.characters(for: bookID)[0]
        var book = try await store.book(id: bookID)
        book.analysisState = .allWindowsValidated
        try await store.updateBook(book)
        let atoms = try await store.atoms(for: bookID, chapterID: chapter.id).filter { $0.kind != .formatting }
        try await store.saveAnnotations(bookID: bookID, annotations: atoms.map {
            AudiobookAnnotation(bookID: bookID, chapterID: chapter.id, windowID: UUID(),
                               atomID: $0.id, sourceRange: $0.sourceRange, assignment: .assigned(roleID: narrator.id))
        })
        try await cast.bindVoice(bookID: bookID, roleID: narrator.id, binding: .init(
            roleID: narrator.id, voiceID: "v-narrator", voiceRevision: "vr_0123456789abcdef0123456789abcdef", modelRevision: String(repeating: "a", count: 40)
        ))
        let castRevision = try await cast.currentCastRevisionID(for: bookID)
        try await cast.confirmCast(bookID: bookID, revisionID: castRevision)
        let voiceDigest = try await cast.currentVoiceSetDigest(for: bookID)
        try await cast.confirmAudition(bookID: bookID, voiceSetDigest: voiceDigest)
        let production = AudiobookProductionController(
            store: store, castController: cast, revisionController: AudiobookRevisionController(store: store),
            renderer: renderer, admission: SpeechCreationAdmission()
        )
        let task = Task { try await production.start(bookID: bookID, chapterIDs: [chapter.id]) }
        await fetching.wait()
        let progress = await production.progress(for: bookID)
        XCTAssertNotNil(progress, "等待能力检查时也必须有进度，不能直到第一段合成才出现")
        XCTAssertEqual(progress?.state, .running)
        XCTAssertEqual(progress?.phase, .preparing)
        XCTAssertGreaterThan(progress?.totalFragments ?? 0, 0)
        let checkpointBeforeRendering = try await store.productionCheckpoint(for: bookID)
        XCTAssertEqual(checkpointBeforeRendering?.chapterIDs, [chapter.id])
        XCTAssertEqual(checkpointBeforeRendering?.progress.totalFragments, progress?.totalFragments)
        await allowFetch.open()
        try await task.value
        let reopened = try AudiobookProjectStore(root: tempRoot)
        let saved = try await reopened.productionCheckpoint(for: bookID)
        XCTAssertEqual(saved?.progress.phase, .completed)
        XCTAssertEqual(saved?.progress.fraction, 1)
    }

    @MainActor
    func testPauseAfterCompletionCommitKeepsCompletedState() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let cast = AudiobookCastController(store: store, capabilityProvider: { Self.makeDefaultCapabilities() })
        let renderer = ScriptedSpeechRenderer(capabilities: Self.makeDefaultCapabilities())
        let completionCommitted = AsyncGate()
        let allowCommitToReturn = AsyncGate()
        let production = AudiobookProductionController(
            store: store, castController: cast, revisionController: AudiobookRevisionController(store: store),
            renderer: renderer, admission: SpeechCreationAdmission(),
            candidateCommitter: { candidate, wav in
                try await store.commitCandidate(candidate, wav: wav)
            },
            completionCommitter: { checkpoint, listenableState in
                try await store.saveProductionCheckpoint(checkpoint, listenableState: listenableState)
                await completionCommitted.open()
                await allowCommitToReturn.wait()
            }
        )
        let url = tempRoot.appendingPathComponent("completed-commit-pause.txt")
        try Data("第一章 渡口\n风吹过港口。\n".utf8).write(to: url)
        let preview = try await AudiobookTXTImporter.prepare(fileURL: url, encoding: .utf8)
        let bookID = try await store.importBook(preview)
        let chapter = try await store.chapters(for: bookID)[0]
        let narrator = try await store.characters(for: bookID)[0]
        var book = try await store.book(id: bookID)
        book.analysisState = .allWindowsValidated
        try await store.updateBook(book)
        let atoms = try await store.atoms(for: bookID, chapterID: chapter.id).filter { $0.kind != .formatting }
        try await store.saveAnnotations(bookID: bookID, annotations: atoms.map {
            AudiobookAnnotation(bookID: bookID, chapterID: chapter.id, windowID: UUID(),
                               atomID: $0.id, sourceRange: $0.sourceRange, assignment: .assigned(roleID: narrator.id))
        })
        try await cast.bindVoice(bookID: bookID, roleID: narrator.id, binding: .init(
            roleID: narrator.id, voiceID: "v-narrator", voiceRevision: "vr_0123456789abcdef0123456789abcdef", modelRevision: String(repeating: "a", count: 40)
        ))
        let castRevision = try await cast.currentCastRevisionID(for: bookID)
        try await cast.confirmCast(bookID: bookID, revisionID: castRevision)
        let voiceDigest = try await cast.currentVoiceSetDigest(for: bookID)
        try await cast.confirmAudition(bookID: bookID, voiceSetDigest: voiceDigest)

        let task = Task { try await production.start(bookID: bookID, chapterIDs: [chapter.id]) }
        await completionCommitted.wait()
        let committedBook = try await store.book(id: bookID)
        XCTAssertEqual(committedBook.productionState, .fullBookProduced)
        let progressBeforeSaveReturns = await production.progress(for: bookID)
        XCTAssertEqual(progressBeforeSaveReturns?.state, .running)
        XCTAssertNotEqual(progressBeforeSaveReturns?.phase, .completed,
                          "控制器只在最终保存成功返回后发布完成进度")
        // Workflow cancels its parent task before asking the controller to pause.
        task.cancel()
        await production.pause()
        await allowCommitToReturn.open()
        do {
            try await task.value
        } catch {
            XCTFail("完成事务已提交，迟到的暂停不应把成功返回改成暂停：\(error)")
        }

        let finalBook = try await store.book(id: bookID)
        let checkpoint = try await store.productionCheckpoint(for: bookID)
        let finalProgress = await production.progress(for: bookID)
        XCTAssertEqual(finalBook.productionState, .fullBookProduced)
        XCTAssertEqual(finalBook.listenableState, .fullBookListenable)
        XCTAssertEqual(checkpoint?.progress.state, .fullBookProduced)
        XCTAssertEqual(checkpoint?.progress.phase, .completed)
        XCTAssertEqual(finalProgress?.state, .fullBookProduced)
        XCTAssertEqual(finalProgress?.phase, .completed)
    }

    func testProgressUsesSavedAudioCountsAndStopsElapsedTimeWhenPaused() {
        let start = Date(timeIntervalSince1970: 100)
        var progress = AudiobookProductionProgress(
            bookID: UUID(), state: .running, completedFragments: 3, totalFragments: 8,
            phase: .rendering, startedAt: start, updatedAt: start.addingTimeInterval(10)
        )
        XCTAssertEqual(progress.fraction, 0.375)
        XCTAssertEqual(progress.savedFragmentsText, "已保存 3/8 段")
        XCTAssertFalse(progress.isStalled(at: start.addingTimeInterval(69)))
        XCTAssertTrue(progress.isStalled(at: start.addingTimeInterval(70)))
        XCTAssertEqual(progress.elapsedSeconds(at: start.addingTimeInterval(80)), 80)
        progress.state = .paused
        XCTAssertEqual(progress.statusTitle, "制作已暂停")
        XCTAssertEqual(progress.elapsedSeconds(at: start.addingTimeInterval(800)), 10)
        XCTAssertFalse(progress.isStalled(at: start.addingTimeInterval(800)))
        progress.totalFragments = 0
        XCTAssertEqual(progress.fraction, 0)
        XCTAssertEqual(progress.savedFragmentsText, "正在确认本次制作范围")
    }

    @MainActor
    func testFormalRenderRequiresAnalysisCastAuditionAndChapterReadiness() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let castController = AudiobookCastController(store: store, capabilityProvider: { Self.makeDefaultCapabilities() })
        let revisionController = AudiobookRevisionController(store: store)
        let admission = SpeechCreationAdmission()
        let renderer = ScriptedSpeechRenderer(capabilities: Self.makeDefaultCapabilities())
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
            binding: AudiobookVoiceBinding(roleID: narrator.id, voiceID: "v-narrator", voiceRevision: "vr_0123456789abcdef0123456789abcdef", modelRevision: String(repeating: "a", count: 40))
        )
        try await castController.bindVoice(
            bookID: bookID,
            roleID: hero.id,
            binding: AudiobookVoiceBinding(roleID: hero.id, voiceID: "v-hero", voiceRevision: "vr_1123456789abcdef0123456789abcdef", modelRevision: String(repeating: "a", count: 40))
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
        XCTAssertEqual(renderer.requests[0].expectedVoiceRevision, "vr_0123456789abcdef0123456789abcdef")
        XCTAssertEqual(renderer.requests[0].speed, 1.0)
        XCTAssertEqual(renderer.requests[1].voiceID, "v-hero")
        XCTAssertFalse(admission.isBusy)

        let finalBook = try await store.book(id: bookID)
        XCTAssertEqual(finalBook.productionState, .fullBookProduced)
        XCTAssertEqual(finalBook.listenableState, .fullBookListenable)

        let fragments = try await store.fragments(for: bookID, chapterID: chapter.id)
        let heroFragment = try XCTUnwrap(fragments.first { $0.roleID == hero.id })
        let originalChapter = try await store.chapters(for: bookID)[0]
        let originalRevisionID = try XCTUnwrap(originalChapter.currentChapterRevisionID)
        let originalCandidates = try await store.candidates(for: bookID)

        try await production.regenerateFragment(bookID: bookID, chapterID: chapter.id, fragmentID: heroFragment.id)

        XCTAssertEqual(renderer.requests.count, 3, "重录必须生成一个新候选，不能直接复用相同依赖的旧音频")
        XCTAssertEqual(renderer.requests.last?.voiceID, "v-hero", "只重录目标角色片段")
        let repairedCandidates = try await store.candidates(for: bookID)
        XCTAssertEqual(repairedCandidates.count, originalCandidates.count + 1)
        XCTAssertEqual(repairedCandidates.filter { $0.fragmentID == heroFragment.id }.count, 2)
        let chapterAfterRepair = try await store.chapters(for: bookID)[0]
        XCTAssertEqual(chapterAfterRepair.currentChapterRevisionID, originalRevisionID,
                       "新候选必须由用户显式采用，重录本身不切换章节版本")
        for original in originalCandidates {
            let assetPreserved = try await store.verifyCandidateAsset(original)
            XCTAssertTrue(assetPreserved)
        }

        do {
            try await production.regenerateFragment(bookID: bookID, chapterID: chapter.id, fragmentID: UUID())
            XCTFail("无效片段不能退化为整章制作")
        } catch let error as AudiobookRevisionError {
            guard case .fragmentNotFound = error else { return XCTFail("应拒绝无效片段，实际为：\(error)") }
        }
        XCTAssertEqual(renderer.requests.count, 3)

        await production.shutdown()
        let bookAfterShutdown = try await store.book(id: bookID)
        XCTAssertEqual(bookAfterShutdown.productionState, .fullBookProduced,
                       "无进行中任务时关闭制作器不得把已完成书籍改为暂停")
    }

    @MainActor
    func testPauseWaitsForInFlightAndRejectsLateCommit() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let castController = AudiobookCastController(store: store, capabilityProvider: { Self.makeDefaultCapabilities() })
        let revisionController = AudiobookRevisionController(store: store)
        let admission = SpeechCreationAdmission()
        let renderer = ScriptedSpeechRenderer(capabilities: Self.makeDefaultCapabilities())
        let clock = FakeAudiobookClock()
        let candidateCommitted = AsyncGate()
        let allowCommitToReturn = AsyncGate()
        let production = AudiobookProductionController(
            store: store,
            castController: castController,
            revisionController: revisionController,
            renderer: renderer,
            admission: admission,
            clock: clock,
            candidateCommitter: { candidate, wav in
                try await store.commitCandidate(candidate, wav: wav)
                await candidateCommitted.open()
                await allowCommitToReturn.wait()
            }
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
            binding: AudiobookVoiceBinding(roleID: narrator.id, voiceID: "v-narrator", voiceRevision: "vr_0123456789abcdef0123456789abcdef", modelRevision: String(repeating: "a", count: 40))
        )
        let castRev = try await castController.currentCastRevisionID(for: bookID)
        try await castController.confirmCast(bookID: bookID, revisionID: castRev)
        let voiceDigest = try await castController.currentVoiceSetDigest(for: bookID)
        try await castController.confirmAudition(bookID: bookID, voiceSetDigest: voiceDigest)

        renderer.onRenderStart = { _ in
            let cancellationReceived = AsyncGate()
            Task {
                await production.pause()
            }
            await withTaskCancellationHandler {
                await cancellationReceived.wait()
            } onCancel: {
                Task { await cancellationReceived.open() }
            }
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

        let fragments = try await store.fragments(for: bookID, chapterID: chapter.id)
        let fragment = try XCTUnwrap(fragments.first)
        do {
            try await production.regenerateFragment(bookID: bookID, chapterID: chapter.id, fragmentID: fragment.id)
            XCTFail("重录也必须遵循暂停，不能提交迟到候选")
        } catch let error as AudiobookProductionError {
            XCTAssertEqual(error, .cancelled)
        }
        let candidatesAfterRepairPause = try await store.candidates(for: bookID)
        let chapterAfterRepairPause = try await store.chapters(for: bookID)[0]
        XCTAssertTrue(candidatesAfterRepairPause.isEmpty)
        XCTAssertNil(chapterAfterRepairPause.currentChapterRevisionID)
        XCTAssertFalse(admission.isBusy)

        // Pause after a real durable commit has succeeded, before its await returns.
        // The candidate is a valid recovery boundary; the old run must not report completion.
        renderer.onRenderStart = nil
        let repairTask = Task {
            do {
                try await production.regenerateFragment(bookID: bookID, chapterID: chapter.id, fragmentID: fragment.id)
            } catch {
                await candidateCommitted.open()
                throw error
            }
            await candidateCommitted.open()
        }
        await candidateCommitted.wait()
        await production.pause()
        await allowCommitToReturn.open()
        do {
            try await repairTask.value
            XCTFail("提交期间暂停后，旧重录任务不能继续报告完成")
        } catch let error as AudiobookProductionError {
            XCTAssertEqual(error, .cancelled)
        }
        let committedCandidates = try await store.candidates(for: bookID)
        let bookAfterCommitPause = try await store.book(id: bookID)
        let chapterAfterCommitPause = try await store.chapters(for: bookID)[0]
        XCTAssertEqual(committedCandidates.count, 1, "已提交的有效候选应保留供恢复和试听")
        XCTAssertEqual(bookAfterCommitPause.productionState, .paused)
        XCTAssertNil(chapterAfterCommitPause.currentChapterRevisionID)
        XCTAssertFalse(admission.isBusy)

        let checkpoint = try await store.productionCheckpoint(for: bookID)
        let savedTaskID = try XCTUnwrap(checkpoint?.taskID)
        let requestCountBeforeResume = renderer.requests.count
        try await production.regenerateFragment(bookID: bookID, chapterID: chapter.id,
                                               fragmentID: fragment.id, resumingTaskID: savedTaskID)
        XCTAssertEqual(renderer.requests.count, requestCountBeforeResume,
                       "提交边界暂停后，续作应复用本次重录已经保存的候选")
        let candidatesAfterResume = try await store.candidates(for: bookID)
        XCTAssertEqual(candidatesAfterResume.map(\.id), committedCandidates.map(\.id))
    }

    @MainActor
    func testConcurrentStartDoesNotInvalidateFirstRunOrLeakAdmission() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let castController = AudiobookCastController(store: store, capabilityProvider: { Self.makeDefaultCapabilities() })
        let revisionController = AudiobookRevisionController(store: store)
        let admission = SpeechCreationAdmission()
        let renderer = ScriptedSpeechRenderer(capabilities: Self.makeDefaultCapabilities())
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
                voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                modelRevision: String(repeating: "a", count: 40)
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

        do {
            let fragment = try await store.fragments(for: bookID, chapterID: chapter.id)[0]
            try await production.regenerateFragment(bookID: bookID, chapterID: chapter.id, fragmentID: fragment.id)
            XCTFail("正式制作期间不能并行重录片段")
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
        let castController = AudiobookCastController(store: store, capabilityProvider: { Self.makeDefaultCapabilities() })
        let revisionController = AudiobookRevisionController(store: store)
        let admission = SpeechCreationAdmission()
        let renderer = ScriptedSpeechRenderer(capabilities: Self.makeDefaultCapabilities())
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
                voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                modelRevision: String(repeating: "a", count: 40)
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
        let castController = AudiobookCastController(store: store, capabilityProvider: { Self.makeDefaultCapabilities() })
        let revisionController = AudiobookRevisionController(store: store)
        let admission = SpeechCreationAdmission()
        let renderer = ScriptedSpeechRenderer(
            capabilities: Self.makeDefaultCapabilities(),
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
                voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                modelRevision: String(repeating: "a", count: 40)
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
    func testRenderRetriesKeepFrozenParametersAndStrictPolicy() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let castController = AudiobookCastController(store: store, capabilityProvider: { Self.makeDefaultCapabilities() })
        let revisionController = AudiobookRevisionController(store: store)
        let admission = SpeechCreationAdmission()
        let renderer = ScriptedSpeechRenderer(capabilities: Self.makeDefaultCapabilities())
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
            binding: AudiobookVoiceBinding(roleID: narrator.id, voiceID: "v-narrator", voiceRevision: "vr_0123456789abcdef0123456789abcdef", modelRevision: String(repeating: "a", count: 40))
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
        XCTAssertTrue(renderer.requests.allSatisfy { $0 == renderer.requests.first })
        XCTAssertTrue(renderer.requests.allSatisfy { $0.voiceID == "v-narrator" && $0.expectedVoiceRevision == "vr_0123456789abcdef0123456789abcdef" })
        let before = renderer.requests.count
        let refusal = ServiceAPIClientError.http(statusCode: 400, code: "unsupported_parameter", message: "invalid", requestID: "fixture", retryable: false)
        renderer.scriptedErrors = [refusal]
        do { try await production.start(bookID: bookID, chapterIDs: [chapter.id]); XCTFail("deterministic refusal must stop") }
        catch { XCTAssertEqual(error as? ServiceAPIClientError, refusal) }
        XCTAssertEqual(renderer.requests.count - before, 1, "Only transient errors may be retried")
    }
}
