import AppKit
import SwiftUI

/// 开发者文档：把「怎么接进本机语音能力」放在应用里，而不是只留在仓库的 Markdown 里。
///
/// 结构是「目录列 + 正文列」：一次只展开一个主题。文档页最忌讳的是一屏接一屏的正文——
/// 需要整段阅读的内容应该能被搜索、能被引用，而**不需要**被铺满窗口
/// （REDESIGN-SPEC §13.3，信息密度约束）。
public struct DeveloperDocsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedTopicID: String? = DeveloperDocsCatalog.topics.first?.id
    @State private var copyFeedback: String?
    /// 接入信息带的实测高度：它是「正文槽位下限」的一部分，而它会随窗口宽度在
    /// 一行与两行事实之间变，所以只能量，不能写死。
    @State private var accessCardHeight: CGFloat = 0

    public init() {}

    private var selectedTopic: DeveloperDocTopic? {
        DeveloperDocsCatalog.topics.first { $0.id == selectedTopicID }
            ?? DeveloperDocsCatalog.topics.first
    }

    public var body: some View {
        // 这一页的正文槽位有**确定高度**，而外层仍然是可滚动页面。两件事都要：
        //
        // 1）高度必须由窗口决定。2026-09-16 离屏实测（真实页面 + 真实 `AppModel`，
        //    1200 × 848 窗格，逐个主题渲染）：文档卡的高度在 **219 / 529 / 530 / 536**
        //    之间跳——因为卡片是按内容取高的，而右侧正文列里的 `ScrollView` 在不定高
        //    提案下会报出**内容高度**（短主题 219、长主题 536）。这一跳直接压扁目录列：
        //    卡片 219 高时 `List` 只露得下四个主题，行内自己滚起来，于是「点一个主题，
        //    菜单少了几个」。现在高度来自窗格，主题换来换去卡片都是同一条边。
        //
        // 2）外层必须还能滚。按稿改成「不滚动 + 卡片吃满窗口」时，页首（一句话说明 +
        //    接入信息带）被顶出可视区且没有任何滚动能回到顶部——固定填充外壳在
        //    内容比窗格大时会触发同一类
        //    失败：`.inspector` 与最小高度）。所以现在量窗格、算固定高度，再交给滚动兜底。
        PageScaffold(
            route: .developerDocs,
            layout: .scroll(minimumHeight: minimumPageHeight)
        ) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.gutter) {
                accessCard
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        accessCardHeight = height
                    }
                // 卡片吃掉「页头以下」的剩余高度：稿把这一页画成窗口里的一个面板
                // （`grow(docs)`），所以它不该是「内容多高就多高」。
                docsCard
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        } trailing: {
            // 稿的页头次按钮带 `copy` 图标；复制完成后图标换成对钩，回执不止换字。
            Button {
                copyAccessInfo()
            } label: {
                Label(
                    copyFeedback ?? "复制接入信息",
                    systemImage: copyFeedback == nil ? "doc.on.doc" : "checkmark"
                )
            }
            .speechRailButton(.secondary)
            .disabled(copyFeedback != nil)
            .speechRailPointerCursor()
            .accessibilityLabel("复制接入信息")
            .help("复制服务地址、鉴权方式与当前档位")
        }
        .task {
            // 这一页的每一处结论（运行档位、发布的能力、正文里的分档说法、标题旁的胶囊）
            // 都读自当前服务声明，所以它们必须以**同一时刻**的快照为准。原来这里只补能力清单，
            // 于是从落地页直接进来时会稳定出现「能力读到了、运行档位写着未读取」的半张页面；
            // `refresh()` 同时刷新健康快照、能力清单与控制面档位，这正是 ⌘R 做的那一次读取。
            if model.health == nil || model.serviceCapabilities == nil {
                await model.refresh()
            }
        }
        // 这一页的「重新读取」是把接入信息重新问一次：档位或能力变了，正文里的结论也要变。
        .focusedSceneValue(
            \.reloadPageCommand,
            ReloadPageCommand(title: "重新读取接入信息") {
                Task { await model.refresh() }
            }
        )
    }

    // MARK: - 接入信息

    private var accessCard: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                accessFacts
                HStack(alignment: .firstTextBaseline, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Image(systemName: "info.circle")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .accessibilityHidden(true)
                    Text("这里的档位与能力来自当前服务的真实声明；换档后回到本页即可看到新的能力集合。")
                        .font(SpeechRailDesignTokens.Typography.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    /// 正文槽位的下限 = 接入信息带（实测）+ 块间距 + 文档卡下限。
    private var minimumPageHeight: CGFloat {
        accessCardHeight
            + SpeechRailDesignTokens.Spacing.gutter
            + SpeechRailDesignTokens.DeveloperDocs.cardMinimumHeight
    }

    private var accessFacts: some View {
        // 四个事实并排：地址、鉴权、档位、已发布能力。窄窗口由系统折行，不在这层写死列数。
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.lg) {
                fact("服务地址", DeveloperDocsCatalog.loopbackBaseURL)
                fact("鉴权", authSummary)
                fact("运行档位", profileSummary)
                fact("发布的能力", capabilitySummary)
            }
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                fact("服务地址", DeveloperDocsCatalog.loopbackBaseURL)
                fact("鉴权", authSummary)
                fact("运行档位", profileSummary)
                fact("发布的能力", capabilitySummary)
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
            Text(label)
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            Text(value)
                .font(SpeechRailDesignTokens.Typography.body)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var authSummary: String {
        // 密钥在不在是本机部署事实：服务没有公开「是否已配 key」，所以这里只说契约，
        // 不猜当前状态（未读取 != 未配置）。
        "回环免密钥；非回环需 Bearer"
    }

    private var profileSummary: String {
        guard let profile = model.health?.profile else { return unreadFact }
        return SpeechRailProfilePresentation.shortTitle(profile)
    }

    /// 事实格子里「没读到」的那句话要分清两件事：还在读，和读不到。
    /// 快照还在路上时写「未读取」，会让一页本来是正常加载的界面读起来像出了故障。
    private var unreadFact: String {
        contentState == .checking ? "正在读取…" : "未读取"
    }

    private var capabilitySummary: String {
        guard let capabilities = model.serviceCapabilities else { return unreadFact }
        var names: [String] = []
        if model.health?.asrReady == true { names.append("识别") }
        if model.health?.ttsReady == true { names.append("合成") }
        if capabilities.supportsInstruction { names.append("声音设计") }
        if capabilities.supportsClone { names.append("声音复刻") }
        if model.health?.diarization?.ready == true { names.append("匿名分人") }
        return names.isEmpty ? "未发布可用能力" : names.joined(separator: " · ")
    }

    // MARK: - 目录 + 正文

    private var docsCard: some View {
        CardSurface {
            HStack(alignment: .top, spacing: 0) {
                topicColumn
                Divider()
                ScrollView {
                    topicContent
                        .padding(SpeechRailDesignTokens.Layout.cardInset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var topicColumn: some View {
        // 系统 `List` 提供方向键与选中语义，但选中底色用稿的 `surface/railTint`：
        // `▸ 开发者文档.png`（4x）里「快速开始」那一行是淡青底 + `accent/rail` 图标，
        // 系统默认的实心强调蓝在深浅两色下都不是这一档（与音色库列表同一条改法）。
        List(selection: $selectedTopicID) {
            ForEach(Array(DeveloperDocsCatalog.topics.enumerated()), id: \.element.id) { index, topic in
                topicRow(topic, index: index)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(width: SpeechRailDesignTokens.DeveloperDocs.topicListWidth)
    }

    /// 主题行：稿 `topics` 帧 = padX 12 / padY 14 / 行距 2，行 = padX 10 / padY 8 / radius 8。
    ///
    /// 三处边距都靠行自己给：`List.contentMargins` 对行**不生效**（2026-09-16 带真实窗口
    /// 的离屏实测：写了 `contentMargins(.horizontal, 12, for: .scrollContent)` 之后，
    /// 选中底色块仍然是整列 272 宽；稿上它是 248 宽、离卡沿 12），所以列内边距写进行里，
    /// 底色块再把这几个边距**镜像一遍**，缩进与圆角才对得上稿。
    /// 行内边距由行自己给、`listRowInsets` 清零，与音色库 / 我的作品 / 诊断同一套写法。
    @ViewBuilder
    private func topicRow(_ topic: DeveloperDocTopic, index: Int) -> some View {
        let isSelected = topic.id == selectedTopicID
        let isFirst = index == 0
        let isLast = index == DeveloperDocsCatalog.topics.count - 1
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Image(systemName: topic.systemImage)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .frame(width: SpeechRailDesignTokens.Icon.navigationFrame)
                    .foregroundStyle(
                        isSelected
                            ? SpeechRailDesignTokens.Color.rail
                            : SpeechRailDesignTokens.Color.inkSecondary
                    )
                    .accessibilityHidden(true)
                Text(topic.title)
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(1)
            }
            Text(topic.summary)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .lineLimit(SpeechRailDesignTokens.DeveloperDocs.topicDescriptionMaximumLines)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(
            .horizontal,
            SpeechRailDesignTokens.DeveloperDocs.topicRowHorizontalPadding
        )
        .padding(
            .vertical,
            SpeechRailDesignTokens.DeveloperDocs.topicRowVerticalPadding
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(
            .horizontal,
            SpeechRailDesignTokens.DeveloperDocs.topicColumnHorizontalPadding
        )
        .padding(
            .top,
            isFirst ? SpeechRailDesignTokens.DeveloperDocs.topicColumnVerticalPadding : 0
        )
        .padding(
            .bottom,
            isLast ? SpeechRailDesignTokens.DeveloperDocs.topicColumnVerticalPadding : 0
        )
        .tag(topic.id)
        .listRowInsets(EdgeInsets())
        // 稿的行底色是**带圆角的块**，不是整条色带；`listRowBackground` 收的是视图，
        // 所以这里给它一个填充过的圆角矩形——形状归这一层，选中语义仍归系统。
        //
        // 这一层还必须**不透明**：系统的选中层画在行背景的下面（音色库那一轮的逐像素
        // 实测：`listRowBackground` 是唯一能盖住它的写法），而块是内缩的——只铺块，
        // 它四周就会露出系统那层实心强调色带，于是同一行同时出现「带 + 块」两处选中反馈
        // （2026-09-16 用户截图）。选中行先铺一层与卡片同值的 `Color.field` 盖掉系统层，
        // 块再叠在上面：选中反馈只剩稿的这一处。
        .listRowBackground(
            Group {
                if isSelected {
                    SpeechRailDesignTokens.Color.field
                        .overlay {
                            RoundedRectangle(
                                cornerRadius: SpeechRailDesignTokens.DeveloperDocs
                                    .topicRowCornerRadius,
                                style: .continuous
                            )
                            .fill(SpeechRailDesignTokens.Surface.selectionTint)
                            // 底色块把行上的三处边距镜像回来：列内边距 12、首尾各 14、
                            // 以及行距（稿 gap 2）的一半 1 —— 相邻两块因此隔 2pt。
                            .padding(
                                .horizontal,
                                SpeechRailDesignTokens.DeveloperDocs.topicColumnHorizontalPadding
                            )
                            .padding(
                                .top,
                                SpeechRailDesignTokens.Spacing.tight / 2
                                    + (isFirst
                                        ? SpeechRailDesignTokens.DeveloperDocs
                                            .topicColumnVerticalPadding
                                        : 0)
                            )
                            .padding(
                                .bottom,
                                SpeechRailDesignTokens.Spacing.tight / 2
                                    + (isLast
                                        ? SpeechRailDesignTokens.DeveloperDocs
                                            .topicColumnVerticalPadding
                                        : 0)
                            )
                        }
                } else {
                    Color.clear
                }
            }
        )
        // 主题之间没有分隔线（稿里只有行距 2）。
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var topicContent: some View {
        if let topic = selectedTopic {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                        Text(topic.title)
                            .font(SpeechRailDesignTokens.Typography.display)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                        StatusPill(
                            tone: contentState.tone,
                            label: contentState.label
                        )
                        Spacer(minLength: 0)
                    }
                    Text(topic.summary)
                        .font(SpeechRailDesignTokens.Typography.callout)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
                ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .frame(
                maxWidth: SpeechRailDesignTokens.DeveloperDocs.contentMaximumWidth,
                alignment: .leading
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 正文标题旁那颗胶囊的状态（稿：「已按当前档位核对」）。
    ///
    /// 这一页与档位有关的说法都读自当前服务声明，所以胶囊必须是一句真话，而且要把
    /// **还没读到**和**读不到**分开：服务正常、快照还在路上时报警，等于把加载说成故障；
    /// 只有读取真的失败（或读完了却缺那一项）才该说未读取——「未读取」不是「不支持」，
    /// 与 §11.6 第五十一轮、音色创作页 `checking` / `failed` 同一口径。
    private enum ContentState {
        case verified
        case checking
        case unread

        var tone: StatusTone {
            switch self {
            case .verified: .healthy
            case .checking: .neutral
            case .unread: .attention
            }
        }

        var label: String {
            switch self {
            case .verified: "已按当前档位核对"
            case .checking: "正在读取档位…"
            case .unread: "档位未读取"
            }
        }
    }

    private var contentState: ContentState {
        if model.health?.profile != nil, model.serviceCapabilities != nil { return .verified }
        switch model.serviceCapabilitiesLoadState {
        case .unknown, .loading: return .checking
        // 读完了却还缺一项（例如健康快照里没有档位），或这次读取失败：如实说没读到。
        case .loaded, .failed: return .unread
        }
    }

    @ViewBuilder
    private func blockView(_ block: DeveloperDocTopic.Block) -> some View {
        switch block {
        case let .paragraph(text):
            Text(text)
                .font(SpeechRailDesignTokens.Typography.body)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        case let .bullets(items):
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Text("•")
                            .font(SpeechRailDesignTokens.Typography.body)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                            .accessibilityHidden(true)
                        Text(item)
                            .font(SpeechRailDesignTokens.Typography.body)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case let .code(language, lines):
            codeBlock(language: language, lines: lines)
        case let .endpoints(endpoints):
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                ForEach(Array(endpoints.enumerated()), id: \.offset) { _, endpoint in
                    endpointRow(endpoint)
                }
            }
        case let .note(text):
            HStack(alignment: .firstTextBaseline, spacing: SpeechRailDesignTokens.Spacing.xs) {
                Image(systemName: "lightbulb")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .accessibilityHidden(true)
                Text(text)
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            .padding(SpeechRailDesignTokens.Spacing.sm)
            .speechRailField()
        }
    }

    private func codeBlock(language: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text(language)
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                Spacer(minLength: 0)
                Button {
                    copy(lines.joined(separator: "\n"), feedback: "已复制示例")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(SpeechRailDesignTokens.Typography.caption)
                }
                .buttonStyle(.plain)
                .speechRailPointerCursor()
                .accessibilityLabel("复制这段示例")
                .help("复制这段示例")
            }
            // 代码用系统等宽字体：缩进与路径的对齐不能靠比例字体碰运气。
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(SpeechRailDesignTokens.Typography.code)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.sm)
        .frame(
            minHeight: SpeechRailDesignTokens.DeveloperDocs.codeBlockMinimumHeight,
            alignment: .topLeading
        )
        .speechRailContentSurface()
    }

    private func endpointRow(_ endpoint: DeveloperDocTopic.Endpoint) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Text(endpoint.method)
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                .frame(
                    width: SpeechRailDesignTokens.DeveloperDocs.endpointMethodWidth,
                    alignment: .leading
                )
            Text(endpoint.path)
                .font(SpeechRailDesignTokens.Typography.code)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .textSelection(.enabled)
                .frame(
                    width: SpeechRailDesignTokens.DeveloperDocs.endpointPathWidth,
                    alignment: .leading
                )
            Text(endpoint.detail)
                .font(SpeechRailDesignTokens.Typography.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - 复制

    private func copyAccessInfo() {
        let text = [
            "SpeechRail 接入信息",
            "服务地址：\(DeveloperDocsCatalog.loopbackBaseURL)",
            "OpenAI 兼容 base_url：\(DeveloperDocsCatalog.openAICompatBaseURL)",
            "鉴权：\(authSummary)",
            "运行档位：\(profileSummary)",
            "发布的能力：\(capabilitySummary)"
        ].joined(separator: "\n")
        copy(text, feedback: "已复制")
    }

    private func copy(_ text: String, feedback: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copyFeedback = feedback
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copyFeedback == feedback { copyFeedback = nil }
        }
    }
}
