import Foundation
import Observation

// 会话所有权、阶段与设备租约的唯一持有者（TECHNICAL-DESIGN §5.2）。
//
// 三条不能违反的规矩：
//   1. **所有权不跟随页面**（§5.3）。切到「语音助手」是浏览，不是开始；三个能力谁也
//      不因为「用户在看这一页」而取设备。
//   2. **App 不做常占**（§5.3.1）。空闲就是真的没有麦克风、没有系统录音 tap、没有音频引擎；
//      获取只发生在用户按了开始之后，释放在会话离开时（归档 / 中断 / 整理开始之前）。
//   3. **中断是事件，不是阶段**（§15.7）。库里 `session.state` 没有 `interrupted`；
//      这里 `.interrupted` 是界面相位，事实落在 `session_interruption` 一行。

@MainActor
@Observable
public final class SessionCoordinator {
    /// 界面相位。与「库里怎么写」是两件不同的事，见文件头第 3 条。
    public enum Phase: String, Sendable {
        case idle
        case preparing
        case recording
        case processing
        case interrupted
        case archived

        public var isActive: Bool {
            switch self {
            case .idle, .archived: false
            case .preparing, .recording, .processing, .interrupted: true
            }
        }

        /// 此刻是否应该持着设备。整理阶段**已经释放**（§5.3 表：`processing` 一列写的就是「已释放」）。
        public var holdsDevices: Bool {
            switch self {
            case .preparing, .recording: true
            case .idle, .processing, .interrupted, .archived: false
            }
        }
    }

    /// 谁在用麦克风。空闲时没有会话占用，且设备一定已释放。
    public struct Occupancy: Equatable, Sendable {
        public var kind: SessionKind
        public var isProcessing: Bool
    }

    /// 助手专属的结束目标（VA-01）。
    ///
    /// 文字助手没有设备占用，结束必须按自己的 recordID 收口；
    /// 语音助手还必须核对 kind + leaseID，避免旧助手的迟到结束清掉新会话。
    public struct AssistantEndTarget: Equatable, Sendable {
        public var recordID: String?
        public var leaseID: UUID?
        public var endTaskID: UUID

        public init(recordID: String? = nil, leaseID: UUID? = nil, endTaskID: UUID = UUID()) {
            self.recordID = recordID
            self.leaseID = leaseID
            self.endTaskID = endTaskID
        }
    }

    public enum AssistantEndResult: Equatable, Sendable {
        case ended(recordID: String?)
        case superseded
        case mismatch
        case noConversation
    }

    /// 这个能力还没有接线（语音助手 / 会议助手在阶段 5 / 6 之前）。
    ///
    /// 存在的理由是**那条"静默成功"的路**：`starter` 的契约是「抛错 = 受阻」，返回
    /// `Void` 会被读成"已经开始采集了"。于是界面显示在录、实际什么也没拿到——这种谎
    /// 比"还没做"难查得多，所以在接线之前，未接线的 kind 必须抛。
    public struct CapabilityNotWired: LocalizedError, Equatable, Sendable {
        public var kind: SessionKind

        public init(kind: SessionKind) {
            self.kind = kind
        }

        public var errorDescription: String? {
            "\(kind.title)的采集还没有接上。"
        }
    }

