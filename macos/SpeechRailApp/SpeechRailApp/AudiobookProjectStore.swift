import Foundation
import SQLite3
import SpeechRailControlKit

public enum AudiobookStoreError: Error, Equatable, Sendable, LocalizedError {
    case storageUnavailable(String)
    case unsupportedSchemaVersion(found: Int32, supported: Int32)
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
        case let .storageUnavailable(detail):
            "有声书作品库不可用：\(detail)"
        case let .unsupportedSchemaVersion(found, supported):
            "有声书数据库版本（v\(found)）高于当前应用支持的版本（v\(supported)），为保护您的数据已拒绝降级打开。"
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
    private var cachedSourceIndices: [UUID: (sha256: String, index: AudiobookSourceIndex)] = [:]
    private var cachedCharactersByBook: [UUID: [AudiobookCharacter]] = [:]
    private var cachedAnnotationsByBook: [UUID: [AudiobookAnnotation]] = [:]
    private var startupRunningBookUpdatedAt: [UUID: Double] = [:]
    private var didApplyStartupRecovery = false

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

        try Self.execSQL(pointer, AudiobookStoreSchema.createTablesSQL)
        if existingVersion == 0 {
            try Self.execSQL(pointer, "PRAGMA user_version = \(AudiobookStoreSchema.currentUserVersion);")
        }
        self.startupRunningBookUpdatedAt = try Self.queryStartupRunningBookUpdatedAt(pointer)
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
        try AudiobookChapterPlanner.validateChapterEdits(preview.chapters, source: preview.sourceIndex)

