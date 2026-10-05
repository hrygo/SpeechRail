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

    private let onAdopt: (String) async throws -> Bool

    init(
        coordinator: SessionCoordinator,
        sessionID: String,
        version: MinutesVersion,
        onAdopt: @escaping (String) async throws -> Bool
    ) {
        _model = State(initialValue: MinutesReviewModel(
            coordinator: coordinator, sessionID: sessionID, version: version
        ))
        self.onAdopt = onAdopt
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            editor
            Divider()
            actionBar
        }
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
        }
        .padding(.horizontal, SpeechRailDesignTokens.Layout.contentPadding)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
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
                Task {
                    let body = model.draft
                    _ = try? await onAdopt(body)
                }
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
