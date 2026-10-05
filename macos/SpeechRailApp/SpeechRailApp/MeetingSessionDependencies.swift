import Foundation
import SpeechRailControlKit

// `MeetingSession` 的依赖边界（方案 MA-01）。
//
// 它是会议链上唯一"什么都认识"的地方：设备、WebSocket、时钟都从它穿过。
// 生产运行时接真实实现；测试要用**同一份** `MeetingSession` 把
// 启动 / 中断 / 结束跑完整，就必须在**这里**换成假实现，
// 而不是另写一份仿制的状态机——仿制品证明不了生产代码的竞态。
//
// 三条约束（与 `AssistantSessionDependencies` 一致）：
//
//   1. 协议只覆盖编排层**实际调用**的成员，不做"以后可能用到"的宽接口；
//   2. 生产默认值写在 `production` 里，composition root 不必改动，行为不变；
//   3. 假实现不碰设备、不连 loopback，只在测试内构造。

/// 一个系统声音来源。生产侧对应 `SystemAudioApp`，但这里只留编排层
/// 真正读的字段——同样的理由让 `MeetingSourcePresentation` 用纯值而不是
/// AppKit 类型：整条翻译层要能进 SPM 测试目标。
public struct MeetingAudioApp: Hashable, Sendable {
    public var bundleID: String
    public var name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// 这一场勾了哪些来源。**协议边界上的值类型**。
public struct MeetingAudioSelection: Hashable, Sendable {
    public var usesMicrophone: Bool
    public var systemApps: [MeetingAudioApp]

    public init(usesMicrophone: Bool = true, systemApps: [MeetingAudioApp] = []) {
        self.usesMicrophone = usesMicrophone
        self.systemApps = systemApps
    }

    public var isEmpty: Bool { !usesMicrophone && systemApps.isEmpty }
}

/// 会议采集通道。生产实现是 `AudioSourceCoordinator`。
///
/// 只列 `MeetingSession` 真正调用的成员：起停、麦克风静音、系统音频断线
/// 重连、补洞计数与本场实际来源。设备枚举与混音仍归 `AudioSourceCoordinator`。
///
/// 协议本身必须待在这个目标里，而 `AudioSourceCoordinator` 是 App-only 文件，
/// 所以 **conformance 放在 `MeetingSession.swift`**，不在这里。
@MainActor
public protocol MeetingAudioSource: AnyObject {
    var gapCount: Int { get }
    var resolvedSource: SessionAudioSource { get }
    var onSystemAudioLost: (@MainActor (String) -> Void)? { get set }
    func start(selection: MeetingAudioSelection) async throws -> AsyncStream<AudioChunk>
    func stop() async
    func setMicrophoneMuted(_ muted: Bool)
    func restartSystemAudio() async -> Bool
}

/// 一条会议 Realtime 连接。生产实现是 `RealtimeASRClient`（`actor`）。
///
/// 会议只用 ASR 子集，所以这里**不含**任何 TTS 成员——把 TTS 写进协议
/// 就是给会议链路凭空加一个它永远不会用的依赖。
public protocol MeetingRealtimeClient: Sendable {
    func events() async -> RealtimeEventStream<RealtimeASRClient.Event>
    func connect() async throws
    func append(_ pcm: Data) async throws
    func drainAndClear(timeout: Duration) async throws
    func close() async
}

extension RealtimeASRClient: MeetingRealtimeClient {}

/// 建一条连接需要的参数。测试只看得出"建了几条、参数是什么"，
/// 不需要真的握手。
public struct MeetingRealtimeClientConfiguration: Sendable, Equatable {
    public var port: Int
    public var apiKey: String?
    public var diarizationEnabled: Bool
    public var expectedASRRevision: String?

    public init(
        port: Int,
        apiKey: String?,
        diarizationEnabled: Bool,
        expectedASRRevision: String?
    ) {
        self.port = port
        self.apiKey = apiKey
        self.diarizationEnabled = diarizationEnabled
        self.expectedASRRevision = expectedASRRevision
    }
}

/// 时钟。生产实现取系统时间。
///
/// 抽出来不是为了"好看"，而是为了**时间证据可测**：转录行的
/// `tStart` / `tEnd` 依赖取时刻的次数与顺序，用真时钟测不出来。
public protocol MeetingClock: Sendable {
    func now() -> Date
}

/// 生产时钟。
public struct SystemMeetingClock: MeetingClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// `MeetingSession` 可以替换的外部依赖。默认值就是生产行为。
public struct MeetingSessionDependencies: Sendable {
    /// 建一条新的采集通道。每次 `startPipeline` 调一次。
    public var makeAudioSource: @MainActor () -> any MeetingAudioSource
    /// 建一条新的 Realtime 连接。每次 `startPipeline` 调一次，所以"每轮建连"
    /// 必须在测试里可数。
    public var makeRealtimeClient: @Sendable (MeetingRealtimeClientConfiguration) -> any MeetingRealtimeClient
    public var clock: any MeetingClock

    public init(
        makeAudioSource: @escaping @MainActor () -> any MeetingAudioSource,
        makeRealtimeClient: @escaping @Sendable (MeetingRealtimeClientConfiguration) -> any MeetingRealtimeClient,
        clock: any MeetingClock = SystemMeetingClock()
    ) {
        self.makeAudioSource = makeAudioSource
        self.makeRealtimeClient = makeRealtimeClient
        self.clock = clock
    }

}

/// 连接代次守卫（MA-01）。
///
/// 一次 `await` 回来之后，**这一行代码还属不属于当前这一代**，已经不是
/// 启动时能回答的问题了：中断、结束、重连都可能在这期间换掉状态。
/// 所以每条异步回调都带一枚启动时领的代次票，回来先验票再发布给 self。
///
/// 两条推进路径，缺一不可：
/// - `begin()`：新管线接管，旧票全部作废；
/// - `invalidate()`：连接被释放，在飞的东西同样作废。
///
/// 只推进不回收——旧票**永远不会**重新变成当前的。这正是"晚到的回调
/// 不许写进已经换了一代的状态"这句话的含义。
public struct MeetingConnectionGeneration: Hashable, Sendable {
    private var value: Int = 0

    public init() {}

    /// 新一代接管。返回的票要随泵任务与回调一路带走。
    public mutating func begin() -> Int {
        value += 1
        return value
    }

    /// 连接被释放：让所有在飞的回调立刻作废。
    public mutating func invalidate() {
        value += 1
    }

    /// 这枚票还成立吗？**发布到 self 之前**必须问一次。
    public func isCurrent(_ token: Int) -> Bool {
        value == token
    }

    /// 当前代次。仅供诊断与断言，不用于判断。
    public var current: Int { value }
}
