import Foundation
import SQLite3

// `SessionStore` 的 MA 域实现：项目、标签与结构化事项投影（MA-13）。
// 纯搬移自主文件；共享的 SQLite 薄封装见 `SessionStoreSQLite.swift`。

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

        // 执行状态挂在**稳定 key** 上，`minutes_item` 里没有这一列，SQL 算不出来。
        // 所以这里一次把候选会议的执行事件读回来，在 Swift 里按 key 归并，
        // 顺便让本页每一条都带上负责人和期限——只给一句正文不叫"列出未完成事项"。
        let executions = try latestExecutionStates(documentIDs: Set(all.map(\.documentID)))

        // 「未完成」= 没有执行事件，或当前状态是未完成／受阻。已完成、已放弃都不算。
        // 谓词放在计数**之前**：总数和列表必须来自同一批行，否则又是"只给 top10 却称全部"。
        var matched = all
        if filter.openOnly {
            matched = all.filter { row in
                guard row.kind == "action" else { return true }
                return isOpenAction(
                    documentID: row.documentID, kind: row.kind, text: row.text,
                    executions: executions
                )
            }
        }

        var disputedCache: [String: Set<String>] = [:]
        var byKind: [String: Int] = [:]
        var needsReviewCount = 0
        var disputedCount = 0
        for row in matched {
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
            // 用 `matched` 而不是 `all`：`openOnly` 滤掉的是行，总数必须跟着一起少，
            // 否则标题写"共 N 条"而列表翻到底也翻不满 N 条（MC-56）。
            total: matched.count,
            byKind: byKind,
            needsReview: needsReviewCount,
            disputed: disputedCount
        )

        // 第二遍：只为本页取正文与锚点。
        let pageRows = matched.dropFirst(offset).prefix(max(0, limit))
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
                occurredAt: row.occurredAt.map { Date(timeIntervalSince1970: $0) },
                execution: executions[KnowledgeIdentity.key(
                    documentID: row.documentID, kind: row.kind, text: row.text
                )]
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
        // `openOnly` 不在这里拼：执行状态按稳定 key 索引，SQL 侧没有这一列，
        // 硬拼只能退回 `item_id`，而纪要重新生成会换掉 `item_id`，用户标过的
        // "已完成"就会整批复活（MC-53）。过滤放在 `knowledgeItems` 里按 key 做。
        return (sql, bindings)
    }

    /// 这一条行动项是不是还开着。
    ///
    /// **没有事件算开着**：会上定了就是定了，只是没人更新进度；把它藏起来等于
    /// 让人重新问一遍会议到底定了什么。已放弃不算——用户已经决定不做了，
    /// 列进待办是在制造假待办。
    private func isOpenAction(
        documentID: String,
        kind: String,
        text: String,
        executions: [String: KnowledgeExecutionState]
    ) -> Bool {
        let key = KnowledgeIdentity.key(documentID: documentID, kind: kind, text: text)
        guard let status = executions[key]?.status else { return true }
        return status != .done && status != .dropped
    }

    /// 这些会议里每条行动项**当前**的执行状态，按稳定 key 索引。
    ///
    /// 排序与 `executionState(itemKey:)` 完全一致（升序读、逐条覆盖，最后留下
    /// `valid_from DESC, recorded_at DESC, id DESC` 那一条）。两边一旦分叉，
    /// "未完成清单"和详情里显示的状态就会各说各话。
    private func latestExecutionStates(
        documentIDs: Set<String>
    ) throws -> [String: KnowledgeExecutionState] {
        guard !documentIDs.isEmpty else { return [:] }
        let sorted = documentIDs.sorted()
        let placeholders = Array(repeating: "?", count: sorted.count).joined(separator: ", ")
        return try withStatement("""
        SELECT item_key, kind, status, owner_text, due_text, due_date, valid_from, recorded_at
        FROM knowledge_execution_event
        WHERE document_id IN (\(placeholders))
        ORDER BY valid_from ASC, recorded_at ASC, id ASC;
        """) { statement -> [String: KnowledgeExecutionState] in
            for (offset, value) in sorted.enumerated() {
                bind(statement, Int32(offset + 1), value)
            }
            var latest: [String: KnowledgeExecutionState] = [:]
            while try step(statement) == SQLITE_ROW {
                let key = columnText(statement, 0) ?? ""
                guard !key.isEmpty else { continue }
                latest[key] = KnowledgeExecutionState(
                    itemKey: key,
                    kind: columnText(statement, 1) ?? "",
                    status: ActionExecutionStatus(rawValue: columnText(statement, 2) ?? "") ?? .open,
                    ownerText: columnText(statement, 3),
                    dueText: columnText(statement, 4),
                    dueDate: columnIsNull(statement, 5)
                        ? nil : Date(timeIntervalSince1970: columnDouble(statement, 5 as Int32)),
                    validFrom: Date(timeIntervalSince1970: columnDouble(statement, 6 as Int32)),
                    recordedAt: Date(timeIntervalSince1970: columnDouble(statement, 7))
                )
            }
            return latest
        }
    }
}
