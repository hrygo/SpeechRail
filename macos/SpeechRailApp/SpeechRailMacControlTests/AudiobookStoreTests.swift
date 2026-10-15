import Foundation
import SQLite3
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

final class AudiobookStoreTests: XCTestCase {
    private struct ChapterEditFixture {
        let root: URL
        let store: AudiobookProjectStore
        let bookID: UUID
        let chapter: AudiobookChapter
        let atom: AudiobookTextAtom
        let narrator: AudiobookCharacter
    }

    private enum ChapterEditArtifact: String, CaseIterable {
        case analysisWindow
        case annotation
        case fragment
        case renderCandidate
        case chapterRevision
    }

    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiobookStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeChapterEditFixture() async throws -> ChapterEditFixture {
        let root = try makeTempRoot()
        let store = try AudiobookProjectStore(root: root)
        let preview = try AudiobookTXTImporter.prepare(
            rawData: Data("第1章 灯塔\n海雾在午夜漫过栈桥。\n".utf8),
            suggestedTitle: "章节编辑夹具"
        )
        let bookID = try await store.importBook(preview)
        let chapters = try await store.chapters(for: bookID)
        let chapter = try XCTUnwrap(chapters.first)
        let atoms = try await store.atoms(for: bookID, chapterID: chapter.id)
        let atom = try XCTUnwrap(atoms.first(where: { $0.kind != .formatting }))
        let characters = try await store.characters(for: bookID)
        let narrator = try XCTUnwrap(characters.first(where: { $0.isNarrator }))
        return ChapterEditFixture(
            root: root,
            store: store,
            bookID: bookID,
            chapter: chapter,
            atom: atom,
            narrator: narrator
        )
    }

    private func changedTitles(_ chapters: [AudiobookChapter]) -> [AudiobookChapter] {
        chapters.map { chapter in
            var edited = chapter
            edited.title += "（改名）"
            return edited
        }
    }

