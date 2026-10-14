import SwiftUI

/// T13：有声书工坊书架视图（筛选搜索、三态独立进度呈现、每本书严格唯一主动作、移入可恢复废纸篓）。
public struct AudiobookBookShelfView: View {
    @Environment(AppModel.self) private var appModel
    let onImportTXT: () -> Void

    public init(onImportTXT: @escaping () -> Void) {
        self.onImportTXT = onImportTXT
    }

    private var workflow: AudiobookWorkflowModel {
        appModel.audiobookWorkflow
    }

    public var body: some View {
        @Bindable var bindableWorkflow = workflow

        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            filterAndSearchHeader(bindableWorkflow: $bindableWorkflow)

            if workflow.filteredShelfBooks.isEmpty {
                CardSurface {
                    SessionEmptyState(
                        systemImage: "books.vertical",
                        title: workflow.shelfBooks.isEmpty ? "还没有导入有声书项目" : "没有符合筛选条件的书籍",
                        message: "导入本地 TXT 电子书后，先完成全书人物分析与配声确认，再逐章制作高保真多角色有声书。原文与音频均保存在本机独立作品库中。"
                    ) {
                        Button("导入 TXT 电子书…", action: onImportTXT)
                            .speechRailButton(.primary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                        ForEach(workflow.filteredShelfBooks) { summary in
                            bookCard(summary)
                        }
                    }
                    .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func filterAndSearchHeader(
        bindableWorkflow: Bindable<AudiobookWorkflowModel>
    ) -> some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            Picker("书架筛选", selection: bindableWorkflow.shelfFilter) {
                ForEach(AudiobookWorkflowModel.ShelfFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360, alignment: .leading)
            .labelsHidden()

            Spacer()

            TextField("搜索书名或作者…", text: bindableWorkflow.searchQuery)
                .speechRailSingleLineInput(.compact)
                .frame(width: 240)
                .accessibilityIdentifier("audiobook-shelf-search")
        }
    }

    @ViewBuilder
    private func bookCard(_ summary: AudiobookBookSummary) -> some View {
        let primaryAction = workflow.nextPrimaryAction(for: summary)

        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.md) {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Text(summary.book.title)
                                .font(SpeechRailDesignTokens.Typography.sectionTitle)
                                .foregroundStyle(SpeechRailDesignTokens.Color.ink)

                            if let author = summary.book.author, !author.isEmpty {
                                Text("· \(author)")
                                    .font(SpeechRailDesignTokens.Typography.callout)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            }
                        }

                        Text("共 \(summary.totalChapterCount) 章 · \(summary.characterCount) 个角色 · 已完成 \(summary.completedChapterCount)/\(summary.totalChapterCount) 章制作 · 编码 \(summary.book.originalEncoding.uppercased())")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    }

                    Spacer()

                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Button {
                            Task {
                                await performPrimaryAction(primaryAction, for: summary)
                            }
                        } label: {
                            Label(primaryAction.title, systemImage: primaryAction.systemImage)
                        }
                        .speechRailButton(.primary)
                        .accessibilityIdentifier("audiobook-card-primary-\(summary.id.uuidString)")

                        Button("打开工作台") {
                            Task { await workflow.openBook(summary.id) }
                        }
                        .speechRailButton(.secondary)

                        Menu {
                            Button("进入工作台") {
                                Task { await workflow.openBook(summary.id) }
                            }
                            if summary.completedChapterCount > 0 {
                                Button("进入听书模式") {
                                    Task {
                                        await workflow.openBook(summary.id)
                                        await workflow.startListening()
                                    }
                                }
                                Button("导出有声书…") {
                                    Task {
                                        await workflow.openBook(summary.id)
                                        workflow.isShowingExportSheet = true
                                    }
                                }
                            }
                            Divider()
                            Button("移入有声书废纸篓", role: .destructive) {
                                Task { await workflow.trashBook(summary.id) }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(SpeechRailDesignTokens.Typography.body)
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 28)
                    }
                }

                // 严格分离三项状态标签（分析状态 / 制作状态 / 可收听状态，不共用笼统 completed）
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    analysisStatePill(summary)
                    productionStatePill(summary)
                    listenableStatePill(summary)

                    if summary.unknownSpeakerCount > 0 {
                        StatusPill(
                            tone: .attention,
                            label: "待确认说话人 \(summary.unknownSpeakerCount) 处"
                        )
                    }

                    Spacer()

                    if let bookmark = summary.bookmark {
                        Text("上次听到片段偏置 \(Int(bookmark.fragmentOffsetSeconds))s · \(String(format: "%.2gx", bookmark.playbackRate))")
                            .font(SpeechRailDesignTokens.Typography.technical)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    }
                }
            }
            .padding(SpeechRailDesignTokens.Layout.cardInset)
        }
    }

    @ViewBuilder
    private func analysisStatePill(_ summary: AudiobookBookSummary) -> some View {
        switch summary.book.analysisState {
        case .notStarted:
            StatusPill(tone: .neutral, label: "分析：未开始")
        case .running:
            StatusPill(tone: .attention, label: "分析中 \(summary.completedWindowCount)/\(max(1, summary.totalWindowCount))")
        case .paused:
            StatusPill(tone: .attention, label: "分析：已暂停")
        case .failed:
            StatusPill(tone: .critical, label: "分析：需处理")
        case .allWindowsValidated:
            StatusPill(tone: .healthy, label: "全书分析已完成")
        }
    }

    @ViewBuilder
    private func productionStatePill(_ summary: AudiobookBookSummary) -> some View {
        switch summary.book.productionState {
        case .idle:
            StatusPill(tone: .neutral, label: "制作：待开始")
        case .running:
            StatusPill(tone: .attention, label: "正在制作章节")
        case .pausing:
            StatusPill(tone: .attention, label: "正在暂停")
        case .paused:
            StatusPill(tone: .attention, label: "制作：已暂停")
        case .blockedByConditions:
            StatusPill(tone: .attention, label: "待确认角色或声音")
        case .partialChaptersReady:
            StatusPill(tone: .healthy, label: "已制作 \(summary.completedChapterCount)/\(summary.totalChapterCount) 章")
        case .allConfirmedChaptersProduced:
            StatusPill(tone: .healthy, label: "已确认章节制作完成")
        case .fullBookProduced:
            StatusPill(tone: .healthy, label: "全书制作完成")
        case .failed:
            StatusPill(tone: .critical, label: "制作：需处理")
        }
    }

    @ViewBuilder
    private func listenableStatePill(_ summary: AudiobookBookSummary) -> some View {
        switch summary.book.listenableState {
        case .noneAvailable:
            StatusPill(tone: .neutral, label: "收听：暂无成品")
        case .previousRevisionAvailable:
            StatusPill(tone: .attention, label: "可听：之前的版本")
        case .partialChaptersListenable:
            StatusPill(tone: .healthy, label: "可听：部分章节")
        case .fullBookListenable:
            StatusPill(tone: .healthy, label: "可听：整本就绪")
        }
    }

    private func performPrimaryAction(
        _ action: AudiobookWorkflowModel.PrimaryBookAction,
        for summary: AudiobookBookSummary
    ) async {
        await workflow.openBook(summary.id)
        switch action {
        case .analyzeWholeBook, .resumeAnalysis:
            workflow.beginAnalysis(summary.id)
        case .pauseAnalysis:
            await workflow.pauseAnalysis()
        case .confirmSpeakers, .confirmCastAndVoices:
            workflow.workbenchTab = .preparation
        case .makeConfirmedChapters, .resumeProduction:
            workflow.workbenchTab = .production
            workflow.makeConfirmedChapters()
        case .pauseProduction:
            await workflow.pauseProduction()
        case .continueListening:
            await workflow.startListening()
        }
    }
}
