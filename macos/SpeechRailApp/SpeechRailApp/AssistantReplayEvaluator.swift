import Foundation

/// VA-17b 语音助手离线回放评估：纯 manifest 驱动的确定性评估。
///
/// 只消费仓库外已授权素材的事件序列，输出去标识聚合；
/// 不录音、不下载模型、不联网；缺素材版本记录时直接失败。
/// 形态复用提词器 teleprompter-replay（schema 版本化、缺素材直接失败）。
public enum AssistantReplayEvaluator {
    public static let schemaVersion = "assistant.replay.v1"
    public static let reportSchemaVersion = "assistant.eval.v1"

    /// 回放事件：沿用生产 AssistantSession.Turn 的最小投影，
    /// 只记身份、顺序与交付状态，不记完整正文。
    public struct ReplayEvent: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Equatable, Sendable {
            case turnAdded
            case playbackStarted
            case playbackInterrupted
            case playbackCompleted
            case sealed
        }

        public let atMilliseconds: Int
        public let kind: Kind
        public let turnID: String
        public let ordinal: Int
        public let isInterrupted: Bool

        public init(
            atMilliseconds: Int,
            kind: Kind,
            turnID: String,
            ordinal: Int,
            isInterrupted: Bool = false
        ) {
            self.atMilliseconds = atMilliseconds
            self.kind = kind
            self.turnID = turnID
            self.ordinal = ordinal
            self.isInterrupted = isInterrupted
        }

        private enum CodingKeys: String, CodingKey {
            case atMilliseconds = "at_milliseconds"
            case kind
            case turnID = "turn_id"
            case ordinal
            case isInterrupted = "is_interrupted"
        }
    }

    public struct Manifest: Codable, Equatable, Sendable {
        public let datasetRevision: String
        public let baselineCommit: String
        public let policyRevision: String
        public let events: [ReplayEvent]

        public init(
            datasetRevision: String,
            baselineCommit: String,
            policyRevision: String,
            events: [ReplayEvent]
        ) {
            self.datasetRevision = datasetRevision
            self.baselineCommit = baselineCommit
            self.policyRevision = policyRevision
            self.events = events
        }

        private enum CodingKeys: String, CodingKey {
            case datasetRevision = "dataset_revision"
            case baselineCommit = "baseline_commit"
            case policyRevision = "policy_revision"
            case events
        }
    }

    public struct Metrics: Codable, Equatable, Sendable {
        public let eventCount: Int
        public let turnCount: Int
        public let interruptedTurnCount: Int
        public let completedPlaybackCount: Int
        public let sealedCount: Int
    }

    public struct Report: Codable, Equatable, Sendable {
        public let schema: String
        public let datasetRevision: String
        public let baselineCommit: String
        public let policyRevision: String
        public let metrics: Metrics
        public let caveats: [String]

        public var jsonObject: [String: Any] {
            [
                "schema": schema,
                "dataset_revision": datasetRevision,
                "baseline_commit": baselineCommit,
                "policy_revision": policyRevision,
                "metrics": [
                    "event_count": metrics.eventCount,
                    "turn_count": metrics.turnCount,
                    "interrupted_turn_count": metrics.interruptedTurnCount,
                    "completed_playback_count": metrics.completedPlaybackCount,
                    "sealed_count": metrics.sealedCount,
                ],
                "caveats": caveats,
            ]
        }
    }

    public enum EvaluateError: Error, Equatable, Sendable {
        case missingDatasetRevision
        case missingBaselineCommit
        case emptyEvents
    }

    /// 纯函数评估：只数身份、顺序与交付状态，不读正文。
    /// 离线事件不能证明 AEC、双讲或设备尾音，报告 caveats 固定声明。
    public static func evaluate(_ manifest: Manifest) throws -> Report {
        guard !manifest.datasetRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EvaluateError.missingDatasetRevision
        }
        guard !manifest.baselineCommit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EvaluateError.missingBaselineCommit
        }
        guard !manifest.events.isEmpty else { throw EvaluateError.emptyEvents }
        let turns = Set(manifest.events.map(\.turnID)).count
        let interrupted = Set(
            manifest.events.filter(\.isInterrupted).map(\.turnID)
        ).count
        let completed = manifest.events.filter { $0.kind == .playbackCompleted }.count
        let sealed = manifest.events.filter { $0.kind == .sealed }.count
        return Report(
            schema: reportSchemaVersion,
            datasetRevision: manifest.datasetRevision,
            baselineCommit: manifest.baselineCommit,
            policyRevision: manifest.policyRevision,
            metrics: Metrics(
                eventCount: manifest.events.count,
                turnCount: turns,
                interruptedTurnCount: interrupted,
                completedPlaybackCount: completed,
                sealedCount: sealed
            ),
            caveats: [
                "离线转写事件不能证明 AEC、双讲或设备尾音；A57 须真实扬声器麦克风闭环。",
                "本报告仅聚合计数与版本信息，不含音频、完整正文或转写；未运行记 not_run，不用 0 冒充无错误。",
            ]
        )
    }
}
