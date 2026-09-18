import Foundation
import SQLite3

// 会话记录的持久化层。它是**一切会话持久化的唯一入口**（TECHNICAL-DESIGN §5.1）：
// 业务层不直接碰 SQLite，只允许用 §6.4 那张动作表里的方法。
//
// 三条结构上的规矩，改代码前先读：
//   1. 库文件住在**数据区**（`Application Support/SpeechRail/`），换服务版本、重装 App、
//      `service uninstall` 都不动它。记录是资产，不是缓存。
//   2. 单写者：整个 store 是一个 actor，写入天然串行；同时开 `WAL`，让「录制中写入」
//      与「页面里查询」不互相阻塞。
//   3. schema 只按 `user_version` 升级，没有迁移框架。v1 就是 §15.2 + R1 + R2 的合并结果
//      （这三份是加法关系，合并后没有历史包袱）。

public enum SessionStoreError: LocalizedError, Equatable {
    case storageUnavailable
    case openFailed(String)
    case statementFailed(String)
    case unsupportedSchemaVersion(Int32)

    public var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            "记录库位置不可用"
        case .openFailed(let detail):
            "记录库打不开：\(detail)"
        case .statementFailed(let detail):
            "记录库操作失败：\(detail)"
        case .unsupportedSchemaVersion(let version):
            "记录库版本 \(version) 比这个 App 支持的版本新，请先升级 App"
        }
    }
}

/// SQLite 句柄的持有者。用一个小盒子而不是 actor 的存储属性，是为了让关闭动作
/// 跟着对象生命周期走：actor 的 `deinit` 在 Swift 6 里是 nonisolated，直接访问非 Sendable
/// 的 `OpaquePointer` 存储属性会被拒。盒子只在 actor 内部被触碰，所以这里的
/// `@unchecked Sendable` 说的是「没有并发访问」，不是「可以并发访问」。
private final class SQLiteHandle: @unchecked Sendable {
    var pointer: OpaquePointer?

    deinit {
        if let pointer {
            sqlite3_close_v2(pointer)
        }
    }
}

