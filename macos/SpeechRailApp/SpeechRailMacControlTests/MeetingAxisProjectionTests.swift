import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 六条状态轴的统一投影（方案 MA-21 / MC-74、MC-78）。
///
/// 这里钉的是**最容易被合成掉的两类误报**：
/// - 采集在跑、识别断了，不能显示成"正在录音，一切正常"；
/// - 内容存下了、索引没跟上，不能显示成"已保存"——用户搜不到就以为没存进去。
@MainActor
final class MeetingAxisProjectionTests: XCTestCase {
    private typealias Axis = MeetingAxisProjection.State

    private func projection(
        readiness: Axis = .ready,
        capture: Axis = .active,
        recognition: Axis = .active,
        persistence: Axis = .active,
        index: Axis = .ready,
        review: Axis = .idle
    ) -> MeetingAxisProjection {
        MeetingAxisProjection(
            readiness: readiness, capture: capture, recognition: recognition,
            persistence: persistence, index: index, review: review
        )
    }

    // MARK: - 六条轴各自独立

    func testSixAxesAreProjectedSeparately() {
        let axes = projection().axes
        XCTAssertEqual(axes.count, 6)
        XCTAssertEqual(axes.map(\.name), ["就绪", "采集", "识别", "保存", "索引", "审阅"])
        XCTAssertEqual(
            axes.map(\.name), projection().axes.map(\.name),
            "轴的顺序固定，界面上的行才不会每次刷新都换位置"
        )
    }

    func testUnknownAxisIsNotReportedAsNormal() {
        let view = projection(readiness: .unknown)
        XCTAssertFalse(
            view.factLines.contains("就绪：正常"),
            "未知不是正常，界面不该在状态不明时说「一切正常」"
        )
        XCTAssertTrue(view.needsAttention)
    }

    // MARK: - MC-74：采集在跑不等于识别在跑

    func testCaptureRunningWithRecognitionBrokenIsNotReportedAsFine() {
        let view = projection(recognition: .failed("上行断了"))
        XCTAssertTrue(view.factLines.contains { $0.contains("识别：失败") })
        XCTAssertTrue(view.factLines.contains("采集：进行中"), "两条轴各说各的")
        XCTAssertEqual(view.headline, "识别有问题")
        XCTAssertEqual(view.tone, .attention)
    }

    func testOneAxisProblemDoesNotMaskAnother() {
        let view = projection(readiness: .failed("服务没起来"), recognition: .failed("上行断了"))
        XCTAssertEqual(view.problems.map(\.name), ["就绪", "识别"], "两条都报，不是一条盖住另一条")
        XCTAssertEqual(view.headline, "就绪、识别有问题")
    }

    // MARK: - §6.5：保存与索引分开报

    func testSavedButNotIndexedIsNotReportedAsFullySaved() {
        let view = projection(persistence: .ready, index: .degraded("索引还没跟上"))
        XCTAssertTrue(view.factLines.contains("保存：正常"))
        XCTAssertTrue(view.factLines.contains { $0.contains("索引：降级") })
        XCTAssertEqual(view.headline, "索引有问题")
        XCTAssertEqual(view.tone, .attention)
    }

    func testIndexCaughtUpIsQuiet() {
        let view = projection(persistence: .ready, index: .ready)
        XCTAssertEqual(view.headline, "进行中")
        XCTAssertFalse(view.needsAttention)
    }

    // MARK: - 「没有在动」不是故障

    func testIdleAxisIsNotAProblem() {
        let view = projection(capture: .idle, recognition: .idle, persistence: .idle)
        XCTAssertTrue(view.problems.isEmpty, "没在动不等于坏了")
        XCTAssertEqual(view.tone, .neutral, "给「没有在动」上警告色会让用户到处找问题")
        XCTAssertFalse(view.factLines.contains { $0.contains("采集：失败") })
    }

    func testPausedIsQuietButVisible() {
        // 全部轴都不在动：这时不该有任何"进行中"的绿色。
        let view = projection(
            capture: .paused, recognition: .paused,
            persistence: .idle, index: .idle, review: .idle
        )
        XCTAssertTrue(view.problems.isEmpty)
        XCTAssertTrue(view.factLines.contains("采集：已暂停"), "暂停要说出来，但不算故障")
        XCTAssertEqual(view.tone, .neutral)
    }

