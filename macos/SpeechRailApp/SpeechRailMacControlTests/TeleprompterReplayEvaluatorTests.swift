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
