import Foundation
import SwiftUI

/// Shared geometry and composition primitives for the native Settings scene.
///
/// Settings uses one layout vocabulary across all tabs so the user's focus moves
/// between pages without learning a new visual grammar.
enum SettingsMetrics {
    static let paneInset: CGFloat = 13
    static let sectionGap = SpeechRailDesignTokens.Spacing.md
    static let sectionHeadInsetX = SpeechRailDesignTokens.Spacing.micro
    static let sectionHeadInsetY: CGFloat = 6
    static let rowInsetX = SpeechRailDesignTokens.Spacing.md
    static let rowInsetY: CGFloat = 11
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
        case .notResponsesAPI:
            "这个服务不支持对话"
        case .unreachable:
            "连接未通过"
        case .notConfigured:
            "还没有配置对话服务"
        case .badBaseURL:
            "服务地址无效"
        }
    }

    static func toneColor(for result: LLMConnectionResult) -> Color {
        result.isReady ? .green : .orange
    }
}

struct SettingsConnectionStatus: View {
    let result: LLMConnectionResult?
    let isChecking: Bool
    let saveError: String?
    let saveFailurePrefix: String

    init(
        result: LLMConnectionResult?,
        isChecking: Bool,
        saveError: String?,
        saveFailurePrefix: String = "连接已通过，但密钥未保存"
    ) {
        self.result = result
        self.isChecking = isChecking
        self.saveError = saveError
        self.saveFailurePrefix = saveFailurePrefix
    }

    var body: some View {
        Group {
            if isChecking {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在检查连接")
                }
            } else if let result {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Label {
                        Text(SettingsConnectionPresentation.title(for: result))
                            .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    } icon: {
                        Image(systemName: result.isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(SettingsConnectionPresentation.toneColor(for: result))
                    }

                    Text(
                        saveError.map { "\(saveFailurePrefix)：\($0)" }
                            ?? result.detail
                    )
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        if isChecking {
            return "正在检查连接"
        }
        guard let result else { return "" }
        let title = SettingsConnectionPresentation.title(for: result)
        let detail = saveError.map { "\(saveFailurePrefix)：\($0)" } ?? result.detail
        return "\(title)。\(detail)"
    }
}
