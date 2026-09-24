import Testing
import SpeechRailControlKit
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

struct TeleprompterFollowControllerTests {
    @Test func followPresentationUsesClearUserFacingStates() {
        #expect(TeleprompterFollowPresentation.statusText(for: .waitingForSpeech) == "等待声音请开讲…")
        #expect(TeleprompterFollowPresentation.statusText(for: .listening) == "听见你了，正在跟上稿件…")
        #expect(TeleprompterFollowPresentation.statusText(for: .tracking) == "跟读咬合")
        #expect(TeleprompterFollowPresentation.statusText(for: .catchingUp) == "正在跟上稿件")
        #expect(TeleprompterFollowPresentation.statusText(for: .freePlaying) == "自由发挥中")
        #expect(TeleprompterFollowPresentation.statusText(for: .paused) == "已暂停")
        #expect(TeleprompterFollowPresentation.statusText(for: .manual) == "手动浏览中")
    }

    private func script() throws -> [TeleprompterSegment] {
        try TeleprompterSegmenter.segment(sourceText: "欢迎来到今天的直播。今天我们介绍相机设置。最后演示照片导出。")
    }

    @Test func manualMovementClampsAtBothEnds() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        controller.move(to: -10, segmentCount: segments.count)
        #expect(controller.currentIndex == 0)
        #expect(controller.mode == .manual)

