import CryptoKit
import Foundation
import Security

// 大模型的唯一通道（`TECHNICAL-DESIGN` §5.12、§8.1）。
//
// 三条不能含糊的口径：
//
//   1. **只对接 Responses API**（`T4` 已裁决：不做端侧模型兜底）。只实现 Chat Completions
//      的服务接不上——这不是警告，是设置页上的第四种可判定结论（`notResponsesAPI`），
//      因为「地址、密钥、模型名都对却连不上」在真机上最可能的原因就是它（§6.5）。
//   2. **密钥只进安全保管库**（§15.4）：库里只留端点与模型名，日志与错误里不出现密钥。
//   3. **前缀结构是硬的**（§5.5）：人设与记忆进 developer 消息的 `input_text` 块并打显式
//      断点，动态内容一律排在后面。顶层 `instructions` 不能带断点，所以人设不能写在那里。
//   4. **语音场景关 thinking，且必须能退化**：顶层 `instructions` 承载语音对话契约（每轮重发，
//      续轮不继承）；`chat_template_kwargs.enable_thinking=false` 挡住思维链（oMLX 上它会被念出来）；
//      端点不认识这组参数时只失败一次，之后按不带它的形状发。

/// 大模型服务的配置。**值本身不含密钥**：密钥只按需从钥匙串取。
public struct LLMConfiguration: Sendable, Equatable {
    /// 兼容 OpenAI 的服务地址；**不接受 URL 里带 key**（§6.5）。
    public var baseURL: String
    public var model: String

    public init(baseURL: String = "", model: String = "") {
        self.baseURL = baseURL
        self.model = model
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

    /// 端点上是否混进了凭据。带 `?api_key=` / `?key=` 的地址一律拒绝——项目约束不允许
    /// key 出现在 URL 里（`AGENTS.md` 的同一条）。
    public var embedsCredential: Bool {
        let text = baseURL.lowercased()
        return text.contains("api_key=") || text.contains("apikey=") || text.contains("key=") || text.contains("@")
    }
}

/// 一次「检查连接」的结论。四种都可判定，不出现"测试失败"（§6.5）。
public enum LLMConnectionResult: Sendable, Equatable {
    case connected(milliseconds: Int, model: String)
    case serviceReachableModelMissing(String)
    case notResponsesAPI
    case unreachable(String)
    case notConfigured
    case badBaseURL

