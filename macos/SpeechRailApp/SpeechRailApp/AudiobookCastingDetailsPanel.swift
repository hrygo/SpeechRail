import SwiftUI

/// 配声说明与试听操作共用一个面板；关闭入口独立于角色列表。
struct AudiobookCastingDetailsPanel<Reasons: View, Actions: View>: View {
    @FocusState private var areReasonsFocused: Bool
    let onClose: () -> Void
    @ViewBuilder var reasons: () -> Reasons
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            HStack {
                Text("试听与分配说明")
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                Spacer()
                Button("关闭", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("audiobook-casting-details-close")
            }
            Divider()
            ScrollView {
                reasons()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
            // A newly opened popover can leave keyboard focus on its trigger.
            // Give the reading area focus so Escape works before the first click.
            .focusable(interactions: .edit)
            .focused($areReasonsFocused)
            .accessibilityIdentifier("audiobook-casting-details-reasons")
            Divider()
            actions()
        }
        .padding(SpeechRailDesignTokens.Spacing.md)
        .frame(
            width: SpeechRailDesignTokens.Layout.Sheet.compactWidth,
            height: SpeechRailDesignTokens.Layout.audiobookCastingDetailsHeight
        )
        .defaultFocus($areReasonsFocused, true)
        .onExitCommand(perform: onClose)
    }
}
