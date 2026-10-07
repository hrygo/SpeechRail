import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// `LLMProvider` 的请求形状回归（`TECHNICAL-DESIGN` §5.5 + 2026-09-19 本机兼容端点实测）。
///
/// 用假的 `URLProtocol` 当传输层：不连网、不碰钥匙串、不加载模型。钉住两条形状：
///   · 语音契约走顶层 `instructions`（不是 SpeechRail TTS 的那个 `instructions`），
///     人设与记忆留在 `input` 并带显式断点，顺序不变；
///   · 通用 OpenAI-compatible 请求只发送标准 thinking 关闭字段；OpenCode 与本机模板
///     只在显式 mode 下发送各自的专有字段，端点明确拒绝时只失败一次。
final class LLMProviderTests: XCTestCase {

    // MARK: - 假传输

    final class FakeTransport: URLProtocol {
        struct Exchange {
            var status: Int
            var contentType: String
            var body: String
            var headers: [String: String] = [:]
            /// V07f:模拟传输层失败（如 Task 取消穿透的 `URLError.cancelled`）。
            /// 非 nil 时直接 `didFailWithError`，不返回响应。
            var failCode: URLError.Code?
        }

        nonisolated(unsafe) private static var scripted: [Exchange] = []
        nonisolated(unsafe) private static var captured: [[String: Any]] = []
        nonisolated(unsafe) private static var capturedURLs: [String] = []
        nonisolated(unsafe) private static var capturedHeaders: [[String: String]] = []
        private static let lock = NSLock()

        static func reset(_ exchanges: [Exchange]) {
            lock.lock()
            defer { lock.unlock() }
            scripted = exchanges
            captured = []
            capturedURLs = []
            capturedHeaders = []
        }

        static func requestBodies() -> [[String: Any]] {
            lock.lock()
            defer { lock.unlock() }
            return captured
        }

        static func requestURLs() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return capturedURLs
        }

