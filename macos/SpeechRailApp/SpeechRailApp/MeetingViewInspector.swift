import SwiftUI

// `MeetingView` 的会议信息栏（360pt）：这一场现在的事实、中断出口与纪要版本。
// 纯搬移自主文件；跨文件共用的是主文件里的 `@State` 与 `body` 调用的入口。

extension MeetingView {
    // MARK: - 会议信息栏（360pt）

    var inspector: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            if let reviewing = reviewRecord {
                // 在看**以前的一场**（从空态的「会议记录库」点进来的）时，右栏必须跟着换人：
                // 主区说的是旧记录，右栏若还挂着这一场的说话人与纪要版本，同一屏就有两个对象
                // ——和"导错一场"是同一类错误（2026-09-19 回读代码时发现，真机未验）。
                reviewInspectorCard(reviewing)
            } else if meeting.phase == .archived {
                if let id = meeting.sessionID {
                    SpeakerLabelingPanel(labeling: meeting.labeling, sessionID: id, isLive: false)
                }
                minutesVersionsCard
            } else if meeting.phase == .idle {
                // 稿 `screenClosureMeetingSources` 的右栏：「本次会议 · 还没有开始」+ 运行档位
                // 那一组事实 + 「检查输入电平」。时长/转录这些读数在还没开始时都是 0。
                meetingInfoCard
            } else {
                thisMeetingCard
                if meeting.phase == .interrupted { interruptionCard }
            }
        }
    }

    /// 「本次会议」：这一场现在的基本事实。**保存位置也写在这里**——
    /// 「记录只保存在这台 Mac 上」这句话要有一个能看见的落点（§6.3.2 的同一条口径）。
    /// 在看**以前的一场**时右栏换成它：这一栏说的永远是"你现在看的这一场"，
    /// 不是"后台还开着的那一场"。逐行读的都是这一场自己的读数（`reviewRecord` /
    /// `reviewLines` / `reviewSpeakerNames` / `reviewMinutes`），没有一处回读 `meeting`。
    private func reviewInspectorCard(_ record: SessionRecord) -> some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                CardHead(title: "这一场") {
                    Button("回到这一场") { closeReview() }
                        .buttonStyle(.link)
                        .font(SpeechRailDesignTokens.Typography.caption)
                }
                Text(record.title ?? "这一场会议")
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 0) {
                    inspectorRow(
                        "时间",
                        record.startedAt.formatted(date: .numeric, time: .shortened)
                    )
                    inspectorRow("文字记录", "\(reviewLines.count) 段")
                    inspectorRow(
                        "说话人",
                        reviewSpeakerNames.isEmpty ? "还没有" : "\(reviewSpeakerNames.count) 位"
                    )
                    inspectorRow("结束方式", record.endedReason.title)
                    inspectorRow("音频来源", record.audioSource.title)
                    inspectorRow("纪要", reviewMinutesVersionFact)
                    inspectorRow("保存位置", session.libraryURL.lastPathComponent)
                }
                Text("这一栏说的是这一场当时的样子：说话人名与纪要都按当时记录的原样显示。改名与合并要在那一场刚结束、这一页还停在这一场时做。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, SpeechRailDesignTokens.Spacing.micro)
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    /// 在看的那一场有没有纪要、是哪一版（只有一版时不必说"第 1 版"）。
    private var reviewMinutesVersionFact: String {
        guard let reviewMinutes else { return "还没有" }
        return reviewMinutes.version > 1 ? "第 \(reviewMinutes.version) 版" : "有"
    }

    private var thisMeetingCard: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                CardHead(title: "本次会议") { EmptyView() }
                VStack(alignment: .leading, spacing: 0) {
                    inspectorRow("时长", SessionCoordinator.formatted(meeting.elapsed))
                    inspectorRow("文字记录", "\(meeting.storedLineCount) 段")
                    inspectorRow(
                        "说话人",
                        meeting.labeling.labels.isEmpty
                            ? "还没有"
                            : "\(meeting.labeling.labels.count) 位"
                    )
                    inspectorRow("音频来源", meeting.selection?.label ?? "还没选")
                    inspectorRow("说话人", diarizationFact)
                    inspectorRow("整理", meeting.minutes.state.title)
                    inspectorRow("保存位置", session.libraryURL.lastPathComponent)
                }
                if let failure = meeting.lastFailure {
                    Text(failure)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, SpeechRailDesignTokens.Spacing.micro)
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    /// 右栏那一行说的也是人话：不出现「分人」这类行话（用户 2026-09-19）。
    private var diarizationFact: String {
        switch meeting.labeling.state {
        case .off: "不标"
        case .active: "会标出"
        case .degraded: "中途停了"
        case .unavailable: "没能标"
        }
    }

    private func inspectorRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
        }
        .labeledContentStyle(SpeechRailInspectorLabeledContentStyle())
    }

    /// 中断时右栏给两个出口（§6.2 的中断行）。四类断法的处置写在下方的表里——
    /// 用户不需要记住它们，但需要知道"哪一种会自己接回来"。
    private var interruptionCard: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                CardHead(title: meeting.interruption?.title ?? "录制中断") { EmptyView() }
                Text(interruptionDetail)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Button("继续这一段") { Task { await meeting.continueAfterInterruption() } }
                        .buttonStyle(.borderedProminent)
                    Button("结束并整理") { Task { await meeting.requestFinish() } }
                        .buttonStyle(.bordered)
                }
                .controlSize(.small)
                Divider()
                Text("四种断法")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                ForEach(Self.interruptionNotes, id: \.0) { note in
                    Text("\(note.0)：\(note.1)")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    private var interruptionDetail: String {
        switch meeting.interruption {
        case .serviceLost:
            "语音服务断开了。丢掉的音频就是没录上；已经定稿的文字记录都在。继续之后是新的一段。"
        case .sleep:
            "这台 Mac 睡过。醒来之后麦克风与本机音频都要重新拿一次，所以不会自动接着录。"
        case .sourceLost:
            // 这一类在库里对应两件事：**被 tap 的 App 退出**（自动接回、录制不打断，
            // 那种情况根本不会进中断态）与**采集流自己结束**（设备被拔、引擎停了）。
            // 能走到这张卡上的只有后者，所以以现场那句 note 为准；没有 note 时给一句
            // 不替它下结论的话——绝不写"已经自动接回"。
            meeting.interruptionNote ?? "音频来源停下来了。已经定稿的文字记录都在。"
        case .unexpectedExit:
            "上一次没有正常结束。这一段已经封存，可以回看、导出。"
        case .userPaused:
            // 正常情况下到不了这张卡：`interruption` 只由故障路径写入，暂停走
            // `markUserPaused`（只落停记区间、不改相位、不释放设备），所以
            // 上面的「四种断法」里没有它——用户主动为之不算断法。
            // 这一支是给"万一走到了这儿"兜底的：真走到了，说明有路径把暂停误记成了
            // 故障，那要显示成"你自己暂停的"，不能反过来把用户的动作说成设备出问题。
            "这一段是你自己暂停的记录，不是出了故障。"
        case .unknown:
            // 库里这一段确实没录上，原因却是这一版程序读不懂的。宁可说"原因不明"，
            // 也不能默认当成安静或当成设备故障——用户据此判断该不该重录。
            "这一段时间没有录上，原因不明。"
        case .none:
            "这一段停在了断点上。"
        }
    }

    private static let interruptionNotes: [(String, String)] = [
        ("服务断开", "停收声；正文保留。继续 = 新一段。"),
        ("系统睡眠", "醒来即中断态；不自动续。"),
        ("来源 App 退出", "会自动接回；只记一条区间，不打断录制。"),
        ("设备被拔 / 引擎停了", "采集流结束；要人决定继续还是结束。"),
        ("App 意外退出", "下次启动把上一场封存，可以回看、导出。")
    ]

    /// 纪要版本：**重新生成只新增版本**，旧版一直可看可导出（§5.8）。
    ///
    /// 这张卡**只列版本**：动作「重新生成纪要」在页头（稿 `screenMeetingMinutes` 的页头两件之一），
    /// 卡片里再放一颗就是同一个动作在一屏里画两遍（§17 / §19 的去重口径）。页头还有一处好处：
    /// 右栏可以收起，页面动作不会跟着被收起。
    private var minutesVersionsCard: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                CardHead(title: "纪要版本") { EmptyView() }
                if meeting.minutes.versions.isEmpty {
                    Text("这一场还没有生成过纪要。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
                ForEach(meeting.minutes.versions) { version in
                    // 「看这一版」与「采用这一版」是两个动作，所以是两个控件：
                    // 把采用按钮套在行按钮里会变成嵌套按钮，键盘与指针都拿不到它。
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Button {
                            // 点一行 = 「看这一版」：换正文，并且把分段切回纪要
                            // ——在「转录」页签上点版本号却什么都没变，和没接线是一回事。
                            selectedMinutesVersionID = version.id
                            postTab = .minutes
                        } label: {
                            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                                Text(versionLabel(version))
                                    .font(SpeechRailDesignTokens.Typography.callout)
                                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                                // MC-46 后半句：来源修订晚于该版创建时标需复核；正文不动，引用仍指旧版。
                                if meeting.minutes.versionsNeedingReview.contains(version.id) {
                                    StatusPill(tone: .attention, label: "需复核")
                                }
                                // MA-06：采用版是当前口径；失败/排队中的版本不可采用。
                                if version.isAccepted {
                                    StatusPill(tone: .healthy, label: "已采用")
                                }
                                StatusPill(tone: Self.tone(for: version.status), label: version.status.title)
                            }
                            .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                            .padding(.vertical, SpeechRailDesignTokens.Spacing.hairline)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(
                            (selectedMinutesVersionID ?? latestVersionID) == version.id ? "正在查看" : "未选中"
                        )
                        .speechRailPointerCursor()
                        .background(
                            // 选中行与"正在看的那一版"必须一致：`selectedMinutesVersion` 为空时
                            // 实际在看当前展示版，所以那一行也是选中的。
                            (selectedMinutesVersionID ?? latestVersionID) == version.id
                                ? SpeechRailDesignTokens.Surface.selectedFill
                                : Color.clear,
                            in: SpeechRailDesignTokens.Corner.nestedShape
                        )
                        if !version.isAccepted, canAdopt(version), let sessionID = meeting.sessionID {
                            Button {
                                Task { await adoptMinutesVersion(version, sessionID: sessionID) }
                            } label: {
                                Text("采用")
                                    .font(SpeechRailDesignTokens.Typography.caption)
                            }
                            .buttonStyle(.link)
                            .speechRailPointerCursor()
                            .accessibilityLabel("采用第 \(version.version) 版作为当前纪要")
                        }
                    }
                }
                if let adoptConflictNotice {
                    Text(adoptConflictNotice)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    var latestVersionID: String? {
        // MA-06/MC-25：默认选中的那一版是当前展示版——采用版优先，其次最新尝试。
        meeting.minutes.versions.first(where: \.isAccepted)?.id
            ?? meeting.minutes.versions.first(where: \.isLatest)?.id
    }

    /// 版本行标题：采用版、最新尝试与普通历史版各说各的，不让"最新"冒充"当前"。
    private func versionLabel(_ version: MinutesVersion) -> String {
        if version.isAccepted { return "当前采用 · 第 \(version.version) 版" }
        if version.isLatest { return "最新 · 第 \(version.version) 版" }
        return "第 \(version.version) 版"
    }

    /// 只有已完成且有正文的版本能被采用；失败、排队、运行中一律不给这个出口。
    private func canAdopt(_ version: MinutesVersion) -> Bool {
        version.status == .ready && version.body?.isEmpty == false
    }

    static func tone(for status: MinutesStatus) -> StatusTone {
        switch status {
        case .ready: .healthy
        case .failed: .attention
        case .submissionUnknown: .attention
        default: .neutral
        }
    }
}
