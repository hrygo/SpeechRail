import XCTest
import Testing

#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

@MainActor
final class TeleprompterStoreTests: XCTestCase {
    private var directory: URL!
    private var store: TeleprompterStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechRail-Teleprompter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try TeleprompterStore(directoryURL: directory)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    func testSaveListLoadAndUpdateRunState() throws {
        let bundle = makeBundle()

        try store.saveBundle(bundle)
        XCTAssertEqual(try store.listDocuments().map(\.id), [bundle.document.id])
        let loaded = try store.loadBundle(documentID: bundle.document.id)
        XCTAssertEqual(loaded.document.id, bundle.document.id)
        XCTAssertEqual(loaded.document.activeVersionID, bundle.document.activeVersionID)
        XCTAssertEqual(loaded.versions.map(\.id), bundle.versions.map(\.id))
        XCTAssertEqual(loaded.versions[0].segments, bundle.versions[0].segments)

        let state = TeleprompterRunState(
            documentID: bundle.document.id,
            versionID: bundle.versions[0].id,
            currentSegmentID: bundle.versions[0].segments[1].id,
            mode: .paused
        )
        try store.updateRunState(state)

        let restoredState = try store.loadBundle(documentID: bundle.document.id).runState
        XCTAssertEqual(restoredState?.documentID, state.documentID)
        XCTAssertEqual(restoredState?.versionID, state.versionID)
        XCTAssertEqual(restoredState?.currentSegmentID, state.currentSegmentID)
        XCTAssertEqual(restoredState?.mode, state.mode)
        XCTAssertEqual(
            restoredState?.lastUpdatedAt.timeIntervalSince1970 ?? 0,
            state.lastUpdatedAt.timeIntervalSince1970,
            accuracy: 0.01
        )
    }

    func testDeleteAndDuplicateDocument() throws {
        let bundle = makeBundle()
        try store.saveBundle(bundle)
        XCTAssertEqual(try store.listDocuments().count, 1)

        let duplicate = try store.duplicateDocument(documentID: bundle.document.id)
        XCTAssertEqual(try store.listDocuments().count, 2)
        XCTAssertTrue(duplicate.document.title.contains("副本"))
        XCTAssertEqual(duplicate.document.sourceText, bundle.document.sourceText)

        try store.deleteDocument(documentID: bundle.document.id)
        XCTAssertEqual(try store.listDocuments().count, 1)
        XCTAssertThrowsError(try store.loadBundle(documentID: bundle.document.id)) { error in
            XCTAssertEqual(error as? TeleprompterStoreError, .notFound)
        }

        try store.deleteDocument(documentID: duplicate.document.id)
        XCTAssertEqual(try store.listDocuments().count, 0)
    }

    func testExportContainsUserFacingTextButNoInternalRunState() throws {
        let markdown = store.exportMarkdown(makeBundle())

        XCTAssertTrue(markdown.contains("# 直播稿"))
        XCTAssertTrue(markdown.contains("欢迎来到直播。"))
        XCTAssertFalse(markdown.contains("segment-1"))
        XCTAssertFalse(markdown.contains("currentSegmentID"))
    }

    func testCorruptBundleFailsClosed() throws {
        let bundle = makeBundle()
        try store.saveBundle(bundle)
        let file = directory.appendingPathComponent("\(bundle.document.id).json")
        try Data("not-json".utf8).write(to: file)

        XCTAssertThrowsError(try store.loadBundle(documentID: bundle.document.id)) { error in
            XCTAssertEqual(error as? TeleprompterStoreError, .corruptBundle)
        }
    }

