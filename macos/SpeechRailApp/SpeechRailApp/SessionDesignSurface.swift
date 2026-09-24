import AppKit
import SwiftUI

// 稿构件层：`figma-kit/main.js` 的「会话共享件」（脚本 1812–2270）与闭环稿的通用构件。
//
// 为什么单开一层：这三页此前各自拼卡片、各自排行、各自写「标签在左 / 取值在右」，
// 于是同一件事在三个页面有三种说法（`SESSIONS-SPEC` §6.7 的同一条理由）。这一层只放
// **稿上画过、且被两处以上复用**的形状；页面自己的正文面（对话流 / 转录流 / 字幕带）
// 不在这里。
//
// 数值一律取自既有 token（`Spacing` / `Layout` / `Corner` / `Control`），本层**不新增
// 数值常量**：稿那边的同一个数在实现里已经有一处声明，再写第二个就是漂移的起点。

// MARK: - 键帽（稿 `kbd` / `kbdInRow`）

/// 一颗键帽。稿里每一处快捷键提示都走它，所以提示在全 App 长得一样；
/// 按钮自己的快捷键不走这里（那句长在按钮标签上，见 `ButtonShortcutHint`）。
public struct SessionKeycap: View {
    public let label: String

    public init(_ label: String) {
        self.label = label
    }

    public var body: some View {
        Text(label)
            .font(SpeechRailDesignTokens.Typography.caption)
            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.micro)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)
            .background(
                SpeechRailDesignTokens.Color.recessedField,
                in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Spacing.micro, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Spacing.micro, style: .continuous)
                    .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
            }
            .accessibilityHidden(true)
    }
}

/// 页头行里的键帽槽：稿给它一个 34pt 高的盒子，让键帽与同一行的按钮基线对齐
/// （`kbdInRow`，脚本 1973）。
public struct SessionHeaderKeycap: View {
    public let label: String

    public init(_ label: String) {
        self.label = label
    }

    public var body: some View {
        SessionKeycap(label)
            .frame(height: SpeechRailDesignTokens.Control.regularHeight)
    }
}

// MARK: - 「非主框体」的收起控件（稿 `sideToggle`）

/// 稿 `sideToggle`：内容列首行尾端的一枚 28pt 图标按钮，收起右栏那类面板。
///
/// 它**不是工具栏项**：工具栏里每一件的落点由系统分配，锚不住「面板分界线」这个位置；
/// 首行由内容列承载，它的右沿就是面板左沿（`closurePanelRulesBoard` 的判据之一）。
public struct SessionPanelToggle: View {
    public let panelName: String
    public let isCollapsed: Bool
    public let action: () -> Void

    public init(panelName: String, isCollapsed: Bool, action: @escaping () -> Void) {
        self.panelName = panelName
        self.isCollapsed = isCollapsed
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.right")
                .font(SpeechRailDesignTokens.Typography.toolbarActionIcon)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .frame(
                    width: SpeechRailDesignTokens.Control.iconButtonSize,
                    height: SpeechRailDesignTokens.Control.iconButtonSize
                )
        }
        .buttonStyle(.borderless)
        .help(isCollapsed ? "展开「\(panelName)」" : "收起「\(panelName)」")
        .accessibilityLabel(isCollapsed ? "展开\(panelName)" : "收起\(panelName)")
        .accessibilityValue(isCollapsed ? "已收起" : "已展开")
        .accessibilityHint(isCollapsed ? "显示\(panelName)" : "隐藏\(panelName)")
        .accessibilityIdentifier("session-panel-toggle")
    }
}

// MARK: - 检查行（稿 `closureCheckRow`）

/// 稿 `closureCheckRow`（脚本 4161）：一行 = 定宽的名字格 + 一句说明 + 行尾取值。
///
/// 名字格是**定宽**（稿 132）而不是自适应：三行摆在一起时，说明文字的左沿要对齐；
/// 让它按各自的名字长短伸缩，读起来就是一列歪的。稿的注释里记着两条实测教训
/// （「Attention」在 96 里要 103、「腾讯会议」在 116 里要 122），所以这个格宽是按
/// **最长的那条名字**定的，改文案之前先量一遍。
public struct SessionCheckRow<Trailing: View>: View {
    /// 名字格宽。稿 132。
    public static var nameColumnWidth: CGFloat { 132 }

