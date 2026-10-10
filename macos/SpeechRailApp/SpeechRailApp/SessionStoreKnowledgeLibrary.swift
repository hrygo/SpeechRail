import Foundation
import SQLite3

// `SessionStore` 的 MA 域实现：会议知识库列表与详情快照（MA-12）。
// 纯搬移自主文件；共享的 SQLite 薄封装见 `SessionStoreSQLite.swift`。

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
        // 排序**只进分页查询**：计数与"全部命中行的待核对数"共用同一段谓词，
        // 但它们不排序。把 ORDER BY 连同它的绑定塞进 `source` 的话，
        // 那两条查询就会少绑一个参数——而 COUNT 不会因此报错，只会静默算错。
        let order = libraryOrder(query: query)
        let source = """
        FROM meeting_document d LEFT JOIN meeting_project p ON p.id = d.project_id
        WHERE 1 = 1 \(predicate.sql)
        """
        var from = source
        if !order.sql.isEmpty {
            from += "\nORDER BY \(order.sql)"
        }
        let pageRows = try withStatement("SELECT d.id, d.source_session_id, d.title, d.occurred_at, d.project_id, d.deleted_at, d.deletion_mode \(from) LIMIT ? OFFSET ?;")
        { statement -> [MeetingLibraryRow] in
            var index: Int32 = 1
            for value in predicate.bindings {
                bindArgument(statement, index, value)
                index += 1
            }
            for value in order.bindings {
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
        \(source);
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
        // 标签按文档批量取，不在行循环里逐个查——一页 50 场就是 50 次查询。
        let tagsByDocument = try meetingLibraryTags(documentIDs: pageRows.map(\.id))
        // 证据片段只在**真的搜了**的时候去取：空查询下每行都挂一句原文，
        // 那不是证据，是噪声。
        let excerpts = try meetingLibraryMatchExcerpts(
            sessionIDs: pageRows.compactMap(\.sessionID),
            query: query,
            includesArchived: includesArchived
        )
        let rows = pageRows.map { row -> MeetingLibraryRow in
            var row = row
            let stat = stats[row.id]
            row.hasMinutes = stat?.hasMinutes ?? false
            row.needsReviewCount = stat?.needsReview ?? 0
            row.openActionCount = stat?.openActions ?? 0
            row.projectName = row.projectID.flatMap { try? meetingProject(id: $0)?.name }
            row.matchExcerpt = row.sessionID.flatMap { excerpts[$0] }
            row.tags = tagsByDocument[row.id] ?? []
            return row
        }
        return MeetingLibraryPage(rows: rows, counts: counts, offset: offset, limit: limit)
    }

    /// 一页文档的标签，`documentID -> [标签]`。一次查完，不在行循环里逐个查。
    private func meetingLibraryTags(documentIDs: [String]) throws -> [String: [String]] {
        guard !documentIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: documentIDs.count).joined(separator: ", ")
        return try withStatement("""
        SELECT document_id, tag FROM meeting_document_tag
        WHERE document_id IN (\(placeholders))
        ORDER BY document_id ASC, tag ASC;
        """) { statement -> [String: [String]] in
            var index: Int32 = 1
            for id in documentIDs {
                bind(statement, index, id)
                index += 1
            }
            var result: [String: [String]] = [:]
            while try step(statement) == SQLITE_ROW {
                let documentID = columnText(statement, 0) ?? ""
                guard let tag = columnText(statement, 1) else { continue }
                result[documentID, default: []].append(tag)
            }
            return result
        }
    }

    /// 检索命中时的那句原文（验收 4 的「与证据」）。
    ///
    /// 口径与谓词一致：命中之后**回权威表核对**，非终稿行、未就绪纪要、
    /// 已删会话都不算数（MC-62）。**优先给转录原话**——那才是依据；
    /// 拿纪要正文当证据等于拿结论证明结论，只在转录没命中时兜底。
    private func meetingLibraryMatchExcerpts(
        sessionIDs: [String],
        query: String,
        includesArchived: Bool
    ) throws -> [String: String] {
        guard !sessionIDs.isEmpty else { return [:] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }

        var excerpts: [String: String] = [:]
        let match = Self.fts5Available
            ? KnowledgeSearchTokenizer.matchExpression(for: trimmed)
            : nil

        if let match {
            let placeholders = Array(repeating: "?", count: sessionIDs.count).joined(separator: ", ")
            // 归档件在归档时索引行就被物理清掉了；显式包含归档时不去 tombstone 过滤。
            let tombstone = includesArchived ? "" : " AND (d.id IS NULL OR d.deleted_at IS NULL)"
            let sql = """
            SELECT knowledge_fts.session_id,
                   CASE WHEN knowledge_fts.source_kind = 'line' THEN kl.text ELSE km.body END
            FROM knowledge_fts
            JOIN session ks ON ks.id = knowledge_fts.session_id
            LEFT JOIN line kl ON knowledge_fts.source_kind = 'line'
                              AND kl.id = knowledge_fts.source_id
            LEFT JOIN minutes km ON knowledge_fts.source_kind = 'minutes'
                                 AND km.id = knowledge_fts.source_id
            LEFT JOIN meeting_document d ON d.source_session_id = ks.id
            WHERE knowledge_fts MATCH ?
              AND knowledge_fts.session_id IN (\(placeholders))
              AND (knowledge_fts.source_kind <> 'line'
                   OR (kl.id IS NOT NULL AND kl.status = 'final'))
              AND (knowledge_fts.source_kind <> 'minutes'
                   OR (km.id IS NOT NULL AND km.status = 'ready'))
              \(tombstone)
            ORDER BY CASE knowledge_fts.source_kind WHEN 'line' THEN 0 ELSE 1 END,
                     knowledge_fts.session_id;
            """
            try withStatement(sql) { statement in
                var index: Int32 = 1
                bind(statement, index, match)
                index += 1
                for sessionID in sessionIDs {
                    bind(statement, index, sessionID)
                    index += 1
                }
                while try step(statement) == SQLITE_ROW {
                    let sessionID = columnText(statement, 0) ?? ""
                    // 转录行排在纪要行前面，所以"第一个赢"就是"原话优先"。
                    guard !sessionID.isEmpty, excerpts[sessionID] == nil else { continue }
                    guard let snippet = Self.matchSnippet(
                        columnText(statement, 1) ?? "", query: trimmed
                    ) else { continue }
                    excerpts[sessionID] = snippet
                }
            }
        }

        // 没有全文索引、或索引里没有这场会（归档件）时，回权威表找原话——
        // 与 `libraryPredicate` 的回退条件保持一致，两边不会给出不同的答案。
        if match == nil || includesArchived {
            let missing = sessionIDs.filter { excerpts[$0] == nil }
            guard !missing.isEmpty else { return excerpts }
            let placeholders = Array(repeating: "?", count: missing.count).joined(separator: ", ")
            let pattern = "%" + Self.likeEscape(trimmed) + "%"
            try withStatement("""
            SELECT l.session_id, l.text
            FROM line l
            WHERE l.status = 'final' AND l.text LIKE ? ESCAPE '\\'
              AND l.session_id IN (\(placeholders))
            ORDER BY l.session_id, l.ordinal;
            """) { statement in
                var index: Int32 = 1
                bind(statement, index, pattern)
                index += 1
                for sessionID in missing {
                    bind(statement, index, sessionID)
                    index += 1
                }
                while try step(statement) == SQLITE_ROW {
                    let sessionID = columnText(statement, 0) ?? ""
                    guard excerpts[sessionID] == nil else { continue }
                    guard let snippet = Self.matchSnippet(
                        columnText(statement, 1) ?? "", query: trimmed
                    ) else { continue }
                    excerpts[sessionID] = snippet
                }
            }
        }
        return excerpts
    }

    /// 把命中的正文裁成一行可读的片段。
    ///
    /// 词项是二元组，命中位置常常对不上字面（查「会议室」命中的是「会议」），
    /// 所以先找**字面出现**的第一个词项、围绕它取窗口；找不到就从头取。
    /// 正文为空或裁完只剩空白时返回 nil——**宁可没有，也不要凑一句像证据的话**。
    private static func matchSnippet(
        _ body: String,
        query: String,
        limit: Int = 120
    ) -> String? {
        let flat = body
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return nil }

        // 用小写副本定位：长度一一对应，偏移量可以直接拿去切原文。
        let lowered = flat.lowercased()
        let anchor = KnowledgeSearchTokenizer.queryTerms(for: query)
            .lazy
            .compactMap { lowered.range(of: $0)?.lowerBound }
            .min()
        let characters = Array(flat)
        let center = anchor.map { lowered.distance(from: lowered.startIndex, to: $0) } ?? 0
        let start = max(0, min(characters.count, center - limit / 3))
        let end = min(characters.count, start + limit)
        guard end > start else { return nil }
        let prefix = start > 0 ? "…" : ""
        let suffix = end < characters.count ? "…" : ""
        let snippet = (prefix + String(characters[start..<end]) + suffix)
            .trimmingCharacters(in: .whitespaces)
        return snippet.isEmpty ? nil : snippet
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
            // 标题、项目名**和正文**都参与搜索（MA-15 / MC-54 / MC-75）。
            //
            // 这里曾经只搜标题与项目名，注释写着"转录正文不进这一层，那是
            // MA-15 全文检索的活"。可 MA-15 的能力只落在 store 上，搜索框
            // 够不到它——用户在库里打一个正文里出现过的词，得到"没有匹配的会议"。
            // 交付了却用不上，等于没交付（MC-75 要求离线关键词搜索真的可用）。
            //
            // 两条路径的代价仍然分开：LIKE 认标题/项目名且是有界回退，
            // FTS5 认正文并按 `KnowledgeSearchTokenizer` 同一套分词走。
            // 但**谓词只有这一份**，所以翻页、计数、筛选不会各说各话（MC-52）。
            var branches = [
                "d.title LIKE ? ESCAPE '\\'",
                "COALESCE(p.name, '') LIKE ? ESCAPE '\\'"
            ]
            let pattern = "%" + Self.likeEscape(trimmed) + "%"
            bindings.append(.text(pattern))
            bindings.append(.text(pattern))
            // 正文走全文索引。索引不可用、或查询没有有效词项时不加这一支，
            // 由下面的权威表 LIKE 兜底，而不是拿"零结果"冒充"库里确实没有"。
            let match = Self.fts5Available
                ? KnowledgeSearchTokenizer.matchExpression(for: trimmed)
                : nil
            if let match {
                // 命中之后仍要回权威表核对，与 `searchKnowledgeFullText` 同一口径：
                // 索引里残留的已删行、非终稿行、未就绪纪要都不能把会议带出来
                // （MC-62：索引迟到不复活旧来源）。
                branches.append("""
                EXISTS (
                  SELECT 1 FROM knowledge_fts
                  JOIN session ks ON ks.id = knowledge_fts.session_id
                  LEFT JOIN line kl ON knowledge_fts.source_kind = 'line'
                                    AND kl.id = knowledge_fts.source_id
                  LEFT JOIN minutes km ON knowledge_fts.source_kind = 'minutes'
                                       AND km.id = knowledge_fts.source_id
                  WHERE knowledge_fts.session_id = d.source_session_id
                    AND knowledge_fts MATCH ?
                    AND (knowledge_fts.source_kind <> 'line'
                         OR (kl.id IS NOT NULL AND kl.status = 'final'))
                    AND (knowledge_fts.source_kind <> 'minutes'
                         OR (km.id IS NOT NULL AND km.status = 'ready'))
                )
                """)
                bindings.append(.text(match))
            }
            // 权威表的有界 LIKE 回退，**只在两种情况下需要**：
            // 归档件的索引行在归档时就清掉了，"显式包含归档"要能搜回来只能靠它；
            // 没有 FTS5 或查询无有效词项时，全文那一支根本不存在。
            // 平时不挂这一支：`LIKE '%…%'` 用不上索引，扫全库换取一个用不上的分支不划算。
            if includesArchived || match == nil {
                branches.append("""
                EXISTS (
                  SELECT 1 FROM line bl
                  WHERE bl.session_id = d.source_session_id
                    AND bl.status = 'final' AND bl.text LIKE ? ESCAPE '\\'
                )
                """)
                bindings.append(.text(pattern))
                branches.append("""
                EXISTS (
                  SELECT 1 FROM minutes bm
                  WHERE bm.session_id = d.source_session_id
                    AND bm.status = 'ready' AND bm.body IS NOT NULL
                    AND bm.body LIKE ? ESCAPE '\\'
                )
                """)
                bindings.append(.text(pattern))
            }
            sql += " AND (" + branches.joined(separator: " OR ") + ")"
        }
        return (sql, bindings)
    }

    /// 搜索时的排序：**标题命中的排前面**，其余仍按时间倒序（总账第 9 条）。
    ///
    /// 此前排序恒为 `COALESCE(occurred_at, created_at) DESC`。用户搜"灰度"，
    /// 最想要的是那场**就叫《灰度发布评审》**的会，而不是上周某场正文里
    /// 碰巧提了一次灰度的会——后者时间更近，于是一直排在前面，
    /// 用户只能一页页翻过去找。
    ///
    /// **只做标题优先，不做通用打分**，两个理由：
    /// 一是标题是用户自己起的名字，是"这场就是我要找的那场"最强的信号，
    /// 而且它**可解释**——排在前面的理由用户一眼能懂；
    /// 二是通用 BM25 在这套分词下并不划算：索引里对中文同时写单字与二元组
    /// （见 `KnowledgeSearchTokenizer`），单字的 IDF 几乎没有区分度，
    /// 打出来的分差主要来自二元组命中数，那不如直接按标题命中与否分层。
    ///
    /// 空查询时返回空子句，排序保持原样——不搜东西的时候按时间倒序是对的。
    private func libraryOrder(query: String) -> (sql: String, bindings: [SQLArgument]) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", []) }
        let pattern = "%" + Self.likeEscape(trimmed) + "%"
        return (
            """
            (CASE WHEN d.title LIKE ? ESCAPE '\\' THEN 0 ELSE 1 END),
            COALESCE(d.occurred_at, d.created_at) DESC, d.id ASC
            """,
            [.text(pattern)]
        )
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
        var minutesVersionID: String?
        if let sessionID = document.sourceSessionID {
            let minutes = try acceptedMinutes(sessionID: sessionID) ?? latestUsableMinutes(sessionID: sessionID)
            body = minutes?.body
            minutesVersionID = minutes?.id
            transcript = try lines(sessionID: sessionID).map(\.text)
        }
        return MeetingReviewSnapshot(
            documentID: document.id,
            title: document.title ?? "未命名会议",
            occurredAt: document.occurredAt,
            status: status,
            minutesBody: body,
            transcriptLines: transcript,
            items: page.items,
            minutesVersionID: minutesVersionID
        )
    }

    /// 从库里读一场会议的导出件（MA-19 / 验收 4「导出已有资料」）。
    ///
    /// **重新从库里读，不拿界面上正在显示的那份快照**：快照里的转录只有纯文本，
    /// 丢了行 id、时间与说话人，导出去就再也对不回来源。宁可多读一次库。
    ///
    /// `minutesVersionID` 是详情正在显示的那一版。传 nil 表示"没选版本"，
    /// 这时导出当前采用版——与 `MeetingReviewSnapshot` 的取法一致。
    public func meetingExportPayload(
        documentID: String,
        minutesVersionID: String? = nil
    ) throws -> SessionExportPayload? {
        guard let document = try meetingDocument(id: documentID) else { return nil }
        guard let sessionID = document.sourceSessionID else {
            // 导入的纪要允许没有会话（MC-68）。没有会话就没有转录行可导，
            // 硬造一个空 record 导出去，用户拿到的是一份看着像会议的空壳。
            return nil
        }
        guard let record = try session(id: sessionID) else { return nil }
        let minutes: MinutesVersion? = if let minutesVersionID {
            try? minutesVersion(id: minutesVersionID)
        } else {
            try acceptedMinutes(sessionID: sessionID) ?? latestUsableMinutes(sessionID: sessionID)
        }
        return SessionExportPayload(
            record: record,
            lines: try lines(sessionID: sessionID),
            speakerNames: try speakerNames(sessionID: sessionID),
            minutes: minutes
        )
    }

    /// `LIKE` 的通配符要转义，否则用户搜「100%」会变成匹配一切。
    private static func likeEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
