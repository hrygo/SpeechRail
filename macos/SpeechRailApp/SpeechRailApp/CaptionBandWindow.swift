import AppKit
import SwiftUI

// 字幕带的浮层（`SESSIONS-SPEC` §6.3.1、`UX-UI-SPEC` §2 的「浮层」一条）。
//
// **它是 App 里唯一一个 `NSPanel`**，三件事决定了它的形状：
//
//   1. **不抢焦点、不激活 App**（`.nonactivatingPanel` + `becomesKeyOnlyIfNeeded`）。
//      最常见的用法是"我在别处干活，字幕贴在屏幕上"，所以它既不能把 App 拽到前台，
//      也不能在别人全屏演示时缩回去（`.canJoinAllSpaces` + `.fullScreenAuxiliary`）。
//   2. **材质是系统的**，不是自绘半透明色块：`NSVisualEffectView` 的 `.hudWindow` +
//      `.behindWindow`。稿里以 `surface/panel` + 1px hairline 表示，那只是"画不出来"的替身。
//   3. **高度按内容长，位置按屏记**。悬停工具条出现时窗口**向上长**（底边不动），
//      所以字幕文字在视觉上不跳——这一条是"薄片"和"卡片"的分界。

/// 字号三档。它是**用户设置**，不是界面层级（§6.3.1）。
public enum CaptionBandFontSize: String, CaseIterable, Identifiable, Sendable {
    case compact
    case standard
    case large

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .compact: "紧凑"
        case .standard: "标准"
        case .large: "大字"
        }
    }

    public var font: Font {
        switch self {
        case .compact: SpeechRailDesignTokens.Typography.captionBandCompact
        case .standard: SpeechRailDesignTokens.Typography.captionBandStandard
        case .large: SpeechRailDesignTokens.Typography.captionBandLarge
        }
    }

    var textStyle: NSFont.TextStyle {
        switch self {
        // SwiftUI 的 `.title` 对应 AppKit 的 `.title1`（22pt），不是 `.title`——
        // `NSFont.TextStyle` 里没有 `title` 这一档。
        case .compact: .title2
        case .standard: .title1
        case .large: .largeTitle
        }
    }

    /// 一行的高度（含行距）。窗口高度按它算——**不靠测量**：浮层高度要在内容出现之前
    /// 就定下来，否则首句到达时带子会先跳一下。
    var lineHeight: CGFloat {
        let font = NSFont.preferredFont(forTextStyle: textStyle)
        return ceil(font.ascender - font.descender + font.leading)
    }
}

/// 浮层当前该占多大。界面侧每次变化把这一份交给控制器，控制器只做"算出高度、动窗口"。
struct CaptionBandMetrics: Equatable {
    var lineCount: Int
    var fontSize: CaptionBandFontSize
    var isHovering: Bool

    static func height(_ metrics: CaptionBandMetrics) -> CGFloat {
        let layout = SpeechRailDesignTokens.Layout.self
        let rows: Int = min(
            max(metrics.lineCount, layout.captionBandMinimumLineCount),
            layout.captionBandMaximumLineCount
        )
        let lineRow: CGFloat = metrics.fontSize.lineHeight + 2 * layout.captionLinePaddingV
        let hint: CGFloat = Self.lineHeight(for: .caption1)
        let foot: CGFloat = 2 * layout.captionBandFootPaddingV + max(layout.captionBandLevelBarHeight, hint)
        let verticalPadding: CGFloat = 2 * layout.captionBandPaddingV
        let lines: CGFloat = CGFloat(rows) * lineRow
        let gaps: CGFloat = CGFloat(rows) * layout.captionBandSpacing
        // 工具条出现时窗口**向上长**，底边不动（`applyMetrics`）。
        let toolbar: CGFloat = metrics.isHovering
            ? 2 * layout.captionBandToolbarPaddingV + layout.captionBandIconButtonSize + layout.captionBandSpacing
            : 0
        let total: CGFloat = verticalPadding + lines + gaps + foot + toolbar
        return max(total, SpeechRailDesignTokens.CaptionBand.minimumHeight)
    }