    public let tone: SessionRowTone
    public let name: String
    public let detail: String
    private let trailing: Trailing
    private let onSelect: (() -> Void)?

    public init(
        tone: SessionRowTone,
        name: String,
        detail: String,
        onSelect: (() -> Void)? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.tone = tone
        self.name = name
        self.detail = detail
        self.trailing = trailing()
        self.onSelect = onSelect
    }

    public var body: some View {
        let row = HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            HStack(spacing: 0) {
                SessionRowMark(tone: tone, label: name)
                Spacer(minLength: 0)
            }
            .frame(width: Self.nameColumnWidth, alignment: .leading)

            Text(detail)
                .font(SpeechRailDesignTokens.Typography.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)

        if let onSelect {
            Button(action: onSelect) { row }
                .buttonStyle(.plain)
                .speechRailPointerCursor()
        } else {
            row
        }
    }
}

public extension SessionCheckRow where Trailing == EmptyView {
    init(tone: SessionRowTone, name: String, detail: String, onSelect: (() -> Void)? = nil) {
        self.init(tone: tone, name: name, detail: detail, onSelect: onSelect) { EmptyView() }
    }
}

/// 检查行里那个名字的形状：稿的 `pill(tone, label)`——图标 + 短名 + 语义色淡底胶囊。
///
/// 与 `StatusPill` 的区别是**成员**：这里的 `tone` 多一档 `selected`（已选 / 当前），
/// 而 `StatusPill` 的语义是「状态」。两者共用同一档字号与胶囊几何。
public enum SessionRowTone: Sendable {
    case ready
    case selected
    case neutral
    case attention

    var statusTone: StatusTone? {
        switch self {
        case .ready, .selected: .healthy
        case .neutral: nil
        case .attention: .attention
        }
    }
}

struct SessionRowMark: View {
    let tone: SessionRowTone
    let label: String

    var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
            if let status = tone.statusTone {
                Image(systemName: tone == .selected ? "checkmark" : status.systemImage)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .accessibilityHidden(true)
            }
            Text(label)
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)
        .background(background, in: .capsule)
        .accessibilityElement(children: .combine)
    }

    private var foreground: Color {
        switch tone {
        case .ready, .selected: SpeechRailDesignTokens.Color.ready
        case .neutral: SpeechRailDesignTokens.Color.inkSecondary
        case .attention: SpeechRailDesignTokens.Color.attention
        }
    }

    private var background: Color {
        switch tone {
        case .ready, .selected:
            SpeechRailDesignTokens.Color.ready.opacity(SpeechRailDesignTokens.Surface.statusTintOpacity)
        case .neutral:
            SpeechRailDesignTokens.Color.recessedField
        case .attention:
            SpeechRailDesignTokens.Surface.attentionTint
        }
    }
}

// MARK: - 卡片面板（稿 `card(pad: 0, clip: true)` + 头 + 分隔 + 正文 + 弹性 + 分隔 + 动作）

/// 稿里带「头 / 正文 / 动作带」的容器卡。会话三页的右栏、人设区、音色区、对话流、
/// 记录卡都用这一形状，区别只在内容。
public struct SessionPanel<Content: View>: View {
    private let expandsVertically: Bool
    private let content: Content

    public init(expandsVertically: Bool = false, @ViewBuilder content: () -> Content) {
        self.expandsVertically = expandsVertically
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: expandsVertically ? .infinity : nil,
            alignment: .topLeading
        )
        .speechRailSurface(.panel)
        .clipShape(SpeechRailDesignTokens.Corner.containerShape)
    }
}

/// 稿 `card` 的头两种写法：`Title / Page` + 一句话（右栏），或 `Heading / Section` +
/// 右侧一句事实（正文卡）。`badge` 是右栏标题下那一行小字（「还没有开始」）。
public struct SessionPanelHead: View {
    public let title: String
    public let badge: String?
    public let detail: String?
    public let trailingDetail: String?

    public init(title: String, badge: String? = nil, detail: String? = nil, trailingDetail: String? = nil) {
        self.title = title
        self.badge = badge
        self.detail = detail
        self.trailingDetail = trailingDetail
    }

