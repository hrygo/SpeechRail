import SwiftUI

// `MeetingView` 的录制中实现：转录流、中断行、说话人列，以及会中标注说话人的面板。
// 纯搬移自主文件；录制中转录与会后正文共用的 `timecode` 也在这里。

extension MeetingView {
    // MARK: - 录制中：转录流

    var liveTranscript: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 0) {
                CardHead(
                    title: "实时记录",
                    detail: meeting.transcriptionStatusText
                        ?? (meeting.labeling.isEnabled ? "点击发言人标签可重命名或合并" : nil)
                ) {
                    // 稿 `screenMeetingRecording` 表头那一颗（`main.js:3642`）：会中人工标注的
                    // 入口必须看得见。点行上的标签是**第一条路**（就地改名 / 合并），这颗按钮是
                    // 同一件事的**第二条路**——会中不想在长长的转录里找标签时，从这里进来一次改完。
                    // `labeling.state` 三种（没开 / 不支持 / 在用）面板自己会说话，所以按钮常在；
                    // 会话还没建起来时不给（那时没有可标注的行）。
                    if meeting.sessionID != nil {
                        Button("复制全部文字", systemImage: "doc.on.doc") {
                            Task {
                                do {
                                    let text = try await meeting.completeTranscriptText()
                                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                                } catch { transcriptCopyMessage = "文字暂时未能复制，请重试。" }
                            }
                        }
                        .speechRailButton(.quiet)
                    }
                    if meeting.sessionID != nil {
                        Button {
                            isLabelingSpeakers = true
                        } label: {
                            Label("标注说话人", systemImage: "person.2")
                        }
                        .speechRailButton(.secondary)
                        .help("谁说了哪句：改显示名或合并；正文一个字不动")
                    }
                }
                if meeting.phase == .interrupted, let at = meeting.interruptedElapsed {
                    interruptionRow(at)
                }
                Group {
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                            if meeting.transcriptPresentation.hasEarlier {
                                Button(meeting.transcriptPresentation.isLoadingPage ? "正在读取…" : "载入更早记录") {
                                    Task { await loadEarlierTranscript(before: meeting.lines.first?.ordinal) }
                                }
                                .speechRailButton(.quiet)
                                .disabled(meeting.transcriptPresentation.isLoadingPage)
                            }
                            if let transcriptCopyMessage { Text(transcriptCopyMessage).font(SpeechRailDesignTokens.Typography.caption) }
                            if meeting.lines.isEmpty, meeting.partialText == nil {
                                Text("这一场还没有说到能定稿的句子。")
                                    .font(SpeechRailDesignTokens.Typography.callout)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                                    .padding(.vertical, SpeechRailDesignTokens.Spacing.lg)
                            }
                            ForEach(meeting.lines) { line in
                                if let before = meeting.transcriptPresentation.gapBefore(id: line.id) {
                                    Button("查看这之前的记录") { Task { await loadEarlierTranscript(before: before) } }
                                        .speechRailButton(.quiet)
                                        .disabled(meeting.transcriptPresentation.isLoadingPage)
                                }
                                liveLine(line).id(line.id)
                            }
                            if let capture = meeting.windowCapture {
                                ForEach(capture.visibleUnits, id: \.unitID) { unit in
                                    partialLine(unit.text)
                                }
                            } else if let partial = meeting.partialText, !partial.isEmpty {
                                partialLine(partial)
                            }
                        }
                        .scrollTargetLayout()
                        .padding(SpeechRailDesignTokens.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollPosition($transcriptScrollPosition)
                    .defaultScrollAnchor(
                        transcriptFollow.isPinnedToBottom ? .bottom : nil, for: .sizeChanges
                    )
                    .onScrollTargetVisibilityChange(idType: String.self) { ids in
                        transcriptVisibleLineIDs = ids
                        if !transcriptFollow.isPinnedToBottom {
                            meeting.transcriptPresentation.beginHistory(anchorID: firstVisibleTranscriptID)
                            meeting.transcriptPresentation.setScrollAnchor(firstVisibleTranscriptID)
                        }
                    }
                    .onChange(of: transcriptFollow.isPinnedToBottom) { _, pinned in
                        if pinned { meeting.transcriptPresentation.returnToLatest() }
                        else { meeting.transcriptPresentation.beginHistory(anchorID: firstVisibleTranscriptID) }
                    }
                    .onScrollPhaseChange { oldPhase, phase, context in
                        let wasUserScroll = oldPhase == .interacting || oldPhase == .decelerating
                        let isUserScroll = phase == .interacting || phase == .decelerating
                        transcriptUserScrollActive = isUserScroll
                        guard wasUserScroll || isUserScroll else { return }
                        let proximity = TranscriptFollowState.scrollProximity(
                            contentBottomY: Double(context.geometry.contentSize.height),
                            viewportBottomY: Double(context.geometry.visibleRect.maxY)
                        )
                        let updated = transcriptFollow.geometryChanged(
                            to: proximity, isUserInitiated: true
                        )
                        if updated != transcriptFollow { transcriptFollow = updated }
                    }
                    .onScrollGeometryChange(for: TranscriptFollowState.ScrollProximity.self) { geometry in
                        TranscriptFollowState.scrollProximity(
                            contentBottomY: Double(geometry.contentSize.height),
                            viewportBottomY: Double(geometry.visibleRect.maxY)
                        )
                    } action: { _, proximity in
                        let updated = transcriptFollow.geometryChanged(
                            to: proximity, isUserInitiated: transcriptUserScrollActive
                        )
                        guard updated != transcriptFollow else { return }
                        transcriptFollow = updated
                    }
                    .onChange(of: meeting.transcriptPresentation.arrivalCount) { oldCount, newCount in
                        // 用户正在回看时，新句子一条都不许抢滚动（MA-10）。
                        let arrived = transcriptFollow.anchoring(meeting.lines.last?.id)
                            .contentArrived(lineCount: newCount - oldCount)
                        if transcriptFollow != arrived.state {
                            transcriptFollow = arrived.state
                        }
                        guard case .follow = arrived.decision else { return }
                        scrollTranscriptToBottom()
                    }
                    .safeAreaInset(edge: .bottom) {
                        if let banner = transcriptFollow.unseenBannerText {
                            Button {
                                meeting.transcriptPresentation.returnToLatest()
                                transcriptFollow = transcriptFollow.jumpToLatest(
                                    anchor: meeting.lines.last?.id
                                )
                                scrollTranscriptToBottom()
                            } label: {
                                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                                    Text(banner)
                                        .font(SpeechRailDesignTokens.Typography.captionMedium)
                                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                                    Text("回到最新")
                                        .font(SpeechRailDesignTokens.Typography.caption)
                                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                }
                                .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                                .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
                                .background(SpeechRailDesignTokens.Surface.floatingToolbarMaterial, in: Capsule())
                                .overlay(
                                    Capsule().strokeBorder(SpeechRailDesignTokens.Color.separator, lineWidth: 0.5)
                                )
                                .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 3)
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut(.defaultAction)
                            .speechRailPointerCursor()
                            .padding(.bottom, SpeechRailDesignTokens.Spacing.sm)
                            .accessibilityLabel("\(banner)，点击回到最新")
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                if !recoveryLines.isEmpty {
                    recoverySection
                }
            }
        }
    }

    private var firstVisibleTranscriptID: String? {
        let ids = Set(transcriptVisibleLineIDs)
        return meeting.lines.first { ids.contains($0.id) }?.id
    }
    private func loadEarlierTranscript(before: Int?) async {
        meeting.transcriptPresentation.beginHistory(anchorID: firstVisibleTranscriptID)
        transcriptFollow.isPinnedToBottom = false
        let anchor = meeting.transcriptPresentation.scrollAnchorID
        await meeting.loadTranscriptPage(beforeOrdinal: before)
        if let anchor { transcriptScrollPosition.scrollTo(id: anchor, anchor: .top) }
    }

    private func scrollTranscriptToBottom() {
        if reduceMotion {
            transcriptScrollPosition.scrollTo(edge: .bottom)
        } else {
            withAnimation(SpeechRailDesignTokens.Motion.interactiveSpring) {
                transcriptScrollPosition.scrollTo(edge: .bottom)
            }
        }
    }

    /// 恢复材料区（MA-02 / MC-11）。
    ///
    /// 系统提示里说了"已原样保留"，这里就必须真能取回那句话。
    /// 它**不是**转录正文，所以单独成区、明说不进纪要——放在正文流里
    /// 会让用户以为这是这场会正常识别出来的一句。
    @ViewBuilder
    private var recoverySection: some View {
        TranscriptRecoveryMaterialSection(lines: recoveryLines)
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
    }

    /// 断点那一行：**时间码在断点处是跳的**（§6.5、D8），所以这里明写一句。
    private func interruptionRow(_ at: TimeInterval) -> some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(StatusTone.attention.color)
                .accessibilityHidden(true)
            Text("\(SessionCoordinator.formatted(at)) 起中断 · 这一段没有文本")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.bottom, SpeechRailDesignTokens.Spacing.xs)
    }

    private func liveLine(_ line: MeetingSession.Line) -> some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
            let timecodeStr = TranscriptTimeWindow.timecodeColumn(
                observed: line.start,
                quality: line.timingQuality
            )
            Text(timecodeStr)
                .font(SpeechRailDesignTokens.Typography.technicalValue)
                .foregroundStyle(
                    timecodeStr == "—"
                        ? SpeechRailDesignTokens.Color.inkTertiary.opacity(0.4)
                        : SpeechRailDesignTokens.Color.inkTertiary
                )
                .frame(
                    width: SpeechRailDesignTokens.Layout.sessionTimecodeColumnWidth,
                    alignment: .leading
                )
                .help(
                    TranscriptTimeWindow.accessibilityText(
                        observedStart: line.start,
                        observedEnd: line.end,
                        quality: line.timingQuality
                    )
                )
                .accessibilityLabel(
                    TranscriptTimeWindow.accessibilityText(
                        observedStart: line.start,
                        observedEnd: line.end,
                        quality: line.timingQuality
                    )
                )
            speakerColumn(for: line)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(line.text)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if line.isDeviceSwitch {
                    Text("换设备")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// 说话人列：点它就能改名、标记为我或与其他说话人合并。未指定时展示轻量占位。
    @ViewBuilder
    private func speakerColumn(for line: MeetingSession.Line) -> some View {
        if let label = line.speakerLabel {
            Menu {
                Button {
                    isLabelingSpeakers = true
                } label: {
                    Label("重命名或合并说话人…", systemImage: "pencil")
                }
                Button {
                    Task { await meeting.markAsMe(label: label) }
                } label: {
                    Label("标记为「我」", systemImage: "person.crop.circle.badge.checkmark")
                }
                let others = meeting.labeling.labels.filter { $0 != label }
                if !others.isEmpty {
                    Divider()
                    ForEach(others, id: \.self) { other in
                        Button("与 \(meeting.labeling.displayText(for:other)) 合并") {
                            Task { await meeting.merge(label: label, into: other) }
                        }
                    }
                }
            } label: {
                SpeakerChip(
                    label: label,
                    displayName: meeting.labeling.displayText(for:label)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(
                width: SpeechRailDesignTokens.Layout.sessionSpeakerColumnWidth,
                alignment: .leading
            )
            .help("点此修改说话人名字、标记为我或与其他说话人合并")
        } else if meeting.labeling.isEnabled {
            Menu {
                Button {
                    isLabelingSpeakers = true
                } label: {
                    Label("标注说话人…", systemImage: "pencil")
                }
                let existing = meeting.labeling.labels
                if !existing.isEmpty {
                    Divider()
                    ForEach(existing, id: \.self) { other in
                        Button("指定为 \(meeting.labeling.displayText(for:other))") {
                            Task { await meeting.labeling.split(lineIDs: [line.id], to: other) }
                        }
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "person.badge.plus")
                        .font(SpeechRailDesignTokens.Typography.chipIcon)
                    Text("未标说话人")
                        .font(SpeechRailDesignTokens.Typography.caption)
                }
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary.opacity(0.8))
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                .padding(.vertical, 2)
                .background(
                    SpeechRailDesignTokens.Color.field,
                    in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(SpeechRailDesignTokens.Color.separator.opacity(0.6), lineWidth: 0.5)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(
                width: SpeechRailDesignTokens.Layout.sessionSpeakerColumnWidth,
                alignment: .leading
            )
            .help("未检测出发言人归属，点击可手动指认或命名")
        } else {
            Color.clear.frame(
                width: SpeechRailDesignTokens.Layout.sessionSpeakerColumnWidth,
                height: 1
            )
        }
    }

    private func partialLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Text(Self.timecode(session.elapsed))
                .font(SpeechRailDesignTokens.Typography.technicalValue)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                .frame(
                    width: SpeechRailDesignTokens.Layout.sessionTimecodeColumnWidth,
                    alignment: .leading
                )
            HStack(alignment: .firstTextBaseline, spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text(text)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Circle()
                        .fill(SpeechRailDesignTokens.Color.rail)
                        .frame(
                            width: SpeechRailDesignTokens.Icon.liveIndicatorDotSize,
                            height: SpeechRailDesignTokens.Icon.liveIndicatorDotSize
                        )
                    Text("正在识别…")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }
    static func timecode(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
