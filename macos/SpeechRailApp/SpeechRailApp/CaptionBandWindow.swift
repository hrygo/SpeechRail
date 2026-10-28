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

/// 字幕带背景衬底对比度档位（适应白底网页、亮色课件或暗色视频等不同背景）。
public enum CaptionBandBackgroundStyle: String, CaseIterable, Identifiable, Sendable {
    case translucent
    case standard
    case highContrast

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .translucent: "通透毛玻璃"
        case .standard: "标准深色衬底"
        case .highContrast: "高对比深色"
        }
    }

    var dimmerOpacity: Double {
        switch self {
        case .translucent: 0.0
        case .standard: 0.24
        case .highContrast: 0.56
        }
    }
}

/// 浮层当前该占多大。界面侧每次变化把这一份交给控制器，控制器只做"算出高度、动窗口"。
///
/// **高度按"视觉行"算，不按"逻辑行"算**（`SESSIONS-SPEC` §6.3.1「内容撑高」）。
/// 一句 45 字的长话在 760pt 宽的带子里会折成两行；只数逻辑行就少算一整行，
/// 最下面那半句会被顶到窗口外——这正是离屏走查量出来的那条差（`band-live` 夹具）。
/// 所以行数由 `visualRowCount(for:style:availableWidth:)` 用**同一套字体和真实可用宽度**
/// 量出来：折行在内容出现之前就能算清，不需要等布局回读，也就没有"首句到达时带子跳一下"。
struct CaptionBandMetrics: Equatable {
    /// 屏幕上要留出的视觉行数（折行已经算进去）。控制器会按上下限再裁一次。
    var visualRowCount: Int
    /// 受阻行的高度（`blockedRowHeight(title:detail:contentWidth:)`）；没受阻就是 0。
    var blockedRowHeight: CGFloat = 0
    var fontSize: CaptionBandFontSize
    var isHovering: Bool
    /// 带子的内容宽度。它参与折行计算，所以宽度一变高度就得重算。
    var contentWidth: CGFloat = SpeechRailDesignTokens.Layout.captionBandDefaultWidth

    static func height(_ metrics: CaptionBandMetrics) -> CGFloat {
        let layout = SpeechRailDesignTokens.Layout.self
        let rows: Int = min(
            max(metrics.visualRowCount, layout.captionBandMinimumLineCount),
            layout.captionBandMaximumLineCount
        )
        let lineRow: CGFloat = metrics.fontSize.lineHeight + 2 * layout.captionLinePaddingV
        let hint: CGFloat = Self.lineHeight(for: .caption1)
        let foot: CGFloat = 2 * layout.captionBandFootPaddingV + max(layout.captionBandLevelBarHeight, hint)
        let verticalPadding: CGFloat = 2 * layout.captionBandPaddingV
        let lines: CGFloat = CGFloat(rows) * (lineRow + layout.captionBandSpacing)
        let blocked: CGFloat = metrics.blockedRowHeight > 0
            ? metrics.blockedRowHeight + layout.captionBandSpacing
            : 0
        // 工具条出现时窗口**向上长**，底边不动（`applyMetrics`）。
        let toolbar: CGFloat = metrics.isHovering
            ? 2 * layout.captionBandToolbarPaddingV + layout.captionBandIconButtonSize + layout.captionBandSpacing
            : 0
        let total: CGFloat = verticalPadding + blocked + lines + foot + toolbar
        return max(total, SpeechRailDesignTokens.CaptionBand.minimumHeight)
    }

    static func lineHeight(for style: NSFont.TextStyle) -> CGFloat {
        let font = NSFont.preferredFont(forTextStyle: style)
        return ceil(font.ascender - font.descender + font.leading)
    }

