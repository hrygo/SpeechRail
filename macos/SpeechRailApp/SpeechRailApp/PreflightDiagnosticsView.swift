import AppKit
import SpeechRailControlKit
import SwiftUI

public struct PreflightDiagnosticsView: View {
    /// 复制回执在页脚停留的时长。
    private static let reportReceiptDuration: Duration = .seconds(4)

    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 开发者详情是全 App 的一个偏好（View ▸ 显示/隐藏开发者详情 ⌘⌥I）。
    @AppStorage("speechrail.showDeveloperDetails") private var showInspector = false
    @State private var selectedCheckName: String?
    @State private var reportMessage: String?
    @State private var reportCopySucceeded = true
    @State private var showsPassingChecks = false
    @AppStorage("speechrail.diagnostics.includeServiceContext") private var includeServiceContext = true

    public init() {}

    public var body: some View {
        PageScaffold(route: .diagnostics, layout: .content) {
            diagnosticWorkspace
        } trailing: {
            Button {
                Task { await model.refreshPreflight() }
            } label: {
                Label("重新运行诊断", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            // 稿的页头次按钮是 30pt（脚本 `secondaryButton`）；系统 `.large` 是 28。
            .controlSize(.large)
            .disabled(model.isBusy || model.isRefreshingPreflight)
            .help("重新运行诊断")
            .accessibilityLabel("重新运行诊断")
            .accessibilityIdentifier("diagnostics-run")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // 重新运行诊断是这一页的主动作，它留在正文的结论面板旁；
                // 头部只放跨页要用的那一件事（§6.2）。
                PageActionButton(
                    systemImage: "doc.on.clipboard",
                    helpText: "复制脱敏诊断报告",
                    isEnabled: !(model.isRefreshingPreflight || model.preflightChecks.isEmpty)
                ) {
                    copyDiagnosticReport()
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .focusedSceneValue(
            \.reloadPageCommand,
            ReloadPageCommand(title: "重新运行诊断") {
                Task { await model.refreshPreflight() }
            }
        )
        .inspector(isPresented: $showInspector) {
            DeveloperInspector {
                SectionHeading(
                    title: "诊断上下文",
                    detail: "诊断只读环境、模型文件和配置，不会下载模型，也不会改变服务。"
                )
                LabeledContent("运行档位", value: displayedHealth?.profile?.rawValue ?? "未读取")
                LabeledContent("配置档位", value: model.profile?.preset?.rawValue ?? "未配置")
                LabeledContent("服务状态", value: model.service.serviceState)
                LabeledContent("检查数量", value: String(model.preflightChecks.count))
                if let selectedCheck {
                    Divider()
                        LabeledContent("选中检查", value: selectedCheck.name)
                        LabeledContent("结果", value: selectedCheck.ok ? "通过" : "失败")
                        LabeledContent("安全技术结果", value: safeTechnicalResult(for: selectedCheck))
                }
            }
        }
        .task {
            model.refreshControlAgentStatus()
            await model.refreshModelsAndHealth()
            await model.refreshPreflight()
            selectFirstCheckIfNeeded()
        }
        .onChange(of: model.preflightChecks) { _, _ in
            selectFirstCheckIfNeeded()
        }
        .onChange(of: model.preflightRequestID) { _, _ in
            // 新的一次预检要回到它自己的结论，而不是停在上一轮点开的明细上。
            showsPassingChecks = false
        }
    }

    private var diagnosticWorkspace: some View {
        Group {
            if model.preflightChecks.isEmpty && model.isRefreshingPreflight {
                // REDESIGN-SPEC §8：服务四页的「加载中」是 ProgressView，
                // 不是一份空清单，也不是一个结论。
                ProgressView("正在运行诊断…")
                    .frame(
                        maxWidth: .infinity,
                        minHeight: SpeechRailDesignTokens.Layout.diagnosticsBodyMinimumHeight,
                        alignment: .center
                    )
            } else if allChecksPassed && !showsPassingChecks {
                // A clean run is a conclusion, not an empty list
                // (REDESIGN-SPEC §7.8). It uses the shared state-conclusion
                // panel so the tint/stroke/icon say "checked, clean"; grey
                // stays reserved for 「还没有检查项」(未执行) below.
                // `ContentUnavailableView` is the system *empty* component and
                // renders grey, which reads as "diagnostics never ran".
                StatusBanner(
                    kind: .conclusion,
                    tone: .healthy,
                    title: "未发现问题",
                    message: "\(model.preflightChecks.count) 项检查全部通过。这只说明环境与配置满足启动条件，不代表模型质量、性能或发布验收通过。",
                    actionTitle: "查看检查明细"
                ) {
                    showsPassingChecks = true
                }
            } else {
                // 两栏之间是「栏与栏」，不是页面块：帧实测两栏底色带 15pt（即 16pt），
                // 比页面级 20pt 紧一档（REDESIGN-SPEC §5.6 / §11.6 第十七轮）。
                HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.md) {
                    checkList
                        .frame(
                            minWidth: SpeechRailDesignTokens.Layout.diagnosticsListWidth,
                            idealWidth: SpeechRailDesignTokens.Layout.diagnosticsListWidth,
                            maxWidth: SpeechRailDesignTokens.Layout.diagnosticsListWidth,
                            minHeight: SpeechRailDesignTokens.Layout.diagnosticsBodyMinimumHeight,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                    detailPanel
                        .frame(
                            minWidth: 0,
                            maxWidth: .infinity,
                            minHeight: SpeechRailDesignTokens.Layout.diagnosticsBodyMinimumHeight,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                }
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: SpeechRailDesignTokens.Layout.diagnosticsBodyMinimumHeight,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }

    private var allChecksPassed: Bool {
        !model.preflightChecks.isEmpty && model.preflightChecks.allSatisfy(\.ok)
    }

    private var checkList: some View {
        CardSurface {
            CardHead(
                title: "检查项",
                detail: "选择一项查看原因和处理建议。",
                trailing: { checkListHeadTrailing }
            )
            Divider()
            if model.preflightChecks.isEmpty {
                ContentUnavailableView(
                    "还没有检查项",
                    systemImage: AppRoute.diagnostics.systemImage,
                    description: Text("运行诊断后，结果会出现在这里。")
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: SpeechRailDesignTokens.Layout.diagnosticsEmptyListMinimumHeight
                )
            } else {
                List(selection: $selectedCheckName) {
                    ForEach(model.preflightChecks, id: \.name) { check in
                        PreflightCheckRow(
                            check: check,
                            title: checkTitle(for: check.name),
                            detail: explanation(for: check.name)
                        )
                        .tag(check.name)
                        .accessibilityIdentifier("preflight-\(check.name)")
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("诊断检查项")
            }
            Divider()
            CardFoot(note: checklistFootnote) {
                Button {
                    copyDiagnosticReport()
                } label: {
                    // 复制回执留在这个动作自己身上：设计稿的页脚只有「一句事实 + 一个动作」，
                    // 回执不能另起一条横贯页面的提示带。
                    Label(copyReportTitle, systemImage: copyReportIcon)
                }
                .speechRailButton(.secondary)
                .disabled(model.isRefreshingPreflight || model.preflightChecks.isEmpty)
                .accessibilityIdentifier("diagnostics-copy-report")
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: SpeechRailDesignTokens.Layout.diagnosticsBodyMinimumHeight,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .accessibilityIdentifier("diagnostics-check-list")
    }

    /// Figma `listHead` 右侧：需要处理的检查项数量。颜色之外还有文字，
    /// 不靠颜色单独表达（REDESIGN-SPEC §9）。
    private var pendingNote: some View {
        let pending = model.preflightChecks.filter { !$0.ok }.count
        let note = if model.preflightChecks.isEmpty {
            "尚未检查"
        } else if pending == 0 {
            "全部通过"
        } else {
            "\(pending) 项需要处理"
        }
        let tone: Color = if model.preflightChecks.isEmpty {
            SpeechRailDesignTokens.Color.inkTertiary
        } else if pending == 0 {
            SpeechRailDesignTokens.Color.ready
        } else {
            SpeechRailDesignTokens.Color.attention
        }
        return Text(note)
            .font(SpeechRailDesignTokens.Typography.caption)
            .foregroundStyle(tone)
            .lineLimit(1)
            .accessibilityIdentifier("diagnostics-summary")
            .accessibilityLabel("检查项结论")
            .accessibilityValue(
                model.preflightChecks.isEmpty
                    ? "尚未检查"
                    : "\(model.preflightChecks.count - pending) 项通过，\(pending) 项失败"
            )
    }

    /// 全通过时清单是「从结论面板点进来」看的，所以清单头要留一条回结论的路：
    /// `showsPassingChecks` 不能是单向门。
    @ViewBuilder
    private var checkListHeadTrailing: some View {
        if showsPassingChecks && allChecksPassed {
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                pendingNote
                Button("只看结论") {
                    showsPassingChecks = false
                }
                .speechRailButton(.secondary)
                .accessibilityIdentifier("diagnostics-collapse-passing")
            }
        } else {
            pendingNote
        }
    }

    /// 页脚动作兼回执：复制成功与失败都在这一个控件上说清楚，图标与文字同时变化，
    /// 不依赖颜色单独表达（REDESIGN-SPEC §9）。
    private var copyReportTitle: String {
        reportMessage ?? "复制诊断报告"
    }

    private var copyReportIcon: String {
        guard reportMessage != nil else { return "doc.on.clipboard" }
        return reportCopySucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    /// Figma `listFoot`：上次诊断多久前、一共查了几项 —— 两个本机事实，
    /// 不涉及任何检查内容或路径。
    private var checklistFootnote: String {
        let count = model.preflightChecks.count
        guard let lastUpdated = model.lastPreflightRefresh else {
            return count == 0 ? "尚未运行诊断" : "共 \(count) 项 · 上次诊断时间未记录"
        }
        return "上次诊断 \(relativeAgeText(lastUpdated)) · 共 \(count) 项"
    }

    private func relativeAgeText(_ date: Date) -> String {
        let age = max(0, Int(Date().timeIntervalSince(date).rounded()))
        return age < 60 ? "\(age) 秒前" : "\(age / 60) 分钟前"
    }

    /// The card owns the full column height and scrolls inside itself, so the
    /// numbered steps never get cut off after the technical context
    /// (REDESIGN-SPEC §7.8).
    private var detailPanel: some View {
        ScrollView(.vertical) {
            detailContent
                .padding(SpeechRailDesignTokens.Layout.cardInset)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .speechRailContentSurface()
        .accessibilityIdentifier("diagnostics-check-detail")
    }

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            if let selectedCheck {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                    // Figma `pillRow`：结论胶囊在左，这次预检的时间在右；
                    // 状态由胶囊承载，标题下面不再重复一遍「检查通过 / 失败」。
                    HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                        StatusPill(
                            tone: selectedCheck.ok ? .healthy : .critical,
                            label: selectedCheck.ok ? "通过" : "需要处理"
                        )
                        Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
                        if let lastUpdated = model.lastPreflightRefresh {
                            Text(relativeAgeText(lastUpdated))
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                                .lineLimit(1)
                        }
                    }
                    Text(checkTitle(for: selectedCheck.name))
                        .font(SpeechRailDesignTokens.Typography.windowTitle)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 「检测结果」这一行删掉了：它与折叠区里的「安全技术结果」是同一句话
                // （`safeTechnicalResult(for:)` 就是 `resultMessage(for:)` 的返回值），
                // 同一屏写两遍只是重复（全局密度约定；当前生成脚本的详情卡里这两条
                // 也只在折叠区出现一次）。
                detailFact("这项检查确认", explanation(for: selectedCheck.name))
                detailFact("对当前服务的影响", impact(for: selectedCheck))

                // Figma `fix`：结论与影响之后就是这一项的动作，而且是详情卡里**唯一**
                // 的按钮（当前生成脚本：`primaryButton(fix, "打开模型管理", "download", 268)`，
                // 整宽 268/300、图标是托盘 + 下箭头）。这一格也是「不需要操作」的回执位置。
                if selectedCheck.ok {
                    Text("当前项目状态正常。")
                        .font(SpeechRailDesignTokens.Typography.body)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                } else {
                    recoveryAction(for: selectedCheck)
                }

                Divider()

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        LabeledContent("检查标识", value: selectedCheck.name)
                        LabeledContent("安全技术结果", value: safeTechnicalResult(for: selectedCheck))
                        LabeledContent("结果", value: selectedCheck.ok ? "通过" : "失败")
                        // 建议动作与模型证据收进这一层：前者与下面的编号修复步骤讲同一件事，
                        // 后者与模型页、Inspector 同源，都是「要查的时候才展开」的技术事实
                        // （§7.6.1 全局密度约束；稿的详情卡首屏只有结论、一句影响和一个动作）。
                        LabeledContent("建议动作", value: recoveryPath(for: selectedCheck).detail)
                        if isModelRelatedCheck(selectedCheck) {
                            modelEvidenceRows
                        }
                        LabeledContent("运行档位", value: displayedHealth?.profile?.rawValue ?? "未读取")
                        LabeledContent("配置档位", value: model.profile?.preset?.rawValue ?? "未配置")
                        LabeledContent("服务状态", value: model.service.serviceState)
                    }
                    .font(SpeechRailDesignTokens.Typography.technical)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .padding(.top, SpeechRailDesignTokens.Spacing.xs)
                } label: {
                    // 生成脚本这一格写的是「开发者详情」（`▸ 诊断.png` 那张 22:04 的帧上
                    // 还写着「技术上下文」，属于第十五轮判定的旧一代，不采用）。
                    Text("开发者详情")
                        .font(SpeechRailDesignTokens.Typography.body)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .disclosureGroupStyle(SpeechRailDisclosureGroupStyle())

                // 生成脚本的顺序是「开发者详情 → 修复步骤」（分隔线下方先是折叠区，
                // 再是编号步骤），条文的列举顺序与此不同，按稿。
                if !selectedCheck.ok {
                    recoverySteps(recoveryPath(for: selectedCheck).steps)
                }
            } else {
                ContentUnavailableView(
                    "选择一项检查",
                    systemImage: "list.bullet.clipboard",
                    description: Text("左侧清单会说明每项检查的用途和当前结果。")
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: SpeechRailDesignTokens.Layout.diagnosticsEmptyDetailMinimumHeight
                )
            }

            if let message = model.preflightMessage, !message.isEmpty {
                Text(SpeechRailOperationMessagePresentation.text(message))
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.critical)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func detailFact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Text(title)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            Text(value)
                .font(SpeechRailDesignTokens.Typography.diagnosticsDetail)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Steps are numbered because the order matters: applying a profile before
    /// its artifacts verify is exactly the mistake this page exists to prevent.
    private func recoverySteps(_ steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Text("修复步骤")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: SpeechRailDesignTokens.Spacing.sm) {
                        Text("\(index + 1)")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .monospacedDigit()
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            .frame(width: 16, alignment: .trailing)
                        Text(step)
                            .font(SpeechRailDesignTokens.Typography.diagnosticsDetail)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("修复步骤")
    }

    /// Figma `fix`：详情卡里只有一个动作，而且是整宽主按钮。
    /// 稿实测（2026-09-15 22:04 的 4x 帧）按钮 268×34、内容宽 300.8pt——稿是手画的
    /// 固定宽度，应用取整宽；稿的图标是托盘 + 下箭头，文案是目的地而不是动作
    /// （「打开模型管理」）。另外两条路由在稿上没有画面，沿用原文案与各自路由图标。
    @ViewBuilder
    private func recoveryAction(for check: PreflightCheckSnapshot) -> some View {
        switch recoveryPath(for: check).route {
        case .models:
            Button {
                navigation.request(.models)
            } label: {
                Label("打开模型管理", systemImage: "tray.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .speechRailButton(.primary)
        case .overview:
            Button {
                navigation.request(.overview)
            } label: {
                Label("查看服务状态", systemImage: AppRoute.overview.systemImage)
                    .frame(maxWidth: .infinity)
            }
            .speechRailButton(.primary)
        case .developer:
            Button {
                copyDiagnosticReport()
            } label: {
                Label("复制脱敏报告", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity)
            }
            .speechRailButton(.primary)
        }
    }

    /// 模型相关检查的证据行，整块收进「开发者详情」。取值与模型页使用同一组
    /// XPC `model.catalog` / `model.status` 快照；快照没读到就如实说不能判断，
    /// 不猜。原先这里在首屏上另起一块「模型证据」（分隔线 + 小标题 + 一句说明 +
    /// 三行事实），2026-09-16 的密度复查把它降为折叠区里的两行——同一份事实，
    /// 只是不再和结论抢首屏。第三行「当前服务」与折叠区里的「运行档位」同值，
    /// 合并成一行。
    @ViewBuilder
    private var modelEvidenceRows: some View {
        if let catalog = model.modelCatalog, let status = model.modelStatus {
            let statuses = status.artifacts + status.diarization
            let verifiedCount = statuses.filter {
                $0.state == .verified && $0.integrity == .verified
            }.count
            LabeledContent("受管模型文件", value: "\(catalog.artifacts.count) 个目录项")
            LabeledContent("完整性", value: "\(verifiedCount)/\(statuses.count) 个模型文件已通过校验")
        } else {
            LabeledContent("模型状态", value: "还没读取；本页不能推断模型是否存在、是否在用")
        }
    }

    private var displayedHealth: HealthSnapshot? {
        guard model.healthFailure == nil else { return nil }
        return model.health
    }

    private func isModelRelatedCheck(_ check: PreflightCheckSnapshot) -> Bool {
        let normalized = check.name.lowercased()
        return normalized.contains("model")
            || normalized.contains("snapshot")
            || normalized.contains("asr")
            || normalized.contains("tts")
            || normalized.contains("diarization")
            || normalized.contains("aligner")
            || normalized.contains("vad")
    }

    private func recoveryPath(for check: PreflightCheckSnapshot) -> DiagnosticRecoveryPath {
        let normalized = check.name.lowercased()
        if isModelRelatedCheck(check) {
            return DiagnosticRecoveryPath(
                route: .models,
                detail: "打开「模型」页核对这一档的目录、文件完整性和当前服务使用状态；模型文件全部校验通过之后再换档。",
                steps: [
                    "打开「模型」页，确认这一档需要的模型文件都已登记。",
                    "运行「下载并校验」，直到每项的存在状态与校验状态都通过。",
                    "回到本页重新运行诊断，确认这一项已经通过。",
                ]
            )
        }
        if normalized.contains("config")
            || normalized.contains("permission")
            || normalized.contains("runtime")
            || normalized.contains("ffmpeg")
            || normalized.contains("app_home")
            || normalized.contains("settings")
        {
            return DiagnosticRecoveryPath(
                route: .overview,
                detail: "先打开「服务状态」确认能在这里管理服务、运行环境正常，再重新运行诊断；本页不会自动改写配置或权限。",
                steps: [
                    "打开「服务状态」，确认可以在这里管理服务，且服务已就绪。",
                    "确认运行环境、配置文件和模型文件的访问权限满足运行条件。",
                    "回到本页重新运行诊断，确认这一项已经通过。",
                ]
            )
        }
        return DiagnosticRecoveryPath(
            route: .developer,
            detail: "没有安全的自动修复动作；复制脱敏报告交给开发者，报告不包含凭据、原始音频或本地绝对路径。",
            steps: [
                "复制脱敏诊断报告（不含凭据、原始音频或本地绝对路径）。",
                "把报告连同本页的检查项交给开发者。",
                "修复后回到本页重新运行诊断，确认这一项已经通过。",
            ]
        )
    }

    private func explanation(for name: String) -> String {
        let normalized = name.lowercased()
        if normalized.contains("app_home") {
            return "确认 SpeechRail 的本机应用目录可访问。"
        }
        if normalized.contains("config_file") {
            return "确认服务配置文件存在且可以被受管 runtime 读取。"
        }
        if normalized.contains("permission") {
            return "确认配置和模型文件具备服务运行所需的访问权限。"
        }
        if normalized.contains("ffmpeg") {
            return "确认音频编解码依赖可用，上传和输出流程能够正常工作。"
        }
        if normalized.contains("settings") {
            return "确认当前 profile 和运行参数可以被服务读取。"
        }
        if normalized.contains("asr") {
            return "确认语音识别的配置、模型文件和运行状态满足启动条件。"
        }
        if normalized.contains("tts") {
            return "确认语音合成的配置、模型文件和运行状态满足启动条件。"
        }
        return "确认 \(checkTitle(for: name)) 满足 SpeechRail 服务运行的前置条件。"
    }

    private func resultMessage(for check: PreflightCheckSnapshot) -> String {
        switch check.message.lowercased() {
        case "app home is available":
            "SpeechRail 应用目录可访问。"
        case "app home is missing":
            "找不到 SpeechRail 应用目录。"
        case "configuration file is present":
            "服务配置文件已找到。"
        case "configuration file is missing":
            "找不到服务配置文件。"
        case "configuration file is private":
            "服务配置文件权限符合要求。"
        case "configuration file must have mode 0600":
            "服务配置文件需要设置为仅当前用户可读写。"
        case "ffmpeg is available":
            "音频编解码依赖可用。"
        case "ffmpeg executable is missing":
            "找不到音频编解码依赖。"
        case "configuration is valid and model downloads are disabled":
            "运行配置有效，且服务不会自行下载模型。"
        case "model downloads must be disabled":
            "运行配置仍允许模型下载，需要先收紧配置。"
        case "runtime import is available":
            "运行时依赖可以正常加载。"
        case "runtime import failed":
            "运行时依赖加载失败。"
        case "runtime path is not configured":
            "尚未配置运行时位置。"
        case "runtime executable is missing or not executable":
            "运行时文件缺失或不可执行。"
        case "model snapshot is complete":
            "模型文件完整。"
        case "model snapshot is incomplete":
            "模型文件不完整。"
        case "model snapshot path is not configured":
            "还没有配置模型文件的位置。"
        case "model snapshot directory is missing":
            "找不到模型文件目录。"
        case "model snapshot weights are missing":
            "模型文件里缺少必要的权重文件。"
        case "asr runtime and snapshot are configured":
            "识别用的运行环境和模型文件都已配置。"
        case "asr model and python paths must be configured together":
            "识别模型与 Python 运行环境需要同时配置。"
        case "asr snapshot cannot be checked":
            "缺少识别配置，无法检查模型文件。"
        case "asr runtime cannot be checked":
            "缺少识别配置，无法检查运行环境。"
        case "tts runtime and snapshot are configured":
            "合成用的运行环境和模型文件都已配置。"
        case "tts is not configured; use explicit asr-only mode":
            "没有配置合成能力；当前只做识别。"
        case "tts snapshot cannot be checked":
            "缺少合成配置，无法检查模型文件。"
        case "tts runtime cannot be checked":
            "缺少合成配置，无法检查运行环境。"
        case "cannot validate settings without configuration":
            "缺少配置文件，无法检查运行设置。"
        case "configuration validation failed":
            "服务配置校验失败。"
        case "asr configuration validation failed":
            "识别配置校验失败。"
        case "tts configuration validation failed":
            "合成配置校验失败。"
        case "diarization configuration validation failed":
            "「谁在说话」的配置没通过校验。"
        case "optional diarization profile is not configured":
            "当前没有配置可选的「谁在说话」能力。"
        case "diarization profile is configured":
            "「谁在说话」的配置已经登记。"
        case "compiled coreml diarization bundle is available":
            "「谁在说话」要用的模型可用。"
        case "compiled coreml diarization bundle is missing or incorrect":
            "「谁在说话」要用的模型缺失，或版本不正确。"
        case "coreml diarization worker is executable":
            "「谁在说话」的后台组件可以执行。"
        case "coreml diarization worker is missing or not executable":
            "「谁在说话」的后台组件缺失或无法执行。"
        case "legacy vad is ready":
            "实时语音断句（旧引擎）已就绪。"
        case "silero vad model file is available":
            "实时语音断句的模型可用。"
        case "silero vad model path is not configured":
            "还没有配置实时语音断句的模型。"
        case "silero vad model file is missing":
            "找不到实时语音断句的模型文件。"
        case "prepared runtime is unavailable":
            "受管的运行环境不可用。"
        case "prepared vendor runtime is available":
            "受管的厂商运行环境可用。"
        case "runtime lock and manifest identity match":
            "运行环境的锁定版本与清单一致。"
        case "prepared ffmpeg is available":
            "受管的音频编解码组件可用。"
        case "prepared ffmpeg is missing":
            "受管的音频编解码组件缺失。"
        case "prepared asr runtime identity and worker import are available":
            "识别用的受管运行环境可用。"
        case "prepared tts runtime identity and worker import are available":
            "合成用的受管运行环境可用。"
        case "prepared asr runtime package or worker import failed":
            "识别用的受管运行环境加载失败。"
        case "prepared tts runtime package or worker import failed":
            "合成用的受管运行环境加载失败。"
        case "clone snapshot path is not configured":
            "还没有配置音色克隆要用的模型。"
        case "clone snapshot config.json is missing or invalid":
            "音色克隆模型的配置文件缺失或无效。"
        case "clone snapshot config.json must contain an object":
            "音色克隆模型的配置文件格式不正确。"
        case "clone snapshot is not a qwen3-tts model":
            "音色克隆用的模型不是受支持的模型。"
        case "clone snapshot must be the base tts variant":
            "音色克隆必须用内置音色那一版合成模型。"
        case "clone snapshot is the base tts variant":
            "音色克隆用的模型版本正确。"
        default:
            check.ok
                ? "检查已通过；服务端未提供额外安全详情。"
                : "检查未通过；技术原文已隐藏，请依据检查标识处理。"
        }
    }

    private func safeTechnicalResult(for check: PreflightCheckSnapshot) -> String {
        resultMessage(for: check)
    }

    private func copyDiagnosticReport() {
        let formatter = ISO8601DateFormatter()
        let generatedAt = formatter.string(from: Date())
        let lastUpdated = model.lastPreflightRefresh.map(formatter.string(from:)) ?? "未提供"
        let checks = model.preflightChecks.map { check in
            let status = check.ok ? "passed" : "failed"
            return "- \(safeIdentifier(check.name)): \(status); \(safeTechnicalResult(for: check))"
        }.joined(separator: "\n")
        let report = """
        SpeechRail 脱敏诊断报告
        schema_version: \(ControlConstants.schemaVersion)
        generated_at: \(generatedAt)
        preflight_updated_at: \(lastUpdated)
        preflight_request_id: \(model.preflightRequestID?.uuidString ?? "未提供")
        \(serviceContextLines)
        control_plane: \(model.controlPlaneMessage == nil ? "available" : "unavailable")
        checks: \(model.preflightChecks.filter(\.ok).count)/\(model.preflightChecks.count) passed

        \(checks)
        """
        _ = NSPasteboard.general.clearContents()
        reportCopySucceeded = NSPasteboard.general.setString(report, forType: .string)
        withAnimation(reduceMotion ? nil : .easeOut(duration: SpeechRailDesignTokens.Motion.standardDuration)) {
            reportMessage = reportCopySucceeded ? "已复制脱敏诊断报告" : "复制失败，请重试"
        }
        // 回执是临时的：几秒后页脚的事实位要还给「上次诊断 … · 共 N 项」。
        Task {
            try? await Task.sleep(for: Self.reportReceiptDuration)
            guard reportMessage != nil else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: SpeechRailDesignTokens.Motion.standardDuration)) {
                reportMessage = nil
            }
        }
    }

    /// Settings ▸ 服务 decides whether the report carries the runtime context.
    /// Credentials, raw audio, full transcripts and absolute paths are never
    /// included either way (REDESIGN-SPEC §7.10).
    private var serviceContextLines: String {
        guard includeServiceContext else {
            return "service_context: 按设置省略（运行档位、配置档位、服务状态、健康结果）"
        }
        return """
        runtime_profile: \(displayedHealth?.profile?.rawValue ?? "未读取")
        configured_profile: \(model.profile?.preset?.rawValue ?? "未配置")
        service_state: \(safeIdentifier(model.service.serviceState))
        health_ready: \(displayedHealth?.ready.map { $0 ? "true" : "false" } ?? "未读取")
        health_failure: \(healthFailureSummary)
        """
    }

    private func safeIdentifier(_ value: String) -> String {
        String(value.map { character in
            let isAllowed = character.isASCII
                && (character.isLetter || character.isNumber || "._-".contains(character))
            return isAllowed ? character : "_"
        })
    }

    private var healthFailureSummary: String {
        guard let failure = model.healthFailure else { return "none" }
        switch failure {
        case .connection:
            return "connection"
        case .timeout:
            return "timeout"
        case .invalidResponse:
            return "invalid_response"
        case let .server(code):
            return "server_\(safeIdentifier(code))"
        }
    }

    private func checkTitle(for name: String) -> String {
        // 这些名字是**用户**在"出问题了"的时候读的（这一页就是给用户的自检页），
        // 所以一律说人话：`ASR 制品` → `识别模型`、`受管运行时` → `运行环境`
        // （用户 2026-09-19：「有一些用户看不懂的词汇」）。服务侧的检查标识原样
        // 留在开发者详情里，排障时对得上。
        switch name.lowercased() {
        case "app_home":
            "应用目录"
        case "config_file":
            "配置文件"
        case "config_permissions":
            "配置权限"
        case "ffmpeg":
            "音频编解码"
        case "settings":
            "运行设置"
        case "asr_config":
            "识别配置"
        case "asr_snapshot":
            "识别模型"
        case "asr_runtime":
            "识别运行状态"
        case "tts_config":
            "合成配置"
        case "tts_snapshot":
            "合成模型"
        case "tts_runtime":
            "合成运行状态"
        case "tts_clone_snapshot":
            "音色克隆模型"
        case "tts_clone_variant":
            "音色克隆版本"
        case "diarization_config":
            "谁在说话的配置"
        case "diarization_snapshot":
            "谁在说话的模型"
        case "diarization_runtime":
            "谁在说话的运行状态"
        case "diarization_aligner_snapshot":
            "谁在说话的配套模型"
        case "realtime_vad":
            "实时语音断句"
        case "realtime_vad_model":
            "实时语音断句模型"
        case "realtime_vad_runtime":
            "实时语音断句运行状态"
        case "managed_runtime":
            "运行环境"
        case "managed_runtime_identity":
            "运行环境标识"
        case "managed_asr_runtime":
            "识别运行环境"
        case "managed_tts_runtime":
            "合成运行环境"
        case "managed_ffmpeg":
            "音频编解码组件"
        default:
            name.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func impact(for check: PreflightCheckSnapshot) -> String {
        if check.ok {
            return "这项前置条件已满足，不会阻塞当前服务。"
        }
        let normalized = check.name.lowercased()
        if normalized.contains("snapshot")
            || normalized.contains("model")
            || normalized.contains("asr")
            || normalized.contains("tts")
            || normalized.contains("diarization")
            || normalized.contains("aligner")
            || normalized.contains("vad")
        {
            return "相关模型或语音能力无法被证明可用；继续启动可能导致对应请求返回未就绪。"
        }
        if normalized.contains("runtime") || normalized.contains("ffmpeg") {
            return "运行环境或音频编解码链路不完整，服务可能起不来，或者交付不了音频。"
        }
        if normalized.contains("config") || normalized.contains("permission") || normalized.contains("settings") {
            return "服务读不到配置；现在的档位和能力结论都不能当作可信。"
        }
        return "这项前置条件未满足，相关服务能力可能无法启动或使用。"
    }

    private var selectedCheck: PreflightCheckSnapshot? {
        guard let selectedCheckName else { return nil }
        return model.preflightChecks.first(where: { $0.name == selectedCheckName })
    }

    private func selectFirstCheckIfNeeded() {
        guard selectedCheck == nil else { return }
        selectedCheckName = model.preflightChecks.first?.name
    }
}

private struct DiagnosticRecoveryPath {
    enum Route {
        case models
        case overview
        case developer
    }

    let route: Route
    let detail: String
    /// Numbered, ordered steps. A single suggestion line is not a recovery plan
    /// (REDESIGN-SPEC §7.8).
    let steps: [String]
}

private struct PreflightCheckRow: View {
    let check: PreflightCheckSnapshot
    let title: String
    let detail: String

    var body: some View {
        // 稿的诊断检查行是 `frame("diagRow", { gap: 10, padX: 16, padY: 12 })`
        // （`main.js` 2009），图标是 `icon(row, item.icon, 16)` 的 **16pt 框**。
        // 上一轮只把墨迹从 10 收到 13（`Icon.rowStatusSize`），没有补框与间距，
        // 于是文字列停在 `16 + 13 + 8 = 37`，稿是 `16 + 16 + 10 = 42`。
        // 4x 帧 `▸ 诊断.png` 实测（`--cols`，就绪行在纯白底上）：图标墨迹 x 280.0
        // （= 卡左沿 261 + padX 16 + lucide `check` 在 16 框里的 2.25 留白）、
        // 标题墨迹 x 304.25（= 42 + 首字 1.25 字形留白）——与脚本的 16/10 逐位吻合。
        // 10 不在应用的 4pt 间距档上，也没有第二处用到，所以不新造 token，
        // 就地写明来源（REDESIGN-SPEC §11.6 第四十一轮）。
        HStack(spacing: 10) {
            Image(systemName: check.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                // 稿的 `icon(row, item.icon, 16)` 是 16pt 图标框；4x 帧实测墨迹
                // 对勾行 12.0 × 8.75、三角行 13.5 × 12.0。此前用 `.imageScale(.small)`
                // 只有 10.0 × 10.0（比稿小 20–30%），改用行首状态字形这一档
                // （`Icon.rowStatusSize` = 13，复现后 13 × 13 / 13 × 12）。
                // REDESIGN-SPEC §11.6 第三十九轮。字号管**墨迹**，框由下面的
                // `frame(width:)` 管，两者分开才是稿的写法。
                .font(SpeechRailDesignTokens.Typography.rowStatusIcon)
                .foregroundStyle(
                    check.ok
                        ? SpeechRailDesignTokens.Color.ready
                        : SpeechRailDesignTokens.Color.critical
                )
                .frame(width: SpeechRailDesignTokens.Control.diagnosticIconFrame)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(title)
                    // 稿的诊断检查行：图标框 16（墨迹 12–13.5）+ 名称 `Body / Medium` + 说明 `Callout`。
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail)
                    // 稿的诊断检查行说明是 `Callout`（12pt），不是 `caption`（10pt）：
                    // 4x 帧上这一行的墨迹高 12.50、名称行 12.00（两行都是中文，比例可比）——
                    // 说明与名称同档，而非小一档。应用此前用 `caption`，与上面这行注释自相矛盾，
                    // 也违反 `macos-app-design-system.md`「`caption` 只留给应用自有密集区块」的约定
                    // （REDESIGN-SPEC §11.6 第三十七轮）。
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            // 行尾是**导航指示**，不是状态词：稿 `main.js` 2016 写的是
            // `icon(row, "chevron-right", 14, V["text/tertiary"])`，4x 帧
            // `▸ 诊断.png` 每一行的右端也只有一个灰色 `›`。应用此前在这里放
            // 「通过 / 失败」两个字的语义色文本，比稿多出一列文字，而状态在行首字形
            // （`checkmark.circle.fill` / `xmark.circle.fill`）、列表头的「N 项需要处理」
            // 和行自身的 `accessibilityValue` 里都已经说过一遍了
            // （REDESIGN-SPEC §11.6 第四十一轮）。尺寸沿用应用自己的导航 chevron 档
            // （`caption`，与折叠行、结果条同族），颜色取稿的 `text/tertiary`。
            Image(systemName: "chevron.right")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                .accessibilityHidden(true)
        }
        // 页面列表行与侧栏列表行不是一档：稿的侧栏项是 padX 8（`List.rowHorizontalPadding`
        // 仍留给侧栏），页面里的 `row` 三处（音色库 / 我的作品 / 诊断）都是 **padX 16 /
        // padY 12**。4x 帧实测这三页的行距都是 64.00 = 行框 63 + 1pt hairline，
        // 所以行高钉 `pageRowMinimumHeight`（2026-09-16 第三十七轮；此前取 44 的命中区下限，
        // 渲染出来只有 59，比帧矮 4）。行内边距由行自己给、`listRowInsets` 清零。
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        .listRowInsets(EdgeInsets())
        .frame(
            maxWidth: .infinity,
            minHeight: SpeechRailDesignTokens.List.pageRowMinimumHeight,
            alignment: .leading
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue("\(check.ok ? "通过" : "失败")，\(detail)")
    }
}
