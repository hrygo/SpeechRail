import SpeechRailControlKit
import SwiftUI

public struct PreflightDiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    @AppStorage("speechrail.showDeveloperDetails") private var showDeveloperDetails = false
    @State private var selectedCheckName: String?
    @State private var showInspector = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            PageIntroView(route: .diagnostics)
            DiagnosticsSummaryView(
                checks: model.preflightChecks,
                isBusy: model.isBusy || model.isRefreshingPreflight,
                isRefreshing: model.isRefreshingPreflight,
                action: { Task { await model.refreshPreflight() } }
            )
            diagnosticWorkspace
        }
        .frame(
            maxWidth: SpeechRailDesignTokens.Layout.contentMaximumWidth,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.xl)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar {
            ToolbarItem {
                WorkspaceActionsMenu(helpText: "查看预检上下文与脱敏技术详情") {
                    Button {
                        showInspector.toggle()
                    } label: {
                        Label(
                            showInspector ? "隐藏开发者详情" : "显示开发者详情",
                            systemImage: "info.circle"
                        )
                    }
                }
            }
        }
        .inspector(isPresented: $showInspector) {
            DeveloperInspector {
                SectionHeading(
                    title: "预检上下文",
                    detail: "预检只读取环境、制品和配置，不会下载模型或改变服务。"
                )
                LabeledContent("当前档位", value: model.profile?.preset?.rawValue ?? "未配置")
                LabeledContent("服务状态", value: model.service.serviceState)
                LabeledContent("检查数量", value: String(model.preflightChecks.count))
                if let selectedCheck {
                    Divider()
                    LabeledContent("选中检查", value: selectedCheck.name)
                    LabeledContent("结果", value: selectedCheck.ok ? "通过" : "失败")
                }
            }
        }
        .task {
            showInspector = showDeveloperDetails
            model.refreshControlAgentStatus()
            await model.refreshPreflight()
            selectFirstCheckIfNeeded()
        }
        .onChange(of: showInspector) { _, value in
            showDeveloperDetails = value
        }
        .onChange(of: model.preflightChecks) { _, _ in
            selectFirstCheckIfNeeded()
        }
    }

    private var diagnosticWorkspace: some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.lg) {
            checkList
                .frame(
                    minWidth: SpeechRailDesignTokens.Layout.diagnosticsListWidth,
                    idealWidth: SpeechRailDesignTokens.Layout.diagnosticsListWidth,
                    maxWidth: SpeechRailDesignTokens.Layout.diagnosticsListWidth,
                    minHeight: SpeechRailDesignTokens.Layout.diagnosticsBodyMinimumHeight,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
            ScrollView(.vertical, showsIndicators: false) {
                detailPanel
            }
                .frame(
                    minWidth: 0,
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
        }
        .frame(
            maxWidth: .infinity,
            minHeight: SpeechRailDesignTokens.Layout.diagnosticsBodyMinimumHeight,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }

    private var checkList: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            SectionHeading(
                title: "检查清单",
                detail: "选择一项查看原因和处理建议。"
            )
            if model.preflightChecks.isEmpty {
                ContentUnavailableView(
                    "还没有检查项",
                    systemImage: "stethoscope",
                    description: Text("运行诊断后，结果会出现在这里。")
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: SpeechRailDesignTokens.Layout.diagnosticsEmptyListMinimumHeight
                )
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(minimum: 0), spacing: SpeechRailDesignTokens.Spacing.xs),
                            GridItem(.flexible(minimum: 0), spacing: SpeechRailDesignTokens.Spacing.xs),
                        ],
                        spacing: SpeechRailDesignTokens.Spacing.xs
                    ) {
                        ForEach(model.preflightChecks, id: \.name) { check in
                            Button {
                                selectedCheckName = check.name
                            } label: {
                                PreflightCheckRow(
                                    check: check,
                                    title: checkTitle(for: check.name),
                                    selected: selectedCheckName == check.name
                                )
                            }
                            .speechRailInteractiveButtonStyle()
                            .accessibilityIdentifier("preflight-\(check.name)")
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: SpeechRailDesignTokens.Layout.diagnosticsBodyMinimumHeight,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .padding(SpeechRailDesignTokens.Spacing.md)
        .speechRailField()
        .accessibilityIdentifier("diagnostics-check-list")
    }

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            if let selectedCheck {
                HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
                    Image(systemName: selectedCheck.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(
                            selectedCheck.ok
                                ? SpeechRailDesignTokens.Color.ready
                                : SpeechRailDesignTokens.Color.critical
                        )
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                        Text(checkTitle(for: selectedCheck.name))
                            .font(SpeechRailDesignTokens.Typography.sectionTitle)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                        Text(selectedCheck.ok ? "检查通过" : "检查失败")
                            .font(SpeechRailDesignTokens.Typography.label)
                            .foregroundStyle(
                                selectedCheck.ok
                                    ? SpeechRailDesignTokens.Color.ready
                                    : SpeechRailDesignTokens.Color.critical
                            )
                    }
                }

                detailFact("检测结果", resultMessage(for: selectedCheck))
                detailFact("这项检查确认", explanation(for: selectedCheck.name))
                detailFact("对当前服务的影响", impact(for: selectedCheck))

                Divider()

                SectionHeading(
                    title: "下一步",
                    detail: selectedCheck.ok
                        ? "这项检查不需要操作。继续查看其他检查项即可。"
                        : "先处理这项阻塞，再重新运行诊断确认结果。"
                )
                if selectedCheck.ok {
                    Text("当前项目状态正常。")
                        .font(SpeechRailDesignTokens.Typography.body)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                } else {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                        Button {
                            Task { await model.refreshPreflight() }
                        } label: {
                            Label("重新运行诊断", systemImage: "arrow.clockwise")
                        }
                        .speechRailButton(.primary)
                        .disabled(model.isBusy || model.isRefreshingPreflight)
                        Button {
                            navigation.request(.models)
                        } label: {
                            Label("打开模型管理", systemImage: "cube")
                        }
                        .speechRailButton(.secondary)
                        Button {
                            navigation.request(.overview)
                        } label: {
                            Label("查看服务状态", systemImage: "server.rack")
                        }
                        .speechRailButton(.secondary)
                    }
                }

                DisclosureGroup("开发者详情") {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        LabeledContent("检查标识", value: selectedCheck.name)
                        LabeledContent("原始结果", value: selectedCheck.message)
                        LabeledContent("结果", value: selectedCheck.ok ? "通过" : "失败")
                        LabeledContent("当前档位", value: model.profile?.preset?.rawValue ?? "未配置")
                        LabeledContent("服务状态", value: model.service.serviceState)
                    }
                    .font(SpeechRailDesignTokens.Typography.technical)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .padding(.top, SpeechRailDesignTokens.Spacing.xs)
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

            if let message = model.message, !message.isEmpty {
                Text(SpeechRailOperationMessagePresentation.text(message))
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.critical)
                    .lineLimit(2)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: SpeechRailDesignTokens.Layout.diagnosticsBodyMinimumHeight,
            alignment: .topLeading
        )
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailField()
        .accessibilityIdentifier("diagnostics-check-detail")
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

    private func explanation(for name: String) -> String {
        let normalized = name.lowercased()
        if normalized.contains("app_home") {
            return "确认 SpeechRail 的本机应用目录可访问。"
        }
        if normalized.contains("config_file") {
            return "确认服务配置文件存在且可以被受管 runtime 读取。"
        }
        if normalized.contains("permission") {
            return "确认配置和模型资产具备服务运行所需的访问权限。"
        }
        if normalized.contains("ffmpeg") {
            return "确认音频编解码依赖可用，上传和输出流程能够正常工作。"
        }
        if normalized.contains("settings") {
            return "确认当前 profile 和运行参数可以被服务读取。"
        }
        if normalized.contains("asr") {
            return "确认语音识别能力的配置、制品和运行状态满足启动条件。"
        }
        if normalized.contains("tts") {
            return "确认语音合成能力的配置、制品和运行状态满足启动条件。"
        }
        return "确认 \(name) 满足 SpeechRail 服务运行的前置条件。"
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
            "模型制品文件完整。"
        case "model snapshot is incomplete":
            "模型制品文件不完整。"
        case "model snapshot path is not configured":
            "尚未配置模型制品位置。"
        case "model snapshot directory is missing":
            "找不到模型制品目录。"
        case "model snapshot weights are missing":
            "模型制品缺少必要权重文件。"
        case "asr runtime and snapshot are configured":
            "ASR 运行时和模型制品已配置。"
        case "asr model and python paths must be configured together":
            "ASR 模型与 Python 运行时需要同时配置。"
        case "asr snapshot cannot be checked":
            "缺少 ASR 配置，无法检查模型制品。"
        case "asr runtime cannot be checked":
            "缺少 ASR 配置，无法检查运行时。"
        case "tts runtime and snapshot are configured":
            "TTS 运行时和模型制品已配置。"
        case "tts is not configured; use explicit asr-only mode":
            "TTS 未配置；当前只能使用明确的 ASR-only 模式。"
        case "tts snapshot cannot be checked":
            "缺少 TTS 配置，无法检查模型制品。"
        case "tts runtime cannot be checked":
            "缺少 TTS 配置，无法检查运行时。"
        case "cannot validate settings without configuration":
            "缺少配置文件，无法检查运行设置。"
        case "configuration validation failed":
            "服务配置校验失败。"
        case "asr configuration validation failed":
            "ASR 配置校验失败。"
        case "tts configuration validation failed":
            "TTS 配置校验失败。"
        case "diarization configuration validation failed":
            "分人配置校验失败。"
        case "optional diarization profile is not configured":
            "当前未配置可选的分人能力。"
        case "diarization profile is configured":
            "分人配置已登记。"
        case "compiled coreml diarization bundle is available":
            "CoreML 分人制品可用。"
        case "compiled coreml diarization bundle is missing or incorrect":
            "CoreML 分人制品缺失或版本不正确。"
        case "coreml diarization worker is executable":
            "CoreML 分人运行时可执行。"
        case "coreml diarization worker is missing or not executable":
            "CoreML 分人运行时缺失或不可执行。"
        case "legacy vad is ready":
            "传统 VAD 能力已就绪。"
        case "silero vad model file is available":
            "Silero VAD 模型可用。"
        case "silero vad model path is not configured":
            "尚未配置 Silero VAD 模型。"
        case "silero vad model file is missing":
            "找不到 Silero VAD 模型文件。"
        case "prepared runtime is unavailable":
            "受管运行时不可用。"
        case "prepared vendor runtime is available":
            "受管厂商运行时可用。"
        case "runtime lock and manifest identity match":
            "运行时锁定版本与清单一致。"
        case "prepared ffmpeg is available":
            "受管音频编解码依赖可用。"
        case "prepared ffmpeg is missing":
            "受管音频编解码依赖缺失。"
        case "prepared asr runtime identity and worker import are available":
            "受管 ASR 运行时身份和 worker 依赖可用。"
        case "prepared tts runtime identity and worker import are available":
            "受管 TTS 运行时身份和 worker 依赖可用。"
        case "prepared asr runtime package or worker import failed":
            "受管 ASR 运行时依赖或 worker 加载失败。"
        case "prepared tts runtime package or worker import failed":
            "受管 TTS 运行时依赖或 worker 加载失败。"
        case "clone snapshot path is not configured":
            "尚未配置音色克隆制品。"
        case "clone snapshot config.json is missing or invalid":
            "音色克隆制品的配置文件缺失或无效。"
        case "clone snapshot config.json must contain an object":
            "音色克隆制品的配置文件格式不正确。"
        case "clone snapshot is not a qwen3-tts model":
            "音色克隆制品不是受支持的 Qwen3-TTS 模型。"
        case "clone snapshot must be the base tts variant":
            "音色克隆制品必须使用 Base TTS 版本。"
        case "clone snapshot is the base tts variant":
            "音色克隆制品已确认是 Base TTS 版本。"
        default:
            check.ok
                ? "检查已通过。"
                : "检查未通过，请展开开发者详情查看原始结果。"
        }
    }

    private func checkTitle(for name: String) -> String {
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
            "ASR 配置"
        case "asr_snapshot":
            "ASR 制品"
        case "asr_runtime":
            "ASR 运行时"
        case "tts_config":
            "TTS 配置"
        case "tts_snapshot":
            "TTS 制品"
        case "tts_runtime":
            "TTS 运行时"
        case "tts_clone_snapshot":
            "音色克隆制品"
        case "tts_clone_variant":
            "音色克隆版本"
        case "diarization_config":
            "分人配置"
        case "diarization_snapshot":
            "分人制品"
        case "diarization_runtime":
            "分人运行时"
        case "diarization_aligner_snapshot":
            "分人对齐制品"
        case "realtime_vad":
            "实时语音检测"
        case "realtime_vad_model":
            "实时语音检测模型"
        case "realtime_vad_runtime":
            "实时语音检测运行时"
        case "managed_runtime":
            "受管运行时"
        case "managed_runtime_identity":
            "运行时身份"
        case "managed_asr_runtime":
            "受管 ASR 运行时"
        case "managed_tts_runtime":
            "受管 TTS 运行时"
        case "managed_ffmpeg":
            "受管音频编解码"
        default:
            name.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func impact(for check: PreflightCheckSnapshot) -> String {
        if check.ok {
            return "这项前置条件已满足，不会阻塞当前服务。"
        }
        return "这项前置条件未满足，相关语音能力可能无法启动或使用。"
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

private struct DiagnosticsSummaryView: View {
    let checks: [PreflightCheckSnapshot]
    let isBusy: Bool
    let isRefreshing: Bool
    let action: () -> Void

    private var passedCount: Int { checks.filter(\.ok).count }
    private var failedCount: Int { checks.count - passedCount }

    private var tone: StatusTone {
        if isRefreshing { return .attention }
        if checks.isEmpty { return .attention }
        return failedCount == 0 ? .healthy : .critical
    }

    private var title: String {
        if isRefreshing { return "正在运行诊断" }
        if checks.isEmpty { return "尚未运行诊断" }
        return failedCount == 0 ? "预检通过" : "需要处理的检查"
    }

    private var message: String {
        if isRefreshing { return "正在读取本机环境、配置和模型准备状态。" }
        if checks.isEmpty { return "运行一次诊断，控制台会说明阻塞原因和下一步动作。" }
        if failedCount == 0 { return "当前受管 runtime、配置和模型目录满足控制面检查条件。" }
        return "有 \(failedCount) 项前置条件需要处理，先从右侧详情开始。"
    }

    private var countText: String {
        checks.isEmpty ? "尚未检查" : "\(passedCount)/\(checks.count) 项通过"
    }

    var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.md) {
            Image(systemName: tone.systemImage)
                .font(.title2)
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    Text(title)
                        .font(SpeechRailDesignTokens.Typography.diagnosticsSummary)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    Text(countText)
                        .font(SpeechRailDesignTokens.Typography.metricValue)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
                Text(message)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
            Button("重新运行诊断", action: action)
                .speechRailButton(.primary)
                .disabled(isBusy)
                .accessibilityIdentifier("diagnostics-run")
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.lg)
        .frame(
            maxWidth: .infinity,
            minHeight: SpeechRailDesignTokens.Layout.diagnosticsSummaryHeight,
            maxHeight: SpeechRailDesignTokens.Layout.diagnosticsSummaryHeight,
            alignment: .leading
        )
        .speechRailField()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("diagnostics-summary")
        .accessibilityValue(
            checks.isEmpty ? "尚未检查" : "\(passedCount) 项通过，\(failedCount) 项失败"
        )
    }
}

private struct PreflightCheckRow: View {
    let check: PreflightCheckSnapshot
    let title: String
    let selected: Bool

    var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Image(systemName: check.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(
                    check.ok
                        ? SpeechRailDesignTokens.Color.ready
                        : SpeechRailDesignTokens.Color.critical
                )
                .imageScale(.small)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(title)
                    .font(SpeechRailDesignTokens.Typography.label)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(1)
                Text(check.ok ? "通过" : "失败")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(
                        check.ok
                            ? SpeechRailDesignTokens.Color.ready
                            : SpeechRailDesignTokens.Color.critical
                    )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
        .frame(
            maxWidth: .infinity,
            minHeight: SpeechRailDesignTokens.Layout.diagnosticsRowHeight,
            alignment: .leading
        )
        .background(
            selected ? SpeechRailDesignTokens.Navigation.selectedFill : Color.clear,
            in: .rect(cornerRadius: SpeechRailDesignTokens.Corner.row, style: .continuous)
        )
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.row, style: .continuous)
                    .stroke(SpeechRailDesignTokens.Navigation.focusRing, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(check.ok ? "通过" : "失败")
    }
}