    func testTextImporterAcceptsMarkdownAndRejectsOtherExtensions() throws {
        let markdownURL = directory.appendingPathComponent("draft.md")
        try "# 标题\n\n正文".write(to: markdownURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(try TeleprompterTextImporter.load(from: markdownURL), "# 标题\n\n正文")

        let audioURL = directory.appendingPathComponent("draft.wav")
        XCTAssertThrowsError(try TeleprompterTextImporter.load(from: audioURL)) { error in
            XCTAssertEqual(error as? TeleprompterStoreError, .unsupportedImport)
        }
    }

    /// `.markdown` 是文件选择器里能选到的扩展名（T1）。它与 `TeleprompterSourceImporter`
    /// 的那道白名单是**同一族约束的两个副本**，两处此前都只测了 `.md`。
    func testTextImporterAcceptsTheDotMarkdownExtensionToo() throws {
        let url = directory.appendingPathComponent("draft.markdown")
        try "# 标题".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(try TeleprompterTextImporter.load(from: url), "# 标题")
    }

    /// 首次启动时目录还不存在（T2）。这条路径此前从未被构造过——每条用例都先
    /// 建目录再用，于是「第一次打开提词器」这个最常见的入口是裸的。
    func testListingAMissingDirectoryReturnsAnEmptyList() throws {
        let missing = directory.appendingPathComponent("not-created-yet", isDirectory: true)
        let fresh = try TeleprompterStore(directoryURL: missing)

        XCTAssertEqual(try fresh.listDocuments().count, 0)
    }

    /// 目录里可能有 macOS 放下的 `.DS_Store`（T3）。它不是稿子，也不该让整份列表报错。
    func testListingIgnoresNonBundleFilesInTheDirectory() throws {
        let bundle = makeBundle()
        try store.saveBundle(bundle)
        try Data("junk".utf8).write(to: directory.appendingPathComponent(".DS_Store"))
        try Data("junk".utf8).write(to: directory.appendingPathComponent("notes.txt"))

        XCTAssertEqual(try store.listDocuments().map(\.id), [bundle.document.id])
    }

    /// 最近编辑的稿子排在最前（T4）。此前每条用例只存一份稿子，比较器从未被比较过。
    func testListingSortsByMostRecentlyUpdated() throws {
        let base = Date()
        try store.saveBundle(makeBundle(id: "document-old", updatedAt: base))
        try store.saveBundle(makeBundle(id: "document-new", updatedAt: base.addingTimeInterval(600)))

        XCTAssertEqual(try store.listDocuments().map(\.id), ["document-new", "document-old"])
    }

    /// 运行态只能挂在**这份稿子里确实存在**的版本上（T7）。
    func testRunStateRejectsAVersionThisDocumentDoesNotOwn() throws {
        let bundle = makeBundle()
        try store.saveBundle(bundle)
        let state = TeleprompterRunState(
            documentID: bundle.document.id,
            versionID: "version-does-not-exist",
            currentSegmentID: bundle.versions[0].segments[0].id,
            mode: .paused
        )

        XCTAssertThrowsError(try store.updateRunState(state)) { error in
            XCTAssertEqual(error as? TeleprompterStoreError, .invalidBundle)
        }
    }

    /// 删一份不存在的稿子要报「找不到」，而不是 Foundation 的底层错误（T8）。
    /// 同一道约束在读取侧已被 `testDeleteAndDuplicateDocument` 覆盖，删除侧此前没有。
    func testDeletingAMissingDocumentReportsNotFound() {
        XCTAssertThrowsError(try store.deleteDocument(documentID: "never-existed")) { error in
            XCTAssertEqual(error as? TeleprompterStoreError, .notFound)
        }
    }

    /// 导出的是**正在读的那一版**，不是列表里的第一版（T9）。AI 改过稿之后，
    /// 导出拿到旧稿是用户直接看得见的错。
    func testExportPrefersTheActiveVersionOverTheFirst() throws {
        let bundle = makeBundle()
        let older = TeleprompterVersion(
            id: "version-old",
            documentID: bundle.document.id,
            sourceText: "旧的第一版。",
            segments: [TeleprompterSegment(id: "s-old", ordinal: 0, sourceRange: .init(start: 0, end: 6), text: "旧的第一版。")],
            analysisSource: .deterministic
        )
        let active = TeleprompterVersion(
            id: "version-active",
            documentID: bundle.document.id,
            sourceText: "AI 改过的新版。",
            segments: [TeleprompterSegment(id: "s-new", ordinal: 0, sourceRange: .init(start: 0, end: 8), text: "AI 改过的新版。")],
            analysisSource: .ai
        )
        var document = bundle.document
        document.activeVersionID = active.id
        let twoVersions = TeleprompterDocumentBundle(
            document: document,
            versions: [older, active],
            runState: nil
        )

        let markdown = store.exportMarkdown(twoVersions)

        XCTAssertTrue(markdown.contains("AI 改过的新版。"))
        XCTAssertFalse(markdown.contains("旧的第一版。"))
    }

    /// 导出时段落之间是空行（T10）。此前只断言「包含某段文字」，没断言分隔。
    func testExportSeparatesParagraphsWithABlankLine() {
        let markdown = store.exportMarkdown(makeBundle())

        XCTAssertTrue(markdown.contains("欢迎来到直播。\n\n今天介绍三个重点。"))
    }

    /// bundle 校验的六道守卫此前只有「正常 bundle」被存过（T11–T16）。
    func testBundleValidationRejectsStructurallyBrokenDocuments() throws {
        let base = makeBundle()

        func expectRejected(
            _ bundle: TeleprompterDocumentBundle,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertThrowsError(try store.saveBundle(bundle), file: file, line: line) { error in
                XCTAssertEqual(error as? TeleprompterStoreError, .invalidBundle, file: file, line: line)
            }
        }

        expectRejected(makeBundle(id: "", title: "空 ID", versionID: "", omitActiveVersionID: true))

        expectRejected(makeBundle(title: "   \n  "))

        expectRejected(makeBundle(versionDocumentID: "another-document"))

        expectRejected(makeBundle(activeVersionID: "version-gone"))

        let noSegments = makeBundle(versionID: "version-empty", segments: [])
        expectRejected(noSegments)

        let badOrdinals = makeBundle(
            versionID: "version-bad-ordinals",
            segments: [
                TeleprompterSegment(id: "s-a", ordinal: 0, sourceRange: .init(start: 0, end: 8), text: "欢迎来到直播。"),
                TeleprompterSegment(id: "s-b", ordinal: 5, sourceRange: .init(start: 8, end: 17), text: "今天介绍三个重点。"),
            ]
        )
        expectRejected(badOrdinals)
    }

    /// 路径穿越防护此前零观察（T17–T19）。`documentID` 里的 `/`、`.` 与 `..`
    /// 都会让路径落到 documents 目录之外，而读取和删除都能作用于那个路径。
    func testDocumentIDCannotEscapeTheStoreDirectory() throws {
        let bundle = makeBundle()
        try store.saveBundle(bundle)
        let outside = directory.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(bundle).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        for hostileID in ["../\(outside.lastPathComponent)", "..", ".", "sub/dir", "\\"] {
            XCTAssertThrowsError(try store.loadBundle(documentID: hostileID), hostileID) { error in
                XCTAssertEqual(error as? TeleprompterStoreError, .invalidDocumentID, hostileID)
            }
            XCTAssertThrowsError(try store.deleteDocument(documentID: hostileID), hostileID) { error in
                XCTAssertEqual(error as? TeleprompterStoreError, .invalidDocumentID, hostileID)
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "越界尝试不得动到目录外的文件")
    }

    private func makeBundle(
        id: String = "document-1",
        title: String = "直播稿",
        versionID: String = "version-1",
        activeVersionID: String? = nil,
        omitActiveVersionID: Bool = false,
        versionDocumentID: String? = nil,
        segments: [TeleprompterSegment]? = nil,
        updatedAt: Date? = nil
    ) -> TeleprompterDocumentBundle {
        let sourceText = "欢迎来到直播。\n今天介绍三个重点。"
        var document = TeleprompterDocument(
            id: id,
            title: title,
            sourceText: sourceText
        )
        if let updatedAt {
            document.updatedAt = updatedAt
        }
        let version = TeleprompterVersion(
            id: versionID,
            documentID: versionDocumentID ?? id,
            sourceText: sourceText,
            segments: segments ?? [
                TeleprompterSegment(
                    id: "segment-1",
                    ordinal: 0,
                    sourceRange: .init(start: 0, end: 8),
                    text: "欢迎来到直播。"
                ),
                TeleprompterSegment(
                    id: "segment-2",
                    ordinal: 1,
                    sourceRange: .init(start: 8, end: 17),
                    text: "今天介绍三个重点。"
                ),
            ],
            analysisSource: .deterministic
        )
        document.activeVersionID = omitActiveVersionID ? nil : (activeVersionID ?? versionID)
        return TeleprompterDocumentBundle(
            document: document,
            versions: [version],
            runState: nil
        )
    }
}

struct TeleprompterDraftStoreTests {
    @Test @MainActor func savesDraftBeforeAnyAnalysis() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TeleprompterStore(directoryURL: directory)
        let draft = TeleprompterDocument(id: "draft", title: "未命名稿子", sourceText: "")
        try store.saveBundle(.init(document: draft, versions: [], runState: nil))
        #expect(try store.loadBundle(documentID: "draft").versions.isEmpty)
        #expect(try store.listDocuments().count == 1)
    }
}
