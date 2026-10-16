import SpeechRailControlKit
import SwiftUI

private struct AudiobookChapterRenameTarget: Identifiable {
    let bookID: UUID
    let chapterID: UUID
    let title: String

    var id: UUID { chapterID }
}

/// A small, independently ticking subtree keeps elapsed time out of the workspace's data flow.
private struct AudiobookProductionProgressRail: View {
    let progress: AudiobookProductionProgress
    let chapterTitle: String?
    let isBusy: Bool
    let isPausing: Bool
    let canResume: Bool
    let onPause: () -> Void
    let onResume: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            CardSurface {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                        Text(isPausing && isBusy ? "正在暂停制作…" : progress.statusTitle)
                            .font(SpeechRailDesignTokens.Typography.sectionTitle)
                        Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
                        Text("已用 \(progress.elapsedSeconds(at: context.date)) 秒")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .monospacedDigit()
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        if isBusy {
                            Button(isPausing ? "正在暂停…" : "暂停制作", systemImage: "pause.circle", action: onPause)
                                .speechRailButton(.secondary)
                                .disabled(isPausing)
                                .accessibilityIdentifier("audiobook-production-pause")
                        } else if progress.state == .paused || progress.state == .failed {
                            Button("继续制作", systemImage: "play.circle", action: onResume)
                                .speechRailButton(.secondary)
                                .disabled(!canResume)
                                .accessibilityIdentifier("audiobook-production-resume")
                        }
                    }
                    if progress.totalFragments > 0 {
                        ProgressView(value: progress.fraction)
                            .tint(SpeechRailDesignTokens.Color.rail)
                            .accessibilityLabel("制作进度")
                            .accessibilityValue("\(Int(progress.fraction * 100))%，\(progress.savedFragmentsText)")
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
                            Text("\(Int(progress.fraction * 100))%").monospacedDigit()
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
                    }
                    if let message = progress.lastErrorMessage {
                        Text(message)
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.attention)
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
    @AppStorage("speechrail.showDeveloperDetails") private var showAnalysisDeveloperDetails = false
    @State private var isAnalysisDevSectionExpanded = false
    @State private var chapterRenameTarget: AudiobookChapterRenameTarget?
    @State private var chapterRenameDraft = ""

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
            let showInlineCast = WindowLayoutPolicy.audiobookShowsInlineCastColumn(forWidth: proxy.size.width)

            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                topStatusAndPrimaryActionBar(showInlineCast: showInlineCast)

