import Foundation
import SQLite3
import XCTest
import SpeechRailControlKit
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

final class AudiobookRevisionTests: XCTestCase {
    nonisolated(unsafe) private var tempRoot: URL!

    private struct DurableSnapshot: Equatable {
        let book: AudiobookBook
        let chapters: [AudiobookChapter]
        let chapterRevisions: [AudiobookChapterRevision]
        let productionRevisions: [AudiobookProductionRevision]
        let candidates: [AudiobookRenderCandidate]
        let voiceBindings: [UUID: AudiobookVoiceBinding]
        let fragments: [AudiobookFragment]
        let annotations: [AudiobookAnnotation]
    }

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
        store: AudiobookProjectStore,
        text: String = "第一章 渡口\n风声紧迫。\n“快上船！”林远喊道。\n"
    ) async throws -> (
        bookID: UUID,
        chapter: AudiobookChapter,
        fragments: [AudiobookFragment],
        narrator: AudiobookCharacter,
        hero: AudiobookCharacter
    ) {
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

    private func commitCandidate(
        store: AudiobookProjectStore,
        bookID: UUID,
        chapterID: UUID,
        fragment: AudiobookFragment,
        generation: Int,
        frameCount: Int,
        sampleValue: Int16
    ) async throws -> AudiobookRenderCandidate {
        let wav = makeWAV(frameCount: frameCount, sampleValue: sampleValue)
        let candidateID = UUID()
        let candidate = AudiobookRenderCandidate(
            id: candidateID,
            bookID: bookID,
            chapterID: chapterID,
            fragmentID: fragment.id,
            generation: generation,
            relativeAssetPath: "books/\(bookID.uuidString)/audio/\(candidateID.uuidString).wav",
            fileSHA256: AudiobookDigest.sha256Hex(wav),
            pcmSHA256: try AudioDigest.sha256HexOfPCM(in: wav),
            frameCount: Int64(frameCount),
            dependencyDigest: fragment.dependencyDigest
        )
        try await store.commitCandidate(candidate, wav: wav)
        return candidate
    }

    private func durableSnapshot(
        store: AudiobookProjectStore,
        bookID: UUID,
        chapterID: UUID
    ) async throws -> DurableSnapshot {
        let book = try await store.book(id: bookID)
        let chapters = try await store.chapters(for: bookID)
        guard chapters.contains(where: { $0.id == chapterID }) else {
            throw AudiobookStoreError.chapterNotFound(chapterID)
        }
        var chapterRevisions: [AudiobookChapterRevision] = []
        for chapter in chapters {
            chapterRevisions += try await store.chapterRevisions(for: bookID, chapterID: chapter.id)
        }
        let productionRevisions = try await store.productionRevisions(for: bookID)
        let candidates = try await store.candidates(for: bookID)
        let voiceBindings = try await store.voiceBindings(for: bookID)
        let fragments = try await store.fragments(for: bookID)
        let annotations = try await store.annotations(for: bookID)
        return DurableSnapshot(
            book: book,
            chapters: chapters,
            chapterRevisions: chapterRevisions,
            productionRevisions: productionRevisions,
            candidates: candidates,
            voiceBindings: voiceBindings,
            fragments: fragments,
            annotations: annotations
        )
    }

    private static func executeSQLite(_ sql: String, databaseURL: URL) throws {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed"
            if let database { sqlite3_close_v2(database) }
            throw NSError(
                domain: "AudiobookRevisionTests.SQLite",
                code: Int(openResult),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        defer { sqlite3_close_v2(database) }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        let message = errorMessage.map { String(cString: $0) }
        if let errorMessage { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else {
            throw NSError(
                domain: "AudiobookRevisionTests.SQLite",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: message ?? String(cString: sqlite3_errmsg(database))]
            )
        }
    }

    private static func installAbortTriggers(
        table: String,
        triggerPrefix: String,
        marker: String,
        predicate: String,
        operations: [String] = ["INSERT", "UPDATE"],
        databaseURL: URL
    ) throws {
        let sql = operations.map { operation in
            """
            CREATE TRIGGER \(triggerPrefix)_\(operation.lowercased())
            BEFORE \(operation) ON \(table)
            WHEN \(predicate)
            BEGIN
                SELECT RAISE(ABORT, '\(marker)');
            END;
            """
        }.joined(separator: "\n")
        try executeSQLite(sql, databaseURL: databaseURL)
    }

    private static func removeAbortTriggers(triggerPrefix: String, databaseURL: URL) throws {
        try executeSQLite(
            "DROP TRIGGER IF EXISTS \(triggerPrefix)_insert; DROP TRIGGER IF EXISTS \(triggerPrefix)_update;",
            databaseURL: databaseURL
        )
    }

    private func publishInitialVersion(
        store: AudiobookProjectStore,
        controller: AudiobookRevisionController,
        fixture: (bookID: UUID, chapter: AudiobookChapter, fragments: [AudiobookFragment], narrator: AudiobookCharacter, hero: AudiobookCharacter)
    ) async throws -> AudiobookChapterRevision {
        for (index, fragment) in fixture.fragments.enumerated() {
            _ = try await commitCandidate(
                store: store,
                bookID: fixture.bookID,
                chapterID: fixture.chapter.id,
                fragment: fragment,
                generation: 1,
                frameCount: 2_400 + index * 100,
                sampleValue: Int16(400 + index)
            )
        }
        let maybeRevision = try await controller.promoteInitialChapterIfComplete(
            bookID: fixture.bookID,
            chapterID: fixture.chapter.id
        )
        return try XCTUnwrap(maybeRevision)
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

    func testAdoptFaultAtProductionRevisionWriteRollsBackAndRetryPreservesHistory() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let controller = AudiobookRevisionController(store: store)
        let fixture = try await setupSingleChapterWithTwoFragments(store: store)
        let initialRevision = try await publishInitialVersion(store: store, controller: controller, fixture: fixture)
        let repairCandidate = try await commitCandidate(
            store: store,
            bookID: fixture.bookID,
            chapterID: fixture.chapter.id,
            fragment: fixture.fragments[0],
            generation: 2,
            frameCount: 3_600,
            sampleValue: 900
        )
        let beforeFailure = try await durableSnapshot(
            store: store,
            bookID: fixture.bookID,
            chapterID: fixture.chapter.id
        )
        let marker = "injected_adopt_production_revision_failure"
        let triggerPrefix = "inject_adopt_production_revision_fault"
        let databaseURL = tempRoot.appendingPathComponent("library.sqlite3")
        try Self.installAbortTriggers(
            table: "production_revisions",
            triggerPrefix: triggerPrefix,
            marker: marker,
            predicate: "NEW.book_id = '\(fixture.bookID.uuidString)'",
            databaseURL: databaseURL
        )
        defer { try? Self.removeAbortTriggers(triggerPrefix: triggerPrefix, databaseURL: databaseURL) }

        var injectedFailure: String?
        do {
            try await controller.adopt(
                bookID: fixture.bookID,
                candidateID: repairCandidate.id,
                expectedRevisionID: initialRevision.id
            )
            XCTFail("production_revisions 故障应使候选采用失败")
        } catch {
            injectedFailure = "\(String(describing: error)) \(error.localizedDescription)"
        }
        XCTAssertTrue(
            injectedFailure?.contains(marker) == true,
            "必须命中 production_revisions 注入点，实际错误：\(injectedFailure ?? "<none>")"
        )
        try Self.removeAbortTriggers(triggerPrefix: triggerPrefix, databaseURL: databaseURL)

        let afterFailure = try await durableSnapshot(store: store, bookID: fixture.bookID, chapterID: fixture.chapter.id)
        let reopenedStore = try AudiobookProjectStore(root: tempRoot)
        let reopenedAfterFailure = try await durableSnapshot(
            store: reopenedStore,
            bookID: fixture.bookID,
            chapterID: fixture.chapter.id
        )
        let failureStateIntact = afterFailure == beforeFailure && reopenedAfterFailure == beforeFailure
        XCTAssertEqual(afterFailure, beforeFailure, "同一 Store 中 book/chapters/revisions/candidates/bindings 应完整回滚")
        XCTAssertEqual(reopenedAfterFailure, beforeFailure, "重开数据库后持久化状态应完整回滚")
        guard failureStateIntact else { return }

        try await controller.adopt(
            bookID: fixture.bookID,
            candidateID: repairCandidate.id,
            expectedRevisionID: initialRevision.id
        )
        let afterRetry = try await durableSnapshot(store: store, bookID: fixture.bookID, chapterID: fixture.chapter.id)
        XCTAssertEqual(afterRetry.chapterRevisions.count, beforeFailure.chapterRevisions.count + 1)
        XCTAssertEqual(afterRetry.productionRevisions.count, beforeFailure.productionRevisions.count + 1)
        XCTAssertEqual(afterRetry.candidates, beforeFailure.candidates, "采用候选不应丢弃候选历史")
        XCTAssertEqual(afterRetry.voiceBindings, beforeFailure.voiceBindings)
        let chapterAfterRetry = try XCTUnwrap(afterRetry.chapters.first(where: { $0.id == fixture.chapter.id }))
        XCTAssertNotEqual(chapterAfterRetry.currentChapterRevisionID, initialRevision.id)
        XCTAssertEqual(chapterAfterRetry.previousChapterRevisionID, initialRevision.id)

        try await controller.undoAdoption(bookID: fixture.bookID, chapterID: fixture.chapter.id)
        let afterUndo = try await durableSnapshot(store: store, bookID: fixture.bookID, chapterID: fixture.chapter.id)
        let chapterAfterUndo = try XCTUnwrap(afterUndo.chapters.first(where: { $0.id == fixture.chapter.id }))
        XCTAssertEqual(chapterAfterUndo.currentChapterRevisionID, initialRevision.id)
        XCTAssertNil(chapterAfterUndo.previousChapterRevisionID, "撤销后不应留下可重做指针")
        XCTAssertEqual(afterUndo.chapterRevisions.count, afterRetry.chapterRevisions.count)
        XCTAssertEqual(afterUndo.candidates, beforeFailure.candidates)
        XCTAssertEqual(afterUndo.voiceBindings, beforeFailure.voiceBindings)

        var noRedoErrorReceived = false
        do {
            try await controller.undoAdoption(bookID: fixture.bookID, chapterID: fixture.chapter.id)
            XCTFail("撤销后的第二次 undo 应稳定拒绝")
        } catch let error as AudiobookRevisionError {
            noRedoErrorReceived = error == .noPreviousChapterRevisionToUndo(chapterID: fixture.chapter.id)
            XCTAssertEqual(error, .noPreviousChapterRevisionToUndo(chapterID: fixture.chapter.id))
        } catch {
            XCTFail("第二次 undo 返回了非预期错误：\(error)")
        }
        XCTAssertTrue(noRedoErrorReceived)
        let afterRejectedRedo = try await durableSnapshot(store: store, bookID: fixture.bookID, chapterID: fixture.chapter.id)
        XCTAssertEqual(afterRejectedRedo, afterUndo, "拒绝第二次 undo 不应改写任何版本历史")
    }

    func testUndoAdoptionFaultAtFinalBookStateWriteRollsBackAndRetryHasNoRedo() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let controller = AudiobookRevisionController(store: store)
        let fixture = try await setupSingleChapterWithTwoFragments(store: store)
        let initialRevision = try await publishInitialVersion(store: store, controller: controller, fixture: fixture)
        let repairCandidate = try await commitCandidate(
            store: store,
            bookID: fixture.bookID,
            chapterID: fixture.chapter.id,
            fragment: fixture.fragments[0],
            generation: 2,
            frameCount: 3_600,
            sampleValue: 910
        )
        try await controller.adopt(
            bookID: fixture.bookID,
            candidateID: repairCandidate.id,
            expectedRevisionID: initialRevision.id
        )

        // 让保存 production revision 的中间 books UPSERT 保持 running，故障只在最终状态切换时触发。
        var runningBook = try await store.book(id: fixture.bookID)
        runningBook.productionState = .running
        try await store.updateBook(runningBook)
        let beforeFailure = try await durableSnapshot(
            store: store,
            bookID: fixture.bookID,
            chapterID: fixture.chapter.id
        )
        let marker = "injected_undo_final_book_state_failure"
        let triggerPrefix = "inject_undo_final_book_fault"
        let databaseURL = tempRoot.appendingPathComponent("library.sqlite3")
        try Self.installAbortTriggers(
            table: "books",
            triggerPrefix: triggerPrefix,
            marker: marker,
            predicate: "NEW.id = '\(fixture.bookID.uuidString)' AND OLD.production_state = 'running' AND NEW.production_state = 'fullBookProduced'",
            operations: ["UPDATE"],
            databaseURL: databaseURL
        )
        defer { try? Self.removeAbortTriggers(triggerPrefix: triggerPrefix, databaseURL: databaseURL) }

        var injectedFailure: String?
        do {
            try await controller.undoAdoption(bookID: fixture.bookID, chapterID: fixture.chapter.id)
            XCTFail("最终 books 状态写入故障应使撤销采用失败")
        } catch {
            injectedFailure = "\(String(describing: error)) \(error.localizedDescription)"
        }
        XCTAssertTrue(
            injectedFailure?.contains(marker) == true,
            "必须命中最终 books 状态注入点，实际错误：\(injectedFailure ?? "<none>")"
        )
        try Self.removeAbortTriggers(triggerPrefix: triggerPrefix, databaseURL: databaseURL)

        let afterFailure = try await durableSnapshot(store: store, bookID: fixture.bookID, chapterID: fixture.chapter.id)
        let reopenedStore = try AudiobookProjectStore(root: tempRoot)
        let reopenedAfterFailure = try await durableSnapshot(
            store: reopenedStore,
            bookID: fixture.bookID,
            chapterID: fixture.chapter.id
        )
        let failureStateIntact = afterFailure == beforeFailure && reopenedAfterFailure == beforeFailure
        XCTAssertEqual(afterFailure, beforeFailure)
        XCTAssertEqual(reopenedAfterFailure, beforeFailure)
        guard failureStateIntact else { return }

        try await controller.undoAdoption(bookID: fixture.bookID, chapterID: fixture.chapter.id)
        let afterRetry = try await durableSnapshot(store: store, bookID: fixture.bookID, chapterID: fixture.chapter.id)
        let chapterAfterRetry = try XCTUnwrap(afterRetry.chapters.first(where: { $0.id == fixture.chapter.id }))
        XCTAssertEqual(chapterAfterRetry.currentChapterRevisionID, initialRevision.id)
        XCTAssertNil(chapterAfterRetry.previousChapterRevisionID, "重试成功的撤销必须清空 previous 指针")
        XCTAssertEqual(afterRetry.chapterRevisions.count, beforeFailure.chapterRevisions.count)
        XCTAssertEqual(afterRetry.productionRevisions.count, beforeFailure.productionRevisions.count + 1)
        XCTAssertEqual(afterRetry.candidates, beforeFailure.candidates)
        XCTAssertEqual(afterRetry.voiceBindings, beforeFailure.voiceBindings)

        var noRedoErrorReceived = false
        do {
            try await controller.undoAdoption(bookID: fixture.bookID, chapterID: fixture.chapter.id)
            XCTFail("撤销重试完成后再次 undo 应稳定拒绝")
        } catch let error as AudiobookRevisionError {
            noRedoErrorReceived = error == .noPreviousChapterRevisionToUndo(chapterID: fixture.chapter.id)
            XCTAssertEqual(error, .noPreviousChapterRevisionToUndo(chapterID: fixture.chapter.id))
        } catch {
            XCTFail("第二次 undo 返回了非预期错误：\(error)")
        }
        XCTAssertTrue(noRedoErrorReceived)
        let afterRejectedRedo = try await durableSnapshot(store: store, bookID: fixture.bookID, chapterID: fixture.chapter.id)
        XCTAssertEqual(afterRejectedRedo, afterRetry)
    }

    func testPromoteInitialFaultAtListenableStateWriteRollsBackAndRetryPreservesRunning() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let controller = AudiobookRevisionController(store: store)
        let fixture = try await setupSingleChapterWithTwoFragments(store: store)
        for (index, fragment) in fixture.fragments.enumerated() {
            _ = try await commitCandidate(
                store: store,
                bookID: fixture.bookID,
                chapterID: fixture.chapter.id,
                fragment: fragment,
                generation: 1,
                frameCount: 2_400 + index * 100,
                sampleValue: Int16(700 + index)
            )
        }
        // 重新规划的片段也必须随章节发布提交，不能由准备阶段提前写入。
        try await store.saveFragments(bookID: fixture.bookID, chapterID: fixture.chapter.id, fragments: [])
        var runningBook = try await store.book(id: fixture.bookID)
        runningBook.productionState = .running
        try await store.updateBook(runningBook)
        let beforeFailure = try await durableSnapshot(
            store: store,
            bookID: fixture.bookID,
            chapterID: fixture.chapter.id
        )
        let marker = "injected_promote_listenable_state_failure"
        let triggerPrefix = "inject_promote_listenable_state_fault"
        let databaseURL = tempRoot.appendingPathComponent("library.sqlite3")
        try Self.installAbortTriggers(
            table: "books",
            triggerPrefix: triggerPrefix,
            marker: marker,
            predicate: "NEW.id = '\(fixture.bookID.uuidString)' AND OLD.listenable_state = 'noneAvailable' AND NEW.listenable_state = 'fullBookListenable'",
            operations: ["UPDATE"],
            databaseURL: databaseURL
        )
        defer { try? Self.removeAbortTriggers(triggerPrefix: triggerPrefix, databaseURL: databaseURL) }

        var injectedFailure: String?
        do {
            _ = try await controller.promoteInitialChapterIfComplete(
                bookID: fixture.bookID,
                chapterID: fixture.chapter.id,
                updateBookProductionState: false
            )
            XCTFail("最终 listenable_state 写入故障应使初章发布失败")
        } catch {
            injectedFailure = "\(String(describing: error)) \(error.localizedDescription)"
        }
        XCTAssertTrue(
            injectedFailure?.contains(marker) == true,
            "必须命中最终 books.listenable_state 注入点，实际错误：\(injectedFailure ?? "<none>")"
        )
        try Self.removeAbortTriggers(triggerPrefix: triggerPrefix, databaseURL: databaseURL)

        let afterFailure = try await durableSnapshot(store: store, bookID: fixture.bookID, chapterID: fixture.chapter.id)
        let reopenedStore = try AudiobookProjectStore(root: tempRoot)
        let reopenedAfterFailure = try await durableSnapshot(
            store: reopenedStore,
            bookID: fixture.bookID,
            chapterID: fixture.chapter.id
        )
        let failureStateIntact = afterFailure == beforeFailure && reopenedAfterFailure == beforeFailure
        XCTAssertEqual(afterFailure, beforeFailure)
        XCTAssertEqual(reopenedAfterFailure, beforeFailure)
        guard failureStateIntact else { return }

        let retriedRevision = try await controller.promoteInitialChapterIfComplete(
            bookID: fixture.bookID,
            chapterID: fixture.chapter.id,
            updateBookProductionState: false
        )
        let afterRetry = try await durableSnapshot(store: store, bookID: fixture.bookID, chapterID: fixture.chapter.id)
        XCTAssertNotNil(retriedRevision)
        XCTAssertEqual(afterRetry.chapterRevisions.count, beforeFailure.chapterRevisions.count + 1)
        XCTAssertEqual(afterRetry.productionRevisions.count, beforeFailure.productionRevisions.count + 1)
        XCTAssertEqual(afterRetry.candidates, beforeFailure.candidates)
        XCTAssertEqual(afterRetry.voiceBindings, beforeFailure.voiceBindings)
        XCTAssertEqual(afterRetry.book.productionState, .running, "首次发布不能覆盖制作队列仍在运行的状态")
        XCTAssertEqual(afterRetry.book.listenableState, .fullBookListenable)
        let promotedChapter = try XCTUnwrap(afterRetry.chapters.first(where: { $0.id == fixture.chapter.id }))
        XCTAssertEqual(promotedChapter.currentChapterRevisionID, retriedRevision?.id)
        XCTAssertNil(promotedChapter.previousChapterRevisionID)
    }

    func testUndoAdoptionConsumesPreviousVersionWithoutRedo() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let controller = AudiobookRevisionController(store: store)
        let fixture = try await setupSingleChapterWithTwoFragments(store: store)
        let initial = try await publishInitialVersion(store: store, controller: controller, fixture: fixture)
        let repair = try await commitCandidate(
            store: store, bookID: fixture.bookID, chapterID: fixture.chapter.id,
            fragment: fixture.fragments[0], generation: 2, frameCount: 3_600, sampleValue: 920
        )
        try await controller.adopt(bookID: fixture.bookID, candidateID: repair.id, expectedRevisionID: initial.id)
        try await controller.undoAdoption(bookID: fixture.bookID, chapterID: fixture.chapter.id)
        let afterUndo = try await durableSnapshot(store: store, bookID: fixture.bookID, chapterID: fixture.chapter.id)
        XCTAssertEqual(afterUndo.chapters[0].currentChapterRevisionID, initial.id)
        XCTAssertNil(afterUndo.chapters[0].previousChapterRevisionID)
        do {
            try await controller.undoAdoption(bookID: fixture.bookID, chapterID: fixture.chapter.id)
            XCTFail("撤销机会只应消费一次，不能再次切回返修版本")
        } catch let error as AudiobookRevisionError {
            XCTAssertEqual(error, .noPreviousChapterRevisionToUndo(chapterID: fixture.chapter.id))
        }
        let afterSecondUndo = try await durableSnapshot(store: store, bookID: fixture.bookID, chapterID: fixture.chapter.id)
        XCTAssertEqual(afterSecondUndo, afterUndo)
    }

    func testRepeatedInitialPublicationKeepsAdoptedVersionAndRepairCandidate() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let controller = AudiobookRevisionController(store: store)
        let fixture = try await setupSingleChapterWithTwoFragments(store: store)
        let initial = try await publishInitialVersion(store: store, controller: controller, fixture: fixture)
        _ = try await commitCandidate(
            store: store, bookID: fixture.bookID, chapterID: fixture.chapter.id,
            fragment: fixture.fragments[0], generation: 2, frameCount: 3_600, sampleValue: 930
        )
        let beforeRepeat = try await durableSnapshot(store: store, bookID: fixture.bookID, chapterID: fixture.chapter.id)
        let repeated = try await controller.promoteInitialChapterIfComplete(bookID: fixture.bookID, chapterID: fixture.chapter.id)
        XCTAssertEqual(repeated?.id, initial.id)
        let afterRepeat = try await durableSnapshot(store: store, bookID: fixture.bookID, chapterID: fixture.chapter.id)
        XCTAssertEqual(afterRepeat, beforeRepeat, "初次发布重入不能自动采用返修候选或新增重复历史")
    }

    func testConcurrentAdoptionsRecheckExpectedVersionAndKeepIdempotency() async throws {
        for sameCandidate in [false, true] {
            let root = tempRoot.appendingPathComponent(sameCandidate ? "same-candidate" : "different-candidates")
            let store = try AudiobookProjectStore(root: root)
            let controller = AudiobookRevisionController(store: store)
            let otherController = AudiobookRevisionController(store: store)
            let fixture = try await setupSingleChapterWithTwoFragments(store: store)
            let initial = try await publishInitialVersion(store: store, controller: controller, fixture: fixture)
            let first = try await commitCandidate(
                store: store, bookID: fixture.bookID, chapterID: fixture.chapter.id,
                fragment: fixture.fragments[0], generation: 2, frameCount: 3_600, sampleValue: 940
            )
            let second = sameCandidate ? first : try await commitCandidate(
                store: store, bookID: fixture.bookID, chapterID: fixture.chapter.id,
                fragment: fixture.fragments[0], generation: 3, frameCount: 3_800, sampleValue: 950
            )
            let before = try await durableSnapshot(store: store, bookID: fixture.bookID, chapterID: fixture.chapter.id)
            let results = try await withThrowingTaskGroup(of: Bool.self) { group in
                for (target, candidateID) in [(controller, first.id), (otherController, second.id)] {
                    group.addTask {
                        do {
                            try await target.adopt(bookID: fixture.bookID, candidateID: candidateID, expectedRevisionID: initial.id)
                            return true
                        } catch let error as AudiobookRevisionError {
                            guard case .expectedRevisionMismatch = error else { throw error }
                            return false
                        }
                    }
                }
                var collected: [Bool] = []
                for try await result in group { collected.append(result) }
                return collected
            }
            XCTAssertEqual(results.filter { $0 }.count, sameCandidate ? 2 : 1)
            let after = try await durableSnapshot(store: store, bookID: fixture.bookID, chapterID: fixture.chapter.id)
            XCTAssertEqual(after.chapterRevisions.count, before.chapterRevisions.count + 1)
            XCTAssertEqual(after.productionRevisions.count, before.productionRevisions.count + 1)
            XCTAssertEqual(after.chapters[0].previousChapterRevisionID, initial.id)
            let current = try XCTUnwrap(after.chapterRevisions.first { $0.id == after.chapters[0].currentChapterRevisionID })
            XCTAssertTrue(current.orderedBindings.contains { $0.candidateID == first.id || $0.candidateID == second.id })
            let currentProduction = try XCTUnwrap(after.productionRevisions.first { $0.id == after.book.currentProductionRevisionID })
            XCTAssertEqual(currentProduction.chapterRevisionIDsByChapter, [fixture.chapter.id: current.id])
        }
    }

    func testMultiChapterAdoptionFaultPreservesOtherChapterAndBookMap() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let controller = AudiobookRevisionController(store: store)
        let fixture = try await setupSingleChapterWithTwoFragments(
            store: store,
            text: "第一章 渡口\n风声紧迫。\n“快上船！”林远喊道。\n第二章 上岸\n远处的灯亮了。\n"
        )
        let chapters = try await store.chapters(for: fixture.bookID)
        XCTAssertEqual(chapters.count, 2)
        let otherChapter = try XCTUnwrap(chapters.last)
        let otherAtoms = try await store.atoms(for: fixture.bookID, chapterID: otherChapter.id)
        var annotations = try await store.annotations(for: fixture.bookID)
        annotations += otherAtoms.filter { $0.kind != .formatting }.map {
            AudiobookAnnotation(
                bookID: fixture.bookID, chapterID: otherChapter.id, windowID: UUID(),
                atomID: $0.id, sourceRange: $0.sourceRange, assignment: .assigned(roleID: fixture.narrator.id)
            )
        }
        try await store.saveAnnotations(bookID: fixture.bookID, annotations: annotations)
        let source = try await store.sourceIndex(for: fixture.bookID)
        let voices = try await store.voiceBindings(for: fixture.bookID)
        let otherFragments = try AudiobookFragmentPlanner.plan(
            chapter: otherChapter, annotations: annotations, bindings: voices,
            source: source, atoms: otherAtoms
        )
        for fragment in otherFragments {
            _ = try await commitCandidate(
                store: store, bookID: fixture.bookID, chapterID: otherChapter.id,
                fragment: fragment, generation: 1, frameCount: 2_400, sampleValue: 960
            )
        }
        let publishedOther = try await controller.promoteInitialChapterIfComplete(
            bookID: fixture.bookID, chapterID: otherChapter.id
        )
        let otherRevision = try XCTUnwrap(publishedOther)
        let partialBook = try await store.book(id: fixture.bookID)
        XCTAssertEqual(partialBook.listenableState, .partialChaptersListenable)
        XCTAssertNil(partialBook.currentProductionRevisionID)
        let initial = try await publishInitialVersion(store: store, controller: controller, fixture: fixture)
        let repair = try await commitCandidate(
            store: store, bookID: fixture.bookID, chapterID: fixture.chapter.id,
            fragment: fixture.fragments[0], generation: 2, frameCount: 3_600, sampleValue: 970
        )
        let before = try await durableSnapshot(store: store, bookID: fixture.bookID, chapterID: fixture.chapter.id)
        let databaseURL = tempRoot.appendingPathComponent("library.sqlite3")
        let marker = "injected_multichapter_book_failure"
        let prefix = "inject_multichapter_book_fault"
        try Self.installAbortTriggers(
            table: "books", triggerPrefix: prefix, marker: marker,
            predicate: "NEW.id = '\(fixture.bookID.uuidString)'", databaseURL: databaseURL
        )
        defer { try? Self.removeAbortTriggers(triggerPrefix: prefix, databaseURL: databaseURL) }
        do {
            try await controller.adopt(bookID: fixture.bookID, candidateID: repair.id, expectedRevisionID: initial.id)
            XCTFail("整书投影故障应回滚目标章节切换")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(marker))
        }
        let failed = try await durableSnapshot(store: store, bookID: fixture.bookID, chapterID: fixture.chapter.id)
        XCTAssertEqual(failed, before)
        let reopened = try AudiobookProjectStore(root: tempRoot)
        let reopenedFailed = try await durableSnapshot(store: reopened, bookID: fixture.bookID, chapterID: fixture.chapter.id)
        XCTAssertEqual(reopenedFailed, before)
        try Self.removeAbortTriggers(triggerPrefix: prefix, databaseURL: databaseURL)
        try await controller.adopt(bookID: fixture.bookID, candidateID: repair.id, expectedRevisionID: initial.id)
        let adopted = try await durableSnapshot(store: store, bookID: fixture.bookID, chapterID: fixture.chapter.id)
        XCTAssertEqual(adopted.chapters.first { $0.id == otherChapter.id }, before.chapters.first { $0.id == otherChapter.id })
        let production = try XCTUnwrap(adopted.productionRevisions.first { $0.id == adopted.book.currentProductionRevisionID })
        XCTAssertEqual(production.chapterRevisionIDsByChapter[otherChapter.id], otherRevision.id)
        XCTAssertEqual(production.chapterRevisionIDsByChapter[fixture.chapter.id], adopted.chapters[0].currentChapterRevisionID)
        XCTAssertEqual(adopted.chapterRevisions.count, before.chapterRevisions.count + 1)
        XCTAssertEqual(adopted.productionRevisions.count, before.productionRevisions.count + 1)
        XCTAssertEqual(adopted.book.listenableState, .fullBookListenable)
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }
}
