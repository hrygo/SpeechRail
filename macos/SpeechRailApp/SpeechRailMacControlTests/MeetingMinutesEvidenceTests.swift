import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 结构化纪要的证据核对（方案 MA-08 / 场景 MC-33～MC-38）。
///
/// 钉的是三条底线：
/// - **引文存在 ≠ 支持结论**：引用合法但语气、数字、负责人对不上，一律进复核；
/// - **引用身份不可兜底**：不存在或属于别的会议的来源单元一律拒绝，
///   绝不按序号去别处猜一个（MC-35）；
/// - **错误结果保留但不升可信**：被拒的条目仍留在正文里让人看得见，
///   但整版标成需核对，不会被当成"整理好了"。
final class MeetingMinutesEvidenceTests: XCTestCase {
    private func unit(
        _ id: String,
        _ text: String,
        lineID: String? = nil
    ) -> MinutesSourceUnit {
        MinutesSourceUnit(
            id: id,
            lineID: lineID ?? "line-\(id)",
            ordinal: Int(id.dropFirst()) ?? 0,
            speaker: "张三",
            text: text,
            startSeconds: 0
        )
    }

    private func candidate(
        decisions: [MinutesCandidateV2.DecisionItem] = [],
        actions: [MinutesCandidateV2.ActionItem] = [],
        overview: [MinutesCandidateV2.OverviewItem] = [],
        openQuestions: [MinutesCandidateV2.OpenQuestionItem] = []
    ) -> MinutesCandidateV2 {
        MinutesCandidateV2(
            title: "发布评审",
            overview: overview,
            decisions: decisions,
            actions: actions,
            openQuestions: openQuestions,
            confidenceNotes: ""
        )
    }

    // MARK: - MC-35 引用身份

    /// MC-35：引用不存在的来源单元一律拒绝，**不按序号兜底**指向另一场。
    func testUnknownSourceUnitIsRejectedWithoutOrdinalFallback() {
        let units = [unit("u1", "今天讨论发布节奏。")]
        let subject = candidate(decisions: [
            .init(
                localID: "d1",
                text: "决定下周发布。",
                modality: .decided,
                conditions: [],
                // u9 不在这份来源单元集合里——多半是模型从别的会议搬来的。
                sourceUnitIDs: ["u9"]
            ),
        ])
        let report = MinutesEvidenceValidator.validate(candidate: subject, units: units)
        XCTAssertTrue(report.needsReview)
        XCTAssertEqual(report.rejectedCount, 1)
        let finding = report.findings(for: "d1").first
        XCTAssertEqual(finding?.verdict, .rejected)
        XCTAssertTrue(finding?.reason.contains("u9") ?? false, "原因要指名是哪个 id 不存在")
    }

    /// 另一场会议的来源单元**不在**本次集合里，所以同样被拒——
    /// 这正是"绝不兜底指向同 ordinal 的另一场"的落点。
    func testUnitFromAnotherMeetingIsNotAccepted() {
        let thisMeeting = [unit("u1", "本场第一句。")]
        let otherMeeting = [unit("u1", "别场的第一句。"), unit("u2", "别场的第二句。")]
        let subject = candidate(decisions: [
            .init(localID: "d1", text: "决定下周发布。", modality: .decided, conditions: [],
                  sourceUnitIDs: ["u2"]),
        ])
        let report = MinutesEvidenceValidator.validate(candidate: subject, units: thisMeeting)
        XCTAssertEqual(report.rejectedCount, 1, "别场的 u2 不该因为本场没有它就通过")
        // 同一份候选放到它真正的会议里就成立——说明拒的是身份，不是内容。
        let elsewhere = MinutesEvidenceValidator.validate(candidate: subject, units: otherMeeting)
        XCTAssertEqual(elsewhere.rejectedCount, 0)
    }

    /// 没有指明依据的结论保留，但必须标复核。
    func testConclusionWithoutSourceUnitsNeedsReview() {
        let subject = candidate(decisions: [
            .init(localID: "d1", text: "大家一致同意。", modality: .decided, conditions: [], sourceUnitIDs: []),
        ])
        let report = MinutesEvidenceValidator.validate(candidate: subject, units: [unit("u1", "随便一句。")])
        XCTAssertTrue(report.needsReview)
        XCTAssertEqual(report.rejectedCount, 0, "没指依据不等于引用错了，只是站不住")
    }

