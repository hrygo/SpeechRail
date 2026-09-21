import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

struct TeleprompterPreparationPromptsTests {
    @Test func mapUsesLocalCoordinatesAndDecoderRestoresGlobalSources() throws {
        let targets = [24, 25].enumerated().map { index, id in
            TeleprompterSourceUnit(id: id, ordinal: id, sourceRevisionID: "r",
                                  sourceRange: .init(start: index * 3, end: index * 3 + 3),
                                  rawText: "正文。", continuation: false, budgetUnits: 9)
        }
        let prompt = try TeleprompterPreparationPromptBuilder.map(
            targets: targets, formatHint: .plaintext, globalTargetSeconds: 600,
            localBudgetSeconds: 10, weightMode: .estimatedDuration, pace: .natural,
            operation: .tighten, currentBlocks: [.init(startUnit: 24, endUnit: 26, text: "正文。正文。")],
            readOnlyContext: .init(before: [.init(id: 23, rawText: "前文")],
                                   after: [.init(id: 26, rawText: "后文")])
        )
        let input = try JSONDecoder().decode(TeleprompterPreparationMapInput.self, from: Data(prompt.input.utf8))
        #expect(input.targets.map(\.id) == [0, 1])
        #expect(input.currentBlocks[0].startUnit == 0)
        #expect(input.currentBlocks[0].endUnit == 2)
        #expect(input.readOnlyContext.before[0].id == -1)
        #expect(input.readOnlyContext.after[0].id == 2)
        let output = try TeleprompterMapDecoder().decode(
            #"{"schema_version":"teleprompter.preparation.v2","blocks":[{"start_unit":0,"end_unit":2,"mode":"speak","text":"正文。正文。","issues":[]}]}"#,
            targets: targets, maxGroupUnits: 8
        )
        #expect(output.blocks[0].startUnit == 24)
        #expect(output.blocks[0].endUnit == 26)
    }

