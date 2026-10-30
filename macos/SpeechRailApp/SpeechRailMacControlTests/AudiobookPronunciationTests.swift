import Foundation
import SQLite3
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

final class AudiobookPronunciationTests: XCTestCase {
    func testCrossLinePronunciationRuleMatchesWorkingText() throws {
        let raw = "他走進大廳之後提到鄉間那位住了許多年又講理學的老監\r\n生，見面之後總會先互相問候幾句。"
        let binding = AudiobookPronunciationBinding(setID: "test", revision: "pr_test", entries: [
            PronunciationEntry(id: "e1", surface: "老監生", spoken: "老監生的指定讀法")
        ])
        XCTAssertNil(binding.dependencyComponent(in: raw))
        let preview = try AudiobookTXTImporter.prepare(rawData: Data(raw.utf8))
        let working = try preview.sourceIndex.text(in: preview.sourceIndex.wholeRange)
        XCTAssertNotNil(binding.dependencyComponent(in: working))
        let unrelated = AudiobookPronunciationBinding(setID: "test", revision: "pr_other", entries: binding.entries + [
            PronunciationEntry(id: "e2", surface: "別的詞", spoken: "別的讀法")
        ])
        XCTAssertEqual(binding.dependencyComponent(in: working), unrelated.dependencyComponent(in: working))
    }

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

    private static func makeDefaultCapabilities(modelRev: String = String(repeating: "a", count: 40)) -> EffectiveCapabilitySnapshot {
        let model = ConfiguredModelIdentity(
            assurance: .configuredCatalog,
            runtimeRevision: modelRev,
            catalogRevision: modelRev
        )
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
        let ops: [String: JSONValue] = [
            "http_speech": JSONValue(.object([
                "parameters": JSONValue(.object([
                    "speed": JSONValue(.object([
                        "status": JSONValue(.string("supported")),
                        "minimum": JSONValue(.number(0.25)),
                        "maximum": JSONValue(.number(4))
                    ]))
                ]))
            ]))
        ]
        let voices = [
            SafeVoiceEntry(
                id: "v-1", name: "Voice 1", mode: "system", isSystem: true, isDefault: true,
                available: true, availabilityReason: .available, voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                voiceIdentityAssurance: .contentAddressed, model: model, descriptors: desc, operations: ops, productionReady: true
            ),
            SafeVoiceEntry(
                id: "v-2", name: "Voice 2", mode: "system", isSystem: true, isDefault: true,
                available: true, availabilityReason: .available, voiceRevision: "vr_fedcba9876543210fedcba9876543210",
                voiceIdentityAssurance: .contentAddressed, model: model, descriptors: desc, operations: ops, productionReady: true
            )
        ]
        return EffectiveCapabilitySnapshot(
            serviceInstanceEpoch: "epoch-1",
            catalogRevision: "cat-1",
            snapshotID: "snap-1",
            profile: "quality",
            models: ["tts": model, "tts_clone": model],
            voices: voices,
            operations: [:],
            guarantees: [:]
        )
    }

    func testRefreshBindingDependenciesPreservesPronunciationDigestComponent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechrail-pron-binding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let modelRev = String(repeating: "a", count: 40)
        let capabilities = Self.makeDefaultCapabilities(modelRev: modelRev)
        let store = try AudiobookProjectStore(root: root)
        let castController = AudiobookCastController(store: store, capabilityProvider: { capabilities })
        let txtURL = root.appendingPathComponent("book.txt")
        try Data("第一章 重庆\n他踏上旅途去重庆。\n".utf8).write(to: txtURL)
        let preview = try await AudiobookTXTImporter.prepare(fileURL: txtURL, encoding: .utf8)
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

