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
    /// 获取当前屏幕上所有普通应用窗口（不读取窗口标题，仅读取 PID / Layer / Bounds）。
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
            guard let layer = dict[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
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

    /// 提取正在出声或有音频通道的应用列表（去重）。
    public static func activeAudioApps(excludingBundleID: String? = nil) -> [CaptionTargetApp] {
        let windows = visibleAppWindows(excludingBundleID: excludingBundleID)
        var seenBundles = Set<String>()
        var apps: [CaptionTargetApp] = []

        // 先放正在发声的
        for win in windows where win.isAudioActive {
            if !seenBundles.contains(win.bundleID) {
                seenBundles.insert(win.bundleID)
                apps.append(CaptionTargetApp(bundleID: win.bundleID, appName: win.appName, windowID: win.id, pid: win.pid))
            }
        }
        return apps
    }
}

// MARK: - 窗口拾取全屏覆盖层视图

public struct WindowPickerOverlayView: View {
    public let windows: [CaptionWindowInfo]
    public let audioApps: [CaptionTargetApp]
    public let onSelectTarget: (CaptionAudioTarget) -> Void
    public let onCancel: () -> Void

    @State private var mouseLocation: CGPoint = .zero
    @State private var hoveredWindow: CaptionWindowInfo?

    public init(
        windows: [CaptionWindowInfo],
        audioApps: [CaptionTargetApp],
        onSelectTarget: @escaping (CaptionAudioTarget) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.windows = windows
        self.audioApps = audioApps
        self.onSelectTarget = onSelectTarget
        self.onCancel = onCancel
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // 半透明遮罩底色
                Color.black.opacity(0.18)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let hovered = hoveredWindow {
                            onSelectTarget(.app(CaptionTargetApp(
                                bundleID: hovered.bundleID,
                                appName: hovered.appName,
                                windowID: hovered.id,
                                pid: hovered.pid
                            )))
                        } else {
                            onCancel()
                        }
                    }

                // 高亮选中窗口边框与胶囊
                if let hovered = hoveredWindow {
                    let localFrame = screenToLocal(hovered.bounds, proxy: proxy)
                    windowHighlight(hovered: hovered, localFrame: localFrame)
                }

                // 底部快捷栏
                VStack {
                    Spacer()
                    bottomControlBar
                        .padding(.bottom, 48)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    mouseLocation = location
                    updateHoveredWindow(localPoint: location, proxy: proxy)
                case .ended:
                    hoveredWindow = nil
                }
            }
        }
        .ignoresSafeArea()
    }

    private func screenToLocal(_ screenRect: CGRect, proxy: GeometryProxy) -> CGRect {
        // AppKit 屏幕坐标转换为当前 View 本地坐标
        let screenHeight = NSScreen.screens.first?.frame.height ?? proxy.size.height
        let viewY = screenHeight - (screenRect.origin.y + screenRect.height)
        return CGRect(x: screenRect.origin.x, y: viewY, width: screenRect.width, height: screenRect.height)
    }

    private func updateHoveredWindow(localPoint: CGPoint, proxy: GeometryProxy) {
        // 查找鼠标下方的窗口（按从前到后的层叠顺序，即列表优先）
        for window in windows {
            let localRect = screenToLocal(window.bounds, proxy: proxy)
            if localRect.contains(localPoint) {
                hoveredWindow = window
                return
            }
        }
        hoveredWindow = nil
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
                        .frame(width: 18, height: 18)
                }
                Text(hovered.appName)
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)

                if hovered.isAudioActive {
                    HStack(spacing: 3) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 10))
                        Text("有声音")
                            .font(SpeechRailDesignTokens.Typography.caption)
                    }
                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(SpeechRailDesignTokens.Color.rail.opacity(0.12), in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
            .offset(x: 12, y: 12)
        }
        .position(x: localFrame.midX, y: localFrame.midY)
        .allowsHitTesting(false)
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
                .frame(height: 20)

            // 发声应用快捷按钮
            if !audioApps.isEmpty {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    ForEach(audioApps.prefix(3), id: \.bundleID) { app in
                        Button {
                            onSelectTarget(.app(app))
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                                Text(app.appName)
                                    .font(SpeechRailDesignTokens.Typography.callout)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(SpeechRailDesignTokens.Color.rail.opacity(0.1), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()
                    .frame(height: 20)
            }

            // 麦克风全场收音
            Button {
                onSelectTarget(.microphone)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 12))
                    Text("麦克风收音")
                        .font(SpeechRailDesignTokens.Typography.callout)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(SpeechRailDesignTokens.Color.inkSecondary.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)

            // 取消按钮
            Button {
                onCancel()
            } label: {
                Text("取消 (Esc)")
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(SpeechRailDesignTokens.Color.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 6)
    }
}

// MARK: - 窗口拾取器控制器

@MainActor
public final class WindowPickerOverlayController: NSWindowController {
    private var completion: ((CaptionAudioTarget?) -> Void)?
    private var keyMonitor: Any?

    public static func pickTarget() async -> CaptionAudioTarget? {
        await withCheckedContinuation { continuation in
            let controller = WindowPickerOverlayController()
            controller.startPicking { selected in
                continuation.resume(returning: selected)
            }
        }
    }

    public func startPicking(completion: @escaping (CaptionAudioTarget?) -> Void) {
        self.completion = completion

        let windows = CaptionWindowCatalog.visibleAppWindows()
        let audioApps = CaptionWindowCatalog.activeAudioApps()

        guard let screen = NSScreen.main else {
            completion(nil)
            return
        }

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
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

        let overlayView = WindowPickerOverlayView(
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

        // 监听 Esc 键退出
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // ESC
                self?.dismiss(selected: nil)
                return nil
            }
            return event
        }

        panel.makeKeyAndOrderFront(nil)
    }

    private func dismiss(selected: CaptionAudioTarget?) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        window?.orderOut(nil)
        window = nil
        let comp = completion
        completion = nil
        comp?(selected)
    }
}
