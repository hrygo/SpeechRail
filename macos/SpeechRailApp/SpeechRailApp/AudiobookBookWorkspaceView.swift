import SpeechRailControlKit
import SwiftUI

/// Terminal dates are frozen; no clock is owned by the workflow or its parent workspace.
struct AudiobookAnalysisTimedRail: View {
    let progress: AudiobookAnalysisProgress
    let stoppedAt: Date?
    let eventCount: Int
    let showDeveloperDetails: Bool
    @Binding var isDeveloperSectionExpanded: Bool
    let onPause: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    var body: some View {
        TimelineView(.animation(minimumInterval: 1,
            paused: !SessionActivityPolicy.shouldTick(active: stoppedAt == nil, visible: visible, foreground: scenePhase == .active))) { context in
            AudiobookAnalysisProgressRailView(progress: progress,
                tick: SessionActivityPolicy.displayDate(now: context.date, stoppedAt: stoppedAt),
                eventCount: eventCount, showDeveloperDetails: showDeveloperDetails,
                isDeveloperSectionExpanded: $isDeveloperSectionExpanded, onPause: onPause)
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }
}

private struct AudiobookChapterRenameTarget: Identifiable {
    let bookID: UUID
    let chapterID: UUID
    let title: String

    var id: UUID { chapterID }
}

/// A small, independently ticking subtree keeps elapsed time out of the workspace's data flow.
private struct AudiobookProductionProgressRail: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    let progress: AudiobookProductionProgress
    let chapterTitle: String?
    let isBusy: Bool
    let isPausing: Bool
    let canResume: Bool
    var unreadyFragmentCount: Int = 0
    var reviewChapterCount: Int = 0
    let onPause: () -> Void
    let onResume: () -> Void
    var onRegenerateUnready: (() -> Void)? = nil
    var onReviewCandidates: (() -> Void)? = nil

    private var resolvedTitle: String {
        if isPausing && isBusy { return "正在暂停制作…" }
        if !isBusy && progress.isComplete {
            if unreadyFragmentCount > 0 {
                return "上次任务已保存 · 仍有 \(unreadyFragmentCount) 段尚未就绪"
            }
            if reviewChapterCount > 0 {
                return "新候选已保存 · 待试听采用"
            }
        }
        return progress.statusTitle
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !SessionActivityPolicy.shouldTick(active: isBusy, visible: visible, foreground: scenePhase == .active))) { context in
            CardSurface {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                        Text(resolvedTitle)
                            .font(SpeechRailDesignTokens.Typography.sectionTitle)
                        Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
                        Text("已用 \(SpeechRailDisplayFormat.duration(Double(progress.elapsedSeconds(at: context.date)), style: .elapsed))")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .monospacedDigit()
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        if isBusy {
                            Button(isPausing ? "正在暂停…" : "暂停制作", systemImage: "pause.circle", action: onPause)
                                .speechRailButton(.secondary)
                                .disabled(isPausing)
                                .accessibilityIdentifier("audiobook-production-pause")
                        } else if progress.canResume && (progress.state == .paused || progress.state == .failed) {
                            Button("继续制作", systemImage: "play.circle", action: onResume)
                                .speechRailButton(.secondary)
                                .disabled(!canResume)
                                .accessibilityIdentifier("audiobook-production-resume")
                        } else if unreadyFragmentCount > 0, let onRegenerateUnready {
                            Button("重新制作未就绪（\(unreadyFragmentCount) 段）…", systemImage: "arrow.clockwise", action: onRegenerateUnready)
                                .speechRailButton(.secondary)
                                .accessibilityIdentifier("audiobook-production-rail-regenerate-unready")
                        } else if reviewChapterCount > 0, let onReviewCandidates {
                            Button("去试听并采用", systemImage: "headphones.circle", action: onReviewCandidates)
                                .speechRailButton(.secondary)
                                .accessibilityIdentifier("audiobook-production-rail-review")
                        }
                    }
                    if progress.totalFragments > 0 {
                        ProgressView(value: SpeechRailDisplayFormat.progressValue(progress.fraction, isComplete: progress.isComplete && unreadyFragmentCount == 0))
                            .tint(SpeechRailDesignTokens.Color.rail)
                            .accessibilityLabel("制作进度")
                            .accessibilityValue("\(SpeechRailDisplayFormat.progress(progress.fraction, isComplete: progress.isComplete && unreadyFragmentCount == 0))，\(progress.savedFragmentsText)")
                    } else if isBusy {
                        ProgressView().controlSize(.small).accessibilityLabel(progress.statusTitle)
                    }
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        if let chapterTitle {
                            Text(chapterTitle).lineLimit(1)
                        }
                        Text(progress.savedFragmentsText).monospacedDigit()
                        if progress.reusedFragments > 0 { Text("其中 \(progress.reusedFragments) 段已复用") }
                        Spacer(minLength: 0)
                        if progress.totalFragments > 0 {
                            Text("\(SpeechRailDisplayFormat.progress(progress.fraction, isComplete: progress.isComplete && unreadyFragmentCount == 0))").monospacedDigit()
                        }
                    }
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

                    if isPausing && isBusy {
                        detail("正在停止当前请求，已保存的声音会保留。")
                    } else if progress.state == .paused {
                        detail("已保存的声音会保留。继续后会核对已有音频，接着完成本次任务。")
                    } else if progress.retryAttempt > 0 && isBusy {
                        detail("正在进行第 \(progress.retryAttempt) 次重试，已保存的声音不受影响。")
                    } else if isBusy {
                        detail("完成一段就保存，可随时暂停后继续。")
                    } else if progress.verificationFailureFragmentID != nil || unreadyFragmentCount > 0 {
                        detail("部分片段待更新或未通过校验，可直接点击右侧「重新制作未就绪」补齐并发布章节。")
                    }
                    if progress.isStalled(at: context.date), !isPausing {
                        StatusBanner(
                            kind: .standard, tone: .attention, title: "这次等待较久",
                            message: "当前步骤超过一分钟没有新进展。已保存的声音会保留，可以暂停后检查语音服务，再继续制作。"
                        )
                    }
                }
                .padding(SpeechRailDesignTokens.Spacing.sm)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("audiobook-production-progress-rail")
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(SpeechRailDesignTokens.Typography.caption)
            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
    }
}