        controller.move(to: 999, segmentCount: segments.count)
        #expect(controller.currentIndex == segments.count - 1)
        #expect(controller.mode == .manual)
    }

    @Test func sameSegmentManualMovePreservesReadingOffset() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        controller.receiveCompleted(itemID: "a", transcript: "欢迎来到", segments: segments)
        let positionBeforeMove = controller.position

        controller.manualMove(to: 0, segmentCount: segments.count)

        #expect(controller.position == positionBeforeMove)
        #expect(controller.mode == .manual)
    }

    @Test func differentSegmentManualMoveStartsAtParagraphBeginning() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        controller.receiveCompleted(itemID: "a", transcript: "欢迎来到", segments: segments)
        #expect(controller.position.utf16Offset > 0)

        controller.manualMove(to: 1, segmentCount: segments.count)

        #expect(controller.currentIndex == 1)
        #expect(controller.position.utf16Offset == 0)
        #expect(controller.mode == .manual)
    }

    @Test func eventsAfterManualTakeoverCannotMovePosition() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        controller.move(to: 1, segmentCount: segments.count)
        controller.receivePartial(itemID: "stale", delta: "欢迎来到今天的直播", segments: segments)
        controller.receiveCompleted(itemID: "stale", transcript: "欢迎来到今天的直播", segments: segments)
        #expect(controller.currentIndex == 1)
        #expect(controller.mode == .manual)
    }

    @Test func latencyDiagnosticsReportsBoundedPercentiles() {
        var diagnostics = TeleprompterLatencyDiagnostics(maxSamples: 3)
        diagnostics.recordAlignment(queueAgeMilliseconds: 1, matchMilliseconds: 4)
        diagnostics.recordAlignment(queueAgeMilliseconds: 2, matchMilliseconds: 5)
        diagnostics.recordAlignment(queueAgeMilliseconds: 3, matchMilliseconds: 6)
        diagnostics.recordAlignment(queueAgeMilliseconds: 40, matchMilliseconds: 60)
        diagnostics.recordCaptureToSend(milliseconds: 7)

        #expect(diagnostics.alignmentSampleCount == 3)
        #expect(diagnostics.queueAgeP95Milliseconds == 40)
        #expect(diagnostics.matchP95Milliseconds == 60)
        #expect(diagnostics.captureSampleCount == 1)
        #expect(diagnostics.captureToSendP95Milliseconds == 7)
    }

    @Test func splitFinalsAccumulatePosition() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        controller.receiveCompleted(itemID: "a", transcript: "欢迎来到", segments: segments)
        #expect(controller.position.utf16Offset == 4)
        controller.receiveCompleted(itemID: "b", transcript: "今天的直播", segments: segments)
        #expect(controller.position.utf16Offset == 9)
        controller.receiveCompleted(itemID: "c", transcript: "今天我们介绍相机设置最后演示照片导出", segments: segments)
        #expect(controller.currentIndex == 2)
    }

    @Test func partialMovesProvisionallyAndFinalReplacesIt() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        controller.receivePartial(itemID: "a", delta: "今天我们介绍", segments: segments)
        #expect(controller.candidatePosition?.segmentIndex == 1)
        #expect(controller.currentIndex == 1)
        controller.receivePartial(itemID: "a", delta: "相机设置", segments: segments)
        #expect(controller.currentIndex == 1)
        controller.receiveCompleted(itemID: "a", transcript: "欢迎来到今天的直播", segments: segments)
        #expect(controller.currentIndex == 0)
        controller.receiveCompleted(itemID: "a", transcript: "最后演示照片导出", segments: segments)
        #expect(controller.currentIndex == 0)
    }

    @Test func snapshotRevisionsReplaceTextAndFollowRevisions() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        controller.receiveSnapshot(
            itemID: "a",
            revision: 1,
            text: "今天我们介绍",
            segments: segments,
            eventID: "s1"
        )
        #expect(controller.partialPreview == "今天我们介绍")
        #expect(controller.currentIndex == 1)
        controller.receiveSnapshot(
            itemID: "a",
            revision: 2,
            text: "今天我们介绍相机设置",
            segments: segments,
            eventID: "s2"
        )
        #expect(controller.currentIndex == 1)
        #expect(controller.partialPreview == "今天我们介绍相机设置")
    }

    @Test func uniqueNearAnchorSnapshotCanAdvanceImmediately() throws {
        let segments = try TeleprompterSegmenter.segment(
            sourceText: "开场。今天我们介绍相机设置。下一段。"
        )
        var controller = TeleprompterFollowController()
        controller.receiveSnapshot(
            itemID: "a",
            revision: 1,
            text: "今天我们介绍相机设置",
            segments: segments,
            eventID: "s1"
        )
        #expect(controller.currentIndex == 1)
    }

    @Test func revisedSnapshotCannotMoveBackWithinTheCurrentSegment() throws {
        let segments = try TeleprompterSegmenter.segment(sourceText: "今天我们介绍相机设置。")
        var controller = TeleprompterFollowController()
        controller.receiveSnapshot(
            itemID: "a",
            revision: 1,
            text: "今天我们介绍相机设置",
            segments: segments,
            eventID: "s1"
        )
        let advanced = controller.position
        controller.receiveSnapshot(
            itemID: "a",
            revision: 2,
            text: "今天我们介绍相机",
            segments: segments,
            eventID: "s2"
        )
        #expect(controller.position == advanced)
    }

    @Test func duplicateSnapshotRevisionCannotAppendOrAdvance() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        controller.receiveSnapshot(
            itemID: "a",
            revision: 1,
            text: "今天我们介绍",
            segments: segments,
            eventID: "s1"
        )
        let firstPosition = controller.position
        controller.receiveSnapshot(
            itemID: "a",
            revision: 1,
            text: "今天我们介绍相机设置",
            segments: segments,
            eventID: "s1-duplicate"
        )
        #expect(controller.position == firstPosition)
        #expect(controller.partialPreview == "今天我们介绍")
    }

    @Test func detourHoldsAndFollowingSpeechRecovers() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        controller.receiveCompleted(itemID: "a", transcript: "欢迎来到今天的直播", segments: segments)
        let before = controller.position
        controller.receiveCompleted(itemID: "b", transcript: "请稍等我回复一下评论", segments: segments)
        #expect(controller.position == before)
        #expect(controller.uncertainty != nil)
        controller.receiveCompleted(itemID: "c", transcript: "今天我们介绍相机设置", segments: segments)
        #expect(controller.currentIndex == 1)
        #expect(controller.uncertainty == nil)
    }

    @Test func pausedAndRetiredItemsCannotOverrideManualPosition() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        controller.receivePartial(itemID: "old", delta: "今天我们", segments: segments)
        controller.pause()
        controller.receiveCompleted(itemID: "paused", transcript: "最后演示照片导出", segments: segments)
        #expect(controller.mode == .paused)
        controller.move(to: 1, segmentCount: segments.count)
        controller.resume()
        controller.receiveCompleted(itemID: "old", transcript: "最后演示照片导出", segments: segments)
        controller.receiveCompleted(itemID: "paused", transcript: "最后演示照片导出", segments: segments)
        #expect(controller.currentIndex == 1)
        #expect(controller.position.utf16Offset == 0)
        controller.receiveCompleted(itemID: "new", transcript: "今天我们介绍相机设置", segments: segments)
        #expect(controller.position.utf16Offset > 0)
    }

    @Test func finalRejectsWrongProvisionalProgress() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        let origin = controller.position
        controller.receivePartial(itemID: "a", delta: "今天我们介绍", segments: segments)
        controller.receivePartial(itemID: "a", delta: "相机设置", segments: segments)
        #expect(controller.currentIndex == 1)
        controller.receiveCompleted(itemID: "a", transcript: "我来回答观众的问题", segments: segments)
        #expect(controller.position == origin)
    }

    @Test func lateFinalFromOlderItemCannotUndoNewerFinal() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        controller.receivePartial(itemID: "a", delta: "欢迎来到", segments: segments)
        controller.receiveCompleted(itemID: "b", transcript: "最后演示照片导出", segments: segments)
        controller.receiveCompleted(itemID: "a", transcript: "欢迎来到今天的直播", segments: segments)
        #expect(controller.currentIndex == 2)
    }

    @Test func shortExactFinalsAdvanceAtUniqueNearbyPassage() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        controller.receiveCompleted(itemID: "a", transcript: "欢迎", segments: segments)
        #expect(controller.position.utf16Offset == 2)
        controller.receiveCompleted(itemID: "b", transcript: "来到", segments: segments)
        #expect(controller.position.utf16Offset == 4)
    }

    @Test func repeatedWireEventDoesNotAppendTwice() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        controller.receivePartial(itemID: "a", delta: "今天我们介绍", segments: segments, eventID: "e1")
        let firstPosition = controller.position
        controller.receivePartial(itemID: "a", delta: "今天我们介绍", segments: segments, eventID: "e1")
        #expect(controller.partialPreview == "今天我们介绍")
        #expect(controller.position == firstPosition)
    }

    @Test func continuousTurnTracksBeyondInitialSearchWindow() throws {
        let sentences = (10..<70).map { "现在检查第\($0)号设备的运行状态。" }
        let segments = try TeleprompterSegmenter.segment(sourceText: sentences.joined())
        var controller = TeleprompterFollowController()
        for (index, sentence) in sentences.enumerated() {
            controller.receivePartial(itemID: "long", delta: sentence, segments: segments, eventID: "e\(index)")
        }
        #expect(controller.currentIndex == segments.count - 1)
        controller.receiveCompleted(itemID: "long", transcript: sentences.joined(), segments: segments)
        #expect(controller.currentIndex == segments.count - 1)
    }

    @Test func partialCanPreviewForwardWithoutImmediateFinalRollback() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        controller.receiveSnapshot(
            itemID: "a",
            revision: 1,
            text: "今天我们介绍相机",
            segments: segments
        )
        let previewPosition = controller.position
        controller.receiveCompleted(itemID: "a", transcript: "今天我们介绍相机设置", segments: segments)

        #expect(controller.position.segmentIndex > previewPosition.segmentIndex
                || controller.position.utf16Offset >= previewPosition.utf16Offset)
        #expect(controller.followState == .tracking)
    }

    @Test func sustainedDetourEntersFreePlayAndLaterReanchors() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        controller.receiveCompleted(itemID: "a", transcript: "我先回答观众问题", segments: segments)
        #expect(controller.followState == .catchingUp)
        controller.receiveCompleted(itemID: "b", transcript: "这个问题和稿件无关", segments: segments)
        #expect(controller.followState == .freePlaying)

        controller.receiveCompleted(itemID: "c", transcript: "最后演示照片导出", segments: segments)
        #expect(controller.followState == .tracking)
        #expect(controller.currentIndex == 2)
    }

    @Test func isolatedFinalMismatchKeepsLastConfirmedPosition() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        controller.receiveCompleted(itemID: "a", transcript: "欢迎来到今天的直播", segments: segments)
        let confirmed = controller.position

        controller.receiveCompleted(itemID: "b", transcript: "我先回答观众问题", segments: segments)

        #expect(controller.position == confirmed)
        #expect(controller.followState == .catchingUp)
    }