    // MARK: - MC-37 语气与撤回

    /// MC-37：原文是建议，结论写成"已决定"——引用存在也不算数。
    func testProposalWrittenAsDecisionNeedsReview() {
        let units = [unit("u1", "我建议先做灰度看看效果。")]
        let subject = candidate(decisions: [
            .init(localID: "d1", text: "决定先做灰度。", modality: .decided, conditions: [], sourceUnitIDs: ["u1"]),
        ])
        let report = MinutesEvidenceValidator.validate(candidate: subject, units: units)
        XCTAssertTrue(report.needsReview)
        XCTAssertTrue(
            report.findings(for: "d1").contains { $0.reason.contains("建议") },
            "要指出原文是建议而结论写成已决定"
        )
    }

    /// MC-37：原文带条件而结论没写条件，也不算核对通过。
    func testConditionalSourceWithoutStatedConditionNeedsReview() {
        let units = [unit("u1", "如果灰度数据达标，我们再决定是否全量发布。")]
        let subject = candidate(decisions: [
            .init(localID: "d1", text: "将全量发布。", modality: .decided, conditions: [], sourceUnitIDs: ["u1"]),
        ])
        let report = MinutesEvidenceValidator.validate(candidate: subject, units: units)
        XCTAssertTrue(report.needsReview)
    }

    /// 条件如实写出来时就不该误报——验证器不能变成"一律标复核"的噪声源。
    func testStatedConditionPassesWithoutFinding() {
        let units = [unit("u1", "如果灰度数据达标，我们再决定是否全量发布。")]
        let subject = candidate(decisions: [
            .init(
                localID: "d1",
                text: "灰度数据达标后再决定是否全量发布。",
                modality: .conditional,
                conditions: ["灰度数据达标"],
                sourceUnitIDs: ["u1"]
            ),
        ])
        let report = MinutesEvidenceValidator.validate(candidate: subject, units: units)
        XCTAssertFalse(report.needsReview, "如实保留条件与语气就不该标复核：\(report.findings)")
    }

    /// MC-37：会上撤回的决定，不能还写成"已决定"。
    func testRetractedDecisionNeedsReview() {
        let units = [unit("u1", "上次说的那个方案先不做了，撤回。")]
        let subject = candidate(decisions: [
            .init(localID: "d1", text: "按原方案推进。", modality: .decided, conditions: [], sourceUnitIDs: ["u1"]),
        ])
        let report = MinutesEvidenceValidator.validate(candidate: subject, units: units)
        XCTAssertTrue(report.needsReview)
        XCTAssertTrue(report.findings(for: "d1").contains { $0.reason.contains("撤回") })
    }

    // MARK: - MC-38 数字、单位、负责人、期限

    /// MC-38：结论里的数字在所引原文里找不到——听错或改了单位。
    func testNumberNotInSourceNeedsReview() {
        let units = [unit("u1", "预算是 3 万元。")]
        let subject = candidate(decisions: [
            .init(localID: "d1", text: "预算定为 30 万元。", modality: .decided, conditions: [], sourceUnitIDs: ["u1"]),
        ])
        let report = MinutesEvidenceValidator.validate(candidate: subject, units: units)
        XCTAssertTrue(report.needsReview)
        XCTAssertTrue(report.findings(for: "d1").contains { $0.reason.contains("30") })
    }

    /// 小数与原文一致时不误报。
    func testMatchingDecimalNumberPasses() {
        let units = [unit("u1", "预算是 3.5 万元，按季度拨。")]
        let subject = candidate(decisions: [
            .init(localID: "d1", text: "预算 3.5 万元。", modality: .decided, conditions: [], sourceUnitIDs: ["u1"]),
        ])
        let report = MinutesEvidenceValidator.validate(candidate: subject, units: units)
        XCTAssertFalse(report.needsReview, "数字对得上就不该标复核：\(report.findings)")
    }

