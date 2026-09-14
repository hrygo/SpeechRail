import AppKit
import SwiftUI
import SpeechRailControlKit

public struct ControlCenterView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @State private var selection: AppRoute? = .overview
    @State private var searchText = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    public init() {}

    public var body: some View {
        if isUITestWithoutControlCenter {
            Color.clear
                .frame(width: 0, height: 0)
                .onAppear {
                    dismiss()
                }
        } else {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        if !visibleCreatorRoutes.isEmpty {
                            sidebarSection(title: AppRouteGroup.creator.title, routes: visibleCreatorRoutes)
                        }
                        if !visibleServiceRoutes.isEmpty {
                            sidebarSection(title: AppRouteGroup.service.title, routes: visibleServiceRoutes)
                        }
                        if visibleCreatorRoutes.isEmpty && visibleServiceRoutes.isEmpty {
                            ContentUnavailableView.search(text: searchText)
                                .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .background(SpeechRailDesignTokens.Chassis.obsidian)
                    .tint(SpeechRailDesignTokens.SteelRail.railheadGleam)
                    .searchable(text: $searchText, placement: .sidebar, prompt: "搜索创作和服务")

                    Divider()
                        .overlay(SpeechRailDesignTokens.Chassis.milledBevel)
                    sidebarServiceStatus
                }
                .navigationSplitViewColumnWidth(
                    min: SpeechRailDesignTokens.Layout.sidebarMinimumWidth,
                    ideal: SpeechRailDesignTokens.Layout.sidebarIdealWidth,
                    max: SpeechRailDesignTokens.Layout.sidebarMaximumWidth
                )
                .background(SpeechRailDesignTokens.Chassis.obsidian)
            } detail: {
                detailView(for: selection ?? .overview)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(SpeechRailDesignTokens.Chassis.obsidian)
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            WorkspaceTitleLockup(
                                route: selection ?? .overview,
                                service: model.service,
                                health: displayedHealth,
                                healthMessage: model.healthMessage,
                                operation: model.serviceOperation,
                                controlPlaneMessage: model.controlPlaneMessage
                            )
                        }
                        .sharedBackgroundVisibility(.hidden)
                        ToolbarSpacer(.flexible)
                    }
                    .toolbarBackground(
                        SpeechRailDesignTokens.Color.canvas,
                        for: .windowToolbar
                    )
                    .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            }
            .navigationSplitViewStyle(.balanced)
            .frame(
                minWidth: controlCenterMinimumWidth,
                minHeight: SpeechRailDesignTokens.Layout.windowMinimumHeight
            )
            .background {
                if isUITestSession {
                    ControlCenterWindowActivator()
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                }
            }
            .task { await model.refresh() }
            .onAppear {
                if let route = navigation.consumeRequestedRoute() {
                    selection = route
                }
            }
            .onChange(of: navigation.requestedRoute) { _, _ in
                if let route = navigation.consumeRequestedRoute() {
                    selection = route
                }
            }
        }
    }

    private var visibleCreatorRoutes: [AppRoute] {
        matching(AppRoute.creatorRoutes)
    }

    private var displayedHealth: HealthSnapshot? {
        guard model.healthFailure == nil else { return nil }
        return model.health
    }

    private var visibleServiceRoutes: [AppRoute] {
        matching(AppRoute.serviceRoutes)
    }

    private func matching(_ routes: [AppRoute]) -> [AppRoute] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return routes }
        return routes.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.workspaceTitle.localizedCaseInsensitiveContains(query)
                || $0.contextTitle.localizedCaseInsensitiveContains(query)
                || $0.purpose.localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private func sidebarSection(title: String, routes: [AppRoute]) -> some View {
        Section {
            ForEach(routes, id: \.self) { route in
                navigationRow(for: route)
            }
        } header: {
            Text(title)
                .font(SpeechRailDesignTokens.Typography.caption)
                .fontWeight(.medium)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
        }
    }

    @ViewBuilder
    private func navigationRow(for route: AppRoute) -> some View {
        let isSelected = selection == route
        NavigationLink(value: route) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                RouteIconView(route: route, selected: isSelected)
                    .frame(width: SpeechRailDesignTokens.Icon.navigationFrame)
                    .foregroundStyle(
                        isSelected
                            ? SpeechRailDesignTokens.SteelRail.railheadGleam
                            : SpeechRailDesignTokens.Color.inkSecondary
                    )

                Text(route.title)
                    .font(isSelected ? SpeechRailDesignTokens.Typography.sectionTitle : SpeechRailDesignTokens.Typography.label)
                    .foregroundStyle(
                        isSelected
                            ? SpeechRailDesignTokens.Color.ink
                            : SpeechRailDesignTokens.Navigation.unselectedForeground
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)

                if isSelected {
                    // Physical Rail Indicator Bead (嵌入钢轨内的声轨冷青指示滑标)
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.pill, style: .continuous)
                            .fill(SpeechRailDesignTokens.SteelRail.railheadGleam)
                            .frame(width: 3, height: 16)
                            .shadow(color: SpeechRailDesignTokens.SteelRail.trackGlow, radius: 3)
                    }
                    .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
            .frame(
                maxWidth: .infinity,
                minHeight: SpeechRailDesignTokens.List.rowHeight,
                alignment: .leading
            )
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.row, style: .continuous)
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: SpeechRailDesignTokens.SteelRail.trackCyan.opacity(0.30), location: 0.0),
                                    .init(color: SpeechRailDesignTokens.SteelRail.trackCyan.opacity(0.12), location: 1.0)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.row, style: .continuous)
                                .strokeBorder(
                                    SpeechRailDesignTokens.SteelRail.railheadGleam.opacity(0.40),
                                    lineWidth: 0.75
                                )
                        }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(
            EdgeInsets(
                top: SpeechRailDesignTokens.Spacing.micro,
                leading: SpeechRailDesignTokens.Spacing.xs,
                bottom: SpeechRailDesignTokens.Spacing.micro,
                trailing: SpeechRailDesignTokens.Spacing.xs
            )
        )
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityIdentifier(route.id)
        .help(route.purpose)
        .accessibilityValue(
            isSelected ? "已选中。\(route.purpose)" : route.purpose
        )
        .speechRailPointerCursor()
    }

    private var sidebarServiceStatus: some View {
        Button {
            withAnimation(SpeechRailDesignTokens.Motion.springTransition) {
                selection = .overview
            }
        } label: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                // Micro-LED Jewel with Phosphor Diffusion (机架镶嵌式状态透光珠)
                ZStack {
                    Circle()
                        .fill(sidebarStatusTone.color.opacity(0.20))
                        .frame(width: 14, height: 14)
                    Circle()
                        .fill(sidebarStatusTone.color)
                        .frame(width: 6, height: 6)
                        .shadow(color: sidebarStatusTone.color.opacity(0.8), radius: 2)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Text("服务状态")
                        .font(SpeechRailDesignTokens.Typography.label)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    Text(sidebarStatusText)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(sidebarStatusTone.color)
                        .lineLimit(1)
                }
                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                Image(systemName: "chevron.right")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SpeechRailDesignTokens.List.rowHorizontalPadding)
                .padding(.vertical, SpeechRailDesignTokens.List.rowVerticalPadding)
        }
        .speechRailInteractiveButtonStyle(fillsAvailableWidth: true)
        .help("打开服务状态")
        .accessibilityLabel("服务状态")
        .accessibilityValue(sidebarStatusText)
    }

    private var sidebarStatusText: String {
        if model.serviceOperation?.phase.isActive == true {
            return "服务操作进行中"
        }
        if model.serviceOperation?.phase == .failed {
            return "服务操作未完成"
        }
        if model.healthMessage != nil {
            return "健康状态不可用"
        }
        if model.controlPlaneMessage != nil {
            return "控制通道不可用"
        }
        if displayedHealth?.ready == true {
            return "服务已就绪"
        }
        if model.service.serviceState == "unavailable" {
            return "服务不可用"
        }
        return "服务未就绪"
    }

    private var sidebarStatusTone: StatusTone {
        if model.serviceOperation?.phase.isActive == true {
            return .attention
        }
        if model.serviceOperation?.phase == .failed {
            return .critical
        }
        if model.healthMessage != nil {
            return .critical
        }
        if model.controlPlaneMessage != nil {
            return .attention
        }
        if displayedHealth?.ready == true {
            return .healthy
        }
        if model.service.serviceState == "unavailable" {
            return .critical
        }
        return .neutral
    }

    @ViewBuilder
    private func detailView(for route: AppRoute) -> some View {
        switch route {
        case .dubbing:
            DubbingDeskView()
        case .voiceDesign:
            VoiceDesignView()
        case .voiceLibrary:
            VoiceLibraryView()
        case .works:
            WorksView()
        case .overview:
            ServiceOverviewView()
        case .monitoring:
            RuntimeMonitoringView()
        case .models:
            ModelManagementView()
        case .diagnostics:
            PreflightDiagnosticsView()
        }
    }

    private var isUITestWithoutControlCenter: Bool {
#if DEBUG
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--ui-test") && !args.contains("--ui-test-open-control-center")
#else
        return false
#endif
    }

    private var isUITestSession: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-test")
