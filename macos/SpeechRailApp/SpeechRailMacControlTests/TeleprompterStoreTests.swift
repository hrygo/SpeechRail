import XCTest

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

    private func makeBundle() -> TeleprompterDocumentBundle {
        let document = TeleprompterDocument(
            id: "document-1",
            title: "直播稿",
            sourceText: "欢迎来到直播。\n今天介绍三个重点。"
        )
        let segments = [
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
        ]
        let version = TeleprompterVersion(
            id: "version-1",
            documentID: document.id,
            sourceText: document.sourceText,
            segments: segments,
            analysisSource: .deterministic
        )
        var activeDocument = document
        activeDocument.activeVersionID = version.id
        return TeleprompterDocumentBundle(
            document: activeDocument,
            versions: [version],
            runState: nil
        )
    }
}
