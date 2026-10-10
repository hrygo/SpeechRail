import Foundation
import SQLite3

// `SessionStore` 的 MA 域实现：schema 迁移（只按 `user_version` 逐级升级，失败整库回滚）。
// 纯搬移自主文件；共享的 SQLite 薄封装见 `SessionStoreSQLite.swift`。

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
      in_minutes  INTEGER NOT NULL DEFAULT 0,
      -- MC-43 粒度：用户挑出来写进纪要的那几句。NULL = 整条（迁移前行与
      -- 用户显式选「整条」都是这个值），刻意不回填——迁移前没有句子粒度，
      -- 凭空截断等于替用户改了他当时的选择。
      minutes_excerpt TEXT
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
    func migrateV1ToV2() throws {
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
    func migrateV2ToV3() throws {
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
    func migrateV3ToV4() throws {
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
    func migrateV4ToV5() throws {
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

    func migrateV5ToV6() throws {
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
    func migrateV8ToV9() throws {
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
    func migrateV9ToV10() throws {
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
    func migrateV10ToV11() throws {
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
    func migrateV11ToV12() throws {
        let columns = try tableColumnNames("meeting_document")
        if !columns.contains("deletion_mode") {
            try execute("ALTER TABLE meeting_document ADD COLUMN deletion_mode TEXT;")
        }
    }

    /// v12 → v13：给 `inner_os_exchange` 补一列"用户挑了哪几句"。
    ///
    /// MC-43 的验收是"只选择其中一句 → 只该句进入 source snapshot"，
    /// 而此前只有整条问答的布尔旗标，快照里收的是整段答案。
    ///
    /// **刻意不回填**：老行一律留 `NULL`，按整条读。那正是它们当时的语义，
    /// 而且是唯一能证实的语义——迁移无从知道用户当时想留哪半句。
    func migrateV12ToV13() throws {
        let columns = try tableColumnNames("inner_os_exchange")
        if !columns.contains("minutes_excerpt") {
            try execute("ALTER TABLE inner_os_exchange ADD COLUMN minutes_excerpt TEXT;")
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

    func migrateV7ToV8() throws {
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

    func migrateV6ToV7() throws {
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
