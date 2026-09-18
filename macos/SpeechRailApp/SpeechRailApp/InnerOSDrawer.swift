import AppKit
import SwiftUI

// 内心 OS 的抽屉（`SESSIONS-SPEC` §14.2 的"形态"那一行，第八轮的"非主框体可收起"）。
//
// 它是**组件不是模式**：
//   · 收起态是贴底的一行，常驻但几乎不占地方——`内心 OS` + `只你可见` +
//     `已问 N 次 · M 条已写进纪要` + 快捷键 + chevron；
//   · 展开态是两栏：左本场问答历史 + 输入框，右是答案卡（证据 / 不确定度 / 可直接念的措辞）。
//
// 收起态里那句数字必须**兑现**：既然写着"已问 3 次"，展开就得看得到那 3 条，
// 否则用户没法追问"刚才你那条"（§14.2「为什么要有历史」）。
//
// 两条无障碍口径（§3.8）：区域带"只有你看得到"的描述；证据的引用可被读屏取到。

public struct InnerOSDrawer: View {
    @Environment(SessionPreferences.self) private var preferences
    @Bindable public var session: InnerOSSession
    public let sessionID: String?

    @State private var question = ""
    @State private var selectedExchangeID: String?

    public init(session: InnerOSSession, sessionID: String?) {
        self.session = session
        self.sessionID = sessionID
    }

    /// 展开的高度是**有上界的一次性尺寸**：再高就会把转录挤出视野，
    /// 而那正好与"边听边记"的用法相反。
    private static let expandedHeight = SpeechRailDesignTokens.Layout.innerOSDrawerExpandedHeight
    private static let historyColumnWidth = SpeechRailDesignTokens.Layout.innerOSHistoryColumnWidth

