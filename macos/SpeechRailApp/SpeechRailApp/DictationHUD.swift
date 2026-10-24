import AppKit
import Observation
import SwiftUI

// 听写浮层：录制/识别/交付的当前状态，以及交付结果的说明。
//
// 它和字幕带一样是**非激活** `NSPanel`：按下热键时用户正在别的应用里打字，
// 浮层一旦抢焦点，光标就会离开输入框，听写也就失去了意义。
// 与字幕带的区别只有一条：这里不承载可增长正文，尺寸固定、位置固定在主屏底部居中。

@MainActor
public final class DictationHUDWindowController: NSObject {
    private let session: DictationSession
    private var panel: NSPanel?
    private var autoHideTask: Task<Void, Never>?
    private var isObserving = false

    private static let size = NSSize(width: 380, height: 96)

    public init(session: DictationSession) {
        self.session = session
        super.init()
    }

    /// 开始观察会话状态；`install` 幂等。
    public func install() {
        guard !isObserving else { return }
        isObserving = true
        observe()
    }

    /// 状态变化后由观察回调或调用方显式同步一次显隐。
    public func sync() {
        switch session.phase {
        case .idle:
            hide()
        case .recording, .transcribing, .delivering:
            autoHideTask?.cancel()
            autoHideTask = nil
            show()
        case .finished, .failed:
            show()
            scheduleAutoHide()
        }
    }

    public func hide() {
        autoHideTask?.cancel()
        autoHideTask = nil
        panel?.orderOut(nil)
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.session.dismissOutcome()
            self?.hide()
        }
    }

    private func observe() {
        withObservationTracking {
            _ = session.phase
            _ = session.notice
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.sync()
                self.observe()
            }
        }
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        place(panel)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = DictationHUDPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: DictationHUDView(session: session) { [weak self] in
            self?.hide()
        })
        return panel
    }

    private func place(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - Self.size.width / 2,
            y: visible.minY + SpeechRailDesignTokens.Spacing.gutter
        )
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: false)
    }
}

/// 不成为 main、只在需要时成为 key：浮层要能点"复制/关闭"，但不抢走前台应用。
private final class DictationHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct DictationHUDView: View {
    @Bindable var session: DictationSession
    /// 由控制器注入：浮层自己不知道窗口句柄，也不该去 `NSApp.keyWindow` 里猜。
    let onDismiss: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
            statusIcon
                .frame(width: SpeechRailDesignTokens.List.rowIconFrame)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(title)
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                Text(detail)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("关闭") {
                session.dismissOutcome()
                onDismiss()
            }
            .speechRailButton(.quiet)
            .opacity(canDismiss ? 1 : 0)
            .disabled(!canDismiss)
        }
        .padding(SpeechRailDesignTokens.Spacing.sm)
        .frame(width: 380, height: 96, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.container, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.container, style: .continuous)
                .strokeBorder(SpeechRailDesignTokens.Color.separator, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var canDismiss: Bool {
        switch session.phase {
        case .finished, .failed: true
        default: false
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch session.phase {
        case .recording:
            Image(systemName: "record.circle.fill")
                .foregroundStyle(SpeechRailDesignTokens.Color.critical)
        case .transcribing, .delivering:
            ProgressView()
                .controlSize(.small)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(SpeechRailDesignTokens.Color.ready)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(SpeechRailDesignTokens.Color.attention)
        case .idle:
            Image(systemName: "mic")
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
        }
    }

    private var title: String {
        switch session.phase {
        case .idle: "听写"
        case let .recording(target): "正在听写 · \(target.displayName)"
        case .transcribing: "正在识别"
        case .delivering: "正在写入"
        case let .finished(outcome): outcome.delivery.isInserted ? "已写入 \(outcome.target.displayName)" : "已复制，请手动粘贴"
        case .failed: "听写未完成"
        }
    }

    private var detail: String {
        if let notice = session.notice { return notice }
        switch session.phase {
        case .idle:
            return "按 ⌘⇧D 开始。"
        case .recording:
            return "再说一段，或再按一次 ⌘⇧D 结束并写入当前光标位置。"
        case .transcribing:
            return "停止后整段识别，只交付最终文字。"
        case .delivering:
            return "正在核对目标应用，稍候。"
        case let .finished(outcome):
            switch outcome.delivery {
            case .inserted:
                return outcome.text
            case let .copied(reason):
                return "\(Self.copyReason(reason))。文字已放进剪贴板：\(outcome.text)"
            }
        case let .failed(failure):
            return failure.message
        }
    }

    private static func copyReason(_ reason: DictationCopyReason) -> String {
        switch reason {
        case .targetChanged: "结束时的前台应用已经不是开始时的那个"
        case .unsupportedTarget: "目标位置不接受文字输入"
        case .permissionDenied: "没有辅助功能授权，无法代写"
        case .insertionFailed: "写入目标失败"
        }
    }
}
