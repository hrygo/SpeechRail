import AppKit
import SwiftUI

public enum SpeechRailDesignTokens {
    public enum Spacing {
        public static let hairline: CGFloat = 1
        public static let tight: CGFloat = 2
        public static let micro: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let sm: CGFloat = 12
        public static let md: CGFloat = 16
        public static let lg: CGFloat = 24
        public static let xl: CGFloat = 32
        public static let hero: CGFloat = 48

        // Source-compatibility aliases for compiled legacy surfaces.
        public static let xxs = micro
        public static let xxl: CGFloat = 40
    }

    public enum Layout {
        /// Navigation and inspector columns are calibrated for console stability.
        public static let sidebarWidth: CGFloat = 240
        public static let sidebarMinimumWidth: CGFloat = 220
        public static let sidebarIdealWidth: CGFloat = 240
        public static let sidebarMaximumWidth: CGFloat = 280
        public static let modelProfileListWidth: CGFloat = 280
        public static let modelProfileListMinimumWidth: CGFloat = 220
        public static let modelProfileListMaximumWidth: CGFloat = 320
        public static let inspectorWidth: CGFloat = 360
        public static let inspectorMinimumWidth: CGFloat = 300
        public static let inspectorIdealWidth: CGFloat = inspectorWidth
        public static let inspectorMaximumWidth: CGFloat = 440
        /// Page content margin. 20pt keeps the workspace readable at 1120–1280pt
        /// window widths instead of squeezing it with the old 32pt (§5.6).
        public static let contentPadding: CGFloat = 20
        public static let windowMinimumWidth: CGFloat = 1_120
        public static let windowMinimumHeight: CGFloat = 720
        /// The script gets the most space on the page (§5.6 / §7.1).
        public static let creatorComposerMinimumHeight: CGFloat = 320
        public static let creatorReferenceMinimumHeight: CGFloat = 72
        public static let creatorVoiceInstructionMinimumHeight: CGFloat = 160
        public static let creatorVoicePickerWidth: CGFloat = 180
        public static let creatorVoiceNameWidth: CGFloat = 220
        public static let creatorVoiceNameMinimumWidth: CGFloat = 160
        public static let creatorVoiceNameMaximumWidth: CGFloat = 260
        public static let creatorVoiceControlWidth: CGFloat = 240
        public static let creatorSpeedSliderWidth: CGFloat = 120
        public static let creatorSpeedValueWidth: CGFloat = 32
        public static let creatorEditorMinimumWidth: CGFloat = 520
        public static let creatorEditorMinimumHeight: CGFloat = 470
        public static let creatorEditorCloneMinimumHeight: CGFloat = 320
        public static let creatorWaveformWidth: CGFloat = 72
        public static let creatorWaveformHeight: CGFloat = 20
        public static let creatorListRowMinimumHeight: CGFloat = 72
        public static let emptyStateMinimumHeight: CGFloat = 240
        public static let modelEmptyStateMinimumHeight: CGFloat = 180
        public static let modelArtifactEmptyStateMinimumHeight: CGFloat = 130
        public static let modelFactMinimumWidth: CGFloat = 100
        public static let modelVariantWidth: CGFloat = 120
        public static let diagnosticsEmptyListMinimumHeight: CGFloat = 180
        public static let diagnosticsEmptyDetailMinimumHeight: CGFloat = 300
        public static let monitoringEmptyMinimumHeight: CGFloat = 220
        public static let monitoringChartHeight: CGFloat = 240
        public static let compactDividerHeight: CGFloat = 42
        public static let controlMenuWidth: CGFloat = 288
        // Source-compatibility alias for the menu bar popover surface.
        public static let controlMenuMinimumWidth: CGFloat = controlMenuWidth
        public static let settingsWindowMinimumWidth: CGFloat = 560
        public static let settingsWindowMinimumHeight: CGFloat = 360
        public static let diagnosticsSummaryHeight: CGFloat = 84
        public static let diagnosticsListWidth: CGFloat = 320
        public static let diagnosticsDetailMinimumWidth: CGFloat = 460
        public static let diagnosticsRowHeight: CGFloat = 44
        public static let diagnosticsBodyMinimumHeight: CGFloat = 360
        public static let monitoringCapabilityMinimumWidth: CGFloat = 280
        public static let monitoringCapabilityIdealWidth: CGFloat = 320
        public static let monitoringChartMinimumWidth: CGFloat = 320
        public static let monitoringCapabilityRowHeight: CGFloat = 58
        public static let monitoringWorkerRowHeight: CGFloat = 42
        public static let monitoringStatusColumnWidth: CGFloat = 64
        public static let metricMinimumWidth: CGFloat = 112
        public static let metricColumnCount: Int = 4
    }

