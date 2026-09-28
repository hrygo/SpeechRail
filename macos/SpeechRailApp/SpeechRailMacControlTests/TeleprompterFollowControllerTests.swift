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

    @Test func manualPositionMovementPreservesLineOffsetAndClampsToSegmentLength() throws {
        let segments = try script()
        var controller = TeleprompterFollowController(currentIndex: 1, mode: .manual)

        controller.manualMove(
            to: TeleprompterAligner.Position(segmentIndex: 0, utf16Offset: 5),
            segmentCount: segments.count,
            segmentUTF16Lengths: segments.map { $0.text.utf16.count }
        )
        #expect(controller.position == TeleprompterAligner.Position(segmentIndex: 0, utf16Offset: 5))
        #expect(controller.mode == .manual)

        controller.manualMove(
            to: TeleprompterAligner.Position(segmentIndex: 0, utf16Offset: 10_000),
            segmentCount: segments.count,
            segmentUTF16Lengths: segments.map { $0.text.utf16.count }
        )
        #expect(controller.position.segmentIndex == 0)
        #expect(controller.position.utf16Offset == segments[0].text.utf16.count)

        controller.manualMove(
            to: TeleprompterAligner.Position(segmentIndex: -10, utf16Offset: -1),
            segmentCount: segments.count,
            segmentUTF16Lengths: segments.map { $0.text.utf16.count }
        )
        #expect(controller.position == TeleprompterAligner.Position(segmentIndex: 0, utf16Offset: 0))

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

    /// 长稿会产生远超 `items` 窗口的 item。这条固定的是**长跑之后行为仍然正确**：
    /// 末条证据仍能推进、重复 event id 仍被抑制。
    ///
    /// 它**不**证明 `retired`／`eventIDs` 的 128 上限本身——那两个上限是私有
    /// 列表长度，删掉它们不改变任何可观察行为（迟到事件另有两道守卫兜底），
    /// 因此在当前接口下无法证伪，见 §2 第 28 条。
    @Test func longRunsStayCorrectAcrossHundredsOfItems() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        let spokenLines = ["欢迎来到今天的直播", "今天我们介绍相机设置", "最后演示照片导出"]

        for index in 0..<300 {
            controller.receiveSnapshot(
                itemID: "item-\(index)",
                revision: 1,
                text: spokenLines[index % spokenLines.count],
                segments: segments,
                eventID: "event-\(index)"
            )
        }
        // 最后一个 item 仍然有效，300 轮之后跟随没有漂移。
        controller.receiveCompleted(
            itemID: "item-299",
            transcript: "最后演示照片导出",
            segments: segments
        )
        #expect(controller.position.segmentIndex == 2)
        #expect(controller.mode == .following)

        // 重复 event id 在长跑之后仍必须被抑制。
        let before = controller.position
        controller.receiveCompleted(
            itemID: "item-299",
            transcript: "欢迎来到今天的直播",
            segments: segments,
            eventID: "event-299"
        )
        #expect(
            controller.position == before,
            "长跑之后重复 event id 仍不得再次推进位置"
        )
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

    @Test func stableHypothesisPrefixLimitsPreviewToProvenText() throws {
        let segments = try TeleprompterSegmenter.segment(
            sourceText: "今天我们介绍相机设置。后文稳定性。"
        )
        var controller = TeleprompterFollowController()
        let adapter = TeleprompterRealtimeFollowAdapter()

        _ = adapter.apply(
            .partialSnapshot(
                itemID: "i",
                revision: 1,
                text: "今天我们介绍相机设置。后文稳定性。",
                evidence: .init(
                    stablePrefixCodepoints: 6,
                    sampleSpan: .init(startSample: 0, endSample: 24_000)
                )
            ),
            metadata: .init(eventID: "e1", sessionID: "s", sequence: 1),
            segments: segments,
            to: &controller
        )

        #expect(controller.currentIndex == 0)
        #expect(controller.position.utf16Offset == 6)
    }

    /// 重读回退必须由跟随控制器裁决，而不是由对齐器"能不能找到上一段"决定：
    /// 证据充分的整句重读要真的回退，只有几个 token 的远处短语必须留在原位。
    @Test func rereadRollsBackOnlyWhenTheBackwardMatchIsStrong() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()

        controller.receiveCompleted(
            itemID: "forward",
            transcript: "最后演示照片导出",
            segments: segments
        )
        #expect(controller.position.segmentIndex == 2)

        controller.receiveCompleted(
            itemID: "reread",
            transcript: "今天我们介绍相机设置",
            segments: segments
        )
        #expect(
            controller.position.segmentIndex == 1,
            "证据充分的整句重读必须真的回退到上一段"
        )

        controller.receiveCompleted(
            itemID: "forward-again",
            transcript: "最后演示照片导出",
            segments: segments
        )
        let afterForward = controller.position
        #expect(afterForward.segmentIndex == 2)

        controller.receiveCompleted(itemID: "stray", transcript: "直播", segments: segments)
        #expect(
            controller.position == afterForward,
            "只命中两个 token 的远处短语不足以证明重读，必须留在原位"
        )
        #expect(
            controller.committedPosition == afterForward,
            "被拒绝的回退不得改写已确认位置"
        )
    }

    /// 命中再准也不能跨段落倒退：远处的整句复述更可能是旁人声或口误，
    /// 自动跳回四段之前比留在原地更糟。
    @Test func rereadDoesNotRollBackAcrossDistantParagraphs() throws {
        let long = [
            "第一段介绍今天的直播主题和嘉宾安排。",
            "第二段讲述相机机身的基本操作方式。",
            "第三段说明镜头选择和对焦要点。",
            "第四段介绍曝光参数的常见组合。",
            "第五段演示照片导出的具体流程。",
        ].joined(separator: "\n\n")
        let segments = try TeleprompterSegmenter.segment(sourceText: long)
        var controller = TeleprompterFollowController()
        controller.manualMove(to: 4, segmentCount: segments.count)
        controller.resume()

        controller.receiveCompleted(
            itemID: "far",
            transcript: "第一段介绍今天的直播主题和嘉宾安排",
            segments: segments
        )
        #expect(
            controller.committedPosition.segmentIndex == 4,
            "远处整句复述不得把已确认位置拖回前面的段落"
        )
    }

    @Test func candidateCommittedAndViewportPositionsAreSeparated() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        let origin = controller.position

        controller.receiveSnapshot(
            itemID: "a",
            revision: 1,
            text: "今天我们介绍",
            segments: segments
        )
        let preview = controller.position

        #expect(controller.committedPosition == origin)
        #expect(controller.hypothesisPosition == preview)
        #expect(controller.viewportAnchor == preview)
        #expect(controller.position == preview)

        controller.receiveCompleted(
            itemID: "a",
            transcript: "我先回答观众的问题",
            segments: segments
        )

        #expect(controller.committedPosition == origin)
        #expect(controller.hypothesisPosition == nil)
        #expect(controller.viewportAnchor == preview)
        #expect(controller.position == preview)
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

    @Test func failedFinalKeepsViewportWhileCommittedPositionRemainsAuthoritative() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        let origin = controller.position
        controller.receivePartial(itemID: "a", delta: "今天我们介绍", segments: segments)
        controller.receivePartial(itemID: "a", delta: "相机设置", segments: segments)
        let preview = controller.position
        #expect(controller.currentIndex == 1)
        controller.receiveCompleted(itemID: "a", transcript: "我来回答观众的问题", segments: segments)
        #expect(controller.committedPosition == origin)
        #expect(controller.position == preview)
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

    @Test func distantUniquePhraseCannotAdvanceThroughPartialOrFinal() throws {
        let filler = String(repeating: "甲", count: 100)
        let segments = try TeleprompterSegmenter.segment(
            sourceText: "\(filler)。稳定性。\(String(repeating: "乙", count: 30))。"
        )
        var controller = TeleprompterFollowController()
        let origin = controller.position

        controller.receiveSnapshot(
            itemID: "partial",
            revision: 1,
            text: "稳定性",
            segments: segments
        )
        #expect(controller.position == origin)

        controller.receiveCompleted(
            itemID: "final",
            transcript: "稳定性",
            segments: segments
        )
        #expect(controller.position == origin)
    }

    @Test func explicitManualSelectionMakesTheSamePhraseALocalAnchor() throws {
        let filler = String(repeating: "甲", count: 100)
        let segments = try TeleprompterSegmenter.segment(
            sourceText: "\(filler)。稳定性。\(String(repeating: "乙", count: 30))。"
        )
        var controller = TeleprompterFollowController()
        let target = try #require(segments.firstIndex { $0.text.contains("稳定性") })

        controller.move(to: target, segmentCount: segments.count)
        controller.resetFollowWindow()
        controller.receiveCompleted(
            itemID: "selected",
            transcript: "稳定性",
            segments: segments
        )

        #expect(controller.currentIndex == target)
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
            .completed(itemID: "i", transcript: "欢迎来到今天的直播"),
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
            .completed(itemID: "new", transcript: "最后演示照片导出"),
            metadata: .init(eventID: "e2", sessionID: "s", sequence: 2),
            segments: segments,
            to: &controller
        )
        let newerPosition = controller.position

        _ = adapter.apply(
            .completed(itemID: "old", transcript: "欢迎来到今天的直播"),
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
