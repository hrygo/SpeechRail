import SpeechRailControlKit
import SwiftUI

/// T13：三栏有声书工作台视图（左：章节导航与就绪状态；中：准备与角色/制作与返修共享主画布；右：人物与配声检查器，窄窗口自适应收起为浮层）。
public struct AudiobookBookWorkspaceView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppNavigationState.self) private var navigation
    @AppStorage("speechrail.showDeveloperDetails") private var showAnalysisDeveloperDetails = false
    @State private var isAnalysisDevSectionExpanded = false

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
                    .frame(width: 340, height: 560)
                    .padding(SpeechRailDesignTokens.Spacing.sm)
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
                    .frame(width: 210)
                    .labelsHidden()
                    .accessibilityIdentifier("audiobook-workbench-tab-picker")

                    if !showInlineCast {
                        Button {
                            workflow.isCastInspectorPresented.toggle()
                        } label: {
                            Label("人物与声音（\(workflow.characters.count)）", systemImage: "person.2.wave.2")
                        }
                        .speechRailButton(.secondary)
                    }

                    if let primaryAction = workflow.selectedBookPrimaryAction {
                        Button {
                            triggerPrimaryAction(primaryAction, bookID: book.id)
                        } label: {
                            Label(primaryAction.title, systemImage: primaryAction.systemImage)
                        }
                        .speechRailButton(.primary)
                        .disabled(primaryAction == .pauseProduction && workflow.isPausingProduction)
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

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(chapter.title)
                                            .font(SpeechRailDesignTokens.Typography.body)
                                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                                            .lineLimit(1)

                                        HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                                            chapterReadinessBadge(for: readiness)
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
                            .accessibilityIdentifier("audiobook-chapter-row-\(chapter.ordinal)")
                        }
                    }
                    .padding(SpeechRailDesignTokens.Spacing.xs)
                }

                if workflow.unknownAnnotationsInSelectedChapter.count > 0 {
                    SessionHairline()
                    SessionPanelActions {
                        Button {
                            workflow.workbenchTab = .preparation
                        } label: {
                            Label(
                                "定位本章待确认说话人（\(workflow.unknownAnnotationsInSelectedChapter.count)）",
                                systemImage: "scope"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .speechRailButton(.secondary)
                    }
                }
            }
        }
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
                    trailingDetail: "共 \(workflow.chapterAtoms.count) 段 · 待确认 \(workflow.unknownAnnotationsInSelectedChapter.count) 处"
                )
                SessionHairline()

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

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        ForEach(workflow.chapterAtoms) { atom in
                            atomRowView(atom: atom)
                        }
                    }
                    .padding(SpeechRailDesignTokens.Spacing.md)
                    .frame(maxWidth: SpeechRailDesignTokens.Layout.audiobookScriptReadingMaximumWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
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

    private var auditionGateBanner: some View {
        HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Image(systemName: "ear.badge.checkmark")
                .foregroundStyle(SpeechRailDesignTokens.Color.rail)
            VStack(alignment: .leading, spacing: 2) {
                Text("正式制作前请先试听并确认旁白与主要角色声音")
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Text("为避免整章生成后才发现声线不符，请在右侧为每个角色绑定可合成音色，确认后即可逐章制作。")
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
    }

    @ViewBuilder
    private func atomRowView(atom: AudiobookTextAtom) -> some View {
        let annotation = workflow.chapterAnnotationsByAtomID[atom.id]
        let displayText = workflow.atomTextsByID[atom.id] ?? ""
        let isSelected = workflow.selectedAtomIDs.contains(atom.id)
        let isUnknown = annotation?.assignment.isUnknown == true
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

                if isUnknown {
                    StatusPill(tone: .attention, label: "待确认说话人")
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
                            Task { await workflow.assignSpeaker(atomIDs: [atom.id], roleID: role.id) }
                        }
                    }
                    if !workflow.remainingBookCharacters.isEmpty {
                        Divider()
                        Menu("更多全书角色（\(workflow.remainingBookCharacters.count)）") {
                            ForEach(workflow.remainingBookCharacters) { role in
                                Button("指派给：\(role.displayName)") {
                                    Task { await workflow.assignSpeaker(atomIDs: [atom.id], roleID: role.id) }
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
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)

            if case let .unknown(reason, candidateRoleIDs) = annotation?.assignment {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Text("待确认原因：\(reason)")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.attention)

                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Text("快捷确认：")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

                        let candidateRoles = candidateRoleIDs.compactMap { cid in
                            workflow.charactersByID[cid]
                        }
                        let buttonsToShow = candidateRoles.isEmpty ? Array(workflow.currentChapterCharacters.prefix(3)) : candidateRoles

                        ForEach(buttonsToShow) { role in
                            Button(role.displayName) {
                                Task { await workflow.assignSpeaker(atomIDs: [atom.id], roleID: role.id) }
                            }
                            .speechRailButton(.secondary)
                        }
                    }
                }
                .padding(SpeechRailDesignTokens.Spacing.xs)
                .background(SpeechRailDesignTokens.Color.attention.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested))
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested)
                .fill(
                    isSelected
                        ? SpeechRailDesignTokens.Color.rail.opacity(0.10)
                        : (isUnknown ? SpeechRailDesignTokens.Color.attention.opacity(0.06) : SpeechRailDesignTokens.Color.field)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested)
                .strokeBorder(
                    isSelected
                        ? SpeechRailDesignTokens.Color.rail.opacity(0.4)
                        : (isUnknown ? SpeechRailDesignTokens.Color.attention.opacity(0.3) : SpeechRailDesignTokens.Color.separator.opacity(0.5)),
                    lineWidth: 1
                )
        )
    }

    // MARK: - Production & Candidate Repair Canvas

    private var productionStageView: some View {
        SessionPanel {
            VStack(alignment: .leading, spacing: 0) {
                SessionPanelHead(
                    title: "章节合成片段与返修候选（共 \(workflow.chapterFragments.count) 个连续片段）",
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

                if workflow.chapterFragments.isEmpty {
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
                        if workflow.isProducing {
                            Button {
                                Task { await workflow.pauseProduction() }
                            } label: {
                                Label(workflow.isPausingProduction ? "正在暂停…" : "暂停制作", systemImage: "pause.circle")
                            }
                            .speechRailButton(.secondary)
                            .disabled(workflow.isPausingProduction)
                        } else {
                            Button {
                                if let chID = workflow.selectedChapterID {
                                    workflow.makeConfirmedChapters(chapterIDs: [chID])
                                }
                            } label: {
                                Label("制作/更新本章", systemImage: "waveform.badge.plus")
                            }
                            .speechRailButton(.primary)
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
        if let prog = workflow.productionProgress, workflow.isProducing {
            return "正在制作 \(prog.completedFragments)/\(prog.totalFragments)"
        }
        return "固定 speed=1.0 · 48kHz PCM16"
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

                    if let cand = matchingCandidate {
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
        let allAvailableVoices = appModel.safeVoiceCatalog?.data.filter {
            $0.available && $0.productionReady != false
        } ?? []
        let activeBookVoices = allAvailableVoices.filter {
            VoiceCatalogStore.shared.isVoiceActiveForBook(voiceID: $0.id, currentBookID: workflow.selectedBook?.id)
        }
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
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        StatusPill(tone: .healthy, label: "核心 \(leadCount) 人")
                        StatusPill(tone: .neutral, label: "配角群像 \(minorCount) 人")
                        if conflictCount > 0 {
                            StatusPill(tone: .attention, label: "同场撞音 \(conflictCount) 处")
                        }
                        Spacer()
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
                        }

                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Button {
                                Task {
                                    let voices = appModel.safeVoiceCatalog?.data.filter {
                                        $0.available && $0.productionReady != false
                                    }
                                    await workflow.autoAssignRecommendedVoices(availableVoices: voices)
                                }
                            } label: {
                                Label("智能配声", systemImage: "wand.and.stars")
                            }
                            .speechRailButton(.secondary)
                            .accessibilityIdentifier("audiobook-smart-assign-voices-button")

                            Spacer()

                            Button {
                                Task { await workflow.confirmCastAndAudition() }
                            } label: {
                                Label("确认配声", systemImage: "checkmark.circle")
                            }
                            .speechRailButton(.primary)
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

        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    SessionVoiceBadge(label: String(role.displayName.prefix(1)))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                            Text(role.displayName)
                                .font(SpeechRailDesignTokens.Typography.sectionTitle)
                                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                                .lineLimit(1)

                            StatusPill(
                                tone: (tier == .narrator || tier == .lead) ? .healthy : .neutral,
                                label: tier.badgeTitle
                            )

                            StatusPill(
                                tone: .neutral,
                                label: archetype.shortBadgeTitle
                            )

                            if !role.isNarrator {
                                Text(dialogueCount > 0 ? "\(dialogueCount) 句 · \(max(1, chapterCount)) 章" : "仅提及 · 0 句")
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
                    Spacer()
                }

                let persona = role.resolvedVoicePersona()
                let personaHeadline = role.primaryVoiceTraitSummary
                    ?? "\(persona.ageGenderAnchor) · \(persona.pitchAndRegister)"
                Text("声学画像：\(personaHeadline)")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(1)

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
                    .background(SpeechRailDesignTokens.Color.attention.opacity(0.12), in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested))
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
                            let scopePrefix = (voiceMeta?.scope == .bookExclusive) ? "📘 " : ""
                            return "已绑：\(scopePrefix)\(baseName)\(speedSuffix)"
                        }()
                        Label(boundDisplay, systemImage: "waveform")
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
                            activeBookVoices: activeBookVoices,
                            allCharacters: workflow.characters,
                            allBindings: workflow.voiceBindings,
                            fallbackPresets: Self.fallbackPresetChoices,
                            onSelectVoice: { newBinding in
                                activeVoicePickerRoleID = nil
                                Task { await workflow.bindVoice(roleID: role.id, binding: newBinding) }
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
                            }
                        )
                    }

                    Button("设计新音色") {
                        Task {
                            if let ctx = await workflow.beginVoiceRoundTrip(for: role.id) {
                                navigation.requestVoiceDesignForAudiobook(context: ctx)
                            }
                        }
                    }
                    .speechRailButton(.quiet)
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
        case .makeConfirmedChapters, .resumeProduction:
            workflow.workbenchTab = .production
            workflow.makeConfirmedChapters()
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

// MARK: - 100+ 音色分层搜索试听选择器 Popover（解决 B8 平铺 Menu 崩溃）

private struct AudiobookVoicePickerPopover: View {
    @Environment(AppModel.self) private var appModel

    enum ScopeFilter: String, CaseIterable, Identifiable {
        case matchedArchetype = "matched"
        case bookExclusive = "book_exclusive"
        case favorites = "favorites"
        case all = "all"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .matchedArchetype: return "智能匹配声部"
            case .bookExclusive: return "本书专用"
            case .favorites: return "星标收藏"
            case .all: return "全部"
            }
        }
    }

    let role: AudiobookCharacter
    let archetype: AudiobookVoiceArchetype
    let currentBinding: AudiobookVoiceBinding?
    let activeBookVoices: [SafeVoiceEntry]
    let allCharacters: [AudiobookCharacter]
    let allBindings: [UUID: AudiobookVoiceBinding]
    let fallbackPresets: [(id: String, name: String)]
    let onSelectVoice: (AudiobookVoiceBinding) -> Void
    let onChangeSpeed: (Double) -> Void
    let onDesignNewVoice: () -> Void

    @State private var searchQuery: String = ""
    @State private var scopeFilter: ScopeFilter = .matchedArchetype
    @State private var catalogRefreshTick: Int = 0

    private static let microSpeedPresets: [Double] = [0.92, 0.96, 1.00, 1.04, 1.08]

    private var filteredVoices: [SafeVoiceEntry] {
        _ = catalogRefreshTick
        let metadataMap = VoiceCatalogStore.shared.metadataByVoiceID
        let byScope = activeBookVoices.filter { voice in
            let meta = metadataMap[voice.id]
            let voiceArch = AudiobookCastRegistry.resolveVoiceArchetype(for: voice, metadata: meta)
            switch scopeFilter {
            case .matchedArchetype:
                return voiceArch == archetype
                    || meta?.originRoleID == role.id
                    || (meta?.scope == .bookExclusive && meta?.originBookID == role.bookID)
            case .bookExclusive:
                return meta?.scope == .bookExclusive && meta?.originBookID == role.bookID
            case .favorites:
                return meta?.isFavorite == true
            case .all:
                return true
            }
        }
        let candidateList = (byScope.isEmpty && scopeFilter == .matchedArchetype) ? activeBookVoices : byScope
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return candidateList }
        return candidateList.filter { voice in
            let meta = metadataMap[voice.id]
            let arch = AudiobookCastRegistry.resolveVoiceArchetype(for: voice, metadata: meta)
            return voice.name.localizedCaseInsensitiveContains(q)
                || voice.id.localizedCaseInsensitiveContains(q)
                || arch.shortBadgeTitle.localizedCaseInsensitiveContains(q)
                || (meta?.originRoleName?.localizedCaseInsensitiveContains(q) == true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text("为「\(role.displayName)」选择音色")
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                StatusPill(tone: .neutral, label: archetype.shortBadgeTitle)
                Spacer()
                Text("\(filteredVoices.count) 个可选")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }

            TextField("搜索音色名称、声部行当或关联角色…", text: $searchQuery)
                .speechRailSingleLineInput()

            Picker("音色范围", selection: $scopeFilter) {
                ForEach(ScopeFilter.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                    if activeBookVoices.isEmpty {
                        ForEach(fallbackPresets, id: \.id) { preset in
                            Button {
                                let b = AudiobookVoiceBinding(
                                    roleID: role.id,
                                    voiceID: preset.id,
                                    voiceRevision: "v1",
                                    modelRevision: "qwen3-tts-v1",
                                    allowedSpeed: currentBinding?.allowedSpeed ?? 1.0
                                )
                                onSelectVoice(b)
                            } label: {
                                HStack {
                                    Text(preset.name)
                                        .font(SpeechRailDesignTokens.Typography.bodyMedium)
                                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                                    Text("(\(preset.id))")
                                        .font(SpeechRailDesignTokens.Typography.caption)
                                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                    Spacer()
                                    if currentBinding?.voiceID == preset.id {
                                        StatusPill(tone: .healthy, label: "当前绑定")
                                    }
                                }
                                .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                                .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
                            }
                            .buttonStyle(.plain)
                        }
                    } else if filteredVoices.isEmpty {
                        Text("当前筛选条件下没有匹配音色，可切换至「全部」或设计新音色。")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            .padding(SpeechRailDesignTokens.Spacing.sm)
                    } else {
                        let holdersMap = holdersByVoiceID
                        ForEach(filteredVoices) { voice in
                            voiceRow(for: voice, holdersMap: holdersMap)
                        }
                    }
                }
            }
            .frame(height: 240)

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
                   meta.scope == .bookExclusive
                {
                    HStack {
                        Text("📘 本书专属音色")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        Spacer()
                        Button("⬆️ 晋升为全局通用音色") {
                            _ = VoiceCatalogStore.shared.promoteToGlobalReusable(voiceID: b.voiceID)
                            catalogRefreshTick += 1
                        }
                        .speechRailButton(.quiet)
                    }
                }
            }

            Divider()

            HStack {
                Button {
                    onDesignNewVoice()
                } label: {
                    Label("为「\(role.displayName)」AI 设计专属新音色…", systemImage: "sparkles")
                }
                .speechRailButton(.secondary)
                Spacer()
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.md)
        .frame(width: 390)
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
        let lockedByExclusiveLead = otherHolders.first(where: { $0.isNarrator || !$0.allowSharedMinorVoice })

        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Button {
                VoiceCatalogStore.shared.toggleFavorite(voiceID: voice.id)
                catalogRefreshTick += 1
            } label: {
                Image(systemName: meta?.isFavorite == true ? "star.fill" : "star")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(
                        meta?.isFavorite == true
                            ? SpeechRailDesignTokens.Color.voice
                            : SpeechRailDesignTokens.Color.inkTertiary
                    )
            }
            .buttonStyle(.plain)

            Button {
                let speed = currentBinding?.allowedSpeed ?? AudiobookLimits.defaultRenderSpeed
                let b = AudiobookVoiceBinding(
                    roleID: role.id,
                    voiceID: voice.id,
                    voiceRevision: voice.voiceRevision ?? "v1",
                    modelRevision: voice.model.catalogRevision ?? voice.model.runtimeRevision ?? "qwen3-tts-v1",
                    isSynthesisReady: true,
                    allowedSpeed: voice.mode.lowercased() == "clone" ? 1.0 : speed
                )
                onSelectVoice(b)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                        Text(voice.name)
                            .font(SpeechRailDesignTokens.Typography.bodyMedium)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                            .lineLimit(1)
                        StatusPill(tone: .neutral, label: voiceArch.shortBadgeTitle)
                        if meta?.scope == .bookExclusive {
                            StatusPill(tone: .healthy, label: "本书专用")
                        }
                    }

                    HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                        if isBoundToSelf {
                            Text("当前已绑")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.ready)
                        } else if let exclusiveHolder = lockedByExclusiveLead {
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
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
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
                    Image(systemName: isPreviewing ? "stop.circle.fill" : "play.circle")
                }
                .buttonStyle(.borderless)
                .help(isPreviewing ? "停止试听" : "试听该音色")
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
        .background(
            isBoundToSelf
                ? SpeechRailDesignTokens.Color.rail.opacity(0.14)
                : Color.clear,
            in: SpeechRailDesignTokens.Corner.controlShape
        )
    }
}
