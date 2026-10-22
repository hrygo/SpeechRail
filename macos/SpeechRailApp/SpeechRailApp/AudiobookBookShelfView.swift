import SwiftUI

/// T13：有声书工坊书架视图（筛选搜索、三态独立进度呈现、每本书严格唯一主动作、移入可恢复废纸篓）。
public struct AudiobookBookShelfView: View {
    @Environment(AppModel.self) private var appModel
    @State private var openingBookIDs: Set<UUID> = []
    @State private var isDropTargeted = false
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
                        message: "导入本地 TXT 或 EPUB 书稿后，先完成全书人物分析与配声确认，再逐章制作高保真多角色有声书。也可以把书稿直接拖进书架；原文与音频均保存在本机独立作品库中。"
                    ) {
                        Button("导入电子书…", action: onImportTXT)
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
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { Self.isSupportedBookFile($0) }) else { return false }
            Task { await workflow.prepareImport(fileURL: url) }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.container, style: .continuous)
                    .fill(SpeechRailDesignTokens.Color.rail.opacity(0.10))
                    .overlay {
                        VStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Image(systemName: "arrow.down.doc")
                                .font(SpeechRailDesignTokens.Typography.sectionTitle)
                            Text("松开以导入书稿")
                                .font(SpeechRailDesignTokens.Typography.sectionTitle)
                            Text("支持 TXT 与无 DRM 的 EPUB")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        }
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    }
                    .allowsHitTesting(false)
            }
        }
    }

    private static func isSupportedBookFile(_ url: URL) -> Bool {
        ["txt", "epub"].contains(url.pathExtension.lowercased())
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
            .fixedSize()
            .labelsHidden()
            .accessibilityLabel("书架书籍筛选")

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
        let isOpening = openingBookIDs.contains(summary.id)
        let isBlockedByOtherProduction = workflow.isProductionBlocked(for: summary.id)
            && (primaryAction == .makeConfirmedChapters || primaryAction == .resumeProduction)

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
                                await withPendingBook(summary.id) {
                                    await performPrimaryAction(primaryAction, for: summary)
                                }
                            }
                        } label: {
                            Label(
                                isOpening ? "正在打开…" : workflow.primaryActionTitle(primaryAction, for: summary.id),
                                systemImage: primaryAction.systemImage
                            )
                        }
                        .speechRailButton(.primary)
                        .disabled(
                            isOpening
                                || isBlockedByOtherProduction
                                || (primaryAction == .pauseProduction
                                    && workflow.isPausingProduction
                                    && workflow.productionBookID == summary.id)
                        )
                        .accessibilityIdentifier("audiobook-card-primary-\(summary.id.uuidString)")

                        Button("打开工作台") {
                            Task {
                                await withPendingBook(summary.id) {
                                    await workflow.openBook(summary.id)
                                }
                            }
                        }
                        .speechRailButton(.secondary)
                        .disabled(isOpening)

                        Menu {
                            Button("打开工作台") {
                                Task {
                                    await withPendingBook(summary.id) {
                                        await workflow.openBook(summary.id)
                                    }
                                }
                            }
                            .disabled(isOpening)
                            if summary.completedChapterCount > 0 {
                                Button("开始听书") {
                                    Task {
                                        await withPendingBook(summary.id) {
                                            await workflow.openBook(summary.id)
                                            guard workflow.selectedBook?.id == summary.id else { return }
                                            await workflow.startListening()
                                        }
                                    }
                                }
                                .disabled(isOpening)
                                Button("导出有声书…") {
                                    Task {
                                        await withPendingBook(summary.id) {
                                            await workflow.openBook(summary.id)
                                            guard workflow.selectedBook?.id == summary.id else { return }
                                            workflow.isShowingExportSheet = true
                                        }
                                    }
                                }
                                .disabled(isOpening)
                            }
                            Divider()
                            Button("移入废纸篓", role: .destructive) {
                                Task { await workflow.trashBook(summary.id) }
                            }
                            .disabled(isOpening)
                            .help("移入废纸篓后仍可随时恢复，不影响原始 TXT 与已导出文件")
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(SpeechRailDesignTokens.Typography.body)
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 28)
                        .help("更多操作")
                        .accessibilityLabel("更多书籍操作")
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
                        Text(AudiobookDisplayFormat.bookmarkSummary(
                            offsetSeconds: bookmark.fragmentOffsetSeconds,
                            rate: bookmark.playbackRate
                        ))
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
        // 分析进行中优先用 live 投影（跑途中百分比也会跳），否则回退到 DB 快照口径
        if workflow.isAnalyzing,
           workflow.selectedBook?.id == summary.id,
           let progress = workflow.analysisProgress,
           progress.totalWindows > 0
        {
            StatusPill(tone: .attention, label: "分析中 \(SpeechRailDisplayFormat.progress(progress.fraction, isComplete: false))")
        } else if summary.book.analysisState == .notStarted {
            StatusPill(tone: .neutral, label: "分析：未开始")
        } else if summary.book.analysisState == .running {
            StatusPill(tone: .attention, label: "分析中 \(summary.completedWindowCount)/\(max(1, summary.totalWindowCount))")
        } else if summary.book.analysisState == .paused {
            StatusPill(tone: .attention, label: "分析：已暂停")
        } else if summary.book.analysisState == .failed {
            StatusPill(tone: .critical, label: "分析：需重试")
                .help(summary.book.analysisFailure?.message ?? "分析未完成，已完成窗口会保留；请重试。")
        } else {
            StatusPill(tone: .healthy, label: "全书分析已完成")
        }
    }

    @ViewBuilder
    private func productionStatePill(_ summary: AudiobookBookSummary) -> some View {
        if workflow.isProductionBusy, workflow.productionBookID == summary.id,
           let progress = workflow.productionProgress
        {
            StatusPill(tone: .attention, label: workflow.isPausingProduction
                       ? "正在暂停制作"
                       : (progress.totalFragments > 0 ? "制作中 \(SpeechRailDisplayFormat.progress(progress.fraction, isComplete: false)) · \(progress.savedFragmentsText)" : progress.statusTitle))
        } else {
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
            StatusPill(tone: .critical, label: "制作：需重试")
        }
        }
    }

    @ViewBuilder
    private func listenableStatePill(_ summary: AudiobookBookSummary) -> some View {
        switch summary.book.listenableState {
        case .noneAvailable:
            StatusPill(tone: .neutral, label: "收听：暂无成品")
        case .previousRevisionAvailable:
            StatusPill(tone: .attention, label: "可听：旧版音频")
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
        guard workflow.selectedBook?.id == summary.id else { return }
        switch action {
        case .analyzeWholeBook, .resumeAnalysis:
            workflow.beginAnalysis(summary.id)
        case .pauseAnalysis:
            await workflow.pauseAnalysis()
        case .confirmSpeakers, .confirmCastAndVoices:
            workflow.workbenchTab = .preparation
        case .makeConfirmedChapters:
            workflow.workbenchTab = .production
            await workflow.prepareProduction(intent: .missingOnly)
        case .resumeProduction:
            workflow.workbenchTab = .production
            await workflow.prepareResumeProduction()
        case .pauseProduction:
            await workflow.pauseProduction()
        case .reviewCandidates:
            workflow.reviewProductionCandidates()
        case .continueListening:
            await workflow.startListening()
        }
    }

    private func withPendingBook(_ bookID: UUID, operation: () async -> Void) async {
        guard !openingBookIDs.contains(bookID) else { return }
        openingBookIDs.insert(bookID)
        defer { openingBookIDs.remove(bookID) }
        await operation()
    }
}
