import Foundation

// 会话三能力的领域类型。**取值一律对着库里的取值域写**（SESSIONS-SPEC §15.2 / §15.6 R1 / §15.7 R2），
// 所以这里的 `rawValue` 不是内部实现细节：它就是列里那一串字符，改它等于改数据。
//
// 一条最容易搞错的规矩（§15.7 末注）：**中断是事件，不是阶段**。库里 `session.state` 只有
// `recording` / `processing` / `archived`；「这次断过」由未闭合的 `session_interruption` 行推出。
// 所以 `SessionPhase` 里的 `.interrupted` 是**界面的**相位，`SessionRecordState` 才是库里的。

// MARK: - 能力

public enum SessionKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case assistant
    case meeting
    case captions
    case teleprompter

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .assistant: "语音助手"
        case .meeting: "会议助手"
        case .captions: "实时字幕"
        case .teleprompter: "AI 提词器"
        }
    }

    /// 侧边栏占用行与状态带里的短名（「实时字幕进行中」这类句子由调用点拼）。
    public var shortTitle: String {
        switch self {
        case .assistant: "语音助手"
        case .meeting: "会议助手"
        case .captions: "实时字幕"
        case .teleprompter: "AI 提词器"
        }
    }

    public var systemImage: String {
        switch self {
        case .assistant: "message.circle"
        case .meeting: "person.2"
        case .captions: "captions.bubble"
        case .teleprompter: "text.bubble"
        }
    }

    public var route: AppRoute {
        switch self {
        case .assistant: .assistant
        case .meeting: .meeting
        case .captions: .captions
        case .teleprompter: .teleprompter
        }
    }

    public var persistencePolicy: SessionPersistencePolicy {
        switch self {
        case .teleprompter: .ephemeral
        case .assistant, .meeting, .captions: .persistent
        }
    }
}

public enum SessionPersistencePolicy: String, Codable, Sendable {
    case persistent
    case ephemeral
}

// MARK: - 库里的取值域

/// `session.state`。只有三种；中断不在其中（§15.7）。
public enum SessionRecordState: String, Codable, Sendable, CaseIterable {
    case recording
    case processing
    case archived
}

/// 每个 `line.source` 来自哪一路；`keyboard` 是打字输入，不是音频（§15.7 R2 ③）。
public enum SessionLineSource: String, Codable, Sendable {
    case microphone
    case system
    case mixed
    case keyboard
}

/// `session.audio_source`：本次选的采集来源配置。**没有 `keyboard`**——它描述采集，不描述提问方式。
public enum SessionAudioSource: String, Codable, Sendable {
    case microphone
    case system
    case mixed

    public var title: String {
        switch self {
        case .microphone: "麦克风"
        case .system: "本机音频"
        case .mixed: "麦克风 + 本机音频"
        }
    }
}

public enum SessionDiarizationState: String, Codable, Sendable {
    case off
    case active
    case degraded
    case unavailable
}

public enum SessionEndReason: String, Codable, Sendable {
    case user
    case interrupted
    case unexpectedExit = "unexpected_exit"

    public var title: String {
        switch self {
        case .user: "已结束"
        case .interrupted: "中断后结束"
        case .unexpectedExit: "意外退出"
        }
    }
}

public enum SessionInterruptionReason: String, Codable, Sendable {
    case serviceLost = "service_lost"
    case sleep
    case sourceLost = "source_lost"
    case unexpectedExit = "unexpected_exit"

    /// 直接拿来写界面文案（用户的问法是「这一段到底录没录上」）。
    public var title: String {
        switch self {
        case .serviceLost: "语音服务断开"
        case .sleep: "Mac 睡眠"
        case .sourceLost: "音频来源中断"
        case .unexpectedExit: "应用意外退出"
        }
    }
}

public enum SessionLineRole: String, Codable, Sendable {
    case speaker
    case user
    case assistant
}

public enum SessionLineStatus: String, Codable, Sendable {
    case partial
    case final
}

public enum SessionTimingQuality: String, Codable, Sendable {
    case aligned
    case unavailable
}

public enum MinutesStatus: String, Codable, Sendable {
    case queued
    case running
    case ready
    case failed

