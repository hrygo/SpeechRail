import Foundation
import Observation

// 「新会话的预填值」（`TECHNICAL-DESIGN` §5.12、`SESSIONS-SPEC` §15.4）。
//
// 这一层只放**偏好**：它决定下一场会话从什么值起步。每一场的实际取值随会话落库
// （`session.llm_model` / `persona_id` / `voice_id` / `diarization`），所以改了偏好
// 不会改写历史记录——这也是"库里那份是为了复现"的意思。
//
// 一条硬规矩：**密钥不在这里**。它只进钥匙串（`LLMKeychain`），这里最多知道"有没有"。

/// 助手的两种模式（§14.5）。差别只有一个：**能不能打断它**。
public enum AssistantMode: String, CaseIterable, Identifiable, Sendable {
    case turnTaking
    case duplex

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .turnTaking: "一问一答（外放）"
        case .duplex: "实时对讲（耳机）"
        }
    }

    /// 半双工 / 全双工，写成用户读得懂的一句话。
    public var detail: String {
        switch self {
        case .turnTaking: "它说话的时候麦克风关着；说完你说下一句。"
        case .duplex: "随时插话都能打断它。建议戴耳机，外放会有回声。"
        }
    }

    public var allowsBargeIn: Bool { self == .duplex }
}

/// 人设。**它是 system prompt 的一部分**，所以本轮只读、只在开始那一刻写入一次（§14.4）。
///
/// 目录内置几条，正文可由用户改（改的是"下一次开始"时用的那份）。
public struct Persona: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    public var isEditable: Bool

    public init(id: String, title: String, body: String, isEditable: Bool = true) {
        self.id = id
        self.title = title
        self.body = body
        self.isEditable = isEditable
    }
}

@MainActor
@Observable
public final class SessionPreferences {
    private let defaults: UserDefaults

    // MARK: 大模型（地址与模型是偏好；密钥在钥匙串）
    public var llmBaseURL: String {
        didSet { defaults.set(llmBaseURL, forKey: Key.llmBaseURL) }
    }
    public var llmModel: String {
        didSet { defaults.set(llmModel, forKey: Key.llmModel) }
    }
    /// 只读事实：`Responses · 必须`（§6.5 的接口行，不提供降级选项）。
    public let llmInterface = "Responses · 必须"

    // MARK: 助手
    /// 默认人设 id。**只在开始对话时使用一次**。
    public var defaultPersonaID: String {
        didSet { defaults.set(defaultPersonaID, forKey: Key.personaID) }
    }
    /// 默认音色（会话内仍可换，下一句生效）。
    public var defaultVoiceID: String {
        didSet { defaults.set(defaultVoiceID, forKey: Key.voiceID) }
    }
    public var assistantMode: AssistantMode {
        didSet { defaults.set(assistantMode.rawValue, forKey: Key.assistantMode) }
    }

