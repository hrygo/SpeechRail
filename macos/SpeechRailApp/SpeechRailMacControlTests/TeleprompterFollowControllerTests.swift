import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

struct TeleprompterFollowControllerTests {
    private func script() throws -> [TeleprompterSegment] {
        try TeleprompterSegmenter.segment(sourceText: "欢迎来到今天的直播。今天我们介绍相机设置。最后演示照片导出。")
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

    @Test func partialIsProvisionalAndFinalReplacesIt() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        controller.receivePartial(itemID: "a", delta: "今天我们介绍", segments: segments)
        #expect(controller.candidatePosition?.segmentIndex == 1)
        #expect(controller.currentIndex == 0)
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
        #expect(controller.currentIndex == 0)
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
        controller.receiveSnapshot(
            itemID: "a",
            revision: 1,
            text: "今天我们介绍相机设置",
            segments: segments,
            eventID: "s1-duplicate"
        )
        #expect(controller.currentIndex == 0)
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

    @Test func tinyCompletedFragmentsAccumulateWithoutMovingEarly() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        controller.receiveCompleted(itemID: "a", transcript: "欢迎", segments: segments)
        #expect(controller.position.utf16Offset == 0)
        controller.receiveCompleted(itemID: "b", transcript: "来到", segments: segments)
        #expect(controller.position.utf16Offset == 4)
    }

    @Test func repeatedWireEventDoesNotAppendTwice() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        controller.receivePartial(itemID: "a", delta: "今天我们介绍", segments: segments, eventID: "e1")
        controller.receivePartial(itemID: "a", delta: "今天我们介绍", segments: segments, eventID: "e1")
        #expect(controller.partialPreview == "今天我们介绍")
        #expect(controller.currentIndex == 0)
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
}
