import AppKit
import SwiftUI
import SpeechRailControlKit

public enum SpeechRailButtonLevel: Sendable {
    case primary
    case secondary
    case quiet
    case destructive
}

/// Applies the native macOS button hierarchy without replacing the system's
/// pointer, press, focus, or accessibility behavior.
public struct SpeechRailButtonAppearance: ViewModifier {
    private let level: SpeechRailButtonLevel

    public init(level: SpeechRailButtonLevel) {
        self.level = level
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        Group {
            switch level {
            case .primary:
                content
                    .buttonStyle(.borderedProminent)
                    .tint(SpeechRailDesignTokens.Color.rail)
            case .secondary:
                content
                    .buttonStyle(.bordered)
                    .tint(SpeechRailDesignTokens.Color.rail)
            case .quiet:
                content
                    .buttonStyle(.borderless)
                    .tint(SpeechRailDesignTokens.Color.rail)
            case .destructive:
                content
                    .buttonStyle(.bordered)
                    .tint(SpeechRailDesignTokens.Color.critical)
            }
        }
        .controlSize(.regular)
        .frame(minHeight: SpeechRailDesignTokens.Interaction.minimumHitTarget)
        .speechRailPointerCursor()
    }
}

/// A shared style for custom rows/cards that are buttons but intentionally do
/// not look like standard toolbar or form buttons.
public struct SpeechRailInteractiveButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        SpeechRailInteractiveButtonBody(configuration: configuration)
    }
}

private struct SpeechRailInteractiveButtonBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    let configuration: SpeechRailInteractiveButtonStyle.Configuration

    var body: some View {
        configuration.label
            .frame(
                minWidth: SpeechRailDesignTokens.Interaction.minimumHitTarget,
                minHeight: SpeechRailDesignTokens.Interaction.minimumHitTarget,
                alignment: .leading
            )
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
            .background(backgroundShape)
            .overlay {
                if isFocused {
                    RoundedRectangle(
                        cornerRadius: SpeechRailDesignTokens.Corner.row,
                        style: .continuous
                    )
                    .stroke(
                        SpeechRailDesignTokens.Navigation.focusRing,
                        lineWidth: SpeechRailDesignTokens.Interaction.focusLineWidth
                    )
                    .padding(1)
                }
            }
            .contentShape(
                RoundedRectangle(
                    cornerRadius: SpeechRailDesignTokens.Corner.row,
                    style: .continuous
                )
            )
            .scaleEffect(
                configuration.isPressed && isEnabled && !reduceMotion
                    ? SpeechRailDesignTokens.Interaction.pressedScale
                    : 1
            )
            .opacity(isEnabled ? 1 : SpeechRailDesignTokens.Interaction.disabledOpacity)
            .onHover { hovering in
                isHovered = isEnabled && hovering
            }
            .background {
                SpeechRailCursorRegion(isEnabled: isEnabled)
                    .allowsHitTesting(false)
            }
            .animation(
                reduceMotion ? nil : SpeechRailDesignTokens.Motion.hoverFeedback,
                value: isHovered
            )
            .animation(
                reduceMotion ? nil : SpeechRailDesignTokens.Motion.pressFeedback,
                value: configuration.isPressed
            )
    }

    private var backgroundShape: some View {
        RoundedRectangle(
            cornerRadius: SpeechRailDesignTokens.Corner.row,
            style: .continuous
        )
        .fill(
            !isEnabled
                ? SwiftUI.Color.clear
                : configuration.isPressed
                    ? SpeechRailDesignTokens.Surface.interactionPressed
                    : isHovered
                        ? SpeechRailDesignTokens.Surface.interactionHover
                        : SwiftUI.Color.clear
        )
        .overlay {
            if isHovered && isEnabled {
                RoundedRectangle(
                    cornerRadius: SpeechRailDesignTokens.Corner.row,
                    style: .continuous
                )
                .stroke(
                    SpeechRailDesignTokens.Surface.border,
                    lineWidth: SpeechRailDesignTokens.Stroke.hairline
                )
            }
        }
    }
}

private struct SpeechRailCursorRegion: NSViewRepresentable {
    let isEnabled: Bool

    func makeNSView(context: Context) -> CursorView {
        CursorView(isEnabled: isEnabled)
    }

    func updateNSView(_ nsView: CursorView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.window?.invalidateCursorRects(for: nsView)
    }

