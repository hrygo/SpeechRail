import SwiftUI

/// 按书维护发音规则的可编辑清单。规则保存在本机语音服务，不在 App 内另建规则库；
/// 界面只负责草稿、校验和保存结果反馈。
struct AudiobookPronunciationSheet: View {
    @Bindable var controller: AudiobookPronunciationController
    let bookID: UUID
    var onDismiss: () -> Void

    @State private var isConfirmingDeleteAll = false
    @FocusState private var focusedRuleID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            header
            statusNotices
            ruleList
            footer
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .frame(minWidth: 720, idealWidth: 780, minHeight: 460, idealHeight: 560)
        .confirmationDialog(
            "清除本书的全部发音规则？",
            isPresented: $isConfirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("清除全部规则", role: .destructive) {
                Task { await controller.deleteAll(bookID: bookID) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会同时从本机语音服务删除这组规则。已生成的音频不会改变；之后重新制作的片段将恢复默认读法。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            HStack(alignment: .firstTextBaseline) {
                Text("发音规则")
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                Text("按书生效")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Spacer()
                if controller.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            Text("用于多音字、人名地名、英文缩写等需要固定读法的词。规则只影响之后重新制作的片段；已采用的音频不会被自动改写。")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var statusNotices: some View {
        if !controller.isAvailable {
            NoticeBar(
                tone: .warning,
                message: "本机语音服务未连接。可以先整理规则，但连接后才能保存并用于制作。"
            )
        }
        if controller.needsRefresh {
            NoticeBar(
                tone: .warning,
                message: "这些规则已在别处更新，或服务端版本已变化。请先刷新，再决定是否保存。",
                actionTitle: "刷新"
            ) {
                Task { await controller.refresh(bookID: bookID) }
            }
        }
        if let error = controller.errorMessage {
            NoticeBar(tone: .critical, message: error, actionTitle: "知道了") {
                controller.clearError()
            }
        }
        if let lastSavedAt = controller.lastSavedAt {
            Text("已保存 \(lastSavedAt.speechRailFormatted(.time)) · 共 \(controller.binding?.entries.count ?? 0) 条")
                .font(SpeechRailDesignTokens.Typography.technical)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
        }
    }

    private var ruleList: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            HStack {
                Text("原文")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .frame(width: 220, alignment: .leading)
                Spacer(minLength: 0)
                Text("读作")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .frame(width: 220, alignment: .leading)
                Spacer(minLength: 0)
                Text("匹配")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .frame(width: 150, alignment: .leading)
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    if controller.draft.isEmpty {
                        emptyState
                    } else {
                        ForEach($controller.draft) { $rule in
                            ruleRow($rule)
                        }
                    }
                }
                .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
            }
            .frame(maxHeight: .infinity)
            .background(SpeechRailDesignTokens.Color.recessedField, in: SpeechRailDesignTokens.Corner.containerShape)
            .overlay {
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.container)
                    .strokeBorder(SpeechRailDesignTokens.Color.separator, lineWidth: SpeechRailDesignTokens.Spacing.hairline)
            }

            Button {
                controller.addRule()
                focusedRuleID = controller.draft.last?.id
            } label: {
                Label("添加规则", systemImage: "plus")
            }
            .speechRailButton(.secondary)
            .disabled(controller.isSaving)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Text("还没有发音规则")
                .font(SpeechRailDesignTokens.Typography.bodyMedium)
            Text("例如：原文「重」读作「chóng」，或原文「NASA」读作「那萨」。")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
        }
        .padding(SpeechRailDesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ruleRow(_ rule: Binding<AudiobookPronunciationController.Rule>) -> some View {
        HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.xs) {
            TextField("原文", text: rule.surface)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .focused($focusedRuleID, equals: rule.wrappedValue.id)
                .accessibilityLabel("规则原文")

            TextField("读作", text: rule.spoken)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .accessibilityLabel("规则读法")

            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Toggle("大小写", isOn: rule.caseSensitive)
                    .toggleStyle(.checkbox)
                    .help("开启时只有大小写完全一致才命中；英文缩写通常建议关闭。")
                Toggle("整词", isOn: rule.wordBoundary)
                    .toggleStyle(.checkbox)
                    .help("开启时只在独立单词边界命中，避免命中更长单词的一部分。")
            }
            .font(SpeechRailDesignTokens.Typography.caption)
            .frame(width: 150, alignment: .leading)

            Button {
                controller.removeRule(id: rule.wrappedValue.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            .help("删除这条规则")
            .accessibilityLabel("删除规则 \(rule.wrappedValue.surface)")
            .disabled(controller.isSaving)
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
    }

    private var footer: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            Button("清除全部规则", role: .destructive) {
                isConfirmingDeleteAll = true
            }
            .speechRailButton(.quiet)
            .disabled(controller.binding == nil || controller.isSaving)

            Spacer()

            Button("关闭") { onDismiss() }
                .speechRailButton(.secondary)
                .keyboardShortcut(.cancelAction)

            Button {
                Task { await controller.save(bookID: bookID) }
            } label: {
                if controller.isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Text("保存规则")
                }
            }
            .speechRailButton(.primary)
            .disabled(controller.isSaving || !controller.isAvailable || controller.draft.count > 500)
            .keyboardShortcut(.defaultAction)
        }
    }
}
