import Foundation
import SpeechRailControlKit

public enum ServiceAPIClientError: Error, Equatable, Sendable {
    case invalidURL
    case invalidResponse
    case requestFailed
    case requestTimedOut
    case server(code: String, message: String, retryable: Bool)
}

extension ServiceAPIClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "服务地址无效"
        case .invalidResponse:
            "服务返回了无法识别的结果"
        case .requestFailed:
            "无法连接本机 SpeechRail 服务"
        case .requestTimedOut:
            "本机 SpeechRail 服务响应超时"
        case .server:
            // Server detail can contain backend paths or implementation text.
            // Feature surfaces map stable error codes to user-facing copy.
            "SpeechRail 服务请求失败"
        }
    }
}

public protocol ServiceDiagnosticsClient: Sendable {
    var port: Int? { get }
    /// Figma `runtime` 的「服务端口」行写的是 `host:port`：只报端口时看不出这一行连的是
    /// 哪台主机。默认实现返回 nil，既有实现不必都实现它。
    var connectionHost: String? { get }

    func fetchHealthSnapshot() async throws -> HealthSnapshot
    func fetchMetrics() async throws -> RuntimeMetricsSnapshot
}

public extension ServiceDiagnosticsClient {
    var connectionHost: String? { nil }
}

/// 服务公开的 TTS 能力快照。
///
/// 取值只来自 `GET /v1/models` 的 `capabilities`：服务只有在对应 capability
/// 真的解析成功时才把它置为 `true`（`docs/users/api-contract.md`）。界面的能力
/// 结论必须读这里，不能拿“音色列表里有没有某一类音色”反推——音色是用户数据，可以
/// 为空；capability 由当前档位与制品解析决定，两者不是一件事。
public struct ServiceModelCapabilities: Equatable, Sendable {
    public let supportsPreview: Bool
    public let supportsClone: Bool
    public let supportsInstruction: Bool

    public init(
        supportsPreview: Bool = false,
        supportsClone: Bool = false,
        supportsInstruction: Bool = false
    ) {
        self.supportsPreview = supportsPreview
        self.supportsClone = supportsClone
        self.supportsInstruction = supportsInstruction
    }

    /// 合并同一份快照里的多个模型条目。规范条目与兼容 alias 由同一份 active
    /// catalog 派生，取并集既不必猜哪个 id 是当前档位，也不会放宽服务声明。
    func union(_ other: ServiceModelCapabilities) -> ServiceModelCapabilities {
        ServiceModelCapabilities(
            supportsPreview: supportsPreview || other.supportsPreview,
            supportsClone: supportsClone || other.supportsClone,
            supportsInstruction: supportsInstruction || other.supportsInstruction
        )
    }
}

/// 读取服务级能力声明（`GET /v1/models`）。
public protocol ServiceModelCapabilityClient: Sendable {
    func fetchModelCapabilities() async throws -> ServiceModelCapabilities
}

/// 没有本机服务连接时的能力读取端：读取失败，界面据此报“未读取”，不预报结论。
struct UnavailableModelCapabilityClient: ServiceModelCapabilityClient {
    func fetchModelCapabilities() async throws -> ServiceModelCapabilities {
        throw ServiceAPIClientError.requestFailed
    }
}

public final class ServiceAPIClient: @unchecked Sendable {
    private static let longRunningRequestTimeout: TimeInterval = 180
    private let baseURL: URL
    private let session: URLSession
    private let apiKey: String?

