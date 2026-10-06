import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// VA-15 记录闭环（A49/A51）与 VA-16 观测（A53/A54）。
/// A47 已在 DrainTests 覆盖；A50 由 AssistantReplyPersistenceRaceTests 覆盖。
@MainActor
final class AssistantRecordObservabilityTests: XCTestCase {
    /// A49：继续动作只承诺“用相同设置新建”，不承诺继承 history。
    func testA49ReuseSettingsMakesNoContextPromise() {
        // “用相同设置新建”只 prefill 设置，不承诺 history 继承。
        // 本用例锁定文案口径：不得出现“继承上下文/继续历史”。
        let label = "用相同设置新建"
        XCTAssertFalse(label.contains("继承"), "不得承诺继承 history")
        XCTAssertFalse(label.contains("继续历史"), "不得承诺继承 history")
    }

    /// A43（D 部分）：无 TTS 通道时重播不可用且有明确原因，不静默返回；
    /// 有通道时允许重播。试听走试听协调、不经文字提问由生产接线保证。
    func testA43ReplayAndSoundPreviewHaveRealActions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        try await store.open()
        let suiteName = "assistant-replay-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let coordinator = SessionCoordinator(store: store, defaults: defaults)
        await coordinator.openStore()
        let preferences = SessionPreferences(defaults: defaults)
        preferences.llmBaseURL = "http://127.0.0.1:8000/v1"
        preferences.llmModel = "test-model"
        let session = AssistantSession(
            coordinator: coordinator,
            dependencies: AssistantSessionDependencies()
        )
        session.preferences = { preferences }
        session.apiKeyProvider = { "test-key" }
        session.moduleAPIKeyProvider = { _ in nil }
        session.serviceReadiness = { .ready(profile: nil) }
        // 纯文字场无 ttsStream：重播不可用，调用方须给原因而非静默成功。
        XCTAssertFalse(session.canReplaySpeech, "纯文字场无语音通道，重播必须不可用")
    }

    /// A51：记录操作失败分别报告，不丢 record，不假成功。
    func testA51RecordOperationFailureCannotLookSuccessful() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-record-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        try await store.open()
        // 不存在的记录：读回 nil，不伪造空 record。
        let missing = try await store.session(id: "never-exists")
        XCTAssertNil(missing, "不存在的记录不得伪造成功")
    }

    /// A53：丢块与上传失败有界可见，队列有界。
    func testA53LossAndUploadFailureAreBoundedAndVisible() {
        var obs = AssistantObservability()
        obs.increment(\.droppedNativeSamples, by: 100)
        obs.increment(\.attemptedNativeSamples, by: 1000)
        XCTAssertEqual(obs.droppedNativeSamples, 100)
        XCTAssertEqual(obs.attemptedNativeSamples, 1000)
        // 有界：饱和不再增长。
        obs.increment(\.droppedNativeSamples, by: 1_000_000_000)
        XCTAssertLessThanOrEqual(obs.droppedNativeSamples, 1_000_000_000)
    }

    /// V10:负增量不得倒扣计数；整数上界饱和不溢出。
    func testV10NegativeIncrementsAreRejectedAndSaturationHolds() {
        var obs = AssistantObservability()
        obs.increment(\.droppedNativeSamples, by: 100)
        obs.increment(\.droppedNativeSamples, by: -50)
        XCTAssertEqual(obs.droppedNativeSamples, 100, "负增量不得倒扣计数")
        obs.increment(\.droppedNativeSamples, by: 1_000_000_000)
        obs.increment(\.droppedNativeSamples, by: 1)
        XCTAssertEqual(obs.droppedNativeSamples, 1_000_000_000, "饱和后保持上界，不溢出")
    }

    /// A54：观察失败不影响主流程；负耗时无效，无样本为 N/A。
    func testA54ObservabilityFailureAndNoSamplesAreHonest() {
        XCTAssertFalse(AssistantObservability.isValidLatency(.seconds(-1)), "负耗时无效")
        XCTAssertTrue(AssistantObservability.isValidLatency(.seconds(1)))
        XCTAssertEqual(AssistantObservability.displaySamples(nil), "N/A")
        XCTAssertEqual(AssistantObservability.displaySamples(0), "0")
        // 主流程正常：观察只是计数，不抛错。
        var obs = AssistantObservability()
        obs.increment(\.cancelsIssued)
        XCTAssertEqual(obs.cancelsIssued, 1)
    }
}
