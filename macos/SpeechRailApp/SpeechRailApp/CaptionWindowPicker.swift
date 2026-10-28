import AppKit
import CoreGraphics
import SwiftUI

// MARK: - 窗口元数据（零 TCC 权限）

/// 单个可见应用窗口的无害投影。
///
/// **安全红线**：绝不读取 `kCGWindowName`，杜绝系统弹出 TCC 录屏权限警告。
public struct CaptionWindowInfo: Identifiable, Sendable {
    public let id: CGWindowID
    public let pid: pid_t
    public let bundleID: String
    public let appName: String
    public let icon: NSImage?
    public let bounds: CGRect // AppKit 屏幕坐标系
    public let isAudioActive: Bool

    public init(
        id: CGWindowID,
        pid: pid_t,
        bundleID: String,
        appName: String,
        icon: NSImage?,
        bounds: CGRect,
        isAudioActive: Bool
    ) {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.icon = icon
        self.bounds = bounds
        self.isAudioActive = isAudioActive
    }
}

// MARK: - 窗口检索服务

public enum CaptionWindowCatalog {
    /// 获取当前屏幕上所有普通及置顶悬浮应用窗口（不读取窗口标题，仅读取 PID / Layer / Bounds）。
    ///
    /// - 支持 layer 0（普通窗口）至 layer 3（置顶播放器/画中画/会议浮窗），杜绝遗漏。
    public static func visibleAppWindows(excludingBundleID: String? = nil) -> [CaptionWindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let activeAudioBundles = CoreAudioTapCapture.activeAudioBundleIDs()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 1080

        var results: [CaptionWindowInfo] = []

        for dict in list {
            guard let layer = dict[kCGWindowLayer as String] as? Int, layer >= 0 && layer <= 3 else { continue }
            guard let alpha = dict[kCGWindowAlpha as String] as? Double, alpha > 0.5 else { continue }
            guard let winID = dict[kCGWindowNumber as String] as? CGWindowID else { continue }
            guard let pid = dict[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID else { continue }

            guard let boundsDict = dict[kCGWindowBounds as String] as? [String: Any],
                  let quartzRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  quartzRect.width >= 120, quartzRect.height >= 100
            else { continue }

            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular
            else { continue }

            let bundleID = app.bundleIdentifier ?? ""
            if let excludingBundleID, bundleID == excludingBundleID { continue }
            if bundleID.hasPrefix("com.speechrail.") { continue }

            let appName = app.localizedName ?? bundleID
            let isAudioActive = activeAudioBundles.contains(bundleID)

            // Quartz 全局坐标系转换为 AppKit 全局屏幕坐标系（以主屏左下角为原点）
            let appKitY = primaryScreenHeight - (quartzRect.origin.y + quartzRect.height)
            let appKitRect = CGRect(
                x: quartzRect.origin.x,
                y: appKitY,
                width: quartzRect.width,
                height: quartzRect.height
            )

            results.append(
                CaptionWindowInfo(
                    id: winID,
                    pid: pid,
                    bundleID: bundleID,
                    appName: appName,
                    icon: app.icon,
                    bounds: appKitRect,
                    isAudioActive: isAudioActive
                )
            )
        }

        return results
    }

    /// 提取正在出声或有音频通道的应用列表（去重，兼顾在屏窗口与最小化/其他空间的发声应用）。
    public static func activeAudioApps(excludingBundleID: String? = nil) -> [CaptionTargetApp] {
        let windows = visibleAppWindows(excludingBundleID: excludingBundleID)
        let activeAudioBundles = CoreAudioTapCapture.activeAudioBundleIDs()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var seenBundles = Set<String>()
        var apps: [CaptionTargetApp] = []

        // 1. 先放当前在屏且正在发声的应用窗口（携带精确 windowID）
        for win in windows where win.isAudioActive {
            if seenBundles.insert(win.bundleID).inserted {
                apps.append(CaptionTargetApp(
                    bundleID: win.bundleID,
                    appName: win.appName,
                    windowID: win.id,
                    isPlayingAudio: true,
                    pid: win.pid
                ))
            }
        }

        // 2. 补充正在发声但窗口最小化或位于其他全屏桌面空间的应用
        for running in NSWorkspace.shared.runningApplications where running.activationPolicy == .regular {
            guard running.processIdentifier != ownPID,
                  let bundleID = running.bundleIdentifier,
                  bundleID != excludingBundleID,
                  !bundleID.hasPrefix("com.speechrail."),
                  activeAudioBundles.contains(bundleID),
                  seenBundles.insert(bundleID).inserted
            else { continue }
            apps.append(CaptionTargetApp(
                bundleID: bundleID,
                appName: running.localizedName ?? bundleID,
                windowID: nil,
                isPlayingAudio: true,
                pid: running.processIdentifier
            ))
        }
        return apps
    }
}

// MARK: - 窗口拾取全屏覆盖层视图

public struct WindowPickerOverlayView: View {
    public let screenFrame: CGRect
    public let windows: [CaptionWindowInfo]
    public let audioApps: [CaptionTargetApp]
    public let onSelectTarget: (CaptionAudioTarget) -> Void
    public let onCancel: () -> Void

