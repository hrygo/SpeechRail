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

    /// `TeleprompterV2ReadingVersion.segments` is immutable, so a bundle that gains
    /// a confirmed reading is rebuilt the same way the app rebuilds it.
    private func bundle(
        _ source: TeleprompterV2DocumentBundle,
        segmentReadings: [TeleprompterAcceptedReading]
    ) -> TeleprompterV2DocumentBundle {
        var bundle = source
        var version = source.versions[0]
        var segments = version.segments
        segments[0].acceptedReadings = segmentReadings
        version = TeleprompterV2ReadingVersion(
            id: version.id,
            documentID: version.documentID,
            sourceRevisionID: version.sourceRevisionID,
            selectionSnapshot: version.selectionSnapshot,
            readingText: version.readingText,
            readingHash: version.readingHash,
            blocks: version.blocks,
            segments: segments,
            goalSnapshot: version.goalSnapshot,
            paceSnapshot: version.paceSnapshot,
            estimate: version.estimate,
            analysisSource: version.analysisSource,
            createdAt: version.createdAt
        )
        bundle.versions = [version]
        return bundle
    }

    /// #110 的别名必须真的落盘并在重开后还在——否则用户确认过的读法在下次打开
    /// 时悄悄消失，跟随又会退回错词。
    @Test @MainActor func confirmedReadingsSurviveSaveAndReload() throws {
        let fixture = try makeFixture()
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TeleprompterV2Store(directoryURL: directory)

        let ns = "第一段。" as NSString
        let found = ns.range(of: "一段")
        let bundle = bundle(fixture.bundle, segmentReadings: [
            TeleprompterAcceptedReading(
                displayRange: .init(start: found.location, end: found.location + found.length),
                displayText: "一段",
                spokenText: "壹段"
            )
        ])
        try store.save(bundle)

        let loaded = try store.load(documentID: bundle.document.id)
        let alias = try #require(loaded.versions[0].segments[0].acceptedReadings.first)
        #expect(alias.spokenText == "壹段")
        #expect(alias.displayText == "一段")
        #expect(alias.displayRange == .init(start: found.location, end: found.location + found.length))
        #expect(loaded.versions[0].segments[0].text == "第一段。", "别名不得改动显示文本")
    }

    /// M-01：别名通道是后加的字段，旧稿根本没有这个键，仍必须能打开。
    @Test @MainActor func aBundleWrittenBeforeTheAliasChannelStillLoads() throws {
        let fixture = try makeFixture()
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TeleprompterV2Store(directoryURL: directory)
        try store.save(fixture.bundle)

        let url = directory.appendingPathComponent("\(fixture.bundle.document.id).json")
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var versions = try #require(object["versions"] as? [[String: Any]])
        var segments = try #require(versions[0]["segments"] as? [[String: Any]])
        segments[0].removeValue(forKey: "accepted_readings")
        versions[0]["segments"] = segments
        object["versions"] = versions
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let loaded = try store.load(documentID: fixture.bundle.document.id)
        #expect(loaded.versions[0].segments[0].acceptedReadings.isEmpty)
        #expect(loaded.versions[0].segments[0].text == "第一段。")
    }

    /// 别名与它所属的段落写在同一次原子保存里，所以二者对不上说明调用方拼错了
    /// bundle。此时必须拒绝保存，而不是存下一条日后会被丢掉、或更糟——被套用到
    /// 别的词上的别名。
    @Test @MainActor func aBundleWhoseReadingNoLongerMatchesItsSegmentIsRejected() throws {
        let fixture = try makeFixture()
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TeleprompterV2Store(directoryURL: directory)

        let bundle = bundle(fixture.bundle, segmentReadings: [
            TeleprompterAcceptedReading(
                displayRange: .init(start: 0, end: 2),
                displayText: "根本不存在于此段",
                spokenText: "壹段"
            )
        ])
        #expect(throws: TeleprompterV2StoreError.self) {
            try store.save(bundle)
        }
        #expect(throws: TeleprompterV2StoreError.self) {
            _ = try store.load(documentID: bundle.document.id)
        }
    }

    /// 两条别名压在同一段文字上时，「谁生效」就没有确定答案了。与其让读取
    /// 端自己挑一条，不如在存盘时就把这种 bundle 挡下来。
    @Test @MainActor func aBundleCarryingTwoOverlappingReadingsIsRejected() throws {
        let fixture = try makeFixture()
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TeleprompterV2Store(directoryURL: directory)

        let ns = "第一段。" as NSString
        let first = ns.range(of: "第一")
        let second = ns.range(of: "一段")
        let bundle = bundle(fixture.bundle, segmentReadings: [
            TeleprompterAcceptedReading(
                displayRange: .init(start: first.location, end: first.location + first.length),
                displayText: "第一",
                spokenText: "蒂一"
            ),
            TeleprompterAcceptedReading(
                displayRange: .init(start: second.location, end: second.location + second.length),
                displayText: "一段",
                spokenText: "壹段"
            )
        ])
        #expect(throws: TeleprompterV2StoreError.self) {
            try store.save(bundle)
        }
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

    /// #110 asks for 「旧稿／损坏文件／写入失败不丢数据」. The regression above
    /// only covers a failure raised *before* the write, and `atomicWrite` is
    /// fileprivate, so the commit itself had no seam and no coverage at all.
    /// A read-only directory is the same class of failure the requirement names
    /// — a full disk or a denied write — and it reaches the temporary-file step
    /// instead of a validation shortcut.
    @Test @MainActor func aFailedWriteLeavesThePreviousDocumentIntact() throws {
        try #require(getuid() != 0, "root 绕过目录权限，这条路径无法复现")
        let fixture = try makeFixture()
        let directory = try makeDirectory()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: directory.path
            )
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try TeleprompterV2Store(directoryURL: directory)
        try store.save(fixture.bundle)
        let url = directory.appendingPathComponent("\(fixture.bundle.document.id).json")
        let before = try Data(contentsOf: url)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: directory.path
        )
        var changed = fixture.bundle
        changed.document.title = "写入失败时不该出现的标题"

        #expect(throws: TeleprompterV2StoreError.atomicWriteFailed) {
            try store.save(changed)
        }
        #expect(try Data(contentsOf: url) == before, "写入失败后原始字节必须逐字节不变")
        #expect(
            try store.load(documentID: fixture.bundle.document.id).document.title
                == fixture.bundle.document.title,
            "写入失败后原稿必须仍可读且内容未变"
        )
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .allSatisfy { !$0.hasSuffix(".tmp") },
            "写入失败不应残留临时文件"
        )
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

    @Test @MainActor func runSummaryWrittenBeforeIntraSegmentProgressStillLoads() throws {
        let fixture = try makeFixture()
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TeleprompterV2Store(directoryURL: directory)

        var bundle = fixture.bundle
        bundle.lastRun = .init(
            versionID: "version-1",
            targetSeconds: 300,
            elapsedSeconds: 42,
            lastSegmentID: "segment-1",
            lastSegmentOffset: 3,
            endedReason: "paused",
            completedReading: false
        )
        try store.save(bundle)

        let url = directory.appendingPathComponent("\(bundle.document.id).json", isDirectory: false)
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var run = try #require(object["last_run"] as? [String: Any])
        run.removeValue(forKey: "last_segment_offset")
        object["last_run"] = run
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let loaded = try store.load(documentID: bundle.document.id)
        #expect(loaded.lastRun?.lastSegmentID == "segment-1")
        #expect(loaded.lastRun?.lastSegmentOffset == nil, "旧稿缺少新字段仍必须可读")
    }

    @Test @MainActor func rollingBackToAnEarlierVersionKeepsEveryScript() throws {
        let fixture = try makeFixture()
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TeleprompterV2Store(directoryURL: directory)

        let original = try #require(fixture.bundle.versions.first)
        let condensedText = "第一段精简后。"
        let condensed = TeleprompterV2ReadingVersion(
            id: "version-2",
            documentID: original.documentID,
            sourceRevisionID: original.sourceRevisionID,
            selectionSnapshot: original.selectionSnapshot,
            readingText: condensedText,
            blocks: [
                TeleprompterV2ReadingBlock(
                    id: "block-condensed",
                    revision: 1,
                    sourceUnitIDs: [0],
                    text: condensedText,
                    disposition: .speak,
                    origin: .deterministic,
                    budgetShare: 60
                )
            ],
            segments: [
                TeleprompterV2ReadingSegment(
                    id: "segment-condensed",
                    ordinal: 0,
                    readingRange: .init(start: 0, end: condensedText.utf16.count),
                    text: condensedText
                )
            ],
            goalSnapshot: original.goalSnapshot,
            paceSnapshot: .natural,
            estimate: TeleprompterDurationEstimator.estimate(condensedText),
            analysisSource: .deterministic
        )
        var bundle = fixture.bundle
        bundle.versions = [original, condensed]
        bundle.document.activeVersionID = condensed.id
        try store.save(bundle)

        // Rolling back to the earlier AI result is a selection change, never a
        // deletion: the condensed script and the source revision stay readable.
        var rolledBack = try store.load(documentID: bundle.document.id)
        rolledBack.document.activeVersionID = original.id
        rolledBack.document.updatedAt = Date()
        try store.save(rolledBack)

        let reloaded = try store.load(documentID: bundle.document.id)
        #expect(reloaded.document.activeVersionID == original.id)
        #expect(reloaded.versions.count == 2)
        #expect(reloaded.versions.map(\.id).contains(condensed.id))
        #expect(reloaded.versions.map(\.readingText).contains(condensedText))
        #expect(
            try #require(reloaded.versions.first { $0.id == original.id }).readingText
                == original.readingText
        )
        #expect(try #require(reloaded.sourceRevisions.first).sourceText == fixture.sourceText)
        #expect(try store.listDocuments().count == 1)
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
