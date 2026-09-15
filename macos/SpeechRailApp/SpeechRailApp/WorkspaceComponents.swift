import AppKit
import SwiftUI
import SpeechRailControlKit

public enum SpeechRailButtonLevel: Sendable {
    case primary
    case secondary
    case quiet
    case destructive
}

/// Applies the native macOS button hierarchy while keeping SpeechRail's
/// pointer, press, focus, and accessibility behavior consistent.
public struct SpeechRailButtonAppearance: ViewModifier {
    private let level: SpeechRailButtonLevel

    public init(level: SpeechRailButtonLevel) {
        self.level = level
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        Group {
            switch level {
            case .primary:
                content
                    .buttonStyle(.borderedProminent)
            case .secondary:
                content
                    .buttonStyle(.bordered)
            case .quiet:
                content
                    .buttonStyle(.borderless)
            case .destructive:
                content
                    .buttonStyle(.bordered)
                    .tint(SpeechRailDesignTokens.Color.critical)
            }
        }
        .controlSize(.regular)
        .contentShape(Rectangle())
        .speechRailPointerCursor()
    }
}

/// A shared style for custom rows/cards that are buttons but intentionally do
/// not look like standard toolbar or form buttons.
public struct SpeechRailInteractiveButtonStyle: ButtonStyle {
    private let fillsAvailableWidth: Bool

    public init(fillsAvailableWidth: Bool = false) {
        self.fillsAvailableWidth = fillsAvailableWidth
    }

    public func makeBody(configuration: Configuration) -> some View {
        SpeechRailInteractiveButtonBody(
            configuration: configuration,
            fillsAvailableWidth: fillsAvailableWidth
        )
    }
}

/// A full-width disclosure primitive for technical detail sections.
///
/// `DisclosureGroup` still owns the expansion binding and content lifecycle,
/// while this style makes the complete row one native Button hit target. This
/// prevents a long detail panel from falling back to the label's intrinsic
/// width and keeps the arrow, focus, pressed, and accessibility states together.
@MainActor
public struct SpeechRailDisclosureGroupStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    @ViewBuilder
    public func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
            Button {
                withAnimation(
                    reduceMotion ? nil : SpeechRailDesignTokens.Motion.selectionFeedback
                ) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                ZStack(alignment: .leading) {
                    // A clear fill gives the label a concrete full-width layout
                    // proposal. The row remains visually transparent until the
                    // shared ButtonStyle supplies hover/pressed feedback.
                    Color.clear
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Image(
                            systemName: configuration.isExpanded
                                ? "chevron.down"
                                : "chevron.right"
                        )
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .accessibilityHidden(true)

                        configuration.label
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(
                    minWidth: SpeechRailDesignTokens.Interaction.minimumHitTarget,
                    maxWidth: .infinity,
                    minHeight: SpeechRailDesignTokens.List.rowHeight,
                    alignment: .leading
                )
                .contentShape(Rectangle())
            }
            .speechRailInteractiveButtonStyle(fillsAvailableWidth: true)
            // Keep the Button's outer hit region aligned with the full-width
            // label. The style owns feedback; this frame owns the command
            // boundary so transparent trailing space is still actionable.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityValue(configuration.isExpanded ? "已展开" : "已收起")

            if configuration.isExpanded {
                configuration.content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, SpeechRailDesignTokens.List.disclosureContentInset)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A compact, full-width action row for the menu-bar popover. The native
/// Button style still owns its pressed appearance; this modifier owns only the
/// shared geometry and cursor affordance.
public struct SpeechRailMenuRowModifier: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .frame(
                minWidth: SpeechRailDesignTokens.Interaction.minimumHitTarget,
                maxWidth: .infinity,
                minHeight: SpeechRailDesignTokens.Menu.rowHeight,
                alignment: .leading
            )
            .contentShape(Rectangle())
            .speechRailPointerCursor()
    }
}

public extension View {
    func speechRailMenuRow() -> some View {
        modifier(SpeechRailMenuRowModifier())
    }
}

private struct SpeechRailInteractiveButtonBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    let configuration: SpeechRailInteractiveButtonStyle.Configuration
    let fillsAvailableWidth: Bool

    var body: some View {
        labelContent
            .frame(
                minWidth: SpeechRailDesignTokens.Interaction.minimumHitTarget,
                maxWidth: fillsAvailableWidth ? .infinity : nil,
                minHeight: SpeechRailDesignTokens.Interaction.minimumHitTarget,
                alignment: .leading
            )
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
            .background(backgroundShape)
            .overlay {
                if isFocused {
                    ConcentricRectangle()
                    .stroke(
                        SpeechRailDesignTokens.Navigation.focusRing,
                        lineWidth: SpeechRailDesignTokens.Interaction.focusLineWidth
                    )
                    .padding(SpeechRailDesignTokens.Interaction.focusRingInset)
                }
            }
            // The visual treatment stays rounded, but the complete button
            // bounds—including transparent padding—remain one hit target.
            // The system already animates press; a custom scale would double
            // that feedback (REDESIGN-SPEC §5.8).
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : SpeechRailDesignTokens.Interaction.disabledOpacity)
            .onHover { hovering in
                isHovered = isEnabled && hovering
            }
            .overlay {
                SpeechRailCursorRegion(isEnabled: isEnabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
            .animation(
                reduceMotion ? nil : SpeechRailDesignTokens.Motion.hoverFeedback,
                value: isHovered
            )
            .animation(
                reduceMotion ? nil : SpeechRailDesignTokens.Motion.pressFeedback,
                value: configuration.isPressed
            )
    }

    @ViewBuilder
    private var labelContent: some View {
        if fillsAvailableWidth {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            configuration.label
        }
    }

    private var backgroundShape: some View {
        ConcentricRectangle()
        .fill(
            !isEnabled
                ? SwiftUI.Color.clear
                : configuration.isPressed
                    ? SpeechRailDesignTokens.Surface.interactionPressed
                    : isHovered
                        ? SpeechRailDesignTokens.Surface.interactionHover
                        : SwiftUI.Color.clear
        )
        .overlay {
            if isHovered && isEnabled {
                ConcentricRectangle()
                .stroke(
                    SpeechRailDesignTokens.Surface.border,
                    lineWidth: SpeechRailDesignTokens.Stroke.hairline
                )
            }
        }
    }
}

private struct SpeechRailCursorRegion: NSViewRepresentable {
    let isEnabled: Bool

    func makeNSView(context: Context) -> CursorView {
        CursorView(isEnabled: isEnabled)
    }

    func updateNSView(_ nsView: CursorView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.window?.invalidateCursorRects(for: nsView)
    }

    final class CursorView: NSView {
        var isEnabled: Bool

        init(isEnabled: Bool) {
            self.isEnabled = isEnabled
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func resetCursorRects() {
            if isEnabled {
                addCursorRect(bounds, cursor: .pointingHand)
            }
        }
    }
}

public extension View {
    func speechRailButton(_ level: SpeechRailButtonLevel) -> some View {
        modifier(SpeechRailButtonAppearance(level: level))
    }

    /// Applies the fixed-label-column inspector row shape to every
    /// `LabeledContent` in the subtree.
    func speechRailInspectorContent() -> some View {
        labeledContentStyle(SpeechRailInspectorLabeledContentStyle())
    }

    func speechRailInteractiveButtonStyle(fillsAvailableWidth: Bool = false) -> some View {
        buttonStyle(
            SpeechRailInteractiveButtonStyle(fillsAvailableWidth: fillsAvailableWidth)
        )
        // A custom ButtonStyle controls the visual body, but SwiftUI may keep
        // the Button's outer layout at the label's intrinsic width. Expand the
        // semantic command surface here as well, so the complete row/tag—not
        // only its text or icon—has one consistent hit target.
        .frame(
            maxWidth: fillsAvailableWidth ? .infinity : nil,
            alignment: .leading
        )
        .contentShape(Rectangle())
    }

    /// Shows a pointing hand only for an enabled, genuinely interactive surface.
    /// Static labels and containers never opt into this cursor.
    func speechRailPointerCursor() -> some View {
        modifier(SpeechRailPointerCursorModifier())
    }
}

public struct SpeechRailPointerCursorModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func body(content: Content) -> some View {
        content
            .overlay {
                SpeechRailCursorRegion(isEnabled: isEnabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
    }
}

public enum StatusTone: Sendable {
    case neutral
    case healthy
    case attention
    case critical

    var color: Color {
        switch self {
        case .neutral:
            Color.secondary
        case .healthy:
            Color.green
        case .attention:
            Color.orange
        case .critical:
            Color.red
        }
    }