    static func lineHeight(for style: NSFont.TextStyle) -> CGFloat {
        let font = NSFont.preferredFont(forTextStyle: style)
        return ceil(font.ascender - font.descender + font.leading)
    }
}

// MARK: - 窗口控制器

/// 字幕带的窗口控制器。App 里唯一碰 `NSPanel` 的地方。
@MainActor
public final class CaptionBandWindowController: NSObject {
    private let session: CaptionSession
    private let defaults: UserDefaults
    private var panel: CaptionBandPanel?
    private var metrics = CaptionBandMetrics(lineCount: 2, fontSize: .standard, isHovering: false)

    private let onOpenActiveSession: () -> Void

    public init(
        session: CaptionSession,
        defaults: UserDefaults = .standard,
        onOpenActiveSession: @escaping () -> Void = {}
    ) {
        self.session = session
        self.defaults = defaults
        self.onOpenActiveSession = onOpenActiveSession
        super.init()
    }

    /// 出现 / 隐藏。会话层只发这一个信号（`CaptionSession.presentBand`），
    /// 窗口怎么放、放哪儿是这一层的事。
    public func setVisible(_ visible: Bool) {
        visible ? show() : hide()
    }

    public func show() {
        let panel = ensurePanel()
        applyMetrics(metrics)
        panel.alphaValue = 1
        // `orderFrontRegardless`：非激活面板不调用 `makeKeyAndOrderFront`——那会把 App 激活。
        panel.orderFrontRegardless()
    }

    public func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> CaptionBandPanel {
        if let panel { return panel }
        let panel = CaptionBandPanel(
            contentRect: NSRect(
                origin: .zero,
                size: NSSize(
                    width: SpeechRailDesignTokens.Layout.captionBandDefaultWidth,
                    height: CaptionBandMetrics.height(metrics)
                )
            ),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // `.floating` 而不是 `.screenSaver`：它要盖住普通窗口与全屏演示，但不该盖住系统弹窗。
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // 「钉住位置」是**真的**：钉住时整块带子不再跟着拖动走，只有解锁之后才拖得动。
        panel.isMovableByWindowBackground = !defaults.bool(forKey: SpeechRailDesignTokens.CaptionBand.pinnedDefaultsKey)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.minSize = NSSize(
            width: SpeechRailDesignTokens.Layout.captionBandMinimumWidth,
            height: SpeechRailDesignTokens.CaptionBand.minimumHeight
        )
        panel.maxSize = NSSize(
            width: SpeechRailDesignTokens.Layout.captionBandMaximumWidth,
            height: 400
        )
        panel.delegate = self

        let hosting = NSHostingView(
            rootView: CaptionBandView(
                session: session,
                onMetricsChange: { [weak self] metrics in
                    self?.applyMetrics(metrics)
                },
                onPinChange: { [weak self] pinned in
                    self?.panel?.isMovableByWindowBackground = !pinned
                },
                onOpenActiveSession: { [weak self] in
                    self?.onOpenActiveSession()
                },
                onClose: { [weak self] in
                    guard let self else { return }
                    Task { await session.finish() }
                }
            )
        )
        hosting.frame = panel.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]

        let material = NSVisualEffectView(frame: panel.contentLayoutRect)
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = SpeechRailDesignTokens.Layout.captionBandCornerRadius
        material.layer?.masksToBounds = true
        material.layer?.borderWidth = 1
        material.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        material.autoresizingMask = [.width, .height]
        material.addSubview(hosting)
        panel.contentView = material

        self.panel = panel
        place(panel)
        return panel
    }

    /// 高度跟内容变，**底边不动**：窗口的 `origin.y` 就是底边的位置，
    /// 所以只要不碰它，长高就是往上长。
    private func applyMetrics(_ metrics: CaptionBandMetrics) {
        self.metrics = metrics
        guard let panel else { return }
        let height = CaptionBandMetrics.height(metrics)
        var frame = panel.frame
        guard abs(frame.height - height) > 0.5 else { return }
        frame.size.height = height
        panel.setFrame(frame, display: true)
        remember(panel)
    }

