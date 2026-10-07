import Foundation
import Observation
import SpeechRailControlKit

public protocol CaptionRealtimeClient: Sendable {
    func events() async -> RealtimeEventStream<RealtimeASRClient.Event>
    func connect() async throws
    func append(_ pcm: Data) async throws
    func drainAndClear(timeout: Duration) async throws
    func close() async
}

extension RealtimeASRClient: CaptionRealtimeClient {}

public struct CaptionRealtimeClientConfiguration: Sendable, Equatable {
    public var port: Int
    public var scenePreset: ASRScenePreset
    public var diarizationEnabled: Bool
    public var apiKey: String?
    public var expectedASRRevision: String?

    public init(
        port: Int,
        scenePreset: ASRScenePreset = .caption,
        diarizationEnabled: Bool,
        apiKey: String?,
        expectedASRRevision: String?
    ) {
        self.port = port
        self.scenePreset = scenePreset
        self.diarizationEnabled = diarizationEnabled
        self.apiKey = apiKey
        self.expectedASRRevision = expectedASRRevision
    }
}

public struct CaptionSessionDependencies: Sendable {
    public var makeRealtimeClient:
        @Sendable (CaptionRealtimeClientConfiguration) -> any CaptionRealtimeClient
    public var persistenceConfiguration: TranscriptPersistenceQueue.Configuration
    public var saveLine: (@Sendable (LineDraft, String) async throws -> Int)?
    public var attachSpeakerLabel: (@Sendable (String, String?) async throws -> Void)?

    public init(
        makeRealtimeClient: @escaping @Sendable
            (CaptionRealtimeClientConfiguration) -> any CaptionRealtimeClient,
        persistenceConfiguration: TranscriptPersistenceQueue.Configuration = .init(),
        saveLine: (@Sendable (LineDraft, String) async throws -> Int)? = nil,
        attachSpeakerLabel: (@Sendable (String, String?) async throws -> Void)? = nil
    ) {
        self.makeRealtimeClient = makeRealtimeClient
        self.persistenceConfiguration = persistenceConfiguration
        self.saveLine = saveLine
        self.attachSpeakerLabel = attachSpeakerLabel
    }

    public static func production() -> Self {
        Self(makeRealtimeClient: { configuration in
            RealtimeASRClient(
                port: configuration.port,
                scenePreset: configuration.scenePreset,
                diarizationEnabled: configuration.diarizationEnabled,
                apiKey: configuration.apiKey,
                expectedASRRevision: configuration.expectedASRRevision
            )
        })
    }
}

// 实时字幕的会话层（`SESSIONS-SPEC` §6.3、`TECHNICAL-DESIGN` §5.7）。
//
// **它不认识 AppKit，也不认识窗口。** 浮层由 `CaptionBandWindowController` 负责；这里只说
// "现在该看得见 / 看不见"（`presentBand`）。于是这一层可以脱离界面单独跑——阶段 3 的验收
// 正是这么做的：用文件音频源驱动同一条链路，核对库里真的落了行与时间码。
//
// 三段职责，边界不能混：
//   ① 设备与连接的生命周期（用户裁决：**按功能启用、功能离开释放**）；
//   ② 内存里的 partial 与定稿；**定稿即落库**，库里不出现 `status='partial'` 的行；
//   ③ 受阻：几类原因共用同一条带子，**一律保留最后一句字幕**（可读、可复制）。
//
// 两条只在这里才说得清的取舍：
//
//   - **时间码是相对会话开始的墙钟秒**（§15 的 `t_start` 注释）。暂停与断线留下的空档
//     因此在导出物里是**看得见的跳变**，而不是被悄悄抹平——那正是 §16.7 要的证据。
//     不用"已录音频的秒数"当基准，因为那会把空档伪装成连续。
//   - **`timing_quality` 只在拿到对齐证据时才写**。它随 `speechrail.alignment.done`
//     独立到达，属于分人那一步；字幕不协商对齐时这一列保持 NULL，不假装有时间码。

@MainActor
@Observable
public final class CaptionSession {
    public enum Phase: String, Sendable, Equatable {
        case idle
        case preparing
        case running
        case paused
        /// 正在收尾（把最后半句交出去、等终态）。
        case ending

        public var isLive: Bool { self == .running || self == .paused }
    }

    /// 受阻的原因。共用同一条带子，各给一个出口（§6.3.1 / §16.3）。
    public enum BlockReason: Equatable, Sendable {
        case microphoneDenied
        case serviceNotReady(String)
        /// 服务可达，但流式 worker 被另一个实时会话占着（`backend_busy`）。
        case serviceBusy(String)
        /// 已经在跑另一个会话：麦克风同一时刻只能由一个会话使用（§6.4）。
        case occupiedBy(SessionKind)
        case storeUnavailable(String)
        /// 转写链路中途断了。正文保留，可以重新接上（新 epoch，不重放 PCM）。
        case streamFailed(String)

        public var title: String {
            switch self {
            case .microphoneDenied: "麦克风未授权，字幕带已暂停"
            case .serviceNotReady: "语音服务未就绪"
            case .serviceBusy: "语音服务正忙"
            case .occupiedBy(let kind): "\(kind.title)正在使用麦克风"
            case .storeUnavailable: "记录库不可用"
            case .streamFailed: "转写中断了"
            }
        }

        public var detail: String {
            switch self {
            case .microphoneDenied:
                "在系统设置里允许 SpeechRail 使用麦克风，然后回到这里重试。"
            case .serviceNotReady(let message):
                message
            case .serviceBusy(let message):
                message
            case .occupiedBy:
                "字幕带不会再开第二条会话。可以在会议的文字记录里看，或者结束会议并启动字幕。"
            case .storeUnavailable(let message):
                message
            case .streamFailed(let message):
                // 断开码要带给用户：`1008`（握手被拒）与「服务中途挂了」是两件事，
                // 只写"中断了"会让人没法判断该去检查 key 还是该去看服务。
                "\(message)丢掉的音频就是没录上；已经定稿的字幕都还在，可以重新接上往下听。"
            }
        }

