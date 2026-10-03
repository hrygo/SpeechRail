import SpeechRailControlKit

/// 用户距离"第一条真实结果"还差什么。
///
/// 这是一份**只读投影**：它只读 App 已经知道的事实，不安装、不下载、不改配置，
/// 也不把"还没读到"说成"已经就绪"。`/readyz=200` 出现在这里也不会让任何一步
/// 变成已满足——真实结果是用户按下生成后听到的音频，不是任何一个探针。
public struct FirstResultReadiness: Equatable, Sendable {
    public enum Step: String, CaseIterable, Identifiable, Sendable {
        case serviceReachable
        case profileSelected
        case modelsReady
        case voiceAvailable

        public var id: String { rawValue }
    }

    /// 一个还没满足的步骤，以及用户现在能做的那一个动作。
    public struct StepStatus: Identifiable, Equatable, Sendable {
        public let step: Step
        /// 面向用户的一句话说清"缺什么"。
        public let detail: String
        /// `false` 表示这一项还没有结论（还没读到状态），不是失败。
        public let isKnown: Bool

        public var id: String { step.id }
    }

    public let steps: [StepStatus]

    public init(steps: [StepStatus]) {
        self.steps = steps
    }

    /// 没有任何未满足步骤时，用户已经具备拿到第一条真实结果的条件。
    public var isReady: Bool {
        steps.isEmpty
    }

    /// 还没读到结论的步骤排在最后：先说确定的缺口，不拿未知充数。
    public var blockingSteps: [StepStatus] {
        steps.filter(\.isKnown)
    }

    public var unknownSteps: [StepStatus] {
        steps.filter { !$0.isKnown }
    }

    /// 有确定缺口时才值得让用户去做点什么。
    ///
    /// 全部步骤都还没有结论时，卡片只能渲染出一个空壳：有标题、有分隔线、
    /// 没有任何一行。这条判据让「该不该显示」变成可测试的判断，而不是藏在
    /// 视图里的一个条件。
    public var hasActionableSteps: Bool {
        !blockingSteps.isEmpty
    }

    public static let ready = FirstResultReadiness(steps: [])
}

public enum FirstResultReadinessBuilder {
    /// 把 App 当前持有的事实投影成一张"还差什么"的清单。
    ///
    /// 每一步只有在**正面证据**存在时才算满足。探针成功不等于可用：模型要真的
    /// ready，音色要真的能用于配音，服务要真的读到过状态。
    public static func evaluate(
        hasHealth: Bool,
        healthFailure: ServiceHealthFailureKind?,
        hasProfile: Bool,
        modelAvailability: ModelAvailabilityState,
        modelStatusMessage: String?,
        voices: [CreatorVoice],
        voicesLoadState: CreatorVoicesLoadState,
        discoveryState: CapabilityDiscoveryState
    ) -> FirstResultReadiness {
        var steps: [FirstResultReadiness.StepStatus] = []

        if healthFailure != nil {
            steps.append(
                .init(
                    step: .serviceReachable,
                    detail: "连不上本机服务，先在「引擎」里确认它正在运行。",
                    isKnown: true
                )
            )
        } else if !hasHealth {
            steps.append(
                .init(
                    step: .serviceReachable,
                    detail: "还没有读到服务状态，稍等片刻或手动刷新一次。",
                    isKnown: false
                )
            )
        }

        if !hasProfile {
            steps.append(
                .init(
                    step: .profileSelected,
                    detail: "还没有选择运行档位，先在「引擎」里选一个档位。",
                    isKnown: true
                )
            )
        }

        switch modelAvailability {
        case .available:
            break
        case .failed:
            steps.append(
                .init(
                    step: .modelsReady,
                    detail: modelStatusMessage ?? "模型准备失败，请在「引擎」里查看原因并重试。",
                    isKnown: true
                )
            )
        case .unsupported:
            steps.append(
                .init(
                    step: .modelsReady,
                    detail: "当前机器不支持这个档位，换一个档位或换一台机器。",
                    isKnown: true
                )
            )
        case .notReady:
            steps.append(
                .init(
                    step: .modelsReady,
                    detail: modelStatusMessage ?? "模型还没准备好，请在「引擎」里开始准备。",
                    isKnown: true
                )
            )
        case .unknown:
            steps.append(
                .init(
                    step: .modelsReady,
                    detail: "还不确定模型是否可用，先在「引擎」里查看。",
                    isKnown: false
                )
            )
        }

        if voices.contains(where: \.available) {
            // 已经能用配音音色：这一步没有缺口。
        } else {
            switch voicesLoadState {
            case .failed:
                steps.append(
                    .init(
                        step: .voiceAvailable,
                        detail: "音色列表读取失败，请刷新后重试。",
                        isKnown: true
                    )
                )
            case .loaded where discoveryState != .loaded:
                steps.append(
                    .init(
                        step: .voiceAvailable,
                        detail: "还没有确认当前音色能力，先在「引擎」里刷新能力快照。",
                        isKnown: false
                    )
                )
            case .unknown, .loading:
                // 列表还没读到：这不是「没有音色」，是「还不知道有没有」。
                steps.append(
                    .init(
                        step: .voiceAvailable,
                        detail: "还在读取音色列表，稍等片刻或到「引擎」里手动刷新一次。",
                        isKnown: false
                    )
                )
            default:
                steps.append(
                    .init(
                        step: .voiceAvailable,
                        detail: "还没有可用于配音的音色，先在「音色库」里准备一个。",
                        isKnown: true
                    )
                )
            }
        }

        return FirstResultReadiness(steps: steps)
    }
}
