import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// `LLMProvider` 的请求形状回归（`TECHNICAL-DESIGN` §5.5 + 2026-09-19 本机 oMLX 实测）。
///
/// 用假的 `URLProtocol` 当传输层：不连网、不碰钥匙串、不加载模型。钉住两条形状：
///   · 语音契约走顶层 `instructions`（不是 SpeechRail TTS 的那个 `instructions`），
///     人设与记忆留在 `input` 并带显式断点，顺序不变；
///   · 关 thinking 的 `chat_template_kwargs` 一定发，但端点明确拒绝时只失败一次，
///     之后按不带它的形状发——`instructions` 不能跟着一起丢。
final class LLMProviderTests: XCTestCase {

    // MARK: - 假传输

    final class FakeTransport: URLProtocol {
        struct Exchange {
            var status: Int
            var contentType: String
            var body: String
        }

        nonisolated(unsafe) private static var scripted: [Exchange] = []
        nonisolated(unsafe) private static var captured: [[String: Any]] = []
        nonisolated(unsafe) private static var capturedURLs: [String] = []
        private static let lock = NSLock()

        static func reset(_ exchanges: [Exchange]) {
            lock.lock()
            defer { lock.unlock() }
            scripted = exchanges
            captured = []
            capturedURLs = []
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

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.lock()
            Self.captured.append(Self.jsonBody(of: request))
            Self.capturedURLs.append(request.url?.absoluteString ?? "")
            let exchange = Self.scripted.isEmpty
                ? Exchange(status: 500, contentType: "application/json", body: "{}")
                : Self.scripted.removeFirst()
            Self.lock.unlock()

            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://127.0.0.1/v1/responses")!,
                statusCode: exchange.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": exchange.contentType]
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

    // MARK: - 夹具

    private let configuration = LLMConfiguration(
        baseURL: "http://127.0.0.1:8000/v1",
        model: "test-model"
    )

    private static let okBody = """
    {"id":"resp_test","object":"response","status":"completed","output":[\
    {"type":"message","role":"assistant","content":[{"type":"output_text","text":"好"}]}]}
    """

    private static let rejectedBody = """
    {"error":{"message":"Unrecognized request argument supplied: chat_template_kwargs",\
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

    private func makeProvider() -> LLMProvider {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [FakeTransport.self]
        return LLMProvider(session: URLSession(configuration: sessionConfiguration))
    }

    private func complete(instructions: String = "语音对话契约") async throws -> String {
        try await makeProvider().complete(
            configuration: configuration,
            messages: Self.messages,
            apiKey: nil,
            maxOutputTokens: 128,
            instructions: instructions
        )
    }

    // MARK: - 断言

    func testCompleteSendsVoiceContractAndSuppressesThinking() async throws {
        FakeTransport.reset([.init(status: 200, contentType: "application/json", body: Self.okBody)])

        let text = try await complete()

        XCTAssertEqual(text, "好")
        let body = try XCTUnwrap(FakeTransport.requestBodies().first)
        XCTAssertEqual(body["instructions"] as? String, "语音对话契约")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(
            (body["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool,
            false
        )

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

    func testRejectedThinkingControlRetriesOnceWithoutIt() async throws {
        FakeTransport.reset([
            .init(status: 400, contentType: "application/json", body: Self.rejectedBody),
            .init(status: 200, contentType: "application/json", body: Self.okBody)
        ])

        let text = try await complete()

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
        XCTAssertNotNil(body["chat_template_kwargs"])
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

        let result = await makeProvider().check(configuration: configuration, apiKey: nil)

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

        let result = await makeProvider().check(configuration: configuration, apiKey: nil)

        XCTAssertFalse(result.isReady)
        XCTAssertEqual(probeBodies().count, 1, "与这组参数无关的 400 不该触发重发")
    }

    // MARK: - 模块差异化配置解析

    private let globalAPIKey = "global-key"

    private let moduleConfiguration = LLMConfiguration(
        baseURL: "http://127.0.0.1:8317/v1",
        model: "module-model"
    )

    func testModuleOverrideWinsAsAnAtomicProfile() {
        let result = LLMConfigurationResolver.resolve(
            global: configuration,
            globalAPIKey: globalAPIKey,
            moduleOverride: LLMModuleOverride(
                enabled: true,
                baseURL: moduleConfiguration.baseURL,
                model: moduleConfiguration.model
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
                model: moduleConfiguration.model
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
            model: moduleConfiguration.model
        )

        let encoded = try JSONEncoder().encode([LLMModule.teleprompter: override])
        let decoded = try JSONDecoder().decode(
            [LLMModule: LLMModuleOverride].self,
            from: encoded
        )

        XCTAssertEqual(decoded[.teleprompter], override)
    }

    func testTeleprompterDataFlowAcknowledgementIsScopedWithoutEmbeddingEndpoint() {
        let first = TeleprompterAIDataFlowDisclosure.acknowledgementDefaultsKey(
            for: LLMConfiguration(baseURL: "http://127.0.0.1:8000/v1", model: "model-a")
        )
        let second = TeleprompterAIDataFlowDisclosure.acknowledgementDefaultsKey(
            for: LLMConfiguration(baseURL: "http://127.0.0.1:8317/v1", model: "model-a")
        )

        XCTAssertTrue(first.hasPrefix("speechrail.teleprompter.aiDataFlowAcknowledged.v2."))
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.contains("127.0.0.1"))
    }
}
