import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct TeleprompterView: View {
    @Environment(TeleprompterSession.self) private var session
    @Environment(TeleprompterStageWindowController.self) private var stage
    @Environment(TeleprompterStageSettings.self) private var settings
    @Environment(SessionPreferences.self) private var preferences

    @State private var documents: [TeleprompterDocument] = []
    @State private var isImporterPresented = false
    @State private var isAIDataFlowDisclosurePresented = false
    @State private var operationMessage: String?
    @State private var documentToDelete: TeleprompterDocument?
    @State private var isDeleteAlertPresented = false
    @State private var unavailableDocumentToDelete: TeleprompterV2DocumentListItem?
    @State private var isUnavailableDeleteAlertPresented = false
    @State private var searchQuery = ""

    // 终版规格 Sheet 状态
    @State private var isTrialReadingPresented = false
    @State private var isReadingAliasPresented = false
    @State private var targetMinutesInput = "20"
    @State private var pendingAIAction: AIPendingAction = .prepare
    @State private var localPreparedText = ""
    @State private var preparedTextSyncTask: Task<Void, Never>?

    /// 送模型之前要先说清楚这次发出去的是哪类内容，用户才认得同意按钮在同意什么。
    private enum AIPendingAction {
        /// 把原稿整理成口语播报稿。
        case prepare
        /// 给已确认的稿子补朗读提示。
        case annotate
    }

    private var isTargetMinutesValid: Bool {
        guard let mins = Int(targetMinutesInput.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return mins >= TeleprompterTimingPolicy.minimumTargetMinutes && mins <= TeleprompterTimingPolicy.maximumTargetMinutes
    }

    public init() {}

    public var body: some View {
        PageScaffold(
            route: .teleprompter,
            layout: .fill(
                minimumHeight: SpeechRailDesignTokens.Teleprompter.preparationMinimumHeight
            )
        ) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.gutter) {
                // 选中稿件后的各阶段在工作台内部已有对应状态；只在选择稿件前保留全局状态条，
                // 避免它与稿件状态、阻碍提示重复占据首屏。
                if documents.isEmpty || session.document == nil {
                    SessionStatusBar(
                        title: pageStatusPresentation.title,
                        tone: pageStatusPresentation.tone,
                        facts: pageStatusPresentation.facts
                    )
                }

                if let operationMessage {
                    Label(operationMessage, systemImage: "exclamationmark.triangle")
                        .font(SpeechRailDesignTokens.Typography.callout)
                        .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                }

                if documents.isEmpty {
                    welcomeHub
                } else {
                    populatedWorkspace
                }
                if !session.unavailableDocuments.isEmpty {
                    unavailableDocumentsNotice
                }
            }
        } trailing: {
            headerActions
        }
        .task {
            reloadDocuments()
        }
        .onChange(of: session.document?.id) { _, _ in
            reloadDocuments()
            // 目标时长由会话在载入时定好（存过用存的，否则按原稿估算），
            // 这里只把输入框同步到那个值。原先由视图顺手 `setTargetMinutes`，
            // 于是「打开哪份稿」这件事有了两个负责人，切页回来还可能不触发。
            targetMinutesInput = "\(session.targetMinutes)"
        }
        .sheet(isPresented: $isTrialReadingPresented) {
            TeleprompterTrialReadingSheet(session: session)
        }
        .sheet(isPresented: $isReadingAliasPresented) {
            TeleprompterReadingAliasSheet(session: session)
        }
        .alert(
            TeleprompterAIDataFlowDisclosure.title,
            isPresented: $isAIDataFlowDisclosurePresented
        ) {
            Button("取消", role: .cancel) {}
            Button(pendingAIAction == .prepare ? "允许发送并整理" : "允许发送并添加提示") {
                UserDefaults.standard.set(true, forKey: aiDataFlowAcknowledgementKey)
                switch pendingAIAction {
                case .prepare:
                    startAIAnalysis()
                case .annotate:
                    startAnnotation()
                }
            }
        } message: {
            Text(TeleprompterAIDataFlowDisclosure.message)
        }
        .onDrop(of: [.fileURL, .plainText], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .onAppear(perform: restorePreferredSpeechLanguage)
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [
                .plainText,
                .utf8PlainText,
                .text,
                UTType(filenameExtension: "md") ?? .plainText,
                UTType(filenameExtension: "markdown") ?? .plainText
            ]
        ) { result in
            switch result {
            case .success(let url):
                importFromURL(url)
            case .failure(let error):
                if let cocoaError = error as? CocoaError, cocoaError.code != .userCancelled {
                    operationMessage = "导入失败：\(error.localizedDescription)"
                }
            }
        }
        .alert(
            "确定删除这份稿子？",
            isPresented: $isDeleteAlertPresented,
            presenting: documentToDelete
        ) { doc in
            Button("删除", role: .destructive) {
                do {
                    try session.deleteDocument(documentID: doc.id)
                    operationMessage = nil
                    reloadDocuments()
                } catch {
                    operationMessage = error.localizedDescription
                }
            }
            Button("取消", role: .cancel) {}
        } message: { doc in
            Text("删除「\(doc.title)」后无法恢复。")
        }
        .alert(
            "删除无法打开的稿件？",
            isPresented: $isUnavailableDeleteAlertPresented,
            presenting: unavailableDocumentToDelete
        ) { item in
            Button("删除", role: .destructive) {
                do {
                    try session.deleteDocument(documentID: item.id)
                    unavailableDocumentToDelete = nil
                    reloadDocuments()
                } catch {
                    operationMessage = error.localizedDescription
                }
            }
            Button("取消", role: .cancel) {}
        } message: { item in
            Text("「\(item.id)」的当前格式无法读取。删除后可以重新导入原稿。")
        }
    }

    private var pageStatusPresentation: SessionPageStatusPresentation {
        let facts = [
            session.document?.title,
            session.activeVersion.map { "\($0.segments.count) 段" },
            "目标约 \(session.targetMinutes) 分钟"
        ].compactMap { $0 }

        if let blocked = session.blocked {
            return SessionPageStatusPresentation(
                title: blocked.title,
                tone: .attention,
                facts: facts
            )
        }

        return switch session.phase {
        case .draft:
            SessionPageStatusPresentation(
                title: "草稿待整理",
                tone: .neutral,
                facts: facts
            )
        case .analyzing:
            SessionPageStatusPresentation(
                title: "正在整理稿件",
                tone: .attention,
                facts: facts
            )
        case .prepared:
            SessionPageStatusPresentation(
                title: "整理好了",
                tone: .healthy,
                facts: facts
            )
        case .ready:
            SessionPageStatusPresentation(
                title: "提词稿已就绪",
                tone: .healthy,
                facts: facts
            )
        case .preparing:
            SessionPageStatusPresentation(
                title: "正在连接提词舞台",
                tone: .attention,
                facts: facts
            )
        case .following:
            SessionPageStatusPresentation(
                title: "正在跟读",
                tone: .healthy,
                facts: facts
            )
        case .paused:
            SessionPageStatusPresentation(
                title: "跟读已暂停",
                tone: .attention,
                facts: facts
            )
        case .uncertain:
            SessionPageStatusPresentation(
                title: "位置已保留",
                tone: .attention,
                facts: facts
            )
        case .manual:
            SessionPageStatusPresentation(
                title: "手动提词",
                tone: .healthy,
                facts: facts
            )
        case .ended:
            SessionPageStatusPresentation(
                title: "跟读已结束",
                tone: .neutral,
                facts: facts
            )
        }
    }

    // MARK: - 头部工具栏动作

    @ViewBuilder
    private var headerActions: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            if documents.isEmpty {
                PageActionButton(
                    title: "导入文件…",
                    icon: .importDocument,
                    helpText: "导入 TXT 或 Markdown 文本文件"
                ) {
                    isImporterPresented = true
                }
            } else {
                PageActionsMenu(
                    title: "新建",
                    icon: .add,
                    helpText: "创建新的提词稿件"
                ) {
                    Button("新建空白稿") {
                        session.createDocument(title: "未命名稿子", sourceText: "")
                    }
                    .disabled(!session.canEdit)
                    Button("从剪贴板创建") {
                        createFromClipboard()
                    }
                    Divider()
                    Button("导入文本文件…") {
                        isImporterPresented = true
                    }
                }

                if session.document != nil {
                    PageActionsMenu(
                        title: "导出",
                        icon: .export,
                        helpText: "导出原稿或朗读稿"
                    ) {
                        Button("导出原稿 (Markdown)…", systemImage: SpeechRailDesignTokens.Icon.Symbol.document.systemName) {
                            exportSourceDocument()
                        }
                        Button("导出朗读稿 (Markdown)…", systemImage: SpeechRailDesignTokens.Icon.Symbol.readingCues.systemName) {
                            exportReadingDocument()
                        }
                        Divider()
                        Button("复制稿件内容", systemImage: SpeechRailDesignTokens.Icon.Symbol.copy.systemName) {
                            copyDocumentContent()
                        }
                    }
                }

                if session.isCapturing {
                    PageActionButton(
                        title: "关闭语音跟随",
                        icon: .stop,
                        helpText: "停止语音跟随并释放麦克风，保留当前阅读位置"
                    ) {
                        Task { await session.disableVoiceAssist() }
                    }
                } else if session.document != nil {
                    PageActionButton(
                        title: "打开提词器",
                        icon: .stage,
                        helpText: "打开独立悬浮提词窗口，默认手动阅读"
                    ) {
                        showStage()
                    }
                }
            }
        }
    }

    // MARK: - 首屏欢迎工作台（无稿件时）

    private var welcomeHub: some View {
        VStack(spacing: SpeechRailDesignTokens.Spacing.gutter) {
            VStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(SpeechRailDesignTokens.Color.rail.opacity(0.12))
                        .frame(
                            width: SpeechRailDesignTokens.Teleprompter.welcomeIconOuterSize,
                            height: SpeechRailDesignTokens.Teleprompter.welcomeIconOuterSize
                        )
                    Image(systemName: "text.bubble")
                        .font(.system(size: SpeechRailDesignTokens.Teleprompter.welcomeIconSize, weight: .semibold))
                        .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                }

                VStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Text("准备一份提词稿件")
                        .font(SpeechRailDesignTokens.Typography.display)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)

                    Text("在独立悬浮舞台中跟读，视线自然对齐摄像头；支持 AI 时长规划、智能断句与口语化整理。")
                        .font(SpeechRailDesignTokens.Typography.callout)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: SpeechRailDesignTokens.Teleprompter.welcomeContentMaxWidth)
                }

                HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    Button {
                        session.createDocument(title: "未命名稿子", sourceText: "")
                    } label: {
                        Label("新建空白稿", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.extraLarge)
                    .disabled(!session.canEdit)

                    Button {
                        createFromClipboard()
                    } label: {
                        if let snippet = pasteboardSnippet {
                            Label("从剪贴板创建 (\(snippet.count) 字)", systemImage: "doc.on.clipboard")
                        } else {
                            Label("从剪贴板创建", systemImage: "doc.on.clipboard")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.extraLarge)

                    Button {
                        isImporterPresented = true
                    } label: {
                        Label("导入文件…", systemImage: "arrow.down.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.extraLarge)
                }
                .padding(.top, SpeechRailDesignTokens.Spacing.xs)
            }
            .frame(maxWidth: .infinity)

            // 开箱即用范例卡片
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Image(systemName: "sparkles")
                        .font(SpeechRailDesignTokens.Typography.captionMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                    Text("开箱即用范例")
                        .font(SpeechRailDesignTokens.Typography.sectionTitle)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    Text("点击任一场景直接载入体验")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                }

                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: SpeechRailDesignTokens.Teleprompter.welcomeTemplateMinimumWidth),
                            spacing: SpeechRailDesignTokens.Spacing.sm
                        )
                    ],
                    alignment: .leading,
                    spacing: SpeechRailDesignTokens.Spacing.sm
                ) {
                    ForEach(starterTemplates) { template in
                        Button {
                            session.createDocument(title: template.title, sourceText: template.content)
                        } label: {
                            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                                    Image(systemName: template.icon)
                                        .font(SpeechRailDesignTokens.Typography.caption)
                                        .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                                    Text(template.tag)
                                        .font(SpeechRailDesignTokens.Typography.captionMedium)
                                        .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                                    Spacer(minLength: 0)
                                }

                                Text(template.title)
                                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                                    .lineLimit(1)

                                Text(template.subtitle)
                                    .font(SpeechRailDesignTokens.Typography.caption)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                    .lineLimit(1)

                                Text(template.content.trimmingCharacters(in: .whitespacesAndNewlines))
                                    .font(SpeechRailDesignTokens.Typography.caption)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, SpeechRailDesignTokens.Spacing.micro)
                            }
                            .padding(SpeechRailDesignTokens.Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                SpeechRailDesignTokens.Color.field,
                                in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.container, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.container, style: .continuous)
                                    .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
                            )
                        }
                        .buttonStyle(.plain)
                        .speechRailPointerCursor()
                        .disabled(!session.canEdit)
                    }
                }
            }

            // 提词工作流说明
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Image(systemName: "checklist")
                        .font(SpeechRailDesignTokens.Typography.captionMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    Text("提词工作流")
                        .font(SpeechRailDesignTokens.Typography.sectionTitle)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                }

                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: SpeechRailDesignTokens.Teleprompter.welcomeTemplateMinimumWidth),
                            spacing: SpeechRailDesignTokens.Spacing.sm
                        )
                    ],
                    alignment: .leading,
                    spacing: SpeechRailDesignTokens.Spacing.sm
                ) {
                    workflowStepCard(
                        step: "1",
                        icon: "square.and.pencil",
                        title: "编排与预检",
                        detail: "设置目标时长与朗读节奏，实时预检篇幅是否合理，原稿永远不会被覆盖。"
                    )
                    workflowStepCard(
                        step: "2",
                        icon: "sparkles",
                        title: "口语化整理",
                        detail: "把原稿整理成可以直接照念的稿子；哪一段不念，当场点一下就能改。"
                    )
                    workflowStepCard(
                        step: "3",
                        icon: "macwindow.on.rectangle",
                        title: "独立悬浮跟读",
                        detail: "舞台贴近摄像头保持自然视线，等宽计时与语音识别驱动智能滚动。"
                    )
                }
            }

            welcomeSafetyNotice
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var unavailableDocumentsNotice: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                Label {
                    Text("有 \(session.unavailableDocuments.count) 份稿件无法打开，未影响其他稿件。可以删除后重新导入原稿重建。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                } icon: {
                    Image(systemName: "doc.badge.ellipsis")
                        .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                }

                ForEach(session.unavailableDocuments, id: \.id) { item in
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Text(item.id)
                            .font(SpeechRailDesignTokens.Typography.technicalValue)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                            .lineLimit(1)
                        Spacer()
                        Button("删除", role: .destructive) {
                            unavailableDocumentToDelete = item
                            isUnavailableDeleteAlertPresented = true
                        }
                        .buttonStyle(.borderless)
                        .disabled(!session.canEdit)
                    }
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    private func workflowStepCard(step: String, icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
            ZStack {
                Circle()
                    .fill(SpeechRailDesignTokens.Color.recessedField)
                    .frame(width: SpeechRailDesignTokens.Layout.badgeMediumSize, height: SpeechRailDesignTokens.Layout.badgeMediumSize)
                Text(step)
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
            }

            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Image(systemName: icon)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    Text(title)
                        .font(SpeechRailDesignTokens.Typography.bodyMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                }

                Text(detail)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(SpeechRailDesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            SpeechRailDesignTokens.Color.field,
            in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.container, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.container, style: .continuous)
                .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
        )
    }

    private var welcomeSafetyNotice: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.gutter) {
            Label {
                Text("直播推流建议：OBS 或直播伴侣请采集「摄像头」或「目标窗口」，避免全屏采集捕获提词悬浮窗。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            } icon: {
                Image(systemName: "rectangle.on.rectangle")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
            }

            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)

            Label {
                Text(TeleprompterAIDataFlowDisclosure.inlineMessage)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            } icon: {
                Image(systemName: "lock.shield")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        .background(
            SpeechRailDesignTokens.Color.recessedField,
            in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
        )
    }

    // MARK: - 已有稿件时的工作台

    private var populatedWorkspace: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.md) {
                recentDocuments
                    .frame(width: SpeechRailDesignTokens.Layout.sessionListWidth)
                    .disabled(!session.canEdit || session.isPreparingDraft)
                editor(showInlineDocumentPicker: false)
            }
            .frame(minWidth: populatedWorkspaceMinimumWidth, alignment: .top)

            editor(showInlineDocumentPicker: true)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// 双栏工作台的最小可用宽度：目录列 + 栏间距 + 编辑区最小可读宽度。
    /// 可用宽度低于它时 `ViewThatFits` 退到「内联稿件切换 + 统一工作台」的全宽排布。
    private var populatedWorkspaceMinimumWidth: CGFloat {
        SpeechRailDesignTokens.Layout.sessionListWidth
            + SpeechRailDesignTokens.Spacing.md
            + SpeechRailDesignTokens.Teleprompter.workbenchEditorMinimumWidth
    }

    private var recentDocuments: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                CardHead(title: "我的稿子", detail: "\(documents.count) 篇稿件与跟读版本") {
                    Menu {
                        Button("新建空白稿") {
                            session.createDocument(title: "未命名稿子", sourceText: "")
                        }
                        .disabled(!session.canEdit)
                        Button("从剪贴板创建") {
                            createFromClipboard()
                        }
                        Divider()
                        Button("导入文本文件…") {
                            isImporterPresented = true
                        }
                    } label: {
                        Label("新建", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                }

                // 搜索过滤条
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Image(systemName: "magnifyingglass")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)

                    TextField("搜索稿件…", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(SpeechRailDesignTokens.Typography.callout)

                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(SpeechRailDesignTokens.Typography.subheadline)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清空稿件搜索")
                        .help("清空稿件搜索")
                        .speechRailPointerCursor()
                    }
                }
                .speechRailSingleLineInput(.compact)
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                .padding(.bottom, SpeechRailDesignTokens.Spacing.xs)

                SessionHairline()

                if filteredDocuments.isEmpty {
                    VStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Spacer()
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(SpeechRailDesignTokens.Typography.emptyStateIcon)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        Text("未找到匹配的稿件")
                            .font(SpeechRailDesignTokens.Typography.bodyMedium)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                        Text("请尝试更换搜索关键词。")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: SpeechRailDesignTokens.Teleprompter.searchEmptyMinHeight)
                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: SpeechRailDesignTokens.Spacing.tight) {
                            ForEach(filteredDocuments) { document in
                                let isSelected = document.id == session.document?.id
                                HStack(spacing: SpeechRailDesignTokens.Spacing.tight) {
                                    Button {
                                        do {
                                            try session.load(documentID: document.id)
                                            operationMessage = nil
                                        } catch {
                                            operationMessage = error.localizedDescription
                                        }
                                    } label: {
                                        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                                            HStack {
                                                Text(document.title)
                                                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                                                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                                                    .lineLimit(1)
                                                Spacer(minLength: 0)
                                                if isSelected {
                                                    StatusPill(tone: .healthy, label: "当前")
                                                }
                                            }
                                            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                                                Text("\(document.sourceText.count) 字")
                                                    .font(SpeechRailDesignTokens.Typography.caption)
                                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                                                Text("·")
                                                    .font(SpeechRailDesignTokens.Typography.caption)
                                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                                                Text(document.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                                    .font(SpeechRailDesignTokens.Typography.caption)
                                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .speechRailPointerCursor()

                                    Menu {
                                        Button("创建副本", systemImage: SpeechRailDesignTokens.Icon.Symbol.duplicate.systemName) {
                                            do {
                                                _ = try session.duplicateDocument(documentID: document.id)
                                                reloadDocuments()
                                            } catch {
                                                operationMessage = error.localizedDescription
                                            }
                                        }
                                        Button("复制稿件内容", systemImage: SpeechRailDesignTokens.Icon.Symbol.copy.systemName) {
                                            if let markdown = session.exportMarkdown() {
                                                NSPasteboard.general.clearContents()
                                                NSPasteboard.general.setString(markdown, forType: .string)
                                                operationMessage = "已复制稿件内容"
                                            }
                                        }
                                        Divider()
                                        Button("删除…", systemImage: SpeechRailDesignTokens.Icon.Symbol.delete.systemName, role: .destructive) {
                                            documentToDelete = document
                                            isDeleteAlertPresented = true
                                        }
                                    } label: {
                                        SpeechRailButtonIcon(.more)
                                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                                            .frame(width: SpeechRailDesignTokens.Layout.badgeSmallSize, height: SpeechRailDesignTokens.Layout.badgeSmallSize)
                                    }
                                    .menuStyle(.borderlessButton)
                                }
                                .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                                .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
                                .background(
                                    isSelected
                                        ? SpeechRailDesignTokens.Surface.selectionTint
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous))
                            }
                        }
                        .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
                    }
                    .frame(maxHeight: .infinity)
                }

                if !documents.isEmpty {
                    SessionHairline()
                    HStack {
                        Text("\(documents.count) 篇稿件")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        Spacer()
                    }
                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                    .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var filteredDocuments: [TeleprompterDocument] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return documents }
        return documents.filter { doc in
            doc.title.localizedCaseInsensitiveContains(trimmed) ||
            doc.sourceText.localizedCaseInsensitiveContains(trimmed)
        }
    }

    // MARK: - 主工作台与状态机

    @ViewBuilder
    private func editor(showInlineDocumentPicker: Bool) -> some View {
        if session.document == nil {
            emptyDocumentState
        } else {
            unifiedWorkbench(showInlineDocumentPicker: showInlineDocumentPicker)
        }
    }

    private var emptyDocumentState: some View {
        SessionEmptyState(
            systemImage: "doc.text",
            title: "选择或新建一份稿件",
            message: "从左侧列表选择一份已有稿件，或点击「新建」开始编排。"
        ) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Button("新建空白稿") {
                    session.createDocument(title: "未命名稿子", sourceText: "")
                }
                .disabled(!session.canEdit)
                .buttonStyle(.borderedProminent)
                Button("从剪贴板创建") {
                    createFromClipboard()
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .speechRailSurface(.panel)
        .clipShape(SpeechRailDesignTokens.Corner.containerShape)
    }

    // MARK: - 统一提词工作台画布 (Unified Workbench Canvas)

    private func unifiedWorkbench(showInlineDocumentPicker: Bool) -> some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 0) {
                // 1. 顶部控制与编排工具条 (Inspector Strip)
                workbenchInspectorStrip(showInlinePicker: showInlineDocumentPicker)

                // 2. 内嵌阻碍横幅 (仅在有 blocked 时展示)
                if let blocked = session.blocked {
                    workbenchBlockedBanner(blocked)
                }

                // 3. 核心视觉舞台 (占据主视域空间，视觉中心绝对聚焦)
                workbenchCoreStage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 4. 一体化操作底座与视效微调坞 (Integrated Bottom Dock)
                workbenchBottomDock
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 1. 工作台顶部控制条 (Inspector Strip)

    private func workbenchInspectorStrip(showInlinePicker: Bool) -> some View {
        let documentPicker = Group {
            if showInlinePicker {
                Menu {
                    ForEach(documents) { document in
                        Button {
                            do {
                                try session.load(documentID: document.id)
                                operationMessage = nil
                            } catch {
                                operationMessage = error.localizedDescription
                            }
                        } label: {
                            Text(document.title)
                        }
                    }
                    Divider()
                    Button("新建空白稿") {
                        session.createDocument(title: "未命名稿子", sourceText: "")
                    }
                    .disabled(!session.canEdit)
                    Button("从剪贴板创建") {
                        createFromClipboard()
                    }
                    Button("导入文本文件…") {
                        isImporterPresented = true
                    }
                } label: {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.tight) {
                        Image(systemName: "doc.text")
                            .font(SpeechRailDesignTokens.Typography.bodyMedium)
                            .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    }
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("选择稿件")
                .accessibilityValue(session.document?.title ?? "未选择")
                .speechRailPointerCursor()
            } else {
                Image(systemName: "doc.text")
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
            }
        }
        let titleInput = TextField("稿件名称", text: titleBinding)
            .disabled(!session.canEdit || session.isPreparingDraft)
            .textFieldStyle(.plain)
            .font(SpeechRailDesignTokens.Typography.bodyMedium)
            .speechRailSingleLineInput(.regular)
            .frame(
                minWidth: SpeechRailDesignTokens.Teleprompter.workbenchDocumentTitleMinimumWidth,
                maxWidth: .infinity
            )
        let documentCount = Text("\(sourceBinding.wrappedValue.count) 字")
            .font(SpeechRailDesignTokens.Typography.technicalValue)
            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.compact)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)
            .background(
                SpeechRailDesignTokens.Color.recessedField,
                in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
            )

        return VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            // 宽度充足时同排；窄窗时将字数与状态降到第二行，给名称编辑留出空间。
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.sm) {
                    documentPicker
                    titleInput
                    documentCount
                    documentStatusPill
                    documentOptionsMenu
                }

                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.sm) {
                        documentPicker
                        titleInput
                        documentOptionsMenu
                    }

                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Spacer(minLength: 0)
                        documentCount
                        documentStatusPill
                    }
                }
            }

            SessionHairline()

            // 第二行：目标时长、节奏、匹配结论，以及收起来的语速/试读入口
            let preflight = session.preflightConclusion

            ViewThatFits(in: .horizontal) {
                // 宽窗单行
                HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.md) {
                    targetGroup
                    paceGroup
                    preflightGroup(preflight)

                    Spacer(minLength: 0)

                    readingSetupMenu
                }

                // 窄窗双行
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                    HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.md) {
                        targetGroup
                        paceGroup
                        preflightGroup(preflight)
                    }

                    readingSetupMenu
                }
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.md)
        .background(SpeechRailDesignTokens.Color.recessedField.opacity(0.35))
        .disabled(session.isPreparingDraft)
    }

    private var documentStatusPill: some View {
        Group {
            if case .storeUnavailable = session.blocked {
                StatusPill(tone: .attention, label: "尚未保存")
            } else if session.phase == .prepared {
                StatusPill(tone: .healthy, label: "已整理")
            } else if session.activeVersion != nil {
                StatusPill(tone: .healthy, label: "已就绪")
            } else {
                StatusPill(tone: .neutral, label: "草稿")
            }
        }
    }

    private var documentOptionsMenu: some View {
        Menu {
            // 逐词登记读法：识别器容易听错的词按你的实际读法匹配。少数人才用得上，
            // 不占就绪页首屏，放在文档「⋯」里按需取用。
            Button("读法标注…") {
                isReadingAliasPresented = true
            }
            .disabled(session.activeVersion == nil)

            Divider()

            Button("导出原稿 (Markdown)…", systemImage: SpeechRailDesignTokens.Icon.Symbol.document.systemName) {
                exportSourceDocument()
            }
            Button("导出朗读稿 (Markdown)…", systemImage: SpeechRailDesignTokens.Icon.Symbol.readingCues.systemName) {
                exportReadingDocument()
            }
            Divider()
            Button("创建副本", systemImage: SpeechRailDesignTokens.Icon.Symbol.duplicate.systemName) {
                if let doc = session.document {
                    do {
                        _ = try session.duplicateDocument(documentID: doc.id)
                        reloadDocuments()
                    } catch {
                        operationMessage = error.localizedDescription
                    }
                }
            }
            Button("复制稿件内容", systemImage: SpeechRailDesignTokens.Icon.Symbol.copy.systemName) {
                copyDocumentContent()
            }
            Divider()
            Button("删除这份稿子…", systemImage: SpeechRailDesignTokens.Icon.Symbol.delete.systemName, role: .destructive) {
                if let doc = session.document {
                    documentToDelete = doc
                    isDeleteAlertPresented = true
                }
            }
        } label: {
            SpeechRailButtonIcon(.more)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
        }
        .menuStyle(.borderlessButton)
    }

    private var targetGroup: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Text("目标")
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

            HStack(spacing: SpeechRailDesignTokens.Spacing.tight) {
                TextField("目标", text: $targetMinutesInput)
                    .disabled(!session.canEdit)
                    .font(SpeechRailDesignTokens.Typography.technicalValue)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.plain)
                    .frame(width: SpeechRailDesignTokens.Teleprompter.targetMinutesFieldWidth)
                    .onSubmit {
                        if let mins = Int(targetMinutesInput.trimmingCharacters(in: .whitespacesAndNewlines)),
                           isTargetMinutesValid {
                            session.setTargetMinutes(mins)
                        }
                    }

                Text("分")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            }
            .speechRailSingleLineInput(.compact)
            .overlay {
                if !isTargetMinutesValid && !targetMinutesInput.isEmpty {
                    SpeechRailDesignTokens.Corner.controlShape
                        .strokeBorder(
                            SpeechRailDesignTokens.Color.attention,
                            lineWidth: SpeechRailDesignTokens.Stroke.hairline
                        )
                }
            }

            Menu {
                ForEach(TeleprompterTimingPolicy.quickTargets, id: \.self) { mins in
                    Button("\(mins) 分钟") {
                        targetMinutesInput = "\(mins)"
                        session.setTargetMinutes(mins)
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(SpeechRailDesignTokens.Typography.captionRegular)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            .menuStyle(.borderlessButton)

            if !isTargetMinutesValid && !targetMinutesInput.isEmpty {
                Text("需 1–120 整数分钟")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.attention)
            }
        }
    }

    private var paceGroup: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Text("节奏")
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

            Picker("朗读节奏", selection: Binding(
                get: { session.pace },
                set: { session.setPace($0) }
            )) {
                ForEach(TeleprompterPace.allCases) { pace in
                    Text("\(pace.title) (\(pace.subtitle))").tag(pace)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private func preflightGroup(_ preflight: TeleprompterTimingPolicy.PreflightConclusion) -> some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            // 仅在存在明显偏紧/无效等异常时给出注意力提示，正常匹配或无法预估不作为必须解决的问题打扰用户
            if preflightTone(preflight) == .attention {
                StatusPill(
                    tone: .attention,
                    label: preflight.badgeTitle
                )
            }
        }
    }

    /// 预检结论里的「预计 N 分钟」来自预检计算。没试读校准时它只是按默认语速推的，
    /// 与「无内容」这类结论不同，不加标注会被当成量出来的判断。
    private func preflightGuidance(_ preflight: TeleprompterTimingPolicy.PreflightConclusion) -> String {
        guard preflight.showsDurationEstimate, !session.isPaceCalibrated else {
            return preflight.userGuidance
        }
        return "\(preflight.userGuidance)（未试读校准）"
    }

    /// 语速校准、试读与时长匹配说明的入口。
    ///
    /// 这三样解释的是「整理得好不好」，不是「下一步做什么」。原先它们和目标时长
    /// 并排铺开，普通用户第一眼读到的是一句「预计 1 分钟，与目标 1 分钟大致匹配，
    /// 可正常整理。（未试读校准）」——机制自述，不是任务指引；「计时试读」还同时
    /// 出现在节奏菜单和独立按钮两处。收进这一个菜单后，第二行只剩目标时长和匹配
    /// 结论两个真与时长有关的控件。
    private var readingSetupMenu: some View {
        Menu {
            // 判断依据默认不展开：第二行只留结论徽标。
            Button {} label: {
                Text(preflightGuidance(session.preflightConclusion))
            }
            .disabled(true)

            Divider()

            Button("计时试读…", systemImage: SpeechRailDesignTokens.Icon.Symbol.timer.systemName) {
                isTrialReadingPresented = true
            }
            if session.calibrationSource != .uncalibrated {
                Button("恢复默认语速 (1.0x)", systemImage: SpeechRailDesignTokens.Icon.Symbol.reset.systemName) {
                    session.applyTrialCalibration(k: 1.0, source: .uncalibrated)
                    operationMessage = "已恢复为默认自然语速 (1.0x)"
                }
            }
        } label: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.tight) {
                StatusPill(
                    tone: session.calibrationSource == .uncalibrated ? .neutral : .healthy,
                    label: session.calibrationSource == .uncalibrated
                        ? "未试读校准"
                        : String(format: "%.2fx", session.calibrationFactor)
                )
                SpeechRailButtonIcon(.expandDown, size: SpeechRailDesignTokens.Spacing.xs, weight: .semibold)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .help("语速校准、试读与时长匹配说明")
    }

    private func preflightTone(_ conclusion: TeleprompterTimingPolicy.PreflightConclusion) -> StatusTone {
        switch conclusion {
        case .emptyText, .uncertain: .neutral
        case .matching: .healthy
        case .underfilled, .slightlyOver: .neutral
        case .tight, .invalidTarget: .attention
        }
    }

    // MARK: - 2. 内嵌阻碍横幅 (Contextual Blocked Banner)

    private func workbenchBlockedBanner(_ blocked: TeleprompterSession.BlockReason) -> some View {
        VStack(spacing: 0) {
            SessionHairline()

            HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: SpeechRailDesignTokens.Notice.iconSize, weight: .semibold))
                    .foregroundStyle(SpeechRailDesignTokens.Color.attention)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Text(blocked.title)
                            .font(SpeechRailDesignTokens.Typography.captionMedium)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)

                        Text("· 原稿与进度已完整保留")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    }

                    Text(blocked.detail)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)

                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    switch blocked {
                    case .microphoneDenied:
                        Button("打开系统设置…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .speechRailButton(.primary)

                        Button("打开提词器") {
                            showStage()
                        }
                        .speechRailButton(.secondary)

                    case .inputDeviceUnavailable, .serviceNotReady, .serviceBusy, .streamFailed:
                        Button("打开提词器") {
                            showStage()
                        }
                        .speechRailButton(.primary)

                        Button("重试语音跟随") {
                            showStage()
                            Task { await session.enableVoiceAssist() }
                        }
                        .speechRailButton(.secondary)

                    case .aiUnavailable:
                        Button("重试整理") {
                            requestAIAnalysis()
                        }
                        .speechRailButton(.primary)

                        Button("直接使用原稿") {
                            do {
                                try session.useDeterministicFallback()
                                operationMessage = nil
                            } catch {
                                // 静默 `try?` 会让读者以为按钮坏了：状态已回滚，
                                // 按钮还能再按，但必须告诉他为什么这次没成。
                                operationMessage = error.localizedDescription
                            }
                        }
                        .speechRailButton(.secondary)

                    case .noActiveVersion:
                        Button("直接使用原稿") {
                            do {
                                try session.useDeterministicFallback()
                                operationMessage = nil
                            } catch {
                                operationMessage = error.localizedDescription
                            }
                        }
                        .speechRailButton(.primary)

                    case .occupiedBy:
                        Button("打开提词器") {
                            showStage()
                        }
                        .speechRailButton(.primary)

                    case .speechTrialActive:
                        // 能真正解决它的是结束试读，不是重试跟读——
                        // 麦克风正被提词器自己的试读占着。
                        Button("结束语音试读") {
                            Task {
                                await session.stopSpeechTrial()
                                session.clearBlocked()
                            }
                        }
                        .speechRailButton(.primary)

                    case .storeUnavailable:
                        Button("重试保存") {
                            do {
                                try session.save()
                                operationMessage = nil
                            } catch {
                                // 重试再次失败时不能一声不吭：读者刚腾出磁盘空间，
                                // 看不到结果就只会以为按钮坏了。
                                operationMessage = error.localizedDescription
                            }
                        }
                        .speechRailButton(.primary)
                    }

                    Button {
                        session.clearBlocked()
                    } label: {
                        Image(systemName: "xmark")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                            .frame(width: SpeechRailDesignTokens.Icon.dismissButtonFrame, height: SpeechRailDesignTokens.Icon.dismissButtonFrame)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭提示")
                    .help("关闭当前阻碍提示")
                    .speechRailPointerCursor()
                }
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
            .background(SpeechRailDesignTokens.Surface.attentionTint)

            SessionHairline()
        }
    }

    // MARK: - 3. 核心视觉舞台 (Hero Stage)

    @ViewBuilder
    private var workbenchCoreStage: some View {
        VStack(spacing: 0) {
            SessionHairline()

            switch session.phase {
            case .draft:
                workbenchDraftContent
            case .analyzing, .preparing:
                workbenchAnalyzingContent
            case .prepared:
                workbenchPreparedContent
            case .ready, .ended:
                workbenchReadyContent
            case .following, .paused, .uncertain, .manual:
                workbenchRunningContent
            }
        }
    }

    // MARK: - 3.1 草稿内容视图

    private var workbenchDraftContent: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            HStack {
                Text("原稿正文")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Text("— 可直接编辑、粘贴或从左侧导入 Markdown / 纯文本")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                Spacer()
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            .padding(.top, SpeechRailDesignTokens.Spacing.sm)

            TextEditor(text: sourceBinding)
                .disabled(!session.canEdit)
                .font(SpeechRailDesignTokens.Typography.body)
                .scrollContentBackground(.hidden)
                .padding(SpeechRailDesignTokens.Spacing.sm)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    SpeechRailDesignTokens.Color.recessedField,
                    in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                )
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                .accessibilityLabel("原稿正文")

            if let sourceValidationError = session.sourceValidationError {
                Label(sourceValidationError.localizedDescription, systemImage: "exclamationmark.triangle")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                    .padding(.bottom, SpeechRailDesignTokens.Spacing.xs)
            }
        }
    }

    // MARK: - 3.2 正在整理内容视图

    private var workbenchAnalyzingContent: some View {
        VStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.gutter) {
            Spacer()

            if let progress = session.preparationProgress, progress.total > 0 {
                ProgressView(
                    value: Double(progress.completed),
                    total: Double(progress.total)
                )
                .progressViewStyle(.linear)
                .frame(maxWidth: SpeechRailDesignTokens.Teleprompter.analyzingProgressMaxWidth)
            } else {
                ProgressView()
                    .controlSize(.large)
            }

            VStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text(preparationPhaseTitle)
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)

                Text(preparationProgressDetail)
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }

            HStack(spacing: SpeechRailDesignTokens.Spacing.md) {
                preparationStepLabel("正在整理内容", phase: .mapping, systemImage: "1.circle.fill")
                Image(systemName: "arrow.right")
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                preparationStepLabel("正在检查衔接", phase: .reducing, systemImage: "2.circle.fill")
                Image(systemName: "arrow.right")
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                preparationStepLabel("准备预览", phase: .finalizing, systemImage: "3.circle.fill")
            }
            .font(SpeechRailDesignTokens.Typography.captionMedium)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(SpeechRailDesignTokens.Spacing.lg)
    }

    private var preparationPhaseTitle: String {
        switch session.preparationProgress?.phase {
        case .mapping: "正在整理内容…"
        case .reducing: "正在检查衔接…"
        case .finalizing: "正在准备预览…"
        case nil: "正在整理朗读稿…"
        }
    }

    private var preparationProgressDetail: String {
        guard let progress = session.preparationProgress else {
            return "正在按目标 \(session.targetMinutes) 分钟规划篇幅，保真口语化并检查段落衔接。"
        }
        if progress.total > 0 {
            return "已完成 \(min(progress.completed, progress.total)) / \(progress.total) 项；原稿保持只读。"
        }
        return "正在按目标 \(session.targetMinutes) 分钟规划篇幅；原稿保持只读。"
    }

    private func preparationStepLabel(
        _ title: String,
        phase: TeleprompterPreparationPhase,
        systemImage: String
    ) -> some View {
        let active = session.preparationProgress?.phase == phase
        return Label(title, systemImage: systemImage)
            .foregroundStyle(active ? SpeechRailDesignTokens.Color.rail : SpeechRailDesignTokens.Color.inkTertiary)
    }

    // MARK: - 3.3 整理稿内容视图
    ///
    /// 极简口述字符稿：AI 整理后呈现一份完整的通读稿。
    /// 用户可以像便签一样通读修改，确认无误直接开讲，无需进行琐碎的段落微操。
    private var workbenchPreparedContent: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            CardSurface {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("口述字符稿")
                                .font(SpeechRailDesignTokens.Typography.sectionTitle)
                                .foregroundStyle(SpeechRailDesignTokens.Color.ink)

                            Text("AI 已将原稿转为自然口述语序。通读核对，可直接修改，满意后直接开讲。")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        }

                        Spacer()

                        Button("恢复原稿") {
                            session.discardPendingVersion()
                        }
                        .buttonStyle(.plain)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        .help("放弃 AI 整理，使用导入的原始文本")
                    }

                    SessionHairline()

                    TextEditor(text: $localPreparedText)
                        .disabled(!session.canEdit)
                        .font(SpeechRailDesignTokens.Typography.body)
                        .scrollContentBackground(.hidden)
                        .padding(SpeechRailDesignTokens.Spacing.sm)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            SpeechRailDesignTokens.Color.recessedField,
                            in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                        )
                        .accessibilityLabel("口述字符稿正文")
                        .onAppear {
                            localPreparedText = session.preparedText
                        }
                        .onChange(of: session.phase) { _, newPhase in
                            if newPhase == .prepared {
                                localPreparedText = session.preparedText
                            }
                        }
                        .onChange(of: localPreparedText) { _, newText in
                            preparedTextSyncTask?.cancel()
                            preparedTextSyncTask = Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(350))
                                guard !Task.isCancelled else { return }
                                session.updatePreparedDraftText(newText)
                            }
                        }
                }
                .padding(SpeechRailDesignTokens.Spacing.md)
            }
        }
    }


    // MARK: - 3.4 提词就绪内容视图 (Hero View)

    private var workbenchReadyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let active = session.activeVersion {
                HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(SpeechRailDesignTokens.Typography.captionMedium)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ready)
                        Text(session.phase == .ended && session.blocked == nil ? "跟读已结束" : "提词稿已就绪")
                            .font(SpeechRailDesignTokens.Typography.bodyMedium)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                        Text("· 共 \(active.segments.count) 段")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    }

                    Spacer(minLength: SpeechRailDesignTokens.Spacing.md)

                    // 首屏只留「选起讲段」这一件事。读法标注是逐个词登记读法，
                    // 属于少数人才会用到的术语登记，挪到文档「⋯」菜单里。
                    Text("点击段落设定起讲位置")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                }
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
                .background(SpeechRailDesignTokens.Color.field)

                SessionHairline()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                            ForEach(Array(active.segments.enumerated()), id: \.element.id) { element in
                                let index = element.offset
                                let segment = element.element
                                let isSelected = index == session.currentSegmentIndex

                                Button {
                                    session.moveToSegment(index)
                                } label: {
                                    HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
                                        Capsule()
                                            .fill(isSelected ? SpeechRailDesignTokens.Color.rail : Color.clear)
                                            .frame(width: SpeechRailDesignTokens.Teleprompter.stageCurrentRailWidth)
                                            .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)

                                        Text(String(format: "#%02d", index + 1))
                                            .font(SpeechRailDesignTokens.Typography.technicalValue)
                                            .foregroundStyle(
                                                isSelected
                                                    ? SpeechRailDesignTokens.Color.rail
                                                    : SpeechRailDesignTokens.Color.inkTertiary
                                            )
                                            .frame(width: 32, alignment: .leading)

                                        Text(segment.text)
                                            .font(SpeechRailDesignTokens.Typography.body)
                                            .fontWeight(isSelected ? .medium : .regular)
                                            .foregroundStyle(
                                                isSelected
                                                    ? SpeechRailDesignTokens.Color.ink
                                                    : SpeechRailDesignTokens.Color.inkSecondary
                                            )
                                            .lineSpacing(SpeechRailDesignTokens.Teleprompter.previewLineSpacing)
                                            .multilineTextAlignment(.leading)
                                            .frame(maxWidth: .infinity, alignment: .leading)

                                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                                            if segment.pauseHint == .medium || segment.pauseHint == .long {
                                                Text(segment.pauseHint == .long ? "长停顿" : "句间停顿")
                                                    .font(SpeechRailDesignTokens.Typography.caption)
                                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.micro)
                                                    .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)
                                                    .background(
                                                        SpeechRailDesignTokens.Color.inputField,
                                                        in: Capsule()
                                                    )
                                            }

                                            if isSelected {
                                                StatusPill(tone: .healthy, label: "起讲段")
                                            }
                                        }
                                    }
                                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                                    .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
                                    .background(
                                        isSelected
                                            ? SpeechRailDesignTokens.Color.rail.opacity(
                                                SpeechRailDesignTokens.Teleprompter.stageCurrentBackgroundOpacity
                                            )
                                            : Color.clear,
                                        in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                                    )
                                }
                                .buttonStyle(.plain)
                                .speechRailPointerCursor()
                                .id(segment.id)
                            }
                        }
                        .padding(SpeechRailDesignTokens.Spacing.sm)
                    }
                    .onAppear {
                        scrollToCurrentReadySegment(using: proxy)
                    }
                    .onChange(of: session.currentSegmentIndex) { _, _ in
                        scrollToCurrentReadySegment(using: proxy)
                    }
                    .onChange(of: session.activeVersion?.id) { _, _ in
                        scrollToCurrentReadySegment(using: proxy)
                    }
                }
                .frame(minHeight: SpeechRailDesignTokens.Teleprompter.sourceEditorMinimumHeight, maxHeight: .infinity)
                .background(SpeechRailDesignTokens.Color.recessedField)
            }
        }
    }

    private func scrollToCurrentReadySegment(using proxy: ScrollViewProxy) {
        guard let active = session.activeVersion,
              active.segments.indices.contains(session.currentSegmentIndex) else {
            return
        }
        proxy.scrollTo(active.segments[session.currentSegmentIndex].id, anchor: .center)
    }

    // MARK: - 3.5 运行中内容视图

    private var workbenchRunningContent: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            HStack {
                Text("提词舞台运行中")
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Text("— 稿件正文已锁定保护；悬浮舞台提词卡正在置顶跟读")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                Spacer()
                StatusPill(
                    tone: session.phase == .following ? .healthy : .attention,
                    label: phaseLabel(session.phase)
                )
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            .padding(.top, SpeechRailDesignTokens.Spacing.sm)

            SessionHairline()

            HStack(spacing: SpeechRailDesignTokens.Spacing.gutter) {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Text("当前进度")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    Text(session.progressText)
                        .font(SpeechRailDesignTokens.Typography.bodyMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                }

                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Text("已朗读时间")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    Text(formatClock(session.runClock.elapsedSeconds))
                        .font(SpeechRailDesignTokens.Typography.technicalValue)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                }

                if session.targetMinutes > 0 {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                        Text("预计剩余时间")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        Text(formatClock(session.runClock.estimatedRemainingSeconds))
                            .font(SpeechRailDesignTokens.Typography.technicalValue)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    }
                }

                Spacer()
            }
            .padding(SpeechRailDesignTokens.Spacing.md)

            Spacer()
        }
    }

    // MARK: - 4. 一体化操作底座与视效微调坞 (Integrated Bottom Dock)

    private var workbenchBottomDock: some View {
        VStack(spacing: 0) {
            SessionHairline()

            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                // 阻碍横幅已经提供对应的恢复操作，不再重复展示第二组按钮。
                if session.blocked == nil {
                    workbenchActionRow
                }

                // 行 2：视效微调坞
                workbenchStageSettingsStrip
            }
            .padding(.bottom, SpeechRailDesignTokens.Spacing.sm)
            .background(SpeechRailDesignTokens.Color.recessedField.opacity(0.35))
        }
    }

    private var workbenchActionRow: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            switch session.phase {
            case .draft:
                Button {
                    requestAIAnalysis()
                } label: {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Label("整理朗读稿", systemImage: "sparkles")
                        ButtonShortcutHint("⌘⏎")
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .speechRailButton(.primary)
                .disabled(
                    sourceIsEmpty
                        || session.sourceValidationError != nil
                        || !session.canEdit
                        || session.isPreparingDraft
                        || !isTargetMinutesValid
                )

                Button("直接使用原稿") {
                    do {
                        try session.useDeterministicFallback()
                        operationMessage = nil
                    } catch {
                        operationMessage = error.localizedDescription
                    }
                }
                .speechRailButton(.secondary)
                .disabled(sourceIsEmpty || session.sourceValidationError != nil || !session.canEdit)

            case .analyzing, .preparing:
                Button("取消整理") {
                    session.discardPendingVersion()
                }
                .speechRailButton(.secondary)

            case .prepared:
                Button {
                    do {
                        preparedTextSyncTask?.cancel()
                        session.updatePreparedDraftText(localPreparedText)
                        try session.acceptPendingVersion()
                        operationMessage = nil
                        reloadDocuments()
                        showStage()
                    } catch {
                        operationMessage = error.localizedDescription
                    }
                } label: {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Image(systemName: "play.rectangle.fill")
                        Text("打开提词器")
                        ButtonShortcutHint("⌘⏎")
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .speechRailButton(.primary)
                .disabled(!session.canAcceptPendingVersion)

                Button("重新整理", systemImage: "arrow.triangle.2.circlepath") {
                    startAIAnalysis()
                }
                .speechRailButton(.secondary)
                .disabled(session.isPreparingDraft)

                Button("恢复原稿") {
                    session.discardPendingVersion()
                }
                .speechRailButton(.secondary)

            case .ready, .ended:
                Button {
                    showStage()
                } label: {
                    SpeechRailButtonLabel("打开提词器", icon: .stage)
                }
                .speechRailButton(.primary)

                Button {
                    requestReadingCues()
                } label: {
                    SpeechRailButtonLabel("添加朗读提示", icon: .readingCues)
                }
                .speechRailButton(.secondary)
                .disabled(session.isAnnotating)

                Button("重新编辑原稿") {
                    session.discardPendingVersion()
                }
                .speechRailButton(.secondary)

            case .following, .paused, .uncertain, .manual:
                Button {
                    showStage()
                } label: {
                    SpeechRailButtonLabel("返回提词舞台", icon: .stage)
                }
                .speechRailButton(.primary)

                workbenchVoiceAssistControl
                speechLanguageMenu
            }

            Spacer()

            if session.phase == .ready || session.phase == .ended {
                Text("按回车或点主按钮进入悬浮舞台")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.top, SpeechRailDesignTokens.Spacing.sm)
    }

    private var workbenchStageSettingsStrip: some View {
        let titleGroup = HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Image(systemName: "macwindow")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.rail)
            Text("提词卡视效")
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
        }

        let divider = Divider()
            .frame(height: SpeechRailDesignTokens.Teleprompter.stageSettingsDividerHeight)

        let fontScaleGroup = HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Text("字号")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)

            Slider(
                value: Binding(get: { settings.fontScale }, set: { settings.fontScale = $0 }),
                in: SpeechRailDesignTokens.Teleprompter.stageMinimumFontScale...SpeechRailDesignTokens.Teleprompter.stageMaximumFontScale
            )
            .frame(width: SpeechRailDesignTokens.Teleprompter.stageFontSliderWidth)
            .accessibilityLabel("提词卡字号")
            .accessibilityValue("\(Int(settings.scriptPointSize)) 点")

            Text("\(Int(settings.scriptPointSize)) pt")
                .font(SpeechRailDesignTokens.Typography.technicalValue)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .frame(width: SpeechRailDesignTokens.Teleprompter.targetMinutesFieldWidth, alignment: .trailing)
        }

        let transparencyValue = TeleprompterStageTransparencyPresentation.valueLabel(
            for: settings.backgroundTransparency
        )
        let opacityGroup = HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Text("背景透明度")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)

            Slider(
                value: Binding(
                    get: { settings.backgroundTransparency },
                    set: { settings.backgroundTransparency = $0 }
                ),
                in: SpeechRailDesignTokens.Teleprompter.stageMinimumTransparency...SpeechRailDesignTokens.Teleprompter.stageMaximumTransparency
            )
            .frame(width: SpeechRailDesignTokens.Teleprompter.stageOpacitySliderWidth)
            .accessibilityLabel("提词卡背景透明度")
            .accessibilityValue(transparencyValue)
            .help("滑杆连续调节；百分比是控制值，材质观感会受桌面内容影响")

            Text(transparencyValue)
                .font(SpeechRailDesignTokens.Typography.technicalValue)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .frame(width: SpeechRailDesignTokens.Teleprompter.stageTransparencyValueWidth, alignment: .trailing)
        }

        let visibleLineCountStepper = Stepper(
            "显示 \(settings.visibleLineCount) 行",
            value: Binding(
                get: { settings.visibleLineCount },
                set: { settings.visibleLineCount = $0 }
            ),
            in: SpeechRailDesignTokens.Teleprompter.stageMinimumVisibleLineCount...SpeechRailDesignTokens.Teleprompter.stageMaximumVisibleLineCount
        )
        .font(SpeechRailDesignTokens.Typography.caption)

        let streamingTip = Image(systemName: "info.circle")
            .font(SpeechRailDesignTokens.Typography.caption)
            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            .help("OBS 或直播伴侣请选择摄像头或目标窗口采集，避免全屏采集提词器窗口。")
            .accessibilityLabel("直播采集建议")
            .accessibilityValue("OBS 或直播伴侣请选择摄像头或目标窗口采集，避免全屏采集提词器窗口。")

        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.md) {
                titleGroup
                divider
                fontScaleGroup
                opacityGroup
                visibleLineCountStepper

                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                streamingTip
            }

            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.md) {
                    titleGroup
                    divider
                    fontScaleGroup
                }

                HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.md) {
                    opacityGroup
                    visibleLineCountStepper
                    Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                    streamingTip
                }
            }

            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.md) {
                    titleGroup
                    fontScaleGroup
                }

                opacityGroup

                HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.md) {
                    visibleLineCountStepper
                    Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                    streamingTip
                }
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
    }

    private func phaseLabel(_ phase: TeleprompterSession.Phase) -> String {
        switch phase {
        case .draft: "草稿"
        case .analyzing: "正在整理…"
        case .prepared: "整理好了"
        case .ready: "可以开始"
        case .preparing: "正在连接…"
        case .following: "跟读中"
        case .paused: "已暂停"
        case .uncertain: "位置已保留"
        case .manual: "手动提词"
        case .ended: "已结束"
        }
    }

    @ViewBuilder
    private var workbenchVoiceAssistControl: some View {
        switch session.voiceAssistState {
        case .off:
            EmptyView()
        case .starting:
            Button("正在开启语音跟随…") {}
                .speechRailButton(.secondary)
                .disabled(true)
        case .following:
            Button {
                Task { await session.disableVoiceAssist() }
            } label: {
                SpeechRailButtonLabel("关闭语音跟随", icon: .stop)
            }
            .speechRailButton(.secondary)
        case .stopping:
            Button("正在停止语音跟随…") {}
                .speechRailButton(.secondary)
                .disabled(true)
        case .stopFailed:
            Button {
                Task { await session.retryStopVoiceAssist() }
            } label: {
                SpeechRailButtonLabel("重试停止语音跟随", icon: .refresh)
            }
            .speechRailButton(.secondary)
        case .pausedByUser:
            Button {
                Task { await session.enableVoiceAssist() }
            } label: {
                SpeechRailButtonLabel("恢复语音跟随", icon: .micFill)
            }
            .speechRailButton(.secondary)
        case .unavailable:
            Button {
                Task { await session.enableVoiceAssist() }
            } label: {
                SpeechRailButtonLabel("重试语音跟随", icon: .refresh)
            }
            .speechRailButton(.secondary)
        }
    }

    private func formatClock(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    // MARK: - 识别语言（进阶设置）

    /// `preferredSpeechLanguage` 只有在这里才会被写入生产路径。契约、连接配置
    /// 与降级都已就绪，但在此之前它没有任何写入者，真实连接恒用服务端默认。
    private var speechLanguageMenu: some View {
        Menu {
            Picker("识别语言", selection: Binding(
                get: { session.preferredSpeechLanguage ?? "" },
                set: { newValue in
                    session.preferredSpeechLanguage = newValue.isEmpty ? nil : newValue
                    UserDefaults.standard.set(
                        newValue,
                        forKey: TeleprompterRealtimeConfiguration.preferredSpeechLanguageDefaultsKey
                    )
                }
            )) {
                Text("自动（服务默认）").tag("")
                ForEach(TeleprompterRealtimeConfiguration.speechLanguageChoices) { choice in
                    Text(choice.label).tag(choice.code)
                }
            }
        } label: {
            Label(speechLanguageLabel, systemImage: "globe")
        }
        .speechRailButton(.secondary)
        .help("脚本语言与识别默认不一致时才需要改；自动会沿用服务端的默认语言。")
    }

    private var speechLanguageLabel: String {
        guard let code = session.preferredSpeechLanguage else { return "识别语言：自动" }
        let name = TeleprompterRealtimeConfiguration.label(forSpeechLanguage: code) ?? code
        return "识别语言：\(name)"
    }

    /// 恢复上次选择。存的是清洗后的值，非法值一律退回「自动」而不是带进连接。
    private func restorePreferredSpeechLanguage() {
        let stored = UserDefaults.standard.string(
            forKey: TeleprompterRealtimeConfiguration.preferredSpeechLanguageDefaultsKey
        )
        session.preferredSpeechLanguage = TeleprompterRealtimeConfiguration(
            language: stored,
            keywords: []
        ).sanitized.language
    }

    // MARK: - 剪贴板与数据辅助

    private var pasteboardSnippet: (text: String, count: Int)? {
        guard let string = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else {
            return nil
        }
        let tokenCount = TeleprompterNormalizer.tokens(string).count
        guard tokenCount > 0 else { return nil }
        return (text: string, count: string.count)
    }

    private func createFromClipboard() {
        if let snippet = pasteboardSnippet {
            do {
                try session.createDocumentValidated(title: "剪贴板稿件", sourceText: snippet.text)
                operationMessage = nil
                reloadDocuments()
            } catch {
                operationMessage = "导入失败：\(error.localizedDescription)"
            }
        } else {
            operationMessage = "剪贴板中未检测到文本内容"
        }
    }

    private var sourceIsEmpty: Bool {
        TeleprompterNormalizer.tokens(session.document?.sourceText ?? "").isEmpty
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { session.document?.title ?? "" },
            set: { session.updateTitle($0) }
        )
    }

    private var sourceBinding: Binding<String> {
        Binding(
            get: { session.document?.sourceText ?? "" },
            set: { session.updateSourceText($0) }
        )
    }

    private func reloadDocuments() {
        do {
            documents = try session.listDocuments()
        } catch {
            documents = []
            operationMessage = error.localizedDescription
            return
        }
        // 自动打开第一份稿件失败时，列表本身仍然有用——不能把两者混在同一个
        // `catch` 里连列表一起清空，那会让读者看到一份空工作台且没有任何说明。
        if session.document == nil, let first = documents.first {
            do {
                try session.load(documentID: first.id)
            } catch {
                operationMessage = error.localizedDescription
            }
        }
    }

    private func showStage() {
        stage.show()
        if let message = stage.lastPresentationError {
            operationMessage = message
            return
        }
        operationMessage = nil
    }

    private func requestAIAnalysis() {
        pendingAIAction = .prepare
        guard UserDefaults.standard.bool(forKey: aiDataFlowAcknowledgementKey) else {
            isAIDataFlowDisclosurePresented = true
            return
        }
        startAIAnalysis()
    }

    private var aiDataFlowAcknowledgementKey: String {
        TeleprompterAIDataFlowDisclosure.acknowledgementDefaultsKey(
            for: preferences.llmConfiguration(for: .teleprompter)
        )
    }

    private func startAIAnalysis() {
        Task {
            await session.analyzeDraft()
        }
    }

    private func requestReadingCues() {
        pendingAIAction = .annotate
        guard UserDefaults.standard.bool(forKey: aiDataFlowAcknowledgementKey) else {
            isAIDataFlowDisclosurePresented = true
            return
        }
        startAnnotation()
    }

    private func startAnnotation() {
        Task {
            if let message = await session.annotateActiveVersion() {
                operationMessage = message
            } else {
                operationMessage = "已添加朗读提示；正文保持不变。"
            }
        }
    }

    // MARK: - 导出、拖拽与朗读提示辅助

    private func copyDocumentContent() {
        guard let text = session.copyableDocumentText() else {
            operationMessage = "还没有可复制的稿件内容。"
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        operationMessage = "已复制稿件内容"
    }

    private func exportSourceDocument() {
        guard let doc = session.document else { return }
        exportDataDocument(
            title: "导出原稿",
            defaultFilename: "\(doc.title)-原稿.md",
            data: session.exportSourceData() ?? Data(doc.sourceText.utf8)
        )
    }

    private func exportReadingDocument() {
        guard let doc = session.document else { return }
        let readingText: String
        if let active = session.activeVersion {
            readingText = active.segments.map(\.text).joined(separator: "\n\n")
        } else if !session.readingBlocks.isEmpty {
            readingText = session.readingBlocks
                .filter { $0.disposition == .speak }
                .map(\.text)
                .joined(separator: "\n\n")
        } else {
            readingText = session.exportMarkdown() ?? doc.sourceText
        }
        exportDocument(
            title: "导出朗读稿",
            defaultFilename: "\(doc.title)-朗读稿.md",
            content: readingText
        )
    }

    private func exportDocument(title: String, defaultFilename: String, content: String) {
        exportDataDocument(
            title: title,
            defaultFilename: defaultFilename,
            data: Data(content.utf8)
        )
    }

    private func exportDataDocument(title: String, defaultFilename: String, data: Data) {
        let savePanel = NSSavePanel()
        savePanel.title = title
        savePanel.nameFieldStringValue = defaultFilename
        let mdType = UTType(filenameExtension: "md") ?? .plainText
        savePanel.allowedContentTypes = [mdType, .plainText, .utf8PlainText]
        savePanel.canCreateDirectories = true
        if savePanel.runModal() == .OK, let url = savePanel.url {
            do {
                try data.write(to: url, options: .atomic)
                operationMessage = "已导出到「\(url.lastPathComponent)」"
            } catch {
                operationMessage = "导出失败：\(error.localizedDescription)"
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    importFromURL(url)
                }
            }
            return true
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            _ = provider.loadObject(ofClass: String.self) { string, _ in
                guard let string else { return }
                DispatchQueue.main.async {
                    do {
                        try session.createDocumentValidated(title: "拖拽导入稿件", sourceText: string)
                        operationMessage = "已从拖拽文本创建新稿件"
                        reloadDocuments()
                    } catch {
                        operationMessage = "导入失败：\(error.localizedDescription)"
                    }
                }
            }
            return true
        }
        return false
    }

    private func importFromURL(_ url: URL) {
        do {
            let imported = try TeleprompterSourceImporter.load(from: url)
            try session.createDocument(
                title: url.deletingPathExtension().lastPathComponent,
                importedSource: imported
            )
            operationMessage = "已导入「\(url.lastPathComponent)」"
            reloadDocuments()
        } catch {
            operationMessage = "导入失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 开箱即用场景范例数据

private struct TeleprompterStarterTemplate: Identifiable {
    let id: String
    let icon: String
    let tag: String
    let title: String
    let subtitle: String
    let content: String
}

private let starterTemplates: [TeleprompterStarterTemplate] = [
    TeleprompterStarterTemplate(
        id: "short-video-hook",
        icon: "video.fill",
        tag: "短视频口播",
        title: "黄金 3 秒开场",
        subtitle: "迅速抓住眼球的爆款公式",
        content: """
        很多人问我：为什么同样的内容，别人讲完点赞过万，自己讲完观众两秒就划走？

        其实秘密不在于你的内容有多深奥，而在于开头的黄金三秒！

        今天我就把这个经过实战验证的「冲突 + 悬念」开场公式分享给你。赶紧点赞收藏，免得刷着刷着就找不到了。

        第一步：开门见山抛出痛点，不要说任何废话；
        第二步：制造认知冲突，打破常规预期；
        第三步：给出确定性承诺，引导持续观看。

        按照这个节奏走，你的完播率一定会大幅提升！
        """
    ),
    TeleprompterStarterTemplate(
        id: "live-commerce",
        icon: "cart.fill",
        tag: "直播带货",
        title: "爆品好物推介",
        subtitle: "高转化互动与痛点直击",
        content: """
        欢迎新进直播间的所有朋友们！大家晚上好！

        今天给大家带来的这款产品，是我们团队自用内测了整整三个月、回购率最高的一款。

        平时在专柜大家看过的都知道，今天在我们的直播间，不仅价格直接打到地板价，还额外加赠两份正装体验装！

        废话不多说，库存真的非常有限，左下角一号链接，我数三二一，准备开抢！

        三、二、一，直接上链接！抢到的朋友在公屏扣一个「已拍」，我们马上安排顺丰优先发出！
        """
    ),
    TeleprompterStarterTemplate(
        id: "knowledge-sharing",
        icon: "lightbulb.fill",
        tag: "知识科普",
        title: "认知机制拆解",
        subtitle: "深度内容引人入胜的叙事",
        content: """
        你可能不知道，我们的大脑每天要做超过三万次决定。

        但为什么面对同样的选择，我们有时候能瞬间决断，有时候却会陷入严重的决策疲劳？

        这背后的神经认知机制，其实源于我们大脑内部的两套不同运转系统。

        第一套系统是直觉型的快思考，耗能极低，负责日常应激；
        第二套系统是理性的慢思考，虽然精密，但极其消耗能量。

        理解了这一点，你就能掌握一套科学管理精力、避免拖延的核心策略。接下来我们分三个维度详细拆解。
        """
    )
]
