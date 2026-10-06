import Testing
import SpeechRailControlKit
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

struct AssistantInputTurnAssemblerTests {
    private let identity = AssistantInputTurnAssembler.Identity(connection: 3, generation: 8)

    @Test func budgetRolloverWaitsForTheBusinessBoundaryAndCombinesFinalsOnce() {
        var assembler = AssistantInputTurnAssembler()
        assembler.begin(identity: identity)

        let closedFirst = assembler.closeSegment(
            identity: identity,
            itemID: "item-1",
            sampleSpan: .init(startSample: 0, endSample: 24_000),
            reason: .budgetRollover,
            commitEventID: nil,
            eventID: "close-1"
        )
        #expect(closedFirst)
        let firstTerminalTurns = assembler.resolveTerminal(
            identity: identity,
            itemID: "item-1",
            terminal: .completed("Good"),
            eventID: "final-1"
        )
        #expect(firstTerminalTurns.isEmpty)

        let closedSecond = assembler.closeSegment(
            identity: identity,
            itemID: "item-2",
            sampleSpan: .init(startSample: 24_000, endSample: 48_000),
            reason: .vad,
            commitEventID: nil,
            eventID: "close-2"
        )
        #expect(closedSecond)
        let turns = assembler.resolveTerminal(
            identity: identity,
            itemID: "item-2",
            terminal: .completed("morning"),
            eventID: "final-2"
        )

        #expect(turns.count == 1)
        #expect(turns[0].identity == identity)
        #expect(turns[0].boundaryItemID == "item-2")
        #expect(turns[0].itemIDs == ["item-1", "item-2"])
        #expect(turns[0].transcript == "Good morning")
        #expect(turns[0].recoveryText == "Good morning")
        #expect(turns[0].isFormal)
        #expect(turns[0].sampleSpan == .init(startSample: 0, endSample: 48_000))
        #expect(turns[0].closeReason == .vad)
        #expect(assembler.pendingSegmentCount == 0)
    }

    @Test func businessBoundaryWaitsUntilEveryEarlierItemIsTerminal() {
        var assembler = AssistantInputTurnAssembler()
        assembler.begin(identity: identity)

        let closedFirst = assembler.closeSegment(
            identity: identity,
            itemID: "item-1",
            sampleSpan: .init(startSample: 0, endSample: 24_000),
            reason: .budgetRollover,
            commitEventID: nil,
            eventID: "close-1"
        )
        #expect(closedFirst)
        let closedBoundary = assembler.closeSegment(
            identity: identity,
            itemID: "item-2",
            sampleSpan: .init(startSample: 24_000, endSample: 48_000),
            reason: .clientCommit,
            commitEventID: "commit-1",
            eventID: "close-2"
        )
        #expect(closedBoundary)

        let outOfOrderTurns = assembler.resolveTerminal(
            identity: identity,
            itemID: "item-2",
            terminal: .completed("world"),
            eventID: "final-2"
        )
        #expect(outOfOrderTurns.isEmpty)
        let turns = assembler.resolveTerminal(
            identity: identity,
            itemID: "item-1",
            terminal: .completed("hello"),
            eventID: "final-1"
        )

        #expect(turns.count == 1)
        #expect(turns[0].transcript == "hello world")
        #expect(turns[0].closeReason == .clientCommit)
        #expect(turns[0].commitEventID == "commit-1")
    }

    @Test func failedOrEmptyFinalUsesPreviewOnlyAsRecoverablePartial() {
        var assembler = AssistantInputTurnAssembler()
        assembler.begin(identity: identity)

        let acceptedPreview = assembler.acceptDelta(
            identity: identity,
            itemID: "item-1",
            delta: "unfinished words",
            eventID: "partial-1"
        )
        #expect(acceptedPreview)
        let closedItem = assembler.closeSegment(
            identity: identity,
            itemID: "item-1",
            sampleSpan: .init(startSample: 100, endSample: 2_100),
            reason: .vad,
            commitEventID: nil,
            eventID: "close-1"
        )
        #expect(closedItem)

        let turns = assembler.resolveTerminal(
            identity: identity,
            itemID: "item-1",
            terminal: .failed,
            eventID: "failed-1"
        )

        #expect(turns.count == 1)
        #expect(turns[0].transcript.isEmpty)
        #expect(turns[0].recoveryText == "unfinished words")
        #expect(!turns[0].isFormal)
    }