    final class CursorView: NSView {
        var isEnabled: Bool

        init(isEnabled: Bool) {
            self.isEnabled = isEnabled
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func resetCursorRects() {
            if isEnabled {
                addCursorRect(bounds, cursor: .pointingHand)
            }
        }
    }
}

public extension View {
    func speechRailButton(_ level: SpeechRailButtonLevel) -> some View {
        modifier(SpeechRailButtonAppearance(level: level))
    }

    func speechRailInteractiveButtonStyle() -> some View {
        buttonStyle(SpeechRailInteractiveButtonStyle())
    }

    /// Shows a pointing hand only for an enabled, genuinely interactive surface.
    /// Static labels and containers never opt into this cursor.
    func speechRailPointerCursor() -> some View {
        modifier(SpeechRailPointerCursorModifier())
    }
}

public struct SpeechRailPointerCursorModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func body(content: Content) -> some View {
        content
            .background {
                SpeechRailCursorRegion(isEnabled: isEnabled)
                    .allowsHitTesting(false)
            }
    }
}

public enum StatusTone: Sendable {
    case neutral
    case healthy
    case attention
    case critical

    var color: Color {
        switch self {
        case .neutral:
            SpeechRailDesignTokens.Color.inkSecondary
        case .healthy:
            SpeechRailDesignTokens.Color.ready
        case .attention:
            SpeechRailDesignTokens.Color.attention
        case .critical:
            SpeechRailDesignTokens.Color.critical
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

enum SpeechRailRuntimeStatePresentation {
    static func text(_ rawValue: String) -> String {
        return switch rawValue.lowercased() {
        case "active":
            "运行中"
        case "warm_standby":
            "温待机"
        case "cold_evicted":
            "已释放"
        case "inactive":
            "未运行"
        case "unconfigured":
            "未配置"
        case "starting":
            "启动中"
        case "stopping":
            "停止中"
        case "loading":
            "加载中"
        case "idle", "stopped":
            "已停止"
        case "degraded":
            "需关注"
        case "failed":
            "失败"
        case "ok":
            "已连接"
        case "healthy":
            "健康"
        case "ready":
            "已就绪"
        case "not_ready":
            "未就绪"
        case "unknown":
            "未知"
        default:
            "未知"
        }
    }
}

enum SpeechRailProfilePresentation {
    static func title(_ profile: SpeechRailProfile) -> String {
        switch profile {
        case .quality:
            "Quality · 创作优先"
        case .balanced:
            "Balanced · 分人和日常"
        case .light:
            "Light · 轻量快速"
        }
    }
}

enum SpeechRailDiarizationPresentation {
    static func text(_ status: DiarizationStatusSnapshot) -> String {
        guard !status.ready else { return "已就绪" }
        return switch status.code?.lowercased() {
        case "diarization_not_configured":
            "未配置"
        case "diarization_alignment_not_configured":
            "缺少对齐模型"
        case "diarization_not_available":
            "运行时不可用"
        case "diarization_invalid_output":
            "运行时异常"
        default:
            status.configured ? "需要处理" : "未配置"
        }
    }
}

enum SpeechRailOperationMessagePresentation {
    static func text(_ rawMessage: String) -> String {
        let normalized = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if rawMessage.unicodeScalars.contains(where: { scalar in
            scalar.value >= 0x4E00 && scalar.value <= 0x9FFF
        }) {
            return rawMessage
        }
        if normalized.hasPrefix("profile") {
            return "档位应用未完成，请重试或打开系统诊断。"
        }
        if normalized.hasPrefix("model preparation was cancelled") {
            return "模型准备已取消。"
        }
        if normalized.hasPrefix("stopping model preparation") {
            return "正在停止模型准备…"
        }
        if normalized.hasPrefix("model preparation") {
            return "模型准备未完成，请重新下载并校验。"
        }
        if normalized.hasPrefix("managed command") {
            return "受管操作未完成，请打开系统诊断查看原因。"
        }
        if normalized.hasPrefix("managed runtime does not support") {
            return "当前控制 Agent 不支持模型管理，请升级 SpeechRail。"
        }
        if normalized.contains("insufficient disk") {
            return "可用磁盘空间不足，请释放空间后重试。"
        }
        if normalized.contains("integrity") || normalized.contains("checksum") {
            return "模型完整性校验未通过，请重新下载并校验。"
        }
        if normalized.hasPrefix("another control operation") {
            return "已有操作正在进行，请稍候。"
        }
        if normalized.hasPrefix("previous model preparation") {
            return "上次模型准备被中断，请重新下载并校验。"
        }
        return "操作未完成，请重试或打开系统诊断。"
    }
}

public struct PageIntroView: View {
    public let route: AppRoute

    public init(route: AppRoute) {
        self.route = route
    }

    public var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.control, style: .continuous)
                .fill(SpeechRailDesignTokens.Color.rail)
                .frame(
                    width: SpeechRailDesignTokens.Control.purposeIndicatorWidth,
                    height: SpeechRailDesignTokens.Control.purposeIndicatorHeight
                )
            Text(route.purpose)
                .font(SpeechRailDesignTokens.Typography.body)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(route.purpose)
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
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// A single, named entry point for low-frequency workspace actions.
///
/// The menu deliberately owns the label so pages cannot drift into a row of
/// unlabeled toolbar glyphs. Primary actions still belong next to the state
/// they change in the page body.
public struct WorkspaceActionsMenu<Content: View>: View {
    private let helpText: String
    private let content: Content

    public init(
        helpText: String,
        @ViewBuilder content: () -> Content
    ) {
        self.helpText = helpText
        self.content = content()
    }

    public var body: some View {
        Menu {
            content
        } label: {
            Label("更多操作", systemImage: "ellipsis")
                .labelStyle(.titleAndIcon)
                .font(SpeechRailDesignTokens.Typography.label)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .frame(minHeight: SpeechRailDesignTokens.Toolbar.controlHeight)
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.regular)
        .accessibilityLabel("更多操作")
        .accessibilityIdentifier("workspace-actions")
        .help(helpText)
        .speechRailPointerCursor()
    }
}

public struct StatusBanner: View {
    public let tone: StatusTone
    public let title: String
    public let message: String
    public let actionTitle: String?
    public let action: (() -> Void)?
    public let actionDisabled: Bool

    public init(
        tone: StatusTone,
        title: String,
        message: String,
        actionTitle: String? = nil,
        actionDisabled: Bool = false,
        action: (() -> Void)? = nil
    ) {
        self.tone = tone
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.actionDisabled = actionDisabled
    }

    public var body: some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.md) {
            Image(systemName: tone.systemImage)
                .font(SpeechRailDesignTokens.Typography.statusIcon)
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(title)
                    .font(SpeechRailDesignTokens.Typography.statusTitle)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Text(message)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .speechRailButton(.primary)
                    .disabled(actionDisabled)
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.md)
        .speechRailField()
        .accessibilityElement(children: .contain)
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
                .fill(statusColor)
                .frame(
                    width: SpeechRailDesignTokens.Control.statusIndicatorDiameter,
                    height: SpeechRailDesignTokens.Control.statusIndicatorDiameter
                )
                .accessibilityHidden(true)
            if !compact {
                Text(statusText)
                    .font(SpeechRailDesignTokens.Typography.workspaceContext)
                    .foregroundStyle(statusColor)
            }
        }
        .frame(minHeight: SpeechRailDesignTokens.Toolbar.controlHeight)
        .fixedSize(horizontal: true, vertical: false)
        .help("服务状态：\(statusText)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("服务\(statusText)")
    }

    private var isUnavailable: Bool {
        model.service.serviceState == "unavailable" || model.healthMessage != nil
    }

    private var statusText: String {
        if model.serviceOperation?.phase.isActive == true {
            return "处理中"
        }
        if isUnavailable { return "不可用" }
        if model.service.ready == true { return "已就绪" }
        return "未就绪"
    }

    private var statusColor: Color {
        if model.serviceOperation?.phase.isActive == true {
            return SpeechRailDesignTokens.Color.attention
        }
        if model.service.ready == true { return SpeechRailDesignTokens.Color.ready }
        if isUnavailable { return SpeechRailDesignTokens.Color.critical }
        return SpeechRailDesignTokens.Color.attention
    }
}

public struct ServiceOperationStatusView: View {
    public let operation: ServiceOperationStatus
    public let actionTitle: String?
    public let action: (() -> Void)?

