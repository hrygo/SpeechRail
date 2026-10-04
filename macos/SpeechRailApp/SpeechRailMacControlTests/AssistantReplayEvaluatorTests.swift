import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// VA-17b 离线回放评估（A59/A60 的 event-only 入口）。
/// 只数身份、顺序与交付状态；离线事件不能证明 AEC、双讲或设备尾音。
final class AssistantReplayEvaluatorTests: XCTestCase {
    private func makeManifest() -> AssistantReplayEvaluator.Manifest {
        AssistantReplayEvaluator.Manifest(
            datasetRevision: "assistant-eval-set-1",
            baselineCommit: "71fc9231",
            policyRevision: "assistant-turn-v1",
            events: [
                .init(atMilliseconds: 0, kind: .turnAdded, turnID: "t1", ordinal: 1),
                .init(atMilliseconds: 1200, kind: .playbackStarted, turnID: "t1", ordinal: 1),
                .init(atMilliseconds: 1800, kind: .playbackInterrupted, turnID: "t1", ordinal: 1, isInterrupted: true),
                .init(atMilliseconds: 2400, kind: .turnAdded, turnID: "t2", ordinal: 2),
                .init(atMilliseconds: 3600, kind: .playbackCompleted, turnID: "t2", ordinal: 2),
                .init(atMilliseconds: 4200, kind: .sealed, turnID: "t2", ordinal: 2),
            ]
        )
    }

    func testAssistantReplayCountsTurnsAndDelivery() throws {
        let report = try AssistantReplayEvaluator.evaluate(makeManifest())
        XCTAssertEqual(report.metrics.eventCount, 6)
        XCTAssertEqual(report.metrics.turnCount, 2)
        XCTAssertEqual(report.metrics.interruptedTurnCount, 1)
        XCTAssertEqual(report.metrics.completedPlaybackCount, 1)
        XCTAssertEqual(report.metrics.sealedCount, 1)
        XCTAssertFalse(report.caveats.isEmpty, "离线报告必须声明不能证明的事项")
    }

    func testAssistantReplayRejectsMissingDatasetRevision() {
        var manifest = makeManifest()
        manifest = AssistantReplayEvaluator.Manifest(
            datasetRevision: "  ",
            baselineCommit: manifest.baselineCommit,
            policyRevision: manifest.policyRevision,
            events: manifest.events
        )
        XCTAssertThrowsError(try AssistantReplayEvaluator.evaluate(manifest))
    }

    func testAssistantReplayRejectsEmptyEvents() {
        let manifest = AssistantReplayEvaluator.Manifest(
            datasetRevision: "assistant-eval-set-1",
            baselineCommit: "71fc9231",
            policyRevision: "assistant-turn-v1",
            events: []
        )
        XCTAssertThrowsError(try AssistantReplayEvaluator.evaluate(manifest))
    }
}
