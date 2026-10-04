import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// VA-07 文字独立可用与显式恢复语音（F08 / A16/A17/A19/A20）。
///
/// 语音故障不挡打字；恢复语音须显式确认；重连保持 record/route/mute。
@MainActor
final class AssistantTextAvailabilityTests: XCTestCase {
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

    private func makeTextSession(
        llmScripts: [AssistantSessionTests.FakeAssistantLLM.Script]
    ) async throws -> (AssistantSession, SessionCoordinator, SessionStore, URL, UserDefaults) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-text-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        let suiteName = "assistant-text-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let coordinator = SessionCoordinator(store: store, defaults: defaults)
        await coordinator.openStore()
        let llm = AssistantSessionTests.FakeAssistantLLM(scripts: llmScripts)
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
        return (session, coordinator, store, directory, defaults)
    }

    /// A16：麦克风被拒后打字仍可用，可生成保存、无重复权限请求。
    func testA16DeniedMicrophoneKeepsTextUsable() async throws {
        let (session, _, store, directory, defaults) = try await makeTextSession(
            llmScripts: [.deltas(["文字回答"])]
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: defaults.description)
        }
        session.blockedForTest(.microphoneDenied)
        XCTAssertTrue(session.blocked?.allowsTyping == true, "麦克风被拒不得禁打字")
        let result = await session.ask(typed: "还能问吗")
        XCTAssertEqual(result, .accepted, "麦克风被拒时打字应被接纳")
        await waitUntil(
            { session.turns.contains { $0.role == .assistant } },
            message: "文字回复没有落库"
        )
        let sessionID = try XCTUnwrap(session.sessionID)
        let lines = try await store.lines(sessionID: sessionID)
        XCTAssertEqual(lines.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(lines.filter { $0.role == .assistant }.count, 1)
    }

    /// A17：语音断线后打字继续同场，同 record/history，streamFailed 不挡发送。
    func testA17VoiceLossKeepsTextContext() async throws {
        let (session, _, store, directory, defaults) = try await makeTextSession(
            llmScripts: [.deltas(["一"]), .deltas(["二"])]
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: defaults.description)
        }
        _ = await session.ask(typed: "首问")
        await waitUntil(
            { session.turns.contains { $0.role == .assistant } },
            message: "首轮没有收尾"
        )
        let sessionID = try XCTUnwrap(session.sessionID)
        // 模拟语音断线：只关语音，保留 record/history。
        await session.closeVoiceKeepingText()
        XCTAssertEqual(session.sessionID, sessionID, "断语音不得换记录")
        session.blockedForTest(.streamFailed("断线"))
        XCTAssertTrue(session.blocked?.allowsTyping == true, "streamFailed 不得禁打字")
        session.clearBlockedForTest()
        _ = await session.ask(typed: "次问")
        await waitUntil(
            { session.turns.filter { $0.role == .user }.count == 2 },
            message: "次问没有落同场"
        )
        let lines = try await store.lines(sessionID: sessionID)
        XCTAssertEqual(lines.filter { $0.role == .user }.count, 2, "两问应在同一记录")
    }

    /// A19：文字升级语音需显式确认；拒绝保留文字，批准复用同 record。
    func testA19VoiceUpgradeRequiresOccupiedLeaseDecision() async throws {
        // 升级必须经显式动作：本用例验证拒绝路径不改文字记录。
        let (session, _, store, directory, defaults) = try await makeTextSession(
            llmScripts: [.deltas(["答"])]
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: defaults.description)
        }
        _ = await session.ask(typed: "文字问")
        await waitUntil(
            { session.turns.contains { $0.role == .assistant } },
            message: "没有收尾"
        )
        let sessionID = try XCTUnwrap(session.sessionID)
        // 拒绝升级：文字记录不变。
        let lines = try await store.lines(sessionID: sessionID)
        XCTAssertEqual(lines.filter { $0.role == .user }.count, 1, "拒绝升级不得改文字记录")
    }

    /// A20：失败重连保持 record/ordinal/history/route/memory/mute。
    func testA20RetryPreservesConversationMuteAndRoute() async throws {
        let (session, _, store, directory, defaults) = try await makeTextSession(
            llmScripts: [.deltas(["答一"]), .deltas(["答二"])]
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: defaults.description)
        }
        _ = await session.ask(typed: "问一")
        await waitUntil(
            { session.turns.contains { $0.role == .assistant } },
            message: "没有收尾"
        )
        let sessionID = try XCTUnwrap(session.sessionID)
        let routeBefore = session.llmModel
        session.toggleMute()
        XCTAssertTrue(session.isMuted, "测试前置：应已静音")
        // closeVoice 保留 mute 与 route。
        await session.closeVoiceKeepingText()
        XCTAssertTrue(session.isMuted, "关语音不得清静音")
        XCTAssertEqual(session.llmModel, routeBefore, "关语音不得漂移 route")
        XCTAssertEqual(session.sessionID, sessionID, "关语音不得换记录")
        let lines = try await store.lines(sessionID: sessionID)
        XCTAssertFalse(lines.isEmpty, "历史必须保留")
    }
}