    /// 界面上那个胶囊的字（与 `MinutesGenerator.State.title` 同一套词）。
    public var title: String {
        switch self {
        case .queued: "排队中"
        case .running: "整理中"
        case .ready: "已生成"
        case .failed: "没整理出来"
        }
    }
}

public enum InnerOSIntent: String, Codable, Sendable {
    case fact
    case analysis
    case draft
    case mixed
}

public enum InnerOSConfidence: String, Codable, Sendable {
    case low
    case medium
    case high

    /// 答案卡上那个胶囊的字。**不确定度是要给用户看的**：判断与事实分开，
    /// 也就是为了让这一格有意义（§5.9）。
    public var label: String {
        switch self {
        case .high: "较有把握"
        case .medium: "中等把握"
        case .low: "不太确定"
        }
    }
}

public enum InnerOSStatus: String, Codable, Sendable {
    case generating
    case ready
    case cancelled
    case failed
}

public enum AssistantMemoryKind: String, Codable, Sendable {
    case fact
    case preference
    case summary
}

// MARK: - 时间点快照（跨存储只靠快照连接，不靠外键）

/// 人设快照。**会话开始写一次，之后不接受更新**（§14.4：换人设会让前缀缓存整段失效）。
public struct PersonaSnapshot: Hashable, Sendable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// 音色快照。音色被删或改名之后，旧记录仍然说得清「当时用的是谁」（TECHNICAL-DESIGN §6.6）。
public struct VoiceSnapshot: Hashable, Sendable {
    public var id: String
    public var name: String?

    public init(id: String, name: String? = nil) {
        self.id = id
        self.name = name
    }
}

// MARK: - 记录

/// `session` 一行。
public struct SessionRecord: Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: SessionKind
    public var title: String?
    public var state: SessionRecordState
    public var createdAt: Date
    public var startedAt: Date
    public var endedAt: Date?
    public var engineProfile: String
    public var audioSource: SessionAudioSource
    public var diarization: SessionDiarizationState
    public var diarizationNote: String?
    public var llmEndpoint: String?
    public var llmModel: String?
    public var persona: PersonaSnapshot?
    public var voice: VoiceSnapshot?
    /// 空 = `user`（§15.6 R1：既有行为不用改）。
    public var endReason: SessionEndReason?

    public init(
        id: String,
        kind: SessionKind,
        title: String? = nil,
        state: SessionRecordState,
        createdAt: Date,
        startedAt: Date,
        endedAt: Date? = nil,
        engineProfile: String,
        audioSource: SessionAudioSource,
        diarization: SessionDiarizationState = .off,
        diarizationNote: String? = nil,
        llmEndpoint: String? = nil,
        llmModel: String? = nil,
        persona: PersonaSnapshot? = nil,
        voice: VoiceSnapshot? = nil,
        endReason: SessionEndReason? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.state = state
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.engineProfile = engineProfile
        self.audioSource = audioSource
        self.diarization = diarization
        self.diarizationNote = diarizationNote
        self.llmEndpoint = llmEndpoint
        self.llmModel = llmModel
        self.persona = persona
        self.voice = voice
        self.endReason = endReason
    }

    public var endedReason: SessionEndReason { endReason ?? .user }
}

/// `line` 一行（转录 / 字幕 / 对话正文共用）。
public struct TranscriptLine: Identifiable, Hashable, Sendable {
    public var id: String
    public var sessionID: String
    public var ordinal: Int
    public var role: SessionLineRole
    /// 分人匿名标签 `A`…`D`，会话内唯一；不是实名（服务只输出匿名 label）。
    public var speakerLabel: String?
    public var text: String
    public var tStart: TimeInterval?
    public var tEnd: TimeInterval?
    public var source: SessionLineSource
    public var status: SessionLineStatus
    /// 助手的这一句被用户打断（§14.5）。**不是错误**，与 `status == .partial` 是两件事。
    public var isInterrupted: Bool
    public var isDeviceSwitch: Bool
    public var isStarred: Bool
    public var timingQuality: SessionTimingQuality?
    public var createdAt: Date

