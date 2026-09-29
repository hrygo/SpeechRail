import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

struct TeleprompterReplayEvaluatorTests {
    private func manifest(
        events: [TeleprompterReplayManifest.Event],
        labels: [TeleprompterReplayManifest.Label],
        datasetRevision: String = "dataset-1",
        baselineCommit: String = "baseline-sha",
        candidateCommit: String = "candidate-sha",
        policyRevision: String = "policy-1"
    ) -> TeleprompterReplayManifest {
        TeleprompterReplayManifest(
            datasetRevision: datasetRevision,
            baselineCommit: baselineCommit,
            candidateCommit: candidateCommit,
            policyRevision: policyRevision,
            languageLane: "zh",
            deviceClass: "test-device",
            segments: [
                .init(id: "s0", text: "欢迎来到今天的直播。"),
                .init(id: "s1", text: "今天我们介绍相机设置。"),
                .init(id: "s2", text: "最后演示照片导出。")
            ],
            events: events,
            labels: labels
        )
    }

    private func completed(
        _ text: String,
        at milliseconds: Int,
        item: String = "item-1"
    ) -> TeleprompterReplayManifest.Event {
        .init(
            atMilliseconds: milliseconds,
            kind: .completed,
            itemID: item,
            eventID: "evt-\(milliseconds)",
            text: text
        )
    }

    @Test func healthyReadingProducesLatencyWithoutHarmfulJumps() throws {
        let report = try TeleprompterReplayEvaluator.evaluate(
            manifest(
                events: [
                    completed("欢迎来到今天的直播。", at: 800),
                    completed("欢迎来到今天的直播。今天我们介绍相机设置。", at: 2_600, item: "item-2")
                ],
                labels: [
                    .init(eventIndex: 0, intent: .read, expectedSegmentIndex: 0),
                    .init(eventIndex: 1, intent: .read, expectedSegmentIndex: 1)
                ]
            )
        )

        #expect(report.metrics.harmfulJumpCount == 0)
        #expect(report.metrics.unintentionalBackjumpCount == 0)
        #expect(report.metrics.sampleCount == 2)
        #expect(report.status == "deterministic_replay")
        #expect(report.durationMilliseconds == 2_600)
    }

    @Test func improviseLabelCountsAnAdvanceAsAHarmfulJump() throws {
        let report = try TeleprompterReplayEvaluator.evaluate(
            manifest(
                events: [
                    completed("欢迎来到今天的直播。今天我们介绍相机设置。", at: 900),
                    completed("今天我们介绍相机设置。最后演示照片导出。", at: 2_000, item: "item-2")
                ],
                labels: [
                    .init(eventIndex: 0, intent: .read, expectedSegmentIndex: 1),
                    .init(eventIndex: 1, intent: .improvise)
                ]
            )
        )

        #expect(report.metrics.harmfulJumpCount == 1, "脱稿时的推进必须计入严重误推进")
    }

    @Test func manualTakeoverAfterAHarmfulJumpCountsOneCorrection() throws {
        let report = try TeleprompterReplayEvaluator.evaluate(
            manifest(
                events: [
                    completed("欢迎来到今天的直播。今天我们介绍相机设置。", at: 900),
                    completed("今天我们介绍相机设置。最后演示照片导出。", at: 1_800, item: "item-2"),
                    completed("欢迎来到今天的直播。", at: 4_000, item: "item-3")
                ],
                labels: [
                    .init(eventIndex: 0, intent: .read, expectedSegmentIndex: 1),
                    .init(eventIndex: 1, intent: .improvise),
                    .init(eventIndex: 2, intent: .manualJump, expectedSegmentIndex: 0)
                ]
            )
        )

        #expect(report.metrics.harmfulJumpCount >= 1)
        #expect(report.metrics.manualCorrectionCount == 1, "只有系统出错后的接管才算纠正")
    }

    @Test func unlabelledEventsAreCountedInsteadOfHidden() throws {
        let report = try TeleprompterReplayEvaluator.evaluate(
            manifest(
                events: [completed("欢迎来到今天的直播。", at: 500)],
                labels: []
            )
        )

        #expect(report.metrics.unlabelledEventCount == 1)
    }

    @Test func replayRefusesMaterialWithoutDatasetOrVersionRecords() {
        let missingDataset = manifest(
            events: [],
            labels: [],
            datasetRevision: ""
        )
        #expect(throws: TeleprompterReplayError.missingDatasetRevision) {
            try TeleprompterReplayEvaluator.evaluate(missingDataset)
        }

