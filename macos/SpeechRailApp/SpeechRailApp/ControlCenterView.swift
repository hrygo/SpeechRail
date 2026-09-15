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
                    .searchable(text: $searchText, placement: .sidebar, prompt: "搜索创作和服务")

                    Divider()
                    sidebarServiceStatus
                }
                .navigationSplitViewColumnWidth(
                    min: SpeechRailDesignTokens.Layout.sidebarMinimumWidth,
                    ideal: SpeechRailDesignTokens.Layout.sidebarIdealWidth,
                    max: SpeechRailDesignTokens.Layout.sidebarMaximumWidth
                )
            } detail: {
                detailView(for: selection ?? .overview)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            }
            .navigationSplitViewStyle(.balanced)
            .frame(
                minWidth: controlCenterMinimumWidth,
                minHeight: SpeechRailDesignTokens.Layout.windowMinimumHeight
            )
            .background {
#if DEBUG
                if isUITestSession {
                    ControlCenterWindowActivator()
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                }
#endif
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
        Section(title) {
            ForEach(routes, id: \.self) { route in
                navigationRow(for: route)
            }
        }
    }

    @ViewBuilder
    private func navigationRow(for route: AppRoute) -> some View {
        NavigationLink(value: route) {
            Label(route.title, systemImage: route.systemImage)
                .symbolRenderingMode(.monochrome)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(
                    maxWidth: .infinity,
                    minHeight: SpeechRailDesignTokens.List.rowHeight,
                    alignment: .leading
                )
                .contentShape(Rectangle())
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
        .listRowBackground(Color.clear)
        .accessibilityIdentifier(route.id)
        .help(route.purpose)
        .accessibilityValue(
            selection == route ? "已选中。\(route.purpose)" : route.purpose
        )
        .speechRailPointerCursor()
    }

    private var sidebarServiceStatus: some View {
        Button {
            selection = .overview
        } label: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                Circle()
                    .fill(sidebarStatusTone.color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                    Text("服务状态")
                        .font(.callout)
                        .foregroundStyle(.primary)
                    Text(sidebarStatusText)
                        .font(.caption)
                        .foregroundStyle(sidebarStatusTone.color)
                        .lineLimit(1)
                }
                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
