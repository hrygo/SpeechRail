import Foundation
import Observation
import SpeechRailControlKit

// 语音助手的会话层（`TECHNICAL-DESIGN` §5.5、`SESSIONS-SPEC` §6.1 / §8.1 / §14.4 / §14.5）。
//
// 一条线：**麦克风 → 服务端 ASR → Responses → TTS → 播放**，四种失败各有各的出口。
// 三条只在实现里说得清的取舍：
//
//   1. **人设是锁，不是选择器**（§14.4）。它在开始那一刻写进 developer 消息，会话内只读；
//      要换就新开一轮（`personaLock` 是可读结论 + 一个出口，不是静默忽略）。
//   2. **音色只是声音**。换音色写入下一次 caller-owned TTS request，并落一条
//      `session_change(kind='voice')`——「第 N 句起」这句话必须有数据支撑。
//   3. **打字提问不朗读回复**（§6.1）：正文落库（`source='keyboard'`），回复仍可点「重播」。
//   4. **契约在顶层 `instructions`，人设只是风格**：语音对话契约走 Responses 的 `instructions`
//      （每轮重发，续轮不继承），人设走 developer 消息并让位给契约；送 TTS 前还有一道文本清洗。
//      三者都收在 `VoicePrompt.swift` 里，单独可测。
//
// 打断的口径来自契约与规格：服务端只提供 `speech_started` 事实，
// AssistantSession 决定是否 cancel、丢掉还没播的缓冲并记 `interrupted`。

@MainActor
@Observable
public final class AssistantSession {
    public enum Phase: String, Sendable, Equatable {
        case idle
        case preparing
        /// 在听（用户这一侧）。
        case listening
        /// 在想（大模型在流式回答）。
        case thinking
        /// 在说（TTS 音频在放）。
        case speaking
        case paused
        case ending

        public var isLive: Bool {
            switch self {
            case .preparing, .listening, .thinking, .speaking: true
            default: false
            }
        }

        public var title: String {
            switch self {
            case .idle: "未开始"
            case .preparing: "正在准备…"
            case .listening: "正在聆听"
            case .thinking: "正在思考"
            case .speaking: "正在说话"
            case .paused: "已暂停"
            case .ending: "正在收尾…"
            }
        }
    }

    /// 受阻的原因。**一律给可读结论 + 一个出口**（§6.1 的受阻态）。
    public enum BlockReason: Equatable, Sendable {
        case llmNotConfigured
        case llmUnreachable(String)
        case microphoneDenied
        case serviceNotReady(String)
        case serviceBusy(String)
        case occupiedBy(SessionKind)
        case storeUnavailable(String)
        case streamFailed(String)

        public var title: String {
            switch self {
            case .llmNotConfigured: "还没有配置对话模型"
            case .llmUnreachable: "对话模型连不上"
            case .microphoneDenied: "麦克风未授权"
            case .serviceNotReady: "语音服务未就绪"
            case .serviceBusy: "语音服务正忙"
            case .occupiedBy(let kind): "\(kind.title)正在使用麦克风"
            case .storeUnavailable: "记录库不可用"
            case .streamFailed: "识别中断了"
            }
        }

        public var detail: String {
            switch self {
            case .llmNotConfigured:
                "语音识别和语音合成现在就能用；助手需要一台兼容 OpenAI 的服务："
                    + "把地址、模型与密钥填进设置即可，地址是本机还是局域网都行。"
                    + "对接要求只有一条：服务要实现 Responses API（只支持 Chat Completions 的服务接不上）。"
            case .llmUnreachable(let message): message
            case .microphoneDenied: "在系统设置里允许 SpeechRail 使用麦克风，然后回来重试。"
            case .serviceNotReady(let message): message
            case .serviceBusy(let message): message
            case .occupiedBy: "麦克风同一时刻只能由一个会话使用；可以先打字问，或者结束那个会话。"
            case .storeUnavailable(let message): message
            case .streamFailed(let message): "\(message)丢掉的音频就是没录上；已经定稿的对话都还在。"
            }
        }

        /// 打字输入是缺麦克风时的实际出口，所以"没有麦克风"这一类要**保留输入框可用**（§6.1）。
        public var allowsTyping: Bool {
            switch self {
            case .microphoneDenied, .occupiedBy, .serviceBusy: true
            default: false
            }
        }
    }

    /// 一轮对话里的一行（对话流与记录库共用）。
    public struct Turn: Identifiable, Sendable, Equatable {
        public var id: String
        public var ordinal: Int
        public var role: SessionLineRole
        public var text: String
        public var source: SessionLineSource
        public var isInterrupted: Bool
        public var speakerLabel: String?
        /// 这一句的时刻（墙上时间）。稿的对话行右侧有时间码（`14:02:11`），
        /// 回看时读的是 `TranscriptLine.createdAt`——两处得是同一种时间。
        public var createdAt: Date

        public init(
            id: String,
            ordinal: Int,
            role: SessionLineRole,
            text: String,
            source: SessionLineSource,
            isInterrupted: Bool,
            speakerLabel: String?,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.ordinal = ordinal
            self.role = role
            self.text = text
            self.source = source
            self.isInterrupted = isInterrupted
            self.speakerLabel = speakerLabel
            self.createdAt = createdAt
        }
    }

    /// 一次「换音色」：从第几句起、换成了谁。
    ///
    /// 界面靠它给**每一行**标出当时的音色——换过之后前面那些行仍是旧音色，
    /// 这也是稿上那一屏要讲清的事（「第 13 句起：音色：温柔讲解」）。
    public struct VoiceChange: Sendable, Equatable {
        public var atOrdinal: Int
        public var voiceID: String
        public var name: String?

        public init(atOrdinal: Int, voiceID: String, name: String? = nil) {
            self.atOrdinal = atOrdinal
            self.voiceID = voiceID
            self.name = name
        }
    }

    public enum ServiceReadiness: Sendable {
        case ready(profile: String?)
        case notReady(String)
    }

    // MARK: 状态

    public private(set) var phase: Phase = .idle
    public private(set) var blocked: BlockReason?
    /// 本场的对话流（内存镜像；权威在库里）。
    public private(set) var turns: [Turn] = []
    /// 正在识别的那一句（未定稿，只进内存）。
    public private(set) var partialText: String?
    /// `partialText` 槽位的**归属 item**。
    ///
    /// 一条连接上可以有多个并发 item（服务端 rollover commit），
    /// 客户端 `RealtimeEventState` 也按最多 128 个 item 追踪。槽位只绑定
    /// 一个 item：迟到的事件不许覆盖或清掉当前正在显示的那一句。
    /// 与 `partialText` 同生共死——非 nil 时 `partialText` 必然非 nil。
    private var partialItemID: String?
    /// 正在生成的那一句助手回复（流式累加）。
    public private(set) var streamingReply: String?
    public private(set) var level: Double = 0
    public private(set) var sessionID: String?
    public private(set) var lastFailure: String?
    /// 本场用的人设（**开始那一刻定死**）。
    public private(set) var persona: Persona?
    public private(set) var voiceID: String?
    /// 本场**开始那一刻**的音色。`voiceID` 会随「换音色」往前走，所以两者要分开：
    /// 回看某一行的徽标时，得知道它是第几句、以及那句之前最后一次换成了谁。
    public private(set) var startVoiceID: String?
    /// 本场换音色的变更点（内存镜像；权威在库里 `session_change`，回看读那一份）。
    public private(set) var voiceChanges: [VoiceChange] = []
    public private(set) var mode: AssistantMode = .duplex
    /// 本场用的大模型（库里也记这一份，用于复现）。
    public private(set) var llmModel: String?

    #if DEBUG
    /// 离屏渲染工装（`/tmp` 里的 `NSHostingView`）用的**只写展示状态**夹具。
    ///
    /// 「对话中」这一屏真机验收要"解锁 + 麦克风 + 服务 + 大模型"四样同时在手，
    /// 在此之前版面（状态带、对话流、正在识别的那半句、被打断的那一句、受阻卡）
    /// 只能靠渲染真实视图来看。口径与 `CaptionSession.applyRenderFixture` 一致：
    /// 只在 Debug 构建里存在，不碰存储、网络与设备，也不改变任何产线行为。
    func applyRenderFixture(
        phase: Phase,
        blocked: BlockReason? = nil,
        turns: [Turn] = [],
        partialText: String? = nil,
        streamingReply: String? = nil,
        level: Double = 0,
        sessionID: String? = nil,
        lastFailure: String? = nil,
        persona: Persona? = nil,
        voiceID: String? = nil,
        startVoiceID: String? = nil,
        voiceChanges: [VoiceChange] = [],
        mode: AssistantMode = .duplex,
        llmModel: String? = nil
    ) {
        self.phase = phase
        self.blocked = blocked
        self.turns = turns
        self.partialText = partialText
        self.streamingReply = streamingReply
        self.level = level
        self.sessionID = sessionID
        self.lastFailure = lastFailure
        self.persona = persona
        self.voiceID = voiceID
        self.startVoiceID = startVoiceID ?? voiceID
        self.voiceChanges = voiceChanges
        self.mode = mode
        self.llmModel = llmModel
    }
    #endif

    // MARK: 挂载点（由 App 注入）

