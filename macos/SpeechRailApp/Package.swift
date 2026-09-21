// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SpeechRailMacControl",
    platforms: [.macOS(.v26)],
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
                "AssistantAudioPlayback.swift",
                "AssistantAudioSession.swift",
                "AudioPlaybackController.swift",
                "Assets.xcassets",
                "CaptionBandWindow.swift",
                "CaptionSession.swift",
                "ControlAgentStatusView.swift",
                "ControlCenterView.swift",
                "ControlMenuView.swift",
                "CreativeWorkStore.swift",
                "CreatorServiceClient.swift",
                "CreatorSurfaceViews.swift",
                "MicrophoneCapture.swift",
                "ModelManagementView.swift",
                "PreflightDiagnosticsView.swift",
                "ProfilePickerView.swift",
                "RealtimeASRClient.swift",
                "RuntimeMonitoringView.swift",
                "ServiceAPIClient.swift",
                "ServiceOverviewView.swift",
                "ServiceRoutePreviewView.swift",
                "ServiceStatusView.swift",
                "SettingsAssistantPane.swift",
                "SettingsComponents.swift",
                "SettingsView.swift",
                "SessionCoordinator.swift",
                "SessionDomain.swift",
                "SessionExporter.swift",
                "SpeechRailAPICredentials.swift",
                "SessionStore.swift",
                "SessionSurfaceViews.swift",
                "SurfaceHeaderView.swift",
                "WorkspaceComponents.swift",
            ],
            sources: [
                "ControlAgentRegistration.swift",
                "LLMProvider.swift",
                "RuntimeMetricsSampler.swift",
                "RuntimeMonitoringAccessibility.swift",
                "AudioSampleRing.swift",
                "SpeechRailDesignTokens.swift",
                "VoicePrompt.swift",
                "WindowLayoutPolicy.swift",
                "TeleprompterDomain.swift",
                "TeleprompterTimingPolicy.swift",
                "TeleprompterPreparationDomain.swift",
                "TeleprompterPreparationPrompts.swift",
                "TeleprompterNormalizer.swift",
                "TeleprompterSegmenter.swift",
                "TeleprompterAligner.swift",
                "TeleprompterAnalysis.swift",
                "TeleprompterStore.swift",
                "TeleprompterFollowController.swift",
                "TeleprompterStageSettings.swift",
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
