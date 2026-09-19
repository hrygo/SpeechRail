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
    public private(set) var mode: AssistantMode = .turnTaking
    /// 本场用的大模型（库里也记这一份，用于复现）。
    public private(set) var llmModel: String?

    // MARK: 挂载点（由 App 注入）

    public var serviceReadiness: (@MainActor () async -> ServiceReadiness)?
    public var audioSourceFactory: @MainActor () -> AudioChunkSource = { MicrophoneCapture() }
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
    public func changeVoice(to voice: String) async {
        guard let client else { return }
        let previous = voiceID
        do {
            try await client.updateVoice(voice)
            voiceID = voice
            try? await coordinator.noteVoiceChange(
                atOrdinal: currentOrdinal + 1,
                voice: VoiceSnapshot(id: voice)
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
                    speakerLabel: nil
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
        try? await client.speak(turn.text)
    }

    /// 静音 / 取消静音。**不结束会话**：麦克风还在会话手里，只是不上行。
    public func toggleMute() {
        isMuted.toggle()
        if !isMuted, phase == .paused { phase = .listening }
        if isMuted, phase == .listening { phase = .paused }
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
        self.source = source
        let stream: AsyncStream<AudioChunk>
        do {
            stream = try await source.start()
        } catch {
            self.source = nil
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
            throw Blocked(.serviceNotReady(error.localizedDescription))
        }
        self.client = client

        let player = PCMStreamPlayer()
        do {
            try await player.start()
        } catch {
            await client.close()
            source.stop()
            self.source = nil
            self.client = nil
            throw Blocked(.serviceNotReady("播放通道没起来：\(error.localizedDescription)"))
        }
        player.onDrained = { [weak self] in
            guard let self else { return }
            self.isSpeaking = false
            if self.phase == .speaking { self.phase = .listening }
            self.isMutedForPlayback = false
        }
        playback = player

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
            await player.stop()
            await client.close()
            source.stop()
            self.source = nil
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
        source?.stop()
        source = nil
        if let playback {
            await playback.stop()
            self.playback = nil
        }
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
            await playback?.stop()
            isSpeaking = false
            phase = .listening
            if let client { try? await client.cancelResponse() }
        case .responseAudio(let pcm):
            isSpeaking = true
            phase = .speaking
            // 半双工：从这一刻起闭麦（一问一答的口径）。
            isMutedForPlayback = !mode.allowsBargeIn
            await playback?.enqueue(pcm)
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
            turns.append(
                Turn(
                    id: UUID().uuidString,
                    ordinal: ordinal,
                    role: .user,
                    text: text,
                    source: .microphone,
                    isInterrupted: false,
                    speakerLabel: nil
                )
            )
            history.append(LLMMessage(role: .user, text: text))
        } catch {
            committedItemIDs.remove(itemID)
            lastFailure = error.localizedDescription
            return
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
            messages.append(LLMMessage(role: .developer, text: persona.body, cacheBreakpoint: true))
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
        var buffer = ""
        var reply = ""
        do {
            for try await delta in await provider.stream(
                configuration: configuration,
                messages: messages,
                apiKey: key
            ) {
                reply += delta
                streamingReply = reply
                guard spoken else { continue }
                // 逐句合成：用户不必等整段话写完才听见第一句（§8.1 的首次可听响应）。
                buffer += delta
                for sentence in Self.takeSentences(&buffer, flush: false) {
                    try? await client?.speak(sentence)
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
                try? await client?.speak(sentence)
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
                    speakerLabel: nil
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
        source?.stop()
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
        return .serviceNotReady(error.localizedDescription)
    }

    struct Blocked: Error {
        var reason: BlockReason

        init(_ reason: BlockReason) {
            self.reason = reason
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