    /// Native macOS menus stay compact; custom menu-bar rows use the same
    /// geometry so every action has a predictable target and rhythm.
    public enum Menu {
        public static let contentWidth: CGFloat = Layout.controlMenuWidth
        public static let contentPadding: CGFloat = Spacing.md
        public static let sectionSpacing: CGFloat = Spacing.xs
        public static let rowHeight: CGFloat = Interaction.minimumHitTarget
        public static let triggerHeight: CGFloat = Toolbar.controlHeight
        public static let triggerHorizontalPadding: CGFloat = Spacing.xs
    }

    /// List geometry is shared by sidebar navigation and custom content lists.
    /// The rows may grow vertically for explanatory copy, but their baseline and
    /// insets never change between pages.
    public enum List {
        public static let rowHeight: CGFloat = Interaction.minimumHitTarget
        public static let compactRowHeight: CGFloat = 42
        public static let tallRowHeight: CGFloat = 58
        public static let rowSpacing: CGFloat = Spacing.xs
        public static let sectionSpacing: CGFloat = Spacing.md
        public static let contentHorizontalPadding: CGFloat = Spacing.lg
        public static let contentVerticalPadding: CGFloat = Spacing.md
        public static let rowContentPadding: CGFloat = Spacing.sm
        public static let rowVerticalPadding: CGFloat = Spacing.xs
        public static let rowHorizontalPadding: CGFloat = Spacing.xs
        public static let rowIconFrame: CGFloat = Icon.navigationFrame
        public static let numericValueMinimumWidth: CGFloat = 84
        public static let numericValueMaximumWidth: CGFloat = 110
        public static let descriptionPreviewMaximumCharacters: Int = 180
        public static let dividerInset: CGFloat = Spacing.lg
        public static let disclosureContentInset: CGFloat = Spacing.lg
    }

    /// Developer-facing metadata is deliberately denser than page content. Its
    /// width is a compressible range (`Layout.inspector*Width`) so a narrow
    /// window shrinks this panel instead of displacing page content or pushing
    /// the navigation column.
    public enum Inspector {
        public static let contentPadding: CGFloat = Spacing.md
        public static let sectionSpacing: CGFloat = Spacing.md
        public static let rowSpacing: CGFloat = Spacing.sm
        public static let labelValueSpacing: CGFloat = Spacing.micro
        public static let rowVerticalPadding: CGFloat = Spacing.xs
        public static let titleMaximumLines: Int = 1
        public static let valueMaximumLines: Int = 3
        public static let bodyMaximumLines: Int = 4
        public static let actionColumnMinimumWidth: CGFloat = 120
        public static let actionGridSpacing: CGFloat = Spacing.sm
        /// Inspectors keep one label column so values line up and read as data
        /// (REDESIGN-SPEC §7.3).
        public static let labelColumnWidth: CGFloat = 92
    }

    public enum Control {
        public static let compactHeight: CGFloat = 28
        public static let regularHeight: CGFloat = 34
        public static let prominentHeight: CGFloat = 40

        public static let minimumHitTarget: CGFloat = Interaction.minimumHitTarget
        public static let iconSize: CGFloat = 16
        public static let toolbarIconSize: CGFloat = 18
        public static let iconButtonSize: CGFloat = 28
        public static let statusIconSize: CGFloat = 17
        public static let sidebarRowHeight: CGFloat = Interaction.minimumHitTarget
        public static let sidebarIconFrame: CGFloat = 20
        public static let sidebarIconSize: CGFloat = 15
        public static let workspaceTitleHeight: CGFloat = 30
        public static let purposeIndicatorWidth: CGFloat = 3
        public static let purposeIndicatorHeight: CGFloat = 14
        public static let waveformBarSpacing: CGFloat = 3
        public static let waveformBarWidth: CGFloat = 3
        public static let waveformBarRadius: CGFloat = 2
    }

