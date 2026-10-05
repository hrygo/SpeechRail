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
}
