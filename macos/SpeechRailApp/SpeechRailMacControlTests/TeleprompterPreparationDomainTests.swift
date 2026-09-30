import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

struct TeleprompterPreparationDomainTests {
    @Test func readingProgressRestoresTheExactOffsetInsideTheSameVersion() {
        let version = makeVersion(id: "v1", segmentTexts: ["第一段内容。", "第二段内容。"])
        let saved = TeleprompterRunState(
            documentID: "doc",
            versionID: "v1",
            currentSegmentID: "segment-0",
            currentSegmentOffset: 4,
            mode: .manual
        )

        let position = TeleprompterReadingProgressRestorer.position(
            saved: saved,
            versions: [version],
            activeVersion: version
        )

        #expect(position == .init(segmentIndex: 0, utf16Offset: 4))
    }

    @Test func readingProgressFallsBackToSegmentStartWhenTheTextChanged() {
        let recorded = makeVersion(id: "v1", segmentTexts: ["第一段内容。", "第二段内容。"])
        let active = makeVersion(id: "v2", segmentTexts: ["第一段内容改写了。", "第二段内容。"])
        let saved = TeleprompterRunState(
            documentID: "doc",
            versionID: "v1",
            currentSegmentID: "segment-0",
            currentSegmentOffset: 4,
            mode: .manual
        )

        let position = TeleprompterReadingProgressRestorer.position(
            saved: saved,
            versions: [recorded, active],
            activeVersion: active
        )

        #expect(position == .init(segmentIndex: 0, utf16Offset: 0), "旧偏移不能套进新文本")
    }

