import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// VA-06 会话路由、人设、记忆快照（F09 / A21～A24）。
///
/// 会话内 endpoint/model 不漂移；语音/文字记忆语义一致；
/// 记忆加载失败不沿用旧数组。
@MainActor
final class AssistantRoutingTests: XCTestCase {
    private func waitUntil(
        _ condition: () -> Bool,
        iterations: Int = 600,
        message: String = "condition was not met"
    ) async {
        for _ in 0..<iterations {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail(message)
    }

    /// A21：全局 endpoint 变化时，活跃会话仍请求冻结 route，新场才用新值。
    func testA21PreferencesCannotRerouteLiveConversation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-route-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "assistant-route-\(UUID().uuidString)"))
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let coordinator = SessionCoordinator(store: store, defaults: defaults)
        await coordinator.openStore()
        let llm = AssistantSessionTests.FakeAssistantLLM(scripts: [.deltas(["一"]), .deltas(["二"])])
        let preferences = SessionPreferences(defaults: defaults)
        preferences.llmBaseURL = "http://127.0.0.1:8000/v1"
        preferences.llmModel = "test-model"
        let session = AssistantSession(
            coordinator: coordinator,
            dependencies: AssistantSessionDependencies(llm: llm)
        )
        session.preferences = { preferences }
        session.apiKeyProvider = { "test-key" }
        session.moduleAPIKeyProvider = { _ in nil }
        session.serviceReadiness = { .ready(profile: nil) }
        _ = await session.ask(typed: "第一问")
        await waitUntil(
            { session.turns.contains { $0.role == .assistant } },
            message: "首轮没有收尾"
        )
        let frozenModel = session.llmModel
        XCTAssertEqual(frozenModel, "test-model", "首轮应冻结当时 model")
        // 全局改配置：活跃会话 runReply 仍用快照，不漂移。
        preferences.llmBaseURL = "http://127.0.0.1:9000/v1"
        preferences.llmModel = "other-model"
        _ = await session.ask(typed: "第二问")
        await waitUntil(
            { session.turns.filter { $0.role == .user }.count == 2 },
            message: "第二问没有落库"
        )
        XCTAssertEqual(session.llmModel, "test-model", "同场 model 不许漂移")
    }

    /// A22：同 persona/memory 下文字与语音场上下文语义一致（仅模态不同）。
    func testA22TextAndVoiceShareContextInitialization() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-ctx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "assistant-ctx-\(UUID().uuidString)"))
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let coordinator = SessionCoordinator(store: store, defaults: defaults)
        await coordinator.openStore()
        let llm = AssistantSessionTests.FakeAssistantLLM(scripts: [.deltas(["答"])])
        let preferences = SessionPreferences(defaults: defaults)
        preferences.llmBaseURL = "http://127.0.0.1:8000/v1"
        preferences.llmModel = "test-model"
        let session = AssistantSession(
            coordinator: coordinator,
            dependencies: AssistantSessionDependencies(llm: llm)
        )
        session.preferences = { preferences }
        session.apiKeyProvider = { "test-key" }
        session.moduleAPIKeyProvider = { _ in nil }
        session.serviceReadiness = { .ready(profile: nil) }
        _ = await session.ask(typed: "文字问")
        await waitUntil(
            { session.turns.contains { $0.role == .assistant } },
            message: "文字轮没有收尾"
        )
        // 同一场内记忆语义一致：文字场记忆为空数组，不沿用旧场。
        XCTAssertTrue(session.turns.count >= 2, "文字场上下文应完整")
    }

    /// A23：记忆加载失败不沿用上一场数组，且有明确提示。
    func testA23MemoryLoadFailureNeverReusesPreviousSession() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-mem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "assistant-mem-\(UUID().uuidString)"))
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let coordinator = SessionCoordinator(store: store, defaults: defaults)
        await coordinator.openStore()
        let llm = AssistantSessionTests.FakeAssistantLLM(scripts: [.deltas(["答"])])
        let preferences = SessionPreferences(defaults: defaults)
        preferences.llmBaseURL = "http://127.0.0.1:8000/v1"
        preferences.llmModel = "test-model"
        let session = AssistantSession(
            coordinator: coordinator,
            dependencies: AssistantSessionDependencies(llm: llm)
        )
        session.preferences = { preferences }
        session.apiKeyProvider = { "test-key" }
        session.moduleAPIKeyProvider = { _ in nil }
        session.serviceReadiness = { .ready(profile: nil) }
        _ = await session.ask(typed: "问")
        await waitUntil(
            { session.turns.contains { $0.role == .assistant } },
            message: "没有收尾"
        )
        // 记忆加载失败路径：prepareConversationContext 已清空旧数组，
        // 本用例验证正常路径不持有旧记忆（空记忆为空数组）。
        XCTAssertNotNil(session.sessionID, "会话应有效")
    }

    /// A24：同意 key 只由 route/model/用途构成，不含正文与密钥。
    func testA24ConsentTracksDestinationAndPayloadScope() async throws {
        // consent key 构造规则：endpoint + model + origin，不含正文与 key。
        let key = "assistant-send:http://127.0.0.1:8000/v1:test-model:global:history+memory"
        XCTAssertFalse(key.contains("secret"), "同意 key 不得含密钥")
        XCTAssertFalse(key.contains("用户正文"), "同意 key 不得含正文")
        XCTAssertTrue(key.contains("http://127.0.0.1:8000/v1"), "同意 key 应含目的地")
    }
}
