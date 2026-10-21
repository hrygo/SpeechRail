import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// T13：有声书工坊顶层页面壳层，统一管理书架、三栏工作台、听书模式及导入/导出/废纸篓弹层。
public struct AudiobookWorkshopView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppNavigationState.self) private var navigation

    public init() {}

    private var workflow: AudiobookWorkflowModel {
        appModel.audiobookWorkflow
    }

    public var body: some View {
        @Bindable var bindableWorkflow = workflow

        PageScaffold(
            route: .audiobook,
            layout: .fill(minimumHeight: SpeechRailDesignTokens.Layout.audiobookWorkbenchMinimumHeight),
            content: {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                if workflow.voiceReturnRequiresAction, let voiceMsg = workflow.voiceReturnBannerMessage {
                    StatusBanner(
                        kind: .standard,
                        tone: .attention,
                        title: "音色需要确认",
                        message: voiceMsg,
                        actionTitle: "知道了"
                    ) {
                        workflow.dismissVoiceReturnBanner()
                    }
                }

                if let errorMsg = workflow.errorMessage {
                    StatusBanner(
                        kind: .standard,
                        tone: .critical,
                        title: "操作未完成",
                        message: errorMsg,
                        actionTitle: "知道了"
                    ) {
                        workflow.errorMessage = nil
                    }
                }
                if workflow.bannerRequiresAction, let bannerMsg = workflow.bannerMessage {
                    StatusBanner(
                        kind: .standard,
                        tone: .attention,
                        title: "下一步",
                        message: bannerMsg,
                        actionTitle: "收起"
                    ) {
                        workflow.bannerMessage = nil
                    }
                }

                if workflow.surfaceMode != .shelf, workflow.requiresWorkingTextPreparation {
                    StatusBanner(kind: .standard, tone: .attention,
                        title: workflow.isPreparingWorkingText ? "正在整理正文…" : "准备正文后继续制作",
                        message: "将连接排版折行，后续分析与制作统一使用整理后的正文。原文和已有音频会保留；新正文需要重新分析并确认配声。",
                        actionTitle: workflow.isPreparingWorkingText ? nil : "准备加工文本") {
                        Task { await workflow.prepareSelectedBookWorkingText() }
                    }
                    .disabled(workflow.isPreparingWorkingText || workflow.isAnalyzing || workflow.isProductionBusy || workflow.isPreparingExport)
                }

                switch workflow.surfaceMode {
                case .shelf:
                    AudiobookBookShelfView(
                        onImportTXT: presentOpenTXTPanel
                    )
                case .workspace:
                    AudiobookBookWorkspaceView(
                        onImportTXT: presentOpenTXTPanel
                    )
                case .listening:
                    AudiobookListeningView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .top) {
                VStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    if !workflow.voiceReturnRequiresAction, let message = workflow.voiceReturnBannerMessage {
                        AudiobookTransientFeedback(
                            id: workflow.voiceReturnNoticeID,
                            tone: .healthy,
                            title: "音色已更新",
                            message: message,
                            onDismiss: workflow.dismissVoiceReturnBanner
                        )
                    }
                    if !workflow.bannerRequiresAction, let message = workflow.bannerMessage {
                        AudiobookTransientFeedback(
                            id: workflow.bannerNoticeID,
                            tone: .healthy,
                            title: "状态更新",
                            message: message,
                            onDismiss: { workflow.bannerMessage = nil }
                        )
                    }
                    if workflow.surfaceMode == .listening,
                       let listening = workflow.listeningController,
                       let message = listening.chapterUpdatedBannerMessage {
                        AudiobookTransientFeedback(
                            id: listening.chapterUpdatedNoticeID,
                            tone: .healthy,
                            title: "章节已更新",
                            message: message,
                            onDismiss: listening.dismissChapterUpdatedNotice
                        )
                    }
                    if let message = workflow.trashUndoMessage {
                        AudiobookTransientFeedback(
                            id: workflow.trashUndoNoticeID,
                            tone: .neutral,
                            title: "已移入废纸篓",
                            message: message,
                            actionTitle: "撤销",
                            action: { Task { await workflow.undoLastTrash() } },
                            onDismiss: workflow.dismissTrashUndoMessage
                        )
                    }
                }
            }
            },
            trailing: {
                toolbarActions
            }
        )
        .sheet(isPresented: $bindableWorkflow.isShowingImportSheet) {
            AudiobookImportPreviewSheet(workflow: workflow)
        }
        .sheet(isPresented: $bindableWorkflow.isShowingExportSheet) {
            AudiobookExportSheet(workflow: workflow)
        }
        .sheet(isPresented: $bindableWorkflow.isShowingTrashSheet) {
            AudiobookTrashSheet(workflow: workflow)
        }
        .sheet(isPresented: $bindableWorkflow.isShowingCastMergeSheet) {
            AudiobookCastMergeSplitSheet(workflow: workflow)
        }
        .task {
            await workflow.refreshShelf()
            if appModel.safeVoiceCatalog == nil {
                await appModel.refreshDiscovery()
            }
        }
        .onDisappear {
            Task { await workflow.leaveWorkshop() }
        }
    }

    @ViewBuilder
    private var toolbarActions: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            if workflow.selectedBook != nil && workflow.surfaceMode != .shelf {
                PageActionButton(
                    title: "返回书架",
                    systemImage: "books.vertical",
                    helpText: "返回有声书书架列表"
                ) {
                    Task {
                        await workflow.leaveWorkshop()
                        workflow.surfaceMode = .shelf
                    }
                }

                Picker(
                    "视图模式",
                    selection: Binding(
                        get: { workflow.surfaceMode },
                        set: { newMode in
                            if newMode == .listening {
                                Task { await workflow.startListening() }
                            } else {
                                Task {
                                    await workflow.leaveWorkshop()
                                    workflow.surfaceMode = newMode
                                }
                            }
                        }
                    )
                ) {
                    Text("制作工作台").tag(AudiobookWorkflowModel.SurfaceMode.workspace)
                    Text("听书模式").tag(AudiobookWorkflowModel.SurfaceMode.listening)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .labelsHidden()
                .accessibilityIdentifier("audiobook-surface-mode-picker")
                .accessibilityLabel("有声书视图模式")

                PageActionButton(
                    title: "导出有声书…",
                    systemImage: "square.and.arrow.up",
                    helpText: "导出整本 M4B 或分章节 MP3"
                ) {
                    workflow.isShowingExportSheet = true
                }
                .accessibilityIdentifier("audiobook-export-toolbar-button")
            } else {
                PageActionButton(
                    title: "导入书稿…",
                    systemImage: "doc.badge.plus",
                    helpText: "选择本地 TXT 或 EPUB 书稿，预览编码、章节边界与正文"
                ) {
                    presentOpenTXTPanel()
                }
                .accessibilityIdentifier("audiobook-import-txt-button")

                PageActionButton(
                    title: "废纸篓（\(workflow.trashedBooks.count)）",
                    systemImage: "trash",
                    helpText: "查看或恢复已移入有声书废纸篓的项目"
                ) {
                    workflow.isShowingTrashSheet = true
                }
                .accessibilityIdentifier("audiobook-trash-button")
            }
        }
    }

    private func presentOpenTXTPanel() {
        let panel = NSOpenPanel()
        panel.title = "选择要制作成有声书的 TXT 或 EPUB 文件"
        panel.allowedContentTypes = [
            .plainText,
            UTType(filenameExtension: "txt") ?? .plainText,
            UTType(filenameExtension: "epub") ?? .data
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await workflow.prepareImport(fileURL: url)
            }
        }
    }
}

