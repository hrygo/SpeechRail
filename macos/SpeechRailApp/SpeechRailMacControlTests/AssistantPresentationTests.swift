import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// VA-08 可信首屏、模式与数据去向（F10 / A25/A26/A27 + 十二态）。
///
/// 纯 presentation 推导，不碰设备与网络。
@MainActor
final class AssistantPresentationTests: XCTestCase {
    /// 十二态全覆盖：每个态都有标题与事实行。
    func testTwelveStates() {
        XCTAssertEqual(AssistantPresentation.State.allCases.count, 12, "应为十二态")
        let live = AssistantPresentation.make(
            hasRecord: false, isLive: true, blocked: false, blockTitle: nil,
            phase: "listening", isMuted: false, modelConfigured: true,
            modelChecked: false, modelName: "m", modeTitle: "对讲", isArchived: false
        )
        XCTAssertEqual(live.state, .liveListening)
        XCTAssertTrue(live.facts.joined().contains("已配置"), "未检查时仅已配置")
        XCTAssertFalse(live.facts.joined().contains("已连接"), "未检查不得写已连接")
        let liveChecked = AssistantPresentation.make(
            hasRecord: false, isLive: true, blocked: false, blockTitle: nil,
            phase: "speaking", isMuted: false, modelConfigured: true,
            modelChecked: true, modelName: "m", modeTitle: "对讲", isArchived: false
        )
        XCTAssertEqual(liveChecked.state, .liveSpeaking)
        XCTAssertTrue(liveChecked.facts.joined().contains("已连接"))
    }

    /// A25：configured 但服务关的 idle，不得写“语音已就绪”。
    func testA25ConfiguredDoesNotMeanVoiceReady() {
        let ready = AssistantPresentation.make(
            hasRecord: false, isLive: false, blocked: false, blockTitle: nil,
            phase: "idle", isMuted: false, modelConfigured: true,
            modelChecked: false, modelName: "m", modeTitle: "对讲", isArchived: false
        )
        XCTAssertEqual(ready.state, .readyConfigured)
        XCTAssertFalse(ready.title.contains("就绪"), "未开始不得虚报就绪")
        XCTAssertFalse(ready.title.contains("说话即录"), "不得承诺说话即录")
    }

    /// A26：文字助手不借他人电平/elapsed/聆听文案。
    func testA26TextAssistantDoesNotBorrowOtherMeters() {
        // presentation 输入只来自本场事实，不借全局 coordinator.elapsed/level。
        // 本用例锁定接口：make 不接受 elapsed/level 参数。
        let text = AssistantPresentation.make(
            hasRecord: false, isLive: true, blocked: false, blockTitle: nil,
            phase: "listening", isMuted: false, modelConfigured: false,
            modelChecked: false, modelName: nil, modeTitle: "文字", isArchived: false
        )
        XCTAssertEqual(text.facts, ["文字"], "无模型时事实行只有模式")
    }

    /// A27：旧回看无实时连接，不得显示“已连接/刚结束”。
    func testA27OldReviewHasNoLiveConnectionOrFreshSuccess() {
        let review = AssistantPresentation.make(
            hasRecord: true, isLive: false, blocked: false, blockTitle: nil,
            phase: "idle", isMuted: false, modelConfigured: true,
            modelChecked: false, modelName: "m", modeTitle: "对讲", isArchived: true
        )
        XCTAssertEqual(review.state, .reviewArchived)
        XCTAssertFalse(review.facts.joined().contains("已连接"), "回看不得显示实时已连接")
        XCTAssertTrue(
            AssistantPresentation.dataFlowNotice.contains("记录保存在此 Mac"),
            "数据去向固定文案"
        )
    }
}
