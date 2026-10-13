import Foundation
import SQLite3

// `SessionStore` 的 MA 域实现：跨会议证据取数（MA-17）。
// 纯搬移自主文件；共享的 SQLite 薄封装见 `SessionStoreSQLite.swift`。

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
            needsReview: retrieval.evidence.filter { !$0.isEstablishedFact },
            // 上面那批只取了前 200 条。总数必须一起带出去：否则命中更多时，
            // 界面只能拿"列出来的这些"当成全部，正是 MC-52 点名要防的失败形态。
            totalMatched: retrieval.totalMatched
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
