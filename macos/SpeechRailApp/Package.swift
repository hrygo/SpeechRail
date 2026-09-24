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
    dependencies: [
        .package(url: "https://github.com/MacPaw/OpenAI.git", exact: "0.5.1"),
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
            dependencies: [
                "SpeechRailControlKit",
                .product(name: "OpenAI", package: "OpenAI"),
            ],
            path: "SpeechRailApp",
            exclude: [
                "App.swift",
                "AppNavigationState.swift",
                "AssistantAudioPlayback.swift",
                "AssistantAudioSession.swift",
                "Assets.xcassets",
                "CaptionBandWindow.swift",
                "CaptionSession.swift",
                "ControlAgentStatusView.swift",
                "ControlCenterView.swift",
                "ControlMenuView.swift",
                "CreatorSurfaceViews.swift",
                "ModelManagementView.swift",
                "PreflightDiagnosticsView.swift",
                "ProfilePickerView.swift",
                "RuntimeMonitoringView.swift",
                "ServiceOverviewView.swift",
                "ServiceRoutePreviewView.swift",
                "ServiceStatusView.swift",
                "SettingsAssistantPane.swift",
                "SettingsComponents.swift",
                "SettingsView.swift",
                "SessionExporter.swift",
                "SessionSurfaceViews.swift",
                "SurfaceHeaderView.swift",
            ],
            sources: [
                "ControlAgentRegistration.swift",
                "LLMProvider.swift",
                "RuntimeMetricsSampler.swift",
                "RuntimeMonitoringAccessibility.swift",
                "AudioSampleRing.swift",
                "SpeechRailDesignTokens.swift",
                "RealtimeASRClient.swift",
                "TeleprompterRealtimeClientProtocol.swift",
                // AppModel 及其最小闭包：测试目标与 Xcode 单测目标编译同一份实现，
                // 让 cancel/refresh 等状态机回归能在两条 CI 门禁里跑（无桩替代）。
                "AppModel.swift",
                "ServiceAPIClient.swift",
                "CreatorServiceClient.swift",
                "CreativeWorkStore.swift",
                "AudioPlaybackController.swift",
                "VoiceRecordingController.swift",
                "AudioReferenceCheck.swift",
                "AudioEnvelope.swift",
                "SpeechRailAPICredentials.swift",
                "WorkspaceComponents.swift",
                "MicrophoneCapture.swift",
                "AppRoute.swift",
                "SessionDomain.swift",
                "VoicePrompt.swift",
                "WindowLayoutPolicy.swift",
                "TeleprompterDomain.swift",
                "TeleprompterTimingPolicy.swift",
                "TeleprompterPreparationDomain.swift",
                "TeleprompterPreparationPrompts.swift",
                "TeleprompterPreparationPipeline.swift",
                "TeleprompterV2Store.swift",
                "TeleprompterNormalizer.swift",
                "TeleprompterSegmenter.swift",
                "TeleprompterAligner.swift",
                "TeleprompterAnalysis.swift",
                "TeleprompterStore.swift",
                "TeleprompterFollowController.swift",
                "TeleprompterStageSettings.swift",
                "TeleprompterStageInteractionPolicy.swift",
                "TeleprompterVoiceAssistLifecycle.swift",
                "TeleprompterSession.swift",
                "TeleprompterStageView.swift",
                "TeleprompterStageWindow.swift",
                "SessionStore.swift",
                "SessionCoordinator.swift",
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