    public var body: some View {
        HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.sm) {
            if detail == nil, trailingDetail != nil {
                block(title: title, badge: nil, detail: nil, titleFont: SpeechRailDesignTokens.Typography.sectionTitle)
                Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
                Text(trailingDetail ?? "")
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520, alignment: .trailing)
            } else {
                block(title: title, badge: badge, detail: detail, titleFont: SpeechRailDesignTokens.Typography.display)
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, (detail == nil && badge == nil) ? SpeechRailDesignTokens.Spacing.sm : SpeechRailDesignTokens.Spacing.md)
        .accessibilityElement(children: .contain)
    }

    private func block(title: String, badge: String?, detail: String?, titleFont: Font) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight + 1) {
            Text(title)
                .font(titleFont)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            if let badge {
                Text(badge)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    .lineLimit(1)
            }
            if let detail {
                Text(detail)
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 卡片里的一条 1pt 分隔线，左右顶到卡片内沿（稿 `hairline`）。
public struct SessionHairline: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(SpeechRailDesignTokens.Surface.border)
            .frame(height: SpeechRailDesignTokens.Spacing.hairline)
            .frame(maxWidth: .infinity)
    }
}

/// 卡片底部的动作带（稿的 `foot` / `actions`）：分隔线由上一条给出，这里只管内边距与排布。
public struct SessionPanelActions<Content: View>: View {
    public enum Alignment: Sendable {
        case leading
        case trailing
        case spread
    }

    private let alignment: Alignment
    private let content: Content

    public init(alignment: Alignment = .leading, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            switch alignment {
            case .leading:
                content
                Spacer(minLength: 0)
            case .trailing:
                Spacer(minLength: 0)
                content
            case .spread:
                content
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 取值行（稿 `kvRow`）

/// 稿 `kvRow`：标签在左、取值在右，同一个 Inspector 里的取值因此左对齐成一列
/// （会话三页的右栏、记录信息都走它）。
public struct SessionKVRow: View {
    public let label: String
    public let value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SpeechRailDesignTokens.Spacing.xs) {
            Text(label)
                .font(SpeechRailDesignTokens.Typography.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .layoutPriority(1)
            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
            Text(value)
                .font(SpeechRailDesignTokens.Typography.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 对话行 / 转录行（稿 `turnRow`）

/// 对话行与转录行是同一条行（稿 `turnRow`，脚本 2128）：说话人 + 音色徽标 + 状态胶囊 +
/// 来源 + 时间 + 行内动作 + 正文。
///
/// 「被打断」这类**属于这一句**的状态挂在句子上，不挂在页面上：回看时要知道助手那一句
/// 为什么停在四个字上，而不是去猜。混音之后「对方说的」与「屋里说的」也要跟着行走。
public struct SessionTurnRow: View {
    public struct Pill: Sendable {
        public let tone: StatusTone
        public let label: String

        public init(tone: StatusTone, label: String) {
            self.tone = tone
            self.label = label
        }
    }

    public let who: String
    public let isVoice: Bool
    public let voiceBadge: String?
    public let pills: [Pill]
    public let source: String?
    public let timestamp: String?
    public let text: String
    public let isPartial: Bool
    public let bodyWidth: CGFloat?
    public let actions: [SessionTurnAction]
    public let onAction: ((SessionTurnAction) -> Void)?

    @State private var isHovered: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        who: String,
        isVoice: Bool = false,
        voiceBadge: String? = nil,
        pills: [Pill] = [],
        source: String? = nil,
        timestamp: String? = nil,
        text: String,
        isPartial: Bool = false,
        bodyWidth: CGFloat? = nil,
        actions: [SessionTurnAction] = [],
        onAction: ((SessionTurnAction) -> Void)? = nil
    ) {
        self.who = who
        self.isVoice = isVoice
        self.voiceBadge = voiceBadge
        self.pills = pills
        self.source = source
        self.timestamp = timestamp
        self.text = text
        self.isPartial = isPartial
        self.bodyWidth = bodyWidth
        self.actions = actions
        self.onAction = onAction
    }

    private var isAssistant: Bool {
        isVoice || who == "助手"
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isAssistant {
                assistantBubble
                Spacer(minLength: 32)
            } else {
                Spacer(minLength: 32)
                userBubble
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.compact)
        .frame(maxWidth: .infinity)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - 助手消息气泡（靠左）

    private var assistantBubble: some View {
        HStack(alignment: .top, spacing: 10) {
            // 助手形象徽标
            ZStack {
                Circle()
                    .fill(SpeechRailDesignTokens.Color.rail.opacity(0.12))
                    .frame(width: SpeechRailDesignTokens.Layout.badgeRegularSize, height: SpeechRailDesignTokens.Layout.badgeRegularSize)
                Image(systemName: "waveform.and.mic")
                    .font(SpeechRailDesignTokens.Typography.subheadlineBold)
                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
            }
            .padding(.top, SpeechRailDesignTokens.Spacing.tight)

            VStack(alignment: .leading, spacing: 4) {
                // 助手头部标识行
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Text(who)
                        .font(SpeechRailDesignTokens.Typography.captionMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                    if let voiceBadge {
                        SessionVoiceBadge(label: voiceBadge)
                    }
                    if isPartial {
                        StatusPill(tone: .neutral, label: "生成中…")
                    }
                    ForEach(Array(pills.enumerated()), id: \.offset) { _, pill in
                        StatusPill(tone: pill.tone, label: pill.label)
                    }
                    if let source {
                        Text("· \(source)")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    }
                }

                // 助手正文气泡容器
                VStack(alignment: .leading, spacing: 4) {
                    Text(text)
                        .font(SpeechRailDesignTokens.Typography.body)
                        .foregroundStyle(isPartial ? SpeechRailDesignTokens.Color.inkSecondary : SpeechRailDesignTokens.Color.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.roomy)
                .padding(.vertical, SpeechRailDesignTokens.Spacing.cozy)
                .background(
                    SpeechRailDesignTokens.Color.field,
                    in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.container, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.container, style: .continuous)
                        .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
                )
                .contextMenu {
                    contextMenuItems
                }

                // 助手气泡底部时间与动作
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    if let timestamp {
                        Text(timestamp)
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                            .monospacedDigit()
                    }

                    if !actions.isEmpty {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.tight) {
                            ForEach(actions) { action in
                                actionIconButton(action)
                            }
                        }
                        .opacity(isHovered ? 1.0 : 0.0)
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 0.15),
                            value: isHovered
                        )
                    }

                    Spacer(minLength: 4)
                }
            }
            .frame(maxWidth: bodyWidth ?? 640, alignment: .leading)
        }
    }

    // MARK: - 用户消息气泡（靠右）

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            // 用户发言气泡容器
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(isPartial ? SpeechRailDesignTokens.Color.inkSecondary : SpeechRailDesignTokens.Color.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.roomy)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.cozy)
            .background(
                SpeechRailDesignTokens.Color.rail.opacity(0.14),
                in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.container, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.container, style: .continuous)
                    .stroke(SpeechRailDesignTokens.Color.rail.opacity(0.24), lineWidth: SpeechRailDesignTokens.Stroke.hairline)
            )
            .contextMenu {
                contextMenuItems
            }