    @Test func escapedDuplicateJSONKeysAreRejected() throws {
        #expect(throws: (any Error).self) {
            try TeleprompterStrictJSON.object(from: Data(#"{"name":1,"\u006eame":2}"#.utf8))
        }
    }

    private func sourceUnits() throws -> [TeleprompterSourceUnit] {
        let source = try TeleprompterSourceImporter.importData(
            Data("## 上线条件\n\n- 测试通过后方可上线\n- 延迟不得超过 200 ms。".utf8),
            fileExtension: "md"
        )
        return try TeleprompterSourceUnitBuilder(maxBudgetUnits: 24).build(source)
    }

    @Test func mapPromptSeparatesInstructionsFromDynamicSourceAndUsesSchema() throws {
        let units = try sourceUnits()
        let prompt = try TeleprompterPreparationPromptBuilder.map(
            targets: units,
            formatHint: .markdown,
            globalTargetSeconds: 1_200,
            localBudgetSeconds: 20,
            weightMode: .estimatedDuration,
            pace: .natural
        )

        #expect(!prompt.instructions.contains(units[0].rawText))
        #expect(prompt.instructions.contains("不得摘要"))
        #expect(prompt.input.contains("protected_literals"))
        #expect(prompt.input.contains("200"))
        #expect(prompt.input.contains("ms"))
        #expect(prompt.input.contains("calibration_factor"))
        #expect(prompt.input.contains("cjk_units_per_minute"))
        #expect(prompt.schemaVersion == "teleprompter.preparation.v2")
        #expect((TeleprompterPreparationJSONSchema.map["strict"] as? Bool) == true)
    }

    @Test func mapDecoderRestoresSpeakReviewAndOmitAndRequiresCompleteCoverage() throws {
        let units = try sourceUnits()
        let first = units[0].id
        let last = units[units.count - 1].id + 1
        let json = """
        {"schema_version":"teleprompter.preparation.v2","blocks":[
          {"start_unit":\(first),"end_unit":\(first + 1),"mode":"speak","text":"上线条件。","issues":[]},
          {"start_unit":\(first + 1),"end_unit":\(last - 1),"mode":"review","text":"","issues":["format_ambiguity"]},
          {"start_unit":\(last - 1),"end_unit":\(last),"mode":"omit","text":"","issues":["nonspoken_content"]}
        ]}
        """

        let output = try TeleprompterMapDecoder().decode(json, targets: units, maxGroupUnits: 8)
        #expect(output.blocks.map(\.mode) == [.speak, .review, .omit])
        #expect(output.blocks.map(\.startUnit) == [first, first + 1, last - 1])
    }

    @Test func groupingAndRewriteKeepSourceOwnershipOutsideTheModel() throws {
        let units = try sourceUnits()
        guard units.count >= 4 else { return }
        let groupingJSON = #"{"schema_version":"teleprompter.grouping.v1","groups":[{"start_unit":0,"end_unit":2},{"start_unit":2,"end_unit":4}]}"#
        let grouping = try TeleprompterGroupingDecoder().decode(
            groupingJSON,
            targets: Array(units.prefix(4)),
            maxGroupUnits: 8
        )
        let groups = grouping.groups.map { range in
            TeleprompterRewriteGroup(
                id: "block-\(range.startUnit)-\(range.endUnit)",
                sourceUnits: units.filter { $0.id >= range.startUnit && $0.id < range.endUnit }
                    .map { .init(id: $0.id, rawText: $0.rawText) },
                protectedLiterals: units.filter { $0.id >= range.startUnit && $0.id < range.endUnit }
                    .flatMap { TeleprompterProtectedLiteralExtractor.extract(from: $0.rawText) },
                budgetSeconds: 10
            )
        }
        let rewriteJSON = String(decoding: try JSONEncoder().encode(TeleprompterRewriteOutput(blocks: groups.map {
            .init(blockID: $0.id, mode: .speak, text: $0.sourceUnits.map(\.rawText).joined(), issues: [])
        })), as: UTF8.self)
        let output = try TeleprompterRewriteDecoder().decode(
            rewriteJSON,
            groups: groups
        )
        #expect(output.blocks.map(\.blockID) == groups.map(\.id))
    }

    @Test func groupingRejectsNonRangeFieldsAndIncompleteCoverage() throws {
        let units = try sourceUnits()
        let extraField = #"{"schema_version":"teleprompter.grouping.v1","groups":[{"start_unit":0,"end_unit":1,"text":"不应由分组阶段返回"},{"start_unit":1,"end_unit":3}]}"#
        do {
            _ = try TeleprompterGroupingDecoder().decode(extraField, targets: units, maxGroupUnits: 8)
            Issue.record("grouping must reject rewrite fields")
        } catch let error as TeleprompterPreparationError {
            #expect(error.diagnostic?.code == .schemaKeys)
        }

        let gap = #"{"schema_version":"teleprompter.grouping.v1","groups":[{"start_unit":0,"end_unit":1},{"start_unit":2,"end_unit":3}]}"#
        do {
            _ = try TeleprompterGroupingDecoder().decode(gap, targets: units, maxGroupUnits: 8)
            Issue.record("grouping must cover every source unit")
        } catch let error as TeleprompterPreparationError {
            #expect(error.diagnostic?.code == .rangeGap)
        }
    }

    @Test func rewriteRejectsUnknownAndDuplicateBlockIDs() throws {
        let groups = [
            TeleprompterRewriteGroup(
                id: "block-a",
                sourceUnits: [.init(id: 0, rawText: "第一段。")],
                budgetSeconds: 10
            ),
            TeleprompterRewriteGroup(
                id: "block-b",
                sourceUnits: [.init(id: 1, rawText: "第二段。")],
                budgetSeconds: 10
            )
        ]
        let unknown = #"{"schema_version":"teleprompter.rewrite.v1","blocks":[{"block_id":"block-a","mode":"speak","text":"第一段。","issues":[]},{"block_id":"foreign","mode":"speak","text":"第二段。","issues":[]}]}"#
        do {
            _ = try TeleprompterRewriteDecoder().decode(unknown, groups: groups)
            Issue.record("rewrite must reject unknown IDs")
        } catch let error as TeleprompterPreparationError {
            #expect(error.diagnostic?.code == .unknownBlock)
        }

        let duplicate = #"{"schema_version":"teleprompter.rewrite.v1","blocks":[{"block_id":"block-a","mode":"speak","text":"第一段。","issues":[]},{"block_id":"block-a","mode":"speak","text":"第一段。","issues":[]}]}"#
        do {
            _ = try TeleprompterRewriteDecoder().decode(duplicate, groups: groups)
            Issue.record("rewrite must reject duplicate IDs")
        } catch let error as TeleprompterPreparationError {
            #expect(error.diagnostic?.code == .duplicateBlock)
        }
    }

    @Test func mapDecoderRejectsUnknownFieldsGapsEmptySpeakAndInvalidIssues() throws {
        let units = try sourceUnits()
        let sourceText = units.map(\.rawText).joined()
        let escapedSourceText = sourceText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let valid = """
        {"schema_version":"teleprompter.preparation.v2","blocks":[{"start_unit":0,"end_unit":\(units.count),"mode":"speak","text":"\(escapedSourceText)","issues":[]}]}
        """
        let invalids = [
            valid.replacingOccurrences(of: "\"issues\":[]", with: "\"issues\":[],\"extra\":true"),
            valid.replacingOccurrences(of: "\"start_unit\":0", with: "\"start_unit\":1"),
            valid.replacingOccurrences(of: "\"text\":\"\(escapedSourceText)\"", with: "\"text\":\" \""),
            valid.replacingOccurrences(of: "\"issues\":[]", with: "\"issues\":[\"missing_context\"]"),
            valid.replacingOccurrences(of: "\"schema_version\":\"teleprompter.preparation.v2\"", with: "\"schema_version\":\"teleprompter.preparation.v1\"")
        ]

        for json in invalids {
            #expect(throws: TeleprompterPreparationError.self) {
                try TeleprompterMapDecoder().decode(json, targets: units, maxGroupUnits: 8)
            }
        }
    }