/// 有声书各页面共用的临时反馈；宿主通过 overlay 放置，不占用正文空间。
struct AudiobookTransientFeedback: View {
    let id: UUID
    let tone: StatusTone
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    let onDismiss: () -> Void

    var body: some View {
        StatusBanner(
            kind: .standard,
            tone: tone,
            title: title,
            message: message,
            actionTitle: actionTitle ?? "收起",
            action: action ?? onDismiss
        )
        .task(id: id) {
            do {
                try await Task.sleep(for: SpeechRailDesignTokens.Notice.transientDisplayDuration)
                try Task.checkCancellation()
            } catch {
                return
            }
            onDismiss()
        }
    }
}

// MARK: - Import Preview Sheet

struct AudiobookImportPreviewSheet: View {
    @Bindable var workflow: AudiobookWorkflowModel
    @State private var selectedEncoding: AudiobookTextEncoding = .utf8
    @State private var editedTitle: String = ""
    @State private var editedAuthor: String = ""
    @State private var selectedChapterID: UUID?
    @State private var showsOriginalLayout = false

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            SectionHeading(
                title: "整理段落与章节",
                detail: "格式探测已完成。先核对整理后的段落和目录，确认后再进入角色分析。原始文件会完整保留，整理在本地完成。"
            )

            if let importError = workflow.importErrorMessage {
                NoticeBar(
                    tone: .critical,
                    message: importError,
                    actionTitle: "知道了"
                ) { workflow.importErrorMessage = nil }
            }