    /// MC-38：待办标成"已承诺"，但所引原文里没人认领。
    func testCommittedActionWithoutClaimNeedsReview() {
        let units = [unit("u1", "这个补充文档之后要写一下。")]
        let subject = candidate(actions: [
            .init(
                localID: "a1",
                task: "补充文档",
                ownerText: "李四",
                dueExpression: nil,
                commitment: .committed,
                sourceUnitIDs: ["u1"]
            ),
        ])
        let report = MinutesEvidenceValidator.validate(candidate: subject, units: units)
        XCTAssertTrue(report.needsReview)
        XCTAssertTrue(report.findings(for: "a1").contains { $0.reason.contains("认领") })
    }

    /// MC-38：负责人填了但原文没出现，是编的；留空则不误报。
    func testInventedOwnerIsFlaggedButEmptyOwnerIsNot() {
        let units = [unit("u1", "这个补充文档之后要写一下。")]
        let invented = candidate(actions: [
            .init(localID: "a1", task: "补充文档", ownerText: "李四", dueExpression: nil,
                  commitment: .proposed, sourceUnitIDs: ["u1"]),
        ])
        let inventedReport = MinutesEvidenceValidator.validate(candidate: invented, units: units)
        XCTAssertTrue(inventedReport.needsReview)
        XCTAssertTrue(inventedReport.findings(for: "a1").contains { $0.reason.contains("李四") })

        let honest = candidate(actions: [
            .init(localID: "a1", task: "补充文档", ownerText: nil, dueExpression: nil,
                  commitment: .proposed, sourceUnitIDs: ["u1"]),
        ])
        let honestReport = MinutesEvidenceValidator.validate(candidate: honest, units: units)
        XCTAssertFalse(honestReport.needsReview, "负责人留空是正确做法，不该标复核：\(honestReport.findings)")
    }

    /// MC-38：期限里的数字在原文找不到——多半是把相对日期折算成了具体日期。
    func testInventedDueDateIsFlagged() {
        let units = [unit("u1", "下周三之前给结果。")]
        let subject = candidate(actions: [
            .init(localID: "a1", task: "给结果", ownerText: nil, dueExpression: "10 月 8 日",
                  commitment: .proposed, sourceUnitIDs: ["u1"]),
        ])
        let report = MinutesEvidenceValidator.validate(candidate: subject, units: units)
        XCTAssertTrue(report.needsReview)
        XCTAssertTrue(report.findings(for: "a1").contains { $0.reason.contains("期限") })
    }

    /// 原文照写的相对期限不该被当成编造。
    func testVerbatimRelativeDueIsNotFlagged() {
        let units = [unit("u1", "下周三之前给结果。")]
        let subject = candidate(actions: [
            .init(localID: "a1", task: "给结果", ownerText: nil, dueExpression: "下周三",
                  commitment: .proposed, sourceUnitIDs: ["u1"]),
        ])
        let report = MinutesEvidenceValidator.validate(candidate: subject, units: units)
        XCTAssertFalse(report.needsReview, "照抄原文的相对期限不该标复核：\(report.findings)")
    }

    // MARK: - 渲染：保留但不升可信

    /// 被拒的条目仍然出现在正文里（让人看得见模型编了什么），
    /// 但带标记、整版进"需要你核对的地方"，不会被当成整理好的结论。
    func testRejectedItemStaysVisibleButMarked() throws {
        let units = [unit("u1", "今天讨论了发布节奏。")]
        let subject = candidate(
            decisions: [
                .init(localID: "d1", text: "决定下周发布。", modality: .decided, conditions: [],
                      sourceUnitIDs: ["u9"]),
            ],
            actions: [
                .init(localID: "a1", task: "补充文档", ownerText: nil, dueExpression: nil,
                      commitment: .proposed, sourceUnitIDs: ["u1"]),
            ]
        )
        let prepared: MinutesCandidateCodec.Prepared
        switch MinutesCandidateCodec.prepare(
            text: try String(data: JSONEncoder().encode(subject), encoding: .utf8) ?? "",
            units: units
        ) {
        case .prepared(let value): prepared = value
        case .failed(let kind, _): return XCTFail("结构合法应当解析成功，实际失败：\(kind)")
        }

        XCTAssertTrue(prepared.body.contains("决定下周发布"), "被拒的条目要保留在正文里")
        XCTAssertTrue(prepared.body.contains("未通过引用核对"))
        XCTAssertTrue(prepared.body.contains("补充文档"), "通过的条目照常显示")
        XCTAssertFalse(prepared.body.contains("补充文档（待核对）"), "通过的条目不该挂复核标记")
        XCTAssertTrue(prepared.report.needsReview)
    }