    public init(
        port: Int = 8201,
        session: URLSession = .shared,
        apiKey: String? = nil
    ) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.session = session
        self.apiKey = apiKey ?? SpeechRailAPICredentialProvider.resolve()
    }

    public init(
        baseURL: URL,
        session: URLSession = .shared,
        apiKey: String? = nil
    ) {
        self.baseURL = baseURL
        self.session = session
        self.apiKey = apiKey ?? SpeechRailAPICredentialProvider.resolve()
    }

    public var port: Int? { baseURL.port }

    public var connectionHost: String? { baseURL.host }

    public func fetchHealthSnapshot() async throws -> HealthSnapshot {
        try await get(path: "/health")
    }

    public func fetchHealth() async throws -> ServiceSnapshot {
        let payload = try await fetchHealthSnapshot()
        let ready = payload.ready ?? payload.asrReady.map { asrReady in
            guard let ttsReady = payload.ttsReady else { return asrReady }
            return asrReady && ttsReady
        }
        return ServiceSnapshot(
            serviceState: payload.status ?? "unknown",
            ready: ready,
            port: baseURL.port
        )
    }

    public func fetchMetrics() async throws -> RuntimeMetricsSnapshot {
        try await get(path: "/metrics")
    }

    /// 读取服务公开的 TTS 能力声明。这是能力的唯一事实来源：`supports_clone`
    /// 只有在独立 Base capability 解析成功时才为 true。
    public func fetchModelCapabilities() async throws -> ServiceModelCapabilities {
        let response: ServiceModelListResponse = try await get(path: "/v1/models")
        guard response.object == "list" else {
            throw ServiceAPIClientError.invalidResponse
        }
        return response.data
            .map(\.capabilitySnapshot)
            .reduce(ServiceModelCapabilities()) { $0.union($1) }
    }

    public func fetchVoices() async throws -> [CreatorVoice] {
        let response: CreatorVoiceListResponse = try await get(path: "/v1/voices")
        guard response.object == "list" else {
            throw ServiceAPIClientError.invalidResponse
        }
        return response.data
    }

    public func fetchVoice(id: String) async throws -> CreatorVoice {
        guard id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            throw ServiceAPIClientError.invalidURL
        }
        return try await get(path: "/v1/voices/\(id)")
    }

    public func createSpeech(
        text: String,
        voiceID: String,
        speed: Double
    ) async throws -> Data {
        try await postAudio(
            path: "/v1/audio/speech",
            body: SpeechRequestBody(
                input: text,
                voice: voiceID,
                speed: speed
            ),
            acceptedContentType: "audio/wav"
        )
    }

    public func createVoicePreview(
        text: String,
        instruction: String,
        speed: Double,
        seed: Int?
    ) async throws -> Data {
        try await postAudio(
            path: "/v1/voices/previews",
            body: VoicePreviewRequestBody(
                input: text,
                instruction: instruction,
                seed: seed,
                speed: speed
            ),
            acceptedContentType: "audio/wav"
        )
    }

    public func registerVoiceDesign(
        id: String,
        name: String,
        instruction: String,
        referenceText: String,
        seed: Int
    ) async throws -> CreatorVoice {
        let response: VoiceDesignRegistrationResponse = try await postJSON(
            path: "/v1/voices/designs",
            body: VoiceDesignRegistrationRequestBody(
                id: id,
                name: name,
                instruction: instruction,
                referenceText: referenceText,
                seed: seed
            )
        )
        return response.voice
    }

    public func updateVoice(
        id: String,
        name: String?,
        instruction: String?,
        seed: Int?
    ) async throws -> CreatorVoice {
        guard id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            throw ServiceAPIClientError.invalidURL
        }
        var request = try makeRequest(
            path: "/v1/voices/\(id)",
            method: "PATCH",
            accept: "application/json"
        )
        request.httpBody = try JSONEncoder().encode(
            UpdateVoiceRequestBody(name: name, instruction: instruction, seed: seed)
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await execute(request)
        do {
            return try JSONDecoder().decode(CreatorVoice.self, from: data)
        } catch {
            throw ServiceAPIClientError.invalidResponse
        }
    }

    /// `GET /v1/voices/clone/prompts`：官方提词稿。列表为空不是失败——服务端在资产缺失时
    /// 就返回空数组，界面照它显示「没有提词稿，自己写一段」。
    public func fetchClonePrompts() async throws -> [ClonePrompt] {
        let response: ClonePromptListResponse = try await get(path: "/v1/voices/clone/prompts")
        guard response.object == "list" else {
            throw ServiceAPIClientError.invalidResponse
        }
        return response.data
    }

    /// `POST /v1/voices/clone/validate`：与注册同一条管线，但不落任何档案。
    public func validateVoiceClone(
        audio: Data,
        referenceText: String,
        name: String,
        voiceID: String?
    ) async throws -> VoiceQualityReportSnapshot {
        let request = try makeVoiceCloneRequest(
            path: "/v1/voices/clone/validate",
            audio: audio,
            referenceText: referenceText,
            name: name,
            voiceID: voiceID,
            idempotencyKey: nil
        )
        let (data, _) = try await execute(request)
        do {
            return try JSONDecoder().decode(VoiceQualityReportSnapshot.self, from: data)
        } catch {
            throw ServiceAPIClientError.invalidResponse
        }
    }

    /// `POST /v1/voices/clone`：用参考录音注册音色。
    ///
    /// `idempotencyKey` 与 `voiceID` 由调用方在一次逻辑注册里保持不变：响应丢失时重试
    /// 同一个键，服务端会把第一次创建的那条档案还回来，而不是又建一个（§13.2）。
    public func registerVoiceClone(
        audio: Data,
        referenceText: String,
        name: String,
        voiceID: String?,
        idempotencyKey: String?
    ) async throws -> CreatorVoice {
        let request = try makeVoiceCloneRequest(
            path: "/v1/voices/clone",
            audio: audio,
            referenceText: referenceText,
            name: name,
            voiceID: voiceID,
            idempotencyKey: idempotencyKey
        )
        let (data, _) = try await execute(request)
        do {
            return try JSONDecoder().decode(CreatorVoice.self, from: data)
        } catch {
            throw ServiceAPIClientError.invalidResponse
        }
    }

    /// `POST /v1/voices/clone` 与 `…/validate` 共用一份 multipart 正文：
    /// `audio` 文件字段 + `ref_text` / `name` / 可选 `id`，与 OpenAPI `VoiceCloneRequest` 一一对应。
    private func makeVoiceCloneRequest(
        path: String,
        audio: Data,
        referenceText: String,
        name: String,
        voiceID: String?,
        idempotencyKey: String?
    ) throws -> URLRequest {
        var request = try makeRequest(path: path, method: "POST", accept: "application/json")
        request.timeoutInterval = Self.longRunningRequestTimeout
        let boundary = "speechrail-\(UUID().uuidString)"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            audio: audio,
            filename: "reference.wav",
            fields: [
                ("ref_text", referenceText),
                ("name", name),
                ("id", voiceID)
            ]
        )
        return request
    }

    /// 手工拼 multipart：URLSession 没有表单构造器，而 `text/plain` 的字段部分
    /// 必须与文件部分用同一条 boundary 串起来。字段顺序固定，便于对着请求体核对。
    nonisolated static func multipartBody(
        boundary: String,
        audio: Data,
        filename: String,
        fields: [(String, String?)]
    ) -> Data {
        var body = Data()
        func append(_ text: String) {
            body.append(Data(text.utf8))
        }
        for (name, value) in fields {
            guard let value, !value.isEmpty else { continue }
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(audio)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    public func deleteVoice(id: String) async throws {
        guard id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            throw ServiceAPIClientError.invalidURL
        }
        let request = try makeRequest(
            path: "/v1/voices/\(id)",
            method: "DELETE",
            accept: "application/json"
        )
        _ = try await execute(request)
    }

    private func get<Value: Decodable>(path: String) async throws -> Value {
        let request = try makeRequest(path: path, method: "GET", accept: "application/json")
        let (data, _) = try await execute(request)
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw ServiceAPIClientError.invalidResponse
        }
    }

    private func postJSON<Body: Encodable, Value: Decodable>(
        path: String,
        body: Body
    ) async throws -> Value {
        var request = try makeRequest(
            path: path,
            method: "POST",
            accept: "application/json"
        )
        request.timeoutInterval = Self.longRunningRequestTimeout
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await execute(request)
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw ServiceAPIClientError.invalidResponse
        }
    }

    private func postAudio<Body: Encodable>(
        path: String,
        body: Body,
        acceptedContentType: String
    ) async throws -> Data {
        var request = try makeRequest(path: path, method: "POST", accept: acceptedContentType)
        request.timeoutInterval = Self.longRunningRequestTimeout
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await execute(request)
        guard response.value(forHTTPHeaderField: "Content-Type")?
            .lowercased()
            .hasPrefix(acceptedContentType)
            == true,
            !data.isEmpty
        else {
            throw ServiceAPIClientError.invalidResponse
        }
        return data
    }

    private func makeRequest(
        path: String,
        method: String,
        accept: String
    ) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw ServiceAPIClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ServiceAPIClientError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw serverError(from: data, statusCode: httpResponse.statusCode)
            }
            return (data, httpResponse)
        } catch let error as ServiceAPIClientError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            // URLSession commonly reports Task cancellation as
            // URLError.cancelled. Preserve the cancellation boundary so
            // preview/synthesis callers do not show a false connection error.
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw ServiceAPIClientError.requestTimedOut
        } catch {
            throw ServiceAPIClientError.requestFailed
        }
    }

    private func serverError(from data: Data, statusCode: Int) -> ServiceAPIClientError {
        let payload = try? JSONDecoder().decode(ServiceAPIErrorEnvelope.self, from: data)
        return .server(
            code: payload?.error.code ?? "http_\(statusCode)",
            message: payload?.error.message ?? "SpeechRail 服务请求失败",
            retryable: payload?.error.retryable ?? (statusCode >= 500)
        )
    }
}