            // 用户气泡底部标签与时间
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Spacer(minLength: 4)

                if !actions.isEmpty {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.tight) {
                        ForEach(actions) { action in
                            actionIconButton(action)
                        }
                    }
                    .opacity(isHovered ? 1.0 : 0.0)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.15),
                        value: isHovered
                    )
                }

                if isPartial {
                    StatusPill(tone: .neutral, label: "识别中…")
                }
                ForEach(Array(pills.enumerated()), id: \.offset) { _, pill in
                    StatusPill(tone: pill.tone, label: pill.label)
                }
                if let timestamp {
                    Text(timestamp)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: bodyWidth ?? 560, alignment: .trailing)
    }

    private func actionIconButton(_ action: SessionTurnAction) -> some View {
        Button {
            onAction?(action)
        } label: {
            Image(systemName: action.systemImage)
                .font(SpeechRailDesignTokens.Typography.calloutMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .frame(width: SpeechRailDesignTokens.Layout.actionIconButtonWidth, height: SpeechRailDesignTokens.Layout.actionIconButtonHeight)
                .background(
                    SpeechRailDesignTokens.Color.recessedField,
                    in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Spacing.micro, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .help(action.help)
        .accessibilityLabel(action.title)
        .speechRailPointerCursor()
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        ForEach(actions) { action in
            Button {
                onAction?(action)
            } label: {
                Label(action.help, systemImage: action.systemImage)
            }
        }
    }
}


/// 行内动作：稿的行尾图标按钮，动作是有限几类，所以用枚举而不是散落的闭包。
public enum SessionTurnAction: String, CaseIterable, Identifiable, Sendable {
    case play
    case copy
    /// 只有语音助手用（`AssistantView`）：把这一句写进长期记忆。
    ///
    /// 它不适用于会议与字幕——记忆是助手的东西（`assistant_memory`），会议与字幕的
    /// 长期资产是记录本身与纪要。放在同一个枚举里是因为按钮的形状与位置是同一处
    /// （行尾那一列图标），而不是因为它们对三页同义。
    case remember

    public var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .play: "play.fill"
        case .copy: "doc.on.doc"
        case .remember: "bookmark"
        }
    }

    var title: String {
        switch self {
        case .play: "重播"
        case .copy: "复制"
        case .remember: "记住"
        }
    }

    var help: String {
        switch self {
        case .play: "重播这一句：原音色、原内容"
        case .copy: "复制这一句的正文"
        case .remember: "把这一句写进长期记忆：下一轮开始生效，在右栏「记忆」里能改能删"
        }
    }
}