#else
        false
#endif
    }

    private var controlCenterMinimumWidth: CGFloat {
        if isUITestSession {
            return 1_000
        }
        return SpeechRailDesignTokens.Layout.windowMinimumWidth
    }
}

#if DEBUG
private struct ControlCenterWindowActivator: NSViewRepresentable {
    func makeNSView(context: Context) -> ControlCenterWindowActivationView {
        ControlCenterWindowActivationView()
    }

    func updateNSView(_ nsView: ControlCenterWindowActivationView, context: Context) {
        nsView.activateIfPossible()
    }
}

private final class ControlCenterWindowActivationView: NSView {
    private var hasActivatedWindow = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        activateIfPossible()
    }

    fileprivate func activateIfPossible() {
        guard window != nil, !hasActivatedWindow else { return }
        hasActivatedWindow = true

        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.fit(window)
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func fit(_ window: NSWindow) {
        guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else { return }

        let maximumSize = NSSize(
            width: max(1, visibleFrame.width - 16),
            height: max(1, visibleFrame.height - 16)
        )
        window.minSize = NSSize(
            width: min(window.minSize.width, maximumSize.width),
            height: min(window.minSize.height, maximumSize.height)
        )

        var frame = window.frame
        frame.size.width = min(frame.size.width, maximumSize.width)
        frame.size.height = min(frame.size.height, maximumSize.height)
        frame.origin.x = min(
            max(frame.origin.x, visibleFrame.minX + 8),
            visibleFrame.maxX - frame.width - 8
        )
        frame.origin.y = min(
            max(frame.origin.y, visibleFrame.minY + 8),
            visibleFrame.maxY - frame.height - 8
        )
        window.setFrame(frame, display: true, animate: false)
    }
}
#endif
