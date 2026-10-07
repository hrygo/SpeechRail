import Foundation
import Observation
import SpeechRailControlKit

// 会议助手（`SESSIONS-SPEC` §6.2、§14.1、§14.3、§16.7；`TECHNICAL-DESIGN` §5.6）。
//
// 一句话：**按来源把一段多人谈话变成带说话人标签的转录与多版本纪要**。
//
// 它复用的三样东西（一个都不重写）：
//   · 采集与来源选择 → `AudioSourceCoordinator`（R4 的唯一落点）
//   · 连接与事件     → `RealtimeASRClient`（与字幕同一条链路，含分人）
//   · 归属账本与改名 → `SpeakerLabeling`（会议与字幕共用；只改归属列）
//
// 它与字幕的**唯一实质差别**是三件事：来源可以有多路、`server_vad` 的静音窗口更长
// （900 ms，要整句而不是抢速度）、结束之后有纪要这一步（§5.8）。
//
// 中断是**事件不是阶段**（§6.2）：界面上的"已中断"由"有未闭合的中断区间"推出，
// 库里 `session.state` 仍然是 `recording`。四类断法见 `SessionInterruptionReason`。

@MainActor
@Observable
public final class MeetingSession {
    public enum Phase: String, Sendable, Equatable {
        case idle
        case preparing
        case recording
        /// 四类中断之一。它**不是**库状态，只是界面相位（§6.2）。
        case interrupted
        case processing
        case archived

        public var isLive: Bool {
            switch self {
            case .preparing, .recording: true
            default: false
            }
        }
    }

    /// 受阻的原因。会议页的受阻与字幕、助手**共用同一条结论条的形状**（§6.7）。
    public enum BlockReason: Equatable, Sendable {
        case noSourceSelected
        case serviceNotReady(String)
        case serviceBusy(String)
        case occupiedBy(SessionKind)
        case microphoneDenied
        case systemAudioUnavailable(String)
        case storeUnavailable(String)
        case streamFailed(String)

        public var title: String {
            switch self {
            case .noSourceSelected: "还没有选声音从哪来"
            case .serviceNotReady: "语音服务未就绪"
            case .serviceBusy: "语音服务正忙"
            case .occupiedBy(let kind): "\(kind.title)正在使用麦克风"
            case .microphoneDenied: "麦克风未授权"
            case .systemAudioUnavailable: "本机音频拿不到"
            case .storeUnavailable: "记录库不可用"
            case .streamFailed: "识别中断了"
            }
        }

        public var detail: String {
            switch self {
            case .noSourceSelected:
                MeetingAudioBlockReason.noSourceSelected.detail
            case .serviceNotReady(let message):
                message
            case .serviceBusy(let message):
                message
            case .occupiedBy:
                "麦克风同一时刻只能由一个会话使用；可以先结束那个会话，或者等它说完。"
            case .microphoneDenied:
                MeetingAudioBlockReason.microphoneDenied.detail
            case .systemAudioUnavailable(let message):
                MeetingAudioBlockReason.systemAudioUnavailable(message).detail
            case .storeUnavailable(let message):
                message
            case .streamFailed(let message):
                "\(message)丢掉的音频就是没录上；已经定稿的文字记录都还在，可以导出。"
            }
        }

        /// 本机音频受阻时**换来源**是出口之一（§9 第 4 行），所以会议页要给"只用麦克风"。
        public var suggestsMicrophoneOnly: Bool {
            if case .systemAudioUnavailable = self { return true }
            return false
        }
    }

    public struct Blocked: LocalizedError, Equatable, Sendable {
        public var reason: BlockReason
        public var errorDescription: String? { "\(reason.title)。\(reason.detail)" }
    }

    /// 转录流里的一行（内存镜像；权威在库里）。
    public struct Line: Identifiable, Sendable, Equatable {
        public var id: String
        public var ordinal: Int
        public var text: String
        public var start: TimeInterval
        public var end: TimeInterval
        public var speakerLabel: String?
        public var source: SessionLineSource
        public var isDeviceSwitch: Bool
        /// 这一行的 `tStart` / `tEnd` 是不是**说话时刻**。
        ///
        /// `nil` 或 `.unavailable` 都表示"不知道"——那两列存的是**被记下来的
        /// 时刻**。界面据此不显示数字（MA-02 / MC-15）。
        public var timingQuality: SessionTimingQuality?
    }

    public enum ServiceReadiness: Sendable {
        case ready(profile: String?)
        case notReady(String)
    }

    // MARK: 状态

    public private(set) var phase: Phase = .idle
    public private(set) var blocked: BlockReason?
    /// 本场转录（已定稿的行）。
    public private(set) var lines: [Line] = []
    /// 正在识别的那一句（未定稿，只进内存，**不进库**）。
    public private(set) var partialText: String?
    public private(set) var level: Double = 0
    public private(set) var sessionID: String?
    public private(set) var startedAt: Date?
    public private(set) var lastFailure: String?
    /// 这一场选的来源与它的可读名字（库里的 `session.audio_source` 与界面上的那句话）。
    public private(set) var selection: MeetingAudioSelection?
    /// 合流时补的静音块数（缺口）。它是一条事实，不是错误。
    public private(set) var gapCount = 0
    /// 最近一次中断的原因与时刻（界面上的"已中断"读它）。
    public private(set) var interruption: SessionInterruptionReason?
    public private(set) var interruptedAt: Date?
    /// 这一次中断**到底发生了什么**（现场那句话，比枚举名具体）。
    /// 界面读它，是因为 `source_lost` 这一类在库里对应两件事——被 tap 的 App 退出
    /// （自动接回、录制不打断）与采集流自己结束（设备被拔、引擎停了）。
    /// 只按枚举名写文案，就会对后者说成"已经自动接回、录制没有停"，那是**假话**。
    public private(set) var interruptionNote: String?
    /// 因为 `source_lost` 自动接回过几次（§9 第 9 行：无打扰，只记区间）。
    public private(set) var reconnectedSources = 0
    public private(set) var isPaused = false
    /// 麦克风这一路被用户静音了没有（会中「我暂时不说」）。
    ///
    /// 三件事互不等价，页头与状态带必须分开说：**静音**只让麦克风一路往下送静音（设备还在、
    /// 会还在录，本机音频那一侧照旧进转录）；**暂停**是整条上行都停；**结束**才是释放设备。
    /// 所以它与 `isPaused` 是两个独立的开关，一个开着不影响另一个。
    public private(set) var isMicrophoneMuted = false

