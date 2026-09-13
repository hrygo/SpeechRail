import Foundation
import SpeechRailControlKit

public enum ServiceAPIClientError: Error, Equatable, Sendable {
    case invalidURL
    case invalidResponse
    case requestFailed
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
        case let .server(_, message, _):
            message
        }
    }
}

public protocol ServiceDiagnosticsClient: Sendable {
    var port: Int? { get }

    func fetchHealthSnapshot() async throws -> HealthSnapshot
    func fetchMetrics() async throws -> RuntimeMetricsSnapshot
}

public final class ServiceAPIClient: @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession

    public init(port: Int = 8201, session: URLSession = .shared) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.session = session
    }

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
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
            acceptedContentType: "audio/"
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
            acceptedContentType: "audio/"
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
        } catch {
            throw ServiceAPIClientError.requestFailed
        }
    }

    private func serverError(from data: Data, statusCode: Int) -> ServiceAPIClientError {
        let payload = try? JSONDecoder().decode(ServiceAPIErrorEnvelope.self, from: data)
        return .server(
            code: payload?.error.code ?? "http_\\(statusCode)",
            message: payload?.error.message ?? "SpeechRail 服务请求失败",
            retryable: payload?.error.retryable ?? (statusCode >= 500)
        )
    }
}

extension ServiceAPIClient: ServiceDiagnosticsClient, SpeechRailCreatorClient {}

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

private struct ServiceAPIErrorEnvelope: Decodable {
    let error: ServiceAPIError
}

private struct ServiceAPIError: Decodable {
    let code: String
    let message: String
    let retryable: Bool?
}
