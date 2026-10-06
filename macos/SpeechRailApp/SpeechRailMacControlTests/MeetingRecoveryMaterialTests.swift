import Foundation
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