    /// 一段字在给定宽度下会占几个视觉行。**用同一套字体的真实排版结果算**：
    /// 折行是这套高度计算里唯一没法靠"数逻辑行"得到的东西。
    static func visualRowCount(
        for text: String,
        style: NSFont.TextStyle,
        availableWidth: CGFloat
    ) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, availableWidth > 0 else { return 1 }
        let font = NSFont.preferredFont(forTextStyle: style)
        let attributed = NSAttributedString(string: trimmed, attributes: [.font: font])
        // 宽度上留 2pt 余量：宁可多算一行把带子留高一点，也不要少算一行把字切掉。
        let bounds = attributed.boundingRect(
            with: NSSize(width: max(availableWidth - 2, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let line = max(1, lineHeight(for: style))
        return max(1, Int(ceil(bounds.height / line)))
    }

    static func visualRowCount(
        for text: String,
        fontSize: CaptionBandFontSize,
        availableWidth: CGFloat
    ) -> Int {
        visualRowCount(for: text, style: fontSize.textStyle, availableWidth: availableWidth)
    }

    /// 一行字幕里真正给文字用的宽度：两边各让 `captionLinePaddingH`；
    /// 半句那一行还要给右边的「正在识别…」让位；开启分人时首行还要给左侧说话人胶囊让位。
    static func textAvailableWidth(
        contentWidth: CGFloat,
        isPartial: Bool,
        speakerBadgeText: String? = nil
    ) -> CGFloat {
        let layout = SpeechRailDesignTokens.Layout.self
        var available = contentWidth - 2 * layout.captionLinePaddingH
        if let speakerBadgeText, !speakerBadgeText.isEmpty {
            let badge = NSAttributedString(
                string: speakerBadgeText,
                attributes: [.font: NSFont.preferredFont(forTextStyle: .caption1)]
            )
            available -= ceil(badge.size().width) + 12 + SpeechRailDesignTokens.Spacing.xs
        }
        guard isPartial else { return max(available, 1) }
        let label = NSAttributedString(
            string: "正在识别…",
            attributes: [.font: NSFont.preferredFont(forTextStyle: .caption1)]
        )
        return max(available - ceil(label.size().width) - SpeechRailDesignTokens.Spacing.xs, 1)
    }

    /// 受阻行的高度：标题一行 + 说明若干行（说明会折行），右边还要给动作按钮留出位置。
    static func blockedRowHeight(title: String, detail: String, contentWidth: CGFloat) -> CGFloat {
        let layout = SpeechRailDesignTokens.Layout.self
        let textWidth = max(
            contentWidth - 2 * layout.captionLinePaddingH - layout.captionBandBlockedActionsReserve,
            1
        )
        let titleRows = CGFloat(visualRowCount(for: title, style: .callout, availableWidth: textWidth))
        let detailRows = CGFloat(visualRowCount(for: detail, style: .caption1, availableWidth: textWidth))
        let text = titleRows * lineHeight(for: .callout)
            + detailRows * lineHeight(for: .caption1)
            + SpeechRailDesignTokens.Spacing.micro
        return text + 2 * layout.captionLinePaddingV
    }

    /// 从"要显示的内容 + 当前宽度"推出这一份指标。**视图和离屏走查共用这一个入口**，
    /// 否则两边各算一次，量出来的高度就对不上账。
    ///
    /// 行数是**从最新一句往回数**的：屏幕上留得下几行就先满足最新的那几句，
    /// 上面被顶掉的旧句交给滚动。
    static func current(
        content: CaptionBandContent,
        blocked: CaptionSession.BlockReason?,
        fontSize: CaptionBandFontSize,
        isHovering: Bool,
        contentWidth: CGFloat,
        speakerBadgeResolver: ((String) -> String)? = nil
    ) -> CaptionBandMetrics {
        let layout = SpeechRailDesignTokens.Layout.self
        let width = contentWidth > 0 ? contentWidth : layout.captionBandDefaultWidth
        let limit = layout.captionBandMaximumLineCount
        var rows = 0
        for line in content.rows.reversed() where rows < limit {
            let badgeText = line.speakerLabel.flatMap { label -> String? in
                guard !label.isEmpty else { return nil }
                return speakerBadgeResolver?(label)
            }
            rows += visualRowCount(
                for: line.primaryText,
                fontSize: fontSize,
                availableWidth: textAvailableWidth(
                    contentWidth: width,
                    isPartial: line.isPartial || line.isTranslating,
                    speakerBadgeText: badgeText
                )
            )
            if let secondary = line.secondaryText, !secondary.isEmpty {
                rows += visualRowCount(
                    for: secondary,
                    style: .callout,
                    availableWidth: textAvailableWidth(contentWidth: width, isPartial: false)
                )
            }
        }
        let blockedHeight = blocked.map {
            blockedRowHeight(title: $0.title, detail: $0.detail, contentWidth: width)
        } ?? 0
        return CaptionBandMetrics(
            visualRowCount: rows,
            blockedRowHeight: blockedHeight,
            fontSize: fontSize,
            isHovering: isHovering,
            contentWidth: width
        )
    }
}

// MARK: - 窗口控制器

/// 字幕带的窗口控制器。App 里唯一碰 `NSPanel` 的地方。
@MainActor
public final class CaptionBandWindowController: NSObject {
    private let session: CaptionSession
    private let defaults: UserDefaults
    private var panel: CaptionBandPanel?
    private var metrics = CaptionBandMetrics(visualRowCount: 2, fontSize: .standard, isHovering: false)
    private let tracker = TargetWindowTracker()
    /// 正在写跟踪器算出来的吸附落点。`setFrame` 会同步发 `windowDidMove`，
    /// 没有这个标记时"我们自己搬的"会被当成用户拖动，第一帧就把吸附踢成自由悬浮。
    private var isApplyingTargetGeometry = false
    /// 最近一次跟踪器真正落下的吸附原点：异步到达的 `windowDidMove` 靠它识别。
    private var lastDockedOrigin: NSPoint?

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
        tracker.onGeometryChanged = { [weak self] geometry in
            self?.handleTargetGeometryChanged(geometry)
        }
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
        updateTrackingState()
    }

    public func hide() {
        tracker.stopTracking()
        panel?.orderOut(nil)
    }

    public func updateTrackingState() {
        lastDockedOrigin = nil
        if case .app(let target) = session.audioTarget, session.placementMode == .dockedToTargetWindow {
            tracker.startTracking(target: target)
        } else {
            tracker.stopTracking()
        }
    }

    private func handleTargetGeometryChanged(_ geometry: TargetWindowTracker.TargetWindowGeometry?) {
        guard session.placementMode == .dockedToTargetWindow, let panel else { return }
        guard let geometry else { return }
        let frame = Self.dockedFrame(
            targetFrame: geometry.frame,
            bandSize: panel.frame.size,
            screens: NSScreen.screens
        )
        isApplyingTargetGeometry = true
        panel.setFrame(frame, display: true, animate: false)
        isApplyingTargetGeometry = false
        // 记 AppKit 真正落下的原点而不是我们请求的那个：窗口被最小/最大尺寸或屏幕边界
        // 修正过时，只有真实原点才认得出后面那条通知是不是我们自己造成的。
        lastDockedOrigin = panel.frame.origin
    }

    /// 吸附落点：贴目标窗口**内**底边（避开播放器进度条），水平居中，并且左右各留
    /// `dockedHorizontalMargin` 的安全留白——目标窗口比字幕带窄时不越出窗口，
    /// 再兜一层所在屏幕的可视区，避免贴边窗口把带子顶到屏幕外。
    static func dockedFrame(targetFrame: NSRect, bandSize: NSSize, screens: [NSScreen]) -> NSRect {
        let margin = SpeechRailDesignTokens.CaptionBand.dockedHorizontalMargin
        func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
            guard upper >= lower else { return lower }
            return Swift.min(Swift.max(value, lower), upper)
        }

        let width = bandSize.width
        var x = targetFrame.midX - width / 2
        var y = targetFrame.minY + SpeechRailDesignTokens.CaptionBand.dockedBottomInset
        let innerMinX = targetFrame.minX + margin
        let innerMaxX = targetFrame.maxX - margin - width
        if innerMaxX >= innerMinX {
            // 目标窗口放得下整条带子：夹在窗口内，左右各留 `dockedHorizontalMargin`。
            x = clamp(x, innerMinX, innerMaxX)
        }
        // 放不下就保持"以窗口中线对齐"（`x` 未改动），由下面这层屏幕可视区决定最终位置，
        // 而不是硬塞进一个不存在的区间、把带子整体推到窗口右边外。
        if let screen = screens.first(where: { $0.frame.intersects(targetFrame) }) ?? screens.first {
            x = clamp(x, screen.visibleFrame.minX + margin, screen.visibleFrame.maxX - margin - width)
            y = clamp(y, screen.visibleFrame.minY + 12, screen.visibleFrame.maxY - bandSize.height - 12)
        }
        return NSRect(
            x: x,
            y: y,
            width: width,
            height: bandSize.height
        )
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
                onTrackingChange: { [weak self] in
                    // 换目标、切吸附/自由悬浮都要重挂跟踪器：只改 `placementMode` 不会自己跟。
                    self?.updateTrackingState()
                },
                onResetPosition: { [weak self] in
                    self?.resetToDefaultScreenPosition()
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
        isApplyingTargetGeometry = true
        panel.setFrame(frame, display: true)
        isApplyingTargetGeometry = false
        if session.placementMode == .dockedToTargetWindow, lastDockedOrigin != nil {
            lastDockedOrigin = panel.frame.origin
        }
        remember(panel)
    }

    // MARK: - 位置记忆（每屏一套）

    private func place(_ panel: NSPanel) {
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        isApplyingTargetGeometry = true
        defer { isApplyingTargetGeometry = false }
        if let stored = storedFrame(for: screen), Self.isOnScreen(stored, screen: screen) {
            panel.setFrame(stored, display: false)
            return
        }
        panel.setFrame(defaultFrame(for: screen, height: panel.frame.height), display: false)
    }

    /// 一键将字幕带重置回当前屏幕底部居中默认位置，并清除异常偏移记忆。
    private func resetToDefaultScreenPosition() {
        guard let panel else { return }
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        defaults.removeObject(forKey: key(for: screen))
        session.placementMode = .freeFloatingPinned
        lastDockedOrigin = nil
        tracker.stopTracking()
        isApplyingTargetGeometry = true
        panel.setFrame(defaultFrame(for: screen, height: panel.frame.height), display: true, animate: true)
        isApplyingTargetGeometry = false
        remember(panel)
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
    ///
    /// 吸附状态下不记：那个位置是目标窗口推出来的、每帧都在变，记它既会以 15Hz 写
    /// `UserDefaults`，又会把用户挑好的自由悬浮位置覆盖掉。
    private func remember(_ panel: NSPanel) {
        guard session.placementMode != .dockedToTargetWindow else { return }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let frame = panel.frame
        defaults.set("\(frame.origin.x),\(frame.origin.y),\(frame.size.width)", forKey: key(for: screen))
    }
}

extension CaptionBandWindowController: NSWindowDelegate {
    public func windowDidMove(_ notification: Notification) {
        guard let panel, panel.isVisible else { return }
        // 跟踪器的吸附改帧与内部初始排布也会发这条通知（`setFrame` 同步发一次）。
        // 落点仍等于吸附目标位置时那是"我们搬的"，不能算用户拖动：否则 15Hz 跟随会在第一帧停掉自己，
        // 用户也永远看不到 `吸附回窗口` 生效。
        if isApplyingTargetGeometry { return }
        // 拖左/上边缘改尺寸也会改 origin，那不是「把浮层拖走」，吸附不该因此关掉：
        // 缩放期间只认尺寸，落点由下一次跟随统一归位。
        if panel.inLiveResize { return }
        if session.placementMode == .dockedToTargetWindow,
           let lastDockedOrigin,
           abs(panel.frame.minX - lastDockedOrigin.x) < 1,
           abs(panel.frame.minY - lastDockedOrigin.y) < 1 {
            return
        }
        if session.placementMode == .dockedToTargetWindow {
            // 用户拖着走 = 主动解除吸附；`吸附回窗口` 再把它装回来。
            session.placementMode = .freeFloatingPinned
            lastDockedOrigin = nil
            tracker.stopTracking()
        }
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
    /// 目标或吸附状态变了：跟踪器要跟着重挂（换窗口、点「吸附回窗口」都在这里收口）。
    let onTrackingChange: () -> Void
    /// 一键将字幕带重置回当前屏幕底部居中。
    var onResetPosition: () -> Void = {}
    /// 受阻时那条「打开会议转录」的出口。浮层不认识路由表，出口由 App 接。
    let onOpenActiveSession: () -> Void
    let onClose: () -> Void

    @AppStorage(SpeechRailDesignTokens.CaptionBand.fontSizeDefaultsKey)
    private var fontSizeRaw = CaptionBandFontSize.standard.rawValue
    @AppStorage("speechrail.captionBand.backgroundStyle")
    private var backgroundStyleRaw = CaptionBandBackgroundStyle.standard.rawValue
    @AppStorage(SpeechRailDesignTokens.CaptionBand.pinnedDefaultsKey)
    private var isPinned = false
    @State private var isHovering = false
    @State private var transcriptFollow = TranscriptFollowState()
    @State private var userScrollActive = false
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var showsSaveRecovery = false
    @State private var recoveryFeedback: OperationFeedback?
    @State private var copyFailure: String?
    @State private var copyNotice: String?
    @State private var copyNoticeID = UUID()
    @State private var isCopyConfirmed = false
    @State private var copyConfirmationTask: Task<Void, Never>?
    @State private var isLockedDragHintActive = false
    @State private var lockedDragHintTask: Task<Void, Never>?
    @State private var failureAutoDismissTask: Task<Void, Never>?
    /// 自己量出来的内容宽度：宽度参与折行，所以高度得跟着它变。
    @State private var contentWidth: CGFloat = 0

    private var fontSize: CaptionBandFontSize {
        CaptionBandFontSize(rawValue: fontSizeRaw) ?? .standard
    }

    private var backgroundStyle: CaptionBandBackgroundStyle {
        CaptionBandBackgroundStyle(rawValue: backgroundStyleRaw) ?? .standard
    }

    private var content: CaptionBandContent { session.bandContent }

    private var effectiveContentWidth: CGFloat {
        contentWidth > 0 ? contentWidth : SpeechRailDesignTokens.Layout.captionBandDefaultWidth
    }

    private var metrics: CaptionBandMetrics {
        CaptionBandMetrics.current(
            content: content,
            blocked: session.blocked,
            fontSize: fontSize,
            isHovering: isHovering,
            contentWidth: effectiveContentWidth,
            speakerBadgeResolver: session.labeling.isEnabled
                ? { session.labeling.displayText(for: $0) }
                : nil
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Layout.captionBandSpacing) {
            if isHovering {
                toolbar
            }
            if let blocked = session.blocked {
                blockedRow(blocked)
                if !content.rows.isEmpty { linesScroll }
            } else if content.rows.isEmpty {
                emptyListeningStateRow
            } else {
                linesScroll
            }
            footer
        }
        .padding(.vertical, SpeechRailDesignTokens.Layout.captionBandPaddingV)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if backgroundStyle.dimmerOpacity > 0 {
                Color.black.opacity(backgroundStyle.dimmerOpacity)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if !isHovering {
                topEdgeGrabberPill
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            contentWidth = width
        }
        .onHover { hovering in
            isHovering = hovering
            onMetricsChange(metrics)
        }
        .onChange(of: metrics, initial: true) { _, metrics in
            onMetricsChange(metrics)
        }
        // 吸附这套状态机要收口在"目标 + 模式"两件事上：换目标窗口、点工具条的
        // 吸附/自由悬浮、以及会话层自己改模式，走同一条重挂路径。
        .onChange(of: session.audioTarget) { _, _ in
            onTrackingChange()
        }
        .onChange(of: session.placementMode) { _, _ in
            onTrackingChange()
        }
        .onChange(of: session.lastFailure) { _, newFailure in
            failureAutoDismissTask?.cancel()
            if newFailure != nil {
                failureAutoDismissTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled else { return }
                    session.clearFailure()
                }
            }
        }
        // 打开时把"钉住"的状态推给窗口：它是跨会话记住的，不能等用户再点一次才生效。
        .onAppear { onPinChange(isPinned) }
        // 窗口收起后别再让旧倒计时去清下一场的提示。
        .onDisappear { failureAutoDismissTask?.cancel() }
        .operationFeedback([
            recoveryFeedback,
            OperationFeedback(session.exportFailure, title: "字幕未导出", onDismiss: { session.clearExportFailure() }),
            OperationFeedback(copyFailure, title: "复制未完成", onDismiss: { copyFailure = nil }),
            OperationFeedback(copyNotice, tone: .healthy, title: "已复制", id: copyNoticeID.uuidString, autoDismiss: true,
                              onDismiss: { copyNotice = nil })
        ])
    }

    // MARK: 字幕行

    private var linesScroll: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(content.rows) { line in
                    lineRow(line: line)
                        .id(line.id)
                }
            }
        }
        .scrollIndicators(.never)
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(transcriptFollow.isPinnedToBottom ? .bottom : nil, for: .sizeChanges)
        .onScrollPhaseChange { oldPhase, phase, context in
            let wasUserScroll = oldPhase == .interacting || oldPhase == .decelerating
            let isUserScroll = phase == .interacting || phase == .decelerating
            userScrollActive = isUserScroll
            guard wasUserScroll || isUserScroll else { return }
            updateFollowing(
                contentBottomY: context.geometry.contentSize.height,
                viewportBottomY: context.geometry.visibleRect.maxY,
                isUserInitiated: true
            )
        }
        .onScrollGeometryChange(for: TranscriptFollowState.ScrollProximity.self) { geometry in
            TranscriptFollowState.scrollProximity(
                contentBottomY: Double(geometry.contentSize.height),
                viewportBottomY: Double(geometry.visibleRect.maxY)
            )
        } action: { _, proximity in
            let updated = transcriptFollow.geometryChanged(to: proximity, isUserInitiated: userScrollActive)
            if updated != transcriptFollow { transcriptFollow = updated }
        }
        .onChange(of: content) { _, _ in scrollToLatestIfFollowing() }
    }