    /// 语气要显示出来：有条件的、只是提议的、已撤回的，读起来就该不一样。
    func testModalityIsVisibleInRenderedBody() {
        let subject = candidate(decisions: [
            .init(localID: "d1", text: "灰度后再看。", modality: .conditional,
                  conditions: ["灰度数据达标"], sourceUnitIDs: ["u1"]),
            .init(localID: "d2", text: "换个配色。", modality: .proposed,
                  conditions: [], sourceUnitIDs: ["u1"]),
            .init(localID: "d3", text: "先前的排期。", modality: .retracted,
                  conditions: [], sourceUnitIDs: ["u1"]),
        ])
        let body = MinutesCandidateCodec.markdown(
            for: subject,
            report: MinutesEvidenceValidator.Report(findings: [])
        )
        XCTAssertTrue(body.contains("（有条件）"))
        XCTAssertTrue(body.contains("（只是提议，未定）"))
        XCTAssertTrue(body.contains("（会上已撤回）"))
        XCTAssertTrue(body.contains("条件：灰度数据达标"))
    }

    // MARK: - 编解码

    /// v2 候选的字段名是契约的一部分：改了模型就对不上了。
    func testCandidateUsesContractFieldNames() throws {
        let subject = candidate(
            decisions: [],
            actions: [.init(localID: "a1", task: "补充结果", ownerText: "张三", dueExpression: "下周三",
                            commitment: .proposed, sourceUnitIDs: ["u1"])],
            overview: [.init(localID: "o1", text: "讨论了灰度。", sourceUnitIDs: ["u1"])],
            openQuestions: [.init(localID: "q1", text: "时间未定。", sourceUnitIDs: ["u1"])]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try XCTUnwrap(String(data: encoder.encode(subject), encoding: .utf8))
        XCTAssertTrue(json.contains("\"schema_version\""))
        XCTAssertTrue(json.contains("\"source_unit_ids\""))
        XCTAssertTrue(json.contains("\"owner_text\""))
        XCTAssertTrue(json.contains("\"due_expression\""))
        XCTAssertTrue(json.contains("\"open_questions\""))
        XCTAssertFalse(json.contains("ownerText"), "对外必须是契约里的 snake_case")

        let decoded = try JSONDecoder().decode(MinutesCandidateV2.self, from: XCTUnwrap(json.data(using: .utf8)))
        XCTAssertEqual(decoded, subject, "编解码要能原样往返")
        XCTAssertEqual(decoded.schemaVersion, MinutesCandidateV2.schemaVersion)

        // 没有依据的负责人/期限就是空：编码时省略、解码时仍是 nil，
        // 往返之后依然是"没说"，不会变成一个空字符串冒充结论。
        let withoutOwner = candidate(actions: [
            .init(localID: "a1", task: "补充结果", ownerText: nil, dueExpression: nil,
                  commitment: .proposed, sourceUnitIDs: ["u1"]),
        ])
        let roundTrip = try JSONDecoder().decode(
            MinutesCandidateV2.self,
            from: XCTUnwrap(JSONEncoder().encode(withoutOwner))
        )
        XCTAssertNil(roundTrip.actions.first?.ownerText)
        XCTAssertNil(roundTrip.actions.first?.dueExpression)
    }

    /// 数字抽取：只取数字本身，单位与相对日期交给原文核对。
    func testNumberExtractionKeepsDecimalsAndDropsWords() {
        XCTAssertEqual(MinutesEvidenceValidator.numbers(in: "预算是 3.5 万元"), ["3.5"])
        XCTAssertEqual(MinutesEvidenceValidator.numbers(in: "第 2 季度和 10 月"), ["2", "10"])
        XCTAssertTrue(MinutesEvidenceValidator.numbers(in: "下周三之前").isEmpty)
        XCTAssertTrue(MinutesEvidenceValidator.numbers(in: "没有数字").isEmpty)
    }
}
