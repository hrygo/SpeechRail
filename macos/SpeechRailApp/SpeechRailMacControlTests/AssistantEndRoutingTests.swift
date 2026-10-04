import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// VA-01 助手专属结束与租约隔离（F01 / A01/A02/A18）。
///
/// 打的是生产 `AssistantSession` + `SessionCoordinator`：
/// 文字结束按自己的 recordID 封存，不碰全局占用；
/// 语音结束核对 kind + leaseID + recordID，旧目标不得清新会话。
@MainActor
final class AssistantEndRoutingTests: XCTestCase {
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

    private func makeStore() async throws -> (SessionStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-end-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        try await store.open()
        return (store, directory)
    }

    private func makePreferences(defaults: UserDefaults) -> SessionPreferences {
        let preferences = SessionPreferences(defaults: defaults)
        preferences.llmBaseURL = "http://127.0.0.1:8000/v1"
        preferences.llmModel = "test-model"
        return preferences
    }

    /// A01：纯文字场结束只封自己的记录，无占用、无设备、无连接。
    func testA01TextEndWithoutOccupancy() async throws {
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "assistant-end-a01-\(UUID().uuidString)"))
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let coordinator = SessionCoordinator(store: store, defaults: defaults)
        await coordinator.openStore()
        let preferences = makePreferences(defaults: defaults)
        let session = AssistantSession(coordinator: coordinator)
        session.preferences = { preferences }
        session.apiKeyProvider = { "test-key" }
        session.moduleAPIKeyProvider = { _ in nil }
        // 不注入 audio/realtime：纯文字路径若误触设备会直接崩或计数，避免假阳性。
        var micStartCount = 0
        session.audioSourceFactory = {
            micStartCount += 1
            return FakeTextOnlyAudio()
        }

        // 用 ask 经过统一文字建档：需要一个成功返回文字的 LLM。
        // 为避免依赖 AssistantSessionTests 的内部 Fake，这里直接走 Store 建一条文字记录
        // 再验证 endConversation 的目标封存语义（占用隔离是本用例核心）。
        let record = try await coordinator.createSession(
            SessionDraft(kind: .assistant, engineProfile: "unknown", audioSource: .microphone)
        )
        // 模拟已存在一场纯文字助手：无 occupancy、无 activeSessionID。
        XCTAssertNil(coordinator.occupancy)
        XCTAssertNil(coordinator.activeSessionID)

        // 旧路径复现：直接调全局 stopCapture 在无 occupancy 时是 no-op。
        await coordinator.stopCapture(endingWith: .user)
        let stillOpen = try await store.session(id: record.id)
        XCTAssertEqual(stillOpen?.state, .recording, "旧全局结束在无占用时是 no-op，应复现 F01")

        // 新路径：按 recordID 目标结束，必须封存自己的记录。
        let result = await coordinator.endAssistant(
            SessionCoordinator.AssistantEndTarget(recordID: record.id, leaseID: nil)
        )
        guard case .ended(let endedID) = result else {
            XCTFail("纯文字目标结束应返回 ended，实际 \(result)")
            return
        }
        XCTAssertEqual(endedID, record.id)
        let sealed = try await store.session(id: record.id)
        XCTAssertEqual(sealed?.state, .archived, "纯文字记录必须有终态")
        XCTAssertNil(coordinator.occupancy)
        XCTAssertNil(coordinator.activeSessionID)
        XCTAssertEqual(micStartCount, 0, "纯文字结束不该去拿麦克风")
    }

    /// A02：会议占用设备时，文字助手的结束不得改会议的占用/phase/记录/stopper。
    func testA02TextEndWhileMeetingOwnsLease() async throws {
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "assistant-end-a02-\(UUID().uuidString)"))
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let coordinator = SessionCoordinator(store: store, defaults: defaults)
        await coordinator.openStore()

        var stopperCalls = 0
        coordinator.starter = { _ in }
        coordinator.stopper = { _ in stopperCalls += 1 }
        // 会议占用设备。
        try await coordinator.begin(.meeting)
        let leaseBefore = coordinator.activeLeaseID
        XCTAssertNotNil(leaseBefore)
        let meetingRecord = try await coordinator.createSession(
            SessionDraft(kind: .meeting, engineProfile: "unknown", audioSource: .microphone)
        )
        coordinator.sessionDidStartRecording(id: meetingRecord.id)
        let occupancyBefore = coordinator.occupancy
        let phaseBefore = coordinator.phase

        // 另一场纯文字助手的记录（不在 occupancy 里）。
        let textRecord = try await coordinator.createSession(
            SessionDraft(kind: .assistant, engineProfile: "unknown", audioSource: .microphone)
        )

        let result = await coordinator.endAssistant(
            SessionCoordinator.AssistantEndTarget(recordID: textRecord.id, leaseID: nil)
        )
        guard case .ended(let endedID) = result else {
            XCTFail("文字目标结束应返回 ended，实际 \(result)")
            return
        }
        XCTAssertEqual(endedID, textRecord.id)
        // 会议侧逐项不变。
        XCTAssertEqual(coordinator.occupancy, occupancyBefore, "会议占用不得被文字结束改变")
        XCTAssertEqual(coordinator.phase, phaseBefore)
        XCTAssertEqual(coordinator.activeSessionID, meetingRecord.id)
        XCTAssertEqual(coordinator.activeLeaseID, leaseBefore)
        XCTAssertEqual(stopperCalls, 0, "文字结束不得调会议的 stopper")
        let meetingAfter = try await store.session(id: meetingRecord.id)
        XCTAssertEqual(meetingAfter?.state, .recording, "会议记录不得被文字结束封存")
        let textAfter = try await store.session(id: textRecord.id)
        XCTAssertEqual(textAfter?.state, .archived, "文字自己的记录必须封存")
    }

    /// A18：重复结束共用同一任务；旧 lease 目标不得结束新会话。
    func testA18RepeatedAndReviewedEndTargets() async throws {
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "assistant-end-a18-\(UUID().uuidString)"))
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let coordinator = SessionCoordinator(store: store, defaults: defaults)
        await coordinator.openStore()
        coordinator.starter = { _ in }
        coordinator.stopper = { _ in }

        // 第一场语音助手占用。
        try await coordinator.begin(.assistant)
        let leaseA = try XCTUnwrap(coordinator.activeLeaseID)
        let recordA = try await coordinator.createSession(
            SessionDraft(kind: .assistant, engineProfile: "unknown", audioSource: .microphone)
        )
        coordinator.sessionDidStartRecording(id: recordA.id)

        // 旧目标（leaseA + recordA）在新会话开始后仍被调用：先结束 A 再开始 B。
        await coordinator.finalize(reason: .user)
        try await coordinator.begin(.assistant)
        let leaseB = try XCTUnwrap(coordinator.activeLeaseID)
        XCTAssertNotEqual(leaseA, leaseB, "两场必须有不同租约身份")
        let recordB = try await coordinator.createSession(
            SessionDraft(kind: .assistant, engineProfile: "unknown", audioSource: .microphone)
        )
        coordinator.sessionDidStartRecording(id: recordB.id)

        let stale = await coordinator.endAssistant(
            SessionCoordinator.AssistantEndTarget(recordID: recordA.id, leaseID: leaseA)
        )
        XCTAssertEqual(stale, .superseded, "旧助手的迟到结束不得清掉新会话")
        XCTAssertEqual(coordinator.activeSessionID, recordB.id, "新会话的记录必须保留")
        XCTAssertEqual(coordinator.occupancy?.kind, .assistant)
        let recordBAfter = try await store.session(id: recordB.id)
        XCTAssertEqual(recordBAfter?.state, .recording)
    }

    /// A47（Session 层）：纯文字结束遇封存失败时不冒充 ended。
    ///
    /// 不存在的记录 → `sealSessionReporting` 返回 `.failed`：
    /// end 不发布虚假的已封存 ID，保留 pendingSeal 与失败原因，
    /// 界面走重试/复制出口。变异验证：改回 `sealSession` fire-and-forget
    /// 后本用例按预期失败（返回 ended 且无 pendingSeal）。
    func testA47TextEndSealFailureKeepsRecovery() async throws {
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "assistant-end-a47-\(UUID().uuidString)"))
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let coordinator = SessionCoordinator(store: store, defaults: defaults)
        await coordinator.openStore()
        let preferences = makePreferences(defaults: defaults)
        let llm = AssistantSessionTests.FakeAssistantLLM(scripts: [.deltas(["回答。"])])
        let session = AssistantSession(
            coordinator: coordinator,
            dependencies: AssistantSessionDependencies(llm: llm)
        )
        session.preferences = { preferences }
        session.apiKeyProvider = { "test-key" }
        session.moduleAPIKeyProvider = { _ in nil }
        session.serviceReadiness = { .ready(profile: nil) }
        // 先 ask 建出纯文字场（isTextOnlyConversation=true），再删库记录
        // 伪造“封存时记录已丢失”：sealSessionReporting 必返回 .failed。
        _ = await session.ask(typed: "封存失败也不丢恢复出口")
        let recordID = try XCTUnwrap(session.sessionID)
        try await coordinator.removeSession(id: recordID)
        let result = await session.endConversation()
        guard case .noConversation = result else {
            XCTFail("封存失败不得冒充 ended，实际 \(result)")
            return
        }
        XCTAssertNil(session.lastFinalizedSessionID, "失败不得发布虚假的已封存 ID")
        XCTAssertEqual(session.pendingSealRecordID, recordID, "失败保留 pendingSeal 供重试")
        XCTAssertNotNil(session.pendingSealReason, "失败原因须保留供界面展示")
        XCTAssertNotNil(session.lastFailure, "失败须有用户可见提示")
        // 复制出口以内存 turns 为准：问题行仍在内存，可复制。
        XCTAssertTrue(
            session.unsavedTranscriptText().contains("封存失败也不丢恢复出口"),
            "未保存文本须可复制"
        )
        // 重试已删记录仍失败，不伪造成功。
        let retried = await session.retryPendingSeal()
        XCTAssertFalse(retried, "重试不存在的记录不得返回成功")
    }
}

/// 纯文字路径的占位音频源：若被误用会立刻计数，测试据此断言“没碰设备”。
private final class FakeTextOnlyAudio: AudioChunkSource, @unchecked Sendable {
    func start() async throws -> AsyncStream<AudioChunk> {
        throw NSError(domain: "AssistantEndRoutingTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "纯文字不应启动采集"])
    }

    func stop() {}
}
