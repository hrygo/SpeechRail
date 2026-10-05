import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 会议编排层的接缝（方案 MA-01 / MC-05～MC-08）。
///
/// 这里钉的是**晚到的东西不许写进已经换了一代的状态**：
/// 中断、结束、重连都可能让一次 `await` 之前还算数的东西作废。
/// 靠 sleep 碰运气抓不到这种竞态，所以代次必须是可数的、可验的。
final class MeetingSessionDependenciesTests: XCTestCase {
    // MARK: - 代次守卫

    func testFirstGenerationIsCurrentUntilSomethingBegins() {
        let generation = MeetingConnectionGeneration()
        XCTAssertTrue(generation.isCurrent(0))
        XCTAssertEqual(generation.current, 0)
    }

    func testBeginIssuesAFreshToken() {
        var generation = MeetingConnectionGeneration()
        let token = generation.begin()
        XCTAssertTrue(generation.isCurrent(token))
        XCTAssertNotEqual(token, 0)
    }

    func testSecondBeginRetiresThePreviousToken() {
        var generation = MeetingConnectionGeneration()
        let first = generation.begin()
        let second = generation.begin()
        XCTAssertFalse(generation.isCurrent(first))
        XCTAssertTrue(generation.isCurrent(second))
    }

    func testInvalidateKillsInFlightWork() {
        var generation = MeetingConnectionGeneration()
        let token = generation.begin()
        generation.invalidate()
        XCTAssertFalse(generation.isCurrent(token))
    }

    func testRetiredTokenNeverBecomesCurrentAgain() {
        var generation = MeetingConnectionGeneration()
        let first = generation.begin()
        generation.invalidate()
        // 再连一次：旧票必须仍然是旧的，不能"轮回来了"。
        let second = generation.begin()
        XCTAssertFalse(generation.isCurrent(first))
        XCTAssertTrue(generation.isCurrent(second))
        generation.invalidate()
        XCTAssertFalse(generation.isCurrent(first))
        XCTAssertFalse(generation.isCurrent(second))
    }

    func testTwoReconnectsDoNotResurrectTheFirstConnection() {
        // MC-07：两次重连。第一次的票在第三次接管后仍然是旧的。
        var generation = MeetingConnectionGeneration()
        let epoch1 = generation.begin()
        generation.invalidate()
        let epoch2 = generation.begin()
        generation.invalidate()
        let epoch3 = generation.begin()
        XCTAssertFalse(generation.isCurrent(epoch1))
        XCTAssertFalse(generation.isCurrent(epoch2))
        XCTAssertTrue(generation.isCurrent(epoch3))
    }

    func testInterruptionAndReconnectAdvanceTheSameWay() {
        var generation = MeetingConnectionGeneration()
        let beforeInterruption = generation.begin()
        generation.invalidate()
        let afterReconnect = generation.begin()
        XCTAssertFalse(generation.isCurrent(beforeInterruption))
        XCTAssertTrue(generation.isCurrent(afterReconnect))
    }

    // MARK: - 来源选择的协议边界

    func testEmptySelectionIsEmptyOnTheWire() {
        let selection = MeetingAudioSelection(usesMicrophone: false, systemApps: [])
        XCTAssertTrue(selection.isEmpty)
    }

    func testMicrophoneOnlyIsNotEmpty() {
        let selection = MeetingAudioSelection(usesMicrophone: true, systemApps: [])
        XCTAssertFalse(selection.isEmpty)
    }

    func testSystemAudioOnlyIsNotEmpty() {
        let selection = MeetingAudioSelection(
            usesMicrophone: false,
            systemApps: [MeetingAudioApp(bundleID: "com.example.editor", name: "Editor")]
        )
        XCTAssertFalse(selection.isEmpty)
    }

    func testSelectionCarriesBundleIDAndNameForEveryApp() {
        let selection = MeetingAudioSelection(
            usesMicrophone: true,
            systemApps: [
                MeetingAudioApp(bundleID: "com.example.a", name: "A"),
                MeetingAudioApp(bundleID: "com.example.b", name: "B"),
            ]
        )
        XCTAssertEqual(selection.systemApps.map(\.bundleID), ["com.example.a", "com.example.b"])
        XCTAssertEqual(selection.systemApps.map(\.name), ["A", "B"])
    }