        /// `重新接上` 只对流式中断有意义：其他几种要么还没开始过，要么是别的东西占着。
        public var canResume: Bool {
            if case .streamFailed = self { return true }
            return false
        }
    }

    /// 带子里的一行。**只有定稿才会出现在这里**；未定稿在 `partialText`。
    public struct Line: Identifiable, Sendable, Equatable {
        public var id: String
        public var ordinal: Int
        public var text: String
        public var start: TimeInterval?
        public var end: TimeInterval?
        /// 分人给的匿名标签（`A`…`D`）。未开分人时为 `nil`，行内就不出现 chip。
        public var speakerLabel: String?
    }

    public enum ServiceReadiness: Sendable {
        /// 服务可用，顺带带上当前档位（写进会话记录，服务读不到时给 `unknown`）。
        case ready(profile: String?)
        case notReady(String)
    }

    // MARK: 状态

    public private(set) var phase: Phase = .idle
    public private(set) var blocked: BlockReason?
    /// 本次会话已定稿的行（内存镜像；权威在库里，这里只给浮层与导出用）。
    public private(set) var lines: [Line] = []
    /// 未定稿的增量累加结果。`nil` 表示这一轮还没开始出字。
    public private(set) var partialText: String?
    /// 采集的真实电平 0…1（浮层页脚那几根柱子读它）。
    public private(set) var level: Double = 0
    public private(set) var sessionID: String?
    /// 浮层是否应该可见。界面层照着它显隐。
    public private(set) var isBandVisible = false
    /// 失败过的话这里是给人看的一句；原始错误码不外泄（§9 的脱敏口径）。
    public private(set) var lastFailure: String?

    #if DEBUG
    /// 离屏渲染工装（`/tmp` 里的 `NSHostingView`）用的**只写展示状态**夹具。
    ///
    /// 字幕带是浮层，真机验收要"解锁 + 麦克风 + 服务"三样同时在手；在此之前，版面
    /// （行、半句、页脚、受阻行）只能靠渲染真实视图来看。这个钩子沿用 App 里已有的
    /// `--ui-test` fixture 口径：只在 Debug 构建里存在，不碰存储、网络与设备，
    /// 也不改变任何产线行为。
    func applyRenderFixture(
        lines: [Line],
        partialText: String?,
        phase: Phase,
        blocked: BlockReason?
    ) {
        self.lines = lines
        self.partialText = partialText
        self.phase = phase
        self.blocked = blocked
    }
    #endif

    // MARK: 挂载点（由 App 注入）

    /// 浮层呈现口：`true` 出现、`false` 隐藏。会话层不认识窗口。
    public var presentBand: (@MainActor (Bool) -> Void)?
    /// `/readyz` 只作为诊断来源；Realtime capability binding 才决定能否启动。
    public var serviceReadiness: (@MainActor () async -> ServiceReadiness)?
    public var realtimeCapabilityBindingProvider:
        (@MainActor () async -> RealtimeCapabilityBinding?)?
    /// 音频来源。默认麦克风；核对时换成文件源，链路其余部分完全不变。
    public var audioSourceFactory: @MainActor () -> AudioChunkSource = { MicrophoneCapture() }
    /// 这一场要不要开分人。**每场一次**：契约规定只能在首个 PCM 之前协商。
    /// 默认关（§14.3 的开关粒度）。
    public var diarizationPreference: @MainActor () -> Bool = { false }

    private let coordinator: SessionCoordinator
    /// 分人归属账本。会议与字幕共用底座，这里持有的是本场那一个实例。
    public let labeling: SpeakerLabeling
    private let dependencies: CaptionSessionDependencies
    private let port: Int
    private let apiKey: String?

    private var source: AudioChunkSource?
    private var client: (any CaptionRealtimeClient)?
    private var pump: Task<Void, Never>?
    private var uploadPump: Task<Void, Never>?
    private var sessionStartedAt: Date?
    private var nextConnectionID = 0
    private var sessionGeneration = 0
    private var previewIdentity: TranscriptPreviewLedger.Identity?
    private var previewLedger = TranscriptPreviewLedger()
    /// 终态事件计数：收尾时用来判断"最后半句到底回来了没有"。
    private var terminalCount = 0
    private var isStoppingIntentionally = false
    private var currentOrdinal = 0
    /// `(connection, generation, itemID)` → 已落库的行，防止迟到辅助结果串写。
    private var lineByItem: [TranscriptPreviewLedger.ItemIdentity: (lineID: String, ordinal: Int)] = [:]
    private var pendingAttributions = TranscriptAttributionBuffer()
    private var admissionLedger = TranscriptAdmissionLedger()
    @ObservationIgnored private lazy var inputPersistence = TranscriptPersistenceQueue(
        configuration: dependencies.persistenceConfiguration,
        save: { [weak self] command in
            guard let self else { throw CancellationError() }
            return try await self.saveTranscriptLine(command)
        },
        didSave: { [weak self] command, ordinal in
            await self?.didSaveTranscript(command, ordinal: ordinal)
        }
    )
    /// 已经补写过 `timing_quality` 的行；同一行只写一次。
    private var timingQualityApplied: Set<String> = []
    /// 这一场是否协商过分人（决定了结束时要等 EOF 屏障）。
    private var diarizationActive = false
    /// `speechrail.diarization.done` 是否已经到达。
    private var diarizationDrained = false