    /// 尚未产出首句字幕时的聆听/准备中占位引导（对齐 macOS 实时字幕与主流同传工具体验，避免空白框让用户困惑）。
    private var emptyListeningStateRow: some View {
        HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.sm) {
            if session.phase == .preparing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: session.phase == .paused ? "pause.circle.fill" : "waveform.badge.magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(
                        session.phase == .paused
                            ? SpeechRailDesignTokens.Color.attention
                            : SpeechRailDesignTokens.Color.rail
                    )
                    .symbolEffect(.pulse, isActive: session.phase == .running)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(emptyListeningPrimaryText)
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(1)
                Text(emptyListeningSecondaryText)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SpeechRailDesignTokens.Layout.captionLinePaddingH)
        .padding(.vertical, SpeechRailDesignTokens.Layout.captionLinePaddingV)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .overlay {
            CaptionBandDragRegion(
                isPinned: isPinned,
                showsHandCursor: !isPinned,
                onLockedDragAttempt: triggerLockedDragHint
            )
        }
    }

    private var emptyListeningPrimaryText: String {
        switch session.phase {
        case .preparing:
            return "正在连接语音识别引擎…"
        case .paused:
            return "实时字幕已暂停 · 按 ⌘⇧L 或点击上方播放键继续"
        case .ending:
            return "正在收尾并保存字幕记录…"
        case .running, .idle:
            let targetName = session.audioTarget?.displayTitle ?? "麦克风"
            return "正在聆听「\(targetName)」· 检测到语音后实时出字…"
        }
    }

    private var emptyListeningSecondaryText: String {
        let langText = "原音：\(sourceLanguageItemTitle(session.sourceLanguage))"
        let transText = session.translationEnabled
            ? "同传翻译：\(session.displayMode.title)"
            : "同传翻译：未开启（可在上方工具栏或右下角开启双语对照）"
        return "\(langText) · \(transText)"
    }

    private func lineRow(line: CaptionBandContent.Row) -> some View {
        HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.xs) {
            if line.isPartial {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(SpeechRailDesignTokens.Color.rail.opacity(0.75))
                    .frame(width: 3)
                    .padding(.vertical, 3)
            }
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                HStack(alignment: .firstTextBaseline, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    if session.labeling.isEnabled, let speakerLabel = line.speakerLabel, !speakerLabel.isEmpty {
                        Text(session.labeling.displayText(for: speakerLabel))
                            .font(SpeechRailDesignTokens.Typography.captionMedium)
                            .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(SpeechRailDesignTokens.Color.rail.opacity(0.14), in: Capsule())
                            .fixedSize()
                    }
                    tieredText(
                        line.primaryText,
                        tiering: line.primaryTiering
                            ?? line.sourceTiering.flatMap { $0.isSecondary ? nil : $0 },
                        baseColor: line.isPartial
                            ? SpeechRailDesignTokens.Color.inkSecondary
                            : SpeechRailDesignTokens.Color.ink
                    )
                        .font(fontSize.font)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if line.isTranslating {
                        HStack(spacing: 3) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("翻译中")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                        }
                    } else if line.isPartial {
                        Text("正在识别…")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    }
                }
                if let secondary = line.secondaryText, !secondary.isEmpty {
                    tieredText(
                        secondary,
                        tiering: line.sourceTiering.flatMap { $0.isSecondary ? $0 : nil },
                        baseColor: SpeechRailDesignTokens.Color.inkSecondary
                    )
                        .font(SpeechRailDesignTokens.Typography.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Layout.captionLinePaddingH)
        .padding(.vertical, SpeechRailDesignTokens.Layout.captionLinePaddingV)
        .contentShape(Rectangle())
        .overlay {
            CaptionBandDragRegion(
                isPinned: isPinned,
                showsHandCursor: !isPinned,
                onLockedDragAttempt: triggerLockedDragHint
            )
        }
        .contextMenu {
            if let secondary = line.secondaryText, !secondary.isEmpty, secondary != line.primaryText {
                Button("复制此段（双语）") {
                    copyTextToPasteboard("\(line.primaryText)\n\(secondary)")
                }
                Button("仅复制译文") {
                    copyTextToPasteboard(line.primaryText)
                }
                Button("仅复制原文") {
                    copyTextToPasteboard(secondary)
                }
            } else {
                Button("复制此段") {
                    copyTextToPasteboard(line.primaryText)
                }
            }
        }
    }

    /// 未定稿文本的视觉分层：稳定前缀用正文色，活跃尾部保持最浅一档（`spec §11.1`）。
    ///
    /// 原文和译文都可能分层：原文来自相邻 partial 的公共前缀，译文来自两次预览的
    /// LocalAgreement。两者都只是显示优化，不承诺这段文字不可改写。
    private func tieredText(
        _ text: String,
        tiering: CaptionBandContent.Row.SourceTiering?,
        baseColor: Color
    ) -> Text {
        // 分层是一根字符串的切分，只能用在它自己那根字符串上：拼不回 `text` 就说明这份分层
        // 描述的是另一格的内容（例如把原文的分层挂到了译文格），此时宁可整行同色，
        // 也绝不把原文画进该显示译文的位置。
        guard let tiering, tiering.stablePrefix + tiering.volatileTail == text else {
            return Text(text).foregroundStyle(baseColor)
        }
        return Text("\(Text(tiering.stablePrefix).foregroundStyle(baseColor))\(Text(tiering.volatileTail).foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary))")
    }

    // MARK: 悬停工具条

    private var toolbar: some View {
        // 一次求值只问一次能力：`isTranslationAvailable` 会构造一次翻译客户端，
        // 菜单标签、帮助和禁用状态不该各构造一遍。
        let translationAvailable = session.isTranslationAvailable
        let isDocked = session.placementMode == .dockedToTargetWindow
        return HStack(spacing: SpeechRailDesignTokens.Layout.captionBandToolbarSpacing) {
            iconButton(
                systemImage: session.phase == .running ? "pause.fill" : "play.fill",
                label: session.phase == .running ? "暂停实时字幕（快捷键 ⌘⇧L）" : "继续实时字幕（快捷键 ⌘⇧L）",
                role: session.phase == .running ? .activeAccent : .warningAccent
            ) {
                Task {
                    if session.phase == .running {
                        await session.pause()
                    } else {
                        await session.resume()
                    }
                }
            }
            targetAppButton
            sourceLanguageMenu
            translationMenu(isAvailable: translationAvailable)
            fontMenu
            toolbarDragGrip
            if session.audioTarget?.isApp == true {
                iconButton(
                    systemImage: isDocked ? "dock.rectangle" : "macwindow.on.rectangle",
                    label: isDocked
                        ? "已吸附于目标窗口底部（点击转为自由悬停）"
                        : "当前为自由悬停（点击吸附至目标窗口底部）",
                    role: isDocked ? .activeAccent : .standard
                ) {
                    if isDocked {
                        session.placementMode = .freeFloatingPinned
                    } else {
                        session.placementMode = .dockedToTargetWindow
                    }
                }
            }
            iconButton(
                systemImage: isCopyConfirmed ? "checkmark" : "doc.on.doc",
                label: isCopyConfirmed ? "已复制当前字幕段" : "复制当前显示的最新字幕段落",
                role: isCopyConfirmed ? .successAccent : .standard
            ) {
                copyCurrentSegment()
            }
            iconButton(
                systemImage: "square.and.arrow.down",
                label: "将本次字幕导出为 SRT 字幕文件…"
            ) {
                Task { await session.exportSRT() }
            }
            iconButton(
                systemImage: isPinned ? "pin.fill" : "pin",
                label: isPinned ? "已钉住字幕条位置（点击解锁拖动）" : "钉住字幕条位置（锁定后防止误触拖动）",
                role: isPinned ? .activeAccent : .standard
            ) {
                isPinned.toggle()
                onPinChange(isPinned)
            }
            iconButton(
                systemImage: "xmark",
                label: "结束本次字幕并保存记录",
                role: .destructiveHover
            ) {
                onClose()
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Layout.captionBandToolbarPaddingH)
        .padding(.vertical, SpeechRailDesignTokens.Layout.captionBandToolbarPaddingV)
        .background(
            RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Layout.captionBandToolbarCornerRadius)
                .fill(SpeechRailDesignTokens.Surface.floatingToolbarMaterial)
        )
        .padding(.horizontal, SpeechRailDesignTokens.Layout.captionBandToolbarPaddingH)
        .accessibilityIdentifier("caption-band-toolbar")
    }

    /// 未悬停时贴在字幕带顶边中央的微胶囊抓手指示条（不占布局高度，直觉提示此处为可拖拽浮层）。
    private var topEdgeGrabberPill: some View {
        Capsule(style: .continuous)
            .fill(
                isPinned
                    ? SpeechRailDesignTokens.Color.attention.opacity(0.45)
                    : SpeechRailDesignTokens.Color.inkTertiary.opacity(0.38)
            )
            .frame(width: 38, height: 4)
            .padding(.top, 4)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// 工具栏中部显式拖拽手柄（未锁定时显示抓手与按住拖动提示 + 手型光标；锁定时一键点击解锁）。
    @ViewBuilder
    private var toolbarDragGrip: some View {
        if isPinned {
            Button {
                isPinned = false
                isLockedDragHintActive = false
                onPinChange(false)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("位置已钉住 · 点击解锁拖动")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .lineLimit(1)
                }
                .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(CaptionBandChipButtonStyle(isActive: false))
            .help("当前字幕条已锁定位置，点击即可解锁并自由拖动窗口")
            .speechRailPointerCursor()
        } else {
            CaptionBandToolbarDragHandle(onLockedDragAttempt: triggerLockedDragHint)
                .frame(maxWidth: .infinity, minHeight: SpeechRailDesignTokens.Layout.captionBandIconButtonSize)
                .help("按住此处（或直接按住下方字幕区域）即可拖动字幕窗口位置")
                .accessibilityLabel("拖动字幕窗口")
        }
    }

    private var targetAppButton: some View {
        Button {
            Task { await session.promptSelectTarget() }
        } label: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                Image(systemName: session.audioTarget?.isApp == true ? "macwindow" : "mic.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                Text(session.audioTarget?.displayTitle ?? "选择目标")
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(1)
                    .frame(maxWidth: 120)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            .padding(.horizontal, SpeechRailDesignTokens.Layout.captionBandTagPaddingH)
            .padding(.vertical, SpeechRailDesignTokens.Layout.captionBandTagPaddingV)
        }
        .buttonStyle(CaptionBandChipButtonStyle(isActive: session.audioTarget != nil))
        .help(session.audioTarget.map { "当前收音目标：\($0.displayTitle)（点击切换应用窗口或麦克风）" } ?? "选择要捕获音频的应用窗口或麦克风")
        .accessibilityLabel("收音目标 \(session.audioTarget?.displayTitle ?? "未选择")")
        .speechRailPointerCursor()
    }

    private func sourceLanguageItemTitle(_ lang: CaptionSourceLanguage) -> String {
        switch lang {
        case .auto: "自动识别原音"
        case .english: "英语原音"
        case .japanese: "日语原音"
        case .korean: "韩语原音"
        case .chinese: "中文原音（不翻译）"
        }
    }

    private var sourceLanguageMenu: some View {
        Menu {
            ForEach(CaptionSourceLanguage.allCases) { lang in
                Button {
                    session.sourceLanguage = lang
                } label: {
                    if session.sourceLanguage == lang {
                        Label(sourceLanguageItemTitle(lang), systemImage: "checkmark")
                    } else {
                        Text(sourceLanguageItemTitle(lang))
                    }
                }
            }
        } label: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                Image(systemName: "globe")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(session.sourceLanguage == .auto ? SpeechRailDesignTokens.Color.inkSecondary : SpeechRailDesignTokens.Color.rail)
                Text("原音 \(session.sourceLanguage.shortLabel)")
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Image(systemName: "chevron.down")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            .padding(.horizontal, SpeechRailDesignTokens.Layout.captionBandTagPaddingH)
            .padding(.vertical, SpeechRailDesignTokens.Layout.captionBandTagPaddingV)
            .modifier(CaptionBandHoverChipModifier(isActive: session.sourceLanguage != .auto))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("当前音频原音语种：\(sourceLanguageItemTitle(session.sourceLanguage)) · 选「中文原音」时直通不翻译；外语或中英混说请选「自动识别原音」或对应外语")
        .accessibilityLabel("原音语种 \(session.sourceLanguage.title)")
        .speechRailPointerCursor()
    }

    private func translationMenu(isAvailable: Bool) -> some View {
        let isActive = session.translationEnabled && isAvailable
        return Menu {
            translationMenuContent
        } label: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                Image(systemName: "translate")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isActive
                        ? SpeechRailDesignTokens.Color.rail
                        : SpeechRailDesignTokens.Color.inkSecondary)
                Text(translationMenuTitle(isAvailable: isAvailable))
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(isActive ? SpeechRailDesignTokens.Color.rail : SpeechRailDesignTokens.Color.ink)
                Image(systemName: "chevron.down")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(isActive ? SpeechRailDesignTokens.Color.rail.opacity(0.8) : SpeechRailDesignTokens.Color.inkSecondary)
            }
            .padding(.horizontal, SpeechRailDesignTokens.Layout.captionBandTagPaddingH)
            .padding(.vertical, SpeechRailDesignTokens.Layout.captionBandTagPaddingV)
            .modifier(CaptionBandHoverChipModifier(isActive: isActive))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(translationMenuHelp(isAvailable: isAvailable))
        .accessibilityLabel("翻译 \(translationMenuTitle(isAvailable: isAvailable))")
        .speechRailPointerCursor()
    }

    /// 浮层工具条和页脚共用同一份菜单内容，避免两处各写一套开关语义。
    @ViewBuilder
    private var translationMenuContent: some View {
        let isAvailable = session.isTranslationAvailable
        Button {
            session.translationEnabled = false
        } label: {
            if session.translationEnabled {
                Text("不翻译，只看原文")
            } else {
                Label("不翻译，只看原文", systemImage: "checkmark")
            }
        }
        Divider()
        Button {
            enableTranslation(mode: .bilingual)
        } label: {
            if session.translationEnabled, session.displayMode == .bilingual {
                Label("双语对照", systemImage: "checkmark")
            } else {
                Text("双语对照")
            }
        }
        .disabled(!isAvailable)
        Button {
            enableTranslation(mode: .chineseOnly)
        } label: {
            if session.translationEnabled, session.displayMode == .chineseOnly {
                Label("仅中文", systemImage: "checkmark")
            } else {
                Text("仅中文")
            }
        }
        .disabled(!isAvailable)
        if !isAvailable {
            Divider()
            Text("还没有配置翻译模型")
            Text("设置 → 助手 → 实时字幕翻译")
        }
    }

    /// 页脚常驻的小入口：不悬停也能看见翻译开没开、点一下就能切换。
    private var translationFooterControl: some View {
        Menu {
            translationMenuContent
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "translate")
                    .font(.system(size: 11, weight: .medium))
                if session.translationEnabled {
                    Text(session.displayMode == .chineseOnly ? "中" : "双语")
                        .font(.system(size: 10, weight: .medium))
                }
            }
            .foregroundStyle(session.translationEnabled
                ? SpeechRailDesignTokens.Color.rail
                : SpeechRailDesignTokens.Color.inkTertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .modifier(CaptionBandHoverChipModifier(isActive: session.translationEnabled))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(footerTranslationHelp)
        .accessibilityLabel(footerTranslationHelp)
        .accessibilityIdentifier("caption-band-translation")
        .speechRailPointerCursor()
    }

    private var footerTranslationHelp: String {
        guard session.translationEnabled else { return "同传翻译已关闭 · 点击快速开启双语对照或仅中文" }
        return "同传翻译已开启（\(session.displayMode.title)）· 点击切换排版或关闭"
    }

    private func translationMenuTitle(isAvailable: Bool) -> String {
        guard session.translationEnabled else { return "翻译 关" }
        guard isAvailable else { return "翻译 未配置" }
        return session.displayMode == .chineseOnly ? "翻译 仅中文" : "翻译 双语"
    }

    private func translationMenuHelp(isAvailable: Bool) -> String {
        if !isAvailable {
            return "还没有配置翻译模型：请前往「设置 → 助手 → 实时字幕翻译」配置"
        }
        return session.translationEnabled
            ? "实时翻译已开启（\(session.displayMode.title)）· 点击切换双语对照 / 仅中文或关闭"
            : "点击开启实时中文字幕翻译（支持双语对照 / 仅中文，中文音源自动直通不耗流）"
    }

    private func enableTranslation(mode: CaptionDisplayMode) {
        guard session.isTranslationAvailable else { return }
        // 若原音语种此前停留在「中文（不翻译）」，开启翻译时自动切回「自动识别」，否则外语会被当作中文跳过翻译。
        if session.sourceLanguage == .chinese {
            session.sourceLanguage = .auto
        }
        // 先定排版、再打开开关：反过来会先用旧排版触发一次补翻。
        session.displayMode = mode
        session.translationEnabled = true
    }

    private var fontMenu: some View {
        Menu {
            Section("字幕字号") {
                ForEach(CaptionBandFontSize.allCases) { size in
                    Button {
                        fontSizeRaw = size.rawValue
                    } label: {
                        if fontSize == size {
                            Label(size.title, systemImage: "checkmark")
                        } else {
                            Text(size.title)
                        }
                    }
                }
            }
            Divider()
            Section("背景对比度") {
                ForEach(CaptionBandBackgroundStyle.allCases) { style in
                    Button {
                        backgroundStyleRaw = style.rawValue
                    } label: {
                        if backgroundStyle == style {
                            Label(style.title, systemImage: "checkmark")
                        } else {
                            Text(style.title)
                        }
                    }
                }
            }
            Divider()
            Button {
                onResetPosition()
            } label: {
                Label("回到屏幕底部居中", systemImage: "arrow.uturn.backward.square")
            }
        } label: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                Image(systemName: "textformat.size")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Text(fontSize.title)
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Image(systemName: "chevron.down")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            .padding(.horizontal, SpeechRailDesignTokens.Layout.captionBandTagPaddingH)
            .padding(.vertical, SpeechRailDesignTokens.Layout.captionBandTagPaddingV)
            .modifier(CaptionBandHoverChipModifier(isActive: false))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("字幕外观与位置：当前字号「\(fontSize.title)」、衬底「\(backgroundStyle.title)」（点击可调整字号、背景对比度或居中归位）")
        .accessibilityLabel("字号与外观 \(fontSize.title)")
        .speechRailPointerCursor()
    }

    private func iconButton(
        systemImage: String,
        label: String,
        role: CaptionBandIconButtonRole = .standard,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(
                    width: SpeechRailDesignTokens.Layout.captionBandIconButtonSize,
                    height: SpeechRailDesignTokens.Layout.captionBandIconButtonSize
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(CaptionBandIconButtonStyle(role: role))
        .help(label)
        .accessibilityLabel(label)
        .speechRailPointerCursor()
    }

    // MARK: 页脚与受阻

    private var footer: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            statusDot
            Text(session.transcriptionStatusText ?? footerHint)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(
                    isLockedDragHintActive
                        ? SpeechRailDesignTokens.Color.attention
                        : SpeechRailDesignTokens.Color.inkTertiary
                )
                // 一行到底：页脚的高度是按一行算进窗口高度的，折行会把内容顶出窗口。
                .lineLimit(1)
                .truncationMode(.tail)
                .help(footerHelp)
                .background {
                    CaptionBandDragRegion(
                        isPinned: isPinned,
                        showsHandCursor: !isPinned,
                        onLockedDragAttempt: triggerLockedDragHint
                    )
                }
            if session.lastFailure != nil && session.transcriptionStatusText == nil {
                Button {
                    failureAutoDismissTask?.cancel()
                    session.clearFailure()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                }
                .buttonStyle(.borderless)
                .help("清除提示")
                .accessibilityLabel("清除提示")
                .speechRailPointerCursor()
            }
            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                .contentShape(Rectangle())
                .overlay {
                    CaptionBandDragRegion(
                        isPinned: isPinned,
                        showsHandCursor: !isPinned,
                        onLockedDragAttempt: triggerLockedDragHint
                    )
                }
            if isPinned {
                Button {
                    isPinned = false
                    isLockedDragHintActive = false
                    onPinChange(false)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "pin.slash.fill")
                            .font(.system(size: 10, weight: .medium))
                        Text("解锁移动")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                }
                .buttonStyle(CaptionBandChipButtonStyle(isActive: false))
                .help("字幕条位置已钉住，点击即可解锁拖动")
                .speechRailPointerCursor()
            }
            translationFooterControl
            if !session.saveRecoveryRecords.isEmpty {
                Button("未保存文字") { showsSaveRecovery = true }
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .buttonStyle(CaptionBandChipButtonStyle(isActive: true))
                    .help("重试保存、复制未保存文字或处理不完整记录")
                    .popover(isPresented: $showsSaveRecovery) {
                        TranscriptSaveRecoveryPanel(
                            records: session.saveRecoveryRecords,
                            preview: { session.unsavedTranscriptText(recordID: $0) },
                            retry: { await session.retryPendingSaves(recordID: $0) },
                            finishIncomplete: { await session.endIncompleteRecord($0) },
                            onFeedback: { recoveryFeedback = $0 }
                        )
                        .padding(SpeechRailDesignTokens.Spacing.md)
                        .frame(width: SpeechRailDesignTokens.Layout.inspectorColumnWidth)
                    }
            }
            if !transcriptFollow.isPinnedToBottom {
                Button {
                    transcriptFollow = transcriptFollow.jumpToLatest(anchor: nil)
                    scrollToLatest()
                } label: {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                        Image(systemName: "chevron.down")
                        Text("回到最新")
                    }
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                }
                .buttonStyle(CaptionBandChipButtonStyle(isActive: true))
                .help("滚动回到底部并继续跟随最新字幕")
                .accessibilityIdentifier("caption-band-return-latest")
                .speechRailPointerCursor()
            }
            levelBars
        }
        .padding(.horizontal, SpeechRailDesignTokens.Layout.captionBandFootPaddingH)
        .padding(.vertical, SpeechRailDesignTokens.Layout.captionBandFootPaddingV)
    }

    private var statusDot: some View {
        Circle()
            .fill(statusIndicatorColor)
            .frame(width: 6, height: 6)
    }

    private var statusIndicatorColor: Color {
        if session.blocked != nil {
            return SpeechRailDesignTokens.Color.attention
        }
        switch session.phase {
        case .running:
            return SpeechRailDesignTokens.Color.rail
        case .paused:
            return SpeechRailDesignTokens.Color.attention
        case .idle, .preparing, .ending:
            return SpeechRailDesignTokens.Color.inkTertiary.opacity(0.6)
        }
    }

    private var footerHint: String {
        if session.blocked != nil { return "" }
        if isLockedDragHintActive { return "位置已钉住锁定 · 点击右侧「解锁移动」或工具栏图钉即可拖动" }
        if !session.saveRecoveryRecords.isEmpty { return "有文字尚未保存" }
        if session.phase == .paused { return isPinned ? "已暂停 · 位置已钉住 · ⌘⇧L 继续" : "已暂停 · 按住任意位置可拖动 · ⌘⇧L 继续" }
        if session.phase == .ending { return "正在保存最后一句…" }
        if let failure = session.lastFailure { return failure }
        if isPinned { return "位置已钉住 · ⌘⇧L 暂停 · ✕ 结束并保存" }
        return "按住字幕或手柄可拖动 · ⌘⇧L 暂停 · ✕ 结束"
    }

    /// 悬停提示：贴上去才需要看全文（页脚只放得下一行）。
    private var footerHelp: String {
        guard session.blocked == nil, let failure = session.lastFailure else { return footerHint }
        return failure
    }

    /// 真实电平，不是自走的动画。形状对着稿的 `levelBars`：**14 根、中间高两端低**，
    /// 条高**不**跟着电平动——读数靠颜色分辨（已到达 / 未到达），条高一动就变成动画了。
    private var levelBars: some View {
        let layout = SpeechRailDesignTokens.Layout.self
        let count = layout.captionBandLevelBarCount
        let ratio = min(max(session.level, 0), 1)
        let lit = Int((Double(count) * ratio).rounded())
        return HStack(alignment: .bottom, spacing: layout.captionBandLevelBarSpacing) {
            ForEach(0..<count, id: \.self) { index in
                let shape = count > 1 ? sin(.pi * Double(index) / Double(count - 1)) : 1
                let height = max(
                    layout.captionBandLevelBarWidth,
                    (layout.captionBandLevelBarHeight * (0.35 + 0.65 * shape)).rounded()
                )
                RoundedRectangle(
                    cornerRadius: layout.captionBandLevelBarCornerRadius,
                    style: .continuous
                )
                .fill(
                    index < lit
                        ? SpeechRailDesignTokens.Color.rail
                        : SpeechRailDesignTokens.Color.inkTertiary.opacity(0.3)
                )
                .frame(width: layout.captionBandLevelBarWidth, height: height)
            }
        }
        .frame(height: layout.captionBandLevelBarHeight, alignment: .bottom)
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
                Button("打开\(session.activeOwnerTitle)的文字记录") {
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
        case .noTargetSelected:
            Button("选择目标窗口") {
                Task { await session.promptSelectTarget() }
            }
        case .systemAudioUnavailable:
            Button("切换为麦克风收音") {
                Task { await session.selectTarget(.microphone) }
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
        copyTextToPasteboard(text)
    }

    private func copyTextToPasteboard(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(trimmed, forType: .string) else {
            copyFailure = "字幕暂时未能复制，请重试。"
            return
        }
        copyNoticeID = UUID()
        copyNotice = "已复制当前字幕。"
        copyConfirmationTask?.cancel()
        isCopyConfirmed = true
        copyConfirmationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            isCopyConfirmed = false
        }
    }

    private func triggerLockedDragHint() {
        guard isPinned else { return }
        lockedDragHintTask?.cancel()
        isLockedDragHintActive = true
        lockedDragHintTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            isLockedDragHintActive = false
        }
    }

    private func scrollToLatestIfFollowing() {
        guard transcriptFollow.isPinnedToBottom else { return }
        scrollToLatest()
    }

    /// 跟随态下把视图滚到底：新行出现时用户已经在看最新那一句，不该还要自己滚。
    private func scrollToLatest() {
        scrollPosition.scrollTo(edge: .bottom)
    }

    private func updateFollowing(contentBottomY: CGFloat, viewportBottomY: CGFloat, isUserInitiated: Bool) {
        let proximity = TranscriptFollowState.scrollProximity(
            contentBottomY: Double(contentBottomY), viewportBottomY: Double(viewportBottomY)
        )
        let updated = transcriptFollow.geometryChanged(to: proximity, isUserInitiated: isUserInitiated)
        if updated != transcriptFollow { transcriptFollow = updated }
    }
}