                if workflow.isAnalyzing {
                    analysisProgressRail
                }
                if let progress = workflow.selectedBookProductionProgress {
                    AudiobookProductionProgressRail(
                        progress: progress,
                        chapterTitle: workflow.chapters.first(where: { $0.id == progress.currentChapterID })?.title,
                        isBusy: workflow.isProductionBusy && workflow.productionBookID == progress.bookID,
                        isPausing: workflow.isPausingProduction,
                        canResume: !workflow.isProductionBusy && !workflow.isEditingChapterLayout
                            && workflow.selectedBook?.productionState == .paused,
                        onPause: { Task { await workflow.pauseProduction() } },
                        onResume: { Task { await workflow.resumeProduction() } }
                    )
                }
                HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.md) {
                    chapterSidebarColumn
                        .frame(width: SpeechRailDesignTokens.Layout.sessionListWidth)

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
            }
            .popover(isPresented: $bindableWorkflow.isCastInspectorPresented, arrowEdge: .trailing) {
                castInspectorColumn
                    .frame(width: SpeechRailDesignTokens.Layout.inspectorColumnWidth, height: 560)
                    .padding(SpeechRailDesignTokens.Spacing.sm)
            }
            .sheet(item: $chapterRenameTarget) { target in
                chapterRenameSheet(for: target)
            }
            .onChange(of: workflow.selectedBook?.id) { _, selectedBookID in
                if chapterRenameTarget?.bookID != selectedBookID {
                    chapterRenameTarget = nil
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
        }
    }

    // MARK: - Top Summary & Single Primary Action Bar

    @ViewBuilder
    private func topStatusAndPrimaryActionBar(showInlineCast: Bool) -> some View {
        if let book = workflow.selectedBook {
            CardSurface {
                HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.md) {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
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
                        }

                        aiProviderDisclosureLine
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

                    if !showInlineCast {
                        Button {
                            workflow.isCastInspectorPresented.toggle()
                        } label: {
                            Label("人物与声音（\(workflow.characters.count)）", systemImage: "person.2.wave.2")
                        }
                        .speechRailButton(.secondary)
                    }

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
                                || workflow.isEditingChapterLayout
                                || productionStartBlocked
                        )
                        .help(workflow.isEditingChapterLayout
                              ? "正在整理章节目录，请完成后再继续。"
                              : (productionStartBlocked
                                  ? "另一部有声书正在制作，完成或暂停后即可开始此书。"
                                  : primaryAction.title))
                        .accessibilityIdentifier("audiobook-workspace-primary-action")
                    }
                }
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
            }
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
                                            chapterReadinessBadge(for: readiness)
                                            if let unknownCount = workflow.unknownCountByChapterID[chapter.id], unknownCount > 0 {
                                                StatusPill(tone: .attention, label: "待确认 \(unknownCount)")
                                            }
                                            if chapter.previousChapterRevisionID != nil && readiness == .needsUpdate {
                                                Text("之前的版本可听")
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

                if workflow.totalUnknownSpeakerCount > 0 {
                    SessionHairline()
                    SessionPanelActions {
                        Button {
                            Task { await workflow.jumpToNextUnknownSpeaker() }
                        } label: {
                            Label(
                                "快速定位下一处待确认（全书 \(workflow.totalUnknownSpeakerCount) 处）",
                                systemImage: "scope"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .speechRailButton(.secondary)
                        .accessibilityIdentifier("audiobook-jump-next-unknown-button")
                    }
                }
            }
        }
    }

    private var chapterOrganizationMenu: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Menu {
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
            } label: {
                Label("整理章节", systemImage: "list.bullet.indent")
            }
            .speechRailButton(.secondary)
            .fixedSize()
            .accessibilityIdentifier("audiobook-chapter-organization-menu")
            .help(workflow.chapterStructureEditingStatus)

            Text(workflow.chapterStructureEditingStatus)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("audiobook-chapter-organization-status")
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
    }

    private func chapterRenameSheet(for target: AudiobookChapterRenameTarget) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            Text("重命名章节")
                .font(SpeechRailDesignTokens.Typography.sectionTitle)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)

            Text("只更改「\(target.title)」的章节名称，原文、分析记录和已有音频都会保留。")
                .font(SpeechRailDesignTokens.Typography.body)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

            TextField("章节名称", text: $chapterRenameDraft)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("audiobook-chapter-rename-field")

            HStack {
                Spacer()
                Button("取消") {
                    chapterRenameTarget = nil
                }
                .speechRailButton(.secondary)
                .keyboardShortcut(.cancelAction)

                Button("保存") {
                    guard target.bookID == workflow.selectedBook?.id else {
                        chapterRenameTarget = nil
                        return
                    }
                    let chapterID = target.chapterID
                    let title = chapterRenameDraft
                    chapterRenameTarget = nil
                    Task { await workflow.renameChapter(chapterID: chapterID, title: title) }
                }
                .speechRailButton(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    target.bookID != workflow.selectedBook?.id
                        || !workflow.canRenameSelectedChapter
                        || chapterRenameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .accessibilityIdentifier("audiobook-chapter-rename-save")
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.md)
        .frame(minWidth: SpeechRailDesignTokens.Layout.Sheet.compactWidth)
    }

    // MARK: - Center Column: Shared Preparation / Production Canvas

    @ViewBuilder
    private var centerStageColumn: some View {
        switch workflow.workbenchTab {
        case .preparation:
            preparationStageView
        case .production:
            productionStageView
        }
    }

    private var preparationStageView: some View {
        SessionPanel {
            VStack(alignment: .leading, spacing: 0) {
                SessionPanelHead(
                    title: "原文与说话人归属（只读保真原文，AI 不改写一字）",
                    trailingDetail: "共 \(workflow.chapterAtoms.count) 段 · 本章待确认 \(workflow.unknownAnnotationsInSelectedChapter.count) 处 · 全书待确认 \(workflow.totalUnknownSpeakerCount) 处"
                )
                SessionHairline()

                if workflow.totalUnknownSpeakerCount > 0 {
                    unknownSpeakerNavigatorBar
                    SessionHairline()
                }

                if !workflow.isAuditionConfirmedForSelectedBook,
                   workflow.selectedBook?.analysisState == .allWindowsValidated
                {
                    auditionGateBanner
                    SessionHairline()
                }

                if !workflow.selectedAtomIDs.isEmpty {
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
                                ForEach(workflow.displayedChapterAtoms) { atom in
                                    atomRowView(atom: atom)
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
                            Label("撤销上次归属修改", systemImage: "arrow.uturn.backward")
                        }
                        .speechRailButton(.quiet)

                        Spacer()

                        if workflow.selectedBook?.analysisState == .allWindowsValidated {
                            Button {
                                Task { await workflow.confirmCastAndAudition() }
                            } label: {
                                Label("确认全书角色与试听声音", systemImage: "checkmark.seal")
                            }
                            .speechRailButton(.primary)
                            .accessibilityIdentifier("audiobook-confirm-cast-audition-button")
                        }
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
            Text("待确认定位：第 \(currentIndex) / \(workflow.totalUnknownSpeakerCount) 处（本章 \(workflow.unknownAnnotationsInSelectedChapter.count) 处）")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)

            Button {
                Task { await workflow.jumpToPreviousUnknownSpeaker() }
            } label: {
                Label("上一处", systemImage: "chevron.up")
            }
            .speechRailButton(.secondary)

            Button {
                Task { await workflow.jumpToNextUnknownSpeaker() }
            } label: {
                Label("下一处", systemImage: "chevron.down")
            }
            .speechRailButton(.secondary)

            Button {
                workflow.showOnlyUnknownAtomsInChapter.toggle()
            } label: {
                Label(
                    workflow.showOnlyUnknownAtomsInChapter ? "显示全部段落" : "仅看待确认对白",
                    systemImage: workflow.showOnlyUnknownAtomsInChapter ? "list.bullet" : "line.3.horizontal.decrease.circle"
                )
            }
            .speechRailButton(workflow.showOnlyUnknownAtomsInChapter ? .primary : .quiet)

            Spacer()

            Button {
                Task { await workflow.resolveUnknownSpeakersWithLLM() }
            } label: {
                Label(
                    workflow.isResolvingUnknownSpeakers ? "AI 二次复核中…" : "AI 二次复核未确认台词",
                    systemImage: "sparkles"
                )
            }
            .speechRailButton(.secondary)
            .disabled(workflow.isResolvingUnknownSpeakers || workflow.isAnalyzing)
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
            Text("已选 \(workflow.selectedAtomIDs.count) 段原文：")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

            ForEach(workflow.characters.prefix(4)) { role in
                Button("归属给「\(role.displayName)」") {
                    let ids = Array(workflow.selectedAtomIDs)
                    workflow.selectedAtomIDs.removeAll()
                    Task { await workflow.assignSpeaker(atomIDs: ids, roleID: role.id) }
                }
                .speechRailButton(.secondary)
            }

            Spacer()

            Button("取消多选") {
                workflow.selectedAtomIDs.removeAll()
            }
            .speechRailButton(.quiet)
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .background(SpeechRailDesignTokens.Color.recessedField)
        .disabled(workflow.isEditingChapterLayout)
    }

    @ViewBuilder
    private func atomRowView(atom: AudiobookTextAtom) -> some View {
        let annotation = workflow.chapterAnnotationsByAtomID[atom.id]
        let displayText = workflow.atomTextsByID[atom.id] ?? ""
        let isSelected = workflow.selectedAtomIDs.contains(atom.id)
        let isUnknown = annotation?.assignment.isUnknown == true
        let isFocusedUnknown = isUnknown && (workflow.focusedUnknownAtomID == atom.id)
        let assignedRole = annotation?.assignment.roleID.flatMap { id in
            workflow.charactersByID[id]
        }

        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
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
                } else if let role = assignedRole {
                    AudiobookVoiceTag(
                        name: role.displayName,
                        detail: workflow.voiceBindings[role.id]?.voiceID ?? "未配声"
                    )
                } else {
                    StatusPill(tone: .neutral, label: "待分析")
                }

                let charCount = displayText.isEmpty ? max(1, Int(atom.sourceRange.byteCount / 3)) : displayText.count
                Text("\(charCount) 字")
                    .font(SpeechRailDesignTokens.Typography.technical)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)

                Spacer()

                Menu {
                    ForEach(workflow.currentChapterCharacters) { role in
                        Button("指派给：\(role.displayName)") {
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
                                Button("指派给：\(role.displayName)") {
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
                    Label("改派说话人", systemImage: "person.crop.circle")
                        .font(SpeechRailDesignTokens.Typography.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
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

                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Text("一键确认并跳至下一处：")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

                        ForEach(quickRoles) { role in
                            Button {
                                Task { await workflow.assignSpeakerAndAdvanceToNextUnknown(atomID: atom.id, roleID: role.id) }
                            } label: {
                                if candidateSet.contains(role.id) {
                                    Label(role.displayName, systemImage: "sparkles")
                                } else {
                                    Text(role.displayName)
                                }
                            }
                            .speechRailButton(candidateSet.contains(role.id) ? .primary : .secondary)
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
            SpeechRailDesignTokens.Corner.nestedShape
                .fill(
                    isFocusedUnknown
                        ? SpeechRailDesignTokens.Color.attention.opacity(0.14)
                        : (isSelected
                            ? SpeechRailDesignTokens.Color.rail.opacity(0.10)
                            : (isUnknown ? SpeechRailDesignTokens.Color.attention.opacity(0.06) : SpeechRailDesignTokens.Color.field))
                )
        )
        .overlay(
            SpeechRailDesignTokens.Corner.nestedShape
                .stroke(
                    isFocusedUnknown
                        ? SpeechRailDesignTokens.Color.attention
                        : (isSelected
                            ? SpeechRailDesignTokens.Color.rail.opacity(0.4)
                            : (isUnknown ? SpeechRailDesignTokens.Color.attention.opacity(0.3) : SpeechRailDesignTokens.Color.separator.opacity(0.5))),
                    lineWidth: isFocusedUnknown ? 2 : 1
                )
        )
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

                if let plan = workflow.resumePlan, !plan.redoFragmentIDs.isEmpty {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                        StatusPill(tone: .healthy, label: "可复用 \(plan.reusableFragmentIDs.count) 段")
                        StatusPill(tone: .attention, label: "待生成/更新 \(plan.redoFragmentIDs.count) 段")
                        Text("修改角色名称保留全部已有音频；修改归属或角色音色仅重做受影响片段。")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        Spacer()
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
                        title: "当前章节尚未生成片段规划",
                        message: "请先完成全书分析并确认本章说话人与角色配声，随后点击「制作已确认章节」。"
                    ) {
                        Button("制作本章") {
                            if let chID = workflow.selectedChapterID {
                                workflow.makeConfirmedChapters(chapterIDs: [chID])
                            }
                        }
                        .speechRailButton(.primary)
                        .disabled(workflow.isProductionBusy || workflow.isLoadingChapterDetails || workflow.isEditingChapterLayout)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                            ForEach(workflow.chapterFragments) { fragment in
                                fragmentRowView(fragment: fragment)
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
                        if workflow.isProducing,
                           workflow.productionBookID == workflow.selectedBook?.id
                        {
                            Button {
                                Task { await workflow.pauseProduction() }
                            } label: {
                                Label(workflow.isPausingProduction ? "正在暂停…" : "暂停制作", systemImage: "pause.circle")
                            }
                            .speechRailButton(.secondary)
                            .disabled(workflow.isPausingProduction)
                        } else if workflow.selectedBook?.productionState == .paused {
                            Button("继续制作", systemImage: "play.circle") {
                                Task { await workflow.resumeProduction() }
                            }
                            .speechRailButton(.primary)
                            .disabled(workflow.isProductionBusy || workflow.isEditingChapterLayout)
                        } else {
                            Button {
                                if let chID = workflow.selectedChapterID {
                                    workflow.makeConfirmedChapters(chapterIDs: [chID])
                                }
                            } label: {
                                Label(
                                    workflow.isSelectedBookBlockedByProduction
                                        ? "另一部有声书正在制作"
                                        : "制作/更新本章",
                                    systemImage: "waveform.badge.plus"
                                )
                            }
                            .speechRailButton(.primary)
                            .disabled(workflow.isProductionBusy || workflow.isLoadingChapterDetails || workflow.isEditingChapterLayout)
                        }

                        Button {
                            Task { await workflow.undoChapterAdoption() }
                        } label: {
                            Label("回退本章上一版本", systemImage: "arrow.uturn.backward")
                        }
                        .speechRailButton(.quiet)

                        Spacer()

                        Button {
                            Task { await workflow.startListening() }
                        } label: {
                            Label("进入听书模式", systemImage: "headphones")
                        }
                        .speechRailButton(.secondary)
                    }
                }
            }
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
    private func fragmentRowView(fragment: AudiobookFragment) -> some View {
        let role = workflow.charactersByID[fragment.roleID]
        let text = workflow.fragmentTextsByID[fragment.id] ?? ""
        let candidates = workflow.chapterCandidatesByFragmentID[fragment.id] ?? []
        let matchingCandidate = candidates.first(where: { $0.dependencyDigest == fragment.dependencyDigest && $0.isReceiptVerified })

        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Text("#\(fragment.ordinal + 1)")
                        .font(SpeechRailDesignTokens.Typography.technical)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

                    AudiobookVoiceTag(
                        name: role?.displayName ?? "角色",
                        detail: workflow.voiceBindings[fragment.roleID]?.voiceID ?? "未绑定"
                    )

                    if let progress = workflow.selectedBookProductionProgress,
                       workflow.isProducing, progress.currentFragmentID == fragment.id
                    {
                        StatusPill(tone: .attention, label: progress.statusTitle)
                    } else if let cand = matchingCandidate {
                        StatusPill(
                            tone: .healthy,
                            label: String(format: "已就绪 · %.1fs", cand.durationSeconds)
                        )
                    } else if !candidates.isEmpty {
                        StatusPill(tone: .attention, label: "待更新（保留之前版本）")
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

                    Button {
                        workflow.regenerateFragment(fragmentID: fragment.id)
                    } label: {
                        Label(
                            workflow.isRegeneratingFragment(fragment.id) ? "正在重录…" : "重录本段",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .speechRailButton(.quiet)
                    .disabled(!workflow.canRegenerateFragment(fragment.id))
                    .help(workflow.chapters.first(where: { $0.id == fragment.chapterID })?.currentChapterRevisionID == nil
                          ? "请先完成本章首次制作，再重录单段。"
                          : "只为本段生成一个新候选，不会替换当前章节版本；试听后可在候选列表中选择采用。")
                    .accessibilityIdentifier("audiobook-regenerate-fragment-\(fragment.ordinal)")
                }

                Text(text)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .textSelection(.enabled)

                if candidates.count > 1 {
                    DisclosureGroup("候选版本对比与采用（共 \(candidates.count) 条）") {
                        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                            ForEach(candidates) { candidate in
                                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                                    Text("代次 #\(candidate.generation)")
                                        .font(SpeechRailDesignTokens.Typography.technical)
                                    Text(String(format: "%.2f 秒（%lld 帧）", candidate.durationSeconds, candidate.frameCount))
                                        .font(SpeechRailDesignTokens.Typography.caption)
                                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                    if candidate.dependencyDigest == fragment.dependencyDigest {
                                        StatusPill(tone: .healthy, label: "匹配当前设定")
                                    } else {
                                        StatusPill(tone: .neutral, label: "之前的版本")
                                    }
                                    Spacer()
                                    Button("试听") {
                                        Task { await workflow.previewCandidateAudio(candidate) }
                                    }
                                    .speechRailButton(.quiet)

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
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        }
    }

    // MARK: - Right Column: Cast & Voice Binding Inspector

    @State private var activeVoicePickerRoleID: UUID?

    private var castInspectorColumn: some View {
        @Bindable var bindableWorkflow = workflow
        let allAvailableVoices = workflow.mergedAvailableVoices(
            externalVoices: appModel.safeVoiceCatalog?.data ?? []
        )
        let activeBookVoices = allAvailableVoices.filter {
            VoiceCatalogStore.shared.isVoiceActiveForBook(voiceID: $0.id, currentBookID: workflow.selectedBook?.id)
        }
        let missingArchetypes = workflow.missingArchetypesForBook(
            bookID: workflow.selectedBook?.id,
            availableVoices: allAvailableVoices
        )
        let leadCount = workflow.characters.filter { $0.isNarrator || !$0.allowSharedMinorVoice }.count
        let minorCount = max(0, workflow.characters.count - leadCount)
        let conflictCount = workflow.totalSceneVoiceConflictCount

        return SessionPanel {
            VStack(alignment: .leading, spacing: 0) {
                SessionPanelHead(
                    title: "人物与声音（\(workflow.characters.count)）",
                    trailingDetail: "核心 \(leadCount) · 配角 \(minorCount)"
                )
                SessionHairline()

                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    if conflictCount > 0 || !missingArchetypes.isEmpty {
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
                            Spacer()
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
                SessionPanelActions {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        if let progressText = workflow.leadVoiceCreationProgressText,
                           workflow.isCreatingLeadExclusiveVoices
                        {
                            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(progressText)
                                    .font(SpeechRailDesignTokens.Typography.caption)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                Spacer()
                            }
                        }

                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Button {
                                workflow.isShowingCastMergeSheet = true
                            } label: {
                                Label("合并/拆分…", systemImage: "arrow.triangle.merge")
                            }
                            .speechRailButton(.secondary)

                            Menu {
                                let minorArchetypes: [AudiobookVoiceArchetype] = [
                                    .youngMale, .matureMale, .youngFemale, .matureFemale, .neutralEnsemble
                                ]
                                ForEach(minorArchetypes) { archetype in
                                    let matchingMinors = workflow.minorCharactersByArchetype[archetype] ?? []
                                    Menu("\(archetype.shortBadgeTitle)（\(matchingMinors.count) 人）") {
                                        let voicesToList = activeBookVoices.isEmpty ? allAvailableVoices : activeBookVoices
                                        if voicesToList.isEmpty {
                                            Text("当前无可用合成音色")
                                        } else {
                                            ForEach(voicesToList) { voice in
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
                            } label: {
                                Label("声部批量配音…", systemImage: "person.3.sequence")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()

                            Spacer()

                            Button {
                                Task {
                                    _ = await workflow.ensureSixArchetypeVoicesForBook()
                                    await appModel.engine.refreshDiscovery()
                                }
                            } label: {
                                Label("补全六类群像", systemImage: "person.3.fill")
                            }
                            .speechRailButton(.secondary)
                            .disabled(workflow.isCreatingLeadExclusiveVoices)
                            .help("检查当前系统是否具备满足本小说场景的六类群像音色，自动创建缺失的群像声部音色。")
                            .accessibilityIdentifier("audiobook-ensure-six-archetype-voices-button")

                            Button {
                                Task {
                                    _ = await workflow.ensureSixArchetypeVoicesForBook(quietBanner: true)
                                    _ = await workflow.createExclusiveVoicesForLeadCharacters()
                                    await appModel.engine.refreshDiscovery()
                                }
                            } label: {
                                Label(
                                    workflow.isCreatingLeadExclusiveVoices ? "生成音色中…" : "为主角生成专属音色",
                                    systemImage: "person.wave.2.fill"
                                )
                            }
                            .speechRailButton(.secondary)
                            .disabled(workflow.isCreatingLeadExclusiveVoices)
                            .accessibilityIdentifier("audiobook-create-lead-exclusive-voices-button")
                        }

                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Button {
                                Task { await workflow.previewRecommendedVoices() }
                            } label: {
                                Label("推荐声音", systemImage: "wand.and.stars")
                            }
                            .speechRailButton(.secondary)
                            .accessibilityIdentifier("audiobook-smart-assign-voices-button")

                            Spacer()

                            Button("撤销上次配声") { Task { await workflow.undoLastCastingChange() } }
                                .speechRailButton(.quiet)

                            Button {
                                Task { await workflow.confirmCastAndAudition() }
                            } label: {
                                Label("确认配声", systemImage: "checkmark.circle")
                            }
                            .speechRailButton(workflow.pendingCastingPlan == nil ? .primary : .secondary)
                        }
                        if let plan = workflow.pendingCastingPlan {
                            AudiobookCastingReview(workflow: workflow).id(plan.inputDigest)
                        }
                    }
                }
            }
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
        let chapterCount = max(stat?.speakingChapterIDs.count ?? 0, role.chapterIDs.count)
        let conflictPartners = workflow.sceneConflictPartnerNames(for: role.id)
        let voiceMeta = binding.flatMap { VoiceCatalogStore.shared.metadata(for: $0.voiceID) }
        let isCustomExclusiveVoice = binding.map {
            voiceMeta?.visibilityScope == .bookExclusive
                || !AudiobookWorkflowModel.builtInSystemVoiceIDs.contains($0.voiceID.lowercased())
        } ?? false

        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    SessionVoiceBadge(label: String(role.displayName.prefix(1)))
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(role.displayName)
                                .font(SpeechRailDesignTokens.Typography.sectionTitle)
                                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            Spacer()

                            if !role.isNarrator {
                                Text(dialogueCount > 0 ? "\(dialogueCount) 句 · \(max(1, chapterCount)) 章" : "仅提及 · 0 句")
                                    .font(SpeechRailDesignTokens.Typography.technical)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                            }
                        }

                        HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                            StatusPill(
                                tone: (tier == .narrator || tier == .lead) ? .healthy : .neutral,
                                label: tier.badgeTitle
                            )

                            StatusPill(
                                tone: .neutral,
                                label: archetype.shortBadgeTitle
                            )

                            if binding != nil {
                                StatusPill(
                                    tone: isCustomExclusiveVoice ? .healthy : .neutral,
                                    label: isCustomExclusiveVoice ? "专属定制" : "默认音色"
                                )
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

                if !conflictPartners.isEmpty {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                        Text("与同场对话角色「\(conflictPartners.joined(separator: "、"))」共用同一声线，建议点击智能配声或更换音色")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                            .lineLimit(2)
                    }
                    .padding(SpeechRailDesignTokens.Spacing.xs)
                    .background(SpeechRailDesignTokens.Color.attention.opacity(0.12), in: SpeechRailDesignTokens.Corner.nestedShape)
                }

                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Button {
                        activeVoicePickerRoleID = (activeVoicePickerRoleID == role.id) ? nil : role.id
                    } label: {
                        let boundDisplay: String = {
                            guard let b = binding else { return "选择音色…" }
                            let baseName: String
                            if let matched = allVoices.first(where: { $0.id == b.voiceID }) {
                                baseName = matched.name
                            } else if let preset = Self.fallbackPresetChoices.first(where: { $0.id == b.voiceID }) {
                                baseName = preset.name
                            } else {
                                baseName = b.voiceID
                            }
                            let speedSuffix = abs(b.allowedSpeed - 1.0) > 0.005
                                ? String(format: " · %.2fx", b.allowedSpeed)
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
                                Task { await workflow.bindVoice(roleID: role.id, voiceID: voiceID) }
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

                    Menu {
                        Button {
                            Task { await workflow.createExclusiveVoiceForRole(role.id) }
                        } label: {
                            Label("AI 生成专属音色", systemImage: "sparkles")
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
                }

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
            Task { await workflow.confirmCastAndAudition() }
        case .makeConfirmedChapters:
            workflow.workbenchTab = .production
            workflow.makeConfirmedChapters()
        case .resumeProduction:
            workflow.workbenchTab = .production
            Task { await workflow.resumeProduction() }
        case .pauseProduction:
            Task { await workflow.pauseProduction() }
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
            AudiobookAnalysisProgressRailView(
                progress: progress,
                tick: workflow.analysisClockTick,
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
            StatusPill(tone: .neutral, label: "待全书分析")
        case .awaitingCastConfirmation:
            StatusPill(tone: .neutral, label: "待确认配声")
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
        case .failed:
            StatusPill(tone: .critical, label: "需重试")
        }
    }
}

private struct AudiobookCastingReview: View {
    @Bindable var workflow: AudiobookWorkflowModel
    @State private var acknowledgements: Set<UUID> = []

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
                ForEach(plan.issues) { issue in
                    if issue.isBlocking {
                        Text(issue.nextAction).foregroundStyle(SpeechRailDesignTokens.Color.attention)
                    } else if issue.severity == .warning {
                        Toggle(issue.nextAction, isOn: Binding(get: { acknowledgements.contains(issue.id) }, set: {
                            if $0 { acknowledgements.insert(issue.id) } else { acknowledgements.remove(issue.id) }
                        })).toggleStyle(.checkbox)
                    }
                }
                DisclosureGroup("试听与分配说明") {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                        ForEach(workflow.characters.filter { recommendation.affectedRoleIDs.contains($0.id) }) { role in
                            Text("\(role.displayName)：\((recommendation.reasonsByRoleID[role.id] ?? []).joined(separator: "；"))")
                                .font(SpeechRailDesignTokens.Typography.caption)
                        }
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
                HStack {
                    Button("重新推荐") { Task { await workflow.previewRecommendedVoices() } }
                        .speechRailButton(.secondary)
                    Spacer()
                    Button("应用配声方案") { Task { await workflow.applyPendingCastingPlan(acknowledgedIssueIDs: acknowledgements) } }
                        .speechRailButton(.primary)
                        .disabled(!recommendation.isApplicable || workflow.castingPlanNeedsRefresh || !plan.requiredAcknowledgements.isSubset(of: acknowledgements))
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.sm)
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
    @State private var catalogRefreshTick: Int = 0
    @State private var catalogSaveError: String?

    private static let microSpeedPresets: [Double] = [0.92, 0.96, 1.00, 1.04, 1.08]

    private var filteredVoices: [SafeVoiceEntry] {
        _ = catalogRefreshTick
        let catalog = VoiceCatalogStore.shared.snapshot()
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
                    || (meta?.visibilityScope == .bookExclusive && meta?.originBookID == role.bookID)
            case .bookExclusive:
                return meta?.visibilityScope == .bookExclusive && meta?.originBookID == role.bookID
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
            if let catalogSaveError {
                Text(catalogSaveError).font(SpeechRailDesignTokens.Typography.caption).foregroundStyle(SpeechRailDesignTokens.Color.critical)
            }

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
                        Button(String(format: "%.2fx", speed)) {
                            onChangeSpeed(speed)
                        }
                        .speechRailButton(isSelected ? .primary : .quiet)
                    }
                    Spacer()
                }

                if let meta = VoiceCatalogStore.shared.metadata(for: b.voiceID),
                   meta.visibilityScope == .bookExclusive
                {
                    HStack {
                        Text("📘 本书专属音色")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        Spacer()
                        Button("设为通用声音") {
                            saveCatalogChange { _ = try VoiceCatalogStore.shared.promoteToGlobalReusable(voiceID: b.voiceID) }
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
        .task {
            await onRefreshVoices()
        }
        .onReceive(NotificationCenter.default.publisher(for: VoiceCatalogStore.didChange, object: VoiceCatalogStore.shared)) { _ in
            catalogRefreshTick += 1
        }
    }

    private func saveCatalogChange(_ action: () throws -> Void) {
        do { try action(); catalogRefreshTick += 1; catalogSaveError = nil }
        catch { catalogSaveError = error.localizedDescription }
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
        let meta = VoiceCatalogStore.shared.metadata(for: voice.id)
        let voiceArch = AudiobookCastRegistry.resolveVoiceArchetype(for: voice, metadata: meta)
        let isBoundToSelf = (currentBinding?.voiceID == voice.id)
        let otherHolders = holdersMap[voice.id] ?? []
        let lockedByExclusiveLead = otherHolders.first(where: { $0.isNarrator || $0.effectiveVoicePolicy.sharingPolicy != .sharedMinor })
        let isHovered = hoveredVoiceID == voice.id

        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Button {
                saveCatalogChange { _ = try VoiceCatalogStore.shared.toggleFavorite(voiceID: voice.id) }
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
                            StatusPill(tone: .healthy, label: "本书专用")
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
