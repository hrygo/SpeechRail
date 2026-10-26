import CryptoKit
import Foundation
import OpenAI
import Security

/// 最低文本响应合同的失败分类，不包含供应商正文或业务 schema。
public enum LLMResponseIssue: String, Codable, Equatable, Sendable, Error {
    case invalidShape
    case emptyText
    case refused
    case incomplete
    case failed
    case notCompleted

    public var detail: String {
        switch self {
        case .invalidShape: "服务返回的内容不符合所选接口，尚未确认能回答。"
        case .emptyText: "服务没有返回可用正文，尚未确认能回答。"
        case .refused: "服务拒绝了探测请求，尚未确认能回答。"
        case .incomplete: "服务的回答未完成；短探测预算不能证明模型不可用。"
        case .failed: "服务报告请求失败，尚未确认能回答。"
        case .notCompleted: "请求仍未完成，尚未确认能回答。"
        }
    }
}

enum LLMResponseValidation {
    /// 探测与正式文本解析共享最低合同；JSON/schema/usage 是调用者的附加要求。
    static func text(from data: Data, operation: LLMOperation) throws -> String {
        guard data.count <= 256 * 1024,
              let object = try? LLMStrictJSON.object(from: data),
              object["error"] == nil || object["error"] is NSNull else {
            throw LLMResponseIssue.invalidShape
        }
        let text: String
        switch operation {
        case .chat:
            guard object["object"] == nil || object["object"] as? String == "chat.completion",
                  let choices = object["choices"] as? [[String: Any]], choices.count == 1,
                  let message = choices[0]["message"] as? [String: Any],
                  message["role"] as? String == "assistant" else {
                throw LLMResponseIssue.invalidShape
            }
            if let refusal = message["refusal"] as? String, !refusal.isEmpty {
                throw LLMResponseIssue.refused
            }
            if choices[0]["finish_reason"] as? String == "length" { throw LLMResponseIssue.incomplete }
            guard choices[0]["finish_reason"] as? String == "stop",
                  message["tool_calls"] == nil || message["tool_calls"] is NSNull
                    || (message["tool_calls"] as? [Any])?.isEmpty == true,
                  let content = message["content"] as? String else {
                throw LLMResponseIssue.invalidShape
            }
            text = content
        case .responses:
            guard object["object"] == nil || object["object"] as? String == "response",
                  object["choices"] == nil else { throw LLMResponseIssue.invalidShape }
            if let status = object["status"] as? String {
                switch status {
                case "completed": break
                case "incomplete": throw LLMResponseIssue.incomplete
                case "failed": throw LLMResponseIssue.failed
                case "queued", "in_progress", "cancelled": throw LLMResponseIssue.notCompleted
                default: throw LLMResponseIssue.invalidShape
                }
            } else if object["status"] != nil {
                throw LLMResponseIssue.invalidShape
            }
            if let output = object["output"] as? [[String: Any]] {
                guard object["status"] as? String == "completed" else {
                    throw LLMResponseIssue.notCompleted
                }
                var chunks = ""
                for item in output {
                    // Reasoning items carry no user text; only assistant messages do.
                    guard item["type"] as? String == "message",
                          item["role"] as? String == "assistant",
                          let contents = item["content"] as? [[String: Any]] else { continue }
                    for content in contents {
                        if content["type"] as? String == "refusal" { throw LLMResponseIssue.refused }
                        if content["type"] as? String == "output_text",
                           let chunk = content["text"] as? String { chunks += chunk }
                    }
                }
                text = chunks
            } else if object["output"] == nil, let content = object["output_text"] as? String {
                // Explicit compatible-provider shape; no business schema implied.
                text = content
            } else {
                throw LLMResponseIssue.invalidShape
            }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMResponseIssue.emptyText
        }
        return text
    }
}

public struct LLMRequestContext: Codable, Equatable, Sendable {
    public let sessionID: String
    public let requestID: String

    public init(sessionID: String = UUID().uuidString, requestID: String = UUID().uuidString) {
        self.sessionID = sessionID
        self.requestID = requestID
    }
}

public enum LLMObservationKind: String, Codable, Equatable, Sendable {
    case providerRequestStarted = "provider_request_started"
    case providerResponse = "provider_response"
    case providerFailed = "provider_failed"
}

public struct LLMProviderObservation: Codable, Equatable, Sendable {
    public let kind: LLMObservationKind
    public let component: String
    public let context: LLMRequestContext?
    public let elapsedMilliseconds: Int?
    public let httpStatus: Int?
    public let responseBytes: Int?
    public let choiceCount: Int?
    public let finishReason: String?
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let reasoningTokens: Int?
    public let model: String?
    public let endpointHost: String?
    public let transportAttempt: Int?
    public let operation: LLMOperation?
    public let compatibilityMode: LLMCompatibilityMode?
    public let thinkingControl: String?
    public let structuredOutputMode: LLMStructuredOutputMode?
    public let outcome: String?
    public let errorCode: String?

    public init(
        kind: LLMObservationKind,
        component: String = "provider",
        context: LLMRequestContext? = nil,
        elapsedMilliseconds: Int? = nil,
        httpStatus: Int? = nil,
        responseBytes: Int? = nil,
        choiceCount: Int? = nil,
        finishReason: String? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        model: String? = nil,
        endpointHost: String? = nil,
        transportAttempt: Int? = nil,
        operation: LLMOperation? = nil,
        compatibilityMode: LLMCompatibilityMode? = nil,
        thinkingControl: String? = nil,
        structuredOutputMode: LLMStructuredOutputMode? = nil,
        outcome: String? = nil,
        errorCode: String? = nil
    ) {
        self.kind = kind
        self.component = component
        self.context = context
        self.elapsedMilliseconds = elapsedMilliseconds
        self.httpStatus = httpStatus
        self.responseBytes = responseBytes
        self.choiceCount = choiceCount
        self.finishReason = finishReason
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.reasoningTokens = reasoningTokens
        self.model = model
        self.endpointHost = endpointHost
        self.transportAttempt = transportAttempt
        self.operation = operation
        self.compatibilityMode = compatibilityMode
        self.thinkingControl = thinkingControl
        self.structuredOutputMode = structuredOutputMode
        self.outcome = outcome
        self.errorCode = errorCode
    }
}

public typealias LLMObservationHandler = @Sendable (LLMProviderObservation) throws -> Void