    func testProductionCheckpointPreservesTaskScopeAndOmitsServiceErrorsAcrossRestore() async throws {
        let fixture = try await makeChapterEditFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let progress = AudiobookProductionProgress(
            bookID: fixture.bookID, state: .paused, completedFragments: 2, totalFragments: 5,
            lastErrorMessage: "private-service-response-marker", phase: .saving,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let checkpoint = AudiobookProductionCheckpoint(
            chapterIDs: [fixture.chapter.id], regeneratingFragmentID: UUID(), progress: progress
        )
        try await fixture.store.saveProductionCheckpoint(checkpoint)
        let reopened = try AudiobookProjectStore(root: fixture.root)
        let saved = try await reopened.productionCheckpoint(for: fixture.bookID)
        XCTAssertEqual(saved?.taskID, checkpoint.taskID)
        XCTAssertEqual(saved?.chapterIDs, checkpoint.chapterIDs)
        XCTAssertEqual(saved?.regeneratingFragmentID, checkpoint.regeneratingFragmentID)
        XCTAssertEqual(saved?.progress.completedFragments, 2)
        XCTAssertNil(saved?.progress.lastErrorMessage, "服务错误正文不能进入持久化进度")
        try await reopened.trashBook(id: fixture.bookID)
        try await reopened.restoreTrashedBook(id: fixture.bookID)
        let restored = try await reopened.productionCheckpoint(for: fixture.bookID)
        XCTAssertEqual(restored, saved, "移入应用恢复区并恢复后仍须保留原任务范围")
    }

    func testCompletionCheckpointAndBookAvailabilityRollBackTogether() async throws {
        let fixture = try await makeChapterEditFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let running = AudiobookProductionCheckpoint(
            chapterIDs: [fixture.chapter.id],
            progress: .init(bookID: fixture.bookID, state: .running, phase: .saving)
        )
        try await fixture.store.saveProductionCheckpoint(running)
        let originalBook = try await fixture.store.book(id: fixture.bookID)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.root.appendingPathComponent("library.sqlite3").path, &database), SQLITE_OK)
        let handle = try XCTUnwrap(database)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, """
            CREATE TRIGGER reject_completion BEFORE INSERT ON production_checkpoints
            WHEN json_extract(NEW.checkpoint_json, '$.progress.phase') = 'completed'
            BEGIN SELECT RAISE(FAIL, 'simulated completion transaction failure'); END;
            """, nil, nil, nil), SQLITE_OK)
        var completed = running
        completed.progress.state = .fullBookProduced
        completed.progress.phase = .completed
        do {
            try await fixture.store.saveProductionCheckpoint(completed, listenableState: .fullBookListenable)
            XCTFail("最终检查点写入失败必须回滚同事务的书籍状态")
        } catch let error as AudiobookStoreError {
            guard case .statementFailed = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let restoredBook = try await fixture.store.book(id: fixture.bookID)
        let restoredCheckpoint = try await fixture.store.productionCheckpoint(for: fixture.bookID)
        XCTAssertEqual(restoredBook.productionState, originalBook.productionState)
        XCTAssertEqual(restoredBook.listenableState, originalBook.listenableState)
        XCTAssertEqual(restoredCheckpoint, running)
    }

    private func seedChapterEditArtifact(
        _ artifact: ChapterEditArtifact,
        fixture: ChapterEditFixture
    ) async throws {
        let chapter = fixture.chapter
        let atom = fixture.atom
        let store = fixture.store

        switch artifact {
        case .analysisWindow:
            try await store.saveAnalysisWindow(
                AudiobookAnalysisWindow(
                    bookID: fixture.bookID,
                    chapterID: chapter.id,
                    ordinal: 0,
                    primaryAtomIDs: [atom.id],
                    policyFingerprint: "test-policy",
                    configurationDigest: "test-config",
                    isCompleted: true
                )
            )
        case .annotation:
            try await store.saveAnnotations(
                bookID: fixture.bookID,
                annotations: [
                    AudiobookAnnotation(
                        bookID: fixture.bookID,
                        chapterID: chapter.id,
                        windowID: UUID(),
                        atomID: atom.id,
                        sourceRange: atom.sourceRange,
                        assignment: .assigned(roleID: fixture.narrator.id)
                    ),
                ]
            )
        case .fragment:
            let fragment = AudiobookFragment(
                bookID: fixture.bookID,
                chapterID: chapter.id,
                ordinal: 0,
                roleID: fixture.narrator.id,
                sourceRange: atom.sourceRange,
                atomIDs: [atom.id],
                localAssignmentDigest: "test-assignment",
                voiceBindingDigest: "test-binding",
                policyDigest: "test-policy",
                dependencyDigest: "test-dependency"
            )
            try await store.saveFragments(bookID: fixture.bookID, chapterID: chapter.id, fragments: [fragment])
        case .renderCandidate:
            let wav = Self.makeDeterministicWAV(pcmSamples: Array(repeating: 1200, count: 480))
            let candidate = AudiobookRenderCandidate(
                bookID: fixture.bookID,
                chapterID: chapter.id,
                fragmentID: UUID(),
                generation: 1,
                relativeAssetPath: "books/\(fixture.bookID.uuidString)/audio/chapter-edit-guard.wav",
                fileSHA256: AudiobookDigest.sha256Hex(wav),
                pcmSHA256: try AudioDigest.sha256HexOfPCM(in: wav),
                frameCount: 480,
                dependencyDigest: "test-dependency"
            )
            try await store.commitCandidate(candidate, wav: wav)
        case .chapterRevision:
            let revision = AudiobookChapterRevision(
                bookID: fixture.bookID,
                chapterID: chapter.id,
                sourceID: chapter.sourceID,
                revisionNumber: 1,
                orderedBindings: [],
                totalFrameCount: 0
            )
            try await store.saveChapterRevision(revision, makeCurrent: true)
        }
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

    func testFirstRecoveryOnNewStorePausesPriorRunningBooksOnlyOnce() async throws {
        let fixture = try await makeChapterEditFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        func importBook(title: String) async throws -> UUID {
            let preview = try AudiobookTXTImporter.prepare(
                rawData: Data("第1章 雾港\n船灯渐远。\n".utf8),
                suggestedTitle: title
            )
            return try await fixture.store.importBook(preview)
        }

        let activeBookID = try await importBook(title: "启动后已更新的制作任务")
        let pausedBookID = try await importBook(title: "已暂停书")
        let completedBookID = try await importBook(title: "已完成书")
        let analysisBookID = try await importBook(title: "遗留分析任务")

        var interruptedBook = try await fixture.store.book(id: fixture.bookID)
        interruptedBook.productionState = .running
        try await fixture.store.updateBook(interruptedBook)
        var liveBookBeforeOpen = try await fixture.store.book(id: activeBookID)
        liveBookBeforeOpen.productionState = .running
        try await fixture.store.updateBook(liveBookBeforeOpen)
        var alreadyPausedBook = try await fixture.store.book(id: pausedBookID)
        alreadyPausedBook.productionState = .paused
        try await fixture.store.updateBook(alreadyPausedBook)
        var completedBook = try await fixture.store.book(id: completedBookID)
        completedBook.productionState = .fullBookProduced
        completedBook.listenableState = .fullBookListenable
        try await fixture.store.updateBook(completedBook)
        var interruptedAnalysis = try await fixture.store.book(id: analysisBookID)
        interruptedAnalysis.analysisState = .running
        try await fixture.store.updateBook(interruptedAnalysis)

        let reopenedStore = try AudiobookProjectStore(root: fixture.root)

        // A same-actor update after initialization identifies a live run, even before first recovery.
        var liveRun = try await reopenedStore.book(id: activeBookID)
        let startupUpdatedAt = liveRun.updatedAt
        liveRun.productionState = .running
        try await reopenedStore.updateBook(liveRun)
        let refreshedLiveRun = try await reopenedStore.book(id: activeBookID)
        XCTAssertNotEqual(refreshedLiveRun.updatedAt, startupUpdatedAt,
                          "夹具必须确认首次恢复前的本实例活动写入已更新启动快照时间戳")

        _ = try await reopenedStore.recover()

        let recoveredInterruptedBook = try await reopenedStore.book(id: fixture.bookID)
        XCTAssertEqual(recoveredInterruptedBook.productionState, .paused,
                       "新 Store 首次恢复应把上进程遗留的 running 任务安全暂停")
        let recoveredAlreadyPausedBook = try await reopenedStore.book(id: pausedBookID)
        XCTAssertEqual(recoveredAlreadyPausedBook.productionState, .paused,
                       "恢复不能改写本来已暂停的书籍")
        let recoveredCompletedBook = try await reopenedStore.book(id: completedBookID)
        XCTAssertEqual(recoveredCompletedBook.productionState, .fullBookProduced,
                       "恢复不能把已完成的制作误判为崩溃任务")
        XCTAssertEqual(recoveredCompletedBook.listenableState, .fullBookListenable)
        let recoveredInterruptedAnalysis = try await reopenedStore.book(id: analysisBookID)
        XCTAssertEqual(recoveredInterruptedAnalysis.analysisState, .paused,
                       "新 Store 首次恢复应把上进程遗留的全书分析任务安全暂停")
        let recoveredLiveRun = try await reopenedStore.book(id: activeBookID)
        XCTAssertEqual(recoveredLiveRun.productionState, .running,
                       "首次恢复不能暂停 Store 初始化后已更新的活动制作任务")

        // Same Store actor's later shelf refresh/recovery must not mistake an active run for a crash.
        var activeBook = try await reopenedStore.book(id: fixture.bookID)
        activeBook.productionState = .running
        try await reopenedStore.updateBook(activeBook)
        _ = try await reopenedStore.recover()

        let activeBookAfterRepeatedRecovery = try await reopenedStore.book(id: fixture.bookID)
        XCTAssertEqual(activeBookAfterRepeatedRecovery.productionState, .running,
                       "同一 Store 的后续恢复调用不能暂停当前进程中的制作任务")
    }

    func testInitialChapterStructureEditSynchronizesNarratorChapterIDs() async throws {
        let fixture = try await makeChapterEditFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let replacementChapter = AudiobookChapter(
            id: UUID(),
            bookID: fixture.chapter.bookID,
            sourceID: fixture.chapter.sourceID,
            ordinal: fixture.chapter.ordinal,
            title: "人工确认的章节名",
            sourceRange: fixture.chapter.sourceRange,
            excludedRanges: fixture.chapter.excludedRanges
        )

        try await fixture.store.updateChapters(bookID: fixture.bookID, chapters: [replacementChapter])

        let storedChapters = try await fixture.store.chapters(for: fixture.bookID)
        XCTAssertEqual(storedChapters, [replacementChapter])
        let cachedCharacters = try await fixture.store.characters(for: fixture.bookID)
        let cachedNarrator = try XCTUnwrap(cachedCharacters.first(where: { $0.isNarrator }))
        XCTAssertEqual(cachedNarrator.chapterIDs, [replacementChapter.id],
                       "首次编辑章节结构后旁白出场章节必须立即同步")

        let reopenedStore = try AudiobookProjectStore(root: fixture.root)
        let persistedCharacters = try await reopenedStore.characters(for: fixture.bookID)
        let persistedNarrator = try XCTUnwrap(persistedCharacters.first(where: { $0.isNarrator }))
        XCTAssertEqual(persistedNarrator.chapterIDs, [replacementChapter.id],
                       "旁白章节关联必须写入持久化数据")
        let updatedBook = try await reopenedStore.book(id: fixture.bookID)
        XCTAssertEqual(updatedBook.analysisState, .notStarted)
    }

    func testSaveCharactersPreservesBindingsForRetainedRolesAndRemovesDeletedRoles() async throws {
        let fixture = try await makeChapterEditFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let retainedRole = AudiobookCharacter(
            bookID: fixture.bookID,
            displayName: "林远",
            isNarrator: false,
            isMajor: true,
            chapterIDs: [fixture.chapter.id]
        )
        let removedRole = AudiobookCharacter(
            bookID: fixture.bookID,
            displayName: "顾南",
            isNarrator: false,
            isMajor: true,
            chapterIDs: [fixture.chapter.id]
        )
        try await fixture.store.saveCharacters(bookID: fixture.bookID, characters: [retainedRole, removedRole])

        let narratorBinding = AudiobookVoiceBinding(
            roleID: retainedRole.id,
            voiceID: "v-narrator-retained",
            voiceRevision: "narrator-r1",
            modelRevision: "model-r1"
        )
        let removedRoleBinding = AudiobookVoiceBinding(
            roleID: removedRole.id,
            voiceID: "v-hero-removed",
            voiceRevision: "hero-r1",
            modelRevision: "model-r1"
        )
        try await fixture.store.saveVoiceBinding(bookID: fixture.bookID, binding: narratorBinding)
        try await fixture.store.saveVoiceBinding(bookID: fixture.bookID, binding: removedRoleBinding)

        let foreignRole = AudiobookCharacter(
            bookID: UUID(),
            displayName: "外书角色",
            isNarrator: false
        )
        let duplicateRole = AudiobookCharacter(
            id: retainedRole.id,
            bookID: fixture.bookID,
            displayName: "重复编号角色",
            isNarrator: false
        )
        let charactersBeforeInvalidSaves = try await fixture.store.characters(for: fixture.bookID)
        let bindingsBeforeInvalidSaves = try await fixture.store.voiceBindings(for: fixture.bookID)
        for invalidCharacters in [[retainedRole, foreignRole], [retainedRole, duplicateRole]] {
            var rejectionMessage: String?
            do {
                try await fixture.store.saveCharacters(bookID: fixture.bookID, characters: invalidCharacters)
            } catch {
                rejectionMessage = error.localizedDescription
            }
            XCTAssertNotNil(rejectionMessage, "跨书或重复编号的角色列表必须被拒绝")
            let savedCharacters = try await fixture.store.characters(for: fixture.bookID)
            let savedBindings = try await fixture.store.voiceBindings(for: fixture.bookID)
            XCTAssertEqual(savedCharacters, charactersBeforeInvalidSaves, "拒绝无效角色列表后原角色数据不得变化")
            XCTAssertEqual(savedBindings, bindingsBeforeInvalidSaves, "拒绝无效角色列表后音色绑定不得变化")
        }

        let updatedRetainedRole = AudiobookCharacter(
            id: retainedRole.id,
            bookID: retainedRole.bookID,
            displayName: "更新后的角色",
            aliases: retainedRole.aliases,
            isNarrator: true,
            isMajor: false,
            allowSharedMinorVoice: true,
            evidences: retainedRole.evidences,
            firstAppearanceRange: retainedRole.firstAppearanceRange,
            chapterIDs: retainedRole.chapterIDs
        )
        try await fixture.store.saveCharacters(bookID: fixture.bookID, characters: [updatedRetainedRole])

        let reopenedStore = try AudiobookProjectStore(root: fixture.root)
        let savedCharacters = try await reopenedStore.characters(for: fixture.bookID)
        XCTAssertEqual(savedCharacters, [updatedRetainedRole], "保留角色的显示名与旁白属性更新必须持久化，已删除角色应消失")

        let savedBindings = try await reopenedStore.voiceBindings(for: fixture.bookID)
        XCTAssertEqual(savedBindings[retainedRole.id], narratorBinding, "保留角色的音色绑定不能因同步角色列表而丢失")
        XCTAssertNil(savedBindings[removedRole.id], "已删除角色的音色绑定应随角色移除")
    }

    func testUpdateChaptersRejectsForeignBookAndSourceIdentityWithoutMutation() async throws {
        let fixture = try await makeChapterEditFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let originalChapter = fixture.chapter
        let invalidChapters = [
            AudiobookChapter(
                id: originalChapter.id,
                bookID: UUID(),
                sourceID: originalChapter.sourceID,
                ordinal: originalChapter.ordinal,
                title: "跨书章节",
                sourceRange: originalChapter.sourceRange,
                excludedRanges: originalChapter.excludedRanges
            ),
            AudiobookChapter(
                id: originalChapter.id,
                bookID: fixture.bookID,
                sourceID: UUID(),
                ordinal: originalChapter.ordinal,
                title: "跨正文章节",
                sourceRange: originalChapter.sourceRange,
                excludedRanges: originalChapter.excludedRanges
            ),
        ]
        let beforeBook = try await fixture.store.book(id: fixture.bookID)
        let beforeChapters = try await fixture.store.chapters(for: fixture.bookID)
        let beforeAtoms = try await fixture.store.atoms(for: fixture.bookID)
        let beforeCharacters = try await fixture.store.characters(for: fixture.bookID)

        for invalidChapter in invalidChapters {
            var rejectionMessage: String?
            do {
                try await fixture.store.updateChapters(bookID: fixture.bookID, chapters: [invalidChapter])
            } catch {
                rejectionMessage = error.localizedDescription
            }
            XCTAssertTrue(rejectionMessage?.contains("章节") == true,
                          "跨书或跨正文章节必须以中文错误拒绝；实际：\(rejectionMessage ?? "未拒绝")")
            let afterBook = try await fixture.store.book(id: fixture.bookID)
            let afterChapters = try await fixture.store.chapters(for: fixture.bookID)
            let afterAtoms = try await fixture.store.atoms(for: fixture.bookID)
            let afterCharacters = try await fixture.store.characters(for: fixture.bookID)
            XCTAssertEqual(afterBook, beforeBook)
            XCTAssertEqual(afterChapters, beforeChapters)
            XCTAssertEqual(afterAtoms, beforeAtoms)
            XCTAssertEqual(afterCharacters, beforeCharacters)
        }
    }

    func testUpdateChaptersRejectsBooksWhoseAnalysisHasStartedWithoutChangingData() async throws {
        let fixture = try await makeChapterEditFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var book = try await fixture.store.book(id: fixture.bookID)
        book.analysisState = .paused
        try await fixture.store.updateBook(book)
        let beforeBook = try await fixture.store.book(id: fixture.bookID)
        let beforeChapters = try await fixture.store.chapters(for: fixture.bookID)
        let beforeAtoms = try await fixture.store.atoms(for: fixture.bookID)

        var rejectionMessage: String?
        do {
            try await fixture.store.updateChapters(
                bookID: fixture.bookID,
                chapters: changedTitles(beforeChapters)
            )
        } catch {
            rejectionMessage = error.localizedDescription
        }

        XCTAssertTrue(rejectionMessage?.contains("章节结构") == true,
                      "拒绝原因应使用明确中文说明章节结构已锁定；实际：\(rejectionMessage ?? "未拒绝")")
        let afterBook = try await fixture.store.book(id: fixture.bookID)
        let afterChapters = try await fixture.store.chapters(for: fixture.bookID)
        let afterAtoms = try await fixture.store.atoms(for: fixture.bookID)
        XCTAssertEqual(afterBook, beforeBook)
        XCTAssertEqual(afterChapters, beforeChapters)
        XCTAssertEqual(afterAtoms, beforeAtoms)
    }

    func testUpdateChaptersRejectsWhenAnyPersistentAnalysisOrProductionArtifactExists() async throws {
        for artifact in ChapterEditArtifact.allCases {
            let fixture = try await makeChapterEditFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try await seedChapterEditArtifact(artifact, fixture: fixture)

            let beforeBook = try await fixture.store.book(id: fixture.bookID)
            let beforeChapters = try await fixture.store.chapters(for: fixture.bookID)
            let beforeAtoms = try await fixture.store.atoms(for: fixture.bookID)
            let beforeWindows = try await fixture.store.analysisWindows(for: fixture.bookID)
            let beforeAnnotations = try await fixture.store.annotations(for: fixture.bookID)
            let beforeFragments = try await fixture.store.fragments(for: fixture.bookID)
            let beforeCandidates = try await fixture.store.candidates(for: fixture.bookID)
            let beforeRevisions = try await fixture.store.chapterRevisions(
                for: fixture.bookID,
                chapterID: fixture.chapter.id
            )

            var rejectionMessage: String?
            do {
                try await fixture.store.updateChapters(
                    bookID: fixture.bookID,
                    chapters: changedTitles(beforeChapters)
                )
            } catch {
                rejectionMessage = error.localizedDescription
            }

            XCTAssertTrue(rejectionMessage?.contains("章节结构") == true,
                          "存在 \(artifact.rawValue) 时应明确拒绝章节结构编辑；实际：\(rejectionMessage ?? "未拒绝")")
            let afterBook = try await fixture.store.book(id: fixture.bookID)
            let afterChapters = try await fixture.store.chapters(for: fixture.bookID)
            let afterAtoms = try await fixture.store.atoms(for: fixture.bookID)
            let afterWindows = try await fixture.store.analysisWindows(for: fixture.bookID)
            let afterAnnotations = try await fixture.store.annotations(for: fixture.bookID)
            let afterFragments = try await fixture.store.fragments(for: fixture.bookID)
            let afterCandidates = try await fixture.store.candidates(for: fixture.bookID)
            let afterRevisions = try await fixture.store.chapterRevisions(
                for: fixture.bookID,
                chapterID: fixture.chapter.id
            )
            XCTAssertEqual(afterBook, beforeBook)
            XCTAssertEqual(afterChapters, beforeChapters)
            XCTAssertEqual(afterAtoms, beforeAtoms)
            XCTAssertEqual(afterWindows, beforeWindows)
            XCTAssertEqual(afterAnnotations, beforeAnnotations)
            XCTAssertEqual(afterFragments, beforeFragments)
            XCTAssertEqual(afterCandidates, beforeCandidates)
            XCTAssertEqual(
                afterRevisions,
                beforeRevisions
            )
        }
    }

    func testRenameChapterPreservesAnalysisAnnotationsCandidatesAndEveryRevision() async throws {
        let fixture = try await makeChapterEditFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let window = AudiobookAnalysisWindow(
            bookID: fixture.bookID,
            chapterID: fixture.chapter.id,
            ordinal: 0,
            primaryAtomIDs: [fixture.atom.id],
            policyFingerprint: "rename-policy",
            configurationDigest: "rename-config",
            isCompleted: true
        )
        try await fixture.store.saveAnalysisWindow(window)
        let annotation = AudiobookAnnotation(
            bookID: fixture.bookID,
            chapterID: fixture.chapter.id,
            windowID: window.id,
            atomID: fixture.atom.id,
            sourceRange: fixture.atom.sourceRange,
            assignment: .assigned(roleID: fixture.narrator.id),
            evidence: "原始标注证据"
        )
        try await fixture.store.saveAnnotations(bookID: fixture.bookID, annotations: [annotation])

        let fragment = AudiobookFragment(
            bookID: fixture.bookID,
            chapterID: fixture.chapter.id,
            ordinal: 0,
            roleID: fixture.narrator.id,
            sourceRange: fixture.atom.sourceRange,
            atomIDs: [fixture.atom.id],
            localAssignmentDigest: "rename-assignment",
            voiceBindingDigest: "rename-binding",
            policyDigest: "rename-policy",
            dependencyDigest: "rename-dependency"
        )
        try await fixture.store.saveFragments(
            bookID: fixture.bookID,
            chapterID: fixture.chapter.id,
            fragments: [fragment]
        )

        let wav = Self.makeDeterministicWAV(pcmSamples: Array(repeating: 700, count: 480))
        let candidate = AudiobookRenderCandidate(
            bookID: fixture.bookID,
            chapterID: fixture.chapter.id,
            fragmentID: fragment.id,
            generation: 1,
            relativeAssetPath: "books/\(fixture.bookID.uuidString)/audio/rename-preserved.wav",
            fileSHA256: AudiobookDigest.sha256Hex(wav),
            pcmSHA256: try AudioDigest.sha256HexOfPCM(in: wav),
            frameCount: 480,
            dependencyDigest: fragment.dependencyDigest
        )
        try await fixture.store.commitCandidate(candidate, wav: wav)

        let binding = AudiobookFragmentCandidateBinding(
            fragmentID: fragment.id,
            candidateID: candidate.id,
            sourceRange: fragment.sourceRange,
            dependencyDigest: candidate.dependencyDigest
        )
        let firstRevision = AudiobookChapterRevision(
            bookID: fixture.bookID,
            chapterID: fixture.chapter.id,
            sourceID: fixture.chapter.sourceID,
            revisionNumber: 1,
            orderedBindings: [binding],
            totalFrameCount: candidate.frameCount
        )
        try await fixture.store.saveChapterRevision(firstRevision, makeCurrent: true)
        let secondRevision = AudiobookChapterRevision(
            bookID: fixture.bookID,
            chapterID: fixture.chapter.id,
            sourceID: fixture.chapter.sourceID,
            revisionNumber: 2,
            orderedBindings: [binding],
            totalFrameCount: candidate.frameCount
        )
        try await fixture.store.saveChapterRevision(secondRevision, makeCurrent: true)

        var book = try await fixture.store.book(id: fixture.bookID)
        book.analysisState = .allWindowsValidated
        book.productionState = .partialChaptersReady
        book.listenableState = .partialChaptersListenable
        book.confirmedCastRevisionID = UUID()
        book.confirmedAuditionVoiceSetDigest = "rename-voice-digest"
        try await fixture.store.updateBook(book)
        let productionRevision = AudiobookProductionRevision(
            bookID: fixture.bookID,
            sourceID: fixture.chapter.sourceID,
            chapterRevisionIDsByChapter: [fixture.chapter.id: secondRevision.id]
        )
        try await fixture.store.saveProductionRevision(productionRevision)
        let bookmark = AudiobookBookmark(
            bookID: fixture.bookID,
            chapterID: fixture.chapter.id,
            chapterRevisionID: secondRevision.id,
            fragmentID: fragment.id,
            sourceAnchorRange: fixture.atom.sourceRange,
            fragmentOffsetSeconds: 0.25
        )
        try await fixture.store.saveBookmark(bookmark)

        let chaptersBeforeRename = try await fixture.store.chapters(for: fixture.bookID)
        let chapterBefore = try XCTUnwrap(chaptersBeforeRename.first)
        let bookBefore = try await fixture.store.book(id: fixture.bookID)
        let charactersBefore = try await fixture.store.characters(for: fixture.bookID)
        let windowsBefore = try await fixture.store.analysisWindows(for: fixture.bookID)
        let annotationsBefore = try await fixture.store.annotations(for: fixture.bookID)
        let fragmentsBefore = try await fixture.store.fragments(for: fixture.bookID)
        let candidatesBefore = try await fixture.store.candidates(for: fixture.bookID)
        let chapterRevisionsBefore = try await fixture.store.chapterRevisions(
            for: fixture.bookID,
            chapterID: fixture.chapter.id
        )
        let productionRevisionsBefore = try await fixture.store.productionRevisions(for: fixture.bookID)
        let bookmarkBefore = try await fixture.store.bookmark(for: fixture.bookID)

        let renamedTitle = "人工重命名章节"
        try await fixture.store.renameChapter(
            bookID: fixture.bookID,
            chapterID: fixture.chapter.id,
            title: renamedTitle
        )

        var expectedChapter = chapterBefore
        expectedChapter.title = renamedTitle
        let chaptersAfterRename = try await fixture.store.chapters(for: fixture.bookID)
        let chapterAfter = try XCTUnwrap(chaptersAfterRename.first)
        let bookAfter = try await fixture.store.book(id: fixture.bookID)
        let charactersAfter = try await fixture.store.characters(for: fixture.bookID)
        let windowsAfter = try await fixture.store.analysisWindows(for: fixture.bookID)
        let annotationsAfter = try await fixture.store.annotations(for: fixture.bookID)
        let fragmentsAfter = try await fixture.store.fragments(for: fixture.bookID)
        let candidatesAfter = try await fixture.store.candidates(for: fixture.bookID)
        let chapterRevisionsAfter = try await fixture.store.chapterRevisions(
            for: fixture.bookID,
            chapterID: fixture.chapter.id
        )
        let productionRevisionsAfter = try await fixture.store.productionRevisions(for: fixture.bookID)
        let bookmarkAfter = try await fixture.store.bookmark(for: fixture.bookID)
        XCTAssertEqual(chapterAfter, expectedChapter,
                       "重命名只能改变标题，章节身份、源区间和修订指针必须保留")
        XCTAssertEqual(bookAfter, bookBefore)
        XCTAssertEqual(charactersAfter, charactersBefore)
        XCTAssertEqual(windowsAfter, windowsBefore)
        XCTAssertEqual(annotationsAfter, annotationsBefore)
        XCTAssertEqual(fragmentsAfter, fragmentsBefore)
        XCTAssertEqual(candidatesAfter, candidatesBefore)
        XCTAssertEqual(chapterRevisionsAfter, chapterRevisionsBefore)
        XCTAssertEqual(productionRevisionsAfter, productionRevisionsBefore)
        XCTAssertEqual(bookmarkAfter, bookmarkBefore)
        XCTAssertEqual(chapterRevisionsBefore.map(\.id).sorted { $0.uuidString < $1.uuidString },
                       [firstRevision.id, secondRevision.id].sorted { $0.uuidString < $1.uuidString })
        let candidateStillValid = try await fixture.store.verifyCandidateAsset(candidate)
        XCTAssertTrue(candidateStillValid, "章节重命名不能删除或改写已提交的 WAV 资产")
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