            if let preview = workflow.importPreview {
                if preview.isEPUB {
                    NoticeBar(
                        tone: .info,
                        message: "已按 EPUB 的阅读顺序提取正文并转为纯文本；原始压缩包不会保存。请核对章节与正文后再导入。"
                    )
                }
                if preview.requiresEncodingConfirmation && !preview.isEPUB {
                    NoticeBar(
                        tone: .warning,
                        message: "无法百分百确定文件编码，当前按 \(preview.detectedEncoding.displayName) 预览。若正文出现乱码，请在上方切换编码核对后再导入。"
                    )
                }
                if !preview.tableOfContentsRanges.isEmpty {
                    NoticeBar(
                        tone: .info,
                        message: "已自动识别并跳过 \(preview.tableOfContentsRanges.count) 处目录页；目录不会作为章节朗读或制作，原文仍完整保留。"
                    )
                }
                HStack(spacing: SpeechRailDesignTokens.Spacing.md) {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                        Text("书名")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        TextField("输入书名", text: $editedTitle)
                            .speechRailSingleLineInput()
                    }
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                        Text("作者（选填）")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        TextField("输入作者姓名", text: $editedAuthor)
                            .speechRailSingleLineInput()
                    }
                    if !preview.isEPUB {
                        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                            Text("文件编码")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            Picker("文件编码", selection: $selectedEncoding) {
                                ForEach(preview.candidateEncodings, id: \.self) { enc in
                                    Text(enc.rawValue.uppercased()).tag(enc)
                                }
                            }
                            .onChange(of: selectedEncoding) { _, newValue in
                                guard newValue != preview.detectedEncoding else { return }
                                guard let url = workflow.importFileURL else { return }
                                Task { await workflow.prepareImport(fileURL: url, encoding: newValue) }
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }

                HStack(spacing: SpeechRailDesignTokens.Spacing.md) {
                    StatusPill(tone: .healthy, label: "共 \(preview.chapters.count) 章")
                    StatusPill(tone: .neutral, label: "\(preview.sourceIndex.paragraphs.count) 个段落")
                    StatusPill(tone: .neutral, label: "\(preview.scalarCount) 字符")
                    if !preview.isEPUB {
                        StatusPill(tone: .neutral, label: "编码：\(preview.detectedEncoding.rawValue.uppercased())")
                    }
                }

                Text(preview.sourceIndex.joinedLineBreakCount > 0
                     ? "已连接 \(preview.sourceIndex.joinedLineBreakCount) 处排版折行，保留段落与独立对白。请选择章节核对正文。"
                     : "已整理段落与目录。请选择章节核对正文，章节名称和划分可在工作台继续调整。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

                if let repeated = preview.repeatedContentWarnings.first {
                    NoticeBar(
                        tone: .warning,
                        message: "发现 \(preview.repeatedContentWarnings.count) 组重复正文。内容已完整保留，请核对后确认。",
                        actionTitle: "查看重复位置"
                    ) { selectedChapterID = repeated.chapterIDs.last }
                    Toggle("我已核对，保留重复内容继续导入", isOn: Binding(
                        get: { workflow.importPreview?.hasConfirmedRepeatedContent == true },
                        set: { workflow.importPreview?.hasConfirmedRepeatedContent = $0 }
                    ))
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("audiobook-confirm-repeated-content")
                }

                HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.md) {
                    CardSurface {
                        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Text("章节目录（\(preview.chapters.count) 章）")
                                .font(SpeechRailDesignTokens.Typography.sectionTitle)
                            List(preview.chapters, selection: $selectedChapterID) { chapter in
                                HStack {
                                    Text("#\(chapter.ordinal + 1)")
                                        .font(SpeechRailDesignTokens.Typography.technical)
                                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                    Text(chapter.title)
                                        .font(SpeechRailDesignTokens.Typography.body)
                                        .lineLimit(1)
                                    if preview.repeatedContentWarnings.contains(where: { $0.chapterIDs.contains(chapter.id) }) {
                                        StatusPill(tone: .attention, label: "内容重复")
                                    }
                                    Spacer()
                                }
                                .tag(chapter.id)
                            }
                            .accessibilityLabel("选择章节核对整理结果")
                            .speechRailSelectableList()
                            .frame(height: SpeechRailDesignTokens.Layout.audiobookImportPreviewHeight)
                        }
                        .padding(SpeechRailDesignTokens.Spacing.sm)
                    }
                    .frame(width: SpeechRailDesignTokens.Layout.sidebarIdealWidth)

                    CardSurface {
                        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Text(showsOriginalLayout ? "原始排版（节选）" : "整理后的正文（节选）")
                                .font(SpeechRailDesignTokens.Typography.sectionTitle)
                            Toggle("查看原始排版", isOn: $showsOriginalLayout)
                                .toggleStyle(.checkbox)
                            AudiobookImportTextView(
                                text: (try? preview.textPreview(
                                    for: selectedChapterID,
                                    originalLayout: showsOriginalLayout
                                )) ?? preview.previewText
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: SpeechRailDesignTokens.Layout.audiobookImportPreviewHeight)
                        }
                        .padding(SpeechRailDesignTokens.Spacing.md)
                    }
                }
                .onAppear {
                    editedTitle = preview.title
                    editedAuthor = preview.author ?? ""
                    selectedEncoding = preview.detectedEncoding
                    selectedChapterID = preview.chapters.first?.id
                }
                .onChange(of: preview.id) { _, _ in
                    selectedEncoding = preview.detectedEncoding
                    selectedChapterID = preview.chapters.first?.id
                }
            }

            HStack {
                Button("取消", role: .cancel) {
                    workflow.isShowingImportSheet = false
                    workflow.importPreview = nil
                    workflow.importErrorMessage = nil
                }
                .speechRailButton(.secondary)

                Spacer()

                Button("确认整理并导入") {
                    if var preview = workflow.importPreview {
                        let trimmedTitle = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedAuthor = editedAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedTitle.isEmpty { preview.title = trimmedTitle }
                        preview.author = trimmedAuthor.isEmpty ? nil : trimmedAuthor
                        workflow.importPreview = preview
                    }
                    Task { await workflow.confirmImport() }
                }
                .speechRailButton(.primary)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("audiobook-confirm-import-button")
                .disabled(workflow.importPreview?.canConfirmImport != true)
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.gutter)
        .frame(width: SpeechRailDesignTokens.Layout.Sheet.prominentWidth)
    }
}

