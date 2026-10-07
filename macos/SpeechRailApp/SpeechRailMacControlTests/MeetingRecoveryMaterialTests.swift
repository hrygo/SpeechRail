import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 空 final 的恢复材料（MA-02 / MC-11）。
///
/// 三条都要成立，缺一条就等于"无声消失"：
/// **存得下来、取得回来、不进正式纪要**。
@MainActor
final class MeetingRecoveryMaterialTests: XCTestCase {
    private var directory: URL?
    private var store: SessionStore?

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        try await store.open()
        self.directory = directory
        self.store = store
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        store = nil
        directory = nil
        try await super.tearDown()
    }

    private func seedSession() async throws -> String {
        let store = try XCTUnwrap(store)
        let record = try await store.createSession(
            SessionDraft(kind: .meeting, engineProfile: "test", audioSource: .microphone)
        )
        return record.id
    }

    private func append(
        _ text: String,
        status: SessionLineStatus,
        sessionID: String
    ) async throws -> Int {
        let store = try XCTUnwrap(store)
        return try await store.appendLine(
            LineDraft(
                sessionID: sessionID,
                role: .speaker,
                text: text,
                source: .microphone,
                tStart: 1,
                tEnd: 2,
                status: status,
                timingQuality: .unavailable
            ),
            id: UUID().uuidString
        )
    }

    func testRecoveryMaterialIsRetrievableByDefault() async throws {
        let store = try XCTUnwrap(store)
        let sessionID = try await seedSession()
        try await append("已经显示过的半句", status: .partial, sessionID: sessionID)
        // 默认读回（记录库、导出、纪要的口径）**不包含**它。
        let final = try await store.lines(sessionID: sessionID)
        XCTAssertTrue(final.isEmpty)
    }

    func testRecoveryMaterialIsRetrievableWhenAskedFor() async throws {
        let store = try XCTUnwrap(store)
        let sessionID = try await seedSession()
        try await append("已经显示过的半句", status: .partial, sessionID: sessionID)
        let all = try await store.lines(sessionID: sessionID, includePartial: true)
        let recovered = try XCTUnwrap(all.first { $0.status == .partial })
        XCTAssertEqual(recovered.text, "已经显示过的半句")
    }

    /// 纪要不收恢复材料，靠的是**纪要读库时用的就是默认口径**
    /// （`MinutesGenerator` 三处都调 `coordinator.lines(sessionID:)`，
    /// 签名默认 `includePartial: false`）。
    ///
    /// `MinutesGenerator` 是 App-only 文件、不在 SPM 目标内，所以这里断言的是
    /// 它依赖的那条库层契约；调用点本身是**代码审查确认**的，不是本测试证明的。
    func testDefaultReadIsTheContractMinutesReliesOn() async throws {
        let store = try XCTUnwrap(store)
        let sessionID = try await seedSession()
        try await append("定稿的那句", status: .final, sessionID: sessionID)
        try await append("只有半句的那句", status: .partial, sessionID: sessionID)

        let finalLines = try await store.lines(sessionID: sessionID)
        XCTAssertEqual(finalLines.map(\.text), ["定稿的那句"])
    }

    func testCoordinatorDefaultReadAlsoExcludesRecoveryMaterial() async throws {
        let store = try XCTUnwrap(store)
        let sessionID = try await seedSession()
        try await append("半句", status: .partial, sessionID: sessionID)
        // 协调器是纪要的取数入口，它的默认值必须与 store 一致。
        let coordinator = SessionCoordinator(store: store, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let viaCoordinator = try await coordinator.lines(sessionID: sessionID)
        XCTAssertTrue(viaCoordinator.isEmpty)
    }

    func testRecoveryMaterialSurvivesReopen() async throws {
        let store = try XCTUnwrap(store)
        let sessionID = try await seedSession()
        try await append("重启也要还在", status: .partial, sessionID: sessionID)
        try await store.close()
        try await store.open()
        let all = try await store.lines(sessionID: sessionID, includePartial: true)
        XCTAssertTrue(all.contains { $0.text == "重启也要还在" })
    }

    func testRecoveryMaterialKeepsItsOwnOrdinalAmongFinals() async throws {
        let store = try XCTUnwrap(store)
        let sessionID = try await seedSession()
        let a = try await append("第一句", status: .final, sessionID: sessionID)
        let b = try await append("只剩半句", status: .partial, sessionID: sessionID)
        let c = try await append("第三句", status: .final, sessionID: sessionID)
        // 序号单调，中间不留洞——否则引用会指错行。
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(b, c)
    }

    func testRecoveryMaterialIsMarkedAsUntimedRatherThanSpoken() async throws {
        let store = try XCTUnwrap(store)
        let sessionID = try await seedSession()
        try await append("半句", status: .partial, sessionID: sessionID)
        let all = try await store.lines(sessionID: sessionID, includePartial: true)
        let recovered = try XCTUnwrap(all.first)
        // 恢复材料同样不许把记录时刻说成说话时刻。
        XCTAssertEqual(recovered.timingQuality, .unavailable)
    }
}