    @State private var mouseLocation: CGPoint = .zero
    @State private var hoveredWindow: CaptionWindowInfo?

    public init(
        screenFrame: CGRect,
        windows: [CaptionWindowInfo],
        audioApps: [CaptionTargetApp],
        onSelectTarget: @escaping (CaptionAudioTarget) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.screenFrame = screenFrame
        self.windows = windows
        self.audioApps = audioApps
        self.onSelectTarget = onSelectTarget
        self.onCancel = onCancel
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // 半透明遮罩底色（支持空间坐标点击命中与桌面空白明确取消）
                Color.black.opacity(0.18)
                    .contentShape(Rectangle())
                    .onTapGesture { point in
                        if let tapped = windowAt(localPoint: point, proxy: proxy) {
                            onSelectTarget(.app(CaptionTargetApp(
                                bundleID: tapped.bundleID,
                                appName: tapped.appName,
                                windowID: tapped.id,
                                isPlayingAudio: tapped.isAudioActive,
                                pid: tapped.pid
                            )))
                        } else {
                            // 点击在无窗口的空白桌面处明确退出
                            onCancel()
                        }
                    }

                // 高亮选中窗口边框与胶囊
                if let hovered = hoveredWindow {
                    let localFrame = screenToLocal(hovered.bounds, proxy: proxy)
                    windowHighlight(hovered: hovered, localFrame: localFrame)
                }

                // 顶端指引与底部快捷栏
                VStack {
                    topGuidanceBanner
                        .padding(.top, SpeechRailDesignTokens.CaptionBand.windowPickerTopBannerInset)
                    Spacer()
                    bottomControlBar
                        .padding(.bottom, SpeechRailDesignTokens.CaptionBand.windowPickerBottomBarInset)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    mouseLocation = location
                    hoveredWindow = windowAt(localPoint: location, proxy: proxy)
                case .ended:
                    hoveredWindow = nil
                }
            }
        }
        .ignoresSafeArea()
    }

    private var topGuidanceBanner: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Image(systemName: "macwindow.badge.plus")
                .font(SpeechRailDesignTokens.Typography.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.rail)
            Text("移动鼠标轻点任意窗口，字幕带将智能吸附于其底部")
                .font(SpeechRailDesignTokens.Typography.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        .background(
            Capsule()
                .fill(SpeechRailDesignTokens.Surface.floatingToolbarMaterial)
        )
        .overlay(
            Capsule()
                .stroke(
                    SpeechRailDesignTokens.Color.separator,
                    lineWidth: SpeechRailDesignTokens.Stroke.hairline
                )
        )
        .shadow(color: .black.opacity(0.15), radius: SpeechRailDesignTokens.CaptionBand.windowPickerShadowRadius, x: 0, y: 4)
    }

    /// 将 AppKit 全局屏幕坐标系精确投影至当前 View 所在的屏幕本地坐标系（支持多屏与任意原点）。
    private func screenToLocal(_ screenRect: CGRect, proxy: GeometryProxy) -> CGRect {
        let localX = screenRect.origin.x - screenFrame.origin.x
        let localY = (screenFrame.origin.y + screenFrame.height) - (screenRect.origin.y + screenRect.height)
        return CGRect(x: localX, y: localY, width: screenRect.width, height: screenRect.height)
    }

    private func windowAt(localPoint: CGPoint, proxy: GeometryProxy) -> CaptionWindowInfo? {
        for window in windows {
            let localRect = screenToLocal(window.bounds, proxy: proxy)
            if localRect.contains(localPoint) {
                return window
            }
        }
        return nil
    }

    @ViewBuilder
    private func windowHighlight(hovered: CaptionWindowInfo, localFrame: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: SpeechRailDesignTokens.CaptionBand.windowPickerCornerRadius)
                .stroke(SpeechRailDesignTokens.Color.rail, lineWidth: SpeechRailDesignTokens.CaptionBand.windowPickerBorderWidth)
                .background(
                    RoundedRectangle(cornerRadius: SpeechRailDesignTokens.CaptionBand.windowPickerCornerRadius)
                        .fill(SpeechRailDesignTokens.Color.rail.opacity(0.06))
                )
                .frame(width: max(localFrame.width, 0), height: max(localFrame.height, 0))

            // 顶端 App 胶囊标牌
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                if let icon = hovered.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(
                            width: SpeechRailDesignTokens.CaptionBand.windowPickerAppIconSize,
                            height: SpeechRailDesignTokens.CaptionBand.windowPickerAppIconSize
                        )
                }
                Text(hovered.appName)
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)

                if hovered.isAudioActive {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(SpeechRailDesignTokens.Typography.caption)
                        Text("有声音")
                            .font(SpeechRailDesignTokens.Typography.caption)
                    }
                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                    .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
                    .background(SpeechRailDesignTokens.Color.rail.opacity(0.12), in: Capsule())
                }
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.CaptionBand.windowPickerBadgeCornerRadius)
            )
            .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
            .offset(x: SpeechRailDesignTokens.Spacing.sm, y: SpeechRailDesignTokens.Spacing.sm)

            // 底部字幕带吸附落点预览剪影，直觉展示选中后字幕条将贴合的位置
            if localFrame.width >= 260 && localFrame.height >= 160 {
                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "captions.bubble.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                        Text("点击此窗口 · 实时字幕带将智能吸附于底部")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .frame(width: min(max(localFrame.width - 48, 220), 520))
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(SpeechRailDesignTokens.Color.rail.opacity(0.45), lineWidth: 1)
                    )
                    .padding(.bottom, 18)
                }
                .frame(width: max(localFrame.width, 0), height: max(localFrame.height, 0))
            }
        }
        .position(x: localFrame.midX, y: localFrame.midY)
        .allowsHitTesting(false)
    }

    /// 智能候选应用列表：优先展示发声应用，随后补充其他可见普通应用，避免遮挡窗口无法选取。
    private var suggestedApps: [CaptionTargetApp] {
        var seen = Set<String>()
        var list: [CaptionTargetApp] = []

        // 1. 发声应用优先
        for app in audioApps {
            seen.insert(app.bundleID)
            list.append(app)
        }

        // 2. 补充其他可见窗口应用（最多共展示 6 个）
        for win in windows where !seen.contains(win.bundleID) {
            seen.insert(win.bundleID)
            list.append(CaptionTargetApp(
                bundleID: win.bundleID,
                appName: win.appName,
                windowID: win.id,
                isPlayingAudio: win.isAudioActive,
                pid: win.pid
            ))
            if list.count >= 6 { break }
        }
        return list
    }

    private var bottomControlBar: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.md) {
            // 提示文案
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Image(systemName: "cursorarrow.click.2")
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Text("点击目标窗口或在下方直接选择")
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
            }

            Divider()
                .frame(height: SpeechRailDesignTokens.CaptionBand.windowPickerDividerHeight)

            // 发声或可见应用快捷按钮
            if !suggestedApps.isEmpty {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    ForEach(suggestedApps.prefix(6), id: \.bundleID) { app in
                        let isAudio = app.isPlayingAudio || audioApps.contains(where: { $0.bundleID == app.bundleID })
                        Button {
                            onSelectTarget(.app(app))
                        } label: {
                            HStack(spacing: SpeechRailDesignTokens.Spacing.tight) {
                                Image(systemName: isAudio ? "speaker.wave.2.fill" : "macwindow")
                                    .font(SpeechRailDesignTokens.Typography.caption)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                                Text(app.appName)
                                    .font(SpeechRailDesignTokens.Typography.callout)
                            }
                            .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                            .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
                            .background(SpeechRailDesignTokens.Color.rail.opacity(0.1), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .speechRailPointerCursor()
                    }
                }

                Divider()
                    .frame(height: SpeechRailDesignTokens.CaptionBand.windowPickerDividerHeight)
            }

            // 麦克风全场收音
            Button {
                onSelectTarget(.microphone)
            } label: {
                HStack(spacing: SpeechRailDesignTokens.Spacing.tight) {
                    Image(systemName: "mic.fill")
                        .font(SpeechRailDesignTokens.Typography.caption)
                    Text("麦克风收音")
                        .font(SpeechRailDesignTokens.Typography.callout)
                }
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
                .background(SpeechRailDesignTokens.Color.inkSecondary.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .speechRailPointerCursor()

            // 取消按钮
            Button {
                onCancel()
            } label: {
                HStack(spacing: SpeechRailDesignTokens.Spacing.tight) {
                    Text("取消")
                        .font(SpeechRailDesignTokens.Typography.callout)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    Text("Esc")
                        .font(SpeechRailDesignTokens.Typography.captionMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                        .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
                        .background(
                            SpeechRailDesignTokens.Color.inkSecondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.CaptionBand.windowPickerKeycapCornerRadius)
                        )
                }
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
            }
            .buttonStyle(.plain)
            .speechRailPointerCursor()
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        .background(
            .ultraThickMaterial,
            in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.CaptionBand.windowPickerControlBarCornerRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SpeechRailDesignTokens.CaptionBand.windowPickerControlBarCornerRadius)
                .stroke(
                    SpeechRailDesignTokens.Color.separator,
                    lineWidth: SpeechRailDesignTokens.Stroke.hairline
                )
        )
        .shadow(
            color: .black.opacity(0.2),
            radius: SpeechRailDesignTokens.CaptionBand.windowPickerShadowRadius,
            x: 0,
            y: 6
        )
    }
}

