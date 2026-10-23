import Foundation
import SwiftUI

/// Shared geometry and composition primitives for the native Settings scene.
///
/// Settings uses one layout vocabulary across all tabs so the user's focus moves
/// between pages without learning a new visual grammar.
enum SettingsMetrics {
    static let paneInset = SpeechRailDesignTokens.Settings.paneInset
    static let sectionGap = SpeechRailDesignTokens.Spacing.md
    static let sectionHeadInsetX = SpeechRailDesignTokens.Spacing.micro
    static let sectionHeadInsetY = SpeechRailDesignTokens.Settings.sectionHeadInsetY
    static let rowInsetX = SpeechRailDesignTokens.Spacing.md
    static let rowInsetY = SpeechRailDesignTokens.Settings.rowInsetY
}

@ViewBuilder
func settingsPane<Content: View>(
    @ViewBuilder content: () -> Content
) -> some View {
    ScrollView {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionGap) {
            content()
        }
        .padding(SettingsMetrics.paneInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(SpeechRailDesignTokens.Color.canvas)
}

@ViewBuilder
func settingsSection<Content: View>(
    _ title: String,
    @ViewBuilder rows: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: SettingsMetrics.sectionGap) {
        Text(title)
            .font(SpeechRailDesignTokens.Typography.captionMedium)
            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            .padding(.horizontal, SettingsMetrics.sectionHeadInsetX)
            .padding(.vertical, SettingsMetrics.sectionHeadInsetY)

        VStack(spacing: 0) {
            rows()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            SpeechRailDesignTokens.Color.field,
            in: SpeechRailDesignTokens.Corner.containerShape
        )
        .containerShape(SpeechRailDesignTokens.Corner.containerShape)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}

@ViewBuilder
func settingsRow<Content: View>(
    @ViewBuilder content: () -> Content
) -> some View {
    content()
        .padding(.horizontal, SettingsMetrics.rowInsetX)
        .padding(.vertical, SettingsMetrics.rowInsetY)
        .frame(maxWidth: .infinity, alignment: .leading)
}

var settingsRowSeparator: some View {
    Rectangle()
        .fill(SpeechRailDesignTokens.Color.separator)
        .frame(height: SpeechRailDesignTokens.Spacing.hairline)
}

func settingsValueRow(
    _ title: String,
    value: String,
    valueFont: Font = SpeechRailDesignTokens.Typography.callout
) -> some View {
    HStack(spacing: SpeechRailDesignTokens.Spacing.md) {
        settingsRowLabel(title)
        Spacer(minLength: 0)
        Text(value)
            .font(valueFont)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: true, vertical: false)
    }
    .accessibilityElement(children: .combine)
}

func settingsRowControl() -> some ViewModifier {
    SettingsRowControlModifier()
}

struct SettingsRowControlModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toggleStyle(.switch)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .speechRailPointerCursor()
    }
}

func settingsRowLabel(
    _ title: String,
    caption: String? = nil
) -> some View {
    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Settings.rowLabelSpacing) {
        Text(title)
        if let caption {
            Text(caption)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .lineLimit(SpeechRailDesignTokens.Settings.secondaryTextMaximumLines)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
}

enum SettingsConnectionPresentation {
    static func title(for result: LLMConnectionResult) -> String {
        switch result {
        case .connected:
            "对话服务已连接"
        case .serviceReachableModelMissing:
            "服务已连接，但模型不可用"
        case .responseUnconfirmed:
            "服务已连接，尚未确认能回答"
        case .notChatAPI:
            "这个服务不支持 Chat Completions"
        case .notResponsesAPI:
            "这个服务不支持 Responses"
        case .unreachable:
            "连接未通过"
        case .notConfigured:
            "还没有配置对话服务"
        case .badBaseURL:
            "服务地址无效"
        }
    }

}

/// Connection checks stay inline while running; their results belong to the settings overlay.
struct SettingsConnectionStatus: View {
    let isChecking: Bool

    var body: some View {
        if isChecking {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                ProgressView()
                    .controlSize(.small)
                Text("正在检查连接")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("正在检查连接")
        }
    }
}
