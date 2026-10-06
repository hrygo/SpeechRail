import CryptoKit
import Foundation
import OpenAI
import Security

private final class SpeechRailOpenAIResponseCapture: @unchecked Sendable {
    private static let maxResponseBytes = 256 * 1024

    struct Snapshot: Sendable {
        let statusCode: Int?
        let retryAfter: TimeInterval?
        let body: String
        let isOversized: Bool
        let responseBytes: Int
        let choiceCount: Int?
        let finishReason: String?
        let promptTokens: Int?
        let completionTokens: Int?
        let reasoningTokens: Int?
    }

    private let lock = NSLock()
    private var statusCode: Int?
    private var retryAfter: TimeInterval?
    private var body = ""
    private var isOversized = false
    private var responseBytes = 0
    private var choiceCount: Int?
    private var finishReason: String?
    private var promptTokens: Int?
    private var completionTokens: Int?
    private var reasoningTokens: Int?

    func record(response: URLResponse?, data: Data?) {
        lock.lock()
        defer { lock.unlock() }
        statusCode = (response as? HTTPURLResponse)?.statusCode
        retryAfter = Self.retryAfter(from: response as? HTTPURLResponse)
        responseBytes = data?.count ?? 0
        isOversized = responseBytes > Self.maxResponseBytes
        choiceCount = nil
        finishReason = nil
        promptTokens = nil
        completionTokens = nil
        reasoningTokens = nil
        if let data {
            body = String(decoding: data.prefix(4_096), as: UTF8.self)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            if let choices = object["choices"] as? [[String: Any]] {
                choiceCount = choices.count
                finishReason = choices.first?["finish_reason"] as? String
            }
            if let usage = object["usage"] as? [String: Any] {
                record(usage: usage)
            }
        } else {
            body = ""
        }
    }

    func recordStreaming(response: URLResponse?, responseBytes: Int, usage: [String: Any]?) {
        lock.lock()
        defer { lock.unlock() }
        statusCode = (response as? HTTPURLResponse)?.statusCode
        retryAfter = nil
        self.responseBytes = max(0, responseBytes)
        isOversized = self.responseBytes > Self.maxResponseBytes
        body = ""
        choiceCount = nil
        finishReason = nil
        promptTokens = nil
        completionTokens = nil
        reasoningTokens = nil
        if let usage {
            record(usage: usage)
        }
    }

    private func record(usage: [String: Any]) {
        promptTokens = usage["prompt_tokens"] as? Int ?? usage["input_tokens"] as? Int
        completionTokens = usage["completion_tokens"] as? Int ?? usage["output_tokens"] as? Int
        reasoningTokens = (usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int
            ?? (usage["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int
            ?? usage["reasoning_tokens"] as? Int
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            statusCode: statusCode,
            retryAfter: retryAfter,
            body: body,
            isOversized: isOversized,
            responseBytes: responseBytes,
            choiceCount: choiceCount,
            finishReason: finishReason,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            reasoningTokens: reasoningTokens
        )
    }

    private static func retryAfter(from response: HTTPURLResponse?) -> TimeInterval? {
        guard let value = response?.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }

        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
            // 保留服务给的真实秒数。截断应该发生在「要不要等」的判定层，
            // 不能发生在这里：配额耗尽时服务会回一个「几天后」，截成 60 秒之后
            // 既没法判断这是配额（于是白等一轮），也没法告诉读者要等多久。
            return seconds
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}

private enum LLMJSONValue: Encodable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([LLMJSONValue])
    case object([String: LLMJSONValue])

    init(_ value: Any) throws {
        switch value {
        case is NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .number(Double(value))
        case let value as Double:
            guard value.isFinite else { throw LLMError.invalidStructuredResponse }
            self = .number(value)
        case let value as Float:
            guard value.isFinite else { throw LLMError.invalidStructuredResponse }
            self = .number(Double(value))
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(try value.map(LLMJSONValue.init))
        case let value as [String: Any]:
            self = .object(try value.mapValues(LLMJSONValue.init))
        default:
            throw LLMError.invalidStructuredResponse
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case let .bool(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .number(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .string(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .array(values):
            var container = encoder.unkeyedContainer()
            for value in values { try container.encode(value) }
        case let .object(values):
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in values {
                try container.encode(value, forKey: DynamicCodingKey(stringValue: key))
            }
        }
    }

    private struct DynamicCodingKey: CodingKey, Sendable {
        let stringValue: String
        let intValue: Int? = nil

        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

/// 外部 LLM 的 wire 兼容模式。URL 与 model 本身保持 opaque，不从它们推断 provider。
public enum LLMCompatibilityMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 任意标准 OpenAI-compatible endpoint；这是旧配置与新配置的默认模式。
    case openAICompatible = "openai_compatible"
    /// OpenCode Go 的 Chat 兼容端点。
    case openCodeGo = "opencode_go"
    /// 已验证的本机模板兼容端点，保留关闭 thinking 所需的模板字段。
    case localTemplateCompatible = "local_template_compatible"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .openAICompatible: "OpenAI-compatible（通用）"
        case .openCodeGo: "OpenCode Go"
        case .localTemplateCompatible: "本机模板兼容"
        }
    }

    public var detail: String {
        switch self {
        case .openAICompatible:
            "支持任意标准兼容端点和模型 ID；只发送标准字段。"
        case .openCodeGo:
            "为 OpenCode Go 添加会话关联字段和原生关闭 thinking 字段。"
        case .localTemplateCompatible:
            "为本机兼容服务添加关闭 thinking 所需的模板字段。"
        }
    }

}

/// Server-side format requested for a stateless structured task.
/// JSON mode remains the compatibility default; strict schema is opt-in per endpoint/model.
public enum LLMStructuredOutputMode: String, Codable, CaseIterable, Sendable {
    case jsonObject = "json_object"
    case jsonSchema = "json_schema"
}

/// 连接检查和日志使用的实际协议操作。
public enum LLMOperation: String, Codable, Sendable {
    case chat
    case responses
}

private enum LLMThinkingControl: String, Sendable {
    case standard
    case openCodeNative
    case localTemplate
}

private extension LLMCompatibilityMode {
    var chatThinkingControl: LLMThinkingControl {
        switch self {
        case .openAICompatible: .standard
        case .openCodeGo: .openCodeNative
        case .localTemplateCompatible: .localTemplate
        }
    }

    var responsesThinkingControl: LLMThinkingControl {
        switch self {
        case .openAICompatible, .openCodeGo: .standard
        case .localTemplateCompatible: .localTemplate
        }
    }

    var usesOpenCodeSessionHeader: Bool { self == .openCodeGo }
}

private struct SpeechRailOpenAIMiddleware: OpenAIMiddleware {
    let sessionID: String
    let compatibilityMode: LLMCompatibilityMode
    let includeThinkingControl: Bool
    let responseCapture: SpeechRailOpenAIResponseCapture

    func intercept(request: URLRequest) -> URLRequest {
        var request = request
        request.setValue("SpeechRail/teleprompter", forHTTPHeaderField: "User-Agent")
        if compatibilityMode.usesOpenCodeSessionHeader {
            request.setValue(sessionID, forHTTPHeaderField: "x-opencode-session")
        }

        guard request.url?.path.hasSuffix("/chat/completions") == true,
              let body = request.httpBody,
              var object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return request }

        if !includeThinkingControl {
            object.removeValue(forKey: "reasoning_effort")
            object.removeValue(forKey: "thinking")
            object.removeValue(forKey: "chat_template_kwargs")
        } else {
            switch compatibilityMode.chatThinkingControl {
            case .standard:
                // ChatQuery encodes the standard reasoning_effort field itself.
                break
            case .openCodeNative:
                object["thinking"] = ["type": "disabled"]
            case .localTemplate:
                object["chat_template_kwargs"] = ["enable_thinking": false]
            }
        }
        if let body = try? JSONSerialization.data(withJSONObject: object) {
            request.httpBody = body
        }
        return request
    }

    func intercept(response: URLResponse?, request: URLRequest, data: Data?) -> (response: URLResponse?, data: Data?) {
        responseCapture.record(response: response, data: data)
        guard request.url?.path.hasSuffix("/chat/completions") == true,
              let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var usage = object["usage"] as? [String: Any]
        else { return (response, data) }

        // MacPaw's typed usage details are optional for SpeechRail, but some compatible
        // providers emit only a subset of those nested fields. Removing the unstable
        // detail objects lets the SDK retain the required aggregate token counters.
        usage.removeValue(forKey: "prompt_tokens_details")
        usage.removeValue(forKey: "completion_tokens_details")
        var normalized = object
        normalized["usage"] = usage
        let normalizedData = try? JSONSerialization.data(withJSONObject: normalized)
        return (response, normalizedData ?? data)
    }
}

// 大模型的唯一通道（`TECHNICAL-DESIGN` §5.12、§8.1）。
//
// 四条不能含糊的口径：
//
//   1. **标准对话路径对接 Responses API，提词器整理路径使用 Chat Completions JSON mode**。
//      Responses 仍是助手、内心 OS 与纪要的协议边界；提词器的 map/reduce 只需要无状态的
//      Chat Completions 结构化传输。两条链路都不做端侧模型兜底。
//   2. **密钥只进安全保管库**（§15.4）：库里只留端点与模型名，日志与错误里不出现密钥。
//   3. **前缀结构是硬的**（§5.5）：人设与记忆进 developer 消息的 `input_text` 块并打显式
//      断点，动态内容一律排在后面。顶层 `instructions` 不能带断点，所以人设不能写在那里。
//   4. **SpeechRail 不需要 thinking**：通用 OpenAI-compatible 使用标准的 disabled 语义，
//      OpenCode Go 与本机模板端点只在显式 mode 下使用各自字段。端点不认识控制字段时只失败一次，
//      之后按不带任何 thinking 控制字段的形状发。

/// 大模型服务的配置。**值本身不含密钥**：密钥只按需从钥匙串取。
public struct LLMConfiguration: Sendable, Equatable {
    /// 兼容 OpenAI 的服务地址；**不接受 URL 里带 key**（§6.5）。
    public var baseURL: String
    public var model: String
    public var compatibilityMode: LLMCompatibilityMode

    public init(
        baseURL: String = "",
        model: String = "",
        compatibilityMode: LLMCompatibilityMode = .openAICompatible
    ) {
        self.baseURL = baseURL
        self.model = model
        self.compatibilityMode = compatibilityMode
    }

    public var isConfigured: Bool {
        !normalizedBaseURL.isEmpty && !model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 归一化：去掉尾部斜杠；**URL 里带 query 或 fragment 直接判为无效**（那通常是把 key 塞进去了）。
    public var normalizedBaseURL: String {
        var text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    public var isBaseURLValid: Bool {
        guard
            let url = URL(string: normalizedBaseURL),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            url.host != nil,
            url.query == nil,
            url.fragment == nil
        else { return false }
        return true
    }

    /// 端点上是否混进了凭据。带 `?api_key=` / `?key=` 的地址一律拒绝——项目约束不允许
    /// key 出现在 URL 里（`AGENTS.md` 的同一条）。
    public var embedsCredential: Bool {
        let text = baseURL.lowercased()
        return text.contains("api_key=") || text.contains("apikey=") || text.contains("key=") || text.contains("@")
    }
}

/// 需要 LLM 的应用能力作用域。全局配置是默认值，不是一个额外模块。
public enum LLMModule: String, CaseIterable, Codable, Identifiable, Sendable {
    case assistant
    case minutes
    case teleprompter

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .assistant: "语音助手"
        case .minutes: "会议纪要"
        case .teleprompter: "AI 提词器"
        }
    }

    public var detail: String {
        switch self {
        case .assistant: "语音助手与会议中的内心 OS，共用这一类对话能力。"
        case .minutes: "会后长任务，适合结构化输出能力更强的模型。"
        case .teleprompter: "主动点击才发送原稿，跟读和直播过程中不会调用。"
        }
    }

    public var requiredOperation: LLMOperation {
        switch self {
        case .teleprompter: .chat
        case .assistant, .minutes: .responses
        }
    }
}

/// 单个模块的专用配置。Key 不在这里，仍由 `LLMKeychain` 作用域保管。
public struct LLMModuleOverride: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var baseURL: String
    public var model: String
    public var compatibilityMode: LLMCompatibilityMode

    public init(
        enabled: Bool = false,
        baseURL: String = "",
        model: String = "",
        compatibilityMode: LLMCompatibilityMode = .openAICompatible
    ) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.model = model
        self.compatibilityMode = compatibilityMode
    }