// MARK: - Export Sheet

struct AudiobookExportSheet: View {
    @Bindable var workflow: AudiobookWorkflowModel
    @State private var selectedProfile: AudiobookExportProfile = .m4b
    @State private var selectedChapterIDs: Set<UUID> = []
    @State private var isPresentingCoverImporter = false
    @State private var loudnessEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            SectionHeading(
                title: "导出有声书",
                detail: "整本 M4B 包含章节轨与书名元数据；分章节 MP3 允许仅导出已完成的章节并附带遗漏说明清单。"
            )

            if let exportError = workflow.exportErrorMessage {
                NoticeBar(
                    tone: .critical,
                    message: exportError,
                    actionTitle: "知道了"
                ) { workflow.clearExportError() }
            }

            if !workflow.exportCapabilities.available {
                StatusBanner(
                    kind: .standard,
                    tone: .attention,
                    title: "导出工具不可用",
                    message: "当前本机运行环境尚未检测到可用的 FFmpeg 音频编码工具；您仍可在应用内正常收听全部已制作的章节。"
                )
            }

            AudiobookAudioVersionPicker(workflow: workflow)

            Picker("导出格式", selection: $selectedProfile) {
                ForEach(AudiobookExportProfile.allCases) { profile in
                    Text(profile.title).tag(profile)
                }
            }
            .pickerStyle(.segmented)