    var systemImage: String {
        switch self {
        case .neutral:
            "info.circle.fill"
        case .healthy:
            "checkmark.circle.fill"
        case .attention:
            "exclamationmark.triangle.fill"
        case .critical:
            "xmark.circle.fill"
        }
    }
}

enum SpeechRailRuntimeStatePresentation {
    static func text(_ rawValue: String) -> String {
        return switch rawValue.lowercased() {
        case "active":
            "运行中"
        case "warm_standby":
            "温待机"
        case "cold_evicted":
            "已释放"
        case "inactive":
            "未运行"
        case "unconfigured":
            "未配置"
        case "starting":
            "启动中"
        case "stopping":
            "停止中"
        case "loading":
            "加载中"
        case "idle", "stopped":
            "已停止"
        case "degraded":
            "需关注"
        case "failed":
            "失败"
        case "ok":
            "已连接"
        case "healthy":
            "健康"
        case "ready":
            "已就绪"
        case "not_ready":
            "未就绪"
        case "unknown":
            "未知"
        default:
            "未知"
        }
    }
}

enum SpeechRailProfilePresentation {
    static func title(_ profile: SpeechRailProfile) -> String {
        switch profile {
        case .quality:
            "Quality · 创作优先"
        case .balanced:
            "Balanced · 分人和日常"
        case .light:
            "Light · 轻量快速"
        }
    }
}

enum SpeechRailDiarizationPresentation {
    static func text(_ status: DiarizationStatusSnapshot) -> String {
        guard !status.ready else { return "已就绪" }
        return switch status.code?.lowercased() {
        case "diarization_not_configured":
            "未配置"
        case "diarization_alignment_not_configured":
            "缺少对齐模型"
        case "diarization_not_available":
            "运行时不可用"
        case "diarization_invalid_output":
            "运行时异常"
        default:
            status.configured ? "需要处理" : "未配置"
        }
    }
}

enum SpeechRailOperationMessagePresentation {
    static func text(_ rawMessage: String) -> String {
        let normalized = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "正在停止模型准备…", "模型准备已取消", "已有操作正在进行，请等待当前操作完成。":
            return rawMessage
        case "命令已完成，正在读取最新服务状态…", "服务命令已完成，状态已刷新。":
            return rawMessage
        case "服务命令已完成，但健康检查暂时不可用，请重新读取。":
            return rawMessage
        default:
            break
        }
        if normalized.hasPrefix("profile") {
            return "档位应用未完成，请重试或打开系统诊断。"
        }
        if normalized.hasPrefix("model preparation was cancelled") {
            return "模型准备已取消。"
        }
        if normalized.hasPrefix("stopping model preparation") {
            return "正在停止模型准备…"
        }
        if normalized.hasPrefix("model preparation") {
            return "模型准备未完成，请重新下载并校验。"
        }
        if normalized.hasPrefix("managed command") {
            return "受管操作未完成，请打开系统诊断查看原因。"
        }
        if normalized.hasPrefix("managed runtime does not support") {
            return "当前控制 Agent 不支持模型管理，请升级 SpeechRail。"
        }
        if normalized.contains("insufficient disk") {
            return "可用磁盘空间不足，请释放空间后重试。"
        }
        if normalized.contains("integrity") || normalized.contains("checksum") {
            return "模型完整性校验未通过，请重新下载并校验。"
        }
        if normalized.hasPrefix("another control operation") {
            return "已有操作正在进行，请稍候。"
        }
        if normalized.hasPrefix("previous model preparation") {
            return "上次模型准备被中断，请重新下载并校验。"
        }
        return "操作未完成，请重试或打开系统诊断。"
    }
}

/// The shared page geometry for every workspace surface.
///
/// The scaffold owns the content margins and nothing else: the toolbar carries
/// the page title, and the page body starts straight at its main object instead
/// of repeating the title as a purpose sentence (REDESIGN-SPEC §7).
/// Full-height workspaces such as diagnostics can opt out of the outer scroll
/// container while keeping the same geometry.
public struct PageScaffold<Content: View, Trailing: View>: View {
    public let route: AppRoute
    public let scrollable: Bool
    private let subtitle: String?
    private let trailing: Trailing
    private let content: Content

    public init(
        route: AppRoute,
        scrollable: Bool = true,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.route = route
        self.scrollable = scrollable
        self.subtitle = subtitle
        self.content = content()
        self.trailing = trailing()
    }

