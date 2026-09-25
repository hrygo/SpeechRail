import Foundation
import Observation

// 「新会话的预填值」（`TECHNICAL-DESIGN` §5.12、`SESSIONS-SPEC` §15.4）。
//
// 这一层只放**偏好**：它决定下一场会话从什么值起步。每一场的实际取值随会话落库
// （`session.llm_model` / `persona_id` / `voice_id` / `diarization`），所以改了偏好
// 不会改写历史记录——这也是"库里那份是为了复现"的意思。
//
// 一条硬规矩：**密钥不在这里**。它只进安全保管库（`LLMKeychain`），这里最多知道"有没有"。

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
        case .turnTaking: "它说话期间不上传麦克风声音；说完你说下一句。"
        case .duplex: "随时插话都能打断它。建议戴耳机，外放会有回声。"
        }
    }

    public var allowsBargeIn: Bool { self == .duplex }
}

/// 人设。**它是 system prompt 的一部分**，所以本轮只读、只在开始那一刻写入一次（§14.4）。
///
/// 目录内置几条，正文可由用户改（改的是"下一次开始"时用的那份）。
public struct Persona: Identifiable, Hashable, Codable, Sendable {
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
    /// 兼容模式是 endpoint 的 wire profile；默认使用标准 OpenAI-compatible。
    public var llmCompatibilityMode: LLMCompatibilityMode {
        didSet { defaults.set(llmCompatibilityMode.rawValue, forKey: Key.llmCompatibilityMode) }
    }
    /// 模块覆盖保存地址、模型与兼容模式；Key 由 `LLMKeychain.Scope.module` 单独保管。
    private var llmModuleOverrides: [LLMModule: LLMModuleOverride] {
        didSet { persistLLMModuleOverrides() }
    }
    /// 按功能使用 Chat Completions 或 Responses；不绑定某一个 provider。
    public let llmInterface = "Chat / Responses · 按功能"

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
    /// 自定义人设（用户自己写的，排在内置目录之后）。
    ///
    /// 稿的「新建自定义人设」要求它可建、可删、可长期留下（`SESSIONS-SPEC` §6.1 的
    /// 未开始态）。它与人设**正文的改写**是两件事：改写动的是内置那几条的措辞，
    /// 这里动的是目录本身，所以分开存。
    private var customPersonas: [Persona] {
        didSet { persistCustomPersonas() }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.llmBaseURL = defaults.string(forKey: Key.llmBaseURL) ?? ""
        self.llmModel = defaults.string(forKey: Key.llmModel) ?? ""
        self.llmCompatibilityMode = LLMCompatibilityMode(
            rawValue: defaults.string(forKey: Key.llmCompatibilityMode) ?? ""
        ) ?? .openAICompatible
        self.llmModuleOverrides = Self.decodeLLMModuleOverrides(
            defaults.data(forKey: Key.llmModuleOverrides)
        )
        self.defaultPersonaID = defaults.string(forKey: Key.personaID) ?? Self.catalog[0].id
        self.defaultVoiceID = defaults.string(forKey: Key.voiceID) ?? ""
        self.assistantMode = AssistantMode(rawValue: defaults.string(forKey: Key.assistantMode) ?? "")
            ?? .duplex
        self.captionsDiarizationEnabled = defaults.bool(forKey: Key.captionsDiarization)
        self.meetingDiarizationEnabled = defaults.bool(forKey: Key.meetingDiarization)
        self.meetingSystemAudioBundleIDs = defaults.stringArray(forKey: Key.meetingSystemAudioApps) ?? []
        self.meetingUsesMicrophone = defaults.object(forKey: Key.meetingMicrophone) as? Bool ?? true
        self.minutesModel = defaults.string(forKey: Key.minutesModel) ?? ""
        self.notifyOnInterruption = defaults.bool(forKey: Key.notifyOnInterruption)
        self.personaBodies = defaults.dictionary(forKey: Key.personaBodies) as? [String: String] ?? [:]
        self.customPersonas = Self.decodePersonas(defaults.data(forKey: Key.customPersonas))
    }

    // MARK: 派生

    public var llmConfiguration: LLMConfiguration {
        LLMConfiguration(
            baseURL: llmBaseURL,
            model: llmModel,
            compatibilityMode: llmCompatibilityMode
        )
    }

    /// 不读取 Key 的配置投影，供状态栏等只展示 endpoint/model 的 UI 使用。
    public func llmConfiguration(for module: LLMModule) -> LLMConfiguration {
        LLMConfigurationResolver.resolve(
            global: llmConfiguration,
            globalAPIKey: nil,
            moduleOverride: effectiveLLMOverride(for: module),
            moduleAPIKey: nil
        ).configuration
    }

    /// 纪要用的那一份配置（保留旧 `minutesModel` 兼容语义）。
    public var minutesConfiguration: LLMConfiguration {
        llmConfiguration(for: .minutes)
    }

    public var isLLMConfigured: Bool { llmConfiguration.isConfigured }