    public init(
        coordinator: SessionCoordinator,
        port: Int = 8201,
        apiKey: String? = nil,
        dependencies: CaptionSessionDependencies? = nil,
        audioSourceFactory: (@MainActor () -> AudioChunkSource)? = nil
    ) {
        let resolvedDependencies = dependencies ?? .production()
        self.coordinator = coordinator
        self.labeling = SpeakerLabeling(coordinator: coordinator, attachLabel: resolvedDependencies.attachSpeakerLabel)
        self.dependencies = resolvedDependencies
        self.port = port
        self.apiKey = apiKey
        if let audioSourceFactory {
            self.audioSourceFactory = audioSourceFactory
        }
    }

    public var isRunning: Bool { phase == .running || phase == .preparing }

    private func saveTranscriptLine(_ command: TranscriptPersistenceQueue.Command) async throws -> Int {
        do {
            if let save = dependencies.saveLine {
                return try await save(command.lineDraft, command.lineID)
            }
            return try await coordinator.appendLine(command.lineDraft, id: command.lineID)
        } catch {
            if sessionID == command.sessionID { lastFailure = "这一句未保存，可重试保存。" }
            throw error
        }
    }

    public var pendingSaveRecordIDs: [String] {
        let pending = inputPersistence.outstandingRecordIDs
        return pending + admissionLedger.recordIDs.filter { !pending.contains($0) }
    }

    public func pendingSaveCommands(recordID: String) -> [TranscriptPersistenceQueue.Command] {
        inputPersistence.unsettledInputs(sessionID: recordID).map(\.command)
    }

    public func saveFailures(recordID: String) -> [TranscriptPersistenceQueue.Failure] {
        inputPersistence.failures(sessionID: recordID)
    }

    public func waitForPendingSaves(recordID: String) async -> TranscriptPersistenceQueue.DrainReport {
        let saved = await inputPersistence.waitUntilSettled(sessionID: recordID)
        return admissionLedger.report(recordID: recordID, saved: saved)
    }

    @discardableResult
    public func retryPendingSaves(recordID: String) async -> Bool {
        for failure in saveFailures(recordID: recordID) {
            inputPersistence.retry(sessionID: recordID, lineID: failure.command.lineID)
        }
        return await waitForPendingSaves(recordID: recordID).isComplete
    }

    public func unsavedTranscriptText(recordID: String) -> String {
        var text = pendingSaveCommands(recordID: recordID).map(\.text)
        if let rejected = admissionLedger.copyText(recordID: recordID) { text.append(rejected) }
        return text.joined(separator: "\n")
    }

    public func admissionRecovery(recordID: String) -> TranscriptAdmissionRecovery? {
        admissionLedger.recovery(recordID: recordID)
    }

    public var saveRecoveryRecords: [TranscriptSaveRecoveryRecord] {
        pendingSaveRecordIDs.compactMap { id in
            let failures = saveFailures(recordID: id)
            let admission = admissionRecovery(recordID: id)
            guard !failures.isEmpty || admission != nil,
                  let observedAt = failures.first?.command.observedAt ?? admission?.observedAt else { return nil }
            return .init(id: id, observedAt: observedAt, failedCount: failures.count, admission: admission)
        }
    }

    private var resolvingAdmissionRecords: Set<String> = []

    public func endIncompleteRecord(_ snapshot: TranscriptAdmissionRecovery) async -> Bool {
        let id = snapshot.recordID
        guard admissionLedger.recovery(recordID: id) == snapshot,
              resolvingAdmissionRecords.insert(id).inserted else { return false }
        defer { resolvingAdmissionRecords.remove(id) }
        if sessionID == id { await stopCapture() }
        let saved = await inputPersistence.waitUntilSettled(sessionID: id)
        guard saved.isComplete, admissionLedger.recovery(recordID: id) == snapshot else { return false }
        do {
            _ = try await saveTranscriptLine(snapshot.command)
        } catch {
            return false
        }
        guard admissionLedger.recovery(recordID: id) == snapshot else { return false }
        let result = await coordinator.sealSessionReporting(id: id, reason: .interrupted)
        guard case .sealed(recordID: id) = result,
              let record = try? await coordinator.record(id: id),
              record.state == .archived, record.endReason == .interrupted,
              admissionLedger.confirmResolution(snapshot) else { return false }
        return true
    }

    /// 记录库文件位置。设置页与受阻时的「打开数据目录」读它。
    public var libraryURL: URL { coordinator.libraryURL }

    /// 现在拿着麦克风的是哪一个能力（受阻带着它时给「打开会议转录」那条出口用文案）。
    public var activeOwnerTitle: String {
        if case .occupiedBy(let kind) = blocked { return kind.title }
        return coordinator.occupancy?.kind.title ?? "会话"
    }

    /// 用户当下看得见的那一段（`复制这一段` 复制它）：未定稿优先。
    public var currentSegmentText: String? {
        if let partialText, !partialText.isEmpty { return partialText }
        return lines.last?.text
    }

    // MARK: - 全局入口（`⌘⇧L`）

    /// `⌘⇧L`：空闲时打开并开始，进行中暂停，暂停中继续。
    ///
    /// 结束**不**走这个键：§16.2.3 的 E6 把浮层上的 `✕` 定为字幕闭环唯一的结束点，
    /// 所以这里不提供第二种"结束"。（§5.2 那句"出现或隐藏"更宽松，取更严格的一条，
    /// 已记在 §12.1 的进度表里。）
    public func toggleFromGlobalShortcut() async {
        switch phase {
        case .idle: await openBand()
        case .running: await pause()
        case .paused: await resume()
        case .preparing, .ending: break
        }
    }

