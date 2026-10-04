import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// VA-13 输入证据、自然接话与设备策略（A08 确定性部分；A56/A57/A58 记 R）。
@MainActor
final class AssistantTurnPolicyTests: XCTestCase {
    /// A08：empty/blank/重复 revision 不 cancel；final-only 前任收尾后接管。
    func testA08EvidenceEmptyDuplicateAndFinalOnly() {
        XCTAssertFalse(
            AssistantTurnPolicy.isBargeInEvidence(
                text: "", revision: 1, seenRevisions: [],
                allowsBargeIn: true, isSpeakingOrGenerating: true
            ),
            "空快照不触发 cancel"
        )
        XCTAssertFalse(
            AssistantTurnPolicy.isBargeInEvidence(
                text: "   ", revision: 1, seenRevisions: [],
                allowsBargeIn: true, isSpeakingOrGenerating: true
            ),
            "纯空白不触发 cancel"
        )
        XCTAssertFalse(
            AssistantTurnPolicy.isBargeInEvidence(
                text: "你好", revision: 2, seenRevisions: [2],
                allowsBargeIn: true, isSpeakingOrGenerating: true
            ),
            "重复 revision 不重复触发"
        )
        XCTAssertTrue(
            AssistantTurnPolicy.isBargeInEvidence(
                text: "你好", revision: 3, seenRevisions: [2],
                allowsBargeIn: true, isSpeakingOrGenerating: true
            ),
            "新 revision 非空证据应触发"
        )
        XCTAssertFalse(
            AssistantTurnPolicy.isBargeInEvidence(
                text: "你好", revision: 3, seenRevisions: [],
                allowsBargeIn: false, isSpeakingOrGenerating: true
            ),
            "半双工不允许插话"
        )
        // final-only 接管不经策略函数区分：前任收尾与新轮接管统一走 submitTurn，
        // 见 AssistantSession.beginReply；无分支可测的函数不进覆盖口径（已删除）。
        XCTAssertFalse(AssistantTurnPolicy.aggregationEnabled, "无基线时聚合维持关闭")
        XCTAssertEqual(AssistantTurnPolicy.aggregationState, "deferred_evidence")
    }
}
