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

    private static func clockText(_ value: TimeInterval) -> String {
        let total = max(0, Int(value.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