@MainActor
final class SpeakerLabelingPersistenceTests: XCTestCase {
    private var directory: URL!
    private var store: SessionStore!
    private var coordinator: SessionCoordinator!
    private var defaults: UserDefaults!
    private var defaultsName: String!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speaker-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SessionStore(directory: directory)
        try await store.open()
        defaultsName = "speaker-persistence-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
        coordinator = SessionCoordinator(store: store, defaults: defaults)
    }

    override func tearDown() async throws {
        await store.close()
        defaults.removePersistentDomain(forName: defaultsName)
        try FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func record(with ids: [String]) async throws -> String {
        let record = try await store.createSession(
            SessionDraft(kind: .meeting, engineProfile: "test", audioSource: .microphone)
        )
        for id in ids {
            _ = try await store.appendLine(
                LineDraft(sessionID: record.id, role: .speaker, text: id, source: .microphone), id: id
            )
        }
        return record.id
    }

    private func waitUntilEntered(_ gate: SpeakerAttributionWriteGate) async throws {
        for _ in 0..<1_000 {
            if await gate.entered { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("speaker write never entered the gate")
        await gate.release()
    }

    func testWholeBatchKeepsOldTargetsAcrossNewSessionDuringWrite() async throws {
        let old = try await record(with: ["old-one", "old-two"])
        let new = try await record(with: ["new-two"])
        let gate = SpeakerAttributionWriteGate(store: store)
        let owner = SpeakerLabeling(coordinator: coordinator, attachLabel: { try await gate.write($0, label: $1) })
        owner.begin(sessionID: old, enabled: true)
        let units: [RealtimeASRClient.AttributionUnit] = [
            .init(segmentUID: "one", speaker: "A"), .init(segmentUID: "two", speaker: "B")
        ]
        owner.register(units: [units[0]], lineID: "old-one", ordinal: 1)
        owner.register(units: [units[1]], lineID: "old-two", ordinal: 2)
        let task = Task { await owner.apply(units: units) }
        try await waitUntilEntered(gate)
        owner.begin(sessionID: new, enabled: true)
        owner.register(units: [.init(segmentUID: "two", speaker: nil)], lineID: "new-two", ordinal: 1)
        await gate.release()
        await task.value
        let oldRows = try await store.lines(sessionID: old)
        let newRows = try await store.lines(sessionID: new)
        XCTAssertEqual(oldRows.map(\.speakerLabel), ["A", "B"])
        XCTAssertNil(newRows.first?.speakerLabel)
        XCTAssertTrue(owner.labels.isEmpty, "old completions must not populate new-session labels")
    }

    func testHistoryLoadInvalidatesLateLiveProjection() async throws {
        let old = try await record(with: ["old"])
        let new = try await record(with: ["history"])
        let gate = SpeakerAttributionWriteGate(store: store)
        let owner = SpeakerLabeling(coordinator: coordinator, attachLabel: { try await gate.write($0, label: $1) })
        owner.begin(sessionID: old, enabled: true)
        let units: [RealtimeASRClient.AttributionUnit] = [.init(segmentUID: "unit", speaker: "A")]
        owner.register(units: units, lineID: "old", ordinal: 1)
        let task = Task { await owner.apply(units: units) }
        try await waitUntilEntered(gate)
        owner.load(sessionID: new, labels: ["C"], displayNames: ["C": "历史说话人"])
        await gate.release()
        await task.value
        XCTAssertEqual(owner.labels, ["C"])
        XCTAssertNil(owner.attributedLabel(forLineID: "old"))
        let rows = try await store.lines(sessionID: old)
        XCTAssertEqual(rows.first?.speakerLabel, "A", "accepted old work still writes its frozen target")
    }

    func testRebindingUnitDoesNotReusePriorLinesPersistenceProof() async throws {
        let id = try await record(with: ["one", "two"])
        let owner = SpeakerLabeling(coordinator: coordinator)
        owner.begin(sessionID: id, enabled: true)
        let units: [RealtimeASRClient.AttributionUnit] = [.init(segmentUID: "unit", speaker: "A")]
        owner.register(units: units, lineID: "one", ordinal: 1)
        await owner.apply(units: units)
        owner.register(units: units, lineID: "two", ordinal: 2)
        await owner.apply(units: units)
        let rows = try await store.lines(sessionID: id)
        XCTAssertEqual(rows.map(\.speakerLabel), ["A", "A"])
    }

    func testRebindingDuringWriteDoesNotMarkNewLineAsAlreadyPersisted() async throws {
        let id = try await record(with: ["one", "two"])
        let gate = SpeakerAttributionWriteGate(store: store)
        let owner = SpeakerLabeling(coordinator: coordinator, attachLabel: { try await gate.write($0, label: $1) })
        owner.begin(sessionID: id, enabled: true)
        let units: [RealtimeASRClient.AttributionUnit] = [.init(segmentUID: "unit", speaker: "A")]
        owner.register(units: units, lineID: "one", ordinal: 1)
        let task = Task { await owner.apply(units: units) }
        try await waitUntilEntered(gate)
        owner.register(units: units, lineID: "two", ordinal: 2)
        await gate.release()
        await task.value
        await owner.apply(units: units)
        let rows = try await store.lines(sessionID: id)
        XCTAssertEqual(rows.map(\.speakerLabel), ["A", "A"])
    }

    func testQueuedCommandKeepsItsTargetAcrossSameRecordGenerationReset() async throws {
        let id = try await record(with: ["old-generation", "new-generation"])
        let owner = SpeakerLabeling(coordinator: coordinator)
        owner.begin(sessionID: id, enabled: true)
        let units: [RealtimeASRClient.AttributionUnit] = [.init(segmentUID: "unit", speaker: "A")]
        owner.register(units: units, lineID: "old-generation", ordinal: 1)
        let command = owner.freezeAttribution(units: units)
        owner.begin(sessionID: id, enabled: true)
        owner.register(
            units: [.init(segmentUID: "unit", speaker: nil)], lineID: "new-generation", ordinal: 2
        )
        await owner.apply(command)
        let rows = try await store.lines(sessionID: id)
        XCTAssertEqual(rows.map(\.speakerLabel), ["A", nil])
        XCTAssertTrue(owner.labels.isEmpty)
        XCTAssertNil(owner.attributedLabel(forLineID: "new-generation"))
    }

    func testQueuedNilRevisionClearsPriorWriteInsteadOfBeingDiscardedAtAcceptance() async throws {
        let id = try await record(with: ["line"])
        let gate = SpeakerAttributionWriteGate(store: store)
        let owner = SpeakerLabeling(coordinator: coordinator, attachLabel: { try await gate.write($0, label: $1) })
        owner.begin(sessionID: id, enabled: true)
        let units: [RealtimeASRClient.AttributionUnit] = [.init(segmentUID: "unit", speaker: "A")]
        owner.register(units: units, lineID: "line", ordinal: 1)
        let first = Task { await owner.apply(units: units) }
        try await waitUntilEntered(gate)
        let clear = owner.freezeAttribution(units: [.init(segmentUID: "unit", speaker: nil)])
        await gate.release()
        await first.value
        await owner.apply(clear)
        let rows = try await store.lines(sessionID: id)
        XCTAssertNil(rows.first?.speakerLabel)
        XCTAssertNil(owner.attributedLabel(forLineID: "line"))
    }
}

actor SpeakerAttributionWriteGate {
    private var store: SessionStore?
    private var continuation: CheckedContinuation<Void, Never>?
    private var blocked = true
    private(set) var entered = false

    init(store: SessionStore? = nil) { self.store = store }

    func attach(_ store: SessionStore) { self.store = store }

    func write(_ lineID: String, label: String?) async throws {
        if blocked {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        guard let store else { throw TranscriptPersistenceGate.Failure.unavailable }
        try await store.attachSpeakerLabel(lineID: lineID, label: label)
    }

    func release() {
        blocked = false
        continuation?.resume()
        continuation = nil
    }
}

/// 真实 Store 边界前的确定性 Gate；不接设备或网络。
actor TranscriptPersistenceGate {
    enum Failure: Error { case unavailable }
    private var store: SessionStore?
    private var continuation: CheckedContinuation<Void, Never>?
    private var blocked = true
    private var failing = false
    private(set) var entered = false
    private(set) var attempts: [(draft: LineDraft, id: String)] = []

    func attach(_ store: SessionStore) { self.store = store }

    func save(_ draft: LineDraft, id: String) async throws -> Int {
        attempts.append((draft, id))
        if blocked {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        if failing { throw Failure.unavailable }
        guard let store else { throw Failure.unavailable }
        return try await store.appendLine(draft, id: id)
    }

    func release(failing: Bool = false) {
        blocked = false
        self.failing = failing
        continuation?.resume()
        continuation = nil
    }
}

/// 只替换网络 transport；解析、终态去重和结束协议使用生产客户端。
struct TranscriptRealtimeTestClient: MeetingRealtimeClient, CaptionRealtimeClient {
    let client: RealtimeASRClient
    let transport: TranscriptRealtimeTestTransport

    func events() async -> RealtimeEventStream<RealtimeASRClient.Event> { await client.events() }
    func connect() async throws { try await client.connect(using: transport) }
    func append(_ pcm: Data) async throws { try await client.append(pcm) }
    func flushPendingUtterance() async throws { try await client.flushPendingUtterance() }
    func drainAndClear(timeout: Duration) async throws { try await client.drainAndClear(timeout: timeout) }
    func close() async { await client.close() }
}

actor TranscriptRealtimeTestTransport: RealtimeASRTransport {
    private enum Failure: Error { case closed }
    private var frames: [RealtimeASRSocketFrame] = []
    private var receiver: CheckedContinuation<RealtimeASRSocketFrame, Error>?
    private var sequence = 0
    private var closed = false

    func resume() async {}
    func closeCode() async -> Int? { nil }

    func send(_ text: String) async throws {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
        switch object["type"] as? String {
        case "session.update":
            let session = object["session"] as? [String: Any] ?? [:]
            let speechrail = session["speechrail"] as? [String: Any] ?? [:]
            var policy = speechrail["asr"] as? [String: Any] ?? [:]
            policy["effective_max_segment_ms"] = policy["max_segment_ms"]
            policy["final_deadline_ms"] = policy["final_deadline_ms"] ?? 120_000
            try deliver(["type": "session.updated", "session": ["speechrail": ["asr": policy]]])
        case "input_audio_buffer.commit":
            try deliver([
                "type": "speechrail.input_audio_buffer.committed",
                "commit_event_id": object["event_id"] ?? "",
                "accepted_samples": 0
            ])
        default: break
        }
    }

    func completed(itemID: String, text: String) throws {
        try deliver([
            "type": "conversation.item.input_audio_transcription.completed",
            "item_id": itemID, "transcript": text
        ])
    }

    func control(_ message: String) throws {
        try deliver(["type": "error", "error": ["code": "test_control", "message": message]])
    }

    private func deliver(_ object: [String: Any]) throws {
        var stamped = object
        stamped["event_id"] = "persistence-event-\(sequence)"
        stamped["session_id"] = "persistence-test-session"
        stamped["sequence"] = sequence
        sequence += 1
        let data = try JSONSerialization.data(withJSONObject: stamped)
        let frame = RealtimeASRSocketFrame.text(String(decoding: data, as: UTF8.self))
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: frame)
        } else {
            frames.append(frame)
        }
    }

    func receive() async throws -> RealtimeASRSocketFrame {
        if !frames.isEmpty { return frames.removeFirst() }
        if closed { throw Failure.closed }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }

    func cancel() async {
        closed = true
        receiver?.resume(throwing: Failure.closed)
        receiver = nil
    }
}