    /// 打开浮层。已经在跑就只是再显示一次，不重开会话。
    public func openBand() async {
        if phase.isLive || phase == .preparing {
            setBandVisible(true)
            return
        }
        blocked = nil
        lastFailure = nil
        setBandVisible(true)

        // 别的会话拿着麦克风：**不开第二条会话**，浮层以受阻态出现并给两个出口（§16.3 X1）。
        if let occupancy = coordinator.occupancy, occupancy.kind != .captions,
           case .needsConfirmation = coordinator.decision(for: .captions) {
            blocked = .occupiedBy(occupancy.kind)
            return
        }
        await coordinator.requestStart(.captions)
    }

    /// 隐藏浮层。**这不是结束会话**：字幕继续、记录继续落库。
    public func hideBand() {
        setBandVisible(false)
    }

    /// 浮层受阻时那条「结束会议并启动字幕」的出口：走同一个守卫（§6.4）。
    public func takeOverOccupiedMicrophone() async {
        guard case .occupiedBy = blocked else { return }
        blocked = nil
        await coordinator.requestStart(.captions)
    }

    // MARK: - 生命周期（由协调器的钩子调用）

    /// 协调器拿定占用之后的"真的开始采集"。抛错 = 受阻，协调器会把占用退回去。
    ///
    /// **受阻的原因必须留在这一层**：协调器只负责退回占用与走时，它调 `starter` 时的
    /// 异常不带界面的落点（`SessionCoordinator.requestStart` 只能 `try?`）。所以这里
    /// 先把原因写进 `blocked`，再抛给协调器——浮层要显示的正是这句话（§6.3.1）。
    public func beginCapture() async throws {
        phase = .preparing
        blocked = nil
        lastFailure = nil
        do {
            guard admissionLedger.canStartNewRecord else {
                throw Blocked(.storeUnavailable("未保存的恢复记录已达到上限，请先复制恢复内容。"))
            }
            try await startPipeline()
        } catch {
            let reason = Self.blockReason(for: error)
            blocked = reason
            // 本地也要退回"没在跑"：采集没起来，界面不能显示成在录。
            // 已经定稿的字幕留着（可读、可复制），受阻态就贴在这一句上面。
            resetToIdleKeepingLines()
            throw Blocked(reason)
        }
    }

    /// 一次完整的启动：读档位 → 起采集 → 连服务 → 建库里的行 → 开始上行。
    ///
    /// 每一步失败都把已经拿到的资源还回去（来源、连接），不留给下一个人收拾；
    /// 库里那一行只在采集与服务都起来之后才建（§5.3.1：不留空记录）。
    private func startPipeline() async throws {
        let binding = await realtimeCapabilityBindingProvider?()
        if realtimeCapabilityBindingProvider != nil, binding == nil {
            throw Blocked(.serviceNotReady("当前服务未确认实时语音识别能力，请刷新服务信息后重试。"))
        }
        // 档位是**服务的事实**，不是会话的选择：写进记录的是本次读到的那一个，
        // 读不到写 `unknown`（不为了一个标签去阻塞会话启动）。
        var profile = "unknown"
        if let serviceReadiness {
            switch await serviceReadiness() {
            case .notReady:
                // Readiness can lag operation capability; connection admission
                // and the Realtime handshake provide the actionable result.
                break
            case .ready(let reported):
                profile = reported ?? "unknown"
            }
        }

        let source = audioSourceFactory()
        self.source = source
        let stream: AsyncStream<AudioChunk>
        do {
            stream = try await source.start()
        } catch {
            self.source = nil
            throw Blocked(Self.blockReason(for: error))
        }

        // 分人在**首个 PCM 之前**协商一次，之后改不了（契约 §Diarization 扩展）。
        // 是否可用的唯一事实来源是服务的能力声明：这里按用户开关原样请求，
        // 不在本地按档位拦截，服务不支持时以稳定错误回应。
        let diarizationEnabled = diarizationPreference()
        diarizationActive = diarizationEnabled
        diarizationDrained = false

        let client = dependencies.makeRealtimeClient(
            CaptionRealtimeClientConfiguration(
                port: port,
                scenePreset: .caption,
                diarizationEnabled: diarizationEnabled,
                apiKey: apiKey,
                expectedASRRevision: binding?.asrModelRevision
            )
        )
        do {
            try await client.connect()
        } catch {
            source.stop()
            self.source = nil
            throw Blocked(.serviceNotReady(error.localizedDescription))
        }
        self.client = client

        // 记录行在**采集真的起来之后**才建：麦克风没起来、服务连不上，都不该在记录库里
        // 留下一条什么都没有的会话（§5.3.1）。
        let startedAt = Date()
        sessionStartedAt = startedAt
        lines = []
        partialText = nil
        terminalCount = 0
        currentOrdinal = 0
        lineByItem = [:]
        timingQualityApplied = []
        isStoppingIntentionally = false
        do {
            let record = try await coordinator.createSession(
                SessionDraft(
                    kind: .captions,
                    engineProfile: profile,
                    audioSource: .microphone,
                    diarization: diarizationEnabled ? .active : .off,
                    diarizationNote: nil,
                    startedAt: startedAt
                )
            )
            sessionID = record.id
            labeling.begin(sessionID: record.id, enabled: diarizationEnabled)
            coordinator.sessionDidStartRecording(id: record.id)
        } catch {
            await client.close()
            source.stop()
            self.source = nil
            self.client = nil
            throw Blocked(.storeUnavailable(error.localizedDescription))
        }

        phase = .running
        sessionGeneration &+= 1
        let identity = beginPreviewGeneration(captureStartedAt: startedAt)
        startPump(stream: stream, client: client, identity: identity)
    }