struct TeleprompterRealtimeFollowAdapterTests {
    private func script() throws -> [TeleprompterSegment] {
        try TeleprompterSegmenter.segment(sourceText: "欢迎来到今天的直播。今天我们介绍相机设置。最后演示照片导出。")
    }

    @Test func snapshotCompletedSequenceDrivesFollowPosition() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        let adapter = TeleprompterRealtimeFollowAdapter()

        let preview = adapter.apply(
            .partialSnapshot(itemID: "i", revision: 1, text: "欢迎来到"),
            metadata: .init(eventID: "e1", sessionID: "s", sequence: 1),
            segments: segments,
            to: &controller
        )
        let outcome = adapter.apply(
            .completed(itemID: "i", transcript: "欢迎来到今天的直播", units: []),
            metadata: .init(eventID: "e2", sessionID: "s", sequence: 2),
            segments: segments,
            to: &controller
        )

        #expect(preview == .previewed)
        #expect(outcome == .aligned)
        #expect(controller.currentIndex == 0)
        #expect(controller.followState == .tracking)
    }

    @Test func snapshotRevisionReplacesTextAndDuplicateEventIsIgnored() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        let adapter = TeleprompterRealtimeFollowAdapter()
        _ = adapter.apply(
            .partialSnapshot(itemID: "i", revision: 1, text: "欢迎来到"),
            metadata: .init(eventID: "e1", sessionID: "s", sequence: 1),
            segments: segments,
            to: &controller
        )
        _ = adapter.apply(
            .partialSnapshot(itemID: "i", revision: 2, text: "最后演示照片导出"),
            metadata: .init(eventID: "e2", sessionID: "s", sequence: 2),
            segments: segments,
            to: &controller
        )
        #expect(controller.partialPreview == "最后演示照片导出")
        let position = controller.position

        let duplicate = adapter.apply(
            .partialSnapshot(itemID: "i", revision: 3, text: "今天我们介绍相机设置"),
            metadata: .init(eventID: "e2", sessionID: "s", sequence: 3),
            segments: segments,
            to: &controller
        )

        #expect(duplicate == .ignored)
        #expect(controller.partialPreview == "最后演示照片导出")
        #expect(controller.position == position)
    }

    @Test func lateOldFinalCannotUndoNewerItem() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        let adapter = TeleprompterRealtimeFollowAdapter()
        _ = adapter.apply(
            .partialSnapshot(itemID: "old", revision: 1, text: "欢迎来到"),
            metadata: .init(eventID: "e1", sessionID: "s", sequence: 1),
            segments: segments,
            to: &controller
        )
        _ = adapter.apply(
            .completed(itemID: "new", transcript: "最后演示照片导出", units: []),
            metadata: .init(eventID: "e2", sessionID: "s", sequence: 2),
            segments: segments,
            to: &controller
        )
        let newerPosition = controller.position

        _ = adapter.apply(
            .completed(itemID: "old", transcript: "欢迎来到今天的直播", units: []),
            metadata: .init(eventID: "e3", sessionID: "s", sequence: 3),
            segments: segments,
            to: &controller
        )

        #expect(controller.position == newerPosition)
        #expect(controller.currentIndex == 2)
    }

    @Test func failedAndClosedEventsAreTerminalOutcomes() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        let adapter = TeleprompterRealtimeFollowAdapter()
        let failed = adapter.apply(
            .failed(itemID: "i", code: "backend_busy", message: "unavailable"),
            metadata: .init(eventID: "e1", sessionID: "s", sequence: 1),
            segments: segments,
            to: &controller
        )
        let closed = adapter.apply(
            .closed(code: nil),
            metadata: .init(eventID: "e2", sessionID: "s", sequence: 2),
            segments: segments,
            to: &controller
        )

        #expect(failed == .terminalFailure)
        #expect(closed == .terminalFailure)
        #expect(controller.mode == .following)
    }
}

}
