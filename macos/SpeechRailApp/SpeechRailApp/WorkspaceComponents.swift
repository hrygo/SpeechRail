import SwiftUI
import SpeechRailControlKit

public enum StatusTone: Sendable {
    case neutral
    case healthy
    case attention
    case critical

    var color: Color {
        switch self {
        case .neutral:
            SpeechRailDesignTokens.Palette.secondaryText
        case .healthy:
            SpeechRailDesignTokens.Palette.healthy
        case .attention:
            SpeechRailDesignTokens.Palette.attention
        case .critical:
            SpeechRailDesignTokens.Palette.critical
        }
    }

    var systemImage: String {
        switch self {
        case .neutral:
            "info.circle.fill"
        case .healthy:
            "checkmark.circle.fill"
        case .attention:
            "exclamationmark.triangle.fill"
        case .critical:
            "xmark.circle.fill"
        }
    }
}

public struct PageIntroView: View {
    public let route: AppRoute

    public init(route: AppRoute) {
        self.route = route
    }

    public var body: some View {
        Text(route.purpose)
            .font(SpeechRailDesignTokens.Typography.secondary)
            .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("(route.title)，(route.purpose)")
    }
}

public struct SectionHeading: View {
    public let title: String
    public let detail: String?

    public init(title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Text(title)
                .font(SpeechRailDesignTokens.Typography.sectionTitle)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
            }
        }
    }
}

public struct StatusBanner: View {
    public let tone: StatusTone
    public let title: String
    public let message: String
    public let actionTitle: String?
    public let action: (() -> Void)?

    public init(
        tone: StatusTone,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.tone = tone
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.md) {
            Image(systemName: tone.systemImage)
                .font(.title3)
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(title)
                    .font(SpeechRailDesignTokens.Typography.windowTitle)
                Text(message)
                    .font(SpeechRailDesignTokens.Typography.secondary)
                    .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
            }
            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailContentSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("(title)，(message)")
    }
}

public struct ServiceStatusBadge: View {
    @Environment(AppModel.self) private var model
    public let compact: Bool

    public init(compact: Bool = false) {
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
            Circle()
                .fill(model.service.ready == true
                    ? SpeechRailDesignTokens.Palette.healthy
                    : SpeechRailDesignTokens.Palette.attention)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            if !compact {
                Text(model.service.ready == true ? "已就绪" : "未就绪")
                    .font(SpeechRailDesignTokens.Typography.caption)
            }
        }
        .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.service.ready == true ? "服务已就绪" : "服务尚未就绪")
    }
}

public struct MetricValue: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let value: String
    public let detail: String

    public init(id: String, title: String, value: String, detail: String) {
        self.id = id
        self.title = title
        self.value = value
        self.detail = detail
    }
}

public struct MetricStrip: View {
    public let metrics: [MetricValue]

    public init(metrics: [MetricValue]) {
        self.metrics = metrics
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                if index > 0 {
                    Divider()
                        .frame(height: 42)
                        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                }
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Text(metric.title)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
                    Text(metric.value)
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                    Text(metric.detail)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.md)
        .speechRailContentSurface()
        .accessibilityElement(children: .contain)
    }
}

public struct OperationBar: View {
    public let operation: OperationSnapshot?
    public let actionTitle: String?
    public let action: (() -> Void)?

    public init(
        operation: OperationSnapshot?,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.operation = operation
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        if let operation {
            HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
                Image(systemName: operationIcon(for: operation.state))
                    .foregroundStyle(operationTone(for: operation.state).color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Text(operationTitle(for: operation.state))
                        .font(SpeechRailDesignTokens.Typography.sectionTitle)
                    if let phase = operation.phase {
                        Text(phase)
                            .font(SpeechRailDesignTokens.Typography.secondary)
                            .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
                    }
                    if let progress = operation.progress,
                       let completed = progress.completedBytes,
                       let expected = progress.expectedBytes,
                       expected > 0
                    {
                        ProgressView(value: Double(completed), total: Double(expected))
                            .controlSize(.small)
                        Text("(ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)) / (ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
                    }
                    if let message = operation.message, !message.isEmpty {
                        Text(message)
                            .font(SpeechRailDesignTokens.Typography.secondary)
                            .foregroundStyle(operationTone(for: operation.state).color)
                    }
                }
                Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
            .speechRailContentSurface()
            .accessibilityElement(children: .combine)
            .accessibilityLabel(operationAccessibilityLabel(for: operation))
        }
    }

    private func operationTitle(for state: OperationState) -> String {
        switch state {
        case .accepted, .running:
            "正在准备模型"
        case .interrupted:
            "上次准备被中断"
        case .committed:
            "模型准备完成"
        case .failed:
            "模型准备失败"
        case .cancelled:
            "模型准备已取消"
        }
    }

    private func operationIcon(for state: OperationState) -> String {
        switch state {
        case .accepted, .running:
            "arrow.down.circle"
        case .interrupted:
            "exclamationmark.triangle"
        case .committed:
            "checkmark.circle"
        case .failed:
            "xmark.circle"
        case .cancelled:
            "stop.circle"
        }
    }

    private func operationTone(for state: OperationState) -> StatusTone {
        switch state {
        case .accepted, .running:
            .attention
        case .interrupted, .failed:
            .critical
        case .committed:
            .healthy
        case .cancelled:
            .neutral
        }
    }

    private func operationAccessibilityLabel(for operation: OperationSnapshot) -> String {
        var parts = [operationTitle(for: operation.state)]
        if let phase = operation.phase { parts.append(phase) }
        if let message = operation.message { parts.append(message) }
        return parts.joined(separator: "，")
    }
}

public struct DeveloperInspector<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        Form {
            Section("开发者详情") {
                content
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: SpeechRailDesignTokens.Layout.inspectorMinimumWidth)
        .background(SpeechRailDesignTokens.Surface.inspectorFill)
    }
}
