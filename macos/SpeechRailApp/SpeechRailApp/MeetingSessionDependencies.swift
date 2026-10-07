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

    /// 落库的 `session.audio_source`：它描述"这一次选的采集来源"（§6.3 ③ 的注解）。
    public var resolvedSource: SessionAudioSource {
        switch (usesMicrophone, systemApps.isEmpty) {
        case (true, true): .microphone
        case (false, false): .system
        default: .mixed
        }
    }

    /// 界面上那句话（`麦克风` / `腾讯会议` / `麦克风 + 2 个 App`）。
    ///
    /// 与 `AudioSourceCoordinator.Selection.label` 逐字一致——两边各写一份的话，
    /// 改了一边就会让同一场会来源摘要出现两种说法。
    public var label: String {
        var parts: [String] = []
        if usesMicrophone { parts.append("麦克风") }
        if systemApps.count == 1, let app = systemApps.first {
            parts.append(app.name)
        } else if systemApps.count > 1 {
            parts.append("\(systemApps.count) 个 App")
        }
        return parts.isEmpty ? "没有来源" : parts.joined(separator: " + ")
    }
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
    /// 把缓冲区里**在途的那一句**结算成独立 item。
    ///
    /// 与 `drainAndClear` 的分工必须说清：那个是**收尾**——顺带结束分人、清空缓冲、
    /// 同一连接上并发调用直接抛错，连接随后不可再用。这个只切一刀，不清也不收，
    /// 用来在暂停/继续之间划边界（MC-16）：服务端静音判定（`server_vad` 900ms）之前
    /// 按下的暂停，等不到静音边界，前后的两段会被并成同一句。切完这一刀，
    /// 之后 append 的音频自然落进新 buffer，不会和暂停前那句黏在一起。
    func flushPendingUtterance() async throws
    func drainAndClear(timeout: Duration) async throws
    func close() async
}

extension RealtimeASRClient: MeetingRealtimeClient {}

/// 建一条连接需要的参数。测试只看得出"建了几条、参数是什么"，
/// 不需要真的握手。
public struct MeetingRealtimeClientConfiguration: Sendable, Equatable {
    public var port: Int
    public var scenePreset: ASRScenePreset
    public var apiKey: String?
    public var diarizationEnabled: Bool
    public var expectedASRRevision: String?

    public init(
        port: Int,
        scenePreset: ASRScenePreset = .meeting,
        apiKey: String?,
        diarizationEnabled: Bool,
        expectedASRRevision: String?
    ) {
        self.port = port
        self.scenePreset = scenePreset
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
    /// 睡眠通知源。
    ///
    /// **刻意不给默认值**：一个"什么都不做"的默认实现会让生产漏配时静默失效，
    /// 而睡眠中断恰好属于"不接就看不出缺了"的那种行为——真合盖才发现没记中断，
    /// 那一段的音频已经白丢了。所以生产必须显式给出真的那个。
    public var powerMonitor: any MeetingPowerMonitor
    public var persistenceConfiguration: TranscriptPersistenceQueue.Configuration
    public var saveLine: (@Sendable (LineDraft, String) async throws -> Int)?
    public var attachSpeakerLabel: (@Sendable (String, String?) async throws -> Void)?
    public var drainTimeout: Duration

    public init(
        makeAudioSource: @escaping @MainActor () -> any MeetingAudioSource,
        makeRealtimeClient: @escaping @Sendable (MeetingRealtimeClientConfiguration) -> any MeetingRealtimeClient,
        clock: any MeetingClock = SystemMeetingClock(),
        powerMonitor: any MeetingPowerMonitor,
        persistenceConfiguration: TranscriptPersistenceQueue.Configuration = .init(),
        saveLine: (@Sendable (LineDraft, String) async throws -> Int)? = nil,
        attachSpeakerLabel: (@Sendable (String, String?) async throws -> Void)? = nil,
        drainTimeout: Duration = .seconds(12)
    ) {
        self.makeAudioSource = makeAudioSource
        self.makeRealtimeClient = makeRealtimeClient
        self.clock = clock
        self.powerMonitor = powerMonitor
        self.persistenceConfiguration = persistenceConfiguration
        self.saveLine = saveLine
        self.attachSpeakerLabel = attachSpeakerLabel
        self.drainTimeout = drainTimeout
    }

}

/// 系统睡眠/合盖通知。生产实现读 `NSWorkspace`（AppKit），留在 App-only 文件里。
///
/// 这条接缝存在的理由是让 `MeetingSession` 进单测目标（AppKit 进不了 SPM）。
/// 换来的是"Mac 睡过要记中断、醒来不自动续、麦克风与 tap 都要重拿"这条
/// **可被构造**：以前只能靠真合盖验一次，现在测试里能触发睡眠并断言后果。
@MainActor
public protocol MeetingPowerMonitor: AnyObject, Sendable {
    /// 注册一次睡眠回调；返回的令牌只用来判断"已经注册过了"。
    /// 回调在主 actor 上跑。
    func startObservingSleep(_ onSleep: @escaping @MainActor () -> Void) -> AnyObject
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
