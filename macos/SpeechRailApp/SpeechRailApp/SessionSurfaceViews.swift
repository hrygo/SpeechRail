import AppKit
import SwiftUI

// 会话三页共用的外壳与组件（UX-UI-SPEC §4.1、SESSIONS-SPEC §6.7）。
//
// 这一个文件里放三样东西，都是「三页共用一份实现」的：
//   1. `SessionEmptyState`——空态的唯一形状（图标 28 + `Heading / Section` + 正文 ≤ 容器内宽）；
//   2. `SessionStatusBar`——会话状态带（状态点 + 阶段文字 + 可选的真实电平 + 等宽计时 + 事实条 + 动作）；
//   3. `SessionOwnershipRow`——侧边栏第二行「谁在用麦克风」。
//
// **本批没有的东西（不要在这里补一个假的）**：三条能力各自的正文面（对话流 / 转录流 / 字幕带）
// 与「开始对话 / 开始会议 / 打开字幕带」三个主按钮，随各自的能力阶段落地（§12 阶段 3/5/6）。
// 主按钮在这里缺席是**有意的**：采集还没接上，放一个按了不动的按钮比暂不提供更糟。

// MARK: - 空态

/// Shared status summary rendered by the session surfaces.
///
/// Each page renders its real controls in its own view hierarchy; the audit matrix
/// records the primary, secondary, and recovery actions without duplicating their
/// labels in this status-only value.
public struct SessionPageStatusPresentation: Equatable, Sendable {
    public let title: String
    public let tone: StatusTone
    public let facts: [String]

    public init(
        title: String,
        tone: StatusTone,
        facts: [String] = []
    ) {
        self.title = title
        self.tone = tone
        self.facts = facts
    }
}

/// 三页共用的空态。形状与 §12 第 5 项一致：图标 28、标题 `Heading / Section`、
/// 正文折行宽不超过容器内宽（页面级下限 460），一组动作排在下面。
public struct SessionEmptyState<Actions: View>: View {
    public let systemImage: String
    public let title: String
    public let message: String
    private let actions: Actions

