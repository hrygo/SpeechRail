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
    /// 半句那一行还要给右边的「正在识别…」让位。
    static func textAvailableWidth(contentWidth: CGFloat, isPartial: Bool) -> CGFloat {
        let layout = SpeechRailDesignTokens.Layout.self
        let base = contentWidth - 2 * layout.captionLinePaddingH
        guard isPartial else { return max(base, 1) }
        let label = NSAttributedString(
            string: "正在识别…",
            attributes: [.font: NSFont.preferredFont(forTextStyle: .caption1)]
        )
        return max(base - ceil(label.size().width) - SpeechRailDesignTokens.Spacing.xs, 1)
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
        contentWidth: CGFloat
    ) -> CaptionBandMetrics {
        let layout = SpeechRailDesignTokens.Layout.self
        let width = contentWidth > 0 ? contentWidth : layout.captionBandDefaultWidth
        let limit = layout.captionBandMaximumLineCount
        var rows = 0
        for line in content.rows.reversed() where rows < limit {
            rows += visualRowCount(
                for: line.primaryText,
                fontSize: fontSize,
                availableWidth: textAvailableWidth(contentWidth: width, isPartial: line.isPartial)
            )
            if let secondary = line.secondaryText, !secondary.isEmpty {
                rows += visualRowCount(
                    for: secondary,
                    style: .callout,
                    availableWidth: textAvailableWidth(contentWidth: width, isPartial: line.isPartial)
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
        }
        return NSRect(
            x: x,
            y: targetFrame.minY + SpeechRailDesignTokens.CaptionBand.dockedBottomInset,
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
        guard let panel else { return }
        // 跟踪器的吸附改帧也会发这条通知（`setFrame` 同步发一次）。落点仍等于吸附目标
        // 位置时那是"我们搬的"，不能算用户拖动：否则 15Hz 跟随会在第一帧停掉自己，
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
    /// 受阻时那条「打开会议转录」的出口。浮层不认识路由表，出口由 App 接。
    let onOpenActiveSession: () -> Void
    let onClose: () -> Void

    @AppStorage(SpeechRailDesignTokens.CaptionBand.fontSizeDefaultsKey)
    private var fontSizeRaw = CaptionBandFontSize.standard.rawValue
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
    /// 自己量出来的内容宽度：宽度参与折行，所以高度得跟着它变。
    @State private var contentWidth: CGFloat = 0

    private var fontSize: CaptionBandFontSize {
        CaptionBandFontSize(rawValue: fontSizeRaw) ?? .standard
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
            contentWidth: effectiveContentWidth
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
            } else {
                linesScroll
            }
            footer
        }
        .padding(.vertical, SpeechRailDesignTokens.Layout.captionBandPaddingV)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        // 打开时把"钉住"的状态推给窗口：它是跨会话记住的，不能等用户再点一次才生效。
        .onAppear { onPinChange(isPinned) }
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

    private func lineRow(line: CaptionBandContent.Row) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            HStack(alignment: .firstTextBaseline, spacing: SpeechRailDesignTokens.Spacing.xs) {
                tieredSourceText(
                    line.primaryText,
                    tiering: line.sourceTiering.flatMap { $0.isSecondary ? nil : $0 },
                    baseColor: line.isPartial
                        ? SpeechRailDesignTokens.Color.inkSecondary
                        : SpeechRailDesignTokens.Color.ink
                )
                    .font(fontSize.font)
                    .textSelection(.enabled)
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
                tieredSourceText(
                    secondary,
                    tiering: line.sourceTiering.flatMap { $0.isSecondary ? $0 : nil },
                    baseColor: SpeechRailDesignTokens.Color.inkSecondary
                )
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Layout.captionLinePaddingH)
        .padding(.vertical, SpeechRailDesignTokens.Layout.captionLinePaddingV)
    }

    /// 未定稿原文的视觉分层：稳定前缀用正文色，活跃尾部保持最浅一档（`spec §11.1`）。
    ///
    /// 服务端的 `stable_prefix_codepoints` 恒为 0，所以这里的分层只是显示优化，
    /// 不承诺这段文字不可改写——正式复核仍有权改整句。
    private func tieredSourceText(
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
        return Text(tiering.stablePrefix).foregroundStyle(baseColor)
            + Text(tiering.volatileTail).foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
    }

    // MARK: 悬停工具条

    private var toolbar: some View {
        HStack(spacing: SpeechRailDesignTokens.Layout.captionBandToolbarSpacing) {
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
            targetAppButton
            sourceLanguageMenu
            displayModeMenu
            fontMenu
            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
            if session.audioTarget?.isApp == true {
                iconButton(
                    systemImage: session.placementMode == .dockedToTargetWindow ? "dock.rectangle" : "macwindow.on.rectangle",
                    label: session.placementMode == .dockedToTargetWindow ? "吸附于目标窗口（点击转为自由悬停）" : "自由悬停（点击吸附至窗口）"
                ) {
                    if session.placementMode == .dockedToTargetWindow {
                        session.placementMode = .freeFloatingPinned
                    } else {
                        session.placementMode = .dockedToTargetWindow
                    }
                }
            }
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
                .fill(SpeechRailDesignTokens.Surface.floatingToolbarMaterial)
        )
        .padding(.horizontal, SpeechRailDesignTokens.Layout.captionBandToolbarPaddingH)
        .accessibilityIdentifier("caption-band-toolbar")
    }

    private var targetAppButton: some View {
        Button {
            Task { await session.promptSelectTarget() }
        } label: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                Image(systemName: session.audioTarget?.isApp == true ? "macwindow" : "mic.fill")
                    .font(.system(size: 11))
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
        .buttonStyle(.plain)
        .help("切换收音目标应用或麦克风")
        .speechRailPointerCursor()
    }

    private var sourceLanguageMenu: some View {
        Menu {
            ForEach(CaptionSourceLanguage.allCases) { lang in
                Button {
                    session.sourceLanguage = lang
                } label: {
                    if session.sourceLanguage == lang {
                        Label(lang.title, systemImage: "checkmark")
                    } else {
                        Text(lang.title)
                    }
                }
            }
        } label: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                Image(systemName: "globe")
                    .font(.system(size: 11))
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Text(session.sourceLanguage.shortLabel)
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Image(systemName: "chevron.down")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            .padding(.horizontal, SpeechRailDesignTokens.Layout.captionBandTagPaddingH)
            .padding(.vertical, SpeechRailDesignTokens.Layout.captionBandTagPaddingV)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("源语言 \(session.sourceLanguage.title)")
        .speechRailPointerCursor()
    }

    private var displayModeMenu: some View {
        Menu {
            ForEach(CaptionDisplayMode.allCases, id: \.self) { mode in
                Button {
                    session.displayMode = mode
                } label: {
                    if session.displayMode == mode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Text(mode.title)
                    }
                }
            }
        } label: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                Image(systemName: "character.book.closed")
                    .font(.system(size: 11))
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Text(session.displayMode.title)
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Image(systemName: "chevron.down")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            .padding(.horizontal, SpeechRailDesignTokens.Layout.captionBandTagPaddingH)
            .padding(.vertical, SpeechRailDesignTokens.Layout.captionBandTagPaddingV)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("显示模式 \(session.displayMode.title)")
        .speechRailPointerCursor()
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
            // 稿里这是一颗 chip（`sizeTag` 的 padX 8 / padY 3）：多一点留白，
            // 点起来才不像在点一行文字。
            .padding(.horizontal, SpeechRailDesignTokens.Layout.captionBandTagPaddingH)
            .padding(.vertical, SpeechRailDesignTokens.Layout.captionBandTagPaddingV)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("字号 \(fontSize.title)")
        .speechRailPointerCursor()
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
        .speechRailPointerCursor()
    }

    // MARK: 页脚与受阻

    private var footer: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            statusDot
            Text(session.transcriptionStatusText ?? footerHint)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                // 一行到底：页脚的高度是按一行算进窗口高度的，折行会把内容顶出窗口。
                .lineLimit(1)
                .truncationMode(.tail)
                .help(footerHelp)
            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
            if !session.saveRecoveryRecords.isEmpty {
                Button("未保存文字") { showsSaveRecovery = true }
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .buttonStyle(.borderless)
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
                }
                .buttonStyle(.borderless)
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
            return SpeechRailDesignTokens.Color.amber
        }
        switch session.phase {
        case .running:
            return SpeechRailDesignTokens.Color.rail
        case .paused:
            return SpeechRailDesignTokens.Color.amber
        case .idle, .preparing, .ending:
            return SpeechRailDesignTokens.Color.inkTertiary.opacity(0.6)
        }
    }

    private var footerHint: String {
        if session.blocked != nil { return "" }
        if !session.saveRecoveryRecords.isEmpty { return "有文字尚未保存" }
        if session.phase == .paused { return "已暂停 · ⌘⇧L 继续" }
        if session.phase == .ending { return "正在保存最后一句…" }
        // 服务端说过"这句不行"（`failed` / `error`）时要说出来：否则那一句就这么
        // 从屏幕上消失，用户只会以为是自己没说话。完整原因在悬停提示里。
        if let failure = session.lastFailure { return "上一句没能转写 · \(failure)" }
        return "⌘⇧L 暂停 · ✕ 结束并保存"
    }

    /// 悬停提示：贴上去才需要看全文（页脚只放得下一行）。
    private var footerHelp: String {
        guard session.blocked == nil, let failure = session.lastFailure else { return footerHint }
        return "上一句没能转写：\(failure)"
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
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            copyFailure = "字幕暂时未能复制，请重试。"
            return
        }
        copyNoticeID = UUID()
        copyNotice = "已复制当前字幕。"
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