        let voice1 = AudiobookVoiceBinding(
            roleID: narrator.id,
            voiceID: "v-1",
            voiceRevision: "vr_0123456789abcdef0123456789abcdef",
            modelRevision: modelRev
        )
        let voice2 = AudiobookVoiceBinding(
            roleID: narrator.id,
            voiceID: "v-2",
            voiceRevision: "vr_fedcba9876543210fedcba9876543210",
            modelRevision: modelRev
        )
        try await castController.bindVoice(bookID: bookID, roleID: narrator.id, binding: voice1)

        let pron = AudiobookPronunciationBinding(
            setID: "ab-\(bookID.uuidString.lowercased())",
            revision: "pr_1",
            entries: [PronunciationEntry(id: "e1", surface: "重庆", spoken: "崇庆")]
        )
        try await store.savePronunciationBinding(pron, bookID: bookID)

        let source = try await store.sourceIndex(for: bookID)
        let bindings = try await store.voiceBindings(for: bookID)
        let planned = try AudiobookFragmentPlanner.plan(
            chapter: chapter,
            annotations: anns,
            bindings: bindings,
            source: source,
            atoms: atoms,
            pronunciation: pron
        )
        try await store.saveFragments(bookID: bookID, chapterID: chapter.id, fragments: planned)

        try await castController.bindVoice(bookID: bookID, roleID: narrator.id, binding: voice2)
        try await castController.undoLastCastingChange(bookID: bookID)

        let storedAfterUndo = try await store.fragments(for: bookID, chapterID: chapter.id)
        XCTAssertEqual(
            storedAfterUndo.map(\.dependencyDigest),
            planned.map(\.dependencyDigest),
            "换声再撤销后 refreshBindingDependencies 必须保留 pron: 分量，与 AudiobookFragmentPlanner.plan 一致"
        )
    }

    func testSaveAndDeletePronunciationBindingRefreshesStoredFragmentDigests() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechrail-pron-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let modelRev = String(repeating: "a", count: 40)
        let capabilities = Self.makeDefaultCapabilities(modelRev: modelRev)
        let store = try AudiobookProjectStore(root: root)
        let castController = AudiobookCastController(store: store, capabilityProvider: { capabilities })
        let txtURL = root.appendingPathComponent("book.txt")
        try Data("第一章 重庆\n他踏上旅途去重庆。\n晴空万里。\n".utf8).write(to: txtURL)
        let preview = try await AudiobookTXTImporter.prepare(fileURL: txtURL, encoding: .utf8)
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
            binding: AudiobookVoiceBinding(
                roleID: narrator.id,
                voiceID: "v-1",
                voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                modelRevision: modelRev
            )
        )

        let source = try await store.sourceIndex(for: bookID)
        let bindings = try await store.voiceBindings(for: bookID)
        let baseline = try AudiobookFragmentPlanner.plan(
            chapter: chapter,
            annotations: anns,
            bindings: bindings,
            source: source,
            atoms: atoms,
            pronunciation: nil
        )
        try await store.saveFragments(bookID: bookID, chapterID: chapter.id, fragments: baseline)

        let pron = AudiobookPronunciationBinding(
            setID: "ab-\(bookID.uuidString.lowercased())",
            revision: "pr_1",
            entries: [PronunciationEntry(id: "e1", surface: "重庆", spoken: "崇庆")]
        )
        try await store.savePronunciationBinding(pron, bookID: bookID)
        let afterSave = try await store.fragments(for: bookID, chapterID: chapter.id)
        let expectedWithPron = try AudiobookFragmentPlanner.plan(
            chapter: chapter,
            annotations: anns,
            bindings: bindings,
            source: source,
            atoms: atoms,
            pronunciation: pron
        )
        XCTAssertEqual(afterSave.map(\.dependencyDigest), expectedWithPron.map(\.dependencyDigest))
        XCTAssertNotEqual(afterSave[0].dependencyDigest, baseline[0].dependencyDigest)

        try await store.deletePronunciationBinding(bookID: bookID)
        let afterDelete = try await store.fragments(for: bookID, chapterID: chapter.id)
        XCTAssertEqual(afterDelete.map(\.dependencyDigest), baseline.map(\.dependencyDigest))
    }
}