extension ServiceAPIClient:
    ServiceDiagnosticsClient,
    SpeechRailCreatorClient,
    ServiceModelCapabilityClient
{}

private enum SpeechRailAPICredentialProvider {
    private static let apiKeyName = "SPEECHRAIL_API_KEY"
    private static let appHomeName = "SPEECHRAIL_APP_HOME"

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let value = validated(environment[apiKeyName]) {
            return value
        }
        let appHome = managedAppHome(environment: environment)
        return readEnvFile(
            at: appHome
                .appendingPathComponent("config", isDirectory: true)
                .appendingPathComponent(".env")
        )
    }

    private static func managedAppHome(environment: [String: String]) -> URL {
        if let configured = environment[appHomeName]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            let expanded = (configured as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("SpeechRail", isDirectory: true)
    }

    private static func readEnvFile(at url: URL) -> String? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        for rawLine in contents.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ) {
            var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            guard name == apiKeyName else { continue }
            return parseValue(String(line[line.index(after: separator)...]))
        }
        return nil
    }

    private static func parseValue(_ value: String) -> String? {
        var parsed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = parsed.first, first == "'" || first == "\"" {
            let start = parsed.index(after: parsed.startIndex)
            if let closing = parsed[start...].firstIndex(of: first) {
                let suffix = parsed[parsed.index(after: closing)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if suffix.isEmpty || suffix.hasPrefix("#") {
                    parsed = String(parsed[start..<closing])
                }
            }
        } else if let comment = parsed.range(of: " #") {
            parsed = String(parsed[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return validated(parsed)
    }

    private static func validated(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\r"), !trimmed.contains("\n") else {
            return nil
        }
        return trimmed
    }
}

private struct CreatorVoiceListResponse: Decodable {
    let object: String
    let data: [CreatorVoice]
}

/// `GET /v1/voices/clone/prompts` 的信封（OpenAPI `ClonePromptList`）。
private struct ClonePromptListResponse: Decodable {
    let object: String
    let data: [ClonePrompt]
}

private struct ServiceModelListResponse: Decodable {
    let object: String
    let data: [ServiceModelEntry]
}

private struct ServiceModelEntry: Decodable {
    /// 只有 TTS 条目公开 `capabilities`；ASR 与兼容 alias 条目没有这一段。
    let capabilities: DeclaredCapabilities?

    var capabilitySnapshot: ServiceModelCapabilities {
        ServiceModelCapabilities(
            supportsPreview: capabilities?.supportsPreview == true,
            supportsClone: capabilities?.supportsClone == true,
            supportsInstruction: capabilities?.supportsInstruction == true
        )
    }

    struct DeclaredCapabilities: Decodable {
        let supportsPreview: Bool?
        let supportsClone: Bool?
        let supportsInstruction: Bool?

        enum CodingKeys: String, CodingKey {
            case supportsPreview = "supports_preview"
            case supportsClone = "supports_clone"
            case supportsInstruction = "supports_instruction"
        }
    }
}

private struct VoiceDesignRegistrationResponse: Decodable {
    let voice: CreatorVoice
}

private struct SpeechRequestBody: Encodable {
    let model = "speechrail/qwen3-tts"
    let input: String
    let voice: String
    let responseFormat = "wav"
    let speed: Double
    let language = "auto"

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case voice
        case responseFormat = "response_format"
        case speed
        case language
    }
}

private struct VoicePreviewRequestBody: Encodable {
    let model = "speechrail/qwen3-tts"
    let input: String
    let instruction: String
    let seed: Int?
    let speed: Double
    let language = "auto"
    let responseFormat = "wav"

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case instruction
        case seed
        case speed
        case language
        case responseFormat = "response_format"
    }
}

private struct VoiceDesignRegistrationRequestBody: Encodable {
    let id: String
    let name: String
    let instruction: String
    let referenceText: String
    let seed: Int
    let language = "zh"

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case instruction
        case referenceText = "reference_text"
        case seed
        case language
    }
}

private struct UpdateVoiceRequestBody: Encodable {
    let name: String?
    let instruction: String?
    let seed: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case instruction
        case seed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(instruction, forKey: .instruction)
        try container.encodeIfPresent(seed, forKey: .seed)
    }
}

private struct ServiceAPIErrorEnvelope: Decodable {
    let error: ServiceAPIError
}

private struct ServiceAPIError: Decodable {
    let code: String
    let message: String
    let retryable: Bool?
}