    /// 协调器的 stopper：把最后半句交出去、关掉连接。**不封存记录**——那是协调器接下来做的事。
    ///
    /// 唯一要挡的是重入（`:ending` 里还等着最后一句）。其余相位都照做：`idle` 时也把浮层
    /// 收起来——协调器决定"这次会话结束了"，浮层就不该继续挂在屏幕上。
    public func stopCapture() async {
        guard phase != .ending else { return }
        let endingRecordID = sessionID
        phase = .ending
        isStoppingIntentionally = true
        source?.stop()
        source = nil
        // `stop()` closes the source stream but does not retract chunks it has
        // already buffered. Upload those before committing the server-side tail.
        await uploadPump?.value
        uploadPump = nil
        if let client {
            do {
                // RealtimeASRClient owns the single commit → terminal →
                // diarization (if negotiated) → clear barrier.
                try await client.drainAndClear(timeout: .seconds(8))
            } catch {
                lastFailure = error.localizedDescription
                await markDiarizationDrainFailureIfNeeded(error)
            }
            await client.close()
        }
        // The client finishes its event stream on close. Let the event owner
        // persist every buffered final/attribution before retiring this identity.
        await pump?.value
        pump = nil
        if let endingRecordID {
            let report = await waitForPendingSaves(recordID: endingRecordID)
            if !report.isComplete {
                if sessionID == endingRecordID { lastFailure = "部分文字尚未保存，请重试保存。" }
                if coordinator.activeSessionID == endingRecordID, coordinator.occupancy?.kind == .captions {
                    coordinator.abandonOccupancy()
                }
            }
        }
        previewIdentity = nil
        client = nil
        diarizationActive = false
        resetToIdleKeepingLines()
        // 浮层跟着这次结束一起收：来自 `✕`、`⌘⇧.`、或切到别的会话，都一样。
        setBandVisible(false)
    }

    /// 用户在浮层上按 `✕`：字幕闭环**唯一**的结束点（E6）。结束即保存。
    ///
    /// 它只结束**自己的**会话。占用在别的能力手里时（字幕带正以受阻态贴在屏幕上，
    /// `§16.3` X1 的那一条），`✕` 只把带子收起来——否则"关掉字幕"会把正在录的会议
    /// 推进"整理中"：麦克风的所有权只由守卫（§6.4）交还，不由浮层的关闭键交还。
    public func finish() async {
        if coordinator.occupancy?.kind == .captions {
            await coordinator.stopCapture(endingWith: .user)
        }
        blocked = nil
        resetToIdleKeepingLines()
        setBandVisible(false)
    }

    /// 把"正在跑"的那一套本地状态清掉，**保留已经定稿的字幕**。
    private func resetToIdleKeepingLines() {
        phase = .idle
        level = 0
        partialText = nil
        previewIdentity = nil
        sessionStartedAt = nil
        sessionID = nil
    }

    // MARK: - 暂停 / 继续

    /// 暂停：**停采集、断连接、放设备**（用户裁决：功能离开就释放），会话与记录都留着。
    ///
    /// 暂停**不**写中断账本：它不是"服务丢了"，是用户按的；这一段空档在导出物的时间码上
    /// 本来就是看得见的（`t_start` 跳一段），账本里再写一条反而把"用户按的"和
    /// "真的断了"混成同一种事。
    public func pause() async {
        guard phase == .running else { return }
        isStoppingIntentionally = true
        source?.stop()
        source = nil
        await uploadPump?.value
        uploadPump = nil
        if let client {
            do {
                try await client.drainAndClear(timeout: .seconds(8))
            } catch {
                lastFailure = error.localizedDescription
                await markDiarizationDrainFailureIfNeeded(error)
            }
            await client.close()
        }
        await pump?.value
        pump = nil
        client = nil
        previewIdentity = nil
        level = 0
        // 未定稿的那一句不写成半截行：库里的行只认定稿（§15 的 `status` 取值域）。
        partialText = nil
        phase = .paused
        isStoppingIntentionally = false
    }

    public func resume() async {
        guard phase == .paused else { return }
        do {
            try await restartPipeline()
        } catch {
            blocked = Self.blockReason(for: error)
        }
    }

    /// 受阻之后重新接上。判据是**占用还在不在自己手里**，而不是受阻的类型：
    ///
    ///   - 占用仍是 `.captions`（服务忙、中途断线、续接失败）：这不是"再开一次会话"，
    ///     是"把这条断掉的链路接回去"。走 `requestStart` 只会拿到 `.alreadyActive`，
    ///     于是按钮点了没反应、界面还显示成在跑——那是最糟的一种失败。
    ///   - 占用不在自己手里（麦克风未授权、服务未就绪、别人占着）：走守卫重新开始，
    ///     该弹确认就弹确认。**原因在成功之前不清掉**，用户取消后浮层回到原样。
    public func retry() async {
        if coordinator.occupancy?.kind == .captions {
            if coordinator.phase == .interrupted {
                await coordinator.resumeAfterInterruption()
            }
            do {
                try await restartPipeline()
            } catch {
                blocked = Self.blockReason(for: error)
            }
            return
        }
        await coordinator.requestStart(.captions)
    }

    private func restartPipeline() async throws {
        // 续接是"新 epoch"，不是"再叠一路"：上一次留下的采集件先还回去，
        // 否则旧的引擎会一直被持着（用户裁决：功能离开就释放）。
        source?.stop()
        source = nil
        let binding = await realtimeCapabilityBindingProvider?()
        if realtimeCapabilityBindingProvider != nil, binding == nil {
            throw Blocked(.serviceNotReady("当前服务未确认实时语音识别能力，请刷新服务信息后重试。"))
        }
        let source = audioSourceFactory()
        self.source = source
        let stream: AsyncStream<AudioChunk>
        do {
            stream = try await source.start()
        } catch {
            self.source = nil
            throw Blocked(Self.blockReason(for: error))
        }
        // 续接是**新连接、新 epoch**（§6.5）：分人在新连接上要重新协商一次，
        // 否则这一段的归属会静默丢掉。
        let client = dependencies.makeRealtimeClient(
            CaptionRealtimeClientConfiguration(
                port: port,
                scenePreset: .caption,
                diarizationEnabled: diarizationActive,
                apiKey: apiKey,
                expectedASRRevision: binding?.asrModelRevision
            )
        )
        do {
            try await client.connect()
        } catch {
            source.stop()
            self.source = nil
            throw Blocked(.serviceNotReady(error.localizedDescription))
        }
        self.client = client
        diarizationDrained = false
        isStoppingIntentionally = false
        blocked = nil
        phase = .running
        let identity = beginPreviewGeneration(captureStartedAt: Date())
        startPump(stream: stream, client: client, identity: identity)
    }