/// 音色徽标（稿 `voiceBadge`）：助手说过的话上标着「这句是谁的声音」——
/// 会话里可以换音色，换完之后回看要分得清哪一句是哪一把嗓子。
public struct SessionVoiceBadge: View {
    public let label: String

    public init(label: String) {
        self.label = label
    }

    public var body: some View {
        Text(label)
            .font(SpeechRailDesignTokens.Typography.caption)
            .foregroundStyle(SpeechRailDesignTokens.Color.voice)
            .padding(.horizontal, SpeechRailDesignTokens.Chip.insetX)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)
            .background(SpeechRailDesignTokens.Surface.voiceBadgeFill, in: .capsule)
            .accessibilityLabel("音色 \(label)")
    }
}

// MARK: - 音色胶囊（稿 `voiceCapsule`）

/// 稿 `voiceCapsule`：波形图标 + 音色名 + chevron 的下拉。它替代了早先一颗纯文字按钮——
/// 「音色」在会话里是一个**带对象的下拉**（当前是谁 + 能换成谁），不是一个动作。
public struct SessionVoiceCapsule<Content: View>: View {
    public let name: String
    private let content: Content

    public init(name: String, @ViewBuilder content: () -> Content) {
        self.name = name
        self.content = content()
    }

    public var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Image(systemName: "waveform")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.voice)
                    .accessibilityHidden(true)
                Text(name)
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.cozy)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
            .background(
                SpeechRailDesignTokens.Color.inputField,
                in: Capsule(style: .continuous)
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(SpeechRailDesignTokens.Surface.borderStrong, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("换音色下一句生效；它只改声音，不改角色")
        .accessibilityLabel("音色：\(name)")
    }
}

// MARK: - 结论条的动作组（稿 `conclusionBand` 的 actions 槽）

/// 结论条（稿 `conclusionBand`，脚本 2173）：图标 + 结论 + 影响 + **一行提示** + 若干出口。
///
/// 它和 `StatusBanner(kind: .conclusion)` 的差别有两处，所以没有合并：稿的结论条带
/// `hint` 那一行（更小的字，写"怎么配合这件事"），而且**支持多个出口**（「打开设置…」+
/// 「了解如何配置」是一条结论的两个去向）。`StatusBanner` 服务另外十四个页面，只收一颗按钮。
public struct SessionConclusionBand: View {
    public let tone: StatusTone
    public let title: String
    /// 结论正文。**不能叫 `body`**：那是 `View` 的协议要求，同名会让这个类型编译不过。
    public let message: String
    public let hint: String?
    private let actions: AnyView

    public init<Actions: View>(
        tone: StatusTone,
        title: String,
        message: String,
        hint: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.tone = tone
        self.title = title
        self.message = message
        self.hint = hint
        self.actions = AnyView(actions())
    }