    public init(
        operation: ServiceOperationStatus,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.operation = operation
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Image(systemName: operationIcon)
                .font(SpeechRailDesignTokens.Typography.statusIcon)
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(operationTitle)
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                if operation.phase.isActive {
                    ProgressView()
                        .controlSize(.small)
                        .tint(SpeechRailDesignTokens.Color.rail)
                }
                Text(operation.message ?? defaultMessage)
                    .font(SpeechRailDesignTokens.Typography.secondary)
                    .foregroundStyle(tone.color)
                    .lineLimit(2)
            }
            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .speechRailButton(.secondary)
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.md)
        .speechRailField()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(operationTitle)，\(operation.message ?? defaultMessage)")
    }

    private var commandTitle: String {
        switch operation.command {
        case .start:
            "启动服务"
        case .stop:
            "停止服务"
        case .restart:
            "重启服务"
        default:
            "服务操作"
        }
    }

    private var operationTitle: String {
        switch operation.phase {
        case .starting:
            "正在启动服务"
        case .stopping:
            "正在停止服务"
        case .restarting:
            "正在重启服务"
        case .healthChecking:
            "健康检查中"
        case .completed:
            "\(commandTitle)已完成"
        case .failed:
            "\(commandTitle)未完成"
        }
    }

    private var defaultMessage: String {
        switch operation.phase {
        case .starting:
            "正在请求受管服务启动…"
        case .stopping:
            "正在请求受管服务停止…"
        case .restarting:
            "正在请求受管服务重启…"
        case .healthChecking:
            "正在读取服务与能力状态…"
        case .completed:
            "服务命令已完成。"
        case .failed:
            "服务命令未完成，请重新读取或打开诊断。"
        }
    }

    private var operationIcon: String {
        switch operation.phase {
        case .starting:
            "play.circle"
        case .stopping:
            "stop.circle"
        case .restarting, .healthChecking:
            "arrow.clockwise.circle"
        case .completed:
            "checkmark.circle"
        case .failed:
            "xmark.circle"
        }
    }

    private var tone: StatusTone {
        switch operation.phase {
        case .starting, .stopping, .restarting, .healthChecking:
            .attention
        case .completed:
            .healthy
        case .failed:
            .critical
        }
    }
}

