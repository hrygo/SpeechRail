import Foundation
import SQLite3

// `SessionStore` 的 MA 域实现：用户编辑纪要（MA-11）。
// 纯搬移自主文件；共享的 SQLite 薄封装见 `SessionStoreSQLite.swift`。

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
        body: String,
        origin originOverride: MinutesBodyOrigin? = nil
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
        let origin: MinutesBodyOrigin = originOverride ?? (
            KnowledgeIdentity.normalized(source.body ?? "") == normalizedBody
                ? source.bodyOrigin
                : .userEdited
        )

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

    /// 补一段**用户自己写的话**（验收 2 的第四档来源）。
    ///
    /// 与 `saveUserMinutesEdit` 的区别在**出处**，不在动作：
    /// 改 AI 原来写的是「你改过」，补一段 AI 从没写过的内容是「你补充」。
    /// 两者都**不继承引用**——补写的话没有转录来源，把邻句的引用挂上去
    /// 等于替用户伪造出处（方案 §302：用户新增的事实若没有转录来源，
    /// 标为"用户补充"，不从邻句继承引用）。
    ///
    /// 单独记这一档不是为了好看：`MinutesBodyOrigin.userSupplement` 此前
    /// **没有任何代码路径能产出它**——枚举有、标题有、`isUserAuthored` 收录了它、
    /// 复核界面还会渲染「这段是你补充的」，但用户补不出这段文字。
    /// 验收 2 要求区分的四档来源里，最后一档是空的。
    @discardableResult
    public func saveUserSupplement(
        sessionID: String,
        editingMinutesID: String,
        supplement: String
    ) throws -> MinutesVersion {
        let trimmed = supplement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SessionStoreError.statementFailed("补充不能是空的")
        }
        guard let source = try minutesVersion(id: editingMinutesID) else {
            throw SessionStoreError.statementFailed("找不到要补充的那一版纪要")
        }
        let base = (source.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // 标题写清楚这是谁说的：混进 AI 正文里不加标记，
        /// 三个月后没人分得清哪段是会议结论、哪段是自己加的。
        let block = "## 你补充的说明\n\n" + trimmed
        let body = base.isEmpty ? block : base + "\n\n" + block
        return try saveUserMinutesEdit(
            sessionID: sessionID,
            editingMinutesID: editingMinutesID,
            body: body,
            origin: .userSupplement
        )
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