// MARK: - 浮层按钮与胶囊微交互样式

enum CaptionBandIconButtonRole: Sendable, Equatable {
    case standard
    case activeAccent
    case warningAccent
    case successAccent
    case destructiveHover
}

/// 字幕条图标按钮的高触感 ButtonStyle：提供语义色彩、悬停微胶囊高亮与按压回弹。
struct CaptionBandIconButtonStyle: ButtonStyle {
    let role: CaptionBandIconButtonRole

    func makeBody(configuration: Configuration) -> some View {
        CaptionBandIconButtonBody(configuration: configuration, role: role)
    }
}

private struct CaptionBandIconButtonBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    let configuration: ButtonStyle.Configuration
    let role: CaptionBandIconButtonRole

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
    }

    var body: some View {
        configuration.label
            .foregroundStyle(foregroundColor)
            .background {
                shape.fill(backgroundColor)
            }
            .overlay {
                if let borderColor {
                    shape.strokeBorder(borderColor, lineWidth: 0.75)
                }
            }
            .scaleEffect(
                configuration.isPressed && isEnabled && !reduceMotion
                    ? 0.91
                    : (isHovered && !reduceMotion ? 1.03 : 1.0)
            )
            .opacity(isEnabled ? 1 : SpeechRailDesignTokens.Interaction.disabledOpacity)
            .onHover { hovering in
                isHovered = isEnabled && hovering
            }
            .animation(
                SpeechRailDesignTokens.Motion.resolved(SpeechRailDesignTokens.Motion.hoverFeedback, reduceMotion: reduceMotion),
                value: isHovered
            )
            .animation(
                SpeechRailDesignTokens.Motion.resolved(SpeechRailDesignTokens.Motion.pressFeedback, reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }

    private var foregroundColor: Color {
        guard isEnabled else { return SpeechRailDesignTokens.Color.disabled }
        switch role {
        case .standard:
            return isHovered || configuration.isPressed
                ? SpeechRailDesignTokens.Color.ink
                : SpeechRailDesignTokens.Color.inkSecondary
        case .activeAccent:
            return SpeechRailDesignTokens.Color.rail
        case .warningAccent:
            return SpeechRailDesignTokens.Color.attention
        case .successAccent:
            return SpeechRailDesignTokens.Color.ready
        case .destructiveHover:
            return isHovered || configuration.isPressed
                ? SpeechRailDesignTokens.Color.critical
                : SpeechRailDesignTokens.Color.inkSecondary
        }
    }

    private var backgroundColor: Color {
        if configuration.isPressed {
            switch role {
            case .standard:
                return SpeechRailDesignTokens.Toolbar.Action.pressedFill
            case .activeAccent:
                return SpeechRailDesignTokens.Color.rail.opacity(0.26)
            case .warningAccent:
                return SpeechRailDesignTokens.Color.attention.opacity(0.28)
            case .successAccent:
                return SpeechRailDesignTokens.Color.ready.opacity(0.24)
            case .destructiveHover:
                return SpeechRailDesignTokens.Color.critical.opacity(0.24)
            }
        }
        if isHovered {
            switch role {
            case .standard:
                return SpeechRailDesignTokens.Toolbar.Action.hoverFill
            case .activeAccent:
                return SpeechRailDesignTokens.Color.rail.opacity(0.18)
            case .warningAccent:
                return SpeechRailDesignTokens.Color.attention.opacity(0.20)
            case .successAccent:
                return SpeechRailDesignTokens.Color.ready.opacity(0.16)
            case .destructiveHover:
                return SpeechRailDesignTokens.Color.critical.opacity(0.14)
            }
        }
        switch role {
        case .standard, .destructiveHover:
            return Color.clear
        case .activeAccent:
            return SpeechRailDesignTokens.Color.rail.opacity(0.11)
        case .warningAccent:
            return SpeechRailDesignTokens.Color.attention.opacity(0.13)
        case .successAccent:
            return SpeechRailDesignTokens.Color.ready.opacity(0.12)
        }
    }

    private var borderColor: Color? {
        switch role {
        case .activeAccent:
            return SpeechRailDesignTokens.Color.rail.opacity(isHovered ? 0.38 : 0.22)
        case .warningAccent:
            return SpeechRailDesignTokens.Color.attention.opacity(isHovered ? 0.42 : 0.25)
        case .successAccent:
            return SpeechRailDesignTokens.Color.ready.opacity(0.32)
        case .destructiveHover:
            return isHovered ? SpeechRailDesignTokens.Color.critical.opacity(0.30) : nil
        case .standard:
            return isHovered ? SpeechRailDesignTokens.Surface.border : nil
        }
    }
}

/// 字幕条胶囊按钮（如选择收音目标、「回到最新」）的触感 ButtonStyle。
struct CaptionBandChipButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        CaptionBandChipButtonBody(configuration: configuration, isActive: isActive)
    }
}