    /// Settings keeps the native grouped Form semantics, while these values
    /// align its explanatory copy and control rhythm with the workspaces.
    public enum Settings {
        public static let secondaryTextMaximumLines: Int = 3
        public static let contentSpacing: CGFloat = Spacing.xs
    }

    /// The diagnostic summary stays compact in the normal case but may grow
    /// when the service returns a longer user-facing explanation.
    public enum Diagnostics {
        public static let summaryMessageMaximumLines: Int = 2
    }

    /// Toolbar dimensions are kept separate from page content so the window chrome can
    /// protect its own geometry when a route or context title becomes long.
    public enum Toolbar {
        /// macOS 26 unified compact toolbar baseline. The visual control is compact;
        /// the system still owns the larger accessibility hit region.
        public static let controlHeight: CGFloat = 32
        public static let titleMaximumWidth: CGFloat = 280
        public static let titleCompactMaximumWidth: CGFloat = 220
        public static let titleHeight: CGFloat = 32
        public static let titleMinimumScaleFactor: CGFloat = 0.82
        public static let itemSpacing: CGFloat = 8
    }

    /// Component-level button dimensions. The visual glyph may be smaller than the
    /// hit target; the hit target is never smaller than the macOS control baseline.
    public enum Button {
        public static let standardHeight: CGFloat = 34
        public static let prominentHeight: CGFloat = 40
        public static let iconHitTarget: CGFloat = Interaction.minimumHitTarget
    }

    public enum Icon {
        public static let navigationSize: CGFloat = 15
        public static let navigationFrame: CGFloat = 20
        public static let toolbarSize: CGFloat = 16
        public static let toolbarFrame: CGFloat = 24
    }

    public enum Stroke {
        public static let hairline: CGFloat = 0.5
        public static let standard: CGFloat = 0.75
        public static let strong: CGFloat = 1
    }

    public enum Shadow {
        public static let elevatedRadius: CGFloat = 12
        public static let elevatedYOffset: CGFloat = 4
    }

    /// All non-native interactive surfaces use this matrix. Native Button/Menu/
    /// NavigationLink controls retain the system's own equivalent states.
    public enum Interaction {
        public static let minimumHitTarget: CGFloat = 44
        public static let focusRingInset: CGFloat = 1
        public static let hoverFillOpacity: Double = 0.07
        public static let pressedFillOpacity: Double = 0.12
        public static let disabledOpacity: Double = 0.45
        public static let focusLineWidth: CGFloat = 2
    }

    public enum Typography {
        public static let display: Font = .system(.title2, weight: .semibold)
        public static let windowTitle: Font = .system(.title2, weight: .semibold)
        public static let sectionTitle: Font = .system(.headline, weight: .semibold)
        public static let section = sectionTitle
        public static let body: Font = .body
        /// Figma `Body / Medium`：候选卡槽位名与表格主列等需要中等字重的正文。
        public static let bodyMedium: Font = .body.weight(.medium)
        public static let secondary: Font = .subheadline
        public static let label: Font = .system(.callout, weight: .medium)
        public static let caption: Font = .caption
        public static let technical: Font = .caption2.monospacedDigit()
        public static let metricValue: Font = .system(.title3, weight: .semibold).monospacedDigit()
        public static let metric = metricValue
        public static let statusTitle: Font = .system(.title3, weight: .semibold)
        public static let workspaceTitle: Font = .system(.headline, weight: .semibold)
        public static let toolbarTitle: Font = .system(.headline, weight: .semibold)
        public static let diagnosticsSummary: Font = .system(.title3, weight: .semibold)
        public static let diagnosticsDetail: Font = .system(.callout, weight: .medium)
        public static let statusIcon: Font = .system(size: Control.statusIconSize, weight: .semibold)
        public static let statusGlyph: Font = .system(.title2, weight: .semibold)
        public static let emptyStateGlyph: Font = .system(size: 30, weight: .medium)