    public var body: some View {
        HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.md) {
            Image(systemName: tone.systemImage)
                .font(.system(size: SpeechRailDesignTokens.Control.statusBannerIconSize, weight: .semibold))
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(title)
                    .font(SpeechRailDesignTokens.Typography.display)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(message)
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint {
                    Text(hint)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actions
        }
        .padding(SpeechRailDesignTokens.Layout.cardInset)
        .background(tone.color.opacity(SpeechRailDesignTokens.Surface.statusTintOpacity))
        .clipShape(SpeechRailDesignTokens.Corner.containerShape)
        .overlay {
            SpeechRailDesignTokens.Corner.containerShape
                .stroke(tone.color, lineWidth: SpeechRailDesignTokens.Stroke.strong)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue("\(tone.accessibilityLabel)。\(message)")
    }
}

#if DEBUG
private struct SharedSemanticPreviewSurface: View {
    @State private var isInspectorCollapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.gutter) {
            SessionStatusBar(
                title: "正在记录",
                tone: .attention,
                facts: ["麦克风", "本机音频"],
                elapsed: 92
            )
            SessionPanelToggle(
                panelName: "本次会议",
                isCollapsed: isInspectorCollapsed
            ) {
                isInspectorCollapsed.toggle()
            }
            SessionConclusionBand(
                tone: .critical,
                title: "麦克风需要授权",
                message: "允许后才能开始本次记录。",
                hint: "前往系统设置完成授权。"
            ) {
                Button("打开设置") {}
                    .speechRailButton(.secondary)
            }
        }
        .padding(SpeechRailDesignTokens.Layout.contentPadding)
        .frame(width: 620, alignment: .topLeading)
    }
}

#Preview("Shared states") {
    SharedSemanticPreviewSurface()
}

#Preview("Reduce Motion") {
    SharedSemanticPreviewSurface()
}

#Preview("High Contrast") {
    SharedSemanticPreviewSurface()
}

#Preview("Lived-in content") {
    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.gutter) {
        SessionConclusionBand(
            tone: .attention,
            title: "这是一条超过一行的长状态标题，用来检查窄窗口下的折行和下一步动作",
            message: "保留的数据、当前影响和下一步都应该完整可读；长说明不能在构造数据时预截断，也不能只靠颜色表达失败。",
            hint: "这是部分完成状态：已经保存的内容可以继续查看，失败的部分可以重试。"
        ) {
            Button("重试") {}
                .speechRailButton(.secondary)
        }

        SessionEmptyState(
            systemImage: "tray",
            title: "这里还没有记录",
            message: "完成一次操作后，结果会留在本机记录库中；现在可以返回主任务或开始新的操作。"
        ) {
            Button("开始新的操作") {}
                .speechRailButton(.primary)
        }
    }
    .padding(SpeechRailDesignTokens.Layout.contentPadding)
    .frame(width: 620, alignment: .topLeading)
}
#endif


// MARK: - 记录库列（稿 `recordListColumn`，脚本 2240）

/// 三条闭环的产物住在同一个本机数据库里，所以它们长同一个样子：标题 + 计数 + 搜索 +
/// 行 + 页脚（稿把这一形状在字幕记录库与对话记录库各写过一遍，这里收成一份）。
///
/// 列宽走 `Layout.sessionListWidth`（稿 `size/list` 280）——它与模型配置列表是同一个数，
/// 全 App 的「列表列」只有这一档。
public struct SessionLibraryColumn: View {
    public let kind: SessionKind
    public let title: String
    public let foot: String
    public let selectedID: String?
    /// 外部动作（重命名 / 移除）改过库之后，用计数变化叫这一栏**重新读库**。
    /// 列表的权威在库里，界面只是它的一个读数——不刷新就会留下一条已经不存在的记录
    /// （或一个改过的旧名字），用户看到的是"点了没反应"。
    public let reloadToken: Int
    public let onSelect: (SessionSummary) -> Void

    @Environment(SessionCoordinator.self) private var session
    @State private var summaries: [SessionSummary] = []
    @State private var query = ""

    public init(
        kind: SessionKind,
        title: String,
        foot: String,
        selectedID: String?,
        reloadToken: Int = 0,
        onSelect: @escaping (SessionSummary) -> Void
    ) {
        self.kind = kind
        self.title = title
        self.foot = foot
        self.selectedID = selectedID
        self.reloadToken = reloadToken
        self.onSelect = onSelect
    }

    public var body: some View {
        SessionPanel(expandsVertically: true) {
            // 列头部
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                Text(title)
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                if !summaries.isEmpty {
                    StatusPill(tone: .neutral, label: "\(summaries.count) 段归档")
                }
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)

            // 搜索输入条
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)

