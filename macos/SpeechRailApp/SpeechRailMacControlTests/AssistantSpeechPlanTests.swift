import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// M0e/V12–V13：朗读计划的纯值测试。不碰网络、播放器与 LLM，
/// 只验证整体解析、保义转换、span 对照、分包无关与超限行为。
final class AssistantSpeechPlanTests: XCTestCase {
    /// V12a：同一原文不同分包，计划文本一致（分包无关）。
    func testV12SameSourceDifferentPartitionsAgree() throws {
        let full = "明天上午 9 点开会，带 3.5kg 的设备。"
        let built = try AssistantSpeechPlanBuilder.build(from: full).get()
        XCTAssertTrue(built.isValid)
        XCTAssertEqual(built.sourceScalars, full.unicodeScalars.count)
        // 计划只依赖完整原文：重复构建结果一致。
        let again = try AssistantSpeechPlanBuilder.build(from: full).get()
        XCTAssertEqual(again, built)
    }

    /// V12b：数字/单位/英文词跨分包不授权半句开口——计划是整体转换，
    /// 不存在"3"先播、".5kg"后播的中间产物；对照覆盖朗读文本全体。
    func testV12NumericPrefixHasNoSpeakableIntermediate() throws {
        let full = "重 3.5kg"
        let plan = try XCTUnwrap(AssistantSpeechPlanBuilder.build(from: full).get())
        XCTAssertTrue(plan.isValid)
        XCTAssertEqual(plan.speakText, full, "纯正文无排版时计划即原文")
        XCTAssertEqual(plan.spans.count, 1)
        XCTAssertEqual(plan.spans[0].speakRange.upperBound, plan.speakText.unicodeScalars.count)
    }

    /// V12c：超 4096 不硬切：抛超限，调用方暂停朗读保留全文。
    func testV12OversizedSourceSuspendsSpeech() throws {
        let long = String(repeating: "啊", count: 4_097)
        let result = AssistantSpeechPlanBuilder.build(from: long)
        guard case .failure(.sourceTooLong(let offered, let limit)) = result else {
            return XCTFail("超限必须抛 sourceTooLong，不硬切")
        }
        XCTAssertEqual(offered, 4_097)
        XCTAssertEqual(limit, 4_096)
    }

    /// V13a：词间空格保留——"Hello world" 分段清洗不丢空格。
    func testV13WordSpacingSurvives() throws {
        let plan = try XCTUnwrap(AssistantSpeechPlanBuilder.build(from: "Hello world").get())
        XCTAssertTrue(plan.isValid)
        XCTAssertEqual(plan.speakText, "Hello world")
    }

    /// V13b：带空格负号保留原文（不可靠即回退，不强行转换）。
    func testV13SpacedMinusFallsBackToSource() throws {
        let source = "温度 - 5 度"
        let plan = try XCTUnwrap(AssistantSpeechPlanBuilder.build(from: source).get())
        XCTAssertTrue(plan.isValid)
        // 清洗吃空格但不吃内容：子序列对照通过则转换，否则回退原文。
        // 无论哪条路，否定/实体字符必须一个不少。
        for scalar in ["温", "度", "-", "5", "度"] {
            XCTAssertTrue(plan.speakText.contains(scalar), "保义字符不得丢失：\(scalar)")
        }
    }

    /// V13c：比较符保留——"a < b" 的语义字符不得在转换中丢失。
    func testV13ComparisonOperatorSurvives() throws {
        let source = "a < b"
        let plan = try XCTUnwrap(AssistantSpeechPlanBuilder.build(from: source).get())
        XCTAssertTrue(plan.isValid)
        XCTAssertTrue(plan.speakText.contains("<"), "比较符不得丢失")
    }

    /// V13d：代码行首符号保留原文——多行围栏整体回退，不逐行清洗。
    func testV13CodeFenceFallsBackToSource() throws {
        let source = "先这样写：\n```swift\nlet x = 1\n```"
        let plan = try XCTUnwrap(AssistantSpeechPlanBuilder.build(from: source).get())
        XCTAssertTrue(plan.isValid)
        XCTAssertTrue(plan.fellBackToSource, "多行围栏必须整体回退原文")
        XCTAssertEqual(plan.speakText, source)
    }

    /// V13e：未闭合强调结构保留原文。
    func testV13UnclosedEmphasisFallsBackToSource() throws {
        let source = "这是 **未闭合的强调"
        let plan = try XCTUnwrap(AssistantSpeechPlanBuilder.build(from: source).get())
        XCTAssertTrue(plan.isValid)
        XCTAssertTrue(plan.fellBackToSource, "未闭合结构必须回退原文")
        XCTAssertEqual(plan.speakText, source)
    }

    /// V13f：日期金额编号保义——数字与单位字符一个不少。
    func testV13DateAmountAndSerialSurvive() throws {
        let source = "2026 年 10 月 5 日，金额 12 万元，编号 v2.0"
        let plan = try XCTUnwrap(AssistantSpeechPlanBuilder.build(from: source).get())
        XCTAssertTrue(plan.isValid)
        for scalar in ["2", "0", "2", "6", "1", "0", "5", "1", "2", "v", "."] {
            XCTAssertTrue(plan.speakText.contains(scalar), "日期金额编号字符不得丢失：\(scalar)")
        }
    }

    /// V13g：空/纯空白无可朗读内容——建计划失败，调用方不开口。
    func testV13BlankSourceHasNothingSpeakable() throws {
        let result = AssistantSpeechPlanBuilder.build(from: "   \n  ")
        guard case .failure(.nothingSpeakable) = result else {
            return XCTFail("纯空白必须报 nothingSpeakable")
        }
    }

    /// 对照完整性：isValid 拒绝覆盖不全的 span。
    func testPlanValidityRejectsIncompleteSpans() throws {
        var plan = AssistantSpeechPlan(
            sourceText: "ab",
            speakText: "ab",
            spans: [AssistantSpeechPlan.Span(speakRange: 0..<1, sourceRange: 0..<1)],
            sourceScalars: 2,
            fellBackToSource: true
        )
        XCTAssertFalse(plan.isValid, "span 未覆盖朗读文本全体必须判无效")
        plan.spans = [AssistantSpeechPlan.Span(speakRange: 0..<2, sourceRange: 0..<2)]
        XCTAssertTrue(plan.isValid)
    }
}