        // Source-compatibility aliases for compiled legacy surfaces.
        public static let pageTitle = windowTitle
        public static let panelTitle = sectionTitle
    }

    public enum Color {
        // The system owns the neutral ramp: labels, window floor, panels, slots
        // and separators all resolve through AppKit semantic colors so light,
        // dark, Increase Contrast and reduced transparency behave for free
        // (REDESIGN-SPEC §5.4).
        public static let ink = SwiftUI.Color(nsColor: .labelColor)
        public static let inkSecondary = SwiftUI.Color(nsColor: .secondaryLabelColor)
        public static let inkTertiary = SwiftUI.Color(nsColor: .tertiaryLabelColor)
        /// Content drawn on top of the accent fill.
        public static let onRail = SwiftUI.Color(nsColor: .alternateSelectedControlTextColor)
        /// The window owns its background; this is the system window floor.
        public static let canvas = SwiftUI.Color(nsColor: .windowBackgroundColor)
        /// Content panels and control surfaces.
        public static let field = SwiftUI.Color(nsColor: .controlBackgroundColor)
        /// Input slots sit one level below panels.
        public static let recessedField = SwiftUI.Color(nsColor: .textBackgroundColor)
        public static let separator = SwiftUI.Color(nsColor: .separatorColor)
        public static let focusRing = SwiftUI.Color(nsColor: .keyboardFocusIndicatorColor)
        public static let disabled = SwiftUI.Color(nsColor: .disabledControlTextColor)
        public static let quaternaryFill = SwiftUI.Color(nsColor: .quaternaryLabelColor)
        /// 声轨信号色：提取自 Logo 纵深延伸的双高速导轨（Sonic Rail Cyan 冷青铁轨钢光与道床）
        /// The app accent is the asset catalog color: one source of truth for
        /// selection, focus and primary controls (§5.4).
        public static let rail = SwiftUI.Color.accentColor
        /// 航天冷钛金属色：提取自 Logo 核心 'S' Crest 微雕质感与频谱微光
        public static let titanium = dynamicColor(
            named: "Titanium",
            lightHex: 0x4D5358,
            darkHex: 0x8E9398,
            hcLightHex: 0x24282B,
            hcDarkHex: 0xFAFAFA
        )
        /// 声学母带真空管暖琥珀色：提取自经典模拟音频硬件真空管与暖调声学流
        public static let voice = dynamicColor(
            named: "VoiceAccent",
            lightHex: 0xD97706,
            darkHex: 0xF59E0B,
            hcLightHex: 0xB45309,
            hcDarkHex: 0xFBBF24
        )
        public static let ready = SwiftUI.Color(nsColor: .systemGreen)
        public static let attention = SwiftUI.Color(nsColor: .systemOrange)
        public static let critical = SwiftUI.Color(nsColor: .systemRed)
        public static let info = SwiftUI.Color(nsColor: .systemBlue)
        public static let waveformInactive = Color.inkSecondary.opacity(0.35)
    }

    /// Interactive surfaces. Every member resolves to a system semantic color,
    /// so light, dark, Increase Contrast and reduced transparency come from the
    /// system (REDESIGN-SPEC §5.4). The logo-derived chrome tokens (specular
    /// chamfer, ambient shadow, rail glow) were removed once the pages stopped
    /// drawing their own containers (§5.2).
    public enum Surface {
        public static let selectedFill = Color.rail.opacity(0.16)
        public static let voiceBadgeFill = Color.voice.opacity(0.20)
        public static let inspectorFill = Color.field
        public static let border = Color.separator
        /// Only window-level floating layers cast a shadow (§5.2).
        public static let elevatedShadow = SwiftUI.Color.black.opacity(0.18)
        public static let interactionHover = Color.quaternaryFill.opacity(Interaction.hoverFillOpacity * 6)
        public static let interactionPressed = Color.quaternaryFill.opacity(Interaction.pressedFillOpacity * 6)
    }

    public enum Navigation {
        /// Custom rows and the page editors share one focus ring: the system
        /// focus indicator, so focus never changes color between pages (§9).
        public static let focusRing = Color.focusRing
        /// Selection keeps the single product accent as its source of truth
        /// (§5.4); the bespoke rail-cyan highlights were retired.
        public static let selectedForeground = Color.rail
        public static let unselectedForeground = Color.ink
        public static let secondaryForeground = Color.inkSecondary
    }

