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
                    Text("还没有会议记录。结束一场之后，它会出现在这里。")
                        .font(SpeechRailDesignTokens.Typography.callout)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                        .padding(.vertical, SpeechRailDesignTokens.Spacing.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                                // 截断就**说出来**。只显示最近 8 场而不说明，
                                // 用户会以为另外那些会议不存在（MC-52）。
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
