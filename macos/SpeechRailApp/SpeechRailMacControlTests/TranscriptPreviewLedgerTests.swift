import Testing
import SpeechRailControlKit
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

struct TranscriptPreviewLedgerTests {
    private let identity = TranscriptPreviewLedger.Identity(connection: 2, generation: 11)

    @Test func interleavedItemsKeepTheirOwnPreviewRevisionAndBoundary() {
        var ledger = TranscriptPreviewLedger()
        ledger.beginGeneration(identity: identity, captureTimelineOffsetSeconds: 100)

        let acceptedARevision2 = ledger.acceptSnapshot(
            identity: identity,
            itemID: "item-a",
            revision: 2,
            text: "revised A",
            eventID: "a-r2"
        )
        #expect(acceptedARevision2)
        let acceptedBRevision1 = ledger.acceptSnapshot(
            identity: identity,
            itemID: "item-b",
            revision: 1,
            text: "preview B",
            eventID: "b-r1"
        )
        #expect(acceptedBRevision1)
        let acceptedStaleARevision = ledger.acceptSnapshot(
            identity: identity,
            itemID: "item-a",
            revision: 1,
            text: "stale A",
            eventID: "a-r1"
        )
        #expect(!acceptedStaleARevision)
        #expect(ledger.visiblePartial == "preview B")

        let closedA = ledger.closeSegment(
            identity: identity,
            itemID: "item-a",
            sampleSpan: .init(startSample: 2_400, endSample: 4_800),
            reason: .budgetRollover,
            commitEventID: nil,
            eventID: "a-close"
        )
        #expect(closedA)
        guard case .commit(let committed) = ledger.resolveCommit(
            identity: identity,
            itemID: "item-a",
            transcript: "final A"
        ) else {
            Issue.record("The final for item-a should commit.")
            return
        }

        #expect(committed.itemID == "item-a")
        #expect(committed.finalText == "final A")
        #expect(committed.recoveryNote == nil)
        #expect(committed.boundary?.inputRange.sampleSpan == .init(startSample: 2_400, endSample: 4_800))
        #expect(committed.boundary?.inputRange.startSeconds == 100.1)
        #expect(committed.boundary?.inputRange.endSeconds == 100.2)
        #expect(committed.boundary?.inputRange.isApproximate == true)
        #expect(ledger.visiblePartial == "preview B")
        let duplicateA = ledger.resolveCommit(
            identity: identity,
            itemID: "item-a",
            transcript: "final A"
        )
        #expect(duplicateA == .duplicate)
    }

    @Test func emptyFinalPreservesOnlyItsOwnPreviewAsRecoveryMaterial() {
        var ledger = TranscriptPreviewLedger()
        ledger.beginGeneration(identity: identity)
        let acceptedADelta = ledger.acceptDelta(
            identity: identity,
            itemID: "item-a",
            delta: "unfinished",
            eventID: "a-delta"
        )
        #expect(acceptedADelta)
        let acceptedBDelta = ledger.acceptDelta(
            identity: identity,
            itemID: "item-b",
            delta: "other item",
            eventID: "b-delta"
        )
        #expect(acceptedBDelta)

        guard case .commit(let committed) = ledger.resolveCommit(
            identity: identity,
            itemID: "item-a",
            transcript: "  \n"
        ) else {
            Issue.record("The preview for item-a should remain recoverable.")
            return
        }

        #expect(committed.finalText.isEmpty)
        #expect(committed.recoveryNote == .init(itemID: "item-a", text: "unfinished"))
        #expect(ledger.visiblePartial == "other item")
    }

    @Test func staleConnectionAndFailureCannotOverwriteOrClearCurrentItem() {
        var ledger = TranscriptPreviewLedger()
        ledger.beginGeneration(identity: identity)
        let acceptedCurrentDelta = ledger.acceptDelta(
            identity: identity,
            itemID: "item-current",
            delta: "current preview",
            eventID: "current-delta"
        )
        #expect(acceptedCurrentDelta)
        let oldIdentity = TranscriptPreviewLedger.Identity(connection: 1, generation: 10)

        let acceptedOldSnapshot = ledger.acceptSnapshot(
            identity: oldIdentity,
            itemID: "item-current",
            revision: 9,
            text: "late stale text",
            eventID: "old-r9"
        )
        #expect(!acceptedOldSnapshot)
        let resolvedOldFailure = ledger.resolveFailure(identity: oldIdentity, itemID: "item-current")
        #expect(!resolvedOldFailure)
        #expect(ledger.visiblePartial == "current preview")
        let resolvedOtherFailure = ledger.resolveFailure(identity: identity, itemID: "item-other")
        #expect(resolvedOtherFailure)
        #expect(ledger.visiblePartial == "current preview")
    }

    @Test func lateSnapshotCannotReopenAFinalizedItem() {
        var ledger = TranscriptPreviewLedger()
        ledger.beginGeneration(identity: identity)

        let acceptedPreview = ledger.acceptSnapshot(
            identity: identity,
            itemID: "item-final",
            revision: 1,
            text: "preview",
            eventID: "preview-1"
        )
        #expect(acceptedPreview)

        guard case .commit = ledger.resolveCommit(
            identity: identity,
            itemID: "item-final",
            transcript: "final"
        ) else {
            Issue.record("The final result should close the item.")
            return
        }

        let acceptedLateSnapshot = ledger.acceptSnapshot(
            identity: identity,
            itemID: "item-final",
            revision: 2,
            text: "late revision",
            eventID: "preview-2"
        )
        let acceptedLateDelta = ledger.acceptDelta(
            identity: identity,
            itemID: "item-final",
            delta: " late delta",
            eventID: "preview-3"
        )

        #expect(!acceptedLateSnapshot)
        #expect(!acceptedLateDelta)
        #expect(ledger.visiblePartial == nil)
    }
}
