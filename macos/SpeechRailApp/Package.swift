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
                "CaptionSession.swift",
                "ASRScenePreset.swift",
                "AssistantInputTurnAssembler.swift",
                "TranscriptPreviewLedger.swift",
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
                // CI 的 check_macos_test_target_coverage.py 核对所有测试文件的
                // Xcode Sources 登记；Xcode 单测经 macos_app_build.sh --test-unit
                // 执行，编译器另外验证被测实现的依赖闭包。
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
                "MeetingKnowledgeQuery.swift",
                // 会议知识库列表与详情（MA-12）：选中代次守卫在模型层，视图只负责画。
                "MeetingLibraryModel.swift",
                "MeetingKnowledgeLibraryView.swift",
                // 纪要核对的编辑状态（MA-11）：草稿、失败态与快捷键策略在模型层，
                // 视图只负责画。
                "MinutesReviewModel.swift",
                "MinutesReviewView.swift",
                // 会前/会中来源呈现门面（MA-10）：采集状态到用户语言的翻译。
                "MeetingSourcePresentation.swift",
                // 六条状态轴的统一投影（MA-21）。
                "MeetingAxisProjection.swift",
                // 转录流粘底策略（MA-10）：回看时不许被新句子拽走。
                "TranscriptFollowState.swift",
                // 会议编排层的依赖边界（MA-01）：设备 / 连接 / 时钟可替换。
                "MeetingSessionDependencies.swift",
                // item 级转录账本（MA-02）：按 (代次, itemID) 去重，快照按 revision 替换。
                "TranscriptItemLedger.swift",
                // 时间证据（MA-02）：观测时刻与声学起止分开，伪造精度在类型层面不可能。
                "TranscriptTimeWindow.swift",
                // 生产 MeetingSession 进单测目标（MA-01 收尾）：设备 / 连接 / 时钟 / 睡眠通知
                // 都经 `MeetingSessionDependencies` 注入，协议与值类型留在本目标内；
                // App-only 的 `AudioSourceCoordinator` 由 `MeetingSessionProductionWiring.swift`
                // 在 App target 里接线。所以这里进得来的是**生产类本身**，不是一个替身。
                "MeetingAudioBlockReason.swift",
                "MeetingSession.swift",
                "SpeakerLabeling.swift",
                "InnerOSSession.swift",
                "MinutesGenerator.swift",
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
