import Foundation
import SpeechRailControlKit

// MARK: - 编排层的依赖边界
//
// `AssistantSession` 是这条链上唯一"什么都认识"的地方：麦克风、WebSocket、
// 大模型、播放、记录库都从它穿过。生产运行时这些都接真实实现；测试要用同一份
// `AssistantSession` 把 start / ask / end 跑完整，就必须在**这里**换成假实现，
// 而不是另写一份仿制的状态机。
//
// 三条约束：
//
//   1. 协议只覆盖编排层**实际调用**的成员，不做"以后可能用到"的宽接口；
//   2. 生产默认值写在 `Dependencies` 里，composition root 不必改动，行为不变；
//   3. 假实现不读钥匙串、不连 loopback、不构造 `AVAudioEngine`。

/// 编排层用到的 LLM 面。生产实现是 `LLMProvider`（`actor`）。
public protocol AssistantLLM: Sendable {
    func check(
        configuration: LLMConfiguration,
        apiKey: String?,
        operation: LLMOperation,
        allowThinkingControlFallback: Bool
    ) async -> LLMConnectionResult
    func stream(
        configuration: LLMConfiguration,
        messages: [LLMMessage],
        apiKey: String?,
        maxOutputTokens: Int?,
        instructions: String?
    ) async -> AsyncThrowingStream<String, Error>
}

extension LLMProvider: AssistantLLM {}

/// 一条 Realtime 连接。生产实现是 `RealtimeASRClient`（`actor`）。
///
/// 只列编排层真正调用的方法：ASR 上行、TTS 增量文本、音色切换、结束时的
/// drain/close，以及下行事件流。终态闩、限流与协议细节仍归 `RealtimeASRClient`。
public protocol AssistantRealtimeClient: Sendable {
    func events() async -> RealtimeEventStream<RealtimeASRClient.Event>
    func connect() async throws
    func close() async
    func append(_ pcm: Data) async throws
    func drainAndClear(timeout: Duration) async throws
    func updateVoice(
        _ voice: String,
        expectedVoiceRevision: String?,
        expectedTTSRevision: String?
    ) async throws
    func startTTSStream(requestID: String, speed: Double?, audioWindowBytes: Int) async throws
    func acknowledgeTTSAudio(requestID: String, sampleOffset: Int) async throws
    func appendTTSText(_ text: String, sequence: Int) async throws
    func finishTTSText(lastSequence: Int) async throws
    func cancelTTS() async throws
}

extension RealtimeASRClient: AssistantRealtimeClient {}

/// 独立播放通道（`AssistantAudioSession` 之外的兼容路径）。
/// 生产实现是 `PCMStreamPlayer`，它包着 `AVAudioEngine`。
public protocol AssistantPlaybackChannel: AnyObject, Sendable {
    var onDrained: (@MainActor () -> Void)? { get set }
    /// 每一块设备播放完成时回调（入队时的 epoch、帧数、chunkID；M0d 用 played 语义）。
    var onBufferRendered: (@MainActor (Int, Int, UUID) -> Void)? { get set }
    func start() async throws
    @discardableResult
    func enqueue(_ pcm: Data, epoch: Int, chunkID: UUID) async -> Bool
    func stop() async
}

extension PCMStreamPlayer: AssistantPlaybackChannel {}

/// 编排层可以替换的外部依赖。默认值就是生产行为。
public struct AssistantSessionDependencies: Sendable {
    public var llm: any AssistantLLM
    /// 建一条新的 Realtime 连接。每次 `startPipeline` 调一次，所以"每轮建连"
    /// 必须在测试里可数。
    public var makeRealtimeClient: @Sendable (AssistantRealtimeClientConfiguration) -> any AssistantRealtimeClient
    /// 没有 `AssistantAudioSession` 时的兼容播放通道。
    public var makePlaybackChannel: @MainActor () -> any AssistantPlaybackChannel
    /// 记录"此刻"。测试注入虚拟时钟，时间语义（D09）才可重现。
    public var now: @Sendable () -> Date
    /// 仅替换用户输入保存 IO；默认仍由 SessionCoordinator 写入。
    public var saveInputLine: (@Sendable (LineDraft, String) async throws -> Int)?
    /// M2/V06:仅替换助手回复建行/收尾回退 INSERT；默认仍由 SessionCoordinator 写入。
    /// 测试用它 gate 住首次 INSERT，验证首 delta 正文预览不被建行阻塞。
    public var saveReplyLine: (@Sendable (LineDraft, String) async throws -> Int)?
    /// M2/V06:仅替换自动标题认领；默认仍由 SessionCoordinator 写入。
    /// 测试用它 gate 住标题 IO，验证标题不挡正文投影与 LLM 启动。
    public var claimTitle: (@Sendable (String, String, String) async throws -> Bool)?
    public var inputPersistenceConfiguration: TranscriptPersistenceQueue.Configuration
    public var drainTimeout: Duration

    public init(
        llm: any AssistantLLM = LLMProvider(),
        makeRealtimeClient: @escaping @Sendable (AssistantRealtimeClientConfiguration) -> any AssistantRealtimeClient = { configuration in
            RealtimeASRClient(
                port: configuration.port,
                scenePreset: configuration.scenePreset,
                voice: configuration.voice,
                apiKey: configuration.apiKey,
                expectedASRRevision: configuration.expectedASRRevision,
                expectedTTSRevision: configuration.expectedTTSRevision,
                expectedVoiceRevision: configuration.expectedVoiceRevision,
                callerTTSEnabled: true
            )
        },
        makePlaybackChannel: @escaping @MainActor () -> any AssistantPlaybackChannel = { PCMStreamPlayer() },
        now: @escaping @Sendable () -> Date = { Date() },
        saveInputLine: (@Sendable (LineDraft, String) async throws -> Int)? = nil,
        saveReplyLine: (@Sendable (LineDraft, String) async throws -> Int)? = nil,
        claimTitle: (@Sendable (String, String, String) async throws -> Bool)? = nil,
        inputPersistenceConfiguration: TranscriptPersistenceQueue.Configuration = .init(),
        drainTimeout: Duration = .seconds(12)
    ) {
        self.llm = llm
        self.makeRealtimeClient = makeRealtimeClient
        self.makePlaybackChannel = makePlaybackChannel
        self.now = now
        self.saveInputLine = saveInputLine
        self.saveReplyLine = saveReplyLine
        self.claimTitle = claimTitle
        self.inputPersistenceConfiguration = inputPersistenceConfiguration
        self.drainTimeout = drainTimeout
    }
}

/// 建一条连接所需的全部参数。抽成值类型之后，测试可以断言"用哪个音色、
/// 哪个修订建连"，而不必读 `RealtimeASRClient` 的私有状态。
public struct AssistantRealtimeClientConfiguration: Sendable {
    public var port: Int
    public var scenePreset: ASRScenePreset
    public var voice: String?
    public var apiKey: String?
    public var expectedASRRevision: String?
    public var expectedTTSRevision: String?
    public var expectedVoiceRevision: String?

    public init(
        port: Int,
        scenePreset: ASRScenePreset = .assistantTurnTaking,
        voice: String?,
        apiKey: String?,
        expectedASRRevision: String?,
        expectedTTSRevision: String?,
        expectedVoiceRevision: String?
    ) {
        self.port = port
        self.scenePreset = scenePreset
        self.voice = voice
        self.apiKey = apiKey
        self.expectedASRRevision = expectedASRRevision
        self.expectedTTSRevision = expectedTTSRevision
        self.expectedVoiceRevision = expectedVoiceRevision
    }
}
