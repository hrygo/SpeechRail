import Foundation
import SpeechRailControlKit

/// Recorded material for a deterministic replay: the frozen script, the
/// Realtime events in receive order, and the human labels the plan requires
/// (intent per event, plus the reading position the reader actually reached).
/// Audio, full transcripts and credentials never live here.
public struct TeleprompterReplayManifest: Codable, Equatable, Sendable {
    public static let schemaVersion = "teleprompter.replay.v1"

    public struct Segment: Codable, Equatable, Sendable {
        public let id: String
        public let text: String

        public init(id: String, text: String) {
            self.id = id
            self.text = text
        }
    }

    public struct Event: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Equatable, Sendable {
            case partial
            case snapshot
            case completed
            case failed
        }

        /// Virtual clock offset from the first event. Replay never sleeps.
        public let atMilliseconds: Int
        public let kind: Kind
        public let itemID: String
        public let eventID: String
        public let revision: Int?
        public let text: String
        public let stablePrefixCodepoints: Int?

        public init(
            atMilliseconds: Int,
            kind: Kind,
            itemID: String,
            eventID: String,
            revision: Int? = nil,
            text: String,
            stablePrefixCodepoints: Int? = nil
        ) {
            self.atMilliseconds = atMilliseconds
            self.kind = kind
            self.itemID = itemID
            self.eventID = eventID
            self.revision = revision
            self.text = text
            self.stablePrefixCodepoints = stablePrefixCodepoints
        }

        private enum CodingKeys: String, CodingKey {
            case atMilliseconds = "at_milliseconds"
            case kind
            case itemID = "item_id"
            case eventID = "event_id"
            case revision
            case text
            case stablePrefixCodepoints = "stable_prefix_codepoints"
        }
    }

    /// What the reader was really doing. The plan is explicit that the label
    /// describes the human behaviour, not the model output.
    public enum Intent: String, Codable, Equatable, Sendable {
        /// Normal reading: the system is expected to follow along.
        case read = "read"
        /// Ad-libbing or pausing: holding is fine, jumping ahead is not.
        case improvise = "improvise"
        /// Genuinely re-reading an earlier sentence.
        case reRead = "reRead"
        /// The reader navigated manually; voice must not take the stage back.
        case manualJump = "manualJump"

        /// The exact strings a manifest may carry. Raw values are pinned
        /// explicitly so a Swift rename cannot silently change the on-disk
        /// contract, and the runner's help text and error message both read
        /// this list so documentation cannot drift from the decoder.
        public static let manifestValues = ["read", "improvise", "reRead", "manualJump"]
    }

    public struct Label: Codable, Equatable, Sendable {
        public let eventIndex: Int
        public let intent: Intent
        /// Reading position the reader had reached after this event, when known.
        public let expectedSegmentIndex: Int?

        public init(eventIndex: Int, intent: Intent, expectedSegmentIndex: Int? = nil) {
            self.eventIndex = eventIndex
            self.intent = intent
            self.expectedSegmentIndex = expectedSegmentIndex
        }

        private enum CodingKeys: String, CodingKey {
            case eventIndex = "event_index"
            case intent
            case expectedSegmentIndex = "expected_segment_index"
        }
    }

    public let schemaVersion: String
    public let datasetRevision: String
    public let baselineCommit: String
    public let candidateCommit: String
    public let policyRevision: String
    public let languageLane: String
    public let deviceClass: String
    public let segments: [Segment]
    public let events: [Event]
    public let labels: [Label]

    public init(
        schemaVersion: String = Self.schemaVersion,
        datasetRevision: String,
        baselineCommit: String,
        candidateCommit: String,
        policyRevision: String,
        languageLane: String,
        deviceClass: String,
        segments: [Segment],
        events: [Event],
        labels: [Label]
    ) {
        self.schemaVersion = schemaVersion
        self.datasetRevision = datasetRevision
        self.baselineCommit = baselineCommit
        self.candidateCommit = candidateCommit
        self.policyRevision = policyRevision
        self.languageLane = languageLane
        self.deviceClass = deviceClass
        self.segments = segments
        self.events = events
        self.labels = labels
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case datasetRevision = "dataset_revision"
        case baselineCommit = "baseline_commit"
        case candidateCommit = "candidate_commit"
        case policyRevision = "policy_revision"
        case languageLane = "language_lane"
        case deviceClass = "device_class"
        case segments
        case events
        case labels
    }
}

