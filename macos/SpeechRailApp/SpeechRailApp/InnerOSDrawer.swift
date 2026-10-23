import AppKit
import SwiftUI

// 内心 OS 的抽屉（`SESSIONS-SPEC` §14.2 的"形态"那一行，第八轮的"非主框体可收起"）。
//
// 它是**组件不是模式**：
//   · 收起态是贴底的一行，常驻但几乎不占地方——`会中私聊` + `仅你可见` +
//     `已问 N 次 · M 条已写进纪要` + 快捷键 + chevron；
//   · 展开态上方为问答工作区（空态提供快捷提问引导；有问答时左栏为提问历史、右栏为结构化答案卡），
//     下方为独立的通栏提问输入栏。
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
    @State private var copyFailure: String?
    @State private var copyNoticeID = UUID()
    @State private var copiedFeedback: (exchangeID: String, label: String)?
    @FocusState private var isQuestionFieldFocused: Bool

    public init(session: InnerOSSession, sessionID: String?) {
        self.session = session
        self.sessionID = sessionID
    }

    /// 展开后问答主区的高度上限（底部通栏输入带独立排布）：
    /// 兼顾左侧历史与右侧结构化回答卡的阅读空间，同时不把上方实时转录挤出视野。
    private static let expandedHeight = SpeechRailDesignTokens.Layout.innerOSDrawerExpandedHeight
    private static let historyColumnWidth = SpeechRailDesignTokens.Layout.innerOSHistoryColumnWidth

    public var body: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 0) {
                header
                if session.isExpanded {
                    SessionHairline()
                    if session.exchanges.isEmpty {
                        emptyWorkspace
                            .frame(height: Self.expandedHeight, alignment: .topLeading)
                    } else {
                        HStack(alignment: .top, spacing: 0) {
                            historyColumn
                            Rectangle()
                                .fill(SpeechRailDesignTokens.Surface.border)
                                .frame(width: SpeechRailDesignTokens.Spacing.hairline)
                                .frame(maxHeight: .infinity)
                            answerCard
                        }
                        .frame(height: Self.expandedHeight, alignment: .top)
                    }
                    SessionHairline()
                    composerBar
                }
            }
        }
        .animation(
            SpeechRailDesignTokens.Motion.resolved(SpeechRailDesignTokens.Motion.smoothTransition, reduceMotion: reduceMotion),
            value: session.isExpanded
        )
        .sheet(item: $pickingSentencesFor) { exchange in
            sentencePicker(for: exchange)
        }
        .operationFeedback([
            OperationFeedback(session.supplementError, title: "纪要未更新"),
            OperationFeedback(copyFailure, title: "复制未完成", onDismiss: { copyFailure = nil }),
            OperationFeedback(copiedFeedback?.label, tone: .healthy, title: "已复制", id: copyNoticeID.uuidString, autoDismiss: true,
                              onDismiss: { copiedFeedback = nil })
        ])
        .accessibilityElement(children: .contain)
        .accessibilityLabel("会中私聊。会议中随时私下向助手提问，仅你看得到：这里的提问与回答不会进入会议录音、文字记录或纪要。")
        .onChange(of: session.exchanges.count) { oldCount, newCount in
            if newCount > oldCount || selectedExchangeID == nil {
                selectedExchangeID = session.exchanges.last?.id
            }
        }
        .onChange(of: session.isExpanded) { _, expanded in
            if expanded {
                isQuestionFieldFocused = true
            }
        }
    }

    // MARK: - 收起 / 展开顶栏

    private var header: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            Button {
                session.isExpanded.toggle()
            } label: {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Image(systemName: "eye.slash.fill")
                        .font(SpeechRailDesignTokens.Typography.captionMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                        .accessibilityHidden(true)
                    Text("会中私聊")
                        .font(SpeechRailDesignTokens.Typography.bodyMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    StatusPill(tone: .neutral, label: "私下提问 · 仅你可见")

                    if session.state == .generating {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在思考…")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        }
                    } else if session.askedCount > 0 {
                        Text("已问 \(session.askedCount) 次 · \(session.inMinutesCount) 条已写进纪要")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            .monospacedDigit()
                    } else {
                        Text("仅参考本场已确认记录，不入录音与公开正文")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                    SessionKeycap("⌘⇧I")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .speechRailPointerCursor()
            .help("会议进行中随时向助手私下提问；答案只有你看得到，不会进入会议音频、文字记录或公开纪要。")
            .accessibilityValue(session.isExpanded ? "已展开" : "已收起")

            Button {
                session.isExpanded.toggle()
            } label: {
                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Text(session.isExpanded ? "收起" : "展开提问")
                        .font(SpeechRailDesignTokens.Typography.captionMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    Image(systemName: session.isExpanded ? "chevron.down" : "chevron.up")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
                .background(
                    SpeechRailDesignTokens.Color.recessedField,
                    in: SpeechRailDesignTokens.Corner.compactShape
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(session.isExpanded ? "收起会中私聊" : "展开会中私聊")
            .speechRailPointerCursor()
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
    }

    // MARK: - 空态工作区（尚未提问时提供快捷提问胶囊）

    private var emptyWorkspace: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text("在会议进行中随时向助手私下发问")
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Text("提问与回答仅你可见，只依据本场已确认的文字记录作答（不联网猜测、不混入会议转录）。如果某句分析或措辞对会后有用，可随时勾选「写进纪要」。")
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text("常用会中提问（点击直接发问）")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                WrapHStack(spacing: SpeechRailDesignTokens.Spacing.xs, lineSpacing: SpeechRailDesignTokens.Spacing.xs) {
                    ForEach(InnerOSQuickPrompt.defaults) { item in
                        quickPromptChip(item)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(SpeechRailDesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func quickPromptChip(_ item: InnerOSQuickPrompt) -> some View {
        Button {
            askPrompt(item.prompt)
        } label: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                Image(systemName: item.icon)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                    .accessibilityHidden(true)
                Text(item.title)
                    .font(SpeechRailDesignTokens.Typography.calloutMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.compact)
            .background(
                SpeechRailDesignTokens.Color.recessedField,
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(SpeechRailDesignTokens.Color.separator, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
            )
        }
        .buttonStyle(.plain)
        .disabled(sessionID == nil || session.state == .generating)
        .speechRailPointerCursor()
        .help(item.prompt)
        .accessibilityLabel("快捷提问：\(item.title)")
    }

    // MARK: - 左栏：本场提问历史列表

    private var historyColumn: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text("本场提问（\(session.exchanges.count)）")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .monospacedDigit()
                Spacer(minLength: 0)
                Menu {
                    ForEach(InnerOSQuickPrompt.defaults) { item in
                        Button {
                            askPrompt(item.prompt)
                        } label: {
                            Label(item.title, systemImage: item.icon)
                        }
                    }
                } label: {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.tight) {
                        Image(systemName: "sparkles")
                            .font(SpeechRailDesignTokens.Typography.chipIcon)
                        Text("快捷问")
                            .font(SpeechRailDesignTokens.Typography.captionMedium)
                    }
                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(sessionID == nil || session.state == .generating)
                .help("使用预设的会中高频问题快速提问")
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
            .padding(.top, SpeechRailDesignTokens.Spacing.sm)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                    ForEach(session.exchanges) { exchange in
                        historyRow(exchange)
                    }
                }
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                .padding(.bottom, SpeechRailDesignTokens.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: Self.historyColumnWidth, alignment: .topLeading)
    }

    private func historyRow(_ exchange: InnerOSExchange) -> some View {
        let isSelected = exchange.id == (selectedExchange?.id)
        return Button {
            selectedExchangeID = exchange.id
        } label: {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                Text(exchange.question)
                    .font(isSelected ? SpeechRailDesignTokens.Typography.calloutMedium : SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    if exchange.status == .generating {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(statusLine(exchange))
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(
                            exchange.inMinutes
                                ? SpeechRailDesignTokens.Color.ready
                                : SpeechRailDesignTokens.Color.inkTertiary
                        )
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.compact)
            .background(
                isSelected
                    ? SpeechRailDesignTokens.Surface.selectionTint
                    : Color.clear,
                in: SpeechRailDesignTokens.Corner.controlShape
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .speechRailPointerCursor()
        .accessibilityValue(isSelected ? "已选中" : "未选中")
    }

    private func statusLine(_ exchange: InnerOSExchange) -> String {
        var parts: [String] = []
        switch exchange.status {
        case .generating: parts.append("正在回答…")
        case .failed: parts.append("未能生成回答")
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

    // MARK: - 右栏：结构化答案卡

    @ViewBuilder
    private var answerCard: some View {
        if let exchange = selectedExchange {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                // 答案卡头部：问题标题 + 置信度胶囊 + 纪要/复制操作栏
                HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Text(exchange.question)
                        .font(SpeechRailDesignTokens.Typography.bodyMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let confidence = exchange.confidence {
                        StatusPill(tone: tone(for: confidence), label: confidence.label)
                    }
                    Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                    if exchange.status == .ready {
                        actions(exchange)
                    }
                }

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                        switch exchange.status {
                        case .generating:
                            generatingExchangeView
                        case .failed:
                            failedExchangeView(exchange)
                        case .cancelled:
                            cancelledExchangeView(exchange)
                        case .ready:
                            readyExchangeContent(exchange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)

            }
            .padding(SpeechRailDesignTokens.Spacing.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Text("左边点一条问题，答案就出现在这里。")
                .font(SpeechRailDesignTokens.Typography.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                .padding(SpeechRailDesignTokens.Spacing.md)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var generatingExchangeView: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                Text("正在检索本场会议记录并生成回答…")
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Text("你可以继续听会，回答生成后会自动显示在这里；录音与实时文字记录不受影响。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(SpeechRailDesignTokens.Spacing.sm)
        .background(
            SpeechRailDesignTokens.Color.recessedField,
            in: SpeechRailDesignTokens.Corner.controlShape
        )
    }

    private func failedExchangeView(_ exchange: InnerOSExchange) -> some View {
        HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                Text("未能完成这一问")
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Text(exchange.limitsNote ?? session.lastFailure ?? "模型请求未成功返回，请检查会话模型设置或稍后重试。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
            Button("重新提问") {
                askPrompt(exchange.question)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .speechRailPointerCursor()
        }
        .padding(SpeechRailDesignTokens.Spacing.sm)
        .background(
            SpeechRailDesignTokens.Color.recessedField,
            in: SpeechRailDesignTokens.Corner.controlShape
        )
    }

    private func cancelledExchangeView(_ exchange: InnerOSExchange) -> some View {
        HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Image(systemName: "stop.circle")
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                .accessibilityHidden(true)
            Text(exchange.limitsNote ?? "这一问已取消，没有写进答案。")
                .font(SpeechRailDesignTokens.Typography.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
            Button("重新提问") {
                askPrompt(exchange.question)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .speechRailPointerCursor()
        }
        .padding(SpeechRailDesignTokens.Spacing.sm)
        .background(
            SpeechRailDesignTokens.Color.recessedField,
            in: SpeechRailDesignTokens.Corner.controlShape
        )
    }

    @ViewBuilder
    private func readyExchangeContent(_ exchange: InnerOSExchange) -> some View {
        // 1. 可直接念的措辞高亮卡（会中最急需一眼扫到并念出来的内容置顶）
        if let draft = exchange.draftText, !draft.isEmpty {
            draftCalloutCard(exchange: exchange, draft: draft)
        }
        // 2. 事实与判断
        if let answer = exchange.answerText, !answer.isEmpty {
            labelled("事实与判断", answer)
        }
        // 3. 原文证据引用
        evidenceSection(exchange)
        // 4. 限制说明与已写进纪要的句子回显
        if let limits = exchange.limitsNote, !limits.isEmpty {
            labelled("限制", limits)
        }
        if let excerpt = exchange.minutesExcerpt, !excerpt.isEmpty {
            labelled("已写进纪要的句子", excerpt)
        }
    }

    private func draftCalloutCard(exchange: InnerOSExchange, draft: String) -> some View {
        return HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
            SpeechRailDesignTokens.Corner.compactShape
                .fill(SpeechRailDesignTokens.Color.rail)
                .frame(width: SpeechRailDesignTokens.Layout.innerOSDraftAccentBarWidth)

            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Text("可以直接念的措辞")
                        .font(SpeechRailDesignTokens.Typography.captionMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                    Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                    Button {
                        copyText(draft, exchangeID: exchange.id, feedbackLabel: "已复制措辞")
                    } label: {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.tight) {
                            Image(systemName: "doc.on.doc")
                                .font(SpeechRailDesignTokens.Typography.chipIcon)
                            Text("复制措辞")
                                .font(SpeechRailDesignTokens.Typography.captionMedium)
                        }
                        .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                    }
                    .buttonStyle(.plain)
                    .speechRailPointerCursor()
                    .help("仅复制这段可直接念出的发言措辞")
                }
                Text("「\(draft)」")
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .background(
            SpeechRailDesignTokens.Color.rail.opacity(0.08),
            in: SpeechRailDesignTokens.Corner.controlShape
        )
    }

    private func actions(_ exchange: InnerOSExchange) -> some View {
        return HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Button {
                copy(exchange)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .speechRailPointerCursor()

            if exchange.inMinutes {
                StatusPill(
                    tone: .healthy,
                    label: exchange.minutesExcerpt == nil ? "已写进纪要" : "部分已写进纪要"
                )
                // 撤回是**同一个动作的另一半**，不是高级功能：勾错了要能改，
                // 而不是只能重新封存一场会。
                Button("改选句子") { beginPickingSentences(for: exchange) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .speechRailPointerCursor()
                    .help("换一批句子写进纪要")
                Button("撤回") {
                    Task { await session.excludeFromMinutes(exchangeID: exchange.id) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .speechRailPointerCursor()
                .help("这一句不写进纪要")
            } else {
                Button("写进纪要") { beginPickingSentences(for: exchange) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .speechRailPointerCursor()
                    .help("把这句作为补充写进纪要；只选需要的句子，它不是会上说的话，会标成「AI 补充」")
            }
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
                Text("证据（\(rows.count) 处原文引用）")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        if let start = row.tStart {
                            Text(Self.timecode(start))
                                .font(SpeechRailDesignTokens.Typography.technicalValue)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                                .padding(.horizontal, SpeechRailDesignTokens.Spacing.micro)
                                .padding(.vertical, SpeechRailDesignTokens.Spacing.hairline)
                                .background(
                                    SpeechRailDesignTokens.Color.recessedField,
                                    in: SpeechRailDesignTokens.Corner.compactShape
                                )
                        }
                        Text("「\(row.quote ?? "")」")
                            .font(SpeechRailDesignTokens.Typography.callout)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - 底部通栏提问输入区

    private var composerBar: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            TextField("私下向助手提问（仅参考本场文字记录，不联网、不入公频）…", text: $question)
                .textFieldStyle(.plain)
                .speechRailSingleLineInput(.regular)
                .focused($isQuestionFieldFocused)
                .accessibilityLabel("会中私聊提问输入框")
                .onSubmit { send() }

            if session.state == .generating {
                Button("取消") { session.cancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .speechRailPointerCursor()
            } else {
                Button("提问") { send() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sessionID == nil)
                    .speechRailPointerCursor()
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        .background(SpeechRailDesignTokens.Color.recessedField.opacity(0.5))
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
            Text("选择要写进纪要的句子")
                .font(.headline)
            Text("只勾你想要的句子。没勾的不会进纪要，也不会写进这次会议的存档。")
                .font(.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
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
            .frame(maxHeight: SpeechRailDesignTokens.Layout.innerOSSentencePickerMaxHeight)
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
        .frame(minWidth: SpeechRailDesignTokens.Layout.Sheet.compactWidth, minHeight: 320, alignment: .leading)
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
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        question = ""
        askPrompt(text)
    }

    private func askPrompt(_ promptText: String) {
        let trimmed = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.ask(
            trimmed,
            resolvedConfiguration: preferences.resolvedLLMConfiguration(for: .assistant)
        )
    }

    private func copy(_ exchange: InnerOSExchange) {
        var parts: [String] = []
        if let answer = exchange.answerText, !answer.isEmpty { parts.append(answer) }
        if let draft = exchange.draftText, !draft.isEmpty { parts.append("可直接念：\(draft)") }
        copyText(parts.joined(separator: "\n"), exchangeID: exchange.id, feedbackLabel: "已复制")
    }

    private func copyText(_ text: String, exchangeID: String, feedbackLabel: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            copyFailure = "文字暂时未能复制，请重试。"
            return
        }
        copyNoticeID = UUID()
        copiedFeedback = (exchangeID, feedbackLabel)
    }

    private static func timecode(_ seconds: TimeInterval) -> String {
        return SpeechRailDisplayFormat.timecode(seconds, rounding: .toNearestOrAwayFromZero)
    }
}