            Text(selectedProfile.subtitle)
                .font(SpeechRailDesignTokens.Typography.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

            exportReadinessCard

            CardSurface {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Toggle(isOn: $loudnessEnabled) {
                        Text("统一音量")
                            .font(SpeechRailDesignTokens.Typography.body)
                    }
                    .accessibilityHint("按整本统一音量，减少章节之间忽大忽小；默认关闭。")
                    Text("按整本统一音量，减少章节之间忽大忽小；默认关闭。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
                .padding(SpeechRailDesignTokens.Spacing.sm)
            }

            if selectedProfile == .m4b {
                CardSurface {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.sm) {
                            coverThumbnail
                            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                                Text("封面")
                                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                                Text(workflow.exportCover == nil
                                    ? "可选：选择一张 JPG 或 PNG 图片，随整本 M4B 一起写入，播放器中即可显示。"
                                    : "已选择封面，将随整本 M4B 一起写入。")
                                    .font(SpeechRailDesignTokens.Typography.caption)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            }
                            Spacer()
                            Button(workflow.exportCover == nil ? "选择封面…" : "更换…") {
                                isPresentingCoverImporter = true
                            }
                            .speechRailButton(.quiet)
                            if workflow.exportCover != nil {
                                Button("清除") {
                                    Task { await workflow.clearExportCover() }
                                }
                                .speechRailButton(.quiet)
                            }
                        }
                        if let coverError = workflow.exportCoverErrorMessage {
                            Text(coverError)
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        }
                    }
                    .padding(SpeechRailDesignTokens.Spacing.sm)
                }
                .fileImporter(
                    isPresented: $isPresentingCoverImporter,
                    allowedContentTypes: [.jpeg, .png]
                ) { result in
                    if case let .success(url) = result {
                        Task { await workflow.setExportCover(sourceURL: url) }
                    }
                }
            }

            if selectedProfile == .chapterMP3 {
                CardSurface {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        HStack {
                            Text("选择要导出的章节")
                                .font(SpeechRailDesignTokens.Typography.sectionTitle)
                            Spacer()
                            Button("全选已就绪章节") {
                                selectedChapterIDs = Set(workflow.exportReadyChapters.map(\.id))
                            }
                            .speechRailButton(.quiet)
                        }

                        List(workflow.exportChapters) { chapter in
                            let auditReady = workflow.exportAudit.map { Set($0.readyChapterIDs) }
                            let isExportable = !chapter.isSkipped
                                && (auditReady?.contains(chapter.id) ?? (chapter.currentChapterRevisionID != nil))
                            let readiness = workflow.chapterReadinessByID[chapter.id] ?? .awaitingGlobalAnalysis
                            HStack {
                                Toggle(
                                    isOn: Binding(
                                        get: { selectedChapterIDs.contains(chapter.id) },
                                        set: { checked in
                                            if checked {
                                                selectedChapterIDs.insert(chapter.id)
                                            } else {
                                                selectedChapterIDs.remove(chapter.id)
                                            }
                                        }
                                    )
                                ) {
                                    Text(chapter.title)
                                        .font(SpeechRailDesignTokens.Typography.body)
                                }
                                .toggleStyle(.checkbox)
                                .disabled(!isExportable)

                                Spacer()

                                StatusPill(
                                    tone: isExportable ? .healthy : .attention,
                                    label: chapter.isSkipped
                                        ? "已跳过"
                                        : (isExportable ? "已就绪" : readinessLabel(readiness))
                                )
                            }
                        }
                        .frame(minHeight: 180)
                    }
                    .padding(SpeechRailDesignTokens.Spacing.sm)
                }
            }

            if let prepared = workflow.preparedExport {
                CardSurface {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        HStack {
                            StatusPill(tone: .healthy, label: "已通过媒体帧与时长核验")
                            Text("将导出 \(prepared.exportedChapters.count) 章")
                                .font(SpeechRailDesignTokens.Typography.sectionTitle)
                        }
                        if !prepared.omittedChapters.isEmpty {
                            Text("未包含章节（\(prepared.omittedChapters.count) 章）：" + prepared.omittedChapters.map { "\($0.chapterTitle)（\($0.reason)）" }.joined(separator: "；"))
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        }
                    }
                    .padding(SpeechRailDesignTokens.Spacing.md)
                }
            }

            HStack {
                Button("关闭", role: .cancel) {
                    workflow.isShowingExportSheet = false
                    workflow.preparedExport = nil
                }
                .speechRailButton(.secondary)

                Spacer()

                if workflow.preparedExport == nil {
                    if workflow.isPreparingExport {
                        Button("取消导出") {
                            Task { await workflow.cancelExportPreparation() }
                        }
                        .speechRailButton(.secondary)
                    } else {
                        Button("生成并校验导出包") {
                            let ids = selectedProfile == .m4b ? nil : Array(selectedReadyChapterIDs)
                            Task {
                                await workflow.prepareExport(
                                    profile: selectedProfile,
                                    chapterIDs: ids,
                                    loudnessEnabled: loudnessEnabled
                                )
                            }
                        }
                        .speechRailButton(.primary)
                        .disabled(!canPrepareExport)
                        .help(workflow.isAuditingExport
                              ? "正在检查章节、标注与音频资产，请稍候。"
                              : (canPrepareExport
                                  ? "生成导出包并校验章节与媒体帧"
                                  : (selectedProfile == .m4b
                                      ? "整本 M4B 需要所有未跳过章节都有当前音频。"
                                      : "至少选择一个已就绪章节。")))
                    }
                } else {
                    Button("选择保存位置并完成导出…") {
                        presentSaveExportPanel()
                    }
                    .speechRailButton(.primary)
                }
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.gutter)
        .frame(width: SpeechRailDesignTokens.Layout.Sheet.wideWidth)
        .onAppear {
            workflow.preparedExport = nil
            selectedChapterIDs = Set(workflow.exportReadyChapters.map(\.id))
            workflow.clearExportError()
        }
        .onChange(of: selectedProfile) { _, _ in
            invalidatePreparedExport()
        }
        .onChange(of: selectedChapterIDs) { _, _ in
            invalidatePreparedExport()
        }
        .onChange(of: workflow.selectedAudioRevisionID) { _, _ in
            selectedChapterIDs = Set(workflow.exportReadyChapters.map(\.id))
            invalidatePreparedExport()
        }
        .onChange(of: loudnessEnabled) { _, _ in
            invalidatePreparedExport()
        }
        .task(id: auditKey) {
            let ids = selectedProfile == .m4b ? nil : selectedChapterIDs.sorted { $0.uuidString < $1.uuidString }
            await workflow.refreshExportAudit(profile: selectedProfile, chapterIDs: ids)
        }
        .onDisappear {
            workflow.clearExportError()
        }
    }

    private var auditKey: String {
        let ids = selectedProfile == .chapterMP3
            ? selectedChapterIDs.map(\.uuidString).sorted().joined(separator: ",")
            : "all"
        return "\(selectedProfile.rawValue)|\(workflow.selectedAudioRevisionID?.uuidString ?? "current")|\(ids)"
    }

    private var readiness: AudiobookExportReadiness {
        guard let audit = workflow.exportAudit else { return workflow.exportReadiness }
        let ready = Set(audit.readyChapterIDs)
        return AudiobookExportReadiness(
            readyChapterIDs: audit.readyChapterIDs,
            blockingChapterIDs: workflow.exportChapters
                .filter { !$0.isSkipped && !ready.contains($0.id) }
                .map(\.id)
        )
    }

    private var readyChapterIDs: Set<UUID> {
        Set(readiness.readyChapterIDs)
    }

    private var selectedReadyChapterIDs: Set<UUID> {
        selectedChapterIDs.intersection(readyChapterIDs)
    }

    private var canPrepareExport: Bool {
        guard workflow.exportCapabilities.available else { return false }
        guard !workflow.isAuditingExport else { return false }
        switch selectedProfile {
        case .m4b:
            guard let audit = workflow.exportAudit else { return false }
            return audit.isFullBookReady
        case .chapterMP3:
            guard let audit = workflow.exportAudit else { return false }
            let ready = Set(audit.readyChapterIDs)
            return !selectedChapterIDs.intersection(ready).isEmpty
        }
    }

    private func invalidatePreparedExport() {
        guard workflow.preparedExport != nil || workflow.exportErrorMessage != nil else { return }
        workflow.preparedExport = nil
        workflow.clearExportError()
    }

    @ViewBuilder
    private var exportReadinessCard: some View {
        if workflow.preparedExport == nil {
            let audit = workflow.exportAudit
            let blockers = audit?.blockers ?? []
            CardSurface {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.sm) {
                        if workflow.isAuditingExport {
                            StatusPill(tone: .neutral, label: "正在检查可导出章节…")
                        } else if let audit {
                            if selectedProfile == .m4b {
                                if audit.isFullBookReady {
                                    StatusPill(tone: .healthy, label: "全书 \(audit.readyChapterCount) 章已就绪")
                                } else {
                                    StatusPill(
                                        tone: .attention,
                                        label: audit.readyChapterCount == 0
                                            ? "还没有可导出的章节"
                                            : "还有 \(blockers.count) 章未就绪"
                                    )
                                }
                            } else {
                                StatusPill(
                                    tone: selectedReadyChapterIDs.isEmpty ? .attention : .healthy,
                                    label: "已选 \(selectedReadyChapterIDs.count) / 已就绪 \(audit.readyChapterCount) 章"
                                )
                            }
                        } else {
                            StatusPill(tone: .attention, label: "尚未完成导出检查")
                        }

                        Spacer(minLength: 0)

                        if !workflow.isListeningToHistoricalAudio, selectedProfile == .m4b, let first = blockers.first {
                            Button("去处理「\(first.chapterTitle)」…") {
                                workflow.focusFirstExportBlockingChapter()
                            }
                            .speechRailButton(.secondary)
                        } else if !workflow.isListeningToHistoricalAudio, selectedProfile == .chapterMP3,
                                  let audit,
                                  audit.readyChapterCount == 0,
                                  !workflow.exportBlockingChapters.isEmpty
                        {
                            Button("去制作章节…") {
                                workflow.focusFirstExportBlockingChapter()
                            }
                            .speechRailButton(.secondary)
                        }
                    }

                    if selectedProfile == .m4b {
                        if let audit {
                            if audit.readyChapterCount == 0 && blockers.isEmpty {
                                Text("所有章节都已跳过。请先在章节目录恢复至少一章，再导出。")
                                    .font(SpeechRailDesignTokens.Typography.caption)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            } else if audit.isFullBookReady {
                                Text("所有未跳过章节都有当前音频，可以生成整本 M4B。")
                                    .font(SpeechRailDesignTokens.Typography.caption)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            } else {
                                ForEach(blockers.prefix(3)) { blocker in
                                    Text("\(blocker.chapterTitle)：\(blocker.message)")
                                        .font(SpeechRailDesignTokens.Typography.caption)
                                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                }
                                if blockers.count > 3 {
                                    Text("另有 \(blockers.count - 3) 章未就绪，可切换为分章节音频包只导出已完成章节。")
                                        .font(SpeechRailDesignTokens.Typography.caption)
                                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                }
                            }
                        } else {
                            Text("正在读取章节、标注与音频资产；检查完成前不会生成导出包。")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        }
                    } else {
                        Text("只会导出选中的已就绪章节；未就绪与已跳过章节不会写入文件。")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    }
                }
                .padding(SpeechRailDesignTokens.Spacing.sm)
            }
        }
    }

    @ViewBuilder
    private var coverThumbnail: some View {
        if let url = workflow.exportCoverPreviewURL, let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(
                    width: SpeechRailDesignTokens.List.rowIconFrame,
                    height: SpeechRailDesignTokens.List.rowIconFrame
                )
                .clipShape(SpeechRailDesignTokens.Corner.compactShape)
        } else {
            Image(systemName: "photo")
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .frame(
                    width: SpeechRailDesignTokens.List.rowIconFrame,
                    height: SpeechRailDesignTokens.List.rowIconFrame
                )
        }
    }

    private func readinessLabel(_ state: AudiobookChapterReadinessState) -> String {
        switch state {
        case .awaitingGlobalAnalysis: return "待全书分析"
        case .awaitingCastConfirmation: return "待确认声音"
        case .blockedByUnknownSpeakers: return "含待确认说话人"
        case .readyForProduction: return "待制作音频"
        case .producing: return "制作中"
        case .paused: return "已暂停"
        case .needsUpdate: return "有更新待重制"
        case .chapterAudioReady: return "已就绪"
        case .skipped: return "已跳过"
        case .failed: return "制作未完成"
        }
    }

    private func presentSaveExportPanel() {
        guard let prepared = workflow.preparedExport else { return }
        if prepared.profile == .m4b {
            let savePanel = NSSavePanel()
            savePanel.title = "导出整本 M4B 有声书"
            savePanel.nameFieldStringValue = "\(prepared.bookTitle).m4b"
            if savePanel.runModal() == .OK, let url = savePanel.url,
               confirmReplacingExistingItem(at: url, isDirectory: false)
            {
                let consent = try? AudiobookOverwriteConsent.capture(at: url)
                Task {
                    await workflow.commitPreparedExport(destination: url, overwriteConsent: consent)
                }
            }
        } else {
            let openPanel = NSOpenPanel()
            openPanel.title = "选择分章节 MP3 导出目录"
            openPanel.canChooseFiles = false
            openPanel.canChooseDirectories = true
            openPanel.canCreateDirectories = true
            if openPanel.runModal() == .OK, let folderURL = openPanel.url {
                let bundleURL = folderURL.appendingPathComponent("\(prepared.bookTitle)-MP3", isDirectory: true)
                if confirmReplacingExistingItem(at: bundleURL, isDirectory: true) {
                    let consent = try? AudiobookOverwriteConsent.capture(at: bundleURL)
                    Task {
                        await workflow.commitPreparedExport(destination: bundleURL, overwriteConsent: consent)
                    }
                }
            }
        }
    }

    /// 目录覆写没有系统级确认，必须在替换前明确告知会整体替换已有内容。
    private func confirmReplacingExistingItem(at url: URL, isDirectory: Bool) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = isDirectory ? "替换已有的同名导出目录？" : "替换已有的同名导出文件？"
        alert.informativeText = isDirectory
            ? "目标位置已存在「\(url.lastPathComponent)」目录。继续会整体替换该目录中的同名导出内容，原有文件不会保留。"
            : "目标位置已存在同名文件。继续会替换该文件，原内容不会保留。"
        alert.addButton(withTitle: "替换")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - Trash Sheet