    /// 返回设置页编辑用的覆盖值。没有显式新值时，把旧纪要模型映射成一个可编辑覆盖。
    public func llmOverride(for module: LLMModule) -> LLMModuleOverride {
        if let override = llmModuleOverrides[module] { return override }
        guard module == .minutes else { return LLMModuleOverride() }
        let legacyModel = minutesModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacyModel.isEmpty else { return LLMModuleOverride() }
        return LLMModuleOverride(
            enabled: true,
            baseURL: llmBaseURL,
            model: legacyModel,
            compatibilityMode: llmCompatibilityMode
        )
    }

    /// 切换模块专用配置。首次打开时复制全局值，避免用户打开开关后落入空配置。
    public func setLLMOverrideEnabled(_ enabled: Bool, for module: LLMModule) {
        var override = llmOverride(for: module)
        override.enabled = enabled
        if enabled {
            let inheritsGlobalProfile = override.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || override.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if override.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                override.baseURL = llmBaseURL
            }
            if override.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                override.model = llmModel
            }
            if inheritsGlobalProfile {
                override.compatibilityMode = llmCompatibilityMode
            }
        }
        updateLLMOverride(override, for: module)
    }

    public func updateLLMOverride(_ override: LLMModuleOverride, for module: LLMModule) {
        var normalized = override
        normalized.baseURL = normalized.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.model = normalized.model.trimmingCharacters(in: .whitespacesAndNewlines)
        llmModuleOverrides[module] = normalized
    }

    /// 普通运行时入口：统一读取 global/module Key，再走同一个解析器。
    public func resolvedLLMConfiguration(for module: LLMModule) -> ResolvedLLMConfiguration {
        let moduleOverride = effectiveLLMOverride(for: module)
        return resolvedLLMConfiguration(
            for: module,
            globalAPIKey: LLMKeychain.load(scope: .global),
            moduleAPIKey: moduleOverride == nil ? nil : LLMKeychain.load(scope: .module(module))
        )
    }

    /// 注入式入口供会话测试/运行时使用，避免为测试改写真实安全保管库。
    public func resolvedLLMConfiguration(
        for module: LLMModule,
        globalAPIKey: String?,
        moduleAPIKey: String?
    ) -> ResolvedLLMConfiguration {
        LLMConfigurationResolver.resolve(
            global: llmConfiguration,
            globalAPIKey: globalAPIKey,
            moduleOverride: effectiveLLMOverride(for: module),
            moduleAPIKey: moduleAPIKey
        )
    }

    public func isLLMConfigured(for module: LLMModule) -> Bool {
        llmConfiguration(for: module).isConfigured
    }

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
        (Self.catalog + customPersonas).map { persona in
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

    /// 新建一条自定义人设。「它是它开口前读的第一段话」，所以正文不能为空——
    /// 空正文的人设不会让助手有任何变化，却会在列表里占一行。
    @discardableResult
    public func addPersona(title: String, body: String) -> Persona? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedBody.isEmpty else { return nil }
        let persona = Persona(
            id: "custom-\(UUID().uuidString.prefix(8))",
            title: trimmedTitle,
            body: trimmedBody
        )
        customPersonas.append(persona)
        return persona
    }

    public func removePersona(id: String) {
        customPersonas.removeAll { $0.id == id }
        personaBodies[id] = nil
        if defaultPersonaID == id { defaultPersonaID = Self.catalog[0].id }
    }

    public var isCustomPersona: (String) -> Bool {
        { [customPersonas] id in customPersonas.contains { $0.id == id } }
    }

    private func persistCustomPersonas() {
        guard let data = try? JSONEncoder().encode(customPersonas) else { return }
        defaults.set(data, forKey: Key.customPersonas)
    }

    private static func decodePersonas(_ data: Data?) -> [Persona] {
        guard let data, let personas = try? JSONDecoder().decode([Persona].self, from: data) else {
            return []
        }
        return personas
    }

    private func effectiveLLMOverride(for module: LLMModule) -> LLMModuleOverride? {
        if let override = llmModuleOverrides[module] {
            return override.enabled ? override : nil
        }
        guard module == .minutes else { return nil }
        let legacyModel = minutesModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacyModel.isEmpty else { return nil }
        return LLMModuleOverride(enabled: true, baseURL: llmBaseURL, model: legacyModel)
    }

    private func persistLLMModuleOverrides() {
        guard let data = try? JSONEncoder().encode(llmModuleOverrides) else { return }
        defaults.set(data, forKey: Key.llmModuleOverrides)
    }

    private static func decodeLLMModuleOverrides(_ data: Data?) -> [LLMModule: LLMModuleOverride] {
        guard
            let data,
            let overrides = try? JSONDecoder().decode(
                [LLMModule: LLMModuleOverride].self,
                from: data
            )
        else { return [:] }
        return overrides
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
    private enum Key {
        static let llmBaseURL = "speechrail.llm.baseURL"
        static let llmModel = "speechrail.llm.model"
        static let llmCompatibilityMode = "speechrail.llm.compatibilityMode"
        static let llmModuleOverrides = "speechrail.llm.moduleOverrides.v1"
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
        static let customPersonas = "speechrail.session.customPersonas"
    }
}