public enum TeleprompterReplayError: Error, Equatable, Sendable {
    case missingDatasetRevision
    case missingVersionRecord
    case unsupportedSchema(String)
    case emptyScript
    case labelOutOfRange(Int)
}

/// Replays recorded events through the production follow adapter and
/// controller, then scores the actions against the human labels. Deterministic:
/// a virtual clock, no model, no audio, no network.
public enum TeleprompterReplayEvaluator {
    /// A stall longer than this counts against the reading experience instead
    /// of disappearing from the average.
    public static let stallThresholdMilliseconds = 3_000
    /// §11.6: above this failure share the latency percentiles describe only
    /// the successful subset and must not be quoted alone.
    public static let failureShareThreshold = 0.05

    public struct Metrics: Codable, Equatable, Sendable {
        public var sampleCount: Int
        /// How many events actually moved the reading position forward. This
        /// is the denominator that makes "0 harmful jumps" readable: a run
        /// that never advances trivially has zero harmful jumps, and without
        /// this counter the report cannot tell that apart from a clean run.
        public var advancedEventCount: Int
        public var harmfulJumpCount: Int
        public var unintentionalBackjumpCount: Int
        /// E3：有假设后的空 final（保位、不提交、可观察未确认）。
        /// 只计 adapter 实际返回 .unconfirmed 的事件；无先前证据的空 final
        /// 是 ignored，不计入。空 final 不记成功确认、不进延迟分母。
        public var unconfirmedFinalCount: Int
        /// E2/F-15：稳定前缀契约异常（越界/改写后暂停推进）的可见计数。
        /// 只含聚合数，不含 item IDs、正文、文本哈希或音频。
        public var stablePrefixContractAnomalyCount: Int
        public var trackingLatencyP50Milliseconds: Int?
        public var trackingLatencyP95Milliseconds: Int?
        public var reanchorLatencyP50Milliseconds: Int?
        public var reanchorLatencyP95Milliseconds: Int?
        /// §11.6 要求每个延迟分位都带样本数。分位本身不说明它由几个样本算出:
        /// 4 个样本的 P95 与 80 个样本的 P95 在 JSON 里长得一模一样, 而顶层那个
        /// `sampleCount` 是**事件数**, 不是延迟样本数——两者并排时读的人只会
        /// 拿事件数当分母。探针侧的 `timing_summary` 一直带 `count`, 回放侧是
        /// 另一半, 这一对把它补上。
        public var trackingLatencySampleCount: Int
        public var reanchorLatencySampleCount: Int
        /// §11.6 结尾要求「超时和**未匹配**数量单列」。一个事件没有阅读位置，
        /// 就既产不出延迟样本、也不算失败——它从两个方向同时退出统计。修复前
        /// 报告里没有任何字段说明这类事件有多少，真实素材上 82 个里有 18 个。
        public var unmatchedEventCount: Int
        public var reanchorTimeoutCount: Int
        public var manualCorrectionCount: Int
        public var stalledEventCount: Int
        public var unlabelledEventCount: Int
        public var terminalFailureCount: Int
        public var failedSampleCount: Int
        public var failureShare: Double
        public var failureShareExceedsThreshold: Bool
    }

    public struct Report: Codable, Equatable, Sendable {
        // E3 新增聚合字段（unconfirmed_final_count、
        // stable_prefix_contract_anomaly_count）后升级为 v2。
        // 输入 teleprompter.replay.v1 保持现有结构。
        public static let schemaVersion = "teleprompter.eval.v2"