    #if DEBUG
    /// 离屏渲染工装（`/tmp` 里的 `NSHostingView`）用的**只写展示状态**夹具。
    ///
    /// 「录制中 / 已中断 / 正在整理」这几屏真机验收要"解锁 + 麦克风 + 服务"三样同时在手；
    /// 在此之前版面（来源读数、转录流、说话人编号、中断那一行、内心 OS 展开）只能靠渲染
    /// 真实视图来看。口径与 `CaptionSession.applyRenderFixture` 一致：只在 Debug 构建里
    /// 存在，不碰存储、网络与设备，也不改变任何产线行为。
    func applyRenderFixture(
        phase: Phase,
        blocked: BlockReason? = nil,
        lines: [Line] = [],
        partialText: String? = nil,
        level: Double = 0,
        sessionID: String? = nil,
        startedAt: Date? = nil,
        lastFailure: String? = nil,
        selection: MeetingAudioSelection? = nil,
        gapCount: Int = 0,
        interruption: SessionInterruptionReason? = nil,
        interruptedAt: Date? = nil,
        interruptionNote: String? = nil,
        reconnectedSources: Int = 0,
        isPaused: Bool = false,
        isMicrophoneMuted: Bool = false
    ) {
        self.phase = phase
        self.blocked = blocked
        self.lines = lines
        self.partialText = partialText
        self.level = level
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.lastFailure = lastFailure
        self.selection = selection
        self.gapCount = gapCount
        self.interruption = interruption
        self.interruptedAt = interruptedAt
        self.interruptionNote = interruptionNote
        self.reconnectedSources = reconnectedSources
        self.isPaused = isPaused
        self.isMicrophoneMuted = isMicrophoneMuted
    }
    #endif

    /// 分人账本：与会话同生共死，**会议与字幕共用同一份实现**。
    public let labeling: SpeakerLabeling
    /// 纪要生成（排队 + 租约 + 版本）。
    public let minutes: MinutesGenerator
    /// 会中私密问答。
    public let innerOS: InnerOSSession

    // MARK: 挂载点（由 App 注入）

    /// Optional `/readyz` diagnostic; the effective capability binding is the start gate.
    public var serviceReadiness: (@MainActor () async -> ServiceReadiness)?
    public var realtimeCapabilityBindingProvider:
        (@MainActor () async -> RealtimeCapabilityBinding?)?
    public var preferences: (@MainActor () -> SessionPreferences)?
    private let coordinator: SessionCoordinator
    /// 采集、连接与时钟的接缝（MA-01）。默认值就是生产行为。
    private let dependencies: MeetingSessionDependencies
    private var audio: any MeetingAudioSource
    private let port: Int
    private let serviceKey: String?

    private var client: (any MeetingRealtimeClient)?
    private var pump: Task<Void, Never>?
    private var uploadPump: Task<Void, Never>?
    private var sleepObserver: AnyObject?
    private var currentOrdinal = 0
    /// item 级账本（MA-02）。去重按 (代次, itemID)，
    /// 所以重连后新服务复用 item ID 不会被旧连接的去重集吞掉（MC-13）。
    private var transcriptLedger = TranscriptItemLedger()
    /// 修订文本与输入区间按连接及 item 归属；final 到达时刻不参与声学时间。
    private var previewLedger = TranscriptPreviewLedger()
    private var previewIdentity: TranscriptPreviewLedger.Identity?
    /// `(connection, generation, itemID)` → 已落库行，避免迟到归属命中新连接复用的 item ID。
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
    private var diarizationDrained = false
    private var isStoppingIntentionally = false
    /// 本场第几个 epoch（一次 WS 连接 = 一个 epoch，§5.2 账本规则 1）。
    private var epoch = 0
    /// 连接代次守卫（MA-01）。泵任务与异步回调带着启动时领的票，
    /// 在**发布到 self 之前**重新核对——晚到的 chunk 或事件不许写进
    /// 已经换了一代的状态。
    private var connectionGeneration = MeetingConnectionGeneration()

    public init(
        coordinator: SessionCoordinator,
        port: Int = 8201,
        apiKey: String? = nil,
        llmProvider: LLMProvider = LLMProvider(),
        dependencies: MeetingSessionDependencies
    ) {
        self.coordinator = coordinator
        self.dependencies = dependencies
        self.audio = dependencies.makeAudioSource()
        self.port = port
        self.serviceKey = apiKey
        self.labeling = SpeakerLabeling(coordinator: coordinator, attachLabel: dependencies.attachSpeakerLabel)
        self.minutes = MinutesGenerator(coordinator: coordinator, provider: llmProvider)
        self.innerOS = InnerOSSession(coordinator: coordinator, provider: llmProvider)
        // 改了来源（改名 / 合并 / 标记「我」/ 拆出）就重算一次复核状态。
        // 验收标准 3 说的「修改来源后相关结论提示复核」要**当场**兑现：
        // 此前这四条路径写完修订就结束，界面上的"需复核"要等下一次重新整理或
        // 重开才出现——用户看到的是"我改了名字，什么提示都没有"。
        self.labeling.onSourceRevision = { [weak self] in
            guard let self, let sessionID = self.sessionID else { return }
            await self.minutes.reload(sessionID: sessionID)
        }
    }

    // MARK: - 入口

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

