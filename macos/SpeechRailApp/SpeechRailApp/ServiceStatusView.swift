import SwiftUI

public struct ServiceStatusView: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            Text("服务状态")
                .font(SpeechRailDesignTokens.Typography.panelTitle)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                LabeledContent("状态", value: model.service.serviceState)
                if let ready = model.service.ready {
                    LabeledContent("就绪", value: ready ? "是" : "否")
                }
                HStack {
                    Button("启动") { Task { await model.execute(.start) } }
                    Button("停止") { Task { await model.execute(.stop) } }
                    Button("重启") { Task { await model.execute(.restart) } }
                }
                .disabled(model.isBusy)
                if let message = model.message {
                    Text(message)
                        .font(SpeechRailDesignTokens.Typography.secondary)
                        .foregroundStyle(SpeechRailDesignTokens.Palette.critical)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailContentSurface()
    }
}
