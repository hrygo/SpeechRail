import SwiftUI

public struct ServiceStatusView: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        GroupBox("服务状态") {
            VStack(alignment: .leading, spacing: 8) {
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
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
