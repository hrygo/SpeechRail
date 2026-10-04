import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 会议纪要版本指针回归（方案 MA-06 / 场景 MC-25、MC-26、MC-48）。
/// 这里钉的是库这一层的约束，不碰界面：
/// - 排队新版本是原子动作：INSERT 失败不能留下“旧版已被清掉指针”的半提交；
/// - 最新尝试失败后，最新可用版仍可查；查询不到已完成版本时也不伪造成功；
/// - 展示、搜索与导出只认调用方选定的版本，不把“版本号最大”等同于“用户采用版”。
@MainActor
final class MeetingMinutesVersioningTests: XCTestCase {
    private var directory: URL?
    private var store: SessionStore?
    private var sessionID: String?

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-minutes-versioning-\(UUID().uuidString)", isDirectory: true)
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

    /// MC-26：新候选 INSERT 失败时，旧版的最新指针保持不变。
    func testEnqueueFailureKeepsPreviousLatestPointer() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let first = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        try await store.finishMinutes(minutesID: first.id, body: "# 采用版", model: nil)

        do {
            _ = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 9, id: first.id)
            XCTFail("重复 id 的排队必须失败")
        } catch {
            // 预期失败：旧版指针必须保持。
        }

        let versions = try await store.minutesVersions(sessionID: sessionID)
        XCTAssertEqual(versions.count, 1, "失败的排队不能新增版本行")
        XCTAssertEqual(versions.first?.id, first.id)
        XCTAssertTrue(versions.first?.isLatest ?? false, "旧版的最新指针不能被失败的排队清掉")
    }

    /// MC-25：一版可用之后再来一版失败，最新可用版仍是上一版。
    func testLatestUsableStaysAfterFailedAttempt() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let first = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        try await store.finishMinutes(minutesID: first.id, body: "# 采用版", model: nil)
        let failed = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 9)
        try await store.failMinutes(minutesID: failed.id, reason: "模型没有给结果")

        let versions = try await store.minutesVersions(sessionID: sessionID)
        XCTAssertEqual(versions.count, 2)
        let usable = versions.filter { $0.status == .ready }
        XCTAssertEqual(usable.count, 1)
        XCTAssertEqual(usable.first?.id, first.id, "失败尝试不能取代已完成版本")
    }

    /// MC-25：Store 直接给出最新可用版；没有可用版时返回 nil，不伪造成功。
    func testLatestUsableMinutesReturnsNewestReady() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let empty = try await store.latestUsableMinutes(sessionID: sessionID)
        XCTAssertNil(empty)
        let first = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        try await store.finishMinutes(minutesID: first.id, body: "# 采用版", model: nil)
        let failed = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 9)
        try await store.failMinutes(minutesID: failed.id, reason: "模型没有给结果")
        let usable = try await store.latestUsableMinutes(sessionID: sessionID)
        XCTAssertEqual(usable?.id, first.id)
        XCTAssertEqual(usable?.body, "# 采用版")
    }

    /// MC-48：选定版本导出只认调用方传入的版本，不认“最新/最大版本”。
    func testSelectedVersionIsReturnedAsSelected() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let first = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        try await store.finishMinutes(minutesID: first.id, body: "# 第一版", model: nil)
        let second = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 9)
        try await store.finishMinutes(minutesID: second.id, body: "# 第二版", model: nil)

        let versions = try await store.minutesVersions(sessionID: sessionID)
        let selected = versions.first { $0.id == first.id }
        XCTAssertEqual(selected?.body, "# 第一版", "调用方选定旧版时必须原样返回旧版正文")
        XCTAssertEqual(selected?.version, 1)
    }
}