    // MARK: - 位置记忆（每屏一套）

    private func place(_ panel: NSPanel) {
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        if let stored = storedFrame(for: screen), Self.isOnScreen(stored, screen: screen) {
            panel.setFrame(stored, display: false)
            return
        }
        panel.setFrame(defaultFrame(for: screen, height: panel.frame.height), display: false)
    }

    private func defaultFrame(for screen: NSScreen, height: CGFloat) -> NSRect {
        let layout = SpeechRailDesignTokens.Layout.self
        // 距**可用区**底部 96pt：Dock 常驻时这一条自动把它让开，Dock 隐藏时就是离屏幕底 96pt。
        let originY = screen.visibleFrame.minY + layout.captionBandBottomInset
        let width = min(
            max(layout.captionBandDefaultWidth, panel?.frame.width ?? layout.captionBandDefaultWidth),
            layout.captionBandMaximumWidth
        )
        return NSRect(
            x: screen.frame.midX - width / 2,
            y: originY,
            width: width,
            height: height
        )
    }

    private static func isOnScreen(_ frame: NSRect, screen: NSScreen) -> Bool {
        // 只要求"和这块屏有交集"：显示器被拔掉之后，存下来的帧会挂在屏幕外，
        // 那时回到默认位置，而不是让用户找一块看不见的带子。
        screen.visibleFrame.intersects(frame)
    }

    private func key(for screen: NSScreen) -> String {
        SpeechRailDesignTokens.CaptionBand.positionDefaultsPrefix + Self.identifier(for: screen)
    }

    private static func identifier(for screen: NSScreen) -> String {
        guard
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
            let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else {
            return "unknown"
        }
        return (CFUUIDCreateString(nil, uuid) as String?) ?? "unknown"
    }

    private func storedFrame(for screen: NSScreen) -> NSRect? {
        guard let raw = defaults.string(forKey: key(for: screen)) else { return nil }
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return NSRect(
            x: parts[0],
            y: parts[1],
            width: parts[2],
            height: panel?.frame.height ?? CaptionBandMetrics.height(metrics)
        )
    }

    /// 只记 `x / y / 宽度`：高度由内容决定，记下来会与字号档打架。
    private func remember(_ panel: NSPanel) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let frame = panel.frame
        defaults.set("\(frame.origin.x),\(frame.origin.y),\(frame.size.width)", forKey: key(for: screen))
    }
}

extension CaptionBandWindowController: NSWindowDelegate {
    public func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        remember(panel)
    }

    public func windowDidResize(_ notification: Notification) {
        guard let panel else { return }
        remember(panel)
    }
}

/// 非激活浮层。它**可以**成为 key（要能滚动、能点按钮），但**不**成为 main——
/// 于是"可交互"与"不抢走 App 的前台"两件事同时成立（§5.7）。
private final class CaptionBandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - 浮层内容

/// 带子的内容。**它自己不画背景**：材质由外面的 `NSVisualEffectView` 给，
/// 这里只负责字、行、页脚与悬停工具条（`UX-UI-SPEC` §2 的「浮层」一条）。
struct CaptionBandView: View {
    let session: CaptionSession
    let onMetricsChange: (CaptionBandMetrics) -> Void
    /// 「钉住位置」要传到窗口那一层：它改的是窗口能不能被拖动，不是一个界面开关。
    let onPinChange: (Bool) -> Void
    /// 受阻时那条「打开会议转录」的出口。浮层不认识路由表，出口由 App 接。
    let onOpenActiveSession: () -> Void
    let onClose: () -> Void

    @AppStorage(SpeechRailDesignTokens.CaptionBand.fontSizeDefaultsKey)
    private var fontSizeRaw = CaptionBandFontSize.standard.rawValue
    @AppStorage(SpeechRailDesignTokens.CaptionBand.pinnedDefaultsKey)
    private var isPinned = false
    @State private var isHovering = false
    @State private var isFollowing = true
    @State private var scrollProxy: ScrollViewProxy?

