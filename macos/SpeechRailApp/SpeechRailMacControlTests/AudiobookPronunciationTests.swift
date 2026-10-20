import Foundation
import SQLite3
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

final class AudiobookPronunciationTests: XCTestCase {
    // MARK: - Fixtures

    private final class FakeClient: AudiobookPronunciationClient, @unchecked Sendable {
        private let lock = NSLock()
        private var storedRevision: String?
        private var storedEntries: [PronunciationEntry] = []
        private var storedSetID: String?
        var saveCount = 0
        private var conflictNext = false
        var deleteCount = 0

        var revision: String? { lock.withLock { storedRevision } }
        var entries: [PronunciationEntry] { lock.withLock { storedEntries } }

        func forceConflictOnNextSave() {
            lock.withLock { conflictNext = true }
        }

        func simulateExternalUpdate(entries: [PronunciationEntry], revision: String = "pr_external") {
            lock.withLock {
                storedEntries = entries
                storedRevision = revision
            }
        }

        func fetchPronunciationSetSummaries() async throws -> [PronunciationSetSummary] {
            lock.withLock {
                guard let storedSetID, let storedRevision else { return [] }
                return [
                    PronunciationSetSummary(
                        id: storedSetID,
                        revision: storedRevision,
                        revoked: false,
                        entryCount: storedEntries.count
                    )
                ]
            }
        }

        func fetchPronunciationSet(id: String, revision: String) async throws -> PronunciationSet {
            try lock.withLock {
                guard storedRevision == revision else {
                    throw ServiceAPIClientError.http(
                        statusCode: 404, code: "pronunciation_revision_not_found",
                        message: "missing", requestID: nil, retryable: false
                    )
                }
                return PronunciationSet(id: id, revision: revision, entries: storedEntries, revoked: false)
            }
        }

        func upsertPronunciationSet(
            id: String,
            expectedRevision: String?,
            entries: [PronunciationEntry]
        ) async throws -> PronunciationSet {
            try lock.withLock {
                if conflictNext || storedRevision != expectedRevision {
                    conflictNext = false
                    throw ServiceAPIClientError.http(
                        statusCode: 409, code: "pronunciation_conflict",
                        message: "conflict", requestID: nil, retryable: false
                    )
                }
                saveCount += 1
                storedSetID = id
                storedEntries = entries.sorted { $0.id < $1.id }
                storedRevision = "pr_\(saveCount)"
                return PronunciationSet(id: id, revision: storedRevision, entries: storedEntries, revoked: false)
            }
        }

        func deletePronunciationSet(id: String) async throws {
            lock.withLock {
                deleteCount += 1
                storedRevision = nil
                storedEntries = []
            }
        }
    }

