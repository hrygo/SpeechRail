import SwiftUI

struct AudiobookVoicePreparationSheet: View {
    @Bindable var workflow: AudiobookWorkflowModel

    private var pending: [AudiobookVoiceCreationDraft] {
        workflow.voiceCreationDrafts.filter { !$0.status.isComplete }
    }
    private var selected: [AudiobookVoiceCreationDraft] { pending.filter(\.isSelected) }
    private var isCreationBlocked: Bool {
        workflow.isPreparingVoiceDrafts || workflow.isAssigningRecommendedVoices
            || workflow.isAnalyzing || workflow.isProductionBusy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text("浏览并创建音色")
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                Text("名称、声音描述与试听文稿已备好。勾选后确认创建，可随时修改建议；群像声音可供列出的角色共用。")
                    .font(SpeechRailDesignTokens.Typography.body)
                Text("创建后会重新准备配声建议，声音共用或撞音由你确认。章节音频另行启动。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            if let message = workflow.voiceCreationErrorMessage {
                NoticeBar(tone: .warning, message: message)
            }
            if isCreationBlocked {
                Text("正在处理当前作品，请稍候再创建声音；资料仍可浏览。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            if let summary = workflow.voiceCreationSummary {
                Text(summary).font(SpeechRailDesignTokens.Typography.callout)
                    .accessibilityIdentifier("audiobook-voice-batch-summary")
            }
            if workflow.voiceCreationDrafts.isEmpty {
                ContentUnavailableView("暂无需要补充的声音", systemImage: "person.wave.2",
                    description: Text("已有选声会保留。也可回到角色卡片，单独准备新的专属音色。"))
            } else {
                HStack {
                    Text("共 \(workflow.voiceCreationDrafts.count) 项，已选 \(selected.count) 项")
                    Spacer()
                    Button("重新读取角色资料") {
                        Task { await workflow.prepareVoiceCreationDrafts(scope: workflow.voicePreparationScope) }
                    }
                    .disabled(workflow.isCreatingVoiceDrafts || workflow.isPreparingVoiceDrafts)
                    .help("重新核对角色与原文，仍适用的编辑会保留")
                    Button(selected.count == pending.count ? "取消全选" : "全选待创建项") {
                        let selectAll = selected.count != pending.count
                        for var draft in pending {
                            draft.isSelected = selectAll
                            workflow.updateVoiceCreationDraft(draft)
                        }
                    }
                    .disabled(workflow.isCreatingVoiceDrafts || pending.isEmpty)
                }
                .font(SpeechRailDesignTokens.Typography.caption)
                List {
                    ForEach(workflow.voiceCreationDrafts) { draft in
                        AudiobookVoiceDraftRow(draft: binding(for: draft),
                            chapters: workflow.chapters, isBusy: workflow.isCreatingVoiceDrafts)
                    }
                }
                .listStyle(.inset)
                .accessibilityIdentifier("audiobook-voice-draft-list")
            }
            footer
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .frame(minWidth: SpeechRailDesignTokens.Layout.Sheet.formWidth,
            idealWidth: SpeechRailDesignTokens.Layout.Sheet.prominentWidth,
            minHeight: SpeechRailDesignTokens.Layout.creatorEditorMinimumHeight,
            idealHeight: SpeechRailDesignTokens.Layout.creatorDubbingSheetHeight)
        .interactiveDismissDisabled(workflow.isCreatingVoiceDrafts)
        .accessibilityIdentifier("audiobook-voice-preparation-sheet")
    }

    private func binding(for draft: AudiobookVoiceCreationDraft) -> Binding<AudiobookVoiceCreationDraft> {
        Binding(get: { workflow.voiceCreationDrafts.first { $0.id == draft.id } ?? draft },
            set: { workflow.updateVoiceCreationDraft($0) })
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            if let text = workflow.voiceCreationProgressText {
                ProgressView().controlSize(.small)
                Text(text).font(SpeechRailDesignTokens.Typography.caption)
                    .accessibilityIdentifier("audiobook-voice-batch-progress")
            }
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                Button("返回配声") { workflow.isShowingVoicePreparationSheet = false }
                    .speechRailButton(.secondary)
                    .keyboardShortcut(.cancelAction)
                    .disabled(workflow.isCreatingVoiceDrafts)
                Spacer()
                if workflow.isCreatingVoiceDrafts {
                    Button("停止后续创建") { workflow.cancelVoiceDraftCreation() }
                        .speechRailButton(.secondary)
                        .accessibilityIdentifier("audiobook-voice-batch-stop")
                } else {
                    if selected.contains(where: { $0.status.isFailure }) {
                        Button("仅重试失败项") {
                            Task { await workflow.createSelectedVoiceDrafts(retryFailuresOnly: true) }
                        }
                        .speechRailButton(.secondary)
                        .disabled(isCreationBlocked)
                        .accessibilityIdentifier("audiobook-voice-batch-retry")
                    }
                    Button(selected.allSatisfy { $0.status.isCreated }
                        ? "继续检查所选音色（\(selected.count)）" : "确认创建所选音色（\(selected.count)）") {
                        Task { await workflow.createSelectedVoiceDrafts() }
                    }
                    .speechRailButton(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreationBlocked || selected.isEmpty || selected.contains(where: { $0.validationMessage != nil }))
                    .accessibilityIdentifier("audiobook-voice-batch-confirm")
                }
            }
        }
    }
}

