import SwiftUI

// `MeetingView` 的会后实现：纪要 / 文字记录两个页签、导出，以及看旧记录时的导航。
// 纯搬移自主文件；跨文件共用的是主文件里的 `@State` 与 `body` 调用的入口。

extension MeetingView {
    // MARK: - 会后

    var postMeeting: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 0) {
                CardHead(title: postTab.title, detail: postDetail) {
                    Picker("", selection: $postTab) {
                        ForEach(PostTab.allCases) { tab in
                            Text(tab.title).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                ScrollView(.vertical) {
                    Group {
                        if let reviewRecord {
                            reviewBody(reviewRecord)
                        } else if postTab == .minutes {
                            minutesBody
                        } else {
                            transcriptBody
                        }
                    }
                    .padding(SpeechRailDesignTokens.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var postDetail: String? {
        if reviewRecord != nil { return "在看以前的一场；点「回到这一场」回来" }
        guard let id = meeting.sessionID else { return nil }
        let count = reviewLines.count
        return "\(id.prefix(8)) · \(count) 段"
    }

    private var minutesBody: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            switch meeting.minutes.state {
            case .failed(let reason):
                // 出口按**失败的性质**给：配置还没填（或填错）时，「重新生成」按下去只会
                // 原样再失败一次——那一刻用户真正要做的是把对话模型填上，所以这里直接给
                // 设置那条路（用户 2026-09-19：一次性设置只在最需要它的时刻打扰）。
                if meeting.minutesNeedsSetup {
                    StatusBanner(
                        kind: .standard,
                        tone: .attention,
                        title: "纪要要用对话模型 · 文字记录已经存好了",
                        message: reason,
                        actionTitle: "去设置里填"
                    ) {
                        openSettings()
                    }
                } else {
                    StatusBanner(
                        kind: .standard,
                        tone: .attention,
                        title: "纪要没整理出来 · 文字记录已经存好了",
                        message: reason,
                        actionTitle: "重新生成"
                    ) {
                        Task { await regenerateMinutes() }
                    }
                }
            case .queued, .running:
                // 这里只显示状态标题，不显示失败原因：`MinutesGenerator` 的状态机里
                // 失败只走 `.failed(reason)`，`queued`/`running` 不带原因字段；
                // 若"一直转圈"且无失败横幅，原因是 `failMinutes` 落库失败，
                // 查日志分类 `minutes.generate`（P1-5），不是界面吞了错误。
                Text(meeting.minutes.state.title)
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                // MC-32：任务在排队那一刻就固定了用哪套设置。用户中途改设置，
                // 这一条**不跟着换**——换了等于同一任务前后用了两个端点，出了错无法归因。
                if meeting.minutes.jobConfigDiffersFromCurrent {
                    Text("这一次整理用的是它开始时那套设置；你改过的设置从下一次整理生效。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
            case .cancelled:
                // MC-30：这是"你停掉的"，不是"没整理出来"。远端停没停要单独说，
                // 说不准就说不准——本地停下来是确定的，远端不是。
                StatusBanner(
                    kind: .standard,
                    tone: .neutral,
                    title: "整理已停止 · 文字记录已经存好了",
                    message: "这一次是你停掉的，不算整理失败，可以随时重新生成。"
                        + (meeting.minutes.remoteCancellationNote ?? ""),
                    actionTitle: "重新生成"
                ) {
                    Task { await regenerateMinutes() }
                }
            case .submissionUnknown:
                // MC-28：远端可能已经受理，只是没拿到回执。这里**不**给"重新生成"当默认出口，
                // 因为重发可能重复执行、重复计费；由用户自己决定要不要再试。
                StatusBanner(
                    kind: .standard,
                    tone: .attention,
                    title: "提交结果待确认 · 文字记录已经存好了",
                    message: "请求可能已经发出去了，只是没拿到回执。没法确认的时候我们不会自动重试："
                        + "再来一次可能会重复执行、重复计费。确认服务那边没有在跑之后再重新生成。"
                )
            default:
                EmptyView()
            }
            // 「在看哪一版」是一个**有落点的状态**：点了版本列表里的旧版就必须换正文，
            // 否则那一行按下去什么都不会发生（而这正是"旧版一直可看"的承诺）。
            if let viewing = selectedMinutesVersion, viewing.id != latestVersionID {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Text("正在看第 \(viewing.version) 版")
                        .font(SpeechRailDesignTokens.Typography.captionMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    StatusPill(tone: Self.tone(for: viewing.status), label: viewing.status.title)
                    Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                    Button("回到当前版本") { selectedMinutesVersionID = nil }
                        .buttonStyle(.link)
                        .font(SpeechRailDesignTokens.Typography.caption)
                }
            }
            // MC-46 后半句：正在看的这一版若在来源修订之前创建，提示结论可能已过期。
            if let viewing = selectedMinutesVersion,
               meeting.minutes.versionsNeedingReview.contains(viewing.id)
            {
                Text("这一版创建之后说话人有过修订，结论可能已过期，引用仍指修订前的原文。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            // MA-08：结构合法但语义撑不住的结论留在正文里，同时说明要核对。
            // 不把"有引用"说成"核对通过"——那正是验证器最不该犯的错。
            if let review = meeting.minutes.candidateReview, review.needsReview {
                Text(reviewSummary(review))
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            if let body = displayedMinutesBody, !body.isEmpty {
                Text(body)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if case .ready = meeting.minutes.state {
                Text("这一版是空的。")
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            }
        }
    }

    /// 被点开的那一版。**选中即唯一来源**：找不到就是没选（比如换了会话，版本列表变了），
    /// 不把失效的 id 当成"还在看旧版"。
    /// 核对报告转成一句人话。数字要说清楚：几条没通过引用核对、几条语义上要核对。
    private func reviewSummary(_ review: MinutesEvidenceValidator.Report) -> String {
        if review.rejectedCount > 0, review.reviewCount > 0 {
            return "这一版有 \(review.rejectedCount) 条结论没通过引用核对、\(review.reviewCount) 条语气或数字对不上。"
                + "内容留在下面，请对着文字记录核对后再用。"
        }
        if review.rejectedCount > 0 {
            return "这一版有 \(review.rejectedCount) 条结论没通过引用核对，内容仍留在下面，请对着文字记录核对后再用。"
        }
        return "这一版有 \(review.reviewCount) 条结论的语气或数字与转录对不上，已标在正文里，请核对后再用。"
    }

    private var selectedMinutesVersion: MinutesVersion? {
        guard let selectedMinutesVersionID else { return nil }
        return meeting.minutes.versions.first { $0.id == selectedMinutesVersionID }
    }

    /// 正文只在这一处决定：选了旧版就显示旧版，否则是当前展示版
    /// （采用版优先，其次最新可用候选；`latestBody` 只作为版本列表还没刷出来时的兜底）。
    private var displayedMinutesBody: String? {
        if let selectedMinutesVersion { return selectedMinutesVersion.body }
        // MC-25：已采用 v2 后 v3 失败，仍显示 v2；不把失败版的空正文当成功。
        if let accepted = meeting.minutes.versions.first(where: \.isAccepted) {
            return accepted.body
        }
        if let latest = meeting.minutes.versions.first(where: \.isLatest) {
            if latest.status == .ready { return latest.body }
            if let usable = meeting.minutes.versions.filter({ $0.status == .ready }).max(by: { $0.version < $1.version }) {
                return usable.body
            }
            return latest.body
        }
        return meeting.minutes.latestBody
    }

    private var transcriptBody: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            if reviewLines.isEmpty {
                Text("这一场还没有文字记录。")
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            }
            ForEach(reviewLines) { line in
                HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
                    Text(Self.timecode(line.tStart ?? 0))
                        .font(SpeechRailDesignTokens.Typography.technicalValue)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        .frame(
                            width: SpeechRailDesignTokens.Layout.sessionTimecodeColumnWidth,
                            alignment: .leading
                        )
                    if let label = line.speakerLabel {
                        Text(
                            SpeakerLabeling.chipText(
                                label: label,
                                displayName: reviewSpeakerNames[label]
                            )
                        )
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .frame(
                            width: SpeechRailDesignTokens.Layout.sessionSpeakerColumnWidth,
                            alignment: .leading
                        )
                    }
                    Text(line.text)
                        .font(SpeechRailDesignTokens.Typography.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func reviewBody(_ record: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text(record.title ?? "这一场会议")
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                StatusPill(tone: .neutral, label: record.endedReason.title)
                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                Button("回到这一场") { closeReview() }
                    .buttonStyle(.link)
                    .font(SpeechRailDesignTokens.Typography.caption)
            }
            if let reviewMinutes, let body = reviewMinutes.body {
                Text(body)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                transcriptBody
            }
        }
    }

    func reloadPostMeeting() async {
        // 会后这一栏读的是**库里的行**，不是内存镜像：界面可能是从内存快照渲染的，
        // 而"重开 App 之后还在不在"只能由库回答（§11.2 的第二条）。
        guard let id = meeting.sessionID else { return }
        reviewLines = (try? await session.lines(sessionID: id)) ?? []
        recoveryLines = (try? await session.lines(sessionID: id, includePartial: true))?
            .filter { $0.status == .partial } ?? []
        reviewSpeakerNames = (try? await session.speakerNames(sessionID: id)) ?? [:]
        await meeting.minutes.reload(sessionID: id)
        await reloadReviewVerdicts(sessionID: id)
    }

    /// 采用版里每条结论的核对结论。取的是**采用指针指向的那一版**，
    /// 不是"最新一版"——界面此刻显示什么，审阅轴就该说什么。
    private func reloadReviewVerdicts(sessionID: String) async {
        // `??` 的右操作数是自动闭包，装不下 `await`，所以分步取。
        var adopted = try? await session.acceptedMinutes(sessionID: sessionID)
        if adopted == nil {
            adopted = try? await session.currentMinutes(sessionID: sessionID)
        }
        guard let adopted,
              let items = try? await session.minutesItems(minutesID: adopted.id)
        else {
            reviewVerdicts = []
            return
        }
        reviewVerdicts = items.compactMap(\.verdict)
    }

    private func regenerateMinutes() async {
        await regenerateMinutes(for: meeting.sessionID)
    }

    /// 重新生成**指定那一场**的纪要（在看旧记录时页头那颗按钮作用在旧记录上）。
    /// 生成之后回到「纪要」页签看新版；选中态清掉，否则会以为"重新生成没生效"。
    func regenerateMinutes(for sessionID: String?) async {
        guard let id = sessionID else { return }
        await meeting.minutes.generate(
            sessionID: id,
            resolvedConfiguration: preferences.resolvedLLMConfiguration(for: .minutes)
        )
        if reviewRecord?.id == id {
            reviewMinutes = try? await session.currentMinutes(sessionID: id)
            selectedMinutesVersionID = nil
            postTab = .minutes
            return
        }
        await meeting.minutes.reload(sessionID: id)
        selectedMinutesVersionID = nil
        postTab = .minutes
    }

    // MARK: - 导出（稿 M3「先导出转录…」与会后板「导出…」）

    /// 页头的导出动作。四种格式收进一个菜单：页头是低频动作的地方，四个格式不值得占四个槽位
    /// （与记录库页同一个口径）。默认格式排第一——会议是 Markdown。
    func exportMenu(title: String, helpText: String) -> some View {
        PageActionsMenu(title: title, systemImage: "square.and.arrow.down", helpText: helpText) {
            ForEach(orderedFormats) { format in
                Button(format.title) {
                    exportCurrentSession(includeMinutes: true, as: format)
                }
            }
        }
    }

    private var orderedFormats: [SessionExportFormat] {
        let preferred = SessionExportFormat.preferred(for: .meeting)
        return [preferred] + SessionExportFormat.allCases.filter { $0 != preferred }
    }

    /// 导出**重新从库里读一遍**，不拿界面上正在显示的那份内存镜像：整理中也好、归档也好，
    /// 要带走的是库里定稿的内容（`includePartial == false`），与这一页此刻渲染到哪儿无关。
    ///
    /// `includeMinutes` 只有一处为真：**归档之后**才连纪要一起导。整理中那一颗叫「先导出转录」，
    /// 此时纪要还没生成——把它拼进去只会得到一个空章节，那正是"先导出转录"要避免的事。
    private func exportCurrentSession(includeMinutes: Bool, as format: SessionExportFormat) {
        guard let id = pageSessionID else { return }
        // MC-48：导出固定正在看的那一版；没选旧版时才用最新版。
        let pinnedMinutesID = selectedMinutesVersionID
        Task {
            guard let record = (try? await session.record(id: id)) ?? nil else { return }
            let rows = (try? await session.lines(sessionID: id)) ?? []
            let names = (try? await session.speakerNames(sessionID: id)) ?? [:]
            let minutes: MinutesVersion? = if includeMinutes {
                if let pinnedMinutesID {
                    try? await session.minutesVersion(id: pinnedMinutesID)
                } else {
                    // MC-25：没选旧版时导当前展示版（采用版优先）；最新尝试失败不带空正文。
                    try? await session.currentMinutes(sessionID: id)
                }
            } else {
                nil
            }
            SessionExportPanel.write(
                SessionExportPayload(
                    record: record,
                    lines: rows,
                    speakerNames: names,
                    minutes: minutes
                ),
                as: format
            )
        }
    }

    /// 页头动作到底作用在哪一场上。**在看旧记录时以旧记录为准**：这一页可以一边开着
    /// 上一场的记录（`reviewRecord`）一边保持 `phase == .archived`，若动作跟着
    /// `meeting.sessionID` 走，用户就会把「导出的那一场」和「屏幕上这一场」搞混——
    /// 一个导错对象的导出比没有导出更糟。
    var pageSessionID: String? { reviewRecord?.id ?? meeting.sessionID }

    func openRecord(_ summary: SessionSummary) async {
        guard let record = (try? await session.record(id: summary.id)) ?? nil else { return }
        reviewRecord = record
        let loaded = (try? await session.lines(sessionID: summary.id, includePartial: true)) ?? []
        guard reviewRecord?.id == summary.id else { return }
        reviewLines = loaded.filter { $0.status == .final }
        recoveryLines = loaded.filter { $0.status == .partial }
        reviewSpeakerNames = (try? await session.speakerNames(sessionID: summary.id)) ?? [:]
        // MC-25：回看读当前展示版（采用版优先）；最新尝试失败时不拿失败版的空正文遮旧版。
        reviewMinutes = try? await session.currentMinutes(sessionID: summary.id)
        selectedMinutesVersionID = nil
    }

    func closeReview() {
        reviewRecord = nil
        reviewMinutes = nil
        Task { await reloadPostMeeting() }
    }

    /// 采用某一版（MA-06/MC-31）：只有用户明确采用才移动当前采用版；
    /// 采用基于"点下去时看到的那个采用版"做比较，期间别人改过就拒绝覆盖并提示刷新。
    func adoptMinutesVersion(_ version: MinutesVersion, sessionID: String) async {
        let expected = ((try? await session.acceptedMinutes(sessionID: sessionID)) ?? nil)?.id
        let committed = (try? await session.adoptMinutes(
            sessionID: sessionID,
            minutesID: version.id,
            expectedCurrentID: expected
        )) ?? false
        guard committed else {
            adoptConflictNotice = "当前采用的版本已经变了，刷新后再试一次。"
            await refreshAfterAdopt(sessionID: sessionID)
            return
        }
        adoptConflictNotice = nil
        await refreshAfterAdopt(sessionID: sessionID)
    }

    /// 采用之后把这一场的展示口径刷回"当前展示版"：当前会议刷生成器状态，
    /// 回看旧记录刷右栏正文，两条路径都不自己拼回退链。
    private func refreshAfterAdopt(sessionID: String) async {
        if reviewRecord?.id == sessionID {
            reviewMinutes = try? await session.currentMinutes(sessionID: sessionID)
        }
        await reloadPostMeeting()
    }

}
