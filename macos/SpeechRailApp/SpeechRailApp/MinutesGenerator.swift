import Foundation
import Observation

// 纪要生成（`SESSIONS-SPEC` §6.2 / §16.8，`TECHNICAL-DESIGN` §5.8）。
//
// 四条口径，逐条都有来源：
//
//   1. **排队、单飞、租约回收**。转录封存之后才写 `queued`；认领带租约，
//      过期租约可以被下一次启动回收——否则 App 崩一次，那一版纪要就永远卡在 `running`。
//   2. **长任务用 Responses 的 background 模式 + 轮询**。纪要要跑几十秒到几分钟，
//      不该把界面挂在一条请求上。
//   3. **重新生成只新增版本**。`version = n+1`、`is_latest` 指向最新，旧版仍可看可导出。
//   4. **失败给可读原因，不动转录**。`纪要没整理出来 · 转录已经存好了`。
//
// 隐私口径（§5.8 的显式要求，界面必须照说）：默认 `store=false`，但**后台模式下即使
// `store=false`，响应数据仍会在服务端临时落盘约 10 分钟**以支持异步执行与轮询。
// 所以这里**不许**出现"内容没经过服务器"这类说法。


@MainActor
@Observable
public final class MinutesGenerator {
    public enum State: Equatable, Sendable {
        case idle
        case queued
        case running
        case ready
        case failed(String)
        /// 用户停下了这一次（MC-30）。与 `failed` 分开：下一步不同，也不该显示成"整理失败"。
        case cancelled
        /// 远端可能已经受理，本地没拿到回执（MC-28、§8.5）。**不自动重发。**
        case submissionUnknown

        public var title: String {
            switch self {
            case .idle: "还没有纪要"
            case .queued: "正在排队整理…"
            case .running: "正在整理会议…"
            case .ready: "纪要在下面"
            case .failed: "纪要没整理出来 · 文字记录已经存好了"
            case .cancelled: "整理已停止 · 文字记录已经存好了"
            case .submissionUnknown: "提交结果待确认 · 文字记录已经存好了"
            }
        }
    }

    public private(set) var state: State = .idle
    public private(set) var versions: [MinutesVersion] = []
    public private(set) var latestBody: String?
    /// 需复核的纪要版本 id（MC-46 后半句）：来源修订晚于纪要创建。
    /// `reload` 时随版本列表一起刷新；纯读判断，不写库。
    public private(set) var versionsNeedingReview: Set<String> = []
    /// 刚整理出来的这一版的核对报告（MA-08）。
    ///
    /// 有 `needsReview` 的条目**仍然留在正文里**，但不升可信：界面据此说明
    /// 哪里要核对，而"有引用"本身不算核对通过。
    public private(set) var candidateReview: MinutesEvidenceValidator.Report?
    /// 刚整理出来的这一版的覆盖账本（MA-09）。
    ///
    /// 为 nil 表示这一版没有分窗账本（单窗或旧版本）。**不**把 nil 当成
    /// "全部覆盖"：那正好是计划禁止的那种"100% 完成"。
    public private(set) var coverage: MinutesCoverageLedger?
    /// 还能局部重试的窗口个数（MC-40）。0 表示没有缺口可补。
    public var retryableWindowCount: Int {
        coverage?.failedWindowIndexes.count ?? 0
    }
    /// 最近一次整理用的服务端响应 id（诊断用；它不是用户内容）。
    public private(set) var lastResponseID: String?
    /// 停止之后关于**远端**的那半句话（MC-30）。本地停下是确定的，
    /// 远端停没停不是——没确认就要说出来，不能替用户断言。
    public private(set) var remoteCancellationNote: String?
    /// 当前设置与在跑任务冻结的那份不一致（MC-32）。界面据此说明
    /// 「新配置从下一次任务生效」，当前任务不跟着换端点。
    public private(set) var jobConfigDiffersFromCurrent = false
    /// 这一次失败是不是**配置问题**（没填模型 / 地址不对 / 端点没有 Responses API）。
    /// 由它决定失败条给哪个出口：配置问题给「去设置里填对话模型」，其它给「重新生成」——
    /// 配置没填时按「重新生成」只会原样再失败一次，是个死循环（用户 2026-09-19：
    /// 一次性设置要在最需要它的那一刻给）。
    private var failedOnSetup = false

    /// 这一次失败本身**是不是配置引起的**（生成器管不到配置，只如实报自己看到的）。
    /// 界面要不要给「去设置里填」，由 `MeetingSession.minutesNeedsSetup` 合并"当前配置
    /// 仍然空着"之后再判——重启后 `reload` 只读得回失败原因文本（库里没有 code 列）。
    public var failureNeedsSetup: Bool {
        guard case .failed = state else { return false }
        return failedOnSetup
    }

    private let coordinator: SessionCoordinator
    private let provider = LLMProvider()
    /// 一次只整理一份（§5.8「同会话单飞」）。
    private var inFlight: String?
    /// 在飞的那一次整理。`stop()` 取消的是它——界面上的「停止整理」要真的停下，
    /// 而不是只把按钮换掉（设计稿 `会议助手 · 会议页 · 整理中` 给出这个出口）。
    private var runTask: Task<Void, Never>?
    /// 在飞的那一版纪要行。停止时按它写取消请求——取消的是**指定任务**，
    /// 不影响另一场正在记录的会议，也不删旧纪要（MC-22/MC-30）。
    private var inFlightMinutesID: String?
    /// 租约时长。它比一次整理该花的时间长一点，短了会被下一个启动误回收。
    private static let lease: TimeInterval = 600
    /// 心跳间隔：租约的三分之一。整理要跑十几分钟，只写一次租约的话后半程会被误回收。
    private static let heartbeatInterval: TimeInterval = 200