    private var fontSize: CaptionBandFontSize {
        CaptionBandFontSize(rawValue: fontSizeRaw) ?? .standard
    }

    private var rows: [CaptionSession.Line] {
        session.lines
    }

    private var visibleLineCount: Int {
        rows.count + (session.partialText == nil ? 0 : 1)
    }

    private var metrics: CaptionBandMetrics {
        CaptionBandMetrics(
            lineCount: visibleLineCount,
            fontSize: fontSize,
            isHovering: isHovering
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Layout.captionBandSpacing) {
            if isHovering {
                toolbar
            }
            if let blocked = session.blocked {
                blockedRow(blocked)
                if !rows.isEmpty { linesScroll }
            } else {
                linesScroll
            }
            footer
        }
        .padding(.vertical, SpeechRailDesignTokens.Layout.captionBandPaddingV)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onHover { hovering in
            isHovering = hovering
            onMetricsChange(metrics)
        }
        .onChange(of: metrics, initial: true) { _, metrics in
            onMetricsChange(metrics)
        }
        // 打开时把"钉住"的状态推给窗口：它是跨会话记住的，不能等用户再点一次才生效。
        .onAppear { onPinChange(isPinned) }
    }

    // MARK: 字幕行

    private var linesScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { line in
                        lineRow(text: line.text, isPartial: false)
                            .id(line.id)
                    }
                    if let partial = session.partialText, !partial.isEmpty {
                        lineRow(text: partial, isPartial: true)
                            .id(Self.partialAnchor)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
            }
            .scrollIndicators(.never)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // 「贴着底」= 内容底边已经在可视区里（留一点余量给惯性）。
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - SpeechRailDesignTokens.CaptionBand.followThreshold
            } action: { _, atBottom in
                isFollowing = atBottom
            }
            .onAppear { scrollProxy = proxy }
            .onChange(of: session.lines.count) { _, _ in scrollToLatestIfFollowing() }
            .onChange(of: session.partialText) { _, _ in scrollToLatestIfFollowing() }
        }
    }

    private static let partialAnchor = "caption-band-partial"
    private static let bottomAnchor = "caption-band-bottom"

    private func lineRow(text: String, isPartial: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SpeechRailDesignTokens.Spacing.xs) {
            Text(text)
                .font(fontSize.font)
                .foregroundStyle(
                    isPartial
                        ? SpeechRailDesignTokens.Color.inkSecondary
                        : SpeechRailDesignTokens.Color.ink
                )
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isPartial {
                Text("正在识别…")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Layout.captionLinePaddingH)
        .padding(.vertical, SpeechRailDesignTokens.Layout.captionLinePaddingV)
    }

    // MARK: 悬停工具条

    private var toolbar: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            iconButton(
                systemImage: session.phase == .running ? "pause.fill" : "play.fill",
                label: session.phase == .running ? "暂停" : "继续"
            ) {
                Task {
                    if session.phase == .running {
                        await session.pause()
                    } else {
                        await session.resume()
                    }
                }
            }
            fontMenu
            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
            iconButton(systemImage: "doc.on.doc", label: "复制这一段") {
                copyCurrentSegment()
            }
            iconButton(systemImage: "square.and.arrow.down", label: "导出 SRT…") {
                Task { await session.exportSRT() }
            }
            iconButton(systemImage: isPinned ? "pin.fill" : "pin", label: isPinned ? "取消钉住" : "钉住位置") {
                isPinned.toggle()
                onPinChange(isPinned)
            }
            iconButton(systemImage: "xmark", label: "结束并保存") {
                onClose()
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Layout.captionBandToolbarPaddingH)
        .padding(.vertical, SpeechRailDesignTokens.Layout.captionBandToolbarPaddingV)
        .background(
            RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Layout.captionBandToolbarCornerRadius)
                .fill(.thinMaterial)
        )
        .padding(.horizontal, SpeechRailDesignTokens.Layout.captionBandToolbarPaddingH)
        .accessibilityIdentifier("caption-band-toolbar")
    }

    private var fontMenu: some View {
        Menu {
            ForEach(CaptionBandFontSize.allCases) { size in
                Button(size.title) {
                    fontSizeRaw = size.rawValue
                }
            }
        } label: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text("字号")
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Text(fontSize.title)
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Image(systemName: "chevron.down")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("字号 \(fontSize.title)")
    }

    private func iconButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(SpeechRailDesignTokens.Typography.callout)
                .frame(
                    width: SpeechRailDesignTokens.Layout.captionBandIconButtonSize,
                    height: SpeechRailDesignTokens.Layout.captionBandIconButtonSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: 页脚与受阻

    private var footer: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Text(footerHint)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
            if !isFollowing {
                Button {
                    isFollowing = true
                    scrollToLatest()
                } label: {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                        Image(systemName: "chevron.down")
                        Text("回到最新")
                    }
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("caption-band-return-latest")
            }
            levelBars
        }
        .padding(.horizontal, SpeechRailDesignTokens.Layout.captionBandFootPaddingH)
        .padding(.vertical, SpeechRailDesignTokens.Layout.captionBandFootPaddingV)
    }

    private var footerHint: String {
        if session.blocked != nil { return "" }
        if session.phase == .paused { return "已暂停 · ⌘⇧L 继续" }
        if session.phase == .ending { return "正在保存最后一句…" }
        return "⌘⇧L 暂停 · ✕ 结束并保存"
    }

    /// 真实电平，不是自走的动画（`LevelMeter` 的同一处口径）。
    private var levelBars: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                let threshold = Double(index + 1) / 3.0
                Capsule()
                    .fill(
                        session.level >= threshold
                            ? SpeechRailDesignTokens.Color.rail
                            : SpeechRailDesignTokens.Color.inkTertiary.opacity(0.3)
                    )
                    .frame(
                        width: SpeechRailDesignTokens.Layout.captionBandLevelBarWidth / 4,
                        height: SpeechRailDesignTokens.Layout.captionBandLevelBarHeight / 3 * CGFloat(index + 1)
                    )
            }
        }
        .frame(height: SpeechRailDesignTokens.Layout.captionBandLevelBarHeight, alignment: .bottom)
        .accessibilityLabel("输入电平")
    }

    /// 受阻：**同一条带子**换成一句话 + 一个出口，最后一句字幕仍然留在上面（可读、可复制）。
    private func blockedRow(_ reason: CaptionSession.BlockReason) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SpeechRailDesignTokens.Spacing.xs) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(reason.title)
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                Text(reason.detail)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
            blockedActions(reason)
        }
        .padding(.horizontal, SpeechRailDesignTokens.Layout.captionLinePaddingH)
        .padding(.vertical, SpeechRailDesignTokens.Layout.captionLinePaddingV)
    }

    @ViewBuilder
    private func blockedActions(_ reason: CaptionSession.BlockReason) -> some View {
        switch reason {
        case .microphoneDenied:
            Button("打开系统设置") {
                openSystemSettings()
            }
        case .occupiedBy:
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Button("打开\(session.activeOwnerTitle)转录") {
                    onOpenActiveSession()
                }
                Button("结束并启动字幕") {
                    Task { await session.takeOverOccupiedMicrophone() }
                }
            }
        case .storeUnavailable:
            Button("打开数据目录") {
                NSWorkspace.shared.activateFileViewerSelecting([session.libraryURL])
            }
        case .serviceNotReady, .serviceBusy, .streamFailed:
            Button(reason.canResume ? "重新接上" : "重试") {
                Task { await session.retry() }
            }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func copyCurrentSegment() {
        guard let text = session.currentSegmentText, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func scrollToLatestIfFollowing() {
        guard isFollowing else { return }
        scrollToLatest()
    }

    /// 跟随态下把视图滚到底：新行出现时用户已经在看最新那一句，不该还要自己滚。
    private func scrollToLatest() {
        scrollProxy?.scrollTo(Self.bottomAnchor, anchor: .bottom)
    }
}