    public var configuration: LLMConfiguration {
        LLMConfiguration(
            baseURL: baseURL,
            model: model,
            compatibilityMode: compatibilityMode
        )
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case baseURL
        case model
        case compatibilityMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        compatibilityMode = try container.decodeIfPresent(
            LLMCompatibilityMode.self,
            forKey: .compatibilityMode
        ) ?? .openAICompatible
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(model, forKey: .model)
        try container.encode(compatibilityMode, forKey: .compatibilityMode)
    }
}

public enum LLMConfigurationOrigin: String, Codable, Equatable, Sendable {
    case global
    case moduleOverride
    case globalFallback
}

public enum LLMConfigurationFallbackReason: String, Codable, Equatable, Sendable {
    case incomplete
    case embedsCredential
    case invalidBaseURL
}

/// 一次 LLM 执行所需的已解析值。Key 只在内存中短暂存在，不参与 UserDefaults 持久化。
public struct ResolvedLLMConfiguration: Equatable, Sendable {
    public let configuration: LLMConfiguration
    public let apiKey: String?
    public let origin: LLMConfigurationOrigin
    public let fallbackReason: LLMConfigurationFallbackReason?

    public init(
        configuration: LLMConfiguration,
        apiKey: String?,
        origin: LLMConfigurationOrigin,
        fallbackReason: LLMConfigurationFallbackReason? = nil
    ) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.origin = origin
        self.fallbackReason = fallbackReason
    }

    public var usesModuleOverride: Bool { origin == .moduleOverride }
}

/// 模块配置的唯一优先级解析点。它不探测网络，也不在请求失败后切换 endpoint。
public enum LLMConfigurationResolver {
    public static func resolve(
        global: LLMConfiguration,
        globalAPIKey: String?,
        moduleOverride: LLMModuleOverride?,
        moduleAPIKey: String?
    ) -> ResolvedLLMConfiguration {
        guard let moduleOverride, moduleOverride.enabled else {
            return ResolvedLLMConfiguration(
                configuration: global,
                apiKey: normalizedKey(globalAPIKey),
                origin: .global
            )
        }

        let moduleConfiguration = moduleOverride.configuration
        guard moduleConfiguration.isConfigured else {
            return ResolvedLLMConfiguration(
                configuration: global,
                apiKey: normalizedKey(globalAPIKey),
                origin: .globalFallback,
                fallbackReason: .incomplete
            )
        }
        guard !moduleConfiguration.embedsCredential else {
            return ResolvedLLMConfiguration(
                configuration: global,
                apiKey: normalizedKey(globalAPIKey),
                origin: .globalFallback,
                fallbackReason: .embedsCredential
            )
        }
        guard moduleConfiguration.isBaseURLValid else {
            return ResolvedLLMConfiguration(
                configuration: global,
                apiKey: normalizedKey(globalAPIKey),
                origin: .globalFallback,
                fallbackReason: .invalidBaseURL
            )
        }

        return ResolvedLLMConfiguration(
            configuration: moduleConfiguration,
            apiKey: normalizedKey(moduleAPIKey) ?? normalizedKey(globalAPIKey),
            origin: .moduleOverride
        )
    }

