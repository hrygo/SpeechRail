import Foundation

/// 会议相关的六条状态轴，分别投影（MA-21）。
///
/// 为什么是六条而不是一个枚举：这几件事**各自会独立地坏**。
/// 压成一个状态，用户就会得到一个必然不完整的答案——
/// 最糟的两种误报是：
/// - 采集在跑、识别断了 → 显示"正在录音"，用户以为文字会自己出现；
/// - 内容存下了、索引还没跟上 → 显示"已保存"，用户搜不到就以为没存进去。
///
/// 所以每条轴**各说各的**，一个轴的问题不许掩盖另一个轴（MA-21 / MC-74）。
public struct MeetingAxisProjection: Hashable, Sendable {
    /// 一条轴的状态。`.unknown` 不是"正常"，是"还不知道"——
    /// 把它当成正常报出去，就是界面说出了没有的事。
    public enum State: Hashable, Sendable {
        case unknown
        case ready
        case active
        case paused
        case degraded(String)
        case failed(String)
        case idle

        public var isProblem: Bool {
            switch self {
            case .degraded, .failed: true
            case .unknown, .ready, .active, .paused, .idle: false
            }
        }

        /// 没坏，但用户要知道它**没有在动**。
        public var isQuiet: Bool {
            switch self {
            case .idle, .paused: true
            default: false
            }
        }
    }

    /// ① 就绪：服务与纪要模型能不能用。
    public var readiness: State
    /// ② 采集：此刻在不在收声音。
    public var capture: State
    /// ③ 识别：转录流有没有连上。
    public var recognition: State
    /// ④ 保存：内容有没有真的写进库。
    public var persistence: State
    /// ⑤ 索引：检索侧跟上了没有。**与保存分开报**（§6.5）。
    public var index: State
    /// ⑥ 审阅：有没有待用户处理的疑点。
    public var review: State

    public init(
        readiness: State = .unknown,
        capture: State = .unknown,
        recognition: State = .unknown,
        persistence: State = .unknown,
        index: State = .unknown,
        review: State = .unknown
    ) {
        self.readiness = readiness
        self.capture = capture
        self.recognition = recognition
        self.persistence = persistence
        self.index = index
        self.review = review
    }

    /// 审阅轴（MA-21）。这一轴之前恒为 `.idle`，等于界面明明有
    /// 待复核的结论却什么都不说。
    ///
    /// 三档分开报，因为它们要用户做的事不一样：
    /// - `rejected`：**正文不成立**，不能当成结论看；
    /// - `needsReview`：引用合法但语义可疑，要人看一眼；
    /// - 全部 `supported` 才算审阅通过。
    public static func reviewState(
        verdicts: [MinutesEvidenceValidator.Verdict]
    ) -> State {
        let rejected = verdicts.filter { $0 == .rejected }.count
        if rejected > 0 {
            return .failed("有 \(rejected) 条结论的引用不成立，不能当结论看")
        }
        let needsReview = verdicts.filter { $0 == .needsReview }.count
        if needsReview > 0 {
            return .degraded("有 \(needsReview) 条结论待复核")
        }
        // 一条都没有就是"还没开始核对"，不是"核对通过"。
        return verdicts.isEmpty ? .idle : .ready
    }

    /// 六个轴的稳定顺序。**顺序固定**，界面上的行才不会每次刷新都换位置。
    public var axes: [(name: String, state: State)] {
        [
            ("就绪", readiness),
            ("采集", capture),
            ("识别", recognition),
            ("保存", persistence),
            ("索引", index),
            ("审阅", review),
        ]
    }

    /// 有问题的轴。**只报真正坏的**，不把"没在动"当成故障。
    public var problems: [(name: String, state: State)] {
        axes.filter { $0.state.isProblem }
    }

    /// 现在能不能开始采集。只看就绪与采集两条。
    public var canStart: Bool {
        !readiness.isProblem && !capture.isProblem
            && readiness != .unknown && capture != .unknown
    }

    /// 有没有"用户应该去看一眼"的轴。
    ///
    /// `unknown` 算进去：还没开始不等于没异常，界面不该在状态不明时说"一切正常"。
    public var needsAttention: Bool {
        problems.isEmpty == false || axes.contains { $0.state == .unknown }
    }

    /// 状态带上的事实行。**一行一条轴**，不做合并——
    /// 合并会把"采集在跑但识别断了"这种最需要说清的情况说没了。
    public var factLines: [String] {
        axes.compactMap { axis in
            switch axis.state {
            case .unknown: nil
            case .ready: "\(axis.name)：正常"
            case .active: "\(axis.name)：进行中"
            case .paused: "\(axis.name)：已暂停"
            case .idle: "\(axis.name)：没有在动"
            case .degraded(let reason): "\(axis.name)：降级（\(reason)）"
            case .failed(let reason): "\(axis.name)：失败（\(reason)）"
            }
        }
    }

    /// 一句话结论。**只由问题推出**，全部正常时不加任何修饰。
    public var headline: String {
        if problems.isEmpty { return axes.contains { $0.state == .active } ? "进行中" : "暂无异常" }
        let names = problems.map(\.name).joined(separator: "、")
        return "\(names)有问题"
    }

    /// 状态色。**只有真坏了才是 attention**：
    /// "没有在动"不是故障，给它 warning 色会让用户到处找问题。
    public var tone: StatusTone {
        if axes.contains(where: { $0.state.isProblem }) { return .attention }
        return axes.contains { $0.state == .active } ? .healthy : .neutral
    }
}
