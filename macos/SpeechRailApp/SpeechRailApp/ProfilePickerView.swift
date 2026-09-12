import SwiftUI
import SpeechRailControlKit

public struct ProfilePickerView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedProfile: SpeechRailProfile = .balanced

    public init() {}

    public var body: some View {
        GroupBox("模型档位") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("档位", selection: $selectedProfile) {
                    ForEach(SpeechRailProfile.allCases, id: \.self) { profile in
                        Text(profile.rawValue).tag(profile)
                    }
                }
                .pickerStyle(.segmented)
                Button("应用档位") {
                    Task { await model.execute(.profileApply, profile: selectedProfile) }
                }
                .disabled(model.isBusy)
                if let active = model.profile?.preset {
                    Text("当前：\(active.rawValue)")
                        .foregroundStyle(.secondary)
                }
                if let operation = model.operation {
                    Text("操作：\(operation.state.rawValue)")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
