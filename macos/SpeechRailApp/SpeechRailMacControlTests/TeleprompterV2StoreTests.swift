import CryptoKit
import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

struct TeleprompterV2StoreTests {
    @Test @MainActor func v2RoundTripPreservesSourceAndReadingCoordinates() throws {
        let fixture = try makeFixture()
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TeleprompterV2Store(directoryURL: directory)

        try store.save(fixture.bundle)
        let loaded = try store.load(documentID: fixture.bundle.document.id)

        #expect(loaded.formatVersion == 2)
        #expect(loaded.document.currentSourceRevisionID == fixture.sourceRevisionID)
        #expect(loaded.sourceRevisions[0].sourceText == fixture.sourceText)
        #expect(loaded.versions[0].readingText == "第一段。\n\n第二段。")
        #expect(loaded.versions[0].segments[0].text == "第一段。")
        #expect(loaded.versions[0].segments[0].readingRange == .init(start: 0, end: 4))
    }

    @Test @MainActor func sourceRevisionIsImmutableAndInvalidSaveLeavesPreviousBytesUntouched() throws {
        let fixture = try makeFixture()
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TeleprompterV2Store(directoryURL: directory)
        try store.save(fixture.bundle)
        let url = directory.appendingPathComponent("document-1.json")
        let before = try Data(contentsOf: url)

        var changed = fixture.bundle
        changed.sourceRevisions[0].sourceText = "被篡改的原稿"
        changed.sourceRevisions[0].utf8SHA256 = TeleprompterV2Hash.sha256("被篡改的原稿")

        #expect(throws: TeleprompterV2StoreError.immutableSourceRevision) {
            try store.save(changed)
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(try store.load(documentID: "document-1").sourceRevisions[0].sourceText == fixture.sourceText)
    }

    @Test @MainActor func unknownFutureVersionFailsClosedAndCorruptDocumentsDoNotBreakListing() throws {
        let fixture = try makeFixture()
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TeleprompterV2Store(directoryURL: directory)
        try store.save(fixture.bundle)
        try Data(#"{"format_version":9,"document":{}}"#.utf8)
            .write(to: directory.appendingPathComponent("future.json"))
        try Data("not-json".utf8)
            .write(to: directory.appendingPathComponent("broken.json"))

        #expect(throws: TeleprompterV2StoreError.unsupportedVersion(9)) {
            try store.load(documentID: "future")
        }
        let items = try store.listDocuments()
        #expect(items.count == 3)
        #expect(items.first(where: { $0.id == "document-1" })?.isAvailable == true)
        #expect(items.first(where: { $0.id == "future" })?.isAvailable == false)
        #expect(items.first(where: { $0.id == "broken" })?.isAvailable == false)
    }

    @Test @MainActor func exportsSourceWithBomAndReadingTextWithoutCueOrSkippedContent() throws {
        let fixture = try makeFixture(hasBOM: true)
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TeleprompterV2Store(directoryURL: directory)

        let sourceData = try store.exportSource(fixture.bundle)
        #expect(sourceData.starts(with: [0xEF, 0xBB, 0xBF]))
        #expect(String(decoding: sourceData.dropFirst(3), as: UTF8.self) == fixture.sourceText)
        let reading = try store.exportReading(fixture.bundle)
        #expect(reading == "第一段。\n\n第二段。\n")
        #expect(!reading.contains("提示"))
        #expect(!reading.contains("跳过"))
    }

    @Test @MainActor func duplicateRegeneratesIdentitiesAndClearsRunProgress() throws {
        let fixture = try makeFixture()
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TeleprompterV2Store(directoryURL: directory)

        var sourceBundle = fixture.bundle
        sourceBundle.lastRun = .init(
            versionID: "version-1",
            targetSeconds: 300,
            elapsedSeconds: 42,
            lastSegmentID: "segment-1",
            endedReason: "paused",
            completedReading: false
        )
        try store.save(sourceBundle)

        let copy = try store.duplicate(documentID: fixture.bundle.document.id)
        #expect(copy.document.id != fixture.bundle.document.id)
        #expect(copy.document.title == "测试稿 副本")
        #expect(copy.lastRun == nil)
        #expect(copy.sourceRevisions[0].id != fixture.bundle.sourceRevisions[0].id)
        #expect(copy.versions[0].id != fixture.bundle.versions[0].id)
        #expect(copy.versions[0].documentID == copy.document.id)
        #expect(copy.versions[0].sourceRevisionID == copy.sourceRevisions[0].id)
        #expect(copy.versions[0].blocks.map(\.id) != fixture.bundle.versions[0].blocks.map(\.id))
        #expect(copy.versions[0].segments.map(\.id) != fixture.bundle.versions[0].segments.map(\.id))
        do {
            let loadedCopy = try store.load(documentID: copy.document.id)
            #expect(loadedCopy.document.id == copy.document.id)
            #expect(loadedCopy.document.title == copy.document.title)
            #expect(loadedCopy.sourceRevisions.map(\.sourceText) == copy.sourceRevisions.map(\.sourceText))
            #expect(loadedCopy.versions.map(\.readingText) == copy.versions.map(\.readingText))
            #expect(loadedCopy.lastRun == nil)
        } catch {
            Issue.record("duplicate load failed: \(error)")
        }
    }