    // MARK: - 能不能开始

    func testCannotStartWhileReadinessUnknown() {
        XCTAssertFalse(projection(readiness: .unknown).canStart)
    }

    func testCannotStartWhenReadinessFailed() {
        XCTAssertFalse(projection(readiness: .failed("模型没配")).canStart)
    }

    func testCanStartWhenReadinessAndCaptureAreReady() {
        let view = projection(readiness: .ready, capture: .idle, recognition: .idle)
        XCTAssertTrue(view.canStart)
    }

    func testRecognitionFailureDoesNotBlockStarting() {
        // 识别断了不等于不能开始采集：这一场的声音还要收。
        let view = projection(recognition: .failed("上行断了"))
        XCTAssertTrue(view.canStart, "开始与否看就绪与采集，不看识别")
    }

    // MARK: - 审阅轴

    func testPendingReviewIsReportedButNotAsAFailure() {
        let view = projection(review: .degraded("3 条待核对"))
        XCTAssertEqual(view.headline, "审阅有问题")
        XCTAssertTrue(view.factLines.contains { $0.contains("审阅：降级（3 条待核对）") })
        XCTAssertFalse(view.factLines.contains { $0.contains("审阅：失败") })
    }

    // MARK: - MC-78：不把"没报错"当验收

    func testNoProblemsDoesNotClaimAcceptance() {
        let view = projection()
        XCTAssertEqual(view.headline, "进行中")
        XCTAssertFalse(
            view.factLines.contains { $0.contains("验收") },
            "状态全绿不等于实机验收通过，这条话不能由状态投影说出口"
        )
    }

    // MARK: - 审阅轴（MA-21）

    func testReviewIsIdleWhenNothingHasBeenChecked() {
        // 一条结论都没有 = 还没开始核对，不是"核对通过"。
        XCTAssertEqual(MeetingAxisProjection.reviewState(verdicts: []), .idle)
    }

    func testReviewIsReadyOnlyWhenEverythingIsSupported() {
        XCTAssertEqual(
            MeetingAxisProjection.reviewState(
                verdicts: [.supported, .supported]
            ),
            .ready
        )
    }

    func testPendingReviewIsDegradedNotFailed() {
        // 待复核要人去看一眼，但它没有失败——两者的下一步动作不同。
        let state = MeetingAxisProjection.reviewState(
            verdicts: [.supported, .needsReview]
        )
        guard case .degraded(let reason) = state else {
            return XCTFail("待复核应当是降级，实际是 \(state)")
        }
        XCTAssertTrue(reason.contains("待复核"), reason)
    }

    func testRejectedConclusionFailsTheAxis() {
        // 引用不成立的条目留在正文里让人看得见，但整版不能显示成"整理好了"。
        let state = MeetingAxisProjection.reviewState(
            verdicts: [.supported, .rejected]
        )
        guard case .failed(let reason) = state else {
            return XCTFail("引用不成立应当报失败，实际是 \(state)")
        }
        XCTAssertTrue(reason.contains("1"), reason)
    }

    func testRejectedOutranksNeedsReview() {
        // 两者同时存在时报更严重的那个，不能被"待复核"稀释掉。
        let state = MeetingAxisProjection.reviewState(
            verdicts: [.needsReview, .rejected]
        )
        guard case .failed = state else {
            return XCTFail("存在被拒条目时必须报失败，实际是 \(state)")
        }
    }

    func testReviewProblemIsCountedAsAProblem() {
        let projection = MeetingAxisProjection(
            readiness: .ready, capture: .ready, recognition: .ready,
            persistence: .ready, index: .ready,
            review: MeetingAxisProjection.reviewState(verdicts: [.needsReview])
        )
        XCTAssertTrue(projection.needsAttention)
        XCTAssertEqual(projection.problems.map(\.name), ["审阅"])
    }

    func testReviewReadyDoesNotRaiseAttention() {
        let projection = MeetingAxisProjection(
            readiness: .ready, capture: .ready, recognition: .ready,
            persistence: .ready, index: .ready,
            review: MeetingAxisProjection.reviewState(verdicts: [.supported])
        )
        XCTAssertFalse(projection.needsAttention)
    }

}
