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

    private final class ObservationLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [TeleprompterAIObservation] = []

        func append(_ observation: TeleprompterAIObservation) {
            lock.lock()
            stored.append(observation)
            lock.unlock()
        }

        var values: [TeleprompterAIObservation] {
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
        observationHandler: TeleprompterAIObservationHandler? = nil
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
        observationContext: TeleprompterAICallContext? = nil,
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
        let context = TeleprompterAICallContext(
            runID: "run-test",
            requestID: "request-test",
            stage: .map,
            itemIndex: 2,
            itemCount: 4,
            attempt: 0
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

        let response = try XCTUnwrap(
            observations.values.first { $0.kind == .providerResponse }
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
        let context = TeleprompterAICallContext(
            runID: "run-stable",
            requestID: "request-1",
            stage: .map,
            itemIndex: 0,
            itemCount: 2
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
                runID: context.runID,
                requestID: "request-2",
                stage: .reduce,
                itemIndex: 0,
                itemCount: 1
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
}
