import SwiftUI

/// 纪要核对（MA-11 / MC-46～MC-48、MC-73）。
///
/// 这一页的形状由三件事决定：
/// - **先读完整纪要，再谈疑点**。默认进来看到的是全文，不是待办清单——
///   只把疑点摊在首屏，等于替用户判断哪句话不用看。
/// - **编辑框是编辑框**。输入控件是 first responder 时，会话级快捷键一律不生效
///   （MC-73）：中文输入法选词按的那一下回车，不该顺手把纪要存了或采用了。
/// - **存不上要说"没存上"，不是"你的内容没了"**。草稿留在屏幕上，
///   失败提示给一个能继续的下一步（MC-47）。
struct MinutesReviewView: View {
    @State private var model: MinutesReviewModel
    @FocusState private var editorFocused: Bool
    /// 中文输入法组字中。SwiftUI 没有直接暴露这个状态，
    /// 由外层输入法适配层在需要时覆盖——这里留出接口而不是假装测不到。
    @State private var isComposing = false
    /// 「补充说明」面板。空字符串 = 没打开。
    @State private var supplementDraft = ""
    @State private var supplementSheetPresented = false

    init(coordinator: SessionCoordinator, sessionID: String, version: MinutesVersion) {
        _model = State(initialValue: MinutesReviewModel(
            coordinator: coordinator, sessionID: sessionID, version: version
        ))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            editor
            Divider()
            actionBar
        }
        .sheet(isPresented: $supplementSheetPresented) { supplementSheet }
    }

    /// 补一段用户自己的话。**先说清会发生什么**：另存一版、标成「你补充」、
    /// **不给它安转录来源**——不能当成会上说过的话。
    private var supplementSheet: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Text("补充一段说明")
                .font(.headline)
            Text("这段会作为「你补充」另存为一版。它没有转录来源，所以不会挂引用——不能当成会上说过的话。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $supplementDraft)
                .font(.body)
                .frame(minHeight: 140)
                .accessibilityLabel("补充说明正文")
            HStack {
                Spacer()
                Button("取消", role: .cancel) { supplementSheetPresented = false }
                Button("补充") {
                    Task { if await model.supplement(supplementDraft) { supplementSheetPresented = false } }
                }
                .disabled(
                    supplementDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.isSaving
                )
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(SpeechRailDesignTokens.Layout.contentPadding)
        .frame(minWidth: 420, minHeight: 300, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            // 说出处，不用让用户猜哪一段是模型写的。
            Text(model.originSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
            if model.originChanged {
                // 改过之后出处变了，这句话必须跟着变。
                Text("已存为新的一版，AI 原来那一版仍然保留。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            statusLine
            if let comparison = model.comparison, !comparison.isIdentical {
                // 差异常驻，但不抢首屏：用户要回答的是"我改了什么"。
                DisclosureGroup("与打开时的版本对比：\(comparison.summary)") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(comparison.lines.enumerated()), id: \.offset) { _, line in
                            diffRow(line)
                        }
                    }
                    .padding(.top, SpeechRailDesignTokens.Spacing.xs)
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Layout.contentPadding)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        .task { await model.loadLineage() }
    }

    /// 增删用颜色和符号**两处**表达，不靠颜色单独承载信息。
    @ViewBuilder
    private func diffRow(_ line: MinutesVersionDiff.LineChange) -> some View {
        switch line {
        case .unchanged(let text):
            Text(text).foregroundStyle(.secondary)
        case .added(let text):
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("+").foregroundStyle(.green).accessibilityHidden(true)
                Text(text)
            }
            .accessibilityLabel("新增：\(text)")
        case .removed(let text):
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("−").foregroundStyle(.red).accessibilityHidden(true)
                Text(text)
            }
            .accessibilityLabel("删除：\(text)")
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let failure = model.saveFailure {
            // 说清当前问题和有效出口，不堆一串可能的原因。
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("没存上，你写的内容还在屏幕上。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("重试") { Task { _ = await model.save() } }
                    .buttonStyle(.link)
                    .font(.caption)
                Spacer(minLength: 0)
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("没存上，草稿仍然保留在编辑框里。可以重试。")
        } else if model.hasUnsavedChanges {
            Text("还有改动没存。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if model.isSaving {
            Text("正在存…").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var editor: some View {
        // 编辑控件拿到焦点时，会话级快捷键不参与——MC-73 的落点就在这个 focused 绑定上。
        TextEditor(text: Binding(
            get: { model.draft },
            set: { model.update($0) }
        ))
        .focused($editorFocused)
        .font(.body)
        .scrollContentBackground(.hidden)
        .padding(SpeechRailDesignTokens.Spacing.md)
        .accessibilityLabel("纪要正文")
        .accessibilityHint("改完按保存。会另存为一版，AI 原来那一版仍然保留。")
        .onChange(of: editorFocused) { _, focused in
            // 焦点进出编辑框时，界面要跟着切换"能不能用会话级快捷键"。
            NotificationCenter.default.post(
                name: .speechRailTextInputFocusChanged,
                object: focused
            )
        }
    }

    private var actionBar: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            Button("撤销") { model.revertToLastSaved() }
                .disabled(!model.hasUnsavedChanges)
                .help("回到上一次成功存进去的内容")
            Button("补充说明…") {
                supplementDraft = ""
                supplementSheetPresented = true
            }
            .disabled(model.isSaving || model.hasUnsavedChanges)
            .help(
                model.hasUnsavedChanges
                    ? "先把当前改动存下来，再补说明"
                    : "补一段你自己写的话，另存为一版"
            )
            Button(model.isSaving ? "正在存…" : "保存") {
                Task { _ = await model.save() }
            }
            .disabled(model.isSaving || !model.hasUnsavedChanges)
            .keyboardShortcut("s", modifiers: .command)
            .help("另存为一版，AI 原来那一版仍然保留")

            Spacer()

            // 组字中不弹确认层：用户在选词，不是在结束什么。
            Button("采用这一版") {
                guard ReviewShortcutPolicy.shouldPresentConfirm(isComposing: isComposing) else { return }
                Task { await model.adopt() }
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .help("把这一版设为当前采用的纪要")
        }
        .controlSize(.large)
        .padding(.horizontal, SpeechRailDesignTokens.Layout.contentPadding)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
    }
}

extension Notification.Name {
    /// 编辑框焦点变化。会话级快捷键据此让路（MC-73）。
    static let speechRailTextInputFocusChanged = Notification.Name("SpeechRailTextInputFocusChanged")
}