    public init(
        systemImage: String,
        title: String,
        message: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            Image(systemName: systemImage)
                .font(SpeechRailDesignTokens.Typography.sessionEmptyIcon)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                .accessibilityHidden(true)

            Text(title)
                .font(SpeechRailDesignTokens.Typography.sectionTitle)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .multilineTextAlignment(.center)

            Text(message)
                .font(SpeechRailDesignTokens.Typography.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .multilineTextAlignment(.center)
                // 上限 460 是稿的页面级空态口径；放进分栏时由外层容器再收窄，不超这个数。
                .frame(maxWidth: SpeechRailDesignTokens.Layout.sessionEmptyBodyMaximumWidth)

            actions
                .padding(.top, SpeechRailDesignTokens.Spacing.tight)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xl)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - 会话状态带

/// 会话状态带。三页首屏与会议 live 带共用这一份实现：`MetricStrip` 是纯读数、
/// `StatusPill` 是单个胶囊，拼出来的话三页会各拼一套（正是 Sona 的 S4 代价）。
public struct SessionStatusBar<Trailing: View>: View {
    public let title: String
    public let tone: StatusTone
    public let facts: [String]
    public let elapsed: TimeInterval?
    /// 真实电平（0…1）。**没接上采集时传 `nil`**——那时不画波形，
    /// 而不是画一根动的假波形（§6.1：电平来自麦克风的 `averagePower`）。
    public let level: Double?
    private let trailing: Trailing

    public init(
        title: String,
        tone: StatusTone,
        facts: [String] = [],
        elapsed: TimeInterval? = nil,
        level: Double? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.tone = tone
        self.facts = facts
        self.elapsed = elapsed
        self.level = level
        self.trailing = trailing()
    }

    public var body: some View {
        CardSurface {
            let dotSize = SpeechRailDesignTokens.Icon.statusDotSize
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                Circle()
                    .fill(tone.color)
                    .frame(width: dotSize, height: dotSize)
                    .accessibilityHidden(true)

                Text(title)
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(1)

                if let level {
                    LevelMeterBar(level: level)
                }

                if let elapsed {
                    Text(SessionCoordinator.formatted(elapsed))
                        .font(SpeechRailDesignTokens.Typography.technicalValue)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .accessibilityLabel("已进行 \(SessionCoordinator.formatted(elapsed))")
                }

                if !facts.isEmpty {
                    Text(facts.joined(separator: " · "))
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                trailing
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts = [tone.accessibilityLabel]
        parts.append(contentsOf: facts)
        if let elapsed {
            parts.append("已进行 \(SessionCoordinator.formatted(elapsed))")
        }
        return parts.joined(separator: "，")
    }
}

public extension SessionStatusBar where Trailing == EmptyView {
    init(
        title: String,
        tone: StatusTone,
        facts: [String] = [],
        elapsed: TimeInterval? = nil,
        level: Double? = nil
    ) {
        self.init(
            title: title,
            tone: tone,
            facts: facts,
            elapsed: elapsed,
            level: level,
            trailing: { EmptyView() }
        )
    }
}

/// 电平条。只有拿到真实电平才画（`SessionStatusBar` 保证这一点）。
struct LevelMeterBar: View {
    let level: Double

    var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.tight) {
            ForEach(0..<12, id: \.self) { index in
                let threshold = Double(index + 1) / 12
                Capsule()
                    .fill(
                        level >= threshold
                            ? SpeechRailDesignTokens.Color.rail
                            : SpeechRailDesignTokens.Color.inkTertiary.opacity(0.25)
                    )
                    .frame(width: SpeechRailDesignTokens.Layout.captionBandLevelBarWidth, height: 4 + CGFloat(index) * 0.6)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 侧边栏第二行

/// 侧边栏第二行：谁在用麦克风（P1 的落点，也是与 Sona S1/S2 的分界）。
/// 与服务状态同行形：语义图标 + 一行状态 + 行尾状态点。
public struct SessionOwnershipRow: View {
    @Environment(SessionCoordinator.self) private var session
    @Environment(AppNavigationState.self) private var navigation

    public init() {}

    public var body: some View {
        Button {
            navigation.request(session.ownershipRoute)
        } label: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Image(systemName: "mic")
                    .font(SpeechRailDesignTokens.Typography.navigationIcon)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .frame(
                        width: SpeechRailDesignTokens.Icon.navigationFrame,
                        height: SpeechRailDesignTokens.Icon.navigationFrame
                    )
                    .accessibilityHidden(true)

                Text(session.ownershipText)
                    .font(.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .monospacedDigit()
                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                Circle()
                    .fill(tone.color)
                    .frame(
                        width: SpeechRailDesignTokens.Control.sidebarStatusDotSize,
                        height: SpeechRailDesignTokens.Control.sidebarStatusDotSize
                    )
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SpeechRailDesignTokens.List.rowHorizontalPadding)
            .padding(.vertical, SpeechRailDesignTokens.List.rowVerticalPadding)
        }
        .speechRailInteractiveButtonStyle(
            fillsAvailableWidth: true,
            minimumHeight: SpeechRailDesignTokens.List.sidebarRowHeight
        )
        .help(session.isIdle ? "麦克风空闲；打开实时字幕" : "\(session.ownershipText)；打开正在进行的会话")
        .accessibilityLabel("麦克风")
        .accessibilityValue(session.ownershipText)
    }

    private var tone: StatusTone {
        guard session.occupancy != nil else { return .neutral }
        if session.phase == .interrupted { return .critical }
        // 稿把「正在收声」画成 attention 点（`sessionDot(live, "attention")`），
        // 与「空闲」的 neutral 只差颜色，不差形状。
        return .attention
    }
}

// MARK: - 记录库页面（三个能力共用一份实现）

/// 记录库页面。三个能力的记录住在同一个本机库里、长得一样，所以**这一份实现服务三页**：
/// 差别只有 `kind` 与几处文案（UX-UI-SPEC §4.1 的 `recordListColumn` 同一判断）。
///
/// 它今天就能真跑：列表、选中、搜索、复制、移除都不依赖麦克风与模型
/// （`IMPLEMENTATION-READINESS.md` §12 阶段 2：记录库不依赖麦克风）。
public struct SessionLibraryView: View {
    public let kind: SessionKind

    @Environment(AppModel.self) private var model
    @Environment(SessionCoordinator.self) private var session
    @Environment(CaptionSession.self) private var caption
    @Environment(SessionPreferences.self) private var preferences
    @Environment(\.openSettings) private var openSettings
    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var summaries: [SessionSummary] = []
    @State private var selectedID: String?
    private typealias LibraryDetail = (review: SessionReviewSnapshot, recoveryLines: [TranscriptLine])
    @State private var detail: LibraryDetail?
    @State private var detailLoad = SpeechRailSelectionLoad<LibraryDetail>()
    private var lines: [TranscriptLine] { detail?.review.lines ?? [] }
    private var displayLines: [TranscriptLine] { SessionExporter.paragraphLines(lines) }
    private var recoveryLines: [TranscriptLine] { detail?.recoveryLines ?? [] }
    private var speakerNames: [String: String] { detail?.review.speakerNames ?? [:] }
    @State private var libraryDisplayMode: CaptionDisplayMode = .bilingual
    @State private var searchText = ""
    @State private var recordFilter: RecordListFilter = .all
    @State private var detailSearchText = ""
    @State private var selectedSpeakerFilter: String?
    @State private var editingSpeakerLabel: String?
    @State private var speakerRenameDraft = ""
    @State private var renamingRecordID: String?
    @State private var recordRenameDraft = ""
    @State private var showsLiveSpeakerSheet = false
    @State private var manualSpeakerModeRecordIDs: Set<String> = []
    /// 全文检索命中（MC-49/MC-52/MC-54）：转录终稿与已完成纪要正文。
    /// 为空表示未检索或无命中；与标题过滤互斥，检索优先。
    @State private var knowledgeHits: [SessionStore.KnowledgeHit] = []
    @State private var knowledgeError: String?
    @State private var loadFailure: String?
    @State private var operationError: String?
    @State private var recoveryFeedback: OperationFeedback?
    @State private var operationNotice: String?
    @State private var pendingRemoval: SessionSummary?
    @State private var isShowingDataDirectoryHint = false
    /// 前置检查态那一栏「本次字幕」收起了没有（与语音助手、会议页同一套规矩）。
    @State private var isInspectorCollapsed = false
    @FocusState private var inspectorToggleFocused: Bool
    @State private var autoCollapsedDueToWidth = false
    /// 字幕空态里「遇到问题怎么办」那一行可选项（2026-09-19 低门槛改造）。
    @State private var showsBlockedHelp = false
    /// 想打开翻译但还没配模型：不把开关拨过去，而是明确告诉用户缺什么、去哪配。
    @State private var showsTranslationSetupHint = false

    private enum RecordListFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case multiSpeaker = "多人"
        case active = "进行中"

        var id: String { rawValue }
    }

    public init(kind: SessionKind) {
        self.kind = kind
    }

    public var body: some View {
        // 字幕库固定在窗口视口内；记录清单由 List 自己滚动，选中记录正文由详情面板滚动。
        PageScaffold(
            route: kind.route,
            layout: .fill(minimumHeight: 420)
        ) {
            VStack(spacing: SpeechRailDesignTokens.Spacing.gutter) {
                SessionStatusBar(
                    title: pageStatusPresentation.title,
                    tone: pageStatusPresentation.tone,
                    facts: pageStatusPresentation.facts,
                    elapsed: session.occupancy == nil ? nil : session.elapsed
                )
                if kind == .captions, !caption.saveRecoveryRecords.isEmpty {
                    TranscriptSaveRecoveryPanel(
                        records: caption.saveRecoveryRecords,
                        preview: { caption.unsavedTranscriptText(recordID: $0) },
                        retry: { await caption.retryPendingSaves(recordID: $0) },
                        finishIncomplete: { await caption.endIncompleteRecord($0) },
                        onFeedback: { recoveryFeedback = $0 }
                    )
                }
                if kind == .captions, let failure = caption.completionFailure {
                    StatusBanner(
                        kind: .standard,
                        tone: .attention,
                        title: "字幕收尾尚未确认",
                        message: failure.message.contains("正在收尾")
                            ? "会话已关闭，已录制的字幕已完整保存在本机记录中。"
                            : failure.message,
                        actionTitle: "完成记录",
                        action: {
                            Task {
                                await caption.finishIncompleteCapture()
                                await reload()
                            }
                        }
                    )
                    .help("结束确认阶段：\(failure.stage.rawValue)"
                        + (caption.completionDiagnosticCode.map { "；诊断代码：\($0)" } ?? ""))
                    .accessibilityIdentifier("caption-completion-failure")
                }

                if loadFailure != nil {
                    StatusBanner(
                        kind: .standard,
                        tone: .critical,
                        title: "记录库不可用",
                        message: "暂时无法读取记录，请重试。",
                        actionTitle: "重试",
                        action: { Task { await reload() } }
                    )
                }

                if summaries.isEmpty {
                    emptyState
                } else {
                    if kind == .captions {
                        captionQuickControlBar
                    }
                    library
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } trailing: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                if kind == .captions {
                    // 页头主动作放在最左侧，采用 prominent 强调色与按压回弹触感，一眼可定位。
                    // 未开始时叫「开始字幕」（与下方「开始之前」卡片文案保持一致），进行或暂停时叫「显示字幕带」。
                    PageActionButton(
                        title: caption.phase.isLive ? "显示字幕带" : "开始字幕",
                        systemImage: caption.phase.isLive ? "captions.bubble.fill" : "captions.bubble",
                        variant: .prominent,
                        helpText: caption.phase == .running
                            ? "把字幕带重新显示到屏幕上；它一直在后台实时收音识别（快捷键 ⌘⇧L）"
                            : (caption.phase == .paused
                                ? "重新显示字幕带并可继续录制（快捷键 ⌘⇧L）"
                                : "选择目标应用窗口或麦克风开始实时字幕（快捷键 ⌘⇧L）")
                    ) {
                        Task {
                            if caption.phase.isLive {
                                await caption.openBand()
                            } else {
                                await caption.promptSelectTarget()
                            }
                        }
                    }
                    if caption.phase == .paused {
                        PageActionButton(
                            title: "新开字幕",
                            systemImage: "plus.circle",
                            helpText: "结束当前暂停的会话，重新选择窗口或麦克风开始新的实时字幕"
                        ) {
                            Task {
                                await caption.finish()
                                await caption.promptSelectTarget()
                            }
                        }
                    }
                    // 稿 `screenClosureCaptionsIdle` 的页头快捷键提示：只在空态展示。
                    if summaries.isEmpty {
                        SessionHeaderKeycap("⌘⇧L")
                    }
                }
                exportMenu
                if kind == .captions, summaries.isEmpty {
                    SessionPanelToggle(
                        panelName: "本次字幕",
                        isCollapsed: isInspectorCollapsed
                    ) {
                        setInspectorCollapsed(!isInspectorCollapsed, autoCollapsed: false)
                    }
                    .focused($inspectorToggleFocused)
                }
            }
        }
        .onChange(of: navigation.layoutTier, initial: true) { _, _ in
            syncInspectorWithLayoutContract(navigation.layoutContract)
        }
        .onChange(of: caption.sessionID) { _, newSessionID in
            guard kind == .captions else { return }
            Task {
                await reload()
                if let newSessionID {
                    selectedID = newSessionID
                }
            }
        }
        .onChange(of: caption.phase) { _, _ in
            guard kind == .captions else { return }
            Task { await reload() }
        }
        .onChange(of: caption.persistedTranscriptRevision) { _, _ in
            guard kind == .captions, let activeID = caption.sessionID, selectedID == activeID else { return }
            Task { await loadLines() }
        }
        .onChange(of: caption.labeling.attributionRevision) { _, _ in
            guard kind == .captions, let activeID = caption.sessionID, selectedID == activeID else { return }
            Task { await loadLines() }
        }
        .task(id: refreshToken) { await reload() }
        .task(id: selectedID) { await loadLines() }
        .confirmationDialog(
            "移除这条记录？",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { summary in
            Button("移除记录", role: .destructive) {
                Task { await remove(summary) }
            }
            Button("取消", role: .cancel) {
                pendingRemoval = nil
            }
        } message: { summary in
            Text(removalMessage(for: summary))
        }
        .alert("翻译模型还没配置", isPresented: $showsTranslationSetupHint) {
            Button("去设置") { openSettings() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("在「设置 → 助手 → 实时字幕翻译」里填好地址和模型，再回来打开这个开关。")
        }
        .operationFeedback([
            recoveryFeedback,
            OperationFeedback(operationError, onDismiss: { operationError = nil }),
            OperationFeedback(loadFailure, title: "记录库未读取"),
            OperationFeedback(detailLoad.failure, title: "记录未打开"),
            OperationFeedback(knowledgeError.map { "全文检索没能完成：\($0)" }, title: "检索未完成",
                              onDismiss: { knowledgeError = nil }),
            OperationFeedback(kind == .captions ? caption.exportFailure : nil, title: "字幕未导出", onDismiss: { caption.clearExportFailure() }),
            OperationFeedback(operationNotice, tone: .healthy, title: "已完成", autoDismiss: true,
                              onDismiss: { operationNotice = nil })
        ])
    }

    private var refreshToken: String {
        "\(kind.rawValue)|\(model.health?.ready == true)"
    }

    private func syncInspectorWithLayoutContract(_ contract: WindowLayoutContract) {
        guard kind == .captions else { return }
        guard contract.inspector == .collapsed else {
            if isInspectorCollapsed && autoCollapsedDueToWidth {
                setInspectorCollapsed(false, autoCollapsed: false)
            }
            return
        }

        if !isInspectorCollapsed {
            setInspectorCollapsed(true, autoCollapsed: true)
        }
    }

    private func setInspectorCollapsed(_ collapsed: Bool, autoCollapsed: Bool) {
        let update = {
            isInspectorCollapsed = collapsed
            autoCollapsedDueToWidth = autoCollapsed
            inspectorToggleFocused = true
        }

        if reduceMotion {
            update()
        } else {
            withAnimation(SpeechRailDesignTokens.Motion.interactiveSpring, update)
        }
    }

    private var pageStatusPresentation: SessionPageStatusPresentation {
        guard kind == .captions else {
            return SessionPageStatusPresentation(
                title: session.ownershipText,
                tone: session.isIdle ? .neutral : .attention,
                facts: statusFacts
            )
        }

        return switch caption.phase {
        case .idle:
            SessionPageStatusPresentation(
                title: caption.blocked?.title ?? (summaries.isEmpty ? "还没有开始字幕" : "字幕服务就绪 · 可按 ⌘⇧L 随时开启"),
                tone: caption.blocked == nil ? .neutral : .attention,
                facts: statusFacts
            )
        case .preparing:
            SessionPageStatusPresentation(
                title: "正在准备字幕",
                tone: .attention,
                facts: statusFacts
            )
        case .running:
            SessionPageStatusPresentation(
                title: "正在实时字幕",
                tone: .healthy,
                facts: statusFacts
            )
        case .paused:
            SessionPageStatusPresentation(
                title: "字幕已暂停",
                tone: .attention,
                facts: statusFacts
            )
        case .ending:
            SessionPageStatusPresentation(
                title: "正在保存字幕",
                tone: .attention,
                facts: statusFacts
            )
        }
    }

    private var statusFacts: [String] {
        var facts = [kind.title]
        if let selection = model.health?.selection {
            facts.append(SpeechRailProfilePresentation.shortTitle(selection))
        }
        return facts
    }

    // MARK: - 导出（§6.2 第三条判断：走系统保存面板，不画伪保存）

    /// 页头的导出动作。四种格式收进一个菜单而不是排成四颗按钮——页头是低频动作的地方，
    /// 四种格式不值得占四个槽位。默认格式排第一：会议是 Markdown、字幕是 SRT、助手是纯文本。
    private var exportMenu: some View {
        PageActionsMenu(
            title: "导出",
            systemImage: "square.and.arrow.down",
            helpText: selectedSummary == nil
                ? "先在左边的记录列表里选一条，再导出"
                : "把选中的记录导出成文件"
        ) {
            ForEach(orderedFormats) { format in
                Button(format.title) {
                    guard let summary = selectedSummary else { return }
                    export(summary, as: format)
                }
            }
        }
        .disabled(selectedSummary == nil)
    }

    private var orderedFormats: [SessionExportFormat] {
        let preferred = SessionExportFormat.preferred(for: kind)
        return [preferred] + SessionExportFormat.allCases.filter { $0 != preferred }
    }

    /// 导出**重新从库里读一遍**，不拿界面上正在显示的那一份：列表里选中的是这一条，
    /// 但导出物该是库里的定稿内容（`includePartial == false`），两者不该因为一次选中而耦合。
    private func export(_ summary: SessionSummary, as format: SessionExportFormat) {
        Task {
            do {
                let payload = try await exportPayload(for: summary)
                try SessionExportPanel.write(payload, as: format)
            } catch {
                operationError = "导出失败：\(error.localizedDescription)"
            }
        }
    }

    private func exportPayload(for summary: SessionSummary) async throws -> SessionExportPayload {
        let rows = try await session.lines(sessionID: summary.id)
        let names = try await session.speakerNames(sessionID: summary.id)
        // MC-25：导出当前展示版（采用版优先）；最新尝试失败时不让纪要章节凭空消失。
        // 无可用版时为 nil，导出物只出转录。
        let minutes = try await session.currentMinutes(sessionID: summary.id)
        return SessionExportPayload(
            record: summary.record,
            lines: rows,
            speakerNames: names,
            minutes: minutes,
            captionDisplayMode: caption.effectiveDisplayMode
        )
    }

    @ViewBuilder
    private var emptyState: some View {
        if kind == .captions {
            AnyView(captionsIdleState)
        } else {
            AnyView(genericEmptyState)
        }
    }

    /// 实时字幕的翻译开关。**默认关**：没配模型时不允许拨到「开」，否则用户会得到
    /// 一个打开了却永远没有译文的开关。
    private var translationBinding: Binding<Bool> {
        Binding(
            get: { caption.translationEnabled },
            set: { enabled in
                if enabled {
                    guard caption.isTranslationAvailable else {
                        showsTranslationSetupHint = true
                        return
                    }
                    if caption.displayMode == .originalOnly {
                        caption.displayMode = .bilingual
                    }
                }
                caption.translationEnabled = enabled
            }
        )
    }

    private var captionSilenceBinding: Binding<Int> {
        Binding(
            get: { caption.captionSilenceDurationMilliseconds },
            set: { caption.captionSilenceDurationMilliseconds = $0 }
        )
    }

    private var paragraphAssemblyBinding: Binding<Bool> {
        Binding(
            get: { caption.paragraphAssemblyEnabled },
            set: { caption.paragraphAssemblyEnabled = $0 }
        )
    }

    private var diarizationBinding: Binding<Bool> {
        Binding(
            get: { preferences.captionsDiarizationEnabled },
            set: { enabled in
                preferences.captionsDiarizationEnabled = enabled
                if !enabled {
                    if recordFilter == .multiSpeaker && !summaries.contains(where: { $0.speakerCount > 1 }) {
                        recordFilter = .all
                    }
                    if let summary = selectedSummary, !isSpeakerAttributionActive(for: summary) {
                        selectedSpeakerFilter = nil
                        editingSpeakerLabel = nil
                    }
                }
                caption.notifyDiarizationPreferenceChanged()
            }
        )
    }

    private var translationSetupDetail: String {
        if !caption.isTranslationAvailable {
            return "还没有配置翻译模型。先在「字幕设置 → 助手 → 实时字幕翻译」里填好地址和模型。"
        }
        if caption.translationEnabled {
            return caption.displayMode == .chineseOnly
                ? "已开启，只看中文：外语会实时翻成中文，中文内容不调用模型。"
                : "已开启，双语对照：外语会实时翻成中文，原文留在下一行。"
        }
        return "默认关闭，只显示原文字幕。打开后外语会实时翻成中文，中文内容不调用模型。"
    }

    private var translationInspectorValue: String {
        guard caption.translationEnabled else { return "关闭（只看原文）" }
        guard caption.isTranslationAvailable else { return "已开启 · 未配置模型" }
        return caption.displayMode == .chineseOnly ? "已开启 · 仅中文" : "已开启 · 双语对照"
    }

    /// 历史记录库顶部的实时字幕快捷控制台：有历史记录后依然能随时切换目标音源、原音语种、同传翻译、断句灵敏度与暂停/结束状态。
    private var captionQuickControlBar: some View {
        CardSurface {
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                // 1. 收音目标快速切换
                Button {
                    Task { await caption.promptSelectTarget() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: caption.audioTarget?.isApp == true ? "macwindow" : "mic.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                        Text(caption.audioTarget?.displayTitle ?? "选择收音窗口 / 麦克风")
                            .font(SpeechRailDesignTokens.Typography.callout)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(SpeechRailDesignTokens.Color.rail.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(SpeechRailDesignTokens.Color.rail.opacity(0.22), lineWidth: 0.75)
                    )
                }
                .buttonStyle(.plain)
                .help("点击切换实时字幕采集的目标应用窗口或麦克风")
                .speechRailPointerCursor()

                Divider().frame(height: 16)

                // 2. 原音语种选择
                HStack(spacing: 4) {
                    Text("原音")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    Picker("原音语种", selection: Binding(
                        get: { caption.sourceLanguage },
                        set: { caption.sourceLanguage = $0 }
                    )) {
                        ForEach(CaptionSourceLanguage.allCases) { lang in
                            Text(lang == .chinese ? "中文（不翻译）" : lang.title).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                }
                .help("选择视频或音频的源语言；切换后立即同步给语音识别与同传翻译")

                // 3. 同传翻译与双语排版
                HStack(spacing: 6) {
                    Toggle("同传翻译", isOn: translationBinding)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(SpeechRailDesignTokens.Typography.caption)
                    if caption.translationEnabled {
                        Picker("排版", selection: Binding(
                            get: { caption.displayMode },
                            set: { caption.displayMode = $0 }
                        )) {
                            Text("双语对照").tag(CaptionDisplayMode.bilingual)
                            Text("仅中文").tag(CaptionDisplayMode.chineseOnly)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .frame(width: 120)
                    }
                }
                .help(translationSetupDetail)

                Divider().frame(height: 16)

                // 4. 断句灵敏度与段落合并
                HStack(spacing: 6) {
                    Picker("断句", selection: captionSilenceBinding) {
                        Text("断句 400ms").tag(400)
                        Text("断句 650ms").tag(650)
                        Text("断句 900ms").tag(900)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                    .help("调整句末静音切分窗口：400ms 出字更快，900ms 断句更完整")

                    Toggle("段落合并", isOn: paragraphAssemblyBinding)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .help("把同一句话被切成的多行自动合并为完整段落并整段精翻")

                    Toggle("区分说话人", isOn: diarizationBinding)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .help("开启说话人分离（谁在说话）；运行中切换会自动重连并启用分人标记")
                }

                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)

                if caption.phase.isLive, preferences.captionsDiarizationEnabled || !caption.labeling.labels.isEmpty {
                    Button {
                        showsLiveSpeakerSheet = true
                    } label: {
                        Label("标注说话人", systemImage: "person.crop.rectangle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("实时改名、合并或标记当前字幕会话中的说话人")
                }

                // 5. 运行态快捷控制（暂停/继续、结束）
                if caption.phase.isLive {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Button {
                            Task {
                                if caption.phase == .running {
                                    await caption.pause()
                                } else {
                                    await caption.resume()
                                }
                            }
                        } label: {
                            Label(
                                caption.phase == .running ? "暂停" : "继续",
                                systemImage: caption.phase == .running ? "pause.fill" : "play.fill"
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(caption.phase == .running ? "暂停实时字幕（⌘⇧L）" : "继续实时字幕（⌘⇧L）")

                        Button(role: .destructive) {
                            Task {
                                await caption.finish()
                                await reload()
                            }
                        } label: {
                            Label("结束保存", systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("结束当前实时字幕并归档保存到下方记录列表")
                    }
                }
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        }
    }

    /// 实时字幕的空态（稿 ``实时字幕 · 记录库 · 未开始（前置检查）`）。
    ///
    /// 字幕这条闭环的入口不在主窗口里（⌘⇧L 或菜单栏），所以这一屏要把「开始之前要满足
    /// 什么、三种受阻各给哪个出口」一次说清——起点没画清，后面全是悬空的。
    private var captionsIdleState: some View {
        VStack(spacing: SpeechRailDesignTokens.Spacing.gutter) {
            SessionConclusionBand(
                tone: .healthy,
                title: "现在就可以开始字幕",
                message: "精准抓取目标视频窗口声音或麦克风，实时显示原文字幕；需要时在字幕带或下面打开翻译，就能看双语对照或仅中文。开始后字幕带智能吸附于窗口底部或自由悬浮。",
                hint: "⌘⇧L 可随时开启、暂停或继续；点击字幕带的 ✕ 结束并保存。"
            ) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    Button(caption.audioTarget == nil ? "选择窗口并开启字幕" : "开启字幕") {
                        Task {
                            if caption.audioTarget == nil {
                                await caption.promptSelectTarget()
                            } else {
                                await caption.openBand()
                            }
                        }
                    }
                    .speechRailButton(.primary)

                    if caption.audioTarget != nil {
                        Button("重新选择目标…") {
                            Task { await caption.promptSelectTarget() }
                        }
                        .speechRailButton(.secondary)
                    }

                    Button("字幕设置") { openSettings() }
                        .speechRailButton(.secondary)
                }
            }

            HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.md) {
                SessionPanel {
                    SessionPanelHead(
                        title: "开始之前",
                        detail: "前两件是必须的；翻译和「谁在说话」都是可选项，开始后也能改。"
                    )
                    SessionHairline()
                    SessionCheckRow(tone: microphoneTone, name: "麦克风", detail: microphoneDetail)
                    SessionHairline()
                    SessionCheckRow(tone: serviceTone, name: "语音服务", detail: serviceDetail)
                    SessionHairline()
                    SessionCheckRow(
                        tone: caption.translationEnabled && caption.isTranslationAvailable ? .ready : .neutral,
                        name: "翻译成中文 · 可选",
                        detail: translationSetupDetail
                    ) {
                        Toggle("", isOn: translationBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .accessibilityLabel("翻译成中文")
                            .accessibilityIdentifier("caption-translation-toggle")
                    }
                    SessionHairline()
                    SessionCheckRow(
                        tone: .neutral,
                        name: "断句灵敏度 · 可选",
                        detail: "650ms 平衡完整与速度；400ms 更快但更碎；900ms 更接近会议整句。"
                    ) {
                        Picker("", selection: captionSilenceBinding) {
                            Text("更快 400ms").tag(400)
                            Text("平衡 650ms").tag(650)
                            Text("更完整 900ms").tag(900)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .accessibilityLabel("字幕断句灵敏度")
                        .accessibilityIdentifier("caption-silence-picker")
                    }
                    SessionHairline()
                    SessionCheckRow(
                        tone: caption.paragraphAssemblyEnabled ? .ready : .neutral,
                        name: "段落合并 · 可选",
                        detail: "把同一句被 ASR 切开的几行合成一段显示和翻译；关掉后逐句显示，便于对照。"
                    ) {
                        Toggle("", isOn: paragraphAssemblyBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .accessibilityLabel("段落合并")
                            .accessibilityIdentifier("caption-paragraph-toggle")
                    }
                    SessionHairline()
                    SessionCheckRow(
                        tone: preferences.captionsDiarizationEnabled ? .ready : .neutral,
                        name: "谁在说话（区分说话人） · 可选",
                        detail: preferences.captionsDiarizationEnabled
                            ? "已开启：自动区分不同发言人（A / B / C…），在工作台中可随时按人筛选或点击标记姓名。"
                            : "默认关闭（保障最低识别与同传延迟）。打开后自动区分发言人并在工作台开启按人标记；标不出时正文照常记录。"
                    ) {
                        Toggle("", isOn: diarizationBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .accessibilityLabel("谁在说话（区分说话人）")
                            .accessibilityIdentifier("caption-diarization-toggle")
                    }
                    Spacer(minLength: 0)
                    SessionHairline()
                    CardFoot(
                        note: "字幕带按目标应用定向采集音频；说话人区分等工作台设置仅在此工作台内集中配置。"
                            + "记录库空着的时候，这里只有「开始字幕」。"
                    ) { EmptyView() }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                // 「非主框体都能收起」这条规矩在这一屏也要成立（用户 2026-09-18），
                // 稿 `screenClosureCaptionsIdle` 的页头末件就是 `sideToggle(row, "本次字幕")`。
                if !isInspectorCollapsed {
                    SessionPanel {
                        SessionPanelHead(title: "本次字幕", badge: "还没有开始")
                        SessionHairline()
                        VStack(alignment: .leading, spacing: 10) {
                            SessionKVRow("收音目标", caption.audioTarget?.displayTitle ?? "按窗口选择 / 麦克风")
                            SessionKVRow("源语言", caption.sourceLanguage.title)
                            SessionKVRow("翻译", translationInspectorValue)
                            SessionKVRow("说话人区分", preferences.captionsDiarizationEnabled ? "已开启（可标记姓名）" : "关闭")
                            SessionKVRow("字幕带位置", caption.placementMode == .dockedToTargetWindow ? "吸附目标窗口" : "自由悬停")
                            SessionKVRow("识别精度", profileRowText)
                            SessionKVRow("默认字号", "标准")
                            SessionKVRow("保存位置", "记录库 · 长期保留")
                            SessionKVRow("最近一条记录", lastRecordText)
                        }
                        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                        .padding(.vertical, SpeechRailDesignTokens.Spacing.md)
                        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Text("「识别精度」是什么意思")
                                .font(SpeechRailDesignTokens.Typography.captionMedium)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            Text(
                                "\(profileRowText) 是这台 Mac 现在的识别精度：越高，认字越准，"
                                    + "也越能标出谁在说话。换精度在设置里，已经存下的记录不跟着变。"
                            )
                            .font(SpeechRailDesignTokens.Typography.secondary)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                        .padding(.bottom, SpeechRailDesignTokens.Spacing.md)
                        Spacer(minLength: 0)
                    }
                    .frame(width: SpeechRailDesignTokens.Layout.sessionInspectorWidth)
                }
            }

            // 「受阻时」是**查表**，不是首屏要做的事：一切正常的人一辈子用不上它。
            // 2026-09-19 用户反馈「门槛极高」之后折成一行可选项——首页只留
            // 「结论条 + 开始之前（三行前置检查）+ 本次字幕右栏」。
            DisclosureGroup(isExpanded: $showsBlockedHelp) {
                SessionPanel {
                    SessionPanelHead(
                        title: "受阻时",
                        detail: nil,
                        trailingDetail: "三种受阻共用同一个形状：说明影响 + 唯一出口；不弹对话框。"
                    )
                    SessionHairline()
                SessionCheckRow(
                        // 这张卡是**查表**，不是实时体检——上面的「开始之前」才是看现在状态的。
                        // 三行都用 attention 的感叹号（与稿一致），别在「麦克风未授权」旁边
                        // 画一个绿勾：那时这一行说的是"遇到这种情况怎么办"，不是"你没问题"。
                        tone: .attention,
                        name: "麦克风未授权",
                        detail: "系统设置里给过权限才能采音。拒绝一次不会反复弹窗。"
                    ) {
                        Button("打开系统设置") { openMicrophoneSettings() }
                            .speechRailButton(.secondary)
                    }
                    SessionHairline()
                    SessionCheckRow(
                        tone: .attention,
                        name: "语音服务未就绪",
                        detail: "识别服务没起来时，字幕带换成同一条受阻带并保留最后一句。"
                    ) {
                        // 稿这里写的是 `[去服务状态]`；实现给 `[重试]`——服务还没起来时重试会
                        // 原样再报一次，出口在这一屏够用（SESSIONS-SPEC §12.1.2 第 3 条未决项）。
                        Button("重试") { Task { await caption.retry() } }
                            .speechRailButton(.secondary)
                    }
                    SessionHairline()
                    SessionCheckRow(
                        tone: .attention,
                        name: "麦克风被占用",
                        detail: "同一时刻只有一个会话能用麦克风；交还要确认，不会静默抢。"
                    ) {
                        Button("结束会话并切换") { Task { await caption.takeOverOccupiedMicrophone() } }
                            .speechRailButton(.secondary)
                    }
                }
            } label: {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Text("遇到问题怎么办（可选）")
                        .font(SpeechRailDesignTokens.Typography.bodyMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    Text("麦克风没授权 / 服务没起来 / 麦克风被占用")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    Spacer(minLength: 0)
                }
            }
            .disclosureGroupStyle(SpeechRailDisclosureGroupStyle())
        }
    }

    private var genericEmptyState: some View {
        SessionEmptyState(
            systemImage: kind.systemImage,
            title: emptyTitle,
            message: emptyMessage
        ) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Button("打开数据目录") {
                    NSWorkspace.shared.activateFileViewerSelecting([session.libraryURL])
                }
                .buttonStyle(.bordered)

                Button("重新读取") {
                    Task { await reload() }
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .speechRailSurface(.panel)
        .clipShape(SpeechRailDesignTokens.Corner.containerShape)
    }

    private var emptyTitle: String {
        switch kind {
        case .assistant: "还没有对话记录"
        case .meeting: "还没有会议记录"
        case .captions: "还没有字幕记录"
        case .teleprompter: "提词稿不进入语音记录库"
        }
    }

    // MARK: 前置检查的读数（只读系统与服务的现状，不猜）

    private var microphoneAuthorized: Bool {
        MicrophoneCapture.authorizationStatus() == .authorized
    }

    private var microphoneTone: SessionRowTone {
        microphoneAuthorized ? .ready : .attention
    }

    private var microphoneDetail: String {
        switch MicrophoneCapture.authorizationStatus() {
        case .authorized: "已经给过权限，开始就能采音。"
        case .notDetermined: "第一次开始时会请求授权；拒绝后这一行会变成受阻态并给出出口。"
        default: "系统里没给麦克风权限：识别拿不到声音，先去设置里打开。"
        }
    }

    private var serviceTone: SessionRowTone {
        model.health?.ready == true ? .ready : .attention
    }

    private var serviceDetail: String {
        model.health?.ready == true
            ? "识别在本机跑，服务已就绪。"
            : "识别在本机跑；服务未就绪时字幕带会换成同一条受阻带。"
    }

    private var profileRowText: String {
        guard let selection = model.health?.selection else { return SpeechRailDisplayFormat.MissingValue.notLoaded.text }
        return SpeechRailProfilePresentation.shortTitle(selection.asrSpec)
    }

    private var lastRecordText: String {
        guard let latest = summaries.first else { return "还没有记录" }
        let when = latest.record.startedAt.speechRailFormatted()
        return "\(when) · \(latest.lineCount) 行"
    }

    private func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private var emptyMessage: String {
        switch kind {
        case .assistant:
            "开始对话之后，你说过的话和助手的回答会留在这里，可以回看、搜索、复制。原始音频不留存。"
        case .meeting:
            "开始会议之后，文字记录会边听边出现；结束后可以生成纪要、改说话人的名字，并导出 Markdown 或 SRT。原始音频不留存。"
        case .captions:
            "字幕带打开之后，看过的字幕会留在这里，可以回看、搜索和导出 SRT。原始音频不留存。"
        case .teleprompter:
            "提词器只保存稿件版本和最后位置，不保存原始音频或语音记录。"
        }
    }

    private var library: some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.gutter) {
            recordList
                .frame(maxHeight: .infinity, alignment: .top)
            if let selected = selectedSummary {
                recordDetail(selected)
            } else {
                SessionEmptyState(
                    systemImage: kind.systemImage,
                    title: "选一条记录",
                    message: "左边选一条记录，这里显示它的正文与信息。"
                ) { EmptyView() }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .speechRailSurface(.panel)
                .clipShape(SpeechRailDesignTokens.Corner.containerShape)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var recordList: some View {
        CardSurface {
            VStack(spacing: 0) {
                // 1. 紧凑单行栏头：标题 + 同行计数胶囊 + 可选筛选胶囊（消除「记录」与「13」上下两行堆叠割裂感）
                HStack(alignment: .center, spacing: 6) {
                    Text("记录")
                        .font(SpeechRailDesignTokens.Typography.bodyMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)

                    Text(
                        filteredSummaries.count == summaries.count
                            ? "\(summaries.count)"
                            : "\(filteredSummaries.count)/\(summaries.count)"
                    )
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .monospacedDigit()
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(
                        Capsule()
                            .fill(SpeechRailDesignTokens.Color.recessedField)
                    )

                    Spacer(minLength: 4)

                    if availableRecordListFilters.count > 1 {
                        HStack(spacing: 2) {
                            ForEach(availableRecordListFilters) { filter in
                                let isSelected = recordFilter == filter
                                Button {
                                    recordFilter = filter
                                } label: {
                                    Text(filter.rawValue)
                                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                        .foregroundStyle(
                                            isSelected
                                                ? SpeechRailDesignTokens.Color.rail
                                                : SpeechRailDesignTokens.Color.inkTertiary
                                        )
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            Capsule()
                                                .fill(
                                                    isSelected
                                                        ? SpeechRailDesignTokens.Color.rail.opacity(0.14)
                                                        : Color.clear
                                                )
                                        )
                                }
                                .buttonStyle(.plain)
                                .speechRailPointerCursor()
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

                // 2. 一体化轻量侧边栏搜索框（与下方列表卡片左右边缘严格对齐，内置回车全文检索提示）
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(
                            searchText.isEmpty
                                ? SpeechRailDesignTokens.Color.inkTertiary
                                : SpeechRailDesignTokens.Color.rail
                        )

                    TextField("搜索记录…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(SpeechRailDesignTokens.Typography.callout)
                        .onSubmit {
                            Task { await runKnowledgeSearch() }
                        }

                    if !knowledgeHits.isEmpty {
                        Text("\(knowledgeHits.count)条")
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(SpeechRailDesignTokens.Color.rail.opacity(0.12), in: Capsule())
                    } else if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("↵全文")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                            .help("按回车键检索正文全文")
                    }

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            knowledgeHits = []
                            knowledgeError = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        }
                        .buttonStyle(.plain)
                        .help("清空搜索")
                        .speechRailPointerCursor()
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(SpeechRailDesignTokens.Color.recessedField)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            searchText.isEmpty
                                ? SpeechRailDesignTokens.Surface.border
                                : SpeechRailDesignTokens.Color.rail.opacity(0.35),
                            lineWidth: 0.75
                        )
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

                SessionHairline()

                List(selection: $selectedID) {
                    ForEach(filteredSummaries) { summary in
                        recordRow(summary)
                            .tag(summary.id)
                            .listRowBackground(
                                summary.id == selectedID
                                    ? SpeechRailDesignTokens.Surface.selectionTint
                                    : Color.clear
                            )
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6))
                            .contextMenu {
                                Button("重命名记录…") {
                                    selectedID = summary.id
                                    renamingRecordID = summary.id
                                    recordRenameDraft = summary.record.title ?? displayTitle(for: summary)
                                }
                                Divider()
                                Menu("导出") {
                                    ForEach(orderedFormats) { format in
                                        Button(format.title) {
                                            export(summary, as: format)
                                        }
                                    }
                                }
                                Button("复制全文") {
                                    Task { await copyTranscript(of: summary) }
                                }
                                Divider()
                                Button("移除记录…", role: .destructive) {
                                    pendingRemoval = summary
                                }
                            }
                    }
                }
                .speechRailSelectableList()
                .scrollContentBackground(.hidden)
                .frame(maxHeight: .infinity)
            }
        }
        .frame(width: SpeechRailDesignTokens.Layout.sessionListWidth)
    }

    private func recordRow(_ summary: SessionSummary) -> some View {
        let isAppAudio = (summary.record.targetAppName?.isEmpty == false) || summary.record.audioSource == .system
        let isLiveRecording = summary.record.state == .recording
        let isSelected = summary.id == selectedID
        return HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isLiveRecording || isSelected
                            ? SpeechRailDesignTokens.Color.rail.opacity(0.14)
                            : SpeechRailDesignTokens.Color.recessedField
                    )
                    .frame(width: 24, height: 24)
                Image(systemName: isAppAudio ? "macwindow" : "mic.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(
                        isLiveRecording || isSelected
                            ? SpeechRailDesignTokens.Color.rail
                            : SpeechRailDesignTokens.Color.inkSecondary
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Text(displayTitle(for: summary))
                        .font(SpeechRailDesignTokens.Typography.calloutMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                        .lineLimit(1)
                    if let reason = summary.openInterruption {
                        StatusPill(tone: .critical, label: reason.title)
                    }
                    Spacer(minLength: SpeechRailDesignTokens.Spacing.micro)
                    if summary.record.state == .recording {
                        StatusPill(tone: .attention, label: "录制中")
                    } else if summary.record.state == .processing {
                        StatusPill(tone: .attention, label: "整理中")
                    }
                }
                Text(
                    recordSubtitle(
                        summary,
                        includeSpeakerCount: isSpeakerAttributionActive(for: summary)
                    )
                )
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .monospacedDigit()
                .lineLimit(1)
            }

            InPlaceDeleteButton(
                style: .compactIcon,
                title: "移除记录"
            ) {
                Task { await remove(summary) }
            }
        }
        .padding(.vertical, 2)
        .speechRailSelectableRow()
    }

    private func recordDetail(_ summary: SessionSummary) -> some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    if renamingRecordID == summary.id {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            TextField("输入记录标题…", text: $recordRenameDraft)
                                .textFieldStyle(.plain)
                                .speechRailSingleLineInput(.compact)
                                .frame(width: 220)
                                .onSubmit {
                                    Task { await saveRecordTitle(for: summary) }
                                }
                            Button("保存") {
                                Task { await saveRecordTitle(for: summary) }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            Button("取消") {
                                renamingRecordID = nil
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(displayTitle(for: summary))
                                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                                    .lineLimit(1)
                                Button {
                                    renamingRecordID = summary.id
                                    recordRenameDraft = summary.record.title ?? displayTitle(for: summary)
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 11))
                                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                                }
                                .buttonStyle(.plain)
                                .help("重命名此条记录")
                                .speechRailPointerCursor()
                            }
                            Text(
                                recordSubtitle(
                                    summary,
                                    includeSpeakerCount: isSpeakerAttributionActive(for: summary)
                                )
                            )
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            .monospacedDigit()
                            .lineLimit(1)
                        }
                    }
                    Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                    if kind == .captions {
                        Picker("显示模式", selection: $libraryDisplayMode) {
                            Text("双语对照").tag(CaptionDisplayMode.bilingual)
                            Text("仅译文").tag(CaptionDisplayMode.chineseOnly)
                            Text("仅原文").tag(CaptionDisplayMode.originalOnly)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 210)
                        .controlSize(.small)
                        .speechRailPointerCursor()
                    }
                    Button {
                        Task { await copyTranscript(of: summary) }
                    } label: {
                        Label("复制全文", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    if summary.record.state != .archived {
                        Button("完成记录") {
                            Task {
                                _ = await session.sealSessionReporting(id: summary.record.id, reason: .interrupted)
                                if caption.sessionID == summary.record.id {
                                    await caption.finish()
                                }
                                await reload()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .help("当前记录未确认正常归档，点击完成封存")
                    }
                    InPlaceDeleteButton(
                        style: .regularButton,
                        title: "移除记录",
                        systemImage: "trash",
                        confirmText: "确认移除",
                        cancelText: "取消"
                    ) {
                        Task { await remove(summary) }
                    }
                }
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)

                Divider()

                if !displayLines.isEmpty {
                    detailSpeakerAndFilterBar(for: summary)
                    Divider()
                }

                if detailLoad.isLoading {
                    ProgressView("正在打开记录…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if detailLoad.failure != nil {
                    ContentUnavailableView {
                        Label("记录暂时没能打开", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("暂时无法读取这条记录，请重试。")
                    } actions: {
                        Button("重试") { Task { await loadLines() } }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if lines.isEmpty && recoveryLines.isEmpty {
                    Text("这条记录里还没有正文。")
                        .font(SpeechRailDesignTokens.Typography.callout)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else if filteredDisplayLines.isEmpty {
                    VStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Text("没有匹配的段落")
                            .font(SpeechRailDesignTokens.Typography.bodyMedium)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                        Button("重置筛选条件") {
                            detailSearchText = ""
                            selectedSpeakerFilter = nil
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                            ForEach(filteredDisplayLines) { line in
                                lineRow(line, summary: summary)
                            }
                            if !recoveryLines.isEmpty {
                                TranscriptRecoveryMaterialSection(lines: recoveryLines)
                            }
                        }
                        .padding(SpeechRailDesignTokens.Spacing.md)
                    }
                }

                Divider()

                Text(
                    isSpeakerAttributionActive(for: summary)
                        ? "记录只保存在这台 Mac 上；点击任意段落左侧说话人标签即可标记姓名或调整归属。"
                        : "记录只保存在这台 Mac 上。"
                )
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                    .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showsLiveSpeakerSheet) {
            SpeakerLabelingSheet(
                labeling: caption.labeling,
                sessionID: caption.sessionID ?? selectedID,
                transcriptRevision: UInt64(lines.count),
                onClose: {
                    showsLiveSpeakerSheet = false
                    Task { await loadLines() }
                }
            )
        }
    }

    /// 当前记录是否启用或包含说话人区分（决定是否展示说话人胶囊、左列占位与标注菜单）。
    /// 注意：历史存量记录的说话人区分状态只取决于该场记录本身的数据（自身是否开启或存在说话人/手动标注），
    /// 顶部快捷控制台的全局开关仅作用于正在进行或新开启的实时字幕会话，不应回溯污染历史存量记录。
    private func isSpeakerAttributionActive(for summary: SessionSummary) -> Bool {
        if kind == .meeting { return true }
        if manualSpeakerModeRecordIDs.contains(summary.id) { return true }
        if summary.record.diarization == .active || summary.speakerCount > 0 { return true }
        // 正在进行的当前实时字幕会话：跟随实时字幕会话的开关偏好
        if kind == .captions, let activeID = caption.sessionID, summary.id == activeID {
            return preferences.captionsDiarizationEnabled || !sessionSpeakerLabels.isEmpty
        }
        return !sessionSpeakerLabels.isEmpty
    }

    private var availableRecordListFilters: [RecordListFilter] {
        let showMultiSpeaker = kind == .meeting
            || summaries.contains(where: { $0.speakerCount > 1 })
            || recordFilter == .multiSpeaker
        let showActive = summaries.contains(where: { $0.record.state == .recording || $0.record.state == .processing })
            || recordFilter == .active
        return RecordListFilter.allCases.filter { filter in
            switch filter {
            case .all: return true
            case .multiSpeaker: return showMultiSpeaker
            case .active: return showActive
            }
        }
    }

    /// 详情页顶部说话人管理/标注栏与段内搜索过滤栏（根据是否开启分人自适应呈现）。
    @ViewBuilder
    private func detailSpeakerAndFilterBar(for summary: SessionSummary) -> some View {
        let speakerActive = isSpeakerAttributionActive(for: summary)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                if speakerActive {
                    // 1a. 开启分人或存在说话人时：说话人筛选与一键改名胶囊
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            Button {
                                selectedSpeakerFilter = nil
                            } label: {
                                Text("全部 (\(displayLines.count))")
                                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                                    .foregroundStyle(
                                        selectedSpeakerFilter == nil
                                            ? SpeechRailDesignTokens.Color.rail
                                            : SpeechRailDesignTokens.Color.inkSecondary
                                    )
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule()
                                            .fill(
                                                selectedSpeakerFilter == nil
                                                    ? SpeechRailDesignTokens.Color.rail.opacity(0.14)
                                                    : Color.primary.opacity(0.05)
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                            .speechRailPointerCursor()

                            ForEach(sessionSpeakerLabels, id: \.self) { label in
                                let isSelected = selectedSpeakerFilter == label
                                let name = speakerDisplayName(for: label)
                                let count = displayLines.filter { $0.speakerLabel == label }.count
                                HStack(spacing: 3) {
                                    Button {
                                        selectedSpeakerFilter = isSelected ? nil : label
                                    } label: {
                                        HStack(spacing: 3) {
                                            Image(systemName: "person.fill")
                                                .font(.system(size: 9))
                                            Text("\(name) (\(count))")
                                                .font(SpeechRailDesignTokens.Typography.captionMedium)
                                        }
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        editingSpeakerLabel = label
                                        speakerRenameDraft = speakerNames[label] ?? ""
                                    } label: {
                                        Image(systemName: "pencil")
                                            .font(.system(size: 9, weight: .semibold))
                                    }
                                    .buttonStyle(.plain)
                                    .help("重命名「\(name)」")
                                }
                                .foregroundStyle(
                                    isSelected
                                        ? SpeechRailDesignTokens.Color.rail
                                        : SpeechRailDesignTokens.Color.ink
                                )
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(
                                            isSelected
                                                ? SpeechRailDesignTokens.Color.rail.opacity(0.16)
                                                : Color.primary.opacity(0.05)
                                        )
                                )
                                .speechRailPointerCursor()
                            }
                        }
                    }
                } else {
                    // 1b. 未开启分人（纯享字幕态）：默认仅展示干净的段落计数，并提供按需手动标人入口
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Text("共 \(displayLines.count) 段")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        Button {
                            manualSpeakerModeRecordIDs.insert(summary.id)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "person.badge.plus")
                                    .font(.system(size: 10))
                                Text("手动标人")
                                    .font(SpeechRailDesignTokens.Typography.caption)
                            }
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.04), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("本场未开启自动说话人区分；点击可展开说话人列进行事后手动标记")
                        .speechRailPointerCursor()
                    }
                }

                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)

                // 2. 段内关键词过滤框
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    TextField(speakerActive ? "筛选本场正文或说话人…" : "筛选本场正文…", text: $detailSearchText)
                        .textFieldStyle(.plain)
                        .frame(width: 160)
                    if !detailSearchText.isEmpty {
                        Button {
                            detailSearchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .speechRailSingleLineInput(.compact)
            }

            // 内联说话人重命名编辑器（含常用身份一键预设）
            if let editingLabel = editingSpeakerLabel {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Text("标注「\(speakerDisplayName(for: editingLabel))」为：")
                        .font(SpeechRailDesignTokens.Typography.captionMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    TextField("输入姓名或称呼（如：张总、主持人）", text: $speakerRenameDraft)
                        .textFieldStyle(.plain)
                        .speechRailSingleLineInput(.compact)
                        .frame(width: 190)
                        .onSubmit {
                            Task { await commitSpeakerRename(sessionID: summary.id, label: editingLabel, name: speakerRenameDraft) }
                        }
                    ForEach(["我", "主持人", "主讲人", "嘉宾"], id: \.self) { preset in
                        Button(preset) {
                            Task { await commitSpeakerRename(sessionID: summary.id, label: editingLabel, name: preset) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .speechRailPointerCursor()
                    }
                    Button("保存") {
                        Task { await commitSpeakerRename(sessionID: summary.id, label: editingLabel, name: speakerRenameDraft) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button("取消") {
                        editingSpeakerLabel = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, 8)
        .background(SpeechRailDesignTokens.Color.recessedField.opacity(0.45))
    }

    private func lineRow(_ line: TranscriptLine, summary: SessionSummary) -> some View {
        let speakerActive = isSpeakerAttributionActive(for: summary)
        return HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.xs) {
            if speakerActive {
                speakerMenuBadge(for: line, summary: summary)
                    .frame(width: SpeechRailDesignTokens.Layout.sessionSpeakerColumnWidth, alignment: .leading)
            }

            Text(Self.timecode(line.tStart))
                .font(SpeechRailDesignTokens.Typography.technical)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                .frame(width: SpeechRailDesignTokens.Layout.sessionTimecodeColumnWidth, alignment: .leading)

            lineContent(line)
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)
        .contextMenu {
            Button(kind == .captions ? "复制此段" : "复制此句") {
                copySingleLine(line)
            }
            let source = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = line.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let translation, hasDistinctMeaningfulTranslation(source: source, translation: translation) {
                Button("复制双语对照") {
                    copyBilingualLine(source: source, translation: translation)
                }
            }
            if speakerActive {
                Divider()
                Menu("标记此段说话人") {
                    speakerAssignmentMenuItems(for: line, summary: summary)
                }
                if let label = line.speakerLabel, !label.isEmpty {
                    Button("重命名「\(speakerDisplayName(for: label))」…") {
                        editingSpeakerLabel = label
                        speakerRenameDraft = speakerNames[label] ?? ""
                    }
                }
            }
        }
    }

    /// 行首可交互说话人胶囊：支持直接点击切换本段归属或重命名该说话人。
    private func speakerMenuBadge(for line: TranscriptLine, summary: SessionSummary) -> some View {
        let hasLabel = (line.speakerLabel?.isEmpty == false)
        return Menu {
            Section("将此段归属给") {
                speakerAssignmentMenuItems(for: line, summary: summary)
            }
            if let label = line.speakerLabel, !label.isEmpty {
                Divider()
                Section("全局修改「\(speakerDisplayName(for: label))」称呼") {
                    ForEach(["我", "主持人", "主讲人", "嘉宾"], id: \.self) { preset in
                        Button("改名为「\(preset)」") {
                            Task { await commitSpeakerRename(sessionID: summary.id, label: label, name: preset) }
                        }
                    }
                    Button("自定义姓名…") {
                        editingSpeakerLabel = label
                        speakerRenameDraft = speakerNames[label] ?? ""
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(speakerText(for: line))
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(
                        hasLabel
                            ? SpeechRailDesignTokens.Color.rail
                            : SpeechRailDesignTokens.Color.inkSecondary
                    )
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(
                        hasLabel
                            ? SpeechRailDesignTokens.Color.rail.opacity(0.11)
                            : Color.primary.opacity(0.04)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("点击标记此段说话人或修改说话人姓名")
        .speechRailPointerCursor()
    }

    @ViewBuilder
    private func speakerAssignmentMenuItems(for line: TranscriptLine, summary: SessionSummary) -> some View {
        let candidateLabels = Array(Set(sessionSpeakerLabels + ["A", "B", "C", "D"])).sorted()
        ForEach(candidateLabels, id: \.self) { label in
            let display = speakerDisplayName(for: label)
            Button {
                Task { await assignParagraphSpeaker(for: line, to: label, sessionID: summary.id) }
            } label: {
                if line.speakerLabel == label {
                    Label(display, systemImage: "checkmark")
                } else {
                    Text(display)
                }
            }
        }
        Divider()
        ForEach(["我", "主持人", "主讲人", "嘉宾"], id: \.self) { preset in
            Button("直接标为「\(preset)」") {
                Task { await assignAndRenameSpeaker(for: line, presetName: preset, sessionID: summary.id) }
            }
        }
    }

    @ViewBuilder
    private func lineContent(_ line: TranscriptLine) -> some View {
        let source = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = line.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTranslation = hasDistinctMeaningfulTranslation(source: source, translation: translation)

        switch (kind == .captions ? libraryDisplayMode : .bilingual) {
        case .originalOnly:
            Text(source)
                .font(SpeechRailDesignTokens.Typography.body)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .chineseOnly:
            let textToShow = (hasTranslation ? translation : nil) ?? source
            Text(textToShow)
                .font(SpeechRailDesignTokens.Typography.body)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .bilingual:
            if hasTranslation, let translation {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Text(translation)
                        .font(SpeechRailDesignTokens.Typography.body)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(source)
                        .font(SpeechRailDesignTokens.Typography.callout)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(source)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func hasDistinctMeaningfulTranslation(source: String, translation: String?) -> Bool {
        guard let translation, !translation.isEmpty, translation != source else {
            return false
        }
        if isPredominantlyChinese(source) && isPredominantlyChinese(translation) {
            let sNormalized = normalizedText(source)
            let tNormalized = normalizedText(translation)
            if sNormalized == tNormalized { return false }
            let sSet = Set(sNormalized)
            let tSet = Set(tNormalized)
            let overlap = sSet.intersection(tSet).count
            let union = sSet.union(tSet).count
            if union > 0 && Double(overlap) / Double(union) > 0.85 {
                return false
            }
        }
        return true
    }

    private func isPredominantlyChinese(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let cjkCount = text.unicodeScalars.filter {
            (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value)
        }.count
        return Double(cjkCount) / Double(text.count) >= 0.3
    }

    private func normalizedText(_ text: String) -> String {
        text.filter { $0.isLetter || $0.isNumber }
    }

    private func copySingleLine(_ line: TranscriptLine) {
        let source = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = line.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTranslation = hasDistinctMeaningfulTranslation(source: source, translation: translation)
        let textToCopy: String
        switch (kind == .captions ? libraryDisplayMode : .bilingual) {
        case .originalOnly:
            textToCopy = source
        case .chineseOnly:
            textToCopy = (hasTranslation ? translation : nil) ?? source
        case .bilingual:
            if hasTranslation, let translation {
                textToCopy = "\(translation) (\(source))"
            } else {
                textToCopy = source
            }
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(textToCopy, forType: .string)
        operationNotice = "已复制该句文字。"
    }

    private func copyBilingualLine(source: String, translation: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("\(translation)\n\(source)", forType: .string)
        operationNotice = "已复制双语对照。"
    }

    private func speakerText(for line: TranscriptLine) -> String {
        // 显式 `return`：`.speaker` 那一支里有两个语句，整个 switch 因此不是表达式，
        // 不能靠隐式返回（上一版就是这么编译失败的）。
        switch line.role {
        case .user: return "你"
        case .assistant: return "助手"
        case .speaker:
            guard let label = line.speakerLabel, !label.isEmpty else { return "未标" }
            return speakerDisplayName(for: label)
        }
    }

    /// 当前选中记录中出现过的全部说话人标签（按首次出现顺序）。
    private var sessionSpeakerLabels: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for line in displayLines {
            if let label = line.speakerLabel, !label.isEmpty, seen.insert(label).inserted {
                result.append(label)
            }
        }
        for key in speakerNames.keys.sorted() where !key.isEmpty && seen.insert(key).inserted {
            result.append(key)
        }
        return result
    }

    private func speakerDisplayName(for label: String) -> String {
        if let name = speakerNames[label]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return SpeakerLabeling.chipText(label: label, displayName: nil)
    }

    /// 按详情页顶部的说话人胶囊与段内搜索词过滤后的展示行。
    private var filteredDisplayLines: [TranscriptLine] {
        let keyword = detailSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let speakerFilterActive = selectedSummary.map { isSpeakerAttributionActive(for: $0) } ?? false
        return displayLines.filter { line in
            if speakerFilterActive, let filterLabel = selectedSpeakerFilter, line.speakerLabel != filterLabel {
                return false
            }
            guard !keyword.isEmpty else { return true }
            let speakerMatch = speakerFilterActive && speakerText(for: line).localizedCaseInsensitiveContains(keyword)
            let sourceMatch = line.text.localizedCaseInsensitiveContains(keyword)
            let translationMatch = line.translatedText?.localizedCaseInsensitiveContains(keyword) ?? false
            return speakerMatch || sourceMatch || translationMatch
        }
    }

    /// 保存说话人改名（同时更新持久化记录与当前正在运行的字幕会话账本）。
    private func commitSpeakerRename(sessionID: String, label: String, name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            editingSpeakerLabel = nil
            return
        }
        do {
            try await session.renameSpeaker(sessionID: sessionID, label: label, name: trimmed)
            if caption.sessionID == sessionID {
                await caption.labeling.rename(label: label, to: trimmed)
            }
            editingSpeakerLabel = nil
            operationNotice = "已将「说话人 \(label)」标记为「\(trimmed)」。"
            await reload()
        } catch {
            operationError = "说话人改名失败：\(error.localizedDescription)"
        }
    }

    /// 找出当前展示段落在底层 `lines` 中对应的连续同说话人行 ID（若同 `paragraphID` 已因换人拆成多段，只命中当前展示段所属的连续子组）。
    private func paragraphMemberLineIDs(for displayLine: TranscriptLine) -> [String] {
        guard let paragraphID = displayLine.paragraphID, !paragraphID.isEmpty,
              let startIdx = lines.firstIndex(where: { $0.id == displayLine.id }) else {
            return [displayLine.id]
        }
        var memberIDs: [String] = [displayLine.id]
        var groupSpeaker = lines[startIdx].speakerLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        var idx = startIdx + 1
        while idx < lines.count, lines[idx].paragraphID == paragraphID {
            let nextSpeaker = lines[idx].speakerLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasConflict = (groupSpeaker?.isEmpty == false)
                && (nextSpeaker?.isEmpty == false)
                && groupSpeaker != nextSpeaker
            if hasConflict { break }
            if (groupSpeaker?.isEmpty != false), let nextSpeaker, !nextSpeaker.isEmpty {
                groupSpeaker = nextSpeaker
            }
            memberIDs.append(lines[idx].id)
            idx += 1
        }
        return memberIDs
    }

    /// 将某一段落（含该展示段合并的底层正式行）归属给指定说话人标签。
    private func assignParagraphSpeaker(for line: TranscriptLine, to label: String, sessionID: String) async {
        let targetLineIDs = paragraphMemberLineIDs(for: line)
        do {
            for id in targetLineIDs {
                _ = try await session.attachSpeakerLabel(lineID: id, label: label)
            }
            if caption.sessionID == sessionID {
                await caption.labeling.split(lineIDs: targetLineIDs, to: label)
            }
            operationNotice = "已将该段标记为「\(speakerDisplayName(for: label))」。"
            await reload()
        } catch {
            operationError = "标记说话人失败：\(error.localizedDescription)"
        }
    }

    /// 一键将该段归属并直接命名为指定身份（如「我」「主持人」「主讲人」「嘉宾」）。
    private func assignAndRenameSpeaker(for line: TranscriptLine, presetName: String, sessionID: String) async {
        let existingLabel = speakerNames.first(where: { $0.value == presetName })?.key
        let targetLabel = existingLabel ?? line.speakerLabel ?? nextUnusedSpeakerLabel()
        let targetLineIDs = paragraphMemberLineIDs(for: line)
        do {
            for id in targetLineIDs {
                _ = try await session.attachSpeakerLabel(lineID: id, label: targetLabel)
            }
            if caption.sessionID == sessionID {
                await caption.labeling.split(lineIDs: targetLineIDs, to: targetLabel)
            }
            if speakerNames[targetLabel] != presetName {
                try await session.renameSpeaker(sessionID: sessionID, label: targetLabel, name: presetName)
                if caption.sessionID == sessionID {
                    await caption.labeling.rename(label: targetLabel, to: presetName)
                }
            }
            operationNotice = "已将该段标记为「\(presetName)」。"
            await reload()
        } catch {
            operationError = "标记说话人失败：\(error.localizedDescription)"
        }
    }

    private func nextUnusedSpeakerLabel() -> String {
        let used = Set(sessionSpeakerLabels)
        for candidate in ["A", "B", "C", "D", "E", "F"] where !used.contains(candidate) {
            return candidate
        }
        return "A"
    }

    private func saveRecordTitle(for summary: SessionSummary) async {
        let trimmed = recordRenameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await session.setSessionTitle(id: summary.id, title: trimmed.isEmpty ? nil : trimmed)
            renamingRecordID = nil
            operationNotice = "已更新记录标题。"
            await reload()
        } catch {
            operationError = "重命名记录失败：\(error.localizedDescription)"
        }
    }

    private static func timecode(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return SpeechRailDisplayFormat.MissingValue.timecode.text }
        return SpeechRailDisplayFormat.timecode(seconds)
    }

    // MARK: - 数据

    private var filteredSummaries: [SessionSummary] {
        let base: [SessionSummary]
        switch recordFilter {
        case .all:
            base = summaries
        case .multiSpeaker:
            base = summaries.filter { $0.speakerCount > 1 }
        case .active:
            base = summaries.filter { $0.record.state == .recording || $0.record.state == .processing }
        }
        // MC-49/MC-52：全文检索命中时按命中会话过滤，标题过滤作为回退。
        if !knowledgeHits.isEmpty {
            let hitIDs = Set(knowledgeHits.map(\.sessionID))
            return base.filter { hitIDs.contains($0.id) }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        return base.filter { summary in
            displayTitle(for: summary).localizedCaseInsensitiveContains(query)
                || recordSubtitle(summary).localizedCaseInsensitiveContains(query)
        }
    }

    /// 全文检索（MC-49/MC-52/MC-54）：查转录终稿与已完成纪要，不查私密问答。
    /// 失败不清空列表，只记错误；空查询清空命中回到标题过滤。
    private func runKnowledgeSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            knowledgeHits = []
            knowledgeError = nil
            return
        }
        do {
            knowledgeHits = try await session.searchKnowledge(query: query, kind: kind)
            knowledgeError = nil
            // 有命中时选中第一条，详情面板直接可读。
            if let first = knowledgeHits.first,
               summaries.contains(where: { $0.id == first.sessionID })
            {
                selectedID = first.sessionID
            }
        } catch {
            knowledgeHits = []
            knowledgeError = error.localizedDescription
        }
    }

    private var selectedSummary: SessionSummary? {
        summaries.first { $0.id == selectedID }
    }

    private func displayTitle(for summary: SessionSummary) -> String {
        if let title = summary.record.title, !title.isEmpty { return title }
        let date = summary.record.startedAt
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "今天 \(date.speechRailFormatted(.time))"
        } else if calendar.isDateInYesterday(date) {
            return "昨天 \(date.speechRailFormatted(.time))"
        }
        return date.speechRailFormatted(.dateTime)
    }

    private func recordSubtitle(_ summary: SessionSummary, includeSpeakerCount: Bool = true) -> String {
        var parts = [SessionCoordinator.formatted(summary.duration())]
        parts.append("\(summary.lineCount) 行")
        if includeSpeakerCount, summary.speakerCount > 1 {
            parts.append("\(summary.speakerCount) 人")
        }
        if let appName = summary.record.targetAppName, !appName.isEmpty {
            parts.append(appName)
        } else if summary.record.audioSource != .system {
            parts.append(summary.record.audioSource.title)
        }
        if summary.record.state == .archived, let reason = summary.record.endReason, reason != .user {
            parts.append(reason.title)
        }
        return parts.joined(separator: " · ")
    }

    private func removalMessage(for summary: SessionSummary) -> String {
        let title = displayTitle(for: summary)
        return "「\(title)」的正文、纪要与内心 OS 问答会一起删掉，无法撤销。"
            + "原始音频本来就没有留存。"
    }

    private func reload() async {
        do {
            let loaded = try await session.listSummaries(kind: kind)
            summaries = loaded
            let previousID = selectedID
            if selectedID == nil || !loaded.contains(where: { $0.id == selectedID }) {
                selectedID = loaded.first?.id
            }
            loadFailure = nil
            if previousID == selectedID { await loadLines() }
        } catch {
            loadFailure = error.localizedDescription
            summaries = []
            detailLoad.reset()
            detail = nil
        }
    }

    private func loadLines() async {
        guard let selectedID else {
            detailLoad.reset()
            detail = nil
            return
        }
        let isSwitchingRecord = detail?.review.record.id != selectedID
        if isSwitchingRecord {
            editingSpeakerLabel = nil
            selectedSpeakerFilter = nil
            detailSearchText = ""
            detail = nil
        }
        do {
            guard let snapshot = try await detailLoad.load(id: selectedID, operation: {
                guard let snapshot = try await session.reviewSnapshot(sessionID: selectedID) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let recovery = try await session.lines(sessionID: selectedID, includePartial: true)
                    .filter { $0.status == .partial }
                return (review: snapshot, recoveryLines: recovery)
            }) else { return }
            guard self.selectedID == selectedID else { return }
            detail = snapshot
        } catch {
            // The loader exposes the failure beside its retry action.
        }
    }

    private func copyTranscript(of summary: SessionSummary) async {
        do {
            let rawRows = try await session.lines(sessionID: summary.id)
            let rows = kind == .captions ? SessionExporter.paragraphLines(rawRows) : rawRows
            let text = rows.map { row -> String in
                let hasExplicitSpeaker = (row.speakerLabel?.isEmpty == false) || kind != .captions
                let prefix = hasExplicitSpeaker ? "\(speakerText(for: row))  " : ""
                let indent = hasExplicitSpeaker ? "    " : ""
                let source = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let translation = row.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines)
                let hasTranslation = hasDistinctMeaningfulTranslation(source: source, translation: translation)
                switch (kind == .captions ? libraryDisplayMode : .bilingual) {
                case .originalOnly:
                    return "\(prefix)\(source)"
                case .chineseOnly:
                    let content = (hasTranslation ? translation : nil) ?? source
                    return "\(prefix)\(content)"
                case .bilingual:
                    if hasTranslation, let translation {
                        return "\(prefix)\(translation)\n\(indent)\(source)"
                    }
                    return "\(prefix)\(source)"
                }
            }.joined(separator: kind == .captions ? "\n\n" : "\n")
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                operationError = "文字暂时未能复制，请重试。"
                return
            }
            operationNotice = "已复制文字记录。"
        } catch {
            operationError = "复制失败：\(error.localizedDescription)"
        }
    }

    private func remove(_ summary: SessionSummary) async {
        pendingRemoval = nil
        do {
            try await session.removeSession(id: summary.id)
            if selectedID == summary.id { selectedID = nil }
            await reload()
        } catch {
            operationError = "移除失败：\(error.localizedDescription)"
        }
    }
}