    // MARK: - 采集 → 上行

    private func beginPreviewGeneration(captureStartedAt: Date) -> TranscriptPreviewLedger.Identity {
        nextConnectionID &+= 1
        let identity = TranscriptPreviewLedger.Identity(
            connection: nextConnectionID,
            generation: sessionGeneration
        )
        previewIdentity = identity
        previewLedger.beginGeneration(
            identity: identity,
            captureTimelineOffsetSeconds: captureStartedAt.timeIntervalSince1970
        )
        return identity
    }

    private func startPump(
        stream: AsyncStream<AudioChunk>,
        client: any CaptionRealtimeClient,
        identity: TranscriptPreviewLedger.Identity
    ) {
        uploadPump?.cancel()
        uploadPump = Task { [weak self] in
            for await chunk in stream {
                guard let self, self.isCurrent(identity) else { return }
                await self.upload(chunk, to: client, identity: identity)
            }
        }

        pump?.cancel()
        pump = Task { [weak self] in
            let events = await client.events()
            for await envelope in events {
                guard let self, self.isCurrent(identity) else { return }
                await self.handle(envelope, identity: identity)
            }
        }
    }

    private func isCurrent(_ identity: TranscriptPreviewLedger.Identity) -> Bool {
        identity == previewIdentity
    }

    private func upload(
        _ chunk: AudioChunk,
        to client: any CaptionRealtimeClient,
        identity: TranscriptPreviewLedger.Identity
    ) async {
        guard isCurrent(identity) else { return }
        level = chunk.level
        do {
            try await client.append(chunk.pcm)
        } catch {
            // 送不出去就是连接没了：由接收侧的 `closed` 统一处置，这里不重复报错。
            lastFailure = error.localizedDescription
        }
    }

    // MARK: - 下行

    private func handle(
        _ envelope: RealtimeEventEnvelope<RealtimeASRClient.Event>,
        identity: TranscriptPreviewLedger.Identity
    ) async {
        guard identity == previewIdentity else { return }
        switch envelope.payload {
        case .ready, .configured, .alignmentFailed,
             .ttsStarted(_, _, _), .ttsTextAccepted(_, _, _, _),
             .ttsAudio(_, _, _), .ttsEnded(_, _, _, _, _):
            // 字幕会话不接线 TTS：增量 utterance 属于助手那一层。
            break
        case .partial(let itemID, let delta):
            _ = previewLedger.acceptDelta(
                identity: identity,
                itemID: itemID,
                delta: delta,
                eventID: envelope.metadata.eventID
            )
            partialText = previewLedger.visiblePartial
        case .partialSnapshot(let itemID, let revision, let text, _):
            _ = previewLedger.acceptSnapshot(
                identity: identity,
                itemID: itemID,
                revision: revision,
                text: text,
                eventID: envelope.metadata.eventID
            )
            partialText = previewLedger.visiblePartial
        case .segmentClosed(let itemID, let sampleSpan, let reason, let commitEventID):
            guard let closeReason = TranscriptPreviewLedger.SegmentCloseReason(
                rawValue: reason.rawValue
            ) else { return }
            _ = previewLedger.closeSegment(
                identity: identity,
                itemID: itemID,
                sampleSpan: sampleSpan,
                reason: closeReason,
                commitEventID: commitEventID,
                eventID: envelope.metadata.eventID
            )
        case .completed(let itemID, let transcript):
            terminalCount += 1
            let outcome = previewLedger.resolveCommit(
                identity: identity,
                itemID: itemID,
                transcript: transcript
            )
            partialText = previewLedger.visiblePartial
            guard case .commit(let committed) = outcome else { return }
            await commit(committed)
        case .failed(let itemID, let code, let message):
            terminalCount += 1
            lastFailure = "\(code)：\(message)"
            let recoveryNote = previewLedger.recoveryNote(
                identity: identity,
                itemID: itemID
            )
            let boundary = previewLedger.boundary(identity: identity, itemID: itemID)
            _ = previewLedger.resolveFailure(identity: identity, itemID: itemID)
            partialText = recoveryNote?.text ?? previewLedger.visiblePartial
            if let recoveryNote {
                acceptTranscript(
                    text: recoveryNote.text, itemID: itemID, identity: identity,
                    boundary: boundary, formal: false
                )
            }
        case .attribution(let itemID, let units, _):
            await applyAttribution(itemID: itemID, units: units, identity: identity)
        case .diarizationFinished:
            diarizationDrained = true
        case .auxiliaryIncomplete(_, let alignmentMissing, let diarizationMissing):
            if diarizationMissing, diarizationActive {
                labeling.markDegraded(
                    code: "auxiliary_window_expired",
                    message: "部分说话人归属未能及时到达，正文已经保留。"
                )
                if let sessionID, let note = labeling.note {
                    await coordinator.updateSessionDiarization(
                        id: sessionID,
                        state: .degraded,
                        note: note
                    )
                }
            }
            if alignmentMissing || diarizationMissing {
                lastFailure = "部分辅助信息未能及时到达，已保留转写内容。"
            }
        case .diarizationDegraded(let code, let message):
            labeling.markDegraded(code: code, message: message)
            if let sessionID, let note = labeling.note {
                await coordinator.updateSessionDiarization(id: sessionID, state: .degraded, note: note)
            }
        case .serverError(let code, let message, _):
            await handleServerError(code: code, message: message)
        case .closed(let code):
            await handleUnexpectedClose(code: code)
        }
    }