public struct ServiceOperationCompactStatus: View {
    public let operation: ServiceOperationStatus

    public init(operation: ServiceOperationStatus) {
        self.operation = operation
    }

    public var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            if operation.phase.isActive {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: operation.phase == .failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(SpeechRailDesignTokens.Typography.secondary)
                .lineLimit(1)
            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
        }
        .foregroundStyle(operation.phase == .failed ? SpeechRailDesignTokens.Color.critical : SpeechRailDesignTokens.Color.inkSecondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    private var title: String {
        let command = switch operation.command {
        case .start: "启动服务"
        case .stop: "停止服务"
        case .restart: "重启服务"
        default: "服务操作"
        }
        return switch operation.phase {
        case .starting: "正在启动服务…"
        case .stopping: "正在停止服务…"
        case .restarting: "正在重启服务…"
        case .healthChecking: "健康检查中…"
        case .completed: "\(command)已完成"
        case .failed: "\(command)未完成"
        }
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

private struct MetricValueView: View {
    let metric: MetricValue

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Text(metric.title)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .lineLimit(1)
            Text(metric.value)
                .font(SpeechRailDesignTokens.Typography.metricValue)
                .monospacedDigit()
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineLimit(1)
            Text(metric.detail)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .lineLimit(1)
        }
        .frame(
            minWidth: SpeechRailDesignTokens.Layout.metricMinimumWidth,
            maxWidth: .infinity,
            alignment: .leading
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(metric.title)
        .accessibilityValue("\(metric.value)，\(metric.detail)")
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
                        .frame(height: SpeechRailDesignTokens.Layout.compactDividerHeight)
                        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                }
                MetricValueView(metric: metric)
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.md)
        .speechRailField()
        .accessibilityElement(children: .contain)
    }
}

public struct MetricGrid: View {
    public let metrics: [MetricValue]
    private let columnCount: Int

    public init(
        metrics: [MetricValue],
        columnCount: Int = SpeechRailDesignTokens.Layout.metricColumnCount
    ) {
        self.metrics = metrics
        self.columnCount = max(1, columnCount)
    }