    /// 记录进度时那个版本已经被删掉（回退、精简或清理）的情况：无从证明
    /// 偏移仍然有效，必须退回段首，而不是把偏移盲目采信到别的段落上。
    @Test func readingProgressFallsBackToSegmentStartWhenTheRecordedVersionIsGone() {
        let active = makeVersion(id: "v2", segmentTexts: ["第一段内容。", "第二段内容。"])
        let saved = TeleprompterRunState(
            documentID: "doc",
            versionID: "v-deleted",
            currentSegmentID: active.segments[1].id,
            currentSegmentOffset: 4,
            mode: .manual
        )

        let position = TeleprompterReadingProgressRestorer.position(
            saved: saved,
            versions: [active],
            activeVersion: active
        )

        #expect(
            position == .init(segmentIndex: 1, utf16Offset: 0),
            "记录版本已不存在时不得采信旧偏移"
        )
    }

    @Test func readingProgressMigratesOffsetWhenTheSegmentTextIsIdentical() {
        let recorded = makeVersion(id: "v1", segmentTexts: ["第一段内容。"])
        let active = makeVersion(id: "v2", segmentTexts: ["第一段内容。", "新增的一段。"])
        let saved = TeleprompterRunState(
            documentID: "doc",
            versionID: "v1",
            currentSegmentID: "segment-0",
            currentSegmentOffset: 4,
            mode: .manual
        )

        let position = TeleprompterReadingProgressRestorer.position(
            saved: saved,
            versions: [recorded, active],
            activeVersion: active
        )

        #expect(position == .init(segmentIndex: 0, utf16Offset: 4))
    }

    @Test func readingProgressClampsOffsetsAndIgnoresUnknownSegments() {
        let version = makeVersion(id: "v1", segmentTexts: ["第一段。"])
        let beyond = TeleprompterRunState(
            documentID: "doc",
            versionID: "v1",
            currentSegmentID: "segment-0",
            currentSegmentOffset: 999,
            mode: .manual
        )
        let unknown = TeleprompterRunState(
            documentID: "doc",
            versionID: "v1",
            currentSegmentID: "gone",
            currentSegmentOffset: 2,
            mode: .manual
        )

        #expect(
            TeleprompterReadingProgressRestorer.position(
                saved: beyond,
                versions: [version],
                activeVersion: version
            ) == .init(segmentIndex: 0, utf16Offset: 4)
        )
        #expect(
            TeleprompterReadingProgressRestorer.position(
                saved: unknown,
                versions: [version],
                activeVersion: version
            ) == nil
        )
    }

    @Test func readingProgressRestoresTheRecordedSegmentStartWhenNoOffsetWasEverSaved() {
        // Documents written before intra-segment progress existed decode with a
        // nil offset. `TeleprompterV2Store` already proves the key may be
        // absent; this pins what the reader then does with it — the recorded
        // segment's own start, not the start of the script and not a stale
        // offset borrowed from another segment.
        let version = makeVersion(id: "v1", segmentTexts: ["第一段内容。", "第二段内容。"])
        let saved = TeleprompterRunState(
            documentID: "doc",
            versionID: "v1",
            currentSegmentID: "segment-1",
            currentSegmentOffset: nil,
            mode: .manual
        )

        let position = TeleprompterReadingProgressRestorer.position(
            saved: saved,
            versions: [version],
            activeVersion: version
        )

        #expect(
            position == .init(segmentIndex: 1, utf16Offset: 0),
            "旧稿缺少句内偏移时必须回到该记录段的开头"
        )
    }

    @Test func importsBOMWithoutChangingSourceBytes() throws {
        let body = "# 标题\r\n\r\n😀欢迎。\n"
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(body.utf8)

        let source = try TeleprompterSourceImporter.importData(
            data,
            fileExtension: "md"
        )

        #expect(source.sourceText == body)
        #expect(source.hasBOM)
        #expect(source.formatHint == .markdown)
        #expect(source.originalUTF8Data == data)
    }

    @Test func rejectsInvalidUTF8NULAndEmptySource() {
        #expect(throws: TeleprompterPreparationError.self) {
            try TeleprompterSourceImporter.importData(Data([0xFF]), fileExtension: "txt")
        }
        #expect(throws: TeleprompterPreparationError.self) {
            try TeleprompterSourceImporter.importData(Data("a\0b".utf8), fileExtension: "txt")
        }
        #expect(throws: TeleprompterPreparationError.self) {
            try TeleprompterSourceImporter.importData(Data(" \r\n".utf8), fileExtension: "txt")
        }
    }

    @Test func sourceUnitsRoundTripUTF8AndDoNotSplitGrapheme() throws {
        let source = try TeleprompterSourceImporter.importData(
            Data("第一段。\r\n\r\n👩🏽‍💻 正文。第二句。".utf8),
            fileExtension: "txt"
        )
        let units = try TeleprompterSourceUnitBuilder(maxBudgetUnits: 24).build(source)

        #expect(units.map(\.rawText).joined().data(using: .utf8) == source.sourceText.data(using: .utf8))
        #expect(units.allSatisfy { $0.sourceRange.isValid(in: source.sourceText) })
        #expect(units.contains { $0.rawText.contains("👩🏽‍💻") })
        #expect(units.map(\.ordinal) == Array(0..<units.count))
    }

    @Test func sourceUnitsPreferParagraphBoundariesInsideBoundedWindows() throws {
        let paragraphs = (0..<8).map { "第\($0)段内容。" }.joined(separator: "\n\n")
        let source = try TeleprompterSourceImporter.importData(Data(paragraphs.utf8), fileExtension: "md")
        let units = try TeleprompterSourceUnitBuilder(maxBudgetUnits: 24).build(source)

        #expect(units.allSatisfy {
            $0.rawText
                .components(separatedBy: "\n\n")
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .count <= 1
        })
        #expect(units.map(\.rawText).joined().data(using: .utf8) == Data(paragraphs.utf8))
    }

    @Test func durationSeparatesKnownEnglishAndHanFromUncertainDigits() throws {
        let known = TeleprompterDurationEstimator.estimate("你好 hello world。")
        #expect(known.pointSeconds != nil)
        #expect(known.uncertaintyReasons.isEmpty)
        #expect(known.knownPartSeconds > 0)

        let uncertain = TeleprompterDurationEstimator.estimate("你好，版本 2.0 发布。")
        #expect(uncertain.pointSeconds == nil)
        #expect(uncertain.knownPartSeconds > 0)
        #expect(uncertain.uncertaintyReasons.contains("unresolvedPronunciation"))
    }

    @Test func timingPlanUsesOneWeightModeAndConservesBudget() throws {
        let source = try TeleprompterSourceImporter.importData(
            Data("第一句。第二句。第三句。".utf8),
            fileExtension: "txt"
        )
        let units = try TeleprompterSourceUnitBuilder(maxBudgetUnits: 600).build(source)
        let estimate = TeleprompterDurationEstimator.estimate(source.sourceText)
        let plan = try TeleprompterTimingPlanner.plan(
            sourceUnits: units,
            estimates: Array(repeating: estimate.pointSeconds, count: units.count),
            targetMinutes: 20
        )

        #expect(plan.weightMode == .estimatedDuration)
        #expect(plan.allocations.reduce(0) { $0 + $1.budgetSeconds } == plan.budgetSeconds)
        #expect(plan.budgetSeconds == 1_140)
        #expect(plan.budget(for: units.map(\.id)) == plan.budgetSeconds)
    }

    @Test func selectedTimingBudgetExcludesUnselectedSourceUnits() throws {
        let source = try TeleprompterSourceImporter.importData(
            Data("第一段。\n\n第二段。\n\n第三段。".utf8),
            fileExtension: "md"
        )
        let units = try TeleprompterSourceUnitBuilder().build(source)
        #expect(units.count == 3)
        let selected = Set(units.dropFirst().map(\.id))
        let plan = try TeleprompterTimingPlanner.plan(
            sourceUnits: units,
            estimates: Array(repeating: nil, count: units.count),
            targetMinutes: 5,
            selectedUnitIDs: selected
        )

        #expect(plan.budget(for: Array(selected)) == plan.budgetSeconds)
        #expect(plan.allocations.first?.budgetSeconds == 0)
    }

    @Test func unknownEstimateFallsBackToProxyWithoutClaimingDuration() throws {
        let source = try TeleprompterSourceImporter.importData(
            Data("第一句。second language مرحبا。".utf8),
            fileExtension: "txt"
        )
        let units = try TeleprompterSourceUnitBuilder().build(source)
        let estimate = TeleprompterDurationEstimator.estimate(source.sourceText)
        let plan = try TeleprompterTimingPlanner.plan(
            sourceUnits: units,
            estimates: Array(repeating: estimate.pointSeconds, count: units.count),
            targetMinutes: 5
        )

        #expect(estimate.pointSeconds == nil)
        #expect(plan.weightMode == .proxyCharacters)
        #expect(plan.allocations.allSatisfy { $0.budgetSeconds >= 0 })
        #expect(abs(plan.allocations.reduce(0) { $0 + $1.budgetSeconds } - plan.budgetSeconds) < 0.001)
    }

    @Test func targetMinutesMustBeIntegerBetweenOneAndOneHundredTwenty() {
        #expect(throws: TeleprompterPreparationError.self) {
            try TeleprompterTimingPlanner.validateTargetMinutes(0)
        }
        #expect(throws: TeleprompterPreparationError.self) {
            try TeleprompterTimingPlanner.validateTargetMinutes(121)
        }
        #expect(throws: TeleprompterPreparationError.self) {
            try TeleprompterTimingPlanner.validateTargetMinutes(1.5)
        }
        let valid = try? TeleprompterTimingPlanner.validateTargetMinutes(20)
        #expect(valid == 1_200)
    }

    /// 导入的两道容量闸门此前没有任何用例观察过（R1／R5）。它们挡在分片之前，
    /// 一旦失效，用户看到的不是「这份稿件太大」，而是分片阶段或预算阶段的另一种报错。
    @Test func importRejectsOversizedAndOverlongSources() {
        let long = Data(String(repeating: "这是一段测试用的稿件内容。", count: 200).utf8)

        #expect(throws: TeleprompterPreparationError.self) {
            try TeleprompterSourceImporter.importData(
                long,
                fileExtension: "txt",
                limits: .init(maxBytes: 1_024, maxSourceUnits: 20_000, maxReferenceSeconds: 7_200)
            )
        }
        #expect(throws: TeleprompterPreparationError.self) {
            try TeleprompterSourceImporter.importData(
                long,
                fileExtension: "txt",
                limits: .init(maxBytes: 1_048_576, maxSourceUnits: 20_000, maxReferenceSeconds: 1)
            )
        }
    }

    /// `.markdown` 是用户在文件选择器里能选到的扩展名，导入却只认 `.md`（R2）。
    @Test func importAcceptsBothMarkdownExtensions() throws {
        for ext in ["md", "markdown"] {
            let source = try TeleprompterSourceImporter.importData(
                Data("# 标题\n\n正文。".utf8),
                fileExtension: ext
            )
            #expect(source.formatHint == .markdown, "\(ext) 应被识别为 Markdown")
        }
    }

    /// 段落在空白之后起头时不是上一句的延续（R7）。这个标记决定阅读时是否把
    /// 两段当作同一句话连读，错了会让排版出现「句中换行」。
    @Test func unitsAfterWhitespaceAreNotMarkedAsContinuation() throws {
        let source = try TeleprompterSourceImporter.importData(
            Data("第一段 内容。".utf8),
            fileExtension: "txt"
        )
        let units = try TeleprompterSourceUnitBuilder(maxBudgetUnits: 7).build(source)

        let afterWord = try #require(units.first { $0.rawText == "段 " })
        let afterSpace = try #require(units.first { $0.rawText == "内容" })
        #expect(afterWord.continuation, "紧接文字之后的单元是上一句的延续")
        #expect(!afterSpace.continuation, "空白之后的单元是新的一句，不是延续")
    }

    /// 分片数**恰好等于**上限必须成功，只有超过才拒绝（R8）。
    @Test func sourceUnitLimitRejectsOnlyBeyondTheLimit() throws {
        let source = try TeleprompterSourceImporter.importData(
            Data("第一段。\n\n第二段。\n\n第三段。".utf8),
            fileExtension: "md"
        )
        let units = try TeleprompterSourceUnitBuilder().build(source)
        try #require(units.count == 3)

        #expect(throws: TeleprompterPreparationError.self) {
            try TeleprompterSourceUnitBuilder(maxSourceUnits: 2).build(source)
        }
        let atLimit = try TeleprompterSourceUnitBuilder(maxSourceUnits: 3).build(source)
        #expect(atLimit.count == 3)
    }

    /// CRLF 空行也必须被当作段落边界。现有段落用例全用 LF，而这一族此前零覆盖。
    @Test func sourceUnitsRespectWindowsParagraphBoundaries() throws {
        let paragraphs = (0..<6).map { "第\($0)段内容。" }.joined(separator: "\r\n\r\n")
        let source = try TeleprompterSourceImporter.importData(Data(paragraphs.utf8), fileExtension: "md")
        let units = try TeleprompterSourceUnitBuilder(maxBudgetUnits: 24).build(source)

        #expect(units.allSatisfy {
            $0.rawText
                .components(separatedBy: "\r\n\r\n")
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .count <= 1
        })
        #expect(units.map(\.rawText).joined().data(using: .utf8) == Data(paragraphs.utf8))
    }

    /// 小数、版本号与域名不能在点号处被切开（R20）。跨单元切开的小数会被对齐器
    /// 与保真门禁当成两段文本。
    @Test func sourceUnitsDoNotSplitDecimalsOrVersions() throws {
        let source = try TeleprompterSourceImporter.importData(
            Data("耗时 3.14 秒。".utf8),
            fileExtension: "txt"
        )
        // 窗口正好停在「3.」之后：小数点若被当成切点，这一段就会以「.」结尾。
        let units = try TeleprompterSourceUnitBuilder(maxBudgetUnits: 9).build(source)
        let rebuilt = units.map(\.rawText).joined()

        #expect(!units.contains { $0.rawText.hasSuffix(".") })
        #expect(!units.contains { $0.rawText.hasPrefix(".") })
        #expect(rebuilt.contains("3.14"))
        #expect(units.allSatisfy { $0.sourceRange.isValid(in: source.sourceText) })
    }

    /// 时长区间由已估出的部分派生，两端都要有明确的系数（R13）。
    @Test func durationRangeIsDerivedFromTheKnownPart() throws {
        let estimate = TeleprompterDurationEstimator.estimate("这是一段用来检查时长区间的稿件。")
        let known = try #require(estimate.knownPartSeconds)
        let range = try #require(estimate.rangeSeconds)

        #expect(abs(range.lowerBound - known * 0.8) < 0.0001)
        #expect(abs(range.upperBound - known * 1.25) < 0.0001)
    }

    /// 校准系数被夹在 0.5…2.0（R14）。不夹的话，用户把语速调到极慢时估算会小到
    /// 与「这段话念不完」同量级，而界面照常显示为可用估算。
    @Test func calibrationFactorIsClampedToThePolicyRange() {
        let text = "这是一段用来检查校准系数夹取的稿件。"
        let atPolicyFloor = TeleprompterDurationEstimator.estimate(
            text,
            calibrationFactor: TeleprompterTimingPolicy.minimumCalibrationFactor
        )
        let belowFloor = TeleprompterDurationEstimator.estimate(text, calibrationFactor: 0.01)
        let atCeiling = TeleprompterDurationEstimator.estimate(
            text,
            calibrationFactor: TeleprompterTimingPolicy.maximumCalibrationFactor
        )
        let aboveCeiling = TeleprompterDurationEstimator.estimate(text, calibrationFactor: 50)

        #expect(belowFloor.knownPartSeconds == atPolicyFloor.knownPartSeconds)
        #expect(aboveCeiling.knownPartSeconds == atCeiling.knownPartSeconds)
    }

    /// 估算全是 0 秒也要能建出计划（R18）。没有下限的话总权重为 0，
    /// 用户看到的是「无法为这份稿件建立时间预算」，而真实原因是稿件没估出时长。
    @Test func zeroEstimatesStillProduceAPlan() throws {
        let source = try TeleprompterSourceImporter.importData(
            Data("第一段。\n\n第二段。\n\n第三段。".utf8),
            fileExtension: "md"
        )
        let units = try TeleprompterSourceUnitBuilder().build(source)
        let plan = try TeleprompterTimingPlanner.plan(
            sourceUnits: units,
            estimates: Array(repeating: 0, count: units.count),
            targetMinutes: 5
        )

        #expect(plan.allocations.allSatisfy { $0.weight > 0 })
        #expect(abs(plan.allocations.reduce(0) { $0 + $1.budgetSeconds } - plan.budgetSeconds) < 0.001)
    }

    /// 只有一个冒号也是 URL 标记（R19）。`mailto:` 这类地址不含数字也不含斜杠，
    /// 去掉这道判断后它们会被判成「可精确估算」。
    @Test func aColonAloneIsTreatedAsAURLMarker() {
        let metrics = TeleprompterDurationEstimator.metrics(in: "发到 mailto:someone")
        #expect(!metrics.uncertaintyReasons.isEmpty)

        let estimate = TeleprompterDurationEstimator.estimate("发到 mailto:someone")
        #expect(estimate.pointSeconds == nil)
        #expect(estimate.uncertaintyReasons.contains("unresolvedPronunciation"))
    }

    private func makeVersion(id: String, segmentTexts: [String]) -> TeleprompterVersion {
        TeleprompterVersion(
            id: id,
            documentID: "doc",
            sourceText: segmentTexts.joined(),
            segments: segmentTexts.enumerated().map { index, text in
                TeleprompterSegment(
                    // Segment identities come from source blocks, so they stay
                    // stable across versions built from the same source.
                    id: "segment-\(index)",
                    ordinal: index,
                    sourceRange: .init(start: 0, end: text.utf16.count),
                    text: text
                )
            },
            analysisSource: .ai
        )
    }
}