    public init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
    }

    /// 转录封存之后调它：排队 → 认领 → 生成 → 落库（§8.2 的最后一步）。
    public func generate(sessionID: String, configuration: LLMConfiguration) async {
        await generate(
            sessionID: sessionID,
            resolvedConfiguration: ResolvedLLMConfiguration(
                configuration: configuration,
                apiKey: LLMKeychain.load(),
                origin: .global
            )
        )
    }

    /// 应用入口传入模块解析结果；后台任务不再自行读取 global Key。
    public func generate(
        sessionID: String,
        resolvedConfiguration: ResolvedLLMConfiguration
    ) async {
        guard inFlight == nil else { return }
        inFlight = sessionID
        defer { inFlight = nil }
        state = .queued
        failedOnSetup = false
        remoteCancellationNote = nil
        jobConfigDiffersFromCurrent = false
        // 新一次整理开始：上一版的覆盖账本不能继续挂在新版本上。
        coverage = nil
        let configuration = resolvedConfiguration.configuration

        let version: MinutesVersion
        do {
            let lines = try await coordinator.lines(sessionID: sessionID)
            let names = (try? await coordinator.speakerNames(sessionID: sessionID)) ?? [:]
            let units = Self.sourceUnits(lines: lines, names: names)
            let transcript = Self.transcript(units: units)
            guard !transcript.isEmpty else {
                state = .failed("这一场没有可整理的正文。")
                return
            }
            // MC-43/MC-35/MC-36：快照输入 = 转录终稿 + 已校验的用户补充。
            // 未逐字命中的引文整条丢弃，不进入 prompt。
            let supplements = Self.userSupplements(
                exchanges: (try? await coordinator.innerOSExchanges(sessionID: sessionID)) ?? [],
                verifiedExchangeIDs: await Self.verifiedSupplementIDs(coordinator: coordinator, sessionID: sessionID)
            )
            // MA-07：配置与来源快照在**排队这一刻**冻下来（MC-20/MC-32）。
            // 任务跑着的时候改设置，当前任务不跟着换；新配置从下一次任务生效。
            let jobConfig = MinutesJobConfig(configuration)
            let snapshotID = (try? await coordinator.latestSourceSnapshot(sessionID: sessionID))?.id
            version = try await coordinator.enqueueMinutes(
                sessionID: sessionID,
                model: configuration.model.isEmpty ? nil : configuration.model,
                promptChars: transcript.count,
                configSnapshot: jobConfig.fingerprint,
                snapshotID: snapshotID
            )
            versions = try await coordinator.minutesVersions(sessionID: sessionID)
            versionsNeedingReview = await Self.reviewIDs(coordinator: coordinator, sessionID: sessionID)
            guard !configuration.isConfigured else {
                let task = Task { [weak self] in
                    _ = try? await self?.run(
                        version: version,
                        units: units,
                        supplements: supplements,
                        jobConfig: jobConfig,
                        resolvedConfiguration: resolvedConfiguration
                    )
                }
                runTask = task
                await task.value
                runTask = nil
                return
            }
            // 没配大模型：文字记录已经封存好了，这一版如实失败（§9 第 18 行）。
            try? await coordinator.failMinutes(
                minutesID: version.id,
                reason: "还没有配置对话模型（设置 → 会话）。文字记录已经存好，配好之后可以重新生成。"
            )
            failedOnSetup = true
            state = .failed("还没有配置对话模型。文字记录已经存好，配好之后可以重新生成。")
        } catch {
            state = .failed(error.localizedDescription)
        }
        versions = (try? await coordinator.minutesVersions(sessionID: sessionID)) ?? versions
        versionsNeedingReview = await Self.reviewIDs(coordinator: coordinator, sessionID: sessionID)
    }

    /// 重开 App 之后回收过期租约：`running` 且租约过期的那些行可以被重新认领（§5.8）。
    public func recoverPending(configuration: LLMConfiguration) async {
        await recoverPending(
            resolvedConfiguration: ResolvedLLMConfiguration(
                configuration: configuration,
                apiKey: LLMKeychain.load(),
                origin: .global
            )
        )
    }

    public func recoverPending(resolvedConfiguration: ResolvedLLMConfiguration) async {
        // MC-27 收尾：按原 job 身份认领续跑，不新建版本。
        // generate() 会 enqueue 新版本，这里必须走 pendingMinutesRows + run 原行。
        guard let pending = try? await coordinator.pendingMinutesRows() else { return }
        for row in pending {
            await resume(row: row, resolvedConfiguration: resolvedConfiguration)
        }
    }

    /// 认领指定的原 job 并续跑：不排新版本，attempt 代际由 claim 推进（MC-27）。
    private func resume(
        row: MinutesVersion,
        resolvedConfiguration: ResolvedLLMConfiguration
    ) async {
        guard inFlight == nil else { return }
        inFlight = row.sessionID
        defer { inFlight = nil }
        state = .queued
        failedOnSetup = false
        coverage = nil
        do {
            let lines = try await coordinator.lines(sessionID: row.sessionID)
            let names = (try? await coordinator.speakerNames(sessionID: row.sessionID)) ?? [:]
            let units = Self.sourceUnits(lines: lines, names: names)
            let transcript = Self.transcript(units: units)
            guard !transcript.isEmpty else {
                state = .failed("这一场没有可整理的正文。")
                return
            }
            // MC-43/MC-35/MC-36：恢复续跑同样走快照输入，已校验的用户补充才带入。
            let supplements = Self.userSupplements(
                exchanges: (try? await coordinator.innerOSExchanges(sessionID: row.sessionID)) ?? [],
                verifiedExchangeIDs: await Self.verifiedSupplementIDs(coordinator: coordinator, sessionID: row.sessionID)
            )
            versions = try await coordinator.minutesVersions(sessionID: row.sessionID)
            versionsNeedingReview = await Self.reviewIDs(coordinator: coordinator, sessionID: row.sessionID)
            let configuration = resolvedConfiguration.configuration
            // MC-32：恢复的是**原来那次任务**，它答应过用哪一套配置。
            // 用户这时改了设置，当前任务也不换端点——界面只说明新配置从下一次生效。
            // 读不出的指纹（老行没有这一列）才退回当前设置，那不是猜，是没有可还原的东西。
            let currentConfig = MinutesJobConfig(configuration)
            let jobConfig = MinutesJobConfig.parse(row.configSnapshot) ?? currentConfig
            jobConfigDiffersFromCurrent = jobConfig != currentConfig
            guard jobConfig.configuration.isConfigured else {
                // 没配大模型：不断原 job，只如实记失败；行仍可被下次恢复认领。
                _ = try? await coordinator.failMinutes(
                    minutesID: row.id,
                    reason: "还没有配置对话模型（设置 → 会话）。文字记录已经存好，配好之后可以重新生成。"
                )
                failedOnSetup = true
                state = .failed("还没有配置对话模型。文字记录已经存好，配好之后可以重新生成。")
                versions = (try? await coordinator.minutesVersions(sessionID: row.sessionID)) ?? versions
                versionsNeedingReview = await Self.reviewIDs(coordinator: coordinator, sessionID: row.sessionID)
                return
            }
            let task = Task { [weak self] in
                _ = try? await self?.run(
                    version: row,
                    units: units,
                    supplements: supplements,
                    jobConfig: jobConfig,
                    resolvedConfiguration: resolvedConfiguration
                )
            }
            runTask = task
            await task.value
            runTask = nil
        } catch {
            state = .failed(error.localizedDescription)
        }
        versions = (try? await coordinator.minutesVersions(sessionID: row.sessionID)) ?? versions
        versionsNeedingReview = await Self.reviewIDs(coordinator: coordinator, sessionID: row.sessionID)
    }

    /// 「停止整理」：取消在飞的那一次。**转录不受影响**——它早就封存好了，
    /// 所以这里只停这一版，用户可以随时重新生成。
    ///
    /// 顺序是刻意的（MA-07/MC-30）：**先**把取消请求写进库，再停本地任务。
    /// 写库之后崩溃，重启仍看得见"有人要求停这一条"，而不是只停了个内存里的 Task，
    /// 留下一条永远转圈的 `running`。停掉的这一版落成 `cancelled` 而不是"整理失败"——
    /// 用户不要了和没整理出来，下一步不一样。
    public func stop() {
        let task = runTask
        let minutesID = inFlightMinutesID
        Task { [weak self] in
            if let minutesID {
                _ = try? await self?.coordinator.requestCancelMinutes(minutesID: minutesID)
            }
            task?.cancel()
        }
    }

    /// 界面上要不要给「停止整理」这个出口。
    public var isBusy: Bool {
        switch state {
        case .queued, .running: true
        default: false
        }
    }

    /// 局部重试（MC-40）：**只**重跑失败的窗口，成功窗口的候选直接复用。
    ///
    /// 三条边界，都是为了不覆盖用户已经核对过的东西：
    /// 1. 已采用的版本拒绝重开——那正是用户核对过的一版；
    /// 2. 没有失败窗口时不做任何事，不新建版本、不发请求；
    /// 3. 重跑完重新归并时以来源身份去重，同一条待办不会因为重跑多出一条。
    public func retryFailedWindows(
        sessionID: String,
        configuration: LLMConfiguration
    ) async {
        await retryFailedWindows(
            sessionID: sessionID,
            resolvedConfiguration: ResolvedLLMConfiguration(
                configuration: configuration,
                apiKey: LLMKeychain.load(),
                origin: .global
            )
        )
    }

    public func retryFailedWindows(
        sessionID: String,
        resolvedConfiguration: ResolvedLLMConfiguration
    ) async {
        guard inFlight == nil else { return }
        guard let target = try? await coordinator.latestMinutes(sessionID: sessionID) else { return }
        let windows = (try? await coordinator.minutesWindows(minutesID: target.id)) ?? []
        let failed = windows.filter { $0.outcome != .processed }
        guard !failed.isEmpty else {
            state = .failed("这一版没有整理失败的窗口，不需要重试。")
            return
        }
        inFlight = sessionID
        defer { inFlight = nil }
        state = .queued
        failedOnSetup = false
        do {
            let lines = try await coordinator.lines(sessionID: sessionID)
            let names = (try? await coordinator.speakerNames(sessionID: sessionID)) ?? [:]
            let units = Self.sourceUnits(lines: lines, names: names)
            guard !units.isEmpty else {
                state = .failed("这一场没有可整理的正文。")
                return
            }
            let supplements = Self.userSupplements(
                exchanges: (try? await coordinator.innerOSExchanges(sessionID: sessionID)) ?? [],
                verifiedExchangeIDs: await Self.verifiedSupplementIDs(
                    coordinator: coordinator,
                    sessionID: sessionID
                )
            )
            // 重试认的是**原来那次任务**冻结的配置：换了端点的结果
            // 不能混进同一版里（MC-32）。
            let currentConfig = MinutesJobConfig(resolvedConfiguration.configuration)
            let jobConfig = MinutesJobConfig.parse(target.configSnapshot) ?? currentConfig
            jobConfigDiffersFromCurrent = jobConfig != currentConfig
            guard jobConfig.configuration.isConfigured else {
                failedOnSetup = true
                state = .failed("还没有配置对话模型。文字记录已经存好，配好之后可以重新生成。")
                return
            }
            // 重新开成 `running` 才能续跑；带 fencing，已采用的版本会被拒绝。
            let reopened = try await coordinator.reopenMinutesForWindowRetry(
                minutesID: target.id,
                expectedAttempts: target.attempts,
                lease: Self.lease
            )
            guard reopened else {
                state = .failed("这一版已经采用，或者已经被别的整理任务接管，没有重试。")
                return
            }
            var claimed = target
            claimed.status = .running
            claimed.attempts = target.attempts + 1
            let task = Task { [weak self] in
                _ = try? await self?.run(
                    claimed: claimed,
                    units: units,
                    supplements: supplements,
                    jobConfig: jobConfig,
                    resolvedConfiguration: resolvedConfiguration
                )
            }
            runTask = task
            await task.value
            runTask = nil
        } catch {
            state = .failed(error.localizedDescription)
        }
        versions = (try? await coordinator.minutesVersions(sessionID: sessionID)) ?? versions
        versionsNeedingReview = await Self.reviewIDs(coordinator: coordinator, sessionID: sessionID)
    }

    /// 读库刷新（界面切换版本、重新打开这一场时调）。
    public func reload(sessionID: String) async {
        versions = (try? await coordinator.minutesVersions(sessionID: sessionID)) ?? []
        versionsNeedingReview = await Self.reviewIDs(coordinator: coordinator, sessionID: sessionID)
        let latest = try? await coordinator.latestMinutes(sessionID: sessionID)
        // 核对报告随版本一起存，所以重开这一场仍然知道"哪里要核对"。
        let fallback = try? await coordinator.currentMinutes(sessionID: sessionID)
        candidateReview = (latest ?? fallback)?.review
        // 覆盖账本随版本一起存，所以重开这一场仍然知道"哪里没整理到"。
        coverage = (latest ?? fallback)?.coverage
        switch latest?.status {
        case .ready:
            latestBody = latest?.body
            state = .ready
        case .running:
            latestBody = latest?.body
            state = .running
        case .queued:
            latestBody = latest?.body
            state = .queued
        case .failed:
            // MC-25：新尝试失败不丢采用版正文；状态仍如实报失败，不伪装成功。
            let current = try? await coordinator.currentMinutes(sessionID: sessionID)
            latestBody = current?.body
            state = .failed(latest?.failureReason ?? "没有可读的原因")
        case .cancelled:
            // MC-30：停掉的这一版不算失败，正文仍按"采用版优先"回退，
            // 远端那句"无法确认"在没有本次会话内上下文时必须原样说。
            let current = try? await coordinator.currentMinutes(sessionID: sessionID)
            latestBody = current?.body
            remoteCancellationNote = "本地已经停下；远端有没有一起停下无法确认。"
            state = .cancelled
        case .submissionUnknown:
            // MC-28：远端可能已经受理，本地没有回执。不自动重发，也不显示成"没整理出来"。
            let current = try? await coordinator.currentMinutes(sessionID: sessionID)
            latestBody = current?.body
            state = .submissionUnknown
        default:
            latestBody = nil
            remoteCancellationNote = nil
            state = .idle
        }
    }

    /// 需复核的纪要版本 id（MC-46 后半句）：任一说话人修订事件晚于纪要创建时间。
    /// 纯读判断，不写库；修订查询失败时返回空集，不误标复核。
    /// 比较逻辑在 Domain 层（`MinutesReview`），此处只组装库里读到的数据。
    static func reviewIDs(coordinator: SessionCoordinator, sessionID: String) async -> Set<String> {
        guard let revisions = try? await coordinator.speakerRevisions(sessionID: sessionID),
              !revisions.isEmpty
        else { return [] }
        let versions = (try? await coordinator.minutesVersions(sessionID: sessionID)) ?? []
        return MinutesReview.reviewIDs(
            versions: versions.map { (id: $0.id, createdAt: $0.createdAt, parentID: $0.parentMinutesID) },
            revisions: revisions.map(\.createdAt)
        )
    }

    /// 已校验的用户补充 id：问答被显式选进纪要、且其全部引文逐字命中所指转录行。
    /// 任一条引文未通过即整条丢弃，不部分带入（MC-35/MC-36）。
    /// 纯读校验，不写库。
    static func verifiedSupplementIDs(
        coordinator: SessionCoordinator,
        sessionID: String
    ) async -> Set<String> {
        guard let exchanges = try? await coordinator.innerOSExchanges(sessionID: sessionID) else {
            return []
        }
        var verified: Set<String> = []
        for exchange in exchanges where exchange.inMinutes {
            guard let checks = try? await coordinator.verifyEvidenceQuotes(exchangeID: exchange.id),
                  !checks.isEmpty,
                  checks.allSatisfy(\.verified)
            else { continue }
            verified.insert(exchange.id)
        }
        return verified
    }

    /// 窗口预算（MA-09）。
    ///
    /// 当前配置里**没有** provider/model 的上下文能力，所以这里用保守的
    /// 实验起点，而不是"provider 接受了就说明装得下"。真实取值要按目标模型
    /// 校准后改这里（§6.3）。
    static let windowBudget = MinutesWindowBudget()

    /// 在飞任务拿到的远端响应 id。取消时逐个去问远端停没停（MC-30）。
    private var inFlightResponseIDs: [String] = []

    private func run(
        version: MinutesVersion,
        units: [MinutesSourceUnit],
        supplements: String = "",
        jobConfig: MinutesJobConfig,
        resolvedConfiguration: ResolvedLLMConfiguration
    ) async throws {
        let claimed = try await coordinator.claimMinutes(sessionID: version.sessionID, lease: Self.lease)
        guard let claimed else { return }
        try await run(
            claimed: claimed,
            units: units,
            supplements: supplements,
            jobConfig: jobConfig,
            resolvedConfiguration: resolvedConfiguration
        )
    }

    /// 整理一个**已认领**的任务。认领在门外：正常生成走 `claimMinutes`，
    /// 局部重试走 `reopenMinutesForWindowRetry`（同一代际规则，不同入口）。
    private func run(
        claimed: MinutesVersion,
        units: [MinutesSourceUnit],
        supplements: String,
        jobConfig: MinutesJobConfig,
        resolvedConfiguration: ResolvedLLMConfiguration
    ) async throws {
        state = .running
        inFlightMinutesID = claimed.id
        defer { inFlightMinutesID = nil }

        // MC-32：用任务冻结的那份配置，不跟着当前设置换端点。
        // 密钥仍然在调用时按安全来源解析、不落库（§8.3）——指纹只回答"是不是同一套配置"。
        let configuration = jobConfig.configuration
        let key = resolvedConfiguration.apiKey
        // 心跳：租约定期续一次。整理要跑十几分钟，只写一次租约的话后半程会被误回收。
        let heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.heartbeatInterval))
                guard !Task.isCancelled, let self else { return }
                let renewed = (try? await self.coordinator.renewMinutesLease(
                    minutesID: claimed.id,
                    expectedAttempts: claimed.attempts,
                    lease: Self.lease
                )) ?? false
                // 续不上说明行已被新 owner 接管或已落终态：不再续，也不去覆盖它。
                if !renewed { return }
            }
        }
        defer { heartbeat.cancel() }
        do {
            // §6.3：按 token 预算分窗，每个来源单元恰好 owned 一次。
            // 短会得到单窗，走的是**同一条**验证与落库路径。
            let windows = MinutesWindowPlanner.plan(units: units, budget: Self.windowBudget)
            // 已经跑过的窗口（崩溃恢复、局部重试）：直接复用，不重发请求。
            let previous = (try? await coordinator.minutesWindows(minutesID: claimed.id)) ?? []
            var records: [MinutesWindowRecord] = []
            var candidates: [MinutesCandidateV2] = []

            for window in windows {
                if Task.isCancelled { throw LLMError.cancelled }
                let stored = previous.first { $0.index == window.index }
                // 这一窗已经有候选：复用。整场重发可能重复计费，
                // 也可能覆盖用户已经核对过的结果（MC-28/MC-40）。
                if let ready = stored, ready.outcome == .processed, ready.candidate != nil {
                    records.append(ready)
                    if let candidate = ready.candidate { candidates.append(candidate) }
                    continue
                }
                let responseID = try await responseIDFor(
                    claimed: claimed,
                    window: window,
                    stored: stored,
                    units: units,
                    supplements: supplements,
                    configuration: configuration,
                    key: key,
                    isOnlyWindow: windows.count == 1
                )
                lastResponseID = responseID
                inFlightResponseIDs.append(responseID)
                let text = try await provider.pollBackground(
                    configuration: configuration,
                    apiKey: key,
                    responseID: responseID
                )
                let record: MinutesWindowRecord
                switch MinutesCandidateCodec.prepareWindow(text: text, window: window) {
                case .prepared(let prepared):
                    candidates.append(prepared.candidate)
                    record = MinutesWindowRecord(
                        index: window.index,
                        ownedUnitIDs: window.owned.map(\.id),
                        contextUnitIDs: (window.contextBefore + window.contextAfter).map(\.id),
                        outcome: .processed,
                        candidateJSON: Self.encode(prepared.candidate),
                        remoteResponseID: responseID
                    )
                case .failed(let kind, let reason):
                    // 截断与失败分开记：截断的尾部没拿全，不能当成"整理好了"（§6.3）。
                    record = MinutesWindowRecord(
                        index: window.index,
                        ownedUnitIDs: window.owned.map(\.id),
                        contextUnitIDs: (window.contextBefore + window.contextAfter).map(\.id),
                        outcome: kind == .incomplete ? .truncated : .failed,
                        failureReason: reason,
                        remoteResponseID: responseID
                    )
                }
                // 每跑完一窗就落一行（§7.6）：崩了以后从已完成的窗口继续，
                // 不把整场重新发一遍。父行已被新 owner 接管时不写。
                let recorded = (try? await coordinator.recordMinutesWindow(
                    minutesID: claimed.id,
                    expectedAttempts: claimed.attempts,
                    record: record
                )) ?? false
                guard recorded else {
                    throw LLMError.transport("这一版已被新的整理任务接管，这次的结果没有写回。")
                }
                records.append(record)
            }

            // 覆盖账本：哪些来源单元整理到了、哪些没有（§6.3）。
            let ledger = MinutesCoverageLedger(
                eligibleUnitIDs: units.map(\.id),
                windows: records.map {
                    MinutesCoverageLedger.WindowRecord(
                        index: $0.index,
                        ownedUnitIDs: $0.ownedUnitIDs,
                        outcome: $0.outcome,
                        failureReason: $0.failureReason
                    )
                }
            )
            let coverageText = try? Self.encode(ledger)

            guard !candidates.isEmpty else {
                // 一个窗口都没成功：整场如实失败，不发布半成品。
                let reason = records.compactMap(\.failureReason).first
                    ?? "没有整理出可用的内容。"
                _ = try? await coordinator.failMinutesIfOwner(
                    minutesID: claimed.id,
                    expectedAttempts: claimed.attempts,
                    reason: reason
                )
                failedOnSetup = false
                state = .failed(reason)
                return
            }

            // §6.3 reduce：以来源身份去重，跨窗撤回保留两个事件并标未确认。
            let merged = MinutesCandidateMerger.merge(
                windowCandidates: candidates,
                units: units,
                coverageNote: ledger.isComplete ? nil : ledger.summary()
            )
            let body = MinutesCandidateCodec.markdown(
                for: merged.candidate,
                report: merged.report
            )
            // MC-29：凭认领代际提交；行已被新 owner 接管时不改写、不谎报成功。
            // 候选、核对报告、覆盖账本、条目、锚点与窗口进度一起落库：
            // 少任何一样都会让"这一版覆盖到哪"和正文对不上（§6.3）。
            let revisionIDs = (try? await coordinator.latestRevisionIDsByLine(sessionID: claimed.sessionID)) ?? [:]
            let unitsByID = Dictionary(units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let drafts = MinutesCandidateCodec.itemDrafts(
                for: merged.candidate,
                report: merged.report,
                unitsByID: unitsByID,
                revisionIDsByLine: revisionIDs
            )
            let committed = (try? await coordinator.saveMinutesCandidate(
                minutesID: claimed.id,
                expectedAttempts: claimed.attempts,
                body: body,
                model: configuration.model.isEmpty ? nil : configuration.model,
                candidate: try? Self.encode(merged.candidate),
                review: try? Self.encode(merged.report),
                items: drafts,
                snapshotID: claimed.snapshotID,
                coverage: coverageText,
                windows: records.sorted { $0.index < $1.index }
            )) ?? false
            guard committed else {
                versions = (try? await coordinator.minutesVersions(sessionID: claimed.sessionID)) ?? versions
                versionsNeedingReview = await Self.reviewIDs(coordinator: coordinator, sessionID: claimed.sessionID)
                state = .failed("这一版已被新的整理任务接管，旧结果没有覆盖。")
                return
            }
            latestBody = body
            failedOnSetup = false
            remoteCancellationNote = nil
            candidateReview = merged.report
            coverage = ledger
            state = .ready
        } catch {
            // 取消与失败要分开说：用户按的「停止整理」不该在记录里留下一条"整理失败"。
            let cancelled = Task.isCancelled || (error as? LLMError) == .cancelled
            if cancelled {
                await finishCancellation(claimed: claimed, configuration: configuration, key: key)
                return
            }
            // §8.5：请求可能已被受理，只是回执没到手。不无条件重发，也不谎称"失败"。
            if MinutesSubmissionCertainty.classify(error) == .unknown {
                _ = try? await coordinator.markMinutesSubmissionUnknown(
                    minutesID: claimed.id, expectedAttempts: claimed.attempts
                )
                failedOnSetup = false
                state = .submissionUnknown
                versions = (try? await coordinator.minutesVersions(sessionID: claimed.sessionID)) ?? versions
                versionsNeedingReview = await Self.reviewIDs(coordinator: coordinator, sessionID: claimed.sessionID)
                return
            }
            let reason = Self.readableReason(for: error)
            _ = try? await coordinator.failMinutesIfOwner(
                minutesID: claimed.id, expectedAttempts: claimed.attempts, reason: reason
            )
            // 地址写错、服务没有 Responses API 这类失败，按「重新生成」只会再撞一次；
            // 它们和「没填模型」是同一类下一步：去设置里改配置。
            if let llm = error as? LLMError {
                switch llm {
                case .notConfigured, .badBaseURL, .notResponsesAPI: failedOnSetup = true
                default: failedOnSetup = false
                }
            } else {
                failedOnSetup = false
            }
            state = .failed(reason)
        }
    }

    /// 拿这一窗要轮询的远端响应 id。
    ///
    /// 三条来源，按可靠性排序（MC-28/MC-40）：
    /// 1. 这一窗上次已经拿到的 id —— 崩溃恢复查**原请求**，不重发；
    /// 2. 单窗时 `minutes` 行上的旧字段（MA-07 既有行为，短会不受影响）；
    /// 3. 新发一次，拿到 id 立刻随窗口行落库。
    @discardableResult
    private func responseIDFor(
        claimed: MinutesVersion,
        window: MinutesWindow,
        stored: MinutesWindowRecord?,
        units: [MinutesSourceUnit],
        supplements: String,
        configuration: LLMConfiguration,
        key: String?,
        isOnlyWindow: Bool
    ) async throws -> String {
        if let existing = stored?.remoteResponseID, !existing.isEmpty {
            lastResponseID = existing
            return existing
        }
        if isOnlyWindow, let existing = claimed.remoteResponseID, claimed.hasRemoteResponse {
            lastResponseID = existing
            return existing
        }
        // 用户已经按下停止，就不要再把这一场发出去。
        if claimed.cancelRequestedAt != nil {
            throw LLMError.cancelled
        }
        let responseID = try await provider.startBackground(
            configuration: configuration,
            messages: Self.prompt(
                transcript: Self.windowTranscript(window),
                supplements: supplements
            ),
            apiKey: key,
            maxOutputTokens: 4_000,
            textFormat: MinutesCandidateCodec.jsonSchema
        )
        lastResponseID = responseID
        if isOnlyWindow {
            // 单窗沿用行上的字段：MA-07 的恢复路径对短会保持原样。
            let recorded = (try? await coordinator.recordMinutesRemoteResponse(
                minutesID: claimed.id,
                expectedAttempts: claimed.attempts,
                responseID: responseID
            )) ?? false
            guard recorded else {
                // 记不进去说明行已被新 owner 接管。请求已经发出去了，但结果不再往这行写，
                // 也不谎报成功——远端那一侧的事实不由这里替用户断言。
                throw LLMError.transport("这一版已被新的整理任务接管，这次的结果没有写回。")
            }
        }
        return responseID
    }

    /// 编码落库用的 JSON 文本。编不出来返回 nil：那一列就空着，
    /// 读回时按"没有"处理，不塞占位文本冒充内容。
    static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 取消落定：本地停、状态说"已停止"，远端给一句**如实的**结论（MC-30）。
    ///
    /// 远端取消只对已经拿到 id 的任务问得着；问不到、或端点没有这个接口，
    /// 就说"无法确认"——本地停下来是我们知道的事，远端停没停不是。
    private func finishCancellation(
        claimed: MinutesVersion,
        configuration: LLMConfiguration,
        key: String?
    ) async {
        _ = try? await coordinator.requestCancelMinutes(minutesID: claimed.id)
        let note: String
        // MA-09：分窗之后可能同时有多个远端任务在跑，挨个问、挨个如实说。
        // 只取消最后一个、其余默默留在远端跑着，是"停掉了"最常见的假话。
        var responseIDs = inFlightResponseIDs
        if let legacy = claimed.remoteResponseID ?? lastResponseID,
           !responseIDs.contains(legacy) {
            responseIDs.append(legacy)
        }
        if responseIDs.isEmpty {
            note = "这一次还没拿到远端受理凭据，没法去确认它有没有开始跑。"
        } else {
            var confirmed = 0
            var unsupported = 0
            var unconfirmed = 0
            for responseID in responseIDs {
                switch await provider.cancelBackground(
                    configuration: configuration,
                    apiKey: key,
                    responseID: responseID
                ) {
                case .confirmed: confirmed += 1
                case .unsupported: unsupported += 1
                case .unconfirmed: unconfirmed += 1
                }
            }
            var parts: [String] = []
            if confirmed > 0 { parts.append("\(confirmed) 个远端任务已确认停下") }
            if unsupported > 0 { parts.append("\(unsupported) 个远端任务停没停无法确认") }
            if unconfirmed > 0 { parts.append("\(unconfirmed) 个没能确认远端是否还在跑") }
            note = parts.joined(separator: "，") + "；文字记录和已经整理出的旧版本都还在。"
        }
        inFlightResponseIDs = []
        _ = try? await coordinator.cancelMinutesIfOwner(
            minutesID: claimed.id, expectedAttempts: claimed.attempts
        )
        remoteCancellationNote = note
        failedOnSetup = false
        state = .cancelled
        versions = (try? await coordinator.minutesVersions(sessionID: claimed.sessionID)) ?? versions
        versionsNeedingReview = await Self.reviewIDs(coordinator: coordinator, sessionID: claimed.sessionID)
    }

    /// 快照输入里的用户补充（MC-43）：组装走 Domain 层纯逻辑，
    /// 只含 `in_minutes = 1` 且全部引文已校验的问答（MC-35/MC-36），
    /// 逐条标“用户选择的 AI 补充”，不升级成会议事实。
    /// 送进 prompt 的补充正文是**用户挑过的那几句**，不是整段答案（MC-43）。
    ///
    /// 这一处和快照必须同时改：纪要是从 prompt 生成的，快照收窄了而 prompt
    /// 仍拿整段，等于用户没选的那半句被偷偷用了一次，"只该句进入"在最终产物上
    /// 根本不成立。`minutesExcerpt` 为 `nil`（迁移前的行、或用户显式选整条）
    /// 时才用整段答案。
    static func userSupplements(
        exchanges: [InnerOSExchange],
        verifiedExchangeIDs: Set<String>
    ) -> String {
        MinutesSupplements.render(
            questions: exchanges.map {
                (
                    id: $0.id,
                    question: $0.question,
                    answer: $0.minutesExcerpt ?? $0.answerText,
                    inMinutes: $0.inMinutes
                )
            },
            verifiedIDs: verifiedExchangeIDs
        )
    }

    /// Prompt。三条硬要求：**只依据转录与已校验的用户补充**、
    /// **不知道就写不知道**（与内心 OS 同一条规矩）、**用户补充不升级成会议事实**。
    /// 第四条是 MA-08 加的：**每条结论都要指明依据哪几个来源单元**，
    /// 并把"是建议还是有条件"如实写进 modality —— 验证器会拿这些去核对转录。
    static func prompt(transcript: String, supplements: String = "") -> [LLMMessage] {
        let userText: String
        if supplements.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            userText = "下面是这一场的转录：\n\n\(transcript)"
        } else {
            userText = "下面是这一场的转录：\n\n\(transcript)"
                + "\n\n下面是用户明确选择写进纪要的私密问答补充（标为用户选择的 AI 补充，"
                + "不得当成会议现场的发言或决定）：\n\n\(supplements)"
        }
        return [
            LLMMessage(
                role: .developer,
                text: "你负责把一段会议转录整理成结构化纪要。只依据转录与已校验的用户补充里的内容，"
                    + "不要补你没看到的事；转录里没提到的决定、待办、负责人一律不要写。"
                    + "用户补充只是用户选择的 AI 参考，不得写成参会人的发言、决定或待办归属。"
                    + "说话人用转录里已有的名字；同一个名字不要改写成别的称呼。"
                    + "每一条概述、结论、待办和未决问题都必须填 source_unit_ids，"
                    + "只能填转录里 [u1] [u2] 这样的编号，一条都没依据就不要写这一条。"
                    + "结论的 modality 要如实填：只是提议或待定就填 proposed，带前提就填 conditional，"
                    + "会上已经撤回的填 retracted，只有真的定了才填 decided。"
                    + "待办的 owner_text 和 due_expression 没有依据就留空字符串，"
                    + "不要根据日历或今天的日期推算，也不要为了填满而编一个。"
                    + "原文只是提议、没人认领的待办，commitment 填 proposed。"
                    + "数字、单位、否定词照抄原文，不要改写。"
                    + "标着「上下文·不可引用」的行只用来理解前后文，"
                    + "任何一条的 source_unit_ids 都不能填它们的编号——"
                    + "它们由相邻窗口负责，重复登记会让同一条待办出现两遍。"
                    + "confidence_notes 写这份纪要里最不确定的一两处；如果没什么不确定的就留空。",
                cacheBreakpoint: true
            ),
            LLMMessage(role: .user, text: userText),
        ]
    }

    /// 转录 → prompt 里的文本。**相对会话开始的秒**，与库里的时间码同源（§6.5）。
    static func render(lines: [TranscriptLine], names: [String: String] = [:]) -> String {
        lines.map { line in
            let speaker = line.speakerLabel.flatMap { names[$0] } ?? line.speakerLabel ?? "说话人"
            let start = line.tStart ?? 0
            return "[\(Self.timecode(start))] \(speaker)：\(line.text)"
        }.joined(separator: "\n")
    }

    /// 转录 → 来源单元。**id 在这里分配**（`u1`、`u2`…），模型只能引用、不能自己编（§7.5）。
    ///
    /// id 按**过滤后的顺序**编号，所以空行被丢掉时不会留下空洞，
    /// 模型看到的清单和这里看到的完全一致。
    static func sourceUnits(lines: [TranscriptLine], names: [String: String] = [:]) -> [MinutesSourceUnit] {
        let usable: [MinutesSourceUnit] = lines.compactMap { line -> MinutesSourceUnit? in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let speaker = line.speakerLabel.flatMap { names[$0] } ?? line.speakerLabel ?? "说话人"
            return MinutesSourceUnit(
                id: "",
                lineID: line.id,
                ordinal: line.ordinal,
                speaker: speaker,
                text: text,
                startSeconds: line.tStart
            )
        }
        return usable.enumerated().map { index, unit -> MinutesSourceUnit in
            var numbered = unit
            numbered.id = "u\(index + 1)"
            return numbered
        }
    }

    /// 来源单元 → prompt 里的文本。每行前面带 id 与时间码，模型照抄 id 回来。
    static func transcript(units: [MinutesSourceUnit]) -> String {
        units.map { unit in
            "[\(unit.id)] [\(Self.timecode(unit.startSeconds ?? 0))] \(unit.speaker)：\(unit.text)"
        }.joined(separator: "\n")
    }

    /// 一个窗口 → prompt 里的文本（MA-09）。
    ///
    /// 拥有区与重叠区**分开标注**：重叠行前面加「上下文」标记，
    /// 并且明确说它不能进 `source_unit_ids`。只靠"少写一句提示"是不够的——
    /// 模型看到前一句待办时很容易顺手又写一遍，去重就成了兜底而不是设计。
    static func windowTranscript(_ window: MinutesWindow) -> String {
        func line(_ unit: MinutesSourceUnit, owned: Bool) -> String {
            let marker = owned ? "" : "[上下文·不可引用] "
            return "\(marker)[\(unit.id)] [\(Self.timecode(unit.startSeconds ?? 0))] "
                + "\(unit.speaker)：\(unit.text)"
        }
        var lines: [String] = []
        if !window.contextBefore.isEmpty {
            lines.append("—— 以下是上一窗的结尾，只用来理解前后文 ——")
            lines.append(contentsOf: window.contextBefore.map { line($0, owned: false) })
        }
        lines.append("—— 以下是这一窗负责的内容 ——")
        lines.append(contentsOf: window.owned.map { line($0, owned: true) })
        if !window.contextAfter.isEmpty {
            lines.append("—— 以下是下一窗的开头，只用来理解前后文 ——")
            lines.append(contentsOf: window.contextAfter.map { line($0, owned: false) })
        }
        return lines.joined(separator: "\n")
    }

    private static func timecode(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func readableReason(for error: Error) -> String {
        if let llm = error as? LLMError {
            switch llm {
            case .refused(let reason): return "大模型没有给结果：\(reason)"
            case .http(let status, _): return "大模型服务回了 \(status)。文字记录已经存好，可以重新生成。"
            case .notConfigured: return "还没有配置对话模型。"
            default: return llm.errorDescription ?? "整理没有完成。"
            }
        }
        return error.localizedDescription
    }
}
