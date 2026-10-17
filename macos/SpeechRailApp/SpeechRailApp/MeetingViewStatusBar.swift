import SwiftUI

/// Only this small status subtree subscribes to metering and the session clock.
struct MeetingActivityStatusBar<Trailing: View>: View {
    let meeting: MeetingSession
    let session: SessionCoordinator
    let title: String
    let tone: StatusTone
    let facts: [String]
    @ViewBuilder let trailing: () -> Trailing
    var body: some View {
        SessionStatusBar(title: title, tone: tone, facts: facts,
            elapsed: meeting.phase.isLive || meeting.phase == .processing ? session.elapsed : nil,
            level: meeting.phase.isLive ? meeting.level : nil, trailing: trailing)
            .accessibilityHint(SessionActivityPolicy.levelDescription(meeting.level, active: meeting.phase.isLive))
    }
}

// `MeetingView` 的状态带：相位标题、语气、来源与六条轴的事实行（MA-10 / MA-21）。
// 纯搬移自主文件；跨文件共用的是主文件里的 `@State` 与 `body` 调用的入口。

extension MeetingView {
    // MARK: - 状态带

    private var pageStatusPresentation: SessionPageStatusPresentation {
        return switch meeting.phase {
        case .idle:
            SessionPageStatusPresentation(
                title: statusTitle,
                tone: statusTone,
                facts: statusFacts
            )
        case .preparing:
            SessionPageStatusPresentation(
                title: statusTitle,
                tone: statusTone,
                facts: statusFacts
            )
        case .recording:
            SessionPageStatusPresentation(
                title: statusTitle,
                tone: statusTone,
                facts: statusFacts
            )
        case .interrupted:
            SessionPageStatusPresentation(
                title: statusTitle,
                tone: statusTone,
                facts: statusFacts
            )
        case .processing:
            SessionPageStatusPresentation(
                title: statusTitle,
                tone: statusTone,
                facts: statusFacts
            )
        case .archived:
            SessionPageStatusPresentation(
                title: statusTitle,
                tone: statusTone,
                facts: statusFacts
            )
        }
    }