private struct CaptionBandChipButtonBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    let configuration: ButtonStyle.Configuration
    let isActive: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
    }

    var body: some View {
        configuration.label
            .background {
                shape.fill(backgroundColor)
            }
            .overlay {
                shape.strokeBorder(borderColor, lineWidth: 0.75)
            }
            .scaleEffect(
                configuration.isPressed && isEnabled && !reduceMotion ? 0.96 : 1.0
            )
            .onHover { hovering in
                isHovered = isEnabled && hovering
            }
            .animation(
                SpeechRailDesignTokens.Motion.resolved(SpeechRailDesignTokens.Motion.hoverFeedback, reduceMotion: reduceMotion),
                value: isHovered
            )
            .animation(
                SpeechRailDesignTokens.Motion.resolved(SpeechRailDesignTokens.Motion.pressFeedback, reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }

    private var backgroundColor: Color {
        if configuration.isPressed {
            return isActive
                ? SpeechRailDesignTokens.Color.rail.opacity(0.22)
                : SpeechRailDesignTokens.Toolbar.Action.pressedFill
        }
        if isHovered {
            return isActive
                ? SpeechRailDesignTokens.Color.rail.opacity(0.15)
                : SpeechRailDesignTokens.Toolbar.Action.hoverFill
        }
        return isActive
            ? SpeechRailDesignTokens.Color.rail.opacity(0.08)
            : Color.primary.opacity(0.04)
    }

    private var borderColor: Color {
        if isActive {
            return SpeechRailDesignTokens.Color.rail.opacity(isHovered ? 0.36 : 0.20)
        }
        return isHovered
            ? SpeechRailDesignTokens.Surface.border
            : SpeechRailDesignTokens.Surface.border.opacity(0.55)
    }
}

/// 字幕条下拉菜单胶囊（翻译、源语种、字号）的悬停高亮与激活态边框修饰器。
struct CaptionBandHoverChipModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    let isActive: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background {
                shape.fill(backgroundColor)
            }
            .overlay {
                shape.strokeBorder(borderColor, lineWidth: 0.75)
            }
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(
                SpeechRailDesignTokens.Motion.resolved(SpeechRailDesignTokens.Motion.hoverFeedback, reduceMotion: reduceMotion),
                value: isHovered
            )
    }

    private var backgroundColor: Color {
        if isHovered {
            return isActive
                ? SpeechRailDesignTokens.Color.rail.opacity(0.18)
                : SpeechRailDesignTokens.Toolbar.Action.hoverFill
        }
        return isActive
            ? SpeechRailDesignTokens.Color.rail.opacity(0.10)
            : Color.primary.opacity(0.04)
    }

    private var borderColor: Color {
        if isActive {
            return SpeechRailDesignTokens.Color.rail.opacity(isHovered ? 0.38 : 0.22)
        }
        return isHovered
            ? SpeechRailDesignTokens.Surface.border
            : SpeechRailDesignTokens.Surface.border.opacity(0.5)
    }
}