    @ViewBuilder
    public var body: some View {
        if scrollable {
            ScrollView {
                pageContent
            }
        } else {
            pageContent
                .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// 页头：八个页面都以同一套「标题 + 一句话说明」开场，可带右侧控件，
    /// 这样八个屏幕读起来是一个产品而不是八个变体（Figma `pageHead`）。
    private var pageHead: some View {
        HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.lg) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(route.title)
                    .font(SpeechRailDesignTokens.Typography.display)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle ?? route.pageSubtitle)
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var pageContent: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.lg) {
            pageHead
            content
        }
        .padding(.horizontal, SpeechRailDesignTokens.Layout.contentPadding)
        .padding(.vertical, SpeechRailDesignTokens.Layout.contentPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

public extension PageScaffold where Trailing == EmptyView {
    init(
        route: AppRoute,
        scrollable: Bool = true,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            route: route,
            scrollable: scrollable,
            subtitle: subtitle,
            content: content,
            trailing: { EmptyView() }
        )
    }
}

public struct SectionHeading: View {
    public let title: String
    public let detail: String?

    public init(title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Text(title)
                .font(SpeechRailDesignTokens.Typography.sectionTitle)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Figma `card`：内容卡只负责外观 —— 系统内容面与圆角裁切。卡片按内容取高，
/// 内部的标题带、行与说明带由调用方按 `head` / `hairline` / `listFoot` 的顺序排列，
/// 因此同一张卡既能装列表，也能装矩阵或键值行（REDESIGN-SPEC §5.2）。
public struct CardSurface<Content: View>: View {
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
        .clipShape(ConcentricRectangle())
    }
}

/// Figma `head` / `listHead`：卡片顶部的标题带 —— 标题与一句说明在左，
/// 计数、状态或控件在右。与 `SectionHeading` 同源，卡片内外的标题不会分成两套。
public struct CardHead<Trailing: View>: View {
    private let title: String
    private let detail: String?
    private let trailing: Trailing

    public init(title: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.sm) {
            SectionHeading(title: title, detail: detail)
            trailing
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        .accessibilityElement(children: .contain)
    }
}

public extension CardHead where Trailing == EmptyView {
    init(title: String, detail: String? = nil) {
        self.init(title: title, detail: detail) { EmptyView() }
    }
}

/// Figma `listFoot`：卡片底部的说明带 —— 一句本机事实在左，次级动作在右。
public struct CardFoot<Action: View>: View {
    private let note: String
    private let action: Action

    public init(note: String, @ViewBuilder action: () -> Action) {
        self.note = note
        self.action = action()
    }

    public var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            Text(note)
                .font(SpeechRailDesignTokens.Typography.secondary)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
            action
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
    }
}

/// Figma `Status Pill`：语义色胶囊，图标 + 短标签。状态永远不只靠颜色表达
/// （REDESIGN-SPEC §9），所以每一项都自带图标与文字。
public struct StatusPill: View {
    public let tone: StatusTone
    public let label: String

    public init(tone: StatusTone, label: String) {
        self.tone = tone
        self.label = label
    }

