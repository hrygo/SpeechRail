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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable public var session: InnerOSSession
    public let sessionID: String?

    @State private var question = ""
    @State private var selectedExchangeID: String?
    /// 正在挑句子的那条问答（MC-43）。挑句界面是**一层**而不是常驻控件——
    /// 多数答案用户就是想整条写进，逐句勾选属于高级操作。
    @State private var pickingSentencesFor: InnerOSExchange?
    @State private var pickedSentences: Set<Int> = []

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
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.18),
            value: session.isExpanded
        )
        .sheet(item: $pickingSentencesFor) { exchange in
            sentencePicker(for: exchange)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("内心 OS。会议中随时私下问它一句，只有你看得到：这里的提问与回答不会进入会议录音、文字记录或纪要。")
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
                    // 「内心 OS」是这一版的叫法（沿用 Sona）；名字本身不解释用途，
                    // 所以紧跟一句人话说明它**干什么**（用户 2026-09-19：界面要说人话）。
                    Text("随时私下问它一句 · 只你可见")
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
            .help("会议进行中随时问它一句话（比如「刚才那个数字是多少」）；答案只有你看得到，不会进会议音频、文字记录或纪要。")
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
                TextField("问点什么（它只看这一场的文字记录，不联网）", text: $question)
                    .textFieldStyle(.plain)
                    .speechRailSingleLineInput(.regular)
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
            Text("追问接着上一问的上下文；回答不会进会议音频与文字记录，"
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
        if exchange.inMinutes {
            // 说了"已写进纪要"就得让人知道**哪些**进去了。整条与只挑了几句
            // 是两种不同的东西，混成同一枚标签等于让用户回头重读自己的答案。
            parts.append(exchange.minutesExcerpt == nil ? "已写进纪要" : "已写进纪要（只一部分）")
        }
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
                        // 用户挑句之后，这里必须回显**真正写进去的是哪几句**。
                        // 只在答案卡里标一枚"已写进纪要"是不够的：整段答案还
                        // 留在上面，用户无从知道另外那半句已经没进去。
                        if let excerpt = exchange.minutesExcerpt, !excerpt.isEmpty {
                            labelled("已写进纪要的句子", excerpt)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                    // 写失败必须看得见：这个标签是用户判断"这句到底进没进去"的唯一依据，
                    // 静默失败等于让他按一个没生效的开关。
                    if let error = session.supplementError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("写进纪要失败：\(error)")
                    }
                    actions(exchange)
                }
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
                // 撤回是**同一个动作的另一半**，不是高级功能：勾错了要能改，
                // 而不是只能重新封存一场会。
                Button("撤回") {
                    Task { await session.excludeFromMinutes(exchangeID: exchange.id) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("这一句不写进纪要")
                Button("改选句子") { beginPickingSentences(for: exchange) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("换一批句子写进纪要")
            } else {
                Button("写进纪要") { beginPickingSentences(for: exchange) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("把这句作为补充写进纪要；只选需要的句子，它不是会上说的话，会标成「AI 补充」")
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func evidenceSection(_ exchange: InnerOSExchange) -> some View {
        let rows = session.evidence[exchange.id] ?? []
        if rows.isEmpty {
            // 没有证据就说没有证据——这是"我不知道"唯一有用的说法（§5.9）。
            labelled("证据", "文字记录里没有能支撑这一问的内容。")
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

    // MARK: - 挑句子（MC-43）

    /// 打开挑句界面。**默认全选**：绝大多数答案用户就是想整条写进，
    /// 一进来就摆一堆空勾选框等于逼他先做一遍没必要的判断。
    private func beginPickingSentences(for exchange: InnerOSExchange) {
        pickedSentences = Set(InnerOSSession.selectableSentences(in: exchange.answerText ?? "").indices)
        pickingSentencesFor = exchange
    }

    /// 全选时按"整条"写（`excerpt = nil`），只有真的选了子集才记下是哪几句。
    /// 写库那侧把 `nil` 读成整段，与迁移前的行是同一条路径。
    private func confirmSentenceSelection(for exchange: InnerOSExchange) {
        let sentences = InnerOSSession.selectableSentences(in: exchange.answerText ?? "")
        let all = Set(sentences.indices)
        let excerpt: String? = (pickedSentences == all)
            ? nil
            : sentences.indices.filter { pickedSentences.contains($0) }
                .map { sentences[$0] }
                .joined(separator: "\n")
        pickingSentencesFor = nil
        Task { await session.includeInMinutes(exchangeID: exchange.id, excerpt: excerpt) }
    }

    private func sentencePicker(for exchange: InnerOSExchange) -> some View {
        let sentences = InnerOSSession.selectableSentences(in: exchange.answerText ?? "")
        return VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Text("写进纪要哪几句")
                .font(.headline)
            Text("只勾你想要的句子。没勾的不会进纪要，也不会写进这次会议的存档。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                    ForEach(Array(sentences.enumerated()), id: \.offset) { index, sentence in
                        Toggle(isOn: Binding(
                            get: { pickedSentences.contains(index) },
                            set: { on in
                                if on { pickedSentences.insert(index) } else { pickedSentences.remove(index) }
                            }
                        )) {
                            Text(sentence)
                                .font(.body)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(maxHeight: 260)
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Button(pickedSentences.count == sentences.count ? "取消全选" : "全选") {
                    pickedSentences = pickedSentences.count == sentences.count
                        ? []
                        : Set(sentences.indices)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
                Button("取消", role: .cancel) { pickingSentencesFor = nil }
                Button("写进纪要") { confirmSentenceSelection(for: exchange) }
                    .disabled(pickedSentences.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(SpeechRailDesignTokens.Layout.contentPadding)
        .frame(minWidth: 420, minHeight: 320, alignment: .leading)
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
        session.ask(
            text,
            resolvedConfiguration: preferences.resolvedLLMConfiguration(for: .assistant)
        )
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
