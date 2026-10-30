import Foundation
import SQLite3
import SpeechRailControlKit

public enum AudiobookStoreError: Error, Equatable, Sendable, LocalizedError {
    case workingTextPreparationRequired
    case workingSourceChanged
    case storageUnavailable(String)
    case unsupportedSchemaVersion(found: Int32, supported: Int32)
    case schemaMismatch(String)
    case statementFailed(String)
    case bookNotFound(UUID)
    case chapterNotFound(UUID)
    case invalidRelativePath(String)
    case symlinkRejected(String)
    case invalidWAVAsset(String)
    case conflictingCandidateDigest(UUID)
    case diskFull
    case simulatedCrash(AudiobookCommitCrashStage)
    case corruptedOrMissingAsset(candidateID: UUID, relativePath: String)

    public var errorDescription: String? {
        switch self {
        case .workingTextPreparationRequired:
            "working_text_preparation_required：请先准备加工文本，再开始分析或制作。已有音频仍可收听和导出。"
        case .workingSourceChanged:
            "工作文本版本已变化，本次结果未写入。请重新开始。"
        case let .storageUnavailable(detail):
            "有声书作品库不可用：\(detail)"
        case let .unsupportedSchemaVersion(found, supported):
            "有声书数据库版本（v\(found)）高于当前应用支持的版本（v\(supported)），为保护您的数据已拒绝降级打开。"
        case let .schemaMismatch(detail):
            "作品库结构校验未通过，已停止打开以保护数据：\(detail)"
        case let .statementFailed(detail):
            "有声书数据库操作失败：\(detail)"
        case .bookNotFound:
            "找不到指定的有声书项目。"
        case .chapterNotFound:
            "找不到指定的章节。"
        case .invalidRelativePath:
            "拒绝访问项目目录外的路径。"
        case .symlinkRejected:
            "拒绝跟随符号链接。"
        case let .invalidWAVAsset(reason):
            "音频资产校验失败：\(reason)"
        case .conflictingCandidateDigest:
            "同一候选编号存在不一致的音频摘要，已拒绝覆盖。"
        case .diskFull:
            "片段保存失败：可用磁盘空间不足。"
        case let .simulatedCrash(stage):
            "模拟崩溃阶段：\(stage.rawValue)"
        case .corruptedOrMissingAsset:
            "本地音频片段缺失或校验不通过，需要重新生成该片段。"
        }
    }
}

public struct AudiobookBookSummary: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let book: AudiobookBook
    public let totalChapterCount: Int
    public let completedChapterCount: Int
    public let unknownSpeakerCount: Int
    public let characterCount: Int
    public let completedWindowCount: Int
    public let totalWindowCount: Int
    public let bookmark: AudiobookBookmark?

    public init(
        book: AudiobookBook,
        totalChapterCount: Int,
        completedChapterCount: Int,
        unknownSpeakerCount: Int,
        characterCount: Int,
        completedWindowCount: Int = 0,
        totalWindowCount: Int = 0,
        bookmark: AudiobookBookmark? = nil
    ) {
        self.id = book.id
        self.book = book
        self.totalChapterCount = totalChapterCount
        self.completedChapterCount = completedChapterCount
        self.unknownSpeakerCount = unknownSpeakerCount
        self.characterCount = characterCount
        self.completedWindowCount = completedWindowCount
        self.totalWindowCount = totalWindowCount
        self.bookmark = bookmark
    }
}

