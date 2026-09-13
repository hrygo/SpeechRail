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
        ScrollView {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.lg) {
                PageIntroView(route: .diagnostics)
                conclusionBanner
                diagnosticWorkspace
            }
            .frame(maxWidth: SpeechRailDesignTokens.Layout.contentMaximumWidth, alignment: .leading)
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.xl)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollEdgeEffectStyle(.automatic, for: .top)
        .toolbar {
            ToolbarItem {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("开发者详情", systemImage: "info.circle")
                }
                .help("查看预检字段和当前运行档位")
            }
            ToolbarItem {
                Button {
                    Task { await model.refreshPreflight() }
                } label: {
                    Label("重新运行", systemImage: "arrow.clockwise")
                }
                .help("重新读取本机运行环境和受管配置")
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
                    Text(selectedCheck.message)
                        .font(SpeechRailDesignTokens.Typography.technical)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .textSelection(.enabled)
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

    private var conclusionBanner: some View {
        let tone: StatusTone
        let title: String
        let message: String
        if model.preflightChecks.isEmpty {
            tone = .attention
            title = "还没有预检结果"
            message = "运行一次预检，控制台会把阻塞原因和下一步动作列出来。"
        } else if model.preflightChecks.allSatisfy(\.ok) {
            tone = .healthy
            title = "预检通过"
            message = "当前受管 runtime、配置和模型目录满足控制面检查条件。"
        } else {
            tone = .critical
            title = "需要处理的检查项"
            message = "先选择失败项查看原因，再决定是恢复服务、准备模型还是修正配置。"
        }
        return StatusBanner(
            tone: tone,
            title: title,
            message: message,
            actionTitle: model.preflightChecks.isEmpty ? "运行预检" : nil
        ) {
            Task { await model.refreshPreflight() }
        }
    }

    private var diagnosticWorkspace: some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.lg) {
            checkList
                .frame(width: SpeechRailDesignTokens.Layout.sidebarIdealWidth)
            detailPanel
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var checkList: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            SectionHeading(
                title: "检查项",
                detail: "选择一项查看明确的处理建议。"
            )
            if model.preflightChecks.isEmpty {
                ContentUnavailableView(
                    "还没有检查项",
                    systemImage: "stethoscope",
                    description: Text("运行预检后，检查结果会出现在这里。")
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: SpeechRailDesignTokens.Layout.diagnosticsEmptyListMinimumHeight
                )
            } else {
                VStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    ForEach(model.preflightChecks, id: \.name) { check in
                        Button {
                            selectedCheckName = check.name
                        } label: {
                            PreflightCheckRow(
                                check: check,
                                selected: selectedCheckName == check.name
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("preflight-\(check.name)")
                    }
                }
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailField()
    }

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.lg) {
            if let selectedCheck {
                HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.md) {
                    Image(systemName: selectedCheck.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(
                            selectedCheck.ok
                                ? SpeechRailDesignTokens.Color.ready
                                : SpeechRailDesignTokens.Color.critical
                        )
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                        Text(selectedCheck.name)
                            .font(SpeechRailDesignTokens.Typography.windowTitle)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                        Text(selectedCheck.ok ? "通过" : "失败")
                            .font(SpeechRailDesignTokens.Typography.body)
                            .foregroundStyle(
                                selectedCheck.ok
                                    ? SpeechRailDesignTokens.Color.ready
                                    : SpeechRailDesignTokens.Color.critical
                            )
                    }
                }
                Text(selectedCheck.message)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .textSelection(.enabled)
                Divider()
                SectionHeading(
                    title: "下一步",
                    detail: selectedCheck.ok
                        ? "这项检查不需要操作。继续查看其他检查项即可。"
                        : "先处理这项阻塞，再重新运行预检确认结果。"
                )
                HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    if !selectedCheck.ok {
                        Button("重新运行") {
                            Task { await model.refreshPreflight() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("打开模型") {
                        navigation.request(.models)
                    }
                    .buttonStyle(.bordered)
                    Button("查看服务状态") {
                        navigation.request(.overview)
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                ContentUnavailableView(
                    "选择一项检查",
                    systemImage: "list.bullet.clipboard",
                    description: Text("左侧列表会说明每项检查的用途和当前结果。")
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: SpeechRailDesignTokens.Layout.diagnosticsEmptyDetailMinimumHeight
                )
            }
            if let message = model.message, !message.isEmpty {
                Text(message)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.critical)
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailField()
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

private struct PreflightCheckRow: View {
    let check: PreflightCheckSnapshot
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Image(systemName: check.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(
                    check.ok
                        ? SpeechRailDesignTokens.Color.ready
                        : SpeechRailDesignTokens.Color.critical
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(check.name)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Text(check.ok ? "通过" : "失败")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(SpeechRailDesignTokens.Spacing.sm)
        .background(
            selected ? SpeechRailDesignTokens.Surface.selectedFill : Color.clear,
            in: .rect(cornerRadius: SpeechRailDesignTokens.Corner.row)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(check.name)
        .accessibilityValue(check.ok ? "通过" : "失败")
    }
}