public actor SessionStore {
    public static let fileName = "sessions.sqlite3"
    /// 当前 schema 版本。`session` 表建表时就是 §15.2 + R1 + R2 合并后的形状，所以起点是 1。
    public static let schemaVersion: Int32 = 1

    private let directory: URL
    private let fileManager: FileManager
    private let handle = SQLiteHandle()
    private var isOpen = false

    /// 记录库文件位置。设置页的「打开数据目录」与备份入口都用它。
    public nonisolated var libraryURL: URL {
        directory.appendingPathComponent(Self.fileName)
    }

    public nonisolated var dataDirectory: URL { directory }

    /// 默认落在 `~/Library/Application Support/SpeechRail/`，与 `Works/` 同层（§15.1）。
    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SpeechRail", isDirectory: true)
    }

    // MARK: - 生命周期

    public func open() throws {
        guard !isOpen else { return }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SessionStoreError.storageUnavailable
        }

        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let status = sqlite3_open_v2(libraryURL.path, &pointer, flags, nil)
        guard status == SQLITE_OK, let pointer else {
            let detail = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(status)"
            if let pointer { sqlite3_close_v2(pointer) }
            throw SessionStoreError.openFailed(detail)
        }
        handle.pointer = pointer
        isOpen = true

        do {
            // WAL 让录制中的写入不阻塞页面查询；`synchronous=NORMAL` 是 WAL 下的推荐档。
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA synchronous=NORMAL;")
            try execute("PRAGMA foreign_keys=ON;")
            try migrate()
        } catch {
            close()
            throw error
        }
    }

    public func close() {
        if let pointer = handle.pointer {
            sqlite3_close_v2(pointer)
            handle.pointer = nil
        }
        isOpen = false
    }

    private func migrate() throws {
        let version = try scalarInt("PRAGMA user_version;") ?? 0
        guard version <= Self.schemaVersion else {
            throw SessionStoreError.unsupportedSchemaVersion(Int32(version))
        }
        guard version < Self.schemaVersion else { return }

        // 整库只在一个事务里逐级升；v1 就是「从空库建到当前形状」。
        try execute("BEGIN IMMEDIATE;")
        do {
            try execute(Self.schemaV1)
            try execute("PRAGMA user_version=\(Self.schemaVersion);")
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    // MARK: - 写入（§6.4 动作表的上半张）

    /// 建会话行。**只在首个 PCM 已发送时调用**；`persona_*` 一次写入，之后不接受更新（§14.4）。
    @discardableResult
    public func createSession(_ draft: SessionDraft, id: String = UUID().uuidString) throws -> SessionRecord {
        let now = Date()
        let sql = """
        INSERT INTO session (
            id, kind, title, state, created_at, started_at, ended_at, engine_profile,
            audio_source, diarization, diarization_note, llm_endpoint, llm_model,
            persona_id, persona_title, voice_id, voice_name, end_reason
        ) VALUES (?, ?, ?, 'recording', ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL);
        """
        try withStatement(sql) { statement in
            bind(statement, 1, id)
            bind(statement, 2, draft.kind.rawValue)
            bind(statement, 3, draft.title)
            bind(statement, 4, now.timeIntervalSince1970)
            bind(statement, 5, draft.startedAt.timeIntervalSince1970)
            bind(statement, 6, draft.engineProfile)
            bind(statement, 7, draft.audioSource.rawValue)
            bind(statement, 8, draft.diarization.rawValue)
            bind(statement, 9, draft.diarizationNote)
            bind(statement, 10, draft.llmEndpoint)
            bind(statement, 11, draft.llmModel)
            bind(statement, 12, draft.persona?.id)
            bind(statement, 13, draft.persona?.title)
            bind(statement, 14, draft.voice?.id)
            bind(statement, 15, draft.voice?.name)
            try step(statement)
        }
        guard let record = try session(id: id) else {
            throw SessionStoreError.statementFailed("会话行写入后读不回来")
        }
        return record
    }

    /// 落一行正文，返回库分配的 `ordinal`。取号与插入是同一条语句（§15.7 R2 ①），
    /// 所以重复的 `completed` 撞唯一索引而不是产生第二行。
    @discardableResult
    public func appendLine(_ draft: LineDraft, id: String = UUID().uuidString) throws -> Int {
        let sql = """
        INSERT INTO line (
            id, session_id, ordinal, role, speaker_label, text, t_start, t_end,
            source, status, interrupted, device_switch, starred, timing_quality, created_at
        ) VALUES (
            ?, ?, (SELECT COALESCE(MAX(ordinal), 0) + 1 FROM line WHERE session_id = ?),
            ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?
        );
        """
        try withStatement(sql) { statement in
            bind(statement, 1, id)
            bind(statement, 2, draft.sessionID)
            bind(statement, 3, draft.sessionID)
            bind(statement, 4, draft.role.rawValue)
            bind(statement, 5, draft.speakerLabel)
            bind(statement, 6, draft.text)
            bind(statement, 7, draft.tStart)
            bind(statement, 8, draft.tEnd)
            bind(statement, 9, draft.source.rawValue)
            bind(statement, 10, draft.status.rawValue)
            bind(statement, 11, draft.isInterrupted ? 1 : 0)
            bind(statement, 12, draft.isDeviceSwitch ? 1 : 0)
            bind(statement, 13, draft.timingQuality?.rawValue)
            bind(statement, 14, Date().timeIntervalSince1970)
            try step(statement)
        }
        guard let ordinal = try scalarInt("SELECT ordinal FROM line WHERE id = ?;", args: [.text(id)]) else {
            throw SessionStoreError.statementFailed("行写入后读不回序号")
        }
        return ordinal
    }

    /// 分人链路只允许改归属列，**正文一个字不动**（§15.3 第 2 条）。
    public func attachSpeakerLabel(lineID: String, label: String?) throws {
        try withStatement("UPDATE line SET speaker_label = ? WHERE id = ?;") { statement in
            bind(statement, 1, label)
            bind(statement, 2, lineID)
            try step(statement)
        }
    }

    /// 改显示名只写 `speaker_name`；历史引用因此在新名字下显示新名，而引用原文不变。
    public func renameSpeaker(sessionID: String, label: String, name: String) throws {
        let sql = """
        INSERT INTO speaker_name (session_id, label, display_name, updated_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(session_id, label) DO UPDATE SET display_name = excluded.display_name,
                                                     updated_at = excluded.updated_at;
        """
        try withStatement(sql) { statement in
            bind(statement, 1, sessionID)
            bind(statement, 2, label)
            bind(statement, 3, name)
            bind(statement, 4, Date().timeIntervalSince1970)
            try step(statement)
        }
    }

    /// 「音色第 N 句起生效」是一条记录，不是被覆盖的字段（§15.3 第 3 条）。
    public func noteVoiceChange(
        sessionID: String,
        atOrdinal: Int,
        voice: VoiceSnapshot,
        id: String = UUID().uuidString
    ) throws {
        let sql = "INSERT INTO session_change (id, session_id, at_ordinal, kind, value, created_at) VALUES (?, ?, ?, 'voice', ?, ?);"
        try withStatement(sql) { statement in
            bind(statement, 1, id)
            bind(statement, 2, sessionID)
            bind(statement, 3, atOrdinal)
            // 存 `id|name` 而不是只存 id：音色改名或删除之后这一行仍然说得清当时是谁。
            bind(statement, 4, voice.name.map { "\(voice.id)|\($0)" } ?? voice.id)
            bind(statement, 5, Date().timeIntervalSince1970)
            try step(statement)
        }
    }

    @discardableResult
    public func markInterruption(
        sessionID: String,
        atOrdinal: Int,
        reason: SessionInterruptionReason,
        id: String = UUID().uuidString
    ) throws -> String {
        let sql = "INSERT INTO session_interruption (id, session_id, at_ordinal, reason, resumed_at, created_at) VALUES (?, ?, ?, ?, NULL, ?);"
        try withStatement(sql) { statement in
            bind(statement, 1, id)
            bind(statement, 2, sessionID)
            bind(statement, 3, atOrdinal)
            bind(statement, 4, reason.rawValue)
            bind(statement, 5, Date().timeIntervalSince1970)
            try step(statement)
        }
        return id
    }

    /// 续接：把最后一条未闭合的中断合上。续接是新 epoch，序号不重置（§6.5）。
    public func closeInterruption(sessionID: String, resumedAt: Date = Date()) throws {
        let sql = """
        UPDATE session_interruption SET resumed_at = ?
        WHERE session_id = ? AND resumed_at IS NULL;
        """
        try withStatement(sql) { statement in
            bind(statement, 1, resumedAt.timeIntervalSince1970)
            bind(statement, 2, sessionID)
            try step(statement)
        }
    }

    public func setSessionState(id: String, state: SessionRecordState) throws {
        try withStatement("UPDATE session SET state = ? WHERE id = ?;") { statement in
            bind(statement, 1, state.rawValue)
            bind(statement, 2, id)
            try step(statement)
        }
    }

    public func updateSessionTitle(id: String, title: String?) throws {
        try withStatement("UPDATE session SET title = ? WHERE id = ?;") { statement in
            bind(statement, 1, title)
            bind(statement, 2, id)
            try step(statement)
        }
    }

    public func setLineStarred(lineID: String, starred: Bool) throws {
        try withStatement("UPDATE line SET starred = ? WHERE id = ?;") { statement in
            bind(statement, 1, starred ? 1 : 0)
            bind(statement, 2, lineID)
            try step(statement)
        }
    }

    /// 封存：`archived` + `ended_at` + `end_reason`。空 reason 视为 `user`（§15.6 R1）。
    public func finalizeSession(id: String, endReason: SessionEndReason = .user, endedAt: Date = Date()) throws {
        let sql = "UPDATE session SET state = 'archived', ended_at = ?, end_reason = ? WHERE id = ?;"
        try withStatement(sql) { statement in
            bind(statement, 1, endedAt.timeIntervalSince1970)
            bind(statement, 2, endReason.rawValue)
            bind(statement, 3, id)
            try step(statement)
        }
    }

    /// 移除一条记录。靠 `ON DELETE CASCADE` 带走它的行、纪要、OS 问答、中断区间。
    /// **破坏性动作**，界面必须先确认（§16.6）。
    public func removeSession(id: String) throws {
        try withStatement("DELETE FROM session WHERE id = ?;") { statement in
            bind(statement, 1, id)
            try step(statement)
        }
    }

    // MARK: - 纪要队列（§5.8：单飞 + 租约回收 + 失败给可读原因）

    @discardableResult
    public func enqueueMinutes(
        sessionID: String,
        model: String?,
        promptChars: Int?,
        id: String = UUID().uuidString
    ) throws -> MinutesVersion {
        let version = try scalarInt(
            "SELECT COALESCE(MAX(version), 0) + 1 FROM minutes WHERE session_id = ?;",
            args: [.text(sessionID)]
        ) ?? 1
        let now = Date()
        try withStatement("UPDATE minutes SET is_latest = 0 WHERE session_id = ?;") { statement in
            bind(statement, 1, sessionID)
            try step(statement)
        }
        let sql = """
        INSERT INTO minutes (id, session_id, version, status, body, model, prompt_chars, is_latest, attempts, failure_reason, lease_until, created_at)
        VALUES (?, ?, ?, 'queued', NULL, ?, ?, 1, 0, NULL, NULL, ?);
        """
        try withStatement(sql) { statement in
            bind(statement, 1, id)
            bind(statement, 2, sessionID)
            bind(statement, 3, version)
            bind(statement, 4, model)
            bind(statement, 5, promptChars)
            bind(statement, 6, now.timeIntervalSince1970)
            try step(statement)
        }
        return MinutesVersion(
            id: id,
            sessionID: sessionID,
            version: version,
            status: .queued,
            model: model,
            promptChars: promptChars,
            isLatest: true,
            createdAt: now
        )
    }

    /// 认领一条排队中的纪要。租约过期的 `running` 行可以被下一次启动回收（否则会永远卡住）。
    public func claimMinutes(sessionID: String, lease: TimeInterval) throws -> MinutesVersion? {
        let now = Date()
        let sql = """
        SELECT id, session_id, version, status, body, model, prompt_chars, is_latest, attempts, failure_reason, lease_until, created_at
        FROM minutes
        WHERE session_id = ?
          AND (status = 'queued' OR (status = 'running' AND (lease_until IS NULL OR lease_until < ?)))
        ORDER BY version DESC LIMIT 1;
        """
        let candidate = try withStatement(sql) { statement -> MinutesVersion? in
            bind(statement, 1, sessionID)
            bind(statement, 2, now.timeIntervalSince1970)
            guard try step(statement) == SQLITE_ROW else { return nil }
            return minutesVersion(from: statement)
        }
        guard let candidate else { return nil }

        let update = """
        UPDATE minutes SET status = 'running', attempts = attempts + 1, lease_until = ?, failure_reason = NULL
        WHERE id = ?;
        """
        try withStatement(update) { statement in
            bind(statement, 1, now.addingTimeInterval(lease).timeIntervalSince1970)
            bind(statement, 2, candidate.id)
            try step(statement)
        }
        var claimed = candidate
        claimed.status = .running
        claimed.attempts += 1
        claimed.leaseUntil = now.addingTimeInterval(lease)
        return claimed
    }

    public func finishMinutes(minutesID: String, body: String, model: String?) throws {
        let sql = "UPDATE minutes SET status = 'ready', body = ?, model = COALESCE(?, model), lease_until = NULL, failure_reason = NULL WHERE id = ?;"
        try withStatement(sql) { statement in
            bind(statement, 1, body)
            bind(statement, 2, model)
            bind(statement, 3, minutesID)
            try step(statement)
        }
    }

    public func failMinutes(minutesID: String, reason: String) throws {
        let sql = "UPDATE minutes SET status = 'failed', lease_until = NULL, failure_reason = ? WHERE id = ?;"
        try withStatement(sql) { statement in
            bind(statement, 1, reason)
            bind(statement, 2, minutesID)
            try step(statement)
        }
    }

    // MARK: - 内心 OS 与长期记忆

    /// 存一次问答。默认 `in_minutes = 0`：「默认不进纪要」由结构决定（§15.3 第 1 条）。
    @discardableResult
    public func saveInnerOSExchange(_ exchange: InnerOSExchange, evidence: [InnerOSEvidence] = []) throws -> String {
        let sql = """
        INSERT INTO inner_os_exchange (
            id, session_id, asked_at, at_ordinal, question, intent, answer_text, draft_text,
            confidence, limits_note, model, status, in_minutes
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try withStatement(sql) { statement in
            bind(statement, 1, exchange.id)
            bind(statement, 2, exchange.sessionID)
            bind(statement, 3, exchange.askedAt.timeIntervalSince1970)
            bind(statement, 4, exchange.atOrdinal)
            bind(statement, 5, exchange.question)
            bind(statement, 6, exchange.intent?.rawValue)
            bind(statement, 7, exchange.answerText)
            bind(statement, 8, exchange.draftText)
            bind(statement, 9, exchange.confidence?.rawValue)
            bind(statement, 10, exchange.limitsNote)
            bind(statement, 11, exchange.model)
            bind(statement, 12, exchange.status.rawValue)
            bind(statement, 13, exchange.inMinutes ? 1 : 0)
            try step(statement)
        }
        for item in evidence {
            try insertEvidence(item, exchangeID: exchange.id)
        }
        return exchange.id
    }

    private func insertEvidence(_ item: InnerOSEvidence, exchangeID: String) throws {
        let sql = """
        INSERT INTO inner_os_evidence (id, exchange_id, line_id, speaker_label, t_start, quote, content_hash)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        try withStatement(sql) { statement in
            bind(statement, 1, item.id)
            bind(statement, 2, exchangeID)
            bind(statement, 3, item.lineID)
            bind(statement, 4, item.speakerLabel)
            bind(statement, 5, item.tStart)
            bind(statement, 6, item.quote)
            bind(statement, 7, item.contentHash)
            try step(statement)
        }
    }

    /// 「写进纪要」是显式动作（§14.2）。
    public func setInnerOSInMinutes(exchangeID: String, included: Bool) throws {
        try withStatement("UPDATE inner_os_exchange SET in_minutes = ? WHERE id = ?;") { statement in
            bind(statement, 1, included ? 1 : 0)
            bind(statement, 2, exchangeID)
            try step(statement)
        }
    }

    @discardableResult
    public func upsertMemory(
        kind: AssistantMemoryKind,
        body: String,
        sourceSessionID: String?,
        id: String = UUID().uuidString
    ) throws -> String {
        let now = Date().timeIntervalSince1970
        let sql = """
        INSERT INTO assistant_memory (id, kind, body, source_session_id, active, created_at, updated_at)
        VALUES (?, ?, ?, ?, 1, ?, ?)
        ON CONFLICT(id) DO UPDATE SET kind = excluded.kind,
                                      body = excluded.body,
                                      active = 1,
                                      updated_at = excluded.updated_at;
        """
        try withStatement(sql) { statement in
            bind(statement, 1, id)
            bind(statement, 2, kind.rawValue)
            bind(statement, 3, body)
            bind(statement, 4, sourceSessionID)
            bind(statement, 5, now)
            bind(statement, 6, now)
            try step(statement)
        }
        return id
    }

    public func setMemoryActive(id: String, active: Bool) throws {
        try withStatement("UPDATE assistant_memory SET active = ?, updated_at = ? WHERE id = ?;") { statement in
            bind(statement, 1, active ? 1 : 0)
            bind(statement, 2, Date().timeIntervalSince1970)
            bind(statement, 3, id)
            try step(statement)
        }
    }

    public func removeMemory(id: String) throws {
        try withStatement("DELETE FROM assistant_memory WHERE id = ?;") { statement in
            bind(statement, 1, id)
            try step(statement)
        }
    }

    // MARK: - 读

    public func session(id: String) throws -> SessionRecord? {
        let sql = "SELECT \(Self.sessionColumns) FROM session WHERE id = ?;"
        return try withStatement(sql) { statement in
            bind(statement, 1, id)
            guard try step(statement) == SQLITE_ROW else { return nil }
            return Self.sessionRecord(from: statement)
        }
    }

    public func listSessions(kind: SessionKind? = nil) throws -> [SessionSummary] {
        let sql = """
        SELECT \(Self.sessionColumns),
               (SELECT COUNT(*) FROM line l WHERE l.session_id = s.id AND l.status = 'final'),
               (SELECT COUNT(DISTINCT l.speaker_label) FROM line l WHERE l.session_id = s.id AND l.speaker_label IS NOT NULL),
               (SELECT i.reason FROM session_interruption i
                 WHERE i.session_id = s.id AND i.resumed_at IS NULL
                 ORDER BY i.at_ordinal DESC LIMIT 1),
               (SELECT m.status FROM minutes m WHERE m.session_id = s.id ORDER BY m.version DESC LIMIT 1)
        FROM session s
        \(kind == nil ? "" : "WHERE s.kind = ?")
        ORDER BY s.started_at DESC;
        """
        return try withStatement(sql) { statement in
            if let kind {
                bind(statement, 1, kind.rawValue)
            }
            var summaries: [SessionSummary] = []
            while try step(statement) == SQLITE_ROW {
                guard let record = Self.sessionRecord(from: statement) else { continue }
                summaries.append(
                    SessionSummary(
                        record: record,
                        lineCount: Int(columnInt(statement, 18)),
                        speakerCount: Int(columnInt(statement, 19)),
                        openInterruption: columnText(statement, 20).flatMap(SessionInterruptionReason.init(rawValue:)),
                        latestMinutesStatus: columnText(statement, 21).flatMap(MinutesStatus.init(rawValue:))
                    )
                )
            }
            return summaries
        }
    }

    /// `includePartial == false` 时只给已定稿的行——**记录库与导出只认这一档**。
    public func lines(sessionID: String, includePartial: Bool = false) throws -> [TranscriptLine] {
        let sql = """
        SELECT id, session_id, ordinal, role, speaker_label, text, t_start, t_end, source, status,
               interrupted, device_switch, starred, timing_quality, created_at
        FROM line WHERE session_id = ? \(includePartial ? "" : "AND status = 'final'")
        ORDER BY ordinal ASC;
        """
        return try withStatement(sql) { statement in
            bind(statement, 1, sessionID)
            var rows: [TranscriptLine] = []
            while try step(statement) == SQLITE_ROW {
                rows.append(Self.transcriptLine(from: statement))
            }
            return rows
        }
    }

    /// v1 检索用 `LIKE`（§6.5）。个人量级几万行仍是毫秒级；FTS5 留作实测变慢之后的一次迁移。
    public func searchLines(query: String, kind: SessionKind? = nil, limit: Int = 200) throws -> [TranscriptLine] {
        let pattern = "%" + query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
        let sql = """
        SELECT l.id, l.session_id, l.ordinal, l.role, l.speaker_label, l.text, l.t_start, l.t_end,
               l.source, l.status, l.interrupted, l.device_switch, l.starred, l.timing_quality, l.created_at
        FROM line l JOIN session s ON s.id = l.session_id
        WHERE l.status = 'final' AND l.text LIKE ? ESCAPE '\\'
        \(kind == nil ? "" : "AND s.kind = ?")
        ORDER BY s.started_at DESC, l.ordinal ASC
        LIMIT ?;
        """
        return try withStatement(sql) { statement in
            bind(statement, 1, pattern)
            var index: Int32 = 2
            if let kind {
                bind(statement, index, kind.rawValue)
                index += 1
            }
            bind(statement, index, limit)
            var rows: [TranscriptLine] = []
            while try step(statement) == SQLITE_ROW {
                rows.append(Self.transcriptLine(from: statement))
            }
            return rows
        }
    }

    /// 匿名标签 → 用户手写的名字。正文与时间码从不改写（§15.3 第 2 条）。
    public func speakerNames(sessionID: String) throws -> [String: String] {
        let sql = "SELECT label, display_name FROM speaker_name WHERE session_id = ?;"
        return try withStatement(sql) { statement in
            bind(statement, 1, sessionID)
            var names: [String: String] = [:]
            while try step(statement) == SQLITE_ROW {
                if let label = columnText(statement, 0), let name = columnText(statement, 1) {
                    names[label] = name
                }
            }
            return names
        }
    }

    public func voiceChanges(sessionID: String) throws -> [SessionChange] {
        let sql = "SELECT id, at_ordinal, kind, value, created_at FROM session_change WHERE session_id = ? ORDER BY at_ordinal ASC;"
        return try withStatement(sql) { statement in
            bind(statement, 1, sessionID)
            var rows: [SessionChange] = []
            while try step(statement) == SQLITE_ROW {
                rows.append(
                    SessionChange(
                        id: columnText(statement, 0) ?? "",
                        atOrdinal: Int(columnInt(statement, 1)),
                        kind: columnText(statement, 2) ?? "voice",
                        value: columnText(statement, 3) ?? "",
                        createdAt: Date(timeIntervalSince1970: columnDouble(statement, 4))
                    )
                )
            }
            return rows
        }
    }

    public func interruptions(sessionID: String) throws -> [SessionInterruption] {
        let sql = "SELECT id, session_id, at_ordinal, reason, resumed_at, created_at FROM session_interruption WHERE session_id = ? ORDER BY at_ordinal ASC;"
        return try withStatement(sql) { statement in
            bind(statement, 1, sessionID)
            var rows: [SessionInterruption] = []
            while try step(statement) == SQLITE_ROW {
                guard let reason = columnText(statement, 3).flatMap(SessionInterruptionReason.init(rawValue:)) else { continue }
                let resumed = columnIsNull(statement, 4) ? nil : Date(timeIntervalSince1970: columnDouble(statement, 4))
                rows.append(
                    SessionInterruption(
                        id: columnText(statement, 0) ?? "",
                        sessionID: columnText(statement, 1) ?? sessionID,
                        atOrdinal: Int(columnInt(statement, 2)),
                        reason: reason,
                        resumedAt: resumed,
                        createdAt: Date(timeIntervalSince1970: columnDouble(statement, 5))
                    )
                )
            }
            return rows
        }
    }

    public func minutesVersions(sessionID: String) throws -> [MinutesVersion] {
        let sql = """
        SELECT id, session_id, version, status, body, model, prompt_chars, is_latest, attempts, failure_reason, lease_until, created_at
        FROM minutes WHERE session_id = ? ORDER BY version DESC;
        """
        return try withStatement(sql) { statement in
            bind(statement, 1, sessionID)
            var rows: [MinutesVersion] = []
            while try step(statement) == SQLITE_ROW {
                rows.append(minutesVersion(from: statement))
            }
            return rows
        }
    }

    public func innerOSExchanges(sessionID: String) throws -> [InnerOSExchange] {
        let sql = """
        SELECT id, session_id, asked_at, at_ordinal, question, intent, answer_text, draft_text,
               confidence, limits_note, model, status, in_minutes
        FROM inner_os_exchange WHERE session_id = ? ORDER BY asked_at ASC;
        """
        return try withStatement(sql) { statement in
            bind(statement, 1, sessionID)
            var rows: [InnerOSExchange] = []
            while try step(statement) == SQLITE_ROW {
                rows.append(
                    InnerOSExchange(
                        id: columnText(statement, 0) ?? "",
                        sessionID: columnText(statement, 1) ?? sessionID,
                        askedAt: Date(timeIntervalSince1970: columnDouble(statement, 2)),
                        atOrdinal: columnIsNull(statement, 3) ? nil : Int(columnInt(statement, 3)),
                        question: columnText(statement, 4) ?? "",
                        intent: columnText(statement, 5).flatMap(InnerOSIntent.init(rawValue:)),
                        answerText: columnText(statement, 6),
                        draftText: columnText(statement, 7),
                        confidence: columnText(statement, 8).flatMap(InnerOSConfidence.init(rawValue:)),
                        limitsNote: columnText(statement, 9),
                        model: columnText(statement, 10),
                        status: columnText(statement, 11).flatMap(InnerOSStatus.init(rawValue:)) ?? .generating,
                        inMinutes: columnInt(statement, 12) != 0
                    )
                )
            }
            return rows
        }
    }

    public func memories(activeOnly: Bool = true) throws -> [AssistantMemory] {
        let sql = """
        SELECT id, kind, body, source_session_id, active, created_at, updated_at
        FROM assistant_memory \(activeOnly ? "WHERE active = 1" : "") ORDER BY updated_at DESC;
        """
        return try withStatement(sql) { statement in
            var rows: [AssistantMemory] = []
            while try step(statement) == SQLITE_ROW {
                guard let kind = columnText(statement, 1).flatMap(AssistantMemoryKind.init(rawValue:)) else { continue }
                rows.append(
                    AssistantMemory(
                        id: columnText(statement, 0) ?? "",
                        kind: kind,
                        body: columnText(statement, 2) ?? "",
                        sourceSessionID: columnText(statement, 3),
                        isActive: columnInt(statement, 4) != 0,
                        createdAt: Date(timeIntervalSince1970: columnDouble(statement, 5)),
                        updatedAt: Date(timeIntervalSince1970: columnDouble(statement, 6))
                    )
                )
            }
            return rows
        }
    }

    /// 在线一致快照（§15.1）。目标文件必须**不存在**——`VACUUM INTO` 不会覆盖。
    public func backup(to url: URL) throws {
        guard !fileManager.fileExists(atPath: url.path) else {
            throw SessionStoreError.statementFailed("目标文件已存在：先移走它再备份")
        }
        try withStatement("VACUUM INTO ?;") { statement in
            bind(statement, 1, url.path)
            try step(statement)
        }
    }

    // MARK: - 行 → 类型

    static let sessionColumns = """
    id, kind, title, state, created_at, started_at, ended_at, engine_profile, audio_source,
    diarization, diarization_note, llm_endpoint, llm_model, persona_id, persona_title,
    voice_id, voice_name, end_reason
    """

    private static func sessionRecord(from statement: OpaquePointer) -> SessionRecord? {
        guard
            let id = columnText(statement, 0),
            let kind = columnText(statement, 1).flatMap(SessionKind.init(rawValue:)),
            let state = columnText(statement, 3).flatMap(SessionRecordState.init(rawValue:)),
            let source = columnText(statement, 8).flatMap(SessionAudioSource.init(rawValue:))
        else { return nil }

        let persona = columnText(statement, 13).map { PersonaSnapshot(id: $0, title: columnText(statement, 14) ?? $0) }
        let voice = columnText(statement, 15).map { VoiceSnapshot(id: $0, name: columnText(statement, 16)) }

        return SessionRecord(
            id: id,
            kind: kind,
            title: columnText(statement, 2),
            state: state,
            createdAt: Date(timeIntervalSince1970: columnDouble(statement, 4)),
            startedAt: Date(timeIntervalSince1970: columnDouble(statement, 5)),
            endedAt: columnIsNull(statement, 6) ? nil : Date(timeIntervalSince1970: columnDouble(statement, 6)),
            engineProfile: columnText(statement, 7) ?? "",
            audioSource: source,
            diarization: columnText(statement, 9).flatMap(SessionDiarizationState.init(rawValue:)) ?? .off,
            diarizationNote: columnText(statement, 10),
            llmEndpoint: columnText(statement, 11),
            llmModel: columnText(statement, 12),
            persona: persona,
            voice: voice,
            endReason: columnText(statement, 17).flatMap(SessionEndReason.init(rawValue:))
        )
    }

    private static func transcriptLine(from statement: OpaquePointer) -> TranscriptLine {
        TranscriptLine(
            id: columnText(statement, 0) ?? "",
            sessionID: columnText(statement, 1) ?? "",
            ordinal: Int(columnInt(statement, 2)),
            role: columnText(statement, 3).flatMap(SessionLineRole.init(rawValue:)) ?? .speaker,
            speakerLabel: columnText(statement, 4),
            text: columnText(statement, 5) ?? "",
            tStart: columnIsNull(statement, 6) ? nil : columnDouble(statement, 6),
            tEnd: columnIsNull(statement, 7) ? nil : columnDouble(statement, 7),
            source: columnText(statement, 8).flatMap(SessionLineSource.init(rawValue:)) ?? .microphone,
            status: columnText(statement, 9).flatMap(SessionLineStatus.init(rawValue:)) ?? .final,
            isInterrupted: columnInt(statement, 10) != 0,
            isDeviceSwitch: columnInt(statement, 11) != 0,
            isStarred: columnInt(statement, 12) != 0,
            timingQuality: columnText(statement, 13).flatMap(SessionTimingQuality.init(rawValue:)),
            createdAt: Date(timeIntervalSince1970: columnDouble(statement, 14))
        )
    }

    private func minutesVersion(from statement: OpaquePointer) -> MinutesVersion {
        MinutesVersion(
            id: columnText(statement, 0) ?? "",
            sessionID: columnText(statement, 1) ?? "",
            version: Int(columnInt(statement, 2)),
            status: columnText(statement, 3).flatMap(MinutesStatus.init(rawValue:)) ?? .ready,
            body: columnText(statement, 4),
            model: columnText(statement, 5),
            promptChars: columnIsNull(statement, 6) ? nil : Int(columnInt(statement, 6)),
            isLatest: columnInt(statement, 7) != 0,
            attempts: Int(columnInt(statement, 8)),
            failureReason: columnText(statement, 9),
            leaseUntil: columnIsNull(statement, 10) ? nil : Date(timeIntervalSince1970: columnDouble(statement, 10)),
            createdAt: Date(timeIntervalSince1970: columnDouble(statement, 11))
        )
    }

    // MARK: - SQLite 薄封装

    private enum SQLArgument {
        case text(String)
        case int(Int)
        case real(Double)
    }

    private func requireHandle() throws -> OpaquePointer {
        guard let pointer = handle.pointer else {
            throw SessionStoreError.storageUnavailable
        }
        return pointer
    }

    private func execute(_ sql: String) throws {
        let pointer = try requireHandle()
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(pointer, sql, nil, nil, &error) == SQLITE_OK else {
            let detail = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(pointer))
            sqlite3_free(error)
            throw SessionStoreError.statementFailed(detail)
        }
    }

    @discardableResult
    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        let pointer = try requireHandle()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(pointer, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SessionStoreError.statementFailed(String(cString: sqlite3_errmsg(pointer)))
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    @discardableResult
    private func step(_ statement: OpaquePointer) throws -> Int32 {
        let status = sqlite3_step(statement)
        switch status {
        case SQLITE_ROW, SQLITE_DONE:
            return status
        default:
            let pointer = try requireHandle()
            throw SessionStoreError.statementFailed(String(cString: sqlite3_errmsg(pointer)))
        }
    }

    private func scalarInt(_ sql: String, args: [SQLArgument] = []) throws -> Int? {
        try withStatement(sql) { statement in
            for (offset, argument) in args.enumerated() {
                bindArgument(statement, Int32(offset + 1), argument)
            }
            guard try step(statement) == SQLITE_ROW else { return nil }
            return Int(columnInt(statement, 0))
        }
    }

    /// 名字不能叫 `bind`：那会遮蔽文件级的 `bind(_:_:_:)`，于是所有通过 `withStatement`
    /// 写值的调用点都会报「cannot convert value of type 'String' to 'SQLArgument'」。
    private func bindArgument(_ statement: OpaquePointer, _ index: Int32, _ argument: SQLArgument) {
        switch argument {
        case .text(let value): bind(statement, index, value)
        case .int(let value): bind(statement, index, value)
        case .real(let value): bind(statement, index, value)
        }
    }
}

// MARK: - 绑定与取值

private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
    if let value {
        // `SQLITE_TRANSIENT`：让 SQLite 复制字符串，而不是持有我们那个临时缓冲区的指针。
        // 写成内联表达式而不是文件级常量：函数类型的全局存储属性在严格并发下会要求 Sendable。
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    } else {
        sqlite3_bind_null(statement, index)
    }
}