        public let schemaVersion: String
        public let runID: String
        public let baselineCommit: String
        public let candidateCommit: String
        public let datasetRevision: String
        public let policyRevision: String
        public let condition: [String: String]
        public let sampleCount: Int
        public let durationMilliseconds: Int
        public let metrics: Metrics
        /// Human-readable guards the plan requires next to every aggregate:
        /// denominators, timeouts and unlabelled material, never hidden.
        public let caveats: [String]
        /// `not_run` until authorized material is replayed; never `passed`
        /// with null metrics.
        public let status: String

        public var jsonObject: [String: Any] {
            [
                "schema_version": schemaVersion,
                "run_id": runID,
                "baseline_commit": baselineCommit,
                "candidate_commit": candidateCommit,
                "dataset_revision": datasetRevision,
                "policy_revision": policyRevision,
                "condition": condition,
                "sample_count": sampleCount,
                "duration_seconds": durationMilliseconds / 1_000,
                "metrics": [
                    "advanced_event_count": metrics.advancedEventCount,
                    "harmful_jump_count": metrics.harmfulJumpCount,
                    "unintentional_backjump_count": metrics.unintentionalBackjumpCount,
                    "unconfirmed_final_count": metrics.unconfirmedFinalCount,
                    "stable_prefix_contract_anomaly_count": metrics.stablePrefixContractAnomalyCount,
                    "tracking_latency_p50_ms": metrics.trackingLatencyP50Milliseconds
                        .map { NSNumber(value: $0) } as Any,
                    "tracking_latency_p95_ms": metrics.trackingLatencyP95Milliseconds
                        .map { NSNumber(value: $0) } as Any,
                    "tracking_latency_sample_count": metrics.trackingLatencySampleCount,
                    "reanchor_latency_p50_ms": metrics.reanchorLatencyP50Milliseconds
                        .map { NSNumber(value: $0) } as Any,
                    "reanchor_latency_p95_ms": metrics.reanchorLatencyP95Milliseconds
                        .map { NSNumber(value: $0) } as Any,
                    "reanchor_latency_sample_count": metrics.reanchorLatencySampleCount,
                    "unmatched_event_count": metrics.unmatchedEventCount,
                    "reanchor_timeout_count": metrics.reanchorTimeoutCount,
                    "manual_correction_count": metrics.manualCorrectionCount,
                    "stalled_event_count": metrics.stalledEventCount,
                    "unlabelled_event_count": metrics.unlabelledEventCount,
                    "terminal_failure_count": metrics.terminalFailureCount,
                    "failed_sample_count": metrics.failedSampleCount,
                    "failure_share": metrics.failureShare,
                    "failure_share_exceeds_threshold": metrics.failureShareExceedsThreshold
                ],
                "caveats": caveats,
                "status": status
            ]
        }
    }

