import SwiftUI
import UniformTypeIdentifiers

public struct TeleprompterView: View {
    @Environment(TeleprompterSession.self) private var session
    @Environment(TeleprompterStageWindowController.self) private var stage
    @Environment(TeleprompterStageSettings.self) private var settings
    @State private var documents: [TeleprompterDocument] = []
    @State private var isImporterPresented = false

    public init() {}

    public var body: some View {
        PageScaffold(
            route: .teleprompter,
            minimumContentHeight: SpeechRailDesignTokens.Teleprompter.preparationMinimumHeight,
            growsWithContent: true
        ) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.gutter) {
                safetyNotice
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
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.plainText]
        ) { result in
            guard case .success(let url) = result else { return }
            do {
                let text = try TeleprompterTextImporter.load(from: url)
                session.createDocument(
                    title: url.deletingPathExtension().lastPathComponent,
                    sourceText: text
                )
                reloadDocuments()
            } catch {
                session.createDocument(title: "导入失败", sourceText: "")
            }
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
                    Text("还没有保存的稿件。")
                        .font(SpeechRailDesignTokens.Typography.callout)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .padding(SpeechRailDesignTokens.Spacing.md)
                } else {
                    ForEach(documents) { document in
                        Button {
                            try? session.load(documentID: document.id)
                        } label: {
                            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                                Text(document.title)
                                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                                    .lineLimit(1)
                                Text(document.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(SpeechRailDesignTokens.Typography.caption)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                            .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
                        }
                        .buttonStyle(.plain)
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
                    if session.activeVersion != nil {
                        Text("活动版本 \(session.document?.activeVersionID?.prefix(8) ?? "")")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
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
                    Button("AI 整理稿件", systemImage: "sparkles") {
                        Task { await session.analyzeDraft(language: "跟随原稿", style: "自然、适合直播") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sourceIsEmpty || session.phase == .analyzing)
                    Button("使用纯文本分段") {
                        try? session.useDeterministicFallback()
                    }
                    .buttonStyle(.bordered)
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
                    CardHead(title: "AI 建议（待确认）", detail: "建议不会覆盖原稿") {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Button("撤销") { session.discardPendingVersion() }
                            Button("接受并生成活动版本") {
                                try? session.acceptPendingVersion()
                                reloadDocuments()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    SessionHairline()
                    ForEach(pending.segments) { segment in
                        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Text("第 \(segment.ordinal + 1) 段 · \(segment.pauseHint.rawValue)")
                                .font(SpeechRailDesignTokens.Typography.captionMedium)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                            TextField("可编辑的段落", text: pendingSegmentBinding(segment.id))
                                .textFieldStyle(.plain)
                                .font(SpeechRailDesignTokens.Typography.body)
                                .speechRailField()
                        }
                    }
                }
                .padding(SpeechRailDesignTokens.Spacing.md)
            }
        }
    }

    private var stageSettings: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                CardHead(title: "舞台与跟读", detail: "直播软件请使用摄像头或目标窗口采集") {
                    Button("打开舞台", systemImage: "macwindow") {
                        stage.show()
                    }
                    .buttonStyle(.bordered)
                    .disabled(session.activeVersion == nil)
                }
                SessionHairline()
                HStack(spacing: SpeechRailDesignTokens.Spacing.gutter) {
                    LabeledContent("字号") {
                        Slider(
                            value: Binding(get: { settings.fontScale }, set: { settings.fontScale = $0 }),
                            in: SpeechRailDesignTokens.Teleprompter.stageMinimumFontScale...SpeechRailDesignTokens.Teleprompter.stageMaximumFontScale
                        )
                            .frame(minWidth: SpeechRailDesignTokens.Layout.creatorSpeedSliderWidth)
                    }
                    LabeledContent("透明度") {
                        Slider(
                            value: Binding(get: { settings.opacity }, set: { settings.opacity = $0 }),
                            in: SpeechRailDesignTokens.Teleprompter.stageMinimumOpacity...SpeechRailDesignTokens.Teleprompter.stageMaximumOpacity
                        )
                            .frame(minWidth: SpeechRailDesignTokens.Layout.creatorSpeedSliderWidth)
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
                    .buttonStyle(.borderedProminent)
                    .disabled(session.activeVersion == nil)
                    if session.phase == .following || session.phase == .paused || session.phase == .uncertain {
                        Button("结束提词", systemImage: "stop.fill") {
                            Task { await session.endFollowing() }
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer(minLength: 0)
                    Text(session.phase.rawValue)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    private var safetyNotice: some View {
        Label {
            Text("请在直播软件中选择摄像头或目标直播窗口，不要使用包含提词器的整屏采集。SpeechRail 不负责直播推流，也不会把提词器内容写入直播画面。")
                .font(SpeechRailDesignTokens.Typography.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
        } icon: {
            Image(systemName: "rectangle.on.rectangle")
                .foregroundStyle(SpeechRailDesignTokens.Color.attention)
        }
        .padding(SpeechRailDesignTokens.Spacing.md)
        .speechRailSurface(.control)
        .clipShape(SpeechRailDesignTokens.Corner.containerShape)
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
        documents = (try? session.listDocuments()) ?? []
    }
}