    /// 由用户明确确认：保留可恢复预览并按中断结束，不生成正式纪要或丢弃已接纳命令。
    public func endIncompleteRecord(_ snapshot: TranscriptAdmissionRecovery) async -> Bool {
        let id = snapshot.recordID
        guard admissionLedger.recovery(recordID: id) == snapshot,
              resolvingAdmissionRecords.insert(id).inserted else { return false }
        defer { resolvingAdmissionRecords.remove(id) }
        if sessionID == id {
            isStoppingIntentionally = true
            await releaseCapture(drain: true)
            if sessionID == id { phase = .processing }
        }
        let saved = await inputPersistence.waitUntilSettled(sessionID: id)
        guard saved.isComplete, admissionLedger.recovery(recordID: id) == snapshot else { return false }
        do {
            _ = try await saveTranscriptLine(snapshot.command)
        } catch {
            return false
        }
        guard admissionLedger.recovery(recordID: id) == snapshot else { return false }
        let result = await coordinator.sealMeeting(id: id, reason: .interrupted)
        guard case .sealed(recordID: id) = result,
              let record = try? await coordinator.record(id: id),
              record.state == .archived, record.endReason == .interrupted,
              admissionLedger.confirmResolution(snapshot) else { return false }
        if sessionID == id {
            phase = .archived
            lastFailure = "本次记录已按中断结束，未完整保存的预览保留在恢复内容中。"
        }
        return true
    }

    /// 页面主按钮：选好来源之后从这里进（§6.2 的空态度）。
    /// 会前写的标题（方案 §4.1）。
    ///
    /// 存下来是为了**失败之后还在**：启动被麦克风占用、服务没握手这些都很常见，
    /// 清空它等于让用户把刚打的字重打一遍，而失败往往还发生在同一台机器、
    /// 同一个占着设备的应用上——他改不掉。空白按"没写"处理，不是存一个空标题。
    public private(set) var pendingTitle: String?

    public func start(selection: MeetingAudioSelection, title: String? = nil) async {
        self.selection = selection
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        // 每次开始都重设：下一场会议不该继承上一场的名字。
        pendingTitle = (trimmed?.isEmpty ?? true) ? nil : trimmed
        blocked = nil
        lastFailure = nil
        await coordinator.requestStart(.meeting)
    }

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

    /// 协调器的 `starter`：真的拿设备、连服务。
    public func beginCapture() async throws {
        phase = .preparing
        blocked = nil
        do {
            guard admissionLedger.canStartNewRecord else {
                throw Blocked(reason: .storeUnavailable("未保存的恢复记录已达到上限，请先复制恢复内容。"))
            }
            try await startPipeline(isNewSession: true)
        } catch {
            let reason = Self.blockReason(for: error)
            blocked = reason
            await audio.stop()
            resetKeepingLines()
            throw Blocked(reason: reason)
        }
    }

    /// 协调器的 `stopper`：只释放设备与连接，**不动库里的行**（封存由协调器做）。
    public func stopCapture() async {
        isStoppingIntentionally = true
        await releaseCapture(drain: true)
    }

    /// 结束这一场并整理：EOF 屏障 → 释放设备 → 封存 → 排纪要（§8.2 的最后三步）。
    public func finishAndSummarize() async {
        guard sessionID != nil else {
            // 还没建记录就点结束：多半正有一段启动挂在半路（麦克风授权弹窗、
            // 服务握手还没回来）。没有记录就没有可整理的，所以走 `finalize`
            // 而不是 `stopCapture`——后者会把占用留在 `isProcessing` 且永远
            // 等不到 `finishProcessing`，下一场会议就再也开不起来了。
            //
            // `finalize` 内部会先调 `stopper`，也就是 `stopCapture()`，
            // 由它 `releaseCapture`：作废连接代次，让挂起的启动回来时发现自己过期，
            // 不会把已经结束的会改回「正在录」（MC-05 / MC-06）。
            await coordinator.finalize(reason: .user)
            // 本层相位协调器不管，单独复位成 idle：没有记录，也就没有可整理的。
            resetKeepingLines()
            return
        }
        isStoppingIntentionally = true
        let id = sessionID
        // ① RealtimeASRClient drains ASR and diarization before clear/close;
        // devices are released before the record is archived (R4).
        await releaseCapture(drain: true)
        if let id, !(await waitForPendingSaves(recordID: id)).isComplete {
            phase = .processing
            lastFailure = "部分文字尚未保存，请重试保存后再整理。"
            return
        }
        phase = .processing
        await coordinator.stopCapture(endingWith: .user)
        // MC-17/MC-20 收尾：封存走上报结果，失败如实留痕并保留重试/复制出口。
        guard let id else { return }
        let seal = await coordinator.sealMeeting(id: id, reason: .user)
        switch seal {
        case .sealed:
            lastFailure = nil
            phase = .archived
        case .failed(_, let reason):
            // 转录已在库里，封存失败只影响状态不断言丢失：留在 processing，
            // 界面可重试结束或复制已保存内容，不谎报已归档。
            lastFailure = "封存没有成功：\(reason)。文字记录仍在库里，可以重试结束或先复制已保存的内容。"
            return
        case .skipped:
            lastFailure = "封存被跳过：记录仍被占用。文字记录仍在库里，可以重试结束。"
            return
        }
        // ② 整理：转录已封存，失败也不影响它（§9 第 18 行）。
        let resolvedConfiguration = preferences?().resolvedLLMConfiguration(for: .minutes)
            ?? ResolvedLLMConfiguration(
                configuration: LLMConfiguration(),
                apiKey: nil,
                origin: .global
            )
        await minutes.generate(sessionID: id, resolvedConfiguration: resolvedConfiguration)
    }

    /// 页头的「结束会议」。**会议永远确认**（防误停，§6.4），确认在界面上做。
    public func requestFinish() async {
        guard phase.isLive || phase == .interrupted else { return }
        await finishAndSummarize()
    }

