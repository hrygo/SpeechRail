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
    /// v8（MA-15）：`knowledge_fts` 全文索引 + `search_index_outbox`。
    /// 索引是**派生数据**：内容永远在权威表里，索引坏了重建即可。
    /// v10（MA-14）：`knowledge_execution_event` 双时间事件日志 + `knowledge_supersession`。
    /// v11（MA-11）：`minutes.body_origin` + `parent_minutes_id`——用户改纪要产生**新版本**。
    public static let schemaVersion: Int32 = 12

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
            // MA-15：打开时把待处理的索引项应用掉。内容保存与索引更新分开报状态，
            // 但**不能**永远分开——否则重启后旧内容仍然搜不到。
            // drain 失败不影响打开：索引是派生数据，检索会走词法回退并如实标降级。
            try? drainSearchIndex()
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
            if version < 8 {
                try migrateV7ToV8()
            }
            if version < 9 {
                try migrateV8ToV9()
            }
            if version < 10 {
                try migrateV9ToV10()
            }
            if version < 11 {
                try migrateV10ToV11()
            }
            if version < 12 {
                try migrateV11ToV12()
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
        // MA-15：内容保存与索引更新分开报状态——这里只排队，
        // 由 drainSearchIndex 真正写索引。崩溃也不会漏，因为 outbox 与内容同事务。
        if draft.status == .final {
            try enqueueSearchIndex(
                sessionID: draft.sessionID,
                sourceKind: SearchIndexOp.lineKind,
                sourceID: id
            )
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

    /// 把**对齐得到的**声学起止与质量一起写回一行（MA-02 / MC-15）。
    ///
    /// 与 `attachTimingQuality` 分开是有意的：只改标签不改值，正是方案
    /// 点名要修的那条路——标了 `aligned` 却仍然存着接收间隔，
    /// 等于把谎报盖了个"已校准"的章。三个字段在一条 UPDATE 里写，
    /// 不给"标签到了但值没到"留中间态。
    ///
    /// 正文、序号、归属、来源都不参与这次写入。
    public func attachAcousticTiming(
        lineID: String,
        start: TimeInterval,
        end: TimeInterval,
        quality: SessionTimingQuality
    ) throws {
        try withStatement(
            "UPDATE line SET t_start = ?, t_end = ?, timing_quality = ? WHERE id = ?;"
        ) { statement in
            bind(statement, 1, start)
            bind(statement, 2, end)
            bind(statement, 3, quality.rawValue)
            bind(statement, 4, lineID)
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

    /// 记一条**归属**修订（拆出用），只追加事件，不碰 `speaker_name`。
    ///
    /// 为什么不直接让 `attachSpeakerLabel` 写事件：那条方法同时是**实时对齐**
    /// 写归属的路径（对齐证据在文本 final 之后独立到达），在那里写会被每一次
    /// 对齐到达刷出一堆复核标记，把真正需要提示的那批淹掉。
    ///
    /// 所以归属修订由**用户动作**这一层来记——用户说"这几句不是他说的"，
    /// 是一次有意的更正，依赖旧归属的结论该被提示复核。
    public func noteSpeakerAttributionChange(sessionID: String, detail: String) throws {
        let sql = """
        INSERT INTO session_change (id, session_id, at_ordinal, kind, value, created_at)
        VALUES (?, ?, 0, 'speaker', ?, ?);
        """
        try withStatement(sql) { statement in
            bind(statement, 1, UUID().uuidString)
            bind(statement, 2, sessionID)
            bind(statement, 3, detail)
            bind(statement, 4, Date().timeIntervalSince1970)
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
        // 基准是**血缘起点**，不是本版的创建时间：改一版只是换了措辞，
        // 依据的仍是起点那版读到的来源。只比本版会把标记静默洗掉。
        let versions = try minutesVersions(sessionID: version.sessionID)
        let createdAtByID = Dictionary(
            uniqueKeysWithValues: versions.map { ($0.id, $0.createdAt) }
        )
        let parentByID = Dictionary(
            uniqueKeysWithValues: versions.map { ($0.id, $0.parentMinutesID) }
        )
        return MinutesReview.reviewID(
            createdAtByID: createdAtByID,
            parentID: { parentByID[$0] ?? nil },
            minutesID: minutesID,
            revisions: revisions.map(\.createdAt)
        ) != nil
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

    /// 按 id 合上**某一条**中断区间（MC-16 暂停用）。
    ///
    /// 为什么不用上面那个按会话合的：那条会把该会话**所有**未闭合区间一起合上。
    /// 用户暂停着、又出了故障时，两条区间叠在一起，恢复那一刻会把暂停的那段
    /// 也算成"录到了"，停记区间就不再等于用户实际按下的那段时间。
    /// 暂停必须自己能指出是哪一条。
    public func closeInterruption(id: String, resumedAt: Date = Date()) throws {
        let sql = """
        UPDATE session_interruption SET resumed_at = ?
        WHERE id = ? AND resumed_at IS NULL;
        """
        try withStatement(sql) { statement in
            bind(statement, 1, resumedAt.timeIntervalSince1970)
            bind(statement, 2, id)
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
        // 索引里现有的条目先记下来：它们要排进删除 outbox。**不能只删源行**——
        // `knowledge_fts` 是独立表，`DELETE FROM session` 带不走它，那段全文会
        // 继续躺在库里。检索之所以还搜不出来，是因为命中要过源行存在性那一关；
        // 但验收 4 说的是「删除内容不得被**索引**」，那说的是索引本身干不干净。
        let indexedEntries = try indexedSearchEntries(sessionID: id)
        try execute("BEGIN IMMEDIATE;")
        do {
            try withStatement("DELETE FROM session WHERE id = ?;") { statement in
                bind(statement, 1, id)
                try step(statement)
            }
            for (kind, sourceID) in indexedEntries {
                try enqueueSearchIndex(
                    op: SearchIndexOp.delete, sessionID: id, sourceKind: kind, sourceID: sourceID
                )
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        // drain 自己要开事务，不能嵌在上面那个里（SQLite 不支持嵌套事务）。
        _ = try? drainSearchIndex()
    }

    // MARK: - 纪要队列（§5.8：单飞 + 租约回收 + 失败给可读原因）

    /// `minutes` 的完整读列清单。**所有**读这一行的查询都用它，
    /// 因为 `minutesVersion(from:)` 按列序号取值：清单和映射对不上，
    /// 读出来的就是别人的字段——所以这里只留一份，不要再各写各的。
    private static let minutesSelectColumns = """
    id, session_id, version, status, body, model, prompt_chars, is_latest, is_accepted, \
    attempts, failure_reason, lease_until, created_at, is_legacy_import, \
    remote_response_id, config_snapshot, snapshot_id, cancel_requested_at, \
    candidate_json, review_json, coverage_json, body_origin, parent_minutes_id
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
        // 迟到的结果不许把已经归档/删除的会议写回来（MA-18 / MC-63）。
        if try rejectLateMinutesIfMeetingDeleted(minutesID: minutesID) { return false }
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
        // 同 finishMinutesIfOwner：先问这场会还在不在，再决定要不要落库。
        if try rejectLateMinutesIfMeetingDeleted(minutesID: minutesID) { return false }
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
            // MA-15：纪要定稿后排一次索引更新。正文改动（版本重生成）同样会被覆盖写。
            let minutesSessionID = try withStatement(
                "SELECT session_id FROM minutes WHERE id = ?;"
            ) { statement -> String? in
                bind(statement, 1, minutesID)
                guard try step(statement) == SQLITE_ROW else { return nil }
                return columnText(statement, 0)
            }
            try enqueueSearchIndex(
                sessionID: minutesSessionID,
                sourceKind: SearchIndexOp.minutesKind,
                sourceID: minutesID
            )
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
                        openInterruption: columnText(statement, 20).map(SessionInterruptionReason.init(reading:)),
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
    public func searchKnowledge(
        query: String,
        kind: SessionKind? = nil,
        limit: Int = 200,
        scope: MeetingKnowledgeScope = .standard
    ) throws -> [KnowledgeHit] {
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
        LEFT JOIN meeting_document d ON d.source_session_id = s.id
        WHERE l.status = 'final' AND l.text LIKE ? ESCAPE '\\'
        \(kind == nil ? "" : "AND s.kind = ?")
        \(Self.visibilityClause(scope: scope).sql)
        ORDER BY s.started_at DESC, l.ordinal ASC
        LIMIT ?;
        """
        let visibility = Self.visibilityClause(scope: scope)
        try withStatement(lineSQL) { statement in
            bind(statement, 1, pattern)
            var index: Int32 = 2
            if let kind {
                bind(statement, index, kind.rawValue)
                index += 1
            }
            for value in visibility.bindings {
                bindArgument(statement, index, value)
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
        LEFT JOIN meeting_document d ON d.source_session_id = s.id
        WHERE m.status = 'ready' AND m.body IS NOT NULL AND m.body LIKE ? ESCAPE '\\'
        \(kind == nil ? "" : "AND s.kind = ?")
        \(visibility.sql)
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
            for value in visibility.bindings {
                bindArgument(statement, index, value)
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
                let resumed = columnIsNull(statement, 4) ? nil : Date(timeIntervalSince1970: columnDouble(statement, 4))
                rows.append(
                    SessionInterruption(
                        id: columnText(statement, 0) ?? "",
                        sessionID: columnText(statement, 1) ?? sessionID,
                        atOrdinal: Int(columnInt(statement, 2)),
                        // 认不出的 reason 也留下：这一行代表一段没录上的时间，
                        // 丢掉它会让老程序把"原因不明"说成"全程录上了"。
                        reason: SessionInterruptionReason(reading: columnText(statement, 3)),
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

    /// 人工编辑会议文档的项目、标题与发生时间（MA-13）。
    ///
    /// **只有用户能改**：导入与生成都不猜项目归属——猜错了会把这场会
    /// 悄悄归进另一个项目，用户还得自己一条条找回来。
    /// 传 nil 表示"不改这一项"，与"改成空"不同：这里用显式可选包一层区分。
    public func updateMeetingDocument(
        id: String,
        title: String?? = nil,
        projectID: String?? = nil,
        occurredAt: Date?? = nil
    ) throws {
        guard var document = try meetingDocument(id: id) else {
            throw SessionStoreError.statementFailed("找不到这场会议知识文档")
        }
        if let title { document.title = title }
        if let projectID { document.projectID = projectID }
        if let occurredAt { document.occurredAt = occurredAt }
        document.updatedAt = Date()
        try withStatement("""
        UPDATE meeting_document
        SET title = ?, project_id = ?, occurred_at = ?, updated_at = ?
        WHERE id = ?;
        """) { statement in
            bind(statement, 1, document.title)
            bind(statement, 2, document.projectID)
            bind(statement, 3, document.occurredAt?.timeIntervalSince1970)
            bind(statement, 4, document.updatedAt.timeIntervalSince1970)
            bind(statement, 5, document.id)
            try step(statement)
        }
    }

    public func meetingDocument(id: String) throws -> MeetingDocument? {
        let sql = "SELECT id, source_session_id, title, project_id, occurred_at, timezone, deleted_at, deletion_mode, created_at, updated_at FROM meeting_document WHERE id = ? LIMIT 1;"
        return try withStatement(sql) { statement -> MeetingDocument? in
            bind(statement, 1, id)
            guard try step(statement) == SQLITE_ROW else { return nil }
            return meetingDocument(from: statement)
        }
    }

    public func meetingDocument(forSessionID sessionID: String) throws -> MeetingDocument? {
        let sql = "SELECT id, source_session_id, title, project_id, occurred_at, timezone, deleted_at, deletion_mode, created_at, updated_at FROM meeting_document WHERE source_session_id = ? LIMIT 1;"
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
            deletedAt: columnIsNull(statement, 6) ? nil : Date(timeIntervalSince1970: columnDouble(statement, 6 as Int32)),
            deletionMode: columnText(statement, 7).flatMap(MeetingDeletionMode.init(rawValue:)),
            createdAt: Date(timeIntervalSince1970: columnDouble(statement, 8)),
            updatedAt: Date(timeIntervalSince1970: columnDouble(statement, 9 as Int32))
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
            // MC-43：用户明确勾选要写进纪要的那几句私密问答，以 **AI 补充** 的身份
            // 跟着这份快照走。它们不是会上说的话，所以只进 `note_refs`，
            // 不混进行修订——混进去就等于把模型的话升级成会议事实。
            let supplements = try selectedSupplements(sessionID: sessionID)

            let snapshot = "snap-\(sessionID)-\(Self.stableDigest(revisionIDs + supplements.map(\.exchangeID)))"
            snapshotID = snapshot
            try withStatement("""
            INSERT OR IGNORE INTO source_snapshot
                (id, document_id, line_revision_ids, speaker_map_revision, note_refs, coverage, seal_result, created_at)
            VALUES (?, ?, ?, ?, ?, ?, 'ok', ?);
            """) { statement in
                bind(statement, 1, snapshot)
                bind(statement, 2, document)
                bind(statement, 3, revisionIDs.joined(separator: ","))
                bind(statement, 4, speakerRevision)
                bind(statement, 5, supplements.isEmpty ? "[]" : supplements.map(\.exchangeID).joined(separator: ","))
                // 没有补充时保持原来的写法不变：`final_lines=N` 是已有契约，
                // 多一个恒为 0 的字段只会让读它的人多问一句为什么。
                let coverage = supplements.isEmpty
                    ? "final_lines=\(revisionIDs.count)"
                    : "final_lines=\(revisionIDs.count),ai_supplements=\(supplements.count)"
                bind(statement, 6, coverage)
                bind(statement, 7, sealedAt.timeIntervalSince1970)
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

    /// 用户勾选要写进纪要的私密问答（MC-43）。**只取勾选过、且已经有答案的那些**：
    /// 勾了但还没生成出内容的不能进快照——快照里写一个空指针没有意义。
    private func selectedSupplements(sessionID: String) throws -> [MeetingSupplement] {
        try withStatement("""
        SELECT id, question, answer_text FROM inner_os_exchange
        WHERE session_id = ? AND in_minutes = 1 AND status = 'ready'
          AND answer_text IS NOT NULL AND TRIM(answer_text) <> ''
        ORDER BY asked_at ASC;
        """) { statement -> [MeetingSupplement] in
            bind(statement, 1, sessionID)
            var rows: [MeetingSupplement] = []
            while try step(statement) == SQLITE_ROW {
                rows.append(MeetingSupplement(
                    id: columnText(statement, 0) ?? "",
                    exchangeID: columnText(statement, 0) ?? "",
                    question: columnText(statement, 1) ?? "",
                    answerText: columnText(statement, 2) ?? ""
                ))
            }
            return rows
        }
    }

    /// 读一份快照里跟着走的 AI 补充（MC-43）。读不到就是没有，不补造。
    public func meetingSupplements(snapshotID: String) throws -> [MeetingSupplement] {
        guard let snapshot = try sourceSnapshot(id: snapshotID) else { return [] }
        let ids = snapshot.noteRefs.filter { $0 != "[]" }
        guard !ids.isEmpty else { return [] }
        var rows: [MeetingSupplement] = []
        for id in ids {
            let row = try withStatement("""
            SELECT id, question, answer_text FROM inner_os_exchange WHERE id = ? LIMIT 1;
            """) { statement -> MeetingSupplement? in
                bind(statement, 1, id)
                guard try step(statement) == SQLITE_ROW else { return nil }
                return MeetingSupplement(
                    id: columnText(statement, 0) ?? "",
                    exchangeID: columnText(statement, 0) ?? "",
                    question: columnText(statement, 1) ?? "",
                    answerText: columnText(statement, 2) ?? ""
                )
            }
            if let row { rows.append(row) }
        }
        return rows
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
                    editedAt: Date(timeIntervalSince1970: columnDouble(statement, 6 as Int32))
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
                        updatedAt: Date(timeIntervalSince1970: columnDouble(statement, 6 as Int32))
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


    // MARK: - 全文检索索引（MA-15 / §6.5）

    /// FTS5 能力预检。**预检要真建一次表**：只查编译宏在裁剪过的 SQLite 构建里
    /// 会骗人（系统库与自链接的编译选项不一定相同）。
    public static let fts5Available: Bool = {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db = pointer else {
            if let pointer { sqlite3_close_v2(pointer) }
            return false
        }
        defer { sqlite3_close_v2(db) }
        var error: UnsafeMutablePointer<CChar>?
        let ok = sqlite3_exec(db, "CREATE VIRTUAL TABLE temp.__fts_probe USING fts5(x);", nil, nil, &error)
        if let error { sqlite3_free(error) }
        return ok == SQLITE_OK
    }()

    enum SearchIndexOp {
        static let upsert = "upsert"
        static let delete = "delete"
        static let lineKind = "line"
        static let minutesKind = "minutes"
    }

    /// 检索索引状态。**保存与索引分开报**：内容写成功但索引还没跟上时，
    /// 这里必须看得出来，而不是让检索悄悄少一条（§6.5）。
    public struct SearchIndexStatus: Hashable, Sendable {
        /// FTS5 不可用时退到有界词法查询（明确标注降级，不假装是全文检索）。
        public var isFullTextAvailable: Bool
        /// 待应用的操作数。0 表示索引与内容一致。
        public var pendingCount: Int
        public var indexedCount: Int
        public var degradedReason: String?

        public var isCaughtUp: Bool { pendingCount == 0 }
    }

    /// 排一次索引更新。
    ///
    /// 放进 outbox 而不是直接写索引：内容保存与索引更新**分开报状态**，
    /// 中途失败也不会让「已保存」和「可检索」这两个事实对不上。
    private func enqueueSearchIndex(
        op: String = SearchIndexOp.upsert,
        sessionID: String?,
        sourceKind: String,
        sourceID: String
    ) throws {
        guard Self.fts5Available else { return }
        try withStatement("""
        INSERT INTO search_index_outbox (op, session_id, source_kind, source_id)
        VALUES (?, ?, ?, ?);
        """) { statement in
            bind(statement, 1, op)
            bind(statement, 2, sessionID)
            bind(statement, 3, sourceKind)
            bind(statement, 4, sourceID)
            try step(statement)
        }
    }

    /// 应用待处理的索引操作，按 (kind, id) 幂等覆盖。
    ///
    /// 先 delete 再 insert 而不是 `INSERT OR REPLACE`：虚拟表的 replace 语义
    /// 在不同 FTS5 构建上并不一致，显式两步在所有构建上行为相同。
    @discardableResult
    public func drainSearchIndex(limit: Int = 500) throws -> Int {
        guard Self.fts5Available else { return 0 }
        let pending: [(rowid: Int64, op: String, kind: String, id: String)] =
            try withStatement("""
            SELECT rowid, op, source_kind, source_id FROM search_index_outbox
            ORDER BY rowid ASC LIMIT ?;
            """) { statement in
                bind(statement, 1, limit)
                var rows: [(Int64, String, String, String)] = []
                while try step(statement) == SQLITE_ROW {
                    rows.append((
                        sqlite3_column_int64(statement, 0),
                        columnText(statement, 1) ?? SearchIndexOp.upsert,
                        columnText(statement, 2) ?? "",
                        columnText(statement, 3) ?? ""
                    ))
                }
                return rows
            }
        guard !pending.isEmpty else { return 0 }

        try execute("BEGIN IMMEDIATE;")
        do {
            for row in pending {
                try withStatement(
                    "DELETE FROM knowledge_fts WHERE source_kind = ? AND source_id = ?;"
                ) { statement in
                    bind(statement, 1, row.kind)
                    bind(statement, 2, row.id)
                    try step(statement)
                }
                try withStatement("DELETE FROM search_index_outbox WHERE rowid = ?;") { statement in
                    bind(statement, 1, Int(row.rowid))
                    try step(statement)
                }
                guard row.op != SearchIndexOp.delete else { continue }
                guard let document = try searchDocument(kind: row.kind, sourceID: row.id) else { continue }
                try withStatement("""
                INSERT INTO knowledge_fts
                    (body, session_id, kind, source_kind, source_id, version, ordinal, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """) { statement in
                    bind(statement, 1, document.body)
                    bind(statement, 2, document.sessionID)
                    bind(statement, 3, document.kind)
                    bind(statement, 4, row.kind)
                    bind(statement, 5, row.id)
                    bind(statement, 6, document.version)
                    bind(statement, 7, document.ordinal)
                    bind(statement, 8, document.createdAt.timeIntervalSince1970)
                    try step(statement)
                }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        return pending.count
    }

    /// 一条待写入索引的文档。字段与 FTS5 表的 UNINDEXED 列一一对应。
    private struct SearchDocument {
        var body: String
        var sessionID: String
        /// FTS5 的 UNINDEXED 列存原始字符串，不存枚举本身。
        var kind: String?
        var version: Int?
        var ordinal: Int?
        var createdAt: Date
    }

    /// 从**权威表**读出该索引文档。索引里没有的东西一律不认。
    private func searchDocument(kind: String, sourceID: String) throws -> SearchDocument? {
        switch kind {
        case SearchIndexOp.lineKind:
            let sql = """
            SELECT l.text, l.session_id, s.kind, NULL, l.ordinal, l.created_at
            FROM line l JOIN session s ON s.id = l.session_id
            WHERE l.id = ? AND l.status = 'final';
            """
            return try withStatement(sql) { statement in
                bind(statement, 1, sourceID)
                guard try step(statement) == SQLITE_ROW else { return nil }
                return SearchDocument(
                    body: KnowledgeSearchTokenizer.indexDocument(for: columnText(statement, 0) ?? ""),
                    sessionID: columnText(statement, 1) ?? "",
                    kind: columnText(statement, 2),
                    version: nil,
                    ordinal: Int(columnInt(statement, 4)),
                    createdAt: Date(timeIntervalSince1970: columnDouble(statement, 5))
                )
            }
        case SearchIndexOp.minutesKind:
            let sql = """
            SELECT m.body, m.session_id, s.kind, m.version, NULL, m.created_at
            FROM minutes m JOIN session s ON s.id = m.session_id
            WHERE m.id = ? AND m.status = 'ready' AND m.body IS NOT NULL;
            """
            return try withStatement(sql) { statement in
                bind(statement, 1, sourceID)
                guard try step(statement) == SQLITE_ROW else { return nil }
                return SearchDocument(
                    body: KnowledgeSearchTokenizer.indexDocument(for: columnText(statement, 0) ?? ""),
                    sessionID: columnText(statement, 1) ?? "",
                    kind: columnText(statement, 2),
                    version: Int(columnInt(statement, 3)),
                    ordinal: nil,
                    createdAt: Date(timeIntervalSince1970: columnDouble(statement, 5))
                )
            }
        default:
            return nil
        }
    }

    /// 索引当前状态。
    public func searchIndexStatus() throws -> SearchIndexStatus {
        guard Self.fts5Available else {
            return SearchIndexStatus(
                isFullTextAvailable: false,
                pendingCount: 0,
                indexedCount: 0,
                degradedReason: "这个 SQLite 没有 FTS5，已退到有界词法查询"
            )
        }
        return SearchIndexStatus(
            isFullTextAvailable: true,
            pendingCount: try scalarInt("SELECT COUNT(*) FROM search_index_outbox;") ?? 0,
            indexedCount: try scalarInt("SELECT COUNT(*) FROM knowledge_fts;") ?? 0,
            degradedReason: nil
        )
    }

    /// 重建整个索引（MC-62「索引损坏不丢内容」）。
    ///
    /// 索引是**派生数据**：内容永远在权威表里。索引坏了或对不上时重建即可，
    /// **不需要**也不允许从索引反推内容。
    @discardableResult
    public func rebuildSearchIndex() throws -> Int {
        guard Self.fts5Available else { return 0 }
        try execute("BEGIN IMMEDIATE;")
        do {
            try execute("DELETE FROM knowledge_fts;")
            try execute("DELETE FROM search_index_outbox;")
            try execute("""
            INSERT INTO search_index_outbox (op, session_id, source_kind, source_id)
            SELECT 'upsert', l.session_id, 'line', l.id FROM line l WHERE l.status = 'final';
            """)
            try execute("""
            INSERT INTO search_index_outbox (op, session_id, source_kind, source_id)
            SELECT 'upsert', session_id, 'minutes', id FROM minutes
            WHERE status = 'ready' AND body IS NOT NULL;
            """)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        return try drainSearchIndex(limit: 200_000)
    }

    /// 一条命中的检索结果，附带排序用的元信息。
    private struct SearchRow {
        var hit: KnowledgeHit
        var isLine: Bool
        var isAccepted: Bool
        var version: Int
    }

    /// 全文检索（MA-15）。
    ///
    /// 三条硬口径：
    /// 1. **结果回到权威表核对**：索引命中但 `line`/`minutes` 已经没有的，
    ///    一律不给——索引迟到不能把删掉的内容复活（MC-62）。
    /// 2. **当前采用版优先去重**：同一场会议多版纪要时采用版优先、其次版本号大的，
    ///    同场只出一条，不让新旧版本刷屏（§6.5）。
    /// 3. 索引不可用或查询没有有效词项时**明确回退**到有界词法查询，
    ///    并在返回值里说清走的是哪条路。
    public func searchKnowledgeFullText(
        query: String,
        kind: SessionKind? = nil,
        limit: Int = 200,
        scope: MeetingKnowledgeScope = .standard
    ) throws -> KnowledgeSearchResults {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return KnowledgeSearchResults(hits: [], usedFullText: Self.fts5Available, degradedReason: nil)
        }
        guard Self.fts5Available, let match = KnowledgeSearchTokenizer.matchExpression(for: query) else {
            return KnowledgeSearchResults(
                hits: try searchKnowledge(query: query, kind: kind, limit: limit, scope: scope),
                usedFullText: false,
                degradedReason: Self.fts5Available
                    ? "查询里没有可检索的词，已回退到词法查询"
                    : "这个 SQLite 没有 FTS5，已回退到词法查询"
            )
        }

        var rows: [SearchRow] = []
        let visibility = Self.visibilityClause(scope: scope)
        let sql = """
        SELECT f.session_id, f.kind, f.source_kind, f.source_id, f.version, f.ordinal, f.created_at,
               l.text, m.body, m.is_accepted
        FROM knowledge_fts f
        JOIN session s ON s.id = f.session_id
        LEFT JOIN line l ON f.source_kind = 'line' AND l.id = f.source_id
        LEFT JOIN minutes m ON f.source_kind = 'minutes' AND m.id = f.source_id
        LEFT JOIN meeting_document d ON d.source_session_id = s.id
        WHERE knowledge_fts MATCH ?
          AND (f.source_kind <> 'line' OR (l.id IS NOT NULL AND l.status = 'final'))
          AND (f.source_kind <> 'minutes' OR (m.id IS NOT NULL AND m.status = 'ready'))
          \(kind == nil ? "" : "AND f.kind = ?")
          \(visibility.sql)
        ORDER BY s.started_at DESC, f.created_at DESC;
        """
        try withStatement(sql) { statement in
            bind(statement, 1, match)
            var index: Int32 = 2
            if let kind {
                bind(statement, index, kind.rawValue)
                index += 1
            }
            for value in visibility.bindings {
                bindArgument(statement, index, value)
                index += 1
            }
            while try step(statement) == SQLITE_ROW {
                let sourceKind = columnText(statement, 2) ?? ""
                let body = sourceKind == SearchIndexOp.lineKind
                    ? columnText(statement, 7)
                    : columnText(statement, 8)
                guard let body, !body.isEmpty else { continue }
                let sourceID = columnText(statement, 3) ?? ""
                let version = columnIsNull(statement, 4) ? 0 : Int(columnInt(statement, 4))
                rows.append(SearchRow(
                    hit: KnowledgeHit(
                        sessionID: columnText(statement, 0) ?? "",
                        kind: columnText(statement, 1).flatMap { SessionKind(rawValue: $0) },
                        lineID: sourceKind == SearchIndexOp.lineKind ? sourceID : nil,
                        minutesID: sourceKind == SearchIndexOp.minutesKind ? sourceID : nil,
                        version: sourceKind == SearchIndexOp.minutesKind ? version : nil,
                        excerpt: body,
                        ordinal: columnIsNull(statement, 5) ? nil : Int(columnInt(statement, 5)),
                        createdAt: Date(timeIntervalSince1970: columnDouble(statement, 6 as Int32))
                    ),
                    isLine: sourceKind == SearchIndexOp.lineKind,
                    isAccepted: columnInt(statement, 9) != 0,
                    version: version
                ))
            }
        }

        // 同场多版只留一条：采用版优先，其次版本号大的。
        var bestBySession: [String: Int] = [:]
        for (position, row) in rows.enumerated() where !row.isLine {
            guard let current = bestBySession[row.hit.sessionID] else {
                bestBySession[row.hit.sessionID] = position
                continue
            }
            let existing = rows[current]
            let better = (row.isAccepted && !existing.isAccepted)
                || (row.isAccepted == existing.isAccepted && row.version > existing.version)
            if better { bestBySession[row.hit.sessionID] = position }
        }
        let bestPositions = Set(bestBySession.values)
        let hits = rows.enumerated()
            .filter { position, row in row.isLine || bestPositions.contains(position) }
            .map(\.element.hit)
        return KnowledgeSearchResults(
            hits: hits.count > limit ? Array(hits.prefix(limit)) : hits,
            usedFullText: true,
            degradedReason: nil
        )
    }

    /// 检索结果 + 走了哪条路。降级必须**对调用方可见**（§6.5）。
    public struct KnowledgeSearchResults: Sendable {
        public var hits: [KnowledgeHit]
        public var usedFullText: Bool
        public var degradedReason: String?
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
            endedAt: columnIsNull(statement, 6) ? nil : Date(timeIntervalSince1970: columnDouble(statement, 6 as Int32)),
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
            tStart: columnIsNull(statement, 6) ? nil : columnDouble(statement, 6 as Int32),
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
            leaseUntil: columnIsNull(statement, 11) ? nil : Date(timeIntervalSince1970: columnDouble(statement, 11 as Int32)),
            createdAt: Date(timeIntervalSince1970: columnDouble(statement, 12)),
            isLegacyImport: legacy,
            bodyOrigin: count > 21
                ? (MinutesBodyOrigin(rawValue: columnText(statement, 21) ?? "") ?? .ai)
                : .ai,
            parentMinutesID: count > 22 ? columnText(statement, 22) : nil,
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

/// 可空的时间列。**NULL 必须读成 nil，不能读成 0**——`valid_to = 0`
/// 的意思是"1970 年就失效了"，把"还没失效"写成这个是在编造事实。
private func columnDoubleOrNil(_ statement: OpaquePointer, _ index: Int32) -> Double? {
    guard !columnIsNull(statement, index) else { return nil }
    return sqlite3_column_double(statement, index)
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

    /// v8 → v9 的 DDL（MA-13）：项目与标签。
    ///
    /// 项目**按 id 认，不按名字认**：同名项目是允许存在的两个项目，
    /// 按名字归一就会把它们混成一份统计与筛选（MC-51）。
    /// 所以 `name` 上不建唯一索引。
    static let schemaV9Delta = """
    CREATE TABLE IF NOT EXISTS meeting_project (
      id         TEXT PRIMARY KEY,
      name       TEXT NOT NULL,
      created_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS meeting_project_by_name ON meeting_project(name);

    CREATE TABLE IF NOT EXISTS meeting_document_tag (
      document_id TEXT NOT NULL REFERENCES meeting_document(id) ON DELETE CASCADE,
      tag         TEXT NOT NULL,
      PRIMARY KEY (document_id, tag)
    );
    CREATE INDEX IF NOT EXISTS meeting_document_tag_by_tag ON meeting_document_tag(tag);
    """

    /// v8 → v9：只建结构，不回填。项目与标签都是**用户自己写的**，
    /// 迁移时猜出来的归属比没有归属更糟（MA-13）。
    private func migrateV8ToV9() throws {
        try execute(Self.schemaV9Delta)
    }

    /// v9 → v10 的 DDL（MA-14）：执行状态事件日志与跨会议替代关系。
    ///
    /// 执行状态**不在 `minutes_item` 上**。纪要每次重新生成都会写出新的一版条目，
    /// 状态写在条目上就会被新版本重置——已完成的任务会自己复活（MC-53）。
    /// 所以状态按**稳定 key**存在这张表里，重新生成不动它。
    ///
    /// 双时间：`valid_from` 是"这件事从什么时候开始这样"（有效时间），
    /// `recorded_at` 是"我们什么时候知道的"（记入时间）。期限改了也不改历史承诺，
    /// 因为旧事件仍然在日志里，按有效时间能读回当时承诺的是什么（MC-59）。
    static let schemaV10Delta = """
    CREATE TABLE IF NOT EXISTS knowledge_execution_event (
      id             TEXT PRIMARY KEY,
      item_key       TEXT NOT NULL,
      document_id    TEXT,
      item_id        TEXT,
      kind           TEXT NOT NULL,
      status         TEXT NOT NULL,
      owner_text     TEXT,
      due_text       TEXT,
      due_date       REAL,
      valid_from     REAL NOT NULL,
      recorded_at    REAL NOT NULL,
      valid_to       REAL,
      note           TEXT
    );
    CREATE INDEX IF NOT EXISTS knowledge_execution_event_by_key
      ON knowledge_execution_event(item_key, valid_from);
    CREATE INDEX IF NOT EXISTS knowledge_execution_event_by_item
      ON knowledge_execution_event(item_id);

    CREATE TABLE IF NOT EXISTS knowledge_supersession (
      id                TEXT PRIMARY KEY,
      from_key          TEXT NOT NULL,
      to_key            TEXT NOT NULL,
      kind              TEXT NOT NULL,
      basis             TEXT NOT NULL,
      evidence_item_ids TEXT NOT NULL DEFAULT '[]',
      created_at        REAL NOT NULL,
      UNIQUE (from_key, to_key)
    );
    CREATE INDEX IF NOT EXISTS knowledge_supersession_by_from
      ON knowledge_supersession(from_key);
    CREATE INDEX IF NOT EXISTS knowledge_supersession_by_to
      ON knowledge_supersession(to_key);
    """

    /// v9 → v10：只建结构，不回填、不推断。
    ///
    /// 既有条目**一律当作"未处理"**——不猜哪条其实已经做完了。
    /// 猜出来的完成状态会直接毁掉用户对这份清单的信任。
    private func migrateV9ToV10() throws {
        try execute(Self.schemaV10Delta)
    }

    /// v10 → v11 的索引部分（MA-11）。两列由 `migrateV10ToV11` 逐列判存在后追加。
    ///
    /// **用户改纪要产生新版本，不覆盖旧版。** 覆盖写会让"AI 原来写了什么"
    /// 永远查不到，撤销也就无从谈起（MC-47、MC-48）。
    /// `body_origin` 记正文到底出自谁：AI 写的、用户改的、还是用户补的。
    static let schemaV11Delta = """
    CREATE INDEX IF NOT EXISTS minutes_by_parent ON minutes(parent_minutes_id);
    """

    /// `minutes` 当前有哪些列。SQLite 的 `ALTER TABLE ADD COLUMN` **没有**
    /// `IF NOT EXISTS`，列已存在会直接报 `duplicate column name`，迁移因此不幂等——
    /// 测试把 `user_version` 拨回去重跑迁移时就会炸。
    private func minutesColumnNames() throws -> Set<String> {
        try tableColumnNames("minutes")
    }

    /// v10 → v11：只加列，不回填。
    ///
    /// 既有正文一律标 `'ai'`——它们确实都是模型写出来的。
    /// 标错来源比没有来源更糟：界面会拿它去解释"这句为什么在这里"。
    private func migrateV10ToV11() throws {
        let columns = try minutesColumnNames()
        if !columns.contains("body_origin") {
            try execute("ALTER TABLE minutes ADD COLUMN body_origin TEXT NOT NULL DEFAULT 'ai';")
        }
        if !columns.contains("parent_minutes_id") {
            try execute("ALTER TABLE minutes ADD COLUMN parent_minutes_id TEXT;")
        }
        try execute(Self.schemaV11Delta)
    }

    /// v11 → v12：给 `meeting_document` 补一列删除档位。
    ///
    /// 此前 `deleted_at` 把三档删除压成同一个状态，于是 `MeetingLibraryStatus.archived`
    /// 永远不会被产出——「撤销归档」那个出口在界面上从来没出现过。
    ///
    /// **刻意不回填**：老行是迁移前写的，哪一档删除无从得知，
    /// 而猜错的方向恰好是危险的那个（对内容已不在的文档谎称可恢复）。
    /// 空值一律按"不可撤销"处理，代价只是老文档少一个出口。
    private func migrateV11ToV12() throws {
        let columns = try tableColumnNames("meeting_document")
        if !columns.contains("deletion_mode") {
            try execute("ALTER TABLE meeting_document ADD COLUMN deletion_mode TEXT;")
        }
    }

    private func tableColumnNames(_ table: String) throws -> Set<String> {
        try withStatement("PRAGMA table_info(\(table));") { statement in
            var names: Set<String> = []
            while try step(statement) == SQLITE_ROW {
                if let name = columnText(statement, 1) { names.insert(name) }
            }
            return names
        }
    }

    /// v7 → v8 的 DDL（MA-15）：FTS5 全文索引与事务 outbox。
    ///
    /// 索引与 outbox 分开：outbox 随业务事务一起提交，保证「内容已保存」
    /// 与「索引待更新」两个事实不会互相矛盾。迁移只建结构并回填待办，
    /// 真正的索引写入由打开后的首次 drain 完成。
    static let schemaV8Delta = """
    CREATE TABLE IF NOT EXISTS search_index_outbox (
      rowid        INTEGER PRIMARY KEY AUTOINCREMENT,
      op           TEXT NOT NULL,
      session_id   TEXT,
      source_kind  TEXT NOT NULL,
      source_id    TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS search_index_outbox_by_source
      ON search_index_outbox(source_kind, source_id);
    """

    private func migrateV7ToV8() throws {
        try execute(Self.schemaV8Delta)
        guard Self.fts5Available else {
            // 没有 FTS5 就只留 outbox 结构：检索走有界词法回退，
            // 降级状态由 searchIndexStatus 如实报出。
            return
        }
        try execute(Self.schemaV8FTS)
        // 回填待处理项而不是直接写索引：让「旧内容也要被检索到」这件事
        // 走和新建内容一样的路径，不留下两套行为。
        try execute("""
        INSERT INTO search_index_outbox (op, session_id, source_kind, source_id)
        SELECT 'upsert', l.session_id, 'line', l.id FROM line l WHERE l.status = 'final';
        """)
        try execute("""
        INSERT INTO search_index_outbox (op, session_id, source_kind, source_id)
        SELECT 'upsert', session_id, 'minutes', id FROM minutes
        WHERE status = 'ready' AND body IS NOT NULL;
        """)
    }

    /// FTS5 虚表。索引列存的是**分词结果**（空格分隔的词项），
    /// 原文另有出处——这样 `unicode61` 切不对中文的问题在上游就解决了。
    static let schemaV8FTS = """
    CREATE VIRTUAL TABLE IF NOT EXISTS knowledge_fts USING fts5(
      body,
      session_id UNINDEXED,
      kind UNINDEXED,
      source_kind UNINDEXED,
      source_id UNINDEXED,
      version UNINDEXED,
      ordinal UNINDEXED,
      created_at UNINDEXED,
      tokenize = 'unicode61 remove_diacritics 2'
    );
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

// MARK: - 知识归档包：导出与导入（MA-19 / MC-48、MC-65、MC-66、MC-71）
//
// 导出与导入都走**库内原 id**，不做任何重新编号：跨新库往返之后，
// 版本、来源与行动身份必须还是原来那几个（MC-66）。重新编号的"干净"导出
// 会让用户手上已有的引用、已分享出去的链接全部指空。
extension SessionStore {
    /// 按选定范围组装归档包。**不写文件**——组装失败时磁盘上什么都没有（MC-65）。
    ///
    /// `minutesID` 就是选中的那一版，全程按它取。库里即使已经有 v3，
    /// 这里也不会改导 v3；找不到这一版直接失败，不退回"当前展示版"（MC-48）。
    public func knowledgeArchivePayload(
        selection: KnowledgeArchiveSelection
    ) throws -> KnowledgeArchivePayload {
        guard let document = try meetingDocument(id: selection.documentID) else {
            throw KnowledgeArchiveError.documentNotFound(selection.documentID)
        }
        guard let selected = try minutesVersion(id: selection.minutesID) else {
            throw KnowledgeArchiveError.minutesNotFound(selection.minutesID)
        }
        guard let body = selected.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KnowledgeArchiveError.minutesBodyMissing(selection.minutesID)
        }

        // 分享包只装这一版；完整归档装这场会的全部版本。
        let includedVersions: [MinutesVersion]
        switch selection.scope {
        case .share:
            includedVersions = [selected]
        case .fullArchive:
            includedVersions = try minutesVersions(sessionID: selected.sessionID)
                .sorted { $0.version < $1.version }
        }

        // 执行状态挂在 `KnowledgeIdentity.key(documentID:kind:text:)` 上，
        // 所以这里必须先拿到这份文档自己的 id——条目本身不存它。
        let archiveDocumentID = try meetingDocument(forSessionID: selected.sessionID)?.id
            ?? selection.documentID

        var items: [ArchiveItem] = []
        var anchorLineIDs: Set<String> = []
        var anchorRevisionIDs: Set<String> = []
        for version in includedVersions {
            for item in try minutesItems(minutesID: version.id) {
                items.append(ArchiveItem(
                    id: item.id,
                    minutesID: item.minutesID,
                    localID: item.localID,
                    kind: item.kind,
                    text: item.text,
                    verdict: item.verdict?.rawValue,
                    sortOrder: item.sortOrder,
                    itemKey: KnowledgeIdentity.key(
                        documentID: archiveDocumentID,
                        kind: item.kind,
                        text: item.text
                    ),
                    anchors: item.anchors.map { anchor in
                        if let lineID = anchor.lineID { anchorLineIDs.insert(lineID) }
                        if let revisionID = anchor.revisionID { anchorRevisionIDs.insert(revisionID) }
                        return ArchiveAnchor(
                            id: anchor.id,
                            itemID: anchor.itemID,
                            unitID: anchor.unitID,
                            lineID: anchor.lineID,
                            revisionID: anchor.revisionID,
                            snapshotID: anchor.snapshotID,
                            speakerLabel: anchor.speakerLabel,
                            startSeconds: anchor.startSeconds,
                            quote: anchor.quote,
                            verification: anchor.verification
                        )
                    }
                ))
            }
        }

        // 完整归档带整场转录与全部修订；分享包只带锚点真正引用到的那几行。
        let allLines = try lines(sessionID: selected.sessionID, includePartial: true)
            .sorted { $0.ordinal < $1.ordinal }
        var archiveLines = allLines
        if selection.scope == .share {
            archiveLines = allLines.filter { anchorLineIDs.contains($0.id) }
        }

        var archiveRevisions: [TranscriptRevision] = []
        var snapshots: [MeetingSourceSnapshot] = []
        switch selection.scope {
        case .share:
            archiveRevisions = try revisions(includingParentsOf: anchorRevisionIDs)
            if let snapshotID = selected.snapshotID, let snapshot = try sourceSnapshot(id: snapshotID) {
                snapshots = [snapshot]
            }
        case .fullArchive:
            archiveRevisions = try withStatement("""
            SELECT id, line_id, session_id, text, origin, parent_revision_id, edited_at
            FROM transcript_revision WHERE session_id = ? ORDER BY edited_at ASC;
            """) { statement -> [TranscriptRevision] in
                bind(statement, 1, selected.sessionID)
                var rows: [TranscriptRevision] = []
                while try step(statement) == SQLITE_ROW {
                    rows.append(transcriptRevision(from: statement))
                }
                return rows
            }
            snapshots = try allArchiveSnapshots(documentID: document.id)
        }
        let lineIDsInPackage = Set(archiveLines.map(\.id))
        // 分享包只带被引用的那几行修订；父修订如果落在包外，就不让它把链断在这里——
        // 断链的修订在包里没有意义，带上父 id 反而会指向不存在的东西。
        archiveRevisions = archiveRevisions.filter { lineIDsInPackage.contains($0.lineID) }

        var windowModels: [ArchiveWindow] = []
        if selection.scope == .fullArchive {
            for version in includedVersions {
                windowModels.append(contentsOf: try minutesWindows(minutesID: version.id).map { $0.archiveModel(minutesID: version.id) })
            }
        }

        var sessionModel: ArchiveSession?
        if let record = try session(id: selected.sessionID) {
            sessionModel = record.archiveModel
        }

        return KnowledgeArchivePayload(
            document: document.archiveModel,
            session: sessionModel,
            lines: archiveLines.map(\.archiveModel),
            speakerNames: try speakerNames(sessionID: selected.sessionID),
            snapshots: snapshots.map(\.archiveModel),
            revisions: archiveRevisions.map(\.archiveModel),
            minutes: includedVersions.map(\.archiveModel),
            items: items,
            windows: windowModels,
            execution: try knowledgeExecutionEvents(documentID: document.id),
            supersessions: try knowledgeSupersessions(documentID: document.id)
        )
    }

    /// 执行状态事件（归档用）。按文档取，双时间日志**整条带走**：
    /// 只带走当前有效的那一条，等于把"曾经改过又改回来"的历史抹掉。
    public func knowledgeExecutionEvents(documentID: String) throws -> [ArchiveExecutionEvent] {
        try withStatement("""
        SELECT id, item_key, document_id, item_id, kind, status, owner_text, due_text, due_date,
               valid_from, recorded_at, valid_to, note
        FROM knowledge_execution_event
        WHERE document_id = ? OR item_key IN (
            SELECT DISTINCT e.item_key FROM knowledge_execution_event e
            JOIN minutes_item i ON i.id = e.item_id
            JOIN minutes v ON v.id = i.minutes_id
            WHERE v.session_id = (SELECT source_session_id FROM meeting_document WHERE id = ?)
        )
        ORDER BY valid_from ASC, recorded_at ASC;
        """) { statement in
            bind(statement, 1, documentID)
            bind(statement, 2, documentID)
            var rows: [ArchiveExecutionEvent] = []
            while try step(statement) == SQLITE_ROW {
                rows.append(ArchiveExecutionEvent(
                    id: columnText(statement, 0) ?? "",
                    itemKey: columnText(statement, 1) ?? "",
                    documentID: columnText(statement, 2),
                    itemID: columnText(statement, 3),
                    kind: columnText(statement, 4) ?? "",
                    status: columnText(statement, 5) ?? "",
                    ownerText: columnText(statement, 6),
                    dueText: columnText(statement, 7),
                    dueDate: columnDoubleOrNil(statement, 8 as Int32),
                    validFrom: columnDouble(statement, 9 as Int32) ?? 0,
                    recordedAt: columnDouble(statement, 10 as Int32) ?? 0,
                    validTo: columnDoubleOrNil(statement, 11 as Int32),
                    note: columnText(statement, 12)
                ))
            }
            return rows
        }
    }

    /// 决策替代关系（归档用）。
    public func knowledgeSupersessions(documentID: String) throws -> [ArchiveSupersession] {
        let keys = try knowledgeItemKeys(documentID: documentID)
        guard !keys.isEmpty else { return [] }
        let ph = Array(repeating: "?", count: keys.count).joined(separator: ", ")
        return try withStatement("""
        SELECT id, from_key, to_key, kind, basis, evidence_item_ids, created_at
        FROM knowledge_supersession
        WHERE from_key IN (\(ph)) OR to_key IN (\(ph))
        ORDER BY created_at ASC;
        """) { statement in
            var index: Int32 = 1
            for key in keys { bind(statement, index, key); index += 1 }
            for key in keys { bind(statement, index, key); index += 1 }
            var rows: [ArchiveSupersession] = []
            while try step(statement) == SQLITE_ROW {
                let raw = columnText(statement, 5) ?? "[]"
                let ids = (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? []
                rows.append(ArchiveSupersession(
                    id: columnText(statement, 0) ?? "",
                    fromKey: columnText(statement, 1) ?? "",
                    toKey: columnText(statement, 2) ?? "",
                    kind: columnText(statement, 3) ?? "",
                    basis: columnText(statement, 4) ?? "",
                    evidenceItemIDs: ids,
                    createdAt: columnDouble(statement, 6 as Int32) ?? 0
                ))
            }
            return rows
        }
    }

    /// 这一份文档下所有条目的稳定 key（`KnowledgeIdentity.key`）。
    private func knowledgeItemKeys(documentID: String) throws -> Set<String> {
        let versions = try minutesVersions(sessionID: documentID)
        guard !versions.isEmpty else { return [] }
        var keys: Set<String> = []
        for version in versions {
            for item in try minutesItems(minutesID: version.id) {
                keys.insert(
                    KnowledgeIdentity.key(documentID: documentID, kind: item.kind, text: item.text)
                )
            }
        }
        return keys
    }

    /// 归档包清单。计数按实际装进去的东西算，不是按库里有多少——
    /// 清单说 12 条、包里只有 3 条，导入端核对时立刻就知道对不上。
    public func knowledgeArchiveManifest(
        selection: KnowledgeArchiveSelection,
        payload: KnowledgeArchivePayload
    ) throws -> KnowledgeArchiveManifest {
        guard let document = try meetingDocument(id: selection.documentID) else {
            throw KnowledgeArchiveError.documentNotFound(selection.documentID)
        }
        guard let selected = try minutesVersion(id: selection.minutesID) else {
            throw KnowledgeArchiveError.minutesNotFound(selection.minutesID)
        }
        let accepted = try acceptedMinutes(sessionID: selected.sessionID)
        return KnowledgeArchiveManifest(
            scope: selection.scope,
            documentID: document.id,
            documentTitle: document.title,
            sessionID: document.sourceSessionID,
            selectedMinutesID: selected.id,
            selectedVersion: selected.version,
            acceptedMinutesID: accepted?.id,
            sourceSchemaVersion: Int(Self.schemaVersion),
            counts: KnowledgeArchiveCounts(
                sessions: payload.session == nil ? 0 : 1,
                lines: payload.lines.count,
                speakerNames: payload.speakerNames.count,
                documents: 1,
                snapshots: payload.snapshots.count,
                revisions: payload.revisions.count,
                minutes: payload.minutes.count,
                items: payload.items.count,
                anchors: payload.items.reduce(0) { $0 + $1.anchors.count },
                windows: payload.windows.count,
                executionEvents: payload.execution.count,
                supersessions: payload.supersessions.count
            ),
            files: []
        )
    }

    /// 按选定范围导出成一个包目录。**读失败就不产出任何文件**（MC-65）：
    /// 组装与校验都在内存里做完，写盘是最后一步。
    @discardableResult
    public func exportKnowledgeArchive(
        selection: KnowledgeArchiveSelection,
        to directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let payload = try knowledgeArchivePayload(selection: selection)
        let manifest = try knowledgeArchiveManifest(selection: selection, payload: payload)
        let markdown = KnowledgeArchiveMarkdown.render(manifest: manifest, payload: payload)
        return try KnowledgeArchiveFileIO.write(
            manifest: manifest,
            payload: payload,
            markdown: markdown,
            to: directory,
            fileManager: fileManager
        )
    }

    // MARK: - 导入

    /// 导入预检（MC-71）：读包、校验、比对现有库，**只读不写**。
    ///
    /// 冲突分两种，这里必须分开报：同 ID 同内容是可以跳过的重复，
    /// 同 ID 异内容才是冲突。前者静默跳过没问题，后者静默跳过就等于丢用户数据。
    public func previewKnowledgeArchive(
        at packageURL: URL,
        fileManager: FileManager = .default,
        limits: KnowledgeArchiveFileIO.Limits = .standard
    ) throws -> KnowledgeArchivePreview {
        let read = try KnowledgeArchiveFileIO.readPackage(
            at: packageURL,
            fileManager: fileManager,
            limits: limits
        )
        let (conflicts, newCount) = try diffAgainstStore(read.payload)
        return KnowledgeArchivePreview(
            manifest: read.manifest,
            conflicts: conflicts,
            newObjectCount: newCount
        )
    }

    /// 导入一个包到**当前库**。全程一个事务：任何一步失败整批回滚，
    /// 当前库在任何失败路径下都不变（MA-19 回退条款）。
    ///
    /// 有真冲突时直接拒绝并要求先看预检——不允许"能插几条插几条"。
    @discardableResult
    public func importKnowledgeArchive(
        at packageURL: URL,
        fileManager: FileManager = .default,
        limits: KnowledgeArchiveFileIO.Limits = .standard
    ) throws -> KnowledgeArchiveImportResult {
        let read = try KnowledgeArchiveFileIO.readPackage(
            at: packageURL,
            fileManager: fileManager,
            limits: limits
        )
        let (conflicts, _) = try diffAgainstStore(read.payload)
        let real = conflicts.filter { !$0.isIdentical }
        guard real.isEmpty else {
            throw KnowledgeArchiveError.identityConflict("\(real.count) 处同 ID 异内容")
        }
        let inserted = try write(payload: read.payload, skippingIdentical: conflicts)
        return KnowledgeArchiveImportResult(
            documentID: read.payload.document.id,
            selectedMinutesID: read.manifest.selectedMinutesID,
            inserted: inserted,
            skippedIdentical: conflicts.count
        )
    }

    /// 库里逐 id 比对。返回 (冲突列表, 需要新写的对象数)。
    private func diffAgainstStore(
        _ payload: KnowledgeArchivePayload
    ) throws -> ([KnowledgeArchiveConflict], Int) {
        var conflicts: [KnowledgeArchiveConflict] = []
        var newCount = 0

        func compare<T: Hashable>(
            _ kind: KnowledgeArchiveConflict.Kind,
            _ id: String,
            _ incoming: T,
            _ existing: T?
        ) {
            guard let existing else {
                newCount += 1
                return
            }
            conflicts.append(KnowledgeArchiveConflict(
                kind: kind,
                id: id,
                isIdentical: existing == incoming
            ))
        }

        if let session = payload.session {
            let existing = try self.session(id: session.id)?.archiveModel
            compare(.session, session.id, session, existing)
        }
        for line in payload.lines {
            let existing = try transcriptLine(id: line.id)?.archiveModel
            compare(.line, line.id, line, existing)
        }
        if let sessionID = payload.session?.id {
            let existingNames = try speakerNames(sessionID: sessionID)
            for (label, name) in payload.speakerNames {
                compare(.speakerName, "\(sessionID)/\(label)", name, existingNames[label])
            }
        }
        compare(.document, payload.document.id, payload.document, try meetingDocument(id: payload.document.id)?.archiveModel)
        for snapshot in payload.snapshots {
            compare(.snapshot, snapshot.id, snapshot, try sourceSnapshot(id: snapshot.id)?.archiveModel)
        }
        for revision in payload.revisions {
            compare(.revision, revision.id, revision, try transcriptRevision(id: revision.id)?.archiveModel)
        }
        for minutes in payload.minutes {
            compare(.minutes, minutes.id, minutes, try minutesVersion(id: minutes.id)?.archiveModel)
        }
        for item in payload.items {
            let existing = try minutesItems(minutesID: item.minutesID)
                .first { $0.id == item.id }?.archiveModel(documentID: payload.document.id)
            compare(.minutesItem, item.id, item, existing)
        }
        for event in payload.execution {
            let existing = try knowledgeExecutionEvents(documentID: payload.document.id)
                .first { $0.id == event.id }
            compare(.executionEvent, event.id, event, existing)
        }
        for supersession in payload.supersessions {
            let existing = try knowledgeSupersessions(documentID: payload.document.id)
                .first { $0.id == supersession.id }
            compare(.supersession, supersession.id, supersession, existing)
        }
        for window in payload.windows {
            let existing = try minutesWindows(minutesID: window.minutesID)
                .first { $0.id == window.id }?.archiveModel(minutesID: window.minutesID)
            compare(.window, window.id, window, existing)
        }
        return (conflicts, newCount)
    }

    /// 读一组行修订，并把它们的父修订一并带上——只带子不带父的话，
    /// 修订链在包中间就断了，读的人看到的是一段没有出处的改动。
    /// 引用不到的修订（库里已经删了）跳过，不因此让整个导出失败。
    private func revisions(includingParentsOf ids: Set<String>) throws -> [TranscriptRevision] {
        var queue = Array(ids)
        var seen: Set<String> = []
        var rows: [TranscriptRevision] = []
        while let current = queue.popLast() {
            guard seen.insert(current).inserted else { continue }
            guard let revision = try transcriptRevision(id: current) else { continue }
            rows.append(revision)
            if let parentID = revision.parentRevisionID { queue.append(parentID) }
        }
        return rows.sorted { $0.editedAt < $1.editedAt }
    }

    /// 落库。**保持原 id**；已存在且内容一致的跳过，不存在冲突时不可能撞唯一约束。
    private func write(
        payload: KnowledgeArchivePayload,
        skippingIdentical conflicts: [KnowledgeArchiveConflict]
    ) throws -> KnowledgeArchiveCounts {
        let identicalIDs = Set(conflicts.filter(\.isIdentical).map(\.id))
        var inserted = KnowledgeArchiveCounts.zero

        try execute("BEGIN IMMEDIATE;")
        do {
            if let session = payload.session, !identicalIDs.contains(session.id) {
                try withStatement("""
                INSERT INTO session (
                    id, kind, title, state, created_at, started_at, ended_at, engine_profile,
                    audio_source, diarization, diarization_note, llm_endpoint, llm_model,
                    persona_id, persona_title, voice_id, voice_name, end_reason
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """) { statement in
                    bind(statement, 1, session.id)
                    bind(statement, 2, session.kind)
                    bind(statement, 3, session.title)
                    bind(statement, 4, session.state)
                    bind(statement, 5, session.createdAt)
                    bind(statement, 6, session.startedAt)
                    bind(statement, 7, session.endedAt)
                    bind(statement, 8, session.engineProfile)
                    bind(statement, 9, session.audioSource)
                    bind(statement, 10, session.diarization)
                    bind(statement, 11, session.diarizationNote)
                    bind(statement, 12, session.llmEndpoint)
                    bind(statement, 13, session.llmModel)
                    bind(statement, 14, session.personaID)
                    bind(statement, 15, session.personaTitle)
                    bind(statement, 16, session.voiceID)
                    bind(statement, 17, session.voiceName)
                    bind(statement, 18, session.endReason)
                    try step(statement)
                }
                inserted.sessions += 1
            }
            for line in payload.lines where !identicalIDs.contains(line.id) {
                try withStatement("""
                INSERT INTO line (
                    id, session_id, ordinal, role, speaker_label, text, t_start, t_end,
                    source, status, interrupted, device_switch, starred, timing_quality, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """) { statement in
                    bind(statement, 1, line.id)
                    bind(statement, 2, line.sessionID)
                    bind(statement, 3, line.ordinal)
                    bind(statement, 4, line.role)
                    bind(statement, 5, line.speakerLabel)
                    bind(statement, 6, line.text)
                    bind(statement, 7, line.tStart)
                    bind(statement, 8, line.tEnd)
                    bind(statement, 9, line.source)
                    bind(statement, 10, line.status)
                    bind(statement, 11, line.interrupted ? 1 : 0)
                    bind(statement, 12, line.deviceSwitch ? 1 : 0)
                    bind(statement, 13, line.starred ? 1 : 0)
                    bind(statement, 14, line.timingQuality)
                    bind(statement, 15, line.createdAt)
                    try step(statement)
                }
                inserted.lines += 1
            }
            if let sessionID = payload.session?.id {
                for (label, name) in payload.speakerNames {
                    // 内容一致就整行跳过：这里写的是 upsert，不加这道判断的话
                    // 一份重复导入的包会把用户后来改过的说话人名字覆盖回去。
                    guard !identicalIDs.contains("\(sessionID)/\(label)") else { continue }
                    try withStatement("""
                    INSERT INTO speaker_name (session_id, label, display_name, updated_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(session_id, label) DO UPDATE SET display_name = excluded.display_name,
                                                                 updated_at = excluded.updated_at;
                    """) { statement in
                        bind(statement, 1, sessionID)
                        bind(statement, 2, label)
                        bind(statement, 3, name)
                        bind(statement, 4, Date().timeIntervalSince1970)
                        try step(statement)
                    }
                    inserted.speakerNames += 1
                }
            }
            if !identicalIDs.contains(payload.document.id) {
                try withStatement("""
                INSERT INTO meeting_document (
                    id, source_session_id, title, project_id, occurred_at, timezone,
                    deleted_at, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """) { statement in
                    bind(statement, 1, payload.document.id)
                    bind(statement, 2, payload.document.sourceSessionID)
                    bind(statement, 3, payload.document.title)
                    bind(statement, 4, payload.document.projectID)
                    bind(statement, 5, payload.document.occurredAt)
                    bind(statement, 6, payload.document.timezone)
                    bind(statement, 7, payload.document.deletedAt)
                    bind(statement, 8, payload.document.createdAt)
                    bind(statement, 9, payload.document.updatedAt)
                    try step(statement)
                }
                inserted.documents += 1
            }
            for snapshot in payload.snapshots where !identicalIDs.contains(snapshot.id) {
                try withStatement("""
                INSERT INTO source_snapshot (
                    id, document_id, line_revision_ids, speaker_map_revision, note_refs,
                    coverage, seal_result, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """) { statement in
                    bind(statement, 1, snapshot.id)
                    bind(statement, 2, snapshot.documentID)
                    bind(statement, 3, snapshot.lineRevisionIDs.joined(separator: ","))
                    bind(statement, 4, snapshot.speakerMapRevision)
                    bind(statement, 5, snapshot.noteRefs.joined(separator: ","))
                    bind(statement, 6, snapshot.coverage)
                    bind(statement, 7, snapshot.sealResult)
                    bind(statement, 8, snapshot.createdAt)
                    try step(statement)
                }
                inserted.snapshots += 1
            }
            for revision in payload.revisions where !identicalIDs.contains(revision.id) {
                try withStatement("""
                INSERT INTO transcript_revision (
                    id, line_id, session_id, text, origin, parent_revision_id, edited_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?);
                """) { statement in
                    bind(statement, 1, revision.id)
                    bind(statement, 2, revision.lineID)
                    bind(statement, 3, revision.sessionID)
                    bind(statement, 4, revision.text)
                    bind(statement, 5, revision.origin)
                    bind(statement, 6, revision.parentRevisionID)
                    bind(statement, 7, revision.editedAt)
                    try step(statement)
                }
                inserted.revisions += 1
            }
            for minutes in payload.minutes where !identicalIDs.contains(minutes.id) {
                try withStatement("""
                INSERT INTO minutes (
                    id, session_id, version, status, body, model, prompt_chars,
                    is_latest, is_accepted, attempts, failure_reason, lease_until, created_at,
                    is_legacy_import, remote_response_id, config_snapshot, snapshot_id,
                    cancel_requested_at, candidate_json, review_json, coverage_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """) { statement in
                    bind(statement, 1, minutes.id)
                    bind(statement, 2, minutes.sessionID)
                    bind(statement, 3, minutes.version)
                    bind(statement, 4, minutes.status)
                    bind(statement, 5, minutes.body)
                    bind(statement, 6, minutes.model)
                    bind(statement, 7, minutes.promptChars)
                    bind(statement, 8, minutes.isLatest ? 1 : 0)
                    bind(statement, 9, minutes.isAccepted ? 1 : 0)
                    bind(statement, 10, minutes.attempts)
                    bind(statement, 11, minutes.failureReason)
                    bind(statement, 12, minutes.leaseUntil)
                    bind(statement, 13, minutes.createdAt)
                    bind(statement, 14, minutes.isLegacyImport ? 1 : 0)
                    bind(statement, 15, minutes.remoteResponseID)
                    bind(statement, 16, minutes.configSnapshot)
                    bind(statement, 17, minutes.snapshotID)
                    bind(statement, 18, minutes.cancelRequestedAt)
                    bind(statement, 19, minutes.candidateJSON)
                    bind(statement, 20, minutes.reviewJSON)
                    bind(statement, 21, minutes.coverageJSON)
                    try step(statement)
                }
                inserted.minutes += 1
                // MA-15：导入的内容也要进检索索引。outbox 与内容同事务，
                // 所以"已导入"与"已可检索"这两个事实不会互相矛盾。
                try enqueueSearchIndex(
                    sessionID: minutes.sessionID,
                    sourceKind: SearchIndexOp.minutesKind,
                    sourceID: minutes.id
                )
            }
            for item in payload.items where !identicalIDs.contains(item.id) {
                try withStatement("""
                INSERT INTO minutes_item (id, minutes_id, local_id, kind, text, verdict, sort_order)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """) { statement in
                    bind(statement, 1, item.id)
                    bind(statement, 2, item.minutesID)
                    bind(statement, 3, item.localID)
                    bind(statement, 4, item.kind)
                    bind(statement, 5, item.text)
                    bind(statement, 6, item.verdict)
                    bind(statement, 7, item.sortOrder)
                    try step(statement)
                }
                inserted.items += 1
                for anchor in item.anchors where !identicalIDs.contains(anchor.id) {
                    try withStatement("""
                    INSERT INTO minutes_evidence (
                        id, item_id, unit_id, line_id, revision_id, snapshot_id,
                        speaker_label, t_start, verification
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """) { statement in
                        bind(statement, 1, anchor.id)
                        bind(statement, 2, anchor.itemID)
                        bind(statement, 3, anchor.unitID)
                        bind(statement, 4, anchor.lineID)
                        bind(statement, 5, anchor.revisionID)
                        bind(statement, 6, anchor.snapshotID)
                        bind(statement, 7, anchor.speakerLabel)
                        bind(statement, 8, anchor.startSeconds)
                        bind(statement, 9, anchor.verification)
                        try step(statement)
                    }
                    inserted.anchors += 1
                }
            }
            for window in payload.windows where !identicalIDs.contains(window.id) {
                try withStatement("""
                INSERT INTO minutes_window (
                    id, minutes_id, window_index, owned_unit_ids, context_unit_ids,
                    outcome, failure_reason, candidate_json, remote_response_id, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """) { statement in
                    bind(statement, 1, window.id)
                    bind(statement, 2, window.minutesID)
                    bind(statement, 3, window.index)
                    bind(statement, 4, window.ownedUnitIDs.joined(separator: ","))
                    bind(statement, 5, window.contextUnitIDs.joined(separator: ","))
                    bind(statement, 6, window.outcome)
                    bind(statement, 7, window.failureReason)
                    bind(statement, 8, window.candidateJSON)
                    bind(statement, 9, window.remoteResponseID)
                    bind(statement, 10, window.updatedAt)
                    try step(statement)
                }
                inserted.windows += 1
            }
            // 执行状态与决策演进随包回来（MA-14 / MA-19 补齐）。
            // 跳过"内容相同"的那些，与其它对象的口径一致：重复导入不重复写。
            for event in payload.execution where !identicalIDs.contains(event.id) {
                try withStatement("""
                INSERT INTO knowledge_execution_event (
                    id, item_key, document_id, item_id, kind, status, owner_text, due_text,
                    due_date, valid_from, recorded_at, valid_to, note
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """) { statement in
                    bind(statement, 1, event.id)
                    bind(statement, 2, event.itemKey)
                    bind(statement, 3, event.documentID ?? payload.document.id)
                    bind(statement, 4, event.itemID)
                    bind(statement, 5, event.kind)
                    bind(statement, 6, event.status)
                    bind(statement, 7, event.ownerText)
                    bind(statement, 8, event.dueText)
                    bind(statement, 9, event.dueDate)
                    bind(statement, 10, event.validFrom)
                    bind(statement, 11, event.recordedAt)
                    bind(statement, 12, event.validTo)
                    bind(statement, 13, event.note)
                    try step(statement)
                }
                inserted.executionEvents += 1
            }
            for supersession in payload.supersessions where !identicalIDs.contains(supersession.id) {
                try withStatement("""
                INSERT INTO knowledge_supersession (
                    id, from_key, to_key, kind, basis, evidence_item_ids, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?);
                """) { statement in
                    bind(statement, 1, supersession.id)
                    bind(statement, 2, supersession.fromKey)
                    bind(statement, 3, supersession.toKey)
                    bind(statement, 4, supersession.kind)
                    bind(statement, 5, supersession.basis)
                    bind(
                        statement,
                        6,
                        (try? JSONEncoder().encode(supersession.evidenceItemIDs))
                            .map { String(decoding: $0, as: UTF8.self) } ?? "[]"
                    )
                    bind(statement, 7, supersession.createdAt)
                    try step(statement)
                }
                inserted.supersessions += 1
            }
            // 分享包只装锚点引用到的行，所以包里可能有指向**没装进来**的来源的锚点。
            // 这些锚点导入后必须降级：来源不在这个库里，就无从核对，
            // 继续自称"逐字命中"是谎报（验收标准 3）。
            inserted.markedForReview = try markAnchorsWithoutSourceForReview()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        return inserted
    }

    /// 把"引用还在、原句没了"的锚点降级为待复核，并返回受影响的条数。
    ///
    /// `minutes_evidence.line_id` / `revision_id` 是 `ON DELETE SET NULL`，
    /// 所以删掉来源行**不会**删掉锚点，只会把它指向空。锚点还在是好事
    /// （用户还能看见这条结论曾经有过出处），但它必须停止声称已核对。
    ///
    /// 两条一起改：锚点的 `verification` 与条目的 `verdict`。只改前者的话，
    /// 审阅轴读的是后者，界面照样显示"整理好了"。
    @discardableResult
    private func markAnchorsWithoutSourceForReview() throws -> Int {
        let affected = try scalarInt("""
        SELECT COUNT(*) FROM minutes_evidence
        WHERE line_id IS NULL OR revision_id IS NULL;
        """) ?? 0
        try execute("""
        UPDATE minutes_evidence SET verification = 'source_removed'
        WHERE line_id IS NULL OR revision_id IS NULL;
        """)
        // 条目自身是"已核对"或空的才降级：已经是 needsReview / rejected 的不动。
        try execute("""
        UPDATE minutes_item SET verdict = 'needsReview'
        WHERE (verdict IS NULL OR verdict = 'supported')
          AND id IN (
            SELECT item_id FROM minutes_evidence
            WHERE line_id IS NULL OR revision_id IS NULL
          );
        """)
        return affected
    }

    /// 按 id 读一行转录。导入比对与回读核对都要用。
    public func transcriptLine(id: String) throws -> TranscriptLine? {
        try withStatement("""
        SELECT id, session_id, ordinal, role, speaker_label, text, t_start, t_end,
               source, status, interrupted, device_switch, starred, timing_quality, created_at
        FROM line WHERE id = ? LIMIT 1;
        """) { statement -> TranscriptLine? in
            bind(statement, 1, id)
            guard try step(statement) == SQLITE_ROW else { return nil }
            return Self.transcriptLine(from: statement)
        }
    }

    /// 读一版行修订。锚点带的原文来自修订，组装包与回读核对都要用它。
    public func transcriptRevision(id: String) throws -> TranscriptRevision? {
        try withStatement("""
        SELECT id, line_id, session_id, text, origin, parent_revision_id, edited_at
        FROM transcript_revision WHERE id = ? LIMIT 1;
        """) { statement -> TranscriptRevision? in
            bind(statement, 1, id)
            guard try step(statement) == SQLITE_ROW else { return nil }
            return transcriptRevision(from: statement)
        }
    }

    private func allArchiveSnapshots(documentID: String) throws -> [MeetingSourceSnapshot] {
        try withStatement("""
        SELECT id, document_id, line_revision_ids, speaker_map_revision, note_refs, coverage, seal_result, created_at
        FROM source_snapshot WHERE document_id = ? ORDER BY created_at ASC;
        """) { statement -> [MeetingSourceSnapshot] in
            bind(statement, 1, documentID)
            var rows: [MeetingSourceSnapshot] = []
            while try step(statement) == SQLITE_ROW {
                rows.append(sourceSnapshot(from: statement))
            }
            return rows
        }
    }

    private func transcriptRevision(from statement: OpaquePointer) -> TranscriptRevision {
        TranscriptRevision(
            id: columnText(statement, 0) ?? "",
            lineID: columnText(statement, 1) ?? "",
            sessionID: columnText(statement, 2) ?? "",
            text: columnText(statement, 3) ?? "",
            origin: columnText(statement, 4) ?? "",
            parentRevisionID: columnText(statement, 5),
            editedAt: Date(timeIntervalSince1970: columnDouble(statement, 6 as Int32))
        )
    }
}

// MARK: - 知识范围、归档与删除（MA-18 / MC-43、MC-44、MC-62、MC-72）
//
// 三档删除是三件事，不是一个开关的三档强度：归档留着数据、只移除转录留着结论、
// 完整删除什么都不留。**顺序固定为"先不可使用、再清理派生"**：先把文档标成
// 不可见，之后才删正文；反过来会出现"内容已经没了但还能被搜到"的窗口。
extension SessionStore {
    /// 归档/删除的入口（MA-18）。
    ///
    /// - `.archive`：写 tombstone + 排索引删除。数据一行不少，`restoreMeetingKnowledge` 能撤销。
    /// - `.removeTranscript`：删转录行与行修订。纪要、结论条目、锚点留着，
    ///   锚点变成"来源已不可读"——那是合法状态，不是断裂。
    /// - `.deleteEverything`：连文档、会话、快照、纪要、条目、锚点、分窗一起删。
    ///
    /// 全程一个事务：失败路径上当前库一个字节都不变。
    @discardableResult
    public func deleteMeetingKnowledge(
        documentID: String,
        mode: MeetingDeletionMode
    ) throws -> MeetingDeletionReport {
        guard let document = try meetingDocument(id: documentID) else {
            throw KnowledgeArchiveError.documentNotFound(documentID)
        }
        let now = Date().timeIntervalSince1970
        let sessionID = document.sourceSessionID
        var report = MeetingDeletionReport(documentID: documentID, mode: mode)

        // 索引里现有的条目先记下来：它们要排进删除 outbox，而 drain 自己要开事务，
        // 不能嵌在删除事务里（SQLite 不支持嵌套事务）。
        let indexedEntries = try indexedSearchEntries(sessionID: sessionID)
        try execute("BEGIN IMMEDIATE;")
        do {
            // 第一步：不可使用。tombstone 一落，检索、导出、问答都看不见它，
            // 后面的清理哪怕中途出问题也不会让"已删"的东西继续被用。
            try withStatement("""
            UPDATE meeting_document SET deleted_at = ?, deletion_mode = ?, updated_at = ? WHERE id = ?;
            """) { statement in
                bind(statement, 1, now)
                bind(statement, 2, mode.rawValue)
                bind(statement, 3, now)
                bind(statement, 4, documentID)
                try step(statement)
            }

            // 第二步：按档位删正文层。
            switch mode {
            case .archive:
                break
            case .removeTranscript:
                guard let sessionID else { break }
                report.removedLines = try deleteRows("DELETE FROM line WHERE session_id = ?;", sessionID)
                report.removedRevisions = try deleteRows(
                    "DELETE FROM transcript_revision WHERE session_id = ?;", sessionID
                )
                report.removedSnapshots = try deleteRows(
                    "DELETE FROM source_snapshot WHERE document_id = ?;", documentID
                )
                // 纪要与结论留着，但它们的依据没了。
                // 此时必须**降级**：继续自称"逐字命中"就是谎报——原句都不在了，
                // 这条结论根本无从核对（验收标准 3「修改来源后相关结论提示复核」）。
                report.markedForReview = try markAnchorsWithoutSourceForReview()
            case .deleteEverything:
                if let sessionID {
                    report.removedLines = try deleteRows("DELETE FROM line WHERE session_id = ?;", sessionID)
                    report.removedRevisions = try deleteRows(
                        "DELETE FROM transcript_revision WHERE session_id = ?;", sessionID
                    )
                    report.removedSnapshots = try deleteRows(
                        "DELETE FROM source_snapshot WHERE document_id = ?;", documentID
                    )
                    // 从外往里删：锚点 → 条目 → 分窗 → 版本。父行一删子行就被级联带走，
                    // 先删父行的话下面两条都只能数出 0，报告就成了"删了一些"。
                    report.removedAnchors = try deleteRows("""
                    DELETE FROM minutes_evidence WHERE item_id IN
                        (SELECT i.id FROM minutes_item i JOIN minutes m ON m.id = i.minutes_id
                         WHERE m.session_id = ?);
                    """, sessionID)
                    report.removedItems = try deleteRows("""
                    DELETE FROM minutes_item WHERE minutes_id IN
                        (SELECT id FROM minutes WHERE session_id = ?);
                    """, sessionID)
                    try deleteRows("""
                    DELETE FROM minutes_window WHERE minutes_id IN
                        (SELECT id FROM minutes WHERE session_id = ?);
                    """, sessionID)
                    report.removedMinutes = try deleteRows("DELETE FROM minutes WHERE session_id = ?;", sessionID)
                    try deleteRows("DELETE FROM inner_os_exchange WHERE session_id = ?;", sessionID)
                    try deleteRows("DELETE FROM speaker_name WHERE session_id = ?;", sessionID)
                    try deleteRows("DELETE FROM session WHERE id = ?;", sessionID)
                }
                try deleteRows("DELETE FROM meeting_document WHERE id = ?;", documentID)
            }
            // 第三步（仍在事务内）：把索引删除排进 outbox。真正写索引放在提交之后，
            // 因为 drain 自己要开事务，不能嵌在这里。
            for (kind, id) in indexedEntries {
                try enqueueSearchIndex(op: SearchIndexOp.delete, sessionID: sessionID, sourceKind: kind, sourceID: id)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        // 派生索引在提交之后才落。失败不影响"已不可用"这个事实——
        // 检索还要过 tombstone 那一关，索引里多留几条也搜不出来。
        report.purgedIndexEntries = (try? drainSearchIndex()) ?? 0
        return report
    }

    /// 撤销归档（MA-18 回退条款）。**只对归档有效**——另外两档没有"撤销"这回事，
    /// 调用它们的人不该被这里悄悄恢复一份已经删掉的内容。
    @discardableResult
    public func restoreMeetingKnowledge(documentID: String) throws -> Bool {
        // 返回值说的是"**确实**撤销了归档"，不是"文档存在"。
        // 对一份没归档过的文档执行 UPDATE 是一次什么也没改的空操作，
        // 返回 true 会让界面说「已撤销归档」而实际什么都没发生——
        // 那比说"这份记录不是归档态，撤不了"坏得多。
        // 档位也要对：移除转录/完整删除的文档 `deleted_at` 同样非空，
        // 但内容已经不在库里，撤回来是个空壳——界面却会说
        // 「已撤销归档，这场会回到搜索和导出里」。
        guard let document = try meetingDocument(id: documentID),
              document.deletedAt != nil,
              document.deletionMode?.isRecoverable == true
        else {
            return false
        }
        try execute("BEGIN IMMEDIATE;")
        do {
            try withStatement(
                "UPDATE meeting_document SET deleted_at = NULL, deletion_mode = NULL, updated_at = ? WHERE id = ?;"
            ) { statement in
                bind(statement, 1, Date().timeIntervalSince1970)
                bind(statement, 2, documentID)
                try step(statement)
            }
            // 恢复后要把索引重新排上：内容回来了，可检索性也要回来。
            if let sessionID = document.sourceSessionID {
                try reindex(sessionID: sessionID)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        return true
    }

    /// 这次删除/归档够不够撤销。只有归档够。
    public func meetingDeletionIsRecoverable(documentID: String) throws -> Bool {
        guard let document = try meetingDocument(id: documentID) else { return false }
        // 读**记下来的档位**，不去数行。
        //
        // 原先靠"转录行还在吗"推断，方向恰好是危险的那个：一场从头到尾没录到
        // 任何东西的会议（用户开了但一句话没说）行数为 0，会被判成"正文被删过、
        // 撤不了"，而它其实只是被归档了。档位是删除那一刻就确定的事实，
        // 不该事后从残留里猜。
        return document.deletionMode?.isRecoverable == true
    }

    private func deleteRows(_ sql: String, _ argument: String) throws -> Int {
        try withStatement(sql) { statement in
            bind(statement, 1, argument)
            try step(statement)
            return Int(sqlite3_changes(try requireHandle()))
        }
    }

    /// 旧任务提交前重检删除状态（MA-18 / MC-63）。
    ///
    /// 返回 true 表示"这一场已经不可用了，别写"。此时把这一版标成用户停止：
    /// 它确实没产出内容，但原因要说清楚是会议被删/被归档，不是模型没整理出来。
    @discardableResult
    func rejectLateMinutesIfMeetingDeleted(minutesID: String) throws -> Bool {
        guard let sessionID = try sessionID(minutesID: minutesID) else { return false }
        guard try isMeetingDeleted(sessionID: sessionID) else { return false }
        try withStatement("""
        UPDATE minutes SET status = 'cancelled', lease_until = NULL,
               failure_reason = '会议已归档或删除，这次整理结果没有写入'
        WHERE id = ? AND status IN ('queued', 'running');
        """) { statement in
            bind(statement, 1, minutesID)
            try step(statement)
        }
        return true
    }

    // MARK: - 范围过滤

    /// 可见性 SQL 片段。两个检索路径共用同一段，所以"归档之后还能被搜到"
    /// 这种漏洞不会只在其中一条路上出现。
    private static func visibilityClause(scope: MeetingKnowledgeScope, documentAlias: String = "d") -> (sql: String, bindings: [SQLArgument]) {
        var sql = ""
        var bindings: [SQLArgument] = []
        if scope.includesArchived {
            // 显式包含归档时不做 tombstone 过滤，但点名与项目过滤照旧。
        } else {
            sql += " AND (\(documentAlias).id IS NULL OR \(documentAlias).deleted_at IS NULL)"
        }
        if !scope.documentIDs.isEmpty {
            let placeholders = Array(repeating: "?", count: scope.documentIDs.count).joined(separator: ", ")
            sql += " AND \(documentAlias).id IN (\(placeholders))"
            bindings.append(contentsOf: scope.documentIDs.sorted().map { .text($0) })
        } else if let projectID = scope.projectID {
            // 指定了项目就只能看这个项目。没有文档的行（助手、字幕）不隶属于
            // 任何项目，因此**不**在范围内——这是"只检索授权范围"的保守读法。
            sql += " AND \(documentAlias).project_id = ?"
            bindings.append(.text(projectID))
        }
        return (sql, bindings)
    }

    /// 归档后仍在飞行中的旧任务：**提交前重检**文档是不是已经不可用了。
    ///
    /// 不重检的后果是"用户删了/归档了，一条几分钟后才回来的任务把它又写了回来"，
    /// 而且界面显示的是删除之前的状态——用户完全不知情（MC-63）。
    func minutesOwnerMayStillCommit(minutesID: String) throws -> Bool {
        guard let sessionID = try sessionID(minutesID: minutesID) else { return true }
        return try !isMeetingDeleted(sessionID: sessionID)
    }

    /// 这一场是不是已经归档/删除。
    public func isMeetingDeleted(sessionID: String) throws -> Bool {
        let sql = """
        SELECT d.deleted_at FROM meeting_document d
        WHERE d.source_session_id = ? AND d.deleted_at IS NOT NULL LIMIT 1;
        """
        return try withStatement(sql) { statement -> Bool in
            bind(statement, 1, sessionID)
            return try step(statement) == SQLITE_ROW
        }
    }

    func sessionID(minutesID: String) throws -> String? {
        try withStatement("SELECT session_id FROM minutes WHERE id = ? LIMIT 1;") { statement -> String? in
            bind(statement, 1, minutesID)
            guard try step(statement) == SQLITE_ROW else { return nil }
            return columnText(statement, 0)
        }
    }

    /// 把一场会重新排进检索索引（撤销归档、导入之后用）。
    private func reindex(sessionID: String) throws {
        let lineIDs = try withStatement("SELECT id FROM line WHERE session_id = ? AND status = 'final';") { statement -> [String] in
            bind(statement, 1, sessionID)
            var ids: [String] = []
            while try step(statement) == SQLITE_ROW {
                if let id = columnText(statement, 0) { ids.append(id) }
            }
            return ids
        }
        for id in lineIDs {
            try enqueueSearchIndex(sessionID: sessionID, sourceKind: SearchIndexOp.lineKind, sourceID: id)
        }
        let minutesIDs = try withStatement("SELECT id FROM minutes WHERE session_id = ? AND status = 'ready';") { statement -> [String] in
            bind(statement, 1, sessionID)
            var ids: [String] = []
            while try step(statement) == SQLITE_ROW {
                if let id = columnText(statement, 0) { ids.append(id) }
            }
            return ids
        }
        for id in minutesIDs {
            try enqueueSearchIndex(sessionID: sessionID, sourceKind: SearchIndexOp.minutesKind, sourceID: id)
        }
    }

    /// 一场会当前在检索索引里占着哪些条目。
    private func indexedSearchEntries(sessionID: String?) throws -> [(String, String)] {
        guard let sessionID, Self.fts5Available else { return [] }
        let ids = try withStatement("""
        SELECT source_kind, source_id FROM knowledge_fts WHERE session_id = ?;
        """) { statement -> [(String, String)] in
            bind(statement, 1, sessionID)
            var rows: [(String, String)] = []
            while try step(statement) == SQLITE_ROW {
                if let kind = columnText(statement, 0), let id = columnText(statement, 1) {
                    rows.append((kind, id))
                }
            }
            return rows
        }
        return ids
    }
}

// MARK: - 跨会议证据取数（MA-17 / MC-56、MC-57、MC-64）
//
// 取数与措辞分开：这里只回答"授权范围内有哪些可引用的事实、它们是什么状态"，
// 不生成任何答案。**分页是显式的**：列表问题必须能翻到底，
// 拿 top-k 当全量就是漏答（MC-57）。
extension SessionStore {
    /// 授权范围内取证据。
    ///
    /// - `.list`：不按词过滤，翻页取全，避免"只回了最相关的几条"被读成"就这些"。
    /// - `.point`：按问题词项用**与检索同一套分词**过滤，词项全命中才算相关。
    /// - `.preparation`：只取当前版本的未决与待办。
    public func knowledgeEvidence(
        question: String,
        kind: KnowledgeQuestionKind,
        scope: MeetingKnowledgeScope = .standard,
        itemKinds: Set<String> = ["decision", "action", "open_question", "overview"],
        limit: Int = 50,
        offset: Int = 0
    ) throws -> KnowledgeRetrieval {
        let visibility = Self.visibilityClause(scope: scope)
        var sql = """
        SELECT i.id, i.minutes_id, i.kind, i.text, i.verdict, m.version, m.session_id,
               m.candidate_json, m.created_at,
               COALESCE(d.id, ''), d.occurred_at, m.is_accepted
        FROM minutes_item i
        JOIN minutes m ON m.id = i.minutes_id
        JOIN session s ON s.id = m.session_id
        LEFT JOIN meeting_document d ON d.source_session_id = s.id
        WHERE m.status = 'ready' AND m.body IS NOT NULL
        \(visibility.sql)
        ORDER BY COALESCE(d.occurred_at, m.created_at) DESC, m.version DESC, i.sort_order ASC;
        """
        var rows = try withStatement(sql) { statement -> [EvidenceRow] in
            var index: Int32 = 1
            for value in visibility.bindings {
                bindArgument(statement, index, value)
                index += 1
            }
            var results: [EvidenceRow] = []
            while try step(statement) == SQLITE_ROW {
                results.append(EvidenceRow(
                    id: columnText(statement, 0) ?? "",
                    minutesID: columnText(statement, 1) ?? "",
                    kind: columnText(statement, 2) ?? "",
                    text: columnText(statement, 3) ?? "",
                    verdict: columnText(statement, 4),
                    version: Int(columnInt(statement, 5)),
                    sessionID: columnText(statement, 6) ?? "",
                    candidateJSON: columnText(statement, 7),
                    createdAt: Date(timeIntervalSince1970: columnDouble(statement, 8 as Int32)),
                    documentID: columnText(statement, 9) ?? "",
                    occurredAt: columnIsNull(statement, 10) ? nil : Date(timeIntervalSince1970: columnDouble(statement, 10 as Int32)),
                    isAccepted: columnInt(statement, 11) != 0
                ))
            }
            return results
        }
        rows = rows.filter { itemKinds.contains($0.kind) }

        // 当前版本 = 采用版；没有采用版时退回最新可用版（与展示口径同一处判断）。
        let currentVersionIDs = try currentMinutesIDs(for: Set(rows.map(\.sessionID)))
        var disputedCache: [String: Set<String>] = [:]

        func isDisputed(_ row: EvidenceRow) -> Bool {
            if disputedCache[row.minutesID] == nil {
                disputedCache[row.minutesID] = disputedDecisionTexts(in: row.candidateJSON)
            }
            return disputedCache[row.minutesID]?.contains(row.text) == true
        }

        var matched = rows
        switch kind {
        case .list, .preparation:
            break
        case .point:
            // 与全文检索同一套分词、同一个 AND 语义：问题词项必须被结论文本全包含。
            let terms = Set(KnowledgeSearchTokenizer.indexTerms(for: question))
            if !terms.isEmpty {
                matched = rows.filter { row in
                    Set(KnowledgeSearchTokenizer.indexTerms(for: row.text)).isSuperset(of: terms)
                }
            } else {
                // 问题里没有可用的词项：这不是"确实没有"，退回按范围取全部，
                // 由上层决定怎么用，而不是悄悄给一个零结果。
                matched = rows
            }
        }
        if kind == .preparation {
            matched = matched.filter { currentVersionIDs.contains($0.minutesID) }
        }

        let page = matched.dropFirst(offset).prefix(max(0, limit))
        let evidence = try page.map { row in
            KnowledgeEvidence(
                id: row.id,
                documentID: row.documentID,
                sessionID: row.sessionID,
                minutesID: row.minutesID,
                version: row.version,
                kind: row.kind,
                text: row.text,
                status: KnowledgeItemStatus(
                    isCurrent: currentVersionIDs.contains(row.minutesID),
                    isDisputed: isDisputed(row),
                    needsReview: row.verdict == nil
                        || row.verdict != MinutesEvidenceValidator.Verdict.supported.rawValue
                ),
                anchors: try minutesEvidence(itemID: row.id),
                occurredAt: row.occurredAt
            )
        }
        return KnowledgeRetrieval(
            question: question,
            kind: kind,
            evidence: evidence,
            totalMatched: matched.count,
            offset: offset,
            snapshotID: nil
        )
    }

    /// 每场会当前该被引用的那一版：采用版优先，没有采用版才用最新可用版。
    func currentMinutesIDs(for sessionIDs: Set<String>) throws -> Set<String> {
        var ids: Set<String> = []
        for sessionID in sessionIDs {
            if let accepted = try acceptedMinutes(sessionID: sessionID) {
                ids.insert(accepted.id)
            } else if let latest = try latestUsableMinutes(sessionID: sessionID) {
                ids.insert(latest.id)
            }
        }
        return ids
    }

    /// 这一版里被归并器标成"存在分歧/未确认"的结论正文（MA-09/§6.3）。
    /// 标记只写在候选 JSON 的 `conditions` 里，`minutes_item` 不存它，
    /// 所以判定必须回候选里读——把标记另存一列就会两处真相。
    func disputedDecisionTexts(in candidateJSON: String?) -> Set<String> {
        guard let candidateJSON, let data = candidateJSON.data(using: .utf8),
              let candidate = try? JSONDecoder().decode(MinutesCandidateV2.self, from: data)
        else { return [] }
        let marker = "存在分歧/未确认"
        return Set(candidate.decisions.filter { $0.conditions.contains(marker) }.map(\.text))
    }

    /// 下次会议准备稿（MA-17）。**只读**：它没有发送、建日程或写回库的入口。
    public func meetingPrepDraft(scope: MeetingKnowledgeScope = .standard) throws -> MeetingPrepDraft {
        let retrieval = try knowledgeEvidence(
            question: "",
            kind: .preparation,
            scope: scope,
            itemKinds: ["open_question", "action"],
            limit: 200,
            offset: 0
        )
        return MeetingPrepDraft(
            openQuestions: retrieval.evidence.filter { $0.kind == "open_question" },
            pendingActions: retrieval.evidence.filter { $0.kind == "action" },
            needsReview: retrieval.evidence.filter { !$0.isEstablishedFact }
        )
    }

    /// 展示前最后一次范围复核（MC-63、MC-72）。
    ///
    /// 问答开始时取到的证据，到展示那一刻可能已经被归档或删除。
    /// 这个方法只回答"这些证据现在还在不在"，不回答别的。
    public func liveKnowledgeEvidenceIDs(_ ids: Set<String>) throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let visibility = Self.visibilityClause(scope: MeetingKnowledgeScope())
        let sorted = ids.sorted()
        let placeholders = Array(repeating: "?", count: sorted.count).joined(separator: ", ")
        let sql = """
        SELECT i.id
        FROM minutes_item i
        JOIN minutes m ON m.id = i.minutes_id
        JOIN session s ON s.id = m.session_id
        LEFT JOIN meeting_document d ON d.source_session_id = s.id
        WHERE i.id IN (\(placeholders))
          AND m.status = 'ready' AND m.body IS NOT NULL
          \(visibility.sql);
        """
        return try withStatement(sql) { statement -> Set<String> in
            var index: Int32 = 1
            for id in sorted {
                bind(statement, index, id)
                index += 1
            }
            for value in visibility.bindings {
                bindArgument(statement, index, value)
                index += 1
            }
            var live: Set<String> = []
            while try step(statement) == SQLITE_ROW {
                if let id = columnText(statement, 0) { live.insert(id) }
            }
            return live
        }
    }

    private struct EvidenceRow {
        var id: String
        var minutesID: String
        var kind: String
        var text: String
        var verdict: String?
        var version: Int
        var sessionID: String
        var candidateJSON: String?
        var createdAt: Date
        var documentID: String
        var occurredAt: Date?
        var isAccepted: Bool
    }
}

// MARK: - 项目、标签与结构化事项投影（MA-13 / MC-51、MC-52、MC-56）
//
// 计数与列表**共用同一段 WHERE**：分开算就会出现"显示 12 条、列出 9 条"，
// 用户没法判断该信哪个。这里先把命中行的元信息（不含正文）全部读出来聚合，
// 再按页取正文，谓词只有一份，计数不可能和列表对不上。
extension SessionStore {
    // MARK: 项目

    @discardableResult
    public func createProject(name: String, id: String = UUID().uuidString) throws -> MeetingProject {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SessionStoreError.statementFailed("项目名不能为空")
        }
        let project = MeetingProject(id: id, name: trimmed)
        try withStatement(
            "INSERT INTO meeting_project (id, name, created_at) VALUES (?, ?, ?);"
        ) { statement in
            bind(statement, 1, project.id)
            bind(statement, 2, project.name)
            bind(statement, 3, project.createdAt.timeIntervalSince1970)
            try step(statement)
        }
        return project
    }

    public func meetingProject(id: String) throws -> MeetingProject? {
        try withStatement("SELECT id, name, created_at FROM meeting_project WHERE id = ? LIMIT 1;") { statement -> MeetingProject? in
            bind(statement, 1, id)
            guard try step(statement) == SQLITE_ROW else { return nil }
            return MeetingProject(
                id: columnText(statement, 0) ?? "",
                name: columnText(statement, 1) ?? "",
                createdAt: Date(timeIntervalSince1970: columnDouble(statement, 2))
            )
        }
    }

    public func projects() throws -> [MeetingProject] {
        try withStatement("SELECT id, name, created_at FROM meeting_project ORDER BY created_at ASC;") { statement -> [MeetingProject] in
            var rows: [MeetingProject] = []
            while try step(statement) == SQLITE_ROW {
                rows.append(MeetingProject(
                    id: columnText(statement, 0) ?? "",
                    name: columnText(statement, 1) ?? "",
                    createdAt: Date(timeIntervalSince1970: columnDouble(statement, 2))
                ))
            }
            return rows
        }
    }

    public func renameProject(id: String, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SessionStoreError.statementFailed("项目名不能为空")
        }
        try withStatement("UPDATE meeting_project SET name = ? WHERE id = ?;") { statement in
            bind(statement, 1, trimmed)
            bind(statement, 2, id)
            try step(statement)
        }
    }

    // MARK: 标签

    /// 标签是**用户写的**，导入与生成都不猜（MA-13）。
    public func setDocumentTags(documentID: String, tags: [String]) throws {
        guard try meetingDocument(id: documentID) != nil else {
            throw SessionStoreError.statementFailed("找不到这场会议知识文档")
        }
        let cleaned = Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        try execute("BEGIN IMMEDIATE;")
        do {
            try withStatement("DELETE FROM meeting_document_tag WHERE document_id = ?;") { statement in
                bind(statement, 1, documentID)
                try step(statement)
            }
            for tag in cleaned.sorted() {
                try withStatement(
                    "INSERT INTO meeting_document_tag (document_id, tag) VALUES (?, ?);"
                ) { statement in
                    bind(statement, 1, documentID)
                    bind(statement, 2, tag)
                    try step(statement)
                }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func documentTags(documentID: String) throws -> [String] {
        try withStatement("SELECT tag FROM meeting_document_tag WHERE document_id = ? ORDER BY tag ASC;") { statement -> [String] in
            bind(statement, 1, documentID)
            var tags: [String] = []
            while try step(statement) == SQLITE_ROW {
                if let tag = columnText(statement, 0) { tags.append(tag) }
            }
            return tags
        }
    }

    public func documentTagsInProject(projectID: String) throws -> [String] {
        try withStatement("""
        SELECT DISTINCT t.tag FROM meeting_document_tag t
        JOIN meeting_document d ON d.id = t.document_id
        WHERE d.project_id = ? ORDER BY t.tag ASC;
        """) { statement -> [String] in
            bind(statement, 1, projectID)
            var tags: [String] = []
            while try step(statement) == SQLITE_ROW {
                if let tag = columnText(statement, 0) { tags.append(tag) }
            }
            return tags
        }
    }

    // MARK: 结构化投影

    /// 结构化事项查询：筛选 → 分页 → 计数（MC-51、MC-52、MC-56）。
    ///
    /// 默认档**包含待核对**：只有待核对候选的那场会不能从库里消失（MC-52）。
    /// 严格档是用户显式选的"只看已确认"。
    public func knowledgeItems(
        filter: KnowledgeItemFilter = .all,
        scope: MeetingKnowledgeScope = .standard,
        limit: Int = 50,
        offset: Int = 0
    ) throws -> KnowledgeItemPage {
        let predicate = itemPredicate(filter: filter, scope: scope)

        // 第一遍：只取命中行的元信息，用来算计数。不读正文，代价可控。
        struct Meta {
            var id: String
            var minutesID: String
            var kind: String
            var text: String
            var verdict: String?
            var candidateJSON: String?
            var sessionID: String
            var version: Int
            var createdAt: Double
            var documentID: String
            var occurredAt: Double?
            var isAccepted: Bool
        }
        let metaSQL = """
        SELECT i.id, i.minutes_id, i.kind, i.text, i.verdict, m.candidate_json, m.session_id, m.version,
               m.created_at, COALESCE(d.id, ''), d.occurred_at, m.is_accepted
        FROM minutes_item i
        JOIN minutes m ON m.id = i.minutes_id
        JOIN session s ON s.id = m.session_id
        LEFT JOIN meeting_document d ON d.source_session_id = s.id
        WHERE \(predicate.sql)
        ORDER BY COALESCE(d.occurred_at, m.created_at) DESC, m.version DESC, i.sort_order ASC;
        """
        let all = try withStatement(metaSQL) { statement -> [Meta] in
            var index: Int32 = 1
            for value in predicate.bindings {
                bindArgument(statement, index, value)
                index += 1
            }
            var rows: [Meta] = []
            while try step(statement) == SQLITE_ROW {
                rows.append(Meta(
                    id: columnText(statement, 0) ?? "",
                    minutesID: columnText(statement, 1) ?? "",
                    kind: columnText(statement, 2) ?? "",
                    text: columnText(statement, 3) ?? "",
                    verdict: columnText(statement, 4),
                    candidateJSON: columnText(statement, 5),
                    sessionID: columnText(statement, 6) ?? "",
                    version: Int(columnInt(statement, 7)),
                    createdAt: columnDouble(statement, 8 as Int32),
                    documentID: columnText(statement, 9) ?? "",
                    occurredAt: columnIsNull(statement, 10) ? nil : columnDouble(statement, 10 as Int32),
                    isAccepted: columnInt(statement, 11) != 0
                ))
            }
            return rows
        }

        var disputedCache: [String: Set<String>] = [:]
        var byKind: [String: Int] = [:]
        var needsReviewCount = 0
        var disputedCount = 0
        for row in all {
            byKind[row.kind, default: 0] += 1
            if row.verdict == nil || row.verdict != MinutesEvidenceValidator.Verdict.supported.rawValue {
                needsReviewCount += 1
            }
            if disputedCache[row.minutesID] == nil {
                disputedCache[row.minutesID] = disputedDecisionTexts(in: row.candidateJSON)
            }
            if disputedCache[row.minutesID]?.contains(row.text) == true { disputedCount += 1 }
        }
        let counts = KnowledgeItemCounts(
            total: all.count,
            byKind: byKind,
            needsReview: needsReviewCount,
            disputed: disputedCount
        )

        // 第二遍：只为本页取正文与锚点。
        let pageRows = all.dropFirst(offset).prefix(max(0, limit))
        let currentIDs = try currentMinutesIDs(for: Set(pageRows.map(\.sessionID)))
        let items = try pageRows.map { row -> KnowledgeEvidence in
            let disputed = disputedCache[row.minutesID]?.contains(row.text) == true
            let items = try minutesItems(minutesID: row.minutesID)
            let anchorSet = items.first { $0.id == row.id }?.anchors ?? []
            return KnowledgeEvidence(
                id: row.id,
                documentID: row.documentID,
                sessionID: row.sessionID,
                minutesID: row.minutesID,
                version: row.version,
                kind: row.kind,
                text: row.text,
                status: KnowledgeItemStatus(
                    isCurrent: currentIDs.contains(row.minutesID),
                    isDisputed: disputed,
                    needsReview: row.verdict == nil
                        || row.verdict != MinutesEvidenceValidator.Verdict.supported.rawValue
                ),
                anchors: anchorSet,
                occurredAt: row.occurredAt.map { Date(timeIntervalSince1970: $0) }
            )
        }
        return KnowledgeItemPage(items: items, counts: counts, offset: offset, limit: limit)
    }

    /// 筛选谓词。**列表与计数都用这一份**，所以两者不可能对不上。
    private func itemPredicate(
        filter: KnowledgeItemFilter,
        scope: MeetingKnowledgeScope
    ) -> (sql: String, bindings: [SQLArgument]) {
        var sql = "m.status = 'ready' AND m.body IS NOT NULL"
        var bindings: [SQLArgument] = []
        let visibility = Self.visibilityClause(scope: scope, documentAlias: "d")
        sql += visibility.sql
        bindings.append(contentsOf: visibility.bindings)

        if !filter.projectIDs.isEmpty {
            let placeholders = Array(repeating: "?", count: filter.projectIDs.count).joined(separator: ", ")
            sql += " AND d.project_id IN (\(placeholders))"
            bindings.append(contentsOf: filter.projectIDs.sorted().map { .text($0) })
        }
        if !filter.documentIDs.isEmpty {
            let placeholders = Array(repeating: "?", count: filter.documentIDs.count).joined(separator: ", ")
            sql += " AND d.id IN (\(placeholders))"
            bindings.append(contentsOf: filter.documentIDs.sorted().map { .text($0) })
        }
        if !filter.tags.isEmpty {
            let placeholders = Array(repeating: "?", count: filter.tags.count).joined(separator: ", ")
            // 标签取交集：同时打了「发布」和「2024」的会才算命中两个标签。
            sql += """
             AND d.id IN (
               SELECT document_id FROM meeting_document_tag WHERE tag IN (\(placeholders))
               GROUP BY document_id HAVING COUNT(DISTINCT tag) = \(filter.tags.count)
             )
            """
            bindings.append(contentsOf: filter.tags.sorted().map { .text($0) })
        }
        if !filter.kinds.isEmpty {
            let placeholders = Array(repeating: "?", count: filter.kinds.count).joined(separator: ", ")
            sql += " AND i.kind IN (\(placeholders))"
            bindings.append(contentsOf: filter.kinds.sorted().map { .text($0) })
        }
        if filter.verification == .strictlyVerified {
            sql += " AND i.verdict = 'supported'"
        }
        return (sql, bindings)
    }
}

// MARK: - 行动生命周期与决策演进（MA-14 / MC-53、MC-57～MC-59）
//
// 状态存在**版本之外**，按稳定 key 索引。纪要重新生成会写出新的一版 `minutes_item`，
// `item.id` 每次都变；状态挂在条目上就会被重置掉，已完成的任务会自己复活（MC-53）。
extension SessionStore {
    private struct ExecutionContext {
        var itemKey: String
        var documentID: String
        var kind: String
        var text: String
    }

    /// 从条目解析稳定 key。要的是这场会 + 这类 + 规范化正文，不是数据库行 id。
    private func executionContext(itemID: String) throws -> ExecutionContext {
        let rows = try withStatement("""
        SELECT i.kind, i.text, COALESCE(d.id, '')
        FROM minutes_item i
        JOIN minutes m ON m.id = i.minutes_id
        JOIN session s ON s.id = m.session_id
        LEFT JOIN meeting_document d ON d.source_session_id = s.id
        WHERE i.id = ? LIMIT 1;
        """) { statement -> [(kind: String, text: String, documentID: String)] in
            bind(statement, 1, itemID)
            var found: [(String, String, String)] = []
            while try step(statement) == SQLITE_ROW {
                found.append((
                    columnText(statement, 0) ?? "",
                    columnText(statement, 1) ?? "",
                    columnText(statement, 2) ?? ""
                ))
            }
            return found
        }
        guard let row = rows.first, !row.documentID.isEmpty else {
            throw SessionStoreError.statementFailed("找不到这条会议知识条目")
        }
        return ExecutionContext(
            itemKey: KnowledgeIdentity.key(documentID: row.documentID, kind: row.kind, text: row.text),
            documentID: row.documentID,
            kind: row.kind,
            text: row.text
        )
    }

    /// 记一次执行状态变化。**只追加事件**，不改写旧事件。
    ///
    /// `ownerText` / `dueText` / `dueDate` 传 nil 表示"这次没改"，
    /// 沿用上一条的值；未知就一直保持未知——**不从正文猜负责人和期限**（MC-59）。
    @discardableResult
    public func recordExecutionEvent(
        itemID: String,
        status: ActionExecutionStatus,
        ownerText: String?? = nil,
        dueText: String?? = nil,
        dueDate: Date?? = nil,
        validFrom: Date = Date(),
        note: String? = nil
    ) throws -> KnowledgeExecutionEvent {
        let context = try executionContext(itemID: itemID)
        let previous = try executionState(itemKey: context.itemKey)
        let event = KnowledgeExecutionEvent(
            itemKey: context.itemKey,
            documentID: context.documentID,
            itemID: itemID,
            kind: context.kind,
            status: status,
            ownerText: ownerText ?? previous?.ownerText,
            dueText: dueText ?? previous?.dueText,
            dueDate: dueDate ?? previous?.dueDate,
            validFrom: validFrom,
            note: note
        )
        try insertExecutionEvent(event)
        return event
    }

    private func insertExecutionEvent(_ event: KnowledgeExecutionEvent) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            // 补记（validFrom 早于已有事件）时只关掉**不晚于**它的那些，
            // 后面那些"更新的"承诺保持有效——它们才是现在的状态。
            try withStatement("""
            UPDATE knowledge_execution_event SET valid_to = ?
            WHERE item_key = ? AND valid_to IS NULL AND valid_from <= ?;
            """) { statement in
                bind(statement, 1, event.validFrom.timeIntervalSince1970)
                bind(statement, 2, event.itemKey)
                bind(statement, 3, event.validFrom.timeIntervalSince1970)
                try step(statement)
            }
            try withStatement("""
            INSERT INTO knowledge_execution_event
              (id, item_key, document_id, item_id, kind, status, owner_text, due_text, due_date,
               valid_from, recorded_at, valid_to, note)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """) { statement in
                bind(statement, 1, event.id)
                bind(statement, 2, event.itemKey)
                bind(statement, 3, event.documentID)
                bind(statement, 4, event.itemID)
                bind(statement, 5, event.kind)
                bind(statement, 6, event.status.rawValue)
                bind(statement, 7, event.ownerText)
                bind(statement, 8, event.dueText)
                bind(statement, 9, event.dueDate?.timeIntervalSince1970)
                bind(statement, 10, event.validFrom.timeIntervalSince1970)
                bind(statement, 11, event.recordedAt.timeIntervalSince1970)
                bind(statement, 12, event.validTo?.timeIntervalSince1970)
                bind(statement, 13, event.note)
                try step(statement)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// 当前的执行状态。**没有事件就是"没有状态"**，不是"未完成"：
    /// 没记录过和记录成未完成是两回事，界面给的提示不一样。
    public func executionState(itemID: String) throws -> KnowledgeExecutionState? {
        try executionState(itemKey: try executionContext(itemID: itemID).itemKey)
    }

    public func executionState(itemKey: String) throws -> KnowledgeExecutionState? {
        try executionState(itemKey: itemKey, asOfValidTime: nil)
    }

    /// 按**有效时间**读回那一刻的状态。日期更新不改变历史承诺（MC-59）：
    /// 三月承诺的期限，四月改成五月之后，仍然能读回"三月时承诺的是三月"。
    public func executionState(itemKey: String, asOfValidTime date: Date) throws -> KnowledgeExecutionState? {
        try executionStateValid(itemKey: itemKey, at: date)
    }

    private func executionStateValid(itemKey: String, at date: Date) throws -> KnowledgeExecutionState? {
        try executionState(itemKey: itemKey, asOfValidTime: Optional(date))
    }

    private func executionState(itemKey: String, asOfValidTime date: Date?) throws -> KnowledgeExecutionState? {
        let clause = date == nil ? "" : " AND valid_from <= ?"
        return try withStatement("""
        SELECT item_key, kind, status, owner_text, due_text, due_date, valid_from, recorded_at
        FROM knowledge_execution_event
        WHERE item_key = ?\(clause)
        ORDER BY valid_from DESC, recorded_at DESC, id DESC
        LIMIT 1;
        """) { statement -> KnowledgeExecutionState? in
            bind(statement, 1, itemKey)
            if let date { bind(statement, 2, date.timeIntervalSince1970) }
            guard try step(statement) == SQLITE_ROW else { return nil }
            return KnowledgeExecutionState(
                itemKey: columnText(statement, 0) ?? "",
                kind: columnText(statement, 1) ?? "",
                status: ActionExecutionStatus(rawValue: columnText(statement, 2) ?? "") ?? .open,
                ownerText: columnText(statement, 3),
                dueText: columnText(statement, 4),
                dueDate: columnIsNull(statement, 5) ? nil : Date(timeIntervalSince1970: columnDouble(statement, 5)),
                validFrom: Date(timeIntervalSince1970: columnDouble(statement, 6 as Int32)),
                recordedAt: Date(timeIntervalSince1970: columnDouble(statement, 7))
            )
        }
    }

    /// 完整时间线，按有效时间升序。旧事件永远还在。
    public func executionEvents(itemKey: String) throws -> [KnowledgeExecutionEvent] {
        try withStatement("""
        SELECT id, item_key, document_id, item_id, kind, status, owner_text, due_text, due_date,
               valid_from, recorded_at, valid_to, note
        FROM knowledge_execution_event
        WHERE item_key = ?
        ORDER BY valid_from ASC, recorded_at ASC, id ASC;
        """) { statement -> [KnowledgeExecutionEvent] in
            bind(statement, 1, itemKey)
            var events: [KnowledgeExecutionEvent] = []
            while try step(statement) == SQLITE_ROW {
                events.append(KnowledgeExecutionEvent(
                    id: columnText(statement, 0) ?? "",
                    itemKey: columnText(statement, 1) ?? "",
                    documentID: columnText(statement, 2),
                    itemID: columnText(statement, 3),
                    kind: columnText(statement, 4) ?? "",
                    status: ActionExecutionStatus(rawValue: columnText(statement, 5) ?? "") ?? .open,
                    ownerText: columnText(statement, 6),
                    dueText: columnText(statement, 7),
                    dueDate: columnIsNull(statement, 8) ? nil : Date(timeIntervalSince1970: columnDouble(statement, 8 as Int32)),
                    validFrom: Date(timeIntervalSince1970: columnDouble(statement, 9 as Int32)),
                    recordedAt: Date(timeIntervalSince1970: columnDouble(statement, 10 as Int32)),
                    validTo: columnIsNull(statement, 11) ? nil : Date(timeIntervalSince1970: columnDouble(statement, 11 as Int32)),
                    note: columnText(statement, 12)
                ))
            }
            return events
        }
    }

    // MARK: - 跨会议替代（MC-57、MC-58）

    /// 确认一条跨会议替代关系。
    ///
    /// 只有两种依据：明确证据，或用户确认。**字面相似不作为依据**——
    /// 措辞像不等于承诺变了。
    @discardableResult
    public func confirmSupersession(
        fromItemID: String,
        toItemID: String,
        basis: SupersessionBasis,
        evidenceItemIDs: [String] = []
    ) throws -> KnowledgeSupersession {
        let from = try executionContext(itemID: fromItemID)
        let to = try executionContext(itemID: toItemID)
        guard from.documentID != to.documentID else {
            throw SessionStoreError.statementFailed("同一场会内的重新生成不需要替代关系")
        }
        guard from.kind == to.kind else {
            throw SessionStoreError.statementFailed("只能在同类条目之间建立替代关系")
        }
        var evidence = evidenceItemIDs
        if basis == .evidence {
            // 有证据这一档就得真的挂得上证据，否则"有证据"是句空话。
            evidence = try evidence.filter { try minutesItemExists(id: $0) }
            guard !evidence.isEmpty else {
                throw SessionStoreError.statementFailed("按证据建立替代关系至少要有一条能对上的证据")
            }
        }
        let supersession = KnowledgeSupersession(
            fromKey: from.itemKey,
            toKey: to.itemKey,
            kind: from.kind,
            basis: basis,
            evidenceItemIDs: evidence
        )
        try withStatement("""
        INSERT INTO knowledge_supersession
          (id, from_key, to_key, kind, basis, evidence_item_ids, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """) { statement in
            bind(statement, 1, supersession.id)
            bind(statement, 2, supersession.fromKey)
            bind(statement, 3, supersession.toKey)
            bind(statement, 4, supersession.kind)
            bind(statement, 5, supersession.basis.rawValue)
            bind(statement, 6, String(data: try JSONEncoder().encode(supersession.evidenceItemIDs), encoding: .utf8) ?? "[]")
            bind(statement, 7, supersession.createdAt.timeIntervalSince1970)
            try step(statement)
        }
        return supersession
    }

    private func minutesItemExists(id: String) throws -> Bool {
        try withStatement("SELECT 1 FROM minutes_item WHERE id = ? LIMIT 1;") { statement in
            bind(statement, 1, id)
            return try step(statement) == SQLITE_ROW
        }
    }

    public func supersessions(itemKey: String) throws -> [KnowledgeSupersession] {
        try withStatement("""
        SELECT id, from_key, to_key, kind, basis, evidence_item_ids, created_at
        FROM knowledge_supersession
        WHERE from_key = ? OR to_key = ?
        ORDER BY created_at ASC;
        """) { statement -> [KnowledgeSupersession] in
            bind(statement, 1, itemKey)
            bind(statement, 2, itemKey)
            var rows: [KnowledgeSupersession] = []
            while try step(statement) == SQLITE_ROW {
                let payload = columnText(statement, 5) ?? "[]"
                rows.append(KnowledgeSupersession(
                    id: columnText(statement, 0) ?? "",
                    fromKey: columnText(statement, 1) ?? "",
                    toKey: columnText(statement, 2) ?? "",
                    kind: columnText(statement, 3) ?? "",
                    basis: SupersessionBasis(rawValue: columnText(statement, 4) ?? "") ?? .userConfirmed,
                    evidenceItemIDs: (try? JSONDecoder().decode([String].self, from: Data(payload.utf8))) ?? [],
                    createdAt: Date(timeIntervalSince1970: columnDouble(statement, 6 as Int32))
                ))
            }
            return rows
        }
    }
}

// MARK: - 知识变化建议（MA-14）
//
// 只**提出**差异，不落任何状态。自动建议一旦自己动手改状态，
// 用户就再也说不清"这条为什么变了"。
extension SessionStore {
    /// 同一场会重新生成之后，新一版相对上一版**可能**变了什么。
    ///
    /// 刻意只报"看起来像同一条"的候选，不做负责人/期限的文本抽取——
    /// 从正文猜"这条是谁负责、什么时候之前做完"就是凭空补事实（MC-59）。
    public func knowledgeChangeProposals(documentID: String) throws -> [KnowledgeChangeProposal] {
        guard let document = try meetingDocument(id: documentID),
              let sessionID = document.sourceSessionID
        else { return [] }
        let usable = try minutesVersions(sessionID: sessionID)
            .filter { $0.status == .ready }
            .sorted { $0.version < $1.version }
        // 用户看到的是采用版，没有采用版才看最新可用版——与展示口径同一处判断。
        let currentVersion = try acceptedMinutes(sessionID: sessionID) ?? usable.last
        guard let currentVersion, let previous = usable.dropLast().last,
              previous.id != currentVersion.id
        else { return [] }

        let oldItems = try minutesItems(minutesID: previous.id)
            .filter { $0.kind == "action" || $0.kind == "decision" }
        let newItems = try minutesItems(minutesID: currentVersion.id)
            .filter { $0.kind == "action" || $0.kind == "decision" }
        guard !oldItems.isEmpty || !newItems.isEmpty else { return [] }

        var proposals: [KnowledgeChangeProposal] = []
        var matchedOld: Set<String> = []
        for item in newItems {
            let best = oldItems
                .filter { $0.kind == item.kind && !matchedOld.contains($0.id) }
                .map { ($0, KnowledgeIdentity.similarity($0.text, item.text)) }
                .filter { $0.1 >= KnowledgeIdentity.rewordSimilarityThreshold }
                .max { $0.1 < $1.1 }
            guard let (old, score) = best else {
                proposals.append(KnowledgeChangeProposal(
                    kind: .added,
                    summary: "这一版新出现了条目",
                    proposedItemID: item.id,
                    proposedText: item.text
                ))
                continue
            }
            matchedOld.insert(old.id)
            guard KnowledgeIdentity.normalized(old.text) != KnowledgeIdentity.normalized(item.text) else { continue }
            proposals.append(KnowledgeChangeProposal(
                kind: .reworded,
                summary: "同一条被换了个说法",
                previousItemID: old.id,
                proposedItemID: item.id,
                previousText: old.text,
                proposedText: item.text,
                detail: String(format: "相似度 %.0f%%，负责人和期限都没有变化——要不要算同一条由你定",
                               score * 100)
            ))
        }
        for item in oldItems where !matchedOld.contains(item.id) {
            // 缺席**不等于完成，也不等于放弃**。原状态原样保留，这里只提示。
            proposals.append(KnowledgeChangeProposal(
                kind: .missingFromNewVersion,
                summary: "这一版里没再出现",
                previousItemID: item.id,
                previousText: item.text,
                detail: "不会因此标记成已完成或已放弃"
            ))
        }
        return proposals
    }

    /// 跨会议结论看起来相反、且缺少限定条件的候选对（MC-58）。
    ///
    /// 只**摆出来**并且说清缺什么限定，**不合成一致意见**：
    /// "两个会议结论相反但范围不清"的时候，给一句归纳就是编造共识。
    public func conflictingDecisions(
        scope: MeetingKnowledgeScope = .standard,
        limit: Int = 20
    ) throws -> [KnowledgeChangeProposal] {
        let page = try knowledgeItems(
            filter: KnowledgeItemFilter(kinds: ["decision"]),
            scope: scope,
            limit: 500,
            offset: 0
        )
        // 按共享词项分组；同组里来自不同会议、字面又不一样的，就是候选对。
        var groups: [String: [KnowledgeEvidence]] = [:]
        for item in page.items {
            for term in Set(KnowledgeSearchTokenizer.indexTerms(for: item.text)) where term.count >= 2 {
                groups[term, default: []].append(item)
            }
        }
        var proposals: [KnowledgeChangeProposal] = []
        var seen: Set<String> = []
        for (term, items) in groups.sorted(by: { $0.key < $1.key }) {
            guard items.count > 1 else { continue }
            for i in items.indices {
                for j in items.indices where j > i {
                    let lhs = items[i]
                    let rhs = items[j]
                    guard lhs.documentID != rhs.documentID else { continue }
                    // 说法完全一致只是重复记录，不是冲突。
                    guard KnowledgeIdentity.normalized(lhs.text) != KnowledgeIdentity.normalized(rhs.text) else { continue }
                    let pairKey = "\(min(lhs.id, rhs.id))|\(max(lhs.id, rhs.id))"
                    guard seen.insert(pairKey).inserted else { continue }
                    let detail = conflictDetail(lhs: lhs, rhs: rhs)
                    let summary = "两场会提到「\(term)」，但说法不一样"
                    proposals.append(KnowledgeChangeProposal(
                        kind: .conflictAcrossMeetings,
                        summary: summary,
                        previousItemID: lhs.id,
                        proposedItemID: rhs.id,
                        previousText: lhs.text,
                        proposedText: rhs.text,
                        detail: detail
                    ))
                    if proposals.count >= limit { return proposals }
                }
            }
        }
        return proposals
    }

    /// 说清**缺了哪些限定**，而不是替用户选一个。
    private func conflictDetail(lhs: KnowledgeEvidence, rhs: KnowledgeEvidence) -> String {
        var missing: [String] = []
        if !lhs.isEstablishedFact { missing.append("前一条还没核对") }
        if !rhs.isEstablishedFact { missing.append("后一条还没核对") }
        if !lhs.anchors.isEmpty == false { missing.append("前一条对不上原句") }
        if !rhs.anchors.isEmpty == false { missing.append("后一条对不上原句") }
        if missing.isEmpty {
            return "两条都能追溯到原句，但适用条件不一样的话得你补一句——系统不替你合成一致意见"
        }
        return "缺少限定：" + missing.joined(separator: "、") + "。先补条件，再谈哪个作数"
    }
}

// MARK: - 会议知识库列表与详情快照（MA-12 / MC-48～MC-52、MC-75）

extension SessionStore {
    /// 分页列出会议知识文档。**完整分页，不截断到最近几场**（MC-52）：
    /// 只显示最近 8 场，用户会以为另外 92 场没了。
    ///
    /// 计数与列表**共用同一段谓词**，和 MA-13 同一个纪律。
    public func meetingLibraryPage(
        query: String = "",
        projectID: String? = nil,
        includesArchived: Bool = false,
        limit: Int = 50,
        offset: Int = 0
    ) throws -> MeetingLibraryPage {
        let predicate = libraryPredicate(
            query: query, projectID: projectID, includesArchived: includesArchived
        )
        let from = """
        FROM meeting_document d LEFT JOIN meeting_project p ON p.id = d.project_id
        WHERE 1 = 1 \(predicate.sql)
        ORDER BY COALESCE(d.occurred_at, d.created_at) DESC, d.id ASC
        """
        let pageRows = try withStatement("SELECT d.id, d.source_session_id, d.title, d.occurred_at, d.project_id, d.deleted_at, d.deletion_mode \(from) LIMIT ? OFFSET ?;")
        { statement -> [MeetingLibraryRow] in
            var index: Int32 = 1
            for value in predicate.bindings {
                bindArgument(statement, index, value)
                index += 1
            }
            bind(statement, index, max(0, limit))
            bind(statement, index + 1, max(0, offset))
            var rows: [MeetingLibraryRow] = []
            while try step(statement) == SQLITE_ROW {
                // 归档与另两档在**列表**里也必须分得开：只有归档还能撤销，
                // 合并成一个状态就等于把出口一起收走（旧实现正是这么做的，
                // 结果 `MeetingLibraryStatus.archived` 从来没被产出过）。
                let document = MeetingDocument(
                    id: "",
                    deletedAt: columnIsNull(statement, 5)
                        ? nil
                        : Date(timeIntervalSince1970: columnDouble(statement, 5)),
                    deletionMode: columnText(statement, 6).flatMap(MeetingDeletionMode.init(rawValue:))
                )
                rows.append(MeetingLibraryRow(
                    id: columnText(statement, 0) ?? "",
                    sessionID: columnText(statement, 1),
                    title: columnText(statement, 2) ?? "未命名会议",
                    occurredAt: columnIsNull(statement, 3) ? nil : Date(timeIntervalSince1970: columnDouble(statement, 3)),
                    projectID: columnText(statement, 4),
                    projectName: nil,
                    status: MeetingLibraryStatus(document: document),
                    hasMinutes: false, needsReviewCount: 0, openActionCount: 0
                ))
            }
            return rows
        }

        // 计数走**同一段谓词**，但不带 LIMIT——数的是全部命中行，不是当前这一页。
        var counts = try withStatement("""
        SELECT COUNT(*),
               SUM(CASE WHEN d.deleted_at IS NULL THEN 1 ELSE 0 END)
        \(from);
        """) { statement -> MeetingLibraryCounts in
            var index: Int32 = 1
            for value in predicate.bindings {
                bindArgument(statement, index, value)
                index += 1
            }
            guard try step(statement) == SQLITE_ROW else { return .zero }
            let total = Int(columnInt(statement, 0))
            let active = Int(columnInt(statement, 1))
            return MeetingLibraryCounts(
                total: total,
                byStatus: [.active: active, .deleted: total - active],
                needsReview: 0
            )
        }
        // 待核对数是**全部命中行**的合计，不是当前页的合计——
        // 翻到第二页数字就跳的话，这个计数没有意义。
        counts.needsReview = try libraryNeedsReviewTotal(predicate: predicate)

        let stats = try meetingLibraryStats(documentIDs: pageRows.map(\.id))
        let rows = pageRows.map { row -> MeetingLibraryRow in
            var row = row
            let stat = stats[row.id]
            row.hasMinutes = stat?.hasMinutes ?? false
            row.needsReviewCount = stat?.needsReview ?? 0
            row.openActionCount = stat?.openActions ?? 0
            row.projectName = row.projectID.flatMap { try? meetingProject(id: $0)?.name }
            return row
        }
        return MeetingLibraryPage(rows: rows, counts: counts, offset: offset, limit: limit)
    }

    /// 列表谓词。**翻页、计数、搜索共用这一份**，所以三者不可能对不上（MC-52）。
    private func libraryPredicate(
        query: String, projectID: String?, includesArchived: Bool
    ) -> (sql: String, bindings: [SQLArgument]) {
        var sql = ""
        var bindings: [SQLArgument] = []
        if !includesArchived {
            sql += " AND d.deleted_at IS NULL"
        }
        if let projectID {
            sql += " AND d.project_id = ?"
            bindings.append(.text(projectID))
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            // 标题与项目名参与搜索；转录正文不进这一层——那是 MA-15 全文检索的活，
            // 两条路径的代价和口径都不一样，混在一起就没法分别归因。
            sql += " AND (d.title LIKE ? ESCAPE '\\' OR COALESCE(p.name, '') LIKE ? ESCAPE '\\')"
            let pattern = "%" + Self.likeEscape(trimmed) + "%"
            bindings.append(.text(pattern))
            bindings.append(.text(pattern))
        }
        return (sql, bindings)
    }

    /// 全部命中会议的待核对条目数。**与列表同一段谓词**，所以翻页不会让数字跳。
    private func libraryNeedsReviewTotal(predicate: (sql: String, bindings: [SQLArgument])) throws -> Int {
        try withStatement("""
        SELECT COALESCE(SUM(t.needs), 0) FROM (
          SELECT (
            SELECT COUNT(*) FROM minutes_item i
            JOIN minutes m ON m.id = i.minutes_id
            JOIN session s ON s.id = m.session_id
            WHERE s.id = d.source_session_id
              AND m.status = 'ready' AND m.body IS NOT NULL
              AND (i.verdict IS NULL OR i.verdict <> 'supported')
          ) AS needs
          FROM meeting_document d LEFT JOIN meeting_project p ON p.id = d.project_id
          WHERE 1 = 1 \(predicate.sql)
        ) t;
        """) { statement -> Int in
            var index: Int32 = 1
            for value in predicate.bindings {
                bindArgument(statement, index, value)
                index += 1
            }
            guard try step(statement) == SQLITE_ROW else { return 0 }
            return Int(columnInt(statement, 0))
        }
    }

    private struct MeetingLibraryStat {
        var hasMinutes: Bool
        var needsReview: Int
        var openActions: Int
    }

    private func meetingLibraryStats(documentIDs: [String]) throws -> [String: MeetingLibraryStat] {
        guard !documentIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: documentIDs.count).joined(separator: ", ")
        return try withStatement("""
        SELECT COALESCE(d.id, ''),
               MAX(CASE WHEN m.status = 'ready' AND m.body IS NOT NULL THEN 1 ELSE 0 END),
               SUM(CASE WHEN i.kind IS NOT NULL AND (i.verdict IS NULL OR i.verdict <> 'supported') THEN 1 ELSE 0 END),
               SUM(CASE WHEN i.kind = 'action' AND e.status IS NULL THEN 1 ELSE 0 END)
        FROM meeting_document d
        LEFT JOIN session s ON s.id = d.source_session_id
        LEFT JOIN minutes m ON m.session_id = s.id
        LEFT JOIN minutes_item i ON i.minutes_id = m.id
        LEFT JOIN knowledge_execution_event e ON e.item_id = i.id AND e.valid_to IS NULL
        WHERE d.id IN (\(placeholders))
        GROUP BY d.id;
        """) { statement -> [String: MeetingLibraryStat] in
            var index: Int32 = 1
            for value in documentIDs.sorted() {
                bind(statement, index, value)
                index += 1
            }
            var result: [String: MeetingLibraryStat] = [:]
            while try step(statement) == SQLITE_ROW {
                result[columnText(statement, 0) ?? ""] = MeetingLibraryStat(
                    hasMinutes: columnInt(statement, 1) != 0,
                    needsReview: Int(columnInt(statement, 2)),
                    openActions: Int(columnInt(statement, 3))
                )
            }
            return result
        }
    }

    /// 一次读取、整体提交的详情快照（MC-50）。
    ///
    /// 纪要、转录、条目**同一次读出来**。分三次到齐再拼的话，
    /// 中间那一瞬用户看到的是"有标题没内容"的半成品，
    /// 而标题来自 A、内容来自 B 的组合比空着更糟。
    public func meetingReviewSnapshot(documentID: String) throws -> MeetingReviewSnapshot? {
        guard let document = try meetingDocument(id: documentID) else { return nil }
        let status = MeetingLibraryStatus(document: document)
        let page = try knowledgeItems(
            filter: KnowledgeItemFilter(documentIDs: [documentID]),
            scope: MeetingKnowledgeScope(documentIDs: [documentID], includesArchived: true),
            limit: 500,
            offset: 0
        )
        var body: String?
        var transcript: [String] = []
        if let sessionID = document.sourceSessionID {
            let minutes = try acceptedMinutes(sessionID: sessionID) ?? latestUsableMinutes(sessionID: sessionID)
            body = minutes?.body
            transcript = try lines(sessionID: sessionID).map(\.text)
        }
        return MeetingReviewSnapshot(
            documentID: document.id,
            title: document.title ?? "未命名会议",
            occurredAt: document.occurredAt,
            status: status,
            minutesBody: body,
            transcriptLines: transcript,
            items: page.items
        )
    }

    /// `LIKE` 的通配符要转义，否则用户搜「100%」会变成匹配一切。
    private static func likeEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

// MARK: - 用户编辑纪要（MA-11 / MC-46～MC-48）
//
// 改纪要 = **写一个新版本**，不是覆盖旧版。覆盖写会让"AI 原来写了什么"
// 永远查不到（MC-48），撤销也无从谈起（MC-47）。
extension SessionStore {
    /// 用户改纪要正文。返回新版本。
    ///
    /// 条目处理有两条硬规则：
    /// - **正文里还认得出的原条目照搬，引用照搬**——用户改的是周边文字，
    ///   这条结论一字未动，那它对原句的引用仍然成立；
    /// - **用户新写的句子不继承任何引用**（MC-47「不误恢复成 AI 原文」的另一半）：
    ///   把 AI 的引用挂到用户自己写的话上，等于替用户伪造出处。
    @discardableResult
    public func saveUserMinutesEdit(
        sessionID: String,
        editingMinutesID: String,
        body: String
    ) throws -> MinutesVersion {
        guard let source = try minutesVersion(id: editingMinutesID) else {
            throw SessionStoreError.statementFailed("找不到要改的这一版纪要")
        }
        guard source.sessionID == sessionID else {
            throw SessionStoreError.statementFailed("这一版不属于这场会议")
        }
        guard source.status == .ready else {
            throw SessionStoreError.statementFailed("这一版还没整理出正文，没法改")
        }
        if try rejectLateMinutesIfMeetingDeleted(minutesID: editingMinutesID) {
            throw SessionStoreError.statementFailed("这场会议已归档或删除，改动没有写入")
        }

        let newID = UUID().uuidString
        let now = Date()
        let normalizedBody = KnowledgeIdentity.normalized(body)
        // 没动过几个字就仍然算 AI 整理；动过就是"你改过"。
        let origin: MinutesBodyOrigin = KnowledgeIdentity.normalized(source.body ?? "") == normalizedBody
            ? source.bodyOrigin
            : .userEdited

        var version = 0
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
            try withStatement("""
            INSERT INTO minutes (
                id, session_id, version, status, body, model, prompt_chars, is_latest, is_accepted,
                attempts, failure_reason, lease_until, created_at, is_legacy_import,
                snapshot_id, body_origin, parent_minutes_id
            ) VALUES (?, ?, ?, 'ready', ?, ?, ?, 1, 0, 0, NULL, NULL, ?, 0, ?, ?, ?);
            """) { statement in
                bind(statement, 1, newID)
                bind(statement, 2, sessionID)
                bind(statement, 3, version)
                bind(statement, 4, body)
                bind(statement, 5, source.model)
                bind(statement, 6, source.promptChars)
                bind(statement, 7, now.timeIntervalSince1970)
                // 沿用同一份来源快照：改的是措辞，不是"换了一批原句重新理解"。
                bind(statement, 8, source.snapshotID)
                bind(statement, 9, origin.rawValue)
                bind(statement, 10, editingMinutesID)
                try step(statement)
            }
            try carryOverItemsLocked(
                from: editingMinutesID, to: newID, normalizedBody: normalizedBody
            )
            try enqueueSearchIndex(sessionID: sessionID, sourceKind: SearchIndexOp.minutesKind, sourceID: newID)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }

        guard let stored = try minutesVersion(id: newID) else {
            throw SessionStoreError.statementFailed("新版本没有写进去")
        }
        return stored
    }

    /// 撤销一次编辑：拿回被改那一版的正文，**仍然写一个新版本**。
    ///
    /// 不做"删掉这一版"——删了就说不清用户当时看到过什么（MC-47）。
    public func undoMinutesEdit(minutesID: String) throws -> MinutesVersion? {
        guard let current = try minutesVersion(id: minutesID) else { return nil }
        guard let parentID = current.parentMinutesID, let parent = try minutesVersion(id: parentID) else {
            return nil
        }
        // `bodyOrigin` 记的是**内容出处**，不是动作来源：撤销之后正文与 AI 原文
        // 逐字相同，标成"你改过"是假的。这一版是撤销产生的，由 `parentMinutesID`
        // 与血缘链如实记录，不需要靠出处字段去暗示。
        return try saveUserMinutesEdit(
            sessionID: current.sessionID,
            editingMinutesID: parentID,
            body: parent.body ?? ""
        )
    }

    /// 这一版是从哪一版改来的。空数组表示它就是第一版。
    public func minutesEditLineage(minutesID: String) throws -> [MinutesVersion] {
        var chain: [MinutesVersion] = []
        var cursor: String? = minutesID
        // 血缘是人写的，改一次多一跳；防御性上限避免脏数据造成死循环。
        var guardCounter = 0
        while let id = cursor, guardCounter < 64 {
            guard let version = try minutesVersion(id: id) else { break }
            chain.append(version)
            cursor = version.parentMinutesID
            guardCounter += 1
        }
        return chain.reversed()
    }

    /// 把仍然认得出的条目连同锚点搬到新版本。
    private func carryOverItemsLocked(from: String, to: String, normalizedBody: String) throws {
        // 元组顺序与解包顺序必须一致：(itemID, localID, kind, text, verdict)。
        let carried = try withStatement("""
        SELECT id, local_id, kind, text, verdict FROM minutes_item
        WHERE minutes_id = ? ORDER BY sort_order ASC;
        """) { statement -> [(itemID: String, localID: String, kind: String, text: String, verdict: String?)] in
            bind(statement, 1, from)
            var rows: [(itemID: String, localID: String, kind: String, text: String, verdict: String?)] = []
            while try step(statement) == SQLITE_ROW {
                rows.append((
                    itemID: columnText(statement, 0) ?? "",
                    localID: columnText(statement, 1) ?? "",
                    kind: columnText(statement, 2) ?? "",
                    text: columnText(statement, 3) ?? "",
                    verdict: columnText(statement, 4)
                ))
            }
            return rows
        }
        var sortOrder = 0
        for (itemID, localID, kind, text, verdict) in carried {
            // 正文里已经没有这句话了，它就不是这一版的条目了。
            // 留着它会得到一个"结论还在、但正文里找不到"的条目。
            guard normalizedBody.contains(KnowledgeIdentity.normalized(text)) else { continue }
            let newItemID = UUID().uuidString
            try withStatement("""
            INSERT INTO minutes_item (id, minutes_id, local_id, kind, text, verdict, sort_order)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """) { statement in
                bind(statement, 1, newItemID)
                bind(statement, 2, to)
                bind(statement, 3, localID)
                bind(statement, 4, kind)
                bind(statement, 5, text)
                bind(statement, 6, verdict)
                bind(statement, 7, sortOrder)
                try step(statement)
            }
            // 引用照搬：这句话一字未改，它对原句的引用仍然成立。
            try withStatement("""
            INSERT INTO minutes_evidence
              (id, item_id, unit_id, line_id, revision_id, snapshot_id, speaker_label, t_start, verification)
            SELECT lower(hex(randomblob(16))), ?, unit_id, line_id, revision_id, snapshot_id,
                   speaker_label, t_start, verification
            FROM minutes_evidence WHERE item_id = ?;
            """) { statement in
                bind(statement, 1, newItemID)
                bind(statement, 2, itemID)
                try step(statement)
            }
            sortOrder += 1
        }
    }
}
