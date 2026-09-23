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
        // 稿的控件高度（Figma `size/control` 34 / 次按钮 30）与系统控件档位的对应
        // 关系在本机离屏量过（`ImageRenderer`，无窗口）：`.regular` 24 / `.large` 28 /
        // `.extraLarge` 36。所以主按钮取 `.extraLarge`（残差 2pt）、次按钮取 `.large`
        // （残差 2pt）；`.quiet` 没有填充与描边，尺寸只影响命中区，保持系统默认档
        // （REDESIGN-SPEC §11.6 第二十一轮）。
        .controlSize(controlSize)
        .contentShape(Rectangle())
        .speechRailPointerCursor()
    }

    private var controlSize: ControlSize {
        switch level {
        case .primary: .extraLarge
        case .secondary, .destructive: .large
        case .quiet: .regular
        }
    }
}

/// 交互填色的形状档位。
///
/// 行 / 叶面用同心推导（`Corner.nestedShape`，跟着所在容器走）；**自带底色的卡片**
/// 用容器档（`Corner.containerShape`，12pt）——否则填色的圆角会比卡片本身小一档、
/// 在四角露出来（REDESIGN-SPEC §11.6 第五十二轮）。
public enum SpeechRailInteractiveCorner: Sendable {
    case nested
    case container
}

/// A shared style for custom rows/cards that are buttons but intentionally do
/// not look like standard toolbar or form buttons.
public struct SpeechRailInteractiveButtonStyle: ButtonStyle {
    private let fillsAvailableWidth: Bool
    private let minimumHeight: CGFloat
    private let horizontalInset: CGFloat
    private let baseFill: SwiftUI.Color
    private let corner: SpeechRailInteractiveCorner

    /// `minimumHeight` 默认就是 `Interaction.minimumHitTarget`(44)。只有**稿上明确
    /// 更矮**的一处会传别的值：侧栏底部状态行（稿 `sidebarStatus` 是 220 × 30）——
    /// 30 仍在 macOS 指针目标的 24pt 下限之上（REDESIGN-SPEC §11.6 第四十三轮）。
    ///
    /// `horizontalInset` 默认 `Spacing.xs`(8)：行/叶面按钮的悬停填色比内容各宽 8pt，
    /// 读起来是一圈柔和的外扩。**自带底色的卡片要传 0**——那 8pt 会变成卡片
    /// 与相邻卡片之间的可见空隙（模型页档位卡实测 27.5pt，稿是 12pt：
    /// 卡间 `Spacing.sm`(12) + 每张卡左右各 8）。
    ///
    /// `baseFill` 是这类交互面的**底色**；状态色叠在它上面（见 `backgroundShape`）。
    public init(
        fillsAvailableWidth: Bool = false,
        minimumHeight: CGFloat = SpeechRailDesignTokens.Interaction.minimumHitTarget,
        horizontalInset: CGFloat = SpeechRailDesignTokens.Spacing.xs,
        baseFill: SwiftUI.Color = .clear,
        corner: SpeechRailInteractiveCorner = .nested
    ) {
        self.fillsAvailableWidth = fillsAvailableWidth
        self.minimumHeight = minimumHeight
        self.horizontalInset = horizontalInset
        self.baseFill = baseFill
        self.corner = corner
    }

