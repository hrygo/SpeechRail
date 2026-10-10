import Foundation
import SQLite3

// `SessionStore` 的 MA 域实现：知识变化建议（MA-14）。
// 纯搬移自主文件；共享的 SQLite 薄封装见 `SessionStoreSQLite.swift`。

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
        // **显式按时间升序**：下面把靠前的一条叫 `previous`、靠后的叫 `proposed`，
        // 这个命名必须真的对应"早"和"晚"。列表本身是时间倒序的，直接拿来分组
        // 会把新结论标成 previous——界面上就成了"旧说法取代新说法"。
        let ordered = page.items.sorted {
            let lhs = $0.occurredAt ?? .distantPast
            let rhs = $1.occurredAt ?? .distantPast
            if lhs != rhs { return lhs < rhs }
            return $0.id < $1.id
        }

        // 倒排：词项 -> 命中下标。
        var byTerm: [String: [Int]] = [:]
        for (index, item) in ordered.enumerated() {
            for term in Set(KnowledgeSearchTokenizer.indexTerms(for: item.text))
            where term.count >= 2 {
                byTerm[term, default: []].append(index)
            }
        }

        // 成对累计**共享词项的个数**，而不是"落在同一个词项的组里就报"。
        // 差别在于：「定在」「在五」这种二元组是常用搭配，只共享一个的那条
        // 往往根本不是同一件事（「发布窗口定在九月」对「预算上限定在五十万」）。
        // 报得多了，用户看两次就再也不信这个面板了。
        var sharedCount: [String: Int] = [:]
        for (_, indices) in byTerm where indices.count > 1 {
            for i in indices.indices {
                for j in indices.indices where j > i {
                    let lhs = ordered[indices[i]]
                    let rhs = ordered[indices[j]]
                    guard lhs.documentID != rhs.documentID else { continue }
                    sharedCount["\(indices[i])|\(indices[j])", default: 0] += 1
                }
            }
        }

        // 用户已经确认过替代的两边，不再作为候选拿回来问一遍（MC-57）。
        // 不确认就一直报着是安全的一侧：候选只是提醒，替代关系才是状态。
        let resolved = try confirmedSupersessionPairs()
        var proposals: [KnowledgeChangeProposal] = []
        // 按下标排序：结果与词项的字典序无关，同一份库每次打开是同一批候选。
        for key in sharedCount.keys.sorted() {
            guard sharedCount[key] ?? 0 >= Self.minimumSharedTermsForConflict else { continue }
            let parts = key.split(separator: "|").compactMap { Int($0) }
            guard parts.count == 2 else { continue }
            let lhs = ordered[parts[0]]
            let rhs = ordered[parts[1]]
            // 说法完全一致只是重复记录，不是冲突。
            guard KnowledgeIdentity.normalized(lhs.text) != KnowledgeIdentity.normalized(rhs.text) else { continue }
            guard !isResolved(lhs: lhs, rhs: rhs, pairs: resolved) else { continue }
            // 摘要里引的那句话取两条的**最长公共片段**，而不是碰巧先命中的那个二元组。
            let phrase = Self.longestSharedPhrase(lhs.text, rhs.text)
            let summary = phrase.map { "两场会都说到了「\($0)」，但说法不一样" }
                ?? "两场会的结论说法不一样，但看不出是围绕什么说的"
            proposals.append(KnowledgeChangeProposal(
                kind: .conflictAcrossMeetings,
                summary: summary,
                previousItemID: lhs.id,
                proposedItemID: rhs.id,
                previousText: lhs.text,
                proposedText: rhs.text,
                detail: conflictDetail(lhs: lhs, rhs: rhs)
            ))
            if proposals.count >= limit { return proposals }
        }
        return proposals
    }

    /// 判定"说的是同一件事"至少要共享几个词项。
    ///
    /// 1 个太松（常用搭配就够），太多会漏掉只围绕一个短词展开的分歧。
    /// 2 是当前分词下"至少有一个真正的共同话题词"的下限。
    static let minimumSharedTermsForConflict = 2

    /// 两条里最长的一段公共文字。**至少两个字**才有引用价值。
    ///
    /// 用来在摘要里点出"这两条是围绕什么说的"。按字面算而不是按词项算：
    /// 词项是单字与二元组，指不出「发布窗口」这样真正的话题。
    static func longestSharedPhrase(_ lhs: String, _ rhs: String) -> String? {
        let a = Array(KnowledgeIdentity.normalized(lhs))
        let b = Array(KnowledgeIdentity.normalized(rhs))
        guard a.count >= 2, b.count >= 2 else { return nil }
        // dp[i][j] = 以 a[i-1]、b[j-1] 结尾的公共子串长度。
        var previous = Array(repeating: 0, count: b.count + 1)
        var best = 0
        var bestEnd = 0
        for i in 1...a.count {
            var current = Array(repeating: 0, count: b.count + 1)
            for j in 1...b.count where a[i - 1] == b[j - 1] {
                let length = previous[j - 1] + 1
                current[j] = length
                if length > best {
                    best = length
                    bestEnd = i
                }
            }
            previous = current
        }
        guard best >= 2 else { return nil }
        return String(a[(bestEnd - best)..<bestEnd])
    }

    /// 已经落定替代关系的 key 对。**两个方向都算**——用户点的是
    /// 「后一条取代前一条」，读回来时两条的先后不该影响判断。
    private func confirmedSupersessionPairs() throws -> Set<[String]> {
        try withStatement("SELECT from_key, to_key FROM knowledge_supersession;") { statement -> Set<[String]> in
            var pairs: Set<[String]> = []
            while try step(statement) == SQLITE_ROW {
                let from = columnText(statement, 0) ?? ""
                let to = columnText(statement, 1) ?? ""
                guard !from.isEmpty, !to.isEmpty else { continue }
                pairs.insert([from, to].sorted())
            }
            return pairs
        }
    }

    /// 这一对是不是已经确认过取代。用**稳定 key** 比对而不是行 id：
    /// 纪要重新生成会换掉 `item.id`，按行 id 判断等于让用户确认过的事又冒出来。
    private func isResolved(
        lhs: KnowledgeEvidence,
        rhs: KnowledgeEvidence,
        pairs: Set<[String]>
    ) -> Bool {
        let lhsKey = KnowledgeIdentity.key(documentID: lhs.documentID, kind: lhs.kind, text: lhs.text)
        let rhsKey = KnowledgeIdentity.key(documentID: rhs.documentID, kind: rhs.kind, text: rhs.text)
        return pairs.contains([lhsKey, rhsKey].sorted())
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
