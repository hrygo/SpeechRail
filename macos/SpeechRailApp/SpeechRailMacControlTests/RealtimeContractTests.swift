import XCTest
@testable import SpeechRailControlKit

final class RealtimeContractTests: XCTestCase {
    func testSequenceValidatorReportsGapAndRegression() {
        var validator = RealtimeSequenceValidator()

        XCTAssertEqual(
            validator.accept(RealtimeEventMetadata(eventID: "e1", sessionID: "s1", sequence: 1)),
            .first
        )
        XCTAssertEqual(
            validator.accept(RealtimeEventMetadata(eventID: "e2", sessionID: "s1", sequence: 3)),
            .gap(expected: 2, received: 3)
        )
        XCTAssertEqual(
            validator.accept(RealtimeEventMetadata(eventID: "e3", sessionID: "s1", sequence: 2)),
            .regression(last: 3, received: 2)
        )
    }

    func testSequenceValidatorReportsMissingAndSessionChange() {
        var validator = RealtimeSequenceValidator()

        XCTAssertEqual(
            validator.accept(RealtimeEventMetadata(sessionID: "s1", sequence: 1)),
            .first
        )
        XCTAssertEqual(
            validator.accept(RealtimeEventMetadata(sessionID: "s1")),
            .missing
        )
        XCTAssertEqual(
            validator.accept(RealtimeEventMetadata(sessionID: "s2", sequence: 1)),
            .sessionChanged(expected: "s1", received: "s2")
        )
    }

    func testCloseBarrierOnlyAllowsClearAfterEveryCommittedItemIsTerminal() {
        var barrier = RealtimeCloseBarrier()
        barrier.committed(itemID: "item-1")
        XCTAssertFalse(barrier.isReadyToClear)

        barrier.completed(itemID: "item-1")
        XCTAssertTrue(barrier.isReadyToClear)
    }

    func testCloseBarrierAcceptsFailedTerminalItemsAndDeduplicatesCommit() {
        var barrier = RealtimeCloseBarrier()
        barrier.committed(itemID: "item-1")
        barrier.committed(itemID: "item-1")
        barrier.committed(itemID: "item-2")
        barrier.failed(itemID: "item-1")

        XCTAssertEqual(barrier.pendingItemIDs, ["item-2"])
        XCTAssertFalse(barrier.isReadyToClear)

        barrier.failed(itemID: "item-2")
        XCTAssertTrue(barrier.isReadyToClear)
    }

    func testDrainPlanOrdersCommitCompletionClearAndClose() {
        XCTAssertEqual(
            RealtimeClosePlan.steps,
            [.commit, .waitForTerminalItems, .clear, .close]
        )
    }

    func testRealtimeMetadataUsesWireFieldNames() throws {
        let metadata = try JSONDecoder().decode(
            RealtimeEventMetadata.self,
            from: Data(#"{"event_id":"evt-1","session_id":"sess-1","sequence":7}"#.utf8)
        )

        XCTAssertEqual(metadata.eventID, "evt-1")
        XCTAssertEqual(metadata.sessionID, "sess-1")
        XCTAssertEqual(metadata.sequence, 7)
    }
}