        static func requestHeaders() -> [[String: String]] {
            lock.lock()
            defer { lock.unlock() }
            return capturedHeaders
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.lock()
            Self.captured.append(Self.jsonBody(of: request))
            Self.capturedURLs.append(request.url?.absoluteString ?? "")
            Self.capturedHeaders.append([
                "User-Agent": request.value(forHTTPHeaderField: "User-Agent") ?? "",
                "x-opencode-session": request.value(forHTTPHeaderField: "x-opencode-session") ?? ""
            ])
            let exchange = Self.scripted.isEmpty
                ? Exchange(status: 500, contentType: "application/json", body: "{}")
                : Self.scripted.removeFirst()
            Self.lock.unlock()

            // V07f:失败注入优先——模拟 Task 取消穿透到底层传输的错误。
            if let failCode = exchange.failCode {
                client?.urlProtocol(self, didFailWithError: URLError(failCode))
                return
            }
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://127.0.0.1/v1/responses")!,
                statusCode: exchange.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": exchange.contentType].merging(exchange.headers) { _, new in new }
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(exchange.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        private static func jsonBody(of request: URLRequest) -> [String: Any] {
            guard
                let data = bodyData(of: request),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return object
        }

        /// `URLProtocol` 里 `request.httpBody` 是空的，body 在 stream 上。
        private static func bodyData(of request: URLRequest) -> Data? {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            return data
        }
    }

    final class ObservationLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [LLMProviderObservation] = []

        func append(_ observation: LLMProviderObservation) {
            lock.lock()
            stored.append(observation)
            lock.unlock()
        }

        var values: [LLMProviderObservation] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    // MARK: - 夹具

    private let configuration = LLMConfiguration(
        baseURL: "http://127.0.0.1:8000/v1",
        model: "test-model"
    )

    private let openCodeConfiguration = LLMConfiguration(
        baseURL: "https://opencode.example/v1",
        model: "vendor/strange:model",
        compatibilityMode: .openCodeGo
    )

    private let localTemplateConfiguration = LLMConfiguration(
        baseURL: "http://127.0.0.1:8000/v1",
        model: "test-model",
        compatibilityMode: .localTemplateCompatible
    )

    private static let okBody = """
    {"id":"resp_test","object":"response","status":"completed","output":[\
    {"type":"message","role":"assistant","content":[{"type":"output_text","text":"好"}]}]}
    """

    private static let responsesBodyWithUsage = """
    {"id":"resp_test","object":"response","status":"completed","output":[\
    {"type":"message","role":"assistant","content":[{"type":"output_text","text":"好"}]}],\
    "usage":{"input_tokens":8,"output_tokens":3,"output_tokens_details":{"reasoning_tokens":2}}}
    """

    private static let rejectedBody = """
    {"error":{"message":"Unrecognized request argument supplied: thinking",\
    "type":"invalid_request_error"}}
    """

    private static let unrelatedBadRequest = #"{"error":{"message":"model not found"}}"#

    private static let rejectedStructuredOutputBody = #"{"error":{"message":"Invalid parameter: text.format json_schema is not supported by this model"}}"#

    private static let invalidStructuredSchemaBody = #"{"error":{"message":"Invalid json_schema: additionalProperties must be false"}}"#

    private static let messages: [LLMMessage] = [
        LLMMessage(role: .developer, text: "# 角色风格（人设）\n简洁。", cacheBreakpoint: true),
        LLMMessage(role: .developer, text: "以下是用户确认过、可以长期记住的事：\n- 只会说中文", cacheBreakpoint: true),
        LLMMessage(role: .assistant, text: "我在。")
    ]

    private func makeProvider(
        observationHandler: LLMObservationHandler? = nil
    ) -> LLMProvider {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [FakeTransport.self]
        return LLMProvider(
            session: URLSession(configuration: sessionConfiguration),
            observationHandler: observationHandler
        )
    }

    private func complete(
        configuration: LLMConfiguration? = nil,
        instructions: String = "语音对话契约"
    ) async throws -> String {
        try await makeProvider().complete(
            configuration: configuration ?? self.configuration,
            messages: Self.messages,
            apiKey: nil,
            maxOutputTokens: 128,
            instructions: instructions
        )
    }

    private func completeJSON(
        provider: LLMProvider? = nil,
        configuration: LLMConfiguration? = nil,
        observationContext: LLMRequestContext? = nil,
        structuredOutputMode: LLMStructuredOutputMode = .jsonObject
    ) async throws -> String {
        try await (provider ?? makeProvider()).completeJSON(
            configuration: configuration ?? self.configuration, apiKey: nil,
            instructions: "保持事实", input: "原稿资料",
            schema: TeleprompterPreparationJSONSchema.map,
            maxOutputTokens: 128, timeout: 30,
            observationContext: observationContext,
            structuredOutputMode: structuredOutputMode
        )
    }

    private func chatBody(finish: String = "stop", tokens: Int? = 12,
                          content: String = "{}", refusal: String? = nil,
                          toolCalls: Bool = false,
                          partialUsageDetails: Bool = false) throws -> String {
        var message: [String: Any] = ["role": "assistant", "content": content,
                                      "reasoning_content": "这不是正文"]
        if let refusal { message["refusal"] = refusal }
        if toolCalls { message["tool_calls"] = [["id": "unexpected"]] }
        var object: [String: Any] = ["id": "chat_test", "object": "chat.completion",
                                     "created": 1, "model": "test-model", "choices": [
            ["index": 0, "finish_reason": finish, "message": message]
        ]]
        if let tokens {
            var usage: [String: Any] = [
                "prompt_tokens": 4,
                "completion_tokens": tokens,
                "total_tokens": 4 + tokens
            ]
            if partialUsageDetails {
                usage["prompt_tokens_details"] = ["cached_tokens": 0]
            }
            object["usage"] = usage
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func testChatJSONSendsCompleteSchemaAndReturnsOnlyFinalContent() async throws {
        FakeTransport.reset([.init(status: 200, contentType: "application/json", body: try chatBody())])
        let text = try await completeJSON()
        XCTAssertEqual(text, "{}")
        XCTAssertTrue(FakeTransport.requestURLs()[0].hasSuffix("/chat/completions"))
        let body = FakeTransport.requestBodies()[0]
        XCTAssertEqual((body["response_format"] as? [String: String])?["type"], "json_object")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["max_tokens"] as? Int, 128)
        XCTAssertEqual(body["temperature"] as? Double, 0)
        XCTAssertNil(body["text"])
        XCTAssertEqual(body["reasoning_effort"] as? String, "none")
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["chat_template_kwargs"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"]! }, ["system", "user"])
        XCTAssertTrue(messages[0]["content"]!.contains("additionalProperties"))
        XCTAssertTrue(messages[0]["content"]!.contains("teleprompter.preparation.v2"))
        XCTAssertEqual(messages[1]["content"], "原稿资料")
        let headers = try XCTUnwrap(FakeTransport.requestHeaders().first)
        XCTAssertEqual(headers["User-Agent"], "SpeechRail/teleprompter")
        XCTAssertTrue(headers["x-opencode-session"]?.isEmpty ?? true)
    }

    func testChatJSONCanRequestStrictSchemaAndPreservesSchemaDefinition() async throws {
        FakeTransport.reset([.init(status: 200, contentType: "application/json", body: try chatBody())])

        _ = try await completeJSON(structuredOutputMode: .jsonSchema)

        let body = FakeTransport.requestBodies()[0]
        let responseFormat = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
        let jsonSchema = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
        XCTAssertEqual(jsonSchema["name"] as? String, "teleprompter_preparation")
        XCTAssertEqual(jsonSchema["strict"] as? Bool, true)
        let schema = try XCTUnwrap(jsonSchema["schema"] as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
    }

    func testOpenCodeGoUsesJSONModeForStrictPreparation() async throws {
        FakeTransport.reset([.init(status: 200, contentType: "application/json", body: try chatBody())])

        _ = try await completeJSON(
            configuration: openCodeConfiguration,
            structuredOutputMode: .jsonSchema
        )

        let body = FakeTransport.requestBodies()[0]
        let responseFormat = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual(responseFormat["type"] as? String, "json_object")
    }

    func testChatJSONFallsBackForOpenCodeUnavailableStructuredOutput() async throws {
        FakeTransport.reset([
            .init(
                status: 400,
                contentType: "application/json",
                body: #"{"error":{"message":"Error from provider (Console): Upstream request failed: [invalid_request_error] This response_format type is unavailable now"}}"#
            ),
            .init(status: 200, contentType: "application/json", body: try chatBody())
        ])

        _ = try await completeJSON(structuredOutputMode: .jsonSchema)

        let bodies = FakeTransport.requestBodies()
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual((bodies[0]["response_format"] as? [String: Any])?["type"] as? String, "json_schema")
        XCTAssertEqual((bodies[1]["response_format"] as? [String: Any])?["type"] as? String, "json_object")
    }

    func testChatJSONFallsBackToJSONModeOnlyWhenStrictCapabilityIsRejected() async throws {
        FakeTransport.reset([
            .init(
                status: 400,
                contentType: "application/json",
                body: #"{"error":{"message":"response_format json_schema is not supported by this model"}}"#
            ),
            .init(status: 200, contentType: "application/json", body: try chatBody())
        ])

        _ = try await completeJSON(structuredOutputMode: .jsonSchema)

        let bodies = FakeTransport.requestBodies()
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual((bodies[0]["response_format"] as? [String: Any])?["type"] as? String, "json_schema")
        XCTAssertEqual((bodies[1]["response_format"] as? [String: Any])?["type"] as? String, "json_object")
    }

    func testChatJSONRemembersStrictCapabilityRejectionForSameSchemaScope() async throws {
        FakeTransport.reset([
            .init(
                status: 400,
                contentType: "application/json",
                body: #"{"error":{"message":"response_format json_schema is not supported by this model"}}"#
            ),
            .init(status: 200, contentType: "application/json", body: try chatBody()),
            .init(status: 200, contentType: "application/json", body: try chatBody())
        ])
        let provider = makeProvider()

        _ = try await provider.completeJSON(
            configuration: configuration,
            apiKey: nil,
            instructions: "整理",
            input: "原稿资料",
            schema: TeleprompterPreparationJSONSchema.map,
            maxOutputTokens: 128,
            structuredOutputMode: .jsonSchema
        )
        _ = try await provider.completeJSON(
            configuration: configuration,
            apiKey: nil,
            instructions: "整理",
            input: "原稿资料",
            schema: TeleprompterPreparationJSONSchema.map,
            maxOutputTokens: 128,
            structuredOutputMode: .jsonSchema
        )

        let bodies = FakeTransport.requestBodies()
        XCTAssertEqual(bodies.count, 3)
        XCTAssertEqual((bodies[0]["response_format"] as? [String: Any])?["type"] as? String, "json_schema")
        XCTAssertEqual((bodies[1]["response_format"] as? [String: Any])?["type"] as? String, "json_object")
        XCTAssertEqual((bodies[2]["response_format"] as? [String: Any])?["type"] as? String, "json_object")
    }

    func testChatJSONPreservesRetryAfterForTransientHTTP() async throws {
        FakeTransport.reset([
            .init(
                status: 429,
                contentType: "application/json",
                body: #"{"error":{"message":"rate limit"}}"#,
                headers: ["Retry-After": "1.5"]
            )
        ])

        do {
            _ = try await completeJSON()
            XCTFail("429 should fail with retry metadata")
        } catch let error as LLMError {
            guard case let .httpWithRetry(status, body, retryAfter) = error else {
                return XCTFail("retry metadata was lost: \(error)")
            }
            XCTAssertEqual(status, 429)
            XCTAssertEqual(body, "")
            XCTAssertEqual(retryAfter, 1.5, accuracy: 0.001)
        }
    }

    func testQuotaResponseBecomesUsageLimitInsteadOfARateLimit() async throws {
        // 配额耗尽长得像限流（都是 429 + Retry-After），但只有前者值得单独成类：
        // 上游给的 Retry-After 是「几天后」，截断成几十秒会让调用方白等一轮，
        // 也让界面没法告诉读者到底要等多久。
        FakeTransport.reset([
            .init(
                status: 429,
                contentType: "application/json",
                body: #"{"type":"error","error":{"type":"GoUsageLimitError","message":"Go usage limit exceeded"},"metadata":{"limitName":"monthly"}}"#,
                headers: ["Retry-After": "1257998"]
            )
        ])

        do {
            _ = try await completeJSON()
            XCTFail("quota exhaustion should fail")
        } catch let error as LLMError {
            guard case let .usageLimitExceeded(retryAfter) = error else {
                return XCTFail("quota exhaustion was misclassified: \(error)")
            }
            // 真实秒数必须原样传下去，判定与等待都在更下游做。
            XCTAssertEqual(try XCTUnwrap(retryAfter), 1_257_998, accuracy: 1)
        }
    }

    func testQuotaMessageNeverEchoesTheUpstreamBody() async throws {
        // 上游报错可能回显稿件或凭据，分类结论可以保留，正文不行。
        FakeTransport.reset([
            .init(
                status: 429,
                contentType: "application/json",
                body: #"{"error":{"type":"usage_limit","message":"quota exceeded for sk-live-NOT-A-REAL-KEY"}}}"#,
                headers: ["Retry-After": "600"]
            )
        ])

        do {
            _ = try await completeJSON()
            XCTFail("quota exhaustion should fail")
        } catch let error as LLMError {
            let text = error.errorDescription ?? ""
            XCTAssertFalse(text.contains("NOT-A-REAL-KEY"), "upstream body leaked into: \(text)")
        }
    }

    func testChatJSONDoesNotTreatRateLimitAsStrictCapabilityRejection() async throws {
        FakeTransport.reset([
            .init(
                status: 429,
                contentType: "application/json",
                body: #"{"error":{"message":"rate limit"}}"#
            )
        ])

        do {
            _ = try await completeJSON(structuredOutputMode: .jsonSchema)
            XCTFail("rate limiting must fail without changing output mode")
        } catch let error as LLMError {
            XCTAssertEqual(error, .http(status: 429, body: ""))
        }
        let bodies = FakeTransport.requestBodies()
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual((bodies[0]["response_format"] as? [String: Any])?["type"] as? String, "json_schema")
    }

    func testChatJSONKeepsAggregateUsageWhenProviderDetailsArePartial() async throws {
        FakeTransport.reset([
            .init(status: 200, contentType: "application/json", body: try chatBody(partialUsageDetails: true))
        ])

        let text = try await completeJSON()
        XCTAssertEqual(text, "{}")
    }

    func testChatJSONRejectsBudgetExhaustionEvenWhenProviderSaysStop() async throws {
        for body in [try chatBody(tokens: 128), try chatBody(finish: "length", tokens: 20)] {
            FakeTransport.reset([.init(status: 200, contentType: "application/json", body: body)])
            do { _ = try await completeJSON(); XCTFail("truncation accepted") }
            catch { XCTAssertEqual(error as? LLMError, .outputTruncated) }
        }
    }

    func testChatJSONRejectsOversizedResponse() async throws {
        let content = "{\"text\":\"" + String(repeating: "x", count: 270_000) + "\"}"
        FakeTransport.reset([.init(status: 200, contentType: "application/json", body: try chatBody(content: content))])
        do { _ = try await completeJSON(); XCTFail("oversized response accepted") }
        catch { XCTAssertEqual(error as? LLMError, .invalidStructuredResponse) }
    }

    func testChatJSONRejectsMissingUsageInvalidJSONRefusalAndToolCalls() async throws {
        for body in [try chatBody(tokens: nil), try chatBody(tokens: -1),
                     try chatBody(content: "not JSON"), try chatBody(refusal: "no"),
                     try chatBody(toolCalls: true), try chatBody(finish: "content_filter")] {
            FakeTransport.reset([.init(status: 200, contentType: "application/json", body: body)])
            do { _ = try await completeJSON(); XCTFail("invalid response accepted") }
            catch { XCTAssertEqual(error as? LLMError, .invalidStructuredResponse) }
        }
    }

    func testChatJSONDoesNotRetryOrChangeProtocolOnUnsupportedFormat() async throws {
        FakeTransport.reset([.init(status: 400, contentType: "application/json",
                                  body: #"{"error":{"message":"response_format unavailable"}}"#)])
        do { _ = try await completeJSON(); XCTFail("unsupported response accepted") }
        catch { guard case .http(status: 400, _) = error as? LLMError else { return XCTFail("wrong error") } }
        XCTAssertEqual(FakeTransport.requestURLs().count, 1)
    }

    func testChatJSONRetriesWithoutThinkingControlWhenProviderRejectsIt() async throws {
        FakeTransport.reset([
            .init(status: 400, contentType: "application/json", body: Self.rejectedBody),
            .init(status: 200, contentType: "application/json", body: try chatBody())
        ])

        let text = try await completeJSON(configuration: openCodeConfiguration)
        XCTAssertEqual(text, "{}")
        let bodies = FakeTransport.requestBodies()
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual((bodies[0]["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertNil(bodies[0]["chat_template_kwargs"])
        XCTAssertNil(bodies[1]["thinking"])
        let headers = FakeTransport.requestHeaders()
        XCTAssertEqual(headers[0]["x-opencode-session"], headers[1]["x-opencode-session"])
    }

    func testGenericChatRetriesWithoutStandardThinkingControlWhenProviderRejectsIt() async throws {
        FakeTransport.reset([
            .init(
                status: 400,
                contentType: "application/json",
                body: #"{"error":{"message":"unknown parameter: reasoning_effort"}}"#
            ),
            .init(status: 200, contentType: "application/json", body: try chatBody())
        ])

        let text = try await completeJSON()

        XCTAssertEqual(text, "{}")
        let bodies = FakeTransport.requestBodies()
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0]["reasoning_effort"] as? String, "none")
        XCTAssertNil(bodies[0]["thinking"])
        XCTAssertNil(bodies[1]["reasoning_effort"])
        XCTAssertTrue(FakeTransport.requestHeaders()[0]["x-opencode-session"]?.isEmpty ?? true)
    }

    func testChatJSONEmitsSafeProviderMetadataOnStructuredFailure() async throws {
        let observations = ObservationLog()
        let context = LLMRequestContext(
            sessionID: "run-test",
            requestID: "request-test"
        )
        FakeTransport.reset([
            .init(status: 200, contentType: "application/json", body: try chatBody(finish: "length", tokens: 128))
        ])

        do {
            _ = try await completeJSON(
                provider: makeProvider(observationHandler: observations.append),
                observationContext: context
            )
            XCTFail("截断响应不应成功")
        } catch let error as LLMError {
            XCTAssertEqual(error, .outputTruncated)
        }

        XCTAssertEqual(observations.values.filter { $0.kind == .providerRequestStarted }.count, 1)
        XCTAssertEqual(observations.values.filter {
            $0.kind == .providerResponse || $0.kind == .providerFailed
        }.count, 1, "one transport attempt must have one terminal observation")
        let response = try XCTUnwrap(
            observations.values.first { $0.kind == .providerFailed }
        )
        XCTAssertEqual(response.context, context)
        XCTAssertEqual(response.httpStatus, 200)
        XCTAssertEqual(response.finishReason, "length")
        XCTAssertEqual(response.completionTokens, 128)
        XCTAssertGreaterThan(response.responseBytes ?? 0, 0)
        XCTAssertEqual(response.operation, .chat)
        XCTAssertEqual(response.compatibilityMode, .openAICompatible)
        XCTAssertEqual(response.thinkingControl, "standard_disabled")

        let failure = try XCTUnwrap(
            observations.values.first { $0.kind == .providerFailed }
        )
        XCTAssertEqual(failure.errorCode, "output_truncated")
        XCTAssertEqual(failure.context, context)
    }

    func testChatJSONReusesStableOpenCodeSessionForOnePreparationRun() async throws {
        let context = LLMRequestContext(
            sessionID: "run-stable",
            requestID: "request-1"
        )
        FakeTransport.reset([
            .init(status: 200, contentType: "application/json", body: try chatBody()),
            .init(status: 200, contentType: "application/json", body: try chatBody())
        ])
        let provider = makeProvider()

        _ = try await completeJSON(
            provider: provider,
            configuration: openCodeConfiguration,
            observationContext: context
        )
        _ = try await completeJSON(
            provider: provider,
            configuration: openCodeConfiguration,
            observationContext: .init(
                sessionID: context.sessionID,
                requestID: "request-2"
            )
        )

        let headers = FakeTransport.requestHeaders()
        XCTAssertEqual(headers.count, 2)
        XCTAssertEqual(headers[0]["x-opencode-session"], "run-stable")
        XCTAssertEqual(headers[1]["x-opencode-session"], "run-stable")
    }

    // MARK: - 断言

    func testBaseURLRejectsQueryAndFragment() {
        XCTAssertTrue(
            LLMConfiguration(
                baseURL: "http://127.0.0.1:8000/v1",
                model: "test-model"
            ).isBaseURLValid
        )
        XCTAssertFalse(
            LLMConfiguration(
                baseURL: "http://127.0.0.1:8000/v1?api_key=secret",
                model: "test-model"
            ).isBaseURLValid
        )
        XCTAssertFalse(
            LLMConfiguration(
                baseURL: "http://127.0.0.1:8000/v1#fragment",
                model: "test-model"
            ).isBaseURLValid
        )
        let arbitrary = LLMConfiguration(
            baseURL: "https://provider.example/custom/v1/",
            model: "vendor/strange:model@2026",
            compatibilityMode: .openAICompatible
        )
        XCTAssertTrue(arbitrary.isConfigured)
        XCTAssertEqual(arbitrary.normalizedBaseURL, "https://provider.example/custom/v1")
        XCTAssertEqual(arbitrary.model, "vendor/strange:model@2026")
    }

    func testConnectionRejectsInvalidBaseURLBeforeRequest() async {
        FakeTransport.reset([
            .init(status: 200, contentType: "application/json", body: Self.modelsBody)
        ])

        let result = await makeProvider().check(
            configuration: LLMConfiguration(
                baseURL: "http://127.0.0.1:8000/v1?trace=1",
                model: "test-model"
            ),
            apiKey: nil
        )

        XCTAssertEqual(result, .badBaseURL)
        XCTAssertTrue(FakeTransport.requestURLs().isEmpty)
    }

    func testCompleteSendsVoiceContractAndSuppressesThinking() async throws {
        FakeTransport.reset([.init(status: 200, contentType: "application/json", body: Self.okBody)])

        let text = try await complete()

        XCTAssertEqual(text, "好")
        let body = try XCTUnwrap(FakeTransport.requestBodies().first)
        XCTAssertEqual(body["instructions"] as? String, "语音对话契约")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "none")
        XCTAssertNil(body["chat_template_kwargs"])

        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.compactMap { $0["role"] as? String }, ["developer", "developer", "assistant"])
        let persona = try XCTUnwrap((input[0]["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(persona["type"] as? String, "input_text")
        XCTAssertNotNil(persona["prompt_cache_breakpoint"])
        let memory = try XCTUnwrap((input[1]["content"] as? [[String: Any]])?.first)
        XCTAssertNotNil(memory["prompt_cache_breakpoint"])
        let history = try XCTUnwrap((input[2]["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(history["type"] as? String, "output_text")
        XCTAssertNil(history["prompt_cache_breakpoint"])
    }

    func testResponsesProviderEmitsSafeObservationMetadata() async throws {
        FakeTransport.reset([.init(status: 200, contentType: "application/json", body: Self.responsesBodyWithUsage)])
        let observations = ObservationLog()
        let provider = makeProvider(observationHandler: observations.append)

        _ = try await provider.complete(
            configuration: configuration,
            messages: Self.messages,
            apiKey: nil,
            instructions: "语音对话契约"
        )

        let started = try XCTUnwrap(observations.values.first { $0.kind == .providerRequestStarted })
        let response = try XCTUnwrap(observations.values.first { $0.kind == .providerResponse })
        XCTAssertEqual(started.operation, .responses)
        XCTAssertEqual(started.compatibilityMode, .openAICompatible)
        XCTAssertEqual(started.thinkingControl, "standard_disabled")
        XCTAssertEqual(started.outcome, "started")
        XCTAssertEqual(response.operation, .responses)
        XCTAssertEqual(response.httpStatus, 200)
        XCTAssertEqual(response.promptTokens, 8)
        XCTAssertEqual(response.completionTokens, 3)
        XCTAssertEqual(response.reasoningTokens, 2)
        XCTAssertEqual(response.outcome, "received")
        XCTAssertNotNil(started.context)
        XCTAssertEqual(started.context, response.context)
    }

    func testThrowingObserverDoesNotChangeSuccessFailureOrCancellation() async throws {
        enum ObserverFailure: Error { case unavailable }
        let provider = makeProvider(observationHandler: { _ in throw ObserverFailure.unavailable })
        FakeTransport.reset([.init(status: 200, contentType: "application/json", body: try chatBody())])
        let content = try await completeJSON(provider: provider)
        XCTAssertEqual(content, "{}")

        FakeTransport.reset([.init(status: 200, contentType: "application/json", body: try chatBody(finish: "length"))])
        do {
            _ = try await completeJSON(provider: provider)
            XCTFail("truncation must survive observation failure")
        } catch let error as LLMError { XCTAssertEqual(error, .outputTruncated) }

        FakeTransport.reset([.init(status: 200, contentType: "application/json", body: "", failCode: .cancelled)])
        do {
            _ = try await completeJSON(provider: provider)
            XCTFail("cancellation must survive observation failure")
        } catch let error as LLMError { XCTAssertEqual(error, .cancelled) }
    }

    func testPerCallObserverReplacesDefaultWithoutDoubleDelivery() async throws {
        let global = ObservationLog()
        let local = ObservationLog()
        let provider = makeProvider(observationHandler: global.append)
        FakeTransport.reset([.init(status: 200, contentType: "application/json", body: try chatBody())])
        _ = try await provider.completeJSON(
            configuration: configuration, apiKey: nil, instructions: "schema", input: "fixture",
            schema: TeleprompterPreparationJSONSchema.map, maxOutputTokens: 128,
            observationHandler: local.append
        )
        XCTAssertTrue(global.values.isEmpty)
        XCTAssertEqual(local.values.map(\.kind), [.providerRequestStarted, .providerResponse])
        XCTAssertNotNil(local.values.first?.context)
        XCTAssertEqual(local.values.first?.context, local.values.last?.context)
    }

    @MainActor
    func testResponsesStreamEmitsProviderObservationMetadata() async throws {
        FakeTransport.reset([
            .init(
                status: 200,
                contentType: "text/event-stream",
                body: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"好\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":8,\"output_tokens\":3,\"output_tokens_details\":{\"reasoning_tokens\":2}}}}\n\ndata: [DONE]\n\n"
            )
        ])
        let observations = ObservationLog()
        let provider = makeProvider(observationHandler: observations.append)
        var text = ""

        let stream = await provider.stream(
            configuration: configuration,
            messages: Self.messages,
            apiKey: nil,
            instructions: "语音对话契约"
        )
        for try await delta in stream {
            text += delta
        }

        XCTAssertEqual(text, "好")
        XCTAssertEqual(observations.values.filter { $0.kind == .providerRequestStarted }.count, 1)
        let response = try XCTUnwrap(observations.values.first { $0.kind == .providerResponse })
        XCTAssertEqual(response.operation, .responses)
        XCTAssertEqual(response.httpStatus, 200)
        XCTAssertEqual(response.promptTokens, 8)
        XCTAssertEqual(response.completionTokens, 3)
        XCTAssertEqual(response.reasoningTokens, 2)
        XCTAssertEqual(response.outcome, "received")
    }

    @MainActor
    func testAssistantStreamUsesLocalTemplateThinkingControl() async throws {
        FakeTransport.reset([
            .init(
                status: 200,
                contentType: "text/event-stream",
                body: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"好\"}\n\ndata: {\"type\":\"response.completed\"}\n\n"
            )
        ])

        let stream = await makeProvider().stream(
            configuration: localTemplateConfiguration,
            messages: Self.messages,
            apiKey: nil,
            instructions: "语音对话契约"
        )
        var text = ""
        for try await delta in stream { text += delta }

        XCTAssertEqual(text, "好")
        let body = try XCTUnwrap(FakeTransport.requestBodies().first)
        XCTAssertEqual(
            (body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"],
            false
        )
        XCTAssertNil(body["reasoning"])
    }

    @MainActor
    func testAssistantStreamDoesNotRetryWithoutThinkingControl() async throws {
        FakeTransport.reset([
            .init(status: 400, contentType: "application/json", body: Self.rejectedBody),
            .init(status: 200, contentType: "application/json", body: Self.okBody)
        ])

        let stream = await makeProvider().stream(
            configuration: localTemplateConfiguration,
            messages: Self.messages,
            apiKey: nil,
            instructions: "语音对话契约"
        )
        do {
            for try await _ in stream {}
            XCTFail("语音助手不能在关闭 thinking 失败后省略控制字段重试")
        } catch let error as LLMError {
            XCTAssertEqual(error, .thinkingControlUnavailable)
        }
        XCTAssertEqual(FakeTransport.requestBodies().count, 1)
    }

    // MARK: - D10：Responses 流必须以明确的成功终态收束

    @MainActor
    private func drainResponsesStream(_ provider: LLMProvider) async -> Result<String, Error> {
        do {
            var text = ""
            let stream = await provider.stream(
                configuration: configuration,
                messages: Self.messages,
                apiKey: nil,
                instructions: "语音对话契约"
            )
            for try await delta in stream {
                text += delta
            }
            return .success(text)
        } catch {
            return .failure(error)
        }
    }

    /// delta 之后直接 EOF：以前会被当成成功返回整段正文，
    /// 于是半截回答被朗读、被落库、被当成"模型答完了"。
    @MainActor
    func testResponsesStreamDeltaThenEOFAreNotSuccess() async throws {
        FakeTransport.reset([
            .init(
                status: 200,
                contentType: "text/event-stream",
                body: "data: {\"type\":\"response.output_text.delta\",\"response_id\":\"resp_a\",\"delta\":\"好\"}\n\n"
            )
        ])
        let result = await drainResponsesStream(makeProvider())

        switch result {
        case .success(let text):
            XCTFail("没有成功终态就结束，必须是失败，实际拿到 \(text)")
        case .failure(let error):
            XCTAssertEqual(error as? LLMError, .streamEndedEarly)
        }
    }

    /// `[DONE]` 只表示传输关闭，不是模型的成功终态。
    @MainActor
    func testResponsesStreamDeltaThenDoneSentinelIsNotSuccess() async throws {
        FakeTransport.reset([
            .init(
                status: 200,
                contentType: "text/event-stream",
                body: "data: {\"type\":\"response.output_text.delta\",\"response_id\":\"resp_a\",\"delta\":\"好\"}\n\ndata: [DONE]\n\n"
            )
        ])
        let result = await drainResponsesStream(makeProvider())

        switch result {
        case .success(let text):
            XCTFail("[DONE] 不能代替 response.completed，实际拿到 \(text)")
        case .failure(let error):
            XCTAssertEqual(error as? LLMError, .streamEndedEarly)
        }
    }

    @MainActor
    func testResponsesStreamCompletedThenGarbageStillSucceeds() async throws {
        FakeTransport.reset([
            .init(
                status: 200,
                contentType: "text/event-stream",
                body: """
                data: {"type":"response.output_text.delta","response_id":"resp_a","delta":"好"}

                data: {"type":"response.completed","response":{"id":"resp_a"}}

                data: { 这不是 JSON

                data: [DONE]

                """
            )
        ])
        let result = await drainResponsesStream(makeProvider())

        XCTAssertEqual(try result.get(), "好", "收到合法 completed 之后就该收尾，不再要求提供方关 TCP")
    }

    @MainActor
    func testResponsesStreamEmptyCompletedSucceeds() async throws {
        FakeTransport.reset([
            .init(
                status: 200,
                contentType: "text/event-stream",
                body: "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_a\"}}\n\ndata: [DONE]\n\n"
            )
        ])
        let result = await drainResponsesStream(makeProvider())

        XCTAssertEqual(try result.get(), "", "空的成功响应是合法的，交给上层提示空内容")
    }

    @MainActor
    func testResponsesStreamRefusalStillNeedsASuccessfulTerminal() async throws {
        FakeTransport.reset([
            .init(
                status: 200,
                contentType: "text/event-stream",
                body: "data: {\"type\":\"response.refusal.delta\",\"response_id\":\"resp_a\",\"delta\":\"我不能\"}\n\ndata: [DONE]\n\n"
            )
        ])
        let result = await drainResponsesStream(makeProvider())

        switch result {
        case .success(let text):
            XCTFail("refusal delta 不等于成功终态，实际拿到 \(text)")
        case .failure(let error):
            XCTAssertEqual(error as? LLMError, .streamEndedEarly)
        }
    }

    @MainActor
    func testResponsesStreamRejectsTerminalOfAnotherResponse() async throws {
        FakeTransport.reset([
            .init(
                status: 200,
                contentType: "text/event-stream",
                body: """
                data: {"type":"response.output_text.delta","response_id":"resp_a","delta":"好"}

                data: {"type":"response.completed","response":{"id":"resp_b"}}

                data: [DONE]

                """
            )
        ])
        let result = await drainResponsesStream(makeProvider())

        switch result {
        case .success(let text):
            XCTFail("别的响应的成功终态不能收束本轮，实际拿到 \(text)")
        case .failure(let error):
            XCTAssertEqual(error as? LLMError, .streamEndedEarly)
        }
    }

    @MainActor
    func testResponsesStreamMalformedDataDoesNotSilentlyBecomeSuccess() async throws {
        FakeTransport.reset([
            .init(
                status: 200,
                contentType: "text/event-stream",
                body: """
                data: {"type":"response.output_text.delta","response_id":"resp_a","delta":"好"}

                data: { 这不是 JSON

                data: {"type":"response.completed","response":{"id":"resp_a"}}

                """
            )
        ])
        let result = await drainResponsesStream(makeProvider())

        switch result {
        case .success(let text):
            XCTFail("坏 JSON 不能被静默跳过直到假成功，实际拿到 \(text)")
        case .failure(let error):
            XCTAssertEqual(error as? LLMError, .malformedStreamEvent)
        }
    }

    /// 一个 SSE 事件可以由多行 `data:` 拼成；按行解析会把它读成两个坏事件。
    @MainActor
    func testResponsesStreamJoinsMultiLineDataFields() async throws {
        FakeTransport.reset([
            .init(
                status: 200,
                contentType: "text/event-stream",
                body: """
                data: {"type":"response.output_text.delta",
                data: "response_id":"resp_a","delta":"好"}

                data: {"type":"response.completed","response":{"id":"resp_a"}}

                data: [DONE]

                """
            )
        ])
        let result = await drainResponsesStream(makeProvider())

        XCTAssertEqual(try result.get(), "好")
    }

    // MARK: - M2/V07:流预算有界

    /// V07a:无换行 SSE 单行无限增长必须有界——超限显式失败，不无界积压。
    /// 已收到的正文由调用方保留，不得静默丢 token，不得强制完成/朗读。
    @MainActor
    func testResponsesStreamSingleLineBeyondBudgetFailsExplicitly() async throws {
        final class Sink: @unchecked Sendable { var deltas: [String] = [] }
        let sink = Sink()
        var decoder = ResponsesEventStreamDecoder()
        let filler = String(repeating: "x", count: 1024)
        var thrown: Error?
        // 先喂一个合法 delta 并结算（空行即事件边界），再喂超长无换行单行。
        let head = "data: {\"type\":\"response.output_text.delta\",\"response_id\":\"resp_a\",\"delta\":\"好\"}\n\n"
        for byte in head.utf8 { try? decoder.consume(byte, onDelta: { sink.deltas.append($0) }) }
        do {
            for _ in 0..<(AssistantLLMStreamBudget.maxSSELineBytes / 1024 + 2) {
                for byte in filler.utf8 {
                    try decoder.consume(byte, onDelta: { sink.deltas.append($0) })
                }
            }
        } catch {
            thrown = error
        }
        guard case .streamBudgetExceeded(let detail) = thrown as? LLMError else {
            XCTFail("超长无换行单行必须报 streamBudgetExceeded，实际 \(String(describing: thrown))")
            return
        }
        XCTAssertTrue(detail.contains("单行"), "失败原因应指明是单行超限，实际 \(detail)")
        XCTAssertEqual(sink.deltas, ["好"], "超限前已收到的正文必须保留")
    }

    /// V07b:多行 data: 拼成的单事件同样有界——超限显式失败。
    @MainActor
    func testResponsesStreamSingleEventBeyondBudgetFailsExplicitly() async throws {
        final class Sink: @unchecked Sendable { var deltas: [String] = [] }
        let sink = Sink()
        var decoder = ResponsesEventStreamDecoder()
        let filler = String(repeating: "y", count: 4096)
        var thrown: Error?
        do {
            for _ in 0..<(AssistantLLMStreamBudget.maxSSEEventBytes / 4096 + 2) {
                let line = "data: " + filler + "\n"
                for byte in line.utf8 {
                    try decoder.consume(byte, onDelta: { sink.deltas.append($0) })
                }
            }
        } catch {
            thrown = error
        }
        guard case .streamBudgetExceeded(let detail) = thrown as? LLMError else {
            XCTFail("超限单事件必须报 streamBudgetExceeded，实际 \(String(describing: thrown))")
            return
        }
        XCTAssertTrue(detail.contains("单事件"), "失败原因应指明是单事件超限，实际 \(detail)")
    }

    /// V07c:巨大错误 body 不得无界累加——截断并标记，正文仍可分类。
    @MainActor
    func testResponsesStreamHugeErrorBodyIsTruncatedAndMarked() async throws {
        // runStream 先发 attempt 0（含 thinking 控制字段，FakeTransport 按序消费）。
        // 500 非 400 不触发 thinking-control 回退：attempt 0 即进入错误 body 路径。
        let huge = String(repeating: "E", count: AssistantLLMStreamBudget.maxErrorBodyBytes + 4096)
        FakeTransport.reset([
            .init(
                status: 500,
                contentType: "text/plain",
                body: huge
            )
        ])
        let result = await drainResponsesStream(makeProvider())
        switch result {
        case .success(let text):
            XCTFail("500 必须是失败，实际拿到 \(text)")
        case .failure(let error):
            guard case .http(let status, let body) = error as? LLMError else {
                XCTFail("500 应为 .http，实际 \(error)")
                return
            }
            XCTAssertEqual(status, 500)
            XCTAssertTrue(body.contains("正文超限已截断"), "超限错误正文必须标记截断")
            XCTAssertLessThanOrEqual(
                body.utf8.count,
                AssistantLLMStreamBudget.maxErrorBodyBytes + 512,
                "错误正文不得无界累加"
            )
        }
    }

    // MARK: - M2/V07d:累计正文有界（decoder 层，不经过网络计时器）

    /// V07d:整轮累计正文超限必须显式失败，不静默丢 token，已收前缀保留。
    /// decoder 是同步值类型：直接喂事件验证计数边界，不依赖网络计时。
    func testResponsesStreamTotalTextBeyondBudgetFailsExplicitly() throws {
        final class Sink: @unchecked Sendable { var deltas: [String] = [] }
        let sink = Sink()
        var state = LLMResponseStreamState()
        var usage: [String: Any]?
        var total = 0
        // 每个 delta 4096 scalars：5 个即超 16,384 上限。
        let big = String(repeating: "文", count: 4096)
        var thrown: Error?
        do {
            for i in 0..<5 {
                let object: [String: Any] = [
                    "type": "response.output_text.delta",
                    "response_id": "resp_a",
                    "delta": big + String(i),
                ]
                _ = try ResponsesEventStreamDecoder.countedHandle(
                    object,
                    state: &state,
                    usage: &usage,
                    totalTextScalars: &total,
                    onDelta: { sink.deltas.append($0) }
                )
            }
        } catch {
            thrown = error
        }
        guard case .streamBudgetExceeded(let detail) = thrown as? LLMError else {
            XCTFail("累计正文超限必须报 streamBudgetExceeded，实际 \(String(describing: thrown))")
            return
        }
        XCTAssertTrue(detail.contains("累计正文"), "失败原因应指明是累计正文超限，实际 \(detail)")
        XCTAssertEqual(sink.deltas.joined().unicodeScalars.count, 4 * 4097, "超限前已收到的正文必须保留")
    }

    /// V07d:累计正文未超限时计数精确累加，不误杀合法回答。
    func testResponsesStreamTotalTextWithinBudgetCountsExactly() throws {
        final class Sink: @unchecked Sendable { var text = "" }
        let sink = Sink()
        var state = LLMResponseStreamState()
        var usage: [String: Any]?
        var total = 0
        let object: [String: Any] = [
            "type": "response.output_text.delta",
            "response_id": "resp_a",
            "delta": "你好世界",
        ]
        _ = try ResponsesEventStreamDecoder.countedHandle(
            object,
            state: &state,
            usage: &usage,
            totalTextScalars: &total,
            onDelta: { sink.text += $0 }
        )
        XCTAssertEqual(total, 4, "累计计数应精确为 4 scalars")
        XCTAssertEqual(sink.text, "你好世界")
    }

    // MARK: - M2/V07e:首正文与停滞 deadline 状态机

    /// V07e:首个有效正文到达前 deadline 到达，必须立超限旗并抛错。
    func testStreamTimerFirstTextTimeoutFires() async throws {
        let timer = StreamTimer(
            firstDeadline: ContinuousClock.now,
            stallTimeout: nil,
            initialStall: nil
        )
        do {
            try await timer.waitForExpiry()
            XCTFail("首正文 deadline 已到，必须抛超限错误")
        } catch let error as LLMError {
            guard case .streamBudgetExceeded(let detail) = error else {
                XCTFail("应为 streamBudgetExceeded，实际 \(error)")
                return
            }
            XCTAssertTrue(detail.contains("首个有效正文"), "失败原因应指明首正文超时，实际 \(detail)")
        }
        let expired = await timer.expired
        XCTAssertTrue(expired, "超限后 expired 旗必须立起，供读取循环在下一字节处抛同错")
    }

    /// V07e:见有效正文后首正文 deadline 解除；停滞 deadline 由正文推进重置。
    /// 心跳/注释不调用 noteText，不延长等待——此处直接验证"不调用即不重置"：
    /// deadline 按墙钟推进，不因等待中的事件而顺延。
    func testStreamTimerTextResetsStallDeadline() async throws {
        let timer = StreamTimer(
            firstDeadline: nil,
            stallTimeout: .milliseconds(200),
            initialStall: ContinuousClock.now.advanced(by: .milliseconds(50))
        )
        // 50ms 后 noteText：stall 重新展期 200ms；再睡 100ms 仍未到期。
        try await Task.sleep(for: .milliseconds(50))
        await timer.noteText()
        try await Task.sleep(for: .milliseconds(100))
        let expired = await timer.expired
        XCTAssertFalse(expired, "见正文后停滞 deadline 应被重置，不应误杀合法推理等待")
        let seen = await timer.firstTextSeen
        XCTAssertTrue(seen, "noteText 后 firstTextSeen 必须为真，首正文 deadline 永久解除")
    }

    /// V07e:无 deadline 可等时计时器直接返回认输，不伪造超限。
    func testStreamTimerWithoutDeadlinesConcedesImmediately() async throws {
        let timer = StreamTimer(
            firstDeadline: nil,
            stallTimeout: nil,
            initialStall: nil
        )
        // 必须立即返回（不抛错）：若此处抛超限，就是"无 deadline 误杀"。
        try await timer.waitForExpiry()
        let expired = await timer.expired
        XCTAssertFalse(expired, "无 deadline 时不得立超限旗")
    }

    // MARK: - M2/V07f:取消单独成类，不记成传输失败

    /// V07f:建连阶段传输层报 `URLError.cancelled`（Task 取消穿透），
    /// `runStream` 必须映射为 `.cancelled`，不是 `.transport`。
    /// 确定性失败注入，不依赖取消时序。
    @MainActor
    func testStreamConnectCancellationMapsToCancelled() async throws {
        FakeTransport.reset([
            .init(status: 0, contentType: "", body: "", failCode: .cancelled)
        ])
        let result = await drainResponsesStream(makeProvider())
        switch result {
        case .success(let text):
            XCTFail("取消后不能返回成功，实际拿到 \(text)")
        case .failure(let error):
            XCTAssertEqual(
                error as? LLMError, .cancelled,
                "取消必须映射为 .cancelled，实际 \(error)"
            )
        }
    }

    /// V07f:非取消的传输失败（如超时）仍是 `.transport`，不误杀为取消。
    @MainActor
    func testStreamConnectTimeoutStaysTransport() async throws {
        FakeTransport.reset([
            .init(status: 0, contentType: "", body: "", failCode: .timedOut)
        ])
        let result = await drainResponsesStream(makeProvider())
        switch result {
        case .success(let text):
            XCTFail("超时后不能返回成功，实际拿到 \(text)")
        case .failure(let error):
            guard case .transport = error as? LLMError else {
                XCTFail("超时应为 .transport，实际 \(error)")
                return
            }
        }
    }

    @MainActor
    func testResponsesStreamIgnoresCommentsAndHeartbeats() async throws {
        FakeTransport.reset([
            .init(
                status: 200,
                contentType: "text/event-stream",
                body: """
                : keep-alive

                data: {"type":"response.output_text.delta","response_id":"resp_a","delta":"好"}

                event: ping
                data: {"type":"response.in_progress","response_id":"resp_a"}

                data: {"type":"response.completed","response":{"id":"resp_a"}}

                data: [DONE]

                """
            )
        ])
        let result = await drainResponsesStream(makeProvider())

        XCTAssertEqual(try result.get(), "好", "注释和心跳不影响正文")
    }

    // MARK: - M1/V15:正文前合法推理阶段不误杀

    /// V15:reasoning delta 是有效进展（展期停滞 deadline），但不是正文——
    /// 不产生朗读文本、不占正文预算、不解除首正文 deadline。
    /// 此处先在解码层验证：reasoning 事件只产生空进展信号，正文为空。
    func testReasoningDeltasAreProgressNotText() throws {
        final class Sink: @unchecked Sendable {
            let lock = NSLock()
            var texts: [String] = []
            var emptyCount = 0
            func record(_ text: String) {
                lock.withLock {
                    texts.append(text)
                    if text.isEmpty { emptyCount += 1 }
                }
            }
        }
        let sink = Sink()
        var state = LLMResponseStreamState()
        var usage: [String: Any]?
        var total = 0
        for eventType in [
            "response.reasoning_summary_text.delta",
            "response.reasoning_text.delta",
        ] {
            let object: [String: Any] = [
                "type": eventType,
                "response_id": "resp_a",
                "delta": "思考中",
            ]
            let finished = try ResponsesEventStreamDecoder.countedHandle(
                object,
                state: &state,
                usage: &usage,
                totalTextScalars: &total,
                onDelta: { sink.record($0) }
            )
            XCTAssertFalse(finished, "\(eventType) 不是终态")
        }
        XCTAssertEqual(sink.emptyCount, 2, "reasoning 应只产生空进展信号，不产生正文")
        XCTAssertEqual(total, 0, "推理进展不占累计正文预算")
        XCTAssertFalse(state.isFinished, "推理阶段不得终结本轮")
    }

    /// V15:未知 reasoning 事件类型走 default 忽略，不延长等待（fail-closed）。
    func testUnknownReasoningEventsDoNotExtendWait() throws {
        var state = LLMResponseStreamState()
        var usage: [String: Any]?
        var total = 0
        final class Flag: @unchecked Sendable {
            let lock = NSLock()
            var called = false
            func mark() { lock.withLock { called = true } }
        }
        let flag = Flag()
        let object: [String: Any] = [
            "type": "response.reasoning_mystery.delta",
            "response_id": "resp_a",
            "delta": "???",
        ]
        let finished = try ResponsesEventStreamDecoder.countedHandle(
            object,
            state: &state,
            usage: &usage,
            totalTextScalars: &total,
            onDelta: { _ in flag.mark() }
        )
        XCTAssertFalse(finished)
        XCTAssertFalse(flag.called, "未知 reasoning 事件不得产生进展信号")
        XCTAssertEqual(total, 0)
    }

    /// V15:noteProgress 只展期停滞 deadline，不解除首正文 deadline。
    func testStreamTimerProgressExtendsStallButNotFirstText() async throws {
        let timer = StreamTimer(
            firstDeadline: ContinuousClock.now.advanced(by: .milliseconds(300)),
            stallTimeout: .milliseconds(200),
            initialStall: ContinuousClock.now.advanced(by: .milliseconds(50))
        )
        // 50ms 后来一次推理进展：停滞展期 200ms；再睡 100ms 仍未到期。
        try await Task.sleep(for: .milliseconds(50))
        await timer.noteProgress()
        try await Task.sleep(for: .milliseconds(100))
        let expired = await timer.expired
        XCTAssertFalse(expired, "推理进展应展期停滞 deadline，不误杀合法等待")
        let seen = await timer.firstTextSeen
        XCTAssertFalse(seen, "推理进展不得算首正文，首正文 deadline 仍有效")
        // 首正文 deadline 到达仍超限：推理不能无限延长正文等待。
        try await Task.sleep(for: .milliseconds(250))
        do {
            try await timer.waitForExpiry()
            XCTFail("首正文 deadline 到达必须抛超限，不能被推理无限延长")
        } catch let error as LLMError {
            guard case .streamBudgetExceeded(let detail) = error else {
                XCTFail("应为 streamBudgetExceeded，实际 \(error)")
                return
            }
            XCTAssertTrue(detail.contains("首个有效正文"), "实际 \(detail)")
        }
    }

    @MainActor
    func testResponsesStreamFailedEventFailsImmediately() async throws {
        FakeTransport.reset([
            .init(
                status: 200,
                contentType: "text/event-stream",
                body: """
                data: {"type":"response.output_text.delta","response_id":"resp_a","delta":"好"}

                data: {"type":"response.failed","response":{"id":"resp_a","error":{"message":"上游中断"}}}

                data: {"type":"response.completed","response":{"id":"resp_a"}}

                """
            )
        ])
        let result = await drainResponsesStream(makeProvider())

        switch result {
        case .success(let text):
            XCTFail("response.failed 之后不能再被 completed 覆盖，实际拿到 \(text)")
        case .failure(let error):
            guard case .refused(let reason)? = error as? LLMError else {
                return XCTFail("预期 refused，实际 \(error)")
            }
            XCTAssertTrue(reason.contains("上游中断"))
        }
    }

    @MainActor
    func testBackgroundPollEmitsProviderObservationMetadata() async throws {
        FakeTransport.reset([.init(status: 200, contentType: "application/json", body: Self.okBody)])
        let observations = ObservationLog()
        let provider = makeProvider(observationHandler: observations.append)

        let text = try await provider.pollBackground(
            configuration: configuration,
            apiKey: nil,
            responseID: "resp_test",
            timeout: 1,
            interval: 0
        )

        XCTAssertEqual(text, "好")
        let started = try XCTUnwrap(observations.values.first { $0.kind == .providerRequestStarted })
        let response = try XCTUnwrap(observations.values.first { $0.kind == .providerResponse })
        XCTAssertEqual(started.component, "provider_poll")
        XCTAssertEqual(started.thinkingControl, "not_applicable")
        XCTAssertEqual(response.component, "provider_poll")
        XCTAssertEqual(response.outcome, "completed")
    }

    func testGenericResponsesRetriesWithoutStandardThinkingControlWhenProviderRejectsIt() async throws {
        FakeTransport.reset([
            .init(status: 400, contentType: "application/json", body: Self.rejectedBody),
            .init(status: 200, contentType: "application/json", body: Self.okBody)
        ])

        let text = try await complete()

        XCTAssertEqual(text, "好")
        let bodies = FakeTransport.requestBodies()
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual((bodies[0]["reasoning"] as? [String: String])?["effort"], "none")
        XCTAssertNil(bodies[0]["chat_template_kwargs"])
        XCTAssertNil(bodies[1]["reasoning"])
        XCTAssertNil(bodies[1]["chat_template_kwargs"])
    }

    func testRejectedThinkingControlRetriesOnceWithoutIt() async throws {
        FakeTransport.reset([
            .init(status: 400, contentType: "application/json", body: Self.rejectedBody),
            .init(status: 200, contentType: "application/json", body: Self.okBody)
        ])

        let text = try await complete(configuration: localTemplateConfiguration)

        XCTAssertEqual(text, "好")
        let bodies = FakeTransport.requestBodies()
        XCTAssertEqual(bodies.count, 2)
        XCTAssertNotNil(bodies[0]["chat_template_kwargs"])
        XCTAssertNil(bodies[1]["chat_template_kwargs"])
        XCTAssertEqual(bodies[1]["instructions"] as? String, "语音对话契约")
        XCTAssertEqual(bodies[1]["store"] as? Bool, false)
    }

    func testUnrelatedBadRequestIsNotRetried() async throws {
        FakeTransport.reset([
            .init(status: 400, contentType: "application/json", body: Self.unrelatedBadRequest),
            .init(status: 200, contentType: "application/json", body: Self.okBody)
        ])

        do {
            _ = try await complete()
            XCTFail("400 应当原样抛出来")
        } catch let error as LLMError {
            guard case let .http(status, body) = error else {
                return XCTFail("错误类型不对：\(error)")
            }
            XCTAssertEqual(status, 400)
            XCTAssertTrue(body.contains("model not found"))
        }
        XCTAssertEqual(FakeTransport.requestBodies().count, 1)
    }

    func testStructuredOutputRejectionIsClassifiedWithoutLooseJsonFallback() async throws {
        FakeTransport.reset([
            .init(
                status: 400,
                contentType: "application/json",
                body: Self.rejectedStructuredOutputBody
            )
        ])

        do {
            _ = try await makeProvider().complete(
                configuration: configuration,
                messages: [LLMMessage(role: .user, text: "整理稿件")],
                apiKey: nil,
                textFormat: [
                    "type": "json_schema",
                    "name": "teleprompter_analysis",
                    "strict": true,
                    "schema": ["type": "object"]
                ]
            )
            XCTFail("应报告 endpoint 不支持严格结构化输出")
        } catch let error as LLMError {
            XCTAssertEqual(error, .unsupportedStructuredOutput)
        }

        XCTAssertEqual(
            FakeTransport.requestBodies().count,
            1,
            "不应静默重试为非结构化 JSON"
        )
    }

    func testInvalidStructuredSchemaIsNotMisclassifiedAsUnsupportedCapability() async throws {
        FakeTransport.reset([
            .init(
                status: 400,
                contentType: "application/json",
                body: Self.invalidStructuredSchemaBody
            )
        ])

        do {
            _ = try await makeProvider().complete(
                configuration: configuration,
                messages: [LLMMessage(role: .user, text: "整理稿件")],
                apiKey: nil,
                textFormat: ["type": "json_schema"]
            )
            XCTFail("应报告原始 schema 错误")
        } catch let error as LLMError {
            guard case let .http(status, body) = error else {
                return XCTFail("错误类型不应被改写：\(error)")
            }
            XCTAssertEqual(status, 400)
            XCTAssertTrue(body.contains("additionalProperties"))
        }
    }

    func testMissingInstructionsKeepsRequestUsable() async throws {
        FakeTransport.reset([.init(status: 200, contentType: "application/json", body: Self.okBody)])

        _ = try await makeProvider().complete(
            configuration: configuration,
            messages: Self.messages,
            apiKey: nil,
            instructions: "   "
        )

        let body = try XCTUnwrap(FakeTransport.requestBodies().first)
        XCTAssertNil(body["instructions"])
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "none")
    }

    // MARK: - 检查连接：探测阶段就把「端点认不认关 thinking 的参数」定下来

    private static let modelsBody = #"{"data":[{"id":"test-model"}]}"#

    /// 探测用的正文只留一条 `ping`，且必须回一个模型名认得出的 `/models`。
    private func probeBodies() -> [[String: Any]] {
        zip(FakeTransport.requestURLs(), FakeTransport.requestBodies())
            .filter { $0.0.hasSuffix("/responses") }
            .map(\.1)
    }

    func testProbeRejectsInvalidSuccessBodiesAndDoesNotSaveDraft() async throws {
        let bodies = [
            "<html>gateway</html>", "", "{}", #"{"error":{"message":"SECRET_BODY"}}"#,
            #"{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#,
            #"{"output":[]}"#, #"{"output_text":"   "}"#,
            #"{"output_text":"one","output_text":"two"}"#,
            #"{"status":"incomplete","output_text":"partial"}"#,
            #"{"status":"failed","output_text":"partial"}"#,
            #"{"status":"queued","output_text":"partial"}"#,
            #"{"output":[{"type":"message","role":"assistant","content":[{"type":"refusal","refusal":"SECRET_BODY"}]}]}"#
        ]
        for body in bodies {
            FakeTransport.reset([
                .init(status: 404, contentType: "application/json", body: "{}"),
                .init(status: body.isEmpty ? 204 : 200, contentType: "application/json", body: body)
            ])
            let result = await makeProvider().check(configuration: configuration, apiKey: nil)
            XCTAssertFalse(result.isReady, "invalid success must not become ready: \(body)")
            XCTAssertFalse(LLMKeyDraftPolicy.shouldPersist(
                draft: "draft-key", connection: result, saveRequested: true
            ))
            XCTAssertFalse(result.detail.contains("SECRET_BODY"))
            XCTAssertThrowsError(try LLMProvider.extractText(from: Data(body.utf8)))
        }
    }

    func testChatProbeUsesTextContractWithoutBusinessSchemaOrUsage() async throws {
        let bodies = [
            try chatBody(content: "普通文本", partialUsageDetails: true),
            try chatBody(tokens: nil, content: "普通文本")
        ]
        for body in bodies {
            FakeTransport.reset([
                .init(status: 404, contentType: "application/json", body: "{}"),
                .init(status: 200, contentType: "application/json", body: body)
            ])
            let result = await makeProvider().check(configuration: configuration, apiKey: nil, operation: .chat)
            XCTAssertTrue(result.isReady, result.detail)
        }
    }

    func testChatProbeRejectsWrongOperationEmptyRefusalTruncationAndTools() async throws {
        let bodies = [
            Self.okBody, "{}", "",
            #"{"error":{"message":"SECRET_BODY"}}"#,
            try chatBody(content: " "),
            try chatBody(finish: "length", content: "partial"),
            try chatBody(content: "ok", refusal: "SECRET_BODY"),
            try chatBody(content: "ok", toolCalls: true)
        ]
        for body in bodies {
            FakeTransport.reset([
                .init(status: 404, contentType: "application/json", body: "{}"),
                .init(status: 200, contentType: "application/json", body: body)
            ])
            let result = await makeProvider().check(configuration: configuration, apiKey: nil, operation: .chat)
            XCTAssertFalse(result.isReady, body)
            XCTAssertFalse(result.detail.contains("SECRET_BODY"))
        }
    }

    func testResponsesProbeAcceptsDeclaredTextShapes() async throws {
        for body in [Self.okBody, #"{"output_text":"普通文本"}"#, Self.responsesBodyWithUsage] {
            FakeTransport.reset([
                .init(status: 404, contentType: "application/json", body: "{}"),
                .init(status: 200, contentType: "application/json", body: body)
            ])
            let result = await makeProvider().check(configuration: configuration, apiKey: nil)
            XCTAssertTrue(result.isReady, result.detail)
            XCTAssertFalse(try LLMProvider.extractText(from: Data(body.utf8)).isEmpty)
        }
    }

    func testResponsesOutputNeedsCompletedStatusInProbeAndFormalCall() async throws {
        let body = #"{"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}]}"#
        FakeTransport.reset([
            .init(status: 404, contentType: "application/json", body: "{}"),
            .init(status: 200, contentType: "application/json", body: body)
        ])
        let result = await makeProvider().check(configuration: configuration, apiKey: nil)
        XCTAssertEqual(result, .responseUnconfirmed(.notCompleted))
        XCTAssertThrowsError(try LLMResponseValidation.text(from: Data(body.utf8), operation: .responses)) {
            XCTAssertEqual($0 as? LLMResponseIssue, .notCompleted)
        }
        FakeTransport.reset([.init(status: 200, contentType: "application/json", body: body)])
        do {
            _ = try await complete()
            XCTFail("missing terminal status must not complete a formal call")
        } catch let error as LLMError {
            XCTAssertEqual(error, .transport(LLMResponseIssue.notCompleted.detail))
        }
    }

    func testConnectionProbeLearnsThinkingRejectionOnce() async throws {
        FakeTransport.reset([
            .init(status: 200, contentType: "application/json", body: Self.modelsBody),
            .init(status: 400, contentType: "application/json", body: Self.rejectedBody),
            .init(status: 200, contentType: "application/json", body: Self.okBody)
        ])

        let result = await makeProvider().check(
            configuration: localTemplateConfiguration,
            apiKey: nil,
            operation: .responses
        )

        XCTAssertTrue(result.isReady, result.title)
        let probes = probeBodies()
        XCTAssertEqual(probes.count, 2)
        XCTAssertNotNil(probes[0]["chat_template_kwargs"])
        XCTAssertNil(probes[1]["chat_template_kwargs"], "第二次探测不该再带上被拒绝的参数")
        XCTAssertEqual(probes[0]["max_output_tokens"] as? Int, 16)
        XCTAssertEqual(probes[1]["model"] as? String, "test-model")
    }

    func testAssistantProbeRequiresThinkingControl() async throws {
        FakeTransport.reset([
            .init(status: 200, contentType: "application/json", body: Self.modelsBody),
            .init(status: 400, contentType: "application/json", body: Self.rejectedBody),
            .init(status: 200, contentType: "application/json", body: Self.okBody)
        ])

        let result = await makeProvider().check(
            configuration: localTemplateConfiguration,
            apiKey: nil,
            operation: .responses,
            allowThinkingControlFallback: false
        )

        XCTAssertFalse(result.isReady)
        XCTAssertEqual(probeBodies().count, 1)
    }

    func testConnectionProbeDoesNotRetryUnrelatedBadRequest() async throws {
        FakeTransport.reset([
            .init(status: 200, contentType: "application/json", body: Self.modelsBody),
            .init(status: 400, contentType: "application/json", body: #"{"error":{"message":"bad key"}}"#)
        ])

        let result = await makeProvider().check(
            configuration: localTemplateConfiguration,
            apiKey: nil,
            operation: .responses
        )

        XCTAssertFalse(result.isReady)
        XCTAssertEqual(probeBodies().count, 1, "与这组参数无关的 400 不该触发重发")
    }

    func testChatConnectionDoesNotRequireModelsEndpoint() async throws {
        let arbitraryConfiguration = LLMConfiguration(
            baseURL: "https://provider.example/custom/v1",
            model: "vendor/strange:model@2026"
        )
        FakeTransport.reset([
            .init(status: 404, contentType: "application/json", body: #"{"error":"not found"}"#),
            .init(status: 200, contentType: "application/json", body: try chatBody())
        ])

        let result = await makeProvider().check(
            configuration: arbitraryConfiguration,
            apiKey: nil,
            operation: .chat
        )

        guard case let .connected(_, model) = result else {
            return XCTFail("应按实际 Chat 能力判定连接成功：\(result)")
        }
        XCTAssertEqual(model, arbitraryConfiguration.model)
        XCTAssertTrue(FakeTransport.requestURLs()[1].hasSuffix("/chat/completions"))
        XCTAssertEqual(FakeTransport.requestBodies()[1]["model"] as? String, arbitraryConfiguration.model)
        XCTAssertEqual(FakeTransport.requestBodies()[1]["reasoning_effort"] as? String, "none")
    }

    func testChatConnectionAllowsModelIDMissingFromAdvisoryModelsList() async throws {
        let arbitraryConfiguration = LLMConfiguration(
            baseURL: "https://provider.example/custom/v1",
            model: "vendor/alias-model"
        )
        FakeTransport.reset([
            .init(status: 200, contentType: "application/json", body: #"{"data":[{"id":"other-model"}]}"#),
            .init(status: 200, contentType: "application/json", body: try chatBody())
        ])

        let result = await makeProvider().check(
            configuration: arbitraryConfiguration,
            apiKey: nil,
            operation: .chat
        )

        guard case let .connected(_, model) = result else {
            return XCTFail("模型列表不是权威白名单：\(result)")
        }
        XCTAssertEqual(model, arbitraryConfiguration.model)
    }

    func testChatConnectionReportsMissingChatEndpoint() async throws {
        FakeTransport.reset([
            .init(status: 404, contentType: "application/json", body: #"{"error":"not found"}"#),
            .init(status: 404, contentType: "application/json", body: #"{"error":"chat not found"}"#)
        ])

        let result = await makeProvider().check(
            configuration: configuration,
            apiKey: nil,
            operation: .chat
        )

        XCTAssertEqual(result, .notChatAPI)
    }

    // MARK: - 模块差异化配置解析

    private let globalAPIKey = "global-key"

    private let moduleConfiguration = LLMConfiguration(
        baseURL: "https://module.example/v1",
        model: "module-model",
        compatibilityMode: .openCodeGo
    )

    func testModuleOverrideWinsAsAnAtomicProfile() {
        let result = LLMConfigurationResolver.resolve(
            global: configuration,
            globalAPIKey: globalAPIKey,
            moduleOverride: LLMModuleOverride(
                enabled: true,
                baseURL: moduleConfiguration.baseURL,
                model: moduleConfiguration.model,
                compatibilityMode: moduleConfiguration.compatibilityMode
            ),
            moduleAPIKey: "module-key"
        )

        XCTAssertEqual(result.configuration, moduleConfiguration)
        XCTAssertEqual(result.apiKey, "module-key")
        XCTAssertEqual(result.origin, .moduleOverride)
        XCTAssertNil(result.fallbackReason)
    }

    func testIncompleteModuleOverrideFallsBackAsAnAtomicProfile() {
        let result = LLMConfigurationResolver.resolve(
            global: configuration,
            globalAPIKey: globalAPIKey,
            moduleOverride: LLMModuleOverride(
                enabled: true,
                baseURL: moduleConfiguration.baseURL,
                model: ""
            ),
            moduleAPIKey: "module-key"
        )

        XCTAssertEqual(result.configuration, configuration)
        XCTAssertEqual(result.apiKey, globalAPIKey)
        XCTAssertEqual(result.origin, .globalFallback)
        XCTAssertEqual(result.fallbackReason, .incomplete)
    }

    func testModuleOverrideWithCredentialInURLFallsBackWithoutLeakingTheModuleKey() {
        let result = LLMConfigurationResolver.resolve(
            global: configuration,
            globalAPIKey: globalAPIKey,
            moduleOverride: LLMModuleOverride(
                enabled: true,
                baseURL: "http://user:secret@example.test/v1",
                model: moduleConfiguration.model
            ),
            moduleAPIKey: "module-key"
        )

        XCTAssertEqual(result.configuration, configuration)
        XCTAssertEqual(result.apiKey, globalAPIKey)
        XCTAssertEqual(result.origin, .globalFallback)
        XCTAssertEqual(result.fallbackReason, .embedsCredential)
    }

    func testMalformedModuleEndpointFallsBackBeforeARequestIsAttempted() {
        let result = LLMConfigurationResolver.resolve(
            global: configuration,
            globalAPIKey: globalAPIKey,
            moduleOverride: LLMModuleOverride(
                enabled: true,
                baseURL: "not a URL",
                model: moduleConfiguration.model
            ),
            moduleAPIKey: "module-key"
        )

        XCTAssertEqual(result.configuration, configuration)
        XCTAssertEqual(result.apiKey, globalAPIKey)
        XCTAssertEqual(result.origin, .globalFallback)
        XCTAssertEqual(result.fallbackReason, .invalidBaseURL)
    }

    func testEmptyModuleKeyInheritsOnlyTheGlobalKey() {
        let result = LLMConfigurationResolver.resolve(
            global: configuration,
            globalAPIKey: globalAPIKey,
            moduleOverride: LLMModuleOverride(
                enabled: true,
                baseURL: moduleConfiguration.baseURL,
                model: moduleConfiguration.model,
                compatibilityMode: moduleConfiguration.compatibilityMode
            ),
            moduleAPIKey: "   "
        )

        XCTAssertEqual(result.configuration, moduleConfiguration)
        XCTAssertEqual(result.apiKey, globalAPIKey)
        XCTAssertEqual(result.origin, .moduleOverride)
    }

    func testDisabledModuleOverrideUsesGlobalConfiguration() {
        let result = LLMConfigurationResolver.resolve(
            global: configuration,
            globalAPIKey: globalAPIKey,
            moduleOverride: LLMModuleOverride(
                enabled: false,
                baseURL: moduleConfiguration.baseURL,
                model: moduleConfiguration.model
            ),
            moduleAPIKey: "module-key"
        )

        XCTAssertEqual(result.configuration, configuration)
        XCTAssertEqual(result.apiKey, globalAPIKey)
        XCTAssertEqual(result.origin, .global)
        XCTAssertNil(result.fallbackReason)
    }

    func testModuleOverrideIsCodableForUserDefaultsPersistence() throws {
        let override = LLMModuleOverride(
            enabled: true,
            baseURL: moduleConfiguration.baseURL,
            model: moduleConfiguration.model,
            compatibilityMode: moduleConfiguration.compatibilityMode
        )

        let encoded = try JSONEncoder().encode([LLMModule.teleprompter: override])
        let decoded = try JSONDecoder().decode(
            [LLMModule: LLMModuleOverride].self,
            from: encoded
        )

        XCTAssertEqual(decoded[.teleprompter], override)
    }

    func testModuleOverrideMissingCompatibilityModeMigratesToGeneric() throws {
        let data = Data(
            #"{"enabled":true,"baseURL":"https://provider.example/v1","model":"vendor/model"}"#.utf8
        )
        let decoded = try JSONDecoder().decode(LLMModuleOverride.self, from: data)

        XCTAssertEqual(decoded.compatibilityMode, .openAICompatible)
        XCTAssertEqual(decoded.configuration.compatibilityMode, .openAICompatible)
    }

    func testTeleprompterDataFlowAcknowledgementIsScopedWithoutEmbeddingEndpoint() {
        let first = TeleprompterAIDataFlowDisclosure.acknowledgementDefaultsKey(
            for: LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "model-a")
        )
        let second = TeleprompterAIDataFlowDisclosure.acknowledgementDefaultsKey(
            for: LLMConfiguration(baseURL: "https://other.example/v1", model: "model-a")
        )

        XCTAssertTrue(first.hasPrefix("speechrail.teleprompter.aiDataFlowAcknowledged.v2."))
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.contains("example.com"))
    }

    /// E5/TP-05：整理与标注是两种用途——同一 endpoint/model 下确认键必须隔离，
    /// 旧键（无 purpose）不得推导新用途已同意；key 不得写入 endpoint 或正文。
    func testTeleprompterDataFlowAcknowledgementIsIsolatedByPurpose() {
        let configuration = LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "model-a")
        let prepare = TeleprompterAIDataFlowDisclosure.acknowledgementDefaultsKey(
            for: configuration, purpose: .prepare
        )
        let annotate = TeleprompterAIDataFlowDisclosure.acknowledgementDefaultsKey(
            for: configuration, purpose: .annotate
        )
        XCTAssertNotEqual(prepare, annotate, "同一配置下整理与标注确认必须隔离")
        XCTAssertFalse(prepare.contains("127.0.0.1"), "确认键不得嵌入 endpoint 原文")
        XCTAssertFalse(annotate.contains("model-a"), "确认键不得嵌入模型名原文")
    }

    /// E5/TP-05：披露文案不得承诺逐组审阅保证——候选是整体阅稿，不设必审门禁。
    func testTeleprompterDataFlowDisclosureDoesNotPromiseGroupReview() {
        XCTAssertFalse(
            TeleprompterAIDataFlowDisclosure.message.contains("逐组"),
            "确认文案不得再写逐组审阅"
        )
        XCTAssertTrue(TeleprompterAIDataFlowDisclosure.message.contains("通读整份候选稿"))
    }

    func testTeleprompterDataFlowDisclosureUsesPlainLanguage() {
        XCTAssertEqual(TeleprompterAIDataFlowDisclosure.title, "整理稿件前请确认")
        XCTAssertTrue(TeleprompterAIDataFlowDisclosure.inlineMessage.contains("只有点击"))
        XCTAssertTrue(TeleprompterAIDataFlowDisclosure.message.contains("麦克风、摄像头或直播画面"))
        XCTAssertFalse(TeleprompterAIDataFlowDisclosure.message.contains("Responses-compatible"))
        XCTAssertFalse(TeleprompterAIDataFlowDisclosure.message.contains("store=false"))
    }

    func testTeleprompterErrorsUsePlainLanguage() {
        XCTAssertEqual(TeleprompterTextError.emptySource.errorDescription, "请先输入稿件内容")
        XCTAssertEqual(TeleprompterTextError.invalidAnalysis.errorDescription, "AI 返回的整理结果无法使用")
        XCTAssertFalse(TeleprompterTextError.invalidSourceRange.errorDescription?.contains("UTF-16") == true)
    }

    /// E6：全跳过错误用用户语言说明“还没有可朗读的段落”，不抛技术术语。
    func testAllSkippedBlocksErrorUsesPlainLanguage() {
        let message = TeleprompterTextError.noReadableBlocks.errorDescription ?? ""
        XCTAssertTrue(message.contains("还没有可朗读的段落"))
        XCTAssertFalse(message.contains("skip"))
        XCTAssertFalse(message.contains("block"))
    }
}