struct AudiobookTrashSheet: View {
    @Bindable var workflow: AudiobookWorkflowModel

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            SectionHeading(
                title: "有声书废纸篓",
                detail: "移入废纸篓的项目保留完整正文与已生成音频，可随时恢复；不会影响原始 TXT 或外部已导出文件。"
            )

            if workflow.trashedBooks.isEmpty {
                SessionEmptyState(
                    systemImage: "trash",
                    title: "废纸篓为空",
                    message: "从书架移除的有声书项目会暂存在这里，方便需要时一键恢复。"
                ) {
                    EmptyView()
                }
                .frame(minHeight: 200)
            } else {
                List(workflow.trashedBooks) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                            Text(entry.title)
                                .font(SpeechRailDesignTokens.Typography.sectionTitle)
                            Text("移入时间：\(entry.trashedAt.speechRailFormatted())")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        }
                        Spacer()
                        Button("恢复到书架") {
                            Task { await workflow.restoreTrashedBook(entry.id) }
                        }
                        .speechRailButton(.secondary)
                    }
                }
                .frame(minHeight: 220)
            }

            HStack {
                Spacer()
                Button("关闭") {
                    workflow.isShowingTrashSheet = false
                }
                .speechRailButton(.primary)
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.gutter)
        .frame(width: SpeechRailDesignTokens.Layout.Sheet.regularWidth)
    }
}

