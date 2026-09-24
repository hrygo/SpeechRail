import SwiftUI

// 说话人标注的界面（`SESSIONS-SPEC` §6.2.1）。
//
// 会中与会后是**同一件事的两种节奏**，所以它们是同一个 `SpeakerLabeling` 的两个视图，
// 不是两套实现：会中点一下就走（`SpeakerChip` 菜单），会后可以批量（`SpeakerLabelingPanel`）。
// 两处都只改显示名与归属列——**正文没有编辑入口**，这条差别必须看得见。

// MARK: - 行内 chip

/// 转录行 / 对话行上的说话人 chip。没有分人标签时**不出现**（不画一个空的"说话人"）。
public struct SpeakerChip: View {
    public let label: String
    public let displayName: String?
    /// 会中：点开就能改名（快，趁还记得）。会后由右栏面板承接批量。
    public let onRename: (@MainActor (String) -> Void)?
    public let onMerge: (@MainActor () -> Void)?

    public init(
        label: String,
        displayName: String?,
        onRename: (@MainActor (String) -> Void)? = nil,
        onMerge: (@MainActor () -> Void)? = nil
    ) {
        self.label = label
        self.displayName = displayName
        self.onRename = onRename
        self.onMerge = onMerge
    }

    public var body: some View {
        let text = SpeakerLabeling.chipText(label: label, displayName: displayName)
        if onRename == nil {
            StatusPill(tone: .neutral, label: text)
        } else {
            Menu {
                Button("改成「我」") { onRename?("我") }
                if let onMerge { Button("合并到上一位…", action: onMerge) }
            } label: {
                StatusPill(tone: .neutral, label: text)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("改说话人的显示名（正文一个字不动）")
        }
    }
}

// MARK: - 标注面板（会后，右栏）

/// 说话人标注面板。会后这是主入口；会中由行内 chip 与表头动作承接同一件事。
///
/// 降级形状是规格里点名的一条：**档位不支持时不出现说话人列表**，只说一句人话，
/// 也不给一个永远点不动的开关（§6.2.1）。
public struct SpeakerLabelingPanel: View {
    @Environment(SessionCoordinator.self) private var session
    @Bindable public var labeling: SpeakerLabeling
    public let sessionID: String
    /// 会中（记录已经在写）与会后（可以批量）的区别只有一处文案与拆出的可用性。
    public let isLive: Bool

    @State private var editingLabel: String?
    @State private var draftName = ""
    @State private var savedNote: String?

    public init(labeling: SpeakerLabeling, sessionID: String, isLive: Bool) {
        self.labeling = labeling
        self.sessionID = sessionID
        self.isLive = isLive
    }

    public var body: some View {
        switch labeling.state {
        case .unavailable:
            unavailable
        case .off:
            off
        case .active, .degraded:
            list
        }
    }

    private var unavailable: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text("这台 Mac 现在的设置不标说话人")
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Text(labeling.note ?? "正文照常记录；换成更准的一档之后，新开的会话就会有说话人。")
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    private var off: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text("这一场没有标说话人")
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Text("正文照常记录。下一次开始前在「实时字幕 / 会议」里打开「说话人标签」，就能在行上看到谁在说。")
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    private var list: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                CardHead(title: isLive ? "标注说话人" : "说话人") { EmptyView() }

                if let note = labeling.note {
                    Text(note)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(labeling.speakers) { speaker in
                    speakerRow(speaker)
                }

                if let savedNote {
                    Text(savedNote)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                }

                Text("改名与合并只改显示名，正文与时间码一个字都不动。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    @ViewBuilder
    private func speakerRow(_ speaker: SpeakerLabeling.Speaker) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                SpeakerChip(label: speaker.label, displayName: speaker.displayName)
                StatusPill(tone: speaker.displayName == nil ? .attention : .neutral, label: speaker.status)
                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                Text("\(speaker.lineCount) 段")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                Button {
                    editingLabel = speaker.label
                    draftName = speaker.displayName ?? ""
                } label: {
                    RowActionGlyph(.edit)
                }
                .speechRailButton(.quiet)
                .accessibilityLabel("改 \(SpeakerLabeling.chipText(label: speaker.label, displayName: speaker.displayName)) 的名字")
            }

            if editingLabel == speaker.label {
                editor(for: speaker)
            } else {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Button("标记为「我」") {
                        Task { await labeling.markAsMe(label: speaker.label) }
                    }
                    .buttonStyle(.link)
                    .speechRailPointerCursor()

                    let others = labeling.speakers.filter { $0.label != speaker.label }
                    if let target = others.first {
                        Button("与 \(target.label) 合并") {
                            Task { await labeling.merge(label: speaker.label, into: target.label) }
                        }
                        .buttonStyle(.link)
                        .speechRailPointerCursor()
                        .help("这两个标签的行都保留；合并只改显示名，可回溯")
                    }
                    if let suggestion = speaker.suggestedMergeInto, others.contains(where: { $0.label == suggestion }) {
                        Text("服务端认为它可能是 \(suggestion)")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    }
                }
            }
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.hairline)
    }

    @ViewBuilder
    private func editor(for speaker: SpeakerLabeling.Speaker) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                TextField("这位是谁？", text: $draftName)
                    .textFieldStyle(.plain)
                    .speechRailSingleLineInput(.regular)
                    .frame(minWidth: 120)
                    .onSubmit { Task { await save(speaker) } }
                Button("保存") { Task { await save(speaker) } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .speechRailPointerCursor()
                Button("取消") { editingLabel = nil }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .speechRailPointerCursor()
            }

            let existing = Array(Set(labeling.speakers.compactMap(\.displayName))).sorted()
            if !existing.isEmpty {
                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Text("已有：")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    ForEach(existing, id: \.self) { name in
                        Button(name) { draftName = name }
                            .buttonStyle(.link)
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .speechRailPointerCursor()
                    }
                }
            }
        }
        .padding(.top, SpeechRailDesignTokens.Spacing.micro)
    }

    private func save(_ speaker: SpeakerLabeling.Speaker) async {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            editingLabel = nil
            return
        }
        await labeling.rename(label: speaker.label, to: name)
        editingLabel = nil
        savedNote = "已保存：\(speaker.label) → \(name)。正文没有改动。"
    }
}