    private static func normalizedKey(_ key: String?) -> String? {
        guard let key else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 一次「检查连接」的结论。每种都可判定，不出现"测试失败"（§6.5）。
public enum LLMConnectionResult: Sendable, Equatable {
    case connected(milliseconds: Int, model: String)
    case serviceReachableModelMissing(String)
    case notChatAPI
    case notResponsesAPI
    case unreachable(String)
    case notConfigured
    case badBaseURL

    public var title: String {
        switch self {
        case .connected(let milliseconds, _): "已连接 · \(milliseconds) ms"
        case .serviceReachableModelMissing: "服务可达，但这个模型没加载"
        case .notChatAPI: "接口不对：没有 Chat Completions API"
        case .notResponsesAPI: "接口不对：没有 Responses API"
        case .unreachable: "连不上"
        case .notConfigured: "还没配置"
        case .badBaseURL: "地址不对"
        }
    }

    public var detail: String {
        switch self {
        case .connected(_, let model):
            "用的是 \(model)。对话与纪要都走这一个服务地址。"
        case .serviceReachableModelMissing(let model):
            "服务在，但它的模型列表里没有 \(model)。先在那边加载/下载这个模型，或者在这里换一个。"
        case .notChatAPI:
            "这个地址没有 Chat Completions，AI 提词器需要这项能力。换一个兼容地址，或检查它的 API 路径。"
        case .notResponsesAPI:
            "这个地址没有 Responses，语音助手与会议纪要需要这项能力。换一个兼容地址，或为 AI 提词器单独配置 Chat 服务。"
        case .unreachable(let message):
            message
        case .notConfigured:
            "填上地址与模型之后，这里会给出四选一的可判定结论。"
        case .badBaseURL:
            "地址里不要带密钥，也不要带查询参数；给到 /v1 这一层即可。"
        }
    }

    public var isReady: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// 设置页密钥草稿的提交规则：先用草稿测试，只有连接成功后才持久化。
public enum LLMKeyDraftAction: Equatable, Sendable {
    case check
    case checkAndSave
}

public enum LLMKeyDraftPolicy {
    public static func normalizedDraft(_ draft: String) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func action(for draft: String) -> LLMKeyDraftAction {
        normalizedDraft(draft) == nil ? .check : .checkAndSave
    }

    public static func candidateKey(draft: String, storedKey: String?) -> String? {
        normalizedDraft(draft) ?? storedKey
    }

    public static func shouldPersist(
        draft: String,
        connection: LLMConnectionResult,
        saveRequested: Bool
    ) -> Bool {
        saveRequested && normalizedDraft(draft) != nil && connection.isReady
    }
}

/// 对话里的一条消息。`role` 对着 Responses API 的取值域。
public struct LLMMessage: Sendable, Equatable {
    public enum Role: String, Sendable {
        case developer
        case user
        case assistant
    }

    public var role: Role
    public var text: String
    /// 是否在这一条的结尾打显式前缀断点（只对人设与记忆为真，见 §5.5）。
    public var cacheBreakpoint: Bool

    public init(role: Role, text: String, cacheBreakpoint: Bool = false) {
        self.role = role
        self.text = text
        self.cacheBreakpoint = cacheBreakpoint
    }
}

public enum LLMError: LocalizedError, Equatable {
    case notConfigured
    case badBaseURL
    case transport(String)
    case http(status: Int, body: String)
    case httpWithRetry(status: Int, body: String, retryAfter: TimeInterval)
    /// 服务明确回绝了「再来一次」：额度/配额已用尽，或该模型对当前账号不可用。
    ///
    /// 这类 429 和「请求太密、等几秒就好」的限流长得一样（都是 429 + Retry-After），
    /// 但只有前者重试有意义——配额可能几天后才恢复。因此从响应里认出配额标记后单独成类，
    /// 让调用方直接停止，而不是把 `retryAfter` 截断成几十秒白等一场。
    ///
    /// 正文一律不回显：上游报错可能夹带稿件或凭据，只保留我们自己的分类结论。
    case usageLimitExceeded(retryAfter: TimeInterval?)
    /// 端点没有 Responses API（404/405，或返回里明确说没有）。
    case notResponsesAPI
    /// 端点没有 Chat Completions API（404/405，或返回里明确说没有）。
    case notChatAPI
    /// 语音助手要求关闭推理，但端点拒绝了所选兼容模式的控制字段。
    case thinkingControlUnavailable
    /// 端点可达，但不支持请求要求的严格结构化输出。
    case unsupportedStructuredOutput
    case outputTruncated
    case invalidStructuredResponse
    case refused(String)
    /// 流在拿到明确的成功终态之前就结束了（EOF 或 `[DONE]`）。
    /// 已经收到的正文由调用方保留，所以这不是"什么都没拿到"。
    case streamEndedEarly
    /// 流里出现无法解析或无法分类的事件：不能静默跳过直到"看起来成功"。
    case malformedStreamEvent
    /// V07:流预算耗尽——SSE 单行/单事件、错误 body 或累计正文超限。
    /// 已收到的正文由调用方保留；不得静默丢 token，不得强制完成/朗读。
    case streamBudgetExceeded(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "还没有配置对话模型。"
        case .badBaseURL: "地址里不要带密钥或查询参数。"
        case .transport(let message): "连不上这台服务：\(message)"
        case .http(let status, let body):
            body.isEmpty ? "服务返回了 \(status)。" : "服务返回了 \(status)：\(body)"
        case .httpWithRetry(let status, let body, _):
            body.isEmpty ? "服务返回了 \(status)，请稍后重试。" : "服务返回了 \(status)：\(body)"
        case .usageLimitExceeded:
            "AI 服务的可用额度已经用尽，本次没有整理。原稿没有变化。"
        case .notResponsesAPI: "这个服务没有 Responses API。"
        case .notChatAPI: "这个服务没有 Chat Completions API。"
        case .thinkingControlUnavailable:
            "当前服务不支持所选的关闭推理方式。请检查模型的兼容模式。"
        case .unsupportedStructuredOutput: "这个服务不支持严格结构化输出。"
        case .outputTruncated: "整理结果可能未完成，请缩小处理范围后重试。"
        case .invalidStructuredResponse: "模型返回的整理结果无法使用，请重试。"
        case .refused(let reason): "模型没有回答：\(reason)"
        case .streamEndedEarly: "回答提前结束，已保留收到的内容。"
        case .malformedStreamEvent: "服务返回了无法解析的回答流。"
        case .streamBudgetExceeded(let detail):
            detail.isEmpty ? "回答流超出容量预算，已保留收到的内容。" : "回答流超出容量预算（\(detail)），已保留收到的内容。"
        case .cancelled: "已取消。"
        }
    }
}

/// 一轮 Responses 流的终态判定。
///
/// 只有 `response.completed` 算成功；`[DONE]` 与 EOF 都只是**传输**结束。
/// `responseID` 由第一个带身份的事件定下来，之后别的响应的终态一律不认。
struct LLMResponseStreamState {
    private enum Terminal {
        case awaiting
        case completed
        case failed
    }

    private(set) var responseID: String?
    private var terminal: Terminal = .awaiting

    var isFinished: Bool { terminal != .awaiting }

    /// 第一个带身份的事件定下这一轮是谁；后来的身份不改写它。
    mutating func observe(_ id: String?) {
        guard let id, !id.isEmpty, responseID == nil else { return }
        responseID = id
    }

    /// 事件是否属于本轮。事件没带身份时按本轮处理。
    func matches(_ id: String?) -> Bool {
        guard let id, let responseID else { return true }
        return id == responseID
    }

    mutating func complete() { terminal = .completed }
    mutating func fail() { terminal = .failed }
}

/// 逐字节把 Responses 的 SSE 流解码成事件。
///
/// 为什么不用 `URLSession.AsyncBytes.lines`：它会丢掉空行，于是拿不到 SSE 的事件边界，
/// 一个由多行 `data:` 拼成的事件会被读成几个坏事件。
/// V07:流预算上限（方案 §6.3 首版候选，按 fake 边界复核后集中定义）。
/// SSE 单行/单事件 256 KiB；错误 body 8 KiB；首正文与正文停滞 deadline；
/// 累计正文 16,384 scalar。超限显式失败，不静默丢 token。
/// 仅助手 `stream()` 施加；`complete`/`completeJSON` 等一次性调用保持各自显式超时，
/// 不套入语音短响应 deadline。
enum AssistantLLMStreamBudget {
    static let maxSSELineBytes = 256 * 1024
    static let maxSSEEventBytes = 256 * 1024
    static let maxErrorBodyBytes = 8 * 1024
    /// 首个有效正文到达前的等待上限。传 `nil` 表示不设限（测试/按需注入）。
    static let firstTextTimeout: Duration = .seconds(30)
    /// 有效正文之间的无进展上限——仅有效正文重置它，心跳/注释/重复事件不延长。
    /// 总轮次 deadline 由调用方 Task 语义承载，此处不另设不断重置的计时器。
    static let textStallTimeout: Duration = .seconds(15)
    /// 整轮累计正文上限（Unicode scalar）。语音回答极少触及；超限显式失败，
    /// 已收前缀由调用方保留，不强制完成/朗读。
    static let maxTotalTextScalars = 16_384
}

/// V07:流读取与 deadline 计时的赛跑（非隔离 helper，供 actor 内调用）。
///
/// 读取保持原同步 consume 循环；计时器只读进度。任一 deadline 到达即抛
/// `streamBudgetExceeded`，已收正文由调用方保留。`onDelta` 经 @Sendable
/// 参数跨隔离域传递，不在 actor 上下文内联闭包。
private enum StreamRace {
    fileprivate static func run(
        bytes: URLSession.AsyncBytes,
        decoder: inout ResponsesEventStreamDecoder,
        onDelta: @Sendable @escaping (String) -> Void,
        timer: StreamTimer
    ) async throws {
        // decoder 是值类型：赛跑期间所有权移交读取任务，结束时交还。
        // inout 跨任务传递被禁止，故用返回盒（终态/用量由调用方从返回的
        // decoder 读取，与原顺序循环语义一致）。
        // 结算语义与 `RealtimeASRClient.withStageTimeout` 同构：`group.next()`
        // 按完成顺序返回，只取一次——先完成者胜出；defer 取消另一方。
        // 计时器任务永不正常返回（deadline 到达即抛；读取已失败时可取消地停放，
        // 让读取任务的错误获胜），因此不存在"哨兵被误认为成功"的路径。
        final class DecoderBox: @unchecked Sendable {
            var value: ResponsesEventStreamDecoder
            init(_ v: ResponsesEventStreamDecoder) { value = v }
        }
        /// 赛跑结果：只有读取任务返回值；计时器任务只抛错（deadline 到达）
        /// 或被取消（读取已获胜），永不返回值——因此无需 seed 同一性比较。
        enum RaceResult: Sendable {
            case finished(DecoderBox)
            case timerFired
            /// 计时器认输：无 deadline 可等，或读取已失败。
            /// 永不抛错——调用方继续等读取任务的结果，绝不伪造超限。
            case timerConceded
        }
        let finishedDecoder = try await withThrowingTaskGroup(of: RaceResult.self) { group in
            let seed = DecoderBox(decoder)
            group.addTask {
                var local = seed.value
                do {
                    for try await byte in bytes {
                        if await timer.expired {
                            throw LLMError.streamBudgetExceeded(await timer.expiryReason)
                        }
                        if try local.consume(byte, onDelta: { text in
                            onDelta(text)
                            // 空串是纯进展信号（M1/V15 推理阶段）：只展期停滞
                            // deadline，不算首正文。非空正文走 noteText，
                            // 同时解除首正文 deadline 并展期停滞。
                            if text.isEmpty {
                                Task { await timer.noteProgress() }
                            } else {
                                Task { await timer.noteText() }
                            }
                        }) { break }
                    }
                    try local.finish(onDelta: { text in
                        onDelta(text)
                        if text.isEmpty {
                            Task { await timer.noteProgress() }
                        } else {
                            Task { await timer.noteText() }
                        }
                    })
                    if await timer.expired {
                        throw LLMError.streamBudgetExceeded(await timer.expiryReason)
                    }
                    return .finished(DecoderBox(local))
                } catch {
                    // 读取任务先立失败旗：计时器随后退出等待，不再覆盖失败原因。
                    await timer.noteFailure()
                    // V07:读取中途的取消同样单独成类，不记成传输失败。
                    if error is CancellationError || (error as? URLError)?.code == .cancelled {
                        throw LLMError.cancelled
                    }
                    throw error
                }
            }
            group.addTask {
                do {
                    try await timer.waitForExpiry()
                } catch {
                    // deadline 到达：expired 旗已立，抛超限错误获胜；
                    // 非超限错误（理论上不应发生）直接透出。
                    if await timer.expired {
                        return .timerFired
                    }
                    throw error
                }
                // waitForExpiry 正常返回只发生在两种情形：
                // 无 deadline 可等，或读取已失败（failed 旗）。
                // 两种情形下本任务都认输：返回永不抛错的 conceded，
                // 调用方继续等读取任务的结果，绝不伪造超限。
                // 注意：认输后若直接返回，`group.next()` 会先取到 conceded
                // 而不是读取任务的结果——因此此处可取消地停放，等 defer 取消
                // 或外层取消；停放被取消时抛 CancellationError 也不覆盖
                // 读取任务的错误（见下方的 next 循环）。
                do {
                    try await Task.sleep(for: .seconds(3_600))
                } catch {
                    return .timerConceded
                }
                return .timerConceded
            }
            defer { group.cancelAll() }
            // 循环结算：`.timerConceded`（计时器认输）不是终态，继续等
            // 读取任务的结果；`.timerFired`/`.finished`/任务抛错才是终态。
            // 认输任务已返回，不再占用 group；读取任务仍在运行（或已结束），
            // 下一次 next 必为其结果——不会无界等待。
            while true {
                guard let winner = try await group.next() else {
                    throw LLMError.transport("请求没有完成")
                }
                switch winner {
                case .finished(let box):
                    return box.value
                case .timerFired:
                    throw LLMError.streamBudgetExceeded(await timer.expiryReason)
                case .timerConceded:
                    continue
                }
            }
        }
        decoder = finishedDecoder
    }
}

/// V07:流进度与 deadline 计时（actor 隔离，供赛跑双方共享）。
/// internal 以便定向回归验证 deadline 状态机（首正文/停滞/心跳语义）；
/// 不进入公共 API，仅同模块测试可见。
actor StreamTimer {
    private let firstDeadline: ContinuousClock.Instant?
    private let stallTimeout: Duration?
    private var stallDeadline: ContinuousClock.Instant?
    private(set) var expired = false
    private(set) var expiryReason = ""
    private(set) var firstTextSeen = false
    private var failed = false

    init(
        firstDeadline: ContinuousClock.Instant?,
        stallTimeout: Duration?,
        initialStall: ContinuousClock.Instant?
    ) {
        self.firstDeadline = firstDeadline
        self.stallTimeout = stallTimeout
        self.stallDeadline = initialStall
    }

    func noteText() {
        firstTextSeen = true
        if let stallTimeout {
            stallDeadline = ContinuousClock.now.advanced(by: stallTimeout)
        }
    }

    /// M1/V15:合法推理进展——重置停滞 deadline，但不解除首正文 deadline。
    /// reasoning 阶段证明连接与模型活着，但正文尚未开始；首正文 deadline
    /// 仍按原预算执行，不因推理无限延长。
    func noteProgress() {
        if let stallTimeout {
            stallDeadline = ContinuousClock.now.advanced(by: stallTimeout)
        }
    }

    /// 读取任务失败时立旗：计时器随后退出等待，不再覆盖失败原因。
    func noteFailure() {
        failed = true
    }

    /// 计时器任务主体：任一 deadline 到达即立旗并抛错。
    /// 无 deadline 可等时直接返回（由调用方结算读取任务）。
    /// 读取任务已失败时直接返回，不覆盖其错误。
    func waitForExpiry() async throws {
        while true {
            if failed { return }
            let now = ContinuousClock.now
            if let firstDeadline, !firstTextSeen, now >= firstDeadline {
                expired = true
                expiryReason = "首个有效正文超时未到达"
                throw LLMError.streamBudgetExceeded(expiryReason)
            }
            if firstTextSeen, let stall = stallDeadline, now >= stall {
                expired = true
                expiryReason = "正文停滞超时未推进"
                throw LLMError.streamBudgetExceeded(expiryReason)
            }
            let nextWake: ContinuousClock.Instant?
            if !firstTextSeen {
                nextWake = firstDeadline
            } else {
                nextWake = stallDeadline
            }
            guard let wake = nextWake else {
                return  // 无 deadline 可等：计时器退出，等读取任务收尾。
            }
            let delay = max(.milliseconds(50), wake - now)
            try? await Task.sleep(for: delay)
            if Task.isCancelled || failed { return }
        }
    }
}

struct ResponsesEventStreamDecoder {
    private var lineBytes: [UInt8] = []
    private var dataLines: [String] = []
    private var eventBytes = 0
    private(set) var state = LLMResponseStreamState()
    private(set) var usage: [String: Any]?
    private(set) var byteCount = 0
    /// 整轮累计正文 scalar（含 delta 与 refusal delta）。V07d 有界计数，
    /// 超限由调用方显式失败，已收前缀保留。
    private(set) var totalTextScalars = 0

    /// 收到一个字节。返回 `true` 表示本轮已收束，调用方应停止读取。
    mutating func consume(
        _ byte: UInt8,
        onDelta: @Sendable (String) -> Void
    ) throws -> Bool {
        byteCount += 1
        guard byte != 0x0D else { return false }  // CRLF
        guard byte == 0x0A else {
            // V07:无换行 SSE 单行无限增长必须有界——超限显式失败。
            guard lineBytes.count < AssistantLLMStreamBudget.maxSSELineBytes else {
                throw LLMError.streamBudgetExceeded("SSE 单行超过 \(AssistantLLMStreamBudget.maxSSELineBytes) bytes")
            }
            lineBytes.append(byte)
            return false
        }
        let line = String(decoding: lineBytes, as: UTF8.self)
        lineBytes.removeAll(keepingCapacity: true)
        return try handle(line: line, onDelta: onDelta)
    }

    /// 流结束（EOF）：把没落下的行与最后一个事件一并结算。
    mutating func finish(onDelta: @Sendable (String) -> Void) throws {
        if !lineBytes.isEmpty {
            let line = String(decoding: lineBytes, as: UTF8.self)
            lineBytes.removeAll(keepingCapacity: true)
            if try handle(line: line, onDelta: onDelta) { return }
        }
        guard !state.isFinished, !dataLines.isEmpty else { return }
        for object in try Self.parseEvent(dataLines) {
            if try apply(object, onDelta: onDelta) { return }
        }
        dataLines.removeAll()
        eventBytes = 0
    }

    private mutating func handle(
        line: String,
        onDelta: @Sendable (String) -> Void
    ) throws -> Bool {
        if line.isEmpty {
            guard !state.isFinished else { return true }
            for object in try Self.parseEvent(dataLines) {
                if try apply(object, onDelta: onDelta) { return true }
            }
            dataLines.removeAll()
            eventBytes = 0
            return state.isFinished
        }
        // 注释（`: keep-alive`）与 `event:` / `id:` / `retry:` 不影响本任务。
        guard line.hasPrefix("data:") else { return false }
        // V07:多行 data: 拼成的单事件同样有界——超限显式失败。
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        eventBytes += payload.utf8.count
        guard eventBytes <= AssistantLLMStreamBudget.maxSSEEventBytes else {
            throw LLMError.streamBudgetExceeded("SSE 单事件超过 \(AssistantLLMStreamBudget.maxSSEEventBytes) bytes")
        }
        dataLines.append(payload)
        return false
    }

    private mutating func apply(
        _ object: [String: Any],
        onDelta: @Sendable (String) -> Void
    ) throws -> Bool {
        var state = self.state
        var usage = self.usage
        var total = self.totalTextScalars
        let finished = try Self.countedHandle(
            object,
            state: &state,
            usage: &usage,
            totalTextScalars: &total,
            onDelta: onDelta
        )
        self.state = state
        self.usage = usage
        self.totalTextScalars = total
        return finished
    }

    /// 把一个 SSE 事件的若干 `data:` 行解成事件对象。
    ///
    /// 规范允许一个事件由多行 `data:` 拼成，所以先按事件边界整体解析；
    /// 整体解析不了再退回逐行，兼容不发布空行的提供方。两种方式都失败时
    /// 明确报错，不把它静默跳过——否则会一路"跳过"到假成功。
    static func parseEvent(_ dataLines: [String]) throws -> [[String: Any]] {
        guard !dataLines.isEmpty else { return [] }
        let payload = dataLines.joined(separator: "\n")
        if payload == "[DONE]" { return [] }
        if let object = decode(payload) { return [object] }
        var objects: [[String: Any]] = []
        for line in dataLines where line != "[DONE]" {
            guard let object = decode(line) else {
                throw LLMError.malformedStreamEvent
            }
            objects.append(object)
        }
        return objects
    }

    private static func decode(_ payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    /// 处理一个事件（带整轮正文计数）。返回 `true` 表示本轮已收束，调用方应停止读取。
    ///
    /// V07d:累计正文超限显式失败，不静默丢 token，已收前缀由调用方保留。
    static func countedHandle(
        _ object: [String: Any],
        state: inout LLMResponseStreamState,
        usage: inout [String: Any]?,
        totalTextScalars: inout Int,
        onDelta: @Sendable (String) -> Void
    ) throws -> Bool {
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        let finished = try handle(object, state: &state, usage: &usage, onDelta: {
            counter.value += $0.unicodeScalars.count
            onDelta($0)
        })
        totalTextScalars += counter.value
        guard totalTextScalars <= AssistantLLMStreamBudget.maxTotalTextScalars else {
            throw LLMError.streamBudgetExceeded(
                "累计正文超过 \(AssistantLLMStreamBudget.maxTotalTextScalars) scalars"
            )
        }
        return finished
    }

    /// 处理一个事件。返回 `true` 表示本轮已收束，调用方应停止读取。
    static func handle(
        _ object: [String: Any],
        state: inout LLMResponseStreamState,
        usage: inout [String: Any]?,
        onDelta: @Sendable (String) -> Void
    ) throws -> Bool {
        guard let type = object["type"] as? String else {
            throw LLMError.malformedStreamEvent
        }
        let response = object["response"] as? [String: Any]
        let eventID = (object["response_id"] as? String) ?? (response?["id"] as? String)
        state.observe(eventID)
        // 别的响应的终态不是本轮的终态：不认，也不因此报错。
        guard state.matches(eventID) else { return false }
        usage = (object["usage"] as? [String: Any]) ?? (response?["usage"] as? [String: Any])
        switch type {
        case "response.output_text.delta", "response.refusal.delta":
            // refusal 的正文也要朗读，但它本身不是成功终态。
            if let delta = object["delta"] as? String { onDelta(delta) }
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            // M1/V15:合法推理阶段是有效进展，不是停滞——推进 deadline 计时，
            // 但不产生正文、不朗读、不落库。未知 reasoning 事件走 default
            // 忽略，不延长等待（fail-closed）。
            onDelta("")
        case "response.completed":
            state.complete()
            return true
        case "response.failed", "response.incomplete":
            state.fail()
            throw LLMError.refused(Self.failureReason(from: object) ?? "生成中断")
        case "error":
            let message = (object["error"] as? [String: Any])?["message"] as? String ?? "服务返回错误"
            throw LLMError.transport(message)
        default:
            // 进度、心跳等不影响正文的事件。
            break
        }
        return false
    }

    private static func failureReason(from object: [String: Any]) -> String? {
        guard let response = object["response"] as? [String: Any] else { return nil }
        if let error = response["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let details = response["incomplete_details"] as? [String: Any],
           let reason = details["reason"] as? String {
            return reason
        }
        return response["status"] as? String
    }
}

/// LLM 客户端。`actor`：它被助手、纪要、内心 OS 与提词器共用，而流式读取不该与界面线程争。
public actor LLMProvider {
    private let session: URLSession
    private let observationHandler: TeleprompterAIObservationHandler?
    /// 已经明确拒绝原生 thinking 控制的端点（键是 `baseURL|model`）。
    /// 只记在内存里：换端点或重启后重新探一次，不做持久化。
    private var thinkingControlRejected: Set<String> = []
    /// 已经明确拒绝 strict JSON Schema 的 endpoint/model/schema 组合。
    /// 只记在内存里，避免同一整理任务的每个窗口都先失败一次再退回 JSON mode。
    private var structuredOutputRejected: Set<String> = []

    public init(
        session: URLSession = .shared,
        observationHandler: TeleprompterAIObservationHandler? = nil
    ) {
        self.session = session
        self.observationHandler = observationHandler
    }

    // MARK: - 请求

    /// 流式补全。逐段产出正文；`cancelled` 之外的所有失败都是**受阻**，
    /// 不是降级——助手没有第二套回答方式（§8.1）。
    ///
    /// `instructions` 是 Responses API 的**顶层系统提示词**（语音助手用它承载语音对话契约）。
    /// 注意：它和 SpeechRail TTS 的 `instructions` 只是同名——那个管"怎么发声"，这个管"说什么"。
    public func stream(
        configuration: LLMConfiguration,
        messages: [LLMMessage],
        apiKey: String?,
        maxOutputTokens: Int? = nil,
        instructions: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // V07:首正文 deadline——只有心跳/注释而无有效正文时显式失败，
                    // 不无限延长回答；合法推理阶段的首个 delta 到达即解除。
                    // 停滞 deadline 由 runStream 内有效正文推进重置。
                    try await self.runStream(
                        configuration: configuration,
                        messages: messages,
                        apiKey: apiKey,
                        maxOutputTokens: maxOutputTokens,
                        instructions: instructions,
                        firstTextTimeout: AssistantLLMStreamBudget.firstTextTimeout,
                        stallTimeout: AssistantLLMStreamBudget.textStallTimeout,
                        onDelta: { continuation.yield($0) }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 一次性补全（内心 OS 与纪要都用它）。`store=false`：不用服务端会话状态。
    public func complete(
        configuration: LLMConfiguration,
        messages: [LLMMessage],
        apiKey: String?,
        maxOutputTokens: Int? = nil,
        textFormat: [String: Any]? = nil,
        instructions: String? = nil,
        timeout: TimeInterval = 120
    ) async throws -> String {
        let (data, response) = try await performOnce(
            configuration: configuration,
            messages: messages,
            apiKey: apiKey,
            maxOutputTokens: maxOutputTokens,
            textFormat: textFormat,
            background: false,
            instructions: instructions,
            timeout: timeout
        )
        try Self.validate(response: response, data: data)
        return try Self.extractText(from: data)
    }

    /// 无状态结构化任务使用 Chat JSON mode 或显式 strict JSON Schema；业务 decoder
    /// 仍是最终提交边界。默认保持 JSON mode 兼容性，strict 仅在调用方明确选择时启用。
    public func completeJSON(
        configuration: LLMConfiguration,
        apiKey: String?,
        instructions: String,
        input: String,
        schema: [String: Any],
        maxOutputTokens: Int,
        timeout: TimeInterval = 90,
        observationContext: TeleprompterAICallContext? = nil,
        structuredOutputMode: LLMStructuredOutputMode = .jsonObject
    ) async throws -> String {
        guard configuration.isConfigured else { throw LLMError.notConfigured }
        guard configuration.isBaseURLValid, !configuration.embedsCredential,
              URL(string: configuration.normalizedBaseURL) != nil else {
            throw LLMError.badBaseURL
        }
        guard maxOutputTokens > 0, timeout.isFinite, timeout > 0,
              let definition = schema["schema"] as? [String: Any] else {
            throw LLMError.invalidStructuredResponse
        }
        let schemaText = String(decoding: try JSONSerialization.data(
            withJSONObject: definition, options: [.sortedKeys]
        ), as: UTF8.self)
        let system = instructions + "\n输出必须是一个 JSON 对象，满足以下完整 JSON Schema。required 字段不可缺失；additionalProperties=false 表示禁止额外字段。schema_version 是应用的结果版本标签，必须使用 schema 中给定的常量。只输出结果对象，不输出 schema 本身。\n" + schemaText
        let controlKey = thinkingKey(configuration, operation: .chat)
        // OpenCode Go uses this header for routing and prompt-cache affinity. A preparation
        // run is one logical conversation, so reuse its run id across map/reduce calls.
        let sessionID = observationContext?.runID ?? UUID().uuidString
        let structuredOutputKey = structuredOutputKey(
            configuration: configuration,
            schemaName: schema["name"] as? String,
            schemaText: schemaText
        )
        var requestedMode = structuredOutputMode
        // OpenCode Go currently routes Chat Completions through a gateway that
        // rejects OpenAI's response_format=json_schema shape. Keep the local
        // schema/business decoder as the correctness boundary, but avoid
        // spending the first request on a known-incompatible wire shape.
        if requestedMode == .jsonSchema,
           configuration.compatibilityMode == .openCodeGo {
            requestedMode = .jsonObject
        }
        if requestedMode == .jsonSchema,
           structuredOutputRejected.contains(structuredOutputKey) {
            requestedMode = .jsonObject
        }
        var structuredOutputFallbackUsed = false
        var thinkingFallbackUsed = false
        for attempt in 0...2 {
            try Task.checkCancellation()
            let includeThinkingControl = !thinkingControlRejected.contains(controlKey)
            let responseCapture = SpeechRailOpenAIResponseCapture()
            let providerStartedAt = Date()
            emitProviderObservation(
                kind: .providerRequestStarted,
                context: observationContext,
                configuration: configuration,
                startedAt: providerStartedAt,
                snapshot: nil,
                transportAttempt: attempt,
                includeThinkingControl: includeThinkingControl,
                outcome: "started",
                errorCode: nil,
                structuredOutputMode: requestedMode
            )
            let client = try makeChatClient(
                configuration: configuration,
                apiKey: apiKey,
                sessionID: sessionID,
                includeThinkingControl: includeThinkingControl,
                timeout: timeout,
                responseCapture: responseCapture
            )
            var query = ChatQuery(
                messages: [
                    .system(.init(content: .textContent(system))),
                    .user(.init(content: .string(input)))
                ],
                model: configuration.model,
                reasoningEffort: includeThinkingControl
                    && configuration.compatibilityMode.chatThinkingControl == .standard
                    ? ChatQuery.ReasoningEffort.none
                    : nil,
                responseFormat: try responseFormat(
                    schema: schema,
                    mode: requestedMode
                ),
                store: false,
                temperature: 0
            )
            // MacPaw SDK 的标准 reasoning_effort 由上面的 query 编码；OpenCode 与本机
            // 模板字段由 middleware 在 Chat 请求边界注入，避免把某个 provider 的字段
            // 无条件带给其他兼容端点。
            query.maxTokens = maxOutputTokens

            do {
                let result = try await client.chats(query: query)
                try Task.checkCancellation()
                let snapshot = responseCapture.snapshot()
                emitProviderObservation(
                    kind: .providerResponse,
                    context: observationContext,
                    configuration: configuration,
                    startedAt: providerStartedAt,
                    snapshot: snapshot,
                    transportAttempt: attempt,
                    includeThinkingControl: includeThinkingControl,
                    outcome: "received",
                    errorCode: nil,
                    structuredOutputMode: requestedMode
                )
                guard !snapshot.isOversized else {
                    throw LLMError.invalidStructuredResponse
                }
                return try Self.extractChatJSON(result, maxOutputTokens: maxOutputTokens)
            } catch {
                let snapshot = responseCapture.snapshot()
                emitProviderObservation(
                    kind: .providerFailed,
                    context: observationContext,
                    configuration: configuration,
                    startedAt: providerStartedAt,
                    snapshot: snapshot,
                    transportAttempt: attempt,
                    includeThinkingControl: includeThinkingControl,
                    outcome: "failed",
                    errorCode: TeleprompterAIObservability.errorCode(for: error),
                    structuredOutputMode: requestedMode
                )
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw LLMError.cancelled
                }
                if attempt < 2, includeThinkingControl,
                   let statusCode = snapshot.statusCode,
                   !thinkingFallbackUsed,
                   Self.rejectsThinkingControl(status: statusCode, body: snapshot.body) {
                    thinkingControlRejected.insert(controlKey)
                    thinkingFallbackUsed = true
                    continue
                }
                if attempt < 2,
                   requestedMode == .jsonSchema,
                   !structuredOutputFallbackUsed,
                   let statusCode = snapshot.statusCode,
                   Self.rejectsStructuredOutput(status: statusCode, body: snapshot.body) {
                    structuredOutputRejected.insert(structuredOutputKey)
                    requestedMode = .jsonObject
                    structuredOutputFallbackUsed = true
                    continue
                }
                if let statusCode = snapshot.statusCode,
                   let retryAfter = snapshot.retryAfter,
                   Self.isTransientHTTPStatus(statusCode) {
                    // 配额耗尽和普通限流都是 429 + Retry-After，只有前者重试有意义。
                    // 先按白名单标记认出来，认不出才继续当暂态限流处理。
                    if Self.reportsUsageLimit(body: snapshot.body) {
                        throw LLMError.usageLimitExceeded(retryAfter: retryAfter)
                    }
                    throw LLMError.httpWithRetry(
                        status: statusCode,
                        body: "",
                        retryAfter: retryAfter
                    )
                }
                if let llmError = error as? LLMError {
                    throw llmError
                }
                if let statusCode = snapshot.statusCode {
                    // 上游错误可能回显稿件或凭据，不把原始正文交给 UI/日志。
                    if (200...299).contains(statusCode) {
                        throw LLMError.invalidStructuredResponse
                    }
                    throw Self.httpError(status: statusCode, body: "", retryAfter: snapshot.retryAfter)
                }
                throw LLMError.transport(error.localizedDescription)
            }
        }
        throw LLMError.invalidStructuredResponse
    }

    private func responseFormat(
        schema: [String: Any],
        mode: LLMStructuredOutputMode
    ) throws -> ChatQuery.ResponseFormat {
        switch mode {
        case .jsonObject:
            return .jsonObject
        case .jsonSchema:
            guard let name = schema["name"] as? String,
                  let definition = schema["schema"] else {
                throw LLMError.invalidStructuredResponse
            }
            return .jsonSchema(
                .init(
                    name: name,
                    description: nil,
                    schema: .dynamicJsonSchema(try LLMJSONValue(definition)),
                    strict: true
                )
            )
        }
    }

    private func structuredOutputKey(
        configuration: LLMConfiguration,
        schemaName: String?,
        schemaText: String
    ) -> String {
        let digest = SHA256.hash(data: Data(schemaText.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return [
            configuration.normalizedBaseURL,
            configuration.model,
            configuration.compatibilityMode.rawValue,
            LLMOperation.chat.rawValue,
            schemaName ?? "unknown",
            digest
        ].joined(separator: "|")
    }

    private static func isTransientHTTPStatus(_ status: Int) -> Bool {
        status == 429 || (500...599).contains(status)
    }

    /// 只认上游自己的配额措辞，不做任何语义猜测。命中的标记都是明确的
    /// 「额度/配额」字样，因此即使正文里同时夹带稿件片段，被认出来之后也只保留分类结论。
    private static func reportsUsageLimit(body: String) -> Bool {
        let normalized = body.lowercased()
        return usageLimitMarkers.contains { normalized.contains($0) }
    }

    private static let usageLimitMarkers = [
        "usage limit",
        "usage_limit",
        "usagelimit",
        "insufficient_quota",
        "quota exceeded",
        "exceeded your current quota"
    ]

    private static func httpError(
        status: Int,
        body: String,
        retryAfter: TimeInterval?
    ) -> LLMError {
        guard let retryAfter, isTransientHTTPStatus(status) else {
            return .http(status: status, body: body)
        }
        return .httpWithRetry(status: status, body: body, retryAfter: retryAfter)
    }

    private func emitProviderObservation(
        kind: TeleprompterAIObservationKind,
        context: TeleprompterAICallContext?,
        configuration: LLMConfiguration,
        startedAt: Date,
        snapshot: SpeechRailOpenAIResponseCapture.Snapshot?,
        transportAttempt: Int,
        includeThinkingControl: Bool,
        outcome: String,
        errorCode: String?,
        operation: LLMOperation = .chat,
        component: String = "provider",
        thinkingControlOverride: String? = nil,
        structuredOutputMode: LLMStructuredOutputMode? = nil
    ) {
        let endpointHost = URL(string: configuration.normalizedBaseURL)?.host
        let thinkingControl: LLMThinkingControl
        switch operation {
        case .chat:
            thinkingControl = configuration.compatibilityMode.chatThinkingControl
        case .responses:
            thinkingControl = configuration.compatibilityMode.responsesThinkingControl
        }
        TeleprompterAIObservability.emit(
            .init(
                kind: kind,
                component: component,
                context: context,
                elapsedMilliseconds: max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)),
                httpStatus: snapshot?.statusCode,
                responseBytes: snapshot?.responseBytes,
                choiceCount: snapshot?.choiceCount,
                finishReason: snapshot?.finishReason,
                promptTokens: snapshot?.promptTokens,
                completionTokens: snapshot?.completionTokens,
                reasoningTokens: snapshot?.reasoningTokens,
                model: configuration.model,
                endpointHost: endpointHost,
                transportAttempt: transportAttempt,
                operation: operation,
                compatibilityMode: configuration.compatibilityMode,
                thinkingControl: thinkingControlOverride ?? (includeThinkingControl
                    ? "\(thinkingControl.rawValue)_disabled"
                    : "omitted_after_rejection"),
                structuredOutputMode: structuredOutputMode,
                outcome: outcome,
                errorCode: errorCode
            ),
            to: observationHandler
        )
    }

    private func makeChatClient(
        configuration: LLMConfiguration,
        apiKey: String?,
        sessionID: String,
        includeThinkingControl: Bool,
        timeout: TimeInterval,
        responseCapture: SpeechRailOpenAIResponseCapture
    ) throws -> OpenAI {
        guard
            let url = URL(string: configuration.normalizedBaseURL),
            let scheme = url.scheme?.lowercased(),
            let host = url.host
        else { throw LLMError.badBaseURL }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        let basePath = url.path.isEmpty ? "/" : url.path
        let sdkConfiguration = OpenAI.Configuration(
            token: apiKey?.isEmpty == false ? apiKey : nil,
            host: host,
            port: port,
            scheme: scheme,
            basePath: basePath,
            timeoutInterval: timeout,
            parsingOptions: .relaxed
        )
        return OpenAI(
            configuration: sdkConfiguration,
            session: session,
            middlewares: [SpeechRailOpenAIMiddleware(
                sessionID: sessionID,
                compatibilityMode: configuration.compatibilityMode,
                includeThinkingControl: includeThinkingControl,
                responseCapture: responseCapture
            )]
        )
    }

    private static func extractChatJSON(_ result: ChatResult, maxOutputTokens: Int) throws -> String {
        guard result.choices.count == 1,
              let usage = result.usage,
              usage.completionTokens >= 0 else {
            throw LLMError.invalidStructuredResponse
        }
        let choice = result.choices[0]
        // 部分 provider 用 stop 报告预算耗尽，不能单独信任 finish_reason。
        if choice.finishReason == "length" || usage.completionTokens >= maxOutputTokens {
            throw LLMError.outputTruncated
        }
        guard choice.finishReason == "stop",
              choice.message.role == "assistant",
              choice.message.refusal == nil || choice.message.refusal == "",
              choice.message.toolCalls?.isEmpty != false,
              let content = choice.message.content else {
            throw LLMError.invalidStructuredResponse
        }
        do { _ = try TeleprompterStrictJSON.object(from: Data(content.utf8)) }
        catch {
            throw LLMError.invalidStructuredResponse
        }
        return content
    }

    // MARK: - 长任务（Responses 的 background 模式，§5.8）

    /// 纪要这一类长任务**不绑在界面上**：先在服务端起一个后台响应，再轮询它。
    ///
    /// 两件必须一起说清的事（文档口径，§5.8 的隐私一行）：
    ///   · `store=false`：我们不使用服务端的会话状态；
    ///   · **但后台模式下即使 `store=false`，响应数据仍会在服务端临时落盘约 10 分钟**
    ///     以支持异步执行与轮询。所以界面**不许**说成"内容没经过服务器"。
    public func startBackground(
        configuration: LLMConfiguration,
        messages: [LLMMessage],
        apiKey: String?,
        maxOutputTokens: Int? = nil,
        textFormat: [String: Any]? = nil,
        instructions: String? = nil
    ) async throws -> String {
        // 后台响应的第一次 POST 只回一个 id 就返回，所以超时给短一点：卡住就重来。
        let (data, response) = try await performOnce(
            configuration: configuration,
            messages: messages,
            apiKey: apiKey,
            maxOutputTokens: maxOutputTokens,
            textFormat: textFormat,
            background: true,
            instructions: instructions,
            timeout: 60
        )
        try Self.validate(response: response, data: data)
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = object["id"] as? String, !id.isEmpty
        else { throw LLMError.transport("服务没有回一个可轮询的响应 id。") }
        return id
    }

    /// 轮询一个后台响应，直到它完成、失败或超时。
    ///
    /// 返回正文；`status` 为 `failed` / `incomplete` 时抛 `refused`（**拒答可程序化识别**）。
    public func pollBackground(
        configuration: LLMConfiguration,
        apiKey: String?,
        responseID: String,
        timeout: TimeInterval = 900,
        interval: TimeInterval = 3
    ) async throws -> String {
        guard
            configuration.isBaseURLValid,
            !configuration.embedsCredential,
            let url = URL(string: "\(configuration.normalizedBaseURL)/responses/\(responseID)")
        else { throw LLMError.badBaseURL }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            if let apiKey, !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            let providerStartedAt = Date()
            let responseCapture = SpeechRailOpenAIResponseCapture()
            emitProviderObservation(
                kind: .providerRequestStarted,
                context: nil,
                configuration: configuration,
                startedAt: providerStartedAt,
                snapshot: nil,
                transportAttempt: 0,
                includeThinkingControl: false,
                outcome: "started",
                errorCode: nil,
                operation: .responses,
                component: "provider_poll",
                thinkingControlOverride: "not_applicable"
            )

            let result: (Data, URLResponse)
            do {
                result = try await perform(request, timeout: 60)
            } catch {
                emitProviderObservation(
                    kind: .providerFailed,
                    context: nil,
                    configuration: configuration,
                    startedAt: providerStartedAt,
                    snapshot: nil,
                    transportAttempt: 0,
                    includeThinkingControl: false,
                    outcome: "failed",
                    errorCode: TeleprompterAIObservability.errorCode(for: error),
                    operation: .responses,
                    component: "provider_poll",
                    thinkingControlOverride: "not_applicable"
                )
                throw error
            }
            responseCapture.record(response: result.1, data: result.0)
            do {
                try Self.validate(response: result.1, data: result.0)
                guard let object = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any] else {
                    throw LLMError.transport("轮询回来的不是 JSON。")
                }
                switch object["status"] as? String {
                case "completed":
                    let text = try Self.extractText(from: result.0)
                    if text.isEmpty, let reason = Self.failureReason(from: object) {
                        throw LLMError.refused(reason)
                    }
                    emitProviderObservation(
                        kind: .providerResponse,
                        context: nil,
                        configuration: configuration,
                        startedAt: providerStartedAt,
                        snapshot: responseCapture.snapshot(),
                        transportAttempt: 0,
                        includeThinkingControl: false,
                        outcome: "completed",
                        errorCode: nil,
                        operation: .responses,
                        component: "provider_poll",
                        thinkingControlOverride: "not_applicable"
                    )
                    return text
                case "failed", "incomplete", "cancelled":
                    throw LLMError.refused(Self.failureReason(from: object) ?? "生成没有完成")
                default:
                    emitProviderObservation(
                        kind: .providerResponse,
                        context: nil,
                        configuration: configuration,
                        startedAt: providerStartedAt,
                        snapshot: responseCapture.snapshot(),
                        transportAttempt: 0,
                        includeThinkingControl: false,
                        outcome: "pending",
                        errorCode: nil,
                        operation: .responses,
                        component: "provider_poll",
                        thinkingControlOverride: "not_applicable"
                    )
                    // queued / in_progress：等下一轮。
                    try? await Task.sleep(for: .seconds(interval))
                }
            } catch {
                emitProviderObservation(
                    kind: .providerFailed,
                    context: nil,
                    configuration: configuration,
                    startedAt: providerStartedAt,
                    snapshot: responseCapture.snapshot(),
                    transportAttempt: 0,
                    includeThinkingControl: false,
                    outcome: "failed",
                    errorCode: TeleprompterAIObservability.errorCode(for: error),
                    operation: .responses,
                    component: "provider_poll",
                    thinkingControlOverride: "not_applicable"
                )
                throw error
            }
        }
        throw LLMError.transport("等了很久也没整理完（超时）。")
    }

    private func runStream(
        configuration: LLMConfiguration,
        messages: [LLMMessage],
        apiKey: String?,
        maxOutputTokens: Int?,
        instructions: String?,
        firstTextTimeout: Duration? = nil,
        stallTimeout: Duration? = nil,
        onDelta: @Sendable @escaping (String) -> Void
    ) async throws {
        let controlKey = thinkingKey(configuration, operation: .responses)
        var includeThinkingControl = !thinkingControlRejected.contains(controlKey)
        guard includeThinkingControl else { throw LLMError.thinkingControlUnavailable }
        var bytes: URLSession.AsyncBytes?
        var streamStartedAt: Date?
        var streamResponseCapture: SpeechRailOpenAIResponseCapture?
        var streamResponse: URLResponse?
        var streamResponseBytes = 0
        var streamUsage: [String: Any]?
        var streamAttempt = 0
        for attempt in 0...1 {
            let providerStartedAt = Date()
            let responseCapture = SpeechRailOpenAIResponseCapture()
            emitProviderObservation(
                kind: .providerRequestStarted,
                context: nil,
                configuration: configuration,
                startedAt: providerStartedAt,
                snapshot: nil,
                transportAttempt: attempt,
                includeThinkingControl: includeThinkingControl,
                outcome: "started",
                errorCode: nil,
                operation: .responses
            )

            let request: URLRequest
            do {
                request = try makeRequest(
                    configuration: configuration,
                    messages: messages,
                    apiKey: apiKey,
                    stream: true,
                    maxOutputTokens: maxOutputTokens,
                    instructions: instructions,
                    includeThinkingControl: includeThinkingControl
                )
            } catch {
                emitProviderObservation(
                    kind: .providerFailed,
                    context: nil,
                    configuration: configuration,
                    startedAt: providerStartedAt,
                    snapshot: nil,
                    transportAttempt: attempt,
                    includeThinkingControl: includeThinkingControl,
                    outcome: "failed",
                    errorCode: TeleprompterAIObservability.errorCode(for: error),
                    operation: .responses
                )
                throw error
            }

            let result: (URLSession.AsyncBytes, URLResponse)
            do {
                result = try await session.bytes(for: request)
            } catch {
                // V07:取消单独成类——`URLSession` 取消抛 `URLError.cancelled`，
                // 混进 transport 会把"用户按了取消"记成一次传输失败。
                // 与 `perform(_:timeout:)` 同一区分规则。
                let failure: LLMError
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    failure = .cancelled
                } else {
                    failure = LLMError.transport(error.localizedDescription)
                }
                emitProviderObservation(
                    kind: .providerFailed,
                    context: nil,
                    configuration: configuration,
                    startedAt: providerStartedAt,
                    snapshot: nil,
                    transportAttempt: attempt,
                    includeThinkingControl: includeThinkingControl,
                    outcome: "failed",
                    errorCode: TeleprompterAIObservability.errorCode(for: failure),
                    operation: .responses
                )
                throw failure
            }
            guard let response = result.1 as? HTTPURLResponse else {
                let failure = LLMError.transport("没有收到 HTTP 响应")
                emitProviderObservation(
                    kind: .providerFailed,
                    context: nil,
                    configuration: configuration,
                    startedAt: providerStartedAt,
                    snapshot: nil,
                    transportAttempt: attempt,
                    includeThinkingControl: includeThinkingControl,
                    outcome: "failed",
                    errorCode: TeleprompterAIObservability.errorCode(for: failure),
                    operation: .responses
                )
                throw failure
            }
            responseCapture.record(response: response, data: nil)
            if (200..<300).contains(response.statusCode) {
                bytes = result.0
                streamStartedAt = providerStartedAt
                streamResponseCapture = responseCapture
                streamResponse = response
                streamAttempt = attempt
                break
            }
            // V07:非 2xx 错误 body 累加有上限——超限截断并标记，不无界积压。
            // `AsyncBytes.lines` 按行切分：超长无换行 body 是一整行，`+=` 整行
            // 追加会越过上限，因此逐行检查累加后是否超限并截断到上限。
            var body = ""
            var bodyTruncated = false
            do {
                for try await line in result.0.lines {
                    body += line
                    if body.utf8.count > AssistantLLMStreamBudget.maxErrorBodyBytes {
                        body = String(body.prefix(AssistantLLMStreamBudget.maxErrorBodyBytes))
                        bodyTruncated = true
                        break
                    }
                }
            } catch {
                let failure = LLMError.transport(error.localizedDescription)
                emitProviderObservation(
                    kind: .providerFailed,
                    context: nil,
                    configuration: configuration,
                    startedAt: providerStartedAt,
                    snapshot: responseCapture.snapshot(),
                    transportAttempt: attempt,
                    includeThinkingControl: includeThinkingControl,
                    outcome: "failed",
                    errorCode: TeleprompterAIObservability.errorCode(for: failure),
                    operation: .responses
                )
                throw failure
            }
            responseCapture.record(response: response, data: Data(body.utf8))
            let failure: LLMError
            do {
                try Self.validate(response: response, data: Data(body.utf8), truncated: bodyTruncated)
                var short = Self.shortBody(body)
                if bodyTruncated { short += "…（正文超限已截断）" }
                failure = .http(status: response.statusCode, body: short)
            } catch let error as LLMError {
                failure = error
            }
            emitProviderObservation(
                kind: .providerFailed,
                context: nil,
                configuration: configuration,
                startedAt: providerStartedAt,
                snapshot: responseCapture.snapshot(),
                transportAttempt: attempt,
                includeThinkingControl: includeThinkingControl,
                outcome: "failed",
                errorCode: TeleprompterAIObservability.errorCode(for: failure),
                operation: .responses
            )
            // 语音助手不能在关闭推理失败后省略控制字段继续生成。
            guard attempt == 0, includeThinkingControl, Self.rejectsThinkingControl(failure) else {
                throw failure
            }
            thinkingControlRejected.insert(controlKey)
            throw LLMError.thinkingControlUnavailable
        }
        guard let bytes, let streamStartedAt, let streamResponseCapture else {
            let failure = LLMError.transport("请求没有完成")
            emitProviderObservation(
                kind: .providerFailed,
                context: nil,
                configuration: configuration,
                startedAt: Date(),
                snapshot: nil,
                transportAttempt: streamAttempt,
                includeThinkingControl: includeThinkingControl,
                outcome: "failed",
                errorCode: TeleprompterAIObservability.errorCode(for: failure),
                operation: .responses
            )
            throw failure
        }
        do {
            // V07:读取与计时器赛跑。读取保持原同步 consume 循环；计时器
            // 只读 actor 进度，到达即立旗并抛错；读取在下一字节/收尾处抛同错。
            // 关键：先结算读取任务（它的错误优先），计时器无 deadline 时直接
            // 返回哨兵，随后仍等读取收尾——不把"无 deadline"当成功。
            var decoder = ResponsesEventStreamDecoder()
            let timer = StreamTimer(
                firstDeadline: firstTextTimeout.map { ContinuousClock.now.advanced(by: $0) },
                stallTimeout: stallTimeout,
                initialStall: stallTimeout.map { ContinuousClock.now.advanced(by: $0) }
            )
            try await StreamRace.run(
                bytes: bytes,
                decoder: &decoder,
                onDelta: onDelta,
                timer: timer
            )
            // `[DONE]` 与 EOF 都只是传输结束，不是模型的成功终态。
            guard decoder.state.isFinished else { throw LLMError.streamEndedEarly }
            streamResponseBytes = decoder.byteCount
            streamUsage = decoder.usage
            streamResponseCapture.recordStreaming(
                response: streamResponse,
                responseBytes: streamResponseBytes,
                usage: streamUsage
            )
            emitProviderObservation(
                kind: .providerResponse,
                context: nil,
                configuration: configuration,
                startedAt: streamStartedAt,
                snapshot: streamResponseCapture.snapshot(),
                transportAttempt: streamAttempt,
                includeThinkingControl: includeThinkingControl,
                outcome: "received",
                errorCode: nil,
                operation: .responses
            )
        } catch {
            streamResponseCapture.recordStreaming(
                response: streamResponse,
                responseBytes: streamResponseBytes,
                usage: streamUsage
            )
            emitProviderObservation(
                kind: .providerFailed,
                context: nil,
                configuration: configuration,
                startedAt: streamStartedAt,
                snapshot: streamResponseCapture.snapshot(),
                transportAttempt: streamAttempt,
                includeThinkingControl: includeThinkingControl,
                outcome: "failed",
                errorCode: TeleprompterAIObservability.errorCode(for: error),
                operation: .responses
            )
            throw error
        }
    }

    private func makeRequest(
        configuration: LLMConfiguration,
        messages: [LLMMessage],
        apiKey: String?,
        stream: Bool,
        maxOutputTokens: Int?,
        textFormat: [String: Any]? = nil,
        background: Bool = false,
        instructions: String? = nil,
        includeThinkingControl: Bool = true
    ) throws -> URLRequest {
        guard configuration.isConfigured else { throw LLMError.notConfigured }
        guard configuration.isBaseURLValid,
              !configuration.embedsCredential,
              let url = URL(string: "\(configuration.normalizedBaseURL)/responses")
        else { throw LLMError.badBaseURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        // 前缀结构（§5.5）：人设 → 记忆 → 历史 → 本轮。**动态内容一律在后**，
        // 这样断点之前那一段每次请求逐字节相同，才有缓存可命中。
        let input: [[String: Any]] = messages.map { message in
            var block: [String: Any] = ["type": "input_text", "text": message.text]
            if message.cacheBreakpoint {
                block["prompt_cache_breakpoint"] = ["mode": "explicit"]
            }
            let type = message.role == .assistant ? "output_text" : "input_text"
            block["type"] = type
            return ["role": message.role.rawValue, "content": [block]]
        }

        var body: [String: Any] = [
            "model": configuration.model,
            "input": input,
            "store": false,
            "stream": stream,
            "prompt_cache_options": ["mode": "explicit"]
        ]
        // 顶层 `instructions` = 系统提示词。它每轮都要重发：Responses 的续轮（`previous_response_id`）
        // **不继承**上一轮的 instructions（官方参考与 oMLX 实测一致），断链后也无从恢复。
        if let instructions, !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["instructions"] = instructions
        }
        // SpeechRail 不需要 reasoning/thinking。标准兼容端点使用标准字段；已知本机
        // 模板端点保留它的专用禁用表达。语音助手流要求控制字段生效，
        // 非流式任务仍可按各自策略处理端点拒绝。
        if includeThinkingControl {
            switch configuration.compatibilityMode.responsesThinkingControl {
            case .standard:
                body["reasoning"] = ["effort": "none"]
            case .openCodeNative:
                body["thinking"] = ["type": "disabled"]
            case .localTemplate:
                body["chat_template_kwargs"] = ["enable_thinking": false]
            }
        }
        if let maxOutputTokens { body["max_output_tokens"] = maxOutputTokens }
        if let textFormat { body["text"] = ["format": textFormat] }
        if background { body["background"] = true }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// 非流式的一次请求，自带"端点不认识关 thinking 参数"的退化：只失败一次，之后记住。
    private func performOnce(
        configuration: LLMConfiguration,
        messages: [LLMMessage],
        apiKey: String?,
        maxOutputTokens: Int?,
        textFormat: [String: Any]?,
        background: Bool,
        instructions: String?,
        timeout: TimeInterval
    ) async throws -> (Data, URLResponse) {
        let controlKey = thinkingKey(configuration, operation: .responses)
        var includeThinkingControl = !thinkingControlRejected.contains(controlKey)
        for attempt in 0...1 {
            let providerStartedAt = Date()
            let responseCapture = SpeechRailOpenAIResponseCapture()
            emitProviderObservation(
                kind: .providerRequestStarted,
                context: nil,
                configuration: configuration,
                startedAt: providerStartedAt,
                snapshot: nil,
                transportAttempt: attempt,
                includeThinkingControl: includeThinkingControl,
                outcome: "started",
                errorCode: nil,
                operation: .responses
            )
            let request: URLRequest
            do {
                request = try makeRequest(
                    configuration: configuration,
                    messages: messages,
                    apiKey: apiKey,
                    stream: false,
                    maxOutputTokens: maxOutputTokens,
                    textFormat: textFormat,
                    background: background,
                    instructions: instructions,
                    includeThinkingControl: includeThinkingControl
                )
            } catch {
                emitProviderObservation(
                    kind: .providerFailed,
                    context: nil,
                    configuration: configuration,
                    startedAt: providerStartedAt,
                    snapshot: nil,
                    transportAttempt: attempt,
                    includeThinkingControl: includeThinkingControl,
                    outcome: "failed",
                    errorCode: TeleprompterAIObservability.errorCode(for: error),
                    operation: .responses
                )
                throw error
            }
            let result: (Data, URLResponse)
            do {
                result = try await perform(request, timeout: timeout)
            } catch {
                emitProviderObservation(
                    kind: .providerFailed,
                    context: nil,
                    configuration: configuration,
                    startedAt: providerStartedAt,
                    snapshot: nil,
                    transportAttempt: attempt,
                    includeThinkingControl: includeThinkingControl,
                    outcome: "failed",
                    errorCode: TeleprompterAIObservability.errorCode(for: error),
                    operation: .responses
                )
                throw error
            }
            responseCapture.record(response: result.1, data: result.0)
            do {
                try Self.validate(response: result.1, data: result.0)
                emitProviderObservation(
                    kind: .providerResponse,
                    context: nil,
                    configuration: configuration,
                    startedAt: providerStartedAt,
                    snapshot: responseCapture.snapshot(),
                    transportAttempt: attempt,
                    includeThinkingControl: includeThinkingControl,
                    outcome: "received",
                    errorCode: nil,
                    operation: .responses
                )
                return result
            } catch let error as LLMError {
                emitProviderObservation(
                    kind: .providerFailed,
                    context: nil,
                    configuration: configuration,
                    startedAt: providerStartedAt,
                    snapshot: responseCapture.snapshot(),
                    transportAttempt: attempt,
                    includeThinkingControl: includeThinkingControl,
                    outcome: "failed",
                    errorCode: TeleprompterAIObservability.errorCode(for: error),
                    operation: .responses
                )
                if textFormat != nil, Self.rejectsStructuredOutput(error) {
                    throw LLMError.unsupportedStructuredOutput
                }
                guard attempt == 0, includeThinkingControl, Self.rejectsThinkingControl(error) else {
                    throw error
                }
                thinkingControlRejected.insert(controlKey)
                includeThinkingControl = false
            }
        }
        throw LLMError.transport("请求没有完成")
    }

    private func thinkingKey(_ configuration: LLMConfiguration, operation: LLMOperation) -> String {
        "\(configuration.normalizedBaseURL)|\(configuration.model)|\(configuration.compatibilityMode.rawValue)|\(operation.rawValue)"
    }

    /// 400 且明确指向 thinking 控制参数——才是"端点不认识它"，不是别的问题。
    private static func rejectsThinkingControl(_ error: LLMError) -> Bool {
        guard case let .http(status, body) = error else { return false }
        return rejectsThinkingControl(status: status, body: body)
    }

    /// Responses API 的严格结构化输出不做静默协议替换；Chat completeJSON 的
    /// json_schema 回退是单独受限的能力探测，只允许在端点明确拒绝该格式时退回 json_object。
    private static func rejectsStructuredOutput(_ error: LLMError) -> Bool {
        guard case let .http(status, body) = error else { return false }
        return rejectsStructuredOutput(status: status, body: body)
    }

    private static func rejectsStructuredOutput(status: Int, body: String) -> Bool {
        guard status == 400 || status == 422 else { return false }
        let lower = body.lowercased()
        let mentionsStructuredOutput = lower.contains("text.format")
            || lower.contains("response_format")
            || lower.contains("json_schema")
            || lower.contains("structured output")
            || lower.contains("structured_outputs")
        let openCodeUnavailable = lower.contains("response_format type is unavailable")
        let rejectsCapability = lower.contains("not supported")
            || lower.contains("unsupported")
            || lower.contains("unrecognized")
            || lower.contains("unknown parameter")
            || lower.contains("not implemented")
            || lower.contains("does not support")
            || openCodeUnavailable
        return mentionsStructuredOutput && rejectsCapability
    }

    /// 同上，但直接看原始状态码与正文：`check()` 在把响应包成 `LLMError` 之前就要先判一次。
    private static func rejectsThinkingControl(status: Int, body: String) -> Bool {
        guard status == 400 else { return false }
        let lower = body.lowercased()
        return lower.contains("chat_template_kwargs")
            || lower.contains("thinking")
            || lower.contains("unrecognized request argument")
            || lower.contains("unknown parameter")
            || lower.contains("extra inputs")
    }

    private func perform(_ request: URLRequest, timeout: TimeInterval) async throws -> (Data, URLResponse) {
        var request = request
        request.timeoutInterval = timeout
        do {
            return try await session.data(for: request)
        } catch {
            // 取消要单独成一类：`URLSession` 取消时抛的是 `URLError.cancelled`，
            // 混进 `transport` 之后调用方只能靠文本去猜，于是"用户按了取消"会被记成
            // 一次失败（内心 OS 的取消路径就靠这个区分）。
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw LLMError.cancelled
            }
            throw LLMError.transport(error.localizedDescription)
        }
    }

    // MARK: - 检查连接

    /// 检查用的最小请求。`/models` 不是 OpenAI-compatible 的硬性要求，实际能力探测才是结论。
    private static func probeRequest(
        url: URL,
        configuration: LLMConfiguration,
        apiKey: String?,
        operation: LLMOperation,
        includeThinkingControl: Bool,
        sessionID: String
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("SpeechRail/llm-check", forHTTPHeaderField: "User-Agent")
        if configuration.compatibilityMode.usesOpenCodeSessionHeader {
            request.setValue(sessionID, forHTTPHeaderField: "x-opencode-session")
        }
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var body: [String: Any]
        switch operation {
        case .chat:
            body = [
                "model": configuration.model,
                "messages": [["role": "user", "content": "ping"]],
                "max_tokens": 16,
                "stream": false,
                "temperature": 0
            ]
            if includeThinkingControl {
                switch configuration.compatibilityMode.chatThinkingControl {
                case .standard:
                    body["reasoning_effort"] = "none"
                case .openCodeNative:
                    body["thinking"] = ["type": "disabled"]
                case .localTemplate:
                    body["chat_template_kwargs"] = ["enable_thinking": false]
                }
            }
        case .responses:
            body = [
                "model": configuration.model,
                "input": [["role": "user", "content": [["type": "input_text", "text": "ping"]]]],
                "store": false,
                "max_output_tokens": 16
            ]
            if includeThinkingControl {
                switch configuration.compatibilityMode.responsesThinkingControl {
                case .standard:
                    body["reasoning"] = ["effort": "none"]
                case .openCodeNative:
                    body["thinking"] = ["type": "disabled"]
                case .localTemplate:
                    body["chat_template_kwargs"] = ["enable_thinking": false]
                }
            }
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// 一次点击检查指定功能实际需要的 wire operation。
    public func check(
        configuration: LLMConfiguration,
        apiKey: String?,
        operation: LLMOperation = .responses,
        allowThinkingControlFallback: Bool = true
    ) async -> LLMConnectionResult {
        guard configuration.isConfigured else { return .notConfigured }
        guard configuration.isBaseURLValid, !configuration.embedsCredential else { return .badBaseURL }

        let started = Date()
        // `/models` 只是辅助信息源：不支持、返回空列表或没有列出 alias model 时，仍继续真实能力探测。
        if let modelsURL = URL(string: "\(configuration.normalizedBaseURL)/models") {
            var modelsRequest = URLRequest(url: modelsURL)
            modelsRequest.timeoutInterval = 10
            if let apiKey, !apiKey.isEmpty {
                modelsRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            _ = try? await session.data(for: modelsRequest)
        }

        guard let operationURL = URL(
            string: "\(configuration.normalizedBaseURL)/\(operation == .chat ? "chat/completions" : "responses")"
        ) else { return .badBaseURL }
        let controlKey = thinkingKey(configuration, operation: operation)
        let sessionID = "check-\(UUID().uuidString)"
        var includeThinkingControl = !thinkingControlRejected.contains(controlKey)
        if !allowThinkingControlFallback && !includeThinkingControl {
            return .unreachable(LLMError.thinkingControlUnavailable.localizedDescription)
        }
        let data: Data
        let response: URLResponse
        do {
            var result = try await session.data(
                for: Self.probeRequest(
                    url: operationURL,
                    configuration: configuration,
                    apiKey: apiKey,
                    operation: operation,
                    includeThinkingControl: includeThinkingControl,
                    sessionID: sessionID
                )
            )
            if includeThinkingControl,
               let http = result.1 as? HTTPURLResponse,
               Self.rejectsThinkingControl(
                    status: http.statusCode,
                    body: String(decoding: result.0, as: UTF8.self)
               ) {
                thinkingControlRejected.insert(controlKey)
                if !allowThinkingControlFallback {
                    return .unreachable(LLMError.thinkingControlUnavailable.localizedDescription)
                }
                includeThinkingControl = false
                result = try await session.data(
                    for: Self.probeRequest(
                        url: operationURL,
                        configuration: configuration,
                        apiKey: apiKey,
                        operation: operation,
                        includeThinkingControl: false,
                        sessionID: sessionID
                    )
                )
            }
            data = result.0
            response = result.1
        } catch {
            return .unreachable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            return .unreachable("没有收到 HTTP 响应")
        }
        let body = String(decoding: data, as: UTF8.self)
        if Self.operationUnavailable(operation, status: http.statusCode, body: body) {
            return operation == .chat ? .notChatAPI : .notResponsesAPI
        }
        guard (200..<300).contains(http.statusCode) else {
            // 只有实际操作明确返回模型错误时，才把模型列表问题暴露给用户。
            if body.lowercased().contains("model") {
                return .serviceReachableModelMissing(configuration.model)
            }
            return .unreachable("服务回了 \(http.statusCode)：\(Self.shortBody(body))")
        }
        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        return .connected(milliseconds: milliseconds, model: configuration.model)
    }

    private static func operationUnavailable(
        _ operation: LLMOperation,
        status: Int,
        body: String
    ) -> Bool {
        let lower = body.lowercased()
        if lower.contains("model") && lower.contains("not found") { return false }
        if status == 404 || status == 405 { return true }
        guard status == 400 || status == 422 else { return false }
        if lower.contains("unknown endpoint") || lower.contains("endpoint not found") { return true }
        switch operation {
        case .chat:
            return lower.contains("chat completions") || lower.contains("chat/completions")
        case .responses:
            return lower.contains("responses")
        }
    }

    // MARK: - 解析

    static func modelIDs(from data: Data) -> [String] {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = object["data"] as? [[String: Any]]
        else { return [] }
        return list.compactMap { $0["id"] as? String }
    }

    /// 非流式返回的正文：`output[].content[].text`。拒答走 `refusal`，不假装成正文。
    static func extractText(from data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.transport("返回的不是 JSON")
        }
        if let output = object["output"] as? [[String: Any]] {
            var text = ""
            var refusal: String?
            for item in output {
                guard let contents = item["content"] as? [[String: Any]] else { continue }
                for content in contents {
                    if let chunk = content["text"] as? String, content["type"] as? String != "refusal" {
                        text += chunk
                    }
                    if let chunk = content["refusal"] as? String { refusal = chunk }
                }
            }
            if text.isEmpty, let refusal { throw LLMError.refused(refusal) }
            return text
        }
        // 有的兼容实现直接给一个 `output_text`。
        if let text = object["output_text"] as? String { return text }
        throw LLMError.transport("返回里没有正文")
    }

    private static func failureReason(from object: [String: Any]) -> String? {
        guard let response = object["response"] as? [String: Any] else { return nil }
        if let error = response["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let details = response["incomplete_details"] as? [String: Any],
           let reason = details["reason"] as? String {
            return reason
        }
        return response["status"] as? String
    }

    private static func validate(response: URLResponse, data: Data, truncated: Bool = false) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 404 || http.statusCode == 405 {
            throw LLMError.notResponsesAPI
        }
        guard !(200..<300).contains(http.statusCode) else { return }
        // V07:调用方截断超限 body 时标记透传——下游仍可分类，不误读为完整正文。
        var short = shortBody(String(decoding: data, as: UTF8.self))
        if truncated { short += "…（正文超限已截断）" }
        throw LLMError.http(status: http.statusCode, body: short)
    }

    /// 错误正文只留一小段，且**不回声 Authorization**（它本来也不在正文里）。
    private static func shortBody(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= 200 ? trimmed : String(trimmed.prefix(200)) + "…"
    }
}

// MARK: - 密钥（安全加密保管库）

/// 大模型密钥的读写。**安全保管库是唯一落点**：不进库、不进配置文件、不进日志（§15.4）。
/// 采用 macOS 本地用户目录 0600 严格权限 + CryptoKit AES-GCM 本地加密，
/// 彻底避免本地 ad-hoc 签名在 macOS 系统钥匙串触发登录密码弹窗与 ACL 校验异常。
public enum LLMKeychain {
    public enum Scope: Hashable, Sendable {
        case global
        case module(LLMModule)

        fileprivate var encryptedFileName: String {
            switch self {
            case .global: "llm_api_key.enc"
            case .module(let module): "llm_api_key_\(module.rawValue).enc"
            }
        }
    }

    private static let service = "com.speechrail.app.llm"
    private static let account = "api-key"

    private static var securityDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SpeechRail", isDirectory: true)
            .appendingPathComponent("security", isDirectory: true)
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700
            ])
        }
        return base
    }