    // MARK: 会话通用
    /// 字幕与会议的分人开关**各自一档**（§14.3 的开关粒度），默认都关。
    public var captionsDiarizationEnabled: Bool {
        didSet { defaults.set(captionsDiarizationEnabled, forKey: Key.captionsDiarization) }
    }
    public var meetingDiarizationEnabled: Bool {
        didSet { defaults.set(meetingDiarizationEnabled, forKey: Key.meetingDiarization) }
    }
    /// 会议音频来源的「本机音频」勾选（按 App 多选，存 bundle id 数组）。
    public var meetingSystemAudioBundleIDs: [String] {
        didSet { defaults.set(meetingSystemAudioBundleIDs, forKey: Key.meetingSystemAudioApps) }
    }
    public var meetingUsesMicrophone: Bool {
        didSet { defaults.set(meetingUsesMicrophone, forKey: Key.meetingMicrophone) }
    }
    /// 纪要模型：留空表示「同大模型」。
    public var minutesModel: String {
        didSet { defaults.set(minutesModel, forKey: Key.minutesModel) }
    }
    /// 中断时用系统通知告诉我（默认关，§6.8）。
    public var notifyOnInterruption: Bool {
        didSet { defaults.set(notifyOnInterruption, forKey: Key.notifyOnInterruption) }
    }
    /// 人设正文的可编辑副本（键 = persona id）。
    private var personaBodies: [String: String] {
        didSet { defaults.set(personaBodies, forKey: Key.personaBodies) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.llmBaseURL = defaults.string(forKey: Key.llmBaseURL) ?? ""
        self.llmModel = defaults.string(forKey: Key.llmModel) ?? ""
        self.defaultPersonaID = defaults.string(forKey: Key.personaID) ?? Self.catalog[0].id
        self.defaultVoiceID = defaults.string(forKey: Key.voiceID) ?? ""
        self.assistantMode = AssistantMode(rawValue: defaults.string(forKey: Key.assistantMode) ?? "")
            ?? .turnTaking
        self.captionsDiarizationEnabled = defaults.bool(forKey: Key.captionsDiarization)
        self.meetingDiarizationEnabled = defaults.bool(forKey: Key.meetingDiarization)
        self.meetingSystemAudioBundleIDs = defaults.stringArray(forKey: Key.meetingSystemAudioApps) ?? []
        self.meetingUsesMicrophone = defaults.object(forKey: Key.meetingMicrophone) as? Bool ?? true
        self.minutesModel = defaults.string(forKey: Key.minutesModel) ?? ""
        self.notifyOnInterruption = defaults.bool(forKey: Key.notifyOnInterruption)
        self.personaBodies = defaults.dictionary(forKey: Key.personaBodies) as? [String: String] ?? [:]
    }

    // MARK: 派生

    public var llmConfiguration: LLMConfiguration {
        LLMConfiguration(baseURL: llmBaseURL, model: llmModel)
    }

    /// 纪要用的那一份配置（`minutesModel` 留空 = 同大模型）。
    public var minutesConfiguration: LLMConfiguration {
        var configuration = llmConfiguration
        let override = minutesModel.trimmingCharacters(in: .whitespaces)
        if !override.isEmpty { configuration.model = override }
        return configuration
    }

    public var isLLMConfigured: Bool { llmConfiguration.isConfigured }

    /// 内置人设目录（正文可改，改的是"下一次开始"用的那份）。
    public static let catalog: [Persona] = [
        Persona(
            id: "patient",
            title: "耐心讲解",
            body: "你是一位耐心的讲解者。用简单的话把事说清楚，先给结论再给理由，"
                + "必要时举一个具体的例子。回答尽量短，不要用列表堆砌。"
        ),
        Persona(
            id: "concise",
            title: "简洁助手",
            body: "你是一位极简的助手。默认只答一到两句话，直接给结论；"
                + "只有被追问时才展开细节。不要寒暄，不要重复用户的话。"
        ),
        Persona(
            id: "reviewer",
            title: "严谨评审",
            body: "你是一位严谨的评审者。先指出结论与依据，再指出不确定的地方与可能的反例；"
                + "不确定就明说不确定，不要编造事实。"
        ),
        Persona(
            id: "interpreter",
            title: "口语翻译",
            body: "你是一位口语翻译。默认把用户说的中文译成自然的英文，只给译文，不加解释；"
                + "用户明确要求时再给中文回译。"
        )
    ]

    public var personas: [Persona] {
        Self.catalog.map { persona in
            var copy = persona
            if let body = personaBodies[persona.id], !body.isEmpty { copy.body = body }
            return copy
        }
    }

    public func persona(id: String) -> Persona? {
        personas.first { $0.id == id }
    }

    public var defaultPersona: Persona {
        persona(id: defaultPersonaID) ?? personas[0]
    }

    public func updatePersonaBody(id: String, body: String) {
        personaBodies[id] = body
    }

    /// 从记录库「继续这一轮」时预填当时的设置（§14.4：那里**可以**换人设，因为那是新会话）。
    public func prefill(from record: SessionRecord) {
        if let persona = record.persona, persona.id != defaultPersonaID, self.persona(id: persona.id) != nil {
            defaultPersonaID = persona.id
        }
        if let voice = record.voice, !voice.id.isEmpty {
            defaultVoiceID = voice.id
        }
    }

    /// 分人的**档位门禁**：`light` 档没有 aligner，不给分人（§14.3）。
    ///
    /// 读不到档位时**不拦**：那时由服务端来判（它会回 `diarization_not_available`），
    /// 客户端凭一个未知值去禁用开关，会把"读不到"说成"不支持"。
    /// 返回的是一句能直接写给用户的人话——开关置灰时必须说得出原因。
    public static func diarizationGateNote(for profile: String?) -> String? {
        guard let profile else { return nil }
        let normalized = profile.lowercased()
        guard normalized.contains("light") else { return nil }
        return "这台 Mac 现在的档位（light）不标说话人；换到 balanced 或 quality 档位之后，"
            + "新开的会话就能在行上看到说话人。"
    }

    private enum Key {
        static let llmBaseURL = "speechrail.llm.baseURL"
        static let llmModel = "speechrail.llm.model"
        static let personaID = "speechrail.session.assistant.persona"
        static let voiceID = "speechrail.session.assistant.voice"
        static let assistantMode = "speechrail.session.assistant.mode"
        static let captionsDiarization = "speechrail.session.captions.diarization"
        static let meetingDiarization = "speechrail.session.meeting.diarization"
        static let meetingSystemAudioApps = "speechrail.session.meeting.systemAudioApps"
        static let meetingMicrophone = "speechrail.session.meeting.microphone"
        static let minutesModel = "speechrail.session.meeting.minutesModel"
        static let notifyOnInterruption = "speechrail.session.notifyOnInterruption"
        static let personaBodies = "speechrail.session.personaBodies"
    }
}