    public init(
        id: String,
        sessionID: String,
        ordinal: Int,
        role: SessionLineRole,
        speakerLabel: String? = nil,
        text: String,
        tStart: TimeInterval? = nil,
        tEnd: TimeInterval? = nil,
        source: SessionLineSource,
        status: SessionLineStatus = .final,
        isInterrupted: Bool = false,
        isDeviceSwitch: Bool = false,
        isStarred: Bool = false,
        timingQuality: SessionTimingQuality? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.ordinal = ordinal
        self.role = role
        self.speakerLabel = speakerLabel
        self.text = text
        self.tStart = tStart
        self.tEnd = tEnd
        self.source = source
        self.status = status
        self.isInterrupted = isInterrupted
        self.isDeviceSwitch = isDeviceSwitch
        self.isStarred = isStarred
        self.timingQuality = timingQuality
        self.createdAt = createdAt
    }

    /// SRT 时间码与导出物一律从 `tStart` 取（§6.5）。没有时间戳的行导不出时间码。
    public var hasTimecode: Bool { tStart != nil }
}

/// 记录库列表用的摘要。`openInterruption` 是**查出来的**事实，不是存出来的字段。
public struct SessionSummary: Identifiable, Hashable, Sendable {
    public var record: SessionRecord
    public var lineCount: Int
    public var speakerCount: Int
    public var openInterruption: SessionInterruptionReason?
    public var latestMinutesStatus: MinutesStatus?

    public var id: String { record.id }

    public init(
        record: SessionRecord,
        lineCount: Int,
        speakerCount: Int,
        openInterruption: SessionInterruptionReason? = nil,
        latestMinutesStatus: MinutesStatus? = nil
    ) {
        self.record = record
        self.lineCount = lineCount
        self.speakerCount = speakerCount
        self.openInterruption = openInterruption
        self.latestMinutesStatus = latestMinutesStatus
    }

    /// 会话时长：结束后取封存值，进行中由调用点传「现在」。
    public func duration(now: Date = Date()) -> TimeInterval {
        let end = record.endedAt ?? (record.state == .archived ? record.startedAt : now)
        return max(0, end.timeIntervalSince(record.startedAt))
    }
}

public struct SessionInterruption: Identifiable, Hashable, Sendable {
    public var id: String
    public var sessionID: String
    public var atOrdinal: Int
    public var reason: SessionInterruptionReason
    /// 空 = 没有续接，这一段到此为止。
    public var resumedAt: Date?
    public var createdAt: Date

    public init(
        id: String,
        sessionID: String,
        atOrdinal: Int,
        reason: SessionInterruptionReason,
        resumedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.atOrdinal = atOrdinal
        self.reason = reason
        self.resumedAt = resumedAt
        self.createdAt = createdAt
    }
}

public struct SessionChange: Identifiable, Hashable, Sendable {
    public var id: String
    public var atOrdinal: Int
    public var kind: String
    public var value: String
    public var createdAt: Date

    public init(id: String, atOrdinal: Int, kind: String = "voice", value: String, createdAt: Date = Date()) {
        self.id = id
        self.atOrdinal = atOrdinal
        self.kind = kind
        self.value = value
        self.createdAt = createdAt
    }
}

/// 纪要的一个版本。重新生成只新增版本，不覆盖旧版。
public struct MinutesVersion: Identifiable, Hashable, Sendable {
    public var id: String
    public var sessionID: String
    public var version: Int
    public var status: MinutesStatus
    /// Markdown；`status == .queued` 时为空。
    public var body: String?
    public var model: String?
    /// 只存长度：项目约束不允许记录完整 prompt。
    public var promptChars: Int?
    public var isLatest: Bool
    public var attempts: Int
    public var failureReason: String?
    public var leaseUntil: Date?
    public var createdAt: Date

    public init(
        id: String,
        sessionID: String,
        version: Int,
        status: MinutesStatus,
        body: String? = nil,
        model: String? = nil,
        promptChars: Int? = nil,
        isLatest: Bool = false,
        attempts: Int = 0,
        failureReason: String? = nil,
        leaseUntil: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.version = version
        self.status = status
        self.body = body
        self.model = model
        self.promptChars = promptChars
        self.isLatest = isLatest
        self.attempts = attempts
        self.failureReason = failureReason
        self.leaseUntil = leaseUntil
        self.createdAt = createdAt
    }
}

