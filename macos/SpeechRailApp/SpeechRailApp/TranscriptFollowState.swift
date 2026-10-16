import Foundation

/// 转录流的"粘底"策略（MA-10）。
///
/// 问题：会议进行中每来一句就把视图滚到底部。会中用户经常要往上翻
/// 找刚才那句——**这时新句子不断把他拽回来**，回看根本读不下去。
///
/// 规矩只有一条：**用户离开底部就不许自动抢滚动**。
/// 跟随时正常跟随；离开后保持原位，并告诉他"下面有 n 条新的"，
/// 由他决定什么时候回去。回看优先于"看起来很实时"。
public struct TranscriptFollowState: Hashable, Sendable {
    /// 贴底判定的中心距离（pt）；拖动条无法精确停在 0。
    public static let bottomTolerance: Double = 24
    /// 吸收阈值附近的小幅几何抖动；未读提示引起的视口变化由离散状态处理。
    private static let thresholdHysteresis: Double = 2

    /// 离底部的离散区间。中间带保留前一状态，避免阈值附近的小幅几何变化
    /// 反复切换跟随状态和未读提示。
    public enum ScrollProximity: Hashable, Sendable {
        case atBottom
        case thresholdBand
        case awayFromBottom
    }

    /// 是否跟着底部走。
    public var isPinnedToBottom: Bool
    /// 用户离开底部之后累积的新内容条数。用于"下面有 n 条新的"。
    public var unseenCount: Int
    /// 已经落在底部、且用户没在看上面时，累积的总行数（给锚点用）。
    public var pinnedAnchor: String?

    public init(
        isPinnedToBottom: Bool = true,
        unseenCount: Int = 0,
        pinnedAnchor: String? = nil
    ) {
        self.isPinnedToBottom = isPinnedToBottom
        self.unseenCount = unseenCount
        self.pinnedAnchor = pinnedAnchor
    }

    public enum ScrollDecision: Hashable, Sendable {
        /// 跟到底部（带不带动画由界面决定）。
        case follow(anchor: String?)
        /// 保持用户当前阅读位置，什么都不做。
        case hold
    }

    /// 将内容底边和可见视口底边转换为离散距离区间。
    /// 内容短于视口时距离归零，仍视为贴底。
    public static func scrollProximity(
        contentBottomY: Double,
        viewportBottomY: Double
    ) -> ScrollProximity {
        proximity(forDistanceFromBottom: max(0, contentBottomY - viewportBottomY))
    }

    /// 用户滚动后的新状态。`distanceFromBottom` 是内容底边到视口底边的距离。
    public func userScrolled(toBottomWithin distanceFromBottom: Double) -> TranscriptFollowState {
        userScrolled(to: Self.proximity(forDistanceFromBottom: max(0, distanceFromBottom)))
    }

    /// 使用内容与视口的底边坐标更新跟随状态。
    public func userScrolled(
        contentBottomY: Double,
        viewportBottomY: Double
    ) -> TranscriptFollowState {
        userScrolled(to: Self.scrollProximity(
            contentBottomY: contentBottomY,
            viewportBottomY: viewportBottomY
        ))
    }

    /// 内容增长、窗口变化和程序滚动不代表用户要离开底部。
    public func geometryChanged(
        to proximity: ScrollProximity, isUserInitiated: Bool
    ) -> TranscriptFollowState {
        guard isUserInitiated else { return self }
        return userScrolled(to: proximity)
    }

    /// 消费离散滚动区间。阈值带内保持原状态，避免视口波动造成横幅闪烁。
    public func userScrolled(to proximity: ScrollProximity) -> TranscriptFollowState {
        switch proximity {
        case .atBottom:
            guard !isPinnedToBottom else { return self }
            return TranscriptFollowState(
                isPinnedToBottom: true,
                unseenCount: 0,
                pinnedAnchor: pinnedAnchor
            )
        case .awayFromBottom:
            guard isPinnedToBottom else { return self }
            return TranscriptFollowState(
                isPinnedToBottom: false,
                unseenCount: unseenCount,
                pinnedAnchor: pinnedAnchor
            )
        case .thresholdBand:
            return self
        }
    }

    /// 记住当前贴底时最后一条的 id，作为滚动锚点。
    public func anchoring(_ lineID: String?) -> TranscriptFollowState {
        var next = self
        if isPinnedToBottom { next.pinnedAnchor = lineID }
        return next
    }

    /// 新内容到了。返回该做什么，并给出下一状态。
    ///
    /// 关键点：**新增行数不改变"能不能抢滚动"**。只要用户已经离开底部，
    /// 哪怕这次来了十行也一条都不自动滚——他正在读上面。
    public func contentArrived(lineCount: Int) -> (decision: ScrollDecision, state: TranscriptFollowState) {
        var next = self
        if isPinnedToBottom {
            return (.follow(anchor: pinnedAnchor), next)
        }
        next.unseenCount = unseenCount + max(0, lineCount)
        return (.hold, next)
    }

    /// 用户主动"回到最新"。这是**用户**的意图，可以抢滚动。
    public func jumpToLatest(anchor: String?) -> TranscriptFollowState {
        TranscriptFollowState(isPinnedToBottom: true, unseenCount: 0, pinnedAnchor: anchor)
    }

    /// 换一场会（或重新打开）时复位。
    public func reset() -> TranscriptFollowState {
        TranscriptFollowState()
    }

    /// 底部提示条。没离开底部就不出现。
    public var unseenBannerText: String? {
        guard unseenCount > 0 else { return nil }
        return unseenCount == 1 ? "下面有 1 条新的" : "下面有 \(unseenCount) 条新的"
    }

    private static func proximity(forDistanceFromBottom distance: Double) -> ScrollProximity {
        if distance <= bottomTolerance - thresholdHysteresis {
            return .atBottom
        }
        if distance > bottomTolerance + thresholdHysteresis {
            return .awayFromBottom
        }
        return .thresholdBand
    }
}