    @Test func mapDecoderRejectsDroppingProtectedNumericLiteral() throws {
        let units = try sourceUnits()
        let json = """
        {"schema_version":"teleprompter.preparation.v2","blocks":[{"start_unit":0,"end_unit":\(units.count),"mode":"speak","text":"上线条件。延迟不得超过。","issues":[]}]}
        """

        #expect(throws: TeleprompterPreparationError.self) {
            try TeleprompterMapDecoder().decode(json, targets: units, maxGroupUnits: 8)
        }
    }

    @Test func duplicateJSONKeysAreRejectedBeforeDecoding() throws {
        let units = try sourceUnits()
        let json = """
        {"schema_version":"teleprompter.preparation.v2","schema_version":"teleprompter.preparation.v2","blocks":[{"start_unit":0,"end_unit":\(units.count),"mode":"speak","text":"正文","issues":[]}]}
        """
        do {
            _ = try TeleprompterMapDecoder().decode(json, targets: units, maxGroupUnits: 8)
            Issue.record("duplicate JSON keys must be rejected")
        } catch let error as TeleprompterPreparationError {
            #expect(error.diagnostic?.code == .duplicateKey)
        }
    }

    @Test func mapDecoderReportsRangeGapWithoutExposingSourceText() throws {
        let units = try sourceUnits()
        let json = """
        {"schema_version":"teleprompter.preparation.v2","blocks":[{"start_unit":1,"end_unit":\(units.count),"mode":"speak","text":"正文","issues":[]}]}
        """
        do {
            _ = try TeleprompterMapDecoder().decode(json, targets: units, maxGroupUnits: 8)
            Issue.record("a range gap must be rejected")
        } catch let error as TeleprompterPreparationError {
            #expect(error.diagnostic?.code == .rangeGap)
            #expect(error.diagnostic?.fieldPath == "blocks[0].start_unit")
            #expect(error.diagnostic?.rawValue == nil)
        }
    }

    @Test func reduceDecoderEnforcesEditableWhitelistAndMutualExclusion() throws {
        let valid = #"{"schema_version":"teleprompter.reduction.v1","patches":[{"block_id":"b2","revision":3,"text":"下一段。"}],"review_block_ids":[]}"#
        let output = try TeleprompterReduceDecoder().decode(
            valid,
            editableBlocks: [TeleprompterReduceEditableBlock(id: "b2", revision: 3, text: "下一段，下一段。")]
        )
        #expect(output.patches.count == 1)
        #expect(output.patches[0].blockID == "b2")

        for json in [
            valid.replacingOccurrences(of: "\"b2\"", with: "\"foreign\""),
            valid.replacingOccurrences(of: "\"revision\":3", with: "\"revision\":2"),
            valid.replacingOccurrences(of: "\"review_block_ids\":[]", with: "\"review_block_ids\":[\"b2\"]")
        ] {
            #expect(throws: TeleprompterPreparationError.self) {
                try TeleprompterReduceDecoder().decode(
                    json,
                    editableBlocks: [TeleprompterReduceEditableBlock(id: "b2", revision: 3, text: "下一段。")]
                )
            }
        }
    }

    @Test func reduceDecoderRejectsDroppingProtectedLiteral() throws {
        let valid = #"{"schema_version":"teleprompter.reduction.v1","patches":[{"block_id":"b2","revision":3,"text":"延迟不得超过。"}],"review_block_ids":[]}"#
        let editable = TeleprompterReduceEditableBlock(
            id: "b2",
            revision: 3,
            text: "延迟不得超过 200 ms。",
            protectedLiterals: ["200 ms"]
        )

        #expect(throws: TeleprompterPreparationError.self) {
            try TeleprompterReduceDecoder().decode(valid, editableBlocks: [editable])
        }
    }

    @Test func reviewCopyKeepsTheDefaultPathPlainAndHidesInternalTerms() {
        #expect(TeleprompterReviewCopy.successTitle == "AI 已完成整理")
        #expect(TeleprompterReviewCopy.successMessage.contains("原稿未被覆盖"))
        #expect(TeleprompterReviewCopy.readingTitle == "整理后的朗读稿")
        #expect(!TeleprompterReviewCopy.readingTitle.contains("来源组"))
        #expect(TeleprompterReviewCopy.compareSourceLabel == "对照原稿")
        #expect(TeleprompterReviewCopy.advancedEditLabel == "编辑本段")
        #expect(TeleprompterReviewCopy.blockTitle(ordinal: 0) == "第 1 段")
    }
}