    public var title: String {
        switch self {
        case .connected(let milliseconds, _): "已连接 · \(milliseconds) ms"
        case .serviceReachableModelMissing: "服务可达，但这个模型没加载"
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
        case .notResponsesAPI:
            "这个地址只提供 Chat Completions，助手与纪要需要 Responses API。换一个实现了 Responses 的服务，或者换个地址。"
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
    /// 端点没有 Responses API（404/405，或返回里明确说没有）。
    case notResponsesAPI
    /// 端点可达，但不支持请求要求的严格结构化输出。
    case unsupportedStructuredOutput
    case refused(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "还没有配置对话模型。"
        case .badBaseURL: "地址里不要带密钥或查询参数。"
        case .transport(let message): "连不上这台服务：\(message)"
        case .http(let status, let body):
            body.isEmpty ? "服务返回了 \(status)。" : "服务返回了 \(status)：\(body)"
        case .notResponsesAPI: "这个服务没有 Responses API。"
        case .unsupportedStructuredOutput: "这个服务不支持严格结构化输出。"
        case .refused(let reason): "模型没有回答：\(reason)"
        case .cancelled: "已取消。"
        }
    }
}

/// Responses API 的客户端。`actor`：它被助手、纪要、内心 OS 三处共用，
/// 而流式读取不该与界面线程争。
public actor LLMProvider {
    private let session: URLSession
    /// 已经明确拒绝 `chat_template_kwargs` 的端点（键是 `baseURL|model`）。
    /// 只记在内存里：换端点或重启后重新探一次，不做持久化。
    private var thinkingControlRejected: Set<String> = []

    public init(session: URLSession = .shared) {
        self.session = session
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
                    try await self.runStream(
                        configuration: configuration,
                        messages: messages,
                        apiKey: apiKey,
                        maxOutputTokens: maxOutputTokens,
                        instructions: instructions,
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
            let url = URL(string: "\(configuration.normalizedBaseURL)/responses/\(responseID)")
        else { throw LLMError.badBaseURL }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            if let apiKey, !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await perform(request, timeout: 60)
            try Self.validate(response: response, data: data)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LLMError.transport("轮询回来的不是 JSON。")
            }
            switch object["status"] as? String {
            case "completed":
                let text = try Self.extractText(from: data)
                if text.isEmpty, let reason = Self.failureReason(from: object) {
                    throw LLMError.refused(reason)
                }
                return text
            case "failed", "incomplete", "cancelled":
                throw LLMError.refused(Self.failureReason(from: object) ?? "生成没有完成")
            default:
                // queued / in_progress：等下一轮。
                try? await Task.sleep(for: .seconds(interval))
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
        onDelta: @Sendable (String) -> Void
    ) async throws {
        var suppressThinking = !thinkingControlRejected.contains(thinkingKey(configuration))
        var bytes: URLSession.AsyncBytes?
        for attempt in 0...1 {
            let request = try makeRequest(
                configuration: configuration,
                messages: messages,
                apiKey: apiKey,
                stream: true,
                maxOutputTokens: maxOutputTokens,
                instructions: instructions,
                suppressThinking: suppressThinking
            )
            let result: (URLSession.AsyncBytes, URLResponse)
            do {
                result = try await session.bytes(for: request)
            } catch {
                throw LLMError.transport(error.localizedDescription)
            }
            guard let response = result.1 as? HTTPURLResponse else {
                throw LLMError.transport("没有收到 HTTP 响应")
            }
            if (200..<300).contains(response.statusCode) {
                bytes = result.0
                break
            }
            var body = ""
            for try await line in result.0.lines { body += line }
            let failure: LLMError
            do {
                try Self.validate(response: response, data: Data(body.utf8))
                failure = .http(status: response.statusCode, body: Self.shortBody(body))
            } catch let error as LLMError {
                failure = error
            }
            // 端点不认识关 thinking 的那组参数时只失败一次：记下来，再按不带它的形状重发。
            guard attempt == 0, suppressThinking, Self.rejectsThinkingControl(failure) else {
                throw failure
            }
            thinkingControlRejected.insert(thinkingKey(configuration))
            suppressThinking = false
        }
        guard let bytes else {
            throw LLMError.transport("请求没有完成")
        }
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard
                let data = payload.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = object["type"] as? String
            else { continue }
            switch type {
            case "response.output_text.delta":
                if let delta = object["delta"] as? String { onDelta(delta) }
            case "response.refusal.delta":
                if let delta = object["delta"] as? String { onDelta(delta) }
            case "response.failed", "response.incomplete":
                let reason = Self.failureReason(from: object) ?? "生成中断"
                throw LLMError.refused(reason)
            case "error":
                let message = (object["error"] as? [String: Any])?["message"] as? String ?? "服务返回错误"
                throw LLMError.transport(message)
            default:
                continue
            }
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
        suppressThinking: Bool = true
    ) throws -> URLRequest {
        guard configuration.isConfigured else { throw LLMError.notConfigured }
        guard !configuration.embedsCredential,
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
        // 语音场景必须关掉 thinking：oMLX 上思维链会以 `reasoning_summary_text` 大量输出，
        // 预算被打满时还会混进正文，被 TTS 逐字念出来（2026-09-19 实测）。
        if suppressThinking {
            body["chat_template_kwargs"] = ["enable_thinking": false]
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
        var suppressThinking = !thinkingControlRejected.contains(thinkingKey(configuration))
        for attempt in 0...1 {
            let request = try makeRequest(
                configuration: configuration,
                messages: messages,
                apiKey: apiKey,
                stream: false,
                maxOutputTokens: maxOutputTokens,
                textFormat: textFormat,
                background: background,
                instructions: instructions,
                suppressThinking: suppressThinking
            )
            let result = try await perform(request, timeout: timeout)
            do {
                try Self.validate(response: result.1, data: result.0)
                return result
            } catch let error as LLMError {
                if textFormat != nil, Self.rejectsStructuredOutput(error) {
                    throw LLMError.unsupportedStructuredOutput
                }
                guard attempt == 0, suppressThinking, Self.rejectsThinkingControl(error) else {
                    throw error
                }
                thinkingControlRejected.insert(thinkingKey(configuration))
                suppressThinking = false
            }
        }
        throw LLMError.transport("请求没有完成")
    }

    private func thinkingKey(_ configuration: LLMConfiguration) -> String {
        "\(configuration.normalizedBaseURL)|\(configuration.model)"
    }

    /// 400 且明确指向这组参数——才是"端点不认识它"，不是别的问题。
    private static func rejectsThinkingControl(_ error: LLMError) -> Bool {
        guard case let .http(status, body) = error else { return false }
        return rejectsThinkingControl(status: status, body: body)
    }

    /// 严格结构化输出是提词器分析的安全边界：端点不支持时必须让调用方明确降级，
    /// 不能把同一份请求静默改成自由文本或 JSON mode。
    private static func rejectsStructuredOutput(_ error: LLMError) -> Bool {
        guard case let .http(status, body) = error, status == 400 || status == 422 else {
            return false
        }
        let lower = body.lowercased()
        let mentionsStructuredOutput = lower.contains("text.format")
            || lower.contains("response_format")
            || lower.contains("json_schema")
            || lower.contains("structured output")
            || lower.contains("structured_outputs")
        let rejectsCapability = lower.contains("not supported")
            || lower.contains("unsupported")
            || lower.contains("unrecognized")
            || lower.contains("unknown parameter")
            || lower.contains("not implemented")
            || lower.contains("does not support")
        return mentionsStructuredOutput && rejectsCapability
    }

    /// 同上，但直接看原始状态码与正文：`check()` 在把响应包成 `LLMError` 之前就要先判一次。
    private static func rejectsThinkingControl(status: Int, body: String) -> Bool {
        guard status == 400 else { return false }
        let lower = body.lowercased()
        return lower.contains("chat_template_kwargs")
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

    // MARK: - 检查连接（§6.5 的四种结论）

    /// 「检查连接」用的最小探测请求：`/responses` + 一条 `ping`。
    ///
    /// `chat_template_kwargs` 要不要带上由已知结论决定；端点不认识它时这里只白吃一次 400，
    /// `check()` 会重发一次不带它的形状并把结论记进 `thinkingControlRejected`，
    /// 真实对话不必再先失败一次。
    private static func probeRequest(
        url: URL,
        configuration: LLMConfiguration,
        apiKey: String?,
        suppressThinking: Bool
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        var body: [String: Any] = [
            "model": configuration.model,
            "input": [["role": "user", "content": [["type": "input_text", "text": "ping"]]]],
            "store": false,
            "max_output_tokens": 16
        ]
        if suppressThinking {
            body["chat_template_kwargs"] = ["enable_thinking": false]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// 一次点击检查两件事：服务通不通、接口对不对。
    public func check(
        configuration: LLMConfiguration,
        apiKey: String?
    ) async -> LLMConnectionResult {
        guard configuration.isConfigured else { return .notConfigured }
        guard !configuration.embedsCredential else { return .badBaseURL }

        // ① `GET /models`：连不上与"模型没加载"都在这一步分开。
        guard let modelsURL = URL(string: "\(configuration.normalizedBaseURL)/models") else {
            return .badBaseURL
        }
        var modelsRequest = URLRequest(url: modelsURL)
        modelsRequest.timeoutInterval = 10
        if let apiKey, !apiKey.isEmpty {
            modelsRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let started = Date()
        let modelsData: Data
        do {
            let (data, response) = try await session.data(for: modelsRequest)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                return .unreachable("服务回了 \(status)。地址是否写到了 /v1 这一层？")
            }
            modelsData = data
        } catch {
            return .unreachable(error.localizedDescription)
        }
        let models = Self.modelIDs(from: modelsData)
        if !models.isEmpty, !models.contains(configuration.model) {
            return .serviceReachableModelMissing(configuration.model)
        }

        // ② 用最小请求探一次 `/responses`：只实现 Chat Completions 的服务会在这里露出来。
        guard let responsesURL = URL(string: "\(configuration.normalizedBaseURL)/responses") else {
            return .badBaseURL
        }
        var suppressThinking = !thinkingControlRejected.contains(thinkingKey(configuration))
        let data: Data
        let response: URLResponse
        do {
            var result = try await session.data(
                for: Self.probeRequest(
                    url: responsesURL,
                    configuration: configuration,
                    apiKey: apiKey,
                    suppressThinking: suppressThinking
                )
            )
            // 探测阶段就把"端点认不认关 thinking 的那组参数"定下来：
            // 认识就记着用，不认识就记下来，真实对话不必先白吃一次 400。
            if suppressThinking,
               let http = result.1 as? HTTPURLResponse,
               Self.rejectsThinkingControl(
                   status: http.statusCode,
                   body: String(decoding: result.0, as: UTF8.self)
               ) {
                thinkingControlRejected.insert(thinkingKey(configuration))
                suppressThinking = false
                result = try await session.data(
                    for: Self.probeRequest(
                        url: responsesURL,
                        configuration: configuration,
                        apiKey: apiKey,
                        suppressThinking: false
                    )
                )
            }
            data = result.0
            response = result.1
        } catch {
            return .unreachable(error.localizedDescription)
        }
        do {
            guard let http = response as? HTTPURLResponse else {
                return .unreachable("没有收到 HTTP 响应")
            }
            if http.statusCode == 404 || http.statusCode == 405 {
                return .notResponsesAPI
            }
            if http.statusCode == 400 {
                let body = String(decoding: data, as: UTF8.self).lowercased()
                if body.contains("responses") || body.contains("unknown endpoint") {
                    return .notResponsesAPI
                }
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(decoding: data, as: UTF8.self)
                // 模型名不被接受时，接口本身是通的——归类到"模型没加载"更好用。
                if body.lowercased().contains("model") {
                    return .serviceReachableModelMissing(configuration.model)
                }
                return .unreachable("服务回了 \(http.statusCode)：\(Self.shortBody(body))")
            }
            let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
            return .connected(milliseconds: milliseconds, model: configuration.model)
        } catch {
            return .unreachable(error.localizedDescription)
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

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 404 || http.statusCode == 405 {
            throw LLMError.notResponsesAPI
        }
        guard !(200..<300).contains(http.statusCode) else { return }
        throw LLMError.http(status: http.statusCode, body: shortBody(String(decoding: data, as: UTF8.self)))
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

    private static var encryptedKeyURL: URL {
        securityDirectory.appendingPathComponent("llm_api_key.enc")
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

    public static func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try remove()
            return
        }
        let masterKey = try getOrCreateMasterKey()
        let data = Data(trimmed.utf8)
        let sealedBox = try AES.GCM.seal(data, using: masterKey)
        guard let combined = sealedBox.combined else {
            throw KeychainError.vaultError("加密数据封装失败")
        }
        try combined.write(to: encryptedKeyURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: encryptedKeyURL.path)
    }

    public static func load() -> String? {
        // 从本地安全加密 Vault 读取
        if let encData = try? Data(contentsOf: encryptedKeyURL),
           let masterKey = try? getOrCreateMasterKey(),
           let sealedBox = try? AES.GCM.SealedBox(combined: encData),
           let decryptedData = try? AES.GCM.open(sealedBox, using: masterKey),
           let text = String(data: decryptedData, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    public static func remove() throws {
        if FileManager.default.fileExists(atPath: encryptedKeyURL.path) {
            try? FileManager.default.removeItem(at: encryptedKeyURL)
        }
        // 清除旧钥匙串条目以防残留
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    public static var hasKey: Bool { load() != nil }

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