private struct AudiobookVoiceDraftRow: View {
    @Binding var draft: AudiobookVoiceCreationDraft
    let chapters: [AudiobookChapter]
    let isBusy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Toggle(isOn: $draft.isSelected) {
                    Text(targetTitle).font(SpeechRailDesignTokens.Typography.callout)
                }
                .toggleStyle(.checkbox)
                .disabled(isBusy || draft.status.isComplete)
                .accessibilityLabel("选择创建：\(targetTitle)")
                Spacer()
                Text(draft.status.title)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(draft.status.isFailure ? SpeechRailDesignTokens.Color.attention : SpeechRailDesignTokens.Color.inkSecondary)
            }
            Text("适用角色：\(draft.roleNames)")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            if draft.replacesExistingVoice {
                Text("确认后将为该角色更换声音，相关片段标记待更新；已采用音频和历史版本会保留。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.attention)
            }
            Group {
                TextField("音色名称", text: $draft.voiceName)
                    .speechRailSingleLineInput(.regular)
                    .accessibilityLabel("\(targetTitle)的音色名称")
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Text("声音描述 · 可调整的建议")
                        .font(SpeechRailDesignTokens.Typography.caption)
                    TextField("描述想要的声音", text: $draft.instruction, axis: .vertical)
                        .lineLimit(3...6)
                        .padding(SpeechRailDesignTokens.Spacing.sm)
                        .speechRailRecessedSlot()
                        .accessibilityLabel("\(targetTitle)的声音描述")
                }
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Text("试听文稿 · \(draft.referenceText.unicodeScalars.count)/240 字")
                        .font(SpeechRailDesignTokens.Typography.caption)
                    TextField("试听文稿", text: $draft.referenceText, axis: .vertical)
                        .lineLimit(2...5)
                        .padding(SpeechRailDesignTokens.Spacing.sm)
                        .speechRailRecessedSlot()
                        .accessibilityLabel("\(targetTitle)的试听文稿")
                    Text(draft.referenceTextSource)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
            }
            .disabled(isBusy || draft.status.isComplete)
            if let message = draft.validationMessage {
                Text(message).font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.attention)
            }
            DisclosureGroup("原文与角色依据（\(draft.sourceEvidence.count)）") {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    if draft.sourceEvidence.isEmpty {
                        Text("没有足够的原文声音描写，已采用适合该角色类型的建议。")
                    }
                    ForEach(draft.sourceEvidence, id: \.self) { evidence in
                        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                            Text(chapters.first { $0.id == evidence.chapterID }?.title ?? "原文依据")
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            Text(evidence.quoteExcerpt).textSelection(.enabled)
                            if let traits = evidence.voiceTraitSummary { Text("角色分析建议：\(traits)") }
                        }
                    }
                }
                .font(SpeechRailDesignTokens.Typography.caption)
            }
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("audiobook-voice-draft-\(draft.id)")
    }

    private var targetTitle: String {
        switch draft.target {
        case .role: draft.roles.first?.displayName ?? "角色专属声音"
        case .ensemble(let archetype): "\(archetype.shortBadgeTitle) · 群像声音"
        }
    }
}
