import Foundation
import SpeechRailControlKit

public enum ServiceAPIClientError: Error, Sendable {
    case invalidURL
    case invalidResponse
    case requestFailed
}

private struct HealthPayload: Decodable, Sendable {
    let status: String?
    let profile: SpeechRailProfile?
    let asrReady: Bool?
    let ttsReady: Bool?

    enum CodingKeys: String, CodingKey {
        case status
        case profile
        case asrReady = "asr_ready"
        case ttsReady = "tts_ready"
    }
}

public final class ServiceAPIClient: @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession

    public init(port: Int = 8201, session: URLSession = .shared) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.session = session
    }

    public func fetchHealth() async throws -> ServiceSnapshot {
        let payload: HealthPayload = try await get(path: "/health")
        let ready: Bool?
        if let asrReady = payload.asrReady, let ttsReady = payload.ttsReady {
            ready = asrReady && ttsReady
        } else {
            ready = nil
        }
        return ServiceSnapshot(
            serviceState: payload.status ?? "unknown",
            ready: ready
        )
    }

    private func get<Value: Decodable>(path: String) async throws -> Value {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw ServiceAPIClientError.invalidURL
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode)
            else {
                throw ServiceAPIClientError.invalidResponse
            }
            return try JSONDecoder().decode(Value.self, from: data)
        } catch let error as ServiceAPIClientError {
            throw error
        } catch {
            throw ServiceAPIClientError.requestFailed
        }
    }
}