    public enum Motion {
        public static let standardDuration: Double = 0.2
        public static let reducedDuration: Double = 0
        public static let hoverDuration: Double = 0.14
        public static let pressDuration: Double = 0.12
        public static let selectionFeedback = Animation.easeOut(duration: 0.14)
        public static let hoverFeedback = Animation.easeOut(duration: hoverDuration)
        public static let pressFeedback = Animation.easeOut(duration: pressDuration)
    }
}

private func dynamicColor(
    named name: String,
    lightHex: UInt32,
    darkHex: UInt32,
    hcLightHex: UInt32,
    hcDarkHex: UInt32
) -> SwiftUI.Color {
    if let _ = NSColor(named: name, bundle: .main) {
        return SwiftUI.Color(name, bundle: .main)
    }
    return SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let isHighContrast = appearance.name == .accessibilityHighContrastAqua
            || appearance.name == .accessibilityHighContrastDarkAqua
        let hex: UInt32 = switch (isDark, isHighContrast) {
        case (false, false): lightHex
        case (true, false):  darkHex
        case (false, true):  hcLightHex
        case (true, true):   hcDarkHex
        }
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    })
}

public enum SpeechRailSurfaceLevel: Sendable {
    case window
    case navigation
    case control
    case inspector
    case panel
    case elevated
}

public extension View {
    func speechRailSurface(_ level: SpeechRailSurfaceLevel = .control) -> some View {
        modifier(SpeechRailSystemSurfaceModifier(level: level))
    }

    func speechRailField() -> some View {
        modifier(SpeechRailSlotModifier())
    }

    func speechRailContentSurface() -> some View {
        modifier(SpeechRailSystemSurfaceModifier(level: .panel))
    }

    func speechRailConsoleChassis() -> some View {
        modifier(SpeechRailSystemSurfaceModifier(level: .panel))
    }

    func speechRailRecessedSlot() -> some View {
        modifier(SpeechRailSlotModifier())
    }

    func speechRailKnurledCapsule(selected: Bool = false) -> some View {
        modifier(SpeechRailChipModifier(selected: selected))
    }
}

// MARK: - System surfaces (v2)

/// Content panel. Concentric corners and a system fill; a surface that neither
/// carries interaction nor expresses hierarchy gets no border and no shadow
/// (REDESIGN-SPEC §5.2).
public struct SpeechRailSystemSurfaceModifier: ViewModifier {
    private let level: SpeechRailSurfaceLevel

    public init(level: SpeechRailSurfaceLevel) {
        self.level = level
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        switch level {
        case .window, .navigation:
            // The window and the system sidebar own their own backgrounds.
            content
        case .control, .panel, .inspector:
            content.background(
                SwiftUI.Color(nsColor: .controlBackgroundColor),
                in: ConcentricRectangle()
            )
        case .elevated:
            // Only window-level floating layers elevate (§5.2).
            content
                .background(.regularMaterial, in: ConcentricRectangle())
                .shadow(
                    color: SpeechRailDesignTokens.Surface.elevatedShadow,
                    radius: SpeechRailDesignTokens.Shadow.elevatedRadius,
                    y: SpeechRailDesignTokens.Shadow.elevatedYOffset
                )
        }
    }
}

/// Input slot: one level below a panel, radius concentric with its container.
public struct SpeechRailSlotModifier: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content.background(
            SwiftUI.Color(nsColor: .textBackgroundColor),
            in: ConcentricRectangle()
        )
    }
}

/// Interactive chip: system capsule geometry, accent only for selection.
public struct SpeechRailChipModifier: ViewModifier {
    public let selected: Bool

    public init(selected: Bool = false) {
        self.selected = selected
    }

    public func body(content: Content) -> some View {
        content
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
            .background(
                selected
                    ? SwiftUI.Color.accentColor.opacity(0.18)
                    : SwiftUI.Color(nsColor: .quaternaryLabelColor).opacity(0.6),
                in: Capsule(style: .continuous)
            )
    }
}
