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
    @State private var isAIReviewExpanded = true
    @State private var operationMessage: String?
    @State private var documentToDelete: TeleprompterDocument?
    @State private var isDeleteAlertPresented = false
    @State private var unavailableDocumentToDelete: TeleprompterV2DocumentListItem?
    @State private var isUnavailableDeleteAlertPresented = false
    @State private var searchQuery = ""

    // 终版规格 Sheet 状态
    @State private var isTrialReadingPresented = false
    @State private var isContentSelectionPresented = false
    @State private var isComparingWithSource = false
    @State private var targetMinutesInput = "20"
    @State private var selectedReviewItemIDs: Set<String> = []
    @State private var editingReviewItemID: String? = nil
    @State private var editingReviewItemText: String = ""
    @State private var narrowComparisonTab: ComparisonTab = .reading
    @State private var pendingAIAction: AIPendingAction = .prepare

    private enum AIPendingAction {
        case prepare
        case annotate
    }

    private enum ComparisonTab: String, CaseIterable, Identifiable {
        case source = "原稿"
        case reading = "口语朗读稿"
        var id: String { rawValue }
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
            minimumContentHeight: SpeechRailDesignTokens.Teleprompter.preparationMinimumHeight,
            growsWithContent: true
        ) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.gutter) {
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
            if let suggested = session.suggestedTargetMinutes {
                targetMinutesInput = "\(suggested)"
                session.setTargetMinutes(suggested)
            } else {
                targetMinutesInput = "\(session.targetMinutes)"
            }
        }
        .onChange(of: session.pendingVersion?.id) { _, pendingID in
            if pendingID != nil {
                isAIReviewExpanded = true
            }
        }
        .sheet(isPresented: $isTrialReadingPresented) {
            TeleprompterTrialReadingSheet(session: session)
        }
        .sheet(isPresented: $isContentSelectionPresented) {
            TeleprompterContentSelectionSheet(session: session)
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

    // MARK: - 头部工具栏动作

    @ViewBuilder
    private var headerActions: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            if documents.isEmpty {
                PageActionButton(
                    title: "导入文件…",
                    systemImage: "arrow.down.doc",
                    helpText: "导入 TXT 或 Markdown 文本文件"
                ) {
                    isImporterPresented = true
                }
            } else {
                PageActionsMenu(
                    title: "新建",
                    systemImage: "plus",
                    helpText: "创建新的提词稿件"
                ) {
                    Button("新建空白稿") {
                        session.createDocument(title: "未命名稿子", sourceText: "")
                    }
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
                        systemImage: "square.and.arrow.up",
                        helpText: "导出原稿或朗读稿"
                    ) {
                        Button("导出原稿 (Markdown)…", systemImage: "doc.text") {
                            exportSourceDocument()
                        }
                        Button("导出朗读稿 (Markdown)…", systemImage: "text.bubble") {
                            exportReadingDocument()
                        }
                        Divider()
                        Button("复制稿件内容", systemImage: "doc.on.doc") {
                            copyDocumentContent()
                        }
                    }
                }

                if session.isCapturing {
                    PageActionButton(
                        title: "停止跟读",
                        systemImage: "stop.fill",
                        helpText: "停止当前跟读并释放麦克风"
                    ) {
                        Task { await session.endFollowing() }
                    }
                } else if session.document != nil {
                    PageActionButton(
                        title: "打开舞台",
                        systemImage: "macwindow",
                        helpText: "打开独立悬浮提词窗口"
                    ) {
                        prepareStage()
                        stage.show()
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
                        .frame(width: 56, height: 56)
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
                        .frame(maxWidth: 560)
                }

                HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    Button {
                        session.createDocument(title: "未命名稿子", sourceText: "")
                    } label: {
                        Label("新建空白稿", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.extraLarge)

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
            .padding(.vertical, SpeechRailDesignTokens.Spacing.lg)

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

                HStack(spacing: SpeechRailDesignTokens.Spacing.md) {
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

                HStack(spacing: SpeechRailDesignTokens.Spacing.md) {
                    workflowStepCard(
                        step: "1",
                        icon: "square.and.pencil",
                        title: "编排与预检",
                        detail: "设置目标时长与朗读节奏，实时预检篇幅是否合理，原稿永远不会被覆盖。"
                    )
                    workflowStepCard(
                        step: "2",
                        icon: "sparkles",
                        title: "口语化与审阅",
                        detail: "保真口语化整理，查看原文对照并处理待确认事项，一键采用或精简。"
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
                    .frame(width: 28, height: 28)
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
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.gutter) {
            recentDocuments
                .frame(width: SpeechRailDesignTokens.Layout.sessionListWidth)
                .disabled(!session.canEdit || session.isPreparingDraft)
            editor
        }
    }

    private var recentDocuments: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                CardHead(title: "我的稿子", detail: "\(documents.count) 篇稿件与跟读版本") {
                    Menu {
                        Button("新建空白稿") {
                            session.createDocument(title: "未命名稿子", sourceText: "")
                        }
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
                                .font(.system(size: 11))
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                .padding(.vertical, 6)
                .background(
                    SpeechRailDesignTokens.Color.inputField,
                    in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                        .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
                }
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                .padding(.bottom, SpeechRailDesignTokens.Spacing.xs)

                SessionHairline()

                if filteredDocuments.isEmpty {
                    VStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Spacer()
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 24))
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
                    .frame(maxWidth: .infinity, minHeight: 180)
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
                                        Button("创建副本", systemImage: "plus.square.on.square") {
                                            do {
                                                _ = try session.duplicateDocument(documentID: document.id)
                                                reloadDocuments()
                                            } catch {
                                                operationMessage = error.localizedDescription
                                            }
                                        }
                                        Button("复制稿件内容", systemImage: "doc.on.doc") {
                                            if let markdown = session.exportMarkdown() {
                                                NSPasteboard.general.clearContents()
                                                NSPasteboard.general.setString(markdown, forType: .string)
                                                operationMessage = "已复制稿件内容"
                                            }
                                        }
                                        Divider()
                                        Button("删除…", systemImage: "trash", role: .destructive) {
                                            documentToDelete = document
                                            isDeleteAlertPresented = true
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis")
                                            .font(SpeechRailDesignTokens.Typography.caption)
                                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                                            .frame(width: 18, height: 18)
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
                }
            }
        }
    }

    private var filteredDocuments: [TeleprompterDocument] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return documents }
        return documents.filter { doc in
            doc.title.localizedCaseInsensitiveContains(trimmed) ||
            doc.sourceText.localizedCaseInsensitiveContains(trimmed)
        }
    }

    // MARK: - 主编辑区与状态机

    @ViewBuilder
    private var editor: some View {
        if session.document == nil {
            SessionEmptyState(
                systemImage: "doc.text",
                title: "选择或新建一份稿件",
                message: "从左侧列表选择一份已有稿件，或点击「新建」开始编排。"
            ) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Button("新建空白稿") {
                        session.createDocument(title: "未命名稿子", sourceText: "")
                    }
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
        } else {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.gutter) {
                workspaceHeaderCard
                preparationControlBar

                if let blocked = session.blocked {
                    blockedNoticeCard(blocked)
                }

                // 根据会话状态渲染核心工作区
                switch session.phase {
                case .draft:
                    draftWorkspace
                case .analyzing, .preparing:
                    analyzingWorkspace
                case .review:
                    reviewWorkspace
                case .ready:
                    readyWorkspace
                case .following, .paused, .uncertain, .manual:
                    runningWorkspace
                case .ended:
                    readyWorkspace
                }

                stageSettings
            }
        }
    }

    // MARK: - 稿件信息头部

    private var workspaceHeaderCard: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                CardHead(
                    title: session.phase == .review ? "审阅朗读稿" : "稿件编排",
                    detail: session.phase == .review ? "对比原文核对改动，处理待确认事项后采用" : "原稿内容永远不会被 AI 直接修改或截断"
                ) {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Text("\(sourceBinding.wrappedValue.count) 字")
                            .font(SpeechRailDesignTokens.Typography.technicalValue)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)

                        if case .storeUnavailable = session.blocked {
                            StatusPill(tone: .attention, label: "尚未保存")
                        } else if session.activeVersion != nil {
                            StatusPill(tone: .neutral, label: "已确认版本")
                        }

                        Menu {
                            Button("导出原稿 (Markdown)…", systemImage: "doc.text") {
                                exportSourceDocument()
                            }
                            Button("导出朗读稿 (Markdown)…", systemImage: "text.bubble") {
                                exportReadingDocument()
                            }
                            Divider()
                            Button("创建副本", systemImage: "plus.square.on.square") {
                                if let doc = session.document {
                                    do {
                                        _ = try session.duplicateDocument(documentID: doc.id)
                                        reloadDocuments()
                                    } catch {
                                        operationMessage = error.localizedDescription
                                    }
                                }
                            }
                            Button("复制稿件内容", systemImage: "doc.on.doc") {
                                copyDocumentContent()
                            }
                            Divider()
                            Button("删除这份稿子…", systemImage: "trash", role: .destructive) {
                                if let doc = session.document {
                                    documentToDelete = doc
                                    isDeleteAlertPresented = true
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(SpeechRailDesignTokens.Typography.body)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        }
                        .menuStyle(.borderlessButton)
                    }
                }

                SessionHairline()

                TextField("稿子名称", text: titleBinding)
                    .disabled(!session.canEdit || session.isPreparingDraft)
                    .textFieldStyle(.plain)
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .speechRailRecessedSlot()
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
        .disabled(session.isPreparingDraft)
    }

    // MARK: - 目标时长、节奏与预检控制条

    private var preparationControlBar: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.gutter) {
                    // 目标时长输入与快捷菜单
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Text("目标时长")
                            .font(SpeechRailDesignTokens.Typography.captionMedium)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)

                        HStack(spacing: 2) {
                            TextField("例如 20", text: $targetMinutesInput)
                                .textFieldStyle(.plain)
                                .font(SpeechRailDesignTokens.Typography.technicalValue)
                                .frame(width: 44)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: targetMinutesInput) { _, newValue in
                                    if let mins = Int(newValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                        session.setTargetMinutes(mins)
                                    }
                                }

                            Text("分钟")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        }
                        .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                        .padding(.vertical, 4)
                        .background(
                            SpeechRailDesignTokens.Color.inputField,
                            in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                                .stroke(
                                    !isTargetMinutesValid && !targetMinutesInput.isEmpty
                                        ? SpeechRailDesignTokens.Color.attention
                                        : SpeechRailDesignTokens.Surface.border,
                                    lineWidth: SpeechRailDesignTokens.Stroke.hairline
                                )
                        )

                        Menu {
                            ForEach(TeleprompterTimingPolicy.quickTargets, id: \.self) { mins in
                                Button("\(mins) 分钟") {
                                    targetMinutesInput = "\(mins)"
                                    session.setTargetMinutes(mins)
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10))
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        }
                        .menuStyle(.borderlessButton)

                        if !isTargetMinutesValid && !targetMinutesInput.isEmpty {
                            Text("需 1–120 整数分钟")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                        }
                    }

                    // 朗读节奏选择器
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Text("节奏")
                            .font(SpeechRailDesignTokens.Typography.captionMedium)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)

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

                        if session.calibrationFactor != 1.0 {
                            Menu {
                                Button("重新计时试读…", systemImage: "stopwatch") {
                                    isTrialReadingPresented = true
                                }
                                Divider()
                                Button("恢复默认语速 (1.0x)", systemImage: "arrow.counterclockwise") {
                                    session.applyTrialCalibration(k: 1.0)
                                    operationMessage = "已恢复为默认自然语速 (1.0x)"
                                }
                            } label: {
                                HStack(spacing: 2) {
                                    StatusPill(
                                        tone: .healthy,
                                        label: "已校准 \(String(format: "%.2fx", session.calibrationFactor))"
                                    )
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 8))
                                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                                }
                            }
                            .menuStyle(.borderlessButton)
                        }
                    }

                    Spacer()

                    // 工具入口：选择范围与计时试读
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Button {
                            isContentSelectionPresented = true
                        } label: {
                            Label(
                                session.contentSelection.hasExclusions
                                    ? "已选 \(session.contentSelection.selectedCount) 段"
                                    : "选择内容范围",
                                systemImage: "checklist"
                            )
                        }
                        .speechRailButton(.secondary)

                        Button {
                            isTrialReadingPresented = true
                        } label: {
                            Label("计时试读", systemImage: "stopwatch")
                        }
                        .speechRailButton(.secondary)
                    }
                }

                SessionHairline()

                // 可行性预检反馈行
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    let preflight = session.preflightConclusion
                    StatusPill(
                        tone: preflightTone(preflight),
                        label: preflight.badgeTitle
                    )

                    Text(preflight.userGuidance)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .lineLimit(2)

                    Spacer()

                    Text("包含自然停顿，不含问答演示")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
        .disabled(session.isPreparingDraft)
    }

    private func preflightTone(_ conclusion: TeleprompterTimingPolicy.PreflightConclusion) -> StatusTone {
        switch conclusion {
        case .emptyText, .uncertain: .neutral
        case .matching: .healthy
        case .underfilled, .slightlyOver: .neutral
        case .tight, .invalidTarget: .attention
        }
    }

    // MARK: - 1. 草稿状态工作区

    private var draftWorkspace: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                CardHead(title: "原稿正文", detail: "可直接输入、粘贴或从左侧导入 Markdown / 纯文本") {
                    if session.contentSelection.hasExclusions {
                        StatusPill(tone: .attention, label: "已排除部分段落")
                    }
                }

                SessionHairline()

                TextEditor(text: sourceBinding)
                    .disabled(!session.canEdit)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .scrollContentBackground(.hidden)
                    .frame(
                        minHeight: SpeechRailDesignTokens.Teleprompter.sourceEditorMinimumHeight,
                        idealHeight: SpeechRailDesignTokens.Teleprompter.sourceEditorIdealHeight,
                        maxHeight: SpeechRailDesignTokens.Teleprompter.sourceEditorMaximumHeight
                    )
                .accessibilityLabel("原稿正文")
                    .speechRailRecessedSlot()

                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    if let sourceValidationError = session.sourceValidationError {
                        Label(sourceValidationError.localizedDescription, systemImage: "exclamationmark.triangle")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                            .lineLimit(2)
                    }

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

                    Spacer()
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    // MARK: - 2. 正在整理中工作区

    private var analyzingWorkspace: some View {
        CardSurface {
            VStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.gutter) {
                if let progress = session.preparationProgress, progress.total > 0 {
                    ProgressView(
                        value: Double(progress.completed),
                        total: Double(progress.total)
                    )
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 360)
                    .padding(.top, SpeechRailDesignTokens.Spacing.md)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .padding(.top, SpeechRailDesignTokens.Spacing.md)
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

                Button("取消整理") {
                    session.discardPendingVersion()
                }
                .speechRailButton(.secondary)
                .padding(.bottom, SpeechRailDesignTokens.Spacing.md)
            }
            .frame(maxWidth: .infinity)
            .padding(SpeechRailDesignTokens.Spacing.lg)
        }
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

    // MARK: - 3. 审阅候选稿工作区

    private var reviewWorkspace: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.gutter) {
            if session.hasUncheckedPreparationBoundaries {
                CardSurface {
                    Label {
                        Text("朗读稿已整理，但部分相邻段落未完成衔接检查；仍可采用，请在原文对照中重点核对这些接缝。")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                    }
                    .padding(SpeechRailDesignTokens.Spacing.md)
                }
            }

            // 待确认事项总览与操作门禁
            if session.unresolvedReviewItemCount > 0 {
                CardSurface {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                            Text("待确认事项（还有 \(session.unresolvedReviewItemCount) 项需要决策）")
                                .font(SpeechRailDesignTokens.Typography.bodyMedium)
                                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                            Spacer()
                        }

                        Text("AI 提出了关于指代、读法或略读的建议。请在下方逐项裁决后，方可采用此稿进行跟读。")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

                        // 批量操作工具条
                        let unresolved = session.reviewItems.filter { !$0.isResolved }
                        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                            Button(selectedReviewItemIDs.count == unresolved.count && !unresolved.isEmpty ? "取消全选" : "全选") {
                                if selectedReviewItemIDs.count == unresolved.count {
                                    selectedReviewItemIDs.removeAll()
                                } else {
                                    selectedReviewItemIDs = Set(unresolved.map(\.id))
                                }
                            }
                            .buttonStyle(.plain)
                            .font(SpeechRailDesignTokens.Typography.captionMedium)
                            .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                            .disabled(unresolved.isEmpty)

                            if !selectedReviewItemIDs.isEmpty {
                                Text("已选 \(selectedReviewItemIDs.count) 项")
                                    .font(SpeechRailDesignTokens.Typography.caption)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

                                Spacer()

                                Button("批量采用建议") {
                                    for id in selectedReviewItemIDs {
                                        session.resolveReviewItem(id: id, action: .accept)
                                    }
                                    selectedReviewItemIDs.removeAll()
                                }
                                .speechRailButton(.primary)

                                Button("批量保留原文") {
                                    for id in selectedReviewItemIDs {
                                        session.resolveReviewItem(id: id, action: .keepSource)
                                    }
                                    selectedReviewItemIDs.removeAll()
                                }
                                .speechRailButton(.secondary)

                                Button("批量跳过") {
                                    for id in selectedReviewItemIDs {
                                        session.resolveReviewItem(id: id, action: .skip)
                                    }
                                    selectedReviewItemIDs.removeAll()
                                }
                                .speechRailButton(.secondary)
                            } else {
                                Spacer()
                            }
                        }
                        .padding(.vertical, 2)

                        ForEach(unresolved) { item in
                            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                                HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
                                    Toggle(isOn: Binding(
                                        get: { selectedReviewItemIDs.contains(item.id) },
                                        set: { if $0 { selectedReviewItemIDs.insert(item.id) } else { selectedReviewItemIDs.remove(item.id) } }
                                    )) {
                                        EmptyView()
                                    }
                                    .toggleStyle(.checkbox)
                                    .padding(.top, 2)

                                    StatusPill(tone: .attention, label: item.issue.title)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.issue.detail)
                                            .font(SpeechRailDesignTokens.Typography.caption)
                                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                        if !item.suggestedText.isEmpty {
                                            Text("建议：\(item.suggestedText)")
                                                .font(SpeechRailDesignTokens.Typography.captionMedium)
                                                .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                                        }
                                    }

                                    Spacer()

                                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                                        Button("采用建议") {
                                            session.resolveReviewItem(id: item.id, action: .accept)
                                        }
                                        .speechRailButton(.primary)

                                        Button("修改") {
                                            if editingReviewItemID == item.id {
                                                editingReviewItemID = nil
                                            } else {
                                                editingReviewItemID = item.id
                                                editingReviewItemText = item.suggestedText.isEmpty
                                                    ? (session.readingBlocks.first(where: { $0.id == item.blockID })?.rawSourceText ?? "")
                                                    : item.suggestedText
                                            }
                                        }
                                        .speechRailButton(.secondary)

                                        Button("保留原文") {
                                            session.resolveReviewItem(id: item.id, action: .keepSource)
                                        }
                                        .speechRailButton(.secondary)

                                        Button("仅作提示") {
                                            session.resolveReviewItem(id: item.id, action: .convertToCue)
                                        }
                                        .speechRailButton(.secondary)

                                        Button("跳过") {
                                            session.resolveReviewItem(id: item.id, action: .skip)
                                        }
                                        .speechRailButton(.secondary)
                                    }
                                }

                                if editingReviewItemID == item.id {
                                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                                        TextField("修改后的朗读正文", text: $editingReviewItemText)
                                            .textFieldStyle(.plain)
                                            .font(SpeechRailDesignTokens.Typography.body)
                                            .speechRailRecessedSlot()

                                        Button("保存并确认") {
                                            session.resolveReviewItem(id: item.id, action: .edit, customText: editingReviewItemText)
                                            editingReviewItemID = nil
                                        }
                                        .speechRailButton(.primary)

                                        Button("取消") {
                                            editingReviewItemID = nil
                                        }
                                        .speechRailButton(.secondary)
                                    }
                                    .padding(.top, SpeechRailDesignTokens.Spacing.micro)
                                }
                            }
                            .padding(SpeechRailDesignTokens.Spacing.xs)
                            .background(
                                SpeechRailDesignTokens.Color.recessedField,
                                in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                            )
                        }
                    }
                    .padding(SpeechRailDesignTokens.Spacing.md)
                }
            }

            // 朗读稿分段与原文对照
            CardSurface {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                    HStack {
                        Text("朗读稿来源组 (\(session.readingBlocks.count) 组)")
                            .font(SpeechRailDesignTokens.Typography.sectionTitle)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)

                        Spacer()

                        Toggle(isOn: $isComparingWithSource) {
                            Text("查看原文对照")
                                .font(SpeechRailDesignTokens.Typography.captionMedium)
                        }
                        .toggleStyle(.switch)
                    }

                    SessionHairline()

                    ScrollView {
                        VStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                            ForEach(session.readingBlocks) { block in
                                let blockNumber = block.ordinal + 1
                                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                                    HStack {
                                        Text("第 \(blockNumber) 组")
                                            .font(SpeechRailDesignTokens.Typography.captionMedium)
                                            .foregroundStyle(SpeechRailDesignTokens.Color.rail)

                                        if block.disposition != .speak {
                                            StatusPill(tone: .neutral, label: block.disposition == .cue ? "仅作提示" : "已跳过")
                                        }

                                        if block.text != block.rawSourceText && !block.rawSourceText.isEmpty {
                                            StatusPill(tone: .neutral, label: "已口语化")
                                        }

                                        Spacer()

                                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                                            Button("新增段") {
                                                session.insertBlock(after: block.ordinal)
                                            }
                                            .speechRailButton(.secondary)

                                            Button("拆分") {
                                                session.splitBlock(at: block.ordinal)
                                            }
                                            .speechRailButton(.secondary)

                                            Button("合并下一组") {
                                                session.mergeBlock(at: block.ordinal)
                                            }
                                            .speechRailButton(.secondary)
                                            .disabled(block.ordinal + 1 >= session.readingBlocks.count)
                                        }
                                    }

                                    if isComparingWithSource && !block.rawSourceText.isEmpty {
                                        ViewThatFits(in: .horizontal) {
                                            // 宽屏：双栏并排
                                            HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
                                                sourceDiffColumn(block)
                                                    .frame(minWidth: SpeechRailDesignTokens.Teleprompter.diffColumnMinimumWidth)
                                                readingDiffColumn(block)
                                                    .frame(minWidth: SpeechRailDesignTokens.Teleprompter.diffColumnMinimumWidth)
                                            }

                                            // 窄屏：Tab 切换
                                            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                                                Picker("对比视图", selection: $narrowComparisonTab) {
                                                    ForEach(ComparisonTab.allCases) { tab in
                                                        Text(tab.rawValue).tag(tab)
                                                    }
                                                }
                                                .pickerStyle(.segmented)
                                                .frame(width: 180)

                                                if narrowComparisonTab == .source {
                                                    sourceDiffColumn(block)
                                                } else {
                                                    readingDiffColumn(block)
                                                }
                                            }
                                        }
                                    } else {
                                        readingBlockEditor(block)
                                    }
                                }
                                .padding(SpeechRailDesignTokens.Spacing.sm)
                                .background(
                                    SpeechRailDesignTokens.Color.field,
                                    in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                                        .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 320)

                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Button("使用此稿") {
                            do {
                                try session.acceptPendingVersion()
                                operationMessage = nil
                                reloadDocuments()
                            } catch {
                                operationMessage = error.localizedDescription
                            }
                        }
                        .speechRailButton(.primary)
                        .disabled(!session.canAcceptPendingVersion)

                        Button(session.isTightening ? "正在精简…" : "再精简表达") {
                            Task {
                                if let msg = await session.tightenReadingBlocks() {
                                    operationMessage = msg
                                } else {
                                    operationMessage = "已对符合条件的 AI 段落完成精简表达。"
                                }
                            }
                        }
                        .speechRailButton(.secondary)
                        .disabled(!session.canTighten || session.isTightening)

                        Button("计时试读", systemImage: "stopwatch") {
                            isTrialReadingPresented = true
                        }
                        .speechRailButton(.secondary)

                        Button("放弃修改") {
                            session.discardPendingVersion()
                        }
                        .speechRailButton(.secondary)

                        Spacer()

                        if session.unresolvedReviewItemCount > 0 {
                            Text("需处理全部待确认项后方可采用（还有 \(session.unresolvedReviewItemCount) 项）")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                        }
                    }
                }
                .padding(SpeechRailDesignTokens.Spacing.md)
            }
        }
    }

    private func sourceDiffColumn(_ block: TeleprompterReadingBlock) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("原稿")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            Text(block.rawSourceText)
                .font(SpeechRailDesignTokens.Typography.body)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .padding(SpeechRailDesignTokens.Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    SpeechRailDesignTokens.Color.recessedField,
                    in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func readingDiffColumn(_ block: TeleprompterReadingBlock) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("口语朗读稿")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.rail)
            TextField(
                "朗读正文",
                text: Binding(
                    get: { block.text },
                    set: { session.updateBlockText(id: block.id, text: $0) }
                )
            )
            .textFieldStyle(.plain)
            .font(SpeechRailDesignTokens.Typography.body)
            .speechRailRecessedSlot()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func readingBlockEditor(_ block: TeleprompterReadingBlock) -> some View {
        TextField(
            "朗读正文",
            text: Binding(
                get: { block.text },
                set: { session.updateBlockText(id: block.id, text: $0) }
            )
        )
        .textFieldStyle(.plain)
        .font(SpeechRailDesignTokens.Typography.body)
        .speechRailRecessedSlot()
    }

    private func blockedNoticeCard(_ blocked: TeleprompterSession.BlockReason) -> some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                    Text(blocked.title)
                        .font(SpeechRailDesignTokens.Typography.bodyMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    Spacer()
                    StatusPill(tone: .attention, label: "功能受阻")
                }

                Text(blocked.detail)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

                Text("原稿、编辑进度与已有活动版本均已完整保留。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)

                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    switch blocked {
                    case .microphoneDenied:
                        Button("打开系统设置…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .speechRailButton(.primary)

                        Button("只打开提词窗口 (手动看稿)") {
                            prepareStage()
                            stage.show()
                        }
                        .speechRailButton(.secondary)

                    case .serviceNotReady, .serviceBusy, .streamFailed:
                        Button("重试跟读") {
                            beginReading()
                        }
                        .speechRailButton(.primary)

                        Button("只打开提词窗口 (手动看稿)") {
                            prepareStage()
                            stage.show()
                        }
                        .speechRailButton(.secondary)

                    case .aiUnavailable:
                        Button("重试整理") {
                            requestAIAnalysis()
                        }
                        .speechRailButton(.primary)

                        Button("直接使用原稿") {
                            try? session.useDeterministicFallback()
                        }
                        .speechRailButton(.secondary)

                    case .noActiveVersion:
                        Button("直接使用原稿") {
                            try? session.useDeterministicFallback()
                        }
                        .speechRailButton(.primary)

                    case .occupiedBy:
                        Button("只打开提词窗口 (手动看稿)") {
                            prepareStage()
                            stage.show()
                        }
                        .speechRailButton(.secondary)

                    case .storeUnavailable:
                        Button("重试保存") {
                            try? session.save()
                        }
                        .speechRailButton(.primary)
                    }
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    // MARK: - 4. 已就绪工作区

    private var readyWorkspace: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                CardHead(title: "提词稿已就绪", detail: "已生成并确认最终跟读版本，随时可在悬浮舞台中开讲") {
                    StatusPill(tone: .healthy, label: "已准备完毕")
                }

                SessionHairline()

                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    if let active = session.activeVersion {
                        Text("共 \(active.segments.count) 段 · 预计时长约 \(session.targetMinutes) 分钟")
                            .font(SpeechRailDesignTokens.Typography.bodyMedium)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)

                        ScrollView {
                            Text(active.sourceText)
                                .font(SpeechRailDesignTokens.Typography.body)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                .lineSpacing(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(SpeechRailDesignTokens.Spacing.sm)
                        }
                        .frame(maxHeight: 180)
                        .background(
                            SpeechRailDesignTokens.Color.recessedField,
                            in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                        )
                    }
                }

                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Button("打开舞台并开始跟读", systemImage: "play.fill") {
                        beginReading()
                    }
                    .speechRailButton(.primary)

                    Button("只打开提词窗口", systemImage: "macwindow") {
                        prepareStage()
                        stage.show()
                    }
                    .speechRailButton(.secondary)

                    Button("添加朗读提示", systemImage: "text.quote") {
                        requestReadingCues()
                    }
                    .speechRailButton(.secondary)
                    .disabled(session.isAnnotating)

                    Button("重新编辑原稿") {
                        session.discardPendingVersion()
                    }
                    .speechRailButton(.secondary)
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    // MARK: - 5. 跟读运行中工作区

    private var runningWorkspace: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                CardHead(title: "提词舞台运行中", detail: "稿件正文已锁定保护；你可以在独立悬浮窗口中跟读") {
                    StatusPill(
                        tone: session.phase == .following ? .healthy : .attention,
                        label: phaseLabel(session.phase)
                    )
                }

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
                        Text("单调已用时间")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        Text(formatClock(session.runClock.elapsedSeconds))
                            .font(SpeechRailDesignTokens.Typography.technicalValue)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    }

                    Spacer()

                    Button("返回提词舞台", systemImage: "macwindow") {
                        stage.show()
                    }
                    .speechRailButton(.primary)

                    Button("停止跟读并解锁编辑", systemImage: "stop.fill") {
                        Task { await session.endFollowing() }
                    }
                    .speechRailButton(.secondary)
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    // MARK: - 舞台设置卡

    private var stageSettings: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                CardHead(title: "直播提词设置", detail: "调整独立舞台窗口的视觉尺寸；直播软件只采集摄像头或目标内容窗口")
                SessionHairline()
                HStack(spacing: SpeechRailDesignTokens.Spacing.gutter) {
                    LabeledContent {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Slider(
                                value: Binding(get: { settings.fontScale }, set: { settings.fontScale = $0 }),
                                in: SpeechRailDesignTokens.Teleprompter.stageMinimumFontScale...SpeechRailDesignTokens.Teleprompter.stageMaximumFontScale
                            )
                            .frame(minWidth: SpeechRailDesignTokens.Layout.creatorSpeedSliderWidth)
                            Text("\(Int(settings.scriptPointSize)) pt")
                                .font(SpeechRailDesignTokens.Typography.technicalValue)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    } label: {
                        Text("文字大小")
                    }

                    LabeledContent {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Slider(
                                value: Binding(get: { settings.opacity }, set: { settings.opacity = $0 }),
                                in: SpeechRailDesignTokens.Teleprompter.stageMinimumOpacity...SpeechRailDesignTokens.Teleprompter.stageMaximumOpacity
                            )
                            .frame(minWidth: SpeechRailDesignTokens.Layout.creatorSpeedSliderWidth)
                            Text("\(Int(settings.opacity * 100))%")
                                .font(SpeechRailDesignTokens.Typography.technicalValue)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                .frame(width: 36, alignment: .trailing)
                        }
                    } label: {
                        Text("透明度")
                    }

                    Stepper(
                        "提前提示 \(settings.visibleSegmentCount) 段",
                        value: Binding(
                            get: { settings.visibleSegmentCount },
                            set: { settings.visibleSegmentCount = $0 }
                        ),
                        in: SpeechRailDesignTokens.Teleprompter.stageMinimumVisibleSegmentCount...SpeechRailDesignTokens.Teleprompter.stageMaximumVisibleSegmentCount
                    )
                }

                Label("直播贴士：推流软件请只采集摄像头或目标内容窗口，不要采集整个屏幕。", systemImage: "rectangle.on.rectangle")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    .padding(.top, SpeechRailDesignTokens.Spacing.micro)
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    private func phaseLabel(_ phase: TeleprompterSession.Phase) -> String {
        switch phase {
        case .draft: "草稿"
        case .analyzing: "正在整理…"
        case .review: "审阅候选"
        case .ready: "可以开始"
        case .preparing: "正在连接…"
        case .following: "跟读中"
        case .paused: "已暂停"
        case .uncertain: "位置已保留"
        case .manual: "手动提词"
        case .ended: "已结束"
        }
    }

    private func formatClock(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
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
            if session.document == nil, let first = documents.first {
                try? session.load(documentID: first.id)
            }
        } catch {
            documents = []
            operationMessage = error.localizedDescription
        }
    }

    private func prepareStage() {
        guard session.canEdit else { return }
        if session.activeVersion == nil || session.phase == .draft {
            do { try session.useDeterministicFallback() }
            catch { operationMessage = error.localizedDescription }
        }
    }

    private func beginReading() {
        prepareStage()
        guard session.activeVersion != nil else { return }
        stage.show()
        Task { await session.beginFollowing() }
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
        if let markdown = session.exportMarkdown() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(markdown, forType: .string)
            operationMessage = "已复制稿件内容"
        }
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
            session.createDocument(
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
