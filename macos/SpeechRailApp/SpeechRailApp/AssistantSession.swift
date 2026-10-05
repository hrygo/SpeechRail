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
        /// VA-07：typing 准入以 LLM 配置、Store 可用性、是否 ending 为准；
        /// microphoneDenied/occupied/serviceBusy/serviceNotReady/streamFailed
        /// 不直接禁 typing。模型与 Store 错误仍给具体出口。
        public var allowsTyping: Bool {
            switch self {
            case .microphoneDenied, .occupiedBy, .serviceBusy, .serviceNotReady, .streamFailed: true
            case .llmNotConfigured, .llmUnreachable, .storeUnavailable: false
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
    /// 展示队列中的输入；仅 turns/contextTurns 表示已经保存的正文。
    var conversationRows: [AssistantConversationRow] {
        let saved = turns.map(AssistantConversationRow.saved)
        guard let sessionID else { return saved }
        let savedIDs = Set(turns.map(\.id))
        return saved + inputPersistence.unsettledInputs(sessionID: sessionID)
            .filter { !savedIDs.contains($0.command.lineID) }
            .map { .accepted($0.command, failure: $0.failure) }
    }
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
    /// VA-03/A47：封存失败后保留的恢复出口。成功封存后清空。
    /// View 用它提供“重试封存 / 复制未保存文本”入口；
    /// lastFailure 只做提示文案，不承载恢复动作。
    public private(set) var pendingSealRecordID: String?
    public private(set) var pendingSealReason: String?
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
    /// VA-06：本场冻结的路由快照。开始时冻结 resolvedLLMConfiguration
    ///（normalizedBaseURL、model、origin），runReply 从快照取 route，
    /// 不再中途重解析 preferences，保证会话内不漂移。
    struct FrozenRoute: Equatable, Sendable {
        var endpoint: String
        var model: String
        var origin: LLMConfigurationOrigin
    }
    private var frozenRoute: FrozenRoute?
    /// VA-06：记忆加载失败标记。失败时明确“本次未加载记忆”，
    /// 不沿用旧数组。
    private var memoryLoadFailed = false

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
    private struct VoiceSelectionIntent {
        var revision: Int
        var voice: String
        var name: String?
    }
    private var voiceSelectionRevision = 0
    private var selectedVoice: VoiceSelectionIntent?
    private var appliedVoiceRevision = -1
    private var voiceApplication: Task<Bool, Never>?
    private var voiceApplicationID: UUID?
    private var voiceStartID: UUID?
    private var voiceStartInProgress: Bool { voiceStartID != nil }
    private struct RequestVoice {
        var replyID: String
        var sessionID: String
        var selection: VoiceSelectionIntent
        var voice: String
        var accepted = false
    }
    private var requestVoices: [String: RequestVoice] = [:]
    private var voiceRecordEffects: [String: (sessionID: String, task: Task<Void, Never>)] = [:]
    private var recordedVoiceRequests: Set<String> = []
    private var recordedVoiceSelections: [String: Int] = [:]
    private var pump: Task<Void, Never>?
    /// VA-02：拆分后的上传/接收任务句柄。receiver 保持单一顺序消费者，
    /// 只做轻量归约，不 await 远端 cancel 确认；取消 effect 独立持有身份。
    private var uploaderTask: Task<Void, Never>?
    private var receiverTask: Task<Void, Never>?
    private var transportCloseEffect: Task<Void, Never>?
    private var transportCloseEffectID: UUID?
    /// 有所有权的取消 effect 句柄（VA-02）。结束/新取消按身份回收旧 effect，
    /// effect 完成只在 session/connection/intent 仍匹配时改变当前 phase。
    private var interruptEffect: Task<Bool, Never>?
    private var interruptEffectID: UUID?
    private var playback: (any AssistantPlaybackChannel)?
    private var sessionStartedAt: Date?
    private var currentOrdinal = 0
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
    /// M0a：生产 receiver 的输入证据去重集，键为
    /// `(connectionGeneration, itemID, revision)`。重连换新锚时与
    /// `itemObservedAt` 一起清空，旧连接证据不污染新会话；`partial` 无
    /// revision，用 `-1` 占位并按 item 去重（同一 item 的空/空白 delta 只记一次）。
    private var seenInputEvidence: Set<AssistantTurnPolicy.EvidenceKey> = []
    /// VA-03 输入生命周期：active → draining → closed。
    /// ending 固定 session，draining 固定 connection；结束推进 startToken
    /// 禁止新发布，但不立即撤销该连接的合法 ASR 归档资格。TTS 输出权立即撤销。
    private enum InputLifecycle: Equatable, Sendable {
        case active
        case draining(session: String?, connection: Int)
        case closed
    }
    private var inputLifecycle: InputLifecycle = .active
    /// 历史回合（**只追加、从不重写**，见 §5.5 的前缀结构）。
    private var contextTurns: [AssistantContextTurn] = []
    private var replyQuestionIDs: [String: String] = [:]
    private var replySpoken: [String: Bool] = [:]
    private var replyPlayback: [String: AssistantContextEntry.PlaybackStatus] = [:]
    private var speechRequests: [String: (sessionID: String, replyID: String)] = [:]
    private var speechRequestIDs: [Int: String] = [:]
    public private(set) var contextOmissionNote: String?
    private var textConversationTask: Task<String, Error>?
    private var textConversationTaskID: UUID?
    /// 本场已经确认并生效的记忆（开始时读一次，会话内不变）。
    private var memories: [String] = []
    /// 半双工门闩：它说话的时候不上行音频（§14.5）。
    private var isMutedForPlayback = false
    /// M3/V08:上行丢块证据——上一块的序号与丢样快照、累计跳过的块数与丢样数。
    /// `bufferingNewest(64)` 替换 + ring 满都会在这里留下可计数的证据；
    /// 有证据即输入不完整，不得当成完整意图回答（由调用方判定）。
    private var lastUploadedChunkSequence: Int?
    private var lastChunkDroppedBefore: Int?
    private(set) var uploadedChunksSkipped: Int = 0
    private(set) var uploadedSamplesDropped: Int = 0
    /// 测试 seam：上一块序号（只读）。生产逻辑不依赖它做决策，
    /// 只做单调证据累计；是否"完整"由调用方按证据判定。
    var lastUploadedChunkSequenceForTest: Int? { lastUploadedChunkSequence }
    /// VA-12/A42：当前重播绑定的原始 turnID（playbackInvocation）。
    /// 重播是独立播放调用：停止只更新本次播放记录，不碰另一回复的生成状态。
    /// nil 表示当前没有重播在跑。
    private(set) var replayingTurnID: String?
    /// VA-12/A42：已因停止而中断的重播 turnID 集合（本次播放记录，不改原生成行）。
    private(set) var interruptedReplayTurnIDs: Set<String> = []
    /// VA-12/A41：播放交付说明（turnID → 说明）。完整生成但未播完时，
    /// 原答案全文保留，history 携带交付状态而非假装已听全文。
    private(set) var playbackDeliveryNotes: [String: String] = [:]
    /// VA-15/A50：基于旧记录继续时的上下文种子（冻结的选定文字）。
    /// 不复制密钥与旧 route 同意；父记录删除不破坏子记录（种子自包含）。
    /// nil 表示当前场不是续接场。
    private(set) var continuationSeed: AssistantContinuationSeed?

    /// VA-15/A50 续接种子：冻结的选定文字 + 来源与范围描述。
    /// 自包含：父记录删除后子场仍可用；不含密钥与旧 route 同意。
    struct AssistantContinuationSeed: Equatable, Sendable {
        var parentSessionID: String?
        var selectedLineIDs: [String]
        var frozenText: String
        var sourceRangeDescription: String
        var createdAt: Date
    }

    /// VA-15/A50：从旧记录选定完整轮次建新场（不依赖 schema v2）。
    ///
    /// 语义：读取旧记录一致快照 → 只取选定的完整 user/assistant 轮次 →
    /// 建新记录 → 冻结选定文字为种子（后续删父记录不破坏子场）。
    /// 旧记录原文不动，不自动开麦，不复制密钥与旧 route 同意。
    /// - Returns: 新记录 id；选定为空或旧记录不存在时返回 nil。
    @discardableResult
    public func continueFromRecord(
        parentID: String,
        selectedLineIDs: Set<String>? = nil,
        maxTurns: Int = 12
    ) async -> String? {
        // 一致快照：记录 + 已定稿行一次读齐；读失败返回 nil，不伪造新场。
        guard let snapshot = try? await coordinator.reviewSnapshot(sessionID: parentID) else { return nil }
        // 只取完整轮次：user/assistant 配对尽量不拆；默认取最近 maxTurns 轮。
        let seedTurns = Self.continuationSeedTurns(
            from: snapshot.lines, selectedLineIDs: selectedLineIDs, maxTurns: maxTurns
        )
        guard !seedTurns.isEmpty else { return nil }
        // 建新场：只带非秘密 route/persona/voice 信息，不带 key 与旧同意。
        let draft = SessionDraft(
            kind: .assistant,
            engineProfile: "unknown",
            audioSource: .microphone,
            llmEndpoint: snapshot.record.llmEndpoint,
            llmModel: snapshot.record.llmModel,
            persona: snapshot.record.persona,
            voice: snapshot.record.voice,
            startedAt: Date()
        )
        guard let record = try? await coordinator.createSession(draft) else { return nil }
        // 冻结种子：选定文字自包含；parent 引用可置空但保留来源与范围描述。
        continuationSeed = AssistantContinuationSeed(
            parentSessionID: parentID,
            selectedLineIDs: seedTurns.map { $0.id },
            frozenText: seedTurns.map { ($0.role == SessionLineRole.assistant ? "助手" : "你") + "：" + $0.text }
                .joined(separator: "\n"),
            sourceRangeDescription: "旧记录 \(parentID) 最近 \(seedTurns.count) 句（已选完整轮次）",
            createdAt: Date()
        )
        // 新场从种子重建 history：只含选定完整轮次，不含密钥与旧同意。
        contextTurns = []
        for index in stride(from: 0, to: seedTurns.count - 1, by: 2) {
            let user = seedTurns[index]
            let reply = seedTurns[index + 1]
            contextTurns.append(AssistantContextTurn(
                user: AssistantContextEntry(id: user.id, text: user.text),
                reply: AssistantContextEntry(
                    id: reply.id, text: reply.text,
                    generationStatus: reply.isInterrupted ? .unknown : .completed,
                    playbackStatus: .unknown
                )
            ))
        }
        sessionID = record.id
        currentOrdinal = 0
        turns = []
        streamingReply = nil
        currentReply = nil
        lastFinalizedReply = nil
        memories = []
        frozenRoute = nil
        return record.id
    }

    /// 选定完整轮次：按 ordinal 配对 user/assistant；selected 为 nil 时取最近。
    public static func continuationSeedTurns(
        from lines: [TranscriptLine],
        selectedLineIDs: Set<String>?,
        maxTurns: Int
    ) -> [TranscriptLine] {
        let ordered = lines.sorted { $0.ordinal < $1.ordinal }
        var complete: [[TranscriptLine]] = []
        var user: TranscriptLine?
        for line in ordered {
            guard line.status == .final else { user = nil; continue }
            if line.role == .user {
                user = line
            } else if line.role == .assistant, let question = user {
                let selected = selectedLineIDs.map { $0.contains(question.id) && $0.contains(line.id) } ?? true
                if selected {
                    complete.append([question, line])
                }
                user = nil
            } else {
                user = nil
            }
        }
        return complete.suffix(max(0, maxTurns)).flatMap { $0 }
    }
    /// 正在跑的这一轮回复（D08）。`nil` 表示此刻没有助手回复在生成或待收尾。
    /// 它的 `id` 就是库里那一行的 id，也是界面 `Turn.id`——全程不变。
    private var currentReply: AssistantReplyState?
    /// VA-04：finalization claim 登记表，以 replyID 为键。
    /// 第一个 await 前登记，局部 isFinalized 不再作为唯一 once 证据；
    /// 迟到收尾按 ID 认领自己的记录，不清新轮状态。
    private var replyFinalizationClaims: Set<String> = []
    /// VA-04：用户问题提交序号。ask 与 ASR final 共用 submitTurn 入口，
    /// 按单调 ordinal 接纳，两个 await 结束先后不改变顺序。
    private var submissionOrdinal = 0
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
    // M2/V06:自动标题是有身份、可等待的后台 effect,不挡正文投影与回答。
    // 结束/新标题按身份回收旧 effect;effect 只写自己的标题认领,不碰正文。
    private var titleEffect: Task<Void, Never>?
    private var titleEffectID: UUID?
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
        selectedVoice = nil
        voiceSelectionRevision &+= 1
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
        voiceSelectionRevision &+= 1
        selectedVoice = VoiceSelectionIntent(revision: voiceSelectionRevision, voice: voice, name: name)
        voiceID = voice
        // 断线/准备期间保留最新意图，发布新连接时应用。
        guard client != nil, !voiceStartInProgress else { return }
        _ = await applyLatestVoice()
    }

    /// 对同一 client 只有一个写入者。新选择只更新意图，不取消跨 actor 的旧写入。
    private func applyLatestVoice() async -> Bool {
        if let task = voiceApplication { return await task.value }
        guard let client else { return false }
        let token = startToken
        let connection = connectionToken
        let applicationID = UUID()
        voiceApplicationID = applicationID
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            defer {
                if self.voiceApplicationID == applicationID {
                    self.voiceApplication = nil
                    self.voiceApplicationID = nil
                }
            }
            while let selection = self.selectedVoice {
                if self.appliedVoiceRevision == selection.revision { return true }
                let binding = await self.realtimeCapabilityBindingProvider?(selection.voice)
                guard self.startToken == token, self.connectionToken == connection else { return false }
                guard self.selectedVoice?.revision == selection.revision else { continue }
                do {
                    if self.realtimeCapabilityBindingProvider != nil, binding?.includesSpeech != true {
                        throw Blocked(.serviceNotReady("无法确认这个音色的实时朗读版本，请刷新服务信息后重试。"))
                    }
                    let canonical = binding?.canonicalVoiceID ?? selection.voice
                    try await client.updateVoice(
                        canonical,
                        expectedVoiceRevision: binding?.voiceRevision,
                        expectedTTSRevision: binding?.ttsModelRevision
                    )
                    guard self.startToken == token, self.connectionToken == connection else { return false }
                    // 旧写入已完成，再串行应用最新选择，下一 start 才可通过。
                    guard self.selectedVoice?.revision == selection.revision else { continue }
                    self.appliedVoiceRevision = selection.revision
                    self.activeRealtimeBinding = binding
                    self.voiceID = canonical
                    self.lastFailure = nil
                    return true
                } catch {
                    guard self.startToken == token, self.connectionToken == connection else { return false }
                    guard self.selectedVoice?.revision == selection.revision else { continue }
                    self.lastFailure = "这个音色现在用不了：\(error.localizedDescription)"
                    return false
                }
            }
            return true
        }
        voiceApplication = task
        return await task.value
    }

    private func recordAcceptedVoice(requestID: String, ordinal: Int) async {
        guard let accepted = requestVoices[requestID],
              accepted.accepted,
              !recordedVoiceRequests.contains(requestID) else { return }
        if recordedVoiceSelections[accepted.sessionID] == accepted.selection.revision {
            requestVoices.removeValue(forKey: requestID)
            return
        }
        // 先认领避免 started 与 ordinal 返回同时重复登记；失败撤销认领供再次保存恢复。
        recordedVoiceRequests.insert(requestID)
        do {
            try await coordinator.noteVoiceChange(
                sessionID: accepted.sessionID, atOrdinal: ordinal,
                voice: VoiceSnapshot(id: accepted.voice, name: accepted.selection.name)
            )
            recordedVoiceSelections[accepted.sessionID] = max(
                recordedVoiceSelections[accepted.sessionID] ?? -1, accepted.selection.revision
            )
            requestVoices.removeValue(forKey: requestID)
            recordedVoiceRequests.remove(requestID)
            guard sessionID == accepted.sessionID else { return }
            if !voiceChanges.contains(where: { $0.atOrdinal == ordinal && $0.voiceID == accepted.voice }) {
                voiceChanges.append(VoiceChange(atOrdinal: ordinal, voiceID: accepted.voice, name: accepted.selection.name))
                voiceChanges.sort { $0.atOrdinal < $1.atOrdinal }
            }
        } catch {
            recordedVoiceRequests.remove(requestID)
            if sessionID == accepted.sessionID, selectedVoice?.revision == accepted.selection.revision {
                lastFailure = "已用于朗读，但音色变更记录未保存：\(error.localizedDescription)"
            }
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
        if let task = textConversationTask { return try await task.value }
        let token = startToken
        let taskID = UUID()
        textConversationTaskID = taskID
        let task = Task { try await createTextConversation(token: token) }
        textConversationTask = task
        defer {
            if textConversationTaskID == taskID {
                textConversationTask = nil
                textConversationTaskID = nil
            }
        }
        return try await task.value
    }

    private func createTextConversation(token: Int) async throws -> String {
        let startedAt = Date()
        let resolved = preferences?().resolvedLLMConfiguration(
            for: .assistant,
            globalAPIKey: apiKeyProvider(),
            moduleAPIKey: moduleAPIKeyProvider(.assistant)
        )
        let configuration = resolved?.configuration
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
        guard token == startToken, inputLifecycle == .active else {
            await coordinator.sealSession(id: record.id)
            throw Superseded.start
        }
        prepareConversationContext(startedAt: startedAt)
        // VA-06：文字场同样冻结路由快照，runReply 从快照取 route。
        if let resolved {
            frozenRoute = FrozenRoute(
                endpoint: resolved.configuration.normalizedBaseURL,
                model: resolved.configuration.model,
                origin: resolved.origin
            )
            llmModel = resolved.configuration.model
        }
        // VA-06：文字场同样统一加载记忆，失败不沿用旧数组。
        do {
            memories = try await coordinator.memories(activeOnly: true).map(\.body)
            memoryLoadFailed = false
        } catch {
            memories = []
            memoryLoadFailed = true
            lastFailure = "本次未加载记忆：\(error.localizedDescription)"
        }
        guard token == startToken, inputLifecycle == .active else {
            await coordinator.sealSession(id: record.id)
            throw Superseded.start
        }
        sessionID = record.id
        isTextOnlyConversation = true
        blocked = nil
        phase = .listening
        return record.id
    }

    /// 打字提问：同一条编排，**不朗读回复**（§6.1 第一条）。
    @discardableResult
    public func ask(typed text: String) async -> TextSendResult {
        let acceptanceToken = startToken
        guard inputLifecycle == .active, phase != .ending else { return .rejected("这一场正在结束，请稍后再发。") }
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
        guard acceptanceToken == startToken, inputLifecycle == .active, self.sessionID == sessionID,
              let startedAt = sessionStartedAt else {
            return .rejected("这一场还没准备好，请稍后再试。")
        }
        guard inputPersistence.failures(sessionID: sessionID).isEmpty else {
            return .rejected("还有输入未保存，请先重试保存。")
        }
        let observedAt = dependencies.now()
        let command = AssistantInputPersistenceQueue.Command(
            sessionID: sessionID, connection: connectionToken, itemID: "",
            text: question, source: .keyboard,
            tStart: max(0, observedAt.timeIntervalSince(startedAt)),
            formal: true, observedAt: observedAt
        )
        switch inputPersistence.enqueue(command) {
        case .accepted, .duplicate: break
        case .capacityExceeded:
            return .rejected("记录正在保存，暂时无法发送，请稍后再试。")
        case .invalidIdentity:
            return .rejected("无法确认这一场的记录，请重试。")
        }
        switch await inputPersistence.waitForResult(lineID: command.lineID) {
        case .saved:
            return .accepted
        case .blocked:
            if self.sessionID == sessionID {
                lastFailure = "内容已接纳，但前面的输入尚未保存。请结束对话后重试保存。"
            }
            return .accepted
        case .failed(let message):
            if self.sessionID == sessionID { lastFailure = "这一句未保存：\(message)" }
            return .rejected("没能把这条问题记下来，请重试保存。")
        }
    }

    /// 重播某一句话（打字提问的回复也能听——「不朗读」不等于「不能听」）。
    public func replay(turn: Turn) async {
        guard turn.role == .assistant else { return }
        // VA-12/A42：重播前若旧 TTS 轮仍活跃（isActive），先经统一中断收尾，
        // 再开新的 playbackInvocation。旧轮按自己的 requestID 走退休屏障，
        // 新重播绑定新的 originalTurnID，不与旧轮混淆。
        if let stream = ttsStream, stream.isActive {
            guard await interruptCurrentReply() else { return }
        }
        guard let stream = ttsStream else { return }
        // VA-12/A42：playbackInvocation 绑定 originalTurnID。
        // 停止重播只更新本次播放记录，不改被重播轮的生成状态。
        // 新重播开始时清掉旧重播身份，避免旧重播的迟到终态污染新轮。
        let invocationID = turn.id
        replayingTurnID = invocationID
        interruptedReplayTurnIDs.remove(invocationID)
        playbackDeliveryNotes.removeValue(forKey: invocationID)
        isSpeaking = true
        phase = .speaking
        // 重播与首次朗读同一条口径：已定稿整句走确认计划（整体解析+保义转换），
        // 否则漏出来的标记会被念第二遍。计划超限则保留文字、不开机。
        let planResult = AssistantSpeechPlanBuilder.build(from: turn.text)
        let utterance: String
        switch planResult {
        case .success(let plan):
            guard plan.isValid, !plan.speakText.isEmpty else {
                replayingTurnID = nil
                isSpeaking = false
                phase = .listening
                lastFailure = "朗读计划校验未通过，已保留文字。"
                return
            }
            utterance = plan.speakText
        case .failure:
            replayingTurnID = nil
            isSpeaking = false
            phase = .listening
            lastFailure = "这句太长，先保留文字不朗读。"
            return
        }
        do {
            try await stream.begin(
                generation: replyGeneration,
                requestID: "tts_req_\(UUID().uuidString.lowercased())"
            )
        } catch {
            replayingTurnID = nil
            isSpeaking = false
            phase = .listening
            lastFailure = error.localizedDescription
            return
        }
        stream.offerConfirmed(utterance)
        await stream.finishInput()
        // finishInput 返回只表示输入送完：播放是否播完由账本/终态决定。
        // 重播身份在停止或终态时清除，这里不提前清，避免迟到停止找不到归属。
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

    /// 测试入口：设置 blocked（VA-07/A16/A17）。
    /// 生产路径不受影响，仅供 Fake 夹具模拟语音故障。
    public func blockedForTest(_ reason: BlockReason) {
        blocked = reason
    }

    /// 测试入口：清除 blocked。
    public func clearBlockedForTest() {
        blocked = nil
    }

    /// 主动停止当前助手的朗读或思考（打断当前回答），但不结束会话。
    /// 用户按 ESC 或点击「停止朗读」时调用，清空播放队列与下行生成，保留上下文。
    public func stopSpeaking() async {
        guard phase == .speaking || phase == .thinking || isSpeaking || replyTask != nil else { return }
        _ = await interruptCurrentReply()
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
        await requestReplyInterrupt().value
    }

    /// VA-02 中断意图 effect（InterruptIntent）。
    ///
    /// 先同步撤 reply 输出权、作废播放 epoch，再把有界停播 → cancel → terminal 等待
    /// 交给唯一 effect。effect 持有 session/connection 身份，完成后只在仍匹配时
    /// 改变当前 phase；即使过期也回收自己的资源与 waiter。
    @discardableResult
    private func requestReplyInterrupt(
        termination: AssistantReplyState.Termination = .interrupted
    ) -> Task<Bool, Never> {
        if let effect = interruptEffect { return effect }
        let session = sessionID
        let connection = connectionToken
        let intentID = UUID()
        interruptEffectID = intentID
        let reply = currentReply
        let finalized = lastFinalizedReply
        let replayID = replayingTurnID
        let stream = ttsStream
        let hadPlayback = isSpeaking || stream?.isActive == true || stream?.isAwaitingPlayback == true
        // 撤权和挂远端屏障在 Task 创建前完成，避免下一 start 抢占旧 request。
        let preparation = stream?.prepareCancellation()
        invalidateReply()
        let revokedGeneration = replyGeneration
        isSpeaking = false
        streamingReply = nil
        isMutedForPlayback = false
        let effect = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            let confirmed: Bool
            if let stream, let preparation {
                confirmed = await stream.performCancellation(preparation)
            } else {
                await self.stopPlaybackLayer()
                confirmed = stream?.hasUnconfirmedRemoteOwnership != true
            }
            if let replayID {
                if self.sessionID == session {
                    self.interruptedReplayTurnIDs.insert(replayID)
                    self.playbackDeliveryNotes[replayID] = "朗读未完成；已保留完整文字，可重新播放。"
                    if self.replayingTurnID == replayID { self.replayingTurnID = nil }
                }
            } else if let reply {
                await self.finalizeReply(termination, reply: reply)
            } else if let finalized, hadPlayback {
                await self.markLastReplyInterruptedAfterPlaybackCut(reply: finalized)
            }
            guard self.interruptEffectID == intentID else { return confirmed }
            self.interruptEffect = nil
            self.interruptEffectID = nil
            guard self.sessionID == session, self.connectionToken == connection else { return confirmed }
            if !confirmed {
                await self.handleUnconfirmedRemoteIdle()
            } else if self.replyGeneration == revokedGeneration, self.phase != .ending {
                self.phase = .listening
            }
            return confirmed
        }
        interruptEffect = effect
        return effect
    }

    /// 回收已过期或已完成的中断 effect，不等待其远端确认。
    private func cancelInterruptEffect() {
        interruptEffect?.cancel()
        interruptEffect = nil
        interruptEffectID = nil
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
        stopPumpTasks()
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
        try requireLive(token)
        isStoppingIntentionally = false
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
        var binding: RealtimeCapabilityBinding?
        var bindingRevision: Int
        repeat {
            bindingRevision = voiceSelectionRevision
            binding = await realtimeCapabilityBindingProvider?(selectedVoice?.voice ?? voiceID)
            try requireLive(token)
        } while bindingRevision != voiceSelectionRevision
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
        seenInputEvidence.removeAll()
        // itemID 是**连接内**的去重键：重连之后服务端会从头编号，
        // 沿用上一条连接的集合会把新的一句话当成重复而丢掉。
        do {
            try requireLive(token)
        } catch {
            // 晚到的连接：只关掉它自己，不碰当前会话的设备与状态。
            source.stop()
            await client.close()
            throw error
        }

        // 增量 TTS 的协调器先建好：播放层的"真播完"回调要直接挂到它上面。
        let tts = makeTTSStreamCoordinator(client: client, audioSession: audioSession)

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
            audioSession.onPlaybackBufferRendered = { [weak tts] epoch, frames, chunkID in
                tts?.notePlaybackCompleted(samples: frames, epoch: epoch, chunkID: chunkID)
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
                // M0b：本地输出权同步撤销并登记旧 request 的 retired 归属；
                // 远端仍 active 时必须等匹配 terminal 再放行新轮，不直接
                // invalidate 丢弃。存活 receiver 继续消费旧连接的终态。
                let preparation = self.ttsStream?.prepareCancellation()
                if preparation == nil {
                    self.ttsStream?.invalidate()
                }
                self.isSpeaking = false
                self.isMutedForPlayback = false
                // 旧远端收尾与本地收尾都走这一个 effect：停本地播→发取消→等匹配
                // terminal。确认或超时落定后才收尾正文、改 phase 或关连接；
                // 旧终态迟到只解自己的闩，不污染新轮（V03）。
                let effectSession = self.sessionID
                let effectConnection = self.connectionToken
                let effectToken = self.startToken
                let effect = Task<Bool, Never> { [weak self] in
                    guard let self else { return false }
                    if let stream = self.ttsStream, let preparation {
                        return await stream.performCancellation(preparation)
                    }
                    await self.stopPlaybackLayer()
                    return self.ttsStream?.hasUnconfirmedRemoteOwnership != true
                }
                let confirmed = await effect.value
                guard self.sessionID == effectSession,
                      self.connectionToken == effectConnection,
                      self.startToken == effectToken else { return }
                if let reply = self.currentReply {
                    self.invalidateReply()
                    await self.finalizeReply(.interrupted, reply: reply)
                } else {
                    await self.markLastReplyInterruptedAfterPlaybackCut()
                }
                if invalidation.recovered {
                    if confirmed {
                        // 旧远端已确认收尾：当轮按中断收尾，可继续下一轮。
                        self.lastFailure = "音频设备已切换，本次朗读已停止。"
                        if self.phase == .speaking || self.phase == .thinking {
                            self.phase = .listening
                        }
                    } else {
                        // 超时或旧发送未退出：远端归属未知，关连接显式重试，
                        // 保留记录/文字。recovered 不映射成远端空闲。
                        await self.handleUnconfirmedRemoteIdle(
                            message: "设备切换后没能确认上一轮朗读已经结束，已断开连接。请重试语音。"
                        )
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
            player.onBufferRendered = { [weak tts] epoch, frames, _ in
                tts?.notePlaybackCompleted(samples: frames, epoch: epoch)
            }
            tts.enqueuePlayback = { pcm, epoch, chunkID in await player.enqueue(pcm, epoch: epoch, chunkID: chunkID) }
            tts.stopPlayback = { await player.stop() }
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
        // 设备/建连期间可能又选了音色；私有连接只在最新版本写入完成后发布。
        do {
            repeat {
                bindingRevision = voiceSelectionRevision
                let latestVoice = selectedVoice?.voice ?? voiceID
                binding = await realtimeCapabilityBindingProvider?(latestVoice)
                try requireLive(token)
                guard bindingRevision == voiceSelectionRevision else { continue }
                if realtimeCapabilityBindingProvider != nil, binding?.includesSpeech != true {
                    throw Blocked(.serviceNotReady("无法确认所选音色的实时朗读版本。"))
                }
                if let canonical = binding?.canonicalVoiceID ?? latestVoice {
                    try await client.updateVoice(
                        canonical, expectedVoiceRevision: binding?.voiceRevision,
                        expectedTTSRevision: binding?.ttsModelRevision
                    )
                }
                try requireLive(token)
            } while bindingRevision != voiceSelectionRevision
        } catch {
            await tearDownPrivate(source: source, audioSession: audioSession, client: client)
            throw error
        }
        appliedVoiceRevision = bindingRevision
        voiceApplication?.cancel()
        voiceApplication = nil
        voiceApplicationID = nil
        self.source = source
        self.audioSession = audioSession
        self.client = client
        self.ttsStream = tts
        voiceStartID = nil
        activeRealtimeBinding = binding
        return VoiceTransport(
            stream: stream,
            client: client,
            profile: profile,
            configuration: configuration,
            configurationOrigin: resolved.origin,
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
        var configurationOrigin: LLMConfigurationOrigin
        var startedAt: Date
        var connection: Int
    }

    /// **只在新会话开始时执行一次**的人设、记忆、历史与序号初始化。
    /// 重连不调用它：那些是会话级状态，中断续接必须原样保留（S2 第 8 条）。
    private func prepareConversationContext(startedAt: Date) {
        sessionStartedAt = startedAt
        invalidateReply()
        turns = []
        contextTurns = []
        replyQuestionIDs = [:]
        replySpoken = [:]
        replyPlayback = [:]
        speechRequests = [:]
        speechRequestIDs = [:]
        contextOmissionNote = nil
        partialText = nil
        partialItemID = nil
        streamingReply = nil
        currentOrdinal = 0
        seenInputEvidence.removeAll()
        // VA-06：先清上一场 memories/history，再加载选中 active 记忆。
        // 记忆加载失败时明确标记，不沿用旧数组。
        memories = []
        memoryLoadFailed = false
        frozenRoute = nil
        isStoppingIntentionally = false
        // 新会话默认可上行；同一场重连不动它（D04）。
        isMuted = false
        // VA-03：新场输入生命周期回到 active，排空态不跨场。
        inputLifecycle = .active
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
        // VA-06：统一记忆加载。失败时明确标记，不沿用旧数组。
        do {
            memories = try await coordinator.memories(activeOnly: true).map(\.body)
            memoryLoadFailed = false
        } catch {
            memories = []
            memoryLoadFailed = true
            lastFailure = "本次未加载记忆：\(error.localizedDescription)"
        }
        // VA-06：冻结路由快照（endpoint/model/origin），会话内不再重解析。
        frozenRoute = FrozenRoute(
            endpoint: configuration.normalizedBaseURL,
            model: configuration.model,
            origin: transport.configurationOrigin
        )
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
        // VA-03 结束顺序：ending target once-claim → 拒新发布 → 本地停播与取消 effect
        // → capture 停产 → uploader 排空 → commit(receipt) → draining 保存 → seal。
        // **先作废 startToken，再做任何 await**：这样任何还在飞的启动 await
        // 都会在返回后看见自己过期，只能收掉自己的私有资源（D02）。
        // connectionToken 暂不推进：draining 连接保留合法 ASR 归档资格，
        // TTS 输出权立即撤销，receiver 继续消费该连接的 final。
        let drainingConnection = connectionToken
        let endingSession = sessionID
        inputLifecycle = .draining(session: endingSession, connection: drainingConnection)
        startToken &+= 1
        selectedVoice = nil
        voiceSelectionRevision &+= 1
        voiceApplication?.cancel()
        voiceApplication = nil
        voiceApplicationID = nil
        retryTask?.cancel()
        retryTask = nil
        isStoppingIntentionally = true
        if let effect = transportCloseEffect { await effect.value }
        if let effect = interruptEffect { _ = await effect.value }
        cancelInterruptEffect()
        // 结束对话也是一次回复收尾：正在生成的那一轮先把已知正文存下来并标成打断，
        // 再去关连接。否则最后半句会随着连接一起消失（D06 / D08）。
        let endingReply = currentReply
        let endingCancellation = ttsStream?.prepareCancellation()
        invalidateReply()
        if let stream = ttsStream, let endingCancellation {
            _ = await stream.performCancellation(endingCancellation)
        } else {
            await stopPlaybackLayer()
        }
        if let reply = endingReply {
            await finalizeReply(.interrupted, reply: reply)
        }
        invalidateReply()
        ttsStream?.invalidate()
        // capture 停产：停止 tap 生产；uploader 按准入规则排空已捕获尾部。
        // 现有引擎 stop 为同步释放，此处先停产再排空 drain，避免尾句随连接消失。
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
        // 输入排空：commit(request_receipt=true) → draining receiver 保存 matching final。
        // drainAndClear 返回与应用 marker 到达可能赛跑，结束同时等两者，不假定顺序。
        if let client {
            do {
                try await client.drainAndClear(timeout: .seconds(8))
            } catch {
                // The session can still be closed locally, but it must not
                // claim that the final remote item completed.
                lastFailure = error.localizedDescription
            }
        }
        // 等待 marker 之前的保存任务全部 settled；receiver 不等待该聚合。
        // 有界等待排空保存，避免结束时仍在飞的 final 丢失。
        let inputsSaved: Bool
        if let endingSession {
            inputsSaved = await waitForInputSaves(sessionID: endingSession)
            let records = voiceRecordEffects.values.filter { $0.sessionID == endingSession }
            for record in records { await record.task.value }
            // M2/V06:标题 effect 有界收尾——标题无响应不挡结束报告，
            // 标题失败只记原因，不覆盖正文、不污染封存判定。
            await drainTitleEffect()
        } else {
            inputsSaved = true
        }
        if !inputsSaved, let endingSession {
            lastFailure = "部分输入尚未保存，请重试保存；本轮记录尚未封存。"
            pendingSealRecordID = endingSession
            pendingSealReason = lastFailure
            // 归还本场设备但不封存；coordinator 的 stopper 返回后也不能误宣称保存齐全。
            if coordinator.activeSessionID == endingSession, coordinator.occupancy?.kind == .assistant {
                coordinator.abandonOccupancy()
            }
        }
        // 保存屏障之后再关闭 transport：draining 期间的合法 final 已归档。
        if let client {
            await client.close()
        }
        stopPumpTasks()
        // 结束时推进 connection 代次，撤销该连接的归档资格。
        connectionToken &+= 1
        inputLifecycle = .closed
        client = nil
        // 纯文字这一场没有设备租约，但也得有终态：按它自己的 sessionID 封存，
        // 不能走 `coordinator.finalize`（那会停掉别的功能正在用的设备，D07 / §4.2）。
        if inputsSaved, isTextOnlyConversation, let recordID = sessionID {
            // VA-03：真实结果封存。失败保留 pendingSeal 与内存文本，硬件仍释放。
            let seal = await coordinator.sealSessionReporting(id: recordID, reason: .user)
            switch seal {
            case .sealed:
                pendingSealRecordID = nil
                pendingSealReason = nil
            case .failed(let failedID, let reason):
                lastFailure = "记录尚未保存（\(reason)），可在记录库中重试。"
                pendingSealRecordID = failedID ?? recordID
                pendingSealReason = reason
            case .skipped:
                pendingSealRecordID = nil
                pendingSealReason = nil
            }
        }
        lastFinalizedSessionID = isTextOnlyConversation ? sessionID : lastFinalizedSessionID
        resetToIdleKeepingTurns()
    }

    /// VA-03/A47：封存失败后的重试出口。成功后清空 pendingSeal 并发布成功 ID。
    ///
    /// 只重试调用时仍保留的 recordID；成功才算 sealed，失败保留原因供复制。
    /// View 的“重试保存”按钮走这里，不走 stopCapture 的完整结束流程。
    @discardableResult
    public func retryPendingSeal() async -> Bool {
        guard let recordID = pendingSealRecordID else { return false }
        for failure in inputPersistence.failures(sessionID: recordID) {
            _ = inputPersistence.retry(sessionID: recordID, lineID: failure.command.lineID)
        }
        guard await waitForInputSaves(sessionID: recordID) else {
            pendingSealReason = "仍有输入未保存，请重试保存。"
            lastFailure = pendingSealReason
            return false
        }
        let seal = await coordinator.sealSessionReporting(id: recordID, reason: .user)
        switch seal {
        case .sealed:
            pendingSealRecordID = nil
            pendingSealReason = nil
            lastFinalizedSessionID = recordID
            return true
        case .failed(_, let reason):
            pendingSealReason = reason
            lastFailure = "记录尚未保存（\(reason)），可在记录库中重试。"
            return false
        case .skipped:
            pendingSealRecordID = nil
            pendingSealReason = nil
            return true
        }
    }

    /// VA-03/A47：复制未保存文本的来源。内存 turns 为准，不读库；
    /// turns 为空时返回空字符串，调用方按“无可复制内容”处理。
    public func unsavedTranscriptText() -> String {
        var texts = turns.map(\.text)
        if let recordID = pendingSealRecordID ?? sessionID {
            let projectedIDs = Set(turns.map(\.id))
            let unprojected = inputPersistence.pendingCommands(sessionID: recordID)
                + inputPersistence.failures(sessionID: recordID).map(\.command)
            texts += unprojected
                .filter { !projectedIDs.contains($0.lineID) }
                .sorted { $0.observedAt < $1.observedAt }
                .map(\.text)
        }
        return texts.filter { !$0.isEmpty }.joined(separator: "\n")
    }
    // MARK: - VA-01 助手专属结束（A01/A02/A18）
    //
    // 旧路径（View 直接调 `session.stopCapture(endingWith:)`）按全局 occupancy 收尾：
    // 纯文字助手无 occupancy 时结束无效，会议占用时反而会改会议相位。
    // 这里的结束目标捕获本场身份，文字走自己的 recordID，语音走 kind + leaseID + recordID，
    // 重复结束共用 single-flight 任务，未匹配目标不做全局 stop。

    /// 当前助手场的结束目标。preparing 阶段尚无 recordID 时仍可用 leaseID 锁定租约。
    public func endTarget() -> SessionCoordinator.AssistantEndTarget {
        SessionCoordinator.AssistantEndTarget(
            recordID: sessionID,
            leaseID: coordinator.activeLeaseID
        )
    }

    private var endTask: Task<SessionCoordinator.AssistantEndResult, Never>?

    /// 助手专属结束：single-flight，重复调用共用同一任务。
    @discardableResult
    public func endConversation(target: SessionCoordinator.AssistantEndTarget? = nil) async -> SessionCoordinator.AssistantEndResult {
        if let running = endTask {
            return await running.value
        }
        let resolved = target ?? endTarget()
        // 无会话、无占用、无记录：明确 no-op，不伪造结束。
        guard sessionID != nil || coordinator.occupancy != nil || resolved.recordID != nil else {
            return .noConversation
        }
        let task = Task<SessionCoordinator.AssistantEndResult, Never> { [weak self] in
            guard let self else { return .noConversation }
            return await self.performAssistantEnd(target: resolved)
        }
        endTask = task
        let result = await task.value
        endTask = nil
        return result
    }

    private func performAssistantEnd(target: SessionCoordinator.AssistantEndTarget) async -> SessionCoordinator.AssistantEndResult {
        // 纯文字：无设备租约，按自己的 recordID 封存，不碰全局占用。
        // A02：会议/其他功能占用设备时，文字结束只封自己的记录，
        // 占用、phase、记录、stopper 调用数全部不变。
        if isTextOnlyConversation {
            guard let recordID = target.recordID ?? sessionID else { return .noConversation }
            // 先收尾本场回复与本地资源，再封存自己的记录。
            guard await endTextOnlyResources() else {
                resetToIdleKeepingTurns()
                return .noConversation
            }
            // VA-03 真实结果封存：失败保留 pendingSeal 与原因，
            // 界面走重试/复制出口，不发布虚假的“已封存”。
            let seal = await coordinator.sealSessionReporting(id: recordID, reason: .user)
            switch seal {
            case .sealed:
                pendingSealRecordID = nil
                pendingSealReason = nil
            case .failed(let failedID, let reason):
                lastFailure = "记录尚未保存（\(reason)），可在记录库中重试。"
                pendingSealRecordID = failedID ?? recordID
                pendingSealReason = reason
            case .skipped:
                // 纯文字记录本就不在 occupancy 里：跳过只表示无需再封，
                // 本场仍收尾为 idle，不发布虚假的已封存 ID。
                pendingSealRecordID = nil
                pendingSealReason = nil
            }
            // 只有真实 sealed 才发布界面落地结果；failed/skipped 不伪造已封存。
            if case .sealed = seal {
                lastFinalizedSessionID = recordID
            }
            resetToIdleKeepingTurns()
            // failed/skipped 不再冒充 ended：调用方与 View 按封存真实结果落地。
            if case .sealed = seal {
                return .ended(recordID: recordID)
            }
            return .noConversation
        }
        // 无占用、无本场记录：明确 no-op。
        if coordinator.occupancy == nil {
            guard let recordID = target.recordID ?? sessionID else { return .noConversation }
            guard await endTextOnlyResources() else {
                resetToIdleKeepingTurns()
                return .noConversation
            }
            let seal = await coordinator.sealSessionReporting(id: recordID, reason: .user)
            switch seal {
            case .sealed:
                pendingSealRecordID = nil
                pendingSealReason = nil
                lastFinalizedSessionID = recordID
            case .failed(let failedID, let reason):
                lastFailure = "记录尚未保存（\(reason)），可在记录库中重试。"
                pendingSealRecordID = failedID ?? recordID
                pendingSealReason = reason
            case .skipped:
                pendingSealRecordID = nil
                pendingSealReason = nil
            }
            resetToIdleKeepingTurns()
            if case .sealed = seal {
                return .ended(recordID: recordID)
            }
            return .noConversation
        }
        // 语音：本场必须持有助手占用，否则是旧目标或他人会话。
        guard coordinator.occupancy?.kind == .assistant else { return .mismatch }
        if let expectedLease = target.leaseID, let currentLease = coordinator.activeLeaseID,
           expectedLease != currentLease {
            return .superseded
        }
        if let recordID = target.recordID, let active = coordinator.activeSessionID, recordID != active {
            return .superseded
        }
        await stopCapture()
        if pendingSealRecordID == target.recordID { return .noConversation }
        let result = await coordinator.endAssistant(target, reason: .user)
        if case .ended(let recordID) = result {
            lastFinalizedSessionID = recordID ?? lastFinalizedSessionID
        }
        return result
    }

    /// 纯文字结束的本地收尾：停回复任务、作废 TTS（无）、保留 turns 供回看。
    private func endTextOnlyResources() async -> Bool {
        let endingSession = sessionID
        inputLifecycle = .closed
        startToken &+= 1
        selectedVoice = nil
        voiceSelectionRevision &+= 1
        voiceApplication?.cancel()
        voiceApplication = nil
        voiceApplicationID = nil
        connectionToken &+= 1
        retryTask?.cancel()
        retryTask = nil
        isStoppingIntentionally = true
        if let effect = transportCloseEffect { await effect.value }
        if let effect = interruptEffect { _ = await effect.value }
        cancelInterruptEffect()
        if let reply = currentReply {
            invalidateReply()
            await finalizeReply(.interrupted, reply: reply)
        }
        invalidateReply()
        ttsStream?.invalidate()
        ttsStream = nil
        stopPumpTasks()
        if let endingSession, !(await waitForInputSaves(sessionID: endingSession)) {
            pendingSealRecordID = endingSession
            pendingSealReason = "仍有输入未保存，记录尚未封存。"
            lastFailure = pendingSealReason
            return false
        }
        // M2/V06:纯文字结束同样有界等标题 effect，不挡封存报告。
        await drainTitleEffect()
        return true
    }

    private func resetToIdleKeepingTurns() {
        invalidateReply()
        // M2/V06:新场不继承旧标题句柄。结束路径已在 reset 之前 drain；
        // 这里只取消并清空，迟到标题写 lastFailure 时有 sessionID 守卫。
        titleEffect?.cancel()
        titleEffect = nil
        titleEffectID = nil
        cancelInterruptEffect()
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
        seenInputEvidence.removeAll()
        sessionStartedAt = nil
        sessionID = nil
        isMutedForPlayback = false
        isSpeaking = false
        ttsStream?.invalidate()
        ttsStream = nil
        // VA-03：新场从 active 开始；draining 去重集与计数不跨场。
        inputLifecycle = .active
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
        // VA-02：uploader / receiver 可分别停止。receiver 是唯一的顺序事件消费者，
        // 只做轻量归约与身份校验；取消的远端等待由独立 effect 持有，不占用 receiver。
        stopPumpTasks()
        uploaderTask = Task { [weak self] in
            for await chunk in stream {
                guard let self else { return }
                await self.upload(chunk, to: client)
            }
        }
        receiverTask = Task { [weak self] in
            let events = await client.events()
            for await envelope in events {
                guard let self else { return }
                await self.handle(envelope, from: connection)
            }
        }
        // 旧句柄保留作兼容：两者任一存在即视为 pump 存活，取消时一并回收。
        pump = Task { [weak self] in
            guard let self else { return }
            _ = await (self.uploaderTask?.value, self.receiverTask?.value)
        }
    }

    /// 停止上传与接收任务。receiver 不等待远端 cancel 确认；
    /// 有所有权的取消 effect 由调用方按身份回收。
    private func stopPumpTasks() {
        uploaderTask?.cancel()
        uploaderTask = nil
        receiverTask?.cancel()
        receiverTask = nil
        pump?.cancel()
        pump = nil
    }

    private func upload(_ chunk: AudioChunk, to client: any AssistantRealtimeClient) async {
        guard !isStoppingIntentionally else { return }
        // M3/V08:块序号跳跃（bufferingNewest 替换）与丢样快照差（ring 满）
        // 都在这里累计为单调证据。无序号/无快照的旧来源不产生证据，
        // 也不伪造"连续"结论。
        if let seq = chunk.sequenceNumber {
            if let last = lastUploadedChunkSequence, seq > last + 1 {
                uploadedChunksSkipped += seq - last - 1
            }
            lastUploadedChunkSequence = seq
        }
        if let dropped = chunk.droppedSamplesBefore {
            if let last = lastChunkDroppedBefore, dropped > last {
                uploadedSamplesDropped += dropped - last
            }
            lastChunkDroppedBefore = dropped
        }
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
            // M0a：空/纯空白 delta 无副作用：不记 observed、不触发打断、
            // 不动字幕槽。非空才走统一证据门并去重。
            guard !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            _ = observedAt(forItem: itemID, receivedAt: envelope.receivedAt)
            noteSpeechEvidence(text: delta, itemID: itemID, revision: -1, connection: connection)
            // 别的 item 的增量不进来：它是**那一句**的证据，不是当前槽位的。
            guard ownsPartial(itemID) else { return }
            partialItemID = itemID
            partialText = (partialText ?? "") + delta
        case .partialSnapshot(let itemID, let revision, let text, _):
            if !text.isEmpty {
                _ = observedAt(forItem: itemID, receivedAt: envelope.receivedAt)
            }
            // M0a：空/纯空白 snapshot 无副作用；非空经
            // `(connection, itemID, revision)` 去重后才构成打断证据。
            // hypothesis 仍整段替换，不拼接修订文本。
            noteSpeechEvidence(text: text, itemID: itemID, revision: revision, connection: connection)
            guard ownsPartial(itemID) else { return }
            // hypothesis 是**可改写全文**，必须整段替换，不能追加（契约 §5.1）。
            // 空/纯空白快照是"这一句现在没有可展示的正文"：清掉可见文字，
            // 并把归属一起放开——槽位空着的时候，下一个 item 才能接上，
            // 不会被这一句占住。空白快照不得绑定槽位，否则后到的有效证据
            // 会因归属不匹配被挡在槽外（V01）。
            let hasVisibleText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            partialItemID = hasVisibleText ? itemID : nil
            partialText = hasVisibleText ? text : nil
        case .completed(let itemID, let transcript):
            // final-only 的 item 到这里才有第一个证据，用它自己的接收时刻。
            let observed = observedAt(forItem: itemID, receivedAt: envelope.receivedAt)
            commitUserTurn(itemID: itemID, transcript: transcript, observedAt: observed)
        case .failed(let itemID, let code, let message):
            // 空 itemID 认不出身份（例如 `invalid_hypothesis`），
            // 只报告失败，不去动别人的可见文字。
            if ownsPartial(itemID) {
                partialText = nil
                partialItemID = nil
            }
            lastFailure = "\(code)：\(message)"
        case .ttsStarted(let requestID, let taskID, let limits):
            if let stream = ttsStream, stream.handleStarted(
                requestID: requestID,
                taskID: taskID,
                limits: limits
            ) || stream.isKnownRetiredRequest(requestID) {
                requestVoices[requestID]?.accepted = true
                if let accepted = requestVoices[requestID],
                   let ordinal = turns.first(where: { $0.id == accepted.replyID })?.ordinal,
                   voiceRecordEffects[requestID] == nil {
                    let task = Task { [weak self] in
                        guard let self else { return }
                        await self.recordAcceptedVoice(requestID: requestID, ordinal: ordinal)
                        self.voiceRecordEffects.removeValue(forKey: requestID)
                    }
                    voiceRecordEffects[requestID] = (accepted.sessionID, task)
                }
            }
        case .ttsTextAccepted(let requestID, _, let appendSequence, let totalCodepoints):
            _ = ttsStream?.handleTextAccepted(
                requestID: requestID,
                appendSequence: appendSequence,
                totalCodepoints: totalCodepoints
            )
        case .ttsAudio(let requestID, _, let pcm):
            // 只让当前 request 的已准入音频改变 speaking/闭麦状态。
            // 旧 request 与未知 request 既不能入队，也不能制造朗读 UI。
            guard let stream = ttsStream, stream.currentRequestID == requestID, stream.isActive else { break }
            let admission = stream.admitAudio(requestID: requestID, pcm: pcm)
            guard admission == .accepted else { break }
            isSpeaking = true
            phase = .speaking
            // 半双工：从这一刻起闭麦（一问一答的口径）。
            isMutedForPlayback = !mode.allowsBargeIn
        case .ttsEnded(let requestID, _, let status, let code, let message):
            // 终态**无条件**转给协调器，不在这里按 `isActive` 过滤。
            // 打断之后那一轮已经被 `invalidate()` 作废，`isActive` 是 false；
            // 在这一层挡掉的话，远端空闲屏障就永远等不到解除的那条终态
            // （方案 S4 第 12 条）。活动/已作废的区分由协调器自己判断。
            await ttsStream?.handleTerminal(requestID: requestID, status: status)
            // VA-05：终态分 current/retired/unknown。
            // 协调器已无条件受理（闩已解）；此处只决定界面副作用：
            // current 才可改 phase/error；retired/unknown 不改，避免旧终态
            // 污染新轮。无协调器（nil）时按原路径受理，保证旧测试终态可达。
            if let stream = ttsStream {
                guard stream.currentRequestID == requestID else { break }
            }
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
            scheduleUnexpectedClose(code: code)
        }
    }

    /// 当前 wire 没有服务端 VAD 事件（`speech_started` 已移除，契约 §5.1），
    /// 所以 barge-in 完全由客户端决定：**允许插话时，第一次收到非空识别结果
    /// 就是"用户开始说话"**。半双工模式下播放期本来就不上行，自然不会触发。
    /// M0a：生产 receiver 的统一证据门。空/纯空白无副作用；同一
    /// `(connection, itemID, revision)` 只触发一次；跨 item 的同 revision 独立。
    /// `partial` 无 revision，用 `-1` 占位并按 item 去重。
    private func noteSpeechEvidence(text: String, itemID: String, revision: Int, connection: Int) {
        let decision = AssistantTurnPolicy.bargeInEvidence(
            text: text,
            connection: connection,
            itemID: itemID,
            revision: revision,
            seenEvidence: seenInputEvidence,
            allowsBargeIn: mode.allowsBargeIn,
            isSpeakingOrGenerating: isSpeaking || replyTask != nil
        )
        seenInputEvidence = decision.seenEvidence
        guard decision.fires else {
            return
        }
        // 插话和 ESC 走同一条路：同一个回复收尾（D08），正文与打断标记一起写。
        _ = requestReplyInterrupt()
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
    @ObservationIgnored private lazy var inputPersistence = AssistantInputPersistenceQueue(
        configuration: dependencies.inputPersistenceConfiguration,
        save: { [weak self] command in
            guard let self else { throw CancellationError() }
            let draft = LineDraft(
                sessionID: command.sessionID, role: .user, text: command.text,
                source: command.source, tStart: command.tStart, tEnd: nil,
                status: command.formal ? .final : .partial, isInterrupted: !command.formal,
                timingQuality: .unavailable, createdAt: command.observedAt
            )
            do {
                return try await self.saveInputLine(draft, id: command.lineID)
            } catch {
                // 指定 ID 的 INSERT 不提供幂等成功；恢复必须按 ID 与不可变正文核对。
                if let lines = try? await self.coordinator.lines(sessionID: command.sessionID, includePartial: true),
                   let line = lines.first(where: { $0.id == command.lineID }),
                   line.role == .user, line.text == command.text, line.source == command.source,
                   line.status == draft.status, line.isInterrupted == draft.isInterrupted,
                   line.tStart == command.tStart, line.tEnd == nil, line.timingQuality == .unavailable,
                   abs(line.createdAt.timeIntervalSince(command.observedAt)) < 0.001 {
                    return line.ordinal
                }
                if self.sessionID == command.sessionID { self.lastFailure = "这一句未保存：\(error.localizedDescription)" }
                throw error
            }
        },
        didSave: { [weak self] command, ordinal in
            await self?.didSaveInput(command, ordinal: ordinal)
        }
    )

    private func saveInputLine(_ draft: LineDraft, id: String = UUID().uuidString) async throws -> Int {
        if let save = dependencies.saveInputLine { return try await save(draft, id) }
        return try await coordinator.appendLine(draft, id: id)
    }

    /// receiver 只认领输入并入队；所有保存与标题 IO 由唯一消费者承担。
    private func commitUserTurn(itemID: String, transcript: String, observedAt observed: Date) {
        defer { if !itemID.isEmpty { itemObservedAt.removeValue(forKey: itemID) } }
        guard inputLifecycle != .closed, let recordID = sessionID, sessionStartedAt != nil else { return }
        let ownsSlot = ownsPartial(itemID)
        let visible = ownsSlot ? partialText : nil
        let formalText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let formal = !formalText.isEmpty
        let text = formal ? formalText : (visible ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            if ownsSlot { clearPartialSlot() }
            return
        }
        let target: String
        switch inputLifecycle {
        case .active: target = recordID
        case .draining(let ending, let connection):
            guard connection == connectionToken else { return }
            target = ending ?? recordID
        case .closed: return
        }
        let command = AssistantInputPersistenceQueue.Command(
            sessionID: target, connection: connectionToken, itemID: itemID,
            text: text, formal: formal, observedAt: observed
        )
        switch inputPersistence.enqueue(command) {
        case .accepted, .duplicate:
            // 同步交接给可观察的队列后才释放字幕槽；拒绝输入时保留可见正文。
            if ownsSlot { clearPartialSlot() }
        case .capacityExceeded:
            lastFailure = "记录正在保存，暂时无法接纳这句新输入，请稍后重说。"
        case .invalidIdentity:
            lastFailure = "无法确认这句输入属于哪一场，请重试。"
        }
    }

    private func didSaveInput(_ command: AssistantInputPersistenceQueue.Command, ordinal: Int) async {
        if command.formal, sessionID == command.sessionID,
           inputLifecycle == .active,
           command.source == .keyboard || command.connection == connectionToken {
            lastFailure = nil
        }
        // M2/V06:自动标题是有身份、可等待的后台 effect,不挡正文投影与回答。
        // 先落正文、先生效回答资格,标题只在后台认领;标题失败只记原因,
        // 不覆盖正文、不阻塞 LLM 流。
        if command.formal, let name = SessionTitleSuggestion.suggest(from: command.text) {
            let titleSessionID = command.sessionID
            let titleLineID = command.lineID
            let titleText = name
            let titleTask = Task<Void, Never> { [weak self] in
                guard let self else { return }
                do {
                    if let claim = self.dependencies.claimTitle {
                        _ = try await claim(titleSessionID, titleLineID, titleText)
                    } else {
                        _ = try await self.coordinator.claimAutomaticTitle(
                            sessionID: titleSessionID, lineID: titleLineID, title: titleText
                        )
                    }
                } catch {
                    if self.sessionID == titleSessionID {
                        self.lastFailure = "内容已保存，但记录标题未保存：\(error.localizedDescription)"
                    }
                }
            }
            trackTitleEffect(titleTask)
        }
        // 旧连接仍完成自己的归档；当前 projection 与回答资格单独校验。
        guard sessionID == command.sessionID else { return }
        currentOrdinal = max(currentOrdinal, ordinal)
        if !turns.contains(where: { $0.id == command.lineID }) {
            turns.append(Turn(
                id: command.lineID, ordinal: ordinal, role: .user, text: command.text,
                source: command.source, isInterrupted: !command.formal,
                speakerLabel: nil, createdAt: command.observedAt
            ))
            turns.sort { $0.ordinal < $1.ordinal }
        }
        guard command.formal else {
            if command.connection == connectionToken { lastFailure = "这一句没能识别完整，请再说一次。" }
            return
        }
        if !contextTurns.contains(where: { $0.user.id == command.lineID }) {
            contextTurns.append(AssistantContextTurn(
                user: AssistantContextEntry(id: command.lineID, text: command.text), reply: nil
            ))
        }
        guard sessionID == command.sessionID,
              command.source == .keyboard || connectionToken == command.connection,
              inputLifecycle == .active, !isStoppingIntentionally else { return }
        submitTurn(
            questionID: command.lineID, text: command.text, source: command.source,
            spoken: command.source == .microphone
        )
    }

    // M2/V06:标题 effect 只登记自己的句柄,不等待、不阻塞调用方。
    private func trackTitleEffect(_ task: Task<Void, Never>) {
        titleEffect?.cancel()
        titleEffectID = UUID()
        titleEffect = task
    }

    // M2/V06:结束/收尾等待标题 effect,但有界——标题无响应不挡结束报告。
    private func drainTitleEffect(timeout: Duration = .seconds(2)) async {
        guard let effect = titleEffect else { return }
        let titleID = titleEffectID
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await effect.value }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            _ = await group.next()
            group.cancelAll()
        }
        if titleEffectID == titleID {
            titleEffect = nil
            titleEffectID = nil
        }
    }

    private func waitForInputSaves(sessionID: String, timeout: Duration = .seconds(8)) async -> Bool {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while !inputPersistence.pendingCommands(sessionID: sessionID).isEmpty,
              inputPersistence.failures(sessionID: sessionID).isEmpty,
              ContinuousClock().now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return inputPersistence.pendingCommands(sessionID: sessionID).isEmpty
            && inputPersistence.failures(sessionID: sessionID).isEmpty
    }

    /// 把增量 TTS 的发送、播放与终态接到现有连接 / 播放层上。
    /// 协调器不认识 WebSocket 与 AVAudioEngine 的细节，这里只做注入。
    private func makeTTSStreamCoordinator(
        client: any AssistantRealtimeClient,
        audioSession ownedAudioSession: (any AssistantAudioSession)?
    ) -> AssistantTTSStreamCoordinator {
        let tts = AssistantTTSStreamCoordinator()
        let audioWindowBytes = tts.audioWindowBytes
        tts.sendStart = { requestID in
            try await client.startTTSStream(
                requestID: requestID, speed: nil, audioWindowBytes: audioWindowBytes
            )
        }
        tts.sendAppend = { sequence, text in
            try await client.appendTTSText(text, sequence: sequence)
        }
        tts.sendFinish = { lastSequence in
            try await client.finishTTSText(lastSequence: lastSequence)
        }
        tts.sendCancel = { try await client.cancelTTS() }
        tts.sendAudioAcknowledgement = { requestID, sampleOffset in
            try await client.acknowledgeTTSAudio(requestID: requestID, sampleOffset: sampleOffset)
        }
        tts.enqueuePlayback = { pcm, epoch, chunkID in
            if let audioSession = ownedAudioSession {
                return await audioSession.enqueuePlayback(pcm, epoch: epoch, chunkID: chunkID)
            }
            return false
        }
        tts.stopPlayback = {
            if let audioSession = ownedAudioSession {
                await audioSession.stopPlayback()
            }
        }
        // 朗读前的清洗留在原处：屏幕、历史、SQLite 仍然只认**原始** LLM 文本。
        tts.cleanForSpeech = { VoicePrompt.spokenText(from: $0) }
        tts.onOutcome = { [weak self] generation, outcome in
            guard let self else { return }
            if let requestID = self.speechRequestIDs[generation],
               let request = self.speechRequests[requestID], request.sessionID == self.sessionID {
                let status: AssistantContextEntry.PlaybackStatus
                switch outcome {
                case .completed: status = .completed
                case .cancelled, .failed: status = .incomplete
                }
                self.projectPlaybackStatus(replyID: request.replyID, status: status)
            }
            guard generation == self.replyGeneration else { return }
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

    /// VA-04 submitTurn 统一入口：`ask` 与 ASR final 共用。
    ///
    /// 固定 questionID / replyID / source / 意图；接纳序列按单调 submission
    /// ordinal，两个 await 结束先后不改变顺序。默认第二问题停止前任并接管：
    /// 前任收尾按 replyID 认领旧记录（异步，不阻塞 receiver），新轮同步接管。
    /// 同步路径（语音 completed 经 receiver）不得跨 await 等旧轮落库，
    /// 否则 receiver 单线程被占，TTS 开轮与后续事件全部被堵。
    private func submitTurn(questionID: String, text: String, source: SessionLineSource, spoken: Bool) {
        submissionOrdinal &+= 1
        beginReply(spoken: spoken, questionID: questionID)
    }

    private func beginReply(spoken: Bool, questionID: String? = nil) {
        if currentReply != nil || ttsStream?.isActive == true {
            _ = requestReplyInterrupt()
        }
        replyGeneration &+= 1
        let generation = replyGeneration
        // 第二问题默认接管：前任先收尾，再开始新轮（VA-04/A12）。
        // 收尾按 replyID 认领旧记录，不清新轮状态（见 finalizeReply）。
        // 前任收尾异步进行（按 replyID 认领旧记录），新轮同步接管：
        // 顺序由 submissionOrdinal 与 replyID 保证，不靠等待旧轮落库。
        replyTask?.cancel()
        guard let sessionID else { return }
        currentReply = AssistantReplyState(
            sessionID: sessionID,
            generation: generation,
            source: spoken ? .microphone : .keyboard,
            startedAt: Date()
        )
        if let id = currentReply?.id, let questionID {
            replyQuestionIDs[id] = questionID
            replySpoken[id] = spoken
            replyPlayback[id] = .notRequested
        }
        replyTask = Task { [weak self] in
            await self?.runReply(spoken: spoken, generation: generation)
        }
    }

    /// 第一段非空正文到达时**建行**，之后只累计内存（方案 S4 第 2 条）。
    ///
    /// 不在每个 token 上写库：那既没必要，也会把 WAL 写满。崩溃前还没落库的那部分
    /// 本来就不承诺恢复——已经落库的那部分由 `sealAbandonedSessions` 封成
    /// final + interrupted（见 `SessionStore`），用户至少还能看到已经说过的话。
    // M2/V06:每个 reply 只有一个创建任务；创建与收尾共享固定行 ID。
    // 调用方 fire-and-forget,不 await 首次 INSERT；正文预览与内存累加不等建行。
    private var replyCreateTasks: [String: Task<Void, Never>] = [:]

    private func persistReplyPartial(generation: Int) {
        // VA-04：按 ID 认领，不用旧整个副本回写 currentReply。
        // 迟到 persist 返回时若新轮已接管，只更新匹配轮的 isPersisted/ordinal，
        // 保留当前较新的 text/revision。
        guard let replyID = currentReply?.id,
              currentReply?.generation == generation,
              currentReply?.isPersisted == false,
              currentReply?.hasSpeakableText == true
        else { return }
        guard let reply = currentReply, reply.id == replyID else { return }
        // 单创建任务：同一 replyID 只建一次行，重复调用直接返回。
        if replyCreateTasks[reply.id] != nil { return }
        let replyText = reply.text
        let replySessionID = reply.sessionID
        let replySource = reply.source
        let replyGeneration = reply.generation
        currentReply?.persistence = .persisting
        let createTask = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.runReplyCreate(
                replyID: reply.id,
                sessionID: replySessionID,
                source: replySource,
                generation: replyGeneration,
                initialText: replyText
            )
        }
        replyCreateTasks[reply.id] = createTask
    }

    private func runReplyCreate(
        replyID: String,
        sessionID: String,
        source: SessionLineSource,
        generation: Int,
        initialText: String
    ) async {
        defer { replyCreateTasks.removeValue(forKey: replyID) }
        do {
            let draft = LineDraft(
                sessionID: sessionID,
                role: .assistant,
                text: initialText,
                source: source,
                status: .partial
            )
            // M2/V06:测试可 gate 首次 INSERT；默认走 coordinator。
            let ordinal: Int
            if let save = dependencies.saveReplyLine {
                ordinal = try await save(draft, replyID)
            } else {
                ordinal = try await coordinator.appendLine(draft, id: replyID)
            }
            // 返回后重算当前身份：仍是同一轮才更新全文，否则只补旧轮标记。
            // 正文以 finalize 时的最新内存文本为准，这里只记“行已存在 + 序号”。
            if currentReply?.id == replyID {
                currentReply?.isPersisted = true
                currentReply?.ordinal = ordinal
                currentReply?.persistence = .persisted
            }
        } catch {
            // M2/V06:收尾可能在 drain 超时后经回退 INSERT 先建好同一行——
            // 此时撞主键不是失败，而是"行已存在"。按 id 核对后只补序号与
            // 已建标记，不报失败、不碰正文； genuinely 失败才走原路径。
            if let existing = try? await coordinator.lines(sessionID: sessionID, includePartial: true),
               let row = existing.first(where: { $0.id == replyID }) {
                if currentReply?.id == replyID {
                    currentReply?.isPersisted = true
                    currentReply?.ordinal = row.ordinal
                    if currentReply?.persistence == .persisting {
                        currentReply?.persistence = .persisted
                    }
                }
                return
            }
            // 建行失败不打断这一轮：正文还在内存里，收尾时会再试一次完整落库。
            if currentReply?.id == replyID {
                currentReply?.persistence = .idle
                lastFailure = "这一句正在生成，但暂时存不下来：\(error.localizedDescription)"
            }
        }
    }

    // M2/V06:收尾等待同一 replyID 的创建任务（同句柄、固定行 ID），
    // 有界等待——创建无响应不挡结束报告，finalize 会退回 INSERT 路径。
    private func drainReplyCreate(replyID: String, timeout: Duration = .seconds(2)) async {
        guard let task = replyCreateTasks[replyID] else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            _ = await group.next()
            group.cancelAll()
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
        // VA-04：共享 claim 在第一个 await 前登记，以 replyID 为键。
        // 重复收尾（stop/end/provider 失败争同一轮）只认领一次。
        guard !replyFinalizationClaims.contains(reply.id) else { return }
        replyFinalizationClaims.insert(reply.id)
        reply.isFinalized = true
        reply.termination = termination
        // VA-04：用最新可见正文收尾，不用调用时刻的旧快照覆盖新文本。
        let latestText: String
        if currentReply?.id == reply.id, let currentText = currentReply?.text {
            latestText = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            reply.text = currentText
        } else {
            latestText = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let text = latestText
        let isCurrent = currentReply?.id == reply.id
        if isCurrent { currentReply?.persistence = .finalizing }
        guard !text.isEmpty else {
            // 纯空白的一轮不留下伪造的正文行。
            if isCurrent { currentReply = nil }
            return
        }

        // M2/V06:收尾与创建同句柄、固定行 ID——先有界等创建任务，
        // 再试 UPDATE，不存在退回 INSERT。不依赖快照的 isPersisted。
        await drainReplyCreate(replyID: reply.id)
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
                let draft = LineDraft(
                    sessionID: reply.sessionID,
                    role: .assistant,
                    text: text,
                    source: reply.source,
                    status: .final,
                    isInterrupted: termination.marksInterrupted
                )
                let ordinal: Int
                if let save = dependencies.saveReplyLine {
                    ordinal = try await save(draft, reply.id)
                } else {
                    ordinal = try await coordinator.appendLine(draft, id: reply.id)
                }
                reply.ordinal = ordinal
                reply.isPersisted = true
            } catch {
                if currentReply?.id == reply.id {
                    currentReply?.persistence = .saveFailed(error.localizedDescription)
                    lastFailure = "这一句没能存下来：\(error.localizedDescription)"
                }
            }
        }

        // VA-04：旧操作可完成旧记录，但不能清新的 streamingReply/currentReply/phase。
        // 返回后重算当前身份：只有仍是同一轮才归位与投影 history/turns。
        let stillCurrent = currentReply?.id == reply.id
        // 正文状态按 question/reply ID 投影。旧回复仍可完成自己的历史，不能借完成时序配对。
        if sessionID == reply.sessionID {
            projectReplyContext(reply, termination: termination, text: text)
        }
        if let ordinal = reply.ordinal {
            for (requestID, accepted) in requestVoices where accepted.replyID == reply.id {
                await recordAcceptedVoice(requestID: requestID, ordinal: ordinal)
            }
        }
        guard sessionID == reply.sessionID else { return }
        if stillCurrent, currentReply?.id == reply.id {
            currentReply?.persistence = reply.isPersisted ? .saved : .saveFailed("正文未保存")
            currentReply = nil
        }
        if lastFinalizedReply?.ordinal ?? 0 <= reply.ordinal ?? 0 { lastFinalizedReply = reply }
        // 被打断的回复把**已经说出口的那部分**交给下一轮，不虚构余文，
        // 也不伪造一条"成功"的空消息。
        // VA-04：history 按 ID 投影一次，不靠完成时间 append 乱序。
        if !reply.historyApplied {
            reply.historyApplied = true
            lastFinalizedReply?.historyApplied = true
            // VA-12/A41：history 保持完整原文（不截同比例字符、不编造已听文本）；
            // 交付状态由 turns.isInterrupted 与 playbackDeliveryNotes 承载，
            // 不污染模型上下文。
            if termination.marksInterrupted, replyPlayback[reply.id] == .incomplete,
               playbackDeliveryNotes[reply.id] == nil {
                playbackDeliveryNotes[reply.id] =
                    "朗读未完成；未有可靠逐字对齐，仅以上全文为准。"
            }
        }
        if stillCurrent, currentReply == nil { streamingReply = nil }
        if !turns.contains(where: { $0.id == reply.id }) {
            turns.append(Turn(
                id: reply.id,
                ordinal: reply.ordinal ?? (currentOrdinal + 1),
                role: .assistant,
                text: text,
                source: reply.source,
                isInterrupted: termination.marksInterrupted,
                speakerLabel: nil,
                createdAt: reply.startedAt
            ))
            turns.sort { $0.ordinal < $1.ordinal }
        }
        if let ordinal = reply.ordinal { currentOrdinal = max(currentOrdinal, ordinal) }
    }

    private func projectReplyContext(
        _ reply: AssistantReplyState, termination: AssistantReplyState.Termination, text: String
    ) {
        guard let questionID = replyQuestionIDs[reply.id],
              let index = contextTurns.firstIndex(where: { $0.user.id == questionID }) else { return }
        let status: AssistantContextEntry.GenerationStatus
        switch termination {
        case .completed: status = .completed
        case .failed: status = .failed
        case .interrupted: status = .interrupted
        case .streaming: status = .unknown
        }
        let previousPlayback = replyPlayback[reply.id] ?? contextTurns[index].reply?.playbackStatus
        contextTurns[index] = AssistantContextTurn(
            user: contextTurns[index].user,
            reply: AssistantContextEntry(
                id: reply.id, text: text, generationStatus: status,
                playbackStatus: previousPlayback ?? .notRequested
            )
        )
    }

    private func projectPlaybackStatus(replyID: String, status: AssistantContextEntry.PlaybackStatus) {
        replyPlayback[replyID] = status
        guard let questionID = replyQuestionIDs[replyID],
              let index = contextTurns.firstIndex(where: { $0.user.id == questionID }),
              let reply = contextTurns[index].reply else { return }
        contextTurns[index] = AssistantContextTurn(
            user: contextTurns[index].user,
            reply: AssistantContextEntry(
                id: reply.id, text: reply.text, generationStatus: reply.generationStatus,
                playbackStatus: status
            )
        )
    }

    /// 完整生成、也已经定稿，但朗读还没放完时用户按了停止（D08 第 5 条的后半段）。
    /// 正文已经是完整的，这一行要改的只有"没听完"这一个标记——
    /// `finalizeAssistantLine` 的 SQL 只把 `interrupted` 从 false 推向 true，
    /// 所以重复调用是安全的。
    private func markLastReplyInterruptedAfterPlaybackCut(reply snapshot: AssistantReplyState? = nil) async {
        guard let reply = snapshot ?? lastFinalizedReply, reply.termination == .completed else { return }
        do {
            _ = try await coordinator.finalizeAssistantLine(
                sessionID: reply.sessionID,
                lineID: reply.id,
                text: reply.text.trimmingCharacters(in: .whitespacesAndNewlines),
                interrupted: true
            )
            if lastFinalizedReply?.id == reply.id { lastFinalizedReply?.termination = .interrupted }
            if sessionID == reply.sessionID {
                // 生成已完成；这里只补播放状态，保留 generation completed 与原文。
                projectPlaybackStatus(replyID: reply.id, status: .incomplete)
                playbackDeliveryNotes[reply.id] = "朗读未完成；已保留完整文字。"
            }
            if let index = turns.indices.last, turns[index].id == reply.id {
                turns[index].isInterrupted = true
            }
        } catch {
            if sessionID == reply.sessionID, lastFinalizedReply?.id == reply.id {
                lastFailure = "打断标记没能存下来：\(error.localizedDescription)"
            }
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

        // VA-06：runReply 从冻结快照取 route，不再中途重解析 preferences。
        // 快照缺失（极端路径）时回退一次解析并冻结，保证后续轮次不再漂移。
        let resolved: ResolvedLLMConfiguration
        if let snapshot = frozenRoute {
            let fresh = preferences.resolvedLLMConfiguration(
                for: .assistant,
                globalAPIKey: apiKeyProvider(),
                moduleAPIKey: moduleAPIKeyProvider(.assistant)
            )
            // 快照存在时仍以快照为准：会话内 endpoint/model/origin 不漂移。
            resolved = ResolvedLLMConfiguration(
                configuration: LLMConfiguration(
                    baseURL: snapshot.endpoint,
                    model: snapshot.model,
                    compatibilityMode: fresh.configuration.compatibilityMode
                ),
                apiKey: fresh.apiKey,
                origin: snapshot.origin
            )
        } else {
            resolved = preferences.resolvedLLMConfiguration(
                for: .assistant,
                globalAPIKey: apiKeyProvider(),
                moduleAPIKey: moduleAPIKeyProvider(.assistant)
            )
            frozenRoute = FrozenRoute(
                endpoint: resolved.configuration.normalizedBaseURL,
                model: resolved.configuration.model,
                origin: resolved.origin
            )
        }
        let configuration = resolved.configuration
        let key = resolved.apiKey
        guard let replyID = currentReply?.id, let questionID = replyQuestionIDs[replyID],
              let questionIndex = contextTurns.firstIndex(where: { $0.user.id == questionID }) else { return }
        let context: AssistantContextRequestContext
        contextOmissionNote = nil
        do {
            context = try AssistantContextPolicy.buildRequestContext(
                instructions: VoicePrompt.instructionsFor(
                    input: spoken ? .recognizedSpeech : .keyboard,
                    output: spoken ? .spokenConcise : .textOnly
                ),
                persona: persona.map { VoicePrompt.styleBlock($0.body) },
                memories: memories,
                history: Array(contextTurns[..<questionIndex]),
                currentQuestion: contextTurns[questionIndex].user
            )
            if context.omittedHistoryTurns > 0 || context.omittedMemories > 0 {
                contextOmissionNote = "本次回答未参考 \(context.omittedHistoryTurns) 轮对话和 \(context.omittedMemories) 条记忆；完整记录仍保留。"
            } else {
                contextOmissionNote = nil
            }
        } catch {
            lastFailure = error.localizedDescription
            phase = .listening
            currentReply = nil
            streamingReply = nil
            return
        }

        phase = .thinking
        streamingReply = ""
        var reply = ""
        // M0e：默认确认后朗读——流式循环不再开嗓，不再需要开嗓门闩与
        // 增量可用标志；朗读统一走完整终态后的确认计划。
        do {
            try Task.checkCancellation()
            for try await delta in await provider.stream(
                configuration: configuration,
                messages: context.messages,
                apiKey: key,
                maxOutputTokens: context.maxOutputTokens,
                // VA-10：顶层 instructions 按实际模态每轮组装。
                // spoken 才用朗读契约；文字用文字契约，不套 ASR 容错。
                instructions: context.instructions
            ) {
                try Task.checkCancellation()
                guard generation == replyGeneration else { return }
                reply += delta
                streamingReply = reply
                // 同一轮只有一个身份：流式正文、库里那一行、界面那一行都挂在它下面（D08）。
                // 这一句的时刻按**开始回答**算，不是按它说完算：生成要几秒，
                // 用结束时刻会让时间码落在那一句之后（稿行右侧那个 `14:02:16`）。
                currentReply?.text = reply
                // M2/V06:第一次出现非空白正文时按固定 id 建行；之后只 UPDATE。
                // 首 delta 只进有界预览与内存累加，不等首次 INSERT，不挡正文消费。
                persistReplyPartial(generation: generation)
                // 屏幕与落库永远用**原始**文本。M0e：未定稿不开口——流式 delta
                // 只做预览与落库，不开嗓、不喂增量；朗读等完整终态后走确认计划。
                continue
            }
        } catch is CancellationError {
            // 取消不是失败：谁按下停止，谁负责收尾（`interruptCurrentReply` /
            // `stopCapture`）。这一路只把界面上的流式文本收掉。
            if generation == replyGeneration {
                streamingReply = nil
            }
            return
        } catch let error as LLMError where error == .cancelled {
            // V07:provider 侧取消（`URLSession` 取消映射的 `.cancelled`）同样不是失败，
            // 与原生 `CancellationError` 同一语义：只收界面文本，不记失败、不走失败收尾。
            // 若落到下面的通用失败分支，"用户按了取消"会被记成一次回答失败。
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
            let effect = requestReplyInterrupt(termination: .failed(message))
            let failureGeneration = replyGeneration
            let failureSession = sessionID
            let failureConnection = connectionToken
            _ = await effect.value
            if sessionID == failureSession, connectionToken == failureConnection, replyGeneration == failureGeneration {
                lastFailure = message
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
        // M0e：完整终态后才确认朗读计划。定稿原文 → 整体解析/保义转换 →
        // 计划文本 TTS → 播放确认。计划超限则暂停朗读保留全文，不硬切不开口。
        if spoken, let stream = ttsStream {
            guard generation == replyGeneration else { return }
            // 上一轮远端归属未确认时不开新轮：由调用方走显式重试。
            if let effect = interruptEffect {
                let confirmed = await effect.value
                guard generation == replyGeneration else { return }
                guard confirmed, ttsStream === stream else {
                    lastFailure = "上一轮朗读尚未确认结束，请重试语音。"
                    if phase == .thinking { phase = .listening }
                    return
                }
            }
            if selectedVoice != nil {
                guard await applyLatestVoice() else {
                    lastFailure = "所选音色尚未准备好，请重试。"
                    if phase == .thinking { phase = .listening }
                    return
                }
                guard generation == replyGeneration else { return }
            }
            let requestID = "tts_req_\(UUID().uuidString.lowercased())"
            let selection = selectedVoice
            let requestVoice = activeRealtimeBinding?.canonicalVoiceID ?? voiceID
            let startID = UUID()
            voiceStartID = startID
            defer {
                if voiceStartID == startID { voiceStartID = nil }
            }
            if let state = currentReply {
                speechRequests[requestID] = (state.sessionID, state.id)
                speechRequestIDs[generation] = requestID
                replyPlayback[state.id] = .unknown
                if let selection, let requestVoice {
                    requestVoices[requestID] = RequestVoice(
                        replyID: state.id, sessionID: state.sessionID,
                        selection: selection, voice: requestVoice
                    )
                }
            }
            do {
                try await stream.begin(
                    generation: generation,
                    requestID: requestID
                )
            } catch {
                guard generation == replyGeneration else { return }
                lastFailure = error.localizedDescription
                if phase == .thinking { phase = .listening }
                return
            }
            if let state = currentReply, state.generation == generation,
               let ordinal = state.ordinal {
                await recordAcceptedVoice(requestID: requestID, ordinal: ordinal)
            }
            guard generation == replyGeneration else { return }
            do {
                try await stream.speakConfirmedPlan(replyState.text)
                // 关输入之后仍然继续收音频；这里只保证"没 ACK 的文本不会越过 finish"。
                await stream.finishInput()
                // 确认计划已开嗓：朗读态由首个音频到达 Boo 认（receiver .ttsAudio），
                // 无音频回包时保持 thinking 直至终态收尾，不伪造 speaking。
            } catch {
                guard generation == replyGeneration else { return }
                // 超限/计划失败：暂停朗读，保留全文与落库，不开口。
                if phase == .thinking { phase = .listening }
                return
            }
        }
        guard generation == replyGeneration, currentReply?.id == replyState.id else { return }
        // 朗读被打断过就按打断收尾，否则按正常完成收尾。两者写的是同一行。
        await finalizeReply(
            replyState.termination == .interrupted ? .interrupted : .completed,
            reply: replyState
        )
        if !spoken { phase = .listening }
    }

    private func scheduleUnexpectedClose(code: Int?) {
        guard !isStoppingIntentionally, let closedClient = client else { return }
        let token = startToken
        let connection = connectionToken
        let recordID = sessionID
        let reply = currentReply
        let closedAudio = audioSession
        let closedSource = source
        let closedPlayback = playback
        let reason = code.map { "语音服务断开了连接（\($0)）。" } ?? "语音服务断开了连接。"
        invalidateReply()
        ttsStream?.invalidate()
        ttsStream = nil
        client = nil
        audioSession = nil
        source = nil
        playback = nil
        stopPumpTasks()
        level = 0
        clearPartialSlot()
        isSpeaking = false
        isMutedForPlayback = false
        blocked = .streamFailed(reason)
        phase = .paused
        let effectID = UUID()
        transportCloseEffectID = effectID
        transportCloseEffect = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.transportCloseEffectID == effectID {
                    self.transportCloseEffect = nil
                    self.transportCloseEffectID = nil
                }
            }
            if let closedAudio { closedAudio.stop() } else { closedSource?.stop() }
            await closedPlayback?.stop()
            await closedClient.close()
            if let reply { await self.finalizeReply(.interrupted, reply: reply) }
            guard self.startToken == token, self.connectionToken == connection,
                  self.coordinator.activeSessionID == recordID,
                  self.coordinator.occupancy?.kind == .assistant else { return }
            _ = await self.coordinator.markInterruption(.serviceLost, atOrdinal: self.currentOrdinal)
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

    /// VA-07：只关闭语音（释放 transport 与设备），保留本场
    /// record/history/context。typed 继续同场；与 mute 分开：
    /// mute 只停上传，closeVoice 释放设备。
    public func closeVoiceKeepingText() async {
        guard phase != .ending else { return }
        startToken &+= 1
        let token = startToken
        let recordID = sessionID
        let closingReply = currentReply
        isStoppingIntentionally = true
        retryTask?.cancel()
        retryTask = nil
        voiceApplication?.cancel()
        voiceApplication = nil
        voiceApplicationID = nil
        let interrupt = requestReplyInterrupt()
        invalidateReply()
        if let effect = transportCloseEffect { await effect.value }
        _ = await interrupt.value
        guard startToken == token, sessionID == recordID, phase != .ending else { return }
        // 共享的旧 effect 可能属于前一回复；关闭时的当前正文也必须明确收尾。
        if let closingReply {
            await finalizeReply(.interrupted, reply: closingReply)
            guard startToken == token, sessionID == recordID, phase != .ending else { return }
        }
        let closingClient = client
        let closingPlayback = playback
        client = nil
        playback = nil
        stopPumpTasks()
        connectionToken &+= 1
        ttsStream?.invalidate()
        ttsStream = nil
        if let audioSession {
            audioSession.stop()
            self.audioSession = nil
        } else {
            source?.stop()
        }
        source = nil
        await closingPlayback?.stop()
        await closingClient?.close()
        guard startToken == token, sessionID == recordID, phase != .ending else { return }
        isSpeaking = false
        isMutedForPlayback = false
        isStoppingIntentionally = false
        blocked = nil
        // record/history/context/frozenRoute/memories 一律保留，typed 继续同场。
        phase = .listening
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