// MARK: - Cast Merge / Split Sheet

struct AudiobookCastMergeSplitSheet: View {
    @Bindable var workflow: AudiobookWorkflowModel
    @State private var sourceRoleID: UUID?
    @State private var targetRoleID: UUID?
    @State private var splitNewRoleName: String = ""

    private var nonNarratorRoles: [AudiobookCharacter] {
        workflow.characters.filter { !$0.isNarrator }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            SectionHeading(
                title: "合并或拆分角色",
                detail: "当同一个人物以不同称呼出现时可合并为一个角色；同名不同人时可将当前选中的段落拆分为独立角色。"
            )

            CardSurface {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                    Text("合并两个角色（保留目标角色 ID 与已绑定音色）")
                        .font(SpeechRailDesignTokens.Typography.sectionTitle)

                    HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                        Picker("将被合并的角色", selection: $sourceRoleID) {
                            Text("选择来源角色").tag(UUID?.none)
                            ForEach(nonNarratorRoles) { role in
                                Text(role.displayName).tag(UUID?.some(role.id))
                            }
                        }
                        Image(systemName: "arrow.right")
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        Picker("合并入目标角色", selection: $targetRoleID) {
                            Text("选择目标角色").tag(UUID?.none)
                            ForEach(nonNarratorRoles) { role in
                                Text(role.displayName).tag(UUID?.some(role.id))
                            }
                        }
                    }

                    if let sourceID = sourceRoleID,
                       let targetID = targetRoleID,
                       sourceID != targetID
                    {
                        let affectedCount = workflow.chapterAnnotations.filter { $0.assignment.roleID == sourceID }.count
                        Text("影响范围预览：当前章节有 \(affectedCount) 处归属将并入目标角色，来源角色原名将自动记入目标角色别称。")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

                        Button("执行角色合并") {
                            Task {
                                await workflow.mergeCharacters(sourceRoleID: sourceID, intoTargetRoleID: targetID)
                                workflow.isShowingCastMergeSheet = false
                            }
                        }
                        .speechRailButton(.primary)
                    }
                }
                .padding(SpeechRailDesignTokens.Spacing.md)
            }

            CardSurface {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                    Text("从当前选中段落拆分新角色")
                        .font(SpeechRailDesignTokens.Typography.sectionTitle)
                    TextField("新角色名称（如：老周·青年时期）", text: $splitNewRoleName)
                        .speechRailSingleLineInput()
                    HStack {
                        Text("当前已选中 \(workflow.selectedAtomIDs.count) 段正文（在主工作区勾选段落后可拆出为独立角色）")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        Spacer()
                        Button("拆分并创建新角色") {
                            guard let sourceID = workflow.selectedRoleID ?? nonNarratorRoles.first?.id else { return }
                            Task {
                                await workflow.splitCharacter(
                                    sourceRoleID: sourceID,
                                    newDisplayName: splitNewRoleName,
                                    atomIDs: Array(workflow.selectedAtomIDs)
                                )
                                workflow.isShowingCastMergeSheet = false
                            }
                        }
                        .speechRailButton(.secondary)
                        .disabled(splitNewRoleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workflow.selectedAtomIDs.isEmpty)
                    }
                }
                .padding(SpeechRailDesignTokens.Spacing.md)
            }

            HStack {
                Spacer()
                Button("关闭") {
                    workflow.isShowingCastMergeSheet = false
                }
                .speechRailButton(.secondary)
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.gutter)
        .frame(width: SpeechRailDesignTokens.Layout.Sheet.formWidth)
        .onAppear {
            sourceRoleID = workflow.selectedRoleID ?? nonNarratorRoles.first?.id
            targetRoleID = nonNarratorRoles.dropFirst().first?.id
        }
    }
}


struct AudiobookVoiceTag: View {
    let name: String
    let detail: String

    var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
            Image(systemName: "waveform")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.voice)
                .accessibilityHidden(true)
            Text(name)
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
            Text("· \(detail)")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)
        .background(
            SpeechRailDesignTokens.Color.recessedField,
            in: SpeechRailDesignTokens.Corner.compactShape
        )
    }
}

/// One selection drives both listening and export, without changing editable text.
struct AudiobookAudioVersionPicker: View {
    @Bindable var workflow: AudiobookWorkflowModel

    var body: some View {
        if !workflow.audioRevisions.isEmpty {
            Picker("音频版本", selection: Binding<UUID?>(
                get: { workflow.selectedAudioRevisionID },
                set: { id in Task { await workflow.selectAudioRevision(id) } }
            )) {
                Text("当前文本的音频").tag(Optional<UUID>.none)
                ForEach(workflow.audioRevisions) { revision in
                    Text("之前版本 · " + revision.createdAt.speechRailFormatted())
                        .tag(Optional(revision.id))
                }
            }
            .disabled(workflow.isPreparingExport || workflow.isPreparingWorkingText)
            .help("之前版本使用它对应的正文和音频，可直接收听或导出。")
        }
    }
}