    public var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
            Image(systemName: tone.systemImage)
                .font(SpeechRailDesignTokens.Typography.caption)
                .accessibilityHidden(true)
            Text(label)
                .font(SpeechRailDesignTokens.Typography.caption)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(tone.color)
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)
        .background(tone.color.opacity(SpeechRailDesignTokens.Surface.statusTintOpacity), in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

/// Figma `kbd`：键帽。裸写「⌘⏎」读起来像一个游离的字符，键帽才读得出这是
/// 快捷键（REDESIGN-SPEC §7.1 / §7.2）。键帽本身不承载点击，只承载提示，
/// 因此对辅助技术隐藏 —— 按钮自己的 accessibilityHint 已经说明了这个快捷键。
public struct KeyboardHint: View {
    public let label: String

    public init(_ label: String) {
        self.label = label
    }

    public var body: some View {
        Text(label)
            .font(SpeechRailDesignTokens.Typography.caption)
            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            .lineLimit(1)
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.micro)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)
            .background(SpeechRailDesignTokens.Color.field, in: ConcentricRectangle())
            .overlay {
                ConcentricRectangle()
                    .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

/// A single, named entry point for low-frequency workspace actions.
///
/// The menu deliberately owns the label so pages cannot drift into a row of
/// unlabeled toolbar glyphs. Primary actions still belong next to the state
/// they change in the page body.
public struct WorkspaceActionsMenu<Content: View>: View {
    private let helpText: String
    private let content: Content

    public init(
        helpText: String,
        @ViewBuilder content: () -> Content
    ) {
        self.helpText = helpText
        self.content = content()
    }

    public var body: some View {
        Menu {
            content
        } label: {
            Label("更多操作", systemImage: "ellipsis")
                .labelStyle(.titleAndIcon)
                .font(SpeechRailDesignTokens.Typography.label)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .frame(
                    minWidth: SpeechRailDesignTokens.Interaction.minimumHitTarget,
                    minHeight: SpeechRailDesignTokens.Menu.triggerHeight
                )
                .padding(.horizontal, SpeechRailDesignTokens.Menu.triggerHorizontalPadding)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .controlSize(.regular)
        .accessibilityLabel("更多操作")
        .accessibilityIdentifier("workspace-actions")
        .help(helpText)
        .speechRailPointerCursor()
    }
}

public struct StatusBanner: View {
    public let tone: StatusTone
    public let title: String
    public let message: String
    public let actionTitle: String?
    public let action: (() -> Void)?
    public let actionDisabled: Bool

    public init(
        tone: StatusTone,
        title: String,
        message: String,
        actionTitle: String? = nil,
        actionDisabled: Bool = false,
        action: (() -> Void)? = nil
    ) {
        self.tone = tone
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.actionDisabled = actionDisabled
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalLayout
            verticalLayout
        }
        .padding(SpeechRailDesignTokens.Spacing.md)
        .speechRailField()
        .accessibilityElement(children: .contain)
    }

    private var horizontalLayout: some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.md) {
            bannerIcon
            bannerCopy
            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
            bannerAction
        }
    }

    private var verticalLayout: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.md) {
                bannerIcon
                bannerCopy
            }
            bannerAction
        }
    }

    private var bannerIcon: some View {
        Image(systemName: tone.systemImage)
            .font(SpeechRailDesignTokens.Typography.statusIcon)
            .foregroundStyle(tone.color)
            .accessibilityHidden(true)
    }

    private var bannerCopy: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Text(title)
                .font(SpeechRailDesignTokens.Typography.statusTitle)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(message)
                .font(SpeechRailDesignTokens.Typography.body)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var bannerAction: some View {
        if let actionTitle, let action {
            Button(actionTitle, action: action)
                .speechRailButton(.primary)
                .disabled(actionDisabled)
        }
    }
}

/// A lightweight state row for context that belongs next to the action it
/// explains. Unlike `StatusBanner`, it does not create another card surface;
/// use it for capability, loading, playback, and selection context.
public struct SpeechRailStatusLine: View {
    public let tone: StatusTone
    public let title: String
    public let message: String
    public let systemImage: String?

    public init(
        tone: StatusTone,
        title: String,
        message: String,
        systemImage: String? = nil
    ) {
        self.tone = tone
        self.title = title
        self.message = message
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.xs) {
            Rectangle()
                .fill(tone.color)
                .frame(width: SpeechRailDesignTokens.Control.purposeIndicatorWidth)
                .accessibilityHidden(true)
            if let systemImage {
                Image(systemName: systemImage)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(tone.color)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(title)
                    .font(SpeechRailDesignTokens.Typography.label)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(message)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(message)")
    }
}

public struct ServiceOperationStatusView: View {
    public let operation: ServiceOperationStatus
    public let actionTitle: String?
    public let action: (() -> Void)?

    public init(
        operation: ServiceOperationStatus,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.operation = operation
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalLayout
            verticalLayout
        }
        .padding(SpeechRailDesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .speechRailField()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(operationTitle)，\(SpeechRailOperationMessagePresentation.text(operation.message ?? defaultMessage))"
        )
    }