    private struct Fixture {
        var bundle: TeleprompterV2DocumentBundle
        let sourceText: String
        let sourceRevisionID: String
    }

    private func makeFixture(hasBOM: Bool = false) throws -> Fixture {
        let sourceText = "第一段。\n第二段。"
        let sourceData = Data(sourceText.utf8)
        let source = try TeleprompterSourceImporter.importData(sourceData, fileExtension: "txt")
        let units = try TeleprompterSourceUnitBuilder(maxBudgetUnits: 12).build(source)
        let firstUnitIDs = Array(units.prefix(max(1, units.count / 2))).map(\.id)
        let secondUnitIDs = Array(units.dropFirst(firstUnitIDs.count)).map(\.id)
        let timing = try TeleprompterTimingPlanner.plan(
            sourceUnits: units,
            estimates: Array(repeating: nil, count: units.count),
            targetMinutes: 5
        )
        let selection = TeleprompterV2SelectionRevision(
            id: "selection-1",
            sourceUnitRevision: source.sourceRevisionID,
            selectedUnitIDs: units.map(\.id),
            selectedRanges: [.init(start: 0, end: sourceText.utf16.count)],
            userExcludedRanges: []
        )
        let goal = TeleprompterV2DurationGoal(targetSeconds: 300, goalRevision: 1)
        let allocation = TeleprompterV2TimingAllocationSnapshot(
            allocationRevision: 1,
            plan: timing
        )
        let blocks = [
            TeleprompterV2ReadingBlock(
                id: "block-1",
                revision: 0,
                sourceUnitIDs: firstUnitIDs,
                text: "第一段。",
                disposition: .speak,
                origin: .deterministic,
                budgetShare: 120
            ),
            TeleprompterV2ReadingBlock(
                id: "cue-1",
                revision: 0,
                sourceUnitIDs: [],
                text: "提示",
                disposition: .cue,
                origin: .user,
                budgetShare: 0
            ),
            TeleprompterV2ReadingBlock(
                id: "skip-1",
                revision: 0,
                sourceUnitIDs: [],
                text: "跳过",
                disposition: .skip,
                origin: .user,
                budgetShare: 0
            ),
            TeleprompterV2ReadingBlock(
                id: "block-2",
                revision: 0,
                sourceUnitIDs: secondUnitIDs,
                text: "第二段。",
                disposition: .speak,
                origin: .deterministic,
                budgetShare: 120
            )
        ]
        let segments = [
            TeleprompterV2ReadingSegment(id: "segment-1", ordinal: 0, readingRange: .init(start: 0, end: 4), text: "第一段。"),
            TeleprompterV2ReadingSegment(id: "segment-2", ordinal: 1, readingRange: .init(start: 6, end: 10), text: "第二段。")
        ]
        let version = TeleprompterV2ReadingVersion(
            id: "version-1",
            documentID: "document-1",
            sourceRevisionID: source.sourceRevisionID,
            selectionSnapshot: selection,
            readingText: "第一段。\n\n第二段。",
            blocks: blocks,
            segments: segments,
            goalSnapshot: goal,
            paceSnapshot: .natural,
            estimate: TeleprompterDurationEstimator.estimate("第一段。\n\n第二段。"),
            analysisSource: .deterministic
        )
        let document = TeleprompterV2Document(
            id: "document-1",
            title: "测试稿",
            currentSourceRevisionID: source.sourceRevisionID,
            activeVersionID: version.id
        )
        let sourceRevision = TeleprompterV2SourceRevision(
            id: source.sourceRevisionID,
            sourceText: sourceText,
            utf8SHA256: source.sourceSHA256,
            encoding: "utf8",
            hasBOM: hasBOM,
            formatHint: .plaintext,
            builderVersion: source.builderVersion,
            sourceUnits: units
        )
        let draft = TeleprompterV2ReadingDraft(
            id: "draft-1",
            draftRevision: 1,
            sourceRevisionID: source.sourceRevisionID,
            selectionRevisionID: selection.id,
            blocks: blocks,
            reviewIssues: [],
            goal: goal,
            pace: .natural,
            timingAllocation: allocation
        )
        return Fixture(
            bundle: TeleprompterV2DocumentBundle(
                document: document,
                sourceRevisions: [sourceRevision],
                draft: draft,
                versions: [version],
                lastRun: nil
            ),
            sourceText: sourceText,
            sourceRevisionID: source.sourceRevisionID
        )
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechRail-Teleprompter-v2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
