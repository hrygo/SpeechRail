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
                .navigationSplitViewColumnWidth(
                    min: SpeechRailDesignTokens.Layout.sidebarMinimumWidth,
                    ideal: SpeechRailDesignTokens.Layout.sidebarIdealWidth,
                    max: SpeechRailDesignTokens.Layout.sidebarMaximumWidth
                )
                .backgroundExtensionEffect()
            } detail: {
                detailView(for: selection ?? .overview)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(SpeechRailDesignTokens.Color.canvas)
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            WorkspaceTitleLockup(route: selection ?? .overview, service: model.service)
                        }
                        ToolbarItem(placement: .automatic) {
                            ServiceStatusBadge()
                        }
                        ToolbarSpacer(.flexible)
                    }
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
                            : SpeechRailDesignTokens.Color.inkSecondary
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
        .listRowBackground(
            RoundedRectangle(
                cornerRadius: SpeechRailDesignTokens.Corner.row,
                style: .continuous
            )
            .fill(
                isSelected
                    ? SpeechRailDesignTokens.Navigation.selectedFill
                    : Color.clear
            )
        )
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
        .accessibilityIdentifier(route.id)
        .help(route.purpose)
        .accessibilityValue(
            isSelected ? "已选中。\(route.purpose)" : route.purpose
        )
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
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--ui-test") && !args.contains("--ui-test-open-control-center")
    }
}