    private var horizontalLayout: some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
            operationIconView
            operationCopy
            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
            operationAction
        }
    }

    private var verticalLayout: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
                operationIconView
                operationCopy
            }
            operationAction
        }
    }

    private var operationIconView: some View {
        Image(systemName: operationIcon)
            .font(SpeechRailDesignTokens.Typography.statusIcon)
            .foregroundStyle(tone.color)
            .accessibilityHidden(true)
    }

    private var operationCopy: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Text(operationTitle)
                .font(SpeechRailDesignTokens.Typography.sectionTitle)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            if operation.phase.isActive {
                ProgressView()
                    .controlSize(.small)
                    .tint(SpeechRailDesignTokens.Color.rail)
            }
            Text(SpeechRailOperationMessagePresentation.text(operation.message ?? defaultMessage))
                .font(SpeechRailDesignTokens.Typography.secondary)
                .foregroundStyle(tone.color)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var operationAction: some View {
        if let actionTitle, let action {
            Button(actionTitle, action: action)
                .speechRailButton(.secondary)
        }
    }

    private var commandTitle: String {
        switch operation.command {
        case .start:
            "启动服务"
        case .stop:
            "停止服务"
        case .restart:
            "重启服务"
        default:
            "服务操作"
        }
    }

    private var operationTitle: String {
        switch operation.phase {
        case .starting:
            "正在启动服务"
        case .stopping:
            "正在停止服务"
        case .restarting:
            "正在重启服务"
        case .healthChecking:
            "健康检查中"
        case .completed:
            "\(commandTitle)已完成"
        case .failed:
            "\(commandTitle)未完成"
        }
    }

    private var defaultMessage: String {
        switch operation.phase {
        case .starting:
            "正在请求受管服务启动…"
        case .stopping:
            "正在请求受管服务停止…"
        case .restarting:
            "正在请求受管服务重启…"
        case .healthChecking:
            "正在读取服务与能力状态…"
        case .completed:
            "服务命令已完成。"
        case .failed:
            "服务命令未完成，请重新读取或打开诊断。"
        }
    }

    private var operationIcon: String {
        switch operation.phase {
        case .starting:
            "play.circle"
        case .stopping:
            "stop.circle"
        case .restarting, .healthChecking:
            "arrow.clockwise.circle"
        case .completed:
            "checkmark.circle"
        case .failed:
            "xmark.circle"
        }
    }

    private var tone: StatusTone {
        switch operation.phase {
        case .starting, .stopping, .restarting, .healthChecking:
            .attention
        case .completed:
            .healthy
        case .failed:
            .critical
        }
    }
}

public struct ServiceOperationCompactStatus: View {
    public let operation: ServiceOperationStatus

    public init(operation: ServiceOperationStatus) {
        self.operation = operation
    }

    public var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            if operation.phase.isActive {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: operation.phase == .failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(SpeechRailDesignTokens.Typography.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
        }
        .foregroundStyle(operation.phase == .failed ? SpeechRailDesignTokens.Color.critical : SpeechRailDesignTokens.Color.inkSecondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    private var title: String {
        let command = switch operation.command {
        case .start: "启动服务"
        case .stop: "停止服务"
        case .restart: "重启服务"
        default: "服务操作"
        }
        return switch operation.phase {
        case .starting: "正在启动服务…"
        case .stopping: "正在停止服务…"
        case .restarting: "正在重启服务…"
        case .healthChecking: "健康检查中…"
        case .completed: "\(command)已完成"
        case .failed: "\(command)未完成"
        }
    }
}

public struct MetricValue: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let value: String
    public let detail: String

    public init(id: String, title: String, value: String, detail: String) {
        self.id = id
        self.title = title
        self.value = value
        self.detail = detail
    }
}

private struct MetricValueView: View {
    let metric: MetricValue

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Text(metric.title)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .lineLimit(1)
            Text(metric.value)
                .font(SpeechRailDesignTokens.Typography.metricValue)
                .monospacedDigit()
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(metric.detail)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(
            minWidth: SpeechRailDesignTokens.Layout.metricMinimumWidth,
            maxWidth: .infinity,
            alignment: .leading
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(metric.title)
        .accessibilityValue("\(metric.value)，\(metric.detail)")
    }
}

public struct MetricStrip: View {
    public let metrics: [MetricValue]

    public init(metrics: [MetricValue]) {
        self.metrics = metrics
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                    if index > 0 {
                        Divider()
                            .frame(height: SpeechRailDesignTokens.Layout.compactDividerHeight)
                            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                    }
                    MetricValueView(metric: metric)
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
            .speechRailConsoleChassis()

            MetricGrid(metrics: metrics)
        }
        .accessibilityElement(children: .contain)
    }
}

public struct MetricGrid: View {
    public let metrics: [MetricValue]
    private let columnCount: Int