        let bookDir = try bookDirectory(for: preview.bookID, create: true)
        let sourcesDir = bookDir.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)

        let originalRel = "books/\(preview.bookID.uuidString)/sources/\(preview.sourceID.uuidString)-original.bin"
        let canonicalRel = "books/\(preview.bookID.uuidString)/sources/\(preview.sourceID.uuidString)-source.utf8"
        let originalURL = try resolveOwnedURL(relativePath: originalRel)
        let canonicalURL = try resolveOwnedURL(relativePath: canonicalRel)

        try preview.originalBytes.write(to: originalURL, options: .atomic)
        try preview.canonicalUTF8.write(to: canonicalURL, options: .atomic)

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
            try upsertBookRow(updated)
        }
        // A write through this instance is current work, even if the wall clock
        // happens to produce the same stored timestamp as the startup snapshot.
        startupRunningBookUpdatedAt.removeValue(forKey: book.id)
    }

    public func sourceIndex(for bookID: UUID) async throws -> AudiobookSourceIndex {
        guard let book = try fetchBook(id: bookID) else {
            throw AudiobookStoreError.bookNotFound(bookID)
        }
        if let cached = cachedSourceIndices[bookID], cached.sha256 == book.sourceSHA256 {
            return cached.index
        }
        let canonicalRel = "books/\(bookID.uuidString)/sources/\(book.sourceID.uuidString)-source.utf8"
        let url = try resolveOwnedURL(relativePath: canonicalRel)
        let data = try Data(contentsOf: url)
        let index = try AudiobookSourceIndex(utf8: data)
        guard index.sourceSHA256 == book.sourceSHA256 else {
            throw AudiobookStoreError.storageUnavailable("正文文件校验值与项目记录不一致。")
        }
        cachedSourceIndices[bookID] = (book.sourceSHA256, index)
        return index
    }

    public func chapters(for bookID: UUID) async throws -> [AudiobookChapter] {
        try fetchChapters(bookID: bookID)
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

            try executePrepared("DELETE FROM text_atoms WHERE book_id = ?;", [.text(bookID.uuidString)])
            try executePrepared("DELETE FROM chapters WHERE book_id = ?;", [.text(bookID.uuidString)])
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

    public func renameChapter(bookID: UUID, chapterID: UUID, title: String) async throws {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw AudiobookStoreError.statementFailed("章节名称不能为空。")
        }

        try inTransaction {
            guard try fetchBook(id: bookID) != nil else {
                throw AudiobookStoreError.bookNotFound(bookID)
            }
            guard try countRows(
                "SELECT COUNT(*) FROM chapters WHERE book_id = ? AND id = ?;",
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
        if let cached = cachedCharactersByBook[bookID] {
            return cached
        }
        let rows = try fetchCharacters(bookID: bookID)
        cachedCharactersByBook[bookID] = rows
        return rows
    }

    public func saveCharacters(bookID: UUID, characters: [AudiobookCharacter]) async throws {
        let retainedIDs = Set(characters.map(\.id))
        guard characters.allSatisfy({ $0.bookID == bookID }), retainedIDs.count == characters.count else {
            throw AudiobookStoreError.statementFailed("角色列表包含其他书籍的角色或重复角色。")
        }
        try inTransaction {
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
        }
        cachedCharactersByBook.removeValue(forKey: bookID)
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

    public func analysisWindows(for bookID: UUID) async throws -> [AudiobookAnalysisWindow] {
        try fetchAnalysisWindows(bookID: bookID)
    }

    public func saveAnalysisWindow(_ window: AudiobookAnalysisWindow) async throws {
        try inTransaction {
            try upsertAnalysisWindowRow(window)
        }
    }

    public func annotations(for bookID: UUID, chapterID: UUID? = nil) async throws -> [AudiobookAnnotation] {
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

    // MARK: - Transactional Asset Commit & Crash Recovery

    public func commitCandidate(_ candidate: AudiobookRenderCandidate, wav: Data) async throws {
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

        let books = try fetchAllBooksOrdered()
        for book in books {
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
        try encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)

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
        let snapshot = try decoder.decode(AudiobookTrashSnapshot.self, from: snapshotData)

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
              (try? Self.isSymbolicLink(at: url)) == false,
              let data = try? Data(contentsOf: url)
        else {
            return false
        }
        guard AudiobookDigest.sha256Hex(data) == expectedFileSHA else {
            return false
        }
        guard let pcmSHA = try? AudioDigest.sha256HexOfPCM(in: data),
              pcmSHA == expectedPCMSHA
        else {
            return false
        }
        return true
    }

    private func quarantineKnownFile(at url: URL, bookID: UUID) throws -> String {
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
            created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            author = excluded.author,
            analysis_state = excluded.analysis_state,
            production_state = excluded.production_state,
            listenable_state = excluded.listenable_state,
            confirmed_cast_revision_id = excluded.confirmed_cast_revision_id,
            confirmed_audition_digest = excluded.confirmed_audition_digest,
            current_production_revision_id = excluded.current_production_revision_id,
            updated_at = excluded.updated_at;
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
            excluded_ranges_json, current_chapter_revision_id, previous_chapter_revision_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(book_id, id) DO UPDATE SET
            ordinal = excluded.ordinal,
            title = excluded.title,
            lower_bound = excluded.lower_bound,
            upper_bound = excluded.upper_bound,
            excluded_ranges_json = excluded.excluded_ranges_json,
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

    private func upsertCharacterRow(_ character: AudiobookCharacter) throws {
        let aliasesJSON = try String(data: JSONEncoder().encode(character.aliases), encoding: .utf8) ?? "[]"
        let evidencesJSON = try String(data: JSONEncoder().encode(character.evidences), encoding: .utf8) ?? "[]"
        let chapterIDsJSON = try String(data: JSONEncoder().encode(character.chapterIDs), encoding: .utf8) ?? "[]"
        let sql = """
        INSERT INTO characters (
            id, book_id, display_name, aliases_json, is_narrator, is_major,
            allow_shared_minor_voice, evidences_json, first_lower_bound, first_upper_bound, chapter_ids_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(book_id, id) DO UPDATE SET
            display_name = excluded.display_name,
            aliases_json = excluded.aliases_json,
            is_narrator = excluded.is_narrator,
            is_major = excluded.is_major,
            allow_shared_minor_voice = excluded.allow_shared_minor_voice,
            evidences_json = excluded.evidences_json,
            first_lower_bound = excluded.first_lower_bound,
            first_upper_bound = excluded.first_upper_bound,
            chapter_ids_json = excluded.chapter_ids_json;
        """
        try executePrepared(sql, [
            .text(character.id.uuidString),
            .text(character.bookID.uuidString),
            .text(character.displayName),
            .text(aliasesJSON),
            .int(character.isNarrator ? 1 : 0),
            .int(character.isMajor ? 1 : 0),
            .int(character.allowSharedMinorVoice ? 1 : 0),
            .text(evidencesJSON),
            .int(character.firstAppearanceRange?.lowerBound),
            .int(character.firstAppearanceRange?.upperBound),
            .text(chapterIDsJSON),
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

    private func upsertAnalysisWindowRow(_ window: AudiobookAnalysisWindow) throws {
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

    private func upsertAnnotationRow(_ annotation: AudiobookAnnotation) throws {
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

    private func upsertFragmentRow(_ fragment: AudiobookFragment) throws {
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
               created_at, updated_at
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
               created_at, updated_at
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
            createdAt: Date(timeIntervalSince1970: columnDouble(stmt, 14)),
            updatedAt: Date(timeIntervalSince1970: columnDouble(stmt, 15))
        )
    }

    private func fetchChapters(bookID: UUID) throws -> [AudiobookChapter] {
        let sql = """
        SELECT id, book_id, source_id, ordinal, title, lower_bound, upper_bound,
               excluded_ranges_json, current_chapter_revision_id, previous_chapter_revision_id
        FROM chapters WHERE book_id = ? ORDER BY ordinal ASC;
        """
        return try withPrepared(sql, [.text(bookID.uuidString)]) { stmt in
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
                        currentChapterRevisionID: columnText(stmt, 8).flatMap(UUID.init(uuidString:)),
                        previousChapterRevisionID: columnText(stmt, 9).flatMap(UUID.init(uuidString:))
                    )
                )
            }
            return result
        }
    }

    private func fetchAtoms(bookID: UUID, chapterID: UUID?) throws -> [AudiobookTextAtom] {
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
            FROM text_atoms WHERE book_id = ? ORDER BY lower_bound ASC, ordinal ASC;
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

    private func fetchCharacters(bookID: UUID) throws -> [AudiobookCharacter] {
        let sql = """
        SELECT id, book_id, display_name, aliases_json, is_narrator, is_major,
               allow_shared_minor_voice, evidences_json, first_lower_bound, first_upper_bound, chapter_ids_json
        FROM characters WHERE book_id = ? ORDER BY is_narrator DESC, is_major DESC, display_name ASC;
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
                        chapterIDs: chapterIDs
                    )
                )
            }
            return result
        }
    }

    private func fetchVoiceBindings(bookID: UUID) throws -> [UUID: AudiobookVoiceBinding] {
        let sql = """
        SELECT role_id, voice_id, voice_revision, model_revision, is_synthesis_ready, allowed_speed, caller_seed
        FROM voice_bindings WHERE book_id = ?;
        """
        return try withPrepared(sql, [.text(bookID.uuidString)]) { stmt in
            var map: [UUID: AudiobookVoiceBinding] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard
                    let rStr = columnText(stmt, 0), let rID = UUID(uuidString: rStr),
                    let voiceID = columnText(stmt, 1),
                    let voiceRev = columnText(stmt, 2),
                    let modelRev = columnText(stmt, 3)
                else { continue }
                let seed: Int? = columnIsNull(stmt, 6) ? nil : Int(columnInt(stmt, 6))
                let binding = AudiobookVoiceBinding(
                    roleID: rID,
                    voiceID: voiceID,
                    voiceRevision: voiceRev,
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

    private func fetchAnalysisWindows(bookID: UUID) throws -> [AudiobookAnalysisWindow] {
        let sql = """
        SELECT id, root_window_id, book_id, chapter_id, ordinal,
               primary_atom_ids_json, leading_context_ids_json, trailing_context_ids_json,
               policy_fingerprint, configuration_digest, generation, is_completed
        FROM analysis_windows WHERE book_id = ? ORDER BY ordinal ASC;
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

    private func fetchAnnotations(bookID: UUID, chapterID: UUID?) throws -> [AudiobookAnnotation] {
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
            FROM annotations WHERE book_id = ? ORDER BY lower_bound ASC;
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

    private func fetchFragments(bookID: UUID, chapterID: UUID?) throws -> [AudiobookFragment] {
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
            FROM fragments WHERE book_id = ? ORDER BY lower_bound ASC, ordinal ASC;
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
        guard assetJournal.pendingEntries(bookID: bookID).isEmpty else { return true }

        let args: [SQLValue] = [.text(bookID.uuidString)]
        let checks = [
            "SELECT COUNT(*) FROM analysis_windows WHERE book_id = ?;",
            "SELECT COUNT(*) FROM annotations WHERE book_id = ?;",
            "SELECT COUNT(*) FROM fragments WHERE book_id = ?;",
            "SELECT COUNT(*) FROM render_candidates WHERE book_id = ?;",
            "SELECT COUNT(*) FROM chapter_revisions WHERE book_id = ?;",
            "SELECT COUNT(*) FROM production_revisions WHERE book_id = ?;",
            "SELECT COUNT(*) FROM bookmarks WHERE book_id = ?;",
            "SELECT COUNT(*) FROM export_records WHERE book_id = ?;",
            "SELECT COUNT(*) FROM chapters WHERE book_id = ? AND (current_chapter_revision_id IS NOT NULL OR previous_chapter_revision_id IS NOT NULL);",
            "SELECT COUNT(*) FROM asset_transactions WHERE book_id = ? AND state != 'quarantined';",
        ]
        for sql in checks {
            if try countRows(sql, args) > 0 {
                return true
            }
        }
        return false
    }

    private func buildSummary(for book: AudiobookBook) throws -> AudiobookBookSummary {
        let bArg: [SQLValue] = [.text(book.id.uuidString)]
        let totalChapterCount = try countRows("SELECT COUNT(*) FROM chapters WHERE book_id = ?;", bArg)
        let completedChapterCount = try countRows(
            "SELECT COUNT(*) FROM chapters WHERE book_id = ? AND current_chapter_revision_id IS NOT NULL;",
            bArg
        )
        let unknownCount = try countRows(
            "SELECT COUNT(*) FROM annotations WHERE book_id = ? AND assignment_json LIKE '%\"unknown\"%';",
            bArg
        )
        let characterCount = try countRows("SELECT COUNT(*) FROM characters WHERE book_id = ?;", bArg)
        let totalWindowCount = try countRows("SELECT COUNT(*) FROM analysis_windows WHERE book_id = ?;", bArg)
        let completedWindowCount = try countRows(
            "SELECT COUNT(*) FROM analysis_windows WHERE book_id = ? AND is_completed != 0;",
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

    private struct AudiobookTrashSnapshot: Codable, Sendable {
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
    }

    private func exportBookSnapshot(bookID: UUID) throws -> AudiobookTrashSnapshot {
        guard let book = try fetchBook(id: bookID) else {
            throw AudiobookStoreError.bookNotFound(bookID)
        }
        let chapters = try fetchChapters(bookID: bookID)
        var chapterRevs: [AudiobookChapterRevision] = []
        for ch in chapters {
            chapterRevs.append(contentsOf: try fetchChapterRevisions(bookID: bookID, chapterID: ch.id))
        }
        return AudiobookTrashSnapshot(
            book: book,
            chapters: chapters,
            atoms: try fetchAtoms(bookID: bookID, chapterID: nil),
            characters: try fetchCharacters(bookID: bookID),
            bindings: Array(try fetchVoiceBindings(bookID: bookID).values),
            windows: try fetchAnalysisWindows(bookID: bookID),
            annotations: try fetchAnnotations(bookID: bookID, chapterID: nil),
            fragments: try fetchFragments(bookID: bookID, chapterID: nil),
            candidates: try fetchCandidates(bookID: bookID, fragmentID: nil),
            chapterRevisions: chapterRevs,
            productionRevisions: try fetchProductionRevisions(bookID: bookID),
            bookmark: try fetchBookmark(bookID: bookID),
            exports: try fetchExportRecords(bookID: bookID)
        )
    }

    private func restoreBookSnapshot(_ snapshot: AudiobookTrashSnapshot) throws {
        let bID = snapshot.book.id
        try upsertBookRow(snapshot.book)
        let originalRel = "books/\(bID.uuidString)/sources/\(snapshot.book.sourceID.uuidString)-original.bin"
        let canonicalRel = "books/\(bID.uuidString)/sources/\(snapshot.book.sourceID.uuidString)-source.utf8"
        try insertSourceRow(
            bookID: bID,
            sourceID: snapshot.book.sourceID,
            sha256: snapshot.book.sourceSHA256,
            byteCount: snapshot.book.canonicalByteCount,
            scalarCount: snapshot.book.scalarCount,
            encoding: snapshot.book.originalEncoding,
            originalRelPath: originalRel,
            canonicalRelPath: canonicalRel,
            createdAt: snapshot.book.createdAt
        )
        for ch in snapshot.chapters { try upsertChapterRow(ch) }
        for atom in snapshot.atoms { try insertAtomRow(bookID: bID, atom: atom) }
        for char in snapshot.characters { try upsertCharacterRow(char) }
        for bind in snapshot.bindings { try upsertVoiceBindingRow(bookID: bID, binding: bind) }
        for win in snapshot.windows { try upsertAnalysisWindowRow(win) }
        for ann in snapshot.annotations { try upsertAnnotationRow(ann) }
        for frag in snapshot.fragments { try upsertFragmentRow(frag) }
        for cand in snapshot.candidates { try upsertCandidateRow(cand) }
        for rev in snapshot.chapterRevisions { try upsertChapterRevisionRow(rev) }
        for prod in snapshot.productionRevisions { try upsertProductionRevisionRow(prod) }
        if let bm = snapshot.bookmark { try upsertBookmarkRow(bm) }
        for exp in snapshot.exports { try upsertExportRecordRow(exp) }
    }
}
