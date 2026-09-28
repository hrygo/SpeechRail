import SwiftUI

/// 读法标注窗口。
///
/// 提词器的对齐靠识别器听到的词，但有些词它稳定听错——产品名、内部术语、
/// 人名地名。读者可以在这里登记「屏幕上写 A，我实际念 B」，跟随时按 B 去匹配，
/// 屏幕上的正文、导出与逐字记录一个字都不改。
///
/// 一条读法只绑定到段落里的一处出现位置，所以同一个词在一段里出现多次时
/// 必须由读者指明是哪一处，这里不猜。
public struct TeleprompterReadingAliasSheet: View {
    @Bindable var session: TeleprompterSession
    @Environment(\.dismiss) private var dismiss

    @State private var selectedSegmentID: String?
    @State private var displayTermInput: String = ""
    @State private var spokenTextInput: String = ""
    @State private var message: TeleprompterReadingAliasMessage?

    public init(session: TeleprompterSession) {
        self.session = session
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.gutter) {
            header
            segmentPicker
            segmentPreview
            existingReadings
            addReadingForm
            Spacer(minLength: 0)
            footerActions
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .frame(
            minWidth: SpeechRailDesignTokens.Teleprompter.readingAliasSheetMinimumWidth,
            idealWidth: SpeechRailDesignTokens.Teleprompter.readingAliasSheetWidth,
            maxWidth: SpeechRailDesignTokens.Teleprompter.readingAliasSheetMaximumWidth,
            minHeight: SpeechRailDesignTokens.Teleprompter.readingAliasSheetMinimumHeight,
            idealHeight: SpeechRailDesignTokens.Teleprompter.readingAliasSheetHeight,
            maxHeight: SpeechRailDesignTokens.Teleprompter.readingAliasSheetMaximumHeight
        )
        .onAppear {
            if selectedSegmentID == nil {
                selectedSegmentID = session.currentSegment?.id
                    ?? session.activeVersion?.segments.first?.id
            }
        }
    }

    // MARK: - 头部说明

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text("读法标注")
                    .font(SpeechRailDesignTokens.Typography.display)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)

                Text("有些词识别器会稳定听错。登记你实际会念的说法，跟读时按它匹配，屏幕上的正文不变。")
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

    // MARK: - 段落选择

    private var segmentPicker: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            Text("在哪一段")
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

            Picker("在哪一段", selection: selectedSegmentBinding) {
                ForEach(segments) { segment in
                    Text(segmentLabel(for: segment)).tag(Optional(segment.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .speechRailPointerCursor()
            .accessibilityLabel("选择要标注读法的段落")
            .accessibilityHint("切换段落后，下面的正文与已登记的读法会跟着变")
        }
    }

    private var selectedSegmentBinding: Binding<String?> {
        Binding(
            get: { selectedSegmentID },
            set: { newValue in
                selectedSegmentID = newValue
                // 换段落等于换了一组读法，残留的输入会把词记到错的段落上。
                displayTermInput = ""
                spokenTextInput = ""
                message = nil
            }
        )
    }

    // MARK: - 段落正文

    @ViewBuilder
    private var segmentPreview: some View {
        if let segment = selectedSegment {
            Text(segment.text)
                .font(SpeechRailDesignTokens.Typography.body)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineSpacing(SpeechRailDesignTokens.Teleprompter.previewLineSpacing)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SpeechRailDesignTokens.Spacing.sm)
                .background(
                    SpeechRailDesignTokens.Color.recessedField,
                    in: RoundedRectangle(
                        cornerRadius: SpeechRailDesignTokens.Corner.nested,
                        style: .continuous
                    )
                )
                .accessibilityLabel("这一段的正文")
        }
    }

    // MARK: - 已登记的读法

    @ViewBuilder
    private var existingReadings: some View {
        let readings = selectedSegment?.acceptedReadings ?? []
        if !readings.isEmpty {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text("已登记 \(readings.count) 条")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

                ScrollView {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                        ForEach(readings, id: \.displayRange) { reading in
                            readingRow(reading)
                        }
                    }
                }
                .frame(maxHeight: SpeechRailDesignTokens.Teleprompter.readingAliasListMaximumHeight)
            }
        }
    }

    private func readingRow(_ reading: TeleprompterAcceptedReading) -> some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                Text(reading.displayText)
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Image(systemName: "arrow.right")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        .accessibilityHidden(true)
                    Text(reading.spokenText)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("屏幕上的 \(reading.displayText)，你念作 \(reading.spokenText)")

            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)

            Button {
                guard let segment = selectedSegment else { return }
                if session.removeConfirmedReading(
                    segmentID: segment.id,
                    displayRange: reading.displayRange
                ) {
                    message = nil
                } else {
                    message = .actionFailed
                }
            } label: {
                Text("移除")
                    .font(SpeechRailDesignTokens.Typography.caption)
            }
            .speechRailButton(.secondary)
            .accessibilityLabel("移除 \(reading.displayText) 的读法标注")
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .background(
            SpeechRailDesignTokens.Color.field,
            in: RoundedRectangle(
                cornerRadius: SpeechRailDesignTokens.Corner.nested,
                style: .continuous
            )
        )
    }

    // MARK: - 新增读法

    private var addReadingForm: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            Text("新增一条")
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

            HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.xs) {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                    TextField("屏幕上的词", text: $displayTermInput)
                        .textFieldStyle(.plain)
                        .font(SpeechRailDesignTokens.Typography.body)
                        .speechRailSingleLineInput(.regular)
                        .accessibilityLabel("屏幕上的词")
                        .accessibilityHint("填这一段里你识别不出来的那个词")
                    Text("同一段里出现多次时，请改用更长的词组把它限定到一处。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                    TextField("我会念成", text: $spokenTextInput)
                        .textFieldStyle(.plain)
                        .font(SpeechRailDesignTokens.Typography.body)
                        .speechRailSingleLineInput(.regular)
                        .onSubmit(addReading)
                        .accessibilityLabel("我会念成")
                        .accessibilityHint("填你实际会念出来的说法")
                    Text("数字与单位必须一致：50% 可以标成「百分之五十」，不能标成「大约一半」。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                if let message {
                    TeleprompterReadingAliasMessageView(message: message)
                }
                Spacer()
                Button("添加", action: addReading)
                    .speechRailButton(.primary)
                    .disabled(selectedSegment == nil)
                    .accessibilityHint("把这条读法登记到选中的段落")
            }
        }
    }

    // MARK: - 底部操作栏

    private var footerActions: some View {
        HStack {
            Text("读法只影响跟读时的匹配，不会改动稿件内容。")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            Spacer()
            Button("完成") {
                dismiss()
            }
            .speechRailButton(.secondary)
        }
    }

    // MARK: - 业务辅助

    private var segments: [TeleprompterSegment] {
        session.activeVersion?.segments ?? []
    }

    private var selectedSegment: TeleprompterSegment? {
        guard let selectedSegmentID else { return nil }
        return segments.first { $0.id == selectedSegmentID }
    }

    private func segmentLabel(for segment: TeleprompterSegment) -> String {
        let index = segments.firstIndex { $0.id == segment.id }
        let number = (index ?? 0) + 1
        let preview = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return "#\(String(format: "%02d", number)) \(preview)"
    }

    private func addReading() {
        guard let segment = selectedSegment else { return }
        let rejection = session.confirmReading(
            segmentID: segment.id,
            displayTerm: displayTermInput,
            spokenText: spokenTextInput
        )
        if let rejection {
            message = TeleprompterReadingAliasMessage(rejection: rejection)
            return
        }
        displayTermInput = ""
        spokenTextInput = ""
        message = .added
    }
}