public actor AudiobookProjectStore {
    public let rootURL: URL
    private let handle = SQLiteHandle()
    private let assetJournal: AudiobookAssetJournal
    private var simulatedCrashStage: AudiobookCommitCrashStage?
    private var simulateDiskFullOnWrite: Bool = false
    private var activeAnalysisRuns: [UUID: UUID] = [:]
    private var cachedSourceIndices: [UUID: (sha256: String, index: AudiobookSourceIndex)] = [:]
    private var cachedCharactersByBook: [UUID: [AudiobookCharacter]] = [:]
    private var cachedAnnotationsByBook: [UUID: [AudiobookAnnotation]] = [:]
    private var cachedBookOrder: [UUID] = []
    private var startupRunningBookUpdatedAt: [UUID: Double] = [:]
    private var didApplyStartupRecovery = false
    private var castingScoreCache = AudiobookCastingScoreCache()
    private var verifiedWAVAssetCache: [String: (fileSize: Int64, modTime: Double, fileSHA: String, pcmSHA: String)] = [:]
    public private(set) var recoveredBookIDsHistoryForTest: [UUID] = []
    public private(set) var workingSourceSnapshotLoadCountForTest: [UUID: Int] = [:]

    public func resetDiagnosticCountersForTest() {
        recoveredBookIDsHistoryForTest.removeAll()
        workingSourceSnapshotLoadCountForTest.removeAll()
    }

    // The foreground book and a concurrently producing book can share the store without unbounded retained indexes.
    private func touchBookCache(_ bookID: UUID) {
        cachedBookOrder.removeAll { $0 == bookID }
        cachedBookOrder.append(bookID)
        while cachedBookOrder.count > 2 {
            let old = cachedBookOrder.removeFirst()
            cachedSourceIndices.removeValue(forKey: old)
            cachedCharactersByBook.removeValue(forKey: old)
            cachedAnnotationsByBook.removeValue(forKey: old)
        }
    }

    func workspaceStoreCacheCounts() -> (sourceIndices: Int, characters: Int, annotations: Int) {
        (cachedSourceIndices.count, cachedCharactersByBook.count, cachedAnnotationsByBook.count)
    }

    public static var defaultRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SpeechRail/audiobooks", isDirectory: true)
    }

    public init(root: URL) throws {
        let standardizedRoot = root.standardizedFileURL
        self.rootURL = standardizedRoot
        self.assetJournal = AudiobookAssetJournal(rootURL: standardizedRoot)

        let fm = FileManager.default
        try fm.createDirectory(at: standardizedRoot, withIntermediateDirectories: true)
        if try Self.isSymbolicLink(at: standardizedRoot) {
            throw AudiobookStoreError.symlinkRejected(standardizedRoot.lastPathComponent)
        }

        let dbURL = standardizedRoot.appendingPathComponent("library.sqlite3", isDirectory: false)
        var rawPointer: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbURL.path, &rawPointer, flags, nil) == SQLITE_OK,
              let pointer = rawPointer
        else {
            let msg = rawPointer.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed"
            if let rawPointer { sqlite3_close_v2(rawPointer) }
            throw AudiobookStoreError.storageUnavailable(msg)
        }
        self.handle.pointer = pointer

        let existingVersion = try Self.queryUserVersion(pointer)
        if existingVersion > AudiobookStoreSchema.currentUserVersion {
            sqlite3_close_v2(pointer)
            self.handle.pointer = nil
            throw AudiobookStoreError.unsupportedSchemaVersion(
                found: existingVersion,
                supported: AudiobookStoreSchema.currentUserVersion
            )
        }

        do {
            if existingVersion == 0 {
                try AudiobookStoreSchema.requireEmptyUnversionedDatabase(pointer)
            }
            if existingVersion == 1 {
                try Self.migrateNullableVoiceRevision(pointer, root: standardizedRoot)
            }
            if existingVersion > 0 && existingVersion < 3 {
                try Self.migrateRolePolicies(pointer, root: standardizedRoot)
            }
            if existingVersion > 0 && existingVersion < 4 {
                try Self.backupDatabase(pointer, root: standardizedRoot, version: 3)
                try Self.execSQL(pointer, "BEGIN IMMEDIATE;")
                do {
                    try Self.execSQL(pointer, AudiobookStoreSchema.registrationIntentsSQL)
                    try Self.execSQL(pointer, AudiobookStoreSchema.castingRevisionsSQL)
                    try Self.execSQL(pointer, "PRAGMA user_version = 4; COMMIT;")
                } catch { try? Self.execSQL(pointer, "ROLLBACK;"); throw error }
            }
            if existingVersion > 0 && existingVersion < 5 {
                try Self.backupDatabase(pointer, root: standardizedRoot, version: 4)
                try Self.execSQL(pointer, "BEGIN IMMEDIATE;")
                do {
                    try Self.execSQL(pointer, """
                        CREATE TABLE IF NOT EXISTS pronunciation_bindings (
                            book_id TEXT PRIMARY KEY NOT NULL,
                            set_id TEXT NOT NULL,
                            revision TEXT NOT NULL,
                            entries_json TEXT NOT NULL,
                            updated_at REAL NOT NULL,
                            FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
                        );
                        PRAGMA user_version = 5; COMMIT;
                        """)
                } catch { try? Self.execSQL(pointer, "ROLLBACK;"); throw error }
            }
            if existingVersion < 7 {
                if existingVersion > 0 {
                    try Self.backupDatabase(pointer, root: standardizedRoot, version: Int(existingVersion))
                }
                try Self.execSQL(pointer, "PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON;")
                try Self.execSQL(pointer, "BEGIN IMMEDIATE;")
                do {
                    for (table, column, definition) in [
                        ("chapters", "is_skipped", "INTEGER NOT NULL DEFAULT 0"),
                        ("books", "analysis_failure_json", "TEXT"),
                        ("sources", "source_kind", "TEXT NOT NULL DEFAULT 'reference'"),
                        ("sources", "reference_source_id", "TEXT"),
                        ("sources", "preparation_version", "TEXT"),
                        ("sources", "source_map_rel_path", "TEXT"),
                        ("sources", "source_map_sha256", "TEXT"),
                        ("sources", "workflow_book_json", "TEXT"),
                        ("characters", "source_id", "TEXT NOT NULL DEFAULT ''"),
                    ] where Self.tableExists(pointer, table: table)
                        && !Self.tableHasColumn(pointer, table: table, column: column) {
                        try Self.execSQL(pointer, "ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
                    }
                    try Self.execSQL(pointer, AudiobookStoreSchema.tableDefinitionsSQL)
                    try Self.execSQL(pointer, "UPDATE characters SET source_id = (SELECT source_id FROM books WHERE id = characters.book_id) WHERE source_id = '';")
                    try AudiobookStoreSchema.validate(pointer)
                    try Self.execSQL(pointer, "PRAGMA user_version = 7; COMMIT;")
                } catch {
                    try? Self.execSQL(pointer, "ROLLBACK;")
                    throw error
                }
            } else {
                try AudiobookStoreSchema.validate(pointer)
                try Self.execSQL(pointer, "PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON;")
            }
            self.startupRunningBookUpdatedAt = try Self.queryStartupRunningBookUpdatedAt(pointer)
        } catch {
            sqlite3_close_v2(pointer)
            self.handle.pointer = nil
            throw error
        }
    }

    private static func tableExists(_ db: OpaquePointer, table: String) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?;",
            -1, &statement, nil
        ) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        return table.withCString { name in
            guard sqlite3_bind_text(statement, 1, name, -1, nil) == SQLITE_OK else { return false }
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    private static func tableHasColumn(_ db: OpaquePointer, table: String, column: String) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1), String(cString: name) == column {
                return true
            }
        }
        return false
    }

    /// SQLite backup includes committed WAL pages. Never copy only the main database file.
    private static func migrateNullableVoiceRevision(_ db: OpaquePointer, root: URL) throws {
        var backupURL = root.appendingPathComponent("library.schema1.backup.sqlite3")
        if FileManager.default.fileExists(atPath: backupURL.path) {
            backupURL = root.appendingPathComponent("library.schema1.\(UUID().uuidString).backup.sqlite3")
        }
        var destination: OpaquePointer?
        guard sqlite3_open_v2(backupURL.path, &destination, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let destination else { throw AudiobookStoreError.storageUnavailable("schema_backup_open_failed") }
        defer { sqlite3_close_v2(destination) }
        guard let backup = sqlite3_backup_init(destination, "main", db, "main") else {
            throw AudiobookStoreError.storageUnavailable("schema_backup_failed")
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else {
            throw AudiobookStoreError.storageUnavailable("schema_backup_failed")
        }
        try execSQL(db, "BEGIN IMMEDIATE;")
        do {
            try execSQL(db, """
                CREATE TABLE voice_bindings_v2 (
                    book_id TEXT NOT NULL, role_id TEXT NOT NULL, voice_id TEXT NOT NULL,
                    voice_revision TEXT, model_revision TEXT NOT NULL,
                    is_synthesis_ready INTEGER NOT NULL, allowed_speed REAL NOT NULL,
                    caller_seed INTEGER, binding_digest TEXT NOT NULL,
                    PRIMARY KEY (book_id, role_id),
                    FOREIGN KEY (book_id, role_id) REFERENCES characters(book_id, id) ON DELETE CASCADE
                );
                INSERT INTO voice_bindings_v2 SELECT * FROM voice_bindings;
                DROP TABLE voice_bindings;
                ALTER TABLE voice_bindings_v2 RENAME TO voice_bindings;
                PRAGMA user_version = 2;
                COMMIT;
                """)
        } catch {
            try? execSQL(db, "ROLLBACK;")
            throw error
        }
    }

    private static func migrateRolePolicies(_ db: OpaquePointer, root: URL) throws {
        try backupDatabase(db, root: root, version: 2)
        try execSQL(db, "BEGIN IMMEDIATE;")
        do {
            try execSQL(db, """
                ALTER TABLE characters ADD COLUMN voice_policy_json TEXT;
                ALTER TABLE characters ADD COLUMN manual_tier TEXT;
                ALTER TABLE characters ADD COLUMN voice_traits_json TEXT;
                ALTER TABLE characters ADD COLUMN required_voice_traits_json TEXT;
                ALTER TABLE voice_bindings ADD COLUMN actual_voice_revision TEXT;
                ALTER TABLE voice_bindings ADD COLUMN actual_model_revision TEXT;
                UPDATE characters SET voice_policy_json = json_object(
                    'sharingPolicy', CASE WHEN is_narrator = 1 OR allow_shared_minor_voice = 0 THEN 'exclusive' ELSE 'sharedMinor' END,
                    'bindingOrigin', 'legacyUnknown', 'isLocked', json('true'))
                WHERE EXISTS (SELECT 1 FROM voice_bindings b WHERE b.book_id = characters.book_id AND b.role_id = characters.id);
                PRAGMA user_version = 3;
                COMMIT;
                """)
        } catch {
            try? execSQL(db, "ROLLBACK;")
            throw error
        }
    }

    private static func backupDatabase(_ db: OpaquePointer, root: URL, version: Int) throws {
        var url = root.appendingPathComponent("library.schema\(version).backup.sqlite3")
        if FileManager.default.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("library.schema\(version).\(UUID().uuidString).backup.sqlite3")
        }
        var raw: OpaquePointer?
        guard sqlite3_open_v2(url.path, &raw, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let destination = raw else { throw AudiobookStoreError.storageUnavailable("schema_backup_open_failed") }
        defer { sqlite3_close_v2(destination) }
        guard let backup = sqlite3_backup_init(destination, "main", db, "main") else { throw AudiobookStoreError.storageUnavailable("schema_backup_failed") }
        let step = sqlite3_backup_step(backup, -1), finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else { throw AudiobookStoreError.storageUnavailable("schema_backup_failed") }
    }

    // MARK: - Fault Injection Hooks for Deterministic Tests

    public func setSimulatedCrashStage(_ stage: AudiobookCommitCrashStage?) {
        self.simulatedCrashStage = stage
    }

    public func setSimulateDiskFull(_ enabled: Bool) {
        self.simulateDiskFullOnWrite = enabled
    }

    // MARK: - Book Import & Queries

    public func importBook(_ preview: AudiobookImportPreview) async throws -> UUID {
        let prepared = try AudiobookTextPreparation.prepare(referenceUTF8: preview.referenceUTF8)
        guard prepared == preview.preparedText, prepared.workingUTF8 == preview.canonicalUTF8,
              preview.sourceIndex.utf8Data == prepared.workingUTF8 else {
            throw AudiobookStoreError.workingSourceChanged
        }
        try AudiobookChapterPlanner.validateChapterEdits(preview.chapters, source: preview.sourceIndex)

        let bookDir = try bookDirectory(for: preview.bookID, create: true)
        let sourcesDir = bookDir.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)

        let referenceID = UUID()
        let originalRel = "books/\(preview.bookID.uuidString)/sources/\(preview.sourceID.uuidString)-original.bin"
        let canonicalRel = "books/\(preview.bookID.uuidString)/sources/\(preview.sourceID.uuidString)-source.utf8"
        let originalURL = try resolveOwnedURL(relativePath: originalRel)
        let canonicalURL = try resolveOwnedURL(relativePath: canonicalRel)

        try preview.originalBytes.write(to: originalURL, options: .atomic)
        try preview.canonicalUTF8.write(to: canonicalURL, options: .atomic)
        let referenceRel = "books/\(preview.bookID)/sources/\(referenceID)-source.utf8"
        let mapRel = "books/\(preview.bookID)/sources/\(preview.sourceID)-map.json"
        try preview.referenceUTF8.write(to: resolveOwnedURL(relativePath: referenceRel), options: .atomic)
        try JSONEncoder().encode(prepared.sourceMap).write(to: resolveOwnedURL(relativePath: mapRel), options: .atomic)

        let now = Date()
        let book = AudiobookBook(
            id: preview.bookID,
            sourceID: preview.sourceID,
            title: preview.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名书籍" : preview.title,
            author: preview.author?.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceSHA256: preview.sourceSHA256,
            canonicalByteCount: preview.canonicalByteCount,
            scalarCount: preview.scalarCount,
            originalEncoding: preview.detectedEncoding.rawValue,
            analysisState: .notStarted,
            productionState: .idle,
            listenableState: .noneAvailable,
            createdAt: now,
            updatedAt: now
        )

        var allAtoms: [AudiobookTextAtom] = []
        for chapter in preview.chapters {
            let chapterAtoms = try preview.sourceIndex.buildAtoms(for: chapter)
            allAtoms.append(contentsOf: chapterAtoms)
        }

        // Create default narrator character
        let narrator = AudiobookCharacter(
            bookID: book.id,
            displayName: "旁白",
            aliases: ["叙述"],
            isNarrator: true,
            isMajor: true,
            allowSharedMinorVoice: false,
            evidences: [],
            firstAppearanceRange: preview.chapters.first?.sourceRange,
            chapterIDs: preview.chapters.map(\.id)
        )

        try inTransaction {
            try insertBookRow(book)
            try insertSourceRow(
                bookID: book.id,
                sourceID: preview.sourceID,
                sha256: preview.sourceSHA256,
                byteCount: preview.canonicalByteCount,
                scalarCount: preview.scalarCount,
                encoding: preview.detectedEncoding.rawValue,
                originalRelPath: originalRel,
                canonicalRelPath: canonicalRel,
                createdAt: now
            )
            let referenceIndex = try AudiobookSourceIndex(utf8: preview.referenceUTF8)
            try insertSourceRow(bookID: book.id, sourceID: referenceID, sha256: referenceIndex.sourceSHA256,
                byteCount: referenceIndex.byteCount, scalarCount: referenceIndex.scalarCount,
                encoding: preview.detectedEncoding.rawValue, originalRelPath: originalRel,
                canonicalRelPath: referenceRel, createdAt: now)
            try markWorkingSource(bookID: book.id, sourceID: preview.sourceID, referenceID: referenceID, mapRel: mapRel)
            for chapter in preview.chapters {
                try upsertChapterRow(chapter)
            }
            for atom in allAtoms {
                try insertAtomRow(bookID: book.id, atom: atom)
            }
            try upsertCharacterRow(narrator)
        }

        return book.id
    }

    public func listBooks(
        after: UUID? = nil,
        limit: Int = AudiobookLimits.maxStorePageSize
    ) async throws -> [AudiobookBookSummary] {
        let clampedLimit = max(1, min(limit, AudiobookLimits.maxStorePageSize))
        let allBooks = try fetchAllBooksOrdered()
        let slice: ArraySlice<AudiobookBook>
        if let after, let index = allBooks.firstIndex(where: { $0.id == after }) {
            let start = allBooks.index(after: index)
            slice = allBooks[start..<min(allBooks.endIndex, start + clampedLimit)]
        } else {
            slice = allBooks.prefix(clampedLimit)
        }

        return try slice.map { book in
            try buildSummary(for: book)
        }
    }

    public func book(id: UUID) async throws -> AudiobookBook {
        guard let book = try fetchBook(id: id) else {
            throw AudiobookStoreError.bookNotFound(id)
        }
        return book
    }

    public func updateBook(_ book: AudiobookBook) async throws {
        var updated = book
        updated.updatedAt = Date()
        try inTransaction {
            guard try fetchBook(id: book.id)?.sourceID == book.sourceID else { throw AudiobookStoreError.workingSourceChanged }
            try upsertBookRow(updated)
        }
        // A write through this instance is current work, even if the wall clock
        // happens to produce the same stored timestamp as the startup snapshot.
        startupRunningBookUpdatedAt.removeValue(forKey: book.id)
    }

    public func beginAnalysisRun(bookID: UUID, expectedSourceID: UUID, runID: UUID) throws -> AudiobookBook {
        guard let book = try fetchBook(id: bookID), book.sourceID == expectedSourceID else {
            throw AudiobookStoreError.workingSourceChanged
        }
        activeAnalysisRuns[bookID] = runID
        return book
    }

    public func updateAnalysisBook(_ book: AudiobookBook, runID: UUID) throws {
        try inTransaction {
            guard activeAnalysisRuns[book.id] == runID else { throw AudiobookAnalysisError.cancelled }
            guard try fetchBook(id: book.id)?.sourceID == book.sourceID else { throw AudiobookStoreError.workingSourceChanged }
            var updated = book; updated.updatedAt = Date()
            try upsertBookRow(updated)
        }
        startupRunningBookUpdatedAt.removeValue(forKey: book.id)
    }

    public func endAnalysisRun(bookID: UUID, runID: UUID, paused: Bool = false) throws {
        guard activeAnalysisRuns[bookID] == runID else { return }
        if paused, var book = try fetchBook(id: bookID), book.analysisState == .running {
            book.analysisState = .paused; book.analysisFailure = nil; book.updatedAt = Date()
            try upsertBookRow(book)
        }
        activeAnalysisRuns.removeValue(forKey: bookID)
    }

    public func productionCheckpoint(for bookID: UUID) throws -> AudiobookProductionCheckpoint? {
        try withPrepared("SELECT checkpoint_json FROM production_checkpoints WHERE book_id = ?;", [.text(bookID.uuidString)]) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW, let json = columnText(stmt, 0) else { return nil }
            return try JSONDecoder().decode(AudiobookProductionCheckpoint.self, from: Data(json.utf8))
        }
    }

    public func saveProductionCheckpoint(
        _ checkpoint: AudiobookProductionCheckpoint,
        listenableState: AudiobookListenableState? = nil
    ) throws {
        let bookID = checkpoint.progress.bookID
        try inTransaction {
            guard var book = try fetchBook(id: bookID) else { throw AudiobookStoreError.bookNotFound(bookID) }
            if let sourceID = checkpoint.sourceID {
                guard sourceID == book.sourceID,
                      try sourceRecord(bookID: bookID, sourceID: sourceID).preparationVersion == checkpoint.preparationVersion else {
                    throw AudiobookStoreError.workingSourceChanged
                }
            }
            for chapterID in checkpoint.chapterIDs { try requireActiveChapter(bookID: bookID, chapterID: chapterID) }
            book.productionState = checkpoint.progress.state
            if let listenableState { book.listenableState = listenableState }
            book.updatedAt = Date()
            try upsertBookRow(book)
            try upsertProductionCheckpointRow(checkpoint)
        }
        startupRunningBookUpdatedAt.removeValue(forKey: bookID)
    }

    private func upsertProductionCheckpointRow(_ checkpoint: AudiobookProductionCheckpoint) throws {
        // Service error descriptions may contain arbitrary content. Keep them in memory only.
        var durable = checkpoint
        durable.progress.lastErrorMessage = nil
        let json = String(decoding: try JSONEncoder().encode(durable), as: UTF8.self)
        try executePrepared("""
            INSERT INTO production_checkpoints (book_id, checkpoint_json) VALUES (?, ?)
            ON CONFLICT(book_id) DO UPDATE SET checkpoint_json = excluded.checkpoint_json;
            """, [.text(durable.progress.bookID.uuidString), .text(json)])
    }

    /// A synchronous read transaction cannot be interleaved with this actor's writers.
    func loadWorkspaceInput(bookID: UUID, chapterID: UUID?) throws -> AudiobookWorkspaceInput {
        try AppPerformanceMetrics.shared.measure(.workspaceRead) {
            try inReadTransaction {
                try Task.checkCancellation()
                guard let book = try fetchBook(id: bookID) else { throw AudiobookStoreError.bookNotFound(bookID) }
                let chapters = try fetchChapters(bookID: bookID)
                let selectedID = chapterID.flatMap { id in chapters.contains(where: { $0.id == id }) ? id : nil } ?? chapters.first?.id
                let source = try readSourceIndex(bookID: bookID)
                let chapter = try chapterWorkspaceInput(bookID: bookID, chapterID: selectedID, source: source)
                let characters = try fetchCharacters(bookID: bookID)
                let bindings = try fetchVoiceBindings(bookID: bookID)
                let exports = try fetchExportRecords(bookID: bookID)
                let checkpoint = try productionCheckpoint(for: bookID)
                let annotations = try fetchAnnotations(bookID: bookID, chapterID: nil)
                cachedCharactersByBook[bookID] = characters
                cachedAnnotationsByBook[bookID] = annotations
                let digest = AudiobookCastingDigest.hash([
                    AudiobookCastingDigest.hash(book), AudiobookCastingDigest.hash(chapters),
                    AudiobookCastingDigest.hash(characters), AudiobookCastingDigest.hash(bindings.values.sorted { $0.roleID.uuidString < $1.roleID.uuidString }),
                    AudiobookCastingDigest.hash(exports), AudiobookCastingDigest.hash(checkpoint),
                    AudiobookCastingDigest.hash(annotations), chapter.revision.contentDigest
                ])
                try Task.checkCancellation()
                return .init(book: book, chapters: chapters, characters: characters, bindings: bindings, exports: exports,
                    checkpoint: checkpoint, annotations: annotations, chapter: chapter, changeToken: try workspaceChangeToken(),
                    revision: .init(sourceSHA: book.sourceSHA256, contentDigest: digest))
            }
        }
    }

    func loadChapterWorkspaceInput(bookID: UUID, chapterID: UUID?) throws -> AudiobookChapterWorkspaceInput {
        try AppPerformanceMetrics.shared.measure(.workspaceRead) {
            try inReadTransaction {
                try Task.checkCancellation()
                if let chapterID, try !fetchChapters(bookID: bookID).contains(where: { $0.id == chapterID }) {
                    throw AudiobookStoreError.chapterNotFound(chapterID)
                }
                return try chapterWorkspaceInput(bookID: bookID, chapterID: chapterID, source: readSourceIndex(bookID: bookID))
            }
        }
    }

    private func chapterWorkspaceInput(bookID: UUID, chapterID: UUID?, source: AudiobookSourceIndex) throws -> AudiobookChapterWorkspaceInput {
        let atoms = try chapterID.map { try fetchAtoms(bookID: bookID, chapterID: $0).filter { $0.kind != .formatting } } ?? []
        let annotations = try chapterID.map { try fetchAnnotations(bookID: bookID, chapterID: $0) } ?? []
        let fragments = try chapterID.map { try fetchFragments(bookID: bookID, chapterID: $0) } ?? []
        var work = AudiobookWorkspaceReadWork()
        let candidates = try fetchWorkspaceCandidates(bookID: bookID, fragmentIDs: fragments.map(\.id), work: &work)
        let digest = AudiobookCastingDigest.hash([
            chapterID?.uuidString ?? "", source.sourceSHA256, AudiobookCastingDigest.hash(atoms),
            AudiobookCastingDigest.hash(annotations), AudiobookCastingDigest.hash(fragments), AudiobookCastingDigest.hash(candidates)
        ])
        return .init(bookID: bookID, chapterID: chapterID, source: source, atoms: atoms, annotations: annotations,
            fragments: fragments, candidates: candidates, revision: .init(sourceSHA: source.sourceSHA256, contentDigest: digest), work: work, changeToken: try workspaceChangeToken())
    }

    private func fetchWorkspaceCandidates(bookID: UUID, fragmentIDs: [UUID], work: inout AudiobookWorkspaceReadWork) throws -> [AudiobookRenderCandidate] {
        var candidates: [AudiobookRenderCandidate] = []
        for start in stride(from: 0, to: fragmentIDs.count, by: 500) {
            try Task.checkCancellation()
            let ids = fragmentIDs[start..<min(start + 500, fragmentIDs.count)]
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let sql = """
                SELECT id, book_id, chapter_id, fragment_id, task_id, generation,
                       relative_asset_path, file_sha256, pcm_sha256, frame_count, sample_rate,
                       dependency_digest, request_id, receipt_digest, recipe_summary, is_receipt_verified, created_at
                FROM render_candidates WHERE book_id = ? AND fragment_id IN (\(placeholders)) ORDER BY created_at DESC;
                """
            work.candidateQueries += 1
            let args: [SQLValue] = [.text(bookID.uuidString)] + ids.map { .text($0.uuidString) }
            try withPrepared(sql, args) { statement in
                var status = sqlite3_step(statement)
                while status == SQLITE_ROW {
                    if work.candidateRowsRead.isMultiple(of: 128) { try Task.checkCancellation() }
                    work.candidateRowsRead += 1
                    if let candidate = Self.decodeCandidateRow(statement) { candidates.append(candidate) }
                    status = sqlite3_step(statement)
                }
                guard status == SQLITE_DONE else {
                    throw AudiobookStoreError.statementFailed(String(cString: sqlite3_errmsg(try requireHandle())))
                }
                work.candidateVMSteps += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0))
                work.candidateFullScanSteps += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_FULLSCAN_STEP, 0))
            }
        }
        return candidates.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
    }

    /// Cheap wakeup token; chapter content revision still decides whether projection changes.
    func workspaceChangeToken() throws -> AudiobookWorkspaceChangeToken {
        let pointer = try requireHandle()
        let externalVersion = try countRows("PRAGMA data_version;", [])
        return .init(localChanges: sqlite3_total_changes64(pointer), externalVersion: externalVersion)
    }

    public func sourceIndex(for bookID: UUID) async throws -> AudiobookSourceIndex {
        try workingSourceSnapshot(bookID: bookID).sourceIndex
    }

    public func workingSourceSnapshot(bookID: UUID) throws -> AudiobookWorkingSourceSnapshot {
        guard let book = try fetchBook(id: bookID) else { throw AudiobookStoreError.bookNotFound(bookID) }
        let metadata = try sourceRecord(bookID: bookID, sourceID: book.sourceID)
        guard metadata.kind == "working", metadata.preparationVersion == AudiobookTextPreparation.version,
              let referenceID = metadata.referenceSourceID, let mapRel = metadata.mapRel else {
            throw AudiobookStoreError.workingTextPreparationRequired
        }
        workingSourceSnapshotLoadCountForTest[bookID, default: 0] += 1
        // Revalidate disk bytes even with a warm UI cache. Never fall back to reference bytes.
        let source = try readSourceRecord(metadata)
        let reference = try readSourceRecord(sourceRecord(bookID: bookID, sourceID: referenceID))
        let mapData = try Data(contentsOf: resolveOwnedURL(relativePath: mapRel))
        guard AudiobookDigest.sha256Hex(mapData) == metadata.mapSHA256 else { throw AudiobookStoreError.workingSourceChanged }
        let map = try JSONDecoder().decode([AudiobookWorkingSourceSpan].self, from: mapData)
        try AudiobookChapterTextEditing.validateMap(map, working: source, reference: reference)
        guard source.sourceSHA256 == book.sourceSHA256 else { throw AudiobookStoreError.workingSourceChanged }
        return .init(bookID: bookID, sourceID: book.sourceID, workingSHA256: source.sourceSHA256,
                     preparationVersion: metadata.preparationVersion!, sourceIndex: source)
    }

    public func validateWorkingSource(_ snapshot: AudiobookWorkingSourceSnapshot) throws {
        guard let book = try fetchBook(id: snapshot.bookID), book.sourceID == snapshot.sourceID,
              book.sourceSHA256 == snapshot.workingSHA256 else { throw AudiobookStoreError.workingSourceChanged }
        let source = try sourceRecord(bookID: book.id, sourceID: book.sourceID)
        guard source.kind == "working", source.preparationVersion == snapshot.preparationVersion else {
            throw AudiobookStoreError.workingSourceChanged
        }
    }

    public func referenceSourceIndex(for bookID: UUID) throws -> AudiobookSourceIndex {
        guard let book = try fetchBook(id: bookID) else { throw AudiobookStoreError.bookNotFound(bookID) }
        let active = try sourceRecord(bookID: bookID, sourceID: book.sourceID)
        return try readSourceRecord(sourceRecord(bookID: bookID, sourceID: active.referenceSourceID ?? active.id))
    }

    private struct SourceRecord: Codable {
        let id: UUID
        let bookID: UUID
        let sha256: String
        let byteCount: Int64
        let scalarCount: Int
        let encoding: String
        let originalRel: String
        let canonicalRel: String
        let createdAt: Date
        var kind: String
        var referenceSourceID: UUID?
        var preparationVersion: String?
        var mapRel: String?
        var mapSHA256: String?
        var workflowJSON: String?
    }

    private func sourceRecords(bookID: UUID) throws -> [SourceRecord] {
        try withPrepared("""
            SELECT id, sha256, canonical_byte_count, scalar_count, original_encoding, original_rel_path,
                   canonical_rel_path, created_at, source_kind, reference_source_id, preparation_version, source_map_rel_path, source_map_sha256, workflow_book_json
            FROM sources WHERE book_id = ?;
            """, [.text(bookID.uuidString)]) { stmt in
            var result: [SourceRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let id = columnText(stmt, 0).flatMap(UUID.init(uuidString:)) else { continue }
                result.append(.init(id: id, bookID: bookID, sha256: columnText(stmt, 1) ?? "",
                    byteCount: columnInt(stmt, 2), scalarCount: Int(columnInt(stmt, 3)), encoding: columnText(stmt, 4) ?? "",
                    originalRel: columnText(stmt, 5) ?? "", canonicalRel: columnText(stmt, 6) ?? "",
                    createdAt: Date(timeIntervalSince1970: columnDouble(stmt, 7)), kind: columnText(stmt, 8) ?? "reference",
                    referenceSourceID: columnText(stmt, 9).flatMap(UUID.init(uuidString:)),
                    preparationVersion: columnText(stmt, 10), mapRel: columnText(stmt, 11),
                    mapSHA256: columnText(stmt, 12), workflowJSON: columnText(stmt, 13)))
            }
            return result
        }
    }

    private func sourceRecord(bookID: UUID, sourceID: UUID) throws -> SourceRecord {
        guard let record = try sourceRecords(bookID: bookID).first(where: { $0.id == sourceID }) else {
            throw AudiobookStoreError.workingSourceChanged
        }
        return record
    }

    private func readSourceRecord(_ record: SourceRecord) throws -> AudiobookSourceIndex {
        let data = try Data(contentsOf: resolveOwnedURL(relativePath: record.canonicalRel))
        var titleEvidence: [Int64: Bool]?
        if record.kind == "working" {
            guard let mapRel = record.mapRel else { throw AudiobookStoreError.workingSourceChanged }
            let mapData = try Data(contentsOf: resolveOwnedURL(relativePath: mapRel))
            guard AudiobookDigest.sha256Hex(mapData) == record.mapSHA256 else { throw AudiobookStoreError.workingSourceChanged }
            let spans = try JSONDecoder().decode([AudiobookWorkingSourceSpan].self, from: mapData)
            titleEvidence = Dictionary(uniqueKeysWithValues: spans.compactMap { span in
                span.isIsolatedTitleCandidate.map { (span.workingRange.lowerBound, $0) }
            })
        }
        let index = try AudiobookSourceIndex(utf8: data, titleEvidence: titleEvidence)
        guard index.sourceSHA256 == record.sha256, index.byteCount == record.byteCount,
              index.scalarCount == record.scalarCount else { throw AudiobookStoreError.workingSourceChanged }
        return index
    }

    private func markWorkingSource(bookID: UUID, sourceID: UUID, referenceID: UUID, mapRel: String) throws {
        try executePrepared("""
            UPDATE sources SET source_kind = 'working', reference_source_id = ?, preparation_version = ?,
                               source_map_rel_path = ?, source_map_sha256 = ? WHERE book_id = ? AND id = ?;
            """, [.text(referenceID.uuidString), .text(AudiobookTextPreparation.version), .text(mapRel),
                  .text(AudiobookDigest.sha256Hex(try Data(contentsOf: resolveOwnedURL(relativePath: mapRel)))), .text(bookID.uuidString), .text(sourceID.uuidString)])
    }

    /// Explicit preparation creates fresh coordinates and IDs. It never edits old rows or audio.
    @discardableResult
    public func prepareWorkingRevision(bookID: UUID, expectedSourceID: UUID) async throws -> UUID {
        guard let book = try fetchBook(id: bookID) else { throw AudiobookStoreError.bookNotFound(bookID) }
        guard book.sourceID == expectedSourceID else { throw AudiobookStoreError.workingSourceChanged }
        let active = try sourceRecord(bookID: bookID, sourceID: expectedSourceID)
        let referenceRecord = try sourceRecord(bookID: bookID, sourceID: active.referenceSourceID ?? active.id)
        let reference = try readSourceRecord(referenceRecord)
        // Suspension allows concurrent runs to finish; the transaction below compares the source again.
        let prepared = try await Task.detached { try AudiobookTextPreparation.prepare(referenceUTF8: reference.utf8Data) }.value
        try Task.checkCancellation()
        if simulateDiskFullOnWrite { throw AudiobookStoreError.diskFull }
        let id = UUID()
        let canonicalRel = "books/\(bookID)/sources/\(id)-source.utf8"
        let mapRel = "books/\(bookID)/sources/\(id)-map.json"
        let source = try prepared.sourceIndex()
        let chapters = try AudiobookChapterPlanner.plan(source: source, bookID: bookID, sourceID: id).chapters
        let atoms = try chapters.flatMap { try source.buildAtoms(for: $0) }
        try FileManager.default.createDirectory(at: resolveOwnedURL(relativePath: canonicalRel).deletingLastPathComponent(), withIntermediateDirectories: true)
        try prepared.workingUTF8.write(to: resolveOwnedURL(relativePath: canonicalRel), options: .atomic)
        try JSONEncoder().encode(prepared.sourceMap).write(to: resolveOwnedURL(relativePath: mapRel), options: .atomic)
        guard try Data(contentsOf: resolveOwnedURL(relativePath: canonicalRel)) == prepared.workingUTF8,
              try JSONDecoder().decode([AudiobookWorkingSourceSpan].self,
                from: Data(contentsOf: resolveOwnedURL(relativePath: mapRel))) == prepared.sourceMap else {
            throw AudiobookStoreError.workingSourceChanged
        }
        try Task.checkCancellation()
        try inTransaction {
            guard let current = try fetchBook(id: bookID), current.sourceID == expectedSourceID else {
                throw AudiobookStoreError.workingSourceChanged
            }
            try insertWorkingRevision(book: current, sourceID: id, source: source, referenceRecord: referenceRecord,
                canonicalRel: canonicalRel, mapRel: mapRel, chapters: chapters, atoms: atoms)
        }
        activeAnalysisRuns.removeValue(forKey: bookID)
        cachedSourceIndices.removeValue(forKey: bookID)
        cachedCharactersByBook.removeValue(forKey: bookID)
        cachedAnnotationsByBook.removeValue(forKey: bookID)
        return id
    }

    private func insertWorkingRevision(book current: AudiobookBook, sourceID id: UUID, source: AudiobookSourceIndex,
        referenceRecord: SourceRecord, canonicalRel: String, mapRel: String,
        chapters: [AudiobookChapter], atoms: [AudiobookTextAtom]) throws {
        let bookID = current.id
        let expectedSourceID = current.sourceID
        try saveSourceWorkflow(current)
        try insertSourceRow(bookID: bookID, sourceID: id, sha256: source.sourceSHA256, byteCount: source.byteCount,
            scalarCount: source.scalarCount, encoding: referenceRecord.encoding, originalRelPath: referenceRecord.originalRel,
            canonicalRelPath: canonicalRel, createdAt: Date())
        try markWorkingSource(bookID: bookID, sourceID: id, referenceID: referenceRecord.id, mapRel: mapRel)
        for chapter in chapters { try upsertChapterRow(chapter) }
        for atom in atoms { try insertAtomRow(bookID: bookID, atom: atom) }
        try executePrepared("""
            UPDATE books SET source_id = ?, source_sha256 = ?, canonical_byte_count = ?, scalar_count = ?,
              analysis_state = 'notStarted', production_state = 'idle', listenable_state = ?, confirmed_cast_revision_id = NULL,
              confirmed_audition_digest = NULL, analysis_failure_json = NULL, updated_at = ? WHERE id = ? AND source_id = ?;
            """, [.text(id.uuidString), .text(source.sourceSHA256), .int(source.byteCount), .int(Int64(source.scalarCount)),
                  .text(current.listenableState == .noneAvailable ? AudiobookListenableState.noneAvailable.rawValue : AudiobookListenableState.previousRevisionAvailable.rawValue), .real(Date().timeIntervalSince1970), .text(bookID.uuidString), .text(expectedSourceID.uuidString)])
        let narrator = AudiobookCharacter(bookID: bookID, displayName: "旁白", aliases: ["叙述"], isNarrator: true,
            isMajor: true, chapterIDs: chapters.map(\.id))
        try upsertCharacterRow(narrator)
    }

    private func requireChapterTextEditable(bookID: UUID) throws -> AudiobookBook {
        guard let book = try fetchBook(id: bookID) else { throw AudiobookStoreError.bookNotFound(bookID) }
        guard book.analysisState == .notStarted, book.productionState == .idle,
              activeAnalysisRuns[bookID] == nil, try !hasChapterStructureArtifacts(bookID: bookID) else {
            throw AudiobookChapterTextEditError.notEditable
        }
        return book
    }

    public func chapterEditDraft(bookID: UUID, chapterID: UUID) throws -> AudiobookChapterEditDraft {
        let book = try requireChapterTextEditable(bookID: bookID)
        let snapshot = try workingSourceSnapshot(bookID: bookID)
        let chapters = try fetchChapters(bookID: bookID)
        guard let chapter = chapters.first(where: { $0.id == chapterID }) else { throw AudiobookStoreError.chapterNotFound(chapterID) }
        return .init(bookID: bookID, sourceID: book.sourceID, sourceSHA256: book.sourceSHA256, chapterID: chapterID,
            layoutDigest: AudiobookCastingDigest.hash(chapters), title: chapter.title,
            body: try snapshot.sourceIndex.text(in: chapter.sourceRange, excluding: chapter.excludedRanges))
    }

    private func validateChapterDraft(_ draft: AudiobookChapterEditDraft) throws -> AudiobookBook {
        let book = try requireChapterTextEditable(bookID: draft.bookID)
        guard book.sourceID == draft.sourceID, book.sourceSHA256 == draft.sourceSHA256,
              AudiobookCastingDigest.hash(try fetchChapters(bookID: draft.bookID)) == draft.layoutDigest else {
            throw AudiobookChapterTextEditError.staleDraft
        }
        return book
    }

    @discardableResult
    public func saveChapterEdit(_ draft: AudiobookChapterEditDraft, title: String, body: String) throws -> AudiobookChapterEditResult {
        try Task.checkCancellation()
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { throw AudiobookChapterTextEditError.emptyTitle }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AudiobookChapterTextEditError.emptyBody }
        _ = try validateChapterDraft(draft)
        let snapshot = try workingSourceSnapshot(bookID: draft.bookID)
        // Verify frozen body/title against disk as well; callers cannot supply a forged draft.
        guard try chapterEditDraft(bookID: draft.bookID, chapterID: draft.chapterID) == draft else {
            throw AudiobookChapterTextEditError.staleDraft
        }
        if body.utf8.elementsEqual(draft.body.utf8) {
            try inTransaction {
                _ = try validateChapterDraft(draft)
                if !normalizedTitle.utf8.elementsEqual(draft.title.utf8) {
                    try executePrepared("UPDATE chapters SET title = ? WHERE book_id = ? AND id = ? AND source_id = ?;",
                        [.text(normalizedTitle), .text(draft.bookID.uuidString), .text(draft.chapterID.uuidString), .text(draft.sourceID.uuidString)])
                    try executePrepared("UPDATE books SET updated_at = ? WHERE id = ?;", [.real(Date().timeIntervalSince1970), .text(draft.bookID.uuidString)])
                }
            }
            return .init(sourceID: draft.sourceID, chapterID: draft.chapterID)
        }
        let active = try sourceRecord(bookID: draft.bookID, sourceID: draft.sourceID)
        guard let referenceID = active.referenceSourceID, let oldMapRel = active.mapRel else { throw AudiobookStoreError.workingTextPreparationRequired }
        let referenceRecord = try sourceRecord(bookID: draft.bookID, sourceID: referenceID)
        let reference = try readSourceRecord(referenceRecord)
        let oldMap = try JSONDecoder().decode([AudiobookWorkingSourceSpan].self,
            from: Data(contentsOf: resolveOwnedURL(relativePath: oldMapRel)))
        let id = UUID()
        let replacement = try AudiobookChapterTextEditing.replacing(source: snapshot.sourceIndex, map: oldMap,
            chapters: fetchChapters(bookID: draft.bookID), chapterID: draft.chapterID, title: normalizedTitle, body: body, newSourceID: id)
        let source = try replacement.text.sourceIndex()
        try AudiobookChapterTextEditing.validateMap(replacement.text.sourceMap, working: source, reference: reference)
        let atoms = try replacement.chapters.flatMap { try source.buildAtoms(for: $0) }
        try Task.checkCancellation()
        if simulateDiskFullOnWrite { throw AudiobookStoreError.diskFull }
        let canonicalRel = "books/\(draft.bookID)/sources/\(id)-source.utf8"
        let mapRel = "books/\(draft.bookID)/sources/\(id)-map.json"
        try FileManager.default.createDirectory(at: resolveOwnedURL(relativePath: canonicalRel).deletingLastPathComponent(), withIntermediateDirectories: true)
        try replacement.text.workingUTF8.write(to: resolveOwnedURL(relativePath: canonicalRel), options: .atomic)
        try JSONEncoder().encode(replacement.text.sourceMap).write(to: resolveOwnedURL(relativePath: mapRel), options: .atomic)
        guard try Data(contentsOf: resolveOwnedURL(relativePath: canonicalRel)) == replacement.text.workingUTF8,
              try JSONDecoder().decode([AudiobookWorkingSourceSpan].self, from: Data(contentsOf: resolveOwnedURL(relativePath: mapRel))) == replacement.text.sourceMap else {
            throw AudiobookStoreError.workingSourceChanged
        }
        try Task.checkCancellation()
        try inTransaction {
            let current = try validateChapterDraft(draft)
            try insertWorkingRevision(book: current, sourceID: id, source: source, referenceRecord: referenceRecord,
                canonicalRel: canonicalRel, mapRel: mapRel, chapters: replacement.chapters, atoms: atoms)
        }
        cachedSourceIndices.removeValue(forKey: draft.bookID)
        cachedCharactersByBook.removeValue(forKey: draft.bookID)
        cachedAnnotationsByBook.removeValue(forKey: draft.bookID)
        return .init(sourceID: id, chapterID: replacement.selectedID)
    }

    private struct SourceWorkflowSnapshot: Codable {
        let book: AudiobookBook
        let checkpoint: AudiobookProductionCheckpoint?
    }

    private func saveSourceWorkflow(_ book: AudiobookBook) throws {
        // Capture partial books too: a full-book production revision may not exist yet.
        let chapters = try fetchChapters(bookID: book.id)
        let adopted = Dictionary(uniqueKeysWithValues: chapters.compactMap { chapter in
            (chapter.currentChapterRevisionID ?? chapter.previousChapterRevisionID).map { (chapter.id, $0) }
        })
        if !adopted.isEmpty, !((try fetchProductionRevisions(bookID: book.id)).contains {
            $0.sourceID == book.sourceID && $0.chapterRevisionIDsByChapter == adopted
        }) {
            try upsertProductionRevisionRow(.init(bookID: book.id, sourceID: book.sourceID, chapterRevisionIDsByChapter: adopted))
        }
        try executePrepared("UPDATE sources SET workflow_book_json = ? WHERE book_id = ? AND id = ?;",
            [.text(String(decoding: try JSONEncoder().encode(SourceWorkflowSnapshot(book: book, checkpoint: productionCheckpoint(for: book.id))), as: UTF8.self)),
             .text(book.id.uuidString), .text(book.sourceID.uuidString)])
    }

    /// Restore a previously active revision by pointer, never by replacing the database.
    public func activateSourceRevision(bookID: UUID, sourceID: UUID, expectedSourceID: UUID) throws {
        try inTransaction {
            guard let current = try fetchBook(id: bookID), current.sourceID == expectedSourceID else {
                throw AudiobookStoreError.workingSourceChanged
            }
            if sourceID == expectedSourceID { return }
            let target = try sourceRecord(bookID: bookID, sourceID: sourceID)
            _ = try readSourceRecord(target)
            if target.kind == "working" {
                guard target.preparationVersion == AudiobookTextPreparation.version, let mapRel = target.mapRel,
                      try AudiobookDigest.sha256Hex(Data(contentsOf: resolveOwnedURL(relativePath: mapRel))) == target.mapSHA256 else {
                    throw AudiobookStoreError.workingSourceChanged
                }
            }
            guard let json = target.workflowJSON else { throw AudiobookStoreError.workingSourceChanged }
            let state = try JSONDecoder().decode(SourceWorkflowSnapshot.self, from: Data(json.utf8))
            var restored = state.book
            guard restored.id == bookID, restored.sourceID == sourceID else { throw AudiobookStoreError.workingSourceChanged }
            restored.title = current.title; restored.author = current.author; restored.updatedAt = Date()
            try saveSourceWorkflow(current)
            try executePrepared("UPDATE books SET source_id = ?, source_sha256 = ?, canonical_byte_count = ?, scalar_count = ? WHERE id = ?;",
                [.text(sourceID.uuidString), .text(target.sha256), .int(target.byteCount), .int(Int64(target.scalarCount)), .text(bookID.uuidString)])
            try upsertBookRow(restored)
            if let checkpoint = state.checkpoint { try upsertProductionCheckpointRow(checkpoint) }
            else { try executePrepared("DELETE FROM production_checkpoints WHERE book_id = ?;", [.text(bookID.uuidString)]) }
        }
        activeAnalysisRuns.removeValue(forKey: bookID)
        cachedSourceIndices.removeValue(forKey: bookID)
        cachedCharactersByBook.removeValue(forKey: bookID)
        cachedAnnotationsByBook.removeValue(forKey: bookID)
    }

    public func isWorkingSource(bookID: UUID, sourceID: UUID) throws -> Bool {
        try sourceRecord(bookID: bookID, sourceID: sourceID).kind == "working"
    }

    public func historicalSourceIndex(bookID: UUID, sourceID: UUID) throws -> AudiobookSourceIndex {
        try readSourceRecord(sourceRecord(bookID: bookID, sourceID: sourceID))
    }

    private func readSourceIndex(bookID: UUID) throws -> AudiobookSourceIndex {
        touchBookCache(bookID)
        guard let book = try fetchBook(id: bookID) else {
            throw AudiobookStoreError.bookNotFound(bookID)
        }
        if let cached = cachedSourceIndices[bookID], cached.sha256 == book.sourceSHA256 {
            return cached.index
        }
        let index = try readSourceRecord(sourceRecord(bookID: bookID, sourceID: book.sourceID))
        cachedSourceIndices[bookID] = (book.sourceSHA256, index)
        return index
    }

    public func chapters(for bookID: UUID, sourceID: UUID? = nil) async throws -> [AudiobookChapter] {
        try fetchChapters(bookID: bookID, sourceID: sourceID)
    }

    /// 只切换“跳过本章”标记，不改章节结构、原文或已有分析/制作记录。
    public func setChapterSkipped(bookID: UUID, chapterID: UUID, skipped: Bool) async throws {
        try inTransaction {
            let existing = try fetchChapters(bookID: bookID)
            guard existing.contains(where: { $0.id == chapterID }) else {
                throw AudiobookStoreError.chapterNotFound(chapterID)
            }
            try executePrepared(
                "UPDATE chapters SET is_skipped = ? WHERE book_id = ? AND id = ?;",
                [.int(skipped ? 1 : 0), .text(bookID.uuidString), .text(chapterID.uuidString)]
            )
        }
    }

    public func updateChapters(bookID: UUID, chapters: [AudiobookChapter]) async throws {
        let book = try await self.book(id: bookID)
        guard chapters.allSatisfy({ $0.bookID == bookID && $0.sourceID == book.sourceID }) else {
            throw AudiobookStoreError.statementFailed("章节归属与当前书籍正文不一致，已拒绝保存。")
        }
        guard Set(chapters.map(\.id)).count == chapters.count else {
            throw AudiobookStoreError.statementFailed("章节结构包含重复编号，已拒绝保存。")
        }

        let source = try await sourceIndex(for: bookID)
        try AudiobookChapterPlanner.validateChapterEdits(chapters, source: source)

        var newAtoms: [AudiobookTextAtom] = []
        for chapter in chapters {
            newAtoms.append(contentsOf: try source.buildAtoms(for: chapter))
        }

        try inTransaction {
            guard let currentBook = try fetchBook(id: bookID) else {
                throw AudiobookStoreError.bookNotFound(bookID)
            }
            let hasArtifacts = try hasChapterStructureArtifacts(bookID: bookID)
            guard currentBook.analysisState == .notStarted, !hasArtifacts else {
                throw AudiobookStoreError.statementFailed(
                    "章节结构已开始分析或存在分析、制作记录，不能重建；如需修改名称，请使用章节重命名。"
                )
            }
            guard chapters.allSatisfy({ $0.bookID == bookID && $0.sourceID == currentBook.sourceID }) else {
                throw AudiobookStoreError.statementFailed("章节归属与当前书籍正文不一致，已拒绝保存。")
            }

            try executePrepared("DELETE FROM text_atoms WHERE book_id = ? AND chapter_id IN (SELECT id FROM chapters WHERE chapters.book_id = text_atoms.book_id AND source_id = (SELECT source_id FROM books WHERE id = text_atoms.book_id));", [.text(bookID.uuidString)])
            try executePrepared("DELETE FROM chapters WHERE book_id = ? AND source_id = (SELECT source_id FROM books WHERE id = chapters.book_id);", [.text(bookID.uuidString)])
            for chapter in chapters {
                try upsertChapterRow(chapter)
            }
            for atom in newAtoms {
                try insertAtomRow(bookID: bookID, atom: atom)
            }
            if var narrator = try fetchCharacters(bookID: bookID).first(where: \.isNarrator) {
                narrator.chapterIDs = chapters.map(\.id)
                try upsertCharacterRow(narrator)
            }
            try executePrepared(
                "UPDATE books SET analysis_state = ?, updated_at = ? WHERE id = ?;",
                [.text(AudiobookAnalysisState.notStarted.rawValue), .real(Date().timeIntervalSince1970), .text(bookID.uuidString)]
            )
        }
        cachedCharactersByBook.removeValue(forKey: bookID)
        cachedAnnotationsByBook.removeValue(forKey: bookID)
    }

    public func renameChapter(bookID: UUID, chapterID: UUID, title: String, expectedTitle: String? = nil) async throws {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw AudiobookStoreError.statementFailed("章节名称不能为空。")
        }

        try inTransaction {
            guard try fetchBook(id: bookID) != nil else {
                throw AudiobookStoreError.bookNotFound(bookID)
            }
            if let expectedTitle {
                guard let currentTitle = try fetchChapters(bookID: bookID).first(where: { $0.id == chapterID })?.title,
                      currentTitle.utf8.elementsEqual(expectedTitle.utf8) else {
                    throw AudiobookChapterTextEditError.staleDraft
                }
            }
            guard try countRows(
                "SELECT COUNT(*) FROM chapters WHERE book_id = ? AND source_id = (SELECT source_id FROM books WHERE id = chapters.book_id) AND id = ?;",
                [.text(bookID.uuidString), .text(chapterID.uuidString)]
            ) > 0 else {
                throw AudiobookStoreError.chapterNotFound(chapterID)
            }
            try executePrepared(
                "UPDATE chapters SET title = ? WHERE book_id = ? AND id = ?;",
                [.text(normalizedTitle), .text(bookID.uuidString), .text(chapterID.uuidString)]
            )
        }
    }

    public func atoms(for bookID: UUID, chapterID: UUID? = nil) async throws -> [AudiobookTextAtom] {
        try fetchAtoms(bookID: bookID, chapterID: chapterID)
    }

    public func characters(for bookID: UUID) async throws -> [AudiobookCharacter] {
        touchBookCache(bookID)
        if let cached = cachedCharactersByBook[bookID] {
            return cached
        }
        let rows = try fetchCharacters(bookID: bookID)
        cachedCharactersByBook[bookID] = rows
        return rows
    }

    public func saveCharacters(bookID: UUID, characters: [AudiobookCharacter], expectedSourceID: UUID? = nil) async throws {
        try saveCharacters(bookID: bookID, characters: characters, updatingAnnotations: [], expectedSourceID: expectedSourceID)
    }

    /// Commit role changes and their dialogue assignments together, without actor reentrancy.
    func saveCharacters(
        bookID: UUID,
        characters: [AudiobookCharacter],
        updatingAnnotations annotations: [AudiobookAnnotation],
        expectedSourceID: UUID? = nil
    ) throws {
        let retainedIDs = Set(characters.map(\.id))
        guard characters.allSatisfy({ $0.bookID == bookID }), retainedIDs.count == characters.count else {
            throw AudiobookStoreError.statementFailed("角色列表包含其他书籍的角色或重复角色。")
        }
        guard annotations.allSatisfy({ annotation in
            annotation.bookID == bookID
                && (annotation.assignment.roleID.map { retainedIDs.contains($0) } ?? true)
        }) else {
            throw AudiobookStoreError.statementFailed("对白归属与保存的角色列表不一致，已拒绝保存。")
        }
        try inTransaction {
            if let expectedSourceID, try fetchBook(id: bookID)?.sourceID != expectedSourceID {
                throw AudiobookStoreError.workingSourceChanged
            }

            // Retained rows keep their voice bindings; only removed roles cascade-delete theirs.
            for existing in try fetchCharacters(bookID: bookID) where !retainedIDs.contains(existing.id) {
                try executePrepared(
                    "DELETE FROM characters WHERE book_id = ? AND id = ?;",
                    [.text(bookID.uuidString), .text(existing.id.uuidString)]
                )
            }
            for character in characters {
                try upsertCharacterRow(character)
            }
            for annotation in annotations {
                try upsertAnnotationRow(annotation)
            }
        }
        cachedCharactersByBook.removeValue(forKey: bookID)
        if !annotations.isEmpty {
            cachedAnnotationsByBook.removeValue(forKey: bookID)
        }
    }

    public func upsertCharacter(_ character: AudiobookCharacter) async throws {
        try inTransaction {
            try upsertCharacterRow(character)
        }
        cachedCharactersByBook.removeValue(forKey: character.bookID)
    }

    public func voiceBindings(for bookID: UUID) async throws -> [UUID: AudiobookVoiceBinding] {
        try fetchVoiceBindings(bookID: bookID)
    }

    public func saveVoiceBinding(bookID: UUID, binding: AudiobookVoiceBinding) async throws {
        try inTransaction {
            try upsertVoiceBindingRow(bookID: bookID, binding: binding)
        }
    }

    public func saveVoiceBindings(bookID: UUID, bindings: [AudiobookVoiceBinding]) async throws {
        guard !bindings.isEmpty else { return }
        try inTransaction {
            for binding in bindings {
                try upsertVoiceBindingRow(bookID: bookID, binding: binding)
            }
        }
    }

    /// Read all local planning inputs without actor suspension; attach source and scene revisions.
    public func prepareCastingPlan(bookID: UUID, snapshot: EffectiveCapabilitySnapshot, catalog: VoiceCatalogSnapshot, strategy: AudiobookCastingStrategy = .sceneAware) throws -> AudiobookCastingPlan {
        let characters = try fetchCharacters(bookID: bookID)
        let annotations = try fetchAnnotations(bookID: bookID, chapterID: nil)
        let bindings = try fetchVoiceBindings(bookID: bookID)
        var plan = AudiobookCastRegistry.makeCastingPlan(characters: characters, annotations: annotations,
            snapshot: snapshot, catalog: catalog, bookID: bookID, existingBindings: bindings,
            requiredRoleIDs: try requiredCastingRoleIDs(bookID: bookID, characters: characters, annotations: annotations),
            source: try workingSourceSnapshot(bookID: bookID).sourceIndex, atoms: try fetchAtoms(bookID: bookID, chapterID: nil), strategy: strategy, cachedScores: castingScoreCache)
        castingScoreCache = plan.cachedScores
        plan.sourceContextDigest = try castingSourceContext(bookID: bookID)
        plan.affectedFragmentIDs = Set(try fetchFragments(bookID: bookID, chapterID: nil).filter { plan.affectedRoleIDs.contains($0.roleID) }.map(\.id))
        if !plan.unresolvedRoleIDs.isEmpty { return plan }
        if !((try? hasCompleteCastingAnnotations(bookID: bookID, characters: characters, annotations: annotations)) ?? false),
           characters.contains(where: { plan.proposedBindings[$0.id] == nil }) {
            plan.rawIssues.append(.init(code: .unresolvedSpeaker, nextAction: "请完成全书分析与说话人确认后再豁免未发声角色。"))
        }
        return plan
    }

    /// Explicit replacement plans against the original state; never clears bindings while planning.
    public func prepareRecastingPlan(bookID: UUID, snapshot: EffectiveCapabilitySnapshot, catalog: VoiceCatalogSnapshot,
                                    strategy: AudiobookCastingStrategy = .sceneAware) throws -> AudiobookCastingPlan {
        let original = try fetchCharacters(bookID: bookID)
        let annotations = try fetchAnnotations(bookID: bookID, chapterID: nil)
        let existing = try fetchVoiceBindings(bookID: bookID)
        let replanningRoles = original.map { role in
            var copy = role
            copy.voicePolicy = .init(sharingPolicy: role.isNarrator || role.voicePolicy?.sharingPolicy == .exclusive ? .exclusive : .automatic)
            return copy
        }
        let recommendation = AudiobookCastRegistry.makeCastingPlan(characters: replanningRoles, annotations: annotations,
            snapshot: snapshot, catalog: catalog, bookID: bookID, existingBindings: [:],
            requiredRoleIDs: try requiredCastingRoleIDs(bookID: bookID, characters: original, annotations: annotations),
            source: try workingSourceSnapshot(bookID: bookID).sourceIndex,
            atoms: try fetchAtoms(bookID: bookID, chapterID: nil), strategy: strategy)
        var proposed = recommendation.proposedBindings
        var policies = recommendation.proposedPolicies
        // Keep bindings of merely mentioned roles; a re-cast is not a removal operation.
        for (id, binding) in existing where proposed[id] == nil {
            proposed[id] = binding
            policies[id] = original.first { $0.id == id }?.voicePolicy ?? .init(
                sharingPolicy: original.first { $0.id == id }?.allowSharedMinorVoice == true ? .sharedMinor : .exclusive,
                bindingOrigin: .legacyUnknown, isLocked: true)
        }
        let affected = Set(proposed.keys.filter { proposed[$0] != existing[$0] })
        var plan = AudiobookCastingPlan(bookID: bookID,
            localInputDigest: AudiobookCastingDigest.local(characters: original, annotations: annotations, bindings: existing),
            snapshot: snapshot, catalog: catalog,
            expectedCastRevisionID: AudiobookCastRegistry.castRevisionID(bookID: bookID, characters: original),
            proposedBindings: proposed, proposedPolicies: policies, unresolvedRoleIDs: recommendation.unresolvedRoleIDs,
            affectedRoleIDs: affected, affectedFragmentIDs: [], narratorVoiceCount: recommendation.narratorVoiceCount,
            exclusiveVoiceCount: recommendation.exclusiveVoiceCount, sharedVoiceCount: recommendation.sharedVoiceCount,
            eligibleVoiceCount: recommendation.eligibleVoiceCount, rawIssues: recommendation.rawIssues)
        plan.strategy = strategy
        plan.hasUnavoidableSceneConflicts = recommendation.hasUnavoidableSceneConflicts
        plan.sourceContextDigest = try castingSourceContext(bookID: bookID)
        plan.allowsLockedReplacement = true
        plan.affectedFragmentIDs = Set(try fetchFragments(bookID: bookID, chapterID: nil)
            .filter { plan.affectedRoleIDs.contains($0.roleID) }.map(\.id))
        if !plan.affectedRoleIDs.isEmpty {
            plan.rawIssues.append(.init(code: .bindingReplacementConsentRequired, roleIDs: Array(plan.affectedRoleIDs),
                isBlocking: false, nextAction: "将按角色特征重新配声；确认后只更新当前作品，原配声可撤销恢复，已有音频保留。"))
        }
        return plan
    }

    func manualCastingPlan(bookID: UUID, bindings updates: [AudiobookVoiceBinding], snapshot: EffectiveCapabilitySnapshot, catalog: VoiceCatalogSnapshot, onlyIfUnbound: Bool = false, expectedVoiceSetDigest: String? = nil) throws -> AudiobookCastingPlan {
        let characters = try fetchCharacters(bookID: bookID), annotations = try fetchAnnotations(bookID: bookID, chapterID: nil)
        let existing = try fetchVoiceBindings(bookID: bookID)
        if let expectedVoiceSetDigest,
           expectedVoiceSetDigest != AudiobookCastRegistry.voiceSetDigest(bookID: bookID, characters: characters, bindings: existing) {
            throw AudiobookCastError.staleVoiceReturnContext
        }
        guard !onlyIfUnbound || updates.allSatisfy({ existing[$0.roleID] == nil }) else {
            throw AudiobookCastError.staleVoiceReturnContext
        }
        guard Set(updates.map(\.roleID)).count == updates.count else { throw AudiobookCastError.invalidCastingPlan(reason: "duplicate_role") }
        var proposed = existing
        for binding in updates { proposed[binding.roleID] = binding }
        let changed = Set(updates.filter { existing[$0.roleID] != $0 }.map(\.roleID))
        let policies = Dictionary(uniqueKeysWithValues: characters.map { role in (role.id, AudiobookRoleVoicePolicy(
            sharingPolicy: role.voicePolicy?.sharingPolicy ?? (role.isNarrator || !role.allowSharedMinorVoice ? .exclusive : .sharedMinor),
            bindingOrigin: changed.contains(role.id) ? .manual : (role.voicePolicy?.bindingOrigin ?? .legacyUnknown), isLocked: true)) })
        var plan = AudiobookCastingPlan(bookID: bookID,
            localInputDigest: AudiobookCastingDigest.local(characters: characters, annotations: annotations, bindings: existing),
            snapshot: snapshot, catalog: catalog, expectedCastRevisionID: AudiobookCastRegistry.castRevisionID(bookID: bookID, characters: characters),
            proposedBindings: proposed, proposedPolicies: policies, unresolvedRoleIDs: [], affectedRoleIDs: changed,
            affectedFragmentIDs: Set(try fetchFragments(bookID: bookID, chapterID: nil).filter { changed.contains($0.roleID) }.map(\.id)),
            narratorVoiceCount: 0, exclusiveVoiceCount: 0, sharedVoiceCount: 0, eligibleVoiceCount: snapshot.voices.count, rawIssues: [])
        plan.allowsLockedReplacement = true
        plan.requiresCompleteCast = false
        plan.sourceContextDigest = try castingSourceContext(bookID: bookID)
        return plan
    }

    public func prepareVoiceReplacement(bookID: UUID, bindings: [AudiobookVoiceBinding], snapshot: EffectiveCapabilitySnapshot, catalog: VoiceCatalogSnapshot) throws -> AudiobookCastingPlan {
        var plan = try manualCastingPlan(bookID: bookID, bindings: bindings, snapshot: snapshot, catalog: catalog)
        if !plan.affectedRoleIDs.isEmpty {
            plan.rawIssues.append(.init(code: .bindingReplacementConsentRequired, roleIDs: Array(plan.affectedRoleIDs), isBlocking: false,
                nextAction: "请确认更换的角色和受影响片段；已采用音频会保留。"))
        }
        return plan
    }
    private func castingStateDigest(characters: [AudiobookCharacter], bindings: [UUID: AudiobookVoiceBinding]) -> String {
        AudiobookCastingDigest.hash([AudiobookCastingDigest.hash(Array(bindings.values)),
            AudiobookCastingDigest.hash(characters.map { AudiobookCastingPolicySnapshot(roleID: $0.id, policy: $0.voicePolicy, allowSharedMinorVoice: $0.allowSharedMinorVoice) })])
    }

    private func appendCastingRevision(bookID: UUID, previousBindings: [UUID: AudiobookVoiceBinding],
        previousCharacters: [AudiobookCharacter], updatedCharacters: [AudiobookCharacter], bindings: [UUID: AudiobookVoiceBinding],
        affectedRoleIDs: Set<UUID>, undoingRevisionID: UUID? = nil) throws {
        let revisionID = UUID()
        let record = AudiobookCastingUndoRecord(id: revisionID, bookID: bookID, previousBindings: previousBindings,
            previousPolicies: previousCharacters.map { .init(roleID: $0.id, policy: $0.voicePolicy, allowSharedMinorVoice: $0.allowSharedMinorVoice) },
            affectedRoleIDs: affectedRoleIDs, afterDigest: castingStateDigest(characters: updatedCharacters, bindings: bindings))
        try executePrepared("INSERT INTO casting_revisions (id, book_id, restores_revision_id, record_json, created_at) VALUES (?, ?, ?, ?, ?);",
            [.text(revisionID.uuidString), .text(bookID.uuidString), .text(undoingRevisionID?.uuidString),
             .text(String(decoding: try JSONEncoder().encode(record), as: UTF8.self)), .real(Date().timeIntervalSince1970)])
        if let originalID = undoingRevisionID {
            try executePrepared("UPDATE casting_revisions SET undone_by = ? WHERE id = ? AND undone_by IS NULL;", [.text(revisionID.uuidString), .text(originalID.uuidString)])
            guard let pointer = handle.pointer, sqlite3_changes(pointer) == 1 else { throw AudiobookCastError.castRevisionMismatch }
        }
    }

    /// A policy edit is an atomic casting revision even when the role is not bound yet.
    func saveManualSharingPolicy(bookID: UUID, roleID: UUID, allowed: Bool) throws {
        try Task.checkCancellation()
        try inTransaction {
            guard var book = try fetchBook(id: bookID) else { throw AudiobookStoreError.bookNotFound(bookID) }
            let original = try fetchCharacters(bookID: bookID)
            guard let index = original.firstIndex(where: { $0.id == roleID }) else { throw AudiobookCastError.characterNotFound(roleID) }
            guard !original[index].isNarrator || !allowed else {
                throw AudiobookCastError.invalidCastingPlan(reason: "narrator_must_remain_exclusive")
            }
            var updated = original
            updated[index].voicePolicy = .init(sharingPolicy: allowed ? .sharedMinor : .exclusive, bindingOrigin: .manual, isLocked: true)
            updated[index].allowSharedMinorVoice = allowed
            guard updated != original else { return }
            let bindings = try fetchVoiceBindings(bookID: bookID)
            let annotations = try fetchAnnotations(bookID: bookID, chapterID: nil)
            try AudiobookCastRegistry.validateBindingSet(characters: updated, bindings: bindings,
                requiredRoleIDs: requiredCastingRoleIDs(bookID: bookID, characters: updated, annotations: annotations))
            try upsertCharacterRow(updated[index])
            try appendCastingRevision(bookID: bookID, previousBindings: bindings, previousCharacters: original,
                updatedCharacters: updated, bindings: bindings, affectedRoleIDs: [roleID])
            book.confirmedCastRevisionID = nil
            book.confirmedAuditionVoiceSetDigest = nil
            book.updatedAt = Date()
            try upsertBookRow(book)
            try Task.checkCancellation()
        }
        cachedCharactersByBook.removeValue(forKey: bookID)
        startupRunningBookUpdatedAt.removeValue(forKey: bookID)
    }

    public func prepareCastingUndo(bookID: UUID, snapshot: EffectiveCapabilitySnapshot, catalog: VoiceCatalogSnapshot) throws -> AudiobookCastingPlan {
        let record: AudiobookCastingUndoRecord? = try withPrepared("SELECT record_json FROM casting_revisions WHERE book_id = ? AND undone_by IS NULL AND restores_revision_id IS NULL ORDER BY sequence DESC LIMIT 1;", [.text(bookID.uuidString)]) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW, let json = columnText(stmt, 0) else { return nil }
            return try JSONDecoder().decode(AudiobookCastingUndoRecord.self, from: Data(json.utf8))
        }
        guard let record else { throw AudiobookCastError.nothingToUndo }
        let characters = try fetchCharacters(bookID: bookID), annotations = try fetchAnnotations(bookID: bookID, chapterID: nil)
        let current = try fetchVoiceBindings(bookID: bookID)
        guard castingStateDigest(characters: characters, bindings: current) == record.afterDigest else { throw AudiobookCastError.castRevisionMismatch }
        var restored = current
        for id in record.affectedRoleIDs { restored[id] = record.previousBindings[id] }
        let previous = Dictionary(uniqueKeysWithValues: record.previousPolicies.map { ($0.roleID, $0) })
        let policies = Dictionary(uniqueKeysWithValues: characters.map { role in
            (role.id, previous[role.id]?.policy ?? .init(sharingPolicy: role.isNarrator || previous[role.id]?.allowSharedMinorVoice != true ? .exclusive : .sharedMinor,
                bindingOrigin: .legacyUnknown, isLocked: true))
        })
        var plan = AudiobookCastingPlan(bookID: bookID, localInputDigest: AudiobookCastingDigest.local(characters: characters, annotations: annotations, bindings: current),
            snapshot: snapshot, catalog: catalog, expectedCastRevisionID: AudiobookCastRegistry.castRevisionID(bookID: bookID, characters: characters),
            proposedBindings: restored, proposedPolicies: policies, unresolvedRoleIDs: [], affectedRoleIDs: record.affectedRoleIDs,
            affectedFragmentIDs: Set(try fetchFragments(bookID: bookID, chapterID: nil).filter { record.affectedRoleIDs.contains($0.roleID) }.map(\.id)),
            narratorVoiceCount: 0, exclusiveVoiceCount: 0, sharedVoiceCount: 0, eligibleVoiceCount: snapshot.voices.count, rawIssues: [])
        plan.requiresCompleteCast = false; plan.allowsLockedReplacement = true; plan.undoingRevisionID = record.id
        plan.restoringRolePolicies = previous; plan.sourceContextDigest = try castingSourceContext(bookID: bookID)
        return plan
    }
    private func refreshBindingDependencies(bookID: UUID, changedRoles: Set<UUID>) throws {
        guard !changedRoles.isEmpty else { return }
        let bindings = try fetchVoiceBindings(bookID: bookID), chapters = try fetchChapters(bookID: bookID)
        let source = try workingSourceSnapshot(bookID: bookID).sourceIndex
        let pronunciation = try pronunciationBinding(for: bookID)
        for fragment in try fetchFragments(bookID: bookID, chapterID: nil) where changedRoles.contains(fragment.roleID) {
            guard let chapter = chapters.first(where: { $0.id == fragment.chapterID }) else { throw AudiobookStoreError.chapterNotFound(fragment.chapterID) }
            let voiceDigest = bindings[fragment.roleID]?.bindingDigest ?? "unbound"
            let fragmentText = try source.text(in: fragment.sourceRange)
            let dependency = AudiobookFragmentPlanner.dependencyDigest(
                fragmentText: fragmentText,
                sourceID: chapter.sourceID,
                sourceRange: fragment.sourceRange,
                localAssignmentDigest: fragment.localAssignmentDigest,
                voiceDigest: voiceDigest,
                policyDigest: fragment.policyDigest,
                pronunciation: pronunciation
            )
            try upsertFragmentRow(.init(id: fragment.id, bookID: bookID, chapterID: fragment.chapterID, ordinal: fragment.ordinal, roleID: fragment.roleID,
                sourceRange: fragment.sourceRange, atomIDs: fragment.atomIDs, localAssignmentDigest: fragment.localAssignmentDigest,
                voiceBindingDigest: voiceDigest, policyDigest: fragment.policyDigest, dependencyDigest: dependency))
        }
    }

    public func saveVoiceRegistrationIntent(_ intent: AudiobookVoiceRegistrationIntent) throws {
        let encoded = try JSONEncoder().encode(intent)
        guard encoded.count <= 8192, intent.voiceID.utf8.count <= 128, !intent.voiceID.isEmpty,
              intent.expectedVoiceSetDigest.utf8.count == 64,
              intent.bookTitle?.unicodeScalars.count ?? 0 <= 160, intent.roleName?.unicodeScalars.count ?? 0 <= 160,
              [.voiceDesign, .instantClone, .imported].contains(intent.creationSource),
              intent.binding.map({ $0.roleID == intent.roleID && $0.voiceID == intent.voiceID }) ?? true else {
            throw AudiobookCastError.invalidCastingPlan(reason: "invalid_registration_intent")
        }
        try inTransaction {
            if let old = try fetchVoiceRegistrationIntents(bookID: intent.bookID, includeCompleted: true).first(where: { $0.id == intent.id }) {
                guard old.contentDigest == intent.contentDigest else { throw VoiceCatalogError.revisionChanged }
                return
            }
            try executePrepared("""
                INSERT INTO voice_registration_intents (id, book_id, role_id, voice_id, target_metadata_digest,
                    expected_cast_revision_id, expected_voice_set_digest, phase, intent_json, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """, [.text(intent.id.uuidString), .text(intent.bookID.uuidString), .text(intent.roleID?.uuidString), .text(intent.voiceID),
                    .text(intent.targetMetadataDigest), .text(intent.expectedCastRevisionID.uuidString), .text(intent.expectedVoiceSetDigest),
                    .text(intent.phase.rawValue), .text(String(decoding: encoded, as: UTF8.self)), .real(Date().timeIntervalSince1970)])
        }
    }
    public func voiceRegistrationIntents(bookID: UUID, includeCompleted: Bool = false) throws -> [AudiobookVoiceRegistrationIntent] {
        try fetchVoiceRegistrationIntents(bookID: bookID, includeCompleted: includeCompleted)
    }
    private func fetchVoiceRegistrationIntents(bookID: UUID, includeCompleted: Bool) throws -> [AudiobookVoiceRegistrationIntent] {
        try withPrepared("SELECT intent_json, phase FROM voice_registration_intents WHERE book_id = ? ORDER BY id;", [.text(bookID.uuidString)]) { stmt in
            var result: [AudiobookVoiceRegistrationIntent] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let json = columnText(stmt, 0), let phase = columnText(stmt, 1).flatMap(AudiobookVoiceRegistrationIntent.Phase.init(rawValue:)) else {
                    throw AudiobookStoreError.storageUnavailable("invalid_registration_intent")
                }
                var intent = try JSONDecoder().decode(AudiobookVoiceRegistrationIntent.self, from: Data(json.utf8)); intent.phase = phase
                if includeCompleted || phase != .completed { result.append(intent) }
            }
            return result
        }
    }
    public func advanceVoiceRegistration(id: UUID, from: AudiobookVoiceRegistrationIntent.Phase, to: AudiobookVoiceRegistrationIntent.Phase) throws {
        try inTransaction { try advanceVoiceRegistrationRow(id: id, from: from, to: to) }
    }
    private func advanceVoiceRegistrationRow(id: UUID, from: AudiobookVoiceRegistrationIntent.Phase, to: AudiobookVoiceRegistrationIntent.Phase) throws {
        try executePrepared("UPDATE voice_registration_intents SET phase = ?, updated_at = ? WHERE id = ? AND phase = ?;",
            [.text(to.rawValue), .real(Date().timeIntervalSince1970), .text(id.uuidString), .text(from.rawValue)])
        guard let pointer = handle.pointer, sqlite3_changes(pointer) == 1 else { throw VoiceCatalogError.revisionChanged }
    }

    private func castingSourceContext(bookID: UUID) throws -> String {
        guard let book = try fetchBook(id: bookID) else { throw AudiobookStoreError.bookNotFound(bookID) }
        return AudiobookCastingDigest.hash([book.sourceSHA256, book.analysisState.rawValue, AudiobookCastingDigest.hash(try fetchChapters(bookID: bookID))])
    }

    func requiredCastingRoleIDs(bookID: UUID) throws -> Set<UUID> {
        try requiredCastingRoleIDs(bookID: bookID, characters: fetchCharacters(bookID: bookID),
            annotations: fetchAnnotations(bookID: bookID, chapterID: nil))
    }

    private func requiredCastingRoleIDs(bookID: UUID, characters: [AudiobookCharacter], annotations: [AudiobookAnnotation]) throws -> Set<UUID> {
        guard try hasCompleteCastingAnnotations(bookID: bookID, characters: characters, annotations: annotations) else {
            return Set(characters.map(\.id))
        }
        return Set(annotations.compactMap(\.assignment.roleID)).union(characters.filter(\.isNarrator).map(\.id))
    }

    private func hasCompleteCastingAnnotations(bookID: UUID, characters: [AudiobookCharacter], annotations: [AudiobookAnnotation]) throws -> Bool {
        guard try fetchBook(id: bookID)?.analysisState == .allWindowsValidated else { return false }
        let chapters = try fetchChapters(bookID: bookID)
        let atoms = try fetchAtoms(bookID: bookID, chapterID: nil).filter { atom in
            atom.kind != .formatting && !(chapters.first { $0.id == atom.chapterID }?.excludedRanges.contains { $0.lowerBound < atom.sourceRange.upperBound && atom.sourceRange.lowerBound < $0.upperBound } ?? false)
        }
        let validRoleIDs = Set(characters.map(\.id))
        let grouped = Dictionary(grouping: annotations, by: \.atomID)
        guard !atoms.isEmpty else { return false }
        return atoms.allSatisfy { atom in
            guard let rows = grouped[atom.id], rows.count == 1, let annotation = rows.first,
                  annotation.bookID == bookID, annotation.chapterID == atom.chapterID, annotation.sourceRange == atom.sourceRange,
                  let role = annotation.assignment.roleID, validRoleIDs.contains(role) else { return false }
            return true
        }
    }

    /// All local checks, policy changes, bindings and confirmation invalidation share one SQLite transaction.
    public func validateCastingPlanInput(_ plan: AudiobookCastingPlan) throws {
        guard plan.localInputDigest == AudiobookCastingDigest.local(characters: try fetchCharacters(bookID: plan.bookID),
            annotations: try fetchAnnotations(bookID: plan.bookID, chapterID: nil), bindings: try fetchVoiceBindings(bookID: plan.bookID)),
              plan.sourceContextDigest == (try castingSourceContext(bookID: plan.bookID)) else {
            throw AudiobookCastError.castRevisionMismatch
        }
    }

    public func saveCastingPlan(bookID: UUID, plan: AudiobookCastingPlan, registrationIntentID: UUID? = nil) throws {
        try Task.checkCancellation()
        guard plan.bookID == bookID, plan.isApplicable else { throw AudiobookCastError.invalidCastingPlan(reason: "blocking_issues") }
        try inTransaction {
            try Task.checkCancellation()
            let original = try fetchCharacters(bookID: bookID), annotations = try fetchAnnotations(bookID: bookID, chapterID: nil)
            let existing = try fetchVoiceBindings(bookID: bookID)
            guard plan.localInputDigest == AudiobookCastingDigest.local(characters: original, annotations: annotations, bindings: existing),
                  plan.expectedCastRevisionID == AudiobookCastRegistry.castRevisionID(bookID: bookID, characters: original),
                  plan.sourceContextDigest == (try castingSourceContext(bookID: bookID)) else {
                throw AudiobookCastError.castRevisionMismatch
            }
            var updated = original
            for index in updated.indices {
                let role = updated[index]
                guard let policy = plan.proposedPolicies[role.id] else { throw AudiobookCastError.invalidCastingPlan(reason: "missing_policy") }
                if role.voicePolicy?.isLocked == true, !plan.allowsLockedReplacement, plan.proposedBindings[role.id] != existing[role.id] {
                    // Applying an acknowledged engine re-pin retains the locked
                    // voice and every parameter. No other replacement is allowed.
                    guard let previous = existing[role.id],
                          let reconfirmed = AudiobookCastRegistry.reconfirmedBinding(previous, snapshot: plan.snapshot),
                          plan.proposedBindings[role.id] == reconfirmed else {
                        throw AudiobookCastError.invalidCastingPlan(reason: "locked_binding_changed")
                    }
                }
                if role.isNarrator || role.voicePolicy?.sharingPolicy == .exclusive && !plan.allowsLockedReplacement {
                    guard policy.sharingPolicy != .sharedMinor else { throw AudiobookCastError.invalidCastingPlan(reason: "exclusive_policy_changed") }
                }
                if plan.proposedBindings[role.id] != nil, policy != role.voicePolicy {
                    updated[index].voicePolicy = policy
                }
                if plan.proposedBindings[role.id] != nil {
                    updated[index].allowSharedMinorVoice = policy.sharingPolicy == .sharedMinor
                    updated[index].voicePolicy = policy
                }
            }
            for index in updated.indices {
                if let previous = plan.restoringRolePolicies[updated[index].id] {
                    updated[index].voicePolicy = previous.policy
                    updated[index].allowSharedMinorVoice = previous.allowSharedMinorVoice
                }
            }
            try AudiobookCastRegistry.validateBindingSet(characters: updated, bindings: plan.proposedBindings,
                requiredRoleIDs: requiredCastingRoleIDs(bookID: bookID, characters: updated, annotations: annotations))
            for (roleID, binding) in plan.proposedBindings where binding != existing[roleID] {
                guard binding.isSynthesisReady else { throw AudiobookCastError.voiceNotSynthesisReady(voiceID: binding.voiceID) }
                try AudiobookCastRegistry.validateRenderBinding(binding, snapshot: plan.snapshot)
                guard let voice = plan.snapshot.voices.first(where: { $0.id == binding.voiceID }), plan.catalog.permits(voice, bookID: bookID) else {
                    throw AudiobookCastError.invalidCastingPlan(reason: "voice_scope_changed")
                }
                guard let role = updated.first(where: { $0.id == roleID }),
                      AudiobookCastRegistry.matchesRequiredTraits(role: role, voice: voice, metadata: plan.catalog.state.metadataByVoiceID[voice.id]) else {
                    throw AudiobookCastError.invalidCastingPlan(reason: "required_voice_traits_mismatch")
                }
            }
            if plan.requiresCompleteCast {
                let complete = try hasCompleteCastingAnnotations(bookID: bookID, characters: original, annotations: annotations)
                let speaking = Set(annotations.compactMap(\.assignment.roleID))
                guard original.allSatisfy({ role in
                    let needed = !complete || role.isNarrator || speaking.contains(role.id)
                    return !needed || plan.proposedBindings[role.id] != nil
                }) else { throw AudiobookCastError.invalidCastingPlan(reason: "incomplete_annotations") }
            }
            for role in updated where role != original.first(where: { $0.id == role.id }) {
                try Task.checkCancellation()
                try upsertCharacterRow(role)
            }
            for binding in plan.proposedBindings.values.sorted(by: { $0.roleID.uuidString < $1.roleID.uuidString }) where binding != existing[binding.roleID] {
                try Task.checkCancellation()
                try upsertVoiceBindingRow(bookID: bookID, binding: binding)
            }
            let changedBindings = Set(existing.keys).union(plan.proposedBindings.keys).filter { existing[$0] != plan.proposedBindings[$0] }
            for id in changedBindings where plan.proposedBindings[id] == nil {
                guard plan.undoingRevisionID != nil else { throw AudiobookCastError.invalidCastingPlan(reason: "binding_removal_requires_undo") }
                try executePrepared("DELETE FROM voice_bindings WHERE book_id = ? AND role_id = ?;", [.text(bookID.uuidString), .text(id.uuidString)])
            }
            try refreshBindingDependencies(bookID: bookID, changedRoles: Set(changedBindings))
            let changedPolicies = Set(updated.filter { role in original.first(where: { $0.id == role.id })?.voicePolicy != role.voicePolicy
                || original.first(where: { $0.id == role.id })?.allowSharedMinorVoice != role.allowSharedMinorVoice }.map(\.id))
            if !changedBindings.isEmpty || !changedPolicies.isEmpty {
                try appendCastingRevision(bookID: bookID, previousBindings: existing, previousCharacters: original,
                    updatedCharacters: updated, bindings: plan.proposedBindings,
                    affectedRoleIDs: Set(changedBindings).union(changedPolicies), undoingRevisionID: plan.undoingRevisionID)
            }
            if let registrationIntentID {
                guard let intent = try fetchVoiceRegistrationIntents(bookID: bookID, includeCompleted: true).first(where: { $0.id == registrationIntentID }),
                      intent.phase == .catalogPersisted, let binding = intent.binding, plan.proposedBindings[binding.roleID] == binding else {
                    throw AudiobookCastError.invalidCastingPlan(reason: "registration_intent_changed")
                }
                try advanceVoiceRegistrationRow(id: registrationIntentID, from: .catalogPersisted, to: .bindingCommitted)
            }
            try Task.checkCancellation()
            guard var book = try fetchBook(id: bookID) else { throw AudiobookStoreError.bookNotFound(bookID) }
            if updated != original || plan.proposedBindings != existing {
                book.confirmedCastRevisionID = nil
                book.confirmedAuditionVoiceSetDigest = nil
                book.updatedAt = Date()
                try upsertBookRow(book)
            }
        }
        cachedCharactersByBook.removeValue(forKey: bookID)
        startupRunningBookUpdatedAt.removeValue(forKey: bookID)
    }

    /// Commit voice changes, shared-role flags and audition invalidation without suspension.
    func saveCastVoiceBindings(
        bookID: UUID,
        bindings: [AudiobookVoiceBinding],
        updatingCharacters characters: [AudiobookCharacter] = []
    ) throws {
        guard !bindings.isEmpty else { return }
        guard characters.allSatisfy({ $0.bookID == bookID }),
              Set(characters.map(\.id)).count == characters.count
        else {
            throw AudiobookStoreError.statementFailed("角色列表包含其他书籍的角色或重复角色。")
        }
        var updatedBook = false
        try inTransaction {
            guard var book = try fetchBook(id: bookID) else {
                throw AudiobookStoreError.bookNotFound(bookID)
            }
            if !characters.isEmpty {
                let existingIDs = Set(try fetchCharacters(bookID: bookID).map(\.id))
                if let missing = characters.first(where: { !existingIDs.contains($0.id) }) {
                    throw AudiobookCastError.characterNotFound(missing.id)
                }
            }
            for character in characters {
                try upsertCharacterRow(character)
            }
            for binding in bindings {
                try upsertVoiceBindingRow(bookID: bookID, binding: binding)
            }
            if let confirmedDigest = book.confirmedAuditionVoiceSetDigest {
                let newDigest = AudiobookCastRegistry.voiceSetDigest(
                    bookID: bookID,
                    characters: try fetchCharacters(bookID: bookID),
                    bindings: try fetchVoiceBindings(bookID: bookID)
                )
                if confirmedDigest != newDigest {
                    book.confirmedAuditionVoiceSetDigest = nil
                    book.updatedAt = Date()
                    try upsertBookRow(book)
                    updatedBook = true
                }
            }
        }
        if !characters.isEmpty {
            cachedCharactersByBook.removeValue(forKey: bookID)
        }
        if updatedBook {
            startupRunningBookUpdatedAt.removeValue(forKey: bookID)
        }
    }

    /// Validate the committed cast snapshot; nil leaves that confirmation unchanged.
    func saveCastConfirmation(
        bookID: UUID,
        revisionID: UUID?,
        voiceSetDigest: String?
    ) throws {
        guard revisionID != nil || voiceSetDigest != nil else { return }
        try inTransaction {
            guard var book = try fetchBook(id: bookID) else {
                throw AudiobookStoreError.bookNotFound(bookID)
            }
            guard book.analysisState == .allWindowsValidated else {
                throw AudiobookCastError.analysisNotCompleted
            }
            let characters = try fetchCharacters(bookID: bookID)
            let bindings = try fetchVoiceBindings(bookID: bookID)
            if let revisionID {
                guard revisionID == AudiobookCastRegistry.castRevisionID(bookID: bookID, characters: characters) else {
                    throw AudiobookCastError.castRevisionMismatch
                }
                let annotations = try fetchAnnotations(bookID: bookID, chapterID: nil)
                let complete = try hasCompleteCastingAnnotations(bookID: bookID, characters: characters, annotations: annotations)
                let speakingRoleIDs = Set(annotations.compactMap(\.assignment.roleID))
                let unbound = characters.filter { role in
                    let requiresBinding = !complete || role.isNarrator || speakingRoleIDs.contains(role.id)
                    return requiresBinding && bindings[role.id]?.isSynthesisReady != true
                }.map(\.displayName)
                guard unbound.isEmpty else {
                    throw AudiobookCastError.missingVoiceBindings(unboundRoleNames: unbound)
                }
                try AudiobookCastRegistry.validateBindingSet(characters: characters, bindings: bindings,
                    requiredRoleIDs: complete ? speakingRoleIDs.union(characters.filter(\.isNarrator).map(\.id)) : nil)
                book.confirmedCastRevisionID = revisionID
            }
            if let voiceSetDigest {
                guard voiceSetDigest == AudiobookCastRegistry.voiceSetDigest(
                    bookID: bookID, characters: characters, bindings: bindings
                ) else {
                    throw AudiobookCastError.auditionDigestMismatch
                }
                book.confirmedAuditionVoiceSetDigest = voiceSetDigest
            }
            book.updatedAt = Date()
            try upsertBookRow(book)
        }
        startupRunningBookUpdatedAt.removeValue(forKey: bookID)
    }

    public func analysisWindows(for bookID: UUID) async throws -> [AudiobookAnalysisWindow] {
        try fetchAnalysisWindows(bookID: bookID)
    }

    public func saveAnalysisWindow(_ window: AudiobookAnalysisWindow) async throws {
        try inTransaction {
            try upsertAnalysisWindowRow(window)
        }
    }

    public func annotations(for bookID: UUID, chapterID: UUID? = nil) async throws -> [AudiobookAnnotation] {
        touchBookCache(bookID)
        if let cachedAll = cachedAnnotationsByBook[bookID] {
            if let chapterID {
                return cachedAll.filter { $0.chapterID == chapterID }
            }
            return cachedAll
        }
        if let chapterID {
            return try fetchAnnotations(bookID: bookID, chapterID: chapterID)
        }
        let all = try fetchAnnotations(bookID: bookID, chapterID: nil)
        cachedAnnotationsByBook[bookID] = all
        return all
    }

    public func saveAnnotations(bookID: UUID, annotations: [AudiobookAnnotation]) async throws {
        try inTransaction {
            for annotation in annotations {
                try upsertAnnotationRow(annotation)
            }
        }
        if var cached = cachedAnnotationsByBook[bookID], !annotations.isEmpty {
            var indexByAtomID: [UUID: Int] = [:]
            indexByAtomID.reserveCapacity(cached.count)
            for (idx, item) in cached.enumerated() {
                indexByAtomID[item.atomID] = idx
            }
            var didAppend = false
            for ann in annotations {
                if let existingIdx = indexByAtomID[ann.atomID] {
                    cached[existingIdx] = ann
                } else {
                    cached.append(ann)
                    indexByAtomID[ann.atomID] = cached.count - 1
                    didAppend = true
                }
            }
            if didAppend {
                cached.sort { $0.sourceRange < $1.sourceRange }
            }
            cachedAnnotationsByBook[bookID] = cached
        }
    }

    public func fragments(for bookID: UUID, chapterID: UUID? = nil) async throws -> [AudiobookFragment] {
        try fetchFragments(bookID: bookID, chapterID: chapterID)
    }

    public func saveFragments(bookID: UUID, chapterID: UUID, fragments: [AudiobookFragment]) async throws {
        try inTransaction {
            try requireActiveChapter(bookID: bookID, chapterID: chapterID)
            try executePrepared(
                "DELETE FROM fragments WHERE book_id = ? AND chapter_id = ?;",
                [.text(bookID.uuidString), .text(chapterID.uuidString)]
            )
            for fragment in fragments {
                try upsertFragmentRow(fragment)
            }
        }
    }

    public func candidates(for bookID: UUID, fragmentID: UUID? = nil) async throws -> [AudiobookRenderCandidate] {
        try fetchCandidates(bookID: bookID, fragmentID: fragmentID)
    }

    public func chapterRevisions(for bookID: UUID, chapterID: UUID) async throws -> [AudiobookChapterRevision] {
        try fetchChapterRevisions(bookID: bookID, chapterID: chapterID)
    }

    enum ChapterRevisionPublication: Sendable {
        case initial
        case adoption(candidateID: UUID, expectedRevisionID: UUID)
        case undo(expectedRevisionID: UUID?)
    }

    /// A chapter switch and its book projection have one commit boundary. All
    /// dependency and version checks use fresh rows within that same transaction.
    func publishChapterRevision(
        _ proposed: AudiobookChapterRevision,
        publication: ChapterRevisionPublication,
        policy: AudiobookRenderPolicy,
        updateBookProductionState: Bool = true
    ) async throws -> AudiobookChapterRevision {
        let bookID = proposed.bookID
        let source = try await sourceIndex(for: bookID)
        // Hash the expected current audio before taking SQLite's write lock.
        // Only evidence whose candidate row still matches may be reused below.
        let assetCandidates = Dictionary(uniqueKeysWithValues: try fetchCandidates(bookID: bookID, fragmentID: nil).map { ($0.id, $0) })
        var assetIDs = Set(proposed.orderedBindings.map(\.candidateID))
        for chapter in try fetchChapters(bookID: bookID) {
            guard let currentID = chapter.currentChapterRevisionID else { continue }
            let history = try fetchChapterRevisions(bookID: bookID, chapterID: chapter.id)
            if let current = history.first(where: { $0.id == currentID }) {
                assetIDs.formUnion(current.orderedBindings.map(\.candidateID))
            }
        }
        var verifiedAssets: [UUID: (candidate: AudiobookRenderCandidate, isValid: Bool)] = [:]
        for id in assetIDs {
            if let candidate = assetCandidates[id] {
                verifiedAssets[id] = (candidate, (try? verifyCandidateAsset(candidate)) == true)
            }
            // Let progress/checkpoint writes proceed between audio files. Fresh
            // row checks in the transaction below protect against reentrancy.
            await Task.yield()
        }
        let (published, didChange) = try inTransaction {
            guard var book = try fetchBook(id: bookID) else {
                throw AudiobookStoreError.bookNotFound(bookID)
            }
            var chapters = try fetchChapters(bookID: bookID)
            guard let index = chapters.firstIndex(where: { $0.id == proposed.chapterID }) else {
                throw AudiobookStoreError.chapterNotFound(proposed.chapterID)
            }
            var chapter = chapters[index]
            guard proposed.sourceID == book.sourceID,
                  chapter.sourceID == book.sourceID,
                  source.sourceSHA256 == book.sourceSHA256 else {
                throw AudiobookStoreError.statementFailed("章节版本与当前书籍正文不一致，已拒绝发布。")
            }
            let history = try fetchChapterRevisions(bookID: bookID, chapterID: chapter.id)
            let current = history.first { $0.id == chapter.currentChapterRevisionID }
            let isUndo: Bool
            switch publication {
            case .initial:
                if let current { return (current, false) }
                guard chapter.currentChapterRevisionID == nil else {
                    throw AudiobookStoreError.statementFailed("当前章节版本缺失，请检查作品库后重试。")
                }
                isUndo = false
            case let .adoption(candidateID, expectedRevisionID):
                if let current, current.orderedBindings.contains(where: { $0.candidateID == candidateID }) {
                    return (current, false)
                }
                guard chapter.currentChapterRevisionID == expectedRevisionID else {
                    throw AudiobookRevisionError.expectedRevisionMismatch(
                        expected: expectedRevisionID, actual: chapter.currentChapterRevisionID
                    )
                }
                isUndo = false
            case let .undo(expectedRevisionID):
                guard chapter.currentChapterRevisionID == expectedRevisionID else {
                    throw AudiobookRevisionError.expectedRevisionMismatch(
                        expected: expectedRevisionID ?? proposed.id, actual: chapter.currentChapterRevisionID
                    )
                }
                guard chapter.previousChapterRevisionID == proposed.id,
                      history.contains(proposed) else {
                    throw AudiobookRevisionError.noPreviousChapterRevisionToUndo(chapterID: chapter.id)
                }
                isUndo = true
            }

            let annotations = Dictionary(grouping: try fetchAnnotations(bookID: bookID, chapterID: nil), by: \.chapterID)
            let atoms = Dictionary(grouping: try fetchAtoms(bookID: bookID, chapterID: nil), by: \.chapterID)
            let bindings = try fetchVoiceBindings(bookID: bookID)
            let pronunciation = try pronunciationBinding(for: bookID)
            let candidates = Dictionary(uniqueKeysWithValues: try fetchCandidates(bookID: bookID, fragmentID: nil).map { ($0.id, $0) })
            var plannedByChapter: [UUID: [AudiobookFragment]] = [:]
            func assetIsValid(_ binding: AudiobookFragmentCandidateBinding) -> Bool {
                guard let candidate = candidates[binding.candidateID], candidate.isReceiptVerified,
                      candidate.fragmentID == binding.fragmentID,
                      candidate.dependencyDigest == binding.dependencyDigest else { return false }
                if let verified = verifiedAssets[candidate.id], verified.candidate == candidate {
                    return verified.isValid
                }
                let verified = (try? verifyCandidateAsset(candidate)) == true
                verifiedAssets[candidate.id] = (candidate, verified)
                return verified
            }
            func plannedFragments(for chapter: AudiobookChapter) throws -> [AudiobookFragment] {
                if let planned = plannedByChapter[chapter.id] { return planned }
                let planned = try AudiobookFragmentPlanner.plan(
                    chapter: chapter, annotations: annotations[chapter.id] ?? [], bindings: bindings,
                    policy: policy, source: source, atoms: atoms[chapter.id] ?? [],
                    pronunciation: pronunciation
                )
                plannedByChapter[chapter.id] = planned
                return planned
            }
            func matchesCurrentDependencies(_ revision: AudiobookChapterRevision, chapter: AudiobookChapter) -> Bool {
                guard let planned = try? plannedFragments(for: chapter),
                      revision.orderedBindings.count == planned.count else { return false }
                return zip(revision.orderedBindings, planned).allSatisfy { binding, fragment in
                    binding.fragmentID == fragment.id && binding.sourceRange == fragment.sourceRange
                        && binding.dependencyDigest == fragment.dependencyDigest && assetIsValid(binding)
                }
            }

            let revision: AudiobookChapterRevision
            if isUndo {
                revision = proposed
                chapter.previousChapterRevisionID = nil
            } else {
                let planned = try plannedFragments(for: chapter)
                guard proposed.orderedBindings.count == planned.count else {
                    throw AudiobookRevisionError.incompleteChapterCoverage(
                        chapterID: chapter.id, missingFragmentIDs: planned.map(\.id)
                    )
                }
                for (binding, fragment) in zip(proposed.orderedBindings, planned) {
                    guard binding.fragmentID == fragment.id, binding.sourceRange == fragment.sourceRange,
                          binding.dependencyDigest == fragment.dependencyDigest else {
                        throw AudiobookRevisionError.staleCandidateDependency(candidateID: binding.candidateID)
                    }
                    guard assetIsValid(binding) else {
                        throw AudiobookRevisionError.unverifiedCandidateProvenance(candidateID: binding.candidateID)
                    }
                }
                revision = AudiobookChapterRevision(
                    id: proposed.id, bookID: bookID, chapterID: chapter.id, sourceID: book.sourceID,
                    revisionNumber: (history.map(\.revisionNumber).max() ?? 0) + 1,
                    orderedBindings: proposed.orderedBindings, totalFrameCount: proposed.totalFrameCount,
                    sampleRate: proposed.sampleRate, createdAt: proposed.createdAt
                )
                if try fetchFragments(bookID: bookID, chapterID: chapter.id) != planned {
                    try executePrepared(
                        "DELETE FROM fragments WHERE book_id = ? AND chapter_id = ?;",
                        [.text(bookID.uuidString), .text(chapter.id.uuidString)]
                    )
                    for fragment in planned { try upsertFragmentRow(fragment) }
                }
                try upsertChapterRevisionRow(revision)
                chapter.previousChapterRevisionID = chapter.currentChapterRevisionID
            }
            chapter.currentChapterRevisionID = revision.id
            try upsertChapterRow(chapter)
            chapters[index] = chapter

            var currentMap: [UUID: UUID] = [:]
            var histories: [[AudiobookChapterRevision]] = []
            for item in chapters {
                let revisions = item.id == chapter.id
                    ? (isUndo ? history : history + [revision])
                    : try fetchChapterRevisions(bookID: bookID, chapterID: item.id)
                if let current = revisions.first(where: { $0.id == item.currentChapterRevisionID }),
                   matchesCurrentDependencies(current, chapter: item) {
                    currentMap[item.id] = current.id
                }
                histories.append(revisions)
            }
            if currentMap.count == chapters.count {
                let production = AudiobookProductionRevision(
                    bookID: bookID, sourceID: book.sourceID, chapterRevisionIDsByChapter: currentMap
                )
                try upsertProductionRevisionRow(production)
                book.currentProductionRevisionID = production.id
                if updateBookProductionState { book.productionState = .fullBookProduced }
                book.listenableState = .fullBookListenable
            } else if !currentMap.isEmpty {
                book.currentProductionRevisionID = nil
                if updateBookProductionState { book.productionState = .partialChaptersReady }
                book.listenableState = .partialChaptersListenable
            } else {
                book.currentProductionRevisionID = nil
                let hasPreviousAudio = histories.joined().contains { $0.orderedBindings.allSatisfy(assetIsValid) }
                book.listenableState = hasPreviousAudio ? .previousRevisionAvailable : .noneAvailable
            }
            book.updatedAt = Date()
            try upsertBookRow(book)
            return (revision, true)
        }
        if didChange { startupRunningBookUpdatedAt.removeValue(forKey: bookID) }
        return published
    }

    public func saveChapterRevision(
        _ revision: AudiobookChapterRevision,
        makeCurrent: Bool
    ) async throws {
        try inTransaction {
            try upsertChapterRevisionRow(revision)
            if makeCurrent {
                let chapters = try fetchChapters(bookID: revision.bookID)
                if let existing = chapters.first(where: { $0.id == revision.chapterID }) {
                    var updated = existing
                    if let currentID = existing.currentChapterRevisionID, currentID != revision.id {
                        updated.previousChapterRevisionID = currentID
                    }
                    updated.currentChapterRevisionID = revision.id
                    try upsertChapterRow(updated)
                }
            }
        }
    }

    public func saveProductionRevision(_ revision: AudiobookProductionRevision, makeCurrent: Bool = true) async throws {
        try inTransaction {
            if makeCurrent, try fetchBook(id: revision.bookID)?.sourceID != revision.sourceID {
                throw AudiobookStoreError.workingSourceChanged
            }

            try upsertProductionRevisionRow(revision)
            if makeCurrent, var book = try fetchBook(id: revision.bookID) {
                book.currentProductionRevisionID = revision.id
                book.updatedAt = Date()
                try upsertBookRow(book)
            }
        }
    }

    public func productionRevisions(for bookID: UUID) async throws -> [AudiobookProductionRevision] {
        try fetchProductionRevisions(bookID: bookID)
    }

    public func bookmark(for bookID: UUID) async throws -> AudiobookBookmark? {
        try fetchBookmark(bookID: bookID)
    }

    public func saveBookmark(_ bookmark: AudiobookBookmark) async throws {
        try inTransaction {
            try upsertBookmarkRow(bookmark)
        }
    }

    public func saveExportRecord(_ record: AudiobookExportRecord) async throws {
        try inTransaction {
            try upsertExportRecordRow(record)
        }
    }

    public func exportRecords(for bookID: UUID) async throws -> [AudiobookExportRecord] {
        try fetchExportRecords(bookID: bookID)
    }

    // MARK: - Pronunciation Binding

    /// 读取本书最近一次确认保存的发音规则快照；没有保存过时返回 nil。
    public func pronunciationBinding(for bookID: UUID) throws -> AudiobookPronunciationBinding? {
        try withPrepared(
            "SELECT set_id, revision, entries_json FROM pronunciation_bindings WHERE book_id = ?;",
            [.text(bookID.uuidString)]
        ) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  let setID = columnText(stmt, 0),
                  let revision = columnText(stmt, 1),
                  let entriesJSON = columnText(stmt, 2)
            else { return nil }
            let entries = try JSONDecoder().decode([PronunciationEntry].self, from: Data(entriesJSON.utf8))
            return AudiobookPronunciationBinding(setID: setID, revision: revision, entries: entries)
        }
    }

    public func savePronunciationBinding(
        _ binding: AudiobookPronunciationBinding,
        bookID: UUID
    ) throws {
        let entriesJSON = String(decoding: try JSONEncoder().encode(binding.entries), as: UTF8.self)
        try inTransaction {
            guard try fetchBook(id: bookID) != nil else { throw AudiobookStoreError.bookNotFound(bookID) }
            try executePrepared("""
                INSERT INTO pronunciation_bindings (book_id, set_id, revision, entries_json, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(book_id) DO UPDATE SET
                    set_id = excluded.set_id,
                    revision = excluded.revision,
                    entries_json = excluded.entries_json,
                    updated_at = excluded.updated_at;
                """, [
                    .text(bookID.uuidString),
                    .text(binding.setID),
                    .text(binding.revision),
                    .text(entriesJSON),
                    .real(Date().timeIntervalSince1970),
                ])
            try refreshPronunciationDependencies(bookID: bookID, pronunciation: binding)
        }
    }

    public func deletePronunciationBinding(bookID: UUID) throws {
        try inTransaction {
            try executePrepared(
                "DELETE FROM pronunciation_bindings WHERE book_id = ?;",
                [.text(bookID.uuidString)]
            )
            try refreshPronunciationDependencies(bookID: bookID, pronunciation: nil)
        }
    }

    private func refreshPronunciationDependencies(
        bookID: UUID,
        pronunciation: AudiobookPronunciationBinding?
    ) throws {
        let fragments = try fetchFragments(bookID: bookID, chapterID: nil)
        guard !fragments.isEmpty else { return }
        let chapters = try fetchChapters(bookID: bookID)
        let chaptersByID = Dictionary(uniqueKeysWithValues: chapters.map { ($0.id, $0) })
        guard let source = try? workingSourceSnapshot(bookID: bookID).sourceIndex else { return }
        for fragment in fragments {
            guard let chapter = chaptersByID[fragment.chapterID] else { continue }
            let fragmentText = try? source.text(in: fragment.sourceRange)
            let dependency = AudiobookFragmentPlanner.dependencyDigest(
                fragmentText: fragmentText,
                sourceID: chapter.sourceID,
                sourceRange: fragment.sourceRange,
                localAssignmentDigest: fragment.localAssignmentDigest,
                voiceDigest: fragment.voiceBindingDigest,
                policyDigest: fragment.policyDigest,
                pronunciation: pronunciation
            )
            guard dependency != fragment.dependencyDigest else { continue }
            try upsertFragmentRow(
                .init(
                    id: fragment.id,
                    bookID: bookID,
                    chapterID: fragment.chapterID,
                    ordinal: fragment.ordinal,
                    roleID: fragment.roleID,
                    sourceRange: fragment.sourceRange,
                    atomIDs: fragment.atomIDs,
                    localAssignmentDigest: fragment.localAssignmentDigest,
                    voiceBindingDigest: fragment.voiceBindingDigest,
                    policyDigest: fragment.policyDigest,
                    dependencyDigest: dependency
                )
            )
        }
    }

    // MARK: - Transactional Asset Commit & Crash Recovery

    public func commitCandidate(_ candidate: AudiobookRenderCandidate, wav: Data, requireCurrentSource: Bool = false) async throws {
        if requireCurrentSource {
            try requireActiveChapter(bookID: candidate.bookID, chapterID: candidate.chapterID)
        }
        if simulateDiskFullOnWrite {
            throw AudiobookStoreError.diskFull
        }

        // Validate WAV & PCM digest before touching disk or DB
        let computedFileSHA = AudiobookDigest.sha256Hex(wav)
        let computedPCMSHA: String
        do {
            computedPCMSHA = try AudioDigest.sha256HexOfPCM(in: wav)
        } catch {
            throw AudiobookStoreError.invalidWAVAsset("WAV 缺少有效的 RIFF/data 数据块。")
        }

        guard computedFileSHA == candidate.fileSHA256,
              computedPCMSHA == candidate.pcmSHA256
        else {
            throw AudiobookStoreError.invalidWAVAsset("WAV 文件或 PCM 摘要与候选声明不一致。")
        }

        // Idempotency check if candidate ID already exists
        if let existing = try fetchCandidate(bookID: candidate.bookID, candidateID: candidate.id) {
            if existing.fileSHA256 == candidate.fileSHA256,
               existing.pcmSHA256 == candidate.pcmSHA256,
               existing.dependencyDigest == candidate.dependencyDigest
            {
                return
            }
            throw AudiobookStoreError.conflictingCandidateDigest(candidate.id)
        }

        let finalURL = try resolveOwnedURL(relativePath: candidate.relativeAssetPath)
        let tempRelPath = "books/\(candidate.bookID.uuidString)/tmp/\(candidate.id.uuidString).tmp.wav"
        let tempURL = try resolveOwnedURL(relativePath: tempRelPath)

        try FileManager.default.createDirectory(
            at: tempURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: finalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Stage 1: Write journal (`journalStarted`)
        var journalEntry = AudiobookAssetJournalEntry(
            candidate: candidate,
            tempRelativePath: tempRelPath,
            state: .journalStarted
        )
        try assetJournal.write(journalEntry)
        try upsertAssetTransactionRow(entry: journalEntry)
        if simulatedCrashStage == .afterJournalStarted {
            throw AudiobookStoreError.simulatedCrash(.afterJournalStarted)
        }

        // Stage 2: Write temporary WAV and verify read-back
        try wav.write(to: tempURL, options: .atomic)
        let tempReadBack = try Data(contentsOf: tempURL)
        guard AudiobookDigest.sha256Hex(tempReadBack) == candidate.fileSHA256 else {
            throw AudiobookStoreError.invalidWAVAsset("临时 WAV 写入后读回校验不通过。")
        }
        journalEntry.state = .tempWritten
        journalEntry.updatedAt = Date()
        try assetJournal.write(journalEntry)
        try upsertAssetTransactionRow(entry: journalEntry)
        if simulatedCrashStage == .afterTempAssetWritten {
            throw AudiobookStoreError.simulatedCrash(.afterTempAssetWritten)
        }

        // Stage 3: Move temp asset to owned destination
        if FileManager.default.fileExists(atPath: finalURL.path) {
            _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: finalURL)
        }
        journalEntry.state = .assetMoved
        journalEntry.updatedAt = Date()
        try assetJournal.write(journalEntry)
        try upsertAssetTransactionRow(entry: journalEntry)
        if simulatedCrashStage == .afterAssetRenamed {
            throw AudiobookStoreError.simulatedCrash(.afterAssetRenamed)
        }

        // Stage 4: Commit SQLite reference and read-back verify
        try inTransaction {
            try upsertCandidateRow(candidate)
            journalEntry.state = .dbCommitted
            journalEntry.updatedAt = Date()
            try upsertAssetTransactionRow(entry: journalEntry)
        }
        guard let committed = try fetchCandidate(bookID: candidate.bookID, candidateID: candidate.id),
              committed.fileSHA256 == candidate.fileSHA256
        else {
            throw AudiobookStoreError.statementFailed("候选写入后读回核对失败。")
        }
        let finalReadBack = try Data(contentsOf: finalURL)
        guard AudiobookDigest.sha256Hex(finalReadBack) == candidate.fileSHA256 else {
            throw AudiobookStoreError.invalidWAVAsset("正式 WAV 落盘读回校验失败。")
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: finalURL.path),
           let fileSize = (attrs[.size] as? NSNumber)?.int64Value,
           let modDate = attrs[.modificationDate] as? Date {
            verifiedWAVAssetCache[finalURL.path] = (
                fileSize: fileSize,
                modTime: modDate.timeIntervalSince1970,
                fileSHA: candidate.fileSHA256,
                pcmSHA: candidate.pcmSHA256
            )
        }
        if simulatedCrashStage == .afterDatabaseCommitted {
            throw AudiobookStoreError.simulatedCrash(.afterDatabaseCommitted)
        }

        // Stage 5: Finalize journal
        journalEntry.state = .completed
        journalEntry.updatedAt = Date()
        try upsertAssetTransactionRow(entry: journalEntry)
        assetJournal.remove(bookID: candidate.bookID, candidateID: candidate.id)
        if simulatedCrashStage == .afterJournalCompleted {
            throw AudiobookStoreError.simulatedCrash(.afterJournalCompleted)
        }
    }

    public func recover() async throws -> AudiobookRecoveryReport {
        try recoverBooks(try fetchAllBooksOrdered())
    }

    public func recover(bookID: UUID) async throws -> AudiobookRecoveryReport {
        guard let book = try fetchBook(id: bookID) else {
            throw AudiobookStoreError.bookNotFound(bookID)
        }
        return try recoverBooks([book])
    }

    private func recoverBooks(_ books: [AudiobookBook]) throws -> AudiobookRecoveryReport {
        if !didApplyStartupRecovery {
            try applyStartupRecovery()
            didApplyStartupRecovery = true
            startupRunningBookUpdatedAt.removeAll()
        }

        var verifiedIDs: [UUID] = []
        var recoveredIDs: [UUID] = []
        var quarantinedPaths: [String] = []
        var preservedUnknownPaths: [String] = []
        var damagedIDs: [UUID] = []

        for book in books {
            recoveredBookIDsHistoryForTest.append(book.id)
            // 1. Reconcile pending sidecar journal entries and SQLite asset_transactions
            let sidecarEntries = assetJournal.pendingEntries(bookID: book.id)
            let dbEntries = try fetchPendingAssetTransactions(bookID: book.id)
            var mergedByCandidateID: [UUID: AudiobookAssetJournalEntry] = [:]
            for e in dbEntries { mergedByCandidateID[e.candidate.id] = e }
            for e in sidecarEntries { mergedByCandidateID[e.candidate.id] = e }

            for (_, var entry) in mergedByCandidateID {
                let candidate = entry.candidate
                let finalURL = try resolveOwnedURL(relativePath: candidate.relativeAssetPath)
                let tempURL = try resolveOwnedURL(relativePath: entry.tempRelativePath)

                let finalValid = isValidWAVAsset(at: finalURL, expectedFileSHA: candidate.fileSHA256, expectedPCMSHA: candidate.pcmSHA256)
                let tempValid = isValidWAVAsset(at: tempURL, expectedFileSHA: candidate.fileSHA256, expectedPCMSHA: candidate.pcmSHA256)

                if finalValid {
                    // Promote or complete DB commit if needed
                    if try fetchCandidate(bookID: book.id, candidateID: candidate.id) == nil {
                        try inTransaction {
                            try upsertCandidateRow(candidate)
                        }
                    }
                    if FileManager.default.fileExists(atPath: tempURL.path) {
                        try? FileManager.default.removeItem(at: tempURL)
                    }
                    entry.state = .completed
                    try upsertAssetTransactionRow(entry: entry)
                    assetJournal.remove(bookID: book.id, candidateID: candidate.id)
                    recoveredIDs.append(candidate.id)
                } else if tempValid {
                    // Move valid temp asset to final URL and commit DB reference
                    try FileManager.default.createDirectory(
                        at: finalURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if FileManager.default.fileExists(atPath: finalURL.path) {
                        _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: tempURL)
                    } else {
                        try FileManager.default.moveItem(at: tempURL, to: finalURL)
                    }
                    try inTransaction {
                        try upsertCandidateRow(candidate)
                    }
                    entry.state = .completed
                    try upsertAssetTransactionRow(entry: entry)
                    assetJournal.remove(bookID: book.id, candidateID: candidate.id)
                    recoveredIDs.append(candidate.id)
                } else {
                    // Neither temp nor final has a complete valid asset; quarantine known temp/incomplete file
                    if FileManager.default.fileExists(atPath: tempURL.path) {
                        let qRel = try quarantineKnownFile(at: tempURL, bookID: book.id)
                        quarantinedPaths.append(qRel)
                    }
                    if FileManager.default.fileExists(atPath: finalURL.path),
                       try fetchCandidate(bookID: book.id, candidateID: candidate.id) == nil
                    {
                        let qRel = try quarantineKnownFile(at: finalURL, bookID: book.id)
                        quarantinedPaths.append(qRel)
                    }
                    entry.state = .quarantined
                    try upsertAssetTransactionRow(entry: entry)
                    assetJournal.remove(bookID: book.id, candidateID: candidate.id)
                }
            }

            // 2. Audit all committed render candidates for this book
            let committedCandidates = try fetchCandidates(bookID: book.id, fragmentID: nil)
            var referencedRelPaths = Set<String>()
            for candidate in committedCandidates {
                referencedRelPaths.insert(candidate.relativeAssetPath)
                let assetURL = try resolveOwnedURL(relativePath: candidate.relativeAssetPath)
                if isValidWAVAsset(
                    at: assetURL,
                    expectedFileSHA: candidate.fileSHA256,
                    expectedPCMSHA: candidate.pcmSHA256
                ) {
                    if !recoveredIDs.contains(candidate.id) {
                        verifiedIDs.append(candidate.id)
                    }
                } else {
                    damagedIDs.append(candidate.id)
                }
            }

            // 3. Inspect `audio/` directory for unknown files — preserve unknown files, never delete them!
            let audioDir = try bookDirectory(for: book.id, create: false)
                .appendingPathComponent("audio", isDirectory: true)
            if let urls = try? FileManager.default.contentsOfDirectory(
                at: audioDir,
                includingPropertiesForKeys: nil
            ) {
                for url in urls {
                    let rel = "books/\(book.id.uuidString)/audio/\(url.lastPathComponent)"
                    if !referencedRelPaths.contains(rel) {
                        preservedUnknownPaths.append(rel)
                    }
                }
            }
        }

        return AudiobookRecoveryReport(
            verifiedCandidateIDs: verifiedIDs,
            recoveredCandidateIDs: recoveredIDs,
            quarantinedRelativePaths: quarantinedPaths,
            preservedUnknownRelativePaths: preservedUnknownPaths,
            damagedCandidateIDs: damagedIDs
        )
    }

    private func applyStartupRecovery() throws {
        guard !startupRunningBookUpdatedAt.isEmpty else { return }

        try inTransaction {
            for (bookID, startupUpdatedAt) in startupRunningBookUpdatedAt {
                guard var book = try fetchBook(id: bookID),
                      book.updatedAt.timeIntervalSince1970 == startupUpdatedAt
                else {
                    continue
                }

                var changed = false
                if book.analysisState == .running {
                    book.analysisState = .paused
                    changed = true
                }
                if book.productionState == .running || book.productionState == .pausing {
                    book.productionState = .paused
                    changed = true
                }
                guard changed else { continue }

                book.updatedAt = Date()
                try upsertBookRow(book)
            }
        }
    }

    public func verifyCandidateAsset(_ candidate: AudiobookRenderCandidate) throws -> Bool {
        let url = try resolveOwnedURL(relativePath: candidate.relativeAssetPath)
        return isValidWAVAsset(
            at: url,
            expectedFileSHA: candidate.fileSHA256,
            expectedPCMSHA: candidate.pcmSHA256
        )
    }

    public func resolveAssetFileURL(for candidate: AudiobookRenderCandidate) throws -> URL {
        let url = try resolveOwnedURL(relativePath: candidate.relativeAssetPath)
        guard isValidWAVAsset(
            at: url,
            expectedFileSHA: candidate.fileSHA256,
            expectedPCMSHA: candidate.pcmSHA256
        ) else {
            throw AudiobookStoreError.corruptedOrMissingAsset(
                candidateID: candidate.id,
                relativePath: candidate.relativeAssetPath
            )
        }
        return url
    }

    // MARK: - Recoverable Trash Management

    public func trashBook(id: UUID) async throws {
        guard let book = try fetchBook(id: id) else {
            throw AudiobookStoreError.bookNotFound(id)
        }
        let bookDir = try bookDirectory(for: id, create: false)
        if try Self.isSymbolicLink(at: bookDir) {
            throw AudiobookStoreError.symlinkRejected(bookDir.lastPathComponent)
        }

        let trashRoot = rootURL.appendingPathComponent(".trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)

        let timestamp = Int(Date().timeIntervalSince1970)
        let trashFolderName = "\(id.uuidString)-\(timestamp)"
        let destinationDir = trashRoot.appendingPathComponent(trashFolderName, isDirectory: true)

        // Export book snapshot inside the trash bundle so it can be restored if needed
        let snapshot = try exportBookSnapshot(bookID: id)
        if FileManager.default.fileExists(atPath: bookDir.path) {
            try FileManager.default.moveItem(at: bookDir, to: destinationDir)
        } else {
            try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        }

        let snapshotURL = destinationDir.appendingPathComponent("trash-snapshot.json", isDirectory: false)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try JSONEncoder().encode(snapshot).write(to: snapshotURL, options: .atomic)

        let meta = AudiobookTrashedBookEntry(
            id: book.id,
            title: book.title,
            author: book.author,
            trashedAt: Date(),
            trashDirectoryName: trashFolderName,
            byteSize: Self.directoryByteSize(at: destinationDir)
        )
        let metaURL = destinationDir.appendingPathComponent("trash-meta.json", isDirectory: false)
        try encoder.encode(meta).write(to: metaURL, options: .atomic)

        try inTransaction {
            try executePrepared("DELETE FROM books WHERE id = ?;", [.text(id.uuidString)])
        }
        cachedSourceIndices.removeValue(forKey: id)
        cachedCharactersByBook.removeValue(forKey: id)
        cachedAnnotationsByBook.removeValue(forKey: id)
    }

    public func listTrashedBooks() async throws -> [AudiobookTrashedBookEntry] {
        let trashRoot = rootURL.appendingPathComponent(".trash", isDirectory: true)
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: trashRoot,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return dirs
            .compactMap { dir -> AudiobookTrashedBookEntry? in
                let metaURL = dir.appendingPathComponent("trash-meta.json", isDirectory: false)
                guard let data = try? Data(contentsOf: metaURL) else { return nil }
                return try? decoder.decode(AudiobookTrashedBookEntry.self, from: data)
            }
            .sorted { $0.trashedAt > $1.trashedAt }
    }

    public func restoreTrashedBook(id: UUID) async throws {
        let entries = try await listTrashedBooks()
        guard let entry = entries.first(where: { $0.id == id }) else {
            throw AudiobookStoreError.bookNotFound(id)
        }
        let trashDir = rootURL
            .appendingPathComponent(".trash", isDirectory: true)
            .appendingPathComponent(entry.trashDirectoryName, isDirectory: true)
        let snapshotURL = trashDir.appendingPathComponent("trash-snapshot.json", isDirectory: false)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshotData = try Data(contentsOf: snapshotURL)
        let snapshot: AudiobookTrashSnapshot
        if let precise = try? JSONDecoder().decode(AudiobookTrashSnapshot.self, from: snapshotData) { snapshot = precise }
        else { snapshot = try decoder.decode(AudiobookTrashSnapshot.self, from: snapshotData) }

        let restoredBookDir = try bookDirectory(for: id, create: false)
        try FileManager.default.createDirectory(
            at: restoredBookDir.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: restoredBookDir.path) {
            try FileManager.default.removeItem(at: restoredBookDir)
        }
        try FileManager.default.moveItem(at: trashDir, to: restoredBookDir)
        try? FileManager.default.removeItem(at: restoredBookDir.appendingPathComponent("trash-snapshot.json"))
        try? FileManager.default.removeItem(at: restoredBookDir.appendingPathComponent("trash-meta.json"))

        try inTransaction {
            try restoreBookSnapshot(snapshot)
        }
        cachedSourceIndices.removeValue(forKey: id)
        cachedCharactersByBook.removeValue(forKey: id)
        cachedAnnotationsByBook.removeValue(forKey: id)
    }

    public func permanentlyDeleteTrashedBook(id: UUID) async throws {
        let entries = try await listTrashedBooks()
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        let trashDir = rootURL
            .appendingPathComponent(".trash", isDirectory: true)
            .appendingPathComponent(entry.trashDirectoryName, isDirectory: true)
        if try Self.isSymbolicLink(at: trashDir) {
            throw AudiobookStoreError.symlinkRejected(trashDir.lastPathComponent)
        }
        try? FileManager.default.removeItem(at: trashDir)
    }

    // MARK: - Private Path & Validation Helpers

    private func bookDirectory(for bookID: UUID, create: Bool) throws -> URL {
        let dir = rootURL
            .appendingPathComponent("books", isDirectory: true)
            .appendingPathComponent(bookID.uuidString, isDirectory: true)
            .standardizedFileURL
        if create {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if FileManager.default.fileExists(atPath: dir.path), try Self.isSymbolicLink(at: dir) {
            throw AudiobookStoreError.symlinkRejected(dir.lastPathComponent)
        }
        return dir
    }

    public func resolveOwnedURL(relativePath: String) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.contains(".."),
              !trimmed.contains("://")
        else {
            throw AudiobookStoreError.invalidRelativePath(relativePath)
        }
        let resolved = rootURL.appendingPathComponent(trimmed, isDirectory: false).standardizedFileURL
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard resolved.path.hasPrefix(rootPrefix) else {
            throw AudiobookStoreError.invalidRelativePath(relativePath)
        }
        if FileManager.default.fileExists(atPath: resolved.path), try Self.isSymbolicLink(at: resolved) {
            throw AudiobookStoreError.symlinkRejected(relativePath)
        }
        return resolved
    }

    private func isValidWAVAsset(at url: URL, expectedFileSHA: String, expectedPCMSHA: String) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              (try? Self.isSymbolicLink(at: url)) == false
        else {
            verifiedWAVAssetCache.removeValue(forKey: url.path)
            return false
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = (attrs[.size] as? NSNumber)?.int64Value,
              let modDate = attrs[.modificationDate] as? Date
        else {
            verifiedWAVAssetCache.removeValue(forKey: url.path)
            return false
        }
        let modTime = modDate.timeIntervalSince1970
        if let cached = verifiedWAVAssetCache[url.path],
           cached.fileSize == fileSize,
           abs(cached.modTime - modTime) < 0.001 {
            return cached.fileSHA == expectedFileSHA && cached.pcmSHA == expectedPCMSHA
        }
        guard let data = try? Data(contentsOf: url) else {
            verifiedWAVAssetCache.removeValue(forKey: url.path)
            return false
        }
        let fileSHA = AudiobookDigest.sha256Hex(data)
        guard fileSHA == expectedFileSHA else {
            verifiedWAVAssetCache.removeValue(forKey: url.path)
            return false
        }
        guard let pcmSHA = try? AudioDigest.sha256HexOfPCM(in: data),
              pcmSHA == expectedPCMSHA
        else {
            verifiedWAVAssetCache.removeValue(forKey: url.path)
            return false
        }
        verifiedWAVAssetCache[url.path] = (fileSize: fileSize, modTime: modTime, fileSHA: fileSHA, pcmSHA: pcmSHA)
        return true
    }

    private func quarantineKnownFile(at url: URL, bookID: UUID) throws -> String {
        verifiedWAVAssetCache.removeValue(forKey: url.path)
        let qDir = try bookDirectory(for: bookID, create: true)
            .appendingPathComponent("quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: qDir, withIntermediateDirectories: true)
        let qName = "\(UUID().uuidString)-\(url.lastPathComponent)"
        let qURL = qDir.appendingPathComponent(qName, isDirectory: false)
        try FileManager.default.moveItem(at: url, to: qURL)
        return "books/\(bookID.uuidString)/quarantine/\(qName)"
    }

    private static func isSymbolicLink(at url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values.isSymbolicLink == true
    }

    private static func directoryByteSize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - Private SQLite Low-Level Primitives

    private enum SQLValue {
        case text(String?)
        case int(Int64?)
        case real(Double?)
    }

    private func requireHandle() throws -> OpaquePointer {
        guard let pointer = handle.pointer else {
            throw AudiobookStoreError.storageUnavailable("Database handle is closed")
        }
        return pointer
    }

    private static func queryUserVersion(_ pointer: OpaquePointer) throws -> Int32 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(pointer, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK,
              let stmt
        else {
            throw AudiobookStoreError.statementFailed(String(cString: sqlite3_errmsg(pointer)))
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(stmt, 0)
    }

    private static func queryStartupRunningBookUpdatedAt(_ pointer: OpaquePointer) throws -> [UUID: Double] {
        let sql = """
        SELECT id, updated_at
        FROM books
        WHERE analysis_state = '\(AudiobookAnalysisState.running.rawValue)'
           OR production_state IN ('\(AudiobookProductionState.running.rawValue)', '\(AudiobookProductionState.pausing.rawValue)');
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(pointer, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt
        else {
            throw AudiobookStoreError.statementFailed(String(cString: sqlite3_errmsg(pointer)))
        }
        defer { sqlite3_finalize(stmt) }

        var snapshots: [UUID: Double] = [:]
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw AudiobookStoreError.statementFailed(String(cString: sqlite3_errmsg(pointer)))
            }
            guard let idString = columnText(stmt, 0), let id = UUID(uuidString: idString) else { continue }
            snapshots[id] = sqlite3_column_double(stmt, 1)
        }
        return snapshots
    }

    private static func execSQL(_ pointer: OpaquePointer, _ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(pointer, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let detail = errMsg.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(pointer))
            sqlite3_free(errMsg)
            throw AudiobookStoreError.statementFailed(detail)
        }
    }

    private func inReadTransaction<T>(_ block: () throws -> T) throws -> T {
        let pointer = try requireHandle()
        try Self.execSQL(pointer, "BEGIN DEFERRED TRANSACTION;")
        do {
            let result = try block()
            try Self.execSQL(pointer, "COMMIT TRANSACTION;")
            return result
        } catch {
            try? Self.execSQL(pointer, "ROLLBACK TRANSACTION;")
            throw error
        }
    }

    private func inTransaction<T>(_ block: () throws -> T) throws -> T {
        let pointer = try requireHandle()
        try Self.execSQL(pointer, "BEGIN IMMEDIATE TRANSACTION;")
        do {
            let result = try block()
            try Self.execSQL(pointer, "COMMIT TRANSACTION;")
            return result
        } catch {
            try? Self.execSQL(pointer, "ROLLBACK TRANSACTION;")
            throw error
        }
    }

    private func withPrepared<T>(_ sql: String, _ args: [SQLValue] = [], _ body: (OpaquePointer) throws -> T) throws -> T {
        let pointer = try requireHandle()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(pointer, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw AudiobookStoreError.statementFailed(String(cString: sqlite3_errmsg(pointer)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case let .text(val):
                bind(stmt, idx, val)
            case let .int(val):
                if let val {
                    sqlite3_bind_int64(stmt, idx, val)
                } else {
                    sqlite3_bind_null(stmt, idx)
                }
            case let .real(val):
                bind(stmt, idx, val)
            }
        }
        return try body(stmt)
    }

    private func executePrepared(_ sql: String, _ args: [SQLValue] = []) throws {
        try withPrepared(sql, args) { stmt in
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
                let pointer = try requireHandle()
                throw AudiobookStoreError.statementFailed(String(cString: sqlite3_errmsg(pointer)))
            }
        }
    }

    private func requireActiveChapter(bookID: UUID, chapterID: UUID) throws {
        guard try countRows("SELECT COUNT(*) FROM chapters WHERE book_id = ? AND id = ? AND source_id = (SELECT source_id FROM books WHERE id = chapters.book_id);",
            [.text(bookID.uuidString), .text(chapterID.uuidString)]) == 1 else { throw AudiobookStoreError.workingSourceChanged }
    }

    // MARK: - Private Row Mapping

    private func insertBookRow(_ book: AudiobookBook) throws {
        try upsertBookRow(book)
    }

    private func upsertBookRow(_ book: AudiobookBook) throws {
        let sql = """
        INSERT INTO books (
            id, source_id, title, author, source_sha256, canonical_byte_count, scalar_count,
            original_encoding, analysis_state, production_state, listenable_state,
            confirmed_cast_revision_id, confirmed_audition_digest, current_production_revision_id,
            created_at, updated_at, analysis_failure_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            author = excluded.author,
            analysis_state = excluded.analysis_state,
            production_state = excluded.production_state,
            listenable_state = excluded.listenable_state,
            confirmed_cast_revision_id = excluded.confirmed_cast_revision_id,
            confirmed_audition_digest = excluded.confirmed_audition_digest,
            current_production_revision_id = excluded.current_production_revision_id,
            updated_at = excluded.updated_at,
            analysis_failure_json = excluded.analysis_failure_json;
        """
        try executePrepared(sql, [
            .text(book.id.uuidString),
            .text(book.sourceID.uuidString),
            .text(book.title),
            .text(book.author),
            .text(book.sourceSHA256),
            .int(book.canonicalByteCount),
            .int(Int64(book.scalarCount)),
            .text(book.originalEncoding),
            .text(book.analysisState.rawValue),
            .text(book.productionState.rawValue),
            .text(book.listenableState.rawValue),
            .text(book.confirmedCastRevisionID?.uuidString),
            .text(book.confirmedAuditionVoiceSetDigest),
            .text(book.currentProductionRevisionID?.uuidString),
            .real(book.createdAt.timeIntervalSince1970),
            .real(book.updatedAt.timeIntervalSince1970),
            .text(book.analysisFailure.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }),
        ])
    }

    private func insertSourceRow(
        bookID: UUID,
        sourceID: UUID,
        sha256: String,
        byteCount: Int64,
        scalarCount: Int,
        encoding: String,
        originalRelPath: String,
        canonicalRelPath: String,
        createdAt: Date
    ) throws {
        let sql = """
        INSERT OR REPLACE INTO sources (
            id, book_id, sha256, canonical_byte_count, scalar_count,
            original_encoding, original_rel_path, canonical_rel_path, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try executePrepared(sql, [
            .text(sourceID.uuidString),
            .text(bookID.uuidString),
            .text(sha256),
            .int(byteCount),
            .int(Int64(scalarCount)),
            .text(encoding),
            .text(originalRelPath),
            .text(canonicalRelPath),
            .real(createdAt.timeIntervalSince1970),
        ])
    }

    private func upsertChapterRow(_ chapter: AudiobookChapter) throws {
        let excludedJSON = try String(data: JSONEncoder().encode(chapter.excludedRanges), encoding: .utf8) ?? "[]"
        let sql = """
        INSERT INTO chapters (
            id, book_id, source_id, ordinal, title, lower_bound, upper_bound,
            excluded_ranges_json, is_skipped, current_chapter_revision_id, previous_chapter_revision_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(book_id, id) DO UPDATE SET
            ordinal = excluded.ordinal,
            title = excluded.title,
            lower_bound = excluded.lower_bound,
            upper_bound = excluded.upper_bound,
            excluded_ranges_json = excluded.excluded_ranges_json,
            is_skipped = excluded.is_skipped,
            current_chapter_revision_id = excluded.current_chapter_revision_id,
            previous_chapter_revision_id = excluded.previous_chapter_revision_id;
        """
        try executePrepared(sql, [
            .text(chapter.id.uuidString),
            .text(chapter.bookID.uuidString),
            .text(chapter.sourceID.uuidString),
            .int(Int64(chapter.ordinal)),
            .text(chapter.title),
            .int(chapter.sourceRange.lowerBound),
            .int(chapter.sourceRange.upperBound),
            .text(excludedJSON),
            .int(chapter.isSkipped ? 1 : 0),
            .text(chapter.currentChapterRevisionID?.uuidString),
            .text(chapter.previousChapterRevisionID?.uuidString),
        ])
    }

    private func insertAtomRow(bookID: UUID, atom: AudiobookTextAtom) throws {
        let sql = """
        INSERT OR REPLACE INTO text_atoms (
            id, book_id, chapter_id, ordinal, lower_bound, upper_bound, kind
        ) VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        try executePrepared(sql, [
            .text(atom.id.uuidString),
            .text(bookID.uuidString),
            .text(atom.chapterID.uuidString),
            .int(Int64(atom.ordinal)),
            .int(atom.sourceRange.lowerBound),
            .int(atom.sourceRange.upperBound),
            .text(atom.kind.rawValue),
        ])
    }

    private func upsertCharacterRow(_ character: AudiobookCharacter, historicalSourceID: UUID? = nil) throws {
        let existingSource: String? = try withPrepared("SELECT source_id FROM characters WHERE book_id = ? AND id = ?;",
            [.text(character.bookID.uuidString), .text(character.id.uuidString)]) { stmt in
                sqlite3_step(stmt) == SQLITE_ROW ? columnText(stmt, 0) : nil
            }
        guard let sourceID = try historicalSourceID ?? fetchBook(id: character.bookID)?.sourceID,
              existingSource == nil || existingSource == sourceID.uuidString else { throw AudiobookStoreError.workingSourceChanged }
        let aliasesJSON = try String(data: JSONEncoder().encode(character.aliases), encoding: .utf8) ?? "[]"
        let evidencesJSON = try String(data: JSONEncoder().encode(character.evidences), encoding: .utf8) ?? "[]"
        let chapterIDsJSON = try String(data: JSONEncoder().encode(character.chapterIDs), encoding: .utf8) ?? "[]"
        let sql = """
        INSERT INTO characters (
            id, book_id, source_id, display_name, aliases_json, is_narrator, is_major,
            allow_shared_minor_voice, evidences_json, first_lower_bound, first_upper_bound, chapter_ids_json, voice_policy_json, manual_tier, voice_traits_json, required_voice_traits_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(book_id, id) DO UPDATE SET
            display_name = excluded.display_name,
            aliases_json = excluded.aliases_json,
            is_narrator = excluded.is_narrator,
            is_major = excluded.is_major,
            allow_shared_minor_voice = excluded.allow_shared_minor_voice,
            evidences_json = excluded.evidences_json,
            first_lower_bound = excluded.first_lower_bound,
            first_upper_bound = excluded.first_upper_bound,
            chapter_ids_json = excluded.chapter_ids_json,
            voice_policy_json = excluded.voice_policy_json,
            manual_tier = excluded.manual_tier,
            voice_traits_json = excluded.voice_traits_json,
            required_voice_traits_json = excluded.required_voice_traits_json;
        """
        try executePrepared(sql, [
            .text(character.id.uuidString),
            .text(character.bookID.uuidString),
            .text(sourceID.uuidString),
            .text(character.displayName),
            .text(aliasesJSON),
            .int(character.isNarrator ? 1 : 0),
            .int(character.isMajor ? 1 : 0),
            .int(character.allowSharedMinorVoice ? 1 : 0),
            .text(evidencesJSON),
            .int(character.firstAppearanceRange?.lowerBound),
            .int(character.firstAppearanceRange?.upperBound),
            .text(chapterIDsJSON),
            .text(try character.voicePolicy.map { String(data: try JSONEncoder().encode($0), encoding: .utf8)! }),
            .text(character.manualTier?.rawValue),
            .text(try character.voiceTraitsOverride.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }),
            .text(try character.requiredVoiceTraits.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }),
        ])
    }

    private func upsertVoiceBindingRow(bookID: UUID, binding: AudiobookVoiceBinding) throws {
        let sql = """
        INSERT INTO voice_bindings (
            book_id, role_id, voice_id, voice_revision, model_revision,
            is_synthesis_ready, allowed_speed, caller_seed, binding_digest
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(book_id, role_id) DO UPDATE SET
            voice_id = excluded.voice_id,
            voice_revision = excluded.voice_revision,
            model_revision = excluded.model_revision,
            is_synthesis_ready = excluded.is_synthesis_ready,
            allowed_speed = excluded.allowed_speed,
            caller_seed = excluded.caller_seed,
            binding_digest = excluded.binding_digest;
        """
        try executePrepared(sql, [
            .text(bookID.uuidString),
            .text(binding.roleID.uuidString),
            .text(binding.voiceID),
            .text(binding.voiceRevision),
            .text(binding.modelRevision),
            .int(binding.isSynthesisReady ? 1 : 0),
            .real(binding.allowedSpeed),
            .int(binding.callerSeed.map(Int64.init)),
            .text(binding.bindingDigest),
        ])
    }

    private func upsertAnalysisWindowRow(_ window: AudiobookAnalysisWindow, restoringHistory: Bool = false) throws {
        if !restoringHistory { try requireActiveChapter(bookID: window.bookID, chapterID: window.chapterID) }
        let primaryJSON = try String(data: JSONEncoder().encode(window.primaryAtomIDs), encoding: .utf8) ?? "[]"
        let leadingJSON = try String(data: JSONEncoder().encode(window.leadingContextAtomIDs), encoding: .utf8) ?? "[]"
        let trailingJSON = try String(data: JSONEncoder().encode(window.trailingContextAtomIDs), encoding: .utf8) ?? "[]"
        let sql = """
        INSERT INTO analysis_windows (
            id, root_window_id, book_id, chapter_id, ordinal,
            primary_atom_ids_json, leading_context_ids_json, trailing_context_ids_json,
            policy_fingerprint, configuration_digest, generation, is_completed
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(book_id, id) DO UPDATE SET
            policy_fingerprint = excluded.policy_fingerprint,
            configuration_digest = excluded.configuration_digest,
            generation = excluded.generation,
            is_completed = excluded.is_completed;
        """
        try executePrepared(sql, [
            .text(window.id.uuidString),
            .text(window.rootWindowID.uuidString),
            .text(window.bookID.uuidString),
            .text(window.chapterID.uuidString),
            .int(Int64(window.ordinal)),
            .text(primaryJSON),
            .text(leadingJSON),
            .text(trailingJSON),
            .text(window.policyFingerprint),
            .text(window.configurationDigest),
            .int(Int64(window.generation)),
            .int(window.isCompleted ? 1 : 0),
        ])
    }

    private func upsertAnnotationRow(_ annotation: AudiobookAnnotation, restoringHistory: Bool = false) throws {
        if !restoringHistory { try requireActiveChapter(bookID: annotation.bookID, chapterID: annotation.chapterID) }
        let assignmentJSON = try String(data: JSONEncoder().encode(annotation.assignment), encoding: .utf8) ?? "{}"
        let sql = """
        INSERT INTO annotations (
            id, book_id, chapter_id, window_id, atom_id, lower_bound, upper_bound,
            assignment_json, evidence, user_confirmed, annotation_revision
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(book_id, atom_id) DO UPDATE SET
            window_id = excluded.window_id,
            assignment_json = excluded.assignment_json,
            evidence = excluded.evidence,
            user_confirmed = excluded.user_confirmed,
            annotation_revision = excluded.annotation_revision;
        """
        try executePrepared(sql, [
            .text(annotation.id.uuidString),
            .text(annotation.bookID.uuidString),
            .text(annotation.chapterID.uuidString),
            .text(annotation.windowID.uuidString),
            .text(annotation.atomID.uuidString),
            .int(annotation.sourceRange.lowerBound),
            .int(annotation.sourceRange.upperBound),
            .text(assignmentJSON),
            .text(annotation.evidence),
            .int(annotation.userConfirmed ? 1 : 0),
            .int(Int64(annotation.annotationRevision)),
        ])
    }

    private func upsertFragmentRow(_ fragment: AudiobookFragment, restoringHistory: Bool = false) throws {
        if !restoringHistory { try requireActiveChapter(bookID: fragment.bookID, chapterID: fragment.chapterID) }
        let atomIDsJSON = try String(data: JSONEncoder().encode(fragment.atomIDs), encoding: .utf8) ?? "[]"
        let sql = """
        INSERT INTO fragments (
            id, book_id, chapter_id, ordinal, role_id, lower_bound, upper_bound,
            atom_ids_json, local_assignment_digest, voice_binding_digest, policy_digest, dependency_digest
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(book_id, id) DO UPDATE SET
            ordinal = excluded.ordinal,
            role_id = excluded.role_id,
            lower_bound = excluded.lower_bound,
            upper_bound = excluded.upper_bound,
            atom_ids_json = excluded.atom_ids_json,
            local_assignment_digest = excluded.local_assignment_digest,
            voice_binding_digest = excluded.voice_binding_digest,
            policy_digest = excluded.policy_digest,
            dependency_digest = excluded.dependency_digest;
        """
        try executePrepared(sql, [
            .text(fragment.id.uuidString),
            .text(fragment.bookID.uuidString),
            .text(fragment.chapterID.uuidString),
            .int(Int64(fragment.ordinal)),
            .text(fragment.roleID.uuidString),
            .int(fragment.sourceRange.lowerBound),
            .int(fragment.sourceRange.upperBound),
            .text(atomIDsJSON),
            .text(fragment.localAssignmentDigest),
            .text(fragment.voiceBindingDigest),
            .text(fragment.policyDigest),
            .text(fragment.dependencyDigest),
        ])
    }

    private func upsertCandidateRow(_ candidate: AudiobookRenderCandidate) throws {
        let sql = """
        INSERT OR REPLACE INTO render_candidates (
            id, book_id, chapter_id, fragment_id, task_id, generation,
            relative_asset_path, file_sha256, pcm_sha256, frame_count, sample_rate,
            dependency_digest, request_id, receipt_digest, recipe_summary, is_receipt_verified, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try executePrepared(sql, [
            .text(candidate.id.uuidString),
            .text(candidate.bookID.uuidString),
            .text(candidate.chapterID.uuidString),
            .text(candidate.fragmentID.uuidString),
            .text(candidate.taskID.uuidString),
            .int(Int64(candidate.generation)),
            .text(candidate.relativeAssetPath),
            .text(candidate.fileSHA256),
            .text(candidate.pcmSHA256),
            .int(candidate.frameCount),
            .int(Int64(candidate.sampleRate)),
            .text(candidate.dependencyDigest),
            .text(candidate.requestID),
            .text(candidate.receiptDigest),
            .text(candidate.recipeSummary),
            .int(candidate.isReceiptVerified ? 1 : 0),
            .real(candidate.createdAt.timeIntervalSince1970),
        ])
    }

    private func upsertChapterRevisionRow(_ revision: AudiobookChapterRevision) throws {
        let bindingsJSON = try String(data: JSONEncoder().encode(revision.orderedBindings), encoding: .utf8) ?? "[]"
        let sql = """
        INSERT OR REPLACE INTO chapter_revisions (
            id, book_id, chapter_id, source_id, revision_number,
            ordered_bindings_json, total_frame_count, sample_rate, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try executePrepared(sql, [
            .text(revision.id.uuidString),
            .text(revision.bookID.uuidString),
            .text(revision.chapterID.uuidString),
            .text(revision.sourceID.uuidString),
            .int(Int64(revision.revisionNumber)),
            .text(bindingsJSON),
            .int(revision.totalFrameCount),
            .int(Int64(revision.sampleRate)),
            .real(revision.createdAt.timeIntervalSince1970),
        ])
    }

    private func upsertProductionRevisionRow(_ revision: AudiobookProductionRevision) throws {
        let mapJSON = try String(data: JSONEncoder().encode(revision.chapterRevisionIDsByChapter), encoding: .utf8) ?? "{}"
        let sql = """
        INSERT OR REPLACE INTO production_revisions (
            id, book_id, source_id, chapter_revisions_json, created_at
        ) VALUES (?, ?, ?, ?, ?);
        """
        try executePrepared(sql, [
            .text(revision.id.uuidString),
            .text(revision.bookID.uuidString),
            .text(revision.sourceID.uuidString),
            .text(mapJSON),
            .real(revision.createdAt.timeIntervalSince1970),
        ])
    }

    private func upsertBookmarkRow(_ bookmark: AudiobookBookmark) throws {
        let sql = """
        INSERT OR REPLACE INTO bookmarks (
            book_id, chapter_id, chapter_revision_id, fragment_id,
            anchor_lower_bound, anchor_upper_bound, fragment_offset_seconds, playback_rate, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try executePrepared(sql, [
            .text(bookmark.bookID.uuidString),
            .text(bookmark.chapterID.uuidString),
            .text(bookmark.chapterRevisionID.uuidString),
            .text(bookmark.fragmentID.uuidString),
            .int(bookmark.sourceAnchorRange.lowerBound),
            .int(bookmark.sourceAnchorRange.upperBound),
            .real(bookmark.fragmentOffsetSeconds),
            .real(Double(bookmark.playbackRate)),
            .real(bookmark.updatedAt.timeIntervalSince1970),
        ])
    }

    private func upsertExportRecordRow(_ record: AudiobookExportRecord) throws {
        let exportedJSON = try String(data: JSONEncoder().encode(record.exportedChapterIDs), encoding: .utf8) ?? "[]"
        let omittedJSON = try String(data: JSONEncoder().encode(record.omittedChapters), encoding: .utf8) ?? "[]"
        let sql = """
        INSERT OR REPLACE INTO export_records (
            id, book_id, production_revision_id, profile_raw_value,
            exported_chapter_ids_json, omitted_chapters_json, final_file_sha256,
            total_frame_count, duration_seconds, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try executePrepared(sql, [
            .text(record.id.uuidString),
            .text(record.bookID.uuidString),
            .text(record.productionRevisionID.uuidString),
            .text(record.profileRawValue),
            .text(exportedJSON),
            .text(omittedJSON),
            .text(record.finalFileSHA256),
            .int(record.totalFrameCount),
            .real(record.durationSeconds),
            .real(record.createdAt.timeIntervalSince1970),
        ])
    }

    private func upsertAssetTransactionRow(entry: AudiobookAssetJournalEntry) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let candidateJSON = try String(data: encoder.encode(entry.candidate), encoding: .utf8) ?? "{}"
        let sql = """
        INSERT OR REPLACE INTO asset_transactions (
            candidate_id, book_id, fragment_id, relative_asset_path, temp_asset_path,
            file_sha256, pcm_sha256, state, candidate_json, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try executePrepared(sql, [
            .text(entry.candidate.id.uuidString),
            .text(entry.candidate.bookID.uuidString),
            .text(entry.candidate.fragmentID.uuidString),
            .text(entry.candidate.relativeAssetPath),
            .text(entry.tempRelativePath),
            .text(entry.candidate.fileSHA256),
            .text(entry.candidate.pcmSHA256),
            .text(entry.state.rawValue),
            .text(candidateJSON),
            .real(entry.updatedAt.timeIntervalSince1970),
        ])
    }

    // MARK: - Private Fetch Helpers

    private func fetchAllBooksOrdered() throws -> [AudiobookBook] {
        let sql = """
        SELECT id, source_id, title, author, source_sha256, canonical_byte_count, scalar_count,
               original_encoding, analysis_state, production_state, listenable_state,
               confirmed_cast_revision_id, confirmed_audition_digest, current_production_revision_id,
               created_at, updated_at, analysis_failure_json
        FROM books
        ORDER BY updated_at DESC, id ASC;
        """
        return try withPrepared(sql) { stmt in
            var rows: [AudiobookBook] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let book = Self.decodeBookRow(stmt) {
                    rows.append(book)
                }
            }
            return rows
        }
    }

    private func fetchBook(id: UUID) throws -> AudiobookBook? {
        let sql = """
        SELECT id, source_id, title, author, source_sha256, canonical_byte_count, scalar_count,
               original_encoding, analysis_state, production_state, listenable_state,
               confirmed_cast_revision_id, confirmed_audition_digest, current_production_revision_id,
               created_at, updated_at, analysis_failure_json
        FROM books WHERE id = ?;
        """
        return try withPrepared(sql, [.text(id.uuidString)]) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Self.decodeBookRow(stmt)
        }
    }

    private static func decodeBookRow(_ stmt: OpaquePointer) -> AudiobookBook? {
        guard
            let idStr = columnText(stmt, 0), let id = UUID(uuidString: idStr),
            let sourceIDStr = columnText(stmt, 1), let sourceID = UUID(uuidString: sourceIDStr),
            let title = columnText(stmt, 2),
            let sha256 = columnText(stmt, 4),
            let encoding = columnText(stmt, 7),
            let analysisRaw = columnText(stmt, 8), let analysis = AudiobookAnalysisState(rawValue: analysisRaw),
            let prodRaw = columnText(stmt, 9), let prod = AudiobookProductionState(rawValue: prodRaw),
            let listenRaw = columnText(stmt, 10), let listen = AudiobookListenableState(rawValue: listenRaw)
        else {
            return nil
        }
        return AudiobookBook(
            id: id,
            sourceID: sourceID,
            title: title,
            author: columnText(stmt, 3),
            sourceSHA256: sha256,
            canonicalByteCount: columnInt(stmt, 5),
            scalarCount: Int(columnInt(stmt, 6)),
            originalEncoding: encoding,
            analysisState: analysis,
            productionState: prod,
            listenableState: listen,
            confirmedCastRevisionID: columnText(stmt, 11).flatMap(UUID.init(uuidString:)),
            confirmedAuditionVoiceSetDigest: columnText(stmt, 12),
            currentProductionRevisionID: columnText(stmt, 13).flatMap(UUID.init(uuidString:)),
            analysisFailure: columnText(stmt, 16).flatMap {
                try? JSONDecoder().decode(AudiobookAnalysisFailure.self, from: Data($0.utf8))
            },
            createdAt: Date(timeIntervalSince1970: columnDouble(stmt, 14)),
            updatedAt: Date(timeIntervalSince1970: columnDouble(stmt, 15))
        )
    }

    private func fetchChapters(bookID: UUID, sourceID: UUID? = nil, includeHistory: Bool = false) throws -> [AudiobookChapter] {
        let sql = """
        SELECT id, book_id, source_id, ordinal, title, lower_bound, upper_bound,
               excluded_ranges_json, is_skipped, current_chapter_revision_id, previous_chapter_revision_id
        FROM chapters WHERE book_id = ? \(includeHistory ? "" : "AND source_id = ?") ORDER BY ordinal ASC;
        """
        let selectedSourceID = try sourceID ?? fetchBook(id: bookID)?.sourceID
        let args: [SQLValue] = [.text(bookID.uuidString)] + (includeHistory ? [] : [.text(selectedSourceID?.uuidString)])
        return try withPrepared(sql, args) { stmt in
            var result: [AudiobookChapter] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard
                    let idStr = columnText(stmt, 0), let id = UUID(uuidString: idStr),
                    let bStr = columnText(stmt, 1), let bID = UUID(uuidString: bStr),
                    let sStr = columnText(stmt, 2), let sID = UUID(uuidString: sStr),
                    let title = columnText(stmt, 4)
                else { continue }
                let excludedJSON = columnText(stmt, 7) ?? "[]"
                let excluded = (try? JSONDecoder().decode([AudiobookSourceRange].self, from: Data(excludedJSON.utf8))) ?? []
                result.append(
                    AudiobookChapter(
                        id: id,
                        bookID: bID,
                        sourceID: sID,
                        ordinal: Int(columnInt(stmt, 3)),
                        title: title,
                        sourceRange: AudiobookSourceRange(lowerBound: columnInt(stmt, 5), upperBound: columnInt(stmt, 6)),
                        excludedRanges: excluded,
                        isSkipped: columnInt(stmt, 8) != 0,
                        currentChapterRevisionID: columnText(stmt, 9).flatMap(UUID.init(uuidString:)),
                        previousChapterRevisionID: columnText(stmt, 10).flatMap(UUID.init(uuidString:))
                    )
                )
            }
            return result
        }
    }

    private func fetchAtoms(bookID: UUID, chapterID: UUID?, includeHistory: Bool = false) throws -> [AudiobookTextAtom] {
        let sql: String
        let args: [SQLValue]
        if let chapterID {
            sql = """
            SELECT id, chapter_id, ordinal, lower_bound, upper_bound, kind
            FROM text_atoms WHERE book_id = ? AND chapter_id = ? ORDER BY ordinal ASC;
            """
            args = [.text(bookID.uuidString), .text(chapterID.uuidString)]
        } else {
            sql = """
            SELECT id, chapter_id, ordinal, lower_bound, upper_bound, kind
            FROM text_atoms WHERE book_id = ? \(includeHistory ? "" : "AND chapter_id IN (SELECT id FROM chapters WHERE chapters.book_id = text_atoms.book_id AND source_id = (SELECT source_id FROM books WHERE id = text_atoms.book_id))") ORDER BY lower_bound ASC, ordinal ASC;
            """
            args = [.text(bookID.uuidString)]
        }
        return try withPrepared(sql, args) { stmt in
            var result: [AudiobookTextAtom] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard
                    let idStr = columnText(stmt, 0), let id = UUID(uuidString: idStr),
                    let cStr = columnText(stmt, 1), let cID = UUID(uuidString: cStr),
                    let kindRaw = columnText(stmt, 5), let kind = AudiobookTextAtomKind(rawValue: kindRaw)
                else { continue }
                result.append(
                    AudiobookTextAtom(
                        id: id,
                        chapterID: cID,
                        ordinal: Int(columnInt(stmt, 2)),
                        sourceRange: AudiobookSourceRange(lowerBound: columnInt(stmt, 3), upperBound: columnInt(stmt, 4)),
                        kind: kind
                    )
                )
            }
            return result
        }
    }

    private func fetchCharacters(bookID: UUID, includeHistory: Bool = false) throws -> [AudiobookCharacter] {
        let sql = """
        SELECT id, book_id, display_name, aliases_json, is_narrator, is_major,
               allow_shared_minor_voice, evidences_json, first_lower_bound, first_upper_bound, chapter_ids_json, voice_policy_json, manual_tier, voice_traits_json, required_voice_traits_json
        FROM characters WHERE book_id = ? \(includeHistory ? "" : "AND source_id = (SELECT source_id FROM books WHERE id = characters.book_id)") ORDER BY is_narrator DESC, is_major DESC, display_name ASC;
        """
        let decoder = JSONDecoder()
        return try withPrepared(sql, [.text(bookID.uuidString)]) { stmt in
            var result: [AudiobookCharacter] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard
                    let idStr = columnText(stmt, 0), let id = UUID(uuidString: idStr),
                    let bStr = columnText(stmt, 1), let bID = UUID(uuidString: bStr),
                    let name = columnText(stmt, 2)
                else { continue }
                let aliases = (try? decoder.decode([String].self, from: Data((columnText(stmt, 3) ?? "[]").utf8))) ?? []
                let evidences = (try? decoder.decode([AudiobookCharacterEvidence].self, from: Data((columnText(stmt, 7) ?? "[]").utf8))) ?? []
                let chapterIDs = (try? decoder.decode([UUID].self, from: Data((columnText(stmt, 10) ?? "[]").utf8))) ?? []
                let firstRange: AudiobookSourceRange?
                if !columnIsNull(stmt, 8), !columnIsNull(stmt, 9) {
                    firstRange = AudiobookSourceRange(lowerBound: columnInt(stmt, 8), upperBound: columnInt(stmt, 9))
                } else {
                    firstRange = nil
                }
                result.append(
                    AudiobookCharacter(
                        id: id,
                        bookID: bID,
                        displayName: name,
                        aliases: aliases,
                        isNarrator: columnInt(stmt, 4) != 0,
                        isMajor: columnInt(stmt, 5) != 0,
                        allowSharedMinorVoice: columnInt(stmt, 6) != 0,
                        evidences: evidences,
                        firstAppearanceRange: firstRange,
                        chapterIDs: chapterIDs,
                        voicePolicy: try columnText(stmt, 11).map { try decoder.decode(AudiobookRoleVoicePolicy.self, from: Data($0.utf8)) },
                        manualTier: columnText(stmt, 12).flatMap(AudiobookRoleTier.init(rawValue:)),
                        voiceTraitsOverride: try columnText(stmt, 13).map { try decoder.decode(AudiobookVoiceTraits.self, from: Data($0.utf8)) },
                        requiredVoiceTraits: try columnText(stmt, 14).map { try decoder.decode(AudiobookVoiceTraits.self, from: Data($0.utf8)) }
                    )
                )
            }
            return result
        }
    }

    private func fetchVoiceBindings(bookID: UUID, includeHistory: Bool = false) throws -> [UUID: AudiobookVoiceBinding] {
        let sql = """
        SELECT role_id, voice_id, voice_revision, model_revision, is_synthesis_ready, allowed_speed, caller_seed
        FROM voice_bindings WHERE book_id = ? \(includeHistory ? "" : "AND role_id IN (SELECT id FROM characters WHERE characters.book_id = voice_bindings.book_id AND source_id = (SELECT source_id FROM books WHERE id = voice_bindings.book_id))");
        """
        return try withPrepared(sql, [.text(bookID.uuidString)]) { stmt in
            var map: [UUID: AudiobookVoiceBinding] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard
                    let rStr = columnText(stmt, 0), let rID = UUID(uuidString: rStr),
                    let voiceID = columnText(stmt, 1),
                    let modelRev = columnText(stmt, 3)
                else { continue }
                let seed: Int? = columnIsNull(stmt, 6) ? nil : Int(columnInt(stmt, 6))
                let binding = AudiobookVoiceBinding(
                    roleID: rID,
                    voiceID: voiceID,
                    voiceRevision: columnText(stmt, 2),
                    modelRevision: modelRev,
                    isSynthesisReady: columnInt(stmt, 4) != 0,
                    allowedSpeed: columnDouble(stmt, 5),
                    callerSeed: seed
                )
                map[rID] = binding
            }
            return map
        }
    }

    private func fetchAnalysisWindows(bookID: UUID, includeHistory: Bool = false) throws -> [AudiobookAnalysisWindow] {
        let sql = """
        SELECT id, root_window_id, book_id, chapter_id, ordinal,
               primary_atom_ids_json, leading_context_ids_json, trailing_context_ids_json,
               policy_fingerprint, configuration_digest, generation, is_completed
        FROM analysis_windows WHERE book_id = ? \(includeHistory ? "" : "AND chapter_id IN (SELECT id FROM chapters WHERE chapters.book_id = analysis_windows.book_id AND source_id = (SELECT source_id FROM books WHERE id = analysis_windows.book_id))") ORDER BY ordinal ASC;
        """
        let decoder = JSONDecoder()
        return try withPrepared(sql, [.text(bookID.uuidString)]) { stmt in
            var result: [AudiobookAnalysisWindow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard
                    let idStr = columnText(stmt, 0), let id = UUID(uuidString: idStr),
                    let rStr = columnText(stmt, 1), let rID = UUID(uuidString: rStr),
                    let bStr = columnText(stmt, 2), let bID = UUID(uuidString: bStr),
                    let cStr = columnText(stmt, 3), let cID = UUID(uuidString: cStr),
                    let pFingerprint = columnText(stmt, 8),
                    let cfgDigest = columnText(stmt, 9)
                else { continue }
                let primaryIDs = (try? decoder.decode([UUID].self, from: Data((columnText(stmt, 5) ?? "[]").utf8))) ?? []
                let leadingIDs = (try? decoder.decode([UUID].self, from: Data((columnText(stmt, 6) ?? "[]").utf8))) ?? []
                let trailingIDs = (try? decoder.decode([UUID].self, from: Data((columnText(stmt, 7) ?? "[]").utf8))) ?? []
                result.append(
                    AudiobookAnalysisWindow(
                        id: id,
                        rootWindowID: rID,
                        bookID: bID,
                        chapterID: cID,
                        ordinal: Int(columnInt(stmt, 4)),
                        primaryAtomIDs: primaryIDs,
                        leadingContextAtomIDs: leadingIDs,
                        trailingContextAtomIDs: trailingIDs,
                        policyFingerprint: pFingerprint,
                        configurationDigest: cfgDigest,
                        generation: Int(columnInt(stmt, 10)),
                        isCompleted: columnInt(stmt, 11) != 0
                    )
                )
            }
            return result
        }
    }

    private func fetchAnnotations(bookID: UUID, chapterID: UUID?, includeHistory: Bool = false) throws -> [AudiobookAnnotation] {
        let sql: String
        let args: [SQLValue]
        if let chapterID {
            sql = """
            SELECT id, book_id, chapter_id, window_id, atom_id, lower_bound, upper_bound,
                   assignment_json, evidence, user_confirmed, annotation_revision
            FROM annotations WHERE book_id = ? AND chapter_id = ? ORDER BY lower_bound ASC;
            """
            args = [.text(bookID.uuidString), .text(chapterID.uuidString)]
        } else {
            sql = """
            SELECT id, book_id, chapter_id, window_id, atom_id, lower_bound, upper_bound,
                   assignment_json, evidence, user_confirmed, annotation_revision
            FROM annotations WHERE book_id = ? \(includeHistory ? "" : "AND chapter_id IN (SELECT id FROM chapters WHERE chapters.book_id = annotations.book_id AND source_id = (SELECT source_id FROM books WHERE id = annotations.book_id))") ORDER BY lower_bound ASC;
            """
            args = [.text(bookID.uuidString)]
        }
        let decoder = JSONDecoder()
        return try withPrepared(sql, args) { stmt in
            var result: [AudiobookAnnotation] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard
                    let idStr = columnText(stmt, 0), let id = UUID(uuidString: idStr),
                    let bStr = columnText(stmt, 1), let bID = UUID(uuidString: bStr),
                    let cStr = columnText(stmt, 2), let cID = UUID(uuidString: cStr),
                    let wStr = columnText(stmt, 3), let wID = UUID(uuidString: wStr),
                    let aStr = columnText(stmt, 4), let aID = UUID(uuidString: aStr),
                    let assignJSON = columnText(stmt, 7),
                    let assignment = try? decoder.decode(AudiobookSpeakerAssignment.self, from: Data(assignJSON.utf8))
                else { continue }
                result.append(
                    AudiobookAnnotation(
                        id: id,
                        bookID: bID,
                        chapterID: cID,
                        windowID: wID,
                        atomID: aID,
                        sourceRange: AudiobookSourceRange(lowerBound: columnInt(stmt, 5), upperBound: columnInt(stmt, 6)),
                        assignment: assignment,
                        evidence: columnText(stmt, 8),
                        userConfirmed: columnInt(stmt, 9) != 0,
                        annotationRevision: Int(columnInt(stmt, 10))
                    )
                )
            }
            return result
        }
    }

    private func fetchFragments(bookID: UUID, chapterID: UUID?, includeHistory: Bool = false) throws -> [AudiobookFragment] {
        let sql: String
        let args: [SQLValue]
        if let chapterID {
            sql = """
            SELECT id, book_id, chapter_id, ordinal, role_id, lower_bound, upper_bound,
                   atom_ids_json, local_assignment_digest, voice_binding_digest, policy_digest, dependency_digest
            FROM fragments WHERE book_id = ? AND chapter_id = ? ORDER BY ordinal ASC;
            """
            args = [.text(bookID.uuidString), .text(chapterID.uuidString)]
        } else {
            sql = """
            SELECT id, book_id, chapter_id, ordinal, role_id, lower_bound, upper_bound,
                   atom_ids_json, local_assignment_digest, voice_binding_digest, policy_digest, dependency_digest
            FROM fragments WHERE book_id = ? \(includeHistory ? "" : "AND chapter_id IN (SELECT id FROM chapters WHERE chapters.book_id = fragments.book_id AND source_id = (SELECT source_id FROM books WHERE id = fragments.book_id))") ORDER BY lower_bound ASC, ordinal ASC;
            """
            args = [.text(bookID.uuidString)]
        }
        return try withPrepared(sql, args) { stmt in
            var result: [AudiobookFragment] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard
                    let idStr = columnText(stmt, 0), let id = UUID(uuidString: idStr),
                    let bStr = columnText(stmt, 1), let bID = UUID(uuidString: bStr),
                    let cStr = columnText(stmt, 2), let cID = UUID(uuidString: cStr),
                    let rStr = columnText(stmt, 4), let rID = UUID(uuidString: rStr),
                    let localDigest = columnText(stmt, 8),
                    let voiceDigest = columnText(stmt, 9),
                    let policyDigest = columnText(stmt, 10),
                    let depDigest = columnText(stmt, 11)
                else { continue }
                let atomIDs = (try? JSONDecoder().decode([UUID].self, from: Data((columnText(stmt, 7) ?? "[]").utf8))) ?? []
                result.append(
                    AudiobookFragment(
                        id: id,
                        bookID: bID,
                        chapterID: cID,
                        ordinal: Int(columnInt(stmt, 3)),
                        roleID: rID,
                        sourceRange: AudiobookSourceRange(lowerBound: columnInt(stmt, 5), upperBound: columnInt(stmt, 6)),
                        atomIDs: atomIDs,
                        localAssignmentDigest: localDigest,
                        voiceBindingDigest: voiceDigest,
                        policyDigest: policyDigest,
                        dependencyDigest: depDigest
                    )
                )
            }
            return result
        }
    }

    private func fetchCandidate(bookID: UUID, candidateID: UUID) throws -> AudiobookRenderCandidate? {
        let sql = """
        SELECT id, book_id, chapter_id, fragment_id, task_id, generation,
               relative_asset_path, file_sha256, pcm_sha256, frame_count, sample_rate,
               dependency_digest, request_id, receipt_digest, recipe_summary, is_receipt_verified, created_at
        FROM render_candidates WHERE book_id = ? AND id = ?;
        """
        return try withPrepared(sql, [.text(bookID.uuidString), .text(candidateID.uuidString)]) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Self.decodeCandidateRow(stmt)
        }
    }

    private func fetchCandidates(bookID: UUID, fragmentID: UUID?) throws -> [AudiobookRenderCandidate] {
        let sql: String
        let args: [SQLValue]
        if let fragmentID {
            sql = """
            SELECT id, book_id, chapter_id, fragment_id, task_id, generation,
                   relative_asset_path, file_sha256, pcm_sha256, frame_count, sample_rate,
                   dependency_digest, request_id, receipt_digest, recipe_summary, is_receipt_verified, created_at
            FROM render_candidates WHERE book_id = ? AND fragment_id = ? ORDER BY created_at DESC;
            """
            args = [.text(bookID.uuidString), .text(fragmentID.uuidString)]
        } else {
            sql = """
            SELECT id, book_id, chapter_id, fragment_id, task_id, generation,
                   relative_asset_path, file_sha256, pcm_sha256, frame_count, sample_rate,
                   dependency_digest, request_id, receipt_digest, recipe_summary, is_receipt_verified, created_at
            FROM render_candidates WHERE book_id = ? ORDER BY created_at DESC;
            """
            args = [.text(bookID.uuidString)]
        }
        return try withPrepared(sql, args) { stmt in
            var result: [AudiobookRenderCandidate] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let row = Self.decodeCandidateRow(stmt) {
                    result.append(row)
                }
            }
            return result
        }
    }

    private static func decodeCandidateRow(_ stmt: OpaquePointer) -> AudiobookRenderCandidate? {
        guard
            let idStr = columnText(stmt, 0), let id = UUID(uuidString: idStr),
            let bStr = columnText(stmt, 1), let bID = UUID(uuidString: bStr),
            let cStr = columnText(stmt, 2), let cID = UUID(uuidString: cStr),
            let fStr = columnText(stmt, 3), let fID = UUID(uuidString: fStr),
            let tStr = columnText(stmt, 4), let tID = UUID(uuidString: tStr),
            let relPath = columnText(stmt, 6),
            let fileSHA = columnText(stmt, 7),
            let pcmSHA = columnText(stmt, 8),
            let depDigest = columnText(stmt, 11)
        else { return nil }
        return AudiobookRenderCandidate(
            id: id,
            bookID: bID,
            chapterID: cID,
            fragmentID: fID,
            taskID: tID,
            generation: Int(columnInt(stmt, 5)),
            relativeAssetPath: relPath,
            fileSHA256: fileSHA,
            pcmSHA256: pcmSHA,
            frameCount: columnInt(stmt, 9),
            sampleRate: Int(columnInt(stmt, 10)),
            dependencyDigest: depDigest,
            requestID: columnText(stmt, 12),
            receiptDigest: columnText(stmt, 13),
            recipeSummary: columnText(stmt, 14),
            isReceiptVerified: columnInt(stmt, 15) != 0,
            createdAt: Date(timeIntervalSince1970: columnDouble(stmt, 16))
        )
    }

    private func fetchChapterRevisions(bookID: UUID, chapterID: UUID) throws -> [AudiobookChapterRevision] {
        let sql = """
        SELECT id, book_id, chapter_id, source_id, revision_number,
               ordered_bindings_json, total_frame_count, sample_rate, created_at
        FROM chapter_revisions WHERE book_id = ? AND chapter_id = ? ORDER BY revision_number DESC;
        """
        return try withPrepared(sql, [.text(bookID.uuidString), .text(chapterID.uuidString)]) { stmt in
            var result: [AudiobookChapterRevision] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard
                    let idStr = columnText(stmt, 0), let id = UUID(uuidString: idStr),
                    let bStr = columnText(stmt, 1), let bID = UUID(uuidString: bStr),
                    let cStr = columnText(stmt, 2), let cID = UUID(uuidString: cStr),
                    let sStr = columnText(stmt, 3), let sID = UUID(uuidString: sStr)
                else { continue }
                let bindings = (try? JSONDecoder().decode([AudiobookFragmentCandidateBinding].self, from: Data((columnText(stmt, 5) ?? "[]").utf8))) ?? []
                result.append(
                    AudiobookChapterRevision(
                        id: id,
                        bookID: bID,
                        chapterID: cID,
                        sourceID: sID,
                        revisionNumber: Int(columnInt(stmt, 4)),
                        orderedBindings: bindings,
                        totalFrameCount: columnInt(stmt, 6),
                        sampleRate: Int(columnInt(stmt, 7)),
                        createdAt: Date(timeIntervalSince1970: columnDouble(stmt, 8))
                    )
                )
            }
            return result
        }
    }

    private func fetchProductionRevisions(bookID: UUID) throws -> [AudiobookProductionRevision] {
        let sql = """
        SELECT id, book_id, source_id, chapter_revisions_json, created_at
        FROM production_revisions WHERE book_id = ? ORDER BY created_at DESC;
        """
        return try withPrepared(sql, [.text(bookID.uuidString)]) { stmt in
            var result: [AudiobookProductionRevision] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard
                    let idStr = columnText(stmt, 0), let id = UUID(uuidString: idStr),
                    let bStr = columnText(stmt, 1), let bID = UUID(uuidString: bStr),
                    let sStr = columnText(stmt, 2), let sID = UUID(uuidString: sStr)
                else { continue }
                let map = (try? JSONDecoder().decode([UUID: UUID].self, from: Data((columnText(stmt, 3) ?? "{}").utf8))) ?? [:]
                result.append(
                    AudiobookProductionRevision(
                        id: id,
                        bookID: bID,
                        sourceID: sID,
                        chapterRevisionIDsByChapter: map,
                        createdAt: Date(timeIntervalSince1970: columnDouble(stmt, 4))
                    )
                )
            }
            return result
        }
    }

    private func fetchBookmark(bookID: UUID) throws -> AudiobookBookmark? {
        let sql = """
        SELECT book_id, chapter_id, chapter_revision_id, fragment_id,
               anchor_lower_bound, anchor_upper_bound, fragment_offset_seconds, playback_rate, updated_at
        FROM bookmarks WHERE book_id = ?;
        """
        return try withPrepared(sql, [.text(bookID.uuidString)]) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            guard
                let bStr = columnText(stmt, 0), let bID = UUID(uuidString: bStr),
                let cStr = columnText(stmt, 1), let cID = UUID(uuidString: cStr),
                let rStr = columnText(stmt, 2), let rID = UUID(uuidString: rStr),
                let fStr = columnText(stmt, 3), let fID = UUID(uuidString: fStr)
            else { return nil }
            return AudiobookBookmark(
                bookID: bID,
                chapterID: cID,
                chapterRevisionID: rID,
                fragmentID: fID,
                sourceAnchorRange: AudiobookSourceRange(lowerBound: columnInt(stmt, 4), upperBound: columnInt(stmt, 5)),
                fragmentOffsetSeconds: columnDouble(stmt, 6),
                playbackRate: Float(columnDouble(stmt, 7)),
                updatedAt: Date(timeIntervalSince1970: columnDouble(stmt, 8))
            )
        }
    }

    private func fetchExportRecords(bookID: UUID) throws -> [AudiobookExportRecord] {
        let sql = """
        SELECT id, book_id, production_revision_id, profile_raw_value,
               exported_chapter_ids_json, omitted_chapters_json, final_file_sha256,
               total_frame_count, duration_seconds, created_at
        FROM export_records WHERE book_id = ? ORDER BY created_at DESC;
        """
        return try withPrepared(sql, [.text(bookID.uuidString)]) { stmt in
            var result: [AudiobookExportRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard
                    let idStr = columnText(stmt, 0), let id = UUID(uuidString: idStr),
                    let bStr = columnText(stmt, 1), let bID = UUID(uuidString: bStr),
                    let pStr = columnText(stmt, 2), let pID = UUID(uuidString: pStr),
                    let profileRaw = columnText(stmt, 3),
                    let fileSHA = columnText(stmt, 6)
                else { continue }
                let exported = (try? JSONDecoder().decode([UUID].self, from: Data((columnText(stmt, 4) ?? "[]").utf8))) ?? []
                let omitted = (try? JSONDecoder().decode([AudiobookOmittedChapterRecord].self, from: Data((columnText(stmt, 5) ?? "[]").utf8))) ?? []
                result.append(
                    AudiobookExportRecord(
                        id: id,
                        bookID: bID,
                        productionRevisionID: pID,
                        profileRawValue: profileRaw,
                        exportedChapterIDs: exported,
                        omittedChapters: omitted,
                        finalFileSHA256: fileSHA,
                        totalFrameCount: columnInt(stmt, 7),
                        durationSeconds: columnDouble(stmt, 8),
                        createdAt: Date(timeIntervalSince1970: columnDouble(stmt, 9))
                    )
                )
            }
            return result
        }
    }

    private func fetchPendingAssetTransactions(bookID: UUID) throws -> [AudiobookAssetJournalEntry] {
        let sql = """
        SELECT temp_asset_path, state, candidate_json, updated_at
        FROM asset_transactions WHERE book_id = ? AND state NOT IN ('completed', 'quarantined');
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try withPrepared(sql, [.text(bookID.uuidString)]) { stmt in
            var result: [AudiobookAssetJournalEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard
                    let tempPath = columnText(stmt, 0),
                    let stateRaw = columnText(stmt, 1),
                    let state = AudiobookAssetTransactionState(rawValue: stateRaw),
                    let candidateJSON = columnText(stmt, 2),
                    let candidate = try? decoder.decode(AudiobookRenderCandidate.self, from: Data(candidateJSON.utf8))
                else { continue }
                result.append(
                    AudiobookAssetJournalEntry(
                        candidate: candidate,
                        tempRelativePath: tempPath,
                        state: state,
                        updatedAt: Date(timeIntervalSince1970: columnDouble(stmt, 3))
                    )
                )
            }
            return result
        }
    }

    private func countRows(_ sql: String, _ args: [SQLValue]) throws -> Int {
        try withPrepared(sql, args) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    private func hasChapterStructureArtifacts(bookID: UUID) throws -> Bool {
        let chapters = try fetchChapters(bookID: bookID)
        let chapterIDs = Set(chapters.map(\.id))
        if chapters.contains(where: { $0.currentChapterRevisionID != nil || $0.previousChapterRevisionID != nil }) { return true }
        if assetJournal.pendingEntries(bookID: bookID).contains(where: { chapterIDs.contains($0.candidate.chapterID) }) { return true }
        let args: [SQLValue] = [.text(bookID.uuidString)]
        var checks: [String] = []
        for table in ["analysis_windows", "annotations", "fragments", "render_candidates", "chapter_revisions", "bookmarks"] {
            checks.append("SELECT COUNT(*) FROM \(table) WHERE book_id = ? AND chapter_id IN (SELECT id FROM chapters WHERE chapters.book_id = \(table).book_id AND source_id = (SELECT source_id FROM books WHERE id = \(table).book_id));")
        }
        checks.append("SELECT COUNT(*) FROM production_revisions WHERE book_id = ? AND source_id = (SELECT source_id FROM books WHERE id = production_revisions.book_id);")
        checks.append("SELECT COUNT(*) FROM export_records WHERE book_id = ? AND production_revision_id IN (SELECT id FROM production_revisions WHERE production_revisions.book_id = export_records.book_id AND source_id = (SELECT source_id FROM books WHERE id = export_records.book_id));")
        checks.append("SELECT COUNT(*) FROM asset_transactions WHERE book_id = ? AND state != 'quarantined' AND fragment_id IN (SELECT id FROM fragments WHERE fragments.book_id = asset_transactions.book_id AND chapter_id IN (SELECT id FROM chapters WHERE chapters.book_id = fragments.book_id AND source_id = (SELECT source_id FROM books WHERE id = fragments.book_id)));")
        for sql in checks where try countRows(sql, args) > 0 { return true }
        return false
    }

    private func buildSummary(for book: AudiobookBook) throws -> AudiobookBookSummary {
        let bArg: [SQLValue] = [.text(book.id.uuidString)]
        let totalChapterCount = try countRows("SELECT COUNT(*) FROM chapters WHERE book_id = ? AND source_id = (SELECT source_id FROM books WHERE id = chapters.book_id) AND is_skipped = 0;", bArg)
        let completedChapterCount = try countRows(
            "SELECT COUNT(*) FROM chapters WHERE book_id = ? AND source_id = (SELECT source_id FROM books WHERE id = chapters.book_id) AND is_skipped = 0 AND current_chapter_revision_id IS NOT NULL;",
            bArg
        )
        let unknownCount = try countRows(
            "SELECT COUNT(*) FROM annotations WHERE book_id = ? AND chapter_id IN (SELECT id FROM chapters WHERE chapters.book_id = annotations.book_id AND source_id = (SELECT source_id FROM books WHERE id = annotations.book_id)) AND assignment_json LIKE '%\"unknown\"%';",
            bArg
        )
        let characterCount = try countRows("SELECT COUNT(*) FROM characters WHERE book_id = ? AND source_id = (SELECT source_id FROM books WHERE id = characters.book_id);", bArg)
        let totalWindowCount = try countRows("SELECT COUNT(*) FROM analysis_windows WHERE book_id = ? AND chapter_id IN (SELECT id FROM chapters WHERE chapters.book_id = analysis_windows.book_id AND source_id = (SELECT source_id FROM books WHERE id = analysis_windows.book_id));", bArg)
        let completedWindowCount = try countRows(
            "SELECT COUNT(*) FROM analysis_windows WHERE book_id = ? AND chapter_id IN (SELECT id FROM chapters WHERE chapters.book_id = analysis_windows.book_id AND source_id = (SELECT source_id FROM books WHERE id = analysis_windows.book_id)) AND is_completed != 0;",
            bArg
        )
        let bookmark = try fetchBookmark(bookID: book.id)
        return AudiobookBookSummary(
            book: book,
            totalChapterCount: totalChapterCount,
            completedChapterCount: completedChapterCount,
            unknownSpeakerCount: unknownCount,
            characterCount: characterCount,
            completedWindowCount: completedWindowCount,
            totalWindowCount: totalWindowCount,
            bookmark: bookmark
        )
    }

    // MARK: - Trash Snapshot Export / Restore

    private struct CastingRevisionRowSnapshot: Codable, Sendable {
        let sequence: Int64
        let id: String
        let bookID: UUID
        let restoresRevisionID: String?
        let undoneBy: String?
        let recordJSON: String
        let createdAt: Double
    }

    private struct VoiceRegistrationIntentRowSnapshot: Codable, Sendable {
        let id: String
        let bookID: UUID
        let roleID: String?
        let voiceID: String
        let targetMetadataDigest: String
        let expectedCastRevisionID: String
        let expectedVoiceSetDigest: String
        let phase: String
        let intentJSON: String
        let updatedAt: Double
    }

    private struct AudiobookTrashSnapshot: Codable, Sendable {
        let sources: [SourceRecord]?
        let characterSources: [UUID: UUID]?
        let book: AudiobookBook
        let chapters: [AudiobookChapter]
        let atoms: [AudiobookTextAtom]
        let characters: [AudiobookCharacter]
        let bindings: [AudiobookVoiceBinding]
        let windows: [AudiobookAnalysisWindow]
        let annotations: [AudiobookAnnotation]
        let fragments: [AudiobookFragment]
        let candidates: [AudiobookRenderCandidate]
        let chapterRevisions: [AudiobookChapterRevision]
        let productionRevisions: [AudiobookProductionRevision]
        let bookmark: AudiobookBookmark?
        let exports: [AudiobookExportRecord]
        let productionCheckpoint: AudiobookProductionCheckpoint?
        let castingRevisions: [CastingRevisionRowSnapshot]?
        let voiceRegistrationIntents: [VoiceRegistrationIntentRowSnapshot]?
        let pronunciationBinding: AudiobookPronunciationBinding?
    }

    private func exportBookSnapshot(bookID: UUID) throws -> AudiobookTrashSnapshot {
        guard let book = try fetchBook(id: bookID) else {
            throw AudiobookStoreError.bookNotFound(bookID)
        }
        let chapters = try fetchChapters(bookID: bookID, includeHistory: true)
        var chapterRevs: [AudiobookChapterRevision] = []
        for ch in chapters {
            chapterRevs.append(contentsOf: try fetchChapterRevisions(bookID: bookID, chapterID: ch.id))
        }
        let roleSources: [UUID: UUID] = try withPrepared("SELECT id, source_id FROM characters WHERE book_id = ?;", [.text(bookID.uuidString)]) { stmt in
            var map: [UUID: UUID] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let role = columnText(stmt, 0).flatMap(UUID.init(uuidString:)), let source = columnText(stmt, 1).flatMap(UUID.init(uuidString:)) { map[role] = source }
            }
            return map
        }
        let castingRevs: [CastingRevisionRowSnapshot] = try withPrepared(
            "SELECT sequence, id, restores_revision_id, undone_by, record_json, created_at FROM casting_revisions WHERE book_id = ? ORDER BY sequence ASC;",
            [.text(bookID.uuidString)]
        ) { stmt in
            var rows: [CastingRevisionRowSnapshot] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let id = columnText(stmt, 1), let recordJSON = columnText(stmt, 4) else { continue }
                rows.append(
                    CastingRevisionRowSnapshot(
                        sequence: columnInt(stmt, 0),
                        id: id,
                        bookID: bookID,
                        restoresRevisionID: columnText(stmt, 2),
                        undoneBy: columnText(stmt, 3),
                        recordJSON: recordJSON,
                        createdAt: columnDouble(stmt, 5)
                    )
                )
            }
            return rows
        }
        let registrationIntents: [VoiceRegistrationIntentRowSnapshot] = try withPrepared(
            "SELECT id, role_id, voice_id, target_metadata_digest, expected_cast_revision_id, expected_voice_set_digest, phase, intent_json, updated_at FROM voice_registration_intents WHERE book_id = ? ORDER BY id ASC;",
            [.text(bookID.uuidString)]
        ) { stmt in
            var rows: [VoiceRegistrationIntentRowSnapshot] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let id = columnText(stmt, 0),
                      let voiceID = columnText(stmt, 2),
                      let targetDigest = columnText(stmt, 3),
                      let expectedCastRev = columnText(stmt, 4),
                      let expectedVoiceSet = columnText(stmt, 5),
                      let phase = columnText(stmt, 6),
                      let intentJSON = columnText(stmt, 7)
                else { continue }
                rows.append(
                    VoiceRegistrationIntentRowSnapshot(
                        id: id,
                        bookID: bookID,
                        roleID: columnText(stmt, 1),
                        voiceID: voiceID,
                        targetMetadataDigest: targetDigest,
                        expectedCastRevisionID: expectedCastRev,
                        expectedVoiceSetDigest: expectedVoiceSet,
                        phase: phase,
                        intentJSON: intentJSON,
                        updatedAt: columnDouble(stmt, 8)
                    )
                )
            }
            return rows
        }
        return AudiobookTrashSnapshot(
            sources: try sourceRecords(bookID: bookID), characterSources: roleSources,
            book: book,
            chapters: chapters,
            atoms: try fetchAtoms(bookID: bookID, chapterID: nil, includeHistory: true),
            characters: try fetchCharacters(bookID: bookID, includeHistory: true),
            bindings: Array(try fetchVoiceBindings(bookID: bookID, includeHistory: true).values),
            windows: try fetchAnalysisWindows(bookID: bookID, includeHistory: true),
            annotations: try fetchAnnotations(bookID: bookID, chapterID: nil, includeHistory: true),
            fragments: try fetchFragments(bookID: bookID, chapterID: nil, includeHistory: true),
            candidates: try fetchCandidates(bookID: bookID, fragmentID: nil),
            chapterRevisions: chapterRevs,
            productionRevisions: try fetchProductionRevisions(bookID: bookID),
            bookmark: try fetchBookmark(bookID: bookID),
            exports: try fetchExportRecords(bookID: bookID),
            productionCheckpoint: try productionCheckpoint(for: bookID),
            castingRevisions: castingRevs,
            voiceRegistrationIntents: registrationIntents,
            pronunciationBinding: try pronunciationBinding(for: bookID)
        )
    }

    private func restoreBookSnapshot(_ snapshot: AudiobookTrashSnapshot) throws {
        let bID = snapshot.book.id
        try upsertBookRow(snapshot.book)
        if let sources = snapshot.sources {
            for source in sources {
                try insertSourceRow(bookID: bID, sourceID: source.id, sha256: source.sha256, byteCount: source.byteCount,
                    scalarCount: source.scalarCount, encoding: source.encoding, originalRelPath: source.originalRel,
                    canonicalRelPath: source.canonicalRel, createdAt: source.createdAt)
                try executePrepared("""
                    UPDATE sources SET source_kind = ?, reference_source_id = ?, preparation_version = ?,
                        source_map_rel_path = ?, source_map_sha256 = ?, workflow_book_json = ? WHERE book_id = ? AND id = ?;
                    """, [.text(source.kind), .text(source.referenceSourceID?.uuidString), .text(source.preparationVersion),
                          .text(source.mapRel), .text(source.mapSHA256), .text(source.workflowJSON), .text(bID.uuidString), .text(source.id.uuidString)])
            }
        } else {
            // Old trash packages contain a single reference source.
            try insertSourceRow(bookID: bID, sourceID: snapshot.book.sourceID, sha256: snapshot.book.sourceSHA256,
                byteCount: snapshot.book.canonicalByteCount, scalarCount: snapshot.book.scalarCount,
                encoding: snapshot.book.originalEncoding,
                originalRelPath: "books/\(bID)/sources/\(snapshot.book.sourceID)-original.bin",
                canonicalRelPath: "books/\(bID)/sources/\(snapshot.book.sourceID)-source.utf8", createdAt: snapshot.book.createdAt)
        }
        for ch in snapshot.chapters { try upsertChapterRow(ch) }
        for atom in snapshot.atoms { try insertAtomRow(bookID: bID, atom: atom) }
        for char in snapshot.characters { try upsertCharacterRow(char, historicalSourceID: snapshot.characterSources?[char.id]) }
        for bind in snapshot.bindings { try upsertVoiceBindingRow(bookID: bID, binding: bind) }
        for win in snapshot.windows { try upsertAnalysisWindowRow(win, restoringHistory: true) }
        for ann in snapshot.annotations { try upsertAnnotationRow(ann, restoringHistory: true) }
        for frag in snapshot.fragments { try upsertFragmentRow(frag, restoringHistory: true) }
        for cand in snapshot.candidates { try upsertCandidateRow(cand) }
        for rev in snapshot.chapterRevisions { try upsertChapterRevisionRow(rev) }
        for prod in snapshot.productionRevisions { try upsertProductionRevisionRow(prod) }
        if let bm = snapshot.bookmark { try upsertBookmarkRow(bm) }
        for exp in snapshot.exports { try upsertExportRecordRow(exp) }
        if let checkpoint = snapshot.productionCheckpoint { try upsertProductionCheckpointRow(checkpoint) }
        if let castingRevisions = snapshot.castingRevisions {
            for rev in castingRevisions {
                try executePrepared(
                    """
                    INSERT OR REPLACE INTO casting_revisions (sequence, id, book_id, restores_revision_id, undone_by, record_json, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?);
                    """,
                    [
                        .int(rev.sequence),
                        .text(rev.id),
                        .text(bID.uuidString),
                        .text(rev.restoresRevisionID),
                        .text(rev.undoneBy),
                        .text(rev.recordJSON),
                        .real(rev.createdAt),
                    ]
                )
            }
        }
        if let intents = snapshot.voiceRegistrationIntents {
            for intent in intents {
                try executePrepared(
                    """
                    INSERT OR REPLACE INTO voice_registration_intents (id, book_id, role_id, voice_id, target_metadata_digest,
                        expected_cast_revision_id, expected_voice_set_digest, phase, intent_json, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """,
                    [
                        .text(intent.id),
                        .text(bID.uuidString),
                        .text(intent.roleID),
                        .text(intent.voiceID),
                        .text(intent.targetMetadataDigest),
                        .text(intent.expectedCastRevisionID),
                        .text(intent.expectedVoiceSetDigest),
                        .text(intent.phase),
                        .text(intent.intentJSON),
                        .real(intent.updatedAt),
                    ]
                )
            }
        }
        if let pronunciation = snapshot.pronunciationBinding {
            let entriesJSON = String(decoding: try JSONEncoder().encode(pronunciation.entries), as: UTF8.self)
            try executePrepared(
                """
                INSERT OR REPLACE INTO pronunciation_bindings (book_id, set_id, revision, entries_json, updated_at)
                VALUES (?, ?, ?, ?, ?);
                """,
                [
                    .text(bID.uuidString),
                    .text(pronunciation.setID),
                    .text(pronunciation.revision),
                    .text(entriesJSON),
                    .real(Date().timeIntervalSince1970),
                ]
            )
        }
    }
}
