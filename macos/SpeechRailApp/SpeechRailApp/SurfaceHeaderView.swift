import SwiftUI
import SpeechRailControlKit

public struct WorkspaceTitleLockup: View {
    public let route: AppRoute

    /// REDESIGN-SPEC §6.2：工具栏身份槽只有「这是哪一页」这一个信息，
    /// 单行、固定槽位、尾截断。所以页面名在**全应用只出现一次**：正文不再重复
    /// 标题（`PageScaffold` 只留一句话说明）；服务是否就绪由侧边栏底部状态区
    /// 独家承担（§6.4 / D9），标题不再重复一遍状态。
    public init(route: AppRoute) {
        self.route = route
    }

    public var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            RouteIconView(
                route: route,
                selected: false,
                presentation: .toolbar
            )
            Text(route.title)
                .font(SpeechRailDesignTokens.Typography.toolbarTitle)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(
                    SpeechRailDesignTokens.Toolbar.Identity.titleMinimumScaleFactor
                )
                .allowsTightening(true)
        }
        .frame(
            width: SpeechRailDesignTokens.Toolbar.Identity.maximumWidth,
            height: SpeechRailDesignTokens.Toolbar.Identity.height,
            // 槽位内**左对齐**（第五十五轮）：槽宽固定 280 是为了让项自己
            // 不随时长抖动，但内容居中会让短标题（八个页面名都不超过 4 个字、
            // 整组约 62–80pt）在 280pt 里浮到中间，读起来像一块没有归属的
            // 文字。左对齐后图标固定落在详情列的左沿，与帧「标题贴窗口左沿」
            // 的意图一致（REDESIGN-SPEC §6.2 / §11.6 第五十五轮）。
            alignment: .leading
        )
        // Keep unusually long localized titles inside the fixed toolbar slot;
        // the text already uses a single line and tail truncation above.
        .clipped()
        .id(route.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(route.title)
        .accessibilityIdentifier("workspace-title")
        .accessibilityValue(route.contextTitle)
    }
}

/// 工具栏的页面身份项：**全应用声明一次**，位置在窗口组合根
/// （`ControlCenterView` 的 detail 工具栏）。
///
/// 页面身份是当前路由的纯函数，页面自己没有要额外携带的标题状态，所以在组合根声明
/// 一次最省也最不容易漂移——八个屏幕共用同一个槽位、同一套几何（`Toolbar.Identity`）
/// 与同一个无障碍标识（REDESIGN-SPEC §6.2 / §11.6 第四十九轮）。页面只声明自己的动作。
public struct PageIdentityToolbarItem: ToolbarContent {
    public let route: AppRoute

    public init(_ route: AppRoute) {
        self.route = route
    }

    public var body: some ToolbarContent {
        // 位置从 `.principal` 改成 `.navigation`（第五十五轮，2026-09-16 离屏实测）：
        // `.principal` 的落点是「左侧组与右侧动作之间剩余空间的中点」，因此**只要有
        // 工具栏搜索框，标题就整体左移**——音色库 / 我的作品（两页都有
        // `.searchable(placement: .toolbar)`）实测 x=565.5，其余六页 x=700.5，
        // 切页时页面身份横跳 135pt；窗口收到最小宽 1120pt 时同样跳 135pt
        // （405.5 / 540.5）。身份槽是全应用唯一一处「我在哪一页」的锚点，
        // 它自己动起来就失去了意义。`.navigation` 是 NavigationSplitView
        // 页面标题的原生槽位，实测八页恒定在 x=252（w=288，详情列左沿 248 + 系统
        // 内缩 4），收侧栏时随之移到 x=148，与系统自己的侧栏按钮同步。
        // 帧的标题在窗口左沿 x=78（红绿灯 + 12pt），那一格被系统侧栏切换按钮
        // 占用且不可移除（同轮实测 `.toolbar(removing: .sidebarToggle)` 不生效），
        // 故取系统能给到的最左位置。
        ToolbarItem(placement: .navigation) {
            WorkspaceTitleLockup(route: route)
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

public enum RouteIconPresentation: Sendable {
    case navigation
    case toolbar
}

public struct RouteIconView: View {
    public let route: AppRoute
    public let selected: Bool
    public let presentation: RouteIconPresentation

    public init(
        route: AppRoute,
        selected: Bool,
        presentation: RouteIconPresentation = .navigation
    ) {
        self.route = route
        self.selected = selected
        self.presentation = presentation
    }

    public var body: some View {
        Image(systemName: route.systemImage)
            .font(.system(size: iconSize, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(selected ? SpeechRailDesignTokens.Navigation.selectedForeground : foregroundColor)
            .frame(
                width: iconFrame,
                height: iconFrame
            )
            .accessibilityHidden(true)
    }

    private var iconSize: CGFloat {
        switch presentation {
        case .navigation:
            SpeechRailDesignTokens.Icon.navigationSize
        case .toolbar:
            SpeechRailDesignTokens.Icon.toolbarSize
        }
    }

    private var iconFrame: CGFloat {
        switch presentation {
        case .navigation:
            SpeechRailDesignTokens.Icon.navigationFrame
        case .toolbar:
            SpeechRailDesignTokens.Icon.toolbarFrame
        }
    }

    private var foregroundColor: Color {
        switch presentation {
        case .navigation:
            SpeechRailDesignTokens.Navigation.secondaryForeground
        case .toolbar:
            SpeechRailDesignTokens.Color.inkSecondary
        }
    }
}
