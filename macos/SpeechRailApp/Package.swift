// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SpeechRailMacControl",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SpeechRailControlKit", targets: ["SpeechRailControlKit"]),
        .library(name: "SpeechRailControlAgentCore", targets: ["SpeechRailControlAgentCore"]),
        .executable(name: "SpeechRailControlAgent", targets: ["SpeechRailControlAgent"]),
        .executable(name: "teleprompter-replay", targets: ["TeleprompterReplayTool"]),
        .executable(name: "assistant-replay", targets: ["AssistantReplayTool"]),
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
                "SessionSurfaceViews.swift",
                "SurfaceHeaderView.swift",
            ],
            sources: [
                "ControlAgentRegistration.swift",
                "LLMProvider.swift",
                "RuntimeMetricsSampler.swift",
                "RuntimeMonitoringAccessibility.swift",
                "AudioSampleRing.swift",
                "CoreAudioTapCapture.swift",
                "SpeechRailDesignTokens.swift",
                "RealtimeASRClient.swift",
                // 助手编排层：生产 AssistantSession 本身进单测目标，
                // 依赖的 LLM / Realtime / 播放通道由 AssistantSessionDependencies 注入。
                "AssistantSession.swift",
                "AssistantSessionDependencies.swift",
                "AssistantReplyState.swift",
                "AssistantPresentation.swift",
                "AssistantComposerPolicy.swift",
                "AssistantTurnPolicy.swift",
                "AssistantContextPolicy.swift",
                "AssistantInputPersistenceQueue.swift",
                "AssistantObservability.swift",
                "AssistantAudioPlayback.swift",
                "AssistantAudioSession.swift",
                "SessionPreferences.swift",
                // 单轮增量 TTS：文本稳定前缀、播放预算、utterance 状态机。
                // 三个都不依赖 AVFoundation，所以能和 RealtimeASRClient 一起进单测目标。
                "AssistantSpeechTextBuffer.swift",
                "AssistantPlaybackLedger.swift",
                "AssistantSpeechPlan.swift",
                "AssistantTTSStreamCoordinator.swift",
                "TeleprompterRealtimeClientProtocol.swift",
                // AppModel 及其最小闭包：SPM 测试目标与 Xcode 单测目标编译同一份实现，
                // 让 cancel/refresh 等状态机回归不用桩替身。
                //
                // 两条路径并不等价，不要按「同一个目录」推断覆盖面：CI 只跑
                // `swift test` 一条，`xcodebuild test` 仅本机经
                // `scripts/macos_app_build.sh --test-unit` 复跑，且它编译的测试文件
                // 更少（`WindowLayoutPolicy.swift` 等 3 个源文件与
                // `WindowLayoutPolicyTests.swift` 不在 `Unit Test Sources` 里）。
                // 见 #194。
                "AppModel.swift",
                "ServiceAPIClient.swift",
                "CreatorServiceClient.swift",
                "CreativeWorkStore.swift",
                "DubbingProjectStore.swift",
                "FirstResultReadiness.swift",
                "AudioPlaybackController.swift",
                "VoicePreviewCache.swift",
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
                "TeleprompterReplayEvaluator.swift",
                "TeleprompterStageSettings.swift",
                "TeleprompterStageInteractionPolicy.swift",
                "TeleprompterVoiceAssistLifecycle.swift",
                "TeleprompterSession.swift",
                "TeleprompterStageView.swift",
                "TeleprompterStageWindow.swift",
                "AssistantReplayEvaluator.swift",
                "SessionStore.swift",
                "SessionCoordinator.swift",
                "SessionExporter.swift",
            ]
        ),
        // 确定性回放 runner：只读仓库外 manifest，输出脱敏聚合结果。
        // 不录音、不下载模型、不联网；缺失素材或版本记录时直接失败。
        .executableTarget(
            name: "TeleprompterReplayTool",
            dependencies: ["SpeechRailAppSupport"],
            path: "TeleprompterReplayTool"
        ),
        // 语音助手离线回放 runner（VA-17b）：只读仓库外 manifest，输出脱敏聚合。
        // 不录音、不下载模型、不联网；缺失素材或版本记录时直接失败。
        .executableTarget(
            name: "AssistantReplayTool",
            dependencies: ["SpeechRailAppSupport"],
            path: "AssistantReplayTool"
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
