import SwiftUI

public struct ServiceStatusView: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            Text("服务状态")
                .font(SpeechRailDesignTokens.Typography.sectionTitle)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                LabeledContent(
                    "状态",
                    value: SpeechRailRuntimeStatePresentation.text(model.service.serviceState)
                )
                if let ready = model.service.ready {
                    LabeledContent("就绪", value: ready ? "是" : "否")
                }
                HStack {
                    Button("启动") { Task { await model.execute(.start) } }
                        .speechRailButton(.primary)
                    Button("停止", role: .destructive) { Task { await model.execute(.stop) } }
                        .speechRailButton(.destructive)
                    Button("重启") { Task { await model.execute(.restart) } }
                        .speechRailButton(.secondary)
                }
                .disabled(
                    model.isBusy
                        || model.hasActiveMutation
                        || model.isRefreshingService
                        || !model.controlAgentStatus.allowsMutation
                )
                if let message = model.message {
                    Text(SpeechRailOperationMessagePresentation.text(message))
                        .font(SpeechRailDesignTokens.Typography.secondary)
                        .foregroundStyle(SpeechRailDesignTokens.Color.critical)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailContentSurface()
    }
}
