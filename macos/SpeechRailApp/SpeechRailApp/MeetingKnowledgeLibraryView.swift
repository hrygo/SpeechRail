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
    @State private var model: MeetingLibraryModel
    @State private var searchText = ""
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
    /// 归档包导入前的预检结果。**没看过它就不许导入**（MC-71）。
    @State private var archivePreview: ArchiveImportPreview?
    /// 导入完成后的实数。`nil` = 还没导。
    @State private var archiveImportResult: ArchiveImportReport?
    /// 导出归档包成功时的一句话。
    @State private var archiveExportNotice: String?

    /// 一次导入预检。带着包路径，导入时要用。
    private struct ArchiveImportPreview: Identifiable {
        let id = UUID()
        var packageURL: URL
        var preview: KnowledgeArchivePreview
    }

    /// 一次导入的结果。
    private struct ArchiveImportReport: Identifiable {
        let id = UUID()
        var result: KnowledgeArchiveImportResult
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
        } detail: {
            detailColumn
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
        .alert("导不了这场会议", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("好") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .alert("归档包已导出", isPresented: Binding(
            get: { archiveExportNotice != nil },
            set: { if !$0 { archiveExportNotice = nil } }
        )) {
            Button("好") { archiveExportNotice = nil }
        } message: {
            Text(archiveExportNotice ?? "")
        }
        .sheet(item: $archivePreview) { pending in
            archivePreviewSheet(pending)
        }
        .sheet(item: $archiveImportResult) { report in
            archiveImportSheet(report)
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
        .alert("项目或标签没改成", isPresented: Binding(
            get: { model.projectError != nil },
            set: { if !$0 { model.clearProjectError() } }
        )) {
            Button("好", role: .cancel) { model.clearProjectError() }
        } message: {
            Text(model.projectError ?? "")
        }
        .sheet(isPresented: $manageProjectsPresented) { manageProjectsSheet }
        .sheet(isPresented: $openItemsPresented) { openItemsSheet }
        .sheet(item: $openItemEditTarget) { target in
            openItemEditSheet(target)
        }
        .sheet(isPresented: $tagsSheetPresented) { tagsSheet }
        .task {
            if model.rows.isEmpty {
                await model.loadPage(offset: restoredOffset)
            }
            await model.loadProjects()
            // 入口上的数字要真的有内容：面板可能一次都没打开过，
            // 只在点开时才查的话，标题永远是"未完成事项"没有数字。
            await model.loadOpenItems(offset: 0)
        }
    }

    private var deletionDialogTitle: String {
        "确定要\(pendingDeletion?.mode.title ?? "删除")「\(pendingDeletion?.title ?? "")」吗？"
    }

    /// 确认面板要说明**这一步之后还剩什么**，不只说"不可撤销"。
    ///
    /// 只写"不可撤销"的话，用户没法判断值不值；说清剩什么，他才判断得了。
    private func deletionDialogMessage(_ pending: PendingDeletion) -> String {
        switch pending.mode {
        case .archive:
            return "归档之后它不再出现在搜索、导出和问答里，但数据一行不少，随时可以撤销。"
        case .removeTranscript:
            return "完整转录会被移除，纪要和结论留着。引用结论的原句从此读不到了，"
                + "那些结论会被标成需要你再看一眼。这一步不能撤销。"
        case .deleteEverything:
            return "转录、纪要、结论、引用和来源快照会一起删掉，删完就没了。这一步不能撤销。"
        }
    }

    // MARK: - 列表

    private var listColumn: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: SpeechRailDesignTokens.Layout.sidebarIdealWidth)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            Text("会议知识库")
                .font(.title)
                .accessibilityAddTraits(.isHeader)
            // 计数与列表同源，所以这里可以直接说"共 N 场"。
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
            searchField
            projectMenu
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                archivedToggle
                Spacer()
                Button {
                    openItemsPresented = true
                    Task { await model.loadOpenItems(offset: 0) }
                } label: {
                    // 数字是**全量总数**，不是这一页有几个。用户问"还有多少"的时候，
                    // 答案不能随翻页变化。
                    Text(model.openItemCounts.total > 0
                        ? "未完成事项 \(model.openItemCounts.total)"
                        : "未完成事项")
                }
                .buttonStyle(.link)
                .controlSize(.small)
                .help("列出所有还没做完的事项")
                Button("导入归档包…", action: chooseArchiveToImport)
                    .buttonStyle(.link)
                    .controlSize(.small)
                    .help("把别人分享的会议归档包导入这个知识库")
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

                if model.openItemWriteError != nil {
                    // 写失败必须看得见：静默失败会让用户以为标上了，其实库里没动。
                    Text(model.openItemWriteHint)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, SpeechRailDesignTokens.Layout.contentPadding)
                        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
                }

                if let error = model.openItemsError {
                    VStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                        Text(error).foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
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
                }
            }
        }
        .frame(minWidth: 460, minHeight: 380)
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
                        item.execution?.status == .blocked ? Color.orange : Color.secondary
                    )
                if let owner = item.execution?.ownerText {
                    Text("· \(owner)").font(.caption).foregroundStyle(.secondary)
                }
                if let due = item.execution?.dueText ?? item.execution?.dueDate.map(Self.dateText) {
                    Text("· \(due)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let occurredAt = item.occurredAt {
                    Text(occurredAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                openItemMenu(item)
            }
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .accessibilityElement(children: .contain)
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
        date.formatted(date: .abbreviated, time: .omitted)
    }

    /// 项目筛选（MA-13）。**筛选与列表、计数同源**（MC-51/MC-53），
    /// 所以这里切一下，标题旁的"共 N 场"立刻跟着变。
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
                .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
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
        if let error = model.listError {
            // 故障只说当前问题和一个有效出口，不堆一串可能的原因。
            VStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                Text("读不了会议列表").font(.headline)
                Text(error).font(.callout).foregroundStyle(.secondary)
                Button("重试") { Task { await model.reload() } }
            }
            .padding(SpeechRailDesignTokens.Layout.contentPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if model.rows.isEmpty && !model.isLoadingList {
            ContentUnavailableView(
                searchText.isEmpty ? "还没有会议记录" : "没有匹配的会议",
                systemImage: "books.vertical",
                description: Text(model.emptyStateHint)
            )
        } else {
            List(selection: Binding(
                get: { model.selectedDocumentID },
                set: { id in Task { await model.select(id) } }
            )) {
                Section {
                    ForEach(model.rows) { row in
                        MeetingLibraryRowView(row: row)
                            .tag(row.id)
                            .listRowInsets(EdgeInsets(
                                top: SpeechRailDesignTokens.Spacing.xs,
                                leading: SpeechRailDesignTokens.Spacing.md,
                                bottom: SpeechRailDesignTokens.Spacing.xs,
                                trailing: SpeechRailDesignTokens.Spacing.md
                            ))
                    }
                    if model.hasMore {
                        Button("再显示 \(min(model.limit, max(0, model.counts.total - model.rows.count))) 场") {
                            Task { await model.loadMore() }
                        }
                        .buttonStyle(.link)
                        .accessibilityHint("列表按时间倒序排列，翻页不会重复或漏掉会议")
                    }
                } header: {
                    Text("按会议时间倒序")
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: - 详情

    @ViewBuilder
    private var detailColumn: some View {
        if let error = model.detailError {
            VStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                Text("读不了这场会议").font(.headline)
                Text(error).font(.callout).foregroundStyle(.secondary)
                Button("重试") { Task { await model.open(documentID: model.selectedDocumentID ?? "") } }
            }
            .padding(SpeechRailDesignTokens.Layout.contentPadding)
        } else if let snapshot = model.snapshot {
            detail(snapshot)
        } else if model.isLoadingDetail {
            ProgressView().controlSize(.small)
        } else {
            ContentUnavailableView(
                "选一场会议看纪要",
                systemImage: "doc.text.magnifyingglass",
                description: Text("左边选一场，这里会显示它的纪要和转录。服务没启动也能看，内容都在本机。")
            )
            .speechRailInspectorColumn()
        }
    }

    private func detail(_ snapshot: MeetingReviewSnapshot) -> some View {
        VStack(spacing: 0) {
            // 纪要/转录是**真正切换**：两个页签的内容不同时铺在页面上。
            Picker("内容", selection: $model.detailTab) {
                ForEach(MeetingLibraryModel.DetailTab.allCases, id: \.self) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, SpeechRailDesignTokens.Layout.contentPadding)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.gutter) {
                    identityBand(snapshot)
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

    private func identityBand(_ snapshot: MeetingReviewSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SpeechRailDesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text(snapshot.title)
                    .font(.title)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    if let date = snapshot.occurredAt {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    // 状态不是一个词就完事：已归档的会议仍然读得到，只是不能检索与导出。
                    if snapshot.status != .active {
                        Text(snapshot.status.title)
                            .font(.caption)
                            .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                            .padding(.vertical, 2)
                            .background(SpeechRailDesignTokens.Color.recessedField, in: .rect(cornerRadius: 4))
                    }
                }
                archiveOutcome
            }
            Spacer(minLength: 0)
            moreMenu(snapshot)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    + "导出于 \(manifest.createdAt.formatted(date: .abbreviated, time: .shortened))"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            archiveCount("要新增", preview.newObjectCount)
            if identical > 0 {
                archiveCount("与本机完全相同，跳过", identical)
            }

            if !preview.realConflicts.isEmpty {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Text("有 \(preview.realConflicts.count) 处同 ID 但内容不同")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Text("这些是你已经有的内容。这里不提供覆盖入口——先决定要不要保留本机这一份。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(preview.realConflicts.prefix(5), id: \.self) { conflict in
                        Text("· \(conflict.kind.rawValue) \(conflict.id)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
        .frame(minWidth: 380, alignment: .leading)
    }

    private func performImport(at packageURL: URL) async {
        do {
            let result = try await model.importArchive(at: packageURL)
            archiveImportResult = ArchiveImportReport(result: result)
        } catch {
            exportError = error.localizedDescription
        }
    }

    /// 导入结果只报事实：**新增了什么、跳过了什么**，不写一句"导入成功"了事。
    private func archiveImportSheet(_ report: ArchiveImportReport) -> some View {
        let result = report.result
        return VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Text("已导入这个归档包")
                .font(.headline)
            archiveCount("会议文档", result.inserted.documents)
            archiveCount("纪要版本", result.inserted.minutes)
            archiveCount("结论与待办", result.inserted.items)
            archiveCount("引用锚点", result.inserted.anchors)
            if result.skippedIdentical > 0 {
                archiveCount("与本机相同而跳过", result.skippedIdentical)
            }
            Text("在左边选它就能读。")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("好") { archiveImportResult = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(SpeechRailDesignTokens.Layout.contentPadding)
        .frame(minWidth: 320, alignment: .leading)
    }

    private func archiveCount(_ label: String, _ value: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.callout).foregroundStyle(.secondary)
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
                if !SessionExportPanel.write(payload, as: format) { return }
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
                    .foregroundStyle(.secondary)
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
            }
        }
        .padding(SpeechRailDesignTokens.Layout.contentPadding)
        .frame(minWidth: 320, alignment: .leading)
    }

    /// 标签编辑。**标签是用户写的，导入与生成都不猜**（MA-13），
    /// 所以这里不給建议、不自动补全——用户想到什么就写什么。
    private var tagsSheet: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Text("给这场会议加标签")
                .font(.headline)
            Text("用顿号或逗号分隔。标签是你自己写的，导入和生成都不会替你猜。")
                .font(.callout)
                .foregroundStyle(.secondary)
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
        .frame(minWidth: 360, alignment: .leading)
    }

    /// 要不要确认，判据是**可逆性**：归档能撤，不问；移除转录与完整删除都是单向门，
    /// 问一句。移除转录之后这一场在列表和详情里都还在，容易让人以为"没什么大不了"——
    /// 但原句是被永久删掉的，所以更该问。
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

    /// 删除/撤销之后的那句回执。**说具体数目与还剩什么**，不写「操作成功」。
    @ViewBuilder
    private var archiveOutcome: some View {
        if let error = model.archiveError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let report = model.lastReport {
            Label(MeetingLibraryModel.summary(for: report), systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let restored = model.lastRestore {
            Label(
                restored ? "已撤销归档，这场会回到搜索和导出里。" : "这份记录不是归档态，撤不了。",
                systemImage: restored ? "checkmark.circle" : "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
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
            Text(body)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("核对与修改") { Task { await beginReview(snapshot) } }
                .padding(.top, SpeechRailDesignTokens.Spacing.sm)
            Text("这场会还没整理出纪要。下面是转录里有的内容。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if !snapshot.items.isEmpty {
            Divider()
            Text("结论与待办")
                .font(.headline)
            ForEach(snapshot.items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text).font(.body)
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Text(item.kind).font(.caption).foregroundStyle(.secondary)
                        // 三个轴分别说，不合成一个词。
                        if item.status.needsReview {
                            Text("待核对").font(.caption).foregroundStyle(.orange)
                        }
                        if item.status.isDisputed {
                            Text("有分歧").font(.caption).foregroundStyle(.orange)
                        }
                        if !item.status.isCurrent {
                            Text("历史版本").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func transcriptSection(_ snapshot: MeetingReviewSnapshot) -> some View {
        if snapshot.transcriptLines.isEmpty {
            Text("这场会没有留存转录。")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ForEach(Array(snapshot.transcriptLines.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("第 \(index + 1) 句：\(line)")
            }
        }
    }
}

/// 一行会议。**先说是什么、什么状态、有什么要处理**，再说时间。
struct MeetingLibraryRowView: View {
    let row: MeetingLibraryRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.title)
                .font(.body)
                .lineLimit(1)
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                if let date = row.occurredAt {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let project = row.projectName {
                    Text(project).font(.caption).foregroundStyle(.secondary)
                }
                if row.needsReviewCount > 0 {
                    Text("\(row.needsReviewCount) 条待核对")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if !row.hasMinutes {
                    // 没整理过的会议照样列出来。不列的话，
                    // 用户会以为这场会不存在。
                    Text("未整理").font(.caption).foregroundStyle(.secondary)
                }
                // 标签要看得见：只写不读的标签等于没加。
                ForEach(row.tags, id: \.self) { tag in
                    Text("#\(tag)").font(.caption).foregroundStyle(.secondary)
                }
            }
            // 为什么命中，当场就能看见。只给会议名的话，用户还得点进去
            // 自己找那句话——验收 4 要的是"会议**与证据**"。
            if let excerpt = row.matchExcerpt {
                Text(excerpt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.disabled)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts = [row.title]
        if let date = row.occurredAt { parts.append(date.formatted(date: .long, time: .omitted)) }
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
                        .foregroundStyle(.secondary)
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
        .frame(minWidth: 420, minHeight: 320)
        .onAppear {
            owner = initialOwner
            due = initialDue
        }
    }
}
