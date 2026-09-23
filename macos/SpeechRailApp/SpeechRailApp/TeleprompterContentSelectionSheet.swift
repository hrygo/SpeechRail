import SwiftUI

/// 选择要讲的内容 Sheet。
///
/// 遵循 `docs/superpowers/specs/2026-09-20-ai-teleprompter-final-spec.md` §3.4 与 §5.3：
/// - 显示带复选框的来源段落，默认全选；
/// - 用户操作的是「本次要讲什么」，不是模型分片大小；
/// - 未选中的内容在原稿中完整保留，标记为 `userExcluded`，生成与跟读中排除；
/// - 实时反馈已选段落数、已选字数与预估时长。
public struct TeleprompterContentSelectionSheet: View {
    @Bindable var session: TeleprompterSession
    @Environment(\.dismiss) private var dismiss

    private struct Paragraph: Identifiable, Hashable {
        let id: Int
        let text: String
    }

    @State private var paragraphs: [Paragraph] = []
    @State private var selectedIndices: Set<Int> = []

    public init(session: TeleprompterSession) {
        self.session = session
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.gutter) {
            header
            statsAndBatchBar
            paragraphList
            Spacer(minLength: 0)
            footerActions
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .frame(
            width: SpeechRailDesignTokens.Teleprompter.contentSelectionSheetWidth,
            height: SpeechRailDesignTokens.Teleprompter.contentSelectionSheetHeight
        )
        .onAppear {
            loadParagraphs()
        }
    }

    // MARK: - 头部说明

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text("选择本次要讲的内容")
                    .font(SpeechRailDesignTokens.Typography.display)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)

                Text("勾选本次需要朗读的段落。未选中的内容会完整保留在原稿中，但不会发送整理，也不会出现在跟读中。")
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                SpeechRailButtonIcon(.close, size: SpeechRailDesignTokens.Icon.buttonIconSize)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .frame(
                        width: SpeechRailDesignTokens.Control.iconButtonSize,
                        height: SpeechRailDesignTokens.Control.iconButtonSize
                    )
            }
            .buttonStyle(.plain)
            .speechRailPointerCursor()
            .accessibilityLabel("关闭")
        }
    }

    // MARK: - 统计与全选条

    private var statsAndBatchBar: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                StatusPill(
                    tone: selectedIndices.isEmpty ? .attention : .healthy,
                    label: "已选 \(selectedIndices.count) / \(paragraphs.count) 段"
                )

                Text("·")
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)

                Text("\(selectedUnits) 字/词")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

                Text("·")
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)

                Text("预计用时 \(formatMinutes(selectedEstimateMinutes))")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }

            Spacer()

            Button("全选") {
                selectedIndices = Set(0..<paragraphs.count)
            }
            .buttonStyle(.plain)
            .font(SpeechRailDesignTokens.Typography.captionMedium)
            .foregroundStyle(SpeechRailDesignTokens.Color.rail)
            .disabled(selectedIndices.count == paragraphs.count)
            .speechRailPointerCursor()

            Button("全部取消") {
                selectedIndices.removeAll()
            }
            .buttonStyle(.plain)
            .font(SpeechRailDesignTokens.Typography.captionMedium)
            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            .disabled(selectedIndices.isEmpty)
            .speechRailPointerCursor()
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .background(
            SpeechRailDesignTokens.Color.recessedField,
            in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
        )
    }

    // MARK: - 段落列表

    private var paragraphList: some View {
        ScrollView {
            VStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                ForEach(paragraphs) { paragraph in
                    let index = paragraph.id
                    let isSelected = selectedIndices.contains(index)
                    let text = paragraph.text
                    HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
                        Toggle(isOn: Binding(
                            get: { isSelected },
                            set: { newValue in
                                if newValue {
                                    selectedIndices.insert(index)
                                } else {
                                    selectedIndices.remove(index)
                                }
                            }
                        )) {
                            EmptyView()
                        }
                        .toggleStyle(.checkbox)
                        .padding(.top, 2)

                        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                            HStack {
                                Text("第 \(index + 1) 段")
                                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                                    .foregroundStyle(isSelected ? SpeechRailDesignTokens.Color.rail : SpeechRailDesignTokens.Color.inkTertiary)
                                Spacer()
                                Text("\(text.count) 字")
                                    .font(SpeechRailDesignTokens.Typography.caption)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                            }

                            Text(text)
                                .font(SpeechRailDesignTokens.Typography.body)
                                .foregroundStyle(isSelected ? SpeechRailDesignTokens.Color.ink : SpeechRailDesignTokens.Color.inkTertiary)
                                .lineLimit(3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(SpeechRailDesignTokens.Spacing.sm)
                    .background(
                        isSelected ? SpeechRailDesignTokens.Color.field : SpeechRailDesignTokens.Color.recessedField.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                            .stroke(
                                isSelected ? SpeechRailDesignTokens.Surface.border : Color.clear,
                                lineWidth: SpeechRailDesignTokens.Stroke.hairline
                            )
                    )
                }
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
        }
    }

    // MARK: - 底部操作栏

    private var footerActions: some View {
        HStack {
            Button("取消") {
                dismiss()
            }
            .speechRailButton(.secondary)

            Spacer()

            Button("确定本次范围") {
                session.updateContentSelection(
                    TeleprompterContentSelection(
                        totalParagraphCount: paragraphs.count,
                        selectedParagraphIndices: selectedIndices
                    )
                )
                dismiss()
            }
            .speechRailButton(.primary)
            .disabled(selectedIndices.isEmpty)
        }
    }

    // MARK: - 辅助计算

    private func loadParagraphs() {
        let raw = session.document?.sourceText ?? ""
        let parts = raw.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        paragraphs = (parts.isEmpty ? [raw] : parts).enumerated().map { index, text in
            Paragraph(id: index, text: text)
        }

        if session.contentSelection.totalParagraphCount == paragraphs.count && !session.contentSelection.selectedParagraphIndices.isEmpty {
            selectedIndices = session.contentSelection.selectedParagraphIndices
        } else {
            // 默认全选
            selectedIndices = Set(0..<paragraphs.count)
        }
    }

    private var selectedUnits: Int {
        let selectedText = selectedIndices.compactMap { index in
            paragraphs.first(where: { $0.id == index })?.text
        }.joined(separator: "\n\n")
        return TeleprompterTimingPolicy.countMetrics(in: selectedText).totalUnits
    }

    private var selectedEstimateMinutes: Double {
        let selectedText = selectedIndices.compactMap { index in
            paragraphs.first(where: { $0.id == index })?.text
        }.joined(separator: "\n\n")
        let metrics = TeleprompterTimingPolicy.countMetrics(in: selectedText)
        let est = TeleprompterTimingPolicy.estimateDuration(metrics: metrics, pace: session.pace, calibrationFactor: session.calibrationFactor)
        return (est.pointSeconds ?? 0) / 60.0
    }

    private func formatMinutes(_ minutes: Double) -> String {
        let mins = Int(round(minutes))
        return "\(max(1, mins)) 分钟"
    }
}