enum LLMObservability {
    static func errorCode(for error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? LLMError {
            switch error {
            case .notConfigured: return "not_configured"
            case .badBaseURL: return "bad_base_url"
            case .transport: return "transport"
            case .http(let status, _), .httpWithRetry(let status, _, _): return "http_\(status)"
            case .usageLimitExceeded: return "usage_limit_exceeded"
            case .notChatAPI: return "not_chat_api"
            case .notResponsesAPI: return "not_responses_api"
            case .thinkingControlUnavailable: return "thinking_control_unavailable"
            case .unsupportedStructuredOutput: return "unsupported_structured_output"
            case .outputTruncated: return "output_truncated"
            case .invalidStructuredResponse: return "invalid_structured_response"
            case .refused: return "refused"
            case .streamEndedEarly: return "stream_ended_early"
            case .malformedStreamEvent: return "malformed_stream_event"
            case .streamBudgetExceeded: return "stream_budget_exceeded"
            case .cancelled: return "cancelled"
            }
        }
        if (error as? URLError)?.code == .cancelled { return "cancelled" }
        return "unknown"
    }
}

private final class SpeechRailOpenAIResponseCapture: @unchecked Sendable {
    private static let maxResponseBytes = 256 * 1024

    struct Snapshot: Sendable {
        let statusCode: Int?
        let retryAfter: TimeInterval?
        let body: String
        let rawData: Data?
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
    private var rawData: Data?
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
        rawData = isOversized ? nil : data
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
        rawData = nil
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
            rawData: rawData,
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
//   1. 对话路径对接 Responses；无状态结构化任务复用 Chat JSON 传输。
//      纪要允许在同一配置上协商普通 Responses，不要求后台响应或替换 provider。
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
    case captions
    case teleprompter
    case audiobook

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .assistant: "语音助手"
        case .minutes: "会议纪要"
        case .captions: "实时字幕翻译"
        case .teleprompter: "AI 提词器"
        case .audiobook: "有声书工坊"
        }
    }

    public var detail: String {
        switch self {
        case .assistant: "语音助手与会议中的内心 OS，共用这一类对话能力。"
        case .minutes: "会后长任务，适合结构化输出能力更强的模型。"
        case .captions: "将外语视频或音频实时流式翻译为中文字幕；中文音频自动直通不调用。"
        case .teleprompter: "主动点击才发送原稿，跟读和直播过程中不会调用。"
        case .audiobook: "主动点击分析全书时才发送正文窗口，阅读或听书过程中不会调用。"
        }
    }

    public var requiredOperation: LLMOperation {
        switch self {
        case .minutes, .captions, .teleprompter, .audiobook: .chat
        case .assistant: .responses
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
    case responseUnconfirmed(LLMResponseIssue)

    public var title: String {
        switch self {
        case .connected(let milliseconds, _): "已连接 · \(milliseconds) ms"
        case .serviceReachableModelMissing: "服务可达，但这个模型没加载"
        case .notChatAPI: "接口不对：没有 Chat Completions API"
        case .notResponsesAPI: "接口不对：没有 Responses API"
        case .unreachable: "连不上"
        case .notConfigured: "还没配置"
        case .badBaseURL: "地址不对"
        case .responseUnconfirmed: "服务可达，回答能力未确认"
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
        case .responseUnconfirmed(let issue):
            issue.detail
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
        case .notResponsesAPI: "当前服务不支持 Responses 协议（可能仅支持 Chat Completions）。"
        case .notChatAPI: "当前服务不支持 Chat Completions 协议。"
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
struct LLMResponseStreamState: Sendable {
    private enum Terminal: Sendable {
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

struct StreamReadResult: Sendable {
    let state: LLMResponseStreamState
    let byteCount: Int
    let usageData: Data?
    var usage: [String: Any]? {
        guard let usageData else { return nil }
        return (try? JSONSerialization.jsonObject(with: usageData)) as? [String: Any]
    }
}

/// The reader owns the decoder; the deadline waiter owns no transport buffers.
/// Both are drained before the run returns, and either path closes the actual URLSession task.
enum StreamRace {
    private enum Result: Sendable {
        case finished(StreamReadResult)
        case timerFired(String)
        case timerConceded
    }

    @concurrent
    static func run<Bytes: AsyncSequence & Sendable>(
        bytes: Bytes,
        onDelta: @Sendable @escaping (String) throws -> Void,
        timer: StreamTimer,
        cancelTransport: @Sendable @escaping () -> Void,
        work: StreamRunWork = StreamRunWork()
    ) async throws -> StreamReadResult where Bytes.Element == UInt8 {
        let cancellation = StreamTransportCancellation(cancelTransport)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Result.self) { group in
                group.addTask {
                    work.begin()
                    defer { work.end() }
                    var decoder = ResponsesEventStreamDecoder()
                    do {
                        for try await byte in bytes {
                            if decoder.isEventBoundary(byte) {
                                let receivedAt = ContinuousClock.now
                                try Task.checkCancellation()
                                var deltas: [String] = []
                                let terminal = try AppPerformanceMetrics.shared.measure(.llmEvent) {
                                    try decoder.consume(byte, onDelta: { deltas.append($0) })
                                }
                                try timer.advance(events: deltas.map { $0.isEmpty ? .reasoning : .text },
                                    now: receivedAt, terminal: terminal)
                                for delta in deltas { try onDelta(delta) }
                                if terminal { break }
                            } else {
                                _ = try decoder.consume(byte, onDelta: onDelta)
                            }
                        }
                        try Task.checkCancellation()
                        if !decoder.state.isFinished {
                            let receivedAt = ContinuousClock.now
                            var deltas: [String] = []
                            let previousEvents = decoder.eventCount
                            try decoder.finish(onDelta: { deltas.append($0) })
                            if decoder.eventCount != previousEvents {
                                try timer.advance(events: deltas.map { $0.isEmpty ? .reasoning : .text },
                                    now: receivedAt, terminal: decoder.state.isFinished)
                            }
                            for delta in deltas { try onDelta(delta) }
                        }
                        guard decoder.state.isFinished else { throw LLMError.streamEndedEarly }
                        let usage = try decoder.usage.map { try JSONSerialization.data(withJSONObject: $0) }
                        return .finished(.init(state: decoder.state, byteCount: decoder.byteCount, usageData: usage))
                    } catch {
                        timer.stop()
                        if error is CancellationError || (error as? URLError)?.code == .cancelled { throw LLMError.cancelled }
                        throw error
                    }
                }
                group.addTask {
                    work.begin()
                    defer { work.end() }
                    do { try await timer.waitForExpiry() }
                    catch { return .timerFired(timer.expiryReason) }
                    return .timerConceded
                }
                defer {
                    cancellation.cancel()
                    timer.stop()
                    group.cancelAll()
                }
                while let result = try await group.next() {
                    switch result {
                    case .finished(let result):
                        if Task.isCancelled { throw LLMError.cancelled }
                        return result
                    case .timerFired(let reason): throw LLMError.streamBudgetExceeded(reason)
                    case .timerConceded: continue
                    }
                }
                throw LLMError.cancelled
            }
        } onCancel: {
            cancellation.cancel()
            timer.stop()
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
    private(set) var eventCount = 0

    func isEventBoundary(_ byte: UInt8) -> Bool {
        byte == 0x0A && lineBytes.isEmpty && !dataLines.isEmpty
    }
    /// 整轮累计正文 scalar（含 delta 与 refusal delta）。V07d 有界计数，
    /// 超限由调用方显式失败，已收前缀保留。
    private(set) var totalTextScalars = 0

    /// 收到一个字节。返回 `true` 表示本轮已收束，调用方应停止读取。
    mutating func consume(
        _ byte: UInt8,
        onDelta: (String) throws -> Void
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
    mutating func finish(onDelta: (String) throws -> Void) throws {
        if !lineBytes.isEmpty {
            let line = String(decoding: lineBytes, as: UTF8.self)
            lineBytes.removeAll(keepingCapacity: true)
            if try handle(line: line, onDelta: onDelta) { return }
        }
        guard !state.isFinished, !dataLines.isEmpty else { return }
        eventCount += 1
        for object in try Self.parseEvent(dataLines) {
            if try apply(object, onDelta: onDelta) { return }
        }
        dataLines.removeAll()
        eventBytes = 0
    }

    private mutating func handle(
        line: String,
        onDelta: (String) throws -> Void
    ) throws -> Bool {
        if line.isEmpty {
            guard !state.isFinished else { return true }
            if !dataLines.isEmpty { eventCount += 1 }
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
        onDelta: (String) throws -> Void
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
        onDelta: (String) throws -> Void
    ) throws -> Bool {
        var count = 0
        let finished = try handle(object, state: &state, usage: &usage, onDelta: {
            count += $0.unicodeScalars.count
            try onDelta($0)
        })
        totalTextScalars += count
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
        onDelta: (String) throws -> Void
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
            if let delta = object["delta"] as? String { try onDelta(delta) }
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            // M1/V15:合法推理阶段是有效进展，不是停滞——推进 deadline 计时，
            // 但不产生正文、不朗读、不落库。未知 reasoning 事件走 default
            // 忽略，不延长等待（fail-closed）。
            try onDelta("")
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
    private let observationHandler: LLMObservationHandler?
    /// 已经明确拒绝原生 thinking 控制的端点（键是 `baseURL|model`）。
    /// 只记在内存里：换端点或重启后重新探一次，不做持久化。
    private var thinkingControlRejected: Set<String> = []
    /// 已经明确拒绝 strict JSON Schema 的 endpoint/model/schema 组合。
    /// 只记在内存里，避免同一整理任务的每个窗口都先失败一次再退回 JSON mode。
    private var structuredOutputRejected: Set<String> = []
    private var unformattedOutputEndpoints: Set<String> = []
    private var responsesTaskEndpoints: Set<String> = []
    private var completionTokenLimitEndpoints: Set<String> = []

    public init(
        session: URLSession = .shared,
        observationHandler: LLMObservationHandler? = nil
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
        let delivery = LLMStreamDelivery()
        let task = Task {
            do {
                try await self.runStream(
                    configuration: configuration,
                    messages: messages,
                    apiKey: apiKey,
                    maxOutputTokens: maxOutputTokens,
                    instructions: instructions,
                    firstTextTimeout: AssistantLLMStreamBudget.firstTextTimeout,
                    stallTimeout: AssistantLLMStreamBudget.textStallTimeout,
                    onDelta: { try delivery.yield($0) }
                )
                delivery.finish()
            } catch {
                delivery.finish(throwing: error)
            }
        }
        delivery.cancelWhenTerminated { task.cancel() }
        return delivery.stream
    }

    /// 专供实时字幕的低延迟流式翻译。
    ///
    /// `LLMModule.captions` 的 `requiredOperation` 为 `.chat`（`/chat/completions`），因此优先走
    /// `/chat/completions` 流式 SSE（同时兼容直接返回单包 JSON 的网关，并自动协商 thinking 控制字段与
    /// `max_tokens` / `max_completion_tokens`）；仅当端点明确不支持 Chat 接口时回退 `/responses`。
    public func streamTranslation(
        configuration: LLMConfiguration,
        prompt: String,
        instructions: String,
        apiKey: String?
    ) -> AsyncThrowingStream<String, Error> {
        let delivery = LLMStreamDelivery()
        let task = Task {
            do {
                try await self.runTranslationStream(
                    configuration: configuration,
                    prompt: prompt,
                    instructions: instructions,
                    apiKey: apiKey,
                    maxOutputTokens: 256,
                    timeout: 12,
                    onDelta: { try delivery.yield($0) }
                )
                delivery.finish()
            } catch {
                delivery.finish(throwing: error)
            }
        }
        delivery.cancelWhenTerminated { task.cancel() }
        return delivery.stream
    }

    private func runTranslationStream(
        configuration: LLMConfiguration,
        prompt: String,
        instructions: String,
        apiKey: String?,
        maxOutputTokens: Int,
        timeout: TimeInterval,
        onDelta: @Sendable @escaping (String) throws -> Void
    ) async throws {
        guard configuration.isConfigured else { throw LLMError.notConfigured }
        guard configuration.isBaseURLValid, !configuration.embedsCredential else {
            throw LLMError.badBaseURL
        }

        let responsesKey = thinkingKey(configuration, operation: .responses)
        if !responsesTaskEndpoints.contains(responsesKey) {
            do {
                try await runChatTranslationStream(
                    configuration: configuration,
                    prompt: prompt,
                    instructions: instructions,
                    apiKey: apiKey,
                    maxOutputTokens: maxOutputTokens,
                    timeout: timeout,
                    onDelta: onDelta
                )
                return
            } catch LLMError.notChatAPI {
                responsesTaskEndpoints.insert(responsesKey)
            }
        }

        let messages = [
            LLMMessage(role: .developer, text: instructions),
            LLMMessage(role: .user, text: prompt)
        ]
        do {
            try await runStream(
                configuration: configuration,
                messages: messages,
                apiKey: apiKey,
                maxOutputTokens: maxOutputTokens,
                instructions: instructions,
                firstTextTimeout: .seconds(8),
                stallTimeout: .seconds(5),
                onDelta: onDelta
            )
        } catch {
            let text = try await complete(
                configuration: configuration,
                messages: messages,
                apiKey: apiKey,
                maxOutputTokens: maxOutputTokens,
                instructions: instructions,
                timeout: timeout
            )
            if !text.isEmpty {
                try onDelta(text)
            }
        }
    }

    private func runChatTranslationStream(
        configuration: LLMConfiguration,
        prompt: String,
        instructions: String,
        apiKey: String?,
        maxOutputTokens: Int,
        timeout: TimeInterval,
        onDelta: @Sendable @escaping (String) throws -> Void
    ) async throws {
        guard let url = URL(string: "\(configuration.normalizedBaseURL)/chat/completions") else {
            throw LLMError.badBaseURL
        }
        let controlKey = thinkingKey(configuration, operation: .chat)
        var includeThinkingControl = !thinkingControlRejected.contains(controlKey)
        var useCompletionTokenLimit = completionTokenLimitEndpoints.contains(controlKey)
        let sessionID = "caption-\(UUID().uuidString)"

        for _ in 0..<3 {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("SpeechRail/caption-translator", forHTTPHeaderField: "User-Agent")
            if configuration.compatibilityMode.usesOpenCodeSessionHeader {
                request.setValue(sessionID, forHTTPHeaderField: "x-opencode-session")
            }
            if let apiKey, !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }

            var body: [String: Any] = [
                "model": configuration.model,
                "messages": [
                    ["role": "system", "content": instructions],
                    ["role": "user", "content": prompt]
                ],
                "stream": true,
                "temperature": 0
            ]
            body[useCompletionTokenLimit ? "max_completion_tokens" : "max_tokens"] = maxOutputTokens
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
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let result: (URLSession.AsyncBytes, URLResponse)
            do {
                result = try await session.bytes(for: request)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw LLMError.cancelled
                }
                throw LLMError.transport(error.localizedDescription)
            }

            guard let http = result.1 as? HTTPURLResponse else {
                result.0.task.cancel()
                throw LLMError.transport("没有收到 HTTP 响应")
            }

            if !(200..<300).contains(http.statusCode) {
                var bodyBytes = Data()
                do {
                    defer { result.0.task.cancel() }
                    for try await byte in result.0 {
                        guard bodyBytes.count < AssistantLLMStreamBudget.maxErrorBodyBytes else { break }
                        bodyBytes.append(byte)
                    }
                } catch {
                    if error is CancellationError || (error as? URLError)?.code == .cancelled {
                        throw LLMError.cancelled
                    }
                    throw LLMError.transport(error.localizedDescription)
                }
                let errorBody = String(decoding: bodyBytes, as: UTF8.self)
                if includeThinkingControl,
                   Self.rejectsThinkingControl(status: http.statusCode, body: errorBody) {
                    thinkingControlRejected.insert(controlKey)
                    includeThinkingControl = false
                    continue
                }
                if !useCompletionTokenLimit,
                   Self.requiresCompletionTokenLimit(status: http.statusCode, body: errorBody) {
                    completionTokenLimitEndpoints.insert(controlKey)
                    useCompletionTokenLimit = true
                    continue
                }
                if Self.explicitlyRejectsChat(status: http.statusCode, body: errorBody) {
                    throw LLMError.notChatAPI
                }
                throw Self.httpError(
                    status: http.statusCode,
                    body: Self.shortBody(errorBody),
                    retryAfter: nil
                )
            }

            // 2xx：支持标准 SSE 流式增量（`data: {...}`）与网关直接返回的非流式 JSON。
            defer { result.0.task.cancel() }
            var lineBytes: [UInt8] = []
            var rawBytes = Data()
            var sawSSEDataLine = false

            func consumeSSELine(_ line: String) throws -> Bool {
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmedLine.hasPrefix("data:") else { return false }
                sawSSEDataLine = true
                let payload = trimmedLine.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { return true }
                guard let data = payload.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = object["choices"] as? [[String: Any]],
                      let first = choices.first
                else { return false }

                if let delta = first["delta"] as? [String: Any],
                   let content = delta["content"] as? String,
                   !content.isEmpty {
                    try onDelta(content)
                } else if let message = first["message"] as? [String: Any],
                          let content = message["content"] as? String,
                          !content.isEmpty {
                    try onDelta(content)
                }
                return false
            }

            do {
                for try await byte in result.0 {
                    try Task.checkCancellation()
                    if !sawSSEDataLine, rawBytes.count < 256 * 1024 {
                        rawBytes.append(byte)
                    }
                    if byte == 0x0D { continue }
                    if byte == 0x0A {
                        let line = String(decoding: lineBytes, as: UTF8.self)
                        lineBytes.removeAll(keepingCapacity: true)
                        if try consumeSSELine(line) { break }
                    } else if lineBytes.count < AssistantLLMStreamBudget.maxSSELineBytes {
                        lineBytes.append(byte)
                    }
                }
                if !lineBytes.isEmpty {
                    let line = String(decoding: lineBytes, as: UTF8.self)
                    _ = try consumeSSELine(line)
                }
                if !sawSSEDataLine, !rawBytes.isEmpty,
                   let object = try? JSONSerialization.jsonObject(with: rawBytes) as? [String: Any],
                   let choices = object["choices"] as? [[String: Any]],
                   let first = choices.first,
                   let message = first["message"] as? [String: Any],
                   let content = message["content"] as? String,
                   !content.isEmpty {
                    try onDelta(content)
                }
                return
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw LLMError.cancelled
                }
                throw error
            }
        }
        throw LLMError.transport("字幕翻译请求未完成")
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
        observationContext: LLMRequestContext? = nil,
        observationHandler: LLMObservationHandler? = nil,
        structuredOutputMode: LLMStructuredOutputMode = .jsonObject,
        compatibilityFallback: Bool = false
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
        let observationContext = observationContext ?? LLMRequestContext()
        let sessionID = observationContext.sessionID
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
        var omitFormat = compatibilityFallback && unformattedOutputEndpoints.contains(structuredOutputKey)
        var useCompletionTokenLimit = compatibilityFallback && completionTokenLimitEndpoints.contains(controlKey)
        var structuredOutputFallbackUsed = false
        var thinkingFallbackUsed = false
        let lastAttempt = compatibilityFallback ? 4 : 2
        for attempt in 0...lastAttempt {
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
                structuredOutputMode: omitFormat ? nil : requestedMode,
                observer: observationHandler
            )
            do {
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
                    maxCompletionTokens: useCompletionTokenLimit ? maxOutputTokens : nil,
                    responseFormat: omitFormat ? nil : try responseFormat(
                        schema: schema,
                        mode: requestedMode
                    ),
                    store: false,
                    temperature: compatibilityFallback ? nil : 0
                )
                // MacPaw SDK 的标准 reasoning_effort 由上面的 query 编码；OpenCode 与本机
                // 模板字段由 middleware 在 Chat 请求边界注入，避免把某个 provider 的字段
                // 无条件带给其他兼容端点。
                query.maxTokens = useCompletionTokenLimit ? nil : maxOutputTokens

                let result = try await client.chats(query: query)
                try Task.checkCancellation()
                let snapshot = responseCapture.snapshot()
                guard !snapshot.isOversized else {
                    throw LLMError.invalidStructuredResponse
                }
                _ = try LLMResponseValidation.text(
                    from: snapshot.rawData ?? Data(snapshot.body.utf8),
                    operation: .chat
                )
                let content = try Self.extractChatJSON(result, maxOutputTokens: maxOutputTokens)
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
                    structuredOutputMode: omitFormat ? nil : requestedMode,
                    observer: observationHandler
                )
                return content
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
                    errorCode: LLMObservability.errorCode(for: (error as? LLMResponseIssue).map { $0 == .incomplete ? LLMError.outputTruncated : LLMError.invalidStructuredResponse } ?? error),
                    structuredOutputMode: omitFormat ? nil : requestedMode,
                    observer: observationHandler
                )
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw LLMError.cancelled
                }
                if compatibilityFallback, let status = snapshot.statusCode,
                   Self.explicitlyRejectsChat(status: status, body: snapshot.body) {
                    throw LLMError.notChatAPI
                }
                if compatibilityFallback, !useCompletionTokenLimit, attempt < lastAttempt,
                   let status = snapshot.statusCode,
                   Self.requiresCompletionTokenLimit(status: status, body: snapshot.body) {
                    useCompletionTokenLimit = true
                    completionTokenLimitEndpoints.insert(controlKey)
                    continue
                }
                if compatibilityFallback, !omitFormat, requestedMode == .jsonObject,
                   attempt < lastAttempt, let status = snapshot.statusCode,
                   Self.rejectsStructuredOutput(status: status, body: snapshot.body) {
                    omitFormat = true
                    unformattedOutputEndpoints.insert(structuredOutputKey)
                    continue
                }
                if attempt < lastAttempt, includeThinkingControl,
                   let statusCode = snapshot.statusCode,
                   !thinkingFallbackUsed,
                   Self.rejectsThinkingControl(status: statusCode, body: snapshot.body) {
                    thinkingControlRejected.insert(controlKey)
                    thinkingFallbackUsed = true
                    continue
                }
                if attempt < lastAttempt,
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
                if let issue = error as? LLMResponseIssue {
                    throw issue == .incomplete ? LLMError.outputTruncated : LLMError.invalidStructuredResponse
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

    /// 纪要等本地持有任务：只协商同一 endpoint/model 的能力，不创建远端后台任务。
    /// 只有明确拒绝接口/格式的响应可重试；传输失败、坏输出和业务错误不换协议。
    public func completeCompatibleJSON(
        configuration: LLMConfiguration,
        apiKey: String?,
        instructions: String,
        input: String,
        schema: [String: Any],
        maxOutputTokens: Int,
        timeout: TimeInterval = 900
    ) async throws -> String {
        let key = thinkingKey(configuration, operation: .responses)
        if !responsesTaskEndpoints.contains(key) {
            do {
                return try await completeJSON(
                    configuration: configuration, apiKey: apiKey,
                    instructions: instructions, input: input, schema: schema,
                    maxOutputTokens: maxOutputTokens, timeout: timeout,
                    compatibilityFallback: true
                )
            } catch LLMError.notChatAPI {
                // 明确未受理的接口拒绝才可以在同一 provider 改用普通 Responses。
            }
        }
        guard maxOutputTokens > 0, timeout.isFinite, timeout > 0,
              let definition = schema["schema"] as? [String: Any] else {
            throw LLMError.invalidStructuredResponse
        }
        let schemaText = String(decoding: try JSONSerialization.data(
            withJSONObject: definition, options: [.sortedKeys]), as: UTF8.self)
        let messages = [
            LLMMessage(role: .developer, text: instructions
                + "\n只输出一个符合以下完整 JSON Schema 的 JSON 对象，不要代码围栏或额外文字。\n" + schemaText),
            LLMMessage(role: .user, text: input)
        ]
        for includeFormat in [true, false] {
            try Task.checkCancellation()
            do {
                let (data, _) = try await performOnce(
                    configuration: configuration, messages: messages, apiKey: apiKey,
                    maxOutputTokens: maxOutputTokens,
                    textFormat: includeFormat ? ["type": "json_object"] : nil,
                    background: false, instructions: nil, timeout: timeout,
                    statelessJSON: true
                )
                responsesTaskEndpoints.insert(key)
                return try Self.extractResponsesJSON(data, maxOutputTokens: maxOutputTokens)
            } catch LLMError.unsupportedStructuredOutput where includeFormat {
                // 仍要求严格 JSON 及 feature schema，只去掉 provider 明确不支持的格式参数。
                continue
            } catch is CancellationError {
                throw LLMError.cancelled
            }
        }
        throw LLMError.invalidStructuredResponse
    }

    private static func requiresCompletionTokenLimit(status: Int, body: String) -> Bool {
        guard status == 400 || status == 422 else { return false }
        let lower = body.lowercased()
        return lower.contains("max_tokens") && lower.contains("max_completion_tokens")
            && (lower.contains("unsupported") || lower.contains("not supported"))
    }

    private static func explicitlyRejectsChat(status: Int, body: String) -> Bool {
        let lower = body.lowercased()
        // 路由存在而模型不存在也可能返回 404，不能因此再提交一次。
        if (lower.contains("model") || lower.contains("deployment")),
           lower.contains("not found") || lower.contains("model_not_found")
            || lower.contains("deployment_not_found") || lower.contains("unknown model")
            || lower.contains("does not exist") {
            return false
        }
        if status == 404 || status == 405 || status == 501 { return true }
        guard status == 400 || status == 422 else { return false }
        let mentionsOperation = lower.contains("chat/completions") || lower.contains("chat completions")
            || lower.contains("unknown endpoint") || lower.contains("endpoint not found")
        let rejectsOperation = lower.contains("not supported") || lower.contains("unsupported")
            || lower.contains("does not support") || lower.contains("not implemented")
            || lower.contains("unknown endpoint") || lower.contains("endpoint not found")
        return mentionsOperation && rejectsOperation
    }

    private static func extractResponsesJSON(_ data: Data, maxOutputTokens: Int) throws -> String {
        do {
            let text = try LLMResponseValidation.text(from: data, operation: .responses)
            struct TokenUsage: Decodable {
                struct Usage: Decodable { let output_tokens: Int }
                let usage: Usage
            }
            // JSONDecoder 严格区分整数与布尔值，避免 NSNumber 的 true/false → 1/0 桥接。
            let tokens = try JSONDecoder().decode(TokenUsage.self, from: data).usage.output_tokens
            guard tokens >= 0 else {
                throw LLMError.invalidStructuredResponse
            }
            guard tokens < maxOutputTokens else { throw LLMError.outputTruncated }
            _ = try LLMStrictJSON.object(from: Data(text.utf8))
            return text
        } catch let issue as LLMResponseIssue {
            throw issue == .incomplete ? LLMError.outputTruncated : LLMError.invalidStructuredResponse
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.invalidStructuredResponse
        }
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
        kind: LLMObservationKind,
        context: LLMRequestContext?,
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
        structuredOutputMode: LLMStructuredOutputMode? = nil,
        observer: LLMObservationHandler? = nil
    ) {
        let endpointHost = URL(string: configuration.normalizedBaseURL)?.host
        let thinkingControl: LLMThinkingControl
        switch operation {
        case .chat:
            thinkingControl = configuration.compatibilityMode.chatThinkingControl
        case .responses:
            thinkingControl = configuration.compatibilityMode.responsesThinkingControl
        }
        try? (observer ?? observationHandler)?(
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
            )
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
        do { _ = try LLMStrictJSON.object(from: Data(content.utf8)) }
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
            let observationContext = LLMRequestContext()
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            if let apiKey, !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            let providerStartedAt = Date()
            let responseCapture = SpeechRailOpenAIResponseCapture()
            emitProviderObservation(
                kind: .providerRequestStarted,
                context: observationContext,
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
                    context: observationContext,
                    configuration: configuration,
                    startedAt: providerStartedAt,
                    snapshot: nil,
                    transportAttempt: 0,
                    includeThinkingControl: false,
                    outcome: "failed",
                    errorCode: LLMObservability.errorCode(for: error),
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
                        context: observationContext,
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
                        context: observationContext,
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
                    context: observationContext,
                    configuration: configuration,
                    startedAt: providerStartedAt,
                    snapshot: responseCapture.snapshot(),
                    transportAttempt: 0,
                    includeThinkingControl: false,
                    outcome: "failed",
                    errorCode: LLMObservability.errorCode(for: error),
                    operation: .responses,
                    component: "provider_poll",
                    thinkingControlOverride: "not_applicable"
                )
                throw error
            }
        }
        throw LLMError.transport("等了很久也没整理完（超时）。")
    }

    /// 后台响应的取消结论（MA-07/MC-30、§8.4）。
    ///
    /// 三种，不是一种：确认停下来了 / 这个端点根本没有取消接口 / 问过了但没得到确认。
    /// 把后两种合并成"取消成功"就是在替用户断言一件我们并不知道的事。
    public enum BackgroundCancellation: Equatable, Sendable {
        case confirmed
        case unsupported
        case unconfirmed
    }

    /// 请求取消一个还在跑的后台响应。
    ///
    /// 兼容 OpenAI 的端点**不等于**支持 Responses 的取消扩展，所以这里
    /// 按实际回应说话：`404 / 405 / 501` 记为"这个端点没有取消能力"，
    /// 其它非 2xx 与传输错误都记为"没有确认"。调用方据此决定界面上写哪句话。
    public func cancelBackground(
        configuration: LLMConfiguration,
        apiKey: String?,
        responseID: String,
        timeout: TimeInterval = 10
    ) async -> BackgroundCancellation {
        guard
            configuration.isBaseURLValid,
            !configuration.embedsCredential,
            let url = URL(string: "\(configuration.normalizedBaseURL)/responses/\(responseID)/cancel")
        else { return .unconfirmed }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await perform(request, timeout: timeout)
            guard let http = response as? HTTPURLResponse else { return .unconfirmed }
            switch http.statusCode {
            case 404, 405, 501:
                return .unsupported
            case 200 ..< 300:
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                // 只有服务方**明确**说停了，才算确认；2xx 但状态不明仍是不确认。
                return (object?["status"] as? String) == "cancelled" ? .confirmed : .unconfirmed
            default:
                return .unconfirmed
            }
        } catch {
            return .unconfirmed
        }
    }

    private func runStream(
        configuration: LLMConfiguration,
        messages: [LLMMessage],
        apiKey: String?,
        maxOutputTokens: Int?,
        instructions: String?,
        firstTextTimeout: Duration? = nil,
        stallTimeout: Duration? = nil,
        onDelta: @Sendable @escaping (String) throws -> Void
    ) async throws {
        let observationContext = LLMRequestContext()
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
                context: observationContext,
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
                    context: observationContext,
                    configuration: configuration,
                    startedAt: providerStartedAt,
                    snapshot: nil,
                    transportAttempt: attempt,
                    includeThinkingControl: includeThinkingControl,
                    outcome: "failed",
                    errorCode: LLMObservability.errorCode(for: error),
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
                    context: observationContext,
                    configuration: configuration,
                    startedAt: providerStartedAt,
                    snapshot: nil,
                    transportAttempt: attempt,
                    includeThinkingControl: includeThinkingControl,
                    outcome: "failed",
                    errorCode: LLMObservability.errorCode(for: failure),
                    operation: .responses
                )
                throw failure
            }
            guard let response = result.1 as? HTTPURLResponse else {
                let failure = LLMError.transport("没有收到 HTTP 响应")
                emitProviderObservation(
                    kind: .providerFailed,
                    context: observationContext,
                    configuration: configuration,
                    startedAt: providerStartedAt,
                    snapshot: nil,
                    transportAttempt: attempt,
                    includeThinkingControl: includeThinkingControl,
                    outcome: "failed",
                    errorCode: LLMObservability.errorCode(for: failure),
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
            var bodyBytes = Data()
            var bodyTruncated = false
            do {
                defer { result.0.task.cancel() }
                for try await byte in result.0 {
                    guard bodyBytes.count < AssistantLLMStreamBudget.maxErrorBodyBytes else {
                        bodyTruncated = true
                        break
                    }
                    bodyBytes.append(byte)
                }
            } catch {
                let failure: LLMError = error is CancellationError || (error as? URLError)?.code == .cancelled
                    ? .cancelled : .transport(error.localizedDescription)
                emitProviderObservation(
                    kind: .providerFailed, context: observationContext, configuration: configuration,
                    startedAt: providerStartedAt, snapshot: responseCapture.snapshot(), transportAttempt: attempt,
                    includeThinkingControl: includeThinkingControl, outcome: "failed",
                    errorCode: LLMObservability.errorCode(for: failure), operation: .responses
                )
                throw failure
            }
            let body = String(decoding: bodyBytes, as: UTF8.self)
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
                context: observationContext,
                configuration: configuration,
                startedAt: providerStartedAt,
                snapshot: responseCapture.snapshot(),
                transportAttempt: attempt,
                includeThinkingControl: includeThinkingControl,
                outcome: "failed",
                errorCode: LLMObservability.errorCode(for: failure),
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
                context: observationContext,
                configuration: configuration,
                startedAt: Date(),
                snapshot: nil,
                transportAttempt: streamAttempt,
                includeThinkingControl: includeThinkingControl,
                outcome: "failed",
                errorCode: LLMObservability.errorCode(for: failure),
                operation: .responses
            )
            throw failure
        }
        do {
            // Progress is evaluated only at complete SSE events; the independent timer can cancel a stalled read.
            let timer = StreamTimer(
                firstDeadline: firstTextTimeout.map { ContinuousClock.now.advanced(by: $0) },
                stallTimeout: stallTimeout,
                initialStall: stallTimeout.map { ContinuousClock.now.advanced(by: $0) }
            )
            let result = try await StreamRace.run(
                bytes: bytes,
                onDelta: onDelta,
                timer: timer,
                cancelTransport: { bytes.task.cancel() }
            )
            // `[DONE]` 与 EOF 都只是传输结束，不是模型的成功终态。
            guard result.state.isFinished else { throw LLMError.streamEndedEarly }
            streamResponseBytes = result.byteCount
            streamUsage = result.usage
            streamResponseCapture.recordStreaming(
                response: streamResponse,
                responseBytes: streamResponseBytes,
                usage: streamUsage
            )
            emitProviderObservation(
                kind: .providerResponse,
                context: observationContext,
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
                context: observationContext,
                configuration: configuration,
                startedAt: streamStartedAt,
                snapshot: streamResponseCapture.snapshot(),
                transportAttempt: streamAttempt,
                includeThinkingControl: includeThinkingControl,
                outcome: "failed",
                errorCode: LLMObservability.errorCode(for: error),
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
        includeThinkingControl: Bool = true,
        usePromptCache: Bool = true
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
            if usePromptCache, message.cacheBreakpoint {
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
            "stream": stream
        ]
        if usePromptCache { body["prompt_cache_options"] = ["mode": "explicit"] }
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
        timeout: TimeInterval,
        statelessJSON: Bool = false
    ) async throws -> (Data, URLResponse) {
        let observationContext = LLMRequestContext()
        let controlKey = thinkingKey(configuration, operation: .responses)
        var includeThinkingControl = !thinkingControlRejected.contains(controlKey)
        for attempt in 0...1 {
            let providerStartedAt = Date()
            let responseCapture = SpeechRailOpenAIResponseCapture()
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
                    includeThinkingControl: includeThinkingControl,
                    usePromptCache: !statelessJSON
                )
            } catch {
                emitProviderObservation(
                    kind: .providerFailed,
                    context: observationContext,
                    configuration: configuration,
                    startedAt: providerStartedAt,
                    snapshot: nil,
                    transportAttempt: attempt,
                    includeThinkingControl: includeThinkingControl,
                    outcome: "failed",
                    errorCode: LLMObservability.errorCode(for: error),
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
                    context: observationContext,
                    configuration: configuration,
                    startedAt: providerStartedAt,
                    snapshot: nil,
                    transportAttempt: attempt,
                    includeThinkingControl: includeThinkingControl,
                    outcome: "failed",
                    errorCode: LLMObservability.errorCode(for: error),
                    operation: .responses
                )
                throw error
            }
            responseCapture.record(response: result.1, data: result.0)
            do {
                try Self.validate(response: result.1, data: result.0)
                if statelessJSON {
                    _ = try Self.extractResponsesJSON(result.0, maxOutputTokens: maxOutputTokens ?? 0)
                } else if !background {
                    _ = try Self.extractText(from: result.0)
                }
                emitProviderObservation(
                    kind: .providerResponse,
                    context: observationContext,
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
                    context: observationContext,
                    configuration: configuration,
                    startedAt: providerStartedAt,
                    snapshot: responseCapture.snapshot(),
                    transportAttempt: attempt,
                    includeThinkingControl: includeThinkingControl,
                    outcome: "failed",
                    errorCode: LLMObservability.errorCode(for: error),
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
        guard status == 400 || status == 422 else { return false }
        let lower = body.lowercased()
        return lower.contains("chat_template_kwargs")
            || lower.contains("thinking")
            || lower.contains("reasoning_effort")
            || lower.contains("reasoning.effort")
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
        sessionID: String,
        compatibleTask: Bool = false,
        useCompletionTokenLimit: Bool = false
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
                "stream": false
            ]
            body[useCompletionTokenLimit ? "max_completion_tokens" : "max_tokens"] = 16
            if !compatibleTask { body["temperature"] = 0 }
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

    /// 纪要的文本通路检查：与生成一致，只有明确拒绝 Chat 接口时才检查普通 Responses。
    /// 此探测不代表业务 schema 或长任务质量已通过。
    public func checkCompatibleJSON(
        configuration: LLMConfiguration,
        apiKey: String?
    ) async -> LLMConnectionResult {
        let chat = await checkOperation(configuration: configuration, apiKey: apiKey, operation: .chat,
                               compatibleTask: true)
        guard case .notChatAPI = chat else { return chat }
        return await checkOperation(configuration: configuration, apiKey: apiKey, operation: .responses,
                           compatibleTask: true)
    }

    /// 一次点击检查指定功能实际需要的 wire operation。
    public func check(
        configuration: LLMConfiguration,
        apiKey: String?,
        operation: LLMOperation = .responses,
        allowThinkingControlFallback: Bool = true
    ) async -> LLMConnectionResult {
        await checkOperation(
            configuration: configuration, apiKey: apiKey, operation: operation,
            allowThinkingControlFallback: allowThinkingControlFallback, compatibleTask: false)
    }

    private func checkOperation(
        configuration: LLMConfiguration,
        apiKey: String?,
        operation: LLMOperation,
        allowThinkingControlFallback: Bool = true,
        compatibleTask: Bool
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
        var useCompletionTokenLimit = compatibleTask && completionTokenLimitEndpoints.contains(controlKey)
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
                    sessionID: sessionID,
                    compatibleTask: compatibleTask,
                    useCompletionTokenLimit: useCompletionTokenLimit
                )
            )
            // thinking 与标准预算字段各最多协商一次，不因其他 4xx 或传输失败重试。
            for _ in 0..<2 {
                guard let http = result.1 as? HTTPURLResponse else { break }
                let body = String(decoding: result.0, as: UTF8.self)
                if includeThinkingControl,
                   Self.rejectsThinkingControl(status: http.statusCode, body: body) {
                    thinkingControlRejected.insert(controlKey)
                    if !allowThinkingControlFallback {
                        return .unreachable(LLMError.thinkingControlUnavailable.localizedDescription)
                    }
                    includeThinkingControl = false
                } else if compatibleTask, operation == .chat, !useCompletionTokenLimit,
                          Self.requiresCompletionTokenLimit(status: http.statusCode, body: body) {
                    useCompletionTokenLimit = true
                    completionTokenLimitEndpoints.insert(controlKey)
                } else {
                    break
                }
                result = try await session.data(
                    for: Self.probeRequest(
                        url: operationURL,
                        configuration: configuration,
                        apiKey: apiKey,
                        operation: operation,
                        includeThinkingControl: includeThinkingControl,
                        sessionID: sessionID,
                        compatibleTask: compatibleTask,
                        useCompletionTokenLimit: useCompletionTokenLimit
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
        if (operation == .chat
            ? Self.explicitlyRejectsChat(status: http.statusCode, body: body)
            : Self.operationUnavailable(operation, status: http.statusCode, body: body)) {
            return operation == .chat ? .notChatAPI : .notResponsesAPI
        }
        guard (200..<300).contains(http.statusCode) else {
            // 只有实际操作明确返回模型错误时，才把模型列表问题暴露给用户。
            if body.lowercased().contains("model") {
                return .serviceReachableModelMissing(configuration.model)
            }
            return .unreachable("服务回了 \(http.statusCode)：\(Self.shortBody(body))")
        }
        do {
            _ = try LLMResponseValidation.text(from: data, operation: operation)
        } catch let issue as LLMResponseIssue {
            return .responseUnconfirmed(issue)
        } catch {
            return .responseUnconfirmed(.invalidShape)
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
        do {
            return try LLMResponseValidation.text(from: data, operation: .responses)
        } catch let issue as LLMResponseIssue {
            switch issue {
            case .refused: throw LLMError.refused("服务拒绝了这次请求。")
            case .incomplete: throw LLMError.outputTruncated
            default: throw LLMError.transport(issue.detail)
            }
        }
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

enum LLMStrictJSONError: Error {
    case oversized
    case invalidSyntax
    case duplicateKey
    case notObject
}

enum LLMStrictJSON {
    static func object(from data: Data) throws -> [String: Any] {
        guard data.count <= 256 * 1024 else {
            throw LLMStrictJSONError.oversized
        }
        var scanner = Scanner(bytes: Array(data))
        try scanner.parseDocument()
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMStrictJSONError.notObject
        }
        return object
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        mutating func parseDocument() throws {
            skipWhitespace()
            try parseValue()
            skipWhitespace()
            guard index == bytes.count else { throw LLMStrictJSONError.invalidSyntax }
        }

        mutating func parseValue() throws {
            skipWhitespace()
            guard index < bytes.count else { throw LLMStrictJSONError.invalidSyntax }
            switch bytes[index] {
            case 0x7B: try parseObject()
            case 0x5B: try parseArray()
            case 0x22: _ = try parseString()
            default: try parsePrimitive()
            }
        }

        mutating func parseObject() throws {
            index += 1
            skipWhitespace()
            var keys = Set<String>()
            if consume(0x7D) { return }
            while true {
                skipWhitespace()
                let key = try parseString()
                guard keys.insert(key).inserted else {
                    throw LLMStrictJSONError.duplicateKey
                }
                skipWhitespace()
                guard consume(0x3A) else { throw LLMStrictJSONError.invalidSyntax }
                try parseValue()
                skipWhitespace()
                if consume(0x7D) { return }
                guard consume(0x2C) else { throw LLMStrictJSONError.invalidSyntax }
            }
        }

        mutating func parseArray() throws {
            index += 1
            skipWhitespace()
            if consume(0x5D) { return }
            while true {
                try parseValue()
                skipWhitespace()
                if consume(0x5D) { return }
                guard consume(0x2C) else { throw LLMStrictJSONError.invalidSyntax }
            }
        }

        mutating func parseString() throws -> String {
            guard consume(0x22) else { throw LLMStrictJSONError.invalidSyntax }
            let start = index
            while index < bytes.count {
                switch bytes[index] {
                case 0x22:
                    index += 1
                    // 按 JSON 转义后的实际字符串比较 key，拒绝 name / \u006eame 等同名键。
                    return try JSONDecoder().decode(String.self, from: Data(bytes[(start - 1)..<index]))
                case 0x5C:
                    index += 1
                    guard index < bytes.count else { throw LLMStrictJSONError.invalidSyntax }
                    if bytes[index] == 0x75 {
                        guard index + 4 < bytes.count else { throw LLMStrictJSONError.invalidSyntax }
                        index += 4
                    }
                    index += 1
                default:
                    guard bytes[index] >= 0x20 else { throw LLMStrictJSONError.invalidSyntax }
                    index += 1
                }
            }
            throw LLMStrictJSONError.invalidSyntax
        }

        mutating func parsePrimitive() throws {
            let start = index
            while index < bytes.count, ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D].contains(bytes[index]) {
                index += 1
            }
            guard index > start else { throw LLMStrictJSONError.invalidSyntax }
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }
    }
}