    @MainActor
    private func makeFixture() async throws -> (root: URL, store: AudiobookProjectStore, bookID: UUID) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechrail-pronunciation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try AudiobookProjectStore(root: root)
        let preview = try AudiobookTXTImporter.prepare(
            rawData: Data("第一章 风起\n\n风从山谷吹来，灯火在远处摇晃。\n".utf8),
            suggestedTitle: "发音规则夹具"
        )
        let bookID = try await store.importBook(preview)
        return (root, store, bookID)
    }

    private func makeRule(
        surface: String = "重",
        spoken: String = "chóng"
    ) -> AudiobookPronunciationController.Rule {
        AudiobookPronunciationController.Rule(surface: surface, spoken: spoken)
    }

    // MARK: - Controller

    @MainActor
    func testSaveStoresBindingAndBuildsPinnedHeader() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let client = FakeClient()
        let controller = AudiobookPronunciationController(store: fixture.store, client: client)

        await controller.load(bookID: fixture.bookID)
        XCTAssertNil(controller.binding)
        XCTAssertTrue(controller.draft.isEmpty)

        controller.addRule()
        controller.draft[0] = makeRule(surface: "重", spoken: "chóng")
        controller.addRule()
        controller.draft[1] = makeRule(surface: "NASA", spoken: "那萨")

        await controller.save(bookID: fixture.bookID)

        let binding = try XCTUnwrap(controller.binding)
        XCTAssertEqual(binding.setID, AudiobookPronunciationBinding.makeSetID(bookID: fixture.bookID))
        XCTAssertEqual(binding.revision, "pr_1")
        XCTAssertEqual(binding.headerValue, "\(binding.setID)@pr_1")
        XCTAssertEqual(binding.entries.map(\.surface).sorted(), ["NASA", "重"])
        XCTAssertEqual(controller.ruleCount, 2)
        XCTAssertEqual(controller.errorMessage, nil)

        let persisted = try await fixture.store.pronunciationBinding(for: fixture.bookID)
        XCTAssertEqual(persisted, binding)
    }

    @MainActor
    func testConflictSurfacesRefreshInsteadOfOverwriting() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let client = FakeClient()
        let controller = AudiobookPronunciationController(store: fixture.store, client: client)

        await controller.load(bookID: fixture.bookID)
        controller.addRule()
        controller.draft[0] = makeRule()
        await controller.save(bookID: fixture.bookID)
        let firstRevision = try XCTUnwrap(controller.binding?.revision)

        client.simulateExternalUpdate(
            entries: [PronunciationEntry(id: "other", surface: "行", spoken: "háng")]
        )
        controller.addRule()
        controller.draft[1] = makeRule(surface: "行", spoken: "xíng")
        await controller.save(bookID: fixture.bookID)

        XCTAssertTrue(controller.needsRefresh)
        XCTAssertEqual(controller.binding?.revision, firstRevision)
        let persistedAfterConflict = try await fixture.store.pronunciationBinding(for: fixture.bookID)
        XCTAssertEqual(persistedAfterConflict?.revision, firstRevision)
        XCTAssertEqual(client.saveCount, 1)

        await controller.refresh(bookID: fixture.bookID)
        XCTAssertFalse(controller.needsRefresh)
        XCTAssertEqual(controller.binding?.revision, "pr_external")
        XCTAssertEqual(controller.draft.map(\.surface), ["行"])
    }

    @MainActor
    func testDeleteClearsLocalPointerEvenWhenRemoteAlreadyGone() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let client = FakeClient()
        let controller = AudiobookPronunciationController(store: fixture.store, client: client)

        await controller.load(bookID: fixture.bookID)
        controller.addRule()
        controller.draft[0] = makeRule()
        await controller.save(bookID: fixture.bookID)
        XCTAssertNotNil(controller.binding)

        await controller.deleteAll(bookID: fixture.bookID)

        XCTAssertNil(controller.binding)
        XCTAssertTrue(controller.draft.isEmpty)
        let persistedAfterDelete = try await fixture.store.pronunciationBinding(for: fixture.bookID)
        XCTAssertNil(persistedAfterDelete)
        XCTAssertEqual(client.deleteCount, 1)
    }

    @MainActor
    func testValidationRejectsBlankAndDuplicateRules() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let client = FakeClient()
        let controller = AudiobookPronunciationController(store: fixture.store, client: client)
        await controller.load(bookID: fixture.bookID)

        controller.addRule()
        controller.draft[0] = makeRule(surface: "重", spoken: "chóng")
        controller.addRule()
        controller.draft[1] = makeRule(surface: "重", spoken: "zhòng")
        await controller.save(bookID: fixture.bookID)
        XCTAssertEqual(controller.errorMessage, "原文「重」出现了重复规则，请合并或删除其中一条。")
        XCTAssertEqual(client.revision, nil)

        controller.removeRule(id: controller.draft[1].id)
        controller.draft[0].spoken = "  "
        await controller.save(bookID: fixture.bookID)
        XCTAssertEqual(controller.errorMessage, "第 1 条规则的读法不能为空。")
        XCTAssertEqual(client.revision, nil)
    }

    // MARK: - Fragment dependency

    func testPronunciationInvalidatesOnlyFragmentsContainingSurface() throws {
        let text = "重庆的重是重复的重。北京天空很蓝。"
        let utf8 = Data(text.utf8)
        let source = try AudiobookSourceIndex(utf8: utf8)
        let bookID = UUID()
        let chapter = AudiobookChapter(
            bookID: bookID, sourceID: UUID(), ordinal: 0, title: "夹具",
            sourceRange: AudiobookSourceRange(lowerBound: 0, upperBound: Int64(utf8.count))
        )
        let firstRole = UUID()
        let secondRole = UUID()
        let bindings = [
            firstRole: AudiobookVoiceBinding(roleID: firstRole, voiceID: "a", voiceRevision: nil, modelRevision: "m"),
            secondRole: AudiobookVoiceBinding(roleID: secondRole, voiceID: "b", voiceRevision: nil, modelRevision: "m"),
        ]
        let firstScalars = "重庆的重是重复的重。".unicodeScalars.count
        let splitBytes = Int64(String(text.prefix(firstScalars)).utf8.count)
        func annotation(_ lower: Int64, _ upper: Int64, _ role: UUID) -> AudiobookAnnotation {
            .init(
                bookID: bookID, chapterID: chapter.id, windowID: UUID(), atomID: UUID(),
                sourceRange: .init(lowerBound: lower, upperBound: upper),
                assignment: .assigned(roleID: role)
            )
        }
        let annotations = [
            annotation(0, splitBytes, firstRole),
            annotation(splitBytes, Int64(utf8.count), secondRole),
        ]

        func plan(_ binding: AudiobookPronunciationBinding?) throws -> [AudiobookFragment] {
            try AudiobookFragmentPlanner.plan(
                chapter: chapter, annotations: annotations, bindings: bindings,
                source: source, pronunciation: binding
            )
        }

        let base = try plan(nil)
        XCTAssertEqual(base.count, 2)
        let chong = try plan(AudiobookPronunciationBinding(
            setID: "ab-test", revision: "pr_1",
            entries: [PronunciationEntry(id: "e1", surface: "重", spoken: "chóng")]
        ))
        let zhong = try plan(AudiobookPronunciationBinding(
            setID: "ab-test", revision: "pr_2",
            entries: [PronunciationEntry(id: "e1", surface: "重", spoken: "zhòng")]
        ))
        let unrelated = try plan(AudiobookPronunciationBinding(
            setID: "ab-test", revision: "pr_3",
            entries: [PronunciationEntry(id: "e2", surface: "不存在的词", spoken: "x")]
        ))

        // 命中的片段：无规则 → 规则 → 改读法，摘要应变化。
        XCTAssertNotEqual(base[0].dependencyDigest, chong[0].dependencyDigest)
        XCTAssertNotEqual(chong[0].dependencyDigest, zhong[0].dependencyDigest)
        // 未命中的片段：摘要保持稳定。
        XCTAssertEqual(base[1].dependencyDigest, chong[1].dependencyDigest)
        XCTAssertEqual(chong[1].dependencyDigest, zhong[1].dependencyDigest)
        // 不影响本片段的新规则不应触发重做。
        XCTAssertEqual(base[0].dependencyDigest, unrelated[0].dependencyDigest)
        XCTAssertEqual(base[1].dependencyDigest, unrelated[1].dependencyDigest)
    }

    // MARK: - Schema

    func testSchemaV4OpensWithPronunciationTable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechrail-pronunciation-schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("library.sqlite3").path, &db), SQLITE_OK)
        let database = try XCTUnwrap(db)
        defer { sqlite3_close(database) }
        let ddl = """
        PRAGMA journal_mode = WAL;
        CREATE TABLE books (
            id TEXT PRIMARY KEY NOT NULL,
            source_id TEXT NOT NULL,
            title TEXT NOT NULL,
            author TEXT,
            source_sha256 TEXT NOT NULL,
            canonical_byte_count INTEGER NOT NULL,
            scalar_count INTEGER NOT NULL,
            original_encoding TEXT NOT NULL,
            analysis_state TEXT NOT NULL,
            production_state TEXT NOT NULL,
            listenable_state TEXT NOT NULL,
            confirmed_cast_revision_id TEXT,
            confirmed_audition_digest TEXT,
            current_production_revision_id TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE (id, source_id)
        );
        PRAGMA user_version = 4;
        """
        XCTAssertEqual(sqlite3_exec(database, ddl, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        let store = try AudiobookProjectStore(root: root)
        let binding = try await store.pronunciationBinding(for: UUID())
        XCTAssertNil(binding)

        var check: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("library.sqlite3").path, &check), SQLITE_OK)
        let checkDB = try XCTUnwrap(check)
        defer { sqlite3_close(checkDB) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(checkDB, "PRAGMA user_version;", -1, &statement, nil), SQLITE_OK)
        let versionStatement = try XCTUnwrap(statement)
        defer { sqlite3_finalize(versionStatement) }
        XCTAssertEqual(sqlite3_step(versionStatement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(versionStatement, 0), AudiobookStoreSchema.currentUserVersion)
    }
}
