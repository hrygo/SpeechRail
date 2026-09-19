import AppKit
import Foundation
import Observation

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
                AudioSourceCoordinator.BlockReason.noSourceSelected.detail
            case .serviceNotReady(let message):
                message
            case .serviceBusy(let message):
                message
            case .occupiedBy:
                "麦克风同一时刻只能由一个会话使用；可以先结束那个会话，或者等它说完。"
            case .microphoneDenied:
                AudioSourceCoordinator.BlockReason.microphoneDenied.detail
            case .systemAudioUnavailable(let message):
                AudioSourceCoordinator.BlockReason.systemAudioUnavailable(message).detail
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
    public private(set) var selection: AudioSourceCoordinator.Selection?
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
        selection: AudioSourceCoordinator.Selection? = nil,
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

    public var serviceReadiness: (@MainActor () async -> ServiceReadiness)?
    public var preferences: (@MainActor () -> SessionPreferences)?
    private let coordinator: SessionCoordinator
    private let audio = AudioSourceCoordinator()
    private let port: Int
    private let serviceKey: String?

    private var client: RealtimeASRClient?
    private var pump: Task<Void, Never>?
    private var sleepObserver: NSObjectProtocol?
    private var commitCursor: Date?
    private var pendingItem: (start: Date, end: Date)?
    private var currentOrdinal = 0
    private var committedItemIDs: Set<String> = []
    private var diarizationDrained = false
    private var isStoppingIntentionally = false
    /// 本场第几个 epoch（一次 WS 连接 = 一个 epoch，§5.2 账本规则 1）。
    private var epoch = 0

    public init(coordinator: SessionCoordinator, port: Int = 8201, apiKey: String? = nil) {
        self.coordinator = coordinator
        self.port = port
        self.serviceKey = apiKey
        self.labeling = SpeakerLabeling(coordinator: coordinator)
        self.minutes = MinutesGenerator(coordinator: coordinator)
        self.innerOS = InnerOSSession(coordinator: coordinator)
    }

    // MARK: - 入口

    /// 页面主按钮：选好来源之后从这里进（§6.2 的空态度）。
    public func start(selection: AudioSourceCoordinator.Selection) async {
        self.selection = selection
        blocked = nil
        lastFailure = nil
        await coordinator.requestStart(.meeting)
    }

    /// 协调器的 `starter`：真的拿设备、连服务。
    public func beginCapture() async throws {
        phase = .preparing
        blocked = nil
        do {
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
        await releaseCapture()
    }

    /// 结束这一场并整理：EOF 屏障 → 释放设备 → 封存 → 排纪要（§8.2 的最后三步）。
    public func finishAndSummarize() async {
        guard sessionID != nil else {
            await coordinator.stopCapture(endingWith: .user)
            return
        }
        isStoppingIntentionally = true
        // ① EOF 屏障：先要分人收尾，再断连接。顺序反了会丢掉最后半句的归属（§14.3）。
        if labeling.isEnabled {
            try? await client?.finishDiarization()
            await waitForDiarizationDrain()
        }
        let id = sessionID
        // ② 设备在这里释放，**早于**封存：整理期间不该还占着麦克风（R4）。
        await releaseCapture()
        phase = .processing
        await coordinator.stopCapture(endingWith: .user)
        await coordinator.finishProcessing(endReason: .user)
        phase = .archived
        guard let id else { return }
        // ③ 整理：转录已封存，失败也不影响它（§9 第 18 行）。
        let configuration = preferences?().minutesConfiguration ?? LLMConfiguration()
        await minutes.generate(sessionID: id, configuration: configuration)
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
        return !(preferences?().isLLMConfigured ?? true)
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
    public func togglePause() {
        isPaused.toggle()
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
        let preferences = preferences?()

        var profile = coordinator.lastKnownProfile ?? "unknown"
        if let serviceReadiness {
            switch await serviceReadiness() {
            case .notReady(let message):
                throw Blocked(reason: .serviceNotReady(message))
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

        // 分人：档位给不出时**不声明**，并如实写一句（§14.3 的档位门禁）。
        let gateNote = SessionPreferences.diarizationGateNote(for: profile)
        let wantsDiarization = (preferences?.meetingDiarizationEnabled ?? false) && gateNote == nil

        let client = RealtimeASRClient(
            port: port,
            // 会议 900 ms：要整句，不要抢速度（§5.3）。
            silenceDurationMilliseconds: 900,
            diarizationEnabled: wantsDiarization,
            apiKey: serviceKey
        )
        do {
            try await client.connect()
        } catch {
            await audio.stop()
            throw Blocked(reason: .serviceNotReady(error.localizedDescription))
        }
        self.client = client

        if isNewSession {
            let record = try await coordinator.createSession(
                SessionDraft(
                    kind: .meeting,
                    engineProfile: profile,
                    audioSource: selection.resolvedSource,
                    diarization: wantsDiarization ? .active : (gateNote == nil ? .off : .unavailable),
                    diarizationNote: gateNote,
                    llmEndpoint: preferences?.minutesConfiguration.normalizedBaseURL,
                    llmModel: preferences?.minutesConfiguration.model
                )
            )
            sessionID = record.id
            startedAt = record.startedAt
            lines = []
            currentOrdinal = 0
            committedItemIDs = []
            epoch = 0
            coordinator.sessionDidStartRecording(id: record.id)
        } else {
            // 续接：**不新建会话行**，序号从库现场继续（§6.5）。
            await coordinator.resumeAfterInterruption()
            interruption = nil
            interruptedAt = nil
            interruptionNote = nil
        }
        configureLabeling(sessionID: sessionID, enabled: wantsDiarization, gateNote: gateNote)

        epoch += 1
        commitCursor = Date()
        pendingItem = nil
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
        startPump(stream: stream, client: client)
    }

    private func configureLabeling(sessionID: String?, enabled: Bool, gateNote: String?) {
        guard let sessionID else { return }
        labeling.begin(sessionID: sessionID, enabled: enabled)
        if let gateNote { labeling.markUnavailable(note: gateNote) }
    }

    /// 释放这一层的设备与连接。**幂等**，中断与结束两条路都走它。
    private func releaseCapture() async {
        pump?.cancel()
        pump = nil
        await audio.stop()
        if let client { await client.close() }
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
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase.isLive else { return }
                Task { await self.enterInterruption(.sleep) }
            }
        }
    }

    // MARK: - 上行 / 下行

    private func startPump(stream: AsyncStream<AudioChunk>, client: RealtimeASRClient) {
        pump?.cancel()
        pump = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    for await chunk in stream {
                        guard let self else { return }
                        await self.upload(chunk, to: client)
                    }
                    await self?.captureStreamEnded()
                }
                group.addTask { [weak self] in
                    let events = await client.events()
                    for await event in events {
                        guard let self else { return }
                        await self.handle(event)
                    }
                }
                await group.waitForAll()
            }
        }
    }

    private func upload(_ chunk: AudioChunk, to client: RealtimeASRClient) async {
        guard !isStoppingIntentionally, !isPaused else { return }
        level = chunk.level
        gapCount = audio.gapCount
        do {
            try await client.append(chunk.pcm)
        } catch {
            lastFailure = error.localizedDescription
        }
    }

    private func handle(_ event: RealtimeASRClient.Event) async {
        switch event {
        case .ready, .configured, .speechStarted, .speechStopped, .segment, .responseAudio,
             .responseDone:
            break
        case .committed:
            let now = Date()
            pendingItem = (start: commitCursor ?? now, end: now)
            commitCursor = now
        case .partial(_, let delta):
            guard !delta.isEmpty else { return }
            partialText = (partialText ?? "") + delta
        case .completed(let itemID, let transcript, let units):
            await commit(itemID: itemID, transcript: transcript, units: units)
        case .failed(_, let code, let message):
            lastFailure = "\(code)：\(message)"
            partialText = nil
        case .attribution(_, let units, let links):
            await labeling.apply(units: units)
            labeling.noteSuggestions(links)
            // 归属修订不改正文，所以它更新的是内存里的 chip，不新增行（§15.3 第 2 条）。
            if !lines.isEmpty {
                lines = lines.map { line in
                    var updated = line
                    if let label = labeling.attributedLabel(forLineID: line.id) {
                        updated.speakerLabel = label
                    }
                    return updated
                }
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
        case .diarizationDone:
            diarizationDrained = true
        case .serverError(let code, let message):
            lastFailure = Self.readableError(code: code, message: message)
            if code == "backend_busy" {
                await enterInterruption(.serviceLost, note: lastFailure)
            }
        case .closed(let code):
            await handleUnexpectedClose(code: code)
        }
    }

    /// 定稿即落库。同一个 `item_id` 只落一行（幂等在能力层，不在库里，§15.7 R2 ①）。
    private func commit(
        itemID: String,
        transcript: String,
        units: [RealtimeASRClient.AttributionUnit]
    ) async {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        partialText = nil
        defer { pendingItem = nil }
        guard !text.isEmpty, let sessionID, let startedAt else { return }
        if !itemID.isEmpty {
            guard !committedItemIDs.contains(itemID) else { return }
            committedItemIDs.insert(itemID)
        }
        let window = pendingItem ?? (start: commitCursor ?? startedAt, end: Date())
        // 归属先算：`LineDraft` 里就要带上它，否则修订事件到达之前这一行看起来是"未标注"。
        let initialLabel = units.compactMap { unit -> String? in
            guard let speaker = unit.speaker, !speaker.isEmpty else { return nil }
            return speaker
        }.first
        let isEpochStart = epoch > 1 && lines.isEmpty
        let lineID = UUID().uuidString
        let ordinal: Int
        do {
            ordinal = try await coordinator.appendLine(
                LineDraft(
                    sessionID: sessionID,
                    role: .speaker,
                    text: text,
                    source: lineSource,
                    speakerLabel: initialLabel,
                    tStart: window.start.timeIntervalSince(startedAt),
                    tEnd: window.end.timeIntervalSince(startedAt),
                    isDeviceSwitch: isEpochStart,
                    timingQuality: Self.timingQuality(from: units)
                ),
                id: lineID
            )
        } catch {
            committedItemIDs.remove(itemID)
            lastFailure = error.localizedDescription
            return
        }
        // 行已经在了，这时候才把 `segment_uid` → 行 的对应关系记进账本。
        labeling.register(units: units, lineID: lineID, ordinal: ordinal)
        currentOrdinal = ordinal
        lines.append(
            Line(
                id: lineID,
                ordinal: ordinal,
                text: text,
                start: window.start.timeIntervalSince(startedAt),
                end: window.end.timeIntervalSince(startedAt),
                speakerLabel: initialLabel,
                source: lineSource,
                isDeviceSwitch: isEpochStart
            )
        )
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
    private static func timingQuality(
        from units: [RealtimeASRClient.AttributionUnit]
    ) -> SessionTimingQuality? {
        guard !units.isEmpty else { return nil }
        return units.contains { $0.timingQuality == "aligned" } ? .aligned : .unavailable
    }

    // MARK: - 中断（四类，§5.6 / §16.7）

    private func handleUnexpectedClose(code: Int?) async {
        guard !isStoppingIntentionally, phase.isLive else { return }
        let note = code.map { "识别连接断开了（\($0)）。" } ?? "识别连接断开了。"
        await enterInterruption(.serviceLost, note: note)
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
        interruptedAt = Date()
        phase = .interrupted
    }

    /// 中断期间到底停在哪一刻（页面上那行 `00:12:40 起中断`）。
    public var interruptedElapsed: TimeInterval? {
        guard let interruptedAt, let startedAt else { return nil }
        return max(0, interruptedAt.timeIntervalSince(startedAt))
    }

    private func waitForDiarizationDrain(timeout: Duration = .seconds(6)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !diarizationDrained, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(80))
        }
        if !diarizationDrained {
            // 未对齐不是错误：正文照常，只是时间码要说实话（§8.2 唯一允许降级的位置）。
            lastFailure = "说话人编号没能在结束前全部对齐；文字记录还在，时间码可能不完整。"
        }
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
        if let blocked = error as? AudioSourceCoordinator.Blocked {
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
            "这一档不标说话人；正文照常记录。"
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
