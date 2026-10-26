import AppKit
import Foundation

// MARK: - 生产环境应用音频采集适配器

/// 将选定的应用目标适配为 `AudioChunkSource`。
///
/// 直接使用 `SystemAudioCapture`（XPC + `CoreAudioTapCapture`）按目标应用 `bundleID`
/// 采集 24kHz / 单声道 / PCM16 音频，不经过多路 `StreamMixer`（省去 40ms 混音缓冲与后台轮询，
/// 且在目标应用退出时能立即将 `.sourceLost` 终止信号传回 `CaptionSession`）。
@MainActor
public final class AppAudioTapChunkSource: AudioChunkSource, @unchecked Sendable {
    private let target: CaptionTargetApp
    private var capture: SystemAudioCapture?

    public init(target: CaptionTargetApp) {
        self.target = target
    }

    public func start() async throws -> AudioChunkStream {
        await stop()
        let systemCapture = SystemAudioCapture(
            selection: .init(
                bundleIDs: [target.bundleID],
                label: target.appName
            )
        )
        self.capture = systemCapture
        do {
            return try await systemCapture.start()
        } catch {
            await systemCapture.stop()
            if self.capture === systemCapture {
                self.capture = nil
            }
            if error is CancellationError { throw error }
            throw MeetingAudioBlocked(reason: .systemAudioUnavailable(error.localizedDescription))
        }
    }

    public func stop() async {
        let active = capture
        capture = nil
        await active?.stop()
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
        contextLines: [String],
        priorDraftTranslation: String?,
        systemInstructions: String? = nil
    ) -> AsyncThrowingStream<String, any Error> {
        let resolved = preferences.resolvedLLMConfiguration(for: .captions)
        let prompt = CaptionTranslationCoordinator.buildUserPrompt(
            sourceText: sourceText,
            contextLines: contextLines,
            priorDraftTranslation: priorDraftTranslation
        )
        let configuration = resolved.configuration
        let apiKey = resolved.apiKey
        let instructions = systemInstructions ?? CaptionTranslationCoordinator.systemInstructions
        let provider = self.provider

        // `LLMProvider` 是 actor，取它的流必须跨隔离域 await；而字幕翻译器要的是
        // **同步返回**的流（取消消费者即取消这一次翻译）。这里用一层桥接把两者对上：
        // 消费端终止 -> 取消桥接任务 -> 取消 provider 的流。首字节之前只有这一次跳转，
        // 不额外引入排队或缓冲。
        let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        let bridge = Task {
            do {
                let deltas = await provider.streamTranslation(
                    configuration: configuration,
                    prompt: prompt,
                    instructions: instructions,
                    apiKey: apiKey
                )
                for try await delta in deltas {
                    continuation.yield(delta)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in bridge.cancel() }
        return stream
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