    /// 纪要失败之后，下一步该去哪儿。
    ///
    /// 配置问题（没填模型 / 地址写错 / 端点没有 Responses API）→ 去设置；其余 → 重新生成。
    /// 「配置仍然空着」这一条也在这里判：重启后 `reload` 只读得回失败原因文本，
    /// 而"当前配置还是空的"本身就说明下一步是把模型填上（用户 2026-09-19：
    /// 一次性设置只在最需要它的时刻打扰，且那一刻给的必须是能走通的那条路）。
    public var minutesNeedsSetup: Bool {
        guard case .failed = minutes.state else { return false }
        if minutes.failureNeedsSetup { return true }
        return !(preferences?().isLLMConfigured(for: .minutes) ?? true)
    }

    /// 「继续这一段」= 新 epoch：序号与水位不重置，丢掉的音频就是没录上（§5.6）。
    public func continueAfterInterruption() async {
        guard sessionID != nil, phase == .interrupted else { return }
        blocked = nil
        lastFailure = nil
        phase = .preparing
        do {
            try await startPipeline(isNewSession: false)
        } catch {
            blocked = Self.blockReason(for: error)
            phase = .interrupted
        }
    }

    /// 暂停 / 继续上行。它**不结束会话**：麦克风还在会话手里，只是不再上行。
    ///
    /// 暂停这一次动作做两件事，顺序不能换（MC-16）：
    /// 1. 先把 `isPaused` 置上，`upload` 立刻不再往下送音频；
    /// 2. 再向服务端切一刀，把在途的那一句结算成独立 item。
    ///
    /// 为什么必须切那一刀：服务端的静音判定（`server_vad`，约 900ms）没到之前
    /// 按下的暂停，等不到静音边界。快速暂停再恢复时，暂停前送的和恢复后送的
    /// 音频会落进同一个 buffer，被并成同一句转录——那句话跨越了根本没录的那段时间，
    /// 是**假的**。切完之后，之后 append 的音频自然进新 buffer。
    ///
    /// 同时落一段停记区间：暂停期间一个字都没录上，不记的话事后看这条记录的人
    /// 会把中间那几分钟当成安静。
    public func togglePause() async {
        if isPaused {
            isPaused = false
            await coordinator.resumeUserPaused()
        } else {
            isPaused = true
            await flushPendingUtterance()
            await coordinator.markUserPaused()
        }
    }

    /// 把缓冲区里在途的那一句结算掉。切不出去也不取消暂停：用户按的是"别录了"，
    /// 不是"重来一次"。这一刀失败最坏是多一句跨界的转录，而界面上的断点仍然如实显示；
    /// 反过来把它当成失败去回滚暂停，界面上的「暂停一下」就变成了一个按了没反应的死按钮。
    private func flushPendingUtterance() async {
        guard let client else { return }
        do {
            try await client.flushPendingUtterance()
        } catch {
            lastFailure = error.localizedDescription
        }
    }

    /// 这一场的来源里有没有麦克风（页头的静音按钮据此决定露不露）。
    public var usesMicrophone: Bool { selection?.usesMicrophone ?? false }

    /// 静音 / 取消静音麦克风这一路（页头那一个按钮，§6.2）。
    ///
    /// 只有"这一场正录着、且来源里确实有麦克风"时才有效：纯本机音频的会议按不动它——
    /// 静音一个没在采的来源是个假装有反馈的死按钮。中断态也算不上"正录着"：那里的设备
    /// 已经释放（§9 第 8 行），静音跟着设备一起归零，不给一个跨中断还亮着的假开关。
    public func toggleMicrophoneMute() {
        guard phase == .recording, usesMicrophone else { return }
        isMicrophoneMuted.toggle()
        audio.setMicrophoneMuted(isMicrophoneMuted)
    }

    // MARK: - 生命周期

