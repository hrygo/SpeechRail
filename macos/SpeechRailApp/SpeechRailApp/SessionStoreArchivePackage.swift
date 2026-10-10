import Foundation
import SQLite3

// `SessionStore` 的 MA 域实现：知识归档包导出与导入（MA-19）。
// 纯搬移自主文件；共享的 SQLite 薄封装见 `SessionStoreSQLite.swift`。

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
                    cancel_requested_at, candidate_json, review_json, coverage_json,
                    body_origin, parent_minutes_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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

                    // 出处与血缘（MA-11）。漏掉这两列**不会报错**——`body_origin` 有列默认值
                    // `'ai'`、`parent_minutes_id` 可空——但用户改过或补写过的正文会被悄悄
                    // 标成「AI 整理」，且「撤销一次编辑」在往返之后失效。往返必须原样保真，
                    // 否则用户已经付出过的成本在一次导出里消失。
                    bind(statement, 22, minutes.bodyOrigin)
                    bind(statement, 23, minutes.parentMinutesID)
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
    func markAnchorsWithoutSourceForReview() throws -> Int {
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
