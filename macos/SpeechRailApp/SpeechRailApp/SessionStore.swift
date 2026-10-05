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
    /// v2（MA-05）：新增会议知识文档、转录来源修订、来源快照三张表；
    /// `minutes` 追加 `is_legacy_import` 列（旧库原样迁入标记，不补造引用）。
    /// v1 库由 `migrateV1ToV2` 逐级升，失败整库回滚（MC-67/MC-69）。
    /// v3（MA-06）：`minutes` 追加 `is_accepted` 列（用户当前采用版，与最新尝试分离；
    /// 只有明确采用动作立指针，重试/重启/索引更新不得提升，MC-25/MC-31）。
    /// v1/v2 库逐级升到 v3，失败整库回滚（MC-67/MC-69）。
    /// v4（MA-07）：`minutes` 追加 `remote_response_id` / `config_snapshot` /
    /// `snapshot_id` / `cancel_requested_at`。任务身份落到行上：重启后能接着轮询**同一个**
    /// 远端响应（MC-28）、任务跑着时改设置不换端点（MC-32）、取消是一个有痕迹的状态而不是
    /// 一次内存里的 `Task.cancel()`（MC-30）。不写回既有行：老任务的 response id 本来就
    /// 没存过，补不出来也不补造。
    /// v5（MA-08）：`minutes` 追加 `candidate_json` / `review_json`。正文是渲染结果，
    /// 这两列存的是**数据**：结构化候选与证据核对报告。核对结论必须和它核对的那一版
    /// 存在一起，否则改了正文就没人知道当初核对过什么。
    /// v6（MA-08）：`minutes_item` / `minutes_evidence` 两张表。
    /// 结论与来源的对应关系从"候选 JSON 里的字符串"变成**可查的行**——
    /// 否则"这条结论依据哪几句"只能靠解析 JSON 回答，问不了、也删不掉。
    /// v7（MA-09）：`minutes` 追加 `coverage_json`，新增 `minutes_window`。
    /// 覆盖账本单独成表而不是塞进候选 JSON：局部重试要能只重跑失败的那一窗，
    /// 也要能回答"哪几句转录没被整理到"——这两个问题都要求按窗口查行。
    public static let schemaVersion: Int32 = 7

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

    /// 默认数据目录与库文件位置。设置页的「打开数据目录 / 备份库文件」需要一个
    /// **不依赖实例**的答案（那时 App 可能还没开过库）。
    ///
    /// 它必须与 `init` 里那条路径是同一条：两处各写一遍，迟早会指向两个地方。
    public static func defaultDataDirectory(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SpeechRail", isDirectory: true)
    }

    public static func defaultLibraryURL(fileManager: FileManager = .default) -> URL? {
        defaultDataDirectory(fileManager: fileManager)?.appendingPathComponent(fileName)
    }

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
        // v0 → v1：建全部 v1 表；v1 → v2：MA-05 知识文档三表 + legacy 标记列。
        // v2 → v3：MA-06 采用指针列（只加列，不改已存数据语义）。
        // 中途失败整库回滚，保留原库，不清空重建（MC-69）。
        try execute("BEGIN IMMEDIATE;")
        do {
            if version < 1 {
                try execute(Self.schemaV1)
            }
            if version < 2 {
                try migrateV1ToV2()
            }
            if version < 3 {
                try migrateV2ToV3()
            }
            if version < 4 {
                try migrateV3ToV4()
            }
            if version < 5 {
                try migrateV4ToV5()
            }
            if version < 6 {
                try migrateV5ToV6()
            }
            if version < 7 {
                try migrateV6ToV7()
            }
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
    /// 所以同一个会话里不可能出现两个相同的序号。
    ///
    /// **它不提供"同一个 `completed` 只落一次"的保证**：序号是现场取的 `MAX+1`，
    /// 同一个 item 到两次会老老实实落成两行。幂等在客户端（`CaptionSession.committedItemIDs`），
    /// 库这一层只保证序号单调且唯一。
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
            // 有观测时刻就用它；没有才退回"这一刻"（D09）。
            bind(statement, 14, (draft.createdAt ?? Date()).timeIntervalSince1970)
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

    /// 对齐证据在文本 final 之后独立到达，所以 `timing_quality` 只能补写。
    /// 它和 `attachSpeakerLabel` 同属"归属那一侧"：正文、时间码、序号都不参与。
    public func attachTimingQuality(lineID: String, quality: SessionTimingQuality?) throws {
        try withStatement("UPDATE line SET timing_quality = ? WHERE id = ?;") { statement in
            bind(statement, 1, quality?.rawValue)
            bind(statement, 2, lineID)
            try step(statement)
        }
    }

    /// 分人的状态与可读原因（§7.1 的三种状态 + 降级时那一刻写进记录）。
    ///
    /// 与 `attachSpeakerLabel` 一样是"只动归属那一侧"的写法：正文、时间码、序号都不参与。
    public func updateSessionDiarization(
        id: String,
        state: SessionDiarizationState,
        note: String? = nil
    ) throws {
        let sql = "UPDATE session SET diarization = ?, diarization_note = COALESCE(?, diarization_note) WHERE id = ?;"
        try withStatement(sql) { statement in
            bind(statement, 1, state.rawValue)
            bind(statement, 2, note)
            bind(statement, 3, id)
            try step(statement)
        }
    }

    /// 改显示名只写 `speaker_name`；历史引用因此在新名字下显示新名，而引用原文不变。
    ///
    /// MC-46 后半句（无迁移实现）：改名同时在 `session_change` 追加一条
    /// `kind = 'speaker'` 的记录，作为"来源修订"事件。旧纪要正文一个字不动；
    /// 读取方用"修订事件时间晚于纪要创建时间"判断旧版需复核，
    /// 引用仍指向旧 revision（`line` 原文不动）。`ON CONFLICT` 仍保证幂等，
    /// 修订事件只在显示名确有变化时追加，避免重复改名刷出多条事件。
    public func renameSpeaker(sessionID: String, label: String, name: String) throws {
        let now = Date().timeIntervalSince1970
        let previous = try withStatement(
            "SELECT display_name FROM speaker_name WHERE session_id = ? AND label = ? LIMIT 1;"
        ) { statement -> String? in
            bind(statement, 1, sessionID)
            bind(statement, 2, label)
            guard try step(statement) == SQLITE_ROW else { return nil }
            return columnText(statement, 0)
        }
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
            bind(statement, 4, now)
            try step(statement)
        }
        // 显示名确有变化才记修订事件：首次命名与重复同名不刷事件。
        guard previous != name else { return }
        // at_ordinal 用 0：改名是会话级映射修订，不指向某一句。
        // value 存 `label|name`：回看时仍说得清当时改的是谁。
        let eventSQL = "INSERT INTO session_change (id, session_id, at_ordinal, kind, value, created_at) VALUES (?, ?, 0, 'speaker', ?, ?);"
        try withStatement(eventSQL) { statement in
            bind(statement, 1, UUID().uuidString)
            bind(statement, 2, sessionID)
            bind(statement, 3, "\(label)|\(name)")
            bind(statement, 4, now)
            try step(statement)
        }
    }

    /// 来源修订事件（MC-46 后半句）：`session_change` 里 `kind = 'speaker'` 的记录。
    /// 纪要创建之后出现修订事件，旧版应标需复核；无事件或事件不晚于纪要时不标。
    public func speakerRevisions(sessionID: String) throws -> [SessionChange] {
        let sql = "SELECT id, at_ordinal, kind, value, created_at FROM session_change WHERE session_id = ? AND kind = 'speaker' ORDER BY created_at ASC;"
        return try withStatement(sql) { statement in
            bind(statement, 1, sessionID)
            var rows: [SessionChange] = []
            while try step(statement) == SQLITE_ROW {
                rows.append(
                    SessionChange(
                        id: columnText(statement, 0) ?? "",
                        atOrdinal: Int(columnInt(statement, 1)),
                        kind: columnText(statement, 2) ?? "speaker",
                        value: columnText(statement, 3) ?? "",
                        createdAt: Date(timeIntervalSince1970: columnDouble(statement, 4))
                    )
                )
            }
            return rows
        }
    }

    /// 旧纪要是否需复核（MC-46 后半句）：任一说话人修订事件晚于该纪要创建时间即需复核。
    /// 纯读判断，不写库；引用仍指旧 revision，只是提示结论可能已过期。
    public func minutesNeedsReview(minutesID: String) throws -> Bool {
        guard let version = try minutesVersion(id: minutesID) else { return false }
        let revisions = try speakerRevisions(sessionID: version.sessionID)
        return revisions.contains { $0.createdAt > version.createdAt }
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

    /// 仅由本记录的第一条正式 user 行认领自动标题。
    ///
    /// 条件更新在同一条 SQL 中核验行身份与当前标题：partial 不参与首次命名，
    /// 较晚保存的旧回调也不能抢在第一条正式输入之前命名；用户已手动取名后，
    /// 迟到的自动命名不会覆盖它。
    @discardableResult
    public func claimAutomaticTitle(
        sessionID: String,
        lineID: String,
        title: String
    ) throws -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }

        let sql = """
        UPDATE session
        SET title = ?
        WHERE id = ?
          AND (title IS NULL OR trim(title) = '')
          AND EXISTS (
              SELECT 1
              FROM line AS candidate
              WHERE candidate.id = ?
                AND candidate.session_id = session.id
                AND candidate.role = 'user'
                AND candidate.status = 'final'
                AND candidate.ordinal = (
                    SELECT MIN(first.ordinal)
                    FROM line AS first
                    WHERE first.session_id = session.id
                      AND first.role = 'user'
                      AND first.status = 'final'
                )
          );
        """
        try withStatement(sql) { statement in
            bind(statement, 1, title)
            bind(statement, 2, sessionID)
            bind(statement, 3, lineID)
            try step(statement)
        }
        return sqlite3_changes(handle.pointer) == 1
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

    /// 助手单轮回复的**幂等收尾**（D08 / 方案 S4 第 3 条）。
    ///
    /// 一轮回复在拿到第一段非空正文时就建好了行，之后只有这一个 `lineID`：
    /// 正常说完、用户打断、provider 失败都走这一个入口，不会插出第二行。
    /// 因此这里刻意只允许改**本任务自己的三列**：
    ///
    /// - `text`：截至此刻已经知道的全部正文（被打断时是已保存的那部分，不虚构余文）；
    /// - `status`：一律 `final`——`partial` 是"还在写"的内部状态，不该被回看当成定稿；
    /// - `interrupted`：**只能从 false 推向 true**。迟到的"正常完成"路径可以补全正文，
    ///   但不能把用户已经看到的打断标记擦掉。
    ///
    /// `starred` / `created_at` / `ordinal` / `source` / `t_start` 一律不碰：星标是用户写的，
    /// 建行时间就是这一句开始的时刻。
    ///
    /// 三重校验 `id + session_id + role='assistant'`：别的记录、用户行、根本没建过的行，
    /// 一律抛错而不是静默成功——0 行受影响不能被上层读成"已保存"。
    @discardableResult
    public func finalizeAssistantLine(
        sessionID: String,
        lineID: String,
        text: String,
        interrupted: Bool
    ) throws -> Int {
        let sql = """
        UPDATE line
        SET text = ?,
            status = 'final',
            interrupted = CASE WHEN interrupted = 1 THEN 1 ELSE ? END
        WHERE id = ? AND session_id = ? AND role = 'assistant';
        """
        try withStatement(sql) { statement in
            bind(statement, 1, text)
            bind(statement, 2, interrupted ? 1 : 0)
            bind(statement, 3, lineID)
            bind(statement, 4, sessionID)
            try step(statement)
            guard sqlite3_changes(handle.pointer) == 1 else {
                throw SessionStoreError.statementFailed("这一行不属于本记录")
            }
        }
        guard let ordinal = try scalarInt("SELECT ordinal FROM line WHERE id = ?;", args: [.text(lineID)]) else {
            throw SessionStoreError.statementFailed("行写入后读不回序号")
        }
        return ordinal
    }

    /// 上次没正常结束的那些会话：把 `recording` / `processing` 封存成 `archived`，
    /// `end_reason = 'unexpected_exit'`（§9 第 10 行、§5.6 的第四类中断）。
    ///
    /// 它在 App 启动时跑一次。**只封存，不删**：那一段音频确实没录完，但它已经写下的
    /// 正文是资产——下次启动要能回看、能导出。
    ///
    /// 返回值是**被改动的会话 id**（界面上那句「上次会议没有正常结束」用得到）。
    @discardableResult
    public func sealAbandonedSessions(now: Date = Date()) throws -> [String] {
        let select = """
        SELECT id FROM session WHERE state IN ('recording', 'processing') ORDER BY started_at;
        """
        let ids = try withStatement(select) { statement in
            var found: [String] = []
            while try step(statement) == SQLITE_ROW {
                if let id = columnText(statement, 0) { found.append(id) }
            }
            return found
        }
        guard !ids.isEmpty else { return [] }
        let update = "UPDATE session SET state = 'archived', ended_at = ?, end_reason = ? WHERE id = ?;"
        // 助手单轮回复是先建行、再在结束或打断时收尾的（D08）。进程在两者之间退出时，
        // 库里会留下一行 `partial` 的助手正文——那不是"没发生"，那是用户已经看到的半句话。
        // 所以封存会话的**同一个事务**里把这些助手行收成 final + interrupted：
        // 正文留着、能回看，同时明确标出它没说完。
        //
        // 条件写死 `role = 'assistant'`：用户行、会议/字幕的说话人 partial 各有各的封存规则，
        // 不归这条路管，也不该被顺手改掉。
        let sealAssistantPartials = """
        UPDATE line
        SET status = 'final', interrupted = 1
        WHERE session_id = ? AND role = 'assistant' AND status = 'partial';
        """
        try execute("BEGIN IMMEDIATE;")
        do {
            try withStatement(update) { statement in
                for id in ids {
                    sqlite3_reset(statement)
                    bind(statement, 1, now.timeIntervalSince1970)
                    bind(statement, 2, SessionEndReason.unexpectedExit.rawValue)
                    bind(statement, 3, id)
                    try step(statement)
                }
            }
            try withStatement(sealAssistantPartials) { statement in
                for id in ids {
                    sqlite3_reset(statement)
                    bind(statement, 1, id)
                    try step(statement)
                }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        return ids
    }

    /// 移除一条记录。靠 `ON DELETE CASCADE` 带走它的行、纪要、OS 问答、中断区间。
    /// **破坏性动作**，界面必须先确认（§16.6）。
    /// MA-05/MC-62：已关联会议知识文档的会话，普通删除入口拒绝级联销毁知识，
    /// 调用方必须走 `deleteMeetingKnowledge` 显式删除知识文档；
    /// `meeting_document.source_session_id` 是 `ON DELETE SET NULL`，
    /// 脱离关联也必须经过明确领域操作，不由运行时清理自动触发。
    public func removeSession(id: String) throws {
        let linked = try withStatement("SELECT id FROM meeting_document WHERE source_session_id = ? LIMIT 1;") { statement -> String? in
            bind(statement, 1, id)
            guard try step(statement) == SQLITE_ROW else { return nil }
            return columnText(statement, 0)
        }
        if linked != nil {
            throw SessionStoreError.statementFailed("该会话已有关联会议知识文档，请用知识域删除入口处理")
        }
        try withStatement("DELETE FROM session WHERE id = ?;") { statement in
            bind(statement, 1, id)
            try step(statement)
        }
    }

    // MARK: - 纪要队列（§5.8：单飞 + 租约回收 + 失败给可读原因）

    /// `minutes` 的完整读列清单。**所有**读这一行的查询都用它，
    /// 因为 `minutesVersion(from:)` 按列序号取值：清单和映射对不上，
    /// 读出来的就是别人的字段——所以这里只留一份，不要再各写各的。
    private static let minutesSelectColumns = """
    id, session_id, version, status, body, model, prompt_chars, is_latest, is_accepted, \
    attempts, failure_reason, lease_until, created_at, is_legacy_import, \
    remote_response_id, config_snapshot, snapshot_id, cancel_requested_at, \
    candidate_json, review_json, coverage_json
    """

    @discardableResult
    public func enqueueMinutes(
        sessionID: String,
        model: String?,
        promptChars: Int?,
        configSnapshot: String? = nil,
        snapshotID: String? = nil,
        id: String = UUID().uuidString
    ) throws -> MinutesVersion {
        // MA-06：清旧指针与插入新版本必须是同一事务；INSERT 失败时回滚，
        // 不能留下“旧版已被清掉指针”的半提交（MC-26）。
        let now = Date()
        let version: Int
        try execute("BEGIN IMMEDIATE;")
        do {
            version = try scalarInt(
                "SELECT COALESCE(MAX(version), 0) + 1 FROM minutes WHERE session_id = ?;",
                args: [.text(sessionID)]
            ) ?? 1
            try withStatement("UPDATE minutes SET is_latest = 0 WHERE session_id = ?;") { statement in
                bind(statement, 1, sessionID)
                try step(statement)
            }
            let sql = """
            INSERT INTO minutes (
                id, session_id, version, status, body, model, prompt_chars, is_latest, is_accepted,
                attempts, failure_reason, lease_until, created_at, config_snapshot, snapshot_id
            ) VALUES (?, ?, ?, 'queued', NULL, ?, ?, 1, 0, 0, NULL, NULL, ?, ?, ?);
            """
            try withStatement(sql) { statement in
                bind(statement, 1, id)
                bind(statement, 2, sessionID)
                bind(statement, 3, version)
                bind(statement, 4, model)
                bind(statement, 5, promptChars)
                bind(statement, 6, now.timeIntervalSince1970)
                // MA-07：配置与来源快照在**排队这一刻**就冻下来。任务跑着的时候改设置，
                // 当前任务不跟着换；新配置从下一次任务生效（MC-32）。
                bind(statement, 7, configSnapshot)
                bind(statement, 8, snapshotID)
                try step(statement)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        return MinutesVersion(
            id: id,
            sessionID: sessionID,
            version: version,
            status: .queued,
            model: model,
            promptChars: promptChars,
            isLatest: true,
            createdAt: now,
            configSnapshot: configSnapshot,
            snapshotID: snapshotID
        )
    }

    /// 认领一条排队中的纪要。租约过期的 `running` 行可以被下一次启动回收（否则会永远卡住）。
    /// MC-29：认领带 fencing 代际（`attempts`）：完成/失败必须凭认领时看到的代际提交，
    /// 旧执行者迟到不得改写新 owner 已认领的行。
    public func claimMinutes(sessionID: String, lease: TimeInterval) throws -> MinutesVersion? {
        let now = Date()
        let sql = """
        SELECT \(Self.minutesSelectColumns) FROM minutes
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
        let sql = "UPDATE minutes SET status = 'ready', body = ?, model = COALESCE(?, model), lease_until = NULL, failure_reason = NULL WHERE id = ? AND status = 'running';"
        try withStatement(sql) { statement in
            bind(statement, 1, body)
            bind(statement, 2, model)
            bind(statement, 3, minutesID)
            try step(statement)
        }
    }

    /// 带 fencing 代际的完成：只有 `expectedAttempts` 与当前行一致时才提交，
    /// 否则说明认领之后已有新 owner 接管，旧执行者迟到不得改写（MC-29）。
    /// 返回是否真正提交。
    @discardableResult
    public func finishMinutesIfOwner(minutesID: String, expectedAttempts: Int, body: String, model: String?) throws -> Bool {
        let sql = "UPDATE minutes SET status = 'ready', body = ?, model = COALESCE(?, model), lease_until = NULL, failure_reason = NULL WHERE id = ? AND status = 'running' AND attempts = ?;"
        var committed = false
        try withStatement(sql) { statement in
            bind(statement, 1, body)
            bind(statement, 2, model)
            bind(statement, 3, minutesID)
            bind(statement, 4, expectedAttempts)
            try step(statement)
            committed = sqlite3_changes(try requireHandle()) > 0
        }
        return committed
    }

    public func failMinutes(minutesID: String, reason: String) throws {
        let sql = "UPDATE minutes SET status = 'failed', lease_until = NULL, failure_reason = ? WHERE id = ? AND status = 'running';"
        try withStatement(sql) { statement in
            bind(statement, 1, reason)
            bind(statement, 2, minutesID)
            try step(statement)
        }
    }

    /// 带 fencing 代际的失败：语义同 `finishMinutesIfOwner`（MC-29）。
    @discardableResult
    public func failMinutesIfOwner(minutesID: String, expectedAttempts: Int, reason: String) throws -> Bool {
        let sql = "UPDATE minutes SET status = 'failed', lease_until = NULL, failure_reason = ? WHERE id = ? AND status = 'running' AND attempts = ?;"
        var committed = false
        try withStatement(sql) { statement in
            bind(statement, 1, reason)
            bind(statement, 2, minutesID)
            bind(statement, 3, expectedAttempts)
            try step(statement)
            committed = sqlite3_changes(try requireHandle()) > 0
        }
        return committed
    }

    /// 记下远端后台响应的 id（MA-07/MC-28）。
    ///
    /// **必须在收到 id 的那一刻就落库**，不是整理结束之后。App 在这中间退出，
    /// 重启后才有东西可查——查原请求，而不是把整场重新发一遍（可能重复计费，
    /// 也可能覆盖用户已经采用的版本）。
    /// 带 fencing 代际：行已被新 owner 接管时，迟到的写入不算数。
    @discardableResult
    public func recordMinutesRemoteResponse(
        minutesID: String,
        expectedAttempts: Int,
        responseID: String
    ) throws -> Bool {
        let sql = """
        UPDATE minutes SET remote_response_id = ?
        WHERE id = ? AND status = 'running' AND attempts = ?
          AND (remote_response_id IS NULL OR remote_response_id = ?);
        """
        var committed = false
        try withStatement(sql) { statement in
            bind(statement, 1, responseID)
            bind(statement, 2, minutesID)
            bind(statement, 3, expectedAttempts)
            bind(statement, 4, responseID)
            try step(statement)
            committed = sqlite3_changes(try requireHandle()) > 0
        }
        return committed
    }

    /// 心跳续租（MA-07）。一次整理可能跑十几分钟，租约只写一次的话，
    /// 后半程会被下一次启动当成"执行者已经不在了"回收掉。
    /// 同样带代际：旧执行者的心跳不能把新 owner 的租约往后推。
    @discardableResult
    public func renewMinutesLease(minutesID: String, expectedAttempts: Int, lease: TimeInterval) throws -> Bool {
        let sql = "UPDATE minutes SET lease_until = ? WHERE id = ? AND status = 'running' AND attempts = ?;"
        var committed = false
        try withStatement(sql) { statement in
            bind(statement, 1, Date().addingTimeInterval(lease).timeIntervalSince1970)
            bind(statement, 2, minutesID)
            bind(statement, 3, expectedAttempts)
            try step(statement)
            committed = sqlite3_changes(try requireHandle()) > 0
        }
        return committed
    }

    /// 用户按下「停止整理」：**先**把取消请求写进库里，再去停本地任务（MA-07/MC-30）。
    ///
    /// 顺序是有意的：写库之后崩溃，重启仍能看到"有人要求停这一条"，
    /// 而不是只停了个内存里的 Task、留下一条永远转圈的 `running`。
    /// 这一步**不代表远端已经停了**——远端确认是另一件事，由调用方另行表达。
    /// 返回是否写上：已经在终态的行返回 false，不覆盖既有结论。
    @discardableResult
    public func requestCancelMinutes(minutesID: String) throws -> Bool {
        let sql = """
        UPDATE minutes SET cancel_requested_at = ?
        WHERE id = ? AND cancel_requested_at IS NULL
          AND (status = 'queued' OR status = 'running');
        """
        var committed = false
        try withStatement(sql) { statement in
            bind(statement, 1, Date().timeIntervalSince1970)
            bind(statement, 2, minutesID)
            try step(statement)
            committed = sqlite3_changes(try requireHandle()) > 0
        }
        return committed
    }

    /// 取消已被本地确认：这一条**不是失败**（MC-30）。
    ///
    /// "没整理出来"和"用户不要了"给出的下一步不同，所以是两个状态而不是一条失败原因。
    /// 带代际：被新 owner 接管后，迟到的取消不得改写它的状态。
    @discardableResult
    public func cancelMinutesIfOwner(minutesID: String, expectedAttempts: Int) throws -> Bool {
        let sql = """
        UPDATE minutes SET status = 'cancelled', lease_until = NULL
        WHERE id = ? AND status = 'running' AND attempts = ?
          AND cancel_requested_at IS NOT NULL;
        """
        var committed = false
        try withStatement(sql) { statement in
            bind(statement, 1, minutesID)
            bind(statement, 2, expectedAttempts)
            try step(statement)
            committed = sqlite3_changes(try requireHandle()) > 0
        }
        return committed
    }

    /// 远端是否已经受理这次提交，本地无法查明（MA-07/MC-28 后半句、§8.5）。
    ///
    /// 请求可能已经被供应商收下并开始执行，只是 App 在拿到 response id 之前断了。
    /// 这时**不自动重发**：没有可验证的幂等能力时，重发可能重复执行、重复计费。
    /// 该状态不进 `pendingMinutesRows`，所以下一次启动不会把它当成待办自动跑一遍；
    /// 要不要重试由用户明确决定。
    @discardableResult
    public func markMinutesSubmissionUnknown(minutesID: String, expectedAttempts: Int) throws -> Bool {
        let sql = """
        UPDATE minutes SET status = 'submission_unknown', lease_until = NULL,
               failure_reason = '提交结果待确认'
        WHERE id = ? AND status = 'running' AND attempts = ?;
        """
        var committed = false
        try withStatement(sql) { statement in
            bind(statement, 1, minutesID)
            bind(statement, 2, expectedAttempts)
            try step(statement)
            committed = sqlite3_changes(try requireHandle()) > 0
        }
        return committed
    }

    /// 提交一版结构化候选（MA-08 / §7.6 的 `saveMinutesCandidate`）。
    ///
    /// 正文、候选、核对报告在**同一条 UPDATE** 里落库：三者必须同生共死。
    /// 分两次写就会出现"正文在、报告没了"——那正好是"看起来核对过"的假象。
    /// 同样带 fencing：行已被新 owner 接管时不写，旧的迟到结果不得发布。
    @discardableResult
    public func saveMinutesCandidate(
        minutesID: String,
        expectedAttempts: Int,
        body: String,
        model: String?,
        candidate: String?,
        review: String?,
        items: [MinutesItemDraft] = [],
        snapshotID: String? = nil,
        coverage: String? = nil,
        windows: [MinutesWindowRecord] = []
    ) throws -> Bool {
        let sql = """
        UPDATE minutes
        SET status = 'ready', body = ?, model = COALESCE(?, model), lease_until = NULL,
            failure_reason = NULL, candidate_json = ?, review_json = ?,
            coverage_json = COALESCE(?, coverage_json)
        WHERE id = ? AND status = 'running' AND attempts = ?;
        """
        var committed = false
        // 正文、条目、锚点三者同生共死：分几次写就会出现"正文在、锚点没了"的
        // 假引用——那比没有引用更坏，因为它看起来像有。
        try execute("BEGIN IMMEDIATE;")
        do {
            try withStatement(sql) { statement in
                bind(statement, 1, body)
                bind(statement, 2, model)
                bind(statement, 3, candidate)
                bind(statement, 4, review)
                bind(statement, 5, coverage)
                bind(statement, 6, minutesID)
                bind(statement, 7, expectedAttempts)
                try step(statement)
                committed = sqlite3_changes(try requireHandle()) > 0
            }
            guard committed else {
                // 已被新 owner 接管：这一版的条目也不写，迟到的结果不得发布。
                try execute("ROLLBACK;")
                return false
            }
            // 重跑同一版（幂等）：先清掉这一版上一次写下的条目，再按候选重建。
            try withStatement("DELETE FROM minutes_item WHERE minutes_id = ?;") { statement in
                bind(statement, 1, minutesID)
                try step(statement)
            }
            // 窗口进度与正文同生共死：写一半会让"局部重试"重跑已经成功的窗口，
            // 也会让覆盖账本说的和正文对不上（§6.3）。
            try replaceWindowsLocked(windows, minutesID: minutesID)
            for (order, draft) in items.enumerated() {
                let itemID = "mi-\(minutesID)-\(draft.localID)"
                try withStatement("""
                INSERT INTO minutes_item (id, minutes_id, local_id, kind, text, verdict, sort_order)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """) { statement in
                    bind(statement, 1, itemID)
                    bind(statement, 2, minutesID)
                    bind(statement, 3, draft.localID)
                    bind(statement, 4, draft.kind)
                    bind(statement, 5, draft.text)
                    bind(statement, 6, draft.verdict?.rawValue)
                    bind(statement, 7, order)
                    try step(statement)
                }
                for anchor in draft.anchors {
                    try withStatement("""
                    INSERT INTO minutes_evidence
                        (id, item_id, unit_id, line_id, revision_id, snapshot_id,
                         speaker_label, t_start, verification)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'exact_source_match');
                    """) { statement in
                        bind(statement, 1, "ev-\(itemID)-\(anchor.unitID)")
                        bind(statement, 2, itemID)
                        bind(statement, 3, anchor.unitID)
                        bind(statement, 4, anchor.lineID)
                        bind(statement, 5, anchor.revisionID)
                        bind(statement, 6, snapshotID)
                        bind(statement, 7, anchor.speakerLabel)
                        bind(statement, 8, anchor.startSeconds)
                        try step(statement)
                    }
                }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        return committed
    }

    // MARK: - 窗口进度（MA-09 / §6.3）

    /// 覆盖账本里每个窗口的当前状态（按窗口序号）。
    public func minutesWindows(minutesID: String) throws -> [MinutesWindowRecord] {
        try withStatement("""
        SELECT window_index, owned_unit_ids, context_unit_ids, outcome,
               failure_reason, candidate_json, remote_response_id, updated_at
        FROM minutes_window WHERE minutes_id = ? ORDER BY window_index ASC;
        """) { statement in
            bind(statement, 1, minutesID)
            var rows: [MinutesWindowRecord] = []
            while try step(statement) == SQLITE_ROW {
                rows.append(MinutesWindowRecord(
                    index: Int(columnInt(statement, 0)),
                    ownedUnitIDs: Self.stringArray(columnText(statement, 1)),
                    contextUnitIDs: Self.stringArray(columnText(statement, 2)),
                    outcome: columnText(statement, 3)
                        .flatMap(MinutesWindowOutcome.init(rawValue:)) ?? .failed,
                    failureReason: columnText(statement, 4),
                    candidateJSON: columnText(statement, 5),
                    remoteResponseID: columnText(statement, 6),
                    updatedAt: Date(timeIntervalSince1970: columnDouble(statement, 7))
                ))
            }
            return rows
        }
    }

    /// 需要重试的窗口（失败或被截断的）。
    ///
    /// 局部重试只认这一份清单：成功窗口带着已拿到的候选，
    /// 重跑它们等于重复计费，也可能把用户已经核对过的结果换掉（MC-40）。
    public func retryableMinutesWindows(minutesID: String) throws -> [MinutesWindowRecord] {
        try minutesWindows(minutesID: minutesID)
            .filter { $0.outcome != .processed }
            .sorted { $0.index < $1.index }
    }

    /// 记一个窗口的进度（MA-09 / §7.6：窗口进度要能落库）。
    ///
    /// 整场整理要跑很久，中途崩掉时下一次启动要从**已完成的窗口**继续，
    /// 而不是把整场重新发一遍。所以每跑完一窗就写一行，带远端响应 id：
    /// 重启后能查原请求（MC-28），也能只重跑没拿到结果的那几窗。
    ///
    /// 凭父行的 `status = running` + `attempts` 提交：行已被新 owner 接管时
    /// 返回 false，迟到的窗口结果不写。
    @discardableResult
    public func recordMinutesWindow(
        minutesID: String,
        expectedAttempts: Int,
        record: MinutesWindowRecord
    ) throws -> Bool {
        let owned = try withStatement("""
        SELECT 1 FROM minutes WHERE id = ? AND status = 'running' AND attempts = ?;
        """) { statement -> Bool in
            bind(statement, 1, minutesID)
            bind(statement, 2, expectedAttempts)
            return try step(statement) == SQLITE_ROW
        }
        guard owned else { return false }
        try execute("BEGIN IMMEDIATE;")
        do {
            try withStatement("""
            DELETE FROM minutes_window WHERE minutes_id = ? AND window_index = ?;
            """) { statement in
                bind(statement, 1, minutesID)
                bind(statement, 2, record.index)
                try step(statement)
            }
            try insertWindow(record, minutesID: minutesID)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        return true
    }

    /// 把已落终态的一版重新开成 `running`，只重跑失败窗口（MC-40 局部重试）。
    ///
    /// 带 fencing：凭 `expectedAttempts` 提交，旧执行者迟到改不动。
    /// **已采用的版本拒绝重开**——用户核对过的东西不能被一次重试换掉。
    public func reopenMinutesForWindowRetry(
        minutesID: String,
        expectedAttempts: Int,
        lease: TimeInterval
    ) throws -> Bool {
        var reopened = false
        try execute("BEGIN IMMEDIATE;")
        do {
            try withStatement("""
            UPDATE minutes
            SET status = 'running', attempts = attempts + 1, lease_until = ?,
                failure_reason = NULL
            WHERE id = ? AND status IN ('ready', 'failed') AND attempts = ?
              AND is_accepted = 0;
            """) { statement in
                bind(statement, 1, Date().addingTimeInterval(lease).timeIntervalSince1970)
                bind(statement, 2, minutesID)
                bind(statement, 3, expectedAttempts)
                try step(statement)
                reopened = sqlite3_changes(try requireHandle()) > 0
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        return reopened
    }

    /// 在已提交的事务里重写这一版的窗口行（幂等：先删后插）。
    private func replaceWindowsLocked(
        _ windows: [MinutesWindowRecord],
        minutesID: String
    ) throws {
        try withStatement("DELETE FROM minutes_window WHERE minutes_id = ?;") { statement in
            bind(statement, 1, minutesID)
            try step(statement)
        }
        for window in windows {
            try insertWindow(window, minutesID: minutesID)
        }
    }

    private func insertWindow(
        _ window: MinutesWindowRecord,
        minutesID: String
    ) throws {
        try withStatement("""
        INSERT INTO minutes_window (
            id, minutes_id, window_index, owned_unit_ids, context_unit_ids,
            outcome, failure_reason, candidate_json, remote_response_id, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """) { statement in
            bind(statement, 1, window.id)
            bind(statement, 2, minutesID)
            bind(statement, 3, window.index)
            bind(
                statement,
                4,
                Self.jsonStringArray(window.ownedUnitIDs)
            )
            bind(
                statement,
                5,
                Self.jsonStringArray(window.contextUnitIDs)
            )
            bind(statement, 6, window.outcome.rawValue)
            bind(statement, 7, window.failureReason)
            bind(statement, 8, window.candidateJSON)
            bind(statement, 9, window.remoteResponseID)
            bind(statement, 10, window.updatedAt.timeIntervalSince1970)
            try step(statement)
        }
    }

    private static func jsonStringArray(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values),
              let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
    }

    private static func stringArray(_ raw: String?) -> [String] {
        guard let raw, let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// 这一版的结论条目与其证据锚点（按落库顺序）。
    ///
    /// 锚点的原文从 `transcript_revision` 读，**不从 `line` 读**：
    /// 用户后来改了转录，旧纪要仍然显示它当时依据的那一版（MC-46）。
    /// 修订被删时 `quote` 为 nil——明确是"来源已不可读"，不拿当前行顶替。
    public func minutesItems(minutesID: String) throws -> [MinutesItem] {
        let rows = try withStatement("""
        SELECT id, minutes_id, local_id, kind, text, verdict, sort_order
        FROM minutes_item WHERE minutes_id = ? ORDER BY sort_order ASC;
        """) { statement -> [MinutesItem] in
            bind(statement, 1, minutesID)
            var items: [MinutesItem] = []
            while try step(statement) == SQLITE_ROW {
                items.append(MinutesItem(
                    id: columnText(statement, 0) ?? "",
                    minutesID: columnText(statement, 1) ?? minutesID,
                    localID: columnText(statement, 2) ?? "",
                    kind: columnText(statement, 3) ?? "",
                    text: columnText(statement, 4) ?? "",
                    verdict: columnText(statement, 5).flatMap(MinutesEvidenceValidator.Verdict.init(rawValue:)),
                    sortOrder: Int(columnInt(statement, 6))
                ))
            }
            return items
        }
        return try rows.map { item in
            var item = item
            item.anchors = try minutesEvidence(itemID: item.id)
            return item
        }
    }

    private func minutesEvidence(itemID: String) throws -> [MinutesEvidenceAnchor] {
        try withStatement("""
        SELECT e.id, e.item_id, e.unit_id, e.line_id, e.revision_id, e.snapshot_id,
               e.speaker_label, e.t_start, e.verification, r.text
        FROM minutes_evidence e
        LEFT JOIN transcript_revision r ON r.id = e.revision_id
        WHERE e.item_id = ?
        ORDER BY e.rowid ASC;
        """) { statement -> [MinutesEvidenceAnchor] in
            bind(statement, 1, itemID)
            var anchors: [MinutesEvidenceAnchor] = []
            while try step(statement) == SQLITE_ROW {
                anchors.append(MinutesEvidenceAnchor(
                    id: columnText(statement, 0) ?? "",
                    itemID: columnText(statement, 1) ?? itemID,
                    unitID: columnText(statement, 2) ?? "",
                    lineID: columnText(statement, 3),
                    revisionID: columnText(statement, 4),
                    snapshotID: columnText(statement, 5),
                    speakerLabel: columnText(statement, 6),
                    startSeconds: columnIsNull(statement, 7) ? nil : columnDouble(statement, 7),
                    quote: columnText(statement, 9),
                    verification: columnText(statement, 8) ?? "exact_source_match"
                ))
            }
            return anchors
        }
    }

    /// 每一行当前最新的修订（`lineID → revisionID`）。
    ///
    /// 生成任务靠它把"来源单元"落到不可变的修订上：单元带的是 `lineID`，
    /// 锚点要的是修订——中间这一步不补，引用就永远指着会变的 `line`。
    public func latestRevisionIDsByLine(sessionID: String) throws -> [String: String] {
        try withStatement("""
        SELECT line_id, id FROM transcript_revision r
        WHERE session_id = ?
          AND rowid = (
            SELECT rowid FROM transcript_revision x
            WHERE x.line_id = r.line_id
            ORDER BY x.edited_at DESC, x.rowid DESC LIMIT 1
          );
        """) { statement -> [String: String] in
            bind(statement, 1, sessionID)
            var map: [String: String] = [:]
            while try step(statement) == SQLITE_ROW {
                if let lineID = columnText(statement, 0), let revisionID = columnText(statement, 1) {
                    map[lineID] = revisionID
                }
            }
            return map
        }
    }

    /// 还有纪要没整理完的会话：排队中的，或者租约已经过期的 `running`。
    ///
    /// 启动时用它回收：App 崩一次之后，那一版纪要会永远卡在 `running`
    /// ——没有这条查询，用户看到的是"一直在整理"，而实际上什么都没在跑（§5.8）。
    public func sessionsWithPendingMinutes(now: Date = Date()) throws -> [String] {
        let sql = """
        SELECT DISTINCT session_id FROM minutes
        WHERE status = 'queued' OR (status = 'running' AND (lease_until IS NULL OR lease_until < ?));
        """
        return try withStatement(sql) { statement in
            bind(statement, 1, now.timeIntervalSince1970)
            var found: [String] = []
            while try step(statement) == SQLITE_ROW {
                if let id = columnText(statement, 0) { found.append(id) }
            }
            return found
        }
    }

    /// 待恢复的纪要行（MC-27）：排队中的，或租约已过期的 `running`，按版本升序。
    /// 返回整行以便调用方按原 job 身份认领，不新建版本。
    public func pendingMinutesRows(now: Date = Date()) throws -> [MinutesVersion] {
        let sql = """
        SELECT \(Self.minutesSelectColumns)
        FROM minutes
        WHERE status = 'queued' OR (status = 'running' AND (lease_until IS NULL OR lease_until < ?))
        ORDER BY version ASC;
        """
        return try withStatement(sql) { statement in
            bind(statement, 1, now.timeIntervalSince1970)
            var rows: [MinutesVersion] = []
            while try step(statement) == SQLITE_ROW {
                rows.append(minutesVersion(from: statement))
            }
            return rows
        }
    }

    /// 库里一共有多少条会话记录（含已封存的）。
    ///
    /// "这一场是不是唯一一场"这类断言要它：断线重连**不允许**多出一条记录，
    /// 光看当前 `sessionID` 相同还不够——必须能证明没有第二行。
    public func sessionCount() throws -> Int {
        try withStatement("SELECT COUNT(*) FROM session;") { statement in
            guard try step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    // MARK: - 内心 OS 与长期记忆

    /// 存一次问答。默认 `in_minutes = 0`：「默认不进纪要」由结构决定（§15.3 第 1 条）。
    ///
    /// MC-41/MC-42：建行一次，终态走 `finishInnerOSExchange` 条件 UPDATE；
    /// 答案、状态、证据同一事务写入，不半保存。调用方不得用第二次同 ID INSERT
    /// 冒充终态写入——主键冲突抛错，不吞错报成功。
    @discardableResult
    public func saveInnerOSExchange(_ exchange: InnerOSExchange, evidence: [InnerOSEvidence] = []) throws -> String {
        try execute("BEGIN IMMEDIATE;")
        do {
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
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        return exchange.id
    }

    /// 问答终态写入（MC-41/MC-42）：答案、状态、证据同一事务落库。
    /// 只允许从 `generating` 推向终态；0 行受影响抛错，调用方不得把“没写进去”
    /// 读成“已持久保存”。
    @discardableResult
    public func finishInnerOSExchange(_ exchange: InnerOSExchange, evidence: [InnerOSEvidence] = []) throws -> String {
        try execute("BEGIN IMMEDIATE;")
        do {
            let sql = """
            UPDATE inner_os_exchange
            SET answer_text = ?, draft_text = ?, intent = ?, confidence = ?,
                limits_note = ?, model = ?, status = ?, in_minutes = ?
            WHERE id = ? AND status = 'generating';
            """
            var changed = false
            try withStatement(sql) { statement in
                bind(statement, 1, exchange.answerText)
                bind(statement, 2, exchange.draftText)
                bind(statement, 3, exchange.intent?.rawValue)
                bind(statement, 4, exchange.confidence?.rawValue)
                bind(statement, 5, exchange.limitsNote)
                bind(statement, 6, exchange.model)
                bind(statement, 7, exchange.status.rawValue)
                bind(statement, 8, exchange.inMinutes ? 1 : 0)
                bind(statement, 9, exchange.id)
                try step(statement)
                changed = sqlite3_changes(try requireHandle()) == 1
            }
            guard changed else {
                throw SessionStoreError.statementFailed("问答终态写入影响 0 行：该问答不存在或已不在生成中")
            }
            for item in evidence {
                try insertEvidence(item, exchangeID: exchange.id)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
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

    /// 引文校验（MC-35、MC-36）：引文必须逐字出自所指转录行，否则标未验证。
    /// 返回每条证据的校验结论；调用方不得把未验证引文当已核实展示。
    /// 纯读操作，不写库。
    public func verifyEvidenceQuotes(exchangeID: String) throws -> [EvidenceQuoteCheck] {
        let rows = try innerOSEvidence(exchangeID: exchangeID)
        var checks: [EvidenceQuoteCheck] = []
        for row in rows {
            guard let quote = row.quote, !quote.isEmpty else {
                checks.append(EvidenceQuoteCheck(evidenceID: row.id, verified: false, reason: "引文为空"))
                continue
            }
            guard let lineID = row.lineID else {
                checks.append(EvidenceQuoteCheck(evidenceID: row.id, verified: false, reason: "没有指向转录行"))
                continue
            }
            let line = try withStatement(
                "SELECT id, session_id, ordinal, role, speaker_label, text, t_start, t_end, source, status, interrupted, device_switch, starred, timing_quality, created_at FROM line WHERE id = ? LIMIT 1;"
            ) { statement -> TranscriptLine? in
                bind(statement, 1, lineID)
                guard try step(statement) == SQLITE_ROW else { return nil }
                return Self.transcriptLine(from: statement)
            }

            guard let body = line?.text else {
                checks.append(EvidenceQuoteCheck(evidenceID: row.id, verified: false, reason: "所指转录行不存在"))
                continue
            }
            if body.contains(quote) {
                let occurrences = body.components(separatedBy: quote).count - 1
                if occurrences == 1 {
                    checks.append(EvidenceQuoteCheck(evidenceID: row.id, verified: true, reason: nil))
                } else {
                    checks.append(EvidenceQuoteCheck(evidenceID: row.id, verified: false, reason: "引文在行内出现多次，无法精确定位"))
                }
            } else {
                checks.append(EvidenceQuoteCheck(evidenceID: row.id, verified: false, reason: "引文与所指转录行不一致"))
            }
        }
        return checks
    }

    /// 单条引文的校验结论：只含判断与原因，不回显完整转写。
    public struct EvidenceQuoteCheck: Hashable, Sendable {
        public var evidenceID: String
        public var verified: Bool
        public var reason: String?
    }

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

    /// 会议库分页（MC-49）：按开始时间倒序，`offset`/`limit` 由调用方传，库不截断。
    /// 不传分页参数时返回全部，不再只给最近 8 场。
    public func listSessions(kind: SessionKind? = nil, limit: Int? = nil, offset: Int = 0) throws -> [SessionSummary] {
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
        ORDER BY s.started_at DESC
        \(limit == nil ? "" : "LIMIT ? OFFSET ?");
        """
        return try withStatement(sql) { statement in
            var index: Int32 = 1
            if let kind {
                bind(statement, index, kind.rawValue)
                index += 1
            }
            if let limit {
                bind(statement, index, limit)
                bind(statement, index + 1, offset)
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

    /// 知识检索结果：只含可展示的正文与纪要，不含私密问答（MC-44）。
    /// `excerpt` 是命中片段原文（调用方负责截断展示），不是完整转写回显。
    public struct KnowledgeHit: Hashable, Sendable {
        public var sessionID: String
        public var kind: SessionKind?
        public var lineID: String?
        public var minutesID: String?
        public var version: Int?
        public var excerpt: String
        public var ordinal: Int?
        public var createdAt: Date
    }

    /// 跨会议知识检索（MC-49、MC-52、MC-54）：转录终稿与已完成纪要正文。
    /// 私密问答（`inner_os_exchange`）默认不在范围内，不得隐式带出（MC-44）。
    /// 空查询返回空数组，不做全库扫描。
    public func searchKnowledge(query: String, kind: SessionKind? = nil, limit: Int = 200) throws -> [KnowledgeHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let pattern = "%" + trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
        var hits: [KnowledgeHit] = []
        let lineSQL = """
        SELECT l.session_id, s.kind, l.id, l.text, l.ordinal, l.created_at
        FROM line l JOIN session s ON s.id = l.session_id
        WHERE l.status = 'final' AND l.text LIKE ? ESCAPE '\\'
        \(kind == nil ? "" : "AND s.kind = ?")
        ORDER BY s.started_at DESC, l.ordinal ASC
        LIMIT ?;
        """
        try withStatement(lineSQL) { statement in
            bind(statement, 1, pattern)
            var index: Int32 = 2
            if let kind {
                bind(statement, index, kind.rawValue)
                index += 1
            }
            bind(statement, index, limit)
            while try step(statement) == SQLITE_ROW {
                hits.append(KnowledgeHit(
                    sessionID: columnText(statement, 0) ?? "",
                    kind: columnText(statement, 1).flatMap(SessionKind.init(rawValue:)),
                    lineID: columnText(statement, 2),
                    minutesID: nil,
                    version: nil,
                    excerpt: columnText(statement, 3) ?? "",
                    ordinal: Int(columnInt(statement, 4)),
                    createdAt: Date(timeIntervalSince1970: columnDouble(statement, 5))
                ))
            }
        }
        guard hits.count < limit else { return hits }
        let minutesSQL = """
        SELECT m.session_id, s.kind, m.id, m.version, m.body, m.created_at
        FROM minutes m JOIN session s ON s.id = m.session_id
        WHERE m.status = 'ready' AND m.body IS NOT NULL AND m.body LIKE ? ESCAPE '\\'
        \(kind == nil ? "" : "AND s.kind = ?")
        ORDER BY s.started_at DESC, m.version DESC
        LIMIT ?;
        """
        try withStatement(minutesSQL) { statement in
            bind(statement, 1, pattern)
            var index: Int32 = 2
            if let kind {
                bind(statement, index, kind.rawValue)
                index += 1
            }
            bind(statement, index, limit - hits.count)
            while try step(statement) == SQLITE_ROW {
                hits.append(KnowledgeHit(
                    sessionID: columnText(statement, 0) ?? "",
                    kind: columnText(statement, 1).flatMap(SessionKind.init(rawValue:)),
                    lineID: nil,
                    minutesID: columnText(statement, 2),
                    version: Int(columnInt(statement, 3)),
                    excerpt: columnText(statement, 4) ?? "",
                    ordinal: nil,
                    createdAt: Date(timeIntervalSince1970: columnDouble(statement, 5))
                ))
            }
        }
        return hits
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
        // 只读 `kind = 'voice'`：说话人修订（`kind = 'speaker'`）走 `speakerRevisions`，
        // 不混进音色变更点，避免回看徽标与既有快照语义被污染。
        let sql = "SELECT id, at_ordinal, kind, value, created_at FROM session_change WHERE session_id = ? AND kind = 'voice' ORDER BY at_ordinal ASC;"
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

    /// 一次读完"回看这一条"要的四份内容（`SessionReviewSnapshot`）。
    ///
    /// 复用上面四条语句，不重写 SQL。调用方原来要 4 次 `await`，界面就更新 4 次；
    /// 这里返回**一个值**，界面只赋值一次，翻记录一次到位。
    ///
    /// `lines` 保持 `includePartial: false`——记录库与导出只认已定稿行，口径不变。
    /// 记录不存在时返回 `nil`，与 `session(id:)` 一致。
    public func reviewSnapshot(sessionID: String) throws -> SessionReviewSnapshot? {
        guard let record = try session(id: sessionID) else { return nil }
        return SessionReviewSnapshot(
            record: record,
            lines: try lines(sessionID: sessionID),
            speakerNames: try speakerNames(sessionID: sessionID),
            voiceChanges: try voiceChanges(sessionID: sessionID)
        )
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

    /// 最新可用版（MC-25）：已完成且有正文的版本里版本号最大的那一版。
    /// 没有可用版时返回 nil，调用方不得把失败尝试或空正文当成功展示。
    public func latestUsableMinutes(sessionID: String) throws -> MinutesVersion? {
        let sql = """
        SELECT \(Self.minutesSelectColumns)
        FROM minutes WHERE session_id = ? AND status = 'ready' AND body IS NOT NULL
        ORDER BY version DESC LIMIT 1;
        """
        return try withStatement(sql) { statement -> MinutesVersion? in
            bind(statement, 1, sessionID)
            guard try step(statement) == SQLITE_ROW else { return nil }
            return minutesVersion(from: statement)
        }
    }

    /// 按 id 读一版纪要（MC-48）：查看、复制、导出、引用固定同一版，
    /// 找不到返回 nil，调用方不得回退成最新版冒充选定版。
    public func minutesVersion(id: String) throws -> MinutesVersion? {
        let sql = """
        SELECT \(Self.minutesSelectColumns)
        FROM minutes WHERE id = ? LIMIT 1;
        """
        return try withStatement(sql) { statement -> MinutesVersion? in
            bind(statement, 1, id)
            guard try step(statement) == SQLITE_ROW else { return nil }
            return minutesVersion(from: statement)
        }
    }

    public func minutesVersions(sessionID: String) throws -> [MinutesVersion] {
        let sql = """
        SELECT \(Self.minutesSelectColumns)
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

    /// 当前采用版（MA-06/MC-25/MC-31）：用户明确采用的那一版；没有采用过返回 nil。
    /// 调用方不得把最新尝试或最新可用版冒充成用户采用版。
    public func acceptedMinutes(sessionID: String) throws -> MinutesVersion? {
        let sql = """
        SELECT \(Self.minutesSelectColumns)
        FROM minutes WHERE session_id = ? AND is_accepted = 1 LIMIT 1;
        """
        return try withStatement(sql) { statement -> MinutesVersion? in
            bind(statement, 1, sessionID)
            guard try step(statement) == SQLITE_ROW else { return nil }
            return minutesVersion(from: statement)
        }
    }

    /// 当前应当展示/导出的那一版（MA-06/MC-25）：采用版优先，没有采用版才退回
    /// 最新可用候选。已采用 v2 后生成 v3 失败，默认仍是 v2。
    /// 这是展示口径的唯一查询；调用方不再各自拼"最新尝试/可用版"回退链。
    public func currentMinutes(sessionID: String) throws -> MinutesVersion? {
        if let accepted = try acceptedMinutes(sessionID: sessionID) { return accepted }
        return try latestUsableMinutes(sessionID: sessionID)
    }

    /// 采用一版纪要（MA-06/MC-31）：只有已完成且有正文的版本才能被采用；
    /// 同一事务清旧指针、立新指针；`expectedCurrentID` 是调用方开始操作时看到的
    /// 采用版 id（nil 表示当时无采用版），不一致时拒绝覆盖并返回 false。
    /// 返回是否真正提交。
    @discardableResult
    public func adoptMinutes(sessionID: String, minutesID: String, expectedCurrentID: String?) throws -> Bool {
        try execute("BEGIN IMMEDIATE;")
        do {
            let current = try withStatement("SELECT id FROM minutes WHERE session_id = ? AND is_accepted = 1 LIMIT 1;") { statement -> String? in
                bind(statement, 1, sessionID)
                guard try step(statement) == SQLITE_ROW else { return nil }
                return columnText(statement, 0)
            }
            guard current == expectedCurrentID else {
                try execute("ROLLBACK;")
                return false
            }
            var eligible = false
            try withStatement("SELECT status, body FROM minutes WHERE id = ? AND session_id = ? LIMIT 1;") { statement in
                bind(statement, 1, minutesID)
                bind(statement, 2, sessionID)
                guard try step(statement) == SQLITE_ROW else { return }
                eligible = columnText(statement, 0) == MinutesStatus.ready.rawValue && columnText(statement, 1) != nil
            }
            guard eligible else {
                try execute("ROLLBACK;")
                return false
            }
            try withStatement("UPDATE minutes SET is_accepted = 0 WHERE session_id = ?;") { statement in
                bind(statement, 1, sessionID)
                try step(statement)
            }
            var committed = false
            try withStatement("UPDATE minutes SET is_accepted = 1 WHERE id = ? AND session_id = ?;") { statement in
                bind(statement, 1, minutesID)
                bind(statement, 2, sessionID)
                try step(statement)
                committed = sqlite3_changes(try requireHandle()) > 0
            }
            guard committed else {
                try execute("ROLLBACK;")
                return false
            }
            try execute("COMMIT;")
            return true
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }
    // MARK: - Meeting knowledge documents (MA-05)

    @discardableResult
    public func createMeetingDocument(_ document: MeetingDocument) throws -> MeetingDocument {
        try execute("BEGIN IMMEDIATE;")
        do {
            let sql = "INSERT INTO meeting_document (id, source_session_id, title, project_id, occurred_at, timezone, deleted_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);"
            try withStatement(sql) { statement in
                bind(statement, 1, document.id)
                bind(statement, 2, document.sourceSessionID)
                bind(statement, 3, document.title)
                bind(statement, 4, document.projectID)
                bind(statement, 5, document.occurredAt?.timeIntervalSince1970)
                bind(statement, 6, document.timezone)
                bind(statement, 7, document.deletedAt?.timeIntervalSince1970)
                bind(statement, 8, document.createdAt.timeIntervalSince1970)
                bind(statement, 9, document.updatedAt.timeIntervalSince1970)
                try step(statement)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        guard let saved = try meetingDocument(id: document.id) else {
            throw SessionStoreError.statementFailed("会议知识文档写入后回读失败")
        }
        return saved
    }

    public func meetingDocument(id: String) throws -> MeetingDocument? {
        let sql = "SELECT id, source_session_id, title, project_id, occurred_at, timezone, deleted_at, created_at, updated_at FROM meeting_document WHERE id = ? LIMIT 1;"
        return try withStatement(sql) { statement -> MeetingDocument? in
            bind(statement, 1, id)
            guard try step(statement) == SQLITE_ROW else { return nil }
            return meetingDocument(from: statement)
        }
    }

    public func meetingDocument(forSessionID sessionID: String) throws -> MeetingDocument? {
        let sql = "SELECT id, source_session_id, title, project_id, occurred_at, timezone, deleted_at, created_at, updated_at FROM meeting_document WHERE source_session_id = ? LIMIT 1;"
        return try withStatement(sql) { statement -> MeetingDocument? in
            bind(statement, 1, sessionID)
            guard try step(statement) == SQLITE_ROW else { return nil }
            return meetingDocument(from: statement)
        }
    }

    private func meetingDocument(from statement: OpaquePointer) -> MeetingDocument {
        MeetingDocument(
            id: columnText(statement, 0) ?? "",
            sourceSessionID: columnText(statement, 1),
            title: columnText(statement, 2),
            projectID: columnText(statement, 3),
            occurredAt: columnIsNull(statement, 4) ? nil : Date(timeIntervalSince1970: columnDouble(statement, 4)),
            timezone: columnText(statement, 5),
            deletedAt: columnIsNull(statement, 6) ? nil : Date(timeIntervalSince1970: columnDouble(statement, 6)),
            createdAt: Date(timeIntervalSince1970: columnDouble(statement, 7)),
            updatedAt: Date(timeIntervalSince1970: columnDouble(statement, 8))
        )
    }

    @discardableResult
    public func sealMeetingSource(_ snapshot: MeetingSourceSnapshot) throws -> MeetingSourceSnapshot {
        guard try meetingDocument(id: snapshot.documentID) != nil else {
            throw SessionStoreError.statementFailed("关联的会议知识文档不存在，来源快照未写入")
        }
        try execute("BEGIN IMMEDIATE;")
        do {
            let sql = "INSERT INTO source_snapshot (id, document_id, line_revision_ids, speaker_map_revision, note_refs, coverage, seal_result, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?);"
            try withStatement(sql) { statement in
                bind(statement, 1, snapshot.id)
                bind(statement, 2, snapshot.documentID)
                bind(statement, 3, snapshot.lineRevisionIDs.joined(separator: ","))
                bind(statement, 4, snapshot.speakerMapRevision)
                bind(statement, 5, snapshot.noteRefs.joined(separator: ","))
                bind(statement, 6, snapshot.coverage)
                bind(statement, 7, snapshot.sealResult)
                bind(statement, 8, snapshot.createdAt.timeIntervalSince1970)
                try step(statement)
            }
            try withStatement("UPDATE meeting_document SET updated_at = ? WHERE id = ?;") { statement in
                bind(statement, 1, snapshot.createdAt.timeIntervalSince1970)
                bind(statement, 2, snapshot.documentID)
                try step(statement)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        guard let saved = try sourceSnapshot(id: snapshot.id) else {
            throw SessionStoreError.statementFailed("来源快照写入后回读失败")
        }
        return saved
    }

    public func sourceSnapshot(id: String) throws -> MeetingSourceSnapshot? {
        let sql = "SELECT id, document_id, line_revision_ids, speaker_map_revision, note_refs, coverage, seal_result, created_at FROM source_snapshot WHERE id = ? LIMIT 1;"
        return try withStatement(sql) { statement -> MeetingSourceSnapshot? in
            bind(statement, 1, id)
            guard try step(statement) == SQLITE_ROW else { return nil }
            return sourceSnapshot(from: statement)
        }
    }

    /// 把一场会议封成知识文档 + 来源快照（MA-03 收尾 / MA-05 落地，MC-20、MC-46）。
    ///
    /// 三件事在**同一个事务**里做完：建/取这一场的知识文档、把定稿行物化成
    /// 固定的行修订、写下这一份来源快照。少任何一样，"这一版依据的是哪几句话"
    /// 就还是悬空的。
    ///
    /// 幂等：同一场重复封存不会长出第二份文档，也不会给同一段文字再插一条修订——
    /// 只有**文字真的变了**才新增修订，并把上一条挂成 parent。所以用户改了转录再看旧纪要，
    /// 旧纪要仍然指着它当时依据的那一版（MC-46）。
    ///
    /// 没有定稿正文时返回 nil：库里"没有快照"就是"还没有可锚定的来源"，
    /// 造一条空快照等于宣称"这一场没有任何依据"。
    @discardableResult
    public func sealMeetingSource(
        sessionID: String,
        documentID: String? = nil,
        sealedAt: Date = Date()
    ) throws -> MeetingSourceSnapshot? {
        let document = documentID ?? "doc-\(sessionID)"
        var snapshotID: String?
        try execute("BEGIN IMMEDIATE;")
        do {
            try withStatement("""
            INSERT OR IGNORE INTO meeting_document
                (id, source_session_id, title, occurred_at, created_at, updated_at)
            VALUES (?, ?, (SELECT title FROM session WHERE id = ?), ?, ?, ?);
            """) { statement in
                bind(statement, 1, document)
                bind(statement, 2, sessionID)
                bind(statement, 3, sessionID)
                bind(statement, 4, sealedAt.timeIntervalSince1970)
                bind(statement, 5, sealedAt.timeIntervalSince1970)
                bind(statement, 6, sealedAt.timeIntervalSince1970)
                try step(statement)
            }

            let revisionIDs = try materializeTranscriptRevisions(sessionID: sessionID, at: sealedAt)
            guard !revisionIDs.isEmpty else {
                // 没有可锚定的正文：文档留着（这一场存在），但**不写空快照**。
                try execute("COMMIT;")
                return nil
            }

            let speakerRevision = try withStatement(
                "SELECT COALESCE(MAX(updated_at), 0) FROM speaker_name WHERE session_id = ?;"
            ) { statement -> String? in
                bind(statement, 1, sessionID)
                guard try step(statement) == SQLITE_ROW else { return nil }
                return String(columnDouble(statement, 0))
            }

            // 快照 id 由**内容**决定，不是由场次决定：
            //   · 文字没变 → 同样的 revision 集合 → 同一个 id → 重复封存不重复写；
            //   · 文字变了 → revision 集合变了 → 新 id → 新的快照。
            // 这样改了转录再看旧纪要，旧纪要那一份 `snapshot_id` 仍然指着旧快照，
            // 里面是它当时依据的那几段话（MC-46）。
            let snapshot = "snap-\(sessionID)-\(Self.stableDigest(revisionIDs))"
            snapshotID = snapshot
            try withStatement("""
            INSERT OR IGNORE INTO source_snapshot
                (id, document_id, line_revision_ids, speaker_map_revision, note_refs, coverage, seal_result, created_at)
            VALUES (?, ?, ?, ?, '[]', ?, 'ok', ?);
            """) { statement in
                bind(statement, 1, snapshot)
                bind(statement, 2, document)
                bind(statement, 3, revisionIDs.joined(separator: ","))
                bind(statement, 4, speakerRevision)
                bind(statement, 5, "final_lines=\(revisionIDs.count)")
                bind(statement, 6, sealedAt.timeIntervalSince1970)
                try step(statement)
            }
            try withStatement(
                "UPDATE meeting_document SET updated_at = ? WHERE id = ?;"
            ) { statement in
                bind(statement, 1, sealedAt.timeIntervalSince1970)
                bind(statement, 2, document)
                try step(statement)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        guard let snapshotID else { return nil }
        return try sourceSnapshot(id: snapshotID)
    }

    /// 把定稿行物化成不可变的行修订，返回本次快照锚定的 revision id（按 ordinal 序）。
    ///
    /// 文字没变的行**不新插**：同一段话反复封存不会在库里堆出一串一模一样的修订。
    /// 变了才新增，并把上一条挂成 `parent_revision_id`——修订链就是这样长出来的。
    private func materializeTranscriptRevisions(sessionID: String, at: Date) throws -> [String] {
        struct FinalLine {
            let id: String
            let text: String
            let role: String
            let createdAt: Double
        }
        let lines = try withStatement("""
        SELECT id, text, role, created_at FROM line
        WHERE session_id = ? AND status = 'final' ORDER BY ordinal ASC;
        """) { statement -> [FinalLine] in
            bind(statement, 1, sessionID)
            var rows: [FinalLine] = []
            while try step(statement) == SQLITE_ROW {
                rows.append(FinalLine(
                    id: columnText(statement, 0) ?? "",
                    text: columnText(statement, 1) ?? "",
                    role: columnText(statement, 2) ?? "speaker",
                    createdAt: columnDouble(statement, 3)
                ))
            }
            return rows
        }

        var revisionIDs: [String] = []
        for line in lines {
            let latest = try withStatement("""
            SELECT id, text FROM transcript_revision
            WHERE line_id = ? ORDER BY edited_at DESC, rowid DESC LIMIT 1;
            """) { statement -> (id: String, text: String)? in
                bind(statement, 1, line.id)
                guard try step(statement) == SQLITE_ROW else { return nil }
                return (id: columnText(statement, 0) ?? "", text: columnText(statement, 1) ?? "")
            }
            if let latest, latest.text == line.text {
                revisionIDs.append(latest.id)
                continue
            }
            // 人工输入与 ASR 分开记：将来"这句是谁写的"要能从修订上直接看出来。
            let origin = line.role == "user" ? "user_input" : "asr"
            let revisionID = "rev-\(line.id)-\(UUID().uuidString.prefix(8))"
            try withStatement("""
            INSERT INTO transcript_revision
                (id, line_id, session_id, text, origin, parent_revision_id, edited_at)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """) { statement in
                bind(statement, 1, revisionID)
                bind(statement, 2, line.id)
                bind(statement, 3, sessionID)
                bind(statement, 4, line.text)
                bind(statement, 5, origin)
                bind(statement, 6, latest?.id)
                bind(statement, 7, latest == nil ? line.createdAt : at.timeIntervalSince1970)
                try step(statement)
            }
            revisionIDs.append(revisionID)
        }
        return revisionIDs
    }

    /// 这一场最近一次封存的来源快照（MA-07/MC-20）。
    ///
    /// 生成任务在排队那一刻绑定它：同一任务不能边整理边跟随来源变化，
    /// 否则"这一版依据的是哪份转录"就说不清了。
    /// 还没有快照时返回 nil——**不现造一个**：封存语义属于来源封存那一步（MA-08），
    /// 这里读不到就说"还没有"。
    public func latestSourceSnapshot(sessionID: String) throws -> MeetingSourceSnapshot? {
        let sql = """
        SELECT s.id, s.document_id, s.line_revision_ids, s.speaker_map_revision,
               s.note_refs, s.coverage, s.seal_result, s.created_at
        FROM source_snapshot s
        JOIN meeting_document d ON d.id = s.document_id
        WHERE d.source_session_id = ?
        ORDER BY s.created_at DESC, s.rowid DESC LIMIT 1;
        """
        return try withStatement(sql) { statement -> MeetingSourceSnapshot? in
            bind(statement, 1, sessionID)
            guard try step(statement) == SQLITE_ROW else { return nil }
            return sourceSnapshot(from: statement)
        }
    }

    /// 内容指纹：同一组输入在任何一次启动、任何一台机器上都得到同一个值。
    ///
    /// 刻意不用 `Hashable.hashValue`——它每次启动都不同，拿它当快照 id 的话
    /// "同一份来源"在两次运行之间会被当成两份，旧纪要的引用就断了。
    /// FNV-1a 够用：这里要的是稳定与可比较，不是抗碰撞。
    private static func stableDigest(_ parts: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in parts.joined(separator: ",").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    private func sourceSnapshot(from statement: OpaquePointer) -> MeetingSourceSnapshot {
        func split(_ raw: String?) -> [String] {
            guard let raw, !raw.isEmpty else { return [] }
            return raw.split(separator: ",").map(String.init)
        }
        return MeetingSourceSnapshot(
            id: columnText(statement, 0) ?? "",
            documentID: columnText(statement, 1) ?? "",
            lineRevisionIDs: split(columnText(statement, 2)),
            speakerMapRevision: columnText(statement, 3),
            noteRefs: split(columnText(statement, 4)),
            coverage: columnText(statement, 5),
            sealResult: columnText(statement, 6) ?? "ok",
            createdAt: Date(timeIntervalSince1970: columnDouble(statement, 7))
        )
    }

    @discardableResult
    public func recordTranscriptRevision(_ revision: TranscriptRevision) throws -> TranscriptRevision {
        let sql = "INSERT INTO transcript_revision (id, line_id, session_id, text, origin, parent_revision_id, edited_at) VALUES (?, ?, ?, ?, ?, ?, ?);"
        try withStatement(sql) { statement in
            bind(statement, 1, revision.id)
            bind(statement, 2, revision.lineID)
            bind(statement, 3, revision.sessionID)
            bind(statement, 4, revision.text)
            bind(statement, 5, revision.origin)
            bind(statement, 6, revision.parentRevisionID)
            bind(statement, 7, revision.editedAt.timeIntervalSince1970)
            try step(statement)
        }
        return revision
    }

    public func transcriptRevisions(lineID: String) throws -> [TranscriptRevision] {
        let sql = "SELECT id, line_id, session_id, text, origin, parent_revision_id, edited_at FROM transcript_revision WHERE line_id = ? ORDER BY edited_at ASC;"
        return try withStatement(sql) { statement in
            bind(statement, 1, lineID)
            var rows: [TranscriptRevision] = []
            while try step(statement) == SQLITE_ROW {
                rows.append(TranscriptRevision(
                    id: columnText(statement, 0) ?? "",
                    lineID: columnText(statement, 1) ?? lineID,
                    sessionID: columnText(statement, 2) ?? "",
                    text: columnText(statement, 3) ?? "",
                    origin: columnText(statement, 4) ?? "",
                    parentRevisionID: columnText(statement, 5),
                    editedAt: Date(timeIntervalSince1970: columnDouble(statement, 6))
                ))
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

    /// 一次问答引用的原文证据。**先当 `quote` 是事实**：`line_id` 可能已经被移除
    /// （`ON DELETE SET NULL`），顺不回去也要读得懂当时引的是哪一句。
    public func innerOSEvidence(exchangeID: String) throws -> [InnerOSEvidence] {
        let sql = """
        SELECT id, line_id, speaker_label, t_start, quote, content_hash
        FROM inner_os_evidence WHERE exchange_id = ?;
        """
        return try withStatement(sql) { statement in
            bind(statement, 1, exchangeID)
            var rows: [InnerOSEvidence] = []
            while try step(statement) == SQLITE_ROW {
                rows.append(
                    InnerOSEvidence(
                        id: columnText(statement, 0) ?? UUID().uuidString,
                        lineID: columnText(statement, 1),
                        speakerLabel: columnText(statement, 2),
                        tStart: columnIsNull(statement, 3) ? nil : columnDouble(statement, 3),
                        quote: columnText(statement, 4),
                        contentHash: columnText(statement, 5)
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

    /// 恢复验证（MC-20 落库前置、恢复可证）：打开备份库并核对一致性。
    /// 只读备份文件，不写原库；失败抛错，调用方不得继续按备份覆盖原库。
    public static func verifyBackup(at url: URL) throws -> BackupVerification {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw SessionStoreError.storageUnavailable
        }
        let probe = SessionStore(directory: url.deletingLastPathComponent())
        _ = probe
        // 备份文件本身就是库文件：用只读连接做 integrity_check，不迁移、不写入。
        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY
        let status = sqlite3_open_v2(url.path, &pointer, flags, nil)
        guard status == SQLITE_OK, let db = pointer else {
            if let pointer { sqlite3_close_v2(pointer) }
            throw SessionStoreError.openFailed("备份库打不开：code \(status)")
        }
        defer { sqlite3_close_v2(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check;", -1, &statement, nil) == SQLITE_OK,
              let query = statement else {
            throw SessionStoreError.statementFailed("备份校验语句准备失败")
        }
        defer { sqlite3_finalize(query) }
        var verdict = "ok"
        if sqlite3_step(query) == SQLITE_ROW, let text = sqlite3_column_text(query, 0) {
            verdict = String(cString: text)
        }
        guard verdict.lowercased() == "ok" else {
            throw SessionStoreError.statementFailed("备份完整性校验未通过：\(verdict)")
        }
        let countSQL = "SELECT COUNT(*) FROM minutes;"
        var countStatement: OpaquePointer?
        var minutesCount = 0
        if sqlite3_prepare_v2(db, countSQL, -1, &countStatement, nil) == SQLITE_OK,
           let counter = countStatement {
            defer { sqlite3_finalize(counter) }
            if sqlite3_step(counter) == SQLITE_ROW {
                minutesCount = Int(sqlite3_column_int64(counter, 0))
            }
        }
        return BackupVerification(integrity: verdict, minutesCount: minutesCount)
    }

    /// 备份校验结论：只含计数与结论，不含正文与路径回显。
    public struct BackupVerification: Hashable, Sendable {
        public var integrity: String
        public var minutesCount: Int
    }

    /// 备份清单（MA-20 / §12.3）。与库文件**并排**存放，缺它就不算一份可用的备份。
    ///
    /// 只存计数与 schema 版本，不存正文：清单跟着备份走，泄露面必须和库本身一样小。
    public struct BackupManifest: Codable, Hashable, Sendable {
        public var schemaVersion: Int
        public var createdAt: Date
        public var counts: BackupCounts

        public init(schemaVersion: Int, createdAt: Date, counts: BackupCounts) {
            self.schemaVersion = schemaVersion
            self.createdAt = createdAt
            self.counts = counts
        }
    }

    /// 备份里的行数。用于恢复后核对"少了没有、多了没有"。
    public struct BackupCounts: Codable, Hashable, Sendable {
        public var sessions: Int
        public var lines: Int
        public var meetingDocuments: Int
        public var transcriptRevisions: Int
        public var sourceSnapshots: Int
        public var minutes: Int
        public var minutesItems: Int
        public var minutesEvidence: Int
        public var minutesWindows: Int

        public init(
            sessions: Int,
            lines: Int,
            meetingDocuments: Int,
            transcriptRevisions: Int,
            sourceSnapshots: Int,
            minutes: Int,
            minutesItems: Int,
            minutesEvidence: Int,
            minutesWindows: Int
        ) {
            self.sessions = sessions
            self.lines = lines
            self.meetingDocuments = meetingDocuments
            self.transcriptRevisions = transcriptRevisions
            self.sourceSnapshots = sourceSnapshots
            self.minutes = minutes
            self.minutesItems = minutesItems
            self.minutesEvidence = minutesEvidence
            self.minutesWindows = minutesWindows
        }

        public static let zero = BackupCounts(
            sessions: 0, lines: 0, meetingDocuments: 0, transcriptRevisions: 0,
            sourceSnapshots: 0, minutes: 0, minutesItems: 0, minutesEvidence: 0, minutesWindows: 0
        )
    }

    /// 备份文件与清单的固定名字。清单缺了就当没有备份——
    /// 只剩一个 .sqlite3 时无法判断它是不是完整、是不是当前 schema 写的。
    public static let backupFileName = "sessions.sqlite3"
    public static let backupManifestName = "manifest.json"

    /// 导出一份备份：库快照 + 清单，**原子发布**（§12.3）。
    ///
    /// 先写临时名再改名：中途崩了不会留下"半个备份"被当成可用的那一份。
    /// 目标目录已存在同名备份时直接失败——覆盖一份用户可能正在保留的旧备份，
    /// 比备份失败更糟。
    @discardableResult
    public func exportBackup(to directory: URL) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent(Self.backupFileName)
        let manifestURL = directory.appendingPathComponent(Self.backupManifestName)
        let stagingURL = directory.appendingPathComponent(".\(Self.backupFileName).staging")
        if fileManager.fileExists(atPath: stagingURL.path) {
            try fileManager.removeItem(at: stagingURL)
        }
        try backup(to: stagingURL)
        let manifest = BackupManifest(
            schemaVersion: Int(Self.schemaVersion),
            createdAt: Date(),
            counts: try knowledgeCounts()
        )
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        if fileManager.fileExists(atPath: databaseURL.path) {
            // 已有同名备份：原子替换，不先删——先删再失败就两头都没了。
            _ = try fileManager.replaceItemAt(databaseURL, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: databaseURL)
        }
        return directory
    }

    /// 当前库的知识内容行数（不含运行时缓存）。
    private func knowledgeCounts() throws -> BackupCounts {
        func count(_ sql: String) throws -> Int {
            try scalarInt(sql) ?? 0
        }
        return BackupCounts(
            sessions: try count("SELECT COUNT(*) FROM session;"),
            lines: try count("SELECT COUNT(*) FROM line;"),
            meetingDocuments: try count("SELECT COUNT(*) FROM meeting_document;"),
            transcriptRevisions: try count("SELECT COUNT(*) FROM transcript_revision;"),
            sourceSnapshots: try count("SELECT COUNT(*) FROM source_snapshot;"),
            minutes: try count("SELECT COUNT(*) FROM minutes;"),
            minutesItems: try count("SELECT COUNT(*) FROM minutes_item;"),
            minutesEvidence: try count("SELECT COUNT(*) FROM minutes_evidence;"),
            minutesWindows: try count("SELECT COUNT(*) FROM minutes_window;")
        )
    }

    /// 恢复预演（MC-70 / §12.3）：把备份复制到**临时目录**当新库打开，
    /// 核对文档、版本、引用与行动项关联，然后如实报告。
    ///
    /// 三条边界：
    /// 1. **只碰临时副本**，从不打开或改写当前库——校验不过时当前库当然也不变；
    /// 2. 比当前 schema 更新的备份**拒绝**（MC-69），不尝试破坏性降级；
    /// 3. 比当前旧的备份允许就地迁移后核对——那正是"备份可恢复"要证明的事。
    ///
    /// 调用方在拿到 `.isRestorable == true` 之后才谈得上切换；本方法本身不做切换。
    public static func restorePreview(
        of bundleDirectory: URL,
        into scratchDirectory: URL
    ) async throws -> RestorePreview {
        let fm = FileManager.default
        let source = bundleDirectory.appendingPathComponent(backupFileName)
        guard fm.fileExists(atPath: source.path) else {
            throw SessionStoreError.storageUnavailable
        }
        let manifestURL = bundleDirectory.appendingPathComponent(backupManifestName)
        guard
            let manifestData = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder().decode(BackupManifest.self, from: manifestData)
        else {
            // 没有清单就无法判断完整性：明确拒绝，不"尽力恢复"。
            throw SessionStoreError.statementFailed("备份缺少清单文件，不能作为可恢复的备份使用")
        }

        try fm.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        let staged = scratchDirectory.appendingPathComponent(fileName)
        if fm.fileExists(atPath: staged.path) {
            try fm.removeItem(at: staged)
        }
        try fm.copyItem(at: source, to: staged)
        // WAL/共享内存旁文件也可能带着未合并的页，一并带过去再合并。
        for suffix in ["-wal", "-shm"] {
            let extra = bundleDirectory.appendingPathComponent(backupFileName + suffix)
            if fm.fileExists(atPath: extra.path) {
                try? fm.copyItem(
                    at: extra,
                    to: scratchDirectory.appendingPathComponent(fileName + suffix)
                )
            }
        }

        // 打不开就地抛：schema 更新、文件损坏都在这里被挡住，当前库不受影响。
        let scratch = SessionStore(directory: scratchDirectory)
        let preview: RestorePreview
        do {
            try await scratch.open()
            let counts = try await scratch.knowledgeCounts()
            let verification = try await scratch.verifyReferences()
            let readable = try await scratch.readbackReport()

            var problems: [String] = []
            if !verification.isClean {
                problems.append(contentsOf: verification.problems)
            }
            if counts.minutes != manifest.counts.minutes {
                problems.append("纪要版本数对不上：清单 \(manifest.counts.minutes)，新库读到 \(counts.minutes)")
            }
            if counts.minutesItems != manifest.counts.minutesItems {
                problems.append("结论条目数对不上：清单 \(manifest.counts.minutesItems)，新库读到 \(counts.minutesItems)")
            }
            if counts.meetingDocuments != manifest.counts.meetingDocuments {
                problems.append("知识文档数对不上：清单 \(manifest.counts.meetingDocuments)，新库读到 \(counts.meetingDocuments)")
            }
            problems.append(contentsOf: readable.problems)

            preview = RestorePreview(
                sourceSchemaVersion: manifest.schemaVersion,
                restoredCounts: counts,
                references: verification,
                documentsReadable: readable.documentsReadable,
                versionsReadable: readable.versionsReadable,
                actionsReadable: readable.actionsReadable,
                anchorsWithQuote: readable.anchorsWithQuote,
                problems: problems,
                isRestorable: problems.isEmpty
            )
        } catch {
            // 校验不过就如实失败：临时副本仍然是副本，当前库一个字节都没动。
            await scratch.close()
            throw error
        }
        await scratch.close()
        return preview
    }

    /// 引用完整性（MC-70）：外键 + 四条跨表引用。
    ///
    /// `PRAGMA foreign_key_check` 只覆盖声明了外键的列；这里额外查"证据锚点指向的
    /// 修订/行是否还在"，因为那是本项目最要紧的一条引用，而它允许 `ON DELETE SET NULL`
    /// ——被删的引用是**合法的**（明确表示"来源已不可读"），不算断裂。
    public func verifyReferences() throws -> ReferenceVerification {
        var problems: [String] = []
        let foreignKeyIssues = try scalarInt("SELECT COUNT(*) FROM pragma_foreign_key_check;") ?? 0
        if foreignKeyIssues > 0 {
            problems.append("有 \(foreignKeyIssues) 处外键指向不存在的行")
        }
        func orphanCount(_ sql: String) throws -> Int {
            try scalarInt(sql) ?? 0
        }
        let orphanItems = try orphanCount(
            "SELECT COUNT(*) FROM minutes_item i LEFT JOIN minutes m ON m.id = i.minutes_id WHERE m.id IS NULL;"
        )
        if orphanItems > 0 {
            problems.append("有 \(orphanItems) 条结论条目挂在不存在的纪要上")
        }
        let orphanWindows = try orphanCount(
            "SELECT COUNT(*) FROM minutes_window w LEFT JOIN minutes m ON m.id = w.minutes_id WHERE m.id IS NULL;"
        )
        if orphanWindows > 0 {
            problems.append("有 \(orphanWindows) 行窗口进度挂在不存在的纪要上")
        }
        let orphanEvidence = try orphanCount(
            "SELECT COUNT(*) FROM minutes_evidence e LEFT JOIN minutes_item i ON i.id = e.item_id WHERE i.id IS NULL;"
        )
        if orphanEvidence > 0 {
            problems.append("有 \(orphanEvidence) 条证据锚点挂在不存在的结论上")
        }
        let orphanSnapshots = try orphanCount(
            "SELECT COUNT(*) FROM source_snapshot s LEFT JOIN meeting_document d ON d.id = s.document_id WHERE d.id IS NULL;"
        )
        if orphanSnapshots > 0 {
            problems.append("有 \(orphanSnapshots) 个来源快照挂在不存在的知识文档上")
        }
        return ReferenceVerification(
            foreignKeyIssues: foreignKeyIssues,
            problems: problems,
            isClean: problems.isEmpty
        )
    }

    /// 回读关键内容：文档、版本、引用与行动项（MC-70「恢复成功需回读关键文档」）。
    private func readbackReport() throws -> ReadbackReport {
        var problems: [String] = []
        var documents = 0
        var versions = 0
        var actions = 0
        var anchorsWithQuote = 0
        let sessions = try allSessionsForVerification()
        for session in sessions {
            if try meetingDocument(forSessionID: session.id) != nil {
                documents += 1
            }
            let rows = try minutesVersions(sessionID: session.id)
            versions += rows.count
            for row in rows {
                let items = try minutesItems(minutesID: row.id)
                for item in items {
                    actions += 1
                    anchorsWithQuote += item.anchors.filter { $0.quote != nil }.count
                }
            }
        }
        return ReadbackReport(
            documentsReadable: documents,
            versionsReadable: versions,
            actionsReadable: actions,
            anchorsWithQuote: anchorsWithQuote,
            problems: problems
        )
    }

    private func allSessionsForVerification() throws -> [SessionRecord] {
        try withStatement("SELECT \(Self.sessionColumns) FROM session;") { statement in
            var records: [SessionRecord] = []
            while try step(statement) == SQLITE_ROW {
                if let record = Self.sessionRecord(from: statement) {
                    records.append(record)
                }
            }
            return records
        }
    }

    /// 恢复预演结论。字段都是计数与布尔，不含正文与路径。
    public struct RestorePreview: Sendable {
        public var sourceSchemaVersion: Int
        public var restoredCounts: BackupCounts
        public var references: ReferenceVerification
        public var documentsReadable: Int
        public var versionsReadable: Int
        public var actionsReadable: Int
        public var anchorsWithQuote: Int
        public var problems: [String]
        /// 只有这里为 true，调用才可以考虑切换到这份备份。
        public var isRestorable: Bool
    }

    public struct ReferenceVerification: Hashable, Sendable {
        public var foreignKeyIssues: Int
        public var problems: [String]
        public var isClean: Bool
    }

    private struct ReadbackReport: Sendable {
        var documentsReadable: Int
        var versionsReadable: Int
        var actionsReadable: Int
        var anchorsWithQuote: Int
        var problems: [String]
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
        // 列顺序固定为 `minutesSelectColumns`：0...7 为基础字段，8 为 is_accepted（MA-06），
        // 其后依次为 attempts / failure_reason / lease_until / created_at / is_legacy_import，
        // 最后四列是 MA-07 的任务身份（remote_response_id / config_snapshot / snapshot_id /
        // cancel_requested_at）。
        // 老库读不到后面的列时按"没有过"处理，不猜：v1 没有 is_legacy_import（按 legacy，
        // MC-68）、v2 没有 is_accepted（按未采用）、v3 没有任务身份（按没有远端响应）。
        // v7 追加 coverage_json：读不到就是没有分窗账本，**不**当成"全部覆盖"。
        let count = Int(sqlite3_column_count(statement))
        let accepted: Bool = {
            guard count > 8 else { return false }
            return columnInt(statement, 8) != 0
        }()
        let legacy: Bool = {
            guard count > 13 else { return true }
            return columnInt(statement, 13) != 0
        }()
        func optionalDate(_ index: Int32) -> Date? {
            guard count > Int(index) else { return nil }
            return columnIsNull(statement, index) ? nil : Date(timeIntervalSince1970: columnDouble(statement, index))
        }
        return MinutesVersion(
            id: columnText(statement, 0) ?? "",
            sessionID: columnText(statement, 1) ?? "",
            version: Int(columnInt(statement, 2)),
            status: columnText(statement, 3).flatMap(MinutesStatus.init(rawValue:)) ?? .ready,
            body: columnText(statement, 4),
            model: columnText(statement, 5),
            promptChars: columnIsNull(statement, 6) ? nil : Int(columnInt(statement, 6)),
            isLatest: columnInt(statement, 7) != 0,
            isAccepted: accepted,
            attempts: Int(columnInt(statement, 9)),
            failureReason: columnText(statement, 10),
            leaseUntil: columnIsNull(statement, 11) ? nil : Date(timeIntervalSince1970: columnDouble(statement, 11)),
            createdAt: Date(timeIntervalSince1970: columnDouble(statement, 12)),
            isLegacyImport: legacy,
            remoteResponseID: count > 14 ? columnText(statement, 14) : nil,
            configSnapshot: count > 15 ? columnText(statement, 15) : nil,
            snapshotID: count > 16 ? columnText(statement, 16) : nil,
            cancelRequestedAt: optionalDate(17),
            candidateJSON: count > 18 ? columnText(statement, 18) : nil,
            reviewJSON: count > 19 ? columnText(statement, 19) : nil,
            coverageJSON: count > 20 ? columnText(statement, 20) : nil
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
      is_accepted    INTEGER NOT NULL DEFAULT 0,
      attempts       INTEGER NOT NULL DEFAULT 0,
      failure_reason TEXT,
      lease_until    REAL,
      created_at     REAL NOT NULL,
      -- MA-07 的任务身份四列：新库建表时就在，旧库由 migrateV3ToV4 追加。
      remote_response_id  TEXT,
      config_snapshot     TEXT,
      snapshot_id         TEXT,
      cancel_requested_at REAL,
      -- MA-08：结构化候选与核对报告。新库建表时就在，旧库由 migrateV4ToV5 追加。
      candidate_json TEXT,
      review_json    TEXT,
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

    /// v1 → v2（MA-05）：会议知识文档三表 + `minutes.is_legacy_import`。
    /// 只做加法：v1 用户数据原样保留；新库（v0 → v2）由 `migrate()` 先建 v1 再升 v2，
    /// 所以 `schemaV1` 不改，v2 语句对已存在对象用 `IF NOT EXISTS` 兜底幂等。
    /// 迁移后旧纪要正文不动；是否 legacy 由调用方按“有无来源快照”判断，
    /// 库层不猜、不补造引用（MC-68）。
    static let schemaV2Delta = """
    CREATE TABLE IF NOT EXISTS meeting_document (
      id                 TEXT PRIMARY KEY,
      source_session_id  TEXT UNIQUE REFERENCES session(id) ON DELETE SET NULL,
      title              TEXT,
      project_id         TEXT,
      occurred_at        REAL,
      timezone           TEXT,
      deleted_at         REAL,
      created_at         REAL NOT NULL,
      updated_at         REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS meeting_document_by_project ON meeting_document(project_id, occurred_at DESC);
    CREATE INDEX IF NOT EXISTS meeting_document_by_session ON meeting_document(source_session_id);

    CREATE TABLE IF NOT EXISTS transcript_revision (
      id                 TEXT PRIMARY KEY,
      line_id            TEXT NOT NULL REFERENCES line(id) ON DELETE CASCADE,
      session_id         TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
      text               TEXT NOT NULL,
      origin             TEXT NOT NULL,
      parent_revision_id TEXT REFERENCES transcript_revision(id) ON DELETE SET NULL,
      edited_at          REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS transcript_revision_by_line ON transcript_revision(line_id, edited_at ASC);

    CREATE TABLE IF NOT EXISTS source_snapshot (
      id                    TEXT PRIMARY KEY,
      document_id           TEXT NOT NULL REFERENCES meeting_document(id) ON DELETE CASCADE,
      line_revision_ids     TEXT NOT NULL DEFAULT '[]',
      speaker_map_revision  TEXT,
      note_refs             TEXT NOT NULL DEFAULT '[]',
      coverage              TEXT,
      seal_result           TEXT NOT NULL DEFAULT 'ok',
      created_at            REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS source_snapshot_by_document ON source_snapshot(document_id, created_at DESC);
    """

    /// v1 → v2 的 DDL 与回填（调用方已在同一事务内）。
    /// `minutes.is_legacy_import` 用 `ALTER TABLE` 追加：SQLite 不支持 `IF NOT EXISTS` 列，
    /// 所以先查 `PRAGMA table_info`，已存在则跳过，保证迁移幂等。
    private func migrateV1ToV2() throws {
        try execute(Self.schemaV2Delta)
        let columns = try withStatement("PRAGMA table_info(minutes);") { statement in
            var names: [String] = []
            while try step(statement) == SQLITE_ROW {
                if let name = columnText(statement, 1) { names.append(name) }
            }
            return names
        }
        if !columns.contains("is_legacy_import") {
            try execute("ALTER TABLE minutes ADD COLUMN is_legacy_import INTEGER NOT NULL DEFAULT 0;")
        }
        // 回填：已有 minutes 行全部标为 legacy（v1 时代没有来源快照，不补造引用）；
        // transcript_revision 回填只针对 final 行做 `legacy_import` 起点，
        // 让 MC-46 的“引用仍指旧 revision”有据可查。
        try execute("UPDATE minutes SET is_legacy_import = 1 WHERE is_legacy_import = 0;")
        try execute("""
        INSERT OR IGNORE INTO transcript_revision (id, line_id, session_id, text, origin, parent_revision_id, edited_at)
        SELECT 'rev-' || line.id, line.id, line.session_id, line.text, 'legacy_import', NULL, line.created_at
        FROM line WHERE line.status = 'final';
        """)
    }

    /// v2 → v3 的 DDL（调用方已在同一事务内）。
    /// 只追加 `is_accepted` 列：旧库行默认 0（无采用版），不猜测用户意图；
    /// 新版首次采用必须走 `adoptMinutes` 显式动作（MC-31）。
    private func migrateV2ToV3() throws {
        let columns = try withStatement("PRAGMA table_info(minutes);") { statement in
            var names: [String] = []
            while try step(statement) == SQLITE_ROW {
                if let name = columnText(statement, 1) { names.append(name) }
            }
            return names
        }
        if !columns.contains("is_accepted") {
            try execute("ALTER TABLE minutes ADD COLUMN is_accepted INTEGER NOT NULL DEFAULT 0;")
        }
    }

    /// v3 → v4 的 DDL（调用方已在同一事务内）：任务身份四列。
    ///
    /// 全部可空且**不回填**：老任务当年没有把 response id 存下来过，
    /// 补一个空值等于伪造"我们确认过远端没在跑"（§8.5）。它们的语义是
    /// "没有这项信息"，不是"这项为否"。
    private func migrateV3ToV4() throws {
        let columns = try withStatement("PRAGMA table_info(minutes);") { statement in
            var names: [String] = []
            while try step(statement) == SQLITE_ROW {
                if let name = columnText(statement, 1) { names.append(name) }
            }
            return names
        }
        let additions: [(String, String)] = [
            ("remote_response_id", "TEXT"),
            ("config_snapshot", "TEXT"),
            ("snapshot_id", "TEXT"),
            ("cancel_requested_at", "REAL"),
        ]
        for (name, type) in additions where !columns.contains(name) {
            try execute("ALTER TABLE minutes ADD COLUMN \(name) \(type);")
        }
    }

    /// v4 → v5 的 DDL（调用方已在同一事务内）：结构化候选与核对报告两列。
    ///
    /// 同样**不回填**：v4 之前生成的正文是 Markdown，没有结构化候选可还原。
    /// 硬造一份等于凭空给旧纪要安上引用。
    private func migrateV4ToV5() throws {
        let columns = try withStatement("PRAGMA table_info(minutes);") { statement in
            var names: [String] = []
            while try step(statement) == SQLITE_ROW {
                if let name = columnText(statement, 1) { names.append(name) }
            }
            return names
        }
        for name in ["candidate_json", "review_json"] where !columns.contains(name) {
            try execute("ALTER TABLE minutes ADD COLUMN \(name) TEXT;")
        }
    }

    /// v5 → v6 的 DDL（调用方已在同一事务内）：结论条目与证据锚点两表。
    ///
    /// `revision_id` 用 `ON DELETE SET NULL`：修订被删时锚点还在，但明确变成
    /// "来源已不可读"。拿当前 `line` 顶替是错的——那会让旧引用指向新文字，
    /// 正是 MC-46 要防的事。
    static let schemaV6Delta = """
    CREATE TABLE IF NOT EXISTS minutes_item (
      id          TEXT PRIMARY KEY,
      minutes_id  TEXT NOT NULL REFERENCES minutes(id) ON DELETE CASCADE,
      local_id    TEXT NOT NULL,
      kind        TEXT NOT NULL,
      text        TEXT NOT NULL,
      verdict     TEXT,
      sort_order  INTEGER NOT NULL,
      UNIQUE (minutes_id, local_id)
    );
    CREATE INDEX IF NOT EXISTS minutes_item_by_minutes ON minutes_item(minutes_id, sort_order);

    CREATE TABLE IF NOT EXISTS minutes_evidence (
      id            TEXT PRIMARY KEY,
      item_id       TEXT NOT NULL REFERENCES minutes_item(id) ON DELETE CASCADE,
      unit_id       TEXT NOT NULL,
      line_id       TEXT REFERENCES line(id) ON DELETE SET NULL,
      revision_id   TEXT REFERENCES transcript_revision(id) ON DELETE SET NULL,
      snapshot_id   TEXT,
      speaker_label TEXT,
      t_start       REAL,
      verification  TEXT NOT NULL DEFAULT 'exact_source_match'
    );
    CREATE INDEX IF NOT EXISTS minutes_evidence_by_item ON minutes_evidence(item_id);
    """

    private func migrateV5ToV6() throws {
        try execute(Self.schemaV6Delta)
    }

    /// v6 → v7 的 DDL（调用方已在同一事务内）：覆盖账本（MA-09 / §6.3）。
    ///
    /// 两样东西：`minutes.coverage_json` 记这一版**整体**覆盖到哪，
    /// `minutes_window` 记**每个窗口**的拥有区间与处理结果。
    ///
    /// 分开存的原因：局部重试只重跑失败的那一窗，重跑后要把成功窗口的
    /// 候选重新合并——所以每窗的候选与远端响应 id 都得按行留着。
    /// 合成一列 JSON 的话，重试就得先解出全部窗口再改写，写一半崩了
    /// 就分不清哪一窗真的处理过。
    static let schemaV7Delta = """
    CREATE TABLE IF NOT EXISTS minutes_window (
      id                TEXT PRIMARY KEY,
      minutes_id        TEXT NOT NULL REFERENCES minutes(id) ON DELETE CASCADE,
      window_index      INTEGER NOT NULL,
      owned_unit_ids    TEXT NOT NULL,
      context_unit_ids  TEXT NOT NULL,
      outcome           TEXT NOT NULL,
      failure_reason    TEXT,
      candidate_json    TEXT,
      remote_response_id TEXT,
      updated_at        REAL NOT NULL,
      UNIQUE (minutes_id, window_index)
    );
    CREATE INDEX IF NOT EXISTS minutes_window_by_minutes
      ON minutes_window(minutes_id, window_index);
    """

    private func migrateV6ToV7() throws {
        try execute(Self.schemaV7Delta)
        let columns = try withStatement("PRAGMA table_info(minutes);") { statement in
            var names: [String] = []
            while try step(statement) == SQLITE_ROW {
                if let name = columnText(statement, 1) { names.append(name) }
            }
            return names
        }
        // 不回填：v6 之前的纪要是单窗生成的，没有分窗账本可还原。
        // 补一份"全部覆盖"等于伪造一份从未发生过的窗口划分。
        if !columns.contains("coverage_json") {
            try execute("ALTER TABLE minutes ADD COLUMN coverage_json TEXT;")
        }
    }
}