    /// 一次「要开始另一个会话」的确认。`sheet` 不是 `alert`：需要说明与选项（§6.4）。
    public struct Confirmation: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var message: String
        public var confirmTitle: String
        /// 「以后不再询问」只对助手 / 字幕生效；会议录制永远确认（防误停）。
        public var allowsDoNotAskAgain: Bool
    }

    public enum Decision: Equatable, Sendable {
        case granted
        case alreadyActive(SessionKind)
        case needsConfirmation(Confirmation)
    }

    /// 等待确认的那件事。两个触发点共用同一个确认形状（§6.4：sheet 不是 alert）。
    public enum PendingAction: Equatable, Sendable {
        case switchTo(SessionKind)
        case endCurrentSession
    }

    // MARK: - 状态

    public private(set) var phase: Phase = .idle
    public private(set) var occupancy: Occupancy?
    /// 正在进行的会话 id（库里的行）。**只在首个 PCM 已发送之后才有值**（§5.2）。
    public private(set) var activeSessionID: String?
    public private(set) var startedAt: Date?
    public private(set) var lastInterruption: SessionInterruptionReason?
    /// 设备租约：按功能启用、功能离开释放。阶段 3/6 把真正的采集挂到这一对动作上。
    public private(set) var holdsDeviceLease = false
    /// 当前设备占用的租约身份（VA-01）。
    ///
    /// `begin` 成功时生成，`finalize` / `abandonOccupancy` 时清空。
    /// preparing 阶段尚无 recordID 也能凭它锁定租约；助手专属结束必须同时核对
    /// kind + leaseID + recordID，避免旧助手的迟到结束清掉新会话的占用。
    public private(set) var activeLeaseID: UUID?
    /// 正在等用户回答的那一件事；`nil` 表示没有待确认的动作。
    public private(set) var pendingAction: PendingAction?
    public private(set) var pendingConfirmation: Confirmation?
    /// 开库失败时的可读结论。库里读不出来时界面要给一条结论，而不是空白列表。
    public private(set) var storeFailure: String?
    /// 走时。占用期间每秒推进一次，供侧边栏与状态带显示「12:04」。
    public private(set) var elapsed: TimeInterval = 0
    /// 当前 epoch 内已经落库的行数水位（中断区间与「提问时的转录水位」都用它）。
    public private(set) var lineWatermark = 0
    /// 当前那一段用户暂停的区间 id（MC-16）。开着时非空，恢复/收尾时合上并清空。
    ///
    /// 停在协调器而不是界面上，是因为它有**收尾兜底**的义务：用户暂停着直接结束会议时，
    /// 区间得在这里合上，否则库里会留下一条 `resumed_at` 永远为空的暂停记录，
    /// 事后读出来就成了"这场的记录停在中途且没恢复"。
    private var pauseInterruptionID: String?
    /// 最近一次读到的服务规格组合。它是**服务的事实**：由每场会话开始时那一次 `/health` 读回，
    /// 记在这里，并写进会话记录，供事后核对当时跑的是哪一组规格。
    public private(set) var lastKnownProfile: String?
    /// 刚刚**封存进库**的那一段。页面用它把"结束"这件事做成一次落地：语音助手结束之后
    /// 落到刚结束的那一段上（`AssistantView.landOnFinalized`），而不是回一个空白的"未开始"。
    ///
    /// 它在 `finalize` 里**写完库之后**才置位，所以读它的页面不会撞上"行还停在 `recording`"
    /// 的中间态——那时读回来的 `ended_at` 还是空的，页面上"结束于 / 时长"两行会说错。
    public private(set) var lastFinalizedSessionID: String?

    // MARK: - 能力层挂载点
    //
    // 协调器是会话生命周期的唯一权威（`TECHNICAL-DESIGN` §5.2），但它不认识"字幕""会议""助手"
    // 各自的采集与连接。这两个钩子就是那条缝：能力层注册"真的开始 / 停止采集"，
    // 于是**五个触发点**（侧边栏主按钮、`⌘⇧N`、菜单栏、字幕带、对话里的切换）
    // 共用同一条路——确认完还要记得启动采集，这件事不能每个触发点各写一遍。

    /// 这个 kind 真正开始采集。抛错表示受阻：协调器**不留占用、不留空记录**（§5.3.1）。
    public var starter: (@MainActor (SessionKind) async throws -> Void)?
    /// 这个 kind 停止采集。`finalize` 会先等它收尾，再封存记录——
    /// 反过来的话，停止期间到达的最后一行会写进已归档的记录。
    public var stopper: (@MainActor (SessionKind) async -> Void)?

    /// 「结束当前会话」的**收尾**钩子。
    ///
    /// 只有会议需要它：会议的收尾不是"停一下"，而是 EOF 屏障 → 封存 → 生成纪要。
    /// 字幕与助手在 `stopCapture` 里就结束了，所以这个钩子缺席时走原来的路。
    /// （不把这段塞进 `stopper`：`stopper` 在 `finalize` 里也会被调一次，
    /// 而排纪要只能发生一次。）
    public var finisher: (@MainActor (SessionKind) async -> Void)?

    private let store: SessionStore
    private let llmProvider: LLMProvider
    private let defaults: UserDefaults
    private var clockTask: Task<Void, Never>?

    /// 「以后不再询问」的持久化键。只对助手 / 字幕生效。
    private static let doNotAskAgainKey = "speechrail.session.skipSwitchConfirmation"

    public init(
        store: SessionStore,
        defaults: UserDefaults = .standard,
        llmProvider: LLMProvider = LLMProvider()
    ) {
        self.store = store
        self.defaults = defaults
        self.llmProvider = llmProvider
    }

    /// 开库（含 `WAL` 与 `user_version` 迁移）。App 启动时调一次；失败只记录结论，
    /// 不阻塞三页的其余部分——记录库不可用不该让「看服务状态」也一起坏掉。
    public func openStore() async {
        do {
            try await store.open()
            storeFailure = nil
            // 上次没正常结束的那些会话在这里封存（§5.6 的 `unexpected_exit`）。
            // 它必须在**任何新会话开始之前**跑完，否则新会话会与一个幽灵会话共享库里的状态。
            sealedAbandonedSessions = (try? await store.sealAbandonedSessions()) ?? []
        } catch {
            storeFailure = error.localizedDescription
        }
    }

    /// 启动时被封存的"上次没有正常结束"的会话。界面据此说一句话（§9 第 10 行的出口）。
    public private(set) var sealedAbandonedSessions: [String] = []

    // MARK: - 守卫（§6.4）

    /// 纯判定，不改任何状态：界面据此决定是直接开始、还是先弹确认。
    public func decision(for kind: SessionKind) -> Decision {
        guard let occupancy else { return .granted }
        guard occupancy.kind != kind else { return .alreadyActive(kind) }
        if !allowsDoNotAskAgain(kind), defaults.bool(forKey: Self.doNotAskAgainKey) {
            return .granted
        }
        return .needsConfirmation(confirmation(superseding: occupancy, with: kind))
    }

    // MARK: - 触发点（§6.4）

    /// 任何「要开始一个会话」的动作都走这里：侧边栏会话页的主按钮、`⌘⇧N`、
    /// 菜单栏的「开始…」、字幕带的「开始会议」。判定通过就直接进入 `preparing`。
    ///
    /// `begin` 的异常在这里**只用于退回占用**（`begin` 自己已经退干净了）；原因是能力层
    /// 自己记的（`CaptionSession.blocked`），所以这一层不需要再持有它——这也是为什么
    /// 能力层的 `starter` 必须在抛之前先把原因落到自己的状态上。
    public func requestStart(_ kind: SessionKind) async {
        switch decision(for: kind) {
        case .granted:
            await endCurrentIfNeeded()
            try? await begin(kind)
        case .alreadyActive:
            // 已经在跑同一个会话：这不是错误，也不是「再开一次」，什么都不做。
            break
        case .needsConfirmation(let confirmation):
            pendingAction = .switchTo(kind)
            pendingConfirmation = confirmation
        }
    }

    /// 结束当前会话。**会议永远确认**（防误停），助手与字幕直接结束（§6.4）。
    public func requestEndCurrentSession() {
        guard let occupancy else { return }
        guard occupancy.kind == .meeting else {
            Task { await stopCapture(endingWith: .user) }
            return
        }
        pendingAction = .endCurrentSession
        pendingConfirmation = Confirmation(
            id: "end-meeting",
            title: "结束这次会议？",
            message: "结束之后会先分完最后半句、再生成纪要；文字记录现在就能看。",
            confirmTitle: "结束会议",
            allowsDoNotAskAgain: false
        )
    }

    public func confirmPending() async {
        let action = pendingAction
        pendingAction = nil
        pendingConfirmation = nil
        switch action {
        case .switchTo(let kind):
            await endCurrentIfNeeded()
            try? await begin(kind)
        case .endCurrentSession:
            if let finisher, occupancy?.kind == .meeting {
                await finisher(.meeting)
            } else {
                await stopCapture(endingWith: .user)
            }
        case nil:
            break
        }
    }

    /// 取消后停留原处，**不改变任何状态**（§6.4 最后一条）。
    public func cancelPending() {
        pendingAction = nil
        pendingConfirmation = nil
    }

    private func endCurrentIfNeeded() async {
        guard occupancy != nil else { return }
        await finalize(reason: .user)
    }

    /// 会议录制永远确认，所以它不参与「以后不再询问」。
    public func allowsDoNotAskAgain(_ kind: SessionKind) -> Bool {
        kind != .meeting
    }

    public func rememberDoNotAskAgain() {
        defaults.set(true, forKey: Self.doNotAskAgainKey)
    }

    public func forgetDoNotAskAgain() {
        defaults.removeObject(forKey: Self.doNotAskAgainKey)
    }

    public var skipsSwitchConfirmation: Bool {
        defaults.bool(forKey: Self.doNotAskAgainKey)
    }

    private func confirmation(superseding current: Occupancy, with kind: SessionKind) -> Confirmation {
        let title = "结束\(current.kind.title)并切换到\(kind.title)？"
        let message: String
        if current.isProcessing {
            message = "正在整理的\(current.kind.title)会话还没有收尾。结束后仍会生成纪要，"
                + "但麦克风同一时刻只能由一个会话使用。"
        } else if let startedAt {
            message = "正在进行的\(current.kind.title)已经录了 \(Self.formatted(elapsed(from: startedAt)))。"
                + "麦克风同一时刻只能由一个会话使用；结束后这一条记录会留在记录库里。"
        } else {
            message = "麦克风同一时刻只能由一个会话使用；结束后这一条记录会留在记录库里。"
        }
        return Confirmation(
            id: "\(current.kind.rawValue)->\(kind.rawValue)",
            title: title,
            message: message,
            confirmTitle: "结束并切换",
            allowsDoNotAskAgain: allowsDoNotAskAgain(current.kind) && allowsDoNotAskAgain(kind)
        )
    }

    // MARK: - 生命周期

    /// 进入 `preparing`：拿设备租约、起走时。**还没有库里的行**——行在首个 PCM 之后才建。
    /// 受阻时抛错，调用点把结论写成受阻态，不建空记录（§5.3.1）。
    public func begin(_ kind: SessionKind) async throws {
        guard occupancy == nil else { return }
        phase = .preparing
        occupancy = Occupancy(kind: kind, isProcessing: false)
        startedAt = Date()
        elapsed = 0
        lineWatermark = 0
        lastInterruption = nil
        holdsDeviceLease = true
        activeLeaseID = UUID()
        startClock()
        do {
            try await starter?(kind)
        } catch {
            // 受阻：设备租约、走时、占用一起退回。**不留一条空记录**——
            // 「麦克风未授权」不该在记录库里留下一条什么都没有的会话。
            releaseDevices()
            stopClock()
            occupancy = nil
            activeLeaseID = nil
            startedAt = nil
            elapsed = 0
            phase = .idle
            throw error
        }
    }

    /// 首个 PCM 已发送：持久化会话此刻才有库里的行（由能力层调 `createSession` 之后回报）。
    /// 提词器传入 `nil`，只进入实时 recording 占用，不创建 `SessionStore` 记录。
    public func sessionDidStartRecording(id: String? = nil) {
        guard occupancy != nil else { return }
        activeSessionID = id
        phase = .recording
    }

    /// 落了一行：推进水位。中断区间与内心 OS 的「提问时的水位」都读它。
    public func noteLineAppended() {
        lineWatermark += 1
    }

    /// 四类中断之一。写账本行（**不重放 PCM**，丢的音频就是真的没录上）。
    @discardableResult
    public func markInterruption(_ reason: SessionInterruptionReason, atOrdinal: Int? = nil) async -> String? {
        guard let activeSessionID else { return nil }
        phase = .interrupted
        lastInterruption = reason
        releaseDevices()
        let id = try? await store.markInterruption(
            sessionID: activeSessionID,
            atOrdinal: atOrdinal ?? lineWatermark,
            reason: reason
        )
        return id
    }

    /// 续接 = 新 epoch：合上中断区间、重新拿设备，**序号与水位不重置**（§6.5）。
    public func resumeAfterInterruption() async {
        guard let activeSessionID, phase == .interrupted else { return }
        try? await store.closeInterruption(sessionID: activeSessionID)
        lastInterruption = nil
        holdsDeviceLease = true
        phase = .recording
        startClock()
    }

    /// 用户自己按了暂停（MC-16）。
    ///
    /// **刻意不走 `markInterruption`**：那条会切 `.interrupted` 并 `releaseDevices()`，
    /// 对应的是"设备真的掉了"。暂停是设备还在手里、会话还在录、只是上行停住，
    /// 走那条路等于把"我先歇会儿"记成设备故障，还会顺手把这一场的音频放掉。
    ///
    /// 但区间必须落库：不记的话，事后看这条记录的人会把中间那几分钟当成安静，
    /// 而实际上那段时间一个字都没录上。
    @discardableResult
    public func markUserPaused() async -> String? {
        guard let activeSessionID else { return nil }
        // 重复调用只记一段：界面上按一次是一个动作，两段重叠的暂停区间
        // 会让恢复时合到错的那一条。
        if pauseInterruptionID != nil { return pauseInterruptionID }
        let id = try? await store.markInterruption(
            sessionID: activeSessionID,
            atOrdinal: lineWatermark,
            reason: .userPaused
        )
        pauseInterruptionID = id
        return id
    }

    /// 恢复记录：合上刚才那一段暂停。不重放 PCM、不动设备、不改相位。
    ///
    /// 按 id 合而不是按会话合：暂停期间若又发生故障，会话里有两条未闭合区间，
    /// 按会话合会把暂停的那段一起算到故障恢复的时刻（见 `SessionStore.closeInterruption(id:)`）。
    public func resumeUserPaused() async {
        guard let id = pauseInterruptionID else { return }
        try? await store.closeInterruption(id: id)
        pauseInterruptionID = nil
    }

    /// 收声停止。设备在此**立刻释放**；会议接下来走 `processing`（纪要 / 分人在收尾）。
    public func stopCapture(endingWith reason: SessionEndReason = .user) async {
        guard let occupancy else { return }
        releaseDevices()
        stopClock()
        if occupancy.kind == .meeting {
            phase = .processing
            self.occupancy = Occupancy(kind: occupancy.kind, isProcessing: true)
        } else {
            await finalize(reason: reason)
        }
    }

    /// 整理收尾完成：归档、清空占用。
    public func finishProcessing(endReason: SessionEndReason = .user) async {
        guard phase == .processing else { return }
        await finalize(reason: endReason)
    }

    /// 封存并交还。`activeSessionID` 为空说明还没落在库里，此时只清占用。
    public func finalize(reason: SessionEndReason) async {
        // 先停采集、再封存：倒过来的话，收尾期间到达的最后一句会写进已归档的记录
        // （库里那一条已经不是 `recording`，行却还在往里加）。
        if let kind = occupancy?.kind {
            await stopper?(kind)
        }
        // 暂停中直接结束：这一段停记到收尾这一刻为止。必须**在封存之前**合上，
        // 否则归档包里会带一条 `resumed_at` 为空的暂停记录，事后读出来像是
        //「录到一半没恢复」（MC-16）。
        await resumeUserPaused()
        if let activeSessionID {
            try? await store.finalizeSession(id: activeSessionID, endReason: reason)
        }
        // 先把库写完，再让页面知道"有一段刚刚封存了"（`lastFinalizedSessionID` 的注解）。
        if let finalized = activeSessionID {
            lastFinalizedSessionID = finalized
        }
        releaseDevices()
        stopClock()
        activeSessionID = nil
        occupancy = nil
        activeLeaseID = nil
        startedAt = nil
        elapsed = 0
        lineWatermark = 0
        lastInterruption = nil
        phase = .idle
    }

    /// 会议封存结果上报（MC-17、MC-20）：封存必须返回明确结果，不吞失败。
    /// 成功要求落库且读回为 archived；失败保留调用方的重试/复制出口。
    @discardableResult
    public func sealMeeting(id: String, reason: SessionEndReason = .user) async -> SessionSealResult {
        do {
            try await store.finalizeSession(id: id, endReason: reason)
            guard let record = try await store.session(id: id), record.state == .archived else {
                return .failed(recordID: id, reason: "封存后读回状态不是已归档")
            }
            // MA-03 收尾：来源快照冻结成功，才算"封存"成功——排纪要这一步依赖它。
            // 这一步失败时**转录已经归档**，所以原因里必须说清文字记录没丢，
            // 否则用户会以为整场都没存上，白白重录一遍。
            do {
                try await store.sealMeetingSource(sessionID: id)
            } catch {
                return .failed(
                    recordID: id,
                    reason: "文字记录已经归档，但来源快照没有封存成功：\(error.localizedDescription)"
                )
            }
            lastFinalizedSessionID = id
            return .sealed(recordID: id)
        } catch {
            return .failed(recordID: id, reason: error.localizedDescription)
        }
    }

    /// 按**明确的 sessionID** 封存一条记录，且不碰当前占用。
    ///
    /// 建档是启动流程里最后一个 await：它落库之后启动可能已经被取消。
    /// 那时不能删记录（用户的操作真的发生过），也不该把它挂到新会话上，
    /// 所以只按它自己的 ID 收口。
    public func sealSession(id: String, reason: SessionEndReason = .user) async {
        guard activeSessionID != id else { return }
        try? await store.finalizeSession(id: id, endReason: reason)
    }

    /// VA-03 封存结果：成功且读回 archived 才算保存成功。
    /// 失败保留 pendingSeal 与内存未保存文本，硬件仍释放；
    /// 成功才发布 lastFinalizedSessionID。0 受影响行不算成功。
    public enum SessionSealResult: Equatable, Sendable {
        case sealed(recordID: String)
        case failed(recordID: String?, reason: String)
        case skipped(recordID: String?)
    }

    /// VA-03 真实结果封存：返回实际落库结果，不吞失败。
    /// A47：finalize throw / 0 行更新时无成功 ID，调用方保留 pendingSeal 与重试/复制出口。
    @discardableResult
    public func sealSessionReporting(id: String, reason: SessionEndReason = .user) async -> SessionSealResult {
        // activeSessionID == id 表示该记录仍在占用中：由 finalize 路径收口，此处跳过。
        if activeSessionID == id { return .skipped(recordID: id) }
        do {
            try await store.finalizeSession(id: id, endReason: reason)
            // 读回验证：成功且为 archived 才发布成功 ID。
            if let record = try await store.session(id: id), record.state == .archived {
                lastFinalizedSessionID = id
                return .sealed(recordID: id)
            }
            return .failed(recordID: id, reason: "封存后读回状态不是已归档")
        } catch {
            return .failed(recordID: id, reason: error.localizedDescription)
        }
    }

    /// 助手专属的目标结束（VA-01 / A01/A02/A18）。
    ///
    /// - 纯文字助手没有设备占用：只要 recordID 对上就按该 ID 封存，
    ///   不碰 `occupancy` / `activeSessionID` / `activeLeaseID`。
    /// - 语音助手必须同时核对 kind == .assistant 且 leaseID 匹配；
    ///   不匹配返回 `.mismatch` / `.superseded`，不做全局 stop。
    /// 每个 await 返回后重新比对目标，占用变化后只完成旧目标记录。
    public func endAssistant(_ target: AssistantEndTarget, reason: SessionEndReason = .user) async -> AssistantEndResult {
        // 纯文字：无占用路径。
        if occupancy == nil {
            guard let recordID = target.recordID else { return .noConversation }
            try? await store.finalizeSession(id: recordID, endReason: reason)
            lastFinalizedSessionID = recordID
            return .ended(recordID: recordID)
        }
        // 文字目标（无 lease 身份）：只封自己的记录，不碰任何占用。
        // A02：会议/其他功能占用设备时，文字结束不得改占用/phase/记录/stopper。
        if target.leaseID == nil, target.recordID != nil, target.recordID != activeSessionID {
            let recordID = target.recordID!
            try? await store.finalizeSession(id: recordID, endReason: reason)
            lastFinalizedSessionID = recordID
            return .ended(recordID: recordID)
        }
        // 有占用：只允许助手自己的目标结束。
        guard occupancy?.kind == .assistant else { return .mismatch }
        if let expectedLease = target.leaseID, let currentLease = activeLeaseID,
           expectedLease != currentLease {
            return .superseded
        }
        // recordID 存在时必须与当前语音记录一致，否则是旧目标的迟到结束。
        if let recordID = target.recordID, let active = activeSessionID, recordID != active {
            return .superseded
        }
        let leaseAtEntry = activeLeaseID
        let recordAtEntry = target.recordID ?? activeSessionID
        await finalize(reason: reason)
        // finalize 期间占用若被新会话接管（理论上 finalize 串行持有占用，
        // 此处为防御性复核），只完成旧目标记录，不清新占用。
        if leaseAtEntry != nil, activeLeaseID != nil, activeLeaseID != leaseAtEntry {
            if let recordAtEntry {
                try? await store.finalizeSession(id: recordAtEntry, endReason: reason)
            }
            return .superseded
        }
        return .ended(recordID: recordAtEntry)
    }

    private func releaseDevices() {
        // 空闲 = 真的没有设备。阶段 3/6 的真实采集释放挂在这里，先保证状态不撒谎。
        holdsDeviceLease = false
    }

    // MARK: - 走时

    private func startClock() {
        stopClock()
        let started = startedAt ?? Date()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.elapsed = Date().timeIntervalSince(started)
            }
        }
    }

    private func stopClock() {
        clockTask?.cancel()
        clockTask = nil
    }

    private func elapsed(from start: Date) -> TimeInterval {
        max(0, Date().timeIntervalSince(start))
    }

    // MARK: - 呈现（侧边栏第二行 / 状态带共用同一份口径）

    /// 记录库文件位置。设置页的「打开数据目录」与备份入口读它。
    public var libraryURL: URL { store.libraryURL }

    // MARK: - 记录库的只读入口
    //
    // 界面不直接持有 `SessionStore`：那是业务层与持久化之间唯一的缝（§5.1），
    // 从协调器转发一道，改存储时界面不用跟着改。

    public func listSummaries(kind: SessionKind? = nil, limit: Int? = nil, offset: Int = 0) async throws -> [SessionSummary] {
        try await store.listSessions(kind: kind, limit: limit, offset: offset)
    }

    public func record(id: String) async throws -> SessionRecord? {
        try await store.session(id: id)
    }

    public func lines(sessionID: String, includePartial: Bool = false) async throws -> [TranscriptLine] {
        try await store.lines(sessionID: sessionID, includePartial: includePartial)
    }

    public func speakerNames(sessionID: String) async throws -> [String: String] {
        try await store.speakerNames(sessionID: sessionID)
    }

    /// 分人链路只允许改归属列（§15.3 第 2 条）。正文一个字都不动，所以这条入口
    /// 与"编辑文本"不是同一件事，也没有第二个调用点。
    public func attachSpeakerLabel(lineID: String, label: String?) async throws {
        try await store.attachSpeakerLabel(lineID: lineID, label: label)
    }

    /// 对齐证据独立于文本 final 到达，只补写 `timing_quality` 这一列（§15.3 第 2 条）。
    public func attachTimingQuality(lineID: String, quality: SessionTimingQuality?) async throws {
        try await store.attachTimingQuality(lineID: lineID, quality: quality)
    }

    /// 回填对齐得到的声学起止与质量（MA-02 / MC-15）。
    public func attachAcousticTiming(
        lineID: String,
        start: TimeInterval,
        end: TimeInterval,
        quality: SessionTimingQuality
    ) async throws {
        try await store.attachAcousticTiming(lineID: lineID, start: start, end: end, quality: quality)
    }

    /// 改显示名：写 `speaker_name`，`line.text` 与证据引用都不动（§6.2.1）。
    public func renameSpeaker(sessionID: String, label: String, name: String) async throws {
        try await store.renameSpeaker(sessionID: sessionID, label: label, name: name)
    }

    /// 归属修订透传（拆出用）：只追加 `kind='speaker'` 事件，不碰显示名。
    ///
    /// 与 `renameSpeaker` 分开，是因为它记的是"谁说了这句"变了，
    /// 而不是"这个人叫什么"。
    public func noteSpeakerAttributionChange(sessionID: String, detail: String) async throws {
        try await store.noteSpeakerAttributionChange(sessionID: sessionID, detail: detail)
    }

    /// 来源修订事件透传（MC-46 后半句）：只读 `session_change` 的说话人修订。
    public func speakerRevisions(sessionID: String) async throws -> [SessionChange] {
        try await store.speakerRevisions(sessionID: sessionID)
    }

    /// 旧纪要是否需复核透传（MC-46 后半句）：纯读判断，不写库。
    public func minutesNeedsReview(minutesID: String) async throws -> Bool {
        try await store.minutesNeedsReview(minutesID: minutesID)
    }

    /// 一场里的中断区间（记录库详情与导出物都读它）。
    public func interruptions(sessionID: String) async throws -> [SessionInterruption] {
        try await store.interruptions(sessionID: sessionID)
    }

    /// 一场里的音色变更点（「第 N 句起」这句话的数据来源，§15.3 第 3 条）。
    public func voiceChanges(sessionID: String) async throws -> [SessionChange] {
        try await store.voiceChanges(sessionID: sessionID)
    }

    /// 记录库"回看这一条"的单次快照读。转发一层，保持"界面不直接持有 Store"这条缝。
    public func reviewSnapshot(sessionID: String) async throws -> SessionReviewSnapshot? {
        try await store.reviewSnapshot(sessionID: sessionID)
    }

    public func minutesVersions(sessionID: String) async throws -> [MinutesVersion] {
        try await store.minutesVersions(sessionID: sessionID)
    }

    /// 按 id 读一版纪要：导出与引用固定选定版（MC-48）。
    public func minutesVersion(id: String) async throws -> MinutesVersion? {
        try await store.minutesVersion(id: id)
    }

    public func innerOSExchanges(sessionID: String) async throws -> [InnerOSExchange] {
        try await store.innerOSExchanges(sessionID: sessionID)
    }

    public func innerOSEvidence(exchangeID: String) async throws -> [InnerOSEvidence] {
        try await store.innerOSEvidence(exchangeID: exchangeID)
    }

    /// 引文校验透传（MC-35/MC-36）：纯读，不写库。
    public func verifyEvidenceQuotes(exchangeID: String) async throws -> [SessionStore.EvidenceQuoteCheck] {
        try await store.verifyEvidenceQuotes(exchangeID: exchangeID)
    }

    /// 返回**是否真的改了行**。命中 0 行（这一条问答不存在）不是成功，
    /// 往上如实报，界面才不会把标签翻过去。
    @discardableResult
    public func setInnerOSInMinutes(
        exchangeID: String,
        included: Bool,
        excerpt: String? = nil
    ) async throws -> Bool {
        try await store.setInnerOSInMinutes(
            exchangeID: exchangeID, included: included, excerpt: excerpt
        )
    }

    public func memories(activeOnly: Bool = true) async throws -> [AssistantMemory] {
        try await store.memories(activeOnly: activeOnly)
    }

    @discardableResult
    public func upsertMemory(
        kind: AssistantMemoryKind,
        body: String,
        sourceSessionID: String?,
        id: String = UUID().uuidString
    ) async throws -> String {
        try await store.upsertMemory(kind: kind, body: body, sourceSessionID: sourceSessionID, id: id)
    }

    public func setMemoryActive(id: String, active: Bool) async throws {
        try await store.setMemoryActive(id: id, active: active)
    }

    public func removeMemory(id: String) async throws {
        try await store.removeMemory(id: id)
    }

    @discardableResult
    public func saveInnerOSExchange(
        _ exchange: InnerOSExchange,
        evidence: [InnerOSEvidence] = []
    ) async throws -> String {
        try await store.saveInnerOSExchange(exchange, evidence: evidence)
    }

    /// 问答终态写入透传（MC-41/MC-42）：答案、状态、证据同一事务落库。
    @discardableResult
    public func finishInnerOSExchange(
        _ exchange: InnerOSExchange,
        evidence: [InnerOSEvidence] = []
    ) async throws -> String {
        try await store.finishInnerOSExchange(exchange, evidence: evidence)
    }

    /// 落一条音色变更点（「第 N 句起」必须查得回来）。
    public func noteVoiceChange(atOrdinal: Int, voice: VoiceSnapshot) async throws {
        guard let activeSessionID else { return }
        try await noteVoiceChange(
            sessionID: activeSessionID,
            atOrdinal: atOrdinal,
            voice: voice
        )
    }

    /// 为已固定身份的会话落音色变更点；迟到保存不能被当前 active session 改道。
    public func noteVoiceChange(
        sessionID: String,
        atOrdinal: Int,
        voice: VoiceSnapshot
    ) async throws {
        try await store.noteVoiceChange(
            sessionID: sessionID,
            atOrdinal: atOrdinal,
            voice: voice
        )
    }

    /// 仅让本记录第一条正式 user 行认领自动标题，且不覆盖人工命名。
    @discardableResult
    public func claimAutomaticTitle(
        sessionID: String,
        lineID: String,
        title: String
    ) async throws -> Bool {
        try await store.claimAutomaticTitle(
            sessionID: sessionID,
            lineID: lineID,
            title: title
        )
    }

    public func setSessionTitle(id: String, title: String?) async throws {
        try await store.updateSessionTitle(id: id, title: title)
    }

    public func setLineStarred(lineID: String, starred: Bool) async throws {
        try await store.setLineStarred(lineID: lineID, starred: starred)
    }

    @discardableResult
    public func enqueueMinutes(
        sessionID: String,
        model: String?,
        promptChars: Int?,
        configSnapshot: String? = nil,
        snapshotID: String? = nil
    ) async throws -> MinutesVersion {
        try await store.enqueueMinutes(
            sessionID: sessionID,
            model: model,
            promptChars: promptChars,
            configSnapshot: configSnapshot,
            snapshotID: snapshotID
        )
    }

    @discardableResult
    public func claimMinutes(sessionID: String, lease: TimeInterval) async throws -> MinutesVersion? {
        try await store.claimMinutes(sessionID: sessionID, lease: lease)
    }

    public func failMinutes(minutesID: String, reason: String) async throws {
        try await store.failMinutes(minutesID: minutesID, reason: reason)
    }

    /// 带 fencing 代际的完成/失败：旧执行者迟到不得改写新行（MC-29）。
    @discardableResult
    public func finishMinutesIfOwner(minutesID: String, expectedAttempts: Int, body: String, model: String?) async throws -> Bool {
        try await store.finishMinutesIfOwner(minutesID: minutesID, expectedAttempts: expectedAttempts, body: body, model: model)
    }

    @discardableResult
    public func failMinutesIfOwner(minutesID: String, expectedAttempts: Int, reason: String) async throws -> Bool {
        try await store.failMinutesIfOwner(minutesID: minutesID, expectedAttempts: expectedAttempts, reason: reason)
    }

    /// 记下远端响应 id（MC-28）。收到就写，不等整理结束。
    @discardableResult
    public func recordMinutesRemoteResponse(
        minutesID: String,
        expectedAttempts: Int,
        responseID: String
    ) async throws -> Bool {
        try await store.recordMinutesRemoteResponse(
            minutesID: minutesID,
            expectedAttempts: expectedAttempts,
            responseID: responseID
        )
    }

    /// 心跳续租：一次整理可能跑十几分钟，只写一次租约会被下一次启动误回收。
    @discardableResult
    public func renewMinutesLease(minutesID: String, expectedAttempts: Int, lease: TimeInterval) async throws -> Bool {
        try await store.renewMinutesLease(minutesID: minutesID, expectedAttempts: expectedAttempts, lease: lease)
    }

    /// 用户按下「停止整理」：先把取消请求写进库，再停本地任务（MC-30）。
    @discardableResult
    public func requestCancelMinutes(minutesID: String) async throws -> Bool {
        try await store.requestCancelMinutes(minutesID: minutesID)
    }

    @discardableResult
    public func cancelMinutesIfOwner(minutesID: String, expectedAttempts: Int) async throws -> Bool {
        try await store.cancelMinutesIfOwner(minutesID: minutesID, expectedAttempts: expectedAttempts)
    }

    /// 远端提交结果未知：落成明确状态，不自动重发（MC-28、§8.5）。
    @discardableResult
    public func markMinutesSubmissionUnknown(minutesID: String, expectedAttempts: Int) async throws -> Bool {
        try await store.markMinutesSubmissionUnknown(minutesID: minutesID, expectedAttempts: expectedAttempts)
    }

    /// 排队那一刻要绑定的来源快照；还没有封存快照时为 nil（MC-20）。
    public func latestSourceSnapshot(sessionID: String) async throws -> MeetingSourceSnapshot? {
        try await store.latestSourceSnapshot(sessionID: sessionID)
    }

    /// 启动时回收那些"排队中或租约已过期"的纪要（§5.8）。
    public func sessionsWithPendingMinutes() async throws -> [String] {
        try await store.sessionsWithPendingMinutes()
    }

    /// 待恢复的纪要行：调用方按原 job 身份认领，不新建版本（MC-27）。
    public func pendingMinutesRows() async throws -> [MinutesVersion] {
        try await store.pendingMinutesRows()
    }

    /// 提交一版结构化候选：正文、候选、核对报告同一条写（MA-08）。
    @discardableResult
    public func saveMinutesCandidate(
        minutesID: String,
        expectedAttempts: Int,
        body: String,
        model: String?,
        candidate: String?,
        review: String?,
        items: [MinutesItemDraft] = [],
        snapshotID: String? = nil,
        coverage: String? = nil,
        windows: [MinutesWindowRecord] = []
    ) async throws -> Bool {
        try await store.saveMinutesCandidate(
            minutesID: minutesID,
            expectedAttempts: expectedAttempts,
            body: body,
            model: model,
            candidate: candidate,
            review: review,
            items: items,
            snapshotID: snapshotID,
            coverage: coverage,
            windows: windows
        )
    }

    /// 覆盖账本里的窗口进度（MA-09）。局部重试从它读出"只重跑哪几窗"。
    public func minutesWindows(minutesID: String) async throws -> [MinutesWindowRecord] {
        try await store.minutesWindows(minutesID: minutesID)
    }

    /// 把已落终态的一版重新开成 `running` 以便只重跑失败窗口（MC-40）。
    public func reopenMinutesForWindowRetry(
        minutesID: String,
        expectedAttempts: Int,
        lease: TimeInterval
    ) async throws -> Bool {
        try await store.reopenMinutesForWindowRetry(
            minutesID: minutesID,
            expectedAttempts: expectedAttempts,
            lease: lease
        )
    }

    /// 记一个窗口的进度（MA-09）。带 fencing：父行已被新 owner 接管时返回 false。
    @discardableResult
    public func recordMinutesWindow(
        minutesID: String,
        expectedAttempts: Int,
        record: MinutesWindowRecord
    ) async throws -> Bool {
        try await store.recordMinutesWindow(
            minutesID: minutesID,
            expectedAttempts: expectedAttempts,
            record: record
        )
    }

    /// 这一版的结论条目与证据锚点（锚点原文读自不可变修订）。
    public func minutesItems(minutesID: String) async throws -> [MinutesItem] {
        try await store.minutesItems(minutesID: minutesID)
    }

    /// 每一行当前最新的修订（`lineID → revisionID`），用于把来源单元落到修订上。
    public func latestRevisionIDsByLine(sessionID: String) async throws -> [String: String] {
        try await store.latestRevisionIDsByLine(sessionID: sessionID)
    }


    /// 跨会议知识检索：转录终稿与已完成纪要，不含私密问答（MC-44、MC-49、MC-52）。
    public func searchKnowledge(
        query: String,
        kind: SessionKind? = nil,
        limit: Int = 200
    ) async throws -> [SessionStore.KnowledgeHit] {
        try await store.searchKnowledge(query: query, kind: kind, limit: limit)
    }

    /// 全文检索（MA-15）。降级时 `usedFullText` 为 false 且带原因，
    /// 调用方要把它显示出来，不能让用户以为这就是全文检索的结果。
    public func searchKnowledgeFullText(
        query: String,
        kind: SessionKind? = nil,
        limit: Int = 200
    ) async throws -> SessionStore.KnowledgeSearchResults {
        try await store.searchKnowledgeFullText(query: query, kind: kind, limit: limit)
    }

    /// 会议知识库列表（MA-12）。完整分页，不截断到最近几场（MC-52）。
    public func meetingLibraryPage(
        query: String = "",
        projectID: String? = nil,
        includesArchived: Bool = false,
        limit: Int = 50,
        offset: Int = 0
    ) async throws -> MeetingLibraryPage {
        try await store.meetingLibraryPage(
            query: query, projectID: projectID,
            includesArchived: includesArchived, limit: limit, offset: offset
        )
    }

    /// 下次会议准备稿（会前准备 / 跨会议复用）：仍未解决的问题、
    /// 还没完成的动作、**以及需要先核对的结论**。
    ///
    /// 这一层此前生产代码零消费方：`MeetingPrepDraft` 与 `meetingPrepDraft(scope:)`
    /// 实现完整，还有 `markdown()` 渲染，但没有任何界面入口——用户手里有一套
    /// 跨会议的未决事项，却要自己一场一场点开去拼下一场该准备什么。
    public func meetingPrepDraft(scope: MeetingKnowledgeScope = .standard) async throws -> MeetingPrepDraft {
        try await store.meetingPrepDraft(scope: scope)
    }

    // MARK: - 跨会议问答（MA-17 / MC-56～MC-64）

    /// 问一句跨会议的问题，返回有出处的答案（MA-17）。
    ///
    /// 这一层此前**生产代码零消费方**：`MeetingKnowledgeQueryService` 与它的
    /// `answer(_:)` 实现完整、测试覆盖拒答／分页／注入防护／MC-63 的展示前
    /// 范围复核，但**没有任何生产代码构造它或调用它**——用户根本没有入口提问。
    /// 库里做得再好，够不着就等于没做；这是本分支反复在修的同一类缺陷。
    ///
    /// 模型补全在这里接：`LLMProvider` 与纪要侧同一套（§5.1 的缝在
    /// `SessionCoordinator` 这一层，界面不直接持有 provider）。
    public func askKnowledge(
        question: String,
        scope: MeetingKnowledgeScope = .standard,
        configuration: LLMConfiguration,
        resolvedConfiguration: ResolvedLLMConfiguration
    ) async throws -> MeetingKnowledgeQueryService.Answer {
        let provider = llmProvider
        let service = MeetingKnowledgeQueryService(store: store) { messages in
            try await provider.complete(
                configuration: configuration,
                messages: messages,
                apiKey: resolvedConfiguration.apiKey,
                maxOutputTokens: 1_200,
                textFormat: MeetingKnowledgeAnswer.jsonSchema,
                timeout: 90
            )
        }
        return try await service.answer(
            .init(question: question, scope: scope)
        )
    }

    // MARK: - 未完成事项（MC-56）

    /// 结构化事项查询的透传。此前 `SessionStore.knowledgeItems` 生产代码零消费方：
    /// 库里能算，界面上一个入口都够不着，"列出所有未完成"这条验收拿不出来。
    public func meetingKnowledgeItems(
        filter: KnowledgeItemFilter,
        scope: MeetingKnowledgeScope = .standard,
        limit: Int = 50,
        offset: Int = 0
    ) async throws -> KnowledgeItemPage {
        try await store.knowledgeItems(filter: filter, scope: scope, limit: limit, offset: offset)
    }

    /// 记一次执行状态变化（MA-14 写侧）。**只追加事件，不改写旧事件。**
    ///
    /// `ownerText` / `dueText` 用双层可选：`nil` 表示"这次没改"，`.some(nil)` 表示"清掉"。
    /// 分不开这两者，界面上就没法既保留原值又允许用户删空。
    ///
    /// 这一层此前也不存在：`recordExecutionEvent` 在生产代码里零消费方，
    /// 用户标过的"已完成"只能由测试写进去。
    @discardableResult
    public func recordActionExecution(
        itemID: String,
        status: ActionExecutionStatus,
        ownerText: String?? = nil,
        dueText: String?? = nil,
        dueDate: Date?? = nil
    ) async throws -> KnowledgeExecutionEvent {
        try await store.recordExecutionEvent(
            itemID: itemID, status: status,
            ownerText: ownerText, dueText: dueText, dueDate: dueDate
        )
    }

    /// 一条行动的完整状态变更历史，**按生效时间升序**（MC-59）。
    ///
    /// 三月承诺四月、四月改成五月之后，三月那条并没有消失——按行 id 查会丢，
    /// 所以这里收的是**稳定 key**。
    public func executionTimeline(itemKey: String) async throws -> [KnowledgeExecutionEvent] {
        try await store.executionEvents(itemKey: itemKey)
    }

    /// 这一场重新生成之后，新一版相对上一版**可能**变了什么（MC-54 / MA-14）。
    ///
    /// **只是候选差异，不落任何状态**——自动建议一旦自己动手改状态，
    /// 用户就再也说不清"这条为什么变了"。
    public func knowledgeChangeProposals(
        documentID: String
    ) async throws -> [KnowledgeChangeProposal] {
        try await store.knowledgeChangeProposals(documentID: documentID)
    }

    // MARK: - 跨会议结论冲突（MC-57、MC-58）

    /// 两场会结论看起来相反、且缺少限定的候选对。
    ///
    /// **只摆出来，不合成一致意见**——"两个会议结论相反但范围不清"的时候，
    /// 给一句归纳就是编造共识。已确认过替代的两边不再返回。
    public func conflictingKnowledgeDecisions(
        scope: MeetingKnowledgeScope = .standard,
        limit: Int = 20
    ) async throws -> [KnowledgeChangeProposal] {
        try await store.conflictingDecisions(scope: scope, limit: limit)
    }

    /// 确认「后一条取代前一条」。**依据只有两种**：明确证据，或用户确认——
    /// 字面相似不算（MC-57）。
    @discardableResult
    public func confirmKnowledgeSupersession(
        fromItemID: String,
        toItemID: String,
        basis: SupersessionBasis,
        evidenceItemIDs: [String] = []
    ) async throws -> KnowledgeSupersession {
        try await store.confirmSupersession(
            fromItemID: fromItemID, toItemID: toItemID,
            basis: basis, evidenceItemIDs: evidenceItemIDs
        )
    }

    // MARK: - 知识归档与删除（MA-18）

    /// 三档删除（MA-18 / MC-43、MC-44、MC-62）。
    ///
    /// 顺序固定为"先不可使用、再清理派生"：tombstone 一落，检索、导出、问答就都
    /// 看不见它，之后才删正文；反过来会出现"内容已经没了但还能被搜到"的窗口。
    /// 全程一个事务，失败时当前库一个字节都不变。
    ///
    /// 这一层之前**不存在**，于是界面上根本够不着删除：`MeetingLibraryModel` 只依赖
    /// 协调器（§5.1 的缝），而协调器没有透传。三档删除和索引清理都已经在库里做好，
    /// 缺的只是从界面到它的一条路。
    @discardableResult
    public func deleteMeetingKnowledge(
        documentID: String,
        mode: MeetingDeletionMode
    ) async throws -> MeetingDeletionReport {
        try await store.deleteMeetingKnowledge(documentID: documentID, mode: mode)
    }

    /// 撤销归档。
    ///
    /// **只有 `.archive` 能撤销**：另两档的数据已经不在库里了，`restoreMeetingKnowledge`
    /// 对它们返回 false。界面不得对那两档显示"撤销"——给一个按了没反应的按钮，
    /// 比不给更糟。
    @discardableResult
    public func restoreMeetingKnowledge(documentID: String) async throws -> Bool {
        try await store.restoreMeetingKnowledge(documentID: documentID)
    }

    /// 当前该被引用的那一版：采用版优先，没有采用版才用最新可用版（MA-11）。
    public func currentMinutesVersion(sessionID: String) async throws -> MinutesVersion? {
        if let accepted = try await store.acceptedMinutes(sessionID: sessionID) { return accepted }
        return try await store.latestUsableMinutes(sessionID: sessionID)
    }

    /// 用户改纪要正文（MA-11）。**写新版本，不覆盖**；未就绪 / 跨会议 /
    /// 已归档的版本会被拒绝，改动写不进去。
    public func saveUserMinutesEdit(
        sessionID: String,
        editingMinutesID: String,
        body: String
    ) async throws -> MinutesVersion {
        try await store.saveUserMinutesEdit(
            sessionID: sessionID, editingMinutesID: editingMinutesID, body: body
        )
    }

    /// 补一段用户自己写的话（验收 2 的第四档来源）。另存一版，出处标 `.userSupplement`。
    @discardableResult
    public func saveUserSupplement(
        sessionID: String,
        editingMinutesID: String,
        supplement: String
    ) async throws -> MinutesVersion {
        try await store.saveUserSupplement(
            sessionID: sessionID, editingMinutesID: editingMinutesID, supplement: supplement
        )
    }

    /// 撤销一次编辑：拿回上一版正文，另存一版（MA-11 / MC-47）。
    public func undoMinutesEdit(minutesID: String) async throws -> MinutesVersion? {
        try await store.undoMinutesEdit(minutesID: minutesID)
    }

    /// 这一版是从哪一版改来的（MA-11 / MC-48）。
    public func minutesEditLineage(minutesID: String) async throws -> [MinutesVersion] {
        try await store.minutesEditLineage(minutesID: minutesID)
    }

    /// 会议详情快照（MA-12 / MC-50）。一次读取、整体提交：
    /// 纪要、转录与条目同源，不分三次到齐再拼。
    public func meetingReviewSnapshot(documentID: String) async throws -> MeetingReviewSnapshot? {
        try await store.meetingReviewSnapshot(documentID: documentID)
    }

    /// 导出这一场（MA-19 / 验收 4）。传 `minutesVersionID` 就是**钉住那一版**，
    /// 不传则用当前采用版——与详情显示的取法一致（MC-48）。
    public func meetingExportPayload(
        documentID: String,
        minutesVersionID: String? = nil
    ) async throws -> SessionExportPayload? {
        try await store.meetingExportPayload(
            documentID: documentID, minutesVersionID: minutesVersionID
        )
    }

    // MARK: - 项目与标签（MA-13）

    /// 全部项目，筛选菜单的数据源。
    public func meetingProjects() async throws -> [MeetingProject] {
        try await store.projects()
    }

    @discardableResult
    public func createMeetingProject(name: String) async throws -> MeetingProject {
        try await store.createProject(name: name)
    }

    public func renameMeetingProject(id: String, name: String) async throws {
        try await store.renameProject(id: id, name: name)
    }

    /// 改这场会议属于哪个项目。`projectID` 传 nil 表示**移出项目**——
    /// 这里用双层可选把"不改"和"改成没有"分开，与 store 的约定一致。
    public func updateMeetingDocument(
        id: String, projectID: String??
    ) async throws {
        try await store.updateMeetingDocument(id: id, projectID: projectID)
    }

    public func meetingDocumentTags(documentID: String) async throws -> [String] {
        try await store.documentTags(documentID: documentID)
    }

    public func setMeetingDocumentTags(documentID: String, tags: [String]) async throws {
        try await store.setDocumentTags(documentID: documentID, tags: tags)
    }

    // MARK: - 知识归档包（MA-19）

    /// 导出归档包（MA-19）。`to` 是**父目录**：包会按"哪场会的第几版"命名落在里面。
    public func exportKnowledgeArchive(
        selection: KnowledgeArchiveSelection, to directory: URL
    ) async throws -> URL {
        try await store.exportKnowledgeArchive(selection: selection, to: directory)
    }

    /// 导入预检（MC-71）：读包、比对现有库，**只读不写**。
    public func previewKnowledgeArchive(
        at packageURL: URL
    ) async throws -> KnowledgeArchivePreview {
        try await store.previewKnowledgeArchive(at: packageURL)
    }

    /// 真正导入。有真冲突时 store 侧会拒绝——界面必须先给用户看预检。
    @discardableResult
    public func importKnowledgeArchive(
        at packageURL: URL
    ) async throws -> KnowledgeArchiveImportResult {
        try await store.importKnowledgeArchive(at: packageURL)
    }

    /// 检索索引状态：索引是否可用、有多少待处理项（§6.5「保存与索引分开报状态」）。
    public func searchIndexStatus() async throws -> SessionStore.SearchIndexStatus {
        try await store.searchIndexStatus()
    }

    /// 重建检索索引（索引是派生数据，重建不丢内容）。
    @discardableResult
    public func rebuildSearchIndex() async throws -> Int {
        try await store.rebuildSearchIndex()
    }

    public func searchLines(
        query: String,
        kind: SessionKind? = nil,
        limit: Int = 200
    ) async throws -> [TranscriptLine] {
        try await store.searchLines(query: query, kind: kind, limit: limit)
    }

    /// 关掉占用（**不改库里的行**）。给"会话在能建行之前就失败"这条路用，
    /// 与 `finalize` 的区别是它不封存任何记录。
    public func abandonOccupancy() {
        releaseDevices()
        stopClock()
        activeSessionID = nil
        occupancy = nil
        activeLeaseID = nil
        startedAt = nil
        elapsed = 0
        lineWatermark = 0
        lastInterruption = nil
        phase = .idle
    }

    /// 最新一版纪要（含正文）。导出物把它放在转录前面（§6.3.2）；
    /// 还没生成纪要时给 `nil`，导出物就只出转录。
    public func latestMinutes(sessionID: String) async throws -> MinutesVersion? {
        let versions = try await store.minutesVersions(sessionID: sessionID)
        return versions.first { $0.isLatest } ?? versions.first
    }

    /// 最新可用版（MC-25）：已完成且有正文的版本里版本号最大的那一版。
    public func latestUsableMinutes(sessionID: String) async throws -> MinutesVersion? {
        try await store.latestUsableMinutes(sessionID: sessionID)
    }

    /// 当前采用版（MA-06/MC-25）：用户明确采用的那一版；没有采用过返回 nil。
    public func acceptedMinutes(sessionID: String) async throws -> MinutesVersion? {
        try await store.acceptedMinutes(sessionID: sessionID)
    }

    /// 当前应当展示/导出的那一版（MA-06/MC-25）：采用版优先，
    /// 没有采用版才退回最新可用候选。
    public func currentMinutes(sessionID: String) async throws -> MinutesVersion? {
        try await store.currentMinutes(sessionID: sessionID)
    }

    /// 采用一版纪要（MA-06/MC-31）：只有已完成且有正文的版本才能被采用；
    /// `expectedCurrentID` 是调用方开始操作时看到的采用版 id，不一致时拒绝覆盖。
    @discardableResult
    public func adoptMinutes(sessionID: String, minutesID: String, expectedCurrentID: String?) async throws -> Bool {
        try await store.adoptMinutes(sessionID: sessionID, minutesID: minutesID, expectedCurrentID: expectedCurrentID)
    }

    public func removeSession(id: String) async throws {
        try await store.removeSession(id: id)
    }

    // MARK: - 会议知识文档（MA-05/MC-68）

    /// 建知识文档透传：导入文档允许无采集会话，不伪造"录过音"。
    public func createMeetingDocument(_ document: MeetingDocument) async throws -> MeetingDocument {
        try await store.createMeetingDocument(document)
    }

    /// 按 id 读知识文档：纯读，不写库。
    public func meetingDocument(id: String) async throws -> MeetingDocument? {
        try await store.meetingDocument(id: id)
    }

    /// 按采集会话查知识文档：纯读，不写库。
    public func meetingDocument(forSessionID sessionID: String) async throws -> MeetingDocument? {
        try await store.meetingDocument(forSessionID: sessionID)
    }

    /// 封存来源快照透传：快照与文档关联同一事务，失败全部回滚（MC-20）。
    public func sealMeetingSource(_ snapshot: MeetingSourceSnapshot) async throws -> MeetingSourceSnapshot {
        try await store.sealMeetingSource(snapshot)
    }

    /// 按 id 读来源快照：纯读，不写库。
    public func sourceSnapshot(id: String) async throws -> MeetingSourceSnapshot? {
        try await store.sourceSnapshot(id: id)
    }

    /// 记一条转录来源修订：只追加不覆盖原文（MA-05/MC-46）。
    public func recordTranscriptRevision(_ revision: TranscriptRevision) async throws -> TranscriptRevision {
        try await store.recordTranscriptRevision(revision)
    }

    /// 读一行的来源修订链：纯读，不写库。
    public func transcriptRevisions(lineID: String) async throws -> [TranscriptRevision] {
        try await store.transcriptRevisions(lineID: lineID)
    }

    /// 能力层写库的唯一入口（§5.1：业务模块不持有连接、不写 SQL）。
    public func createSession(_ draft: SessionDraft) async throws -> SessionRecord {
        let record = try await store.createSession(draft)
        lastKnownProfile = draft.engineProfile
        return record
    }

    /// 落一行正文，返回库分配的 `ordinal`。取号与插入在库里是同一条语句（§15.7 R2 ①），
    /// 所以序号在一个会话里单调且唯一；"同一条 `completed` 只落一次"由能力层保证
    /// （见 `CaptionSession.committedItemIDs`），不在这里。
    @discardableResult
    public func appendLine(_ draft: LineDraft) async throws -> Int {
        let ordinal = try await store.appendLine(draft)
        noteLineAppended()
        return ordinal
    }

    /// 落一行，并**指定它的行 id**。分人要用：`segment_uid` 必须能找到它落在哪一行，
    /// 而行的 id 由建行的一方决定（库里不会事后告诉服务端）。
    @discardableResult
    public func appendLine(_ draft: LineDraft, id: String) async throws -> Int {
        let ordinal = try await store.appendLine(draft, id: id)
        noteLineAppended()
        return ordinal
    }

    /// 助手单轮回复的收尾（D08）。**不推进水位**：这一行在生成开始时就建好了，
    /// 收尾只是把同一行改成定稿，不是一次新的追加。
    @discardableResult
    public func finalizeAssistantLine(
        sessionID: String,
        lineID: String,
        text: String,
        interrupted: Bool
    ) async throws -> Int {
        try await store.finalizeAssistantLine(
            sessionID: sessionID,
            lineID: lineID,
            text: text,
            interrupted: interrupted
        )
    }

    /// 分人的状态变了（协商失败 / 运行中降级）。**只动这两列**，正文与时间码不参与。
    public func updateSessionDiarization(
        id: String,
        state: SessionDiarizationState,
        note: String? = nil
    ) async {
        try? await store.updateSessionDiarization(id: id, state: state, note: note)
    }

    public var isIdle: Bool { occupancy == nil }

    public var ownershipText: String {
        guard let occupancy else { return "麦克风空闲" }
        if occupancy.isProcessing { return "正在整理\(occupancy.kind.title)…" }
        if phase == .interrupted { return "\(occupancy.kind.title)已中断 · \(Self.formatted(elapsed))" }
        if phase == .preparing { return "\(occupancy.kind.title)正在准备…" }
        return "\(occupancy.kind.title)进行中 · \(Self.formatted(elapsed))"
    }

    /// 点第二行进**当前会话所在页**；空闲时进实时字幕页（§5.1）。
    public var ownershipRoute: AppRoute {
        occupancy?.kind.route ?? .captions
    }

    /// 与侧边栏第一行同款的走时格式：`12:04`，超过一小时给 `1:02:40`。
    ///
    /// `nonisolated`：这是纯函数，导出器（不跑在界面线程上）用它拼同一份时长口径，
    /// 免得同一段时长在侧边栏和导出物里长得不一样。
    public nonisolated static func formatted(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