    /// 对齐（文本 → 采样区间）与分人（采样区间 → 匿名说话人）随后到达：
    /// 先记住 `segment_uid` → 行，再原位改归属，并补写一次 `timing_quality`。
    /// 正文与时间码一个字不动，也不留新行（§15.3 第 2 条）。
    private func applyAttribution(
        itemID: String,
        units: [RealtimeASRClient.AttributionUnit],
        identity: TranscriptPreviewLedger.Identity
    ) async {
        let itemIdentity = TranscriptPreviewLedger.ItemIdentity(identity: identity, itemID: itemID)
        guard identity == previewIdentity, !units.isEmpty, let sessionID else { return }
        guard let entry = lineByItem[itemIdentity] else {
            if !pendingAttributions.store(
                units, recordID: sessionID, identity: itemIdentity, labelsEnabled: labeling.isEnabled
            ) {
                lastFailure = "部分说话人信息未能保存，正文继续保留。"
            }
            return
        }
        enqueueAttribution(
            recordID: sessionID, identity: identity, lineID: entry.lineID, ordinal: entry.ordinal,
            units: units, labelsEnabled: labeling.isEnabled
        )
    }

    private func enqueueAttribution(
        recordID: String, identity: TranscriptPreviewLedger.Identity, lineID: String, ordinal: Int,
        units: [RealtimeASRClient.AttributionUnit], labelsEnabled: Bool
    ) {
        let owner: SpeakerLabeling
        if sessionID == recordID, previewIdentity == identity {
            owner = labeling
        } else {
            owner = SpeakerLabeling(coordinator: coordinator, attachLabel: dependencies.attachSpeakerLabel)
            owner.begin(sessionID: recordID, enabled: labelsEnabled)
        }
        let command = owner.freezeAttribution(units: units, lineID: lineID)
        let quality = Self.timingQuality(from: units)
        let accepted = inputPersistence.enqueueProjection(
            recordID: recordID, lineID: lineID, unitCount: units.count, coalescing: false
        ) { [weak self, owner] in
            guard let self else { return }
            let confirmedLabels = await owner.apply(command)
            var savedTiming = false
            if let quality, !(self.sessionID == recordID && self.timingQualityApplied.contains(lineID)) {
                do {
                    try await self.coordinator.attachTimingQuality(lineID: lineID, quality: quality)
                    savedTiming = true
                } catch {
                    if self.sessionID == recordID, self.previewIdentity == identity {
                        self.lastFailure = "有一条时间信息未能保存。"
                    }
                }
            }
            guard self.sessionID == recordID, self.previewIdentity == identity else { return }
            if savedTiming { self.timingQualityApplied.insert(lineID) }
            self.lines = self.lines.map { existing in
                guard existing.id == lineID else { return existing }
                var updated = existing
                if confirmedLabels.contains(lineID) {
                    updated.speakerLabel = owner.attributedLabel(forLineID: lineID)
                }
                return updated
            }
        }
        if accepted {
            owner.register(units: units, lineID: lineID, ordinal: ordinal)
        } else if sessionID == recordID, previewIdentity == identity {
            lastFailure = "部分说话人和时间信息未能保存，正文已保留。"
        }
    }

    /// 定稿即落库；preview ledger 按连接和 item 去重，输入 sample span 冻结时间区间。
    private func commit(_ item: TranscriptPreviewLedger.CommittedItem) async {
        let formal = item.recoveryNote == nil
        let text = (item.recoveryNote?.text ?? item.finalText).trimmingCharacters(in: .whitespacesAndNewlines)
        partialText = formal ? nil : text
        if !formal { lastFailure = "有一句话没有拿到定稿正文，正在保留恢复内容。" }
        acceptTranscript(
            text: text, itemID: item.itemID, identity: item.identity,
            boundary: item.boundary, formal: formal
        )
    }

    private func acceptTranscript(
        text: String, itemID: String, identity: TranscriptPreviewLedger.Identity,
        boundary: TranscriptPreviewLedger.Boundary?, formal: Bool
    ) {
        guard !text.isEmpty, let sessionID, let startedAt = sessionStartedAt else { return }
        let inputTimes = sessionRelativeInputTimes(from: boundary, startedAt: startedAt)
        let command = TranscriptPersistenceQueue.Command(
            sessionID: sessionID, connection: identity.connection, itemID: itemID,
            generation: identity.generation, text: text, source: .microphone, role: .speaker,
            tStart: inputTimes?.start, tEnd: inputTimes?.end, formal: formal,
            isInterrupted: false, timingQuality: .unavailable, observedAt: Date()
        )
        switch inputPersistence.enqueue(command) {
        case .accepted, .duplicate: break
        case .capacityExceeded:
            admissionLedger.reject(recordID: sessionID, text: text)
            partialText = text
            lastFailure = "记录正在保存，暂时无法保存这句新内容，请先复制。"
        case .invalidIdentity:
            admissionLedger.reject(recordID: sessionID, text: text)
            partialText = text
            lastFailure = "无法确认这句内容属于哪场记录，请先复制。"
        }
    }

