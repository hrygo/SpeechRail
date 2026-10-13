import SwiftUI

// `MeetingView` 的会议记录库快捷入口：空态下方那一段，点一场进去回看。
// 纯搬移自主文件；跨文件共用的是主文件里的 `@State` 与 `body` 调用的入口。

extension MeetingView {
    // MARK: - 记录库（空态下方那一段：会议**库**在记录库里，不在这一页的主区）

    var libraryCard: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                CardHead(title: "会议记录库") { EmptyView() }
                if recent.isEmpty {
                    Text("还没有会议记录。结束一场之后，它会出现在这里。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(recent.prefix(Self.quickAccessMeetingLimit)) { summary in
                    Button {
                        Task { await openRecord(summary) }
                    } label: {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.hairline) {
                                Text(summary.record.title ?? "这一场会议")
                                    .font(SpeechRailDesignTokens.Typography.callout)
                                    .lineLimit(1)
                                Text(
                                    "\(summary.record.startedAt.formatted(date: .numeric, time: .shortened))"
                                        + " · \(summary.lineCount) 段"
                                        + (summary.speakerCount > 0 ? " · \(summary.speakerCount) 位说话人" : "")
                                )
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                            }
                            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                            if summary.openInterruption != nil {
                                StatusPill(tone: .attention, label: "有中断")
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .speechRailPointerCursor()
                }
                if recent.count > Self.quickAccessMeetingLimit {
                    // 截断就**说出来**。只显示最近 8 场而不说明，
                    // 用户会以为另外那些会议不存在（MC-52）。
                    Divider()
                        .overlay(SpeechRailDesignTokens.Color.separator)
                    Button {
                        showsKnowledgeLibrary = true
                    } label: {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Text("查看全部 \(recent.count) 场会议")
                                .font(SpeechRailDesignTokens.Typography.callout)
                            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                            Image(systemName: "chevron.right")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .speechRailPointerCursor()
                    .accessibilityHint("打开完整的会议知识库，可以搜索、按项目筛选和翻页")
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    /// 这一页只做"最近打开过哪几场"的快捷入口。完整列表在会议知识库里。
    private static let quickAccessMeetingLimit = 8

    func reloadRecent() async {
        recent = (try? await session.listSummaries(kind: .meeting)) ?? []
    }
}
