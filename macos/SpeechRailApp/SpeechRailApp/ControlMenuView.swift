import SwiftUI
import SpeechRailControlKit

public struct ControlMenuView: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SpeechRail")
                .font(.headline)
            Text(model.service.serviceState)
                .foregroundStyle(.secondary)
            Button("启动服务") {
                Task { await model.execute(.start) }
            }
            .disabled(model.isBusy)
            Button("停止服务") {
                Task { await model.execute(.stop) }
            }
            .disabled(model.isBusy)
            Divider()
            Button("打开设置") {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .padding(12)
        .task { await model.refresh() }
    }
}