    private static var vaultKeyURL: URL {
        securityDirectory.appendingPathComponent(".vault_master.key")
    }

    private static func encryptedKeyURL(for scope: Scope) -> URL {
        securityDirectory.appendingPathComponent(scope.encryptedFileName)
    }

    private static func getOrCreateMasterKey() throws -> SymmetricKey {
        let url = vaultKeyURL
        if let data = try? Data(contentsOf: url), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let newKey = SymmetricKey(size: .bits256)
        try newKey.withUnsafeBytes { raw in
            let keyData = Data(raw)
            try keyData.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return newKey
    }

    public static func save(_ key: String, scope: Scope = .global) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try remove(scope: scope)
            return
        }
        let masterKey = try getOrCreateMasterKey()
        let data = Data(trimmed.utf8)
        let sealedBox = try AES.GCM.seal(data, using: masterKey)
        guard let combined = sealedBox.combined else {
            throw KeychainError.vaultError("加密数据封装失败")
        }
        let url = encryptedKeyURL(for: scope)
        try combined.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func load(scope: Scope = .global) -> String? {
        // 从本地安全加密 Vault 读取
        if let encData = try? Data(contentsOf: encryptedKeyURL(for: scope)),
           let masterKey = try? getOrCreateMasterKey(),
           let sealedBox = try? AES.GCM.SealedBox(combined: encData),
           let decryptedData = try? AES.GCM.open(sealedBox, using: masterKey),
           let text = String(data: decryptedData, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    public static func remove(scope: Scope = .global) throws {
        let url = encryptedKeyURL(for: scope)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        if scope == .global {
            // 清除旧钥匙串条目以防残留
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    public static var hasKey: Bool { load(scope: .global) != nil }

    public static func hasKey(scope: Scope) -> Bool {
        load(scope: scope) != nil
    }

    public enum KeychainError: LocalizedError {
        case status(OSStatus)
        case vaultError(String)

        public var errorDescription: String? {
            switch self {
            case .status(let code): "密钥写入失败（\(code)）。"
            case .vaultError(let message): "安全保管库操作失败（\(message)）。"
            }
        }
    }
}
