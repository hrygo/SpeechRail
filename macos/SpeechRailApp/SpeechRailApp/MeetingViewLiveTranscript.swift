import SwiftUI

// `MeetingView` 的录制中实现：转录流、中断行、说话人列，以及会中标注说话人的面板。
// 纯搬移自主文件；滚动测量的两个 preference key 与会后正文共用的 `timecode` 也在这里。

extension MeetingView {
    /// 转录滚动区的命名坐标系，量底边位置用。
    private static let transcriptSpace = "meeting.transcript"
    // MARK: - 录制中：转录流

    var liveTranscript: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 0) {
                CardHead(
                    title: "实时记录",
                    detail: meeting.labeling.isEnabled ? "点名字那一列就能改名，正文不会动" : nil
                ) {
                    // 稿 `screenMeetingRecording` 表头那一颗（`main.js:3642`）：会中人工标注的
                    // 入口必须看得见。点行上的标签是**第一条路**（就地改名 / 合并），这颗按钮是
                    // 同一件事的**第二条路**——会中不想在长长的转录里找标签时，从这里进来一次改完。
                    // `labeling.state` 三种（没开 / 不支持 / 在用）面板自己会说话，所以按钮常在；
                    // 会话还没建起来时不给（那时没有可标注的行）。
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
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                            if meeting.lines.isEmpty, meeting.partialText == nil {
                                Text("这一场还没有说到能定稿的句子。")
                                    .font(SpeechRailDesignTokens.Typography.callout)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                                    .padding(.vertical, SpeechRailDesignTokens.Spacing.lg)
                            }
                            ForEach(meeting.lines) { line in
                                liveLine(line).id(line.id)
                            }
                            if let partial = meeting.partialText, !partial.isEmpty {
                                partialLine(partial)
                            }
                            // 底边标记：量得出「离底部多远」，回看时才不会被抢滚动。
                            Color.clear
                                .frame(height: 1)
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: TranscriptBottomMarkerKey.self,
                                            value: geo.frame(in: .named(Self.transcriptSpace)).maxY
                                        )
                                    }
                                )
                        }
                        .padding(SpeechRailDesignTokens.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .coordinateSpace(name: Self.transcriptSpace)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: TranscriptViewportHeightKey.self,
                                value: geo.size.height
                            )
                        }
                    )
                    .onPreferenceChange(TranscriptBottomMarkerKey.self) { y in
                        transcriptBottomMarkerY = y
                    }
                    .onPreferenceChange(TranscriptViewportHeightKey.self) { h in
                        transcriptViewportHeight = h
                    }
                    .onChange(of: meeting.lines.count) { oldCount, newCount in
                        // 用户正在回看时，新句子一条都不许抢滚动（MA-10）。
                        let arrived = transcriptFollow.anchoring(meeting.lines.last?.id)
                            .contentArrived(lineCount: newCount - oldCount)
                        transcriptFollow = arrived.state
                        guard case .follow = arrived.decision,
                              let last = meeting.lines.last else { return }
                        if reduceMotion {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        } else {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                    .onChange(of: transcriptBottomMarkerY) { _, _ in
                        guard transcriptViewportHeight > 0 else { return }
                        let distance = transcriptViewportHeight - transcriptBottomMarkerY
                        transcriptFollow = transcriptFollow.userScrolled(
                            toBottomWithin: Double(distance)
                        )
                    }
                    .safeAreaInset(edge: .bottom) {
                        if let banner = transcriptFollow.unseenBannerText {
                            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                                Text(banner)
                                    .font(SpeechRailDesignTokens.Typography.caption)
                                Button("回到最新") {
                                    transcriptFollow = transcriptFollow.jumpToLatest(
                                        anchor: meeting.lines.last?.id
                                    )
                                    guard let last = meeting.lines.last else { return }
                                    if reduceMotion {
                                        proxy.scrollTo(last.id, anchor: .bottom)
                                    } else {
                                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .keyboardShortcut(.defaultAction)
                            }
                            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                            .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
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
            // 没有对齐证据就不显示数字：那一列写着 00:12 时，
            // 用户只会读成"这句话是 12 秒时说的"，而它其实是记录时刻。
            Text(
                TranscriptTimeWindow.timecodeColumn(
                    observed: line.start,
                    quality: line.timingQuality
                )
            )
                .font(SpeechRailDesignTokens.Typography.technicalValue)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
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
            speakerColumn(label: line.speakerLabel)
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

    /// 说话人列：**点它就能改名**（会中的轻量入口）。正文没有编辑入口——两者必须看出区别。
    @ViewBuilder
    private func speakerColumn(label: String?) -> some View {
        if let label {
            Menu {
                ForEach(meeting.labeling.labels.filter { $0 != label }, id: \.self) { other in
                    Button("与 \(other) 合并") {
                        Task { await meeting.merge(label: label, into: other) }
                    }
                }
                Button("标记为「我」") { Task { await meeting.markAsMe(label: label) } }
            } label: {
                SpeakerChip(
                    label: label,
                    displayName: meeting.labeling.displayNames[label]
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(
                width: SpeechRailDesignTokens.Layout.sessionSpeakerColumnWidth,
                alignment: .leading
            )
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
            Text(text)
                .font(SpeechRailDesignTokens.Typography.body)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("正在识别…")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            Spacer(minLength: 0)
        }
    }
    static func timecode(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// 内容底边在滚动坐标系里的 Y。仅用于「离底部多远」的判定。
private struct TranscriptBottomMarkerKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 转录滚动视口的高度。
private struct TranscriptViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
