import SwiftUI
import SpeechRailControlKit

public struct PreflightDiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("speechrail.showDeveloperDetails") private var showDeveloperDetails = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.lg) {
                SurfaceHeaderView(route: .diagnostics)
                GlassEffectContainer(spacing: SpeechRailDesignTokens.Spacing.lg) {
                    explanationPanel
                    ControlAgentStatusView()
                    resultPanel
                    recoveryPanel
                }
                ServiceStatusFooterView()
            }
            .frame(maxWidth: SpeechRailDesignTokens.Layout.contentMaximumWidth, alignment: .leading)
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.xl)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollEdgeEffectStyle(.automatic, for: .top)
        .task {
            model.refreshControlAgentStatus()
            await model.refreshPreflight()
        }
    }

    private var explanationPanel: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Label("先找原因，再恢复服务", systemImage: "stethoscope")
                .font(SpeechRailDesignTokens.Typography.sectionTitle)
            Text("预检只读取运行环境、受管制品和配置的一致性，不会下载模型，也不会改变当前服务。")
                .font(SpeechRailDesignTokens.Typography.body)
                .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailSurface(.panel)
    }

    private var resultPanel: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            HStack {
                Text("预检结果")
                    .font(SpeechRailDesignTokens.Typography.panelTitle)
                Spacer()
                Button("重新运行") {
                    Task { await model.refreshPreflight() }
                }
                .disabled(model.isBusy)
            }
            if model.preflightChecks.isEmpty {
                ContentUnavailableView(
                    "还没有预检结果",
                    systemImage: "waveform.badge.exclamationmark",
                    description: Text("点击重新运行，读取本机服务的可操作诊断。")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ForEach(model.preflightChecks, id: \.name) { check in
                    PreflightCheckRow(check: check)
                }
            }
            if let message = model.message {
                Text(message)
                    .font(SpeechRailDesignTokens.Typography.secondary)
                    .foregroundStyle(SpeechRailDesignTokens.Palette.critical)
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailSurface(.panel)
    }

    private var recoveryPanel: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Text("下一步")
                .font(SpeechRailDesignTokens.Typography.panelTitle)
            Text("普通用户可按失败项提示重新启动服务或准备模型；开发者可把检查名称和脱敏结果用于排障。")
                .font(SpeechRailDesignTokens.Typography.secondary)
                .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
            DisclosureGroup("开发者详情", isExpanded: $showDeveloperDetails) {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    LabeledContent("当前档位", value: model.profile?.preset?.rawValue ?? "未配置")
                    LabeledContent("服务状态", value: model.service.serviceState)
                    LabeledContent("结果数量", value: String(model.preflightChecks.count))
                }
                .font(SpeechRailDesignTokens.Typography.technical)
                .padding(.top, SpeechRailDesignTokens.Spacing.xs)
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailSurface(.panel)
    }
}

private struct PreflightCheckRow: View {
    let check: PreflightCheckSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Image(systemName: check.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(
                    check.ok
                        ? SpeechRailDesignTokens.Palette.success
                        : SpeechRailDesignTokens.Palette.critical
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xxs) {
                Text(check.name)
                    .font(SpeechRailDesignTokens.Typography.panelTitle)
                Text(check.message)
                    .font(SpeechRailDesignTokens.Typography.secondary)
                    .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(check.name)，\(check.ok ? "通过" : "失败")，\(check.message)")
    }
}