    /// Optional `/readyz` diagnostic; the effective capability binding is the start gate.
    public var serviceReadiness: (@MainActor () async -> ServiceReadiness)?
    /// 助手默认使用一台同时负责采集与播放的引擎，让系统 voice processing 能看到
    /// near-end capture 与 far-end render。旧的 `AudioChunkSource` 注入仍保留：外部
    /// 测试替身或历史调用方若返回普通 source，就继续走下面的兼容播放器。
    public var audioSourceFactory: @MainActor () -> AudioChunkSource = { AudioEngineSession() }
    public var preferences: (@MainActor () -> SessionPreferences)?
    /// 取全局密钥。模块专用密钥由下面的 provider 按作用域读取。
    public var apiKeyProvider: @MainActor () -> String? = { LLMKeychain.load() }
    public var moduleAPIKeyProvider: @MainActor (LLMModule) -> String? = {
        LLMKeychain.load(scope: .module($0))
    }
    /// 音色被拒时的可用内置声音列表（给可读结论用，§9 第 14 行）。
    public var availableVoices: @MainActor () -> [String] = { [] }
    /// App composition root resolves ASR + selected-voice TTS pins from one
    /// effective-capability snapshot before the microphone is opened.
    public var realtimeCapabilityBindingProvider:
        (@MainActor (String?) async -> RealtimeCapabilityBinding?)?

    private let coordinator: SessionCoordinator
    private let dependencies: AssistantSessionDependencies
    private var provider: any AssistantLLM { dependencies.llm }
    private let port: Int
    private let serviceKey: String?

    private var source: AudioChunkSource?
    private var audioSession: (any AssistantAudioSession)?
    private var client: (any AssistantRealtimeClient)?
    private var activeRealtimeBinding: RealtimeCapabilityBinding?
    private var pump: Task<Void, Never>?
    private var playback: (any AssistantPlaybackChannel)?
    private var sessionStartedAt: Date?
    private var currentOrdinal = 0
    private var committedItemIDs: Set<String> = []
    /// itemID -> 这一句**第一个非空证据**被本机收到的时刻（D09）。
    ///
    /// 这是本地观测时间，不是声学开口时间：wire 上没有 sample span，
    /// 精确的 `t_start/t_end` 一律写 NULL（见 `commitUserTurn`）。
    private var itemObservedAt: [String: Date] = [:]
    /// 连接级时钟锚点：`envelope.receivedAt` 是 `ContinuousClock.Instant`，
    /// 要变成墙上时间得有一对锚。重连换新锚，于是旧连接的 itemID 不会串到新会话。
    private var connectionClockAnchor: ContinuousClock.Instant = ContinuousClock().now
    private var connectionDateAnchor: Date = Date()
    private var isStoppingIntentionally = false
    /// 会话级生命周期令牌（D02）。**每次开始或结束都推进一次**。
    /// 启动流程里每个 `await` 之后都要校验它：不匹配说明这一轮已经被
    /// 结束或被新的一轮顶替，此时只能收掉自己的私有资源，不得发布到 `self`。
    private var startToken = 0
    /// 连接级令牌（D03）：每次建连/重连推进一次。下行事件按它门禁，
    /// 旧连接晚到的事件不许改动当前会话。
    private var connectionToken = 0
    /// 历史回合（**只追加、从不重写**，见 §5.5 的前缀结构）。
    private var history: [LLMMessage] = []
    /// 本场已经确认并生效的记忆（开始时读一次，会话内不变）。
    private var memories: [String] = []
    /// 半双工门闩：它说话的时候不上行音频（§14.5）。
    private var isMutedForPlayback = false
    /// 正在跑的这一轮回复（D08）。`nil` 表示此刻没有助手回复在生成或待收尾。
    /// 它的 `id` 就是库里那一行的 id，也是界面 `Turn.id`——全程不变。
    private var currentReply: AssistantReplyState?
    /// 这一场是**纯文字**对话：没有麦克风、没有语音连接、没有设备租约（D07）。
    /// 麦克风被拒或别的功能占着设备时，打字依然要能问出答案。
    private var isTextOnlyConversation = false
    /// 助手这一场结束时封存的记录 id。界面靠它跳回看，纯文字与语音共用同一个结果，
    /// 免得两条路径各跳一次。
    public private(set) var lastFinalizedSessionID: String?
    /// 刚刚收尾的那一轮。用来处理"正文已完整定稿、但朗读还没放完就按了停止"：
    /// 这时候没有正在跑的回复，只有已落库的那一行还要补一个打断标记。
    private var lastFinalizedReply: AssistantReplyState?
    /// 服务端是否在生成 TTS（用来区分"在思考"与"在说话"）。
    private var isSpeaking = false
    /// 单轮增量 TTS 的状态机（`speechrail.tts.start/append_text/finish_text`）。
    /// 首轮回复与"重播"都走同一条增量路径，没有第二套逐句队列。
    private var ttsStream: AssistantTTSStreamCoordinator?
    /// 当前 Responses 流的所有权。停止/插话会取消任务并递增代际，旧流即使
    /// 上游不及时响应，也不能继续把 delta、TTS 或落库写回当前会话。
    private var replyTask: Task<Void, Never>?
    private var replyGeneration = 0
    /// 重连的 single-flight 句柄。第二次重试与结束都要能让旧重试失效（S2 第 10 条）。
    private var retryTask: Task<Void, Never>?
    /// 用户按了「静音麦克风」：不再上行音频，但会话、连接、记录都留着。
    /// 它与「结束对话」是两件事——前者只是暂时不说，后者交出占用（§6.1 的状态带尾部两个动作）。
    public private(set) var isMuted = false

    // MARK: 界面投影（D04）
    //
    // 以前 View 用一个 `phase.isLive` 推导所有入口，于是"静音"被表达成
    // `phase = .paused`，而 `paused` 同时又是"语音中断"。结果是：静音之后界面
    // 不再 active、结束按钮消失、断线时又被判定成"本来就没在跑"而跳过清理。
    // 这里把三件事拆成三个明确投影，View 不再自己拼。

    /// 这一场对话还活着（有记录、设备在手、没在收尾）。
    /// 静音**不影响**它：麦克风还在会话手里，只是不上行。
    public var hasActiveConversation: Bool {
        switch phase {
        case .preparing, .listening, .thinking, .speaking, .paused: true
        default: false
        }
    }

    /// 「结束对话」可用：这一场确实占着设备或记录。
    public var canEndConversation: Bool {
        hasActiveConversation && phase != .ending
    }

    /// 「重试语音」可用：这一场还在，只是语音通道掉了。
    public var canRetryVoice: Bool {
        hasActiveConversation && (blocked != nil || phase == .paused)
    }

    /// 此刻正在采集/思考/说话。**不含"这一场还在但语音掉了"**——
    /// 界面要靠它区分"正在跑"与"对话中（已中断）"，不能都当成"未开始"。
    public var isActivelyRunning: Bool {
        switch phase {
        case .preparing, .listening, .thinking, .speaking: true
        default: false
        }
    }

    /// 状态条上那句给用户看的话。静音是**用户自己选的**，不是故障；
    /// 纯文字对话也不该显示成"正在聆听"——那时根本没有在听。
    public var statusTitle: String {
        if isTextOnlyConversation && hasActiveConversation { return "文字对话" }
        return isMuted && hasActiveConversation ? "麦克风已静音" : phase.title
    }

    /// 能不能朗读。纯文字对话没有语音通道，「重播」要禁用并说明怎么开启，
    /// 不能偷偷去拿设备。
    public var canReplaySpeech: Bool { ttsStream != nil }

    public init(
        coordinator: SessionCoordinator,
        port: Int = 8201,
        apiKey: String? = nil,
        dependencies: AssistantSessionDependencies = AssistantSessionDependencies()
    ) {
        self.coordinator = coordinator
        self.port = port
        self.serviceKey = apiKey
        self.dependencies = dependencies
    }

    // MARK: - 入口

    /// 从页面主按钮开始。人设与音色在这里定（§6.1 的"未开始"态）。
    public func start(persona: Persona, voiceID: String?, mode: AssistantMode) async {
        self.persona = persona
        self.voiceID = voiceID
        // 开始那一刻的音色要单独留一份：`voiceID` 会随「换音色」往前走，
        // 而"这一句是谁说的"要按变更点回推（稿：第 13 句起才是新音色）。
        self.startVoiceID = voiceID
        self.voiceChanges = []
        self.mode = mode
        blocked = nil
        lastFailure = nil
        await coordinator.requestStart(.assistant)
    }

    /// 协调器的 `starter`：真的开始采集与连接。
    public func beginCapture() async throws {
        phase = .preparing
        blocked = nil
        do {
            try await startPipeline()
        } catch Superseded.start {
            // 已经被结束或被新一轮顶替：不写受阻结论，也不抢 `phase`——
            // 新一轮（如果存在）会自己发布状态。
            return
        } catch {
            let reason = Self.blockReason(for: error)
            blocked = reason
            resetToIdleKeepingTurns()
            throw Blocked(reason)
        }
    }

