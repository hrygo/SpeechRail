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
            .searchable(text: $searchText, placement: .sidebar, prompt: "搜索创作和服务")
            .navigationSplitViewColumnWidth(
                min: SpeechRailDesignTokens.Layout.sidebarMinimumWidth,
                ideal: SpeechRailDesignTokens.Layout.sidebarIdealWidth,
                max: SpeechRailDesignTokens.Layout.sidebarMaximumWidth
            )
            .safeAreaInset(edge: .bottom) {
                sidebarFooter
            }
            .backgroundExtensionEffect()
        } detail: {
            detailView(for: selection ?? .overview)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Text(selection?.title ?? AppRoute.overview.title)
                                .font(SpeechRailDesignTokens.Typography.panelTitle)
                            if selection?.group == .service {
                                statusPill
                            }
                        }
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
    }

    private var sidebarFooter: some View {
        Button {
            selection = .overview
        } label: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Image(systemName: globalStatusIcon)
                    .foregroundStyle(globalStatusColor)
                    .imageScale(.small)
                Text(globalStatusText)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Palette.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let profile = model.profile?.preset {
                    Text(profile.rawValue)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
            .background(
                SpeechRailDesignTokens.Color.field.opacity(0.85),
                in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.row)
            )
            .overlay {
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.row)
                    .stroke(SpeechRailDesignTokens.Surface.hairlineStroke, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .help("点击打开服务状态概览")
        .accessibilityLabel("全局服务状态：\(globalStatusText)")
    }

    private var statusPill: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
            Image(systemName: globalStatusIcon)
                .imageScale(.small)
            Text(globalStatusText)
                .font(SpeechRailDesignTokens.Typography.caption)
        }
        .foregroundStyle(globalStatusColor)
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
        .padding(.vertical, 2)
        .background(globalStatusColor.opacity(0.12), in: Capsule())
    }

    private var globalStatusIcon: String {
        if model.service.ready == true {
            return "checkmark.circle.fill"
        }
        if model.service.serviceState == "unavailable" {
            return "xmark.circle.fill"
        }
        return "exclamationmark.triangle.fill"
    }

    private var globalStatusColor: SwiftUI.Color {
        if model.service.ready == true {
            return SpeechRailDesignTokens.Color.ready
        }
        if model.service.serviceState == "unavailable" {
            return SpeechRailDesignTokens.Color.critical
        }
        return SpeechRailDesignTokens.Color.attention
    }

    private var globalStatusText: String {
        if model.service.ready == true {
            return "服务已就绪"
        }
        if model.service.serviceState == "unavailable" {
            return "服务不可用"
        }
        return "服务未就绪"
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

    private var isUITestWithoutControlCenter: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--ui-test") && !args.contains("--ui-test-open-control-center")
    }
}
