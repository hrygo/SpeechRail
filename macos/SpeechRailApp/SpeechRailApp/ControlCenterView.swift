import SwiftUI

public struct ControlCenterView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    @State private var selection: AppRoute? = .overview
    @State private var searchText = ""

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                if !visibleCreatorRoutes.isEmpty {
                    Section(AppRouteGroup.creator.title) {
                        ForEach(visibleCreatorRoutes) { route in
                            navigationRow(for: route)
                        }
                    }
                }
                if !visibleServiceRoutes.isEmpty {
                    Section(AppRouteGroup.service.title) {
                        ForEach(visibleServiceRoutes) { route in
                            navigationRow(for: route)
                        }
                    }
                }
                if visibleCreatorRoutes.isEmpty && visibleServiceRoutes.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.sidebar)
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
                .background(SpeechRailDesignTokens.Palette.groupedCanvas)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text(selection?.title ?? AppRoute.overview.title)
                            .font(SpeechRailDesignTokens.Typography.panelTitle)
                    }
                    ToolbarSpacer(.flexible)
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await model.refresh() }
                        } label: {
                            Label("刷新状态", systemImage: "arrow.clockwise")
                        }
                        .help("重新读取本机服务状态")
                    }
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
                || $0.purpose.localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private func navigationRow(for route: AppRoute) -> some View {
        Button {
            selection = route
        } label: {
            Label {
                Text(route.title)
            } icon: {
                Image(systemName: route.systemImage)
            }
        }
        .buttonStyle(.plain)
        .tag(route)
        .accessibilityIdentifier(route.id)
        .help(route.purpose)
        .accessibilityValue(route.purpose)
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
}