/// T13：三栏有声书工作台视图（左：章节导航与就绪状态；中：准备与角色/制作与返修共享主画布；右：人物与配声检查器，窄窗口自适应收起为浮层）。
public struct AudiobookBookWorkspaceView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("speechrail.showDeveloperDetails") private var showAnalysisDeveloperDetails = false
    @State private var isAnalysisDevSectionExpanded = false
    @State private var isChapterSidebarCollapsed = false
    @State private var isCastInspectorCollapsed = false
    @State private var userCastInspectorCollapsedOverride: Bool?
    @State private var chapterRenameTarget: AudiobookChapterRenameTarget?
    @State private var chapterRenameDraft = ""
    @State private var isAIPrivacyPresented = false
    @State private var hoveredAtomID: UUID?
    @State private var hoveredFragmentID: UUID?
    @State private var pendingVoiceChange: PendingVoiceChange?

    /// 换声前的确认信息：只披露影响范围，不改变候选/采用语义。
    private struct PendingVoiceChange: Identifiable {
        let id = UUID()
        let roleID: UUID
        let voiceID: String
        let roleName: String
        let dialogueCount: Int
        let chapterCount: Int
    }

    public var onImportTXT: () -> Void

    public init(onImportTXT: @escaping () -> Void = {}) {
        self.onImportTXT = onImportTXT
    }

    private var workflow: AudiobookWorkflowModel {
        appModel.audiobookWorkflow
    }

    public var body: some View {
        @Bindable var bindableWorkflow = workflow

        GeometryReader { proxy in
            let canShowInlineCast = WindowLayoutPolicy.audiobookShowsInlineCastColumn(
                forWidth: proxy.size.width,
                isChapterSidebarCollapsed: isChapterSidebarCollapsed,
                isCastInspectorCollapsed: false
            )
            let showInlineCast = WindowLayoutPolicy.audiobookShowsInlineCastColumn(
                forWidth: proxy.size.width,
                isChapterSidebarCollapsed: isChapterSidebarCollapsed,
                isCastInspectorCollapsed: isCastInspectorCollapsed
            )

            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                topStatusAndPrimaryActionBar(
                    showInlineCast: showInlineCast,
                    canShowInlineCast: canShowInlineCast
                )

                if workflow.isAnalyzing {
                    analysisProgressRail
                }
                if let progress = workflow.selectedBookProductionProgress,
                   (!workflow.isProductionComplete || workflow.isProductionBusy || progress.verificationFailureFragmentID != nil)
                {
                    AudiobookProductionProgressRail(
                        progress: progress,
                        chapterTitle: workflow.chapters.first(where: { $0.id == progress.currentChapterID })?.title,
                        isBusy: workflow.isProductionBusy && workflow.productionBookID == progress.bookID,
                        isPausing: workflow.isPausingProduction,
                        canResume: !workflow.isProductionBusy && !workflow.isEditingChapterLayout
                            && workflow.selectedBook?.productionState == .paused,
                        unreadyFragmentCount: workflow.resumePlan?.redoFragmentIDs.count ?? 0,
                        reviewChapterCount: workflow.resumePlan?.reviewChapterIDs.count ?? 0,
                        onPause: { Task { await workflow.pauseProduction() } },
                        onResume: { Task { await workflow.prepareResumeProduction() } },
                        onRegenerateUnready: { Task { await workflow.prepareRegenerationForRedoFragments() } },
                        onReviewCandidates: { workflow.reviewProductionCandidates() }
                    )
                }
                if workflow.isProductionComplete {
                    productionCompletionGuide
                }
                HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.md) {
                    if !isChapterSidebarCollapsed {
                        chapterSidebarColumn
                            .frame(width: SpeechRailDesignTokens.Layout.sidebarIdealWidth)
                    }

                    centerStageColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if showInlineCast {
                        castInspectorColumn
                            .speechRailInspectorColumn()
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: SpeechRailDesignTokens.Layout.audiobookWorkbenchMinimumHeight,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )

                if shouldShowWorkspaceTransport {
                    workspaceTransportBar
                }
            }
            .sheet(item: $bindableWorkflow.regenerationDraft) { draft in
                AudiobookRegenerationSheet(workflow: workflow, draft: draft, availableSize: proxy.size)
            }
            .sheet(item: $bindableWorkflow.productionDraft) { draft in
                AudiobookProductionPlanSheet(workflow: workflow, plan: draft, availableSize: proxy.size)
            }
            .sheet(item: $bindableWorkflow.productionResumeDraft) { checkpoint in
                AudiobookProductionResumeSheet(workflow: workflow, checkpoint: checkpoint, availableSize: proxy.size)
            }
            .sheet(item: $chapterRenameTarget) { target in
                chapterRenameSheet(for: target)
            }
            .sheet(item: Binding(
                get: { workflow.chapterEditDraft },
                set: { if $0 == nil { workflow.cancelChapterEditing() } }
            )) { draft in
                AudiobookChapterEditingSheet(workflow: workflow, draft: draft)
            }
            .sheet(isPresented: $bindableWorkflow.isShowingVoicePreparationSheet) {
                AudiobookVoicePreparationSheet(workflow: workflow)
            }
            .sheet(isPresented: $bindableWorkflow.isPronunciationSheetPresented) {
                if let controller = workflow.pronunciationController,
                   let bookID = workflow.selectedBook?.id
                {
                    AudiobookPronunciationSheet(controller: controller, bookID: bookID) {
                        workflow.isPronunciationSheetPresented = false
                    }
                } else {
                    SpeechRailSheetScaffold(
                        title: "发音规则暂不可用",
                        subtitle: "作品存储或语音服务尚未就绪，请稍后重试。",
                        showsDividers: false,
                        onClose: { workflow.isPronunciationSheetPresented = false }
                    ) {
                        EmptyView()
                    } footer: {
                        Spacer(minLength: 0)
                        Button("关闭") { workflow.isPronunciationSheetPresented = false }
                            .speechRailButton(.primary)
                            .keyboardShortcut(.defaultAction)
                    }
                    .frame(width: SpeechRailDesignTokens.Layout.Sheet.quickPromptWidth)
                }
            }
            .onChange(of: workflow.selectedBook?.id) { _, selectedBookID in
                cancelRoleAudition()
                expandedRoleIDs.removeAll()
                userCastInspectorCollapsedOverride = nil
                isCastInspectorCollapsed = WindowLayoutPolicy.audiobookRecommendedCastInspectorCollapsed(
                    forTab: workflow.workbenchTab,
                    hasUnresolvedUnknownSpeakers: workflow.totalUnknownSpeakerCount > 0,
                    isCastConfirmed: workflow.isAuditionConfirmedForSelectedBook,
                    userOverride: nil
                )
                if chapterRenameTarget?.bookID != selectedBookID {
                    chapterRenameTarget = nil
                }
            }
            .onChange(of: workflow.workbenchTab) { _, newTab in
                withAnimation(SpeechRailDesignTokens.Motion.resolved(SpeechRailDesignTokens.Motion.panelTransition, reduceMotion: reduceMotion)) {
                    isCastInspectorCollapsed = WindowLayoutPolicy.audiobookRecommendedCastInspectorCollapsed(
                        forTab: newTab,
                        hasUnresolvedUnknownSpeakers: workflow.totalUnknownSpeakerCount > 0,
                        isCastConfirmed: workflow.isAuditionConfirmedForSelectedBook,
                        userOverride: userCastInspectorCollapsedOverride
                    )
                }
            }
            .onChange(of: workflow.isCreatingLeadExclusiveVoices) { wasCreating, isCreating in
                if wasCreating && !isCreating {
                    Task {
                        await appModel.engine.refreshDiscovery()
                        _ = await appModel.refreshCreatorVoices()
                    }
                }
            }
            .onDisappear { cancelRoleAudition() }
            .confirmationDialog(
                pendingVoiceChange.map { "更换「\($0.roleName)」的声音？" } ?? "更换角色声音？",
                isPresented: Binding(
                    get: { pendingVoiceChange != nil },
                    set: { presented in
                        if !presented { pendingVoiceChange = nil }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button("更换并标记待更新") {
                    guard let change = pendingVoiceChange else { return }
                    pendingVoiceChange = nil
                    Task { await workflow.bindVoice(roleID: change.roleID, voiceID: change.voiceID) }
                }
                Button("取消", role: .cancel) {
                    pendingVoiceChange = nil
                }
            } message: {
                if let change = pendingVoiceChange {
                    Text("该角色有 \(change.dialogueCount) 处对白，分布在 \(change.chapterCount) 章。更换后这些章节的对应片段需要重新生成；已采用的章节版本与历史候选都会保留。")
                }
            }
        }
    }

    private var productionCompletionGuide: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                Label("制作完成", systemImage: "checkmark.circle.fill")
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                Text("所有需朗读章节均已就绪。现在可以开始收听，或导出有声书保存和分享。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
            Button("导出有声书…", systemImage: "square.and.arrow.up") {
                workflow.isShowingExportSheet = true
            }
            .speechRailButton(.secondary)
            .accessibilityIdentifier("audiobook-completed-export")
        }
        .padding(SpeechRailDesignTokens.Spacing.md)
        .speechRailRecessedSlot()
        .accessibilityIdentifier("audiobook-production-completed-guide")
    }

    // MARK: - Top Summary & Single Primary Action Bar

    @ViewBuilder
    private func topStatusAndPrimaryActionBar(showInlineCast: Bool, canShowInlineCast: Bool) -> some View {
        @Bindable var bindableWorkflow = workflow
        if let book = workflow.selectedBook {
            CardSurface {
                HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.md) {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Button {
                                withAnimation(SpeechRailDesignTokens.Motion.resolved(SpeechRailDesignTokens.Motion.panelTransition, reduceMotion: reduceMotion)) {
                                    isChapterSidebarCollapsed.toggle()
                                }
                            } label: {
                                Image(systemName: "sidebar.left")
                            }
                            .speechRailButton(.quiet)
                            .help(isChapterSidebarCollapsed ? "展开章节目录" : "收起章节目录，扩大原文校对区")
                            .accessibilityLabel(isChapterSidebarCollapsed ? "展开章节目录" : "收起章节目录")
                            .accessibilityIdentifier("audiobook-toggle-chapter-sidebar")

                            Text(book.title)
                                .font(SpeechRailDesignTokens.Typography.sectionTitle)
                                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                                .lineLimit(1)
                            if let author = book.author, !author.isEmpty {
                                Text("· \(author)")
                                    .font(SpeechRailDesignTokens.Typography.body)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                    .lineLimit(1)
                            }
                            analysisStatusPill(for: book.analysisState)
                            if workflow.totalUnknownSpeakerCount > 0 {
                                StatusPill(
                                    tone: .attention,
                                    label: "待确认说话人 \(workflow.totalUnknownSpeakerCount) 处"
                                )
                            }
                            if workflow.currentAnalysisConfigSnapshot.isConfigured {
                                Button {
                                    isAIPrivacyPresented.toggle()
                                } label: {
                                    Label("AI 与隐私", systemImage: "info.circle")
                                        .labelStyle(.titleAndIcon)
                                }
                                .speechRailButton(.quiet)
                                .popover(isPresented: $isAIPrivacyPresented, arrowEdge: .bottom) {
                                    aiPrivacyDetails
                                        .frame(width: SpeechRailDesignTokens.Layout.inspectorColumnWidth)
                                        .padding(SpeechRailDesignTokens.Spacing.md)
                                }
                                .accessibilityIdentifier("audiobook-ai-privacy-disclosure")
                            }
                        }

                        if !workflow.currentAnalysisConfigSnapshot.isConfigured {
                            aiProviderDisclosureLine
                        }
                    }

                    Spacer()

                    Picker(
                        "工作台子阶段",
                        selection: Binding(
                            get: { workflow.workbenchTab },
                            set: { workflow.workbenchTab = $0 }
                        )
                    ) {
                        ForEach(AudiobookWorkflowModel.WorkbenchTab.allCases, id: \.self) { tab in
                            Text(tab.title).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .labelsHidden()
                    .accessibilityIdentifier("audiobook-workbench-tab-picker")
                    .accessibilityLabel("工作台子阶段")

                    Button {
                        if canShowInlineCast {
                            withAnimation(SpeechRailDesignTokens.Motion.resolved(SpeechRailDesignTokens.Motion.panelTransition, reduceMotion: reduceMotion)) {
                                isCastInspectorCollapsed.toggle()
                                userCastInspectorCollapsedOverride = isCastInspectorCollapsed
                            }
                        } else {
                            workflow.isCastInspectorPresented.toggle()
                        }
                    } label: {
                        Label(
                            "人物与声音（\(workflow.activeSpeakingCharacters.count)）",
                            systemImage: canShowInlineCast ? "sidebar.right" : "person.2.wave.2"
                        )
                    }
                    .speechRailButton(.secondary)
                    .help(canShowInlineCast ? (showInlineCast ? "收起右侧人物与声音栏，扩大主工作区" : "展开右侧人物与声音栏") : "打开人物与声音浮层")
                    .accessibilityValue(showInlineCast || workflow.isCastInspectorPresented ? "已展开" : "已收起")
                    .accessibilityIdentifier("audiobook-toggle-cast-inspector")
                    .popover(isPresented: $bindableWorkflow.isCastInspectorPresented, arrowEdge: .bottom) {
                        castInspectorColumn
                            .frame(width: SpeechRailDesignTokens.Layout.inspectorColumnWidth, height: 560)
                            .padding(SpeechRailDesignTokens.Spacing.sm)
                    }

                    Button {
                        workflow.presentPronunciationRules()
                    } label: {
                        Label(
                            workflow.pronunciationRuleCount > 0
                                ? "发音规则（\(workflow.pronunciationRuleCount)）"
                                : "发音规则",
                            systemImage: "textformat.abc"
                        )
                    }
                    .speechRailButton(.secondary)
                    .help("为多音字、人名地名和英文缩写固定读法；只影响之后重新制作的片段。")
                    .accessibilityIdentifier("audiobook-pronunciation-rules")

                    if let primaryAction = workflow.selectedBookPrimaryAction {
                        let productionStartBlocked = workflow.isProductionBlocked(for: book.id)
                            && (primaryAction == .makeConfirmedChapters || primaryAction == .resumeProduction)
                        Button {
                            triggerPrimaryAction(primaryAction, bookID: book.id)
                        } label: {
                            Label(
                                workflow.primaryActionTitle(primaryAction, for: book.id),
                                systemImage: primaryAction.systemImage
                            )
                        }
                        .speechRailButton(.primary)
                        .disabled(
                            (primaryAction == .pauseProduction && workflow.isPausingProduction)
                                || workflow.isPreparingProduction
                                || (primaryAction == .confirmCastAndVoices && workflow.isAssigningRecommendedVoices)
                                || workflow.isEditingChapterLayout
                                || productionStartBlocked
                        )
                        .help(workflow.isEditingChapterLayout
                              ? "正在整理章节目录，请完成后再继续。"
                              : (productionStartBlocked
                                  ? "另一部有声书正在制作，完成或暂停后即可开始此书。"
                                  : workflow.primaryActionTitle(primaryAction, for: book.id)))
                        .accessibilityIdentifier("audiobook-workspace-primary-action")
                    }
                }
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
            }
            if let guidance = productionActionGuidance {
                Label(guidance, systemImage: "checkmark.shield")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                    .accessibilityIdentifier("audiobook-production-action-guidance")
            }
        }
    }

    private var productionActionGuidance: String? {
        switch workflow.selectedBookPrimaryAction {
        case .makeConfirmedChapters:
            if workflow.pendingProductionChapters.isEmpty { return workflow.productionBlocker?.message }
            return "只补没有可用音频的片段，已有音频和待更新的旧声音全部保留。点击后先核对范围；更新与重新制作在「更多操作」中单独选择。"
        case .resumeProduction:
            return "继续前会展示原任务的操作类型和范围，不会顺带补新增缺失或更新其他片段。"
        case .pauseProduction:
            return "已完成片段逐段保存，暂停后可继续；已有章节版本保留。"
        case .reviewCandidates:
            return "新候选已保存。试听并选择采用后，才会替换当前章节版本。"
        case .continueListening:
            return "收听当前已采用的版本。想重新尝试，可在「更多操作」中选择重新制作范围，已有版本保留。"
        default:
            return nil
        }
    }

    @ViewBuilder
    private var aiProviderCompactPill: some View {
        let snapshot = workflow.currentAnalysisConfigSnapshot
        if snapshot.isConfigured {
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Text(snapshot.model)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.compact)
            .background(
                Capsule(style: .continuous)
                    .fill(SpeechRailDesignTokens.Color.recessedField)
            )
            .help("AI 分析服务：\(snapshot.model)（\(snapshot.normalizedBaseURL)）· 仅点击「分析全书」时按窗口发送正文，只返回角色与归属标注。")
            .accessibilityIdentifier("audiobook-global-analysis-service-summary")
        }
    }

    @ViewBuilder
    private var aiProviderDisclosureLine: some View {
        let snapshot = workflow.currentAnalysisConfigSnapshot
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Image(systemName: "shield.lefthalf.filled")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            if snapshot.isConfigured {
                Text("AI 分析服务：\(snapshot.model)（\(snapshot.normalizedBaseURL)）· 仅点击「分析全书」时按窗口发送正文，只返回角色与归属标注。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(1)
            } else {
                Text("尚未配置 AI 分析服务，请先在「设置 → 语音助手与 AI」填写地址与模型。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                SettingsLink {
                    Text("前往设置")
                }
                .speechRailButton(.quiet)
            }
        }
    }

    private var aiPrivacyDetails: some View {
        let snapshot = workflow.currentAnalysisConfigSnapshot
        return VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Text("AI 分析与隐私")
                .font(SpeechRailDesignTokens.Typography.sectionTitle)
            Text("服务：\(snapshot.model)")
                .font(SpeechRailDesignTokens.Typography.body)
            Text("地址：\(snapshot.normalizedBaseURL)")
                .font(SpeechRailDesignTokens.Typography.caption)
                .textSelection(.enabled)
            Text("只有点击“分析全书”或“AI 智能复核”时，所需正文才会按窗口发送给此服务；服务返回角色与说话人归属标注。原始书稿保留在本机。")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shouldShowWorkspaceTransport: Bool {
        guard let chapterID = workflow.selectedChapterID else { return false }
        let activeForChapter = workflow.listeningController?.activePlayback?.chapterID == chapterID
        return activeForChapter || workflow.chapterReadinessByID[chapterID] == .chapterAudioReady
    }

    @ViewBuilder
    private var workspaceTransportBar: some View {
        if let listening = workflow.listeningController,
           let bookID = workflow.selectedBook?.id,
           let chapterID = workflow.selectedChapterID {
            @Bindable var controller = listening
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                Text(workflow.chapters.first(where: { $0.id == chapterID })?.title ?? "本章播放")
                    .font(SpeechRailDesignTokens.Typography.caption.weight(.medium))
                    .lineLimit(1)
                Text("\(SpeechRailDisplayFormat.timecode(controller.chapterElapsedSeconds)) / \(SpeechRailDisplayFormat.timecode(controller.chapterTotalDurationSeconds))")
                    .font(SpeechRailDesignTokens.Typography.technical)
                    .monospacedDigit()
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                Button {
                    Task {
                        if controller.isPlaying {
                            await controller.pause()
                        } else if controller.activePlayback != nil {
                            try? await controller.resume()
                        } else {
                            try? await controller.play(bookID: bookID, chapterID: chapterID)
                        }
                    }
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                }
                .speechRailButton(.primary)
                .help(controller.isPlaying ? "暂停播放" : "播放本章")
                .accessibilityLabel(controller.isPlaying ? "暂停播放" : "播放本章")
                Button("−15 秒", systemImage: "gobackward.15") {
                    Task { try? await controller.skip(seconds: -15) }
                }
                .speechRailButton(.quiet)
                .accessibilityLabel("后退 15 秒")
                Button("+15 秒", systemImage: "goforward.15") {
                    Task { try? await controller.skip(seconds: 15) }
                }
                .speechRailButton(.quiet)
                .accessibilityLabel("前进 15 秒")
                Menu {
                    ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { rate in
                        Button(SpeechRailDisplayFormat.playbackRate(Double(rate))) {
                            Task { await controller.setRate(Float(rate)) }
                        }
                    }
                } label: {
                    Text(SpeechRailDisplayFormat.playbackRate(Double(controller.playbackRate)))
                }
                .speechRailButton(.secondary)
                .accessibilityLabel("播放速度")
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
            .background(SpeechRailDesignTokens.Color.recessedField)
            .clipShape(SpeechRailDesignTokens.Corner.containerShape)
            .accessibilityIdentifier("audiobook-workspace-mini-transport")
        }
    }

    // MARK: - Left Column: Chapter List & Readiness

    private var chapterSidebarColumn: some View {
        SessionPanel {
            VStack(alignment: .leading, spacing: 0) {
                SessionPanelHead(
                    title: "章节列表（\(workflow.chapters.count)）",
                    trailingDetail: "\(workflow.chapters.filter { $0.currentChapterRevisionID != nil }.count) 章已成片"
                )
                chapterOrganizationMenu
                SessionHairline()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                        ForEach(workflow.chapters) { chapter in
                            let isSelected = (workflow.selectedChapterID == chapter.id)
                            let readiness = workflow.chapterReadinessByID[chapter.id] ?? .awaitingGlobalAnalysis
                            Button {
                                workflow.selectedChapterID = chapter.id
                            } label: {
                                HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.xs) {
                                    Text("#\(chapter.ordinal + 1)")
                                        .font(SpeechRailDesignTokens.Typography.technical)
                                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                        .frame(width: 28, alignment: .leading)

                                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                                        Text(chapter.title)
                                            .font(SpeechRailDesignTokens.Typography.body)
                                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                                            .lineLimit(1)

                                        HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                                            if chapter.isSkipped {
                                                StatusPill(tone: .neutral, label: "已跳过")
                                            } else if readiness != .awaitingCastConfirmation {
                                                chapterReadinessBadge(for: readiness)
                                            }
                                            if let unknownCount = workflow.unknownCountByChapterID[chapter.id], unknownCount > 0 {
                                                StatusPill(tone: .attention, label: "待确认 \(unknownCount)")
                                            }
                                            if chapter.previousChapterRevisionID != nil && readiness == .needsUpdate {
                                                Text("旧版可听")
                                                    .font(SpeechRailDesignTokens.Typography.caption)
                                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                            }
                                        }
                                    }
                                    Spacer()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                                .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
                                .background(isSelected ? SpeechRailDesignTokens.Color.rail.opacity(0.14) : Color.clear, in: SpeechRailDesignTokens.Corner.controlShape)
                                .contentShape(.interaction, Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(workflow.isEditingChapterLayout)
                            .accessibilityIdentifier("audiobook-chapter-row-\(chapter.ordinal)")
                        }
                    }
                    .padding(SpeechRailDesignTokens.Spacing.xs)
                }

            }
        }
    }

    private var selectedChapterIsSkipped: Bool {
        workflow.chapters.first(where: { $0.id == workflow.selectedChapterID })?.isSkipped == true
    }

    private var chapterOrganizationMenu: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Menu {
                Button("编辑章节…", systemImage: "square.and.pencil") {
                    Task { await workflow.beginChapterEditing() }
                }
                .disabled(!workflow.canEditSelectedChapterText)
                Divider()
                Button("重命名章节…", systemImage: "pencil") {
                    guard let bookID = workflow.selectedBook?.id,
                          let chapter = workflow.chapters.first(where: { $0.id == workflow.selectedChapterID })
                    else { return }
                    chapterRenameDraft = chapter.title
                    chapterRenameTarget = AudiobookChapterRenameTarget(
                        bookID: bookID,
                        chapterID: chapter.id,
                        title: chapter.title
                    )
                }
                .disabled(!workflow.canRenameSelectedChapter)

                Divider()

                Button("在选中段落前拆分") {
                    Task { await workflow.splitSelectedChapterBeforeSelectedAtom() }
                }
                .disabled(!workflow.canSplitSelectedChapterBeforeSelectedAtom)
                .help(workflow.canEditChapterStructure
                      ? "先在原文中仅勾选一个章节中间的正文段落；目录调整不会改写原文。"
                      : workflow.chapterStructureEditingStatus)

                Button("与上一章合并") {
                    Task { await workflow.mergeSelectedChapterWithPrevious() }
                }
                .disabled(!workflow.canMergeSelectedChapterWithPrevious)
                .help(workflow.canEditChapterStructure
                      ? (workflow.selectedChapterID == workflow.chapters.first?.id
                          ? "第一章前没有章节可合并。"
                          : "将当前章并入上一章，保留上一章名称；原文不变。")
                      : workflow.chapterStructureEditingStatus)

                Divider()

                Button(
                    selectedChapterIsSkipped ? "恢复本章分析制作" : "跳过本章（不分析、不制作）",
                    systemImage: selectedChapterIsSkipped ? "arrow.uturn.backward" : "forward.end"
                ) {
                    guard let chapterID = workflow.selectedChapterID else { return }
                    Task {
                        await workflow.setChapterSkipped(
                            chapterID: chapterID,
                            skipped: !selectedChapterIsSkipped
                        )
                    }
                }
                .disabled(workflow.selectedChapterID == nil)
                .help("跳过后本章不参与全书分析、制作和导出；原文与章节结构保留，可随时恢复。")
            } label: {
                Label("整理章节", systemImage: "list.bullet.indent")
            }
            .speechRailButton(.secondary)
            .fixedSize()
            .accessibilityIdentifier("audiobook-chapter-organization-menu")
            .help(workflow.chapterStructureEditingStatus)

            if workflow.canEditChapterStructure {
                Text(workflow.chapterStructureEditingStatus)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("audiobook-chapter-organization-status")
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
    }

    private func chapterRenameSheet(for target: AudiobookChapterRenameTarget) -> some View {
        SpeechRailQuickInputSheet(
            title: "重命名章节",
            subtitle: "只更改「\(target.title)」的章节名称，原文、分析记录和已有音频都会保留。",
            placeholder: "章节名称",
            text: $chapterRenameDraft,
            confirmTitle: "保存",
            isConfirmDisabled: target.bookID != workflow.selectedBook?.id || !workflow.canRenameSelectedChapter,
            fieldAccessibilityIdentifier: "audiobook-chapter-rename-field",
            confirmAccessibilityIdentifier: "audiobook-chapter-rename-save",
            onCancel: {
                chapterRenameTarget = nil
            },
            onConfirm: {
                guard target.bookID == workflow.selectedBook?.id else {
                    chapterRenameTarget = nil
                    return
                }
                let chapterID = target.chapterID
                let title = chapterRenameDraft
                chapterRenameTarget = nil
                Task { await workflow.renameChapter(chapterID: chapterID, title: title, expectedTitle: target.title) }
            }
        )
    }

    // MARK: - Center Column: Shared Preparation / Production Canvas

    @ViewBuilder
    private var centerStageColumn: some View {
        VStack(spacing: 0) {
            if let chapter = workflow.chapters.first(where: { $0.id == workflow.selectedChapterID }),
               chapter.isSkipped
            {
                NoticeBar(
                    tone: .neutral,
                    message: "《\(chapter.title)》已跳过：不参与全书分析、制作和导出，原文与章节结构保留。",
                    actionTitle: "恢复本章"
                ) {
                    Task { await workflow.setChapterSkipped(chapterID: chapter.id, skipped: false) }
                }
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                .padding(.top, SpeechRailDesignTokens.Spacing.xs)
                .accessibilityIdentifier("audiobook-chapter-skipped-notice")
            }
            switch workflow.workbenchTab {
            case .preparation:
                preparationStageView
            case .production:
                productionStageView
            }
        }
    }

    private var preparationStageView: some View {
        SessionPanel {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    SessionPanelHead(
                        title: "正文与说话人归属",
                        trailingDetail: "共 \(workflow.chapterAtoms.count) 段 · 本章待确认 \(workflow.unknownAnnotationsInSelectedChapter.count) 处 · 全书 \(workflow.totalUnknownSpeakerCount) 处"
                    )
                    .frame(maxWidth: .infinity)
                    if workflow.selectedBook?.analysisState == .notStarted {
                        Button {
                            Task { await workflow.beginChapterEditing() }
                        } label: {
                            Label(workflow.isLoadingChapterEdit ? "正在读取…" : "编辑章节…", systemImage: "square.and.pencil")
                        }
                        .speechRailButton(.secondary)
                        .disabled(!workflow.canEditSelectedChapterText)
                        .padding(.trailing, SpeechRailDesignTokens.Spacing.md)
                        .accessibilityIdentifier("audiobook-edit-chapter")
                    }
                }
                .help("分析和配音使用保存后的正文。开始分析前可编辑章节标题与正文。")
                SessionHairline()

                if workflow.totalUnknownSpeakerCount > 0 {
                    unknownSpeakerNavigatorBar
                    SessionHairline()
                }

                if workflow.selectedAtomIDs.count > 1 {
                    batchSpeakerAssignmentBar
                    SessionHairline()
                }

                if workflow.isLoadingChapterDetails {
                    ProgressView("正在读取本章…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { scrollProxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                                ForEach(Array(workflow.displayedChapterAtoms.enumerated()), id: \.element.id) { index, atom in
                                    let previousAtom = index > 0 ? workflow.displayedChapterAtoms[index - 1] : nil
                                    atomRowView(atom: atom, previousAtom: previousAtom)
                                        .id(atom.id)
                                }
                            }
                            .padding(SpeechRailDesignTokens.Spacing.md)
                            .frame(maxWidth: SpeechRailDesignTokens.Layout.audiobookScriptReadingMaximumWidth, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .onChange(of: workflow.focusedUnknownAtomID) { _, newFocusedID in
                            guard let targetID = newFocusedID else { return }
                            withAnimation(.easeInOut(duration: 0.2)) {
                                scrollProxy.scrollTo(targetID, anchor: .center)
                            }
                        }
                    }
                }

                SessionHairline()
                SessionPanelActions {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Button {
                            Task { await workflow.undoLastSpeakerAssignment() }
                        } label: {
                            Label("撤销上次说话人修改", systemImage: "arrow.uturn.backward")
                        }
                        .speechRailButton(.quiet)

                        Spacer()
                    }
                }
            }
        }
    }

    private var unknownSpeakerNavigatorBar: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .foregroundStyle(SpeechRailDesignTokens.Color.attention)

            let currentIndex = workflow.currentUnknownSpeakerGlobalIndex ?? 1
            Text("待确认 \(currentIndex)/\(workflow.totalUnknownSpeakerCount)（本章 \(workflow.unknownAnnotationsInSelectedChapter.count) 处）")
                .font(SpeechRailDesignTokens.Typography.caption.weight(.medium))
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .fixedSize(horizontal: true, vertical: false)

            Button {
                Task { await workflow.jumpToPreviousUnknownSpeaker() }
            } label: {
                Label("上一处", systemImage: "chevron.up")
            }
            .speechRailButton(.secondary)
            .fixedSize(horizontal: true, vertical: false)

            Button {
                Task { await workflow.jumpToNextUnknownSpeaker() }
            } label: {
                Label("下一处", systemImage: "chevron.down")
            }
            .speechRailButton(.secondary)
            .fixedSize(horizontal: true, vertical: false)

            Button {
                workflow.showOnlyUnknownAtomsInChapter.toggle()
            } label: {
                Label(
                    workflow.showOnlyUnknownAtomsInChapter ? "显示整章" : "仅看待确认",
                    systemImage: workflow.showOnlyUnknownAtomsInChapter ? "list.bullet" : "line.3.horizontal.decrease.circle"
                )
            }
            .speechRailButton(workflow.showOnlyUnknownAtomsInChapter ? .primary : .quiet)
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 4)

            Button {
                if workflow.isResolvingUnknownSpeakers {
                    workflow.cancelSecondaryResolution()
                } else {
                    Task { await workflow.resolveUnknownSpeakersWithLLM() }
                }
            } label: {
                Label(
                    workflow.isResolvingUnknownSpeakers ? "取消 AI 复核" : "AI 智能复核",
                    systemImage: workflow.isResolvingUnknownSpeakers ? "xmark.circle" : "sparkles"
                )
            }
            .speechRailButton(.secondary)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(workflow.isAnalyzing)
            .help(workflow.isResolvingUnknownSpeakers
                  ? "停止本次复核；已经确认的说话人不会被撤销。"
                  : "结合整章最新人物名册与上下文，让 AI 复核本章剩余未确认台词")
            .accessibilityIdentifier("audiobook-secondary-resolve-unknown-button")
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .background(SpeechRailDesignTokens.Color.attention.opacity(0.10))
    }

    private var auditionGateBanner: some View {
        HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Image(systemName: "ear.badge.checkmark")
                .foregroundStyle(SpeechRailDesignTokens.Color.rail)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                Text("正式制作前请先试听并确认旁白与主要角色声音")
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Text("为避免整章生成后才发现声线不符，请在右侧为每个角色绑定可合成音色（支持为主角一键创建专属音色），确认后即可逐章制作。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            Spacer()
            Button("确认声音并进入制作") {
                Task { await workflow.confirmCastAndAudition() }
            }
            .speechRailButton(.secondary)
        }
        .padding(SpeechRailDesignTokens.Spacing.md)
        .background(SpeechRailDesignTokens.Color.field)
    }

    private var batchSpeakerAssignmentBar: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Text("已选 \(workflow.selectedAtomIDs.count) 段：")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .fixedSize(horizontal: true, vertical: false)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    ForEach(workflow.currentChapterCharacters.prefix(3)) { role in
                        Button("设为「\(role.displayName)」") {
                            let ids = Array(workflow.selectedAtomIDs)
                            workflow.selectedAtomIDs.removeAll()
                            Task { await workflow.assignSpeaker(atomIDs: ids, roleID: role.id) }
                        }
                        .speechRailButton(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    if let narrator = workflow.currentChapterCharacters.first(where: \.isNarrator) {
                        Button("旁白") {
                            let ids = Array(workflow.selectedAtomIDs)
                            workflow.selectedAtomIDs.removeAll()
                            Task { await workflow.assignSpeaker(atomIDs: ids, roleID: narrator.id) }
                        }
                        .speechRailButton(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    if workflow.currentChapterCharacters.count > 3 {
                        Menu("更多角色…") {
                            ForEach(workflow.currentChapterCharacters.dropFirst(3).filter { !$0.isNarrator }) { role in
                                Button(role.displayName) {
                                    let ids = Array(workflow.selectedAtomIDs)
                                    workflow.selectedAtomIDs.removeAll()
                                    Task { await workflow.assignSpeaker(atomIDs: ids, roleID: role.id) }
                                }
                            }
                        }
                        .speechRailButton(.secondary)
                    }
                }
            }

            Spacer(minLength: 4)

            Button("取消多选") {
                workflow.selectedAtomIDs.removeAll()
            }
            .speechRailButton(.quiet)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .background(SpeechRailDesignTokens.Color.recessedField)
        .disabled(workflow.isEditingChapterLayout)
    }

    @ViewBuilder
    private func atomRowView(atom: AudiobookTextAtom, previousAtom: AudiobookTextAtom?) -> some View {
        let annotation = workflow.chapterAnnotationsByAtomID[atom.id]
        let displayText = workflow.atomTextsByID[atom.id] ?? ""
        let isSelected = workflow.selectedAtomIDs.contains(atom.id)
        let isUnknown = annotation?.assignment.isUnknown == true
        let isFocusedUnknown = isUnknown && (workflow.focusedUnknownAtomID == atom.id)
        let previousAnnotation = previousAtom.flatMap { workflow.chapterAnnotationsByAtomID[$0.id] }
        let previousRoleID = previousAnnotation?.assignment.roleID
        let currentRoleID = annotation?.assignment.roleID
        let repeatsPreviousSpeaker = currentRoleID != nil
            && currentRoleID == previousRoleID
            && previousAnnotation?.assignment.isUnknown != true
        let isHovered = hoveredAtomID == atom.id
        let showsSpeakerLabel = !repeatsPreviousSpeaker || isSelected || isFocusedUnknown
        let assignedRole = annotation?.assignment.roleID.flatMap { id in
            workflow.charactersByID[id]
        }
        // 控件常驻，保证键盘/辅助功能用户无需悬停也能改派说话人；标签仍按上下文精简。
        let showsHeaderControls = true

        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            if showsHeaderControls {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Button {
                        if isSelected {
                            workflow.selectedAtomIDs.remove(atom.id)
                        } else {
                            workflow.selectedAtomIDs.insert(atom.id)
                        }
                    } label: {
                        Image(
                            systemName: isSelected
                                ? "checkmark.square.fill"
                                : "square"
                        )
                        .foregroundStyle(
                            isSelected
                                ? SpeechRailDesignTokens.Color.rail
                                : SpeechRailDesignTokens.Color.inkSecondary
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isSelected ? "取消选中本段" : "选中本段")
                    .accessibilityValue(isSelected ? "已选" : "未选")

                    if isUnknown {
                        StatusPill(
                            tone: .attention,
                            label: isFocusedUnknown ? "当前定位 · 待确认说话人" : "待确认说话人"
                        )
                    } else if let role = assignedRole, showsSpeakerLabel || isHovered || isSelected {
                        AudiobookVoiceTag(
                            name: role.displayName,
                            detail: workflow.voiceBindings[role.id]?.voiceID ?? "未配声"
                        )
                    } else if annotation == nil {
                        StatusPill(tone: .neutral, label: "待分析")
                    }

                    let charCount = displayText.isEmpty ? max(1, Int(atom.sourceRange.byteCount / 3)) : displayText.count
                    Text("\(charCount) 字")
                        .font(SpeechRailDesignTokens.Typography.technical)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)

                    Spacer()

                    Menu {
                        ForEach(workflow.currentChapterCharacters) { role in
                            Button("设为：\(role.displayName)") {
                                if isUnknown {
                                    Task { await workflow.assignSpeakerAndAdvanceToNextUnknown(atomID: atom.id, roleID: role.id) }
                                } else {
                                    Task { await workflow.assignSpeaker(atomIDs: [atom.id], roleID: role.id) }
                                }
                            }
                        }
                        if !workflow.remainingBookCharacters.isEmpty {
                            Divider()
                            Menu("更多全书角色（\(workflow.remainingBookCharacters.count)）") {
                                ForEach(workflow.remainingBookCharacters) { role in
                                    Button("设为：\(role.displayName)") {
                                        if isUnknown {
                                            Task { await workflow.assignSpeakerAndAdvanceToNextUnknown(atomID: atom.id, roleID: role.id) }
                                        } else {
                                            Task { await workflow.assignSpeaker(atomIDs: [atom.id], roleID: role.id) }
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("更换说话人", systemImage: "person.crop.circle")
                            .font(SpeechRailDesignTokens.Typography.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            Text(displayText)
                .font(
                    atom.kind == .heading
                        ? SpeechRailDesignTokens.Typography.sectionTitle
                        : SpeechRailDesignTokens.Typography.body
                )
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineSpacing(SpeechRailDesignTokens.Spacing.micro)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let ann = annotation, case let .unknown(reason, candidateRoleIDs) = ann.assignment {
                let candidateSet = Set(candidateRoleIDs)
                let quickRoles = workflow.quickCandidateRoles(for: ann)
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Text("待确认原因：\(reason)")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.attention)

                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Text("选择说话人（按数字键 1–5 快速确认并跳至下一处）：")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                                ForEach(Array(quickRoles.prefix(5).enumerated()), id: \.element.id) { index, role in
                                    Button {
                                        Task { await workflow.assignSpeakerAndAdvanceToNextUnknown(atomID: atom.id, roleID: role.id) }
                                    } label: {
                                        if candidateSet.contains(role.id) {
                                            Label("\(index + 1)  \(role.displayName)", systemImage: "sparkles")
                                                .lineLimit(1)
                                                .fixedSize(horizontal: true, vertical: false)
                                        } else {
                                            Text("\(index + 1)  \(role.displayName)")
                                                .lineLimit(1)
                                                .fixedSize(horizontal: true, vertical: false)
                                        }
                                    }
                                    .speechRailButton(candidateSet.contains(role.id) ? .primary : .secondary)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .keyboardShortcut(
                                        KeyEquivalent(Character(String(index + 1))),
                                        modifiers: []
                                    )
                                    .disabled(!isFocusedUnknown)
                                    .help("归属给「\(role.displayName)」并自动跳至下一处待确认")
                                }
                            }
                        }
                    }
                }
                .padding(SpeechRailDesignTokens.Spacing.xs)
                .background(SpeechRailDesignTokens.Color.attention.opacity(0.14))
                .clipShape(SpeechRailDesignTokens.Corner.nestedShape)
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .background(
            isFocusedUnknown
                ? SpeechRailDesignTokens.Color.attention.opacity(0.14)
                : (isSelected ? SpeechRailDesignTokens.Color.rail.opacity(0.10) : Color.clear)
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(
                    isUnknown
                        ? SpeechRailDesignTokens.Color.attention
                        : (isSelected
                            ? SpeechRailDesignTokens.Color.rail
                            : (assignedRole == nil ? SpeechRailDesignTokens.Color.separator : SpeechRailDesignTokens.Color.ready))
                )
                .frame(width: SpeechRailDesignTokens.Spacing.tiny)
                .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
        }
        .onHover { hovering in
            if hovering {
                hoveredAtomID = atom.id
            } else if hoveredAtomID == atom.id {
                hoveredAtomID = nil
            }
        }
        .disabled(workflow.isEditingChapterLayout)
    }

    // MARK: - Production & Candidate Repair Canvas

    private var productionStageView: some View {
        SessionPanel {
            VStack(alignment: .leading, spacing: 0) {
                SessionPanelHead(
                    title: "章节音频（共 \(workflow.chapterFragments.count) 段）",
                    trailingDetail: productionHeaderSummary
                )
                SessionHairline()

                productionBlockerBar

                AudiobookProductionQueuePanel(workflow: workflow)

                if let plan = workflow.resumePlan, !plan.redoFragmentIDs.isEmpty {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                        StatusPill(tone: .healthy, label: "可复用 \(plan.reusableFragmentIDs.count) 段")
                        StatusPill(tone: .attention, label: "尚未就绪 \(plan.redoFragmentIDs.count) 段")
                        Text("此处为全书统计，包含缺失、待更新或校验未通过的音频。只补缺失会保留已有音频。")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            .lineLimit(1)
                        Spacer()
                        Button("重新制作未就绪（\(plan.redoFragmentIDs.count) 段）…", systemImage: "arrow.clockwise") {
                            Task { await workflow.prepareRegenerationForRedoFragments() }
                        }
                        .speechRailButton(.secondary)
                        .disabled(workflow.isProductionBusy || workflow.isPreparingRegeneration
                            || workflow.isAnalyzing || workflow.isEditingChapterLayout)
                        .accessibilityIdentifier("audiobook-regenerate-redo-fragments")
                    }
                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                    .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
                    .background(SpeechRailDesignTokens.Color.recessedField)
                    SessionHairline()
                }

                if workflow.isLoadingChapterDetails {
                    ProgressView("正在读取本章…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if workflow.chapterFragments.isEmpty,
                          workflow.isProducing, workflow.productionBookID == workflow.selectedBook?.id
                {
                    SessionEmptyState(
                        systemImage: "waveform", title: "正在准备章节声音",
                        message: "上方会持续显示制作进度，已完成的声音会逐段保存。"
                    ) {}
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if workflow.chapterFragments.isEmpty {
                    SessionEmptyState(
                        systemImage: "waveform.path.ecg",
                        title: "本章尚未生成音频",
                        message: "完成分析与配声后，用顶部「只补缺失音频」补齐缺口；本章操作在下方「更多操作」中。开始前会展示具体范围。"
                    ) {}
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                            ForEach(AudiobookWorkspaceProjection.productionRows(workflow.chapterFragments)) { row in
                                fragmentRowView(fragment: row.fragment, previousFragment: row.previousFragment)
                            }
                        }
                        .padding(SpeechRailDesignTokens.Spacing.md)
                        .frame(maxWidth: SpeechRailDesignTokens.Layout.audiobookScriptReadingMaximumWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }

                SessionHairline()
                SessionPanelActions {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        if let chID = workflow.selectedChapterID {
                            if workflow.resumePlan?.reviewChapterIDs.contains(chID) == true {
                                Button("试听本章新候选", systemImage: "play.circle") {
                                    workflow.reviewProductionCandidates(chapterID: chID)
                                }
                                .speechRailButton(.secondary)
                                .disabled(workflow.isProductionBusy || workflow.isLoadingChapterDetails || workflow.isEditingChapterLayout)

                                Button("采用本章新候选", systemImage: "checkmark.circle") {
                                    Task { await workflow.adoptAllChapterCandidates(chapterID: chID) }
                                }
                                .speechRailButton(.primary)
                                .disabled(workflow.isProductionBusy || workflow.isLoadingChapterDetails || workflow.isEditingChapterLayout)
                                .accessibilityIdentifier("audiobook-adopt-chapter-candidates")
                            } else if workflow.isChapterAudioCurrent(chID) {
                                Button("收听本章", systemImage: "headphones") {
                                    Task { await workflow.startListening(chapterID: chID) }
                                }
                                .speechRailButton(.secondary)
                                .disabled(workflow.isProductionBusy || workflow.isLoadingChapterDetails || workflow.isEditingChapterLayout)
                            }
                        }

                        Menu("更多操作", systemImage: "ellipsis.circle") {
                            Button("只补本章缺失音频…", systemImage: "waveform.badge.plus") {
                                if let chID = workflow.selectedChapterID {
                                    Task { await workflow.prepareProduction(intent: .missingOnly, chapterIDs: [chID]) }
                                }
                            }
                            .disabled(workflow.isProductionBusy || workflow.isLoadingChapterDetails
                                || workflow.isAnalyzing || workflow.isEditingChapterLayout
                                || workflow.isPreparingProduction || workflow.selectedChapterID == nil)
                            Button("更新本章待更新音频…", systemImage: "arrow.triangle.2.circlepath") {
                                if let chID = workflow.selectedChapterID {
                                    Task { await workflow.prepareProduction(intent: .updateOutdated, chapterIDs: [chID]) }
                                }
                            }
                            .disabled(workflow.isProductionBusy || workflow.isPreparingProduction || workflow.isAnalyzing
                                || workflow.isEditingChapterLayout || workflow.isLoadingChapterDetails || workflow.selectedChapterID == nil)
                            Divider()
                            Button("只补全书缺失音频…") {
                                Task { await workflow.prepareProduction(intent: .missingOnly) }
                            }
                            .disabled(workflow.isProductionBusy || workflow.isPreparingProduction || workflow.isAnalyzing || workflow.isEditingChapterLayout)
                            Button("更新全书待更新音频…") {
                                Task { await workflow.prepareProduction(intent: .updateOutdated) }
                            }
                            .disabled(workflow.isProductionBusy || workflow.isPreparingProduction || workflow.isAnalyzing || workflow.isEditingChapterLayout)
                            Divider()
                            Button("重新制作…", systemImage: "arrow.clockwise") {
                                Task { await workflow.prepareRegeneration() }
                            }
                            .disabled(workflow.isProductionBusy || workflow.isPreparingRegeneration
                                || workflow.isAnalyzing || workflow.isEditingChapterLayout
                                || (!workflow.chapters.contains { !$0.isSkipped && $0.currentChapterRevisionID != nil }
                                    && (workflow.resumePlan?.redoFragmentIDs.isEmpty ?? true)
                                    && workflow.chapterCandidates.isEmpty))
                            Button("回退本章上一版本", systemImage: "arrow.uturn.backward") {
                                Task { await workflow.undoChapterAdoption() }
                            }
                            .disabled(workflow.isProductionBusy)
                        }
                        .help("只补缺失、更新旧音频和重新制作是独立操作，执行前均显示范围与影响。")
                        .accessibilityIdentifier("audiobook-production-more-actions")

                        Spacer()
                        Text("已有章节保留 · 更新候选采用后替换")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var productionBlockerBar: some View {
        if let blocker = workflow.productionBlocker {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Image(systemName: "info.circle")
                    .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                Text(blocker.message)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                switch blocker {
                case .unknownSpeakers:
                    Button("定位待确认说话人") {
                        Task { await workflow.jumpToFirstUnknownSpeaker() }
                    }
                    .speechRailButton(.secondary)
                case .castNotConfirmed:
                    Button("去确认配声") {
                        workflow.workbenchTab = .preparation
                    }
                    .speechRailButton(.secondary)
                case .editingChapterLayout, .anotherBookProducing, .noReadyChapters:
                    EmptyView()
                }
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
            .background(SpeechRailDesignTokens.Color.recessedField)
            SessionHairline()
        }
    }

    private var productionHeaderSummary: String {
        if workflow.isSelectedBookBlockedByProduction {
            return "另一部有声书正在制作"
        }
        if let prog = workflow.selectedBookProductionProgress,
           workflow.isProducing,
           workflow.productionBookID == workflow.selectedBook?.id
        {
            return "\(prog.statusTitle) · \(prog.savedFragmentsText)"
        }
        return "按章节顺序制作，已完成片段自动复用"
    }

    @ViewBuilder
    private func fragmentRowView(fragment: AudiobookFragment, previousFragment: AudiobookFragment?) -> some View {
        let role = workflow.charactersByID[fragment.roleID]
        let text = workflow.fragmentTextsByID[fragment.id] ?? ""
        let candidates = workflow.chapterCandidatesByFragmentID[fragment.id] ?? []
        let matchingCandidate = candidates.first(where: { $0.dependencyDigest == fragment.dependencyDigest && $0.isReceiptVerified })
        let isCurrentlyProducing = workflow.selectedBookProductionProgress?.currentFragmentID == fragment.id && workflow.isProducing
        let isHovered = hoveredFragmentID == fragment.id
        let repeatsPreviousRole = previousFragment?.roleID == fragment.roleID
        let showsRoleTag = !repeatsPreviousRole || isHovered || isCurrentlyProducing || candidates.count > 1 || matchingCandidate == nil

        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text("#\(fragment.ordinal + 1)")
                    .font(SpeechRailDesignTokens.Typography.technical)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

                if showsRoleTag {
                    AudiobookVoiceTag(
                        name: role?.displayName ?? "角色",
                        detail: workflow.voiceBindings[fragment.roleID]?.voiceID ?? "未绑定"
                    )
                }

                if let progress = workflow.selectedBookProductionProgress,
                   workflow.isProducing, progress.currentFragmentID == fragment.id
                {
                    StatusPill(tone: .attention, label: progress.statusTitle)
                } else if let cand = matchingCandidate {
                    StatusPill(
                        tone: .healthy,
                        label: "已就绪 · " + SpeechRailDisplayFormat.duration(cand.durationSeconds)
                    )
                } else if candidates.contains(where: { $0.dependencyDigest == fragment.dependencyDigest && !$0.isReceiptVerified }) {
                    StatusPill(tone: .attention, label: "已保存 · 校验未通过")
                } else if !candidates.isEmpty {
                    StatusPill(tone: .attention, label: "待更新 · 旧版可听")
                } else {
                    StatusPill(tone: .neutral, label: "待合成")
                }

                Spacer()

                if let cand = matchingCandidate ?? candidates.first {
                    Button {
                        Task { await workflow.previewCandidateAudio(cand) }
                    } label: {
                        Label("试听片段", systemImage: "play.circle")
                    }
                    .speechRailButton(.quiet)
                }

                if let cand = matchingCandidate,
                   workflow.chapters.first(where: { $0.id == fragment.chapterID })?.currentChapterRevisionID != nil,
                   (workflow.resumePlan?.reviewChapterIDs.contains(fragment.chapterID) == true || candidates.count > 1)
                {
                    Button("采用此候选") {
                        Task { await workflow.adoptCandidate(cand.id) }
                    }
                    .speechRailButton(.quiet)
                    .disabled(workflow.isProductionBusy)
                    .accessibilityIdentifier("audiobook-adopt-fragment-\(fragment.ordinal)")
                }

                Button {
                    workflow.selectedFragmentID = fragment.id
                    Task { await workflow.prepareRegeneration(fragmentID: fragment.id) }
                } label: {
                    Label(
                        workflow.isRegeneratingFragment(fragment.id) ? "正在重录…" : "重录本段",
                        systemImage: "arrow.clockwise"
                    )
                }
                .speechRailButton(.quiet)
                .disabled(!workflow.canRegenerateFragment(fragment.id))
                .help(workflow.chapters.first(where: { $0.id == fragment.chapterID })?.currentChapterRevisionID == nil
                      ? (candidates.isEmpty ? "请先完成本章首次制作，再重录单段。" : "重新生成本段音频；本章全部片段就绪后将自动生成章节音频。")
                      : "只为本段生成一个新候选，不会替换当前章节版本；试听后可在候选列表中选择采用。")
                .accessibilityIdentifier("audiobook-regenerate-fragment-\(fragment.ordinal)")
            }

            Text(text)
                .font(SpeechRailDesignTokens.Typography.body)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if candidates.count > 1 {
                DisclosureGroup("历史重录版本（共 \(candidates.count) 版）") {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                        ForEach(candidates) { candidate in
                            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                                Text("第 \(candidate.generation) 版")
                                    .font(SpeechRailDesignTokens.Typography.technical)
                                Text(SpeechRailDisplayFormat.duration(candidate.durationSeconds))
                                    .font(SpeechRailDesignTokens.Typography.caption)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                if candidate.dependencyDigest == fragment.dependencyDigest {
                                    StatusPill(tone: candidate.isReceiptVerified ? .healthy : .attention, label: candidate.isReceiptVerified ? "当前设定" : "校验未通过")
                                } else {
                                    StatusPill(tone: .neutral, label: "旧版设定")
                                }
                                Spacer()
                                Button("试听") {
                                    Task { await workflow.previewCandidateAudio(candidate) }
                                }
                                .speechRailButton(.quiet)
                                .accessibilityLabel("试听第 \(candidate.generation) 版")

                                if candidate.dependencyDigest == fragment.dependencyDigest && candidate.isReceiptVerified {
                                    Button("采用此候选") {
                                        Task { await workflow.adoptCandidate(candidate.id) }
                                    }
                                    .speechRailButton(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.top, SpeechRailDesignTokens.Spacing.micro)
                }
                .disclosureGroupStyle(SpeechRailDisclosureGroupStyle())
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .background(
            isCurrentlyProducing
                ? SpeechRailDesignTokens.Color.attention.opacity(0.10)
                : Color.clear
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(
                    isCurrentlyProducing || (!candidates.isEmpty && matchingCandidate == nil)
                        ? SpeechRailDesignTokens.Color.attention
                        : (matchingCandidate != nil ? SpeechRailDesignTokens.Color.ready : SpeechRailDesignTokens.Color.separator)
                )
                .frame(width: SpeechRailDesignTokens.Spacing.tiny)
                .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
        }
        .onHover { hovering in
            if hovering {
                hoveredFragmentID = fragment.id
            } else if hoveredFragmentID == fragment.id {
                hoveredFragmentID = nil
            }
        }
    }

    // MARK: - Right Column: Cast & Voice Binding Inspector

    @State private var activeVoicePickerRoleID: UUID?
    @State private var expandedRoleIDs: Set<UUID> = []
    @State private var auditionPreviewRoleID: UUID?
    @State private var auditionLoadingRoleID: UUID?
    @State private var auditionRequestID: UUID?

    private static let castMinorArchetypes: [AudiobookVoiceArchetype] = [
        .youngMale, .matureMale, .youngFemale, .matureFemale, .neutralEnsemble
    ]

    private var isAllCastExpanded: Bool {
        !workflow.characters.isEmpty && expandedRoleIDs.count >= workflow.characters.count
    }

    private func toggleAllCastExpansion() {
        withAnimation(SpeechRailDesignTokens.Motion.resolved(SpeechRailDesignTokens.Motion.panelTransition, reduceMotion: reduceMotion)) {
            if isAllCastExpanded {
                expandedRoleIDs.removeAll()
            } else {
                expandedRoleIDs = Set(workflow.characters.map(\.id))
            }
        }
    }

    private func cancelRoleAudition() {
        auditionRequestID = nil
        auditionLoadingRoleID = nil
        if auditionPreviewRoleID != nil {
            appModel.cancelVoicePreview()
        }
        auditionPreviewRoleID = nil
        workflow.stopAuditionPlayback()
    }

    private var castInspectorColumn: some View {
        @Bindable var bindableWorkflow = workflow
        let allAvailableVoices = workflow.mergedAvailableVoices(
            externalVoices: appModel.safeVoiceCatalog?.data ?? []
        )
        let activeBookVoices = allAvailableVoices.filter {
            appModel.voiceCatalogModel.snapshot.isVoiceActiveForBook(voiceID: $0.id, currentBookID: workflow.selectedBook?.id)
        }
        let missingArchetypes = workflow.missingArchetypesForBook(
            bookID: workflow.selectedBook?.id,
            availableVoices: allAvailableVoices
        )
        let leadCount = workflow.leadCharacterCount
        let minorCount = workflow.minorCharacterCount
        let silentCount = workflow.silentCharacterCount
        let activeCount = workflow.activeSpeakingCharacters.count
        let conflictCount = workflow.totalSceneVoiceConflictCount

        return SessionPanel {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 0) {
                    SessionPanelHead(
                        title: "人物与声音（\(activeCount)）",
                        trailingDetail: "核心 \(leadCount) · 配角 \(minorCount)"
                    )
                    Spacer(minLength: 0)
                    Button {
                        toggleAllCastExpansion()
                    } label: {
                        Text(isAllCastExpanded ? "全部收起" : "全部展开")
                            .font(SpeechRailDesignTokens.Typography.caption)
                    }
                    .speechRailButton(.secondary)
                    .padding(.trailing, SpeechRailDesignTokens.Spacing.md)
                    .accessibilityIdentifier("audiobook-cast-toggle-all-expansion-button")
                }
                SessionHairline()

                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        if conflictCount > 0 {
                            StatusPill(tone: .attention, label: "同场撞音 \(conflictCount) 处")
                        }
                        if !missingArchetypes.isEmpty {
                            StatusPill(
                                tone: .neutral,
                                label: "六类群像已备 \(6 - missingArchetypes.count)/6"
                            )
                        } else {
                            StatusPill(tone: .healthy, label: "六类群像音色已齐备")
                        }
                        Spacer(minLength: 0)
                        if silentCount > 0 {
                            Button {
                                workflow.showSilentCharacters.toggle()
                            } label: {
                                Text(workflow.showSilentCharacters ? "隐藏 \(silentCount) 个无对白角色" : "显示 \(silentCount) 个无对白角色")
                                    .font(SpeechRailDesignTokens.Typography.caption)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            }
                            .buttonStyle(.plain)
                            .help("仅在旁白中提及、全书无直接开口台词的角色默认折叠，无需分配独立声音")
                            .accessibilityIdentifier("audiobook-cast-toggle-silent-characters")
                        }
                    }

                    Picker(
                        "角色筛选范围",
                        selection: $bindableWorkflow.castFilterScope
                    ) {
                        ForEach(AudiobookWorkflowModel.CastFilterScope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("audiobook-cast-filter-scope-picker")
                }
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
                .background(SpeechRailDesignTokens.Color.recessedField)

                SessionHairline()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        ForEach(workflow.filteredCharacters) { role in
                            characterCard(
                                for: role,
                                allVoices: allAvailableVoices,
                                activeBookVoices: activeBookVoices.isEmpty ? allAvailableVoices : activeBookVoices
                            )
                        }
                    }
                    .padding(SpeechRailDesignTokens.Spacing.sm)
                }

                SessionHairline()
                castInspectorActions(activeBookVoices: activeBookVoices, allAvailableVoices: allAvailableVoices)
            }
        }
    }

    @ViewBuilder
    private var unavoidableConflictsAlert: some View {
        if workflow.pendingCastingPlan?.hasUnavoidableSceneConflicts == true {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                    .accessibilityHidden(true)
                Text("当前声音不足以完全避开同场撞音。可在「更多整理…」中准备更多音色，浏览确认后批量创建。")
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Spacer(minLength: 0)
            }
            .padding(SpeechRailDesignTokens.Spacing.sm)
            .background(
                SpeechRailDesignTokens.Corner.controlShape
                    .fill(SpeechRailDesignTokens.Surface.attentionTint)
            )
            .overlay(
                SpeechRailDesignTokens.Corner.controlShape
                    .stroke(SpeechRailDesignTokens.Color.attention.opacity(0.4), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var leadVoiceCreationProgressView: some View {
        if let progressText = workflow.castingPreparationProgressText
            ?? (workflow.isCreatingLeadExclusiveVoices ? workflow.leadVoiceCreationProgressText : nil) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                ProgressView()
                    .controlSize(.small)
                Text(progressText)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var primaryCastingActionButton: some View {
        if workflow.isAuditionConfirmedForSelectedBook {
            if workflow.workbenchTab == .preparation {
                Button("查看章节音频", systemImage: "arrow.right") {
                    workflow.workbenchTab = .production
                }
                .speechRailButton(.secondary)
                .help("切换到「制作与返修」，不会开始制作或替换已有音频。")
                .accessibilityIdentifier("audiobook-start-production-action-button")
            } else {
                Label("配声已确认", systemImage: "checkmark.circle")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
        } else if workflow.hasMissingVoiceCreationDrafts {
            Button("浏览并创建音色", systemImage: "person.wave.2") {
                workflow.isShowingVoicePreparationSheet = true
            }
            .speechRailButton(.secondary)
            .disabled(workflow.isCreatingLeadExclusiveVoices || workflow.isAssigningRecommendedVoices)
            .accessibilityIdentifier("audiobook-review-missing-voices-button")
        } else if !workflow.castingPlanNeedsSeparateConfirmation {
            Button {
                Task {
                    await workflow.autoAssignRecommendedVoices(consentsToSharedMinorVoices: true)
                }
            } label: {
                Label(workflow.isAssigningRecommendedVoices ? "正在准备配声…" : "一键智能配声", systemImage: "wand.and.stars")
            }
            .speechRailButton(.secondary)
            .disabled(workflow.isCreatingLeadExclusiveVoices || workflow.isAssigningRecommendedVoices || workflow.isAnalyzing || workflow.isProductionBusy || workflow.selectedBook?.analysisState != .allWindowsValidated)
            .help("使用已有声音自动为全书配声，角色按需共用；已有选声会保留，同章撞音会集中提示确认。完成后由你启动章节制作")
            .accessibilityIdentifier("audiobook-smart-assign-voices-button")
        }
    }

    @ViewBuilder
    private func castInspectorActions(
        activeBookVoices: [SafeVoiceEntry],
        allAvailableVoices: [SafeVoiceEntry]
    ) -> some View {
        SessionPanelActions {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                unavoidableConflictsAlert
                leadVoiceCreationProgressView

                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    castMoreMenu(activeBookVoices: activeBookVoices, allAvailableVoices: allAvailableVoices)
                    Spacer()
                    primaryCastingActionButton
                }

                if workflow.isAuditionConfirmedForSelectedBook {
                    Text("制作请用工作台顶部按钮。更换声音只影响相关片段，已有章节版本保留。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                } else {
                    Text(workflow.hasMissingVoiceCreationDrafts
                        ? "缺少声音的创建资料已备好，浏览、勾选后即可批量创建。"
                        : "自动匹配已有声音，数量不足时按需共用。想精调时再打开角色；准备好后由你开始制作。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }

                if let plan = workflow.pendingCastingPlan,
                   !plan.isApplicable || workflow.castingPlanNeedsSeparateConfirmation {
                    AudiobookCastingReview(workflow: workflow).id(plan.inputDigest)
                }
            }
        }
    }

    @ViewBuilder
    private func castMoreMenu(
        activeBookVoices: [SafeVoiceEntry],
        allAvailableVoices: [SafeVoiceEntry]
    ) -> some View {
        Menu {
            Button("按角色特征重新配声…") {
                Task { await workflow.previewRecastingVoices() }
            }
            .disabled(workflow.isAssigningRecommendedVoices || workflow.isAnalyzing || workflow.isProductionBusy)
            if !workflow.voiceCreationDrafts.isEmpty {
                Button("浏览已准备的音色资料…") {
                    workflow.isShowingVoicePreparationSheet = true
                }
            }
            Button {
                Task {
                    await workflow.prepareVoiceCreationDrafts()
                }
            } label: {
                Label("准备缺少的音色…", systemImage: "person.3.fill")
            }
            .disabled(workflow.isCreatingLeadExclusiveVoices || workflow.isPreparingVoiceDrafts)

            Button {
                Task {
                    await workflow.prepareVoiceCreationDrafts(scope: .leads)
                }
            } label: {
                Label(
                    workflow.isCreatingLeadExclusiveVoices ? "生成音色中…" : "为主角准备专属音色…",
                    systemImage: "person.wave.2.fill"
                )
            }
            .disabled(workflow.isCreatingLeadExclusiveVoices)

            castArchetypeBatchMenu(activeBookVoices: activeBookVoices, allAvailableVoices: allAvailableVoices)

            Button {
                workflow.isShowingCastMergeSheet = true
            } label: {
                Label("合并/拆分角色…", systemImage: "arrow.triangle.merge")
            }

            if workflow.silentCharacterCount > 0 {
                Button {
                    workflow.showSilentCharacters.toggle()
                } label: {
                    Label(
                        workflow.showSilentCharacters
                            ? "隐藏无对白角色（\(workflow.silentCharacterCount)）"
                            : "显示无对白角色（\(workflow.silentCharacterCount)）",
                        systemImage: workflow.showSilentCharacters ? "eye.slash" : "eye"
                    )
                }
            }

            Divider()

            Button {
                toggleAllCastExpansion()
            } label: {
                Label(
                    isAllCastExpanded ? "全部收起角色卡片" : "全部展开角色卡片",
                    systemImage: isAllCastExpanded ? "chevron.up.circle" : "chevron.down.circle"
                )
            }

            Button {
                Task { await workflow.undoLastCastingChange() }
            } label: {
                Label("撤销上次配声", systemImage: "arrow.uturn.backward")
            }
        } label: {
            Label("更多整理…", systemImage: "ellipsis.circle")
        }
        .speechRailButton(.secondary)
        .accessibilityIdentifier("audiobook-cast-more-menu")
    }

    @ViewBuilder
    private func castArchetypeSubmenu(
        archetype: AudiobookVoiceArchetype,
        voices: [SafeVoiceEntry]
    ) -> some View {
        let matchingMinors = workflow.minorCharactersByArchetype[archetype] ?? []
        Menu("\(archetype.shortBadgeTitle)（\(matchingMinors.count) 人）") {
            if voices.isEmpty {
                Text("当前无可用合成音色")
            } else {
                ForEach(voices) { voice in
                    Button("批量绑定：\(voice.name)") {
                        Task {
                            await workflow.batchBindArchetype(archetype, to: voice)
                        }
                    }
                }
            }
        }
        .disabled(matchingMinors.isEmpty)
    }

    @ViewBuilder
    private func castArchetypeBatchMenu(
        activeBookVoices: [SafeVoiceEntry],
        allAvailableVoices: [SafeVoiceEntry]
    ) -> some View {
        let voicesToList = activeBookVoices.isEmpty ? allAvailableVoices : activeBookVoices
        Menu {
            ForEach(Self.castMinorArchetypes) { archetype in
                castArchetypeSubmenu(archetype: archetype, voices: voicesToList)
            }
        } label: {
            Label("按声部批量配音…", systemImage: "person.3.sequence")
        }
    }

    @ViewBuilder
    private func characterCard(
        for role: AudiobookCharacter,
        allVoices: [SafeVoiceEntry],
        activeBookVoices: [SafeVoiceEntry]
    ) -> some View {
        let binding = workflow.voiceBindings[role.id]
        let stat = workflow.roleStatsByID[role.id]
        let tier = stat?.tier ?? (role.isNarrator ? .narrator : (role.allowSharedMinorVoice ? .supporting : .lead))
        let archetype = stat?.archetype ?? role.inferredVoiceArchetype()
        let dialogueCount = stat?.dialogueAtomCount ?? 0
        let voiceIsOptional = stat != nil && !role.isNarrator && dialogueCount == 0
            && workflow.selectedBook?.analysisState == .allWindowsValidated && workflow.totalUnknownSpeakerCount == 0
        let conflictPartners = workflow.sceneConflictPartnerNames(for: role.id)
        let voiceMeta = binding.flatMap { appModel.voiceCatalogModel.metadata(for: $0.voiceID) }
        let isCustomExclusiveVoice = binding.map {
            voiceMeta?.visibilityScope == .bookExclusive
                || !AudiobookWorkflowModel.builtInSystemVoiceIDs.contains($0.voiceID.lowercased())
        } ?? false

        let isSelected = workflow.selectedRoleID == role.id
        let hasConflict = !conflictPartners.isEmpty
        let isExpanded = isSelected || hasConflict || expandedRoleIDs.contains(role.id)

        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                // 默认紧凑行：角色名 + 定位/声部标签 + 音色胶囊 + 试听 + 展开/折叠
                Button {
                    workflow.selectedRoleID = role.id
                } label: {
                    HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        SessionVoiceBadge(label: String(role.displayName.prefix(1)))

                        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                            HStack(alignment: .firstTextBaseline, spacing: SpeechRailDesignTokens.Spacing.xs) {
                                Text(role.displayName)
                                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                StatusPill(
                                    tone: (tier == .narrator || tier == .lead) ? .healthy : .neutral,
                                    label: tier == .narrator
                                        ? "旁白"
                                        : (tier == .lead ? "主角 · \(archetype.shortBadgeTitle)" : archetype.shortBadgeTitle)
                                )

                                if binding != nil {
                                    StatusPill(
                                        tone: isCustomExclusiveVoice ? .healthy : .neutral,
                                        label: isCustomExclusiveVoice ? "专属定制" : "默认音色"
                                    )
                                }

                                Spacer(minLength: 0)

                                if !role.isNarrator {
                                    Text(dialogueCount > 0 ? "\(dialogueCount) 句" : "0 句")
                                        .font(SpeechRailDesignTokens.Typography.technical)
                                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                                }
                            }

                            if !role.aliases.isEmpty {
                                Text("别称：\(role.aliases.joined(separator: "、"))")
                                    .font(SpeechRailDesignTokens.Typography.caption)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityHint("选择此角色")

                // 音色选择胶囊 + 试听按钮 + 展开/折叠切换
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Button {
                        activeVoicePickerRoleID = (activeVoicePickerRoleID == role.id) ? nil : role.id
                    } label: {
                        let boundDisplay: String = {
                            guard let b = binding else { return voiceIsOptional ? "无台词，无需配声（可选）" : "选择音色…" }
                            let baseName: String
                            if let matched = allVoices.first(where: { $0.id == b.voiceID }) {
                                baseName = matched.name
                            } else if let preset = Self.fallbackPresetChoices.first(where: { $0.id == b.voiceID }) {
                                baseName = preset.name
                            } else {
                                baseName = b.voiceID
                            }
                            let speedSuffix = abs(b.allowedSpeed - 1.0) > 0.005
                                ? " · " + SpeechRailDisplayFormat.playbackRate(b.allowedSpeed)
                                : ""
                            let scopePrefix = (voiceMeta?.visibilityScope == .bookExclusive) ? "📘 " : ""
                            return "\(scopePrefix)\(baseName)\(speedSuffix)"
                        }()
                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Image(systemName: "waveform")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.voice)
                            Text(boundDisplay)
                                .font(SpeechRailDesignTokens.Typography.bodyMedium)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: SpeechRailDesignTokens.Spacing.micro)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .speechRailButton(.secondary)
                    .popover(
                        isPresented: Binding(
                            get: { activeVoicePickerRoleID == role.id },
                            set: { presented in
                                if !presented && activeVoicePickerRoleID == role.id {
                                    activeVoicePickerRoleID = nil
                                }
                            }
                        ),
                        arrowEdge: .leading
                    ) {
                        AudiobookVoicePickerPopover(
                            role: role,
                            archetype: archetype,
                            currentBinding: binding,
                            allVoices: allVoices,
                            activeBookVoices: activeBookVoices,
                            allCharacters: workflow.characters,
                            allBindings: workflow.voiceBindings,
                            fallbackPresets: Self.fallbackPresetChoices,
                            onSelectVoice: { voiceID in
                                activeVoicePickerRoleID = nil
                                if let stats = workflow.roleStatsByID[role.id],
                                   stats.dialogueAtomCount > 0
                                {
                                    pendingVoiceChange = PendingVoiceChange(
                                        roleID: role.id,
                                        voiceID: voiceID,
                                        roleName: role.displayName,
                                        dialogueCount: stats.dialogueAtomCount,
                                        chapterCount: stats.speakingChapterIDs.count
                                    )
                                } else {
                                    Task { await workflow.bindVoice(roleID: role.id, voiceID: voiceID) }
                                }
                            },
                            onChangeSpeed: { newSpeed in
                                Task { await workflow.updateRoleAllowedSpeed(roleID: role.id, speed: newSpeed) }
                            },
                            onDesignNewVoice: {
                                activeVoicePickerRoleID = nil
                                Task {
                                    if let ctx = await workflow.beginVoiceRoundTrip(for: role.id) {
                                        navigation.requestVoiceDesignForAudiobook(context: ctx)
                                    }
                                }
                            },
                            onRefreshVoices: {
                                _ = await workflow.refreshAvailableVoices()
                                await appModel.engine.refreshDiscovery()
                            }
                        )
                    }

                    // 试听按钮
                    if let b = binding {
                        let isAuditioning = workflow.isAuditionPlaying(for: role.id)
                            || (auditionPreviewRoleID == role.id && (appModel.previewingVoiceID == b.voiceID || appModel.playingVoiceID == b.voiceID))
                        let isLoading = auditionLoadingRoleID == role.id
                        Button {
                            if isAuditioning || isLoading {
                                cancelRoleAudition()
                            } else {
                                cancelRoleAudition()
                                let requestID = UUID()
                                auditionRequestID = requestID
                                auditionLoadingRoleID = role.id
                                Task {
                                    defer {
                                        if auditionRequestID == requestID {
                                            auditionLoadingRoleID = nil
                                        }
                                    }
                                    await workflow.prepareCastingAudition(kind: .sameTextComparison, roleID: role.id, comparisonVoiceIDs: [b.voiceID])
                                    guard auditionRequestID == requestID else { return }
                                    if workflow.castingAudition != nil && workflow.errorMessage == nil {
                                        auditionPreviewRoleID = role.id
                                        await workflow.playCastingAudition(itemIndex: 0)
                                        guard auditionRequestID == requestID else { return }
                                        if workflow.errorMessage != nil {
                                            auditionPreviewRoleID = nil
                                        }
                                    } else if workflow.errorMessage != nil,
                                              let creatorVoice = appModel.creatorVoices.first(where: { $0.id == b.voiceID }) {
                                        auditionPreviewRoleID = role.id
                                        appModel.startVoicePreview(creatorVoice)
                                    } else {
                                        auditionPreviewRoleID = nil
                                    }
                                }
                            }
                        } label: {
                            if isLoading {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: SpeechRailDesignTokens.Control.statusIconSize, height: SpeechRailDesignTokens.Control.statusIconSize)
                            } else {
                                Image(systemName: isAuditioning ? "stop.circle.fill" : "play.circle.fill")
                                    .font(SpeechRailDesignTokens.Typography.statusIcon)
                                    .foregroundStyle(
                                        isAuditioning
                                            ? SpeechRailDesignTokens.Color.attention
                                            : SpeechRailDesignTokens.Color.voice
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .help(isLoading ? "取消试听" : (isAuditioning ? "停止试听" : "试听当前音色"))
                        .accessibilityLabel(isLoading ? "取消试听" : (isAuditioning ? "停止试听" : "试听角色音色"))
                    }

                    // 展开/折叠按钮
                    Button {
                        withAnimation(SpeechRailDesignTokens.Motion.resolved(SpeechRailDesignTokens.Motion.panelTransition, reduceMotion: reduceMotion)) {
                            if expandedRoleIDs.contains(role.id) {
                                expandedRoleIDs.remove(role.id)
                            } else {
                                expandedRoleIDs.insert(role.id)
                            }
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    }
                    .speechRailButton(.quiet)
                    .accessibilityLabel(isExpanded ? "收起详情" : "展开详情")
                }

                // 同场冲突告警：始终警示或在展开时展示
                if hasConflict {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                        Text("与同场角色「\(conflictPartners.joined(separator: "、"))」共用声线，建议更换")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                            .lineLimit(2)
                    }
                    .padding(SpeechRailDesignTokens.Spacing.xs)
                    .background(SpeechRailDesignTokens.Color.attention.opacity(0.12), in: SpeechRailDesignTokens.Corner.nestedShape)
                }

                // 渐进式披露：声学画像、原文证据、专属定制菜单与次要共用开关
                if isExpanded {
                    Divider()

                    let persona = role.resolvedVoicePersona()
                    let personaHeadline = role.primaryVoiceTraitSummary
                        ?? "\(persona.ageGenderAnchor) · \(persona.pitchAndRegister)"
                    Text("声学画像：\(personaHeadline)")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .lineLimit(2)

                    if let firstEvidence = role.evidences.first {
                        Text("原文证据：「\(firstEvidence.quoteExcerpt)」")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            .lineLimit(2)
                    }

                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Menu {
                            Button {
                                Task { await workflow.prepareVoiceCreationDrafts(scope: .role(role.id)) }
                            } label: {
                                Label("准备专属音色…", systemImage: "sparkles")
                            }
                            .disabled(workflow.isCreatingLeadExclusiveVoices)

                            Button {
                                Task {
                                    if let ctx = await workflow.beginVoiceRoundTrip(for: role.id) {
                                        navigation.requestVoiceDesignForAudiobook(context: ctx)
                                    }
                                }
                            } label: {
                                Label("微调新音色…", systemImage: "slider.horizontal.3")
                            }
                        } label: {
                            Label("专属定制…", systemImage: "sparkles")
                        }
                        .speechRailButton(.secondary)
                        .fixedSize()

                        if workflow.fallbackRoleIDs.contains(role.id) {
                            Button {
                                Task { await workflow.prepareVoiceCreationDrafts(scope: .role(role.id)) }
                            } label: {
                                Label("重试专属音色", systemImage: "arrow.clockwise")
                            }
                            .speechRailButton(.secondary)
                            .disabled(workflow.isCreatingLeadExclusiveVoices)
                            .help("此前专属音色生成超时或未通过，当前已回退至群像音色，可点击重试。")
                        }

                        Spacer()

                        if !role.isNarrator {
                            Toggle(
                                "允许与次要角色共用同一声线",
                                isOn: Binding(
                                    get: { role.allowSharedMinorVoice },
                                    set: { allowed in
                                        Task { await workflow.toggleSharedMinorVoice(roleID: role.id, allowed: allowed) }
                                    }
                                )
                            )
                            .toggleStyle(.checkbox)
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        }
                    }
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    private static let fallbackPresetChoices: [(id: String, name: String)] = [
        ("v-narrator", "默认沉稳旁白"),
        ("uncle_fu", "醇厚中文男声"),
        ("serena", "温柔中文女声"),
        ("vivian", "明亮中文女声"),
        ("dylan", "北京青年男声"),
        ("eric", "成都活力男声")
    ]

    // MARK: - Helpers

    private func triggerPrimaryAction(
        _ action: AudiobookWorkflowModel.PrimaryBookAction,
        bookID: UUID
    ) {
        switch action {
        case .analyzeWholeBook, .resumeAnalysis:
            workflow.beginAnalysis(bookID)
        case .pauseAnalysis:
            Task { await workflow.pauseAnalysis() }
        case .confirmSpeakers:
            workflow.workbenchTab = .preparation
        case .confirmCastAndVoices:
            if workflow.hasMissingVoiceCreationDrafts {
                workflow.isShowingVoicePreparationSheet = true
            } else if workflow.castingPlanNeedsSeparateConfirmation {
                workflow.isCastInspectorPresented = true
            } else {
                Task { await workflow.autoAssignRecommendedVoices(consentsToSharedMinorVoices: true) }
            }
        case .makeConfirmedChapters:
            workflow.workbenchTab = .production
            Task { await workflow.prepareProduction(intent: .missingOnly) }
        case .resumeProduction:
            workflow.workbenchTab = .production
            Task { await workflow.prepareResumeProduction() }
        case .pauseProduction:
            Task { await workflow.pauseProduction() }
        case .reviewCandidates:
            workflow.reviewProductionCandidates()
        case .continueListening:
            Task { await workflow.startListening() }
        }
    }

    private func analysisStatusPill(for state: AudiobookAnalysisState) -> StatusPill {
        if workflow.isAnalyzing, let progress = workflow.analysisProgress {
            return StatusPill(tone: .attention, label: analysisPillLabel(for: progress))
        }
        if workflow.isAnalyzing {
            return StatusPill(tone: .attention, label: "正在分析全书…")
        }
        return switch state {
        case .notStarted:
            StatusPill(tone: .neutral, label: "待分析全书")
        case .running:
            StatusPill(tone: .attention, label: "正在分析全书…")
        case .paused:
            StatusPill(tone: .attention, label: "分析已暂停")
        case .failed:
            StatusPill(tone: .critical, label: "分析需重试")
        case .allWindowsValidated:
            StatusPill(tone: .healthy, label: "全书分析已完成")
        }
    }

    /// 顶栏胶囊的活文案：阶段人话 + n/N（用户语言，技术量进下面的轨道与开发者详情）。
    private func analysisPillLabel(for progress: AudiobookAnalysisProgress) -> String {
        AudiobookAnalysisProgressRailView.pillLabel(for: progress)
    }

    // MARK: - Analysis Progress Rail（确定性轨道：阶段 + n/N + 百分比 + 心跳）

    @ViewBuilder
    private var analysisProgressRail: some View {
        if let progress = workflow.analysisProgress {
            AudiobookAnalysisTimedRail(
                progress: progress,
                stoppedAt: workflow.analysisClockStoppedAt,
                eventCount: workflow.analysisEventBuffer.events.count,
                showDeveloperDetails: showAnalysisDeveloperDetails,
                isDeveloperSectionExpanded: $isAnalysisDevSectionExpanded
            ) {
                Task { await workflow.pauseAnalysis() }
            }
        }
    }

    private func chapterReadinessBadge(for state: AudiobookChapterReadinessState) -> StatusPill {
        switch state {
        case .awaitingGlobalAnalysis:
            StatusPill(tone: .neutral, label: "待分析")
        case .awaitingCastConfirmation:
            StatusPill(tone: .neutral, label: "待配声")
        case .blockedByUnknownSpeakers:
            StatusPill(tone: .attention, label: "待确认说话人")
        case .readyForProduction:
            StatusPill(tone: .healthy, label: "可制作")
        case .producing:
            StatusPill(tone: .attention, label: "制作中")
        case .paused:
            StatusPill(tone: .attention, label: "已暂停")
        case .needsUpdate:
            StatusPill(tone: .attention, label: "待更新")
        case .chapterAudioReady:
            StatusPill(tone: .healthy, label: "已成片")
        case .skipped:
            StatusPill(tone: .neutral, label: "已跳过")
        case .failed:
            StatusPill(tone: .critical, label: "需重试")
        }
    }
}

private struct AudiobookCastingReview: View {
    @Bindable var workflow: AudiobookWorkflowModel
    @State private var acknowledgements: Set<UUID> = []
    @State private var isDetailsPresented = false

    var body: some View {
        if let plan = workflow.pendingCastingPlan, let recommendation = workflow.castingRecommendation {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                Text("本次将调整 \(recommendation.affectedRoleIDs.count) 个角色、\(recommendation.affectedFragmentIDs.count) 个片段的配声。")
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                Text("已采用的音频和历史候选会保留。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                if workflow.castingPlanNeedsRefresh {
                    Text("声音目录已变化，请重新推荐。")
                        .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                }
                if let progress = workflow.castVoiceValidationProgress {
                    Text(progress).font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
                // One row per distinct action: a stale cast fails on every role at once,
                // so repeating the same sentence hides the single decision to make.
                ForEach(Self.groups(plan.issues)) { group in
                    if group.isBlocking {
                        Text(group.label).foregroundStyle(SpeechRailDesignTokens.Color.attention)
                    } else if group.severity == .warning {
                        Toggle(isOn: Binding(
                            get: { group.issueIDs.allSatisfy(acknowledgements.contains) },
                            set: { accepted in
                                if accepted { acknowledgements.formUnion(group.issueIDs) }
                                else { acknowledgements.subtract(group.issueIDs) }
                            }
                        )) {
                            Text(group.label)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                Button("试听与分配说明", systemImage: "info.circle") {
                    isDetailsPresented = true
                }
                .speechRailButton(.quiet)
                .accessibilityIdentifier("audiobook-casting-details-button")
                .popover(isPresented: $isDetailsPresented, arrowEdge: .top) {
                    AudiobookCastingDetailsPanel(onClose: { isDetailsPresented = false }) {
                        LazyVStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                            ForEach(workflow.characters.filter { recommendation.affectedRoleIDs.contains($0.id) }) { role in
                                Text("\(role.displayName)：\((recommendation.reasonsByRoleID[role.id] ?? []).joined(separator: "；"))")
                                    .font(SpeechRailDesignTokens.Typography.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    } actions: {
                        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                            Menu("选择角色准备试听") {
                                ForEach(workflow.characters.filter { plan.proposedBindings[$0.id] != nil }) { role in
                                    Button("\(role.displayName) · 同文对比") {
                                        var voices = [plan.proposedBindings[role.id]?.voiceID, workflow.voiceBindings[role.id]?.voiceID].compactMap { $0 }
                                        if voices.count < 2 {
                                            voices += plan.snapshot.voices.filter { plan.catalog.permits($0, bookID: plan.bookID) && !voices.contains($0.id) }.prefix(1).map(\.id)
                                        }
                                        Task { await workflow.prepareCastingAudition(kind: .sameTextComparison, roleID: role.id, comparisonVoiceIDs: voices) }
                                    }
                                    if !role.isNarrator {
                                        Button("\(role.displayName) · 相邻对白") {
                                            Task { await workflow.prepareCastingAudition(kind: .dialogueComparison, roleID: role.id) }
                                        }
                                    }
                                }
                            }
                            if let audition = workflow.castingAudition {
                                ForEach(Array(audition.items.enumerated()), id: \.offset) { index, item in
                                    Button("试听 \(index + 1) · \(plan.snapshot.voices.first { $0.id == item.voiceID }?.name ?? "所选声音")") {
                                        Task { await workflow.playCastingAudition(itemIndex: index) }
                                    }.speechRailButton(.secondary)
                                }
                            }
                            Button("使用基础推荐重新生成方案") {
                                Task { await workflow.previewRecommendedVoices(strategy: .baseline) }
                            }.speechRailButton(.quiet)
                        }
                    }
                }
                HStack {
                    Button("重新推荐") { Task { await workflow.previewRecommendedVoices() } }
                        .speechRailButton(.secondary)
                        .disabled(workflow.isAssigningRecommendedVoices)
                    if !plan.voicesNeedingValidation.isEmpty {
                        Button(workflow.isRevalidatingCastVoices ? "正在验收…" : "重新验收这些音色") {
                            Task { await workflow.revalidateCastVoices(plan.voicesNeedingValidation) }
                        }
                        .speechRailButton(.secondary)
                        .disabled(workflow.isRevalidatingCastVoices)
                        .help("按当前引擎重新跑一次输出验收；声音和已采用音频都不会改变")
                    }
                    Spacer()
                    Button("应用配声方案") { Task { await workflow.applyPendingCastingPlan(acknowledgedIssueIDs: acknowledgements) } }
                        .speechRailButton(.primary)
                        .disabled(workflow.isAssigningRecommendedVoices || !recommendation.isApplicable || workflow.castingPlanNeedsRefresh || !plan.requiredAcknowledgements.isSubset(of: acknowledgements))
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.sm)
        }
    }

    private struct IssueGroup: Identifiable {
        let id: String
        let issueIDs: [UUID]
        let roleCount: Int
        let isBlocking: Bool
        let severity: AudiobookCastingIssue.Severity
        let nextAction: String
        var label: String { roleCount > 1 ? "\(roleCount) 个角色：\(nextAction)" : nextAction }
    }

    private static func groups(_ issues: [AudiobookCastingIssue]) -> [IssueGroup] {
        struct Draft { var issueIDs: [UUID] = []; var roles: Set<UUID> = [] }
        var order: [String] = []
        var drafts: [String: Draft] = [:]
        var firstIssue: [String: AudiobookCastingIssue] = [:]
        for issue in issues {
            let key = "\(issue.code.rawValue)|\(issue.isBlocking)|\(issue.severity.rawValue)|\(issue.nextAction)"
            if drafts[key] == nil { order.append(key); drafts[key] = Draft(); firstIssue[key] = issue }
            drafts[key]?.issueIDs.append(issue.id)
            drafts[key]?.roles.formUnion(issue.roleIDs)
        }
        return order.compactMap { key in
            guard let draft = drafts[key], let first = firstIssue[key] else { return nil }
            return IssueGroup(id: key, issueIDs: draft.issueIDs,
                roleCount: max(draft.roles.count, draft.issueIDs.count),
                isBlocking: first.isBlocking, severity: first.severity, nextAction: first.nextAction)
        }
    }
}

// MARK: - 音色搜索与试听选择器

private struct AudiobookVoicePickerPopover: View {
    @Environment(AppModel.self) private var appModel

    enum ScopeFilter: String, CaseIterable, Identifiable {
        case all = "all"
        case matchedArchetype = "matched"
        case bookExclusive = "book_exclusive"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "本书可用"
            case .matchedArchetype: return "智能匹配声部"
            case .bookExclusive: return "定制与群像"
            }
        }
    }

    let role: AudiobookCharacter
    let archetype: AudiobookVoiceArchetype
    let currentBinding: AudiobookVoiceBinding?
    let allVoices: [SafeVoiceEntry]
    let activeBookVoices: [SafeVoiceEntry]
    let allCharacters: [AudiobookCharacter]
    let allBindings: [UUID: AudiobookVoiceBinding]
    let fallbackPresets: [(id: String, name: String)]
    let onSelectVoice: (String) -> Void
    let onChangeSpeed: (Double) -> Void
    let onDesignNewVoice: () -> Void
    let onRefreshVoices: () async -> Void

    @State private var searchQuery: String = ""
    @State private var scopeFilter: ScopeFilter = .all
    @State private var favoritesOnly = false
    @State private var catalogSaveError: String?

    private static let microSpeedPresets: [Double] = [0.92, 0.96, 1.00, 1.04, 1.08]

    private var filteredVoices: [SafeVoiceEntry] {
        let catalog = appModel.voiceCatalogModel.snapshot
        let metadataMap = catalog.state.metadataByVoiceID
        let sourcePool = allVoices.filter { $0.available && catalog.permits($0, bookID: role.bookID) }

        let byScope = sourcePool.filter { voice in
            let meta = metadataMap[voice.id]
            let voiceArch = AudiobookCastRegistry.resolveVoiceArchetype(for: voice, metadata: meta)
            guard !favoritesOnly || meta?.isFavorite == true else { return false }
            switch scopeFilter {
            case .all:
                return true
            case .matchedArchetype:
                return voiceArch == archetype
                    || meta?.originRoleID == role.id
            case .bookExclusive:
                return meta?.visibilityScope == .bookExclusive
            }
        }
        let sortedCandidates = byScope.sorted { lhs, rhs in
            let metaL = metadataMap[lhs.id]
            let metaR = metadataMap[rhs.id]
            let roleMatchL = (metaL?.originRoleID == role.id)
            let roleMatchR = (metaR?.originRoleID == role.id)
            if roleMatchL != roleMatchR { return roleMatchL }

            let bookMatchL = (metaL?.originBookID == role.bookID)
            let bookMatchR = (metaR?.originBookID == role.bookID)
            if bookMatchL != bookMatchR { return bookMatchL }

            let archMatchL = (AudiobookCastRegistry.resolveVoiceArchetype(for: lhs, metadata: metaL) == archetype)
            let archMatchR = (AudiobookCastRegistry.resolveVoiceArchetype(for: rhs, metadata: metaR) == archetype)
            if archMatchL != archMatchR { return archMatchL }

            let customL = !AudiobookWorkflowModel.builtInSystemVoiceIDs.contains(lhs.id.lowercased())
            let customR = !AudiobookWorkflowModel.builtInSystemVoiceIDs.contains(rhs.id.lowercased())
            if customL != customR { return customL }

            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return sortedCandidates }
        return sortedCandidates.filter { voice in
            let meta = metadataMap[voice.id]
            let arch = AudiobookCastRegistry.resolveVoiceArchetype(for: voice, metadata: meta)
            return voice.name.localizedCaseInsensitiveContains(q)
                || voice.id.localizedCaseInsensitiveContains(q)
                || arch.shortBadgeTitle.localizedCaseInsensitiveContains(q)
                || (meta?.originRoleName?.localizedCaseInsensitiveContains(q) == true)
        }
    }

    @State private var hoveredVoiceID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text("为「\(role.displayName)」选择音色")
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(1)
                StatusPill(tone: .neutral, label: archetype.shortBadgeTitle)
                Spacer()
                Text("\(filteredVoices.count) 个可选")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }

            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                TextField("搜索音色名称、声部行当或关联角色…", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                }
            }
            .speechRailSingleLineInput(.compact)

            Picker("音色范围", selection: $scopeFilter) {
                ForEach(ScopeFilter.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Toggle("仅收藏", isOn: $favoritesOnly).toggleStyle(.checkbox)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                    if filteredVoices.isEmpty {
                        VStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Text("当前筛选条件下没有匹配音色")
                                .font(SpeechRailDesignTokens.Typography.bodyMedium)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            Text("可切换至「本书可用」、刷新声音或设计新声音。")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, SpeechRailDesignTokens.Spacing.xl)
                    } else {
                        let holdersMap = holdersByVoiceID
                        ForEach(filteredVoices) { voice in
                            voiceRow(for: voice, holdersMap: holdersMap)
                        }
                    }
                }
            }
            .frame(height: SpeechRailDesignTokens.Layout.creatorVoicePopoverHeight)

            if let b = currentBinding {
                Divider()
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Text("微语速：")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    ForEach(Self.microSpeedPresets, id: \.self) { speed in
                        let isSelected = abs(b.allowedSpeed - speed) < 0.015
                        Button(SpeechRailDisplayFormat.playbackRate(speed)) {
                            onChangeSpeed(speed)
                        }
                        .speechRailButton(isSelected ? .primary : .quiet)
                    }
                    Spacer()
                }

                if let meta = appModel.voiceCatalogModel.metadata(for: b.voiceID),
                   meta.visibilityScope == .bookExclusive
                {
                    HStack {
                        Text("来源：\(meta.originBookTitle ?? "剧组创作") · 可跨作品复用")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        Spacer()
                        Button("设为通用声音") {
                            saveCatalogChange { _ = try await appModel.voiceCatalogModel.store.promoteToGlobalReusable(voiceID: b.voiceID) }
                        }
                        .speechRailButton(.quiet)
                    }
                }
            }

            Divider()

            Button {
                onDesignNewVoice()
            } label: {
                HStack {
                    Label("为「\(role.displayName)」AI 设计专属新音色…", systemImage: "sparkles")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                }
                .frame(maxWidth: .infinity)
            }
            .speechRailButton(.secondary)
        }
        .padding(SpeechRailDesignTokens.Spacing.md)
        .frame(width: SpeechRailDesignTokens.Layout.Sheet.compactWidth)
        .operationFeedback([OperationFeedback(catalogSaveError, title: "音色目录未保存",
            onDismiss: { catalogSaveError = nil })])
        .task {
            await onRefreshVoices()
        }
    }

    private func saveCatalogChange(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await action()
                await appModel.voiceCatalogModel.refresh()
                catalogSaveError = nil
            } catch { catalogSaveError = error.localizedDescription }
        }
    }

    private var holdersByVoiceID: [String: [AudiobookCharacter]] {
        let charsByID = Dictionary(uniqueKeysWithValues: allCharacters.map { ($0.id, $0) })
        var grouped: [String: [AudiobookCharacter]] = [:]
        for (rid, b) in allBindings where rid != role.id {
            if let holder = charsByID[rid] {
                grouped[b.voiceID, default: []].append(holder)
            }
        }
        return grouped
    }

    @ViewBuilder
    private func voiceRow(for voice: SafeVoiceEntry, holdersMap: [String: [AudiobookCharacter]]) -> some View {
        let meta = appModel.voiceCatalogModel.metadata(for: voice.id)
        let voiceArch = AudiobookCastRegistry.resolveVoiceArchetype(for: voice, metadata: meta)
        let isBoundToSelf = (currentBinding?.voiceID == voice.id)
        let otherHolders = holdersMap[voice.id] ?? []
        let lockedByExclusiveLead = otherHolders.first(where: { $0.isNarrator || $0.effectiveVoicePolicy.sharingPolicy != .sharedMinor })
        let isHovered = hoveredVoiceID == voice.id

        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Button {
                saveCatalogChange { _ = try await appModel.voiceCatalogModel.store.toggleFavorite(voiceID: voice.id) }
            } label: {
                Image(systemName: meta?.isFavorite == true ? "star.fill" : "star")
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .foregroundStyle(
                        meta?.isFavorite == true
                            ? SpeechRailDesignTokens.Color.voice
                            : SpeechRailDesignTokens.Color.inkTertiary
                    )
                    .frame(
                        width: SpeechRailDesignTokens.Icon.navigationFrame,
                        height: SpeechRailDesignTokens.Icon.navigationFrame
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(meta?.isFavorite == true ? "取消收藏" : "收藏音色")

            Button {
                onSelectVoice(voice.id)
            } label: {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                        Text(voice.name)
                            .font(SpeechRailDesignTokens.Typography.bodyMedium)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                            .lineLimit(1)
                        StatusPill(tone: .neutral, label: voiceArch.shortBadgeTitle)
                        if meta?.visibilityScope == .bookExclusive {
                            StatusPill(tone: .healthy, label: "剧组来源 · 可复用")
                        }
                        if isBoundToSelf {
                            StatusPill(tone: .healthy, label: "当前绑定")
                        }
                    }

                    HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                        if let exclusiveHolder = lockedByExclusiveLead {
                            Text("主角「\(exclusiveHolder.displayName)」独占")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                        } else if !otherHolders.isEmpty {
                            Text("配角共享 ×\(otherHolders.count)（\(otherHolders.prefix(2).map(\.displayName).joined(separator: "、"))）")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        } else {
                            Text("空闲可用 · \(voice.mode == "system" ? "系统支持微变速" : "定制声线")")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let creatorVoice = appModel.creatorVoices.first(where: { $0.id == voice.id }) {
                let isPreviewing = appModel.previewingVoiceID == voice.id
                Button {
                    if isPreviewing {
                        appModel.cancelVoicePreview()
                    } else {
                        appModel.startVoicePreview(creatorVoice)
                    }
                } label: {
                    Image(systemName: isPreviewing ? "stop.circle.fill" : "play.circle.fill")
                        .font(SpeechRailDesignTokens.Typography.statusIcon)
                        .foregroundStyle(
                            isPreviewing
                                ? SpeechRailDesignTokens.Color.attention
                                : SpeechRailDesignTokens.Color.voice
                        )
                }
                .buttonStyle(.plain)
                .help(isPreviewing ? "停止试听" : "试听该音色")
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
        .background(
            isBoundToSelf
                ? SpeechRailDesignTokens.Color.rail.opacity(0.12)
                : (isHovered ? SpeechRailDesignTokens.Color.recessedField : Color.clear),
            in: SpeechRailDesignTokens.Corner.controlShape
        )
        .onHover { hovering in
            hoveredVoiceID = hovering ? voice.id : nil
        }
    }
}

/// A draft is kept in Workflow so a view refresh cannot lose unsaved text.
private struct AudiobookChapterEditingSheet: View {
    @Bindable var workflow: AudiobookWorkflowModel
    let draft: AudiobookChapterEditDraft
    @State private var isConfirmingDiscard = false
    @FocusState private var focusedField: Field?
    private enum Field { case title, body }

    private var hasChanges: Bool {
        draft.hasChanges(title: workflow.chapterEditTitle, body: workflow.chapterEditBody)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            SpeechRailSheetHeader(
                title: "编辑章节",
                subtitle: "保存后的内容将用于后续分析与配音。原始导入内容保留供参考。",
                onClose: { requestClose() }
            )
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text("章节标题")
                TextField("章节标题", text: $workflow.chapterEditTitle)
                    .speechRailSingleLineInput(.regular)
                    .focused($focusedField, equals: .title)
                    .accessibilityIdentifier("audiobook-chapter-edit-title")
                    .disabled(workflow.isSavingChapterEdit)
                Text("章节标题用于目录和导出；正文中的标题行可在下方单独修改。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text("正文")
                TextEditor(text: $workflow.chapterEditBody)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .scrollContentBackground(.hidden)
                    .padding(SpeechRailDesignTokens.Spacing.xs)
                    .speechRailRecessedSlot()
                    .focused($focusedField, equals: .body)
                    .accessibilityLabel("章节正文")
                    .accessibilityIdentifier("audiobook-chapter-edit-body")
            }
            .frame(maxHeight: .infinity)
            .disabled(workflow.isSavingChapterEdit)
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                if workflow.isSavingChapterEdit {
                    ProgressView().controlSize(.small)
                    Text("正在保存…")
                }
                Spacer()
                Button("取消") { requestClose() }
                    .speechRailButton(.secondary)
                    .keyboardShortcut(.cancelAction)
                    .disabled(workflow.isSavingChapterEdit)
                Button("保存更改") {
                    Task {
                        await workflow.saveChapterEditing(title: workflow.chapterEditTitle, body: workflow.chapterEditBody)
                    }
                }
                .speechRailButton(.primary)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(workflow.isSavingChapterEdit
                    || workflow.chapterEditTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || workflow.chapterEditBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("audiobook-chapter-edit-save")
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .frame(width: SpeechRailDesignTokens.Layout.Sheet.prominentWidth,
               height: SpeechRailDesignTokens.Layout.audiobookCastingDetailsHeight)
        .interactiveDismissDisabled(hasChanges || workflow.isSavingChapterEdit)
        .confirmationDialog("放弃尚未保存的章节修改？", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
            Button("放弃更改", role: .destructive) { workflow.cancelChapterEditing() }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("已保存的正文和原始导入内容不会改变。")
        }
        .operationFeedback([OperationFeedback(workflow.chapterEditError, title: "章节未保存")])
        .task { focusedField = .body }
    }

    private func requestClose() {
        if hasChanges { isConfirmingDiscard = true }
        else { workflow.cancelChapterEditing() }
    }
}


/// Frozen book/range preview; editable choices stay local until explicit confirmation.
private struct AudiobookProductionConfirmationSheet<Content: View>: View {
    let title: String
    let impact: String
    let summary: String
    let confirmationTitle: String
    let canConfirm: Bool
    let errorMessage: String?
    let availableSize: CGSize
    let onConfirm: () -> Void
    let onEnqueue: (() -> Void)?
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isContentFocused: Bool

    /// 显式初始化让「加入队列」可以是可选的，同时保留尾随闭包的 content。
    init(
        title: String,
        impact: String,
        summary: String,
        confirmationTitle: String,
        canConfirm: Bool,
        errorMessage: String?,
        availableSize: CGSize,
        onConfirm: @escaping () -> Void,
        onEnqueue: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.impact = impact
        self.summary = summary
        self.confirmationTitle = confirmationTitle
        self.canConfirm = canConfirm
        self.errorMessage = errorMessage
        self.availableSize = availableSize
        self.onConfirm = onConfirm
        self.onEnqueue = onEnqueue
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            SpeechRailSheetHeader(
                title: title,
                subtitle: impact,
                onClose: { dismiss() }
            )
            ScrollView {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SpeechRailDesignTokens.Spacing.xs)
            }
            .focusable(interactions: .edit)
            .focused($isContentFocused)
            Text(summary)
                .font(SpeechRailDesignTokens.Typography.caption)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("audiobook-production-plan-summary")
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                Button("取消", role: .cancel) { dismiss() }
                    .speechRailButton(.secondary)
                    .keyboardShortcut(.cancelAction)
                if let onEnqueue {
                    Button("加入制作队列", action: onEnqueue)
                        .speechRailButton(.secondary)
                        .disabled(!canConfirm)
                        .accessibilityIdentifier("audiobook-production-plan-enqueue")
                }
                Spacer()
                Button(confirmationTitle, action: onConfirm)
                    .speechRailButton(.primary)
                    .disabled(!canConfirm)
                    .accessibilityIdentifier("audiobook-production-plan-confirm")
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.md)
        .frame(width: min(SpeechRailDesignTokens.Layout.Sheet.prominentWidth,
                          max(0, availableSize.width - SpeechRailDesignTokens.Spacing.lg)),
               height: min(SpeechRailDesignTokens.Layout.audiobookCastingDetailsHeight,
                           max(0, availableSize.height - SpeechRailDesignTokens.Spacing.lg)))
        .operationFeedback([OperationFeedback(errorMessage)])
        .defaultFocus($isContentFocused, true)
        .onExitCommand { dismiss() }
        .task { isContentFocused = true }
    }
}

private struct AudiobookProductionPlanSheet: View {
    let workflow: AudiobookWorkflowModel
    let plan: AudiobookProductionPlan
    let availableSize: CGSize

    var body: some View {
        if plan.fragments.isEmpty {
            AudiobookProductionEmptySheet(workflow: workflow, plan: plan, availableSize: availableSize)
        } else {
            confirmation
        }
    }

    private var confirmation: some View {
        let grouped = Dictionary(grouping: plan.fragments, by: \.chapterID)
        return AudiobookProductionConfirmationSheet(
            title: plan.intent.title, impact: plan.intent.impact,
            summary: "将生成 \(plan.fragments.count) 段音频，涉及 \(grouped.count) 章。确认后仅处理下列范围。",
            confirmationTitle: plan.intent == .missingOnly ? "确认只补 \(plan.fragments.count) 段" : "确认更新 \(plan.fragments.count) 段",
            canConfirm: !plan.fragments.isEmpty && !workflow.isProductionBusy && !workflow.isAnalyzing && !workflow.isEditingChapterLayout,
            errorMessage: workflow.errorMessage, availableSize: availableSize,
            onConfirm: { workflow.confirmProduction(plan) },
            onEnqueue: { workflow.enqueueConfirmedProduction(plan) }
        ) {
            Text("已核对 \(plan.chapterIDs.count) 个已就绪章节；保留已有音频 \(plan.preservedAudioCount) 段。")
            if plan.intent == .missingOnly {
                Text("其中 \(plan.preservedOutdatedAudioCount) 段待更新的旧音频也会保留。历史片段边界变化时保守保留，请单独选择更新。")
            } else {
                Text("缺失音频 \(plan.missingAudioCount) 段保持不处理；需要补齐时单独选择“只补缺失音频”。")
            }
            if workflow.selectedBook?.productionState == .paused {
                NoticeBar(tone: .warning, message: "当前有已暂停任务。确认此新操作会替换原任务的续作记录，已保存的音频和历史版本全部保留。")
            }
            ForEach(plan.chapterIDs, id: \.self) { chapterID in
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Text(plan.chapterTitles[chapterID, default: "章节"])
                    Text(grouped[chapterID, default: []].isEmpty
                         ? "本章没有需要执行此操作的片段，将保持原样。"
                         : "本章将生成 \(grouped[chapterID, default: []].count) 段。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    if let fragments = grouped[chapterID], !fragments.isEmpty {
                        DisclosureGroup("查看目标片段") {
                            ForEach(fragments) { fragment in
                                Text("第 \(fragment.ordinal + 1) 段 · \(workflow.charactersByID[fragment.roleID]?.displayName ?? "朗读")")
                                    .font(SpeechRailDesignTokens.Typography.caption)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// A completed check needs an acknowledgement, not a disabled production action.
private struct AudiobookProductionEmptySheet: View {
    let workflow: AudiobookWorkflowModel
    let plan: AudiobookProductionPlan
    let availableSize: CGSize
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isDoneFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            SpeechRailSheetHeader(
                title: plan.intent == .missingOnly ? "没有缺失音频" : "没有待更新音频",
                isCompact: true,
                onClose: { dismiss() }
            )
            ScrollView {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                    if plan.preservedAudioCount > 0 {
                        Text("已有 \(plan.preservedAudioCount) 段音频已全部保留，无需生成。")
                    } else {
                        Text("本次检查没有需要处理的音频。")
                    }
                    if plan.intent == .updateOutdated, plan.missingAudioCount > 0 {
                        Text("另有 \(plan.missingAudioCount) 段缺失音频，可在“只补缺失音频”中单独预览。")
                    }
                    if plan.intent == .missingOnly, plan.preservedOutdatedAudioCount > 0 {
                        Text("其中 \(plan.preservedOutdatedAudioCount) 段待更新。查看后还需单独确认，才会生成新候选。")
                    }
                }
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: min(SpeechRailDesignTokens.Layout.Sheet.messageBodyMaximumHeight,
                                  max(0, availableSize.height - SpeechRailDesignTokens.Spacing.lg)))
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                if plan.intent == .missingOnly, plan.preservedOutdatedAudioCount > 0 {
                    Button(workflow.isPreparingProduction ? "正在核对…" : "查看待更新音频") {
                        Task { await workflow.previewOutdatedAudio(from: plan) }
                    }
                    .speechRailButton(.secondary)
                    .disabled(workflow.isPreparingProduction || workflow.isProductionBusy || workflow.isAnalyzing || workflow.isEditingChapterLayout)
                    .accessibilityIdentifier("audiobook-production-view-outdated")

                    Button("重新制作未就绪片段…") {
                        Task { @MainActor in
                            workflow.productionDraft = nil
                            await workflow.prepareRegenerationForRedoFragments()
                        }
                    }
                    .speechRailButton(.secondary)
                    .disabled(workflow.isPreparingProduction || workflow.isPreparingRegeneration || workflow.isProductionBusy || workflow.isAnalyzing || workflow.isEditingChapterLayout)
                    .accessibilityIdentifier("audiobook-production-regenerate-outdated")
                }
                Spacer()
                Button("完成") { dismiss() }
                    .speechRailButton(.primary)
                    .keyboardShortcut(.defaultAction)
                    .focused($isDoneFocused)
                    .accessibilityIdentifier("audiobook-production-empty-done")
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.md)
        .frame(width: min(SpeechRailDesignTokens.Layout.Sheet.compactWidth,
                          max(0, availableSize.width - SpeechRailDesignTokens.Spacing.lg)))
        .operationFeedback([OperationFeedback(workflow.errorMessage, onDismiss: { workflow.errorMessage = nil })])
        .defaultFocus($isDoneFocused, true)
        .onExitCommand { dismiss() }
        .task { isDoneFocused = true }
    }
}

private struct AudiobookProductionResumeSheet: View {
    let workflow: AudiobookWorkflowModel
    let checkpoint: AudiobookProductionCheckpoint
    let availableSize: CGSize

    var body: some View {
        let intent = checkpoint.productionPlan?.intent ?? .regenerate
        AudiobookProductionConfirmationSheet(
            title: "继续：\(intent.title)", impact: intent.impact,
            summary: "原任务共 \(checkpoint.chapterIDs.count) 章、\(checkpoint.progress.totalFragments) 段；核对并复用本任务已保存的结果后继续。",
            confirmationTitle: "确认按原范围继续", canConfirm: !workflow.isProductionBusy && !workflow.isEditingChapterLayout && !workflow.isAnalyzing,
            errorMessage: workflow.errorMessage, availableSize: availableSize,
            onConfirm: { Task { await workflow.confirmResumeProduction(checkpoint) } }
        ) {
            Text("仅继续上次确认的片段，不扩大到后来新增的缺失或待更新内容。制作条件变化时会停止并要求重新预览。")
            ForEach(checkpoint.chapterIDs, id: \.self) { chapterID in
                Text(checkpoint.productionPlan?.chapterTitles[chapterID]
                     ?? workflow.chapters.first { $0.id == chapterID }?.title ?? "原任务章节")
            }
        }
    }
}

private struct AudiobookRegenerationSheet: View {
    @Bindable var workflow: AudiobookWorkflowModel
    let draft: AudiobookRegenerationDraft
    let availableSize: CGSize
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isContentFocused: Bool
    @State private var scope: Scope = .currentChapter
    @State private var chapterIDs: Set<UUID>
    @State private var fragmentIDs: Set<UUID>

    private enum Scope: String, CaseIterable, Identifiable {
        case fragments = "所选片段"
        case currentChapter = "当前章节"
        case chapters = "勾选章节"
        case wholeBook = "整本书"
        var id: String { rawValue }
    }

    init(workflow: AudiobookWorkflowModel, draft: AudiobookRegenerationDraft, availableSize: CGSize) {
        self.workflow = workflow
        self.draft = draft
        self.availableSize = availableSize
        _chapterIDs = State(initialValue: draft.blockedChapterReasons[draft.defaultChapterID] == nil ? [draft.defaultChapterID] : [])
        _scope = State(initialValue: draft.initialFragmentIDs == nil ? .currentChapter : .fragments)
        let initialFragment = draft.fragmentsByChapter[draft.defaultChapterID, default: []]
            .first { $0.id == workflow.selectedFragmentID }
        _fragmentIDs = State(initialValue: draft.initialFragmentIDs ?? initialFragment.map { [$0.id] } ?? [])
    }

    private var targetChapterIDs: Set<UUID> {
        switch scope {
        case .fragments:
            let matched = Set(draft.chapters.map(\.id).filter { chID in
                draft.fragmentsByChapter[chID, default: []].contains { fragmentIDs.contains($0.id) }
            })
            return matched.isEmpty ? [draft.defaultChapterID] : matched
        case .currentChapter: return [draft.defaultChapterID]
        case .chapters: return chapterIDs
        case .wholeBook: return Set(draft.chapters.map(\.id))
        }
    }

    private var blockedChapters: [AudiobookChapter] {
        draft.chapters.filter { targetChapterIDs.contains($0.id) && draft.blockedChapterReasons[$0.id] != nil }
    }

    private var fragmentCount: Int {
        if scope == .fragments { return fragmentIDs.count }
        return targetChapterIDs.reduce(0) { $0 + draft.fragmentsByChapter[$1, default: []].count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            SpeechRailSheetHeader(
                title: "重新制作",
                subtitle: AudiobookProductionIntent.regenerate.impact,
                onClose: { dismiss() }
            )
            ScrollView {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
                    if workflow.selectedBook?.productionState == .paused {
                        NoticeBar(tone: .warning, message: "确认重新制作会替换已暂停任务的续作记录，已保存的音频和历史版本全部保留。")
                    }
                    Picker("重新制作范围", selection: $scope) {
                        ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    scopeChoices
                    ForEach(blockedChapters) { chapter in
                        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Label(chapter.title, systemImage: "exclamationmark.circle")
                            Text(draft.blockedChapterReasons[chapter.id, default: "请先完成准备。"])
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !blockedChapters.isEmpty {
                        Button("去处理未准备好的章节") {
                            if let chapter = blockedChapters.first { workflow.selectedChapterID = chapter.id }
                            workflow.workbenchTab = .preparation
                            dismiss()
                        }
                        .speechRailButton(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SpeechRailDesignTokens.Spacing.xs)
            }
            .focusable(interactions: .edit)
            .focused($isContentFocused)
            Text("将重新制作 \(targetChapterIDs.count) 章、\(fragmentCount) 个片段。")
                .font(SpeechRailDesignTokens.Typography.caption)
                .accessibilityIdentifier("audiobook-regeneration-summary")
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                Button("取消", role: .cancel) { dismiss() }
                    .speechRailButton(.secondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("确认重新制作") {
                    workflow.confirmRegeneration(draft: draft, chapterIDs: targetChapterIDs,
                        fragmentIDs: scope == .fragments ? fragmentIDs : nil)
                }
                .speechRailButton(.primary)
                .disabled(fragmentCount == 0 || targetChapterIDs.isEmpty || !blockedChapters.isEmpty || workflow.isProductionBusy)
                .accessibilityIdentifier("audiobook-regeneration-confirm")
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.md)
        .frame(width: min(SpeechRailDesignTokens.Layout.Sheet.prominentWidth,
                          max(0, availableSize.width - SpeechRailDesignTokens.Spacing.lg)),
               height: min(SpeechRailDesignTokens.Layout.audiobookCastingDetailsHeight,
                           max(0, availableSize.height - SpeechRailDesignTokens.Spacing.lg)))
        .operationFeedback([OperationFeedback(workflow.errorMessage,
            onDismiss: { workflow.errorMessage = nil })])
        .defaultFocus($isContentFocused, true)
        .onExitCommand { dismiss() }
        .task { isContentFocused = true }
    }

    @ViewBuilder
    private var scopeChoices: some View {
        switch scope {
        case .chapters:
            ForEach(draft.chapters) { chapter in chapterChoice(chapter) }
        case .fragments:
            let displayedChapters = draft.chapters.filter { targetChapterIDs.contains($0.id) || $0.id == draft.defaultChapterID }
            ForEach(displayedChapters) { chapter in
                if displayedChapters.count > 1 {
                    Text(chapter.title)
                        .font(SpeechRailDesignTokens.Typography.caption.weight(.semibold))
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .padding(.top, SpeechRailDesignTokens.Spacing.xs)
                }
                ForEach(Array(draft.fragmentsByChapter[chapter.id, default: []].enumerated()), id: \.element.id) { entry in
                    fragmentChoice(index: entry.offset, fragment: entry.element)
                }
            }
        case .currentChapter:
            Text(draft.chapters.first { $0.id == draft.defaultChapterID }?.title ?? "当前章节")
        case .wholeBook:
            Text("包含所有未跳过章节；尚无音频的章节将首次制作，已有音频生成新候选。")
        }
    }

    private func chapterChoice(_ chapter: AudiobookChapter) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            Toggle(chapter.title, isOn: Binding(
                get: { chapterIDs.contains(chapter.id) },
                set: { if $0 { chapterIDs.insert(chapter.id) } else { chapterIDs.remove(chapter.id) } }
            ))
            .disabled(draft.blockedChapterReasons[chapter.id] != nil)
            if let reason = draft.blockedChapterReasons[chapter.id] {
                Text(reason)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
        }
    }

    private func fragmentChoice(index: Int, fragment: AudiobookFragment) -> some View {
        Toggle(isOn: Binding(
            get: { fragmentIDs.contains(fragment.id) },
            set: { if $0 { fragmentIDs.insert(fragment.id) } else { fragmentIDs.remove(fragment.id) } }
        )) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text("片段 \(index + 1)")
                Text(draft.fragmentExcerpts[fragment.id, default: ""])
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

}

/// T17 跨作品制作队列。只读当前计划与产品状态；所有动作都回到 workflow，
/// 由队列自己决定什么时候真正开始下一项。
private struct AudiobookProductionQueuePanel: View {
    let workflow: AudiobookWorkflowModel

    private var plan: AudiobookProductionQueuePlan { workflow.productionQueuePlan }

    var body: some View {
        Group {
            if let loadError = workflow.productionQueueLoadError {
                NoticeBar(tone: .warning, message: "队列记录读不出来：\(loadError) 已入队的内容仍会在本次运行中执行，但重启后可能丢失。")
            } else if !plan.items.isEmpty {
                content
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .background(SpeechRailDesignTokens.Color.recessedField)
        .accessibilityIdentifier("audiobook-production-queue")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                Text("制作队列（\(plan.items.count) 项）")
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                Spacer()
                if plan.activeItem != nil {
                    Button("暂停队列") { workflow.pauseProductionQueue() }
                        .speechRailButton(.secondary)
                        .accessibilityIdentifier("audiobook-production-queue-pause")
                } else if plan.hasPendingWork {
                    Button("继续队列") { workflow.resumeProductionQueue() }
                        .speechRailButton(.secondary)
                        .accessibilityIdentifier("audiobook-production-queue-resume")
                }
                if !plan.failedItems.isEmpty {
                    Button("重试失败项") { workflow.retryFailedProductionQueueItems() }
                        .speechRailButton(.secondary)
                        .accessibilityIdentifier("audiobook-production-queue-retry")
                }
            }
            Text("一次只制作一项。失败会停在这里等您重试；重启后未确认终态的项需要先核对。")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            ForEach(plan.items) { item in
                HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    Text(item.title).lineLimit(1)
                    StatusPill(tone: tone(for: item.state), label: label(for: item.state))
                    if let reason = item.failureReason {
                        Text(reason)
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    if item.state == .interrupted {
                        Button("核对后继续") { workflow.confirmInterruptedProductionQueueItem(item.id) }
                            .speechRailButton(.secondary)
                    } else if item.state == .queued || item.state == .running || item.state == .waiting {
                        Button("取消") { workflow.cancelProductionQueueItem(item.id) }
                            .speechRailButton(.secondary)
                    }
                    if item.state == .queued {
                        if queuedIndex(of: item) > 0 {
                            Button("上移") { moveQueued(item, by: -1) }
                                .speechRailButton(.secondary)
                                .accessibilityIdentifier("audiobook-production-queue-move-up")
                        }
                        if queuedIndex(of: item) < plan.queuedItems.count - 1 {
                            Button("下移") { moveQueued(item, by: 1) }
                                .speechRailButton(.secondary)
                                .accessibilityIdentifier("audiobook-production-queue-move-down")
                        }
                    }
                }
                .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
            }
        }
    }

    private func label(for state: AudiobookProductionQueueItemState) -> String {
        switch state {
        case .queued: "等待中"
        case .running: "正在制作"
        case .waiting: "等待语音服务"
        case .paused: "已暂停"
        case .failed: "失败"
        case .completed: "已完成"
        case .interrupted: "待核对"
        }
    }

    private func tone(for state: AudiobookProductionQueueItemState) -> StatusTone {
        switch state {
        case .running, .waiting: .healthy
        case .queued, .paused, .interrupted: .neutral
        case .failed: .attention
        case .completed: .healthy
        }
    }

    /// 该项在未开始子队列中的位置；不在其中时返回 0（此时不显示移动按钮）。
    private func queuedIndex(of item: AudiobookProductionQueueItem) -> Int {
        plan.queuedItems.firstIndex(where: { $0.id == item.id }) ?? 0
    }

    private func moveQueued(_ item: AudiobookProductionQueueItem, by offset: Int) {
        var ids = plan.queuedItems.map(\.id)
        let from = queuedIndex(of: item)
        let to = from + offset
        guard ids.indices.contains(from), ids.indices.contains(to) else { return }
        ids.swapAt(from, to)
        workflow.reorderProductionQueue(queuedIDs: ids)
    }
}
