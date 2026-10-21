import Foundation
import SQLite3
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

final class AudiobookStoreTests: XCTestCase {
    func testChapterEditPreservesCanonicalEquivalentButDifferentUserBytes() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AudiobookProjectStore(root: root)
        let preview = try AudiobookTXTImporter.prepare(rawData: Data("café".utf8))
        let id = try await store.importBook(preview)
        let draft = try await store.chapterEditDraft(bookID: id, chapterID: preview.chapters[0].id)
        let decomposed = "cafe\u{0301}"
        XCTAssertEqual(draft.body, decomposed, "Swift string equality uses canonical equivalence")
        XCTAssertTrue(draft.hasChanges(title: draft.title, body: decomposed), "Closing the editor must warn for byte-only changes")
        let result = try await store.saveChapterEdit(draft, title: draft.title, body: decomposed)
        XCTAssertNotEqual(result.sourceID, draft.sourceID)
        let source = try await store.workingSourceSnapshot(bookID: id)
        XCTAssertEqual(source.sourceIndex.utf8Data, Data(decomposed.utf8))
        let fresh = try await store.chapterEditDraft(bookID: id, chapterID: result.chapterID)
        _ = try await store.saveChapterEdit(fresh, title: "café", body: fresh.body)
        let named = try await store.chapterEditDraft(bookID: id, chapterID: result.chapterID)
        XCTAssertTrue(named.hasChanges(title: decomposed, body: named.body))
        _ = try await store.saveChapterEdit(named, title: decomposed, body: named.body)
        let renamed = try await store.chapterEditDraft(bookID: id, chapterID: result.chapterID)
        XCTAssertEqual(Data(renamed.title.utf8), Data(decomposed.utf8))
        XCTAssertFalse(renamed.hasChanges(title: renamed.title, body: renamed.body))
        do { try await store.renameChapter(bookID: id, chapterID: result.chapterID, title: "旧窗口", expectedTitle: named.title); XCTFail("Byte-different stale title accepted") }
        catch { XCTAssertEqual(error as? AudiobookChapterTextEditError, .staleDraft) }
    }

    func testChapterEditPersistsUserTextAndKeepsReferenceAndPriorRevision() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = try AudiobookTXTImporter.prepare(rawData: Data("第一章\n老監\n生在寒\n暄。\n\n第二章\n原有的后文。".utf8))
        let store = try AudiobookProjectStore(root: root)
        let bookID = try await store.importBook(preview)
        let old = try await store.workingSourceSnapshot(bookID: bookID)
        let chapters = try await store.chapters(for: bookID)
        XCTAssertEqual(chapters.count, 2)
        let draft = try await store.chapterEditDraft(bookID: bookID, chapterID: chapters[0].id)
        let body = "人工修改的老監生。👩‍👩‍👧‍👦 e\u{0301}\n\n保留用户换行。\n"
        let result = try await store.saveChapterEdit(draft, title: "手工篇名", body: body)
        XCTAssertNotEqual(result.sourceID, old.sourceID)
        let reopened = try AudiobookProjectStore(root: root)
        let updated = try await reopened.chapterEditDraft(bookID: bookID, chapterID: result.chapterID)
        XCTAssertEqual(updated.body, body)
        XCTAssertEqual(updated.title, "手工篇名")
        let reference = try await reopened.referenceSourceIndex(for: bookID)
        XCTAssertEqual(reference.utf8Data, preview.referenceUTF8)
        let oldChapters = try await reopened.chapters(for: bookID, sourceID: old.sourceID)
        XCTAssertEqual(oldChapters, chapters)
        let currentChapters = try await reopened.chapters(for: bookID)
        let current = try await reopened.workingSourceSnapshot(bookID: bookID)
        XCTAssertEqual(try current.sourceIndex.text(in: currentChapters[1].sourceRange), try old.sourceIndex.text(in: chapters[1].sourceRange))
        try current.sourceIndex.validateCoverage(currentChapters.map(\.sourceRange))
        // Editing a user-generated span again must not manufacture reference offsets.
        let again = try await reopened.saveChapterEdit(updated, title: updated.title, body: "再次修改👋。")
        let latest = try await reopened.chapterEditDraft(bookID: bookID, chapterID: again.chapterID)
        XCTAssertEqual(latest.body, "再次修改👋。")
        _ = try await reopened.workingSourceSnapshot(bookID: bookID)
        XCTAssertTrue(try sqlite(root, sql: "PRAGMA foreign_key_check;").isEmpty)
    }

    func testChapterEditNoOpTitleOnlyStaleAndDiskFailureAreSafe() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = try AudiobookTXTImporter.prepare(rawData: Data("第一章\n原来的正文。".utf8))
        let store = try AudiobookProjectStore(root: root)
        let bookID = try await store.importBook(preview)
        let chapterID = try XCTUnwrap(preview.chapters.first?.id)
        let draft = try await store.chapterEditDraft(bookID: bookID, chapterID: chapterID)
        let unchanged = try await store.saveChapterEdit(draft, title: draft.title, body: draft.body)
        XCTAssertEqual(unchanged.sourceID, preview.sourceID)
        let renamed = try await store.saveChapterEdit(draft, title: "新章名", body: draft.body)
        XCTAssertEqual(renamed.chapterID, chapterID)
        XCTAssertEqual(renamed.sourceID, preview.sourceID)
        do { try await store.renameChapter(bookID: bookID, chapterID: chapterID, title: "旧窗口的标题", expectedTitle: draft.title); XCTFail("Stale rename accepted") }
        catch { XCTAssertEqual(error as? AudiobookChapterTextEditError, .staleDraft) }
        do { _ = try await store.saveChapterEdit(draft, title: "过期", body: "过期草稿。"); XCTFail("Stale layout accepted") }
        catch { XCTAssertEqual(error as? AudiobookChapterTextEditError, .staleDraft) }
        let fresh = try await store.chapterEditDraft(bookID: bookID, chapterID: chapterID)
        await store.setSimulateDiskFull(true)
        do { _ = try await store.saveChapterEdit(fresh, title: fresh.title, body: "新内容。"); XCTFail("Disk failure accepted") }
        catch { XCTAssertEqual(error as? AudiobookStoreError, .diskFull) }
        let persisted = try await store.chapterEditDraft(bookID: bookID, chapterID: chapterID)
        XCTAssertEqual(persisted, fresh)
        XCTAssertEqual(try sqlite(root, sql: "SELECT COUNT(*) FROM sources;"), [["2"]])
    }

    func testChapterEditRejectsAnalysisAndPreservesHistoricalAudio() async throws {
        let fixture = try makeFrozenFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try AudiobookProjectStore(root: fixture.root)
        _ = try await store.prepareWorkingRevision(bookID: fixture.bookID, expectedSourceID: fixture.sourceID)
        let chapters = try await store.chapters(for: fixture.bookID)
        let draft = try await store.chapterEditDraft(bookID: fixture.bookID, chapterID: chapters[0].id)
        let edited = try await store.saveChapterEdit(draft, title: draft.title, body: "用户更新后的正文。")
        let fresh = try await store.chapterEditDraft(bookID: fixture.bookID, chapterID: edited.chapterID)
        _ = try await store.beginAnalysisRun(bookID: fixture.bookID, expectedSourceID: edited.sourceID, runID: UUID())
        do { _ = try await store.saveChapterEdit(fresh, title: fresh.title, body: "不能覆盖分析。"); XCTFail("Analysis race accepted") }
        catch { XCTAssertEqual(error as? AudiobookChapterTextEditError, .notEditable) }
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(fixture.candidate.relativeAssetPath)), fixture.wav)
        let old = try await store.chapters(for: fixture.bookID, sourceID: fixture.sourceID)
        XCTAssertEqual(old.map(\.id), [fixture.chapterID])
    }

    func testChapterEditKeepsManualLayoutSkipsAndExcludesImportedDirectory() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AudiobookProjectStore(root: root)
        let preview = try AudiobookTXTImporter.prepare(rawData: Data("第一章\n目录占位\n\n实际内容。\n\n第二章\n后文内容。".utf8))
        let id = try await store.importBook(preview)
        let source = try await store.sourceIndex(for: id)
        var chapters = try await store.chapters(for: id)
        let excluded = try XCTUnwrap(source.utf8Data.range(of: Data("目录占位".utf8)))
        chapters[0].excludedRanges = [.init(lowerBound: Int64(excluded.lowerBound), upperBound: Int64(excluded.upperBound))]
        chapters[0].title = "手工目录甲"
        chapters[1].title = "手工目录乙"
        chapters[1].isSkipped = true
        try await store.updateChapters(bookID: id, chapters: chapters)
        let draft = try await store.chapterEditDraft(bookID: id, chapterID: chapters[0].id)
        XCTAssertFalse(draft.body.contains("目录占位"))
        do { _ = try await store.saveChapterEdit(draft, title: " ", body: draft.body); XCTFail("Empty title accepted") }
        catch { XCTAssertEqual(error as? AudiobookChapterTextEditError, .emptyTitle) }
        do { _ = try await store.saveChapterEdit(draft, title: draft.title, body: "\n "); XCTFail("Empty body accepted") }
        catch { XCTAssertEqual(error as? AudiobookChapterTextEditError, .emptyBody) }
        _ = try await store.saveChapterEdit(draft, title: draft.title, body: draft.body)
        let unchangedChapters = try await store.chapters(for: id)
        XCTAssertEqual(unchangedChapters, chapters)
        let changed = try await store.saveChapterEdit(draft, title: draft.title, body: "用户正文🧑🏽‍💻。")
        let result = try await store.chapters(for: id)
        XCTAssertEqual(result.map(\.title), ["手工目录甲", "手工目录乙"])
        XCTAssertTrue(result[1].isSkipped)
        XCTAssertTrue(result[0].excludedRanges.isEmpty)
        let saved = try await store.chapterEditDraft(bookID: id, chapterID: changed.chapterID)
        XCTAssertEqual(saved.body, "用户正文🧑🏽‍💻。")
        do { _ = try await store.saveChapterEdit(draft, title: draft.title, body: "旧草稿不能再提交。"); XCTFail("Stale source accepted") }
        catch { XCTAssertEqual(error as? AudiobookChapterTextEditError, .staleDraft) }
        let oldPath = try XCTUnwrap(try sqlite(root, sql: "SELECT canonical_rel_path FROM sources WHERE id = '\(preview.sourceID)';").first?.first)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(oldPath)), source.utf8Data)
    }

    func testImportPersistsPreparedBytesAndImmutableReference() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = Data("他提到住在鄉間許多年的那位十分熟悉各種禮節的老監\r\n生。".utf8)
        let preview = try AudiobookTXTImporter.prepare(rawData: raw)
        let store = try AudiobookProjectStore(root: root)
        let id = try await store.importBook(preview)
        let rows = try sqlite(root, sql: "SELECT source_kind, preparation_version FROM sources WHERE book_id = '\(id)' AND id = '\(preview.sourceID)';")
        XCTAssertEqual(rows, [["working", AudiobookTextPreparation.version]])
        let reopened = try AudiobookProjectStore(root: root)
        let work = try await reopened.workingSourceSnapshot(bookID: id)
        let reference = try await reopened.referenceSourceIndex(for: id)
        XCTAssertEqual(work.sourceIndex, preview.sourceIndex)
        XCTAssertEqual(work.workingSHA256, preview.preparedText.workingSHA256)
        XCTAssertEqual(reference.utf8Data, raw)
        let originalPath = try XCTUnwrap(try sqlite(root, sql: "SELECT original_rel_path FROM sources WHERE id = '\(preview.sourceID)';").first?.first)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(originalPath)), raw)
    }

    func testCorruptWorkingSourceDoesNotFallBackToReference() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = try AudiobookTXTImporter.prepare(rawData: Data("第一章\n完整的文本。".utf8))
        let store = try AudiobookProjectStore(root: root)
        let id = try await store.importBook(preview)
        _ = try await store.workingSourceSnapshot(bookID: id) // Warm caches must not hide corruption.
        let path = try XCTUnwrap(try sqlite(root, sql: "SELECT canonical_rel_path FROM sources WHERE id = '\(preview.sourceID)';").first?.first)
        try Data("损坏文本".utf8).write(to: root.appendingPathComponent(path))
        do { _ = try await store.workingSourceSnapshot(bookID: id); XCTFail("Corrupt working source accepted") }
        catch { XCTAssertEqual(error as? AudiobookStoreError, .workingSourceChanged) }
        let reference = try await store.referenceSourceIndex(for: id)
        XCTAssertEqual(reference.utf8Data, preview.referenceUTF8)
    }

    func testFailedPreparationKeepsActiveRevision() async throws {
        let fixture = try makeFrozenFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try AudiobookProjectStore(root: fixture.root)
        await store.setSimulateDiskFull(true)
        do { _ = try await store.prepareWorkingRevision(bookID: fixture.bookID, expectedSourceID: fixture.sourceID); XCTFail("Expected failure") }
        catch { XCTAssertEqual(error as? AudiobookStoreError, .diskFull) }
        let book = try await store.book(id: fixture.bookID)
        XCTAssertEqual(book.sourceID, fixture.sourceID)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(fixture.candidate.relativeAssetPath)), fixture.wav)
    }

    func testLegacyUpgradeDoesNotRewriteSourceOrAudioAndPreparationIsExplicit() async throws {
        let fixture = try makeFrozenFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let originalRows = try sqlite(fixture.root, sql: "SELECT id, sha256, canonical_rel_path FROM sources;")
        let store = try AudiobookProjectStore(root: fixture.root)
        XCTAssertEqual(try sqlite(fixture.root, sql: "SELECT id, sha256, canonical_rel_path FROM sources;"), originalRows)
        XCTAssertEqual(try sqlite(fixture.root, sql: "SELECT source_kind FROM sources;"), [["reference"]])
        do { _ = try await store.workingSourceSnapshot(bookID: fixture.bookID); XCTFail("Legacy source used for new production") }
        catch { XCTAssertEqual(error as? AudiobookStoreError, .workingTextPreparationRequired) }
        let oldChapters = try await store.chapters(for: fixture.bookID)
        let id = try await store.prepareWorkingRevision(bookID: fixture.bookID, expectedSourceID: fixture.sourceID)
        XCTAssertNotEqual(id, fixture.sourceID)
        let working = try await store.workingSourceSnapshot(bookID: fixture.bookID)
        XCTAssertEqual(working.sourceID, id)
        let chapters = try await store.chapters(for: fixture.bookID)
        XCTAssertTrue(Set(chapters.map(\.id)).isDisjoint(with: oldChapters.map(\.id)))
        XCTAssertEqual(try sqlite(fixture.root, sql: "SELECT COUNT(*) FROM chapters;"), [["2"]])
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(fixture.candidate.relativeAssetPath)), fixture.wav)
        do { _ = try await store.prepareWorkingRevision(bookID: fixture.bookID, expectedSourceID: fixture.sourceID); XCTFail("Stale CAS accepted") }
        catch { XCTAssertEqual(error as? AudiobookStoreError, .workingSourceChanged) }
        let reopened = try AudiobookProjectStore(root: fixture.root)
        let saved = try await reopened.workingSourceSnapshot(bookID: fixture.bookID)
        XCTAssertEqual(saved, working)
        XCTAssertTrue(try sqlite(fixture.root, sql: "PRAGMA foreign_key_check;").isEmpty)
    }

    func testRevisionRollbackSwitchesPointerAndKeepsBothSources() async throws {
        let fixture = try makeFrozenFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try AudiobookProjectStore(root: fixture.root)
        let next = try await store.prepareWorkingRevision(bookID: fixture.bookID, expectedSourceID: fixture.sourceID)
        try await store.activateSourceRevision(bookID: fixture.bookID, sourceID: fixture.sourceID, expectedSourceID: next)
        let old = try await store.book(id: fixture.bookID)
        XCTAssertEqual(old.sourceID, fixture.sourceID)
        let oldChapters = try await store.chapters(for: fixture.bookID)
        XCTAssertEqual(oldChapters.map(\.id), [fixture.chapterID])
        try await store.activateSourceRevision(bookID: fixture.bookID, sourceID: next, expectedSourceID: fixture.sourceID)
        let working = try await store.workingSourceSnapshot(bookID: fixture.bookID)
        XCTAssertEqual(working.sourceID, next)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(fixture.candidate.relativeAssetPath)), fixture.wav)
    }

    func testHistoricalArtifactsDoNotBlockEditingFreshWorkingChapters() async throws {
        let fixture = try makeFrozenFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try AudiobookProjectStore(root: fixture.root)
        _ = try await store.prepareWorkingRevision(bookID: fixture.bookID, expectedSourceID: fixture.sourceID)
        var chapters = try await store.chapters(for: fixture.bookID)
        chapters[0].title = "新文本待核对章节"
        try await store.updateChapters(bookID: fixture.bookID, chapters: chapters)
        let old = try await store.chapters(for: fixture.bookID, sourceID: fixture.sourceID)
        XCTAssertEqual(old.map(\.id), [fixture.chapterID])
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(fixture.candidate.relativeAssetPath)), fixture.wav)
    }

    func testFrozenV6UpgradeOnlyAddsMetadata() async throws {
        let fixture = try makeFrozenFixture(schemaVersion: 6)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rows = try sqlite(fixture.root, sql: "SELECT id, sha256, canonical_rel_path FROM sources;")
        let store = try AudiobookProjectStore(root: fixture.root)
        XCTAssertEqual(try sqlite(fixture.root, sql: "SELECT id, sha256, canonical_rel_path FROM sources;"), rows)
        XCTAssertEqual(try sqlite(fixture.root, sql: "PRAGMA user_version;"), [["7"]])
        XCTAssertEqual(try sqlite(fixture.root, sql: "SELECT source_kind, COALESCE(preparation_version, 'none') FROM sources;"), [["reference", "none"]])
        let chapters = try await store.chapters(for: fixture.bookID)
        XCTAssertEqual(chapters.map(\.id), [fixture.chapterID])
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(fixture.candidate.relativeAssetPath)), fixture.wav)
        XCTAssertTrue(try sqlite(fixture.root, sql: "PRAGMA foreign_key_check;").isEmpty)
    }

    private struct FrozenV5Fixture {
        let root: URL
        let bookID: UUID
        let sourceID: UUID
        let chapterID: UUID
        let candidate: AudiobookRenderCandidate
        let wav: Data
    }

    /// DDL comes from a checked-in historical SQL file, never from the current store.
    private func makeFrozenFixture(schemaVersion: Int = 5) throws -> FrozenV5Fixture {
        let root = try makeTempRoot()
        #if SWIFT_PACKAGE
        let fixtureURL = try XCTUnwrap(Bundle.module.url(
            forResource: "audiobook-schema-v\(schemaVersion)", withExtension: "sql", subdirectory: "Fixtures"
        ))
        #else
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/audiobook-schema-v\(schemaVersion).sql")
        #endif
        _ = try sqlite(root, sql: String(contentsOf: fixtureURL, encoding: .utf8))
        let bookID = UUID(), sourceID = UUID(), chapterID = UUID()
        let source = Data("历史夹具正文。".utf8)
        let sourceDirectory = root.appendingPathComponent("books/\(bookID.uuidString)/source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try source.write(to: sourceDirectory.appendingPathComponent("original.txt"))
        try source.write(to: sourceDirectory.appendingPathComponent("canonical.txt"))
        let wav = Self.makeDeterministicWAV(pcmSamples: Array(repeating: 1200, count: 480))
        let candidate = AudiobookRenderCandidate(
            bookID: bookID, chapterID: chapterID, fragmentID: UUID(), generation: 1,
            relativeAssetPath: "books/\(bookID.uuidString)/audio/historical.wav",
            fileSHA256: AudiobookDigest.sha256Hex(wav),
            pcmSHA256: try AudioDigest.sha256HexOfPCM(in: wav), frameCount: 480,
            dependencyDigest: "historical-dependency"
        )
        let assetURL = root.appendingPathComponent(candidate.relativeAssetPath)
        try FileManager.default.createDirectory(at: assetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try wav.write(to: assetURL)
        let sha = AudiobookDigest.sha256Hex(source)
        _ = try sqlite(root, sql: """
            INSERT INTO books (id, source_id, title, source_sha256, canonical_byte_count, scalar_count,
                original_encoding, analysis_state, production_state, listenable_state, created_at, updated_at)
            VALUES ('\(bookID)', '\(sourceID)', '历史作品', '\(sha)', \(source.count), 7,
                'utf-8', 'notStarted', 'idle', 'noneAvailable', 100, 100);
            INSERT INTO sources VALUES ('\(sourceID)', '\(bookID)', '\(sha)', \(source.count), 7, 'utf-8',
                'books/\(bookID)/source/original.txt', 'books/\(bookID)/source/canonical.txt', 100);
            INSERT INTO chapters (id, book_id, source_id, ordinal, title, lower_bound, upper_bound, excluded_ranges_json, current_chapter_revision_id, previous_chapter_revision_id) VALUES ('\(chapterID)', '\(bookID)', '\(sourceID)', 0, '历史章节',
                0, \(source.count), '[]', NULL, NULL);
            INSERT INTO render_candidates (id, book_id, chapter_id, fragment_id, task_id, generation,
                relative_asset_path, file_sha256, pcm_sha256, frame_count, sample_rate, dependency_digest,
                is_receipt_verified, created_at)
            VALUES ('\(candidate.id)', '\(bookID)', '\(chapterID)', '\(candidate.fragmentID)', '\(candidate.taskID)', 1,
                '\(candidate.relativeAssetPath)', '\(candidate.fileSHA256)', '\(candidate.pcmSHA256)', 480, 48000,
                'historical-dependency', 0, 100);
            """)
        return FrozenV5Fixture(root: root, bookID: bookID, sourceID: sourceID, chapterID: chapterID,
                               candidate: candidate, wav: wav)
    }

    func testFrozenV5MissingColumnsMigratesAndImportsWithoutLosingAssets() async throws {
        let fixture = try makeFrozenFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertEqual(try sqlite(fixture.root, sql: "PRAGMA user_version;"), [["5"]])
        XCTAssertEqual(try sqlite(fixture.root, sql: "SELECT name FROM pragma_table_info('books') WHERE name = 'analysis_failure_json';"), [])
        XCTAssertEqual(try sqlite(fixture.root, sql: "SELECT name FROM pragma_table_info('chapters') WHERE name = 'is_skipped';"), [])
        let identities = try sqlite(fixture.root, sql: "SELECT id, source_id FROM books;")
        let assets = try sqlite(fixture.root, sql: "SELECT id, fragment_id, relative_asset_path, file_sha256, pcm_sha256 FROM render_candidates;")

        let store = try AudiobookProjectStore(root: fixture.root)
        let preview = try AudiobookTXTImporter.prepare(rawData: Data("第一章\n迁移后新增的作品。".utf8), suggestedTitle: "新增作品")
        let importedID = try await store.importBook(preview)
        XCTAssertNotEqual(importedID, fixture.bookID)
        XCTAssertEqual(try sqlite(fixture.root, sql: "SELECT id, source_id FROM books WHERE id = '\(fixture.bookID)';"), identities)
        XCTAssertEqual(try sqlite(fixture.root, sql: "SELECT id, fragment_id, relative_asset_path, file_sha256, pcm_sha256 FROM render_candidates;"), assets)
        let chapters = try await store.chapters(for: fixture.bookID)
        XCTAssertEqual(chapters.map(\.id), [fixture.chapterID])
        XCTAssertEqual(chapters.first?.sourceID, fixture.sourceID)
        XCTAssertEqual(chapters.first?.isSkipped, false)
        let verified = try await store.verifyCandidateAsset(fixture.candidate)
        XCTAssertTrue(verified)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(fixture.candidate.relativeAssetPath)), fixture.wav)

        try await store.setChapterSkipped(bookID: fixture.bookID, chapterID: fixture.chapterID, skipped: true)
        var book = try await store.book(id: fixture.bookID)
        XCTAssertNil(book.analysisFailure)
        book.analysisState = .failed
        book.analysisFailure = AudiobookAnalysisFailure(code: "fixture_failure", message: "请重试分析。",
                                                        failedAt: Date(timeIntervalSince1970: 123), failedWindowOrdinal: 2)
        try await store.updateBook(book)
        let reopened = try AudiobookProjectStore(root: fixture.root)
        let savedBook = try await reopened.book(id: fixture.bookID)
        let savedChapters = try await reopened.chapters(for: fixture.bookID)
        XCTAssertEqual(savedBook.analysisFailure, book.analysisFailure)
        XCTAssertEqual(savedChapters.first?.isSkipped, true)
        let books = try await reopened.listBooks()
        XCTAssertEqual(Set(books.map(\.id)), [fixture.bookID, importedID])
        XCTAssertEqual(try sqlite(fixture.root, sql: "PRAGMA user_version;"), [["7"]])
        XCTAssertTrue(try sqlite(fixture.root, sql: "PRAGMA foreign_key_check;").isEmpty)
        let backup = fixture.root.appendingPathComponent("library.schema5.backup.sqlite3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(try sqliteDatabase(backup, sql: "PRAGMA user_version;"), [["5"]])
        XCTAssertEqual(try sqliteDatabase(backup, sql: "SELECT id, source_id FROM books;"), identities)
        XCTAssertEqual(try sqliteDatabase(backup, sql: "SELECT id, fragment_id, relative_asset_path, file_sha256, pcm_sha256 FROM render_candidates;"), assets)
        XCTAssertEqual(try sqliteDatabase(backup, sql: "SELECT name FROM pragma_table_info('books') WHERE name = 'analysis_failure_json';"), [])
        XCTAssertEqual(try sqliteDatabase(backup, sql: "SELECT name FROM pragma_table_info('chapters') WHERE name = 'is_skipped';"), [])
    }

    private func sqlite(_ root: URL, sql: String) throws -> [[String]] {
        try sqliteDatabase(root.appendingPathComponent("library.sqlite3"), sql: sql)
    }

    private func sqliteDatabase(_ databaseURL: URL, sql: String) throws -> [[String]] {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK,
              let db else { throw ServiceAPIClientError.invalidResponse }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        // exec is intentional here: fixtures include multiple DDL statements.
        if sql.hasPrefix("SELECT") || sql == "PRAGMA user_version;" || sql == "PRAGMA foreign_key_check;" {
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw ServiceAPIClientError.invalidContract("fixture_query")
            }
            defer { sqlite3_finalize(statement) }
            var rows: [[String]] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else {
                    throw ServiceAPIClientError.invalidContract("fixture_query_step")
                }
                rows.append((0..<sqlite3_column_count(statement)).map { index in
                    sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "<NULL>"
                })
            }
            return rows
        }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw ServiceAPIClientError.invalidContract("fixture_ddl")
        }
        return []
    }

    private func schemaShape(_ root: URL) throws -> [String: [[String]]] {
        let tables = try sqlite(root, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name;")
        var result: [String: [[String]]] = [:]
        for row in tables {
            let table = try XCTUnwrap(row.first)
            result["\(table).columns"] = try sqlite(root, sql: "SELECT name, type, [notnull], dflt_value, pk FROM pragma_table_info('\(table)') ORDER BY name;")
            result["\(table).foreignKeys"] = try sqlite(root, sql: "SELECT seq, [table], [from], [to], on_update, on_delete, match FROM pragma_foreign_key_list('\(table)') ORDER BY [table], [from], seq;")
            result["\(table).indexes"] = try sqlite(root, sql: "SELECT l.name, l.[unique], l.origin, l.partial, x.seqno, x.name, x.[desc], x.coll FROM pragma_index_list('\(table)') l JOIN pragma_index_xinfo(l.name) x WHERE x.[key] = 1 ORDER BY l.name, x.seqno;")
        }
        return result
    }

    private func storedRows(_ root: URL) throws -> [String: [[String]]] {
        let tables = try sqlite(root, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name;")
        var result: [String: [[String]]] = [:]
        for row in tables {
            let table = try XCTUnwrap(row.first)
            result[table] = try sqlite(root, sql: "SELECT * FROM \(table) ORDER BY rowid;")
        }
        return result
    }

    func testFrozenV5PartiallyOrFullyPresentColumnsUpgradeIdempotently() async throws {
        for existingColumns in [["is_skipped"], ["analysis_failure_json"], ["is_skipped", "analysis_failure_json"]] {
            let fixture = try makeFrozenFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let failure = AudiobookAnalysisFailure(code: "preserved_failure", message: "请重试。", failedAt: Date(timeIntervalSince1970: 123))
            if existingColumns.contains("is_skipped") {
                _ = try sqlite(fixture.root, sql: "ALTER TABLE chapters ADD COLUMN is_skipped INTEGER NOT NULL DEFAULT 0; UPDATE chapters SET is_skipped = 1;")
            }
            if existingColumns.contains("analysis_failure_json") {
                let json = try XCTUnwrap(String(data: JSONEncoder().encode(failure), encoding: .utf8))
                _ = try sqlite(fixture.root, sql: "ALTER TABLE books ADD COLUMN analysis_failure_json TEXT; UPDATE books SET analysis_failure_json = '\(json)';")
            }
            let store = try AudiobookProjectStore(root: fixture.root)
            let book = try await store.book(id: fixture.bookID)
            let chapters = try await store.chapters(for: fixture.bookID)
            XCTAssertEqual(book.analysisFailure, existingColumns.contains("analysis_failure_json") ? failure : nil)
            XCTAssertEqual(chapters.first?.isSkipped, existingColumns.contains("is_skipped"))
            let shape = try schemaShape(fixture.root), rows = try storedRows(fixture.root)
            _ = try AudiobookProjectStore(root: fixture.root)
            XCTAssertEqual(try schemaShape(fixture.root), shape)
            XCTAssertEqual(try storedRows(fixture.root), rows)
            XCTAssertEqual(try sqlite(fixture.root, sql: "PRAGMA user_version;"), [["7"]])
        }
    }

    func testFrozenV5MigrationFailureRollsBackAndCanRetry() async throws {
        let fixture = try makeFrozenFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Adding is_skipped succeeds before validation encounters this incompatible existing column.
        _ = try sqlite(fixture.root, sql: "ALTER TABLE books ADD COLUMN analysis_failure_json INTEGER;")
        let shape = try schemaShape(fixture.root), rows = try storedRows(fixture.root)
        XCTAssertThrowsError(try AudiobookProjectStore(root: fixture.root))
        XCTAssertEqual(try sqlite(fixture.root, sql: "PRAGMA user_version;"), [["5"]])
        XCTAssertEqual(try schemaShape(fixture.root), shape, "事务失败必须撤销先添加的 is_skipped")
        XCTAssertEqual(try storedRows(fixture.root), rows)
        let backup = fixture.root.appendingPathComponent("library.schema5.backup.sqlite3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(try sqliteDatabase(backup, sql: "PRAGMA user_version;"), [["5"]])
        XCTAssertEqual(try sqliteDatabase(backup, sql: "SELECT * FROM books;"), rows["books"])
        XCTAssertEqual(try sqliteDatabase(backup, sql: "SELECT name FROM pragma_table_info('chapters') WHERE name = 'is_skipped';"), [])
        _ = try sqlite(fixture.root, sql: "ALTER TABLE books DROP COLUMN analysis_failure_json;")
        let recovered = try AudiobookProjectStore(root: fixture.root)
        let book = try await recovered.book(id: fixture.bookID)
        XCTAssertEqual(book.sourceID, fixture.sourceID)
        let preview = try AudiobookTXTImporter.prepare(rawData: Data("第一章\n失败后可以重试迁移。".utf8), suggestedTitle: "重试后导入")
        _ = try await recovered.importBook(preview)
        XCTAssertEqual(try sqlite(fixture.root, sql: "PRAGMA user_version;"), [["7"]])
        XCTAssertEqual(try sqlite(fixture.root, sql: "SELECT COUNT(*) FROM books;"), [["2"]])
        let verified = try await recovered.verifyCandidateAsset(fixture.candidate)
        XCTAssertTrue(verified)
    }

    func testCurrentSchemaRejectsStructuralDamageWithoutMutatingData() throws {
        let corruptions = [
            "ALTER TABLE books DROP COLUMN analysis_failure_json;",
            "ALTER TABLE chapters DROP COLUMN is_skipped;",
            "DROP TABLE pronunciation_bindings;",
            "DROP INDEX idx_chapters_book_ordinal; CREATE INDEX idx_chapters_book_ordinal ON chapters(book_id, title);",
            "DROP TABLE production_checkpoints; CREATE TABLE production_checkpoints (book_id TEXT PRIMARY KEY NOT NULL, checkpoint_json TEXT NOT NULL);",
            "DROP TABLE production_checkpoints; CREATE TABLE production_checkpoints (book_id TEXT PRIMARY KEY NOT NULL, checkpoint_json INTEGER NOT NULL, FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE);",
            "DROP TABLE production_checkpoints; CREATE TABLE production_checkpoints (book_id TEXT PRIMARY KEY NOT NULL, checkpoint_json TEXT, FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE);",
            "DROP TABLE production_checkpoints; CREATE TABLE production_checkpoints (book_id TEXT NOT NULL, checkpoint_json TEXT NOT NULL, FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE);",
            "ALTER TABLE chapters DROP COLUMN is_skipped; ALTER TABLE chapters ADD COLUMN is_skipped INTEGER NOT NULL DEFAULT 1;",
        ]
        for corruption in corruptions {
            let fixture = try makeFrozenFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            _ = try AudiobookProjectStore(root: fixture.root)
            _ = try sqlite(fixture.root, sql: corruption)
            let shape = try schemaShape(fixture.root), rows = try storedRows(fixture.root)
            XCTAssertThrowsError(try AudiobookProjectStore(root: fixture.root), corruption)
            XCTAssertEqual(try schemaShape(fixture.root), shape, corruption)
            XCTAssertEqual(try storedRows(fixture.root), rows, corruption)
            XCTAssertEqual(try sqlite(fixture.root, sql: "PRAGMA user_version;"), [["7"]])
        }
    }

    func testUnversionedNonemptyDatabaseIsRejectedWithoutMutation() throws {
        let fixture = try makeFrozenFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try sqlite(fixture.root, sql: "PRAGMA user_version = 0;")
        let shape = try schemaShape(fixture.root), rows = try storedRows(fixture.root)
        XCTAssertThrowsError(try AudiobookProjectStore(root: fixture.root))
        XCTAssertEqual(try sqlite(fixture.root, sql: "PRAGMA user_version;"), [["0"]])
        XCTAssertEqual(try schemaShape(fixture.root), shape)
        XCTAssertEqual(try storedRows(fixture.root), rows)
    }

    func testFrozenV5MigratedSchemaMatchesFreshDatabase() throws {
        let fixture = try makeFrozenFixture(), freshRoot = try makeTempRoot()
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: freshRoot)
        }
        _ = try AudiobookProjectStore(root: fixture.root)
        _ = try AudiobookProjectStore(root: freshRoot)
        XCTAssertEqual(try schemaShape(fixture.root), try schemaShape(freshRoot))
        XCTAssertEqual(try sqlite(fixture.root, sql: "PRAGMA user_version;"), try sqlite(freshRoot, sql: "PRAGMA user_version;"))
    }

    private func makeLegacyCopy(_ fixture: ChapterEditFixture, schemaVersion: Int = 1) throws -> URL {
        precondition(schemaVersion == 1 || schemaVersion == 2)
        let copy = try makeTempRoot()
        let assets = fixture.root.appendingPathComponent("books", isDirectory: true)
        if FileManager.default.fileExists(atPath: assets.path) {
            try FileManager.default.copyItem(at: assets, to: copy.appendingPathComponent("books", isDirectory: true))
        }
        var source: OpaquePointer?
        var destination: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.root.appendingPathComponent("library.sqlite3").path, &source), SQLITE_OK)
        XCTAssertEqual(sqlite3_open(copy.appendingPathComponent("library.sqlite3").path, &destination), SQLITE_OK)
        let sourceDB = try XCTUnwrap(source), destinationDB = try XCTUnwrap(destination)
        defer { sqlite3_close(sourceDB); sqlite3_close(destinationDB) }
        let backup = try XCTUnwrap(sqlite3_backup_init(destinationDB, "main", sourceDB, "main"))
        XCTAssertEqual(sqlite3_backup_step(backup, -1), SQLITE_DONE)
        XCTAssertEqual(sqlite3_backup_finish(backup), SQLITE_OK)
        _ = try sqlite(copy, sql: """
            ALTER TABLE voice_bindings RENAME TO fixture_old_bindings;
            CREATE TABLE voice_bindings (
                book_id TEXT NOT NULL, role_id TEXT NOT NULL, voice_id TEXT NOT NULL,
                voice_revision TEXT\(schemaVersion == 1 ? " NOT NULL" : ""), model_revision TEXT NOT NULL,
                is_synthesis_ready INTEGER NOT NULL, allowed_speed REAL NOT NULL,
                caller_seed INTEGER, binding_digest TEXT NOT NULL,
                PRIMARY KEY (book_id, role_id),
                FOREIGN KEY (book_id, role_id) REFERENCES characters(book_id, id) ON DELETE CASCADE
            );
            INSERT INTO voice_bindings SELECT book_id, role_id, voice_id, voice_revision, model_revision, is_synthesis_ready, allowed_speed, caller_seed, binding_digest FROM fixture_old_bindings;
            DROP TABLE fixture_old_bindings;
            DROP TABLE IF EXISTS voice_registration_intents;
            DROP TABLE IF EXISTS casting_revisions;
            PRAGMA user_version = \(schemaVersion);
            """)
        for column in ["voice_policy_json", "manual_tier", "voice_traits_json", "required_voice_traits_json"] {
            // Only the synthetic copy is downgraded to the historical fixture shape.
            _ = try sqlite(copy, sql: "ALTER TABLE characters DROP COLUMN \(column);")
        }
        return copy
    }

    func testLegacyPolicyMigratesAsLockedUnknown() async throws {
        let fixture = try await makeChapterEditFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let old = AudiobookVoiceBinding(roleID: fixture.narrator.id, voiceID: "legacy", voiceRevision: "v1", modelRevision: "unknown")
        try await fixture.store.saveVoiceBinding(bookID: fixture.bookID, binding: old)
        let copy = try makeLegacyCopy(fixture, schemaVersion: 2)
        defer { try? FileManager.default.removeItem(at: copy) }
        let migrated = try AudiobookProjectStore(root: copy)
        XCTAssertGreaterThanOrEqual(Int(try XCTUnwrap(try sqlite(copy, sql: "PRAGMA user_version;").first?.first)) ?? 0, 3)
        let policies = try sqlite(copy, sql: "SELECT voice_policy_json FROM characters;")
        XCTAssertTrue(policies.contains { $0.first?.contains("legacyUnknown") == true && $0.first?.contains("true") == true })
        let bindings = try await migrated.voiceBindings(for: fixture.bookID)
        XCTAssertEqual(bindings[fixture.narrator.id]?.voiceRevision, "v1")
        XCTAssertEqual(bindings[fixture.narrator.id]?.modelRevision, "unknown")
    }

    func testPolicyMigrationKeepsUnknownIdentity() async throws {
        let fixture = try await makeChapterEditFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let copy = try makeLegacyCopy(fixture, schemaVersion: 2)
        defer { try? FileManager.default.removeItem(at: copy) }
        let migrated = try AudiobookProjectStore(root: copy)
        let bindings = try await migrated.voiceBindings(for: fixture.bookID)
        XCTAssertTrue(bindings.isEmpty)
        XCTAssertEqual(try sqlite(copy, sql: "SELECT actual_voice_revision, actual_model_revision FROM voice_bindings;"), [])
        XCTAssertTrue(try sqlite(copy, sql: "PRAGMA foreign_key_check;").isEmpty)
    }

    func testPolicyMigrationInterruptionRecovers() async throws {
        let fixture = try await makeChapterEditFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let copy = try makeLegacyCopy(fixture, schemaVersion: 2)
        defer { try? FileManager.default.removeItem(at: copy) }
        _ = try sqlite(copy, sql: "ALTER TABLE characters ADD COLUMN voice_policy_json TEXT;")
        let before = try sqlite(copy, sql: "SELECT * FROM books;")
        XCTAssertThrowsError(try AudiobookProjectStore(root: copy))
        XCTAssertEqual(try sqlite(copy, sql: "PRAGMA user_version;"), [["2"]])
        XCTAssertEqual(try sqlite(copy, sql: "SELECT * FROM books;"), before)
        _ = try sqlite(copy, sql: "ALTER TABLE characters DROP COLUMN voice_policy_json;")
        let recovered = try AudiobookProjectStore(root: copy)
        let books = try await recovered.listBooks()
        XCTAssertEqual(books.count, 1)
    }

    func testNullableVoiceRevisionMigrationPreservesAllRows() async throws {
        let fixture = try await makeChapterEditFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await seedChapterEditArtifact(.annotation, fixture: fixture)
        try await seedChapterEditArtifact(.renderCandidate, fixture: fixture)
        try await seedChapterEditArtifact(.chapterRevision, fixture: fixture)
        let candidates = try await fixture.store.candidates(for: fixture.bookID)
        let candidate = try XCTUnwrap(candidates.first)
        let adopted = AudiobookChapterRevision(bookID: fixture.bookID, chapterID: fixture.chapter.id,
            sourceID: fixture.chapter.sourceID, revisionNumber: 2,
            orderedBindings: [.init(fragmentID: candidate.fragmentID, candidateID: candidate.id,
                sourceRange: fixture.atom.sourceRange, dependencyDigest: candidate.dependencyDigest)], totalFrameCount: candidate.frameCount)
        try await fixture.store.saveChapterRevision(adopted, makeCurrent: true)
        let expectedRevisions = try await fixture.store.chapterRevisions(for: fixture.bookID, chapterID: fixture.chapter.id)
        let binding = AudiobookVoiceBinding(roleID: fixture.narrator.id, voiceID: "system", voiceRevision: "legacy", modelRevision: "legacy")
        try await fixture.store.saveVoiceBinding(bookID: fixture.bookID, binding: binding)
        let copy = try makeLegacyCopy(fixture)
        defer { try? FileManager.default.removeItem(at: copy) }
        let tables = ["books", "sources", "chapters", "characters", "annotations", "voice_bindings", "render_candidates", "chapter_revisions"]
        let projections = ["characters": "id, book_id, display_name, aliases_json, is_narrator, is_major, allow_shared_minor_voice, evidences_json, first_lower_bound, first_upper_bound, chapter_ids_json", "voice_bindings": "book_id, role_id, voice_id, voice_revision, model_revision, is_synthesis_ready, allowed_speed, caller_seed, binding_digest"]
        let before = try tables.map { try sqlite(copy, sql: "SELECT \(projections[$0] ?? "*") FROM \($0) ORDER BY 1, 2;") }
        let migrated = try AudiobookProjectStore(root: copy)
        XCTAssertEqual(try sqlite(copy, sql: "PRAGMA user_version;"), [[String(AudiobookStoreSchema.currentUserVersion)]] )
        XCTAssertEqual(try tables.map { try sqlite(copy, sql: "SELECT \(projections[$0] ?? "*") FROM \($0) ORDER BY 1, 2;") }, before)
        XCTAssertTrue(try sqlite(copy, sql: "PRAGMA foreign_key_check;").isEmpty)
        let saved = try await migrated.voiceBindings(for: fixture.bookID)
        XCTAssertEqual(saved[fixture.narrator.id], binding)
        let verified = try await migrated.verifyCandidateAsset(candidate)
        let revisions = try await migrated.chapterRevisions(for: fixture.bookID, chapterID: fixture.chapter.id)
        let chapters = try await migrated.chapters(for: fixture.bookID)
        XCTAssertTrue(verified, "迁移后旧 WAV 可读取且文件与 PCM 摘要均匹配")
        XCTAssertEqual(revisions, expectedRevisions)
        XCTAssertEqual(chapters.first(where: { $0.id == adopted.chapterID })?.currentChapterRevisionID, adopted.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.appendingPathComponent("library.schema1.backup.sqlite3").path))
    }

    func testIdentityMigrationFailureLeavesSchemaOneIntact() async throws {
        let fixture = try await makeChapterEditFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let copy = try makeLegacyCopy(fixture)
        defer { try? FileManager.default.removeItem(at: copy) }
        _ = try sqlite(copy, sql: "CREATE TABLE voice_bindings_v2 (fixture_marker TEXT);")
        let before = try sqlite(copy, sql: "SELECT * FROM books;")
        XCTAssertThrowsError(try AudiobookProjectStore(root: copy))
        XCTAssertEqual(try sqlite(copy, sql: "PRAGMA user_version;"), [["1"]])
        XCTAssertEqual(try sqlite(copy, sql: "SELECT * FROM books;"), before)
        XCTAssertEqual(try sqlite(copy, sql: "SELECT name FROM sqlite_master WHERE name = 'voice_bindings';"), [["voice_bindings"]])
    }

    func testSchemaTwoRoundTripsSystemMissingRevision() async throws {
        let fixture = try await makeChapterEditFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let binding = AudiobookVoiceBinding(roleID: fixture.narrator.id, voiceID: "system", voiceRevision: nil, modelRevision: String(repeating: "a", count: 40))
        try await fixture.store.saveVoiceBinding(bookID: fixture.bookID, binding: binding)
        let reopened = try AudiobookProjectStore(root: fixture.root)
        let saved = try await reopened.voiceBindings(for: fixture.bookID)
        XCTAssertEqual(saved[fixture.narrator.id], binding)
        XCTAssertEqual(try sqlite(fixture.root, sql: "SELECT voice_revision FROM voice_bindings;"), [["<NULL>"]])
    }

    private func makeCastingFixture() async throws -> (AudiobookProjectStore, URL, UUID, EffectiveCapabilitySnapshot) {
        let root = try makeTempRoot(), store = try AudiobookProjectStore(root: root)
        let preview = try AudiobookTXTImporter.prepare(rawData: Data("第一章 灯塔\n海雾漫过栈桥。\n有人点亮灯火。\n远处传来钟声。\n".utf8), suggestedTitle: "选角夹具")
        let bookID = try await store.importBook(preview)
        var roles = try await store.characters(for: bookID)
        roles += [AudiobookCharacter(bookID: bookID, displayName: "甲", isMajor: false), AudiobookCharacter(bookID: bookID, displayName: "乙", isMajor: false)]
        try await store.saveCharacters(bookID: bookID, characters: roles)
        let chapter = try await store.chapters(for: bookID)[0]
        let atoms = try await store.atoms(for: bookID, chapterID: chapter.id).filter { $0.kind != .formatting }
        let annotations = atoms.enumerated().map { i, atom in
            AudiobookAnnotation(bookID: bookID, chapterID: chapter.id, windowID: UUID(), atomID: atom.id,
                sourceRange: atom.sourceRange, assignment: .assigned(roleID: roles[i % roles.count].id))
        }
        try await store.saveAnnotations(bookID: bookID, annotations: annotations)
        var book = try await store.book(id: bookID); book.analysisState = .allWindowsValidated
        try await store.updateBook(book)
        let model = ConfiguredModelIdentity(assurance: .configuredCatalog, catalogRevision: String(repeating: "a", count: 40))
        let descriptor = SafeVoiceDescriptor(voiceMode: "system", locales: [], styleTags: [], pitchBand: "unknown", timbreFamily: "unknown", baselinePace: "unknown", sourceType: "system_preset", metadataMethod: "declared_only")
        let operation = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"parameters":{"speed":{"status":"supported","minimum":0.25,"maximum":4}}}"#.utf8))
        let voices = (0..<2).map { SafeVoiceEntry(id: "v\($0)", name: "声音\($0)", mode: "system", isSystem: true, isDefault: true, available: true,
            availabilityReason: .available, voiceRevision: nil, voiceIdentityAssurance: .legacy, model: model, descriptors: descriptor,
            operations: ["http_speech": operation], productionReady: true) }
        return (store, root, bookID, EffectiveCapabilitySnapshot(serviceInstanceEpoch: "p0", catalogRevision: "p0", snapshotID: "p0", profile: "p0", models: ["tts": model], voices: voices, operations: [:], guarantees: [:]))
    }

    func testVoiceRegistrationRecoversAtEveryCommitBoundary() async throws {
        for stage in AudiobookRegistrationCrashStage.allCases {
            let (store, root, book, snapshot) = try await makeCastingFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let catalogURL = root.appendingPathComponent("catalog.json")
            let catalog = VoiceCatalogStore(storageURL: catalogURL)
            let controller = AudiobookCastController(store: store, capabilityProvider: { snapshot }, voiceCatalog: catalog)
            let roles = try await store.characters(for: book)
            let role = try XCTUnwrap(roles.first(where: { !$0.isNarrator }))
            let otherPreview = try AudiobookTXTImporter.prepare(rawData: Data("第一章\n另一作品。".utf8), suggestedTitle: "另一作品")
            let otherBook = try await store.importBook(otherPreview)
            let otherRoles = try await store.characters(for: otherBook)
            let otherNarrator = try XCTUnwrap(otherRoles.first)
            let otherBinding = AudiobookVoiceBinding(roleID: otherNarrator.id, voiceID: "v0", voiceRevision: nil,
                modelRevision: String(repeating: "a", count: 40))
            try await store.saveVoiceBinding(bookID: otherBook, binding: otherBinding)
            let context = try await controller.makeVoiceReturnContext(bookID: book, roleID: role.id)
            let binding = AudiobookVoiceBinding(roleID: role.id, voiceID: "v1", voiceRevision: nil, modelRevision: String(repeating: "a", count: 40))
            await controller.setRegistrationCrashStage(stage)
            do {
                try await controller.registerVoiceReturn(context: context, activeBookID: book, binding: binding, creationSource: .instantClone)
                XCTFail("预期边界故障 \(stage)")
            } catch {}
            let reopened = try AudiobookProjectStore(root: root)
            let restartedCatalog = VoiceCatalogStore(storageURL: catalogURL)
            _ = await restartedCatalog.refresh()
            let restarted = AudiobookCastController(store: reopened, capabilityProvider: { snapshot }, voiceCatalog: restartedCatalog)
            try await restarted.recoverVoiceRegistrations(bookID: book)
            try await restarted.recoverVoiceRegistrations(bookID: book)
            let bindings = try await reopened.voiceBindings(for: book)
            XCTAssertEqual(bindings[role.id], binding, "\(stage)")
            let intents = try await reopened.voiceRegistrationIntents(bookID: book, includeCompleted: true)
            XCTAssertEqual(intents.count, 1)
            XCTAssertEqual(intents.first?.phase, .completed)
            let meta = await restartedCatalog.metadata(for: "v1")
            XCTAssertEqual(meta?.creationSource, .instantClone)
            XCTAssertEqual(meta?.visibilityScope, .bookExclusive)
            XCTAssertEqual(meta?.originBookID, book)
            XCTAssertEqual(meta?.originRoleID, role.id)
            let crossBookActive = await restartedCatalog.isVoiceActiveForBook(voiceID: "v1", currentBookID: otherBook)
            XCTAssertTrue(crossBookActive, "恢复后的声音应跨书可用：\(stage)")
            let recoveredCatalog = await restartedCatalog.refresh()
            XCTAssertTrue(recoveredCatalog.permits(try XCTUnwrap(snapshot.voices.first { $0.id == "v1" }), bookID: otherBook))
            let otherSavedBindings = try await reopened.voiceBindings(for: otherBook)
            let otherSavedRoles = try await reopened.characters(for: otherBook)
            XCTAssertEqual(otherSavedBindings, [otherNarrator.id: otherBinding])
            XCTAssertEqual(otherSavedRoles, otherRoles)
            XCTAssertTrue(try sqlite(root, sql: "PRAGMA foreign_key_check;").isEmpty)
        }
    }

    func testVoiceRegistrationRecoveryNeverOverwritesNewChoice() async throws {
        let (store, root, book, snapshot) = try await makeCastingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = VoiceCatalogStore(storageURL: root.appendingPathComponent("catalog.json"))
        let controller = AudiobookCastController(store: store, capabilityProvider: { snapshot }, voiceCatalog: catalog)
        let roles = try await store.characters(for: book)
        let role = try XCTUnwrap(roles.first(where: { !$0.isNarrator }))
        let context = try await controller.makeVoiceReturnContext(bookID: book, roleID: role.id)
        let binding = AudiobookVoiceBinding(roleID: role.id, voiceID: "v1", voiceRevision: nil, modelRevision: String(repeating: "a", count: 40))
        await controller.setRegistrationCrashStage(.afterIntentRegistered)
        do { try await controller.registerVoiceReturn(context: context, activeBookID: book, binding: binding, creationSource: .voiceDesign) } catch {}
        let newer = AudiobookVoiceBinding(roleID: role.id, voiceID: "v0", voiceRevision: nil, modelRevision: String(repeating: "a", count: 40))
        try await store.saveVoiceBinding(bookID: book, binding: newer)
        let restarted = AudiobookCastController(store: store, capabilityProvider: { snapshot }, voiceCatalog: catalog)
        try await restarted.recoverVoiceRegistrations(bookID: book)
        let saved = try await store.voiceBindings(for: book)
        XCTAssertEqual(saved[role.id], newer)
        let intents = try await store.voiceRegistrationIntents(bookID: book, includeCompleted: true)
        XCTAssertEqual(intents.first?.phase, .needsReview)
        let catalogActual2 = await catalog.metadata(for: "v1")?.visibilityScope
        XCTAssertEqual(catalogActual2, .bookExclusive)
    }

    func testBatchImpactAndUndoPreserveAdoptedVersion() async throws {
        let (store, root, book, snapshot) = try await makeCastingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = VoiceCatalogStore()
        let controller = AudiobookCastController(store: store, capabilityProvider: { snapshot }, voiceCatalog: catalog)
        let roles = try await store.characters(for: book)
        let narrator = try XCTUnwrap(roles.first(where: \.isNarrator))
        let chapters = try await store.chapters(for: book)
        let chapter = try XCTUnwrap(chapters.first)
        let atoms = try await store.atoms(for: book, chapterID: chapter.id)
        let atom = try XCTUnwrap(atoms.first(where: { $0.kind != .formatting }))
        let fixture = ChapterEditFixture(root: root, store: store, bookID: book, chapter: chapter, atom: atom, narrator: narrator)
        try await seedChapterEditArtifact(.fragment, fixture: fixture)
        try await seedChapterEditArtifact(.renderCandidate, fixture: fixture)
        try await seedChapterEditArtifact(.chapterRevision, fixture: fixture)
        let adoptedCandidates = try await store.candidates(for: book)
        let adoptedCandidate = try XCTUnwrap(adoptedCandidates.first)
        let adopted = AudiobookChapterRevision(bookID: book, chapterID: chapter.id, sourceID: chapter.sourceID, revisionNumber: 2,
            orderedBindings: [.init(fragmentID: adoptedCandidate.fragmentID, candidateID: adoptedCandidate.id,
                sourceRange: atom.sourceRange, dependencyDigest: adoptedCandidate.dependencyDigest)], totalFrameCount: adoptedCandidate.frameCount)
        try await store.saveChapterRevision(adopted, makeCurrent: true)
        let oldHistory = try await store.chapterRevisions(for: book, chapterID: chapter.id)
        let oldCandidates = try await store.candidates(for: book)
        let first = AudiobookVoiceBinding(roleID: narrator.id, voiceID: "v0", voiceRevision: nil, modelRevision: String(repeating: "a", count: 40))
        try await controller.bindVoice(bookID: book, roleID: narrator.id, binding: first)
        let second = AudiobookVoiceBinding(roleID: narrator.id, voiceID: "v1", voiceRevision: nil, modelRevision: String(repeating: "a", count: 40))
        let plan = try await store.prepareVoiceReplacement(bookID: book, bindings: [second], snapshot: snapshot, catalog: await catalog.refresh())
        XCTAssertEqual(plan.affectedRoleIDs, [narrator.id])
        XCTAssertFalse(plan.affectedFragmentIDs.isEmpty)
        do { _ = try await controller.bindVoicesBatch(bookID: book, bindings: [second]); XCTFail("默认批量入口不可覆盖既有配声") } catch {}
        try await controller.applyCastingPlan(bookID: book, plan: plan, acknowledgedIssueIDs: plan.requiredAcknowledgements)
        let restart = AudiobookCastController(store: try AudiobookProjectStore(root: root), capabilityProvider: { snapshot }, voiceCatalog: catalog)
        try await restart.undoLastCastingChange(bookID: book)
        let restored = try await store.voiceBindings(for: book)
        let history = try await store.chapterRevisions(for: book, chapterID: chapter.id)
        let candidates = try await store.candidates(for: book)
        XCTAssertEqual(restored[narrator.id], first)
        XCTAssertEqual(history, oldHistory)
        XCTAssertEqual(candidates, oldCandidates)
        let current = try await store.chapters(for: book)
        XCTAssertEqual(current.first(where: { $0.id == chapter.id })?.currentChapterRevisionID, adopted.id)
        let assetValid = try await store.verifyCandidateAsset(try XCTUnwrap(candidates.first))
        XCTAssertTrue(assetValid)
    }

    func testSharingPolicyToggleHasIndependentUndoAfterRestart() async throws {
        let (store, root, book, snapshot) = try await makeCastingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = VoiceCatalogStore()
        let controller = AudiobookCastController(store: store, capabilityProvider: { snapshot }, voiceCatalog: catalog)
        let initialRoles = try await store.characters(for: book)
        let roleID = try XCTUnwrap(initialRoles.first { !$0.isNarrator }?.id)
        let binding = AudiobookVoiceBinding(roleID: roleID, voiceID: "v1", voiceRevision: nil, modelRevision: String(repeating: "a", count: 40))
        try await controller.bindVoice(bookID: book, roleID: roleID, binding: binding)
        let originalRoles = try await store.characters(for: book)
        let role = try XCTUnwrap(originalRoles.first { $0.id == roleID })
        let originalBindings = try await store.voiceBindings(for: book)
        XCTAssertEqual(role.effectiveVoicePolicy.sharingPolicy, .exclusive)
        try await controller.setAllowSharedMinorVoice(bookID: book, roleID: role.id, allowed: true)
        let reopened = try AudiobookProjectStore(root: root)
        let restarted = AudiobookCastController(store: reopened, capabilityProvider: { snapshot }, voiceCatalog: catalog)
        try await restarted.undoLastCastingChange(bookID: book)
        let restoredRoles = try await reopened.characters(for: book)
        let restoredBindings = try await reopened.voiceBindings(for: book)
        XCTAssertEqual(restoredRoles.first { $0.id == role.id }, role)
        XCTAssertEqual(restoredBindings, originalBindings)
        // Repeating the same explicit policy must not consume another undo step.
        try await restarted.setAllowSharedMinorVoice(bookID: book, roleID: role.id, allowed: false)
        try await restarted.undoLastCastingChange(bookID: book)
        let unbound = try await reopened.voiceBindings(for: book)
        XCTAssertTrue(unbound.isEmpty)
        let beforeUnboundEdit = try await reopened.characters(for: book)
        try await restarted.setAllowSharedMinorVoice(bookID: book, roleID: role.id, allowed: true)
        try await restarted.undoLastCastingChange(bookID: book)
        let afterUnboundUndo = try await reopened.characters(for: book)
        XCTAssertEqual(afterUnboundUndo, beforeUnboundEdit)
    }

    func testManualPolicyAndTraitsRoundTripWithoutChangingTier() async throws {
        let (store, root, book, _) = try await makeCastingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var roles = try await store.characters(for: book)
        let index = try XCTUnwrap(roles.firstIndex(where: { !$0.isNarrator }))
        roles[index].manualTier = .lead
        roles[index].voicePolicy = .init(sharingPolicy: .sharedMinor, bindingOrigin: .manual, isLocked: true)
        var traits = AudiobookVoiceTraits(); traits.gender = .init(value: "neutral", source: .manual, confidence: 1)
        roles[index].voiceTraitsOverride = traits
        try await store.saveCharacters(bookID: book, characters: roles)
        let reopened = try AudiobookProjectStore(root: root)
        let saved = try await reopened.characters(for: book)
        XCTAssertEqual(saved.first(where: { $0.id == roles[index].id }), roles[index])
        let refreshed = AudiobookCastRegistry.computeRoleDialogueStats(characters: saved, annotations: [], availableVoiceCount: 0)
        XCTAssertEqual(refreshed.statsByRoleID[roles[index].id]?.tier, .lead)
        XCTAssertEqual(refreshed.updatedCharacters, saved)
    }

    func testManualReplacementCannotBypassRequiredTraits() async throws {
        let (store, root, book, snapshot) = try await makeCastingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var roles = try await store.characters(for: book)
        let index = try XCTUnwrap(roles.firstIndex(where: { !$0.isNarrator }))
        var traits = AudiobookVoiceTraits(); traits.gender = .init(value: "female", source: .manual, confidence: 1)
        roles[index].requiredVoiceTraits = traits
        try await store.saveCharacters(bookID: book, characters: roles)
        let binding = AudiobookVoiceBinding(roleID: roles[index].id, voiceID: "v1", voiceRevision: nil, modelRevision: String(repeating: "a", count: 40))
        let catalog = VoiceCatalogStore()
        let plan = try await store.prepareVoiceReplacement(bookID: book, bindings: [binding], snapshot: snapshot, catalog: await catalog.refresh())
        let controller = AudiobookCastController(store: store, capabilityProvider: { snapshot }, voiceCatalog: catalog)
        do { try await controller.applyCastingPlan(bookID: book, plan: plan, acknowledgedIssueIDs: plan.requiredAcknowledgements); XCTFail("必需画像条件不能被手工入口绕过") } catch {}
        let bindings = try await store.voiceBindings(for: book)
        XCTAssertTrue(bindings.isEmpty)
    }

    func testRegistrationMigrationRollsBackAndPreservesLaterWorks() async throws {
        let fixture = try await makeChapterEditFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let copy = try makeLegacyCopy(fixture)
        defer { try? FileManager.default.removeItem(at: copy) }
        _ = try AudiobookProjectStore(root: copy)
        _ = try sqlite(copy, sql: "DROP TABLE voice_registration_intents; DROP TABLE casting_revisions; CREATE TABLE casting_revisions (fixture_marker TEXT); PRAGMA user_version = 3;")
        let before = try sqlite(copy, sql: "SELECT * FROM books;")
        XCTAssertThrowsError(try AudiobookProjectStore(root: copy))
        XCTAssertEqual(try sqlite(copy, sql: "PRAGMA user_version;"), [["3"]])
        XCTAssertEqual(try sqlite(copy, sql: "SELECT * FROM books;"), before)
        XCTAssertEqual(try sqlite(copy, sql: "SELECT name FROM sqlite_master WHERE name = 'voice_registration_intents';"), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.appendingPathComponent("library.schema3.backup.sqlite3").path))
        _ = try sqlite(copy, sql: "DROP TABLE casting_revisions;")
        let migrated = try AudiobookProjectStore(root: copy)
        let later = try AudiobookTXTImporter.prepare(rawData: Data("第一章\n迁移后新增的作品。".utf8), suggestedTitle: "新增作品")
        _ = try await migrated.importBook(later)
        let reopened = try AudiobookProjectStore(root: copy)
        let books = try await reopened.listBooks()
        XCTAssertEqual(books.count, 2)
        XCTAssertTrue(try sqlite(copy, sql: "PRAGMA foreign_key_check;").isEmpty)
        let preserved = try sqlite(copy, sql: "SELECT * FROM books ORDER BY id;")
        _ = try sqlite(copy, sql: "PRAGMA user_version = 999;")
        XCTAssertThrowsError(try AudiobookProjectStore(root: copy))
        XCTAssertEqual(try sqlite(copy, sql: "SELECT * FROM books ORDER BY id;"), preserved)
        XCTAssertEqual(try sqlite(copy, sql: "PRAGMA user_version;"), [["999"]])
    }

    func testCatalogChangeRejectsPlanBeforeCommit() async throws {
        let (store, root, book, snapshot) = try await makeCastingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = VoiceCatalogStore()
        let plan = try await store.prepareCastingPlan(bookID: book, snapshot: snapshot, catalog: await catalog.refresh())
        try await catalog.archiveVoices(voiceIDs: [try XCTUnwrap(plan.proposedBindings.values.first?.voiceID)])
        let controller = AudiobookCastController(store: store, capabilityProvider: { snapshot }, voiceCatalog: catalog)
        do { try await controller.applyCastingPlan(bookID: book, plan: plan, acknowledgedIssueIDs: plan.requiredAcknowledgements); XCTFail("catalog changed") } catch {}
        let bindings = try await store.voiceBindings(for: book)
        XCTAssertTrue(bindings.isEmpty)
    }

    func testProvenSilentLockedBindingDoesNotConsumeSpeakingCapacity() async throws {
        let (store, root, book, snapshot) = try await makeCastingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let roles = try await store.characters(for: book)
        let narrator = try XCTUnwrap(roles.first(where: \.isNarrator))
        let minor = try XCTUnwrap(roles.first(where: { !$0.isNarrator }))
        let silent = try XCTUnwrap(roles.first(where: { $0.id != narrator.id && $0.id != minor.id }))
        var anns = try await store.annotations(for: book)
        for i in anns.indices { anns[i].assignment = .assigned(roleID: i == 0 ? narrator.id : minor.id) }
        try await store.saveAnnotations(bookID: book, annotations: anns)
        let frozen = AudiobookVoiceBinding(roleID: silent.id, voiceID: "v0", voiceRevision: nil, modelRevision: String(repeating: "a", count: 40), isSynthesisReady: false)
        try await store.saveVoiceBinding(bookID: book, binding: frozen)
        let plan = try await store.prepareCastingPlan(bookID: book, snapshot: snapshot, catalog: .init())
        XCTAssertTrue(plan.isApplicable, "完整分析证明零台词时，保留旧绑定但不占发声预算")
        XCTAssertEqual(plan.narratorVoiceCount + plan.exclusiveVoiceCount + plan.sharedVoiceCount, 2)
        XCTAssertEqual(plan.proposedBindings[silent.id], frozen)
        let controller = AudiobookCastController(store: store, capabilityProvider: { snapshot }, voiceCatalog: VoiceCatalogStore())
        try await controller.applyCastingPlan(bookID: book, plan: plan, acknowledgedIssueIDs: plan.requiredAcknowledgements)
        let saved = try await store.voiceBindings(for: book)
        XCTAssertEqual(saved[silent.id], frozen)
        XCTAssertEqual(Set([saved[narrator.id]?.voiceID, saved[minor.id]?.voiceID].compactMap { $0 }).count, 2)
        try await controller.confirmCast(bookID: book, revisionID: controller.currentCastRevisionID(for: book))
        anns[anns.count - 1].assignment = .assigned(roleID: silent.id)
        try await store.saveAnnotations(bookID: book, annotations: anns)
        let changed = try await store.prepareCastingPlan(bookID: book, snapshot: snapshot, catalog: .init())
        XCTAssertFalse(changed.isApplicable, "角色重新发声后必须重新满足独占与容量约束")
        do {
            try await controller.confirmCast(bookID: book, revisionID: controller.currentCastRevisionID(for: book))
            XCTFail("重新发声的旧未就绪绑定不能被确认")
        } catch {}
        let preserved = try await store.voiceBindings(for: book)
        XCTAssertEqual(preserved, saved)
    }

    func testStalePlanDoesNotOverwriteNewCast() async throws {
        let (store, root, book, snapshot) = try await makeCastingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await store.prepareCastingPlan(bookID: book, snapshot: snapshot, catalog: .init())
        var role = try await store.characters(for: book)[0]; role.displayName += "修改"
        try await store.upsertCharacter(role)
        do { try await store.saveCastingPlan(bookID: book, plan: plan); XCTFail("stale cast") } catch {}
        let bindings = try await store.voiceBindings(for: book)
        XCTAssertTrue(bindings.isEmpty)
    }

    func testChangedAnnotationsInvalidatePlanWithoutCharacterChange() async throws {
        let (store, root, book, snapshot) = try await makeCastingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await store.prepareCastingPlan(bookID: book, snapshot: snapshot, catalog: .init())
        var anns = try await store.annotations(for: book); anns[0].annotationRevision += 1
        try await store.saveAnnotations(bookID: book, annotations: anns)
        do { try await store.saveCastingPlan(bookID: book, plan: plan); XCTFail("stale annotations") } catch {}
        let bindings = try await store.voiceBindings(for: book)
        XCTAssertTrue(bindings.isEmpty)
    }

    func testLastInvalidBindingRollsBackWholeBatch() async throws {
        let (store, root, book, snapshot) = try await makeCastingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await store.prepareCastingPlan(bookID: book, snapshot: snapshot, catalog: .init())
        XCTAssertTrue(plan.isApplicable)
        let last = try XCTUnwrap(plan.proposedBindings.keys.sorted { $0.uuidString < $1.uuidString }.last)
        _ = try sqlite(root, sql: "CREATE TRIGGER fail_last BEFORE INSERT ON voice_bindings WHEN NEW.role_id = '\(last.uuidString)' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;")
        let roles = try await store.characters(for: book)
        do { try await store.saveCastingPlan(bookID: book, plan: plan); XCTFail("injected last write must fail") } catch {}
        let afterRoles = try await store.characters(for: book), bindings = try await store.voiceBindings(for: book)
        XCTAssertEqual(afterRoles, roles)
        XCTAssertTrue(bindings.isEmpty)
    }

    func testCancelledApplyDoesNotCommitPartialBindings() async throws {
        let (store, root, book, snapshot) = try await makeCastingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await store.prepareCastingPlan(bookID: book, snapshot: snapshot, catalog: .init())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.saveCastingPlan(bookID: book, plan: plan)
        }
        do { try await task.value; XCTFail("cancelled apply") } catch {}
        let bindings = try await store.voiceBindings(for: book)
        XCTAssertTrue(bindings.isEmpty)
    }

    func testChangedPlanCannotReuseRiskAcknowledgement() async throws {
        let (store, root, book, snapshot) = try await makeCastingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await store.prepareCastingPlan(bookID: book, snapshot: snapshot, catalog: .init())
        XCTAssertFalse(first.requiredAcknowledgements.isEmpty)
        var anns = try await store.annotations(for: book); anns[0].annotationRevision += 1
        try await store.saveAnnotations(bookID: book, annotations: anns)
        let second = try await store.prepareCastingPlan(bookID: book, snapshot: snapshot, catalog: .init())
        let controller = AudiobookCastController(store: store, capabilityProvider: { snapshot }, voiceCatalog: VoiceCatalogStore())
        do { try await controller.applyCastingPlan(bookID: book, plan: second, acknowledgedIssueIDs: first.requiredAcknowledgements); XCTFail("old acknowledgement") } catch {}
        let unchanged = try await store.voiceBindings(for: book); XCTAssertTrue(unchanged.isEmpty)
        try await controller.applyCastingPlan(bookID: book, plan: second, acknowledgedIssueIDs: second.requiredAcknowledgements)
        let saved = try await store.voiceBindings(for: book); XCTAssertEqual(saved.count, second.proposedBindings.count)
    }

    func testSilentRoleExemptionRequiresCompleteAnnotations() async throws {
        let (store, root, bookID, snapshot) = try await makeCastingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let roles = try await store.characters(for: bookID), narrator = try XCTUnwrap(roles.first(where: \.isNarrator))
        var anns = try await store.annotations(for: bookID)
        for i in anns.indices { anns[i].assignment = .assigned(roleID: narrator.id) }
        let binding = AudiobookVoiceBinding(roleID: narrator.id, voiceID: "v0", voiceRevision: nil, modelRevision: String(repeating: "a", count: 40))
        try await store.saveVoiceBinding(bookID: bookID, binding: binding)
        try await store.saveAnnotations(bookID: bookID, annotations: Array(anns.prefix(1)))
        let revision = AudiobookCastRegistry.castRevisionID(bookID: bookID, characters: roles)
        do { try await store.saveCastConfirmation(bookID: bookID, revisionID: revision, voiceSetDigest: nil); XCTFail("partial annotations cannot prove silence") } catch {}
        try await store.saveAnnotations(bookID: bookID, annotations: anns)
        try await store.saveCastConfirmation(bookID: bookID, revisionID: revision, voiceSetDigest: nil)
        let plan = try await store.prepareCastingPlan(bookID: bookID, snapshot: snapshot, catalog: .init())
        XCTAssertEqual(plan.proposedBindings.count, 1)
    }

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
