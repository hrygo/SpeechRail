import AppKit
import Foundation

// MARK: - 生产环境应用音频采集适配器

/// 将选定的应用目标适配为 `AudioChunkSource`。
///
/// 内部复用成熟稳定的 `AudioSourceCoordinator` 系统音频采集通道与 CoreAudio tap，
/// 保持 24kHz / 单声道 / PCM16 输出，离开会话时即刻释放音频设备与 tap。
public final class AppAudioTapChunkSource: AudioChunkSource, @unchecked Sendable {
    private let target: CaptionTargetApp
    private let coordinator = AudioSourceCoordinator()

    public init(target: CaptionTargetApp) {
        self.target = target
    }

    public func start() async throws -> AudioChunkStream {
        let selection = AudioSourceCoordinator.Selection(
            usesMicrophone: false,
            systemApps: [SystemAudioApp(bundleID: target.bundleID, name: target.appName)]
        )
        return try await coordinator.start(selection: selection)
    }

    public func stop() async {
        await coordinator.stop()
    }
}

// MARK: - 生产环境 LLM 翻译客户端

/// 生产环境下的流式中文字幕翻译客户端。
///
/// 每次翻译请求动态读取 `SessionPreferences` 中针对 `.captions` 模块解析的最新端点配置与 Key。
@MainActor
public final class LLMTranslationClient: CaptionTranslationClient {
    private let preferences: SessionPreferences
    private let provider: LLMProvider

    public init(preferences: SessionPreferences, provider: LLMProvider = LLMProvider()) {
        self.preferences = preferences
        self.provider = provider
    }

    public func translateStream(
        sourceText: String,
        contextLines: [String]
    ) -> AsyncThrowingStream<String, any Error> {
        let resolved = preferences.resolvedLLMConfiguration(for: .captions)
        let prompt = CaptionTranslationCoordinator.buildUserPrompt(
            sourceText: sourceText,
            contextLines: contextLines
        )
        return provider.streamTranslation(
            configuration: resolved.configuration,
            prompt: prompt,
            instructions: CaptionTranslationCoordinator.systemInstructions,
            apiKey: resolved.apiKey
        )
    }
}

// MARK: - CaptionSession 依赖接线

extension CaptionSession {
    /// 在 App 运行时为 `CaptionSession` 挂载真实依赖（窗口拾取、系统音频采集与 LLM 翻译）。
    public func wireProductionDependencies(preferences: SessionPreferences) {
        // 1. 全屏窗口拾取器
        self.presentWindowPicker = {
            await WindowPickerOverlayController.pickTarget()
        }

        // 2. 音频捕获通道工厂
        self.makeAudioSourceForTarget = { target in
            switch target {
            case .microphone:
                return MicrophoneCapture()
            case .app(let appTarget):
                return AppAudioTapChunkSource(target: appTarget)
            }
        }

        // 3. 翻译客户端工厂
        self.makeTranslationClient = { [weak preferences] in
            guard let preferences else { return nil }
            return LLMTranslationClient(preferences: preferences)
        }
    }
}