    @Test func terminalWithoutSegmentBoundaryPreservesTextAsRecoverablePartial() throws {
        var assembler = AssistantInputTurnAssembler()
        assembler.begin(identity: identity)

        let acceptedPreview = assembler.acceptSnapshot(
            identity: identity,
            itemID: "item-1",
            revision: 1,
            text: "preview survives a missing close event",
            eventID: "preview-1"
        )
        #expect(acceptedPreview)

        let turns = assembler.resolveTerminal(
            identity: identity,
            itemID: "item-1",
            terminal: .failed,
            eventID: "failed-1"
        )

        let turn = try #require(turns.first)
        #expect(turns.count == 1)
        #expect(turn.transcript.isEmpty)
        #expect(turn.recoveryText == "preview survives a missing close event")
        #expect(!turn.isFormal)
        #expect(turn.sampleSpan == nil)
        #expect(turn.closeReason == nil)
    }

    @Test func emptyIntermediateFinalWithPreviewMakesWholeTurnRecoverable() {
        var assembler = AssistantInputTurnAssembler()
        assembler.begin(identity: identity)

        let acceptedPreview = assembler.acceptDelta(
            identity: identity,
            itemID: "item-1",
            delta: "unfinished words",
            eventID: "partial-1"
        )
        #expect(acceptedPreview)
        let closedFirst = assembler.closeSegment(
            identity: identity,
            itemID: "item-1",
            sampleSpan: .init(startSample: 0, endSample: 24_000),
            reason: .budgetRollover,
            commitEventID: nil,
            eventID: "close-1"
        )
        #expect(closedFirst)
        let emptyFirstTurns = assembler.resolveTerminal(
            identity: identity,
            itemID: "item-1",
            terminal: .completed(" \n"),
            eventID: "final-1"
        )
        #expect(emptyFirstTurns.isEmpty)

        let closedBoundary = assembler.closeSegment(
            identity: identity,
            itemID: "item-2",
            sampleSpan: .init(startSample: 24_000, endSample: 48_000),
            reason: .vad,
            commitEventID: nil,
            eventID: "close-2"
        )
        #expect(closedBoundary)
        let turns = assembler.resolveTerminal(
            identity: identity,
            itemID: "item-2",
            terminal: .completed("morning"),
            eventID: "final-2"
        )

        #expect(turns.count == 1)
        #expect(turns[0].transcript == "morning")
        #expect(turns[0].recoveryText == "unfinished words morning")
        #expect(!turns[0].isFormal)
    }

    @Test func pureEmptyFinalWithoutPreviewRemainsNonFormalAndTextless() {
        var assembler = AssistantInputTurnAssembler()
        assembler.begin(identity: identity)
        let closedItem = assembler.closeSegment(
            identity: identity,
            itemID: "item-empty",
            sampleSpan: .init(startSample: 0, endSample: 24_000),
            reason: .vad,
            commitEventID: nil,
            eventID: "close-empty"
        )
        #expect(closedItem)

        let turns = assembler.resolveTerminal(
            identity: identity,
            itemID: "item-empty",
            terminal: .completed(" \n"),
            eventID: "final-empty"
        )

        #expect(turns.count == 1)
        #expect(turns[0].transcript.isEmpty)
        #expect(turns[0].recoveryText.isEmpty)
        #expect(!turns[0].isFormal)
    }

    @Test func oldIdentityAndDuplicateEventsCannotCompleteAnotherTurn() {
        var assembler = AssistantInputTurnAssembler()
        assembler.begin(identity: identity)
        let oldIdentity = AssistantInputTurnAssembler.Identity(connection: 2, generation: 8)

        let closedOldIdentity = assembler.closeSegment(
            identity: oldIdentity,
            itemID: "item-1",
            sampleSpan: .init(startSample: 0, endSample: 1_000),
            reason: .vad,
            commitEventID: nil,
            eventID: "close-old"
        )
        #expect(!closedOldIdentity)
        let closedCurrentIdentity = assembler.closeSegment(
            identity: identity,
            itemID: "item-1",
            sampleSpan: .init(startSample: 0, endSample: 1_000),
            reason: .vad,
            commitEventID: nil,
            eventID: "close-1"
        )
        #expect(closedCurrentIdentity)
        let currentTerminalTurns = assembler.resolveTerminal(
            identity: identity,
            itemID: "item-1",
            terminal: .completed("hello"),
            eventID: "final-1"
        )
        #expect(currentTerminalTurns.count == 1)
        let duplicateTerminalTurns = assembler.resolveTerminal(
            identity: identity,
            itemID: "item-1",
            terminal: .completed("hello"),
            eventID: "final-1"
        )
        #expect(duplicateTerminalTurns.isEmpty)
    }
}
