import Foundation
import SQLite3

// `SessionStore` 的 MA 域实现：行动生命周期与决策演进（MA-14）。
// 纯搬移自主文件；共享的 SQLite 薄封装见 `SessionStoreSQLite.swift`。

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

    func executionState(itemKey: String, asOfValidTime date: Date?) throws -> KnowledgeExecutionState? {
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
