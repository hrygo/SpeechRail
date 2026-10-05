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
        .task {
            if model.rows.isEmpty {
                await model.loadPage(offset: restoredOffset)
            }
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
        }
        .padding(.horizontal, SpeechRailDesignTokens.Layout.contentPadding)
        .padding(.top, SpeechRailDesignTokens.Spacing.md)
        .padding(.bottom, SpeechRailDesignTokens.Spacing.sm)
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
            TextField("搜索会议标题或项目", text: $searchText)
                .textFieldStyle(.plain)
                .onSubmit { Task { await model.search(searchText) } }
                .accessibilityLabel("搜索会议标题或项目")
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        return parts.joined(separator: "，")
    }
}
