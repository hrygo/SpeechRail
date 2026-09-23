import SpeechRailControlKit
import SwiftUI

public struct ModelManagementView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    /// 开发者详情是全 App 的一个偏好（View ▸ 显示/隐藏开发者详情 ⌘⌥I）。
    @AppStorage("speechrail.showDeveloperDetails") private var showInspector = false
    @State private var selectedProfile: SpeechRailProfile = .balanced
    @State private var selectedArtifactKey: String?
    @State private var pendingAction: ModelAction?

    public init() {}

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
                            await model.prepareModels(for: selectedProfile)
                        case .apply:
                            await model.execute(.profileApply, profile: selectedProfile)
                        }
                    }
                }
            }
            Button("取消", role: .cancel) {
                pendingAction = nil
            }
        }
        .task {
            model.refreshControlAgentStatus()
            await model.refreshModelsAndHealth()
            if let active = model.operation?.profile ?? model.profile?.preset {
                selectedProfile = active
            }
            selectFirstArtifactIfNeeded()
        }
        .onChange(of: model.profile?.preset) { _, value in
            if let value { selectedProfile = value }
        }
        .onChange(of: model.operation?.profile) { _, value in
            if let value, availableProfiles.contains(value) {
                selectedProfile = value
            }
        }
        .onChange(of: selectedProfile) { _, _ in
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
                actionTitle: "重新读取"
            ) {
                Task { await model.refreshModels() }
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
            profileCards
            actionSection
            selectedProfilePanel
        }
    }

    /// 只显示服务目录实际发布的档位；宽度允许时单行展示，空间不足时改为两列。
    @ViewBuilder
    private var profileCards: some View {
        let profiles = availableProfiles
        let cardMinimumWidth = SpeechRailDesignTokens.Layout.modelProfileCardMinimumWidth
        let rowMinimumWidth = profiles.count == 4
            ? SpeechRailDesignTokens.Layout.modelProfileCardsFourColumnBreakpoint
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
            ProfileChoiceCard(
                profile: profile,
                sizeText: summary(for: profile).map {
                    "该档模型总大小 \(formatBytes($0.downloadBytes))"
                },
                specs: profileSpecs(for: profile),
                isSelected: selectedProfile == profile,
                isRunning: currentServiceProfile == profile
            ) {
                selectedProfile = profile
            }
            .frame(minWidth: minimumWidth, maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 三行规格只呈现服务目录声明的能力和本档效果验证状态。
    private func profileSpecs(for profile: SpeechRailProfile) -> [ProfileSpec] {
        let summary = summary(for: profile)
        return [
            ProfileSpec(
                label: "谁在说话",
                value: summary.map { $0.diarization ? "支持" : "不支持" } ?? "未读取"
            ),
            ProfileSpec(label: "音色创作", value: voiceCreationSupport(for: summary)),
            ProfileSpec(label: "识别与配音", value: profile == .extreme ? "效果待验证" : "已有档位"),
        ]
    }

    private func voiceCreationSupport(for summary: ProfileSummary?) -> String {
        guard let summary else { return "未读取" }
        guard let catalog = model.modelCatalog,
              catalog.artifacts.contains(where: {
                  $0.key == summary.tts && $0.variant == "voice_design"
              })
        else {
            return "不支持"
        }
        let supportsClone = summary.ttsClone.flatMap { cloneKey in
            model.modelCatalog?.artifacts.first(where: { $0.key == cloneKey && $0.variant == "base" })
        } != nil
        return supportsClone ? "支持（含克隆）" : "支持"
    }

    private var selectedProfilePanel: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.lg) {
            profileContext
            profileFacts
            modelReadinessSummary
            Divider()
            artifactSection
            if !unmanagedArtifactStatuses.isEmpty {
                Divider()
                unmanagedArtifactSection
            }
            if !independentDiarizationKeys.isEmpty {
                Divider()
                diarizationSection
            }
        }
        .padding(SpeechRailDesignTokens.Layout.cardInset)
        .speechRailContentSurface()
    }

    private var profileContext: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.md) {
            profileContextValue(
                title: "目标档位",
                value: profileTitle(for: selectedProfile),
                tone: .neutral
            )
            Divider()
                .frame(height: SpeechRailDesignTokens.Layout.compactDividerHeight)
            profileContextValue(
                title: "当前服务",
                value: currentServiceProfile.map { profileTitle(for: $0) } ?? "运行态未读取",
                tone: currentServiceProfile == selectedProfile ? .healthy : .attention
            )
            Divider()
                .frame(height: SpeechRailDesignTokens.Layout.compactDividerHeight)
            profileContextValue(
                title: "配置档位",
                value: configuredProfile.map { profileTitle(for: $0) } ?? "未配置",
                tone: configuredProfile == selectedProfile ? .healthy : .attention
            )
            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("模型档位上下文")
        .accessibilityValue(profileContextAccessibilityValue)
    }

    private func profileContextValue(
        title: String,
        value: String,
        tone: StatusTone
    ) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Text(title)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            Text(value)
                // 稿的 `kvRow`：键与值都是 `Callout`（12pt Regular）。
                .font(SpeechRailDesignTokens.Typography.callout)
                .foregroundStyle(tone.color)
                .lineLimit(1)
        }
    }

    private var profileFacts: some View {
        HStack(spacing: 0) {
            fact(
                "档位总大小",
                value: summary(for: selectedProfile).map { formatBytes($0.downloadBytes) } ?? "未读取"
            )
            Divider()
                .frame(height: SpeechRailDesignTokens.Layout.compactDividerHeight)
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            fact("识别", value: summary(for: selectedProfile)?.asr ?? "未读取")
            Divider()
                .frame(height: SpeechRailDesignTokens.Layout.compactDividerHeight)
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            fact("合成", value: summary(for: selectedProfile)?.tts ?? "未读取")
            Divider()
                .frame(height: SpeechRailDesignTokens.Layout.compactDividerHeight)
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            // 这一行的三格是「这一档要用哪几个模型」（取值是制品 key），标题就用页面上
            // 的名字；`VoiceDesign` 只留在开发者详情里（用户 2026-09-19）。
            fact("语音设计", value: voiceDesignCapability(for: selectedProfile))
            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
        }
    }

    private func fact(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Text(title)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            Text(value)
                .font(SpeechRailDesignTokens.Typography.technical)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineLimit(1)
        }
        .frame(minWidth: SpeechRailDesignTokens.Layout.modelFactMinimumWidth, alignment: .leading)
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
                Text("量化")
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
                detail: "「已下载」看文件是否完整；「在用」看当前这一档有没有把它加载起来。写着「已释放」只是暂时没占用内存，不等于文件缺失。"
            )
            Divider()
            if model.modelCatalog != nil {
                let artifacts = visibleArtifacts
                if artifacts.isEmpty {
                    ContentUnavailableView(
                        "这一档还没有登记模型文件",
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
                                    quantization: quantizationText(for: artifact),
                                    selected: selectedArtifactKey == artifact.key
                                )
                            }
                            .speechRailInteractiveButtonStyle(fillsAvailableWidth: true)
                            .accessibilityIdentifier("artifact-\(artifact.key)")
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
        guard !artifacts.isEmpty else { return "这一档还没有登记模型文件。" }
        let pending = artifacts.filter { !isVerified(status(for: $0)) }.count
        let base = pending == 0
            ? "\(artifacts.count) 个模型文件 · 全部已校验"
            : "\(artifacts.count) 个模型文件 · \(pending) 个待校验"
        let diarizationNote = missingDiarizationKeys.isEmpty
            ? ""
            : "，谁在说话在补齐前用不了"
        return base + diarizationNote + "。"
    }

    private var diarizationSection: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            SectionHeading(
                title: "谁在说话要用的模型",
                detail: "这一档要标出每句话是谁说的，还得再下载几个小模型；它们也列在下面的模型文件里。"
            )
            VStack(spacing: 0) {
                ForEach(independentDiarizationKeys, id: \.self) { key in
                    DiarizationStatusRow(
                        key: key,
                        status: status(forKey: key),
                        usage: usage(forKey: key)
                    )
                }
            }
        }
    }

    private var unmanagedArtifactSection: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            SectionHeading(
                title: "已检测但未纳入当前目录",
                detail: "这些模型文件还在本机，但没有登记在当前这一档里；选档和运行都不会用到它们。"
            )
            VStack(spacing: 0) {
                ForEach(unmanagedArtifactStatuses, id: \.key) { status in
                    UnmanagedArtifactRow(status: status)
                }
            }
        }
    }

    /// Figma `actions`：动作行紧跟档位卡、排在制品卡之前。4x 帧实测（`▸ 模型.png`）
    /// 两张卡之间是一条 74.25pt 的页面底色带，里面只有一行 34pt 的动作，上下各留
    /// 20pt——与页面级块间距 `Spacing.gutter` 同值；「磁盘」事实在这一行右端。
    ///
    /// 这里不再放「下一步」小标题：稿上没有，页头副标题「先下载并校验，再应用到运行
    /// 档位；两者是独立操作。」已经说过同一句话（全局密度约定：不重复解释）。
    /// 下方只保留会改变判断的阻塞原因，以及正在进行/被中断的操作本身。
    private var actionSection: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
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
                .speechRailButton(.primary)
                .disabled(!canPrepareModels)
                .accessibilityHint("准备并校验所选档位的本机模型文件")

                Button {
                    pendingAction = .apply
                } label: {
                    // 稿上这个次按钮只有文字，没有图标（4x 帧里是 5 个字形簇）。
                    Text("应用此档位")
                }
                .speechRailButton(.secondary)
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
            if !missingDiarizationKeys.isEmpty {
                Text("此档位还需要 \(missingDiarizationKeys.map(assetTitle(for:)).joined(separator: "、"))通过校验。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                    .lineLimit(2)
                    .truncationMode(.tail)
            } else if !visibleArtifacts.isEmpty && !profileArtifactsVerified {
                Text("换到这一档之前，先把这一档需要的模型下载并校验完。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            if let message = model.message, !message.isEmpty, model.modelAvailability == .available {
                Text(SpeechRailOperationMessagePresentation.text(message))
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.critical)
                    .lineLimit(2)
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

    private var modelReadinessSummary: some View {
        let presentation = modelReadinessPresentation
        return HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Image(systemName: presentation.systemImage)
                .font(SpeechRailDesignTokens.Typography.statusIcon)
                .foregroundStyle(presentation.tone.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(presentation.title)
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(presentation.detail)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.title)
        .accessibilityValue(presentation.detail)
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
                LabeledContent("量化", value: quantizationText(for: artifact))
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
                    "VoiceDesign 能力（目标档位）",
                    value: voiceDesignCapability(for: selectedProfile)
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
                LabeledContent("目标档位", value: profileTitle(for: selectedProfile))
                LabeledContent(
                    "当前服务档位",
                    value: currentServiceProfile.map { profileTitle(for: $0) } ?? "运行态未读取"
                )
                LabeledContent(
                    "配置档位",
                    value: configuredProfile.map { profileTitle(for: $0) } ?? "未读取"
                )
                LabeledContent("目录状态", value: model.modelAvailability == .available ? "已读取" : "未读取")
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
    private var currentServiceProfile: SpeechRailProfile? {
        guard model.healthFailure == nil else { return nil }
        return model.health?.profile
    }

    private var availableProfiles: [SpeechRailProfile] {
        model.modelCatalog?.selectableProfiles ?? []
    }

    private var configuredProfile: SpeechRailProfile? {
        model.profile?.preset
    }

    private var profileContextAccessibilityValue: String {
        let target = "目标档位：\(profileTitle(for: selectedProfile))"
        let current = currentServiceProfile.map { "当前服务：\(profileTitle(for: $0))" }
            ?? "当前服务：运行态未读取"
        let consistency: String
        switch (configuredProfile, currentServiceProfile) {
        case let (.some(configured), .some(current)) where configured == current:
            consistency = "配置与运行一致"
        case (.some, .some):
            consistency = "配置与运行不一致"
        default:
            consistency = "配置与运行一致性未确认"
        }
        let configured = configuredProfile.map { "配置档位：\(profileTitle(for: $0))" }
            ?? "配置档位：未配置"
        return [target, current, configured, consistency].joined(separator: "，")
    }

    private var visibleArtifacts: [ModelArtifactSnapshot] {
        model.modelCatalog?.artifacts.filter {
            $0.requiredBy.contains(selectedProfile)
        } ?? []
    }

    /// The catalog reports total bytes per profile; this is only an upper bound
    /// because any artifact without a verified status is counted in full.
    private func remainingDownloadUpperBound(for profile: SpeechRailProfile) -> Int64? {
        model.modelCatalog?.remainingDownloadUpperBound(
            for: profile,
            statuses: model.modelStatus
        )
    }

    private func remainingDownloadText(for profile: SpeechRailProfile) -> String {
        guard let remainingBytes = remainingDownloadUpperBound(for: profile) else {
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

    private var independentDiarizationKeys: [String] {
        let visibleKeys = Set(visibleArtifacts.map(\.key))
        return requiredDiarizationKeys
            .filter { !visibleKeys.contains($0) }
    }

    private var requiredDiarizationKeys: [String] {
        guard let summary = summary(for: selectedProfile), summary.diarization else {
            return []
        }
        return ["diarization-coreml", summary.aligner].compactMap { $0 }
    }

    private var canPrepareModels: Bool {
        model.modelAvailability == .available
            && !model.isBusy
            && !model.hasActiveMutation
            && !model.isRefreshingModels
            && summary(for: selectedProfile) != nil
            && !visibleArtifacts.isEmpty
            && model.controlAgentStatus.allowsMutation
            && model.controlPlaneMessage == nil
    }

    private var canApplyProfile: Bool {
        canPrepareModels && profileArtifactsVerified
    }

    private var profileArtifactsVerified: Bool {
        summary(for: selectedProfile) != nil
            && !visibleArtifacts.isEmpty
            && visibleArtifacts.allSatisfy { isVerified(status(for: $0)) }
            && profileDiarizationVerified
    }

    private var profileDiarizationVerified: Bool {
        missingDiarizationKeys.isEmpty
    }

    private var modelReadinessPresentation: ModelReadinessPresentation {
        guard summary(for: selectedProfile) != nil else {
            return ModelReadinessPresentation(
                systemImage: "questionmark.circle",
                tone: .neutral,
                title: "目标档位映射未读取",
                detail: "暂时无法判断模型需求；请刷新模型状态。"
            )
        }
        guard !visibleArtifacts.isEmpty else {
            return ModelReadinessPresentation(
                systemImage: "shippingbox",
                tone: .attention,
                title: "这一档还没有可用的模型文件",
                detail: "去受管运行时目录看一眼，或者打开「诊断」看原因。"
            )
        }
        if let operation = activeModelOperation,
           operation.state == .accepted || operation.state == .running
        {
            let title = operation.command == .profileApply ? "正在应用目标档位" : "正在准备目标档位模型"
            return ModelReadinessPresentation(
                systemImage: operation.command == .profileApply
                    ? "arrow.triangle.2.circlepath"
                    : "arrow.down.circle",
                tone: .attention,
                title: title,
                detail: "以 OperationBar 的阶段和进度为准，完成后会重新读取服务状态。"
            )
        }
        guard profileArtifactsVerified else {
            let detail = missingDiarizationKeys.isEmpty
                ? "这一档的模型文件还没全部校验通过。"
                : "还需要校验：\(missingDiarizationKeys.map(assetTitle(for:)).joined(separator: "、"))。"
            return ModelReadinessPresentation(
                systemImage: "arrow.down.circle",
                tone: .attention,
                title: "需要下载并校验",
                detail: detail
            )
        }

        if currentServiceProfile == selectedProfile,
           configuredProfile == selectedProfile
        {
            return ModelReadinessPresentation(
                systemImage: "checkmark.seal.fill",
                tone: .healthy,
                title: "模型文件已验证，服务正在用这一档",
                detail: "配置与运行是同一档；模型按需加载，空闲后自动释放内存。"
            )
        }
        if currentServiceProfile == selectedProfile {
            return ModelReadinessPresentation(
                systemImage: "checkmark.circle",
                tone: .healthy,
                title: "模型文件已验证，服务正在用这一档",
                detail: "还没读到完整的配置档位；以重新读取的服务状态为准。"
            )
        }
        let current = currentServiceProfile.map { profileTitle(for: $0) } ?? "运行态未读取"
        return ModelReadinessPresentation(
            systemImage: "checkmark.circle",
            tone: .attention,
            title: "模型文件已验证，可以换到这一档",
            detail: "服务现在跑的是 \(current)；按下「应用此档位」才会换。"
        )
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

    private func voiceDesignCapability(for profile: SpeechRailProfile) -> String {
        guard let profileSummary = summary(for: profile),
              let artifact = model.modelCatalog?.artifacts.first(where: {
                  $0.key == profileSummary.tts
              })
        else {
            return "未读取"
        }
        return artifact.variant == "voice_design" ? "支持候选预览" : "不支持候选预览"
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
        guard let runtimeProfile = health.profile else {
            return ModelArtifactUsagePresentation(
                text: "运行档位未读取",
                tone: .neutral
            )
        }
        if let configuredProfile, configuredProfile != runtimeProfile {
            return ModelArtifactUsagePresentation(
                text: "配置档位与运行时不一致 · 当前服务未确认使用",
                tone: .critical
            )
        }
        guard let activeSummary = summary(for: runtimeProfile) else {
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

        if key == activeSummary.asr {
            return runtimeUsage(
                label: "当前服务 · " + profileTitle(for: runtimeProfile) + " · ASR",
                ready: health.asrReady,
                state: health.asrState
            )
        }
        if key == activeSummary.tts {
            return runtimeUsage(
                label: "当前服务 · " + profileTitle(for: runtimeProfile) + " · TTS",
                ready: health.ttsReady,
                state: health.ttsState
            )
        }
        if key == activeSummary.ttsClone {
            return cloneRuntimeUsage(
                label: "当前服务 · " + profileTitle(for: runtimeProfile) + " · 克隆 TTS",
                health: health
            )
        }
        if activeSummary.diarization,
           key == activeSummary.aligner || key == "diarization-coreml" {
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
        guard !availableProfiles.contains(selectedProfile) else { return }
        if availableProfiles.contains(.balanced) {
            selectedProfile = .balanced
        } else if let first = availableProfiles.first {
            selectedProfile = first
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
        return switch pendingAction {
        case .download:
            downloadConfirmationTitle
        case .apply:
            applyConfirmationTitle
        }
    }

    private var applyConfirmationTitle: String {
        let current = currentServiceProfile.map { profileTitle(for: $0) } ?? "运行态未读取"
        var details: [String] = []
        if let summary = summary(for: selectedProfile) {
            details.append("该档模型总大小 \(formatBytes(summary.downloadBytes))")
        }
        if let freeBytes = model.modelStatus?.disk.freeBytes {
            details.append("当前可用磁盘空间 \(formatBytes(freeBytes))")
        }
        details.append("已校验的模型文件不会重下，首次加载可能更久，其他档位模型不会删除")
        if selectedProfile == .extreme {
            details.append("更大的模型权重可能增加内存占用；实际并发能力以切换后服务诊断为准")
        }
        return "确认应用 \(profileTitle(for: selectedProfile))？当前服务为 \(current)。"
            + "这会更新服务配置、重新加载语音模型并重新读取状态。"
            + details.joined(separator: "；")
            + "。"
    }

    private var downloadConfirmationTitle: String {
        let profile = profileTitle(for: selectedProfile)
        let size = summary(for: selectedProfile).map { formatBytes($0.downloadBytes) }
        let remaining = remainingDownloadText(for: selectedProfile)
        let free = model.modelStatus.map { formatBytes($0.disk.freeBytes) }
        var details: [String] = []
        if let size {
            details.append("该档模型总大小 \(size)")
        }
        details.append(remaining)
        if let free {
            details.append("当前可用磁盘空间 \(free)")
        }
        details.append("已校验文件不会重下，首次加载可能更久，其他档位模型不会删除")
        details.append("只下载并校验，不会重启服务或切换档位，也不会上传音频或作品")
        return "确认下载并校验 \(profile) 模型？\(details.joined(separator: "；"))。"
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

    private func profilePurpose(for profile: SpeechRailProfile) -> String {
        SpeechRailProfilePresentation.purpose(profile)
    }

    private func quantizationText(for artifact: ModelArtifactSnapshot) -> String {
        let bits = artifact.quantization.bits.map { "\($0)-bit" } ?? "未声明位宽"
        let group = artifact.quantization.groupSize.map { " · group \($0)" } ?? ""
        return "\(bits) · \(artifact.quantization.format)\(group)"
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
        .accessibilityValue(isSelected ? "已选择" : "未选择")
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

private struct ModelReadinessPresentation {
    let systemImage: String
    let tone: StatusTone
    let title: String
    let detail: String
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

private struct ArtifactChoiceRow: View {
    let artifact: ModelArtifactSnapshot
    let status: ModelArtifactStatusSnapshot?
    let quantization: String
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

                Text(quantization)
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
            "\(modelSourceText)，量化 \(quantization)，\(artifact.fileCount) 个文件，\(statusPresentation.summary)"
        )
        .accessibilityHint("在开发者详情中查看模型来源和校验信息")
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

private struct DiarizationStatusRow: View {
    let key: String
    let status: ModelArtifactStatusSnapshot?
    let usage: ModelArtifactUsagePresentation

    var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            Image(systemName: statusPresentation.systemImage)
                .foregroundStyle(statusPresentation.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                // 行的名字说**这一份文件是干什么的**；`aligner-bf16` 这类机器名留在后面，
                // 它对不上名字时还能拿去比对诊断输出（用户 2026-09-19：去掉行话）。
                Text(key == "diarization-coreml" ? "谁在说话用的模型" : "配套模型 · \(key)")
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("存在：\(statusPresentation.summary)")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(statusPresentation.color)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text("使用：\(usage.text)")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(usage.tone.color)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, SpeechRailDesignTokens.List.rowVerticalPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(key)
        .accessibilityValue("存在：\(statusPresentation.summary)，使用：\(usage.text)")
    }

    private var statusPresentation: ModelArtifactStatusPresentation {
        ModelArtifactStatusPresentation(status: status)
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
