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
                        .disabled(!session.canEdit)
                    editor
                }
            }
        } trailing: {
            EmptyView()
        }
        .task {
            reloadDocuments()
        }
        .onChange(of: session.document?.id) { _, _ in reloadDocuments() }
        .onChange(of: session.pendingVersion?.id) { _, pendingID in
            if pendingID != nil {
                isAIReviewExpanded = true
            }
        }
        .alert(
            TeleprompterAIDataFlowDisclosure.title,
            isPresented: $isAIDataFlowDisclosurePresented
        ) {
            Button("取消", role: .cancel) {}
            Button("允许发送并整理") {
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
    }

    private var recentDocuments: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                CardHead(title: "我的稿子", detail: "保存的稿子与跟读版本") {
                    Menu {
                        Button("新建稿子") {
                            session.createDocument(title: "未命名稿子", sourceText: "")
                        }
                        Button("导入文本文件…") {
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
                        Text("还没有保存的稿子")
                            .font(SpeechRailDesignTokens.Typography.bodyMedium)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                        Text("点击右上角「新建」或导入文本文件开始。")
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
                                            operationMessage = "已复制稿件内容"
                                        }
                                    } label: {
                                        Label("复制稿件内容", systemImage: "doc.on.doc")
                                    }

                                    Divider()

                                     Button(role: .destructive) {
                                         documentToDelete = document
                                         isDeleteAlertPresented = true
                                     } label: {
                                        Label("删除稿子…", systemImage: "trash")
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
                    Text("先准备一份稿子")
                        .font(SpeechRailDesignTokens.Typography.display)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    Text("粘贴或导入文本文件。需要时点「AI 帮我整理」；原稿不会被直接改掉。")
                        .font(SpeechRailDesignTokens.Typography.callout)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Button("新建稿子") {
                            session.createDocument(title: "未命名稿子", sourceText: "")
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
                CardHead(title: "原稿", detail: "这里的内容不会被 AI 直接改掉") {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Text("\(sourceBinding.wrappedValue.count) 字")
                            .font(SpeechRailDesignTokens.Typography.technicalValue)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        if session.activeVersion != nil {
                            StatusPill(tone: .neutral, label: "跟读版 \(session.document?.activeVersionID?.prefix(8) ?? "")")
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
                            Button("复制稿件内容", systemImage: "doc.on.doc") {
                                if let markdown = session.exportMarkdown() {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(markdown, forType: .string)
                                    operationMessage = "已复制稿件内容"
                                }
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
                    .disabled(!session.canEdit)
                    .textFieldStyle(.plain)
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .speechRailField()
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
                    .speechRailField()
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Button {
                        requestAIAnalysis()
                    } label: {
                        Label(
                            session.phase == .analyzing ? "整理中…" : "AI 优化朗读标注",
                            systemImage: "sparkles"
                        )
                    }
                    .speechRailButton(.secondary)
                    .disabled(sourceIsEmpty || !session.canEdit || session.phase == .analyzing)

                    Button(startButtonTitle, systemImage: "play.fill") {
                        beginReading()
                    }
                    .speechRailButton(.primary)
                    .disabled(sourceIsEmpty || !session.canEdit)

                    Spacer(minLength: 0)
                    if let blocked = session.blocked {
                        Label(blocked.title, systemImage: "exclamationmark.triangle")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                    }
                }
                Text("跟读时稿件会锁定；需要临时调整位置，可在舞台中使用 ← / →。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    @ViewBuilder
    private var reviewPanel: some View {
        if let pending = session.pendingVersion {
            CardSurface {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                    CardHead(title: "AI 建议（待确认）", detail: "确认后用于跟读；也可以跳过建议按原稿开始") {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Button("撤销") { session.discardPendingVersion() }
                                .speechRailButton(.secondary)

                            Button("确认建议并用于跟读") {
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
                    DisclosureGroup(isExpanded: $isAIReviewExpanded) {
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
                                    if !segment.keywords.isEmpty || !segment.matchPhrases.isEmpty {
                                        DisclosureGroup("朗读提示") {
                                            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                                                if !segment.keywords.isEmpty {
                                                    Text("重点：\(segment.keywords.joined(separator: "、"))")
                                                }
                                                if !segment.matchPhrases.isEmpty {
                                                    Text("表达参考：\(segment.matchPhrases.joined(separator: "；"))")
                                                }
                                            }
                                            .font(SpeechRailDesignTokens.Typography.caption)
                                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                        }
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
                        .padding(.top, SpeechRailDesignTokens.Spacing.xs)
                    } label: {
                        Label("查看 \(pending.segments.count) 段建议", systemImage: "text.magnifyingglass")
                            .font(SpeechRailDesignTokens.Typography.captionMedium)
                    }
                }
                .padding(SpeechRailDesignTokens.Spacing.md)
            }
            .disabled(!session.canEdit)
        }
    }

    private func pauseHintLabel(_ hint: TeleprompterPauseHint) -> String {
        switch hint {
        case .short: "轻停顿"
        case .medium: "句意结束"
        case .long: "换话题 / 长停顿"
        }
    }

    private var stageSettings: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                CardHead(title: "直播提词", detail: "单独的提词窗口；直播软件只采集摄像头或目标内容窗口")
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
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Button("只打开提词窗口", systemImage: "macwindow") {
                        prepareStage()
                        stage.show()
                    }
                    .speechRailButton(.secondary)
                    .disabled((sourceIsEmpty && session.activeVersion == nil) || session.pendingVersion != nil)

                    if session.isCapturing {
                        Button("停止跟读", systemImage: "stop.fill") {
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
                Text(session.pendingVersion == nil
                     ? "舞台打开后，按空格开始或暂停跟读；稿件内容会在跟读期间保持不变。"
                     : "请先确认或跳过 AI 建议，再打开舞台。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    private func phaseLabel(_ phase: TeleprompterSession.Phase) -> String {
        switch phase {
        case .draft: "可以按原稿开始"
        case .analyzing: "正在整理…"
        case .review: "请检查建议"
        case .ready: "可以开始"
        case .preparing: "正在连接…"
        case .following: "跟读中"
        case .paused: "已暂停"
        case .uncertain: "位置已保留"
        case .manual: "手动提词"
        case .ended: "已结束"
        }
    }

    private var headerNotices: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            Label {
                Text("直播软件请只采集摄像头或目标内容窗口，不要采集整个屏幕。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            } icon: {
                Image(systemName: "rectangle.on.rectangle")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.attention)
            }
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

    private func prepareStage() {
        guard session.canEdit else { return }
        if session.activeVersion == nil || session.phase == .draft {
            do { try session.useDeterministicFallback() }
            catch { operationMessage = error.localizedDescription }
        }
    }

    private func beginReading() {
        if session.pendingVersion != nil {
            do {
                try session.useDeterministicFallback()
            } catch {
                operationMessage = error.localizedDescription
                return
            }
        } else {
            prepareStage()
        }
        guard session.activeVersion != nil else { return }
        stage.show()
        Task { await session.beginFollowing() }
        operationMessage = nil
    }

    private var startButtonTitle: String {
        session.pendingVersion == nil ? "打开舞台并开始跟读" : "跳过建议并开始"
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
