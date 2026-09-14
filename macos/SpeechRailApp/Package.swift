// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SpeechRailMacControl",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpeechRailControlKit", targets: ["SpeechRailControlKit"]),
        .library(name: "SpeechRailControlAgentCore", targets: ["SpeechRailControlAgentCore"]),
        .executable(name: "SpeechRailControlAgent", targets: ["SpeechRailControlAgent"]),
    ],
    targets: [
        .target(
            name: "SpeechRailControlKit",
            path: "SpeechRailControlKit"
        ),
        .target(
            name: "SpeechRailControlAgentCore",
            dependencies: ["SpeechRailControlKit"],
            path: "SpeechRailControlAgentCore"
        ),
        .executableTarget(
            name: "SpeechRailControlAgent",
            dependencies: ["SpeechRailControlAgentCore", "SpeechRailControlKit"],
            path: "SpeechRailControlAgent"
        ),
        .target(
            name: "SpeechRailAppSupport",
            dependencies: ["SpeechRailControlKit"],
            path: "SpeechRailApp",
            exclude: [
                "App.swift",
                "AppModel.swift",
                "AppNavigationState.swift",
                "AppRoute.swift",
                "AudioPlaybackController.swift",
                "Assets.xcassets",
                "ControlAgentStatusView.swift",
                "ControlCenterView.swift",
                "ControlMenuView.swift",
                "CreativeWorkStore.swift",
                "CreatorServiceClient.swift",
                "CreatorSurfaceViews.swift",
                "ModelManagementView.swift",
                "PreflightDiagnosticsView.swift",
                "ProfilePickerView.swift",
                "RuntimeMonitoringView.swift",
                "ServiceAPIClient.swift",
                "ServiceOverviewView.swift",
                "ServiceRoutePreviewView.swift",
                "ServiceStatusView.swift",
                "SettingsView.swift",
                "SpeechRailDesignTokens.swift",
                "SurfaceHeaderView.swift",
                "WorkspaceComponents.swift",
            ],
            sources: [
                "ControlAgentRegistration.swift",
                "RuntimeMetricsSampler.swift",
                "RuntimeMonitoringAccessibility.swift",
            ]
        ),
        .testTarget(
            name: "SpeechRailMacControlTests",
            dependencies: [
                "SpeechRailControlKit",
                "SpeechRailControlAgentCore",
                "SpeechRailAppSupport",
            ],
            path: "SpeechRailMacControlTests"
        ),
    ]
)