    public init(
        metrics: [MetricValue],
        columnCount: Int = SpeechRailDesignTokens.Layout.metricColumnCount
    ) {
        self.metrics = metrics
        self.columnCount = max(1, columnCount)
    }

    public var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(
                    .flexible(minimum: SpeechRailDesignTokens.Layout.metricMinimumWidth),
                    spacing: SpeechRailDesignTokens.Spacing.md
                ),
                count: columnCount
            ),
            alignment: .leading,
            spacing: SpeechRailDesignTokens.Spacing.md
        ) {
            ForEach(metrics) { metric in
                MetricValueView(metric: metric)
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.md)
        .speechRailConsoleChassis()
        .accessibilityElement(children: .contain)
    }
}

public struct OperationBar: View {
    public let operation: OperationSnapshot?
    public let actionTitle: String?
    public let action: (() -> Void)?

    public init(
        operation: OperationSnapshot?,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.operation = operation
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        if let operation {
            ViewThatFits(in: .horizontal) {
                horizontalLayout(for: operation)
                verticalLayout(for: operation)
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
            .speechRailField()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(operationAccessibilityLabel(for: operation))
        }
    }

    private func horizontalLayout(for operation: OperationSnapshot) -> some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
            operationSummary(for: operation)
            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
            operationAction
        }
    }

    private func verticalLayout(for operation: OperationSnapshot) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            operationSummary(for: operation)
            operationAction
        }
    }

    private func operationSummary(for operation: OperationSnapshot) -> some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Image(systemName: operationIcon(for: operation))
                .font(SpeechRailDesignTokens.Typography.statusIcon)
                .foregroundStyle(operationTone(for: operation.state).color)
                .accessibilityHidden(true)
            operationDetails(for: operation)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func operationDetails(for operation: OperationSnapshot) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text(operationTitle(for: operation))
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let phase = operation.phase {
                    Text("· \(operationPhaseText(phase))")
                        .font(SpeechRailDesignTokens.Typography.secondary)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if let progress = operation.progress,
               let completed = progress.completedBytes,
               let expected = progress.expectedBytes,
               expected > 0
            {
                let percent = min(1.0, max(0.0, Double(completed) / Double(expected)))
                ProgressView(value: percent)
                    .controlSize(.small)
                    .tint(SpeechRailDesignTokens.Color.rail)
                HStack {
                    Text("\(ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(String(format: "%.1f%%", percent * 100))
                }
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            if let progress = operation.progress {
                if let artifactKey = progress.artifactKey ?? progress.file {
                    Text("当前制品：\(artifactKey)")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let file = progress.file, progress.artifactKey != nil {
                    Text("当前文件：\(file)")
                        .font(SpeechRailDesignTokens.Typography.technical)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if progress.completedBytes == nil || progress.expectedBytes == nil {
                    Text("字节进度：未提供")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
            }
            if operation.command == .modelPrepare {
                Text("速度与预计时间：协议未提供")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            }
            if let message = operation.message, !message.isEmpty {
                Text(SpeechRailOperationMessagePresentation.text(message))
                    .font(SpeechRailDesignTokens.Typography.secondary)
                    .foregroundStyle(operationTone(for: operation.state).color)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var operationAction: some View {
        if let actionTitle, let action {
            Button(actionTitle, action: action)
                .speechRailButton(.secondary)
        }
    }

    private func operationTitle(for operation: OperationSnapshot) -> String {
        let applyingProfile = operation.command == .profileApply
        return switch operation.state {
        case .accepted, .running:
            applyingProfile ? "正在应用档位" : "正在准备模型"
        case .interrupted:
            applyingProfile ? "档位应用被中断" : "上次模型准备被中断"
        case .committed:
            applyingProfile ? "档位应用完成" : "模型准备完成"
        case .failed:
            applyingProfile ? "档位应用失败" : "模型准备失败"
        case .cancelled:
            applyingProfile ? "档位应用已取消" : "模型准备已取消"
        }
    }

    private func operationIcon(for operation: OperationSnapshot) -> String {
        switch operation.state {
        case .accepted, .running:
            operation.command == .profileApply
                ? "arrow.triangle.2.circlepath.circle"
                : "arrow.down.circle"
        case .interrupted:
            "exclamationmark.triangle"
        case .committed:
            "checkmark.circle"
        case .failed:
            "xmark.circle"
        case .cancelled:
            "stop.circle"
        }
    }

    private func operationTone(for state: OperationState) -> StatusTone {
        switch state {
        case .accepted, .running:
            .attention
        case .interrupted, .failed:
            .critical
        case .committed:
            .healthy
        case .cancelled:
            .neutral
        }
    }

    private func operationPhaseText(_ phase: String) -> String {
        switch phase.lowercased() {
        case "accepted":
            "已接收"
        case "prepare", "preparing":
            "准备中"
        case "download", "downloading":
            "下载中"
        case "verify", "verifying":
            "校验中"
        case "apply", "applying":
            "应用中"
        case "reload", "reloading":
            "重载中"
        case "smoke", "smoke_test":
            "健康检查中"
        case "publish", "publishing":
            "发布中"
        case "cache_hit":
            "已存在"
        case "committed", "completed":
            "已完成"
        case "failed":
            "失败"
        case "cancelled", "canceled":
            "已取消"
        case "cancelling", "canceling":
            "正在停止"
        case "interrupted":
            "已中断"
        default:
            "处理中"
        }
    }

    private func operationAccessibilityLabel(for operation: OperationSnapshot) -> String {
        var parts = [operationTitle(for: operation)]
        if let phase = operation.phase { parts.append(operationPhaseText(phase)) }
        if let message = operation.message {
            parts.append(SpeechRailOperationMessagePresentation.text(message))
        }
        return parts.joined(separator: "，")
    }
}

public struct DeveloperInspector<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Inspector.sectionSpacing) {
                Text("开发者详情")
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(SpeechRailDesignTokens.Inspector.titleMaximumLines)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Inspector.rowSpacing) {
                    content
                        .speechRailInspectorContent()
                        .accessibilityElement(children: .contain)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(
                maxWidth: .infinity,
                alignment: .leading
            )
            .padding(SpeechRailDesignTokens.Inspector.contentPadding)
            .fixedSize(horizontal: false, vertical: true)
        }
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize)
        .frame(
            minWidth: SpeechRailDesignTokens.Layout.inspectorMinimumWidth,
            idealWidth: SpeechRailDesignTokens.Layout.inspectorIdealWidth,
            maxWidth: SpeechRailDesignTokens.Layout.inspectorMaximumWidth,
            alignment: .topLeading
        )
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .inspectorColumnWidth(
            min: SpeechRailDesignTokens.Layout.inspectorMinimumWidth,
            ideal: SpeechRailDesignTokens.Layout.inspectorIdealWidth,
            max: SpeechRailDesignTokens.Layout.inspectorMaximumWidth
        )
        .background(SpeechRailDesignTokens.Surface.inspectorFill)
    }
}

/// One label column, one right-aligned value. A fixed label column is what
/// makes a stack of inspector rows scannable instead of ragged
/// (REDESIGN-SPEC §7.3).
public struct SpeechRailInspectorLabeledContentStyle: LabeledContentStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SpeechRailDesignTokens.Spacing.sm) {
            configuration.label
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .lineLimit(SpeechRailDesignTokens.Inspector.titleMaximumLines)
                .frame(
                    width: SpeechRailDesignTokens.Inspector.labelColumnWidth,
                    alignment: .leading
                )
            configuration.content
                .font(SpeechRailDesignTokens.Typography.technical)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineLimit(SpeechRailDesignTokens.Inspector.valueMaximumLines)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, SpeechRailDesignTokens.Inspector.rowVerticalPadding)
    }
}

// MARK: - Focused scene commands

/// A per-window action the focused page publishes, so menu commands can act on
/// "the selected work" without the App layer reaching into page state
/// (REDESIGN-SPEC §6.3).
public struct SelectedWorkCommand {
    public let title: String
    private let action: () -> Void

    public init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public func callAsFunction() {
        action()
    }
}

extension SelectedWorkCommand: Equatable {
    public static func == (lhs: SelectedWorkCommand, rhs: SelectedWorkCommand) -> Bool {
        lhs.title == rhs.title
    }
}

private struct SelectedWorkCommandKey: FocusedValueKey {
    typealias Value = SelectedWorkCommand
}

public extension FocusedValues {
    var selectedWorkCommand: SelectedWorkCommand? {
        get { self[SelectedWorkCommandKey.self] }
        set { self[SelectedWorkCommandKey.self] = newValue }
    }
}
