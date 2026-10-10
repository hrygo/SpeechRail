import Foundation
import SQLite3

// `SessionStore` 的 MA 域实现：知识范围、归档与删除（MA-18）。
// 纯搬移自主文件；共享的 SQLite 薄封装见 `SessionStoreSQLite.swift`。

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
    static func visibilityClause(scope: MeetingKnowledgeScope, documentAlias: String = "d") -> (sql: String, bindings: [SQLArgument]) {
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
    ///
    /// FTS 不可用时返回空：调用方（删除两入口）不能区分"没有条目"与"我没看"，
    /// 但 FTS 不可用时 `enqueueSearchIndex` 同样是空操作，索引里本来就没有东西，
    /// 所以空在这里恰好是正确答案。想确认 FTS 可用性的一方查 `searchIndexStatus`。
    func indexedSearchEntries(sessionID: String?) throws -> [(String, String)] {
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
