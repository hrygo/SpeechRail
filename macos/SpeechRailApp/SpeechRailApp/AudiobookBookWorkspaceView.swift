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
        let annotation = workflow.chapterAnnotations.first(where: { $0.atomID == atom.id })
        let rawText = workflow.atomTextsByID[atom.id] ?? ""
        let displayText = AudiobookSourceIndex.displayNormalizedText(rawText)
        let isSelected = workflow.selectedAtomIDs.contains(atom.id)
        let isUnknown = annotation?.assignment.isUnknown == true
        let assignedRole = annotation?.assignment.roleID.flatMap { id in
            workflow.characters.first(where: { $0.id == id })
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
                    ForEach(workflow.characters) { role in
                        Button("指派给：\(role.displayName)") {
                            Task { await workflow.assignSpeaker(atomIDs: [atom.id], roleID: role.id) }
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
                .textSelection(.enabled)
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
                            workflow.characters.first(where: { $0.id == cid })
                        }
                        let buttonsToShow = candidateRoles.isEmpty ? Array(workflow.characters.prefix(3)) : candidateRoles

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
        let role = workflow.characters.first(where: { $0.id == fragment.roleID })
        let rawText = workflow.fragmentTextsByID[fragment.id] ?? ""
        let text = AudiobookSourceIndex.displayNormalizedText(rawText)
        let candidates = workflow.chapterCandidates
            .filter { $0.fragmentID == fragment.id }
            .sorted { $0.createdAt > $1.createdAt }
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

    private var castInspectorColumn: some View {
        SessionPanel {
            VStack(alignment: .leading, spacing: 0) {
                SessionPanelHead(
                    title: "人物与声音（\(workflow.characters.count)）",
                    trailingDetail: "固定音色与版本"
                )
                SessionHairline()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        ForEach(workflow.characters) { role in
                            characterCard(for: role)
                        }
                    }
                    .padding(SpeechRailDesignTokens.Spacing.sm)
                }

                SessionHairline()
                SessionPanelActions {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Button {
                            workflow.isShowingCastMergeSheet = true
                        } label: {
                            Label("合并/拆分…", systemImage: "arrow.triangle.merge")
                        }
                        .speechRailButton(.secondary)

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
                        .speechRailButton(.quiet)

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

    @ViewBuilder
    private func characterCard(for role: AudiobookCharacter) -> some View {
        let binding = workflow.voiceBindings[role.id]
        let availableVoices = appModel.safeVoiceCatalog?.data.filter {
            $0.available && $0.productionReady != false
        } ?? []

        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    SessionVoiceBadge(label: String(role.displayName.prefix(1)))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                            Text(role.displayName)
                                .font(SpeechRailDesignTokens.Typography.sectionTitle)
                                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                            if role.isNarrator {
                                StatusPill(tone: .healthy, label: "旁白")
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

                let persona = role.resolvedVoicePersona(peers: workflow.characters)
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

                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Menu {
                        if availableVoices.isEmpty {
                            ForEach(Self.fallbackPresetChoices, id: \.id) { preset in
                                Button("\(preset.name)（\(preset.id)）") {
                                    let b = AudiobookVoiceBinding(
                                        roleID: role.id,
                                        voiceID: preset.id,
                                        voiceRevision: "v1",
                                        modelRevision: "qwen3-tts-v1"
                                    )
                                    Task { await workflow.bindVoice(roleID: role.id, binding: b) }
                                }
                            }
                        } else {
                            ForEach(availableVoices) { voice in
                                Button("\(voice.name)（\(voice.id)）") {
                                    let b = AudiobookVoiceBinding(
                                        roleID: role.id,
                                        voiceID: voice.id,
                                        voiceRevision: voice.voiceRevision ?? "v1",
                                        modelRevision: voice.model.catalogRevision ?? voice.model.runtimeRevision ?? "v1"
                                    )
                                    Task { await workflow.bindVoice(roleID: role.id, binding: b) }
                                }
                            }
                        }
                    } label: {
                        let boundDisplay: String? = binding.map { b in
                            if let matched = availableVoices.first(where: { $0.id == b.voiceID }) {
                                return "已绑：\(matched.name)"
                            }
                            if let preset = Self.fallbackPresetChoices.first(where: { $0.id == b.voiceID }) {
                                return "已绑：\(preset.name)"
                            }
                            return "已绑：\(b.voiceID)"
                        }
                        Label(
                            boundDisplay ?? "选择可用音色…",
                            systemImage: "waveform"
                        )
                    }
                    .speechRailButton(.secondary)

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
