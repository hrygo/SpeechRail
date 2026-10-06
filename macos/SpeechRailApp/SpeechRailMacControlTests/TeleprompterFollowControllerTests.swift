import Testing
import SpeechRailControlKit
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

struct TeleprompterFollowControllerTests {
    /// E7c/§6.4：reducer 文案对齐——tracking 仅在有证据时称跟随中；
    /// listening/catchingUp 无证据时称正在定位；不暴露内部术语。
    @Test func followPresentationUsesClearUserFacingStates() {
        #expect(TeleprompterFollowPresentation.statusText(for: .waitingForSpeech) == "麦克风使用中，请开始朗读")
        #expect(TeleprompterFollowPresentation.statusText(for: .listening) == "正在定位，位置已保持")
        #expect(TeleprompterFollowPresentation.statusText(for: .tracking) == "语音跟随中")
        #expect(TeleprompterFollowPresentation.statusText(for: .catchingUp) == "正在定位，位置已保持")
        #expect(TeleprompterFollowPresentation.statusText(for: .freePlaying) == "自由发挥中")
        #expect(TeleprompterFollowPresentation.statusText(for: .paused) == "已暂停")
        #expect(TeleprompterFollowPresentation.statusText(for: .manual) == "手动提词")
        #expect(!TeleprompterFollowPresentation.statusText(for: .tracking).contains("咬合"), "内部术语不得作为用户文案")
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

    /// 时钟回退守卫有**两半**：队列年龄与匹配年龄。既有那条
    /// `latencyDiagnosticsReportsBoundedPercentiles` 四次调用喂的全是合法值，
    /// 所以「匹配年龄为负」这一侧从未被走过——去掉它全量 719 项无人变红。
    /// 负值不是噪声，是时钟回退的信号，放进去会让 P95 凭空变好。
    @Test func aRolledBackMatchClockIsNotRecordedAsALatencySample() {
        var diagnostics = TeleprompterLatencyDiagnostics()
        diagnostics.recordAlignment(queueAgeMilliseconds: 10, matchMilliseconds: 20)
        #expect(diagnostics.alignmentSampleCount == 1)

        diagnostics.recordAlignment(queueAgeMilliseconds: 10, matchMilliseconds: -5)
        #expect(
            diagnostics.alignmentSampleCount == 1,
            "匹配年龄为负说明时钟回退过，这一整次采样都得作废"
        )
        #expect(diagnostics.matchP95Milliseconds == 20)

        diagnostics.recordAlignment(queueAgeMilliseconds: 10, matchMilliseconds: .nan)
        #expect(diagnostics.alignmentSampleCount == 1)
    }

