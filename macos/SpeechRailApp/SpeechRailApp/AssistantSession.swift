import AVFoundation
import Foundation
import Observation

// 语音助手的会话层（`TECHNICAL-DESIGN` §5.5、`SESSIONS-SPEC` §6.1 / §8.1 / §14.4 / §14.5）。
//
// 一条线：**麦克风 → 服务端 ASR → Responses → TTS → 播放**，四种失败各有各的出口。
// 三条只在实现里说得清的取舍：
//
//   1. **人设是锁，不是选择器**（§14.4）。它在开始那一刻写进 developer 消息，会话内只读；
//      要换就新开一轮（`personaLock` 是可读结论 + 一个出口，不是静默忽略）。
//   2. **音色只是声音**。换音色走 `session.update`，下一句生效，并落一条
//      `session_change(kind='voice')`——「第 N 句起」这句话必须有数据支撑。
//   3. **打字提问不朗读回复**（§6.1）：正文落库（`source='keyboard'`），回复仍可点「重播」。
//   4. **契约在顶层 `instructions`，人设只是风格**：语音对话契约走 Responses 的 `instructions`
//      （每轮重发，续轮不继承），人设走 developer 消息并让位给契约；送 TTS 前还有一道文本清洗。
//      三者都收在 `VoicePrompt.swift` 里，单独可测。
//
// 打断的口径来自契约与规格：服务端检测到人声时会自己取消 TTS（Barge-in），
// 客户端要做的只有三件——丢掉还没播的缓冲、留下服务端已经生成的那一句、记 `interrupted`。

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
    public private(set) var mode: AssistantMode = .turnTaking
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
        mode: AssistantMode = .turnTaking,
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
    /// 取密钥。**只有这一处读钥匙串**，密钥不进任何状态、不进日志。
    public var apiKeyProvider: @MainActor () -> String? = { LLMKeychain.load() }
    /// 音色被拒时的可用内置声音列表（给可读结论用，§9 第 14 行）。
    public var availableVoices: @MainActor () -> [String] = { [] }

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
            try await client.updateVoice(voice)
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
        await runReply(spoken: false)
    }

    /// 重播某一句话（打字提问的回复也能听——「不朗读」不等于「不能听」）。
    public func replay(turn: Turn) async {
        guard turn.role == .assistant, let client else { return }
        isSpeaking = true
        phase = .speaking
        // 重播与首次朗读同一条口径：过一遍清洗，否则漏出来的标记会被念第二遍。
        let utterance = VoicePrompt.spokenText(from: turn.text)
        try? await client.speak(utterance.isEmpty ? turn.text : utterance)
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
        guard phase == .speaking || phase == .thinking || isSpeaking else { return }
        currentReplyInterrupted = true
        if let audioSession {
            await audioSession.stopPlayback()
        } else {
            await playback?.stop()
        }
        isSpeaking = false
        if let client { try? await client.cancelResponse() }
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
        guard preferences.isLLMConfigured else { throw Blocked(.llmNotConfigured) }
        llmModel = preferences.llmConfiguration.model
        let configuration = preferences.llmConfiguration
        let key = apiKeyProvider()
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

        // 一条连接同时承载 ASR 与 TTS（§5.5）：TTS 的句子走 `conversation.item.create`
        // + `response.create`，所以两者必须在同一个会话里。
        let client = RealtimeASRClient(
            port: port,
            silenceDurationMilliseconds: 400,
            voice: voiceID,
            apiKey: serviceKey
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

        let playbackDrained: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.isSpeaking = false
            if self.phase == .speaking { self.phase = .listening }
            self.isMutedForPlayback = false
        }
        if let audioSession {
            audioSession.onPlaybackDrained = playbackDrained
            audioSession.onFailure = { [weak self] message in
                guard let self else { return }
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
            playback = player
        }

        let startedAt = Date()
        sessionStartedAt = startedAt
        commitCursor = startedAt
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
            try? await client.commit()
            await waitForFinalTurn()
            await client.close()
        }
        pump?.cancel()
        pump = nil
        client = nil
        resetToIdleKeepingTurns()
    }

    private func resetToIdleKeepingTurns() {
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
    }

    private func waitForFinalTurn() async {
        let ordinalAtCommit = currentOrdinal
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if currentOrdinal > ordinalAtCommit { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
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
                    for await event in events {
                        guard let self else { return }
                        await self.handle(event)
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

    private func handle(_ event: RealtimeASRClient.Event) async {
        switch event {
        case .ready, .configured, .diarizationDone, .attribution, .diarizationDegraded,
             .segment, .speechStopped:
            break
        case .committed:
            let now = Date()
            pendingItem = (start: commitCursor ?? now, end: now)
            commitCursor = now
        case .partial(_, let delta):
            guard !delta.isEmpty else { return }
            partialText = (partialText ?? "") + delta
        case .completed(let itemID, let transcript, _):
            await commitUserTurn(itemID: itemID, transcript: transcript)
        case .failed(_, let code, let message):
            partialText = nil
            lastFailure = "\(code)：\(message)"
        case .speechStarted:
            // 实时对讲：插话就是打断。服务端会原子取消 TTS（契约的 Barge-in），
            // 客户端把还没播的缓冲丢掉，并把这一句标成"被打断"（不是错误）。
            guard mode.allowsBargeIn, isSpeaking else { return }
            currentReplyInterrupted = true
            if let audioSession {
                await audioSession.stopPlayback()
            } else {
                await playback?.stop()
            }
            isSpeaking = false
            phase = .listening
            if let client { try? await client.cancelResponse() }
        case .responseAudio(let pcm):
            isSpeaking = true
            phase = .speaking
            // 半双工：从这一刻起闭麦（一问一答的口径）。
            isMutedForPlayback = !mode.allowsBargeIn
            if let audioSession {
                await audioSession.enqueuePlayback(pcm)
            } else {
                await playback?.enqueue(pcm)
            }
        case .responseDone(let status):
            if status == "cancelled" { currentReplyInterrupted = true }
        case .serverError(let code, let message):
            lastFailure = Self.readableError(code: code, message: message)
        case .closed(let code):
            await handleUnexpectedClose(code: code)
        }
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
        await runReply(spoken: true)
    }

    /// 一次回答：Responses 流式 → 句子切分 → TTS。
    ///
    /// 前缀顺序是硬的（§5.5）：人设 → 记忆 → 历史 → 本轮。**只追加，从不重写**。
    private func runReply(spoken: Bool) async {
        guard let sessionID, let preferences = preferences?() else { return }
        let configuration = preferences.llmConfiguration
        let key = apiKeyProvider()
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
        var buffer = ""
        var reply = ""
        do {
            for try await delta in await provider.stream(
                configuration: configuration,
                messages: messages,
                apiKey: key,
                instructions: VoicePrompt.instructions
            ) {
                reply += delta
                streamingReply = reply
                guard spoken else { continue }
                // 逐句合成：用户不必等整段话写完才听见第一句（§8.1 的首次可听响应）。
                buffer += delta
                for sentence in Self.takeSentences(&buffer, flush: false) {
                    let utterance = VoicePrompt.spokenText(from: sentence)
                    if !utterance.isEmpty { try? await client?.speak(utterance) }
                }
            }
        } catch {
            lastFailure = "这一次没有回答出来：\(error.localizedDescription)"
            streamingReply = nil
            phase = .listening
            return
        }

        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            streamingReply = nil
            lastFailure = "模型这次没有给出内容。"
            phase = .listening
            return
        }
        if spoken {
            for sentence in Self.takeSentences(&buffer, flush: true) {
                let utterance = VoicePrompt.spokenText(from: sentence)
                if !utterance.isEmpty { try? await client?.speak(utterance) }
            }
        }
        streamingReply = nil
        history.append(LLMMessage(role: .assistant, text: trimmed))
        do {
            let ordinal = try await coordinator.appendLine(
                LineDraft(
                    sessionID: sessionID,
                    role: .assistant,
                    text: trimmed,
                    source: spoken ? .microphone : .keyboard,
                    isInterrupted: currentReplyInterrupted
                )
            )
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
        } catch {
            lastFailure = error.localizedDescription
        }
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
        guard !isStoppingIntentionally, phase.isLive else { return }
        let reason = code.map { "语音服务断开了连接（\($0)）。" } ?? "语音服务断开了连接。"
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

/// 助手专用的音频会话接口。普通 `AudioChunkSource` 仍是兼容边界；只有默认源实现这个
/// 扩展接口时，采集和播放才会共享一台 `AVAudioEngine`，从而让系统 AEC 同时看到两路信号。
private protocol AssistantAudioSession: AnyObject, AudioChunkSource {
    func configure(mode: AssistantMode)
    var onPlaybackDrained: (@MainActor () -> Void)? { get set }
    var onFailure: (@MainActor (String) -> Void)? { get set }
    func enqueuePlayback(_ pcm: Data) async
    func stopPlayback() async
}

/// 一台用于语音助手的全双工音频引擎。
///
/// - `.duplex`：在启动前同时给 input/output I/O node 打开系统 voice processing，让
///   macOS 的 AEC/NS/AGC 看到真实的播放参考；输入 tap 只拿处理后的 near-end 音频。
/// - `.turnTaking`：不依赖 AEC，仍共享同一台引擎，但在助手说话时由会话层丢弃上行帧。
/// - 播放停止只停 `AVAudioPlayerNode`，不拆输入引擎；插话后的下一块 TTS 仍能立即播放。
///
/// 音频回调只做系统 converter + 环形缓冲写入；网络、锁等待和 UI 回调都在回调之外。
final class AudioEngineSession: AssistantAudioSession, @unchecked Sendable {
    enum Failure: LocalizedError, Equatable {
        case permissionDenied
        case unsupportedInput
        case converterUnavailable
        case voiceProcessingUnavailable(String)
        case engineFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                "麦克风未授权。"
            case .unsupportedInput:
                "输入设备没有可用的采样率。"
            case .converterUnavailable:
                "这个输入设备的格式转不成 16 kHz 单声道。"
            case .voiceProcessingUnavailable(let message):
                "系统语音处理不可用：\(message)"
            case .engineFailed(let message):
                "共享音频引擎没有开始：\(message)"
            }
        }
    }

    private static let inputSampleRate: Double = 16_000
    private static let playbackSampleRate: Double = 24_000
    private static let chunkDuration: Duration = .milliseconds(100)

    private let queue = DispatchQueue(
        label: "com.speechrail.app.assistant.audio-engine",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private let ring = AssistantAudioRing(capacity: Int(inputSampleRate) * MemoryLayout<Int16>.size)
    private let playbackFormat: AVAudioFormat?

    private var mode: AssistantMode = .turnTaking
    private var stopped = false
    private var started = false
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var drainTask: Task<Void, Never>?

    // 下列引擎对象只在 `queue` 上创建、重建和拆卸；播放入队也串到同一条队列。
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var converter: AVAudioConverter?
    private var configurationObserver: NSObjectProtocol?

    // 播放缓冲的计数与代次由锁保护，避免停止/插话与 completion 同时到来时误报 drained。
    private var playbackGeneration = 0
    private var pendingBuffers = 0
    private var playbackDrainedHandler: (@MainActor () -> Void)?
    private var failureHandler: (@MainActor (String) -> Void)?

    init() {
        playbackFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.playbackSampleRate,
            channels: 1,
            interleaved: true
        )
    }

    var onPlaybackDrained: (@MainActor () -> Void)? {
        get { stateLock.withLock { playbackDrainedHandler } }
        set { stateLock.withLock { playbackDrainedHandler = newValue } }
    }

    var onFailure: (@MainActor (String) -> Void)? {
        get { stateLock.withLock { failureHandler } }
        set { stateLock.withLock { failureHandler = newValue } }
    }

    func configure(mode: AssistantMode) {
        stateLock.withLock {
            guard !started else { return }
            self.mode = mode
        }
    }

    func start() async throws -> AsyncStream<AudioChunk> {
        guard await MicrophoneCapture.requestPermission() else {
            throw Failure.permissionDenied
        }
        let canStart = stateLock.withLock { !stopped && !started }
        guard canStart else {
            throw Failure.engineFailed("一个音频会话实例只能启动一次。")
        }

        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        stateLock.withLock { self.continuation = continuation }
        ring.reset()

        do {
            try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
                queue.async { [weak self] in
                    guard let self else {
                        result.resume(throwing: Failure.engineFailed("音频会话已释放。"))
                        return
                    }
                    do {
                        try self.startEngineOnQueue()
                        self.stateLock.withLock { self.started = true }
                        result.resume()
                    } catch {
                        result.resume(throwing: error)
                    }
                }
            }
        } catch {
            stateLock.withLock { self.continuation = nil }
            continuation.finish()
            throw error
        }

        let canDrain = stateLock.withLock { !stopped && started }
        guard canDrain else {
            continuation.finish()
            throw Failure.engineFailed("音频会话在启动时被取消。")
        }
        startDraining(into: continuation)
        return stream
    }

    func stop() {
        let (continuation, drainTask) = stateLock.withLock {
            stopped = true
            started = false
            playbackGeneration += 1
            pendingBuffers = 0
            let continuation = self.continuation
            let drainTask = self.drainTask
            self.continuation = nil
            self.drainTask = nil
            return (continuation, drainTask)
        }
        continuation?.finish()
        drainTask?.cancel()
        queue.async { [weak self] in
            self?.tearDownEngineOnQueue()
        }
    }

    func enqueuePlayback(_ pcm: Data) async {
        guard !pcm.isEmpty, let playbackFormat else { return }
        let frameCount = pcm.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: playbackFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
              )
        else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        if let destination = buffer.int16ChannelData?[0] {
            pcm.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                destination.update(
                    from: base.assumingMemoryBound(to: Int16.self),
                    count: frameCount
                )
            }
        }

        let reservation: (generation: Int, resetCapture: Bool)? = stateLock.withLock {
            guard !stopped, started else { return nil }
            let resetCapture = !mode.allowsBargeIn && pendingBuffers == 0
            pendingBuffers += 1
            return (playbackGeneration, resetCapture)
        }
        guard let reservation else { return }
        if reservation.resetCapture { ring.reset() }
        let boxedBuffer = AssistantPCMBufferBox(buffer)

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self else {
                    done.resume()
                    return
                }
                let accepted = self.stateLock.withLock {
                    !self.stopped
                        && self.started
                        && reservation.generation == self.playbackGeneration
                }
                guard accepted, let player = self.player else {
                    self.cancelPlaybackReservation(generation: reservation.generation)
                    done.resume()
                    return
                }
                player.scheduleBuffer(boxedBuffer.buffer) { [weak self] in
                    self?.didFinishPlaybackBuffer(generation: reservation.generation)
                }
                if !player.isPlaying { player.play() }
                done.resume()
            }
        }
    }

    func stopPlayback() async {
        let resetCapture = stateLock.withLock {
            playbackGeneration += 1
            pendingBuffers = 0
            return !mode.allowsBargeIn
        }
        if resetCapture { ring.reset() }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                self?.player?.stop()
                self?.player?.reset()
                done.resume()
            }
        }
    }

    private func startDraining(into continuation: AsyncStream<AudioChunk>.Continuation) {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.chunkDuration)
                guard !Task.isCancelled, let self else { return }
                guard self.stateLock.withLock({ !self.stopped && self.started }) else { return }
                if let chunk = self.ring.drain() { continuation.yield(chunk) }
            }
        }
        let cancel = stateLock.withLock { () -> Bool in
            guard !stopped else { return true }
            drainTask = task
            return false
        }
        if cancel { task.cancel() }
    }

    /// 只在串行音频队列上建立图。voice processing 必须在 engine running 之前同时配置在
    /// input/output I/O node；只给 input 开启会丢掉 far-end render 参考，AEC 不完整。
    private func startEngineOnQueue() throws {
        guard !stateLock.withLock({ stopped }) else {
            throw Failure.engineFailed("音频会话已停止。")
        }
        guard let playbackFormat else { throw Failure.converterUnavailable }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let output = engine.outputNode
        let mode = stateLock.withLock { self.mode }

        if mode.allowsBargeIn {
            do {
                try input.setVoiceProcessingEnabled(true)
                try output.setVoiceProcessingEnabled(true)
            } catch {
                throw Failure.voiceProcessingUnavailable(error.localizedDescription)
            }
            guard input.isVoiceProcessingEnabled, output.isVoiceProcessingEnabled else {
                throw Failure.voiceProcessingUnavailable("当前输入/输出节点拒绝启用 voice processing。")
            }
        }

        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw Failure.unsupportedInput }
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.captureFormat) else {
            throw Failure.converterUnavailable
        }

        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        input.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
            guard let self,
                  let converted = MicrophoneCapture.convert(
                    buffer,
                    using: converter,
                    to: Self.captureFormat
                  )
            else { return }
            self.ring.write(converted)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            player.stop()
            player.reset()
            engine.detach(player)
            throw Failure.engineFailed(error.localizedDescription)
        }

        self.engine = engine
        self.player = player
        self.converter = converter
        player.play()
        installConfigurationObserver(for: engine)
    }

    private static let captureFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: inputSampleRate,
        channels: 1,
        interleaved: true
    )!

    private func installConfigurationObserver(for engine: AVAudioEngine) {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in
                self?.rebuildAfterConfigurationChangeOnQueue()
            }
        }
    }

    /// 设备切换会让 AVAudioEngine 停止并重置图；保留同一条 PCM stream，重建 input tap、
    /// converter 和 player。若新路由不支持 duplex，明确回调到会话层，不静默上传坏帧。
    private func rebuildAfterConfigurationChangeOnQueue() {
        guard stateLock.withLock({ !stopped && started }) else { return }
        stateLock.withLock {
            playbackGeneration += 1
            pendingBuffers = 0
        }
        tearDownEngineOnQueue()
        do {
            try startEngineOnQueue()
            stateLock.withLock { started = true }
        } catch {
            let message = error.localizedDescription
            let (continuation, handler) = stateLock.withLock {
                started = false
                pendingBuffers = 0
                let continuation = self.continuation
                self.continuation = nil
                return (continuation, failureHandler)
            }
            continuation?.finish()
            Task { @MainActor in handler?("音频设备切换后无法恢复：\(message)") }
        }
    }

    private func tearDownEngineOnQueue() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            if let player {
                player.stop()
                player.reset()
                engine.detach(player)
            }
            engine.stop()
        }
        engine = nil
        player = nil
        converter = nil
        ring.reset()
    }

    private func cancelPlaybackReservation(generation: Int) {
        stateLock.withLock {
            guard generation == playbackGeneration else { return }
            pendingBuffers = max(0, pendingBuffers - 1)
        }
    }

    private func didFinishPlaybackBuffer(generation: Int) {
        let result: (@MainActor () -> Void)? = stateLock.withLock {
            guard generation == playbackGeneration, !stopped else { return nil }
            pendingBuffers = max(0, pendingBuffers - 1)
            guard pendingBuffers == 0 else { return nil }
            return playbackDrainedHandler
        }
        guard let result else { return }
        if stateLock.withLock({ !mode.allowsBargeIn }) { ring.reset() }
        Task { @MainActor in result() }
    }
}