    public var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(
                    .flexible(minimum: SpeechRailDesignTokens.Layout.metricMinimumWidth),
                    spacing: SpeechRailDesignTokens.Spacing.md
                ),
                count: columnCount
            ),
            alignment: .leading,
            spacing: SpeechRailDesignTokens.Spacing.md
        ) {
            ForEach(metrics) { metric in
                MetricValueView(metric: metric)
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.md)
        .speechRailField()
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
                Image(systemName: operationIcon(for: operation))
                    .font(SpeechRailDesignTokens.Typography.statusIcon)
                    .foregroundStyle(operationTone(for: operation.state).color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Text(operationTitle(for: operation))
                            .font(SpeechRailDesignTokens.Typography.sectionTitle)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                        if let phase = operation.phase {
                            Text("· \(operationPhaseText(phase))")
                                .font(SpeechRailDesignTokens.Typography.secondary)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        }
                    }
                    if let progress = operation.progress,
                       let completed = progress.completedBytes,
                       let expected = progress.expectedBytes,
                       expected > 0
                    {
                        let percent = min(1.0, max(0.0, Double(completed) / Double(expected)))
                        ProgressView(value: percent)
                            .controlSize(.small)
                            .tint(SpeechRailDesignTokens.Color.rail)
                        HStack {
                            Text("\(ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))")
                            Spacer()
                            Text(String(format: "%.1f%%", percent * 100))
                        }
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    }
                    if let progress = operation.progress {
                        if let artifactKey = progress.artifactKey ?? progress.file {
                            Text("当前制品：\(artifactKey)")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                .lineLimit(1)
                        }
                        if let file = progress.file, progress.artifactKey != nil {
                            Text("当前文件：\(file)")
                                .font(SpeechRailDesignTokens.Typography.technical)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                                .lineLimit(1)
                        }
                        if progress.completedBytes == nil || progress.expectedBytes == nil {
                            Text("字节进度：未提供")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        }
                    }
                    if operation.command == .modelPrepare {
                        Text("速度与预计时间：协议未提供")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    }
                    if let message = operation.message, !message.isEmpty {
                        Text(SpeechRailOperationMessagePresentation.text(message))
                            .font(SpeechRailDesignTokens.Typography.secondary)
                            .foregroundStyle(operationTone(for: operation.state).color)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .speechRailButton(.secondary)
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
            .speechRailField()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(operationAccessibilityLabel(for: operation))
        }
    }

    private func operationTitle(for operation: OperationSnapshot) -> String {
        let applyingProfile = operation.command == .profileApply
        return switch operation.state {
        case .accepted, .running:
            applyingProfile ? "正在应用档位" : "正在准备模型"
        case .interrupted:
            applyingProfile ? "档位应用被中断" : "上次模型准备被中断"
        case .committed:
            applyingProfile ? "档位应用完成" : "模型准备完成"
        case .failed:
            applyingProfile ? "档位应用失败" : "模型准备失败"
        case .cancelled:
            applyingProfile ? "档位应用已取消" : "模型准备已取消"
        }
    }

    private func operationIcon(for operation: OperationSnapshot) -> String {
        switch operation.state {
        case .accepted, .running:
            operation.command == .profileApply
                ? "arrow.triangle.2.circlepath.circle"
                : "arrow.down.circle"
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

    private func operationPhaseText(_ phase: String) -> String {
        switch phase.lowercased() {
        case "accepted":
            "已接收"
        case "prepare", "preparing":
            "准备中"
        case "download", "downloading":
            "下载中"
        case "verify", "verifying":
            "校验中"
        case "apply", "applying":
            "应用中"
        case "reload", "reloading":
            "重载中"
        case "smoke", "smoke_test":
            "健康检查中"
        case "publish", "publishing":
            "发布中"
        case "cache_hit":
            "已存在"
        case "committed", "completed":
            "已完成"
        case "failed":
            "失败"
        case "cancelled", "canceled":
            "已取消"
        case "cancelling", "canceling":
            "正在停止"
        case "interrupted":
            "已中断"
        default:
            "处理中"
        }
    }

    private func operationAccessibilityLabel(for operation: OperationSnapshot) -> String {
        var parts = [operationTitle(for: operation)]
        if let phase = operation.phase { parts.append(operationPhaseText(phase)) }
        if let message = operation.message {
            parts.append(SpeechRailOperationMessagePresentation.text(message))
        }
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
                    .accessibilityElement(children: .contain)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: SpeechRailDesignTokens.Layout.inspectorMinimumWidth)
        .background(SpeechRailDesignTokens.Surface.inspectorFill)
    }
}
