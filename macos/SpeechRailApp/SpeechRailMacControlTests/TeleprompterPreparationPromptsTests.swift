import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

struct TeleprompterPreparationPromptsTests {
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
        #expect(prompt.instructions.contains("不摘要"))
        #expect(prompt.input.contains("protected_literals"))
        #expect(prompt.input.contains("200"))
        #expect(prompt.input.contains("ms"))
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

    @Test func mapDecoderRejectsUnknownFieldsGapsEmptySpeakAndInvalidIssues() throws {
        let units = try sourceUnits()
        let valid = """
        {"schema_version":"teleprompter.preparation.v2","blocks":[{"start_unit":0,"end_unit":\(units.count),"mode":"speak","text":"正文","issues":[]}]}
        """
        let invalids = [
            valid.replacingOccurrences(of: "\"issues\":[]", with: "\"issues\":[],\"extra\":true"),
            valid.replacingOccurrences(of: "\"start_unit\":0", with: "\"start_unit\":1"),
            valid.replacingOccurrences(of: "\"text\":\"正文\"", with: "\"text\":\" \""),
            valid.replacingOccurrences(of: "\"issues\":[]", with: "\"issues\":[\"missing_context\"]"),
            valid.replacingOccurrences(of: "\"schema_version\":\"teleprompter.preparation.v2\"", with: "\"schema_version\":\"teleprompter.preparation.v1\"")
        ]

        for json in invalids {
            #expect(throws: TeleprompterPreparationError.self) {
                try TeleprompterMapDecoder().decode(json, targets: units, maxGroupUnits: 8)
            }
        }
    }

    @Test func duplicateJSONKeysAreRejectedBeforeDecoding() throws {
        let units = try sourceUnits()
        let json = """
        {"schema_version":"teleprompter.preparation.v2","schema_version":"teleprompter.preparation.v2","blocks":[{"start_unit":0,"end_unit":\(units.count),"mode":"speak","text":"正文","issues":[]}]}
        """
        #expect(throws: TeleprompterPreparationError.self) {
            try TeleprompterMapDecoder().decode(json, targets: units, maxGroupUnits: 8)
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
}