public struct InnerOSExchange: Identifiable, Hashable, Sendable {
    public var id: String
    public var sessionID: String
    public var askedAt: Date
    /// 提问时的转录水位。
    public var atOrdinal: Int?
    public var question: String
    public var intent: InnerOSIntent?
    public var answerText: String?
    public var draftText: String?
    public var confidence: InnerOSConfidence?
    public var limitsNote: String?
    public var model: String?
    public var status: InnerOSStatus
    /// 「写进纪要」是显式动作，默认 0（§14.2）。
    public var inMinutes: Bool

    public init(
        id: String,
        sessionID: String,
        askedAt: Date = Date(),
        atOrdinal: Int? = nil,
        question: String,
        intent: InnerOSIntent? = nil,
        answerText: String? = nil,
        draftText: String? = nil,
        confidence: InnerOSConfidence? = nil,
        limitsNote: String? = nil,
        model: String? = nil,
        status: InnerOSStatus = .generating,
        inMinutes: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.askedAt = askedAt
        self.atOrdinal = atOrdinal
        self.question = question
        self.intent = intent
        self.answerText = answerText
        self.draftText = draftText
        self.confidence = confidence
        self.limitsNote = limitsNote
        self.model = model
        self.status = status
        self.inMinutes = inMinutes
    }
}

/// 内心 OS 答案引用的那一行原文。`lineID` 允许为空（那一行可能已被移除），
/// 所以渲染时**先把 `quote` 当作事实**，不要假定还能顺着 id 找回正文。
public struct InnerOSEvidence: Identifiable, Hashable, Sendable {
    public var id: String
    public var lineID: String?
    public var speakerLabel: String?
    public var tStart: TimeInterval?
    public var quote: String?
    public var contentHash: String?

    public init(
        id: String = UUID().uuidString,
        lineID: String? = nil,
        speakerLabel: String? = nil,
        tStart: TimeInterval? = nil,
        quote: String? = nil,
        contentHash: String? = nil
    ) {
        self.id = id
        self.lineID = lineID
        self.speakerLabel = speakerLabel
        self.tStart = tStart
        self.quote = quote
        self.contentHash = contentHash
    }
}

/// 助手的长期信息：与某一次会话解耦，会话被移除时它仍然留着。
public struct AssistantMemory: Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: AssistantMemoryKind
    public var body: String
    public var sourceSessionID: String?
    public var isActive: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        kind: AssistantMemoryKind,
        body: String,
        sourceSessionID: String? = nil,
        isActive: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.body = body
        self.sourceSessionID = sourceSessionID
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// 记录名：用户不取名时，用**第一句**顶上来。
///
/// 为什么要有它（2026-09-19 用户验收："记录和纪要是资产"）：一条记录不取名，记录库那一列
/// 就是一排「未命名 + 时间 + N 句」，翻起来认不出哪条是哪条，而"继续这一轮"、"导出"、
/// "重命名"这些动作都要先认得它。第一句是这段对话里**唯一一处用户可以自己认领的标签**，
/// 拿它当名字比"未命名"有用，也比让模型编一个标题诚实（用户改名之后以改名为准：
/// 那一列只由人来写，这个建议只用一次）。
///
/// 取法（列表一行只放得下这么多，宁可短也不能折一半）：
/// 1. 压掉所有换行与多余空白——名字是一行字；
/// 2. 先取到第一个句末（`。！？`）为止；这一句短到不足 6 个字，就把下一句也接上，
///    免得名字只有"嗯"、"那个"这种没有信息量的一句；
/// 3. 还是太长就砍到 20 个字，优先断在最后一个逗号处（读起来是半句而不是断字），加省略号。
public enum SessionTitleSuggestion {
    /// 名字最多几个字。列表行的宽度与"一眼扫得过去"共同定下来的数。
    public static let maxLength = 20