/// AVFAudio 的 buffer 由旧式 ObjC API 管理；这里只把它从调用任务安全地转交到同一条
/// 音频工作队列，不把它暴露给其它模块或跨线程共享。生命周期由 player 的调度完成回调结束。
private final class AssistantPCMBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

/// 助手共享引擎自己的 1 秒 PCM 环形缓冲。`MicrophoneCapture` 的 ring 是 private，避免
/// 为了复用而扩大其他会话的实现边界；两者都遵守“满了丢最旧，不回放补录”的口径。
private final class AssistantAudioRing: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var storage: [UInt8]
    private var readIndex = 0
    private var writeIndex = 0
    private var count = 0

    init(capacity: Int) {
        self.capacity = capacity
        self.storage = [UInt8](repeating: 0, count: capacity)
    }

    func reset() {
        lock.withLock {
            readIndex = 0
            writeIndex = 0
            count = 0
        }
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let run = min(capacity - writeIndex, raw.count - offset)
                    storage.withUnsafeMutableBytes { destination in
                        destination.baseAddress?.advanced(by: writeIndex)
                            .copyMemory(from: base.advanced(by: offset), byteCount: run)
                    }
                    writeIndex = (writeIndex + run) % capacity
                    offset += run
                    let overflow = count + run - capacity
                    if overflow > 0 {
                        count = capacity
                        readIndex = (readIndex + overflow) % capacity
                    } else {
                        count += run
                    }
                }
            }
        }
    }

    func drain() -> AudioChunk? {
        lock.withLock {
            guard count > 0 else { return nil }
            var bytes = [UInt8]()
            bytes.reserveCapacity(count)
            for _ in 0..<count {
                bytes.append(storage[readIndex])
                readIndex = (readIndex + 1) % capacity
            }
            let data = Data(bytes)
            count = 0
            let level = data.withUnsafeBytes { AudioLevel.peak($0.bindMemory(to: Int16.self)) }
            return AudioChunk(pcm: data, level: level)
        }
    }
}