    /// 换音色：**下一句生效**，并落一条 `session_change`（§14.4 的实现约束 2）。
    ///
    /// 被拒时这一句仍用旧音色说，给可读原因与可用内置声音列表（§9 第 14 行）。
    public func changeVoice(to voice: String, name: String? = nil) async {
        let previous = voiceID
        guard let client else { return }
        do {
            let binding = await realtimeCapabilityBindingProvider?(voice)
            if realtimeCapabilityBindingProvider != nil,
               binding?.includesSpeech != true
            {
                throw Blocked(.serviceNotReady("无法确认这个音色的实时朗读版本，请刷新服务信息后重试。"))
            }
            let canonicalVoiceID = binding?.canonicalVoiceID ?? voice
            try await client.updateVoice(
                canonicalVoiceID,
                expectedVoiceRevision: binding?.voiceRevision,
                expectedTTSRevision: binding?.ttsModelRevision
            )
            voiceID = canonicalVoiceID
            if let binding {
                activeRealtimeBinding = binding
            }
            try? await coordinator.noteVoiceChange(
                atOrdinal: currentOrdinal + 1,
                // 名字一起存：库里那一列是 `id|name`，音色改名或删除之后
                // 这一行仍然说得清当时是谁（`SessionStore.noteVoiceChange` 的注解）。
                voice: VoiceSnapshot(id: canonicalVoiceID, name: name)
            )
            voiceChanges.append(
                VoiceChange(atOrdinal: currentOrdinal + 1, voiceID: canonicalVoiceID, name: name)
            )
            lastFailure = nil
        } catch {
            voiceID = previous
            let presets = availableVoices().prefix(4).joined(separator: "、")
            lastFailure = "这个音色现在用不了：\(error.localizedDescription)"
                + (presets.isEmpty ? "" : "可以先用：\(presets)")
        }
    }

    /// 会话内改人设：**拒绝，并给出口**（§14.4 的实现约束 1）。
    public var personaLock: String {
        "这一轮的角色已经定了，中途换会让它把开头重读一遍（第一句会明显变慢，之后每轮都慢）。"
            + "想换就新开一轮；这一轮的记录会留着。"
    }

    /// 打字发送的结果。`.rejected` 带用户读得懂的原因，界面据此**保留草稿**——
    /// 用户已经打出来的字不能因为一次失败就被吞掉（D07）。
    public enum TextSendResult: Equatable, Sendable {
        case accepted
        case rejected(String)
    }

    /// 确保有一条**纯文字**助手记录，没有就建一条（D07）。
    ///
    /// 纯文字对话不需要麦克风、语音服务或设备租约。这里走
    /// `SessionCoordinator.createSession` 这条**不碰设备占用**的 Store 门面：
    /// 既不抢 `activeSessionID`，也不会打断正在占用设备的会议。
    private func ensureTextConversation() async throws -> String {
        if let sessionID { return sessionID }
        let startedAt = Date()
        let configuration: LLMConfiguration? = preferences?().resolvedLLMConfiguration(
            for: .assistant,
            globalAPIKey: apiKeyProvider(),
            moduleAPIKey: moduleAPIKeyProvider(.assistant)
        ).configuration
        let record = try await coordinator.createSession(
            SessionDraft(
                kind: .assistant,
                // 纯文字这一场没有真正跑起来的引擎档位，别编一个。
                engineProfile: "unknown",
                audioSource: .microphone,
                diarization: .off,
                llmEndpoint: configuration?.normalizedBaseURL,
                llmModel: configuration?.model,
                persona: persona.map { PersonaSnapshot(id: $0.id, title: $0.title) },
                startedAt: startedAt
            )
        )
        prepareConversationContext(startedAt: startedAt)
        sessionID = record.id
        isTextOnlyConversation = true
        blocked = nil
        phase = .listening
        return record.id
    }

