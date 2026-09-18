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
            .padding(.horizontal, 5)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)
            .background(
                SpeechRailDesignTokens.Color.recessedField,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
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
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text(who)
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .foregroundStyle(isVoice ? SpeechRailDesignTokens.Color.rail : SpeechRailDesignTokens.Color.ink)
                if let voiceBadge {
                    SessionVoiceBadge(label: voiceBadge)
                }
                if isPartial {
                    StatusPill(tone: .neutral, label: "识别中")
                }
                ForEach(Array(pills.enumerated()), id: \.offset) { _, pill in
                    StatusPill(tone: pill.tone, label: pill.label)
                }
                if let source {
                    Text("· \(source)")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                }
                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                if let timestamp {
                    Text(timestamp)
                        .font(SpeechRailDesignTokens.Typography.callout)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        .monospacedDigit()
                }
                ForEach(actions) { action in
                    Button {
                        onAction?(action)
                    } label: {
                        RowActionGlyph(systemImage: action.systemImage)
                    }
                    .buttonStyle(.borderless)
                    .help(action.help)
                    .accessibilityLabel(action.title)
                }
            }
            Text(text)
                .font(SpeechRailDesignTokens.Typography.body)
                .foregroundStyle(isPartial ? SpeechRailDesignTokens.Color.inkSecondary : SpeechRailDesignTokens.Color.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: bodyWidth, alignment: .leading)
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}


/// 行内动作：稿的行尾图标按钮，动作只有两类，所以用枚举而不是散落的闭包。
public enum SessionTurnAction: String, CaseIterable, Identifiable, Sendable {
    case play
    case copy

    public var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .play: "play"
        case .copy: "copy"
        }
    }

    var title: String {
        switch self {
        case .play: "重播这一句"
        case .copy: "复制这一句"
        }
    }

    var help: String {
        switch self {
        case .play: "重播这一句：原音色、原内容"
        case .copy: "复制这一句的正文"
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
            .padding(.horizontal, 10)
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
        .help("换音色下一句生效；它只改声音，不改人设")
        .accessibilityLabel("音色：\(name)")
    }
}

// MARK: - 结论条的动作组（稿 `conclusionBand` 的 actions 槽）

/// 结论条（稿 `conclusionBand`，脚本 2173）：图标 + 结论 + 影响 + **一行提示** + 若干出口。
///
/// 它和 `StatusBanner(kind: .conclusion)` 的差别有两处，所以没有合并：稿的结论条带
/// `hint` 那一行（更小的字，写"怎么配合这件事"），而且**支持多个出口**（「打开设置…」+
/// 「了解如何配置」是一条结论的两个去向）。`StatusBanner` 服务另外八个页面，只收一颗按钮。
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
    }
}


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
    public let onSelect: (SessionSummary) -> Void

    @Environment(SessionCoordinator.self) private var session
    @State private var summaries: [SessionSummary] = []
    @State private var query = ""

    public init(
        kind: SessionKind,
        title: String,
        foot: String,
        selectedID: String?,
        onSelect: @escaping (SessionSummary) -> Void
    ) {
        self.kind = kind
        self.title = title
        self.foot = foot
        self.selectedID = selectedID
        self.onSelect = onSelect
    }

    public var body: some View {
        SessionPanel {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text(title)
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                if !summaries.isEmpty {
                    Text("\(summaries.count) 段")
                        .font(SpeechRailDesignTokens.Typography.callout)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)

            HStack {
                TextField("搜索记录", text: $query)
                    .textFieldStyle(.plain)
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                    .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
                    .background(
                        SpeechRailDesignTokens.Color.inputField,
                        in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                            .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
                    }
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            .padding(.bottom, SpeechRailDesignTokens.Spacing.micro)

            SessionHairline()

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, summary in
                        if index > 0 { SessionHairline() }
                        libraryRow(summary)
                    }
                    if filtered.isEmpty {
                        Text(summaries.isEmpty ? "还没有记录。" : "没有匹配的记录。")
                            .font(SpeechRailDesignTokens.Typography.callout)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                            .padding(.vertical, SpeechRailDesignTokens.Spacing.md)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            Spacer(minLength: 0)
            SessionHairline()
            CardFoot(note: foot) { EmptyView() }
        }
        .task(id: kind.rawValue) { await reload() }
    }

    private var filtered: [SessionSummary] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return summaries }
        return summaries.filter { summary in
            (summary.record.title ?? "").localizedCaseInsensitiveContains(needle)
        }
    }

    private func libraryRow(_ summary: SessionSummary) -> some View {
        Button {
            onSelect(summary)
        } label: {
            HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.xs) {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight + 1) {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Text(summary.record.title ?? "未命名")
                            .font(SpeechRailDesignTokens.Typography.bodyMedium)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                            .lineLimit(1)
                        if summary.openInterruption != nil {
                            StatusPill(tone: .attention, label: "有中断")
                        }
                    }
                    Text(
                        "\(summary.record.startedAt.formatted(date: .numeric, time: .shortened))"
                            + " · \(summary.lineCount) 句"
                    )
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selectedID == summary.id
                    ? SpeechRailDesignTokens.Surface.selectionTint
                    : .clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .speechRailPointerCursor()
    }

    private func reload() async {
        summaries = (try? await session.listSummaries(kind: kind)) ?? []
    }
}