private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Double?) {
    if let value {
        sqlite3_bind_double(statement, index, value)
    } else {
        sqlite3_bind_null(statement, index)
    }
}

private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Int?) {
    if let value {
        sqlite3_bind_int64(statement, index, Int64(value))
    } else {
        sqlite3_bind_null(statement, index)
    }
}

private func columnIsNull(_ statement: OpaquePointer, _ index: Int32) -> Bool {
    sqlite3_column_type(statement, index) == SQLITE_NULL
}

private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard !columnIsNull(statement, index), let pointer = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: pointer)
}

private func columnDouble(_ statement: OpaquePointer, _ index: Int32) -> Double {
    sqlite3_column_double(statement, index)
}

private func columnInt(_ statement: OpaquePointer, _ index: Int32) -> Int64 {
    sqlite3_column_int64(statement, index)
}

// MARK: - schema

extension SessionStore {
    /// v1 schema = `SESSIONS-SPEC` §15.2 的建表语句 + §15.6 R1 + §15.7 R2，
    /// 三份是加法关系，合并后没有历史包袱（R2 里那两条 `ALTER TABLE` 直接写进建表语句）。
    static let schemaV1 = """
    CREATE TABLE session (
      id               TEXT PRIMARY KEY,
      kind             TEXT NOT NULL,
      title            TEXT,
      state            TEXT NOT NULL,
      created_at       REAL NOT NULL,
      started_at       REAL NOT NULL,
      ended_at         REAL,
      engine_profile   TEXT NOT NULL,
      audio_source     TEXT NOT NULL,
      diarization      TEXT NOT NULL DEFAULT 'off',
      diarization_note TEXT,
      llm_endpoint     TEXT,
      llm_model        TEXT,
      persona_id       TEXT,
      persona_title    TEXT,
      voice_id         TEXT,
      voice_name       TEXT,
      end_reason       TEXT
    );
    CREATE INDEX session_by_started_at ON session(started_at DESC);
    CREATE INDEX session_by_kind ON session(kind, started_at DESC);

    CREATE TABLE line (
      id             TEXT PRIMARY KEY,
      session_id     TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
      ordinal        INTEGER NOT NULL,
      role           TEXT NOT NULL,
      speaker_label  TEXT,
      text           TEXT NOT NULL,
      t_start        REAL,
      t_end          REAL,
      source         TEXT NOT NULL,
      status         TEXT NOT NULL DEFAULT 'final',
      interrupted    INTEGER NOT NULL DEFAULT 0,
      device_switch  INTEGER NOT NULL DEFAULT 0,
      starred        INTEGER NOT NULL DEFAULT 0,
      timing_quality TEXT,
      created_at     REAL NOT NULL
    );
    CREATE UNIQUE INDEX line_by_session ON line(session_id, ordinal);

    CREATE TABLE session_change (
      id          TEXT PRIMARY KEY,
      session_id  TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
      at_ordinal  INTEGER NOT NULL,
      kind        TEXT NOT NULL,
      value       TEXT NOT NULL,
      created_at  REAL NOT NULL
    );
    CREATE INDEX session_change_by_session ON session_change(session_id, at_ordinal);

    CREATE TABLE speaker_name (
      session_id   TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
      label        TEXT NOT NULL,
      display_name TEXT NOT NULL,
      updated_at   REAL NOT NULL,
      PRIMARY KEY (session_id, label)
    );

    CREATE TABLE minutes (
      id             TEXT PRIMARY KEY,
      session_id     TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
      version        INTEGER NOT NULL,
      status         TEXT NOT NULL DEFAULT 'ready',
      body           TEXT,
      model          TEXT,
      prompt_chars   INTEGER,
      is_latest      INTEGER NOT NULL DEFAULT 0,
      attempts       INTEGER NOT NULL DEFAULT 0,
      failure_reason TEXT,
      lease_until    REAL,
      created_at     REAL NOT NULL,
      UNIQUE (session_id, version)
    );

    CREATE TABLE inner_os_exchange (
      id          TEXT PRIMARY KEY,
      session_id  TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
      asked_at    REAL NOT NULL,
      at_ordinal  INTEGER,
      question    TEXT NOT NULL,
      intent      TEXT,
      answer_text TEXT,
      draft_text  TEXT,
      confidence  TEXT,
      limits_note TEXT,
      model       TEXT,
      status      TEXT NOT NULL,
      in_minutes  INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX inner_os_by_session ON inner_os_exchange(session_id, asked_at);

    CREATE TABLE inner_os_evidence (
      id            TEXT PRIMARY KEY,
      exchange_id   TEXT NOT NULL REFERENCES inner_os_exchange(id) ON DELETE CASCADE,
      line_id       TEXT REFERENCES line(id) ON DELETE SET NULL,
      speaker_label TEXT,
      t_start       REAL,
      quote         TEXT,
      content_hash  TEXT
    );
    CREATE INDEX inner_os_evidence_by_exchange ON inner_os_evidence(exchange_id);

    CREATE TABLE assistant_memory (
      id                TEXT PRIMARY KEY,
      kind              TEXT NOT NULL,
      body              TEXT NOT NULL,
      source_session_id TEXT REFERENCES session(id) ON DELETE SET NULL,
      active            INTEGER NOT NULL DEFAULT 1,
      created_at        REAL NOT NULL,
      updated_at        REAL NOT NULL
    );
    CREATE INDEX assistant_memory_by_active ON assistant_memory(active, updated_at DESC);

    CREATE TABLE session_interruption (
      id         TEXT PRIMARY KEY,
      session_id TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
      at_ordinal INTEGER NOT NULL,
      reason     TEXT NOT NULL,
      resumed_at REAL,
      created_at REAL NOT NULL
    );
    CREATE INDEX session_interruption_by_session ON session_interruption(session_id, at_ordinal);

    CREATE INDEX line_by_text ON line(text);
    """
}