                TextField("搜索记录标题或时间…", text: $query)
                    .textFieldStyle(.plain)
                    .font(SpeechRailDesignTokens.Typography.callout)

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(SpeechRailDesignTokens.Typography.subheadline)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空记录搜索")
                    .help("清空记录搜索")
                    .speechRailPointerCursor()
                }
            }
            .speechRailSingleLineInput(.compact)
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            .padding(.bottom, SpeechRailDesignTokens.Spacing.xs)

            SessionHairline()

            // 列表区
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(filtered) { summary in
                        libraryRow(summary)
                    }
                    if filtered.isEmpty {
                        VStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Spacer()
                            Image(systemName: summaries.isEmpty ? "archivebox" : "line.3.horizontal.decrease.circle")
                                .font(SpeechRailDesignTokens.Typography.emptyStateIcon)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                            Text(summaries.isEmpty ? "还没有历史会话记录" : "没有匹配的记录")
                                .font(SpeechRailDesignTokens.Typography.bodyMedium)
                                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                            Text(summaries.isEmpty ? "与助手完成对话后，记录将自动加密保存在此处。" : "请尝试输入其他关键词或清空搜索框。")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                                .multilineTextAlignment(.center)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, minHeight: 180)
                        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                    }
                }
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
            }
            .frame(maxHeight: .infinity)

            SessionHairline()
            CardFoot(note: foot) { EmptyView() }
        }
        .frame(maxHeight: .infinity)
        .task(id: "\(kind.rawValue)-\(reloadToken)") { await reload() }
    }

    private var filtered: [SessionSummary] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return summaries }
        return summaries.filter { summary in
            let titleMatch = (summary.record.title ?? "").localizedCaseInsensitiveContains(needle)
            let personaMatch = (summary.record.persona?.title ?? "").localizedCaseInsensitiveContains(needle)
            let dateMatch = Self.formatSessionDate(summary.record.startedAt).localizedCaseInsensitiveContains(needle)
            return titleMatch || personaMatch || dateMatch
        }
    }

    private func libraryRow(_ summary: SessionSummary) -> some View {
        let isSelected = (selectedID == summary.id)

        return HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Button {
                onSelect(summary)
            } label: {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                    // 顶行：微徽标 + 标题 + 状态胶囊
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        ZStack {
                            Circle()
                                .fill(SpeechRailDesignTokens.Color.rail.opacity(isSelected ? 0.22 : 0.12))
                                .frame(width: SpeechRailDesignTokens.Layout.badgeSmallSize, height: SpeechRailDesignTokens.Layout.badgeSmallSize)
                            Image(systemName: "waveform.and.mic")
                                .font(SpeechRailDesignTokens.Typography.captionBold)
                                .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                        }

                        Text(summary.record.title ?? "未命名对话")
                            .font(SpeechRailDesignTokens.Typography.bodyMedium)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        if summary.openInterruption != nil {
                            StatusPill(tone: .attention, label: "中断")
                        } else if summary.lineCount == 0 {
                            StatusPill(tone: .neutral, label: "0 句")
                        } else {
                            StatusPill(
                                tone: isSelected ? .healthy : .neutral,
                                label: "\(summary.lineCount) 句"
                            )
                        }
                    }

                    // 底行：角色 · 日期 · 耗时
                    HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                        if let persona = summary.record.persona?.title {
                            Text(persona)
                                .font(SpeechRailDesignTokens.Typography.captionMedium)
                                .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                            Text("·")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        }

                        Text(Self.formatSessionDate(summary.record.startedAt))
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)

                        if summary.duration() > 1 {
                            Text("·")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                            Text(Self.formatDuration(summary.duration()))
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .speechRailPointerCursor()

            InPlaceDeleteButton(
                style: .compactIcon,
                title: "删除会话"
            ) {
                Task {
                    try? await session.removeSession(id: summary.id)
                    await reload()
                }
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected
                ? SpeechRailDesignTokens.Surface.selectionTint
                : SpeechRailDesignTokens.Color.field,
            in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                .stroke(
                    isSelected
                        ? SpeechRailDesignTokens.Color.rail.opacity(0.45)
                        : SpeechRailDesignTokens.Surface.border,
                    lineWidth: isSelected
                        ? SpeechRailDesignTokens.Stroke.strong
                        : SpeechRailDesignTokens.Stroke.hairline
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous))
        .contextMenu {
            Button("在此处继续对话") { onSelect(summary) }
            Button("复制会话 ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(summary.id, forType: .string)
            }
            Divider()
            Button("删除会话", role: .destructive) {
                Task {
                    try? await session.removeSession(id: summary.id)
                    await reload()
                }
            }
        }
    }

    private static func formatSessionDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "今天 \(date.formatted(date: .omitted, time: .shortened))"
        } else if calendar.isDateInYesterday(date) {
            return "昨天 \(date.formatted(date: .omitted, time: .shortened))"
        } else {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = Int(duration)
        if seconds < 60 {
            return "\(max(1, seconds))秒"
        } else {
            let mins = seconds / 60
            let remSecs = seconds % 60
            if remSecs == 0 {
                return "\(mins)分"
            } else {
                return "\(mins)分\(remSecs)秒"
            }
        }
    }

    private func reload() async {
        summaries = (try? await session.listSummaries(kind: kind)) ?? []
        if selectedID == nil, let first = summaries.first {
            onSelect(first)
        }
    }
}

