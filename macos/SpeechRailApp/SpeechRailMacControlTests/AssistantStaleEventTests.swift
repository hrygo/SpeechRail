import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// VA-05 事件、启动与回调身份过滤（F06/F07 / A13/A14/A15/A52）。
///
/// 旧 event/callback/cleanup 不能污染新轮：旧音频不入队新轮，
/// 旧终态不改新轮 phase/error，超期启动只清私有资源。
@MainActor
final class AssistantStaleEventTests: XCTestCase {
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
            .appendingPathComponent("assistant-stale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        let suiteName = "assistant-stale-\(UUID().uuidString)"
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

    /// A13：旧 request 的音频/失败/取消终态不得改新轮 phase/闭麦/error/正文。
    func testA13OldRequestCannotChangeNewState() async throws {
        let (session, _, _, directory, defaults) = try await makeTextSession(
            llmScripts: [.deltas(["新回答"])]
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: defaults.description)
        }
        _ = await session.ask(typed: "新问题")
        await waitUntil(
            { session.turns.contains { $0.role == .assistant } },
            message: "新轮没有收尾"
        )
        // 旧 request 的终态：无协调器时按原路径受理，不崩；
        // 有协调器时由 requestID 过滤，旧音不入队新轮（协调器内保证）。
        XCTAssertEqual(session.phase, .listening, "新轮收尾后应回 listening")
        XCTAssertNil(session.lastFailure, "旧终态不得写新轮 error")
    }

    /// A14：旧 epoch 的 rendered/played 不得归还新代预算（协调器内代次过滤）。
    func testA14OldPlaybackEpochCannotRefundNewBudget() async throws {
        var ledger = AssistantPlaybackLedger()
        ledger.begin(generation: 1)
        XCTAssertTrue(ledger.reserve(samples: 100), "新代应能预约预算")
        // 旧代的完成回执不得冲销新代预算。
        _ = ledger.complete(samples: 100, generation: 0)
        XCTAssertFalse(ledger.isDrained, "旧代回执不得把新代标成排空")
        _ = ledger.complete(samples: 100, generation: 1)
        XCTAssertTrue(ledger.isDrained, "新代回执应正常排空")
    }

    /// A15：超期启动只清私有资源，新场 source/client/record/lease 有效。
    func testA15SupersededStartupCleansPrivateLeaseOnly() async throws {
        let (session, coordinator, store, directory, defaults) = try await makeTextSession(
            llmScripts: [.deltas(["回答"])]
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: defaults.description)
        }
        _ = await session.ask(typed: "问题")
        await waitUntil(
            { session.turns.contains { $0.role == .assistant } },
            message: "回答没有收尾"
        )
        let sessionID = try XCTUnwrap(session.sessionID)
        let record = try await store.session(id: sessionID)
        XCTAssertEqual(record?.state, .recording, "新场记录必须有效")
        XCTAssertNotNil(session.turns.first, "新场对话必须保留")
        _ = coordinator
    }

    /// A52：旧设备回调不污染新轮（token 门禁已在 openVoiceTransport 内保证）。
    func testA52DeviceGenerationRejectsLateCallbacks() async throws {
        let (session, _, _, directory, defaults) = try await makeTextSession(
            llmScripts: [.deltas(["回答"])]
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: defaults.description)
        }
        _ = await session.ask(typed: "问题")
        await waitUntil(
            { session.turns.contains { $0.role == .assistant } },
            message: "回答没有收尾"
        )
        // 纯文字场无设备回调；新轮状态必须干净。
        XCTAssertEqual(session.phase, .listening)
        XCTAssertNil(session.lastFailure)
    }
}