    /// 打字提问：同一条编排，**不朗读回复**（§6.1 第一条）。
    @discardableResult
    public func ask(typed text: String) async -> TextSendResult {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return .rejected("先写下要问的内容。") }
        guard blocked == nil || blocked?.allowsTyping == true else {
            return .rejected(lastFailure ?? "现在还不能发送。")
        }
        let sessionID: String
        do {
            sessionID = try await ensureTextConversation()
        } catch {
            lastFailure = "文字对话没能开始：\(error.localizedDescription)"
            return .rejected(lastFailure ?? "文字对话没能开始。")
        }
        guard let startedAt = sessionStartedAt else {
            return .rejected("这一场还没准备好，请稍后再试。")
        }
        do {
            let ordinal = try await coordinator.appendLine(
                LineDraft(
                    sessionID: sessionID,
                    role: .user,
                    text: question,
                    source: .keyboard,
                    tStart: max(0, Date().timeIntervalSince(startedAt))
                )
            )
            currentOrdinal = ordinal
            turns.append(
                Turn(
                    id: UUID().uuidString,
                    ordinal: ordinal,
                    role: .user,
                    text: question,
                    source: .keyboard,
                    isInterrupted: false,
                    speakerLabel: nil,
                    createdAt: Date()
                )
            )
            history.append(LLMMessage(role: .user, text: question))
        } catch {
            lastFailure = error.localizedDescription
            return .rejected(lastFailure ?? "没能把这条问题记下来。")
        }
        beginReply(spoken: false)
        return .accepted
    }

    /// 重播某一句话（打字提问的回复也能听——「不朗读」不等于「不能听」）。
    public func replay(turn: Turn) async {
        guard turn.role == .assistant else { return }
        guard let stream = ttsStream, !stream.isActive else { return }
        isSpeaking = true
        phase = .speaking
        // 重播与首次朗读同一条口径：过一遍清洗，否则漏出来的标记会被念第二遍。
        let utterance = VoicePrompt.spokenText(from: turn.text)
        do {
            try await stream.begin(
                generation: replyGeneration,
                requestID: "tts_req_\(UUID().uuidString.lowercased())"
            )
        } catch {
            isSpeaking = false
            phase = .listening
            lastFailure = error.localizedDescription
            return
        }
        stream.offer(utterance.isEmpty ? turn.text : utterance)
        await stream.finishInput()
    }

    /// 静音 / 取消静音。**不结束会话**：麦克风还在会话手里，只是不上行。
    public func toggleMute() {
        isMuted.toggle()
    }

    /// 关掉界面上的失败提示（用户点了「知道了」）。
    ///
    /// `lastFailure` 与 `blocked` 是两件事：`blocked` 是硬受阻卡，带重试出口与
    /// 占用语义，不在这里动。打字发送失败也不走它——那是 View 侧自己的
    /// `sendFailure`（`AssistantView.send()`）。
    public func clearFailure() {
        lastFailure = nil
    }

    /// 主动停止当前助手的朗读或思考（打断当前回答），但不结束会话。
    /// 用户按 ESC 或点击「停止朗读」时调用，清空播放队列与下行生成，保留上下文。
    public func stopSpeaking() async {
        guard phase == .speaking || phase == .thinking || isSpeaking || replyTask != nil else { return }
        // 两种情况要分开（D08 第 5 条）：
        // - 还在生成/已经定稿但没落库 → 走统一收尾，正文与打断标记一起写；
        // - 正文早已完整定稿、只是朗读没放完 → 同一行只补一个打断标记。
        let remoteIdleConfirmed: Bool
        if let reply = currentReply {
            remoteIdleConfirmed = await interruptCurrentReply()
            await finalizeReply(.interrupted, reply: reply)
        } else {
            remoteIdleConfirmed = await interruptCurrentReply()
            await markLastReplyInterruptedAfterPlaybackCut()
        }
        isSpeaking = false
        streamingReply = nil
        isMutedForPlayback = false
        // 服务端没确认这一轮已经结束，就不能把这条连接当成"空出来了"继续用。
        if remoteIdleConfirmed {
            phase = .listening
        } else {
            await handleUnconfirmedRemoteIdle()
        }
    }

    /// 打断一次正在生成/朗读的回答（ESC、「停止朗读」与 barge-in 共用这条路）。
    ///
    /// 顺序按目标架构 §5：**先 invalidate epoch、清空本地队列 → await 停播屏障 → 再取消**。
    /// LLM 侧的"取消"只是本地断开这一轮生成（没有网络往返），因此与后面的 TTS 网络取消
    /// 天然并行；真正必须排序的是"停播先于网络取消"——增量路径由协调器保证，
    /// 非增量路径在这里显式等播放层停完。后端取消超时也不把旧音放回来。
    /// - Returns: 服务端是否已确认这一轮终止。`false` 表示取消命令发出去了，
    ///   但在有界时间内没等到匹配 requestID 的终态——这条连接的 TTS 归属未知。
    @discardableResult
    private func interruptCurrentReply() async -> Bool {
        // ① 本地先作废：LLM 不再产出。TTS 这一代的作废与排队预算清空在 cancel() 内部完成。
        invalidateReply()
        // ② 停播屏障 → ③ 取消。
        if let stream = ttsStream, stream.isActive {
            return await stream.cancel()
        } else {
            await stopPlaybackLayer()
            if let client { try? await client.cancelTTS() }
            return true
        }
    }

    /// 服务端没确认上一轮已经结束：这条连接上"还有没有在跑的朗读"是未知的，
    /// 在它上面开下一轮会让两个 `request_id` 并存。
    /// 所以关掉它、记一次中断，让用户走「重试语音」重建连接——
    /// 而不是靠 sleep 或者自动重发正文把竞态盖过去（方案 S4 第 12 条）。
    private func handleUnconfirmedRemoteIdle(
        message: String = "没能确认上一轮朗读已经结束，已断开连接。请重试语音。"
    ) async {
        ttsStream?.invalidate()
        ttsStream = nil
        if let client { await client.close() }
        client = nil
        if let audioSession {
            audioSession.stop()
            self.audioSession = nil
        } else {
            source?.stop()
        }
        source = nil
        pump?.cancel()
        pump = nil
        level = 0
        blocked = .streamFailed(message)
        phase = .paused
        if coordinator.occupancy?.kind == .assistant {
            _ = await coordinator.markInterruption(.serviceLost, atOrdinal: currentOrdinal)
        }
    }

    /// 直接让播放层停下（没有增量协调器时的屏障）。
    private func stopPlaybackLayer() async {
        if let audioSession {
            await audioSession.stopPlayback()
        } else if let playback {
            await playback.stop()
        }
    }

    // MARK: - 生命周期

    private func beginStartToken() -> Int {
        startToken &+= 1
        return startToken
    }

    /// 新会话：初始化会话上下文 + 建档 + 开语音通道。
    private func startPipeline() async throws {
        let token = beginStartToken()
        let transport = try await openVoiceTransport(token: token)
        try requireLive(token)
        prepareConversationContext(startedAt: transport.startedAt)
        try await createConversationRecord(token: token, transport: transport)
        phase = .listening
        startPump(
            stream: transport.stream,
            client: transport.client,
            connection: transport.connection
        )
    }

    /// 重连：**只换设备、连接与能力 binding**。
    ///
    /// 记录、turns/history、ordinal、起始时间、人设、记忆与音色变更一律不动
    /// （S2 第 8 条）；本轮 LLM 配置沿用已选快照，配置变化要求新会话。
    private func reconnectPipeline() async throws {
        let token = beginStartToken()
        let transport = try await openVoiceTransport(token: token)
        try requireLive(token)
        // 设备与新连接确实 ready 之后才闭合中断；失败时 interruption 仍然开着，可再重试。
        await coordinator.resumeAfterInterruption()
        phase = .listening
        startPump(
            stream: transport.stream,
            client: transport.client,
            connection: transport.connection
        )
    }

    /// 语音通道：能力 binding → 设备 → 连接 → 播放。
    /// 全部在**局部作用域**里建好；令牌仍然有效才发布到 `self`（S2 第 3 条）。
    private func openVoiceTransport(token: Int) async throws -> VoiceTransport {
        let binding = await realtimeCapabilityBindingProvider?(voiceID)
        try requireLive(token)
        if realtimeCapabilityBindingProvider != nil,
           binding?.includesSpeech != true
        {
            throw Blocked(.serviceNotReady("当前服务未确认语音识别和所选音色的实时朗读能力。"))
        }
        guard let preferences = preferences?() else { throw Blocked(.llmNotConfigured) }
        let resolved = preferences.resolvedLLMConfiguration(
            for: .assistant,
            globalAPIKey: apiKeyProvider(),
            moduleAPIKey: moduleAPIKeyProvider(.assistant)
        )
        guard resolved.configuration.isConfigured, !resolved.configuration.embedsCredential else {
            throw Blocked(.llmNotConfigured)
        }
        llmModel = resolved.configuration.model
        let configuration = resolved.configuration
        let key = resolved.apiKey
        // 大模型先探一次：它连不上时**不开会话、不取设备**（§9 第 15–16 行）。
        let result = await provider.check(
            configuration: configuration,
            apiKey: key,
            operation: .responses,
            allowThinkingControlFallback: false
        )
        try requireLive(token)
        guard result.isReady else {
            throw Blocked(.llmUnreachable("\(result.title)。\(result.detail)"))
        }

        var profile = "unknown"
        if let serviceReadiness {
            switch await serviceReadiness() {
            case .notReady:
                // `/readyz` is diagnostic only. The capability binding above
                // gates entry; the Realtime handshake reports transport failure.
                break
            case .ready(let reported):
                profile = reported ?? "unknown"
            }
        }
        try requireLive(token)

        // —— 以下到 `publish` 之间，设备、连接、播放都只存在于**局部作用域**。
        // 只有令牌仍然有效时才写进 `self`；失效路径只收掉自己那一份。
        let source = audioSourceFactory()
        let audioSession = source as? any AssistantAudioSession
        audioSession?.configure(mode: mode)
        let stream: AsyncStream<AudioChunk>
        do {
            stream = try await source.start()
        } catch {
            source.stop()
            throw Blocked(Self.blockReason(for: error))
        }
        do {
            try requireLive(token)
        } catch {
            source.stop()
            throw error
        }

        // 一条连接同时承载 ASR 与 caller-owned TTS（§5.5）；LLM、历史和句子队列
        // 都留在本地，服务端只接收增量 TTS 的 `speechrail.tts.*` 子集。
        let client = dependencies.makeRealtimeClient(
            AssistantRealtimeClientConfiguration(
                port: port,
                silenceDurationMilliseconds: RealtimeVADProfile.assistant(mode).silenceDurationMilliseconds,
                voice: binding?.canonicalVoiceID ?? voiceID,
                apiKey: serviceKey,
                expectedASRRevision: binding?.asrModelRevision,
                expectedTTSRevision: binding?.ttsModelRevision,
                expectedVoiceRevision: binding?.voiceRevision
            )
        )
        do {
            try await client.connect()
        } catch {
            source.stop()
            throw Blocked(.serviceNotReady(error.localizedDescription))
        }
        let connection = connectionToken &+ 1
        self.connectionToken = connection
        // 每条连接换一对时钟锚点（D09）：`receivedAt` 是单调时钟的 instant，
        // 跨连接没有可比性。旧连接的 item 观测时刻一并清掉，
        // 免得重连之后同一个 itemID 沿用上一条连接的时间。
        connectionClockAnchor = ContinuousClock().now
        connectionDateAnchor = Date()
        itemObservedAt.removeAll()
        // itemID 是**连接内**的去重键：重连之后服务端会从头编号，
        // 沿用上一条连接的集合会把新的一句话当成重复而丢掉。
        committedItemIDs.removeAll()
        do {
            try requireLive(token)
        } catch {
            // 晚到的连接：只关掉它自己，不碰当前会话的设备与状态。
            source.stop()
            await client.close()
            throw error
        }

        // 增量 TTS 的协调器先建好：播放层的"真播完"回调要直接挂到它上面。
        let tts = makeTTSStreamCoordinator(client: client)

        let playbackDrained: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            guard self.startToken == token else { return }
            // 增量模式：排空可能只是**欠载**（服务端还在生成），整轮结束由协调器判。
            if let stream = self.ttsStream, stream.isActive || stream.isAwaitingPlayback {
                return
            }
            self.isSpeaking = false
            if self.phase == .speaking { self.phase = .listening }
            self.isMutedForPlayback = false
        }
        if let audioSession {
            audioSession.onPlaybackDrained = playbackDrained
            audioSession.onPlaybackBufferRendered = { [weak tts] epoch, frames in
                tts?.notePlaybackCompleted(samples: frames, epoch: epoch)
            }
            audioSession.onFailure = { [weak self] message in
                guard let self else { return }
                // 旧设备的迟到通知不许动新一轮的账本。
                guard self.startToken == token else { return }
                self.ttsStream?.notePlaybackFailure(message)
                self.lastFailure = message
            }
            // D05：设备重建丢掉了这一轮还没播完的缓冲。旧 epoch 的 rendered
            // 回调被代次过滤掉了，永远不会回来——所以账本必须在这里归零，
            // 而且要明确告诉用户"这次朗读停了"，不能伪装成播完了。
            audioSession.onPlaybackInvalidated = { [weak self] invalidation in
                guard let self else { return }
                // 结束或重连之后到达的旧设备通知只清理它自己那一份。
                guard self.startToken == token else { return }
                self.ttsStream?.invalidate()
                self.isSpeaking = false
                self.isMutedForPlayback = false
                if let reply = self.currentReply {
                    self.invalidateReply()
                    await self.finalizeReply(.interrupted, reply: reply)
                } else {
                    await self.markLastReplyInterruptedAfterPlaybackCut()
                }
                if invalidation.recovered {
                    self.lastFailure = "音频设备已切换，本次朗读已停止。"
                    if self.phase == .speaking || self.phase == .thinking {
                        self.phase = .listening
                    }
                } else {
                    // 恢复失败：这一场已经没法继续语音了。停止采集与连接，
                    // 记一次可重试的中断，文字输入与「重试语音」都留着。
                    await self.handleUnconfirmedRemoteIdle(
                        message: "音频设备切换后无法恢复：\(invalidation.message ?? "未知原因")"
                    )
                }
            }
        } else {
            let player = dependencies.makePlaybackChannel()
            do {
                try await player.start()
            } catch {
                source.stop()
                await client.close()
                throw Blocked(.serviceNotReady("播放通道没起来：\(error.localizedDescription)"))
            }
            player.onDrained = playbackDrained
            player.onBufferRendered = { [weak tts] epoch, frames in
                tts?.notePlaybackCompleted(samples: frames, epoch: epoch)
            }
            do {
                try requireLive(token)
            } catch {
                source.stop()
                await player.stop()
                await client.close()
                throw error
            }
            playback = player
        }
        self.source = source
        self.audioSession = audioSession
        self.client = client
        self.ttsStream = tts
        activeRealtimeBinding = binding
        return VoiceTransport(
            stream: stream,
            client: client,
            profile: profile,
            configuration: configuration,
            startedAt: Date(),
            connection: connection
        )
    }

    /// 一次启动/重连里"语音通道"那部分的产物。
    private struct VoiceTransport {
        var stream: AsyncStream<AudioChunk>
        var client: any AssistantRealtimeClient
        var profile: String
        var configuration: LLMConfiguration
        var startedAt: Date
        var connection: Int
    }

    /// **只在新会话开始时执行一次**的人设、记忆、历史与序号初始化。
    /// 重连不调用它：那些是会话级状态，中断续接必须原样保留（S2 第 8 条）。
    private func prepareConversationContext(startedAt: Date) {
        sessionStartedAt = startedAt
        invalidateReply()
        turns = []
        history = []
        partialText = nil
        partialItemID = nil
        streamingReply = nil
        committedItemIDs = []
        currentOrdinal = 0
        isStoppingIntentionally = false
        // 新会话默认可上行；同一场重连不动它（D04）。
        isMuted = false
    }

    /// 建档：放在语音准备成功且令牌有效之后（S2 第 7 条）。
    ///
    /// 建档期间被取消也可能产生记录：预分配 record ID 跟踪该创建；
    /// 如果确实落库，只按该 ID 封存，不删除，也不把它挂到新会话。
    private func createConversationRecord(token: Int, transport: VoiceTransport) async throws {
        let source = self.source
        let audioSession = self.audioSession
        let client = transport.client
        let startedAt = transport.startedAt
        let configuration = transport.configuration
        memories = ((try? await coordinator.memories(activeOnly: true)) ?? []).map(\.body)
        do {
            try requireLive(token)
        } catch {
            if let source { await tearDownPrivate(source: source, audioSession: audioSession, client: client) }
            throw error
        }

        // 建档放在语音准备成功之后（S2 第 7 条）。建档期间被取消也可能留下记录：
        // 那就只按这个 ID 封存，不删除，也不把它挂到新会话上。
        let recordID: String
        do {
            let record = try await coordinator.createSession(
                SessionDraft(
                    kind: .assistant,
                    engineProfile: transport.profile,
                    audioSource: .microphone,
                    diarization: .off,
                    llmEndpoint: configuration.normalizedBaseURL,
                    llmModel: configuration.model,
                    persona: persona.map { PersonaSnapshot(id: $0.id, title: $0.title) },
                    voice: voiceID.map { VoiceSnapshot(id: $0) },
                    startedAt: startedAt
                )
            )
            recordID = record.id
        } catch {
            if let source { await tearDownPrivate(source: source, audioSession: audioSession, client: client) }
            self.source = nil
            self.audioSession = nil
            self.client = nil
            self.ttsStream = nil
            throw Blocked(.storeUnavailable(error.localizedDescription))
        }
        guard token == startToken else {
            // 记录已经落库：按它自己的 ID 封存，不删除、不挂到新会话。
            await coordinator.sealSession(id: recordID, reason: .user)
            if let source { await tearDownPrivate(source: source, audioSession: audioSession, client: client) }
            self.source = nil
            self.audioSession = nil
            self.client = nil
            self.ttsStream = nil
            throw Superseded.start
        }
        sessionID = recordID
        isTextOnlyConversation = false
        coordinator.sessionDidStartRecording(id: recordID)
    }

    /// 启动流程内部用：令牌已经变了就抛 `Superseded.start`。
    /// 它**不是**受阻——界面不该给"麦克风被占用"这类结论，只该安静收掉自己那一份。
    private func requireLive(_ token: Int) throws {
        guard token == startToken else { throw Superseded.start }
    }

    /// 收掉启动流程**私有**的那一份资源。已经发布到 `self` 的由调用方另行清理。
    private func tearDownPrivate(
        source: (any AudioChunkSource)?,
        audioSession: (any AssistantAudioSession)?,
        client: any AssistantRealtimeClient
    ) async {
        if let audioSession {
            audioSession.stop()
        } else {
            source?.stop()
        }
        await client.close()
    }

    /// 协调器的 `stopper`：把最后半句交出去、关连接、释放设备。
    public func stopCapture() async {
        guard phase != .ending else { return }
        phase = .ending
        // **先作废令牌，再做任何 await**：这样任何还在飞的启动 await
        // 都会在返回后看见自己过期，只能收掉自己的私有资源（D02）。
        startToken &+= 1
        connectionToken &+= 1
        retryTask?.cancel()
        retryTask = nil
        isStoppingIntentionally = true
        // 结束对话也是一次回复收尾：正在生成的那一轮先把已知正文存下来并标成打断，
        // 再去关连接。否则最后半句会随着连接一起消失（D06 / D08）。
        if let reply = currentReply {
            await stopPlaybackLayer()
            if let client { try? await client.cancelTTS() }
            invalidateReply()
            await finalizeReply(.interrupted, reply: reply)
        }
        invalidateReply()
        ttsStream?.invalidate()
        if let audioSession {
            audioSession.stop()
            self.audioSession = nil
        } else {
            source?.stop()
            if let playback {
                await playback.stop()
                self.playback = nil
            }
        }
        source = nil
        if let client {
            do {
                try await client.drainAndClear(timeout: .seconds(8))
            } catch {
                // The session can still be closed locally, but it must not
                // claim that the final remote item completed.
                lastFailure = error.localizedDescription
            }
            await client.close()
        }
        pump?.cancel()
        pump = nil
        client = nil
        // 纯文字这一场没有设备租约，但也得有终态：按它自己的 sessionID 封存，
        // 不能走 `coordinator.finalize`（那会停掉别的功能正在用的设备，D07 / §4.2）。
        if isTextOnlyConversation, let recordID = sessionID {
            await coordinator.sealSession(id: recordID, reason: .user)
        }
        lastFinalizedSessionID = isTextOnlyConversation ? sessionID : lastFinalizedSessionID
        resetToIdleKeepingTurns()
    }

    private func resetToIdleKeepingTurns() {
        invalidateReply()
        phase = .idle
        level = 0
        partialText = nil
        partialItemID = nil
        streamingReply = nil
        // 场次都结束了，两轮回复的身份也一并作废：下一次开始会重新分配。
        currentReply = nil
        lastFinalizedReply = nil
        isTextOnlyConversation = false
        itemObservedAt.removeAll()
        sessionStartedAt = nil
        sessionID = nil
        isMutedForPlayback = false
        isSpeaking = false
        ttsStream?.invalidate()
        ttsStream = nil
    }

    private func invalidateReply() {
        replyGeneration &+= 1
        replyTask?.cancel()
        replyTask = nil
    }

    // MARK: - 采集 → 上行

    private func startPump(
        stream: AsyncStream<AudioChunk>,
        client: any AssistantRealtimeClient,
        connection: Int
    ) {
        pump?.cancel()
        pump = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    for await chunk in stream {
                        guard let self else { return }
                        await self.upload(chunk, to: client)
                    }
                }
                group.addTask { [weak self] in
                    let events = await client.events()
                    for await envelope in events {
                        guard let self else { return }
                        await self.handle(envelope, from: connection)
                    }
                }
                await group.waitForAll()
            }
        }
    }

    private func upload(_ chunk: AudioChunk, to client: any AssistantRealtimeClient) async {
        guard !isStoppingIntentionally else { return }
        level = chunk.level
        // 用户按了静音：电平照显（麦克风仍归这次会话），但一个字节都不上行。
        if isMuted { return }
        // 半双工（一问一答）：它说话的时候闭麦。门闩在本地，不依赖服务端。
        if isMutedForPlayback { return }
        do {
            try await client.append(chunk.pcm)
        } catch {
            lastFailure = error.localizedDescription
        }
    }

    // MARK: - 下行

    /// 记下"这一句第一次有非空证据"的时间，之后的修订不改它（D09 第 3 条）。
    ///
    /// 锚点把单调的 `receivedAt` 换算成墙上时间，所以同一条连接上的多条 item
    /// 仍然保持真实的先后顺序；墙钟被改动也影响不到它。
    private func observedAt(forItem itemID: String?, receivedAt: ContinuousClock.Instant) -> Date {
        let wall = connectionDateAnchor.addingTimeInterval(
            durationSeconds(receivedAt - connectionClockAnchor)
        )
        guard let itemID, !itemID.isEmpty else { return wall }
        if let existing = itemObservedAt[itemID] { return existing }
        itemObservedAt[itemID] = wall
        return wall
    }

    /// 这个 item 能不能动 `partialText` 这个**单槽位**。
    ///
    /// 槽位为空时先到者绑定；绑定之后只认同一个 item。空 itemID 是异常形状
    /// （`RealtimeASRClient` 的 `invalid_hypothesis` 就是空串），认不出身份
    /// 就返回 false——只报告失败，不去动当前正在显示的那一句。
    private func ownsPartial(_ itemID: String) -> Bool {
        guard !itemID.isEmpty else { return false }
        return partialItemID == nil || partialItemID == itemID
    }

    /// 清空"正在识别的那一句"这个槽位（正文与归属必须一起清）。
    private func clearPartialSlot() {
        partialText = nil
        partialItemID = nil
    }

    private func durationSeconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    private func handle(
        _ envelope: RealtimeEventEnvelope<RealtimeASRClient.Event>,
        from connection: Int
    ) async {
        // 连接代次门禁（D03）：重连之后旧连接晚到的事件一律丢弃，
        // 不许把上一条连接的识别结果、播放账本或终态写进新会话。
        guard connection == connectionToken else { return }
        switch envelope.payload {
        case .ready, .configured, .attribution, .alignmentFailed, .diarizationDegraded,
             .diarizationFinished, .auxiliaryIncomplete:
            break
        case .partial(let itemID, let delta):
            guard !delta.isEmpty else { return }
            _ = observedAt(forItem: itemID, receivedAt: envelope.receivedAt)
            await noteSpeechEvidence()
            // 别的 item 的增量不进来：它是**那一句**的证据，不是当前槽位的。
            guard ownsPartial(itemID) else { return }
            partialItemID = itemID
            partialText = (partialText ?? "") + delta
        case .partialSnapshot(let itemID, _, let text, _):
            if !text.isEmpty {
                _ = observedAt(forItem: itemID, receivedAt: envelope.receivedAt)
            }
            await noteSpeechEvidence()
            guard ownsPartial(itemID) else { return }
            // hypothesis 是**可改写全文**，必须整段替换，不能追加（契约 §5.1）。
            // 空快照是"这一句现在没有可展示的正文"：清掉可见文字，并把归属一起
            // 放开——槽位空着的时候，下一个 item 才能接上，不会被这一句占住。
            partialItemID = text.isEmpty ? nil : itemID
            partialText = text.isEmpty ? nil : text
        case .completed(let itemID, let transcript):
            // final-only 的 item 到这里才有第一个证据，用它自己的接收时刻。
            let observed = observedAt(forItem: itemID, receivedAt: envelope.receivedAt)
            await commitUserTurn(itemID: itemID, transcript: transcript, observedAt: observed)
        case .failed(let itemID, let code, let message):
            // 空 itemID 认不出身份（例如 `invalid_hypothesis`），
            // 只报告失败，不去动别人的可见文字。
            if ownsPartial(itemID) {
                partialText = nil
                partialItemID = nil
            }
            lastFailure = "\(code)：\(message)"
        case .ttsStarted(let requestID, let taskID, let limits):
            _ = ttsStream?.handleStarted(
                requestID: requestID,
                taskID: taskID,
                limits: limits
            )
        case .ttsTextAccepted(let requestID, _, let appendSequence, let totalCodepoints):
            _ = ttsStream?.handleTextAccepted(
                requestID: requestID,
                appendSequence: appendSequence,
                totalCodepoints: totalCodepoints
            )
        case .ttsAudio(let requestID, _, let pcm):
            isSpeaking = true
            phase = .speaking
            // 半双工：从这一刻起闭麦（一问一答的口径）。
            isMutedForPlayback = !mode.allowsBargeIn
            if let stream = ttsStream, stream.isActive {
                await stream.handleAudio(requestID: requestID, pcm: pcm)
            }
        case .ttsEnded(let requestID, _, let status, let code, let message):
            // 终态**无条件**转给协调器，不在这里按 `isActive` 过滤。
            // 打断之后那一轮已经被 `invalidate()` 作废，`isActive` 是 false；
            // 在这一层挡掉的话，远端空闲屏障就永远等不到解除的那条终态
            // （方案 S4 第 12 条）。活动/已作废的区分由协调器自己判断。
            await ttsStream?.handleTerminal(requestID: requestID, status: status)
            if status == "failed" {
                lastFailure = [code, message].compactMap { $0 }.joined(separator: "：")
            }
            if status == "cancelled" {
                // 记录"这一轮没听完"；是否落成 `interrupted` 由统一收尾决定。
                if let reply = currentReply, reply.generation == replyGeneration {
                    currentReply?.termination = .interrupted
                }
            }
        case .serverError(let code, let message, let requestID):
            if let stream = ttsStream, stream.isActive {
                await stream.handleServerError(requestID: requestID, code: code, message: message)
            }
            lastFailure = Self.readableError(code: code, message: message)
        case .closed(let code):
            await handleUnexpectedClose(code: code)
        }
    }

    /// 当前 wire 没有服务端 VAD 事件（`speech_started` 已移除，契约 §5.1），
    /// 所以 barge-in 完全由客户端决定：**允许插话时，第一次收到非空识别结果
    /// 就是"用户开始说话"**。半双工模式下播放期本来就不上行，自然不会触发。
    private func noteSpeechEvidence() async {
        guard mode.allowsBargeIn, isSpeaking || replyTask != nil else {
            return
        }
        // 插话和 ESC 走同一条路：同一个回复收尾（D08），正文与打断标记一起写。
        let remoteIdleConfirmed: Bool
        if let reply = currentReply {
            remoteIdleConfirmed = await interruptCurrentReply()
            await finalizeReply(.interrupted, reply: reply)
        } else {
            remoteIdleConfirmed = await interruptCurrentReply()
            await markLastReplyInterruptedAfterPlaybackCut()
        }
        isSpeaking = false
        if remoteIdleConfirmed {
            phase = .listening
        } else {
            await handleUnconfirmedRemoteIdle()
        }
    }

    /// 服务端给回空 final、而这一轮**确实说过话**：把已经显示出来的那半句留住。
    ///
    /// 它以 `status: .partial` 落库，因此在记录库句数与导出里不算一句正式的话
    /// （`lines(includePartial: false)` 与 `listSessions` 的口径不变），
    /// 但用户能看见自己说过什么，不会遇到"字突然没了、什么都没发生"。
    ///
    /// 刻意**不进 LLM / TTS**：`speechrail.transcription.hypothesis` 是可改写的
    /// 全文，不是权威文本。拿它去问模型等于把未确认内容当事实，而且用户无法
    /// 分清哪句是真的。要让用户知道的是"这句没定稿"，不是让它自己往下走。
    private func keepUnfinalizedUtterance(
        itemID: String,
        partial: String?,
        observedAt observed: Date
    ) async {
        // 没说话时的空 final 是正常路径（`clear` 之后的那一次 commit），
        // 不该凭空造出一句"没能识别完整"。
        guard let partial else { return }
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let sessionID = sessionID else { return }
        if !itemID.isEmpty {
            guard !committedItemIDs.contains(itemID) else { return }
            committedItemIDs.insert(itemID)
        }
        do {
            // ordinal 取 appendLine 的返回值，不自行 +1：库里的自增序号才是权威，
            // 自行推算会与它错位，影响首句标题判定与音色 atOrdinal 回推。
            let ordinal = try await coordinator.appendLine(
                LineDraft(
                    sessionID: sessionID,
                    role: .user,
                    text: trimmed,
                    source: .microphone,
                    // 和定稿路径同一口径：wire 上没有 sample span，
                    // 精确的声学起止存 NULL（D09）。
                    tStart: nil,
                    tEnd: nil,
                    status: .partial,
                    isInterrupted: true,
                    timingQuality: .unavailable,
                    createdAt: observed
                )
            )
            currentOrdinal = ordinal
            turns.append(
                Turn(
                    id: UUID().uuidString,
                    ordinal: ordinal,
                    role: .user,
                    text: trimmed,
                    source: .microphone,
                    isInterrupted: true,
                    speakerLabel: nil,
                    createdAt: observed
                )
            )
            lastFailure = "这一句没能识别完整，请再说一次。"
        } catch {
            // 写失败就如实说写失败，不留"界面有、库里没有"的行，
            // 也不让 committedItemIDs 把它记成已经提交过。
            if !itemID.isEmpty { committedItemIDs.remove(itemID) }
            lastFailure = error.localizedDescription
        }
    }

    /// 用户说完一句：落库 → 调大模型 → 逐句合成。
    private func commitUserTurn(
        itemID: String,
        transcript: String,
        observedAt observed: Date
    ) async {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { if !itemID.isEmpty { itemObservedAt.removeValue(forKey: itemID) } }
        // 先把"槽位上是不是它"和"槽位上是什么"取到手，再清：
        // 空 final 的保留分支要用这份正文，不能在判断之前就把它抹掉。
        let ownsSlot = ownsPartial(itemID)
        let visible = ownsSlot ? partialText : nil
        if ownsSlot { clearPartialSlot() }
        // 空 final 是契约允许的正常事件（`clear` 之后的那一次 commit）。
        // 但"用户确实说过话、服务端却没能定稿"不是正常路径：这句话已经显示在
        // 界面上了，先清 `partialText` 再无声 `return` 会让它连同用户的话一起消失，
        // 不落库、不问模型、不报错。保留它，并明确告诉用户没定稿。
        guard !text.isEmpty else {
            await keepUnfinalizedUtterance(
                itemID: itemID,
                partial: visible,
                observedAt: observed
            )
            return
        }
        guard let sessionID, let startedAt = sessionStartedAt else { return }
        if !itemID.isEmpty {
            guard !committedItemIDs.contains(itemID) else { return }
            committedItemIDs.insert(itemID)
        }
        var appendedOrdinal = 0
        do {
            let ordinal = try await coordinator.appendLine(
                LineDraft(
                    sessionID: sessionID,
                    role: .user,
                    text: text,
                    source: .microphone,
                    // D09：wire 上没有 sample span，精确的声学起止**存 NULL**，
                    // 不再拿会话起点冒充。`timingQuality = .unavailable` 让界面
                    // 能识别"这段时间不可用"，而不是显示一个假的 00:00。
                    tStart: nil,
                    tEnd: nil,
                    timingQuality: .unavailable,
                    createdAt: observed
                )
            )
            currentOrdinal = ordinal
            appendedOrdinal = ordinal
            turns.append(
                Turn(
                    id: UUID().uuidString,
                    ordinal: ordinal,
                    role: .user,
                    text: text,
                    source: .microphone,
                    isInterrupted: false,
                    speakerLabel: nil,
                    // 实时对话流与回看必须显示**同一个**时间（D09）：
                    // 都是"第一个非空证据被本机收到的那一刻"。
                    createdAt: observed
                )
            )
            history.append(LLMMessage(role: .user, text: text))
        } catch {
            committedItemIDs.remove(itemID)
            lastFailure = error.localizedDescription
            return
        }
        // 第一句顶上来当这一条记录的名字：记录库里一排「未命名」时，用户认不出哪条是哪条，
        // 而"继续这一轮 / 导出 / 重命名"都要先认得它（`SessionTitleSuggestion` 里有取法）。
        // 只在第一句上做，用户之后改名就是终局——那一列只由人来写。
        if appendedOrdinal == 1, let name = SessionTitleSuggestion.suggest(from: text) {
            try? await coordinator.setSessionTitle(id: sessionID, title: name)
        }
        // 这一句成功定稿了：上一次留下的软提示（比如"没能识别完整"）已经过期。
        clearFailure()
        beginReply(spoken: true)
    }

    /// 把增量 TTS 的发送、播放与终态接到现有连接 / 播放层上。
    /// 协调器不认识 WebSocket 与 AVAudioEngine 的细节，这里只做注入。
    private func makeTTSStreamCoordinator(
        client: any AssistantRealtimeClient
    ) -> AssistantTTSStreamCoordinator {
        let tts = AssistantTTSStreamCoordinator()
        tts.sendStart = { requestID in
            try await client.startTTSStream(requestID: requestID, speed: nil)
        }
        tts.sendAppend = { sequence, text in
            try await client.appendTTSText(text, sequence: sequence)
        }
        tts.sendFinish = { lastSequence in
            try await client.finishTTSText(lastSequence: lastSequence)
        }
        tts.sendCancel = { try await client.cancelTTS() }
        tts.enqueuePlayback = { [weak self] pcm, epoch in
            guard let self else { return false }
            if let audioSession = self.audioSession {
                return await audioSession.enqueuePlayback(pcm, epoch: epoch)
            }
            if let playback = self.playback {
                return await playback.enqueue(pcm, epoch: epoch)
            }
            return false
        }
        tts.stopPlayback = { [weak self] in
            guard let self else { return }
            if let audioSession = self.audioSession {
                await audioSession.stopPlayback()
            } else if let playback = self.playback {
                await playback.stop()
            }
        }
        // 朗读前的清洗留在原处：屏幕、历史、SQLite 仍然只认**原始** LLM 文本。
        tts.cleanForSpeech = { VoicePrompt.spokenText(from: $0) }
        tts.onOutcome = { [weak self] _, outcome in
            guard let self else { return }
            switch outcome {
            case .completed:
                break
            case .cancelled:
                // 朗读被打断**不等于**这一轮已经收尾：正文可能已经完整生成并定稿，
                // 这里只是把"没听完"记在同一个 `AssistantReplyState` 上，
                // 由 `finalizeReply` 决定要不要把 `interrupted` 推成 true。
                // generation 对不上（重播上一句、或者新一轮已经接替）就不动。
                if let reply = self.currentReply, reply.generation == self.replyGeneration {
                    self.currentReply?.termination = .interrupted
                }
            case .failed(let message):
                self.lastFailure = message
            }
            self.isSpeaking = false
            if self.phase == .speaking { self.phase = .listening }
            self.isMutedForPlayback = false
        }
        return tts
    }

    private func beginReply(spoken: Bool) {
        replyGeneration &+= 1
        let generation = replyGeneration
        replyTask?.cancel()
        guard let sessionID else { return }
        currentReply = AssistantReplyState(
            sessionID: sessionID,
            generation: generation,
            source: spoken ? .microphone : .keyboard,
            startedAt: Date()
        )
        replyTask = Task { [weak self] in
            await self?.runReply(spoken: spoken, generation: generation)
        }
    }

    /// 第一段非空正文到达时**建行**，之后只累计内存（方案 S4 第 2 条）。
    ///
    /// 不在每个 token 上写库：那既没必要，也会把 WAL 写满。崩溃前还没落库的那部分
    /// 本来就不承诺恢复——已经落库的那部分由 `sealAbandonedSessions` 封成
    /// final + interrupted（见 `SessionStore`），用户至少还能看到已经说过的话。
    private func persistReplyPartial(generation: Int) async {
        guard var reply = currentReply,
              reply.generation == generation,
              !reply.isPersisted,
              reply.hasSpeakableText
        else { return }
        do {
            let ordinal = try await coordinator.appendLine(
                LineDraft(
                    sessionID: reply.sessionID,
                    role: .assistant,
                    text: reply.text,
                    source: reply.source,
                    status: .partial
                ),
                id: reply.id
            )
            reply.isPersisted = true
            reply.ordinal = ordinal
            currentReply = reply
        } catch {
            // 建行失败不打断这一轮：正文还在内存里，收尾时会再试一次完整落库。
            lastFailure = "这一句正在生成，但暂时存不下来：\(error.localizedDescription)"
        }
    }

    /// 一轮回复的**唯一收尾入口**（D06 / D08）。
    ///
    /// 正常说完、用户打断、provider 失败、连接断开、结束对话都走这里，
    /// 按 `isFinalized` 幂等：重复调用只生效一次，所以取消路径和正常路径
    /// 不会各插一行，也不会各追加一次 history。
    ///
    /// `snapshot` 是**值类型副本**。跨过 await 之后即使新的一轮已经接管，
    /// 这里写的仍然是调用方按下按钮那一刻的那一轮，不会把旧回复写进新会话。
    private func finalizeReply(
        _ termination: AssistantReplyState.Termination,
        reply snapshot: AssistantReplyState
    ) async {
        var reply = snapshot
        guard !reply.isFinalized else { return }
        reply.isFinalized = true
        reply.termination = termination
        let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isCurrent = currentReply?.id == reply.id
        guard !text.isEmpty else {
            // 纯空白的一轮不留下伪造的正文行。
            if isCurrent { currentReply = nil }
            return
        }

        // 不依赖快照的 isPersisted：快照可能过期（persistReplyPartial 在
        // await 期间完成建行），先试 UPDATE，不存在再退回 INSERT。
        do {
            let ordinal = try await coordinator.finalizeAssistantLine(
                sessionID: reply.sessionID,
                lineID: reply.id,
                text: text,
                interrupted: termination.marksInterrupted
            )
            reply.ordinal = ordinal
            reply.isPersisted = true
        } catch {
            // 行还没建过（快照过期或建行失败过）：退回 INSERT 路径。
            do {
                let ordinal = try await coordinator.appendLine(
                    LineDraft(
                        sessionID: reply.sessionID,
                        role: .assistant,
                        text: text,
                        source: reply.source,
                        status: .final,
                        isInterrupted: termination.marksInterrupted
                    ),
                    id: reply.id
                )
                reply.ordinal = ordinal
                reply.isPersisted = true
            } catch {
                lastFailure = "这一句没能存下来：\(error.localizedDescription)"
            }
        }

        guard isCurrent else { return }
        currentReply = nil
        lastFinalizedReply = reply
        // 被打断的回复把**已经说出口的那部分**交给下一轮，不虚构余文，
        // 也不伪造一条"成功"的空消息。
        history.append(LLMMessage(role: .assistant, text: text))
        streamingReply = nil
        turns.append(
            Turn(
                id: reply.id,
                ordinal: reply.ordinal ?? (currentOrdinal + 1),
                role: .assistant,
                text: text,
                source: reply.source,
                isInterrupted: termination.marksInterrupted,
                speakerLabel: nil,
                createdAt: reply.startedAt
            )
        )
        if let ordinal = reply.ordinal { currentOrdinal = ordinal }
    }

    /// 完整生成、也已经定稿，但朗读还没放完时用户按了停止（D08 第 5 条的后半段）。
    /// 正文已经是完整的，这一行要改的只有"没听完"这一个标记——
    /// `finalizeAssistantLine` 的 SQL 只把 `interrupted` 从 false 推向 true，
    /// 所以重复调用是安全的。
    private func markLastReplyInterruptedAfterPlaybackCut() async {
        guard let reply = lastFinalizedReply, reply.termination == .completed else { return }
        do {
            _ = try await coordinator.finalizeAssistantLine(
                sessionID: reply.sessionID,
                lineID: reply.id,
                text: reply.text.trimmingCharacters(in: .whitespacesAndNewlines),
                interrupted: true
            )
            lastFinalizedReply?.termination = .interrupted
            if let index = turns.indices.last, turns[index].id == reply.id {
                turns[index].isInterrupted = true
            }
        } catch {
            lastFailure = "打断标记没能存下来：\(error.localizedDescription)"
        }
    }

    /// 一次回答：Responses 流式 → 句子切分 → TTS。
    ///
    /// 前缀顺序是硬的（§5.5）：人设 → 记忆 → 历史 → 本轮。**只追加，从不重写**。
    private func runReply(spoken: Bool, generation: Int) async {
        defer {
            if replyGeneration == generation {
                replyTask = nil
            }
        }
        guard generation == replyGeneration,
              let preferences = preferences?()
        else { return }

        let resolved = preferences.resolvedLLMConfiguration(
            for: .assistant,
            globalAPIKey: apiKeyProvider(),
            moduleAPIKey: moduleAPIKeyProvider(.assistant)
        )
        let configuration = resolved.configuration
        let key = resolved.apiKey
        var messages: [LLMMessage] = []
        if let persona {
            messages.append(
                LLMMessage(role: .developer, text: VoicePrompt.styleBlock(persona.body), cacheBreakpoint: true)
            )
        }
        if !memories.isEmpty {
            let block = "以下是用户确认过、可以长期记住的事：\n"
                + memories.map { "- \($0)" }.joined(separator: "\n")
            messages.append(LLMMessage(role: .developer, text: block, cacheBreakpoint: true))
        }
        messages.append(contentsOf: history)

        phase = .thinking
        streamingReply = ""
        var reply = ""
        // 这一轮是否已经开过增量 utterance：`start` 一轮只允许一次。
        var streamStarted = false
        // 开嗓时机与原始空白由它统一决定（D11）：分隔空白不能被丢掉。
        var speechGate = AssistantSpeechStartGate()
        // 服务端明确拒绝增量时，只停朗读，不静默退回逐句 create 队列。
        var streamUnavailable = false
        do {
            try Task.checkCancellation()
            for try await delta in await provider.stream(
                configuration: configuration,
                messages: messages,
                apiKey: key,
                maxOutputTokens: nil,
                instructions: VoicePrompt.instructions
            ) {
                try Task.checkCancellation()
                guard generation == replyGeneration else { return }
                reply += delta
                streamingReply = reply
                // 同一轮只有一个身份：流式正文、库里那一行、界面那一行都挂在它下面（D08）。
                // 这一句的时刻按**开始回答**算，不是按它说完算：生成要几秒，
                // 用结束时刻会让时间码落在那一句之后（稿行右侧那个 `14:02:16`）。
                currentReply?.text = reply
                // 第一次出现非空白正文时按固定 id 建行；之后只 UPDATE，不再 INSERT。
                await persistReplyPartial(generation: generation)
                // 屏幕与落库永远用**原始**文本；朗读那份从同一条流里另走一路。
                guard spoken, !streamUnavailable else { continue }
                guard let stream = ttsStream else { continue }
                switch speechGate.offer(delta) {
                case .buffered:
                    continue
                case .speak(let text):
                    stream.offer(text)
                case .start(let pending):
                    // 第一批有效文本就开轮：不再等整句，更不等整段回复（§8.1）。
                    do {
                        try await stream.begin(
                            generation: generation,
                            requestID: "tts_req_\(UUID().uuidString.lowercased())"
                        )
                    } catch {
                        guard generation == replyGeneration else { return }
                        streamUnavailable = true
                        lastFailure = error.localizedDescription
                        speechGate.disableStarting()
                        continue
                    }
                    streamStarted = true
                    // 开嗓前缓冲的空白与正文一次交出去，再逐段原样 offer。
                    stream.offer(pending)
                }
            }
        } catch is CancellationError {
            // 取消不是失败：谁按下停止，谁负责收尾（`interruptCurrentReply` /
            // `stopCapture`）。这一路只把界面上的流式文本收掉。
            if generation == replyGeneration {
                streamingReply = nil
            }
            return
        } catch {
            guard generation == replyGeneration else { return }
            let message = "这一次没有回答出来：\(error.localizedDescription)"
            // D06：provider 失败必须走**同一个回复收尾**。以前这里只改文案就返回，
            // 于是已经开嗓的 TTS 继续往下播、半句话也永远不落库。
            // 顺序与用户手动打断一致：先停本地播放 → 再取消服务端这一轮 → 再落库归位。
            await stopPlaybackLayer()
            if let client { try? await client.cancelTTS() }
            ttsStream?.invalidate()
            isSpeaking = false
            isMutedForPlayback = false
            lastFailure = message
            phase = .listening
            if let replyState = currentReply, replyState.generation == generation {
                await finalizeReply(.failed(message), reply: replyState)
            }
            return
        }

        guard generation == replyGeneration else { return }
        guard let replyState = currentReply, replyState.generation == generation else { return }
        guard replyState.hasSpeakableText else {
            // 空回复不留下伪造的正文行（D08 第 6 条）。
            streamingReply = nil
            currentReply = nil
            lastFailure = "模型这次没有给出内容。"
            phase = .listening
            return
        }
        if spoken, streamStarted, let stream = ttsStream {
            // 关输入之后仍然继续收音频；这里只保证"没 ACK 的文本不会越过 finish"。
            await stream.finishInput()
        }
        guard generation == replyGeneration, currentReply?.id == replyState.id else { return }
        // 朗读被打断过就按打断收尾，否则按正常完成收尾。两者写的是同一行。
        await finalizeReply(
            replyState.termination == .interrupted ? .interrupted : .completed,
            reply: replyState
        )
        if !spoken { phase = .listening }
    }

    /// 从流式正文里切出"已经可以念"的句子：遇到句末标点就切，**并且要够长**
    /// （太短的片段单独合成会有断句感）。未完的那一段留在缓冲里。
    static func takeSentences(_ buffer: inout String, flush: Bool) -> [String] {
        let terminators: Set<Character> = ["。", "！", "？", "；", "\n", ".", "!", "?", ";"]
        var result: [String] = []
        var current = ""
        for character in buffer {
            current.append(character)
            if terminators.contains(character), current.count >= 6 {
                result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            }
        }
        if flush, !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
            current = ""
        }
        buffer = current
        return result.filter { !$0.isEmpty }
    }

    private func handleUnexpectedClose(code: Int?) async {
        // 断线判定看**连接身份与是否主动停**，不看展示用的 `phase`（D04）。
        // 以前用 `phase.isLive`：静音把 phase 变成 `.paused` 之后，
        // 断线会被判成"本来就没在跑"，于是设备、连接、占用全都留在原地。
        guard !isStoppingIntentionally, client != nil else { return }
        let reason = code.map { "语音服务断开了连接（\($0)）。" } ?? "语音服务断开了连接。"
        // 断线时正在生成的那一轮要**先收尾**：否则它会继续往一条已经关掉的连接上写，
        // 已经说出口的那半句也永远不落库（D06）。
        if let reply = currentReply {
            invalidateReply()
            await finalizeReply(.interrupted, reply: reply)
        }
        // 断线：本地作废这一轮 utterance，不假装它播完了。
        ttsStream?.invalidate()
        if let audioSession {
            audioSession.stop()
            self.audioSession = nil
        } else {
            source?.stop()
            if let playback {
                await playback.stop()
                self.playback = nil
            }
        }
        source = nil
        pump?.cancel()
        pump = nil
        if let client {
            await client.close()
            self.client = nil
        }
        level = 0
        partialText = nil
        partialItemID = nil
        blocked = .streamFailed(reason)
        phase = .paused
        if coordinator.occupancy?.kind == .assistant {
            _ = await coordinator.markInterruption(.serviceLost, atOrdinal: currentOrdinal)
        }
    }

    /// 受阻后的「重试」：占用还在自己手里就续接（新连接 = 新 epoch），否则走守卫。
    public func retry() async {
        // **先作废旧重试的令牌，再取消它**：这样无论谁先恢复，
        // 旧重试下一次校验时一定看见自己过期，不会有"两个重试同时建连"的窗口。
        startToken &+= 1
        retryTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRetry()
        }
        retryTask = task
        await task.value
        // compare-and-clear：只有自己这一轮能清掉句柄。
        if retryTask == task { retryTask = nil }
    }

    private func performRetry() async {
        if coordinator.occupancy?.kind == .assistant {
            if coordinator.phase == .interrupted {
                // 已经封存的记录不允许 retry 把它重新变成 recording。
                guard coordinator.activeSessionID != nil else { return }
            }
            do {
                try await reconnectPipeline()
                blocked = nil
            } catch is CancellationError {
                return
            } catch Superseded.start {
                // 结束或新一轮把它顶替了：保持现状，不写受阻结论。
                return
            } catch {
                blocked = Self.blockReason(for: error)
            }
            return
        }
        await coordinator.requestStart(.assistant)
    }

    // MARK: - 小工具

    /// 服务端错误码 → 用户读得懂的一句。原始码不外泄（§9 的脱敏口径）。
    private static func readableError(code: String, message: String) -> String {
        switch code {
        case "voice_not_found", "voice_not_available":
            "这个音色现在用不了；这一句还是用上一个音色说的。"
        case "backend_busy":
            "语音引擎正被另一个会话占着。"
        default:
            message
        }
    }

    private static func blockReason(for error: Error) -> BlockReason {
        if let blocked = error as? Blocked { return blocked.reason }
        if let failure = error as? MicrophoneCapture.Failure, failure == .permissionDenied {
            return .microphoneDenied
        }
        if let failure = error as? AudioEngineSession.Failure {
            switch failure {
            case .permissionDenied:
                return .microphoneDenied
            case .voiceProcessingUnavailable(let message):
                return .serviceNotReady(
                    "实时对讲的系统回声消除没有在当前音频设备上启用：\(message)"
                        + "请连接支持双向语音处理的耳机，或切换到「一问一答（外放）」。"
                )
            default:
                break
            }
        }
        return .serviceNotReady(error.localizedDescription)
    }

    struct Blocked: Error {
        var reason: BlockReason

        init(_ reason: BlockReason) {
            self.reason = reason
        }
    }

    /// 启动流程被更新的一轮顶替（结束、切功能、或重新开始）。
    /// 它**不是**受阻：不该给"麦克风被占用"这类可读结论，
    /// 也不该把 `phase` 拉回任何活动态——只安静收掉自己那一份资源。
    enum Superseded: Error {
        case start
    }
}

// MARK: - 助手共享音频引擎
//
// `AssistantAudioSession` and `AudioEngineSession` live in
// `AssistantAudioSession.swift`; this file keeps only session orchestration.


// MARK: - TTS 播放
//
// `PCMStreamPlayer` lives in `AssistantAudioPlayback.swift`.
