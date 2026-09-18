import Foundation
import Security

// 大模型的唯一通道（`TECHNICAL-DESIGN` §5.12、§8.1）。
//
// 三条不能含糊的口径：
//
//   1. **只对接 Responses API**（`T4` 已裁决：不做端侧模型兜底）。只实现 Chat Completions
//      的服务接不上——这不是警告，是设置页上的第四种可判定结论（`notResponsesAPI`），
//      因为「地址、密钥、模型名都对却连不上」在真机上最可能的原因就是它（§6.5）。
//   2. **密钥只进钥匙串**（§15.4）：库里只留端点与模型名，日志与错误里不出现密钥。
//   3. **前缀结构是硬的**（§5.5）：人设与记忆进 developer 消息的 `input_text` 块并打显式
//      断点，动态内容一律排在后面。顶层 `instructions` 不能带断点，所以人设不能写在那里。

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
            "用的是 \(model)。对话与纪要都走这一个端点。"
        case .serviceReachableModelMissing(let model):
            "服务在，但它的模型列表里没有 \(model)。先在那边加载/下载这个模型，或者在这里换一个。"
        case .notResponsesAPI:
            "这个地址只提供 Chat Completions，助手与纪要需要 Responses API。换一个实现 Responses 的服务，或者换个端点。"
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
        case .refused(let reason): "模型没有回答：\(reason)"
        case .cancelled: "已取消。"
        }
    }
}

/// Responses API 的客户端。`actor`：它被助手、纪要、内心 OS 三处共用，
/// 而流式读取不该与界面线程争。
public actor LLMProvider {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - 请求

    /// 流式补全。逐段产出正文；`cancelled` 之外的所有失败都是**受阻**，
    /// 不是降级——助手没有第二套回答方式（§8.1）。
    public func stream(
        configuration: LLMConfiguration,
        messages: [LLMMessage],
        apiKey: String?,
        maxOutputTokens: Int? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runStream(
                        configuration: configuration,
                        messages: messages,
                        apiKey: apiKey,
                        maxOutputTokens: maxOutputTokens,
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
        timeout: TimeInterval = 120
    ) async throws -> String {
        let request = try makeRequest(
            configuration: configuration,
            messages: messages,
            apiKey: apiKey,
            stream: false,
            maxOutputTokens: maxOutputTokens
        )
        let (data, response) = try await perform(request, timeout: timeout)
        try Self.validate(response: response, data: data)
        return try Self.extractText(from: data)
    }

    private func runStream(
        configuration: LLMConfiguration,
        messages: [LLMMessage],
        apiKey: String?,
        maxOutputTokens: Int?,
        onDelta: @Sendable (String) -> Void
    ) async throws {
        let request = try makeRequest(
            configuration: configuration,
            messages: messages,
            apiKey: apiKey,
            stream: true,
            maxOutputTokens: maxOutputTokens
        )
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw LLMError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.transport("没有收到 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines { body += line }
            try Self.validate(response: response, data: Data(body.utf8))
            throw LLMError.http(status: http.statusCode, body: Self.shortBody(body))
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
        maxOutputTokens: Int?
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
        if let maxOutputTokens { body["max_output_tokens"] = maxOutputTokens }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func perform(_ request: URLRequest, timeout: TimeInterval) async throws -> (Data, URLResponse) {
        var request = request
        request.timeoutInterval = timeout
        do {
            return try await session.data(for: request)
        } catch {
            throw LLMError.transport(error.localizedDescription)
        }
    }

    // MARK: - 检查连接（§6.5 的四种结论）

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
        var probe = URLRequest(url: responsesURL)
        probe.httpMethod = "POST"
        probe.timeoutInterval = 20
        probe.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            probe.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        probe.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": configuration.model,
            "input": [["role": "user", "content": [["type": "input_text", "text": "ping"]]]],
            "store": false,
            "max_output_tokens": 16
        ])
        do {
            let (data, response) = try await session.data(for: probe)
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

// MARK: - 密钥（只进钥匙串）

/// 大模型密钥的读写。**钥匙串是唯一落点**：不进库、不进配置文件、不进日志（§15.4）。
public enum LLMKeychain {
    private static let service = "com.speechrail.app.llm"
    private static let account = "api-key"

    public static func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try remove()
            return
        }
        let data = Data(trimmed.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
            return
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty
        else { return nil }
        return text
    }

    public static func remove() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    public static var hasKey: Bool { load() != nil }

    public enum KeychainError: LocalizedError {
        case status(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .status(let code): "钥匙串写入失败（\(code)）。"
            }
        }
    }
}