        let missingVersion = manifest(
            events: [],
            labels: [],
            baselineCommit: ""
        )
        #expect(throws: TeleprompterReplayError.missingVersionRecord) {
            try TeleprompterReplayEvaluator.evaluate(missingVersion)
        }
    }

    @Test func replayRejectsLabelsThatPointOutsideTheRecording() {
        let value = manifest(
            events: [completed("欢迎来到今天的直播。", at: 500)],
            labels: [.init(eventIndex: 7, intent: .read)]
        )
        #expect(throws: TeleprompterReplayError.labelOutOfRange(7)) {
            try TeleprompterReplayEvaluator.evaluate(value)
        }
    }

    /// The manifest is authored outside the repository, so its intent strings
    /// are a real wire contract, not an implementation detail.
    private static let manifestJSON = """
        {
          "schema_version": "teleprompter.replay.v1",
          "dataset_revision": "dataset-1",
          "baseline_commit": "baseline-sha",
          "candidate_commit": "candidate-sha",
          "policy_revision": "policy-1",
          "language_lane": "zh",
          "device_class": "test-device",
          "segments": [{"id": "s0", "text": "欢迎来到今天的直播。"}],
          "events": [
            {"at_milliseconds": 500, "kind": "completed", "item_id": "item-1",
             "event_id": "e0", "revision": 1, "text": "欢迎来到今天的直播。"}
          ],
          "labels": [
            {"event_index": 0, "intent": "read", "expected_segment_index": 0},
            {"event_index": 0, "intent": "reRead", "expected_segment_index": 0},
            {"event_index": 0, "intent": "manualJump", "expected_segment_index": null}
          ]
        }
        """

    /// 方案 §11.6：「回稿恢复延迟 = 第一个可辨识回稿片段结束，到**恢复可靠跟随**」，
    /// 「超时算失败，不删除样本」。
    ///
    /// 标注为 `read` 但**没有阅读位置**的事件，对「跟随有没有跟上」这件事
    /// 不提供任何证据——它既没说跟上，也没说没跟上。评估器此前却把它当作
    /// 恢复：`.read` 分支的 `else` 直接调 `endReanchorWindow()`。
    ///
    /// 后果是可复现的：读者在 0.5 秒脱稿，之后两个**完全对不上稿**的事件一路
    /// 走到 6 秒（远超 3 秒超时门槛），报告说 **0 次超时、0 个失败样本**——
    /// 一次也没恢复的跟随，被两个「读不懂」的事件抹平了。真实素材上这一路径
    /// 占比不小：22 次窗口释放里只有 4 次是跟随真的到达，18 次是「对不上稿」。
    @Test func anUnmatchedEventIsNotEvidenceThatTheFollowerRecovered() throws {
        let report = try TeleprompterReplayEvaluator.evaluate(
            manifest(
                events: [
                    completed("完全对不上稿的即兴内容", at: 500),
                    completed("完全不相关的旁白内容", at: 2_000, item: "item-2"),
                    completed("另一段也匹配不上的话", at: 6_000, item: "item-3")
                ],
                labels: [
                    .init(eventIndex: 0, intent: .improvise),
                    .init(eventIndex: 1, intent: .read),
                    .init(eventIndex: 2, intent: .read)
                ]
            )
        )

        #expect(report.metrics.reanchorLatencySampleCount == 0, "前提: 从来没量到恢复延迟")
        #expect(
            report.metrics.reanchorTimeoutCount == 1,
            "脱稿后 5.5 秒仍未恢复，必须按 §11.6 记一次超时而不是删掉样本"
        )
        #expect(
            report.metrics.failedSampleCount > 0,
            "超时窗口内的事件按失败样本计入，未删除"
        )
    }

    /// 同一个洞的另一半：**没有阅读位置的事件本来就不该悄悄消失**。
    /// §11.6 结尾要求「超时和**未匹配**数量单列」，而修复前报告里没有任何字段
    /// 说明有多少事件没能落到位置上。真实素材上 82 个事件里有 18 个（22%）。
    @Test func eventsWithoutAReadingPositionAreCountedSeparately() throws {
        let report = try TeleprompterReplayEvaluator.evaluate(
            manifest(
                events: [
                    completed("欢迎来到今天的直播。今天我们介绍相机设置。", at: 900),
                    completed("完全不相关的旁白内容", at: 1_800, item: "item-2"),
                    completed("另一段也匹配不上的话", at: 2_700, item: "item-3")
                ],
                labels: [
                    .init(eventIndex: 0, intent: .read, expectedSegmentIndex: 1),
                    .init(eventIndex: 1, intent: .read),
                    .init(eventIndex: 2, intent: .read)
                ]
            )
        )

        #expect(report.metrics.unmatchedEventCount == 2, "两个事件没有阅读位置")
        #expect(
            report.metrics.sampleCount == 3,
            "样本数仍是事件数——它与未匹配数是两个口径，不能互相顶替"
        )
        #expect(
            report.caveats.contains { $0.contains("未匹配") && $0.contains("2") },
            "未匹配数量必须单列：\(report.caveats)"
        )
        // 这条 caveat 的**全部价值就是这句话**。把它反过来写成「这些事件已按失败
        // 样本计入」，报告会主动误导读报告的人，而只检查「caveat 存在且带数字」
        // 的断言照样通过——所以这里逐半句钉住。
        #expect(
            report.caveats.contains { $0.contains("既不产生延迟样本") && $0.contains("也不计为失败") },
            "必须说清未匹配事件在两个方向上都退出了统计：\(report.caveats)"
        )
        let metrics = try #require(report.jsonObject["metrics"] as? [String: Any])
        #expect(metrics["unmatched_event_count"] as? Int == 2)
    }

    /// 反向对照：每条 caveat 都得钉住「不该报警时不报警」。全部事件都有阅读
    /// 位置时，未匹配数是 0、caveat 不出现。
    @Test func aFullyPositionedMaterialReportsNoUnmatchedEvents() throws {
        let report = try TeleprompterReplayEvaluator.evaluate(
            manifest(
                events: [
                    completed("欢迎来到今天的直播。", at: 500),
                    completed("欢迎来到今天的直播。今天我们介绍相机设置。", at: 2_000, item: "item-2")
                ],
                labels: [
                    .init(eventIndex: 0, intent: .read, expectedSegmentIndex: 0),
                    .init(eventIndex: 1, intent: .read, expectedSegmentIndex: 1)
                ]
            )
        )

        #expect(report.metrics.unmatchedEventCount == 0)
        #expect(
            !report.caveats.contains { $0.contains("未匹配") },
            "每个事件都有阅读位置时不得报未匹配：\(report.caveats)"
        )
    }

    @Test func manifestIntentStringsRoundTripThroughJSON() throws {
        // Pin the spelling so a Swift rename cannot silently break manifests
        // that live outside the repository. Every other test builds intents in
        // Swift, which is exactly why the runner shipped help text advertising
        // `re_read` / `manual_jump` for a decoder that only accepted
        // `reRead` / `manualJump` without any test noticing.
        #expect(
            TeleprompterReplayManifest.Intent.manifestValues
                == ["read", "improvise", "reRead", "manualJump"]
        )
        let decoded = try JSONDecoder().decode(
            TeleprompterReplayManifest.self,
            from: Data(Self.manifestJSON.utf8)
        )
        #expect(decoded.labels.map(\.intent) == [.read, .reRead, .manualJump])
    }

    @Test func manifestRejectsTheSnakeCaseSpellingTheHelpTextUsedToAdvertise() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                TeleprompterReplayManifest.self,
                from: Data(
                    Self.manifestJSON
                        .replacingOccurrences(of: "reRead", with: "re_read")
                        .utf8
                )
            )
        }
    }

    /// `harmfulJumpCount` only increments under an `improvise` label, and the
    /// latency percentiles only exist when a `read` label carries an expected
    /// position. A material that exercises neither therefore reports a clean
    /// run no matter how the follow path behaved. Saying so is the difference
    /// between "measured" and "not asked".
    @Test func reportSaysWhenASafetyDetectorWasNeverExercised() throws {
        let unexercised = try TeleprompterReplayEvaluator.evaluate(
            manifest(
                events: [completed("欢迎来到今天的直播。今天我们介绍相机设置。", at: 500)],
                labels: [.init(eventIndex: 0, intent: .read)]
            )
        )
        #expect(
            unexercised.caveats.contains { $0.contains("没有 improvise 标注") },
            "缺少 improvise 标注时必须说明误推进计数未被触发"
        )
        #expect(
            unexercised.caveats.contains { $0.contains("没有带 expected_segment_index") },
            "缺少定位标注时必须说明延迟分位只是未测量"
        )
        #expect(
            unexercised.metrics.harmfulJumpCount == 0,
            "计数本身仍然是 0，caveat 负责说明它没有被触发"
        )
    }

    /// 方案 §11.6 结尾一句是「所有延迟报告 P50／P95、**样本数**、语言、
    /// 设备、模型与运行条件」。回放报告原来只给分位，**样本数一个字都没有**——
    /// 而顶层那个 `sample_count` 是**事件数**，不是延迟样本数。41 秒真实素材上
    /// 两者是 82 与 4：并排放着，读的人只会把 P95 = 10993 ms 当成 82 个样本的
    /// 结论。探针侧的 `timing_summary` 一直带 `count`，回放侧是另一半。
    @Test func everyLatencyPercentileTravelsWithItsSampleCount() throws {
        let report = try TeleprompterReplayEvaluator.evaluate(
            manifest(
                events: [
                    completed("欢迎来到今天的直播。", at: 800),
                    completed("欢迎来到今天的直播。今天我们介绍相机设置。", at: 2_600, item: "item-2"),
                    completed(
                        "欢迎来到今天的直播。今天我们介绍相机设置。最后演示照片导出。",
                        at: 4_400,
                        item: "item-3"
                    )
                ],
                labels: [
                    .init(eventIndex: 0, intent: .read, expectedSegmentIndex: 1),
                    .init(eventIndex: 1, intent: .read, expectedSegmentIndex: 1),
                    .init(eventIndex: 2, intent: .read, expectedSegmentIndex: 2)
                ]
            )
        )

        #expect(
            report.metrics.trackingLatencySampleCount == 2,
            "两个段的阅读窗口各自闭合一次，跟随延迟就该有 2 个样本"
        )
        #expect(report.metrics.reanchorLatencySampleCount == 0)
        #expect(report.metrics.trackingLatencyP50Milliseconds != nil)
        #expect(
            report.jsonObject["metrics"] as? [String: Any] != nil,
            "报告必须仍然是可序列化的"
        )
        let metrics = try #require(report.jsonObject["metrics"] as? [String: Any])
        #expect(
            metrics["tracking_latency_sample_count"] as? Int
                == report.metrics.trackingLatencySampleCount,
            "分位旁边的样本数必须真的出现在 JSON 里，不能只活在 Swift 结构体上"
        )
        #expect(metrics["reanchor_latency_sample_count"] != nil)
    }

    /// 同一族的另一半：**标注给了位置，跟随却一次没到**。此时分位是 null，
    /// 而「没有带 expected_segment_index 的 read 标注」那条不触发（标注有位置）、
    /// 「一次都没有推进」也不触发（跟随在段内动过）。报告读起来是「延迟未测量」
    /// ——但它没有说**为什么**：是这份素材没问，还是问了没答上。
    @Test func aLabelledPositionTheFollowerNeverReachedIsNotReportedAsSilence() throws {
        let report = try TeleprompterReplayEvaluator.evaluate(
            manifest(
                events: [
                    completed("欢迎来到今天的直播。", at: 500),
                    completed("欢迎来到今天的直播。", at: 1_200, item: "item-2")
                ],
                labels: [
                    .init(eventIndex: 0, intent: .read, expectedSegmentIndex: 1),
                    .init(eventIndex: 1, intent: .read, expectedSegmentIndex: 1)
                ]
            )
        )

        #expect(report.metrics.advancedEventCount > 0, "前提: 跟随在段内确实动过")
        #expect(report.metrics.trackingLatencyP50Milliseconds == nil, "前提: 分位确实没量到")
        #expect(
            !report.caveats.contains { $0.contains("没有带 expected_segment_index") },
            "前提: 这条 caveat 不该触发——标注是带位置的"
        )
        #expect(
            report.caveats.contains { $0.contains("没有量到跟随延迟") },
            "标注要求的位置一次没到，报告必须说这是没答上而不是没问：\(report.caveats)"
        )
    }

    /// 上一条的**反向对照**。覆盖面 caveat 必须只在真有缺口时出现：把
    /// `<` 写成 `<=` 就能让「全部标注位置都产出了样本」的干净素材也开始报
    /// 缺口，而这种多出来的提醒和常开噪音一样有害。
    ///
    /// 标注刻意从第 1 段起：跟随控制器构造时就在第 0 段，所以第 0 段的位置
    /// 开不出「到达」那一刻——**素材自己选择不标第 0 段**才能量到完整覆盖。
    @Test func aFullyCoveredMaterialReportsNoLatencyCoverageGap() throws {
        let report = try TeleprompterReplayEvaluator.evaluate(
            manifest(
                events: [
                    completed("欢迎来到今天的直播。", at: 500),
                    completed("欢迎来到今天的直播。今天我们介绍相机设置。", at: 2_000, item: "item-2"),
                    completed(
                        "欢迎来到今天的直播。今天我们介绍相机设置。最后演示照片导出。",
                        at: 3_600,
                        item: "item-3"
                    )
                ],
                labels: [
                    .init(eventIndex: 0, intent: .read, expectedSegmentIndex: 1),
                    .init(eventIndex: 1, intent: .read, expectedSegmentIndex: 1),
                    .init(eventIndex: 2, intent: .read, expectedSegmentIndex: 2)
                ]
            )
        )

        #expect(
            report.metrics.trackingLatencySampleCount == 2,
            "前提: 两个标注位置都产出了样本"
        )
        #expect(
            !report.caveats.contains { $0.contains("跟随延迟") },
            "标注位置全部产出样本时不得报覆盖面缺口: \(report.caveats)"
        )
    }

    @Test func reportStaysQuietWhenBothDetectorsAreExercised() throws {
        let exercised = try TeleprompterReplayEvaluator.evaluate(
            manifest(
                events: [
                    completed("欢迎来到今天的直播。", at: 500),
                    completed("欢迎来到今天的直播。今天我们介绍相机设置。", at: 1_500, item: "item-2")
                ],
                labels: [
                    .init(eventIndex: 0, intent: .read, expectedSegmentIndex: 0),
                    .init(eventIndex: 1, intent: .improvise)
                ]
            )
        )
        #expect(!exercised.caveats.contains { $0.contains("没有 improvise 标注") })
        #expect(!exercised.caveats.contains { $0.contains("没有带 expected_segment_index") })
        // 「该报警时才报警」和「不该报警时不报警」是两件事。原来这里只钉了
        // 前者——多余 caveat 照样能过，于是「零推进」这条完全无条件触发也
        // 是一条能过的实现。
        #expect(
            !exercised.caveats.contains { $0.contains("一次都没有推进") },
            "正常跟上的回放不得报零推进"
        )
        #expect(
            exercised.metrics.advancedEventCount > 0,
            "这段素材里跟随确实推进过，推进计数不能是 0"
        )
    }

    /// 验收第 4 条明写「不以全部停住换取安全」。这族 caveat 原本只覆盖
    /// 「素材没问」（缺标注），**没覆盖「素材问了、系统却一次没动」**。
    ///
    /// 后面这一种更危险：标注齐全，所以「没有 improvise 标注」和「没有带
    /// expected_segment_index」两条都不触发；事件间隔压在 3 秒停顿阈值
    /// 以内，所以「错误停顿」也不触发。于是报告读起来是：0 次严重误推进、
    /// 0 次停顿、0 条 caveat——**一场什么都没跟上的干净结果**。
    ///
    /// 而这正是本文件自己注释里警告的事：「Publishing the second as the
    /// first is how a frozen follow path gets reported as a clean run.」
    @Test func aFollowPathThatNeverAdvancesIsNotReportedAsACleanRun() throws {
        let report = try TeleprompterReplayEvaluator.evaluate(
            manifest(
                events: [
                    .init(atMilliseconds: 400, kind: .completed, itemID: "item-1",
                          eventID: "evt-400", text: "完全跑偏的这一段识别内容甲"),
                    .init(atMilliseconds: 1_200, kind: .completed, itemID: "item-2",
                          eventID: "evt-1200", text: "完全跑偏的这一段识别内容乙"),
                    .init(atMilliseconds: 2_200, kind: .completed, itemID: "item-3",
                          eventID: "evt-2200", text: "完全跑偏的这一段识别内容丙")
                ],
                labels: [
                    .init(eventIndex: 0, intent: .read, expectedSegmentIndex: 0),
                    .init(eventIndex: 1, intent: .improvise),
                    .init(eventIndex: 2, intent: .read, expectedSegmentIndex: 2)
                ]
            )
        )

        // 前置：这两条必须都不触发，否则下面的断言说明不了问题。
        #expect(!report.caveats.contains { $0.contains("没有 improvise 标注") })
        #expect(!report.caveats.contains { $0.contains("没有带 expected_segment_index") })
        #expect(report.metrics.harmfulJumpCount == 0, "前提：确实一次都没推进")
        #expect(report.metrics.trackingLatencyP95Milliseconds == nil, "前提：没有跟随样本")
        #expect(
            report.caveats.contains { $0.contains("一次都没有推进") || $0.contains("没有推进过") },
            "素材标了期望段位而跟随一次没动，必须说明这份结果不代表跟随可用"
        )

        // 「0/0 个事件」不是「一次都没推进」，是没素材。evaluate 只挡空稿子、
        // 不挡空事件，所以这个分支真实可达——不钉住的话，把样本数守卫去掉
        // 也能全绿。
        let empty = try TeleprompterReplayEvaluator.evaluate(
            manifest(events: [], labels: [])
        )
        #expect(empty.metrics.sampleCount == 0)
        #expect(
            !empty.caveats.contains { $0.contains("一次都没有推进") },
            "没有事件就没有「零推进」这回事，不能报 0/0"
        )
    }

    /// 第 52 条的同族下一层。方案 §11.7 把**回稿恢复 P95** 列为质量门槛。
    /// 素材全程直读、没有一次脱稿时：恢复分位是 `null`、恢复超时是 0，
    /// 而**没有任何 caveat 解释这件事**。于是「回稿恢复 P95 = null」在一份
    /// 报告里和「回稿恢复 P95 = 0ms」长得一样——前者是没测，后者是极好。
    /// 验收人引用这个门槛时会以为测过了。
    ///
    /// **判据为什么不能是「有没有 reRead 标注」**：恢复样本来自 `reanchorStartedAt`，
    /// 而 `improvise` 事件在没有推进时也会设它。既有回归
    /// `reanchorLatencyIsMeasuredFromTheDetour` 的素材一条 `reRead` 都没有，
    /// 却量出了 1_100ms 恢复延迟——本条第一版就是按标签存在性写的，被它当场打红。
    @Test func aRunWithoutAnyDetourSaysTheRecoveryGateWasNeverMeasured() throws {
        let report = try TeleprompterReplayEvaluator.evaluate(
            manifest(
                events: [
                    completed("欢迎来到今天的直播。", at: 500),
                    completed("欢迎来到今天的直播。今天我们介绍相机设置。", at: 1_200, item: "item-2")
                ],
                labels: [
                    .init(eventIndex: 0, intent: .read, expectedSegmentIndex: 0),
                    .init(eventIndex: 1, intent: .read, expectedSegmentIndex: 1)
                ]
            )
        )

        // 前置：跟随确实推进了，所以第 52 条那条零推进告警不会来抢戏。
        #expect(report.metrics.advancedEventCount > 0)
        #expect(
            !report.caveats.contains { $0.contains("一次都没有推进") },
            "前提：这一段是正常跟上的"
        )
        #expect(report.metrics.reanchorLatencyP50Milliseconds == nil, "前提：没有恢复样本")
        #expect(report.metrics.reanchorLatencyP95Milliseconds == nil)
        #expect(report.metrics.reanchorTimeoutCount == 0, "前提：没有恢复，也就没有恢复超时")
        #expect(
            report.caveats.contains { $0.contains("回稿恢复 P95") && $0.contains("未被测量") },
            "方案把回稿恢复 P95 列为门槛，没有样本就必须说明它未被测量"
        )
    }

    @Test func reportCarriesOnlyAggregatesAndNoScriptText() throws {
        let report = try TeleprompterReplayEvaluator.evaluate(
            manifest(
                events: [completed("欢迎来到今天的直播。", at: 500)],
                labels: [.init(eventIndex: 0, intent: .read, expectedSegmentIndex: 0)]
            )
        )
        let json = String(decoding: try JSONSerialization.data(withJSONObject: report.jsonObject), as: UTF8.self)

        #expect(!json.contains("欢迎来到今天的直播"), "结果文件不得包含稿件正文或转写")
        #expect(json.contains("\"status\":\"deterministic_replay\""))
        #expect(json.contains("\"sample_count\":1"))
    }

    @Test func trackingLatencyIsMeasuredFromTheStartOfTheReadNotTheRun() throws {
        let report = try TeleprompterReplayEvaluator.evaluate(
            manifest(
                events: [
                    completed("欢迎来到今天的直播。", at: 500),
                    completed("欢迎来到今天的直播。", at: 2_000, item: "item-2"),
                    completed("欢迎来到今天的直播。今天我们介绍相机设置。", at: 2_400, item: "item-3")
                ],
                labels: [
                    .init(eventIndex: 0, intent: .read, expectedSegmentIndex: 0),
                    .init(eventIndex: 1, intent: .read, expectedSegmentIndex: 1),
                    .init(eventIndex: 2, intent: .read, expectedSegmentIndex: 1)
                ]
            )
        )

        // Segment 1 starts being read at 2.0s and is confirmed at 2.4s. A
        // long run must not make an early confirmation look slow.
        #expect(report.metrics.trackingLatencyP50Milliseconds == 400)
        #expect(report.metrics.trackingLatencyP95Milliseconds == 400)
        #expect(report.metrics.stalledEventCount == 0, "不到 3 秒不算错误停顿")
    }

    @Test func reanchorLatencyIsMeasuredFromTheDetour() throws {
        let report = try TeleprompterReplayEvaluator.evaluate(
            manifest(
                events: [
                    completed("欢迎来到今天的直播。", at: 500),
                    completed("欢迎来到今天的直播。", at: 1_500, item: "item-2"),
                    completed("欢迎来到今天的直播。今天我们介绍相机设置。", at: 2_600, item: "item-3")
                ],
                labels: [
                    .init(eventIndex: 0, intent: .read, expectedSegmentIndex: 0),
                    .init(eventIndex: 1, intent: .improvise),
                    .init(eventIndex: 2, intent: .read, expectedSegmentIndex: 1)
                ]
            )
        )

        #expect(report.metrics.reanchorLatencyP50Milliseconds == 1_100, "恢复延迟从脱稿那一刻算起")
        #expect(report.metrics.reanchorTimeoutCount == 0)
        #expect(
            report.metrics.reanchorLatencySampleCount == 1,
            "恢复延迟分位必须带着它的样本数一起走，否则 null 与 0ms 长得一样"
        )
        // 恢复这一路该测的都测到了，不该有恢复类 caveat。样本上界那条不算噪音：
        // 2.6 秒素材对误跳率几乎什么都没说，报告必须说出来（第 58 条）。
        #expect(
            report.caveats.filter { $0.contains("回稿") || $0.contains("恢复") }.isEmpty,
            "恢复延迟已量到，不应再有恢复类 caveat: \(report.caveats)"
        )
    }

    /// 素材工具在没人确认过时给 `dataset_revision` 加 `-draft` 后缀。报告此前
    /// 只解释「素材没问」与「系统没动」，**没有解释「这些标注根本没人看过」**：
    /// 拿一段无人值守的机器草稿跑回放，标注齐全、指标全真，报告读起来仍像
    /// 一次测量。实测把 5.4 秒环境声喂进去就能得到这种素材——识别器对静音
    /// 照样吐出事件，工具照样把它们全标成 `read`。
    @Test func unreviewedDraftDatasetSaysSoEvenWhenEveryOtherCaveatStaysSilent() throws {
        let report = try TeleprompterReplayEvaluator.evaluate(
            manifest(
                events: [
                    completed("欢迎来到今天的直播。", at: 500),
                    completed("欢迎来到今天的直播。", at: 1_500, item: "item-2"),
                    completed("欢迎来到今天的直播。今天我们介绍相机设置。", at: 2_600, item: "item-3")
                ],
                labels: [
                    .init(eventIndex: 0, intent: .read, expectedSegmentIndex: 0),
                    .init(eventIndex: 1, intent: .improvise),
                    .init(eventIndex: 2, intent: .read, expectedSegmentIndex: 1)
                ],
                datasetRevision: "dataset-1-draft"
            )
        )

        // 前置条件：这份 fixture 除样本上界外没有其他 caveat，所以下面那条只可能
        // 由 draft 后缀触发。把 fixture 换成有缺口的素材会让本条恒真。
        #expect(report.metrics.advancedEventCount > 0, "先确认跟随确实推进了")
        #expect(
            report.caveats.allSatisfy {
                $0.contains("未经人工确认") || $0.contains("95% 上界")
                    || $0.contains("跟随延迟")
            },
            "除草稿声明外不应再有其他 caveat: \(report.caveats)"
        )
        #expect(
            report.caveats.contains { $0.contains("未经人工确认") && $0.contains("机器") },
            "报告必须自己声明标注是机器草稿: \(report.caveats)"
        )
    }

    @Test func reviewedDatasetKeepsTheSilenceItEarned() throws {
        let report = try TeleprompterReplayEvaluator.evaluate(
            manifest(
                events: [
                    completed("欢迎来到今天的直播。", at: 500),
                    completed("欢迎来到今天的直播。", at: 1_500, item: "item-2"),
                    completed("欢迎来到今天的直播。今天我们介绍相机设置。", at: 2_600, item: "item-3")
                ],
                labels: [
                    .init(eventIndex: 0, intent: .read, expectedSegmentIndex: 0),
                    .init(eventIndex: 1, intent: .improvise),
                    .init(eventIndex: 2, intent: .read, expectedSegmentIndex: 1)
                ],
                datasetRevision: "dataset-1"
            )
        )

        // 反向对照：去掉后缀后草稿声明必须消失，否则这条 caveat 就成了常开
        // 噪音，真出问题时反而被忽略。报告**不再完全沉默**——零误推进的样本
        // 上界是常开的（第 58 条），跟随延迟的样本覆盖面也是常开的（第 62 条：
        // 跟随控制器从第 0 段起步，所以标注为第 0 段的位置开不出「到达」那一刻，
        // 这份 fixture 的 2 个标注位置里只有 1 个产出样本），所以这里断言的是
        // 「剩下的 caveat 只有这两类」。
        #expect(!report.caveats.contains { $0.contains("未经人工确认") })
        #expect(
            report.caveats.allSatisfy { $0.contains("95% 上界") || $0.contains("跟随延迟") },
            "复核过的素材只剩样本上界与延迟覆盖面两条: \(report.caveats)"
        )
    }

    @Test func failureShareAboveFivePercentFlagsPartialPercentiles() throws {
        let report = try TeleprompterReplayEvaluator.evaluate(
            manifest(
                events: [
                    completed("欢迎来到今天的直播。", at: 500),
                    .init(
                        atMilliseconds: 900,
                        kind: .failed,
                        itemID: "item-2",
                        eventID: "evt-fail",
                        text: ""
                    ),
                    completed("欢迎来到今天的直播。", at: 1_400, item: "item-3")
                ],
                labels: [
                    .init(eventIndex: 0, intent: .read, expectedSegmentIndex: 0),
                    .init(eventIndex: 2, intent: .read, expectedSegmentIndex: 0)
                ]
            )
        )

        #expect(report.metrics.terminalFailureCount == 1)
        #expect(report.metrics.failedSampleCount == 1)
        #expect(report.metrics.failureShare > TeleprompterReplayEvaluator.failureShareThreshold)
        #expect(report.metrics.failureShareExceedsThreshold)
        #expect(report.caveats.contains { $0.contains("不能单独引用") })

        let json = String(decoding: try JSONSerialization.data(withJSONObject: report.jsonObject), as: UTF8.self)
        #expect(json.contains("\"failure_share_exceeds_threshold\":true"))
        #expect(json.contains("\"caveats\""))
        #expect(json.contains("\"unlabelled_event_count\""))
    }

    @Test func aStallOnlyCountsAfterTheThresholdElapses() throws {
        let report = try TeleprompterReplayEvaluator.evaluate(
            manifest(
                events: [
                    completed("欢迎来到今天的直播。", at: 500),
                    completed("欢迎来到今天的直播。", at: 2_000, item: "item-2"),
                    completed("欢迎来到今天的直播。", at: 7_500, item: "item-3")
                ],
                labels: [
                    .init(eventIndex: 0, intent: .read, expectedSegmentIndex: 0),
                    .init(eventIndex: 1, intent: .read, expectedSegmentIndex: 1),
                    .init(eventIndex: 2, intent: .read, expectedSegmentIndex: 1)
                ]
            )
        )

        // Segment 1 starts being read at 2.0s; nothing confirms it by 7.5s, so
        // the first event past the 3s threshold is the first counted stall.
        #expect(report.metrics.stalledEventCount == 1)
        #expect(report.metrics.trackingLatencyP50Milliseconds == nil, "没有确认就没有跟随延迟")
        #expect(report.caveats.contains { $0.contains("错误停顿") })
    }

    /// 这两条 caveat 是「不把没测到的说成没问题」的最后一道闸：
    /// 未标注的事件不计入分母，恢复超时的样本按失败计入，两者都必须显式说出来，
    /// 否则报告里的 0 会被读成「安全」而不是「没测」。
    @Test func unlabelledEventsAndReanchorTimeoutsBothSurfaceAsCaveats() throws {
        let unlabelled = try TeleprompterReplayEvaluator.evaluate(
            manifest(
                events: [
                    completed("欢迎来到今天的直播。", at: 500),
                    completed("欢迎来到今天的直播。", at: 1_400, item: "item-2")
                ],
                labels: [
                    .init(eventIndex: 0, intent: .read, expectedSegmentIndex: 0)
                ]
            )
        )
        #expect(unlabelled.metrics.unlabelledEventCount == 1)
        #expect(unlabelled.caveats.contains { $0.contains("没有人工标注") })

        // 脱稿后超过恢复时限才确认：计入失败与恢复超时，而不是被悄悄丢掉。
        let stalled = try TeleprompterReplayEvaluator.evaluate(
            manifest(
                events: [
                    completed("欢迎来到今天的直播。", at: 500),
                    completed("这里即兴说一段。", at: 6_000, item: "item-2"),
                    completed("欢迎来到今天的直播。", at: 12_000, item: "item-3")
                ],
                labels: [
                    .init(eventIndex: 0, intent: .read, expectedSegmentIndex: 0),
                    .init(eventIndex: 1, intent: .improvise),
                    .init(eventIndex: 2, intent: .read, expectedSegmentIndex: 0)
                ]
            )
        )
        #expect(stalled.metrics.reanchorTimeoutCount >= 1)
        #expect(stalled.caveats.contains { $0.contains("回稿恢复超时") })
    }

    /// 失败占比的分母是事件数，分子却只记「最后一次未恢复」：同一次未恢复，
    /// 拖尾事件越多分母越大、占比越低——**恢复失败拖得越久，评分反而越好**。
    @Test func aLongerUnrecoveredTailCannotImproveTheFailureShare() throws {
        func replay(trailing: Int) throws -> TeleprompterReplayEvaluator.Report {
            var events: [TeleprompterReplayManifest.Event] = [
                completed("欢迎来到今天的直播。今天我们介绍相机设置。", at: 500)
            ]
            var labels: [TeleprompterReplayManifest.Label] = [
                .init(eventIndex: 0, intent: .read, expectedSegmentIndex: 1)
            ]
            for i in 0...trailing {
                events.append(
                    completed("现场观众提问互动。", at: 1_000 + i * 600, item: "tail-\(i)")
                )
                labels.append(.init(eventIndex: events.count - 1, intent: .improvise))
            }
            return try TeleprompterReplayEvaluator.evaluate(
                manifest(events: events, labels: labels)
            )
        }

        let short = try replay(trailing: 5)
        let long = try replay(trailing: 40)

        // 前提：跟随确实建立过锚点并推进过，测的是失败分母而不是「压根没动」。
        #expect(short.metrics.advancedEventCount > 0)
        #expect(long.metrics.advancedEventCount > 0)
        #expect(short.metrics.reanchorTimeoutCount == 1, "前提：素材末尾仍未恢复")
        #expect(
            long.metrics.reanchorTimeoutCount == 1,
            "同一次未恢复，不因为拖尾变长而被算成多次"
        )

        #expect(
            long.metrics.failureShare > short.metrics.failureShare,
            "同一次未恢复，拖尾越长失败占比必须越高，不能被更大的分母稀释"
        )
        #expect(
            long.metrics.failureShareExceedsThreshold,
            "未恢复窗口覆盖了 40 个事件里的 36 个，必须超过 5% 门槛"
        )
        #expect(
            long.metrics.failedSampleCount > 1,
            "未恢复窗口内的每个事件都是失败样本，不能整段只记 1"
        )
    }

    /// 未恢复的回稿窗口只有「最后那个」会被记进超时：中间只要恢复一次，
    /// 之前真实发生过的超时就被抹掉——§11.6 要求超时算失败、不删样本。
    @Test func everyUnrecoveredReanchorEpisodeIsCountedNotOnlyTheLast() throws {
        let report = try TeleprompterReplayEvaluator.evaluate(
            manifest(
                events: [
                    completed("欢迎来到今天的直播。今天我们介绍相机设置。", at: 500),
                    completed("现场观众提问互动。", at: 1_000, item: "item-2"),
                    completed("现场观众提问互动。", at: 5_000, item: "item-3"),
                    completed("最后演示照片导出。", at: 5_200, item: "item-4"),
                    completed("现场观众提问互动。", at: 6_000, item: "item-5"),
                    completed("现场观众提问互动。", at: 10_000, item: "item-6"),
                    completed("今天我们介绍相机设置。", at: 10_500, item: "item-7"),
                    completed("今天我们介绍相机设置。", at: 11_000, item: "item-8")
                ],
                labels: [
                    .init(eventIndex: 0, intent: .read, expectedSegmentIndex: 1),
                    .init(eventIndex: 1, intent: .improvise),
                    .init(eventIndex: 2, intent: .improvise),
                    .init(eventIndex: 3, intent: .read, expectedSegmentIndex: 2),
                    .init(eventIndex: 4, intent: .improvise),
                    .init(eventIndex: 5, intent: .improvise),
                    .init(eventIndex: 6, intent: .reRead),
                    .init(eventIndex: 7, intent: .read, expectedSegmentIndex: 1)
                ]
            )
        )

        #expect(report.metrics.advancedEventCount > 0, "前提：跟随建立过锚点")
        #expect(
            report.metrics.reanchorTimeoutCount == 2,
            "两次未恢复各记一次；最后一次恢复了也不能把前一次抹掉"
        )
        #expect(report.metrics.failedSampleCount >= 2)
        #expect(report.caveats.contains { $0.contains("回稿恢复超时 2 次") })
    }

    /// 停顿门槛与回稿窗口是两个独立概念，共用一个 deadline 会让「跟随还没回来」
    /// 期间的正确停顿不计数：§11.7 的错误停滞比例因此被系统性低估。
    @Test func aStallDuringAnUnrecoveredReanchorWindowStillCounts() throws {
        let report = try TeleprompterReplayEvaluator.evaluate(
            manifest(
                events: [
                    completed("欢迎来到今天的直播。", at: 500),
                    completed("现场观众提问互动。", at: 1_000, item: "item-2"),
                    completed("欢迎来到今天的直播。", at: 3_600, item: "item-3")
                ],
                labels: [
                    .init(eventIndex: 0, intent: .read, expectedSegmentIndex: 0),
                    .init(eventIndex: 1, intent: .improvise),
                    .init(eventIndex: 2, intent: .read, expectedSegmentIndex: 0)
                ]
            )
        )

        // 3.6s 距该段开始朗读已过 3s 门槛，即使回稿窗口要到 4.0s 才到期。
        #expect(
            report.metrics.stalledEventCount == 1,
            "停顿门槛不得被尚未到期的回稿 deadline 挡住"
        )
        #expect(report.metrics.reanchorTimeoutCount == 0, "前提：回稿窗口本身还没超时")
    }

    /// 上一条的解耦有过一次副作用：把停顿门槛从回稿 deadline 上摘下来之后，
    /// 它再也不随「恢复成功」重置，一个**在旧停顿之前就打开**的读窗口会被
    /// 旧门槛挡住。41 秒真实素材上错误停顿因此从 12 掉到 11。
    @Test func aRecoveryReleasesTheStallGateForWindowsOpenedEarlier() throws {
        let report = try TeleprompterReplayEvaluator.evaluate(
            manifest(
                events: [
                    completed("欢迎来到今天的直播。今天我们介绍相机设置。", at: 400),
                    completed("现场观众提问互动。", at: 500, item: "item-2"),
                    completed("现场观众提问互动。", at: 1_000, item: "item-3"),
                    completed("现场观众提问互动。", at: 4_000, item: "item-4"),
                    completed("最后演示照片导出。", at: 4_100, item: "item-5"),
                    completed("现场观众提问互动。", at: 4_200, item: "item-6")
                ],
                labels: [
                    .init(eventIndex: 0, intent: .read, expectedSegmentIndex: 1),
                    .init(eventIndex: 1, intent: .read, expectedSegmentIndex: 0),
                    .init(eventIndex: 2, intent: .read, expectedSegmentIndex: 1),
                    .init(eventIndex: 3, intent: .read, expectedSegmentIndex: 1),
                    .init(eventIndex: 4, intent: .read, expectedSegmentIndex: 2),
                    .init(eventIndex: 5, intent: .read, expectedSegmentIndex: 0)
                ]
            )
        )

        // index 1 的窗口在 1.0s 打开、4.0s 停顿；index 0 的窗口在 0.5s 就打开了，
        // 4.2s 时也已过 3s 门槛。4.1s 的回稿恢复必须把门槛释放掉。
        #expect(
            report.metrics.stalledEventCount == 2,
            "恢复之后，先前打开的读窗口仍应能计自己的停顿"
        )
    }

    /// 方案 §11.6／§11.7 把「零事件的 95% 上界约为 3 / 总小时数」写进指标定义，
    /// 判定方式一栏还要求「不声称真实发生率为零」。报告此前只在**误推进 > 0** 时
    /// 才输出 caveat——0 次时整份报告读起来像一次干净的安全结论。
    @Test func zeroHarmfulJumpsOverShortMaterialReportsItsSampleBound() throws {
        func replay(lastAtMilliseconds: Int) throws -> TeleprompterReplayEvaluator.Report {
            try TeleprompterReplayEvaluator.evaluate(
                manifest(
                    events: [
                        completed("欢迎来到今天的直播。今天我们介绍相机设置。", at: 500),
                        completed("最后演示照片导出。", at: lastAtMilliseconds, item: "item-2")
                    ],
                    labels: [
                        .init(eventIndex: 0, intent: .read, expectedSegmentIndex: 1),
                        .init(eventIndex: 1, intent: .read, expectedSegmentIndex: 2)
                    ]
                )
            )
        }

        let short = try replay(lastAtMilliseconds: 10_000)
        let long = try replay(lastAtMilliseconds: 100_000)

        #expect(short.metrics.harmfulJumpCount == 0)
        #expect(short.metrics.advancedEventCount > 0, "前提：跟随推进过，不是压根没动")

        func bound(_ report: TeleprompterReplayEvaluator.Report) -> Int? {
            for caveat in report.caveats where caveat.contains("95% 上界") {
                guard let marker = caveat.range(of: "约为 ") else { return nil }
                let tail = caveat[marker.upperBound...]
                    .prefix { $0.isNumber }
                return Int(tail)
            }
            return nil
        }

        #expect(
            short.caveats.contains { $0.contains("不作为产品性能宣称") },
            "零事件必须自己说明它不是零发生率"
        )
        let shortBound = try #require(bound(short))
        let longBound = try #require(bound(long))
        #expect(
            longBound < shortBound,
            "上界必须随时长收紧：10 秒素材给 \(shortBound)、100 秒素材给 \(longBound)"
        )
        #expect(shortBound == 1_080, "3 / (10 / 3600) 小时 = 1080 次／小时")
    }

    /// 反向对照：真的误推进过时报的是次数与总时长，不是样本上界。
    @Test func aMaterialWithHarmfulJumpsReportsTheCountNotTheSampleBound() throws {
        let report = try TeleprompterReplayEvaluator.evaluate(
            manifest(
                events: [
                    completed("欢迎来到今天的直播。", at: 500),
                    completed("最后演示照片导出。", at: 4_000, item: "item-2")
                ],
                labels: [
                    .init(eventIndex: 0, intent: .read, expectedSegmentIndex: 0),
                    .init(eventIndex: 1, intent: .improvise)
                ]
            )
        )

        #expect(report.metrics.harmfulJumpCount == 1, "前提：确实发生了一次误推进")
        #expect(report.caveats.contains { $0.contains("严重误推进 1 次") })
        #expect(
            !report.caveats.contains { $0.contains("95% 上界") },
            "已经观测到事件时，样本上界不是该说的那句话"
        )
    }
}