// MARK: - TTS 播放

/// 24 kHz / 单声道 / PCM16 的流式播放（契约里 TTS 的输出格式）。
///
/// 为什么不用 `AVAudioPlayer`：它要一个完整的文件，而这里的音频是一块块到的；
/// 打断要求"立刻静音"，缓冲队列必须能一次丢掉。所以用 `AVAudioEngine` + `AVAudioPlayerNode`。
///
/// 阻塞式 CoreAudio 调用（`engine.start()`）**不在主线程**上做（§5.13 的实测教训：
/// 最坏 36 秒）。
final class PCMStreamPlayer: @unchecked Sendable {
    enum Failure: LocalizedError {
        case unsupportedFormat
        case engineFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: "这个输出格式没法播放。"
            case .engineFailed(let message): message
            }
        }
    }

    /// 契约：TTS 输出 24 kHz PCM16。
    static let sampleRate: Double = 24_000

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "com.speechrail.app.assistant.player", qos: .userInitiated)
    private var format: AVAudioFormat?
    private let lock = NSLock()
    private var pendingBuffers = 0
    private var stopped = false

    /// 队列播完（真正静音）时回调一次。界面用它把相位从"正在说话"退回"正在聆听"。
    var onDrained: (@MainActor () -> Void)?

    func start() async throws {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Self.sampleRate,
                channels: 1,
                interleaved: true
            )
        else { throw Failure.unsupportedFormat }
        self.format = format
        let engine = self.engine
        let player = self.player
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                engine.prepare()
                do {
                    try engine.start()
                    player.play()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: Failure.engineFailed(error.localizedDescription))
                }
            }
        }
    }

    /// 入队一块音频。空块与停止之后到的块都被丢掉（不假装播了）。
    func enqueue(_ pcm: Data) async {
        guard !pcm.isEmpty else { return }
        let frames = pcm.count / MemoryLayout<Int16>.size
        guard frames > 0, let format else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        if let destination = buffer.int16ChannelData?[0] {
            pcm.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                destination.update(from: base.assumingMemoryBound(to: Int16.self), count: frames)
            }
        }
        let shouldSchedule = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            pendingBuffers += 1
            return true
        }
        guard shouldSchedule else { return }
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            let isLast = self.lock.withLock { () -> Bool in
                self.pendingBuffers = max(0, self.pendingBuffers - 1)
                return self.pendingBuffers == 0
            }
            if isLast {
                Task { @MainActor in self.onDrained?() }
            }
        }
    }

    /// 立刻静音并丢掉还没播的部分（插话打断 / 结束会话）。
    func stop() async {
        lock.withLock {
            pendingBuffers = 0
            stopped = true
        }
        let player = self.player
        let engine = self.engine
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                player.stop()
                player.reset()
                engine.stop()
                continuation.resume()
            }
        }
    }
}
