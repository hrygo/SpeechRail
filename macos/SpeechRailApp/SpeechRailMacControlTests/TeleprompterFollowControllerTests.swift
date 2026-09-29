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

    /// 方案 §3.6 与 F-15：「稳定前缀越界或改写 → 契约异常可见，**暂停推进而非
    /// 伪造稳定性**」，以及「不静默夹取成『合法』」。
    ///
    /// 修复前把越界一律折成 `nil`，于是走 else 分支拿**整段仍在修订的文本**去
    /// 对齐——比「不推进」更宽松，方向正好相反，而且异常从外面完全看不出来。
    @Test func anOutOfRangeStablePrefixPausesInsteadOfAligningUnrevisedText() throws {
        let segments = try TeleprompterSegmenter.segment(
            sourceText: "今天我们介绍相机设置。后文稳定性。"
        )

        func run(_ stablePrefix: Int) throws -> TeleprompterFollowController {
            var controller = TeleprompterFollowController()
            let adapter = TeleprompterRealtimeFollowAdapter()
            _ = adapter.apply(
                .partialSnapshot(
                    itemID: "i",
                    revision: 1,
                    // 全文 14 个 scalar，稳定前缀只确认前 6 个——后 8 个仍在修订
                    text: "今天我们介绍相机设置。后文稳定性。",
                    evidence: .init(stablePrefixCodepoints: stablePrefix)
                ),
                metadata: .init(eventID: "e1", sessionID: "s", sequence: 1),
                segments: segments,
                to: &controller
            )
            return controller
        }

        // 前提：合法前缀下跟随只走到第 0 段的第 6 个字，不会因为越界而"没动"
        // 是被别的原因挡住的。
        let legal = try run(6)
        #expect(legal.stablePrefixContractAnomalies == 0)
        #expect(legal.position.utf16Offset == 6)

        for bogus in [999, -1] {
            let controller = try run(bogus)
            #expect(
                controller.stablePrefixContractAnomalies == 1,
                "稳定前缀 \(bogus) 越界必须被记成契约异常"
            )
            #expect(
                controller.position.utf16Offset == 0,
                "越界时必须暂停推进，而不是拿仍在修订的全文去对齐（\(bogus)）"
            )
            #expect(
                controller.followState == .catchingUp,
                "越界时必须离开跟读咬合，回到「正在跟上」：\(controller.followState)"
            )
            #expect(
                controller.uncertainty == 1,
                "越界时必须把不确定性顶满，不能让界面显示成跟上了"
            )
        }
    }

    /// 契约校验必须对着**进来的原文**做，不能对着 `suffix(2048)` 之后存下来的
    /// 文本做——否则一段 2100 字、整段都已稳定的合法假设，会因为「比存下来的文本
    /// 长」被判成越界：既不推进，又平白记一次契约异常。
    ///
    /// 这条同时说明为什么不能只把校验留在存文本上：两条路径在**匹配结果**上一致
    /// （前缀不小于存文本长度时，取前缀与取整段存文本是同一段字符串），差的是
    /// **越界判定**，而越界判定决定要不要推进。
    @Test func aLongHypothesisWhoseStablePrefixExceedsTheStoredBoundIsNotAnAnomaly() throws {
        // 重复同一句，让「超长」与「尾部可对齐」同时成立。填充异质文字不行：
        // 对齐器最多只看尾部 72 个 token，一片填充会让它合理地对不上——那测的是
        // 对齐器，不是这道守卫。
        let line = "今天我们介绍相机设置。"
        let text = String(repeating: line, count: 210)
        let prefix = text.unicodeScalars.count
        #expect(prefix > 2048, "前提: 稳定前缀确实长于存储上限")

        let segments = try TeleprompterSegmenter.segment(sourceText: text)
        var controller = TeleprompterFollowController()
        let adapter = TeleprompterRealtimeFollowAdapter()
        _ = adapter.apply(
            .partialSnapshot(
                itemID: "i",
                revision: 1,
                text: text,
                evidence: .init(stablePrefixCodepoints: prefix)
            ),
            metadata: .init(eventID: "e1", sessionID: "s", sequence: 1),
            segments: segments,
            to: &controller
        )

        #expect(
            controller.stablePrefixContractAnomalies == 0,
            "稳定前缀落在原文范围内就不是契约异常：\(controller.stablePrefixContractAnomalies)"
        )
        #expect(
            controller.lastMatchedCount > 0,
            "合法长假设必须照常对齐，不能被 2048 截断误判成越界而停下"
        )
    }

    /// 目标第 1 条的另一面：一段**远处**的短语不得把视口拽到后面的段落。
    /// 既有回归钉住了远处短语不得向后拖（`rereadRollsBackOnlyWhenTheBackwardMatchIsStrong`）
    /// 与整句复述不得倒退（`rereadDoesNotRollBackAcrossDistantParagraphs`），
    /// **向前这一向没有用例**。
    ///
    /// 写这条用例时踩了两个坑，都写在前置断言里：
    /// 一是脚本太短——`localAdvanceTokenRadius` 是**绝对** token 数（默认 24），
    /// 三段玩具脚本只有 46 个 token，半径几乎覆盖整篇，测出来的是口径不是性质；
    /// 二是两段用了同一句 filler，**重复跨度让匹配变歧义**，锚点根本没建立，
    /// 于是「视口没动」是因为压根没匹配上，不是因为远处短语被拦——这种通过毫无意义。
    /// 所以先断言锚点真的建立了，再断言远处短语没推动它。
    @Test func aDistantForwardPhraseCannotDragTheViewportAhead() throws {
        let opening = "第一段的开场白今天我们讲的是相机设置"
        let bridge = "中间这段是过渡内容用来把整篇脚本撑到足够长好让半径成为变量"
        let segments = try TeleprompterSegmenter.segment(
            sourceText: "\(opening)。\n\n\(bridge)。\n\n远端短语出现在第三段"
        )
        var controller = TeleprompterFollowController()

        controller.receiveCompleted(itemID: "anchor", transcript: opening, segments: segments)
        // 前置条件：锚点必须真的建立起来，否则后面两条断言会因为「压根没匹配」而恒真。
        #expect(controller.followState == .tracking, "开场白必须先跟上，否则这条用例测不到半径")
        #expect(controller.position.segmentIndex == 0 && controller.position.utf16Offset > 0)
        let anchored = controller.position

        // 这四个字完整、唯一、置信 1.0 地落在第 3 段，距锚点 30 个 token——
        // 刚好在默认局部半径 24 之外。识别准确不构成跳过两段的许可。
        controller.receiveCompleted(itemID: "distant", transcript: "远端短语", segments: segments)
        #expect(controller.lastMatchConfidence == 1.0, "这条用例要证明的是「匹配成功但不许跳」")
        #expect(controller.lastMatchedCount == 4)
        #expect(
            controller.position == anchored,
            "远处短语不得把视口拽到后面的段落"
        )
        #expect(
            controller.committedPosition == anchored,
            "被拒绝的越位推进不得改写已确认位置"
        )
    }

    /// 「至少两个 token 才允许试探性推进」这道门禁此前没有任何用例
    /// （`provisionalMinimumMatches` 在整个测试目录里零命中）。它挡的是最现实的
    /// 一种误听：识别器把一个杂音听成脚本里恰好存在、且在附近唯一的**单字**。
    /// 这种匹配置信度是满分、位置是唯一的，距离也落在局部半径内——只有 token 数
    /// 这道门禁拦得住它。
    @Test func aLoneStrayTokenMatchDoesNotMoveTheViewport() throws {
        let opening = "第一段的开场白今天我们讲的是相机设置"
        let bridge = "中间这段是过渡内容"
        let segments = try TeleprompterSegmenter.segment(
            sourceText: opening + "。\n\n" + bridge + "。\n\n鸥"
        )
        var controller = TeleprompterFollowController()

        controller.receiveCompleted(itemID: "anchor", transcript: opening, segments: segments)
        #expect(controller.followState == .tracking, "开场白必须先跟上")
        let anchored = controller.position

        controller.receiveCompleted(itemID: "stray", transcript: "鸥", segments: segments)
        // 前置条件：这个匹配在其它维度上都是「合格」的——满分置信、唯一位置、
        // 距离 10 个 token 落在默认局部半径 24 之内、且在近锚窗口之外。
        // 唯一不够的是它只有一个 token。
        #expect(controller.lastMatchConfidence == 1.0)
        #expect(controller.lastMatchedCount == 1)
        #expect(
            controller.position == anchored,
            "单个误听 token 不得把视口拽到后面的段落"
        )
        #expect(
            controller.committedPosition == anchored,
            "被拒绝的越位推进不得改写已确认位置"
        )
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

    /// `mayConfirm` 的向后确认是三项合取：置信 ≥ 0.95、命中 ≥ 6、距离在局部半径内。
    /// `rereadRollsBackOnlyWhenTheBackwardMatchIsStrong` 钉住的是**命中数**那一半
    /// （「直播」只命中两个 token），**置信度那一半此前没有任何用例**——
    /// 门槛从 0.95 降到 0.5 时全量 716 项无人变红。
    @Test func aBackwardMoveNeedsTheStrongConfidenceHalfToo() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        controller.receiveCompleted(
            itemID: "forward", transcript: "最后演示照片导出", segments: segments
        )
        #expect(controller.position.segmentIndex == 2)
        let anchored = controller.position

        // 「相机置」比「相机设置」少一个字：命中 9 个 token（≥ 6 成立），
        // 置信 0.889（< 0.95）。两项各成立一半，合取必须不成立。
        controller.receiveCompleted(
            itemID: "near-miss", transcript: "今天我们介绍相机置", segments: segments
        )
        #expect(controller.lastMatchedCount >= 6, "这条用例要证明的是命中数那一半已经满足")
        #expect(
            (controller.lastMatchConfidence ?? 0) < 0.95,
            "这条用例要证明的是置信度那一半不满足"
        )
        #expect(
            controller.position == anchored,
            "两项各成立一半仍然不得回退：证据不足的整句复述留在原地"
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