    // MARK: - 建连参数

    func testConnectionConfigurationCarriesWhatTheClientNeeds() {
        let configuration = MeetingRealtimeClientConfiguration(
            port: 8300,
            apiKey: nil,
            diarizationEnabled: true,
            expectedASRRevision: "speechrail/qwen3-asr-1.7b"
        )
        XCTAssertEqual(configuration.port, 8300)
        XCTAssertNil(configuration.apiKey)
        XCTAssertTrue(configuration.diarizationEnabled)
        XCTAssertEqual(configuration.expectedASRRevision, "speechrail/qwen3-asr-1.7b")
    }

    func testConnectionConfigurationEquatesSoTestsCanCountAttempts() {
        let a = MeetingRealtimeClientConfiguration(
            port: 8201, apiKey: nil, diarizationEnabled: false, expectedASRRevision: nil
        )
        let b = MeetingRealtimeClientConfiguration(
            port: 8201, apiKey: nil, diarizationEnabled: false, expectedASRRevision: nil
        )
        XCTAssertEqual(a, b)
    }

    // MARK: - 时钟

    func testInjectedClockIsTheOnlySourceOfNow() {
        // 时钟可换是"时间证据可测"的前提：真时钟测不出取时刻的次数与顺序。
        let counter = CallCounter()
        let dependencies = MeetingSessionDependencies(
            makeAudioSource: { MeetingAudioSourceForTests() },
            makeRealtimeClient: { _ in MeetingRealtimeClientForTests() },
            clock: FixedClock(counter: counter)
        )
        let first = dependencies.clock.now()
        let second = dependencies.clock.now()
        XCTAssertEqual(first, second)
        XCTAssertEqual(counter.value, 2)
    }
}

// MARK: - 假实现

/// 可数的时钟调用次数。`Sendable` 类不能有可变存储，所以计数放在这里。
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
    func bump() {
        lock.lock(); count += 1; lock.unlock()
    }
}

struct FixedClock: MeetingClock {
    let counter: CallCounter
    func now() -> Date {
        counter.bump()
        return Date(timeIntervalSince1970: 1_700_000_000)
    }
}

/// 不碰设备的采集通道。
@MainActor
final class MeetingAudioSourceForTests: MeetingAudioSource {
    private(set) var gapCount = 0
    private(set) var resolvedSource: SessionAudioSource = .microphone
    var onSystemAudioLost: (@MainActor (String) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var muted = false

    func start(selection: MeetingAudioSelection) async throws -> AsyncStream<AudioChunk> {
        startCount += 1
        resolvedSource = selection.usesMicrophone ? .microphone : .system
        return AsyncStream { $0.finish() }
    }

    func stop() async { stopCount += 1 }
    func setMicrophoneMuted(_ muted: Bool) { self.muted = muted }
    func restartSystemAudio() async -> Bool { true }
}

/// 不握手、不连 loopback 的 Realtime 连接。
actor MeetingRealtimeClientForTests: MeetingRealtimeClient {
    private(set) var connectCount = 0
    private(set) var closeCount = 0
    private(set) var appendedByteCount = 0
    /// 暂停边界切了几刀（MC-16）。"暂停前后不拼句"就是靠这个数断言的：
    /// 暂停一次必须恰好切一刀，多了是重复结算，少了就是前后黏成一句。
    private(set) var flushCount = 0

    func events() async -> RealtimeEventStream<RealtimeASRClient.Event> {
        RealtimeEventStream<RealtimeASRClient.Event>(limits: .init(maxBufferedEvents: 1))
    }

    func connect() async throws { connectCount += 1 }
    func append(_ pcm: Data) async throws { appendedByteCount += pcm.count }
    func flushPendingUtterance() async throws { flushCount += 1 }
    func drainAndClear(timeout: Duration) async throws {}
    func close() async { closeCount += 1 }
}
