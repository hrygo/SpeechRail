import Foundation
import SpeechRailControlKit

public enum ServiceAPIClientError: Error, Sendable {
    case invalidURL
    case invalidResponse
    case requestFailed
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

    private func get<Value: Decodable>(path: String) async throws -> Value {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw ServiceAPIClientError.invalidURL
        }
        do {
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
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

extension ServiceAPIClient: ServiceDiagnosticsClient {}
