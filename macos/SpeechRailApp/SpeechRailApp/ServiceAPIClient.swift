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

    func fetchHealthSnapshot() async throws -> HealthSnapshot
    func fetchMetrics() async throws -> RuntimeMetricsSnapshot
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

extension ServiceAPIClient: ServiceDiagnosticsClient, SpeechRailCreatorClient {}

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