// MARK: - 反馈信息

private enum TeleprompterReadingAliasMessage: Equatable {
    case added
    case actionFailed
    case rejection(TeleprompterAcceptedReadingRejection)

    init(rejection: TeleprompterAcceptedReadingRejection) {
        self = .rejection(rejection)
    }

    var text: String {
        switch self {
        case .added:
            "已登记，跟读时会按这个说法匹配。"
        case .actionFailed:
            "没有保存成功，请重试。"
        case let .rejection(rejection):
            switch rejection {
            case .notEditable:
                "现在不能改读法：舞台还开着或上一步还没收尾。关掉提词窗口后再试。"
            case .segmentUnavailable:
                "找不到这一段内容了，可能稿件已经切换。重新打开窗口再试。"
            case .saveFailed:
                "没有保存成功，稿件内容未改动。检查磁盘空间或文件夹权限后重试。"
            case .rangeOutOfBounds, .displayTextChanged:
                "这段正文已经变了，请重新打开窗口再试。"
            case .emptySpokenText:
                "请填写你实际会念的说法。"
            case .spokenTextTooLong:
                "这个说法太长了，请换一个更贴近实际念法的短词。"
            case .numericValuesDiffer:
                "两边的数字或单位不一致。读法只能改发音，不能改数值。"
            case .overlappingAlias:
                "这一处已经有读法标注了，请先移除再添加。"
            case .termNotFound:
                "这一段里没有找到这个词，请检查拼写或换一段。"
            case let .termAmbiguousOccurrences(count):
                "这一段里有 \(count) 处「这个词」，请用更长的词组把它限定到一处。"
            case .unknownRuleRevision:
                "这条读法由更新版本写入，当前版本无法确认它是否安全，已忽略。"
            }
        }
    }

    var tone: StatusTone {
        switch self {
        case .added: .healthy
        case .actionFailed, .rejection: .attention
        }
    }
}

private struct TeleprompterReadingAliasMessageView: View {
    let message: TeleprompterReadingAliasMessage

    var body: some View {
        Text(message.text)
            .font(SpeechRailDesignTokens.Typography.caption)
            .foregroundStyle(message.tone.color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(message.text)
    }
}
