import Foundation
import Observation
import SpeechRailControlKit

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
//   - **`timing_quality` 写 NULL**。它来自 `attribution_units`，属于分人那一步（阶段 4）；
//     字幕这一档没有对齐结果，就不该假装有。

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
    /// 读服务就绪情况。`notReady` 时字幕带以受阻态出现，且**不建会话记录**。
    /// 读的是 `AppModel.health`，所以它在主 actor 上。
    public var serviceReadiness: (@MainActor () async -> ServiceReadiness)?
    /// 音频来源。默认麦克风；核对时换成文件源，链路其余部分完全不变。
    public var audioSourceFactory: @MainActor () -> AudioChunkSource = { MicrophoneCapture() }
    /// 这一场要不要开分人。**每场一次**：契约规定只能在首个 PCM 之前协商。
    /// 默认关（§14.3 的开关粒度）。
    public var diarizationPreference: @MainActor () -> Bool = { false }
    /// 档位能不能分人：给不出原因就说明可以。`light` 档返回一句人话，
    /// 于是"开关置灰 + 写明原因"两侧说法一致（§14.3）。
    public var diarizationGate: @MainActor () -> String? = { nil }

    private let coordinator: SessionCoordinator
    /// 分人归属账本。会议与字幕共用底座，这里持有的是本场那一个实例。
    public let labeling: SpeakerLabeling
    private let port: Int
    private let apiKey: String?

    private var source: AudioChunkSource?
    private var client: RealtimeASRClient?
    private var pump: Task<Void, Never>?
    private var sessionStartedAt: Date?
    /// 上一段音频的终点（墙钟）。下一行从这里开始。
    private var commitCursor: Date?
    private var pendingItem: (start: Date, end: Date)?
    /// 终态事件计数：收尾时用来判断"最后半句到底回来了没有"。
    private var terminalCount = 0
    private var isStoppingIntentionally = false
    private var currentOrdinal = 0
    /// 本次会话已经落库的 `item_id`。**序号唯一索引拦不住重复的 `completed`**——
    /// 序号是库现场取的 `MAX+1`（§15.7 R2 ①），同一个 item 到两次就会多出一行；
    /// 幂等这一层因此在客户端，而不是在库里。
    private var committedItemIDs: Set<String> = []
    /// 这一场是否协商过分人（决定了结束时要等 EOF 屏障）。
    private var diarizationActive = false
    /// `speechrail.diarization.done` 是否已经到达。
    private var diarizationDrained = false

    public init(
        coordinator: SessionCoordinator,
        port: Int = 8201,
        apiKey: String? = nil,
        audioSourceFactory: (@MainActor () -> AudioChunkSource)? = nil
    ) {
        self.coordinator = coordinator
        self.labeling = SpeakerLabeling(coordinator: coordinator)
        self.port = port
        self.apiKey = apiKey
        if let audioSourceFactory {
            self.audioSourceFactory = audioSourceFactory
        }
    }

    public var isRunning: Bool { phase == .running || phase == .preparing }

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
        // 档位是**服务的事实**，不是会话的选择：写进记录的是本次读到的那一个，
        // 读不到写 `unknown`（不为了一个标签去阻塞会话启动）。
        var profile = "unknown"
        if let serviceReadiness {
            switch await serviceReadiness() {
            case .notReady(let message):
                throw Blocked(.serviceNotReady(message))
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
        // 档位不支持时不开，也不假装开——开关与说明由 `diarizationGate` 给同一句人话。
        let wantedDiarization = diarizationPreference()
        let gateNote = wantedDiarization ? diarizationGate() : nil
        let diarizationEnabled = wantedDiarization && gateNote == nil
        diarizationActive = diarizationEnabled
        diarizationDrained = false

        let client = RealtimeASRClient(
            port: port,
            silenceDurationMilliseconds: 400,
            diarizationEnabled: diarizationEnabled,
            apiKey: apiKey,
            chunkDurationMilliseconds: TranscriptionSessionUpdate.captionChunkDurationMilliseconds
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
        commitCursor = startedAt
        lines = []
        partialText = nil
        terminalCount = 0
        currentOrdinal = 0
        committedItemIDs = []
        isStoppingIntentionally = false
        do {
            let record = try await coordinator.createSession(
                SessionDraft(
                    kind: .captions,
                    engineProfile: profile,
                    audioSource: .microphone,
                    diarization: diarizationEnabled ? .active : (wantedDiarization ? .unavailable : .off),
                    diarizationNote: gateNote,
                    startedAt: startedAt
                )
            )
            sessionID = record.id
            labeling.begin(sessionID: record.id, enabled: diarizationEnabled)
            if let gateNote { labeling.markUnavailable(note: gateNote) }
            coordinator.sessionDidStartRecording(id: record.id)
        } catch {
            await client.close()
            source.stop()
            self.source = nil
            self.client = nil
            throw Blocked(.storeUnavailable(error.localizedDescription))
        }

        phase = .running
        startPump(stream: stream, client: client)
    }

    /// 协调器的 stopper：把最后半句交出去、关掉连接。**不封存记录**——那是协调器接下来做的事。
    ///
    /// 唯一要挡的是重入（`:ending` 里还等着最后一句）。其余相位都照做：`idle` 时也把浮层
    /// 收起来——协调器决定"这次会话结束了"，浮层就不该继续挂在屏幕上。
    public func stopCapture() async {
        guard phase != .ending else { return }
        phase = .ending
        isStoppingIntentionally = true
        source?.stop()
        source = nil
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
        pump?.cancel()
        pump = nil
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
        pendingItem = nil
        commitCursor = nil
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
        source?.stop()
        source = nil
        if let client {
            do {
                try await client.drainAndClear(timeout: .seconds(8))
            } catch {
                lastFailure = error.localizedDescription
                await markDiarizationDrainFailureIfNeeded(error)
            }
            await client.close()
        }
        pump?.cancel()
        pump = nil
        client = nil
        level = 0
        // 未定稿的那一句不写成半截行：库里的行只认定稿（§15 的 `status` 取值域）。
        partialText = nil
        pendingItem = nil
        phase = .paused
    }

    public func resume() async {
        guard phase == .paused else { return }
        commitCursor = Date()
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
            commitCursor = Date()
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
        let client = RealtimeASRClient(
            port: port,
            silenceDurationMilliseconds: 400,
            diarizationEnabled: diarizationActive,
            apiKey: apiKey,
            chunkDurationMilliseconds: TranscriptionSessionUpdate.captionChunkDurationMilliseconds
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
        startPump(stream: stream, client: client)
    }

    // MARK: - 采集 → 上行

    private func startPump(stream: AsyncStream<AudioChunk>, client: RealtimeASRClient) {
        pump?.cancel()
        pump = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    for await chunk in stream {
                        guard let self else { return }
                        await self.upload(chunk, to: client)
                    }
                }
                group.addTask { [weak self] in
                    let events = await client.events()
                    for await envelope in events {
                        guard let self else { return }
                        await self.handle(envelope)
                    }
                }
                await group.waitForAll()
            }
        }
    }

    private func upload(_ chunk: AudioChunk, to client: RealtimeASRClient) async {
        guard !isStoppingIntentionally else { return }
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
        _ envelope: RealtimeEventEnvelope<RealtimeASRClient.Event>
    ) async {
        switch envelope.payload {
        case .ready, .configured, .speechStarted, .speechStopped:
            break
        case .committed:
            let now = Date()
            pendingItem = (start: commitCursor ?? now, end: now)
            commitCursor = now
        case .partial(_, let delta):
            guard !delta.isEmpty else { return }
            partialText = (partialText ?? "") + delta
        case .partialSnapshot(_, _, let text):
            partialText = text.isEmpty ? nil : text
        case .segment:
            // 分人扩展**不发** `.segment`（契约：避免双写）。真收到说明这一档没协商扩展，
            // 那就不按它切行：一次 utterance 一行，时间码取上面那份提交边界（与服务端 VAD 同源）。
            break
        case .completed(let itemID, let transcript, let units):
            terminalCount += 1
            await commit(itemID: itemID, transcript: transcript, units: units)
        case .failed(_, let code, let message):
            terminalCount += 1
            lastFailure = "\(code)：\(message)"
            partialText = nil
        case .attribution(_, let units, let links):
            await labeling.apply(units: units)
            labeling.noteSuggestions(links)
            // 归属修订不改正文，所以它**不留新行**：库里那一行的正文与时间码都不动（§15.3 第 2 条）。
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
                await coordinator.updateSessionDiarization(id: sessionID, state: .degraded, note: note)
            }
        case .diarizationDone:
            diarizationDrained = true
        case .responseAudio, .responseDone(_, _):
            // TTS 不属于这一层（字幕与会议都不说话）。
            break
        case .serverError(let code, let message, _, _, _, _):
            await handleServerError(code: code, message: message)
        case .cleared:
            break
        case .closed(let code):
            await handleUnexpectedClose(code: code)
        }
    }

    /// 定稿即落库。**同一个 `item_id` 只落一行**：序号是库现场取的 `MAX+1`
    /// （§15.7 R2 ①），所以"同一个 `completed` 到了两次"不会被唯一索引拦住，
    /// 会多出一行——幂等在这里，不在库里。
    private func commit(
        itemID: String,
        transcript: String,
        units: [RealtimeASRClient.AttributionUnit] = []
    ) async {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        partialText = nil
        defer { pendingItem = nil }
        guard !text.isEmpty, let sessionID, let startedAt = sessionStartedAt else { return }
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
        let timingQuality = Self.timingQuality(from: units)
        let lineID = UUID().uuidString
        let ordinal: Int
        do {
            ordinal = try await coordinator.appendLine(
                LineDraft(
                    sessionID: sessionID,
                    role: .speaker,
                    text: text,
                    source: .microphone,
                    speakerLabel: initialLabel,
                    tStart: window.start.timeIntervalSince(startedAt),
                    tEnd: window.end.timeIntervalSince(startedAt),
                    timingQuality: timingQuality
                ),
                id: lineID
            )
        } catch {
            // 没写成就不算处理过：同一个 item 再来一次还要有机会落库。
            committedItemIDs.remove(itemID)
            lastFailure = error.localizedDescription
            return
        }
        // 行已经在了，这时候才把 `segment_uid` → 行 的对应关系记进账本：
        // 之后的 `diarization.updated` 就是按这张表原位修订的。
        labeling.register(units: units, lineID: lineID, ordinal: ordinal)
        currentOrdinal = ordinal
        lines.append(
            Line(
                id: lineID,
                ordinal: ordinal,
                text: text,
                start: window.start.timeIntervalSince(startedAt),
                end: window.end.timeIntervalSince(startedAt),
                speakerLabel: initialLabel
            )
        )
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
        pump?.cancel()
        pump = nil
        if let client {
            await client.close()
            self.client = nil
        }
        level = 0
        partialText = nil
        pendingItem = nil
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