/// 工具栏中部显式拖拽抓手区：提供清晰的六点抓手图标、胶囊提示与手型光标反馈。
private struct CaptionBandToolbarDragHandle: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    let onLockedDragAttempt: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "circle.grid.2x3.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(
                    isHovered
                        ? SpeechRailDesignTokens.Color.inkSecondary
                        : SpeechRailDesignTokens.Color.inkTertiary
                )
            Text(isHovered ? "按住拖动窗口" : "按住拖动")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(
                    isHovered
                        ? SpeechRailDesignTokens.Color.inkSecondary
                        : SpeechRailDesignTokens.Color.inkTertiary
                )
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Capsule(style: .continuous)
                .fill(
                    isHovered
                        ? SpeechRailDesignTokens.Toolbar.Action.hoverFill
                        : Color.primary.opacity(0.03)
                )
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(
                    isHovered
                        ? SpeechRailDesignTokens.Surface.border
                        : SpeechRailDesignTokens.Surface.border.opacity(0.35),
                    lineWidth: 0.75
                )
        }
        .overlay {
            CaptionBandDragRegion(
                isPinned: false,
                showsHandCursor: true,
                onLockedDragAttempt: onLockedDragAttempt,
                onHoverChange: { hovering in
                    isHovered = hovering
                }
            )
        }
        .animation(
            SpeechRailDesignTokens.Motion.resolved(SpeechRailDesignTokens.Motion.hoverFeedback, reduceMotion: reduceMotion),
            value: isHovered
        )
    }
}