    var statusBar: some View {
        MeetingActivityStatusBar(
            meeting: meeting, session: session,
            title: pageStatusPresentation.title,
            tone: pageStatusPresentation.tone,
            facts: pageStatusPresentation.facts
        ) {
            if meeting.phase.isLive {
                Button(meeting.isPaused ? "继续录制" : "暂停录制") {
                    Task { await meeting.togglePause() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("只是暂时不把声音送进去；会话、文字记录都在，麦克风也还归这一场")
                .accessibilityLabel(meeting.isPaused ? "继续录制会议" : "暂停录制会议")
                .accessibilityValue(meeting.isPaused ? "已暂停" : "正在录制")
            }
        }
    }

    private var statusTitle: String {
        switch meeting.phase {
        case .idle:
            return meeting.blocked != nil ? "这一场没有开始" : "还没有开始会议"
        case .preparing: return "正在准备…"
        // 暂停与静音**不是**同一件事：暂停是整条上行都停（含本机音频），静音只关掉麦克风
        // 那一路。两句都成立时先说更强的那一句——"已暂停"已经蕴含"你这边的声音进不去"。
        case .recording:
            if meeting.isPaused { return "已暂停" }
            return meeting.isMicrophoneMuted ? "正在录音 · 麦克风已静音" : "正在录音"
        case .interrupted: return "录制中断"
        case .processing: return meeting.minutes.isBusy ? "正在整理会议…" : "会议收尾未完成"
        case .archived: return "这一场已经结束"
        }
    }

    private var statusTone: StatusTone {
        switch meeting.phase {
        case .idle: meeting.blocked != nil ? .attention : .neutral
        case .preparing: .attention
        case .recording: meeting.isPaused ? .attention : .healthy
        case .interrupted: .attention
        case .processing: .attention
        case .archived: .healthy
        }
    }

    /// MA-10 的呈现门面。把采集状态翻译成用户语言的那一层集中在这里，
    /// 界面不自己拼"现在到底在录什么"。
    private var sourcePresentation: MeetingSourcePresentation {
        MeetingSourcePresentation(
            capture: sourceCapture,
            selection: MeetingSourcePresentation.Selection(
                usesMicrophone: meeting.selection?.usesMicrophone ?? true,
                systemAppNames: meeting.selection?.systemApps.map(\.name) ?? []
            ),
            // 采集层没有独立的"识别已连上"标志。可得的诚实信号是**流有没有断**：
            // `interruption` 非空就说明上行中断过。这一近似会在采集层补上
            // 显式标志之后换掉——现在不拿它冒充"识别正常"。
            isRecognizing: meeting.interruption == nil,
            savedLineCount: meeting.storedLineCount
        )
    }

    /// 六条轴的统一投影（MA-21）。就绪/采集/识别/保存/索引/审阅分别说话。
    private var axisProjection: MeetingAxisProjection {
        let live = meeting.phase.isLive || meeting.phase == .interrupted
        return MeetingAxisProjection(
            readiness: meeting.blocked.map { .failed($0.title) } ?? (live ? .ready : .idle),
            capture: live ? axis(for: sourceCapture) : .idle,
            // 采集层没有独立的"识别已连上"标志；这里用**上行有没有断过**近似，
            // 采集层补上显式标志之后要换掉。
            recognition: live
                ? (meeting.interruption == nil ? .active : .failed("上行中断过"))
                : .idle,
            persistence: meeting.storedLineCount > 0 ? .ready : (live ? .active : .idle),
            // 保存与索引分开报（§6.5）：存下了不等于搜得到。
            index: meeting.gapCount > 0 ? .degraded("补过 \(meeting.gapCount) 处静音") : .ready,
            // 审阅轴之前恒为 .idle，等于界面明明有待复核的结论却什么都不说。
            review: MeetingAxisProjection.reviewState(verdicts: reviewVerdicts)
        )
    }

    private func axis(for capture: MeetingSourcePresentation.Capture) -> MeetingAxisProjection.State {
        switch capture {
        case .notStarted: .idle
        case .pausedAll: .paused
        case .microphoneMuted: .active
        case .live: .active
        }
    }

    private var sourceCapture: MeetingSourcePresentation.Capture {
        guard meeting.phase.isLive || meeting.phase == .interrupted else { return .notStarted }
        if meeting.isPaused { return .pausedAll }
        if meeting.isMicrophoneMuted { return .microphoneMuted }
        return .live
    }

    private var statusFacts: [String] {
        guard meeting.phase != .idle else {
            return meeting.selection.map { [$0.label] } ?? []
        }
        var facts: [String] = []
        // 来源摘要走 MA-10 的呈现门面
        if meeting.selection != nil { facts.append(sourcePresentation.sourceSummary) }
        if !meeting.labeling.labels.isEmpty {
            facts.append("\(meeting.labeling.labels.count) 位发言人")
        }
        facts.append("\(meeting.storedLineCount) 段对话已记录")
        if meeting.gapCount > 0 { facts.append("\(meeting.gapCount) 处补过静音") }
        if meeting.isMicrophoneMuted, meeting.isPaused { facts.append("麦克风已静音") }
        if meeting.reconnectedSources > 0 {
            facts.append("接回过 \(meeting.reconnectedSources) 次")
        }
        // 渐进式披露：仅当某条轴存在故障或降级时才在主状态带呈现警示，常态不无谓堆砌「正常」技术日志
        for problem in axisProjection.problems {
            switch problem.state {
            case .degraded(let reason):
                facts.append("\(problem.name)降级（\(reason)）")
            case .failed(let reason):
                facts.append("\(problem.name)异常（\(reason)）")
            default:
                break
            }
        }
        return facts
    }
}
