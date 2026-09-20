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

    public init() {}

    public var body: some View {
        PageScaffold(
            route: .teleprompter,
            minimumContentHeight: SpeechRailDesignTokens.Teleprompter.preparationMinimumHeight,
            growsWithContent: true
        ) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.gutter) {
                headerNotices
                if let operationMessage {
                    Label(operationMessage, systemImage: "exclamationmark.triangle")
                        .font(SpeechRailDesignTokens.Typography.callout)
                        .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                }
                HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.gutter) {
                    recentDocuments
                        .frame(width: SpeechRailDesignTokens.Layout.sessionListWidth)
                    editor
                }
            }
        } trailing: {
            EmptyView()
        }
        .task {
            reloadDocuments()
        }
        .alert(
            TeleprompterAIDataFlowDisclosure.title,
            isPresented: $isAIDataFlowDisclosurePresented
        ) {
            Button("取消", role: .cancel) {}
            Button("继续并发送原稿") {
                UserDefaults.standard.set(true, forKey: aiDataFlowAcknowledgementKey)
                startAIAnalysis()
            }
        } message: {
            Text(TeleprompterAIDataFlowDisclosure.message)
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.plainText, .text]
        ) { result in
            switch result {
            case .success(let url):
                do {
                    let text = try TeleprompterTextImporter.load(from: url)
                    session.createDocument(
                        title: url.deletingPathExtension().lastPathComponent,
                        sourceText: text
                    )
                    operationMessage = nil
                    reloadDocuments()
                } catch {
                    operationMessage = error.localizedDescription
                }
            case .failure(let error):
                if let cocoaError = error as? CocoaError, cocoaError.code != .userCancelled {
                    operationMessage = "导入失败：\(error.localizedDescription)"
                }
            }
        }
        .alert(
            "确定删除提词稿？",
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
            Text("删除「\(doc.title)」后将无法恢复。")
        }
    }

    private var recentDocuments: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                CardHead(title: "我的提词稿", detail: "稿件与活动版本") {
                    Menu {
                        Button("新建稿件") {
                            session.createDocument(title: "未命名提词稿", sourceText: "")
                        }
                        Button("导入 TXT / Markdown…") {
                            isImporterPresented = true
                        }
                    } label: {
                        Label("新建", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                }
                SessionHairline()
                if documents.isEmpty {
                    VStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 24))
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        Text("还没有保存的稿件")
                            .font(SpeechRailDesignTokens.Typography.bodyMedium)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                        Text("点击右上角「新建」或导入 TXT / Markdown 即可开始。")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(SpeechRailDesignTokens.Spacing.lg)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: SpeechRailDesignTokens.Spacing.tight) {
                            ForEach(documents) { document in
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
                                            Text(document.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                                .font(SpeechRailDesignTokens.Typography.caption)
                                                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
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
                                        Button("复制 Markdown", systemImage: "doc.on.doc") {
                                            if let markdown = session.exportMarkdown() {
                                                NSPasteboard.general.clearContents()
                                                NSPasteboard.general.setString(markdown, forType: .string)
                                                operationMessage = "已复制 Markdown 格式稿件"
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
                                .contextMenu {
                                    Button {
                                        do {
                                            _ = try session.duplicateDocument(documentID: document.id)
                                            reloadDocuments()
                                        } catch {
                                            operationMessage = error.localizedDescription
                                        }
                                    } label: {
                                        Label("创建副本", systemImage: "plus.square.on.square")
                                    }

                                    Button {
                                        if let markdown = session.exportMarkdown() {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(markdown, forType: .string)
                                            operationMessage = "已复制 Markdown 格式稿件"
                                        }
                                    } label: {
                                        Label("复制 Markdown", systemImage: "doc.on.doc")
                                    }

                                    Divider()

                                    Button(role: .destructive) {
                                        documentToDelete = document
                                        isDeleteAlertPresented = true
                                    } label: {
                                        Label("删除稿件…", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if session.document == nil {
            CardSurface {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
                    Text("开始准备一份提词稿")
                        .font(SpeechRailDesignTokens.Typography.display)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    Text("粘贴或导入 TXT / Markdown。AI 只在你主动点击时整理，运行时不会逐句调用大模型。")
                        .font(SpeechRailDesignTokens.Typography.callout)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Button("新建稿件") {
                            session.createDocument(title: "未命名提词稿", sourceText: "")
                        }
                        .buttonStyle(.borderedProminent)
                        Button("导入文件…") {
                            isImporterPresented = true
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(SpeechRailDesignTokens.Spacing.lg)
            }
        } else {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.gutter) {
                sourceEditor
                reviewPanel
                stageSettings
            }
        }
    }

    private var sourceEditor: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                CardHead(title: "原稿", detail: "活动版本不会在跟读中被静默修改") {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Text("\(sourceBinding.wrappedValue.count) 字")
                            .font(SpeechRailDesignTokens.Typography.technicalValue)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        if session.activeVersion != nil {
                            StatusPill(tone: .neutral, label: "版本 \(session.document?.activeVersionID?.prefix(8) ?? "")")
                        }
                        Menu {
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
                            Button("复制 Markdown 全文", systemImage: "doc.on.doc") {
                                if let markdown = session.exportMarkdown() {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(markdown, forType: .string)
                                    operationMessage = "已复制 Markdown 格式稿件"
                                }
                            }
                            Divider()
                            Button("删除此稿件…", systemImage: "trash", role: .destructive) {
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
                TextField("稿件标题", text: titleBinding)
                    .textFieldStyle(.plain)
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .speechRailField()
                TextEditor(text: sourceBinding)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .frame(minHeight: SpeechRailDesignTokens.Layout.creatorComposerMinimumHeight)
                    .speechRailField()
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Button {
                        requestAIAnalysis()
                    } label: {
                        Label(
                            session.phase == .analyzing ? "AI 整理中…" : "AI 整理稿件",
                            systemImage: "sparkles"
                        )
                    }
                    .speechRailButton(.primary)
                    .disabled(sourceIsEmpty || session.phase == .analyzing)

                    Button("使用纯文本分段") {
                        do {
                            try session.useDeterministicFallback()
                            operationMessage = nil
                        } catch {
                            operationMessage = error.localizedDescription
                        }
                    }
                    .speechRailButton(.secondary)
                    .disabled(sourceIsEmpty)

                    Spacer(minLength: 0)
                    if let blocked = session.blocked {
                        Label(blocked.title, systemImage: "exclamationmark.triangle")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                    }
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    @ViewBuilder
    private var reviewPanel: some View {
        if let pending = session.pendingVersion {
            CardSurface {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                    CardHead(title: "AI 建议（待确认）", detail: "建议不会覆盖原稿，确认后生成活动版本") {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Button("撤销") { session.discardPendingVersion() }
                                .speechRailButton(.secondary)

                            Button("接受并生成活动版本") {
                                do {
                                    try session.acceptPendingVersion()
                                    operationMessage = nil
                                    reloadDocuments()
                                } catch {
                                    operationMessage = error.localizedDescription
                                }
                            }
                            .speechRailButton(.primary)
                        }
                    }
                    SessionHairline()
                    VStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        ForEach(pending.segments) { segment in
                            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                                HStack {
                                    Text("第 \(segment.ordinal + 1) 段")
                                        .font(SpeechRailDesignTokens.Typography.captionMedium)
                                        .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                                    Spacer()
                                    StatusPill(tone: .neutral, label: pauseHintLabel(segment.pauseHint))
                                }
                                TextField("可编辑的段落", text: pendingSegmentBinding(segment.id))
                                    .textFieldStyle(.plain)
                                    .font(SpeechRailDesignTokens.Typography.body)
                                    .speechRailField()
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
                .padding(SpeechRailDesignTokens.Spacing.md)
            }
        }
    }

    private func pauseHintLabel(_ hint: TeleprompterPauseHint) -> String {
        switch hint {
        case .short: "短停顿 · 0.5s"
        case .medium: "中停顿 · 1.0s"
        case .long: "长停顿 · 2.0s"
        }
    }

    private var stageSettings: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                CardHead(title: "舞台与跟读", detail: "独立浮层 · 直播软件请使用摄像头或目标窗口采集") {
                    Button("打开舞台", systemImage: "macwindow") {
                        stage.show()
                    }
                    .speechRailButton(.secondary)
                    .disabled(session.activeVersion == nil)
                }
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
                        Text("字号")
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
                        "显示 \(settings.visibleSegmentCount) 段",
                        value: Binding(
                            get: { settings.visibleSegmentCount },
                            set: { settings.visibleSegmentCount = $0 }
                        ),
                        in: SpeechRailDesignTokens.Teleprompter.stageMinimumVisibleSegmentCount...SpeechRailDesignTokens.Teleprompter.stageMaximumVisibleSegmentCount
                    )
                }
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Button("打开舞台并开始跟读", systemImage: "play.fill") {
                        stage.show()
                        Task { await session.beginFollowing() }
                    }
                    .speechRailButton(.primary)
                    .disabled(session.activeVersion == nil)

                    if session.phase == .following || session.phase == .paused || session.phase == .uncertain {
                        Button("结束提词", systemImage: "stop.fill") {
                            Task { await session.endFollowing() }
                        }
                        .speechRailButton(.secondary)
                    }
                    Spacer(minLength: 0)
                    StatusPill(
                        tone: session.phase == .following ? .healthy : (session.phase == .uncertain ? .attention : .neutral),
                        label: phaseLabel(session.phase)
                    )
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    private func phaseLabel(_ phase: TeleprompterSession.Phase) -> String {
        switch phase {
        case .draft: "草稿"
        case .analyzing: "正在整理…"
        case .review: "待确认"
        case .ready: "已就绪"
        case .preparing: "连接中…"
        case .following: "跟读中"
        case .paused: "已暂停"
        case .uncertain: "请确认位置"
        case .manual: "手动模式"
        case .ended: "已结束"
        }
    }

    private var headerNotices: some View {
        HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.md) {
            Label {
                Text("请在直播软件中选择摄像头或目标直播窗口，避免整屏采集。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            } icon: {
                Image(systemName: "rectangle.on.rectangle")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.attention)
            }
            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
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
            SpeechRailDesignTokens.Color.field,
            in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
        )
        .accessibilityElement(children: .combine)
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

    private func pendingSegmentBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { session.pendingVersion?.segments.first { $0.id == id }?.text ?? "" },
            set: { session.updatePendingSegment(id: id, text: $0) }
        )
    }

    private func reloadDocuments() {
        do {
            documents = try session.listDocuments()
        } catch {
            documents = []
            operationMessage = error.localizedDescription
        }
    }

    private func requestAIAnalysis() {
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
            await session.analyzeDraft(language: "跟随原稿", style: "自然、适合直播")
        }
    }
}
