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
                if let voiceMsg = workflow.voiceReturnBannerMessage {
                    StatusBanner(
                        kind: .standard,
                        tone: .healthy,
                        title: "音色流程返回",
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
                } else if let bannerMsg = workflow.bannerMessage {
                    StatusBanner(
                        kind: .standard,
                        tone: .healthy,
                        title: "状态更新",
                        message: bannerMsg,
                        actionTitle: "收起"
                    ) {
                        workflow.bannerMessage = nil
                    }
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
                    title: "导入 TXT…",
                    systemImage: "doc.badge.plus",
                    helpText: "选择本地 TXT 电子书并预览编码与章节边界"
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
        panel.title = "选择要制作成有声书的 TXT 文件"
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "txt") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await workflow.prepareImport(fileURL: url)
            }
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

            if let preview = workflow.importPreview {
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

                HStack(spacing: SpeechRailDesignTokens.Spacing.md) {
                    StatusPill(tone: .healthy, label: "共 \(preview.chapters.count) 章")
                    StatusPill(tone: .neutral, label: "\(preview.sourceIndex.paragraphs.count) 个段落")
                    StatusPill(tone: .neutral, label: "\(preview.scalarCount) 字符")
                    StatusPill(tone: .neutral, label: "编码：\(preview.detectedEncoding.rawValue.uppercased())")
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
                            ScrollView {
                                Text((try? preview.textPreview(for: selectedChapterID, originalLayout: showsOriginalLayout)) ?? preview.previewText)
                                    .font(SpeechRailDesignTokens.Typography.body)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
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

            if !workflow.exportCapabilities.available {
                StatusBanner(
                    kind: .standard,
                    tone: .attention,
                    title: "导出工具不可用",
                    message: "当前本机运行环境尚未检测到可用的 FFmpeg 音频编码工具；您仍可在应用内正常收听全部已制作的章节。"
                )
            }

            Picker("导出格式", selection: $selectedProfile) {
                ForEach(AudiobookExportProfile.allCases) { profile in
                    Text(profile.title).tag(profile)
                }
            }
            .pickerStyle(.segmented)

            Text(selectedProfile.subtitle)
                .font(SpeechRailDesignTokens.Typography.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

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
                                selectedChapterIDs = Set(
                                    workflow.chapters
                                        .filter { $0.currentChapterRevisionID != nil }
                                        .map(\.id)
                                )
                            }
                            .speechRailButton(.quiet)
                        }

                        List(workflow.chapters) { chapter in
                            let isReady = chapter.currentChapterRevisionID != nil
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

                                Spacer()

                                StatusPill(
                                    tone: isReady ? .healthy : .attention,
                                    label: isReady ? "已就绪" : readinessLabel(readiness)
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
                    Button(workflow.isPreparingExport ? "正在编码并校验…" : "生成并校验导出包") {
                        let ids = selectedProfile == .m4b ? nil : Array(selectedChapterIDs)
                        Task {
                            await workflow.prepareExport(
                                profile: selectedProfile,
                                chapterIDs: ids,
                                loudnessEnabled: loudnessEnabled
                            )
                        }
                    }
                    .speechRailButton(.primary)
                    .disabled(workflow.isPreparingExport)
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
            selectedChapterIDs = Set(workflow.chapters.map(\.id))
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
        case .failed: return "制作未完成"
        }
    }

    private func presentSaveExportPanel() {
        guard let prepared = workflow.preparedExport else { return }
        if prepared.profile == .m4b {
            let savePanel = NSSavePanel()
            savePanel.title = "导出整本 M4B 有声书"
            savePanel.nameFieldStringValue = "\(prepared.bookTitle).m4b"
            if savePanel.runModal() == .OK, let url = savePanel.url {
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
                let consent = try? AudiobookOverwriteConsent.capture(at: bundleURL)
                Task {
                    await workflow.commitPreparedExport(destination: bundleURL, overwriteConsent: consent)
                }
            }
        }
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
                            Text("移入时间：\(entry.trashedAt.formatted(date: .abbreviated, time: .shortened))")
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