/// 原位确认删除组件：点击后在原位平滑展开「确认」与「取消」；
/// 点击「确认」执行删除动作，点击「取消」恢复原状。
public struct InPlaceDeleteButton: View {
    public enum Style {
        /// 行内紧凑文字模式（如记忆条目、文本操作行）
        case compactText
        /// 行内微图标模式（如会话历史栏、记录列表每行右侧的小垃圾桶）
        case compactIcon
        /// 完整按钮模式（如复盘页底部的次级操作按钮）
        case regularButton
    }

    public let style: Style
    public let title: String
    public let systemImage: String?
    public let confirmText: String
    public let cancelText: String
    public let onConfirm: () -> Void

    @State private var isConfirming = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        style: Style = .compactIcon,
        title: String = "删除",
        systemImage: String? = "trash",
        confirmText: String = "确认",
        cancelText: String = "取消",
        onConfirm: @escaping () -> Void
    ) {
        self.style = style
        self.title = title
        self.systemImage = systemImage
        self.confirmText = confirmText
        self.cancelText = cancelText
        self.onConfirm = onConfirm
    }

    public var body: some View {
        if isConfirming {
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                if style == .regularButton {
                    Button(confirmText, role: .destructive) {
                        setConfirming(false)
                        onConfirm()
                    }
                    .speechRailButton(.destructive)

                    Button(cancelText) {
                        setConfirming(false)
                    }
                    .speechRailButton(.secondary)
                } else {
                    Button {
                        setConfirming(false)
                        onConfirm()
                    } label: {
                        Text(confirmText)
                            .font(SpeechRailDesignTokens.Typography.captionMedium)
                            .foregroundStyle(SpeechRailDesignTokens.Color.critical)
                            .padding(.horizontal, SpeechRailDesignTokens.Spacing.compact)
                            .padding(.vertical, SpeechRailDesignTokens.Spacing.tiny)
                            .background(
                                SpeechRailDesignTokens.Color.critical.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Spacing.micro, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .speechRailPointerCursor()

                    Button {
                        setConfirming(false)
                    } label: {
                        Text(cancelText)
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            .padding(.horizontal, SpeechRailDesignTokens.Spacing.compact)
                            .padding(.vertical, SpeechRailDesignTokens.Spacing.tiny)
                            .background(
                                SpeechRailDesignTokens.Color.field,
                                in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Spacing.micro, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Spacing.micro, style: .continuous)
                                    .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
                            )
                    }
                    .buttonStyle(.plain)
                    .speechRailPointerCursor()
                }
            }
            .transition(
                reduceMotion
                    ? .identity
                    : .opacity.combined(with: .scale(scale: 0.95))
            )
        } else {
            if style == .regularButton {
                Button(role: .destructive) {
                    setConfirming(true)
                } label: {
                    if let systemImage {
                        Label(title, systemImage: systemImage)
                    } else {
                        Text(title)
                    }
                }
                .speechRailButton(.secondary)
                .transition(
                    reduceMotion
                        ? .identity
                        : .opacity.combined(with: .scale(scale: 0.95))
                )
            } else {
                Button {
                    setConfirming(true)
                } label: {
                    switch style {
                    case .compactIcon:
                        Image(systemName: systemImage ?? "trash")
                            .font(SpeechRailDesignTokens.Typography.subheadline)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                            .padding(SpeechRailDesignTokens.Spacing.micro)
                            .contentShape(Rectangle())
                    case .compactText:
                        Text(title)
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.critical)
                    case .regularButton:
                        EmptyView()
                    }
                }
                .buttonStyle(.plain)
                .speechRailPointerCursor()
            }
        }
    }

    private func setConfirming(_ confirming: Bool) {
        let update = { isConfirming = confirming }
        if reduceMotion {
            update()
        } else {
            withAnimation(.easeInOut(duration: 0.16), update)
        }
    }
}