    private func startPipeline(isNewSession: Bool) async throws {
        guard let selection, !selection.isEmpty else {
            throw Blocked(reason: .noSourceSelected)
        }
        // 进这一轮先领一枚票，位置在任何一次 `await` **之前**。
        //
        // 整段流程要好几跳（读能力绑定、拿设备、握手、建行），期间用户可能结束这一场，
        // 也可能合法切到下一场。票作废了就意味着"这一轮已经不是当前的了"，它只配回收
        // 自己领到的东西，不配发布任何状态——不改相位、不建记录、不占租约。
        //
        // 放在末尾领票是来不及的：`releaseCapture()` 会 `invalidate()`，
        // 而旧启动回来后又 `begin()` 一枚新令牌，等于把自己重新变回"当前一代"
        // 并把 `phase = .recording` 发布出去（MC-05 / MC-06）。
        let startToken = connectionGeneration.begin()
        let binding = await realtimeCapabilityBindingProvider?()
        if realtimeCapabilityBindingProvider != nil, binding == nil {
            throw Blocked(reason: .serviceNotReady("当前服务未确认实时语音识别能力，请刷新服务信息后重试。"))
        }
        let preferences = preferences?()
        let minutesConfiguration = preferences?.resolvedLLMConfiguration(for: .minutes).configuration

        var profile = coordinator.lastKnownProfile ?? "unknown"
        if let serviceReadiness {
            switch await serviceReadiness() {
            case .notReady:
                // `/readyz` is advisory; the capability binding above is the
                // operation gate and the connection handshake verifies service reachability.
                break
            case .ready(let reported):
                profile = reported ?? profile
            }
        }

        let stream: AsyncStream<AudioChunk>
        do {
            stream = try await audio.start(selection: selection)
        } catch {
            throw Blocked(reason: Self.blockReason(for: error))
        }
        gapCount = 0

        // 分人现在是任务级 opt-in：按用户开关声明，服务端不可用时如实回报失败。
        let wantsDiarization = preferences?.meetingDiarizationEnabled ?? false

        let client = dependencies.makeRealtimeClient(
            MeetingRealtimeClientConfiguration(
                port: port,
                scenePreset: .meeting,
                apiKey: serviceKey,
                diarizationEnabled: wantsDiarization,
                expectedASRRevision: binding?.asrModelRevision
            )
        )
        do {
            try await client.connect()
        } catch {
            await audio.stop()
            throw Blocked(reason: .serviceNotReady(error.localizedDescription))
        }
        guard connectionGeneration.isCurrent(startToken) else {
            // 这一场已经被结束或被换掉了。只回收这一轮自己领到的采集与连接，
            // 不碰相位、不建记录——迟到的启动一旦发布状态，就是把已经结束的会
            // 改回"正在录"，界面与库里都会出现一段根本没发生过的录音。
            await audio.stop()
            await client.close()
            return
        }
        self.client = client

        if isNewSession {
            let record = try await coordinator.createSession(
                SessionDraft(
                    kind: .meeting,
                    engineProfile: profile,
                    audioSource: selection.resolvedSource,
                    diarization: wantsDiarization ? .active : .off,
                    diarizationNote: nil,
                    llmEndpoint: minutesConfiguration?.normalizedBaseURL,
                    llmModel: minutesConfiguration?.model,
                    // §4.1：标题可为空。空着照样开始，不把门槛加回去。
                    title: pendingTitle
                )
            )
            guard connectionGeneration.isCurrent(startToken) else {
                // 极窄的一处：建行那一下也是 `await`。票已经作废的话，
                // 这一行**不能留**——留着就是一条"开过但没录到"的空会，
                // 正是 MC-08 要防的那种"失败却看起来像成功"。
                try? await coordinator.removeSession(id: record.id)
                await audio.stop()
                await client.close()
                return
            }
            sessionID = record.id
            startedAt = record.startedAt
            lines = []
            currentOrdinal = 0
            lineByItem = [:]
            timingQualityApplied = []
            epoch = 0
            coordinator.sessionDidStartRecording(id: record.id)
        } else {
            // 续接：**不新建会话行**，序号从库现场继续（§6.5）。
            await coordinator.resumeAfterInterruption()
            interruption = nil
            interruptedAt = nil
            interruptionNote = nil
        }
        configureLabeling(sessionID: sessionID, enabled: wantsDiarization)

        epoch += 1
        // 新一代从这里开始：此前任何仍在飞的回调都成了旧代。
        let generation = connectionGeneration.begin()
        // 无论新建还是续接，都换一代 item 账本：上一代的 item 与这一代无关。
        transcriptLedger.beginGeneration(generation)
        let previewIdentity = TranscriptPreviewLedger.Identity(
            connection: epoch,
            generation: generation
        )
        self.previewIdentity = previewIdentity
        previewLedger.beginGeneration(
            identity: previewIdentity,
            captureTimelineOffsetSeconds: dependencies.clock.now().timeIntervalSince1970
        )
        partialText = nil
        diarizationDrained = false
        isStoppingIntentionally = false
        isPaused = false
        // 静音状态与设备同生共死：`audio.start` 已经把闸门重置回"能说话"，这里的镜像跟上。
        isMicrophoneMuted = false
        phase = .recording
        // 来源退出之后**自动接回**只发生在这一条路上：来源 App 退出不打断录制，只记一条区间。
        audio.onSystemAudioLost = { [weak self] reason in
            Task { await self?.handleSystemAudioLost(reason) }
        }
        if isNewSession { startSleepObserver() }
        startPump(
            stream: stream,
            client: client,
            generation: generation,
            previewIdentity: previewIdentity
        )
    }

    private func configureLabeling(sessionID: String?, enabled: Bool) {
        guard let sessionID else { return }
        labeling.begin(sessionID: sessionID, enabled: enabled)
    }

    /// 释放这一层的设备与连接。**幂等**，中断与结束两条路都走它。
    private func releaseCapture(drain: Bool = false) async {
        let endingRecordID = sessionID
        let shouldDrain = drain && phase == .recording && client != nil
        if !shouldDrain {
            // 中断路径要立刻断开这一代；录制结束的 drain 则必须让这一代
            // 继续接收已经生成的终态与辅助归属，直到事件泵消费完成。
            connectionGeneration.invalidate()
            uploadPump?.cancel()
            uploadPump = nil
            pump?.cancel()
            pump = nil
        }
        await audio.stop()
        if shouldDrain {
            // AsyncStream 结束后仍会交付缓冲中的 AudioChunk。先把这些块送完，
            // 再向服务端提交 drain，避免最后一块音频落在 commit 之后。
            await uploadPump?.value
            uploadPump = nil
        }
        if let client {
            if shouldDrain {
                do {
                    try await client.drainAndClear(timeout: .seconds(8))
                } catch {
                    lastFailure = error.localizedDescription
                    await markDiarizationDrainFailureIfNeeded(error)
                }
            }
            await client.close()
        }
        if shouldDrain {
            // close 结束事件流；其缓冲区会先被消费。等终态、attribution 与
            // diarization EOF 屏障都经过 MeetingSession 保存 owner 后再失效代次。
            await pump?.value
        } else {
            pump?.cancel()
        }
        if drain, let endingRecordID {
            let report = await waitForPendingSaves(recordID: endingRecordID)
            if !report.isComplete {
                if sessionID == endingRecordID { lastFailure = "部分文字尚未保存，请重试保存。" }
                if coordinator.activeSessionID == endingRecordID, coordinator.occupancy?.kind == .meeting {
                    coordinator.abandonOccupancy()
                }
            }
        }
        if shouldDrain { connectionGeneration.invalidate() }
        pump = nil
        client = nil
        level = 0
        partialText = nil
        // 设备走了，静音跟着走：`audio.stop()` 已经把闸门清掉，镜像不能留在"还静着"上。
        isMicrophoneMuted = false
    }

