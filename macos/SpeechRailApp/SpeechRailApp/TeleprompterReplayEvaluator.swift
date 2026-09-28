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
        public var harmfulJumpCount: Int
        public var unintentionalBackjumpCount: Int
        public var trackingLatencyP50Milliseconds: Int?
        public var trackingLatencyP95Milliseconds: Int?
        public var reanchorLatencyP50Milliseconds: Int?
        public var reanchorLatencyP95Milliseconds: Int?
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
        public static let schemaVersion = "teleprompter.eval.v1"

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
                    "harmful_jump_count": metrics.harmfulJumpCount,
                    "unintentional_backjump_count": metrics.unintentionalBackjumpCount,
                    "tracking_latency_p50_ms": metrics.trackingLatencyP50Milliseconds
                        .map { NSNumber(value: $0) } as Any,
                    "tracking_latency_p95_ms": metrics.trackingLatencyP95Milliseconds
                        .map { NSNumber(value: $0) } as Any,
                    "reanchor_latency_p50_ms": metrics.reanchorLatencyP50Milliseconds
                        .map { NSNumber(value: $0) } as Any,
                    "reanchor_latency_p95_ms": metrics.reanchorLatencyP95Milliseconds
                        .map { NSNumber(value: $0) } as Any,
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
            harmfulJumpCount: 0,
            unintentionalBackjumpCount: 0,
            trackingLatencyP50Milliseconds: nil,
            trackingLatencyP95Milliseconds: nil,
            reanchorLatencyP50Milliseconds: nil,
            reanchorLatencyP95Milliseconds: nil,
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

        for (index, event) in manifest.events.enumerated() {
            let label = labelsByIndex[index]
            if label == nil { metrics.unlabelledEventCount += 1 }
            let before = controller.viewportAnchor
            let outcome = adapter.apply(
                wireEvent(for: event),
                metadata: RealtimeEventMetadata(eventID: event.eventID),
                segments: segments,
                to: &controller
            )
            if case .terminalFailure = outcome { metrics.terminalFailureCount += 1 }
            let after = controller.viewportAnchor
            let advanced = after.segmentIndex > before.segmentIndex
                || (after.segmentIndex == before.segmentIndex
                    && after.utf16Offset > before.utf16Offset)
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
                        reanchorDeadline = nil
                        reanchorStartedAt = nil
                    } else if let start = readWindowStart[expected] {
                        // A stall only counts once the threshold has actually
                        // elapsed, then once per threshold window.
                        let thresholdAt = start + Self.stallThresholdMilliseconds
                        if event.atMilliseconds >= thresholdAt,
                           event.atMilliseconds >= (reanchorDeadline ?? 0) {
                            metrics.stalledEventCount += 1
                            reanchorDeadline = thresholdAt + Self.stallThresholdMilliseconds
                        }
                    }
                } else {
                    reanchorDeadline = nil
                    reanchorStartedAt = nil
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
                    reanchorDeadline = nil
                    reanchorStartedAt = nil
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
        }

        if let deadline = reanchorDeadline, let last = manifest.events.last {
            if last.atMilliseconds >= deadline { metrics.reanchorTimeoutCount += 1 }
        }
        metrics.trackingLatencyP50Milliseconds = percentile(0.5, of: latencies)
        metrics.trackingLatencyP95Milliseconds = percentile(0.95, of: latencies)
        metrics.reanchorLatencyP50Milliseconds = percentile(0.5, of: reanchorLatencies)
        metrics.reanchorLatencyP95Milliseconds = percentile(0.95, of: reanchorLatencies)
        let failedSampleCount = metrics.terminalFailureCount + metrics.reanchorTimeoutCount
        metrics.failedSampleCount = failedSampleCount
        metrics.failureShare = manifest.events.isEmpty
            ? 0
            : Double(failedSampleCount) / Double(manifest.events.count)
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
                durationMilliseconds: manifest.events.last?.atMilliseconds ?? 0
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
        durationMilliseconds: Int
    ) -> [String] {
        var caveats: [String] = []
        if metrics.failureShareExceedsThreshold {
            caveats.append(
                "失败样本占比 \(formatPercent(metrics.failureShare))（\(metrics.failedSampleCount)/\(sampleCount)）超过 5%；延迟分位只覆盖成功子集，不能单独引用。"
            )
        }
        if metrics.reanchorTimeoutCount > 0 {
            caveats.append("回稿恢复超时 \(metrics.reanchorTimeoutCount) 次，按失败计入，未删除样本。")
        }
        if metrics.unlabelledEventCount > 0 {
            caveats.append("\(metrics.unlabelledEventCount) 个事件没有人工标注，未计入延迟样本。")
        }
        if metrics.stalledEventCount > 0 {
            caveats.append("错误停顿 \(metrics.stalledEventCount) 次，分母为样本 \(sampleCount)。")
        }
        if metrics.harmfulJumpCount > 0 {
            caveats.append("严重误推进 \(metrics.harmfulJumpCount) 次，总时长 \(durationMilliseconds) ms。")
        }
        return caveats
    }

    private static func formatPercent(_ share: Double) -> String {
        String(format: "%.1f%%", share * 100)
    }
}