/// AppKit 原生窗口拖拽区域：在非锁定状态下直接触发 `window.performDrag(with:)` 并显示抓手光标（🖐️ / ✊），
/// 同时透传滚轮滚动与右键上下文菜单事件；锁定状态下尝试拖拽时触发解锁提示。
private struct CaptionBandDragRegion: NSViewRepresentable {
    let isPinned: Bool
    let showsHandCursor: Bool
    let onLockedDragAttempt: () -> Void
    var onHoverChange: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> CaptionBandDragNSView {
        let view = CaptionBandDragNSView()
        view.isPinned = isPinned
        view.showsHandCursor = showsHandCursor
        view.onLockedDragAttempt = onLockedDragAttempt
        view.onHoverChange = onHoverChange
        return view
    }

    func updateNSView(_ nsView: CaptionBandDragNSView, context: Context) {
        nsView.isPinned = isPinned
        nsView.showsHandCursor = showsHandCursor
        nsView.onLockedDragAttempt = onLockedDragAttempt
        nsView.onHoverChange = onHoverChange
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

final class CaptionBandDragNSView: NSView {
    var isPinned = false
    var showsHandCursor = true
    var onLockedDragAttempt: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var isDraggingWindow = false

    override var mouseDownCanMoveWindow: Bool {
        !isPinned
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard showsHandCursor, !isPinned else { return }
        addCursorRect(bounds, cursor: isDraggingWindow ? .closedHand : .openHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        if showsHandCursor && !isPinned {
            (isDraggingWindow ? NSCursor.closedHand : NSCursor.openHand).set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
        if showsHandCursor && !isPinned {
            NSCursor.openHand.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
        if !isDraggingWindow {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !isPinned else {
            onLockedDragAttempt?()
            return
        }
        isDraggingWindow = true
        NSCursor.closedHand.set()
        window?.performDrag(with: event)
        isDraggingWindow = false
        NSCursor.openHand.set()
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}
