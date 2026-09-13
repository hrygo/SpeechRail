import SwiftUI

public struct ControlCenterView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @State private var selection: AppRoute? = .overview
    @State private var searchText = ""

    public init() {}

    public var body: some View {
        if isUITestWithoutControlCenter {
            Color.clear
                .frame(width: 0, height: 0)
                .onAppear {
                    dismiss()
                }
        } else {
            NavigationSplitView {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        if !visibleCreatorRoutes.isEmpty {
                            Section {
                                ForEach(visibleCreatorRoutes) { route in
                                    navigationRow(for: route)
                                }
                            } header: {
                                Text(AppRouteGroup.creator.title)
                            }
                        }
                        if !visibleServiceRoutes.isEmpty {
                            Section {
                                ForEach(visibleServiceRoutes) { route in
                                    navigationRow(for: route)
                                }
                            } header: {
                                Text(AppRouteGroup.service.title)
                            }
                        }
                        if visibleCreatorRoutes.isEmpty && visibleServiceRoutes.isEmpty {
                            ContentUnavailableView.search(text: searchText)
                                .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.sidebar)
                    .tint(SpeechRailDesignTokens.Color.rail)
                    .searchable(text: $searchText, placement: .sidebar, prompt: "搜索创作和服务")
                    .backgroundExtensionEffect()

                    Divider()
                    sidebarServiceStatus
                }
                .navigationSplitViewColumnWidth(
                    min: SpeechRailDesignTokens.Layout.sidebarMinimumWidth,
                    ideal: SpeechRailDesignTokens.Layout.sidebarIdealWidth,
                    max: SpeechRailDesignTokens.Layout.sidebarMaximumWidth
                )
                .background(SpeechRailDesignTokens.Surface.navigationFill)
            } detail: {
                detailView(for: selection ?? .overview)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(SpeechRailDesignTokens.Color.canvas)
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            WorkspaceTitleLockup(
                                route: selection ?? .overview,
                                service: model.service,
                                health: model.health,
                                healthMessage: model.healthMessage,
                                operation: model.serviceOperation,
                                controlPlaneMessage: model.controlPlaneMessage
                            )
                        }
                        .sharedBackgroundVisibility(.hidden)
                        ToolbarItem(placement: .primaryAction) {
                            ServiceStatusBadge()
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
                minWidth: SpeechRailDesignTokens.Layout.windowMinimumWidth,
                minHeight: SpeechRailDesignTokens.Layout.windowMinimumHeight
            )
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
    private func navigationRow(for route: AppRoute) -> some View {
        let isSelected = selection == route
        NavigationLink(value: route) {
            Label {
            Text(route.title)
                    .font(SpeechRailDesignTokens.Typography.label)
                    .foregroundStyle(
                        isSelected
                            ? SpeechRailDesignTokens.Navigation.selectedForeground
                            : SpeechRailDesignTokens.Navigation.unselectedForeground
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                RouteIconView(route: route, selected: isSelected)
            }
            .frame(
                maxWidth: .infinity,
                minHeight: SpeechRailDesignTokens.Control.sidebarRowHeight,
                alignment: .leading
            )
        }
        .listRowInsets(
            EdgeInsets(
                top: SpeechRailDesignTokens.Spacing.micro,
                leading: SpeechRailDesignTokens.Spacing.xs,
                bottom: SpeechRailDesignTokens.Spacing.micro,
                trailing: SpeechRailDesignTokens.Spacing.xs
            )
        )
        .listRowSeparator(.hidden)
        .frame(minHeight: SpeechRailDesignTokens.Control.sidebarRowHeight)
        .contentShape(Rectangle())
        .accessibilityIdentifier(route.id)
        .help(route.purpose)
        .accessibilityValue(
            isSelected ? "已选中。\(route.purpose)" : route.purpose
        )
        .speechRailPointerCursor()
    }

    private var sidebarServiceStatus: some View {
        Button {
            withAnimation(SpeechRailDesignTokens.Motion.selectionFeedback) {
                selection = .overview
            }
        } label: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Image(systemName: sidebarStatusTone.systemImage)
                    .font(SpeechRailDesignTokens.Typography.label)
                    .foregroundStyle(sidebarStatusTone.color)
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
        }
        .speechRailInteractiveButtonStyle()
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
        .speechRailPointerCursor()
        .help("打开服务状态")
        .accessibilityLabel("服务状态")
        .accessibilityValue(sidebarStatusText)
    }

    private var sidebarStatusText: String {
        if model.serviceOperation?.phase.isActive == true {
            return "服务操作进行中"
        }
        if model.healthMessage != nil {
            return "健康状态不可用"
        }
        if model.controlPlaneMessage != nil {
            return "控制通道不可用"
        }
        if model.health?.ready == true {
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
        if model.healthMessage != nil {
            return .critical
        }
        if model.controlPlaneMessage != nil {
            return .attention
        }
        if model.health?.ready == true {
            return .healthy
        }
        if model.service.serviceState == "unavailable" {
            return .critical
        }
        return .neutral
    }

    @ViewBuilder
    private func detailView(for route: AppRoute) -> some View {
        switch route.group {
        case .creator:
            CreatorSurfaceView(route: route)
        case .service:
            switch route {
            case .overview:
                ServiceOverviewView()
            case .monitoring:
                RuntimeMonitoringView()
            case .models:
                ModelManagementView()
            case .diagnostics:
                PreflightDiagnosticsView()
            case .dubbing, .voiceDesign, .voiceLibrary, .works:
                EmptyView()
            }
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
}
