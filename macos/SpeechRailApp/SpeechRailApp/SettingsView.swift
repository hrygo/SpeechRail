import SwiftUI

public struct SettingsView: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        Form {
            ServiceStatusView()
            ProfilePickerView()
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 360)
        .task { await model.refresh() }
    }
}