    private static let sentenceEnders: Set<Character> = ["。", "！", "？", "!", "?", "."]
    private static let softBreaks: Set<Character> = ["，", "、", ",", "；", ";", "：", ":", " "]

    public static func suggest(from text: String) -> String? {
        let flat = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "「」“”\"'"))
        guard !flat.isEmpty else { return nil }

        // 第 2 步：句末之前的部分。整段都没有句末时就是整段（后面按长度收）。
        var head = ""
        var rest = Substring(flat)
        while let enderIndex = rest.firstIndex(where: { sentenceEnders.contains($0) }) {
            head += rest[rest.startIndex..<enderIndex]
            rest = rest[rest.index(after: enderIndex)...]
            if head.count >= 6 { break }
            head += "，"   // 太短就把下一句接上，句读用逗号
        }
        if head.isEmpty { head = flat }

        let trimmedHead = head.trimmingCharacters(in: CharacterSet(charactersIn: "，、,；;：: "))
        guard !trimmedHead.isEmpty else { return nil }
        guard trimmedHead.count > maxLength else { return trimmedHead }

        // 第 3 步：砍到 20 个字，能断在逗号处就断在逗号处。
        let clipped = trimmedHead.prefix(maxLength)
        if let breakIndex = clipped.lastIndex(where: { softBreaks.contains($0) }),
           clipped.distance(from: clipped.startIndex, to: breakIndex) >= 8 {
            return String(clipped[clipped.startIndex..<breakIndex]) + "…"
        }
        return String(clipped) + "…"
    }
}

// MARK: - 建行 / 落行的输入

/// `createSession` 的输入。只在**首个 PCM 已发送**时调用（§6.4）。
public struct SessionDraft: Sendable {
    public var kind: SessionKind
    public var engineProfile: String
    public var audioSource: SessionAudioSource
    public var diarization: SessionDiarizationState
    public var diarizationNote: String?
    public var llmEndpoint: String?
    public var llmModel: String?
    public var persona: PersonaSnapshot?
    public var voice: VoiceSnapshot?
    public var startedAt: Date
    public var title: String?

    public init(
        kind: SessionKind,
        engineProfile: String,
        audioSource: SessionAudioSource,
        diarization: SessionDiarizationState = .off,
        diarizationNote: String? = nil,
        llmEndpoint: String? = nil,
        llmModel: String? = nil,
        persona: PersonaSnapshot? = nil,
        voice: VoiceSnapshot? = nil,
        title: String? = nil,
        startedAt: Date = Date()
    ) {
        self.kind = kind
        self.engineProfile = engineProfile
        self.audioSource = audioSource
        self.diarization = diarization
        self.diarizationNote = diarizationNote
        self.llmEndpoint = llmEndpoint
        self.llmModel = llmModel
        self.persona = persona
        self.voice = voice
        self.title = title
        self.startedAt = startedAt
    }
}

/// `appendLine` 的输入。`ordinal` 由库分配（§15.7 R2 ①：取号与插入同一事务）。
public struct LineDraft: Sendable {
    public var sessionID: String
    public var role: SessionLineRole
    public var text: String
    public var source: SessionLineSource
    public var speakerLabel: String?
    public var tStart: TimeInterval?
    public var tEnd: TimeInterval?
    public var status: SessionLineStatus
    public var isInterrupted: Bool
    public var isDeviceSwitch: Bool
    public var timingQuality: SessionTimingQuality?

    public init(
        sessionID: String,
        role: SessionLineRole,
        text: String,
        source: SessionLineSource,
        speakerLabel: String? = nil,
        tStart: TimeInterval? = nil,
        tEnd: TimeInterval? = nil,
        status: SessionLineStatus = .final,
        isInterrupted: Bool = false,
        isDeviceSwitch: Bool = false,
        timingQuality: SessionTimingQuality? = nil
    ) {
        self.sessionID = sessionID
        self.role = role
        self.text = text
        self.source = source
        self.speakerLabel = speakerLabel
        self.tStart = tStart
        self.tEnd = tEnd
        self.status = status
        self.isInterrupted = isInterrupted
        self.isDeviceSwitch = isDeviceSwitch
        self.timingQuality = timingQuality
    }
}