    public static func evaluate(_ manifest: TeleprompterReplayManifest) throws -> Report {
        guard manifest.schemaVersion == TeleprompterReplayManifest.schemaVersion else {
            throw TeleprompterReplayError.unsupportedSchema(manifest.schemaVersion)
        }
        // The plan requires the runner to refuse material without a dataset
        // revision or version record instead of inventing one.
        guard !manifest.datasetRevision.isEmpty else {
            throw TeleprompterReplayError.missingDatasetRevision
        }
        guard !manifest.baselineCommit.isEmpty,
              !manifest.candidateCommit.isEmpty,
              !manifest.policyRevision.isEmpty
        else {
            throw TeleprompterReplayError.missingVersionRecord
        }
        guard !manifest.segments.isEmpty else {
            throw TeleprompterReplayError.emptyScript
        }
        for label in manifest.labels where label.eventIndex < 0
            || label.eventIndex >= manifest.events.count {
            throw TeleprompterReplayError.labelOutOfRange(label.eventIndex)
        }

        let segments = manifest.segments.enumerated().map { index, segment in
            TeleprompterSegment(
                id: segment.id,
                ordinal: index,
                sourceRange: .init(start: 0, end: segment.text.utf16.count),
                text: segment.text
            )
        }
        let labelsByIndex = Dictionary(
            manifest.labels.map { ($0.eventIndex, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var controller = TeleprompterFollowController(currentIndex: 0, mode: .following)
        let adapter = TeleprompterRealtimeFollowAdapter()
        var metrics = Metrics(
            sampleCount: manifest.events.count,
            advancedEventCount: 0,
            harmfulJumpCount: 0,
            unintentionalBackjumpCount: 0,
            unconfirmedFinalCount: 0,
            stablePrefixContractAnomalyCount: 0,
            trackingLatencyP50Milliseconds: nil,
            trackingLatencyP95Milliseconds: nil,
            reanchorLatencyP50Milliseconds: nil,
            reanchorLatencyP95Milliseconds: nil,
            trackingLatencySampleCount: 0,
            reanchorLatencySampleCount: 0,
            unmatchedEventCount: 0,
            reanchorTimeoutCount: 0,
            manualCorrectionCount: 0,
            stalledEventCount: 0,
            unlabelledEventCount: 0,
            terminalFailureCount: 0,
            failedSampleCount: 0,
            failureShare: 0,
            failureShareExceedsThreshold: false
        )
        var latencies: [Int] = []
        var reanchorLatencies: [Int] = []
        // Tracking latency is measured from the moment a segment starts being
        // read, not from the start of the run, so a long rehearsal cannot make
        // an early confirmation look slow.
        var readWindowStart: [Int: Int] = [:]
        var manualJumpPending = false
        var reanchorDeadline: Int?
        var reanchorStartedAt: Int?
        // Latched once a reanchor window has run past its deadline. Without it
        // only the window still open at the end of the run was ever inspected,
        // so an episode that later recovered was indistinguishable from one
        // that never stalled — §11.6 counts timeouts as failures instead of
        // deleting the sample.
        var reanchorTimedOut = false
        // The read branch keeps a deadline of its own to count at most one
        // stall per threshold window. Sharing the reanchor deadline let a
        // stall overwrite a pending reanchor deadline, so the timeout that
        // deadline existed to raise could never fire.
        var stallGateDeadline: Int?
        // Failures are counted per event so the numerator shares the unit of
        // `sampleCount`. Counting episodes against an event denominator meant
        // one unrecovered stall spread over a long tail scored better than the
        // same stall in a short run.
        var failedEventCount = 0
        let endReanchorWindow: () -> Void = {
            if reanchorTimedOut { metrics.reanchorTimeoutCount += 1 }
            reanchorTimedOut = false
            reanchorDeadline = nil
            reanchorStartedAt = nil
            // A recovery means the follower caught up, so the next read window
            // must be able to count its own stall. The gate used to be cleared
            // here as a side effect of sharing the reanchor deadline; losing
            // that reset cost one stall on the 41-second material (12 → 11).
            stallGateDeadline = nil
        }

        for (index, event) in manifest.events.enumerated() {
            let label = labelsByIndex[index]
            if label == nil { metrics.unlabelledEventCount += 1 }
            let before = controller.viewportAnchor
            let anomaliesBefore = controller.stablePrefixContractAnomalies
            let outcome = adapter.apply(
                wireEvent(for: event),
                metadata: RealtimeEventMetadata(eventID: event.eventID),
                segments: segments,
                to: &controller
            )
            var eventFailed = false
            if case .terminalFailure = outcome {
                metrics.terminalFailureCount += 1
                eventFailed = true
            }
            // E3：未确认 final 单列——空 final 不记成功确认、不进延迟分母。
            // 延迟样本只在“到达阅读位置”时产出，未确认事件保位故无样本。
            if case .unconfirmed = outcome {
                metrics.unconfirmedFinalCount += 1
            }
            // E2/F-15：稳定前缀契约异常单列——只计聚合数，不含正文或 IDs。
            if controller.stablePrefixContractAnomalies > anomaliesBefore {
                metrics.stablePrefixContractAnomalyCount += 1
            }
            let after = controller.viewportAnchor
            let advanced = after.segmentIndex > before.segmentIndex
                || (after.segmentIndex == before.segmentIndex
                    && after.utf16Offset > before.utf16Offset)
            if advanced { metrics.advancedEventCount += 1 }
            let reversed = after.segmentIndex < before.segmentIndex
                || (after.segmentIndex == before.segmentIndex
                    && after.utf16Offset < before.utf16Offset)

            switch label?.intent {
            case .read:
                manualJumpPending = false
                if let expected = label?.expectedSegmentIndex {
                    if readWindowStart[expected] == nil {
                        readWindowStart[expected] = event.atMilliseconds
                    }
                    if after.segmentIndex >= expected, before.segmentIndex < expected {
                        if let start = readWindowStart.removeValue(forKey: expected) {
                            latencies.append(event.atMilliseconds - start)
                        }
                        if let reanchorStart = reanchorStartedAt {
                            reanchorLatencies.append(event.atMilliseconds - reanchorStart)
                        }
                        endReanchorWindow()
                    } else if let start = readWindowStart[expected] {
                        // A stall only counts once the threshold has actually
                        // elapsed, then once per threshold window.
                        let thresholdAt = start + Self.stallThresholdMilliseconds
                        if event.atMilliseconds >= thresholdAt,
                           event.atMilliseconds >= (stallGateDeadline ?? 0) {
                            metrics.stalledEventCount += 1
                            stallGateDeadline = thresholdAt + Self.stallThresholdMilliseconds
                        }
                    }
                } else {
                    // 标注说这是正常朗读，却**没有给出阅读位置**。这件事对「跟随
                    // 有没有跟上」不提供任何证据：它既没说跟上，也没说没跟上。
                    //
                    // 此前这里调 `endReanchorWindow()`，等于把「读不懂」当成
                    // 「跟上了」。可复现的后果：读者脱稿后连着两个对不上稿的事件
                    // 一路走过超时门槛，报告给出 0 次超时、0 个失败样本——一次也
                    // 没恢复的跟随被抹平。§11.6 说超时算失败、不删除样本，那就
                    // 不能在没有证据的时候宣布恢复。
                    //
                    // 停顿门槛同理：它由**恢复**释放，门槛的意义是「一个阈值窗口
                    // 只记一次停顿」。真实素材上 22 次释放里有 18 次来自这里，
                    // 修好后停顿数 12 → 11，少掉的那次出现在 t=27009ms——它能计上
                    // 只因为同一时刻一个对不上稿的事件把门槛提前释放了，正是这条
                    // 规则要防的重复计数。
                    metrics.unmatchedEventCount += 1
                }
            case .improvise:
                manualJumpPending = false
                if advanced {
                    metrics.harmfulJumpCount += 1
                } else if reanchorDeadline == nil {
                    reanchorDeadline = event.atMilliseconds + Self.stallThresholdMilliseconds
                    reanchorStartedAt = event.atMilliseconds
                }
            case .reRead:
                manualJumpPending = false
                if reversed {
                    endReanchorWindow()
                } else if reanchorDeadline == nil {
                    reanchorDeadline = event.atMilliseconds + Self.stallThresholdMilliseconds
                    reanchorStartedAt = event.atMilliseconds
                }
            case .manualJump:
                manualJumpPending = true
                // A takeover only counts as a correction when the system had
                // actually misbehaved; an ordinary manual jump is not a fix.
                if metrics.harmfulJumpCount > 0 {
                    metrics.manualCorrectionCount += 1
                }
            case nil:
                break
            }

            if reversed, label?.intent != .reRead, !manualJumpPending {
                metrics.unintentionalBackjumpCount += 1
            }
            if manualJumpPending, advanced {
                metrics.harmfulJumpCount += 1
            }
            // Checked after the label switch so a recovery closing the window
            // on this very event is not retroactively counted as a failure.
            if let deadline = reanchorDeadline, event.atMilliseconds >= deadline {
                reanchorTimedOut = true
            }
            if eventFailed || reanchorTimedOut { failedEventCount += 1 }
        }

        // A window still open when the material ends never recovered, so it is
        // a timeout even though no later event was there to observe the
        // deadline being passed. Without this the worst case — the follower
        // never came back at all — was the one case that reported zero.
        endReanchorWindow()
        metrics.trackingLatencyP50Milliseconds = percentile(0.5, of: latencies)
        metrics.trackingLatencyP95Milliseconds = percentile(0.95, of: latencies)
        metrics.reanchorLatencyP50Milliseconds = percentile(0.5, of: reanchorLatencies)
        metrics.reanchorLatencyP95Milliseconds = percentile(0.95, of: reanchorLatencies)
        metrics.trackingLatencySampleCount = latencies.count
        metrics.reanchorLatencySampleCount = reanchorLatencies.count
        metrics.failedSampleCount = failedEventCount
        metrics.failureShare = manifest.events.isEmpty
            ? 0
            : Double(failedEventCount) / Double(manifest.events.count)
        metrics.failureShareExceedsThreshold = metrics.failureShare > Self.failureShareThreshold

        return Report(
            schemaVersion: Report.schemaVersion,
            runID: "\(manifest.datasetRevision)-\(manifest.policyRevision)",
            baselineCommit: manifest.baselineCommit,
            candidateCommit: manifest.candidateCommit,
            datasetRevision: manifest.datasetRevision,
            policyRevision: manifest.policyRevision,
            condition: [
                "language_lane": manifest.languageLane,
                "device_class": manifest.deviceClass
            ],
            sampleCount: manifest.events.count,
            durationMilliseconds: manifest.events.last?.atMilliseconds ?? 0,
            metrics: metrics,
            caveats: caveats(
                for: metrics,
                sampleCount: manifest.events.count,
                durationMilliseconds: manifest.events.last?.atMilliseconds ?? 0,
                labels: manifest.labels,
                datasetRevision: manifest.datasetRevision
            ),
            status: "deterministic_replay"
        )
    }

    private static func wireEvent(for event: TeleprompterReplayManifest.Event) -> RealtimeASRClient.Event {
        switch event.kind {
        case .partial:
            return .partial(itemID: event.itemID, delta: event.text)
        case .snapshot:
            return .partialSnapshot(
                itemID: event.itemID,
                revision: event.revision ?? 1,
                text: event.text,
                evidence: .init(stablePrefixCodepoints: event.stablePrefixCodepoints)
            )
        case .completed:
            return .completed(itemID: event.itemID, transcript: event.text)
        case .failed:
            return .failed(itemID: event.itemID, code: "replay", message: "replay")
        }
    }

    private static func percentile(_ fraction: Double, of samples: [Int]) -> Int? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let rank = Int((Double(sorted.count - 1) * fraction).rounded(.up))
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    /// The plan requires every aggregate to travel with its denominator and
    /// with anything that was not counted, so a reader cannot quote a
    /// convenient subset.
    private static func caveats(
        for metrics: Metrics,
        sampleCount: Int,
        durationMilliseconds: Int,
        labels: [TeleprompterReplayManifest.Label],
        datasetRevision: String
    ) -> [String] {
        var caveats: [String] = []
        // 素材工具在没人逐条确认过时给 `dataset_revision` 加 `-draft` 后缀。
        // 这一条必须排在最前面：下面几条解释的都是「这份素材没有问某个问题」，
        // 而草稿的问题更靠前——**所有标注都还不是证据**。少了它，一份机器草稿
        // 只要标注恰好齐全、指标恰好全真，读起来就与一次人工确认过的测量完全
        // 一样。实测把 5.4 秒环境声喂进识别器就能得到这种素材：识别器对静音
        // 照样吐事件，工具照样把它们全标成 `read`。
        if datasetRevision.hasSuffix("-draft") {
            caveats.append(
                "本次素材是未经人工确认的机器草稿（dataset_revision 以 -draft 结尾）："
                    + "所有 intent 与阅读位置都由机器提议，未被逐条核对过，"
                    + "本报告的数字不能作为质量结论。"
            )
        }
        // Every safety number below is derived from human labels, so a zero has
        // two very different meanings: "the system did not do this" or "the
        // material never asked". Publishing the second as the first is how a
        // frozen follow path gets reported as a clean run.
        if !labels.contains(where: { $0.intent == .improvise }) {
            caveats.append("本次素材没有 improvise 标注：严重误推进只在该标注下计数，因此 0 表示该检测项未被触发，不表示跟随不会越权推进。")
        }
        if !labels.contains(where: { $0.intent == .read && $0.expectedSegmentIndex != nil }) {
            caveats.append("本次素材没有带 expected_segment_index 的 read 标注：跟随与恢复延迟没有样本，分位为 null 只说明未测量，不表示延迟为零。")
        }
        // 上一条管的是「素材没问」。这一条管的是「素材问了、跟随没答上」：标注里
        // 带着阅读位置，所以上面那条不触发；跟随在段内动过，所以「一次都没有
        // 推进」也不触发。于是分位是 null、报告读起来像「延迟不用测」。
        //
        // 注意措辞：**不是「从未到达」**。跟随控制器构造时就在第 0 段，所以任何
        // 标注为第 0 段的位置都开不出「到达」那一刻——它不是没到，是一开始就在。
        // 这类位置和真没到达的位置一样，都不产出样本，且都不被判为失败。分位自
        // 己不会说它由几个样本算出，所以样本数与没产出样本的位置数都要写出来。
        let labelledPositions = Set(
            labels.lazy
                .filter { $0.intent == .read }
                .compactMap(\.expectedSegmentIndex)
        )
        if metrics.trackingLatencySampleCount < labelledPositions.count {
            let unreached = labelledPositions.count - metrics.trackingLatencySampleCount
            if metrics.trackingLatencySampleCount == 0 {
                caveats.append(
                    "本次回放没有量到跟随延迟：素材标注了 \(labelledPositions.count) 个阅读位置，"
                        + "但没有一个产出延迟样本，分位为 null 只说明这份素材没答上，"
                        + "不表示延迟为零。"
                )
            } else {
                caveats.append(
                    "跟随延迟分位只来自 \(metrics.trackingLatencySampleCount) 个样本，"
                        + "而素材标注了 \(labelledPositions.count) 个阅读位置："
                        + "另有 \(unreached) 个标注位置整段回放里没有产出延迟样本"
                        + "（跟随一开始就在该段上，或一直没到达），"
                        + "它们既没有贡献样本、也没有被判为失败。"
                )
            }
        }
        if metrics.unmatchedEventCount > 0 {
            // §11.6 的「未匹配数量单列」。这类事件最容易在报告里消失：它既不是
            // 延迟样本（没有位置就算不出延迟），也不是失败样本（没有位置就没法说
            // 跟随违约），所以两个分位和失败占比都不覆盖它。数字必须自己站出来。
            caveats.append(
                "本次回放的未匹配事件有 \(metrics.unmatchedEventCount)/\(sampleCount) 个"
                    + "（标注为 read 但未给出 expected_segment_index，因而没有阅读位置）："
                    + "它们既不产生延迟样本、也不计为失败，延迟分位与失败占比都不覆盖这部分事件。"
            )
        }
        // 方案 §11.7 把「回稿恢复 P95」列为质量门槛。恢复样本的来源是
        // `reanchorStartedAt`——**`reRead` 与「`improvise` 但没有推进」都会设它**，
        // 所以判据不能是「有没有 reRead 标注」：一份全程直读、没有 reRead 的
        // 素材同样可能量出恢复延迟（既有回归 `reanchorLatencyIsMeasuredFromTheDetour`
        // 就是这种素材，它没有 reRead 标注却量出了 1_100ms）。
        //
        // 这里直接看分位本身有没有样本。恢复超时为 0 在这里同样是「没问」而不是
        // 「没发生」：缺这一条，null 与 0ms 在报告里长得一样，验收人会以为这个
        // 门槛测过了。
        if metrics.reanchorLatencyP95Milliseconds == nil {
            caveats.append("本次回放没有量到回稿恢复延迟（分位为 null、超时为 0）：方案 §11.7 的回稿恢复 P95 门槛本次未被测量，不表示恢复够快。")
        }
        // 上面两条管的是「素材没问」。这一条管的是「素材问了，系统却一次没动」——
        // 标注齐全时上面两条都不触发，事件够密时「错误停顿」也不触发，于是
        // 「0 次严重误推进」会被读成干净结果。一条完全停住的跟随路径必须自己
        // 说明自己没跟上，否则这份报告无法用于任何验收判断。
        if metrics.advancedEventCount == 0, sampleCount > 0 {
            caveats.append(
                "本次回放跟随一次都没有推进（0/\(sampleCount) 个事件移动了阅读位置）："
                    + "0 次严重误推进只说明跟随没有动过，不表示跟随可用；延迟分位为空同理。"
            )
        }
        if metrics.failureShareExceedsThreshold {
            caveats.append(
                "失败样本占比 \(formatPercent(metrics.failureShare))"
                    + "（\(metrics.failedSampleCount)/\(sampleCount) 个事件）超过 5%；"
                    + "延迟分位只覆盖成功子集，不能单独引用。"
            )
        }
        if metrics.reanchorTimeoutCount > 0 {
            // 超时按「次」记，未恢复窗口内的每个事件按「样本」记：分子分母
            // 同为事件，失败拖得越久占比只会越高，不会被更长的素材稀释。
            caveats.append(
                "回稿恢复超时 \(metrics.reanchorTimeoutCount) 次；"
                    + "未恢复窗口内的 \(metrics.failedSampleCount) 个事件按失败样本计入，未删除样本。"
            )
        }
        if metrics.unlabelledEventCount > 0 {
            caveats.append("\(metrics.unlabelledEventCount) 个事件没有人工标注，未计入延迟样本。")
        }
        if metrics.stalledEventCount > 0 {
            caveats.append("错误停顿 \(metrics.stalledEventCount) 次，分母为样本 \(sampleCount)。")
        }
        if metrics.harmfulJumpCount > 0 {
            caveats.append("严重误推进 \(metrics.harmfulJumpCount) 次，总时长 \(durationMilliseconds) ms。")
        } else if durationMilliseconds > 0 {
            // 方案 §11.6 给出「零事件的 95% 上界约为 3 / 总小时数」，§11.7 的判定
            // 方式一栏要求「不声称真实发生率为零」。此前 0 次时整份报告没有任何
            // 说明——**素材越短，证据越弱，报告读起来却越像一次干净的安全结论**。
            // 这条只在真的观测到事件时不输出：那时候该报的是次数，不是样本上界。
            let hours = Double(durationMilliseconds) / 3_600_000
            let upperBoundPerHour = Int((3 / hours).rounded())
            caveats.append(
                "本次回放未观察到严重误推进（0 次／素材时长 \(durationMilliseconds / 1_000) 秒）："
                    + "零事件不等于零发生率。按方案 §11.6 的独立稳定事件过程近似，"
                    + "零事件的 95% 上界约为 \(upperBoundPerHour) 次／小时（3 / 观测小时数）；"
                    + "该数字用于提醒样本边界，不作为产品性能宣称。"
            )
        }
        return caveats
    }

    private static func formatPercent(_ share: Double) -> String {
        String(format: "%.1f%%", share * 100)
    }
}
