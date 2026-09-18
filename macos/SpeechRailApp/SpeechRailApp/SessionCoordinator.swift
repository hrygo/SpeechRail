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
    /// 正在等用户回答的那一件事；`nil` 表示没有待确认的动作。
    public private(set) var pendingAction: PendingAction?
    public private(set) var pendingConfirmation: Confirmation?
    /// 开库失败时的可读结论。库里读不出来时界面要给一条结论，而不是空白列表。
    public private(set) var storeFailure: String?
    /// 走时。占用期间每秒推进一次，供侧边栏与状态带显示「12:04」。
    public private(set) var elapsed: TimeInterval = 0
    /// 当前 epoch 内已经落库的行数水位（中断区间与「提问时的转录水位」都用它）。
    public private(set) var lineWatermark = 0

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

    private let store: SessionStore
    private let defaults: UserDefaults
    private var clockTask: Task<Void, Never>?

    /// 「以后不再询问」的持久化键。只对助手 / 字幕生效。
    private static let doNotAskAgainKey = "speechrail.session.skipSwitchConfirmation"

    public init(store: SessionStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    /// 开库（含 `WAL` 与 `user_version` 迁移）。App 启动时调一次；失败只记录结论，
    /// 不阻塞三页的其余部分——记录库不可用不该让「看服务状态」也一起坏掉。
    public func openStore() async {
        do {
            try await store.open()
            storeFailure = nil
        } catch {
            storeFailure = error.localizedDescription
        }
    }

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
            message: "结束之后会先分完最后半句、再生成纪要；转录现在就能看。",
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
            await stopCapture(endingWith: .user)
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
        startClock()
        do {
            try await starter?(kind)
        } catch {
            // 受阻：设备租约、走时、占用一起退回。**不留一条空记录**——
            // 「麦克风未授权」不该在记录库里留下一条什么都没有的会话。
            releaseDevices()
            stopClock()
            occupancy = nil
            startedAt = nil
            elapsed = 0
            phase = .idle
            throw error
        }
    }

    /// 首个 PCM 已发送：库里的行此刻才存在（由能力层调 `createSession` 之后回报）。
    public func sessionDidStartRecording(id: String) {
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
        if let activeSessionID {
            try? await store.finalizeSession(id: activeSessionID, endReason: reason)
        }
        releaseDevices()
        stopClock()
        activeSessionID = nil
        occupancy = nil
        startedAt = nil
        elapsed = 0
        lineWatermark = 0
        lastInterruption = nil
        phase = .idle
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

    public func listSummaries(kind: SessionKind? = nil) async throws -> [SessionSummary] {
        try await store.listSessions(kind: kind)
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

    /// 最新一版纪要（含正文）。导出物把它放在转录前面（§6.3.2）；
    /// 还没生成纪要时给 `nil`，导出物就只出转录。
    public func latestMinutes(sessionID: String) async throws -> MinutesVersion? {
        let versions = try await store.minutesVersions(sessionID: sessionID)
        return versions.first { $0.isLatest } ?? versions.first
    }

    public func removeSession(id: String) async throws {
        try await store.removeSession(id: id)
    }

    /// 能力层写库的唯一入口（§5.1：业务模块不持有连接、不写 SQL）。
    public func createSession(_ draft: SessionDraft) async throws -> SessionRecord {
        try await store.createSession(draft)
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
