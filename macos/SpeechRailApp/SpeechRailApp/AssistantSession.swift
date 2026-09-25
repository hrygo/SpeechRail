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
    /// 仅从同一代 capability snapshot 读取当前 voice revision；未知时保持 nil，
    /// 不从 voice 名称或本地时间推断 revision。
    public var realtimeVoiceRevision: @MainActor (String?) -> String? = { _ in nil }
    /// 仅从同一代 capability snapshot 读取 TTS catalog revision；未知时保持 nil，
    /// 让服务按普通协商处理，不从模型名或本地时间推断 revision。
    public var realtimeModelRevision: @MainActor (String?) -> String? = { _ in nil }

    private let coordinator: SessionCoordinator
    private let provider = LLMProvider()
    private let port: Int
    private let serviceKey: String?

    private var source: AudioChunkSource?
    private var audioSession: (any AssistantAudioSession)?
    private var client: RealtimeASRClient?
    private var pump: Task<Void, Never>?
    private var playback: PCMStreamPlayer?
    private var sessionStartedAt: Date?
    private var commitCursor: Date?
    private var pendingItem: (start: Date, end: Date)?
    private var currentOrdinal = 0
    private var committedItemIDs: Set<String> = []
    private var isStoppingIntentionally = false
    /// 历史回合（**只追加、从不重写**，见 §5.5 的前缀结构）。
    private var history: [LLMMessage] = []
    /// 本场已经确认并生效的记忆（开始时读一次，会话内不变）。
    private var memories: [String] = []
    /// 半双工门闩：它说话的时候不上行音频（§14.5）。
    private var isMutedForPlayback = false
    /// 这一句助手的回复被打断过。
    private var currentReplyInterrupted = false
    /// 服务端是否在生成 TTS（用来区分"在思考"与"在说话"）。
    private var isSpeaking = false
    /// 单轮增量 TTS 的状态机（`speechrail.tts.start/append_text/finish_text`）。
    /// 首轮回复与"重播"都走同一条增量路径，没有第二套逐句队列。
    private var ttsStream: AssistantTTSStreamCoordinator?
    /// 当前 Responses 流的所有权。停止/插话会取消任务并递增代际，旧流即使
    /// 上游不及时响应，也不能继续把 delta、TTS 或落库写回当前会话。
    private var replyTask: Task<Void, Never>?
    private var replyGeneration = 0
    /// 用户按了「静音麦克风」：不再上行音频，但会话、连接、记录都留着。
    /// 它与「结束对话」是两件事——前者只是暂时不说，后者交出占用（§6.1 的状态带尾部两个动作）。
    public private(set) var isMuted = false

    public init(coordinator: SessionCoordinator, port: Int = 8201, apiKey: String? = nil) {
        self.coordinator = coordinator
        self.port = port
        self.serviceKey = apiKey
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
        voiceID = voice
        guard let client else { return }
        do {
            try await client.updateVoice(
                voice,
                expectedVoiceRevision: realtimeVoiceRevision(voice)
            )
            try? await coordinator.noteVoiceChange(
                atOrdinal: currentOrdinal + 1,
                // 名字一起存：库里那一列是 `id|name`，音色改名或删除之后
                // 这一行仍然说得清当时是谁（`SessionStore.noteVoiceChange` 的注解）。
                voice: VoiceSnapshot(id: voice, name: name)
            )
            voiceChanges.append(
                VoiceChange(atOrdinal: currentOrdinal + 1, voiceID: voice, name: name)
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

    /// 打字提问：同一条编排，**不朗读回复**（§6.1 第一条）。
    public func ask(typed text: String) async {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        guard blocked == nil || blocked?.allowsTyping == true,
              let sessionID,
              let startedAt = sessionStartedAt
        else { return }
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
            return
        }
        beginReply(spoken: false)
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
        if !isMuted, phase == .paused { phase = .listening }
        if isMuted, phase == .listening { phase = .paused }
    }

    /// 主动停止当前助手的朗读或思考（打断当前回答），但不结束会话。
    /// 用户按 ESC 或点击「停止朗读」时调用，清空播放队列与下行生成，保留上下文。
    public func stopSpeaking() async {
        guard phase == .speaking || phase == .thinking || isSpeaking || replyTask != nil else { return }
        currentReplyInterrupted = true
        invalidateReply()
        if let stream = ttsStream, stream.isActive {
            // 增量路径：一次调用里完成"本地作废 → 停播 → 取消服务端"。
            await stream.cancel()
        } else {
            if let audioSession {
                await audioSession.stopPlayback()
            } else {
                await playback?.stop()
            }
            if let client { try? await client.cancelTTS() }
        }
        isSpeaking = false
        streamingReply = nil
        phase = .listening
        isMutedForPlayback = false
        // 若最后一条是助手且处于生成/朗读中，标记被打断
        if let lastIndex = turns.indices.last, turns[lastIndex].role == .assistant {
            turns[lastIndex].isInterrupted = true
        }
    }

    // MARK: - 生命周期

    private func startPipeline() async throws {
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
        let result = await provider.check(configuration: configuration, apiKey: key)
        guard result.isReady else {
            throw Blocked(.llmUnreachable("\(result.title)。\(result.detail)"))
        }

        var profile = "unknown"
        if let serviceReadiness {
            switch await serviceReadiness() {
            case .notReady(let message):
                throw Blocked(.serviceNotReady(message))
            case .ready(let reported):
                profile = reported ?? "unknown"
            }
        }

        let source = audioSourceFactory()
        let audioSession = source as? any AssistantAudioSession
        audioSession?.configure(mode: mode)
        self.source = source
        self.audioSession = audioSession
        let stream: AsyncStream<AudioChunk>
        do {
            stream = try await source.start()
        } catch {
            source.stop()
            self.source = nil
            self.audioSession = nil
            throw Blocked(Self.blockReason(for: error))
        }

        // 一条连接同时承载 ASR 与 caller-owned TTS（§5.5）；LLM、历史和句子队列
        // 都留在本地，服务端只接收增量 TTS 的 `speechrail.tts.*` 子集。
        let client = RealtimeASRClient(
            port: port,
            silenceDurationMilliseconds: 400,
            voice: voiceID,
            apiKey: serviceKey,
            expectedModelRevision: realtimeModelRevision(voiceID),
            expectedVoiceRevision: realtimeVoiceRevision(voiceID),
            callerTTSEnabled: true
        )
        do {
            try await client.connect()
        } catch {
            source.stop()
            self.source = nil
            self.audioSession = nil
            throw Blocked(.serviceNotReady(error.localizedDescription))
        }
        self.client = client

        // 增量 TTS 的协调器先建好：播放层的"真播完"回调要直接挂到它上面。
        let tts = makeTTSStreamCoordinator(client: client)
        ttsStream = tts

        let playbackDrained: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
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
            audioSession.onPlaybackBufferRendered = { [weak tts] frames in
                tts?.notePlaybackCompleted(samples: frames)
            }
            audioSession.onFailure = { [weak self] message in
                guard let self else { return }
                self.ttsStream?.notePlaybackFailure(message)
                self.lastFailure = message
            }
        } else {
            let player = PCMStreamPlayer()
            do {
                try await player.start()
            } catch {
                await client.close()
                source.stop()
                self.source = nil
                self.audioSession = nil
                self.client = nil
                throw Blocked(.serviceNotReady("播放通道没起来：\(error.localizedDescription)"))
            }
            player.onDrained = playbackDrained
            player.onBufferRendered = { [weak tts] frames in
                tts?.notePlaybackCompleted(samples: frames)
            }
            playback = player
        }

        let startedAt = Date()
        sessionStartedAt = startedAt
        commitCursor = startedAt
        invalidateReply()
        turns = []
        history = []
        partialText = nil
        streamingReply = nil
        committedItemIDs = []
        currentOrdinal = 0
        isStoppingIntentionally = false
        memories = ((try? await coordinator.memories(activeOnly: true)) ?? []).map(\.body)

        do {
            let record = try await coordinator.createSession(
                SessionDraft(
                    kind: .assistant,
                    engineProfile: profile,
                    audioSource: .microphone,
                    diarization: .off,
                    llmEndpoint: configuration.normalizedBaseURL,
                    llmModel: configuration.model,
                    persona: persona.map { PersonaSnapshot(id: $0.id, title: $0.title) },
                    voice: voiceID.map { VoiceSnapshot(id: $0) },
                    startedAt: startedAt
                )
            )
            sessionID = record.id
            coordinator.sessionDidStartRecording(id: record.id)
        } catch {
            if let audioSession {
                audioSession.stop()
            } else if let playback {
                await playback.stop()
                self.playback = nil
                source.stop()
            }
            await client.close()
            self.source = nil
            self.audioSession = nil
            self.client = nil
            throw Blocked(.storeUnavailable(error.localizedDescription))
        }
        phase = .listening
        startPump(stream: stream, client: client)
    }

    /// 协调器的 `stopper`：把最后半句交出去、关连接、释放设备。
    public func stopCapture() async {
        guard phase != .ending else { return }
        phase = .ending
        isStoppingIntentionally = true
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
        resetToIdleKeepingTurns()
    }

    private func resetToIdleKeepingTurns() {
        invalidateReply()
        phase = .idle
        level = 0
        partialText = nil
        streamingReply = nil
        pendingItem = nil
        commitCursor = nil
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

    private func startPump(stream: AsyncStream<AudioChunk>, client: RealtimeASRClient) {
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
                        await self.handle(envelope)
                    }
                }
                await group.waitForAll()
            }
        }
    }

    private func upload(_ chunk: AudioChunk, to client: RealtimeASRClient) async {
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

    private func handle(
        _ envelope: RealtimeEventEnvelope<RealtimeASRClient.Event>
    ) async {
        switch envelope.payload {
        case .ready, .configured, .attribution, .alignmentFailed, .diarizationDegraded:
            break
        case .partial(_, let delta):
            guard !delta.isEmpty else { return }
            await noteSpeechEvidence()
            partialText = (partialText ?? "") + delta
        case .partialSnapshot(_, _, let text):
            await noteSpeechEvidence()
            partialText = text.isEmpty ? nil : text
        case .completed(let itemID, let transcript):
            await commitUserTurn(itemID: itemID, transcript: transcript)
        case .failed(_, let code, let message):
            partialText = nil
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
            if let stream = ttsStream, stream.isActive {
                await stream.handleTerminal(requestID: requestID, status: status)
            }
            if status == "failed" {
                lastFailure = [code, message].compactMap { $0 }.joined(separator: "：")
            }
            if status == "cancelled" {
                currentReplyInterrupted = true
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
        guard mode.allowsBargeIn, isSpeaking || replyTask != nil, !currentReplyInterrupted else {
            return
        }
        currentReplyInterrupted = true
        invalidateReply()
        if let stream = ttsStream, stream.isActive {
            // 增量路径：本地立刻失效 + 停播，再取消服务端（顺序由协调器保证）。
            await stream.cancel()
        } else {
            if let audioSession {
                await audioSession.stopPlayback()
            } else {
                await playback?.stop()
            }
            if let client { try? await client.cancelTTS() }
        }
        isSpeaking = false
        phase = .listening
    }

    /// 用户说完一句：落库 → 调大模型 → 逐句合成。
    private func commitUserTurn(itemID: String, transcript: String) async {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        partialText = nil
        defer { pendingItem = nil }
        guard !text.isEmpty, let sessionID, let startedAt = sessionStartedAt else { return }
        if !itemID.isEmpty {
            guard !committedItemIDs.contains(itemID) else { return }
            committedItemIDs.insert(itemID)
        }
        let window = pendingItem ?? (start: commitCursor ?? startedAt, end: Date())
        var appendedOrdinal = 0
        do {
            let ordinal = try await coordinator.appendLine(
                LineDraft(
                    sessionID: sessionID,
                    role: .user,
                    text: text,
                    source: .microphone,
                    tStart: window.start.timeIntervalSince(startedAt),
                    tEnd: window.end.timeIntervalSince(startedAt)
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
                    // 说这一句是**从**什么时候开始的：时间码给的是开口那一刻，
                    // 与库里 `t_start` 同一个来源。
                    createdAt: window.start
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
        beginReply(spoken: true)
    }

    /// 把增量 TTS 的发送、播放与终态接到现有连接 / 播放层上。
    /// 协调器不认识 WebSocket 与 AVAudioEngine 的细节，这里只做注入。
    private func makeTTSStreamCoordinator(client: RealtimeASRClient) -> AssistantTTSStreamCoordinator {
        let tts = AssistantTTSStreamCoordinator()
        tts.sendStart = { requestID in
            try await client.startTTSStream(requestID: requestID)
        }
        tts.sendAppend = { sequence, text in
            try await client.appendTTSText(text, sequence: sequence)
        }
        tts.sendFinish = { lastSequence in
            try await client.finishTTSText(lastSequence: lastSequence)
        }
        tts.sendCancel = { try await client.cancelTTS() }
        tts.enqueuePlayback = { [weak self] pcm in
            guard let self else { return false }
            if let audioSession = self.audioSession {
                return await audioSession.enqueuePlayback(pcm)
            }
            if let playback = self.playback {
                return await playback.enqueue(pcm)
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
                self.currentReplyInterrupted = true
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
        replyTask = Task { [weak self] in
            await self?.runReply(spoken: spoken, generation: generation)
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
              let sessionID,
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
        currentReplyInterrupted = false
        // 这一句回复的时刻按**开始回答**算，不是按它说完算：生成要几秒，
        // 用结束时刻会让时间码落在那一句之后（稿行右侧那个 `14:02:16`）。
        let replyStartedAt = Date()
        var reply = ""
        // 这一轮是否已经开过增量 utterance：`start` 一轮只允许一次。
        var streamStarted = false
        // 服务端明确拒绝增量时，只停朗读，不静默退回逐句 create 队列。
        var streamUnavailable = false
        do {
            try Task.checkCancellation()
            for try await delta in await provider.stream(
                configuration: configuration,
                messages: messages,
                apiKey: key,
                instructions: VoicePrompt.instructions
            ) {
                try Task.checkCancellation()
                guard generation == replyGeneration else { return }
                reply += delta
                streamingReply = reply
                // 屏幕与落库永远用**原始**文本；朗读那份从同一条流里另走一路。
                guard spoken, !streamUnavailable else { continue }
                guard !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                guard let stream = ttsStream else { continue }
                if !streamStarted {
                    // 第一批有效文本就开轮：不再等整句，更不等整段回复（§8.1）。
                    streamStarted = true
                    do {
                        try await stream.begin(
                            generation: generation,
                            requestID: "tts_req_\(UUID().uuidString.lowercased())"
                        )
                    } catch {
                        guard generation == replyGeneration else { return }
                        streamUnavailable = true
                        lastFailure = error.localizedDescription
                        continue
                    }
                }
                stream.offer(delta)
            }
        } catch is CancellationError {
            if generation == replyGeneration {
                streamingReply = nil
            }
            return
        } catch {
            guard generation == replyGeneration else { return }
            lastFailure = "这一次没有回答出来：\(error.localizedDescription)"
            streamingReply = nil
            phase = .listening
            return
        }

        guard generation == replyGeneration else { return }
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            streamingReply = nil
            lastFailure = "模型这次没有给出内容。"
            phase = .listening
            return
        }
        if spoken, streamStarted, let stream = ttsStream {
            // 关输入之后仍然继续收音频；这里只保证"没 ACK 的文本不会越过 finish"。
            await stream.finishInput()
        }
        guard generation == replyGeneration else { return }
        streamingReply = nil
        history.append(LLMMessage(role: .assistant, text: trimmed))
        do {
            try Task.checkCancellation()
            guard generation == replyGeneration else { return }
            let ordinal = try await coordinator.appendLine(
                LineDraft(
                    sessionID: sessionID,
                    role: .assistant,
                    text: trimmed,
                    source: spoken ? .microphone : .keyboard,
                    isInterrupted: currentReplyInterrupted
                )
            )
            try Task.checkCancellation()
            guard generation == replyGeneration else { return }
            currentOrdinal = ordinal
            turns.append(
                Turn(
                    id: UUID().uuidString,
                    ordinal: ordinal,
                    role: .assistant,
                    text: trimmed,
                    source: spoken ? .microphone : .keyboard,
                    isInterrupted: currentReplyInterrupted,
                    speakerLabel: nil,
                    createdAt: replyStartedAt
                )
            )
        } catch is CancellationError {
            return
        } catch {
            guard generation == replyGeneration else { return }
            lastFailure = error.localizedDescription
        }
        if !spoken, generation == replyGeneration { phase = .listening }
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
        guard !isStoppingIntentionally, phase.isLive else { return }
        let reason = code.map { "语音服务断开了连接（\($0)）。" } ?? "语音服务断开了连接。"
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
        blocked = .streamFailed(reason)
        phase = .paused
        if coordinator.occupancy?.kind == .assistant {
            _ = await coordinator.markInterruption(.serviceLost, atOrdinal: currentOrdinal)
        }
    }

    /// 受阻后的「重试」：占用还在自己手里就续接（新连接 = 新 epoch），否则走守卫。
    public func retry() async {
        if coordinator.occupancy?.kind == .assistant {
            if coordinator.phase == .interrupted {
                await coordinator.resumeAfterInterruption()
            }
            do {
                try await startPipeline()
                blocked = nil
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
}

// MARK: - 助手共享音频引擎
//
// `AssistantAudioSession` and `AudioEngineSession` live in
// `AssistantAudioSession.swift`; this file keeps only session orchestration.


// MARK: - TTS 播放
//
// `PCMStreamPlayer` lives in `AssistantAudioPlayback.swift`.
