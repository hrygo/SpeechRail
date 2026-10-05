import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 知识归档包：选定版本导出、开放格式导入与保真往返（方案 MA-19）。
///
/// 这里钉的是四条验收：
/// - MC-48：选中 v1 时，即使库里已经有 v3，导出的仍然是 v1，找不到就明确失败；
/// - MC-65：读不到内容时明确失败，磁盘上不留下半个包；
/// - MC-66：完整归档导出再导入临时新库，版本、结论、锚点与采用指针都不漂移；
/// - MC-71：路径穿越、未知条目、超大包、同 ID 异内容都在落库前被挡住。
@MainActor
final class MeetingKnowledgeArchiveTests: XCTestCase {
    private var directory: URL?
    private var store: SessionStore?
    private var sessionID: String?
    private var snapshotID: String?

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        try await store.open()
        let record = try await store.createSession(
            SessionDraft(kind: .meeting, engineProfile: "test", audioSource: .microphone, title: "发布评审")
        )
        self.directory = directory
        self.store = store
        self.sessionID = record.id
    }

    override func tearDown() async throws {
        if let store { await store.close() }
        store = nil
        sessionID = nil
        snapshotID = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try await super.tearDown()
    }

    private func requireStore() throws -> SessionStore { try XCTUnwrap(store) }
    private func requireSessionID() throws -> String { try XCTUnwrap(sessionID) }

    /// `XCTUnwrap` 的自动闭包里不能 `await`，所以先取出来再断言。
    private func requireDocumentID() async throws -> String {
        let store = try requireStore()
        let document = try await store.meetingDocument(forSessionID: requireSessionID())
        return try XCTUnwrap(document?.id, "有转录的会议应当已经封出知识文档")
    }

    /// 造一场有转录、已封存、带结构化结论与锚点的会议，返回采过的那一版。
    @discardableResult
    private func prepareMeetingWithCitations() async throws -> MinutesVersion {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let texts = ["line-1": "下周三上线灰度。", "line-2": "预算按 3 万元算。"]
        for id in ["line-1", "line-2"] {
            let text = texts[id]!
            _ = try await store.appendLine(
                LineDraft(
                    sessionID: sessionID,
                    role: .speaker,
                    text: text,
                    source: .microphone,
                    tStart: id == "line-1" ? 0 : 10,
                    status: .final
                ),
                id: id
            )
        }
        let snapshot = try await store.sealMeetingSource(sessionID: sessionID)
        let sealedID = try XCTUnwrap(snapshot?.id, "有定稿正文就该封出快照")
        self.snapshotID = sealedID
        let snapshotID = sealedID

        let units = [
            MinutesSourceUnit(
                id: "u1", lineID: "line-1", ordinal: 1,
                speaker: "张三", text: texts["line-1"]!, startSeconds: 0
            ),
            MinutesSourceUnit(
                id: "u2", lineID: "line-2", ordinal: 2,
                speaker: "李四", text: texts["line-2"]!, startSeconds: 10
            ),
        ]
        let candidate = MinutesCandidateV2(
            title: "发布评审",
            overview: [],
            decisions: [
                .init(localID: "d1", text: "下周三上线灰度", modality: .decided, conditions: [], sourceUnitIDs: ["u1"]),
            ],
            actions: [
                .init(
                    localID: "a1", task: "整理发布清单",
                    ownerText: nil, dueExpression: nil, commitment: .proposed, sourceUnitIDs: ["u2"]
                ),
            ],
            openQuestions: [],
            confidenceNotes: ""
        )
        let encoded = try JSONEncoder().encode(candidate)
        guard case .prepared(let prepared) = MinutesCandidateCodec.prepare(
            text: String(data: encoded, encoding: .utf8) ?? "",
            units: units
        ) else {
            XCTFail("结构合法的候选应当解析成功")
            throw XCTSkip("候选构造失败")
        }

        _ = try await store.enqueueMinutes(
            sessionID: sessionID, model: nil, promptChars: 24, snapshotID: snapshotID
        )
        let claimed = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        let row = try XCTUnwrap(claimed)
        let revisionIDs = try await store.latestRevisionIDsByLine(sessionID: sessionID)
        let saved = try await store.saveMinutesCandidate(
            minutesID: row.id,
            expectedAttempts: row.attempts,
            body: prepared.body,
            model: nil,
            candidate: String(data: try JSONEncoder().encode(prepared.candidate), encoding: .utf8),
            review: String(data: try JSONEncoder().encode(prepared.report), encoding: .utf8),
            items: MinutesCandidateCodec.itemDrafts(
                for: prepared.candidate,
                report: prepared.report,
                unitsByID: Dictionary(units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
                revisionIDsByLine: revisionIDs
            ),
            snapshotID: snapshotID
        )
        XCTAssertTrue(saved)
        return row
    }

    /// 再生成一版并采用它，用来制造"库里已有更新版本"的场景。
    @discardableResult
    private func addSecondVersion() async throws -> MinutesVersion {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        _ = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 24)
        let claimed = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        let row = try XCTUnwrap(claimed)
        let saved = try await store.saveMinutesCandidate(
            minutesID: row.id,
            expectedAttempts: row.attempts,
            body: "# 第二版\n\n改口径了。",
            model: nil,
            candidate: nil,
            review: nil,
            items: [],
            snapshotID: nil
        )
        XCTAssertTrue(saved)
        let adopted = try await store.adoptMinutes(
            sessionID: sessionID, minutesID: row.id, expectedCurrentID: nil
        )
        XCTAssertTrue(adopted)
        return row
    }

    private func exportDestination() throws -> URL {
        try XCTUnwrap(directory).appendingPathComponent("exports", isDirectory: true)
    }

    // MARK: - MC-48：选定版本不被"更新版本"顶掉

    func testSelectedRevisionIsExportedEvenWhenNewerVersionExists() async throws {
        let store = try requireStore()
        let first = try await prepareMeetingWithCitations()
        let second = try await addSecondVersion()
        XCTAssertGreaterThan(second.version, first.version)

        let documentID = try await requireDocumentID()
        let payload = try await store.knowledgeArchivePayload(
            selection: KnowledgeArchiveSelection(
                documentID: documentID,
                minutesID: first.id,
                scope: .fullArchive
            )
        )
        XCTAssertEqual(payload.minutes.count, 2, "完整归档装全部版本")
        XCTAssertTrue(payload.minutes.contains { $0.id == first.id })
        XCTAssertTrue(payload.minutes.contains { $0.id == second.id })

        // 分享包只装选中的那一版，另一版不带。
        let share = try await store.knowledgeArchivePayload(
            selection: KnowledgeArchiveSelection(
                documentID: documentID,
                minutesID: first.id,
                scope: .share
            )
        )
        XCTAssertEqual(share.minutes.map(\.id), [first.id], "分享包只装选中的那一版")
        XCTAssertFalse(share.minutes.contains { $0.id == second.id })
    }

    func testExportMissingSelectionFailsWithoutWritingAnything() async throws {
        let store = try requireStore()
        let first = try await prepareMeetingWithCitations()
        let documentID = try await requireDocumentID()
        let destination = try exportDestination()

        do {
            _ = try await store.exportKnowledgeArchive(
                selection: KnowledgeArchiveSelection(
                    documentID: documentID, minutesID: "没有这一版", scope: .share
                ),
                to: destination
            )
            XCTFail("找不到选中的版本必须失败，不能退回当前展示版")
        } catch let error as KnowledgeArchiveError {
            XCTAssertEqual(error, .minutesNotFound("没有这一版"))
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "失败不该在磁盘上留下任何东西，实际：\(leftovers)")
        XCTAssertNotNil(first.id)
    }

    // MARK: - MC-65：读失败不产出空壳

    func testMinutesWithoutBodyFailsInsteadOfExportingEmptyShell() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        _ = try await prepareMeetingWithCitations()
        let documentID = try await requireDocumentID()
        // 再排一版但还没生成：库里确实存在这一行，但导不出可读的纪要。
        let queued = try await store.enqueueMinutes(
            sessionID: sessionID, model: nil, promptChars: 10
        )
        let destination = try exportDestination()

        do {
            _ = try await store.exportKnowledgeArchive(
                selection: KnowledgeArchiveSelection(
                    documentID: documentID, minutesID: queued.id, scope: .share
                ),
                to: destination
            )
            XCTFail("没有正文的版本不该被导成一个空壳")
        } catch let error as KnowledgeArchiveError {
            XCTAssertEqual(error, .minutesBodyMissing(queued.id))
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "失败不该留下半个包，实际：\(leftovers)")
    }

    func testExportRefusesToOverwriteExistingPackage() async throws {
        let store = try requireStore()
        let first = try await prepareMeetingWithCitations()
        let documentID = try await requireDocumentID()
        let destination = try exportDestination()
        let selection = KnowledgeArchiveSelection(
            documentID: documentID, minutesID: first.id, scope: .share
        )
        let package = try await store.exportKnowledgeArchive(selection: selection, to: destination)

        do {
            _ = try await store.exportKnowledgeArchive(selection: selection, to: destination)
            XCTFail("已导出的包不该被静默覆盖")
        } catch let error as KnowledgeArchiveError {
            guard case .destinationExists = error else {
                return XCTFail("应当报目标已存在，实际：\(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
    }

    // MARK: - MC-66：跨新库往返，身份不漂移

    func testFullArchiveRoundTripPreservesIdentityAndAdoptedPointer() async throws {
        let store = try requireStore()
        let first = try await prepareMeetingWithCitations()
        let second = try await addSecondVersion()
        let documentID = try await requireDocumentID()
        let package = try await store.exportKnowledgeArchive(
            selection: KnowledgeArchiveSelection(
                documentID: documentID, minutesID: second.id, scope: .fullArchive
            ),
            to: try exportDestination()
        )

        let imported = try await makeImportedStore { target in
            try await target.importKnowledgeArchive(at: package)
        }
        defer { Task { await imported.store.close() } }

        let result = try XCTUnwrap(imported.result)
        XCTAssertEqual(result.documentID, documentID, "文档 id 应当原样保留")
        XCTAssertEqual(result.selectedMinutesID, second.id, "选中的版本 id 应当原样保留")
        XCTAssertGreaterThan(result.inserted.minutes, 0)

        let versions = try await imported.store.minutesVersions(sessionID: try requireSessionID())
        XCTAssertEqual(
            Set(versions.map(\.id)),
            [first.id, second.id],
            "两个版本的 id 都应当原样保留，不重新编号"
        )
        let accepted = try await imported.store.acceptedMinutes(sessionID: try requireSessionID())
        let adopted = try XCTUnwrap(accepted)
        XCTAssertEqual(adopted.id, second.id, "采用指针应当还是原来那一版")

        let items = try await imported.store.minutesItems(minutesID: first.id)
        let originalItems = try await store.minutesItems(minutesID: first.id)
        XCTAssertEqual(
            Set(items.map(\.id)),
            Set(originalItems.map(\.id)),
            "结论条目身份不漂移"
        )
        let action = try XCTUnwrap(items.first { $0.kind == "action" })
        let originalAction = try XCTUnwrap(originalItems.first { $0.kind == "action" })
        XCTAssertEqual(action.localID, originalAction.localID, "待办的候选内编号也要保留")
        let anchor = try XCTUnwrap(action.anchors.first)
        XCTAssertEqual(anchor.quote, originalAction.anchors.first?.quote, "锚点在新库里仍要读得到封存时的原文")
        let snapshotID = try XCTUnwrap(self.snapshotID)
        let carried = try await imported.store.sourceSnapshot(id: snapshotID)
        XCTAssertEqual(carried?.id, snapshotID, "来源快照应当一起过去，来源边界不丢")
        let references = try await imported.store.verifyReferences()
        XCTAssertTrue(references.isClean, "往返之后引用不该断裂，问题：\(references.problems)")
    }

    /// **正文出处与改稿血缘必须随包往返**（MA-11 / 验收 2 的第四档与「你改过」）。
    ///
    /// `ArchiveMinutes` 带了其余每一个 minutes 列，唯独缺 schema v11 加的
    /// `body_origin` 与 `parent_minutes_id`。后果不是「少两个字段」：
    /// - `body_origin` 在库里是 `NOT NULL DEFAULT 'ai'`，漏写**不会报错**，
    ///   用户改过或补写过的正文会被标成「AI 整理」——正是这一列要防的那件事；
    /// - 血缘断了，`minutesEditLineage` 只剩一版，「撤销一次编辑」在往返后失效。
    ///
    /// 与 `testFullArchiveRoundTripPreservesIdentityAndAdoptedPointer` 的差别：
    /// 那条用的是 `saveMinutesCandidate` 造的第二版（`body_origin` 本来就是 `ai`、
    /// `parent_minutes_id` 为空），所以**恰好绕开了这两列**，一直没红。
    func testUserAuthoredOriginAndEditLineageSurviveTheRoundTrip() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let claimed = try await prepareMeetingWithCitations()
        // 夹具返回的是 `claimMinutes` 的**保存前**行，正文还是空的；
        // 要读回 `saveMinutesCandidate` 之后的那一版。
        // `XCTUnwrap` 的自动闭包里不能 await，所以先取出来再断言。
        let saved = try await store.minutesVersion(id: claimed.id)
        let first = try XCTUnwrap(saved)
        let originalBody = try XCTUnwrap(first.body)

        let edited = try await store.saveUserMinutesEdit(
            sessionID: sessionID,
            editingMinutesID: first.id,
            body: originalBody + "\n\n补一句口径。"
        )
        XCTAssertEqual(edited.bodyOrigin, .userEdited, "改了正文就该记成「你改过」")
        XCTAssertEqual(edited.parentMinutesID, first.id, "改稿必须留下它是从哪一版改来的")

        let supplemented = try await store.saveUserSupplement(
            sessionID: sessionID,
            editingMinutesID: edited.id,
            supplement: "延期到下个月。"
        )
        XCTAssertEqual(supplemented.bodyOrigin, .userSupplement, "补写就该记成「你补充」")

        let documentID = try await requireDocumentID()
        let package = try await store.exportKnowledgeArchive(
            selection: KnowledgeArchiveSelection(
                documentID: documentID, minutesID: supplemented.id, scope: .fullArchive
            ),
            to: try exportDestination()
        )

        let imported = try await makeImportedStore { target in
            try await target.importKnowledgeArchive(at: package)
        }
        defer { Task { await imported.store.close() } }

        let versions = try await imported.store.minutesVersions(sessionID: sessionID)
        let byID = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, $0) })

        let newEdited = try XCTUnwrap(byID[edited.id])
        XCTAssertEqual(
            newEdited.bodyOrigin, .userEdited,
            "用户改过的正文在往返之后被标成「AI 整理」——出处被抹掉了"
        )
        XCTAssertEqual(
            newEdited.parentMinutesID, first.id,
            "改稿血缘在往返之后断了"
        )

        let newSupplement = try XCTUnwrap(byID[supplemented.id])
        XCTAssertEqual(
            newSupplement.bodyOrigin, .userSupplement,
            "用户补写的正文在往返之后被标成「AI 整理」"
        )

        // 血缘不只是那一列：它得真的还能被走出来。
        let lineage = try await imported.store.minutesEditLineage(minutesID: supplemented.id)
        XCTAssertEqual(
            lineage.map(\.id), [first.id, edited.id, supplemented.id],
            "往返之后「这一版是从哪一版改来的」应当仍然答得出来"
        )
        let undone = try await imported.store.undoMinutesEdit(minutesID: supplemented.id)
        XCTAssertNotNil(
            undone,
            "往返之后「撤销一次编辑」失效了：用户改过的东西再也拿不回来"
        )
    }

    func testMarkdownIsReadableOnItsOwn() async throws {
        let store = try requireStore()
        let first = try await prepareMeetingWithCitations()
        let documentID = try await requireDocumentID()
        let package = try await store.exportKnowledgeArchive(
            selection: KnowledgeArchiveSelection(
                documentID: documentID, minutesID: first.id, scope: .share
            ),
            to: try exportDestination()
        )
        let markdownURL = package.appendingPathComponent(KnowledgeArchiveManifest.markdownFileName)
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)

        XCTAssertTrue(markdown.contains("发布评审"), "标题应当能被读懂")
        XCTAssertTrue(markdown.contains("下周三上线灰度"), "结论条目与引文应当在可读文件里")
        XCTAssertTrue(markdown.contains("整理发布清单"), "待办也应当在")
        for token in ["minutes_item", "minutes_evidence", "speechrail.minutes.v2", "selectedMinutesID"] {
            XCTAssertFalse(markdown.contains(token), "可读文件不该露出内部字段名：\(token)")
        }
    }

    func testReimportingSamePackageIsIdempotent() async throws {
        let store = try requireStore()
        let first = try await prepareMeetingWithCitations()
        let documentID = try await requireDocumentID()
        let package = try await store.exportKnowledgeArchive(
            selection: KnowledgeArchiveSelection(
                documentID: documentID, minutesID: first.id, scope: .fullArchive
            ),
            to: try exportDestination()
        )

        let imported = try await makeImportedStore { target in
            try await target.importKnowledgeArchive(at: package)
        }
        defer { Task { await imported.store.close() } }

        let preview = try await imported.store.previewKnowledgeArchive(at: package)
        XCTAssertTrue(preview.isSafeToImport, "同一份包再导一次不该有真冲突")
        XCTAssertTrue(
            preview.conflicts.allSatisfy(\.isIdentical),
            "库里已有的应当逐条判定为内容一致"
        )
        let again = try await imported.store.importKnowledgeArchive(at: package)
        XCTAssertEqual(again.inserted, .zero, "重复导入不该再插一遍")
        XCTAssertGreaterThan(again.skippedIdentical, 0)
    }

    // MARK: - MC-71：不安全与冲突的包在落库前被挡住

    func testPackageWithUnknownEntryIsRejected() async throws {
        let store = try requireStore()
        let first = try await prepareMeetingWithCitations()
        let documentID = try await requireDocumentID()
        let package = try await store.exportKnowledgeArchive(
            selection: KnowledgeArchiveSelection(
                documentID: documentID, minutesID: first.id, scope: .share
            ),
            to: try exportDestination()
        )
        let stray = package.appendingPathComponent("escaped.txt")
        try Data("包里多出来的条目".utf8).write(to: stray)
        defer { try? FileManager.default.removeItem(at: stray) }

        do {
            _ = try await store.previewKnowledgeArchive(at: package)
            XCTFail("包外多出来的条目不该被接受")
        } catch let error as KnowledgeArchiveError {
            guard case .entryRejected(let name) = error else {
                return XCTFail("应当报条目被拒，实际：\(error)")
            }
            XCTAssertEqual(name, "escaped.txt")
        }
    }

    func testSymlinkedEntryIsRejected() async throws {
        let store = try requireStore()
        let first = try await prepareMeetingWithCitations()
        let documentID = try await requireDocumentID()
        let package = try await store.exportKnowledgeArchive(
            selection: KnowledgeArchiveSelection(
                documentID: documentID, minutesID: first.id, scope: .share
            ),
            to: try exportDestination()
        )
        // 目录型包最主要的越界手法：把包内某个条目做成指向包外的符号链接。
        let linked = package.appendingPathComponent(KnowledgeArchiveManifest.markdownFileName)
        let outside = try XCTUnwrap(directory).appendingPathComponent("outside.md")
        try Data("包外的内容".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.removeItem(at: linked)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)

        do {
            _ = try await store.previewKnowledgeArchive(at: package)
            XCTFail("指向包外的符号链接不该被接受")
        } catch let error as KnowledgeArchiveError {
            guard case .entryRejected = error else {
                return XCTFail("应当报条目被拒，实际：\(error)")
            }
        }
    }

    func testManifestPointingOutsidePackageIsRejected() async throws {
        let store = try requireStore()
        let first = try await prepareMeetingWithCitations()
        let documentID = try await requireDocumentID()
        let package = try await store.exportKnowledgeArchive(
            selection: KnowledgeArchiveSelection(
                documentID: documentID, minutesID: first.id, scope: .share
            ),
            to: try exportDestination()
        )
        // 清单里点名一个包外的文件：读的时候必须发现"实际大小对不上"，
        // 而不是顺着这个名字去包外把文件读进来。
        let manifestURL = package.appendingPathComponent(KnowledgeArchiveManifest.manifestFileName)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(
            KnowledgeArchiveManifest.self,
            from: try Data(contentsOf: manifestURL)
        )
        manifest.files.append(KnowledgeArchiveFile(name: "../../../../etc/hosts", byteCount: 12))
        try encoder.encode(manifest).write(to: manifestURL)

        do {
            _ = try await store.previewKnowledgeArchive(at: package)
            XCTFail("清单指向包外的文件应当被拒")
        } catch let error as KnowledgeArchiveError {
            guard case .malformedPackage = error else {
                return XCTFail("应当报包不可信，实际：\(error)")
            }
        }
    }

    func testReimportKeepsUserRenamedSpeaker() async throws {
        let store = try requireStore()
        let first = try await prepareMeetingWithCitations()
        let sessionID = try requireSessionID()
        _ = try await store.renameSpeaker(sessionID: sessionID, label: "A", name: "张三")
        let documentID = try await requireDocumentID()
        let package = try await store.exportKnowledgeArchive(
            selection: KnowledgeArchiveSelection(
                documentID: documentID, minutesID: first.id, scope: .fullArchive
            ),
            to: try exportDestination()
        )

        let imported = try await makeImportedStore { target in
            try await target.importKnowledgeArchive(at: package)
        }
        defer { Task { await imported.store.close() } }

        // 用户在新库里把说话人改了名，再导一次同一个包：这已经是"同 ID 异内容"，
        // 必须报冲突并原样保留用户的改名，而不是拿包里的旧名字盖回去。
        _ = try await imported.store.renameSpeaker(sessionID: sessionID, label: "A", name: "张三改过的名字")
        let preview = try await imported.store.previewKnowledgeArchive(at: package)
        XCTAssertTrue(
            preview.realConflicts.contains { $0.kind == .speakerName },
            "用户改过的显示名要报冲突，实际：\(preview.conflicts)"
        )
        do {
            _ = try await imported.store.importKnowledgeArchive(at: package)
            XCTFail("有真冲突时不该硬导")
        } catch let error as KnowledgeArchiveError {
            guard case .identityConflict = error else {
                return XCTFail("应当报身份冲突，实际：\(error)")
            }
        }
        let names = try await imported.store.speakerNames(sessionID: sessionID)
        XCTAssertEqual(names["A"], "张三改过的名字", "被拒的导入不能覆盖用户后来改的显示名")
    }

    func testOversizedPackageIsRejectedBeforeParsing() async throws {
        let store = try requireStore()
        let first = try await prepareMeetingWithCitations()
        let documentID = try await requireDocumentID()
        let package = try await store.exportKnowledgeArchive(
            selection: KnowledgeArchiveSelection(
                documentID: documentID, minutesID: first.id, scope: .share
            ),
            to: try exportDestination()
        )
        let tight = KnowledgeArchiveFileIO.Limits(maxFileBytes: 16, maxPackageBytes: 32)
        do {
            _ = try await store.previewKnowledgeArchive(at: package, limits: tight)
            XCTFail("超过上限的包应当在解析之前就被拒")
        } catch let error as KnowledgeArchiveError {
            guard case .payloadTooLarge = error else {
                return XCTFail("应当报体积超限，实际：\(error)")
            }
        }
    }

    func testSameIdentifierWithDifferentContentIsReportedAsConflict() async throws {
        let store = try requireStore()
        let first = try await prepareMeetingWithCitations()
        let documentID = try await requireDocumentID()
        let selection = KnowledgeArchiveSelection(
            documentID: documentID, minutesID: first.id, scope: .fullArchive
        )
        let good = try await store.exportKnowledgeArchive(
            selection: selection, to: try exportDestination()
        )

        // 同一批 id，正文被改过：这是"同 ID 异内容"，不是重复导入。
        var payload = try await store.knowledgeArchivePayload(selection: selection)
        payload.minutes = payload.minutes.map { minutes in
            var copy = minutes
            copy.body = "被人改过的正文"
            return copy
        }
        let tamperedDirectory = try XCTUnwrap(directory).appendingPathComponent("tampered", isDirectory: true)
        try FileManager.default.createDirectory(at: tamperedDirectory, withIntermediateDirectories: true)
        let manifest = try await store.knowledgeArchiveManifest(selection: selection, payload: payload)
        let tampered = try KnowledgeArchiveFileIO.write(
            manifest: manifest,
            payload: payload,
            markdown: KnowledgeArchiveMarkdown.render(manifest: manifest, payload: payload),
            to: tamperedDirectory
        )

        let preview = try await store.previewKnowledgeArchive(at: tampered)
        XCTAssertFalse(preview.isSafeToImport, "同 ID 异内容必须先报冲突")
        XCTAssertTrue(
            preview.realConflicts.contains { $0.kind == .minutes && $0.id == first.id },
            "冲突要指到具体是哪个对象：\(preview.conflicts)"
        )

        do {
            _ = try await store.importKnowledgeArchive(at: tampered)
            XCTFail("有真冲突时不该硬导")
        } catch let error as KnowledgeArchiveError {
            guard case .identityConflict = error else {
                return XCTFail("应当报身份冲突，实际：\(error)")
            }
        }
        let current = try await store.minutesVersion(id: first.id)
        let body = try XCTUnwrap(current?.body)
        XCTAssertFalse(body.contains("被人改过的正文"), "被拒的导入不能改动用户现有文档")
        XCTAssertNotNil(good)
    }

    // MARK: - 辅助

    private func makeImportedStore(
        _ body: (SessionStore) async throws -> KnowledgeArchiveImportResult
    ) async throws -> (store: SessionStore, result: KnowledgeArchiveImportResult) {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-archive-target-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = SessionStore(directory: target)
        try await store.open()
        let result = try await body(store)
        return (store, result)
    }

    // MARK: - 执行状态随包往返（MA-14 / MA-19 补齐）

    /// 用户在待办上标过的状态、换过的负责人，导出再导入之后必须还在。
    /// 少了这一步，往返一次就把用户已经付出过的成本清零（MC-53 同类风险）。
    func testExecutionStateSurvivesTheRoundTrip() async throws {
        let store = try requireStore()
        let version = try await prepareMeetingWithCitations()
        let items = try await store.minutesItems(minutesID: version.id)
        let action = try XCTUnwrap(items.first { $0.kind == "action" })

        try await store.recordExecutionEvent(itemID: action.id, status: .done, ownerText: .some("张三"))
        try await store.recordExecutionEvent(
            itemID: action.id,
            status: .blocked,
            dueDate: .some(Date(timeIntervalSince1970: 1_800_000_000))
        )

        let documentID = try await requireDocumentID()
        let package = try await store.exportKnowledgeArchive(
            selection: KnowledgeArchiveSelection(
                documentID: documentID, minutesID: version.id, scope: .fullArchive
            ),
            to: try exportDestination()
        )

        let imported = try await makeImportedStore { target in
            try await target.importKnowledgeArchive(at: package)
        }
        defer { Task { await imported.store.close() } }
        XCTAssertGreaterThan(imported.result.inserted.executionEvents, 0, "执行状态必须真的写进新库")

        let restored = try await imported.store.knowledgeExecutionEvents(documentID: documentID)
        XCTAssertEqual(restored.count, 2, "两条事件都要在，一条都不能少")
        let current = try XCTUnwrap(restored.last)
        XCTAssertEqual(current.status, ActionExecutionStatus.blocked.rawValue)
        XCTAssertEqual(current.ownerText, "张三", "负责人不能丢")
        XCTAssertEqual(current.dueDate, 1_800_000_000, "期限不能丢")
        XCTAssertNil(current.validTo, "当前有效那条不该被写成已失效")
    }

    func testArchiveCarriesTheItemKeyThatExecutionStateHangsOn() async throws {
        let store = try requireStore()
        let version = try await prepareMeetingWithCitations()
        let items = try await store.minutesItems(minutesID: version.id)
        let action = try XCTUnwrap(items.first { $0.kind == "action" })
        try await store.recordExecutionEvent(itemID: action.id, status: .done)

        let documentID = try await requireDocumentID()
        let payload = try await store.knowledgeArchivePayload(
            selection: KnowledgeArchiveSelection(
                documentID: documentID, minutesID: version.id, scope: .fullArchive
            )
        )
        let exportedItem = try XCTUnwrap(payload.items.first { $0.id == action.id })
        XCTAssertFalse(exportedItem.itemKey.isEmpty, "条目必须带稳定 key，否则执行状态挂不上去")
        XCTAssertEqual(
            exportedItem.itemKey,
            KnowledgeIdentity.key(documentID: documentID, kind: action.kind, text: action.text)
        )
        let event = try XCTUnwrap(payload.execution.first)
        XCTAssertEqual(event.itemKey, exportedItem.itemKey, "事件与条目必须挂在同一个 key 上")
    }

    func testReimportingExecutionStateIsIdempotent() async throws {
        let store = try requireStore()
        let version = try await prepareMeetingWithCitations()
        let items = try await store.minutesItems(minutesID: version.id)
        let action = try XCTUnwrap(items.first { $0.kind == "action" })
        try await store.recordExecutionEvent(itemID: action.id, status: .done)

        let documentID = try await requireDocumentID()
        let package = try await store.exportKnowledgeArchive(
            selection: KnowledgeArchiveSelection(
                documentID: documentID, minutesID: version.id, scope: .fullArchive
            ),
            to: try exportDestination()
        )
        let imported = try await makeImportedStore { target in
            try await target.importKnowledgeArchive(at: package)
        }
        defer { Task { await imported.store.close() } }

        // 同一个包导两次：第二次必须全部跳过，不能插出第二份状态。
        let again = try await imported.store.importKnowledgeArchive(at: package)
        XCTAssertEqual(again.inserted.executionEvents, 0, "同内容重复导入不该重复写执行状态")
        let restored = try await imported.store.knowledgeExecutionEvents(documentID: documentID)
        XCTAssertEqual(restored.count, 1)
    }

    /// 人读的那份纪要里必须有执行状态。只写结构化 JSON 不够——
    /// 大多数人导出后只读 `minutes.md`，那里没写就等于说"待办都还没做"。
    func testReadableMarkdownShowsExecutionState() async throws {
        let store = try requireStore()
        let version = try await prepareMeetingWithCitations()
        let items = try await store.minutesItems(minutesID: version.id)
        let action = try XCTUnwrap(items.first { $0.kind == "action" })
        try await store.recordExecutionEvent(
            itemID: action.id, status: .done, ownerText: .some("张三")
        )

        let documentID = try await requireDocumentID()
        let package = try await store.exportKnowledgeArchive(
            selection: KnowledgeArchiveSelection(
                documentID: documentID, minutesID: version.id, scope: .fullArchive
            ),
            to: try exportDestination()
        )
        let read = try KnowledgeArchiveFileIO.readPackage(at: package, fileManager: .default)
        XCTAssertTrue(
            read.markdown.contains("已完成"),
            "可读纪要里应当看得出这条待办已经做完：\n\(read.markdown)"
        )
        XCTAssertTrue(read.markdown.contains("负责人：张三"), read.markdown)
    }

    func testManifestCountsIncludeExecutionState() async throws {
        let store = try requireStore()
        let version = try await prepareMeetingWithCitations()
        let items = try await store.minutesItems(minutesID: version.id)
        let action = try XCTUnwrap(items.first { $0.kind == "action" })
        try await store.recordExecutionEvent(itemID: action.id, status: .done)

        let documentID = try await requireDocumentID()
        let selection = KnowledgeArchiveSelection(
            documentID: documentID, minutesID: version.id, scope: .fullArchive
        )
        let payload = try await store.knowledgeArchivePayload(selection: selection)
        let manifest = try await store.knowledgeArchiveManifest(
            selection: selection,
            payload: payload
        )
        // 清单说装了什么就得说全；漏报会让核对时对不上却查不出原因。
        XCTAssertEqual(manifest.counts.executionEvents, 1)
        XCTAssertEqual(manifest.counts.supersessions, 0)
    }

    func testSupersededExecutionEventIsNotReportedAsCurrent() async throws {
        // 双时间日志里已失效的那条是历史，不能算成当前状态。
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let key = "doc\u{1F}action\u{1F}发布"
        let events = [
            ArchiveExecutionEvent(
                id: "e1", itemKey: key, documentID: "d", itemID: "i1", kind: "action",
                status: "done", ownerText: nil, dueText: nil, dueDate: nil,
                validFrom: now.timeIntervalSince1970, recordedAt: now.timeIntervalSince1970,
                validTo: now.timeIntervalSince1970 + 10, note: nil
            ),
            ArchiveExecutionEvent(
                id: "e2", itemKey: key, documentID: "d", itemID: "i1", kind: "action",
                status: "blocked", ownerText: nil, dueText: nil, dueDate: nil,
                validFrom: now.timeIntervalSince1970 + 20, recordedAt: now.timeIntervalSince1970 + 20,
                validTo: nil, note: nil
            ),
        ]
        let current = KnowledgeArchiveMarkdown.currentExecutionByKey(events)
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(current[key]?.status, "blocked")
    }

    func testExpiredEventAloneDoesNotBecomeCurrent() async throws {
        // 只有历史、没有当前状态时，不该凭空显示一个状态。
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let events = [
            ArchiveExecutionEvent(
                id: "e1", itemKey: "k", documentID: "d", itemID: "i", kind: "action",
                status: "done", ownerText: nil, dueText: nil, dueDate: nil,
                validFrom: now.timeIntervalSince1970, recordedAt: now.timeIntervalSince1970,
                validTo: now.timeIntervalSince1970 + 10, note: nil
            )
        ]
        XCTAssertTrue(KnowledgeArchiveMarkdown.currentExecutionByKey(events).isEmpty)
    }

    /// 完整归档装得下全部来源，所以往返之后**不该**有任何结论被降级。
    ///
    /// 这条是给降级逻辑的护栏：来源齐全时误降级，和来源缺失时不降级
    /// 一样是错的——前者会让用户白白去复核一堆本来没问题的东西。
    func testCompleteRoundTripDowngradesNothing() async throws {
        let store = try requireStore()
        let version = try await prepareMeetingWithCitations()
        let documentID = try await requireDocumentID()
        let package = try await store.exportKnowledgeArchive(
            selection: KnowledgeArchiveSelection(
                documentID: documentID, minutesID: version.id, scope: .fullArchive
            ),
            to: try exportDestination()
        )
        let imported = try await makeImportedStore { target in
            try await target.importKnowledgeArchive(at: package)
        }
        defer { Task { await imported.store.close() } }

        XCTAssertEqual(
            imported.result.inserted.markedForReview, 0,
            "来源齐全的完整归档不该有任何结论被降级"
        )
        let items = try await imported.store.minutesItems(minutesID: version.id)
        let cited = items.filter { !$0.anchors.isEmpty }
        XCTAssertFalse(cited.isEmpty)
        for item in cited {
            XCTAssertEqual(item.verdict, .supported, "\(item.localID) 不该被降级")
        }
    }

    /// 包格式版本。**升版不是形式主义**：v2 缺 `body_origin` 与 `parent_minutes_id`，
    /// 旧包读不了正是刻意的——带着缺列的包导入，会把用户写的正文标成「AI 整理」，
    /// 而那是不能猜的信息。宁可让用户重导一次，也不要静默归错出处。
    func testPayloadSchemaIsV3() async throws {
        let store = try requireStore()
        let version = try await prepareMeetingWithCitations()
        let documentID = try await requireDocumentID()
        let payload = try await store.knowledgeArchivePayload(
            selection: KnowledgeArchiveSelection(
                documentID: documentID, minutesID: version.id, scope: .fullArchive
            )
        )
        XCTAssertEqual(payload.schema, "speechrail.meeting.knowledge-archive.payload/3")
    }
}