    public var body: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 0) {
                header
                if session.isExpanded {
                    Divider()
                    HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.gutter) {
                        history
                        answerCard
                    }
                    .padding(SpeechRailDesignTokens.Spacing.md)
                    .frame(height: Self.expandedHeight, alignment: .top)
                }
            }
        }
        .animation(.smooth(duration: 0.18), value: session.isExpanded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("内心 OS。只有你看得到：这里的提问与回答不会进入会议录音、转录或纪要。")
        .onChange(of: session.exchanges.count) { _, _ in
            if selectedExchangeID == nil { selectedExchangeID = session.exchanges.last?.id }
        }
    }

    // MARK: - 收起 / 展开

    private var header: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Button {
                session.isExpanded.toggle()
            } label: {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Image(systemName: "eye.slash")
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .accessibilityHidden(true)
                    Text("内心 OS").font(SpeechRailDesignTokens.Typography.bodyMedium)
                    Text("只你可见")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    Text("已问 \(session.askedCount) 次 · \(session.inMinutesCount) 条已写进纪要")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    Text("⌘⇧I")
                        .font(SpeechRailDesignTokens.Typography.secondary)
                        .opacity(SpeechRailDesignTokens.Button.shortcutOpacity)
                        .accessibilityHidden(true)
                    Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .speechRailPointerCursor()
            .accessibilityValue(session.isExpanded ? "已展开" : "已收起")
            Button {
                session.isExpanded.toggle()
            } label: {
                Image(systemName: session.isExpanded ? "chevron.down" : "chevron.up")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(session.isExpanded ? "收起内心 OS" : "展开内心 OS")
            .speechRailPointerCursor()
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
    }

    // MARK: - 左：本场问答历史 + 输入

    private var history: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            Text("本场问过的")
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                    if session.exchanges.isEmpty {
                        Text("还没有问过。这里只有你能看到。")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    }
                    ForEach(session.exchanges) { exchange in
                        historyRow(exchange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                // 占位文案按稿：说清"它只看哪一份上下文"，也是这一栏与助手页的区别。
                TextField("问点什么（它只看这一场的转录，不联网）", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send() }
                if session.state == .generating {
                    Button("取消") { session.cancel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button("问") { send() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Text("追问接着上一问的上下文；回答不会进会议音频与转录，"
                + "想让它写进纪要得点一下「写进纪要」。")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: Self.historyColumnWidth, alignment: .topLeading)
    }

    private func historyRow(_ exchange: InnerOSExchange) -> some View {
        Button {
            selectedExchangeID = exchange.id
        } label: {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.hairline) {
                Text(exchange.question)
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(statusLine(exchange))
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SpeechRailDesignTokens.Spacing.xs)
            .background(
                exchange.id == selectedExchangeID
                    ? SpeechRailDesignTokens.Surface.selectionTint
                    : Color.clear,
                in: SpeechRailDesignTokens.Corner.controlShape
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .speechRailPointerCursor()
    }

    private func statusLine(_ exchange: InnerOSExchange) -> String {
        var parts: [String] = []
        switch exchange.status {
        case .generating: parts.append("在答…")
        case .failed: parts.append("没答出来")
        case .cancelled: parts.append("已取消")
        case .ready:
            let count = session.evidence[exchange.id]?.count ?? 0
            parts.append(count > 0 ? "已答 · \(count) 处证据" : "已答 · 没有证据")
        }
        if exchange.inMinutes { parts.append("已写进纪要") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 右：答案卡

    @ViewBuilder
    private var answerCard: some View {
        if let exchange = selectedExchange {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Text(exchange.question)
                        .font(SpeechRailDesignTokens.Typography.bodyMedium)
                        .lineLimit(2)
                    Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                    if let confidence = exchange.confidence {
                        StatusPill(tone: tone(for: confidence), label: confidence.label)
                    }
                }
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                        evidenceSection(exchange)
                        if let answer = exchange.answerText, !answer.isEmpty {
                            labelled("事实与判断", answer)
                        }
                        if let draft = exchange.draftText, !draft.isEmpty {
                            labelled("可以直接念的措辞", "「\(draft)」")
                        }
                        if let limits = exchange.limitsNote, !limits.isEmpty {
                            labelled("限制", limits)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                actions(exchange)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        } else {
            Text("左边点一条问题，答案就出现在这里。")
                .font(SpeechRailDesignTokens.Typography.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func actions(_ exchange: InnerOSExchange) -> some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Button("继续追问") { question = "" }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("复制") { copy(exchange) }
                .buttonStyle(.bordered)
                .controlSize(.small)
            if exchange.inMinutes {
                StatusPill(tone: .healthy, label: "已写进纪要")
            } else {
                Button("写进纪要") {
                    Task { await session.includeInMinutes(exchangeID: exchange.id) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func evidenceSection(_ exchange: InnerOSExchange) -> some View {
        let rows = session.evidence[exchange.id] ?? []
        if rows.isEmpty {
            // 没有证据就说没有证据——这是"我不知道"唯一有用的说法（§5.9）。
            labelled("证据", "转录里没有能支撑这一问的内容。")
        } else {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text("证据")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        if let start = row.tStart {
                            Text(Self.timecode(start))
                                .font(SpeechRailDesignTokens.Typography.technicalValue)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        }
                        Text("「\(row.quote ?? "")」")
                            .font(SpeechRailDesignTokens.Typography.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func labelled(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.hairline) {
            Text(title)
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            Text(body)
                .font(SpeechRailDesignTokens.Typography.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var selectedExchange: InnerOSExchange? {
        if let selectedExchangeID,
           let match = session.exchanges.first(where: { $0.id == selectedExchangeID }) {
            return match
        }
        return session.exchanges.last
    }

    private func tone(for confidence: InnerOSConfidence) -> StatusTone {
        switch confidence {
        case .high: .healthy
        case .medium, .low: .attention
        }
    }

    private func send() {
        let text = question
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        question = ""
        session.ask(text, configuration: preferences.llmConfiguration)
    }

    private func copy(_ exchange: InnerOSExchange) {
        var parts: [String] = []
        if let answer = exchange.answerText { parts.append(answer) }
        if let draft = exchange.draftText { parts.append("可直接念：\(draft)") }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(parts.joined(separator: "\n"), forType: .string)
    }

    private static func timecode(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