    /// `manualMove` 在按段索引 `segmentUTF16Lengths` 之前校验它够长。
    /// 字号或列宽变化时长度表可能短暂落后一版，越界就是崩溃而不是「保持位置」。
    /// 去掉这道校验全量 719 项无人变红。
    @Test func manualMoveWithAStaleLengthTableIsANoOpRatherThanACrash() {
        var controller = TeleprompterFollowController()
        controller.manualMove(
            to: TeleprompterAligner.Position(segmentIndex: 0, utf16Offset: 0),
            segmentCount: 3,
            segmentUTF16Lengths: [10, 10, 10]
        )
        let before = controller.position

        // 长度表只给到第 2 段，却要移动到第 3 段——越界会被夹住，不该崩。
        controller.manualMove(
            to: TeleprompterAligner.Position(segmentIndex: 2, utf16Offset: 4),
            segmentCount: 3,
            segmentUTF16Lengths: [10, 10]
        )
        #expect(
            controller.position == before,
            "长度表不齐全时必须原地不动，而不是越界崩溃"
        )
    }

    /// 切稿时 `prepare` 重建对齐脚本并清空 `history`；那一行比较写反之后，
    /// 换稿不重置、重复传同一份稿反而清空。`history` 是恢复与去重的记忆，
    /// 带着它跨稿就是让上一篇的证据替这一篇做判断。
    @Test func anEventFromThePreviousScriptCannotAdvanceAfterTheScriptChanges() throws {
        let oldScript = try TeleprompterSegmenter.segment(
            sourceText: "欢迎来到今天的直播。今天我们介绍相机设置。"
        )
        let newScript = try TeleprompterSegmenter.segment(
            sourceText: "这一篇讲导出流程与色彩管理。"
        )
        var controller = TeleprompterFollowController()
        controller.receiveCompleted(
            itemID: "old-1", transcript: "今天我们介绍相机设置", segments: oldScript
        )
        #expect(controller.position.segmentIndex == 1)
        let beforeSwitch = controller.position

        // 切稿：任何一条带新稿分段的事件都会触发 prepare(新稿)。
        controller.receiveCompleted(
            itemID: "new-1", transcript: "这一篇讲导出流程", segments: newScript
        )

        let afterSwitch = controller.position
        #expect(afterSwitch != beforeSwitch, "切稿本身必须真的把位置带走")

        // 上一篇的转写随后到达——对齐器面对的已经应该是新稿，它匹配不上。
        controller.receiveCompleted(
            itemID: "stale", transcript: "今天我们介绍相机设置", segments: newScript
        )
        #expect(
            controller.position == afterSwitch,
            "上一篇的转写不得在新稿上推进位置"
        )
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

    @Test func snapshotRevisionWithNoNewAudioWatermarkCannotCreateAnotherAdvance() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        controller.receiveSnapshot(
            itemID: "a",
            revision: 1,
            text: "今天我们介绍相机设置",
            segments: segments,
            eventID: "s1",
            sampleSpan: .init(startSample: 0, endSample: 24_000)
        )
        #expect(controller.currentIndex == 1)

        controller.receiveSnapshot(
            itemID: "a",
            revision: 2,
            text: "最后演示照片导出",
            segments: segments,
            eventID: "s2",
            sampleSpan: .init(startSample: 0, endSample: 24_000)
        )
        #expect(controller.currentIndex == 1)
        #expect(controller.partialPreview == "最后演示照片导出")

        controller.receiveSnapshot(
            itemID: "a",
            revision: 3,
            text: "最后演示照片导出",
            segments: segments,
            eventID: "s3",
            sampleSpan: .init(startSample: 24_000, endSample: 48_000)
        )
        #expect(controller.currentIndex == 2)
    }

    @Test func aNewInputGenerationCanRestartItsSampleWatermark() throws {
        let segments = try script()
        var controller = TeleprompterFollowController()
        controller.receiveSnapshot(
            itemID: "before-pause",
            revision: 1,
            text: "今天我们介绍相机设置",
            segments: segments,
            sampleSpan: .init(startSample: 0, endSample: 24_000)
        )
        #expect(controller.currentIndex == 1)

        controller.pause()
        controller.resume()
        controller.receiveSnapshot(
            itemID: "after-resume",
            revision: 1,
            text: "最后演示照片导出",
            segments: segments,
            sampleSpan: .init(startSample: 0, endSample: 24_000)
        )

        #expect(controller.currentIndex == 2)
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
                "越界时必须离开语音跟随中，回到正在定位：\(controller.followState)"
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
    @Test func retainedStablePrefixSubtractsDroppedScalars() throws {
        // E2 截断坐标回归：旧公式 min(stable, retainedCount) 漏减丢弃数。
        // 反例（方案 F03）：raw=3000 scalars，retain=2048，dropped=952，
        // stable=1500 → 正确 548，旧公式给出 1500。
        // 小稿构造：短文本无截断（dropped=0），正确与旧公式一致——
        // 这条只钉住“换算恒等式”，真正的截断区分由下一条大稿用例覆盖。
        // （大稿对齐窗口有限，短证据在 3000 字稿头无法定位，故分两条。）
        let scriptText = "欢迎来到今天的直播，今天我们介绍相机设置。接下来演示照片导出。"
        let segments = try TeleprompterSegmenter.segment(sourceText: scriptText)
        var controller = TeleprompterFollowController()
        let stable = scriptText.unicodeScalars.count
        controller.receiveSnapshot(
            itemID: "short",
            revision: 1,
            text: scriptText,
            segments: segments,
            eventID: "e-short",
            stablePrefixCodepoints: stable
        )

        #expect(controller.stablePrefixContractAnomalies == 0)
        #expect(controller.position.utf16Offset > 0, "全稳定短文本必须推进")
    }

    @Test func truncatedStablePrefixCoversOnlyRetainedHead() throws {
        // E2 截断区分回归：与上一条同一公式，raw=3000/retain=2048/dropped=952，
        // stable=1500 时正确行为只取保留区前 548。
        // 用可观测行为区分：正确换算的对齐输入是保留区前 548，
        // 旧逻辑的对齐输入是保留区前 1500——两者 token 流不同。
        // 为避开大稿对齐窗口限制，本条直接断言控制器实际消费的稳定文本
        // 等于保留区前缀 548（通过 partialPreview 长度表达），
        // 而不是断言对齐位置。
        let anchorA = "欢迎来到今天的直播，今天我们介绍相机设置。"
        let interlude = "接下来演示照片导出的具体流程，请大家跟随操作。"
        let decoyB = "欢迎来到今天的终审现场，请各位评委有序入场就座。"
        let head = anchorA + interlude + decoyB
        let retainedText = head + String(repeating: "乙", count: 2048 - head.unicodeScalars.count)
        #expect(retainedText.unicodeScalars.count == 2048, "保留区必须恰好 2048 scalars")
        let droppedCount = 3000 - 2048
        let rawStable = droppedCount + 548
        #expect(rawStable == 1500, "复现方案 F03 的数值")
        let droppedLine = "今天我们在这里回顾本季度的拍摄计划与分镜安排。"
        let headFillerCount = 3000 - 2048 - droppedLine.unicodeScalars.count
        let rawText = String(repeating: "甲", count: headFillerCount) + droppedLine + retainedText
        #expect(rawText.unicodeScalars.count == 3000, "原文必须恰好 3000 scalars")
        let segments = try TeleprompterSegmenter.segment(sourceText: rawText)
        var controller = TeleprompterFollowController()
        controller.receiveSnapshot(
            itemID: "truncated",
            revision: 1,
            text: rawText,
            segments: segments,
            eventID: "e-truncated",
            stablePrefixCodepoints: rawStable
        )

        #expect(controller.stablePrefixContractAnomalies == 0)
        // 正确行为：稳定对齐只消费保留区前 548 scalars；
        // 旧逻辑 min(1500, 2048) 消费 1500。多吃的 952 恰为丢弃数。
        #expect(controller.lastStableAlignedScalarCount == 548,
            "稳定对齐必须只取保留区前 548 scalars，实际 \(String(describing: controller.lastStableAlignedScalarCount))；旧逻辑给出 1500")
    }

    @Test func sameItemShortFinalConfirmsWithoutMovingViewport() throws {
        // E3/F04 同位确认：同 item snapshot“欢迎”试探推进后，
        // 同位置 final“欢迎”应提交 committed，且视口不重复移动。
        // 当前逻辑把“相等”归入向后重读门槛（0.95/6 matches），短句无法确认。
        let segments = try TeleprompterSegmenter.segment(
            sourceText: "欢迎来到今天的直播。今天我们介绍相机设置。"
        )
        var controller = TeleprompterFollowController()
        controller.receiveSnapshot(
            itemID: "greet",
            revision: 1,
            text: "欢迎",
            segments: segments,
            eventID: "e-snap"
        )
        let previewPosition = controller.position
        #expect(previewPosition.utf16Offset > 0, "snapshot 必须先试探推进，否则这条用例测不到同位确认")
        let committedBefore = controller.committedPosition

        controller.receiveCompleted(
            itemID: "greet",
            transcript: "欢迎",
            segments: segments,
            eventID: "e-final"
        )

        #expect(controller.committedPosition == previewPosition,
            "同 item 同位 final 必须提交 committed")
        #expect(controller.position == previewPosition,
            "同位确认不得重复移动视口")
        #expect(controller.followState == .tracking)
        _ = committedBefore
    }

    @Test func emptyFinalAfterPreviewIsUnconfirmed() throws {
        // E3/F05 空 final：有非空假设之后收到空 final，不得提交 committed，
        // 必须给出可观察的未确认状态，且保持视口位置。
        let segments = try TeleprompterSegmenter.segment(
            sourceText: "欢迎来到今天的直播。今天我们介绍相机设置。"
        )
        var controller = TeleprompterFollowController()
        controller.receiveSnapshot(
            itemID: "greet",
            revision: 1,
            text: "欢迎来到",
            segments: segments,
            eventID: "e-snap"
        )
        let previewPosition = controller.position
        let committedBefore = controller.committedPosition

        controller.receiveCompleted(
            itemID: "greet",
            transcript: "",
            segments: segments,
            eventID: "e-final"
        )

        #expect(controller.committedPosition == committedBefore, "空 final 不得提交 committed")
        #expect(controller.position == previewPosition, "空 final 必须保位")
        #expect(controller.followState != .tracking,
            "有假设后的空 final 不得继续呈现已跟上，实际 \(controller.followState)")
    }

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

    /// E8/TP-10：重复开场不得远跳，充分证据后能恢复。脚本按既有模式
    /// 拉开距离（半径是绝对 token 数，短脚本测的是口径不是性质）：段0开场白
    /// 建锚，段2是相同开场；纯重复句保位、带后续区分词前进到段1。
    @Test func repeatedOpeningStaysUntilDisambiguatingWordsArrive() throws {
        let opening = "第一段的开场白今天我们讲的是相机设置"
        let bridge = "中间这段是过渡内容用来把整篇脚本撑到足够长好让半径成为变量"
        let segments = try TeleprompterSegmenter.segment(
            sourceText: "\(opening)。\n\n\(bridge)。\n\n第一段的开场白现在开始提问"
        )
        var controller = TeleprompterFollowController()
        controller.receiveCompleted(itemID: "anchor", transcript: opening, segments: segments)
        #expect(controller.followState == .tracking, "开场白必须先跟上，否则门禁无从谈起")
        let anchored = controller.position

        // 纯重复开场（段2相同句子）：含糊，不得远跳。
        controller.receiveCompleted(
            itemID: "repeat", transcript: "第一段的开场白", segments: segments
        )
        #expect(controller.lastMatchedCount > 0, "重复开场必须有真实候选，否则门禁无从谈起")
        #expect(
            controller.position == anchored,
            "含糊重复开场不得远跳到后面的相同句子"
        )
        #expect(controller.committedPosition == anchored)
        // 后续区分词到达：充分证据后能推进到段1。
        controller.receiveCompleted(
            itemID: "disambiguate", transcript: bridge, segments: segments
        )
        #expect(controller.position.segmentIndex == 1)
    }

    /// E8/TP-10：近场单 token 不推进、远场单 token 需强证据。既有
    /// `aLoneStrayTokenMatchDoesNotMoveTheViewport` 已钉住远场单字杂音；
    /// 这里补近场对照：锚点旁的单字延续同样不得推进（有效候选但证据不足，
    /// 不能以“近”放行），远处孤 token 更不得拖走视口。
    @Test func singleTokenNearAndFarAreGatedDifferently() throws {
        let opening = "第一段的开场白今天我们讲的是相机设置"
        let bridge = "中间这段是过渡内容用来把整篇脚本撑到足够长好让半径成为变量"
        let segments = try TeleprompterSegmenter.segment(
            sourceText: "\(opening)。\n\n\(bridge)。\n\n远端短语出现在第三段"
        )
        var controller = TeleprompterFollowController()
        controller.receiveCompleted(itemID: "anchor", transcript: opening, segments: segments)
        #expect(controller.followState == .tracking, "开场白必须先跟上")
        let anchored = controller.position

        // 近场单字延续：落在半径内、置信满分，但只有一个 token——不得推进。
        controller.receiveCompleted(itemID: "near-one", transcript: "置", segments: segments)
        #expect(controller.lastMatchedCount == 1, "近场用例前提：单 token 候选")
        #expect(
            controller.position == anchored,
            "近场单 token 不得推进：不能以近放行证据不足的候选"
        )
        // 远场孤 token：同样不得拖走视口（与既有单字杂音回归同族不同字）。
        controller.receiveCompleted(itemID: "far-one", transcript: "端", segments: segments)
        #expect(
            controller.position == anchored,
            "远场单 token 不得拖走视口：不能以全部冻结证明安全"
        )
        #expect(controller.committedPosition == anchored)
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

    @Test func freePlayReanchorsOnADistantPhraseOnlyWithEnoughEvidence() throws {
        // The two existing free-play tests both re-anchor on a phrase unique in
        // the script, which short-circuits `mayAdvance` before the relocation
        // threshold is ever read. This one is about the band in between: far
        // past the local advance radius, matching more than the provisional
        // minimum, but short of what a relocation is supposed to require.
        let segments = try TeleprompterSegmenter.segment(
            sourceText: "\(String(repeating: "甲", count: 100))。稳定性良好。\(String(repeating: "乙", count: 100))。"
        )
        var controller = TeleprompterFollowController()
        controller.receiveCompleted(itemID: "a", transcript: "我先回答观众问题", segments: segments)
        controller.receiveCompleted(itemID: "b", transcript: "这个问题和稿件无关", segments: segments)
        #expect(controller.followState == .freePlaying)
        let parkedAt = controller.position

        // Three matching tokens, well outside the local radius. That clears the
        // provisional bar, so it counts as evidence -- but relocating the script
        // on three tokens is how a passing mention yanks the reader somewhere
        // they were not reading.
        controller.receiveCompleted(itemID: "c", transcript: "稳定性", segments: segments)
        #expect(controller.position == parkedAt)
        #expect(controller.followState == .freePlaying)

        // The same sentence with more of it actually spoken does relocate, so
        // the assertion above is about the evidence and not about the phrase
        // being unreachable.
        controller.receiveCompleted(itemID: "d", transcript: "稳定性良好", segments: segments)
        #expect(controller.position != parkedAt)
    }

    @Test func aPhraseWrittenTwiceIsNotAnUnambiguousAdvance() throws {
        // `reanchorMargin` is the only thing between "this sentence is in the
        // script twice" and "the reader gets teleported to whichever copy the
        // tie-break happened to pick". Both copies score identically, so the
        // margin is precisely the difference between advancing and holding.
        let segments = try TeleprompterSegmenter.segment(
            sourceText: "今天介绍三脚架。中间插一段别的内容。今天介绍三脚架。"
        )
        var controller = TeleprompterFollowController()
        let parkedAt = controller.position

        controller.receiveCompleted(itemID: "a", transcript: "今天介绍三脚架", segments: segments)

        #expect(controller.position == parkedAt)
        #expect(controller.followState != .tracking)

        // A phrase that occurs exactly once does move the reader, so the two
        // assertions above are about the tie and not about a controller that
        // has stopped following.
        controller.receiveCompleted(itemID: "b", transcript: "中间插一段别的内容", segments: segments)
        #expect(controller.followState == .tracking)
        #expect(controller.position != parkedAt)
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

    @Test func samePositionConfirmationIsObservedWithoutViewportMotion() throws {
        // E3：committed 同位确认不移动视口，但 adapter 必须表达实际确认，
        // 不能判成 ignored，否则调用方会误以为“没有定位成功”。
        let segments = try script()
        var controller = TeleprompterFollowController()
        let adapter = TeleprompterRealtimeFollowAdapter()
        _ = adapter.apply(
            .partialSnapshot(itemID: "greet", revision: 1, text: "欢迎"),
            metadata: .init(eventID: "e1", sessionID: "s", sequence: 1),
            segments: segments,
            to: &controller
        )
        let previewPosition = controller.position
        #expect(previewPosition.utf16Offset > 0, "snapshot 必须先试探推进")
        let committedBefore = controller.committedPosition

        let outcome = adapter.apply(
            .completed(itemID: "greet", transcript: "欢迎"),
            metadata: .init(eventID: "e2", sessionID: "s", sequence: 2),
            segments: segments,
            to: &controller
        )

        #expect(outcome == .confirmed)
        #expect(controller.committedPosition == previewPosition)
        #expect(controller.position == previewPosition)
        _ = committedBefore
    }

    @Test func emptyFinalAfterPreviewIsUnconfirmedRatherThanIgnored() throws {
        // E3：有假设后的空 final 保位、不提交，但 outcome 必须可观察为
        // .unconfirmed，不能与“无证据的空 final（ignored）”混同。
        let segments = try script()
        var controller = TeleprompterFollowController()
        let adapter = TeleprompterRealtimeFollowAdapter()
        _ = adapter.apply(
            .partialSnapshot(itemID: "greet", revision: 1, text: "欢迎来到"),
            metadata: .init(eventID: "e1", sessionID: "s", sequence: 1),
            segments: segments,
            to: &controller
        )
        let previewPosition = controller.position
        let committedBefore = controller.committedPosition

        let outcome = adapter.apply(
            .completed(itemID: "greet", transcript: ""),
            metadata: .init(eventID: "e2", sessionID: "s", sequence: 2),
            segments: segments,
            to: &controller
        )

        #expect(outcome == .unconfirmed)
        #expect(controller.committedPosition == committedBefore)
        #expect(controller.position == previewPosition)
        #expect(controller.followState == .catchingUp)
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