    private func didSaveTranscript(_ command: TranscriptPersistenceQueue.Command, ordinal: Int) async {
        if sessionID == command.sessionID, !command.formal,
           lastFailure?.contains("正在保留恢复内容") == true {
            lastFailure = "有一句话没有拿到定稿正文，已原样保留恢复内容（不进正式记录）。"
        }
        let identity = TranscriptPreviewLedger.Identity(
            connection: command.connection, generation: command.generation
        )
        let itemIdentity = TranscriptPreviewLedger.ItemIdentity(identity: identity, itemID: command.itemID)
        // 行已经在了。对齐/分人结果到达时按 `utterance_id` 找回这一行。
        if sessionID == command.sessionID, command.formal {
            lineByItem[itemIdentity] = (lineID: command.lineID, ordinal: ordinal)
            currentOrdinal = max(currentOrdinal, ordinal)
            if !lines.contains(where: { $0.id == command.lineID }) {
                lines.append(Line(
                    id: command.lineID, ordinal: ordinal, text: command.text,
                    start: command.tStart, end: command.tEnd, speakerLabel: command.speakerLabel
                ))
                lines.sort { $0.ordinal < $1.ordinal }
            }
        }
        guard let payload = pendingAttributions.take(recordID: command.sessionID, identity: itemIdentity),
              command.formal else { return }
        enqueueAttribution(
            recordID: command.sessionID, identity: identity, lineID: command.lineID, ordinal: ordinal,
            units: payload.units, labelsEnabled: payload.labelsEnabled
        )
    }

    private func sessionRelativeInputTimes(
        from boundary: TranscriptPreviewLedger.Boundary?,
        startedAt: Date
    ) -> (start: TimeInterval, end: TimeInterval)? {
        guard let range = boundary?.inputRange,
              range.isApproximate,
              let absoluteStart = range.startSeconds,
              let absoluteEnd = range.endSeconds
        else { return nil }
        let start = absoluteStart - startedAt.timeIntervalSince1970
        let end = absoluteEnd - startedAt.timeIntervalSince1970
        guard start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
        return (start, end)
    }

    /// 分人档位下 `timing_quality` 由归属单元给：有对齐结果就是 `aligned`，
    /// 整 item 退成一个 `unavailable` 单元（契约）时就如实写 `unavailable`。
    /// 没开分人时不写——那一档本来就没有对齐结果，写 `available` 是撒谎。
    private static func timingQuality(
        from units: [RealtimeASRClient.AttributionUnit]
    ) -> SessionTimingQuality? {
        guard !units.isEmpty else { return nil }
        return units.contains { $0.timingQuality == "aligned" } ? .aligned : .unavailable
    }

    private func handleServerError(code: String, message: String) async {
        switch code {
        case "backend_busy":
            // 契约：`backend_busy` 时 session 仍可用，是准入结果而不是坏连接。
            // 但它意味着这一段音频进不去——按中断处理，给"重新接上"的出口（§3 同条结论）。
            await enterInterrupted(.serviceBusy("已有另一个实时转写会话在用语音引擎。等它结束后重新接上。"))
        case "language_not_supported":
            await enterInterrupted(.serviceNotReady("这台 Mac 现在的模型不支持当前语言。"))
        default:
            // 契约里这些失败都**保持 session 可用**：记下来，不打断采集
            // （`voice_not_found` 那种属于助手/TTS，这一档收不到）。
            lastFailure = message
        }
    }

    private func handleUnexpectedClose(code: Int?) async {
        guard !isStoppingIntentionally, phase == .running else { return }
        let reason = code.map { "语音服务断开了连接（\($0)）。" } ?? "语音服务断开了连接。"
        await enterInterrupted(.streamFailed(reason))
    }

    /// 中途断了：停采集、停连接、**写一条中断区间**（不重放 PCM），会话与记录都留着。
    /// 用户点「重新接上」就是新 epoch——序号与水位不重置（§6.5）。
    private func enterInterrupted(_ reason: BlockReason) async {
        source?.stop()
        source = nil
        uploadPump?.cancel()
        uploadPump = nil
        pump?.cancel()
        pump = nil
        previewIdentity = nil
        if let client {
            await client.close()
            self.client = nil
        }
        level = 0
        partialText = nil
        if coordinator.occupancy?.kind == .captions {
            _ = await coordinator.markInterruption(.serviceLost, atOrdinal: currentOrdinal)
        }
        blocked = reason
    }

    private func markDiarizationDrainFailureIfNeeded(_ error: Error) async {
        guard diarizationActive,
              let drainError = error as? RealtimeASRClient.Failure,
              drainError == .drainTimedOut(.diarization)
        else { return }
        labeling.markDegraded(
            code: "finalization_timeout",
            message: "说话人编号没能在结束前对齐，正文已经存好了。"
        )
        if let sessionID, let note = labeling.note {
            await coordinator.updateSessionDiarization(id: sessionID, state: .degraded, note: note)
        }
    }

    // MARK: - 浮层上的动作

    /// `导出 SRT…`：走系统保存面板，只读库里的定稿行（§6.2 第三条判断）。
    public func exportSRT() async {
        guard let sessionID else { return }
        guard let record = (try? await coordinator.record(id: sessionID)) ?? nil else { return }
        let rows = (try? await coordinator.lines(sessionID: sessionID)) ?? []
        let names = (try? await coordinator.speakerNames(sessionID: sessionID)) ?? [:]
        SessionExportPanel.write(
            SessionExportPayload(record: record, lines: rows, speakerNames: names),
            as: .srt
        )
    }

    // MARK: - 小工具

    private func setBandVisible(_ visible: Bool) {
        isBandVisible = visible
        presentBand?(visible)
    }

    private static func blockReason(for error: Error) -> BlockReason {
        if let failure = error as? MicrophoneCapture.Failure, failure == .permissionDenied {
            return .microphoneDenied
        }
        if let blocked = error as? Blocked { return blocked.reason }
        return .serviceNotReady(error.localizedDescription)
    }

    /// 受阻的内部信号：把原因从"真的开始采集"里带出来，交给协调器退回占用。
    struct Blocked: Error {
        var reason: BlockReason

        init(_ reason: BlockReason) {
            self.reason = reason
        }
    }
}