// MARK: - 专用覆盖层 Panel（确保支持成为 Key Window 接收鼠标与按键）

private final class WindowPickerPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - 窗口拾取器控制器

@MainActor
public final class WindowPickerOverlayController: NSWindowController {
    /// 确保会话期间控制器不被即时析构，并在完成时释放
    private static var activeController: WindowPickerOverlayController?

    private var completion: ((CaptionAudioTarget?) -> Void)?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?

    public static func pickTarget() async -> CaptionAudioTarget? {
        await withCheckedContinuation { continuation in
            if let existing = activeController {
                existing.dismiss(selected: nil)
            }
            let controller = WindowPickerOverlayController()
            activeController = controller
            controller.startPicking { selected in
                if activeController === controller {
                    activeController = nil
                }
                continuation.resume(returning: selected)
            }
        }
    }

    public func startPicking(completion: @escaping (CaptionAudioTarget?) -> Void) {
        self.completion = completion

        let windows = CaptionWindowCatalog.visibleAppWindows()
        let audioApps = CaptionWindowCatalog.activeAudioApps()

        // 优先在当前鼠标所在屏幕呈现，确保多屏环境下高亮框与物理位置对齐
        let targetScreen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main ?? NSScreen.screens.first

        guard let screen = targetScreen else {
            dismiss(selected: nil)
            return
        }

        let panel = WindowPickerPanel(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true

        panel.onEscape = { [weak self] in
            self?.dismiss(selected: nil)
        }

        let overlayView = WindowPickerOverlayView(
            screenFrame: screen.frame,
            windows: windows,
            audioApps: audioApps,
            onSelectTarget: { [weak self] target in
                self?.dismiss(selected: target)
            },
            onCancel: { [weak self] in
                self?.dismiss(selected: nil)
            }
        )

        let hostingView = NSHostingView(rootView: overlayView)
        panel.contentView = hostingView
        self.window = panel

        // 激活 SpeechRail 为前台应用，确保 Panel 获得焦点与事件分发
        NSApp.activate(ignoringOtherApps: true)

        // 监听本地与全局 Esc 键退出（双重保障）
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // ESC
                self?.dismiss(selected: nil)
                return nil
            }
            return event
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // ESC
                DispatchQueue.main.async {
                    self?.dismiss(selected: nil)
                }
            }
        }

        panel.makeKeyAndOrderFront(nil)
    }

    private func dismiss(selected: CaptionAudioTarget?) {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        window?.orderOut(nil)
        window = nil
        if Self.activeController === self {
            Self.activeController = nil
        }
        let comp = completion
        completion = nil
        comp?(selected)
    }
}