    private func resetKeepingLines() {
        phase = .idle
        sessionID = nil
        startedAt = nil
        selection = nil
        interruption = nil
        interruptedAt = nil
        interruptionNote = nil
    }

    private func startSleepObserver() {
        guard sleepObserver == nil else { return }
        // 系统睡眠 / 合盖：醒来即中断态，**不自动续**；麦克风与 tap 都要重拿（§9 第 8 行）。
        // 通知源经 `dependencies.powerMonitor` 进来，所以这一条在单测里能触发，
        // 不必真合盖才验得到。
        sleepObserver = dependencies.powerMonitor.startObservingSleep { [weak self] in
            guard let self, self.phase.isLive else { return }
            Task { await self.enterInterruption(.sleep) }
        }
    }

    // MARK: - 上行 / 下行

    private func startPump(
        stream: AsyncStream<AudioChunk>,
        client: any MeetingRealtimeClient,
        generation token: Int,
        previewIdentity: TranscriptPreviewLedger.Identity
    ) {
        uploadPump?.cancel()
        uploadPump = Task { [weak self] in
            for await chunk in stream {
                guard let self else { return }
                guard self.isCurrent(token) else { return }
                await self.upload(chunk, to: client, generation: token)
            }
            guard let self, self.isCurrent(token) else { return }
            await self.captureStreamEnded()
        }

        pump?.cancel()
        pump = Task { [weak self] in
            let events = await client.events()
            for await envelope in events {
                guard let self else { return }
                guard self.isCurrent(token) else { return }
                await self.handle(envelope, identity: previewIdentity)
            }
        }
    }

    /// 这个回调还归当前这一代吗？跨 await 回来之后必须重新问一次——
    /// 中断、结束、重连都可能在这期间换掉状态。
    private func isCurrent(_ token: Int) -> Bool {
        connectionGeneration.isCurrent(token)
    }

    private func upload(
        _ chunk: AudioChunk,
        to client: any MeetingRealtimeClient,
        generation token: Int
    ) async {
        guard isCurrent(token), !isPaused else { return }
        level = chunk.level
        gapCount = audio.gapCount
        do {
            try await client.append(chunk.pcm)
        } catch {
            lastFailure = error.localizedDescription
        }
    }

    private func handle(
        _ envelope: RealtimeEventEnvelope<RealtimeASRClient.Event>,
        identity: TranscriptPreviewLedger.Identity
    ) async {
        guard identity == previewIdentity else { return }
        switch envelope.payload {
        case .ready, .configured, .alignmentFailed,
             .ttsStarted(_, _, _), .ttsTextAccepted(_, _, _, _),
             .ttsAudio(_, _, _), .ttsEnded(_, _, _, _, _):
            // 会议会话不接线 TTS：增量 utterance 属于助手那一层。
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
            let outcome = previewLedger.resolveCommit(
                identity: identity,
                itemID: itemID,
                transcript: transcript
            )
            partialText = previewLedger.visiblePartial
            guard case .commit(let committed) = outcome else { return }
            await commit(committed)
        case .failed(let itemID, let code, let message):
            lastFailure = "\(code)：\(message)"
            let recoveryNote = previewLedger.recoveryNote(identity: identity, itemID: itemID)
            let boundary = previewLedger.boundary(identity: identity, itemID: itemID)
            _ = previewLedger.resolveFailure(identity: identity, itemID: itemID)
            partialText = previewLedger.visiblePartial
            if let recoveryNote {
                persistRecoveryMaterial(recoveryNote, boundary: boundary, identity: identity)
            }
        case .attribution(let itemID, let units, _):
            await applyAttribution(itemID: itemID, units: units, identity: identity)
        case .diarizationFinished:
            diarizationDrained = true
        case .auxiliaryIncomplete(_, let alignmentMissing, let diarizationMissing):
            if diarizationMissing, labeling.isEnabled {
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
                await coordinator.updateSessionDiarization(
                    id: sessionID,
                    state: .degraded,
                    note: note
                )
            }
        case .serverError(let code, let message, _):
            lastFailure = Self.readableError(code: code, message: message)
            if code == "backend_busy" {
                await enterInterruption(.serviceLost, note: lastFailure)
            }
        case .closed(let code):
            await handleUnexpectedClose(code: code)
        }
    }

