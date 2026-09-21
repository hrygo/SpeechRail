import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

struct TeleprompterPreparationDomainTests {
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
}
