import Foundation
import SwiftUI
import AppKit
import SQLite3
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 会议纪要任务的身份、恢复、取消与配置冻结（方案 MA-07 / 场景 MC-27～MC-32）。
///
/// 这里钉的是库这一层的约束，不碰界面，也不发真实请求：
/// - 租约过期后认领的是**原任务**：不新建版本，代际推进；
/// - 远端响应 id 落库后，重启查原请求；提交结果未知时不自动重发；
/// - 心跳、取消、终态都带 fencing：旧执行者迟到改不动新 owner 的行；
/// - 配置在排队那一刻冻结，指纹里没有密钥。
@MainActor
final class MeetingMinutesJobRecoveryTests: XCTestCase {
    private var directory: URL?
    private var store: SessionStore?
    private var sessionID: String?

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-minutes-job-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        try await store.open()
        let record = try await store.createSession(
            SessionDraft(kind: .meeting, engineProfile: "test", audioSource: .microphone)
        )
        self.directory = directory
        self.store = store
        self.sessionID = record.id
    }

    override func tearDown() async throws {
        if let store { await store.close() }
        store = nil
        sessionID = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try await super.tearDown()
    }

    private func requireStore() throws -> SessionStore {
        try XCTUnwrap(store)
    }

    private func requireSessionID() throws -> String {
        try XCTUnwrap(sessionID)
    }

    /// 认领并解包。`XCTUnwrap` 的自动闭包里不能 `await`，所以先取出来再解。
    private func claim(
        _ store: SessionStore,
        _ sessionID: String,
        lease: TimeInterval = 600
    ) async throws -> MinutesVersion {
        let claimed = try await store.claimMinutes(sessionID: sessionID, lease: lease)
        return try XCTUnwrap(claimed, "这一版必须能认领")
    }

    /// 取一行并解包。`XCTUnwrap` 的自动闭包里不能 `await`，所以先取出来再解。
    private func version(_ store: SessionStore, _ id: String) async throws -> MinutesVersion {
        let row = try await store.minutesVersion(id: id)
        return try XCTUnwrap(row, "纪要行必须读得到")
    }

    func testPageReloadCannotReplaceTheActiveMinutesOwner() async throws {
        let store = try requireStore(), id = try requireSessionID()
        _ = try await store.appendLine(.init(sessionID: id, role: .speaker,
            text: "确定性测试正文。", source: .microphone, status: .final))
        let other = try await store.createSession(.init(kind: .meeting, engineProfile: "test", audioSource: .microphone))
        let generator = MinutesGenerator(coordinator: SessionCoordinator(store: store))
        let work = Task { await generator.generate(sessionID: id, configuration: .init()) }
        await Task.yield()
        await generator.reload(sessionID: other.id)
        await work.value
        XCTAssertEqual(generator.sessionID, id, "页面刷新不能把正在整理的会议换成另一场")
        guard case .failed = generator.state else { return XCTFail("缺配置应显示失败出口，不能被刷新成空态") }
        let rows = try await store.minutesVersions(sessionID: id)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.status, .failed)
        let reopened = MinutesGenerator(coordinator: SessionCoordinator(store: store))
        await reopened.reload(sessionID: id)
        XCTAssertEqual(reopened.sessionID, id)
        guard case .failed = reopened.state else { return XCTFail("重新打开仍须显示可恢复的失败状态") }
    }

    func testStopWhilePreparingQueuePersistsCancellationWithoutSubmitting() async throws {
        let store = try requireStore(), id = try requireSessionID()
        _ = try await store.appendLine(.init(sessionID: id, role: .speaker,
            text: "尚未提交的测试正文。", source: .microphone, status: .final))
        let generator = MinutesGenerator(coordinator: SessionCoordinator(store: store))
        let work = Task { await generator.generate(sessionID: id, configuration: .init()) }
        await Task.yield()
        generator.stop()
        await work.value
        XCTAssertEqual(generator.state, .cancelled)
        let rows = try await store.minutesVersions(sessionID: id)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.status, .cancelled)
    }

    // MARK: - MC-27 租约过期后认领原任务

    /// MC-27：租约过期后重启，认领的是**同一条** job —— 版本号不变、代际推进，
    /// 不新建纪要版本，也不新起一个会议。
    func testExpiredLeaseReclaimsSameJobWithoutNewVersion() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let queued = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 12)
        let first = try await claim(store, sessionID, lease: -1)
        XCTAssertEqual(first.id, queued.id)
        XCTAssertEqual(first.attempts, 1)

        // 租约已过期：pending 扫描必须把这一条原样交回去。
        let pending = try await store.pendingMinutesRows()
        XCTAssertEqual(pending.map(\.id), [queued.id], "恢复必须认领原 job，不是新版本")

        let second = try await claim(store, sessionID)
        XCTAssertEqual(second.id, queued.id)
        XCTAssertEqual(second.version, queued.version, "恢复不推进纪要版本号")
        XCTAssertEqual(second.attempts, 2, "代际必须推进 fencing")
        let versions = try await store.minutesVersions(sessionID: sessionID)
        XCTAssertEqual(versions.count, 1, "恢复不得无意义地新建版本")
    }

    // MARK: - MC-28 持久远端响应 id / 提交结果未知

    private func chatMinutesResponse(sourceUnitIDs: [String] = ["u1"]) throws -> String {
        let candidate = MinutesCandidateV2(title: "发布安排",
            overview: [.init(localID: "o1", text: "讨论发布安排。", sourceUnitIDs: sourceUnitIDs)],
            decisions: [], actions: [], openQuestions: [], confidenceNotes: "")
        let content = String(decoding: try JSONEncoder().encode(candidate), as: UTF8.self)
        return String(decoding: try JSONSerialization.data(withJSONObject: [
            "id": "chat-minutes", "object": "chat.completion", "created": 1, "model": "configured-model",
            "choices": [["index": 0, "finish_reason": "stop",
                         "message": ["role": "assistant", "content": content]]],
            "usage": ["prompt_tokens": 20, "completion_tokens": 100, "total_tokens": 120]
        ]), as: UTF8.self)
    }

    func testNewMinutesUseConfiguredChatProviderWithoutBackground() async throws {
        let store = try requireStore(), sessionID = try requireSessionID()
        _ = try await store.appendLine(.init(sessionID: sessionID, role: .speaker,
            text: "讨论发布安排。", source: .microphone, status: .final))
        typealias Transport = LLMProviderTests.FakeTransport
        Transport.reset([.init(status: 200, contentType: "application/json",
            body: try chatMinutesResponse())])
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [Transport.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let generator = MinutesGenerator(coordinator: SessionCoordinator(store: store),
            provider: LLMProvider(session: session))
        await generator.generate(sessionID: sessionID, resolvedConfiguration: .init(
            configuration: .init(baseURL: "https://configured.invalid/v1", model: "configured-model",
                                 compatibilityMode: .openCodeGo),
            apiKey: nil, origin: .moduleOverride))
        XCTAssertEqual(generator.state, .ready)
        XCTAssertEqual(Transport.requestURLs().compactMap { URL(string: $0)?.host }, ["configured.invalid"])
        XCTAssertEqual(Transport.requestURLs().compactMap { URL(string: $0)?.path }, ["/v1/chat/completions"])
        let body = try XCTUnwrap(Transport.requestBodies().first)
        XCTAssertEqual(body["model"] as? String, "configured-model")
        XCTAssertNil(body["background"])
        XCTAssertNil(body["prompt_cache_options"])
        let versions = try await store.minutesVersions(sessionID: sessionID)
        let version = try XCTUnwrap(versions.first)
        XCTAssertEqual(version.status, .ready)
        XCTAssertTrue(version.body?.contains("发布安排") == true)
        let windows = try await store.minutesWindows(minutesID: version.id)
        XCTAssertEqual(windows.map(\.outcome), [.processed])
        XCTAssertNil(windows.first?.remoteResponseID)
        let lines = try await store.lines(sessionID: sessionID)
        XCTAssertEqual(lines.map(\.text), ["讨论发布安排。"])
    }

    func testResponsesOnlyMinutesCanDropFormatAndPersistWithoutBackgroundTask() async throws {
        let store = try requireStore(), sessionID = try requireSessionID()
        _ = try await store.appendLine(.init(sessionID: sessionID, role: .speaker,
            text: "讨论发布安排。", source: .microphone, status: .final))
        let chat = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(try chatMinutesResponse().utf8)) as? [String: Any])
        let choices = try XCTUnwrap(chat["choices"] as? [[String: Any]])
        let content = try XCTUnwrap((choices.first?["message"] as? [String: Any])?["content"] as? String)
        let response = String(decoding: try JSONSerialization.data(withJSONObject: [
            "id": "resp-ordinary", "object": "response", "status": "completed",
            "output": [["type": "message", "role": "assistant",
                        "content": [["type": "output_text", "text": content]]]],
            "usage": ["input_tokens": 20, "output_tokens": 100]
        ]), as: UTF8.self)
        typealias Transport = LLMProviderTests.FakeTransport
        Transport.reset([
            .init(status: 405, contentType: "application/json", body: "{}"),
            .init(status: 400, contentType: "application/json",
                  body: #"{"error":{"message":"Unsupported parameter: text.format"}}"#),
            .init(status: 200, contentType: "application/json", body: response)
        ])
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [Transport.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let generator = MinutesGenerator(coordinator: SessionCoordinator(store: store),
            provider: LLMProvider(session: session))
        await generator.generate(sessionID: sessionID, resolvedConfiguration: .init(
            configuration: .init(baseURL: "https://responses-only.invalid/custom/v1",
                                 model: "configured-model", compatibilityMode: .openCodeGo),
            apiKey: nil, origin: .global))
        XCTAssertEqual(generator.state, .ready)
        XCTAssertEqual(Transport.requestURLs().compactMap { URL(string: $0)?.path }, [
            "/custom/v1/chat/completions", "/custom/v1/responses", "/custom/v1/responses"
        ])
        XCTAssertTrue(Transport.requestURLs().allSatisfy { URL(string: $0)?.host == "responses-only.invalid" })
        XCTAssertTrue(Transport.requestBodies().allSatisfy {
            $0["background"] == nil && $0["model"] as? String == "configured-model"
        })
        XCTAssertNil(Transport.requestBodies().last?["text"])
        let versions = try await store.minutesVersions(sessionID: sessionID)
        let current = try XCTUnwrap(versions.first)
        XCTAssertEqual(current.status, .ready)
        XCTAssertFalse(current.hasRemoteResponse, "普通 Responses ID 不作为后台任务续跑")
        await store.close()
        try await store.open()
        let windows = try await store.minutesWindows(minutesID: current.id)
        XCTAssertEqual(windows.map(\.outcome), [.processed])
        XCTAssertNil(windows.first?.remoteResponseID)
        XCTAssertNotNil(windows.first?.candidate)
        let retained = try await version(store, current.id)
        XCTAssertTrue(retained.body?.contains("发布安排") == true)
        let lines = try await store.lines(sessionID: sessionID)
        XCTAssertEqual(lines.map(\.text), ["讨论发布安排。"])
    }

    func testFormatDowngradeStillMarksFabricatedReferencesAsRejected() async throws {
        let store = try requireStore(), sessionID = try requireSessionID()
        _ = try await store.appendLine(.init(sessionID: sessionID, role: .speaker,
            text: "讨论发布安排。", source: .microphone, status: .final))
        typealias Transport = LLMProviderTests.FakeTransport
        Transport.reset([
            .init(status: 400, contentType: "application/json",
                  body: #"{"error":{"message":"Unsupported parameter: response_format"}}"#),
            .init(status: 200, contentType: "application/json",
                  body: try chatMinutesResponse(sourceUnitIDs: ["nonexistent-unit"]))
        ])
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [Transport.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let generator = MinutesGenerator(coordinator: SessionCoordinator(store: store),
            provider: LLMProvider(session: session))
        await generator.generate(sessionID: sessionID, resolvedConfiguration: .init(
            configuration: .init(baseURL: "https://minutes.invalid/v1", model: "configured-model"),
            apiKey: nil, origin: .global))
        XCTAssertEqual(generator.state, .ready, "候选保留供核对，但伪造引用不得升为可信")
        XCTAssertEqual(generator.candidateReview?.rejectedCount, 1)
        XCTAssertTrue(generator.latestBody?.contains("未通过引用核对") == true)
        XCTAssertEqual(Transport.requestURLs().count, 2)
        let versions = try await store.minutesVersions(sessionID: sessionID)
        let current = try XCTUnwrap(versions.first)
        let windows = try await store.minutesWindows(minutesID: current.id)
        XCTAssertEqual(windows.first?.candidate?.overview.first?.sourceUnitIDs, ["nonexistent-unit"])
        let lines = try await store.lines(sessionID: sessionID)
        XCTAssertEqual(lines.map(\.text), ["讨论发布安排。"])
    }

    func testStatelessMultiwindowRetryReusesCompletedWindowsAfterDatabaseReopen() async throws {
        let store = try requireStore(), sessionID = try requireSessionID()
        let transcript = String(repeating: "讨论发布安排。", count: 1_000)
        _ = try await store.appendLine(.init(sessionID: sessionID, role: .speaker,
            text: transcript, source: .microphone, status: .final))
        let snapshot = try await store.sealMeetingSource(sessionID: sessionID)
        XCTAssertNotNil(snapshot)
        let units = MinutesGenerator.sourceUnits(lines: try await store.lines(sessionID: sessionID), names: [:])
        let windows = MinutesWindowPlanner.plan(units: units, budget: MinutesGenerator.windowBudget)
        XCTAssertGreaterThan(windows.count, 1)
        guard windows.count > 1 else { return }
        typealias Transport = LLMProviderTests.FakeTransport
        Transport.reset([
            .init(status: 200, contentType: "application/json",
                  body: try chatMinutesResponse(sourceUnitIDs: windows[0].owned.map(\.id))),
            .init(status: 503, contentType: "application/json", body: "{}")
        ])
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [Transport.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let resolved = ResolvedLLMConfiguration(
            configuration: .init(baseURL: "https://minutes.invalid/v1", model: "configured-model"),
            apiKey: nil, origin: .global)
        let coordinator = SessionCoordinator(store: store)
        let generator = MinutesGenerator(coordinator: coordinator, provider: LLMProvider(session: session))
        await generator.generate(sessionID: sessionID, resolvedConfiguration: resolved)
        let versions = try await store.minutesVersions(sessionID: sessionID)
        let current = try XCTUnwrap(versions.first)
        let before = try await store.minutesWindows(minutesID: current.id)
        XCTAssertEqual(before.map(\.outcome), [.processed, .failed])
        XCTAssertEqual(Transport.requestURLs().count, 2)
        await store.close()
        try await store.open()
        Transport.reset(try windows.dropFirst().map {
            .init(status: 200, contentType: "application/json",
                  body: try chatMinutesResponse(sourceUnitIDs: $0.owned.map(\.id)))
        })
        let resumed = MinutesGenerator(coordinator: coordinator, provider: LLMProvider(session: session))
        await resumed.retryFailedWindows(sessionID: sessionID, resolvedConfiguration: resolved)
        XCTAssertEqual(resumed.state, .ready)
        XCTAssertTrue(resumed.coverage?.isComplete == true)
        XCTAssertEqual(resumed.candidateReview?.rejectedCount, 0, "切分来源仍须通过最终引用核对")
        XCTAssertEqual(resumed.coverage?.eligibleUnitIDs, windows.flatMap { $0.owned.map(\.id) })
        XCTAssertEqual(Transport.requestURLs().count, windows.count - 1, "完成窗口不可再次提交")
        let after = try await store.minutesWindows(minutesID: current.id)
        XCTAssertEqual(after.map(\.outcome), Array(repeating: .processed, count: windows.count))
        XCTAssertEqual(after.first?.candidateJSON, before.first?.candidateJSON)
        let retainedVersions = try await store.minutesVersions(sessionID: sessionID)
        XCTAssertEqual(retainedVersions.map(\.id), [current.id])
        let items = try await store.minutesItems(minutesID: current.id)
        let anchors = items.flatMap(\.anchors)
        XCTAssertEqual(Set(anchors.map(\.unitID)), Set(windows.flatMap { $0.owned.map(\.id) }))
        XCTAssertTrue(anchors.allSatisfy { $0.revisionID != nil && $0.quote == transcript })
        let lines = try await store.lines(sessionID: sessionID)
        XCTAssertEqual(lines.map(\.text), [transcript])
    }

    func testStatelessMinutesTransportFailureStaysUnknownAndIsNotAutomaticallyResent() async throws {
        let store = try requireStore(), sessionID = try requireSessionID()
        _ = try await store.appendLine(.init(sessionID: sessionID, role: .speaker,
            text: "讨论发布安排。", source: .microphone, status: .final))
        typealias Transport = LLMProviderTests.FakeTransport
        Transport.reset([.init(status: 200, contentType: "application/json", body: "", failCode: .timedOut)])
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [Transport.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let resolved = ResolvedLLMConfiguration(
            configuration: .init(baseURL: "https://minutes.invalid/v1", model: "configured-model"),
            apiKey: nil, origin: .global)
        let coordinator = SessionCoordinator(store: store)
        let generator = MinutesGenerator(coordinator: coordinator, provider: LLMProvider(session: session))
        await generator.generate(sessionID: sessionID, resolvedConfiguration: resolved)
        XCTAssertEqual(generator.state, .submissionUnknown)
        let versions = try await store.minutesVersions(sessionID: sessionID)
        let current = try XCTUnwrap(versions.first)
        let windows = try await store.minutesWindows(minutesID: current.id)
        XCTAssertEqual(windows.map(\.outcome), [.submitted])
        XCTAssertNil(windows.first?.remoteResponseID)
        await store.close()
        try await store.open()
        Transport.reset([])
        let resumed = MinutesGenerator(coordinator: coordinator, provider: LLMProvider(session: session))
        await resumed.recoverPending(resolvedConfiguration: resolved)
        XCTAssertTrue(Transport.requestURLs().isEmpty)
        let retained = try await store.lines(sessionID: sessionID)
        XCTAssertEqual(retained.map(\.text), ["讨论发布安排。"])
    }

    func testCrashWithStatelessSubmittedWindowDoesNotSubmitAgain() async throws {
        let store = try requireStore(), sessionID = try requireSessionID()
        _ = try await store.appendLine(.init(sessionID: sessionID, role: .speaker,
            text: "讨论发布安排。", source: .microphone, status: .final))
        let resolved = ResolvedLLMConfiguration(
            configuration: .init(baseURL: "https://minutes.invalid/v1", model: "configured-model"),
            apiKey: nil, origin: .global)
        let units = MinutesGenerator.sourceUnits(lines: try await store.lines(sessionID: sessionID), names: [:])
        let windows = MinutesWindowPlanner.plan(units: units, budget: MinutesGenerator.windowBudget)
        var config = MinutesJobConfig(resolved.configuration)
        config.inputFingerprint = try MinutesGenerator.inputFingerprint(units: units, windows: windows, supplements: "")
        let queued = try await store.enqueueMinutes(sessionID: sessionID, model: "configured-model",
            promptChars: 8, configSnapshot: config.fingerprint)
        let owner = try await claim(store, sessionID, lease: -1)
        let saved = try await store.recordMinutesWindow(minutesID: queued.id, expectedAttempts: owner.attempts,
            record: .init(index: 0, ownedUnitIDs: ["u1"], outcome: .submitted))
        XCTAssertTrue(saved)
        await store.close()
        try await store.open()
        typealias Transport = LLMProviderTests.FakeTransport
        Transport.reset([])
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [Transport.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let generator = MinutesGenerator(coordinator: SessionCoordinator(store: store),
            provider: LLMProvider(session: session))
        await generator.recoverPending(resolvedConfiguration: resolved)
        XCTAssertEqual(generator.state, .submissionUnknown)
        XCTAssertTrue(Transport.requestURLs().isEmpty)
        let after = try await version(store, queued.id)
        XCTAssertEqual(after.status, .submissionUnknown)
    }

    func testKnownStatelessFailureCanRetrySameVersionWithFrozenProvider() async throws {
        let store = try requireStore(), sessionID = try requireSessionID()
        _ = try await store.appendLine(.init(sessionID: sessionID, role: .speaker,
            text: "讨论发布安排。", source: .microphone, status: .final))
        typealias Transport = LLMProviderTests.FakeTransport
        Transport.reset([.init(status: 401, contentType: "application/json", body: "{}")])
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [Transport.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let resolved = ResolvedLLMConfiguration(
            configuration: .init(baseURL: "https://minutes.invalid/v1", model: "configured-model"),
            apiKey: nil, origin: .global)
        let generator = MinutesGenerator(coordinator: SessionCoordinator(store: store),
            provider: LLMProvider(session: session))
        await generator.generate(sessionID: sessionID, resolvedConfiguration: resolved)
        let versions = try await store.minutesVersions(sessionID: sessionID)
        let current = try XCTUnwrap(versions.first)
        let windows = try await store.minutesWindows(minutesID: current.id)
        XCTAssertEqual(windows.map(\.outcome), [.failed])
        Transport.reset([.init(status: 200, contentType: "application/json", body: try chatMinutesResponse())])
        let changed = ResolvedLLMConfiguration(
            configuration: .init(baseURL: "https://changed.invalid/v1", model: "new-model"),
            apiKey: nil, origin: .global)
        await generator.retryFailedWindows(sessionID: sessionID, resolvedConfiguration: changed)
        XCTAssertEqual(generator.state, .ready)
        XCTAssertTrue(generator.jobConfigDiffersFromCurrent)
        XCTAssertEqual(Transport.requestURLs().compactMap { URL(string: $0)?.host }, ["minutes.invalid"])
        XCTAssertEqual(Transport.requestBodies()[0]["model"] as? String, "configured-model")
        let after = try await store.minutesVersions(sessionID: sessionID)
        XCTAssertEqual(after.map(\.id), [current.id])
    }

    func testCancellingNewStatelessJobDoesNotCancelHistoricalResponse() async throws {
        let store = try requireStore(), sessionID = try requireSessionID()
        _ = try await store.appendLine(.init(sessionID: sessionID, role: .speaker,
            text: "讨论发布安排。", source: .microphone, status: .final))
        let resolved = ResolvedLLMConfiguration(
            configuration: .init(baseURL: "https://minutes.invalid/v1", model: "configured-model"),
            apiKey: nil, origin: .global)
        let units = MinutesGenerator.sourceUnits(lines: try await store.lines(sessionID: sessionID), names: [:])
        let windows = MinutesWindowPlanner.plan(units: units, budget: MinutesGenerator.windowBudget)
        var config = MinutesJobConfig(resolved.configuration)
        config.inputFingerprint = try MinutesGenerator.inputFingerprint(units: units, windows: windows, supplements: "")
        let queued = try await store.enqueueMinutes(sessionID: sessionID, model: "configured-model",
            promptChars: 8, configSnapshot: config.fingerprint)
        let owner = try await claim(store, sessionID)
        let saved = try await store.recordMinutesWindow(minutesID: queued.id, expectedAttempts: owner.attempts,
            record: .init(index: 0, ownedUnitIDs: ["u1"], outcome: .submitted,
                          remoteResponseID: "resp-historical"))
        XCTAssertTrue(saved)
        try await store.failMinutes(minutesID: queued.id, reason: "interrupted")
        let chat = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(try chatMinutesResponse().utf8)) as? [String: Any])
        let choices = try XCTUnwrap(chat["choices"] as? [[String: Any]])
        let content = try XCTUnwrap((choices[0]["message"] as? [String: Any])?["content"] as? String)
        let response = try JSONSerialization.data(withJSONObject: [
            "id": "resp-historical", "object": "response", "status": "completed",
            "output": [["type": "message", "role": "assistant",
                        "content": [["type": "output_text", "text": content]]]]
        ])
        typealias Transport = LLMProviderTests.FakeTransport
        Transport.reset([.init(status: 200, contentType: "application/json",
                               body: String(decoding: response, as: UTF8.self))])
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [Transport.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let generator = MinutesGenerator(coordinator: SessionCoordinator(store: store),
            provider: LLMProvider(session: session))
        await generator.retryFailedWindows(sessionID: sessionID, resolvedConfiguration: resolved)
        XCTAssertEqual(generator.state, .ready)
        XCTAssertEqual(generator.lastResponseID, "resp-historical")
        Transport.reset([.init(status: 200, contentType: "application/json", body: "", failCode: .cancelled)])
        await generator.generate(sessionID: sessionID, resolvedConfiguration: resolved)
        XCTAssertEqual(generator.state, .cancelled)
        XCTAssertNil(generator.lastResponseID)
        XCTAssertEqual(Transport.requestURLs().compactMap { URL(string: $0)?.path }, ["/v1/chat/completions"])
    }

    func testWindowCheckpointsAreScopedToMinutesVersion() async throws {
        let store = try requireStore(), sessionID = try requireSessionID()
        var ids: [String] = []
        for _ in 0..<2 {
            let queued = try await store.enqueueMinutes(sessionID: sessionID, model: "configured-model",
                                                        promptChars: 8)
            let owner = try await claim(store, sessionID)
            let recorded = try await store.recordMinutesWindow(minutesID: queued.id,
                expectedAttempts: owner.attempts,
                record: .init(index: 0, ownedUnitIDs: ["u1"], outcome: .submitted))
            XCTAssertTrue(recorded)
            try await store.failMinutes(minutesID: queued.id, reason: "test")
            ids.append(queued.id)
        }
        for id in ids {
            let records = try await store.minutesWindows(minutesID: id)
            XCTAssertEqual(records.map(\.index), [0])
            XCTAssertEqual(records.map(\.outcome), [.submitted])
        }
    }

    func testMultiwindowPollFailureRetainsResponseIDAndRetryDoesNotResubmit() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        _ = try await store.appendLine(LineDraft(
            sessionID: sessionID, role: .speaker,
            text: String(repeating: "这是会议记录。", count: 1_000),
            source: .microphone, status: .final
        ))
        let lines = try await store.lines(sessionID: sessionID)
        let units = MinutesGenerator.sourceUnits(lines: lines, names: [:])
        let windows = MinutesWindowPlanner.plan(units: units, budget: MinutesGenerator.windowBudget)
        XCTAssertGreaterThan(windows.count, 1)

        typealias Transport = LLMProviderTests.FakeTransport
        Transport.reset([
            .init(status: 400, contentType: "application/json", body: #"{"error":{"message":"poll unavailable"}}"#)
        ])
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [Transport.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let provider = LLMProvider(session: session)
        let resolved = ResolvedLLMConfiguration(
            configuration: LLMConfiguration(baseURL: "https://minutes.invalid/v1", model: "fake-model"),
            apiKey: nil, origin: .global
        )
        let coordinator = SessionCoordinator(store: store)
        let generator = MinutesGenerator(coordinator: coordinator, provider: provider)
        // 历史 App 已提交的后台任务：新 App 只能继续查询这个 ID。
        var config = MinutesJobConfig(resolved.configuration)
        config.inputFingerprint = try MinutesGenerator.inputFingerprint(
            units: units, windows: windows, supplements: "")
        let queued = try await store.enqueueMinutes(sessionID: sessionID, model: "fake-model",
            promptChars: 8_000, configSnapshot: config.fingerprint)
        let owner = try await claim(store, sessionID)
        let checkpointed = try await store.recordMinutesWindow(minutesID: queued.id,
            expectedAttempts: owner.attempts, record: .init(index: 0,
                ownedUnitIDs: windows[0].owned.map(\.id),
                contextUnitIDs: (windows[0].contextBefore + windows[0].contextAfter).map(\.id),
                outcome: .submitted, remoteResponseID: "resp-window-1"))
        XCTAssertTrue(checkpointed)
        try await store.failMinutes(minutesID: queued.id, reason: "interrupted")
        await generator.retryFailedWindows(sessionID: sessionID, resolvedConfiguration: resolved)
        let versions = try await store.minutesVersions(sessionID: sessionID)
        let version = try XCTUnwrap(versions.first)
        let records = try await store.minutesWindows(minutesID: version.id)
        let saved = try XCTUnwrap(records.first, "轮询失败不能丢失已经提交的窗口身份")
        XCTAssertEqual(saved.remoteResponseID, "resp-window-1")
        XCTAssertEqual(saved.outcome.rawValue, "submitted")
        XCTAssertNil(saved.candidate)
        XCTAssertEqual(saved.ownedUnitIDs, windows[0].owned.map(\.id))
        XCTAssertEqual(saved.contextUnitIDs, (windows[0].contextBefore + windows[0].contextAfter).map(\.id))
        let ledger = MinutesCoverageLedger(
            eligibleUnitIDs: saved.ownedUnitIDs,
            windows: [.init(index: saved.index, ownedUnitIDs: saved.ownedUnitIDs, outcome: saved.outcome)]
        )
        XCTAssertTrue(ledger.coveredUnitIDs.isEmpty, "已提交不能冒充已有可用结果")
        XCTAssertEqual(ledger.gapUnitIDs, saved.ownedUnitIDs)

        // 重开数据库模拟 App 重启；原窗口身份必须持久，而不是只留在生成器内存。
        await store.close()
        try await store.open()
        Transport.reset([
            .init(status: 400, contentType: "application/json", body: #"{"error":{"message":"poll unavailable"}}"#)
        ])
        let resumed = MinutesGenerator(coordinator: coordinator, provider: provider)
        await resumed.retryFailedWindows(sessionID: sessionID, resolvedConfiguration: resolved)
        XCTAssertEqual(Transport.requestURLs(), ["https://minutes.invalid/v1/responses/resp-window-1"])
        let afterRetry = try await store.minutesVersions(sessionID: sessionID)
        XCTAssertEqual(afterRetry.map(\.id), [version.id])
        let retained = try await store.lines(sessionID: sessionID)
        XCTAssertEqual(retained.map(\.text), lines.map(\.text))

        // 同一任务的来源随后变化，不能把旧响应绑定到重新切分的窗口。
        _ = try await store.appendLine(.init(sessionID: sessionID, role: .speaker,
            text: "新增的会议记录。", source: .microphone, status: .final))
        Transport.reset([])
        await resumed.retryFailedWindows(sessionID: sessionID, resolvedConfiguration: resolved)
        XCTAssertTrue(Transport.requestURLs().isEmpty, "输入变化后既不能轮询混用，也不能重新 POST")
        guard case .failed(let reason) = resumed.state else { return XCTFail("输入变化应明确停止") }
        XCTAssertTrue(reason.contains("重新生成"))
        let unchanged = try await store.minutesWindows(minutesID: version.id)
        XCTAssertEqual(unchanged, records, "旧响应、候选和窗口记录必须保留")
        let savedConfig = try XCTUnwrap(MinutesJobConfig.parse(version.configSnapshot))
        XCTAssertNotNil(savedConfig.inputFingerprint)
    }

    func testMinutesInputFingerprintRoundTripsWithoutChangingProviderConfiguration() throws {
        let configuration = LLMConfiguration(baseURL: "https://minutes.invalid/v1", model: "fake-model")
        var frozen = MinutesJobConfig(configuration)
        frozen.inputFingerprint = String(repeating: "a1", count: 32)
        let restored = try XCTUnwrap(MinutesJobConfig.parse(frozen.fingerprint))
        XCTAssertEqual(restored, frozen)
        XCTAssertEqual(restored.configuration, configuration)
        XCTAssertNil(MinutesJobConfig.parse(frozen.fingerprint + "|extra"))
        XCTAssertNil(MinutesJobConfig.parse("https://minutes.invalid/v1|fake-model|openAICompatible|invalid"))
    }

    func testLegacyWindowWithoutInputFingerprintIsNotPolledOrResubmitted() async throws {
        let store = try requireStore(), sessionID = try requireSessionID()
        _ = try await store.appendLine(.init(sessionID: sessionID, role: .speaker,
            text: "已有会议文字。", source: .microphone, status: .final))
        let resolved = ResolvedLLMConfiguration(
            configuration: .init(baseURL: "https://minutes.invalid/v1", model: "fake-model"),
            apiKey: nil, origin: .global)
        let queued = try await store.enqueueMinutes(sessionID: sessionID, model: "fake-model", promptChars: 8,
            configSnapshot: MinutesJobConfig(resolved.configuration).fingerprint)
        let owner = try await claim(store, sessionID)
        let record = MinutesWindowRecord(index: 0, ownedUnitIDs: ["u1"], outcome: .submitted,
            remoteResponseID: "resp-legacy")
        let recorded = try await store.recordMinutesWindow(minutesID: queued.id,
            expectedAttempts: owner.attempts, record: record)
        XCTAssertTrue(recorded)
        try await store.failMinutes(minutesID: queued.id, reason: "interrupted")
        let before = try await store.minutesWindows(minutesID: queued.id)
        typealias Transport = LLMProviderTests.FakeTransport
        Transport.reset([])
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [Transport.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let generator = MinutesGenerator(coordinator: SessionCoordinator(store: store), provider: LLMProvider(session: session))
        await generator.retryFailedWindows(sessionID: sessionID, resolvedConfiguration: resolved)
        XCTAssertTrue(Transport.requestURLs().isEmpty)
        guard case .failed(let reason) = generator.state else { return XCTFail("旧输入不可核对应停止") }
        XCTAssertTrue(reason.contains("重新生成"))
        let after = try await store.minutesWindows(minutesID: queued.id)
        XCTAssertEqual(after, before)
    }

    /// MC-28 前半句：response id 一拿到就落库；重开库读得回同一个 id。
    func testRemoteResponseIDSurvivesReopenAndIsNotResent() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        _ = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 20)
        let claimed = try await claim(store, sessionID)
        XCTAssertFalse(claimed.hasRemoteResponse, "刚认领时还没有远端响应")

        let recorded = try await store.recordMinutesRemoteResponse(
            minutesID: claimed.id,
            expectedAttempts: claimed.attempts,
            responseID: "resp-abc-123"
        )
        XCTAssertTrue(recorded)

        // 模拟执行者消失：租约到期。恢复扫描要把它连同远端 id 一起交回来。
        let expired = try await store.renewMinutesLease(
            minutesID: claimed.id, expectedAttempts: claimed.attempts, lease: -1
        )
        XCTAssertTrue(expired)

        let directory = try XCTUnwrap(directory)
        await store.close()
        let reopened = SessionStore(directory: directory)
        try await reopened.open()
        let pending = try await reopened.pendingMinutesRows()
        await reopened.close()

        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.remoteResponseID, "resp-abc-123", "远端响应 id 必须落库")
        XCTAssertTrue(
            pending.first?.hasRemoteResponse ?? false,
            "恢复时应当查询原请求而不是把整场重新发一遍"
        )
    }

    /// MC-28 后半句（§8.5）：远端可能已受理但没拿到回执 —— 落成明确状态，
    /// 且**不进待恢复扫描**，下一次启动不会把它当待办自动重发。
    func testSubmissionUnknownIsNotAutomaticallyResent() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        _ = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 20)
        let claimed = try await claim(store, sessionID)
        let marked = try await store.markMinutesSubmissionUnknown(
            minutesID: claimed.id,
            expectedAttempts: claimed.attempts
        )
        XCTAssertTrue(marked)

        let pending = try await store.pendingMinutesRows()
        XCTAssertTrue(pending.isEmpty, "提交结果未知不得进入自动恢复队列（会重复执行、重复计费）")
        let versions = try await store.minutesVersions(sessionID: sessionID)
        XCTAssertEqual(versions.first?.status, .submissionUnknown)
        XCTAssertNil(versions.first?.body, "未知提交不得留下正文")
    }

    /// 只有传输层失败才算"远端收没收到查不出来"；服务明确回了状态的不算。
    func testOnlyTransportFailureCountsAsSubmissionUnknown() {
        XCTAssertEqual(MinutesSubmissionCertainty.classify(LLMError.transport("连接断了")), .unknown)
        XCTAssertEqual(MinutesSubmissionCertainty.classify(LLMError.http(status: 500, body: "")), .known)
        XCTAssertEqual(MinutesSubmissionCertainty.classify(LLMError.notResponsesAPI), .known)
        XCTAssertEqual(MinutesSubmissionCertainty.classify(LLMError.refused("拒答")), .known)
        XCTAssertEqual(MinutesSubmissionCertainty.classify(LLMError.outputTruncated), .known)
    }

    // MARK: - MC-29 fencing

    /// MC-29：租约被新 owner 接管之后，旧 owner 的心跳、响应 id 与终态全部失效。
    func testLateOwnerCannotRenewRecordOrFinishAfterTakeover() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        _ = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 20)
        let old = try await claim(store, sessionID, lease: -1)
        let new = try await claim(store, sessionID)
        XCTAssertEqual(old.id, new.id)
        XCTAssertNotEqual(old.attempts, new.attempts)

        let renewedByOldOwner = try await store.renewMinutesLease(
            minutesID: old.id, expectedAttempts: old.attempts, lease: 600
        )
        XCTAssertFalse(renewedByOldOwner, "旧代际不得续租约")
        let recordedByOldOwner = try await store.recordMinutesRemoteResponse(
            minutesID: old.id, expectedAttempts: old.attempts, responseID: "resp-late"
        )
        XCTAssertFalse(recordedByOldOwner, "旧代际不得写远端响应 id")
        let finishedByOldOwner = try await store.finishMinutesIfOwner(
            minutesID: old.id, expectedAttempts: old.attempts, body: "# 迟到的正文", model: nil
        )
        XCTAssertFalse(finishedByOldOwner, "旧代际不得发布候选")

        let current = try await version(store, new.id)
        XCTAssertEqual(current.status, .running)
        XCTAssertNil(current.body, "迟到的正文一个字都不能落库")
        XCTAssertNil(current.remoteResponseID)
    }

    // MARK: - MC-30 取消

    /// MC-30：停止只停**指定任务**，落成"已停止"而不是"没整理出来"；
    /// 另一场正在跑的整理与已经存好的旧纪要都不受影响。
    func testCancelStopsOnlyTheTargetJobAndKeepsOlderMinutes() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let other = try await store.createSession(
            SessionDraft(kind: .meeting, engineProfile: "test", audioSource: .microphone)
        )

        let kept = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        _ = try await claim(store, sessionID)
        try await store.finishMinutesForTestOnly(minutesID: kept.id, body: "# 旧版纪要", model: nil)
        let running = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 9)
        let claimed = try await claim(store, sessionID)
        let otherQueued = try await store.enqueueMinutes(sessionID: other.id, model: nil, promptChars: 9)
        let otherClaimed = try await claim(store, other.id)

        let requested = try await store.requestCancelMinutes(minutesID: claimed.id)
        XCTAssertTrue(requested)
        let cancelled = try await store.cancelMinutesIfOwner(
            minutesID: claimed.id, expectedAttempts: claimed.attempts
        )
        XCTAssertTrue(cancelled)

        let stopped = try await version(store, running.id)
        XCTAssertEqual(stopped.status, .cancelled, "取消不是失败")
        XCTAssertNotNil(stopped.cancelRequestedAt, "取消请求要留痕，不能只停内存任务")

        let otherRunning = try await version(store, otherQueued.id)
        XCTAssertEqual(otherRunning.status, .running, "取消另一场不得影响这一场")
        XCTAssertNil(otherRunning.cancelRequestedAt)
        XCTAssertNotEqual(otherClaimed.id, claimed.id)

        // 旧纪要原文与展示口径都不动。
        let keptVersion = try await version(store, kept.id)
        XCTAssertEqual(keptVersion.body, "# 旧版纪要")
        let current = try await store.currentMinutes(sessionID: sessionID)
        XCTAssertEqual(current?.id, kept.id)

        let pending = try await store.pendingMinutesRows()
        XCTAssertFalse(pending.contains { $0.id == running.id }, "已停止的任务不再自动恢复")
    }

    /// 没写过取消请求就不许落成"已停止"——那会把别人接管的行说成用户不要了。
    func testCancelRequiresRequestAndMatchingGeneration() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        _ = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        let claimed = try await claim(store, sessionID)

        let withoutRequest = try await store.cancelMinutesIfOwner(
            minutesID: claimed.id, expectedAttempts: claimed.attempts
        )
        XCTAssertFalse(withoutRequest, "没有取消请求就不能落成已停止")

        let requested = try await store.requestCancelMinutes(minutesID: claimed.id)
        XCTAssertTrue(requested)
        let again = try await store.requestCancelMinutes(minutesID: claimed.id)
        XCTAssertFalse(again, "取消请求只记一次")
        let wrongGeneration = try await store.cancelMinutesIfOwner(
            minutesID: claimed.id, expectedAttempts: claimed.attempts + 1
        )
        XCTAssertFalse(wrongGeneration, "代际不符不得改写")
        let unchanged = try await store.minutesVersion(id: claimed.id)
        XCTAssertEqual(unchanged?.status, .running)
    }

    /// 已落终态的行不再接受取消：终态结论不能被后来的动作改写。
    func testCancelDoesNotOverwriteTerminalRow() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let queued = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        _ = try await claim(store, sessionID)
        try await store.finishMinutesForTestOnly(minutesID: queued.id, body: "# 已完成", model: nil)

        let requested = try await store.requestCancelMinutes(minutesID: queued.id)
        XCTAssertFalse(requested)
        let version = try await version(store, queued.id)
        XCTAssertEqual(version.status, .ready)
        XCTAssertEqual(version.body, "# 已完成")
        XCTAssertNil(version.cancelRequestedAt)
    }

    // MARK: - MC-32 配置冻结

    /// MC-32：排队那一刻冻结配置；指纹可还原，且**不含密钥**。
    func testJobConfigIsFrozenAtEnqueueAndCarriesNoSecret() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let configuration = LLMConfiguration(
            baseURL: "https://example.invalid/v1",
            model: "model-a",
            compatibilityMode: .openAICompatible
        )
        let fingerprint = MinutesJobConfig(configuration).fingerprint
        XCTAssertFalse(fingerprint.contains("sk-"), "指纹里不得出现密钥")

        let queued = try await store.enqueueMinutes(
            sessionID: sessionID,
            model: "model-a",
            promptChars: 11,
            configSnapshot: fingerprint,
            snapshotID: "snap-1"
        )
        XCTAssertEqual(queued.configSnapshot, fingerprint)
        XCTAssertEqual(queued.snapshotID, "snap-1", "任务绑定来源快照")

        let reread = try await version(store, queued.id)
        XCTAssertEqual(reread.configSnapshot, fingerprint, "冻结的配置要能读回来")
        XCTAssertEqual(reread.snapshotID, "snap-1")

        // 还原出来的是**任务答应过**的那套，不是当前设置。
        let restored = try XCTUnwrap(MinutesJobConfig.parse(reread.configSnapshot))
        XCTAssertEqual(restored.configuration.baseURL, "https://example.invalid/v1")
        XCTAssertEqual(restored.configuration.model, "model-a")
        XCTAssertNotEqual(
            restored,
            MinutesJobConfig(LLMConfiguration(baseURL: "https://other.invalid/v1", model: "model-b")),
            "换了设置就该看得出来：新配置从下一次任务生效"
        )
        XCTAssertNil(MinutesJobConfig.parse("只有|两段"), "形状不合法就读不出，不猜也不填默认值")
        XCTAssertNil(MinutesJobConfig.parse(nil))
    }

    // MARK: - schema v4 迁移

    /// v3 库升到 v4：四列补齐、既有行不写回值（老任务本来就没存过远端响应 id）。
    func testMigrationV3ToV4AddsTaskIdentityColumnsWithoutBackfill() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let queued = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        let directory = try XCTUnwrap(directory)
        await store.close()

        // 把库按 v3 形状摆回去：去掉四列、把 user_version 置 3。
        try Self.runSQL(
            on: directory.appendingPathComponent(SessionStore.fileName),
            statements: [
                "ALTER TABLE minutes DROP COLUMN remote_response_id;",
                "ALTER TABLE minutes DROP COLUMN config_snapshot;",
                "ALTER TABLE minutes DROP COLUMN snapshot_id;",
                "ALTER TABLE minutes DROP COLUMN cancel_requested_at;",
                "PRAGMA user_version=3;",
            ]
        )

        let migrated = SessionStore(directory: directory)
        try await migrated.open()
        let version = try await version(migrated, queued.id)
        await migrated.close()

        XCTAssertEqual(version.status, .queued, "迁移不动既有行的语义")
        XCTAssertNil(version.remoteResponseID, "老任务没存过远端响应 id，不补造")
        XCTAssertNil(version.configSnapshot)
        XCTAssertNil(version.snapshotID)
        XCTAssertNil(version.cancelRequestedAt)
    }

    func testRecoverPendingWithQueuedRowAndUnconfiguredLLMPersistsFailedAndClearsBusy() async throws {
        let store = try requireStore(), sessionID = try requireSessionID()
        _ = try await store.appendLine(
            .init(sessionID: sessionID, role: .speaker, text: "需要整理的正文。", source: .microphone, status: .final)
        )
        let queued = try await store.enqueueMinutes(
            sessionID: sessionID,
            model: nil,
            promptChars: 8,
            configSnapshot: nil,
            snapshotID: nil
        )
        XCTAssertEqual(queued.status, .queued)

        let coordinator = SessionCoordinator(store: store)
        let generator = MinutesGenerator(coordinator: coordinator)
        await generator.recoverPending(
            resolvedConfiguration: .init(
                configuration: .init(baseURL: "", model: ""),
                apiKey: nil,
                origin: .global
            )
        )
        XCTAssertFalse(generator.isBusy)
        if case .failed = generator.state {
            // Expected
        } else {
            XCTFail("未配置大模型恢复 queued 纪要后应收敛为 .failed，实际为 \(generator.state)")
        }

        await generator.reload(sessionID: sessionID)
        XCTAssertFalse(generator.isBusy, "reload 后不得回退成 .queued 造成 isBusy 死锁")
        if case .failed = generator.state {
            // Expected
        } else {
            XCTFail("reload 后状态仍应保持 .failed，实际为 \(generator.state)")
        }
        let persisted = try await version(store, queued.id)
        XCTAssertEqual(persisted.status, .failed, "SQLite 中的 queued 行必须落库为 failed")
    }

    func testStopOnReloadedOrphanQueuedMinutesCancelsRowAndUnblocksNewMeeting() async throws {
        let store = try requireStore(), sessionID = try requireSessionID()
        _ = try await store.appendLine(
            .init(sessionID: sessionID, role: .speaker, text: "孤儿排队纪要。", source: .microphone, status: .final)
        )
        let queued = try await store.enqueueMinutes(
            sessionID: sessionID,
            model: "test-model",
            promptChars: 7,
            configSnapshot: nil,
            snapshotID: nil
        )
        let coordinator = SessionCoordinator(store: store)
        let generator = MinutesGenerator(coordinator: coordinator)
        await generator.reload(sessionID: sessionID)
        XCTAssertEqual(generator.state, .queued)
        XCTAssertTrue(generator.isBusy)

        generator.stop()
        XCTAssertFalse(generator.isBusy, "点击停止整理后应立即解除 isBusy 阻塞")
        XCTAssertEqual(generator.state, .cancelled)

        for _ in 0..<200 {
            if (try? await version(store, queued.id).status) == .cancelled { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let persisted = try await version(store, queued.id)
        XCTAssertEqual(persisted.status, .cancelled, "孤儿 queued 纪要行在点击停止后应持久化为 cancelled")
    }

    // MARK: - 工具

    /// 直接对库文件执行 SQL（模拟"库已经是旧形状"）。测试内用，sqlite3 系统库已链。
    private static func runSQL(on file: URL, statements: [String]) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(file.path, &pointer, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let pointer else {
            XCTFail("打不开临时库文件：\(file.lastPathComponent)")
            return
        }
        defer { sqlite3_close_v2(pointer) }
        for statement in statements {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(pointer, statement, nil, nil, &error) == SQLITE_OK else {
                let detail = error.map { String(cString: $0) } ?? "未知错误"
                sqlite3_free(error)
                XCTFail("执行 `\(statement)` 失败：\(detail)")
                return
            }
        }
    }
}

final class MinutesMarkdownTests: XCTestCase {
    func testMeetingHeadingsListsAndQuotesAreRenderedAsBlocks() throws {
        let source = "# 会议标题\n\n## 概述\n\n- **要点**内容\n- 第二条\n\n> 待核对引用\n\n1. 跟进\n2. 确认"
        let blocks = MinutesMarkdownBlock.parse(source)
        XCTAssertEqual(blocks.count, 7)
        XCTAssertEqual(blocks.map { String($0.text.characters) },
            ["会议标题", "概述", "要点内容", "第二条", "待核对引用", "跟进", "确认"])
        XCTAssertEqual(blocks[0].headingLevel, 1)
        XCTAssertEqual(blocks[1].headingLevel, 2)
        XCTAssertEqual(blocks[2].marker, "•")
        XCTAssertEqual(blocks[5].marker, "1.")
        XCTAssertEqual(blocks[6].marker, "2.")
        XCTAssertTrue(blocks[4].isQuote)
        XCTAssertTrue(blocks[2].text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertEqual(Set(blocks.map(\.id)).count, blocks.count)
    }

    @MainActor
    func testRenderedMinutesFitANarrowOffscreenContainer() {
        let markdown = "# 会议纪要\n\n## 待办\n\n- " + String(repeating: "窄窗口长内容应自然换行。", count: 30) + "\n\n> 引用说明。"
        let view = NSHostingView(rootView: MinutesMarkdownView(markdown).frame(width: 280))
        let size = view.fittingSize
        XCTAssertEqual(size.width, 280, accuracy: 1)
        XCTAssertTrue(size.height.isFinite)
        XCTAssertGreaterThan(size.height, 300)
    }

    func testNestedListsCodeAndLiteralCharactersPreserveContent() {
        let blocks = MinutesMarkdownBlock.parse("- 父项\n  1. 子项\n\n```sql\nSELECT * FROM t;\n```\n\n普通文本 #号与 100% 原样保留。")
        XCTAssertEqual(blocks[1].listDepth, 1)
        XCTAssertEqual(blocks[1].marker, "1.")
        XCTAssertTrue(blocks[2].isCode)
        XCTAssertTrue(String(blocks[2].text.characters).contains("SELECT * FROM t;"))
        XCTAssertEqual(String(blocks.last!.text.characters), "普通文本 #号与 100% 原样保留。")
    }
}
