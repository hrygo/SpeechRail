import SwiftUI

// `MeetingView` 的会议记录库快捷入口：空态下方那一段，点一场进去回看。
// 纯搬移自主文件；跨文件共用的是主文件里的 `@State` 与 `body` 调用的入口。

extension MeetingView {
    // MARK: - 记录库（空态下方那一段：会议**库**在记录库里，不在这一页的主区）

    var libraryCard: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 0) {
                CardHead(
                    title: "会议记录库",
                    detail: recent.isEmpty ? "最近会议" : "最近 \(min(recent.count, Self.quickAccessMeetingLimit)) 场 · 共 \(recent.count) 场"
                ) {
                    Button {
                        showsKnowledgeLibrary = true
                    } label: {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                            Text("全部知识库")
                                .font(SpeechRailDesignTokens.Typography.captionMedium)
                            Image(systemName: "chevron.right")
                                .font(SpeechRailDesignTokens.Typography.chipIcon)
                        }
                        .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                    }
                    .buttonStyle(.plain)
                    .speechRailPointerCursor()
                    .help("打开完整的会议知识库，包含跨会议问答、项目分类和未完成事项")
                }
                if recent.isEmpty {
                    VStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 26))
                            .foregroundStyle(SpeechRailDesignTokens.Color.rail.opacity(0.6))
                        Text("暂无历史会议记录")
                            .font(SpeechRailDesignTokens.Typography.bodyMedium)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                        Text("发起会议并结束后，转写文本与整理纪要将自动归档至此。")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SpeechRailDesignTokens.Spacing.xl)
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                            ForEach(Array(recent.prefix(Self.quickAccessMeetingLimit).enumerated()), id: \.element.id) { index, summary in
                                if index > 0 {
                                    SessionHairline()
                                        .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                                }
                                recentMeetingRow(summary)
                            }
                            if recent.count > Self.quickAccessMeetingLimit {
                                SessionHairline()
                                    .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
                                Button {
                                    showsKnowledgeLibrary = true
                                } label: {
                                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                                        Text("查看全部 \(recent.count) 场会议")
                                            .font(SpeechRailDesignTokens.Typography.calloutMedium)
                                            .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                                        Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                                        Image(systemName: "chevron.right")
                                            .font(SpeechRailDesignTokens.Typography.caption)
                                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                                    }
                                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                                    .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
                                    .contentShape(Rectangle())
                                }
                                .speechRailInteractiveButtonStyle(
                                    fillsAvailableWidth: true,
                                    minimumHeight: SpeechRailDesignTokens.Control.regularHeight
                                )
                                .accessibilityHint("打开完整的会议知识库，可以搜索、按项目筛选和翻页")
                            }
                        }
                        .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func recentMeetingRow(_ summary: SessionSummary) -> some View {
        Button {
            Task { await openRecord(summary) }
        } label: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(SpeechRailDesignTokens.Color.recessedField)
                        .frame(width: 30, height: 30)
                    Image(systemName: summary.openInterruption != nil ? "exclamationmark.triangle.fill" : "doc.text.fill")
                        .font(SpeechRailDesignTokens.Typography.captionMedium)
                        .foregroundStyle(summary.openInterruption != nil ? SpeechRailDesignTokens.Color.attention : SpeechRailDesignTokens.Color.rail)
                }

                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                    Text(summary.record.title ?? "这一场会议")
                        .font(SpeechRailDesignTokens.Typography.bodyMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                        .lineLimit(1)
                    Text(
                        "\(summary.record.startedAt.speechRailFormatted())"
                            + " · \(summary.lineCount) 段发言"
                            + (summary.speakerCount > 0 ? " · \(summary.speakerCount) 位说话人" : "")
                    )
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    .monospacedDigit()
                }
                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                if summary.openInterruption != nil {
                    StatusPill(tone: .attention, label: "有中断")
                }
                Image(systemName: "chevron.right")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.compact)
            .contentShape(Rectangle())
        }
        .speechRailInteractiveButtonStyle(
            fillsAvailableWidth: true,
            minimumHeight: SpeechRailDesignTokens.List.compactRowHeight
        )
    }

    /// 这一页只做"最近打开过哪几场"的快捷入口。完整列表在会议知识库里。
    private static let quickAccessMeetingLimit = 8

    func reloadRecent() async {
        recent = (try? await session.listSummaries(kind: .meeting)) ?? []
    }
}