    public func makeBody(configuration: Configuration) -> some View {
        SpeechRailInteractiveButtonBody(
            configuration: configuration,
            fillsAvailableWidth: fillsAvailableWidth,
            minimumHeight: minimumHeight,
            horizontalInset: horizontalInset,
            baseFill: baseFill,
            corner: corner
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
                // 这里**不能**再垫一层 `Color.clear`：它会接受任意高度提案，于是
                // 这一行、整条按钮、进而整个动作区都变成**竖直弹性**的。动作区与
                // 上面的 `ScrollView` 是兄弟节点，两个弹性孩子会平分栏目高度——
                // 离屏实测（`--works-inspector`，360 × 900 / 720，展开「技术上下文」）：
                // 正文区被压到栏目的一半（642 → 296.5），动作区下方留出 360pt 空白。
                // 整宽提案本来由下面 `.frame(maxWidth: .infinity)` 给（标签文字自己也
                // 有 `maxWidth: .infinity`），去掉这一层不改变这一行的宽度、命中区与
                // 悬停填色（REDESIGN-SPEC §11.6 第五十四轮）。
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
    let minimumHeight: CGFloat
    let horizontalInset: CGFloat
    let baseFill: SwiftUI.Color
    let corner: SpeechRailInteractiveCorner

    var body: some View {
        labelContent
            .frame(
                minWidth: SpeechRailDesignTokens.Interaction.minimumHitTarget,
                maxWidth: fillsAvailableWidth ? .infinity : nil,
                minHeight: minimumHeight,
                alignment: .leading
            )
            .padding(.horizontal, horizontalInset)
            .background(backgroundShape)
            .speechRailFocusRing(isFocused)
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
        // 底色与状态色**叠在同一个背景层里**：状态色本身是半透明填色（`Surface.interactionHover`
        // / `.interactionPressed`），单独铺一层会让自带底色的卡片在悬停时「白底消失」、
        // 变成一片压在页面地板上的灰。两层同形同尺寸，状态色只做「再深一档」。
        ZStack {
            shape.fill(baseFill)
            if isEnabled {
                if configuration.isPressed {
                    shape.fill(SpeechRailDesignTokens.Surface.interactionPressed)
                } else if isHovered {
                    shape.fill(SpeechRailDesignTokens.Surface.interactionHover)
                }
            }
        }
        .overlay {
            // Hover is a fill step, never an outline (§5.2): an interactive
            // container stays borderless and the fill above already carries the
            // state. Focus keeps the system ring, not a separator hairline.
            EmptyView()
        }
    }

    private var shape: AnyShape {
        switch corner {
        case .nested: AnyShape(SpeechRailDesignTokens.Corner.nestedShape)
        case .container: AnyShape(SpeechRailDesignTokens.Corner.containerShape)
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

    func speechRailInteractiveButtonStyle(
        fillsAvailableWidth: Bool = false,
        minimumHeight: CGFloat = SpeechRailDesignTokens.Interaction.minimumHitTarget,
        horizontalInset: CGFloat = SpeechRailDesignTokens.Spacing.xs,
        baseFill: SwiftUI.Color = .clear,
        corner: SpeechRailInteractiveCorner = .nested
    ) -> some View {
        buttonStyle(
            SpeechRailInteractiveButtonStyle(
                fillsAvailableWidth: fillsAvailableWidth,
                minimumHeight: minimumHeight,
                horizontalInset: horizontalInset,
                baseFill: baseFill,
                corner: corner
            )
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

public enum StatusTone: Sendable, Equatable {
    case neutral
    case healthy
    case attention
    case critical

    var color: Color {
        switch self {
        case .neutral:
            SpeechRailDesignTokens.Color.inkSecondary
        case .healthy:
            SpeechRailDesignTokens.Color.ready
        case .attention:
            SpeechRailDesignTokens.Color.attention
        case .critical:
            SpeechRailDesignTokens.Color.critical
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

    var accessibilityLabel: String {
        switch self {
        case .neutral: "一般状态"
        case .healthy: "正常"
        case .attention: "需要注意"
        case .critical: "受阻"
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
    /// 侧边栏底部状态区用的是短名（`服务已就绪 · 均衡`，macOS App 设计系统 §4.1），
    /// 卡片与取值行才用 `title` 的「档位 · 取向」写法。
    ///
    /// **一律给中文名**（用户 2026-09-19：「还有一些用户看不懂的词汇」）：原来这里原样
    /// 摆着 `Extreme` / `Quality` / `Balanced` / `Light`——那是制品与 CLI 的 preset 名，中文界面里
    /// 既读不出来也记不住，而用户在这一行要知道的只是「这台 Mac 现在处在哪一档」。
    /// 内部键（`quality` 等）只留在开发者文档与诊断页：那里本来就是对着 CLI 看的。
    static func shortTitle(_ profile: SpeechRailProfile) -> String {
        switch profile {
        case .extreme:
            "极致"
        case .quality:
            "精准"
        case .balanced:
            "均衡"
        case .light:
            "轻量"
        case .unrecognized:
            "未识别的档位"
        }
    }

    static func title(_ profile: SpeechRailProfile) -> String {
        switch profile {
        case .extreme:
            "极致 · 更高权重精度"
        case .quality:
            "精准 · 支持音色创作"
        case .balanced:
            "均衡 · 日常使用"
        case .light:
            "轻量 · 模型文件较小"
        case .unrecognized:
            "未识别的档位"
        }
    }

    /// 档位卡上那句「这一档对用户意味着什么」；效果对比尚无证据时不按权重精度推断质量。
    static func purpose(_ profile: SpeechRailProfile) -> String {
        switch profile {
        case .extreme:
            "使用更高精度的模型，支持音色创作和克隆；识别、配音效果与速度尚未完成对比验证。"
        case .quality:
            "支持音色创作和克隆；与「极致」的实际效果差异尚未完成对比验证。"
        case .balanced:
            "支持区分说话人，适合日常识别与配音。"
        case .light:
            "使用较小的模型文件；不区分说话人，也不能创作音色。"
        case .unrecognized:
            "服务返回了 App 尚不认识的档位；请更新 App 后再管理模型。"
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
            return "换档没成功，请重试；还不行就打开「诊断」看原因。"
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

/// The explicit outer-layout contract for every workspace surface.
public enum PageScaffoldLayout: Equatable, Sendable {
    /// Content keeps its intrinsic height while the page shell fills the detail column.
    case content
    /// The page stays within its window pane; long content must scroll in its own bounded panel.
    case fill(minimumHeight: CGFloat)
    /// The whole page is one intentional scrolling surface and can grow beyond the pane.
    case scroll(minimumHeight: CGFloat)
}

/// The shared page geometry for every workspace surface.
///
/// The scaffold owns the content margins and the page's one-line purpose
/// statement — nothing else. The toolbar carries the page title
/// (`PageIdentityToolbarItem`), so the body never repeats the page name; it opens
/// with the purpose sentence and then goes straight to the main object
/// (REDESIGN-SPEC §6.2 / §11.6 第四十九轮).
/// Full-height workspaces keep a finite viewport; scrolling belongs to bounded content panels.
public struct PageScaffold<Content: View, Trailing: View>: View {
    private enum ContentSizing {
        case fixed
        case grows
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let route: AppRoute
    public let layout: PageScaffoldLayout
    private let purpose: String?
    private let trailing: Trailing
    private let content: Content

    public init(
        route: AppRoute,
        layout: PageScaffoldLayout = .scroll(minimumHeight: 0),
        purpose: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.route = route
        self.layout = layout
        self.purpose = purpose
        self.content = content()
        self.trailing = trailing()
    }

    @ViewBuilder
    public var body: some View {
        Group {
            switch layout {
            case .content:
                pageContent
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            case .fill(let minimumHeight):
                GeometryReader { proxy in
                    pageContent(
                        paneHeight: proxy.size.height,
                        minimumHeight: minimumHeight,
                        sizing: .fixed
                    )
                }
            case .scroll(let minimumHeight):
                if minimumHeight > 0 {
                    // 量窗格 → 算出正文的固定高度 → 仍交给滚动容器兜底。
                    GeometryReader { proxy in
                        ScrollView {
                            pageContent(
                                paneHeight: proxy.size.height,
                                minimumHeight: minimumHeight,
                                sizing: .grows
                            )
                        }
                    }
                } else {
                    ScrollView {
                        pageContent
                    }
                }
            }
        }
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }

    /// 页首「一句话说明」：当前 14 个页面都以同一句话开场（Figma `pageHead` 的第二行），
    /// 页面名不在这里——它在工具栏的身份槽（§6.2）。
    private var pagePurpose: some View {
        HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.lg) {
            Text(purpose ?? route.pageSubtitle)
                .font(SpeechRailDesignTokens.Typography.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                // 两行上限不是排版偏好，而是**界面的最小高度**：`fixedSize(vertical:)`
                // 让这一行在「未定宽度提案」下按极窄宽度测量，一句 20 字的说明因此报出
                // 三百多点的理想高度，把整页的最小高度抬高到声明的最小窗口之上——
                // 离屏实测（`NSHostingView`，1440 宽）配音台 760、我的作品 889、诊断 664，
                // 而声明的最小窗口高是 720；`.inspector` 会把这个最小高度当成自己的
                // 下限，宿主比它矮时内容按底对齐、页首被裁（第三十轮）。
                // 加上 `.lineLimit(2)` 后：配音台 475、我的作品 529、诊断 454，都在 720 以内，
                // 一行的自然渲染与 900 高时的像素位置不变。
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var pageContent: some View {
        // 页头与正文之间是「块与块」，用稿实测的页面级间距（20pt）而不是 lg(24)：
        // 帧上页头末行到第一张卡之间也是 20pt（REDESIGN-SPEC §5.6 / §11.6 第十七轮）。
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.gutter) {
            pagePurpose
            content
        }
        .padding(.horizontal, SpeechRailDesignTokens.Layout.contentPadding)
        .padding(.vertical, SpeechRailDesignTokens.Layout.contentPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// 正文固定高度版：整块内容拿到一个**确定**高度，页头按自己的一两行取高，正文吃掉
    /// 剩下的全部——于是「正文多高」不再由正文自己决定（不用 `minHeight`：它只能抬高
    /// 下限，内容该撑多高还是多高，等于没改）。
    ///
    /// 正文槽位不低于页面合同声明的最小高度，避免把列表、目录等内部面板压扁到不可用。
    /// `.fill` 调用方必须让长内容所在的面板拿到有限高度，并由该面板自己滚动。
    ///
    /// `sizing: .grows` 时这层框架用 `minHeight` 而不是固定高度：内容比窗格矮时
    /// 效果与定高完全一样（卡片照样吃满窗口），内容比窗格高时整个页面长高，交给外层
    /// `ScrollView` 承载。只有明确采用整页连续阅读的页面才应选择这档；工作台应优先用
    /// `.fixed`，并将长内容交给各自的有界面板。
    private func pageContent(
        paneHeight: CGFloat,
        minimumHeight: CGFloat,
        sizing: ContentSizing
    ) -> some View {
        let padding = SpeechRailDesignTokens.Layout.contentPadding
        let slot = max(paneHeight - padding * 2, minimumHeight)
        let padded = VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.gutter) {
            pagePurpose
            content
                .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, SpeechRailDesignTokens.Layout.contentPadding)
        .padding(.vertical, SpeechRailDesignTokens.Layout.contentPadding)

        return Group {
            switch sizing {
            case .grows:
                // `+ Spacing.xs` 是**刀口余量**，不是排版偏好：卡片吃满窗口之后，内容真正
                // 需要的高度比它报出去的多几 pt（亚像素累积），滚动容器于是判「装得下」，
                // SwiftUI 就从最后一行文字身上挤出那几 pt，卡片再 `clipShape` 就是一道硬切。
                // 留出这一档余量后，内容**永远**比窗格高一点点：多出来的高度落在卡片自己的
                // 留白里（可见版面不变），滚动条也不会再判错。
                // 离屏实测 2026-09-19（1200 宽）：窗高 900 裁掉字幕空态页脚那一行的下半截，
                // 820 与 ≥905 都不裁——正是这个刀口。
                padded.frame(
                    minHeight: slot + padding * 2 + SpeechRailDesignTokens.Spacing.xs,
                    alignment: .topLeading
                )
            case .fixed:
                padded.frame(height: slot + padding * 2, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

public extension PageScaffold where Trailing == EmptyView {
    init(
        route: AppRoute,
        layout: PageScaffoldLayout = .scroll(minimumHeight: 0),
        purpose: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            route: route,
            layout: layout,
            purpose: purpose,
            content: content,
            trailing: { EmptyView() }
        )
    }
}

public struct SectionHeading: View {
    public let title: String
    public let detail: String?
    /// 标题是否吃掉整行宽度。
    ///
    /// 页内标题取 `true`（只有它一个对象，贪心与不贪心看不出区别）。卡片头里凡是右侧
    /// 还有「贴着标题的状态」和「贴着右边缘的事实」两项时取 `false`：标题若也贪心，
    /// 这两项会被一起挤到最右，状态就不再贴着标题（稿的音色克隆录制卡正是这一种）。
    private let fillsWidth: Bool

    public init(title: String, detail: String? = nil, fillsWidth: Bool = true) {
        self.title = title
        self.detail = detail
        self.fillsWidth = fillsWidth
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Text(title)
                .font(SpeechRailDesignTokens.Typography.sectionTitle)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// 稿里的选择行（音色克隆的提词稿）是「放不下就换行」：`HStack` 会把超出的选项挤出去，
/// `ScrollView(.horizontal)` 会把它们藏起来，两种都读不出「一共有几个选项」。
/// 系统在 macOS 26 上没有逐项折行的容器（`ViewThatFits` 只给整体方案，不负责逐项排布），
/// 所以这一条规则自己实现一次。
public struct WrapHStack: Layout {
    private let spacing: CGFloat
    private let lineSpacing: CGFloat

    public init(spacing: CGFloat, lineSpacing: CGFloat? = nil) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing ?? spacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maximumWidth = proposal.width ?? .infinity
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widestLine: CGFloat = 0
        var totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let extended = lineWidth == 0 ? size.width : lineWidth + spacing + size.width
            if extended > maximumWidth, lineWidth > 0 {
                widestLine = max(widestLine, lineWidth)
                totalHeight += lineHeight + lineSpacing
                lineWidth = size.width
                lineHeight = size.height
            } else {
                lineWidth = extended
                lineHeight = max(lineHeight, size.height)
            }
        }
        widestLine = max(widestLine, lineWidth)
        totalHeight += lineHeight
        return CGSize(width: min(widestLine, maximumWidth), height: totalHeight)
    }

    public func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
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
        // 卡片底色已经是容器形状：裁切必须用同一形状，否则零半径的裁切会把
        // 刚得到的那两个圆角切回直角。
        .clipShape(SpeechRailDesignTokens.Corner.containerShape)
    }
}

/// Figma `head` / `listHead`：卡片顶部的标题带 —— 标题与一句说明在左，
/// 计数、状态或控件在右。与 `SectionHeading` 同源，卡片内外的标题不会分成两套。
public struct CardHead<Trailing: View>: View {
    private let title: String
    private let detail: String?
    /// 右边缘的一句本机事实（音色克隆录制卡的设备名）。
    ///
    /// 它单独是一个槽位，而不是塞进 `trailing`：稿的卡片头读法是
    /// **标题 → 状态 → 弹性空档 → 事实**，状态要贴着标题，事实要贴着右边缘。
    /// 两者放进同一个尾巴里，中间那段空档会把它们一起推向右半边。
    private let accessory: String?
    private let trailing: Trailing

    public init(
        title: String,
        detail: String? = nil,
        accessory: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.detail = detail
        self.accessory = accessory
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.sm) {
            // 有右侧事实时标题不贪心（见 `SectionHeading.fillsWidth`）。没有右侧事实时
            // 维持原样：标题占满剩余宽度，尾巴自然贴到右边缘——十四个页面都是这么读的。
            SectionHeading(title: title, detail: detail, fillsWidth: accessory == nil)
            trailing
            if let accessory, !accessory.isEmpty {
                Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
                Text(accessory)
                    .font(SpeechRailDesignTokens.Typography.secondary)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel(accessory)
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        // 稿上这是两个组件：只有标题的列表头（`listHead`，padY 12 → 帧实测带高 42）
        // 与「标题 + 一句说明」的内容卡头（`head`，padY 16 → 帧实测带高 70）。
        // 应用此前都用 12，两行头比稿矮 12pt（系统的行高本身还比稿紧约 3.5pt/行，
        // 那部分不追）。REDESIGN-SPEC §11.6 第二十一轮。
        .padding(.vertical, verticalPadding)
        .accessibilityElement(children: .contain)
    }

    private var verticalPadding: CGFloat {
        detail?.isEmpty == false
            ? SpeechRailDesignTokens.Spacing.md
            : SpeechRailDesignTokens.Spacing.sm
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
                // 稿的 `Status Pill` 标签是 `Caption / Medium`（脚本 652）。
                .font(SpeechRailDesignTokens.Typography.captionMedium)
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

/// 主按钮标签尾部的快捷键提示。
///
/// 2026-09-16 用户反馈（原话：「按钮与快捷键文案是否应该都在按钮上显示？」）：旧的
/// Figma `kbd` 键帽挂在按钮**左边**，自带填充与 1pt 描边、又不可点击，读起来像
/// 「按钮旁边还有一颗按钮」；而它离容器边 20pt，同心圆角推导到 0（离屏量到的是方角，
/// 见 `Corner.controlShape` 注释），与旁边的系统胶囊按钮并排更不像一个体系。
/// 快捷键只对**这一颗**按钮生效，就把它长在按钮标签上：沿用按钮自己的前景色降一档
/// 透明度，不另画底色与描边，形状问题随之消失。对辅助技术隐藏 —— 按钮自己的
/// `accessibilityLabel` 已经说明了这个快捷键。
public struct ButtonShortcutHint: View {
    public let label: String

    public init(_ label: String) {
        self.label = label
    }

    public var body: some View {
        Text(label)
            .font(SpeechRailDesignTokens.Typography.secondary)
            .opacity(SpeechRailDesignTokens.Button.shortcutOpacity)
            .lineLimit(1)
            .accessibilityHidden(true)
    }
}

/// SpeechRail 统一高品质按钮图标组件。
/// 封装了 SF Symbol 渲染模式 (.monochrome)、统一尺寸、光学字重与基线防漂移逻辑。
public struct SpeechRailButtonIcon: View {
    public let symbol: SpeechRailDesignTokens.Icon.Symbol
    public let size: CGFloat?
    public let weight: Font.Weight?

    public init(
        _ symbol: SpeechRailDesignTokens.Icon.Symbol,
        size: CGFloat? = nil,
        weight: Font.Weight? = nil
    ) {
        self.symbol = symbol
        self.size = size
        self.weight = weight
    }

    public var body: some View {
        Image(systemName: symbol.systemName)
            .font(.system(
                size: size ?? SpeechRailDesignTokens.Icon.buttonIconSize,
                weight: weight ?? .medium
            ))
            .symbolRenderingMode(.monochrome)
            .accessibilityHidden(true)
    }
}

/// 统一的按钮内容标签组件，标准化图标（可选前缀/后缀）与文字之间的间距 (Spacing.xs) 与快捷键提示对齐。
public struct SpeechRailButtonLabel: View {
    private let title: String
    private let icon: SpeechRailDesignTokens.Icon.Symbol?
    private let trailingIcon: SpeechRailDesignTokens.Icon.Symbol?
    private let shortcut: String?

    public init(
        _ title: String,
        icon: SpeechRailDesignTokens.Icon.Symbol? = nil,
        trailingIcon: SpeechRailDesignTokens.Icon.Symbol? = nil,
        shortcut: String? = nil
    ) {
        self.title = title
        self.icon = icon
        self.trailingIcon = trailingIcon
        self.shortcut = shortcut
    }

    public var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            if let icon {
                SpeechRailButtonIcon(icon)
            }
            Text(title)
            if let trailingIcon {
                SpeechRailButtonIcon(trailingIcon)
            }
            if let shortcut {
                ButtonShortcutHint(shortcut)
            }
        }
    }
}

/// SpeechRail 现代通用按钮：集成视觉变体、图标、文字与原生 macOS 26 交互反馈
public struct SpeechRailButton: View {
    private let title: String
    private let icon: SpeechRailDesignTokens.Icon.Symbol?
    private let trailingIcon: SpeechRailDesignTokens.Icon.Symbol?
    private let shortcut: String?
    private let level: SpeechRailButtonLevel
    private let isEnabled: Bool
    private let action: () -> Void

    public init(
        _ title: String,
        icon: SpeechRailDesignTokens.Icon.Symbol? = nil,
        trailingIcon: SpeechRailDesignTokens.Icon.Symbol? = nil,
        shortcut: String? = nil,
        level: SpeechRailButtonLevel = .secondary,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.trailingIcon = trailingIcon
        self.shortcut = shortcut
        self.level = level
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            SpeechRailButtonLabel(
                title,
                icon: icon,
                trailingIcon: trailingIcon,
                shortcut: shortcut
            )
        }
        .speechRailButton(level)
        .disabled(!isEnabled)
    }
}

/// 稿的行内动作图标按钮字形（`main.js:640` `iconButton(parent, name, 28)`）：
/// **28 × 28 框、圆角 7、无底色**，字形是 15pt 图标框里的 `text/secondary`。
/// 应用此前在四处各写一遍 `Typography.statusIcon`（17pt semibold）、播放钮还自造成
/// 琥珀实心圆；这一个视图让「播放 / 停止 / 导出 / 更多操作」共用同一档字号与墨色，
/// 量测依据见 `Icon.rowActionSize`（REDESIGN-SPEC §11.6 第四十四轮）。
public struct RowActionGlyph: View {
    public let symbol: SpeechRailDesignTokens.Icon.Symbol

    public init(_ symbol: SpeechRailDesignTokens.Icon.Symbol) {
        self.symbol = symbol
    }

    public var body: some View {
        SpeechRailButtonIcon(
            symbol,
            size: SpeechRailDesignTokens.Icon.rowActionSize,
            weight: .semibold
        )
        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
        .frame(
            width: SpeechRailDesignTokens.Control.iconButtonSize,
            height: SpeechRailDesignTokens.Control.iconButtonSize
        )
        .accessibilityHidden(true)
    }
}

/// 页面头部动作控件的标签：图标（可选文字）、统一的一档尺寸与墨色。
///
/// 头部动作**不用通用文字标签**：`title` 只有在动作本身有具体名字时才给
/// （「服务」「新建音色」），其余情况是纯图标 + 精确的无障碍标签
/// （REDESIGN-SPEC §6.2 / §11.6 第四十九轮）。
/// 动作控件的视觉变体层级
public enum PageActionVariant: Sendable {
    /// 默认次级动作（平时无底色，悬停呈现轻柔胶囊高亮，按下压暗）
    case standard
    /// 突出主动作（轻度强调色底，强调色文字与图标，悬停加深）
    case prominent
    /// 破坏性/危险动作（警示红文字，悬停浅红底）
    case destructive
}

/// 页面头部动作控件的标签：图标（可选文字）、统一的一档尺寸与墨色。
///
/// 头部动作**不用通用文字标签**：`title` 只有在动作本身有具体名字时才给
/// （「服务」「新建音色」），其余情况是纯图标 + 精确的无障碍标签
/// （REDESIGN-SPEC §6.2 / §11.6 第四十九轮）。
struct PageActionLabel: View {
    let title: String?
    let systemImage: String

    var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Toolbar.Action.labelSpacing) {
            Image(systemName: systemImage)
                .font(SpeechRailDesignTokens.Typography.toolbarActionIcon)
                .frame(
                    width: SpeechRailDesignTokens.Toolbar.Action.glyphFrame,
                    height: SpeechRailDesignTokens.Toolbar.Action.glyphFrame
                )
                .symbolRenderingMode(.monochrome)
                .accessibilityHidden(true)
            if let title {
                // 稿的菜单行标签是 `Callout`（12pt Regular）。
                Text(title)
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Toolbar.Action.horizontalPadding)
        .frame(
            minWidth: SpeechRailDesignTokens.Toolbar.Action.iconOnlyWidth,
            minHeight: SpeechRailDesignTokens.Toolbar.Action.controlHeight
        )
        .contentShape(SpeechRailDesignTokens.Corner.controlShape)
    }
}

/// 页面动作按钮的高质感 ButtonStyle：接管 macOS 原生悬停高亮胶囊、按压阻尼与焦点环
public struct PageActionButtonStyle: ButtonStyle {
    private let variant: PageActionVariant

    public init(variant: PageActionVariant = .standard) {
        self.variant = variant
    }

    public func makeBody(configuration: Configuration) -> some View {
        PageActionButtonBody(configuration: configuration, variant: variant)
    }
}

private struct PageActionButtonBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    let configuration: ButtonStyle.Configuration
    let variant: PageActionVariant

    var body: some View {
        configuration.label
            .foregroundStyle(foregroundColor)
            .background(backgroundShape)
            .speechRailFocusRing(isFocused)
            .contentShape(SpeechRailDesignTokens.Corner.controlShape)
            .opacity(isEnabled ? 1 : SpeechRailDesignTokens.Interaction.disabledOpacity)
            .onHover { hovering in
                isHovered = isEnabled && hovering
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

    private var foregroundColor: Color {
        if !isEnabled {
            return SpeechRailDesignTokens.Color.disabled
        }
        switch variant {
        case .standard:
            return SpeechRailDesignTokens.Color.ink
        case .prominent:
            return SpeechRailDesignTokens.Color.rail
        case .destructive:
            return SpeechRailDesignTokens.Color.critical
        }
    }

    @ViewBuilder
    private var backgroundShape: some View {
        let shape = SpeechRailDesignTokens.Corner.controlShape
        if configuration.isPressed {
            switch variant {
            case .standard:
                shape.fill(SpeechRailDesignTokens.Toolbar.Action.pressedFill)
            case .prominent:
                shape.fill(SpeechRailDesignTokens.Color.rail.opacity(0.24))
            case .destructive:
                shape.fill(SpeechRailDesignTokens.Color.critical.opacity(0.20))
            }
        } else if isHovered {
            switch variant {
            case .standard:
                shape.fill(SpeechRailDesignTokens.Toolbar.Action.hoverFill)
            case .prominent:
                shape.fill(SpeechRailDesignTokens.Color.rail.opacity(0.14))
            case .destructive:
                shape.fill(SpeechRailDesignTokens.Color.critical.opacity(0.12))
            }
        } else {
            switch variant {
            case .standard:
                Color.clear
            case .prominent:
                shape.fill(SpeechRailDesignTokens.Color.rail.opacity(0.08))
            case .destructive:
                Color.clear
            }
        }
    }
}

/// 页面头部的**低频动作集合**：一个触发器和它的菜单。
///
/// 只有真的存在两个以上低频动作、或者动作本身需要一组选项时才用它；
/// 一个动作就直接用 `PageActionButton`。破坏性与生命周期动作按 `Divider`
/// 分组，与读数据、复制、视图切换分开。
public struct PageActionsMenu<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private let title: String?
    private let systemImage: String
    private let helpText: String
    private let content: Content

    public init(
        title: String? = nil,
        icon: SpeechRailDesignTokens.Icon.Symbol = .more,
        helpText: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = icon.systemName
        self.helpText = helpText
        self.content = content()
    }

    public init(
        title: String? = nil,
        systemImage: String = "ellipsis",
        helpText: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.helpText = helpText
        self.content = content()
    }

    public var body: some View {
        Menu {
            content
        } label: {
            PageActionLabel(title: title, systemImage: systemImage)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .background {
                    if isHovered {
                        SpeechRailDesignTokens.Corner.controlShape
                            .fill(SpeechRailDesignTokens.Toolbar.Action.hoverFill)
                    }
                }
                .contentShape(SpeechRailDesignTokens.Corner.controlShape)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(title == nil ? .hidden : .automatic)
        .controlSize(.regular)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("page-actions")
        .help(helpText)
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(
            reduceMotion ? nil : SpeechRailDesignTokens.Motion.hoverFeedback,
            value: isHovered
        )
        .speechRailPointerCursor()
    }

    /// 无障碍标签必须说清「哪一页的哪个动作」：当前路由共用同一个槽位，
    /// 不能再让不同屏幕读出同一句泛称（§9）。没有具体标题时退到工具提示那句话，
    /// 而不是退回一个通用词。
    private var accessibilityLabel: String {
        title ?? helpText
    }
}

/// 页面头部或工作台卡片的**具体动作按钮**：带悬停微胶囊底色与触感反馈。
public struct PageActionButton: View {
    private let title: String?
    private let systemImage: String
    private let variant: PageActionVariant
    private let helpText: String
    private let isEnabled: Bool
    private let action: () -> Void

    public init(
        title: String? = nil,
        icon: SpeechRailDesignTokens.Icon.Symbol,
        variant: PageActionVariant = .standard,
        helpText: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = icon.systemName
        self.variant = variant
        self.helpText = helpText
        self.isEnabled = isEnabled
        self.action = action
    }

    public init(
        title: String? = nil,
        systemImage: String,
        variant: PageActionVariant = .standard,
        helpText: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.variant = variant
        self.helpText = helpText
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            PageActionLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(PageActionButtonStyle(variant: variant))
        .controlSize(.regular)
        .disabled(!isEnabled)
        .accessibilityLabel(title ?? helpText)
        .accessibilityIdentifier("page-action")
        .help(helpText)
        .speechRailPointerCursor()
    }
}

public struct StatusBanner: View {
    /// 稿里这是两种东西：`conclusion` 是「页面主对象」级的状态结论面板（服务状态页），
    /// `standard` 是行内反馈 / 空态（对应稿的 `Empty State` 组件口径）。两者的底色、
    /// 图标大小与标题档位都不同，所以在这里显式分开，而不是靠调用点自己拼
    /// （REDESIGN-SPEC §7.5 / §11.6 第十八轮）。
    public enum Kind: Sendable {
        case standard
        case conclusion
    }

    public let kind: Kind
    public let tone: StatusTone
    public let title: String
    public let message: String
    public let actionTitle: String?
    public let action: (() -> Void)?
    public let actionDisabled: Bool

    public init(
        kind: Kind = .standard,
        tone: StatusTone,
        title: String,
        message: String,
        actionTitle: String? = nil,
        actionDisabled: Bool = false,
        action: (() -> Void)? = nil
    ) {
        self.kind = kind
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
        .padding(padding)
        .speechRailContainerSurface(backgroundFill)
        .overlay {
            // 稿的 `conclusion` 带 1pt 状态色描边（状态层级才描边，REDESIGN-SPEC §5.2）。
            if kind == .conclusion {
                SpeechRailDesignTokens.Corner.containerShape
                    .stroke(tone.color, lineWidth: SpeechRailDesignTokens.Stroke.strong)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var padding: CGFloat {
        switch kind {
        case .conclusion: SpeechRailDesignTokens.Layout.cardInset
        case .standard: SpeechRailDesignTokens.Spacing.md
        }
    }

    private var backgroundFill: Color {
        switch kind {
        case .conclusion:
            tone.color.opacity(SpeechRailDesignTokens.Surface.statusTintOpacity)
        case .standard:
            SpeechRailDesignTokens.Color.recessedField
        }
    }

    private var titleFont: Font {
        switch kind {
        case .conclusion: SpeechRailDesignTokens.Typography.display
        case .standard: SpeechRailDesignTokens.Typography.statusTitle
        }
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
            .font(
                kind == .conclusion
                    ? .system(size: SpeechRailDesignTokens.Control.statusBannerIconSize, weight: .semibold)
                    : SpeechRailDesignTokens.Typography.statusIcon
            )
            .foregroundStyle(tone.color)
            .accessibilityHidden(true)
    }

    private var bannerCopy: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Text(title)
                .font(titleFont)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(message)
                // 稿的结论副行与空态正文都是 `Callout`（12pt）。
                .font(SpeechRailDesignTokens.Typography.callout)
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

/// 语义化轻量通知栏（NoticeBar）：规范化工作台/表单内部的轻量提示、预检警告与待确认提醒
public struct NoticeBar: View {
    public enum Tone: Sendable {
        case info
        case warning
        case critical
        case success
        case neutral
    }

    private let tone: Tone
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(
        tone: Tone = .info,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.tone = tone
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.sm) {
            toneIcon
                .font(.system(size: SpeechRailDesignTokens.Notice.iconSize, weight: .semibold))
                .foregroundStyle(toneColor)
                .accessibilityHidden(true)

            Text(message)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderless)
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(toneColor)
                    .speechRailPointerCursor()
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Notice.paddingHorizontal)
        .padding(.vertical, SpeechRailDesignTokens.Notice.paddingVertical)
        .background(toneFill, in: SpeechRailDesignTokens.Corner.controlShape)
        .overlay {
            SpeechRailDesignTokens.Corner.controlShape
                .strokeBorder(toneStroke, lineWidth: SpeechRailDesignTokens.Notice.borderWidth)
        }
    }

    private var toneColor: Color {
        switch tone {
        case .info: SpeechRailDesignTokens.Color.info
        case .warning: SpeechRailDesignTokens.Color.attention
        case .critical: SpeechRailDesignTokens.Color.critical
        case .success: SpeechRailDesignTokens.Color.ready
        case .neutral: SpeechRailDesignTokens.Color.inkSecondary
        }
    }

    private var toneFill: Color {
        switch tone {
        case .info: SpeechRailDesignTokens.Color.info.opacity(SpeechRailDesignTokens.Surface.statusTintOpacity)
        case .warning: SpeechRailDesignTokens.Surface.attentionTint
        case .critical: SpeechRailDesignTokens.Color.critical.opacity(SpeechRailDesignTokens.Surface.statusTintOpacity)
        case .success: SpeechRailDesignTokens.Color.ready.opacity(SpeechRailDesignTokens.Surface.statusTintOpacity)
        case .neutral: SpeechRailDesignTokens.Color.recessedField
        }
    }

    private var toneStroke: Color {
        switch tone {
        case .info: SpeechRailDesignTokens.Color.info.opacity(0.3)
        case .warning: SpeechRailDesignTokens.Color.attention.opacity(0.35)
        case .critical: SpeechRailDesignTokens.Color.critical.opacity(0.3)
        case .success: SpeechRailDesignTokens.Color.ready.opacity(0.3)
        case .neutral: SpeechRailDesignTokens.Color.separator
        }
    }

    private var toneIcon: Image {
        switch tone {
        case .info: Image(systemName: SpeechRailDesignTokens.Icon.Symbol.infoCircleFill.systemName)
        case .warning: Image(systemName: SpeechRailDesignTokens.Icon.Symbol.warningFill.systemName)
        case .critical: Image(systemName: SpeechRailDesignTokens.Icon.Symbol.errorCircleFill.systemName)
        case .success: Image(systemName: SpeechRailDesignTokens.Icon.Symbol.successCircleFill.systemName)
        case .neutral: Image(systemName: SpeechRailDesignTokens.Icon.Symbol.infoCircle.systemName)
        }
    }
}

public extension View {
    func speechRailNoticeBar(
        tone: NoticeBar.Tone = .info,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        NoticeBar(tone: tone, message: message, actionTitle: actionTitle, action: action)
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
                    Text("正在处理：\(artifactKey)")
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

/// 详情列（inspector）的**唯一列宽声明点**。
///
/// 2026-09-16 用户复核：「两个侧边栏应该保持宽度一致，另外音色库侧边栏的试听文案下方
/// 应该留出间距」。宽度这一半的根因不是某一块面板，而是**声明方式**：此前这一列只声明
/// 了一个区间（min 300 / ideal 360 / max 440），列宽于是是「窗口余量 + 内容最小宽 +
/// 用户拖动」的函数，而不是 token 的函数。离屏实测（`--render --center --route <route>`
/// `--window`，1440 × 900，同一扇窗口）：
///
/// | 路由 | 走 inspector 声明时的列宽 | 空态（无声明）时的列宽 |
/// |---|---|---|
/// | 音色库（有选中音色） | 360.0 | 270.0 |
/// | 我的作品（永远有 `selectedWork ?? first`） | 360.0 | — |
///
/// 用户装机件（窗口 1443 × 973）里音色库那一列落在 **300**：截图的预览面板外框
/// 2x 实测 x 32–571px = 269.5pt，加两侧 `contentPadding`(16) = 301.5pt，正好是区间的
/// 下限——区间在真实窗口里就是会被内容与余量推到两端，两块侧边栏也就各是各的宽度。
///
/// 因此列宽改为**定宽 token**（`Layout.inspectorColumnWidth` = 360，与稿的 Inspector
/// 同口径），并且由这一处声明：两块目录页（含它们的空态）与其余页面的
/// `DeveloperInspector` 共用它。**有意的代价**：分割线不再可拖（稿上的 Inspector 本来
/// 就是一条定宽列，300–440 的区间是应用自造，且它正是宽度不一致的来源）。
public struct SpeechRailInspectorColumnModifier: ViewModifier {
    private let alignment: Alignment

    public init(alignment: Alignment = .top) {
        self.alignment = alignment
    }

    public func body(content: Content) -> some View {
        content
            .frame(
                width: SpeechRailDesignTokens.Layout.inspectorColumnWidth,
                alignment: alignment
            )
            .frame(maxHeight: .infinity, alignment: alignment)
            // 宽度已经是定值，兜一层裁剪：内容若仍比列宽（例如一个按内容自测宽的
            // 输入槽）也不会画到列外去。
            .clipped()
            .inspectorColumnWidth(SpeechRailDesignTokens.Layout.inspectorColumnWidth)
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
        .speechRailInspectorColumn(alignment: .topLeading)
        .background(SpeechRailDesignTokens.Color.field)
    }
}

/// 目录页（音色库 / 我的作品）右侧详情面板的**唯一结构声明点**。
///
/// 稿 `main.js` 1584–1631 的 `inspector` 是一条竖列、段间**整宽** 1pt hairline：
/// 身份带（`sideHead`：`Title / Page` + `Caption`/`text/tertiary` 徽标）→ hairline →
/// 试听段（`previewWrap`，`padY 14`）→ hairline → 取值段（`sideBody`）→ hairline →
/// 动作区（`actions`，`padY 14`，**压在最底部、不随内容滚动**）。
/// 4x 帧 `▸ 音色库.png` 实测三条 hairline 在 y 260.0–261.0 / 341.0–342.0 / 820.0–821.0，
/// 都从卡片左沿通到右沿。
///
/// 应用此前只有音色库按这条落地（§11.6 第四十五轮），我的作品是另一套结构
/// （`SectionHeading` + 跟着内容滚的内缩 `Divider` + 动作散在正文里），于是同一个窗口里
/// 两块「侧边栏」读起来像两个体系。这里把四段收敛成一处声明：段落顺序、内边距与身份带
/// 的字号档只在这里出现，两个页面不可能再各自漂移。
public struct SpeechRailInspectorPanel<Preview: View, Body: View, Actions: View>: View {
    private let title: String
    private let badge: String
    private let preview: Preview
    private let bodyContent: Body
    private let actions: Actions

    public init(
        title: String,
        badge: String,
        @ViewBuilder preview: () -> Preview,
        @ViewBuilder body: () -> Body,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.badge = badge
        self.preview = preview()
        self.bodyContent = body()
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    identityBand

                    Divider()

                    preview
                        .padding(.horizontal, SpeechRailDesignTokens.Inspector.contentPadding)

                    Divider()

                    bodyContent
                        .padding(.horizontal, SpeechRailDesignTokens.Inspector.contentPadding)
                        .padding(.vertical, SpeechRailDesignTokens.Inspector.contentPadding)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)

            Divider()

            actions
                .padding(.horizontal, SpeechRailDesignTokens.Inspector.contentPadding)
                .padding(.vertical, SpeechRailDesignTokens.Inspector.actionPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 列宽由 token 决定，**不由内容决定**：`speechRailInspectorColumn()` 是这一列
        // 唯一的宽度声明（定宽 `Layout.inspectorColumnWidth`）。此前它是一个区间
        // （300–440，ideal 360），列宽因此是内容的函数——试听文案这类「上限 4096 字的
        // 输入槽」会把它撑宽，而窗口余量不足时又会被压到下限，同一扇窗口里两块目录页
        // 因此可能各是一个宽度（§11.6 第五十七、六十一轮）。
        .speechRailInspectorColumn()
        .background(SpeechRailDesignTokens.Color.field)
    }

    /// 身份带：稿 `sideHead` 是 `Title / Page` 标题 + `Caption`/`text/tertiary` 徽标，
    /// `gap 4 / padX 16 / padY 16`。4x 帧实测标题墨迹 79.25 × 19.0（20pt）、
    /// 徽标墨迹 87.75 × 9.5（10pt）。标题走 `Typography.display`
    /// （系统文本样式里没有 20，取最近的 `.title` 22，+2pt 残差，§5.5），
    /// 徽标取 `tertiaryLabelColor`（稿那个灰是硬编码值，按 §5.4 的系统语义色映射表走）。
    private var identityBand: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Text(title)
                .font(SpeechRailDesignTokens.Typography.display)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineLimit(SpeechRailDesignTokens.Inspector.titleMaximumLines)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(badge)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, SpeechRailDesignTokens.Inspector.contentPadding)
        .padding(.vertical, SpeechRailDesignTokens.Inspector.contentPadding)
    }
}

/// 详情面板里的**试听面板**：稿 `preview` 是 `surface/panel` + 1pt `border/separator`
/// + `radius 10` 的嵌套面板（`padX 12 / padY 10`）。4x 帧实测填充带 50.0（波形 30 +
/// 上下各 10）、描边 1pt 画在填充**外**（外框 52.0）。
///
/// 底色取 `Color.recessedField`（= 稿 `surface/panel`，token 注释里就写着这一格的用途）。
/// 应用此前用的是 `Color.field`，而 Inspector 这一列自己的底色也是 `Color.field`
/// （`Surface.inspectorFill`），于是面板与栏目**同色**、只剩一圈 1pt 描边，「比所在卡片
/// 低一级」的嵌套关系没有画出来。离屏实测（`--inspector`，360 × 900）：改前浅色填充带
/// `#FFFFFF`、深色 `#2B292C`，与栏目底逐位相同；改后是 `#F5F5F7` / `#232124`。
public struct SpeechRailInspectorPreviewPanelModifier: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .padding(.horizontal, SpeechRailDesignTokens.Inspector.previewInsetX)
            .padding(.vertical, SpeechRailDesignTokens.Inspector.previewInsetY)
            .background(
                SpeechRailDesignTokens.Color.recessedField,
                in: RoundedRectangle(
                    cornerRadius: SpeechRailDesignTokens.Inspector.previewRadius,
                    style: .continuous
                )
            )
            // 稿的描边画在填充**外**（帧：填充带 276.0–326.0、描边 275.0–276.0 /
            // 326.0–327.0）。`padding(-1)` 让形状向四周外扩 1pt，`strokeBorder`
            // 再向内画 1pt，这条环就正好落在填充边界之外；外圈半径随之同心 +1。
            .overlay {
                RoundedRectangle(
                    cornerRadius: SpeechRailDesignTokens.Inspector.previewRadius + 1,
                    style: .continuous
                )
                .strokeBorder(SpeechRailDesignTokens.Color.separator, lineWidth: 1)
                .padding(-1)
            }
            // 稿 `previewWrap` 的上下留白（`padY 14`）属于**面板**，不属于整段：
            // 音色库那一段在面板之后还有一块应用自有的「试听文案」输入区
            // （稿上没有入口，§11.6 第四十五轮 ⑤），把那 14pt 套在整段上会把输入区
            // 与面板之间的间距从 26pt 压到 12pt、又在段尾多出 14pt 空白。
            .padding(.vertical, SpeechRailDesignTokens.Inspector.previewWrapInsetY)
    }
}

extension View {
    /// 详情面板的试听段容器（稿的 `previewWrap`）：面板自带 `padY 14` 的上下留白，
    /// 左右由 `SpeechRailInspectorPanel` 的段内边距给（稿 `padX 16` = `contentPadding`）。
    func speechRailInspectorPreviewPanel() -> some View {
        modifier(SpeechRailInspectorPreviewPanelModifier())
    }

    /// 详情列的列宽声明（见 `SpeechRailInspectorColumnModifier`）。整列一处，两块目录页
    /// 与它们的空态、以及其余页面的 `DeveloperInspector` 都走它，宽度因此不可能漂移。
    func speechRailInspectorColumn(alignment: Alignment = .top) -> some View {
        modifier(SpeechRailInspectorColumnModifier(alignment: alignment))
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
                // 稿的取值行两侧都是 `Callout`(12)：4x 帧实测标签列 CJK 字宽 ≈ 10.5pt、
                // 步进 11.75pt，即 12pt；应用此前用 `caption`（10）小一档
                // （REDESIGN-SPEC §11.6 第二十轮）。
                .font(SpeechRailDesignTokens.Typography.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .lineLimit(SpeechRailDesignTokens.Inspector.titleMaximumLines)
                .frame(
                    width: SpeechRailDesignTokens.Inspector.labelColumnWidth,
                    alignment: .leading
                )
            configuration.content
                .font(SpeechRailDesignTokens.Typography.technicalValue)
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

/// 文稿 / 描述用的原生 `TextEditor` 外壳（REDESIGN-SPEC §7.1 / §7.2）。
///
/// 它只做三件事：给编辑器一个**有上界的舒服高度**、把计数等元信息收进同一张
/// 卡的分隔线之内、画出系统焦点环。滚动完全交给原生 `TextEditor`：内容超出
/// 高度时出现系统滚动条，这符合 macOS 预期。
///
/// 高度区间而不是「占满剩余高度」：1440 × 900 下占满会把三行文稿拉成约 640pt
/// 的白板。下限让窄窗口还能压缩，上限避免一屏空白。
///
/// 页脚（字数、清空、保存门禁）不是「一行带上下内边距」，而是稿上量到的一条
/// **固定高度带**：配音台帧里分隔线 660.5pt → 卡底 703.75pt，即 42.5pt，内容在带内
/// 竖直居中。带高由 `metaRowHeight` 给值，两个调用点按各自的稿取值（配音台 42、
/// 音色创作 28）。带高是**下限**，字号放大时行仍然能长高。
///
/// 2026-09-15 用户二次复核：第一版按正文长度自量高、并在装得下时隐藏滚动条，
/// 属于自造机制；当时回到原生滚动 + 固定高度区间。
///
/// 2026-09-16 用户三度校准（「滚动条可接受，优先原生组件，但大小高度需要优化」）
/// 后分成两种策略（见 `HeightPolicy`）。固定区间（`.band`）的**区间套在整张卡上**，
/// 不再只套在 `TextEditor` 上：稿（Figma `editor` 420 / `promptField` 130）量的是
/// 「正文 + 元信息行」的整张卡，只有把区间放在卡上，`creatorVoiceInstructionMaximumHeight`
/// 之类的 token 才等于稿上的那个数；放在编辑器上会让卡比 token 高出页脚那一行
/// （约 35pt）。区间内编辑器的份量由原生布局分配：`.frame(maxHeight: .infinity)`
/// 让它吃掉页脚之外的全部高度。
///
/// `.band` 的高度用原生 `frame(minHeight:idealHeight:maxHeight:)` 给值：容器给出
/// 确定高度时按剩余空间在区间内取值；容器是无界提案时（音色创作在 `ScrollView`
/// 里）取 `idealHeight`，不依赖原生编辑器内部报告的理想高度。
///
/// `.contentDriven` 是配音台文稿（§7.1）的策略：离屏实测 1440 × 900、默认一行
/// 文稿（53 字）时，固定区间会把编辑框拉到 277pt 高、里面只放 16pt 的文字——
/// 这正是用户说的「太高、太大」。跟随内容后，编辑框高度由**正文自身高度**决定，
/// 短文稿就小、长文稿长到上限、超出上限仍由原生滚动条承担（不再隐藏滚动条）。
/// 下限只负责「静止状态看得见 3 行写作区」（`creatorComposerMinimumHeight`；滚动条
/// 已按用户第六度校准被接受，下限因此不必再为「拖后出现滚动条」留更多行）。
/// 量测用同一字体、同行距、同宽度的隐藏 `Text` 副本，只取一个高度值，不改变
/// 原生编辑器的任何行为（不是自造控件、不接管滚动、不做自绘）。
///
/// `chrome` 区分两种归属。配音台的输入区**自己就是一张卡**（稿里正文上方没有
/// 别的容器），用 `.card`：自带 `Layout.cardInset` 内边距，页脚上方有分隔线。
/// 音色创作的描述框**嵌在 `promptCard` 这张面板里**（稿里正文、计数行、声学特征
/// 芯片、生成按钮同属一张卡），用 `.embedded`：内边距由面板给，正文与页脚之间
/// 不加分隔线——4x 帧实测该卡在正文与计数行之间没有任何分隔线（`▸ 音色创作.png`
/// y=270–320 全为纯白），而 `▸ 配音台.png` 在 y=661 有一条 220,220,224 的分隔线。
/// 此前两种场景共用 `.card`，音色创作的正文因此被面板与输入区各内缩一次（距卡沿
/// 40pt，稿实测 21pt），整卡还多出一条稿上没有的分隔线。
public struct SpeechRailComposerTextEditor<Footer: View>: View {
    /// 输入区的归属：独立卡片，还是嵌在一张已有卡片里（见类型注释）。
    public enum Chrome: Sendable {
        case card
        case embedded
    }

    /// 输入区的高度策略（§7.1 配音台文稿 / §7.2 音色创作描述框）。
    public enum HeightPolicy: Sendable {
        /// 固定区间：容器给多少就取多少，受 `minimum…maximum` 约束；容器是无界
        /// 提案时取 `ideal`。区间套在**整张卡**上（正文 + 页脚元信息行）。
        case band(minimum: CGFloat, ideal: CGFloat, maximum: CGFloat)
        /// 跟随内容：正文多高就给多高（另留一行可写余量），并落在
        /// `minimum…maximum` 之间。下限保证短文稿也有整块写作区，上限之外由
        /// 原生 `TextEditor` 的滚动条承担。
        case contentDriven(minimum: CGFloat, maximum: CGFloat)
    }

    /// 跟随内容时额外留出的一行余量。隐藏 `Text` 的行距比 `TextEditor` 自己的
    /// 排版每行少报约 0.5pt（离屏实测：8 行 152 vs 156、16 行 306 vs 316），
    /// 留满一行既吸收这点误差，也让「刚好写完一行」时不会立刻冒出滚动条。
    private static var growthCushion: CGFloat { 20 }

    @Binding private var text: String
    private let label: String
    private let heightPolicy: HeightPolicy
    private let metaRowHeight: CGFloat
    private let lineSpacing: CGFloat
    private let hint: String?
    private let chrome: Chrome
    private let isFocused: FocusState<Bool>.Binding
    private let footer: Footer
    /// 隐藏镜像量到的正文高度（仅 `.contentDriven` 使用）。
    @State private var measuredTextHeight: CGFloat = 0

    public init(
        text: Binding<String>,
        label: String,
        isFocused: FocusState<Bool>.Binding,
        heightPolicy: HeightPolicy,
        metaRowHeight: CGFloat = SpeechRailDesignTokens.Layout.composerMetaRowHeight,
        lineSpacing: CGFloat = 0,
        hint: String? = nil,
        chrome: Chrome = .card,
        @ViewBuilder footer: () -> Footer
    ) {
        self._text = text
        self.label = label
        self.isFocused = isFocused
        self.heightPolicy = heightPolicy
        self.metaRowHeight = metaRowHeight
        self.lineSpacing = lineSpacing
        self.hint = hint
        self.chrome = chrome
        self.footer = footer()
    }

    /// 正文与页脚的内边距：独立卡片自带 `cardInset`，嵌卡形态由外层卡片提供。
    private var textInset: CGFloat {
        chrome == .card ? SpeechRailDesignTokens.Layout.cardInset : 0
    }

    /// 编辑器本体。字体、行距、焦点与无障碍标签两处共用，只有高度给法不同。
    private var textEditor: some View {
        TextEditor(text: $text)
            .font(SpeechRailDesignTokens.Typography.body)
            .lineSpacing(lineSpacing)
            .scrollContentBackground(.hidden)
            .focused(isFocused)
            .accessibilityLabel(label)
    }

    /// 跟随内容时编辑框的目标高度：正文高度 + 上下内边距 + 一行余量，落在
    /// `minimum…maximum`（这两个值与 `.band` 同口径，即**整张卡**的高度）。
    /// `.contentDriven` 目前只用于独立卡片（配音台文稿）；带引导行的嵌卡形态
    /// 请继续用 `.band`。
    private func contentDrivenEditorHeight(minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        // `.band` 的 token 是整卡高度。这一层 frame 套在**已加内边距**的编辑区上，
        // 所以只要减掉卡内其余固定开销（分隔线与页脚带），内边距已经算在下面
        // 的 `wanted` 里。
        let chromeHeight = (chrome == .card ? 1 : 0) + metaRowHeight
        let floorHeight = max(minimum - chromeHeight, 0)
        let ceilingHeight = max(maximum - chromeHeight, floorHeight)
        let wanted = measuredTextHeight + textInset * 2 + Self.growthCushion
        return min(max(wanted, floorHeight), ceilingHeight)
    }

    /// 与正文同字体、同行距、同宽度的隐藏副本，只用来量正文高度。
    /// `fixedSize(vertical:)` 让它忽略高度提案、始终按内容换行，测量因此不会
    /// 与它决定的高度互相牵动。
    private var textMirror: some View {
        Text(text.isEmpty ? " " : text)
            .font(SpeechRailDesignTokens.Typography.body)
            .lineSpacing(lineSpacing)
            .padding(.horizontal, textInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .accessibilityHidden(true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                measuredTextHeight = height
            }
    }

    /// 编辑器：`.band` 吃满页脚之外的剩余高度，`.contentDriven` 按内容取确定高度。
    @ViewBuilder
    private var editor: some View {
        switch heightPolicy {
        case .band:
            textEditor
                .padding(textInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case let .contentDriven(minimum, maximum):
            let target = contentDrivenEditorHeight(minimum: minimum, maximum: maximum)
            textEditor
                .padding(textInset)
                .frame(
                    maxWidth: .infinity,
                    minHeight: target,
                    idealHeight: target,
                    maxHeight: target,
                    alignment: .topLeading
                )
                .background(alignment: .topLeading) { textMirror }
        }
    }

    /// 卡片级的高度约束：`.band` 把区间套在整张卡上；`.contentDriven` 的高度已由
    /// 编辑器决定，卡只跟着内容收放。
    private var cardHeightRange: (minimum: CGFloat?, ideal: CGFloat?, maximum: CGFloat?) {
        switch heightPolicy {
        case let .band(minimum, ideal, maximum): (minimum, ideal, maximum)
        case .contentDriven: (nil, nil, nil)
        }
    }

    public var body: some View {
        Group {
            if chrome == .card {
                cardBody
                    // 边界与底色属于**整张编辑卡**，不属可写区那一块：
                    // 稿的 `editor` 卡把正文、分隔线、字数页脚画在同一个形状里
                    // （`figma-kit/main.js:1288-1322` 的注释、§7.1 第 2 条、
                    // `▸ 配音台.png` 整卡描边实测），页脚飘在卡外的页面地板上是错的。
                    .speechRailEditorCard()
                    .speechRailFocusRing(isFocused.wrappedValue)
            } else {
                cardBody
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: cardHeightRange.minimum,
            idealHeight: cardHeightRange.ideal,
            maxHeight: cardHeightRange.maximum,
            alignment: .top
        )
    }

    /// 卡的内容：可写区 + （独立卡片才有的）分隔线 + 页脚带。表面由 `body` 决定。
    private var cardBody: some View {
        VStack(spacing: 0) {
            // 可写区 = 正文（+ 引导行）。这里**不再自己圈一圈边界**：`chrome == .card`
            // 时边界属于整张卡（见 `body`），`chrome == .embedded` 时它属于外层那张
            // 面板——`figma-kit/main.js:1448-1452` 明确写过「描述框**就是**那个字段，
            // 在白卡里再套一个白输入框只会给同一句话画两圈边」，暗色帧也证实
            // 描述区与卡面是同一级表面（同值 `#2B292C`，卡内没有第二圈描边）。
            VStack(spacing: 0) {
                // 稿的写作区是 `padX 18 / padY 16`，帧实测正文左沿距卡沿 20pt（含字形
                // 左侧留白），应用原先 12pt 显得贴边。取 `Layout.cardInset`（残差 2pt，
                // REDESIGN-SPEC §11.6 第十七轮）。
                editor

                // 稿在描述框正文下方留了一行 tertiary 引导（Figma `promptField/hint`）。
                // 原生 `TextEditor` 没有 placeholder 概念，所以它是一个固定提示行，
                // 不随输入消失、也不盖在文本上。
                if let hint {
                    Text(hint)
                        // 稿的 `promptField/hint` 是 `Callout`(12) + `text/tertiary`：4x 帧上
                        // 这一行 ink 11.0pt（= 0.92 × 12），应用此前用 `caption`（10）
                        // （REDESIGN-SPEC §11.6 第二十轮）。
                        .font(SpeechRailDesignTokens.Typography.callout)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, textInset)
                        // 嵌卡形态没有编辑器的下内边距，靠自己留出稿上正文与引导之间的
                        // 那道间距（4x 帧：正文行盒底 171.5 → 引导行盒顶 178.5，约 7pt，
                        // 取 4pt 节奏里最近的 `xs`）。
                        .padding(.top, chrome == .embedded ? SpeechRailDesignTokens.Spacing.xs : 0)
                        .padding(.bottom, SpeechRailDesignTokens.Spacing.xs)
                }
            }

            if chrome == .card {
                Divider()
            }

            footer
                // 稿把页脚画成一条固定高度的带（配音台帧实测 42.5pt），字数与「清空」
                // 都在这条带里竖直居中；只给上下内边距会让页脚贴着分隔线。
                .frame(
                    maxWidth: .infinity,
                    minHeight: metaRowHeight,
                    alignment: .center
                )
                .padding(.horizontal, textInset)
        }
    }
}

/// A per-window action the focused page publishes, so menu commands can act on
/// "the selected work" without the App layer reaching into page state
/// (REDESIGN-SPEC §6.3).
// MARK: - Focused scene commands

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

/// 「重新读取当前页」（⌘R）：每个页面声明自己该怎么重新读取，视图菜单只负责
/// 暴露快捷键。这样「刷新」不必再在十四个页面各写一条含义不同的菜单项
/// （REDESIGN-SPEC §6.2 / §6.3）。
///
/// 页面没有可重新读取的东西时不要挂这个值，菜单项会自然禁用。
public struct ReloadPageCommand {
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

extension ReloadPageCommand: Equatable {
    public static func == (lhs: ReloadPageCommand, rhs: ReloadPageCommand) -> Bool {
        lhs.title == rhs.title
    }
}

private struct ReloadPageCommandKey: FocusedValueKey {
    typealias Value = ReloadPageCommand
}

public extension FocusedValues {
    var reloadPageCommand: ReloadPageCommand? {
        get { self[ReloadPageCommandKey.self] }
        set { self[ReloadPageCommandKey.self] = newValue }
    }
}
