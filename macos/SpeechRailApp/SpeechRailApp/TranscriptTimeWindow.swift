import Foundation

/// 一句转录的时间证据（方案 MA-02 / MC-15）。
///
/// 这里唯一不能含糊的是**"什么时候说的"**和**"什么时候收到的"**——
/// 它们是两个不同的事实。客户端只在定稿那一刻知道后者。
///
/// 原来的代码用 `commitCursor` 到 `now` 的**接收间隔**当 `tStart` / `tEnd`，
/// 那等于对着用户谎报"你在这 12.4 秒里说的这句话"。所以这个类型把两件事
/// 分开摆，并且**让伪造精度在类型层面不可能**：
///
/// - `speechRange` 在没有对齐证据时返回 `nil`。调用方拿不到"看起来像真的"
///   声学起止，只能老老实实写观测时间并标 `unavailable`；
/// - 想标 `aligned` 就必须同时交出**真实的**声学区间，没有别的路。
public struct TranscriptTimeWindow: Hashable, Sendable {
    /// 观测到的起点（收到这段的会话相对时刻）。
    public var observedStart: TimeInterval
    /// 观测到的终点。
    public var observedEnd: TimeInterval
    /// 声学起止。只有拿到对齐证据时才有。
    public var acousticRange: ClosedRange<TimeInterval>?

    public init(
        observedStart: TimeInterval,
        observedEnd: TimeInterval,
        acousticRange: ClosedRange<TimeInterval>? = nil
    ) {
        self.observedStart = observedStart
        self.observedEnd = observedEnd
        self.acousticRange = acousticRange
    }

    /// 只有观测时间的窗口。**明确不知道**说话发生在什么时候。
    public static func observedOnly(start: TimeInterval, end: TimeInterval) -> TranscriptTimeWindow {
        TranscriptTimeWindow(observedStart: start, observedEnd: end, acousticRange: nil)
    }

    /// 有对齐证据的窗口。
    public static func aligned(
        observedStart: TimeInterval,
        observedEnd: TimeInterval,
        acoustic: ClosedRange<TimeInterval>
    ) -> TranscriptTimeWindow {
        TranscriptTimeWindow(
            observedStart: observedStart,
            observedEnd: observedEnd,
            acousticRange: acoustic
        )
    }

    /// 这句话**发生在什么时候**。
    ///
    /// 没有对齐证据时返回 `nil`——不是 0、不是观测时间、不是猜的值。
    /// 界面据此显示"未知"，不制造 `00:00` 或精确声学起止（MC-15）。
    public var speechRange: ClosedRange<TimeInterval>? { acousticRange }

    /// 写库用的时间质量。
    public var quality: SessionTimingQuality {
        acousticRange == nil ? .unavailable : .aligned
    }

    /// 界面上那句时间标签的文案。
    ///
    /// 有声学证据就报区间；没有就明说"观测时间（未知发声时刻）"——
    /// 让用户知道自己看到的是**什么时候被记下来的**，不是**什么时候说的**。
    public var displayText: String {
        guard let range = acousticRange else {
            return "观测时间（未知发声时刻）"
        }
        return "\(Self.clockText(range.lowerBound))–\(Self.clockText(range.upperBound))"
    }

    /// 观测区间仍然要能展示：它诚实地说明"这一段是在这时被记下来的"。
    public var observedText: String {
        "\(Self.clockText(observedStart))–\(Self.clockText(observedEnd))"
    }

    // MARK: - 从对齐证据升级

    /// 用对齐单元里的采样区间把窗口升级成"知道发声时刻"。
    ///
    /// 拿不到就返回 `nil`——**不猜、不沿用观测值**。宁可让这一行继续显示
    /// "未知发声时刻"，也不把别的时刻写进去。
    ///
    /// 三条硬要求，少一条都不升级：
    /// - 单元自己声明 `timingQuality == "aligned"`；
    /// - 起止采样都在，且**终样大于起样**；
    /// - 采样率是正数。
    public static func aligned(
        observed: TranscriptTimeWindow,
        units: [RealtimeASRClient.AttributionUnit],
        sampleRate: Double
    ) -> TranscriptTimeWindow? {
        guard sampleRate > 0 else { return nil }
        let usable = units.filter {
            $0.timingQuality == "aligned"
                && $0.audioStartSample != nil
                && $0.audioEndSample != nil
                && $0.audioEndSample! > $0.audioStartSample!
        }
        guard let first = usable.min(by: { ($0.audioStartSample ?? 0) < ($1.audioStartSample ?? 0) }),
              let last = usable.max(by: { ($0.audioEndSample ?? 0) < ($1.audioEndSample ?? 0) }),
              let startSample = first.audioStartSample,
              let endSample = last.audioEndSample
        else { return nil }
        let lower = Double(startSample) / sampleRate
        let upper = Double(endSample) / sampleRate
        // 夹进观测区间：发声不可能早于第一块上行的接收，也不可能晚于定稿。
        // 这个夹取不制造精度，只挡掉明显越界的数据。
        let clampedLower = max(observed.observedStart, lower)
        let clampedUpper = min(max(observed.observedEnd, clampedLower), upper)
        guard clampedUpper > clampedLower else { return nil }
        return aligned(
            observedStart: observed.observedStart,
            observedEnd: observed.observedEnd,
            acoustic: clampedLower ... clampedUpper
        )
    }

    // MARK: - 界面呈现

    /// 时间列显示的字。
    ///
    /// **没有对齐证据时不显示数字**，显示 `—`。原因很直接：那一列如果写着
    /// `00:12`，用户只会读成"这句话是在 12 秒时说的"，而它其实是
    /// "这段在 12 秒时**被记下来**"。列宽只够放一个短字，所以选择不写，
    /// 而不是加一个需要悬停才能看见的角标。
    public static func timecodeColumn(
        observed: TimeInterval,
        quality: SessionTimingQuality?
    ) -> String {
        quality == .aligned ? clockText(observed) : "—"
    }

    /// 读屏与悬停用的完整说明。两件事都要说清：什么时候说的、什么时候记下的。
    public static func accessibilityText(
        observedStart: TimeInterval,
        observedEnd: TimeInterval,
        quality: SessionTimingQuality?
    ) -> String {
        let recorded = "\(clockText(observedStart))–\(clockText(observedEnd))"
        guard quality == .aligned else {
            return "说话时刻未知，这一段是在 \(recorded) 记下来的"
        }
        return "说话时刻 \(recorded)"
    }

    private static func clockText(_ value: TimeInterval) -> String {
        let total = max(0, Int(value.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
