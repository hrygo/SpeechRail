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
        #expect(report.caveats.isEmpty)
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

        // 前置条件：这份 fixture 的其他 caveat 全部沉默，所以下面那条只可能
        // 由 draft 后缀触发。把 fixture 换成有缺口的素材会让本条恒真。
        #expect(report.metrics.advancedEventCount > 0, "先确认跟随确实推进了")
        #expect(
            report.caveats.filter { !$0.contains("未经人工确认") }.isEmpty,
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

        // 反向对照：去掉后缀后必须恢复安静，否则这条 caveat 就成了常开噪音，
        // 真出问题时反而被忽略。
        #expect(!report.caveats.contains { $0.contains("未经人工确认") })
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
}
