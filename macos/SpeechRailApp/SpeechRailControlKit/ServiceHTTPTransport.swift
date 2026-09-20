import Foundation

public protocol ServiceTransporting: Sendable {
    func execute(_ request: URLRequest) async throws -> ServiceRawHTTPResponse
}

public final class ServiceHTTPTransport: @unchecked Sendable, ServiceTransporting {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func execute(_ request: URLRequest) async throws -> ServiceRawHTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ServiceAPIClientError.invalidResponse
            }
            var headers: [String: String] = [:]
            for (key, value) in httpResponse.allHeaderFields {
                guard let key = key as? String else { continue }
                headers[key] = String(describing: value)
            }
            return ServiceRawHTTPResponse(
                data: data,
                metadata: ServiceResponseDecoder.makeMetadata(
                    statusCode: httpResponse.statusCode,
                    headers: headers
                )
            )
        } catch let error as ServiceAPIClientError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw ServiceAPIClientError.requestTimedOut
        } catch {
            throw ServiceAPIClientError.requestFailed
        }
    }
}

public struct ServiceRequestBuilder: Sendable {
    private let baseURL: URL
    private let apiKey: String?

    public init(baseURL: URL, apiKey: String? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    public func make(
        path: String,
        method: String,
        query: [(String, String)],
        headers: [String: String],
        body: Data?
    ) throws -> URLRequest {
        guard path.hasPrefix("/"),
              !path.contains("://"),
              !path.contains("?"),
              !path.contains("#"),
              let url = URL(string: path, relativeTo: baseURL)
        else {
            throw ServiceAPIClientError.invalidURL
        }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw ServiceAPIClientError.invalidURL
        }
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let resolvedURL = components.url else {
            throw ServiceAPIClientError.invalidURL
        }

        var request = URLRequest(url: resolvedURL)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: HTTPHeaderNames.accept)
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: HTTPHeaderNames.contentType)
        }
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: HTTPHeaderNames.authorization)
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}

public protocol ServiceCapabilityDiscoveryClient: Sendable {
    func fetchEffectiveCapabilities(
        ifNoneMatch: String?
    ) async throws -> ServiceConditionalResponse<EffectiveCapabilitySnapshot>

    func fetchSafeVoices(
        ifNoneMatch: String?
    ) async throws -> ServiceConditionalResponse<SafeVoiceList>

    func fetchReadiness() async throws -> ReadySnapshot
}
