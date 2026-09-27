import SpeechRailControlKit
import SwiftUI

public struct ModelManagementView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    /// 助手还在听/想/说时不能切档：切档会重启服务，等于把这一轮打断。
    @Environment(AssistantSession.self) private var assistant
    /// 开发者详情是全 App 的一个偏好（View ▸ 显示/隐藏开发者详情 ⌘⌥I）。
    @AppStorage("speechrail.showDeveloperDetails") private var showInspector = false
    /// 识别与配音是两条**独立**的轴，任何一档都能配任何一档（九种组合）。
    /// 三张档位卡只是其中三种最常用的预设，写这两项相同的值。
    @State private var asrSpec: SpeechRailProfile = .quality
    @State private var ttsSpec: SpeechRailProfile = .quality
    @State private var selectedArtifactKey: String?
    @State private var pendingAction: ModelAction?

    public init() {}

    /// 下载与应用只认这一对 `asr_spec`/`tts_spec`，它是页面上唯一的选择真相：
    /// 两条轴直接写它，预设卡只是把两项设成同一个值，wire 上不产生第三份 preset。
    private var targetSelection: SpecSelection {
        SpecSelection(asrSpec: asrSpec, ttsSpec: ttsSpec)
    }

    public var body: some View {
        PageScaffold(route: .models) {
            mainContent
        }
        // 这一页的动作全都属于卡片里的制品（下载并校验、应用到档位），所以没有头部动作；
        // 页面身份由窗口组合根 `ControlCenterView` 声明（§6.2）。
        .focusedSceneValue(
            \.reloadPageCommand,
            ReloadPageCommand(title: "重新读取模型目录") {
                Task { await model.refreshModelsAndHealth() }
            }
        )
        .inspector(isPresented: $showInspector) {
            modelInspector
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: isConfirmingAction,
            titleVisibility: .visible
        ) {
            if let pendingAction {
                Button(
                    actionTitle(for: pendingAction),
                    role: pendingAction == .apply ? .destructive : nil
                ) {
                    let action = pendingAction
                    self.pendingAction = nil
                    Task {
                        switch action {
                        case .download:
                            await model.prepareModels(targetSelection)
                        case .apply:
                            // 确认对话框可能在助手开始说话后才被按下；这里再挡一次。
                            guard !assistant.phase.isLive else { return }
                            await model.execute(.profileApply, selection: targetSelection)
                        }
                    }
                }
            }
            Button("取消", role: .cancel) {
                pendingAction = nil
            }
        } message: {
            Text(confirmationMessage)
        }
        .task {
            model.refreshControlAgentStatus()
            await model.refreshModelsAndHealth()
            if let active = model.operation?.selection ?? model.profile?.selection {
                adopt(active)
            }
            selectFirstArtifactIfNeeded()
        }
        .onChange(of: model.profile?.selection) { _, value in
            if let value { adopt(value) }
        }
        .onChange(of: model.operation?.selection) { _, value in
            if let value { adopt(value) }
        }
        .onChange(of: targetSelection) { _, _ in
            selectFirstArtifactIfNeeded()
        }
        .onChange(of: model.modelCatalog) { _, _ in
            selectAvailableProfileIfNeeded()
            selectFirstArtifactIfNeeded()
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        switch model.modelAvailability {
        case .unknown:
            ProgressView("正在读取模型目录…")
                .frame(maxWidth: .infinity, minHeight: SpeechRailDesignTokens.Layout.emptyStateMinimumHeight)
                .speechRailContentSurface()
        case .available:
            modelWorkspace
        case .unsupported:
            unavailableBanner(
                title: "模型管理暂不可用",
                message: model.message.map { SpeechRailOperationMessagePresentation.text($0) }
                    ?? "模型管理暂不可用：服务组件版本不匹配",
                tone: .critical,
                actionTitle: "打开诊断"
            ) {
                navigation.request(.diagnostics)
            }
        case .notReady:
            unavailableBanner(
                title: "模型状态尚未就绪",
                message: model.message.map { SpeechRailOperationMessagePresentation.text($0) }
                    ?? "请先确认本机服务和控制 Agent 已就绪。",
                tone: .attention,
                actionTitle: "打开诊断"
            ) {
                navigation.request(.diagnostics)
            }
        case .failed:
            unavailableBanner(
                title: "模型状态读取失败",
                message: model.message.map { SpeechRailOperationMessagePresentation.text($0) }
                    ?? "重新读取模型目录，或打开诊断查看阻塞原因。",
                tone: .critical,
                actionTitle: "打开诊断"
            ) {
                navigation.request(.diagnostics)
            }
        }
    }

    private func unavailableBanner(
        title: String,
        message: String,
        tone: StatusTone,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        StatusBanner(
            tone: tone,
            title: title,
            message: message,
            actionTitle: actionTitle,
            action: action
        )
    }

    private var modelWorkspace: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.gutter) {
            // 页面主对象（REDESIGN-SPEC §7.7「当前档位与它的准备状态」）先给结论，
            // 再给选择与操作。此前这条结论是模型卡中段的一行小字，用户要读完上下文
            // 三列、事实四列和动作区叠着的多条告警才拼得出来「我现在在哪、下一步做什么」。
            readinessConclusion
            specSelection
            profilePresets
            actionSection
            modelFileSections
        }
    }

    /// 两条轴常驻，不用先展开什么。
    ///
    /// 此前自由组合被收在一个默认折叠的「分别调整识别与配音」里，而三张档位卡摆在上面，
    /// 于是整页读起来是「只有三档可选」。实际上三档只是**预设**：识别与配音各自三档，
    /// 一共九种组合，两次点击就能任意搭配。既然如此，两条轴就该是页面上第一等的控件，
    /// 预设退成它下面的快捷方式。
    private var specSelection: some View {
        let profiles = availableProfiles
        return CardSurface {
            CardHead(
                title: "识别与配音",
                detail: "识别和配音各自选档，自由搭配。点击下方常用组合可一键重置为对应档位。"
            )
            Divider()
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
                if profiles.isEmpty {
                    Text("服务目录尚未返回可选择的档位。")
                        .font(SpeechRailDesignTokens.Typography.secondary)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                } else {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                        specPicker(
                            "识别",
                            systemImage: "waveform",
                            identifier: "models-asr-axis",
                            selection: $asrSpec,
                            profiles: profiles,
                            badgeText: asrAxisBadgeText(asrSpec)
                        )
                        specPicker(
                            "配音",
                            systemImage: "speaker.wave.2",
                            identifier: "models-tts-axis",
                            selection: $ttsSpec,
                            profiles: profiles,
                            badgeText: ttsAxisBadgeText(ttsSpec)
                        )
                    }

                    Divider()

                    combinationSummaryBar
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
            .accessibilityIdentifier("models-spec-selection")
        }
    }

    private func specPicker(
        _ title: String,
        systemImage: String,
        identifier: String,
        selection: Binding<SpeechRailProfile>,
        profiles: [SpeechRailProfile],
        badgeText: String
    ) -> some View {
        HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.sm) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Image(systemName: systemImage)
                    .font(SpeechRailDesignTokens.Typography.calloutMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                    .frame(width: 16)
                Text(title)
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
            }
            .frame(
                width: SpeechRailDesignTokens.Layout.modelProfileSpecLabelWidth,
                alignment: .leading
            )
            Picker(title, selection: selection) {
                ForEach(profiles, id: \.self) { profile in
                    Text(SpeechRailProfilePresentation.shortTitle(profile))
                        .tag(profile)
                }
            }
            .pickerStyle(.segmented)
            .frame(minWidth: 200, maxWidth: 280)
            .accessibilityIdentifier(identifier)
            .speechRailPointerCursor()

            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)

            Text(badgeText)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .lineLimit(1)
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                .padding(.vertical, SpeechRailDesignTokens.Spacing.tiny)
                .background(
                    SpeechRailDesignTokens.Color.field,
                    in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                )
        }
    }

    private func asrAxisBadgeText(_ profile: SpeechRailProfile) -> String {
        switch profile {
        case .fast:
            "0.6B Q8 · 极速低显存"
        case .quality:
            "1.7B Q8 · 推荐日常主力"
        case .reference:
            "1.7B BF16 · 满血原生精度"
        case .unrecognized:
            "未识别规格"
        }
    }

    private func ttsAxisBadgeText(_ profile: SpeechRailProfile) -> String {
        switch profile {
        case .fast:
            "0.6B Q8 · 极低时延，实时对话"
        case .quality:
            "1.7B Q8 · 自然生动，支持声音克隆"
        case .reference:
            "1.7B BF16 · 满血高保真音色"
        case .unrecognized:
            "未识别规格"
        }
    }

    private var combinationSummaryBar: some View {
        HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Text(targetSelection.quickTier != nil ? "同档预设" : "自定义混搭")
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .foregroundStyle(
                    targetSelection.quickTier != nil
                        ? SpeechRailDesignTokens.Color.rail
                        : SpeechRailDesignTokens.Color.inkSecondary
                )
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                .padding(.vertical, SpeechRailDesignTokens.Spacing.tiny)
                .background(
                    targetSelection.quickTier != nil
                        ? SpeechRailDesignTokens.Surface.selectedFill
                        : SpeechRailDesignTokens.Color.field,
                    in: Capsule()
                )

            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text("当前组合：")
                    .font(SpeechRailDesignTokens.Typography.secondary)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

                Text(combinationSummary)
                    .font(SpeechRailDesignTokens.Typography.secondary)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
            }
            .lineLimit(1)

            if let totalBytes = targetSelectionTotalBytes {
                Text("· 约 \(formatBytes(totalBytes))")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    .monospacedDigit()
            }

            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)

            if currentServiceProfile == targetSelection {
                Label("与当前运行一致", systemImage: "checkmark.circle.fill")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ready)
            } else if let running = currentServiceProfile {
                Text("当前运行：\(SpeechRailProfilePresentation.shortTitle(running))")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
        }
    }
    /// 一句话说明当前组合。用短名（§4.2），并且**总是**把两条轴都写出来——
    /// 只在混搭时写「识别轻快 · 配音品质」，同档时用户看不出这是两项都选了同一档。
    private var combinationSummary: String {
        let asr = SpeechRailProfilePresentation.shortTitle(asrSpec)
        let tts = SpeechRailProfilePresentation.shortTitle(ttsSpec)
        return asr == tts
            ? "识别与配音都用「\(asr)」"
            : "识别用「\(asr)」，配音用「\(tts)」"
    }

    /// 三张卡是**预设**而不是全部选项：点一下把两条轴一起设成同一档。
    /// 卡上仍写这一档的取向与三行差异，供自由组合时对照每一档的差别。
    private var profilePresets: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            SectionHeading(
                title: "常用组合",
                detail: "点一下就把识别与配音一起设成这一档；要混搭，用上面两条轴分别选。"
            )
            profileCards
        }
    }

    /// 只显示服务目录实际发布的档位；宽度允许时单行展示，空间不足时改为两列。
    @ViewBuilder
    private var profileCards: some View {
        let profiles = availableProfiles
        let cardMinimumWidth = SpeechRailDesignTokens.Layout.modelProfileCardMinimumWidth
        let rowMinimumWidth = profiles.count == SpeechRailProfile.allCases.count
            ? SpeechRailDesignTokens.Layout.modelProfileCardsRowBreakpoint
            : cardMinimumWidth * CGFloat(profiles.count)
                + SpeechRailDesignTokens.Spacing.sm * CGFloat(max(0, profiles.count - 1))
        let twoColumnGrid = [
            GridItem(.flexible(minimum: cardMinimumWidth), spacing: SpeechRailDesignTokens.Spacing.sm, alignment: .top),
            GridItem(.flexible(minimum: cardMinimumWidth), spacing: SpeechRailDesignTokens.Spacing.sm, alignment: .top),
        ]

        if profiles.isEmpty {
            ContentUnavailableView(
                "服务没有返回可管理的档位",
                systemImage: AppRoute.models.systemImage,
                description: Text("请重新读取模型目录；服务暂未提供可选择的档位。")
            )
            .frame(maxWidth: .infinity, minHeight: SpeechRailDesignTokens.Layout.emptyStateMinimumHeight)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
                    profileChoiceCards(profiles, minimumWidth: cardMinimumWidth)
                }
                .frame(minWidth: rowMinimumWidth, alignment: .leading)

                LazyVGrid(
                    columns: twoColumnGrid,
                    alignment: .leading,
                    spacing: SpeechRailDesignTokens.Spacing.sm
                ) {
                    profileChoiceCards(profiles, minimumWidth: cardMinimumWidth)
                }
            }
        }
    }

    private func profileChoiceCards(
        _ profiles: [SpeechRailProfile],
        minimumWidth: CGFloat
    ) -> some View {
        ForEach(profiles, id: \.self) { profile in
            let isQuickSelected = targetSelection == .quick(profile)
            let isRunning = currentServiceProfile == .quick(profile)
            let partialBadge: String? = {
                if isQuickSelected { return nil }
                if asrSpec == profile && ttsSpec == profile {
                    return nil
                } else if asrSpec == profile {
                    return "识别已选"
                } else if ttsSpec == profile {
                    return "配音已选"
                }
                return nil
            }()

            ProfileChoiceCard(
                profile: profile,
                sizeText: summary(for: profile).map {
                    "该档模型总大小 \(formatBytes($0.downloadBytes))"
                },
                specs: profileSpecs(for: profile),
                isSelected: isQuickSelected,
                isRunning: isRunning,
                partialSelectionBadge: partialBadge
            ) {
                selectProfilePreset(profile)
            }
            .frame(minWidth: minimumWidth, maxWidth: .infinity, alignment: .leading)
        }
    }

    private func selectProfilePreset(_ profile: SpeechRailProfile) {
        withAnimation(SpeechRailDesignTokens.Motion.selectionFeedback) {
            asrSpec = profile
            ttsSpec = profile
        }
    }

    /// 三行规格只呈现服务目录声明的能力和本档效果验证状态。
    private func profileSpecs(for profile: SpeechRailProfile) -> [ProfileSpec] {
        switch profile {
        case .fast:
            return [
                ProfileSpec(label: "识别规格", value: "0.6B (8-bit) · 极速低显存"),
                ProfileSpec(label: "配音规格", value: "0.6B (8-bit) · 极低时延"),
                ProfileSpec(label: "核心特点", value: "加载秒级 · 资源占用最小"),
            ]
        case .quality:
            return [
                ProfileSpec(label: "识别规格", value: "1.7B (8-bit) · 日常高准确率"),
                ProfileSpec(label: "配音规格", value: "1.7B (8-bit) · 自然生动支持克隆"),
                ProfileSpec(label: "核心特点", value: "官方推荐 · 兼顾自然与性能"),
            ]
        case .reference:
            return [
                ProfileSpec(label: "识别规格", value: "1.7B (BF16) · 原生高精权重"),
                ProfileSpec(label: "配音规格", value: "1.7B (BF16) · 满血高保真音质"),
                ProfileSpec(label: "核心特点", value: "满血精度 · 需较大内存"),
            ]
        case .unrecognized:
            return [
                ProfileSpec(label: "识别规格", value: "未识别"),
                ProfileSpec(label: "配音规格", value: "未识别"),
                ProfileSpec(label: "核心特点", value: "未知档位"),
            ]
        }
    }

    /// 分人是任务级按需能力, 不随档位变化: 三张卡上这一行说的是同一件事, 逐项状态
    /// 在下面的「谁在说话」小节里列。这里只回答「现在能不能用」。
    private var diarizationReadinessText: String {
        guard model.modelCatalog != nil else { return "未读取" }
        return missingDiarizationKeys.isEmpty ? "可用" : "需补齐模型"
    }

    private func voiceCreationSupport(for summary: ProfileSummary?) -> String {
        guard let summary else { return "未读取" }
        // VoiceDesign 与档位无关: 目录里那份按需设计制品存在即可用。
        guard let catalog = model.modelCatalog,
              catalog.hasVoiceDesignArtifact
        else {
            return "不支持"
        }
        let supportsClone = summary.ttsBase.flatMap { baseKey in
            catalog.artifacts.first(where: { $0.key == baseKey && $0.variant == "base" })
        } != nil
        return supportsClone ? "支持（含克隆）" : "支持"
    }

    /// 模型文件与按需能力各自成卡。此前它们连同「目标 / 当前 / 配置」上下文三列、
    /// 事实四列和就绪小结共用**一张**大卡，四个主题被同一个外框兜住，读者分不清
    /// 哪一段说的是「这一档要用什么」、哪一段说的是「不随档位变化的能力」。
    private var modelFileSections: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.gutter) {
            artifactSection
            if !unmanagedArtifactStatuses.isEmpty {
                unmanagedArtifactSection
            }
            if !onDemandCapabilities.isEmpty {
                onDemandCapabilitiesSection
            }
        }
    }

    /// REDESIGN-SPEC §7.7 的主对象：当前档位与它的准备状态。
    ///
    /// 一句话先回答「服务现在跑的是哪一档、模型够不够」。
    ///
    /// 面板**只给结论，不摆动作**：「下载并校验 / 应用此档位」这两个操作由紧随其下
    /// 的动作行承担，同一屏里出现两次同名主按钮会被读成界面出错。两者相距不到一个
    /// 块间距，结论与出口的对应关系不需要靠按钮重复来强调。
    private var readinessConclusion: some View {
        let presentation = modelReadinessPresentation
        return StatusBanner(
            kind: .conclusion,
            tone: presentation.tone,
            title: presentation.title,
            message: presentation.message
        )
    }

    /// Figma `artifacts` 的列头：右侧三个窄列没有列头时读起来像无主的装饰。
    private var artifactColumnsHeader: some View {
        ArtifactColumnGrid { metrics in
            HStack(spacing: 0) {
                Text("模型文件")
                    .frame(
                        minWidth: metrics.artifactMinimum,
                        maxWidth: metrics.artifact,
                        alignment: .leading
                    )
                // 列名与列里的取值必须是同一件事：这一列答的是「这份权重多少位」，
                // 所以叫「精度」而不是「量化」——未量化的制品同样有位数（用户 2026-09-23）。
                Text("精度")
                    .frame(width: metrics.quantization, alignment: .leading)
                Text("文件")
                    .frame(width: metrics.file, alignment: .trailing)
                Text("校验")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        // 稿的制品表列头是 `Caption / Medium`（脚本 1945）。
        .font(SpeechRailDesignTokens.Typography.captionMedium)
        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
        // 列头与上方 `CardHead` 同一条左沿（稿 `header` 与 `head` 都是 padX 18；
        // 应用此前 8pt，比卡头缩进 8pt，同一张卡里两行左沿对不齐）。
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .accessibilityHidden(true)
    }

    private var artifactSection: some View {
        CardSurface {
            CardHead(
                title: "模型文件",
                // 卡头只解释**这张表里真的有的字**：表头是名称 / 精度 / 文件 / 校验，
                // 「已下载」「在用」「已释放」在这一节里一次都没出现（它们在开发者详情
                // 与运行监控里）。原来的说明解释的是别处才有的词，读起来像这张表
                // 少了东西（用户 2026-09-22：模型信息要清晰）。
                detail: "这组档位要用的模型文件。校验通过只说明本机文件完整，不代表服务正在用它。",
                // 右端给进度：这一节最常被问的就是「还差几个」。结论面板说的是
                // 整个页面（含按需能力）的差口，这里说的是**这张表**自己的进度，
                // 两者口径不同，所以分开写。
                accessory: artifactReadinessAccessory
            ) {
                Button {
                    withAnimation(SpeechRailDesignTokens.Motion.selectionFeedback) {
                        showInspector.toggle()
                    }
                } label: {
                    Label(
                        showInspector ? "收起详情" : "模型详情",
                        systemImage: showInspector ? "sidebar.right" : "info.circle"
                    )
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                }
                .buttonStyle(.borderless)
                .speechRailPointerCursor()
                .help("查看所选模型的来源、哈希与校验详情 (⌘⌥I)")
            }
            Divider()
            if model.modelCatalog != nil {
                let artifacts = visibleArtifacts
                if artifacts.isEmpty {
                    ContentUnavailableView(
                        "这组档位还没有登记模型文件",
                        systemImage: AppRoute.models.systemImage,
                        description: Text("先运行一次预检，或者去受管的运行环境目录里看看模型在不在。")
                    )
                    .frame(
                        maxWidth: .infinity,
                        minHeight: SpeechRailDesignTokens.Layout.modelArtifactEmptyStateMinimumHeight
                    )
                } else {
                    VStack(spacing: 0) {
                        // Figma `artifacts`：制品表是四列，不是五行堆叠的说明块。
                        // 来源、目标档位与使用状态都在右侧 Inspector，行里只留
                        // 一眼要量的四个字段（§7.7、§7.6.1 密度约束）。
                        artifactColumnsHeader
                        Divider()
                        ForEach(Array(artifacts.enumerated()), id: \.element.key) { index, artifact in
                            Button {
                                selectedArtifactKey = artifact.key
                            } label: {
                                ArtifactChoiceRow(
                                    artifact: artifact,
                                    status: status(for: artifact),
                                    selected: selectedArtifactKey == artifact.key
                                )
                            }
                            .speechRailInteractiveButtonStyle(fillsAvailableWidth: true)
                            .accessibilityIdentifier("artifact-\(artifact.key)")
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded {
                                    withAnimation(SpeechRailDesignTokens.Motion.selectionFeedback) {
                                        showInspector = true
                                    }
                                }
                            )
                            if index < artifacts.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "模型目录暂时不可用",
                    systemImage: AppRoute.models.systemImage,
                    description: Text("管理控制台会通过本机控制 Agent 读取锁定目录。")
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: SpeechRailDesignTokens.Layout.modelEmptyStateMinimumHeight
                )
            }
            Divider()
            // 设计稿的脚注动作是「仅校验缺失项」；本机只有「下载并校验」这一条准备
            // 路径，没有独立的重新校验操作，所以这里只给出事实，不摆做不到的按钮。
            CardFoot(note: artifactFootnote) {
                EmptyView()
            }
        }
    }

    /// Figma `listFoot`：当前档位的模型文件总数、待校验数量，以及它对「谁在说话」的影响。
    private var artifactFootnote: String {
        let artifacts = visibleArtifacts
        guard !artifacts.isEmpty else { return "这组档位还没有登记模型文件。" }
        let pending = artifacts.filter { !isVerified(status(for: $0)) }.count
        let base = pending == 0
            ? "\(artifacts.count) 个模型文件 · 全部已校验"
            : "\(artifacts.count) 个模型文件 · \(pending) 个待校验"
        let diarizationNote = missingDiarizationKeys.isEmpty
            ? ""
            : "，说话人区分在补齐前用不了"
        return base + diarizationNote + "。"
    }

    /// 卡头右端的进度事实。`CardHead.accessory` 是「贴着右边缘的一句本机事实」，
    /// 与标题分开排，标题因此不会被一起推向右半边。
    private var artifactReadinessAccessory: String? {
        let artifacts = visibleArtifacts
        guard !artifacts.isEmpty else { return nil }
        let ready = artifacts.filter { isVerified(status(for: $0)) }.count
        return ready == artifacts.count
            ? "\(artifacts.count) 个全部就绪"
            : "已就绪 \(ready)/\(artifacts.count)"
    }

    private var unmanagedArtifactSection: some View {
        CardSurface {
            CardHead(
                title: "已检测但未纳入当前目录",
                detail: "这些模型文件还在本机，但没有登记在当前这组档位里；选档和运行都不会用到它们。"
            )
            Divider()
            VStack(spacing: 0) {
                ForEach(unmanagedArtifactStatuses, id: \.key) { status in
                    UnmanagedArtifactRow(status: status)
                }
            }
        }
    }

    /// 三项按任务准备的能力合并成一张卡。
    ///
    /// 说话人区分、音色创作与实时语音断句都不随档位变化，此前各自是一个带标题的
    /// 小节，读起来像三件互不相干的事；合在一张卡里之后，「这三项和上面的档位
    /// 模型不是一回事」这件事才看得出来——上面那张表随档位换，这张卡不换。
    private var onDemandCapabilitiesSection: some View {
        CardSurface {
            CardHead(
                title: "按需能力",
                detail: "这三项不随档位变化，任何档位都能用；用到时才准备，需要时单独下载。"
            )
            Divider()
            VStack(spacing: 0) {
                ForEach(Array(onDemandCapabilities.enumerated()), id: \.element.id) { index, capability in
                    if index > 0 {
                        Divider()
                    }
                    OnDemandCapabilityRow(capability: capability)
                }
            }
        }
    }

    /// 按需能力的每一行都是「这一项是干什么的 + 现在是什么状态」。
    /// 只有目录或 `/health` 真的报了对应能力才出现，不拿占位条目凑数。
    private var onDemandCapabilities: [OnDemandCapability] {
        var capabilities: [OnDemandCapability] = []
        if !requiredDiarizationKeys.isEmpty || model.health?.diarization != nil {
            capabilities.append(diarizationCapability)
        }
        if !voiceDesignArtifacts.isEmpty || model.modelCatalog?.hasVoiceDesignArtifact == true {
            capabilities.append(voiceDesignCapability)
        }
        if model.health?.realtimeVAD != nil {
            capabilities.append(vadCapability)
        }
        return capabilities
    }

    /// 说话人区分：目录用 `required_by: ["diarization"]` 声明这组按需制品，
    /// 服务另开一条通道检查运行态。对齐用的 aligner 同时也绑定档位，已经在上面
    /// 那张表里，所以这里只回答说话人模型本身。
    private var diarizationCapability: OnDemandCapability {
        let state: (String, StatusTone)
        if model.modelCatalog == nil {
            state = ("未读取", .neutral)
        } else if requiredDiarizationKeys.isEmpty {
            // 同 `voiceDesignCapability`：目录没登记说话人模型时不能报就绪。
            state = ("状态未读取", .neutral)
        } else if missingDiarizationKeys.isEmpty {
            state = ("模型已就绪", .healthy)
        } else {
            state = ("还差 \(missingDiarizationKeys.count) 个模型", .attention)
        }
        return OnDemandCapability(
            id: "diarization",
            title: "说话人区分",
            detail: "标出每句话是谁说的。会议和字幕需要说话人标签时才准备。",
            state: state.0,
            tone: state.1,
            // 就绪时**不照抄服务端那句英文**（本机实测原文：
            // `CoreML Sortformer FP16 is configured`）——它写给调用方看，不是给用户读的。
            // 没就绪时才把服务给的原因带出来：那一刻它是唯一的线索（§4.3）。
            runtime: diarizationRuntime.map { "服务：\($0.text)" }
        )
    }

    /// 音色创作的设计权重同样不绑定档位，目录里也不在任何一张档位表上。
    private var voiceDesignCapability: OnDemandCapability {
        let state: (String, StatusTone)
        if model.modelCatalog == nil {
            state = ("未读取", .neutral)
        } else if model.modelCatalog?.hasVoiceDesignArtifact != true {
            state = ("不支持", .neutral)
        } else if allVoiceDesignArtifacts.isEmpty {
            // 目录声明了这项能力，却没给出可核对的文件。说不出「齐了没有」，
            // 就不能报就绪（§4.3）。
            state = ("状态未读取", .neutral)
        } else if allVoiceDesignArtifacts.allSatisfy({ isVerified(status(for: $0)) }) {
            state = ("模型已就绪", .healthy)
        } else {
            state = ("需要下载", .attention)
        }
        return OnDemandCapability(
            id: "voice-design",
            title: "音色创作",
            detail: "用来试听和设计新音色，也支持按参考录音克隆。任何档位都能用。",
            state: state.0,
            tone: state.1,
            runtime: model.modelCatalog?.hasVoiceDesignArtifact == true ? "可试听候选音色" : nil
        )
    }

    /// 实时语音断句只判断「什么时候算有人在说话」，不产出文字，因此既没有目录
    /// 制品也不随档位变化：它只出现在运行状态里。
    private var vadCapability: OnDemandCapability {
        let runtime = vadRuntime
        // 胶囊只说「这一项现在能不能用」，不复述服务给的整句原因——那句话留在下面
        // 那一行，胶囊保持可扫读。
        let state: String = switch runtime?.tone {
        case .healthy: "运行中"
        case .attention, .critical: "未就绪"
        default: "未读取"
        }
        return OnDemandCapability(
            id: "realtime-vad",
            title: "实时语音断句",
            detail: "实时模式靠它判断一句话从什么时候开始、什么时候结束。它不出文字，也不占档位模型。",
            state: state,
            tone: runtime?.tone ?? .neutral,
            // 同上：本机实测就绪原文是 `Silero VAD runtime and model are ready`。
            // 就绪时用界面自己的话说明它在做什么；没就绪才把服务给的原因原样带出来。
            runtime: vadRuntimeDetail
        )
    }

    private var vadRuntimeDetail: String {
        let engine = "检测引擎：\(vadEngineLabel)"
        guard let runtime = vadRuntime else { return engine }
        return runtime.tone == .healthy
            ? "\(engine) · 说话与安静的边界由它在线判断，字幕带据此断句。"
            : "\(engine) · \(runtime.text)"
    }

    /// Figma `actions`：动作行紧跟档位卡、排在制品卡之前。4x 帧实测（`▸ 模型.png`）
    /// 两张卡之间是一条 74.25pt 的页面底色带，里面只有一行 34pt 的动作，上下各留
    /// 20pt——与页面级块间距 `Spacing.gutter` 同值；「磁盘」事实在这一行右端。
    ///
    /// 这里不再放「下一步」小标题：稿上没有，页头副标题「先下载并校验，再应用到运行
    /// 档位；两者是独立操作。」已经说过同一句话（全局密度约定：不重复解释）。
    /// 下方只保留会改变判断的阻塞原因，以及正在进行/被中断的操作本身。
    private var actionSection: some View {
        let isReadyToApply = canApplyProfile && (currentServiceProfile != targetSelection)
        let isDownloadPrimary = !profileArtifactsVerified || !canApplyProfile

        return VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            // 稿 `actions` 的 gap 是 8（脚本 `frame("actions", { gap: 8 })`）；4x 帧在
            // 按钮中线上量的间距是 8.25（圆角矩形在中线最宽，顶边附近量会被圆角吃掉
            // 几个 pt，这是上一轮把这一行判成「约 10」的原因）。应用此前取 `sm`(12)。
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Button {
                    pendingAction = .download
                } label: {
                    // 稿的主按钮图标是「托盘 + 下箭头」，不是 `arrow.down.circle`。
                    Label("下载并校验", systemImage: "tray.and.arrow.down")
                }
                .speechRailButton(isDownloadPrimary ? .primary : .secondary)
                .disabled(!canPrepareModels)
                .accessibilityHint("准备并校验所选档位的本机模型文件")

                Button {
                    pendingAction = .apply
                } label: {
                    // 稿上这个次按钮只有文字，没有图标（4x 帧里是 5 个字形簇）。
                    Text("应用此档位")
                }
                .speechRailButton(isReadyToApply ? .primary : .secondary)
                .disabled(!canApplyProfile)
                .accessibilityHint("把所选档位写进服务配置，并重启相关的后台组件")

                Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)

                // Figma 把磁盘事实放在动作行的右端：准备模型前先看有没有地方放。
                if let disk = model.modelStatus?.disk {
                    Text("磁盘：模型已用 \(formatBytes(disk.modelBytes)) · 可用 \(formatBytes(disk.freeBytes))")
                        .font(SpeechRailDesignTokens.Typography.callout)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            // 动作区只保留**一条**会改变判断的说明。此前这里叠着四条同色小字
            // （助手占用、缺说话人模型、没校验完、服务消息），字号字色都一样，
            // 读不出哪一条更急、哪一条已经被上一条解释过。结论面板已经说明了
            // 「差几个文件」，这里只补它没有说、且会挡住操作的那一条。
            if let guidance = actionGuidance {
                NoticeBar(
                    tone: guidance.tone == .critical ? .critical : .warning,
                    message: guidance.text
                )
            }
            // 长任务进度贴在触发它的那一行下面（§6.4「在触发页内联」），
            // 而不是沉到制品卡后面去。
            if let operation = activeModelOperation {
                let canRetry = operation.state == .interrupted
                    || operation.state == .failed
                    || operation.state == .cancelled
                OperationBar(
                    operation: operation,
                    actionTitle: operationActionTitle(for: operation)
                ) {
                    handleOperationAction(operation, canRetry: canRetry)
                }
                if operation.state == .interrupted {
                    Text("上一次准备被中断。本机不做断点续传：重试会重新核对已存在的文件，再从起点完成校验。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 按「先处理会挡路的、再处理需要解释的」排序，只返回最该先解决的那一条。
    /// 服务消息排第一：它多半是上一次操作失败的原因，其余几条都是它的下游。
    private var actionGuidance: (text: String, tone: StatusTone)? {
        if let message = model.message,
           !message.isEmpty,
           model.modelAvailability == .available
        {
            return (SpeechRailOperationMessagePresentation.text(message), .critical)
        }
        if assistantBlocksProfileSwitch {
            return (profileSwitchBlockedByAssistantText, .attention)
        }
        if !missingDiarizationKeys.isEmpty {
            return (
                "说话人区分还要补齐 \(missingDiarizationKeys.map(assetTitle(for:)).joined(separator: "、"))；补齐前这一项用不了。",
                .attention
            )
        }
        return nil
    }

    @ViewBuilder
    private var modelInspector: some View {
        DeveloperInspector {
            if let artifact = selectedArtifact {
                SectionHeading(title: artifact.variant.replacingOccurrences(of: "_", with: " "))
                LabeledContent("模型 ID", value: artifact.modelID)
                LabeledContent("family", value: artifact.family)
                LabeledContent("来源", value: "\(artifact.provider) · \(artifact.repository)")
                LabeledContent("revision", value: artifact.revision)
                LabeledContent("精度", value: quantizationText(for: artifact))
                LabeledContent("文件", value: "\(artifact.fileCount) 个 · \(formatBytes(artifact.sizeBytes))")
                LabeledContent(
                    "适用档位",
                    value: artifact.requiredBy.map { profileTitle(for: $0) }.joined(separator: "、")
                )
                if let status = status(for: artifact) {
                    Divider()
                    LabeledContent("存在状态", value: statusText(for: status))
                    LabeledContent("完整性", value: integrityText(for: status))
                }
                // 这一行说的是目标档位的声明，不是当前服务：它紧挨「当前服务档位」，
                // 不写清作用域会被读成服务现在的能力。
                LabeledContent(
                    "VoiceDesign 能力（按需模块）",
                    value: voiceDesignCapabilityText
                )
                LabeledContent(
                    "当前服务档位",
                    value: currentServiceProfile.map { profileTitle(for: $0) } ?? "运行态未读取"
                )
                LabeledContent(
                    "配置档位",
                    value: configuredProfile.map { profileTitle(for: $0) } ?? "未读取"
                )
                LabeledContent("使用状态", value: usage(for: artifact).text)
                if let operation = model.operation, let message = operation.message {
                    Divider()
                    LabeledContent("最近操作", value: operation.command.rawValue)
                    LabeledContent("操作状态", value: operation.state.rawValue)
                    LabeledContent(
                        "操作结果",
                        value: SpeechRailOperationMessagePresentation.text(message)
                    )
                }
            } else {
                SectionHeading(
                    title: "模型运行信息",
                    detail: "选中一个模型文件，看它的来源、锁定版本和本机校验结果。"
                )
                LabeledContent("目标档位", value: profileTitle(for: targetSelection))
                LabeledContent(
                    "当前服务档位",
                    value: currentServiceProfile.map { profileTitle(for: $0) } ?? "运行态未读取"
                )
                LabeledContent(
                    "配置档位",
                    value: configuredProfile.map { profileTitle(for: $0) } ?? "未读取"
                )
                LabeledContent("目录状态", value: model.modelAvailability == .available ? "已读取" : "未读取")
                // 这一档绑定的识别与合成权重。它们是制品 key（`asr-…` / `tts-…`），
                // 按 §4.2 属机器名，因此只在开发者详情里出现——页面上原来那两格
                // 「识别 / 合成」把它们摆在首屏，读起来像两个产品名。
                LabeledContent(
                    "这组档位的识别权重",
                    value: summary(for: targetSelection.asrSpec)?.asr ?? "未读取"
                )
                LabeledContent(
                    "这组档位的合成权重",
                    value: summary(for: targetSelection.ttsSpec)?.tts ?? "未读取"
                )
                LabeledContent(
                    "这组档位的音色克隆权重",
                    value: summary(for: targetSelection.ttsSpec)?.ttsBase ?? "未登记"
                )
                if let disk = model.modelStatus?.disk {
                    LabeledContent("模型占用", value: formatBytes(disk.modelBytes))
                    LabeledContent("可用空间", value: formatBytes(disk.freeBytes))
                }
                Text("开发者详情不会改变下载或应用行为。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
        }
    }

    private var selectedArtifact: ModelArtifactSnapshot? {
        guard let key = selectedArtifactKey else { return nil }
        return visibleArtifacts.first(where: { $0.key == key })
    }

    /// `/health` is the source of truth for the profile the running service is
    /// actually using. The XPC profile snapshot remains useful as the desired
    /// configuration, but must not be presented as a running-state fact.
    private var currentServiceProfile: SpecSelection? {
        guard model.healthFailure == nil else { return nil }
        return model.health?.selection
    }

    private var availableProfiles: [SpeechRailProfile] {
        model.modelCatalog?.selectableProfiles ?? []
    }

    /// 两项规格都必须由当前服务目录发布，组合才可下载/应用。
    private var targetSelectionIsPublished: Bool {
        availableProfiles.contains(targetSelection.asrSpec)
            && availableProfiles.contains(targetSelection.ttsSpec)
    }

    /// 两个规格各自的目录摘要；任一项缺失都只能报「映射未读取」。
    private var targetSummaries: [ProfileSummary]? {
        let asr = summary(for: targetSelection.asrSpec)
        let tts = summary(for: targetSelection.ttsSpec)
        guard let asr, let tts else { return nil }
        return [asr, tts]
    }

    /// 混合组合没有单一整档总量，用目录里两个规格的制品并集求和。
    private var targetSelectionCatalogBytes: Int64? {
        guard let artifacts = model.modelCatalog?.artifacts(for: targetSelection),
              !artifacts.isEmpty
        else {
            return nil
        }
        return artifacts.reduce(Int64.zero) { $0 + $1.sizeBytes }
    }

    /// 当前这组档位的模型总大小。两条轴同档时用档位摘要——它额外算上了单独安装、
    /// 不在档位表里的分人小模型；混搭时没有单一摘要，退回目录并集求和。
    private var targetSelectionTotalBytes: Int64? {
        if let quick = targetSelection.quickTier, let summary = summary(for: quick) {
            return summary.downloadBytes
        }
        return targetSelectionCatalogBytes
    }

    /// 把服务端的当前/配置选择回填到两条轴。此前同一件事要分两套控件（卡片 + 高级项），
    /// 混合组合还得「自动展开」才看得见；现在只有一对轴，回填就是赋值。
    private func adopt(_ selection: SpecSelection) {
        guard selection.isSelectable,
              availableProfiles.contains(selection.asrSpec),
              availableProfiles.contains(selection.ttsSpec)
        else {
            return
        }
        asrSpec = selection.asrSpec
        ttsSpec = selection.ttsSpec
    }

    private var configuredProfile: SpecSelection? {
        model.profile?.selection
    }

    private var visibleArtifacts: [ModelArtifactSnapshot] {
        model.modelCatalog?.artifacts(for: targetSelection) ?? []
    }

    /// The catalog reports total bytes per profile; this is only an upper bound
    /// because any artifact without a verified status is counted in full.
    private func remainingDownloadUpperBound(for selection: SpecSelection) -> Int64? {
        model.modelCatalog?.remainingDownloadUpperBound(
            for: selection,
            statuses: model.modelStatus
        )
    }

    private func remainingDownloadText(for selection: SpecSelection) -> String {
        guard let remainingBytes = remainingDownloadUpperBound(for: selection) else {
            return "需下载量待确认"
        }
        if remainingBytes == 0 {
            return "已全部下载并校验"
        }
        return "尚需下载不超过 \(formatBytes(remainingBytes))"
    }

    private var unmanagedArtifactStatuses: [ModelArtifactStatusSnapshot] {
        let catalogKeys = Set(model.modelCatalog?.artifacts.map(\.key) ?? [])
        var statusesByKey: [String: ModelArtifactStatusSnapshot] = [:]
        for status in model.modelStatus?.artifacts ?? [] {
            statusesByKey[status.key] = status
        }
        // The dedicated diarization lane is authoritative for its own keys.
        // Merge it here as well so detected CoreML/aligner assets cannot
        // disappear merely because they are not part of the generic lane.
        for status in model.modelStatus?.diarization ?? [] {
            statusesByKey[status.key] = status
        }
        return statusesByKey.values
            .filter { !catalogKeys.contains($0.key) }
            .sorted { $0.key < $1.key }
    }

    private var activeModelOperation: OperationSnapshot? {
        guard let operation = model.operation,
              operation.command == .modelPrepare || operation.command == .profileApply
        else { return nil }
        switch operation.state {
        case .accepted, .running, .interrupted, .failed, .cancelled:
            return operation
        case .committed:
            return nil
        }
    }

    /// 目录里标为按需、且没被当前档位表覆盖的音色创作制品。
    private var voiceDesignArtifacts: [ModelArtifactSnapshot] {
        let visibleKeys = Set(visibleArtifacts.map(\.key))
        return (model.modelCatalog?.artifacts ?? [])
            .filter { $0.isVoiceDesignAsset && !visibleKeys.contains($0.key) }
    }

    /// 目录里声明的**全部**音色创作制品（含已被某一档顺带覆盖的那些）。
    /// 判断「模型齐了没有」必须按全集算：只看没进档位表的那几条，会在它们恰好
    /// 全部被档位表覆盖时得出空集，从而误报就绪。
    private var allVoiceDesignArtifacts: [ModelArtifactSnapshot] {
        (model.modelCatalog?.artifacts ?? []).filter(\.isVoiceDesignAsset)
    }

    /// 分人的运行态来自 `/health`：目录只说文件在不在，说不了服务加载了没有。
    ///
    /// 取值用界面自己的话，不照抄服务端那句英文（本机 `/health` 实测就绪原文是
    /// `CoreML Sortformer FP16 is configured`）——它写给调用方看，不是给用户读的。
    /// 没就绪时也走同一套中文措辞（`SpeechRailDiarizationPresentation` 已把 code 翻成
    /// 「缺少对齐模型」这类界面语言），与服务状态页同源（§4.3）。
    private var diarizationRuntime: (text: String, tone: StatusTone)? {
        guard model.healthFailure == nil, let health = model.health else {
            return (text: "运行状态未读取", tone: .neutral)
        }
        if let status = health.diarization {
            return (
                text: SpeechRailDiarizationPresentation.text(status),
                tone: status.ready ? .healthy : .attention
            )
        }
        guard let ready = health.diarizationReady else { return nil }
        return (text: ready ? "已就绪" : "未就绪", tone: ready ? .healthy : .attention)
    }

    /// VAD 的运行态同样只来自 `/health`。
    private var vadRuntime: (text: String, tone: StatusTone)? {
        guard model.healthFailure == nil, let status = model.health?.realtimeVAD else {
            return nil
        }
        return (text: status.message, tone: status.ready ? .healthy : .attention)
    }

    private var vadEngineLabel: String {
        guard let status = model.health?.realtimeVAD else { return "未读取" }
        let resolved = status.resolvedEngine.isEmpty ? status.configuredEngine : status.resolvedEngine
        return resolved.isEmpty ? "未读取" : resolved
    }

    private var requiredDiarizationKeys: [String] {
        // 分人不再绑定档位: 目录用 `required_by: ["diarization"]` 声明这组按需制品,
        // 服务对它们另开一条检查通道。缺哪几个按目录算, 不再读档位摘要里那个
        // 服务早已不再下发的标志位——它恒为 false, 曾让这一节永远不出现。
        (model.modelCatalog?.diarizationArtifacts.map(\.key) ?? []).sorted()
    }

    private var canPrepareModels: Bool {
        model.modelAvailability == .available
            && !model.isBusy
            && !model.hasActiveMutation
            && !model.isRefreshingModels
            && targetSummaries != nil
            && targetSelectionIsPublished
            && !visibleArtifacts.isEmpty
            && model.controlAgentStatus.allowsMutation
            && model.controlPlaneMessage == nil
    }

    private var canApplyProfile: Bool {
        canPrepareModels && profileArtifactsVerified && !assistant.phase.isLive
    }

    /// 助手进行中时，用普通用户能懂的话说明为什么现在不能切档、下一步做什么。
    private var profileSwitchBlockedByAssistantText: String {
        "助手正在进行中（\(assistant.phase.title)）。先结束这一轮，或点「停止」把助手停下来，再应用档位。"
    }

    private var assistantBlocksProfileSwitch: Bool {
        assistant.phase.isLive
    }

    private var profileArtifactsVerified: Bool {
        targetSummaries != nil
            && !visibleArtifacts.isEmpty
            && visibleArtifacts.allSatisfy { isVerified(status(for: $0)) }
            && profileDiarizationVerified
    }

    private var profileDiarizationVerified: Bool {
        missingDiarizationKeys.isEmpty
    }

    private var modelReadinessPresentation: ModelReadinessPresentation {
        // 行文里一律用短名（§4.2）：完整标题「品质 · 日常使用」是给卡片头用的，
        // 塞进一句结论会读成两个并列事实。
        return ModelReadinessPresenter.presentation(
            state: modelReadinessState,
            target: SpeechRailProfilePresentation.shortTitle(targetSelection),
            running: currentServiceProfile.map { SpeechRailProfilePresentation.shortTitle($0) },
            remainingDownloadText: remainingDownloadText(for: targetSelection)
        )
    }

    /// 判定的**顺序**是这一页最容易被后续改动悄悄破坏的约定，因此它留在页面侧
    /// 读得到的地方，而「该说哪句话」放在可测试的 `ModelReadinessPresenter`。
    ///
    /// 顺序本身：读不出目录 → 这一档没登记文件 → 有操作在跑 → 还没校验完 →
    /// 正在用且配置一致 → 正在用但配置没读到 → 运行档位没读到 → 可以切换。
    private var modelReadinessState: ModelReadinessState {
        guard targetSummaries != nil else {
            return .catalogUnreadable
        }
        guard !visibleArtifacts.isEmpty else {
            return .noArtifactsRegistered
        }
        if let operation = activeModelOperation,
           operation.state == .accepted || operation.state == .running
        {
            return operation.command == .profileApply ? .applying : .preparing
        }
        guard profileArtifactsVerified else {
            return .pending(count: pendingArtifactCount)
        }

        if currentServiceProfile == targetSelection,
           configuredProfile == targetSelection
        {
            return .inUseAndConfigured
        }
        if currentServiceProfile == targetSelection {
            return .inUseConfigurationUnread
        }
        if currentServiceProfile == nil {
            return .readyRuntimeUnread
        }
        return .readyToSwitch
    }

    /// 这一档还差几个文件：档位表里没校验通过的，加上说话人区分那一组按需模型。
    /// 两组都不绑定档位但都挡着「应用此档位」，所以合成一个数报给用户。
    private var pendingArtifactCount: Int {
        let pending = visibleArtifacts.filter { !isVerified(status(for: $0)) }.count
        return pending + missingDiarizationKeys.count
    }

    private var missingDiarizationKeys: [String] {
        requiredDiarizationKeys.filter { !isVerified(status(forKey: $0)) }
    }

    private func assetTitle(for key: String) -> String {
        key == "diarization-coreml" ? "谁在说话用的小模型" : key
    }

    private func summary(for profile: SpeechRailProfile) -> ProfileSummary? {
        model.modelCatalog?.profiles.first(where: { $0.id == profile })
    }

    /// VoiceDesign 与档位无关: 目录里那份按需设计制品决定能力, 不随所选档位变化。
    private var voiceDesignCapabilityText: String {
        guard let catalog = model.modelCatalog else { return "未读取" }
        return catalog.hasVoiceDesignArtifact ? "支持候选预览" : "不支持候选预览"
    }

    private func status(for artifact: ModelArtifactSnapshot) -> ModelArtifactStatusSnapshot? {
        status(forKey: artifact.key)
    }

    private func status(forKey key: String) -> ModelArtifactStatusSnapshot? {
        model.modelStatus?.status(for: key)
    }

    private func usage(for artifact: ModelArtifactSnapshot) -> ModelArtifactUsagePresentation {
        usage(forKey: artifact.key)
    }

    private func usage(forKey key: String) -> ModelArtifactUsagePresentation {
        guard model.healthFailure == nil else {
            return ModelArtifactUsagePresentation(
                text: "运行状态读取失败 · 当前使用未确认",
                tone: .critical
            )
        }
        guard let health = model.health else {
            return ModelArtifactUsagePresentation(
                text: "运行状态未读取",
                tone: .neutral
            )
        }
        guard let runtimeSelection = health.selection else {
            return ModelArtifactUsagePresentation(
                text: "运行档位未读取",
                tone: .neutral
            )
        }
        if let configuredProfile, configuredProfile != runtimeSelection {
            return ModelArtifactUsagePresentation(
                text: "配置档位与运行时不一致 · 当前服务未确认使用",
                tone: .critical
            )
        }
        let asrSummary = summary(for: runtimeSelection.asrSpec)
        let ttsSummary = summary(for: runtimeSelection.ttsSpec)
        let asrBinding = asrSummary?.asr
        let ttsBinding = ttsSummary?.tts
        let cloneBinding = ttsSummary?.ttsBase
        let alignerBinding = asrSummary?.aligner ?? ttsSummary?.aligner
        let diarizationConfigured = (asrSummary?.diarization ?? false)
            || (ttsSummary?.diarization ?? false)
        guard asrBinding != nil || ttsBinding != nil else {
            return ModelArtifactUsagePresentation(
                text: "当前服务档位模型映射未读取",
                tone: .neutral
            )
        }
        guard let artifactStatus = status(forKey: key) else {
            return ModelArtifactUsagePresentation(
                text: "配置引用 · 存在状态未读取",
                tone: .critical
            )
        }
        guard isVerified(artifactStatus) else {
            return ModelArtifactUsagePresentation(
                text: "配置里引用了它 · 还没校验",
                tone: .attention
            )
        }

        if key == asrBinding {
            return runtimeUsage(
                label: "当前服务 · " + profileTitle(for: runtimeSelection) + " · ASR",
                ready: health.asrReady,
                state: health.asrState
            )
        }
        if key == ttsBinding {
            return runtimeUsage(
                label: "当前服务 · " + profileTitle(for: runtimeSelection) + " · TTS",
                ready: health.ttsReady,
                state: health.ttsState
            )
        }
        if key == cloneBinding {
            return cloneRuntimeUsage(
                label: "当前服务 · " + profileTitle(for: runtimeSelection) + " · 克隆 TTS",
                health: health
            )
        }
        if diarizationConfigured, key == alignerBinding || key == "diarization-coreml" {
            let ready = health.diarization?.ready ?? health.diarizationReady
            guard let ready else {
                return ModelArtifactUsagePresentation(
                    text: "当前谁在说话 · 状态未读取",
                    tone: .neutral
                )
            }
            return ModelArtifactUsagePresentation(
                text: ready ? "当前谁在说话 · 已就绪" : "当前谁在说话 · 未就绪",
                tone: ready ? .healthy : .critical
            )
        }
        return ModelArtifactUsagePresentation(
            text: "目标档位未应用；当前服务未使用",
            tone: .neutral
        )
    }

    private func cloneRuntimeUsage(
        label: String,
        health: HealthSnapshot
    ) -> ModelArtifactUsagePresentation {
        guard let ttsReady = health.ttsReady else {
            return ModelArtifactUsagePresentation(
                text: "\(label) · TTS 就绪状态未读取",
                tone: .neutral
            )
        }
        guard ttsReady else {
            return ModelArtifactUsagePresentation(
                text: "\(label) · 服务 TTS 未就绪",
                tone: .critical
            )
        }

        guard let lifecycle = health.ttsLifecycle else {
                return ModelArtifactUsagePresentation(
                text: "\(label) · 已验证；是否留在内存里没有读到",
                    tone: .neutral
                )
            }

            let hasWarmStateSignal = lifecycle.warmCapability != nil
                || lifecycle.warmCapabilities != nil
            guard hasWarmStateSignal else {
                return ModelArtifactUsagePresentation(
                text: "\(label) · 已验证；是否留在内存里没有读到",
                    tone: .neutral
                )
            }

        let warmCapabilities = lifecycle.warmCapabilities ?? []
        let isWarm = warmCapabilities.contains("voice_clone")
            || lifecycle.warmCapability == "voice_clone"
            || lifecycle.warmCapability == "both"
            if isWarm {
                return ModelArtifactUsagePresentation(
                text: "\(label) · 现在就在内存里",
                    tone: .healthy
                )
            }
            return ModelArtifactUsagePresentation(
            text: "\(label) · 已验证，用到时才加载",
                tone: .attention
            )
    }

    private func runtimeUsage(
        label: String,
        ready: Bool?,
        state: String?
    ) -> ModelArtifactUsagePresentation {
        guard let ready else {
            return ModelArtifactUsagePresentation(
                text: "\(label) · 就绪状态未读取",
                tone: .neutral
            )
        }
        guard ready else {
            return ModelArtifactUsagePresentation(
                text: "\(label) · 服务未就绪",
                tone: .critical
            )
        }
        guard let state else {
            return ModelArtifactUsagePresentation(
                text: "\(label) · 生命周期未读取",
                tone: .neutral
            )
        }
        let normalized = state.lowercased()
        let text: String
        let tone: StatusTone
        switch normalized {
        case "active":
            text = "\(label) · 运行中"
            tone = .healthy
        case "warm_standby":
            text = "\(label) · 温待机"
            tone = .healthy
        case "cold_evicted":
            text = "\(label) · 空闲已释放（请求时加载）"
            tone = .attention
        case "inactive", "stopped":
            text = "\(label) · 未运行"
            tone = .attention
        default:
            text = "\(label) · \(SpeechRailRuntimeStatePresentation.text(state))"
            tone = .neutral
        }
        return ModelArtifactUsagePresentation(text: text, tone: tone)
    }

    private func isVerified(_ status: ModelArtifactStatusSnapshot?) -> Bool {
        status?.state == .verified && status?.integrity == .verified
    }

    private func operationActionTitle(for operation: OperationSnapshot) -> String? {
        switch operation.command {
        case .modelPrepare:
            if operation.phase?.lowercased() == "cancelling" {
                return nil
            }
            return operation.state == .accepted || operation.state == .running
                ? "停止下载"
                : "重新下载并校验"
        case .profileApply:
            return operation.state == .accepted || operation.state == .running
                ? nil
                : "重新应用档位"
        default:
            return nil
        }
    }

    private func handleOperationAction(_ operation: OperationSnapshot, canRetry: Bool) {
        if canRetry {
            pendingAction = operation.command == .profileApply ? .apply : .download
        } else if operation.command == .modelPrepare {
            Task { await model.cancelCurrentOperation() }
        }
    }

    private func selectFirstArtifactIfNeeded() {
        guard let selectedArtifactKey,
              visibleArtifacts.contains(where: { $0.key == selectedArtifactKey })
        else {
            selectedArtifactKey = visibleArtifacts.first?.key
            return
        }
    }

    private func selectAvailableProfileIfNeeded() {
        // 两条轴都只能落在服务目录实际发布的档位上，否则回到第一个可用项。
        if let first = availableProfiles.first {
            if !availableProfiles.contains(asrSpec) { asrSpec = first }
            if !availableProfiles.contains(ttsSpec) { ttsSpec = first }
        }
    }

    private var isConfirmingAction: Binding<Bool> {
        Binding(
            get: { pendingAction != nil },
            set: { isPresented in
                if !isPresented { pendingAction = nil }
            }
        )
    }

    private var confirmationTitle: String {
        guard let pendingAction else { return "确认操作" }
        switch pendingAction {
        case .download:
            return "确认下载并校验所选模型？"
        case .apply:
            return "确认应用该模型组合？"
        }
    }

    private var confirmationMessage: String {
        guard let pendingAction else { return "" }
        switch pendingAction {
        case .download:
            return downloadConfirmationMessage
        case .apply:
            return applyConfirmationMessage
        }
    }

    private var applyConfirmationMessage: String {
        let current = currentServiceProfile.map { profileTitle(for: $0) } ?? "运行态未读取"
        var details: [String] = []
        if let sizeBytes = targetSelectionTotalBytes {
            details.append("模型总大小约 \(formatBytes(sizeBytes))")
        }
        if let freeBytes = model.modelStatus?.disk.freeBytes {
            details.append("磁盘可用空间 \(formatBytes(freeBytes))")
        }
        details.append("已校验模型不会重复下载，其他档位模型保留不删")
        if targetSelection.asrSpec == .reference || targetSelection.ttsSpec == .reference {
            details.append("更高精度权重将占用更多显存/内存")
        }
        return "目标组合：\(combinationSummary)。当前服务运行：\(current)。\n"
            + "应用将更新服务配置并重启后台引擎，过程约需数秒。"
            + details.joined(separator: "；")
            + "。"
    }

    private var downloadConfirmationMessage: String {
        let size = targetSelectionTotalBytes.map(formatBytes)
        let remaining = remainingDownloadText(for: targetSelection)
        let free = model.modelStatus.map { formatBytes($0.disk.freeBytes) }
        var details: [String] = []
        if let size {
            details.append("模型总大小约 \(size)")
        }
        details.append(remaining)
        if let free {
            details.append("磁盘可用空间 \(free)")
        }
        details.append("已校验文件不会重下，其他档位模型保留不删")
        details.append("仅下载并校验本地文件，不会重启服务，也不会上传任何数据")
        return "目标组合：\(combinationSummary)。\(details.joined(separator: "；"))。"
    }

    private func actionTitle(for action: ModelAction) -> String {
        return switch action {
        case .download:
            "下载并校验"
        case .apply:
            "应用此档位"
        }
    }

    private func profileTitle(for profile: SpeechRailProfile) -> String {
        SpeechRailProfilePresentation.title(profile)
    }

    private func profileTitle(for selection: SpecSelection) -> String {
        SpeechRailProfilePresentation.title(selection)
    }

    private func profilePurpose(for profile: SpeechRailProfile) -> String {
        SpeechRailProfilePresentation.purpose(profile)
    }

    /// 开发者详情里的精度：与表格同一件事、同一句话开头（位数），后面才补上「怎么做到的」——
    /// 量化制品写格式与分组，未量化制品写权重本身的数值格式。目录里 `bits: null` /
    /// `format: none` 是「没做量化」，把字段原样念成「未声明位宽 · none」会被读成读取失败
    /// （用户 2026-09-22 / 2026-09-23：模型信息要清晰、精度拉齐到同一维度）。
    private func quantizationText(for artifact: ModelArtifactSnapshot) -> String {
        let quantization = artifact.quantization
        let width = ArtifactQuantizationPresentation.columnText(quantization)
        guard ArtifactQuantizationPresentation.isQuantized(quantization) else {
            guard let dtype = quantization.dtype else {
                // 旧服务不送 dtype：只读得到「没做量化」，位数说不出就不编。
                return "未量化 · 位数未读取"
            }
            return "\(width) · \(dtype) · 未量化"
        }
        let group = quantization.groupSize.map { " · group \($0)" } ?? ""
        return "\(width) · \(quantization.format)\(group)"
    }

    private func statusText(for status: ModelArtifactStatusSnapshot) -> String {
        ModelArtifactStatusPresentation(status: status).summary
    }

    private func integrityText(for status: ModelArtifactStatusSnapshot) -> String {
        return switch status.integrity {
        case .verified:
            "SHA-256 已匹配"
        case .mismatch:
            "SHA-256 不匹配"
        case .notChecked:
            "尚未校验"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        String(format: "%.1f GiB", Double(bytes) / 1_073_741_824)
    }
}

private enum ModelAction {
    case download
    case apply
}

/// 档位规格行：标签列固定，取值右对齐（Figma `kvRow` 的 76pt 标签列）。
private struct ProfileSpec: Identifiable {
    let label: String
    let value: String

    var id: String { label }
}

/// Figma `Profile Card`：档位名 + 「当前使用」胶囊、一句适用场景、发丝线，再接三行
/// 规格。选中态用底色加轨道色描边，不用 2pt 粗框 —— 粗框读起来像错误态。
private struct ProfileChoiceCard: View {
    let profile: SpeechRailProfile
    let sizeText: String?
    let specs: [ProfileSpec]
    let isSelected: Bool
    let isRunning: Bool
    let partialSelectionBadge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Text(SpeechRailProfilePresentation.shortTitle(profile))
                        .font(SpeechRailDesignTokens.Typography.windowTitle)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                        .lineLimit(1)

                    Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)

                    if isRunning {
                        StatusPill(tone: .healthy, label: "当前使用")
                    } else if let partialSelectionBadge {
                        StatusPill(tone: .neutral, label: partialSelectionBadge)
                    }
                }

                Text(profilePurpose)
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                // 稿 `Profile Card` 的 `spec` 是 VERTICAL / gap 6，`kvRow` 取 `Callout`
                // （12pt，行盒 17.4）→ 行距 23.4。4x 帧 `▸ 模型.png` 实测三行 ink 起点
                // 221.75 / 245.75 / 268（行距 24 / 22.25）。系统 `callout` 行盒是 15，
                // 用间距补回同一行距：15 + 8 = 23（残差 0.4），因此这里取 `xs` 而不是
                // 稿的 6（应用的 4pt 节奏里没有 6，`micro`(4) 会让行距只剩 19）。
                VStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    ForEach(specs) { spec in
                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Text(spec.label)
                                .font(SpeechRailDesignTokens.Typography.callout)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                .frame(
                                    width: SpeechRailDesignTokens.Layout.modelProfileSpecLabelWidth,
                                    alignment: .leading
                                )
                            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                            Text(spec.value)
                                .font(SpeechRailDesignTokens.Typography.callout)
                                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }

                if let sizeText {
                    Text(sizeText)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SpeechRailDesignTokens.Spacing.md)
            // 卡片这层只**声明形状**（子层的 `.concentric` 靠它推导）；底色交给下面的
            // 交互样式：样式把底色与悬停/按压色叠在同一个背景层里，卡片自己再画一层
            // 不透明底色会把悬停反馈整个盖住——样式那层填色只在卡片左右各露 8pt，
            // 读起来是一条侧向晕边而不是悬停态（REDESIGN-SPEC §11.6 第五十 / 五十二轮）。
            .containerShape(SpeechRailDesignTokens.Corner.containerShape)
            .overlay {
                // Only the active profile is outlined; an idle profile card is a
                // static surface and separates by fill alone (§5.2, Figma
                // `Profile Card` 的 Default 变体同样无描边). 选中描边与其他选中面
                // 同为 1pt：粗细不再充当状态信号，只由填充与「当前使用」胶囊承担。
                if isSelected {
                    SpeechRailDesignTokens.Corner.containerShape
                        .stroke(
                            SpeechRailDesignTokens.Color.rail,
                            lineWidth: SpeechRailDesignTokens.Stroke.strong
                        )
                }
            }
        }
        // 卡片的底色与状态色都在这里：`horizontalInset: 0` 让卡片**铺满自己的格位**，
        // 于是相邻卡片的可见间隔回到 `HStack` 的 `Spacing.sm`(12)——与帧一致；
        // 此前样式自带左右各 8pt，间隔被撑到 27.5pt（帧 12pt）。
        .speechRailInteractiveButtonStyle(
            fillsAvailableWidth: true,
            horizontalInset: 0,
            baseFill: isSelected
                ? SpeechRailDesignTokens.Surface.selectedFill
                : SpeechRailDesignTokens.Color.field,
            corner: .container
        )
        .accessibilityIdentifier(profile.rawValue)
        .accessibilityLabel(profileTitle)
        .accessibilityValue(isSelected ? "已选择" : (partialSelectionBadge ?? "未选择"))
    }

    private var profileTitle: String {
        SpeechRailProfilePresentation.title(profile)
    }

    private var profilePurpose: String {
        // 一份文案只写在一处：档位名、短名与这句话都在 `SpeechRailProfilePresentation`。
        SpeechRailProfilePresentation.purpose(profile)
    }

}

private struct ModelArtifactUsagePresentation {
    let text: String
    let tone: StatusTone
}

private struct ModelArtifactStatusPresentation {
    let systemImage: String
    let color: Color
    let title: String
    let detail: String

    init(status: ModelArtifactStatusSnapshot?) {
        guard let status else {
            systemImage = "questionmark.circle"
            color = SpeechRailDesignTokens.Color.inkSecondary
            title = "未读取"
            detail = "尚未读取本机文件状态"
            return
        }

        switch status.state {
        case .verified where status.integrity == .verified:
            systemImage = "checkmark.seal.fill"
            color = SpeechRailDesignTokens.Color.ready
            title = "已验证"
            detail = "\(status.verifiedFileCount)/\(status.totalFileCount) 个文件 · SHA-256 已匹配"
        case .verified:
            systemImage = "xmark.octagon.fill"
            color = SpeechRailDesignTokens.Color.critical
            title = "完整性失败"
            detail = "文件存在 · \(status.verifiedFileCount)/\(status.totalFileCount) 个文件 · SHA-256 不匹配"
        case .notDownloaded:
            systemImage = "arrow.down.circle"
            color = SpeechRailDesignTokens.Color.attention
            title = "未下载"
            detail = "未检测到已校验文件 · 需要下载并校验"
        case .downloading:
            systemImage = "arrow.down.circle.fill"
            color = SpeechRailDesignTokens.Color.rail
            title = "下载中"
            detail = "已校验 \(status.verifiedFileCount)/\(status.totalFileCount) 个文件 · 等待操作完成"
        case .invalid:
            systemImage = "exclamationmark.octagon.fill"
            color = SpeechRailDesignTokens.Color.critical
            title = "校验失败"
            detail = "文件存在但与锁定 revision 不一致 · 需要重新准备"
        case .unknown:
            systemImage = "questionmark.circle"
            color = SpeechRailDesignTokens.Color.inkSecondary
            title = "状态未知"
            detail = "无法确认本机文件状态 · 请刷新或打开诊断"
        }
    }

    var summary: String {
        "\(title) · \(detail)"
    }
}

/// 稿 `artifacts` 的列几何：`COLS = [440, 200, 140]` + 校验列吃掉余量，**列间距 0**
/// （列自己留白）。4x 帧实测列沿：制品 280.5、量化 720.5、文件右沿 1060.5、
/// 校验右沿 1400.5 —— 应用此前是「弹性制品 + 84 / 64 / 120 挤在右侧」，最右一列
/// 的位置与稿差约 250pt（REDESIGN-SPEC §11.6 第二十一轮）。
private struct ArtifactColumnMetrics {
    let artifact: CGFloat
    let artifactMinimum: CGFloat
    let quantization: CGFloat
    let file: CGFloat

    /// 稿的原值（1440 宽窗口下与帧列沿逐列重合）。
    static let frame = ArtifactColumnMetrics(
        artifact: 440,
        artifactMinimum: 440,
        quantization: 200,
        file: 140
    )

    /// 最小窗口（1120）下列内容区只剩约 808pt，按同一比例收窄三列，校验列继续吃余量。
    static let compact = ArtifactColumnMetrics(
        artifact: 440,
        artifactMinimum: 220,
        quantization: 140,
        file: 100
    )
}

/// 列头与数据行共用同一套列几何：先按稿的原值排，排不下再退到收窄版。
private struct ArtifactColumnGrid<Content: View>: View {
    private let content: (ArtifactColumnMetrics) -> Content

    init(@ViewBuilder content: @escaping (ArtifactColumnMetrics) -> Content) {
        self.content = content
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content(.frame)
            content(.compact)
        }
    }
}

/// 权重精度在本页只有一套说法：**位数**。量化制品读 `bits`，未量化制品读权重本身的
/// 数值格式（`bf16` / `fp16` / `fp32` → 16 / 16 / 32 位），两者回答的是同一个问题——
/// 每份权重是多少位——所以这一列里每一行的读法都一样，用户不必先懂「量化 / 未量化」
/// 这套内部分法（用户 2026-09-23：未量化是不是也有位数、统一文案）。
/// 目录里 `bits: null` / `format: none` 说的是**没有做量化**，不是「读不出来」；
/// 而 `mlx`、`group 64`、`bf16` 这些格式名只解释「怎么做到的」，留在开发者详情里。
private enum ArtifactQuantizationPresentation {
    /// 未量化制品的数值格式对应的位数。别按字面猜：`bf16` 与 `fp16` 都是 16 位，
    /// `fp32` 是 32 位。
    private static let dtypeBits: [String: Int] = ["bf16": 16, "fp16": 16, "fp32": 32]

    static func isQuantized(_ quantization: ModelQuantizationSnapshot) -> Bool {
        quantization.bits != nil && quantization.format.lowercased() != "none"
    }

    /// 表格列里的取值：`8-bit` / `16-bit`。位数读不出来时如实写「未读取」，不编。
    static func columnText(_ quantization: ModelQuantizationSnapshot) -> String {
        bitWidth(quantization).map { "\($0)-bit" } ?? "未读取"
    }

    /// 同一件事朗读出来要成句：`8-bit`、`16-bit` 在朗读里都不成句。
    static func accessibilityText(_ quantization: ModelQuantizationSnapshot) -> String {
        bitWidth(quantization).map { "精度 \($0) 位" } ?? "精度未读取"
    }

    /// 位数只有一个来源：量化制品是 `bits`，未量化制品是 `dtype`（目录里两者互斥）。
    static func bitWidth(_ quantization: ModelQuantizationSnapshot) -> Int? {
        if isQuantized(quantization) { return quantization.bits }
        guard let dtype = quantization.dtype else { return nil }
        return dtypeBits[dtype.lowercased()]
    }
}

private struct ArtifactChoiceRow: View {
    let artifact: ModelArtifactSnapshot
    let status: ModelArtifactStatusSnapshot?
    let selected: Bool

    var body: some View {
        // 与列头同一套列网格，否则行与列头会各差几 pt。
        ArtifactColumnGrid { metrics in
            HStack(spacing: 0) {
                Text(artifact.key)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(
                        minWidth: metrics.artifactMinimum,
                        maxWidth: metrics.artifact,
                        alignment: .leading
                    )

                Text(quantizationColumnText)
                    // 稿的制品表单元格是 `Callout`(12)（脚本 `cell/v`）
                    .font(SpeechRailDesignTokens.Typography.technicalValue)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(1)
                    .frame(width: metrics.quantization, alignment: .leading)

                Text(String(artifact.fileCount))
                    .font(SpeechRailDesignTokens.Typography.technicalValue)
                    .monospacedDigit()
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(1)
                    .frame(width: metrics.file, alignment: .trailing)
                    .accessibilityLabel("\(artifact.fileCount) 个文件")

                Label(statusPresentation.title, systemImage: statusPresentation.systemImage)
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(statusPresentation.color)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 稿的制品表行是 padX 18 / padY 11 + 一行 `Callout`(17.4) = 39.4pt；应用的行高
        // 16，纵向取 `sm`(12) 补回同一档带高。REDESIGN-SPEC §11.6 第二十一轮。
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .background(
            selected ? SpeechRailDesignTokens.Surface.selectedFill : Color.clear,
            in: SpeechRailDesignTokens.Corner.nestedShape
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(artifact.key)
        .accessibilityValue(
            "\(modelSourceText)，\(ArtifactQuantizationPresentation.accessibilityText(artifact.quantization))，\(artifact.fileCount) 个文件，\(statusPresentation.summary)"
        )
        .accessibilityHint("在开发者详情中查看模型来源和校验信息")
    }

    /// 表格「精度」列按位数读：量化制品看 `bits`，未量化制品把权重格式换算成位数。
    /// 列里不写 `mlx`、`group 64`、`bf16` 这类格式名（它们在开发者详情里）。
    private var quantizationColumnText: String {
        ArtifactQuantizationPresentation.columnText(artifact.quantization)
    }

    /// Model IDs can carry a local snapshot path. Keep the logical
    /// `<provider> · <identifier>` pair and drop the path prefix, because an
    /// absolute model path must never reach the UI (REDESIGN-SPEC §7.7).
    private var modelSourceText: String {
        var identifier = artifact.modelID
        if identifier.hasPrefix("/") || identifier.hasPrefix("~") {
            identifier = identifier
                .split(separator: "/")
                .suffix(2)
                .joined(separator: "/")
        }
        return artifact.provider.isEmpty ? identifier : "\(artifact.provider) · \(identifier)"
    }


    private var statusPresentation: ModelArtifactStatusPresentation {
        ModelArtifactStatusPresentation(status: status)
    }
}

/// 按需能力的一行。左侧说**这一项是干什么的**，右侧一个胶囊说**现在是什么状态**。
///
/// 「模型齐了」和「服务正在用」是两件事：前者来自目录与本机校验，后者来自
/// `/health`。所以状态胶囊只回答前者，运行态另起一行，不合成一句看起来更
/// 肯定、实际没有证据的话（REDESIGN-SPEC §4.3「不能撒谎」）。
private struct OnDemandCapability: Identifiable {
    let id: String
    let title: String
    let detail: String
    let state: String
    let tone: StatusTone
    /// 服务自己给的运行状态；没有这条信号时为 nil，行里就不出现这一行。
    let runtime: String?
}

private struct OnDemandCapabilityRow: View {
    let capability: OnDemandCapability

    var body: some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(capability.title)
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(1)
                Text(capability.detail)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let runtime = capability.runtime {
                    Text(runtime)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            StatusPill(tone: capability.tone, label: capability.state)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(capability.title)
        .accessibilityValue(
            ([capability.detail, capability.state] + [capability.runtime].compactMap { $0 })
                .joined(separator: "，")
        )
    }
}

private struct UnmanagedArtifactRow: View {
    let status: ModelArtifactStatusSnapshot

    var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            Image(systemName: statusPresentation.systemImage)
                .foregroundStyle(statusPresentation.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(status.key)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("存在：\(statusPresentation.summary)")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(statusPresentation.color)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text("使用：当前 catalog 未登记")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, SpeechRailDesignTokens.List.rowVerticalPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.key)
        .accessibilityValue("存在：\(statusPresentation.summary)，使用：当前 catalog 未登记")
    }

    private var statusPresentation: ModelArtifactStatusPresentation {
        ModelArtifactStatusPresentation(status: status)
    }
}