    /// 对齐（文本 → 采样区间）与分人（采样区间 → 匿名说话人）随后到达。
    /// 先把 `segment_uid` → 行 记进账本，再按 uid 原位改归属；同时补写一次
    /// `timing_quality`。正文与时间码一个字不动（§15.3 第 2 条）。
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
        let line = lines.first { $0.id == entry.lineID }
        enqueueAttribution(
            recordID: sessionID, identity: identity, lineID: entry.lineID, ordinal: entry.ordinal,
            units: units, labelsEnabled: labeling.isEnabled,
            observedStart: line?.start, observedEnd: line?.end
        )
    }

    /// receiver 只接纳冻结目标；正文和辅助 I/O 共用同一个有界 owner。
    private func enqueueAttribution(
        recordID: String, identity: TranscriptPreviewLedger.Identity, lineID: String, ordinal: Int,
        units: [RealtimeASRClient.AttributionUnit], labelsEnabled: Bool,
        observedStart: TimeInterval?, observedEnd: TimeInterval?
    ) {
        let owner: SpeakerLabeling
        if sessionID == recordID, previewIdentity == identity {
            owner = labeling
        } else {
            owner = SpeakerLabeling(coordinator: coordinator, attachLabel: dependencies.attachSpeakerLabel)
            owner.begin(sessionID: recordID, enabled: labelsEnabled)
        }
        let command = owner.freezeAttribution(units: units, lineID: lineID)
        let acoustic: ClosedRange<TimeInterval>?
        if let observedStart, let observedEnd {
            acoustic = TranscriptTimeWindow.aligned(
                observed: .observedOnly(start: observedStart, end: observedEnd),
                units: units, sampleRate: RealtimeASRClient.sampleRate
            )?.speechRange
        } else {
            acoustic = nil
        }
        let accepted = inputPersistence.enqueueProjection(
            recordID: recordID, lineID: lineID, unitCount: units.count, coalescing: false
        ) { [weak self, owner] in
            guard let self else { return }
            let confirmedLabels = await owner.apply(command)
            var savedTiming: ClosedRange<TimeInterval>?
            if let acoustic, !(self.sessionID == recordID && self.timingQualityApplied.contains(lineID)) {
                do {
                    try await self.coordinator.attachAcousticTiming(
                        lineID: lineID, start: acoustic.lowerBound, end: acoustic.upperBound, quality: .aligned
                    )
                    savedTiming = acoustic
                } catch {
                    if self.sessionID == recordID, self.previewIdentity == identity {
                        self.lastFailure = "有一条时间信息未能保存。"
                    }
                }
            }
            guard self.sessionID == recordID, self.previewIdentity == identity else { return }
            if savedTiming != nil { self.timingQualityApplied.insert(lineID) }
            self.lines = self.lines.map { existing in
                guard existing.id == lineID else { return existing }
                var updated = existing
                if confirmedLabels.contains(lineID) {
                    updated.speakerLabel = owner.attributedLabel(forLineID: lineID)
                }
                if let savedTiming {
                    updated.start = savedTiming.lowerBound
                    updated.end = savedTiming.upperBound
                    updated.timingQuality = .aligned
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

    /// 定稿即落库。同一个 `(connection, itemID)` 只落一行，时间来自冻结的
    /// `segment_closed` 输入区间；没有可信时钟映射时保留未知值。
    private func commit(_ item: TranscriptPreviewLedger.CommittedItem) async {
        partialText = previewLedger.visiblePartial
        if let recoveryNote = item.recoveryNote {
            persistRecoveryMaterial(recoveryNote, boundary: item.boundary, identity: item.identity)
            return
        }
        let text = item.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let sessionID, let startedAt else { return }
        guard transcriptLedger.markCommitted(item.itemID) else {
            // 同连接同 item 已定稿：只一条权威行，不重复推进 ordinal（MC-12）。
            return
        }
        let inputTimes = sessionRelativeInputTimes(
            from: item.boundary,
            startedAt: startedAt
        )
        let isEpochStart = epoch > 1 && lines.isEmpty
        acceptTranscript(TranscriptPersistenceQueue.Command(
            sessionID: sessionID, connection: item.identity.connection, itemID: item.itemID,
            generation: item.identity.generation, text: text, source: lineSource, role: .speaker,
            tStart: inputTimes?.start, tEnd: inputTimes?.end, formal: true,
            isInterrupted: false, isDeviceSwitch: isEpochStart,
            timingQuality: .unavailable, observedAt: dependencies.clock.now()
        ))
    }

    @discardableResult
    private func acceptTranscript(
        _ command: TranscriptPersistenceQueue.Command
    ) -> TranscriptPersistenceQueue.Admission {
        let admission = inputPersistence.enqueue(command)
        switch admission {
        case .accepted, .duplicate: break
        case .capacityExceeded:
            admissionLedger.reject(recordID: command.sessionID, text: command.text)
            partialText = command.text
            lastFailure = "记录正在保存，暂时无法保存这句新内容，请先复制。"
        case .invalidIdentity:
            admissionLedger.reject(recordID: command.sessionID, text: command.text)
            partialText = command.text
            lastFailure = "无法确认这句内容属于哪场记录，请先复制。"
        }
        return admission
    }

    private func didSaveTranscript(_ command: TranscriptPersistenceQueue.Command, ordinal: Int) async {
        if sessionID == command.sessionID, !command.formal,
           lastFailure?.contains("正在保留恢复内容") == true {
            lastFailure = "有一句话没有拿到定稿正文，已原样保留恢复内容（不进正式纪要）。"
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
                lines.append(
                    Line(
                        id: command.lineID,
                        ordinal: ordinal,
                        text: command.text,
                        start: command.tStart ?? 0,
                        end: command.tEnd ?? 0,
                        speakerLabel: command.speakerLabel,
                        source: command.source,
                        isDeviceSwitch: command.isDeviceSwitch,
                        timingQuality: command.timingQuality
                    )
                )
                lines.sort { $0.ordinal < $1.ordinal }
            }
        }
        guard let payload = pendingAttributions.take(recordID: command.sessionID, identity: itemIdentity),
              command.formal else { return }
        enqueueAttribution(
            recordID: command.sessionID, identity: identity, lineID: command.lineID, ordinal: ordinal,
            units: payload.units, labelsEnabled: payload.labelsEnabled,
            observedStart: command.tStart, observedEnd: command.tEnd
        )
    }

    /// 空 final 的恢复材料**落成 partial 行**（MA-02 / MC-11）。
    ///
    /// `partial` 的既有语义正好就是我们要的：行存得下来、重启后还在、
    /// 而 `coordinator.lines(sessionID:)` 默认 `includePartial: false`
    /// 所以它**不会进正式纪要**、也不会进分享包。
    /// 只放在一行提示文字里是不够的——用户看到提示后没法把那句原文取回来。
    private func persistRecoveryMaterial(
        _ note: TranscriptPreviewLedger.RecoveryNote,
        boundary: TranscriptPreviewLedger.Boundary?,
        identity: TranscriptPreviewLedger.Identity
    ) {
        guard let sessionID, let startedAt else {
            partialText = note.text
            lastFailure = "有一句话没有拿到定稿正文，请先复制。"
            return
        }
        let inputTimes = sessionRelativeInputTimes(from: boundary, startedAt: startedAt)
        let admission = acceptTranscript(TranscriptPersistenceQueue.Command(
            sessionID: sessionID, connection: identity.connection, itemID: note.itemID,
            generation: identity.generation, text: note.text, source: lineSource, role: .speaker,
            tStart: inputTimes?.start, tEnd: inputTimes?.end, formal: false,
            isInterrupted: false, timingQuality: .unavailable, observedAt: dependencies.clock.now()
        ))
        switch admission {
        case .accepted, .duplicate:
            lastFailure = "有一句话没有拿到定稿正文，正在保留恢复内容（不进正式纪要）。"
        case .capacityExceeded, .invalidIdentity: break
        }
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

    /// 每一行标来源（§14.1 的记录口径）：**合流出来的行只能记 `mixed`**——
    /// 服务端看到的是混完之后的一条流，逐句归属到"对方说的 / 屋里说的"在这条链路上无从判断。
    /// 写 `microphone` 会是一个看起来像事实的猜测。
    private var lineSource: SessionLineSource {
        switch audio.resolvedSource {
        case .microphone: .microphone
        case .system: .system
        case .mixed: .mixed
        }
    }

    /// 分人档位下 `timing_quality` 由归属单元给；没开分人时不写（§8.2 的唯一降级点）。
    // MARK: - 中断（四类，§5.6 / §16.7）

    private func handleUnexpectedClose(code: Int?) async {
        guard !isStoppingIntentionally, phase.isLive else { return }
        let note = code.map { "识别连接断开了（\($0)）。" } ?? "识别连接断开了。"
        await enterInterruption(.serviceLost, note: note)
    }

    private func markDiarizationDrainFailureIfNeeded(_ error: Error) async {
        guard labeling.isEnabled,
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

    /// 采集流自己结束了：设备被拔、引擎停了这一类。**不是来源 App 退出**
    /// （那一类在 `handleSystemAudioLost` 里，会自动接回）。它需要人决定怎么继续。
    private func captureStreamEnded() async {
        guard !isStoppingIntentionally, phase.isLive else { return }
        await enterInterruption(.sourceLost, note: "音频来源停下来了（设备被拔或引擎停了）。")
    }

    /// 本机音频那一路断了自己接回来。**这是唯一会自动接回的一类**（§9 第 9 行）：
    /// 被 tap 的 App 退出不打断录制，只记一条区间 + 一句可读的话。
    private func handleSystemAudioLost(_ reason: String) async {
        guard !isStoppingIntentionally, phase.isLive else { return }
        _ = await coordinator.markInterruption(.sourceLost, atOrdinal: currentOrdinal)
        let reconnected = await audio.restartSystemAudio()
        await coordinator.resumeAfterInterruption()
        if reconnected {
            // 只有真接回来了才算"自动接回过一次"：计数是给界面看的事实，
            // 接不回来却 +1 就是在说谎。
            reconnectedSources += 1
            lastFailure = "本机音频的来源 App 退出过（\(reason)）；已经按 App 的标识接回，录制没有停。"
        } else {
            lastFailure = "本机音频的那一路断开了（\(reason)），也没有接回来；"
                + "麦克风这一路还在录，已经定稿的文字记录都在。"
        }
    }

    private func enterInterruption(_ reason: SessionInterruptionReason, note: String? = nil) async {
        guard phase.isLive else { return }
        if let note { lastFailure = note }
        interruptionNote = note
        isStoppingIntentionally = true
        await releaseCapture()
        isStoppingIntentionally = false
        _ = await coordinator.markInterruption(reason, atOrdinal: currentOrdinal)
        interruption = reason
        interruptedAt = dependencies.clock.now()
        phase = .interrupted
    }

    /// 中断期间到底停在哪一刻（页面上那行 `00:12:40 起中断`）。
    public var interruptedElapsed: TimeInterval? {
        guard let interruptedAt, let startedAt else { return nil }
        return max(0, interruptedAt.timeIntervalSince(startedAt))
    }

    // MARK: - 说话人标注（会中 / 会后同一件事的两种节奏，§6.2）

    /// 会中的轻量入口：改一位说话人的显示名。**只写 `speaker_name`**，正文一个字不动。
    public func renameSpeaker(label: String, to name: String) async {
        await labeling.rename(label: label, to: name)
    }

    /// 标记为「我」：只标记本机麦克风那一路（§6.2.1）。
    public func markAsMe(label: String) async {
        await labeling.markAsMe(label: label)
    }

    /// 与另一位合并：**显示名层面的别名**，可回溯（`已并入 A`）。
    public func merge(label: String, into target: String) async {
        await labeling.merge(label: label, into: target)
    }

    /// 把一段行从某位说话人拆出来（唯一会改归属列的用户动作）。
    public func split(lineIDs: [String], to label: String?) async {
        await labeling.split(lineIDs: lineIDs, to: label)
    }

    // MARK: - 小工具

    private static func blockReason(for error: Error) -> BlockReason {
        if let blocked = error as? Blocked { return blocked.reason }
        if let blocked = error as? MeetingAudioBlocked {
            switch blocked.reason {
            case .noSourceSelected: return .noSourceSelected
            case .microphoneDenied: return .microphoneDenied
            case .systemAudioUnavailable(let message): return .systemAudioUnavailable(message)
            case .engineFailed(let message): return .streamFailed(message)
            }
        }
        return .streamFailed(error.localizedDescription)
    }

    private static func readableError(code: String, message: String) -> String {
        switch code {
        case "backend_busy":
            "语音服务同时在跑的会话已经满了。已经定稿的文字记录都还在。"
        case "diarization_not_available":
            "这场没有标出谁在说话；正文照常记录。"
        default:
            "\(code)：\(message)"
        }
    }

    /// 本场时长（走时由协调器给，不用墙钟差值做显示）。
    public var elapsed: TimeInterval { coordinator.elapsed }

    /// 说话人数（分人已标出的那几位）。
    public var speakerCount: Int { labeling.labels.count }

    /// 已存好的段数（界面状态带上那个数字）。
    public var storedLineCount: Int { max(lines.count, coordinator.lineWatermark) }
}
