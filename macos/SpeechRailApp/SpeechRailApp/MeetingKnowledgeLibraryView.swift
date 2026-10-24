import SwiftUI

/// 会议知识库（MA-12 / MC-48～MC-52、MC-75）。
///
/// 这一页只做两件事：**把会议列全**，以及**把选中那一场的纪要读出来**。
/// 三条约定决定了它的形状：
/// - **完整分页**：只显示最近 8 场，用户会以为另外 92 场没了（MC-52）；
/// - **详情一次读取、整体提交**：代次对不上的迟到结果直接丢掉，
///   所以从 A 切到 B 之后，A 的正文不会盖到 B 的标题上（MC-50）；
/// - **查看历史 ≠ 正在录的那场**：录制中的会议也列在这里，但标成进行中，
///   打开是只读的，不改正在跑的那一份（MC-48）。
///
/// 高级操作（标签、项目、删除、导出）留在详情里的"更多"菜单，
/// 首屏只留搜索、翻页和纪要/转录切换。
struct MeetingKnowledgeLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionPreferences.self) private var preferences
    @State private var model: MeetingLibraryModel
    @State private var searchText = ""
    @State private var askPresented = false
    @State private var prepPresented = false
    /// 翻页位置。冷启动直接打开某场会议（MC-48）时靠它回到原来的位置。
    @AppStorage("meetingLibraryOffset") private var restoredOffset = 0

    private let coordinator: SessionCoordinator
    /// 正在核对的那一场。nil = 只读浏览，不开编辑器。
    @State private var reviewTarget: MeetingReviewSnapshot?
    @State private var reviewVersion: MinutesVersion?
    /// 等用户点头的那一次删除。`nil` = 没有待确认的动作。
    ///
    /// 单独一个状态而不是复用模型：**确认是界面的事**，模型只管执行。
    /// 混在一起就会出现"模型记住了上一次待确认的动作"这类说不清的状态。
    @State private var pendingDeletion: PendingDeletion?
    /// 导出失败时要说的那一句。`nil` = 没有失败，没有理由弹一个空面板。
    @State private var exportError: String?
    /// 新建项目的输入。空串 = 没打开面板。
    @State private var projectNameDraft = ""
    @State private var newProjectPromptPresented = false
    /// 正在改名的项目。nil = 没打开。
    @State private var renameTarget: MeetingProject?
    @State private var renameDraft = ""
    /// 标签编辑。逗号或顿号分隔。
    @State private var tagDraft = ""
    @State private var tagsSheetPresented = false
    /// 项目管理面板（改名）。没有删除——方案没要求，库层也没有那个 API。
    @State private var manageProjectsPresented = false

    /// 「未完成事项」面板（MC-56）。默认不占首屏——多数时候用户是来找某一场会，
    /// 不是来看待办清单的；但它必须是**一个能点到的入口**，不是库里一个没人调的方法。
    @State private var openItemsPresented = false
    /// 正在改负责人／期限的那一条。`nil` = 没有打开编辑面板。
    @State private var openItemEditTarget: KnowledgeEvidence?
    /// 正在查看变更历史的那一条。`nil` = 没有打开历史面板。
    @State private var openItemTimelineTarget: KnowledgeEvidence?
    /// 跨会议结论冲突面板（MC-57、MC-58）。
    @State private var conflictsPresented = false
    /// 等用户点头的那一次"取代"确认。点一下就落状态，不给回头路。
    @State private var pendingSupersession: KnowledgeChangeProposal?
    /// 归档包导入前的预检结果。**没看过它就不许导入**（MC-71）。
    @State private var archivePreview: ArchiveImportPreview?
    /// 导入完成后的实数。`nil` = 还没导。
    @State private var archiveImportNotice: String?
    /// 导出归档包成功时的一句话。
    @State private var archiveExportNotice: String?

    /// 一次导入预检。带着包路径，导入时要用。
    private struct ArchiveImportPreview: Identifiable {
        let id = UUID()
        var packageURL: URL
        var preview: KnowledgeArchivePreview
    }

    /// 一次待确认的删除。用 `Identifiable` 驱动 `confirmationDialog`。
    private struct PendingDeletion: Identifiable {
        let id = UUID()
        let documentID: String
        let mode: MeetingDeletionMode
        /// 会议标题。确认面板要指名道姓，不能只说"这一场"。
        let title: String
    }

    public init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
        _model = State(initialValue: MeetingLibraryModel(coordinator: coordinator))
    }

    public var body: some View {
        NavigationSplitView {
            listColumn
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
        } detail: {
            detailColumn
        }
        .frame(
            minWidth: SpeechRailDesignTokens.Layout.meetingLibraryMinimumWidth,
            idealWidth: SpeechRailDesignTokens.Layout.meetingLibraryIdealWidth,
            maxWidth: .infinity,
            minHeight: SpeechRailDesignTokens.Layout.meetingLibraryMinimumHeight,
            idealHeight: SpeechRailDesignTokens.Layout.meetingLibraryIdealHeight,
            maxHeight: .infinity
        )
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    askPresented = true
                } label: {
                    Label("问知识库", systemImage: "sparkles")
                }
                .help("向知识库提问，跨会议检索答案与依据")

                Button {
                    prepPresented = true
                    Task { await model.loadPrepDraft() }
                } label: {
                    Label("会前准备稿", systemImage: "doc.text")
                }
                .help("汇总上一场未决事项与待核对结论，辅助本次会前准备")

                Menu {
                    Button {
                        openItemsPresented = true
                        Task { await model.loadOpenItems(offset: 0) }
                    } label: {
                        Label(
                            model.openItemCounts.total > 0
                                ? "未完成事项 (\(model.openItemCounts.total))"
                                : "未完成事项",
                            systemImage: "checklist"
                        )
                    }
                    Button {
                        conflictsPresented = true
                        Task { await model.loadConflicts() }
                    } label: {
                        Label(
                            model.conflicts.isEmpty
                                ? "跨会议冲突"
                                : "跨会议冲突 (\(model.conflicts.count))",
                            systemImage: "exclamationmark.triangle"
                        )
                    }
                    Divider()
                    Button(action: chooseArchiveToImport) {
                        Label("导入归档包…", systemImage: "square.and.arrow.down")
                    }
                    Divider()
                    Button {
                        projectNameDraft = ""
                        newProjectPromptPresented = true
                    } label: {
                        Label("新建项目…", systemImage: "folder.badge.plus")
                    }
                    Button {
                        manageProjectsPresented = true
                    } label: {
                        Label("管理项目…", systemImage: "folder")
                    }
                } label: {
                    Label("更多操作", systemImage: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .help("跨会议追踪、待办事项、冲突裁决与归档包管理")

                Button("完成") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .sheet(item: $reviewTarget) { target in
            reviewSheet(target)
        }
        .confirmationDialog(
            deletionDialogTitle,
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { pending in
            Button(pending.mode.title, role: .destructive) {
                Task { await model.delete(pending.documentID, mode: pending.mode) }
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: { pending in
            Text(deletionDialogMessage(pending))
        }
        .sheet(item: $archivePreview) { pending in
            archivePreviewSheet(pending)
        }
        .alert("新建项目", isPresented: $newProjectPromptPresented) {
            TextField("项目名", text: $projectNameDraft)
            Button("取消", role: .cancel) {}
            Button("新建") {
                let name = projectNameDraft
                Task { _ = await model.createProject(named: name) }
            }
        } message: {
            Text("项目是你自己分的，导入和生成都不会替你猜。")
        }
        .alert("项目改名", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("项目名", text: $renameDraft)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("保存") {
                guard let project = renameTarget else { return }
                let name = renameDraft
                renameTarget = nil
                Task { await model.renameProject(id: project.id, to: name) }
            }
        } message: {
            Text("改名只改显示，归属这场会议的项目不变。")
        }
        .sheet(isPresented: $manageProjectsPresented) { manageProjectsSheet }
        .sheet(isPresented: $openItemsPresented) { openItemsSheet }
        .sheet(item: $openItemEditTarget) { target in
            openItemEditSheet(target)
        }
        .sheet(item: $openItemTimelineTarget) { target in
            openItemTimelineSheet(target)
        }
        .sheet(isPresented: $conflictsPresented) { conflictsSheet }
        .sheet(isPresented: $askPresented) { askSheet }
        .sheet(isPresented: $prepPresented) { prepSheet }
        .confirmationDialog(
            "确认「后一条取代前一条」？",
            isPresented: Binding(
                get: { pendingSupersession != nil },
                set: { if !$0 { pendingSupersession = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("确认取代", role: .destructive) {
                guard let conflict = pendingSupersession else { return }
                pendingSupersession = nil
                Task { await model.confirmSuperseding(conflict) }
            }
            Button("取消", role: .cancel) { pendingSupersession = nil }
        } message: {
            // 说清这一步之后库里变成什么样：旧结论仍在，只是不再作为当前说法。
            Text("旧结论不会消失，两条都留着。只是标记为「新结论取代了它」，以后不再问你同一处矛盾。")
        }
        .sheet(isPresented: $tagsSheetPresented) { tagsSheet }
        .operationFeedback([
            OperationFeedback(exportError, title: "操作未完成", onDismiss: { exportError = nil }),
            OperationFeedback(model.projectError, title: "项目或标签未保存", onDismiss: { model.clearProjectError() }),
            OperationFeedback(model.archiveError),
            OperationFeedback(model.listError, title: "会议列表未读取"),
            OperationFeedback(model.detailError, title: "会议未打开"),
            OperationFeedback(!openItemsPresented ? model.openItemWriteError.map { _ in model.openItemWriteHint } : nil,
                              title: "事项未保存"),
            OperationFeedback(!conflictsPresented ? model.conflictWriteError.map { _ in model.conflictWriteHint } : nil,
                              title: "取代关系未保存"),
            OperationFeedback(archiveImportNotice, tone: .healthy, title: "归档包已导入", autoDismiss: true,
                              onDismiss: { archiveImportNotice = nil }),
            OperationFeedback(archiveExportNotice, tone: .healthy, title: "归档包已导出", autoDismiss: true,
                              onDismiss: { archiveExportNotice = nil })
        ])
        .task {
            if model.rows.isEmpty {
                await model.loadPage(offset: restoredOffset)
            }
            await model.loadProjects()
            // 入口上的数字要真的有内容：面板可能一次都没打开过，
            // 只在点开时才查的话，标题永远是"未完成事项"没有数字。
            await model.loadOpenItems(offset: 0)
            await model.loadConflicts()
            if model.selectedDocumentID == nil, let firstID = model.rows.first?.id {
                await model.select(firstID)
            }
        }
    }

    private var deletionDialogTitle: String {
        "确定删除「\(pendingDeletion?.title ?? "")」吗？"
    }

    /// 确认面板要说明**这一步之后还剩什么**，不只说"不可撤销"。
    private func deletionDialogMessage(_ pending: PendingDeletion) -> String {
        switch pending.mode {
        case .archive:
            return "归档后它不再出现在搜索和问答中，数据完整保留，可随时恢复。"
        case .removeTranscript:
            return "将永久清除录音文字记录，保留纪要与结论，此操作无法撤销。"
        case .deleteEverything:
            return "将永久删除该会议的全部转写、纪要、结论与关联记录，此操作无法撤销。"
        }
    }

    // MARK: - 列表

    private var listColumn: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: SpeechRailDesignTokens.Layout.sessionListWidth)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("会议知识库")
                    .font(.title2)
                    .fontWeight(.bold)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            searchField
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                projectMenu
                Spacer()
                archivedToggle
            }
            if model.openItemCounts.total > 0 || !model.conflicts.isEmpty {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    if model.openItemCounts.total > 0 {
                        Button {
                            openItemsPresented = true
                            Task { await model.loadOpenItems(offset: 0) }
                        } label: {
                            HStack(spacing: SpeechRailDesignTokens.Spacing.tiny) {
                                Image(systemName: "checklist")
                                    .font(SpeechRailDesignTokens.Typography.chipIcon)
                                Text("\(model.openItemCounts.total) 项未完成")
                                    .font(.caption2)
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, SpeechRailDesignTokens.Spacing.compact)
                            .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)
                            .background(SpeechRailDesignTokens.Color.recessedField, in: SpeechRailDesignTokens.Corner.compactShape)
                            .foregroundStyle(SpeechRailDesignTokens.Color.info)
                        }
                        .buttonStyle(.plain)
                        .help("查看所有尚未完成的跟进事项")
                    }
                    if !model.conflicts.isEmpty {
                        Button {
                            conflictsPresented = true
                            Task { await model.loadConflicts() }
                        } label: {
                            HStack(spacing: SpeechRailDesignTokens.Spacing.tiny) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(SpeechRailDesignTokens.Typography.chipIcon)
                                Text("\(model.conflicts.count) 处冲突")
                                    .font(.caption2)
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, SpeechRailDesignTokens.Spacing.compact)
                            .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)
                            .background(SpeechRailDesignTokens.Color.recessedField, in: SpeechRailDesignTokens.Corner.compactShape)
                            .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                        }
                        .buttonStyle(.plain)
                        .help("查看跨会议之间对不上的结论并裁决")
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Layout.contentPadding)
        .padding(.top, SpeechRailDesignTokens.Spacing.md)
        .padding(.bottom, SpeechRailDesignTokens.Spacing.sm)
    }

    /// 未完成事项（MC-56）。**给出全量总数，并且翻得完**——
    /// 只显示最近 10 条却在标题里写"共 37 条"，比不给这个面板更糟。
    private var openItemsSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: Binding(
                    get: { model.openItemMode },
                    set: { mode in Task { await model.setOpenItemMode(mode) } }
                )) {
                    ForEach(MeetingLibraryModel.OpenItemMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("未完成事项清单显示范围")

                if model.openItemsError != nil {
                    VStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                        Text("暂时无法读取未完成事项。").foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        Button("重试") { Task { await model.loadOpenItems(offset: 0) } }
                    }
                    .padding(SpeechRailDesignTokens.Layout.contentPadding)
                    Spacer()
                } else if model.isLoadingOpenItems && model.openItems.isEmpty {
                    ProgressView().controlSize(.small)
                    Spacer()
                } else if model.openItems.isEmpty {
                    // 空态说清为什么空，不写"暂无数据"。
                    Text(model.openItemsEmptyHint)
                        .font(.callout)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer()
                } else {
                    List {
                        Section {
                            ForEach(model.openItems) { item in
                                openItemRow(item)
                            }
                        } header: {
                            Text(model.openItemsHeadline)
                        } footer: {
                            if model.hasMoreOpenItems {
                                Button("再显示 \(min(model.openItemLimit, model.openItemCounts.total - model.openItems.count)) 条") {
                                    Task { await model.loadMoreOpenItems() }
                                }
                                .buttonStyle(.link)
                            } else {
                                Text("已经到底了，一共 \(model.openItemCounts.total) 条。")
                            }
                        }
                    }
                }
            }
            .navigationTitle("未完成事项")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("好") { openItemsPresented = false }
                        .keyboardShortcut(.defaultAction)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(
            minWidth: SpeechRailDesignTokens.Layout.Sheet.regularWidth,
            minHeight: SpeechRailDesignTokens.Layout.Sheet.mediumMinimumHeight
        )
        .operationFeedback([
            OperationFeedback(model.openItemWriteError.map { _ in model.openItemWriteHint }, title: "事项未保存"),
            OperationFeedback(model.openItemsError, title: "未完成事项未读取")
        ])
    }

    /// 一条未完成事项。状态、负责人、期限都摆出来——
    /// 只给一句正文，用户还得自己去翻会议才知道这事归谁。
    private func openItemRow(_ item: KnowledgeEvidence) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            Text(item.text)
                .font(.body)
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                // 没记录过进度时显示"未完成"而不是"不知道"：会上定了就是定了。
                Text(item.execution?.status.title ?? ActionExecutionStatus.open.title)
                    .font(.caption)
                    .foregroundStyle(
                        item.execution?.status == .blocked
                            ? SpeechRailDesignTokens.Color.attention
                            : SpeechRailDesignTokens.Color.inkSecondary
                    )
                if let owner = item.execution?.ownerText {
                    Text("· \(owner)").font(.caption).foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
                if let due = item.execution?.dueText ?? item.execution?.dueDate.map(Self.dateText) {
                    Text("· \(due)").font(.caption).foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
                Spacer()
                if let occurredAt = item.occurredAt {
                    Text(occurredAt.speechRailFormatted(.date))
                        .font(.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
                Spacer()
                openItemMenu(item)
            }
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .accessibilityElement(children: .contain)
    }

    /// 跨会议结论冲突（MC-58）。**只摆矛盾，让用户定，系统不合成一致意见**。
    private var conflictsSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.conflictError != nil {
                    VStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                        Text("暂时无法读取跨会议结论。").foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        Button("重试") { Task { await model.loadConflicts() } }
                    }
                    .padding(SpeechRailDesignTokens.Layout.contentPadding)
                    Spacer()
                } else if model.isLoadingConflicts && model.conflicts.isEmpty {
                    ProgressView().controlSize(.small)
                    Spacer()
                } else if model.conflicts.isEmpty {
                    Text(model.conflictsEmptyHint)
                        .font(.callout)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer()
                } else {
                    List {
                        ForEach(model.conflicts) { conflict in
                            conflictRow(conflict)
                        }
                    }
                }
            }
            .navigationTitle(model.conflictsHeadline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("好") { conflictsPresented = false }
                        .keyboardShortcut(.defaultAction)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(
            minWidth: SpeechRailDesignTokens.Layout.Sheet.formWidth,
            minHeight: SpeechRailDesignTokens.Layout.Sheet.formMinimumHeight
        )
        .operationFeedback([
            OperationFeedback(model.conflictWriteError.map { _ in model.conflictWriteHint }, title: "取代关系未保存"),
            OperationFeedback(model.conflictError, title: "跨会议结论未读取")
        ])
    }

    /// 一处矛盾。**两边的原话都要摆出来**——只给一个"存在冲突"的提示，
    /// 用户没法判断到底该改哪一句。
    private func conflictRow(_ conflict: KnowledgeChangeProposal) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            Text(conflict.summary)
                .font(.callout)
            if let previous = conflict.previousText {
                labelledDecision(previous, tag: "早那场")
            }
            if let proposed = conflict.proposedText {
                labelledDecision(proposed, tag: "晚那场")
            }
            if let detail = conflict.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            Button("后一条取代前一条…") { pendingSupersession = conflict }
                .buttonStyle(.link)
                .controlSize(.small)
                .disabled(model.pendingConflictID == conflict.id)
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .accessibilityElement(children: .contain)
    }

    /// 一侧的结论，用固定宽度的小标签标出它来自哪一场。
    private func labelledDecision(_ text: String, tag: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SpeechRailDesignTokens.Spacing.xs) {
            Text(tag)
                .font(.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .frame(width: SpeechRailDesignTokens.Layout.labelledDecisionTagWidth, alignment: .leading)
            Text(text)
                .font(.body)
            Spacer()
        }
    }

    /// 一条行动的完整变更历史（MC-59）。
    ///
    /// **只读**：三月承诺四月、四月改成五月之后，三月那条并没有消失，
    /// 这里按生效时间升序全摆出来。界面不提供任何改状态的入口——
    /// 改状态走菜单，"看历史"和"改状态"混在一处，用户会顺手改掉一条。
    private func openItemTimelineSheet(_ item: KnowledgeEvidence) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                if model.executionTimeline.isEmpty {
                    Text(model.executionTimelineEmptyHint)
                        .font(.callout)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(SpeechRailDesignTokens.Layout.contentPadding)
                    Spacer()
                } else {
                    List {
                        Section {
                            ForEach(model.executionTimeline, id: \.id) { event in
                                executionEventRow(event)
                            }
                        } header: {
                            Text(model.executionTimelineHeadline)
                        } footer: {
                            Text("这是当时记下的原话，后来的修改没有改写它。")
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("变更历史")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("好") {
                        model.clearTimeline()
                        openItemTimelineTarget = nil
                    }
                }
            }
        }
        .frame(
            minWidth: SpeechRailDesignTokens.Layout.Sheet.regularWidth,
            minHeight: SpeechRailDesignTokens.Layout.Sheet.regularMinimumHeight
        )
    }

    /// 一次状态变化。**生效时间与记录时间不是一回事**：
    /// 补记一件三月就承诺过的事，今天录进去，生效时间仍然是三月。
    private func executionEventRow(_ event: KnowledgeExecutionEvent) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text(event.status.title)
                    .font(.callout)
                Text(event.validFrom.speechRailFormatted())
                    .font(.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Spacer()
            }
            // ViewBuilder 里不能写 `var`，抽成函数。
            let facts = Self.executionFacts(event)
            if let facts {
                Text(facts)
                    .font(.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            if let note = event.note {
                Text(note).font(.caption).foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
        .accessibilityElement(children: .combine)
    }

    /// 一次状态变化里**当时记着的**负责人与期限。没有就是没有，不留空位占一行。
    private static func executionFacts(_ event: KnowledgeExecutionEvent) -> String? {
        var facts: [String] = []
        if let owner = event.ownerText { facts.append("负责人 \(owner)") }
        if let due = event.dueText { facts.append("期限 \(due)") }
        return facts.isEmpty ? nil : facts.joined(separator: " · ")
    }

    /// 一条未完成事项能做的动作。**列得出却点不动的清单等于让用户回去翻会议**。
    ///
    /// 菜单而不是常驻按钮：完成／受阻／放弃是低频动作，常驻会把正文挤成两行，
    /// 而"改负责人与期限"本来就该是一个表单，不是一个开关。
    private func openItemMenu(_ item: KnowledgeEvidence) -> some View {
        let busy = model.pendingOpenItemID == item.id
        return Menu {
            if item.execution?.status == .done || item.execution?.status == .dropped {
                Button("重新打开") { Task { await model.markOpenItem(item.id, status: .open) } }
            }
            Button("标为完成") { Task { await model.markOpenItem(item.id, status: .done) } }
            Button("标为受阻") { Task { await model.markOpenItem(item.id, status: .blocked) } }
            Divider()
            Button("改负责人与期限…") { openItemEditTarget = item }
            // 历史是**只读**的：它回答"这条承诺是怎么变成今天这样的"，
            // 用户在这里看不到任何能改状态的东西。
            Button("查看变更历史…") {
                Task {
                    openItemTimelineTarget = item
                    await model.loadTimeline(for: item)
                }
            }
            Button("放弃这件事", role: .destructive) {
                Task { await model.markOpenItem(item.id, status: .dropped) }
            }
        } label: {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                // 常用动作直接摆在行上，其余进菜单——"完成"是用户来这里的主要目的。
                Image(systemName: "checkmark.circle")
            }
        }
        .menuStyle(.borderlessButton)
        .disabled(busy)
        .accessibilityLabel("修改「\(item.text)」的完成状态、负责人或期限")
    }

    /// 负责人与期限。**分两个输入框，不合并**——期限可以是「五月前」这种话，
    /// 硬塞进日期选择器等于逼用户编一个自己没有的信息。
    private func openItemEditSheet(_ item: KnowledgeEvidence) -> some View {
        OpenItemEditSheet(
            text: item.text,
            initialOwner: item.execution?.ownerText ?? "",
            initialDue: item.execution?.dueText ?? "",
            onSave: { owner, due in
                openItemEditTarget = nil
                Task { await model.updateOpenItem(item.id, owner: owner, due: due) }
            },
            onCancel: { openItemEditTarget = nil }
        )
    }

    private static func dateText(_ date: Date) -> String {
        date.speechRailFormatted(.date)
    }

    /// 项目筛选（MA-13）。**筛选与列表、计数同源**（MC-51/MC-53），
    /// 所以这里切一下，标题旁的"共 N 场"立刻跟着变。
    /// 跨会议问答（MA-17）。**这一层此前完全没有入口**：
    /// `MeetingKnowledgeQueryService` 与它的拒答／分页／注入防护／展示前范围复核
    /// 都实现完整、都有测试，但生产代码里没有任何地方构造它——
    /// 用户能搜、能筛、能导出，却**没法问一句**。
    private var askSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                TextField("问一句，例如：上次说的灰度排期是哪天", text: $model.askDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .accessibilityLabel("要问的问题")
                HStack {
                    // 范围跟着库页当前的筛选走，这里要说出来：不然用户以为问的是全库。
                    Text(askScopeCaption)
                        .font(.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    Spacer()
                    if model.isAsking {
                        ProgressView().controlSize(.small)
                    }
                    Button("问") {
                        Task { await model.ask(model.askDraft, resolvedConfiguration: resolvedAskConfiguration) }
                    }
                    .disabled(model.isAsking || model.askDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
                Divider()
                answerBody
                Spacer(minLength: 0)
            }
            .padding(SpeechRailDesignTokens.Layout.contentPadding)
            .frame(
                minWidth: SpeechRailDesignTokens.Layout.Sheet.regularWidth,
                minHeight: SpeechRailDesignTokens.Layout.Sheet.regularMinimumHeight,
                alignment: .leading
            )
            .navigationTitle("问知识库")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        askPresented = false
                        model.clearAnswer()
                    }
                }
            }
        }
        .operationFeedback([
            OperationFeedback(model.askError, title: "提问未完成")
        ])
    }

    private var resolvedAskConfiguration: ResolvedLLMConfiguration {
        preferences.resolvedLLMConfiguration(for: .minutes)
    }

    private var askScopeCaption: String {
        if let projectID = model.projectID,
           let name = model.projects.first(where: { $0.id == projectID })?.name {
            return "只问「\(name)」这个项目里的会议"
        }
        return model.includesArchived
            ? "含已归档的会议"
            : "只问未归档的会议"
    }

    @ViewBuilder
    private var answerBody: some View {
        if let answer = model.answer {
            if let refusal = answer.draft.refusal {
                // 拒答要说清是**哪一种**。三句话的语气完全不同：
                // "没记录"不是"你问错了"，也不是"这件事没发生过"。
                Text(refusal.message)
                    .font(.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(answer.draft.segments.enumerated()), id: \.offset) { _, segment in
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.hairline) {
                    Text(segment.text)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(segment.evidenceIDs, id: \.self) { id in
                        if let evidence = answer.retrieval.evidence.first(where: { $0.id == id }) {
                            // 出处要看得见原话。只给"来自第 2 场会"等于让用户回去自己找。
                            Text("「\(evidence.text)」")
                                .font(.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if answer.stoppedAtPageLimit {
                // 翻页有上限，而"以为翻到底了"是这类列表问题最坏的失败形态。
                Text("已经翻到这次检索的上限，可能还有更早的记录没被列进来。")
                    .font(.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.attention)
            }
        } else if !model.isAsking {
            Text("问一句，答案会标出依据的是哪几场会的哪几条。没有依据时它会直说没有，而不是编一段。")
                .font(.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 会前准备稿（MA-17）。**先核对的那一组排在最前面**——
    /// 拿一条还没核对的结论去做准备，等于把不确定性直接带进下一场会。
    ///
    /// 它是纯数据：不发送、不建日程、不写回库，所以这里也不给任何"发出去了"的出口。
    private var prepSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.prepError != nil {
                    VStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                        Text("暂时无法读取会前准备稿。").foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        Button("重试") { Task { await model.loadPrepDraft() } }
                    }
                    .padding(SpeechRailDesignTokens.Layout.contentPadding)
                    Spacer()
                } else if model.isLoadingPrep && model.prepDraft == nil {
                    ProgressView().controlSize(.small)
                    Spacer()
                } else if let draft = model.prepDraft, draft.isEmpty {
                    Text("你授权的范围内没有待跟进的内容。")
                        .font(.callout)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(SpeechRailDesignTokens.Layout.contentPadding)
                    Spacer()
                } else if let draft = model.prepDraft {
                    List {
                        // 顺序就是"该先看什么"的顺序，不是数据的自然顺序。
                        if !draft.needsReview.isEmpty {
                            Section {
                                ForEach(draft.needsReview) { prepRow($0) }
                            } header: {
                                Text("先核对（这几条还不能当结论用）")
                            } footer: {
                                Text("这些结论的出处还没核对过，或两场会说得不一致。带进下一场会之前先定下来。")
                            }
                        }
                        if !draft.openQuestions.isEmpty {
                            Section {
                                ForEach(draft.openQuestions) { prepRow($0) }
                            } header: {
                                Text("上次没答完")
                            }
                        }
                        if !draft.pendingActions.isEmpty {
                            Section {
                                ForEach(draft.pendingActions) { prepRow($0) }
                            } header: {
                                Text("还没做完")
                            }
                        }
                        Section {
                            Text(prepFooter(draft))
                                .font(.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        }
                    }
                }
            }
            .navigationTitle("会前准备稿")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("好") {
                        prepPresented = false
                        model.clearPrepDraft()
                    }
                    .keyboardShortcut(.defaultAction)
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(
            minWidth: SpeechRailDesignTokens.Layout.Sheet.regularWidth,
            minHeight: SpeechRailDesignTokens.Layout.Sheet.mediumMinimumHeight
        )
        .operationFeedback([
            OperationFeedback(model.prepError, title: "会前准备稿未读取")
        ])
    }

    /// 一条待跟进。**出处原话要摆出来**：只给一句归纳，用户没法判断这条值不值得带进下一场会。
    private func prepRow(_ item: KnowledgeEvidence) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            Text(item.text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text(item.status.summary)
                    .font(.caption)
                    .foregroundStyle(
                        item.isEstablishedFact
                            ? SpeechRailDesignTokens.Color.inkSecondary
                            : SpeechRailDesignTokens.Color.attention
                    )
                if let occurredAt = item.occurredAt {
                    Text("· \(occurredAt.speechRailFormatted(.date))")
                        .font(.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
            }
            ForEach(item.anchors) { anchor in
                if let quote = anchor.quote, !quote.isEmpty {
                    Text("「\(quote)」")
                        .font(.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.hairline)
    }

    /// 页脚。两件事必须说清：有没有被截断，以及这份东西**不会**自己发出去。
    private func prepFooter(_ draft: MeetingPrepDraft) -> String {
        var lines: [String] = []
        if draft.stoppedAtLimit {
            // 命中超过一次能列出的条数时说清只列了前面一段，
            // 否则用户会把这一屏当成"全部待跟进"。
            lines.append("命中共 \(draft.totalMatched) 条，这次只列出了前 \(draft.listedCount) 条。")
        }
        lines.append("这份准备稿只是把你已授权范围内的未决与待办列出来，不会自动发送，也不会创建日程。")
        return lines.joined(separator: "\n\n")
    }

    private var projectMenu: some View {
        Menu {
            Button("全部项目") { Task { await model.filter(projectID: nil) } }
            if !model.projects.isEmpty { Divider() }
            ForEach(model.projects) { project in
                Button(project.name) { Task { await model.filter(projectID: project.id) } }
            }
            Divider()
            Button("新建项目…") {
                projectNameDraft = ""
                newProjectPromptPresented = true
            }
            Button("管理项目…") { manageProjectsPresented = true }
        } label: {
            // 说清当前筛在哪儿，否则用户不知道列表为什么少了。
            Label(model.projectID.flatMap { id in model.projects.first { $0.id == id }?.name }
                ?? "全部项目", systemImage: "folder")
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .accessibilityLabel("按项目筛选会议")
    }

    /// 「连归档的一起列」。默认不列——归档的意义就是搜索、导出、问答都看不见它。
    ///
    /// 但撤不了归档，「可恢复」就是一句空话：这个开关是用户把归档件重新摆出来看的入口。
    /// 它**不**把归档件恢复成可用——那要走详情里的「撤销归档」，两件事不混。
    private var archivedToggle: some View {
        Toggle(isOn: Binding(
            get: { model.includesArchived },
            set: { value in Task { await model.setIncludesArchived(value) } }
        )) {
            Text("连归档的一起列")
                .font(.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
        }
        .toggleStyle(.checkbox)
        .accessibilityHint("归档的会议默认不列出来，打开这个才能看到并撤销归档")
    }

    private var subtitle: String {
        if model.counts.total == 0 { return "还没有会议记录" }
        var parts = ["共 \(model.counts.total) 场"]
        if model.counts.needsReview > 0 { parts.append("\(model.counts.needsReview) 条待核对") }
        return parts.joined(separator: " · ")
    }

    private var searchField: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .accessibilityHidden(true)
            TextField("搜索标题、项目或会议里说过的话", text: $searchText)
                .textFieldStyle(.plain)
                .onSubmit { Task { await model.search(searchText) } }
                .accessibilityLabel("搜索标题、项目或会议里说过的话")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    Task { await model.search("") }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }
        }
        .speechRailSingleLineInput(.regular)
    }

    @ViewBuilder
    private var content: some View {
        if model.listError != nil {
            // 故障只说当前问题和一个有效出口，不堆一串可能的原因。
            VStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                Text("读不了会议列表").font(.headline)
                Button("重试") { Task { await model.reload() } }
            }
            .padding(SpeechRailDesignTokens.Layout.contentPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if model.rows.isEmpty && !model.isLoadingList {
            ContentUnavailableView {
                Label(searchText.isEmpty ? "还没有会议记录" : "没有匹配的会议", systemImage: "books.vertical")
            } description: {
                Text(model.emptyStateHint)
            } actions: {
                if !searchText.isEmpty {
                    Button("清除搜索") {
                        searchText = ""
                        Task { await model.search("") }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        } else {
            List(selection: Binding(
                get: { model.selectedDocumentID },
                set: { id in Task { await model.select(id) } }
            )) {
                ForEach(model.rows) { row in
                    MeetingLibraryRowView(row: row)
                        .speechRailSelectableRow()
                        .tag(row.id)
                        .listRowBackground(
                            row.id == model.selectedDocumentID
                                ? SpeechRailDesignTokens.Surface.selectionTint
                                : nil
                        )
                        .listRowInsets(EdgeInsets(
                            top: SpeechRailDesignTokens.Spacing.xs,
                            leading: SpeechRailDesignTokens.Spacing.md,
                            bottom: SpeechRailDesignTokens.Spacing.xs,
                            trailing: SpeechRailDesignTokens.Spacing.md
                        ))
                        .contextMenu {
                            Button(role: .destructive) {
                                requestRowDeletion(row, mode: .deleteEverything)
                            } label: {
                                Label("删除会议", systemImage: "trash")
                            }
                            Button {
                                requestRowDeletion(row, mode: .archive)
                            } label: {
                                Label("归档会议", systemImage: "archivebox")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                requestRowDeletion(row, mode: .deleteEverything)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
                if model.hasMore {
                    HStack {
                        Spacer()
                        Button("加载更多（剩余 \(max(0, model.counts.total - model.rows.count)) 场）") {
                            Task { await model.loadMore() }
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                        .accessibilityHint("列表按时间倒序排列，翻页不会重复或漏掉会议")
                        Spacer()
                    }
                    .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
                }
            }
            .speechRailSelectableList()
            .onKeyPress(.delete) {
                if let selectedID = model.selectedDocumentID,
                   let row = model.rows.first(where: { $0.id == selectedID }) {
                    requestRowDeletion(row, mode: .deleteEverything)
                    return .handled
                }
                return .ignored
            }
        }
    }


    // MARK: - 详情

    @ViewBuilder
    private var detailColumn: some View {
        if model.detailError != nil {
            VStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                Text("读不了这场会议").font(.headline)
                Button("重试") { Task { await model.open(documentID: model.selectedDocumentID ?? "") } }
            }
            .padding(SpeechRailDesignTokens.Layout.contentPadding)
        } else if let snapshot = model.snapshot {
            detail(snapshot)
        } else if model.isLoadingDetail {
            ProgressView().controlSize(.small)
        } else {
            ContentUnavailableView {
                Label("选一场会议看纪要", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("从左侧列表中选择一场会议，此处将展示其智能纪要、待核对结论与完整转录。数据完全保留在本机。")
            } actions: {
                HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    Button("问知识库") {
                        askPresented = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Button("会前准备稿") {
                        prepPresented = true
                        Task { await model.loadPrepDraft() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
                .padding(.top, SpeechRailDesignTokens.Spacing.xs)
            }
            .speechRailInspectorColumn()
        }
    }

    private func detail(_ snapshot: MeetingReviewSnapshot) -> some View {
        VStack(spacing: 0) {
            detailHeader(snapshot)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.gutter) {
                    changeProposalsBand
                    switch model.detailTab {
                    case .minutes: minutesSection(snapshot)
                    case .transcript: transcriptSection(snapshot)
                    }
                }
                .padding(SpeechRailDesignTokens.Layout.contentPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .speechRailInspectorColumn()
    }

    private func detailHeader(_ snapshot: MeetingReviewSnapshot) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                    HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Text(snapshot.title)
                            .font(.title2)
                            .fontWeight(.bold)
                            .textSelection(.enabled)
                            .accessibilityAddTraits(.isHeader)

                        if snapshot.status != .active {
                            Text(snapshot.status.title)
                                .font(.caption2)
                                .fontWeight(.medium)
                                .padding(.horizontal, SpeechRailDesignTokens.Spacing.compact)
                                .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)
                                .background(SpeechRailDesignTokens.Color.recessedField, in: SpeechRailDesignTokens.Corner.compactShape)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        }
                    }

                    HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                        if let date = snapshot.occurredAt {
                            HStack(spacing: SpeechRailDesignTokens.Spacing.tiny) {
                                Image(systemName: "calendar")
                                    .font(.caption2)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                Text(date.speechRailFormatted())
                                    .font(.caption)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            }
                        }
                        if let projectID = model.projectID,
                           let project = model.projects.first(where: { $0.id == projectID }) {
                            HStack(spacing: SpeechRailDesignTokens.Spacing.tiny) {
                                Image(systemName: "folder")
                                    .font(.caption2)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                Text(project.name)
                                    .font(.caption)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            }
                        }
                        ForEach(model.documentTags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.caption2)
                                .padding(.horizontal, SpeechRailDesignTokens.Spacing.compact)
                                .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)
                                .background(SpeechRailDesignTokens.Color.recessedField, in: SpeechRailDesignTokens.Corner.compactShape)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        }
                    }
                }

                Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)

                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    if let body = snapshot.minutesBody, !body.isEmpty {
                        Button {
                            Task { await beginReview(snapshot) }
                        } label: {
                            Label("核对与修改", systemImage: "pencil.line")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }

                    Button(role: .destructive) {
                        if let docID = model.selectedDocumentID {
                            requestDeletion(docID, mode: .deleteEverything, snapshot)
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.callout)
                            .foregroundStyle(SpeechRailDesignTokens.Color.critical)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("删除这场会议")
                    .accessibilityLabel("删除这场会议")

                    moreMenu(snapshot)
                }
            }

            // 纪要/转录切换置于标题元数据下方
            Picker("内容", selection: $model.detailTab) {
                ForEach(MeetingLibraryModel.DetailTab.allCases, id: \.self) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.regular)
            .padding(.top, SpeechRailDesignTokens.Spacing.tight)
        }
        .padding(.horizontal, SpeechRailDesignTokens.Layout.contentPadding)
        .padding(.top, SpeechRailDesignTokens.Spacing.md)
        .padding(.bottom, SpeechRailDesignTokens.Spacing.sm)
    }

    /// 这一版可能变了什么（MC-54）。
    ///
    /// 与详情里的正文对比**不是一回事**：那边回答"我这次改了什么"（行级），
    /// 这里回答"重新生成把哪条结论换掉了"（条目级，按相似度跨版本配对）。
    ///
    /// **只在真有差异时出现**：没重新生成过就没有这一段，不必占常态的版面。
    /// 读失败要说一句——"看不出变化"和"没去看"对用户是两件事。
    @ViewBuilder
    private var changeProposalsBand: some View {
        if let hint = model.changeProposalsHint {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.attention)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if !model.changeProposals.isEmpty {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text(model.changeProposalsHeadline)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                ForEach(model.changeProposals) { proposal in
                    changeProposalRow(proposal)
                }
                // 说清它是建议：**系统没有因为这份清单改过任何东西**。
                Text("这些只是候选差异。系统没有替你改任何一条，要不要算同一条由你定。")
                    .font(.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            Divider()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, SpeechRailDesignTokens.Spacing.xs)
        }
    }

    private func changeProposalRow(_ proposal: KnowledgeChangeProposal) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Text(proposal.title)
                .font(.callout)
            if let previous = proposal.previousText {
                labelledDecision(previous, tag: "上一版")
            }
            if let proposed = proposal.proposedText {
                labelledDecision(proposed, tag: "这一版")
            }
            if let detail = proposal.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
        .accessibilityElement(children: .contain)
    }

    /// 删除与撤销。**放在「更多」里而不是页头**：首屏只留搜索、翻页和纪要/转录切换，
    /// 删除是低频且不可逆的动作，不该和「读这一场」摆在同一视觉层级上。
    ///
    /// 三档都摆出来而不是只给一个「删除」：它们的**后果完全不同**
    /// （可撤销 / 留结论但没来源 / 全清），合成一个开关的三档强度是在骗用户。
    @ViewBuilder
    private func moreMenu(_ snapshot: MeetingReviewSnapshot) -> some View {
        if let documentID = model.selectedDocumentID {
            Menu {
                Menu("导出这场会议…") {
                    ForEach(exportFormats) { format in
                        Button(format.title) { exportSelected(as: format) }
                    }
                }
                Menu("标签…") {
                    Button("编辑标签…") {
                        tagDraft = model.documentTags.joined(separator: "、")
                        tagsSheetPresented = true
                    }
                }
                Menu("归到项目…") {
                    Button("不归项目") { Task { await model.assignProject(nil) } }
                    if !model.projects.isEmpty { Divider() }
                    ForEach(model.projects) { project in
                        Button(project.name) { Task { await model.assignProject(project.id) } }
                    }
                    Divider()
                    Button("新建项目…") {
                        projectNameDraft = ""
                        newProjectPromptPresented = true
                    }
                }
                Menu("导出归档包…") {
                    Button("完整归档（能再导回这个 App）") { exportArchive(scope: .fullArchive) }
                    Button("分享包（只含被引用的原句）") { exportArchive(scope: .share) }
                }
                Divider()
                if snapshot.status == .archived {
                    Button("撤销归档") {
                        Task { await model.restore(documentID) }
                    }
                    Divider()
                }
                Button("归档（可恢复）") { requestDeletion(documentID, mode: .archive, snapshot) }
                Button("只移除完整转录") { requestDeletion(documentID, mode: .removeTranscript, snapshot) }
                Button("完整删除（不可撤销）", role: .destructive) {
                    requestDeletion(documentID, mode: .deleteEverything, snapshot)
                }
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .disabled(model.pendingDocumentID != nil)
            .help("归档、移除转录或完整删除这场会议")
            .accessibilityLabel("这场会议的更多操作")
        }
    }

    /// 首选格式排在最前，其余按枚举顺序——与会议页的导出菜单同一套规则，
    /// 两处菜单给出的默认项不一样的话，用户会以为是两个功能。
    private var exportFormats: [SessionExportFormat] {
        let preferred = SessionExportFormat.preferred(for: .meeting)
        return [preferred] + SessionExportFormat.allCases.filter { $0 != preferred }
    }

    /// 导入预检（MC-71）。**有真冲突时不给「导入」按钮**——
    /// 同 ID 异内容静默覆盖就是丢用户数据，store 侧会拒绝，界面也不该给这条路。
    private func archivePreviewSheet(_ pending: ArchiveImportPreview) -> some View {
        let preview = pending.preview
        let manifest = preview.manifest
        let identical = preview.conflicts.count - preview.realConflicts.count
        return VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Text("这个包里有什么")
                .font(.headline)
            Text(manifest.documentTitle ?? "未命名会议")
                .font(.callout)
            Text(
                "第 \(manifest.selectedVersion) 版纪要 · \(manifest.scope.title) · "
                    + "导出于 \(manifest.createdAt.speechRailFormatted())"
            )
            .font(.caption)
            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

            archiveCount("要新增", preview.newObjectCount)
            if identical > 0 {
                archiveCount("与本机完全相同，跳过", identical)
            }

            if !preview.realConflicts.isEmpty {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Text("有 \(preview.realConflicts.count) 处同 ID 但内容不同")
                        .font(.callout)
                        .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                    Text("这些是你已经有的内容。这里不提供覆盖入口——先决定要不要保留本机这一份。")
                        .font(.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(preview.realConflicts.prefix(5), id: \.self) { conflict in
                        Text("· \(conflict.kind.rawValue) \(conflict.id)")
                            .font(.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    }
                }
            }

            HStack {
                Spacer()
                if preview.isSafeToImport {
                    Button("导入") {
                        let url = pending.packageURL
                        archivePreview = nil
                        Task { await performImport(at: url) }
                    }
                }
                Button("好", role: .cancel) { archivePreview = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(SpeechRailDesignTokens.Layout.contentPadding)
        .frame(minWidth: SpeechRailDesignTokens.Layout.Sheet.compactWidth, alignment: .leading)
    }

    private func performImport(at packageURL: URL) async {
        do {
            let result = try await model.importArchive(at: packageURL)
            archiveImportNotice = "新增 \(result.inserted.documents) 场会议、\(result.inserted.minutes) 版纪要、"
                + "\(result.inserted.items) 条结论与待办、\(result.inserted.anchors) 处引用；"
                + "跳过 \(result.skippedIdentical) 个相同条目。在左边选会议即可阅读。"
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func archiveCount(_ label: String, _ value: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.callout).foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            Spacer()
            Text("\(value)").font(.callout).monospacedDigit()
        }
    }

    /// 导出**详情正在显示的那一版**纪要（MC-48）。
    ///
    /// 导不出就说导不出：没有会话的导入纪要没有转录行，
    /// 给一个看着像会议的空壳比失败更糟——用户会以为导全了。
    private func exportSelected(as format: SessionExportFormat) {
        Task {
            do {
                guard let payload = try await model.exportPayload() else {
                    exportError = "这场会议没有可导出的转录记录。"
                    return
                }
                guard try SessionExportPanel.write(payload, as: format) else { return }
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    /// 导出归档包（MA-19）。**分享包与完整归档分开摆**，因为它们不是一回事：
    /// 完整归档能再导回这个 App，分享包只装被引用的那几行原句。
    private func exportArchive(scope: KnowledgeArchiveScope) {
        let panel = NSOpenPanel()
        panel.title = "选择归档包存放位置"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "存到这里"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        Task {
            do {
                guard let package = try await model.exportArchive(scope: scope, to: parent) else {
                    exportError = "这场会议还没有可归档的纪要版本。整理出纪要之后才能导出归档包。"
                    return
                }
                archiveExportNotice = "已导出「\(package.lastPathComponent)」。"
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    /// 导入归档包：先选包，**先看预检**，再谈写入（MC-71）。
    private func chooseArchiveToImport() {
        let panel = NSOpenPanel()
        panel.title = "选择一个归档包"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "检查这个包"
        guard panel.runModal() == .OK, let package = panel.url else { return }
        Task {
            do {
                let preview = try await model.previewArchive(at: package)
                archivePreview = ArchiveImportPreview(packageURL: package, preview: preview)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    /// 项目管理。当前只做改名——方案没要求删项目，库层也没有那个 API，
    /// 凭空加一个"删除项目"要么丢会议、要么留一堆孤儿，都不该顺手做。
    private var manageProjectsSheet: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Text("项目")
                .font(.headline)
            if model.projects.isEmpty {
                Text("还没有项目。")
                    .font(.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            } else {
                ForEach(model.projects) { project in
                    HStack {
                        Text(project.name).font(.callout)
                        Spacer()
                        Button("改名") {
                            renameDraft = project.name
                            renameTarget = project
                            manageProjectsPresented = false
                        }
                        .controlSize(.small)
                    }
                }
            }
            HStack {
                Spacer()
                Button("新建项目…") {
                    projectNameDraft = ""
                    manageProjectsPresented = false
                    newProjectPromptPresented = true
                }
                Button("好", role: .cancel) { manageProjectsPresented = false }
                    .keyboardShortcut(.defaultAction)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(SpeechRailDesignTokens.Layout.contentPadding)
        .frame(minWidth: SpeechRailDesignTokens.Layout.creatorVoicePopoverWidth, alignment: .leading)
    }

    /// 标签编辑。**标签是用户写的，导入与生成都不猜**（MA-13），
    /// 所以这里不給建议、不自动补全——用户想到什么就写什么。
    private var tagsSheet: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Text("给这场会议加标签")
                .font(.headline)
            Text("用顿号或逗号分隔。标签是你自己写的，导入和生成都不会替你猜。")
                .font(.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("例如：季度规划、招聘", text: $tagDraft)
                .textFieldStyle(.plain)
                .accessibilityLabel("标签，用顿号或逗号分隔")
            HStack {
                Spacer()
                Button("取消", role: .cancel) { tagsSheetPresented = false }
                Button("保存") {
                    guard let documentID = model.selectedDocumentID else { return }
                    let tags = tagDraft
                        .replacingOccurrences(of: "，", with: "、")
                        .split(separator: "、")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    tagsSheetPresented = false
                    Task {
                        await model.setTags(tags, for: documentID)
                        await model.reload()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(SpeechRailDesignTokens.Layout.contentPadding)
        .frame(minWidth: SpeechRailDesignTokens.Layout.inspectorColumnWidth, alignment: .leading)
    }

    private func requestDeletion(
        _ documentID: String,
        mode: MeetingDeletionMode,
        _ snapshot: MeetingReviewSnapshot
    ) {
        guard MeetingLibraryModel.requiresConfirmation(mode) else {
            Task { await model.delete(documentID, mode: mode) }
            return
        }
        pendingDeletion = PendingDeletion(documentID: documentID, mode: mode, title: snapshot.title)
    }

    private func requestRowDeletion(
        _ row: MeetingLibraryRow,
        mode: MeetingDeletionMode
    ) {
        guard MeetingLibraryModel.requiresConfirmation(mode) else {
            Task { await model.delete(row.id, mode: mode) }
            return
        }
        pendingDeletion = PendingDeletion(documentID: row.id, mode: mode, title: row.title)
    }

    /// 删除和撤销回执由宿主浮层呈现，不改变详情标题的高度。
    private var archiveOutcomeMessage: String? {
        if model.archiveError != nil { return nil }
        if let report = model.lastReport { return MeetingLibraryModel.summary(for: report) }
        if let restored = model.lastRestore {
            return restored ? "已撤销归档，这场会回到搜索和导出里。" : "这份记录不是归档态，撤不了。"
        }
        return nil
    }

    /// 核对视图。拿不到这一场的会话 id 时不开编辑器——只读浏览仍然可用。
    @ViewBuilder
    private func reviewSheet(_ target: MeetingReviewSnapshot) -> some View {
        if let version = reviewVersion {
            MinutesReviewView(
                coordinator: coordinator,
                sessionID: version.sessionID,
                version: version
            )
            .speechRailInspectorColumn()
        } else {
            ContentUnavailableView(
                "这一场没有可核对的纪要",
                systemImage: "doc.text",
                description: Text("可以先在会议助手页整理出纪要，再回来核对。")
            )
            .speechRailInspectorColumn()
        }
    }

    private func beginReview(_ snapshot: MeetingReviewSnapshot) async {
        guard let sessionID = model.selectedSessionID else { return }
        guard let version = try? await coordinator.currentMinutesVersion(sessionID: sessionID) else {
            // 这一版没有纪要就不开编辑器——只读浏览仍然可用。
            return
        }
        reviewVersion = version
        reviewTarget = snapshot
    }

    @ViewBuilder
    private func minutesSection(_ snapshot: MeetingReviewSnapshot) -> some View {
        if let body = snapshot.minutesBody, !body.isEmpty {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                Text(body)
                    .font(.body)
                    .textSelection(.enabled)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Image(systemName: "doc.text")
                        .font(.title3)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                        Text("这场会议还没有整理出纪要")
                            .font(.headline)
                        Text("录音原始转录已完整留存。你可以直接查看转录，或删除这场记录。")
                            .font(.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    }
                }
                HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    Button("查看转录内容") {
                        model.detailTab = .transcript
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("删除空会议", role: .destructive) {
                        if let docID = model.selectedDocumentID {
                            requestDeletion(docID, mode: .deleteEverything, snapshot)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, SpeechRailDesignTokens.Spacing.micro)
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
            .background(SpeechRailDesignTokens.Color.recessedField, in: SpeechRailDesignTokens.Corner.controlShape)
        }
        if !snapshot.items.isEmpty {
            Divider()
                .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
            Text("结论与待办")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ForEach(snapshot.items) { item in
                HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
                    Circle()
                        .fill(
                            item.status.needsReview
                                ? SpeechRailDesignTokens.Color.attention
                                : SpeechRailDesignTokens.Color.inkTertiary
                        )
                        .frame(
                            width: SpeechRailDesignTokens.Icon.liveIndicatorDotSize,
                            height: SpeechRailDesignTokens.Icon.liveIndicatorDotSize
                        )
                        .padding(.top, SpeechRailDesignTokens.Spacing.compact)

                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tiny) {
                        Text(item.text)
                            .font(.body)
                            .textSelection(.enabled)
                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Text(item.kind)
                                .font(.caption2)
                                .padding(.horizontal, SpeechRailDesignTokens.Spacing.micro)
                                .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)
                                .background(SpeechRailDesignTokens.Color.recessedField, in: SpeechRailDesignTokens.Corner.compactShape)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            if item.status.needsReview {
                                Text("待核对")
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.micro)
                                    .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)
                                    .background(SpeechRailDesignTokens.Surface.attentionTint, in: SpeechRailDesignTokens.Corner.compactShape)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                            }
                            if item.status.isDisputed {
                                Text("有分歧")
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.micro)
                                    .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)
                                    .background(SpeechRailDesignTokens.Surface.criticalTint, in: SpeechRailDesignTokens.Corner.compactShape)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.critical)
                            }
                            if !item.status.isCurrent {
                                Text("历史版本")
                                    .font(.caption2)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            }
                        }
                    }
                }
                .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func transcriptSection(_ snapshot: MeetingReviewSnapshot) -> some View {
        if snapshot.transcriptLines.isEmpty {
            Text("这场会没有留存转录。")
                .font(.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
        } else {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                HStack {
                    Text("录音完整转录（共 \(snapshot.transcriptLines.count) 句）")
                        .font(.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    Spacer()
                    Button {
                        let fullTranscript = snapshot.transcriptLines.joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(fullTranscript, forType: .string)
                    } label: {
                        Label("复制全文", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                }
                .padding(.bottom, SpeechRailDesignTokens.Spacing.tight)

                ForEach(Array(snapshot.transcriptLines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .firstTextBaseline, spacing: SpeechRailDesignTokens.Spacing.sm) {
                        Text("\(index + 1)")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                            .frame(width: SpeechRailDesignTokens.Layout.transcriptLineNumberWidth, alignment: .trailing)

                        Text(line)
                            .font(.body)
                            .textSelection(.enabled)
                            .lineSpacing(SpeechRailDesignTokens.Spacing.micro)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)
                }
            }
        }
    }
}

/// 一行会议。**先说是什么、什么状态、有什么要处理**，再说时间。
struct MeetingLibraryRowView: View {
    let row: MeetingLibraryRow

    var body: some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
            ZStack {
                SpeechRailDesignTokens.Corner.controlShape
                    .fill(iconBackgroundColor)
                    .frame(
                        width: SpeechRailDesignTokens.Layout.badgeMediumSize,
                        height: SpeechRailDesignTokens.Layout.badgeMediumSize
                    )
                Image(systemName: iconSystemName)
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .foregroundStyle(iconForegroundColor)
            }
            .padding(.top, SpeechRailDesignTokens.Spacing.tight)

            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tiny) {
                Text(row.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(1)

                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    if let date = row.occurredAt {
                        Text(date.speechRailFormatted(.date))
                            .font(.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    }
                    if let project = row.projectName {
                        Text(project)
                            .font(.caption2)
                            .padding(.horizontal, SpeechRailDesignTokens.Spacing.micro)
                            .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)
                            .background(SpeechRailDesignTokens.Color.recessedField, in: SpeechRailDesignTokens.Corner.compactShape)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    }
                    if row.needsReviewCount > 0 {
                        Text("\(row.needsReviewCount) 条待核对")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, SpeechRailDesignTokens.Spacing.micro)
                            .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)
                            .background(SpeechRailDesignTokens.Surface.attentionTint, in: SpeechRailDesignTokens.Corner.compactShape)
                            .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                    }
                    if !row.hasMinutes {
                        Text("未整理")
                            .font(.caption2)
                            .padding(.horizontal, SpeechRailDesignTokens.Spacing.micro)
                            .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)
                            .background(SpeechRailDesignTokens.Color.recessedField, in: SpeechRailDesignTokens.Corner.compactShape)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    }
                    ForEach(row.tags, id: \.self) { tag in
                        Text("#\(tag)").font(.caption).foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    }
                }

                if let excerpt = row.matchExcerpt {
                    Text(excerpt)
                        .font(.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .lineLimit(2)
                        .textSelection(.disabled)
                        .padding(.horizontal, SpeechRailDesignTokens.Spacing.compact)
                        .padding(.vertical, SpeechRailDesignTokens.Spacing.tiny)
                        .background(SpeechRailDesignTokens.Color.recessedField, in: SpeechRailDesignTokens.Corner.compactShape)
                }
            }
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var iconSystemName: String {
        if row.hasMinutes {
            return row.needsReviewCount > 0 ? "doc.text.fill" : "doc.text"
        }
        return "waveform"
    }

    private var iconBackgroundColor: Color {
        if row.needsReviewCount > 0 {
            return SpeechRailDesignTokens.Surface.attentionTint
        } else if row.hasMinutes {
            return SpeechRailDesignTokens.Surface.selectedFill
        }
        return SpeechRailDesignTokens.Color.recessedField
    }

    private var iconForegroundColor: Color {
        if row.needsReviewCount > 0 {
            return SpeechRailDesignTokens.Color.attention
        } else if row.hasMinutes {
            return SpeechRailDesignTokens.Color.rail
        }
        return SpeechRailDesignTokens.Color.inkSecondary
    }

    private var accessibilityDescription: String {
        var parts = [row.title]
        if let date = row.occurredAt { parts.append(date.speechRailFormatted(.date)) }
        if row.needsReviewCount > 0 { parts.append("\(row.needsReviewCount) 条待核对") }
        if !row.hasMinutes { parts.append("未整理") }
        if let excerpt = row.matchExcerpt { parts.append("命中内容：\(excerpt)") }
        return parts.joined(separator: "，")
    }
}

/// 负责人与期限的编辑面板。单独抽出来是为了 `openItemEditSheet` 不用背一整套
/// `@State` 初始化——SwiftUI 里带初始值的输入框放在子视图里才写得清楚。
private struct OpenItemEditSheet: View {
    let text: String
    let initialOwner: String
    let initialDue: String
    let onSave: (String?, String?) -> Void
    let onCancel: () -> Void

    @State private var owner: String = ""
    @State private var due: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
                Section("负责人") {
                    // 留空表示"还不知道"，不是从正文里猜一个出来。
                    TextField("还没定负责人", text: $owner)
                }
                Section("期限") {
                    TextField("还没定期限，可以写「五月前」", text: $due)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("负责人与期限")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onSave(owner, due) }
                }
            }
        }
        .frame(
            minWidth: SpeechRailDesignTokens.Layout.Sheet.compactWidth,
            minHeight: SpeechRailDesignTokens.Layout.Sheet.compactMinimumHeight
        )
        .onAppear {
            owner = initialOwner
            due = initialDue
        }
    }
}
