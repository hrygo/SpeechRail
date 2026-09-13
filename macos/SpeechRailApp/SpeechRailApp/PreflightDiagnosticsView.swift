import AppKit
import SpeechRailControlKit
import SwiftUI

public struct PreflightDiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    @AppStorage("speechrail.showDeveloperDetails") private var showDeveloperDetails = false
    @State private var selectedCheckName: String?
    @State private var showInspector = false
    @State private var reportMessage: String?

    public init() {}

    public var body: some View {
        PageScaffold(route: .diagnostics, scrollable: false) {
            DiagnosticsSummaryView(
                checks: model.preflightChecks,
                isBusy: model.isBusy || model.isRefreshingPreflight,
                isRefreshing: model.isRefreshingPreflight,
                errorMessage: model.preflightMessage,
                lastUpdated: model.lastPreflightRefresh,
                action: { Task { await model.refreshPreflight() } }
            )
            if let reportMessage {
                Label(reportMessage, systemImage: "checkmark.circle.fill")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ready)
                    .transition(.opacity)
            }
            diagnosticWorkspace
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                WorkspaceActionsMenu(helpText: "查看预检上下文与脱敏技术详情") {
                    Button {
                        copyDiagnosticReport()
                    } label: {
                        Label("复制脱敏诊断报告", systemImage: "doc.on.clipboard")
                    }
                    .disabled(model.isRefreshingPreflight || model.preflightChecks.isEmpty)
                    Divider()
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
            .sharedBackgroundVisibility(.hidden)
        }
        .inspector(isPresented: $showInspector) {
            DeveloperInspector {
                SectionHeading(
                    title: "预检上下文",
                    detail: "预检只读取环境、制品和配置，不会下载模型或改变服务。"
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
            showInspector = showDeveloperDetails
            model.refreshControlAgentStatus()
            await model.refreshModelsAndHealth()
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
                    systemImage: AppRoute.diagnostics.systemImage,
                    description: Text("运行诊断后，结果会出现在这里。")
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: SpeechRailDesignTokens.Layout.diagnosticsEmptyListMinimumHeight
                )
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
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
        .speechRailContentSurface()
        .accessibilityIdentifier("diagnostics-check-list")
    }

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            if let selectedCheck {
                HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
                    Image(systemName: selectedCheck.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(SpeechRailDesignTokens.Typography.statusIcon)
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
                detailFact("建议动作", recoveryPath(for: selectedCheck).detail)

                if isModelRelatedCheck(selectedCheck) {
                    modelEvidence
                }

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
                        recoveryAction(for: selectedCheck)
                    }
                }

                DisclosureGroup("开发者详情") {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        LabeledContent("检查标识", value: selectedCheck.name)
                        LabeledContent("安全技术结果", value: safeTechnicalResult(for: selectedCheck))
                        LabeledContent("结果", value: selectedCheck.ok ? "通过" : "失败")
                        LabeledContent("运行档位", value: displayedHealth?.profile?.rawValue ?? "未读取")
                        LabeledContent("配置档位", value: model.profile?.preset?.rawValue ?? "未配置")
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

            if let message = model.preflightMessage, !message.isEmpty {
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
        .speechRailContentSurface()
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

    @ViewBuilder
    private func recoveryAction(for check: PreflightCheckSnapshot) -> some View {
        switch recoveryPath(for: check).route {
        case .models:
            Button {
                navigation.request(.models)
            } label: {
                Label("打开模型管理", systemImage: AppRoute.models.systemImage)
            }
            .speechRailButton(.secondary)
        case .overview:
            Button {
                navigation.request(.overview)
            } label: {
                Label("查看服务状态", systemImage: AppRoute.overview.systemImage)
            }
            .speechRailButton(.secondary)
        case .developer:
            Button {
                copyDiagnosticReport()
            } label: {
                Label("复制脱敏报告", systemImage: "doc.on.clipboard")
            }
            .speechRailButton(.secondary)
        }
    }

    private var modelEvidence: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Divider()
            SectionHeading(
                title: "模型证据",
                detail: "以下与模型页使用同一组 XPC model.catalog / model.status 快照；使用状态再结合当前 health 和 worker 生命周期判断。"
            )
            if let catalog = model.modelCatalog, let status = model.modelStatus {
                let statuses = status.artifacts + status.diarization
                let verifiedCount = statuses.filter {
                    $0.state == .verified && $0.integrity == .verified
                }.count
                detailFact("受管制品", "\(catalog.artifacts.count) 个目录项")
                detailFact("完整性", "\(verifiedCount)/\(statuses.count) 个制品已通过校验")
                detailFact(
                    "当前服务",
                    displayedHealth?.profile.map(SpeechRailProfilePresentation.title) ?? "运行态未读取"
                )
            } else {
                Text("模型 XPC 快照尚未读取，不能在诊断页推断模型存在或使用状态。")
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
        }
        .padding(.top, SpeechRailDesignTokens.Spacing.xs)
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
                detail: "打开模型管理核对目标档位的目录、文件完整性和当前服务使用状态；仅在制品通过校验后应用档位。"
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
                detail: "先打开服务状态确认控制通道和受管 runtime，再重新运行预检；该页面不自动改写配置或权限。"
            )
        }
        return DiagnosticRecoveryPath(
            route: .developer,
            detail: "没有安全的自动修复动作；复制脱敏报告交给开发者，报告不包含凭据、原始音频或本地绝对路径。"
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
        let runtimeProfile = displayedHealth?.profile?.rawValue ?? "未读取"
        let configuredProfile = model.profile?.preset?.rawValue ?? "未配置"
        let ready = displayedHealth?.ready.map { $0 ? "true" : "false" } ?? "未读取"
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
        runtime_profile: \(runtimeProfile)
        configured_profile: \(configuredProfile)
        service_state: \(safeIdentifier(model.service.serviceState))
        health_ready: \(ready)
        health_failure: \(healthFailureSummary)
        control_plane: \(model.controlPlaneMessage == nil ? "available" : "unavailable")
        checks: \(model.preflightChecks.filter(\.ok).count)/\(model.preflightChecks.count) passed

        \(checks)
        """
        _ = NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(report, forType: .string) {
            withAnimation(.easeOut(duration: SpeechRailDesignTokens.Motion.standardDuration)) {
                reportMessage = "已复制脱敏诊断报告"
            }
        } else {
            reportMessage = "复制失败，请稍后重试"
        }
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
            return "受管运行时或音频编解码链路不完整，服务可能无法启动或无法交付音频。"
        }
        if normalized.contains("config") || normalized.contains("permission") || normalized.contains("settings") {
            return "服务无法安全读取配置；当前运行档位和能力结论不能视为可信。"
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
}

private struct DiagnosticsSummaryView: View {
    let checks: [PreflightCheckSnapshot]
    let isBusy: Bool
    let isRefreshing: Bool
    let errorMessage: String?
    let lastUpdated: Date?
    let action: () -> Void

    private var passedCount: Int { checks.filter(\.ok).count }
    private var failedCount: Int { checks.count - passedCount }

    private var tone: StatusTone {
        if isRefreshing { return .attention }
        if let errorMessage, !errorMessage.isEmpty { return .critical }
        if checks.isEmpty { return .attention }
        return failedCount == 0 ? .healthy : .critical
    }

    private var title: String {
        if isRefreshing { return "正在运行诊断" }
        if checks.isEmpty, errorMessage != nil { return "预检读取失败" }
        if checks.isEmpty { return "尚未运行诊断" }
        return failedCount == 0 ? "预检通过" : "需要处理的检查"
    }

    private var message: String {
        if isRefreshing { return "正在读取本机环境、配置和模型准备状态。" }
        if let errorMessage, !errorMessage.isEmpty {
            let prefix = checks.isEmpty ? "无法读取预检结果" : "保留上次结果；本次读取失败"
            return "\(prefix)：\(SpeechRailOperationMessagePresentation.text(errorMessage))"
        }
        if checks.isEmpty { return "运行一次诊断，控制台会说明阻塞原因和下一步动作。" }
        if failedCount == 0 { return "当前受管 runtime、配置和模型目录满足控制面检查条件。" }
        return "有 \(failedCount) 项前置条件需要处理，先从右侧详情开始。"
    }

    private var countText: String {
        checks.isEmpty ? "尚未检查" : "\(passedCount)/\(checks.count) 项通过"
    }

    private var updatedText: String? {
        lastUpdated.map { "更新于 \($0.formatted(date: .omitted, time: .shortened))" }
    }

    var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.md) {
            Image(systemName: tone.systemImage)
                .font(SpeechRailDesignTokens.Typography.statusGlyph)
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
                HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    Text(message)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .lineLimit(1)
                    if let updatedText {
                        Text(updatedText)
                            .font(SpeechRailDesignTokens.Typography.technical)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            .lineLimit(1)
                    }
                }
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
        .speechRailContentSurface()
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
                    .stroke(
                        SpeechRailDesignTokens.Navigation.focusRing,
                        lineWidth: SpeechRailDesignTokens.Stroke.strong
                    )
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(check.ok ? "通过" : "失败")
    }
}
