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

    public enum Corner {
        public static let control: CGFloat = 6
        public static let row: CGFloat = 8
        public static let field: CGFloat = 14
        public static let module: CGFloat = 18
        public static let pill: CGFloat = 999

        /// Apple HIG 连续曲率超椭圆比例（提取自 Logo Master 矢量母版）
        public static let continuousRadiusRatio: CGFloat = 0.2237

        // Source-compatibility aliases for compiled legacy surfaces.
        public static let surface: CGFloat = 12
        public static let panel = surface
        public static let window: CGFloat = 16
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
        public static let creatorSlotBadgeSize: CGFloat = 32
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

    // MARK: - 1. 冶金机架底座 (Chassis & Metallurgy)
    public enum Chassis {
        /// 黑曜岩枪膛底座（Logo 背景最深处哑光吸光质感）
        public static let enclosure = Color.canvas
        public static let obsidian = enclosure
        /// 机加工底板表面（机架面板主表面）
        public static let deck = Color.field
        public static let machined = deck
        /// 沉降凹槽底色（文本框内陷槽位）
        public static let recessedWell = Color.recessedField
        public static let recessed = recessedWell
        /// 机架切削边界描边
        public static let milledBevel = Color.separator
        public static let border = milledBevel
        /// 强化铣削边框（外边缘）
        public static let grooveStroke = Color.separator
        public static let borderStrong = grooveStroke
    }

    // MARK: - 2. 拉丝冷钢与航天冷钛 (SteelAlloy & Specular)
    public enum SteelAlloy {
        /// Logo 顶光 1px 镜面切削反光（最高光）
        public static let specularEdge = dynamicColor(
            named: "SteelSpecular",
            lightHex: 0xFFFFFF,
            darkHex: 0xF0F0EF,
            hcLightHex: 0xFFFFFF,
            hcDarkHex: 0xFFFFFF
        )
        public static let specular = specularEdge
        /// 拉丝冷钛中段银光（S 徽记主反光）
        public static let brushedFace = dynamicColor(
            named: "SteelGleam",
            lightHex: 0xD4D8DC,
            darkHex: 0xC8CDD2,
            hcLightHex: 0xB0B6BE,
            hcDarkHex: 0xE2E5E8
        )
        public static let gleam = brushedFace
        /// 铣削结构厚板
        public static let billetPlate = Color.titanium
        public static let titanium = billetPlate
        /// 滚花机械边缘 / 各向异性暗影切槽
        public static let knurledRim = dynamicColor(
            named: "SteelGroove",
            lightHex: 0x9CA3AF,
            darkHex: 0x202226,
            hcLightHex: 0x6B7280,
            hcDarkHex: 0x141518
        )
        public static let groove = knurledRim
    }
    public typealias Steel = SteelAlloy

    // MARK: - 3. 重轨、道床与声学导轨系统 (SteelRail & Sleepers)
    public enum SteelRail {
        /// 道床冷青钢光（直接取自 Logo 轨道深槽，核心声轨基调）
        public static let trackCyan = dynamicColor(
            named: "PetrolCyan",
            lightHex: 0x2A4E57,
            darkHex: 0x2A4E57,
            hcLightHex: 0x1B363D,
            hcDarkHex: 0x3D6F7B
        )
        public static let petrolCyan = trackCyan
        /// 钢轨表面冷光（光线掠过钢轨顶部的电容青绿）
        public static let railheadGleam = Color.rail
        public static let railGleam = railheadGleam
        /// 轨道脉冲信号色
        public static let signalPulse = dynamicColor(
            named: "SignalPulse",
            lightHex: 0x1E5C6B,
            darkHex: 0x388B9E,
            hcLightHex: 0x133E48,
            hcDarkHex: 0x56B3C8
        )
        /// 轨枕标尺颜色（物理节奏分割刻度）
        public static let sleeperTie = dynamicColor(
            named: "SleeperTie",
            lightHex: 0xB8BEC7,
            darkHex: 0x33373B,
            hcLightHex: 0x9098A3,
            hcDarkHex: 0x484E53
        )
        /// 声轨微光光晕
        public static let trackGlow = Color.rail.opacity(0.18)
        /// 钢轨导航滑块发光珠
        public static let gliderBead = railheadGleam
    }
    public typealias TrackRail = SteelRail

    // MARK: - 4. 实体母带台声学系统 (AcousticMaster & Metering)
    public enum AcousticMaster {
        /// 真空管暖琥珀色（声色创作暖光、重要声学交互）
        public static let tubeWarmth = Color.voice
        public static let tubeAmber = tubeWarmth
        /// 示波器荧光绿（实体 VU 表针、播放状态）
        public static let vuPhosphor = Color.ready
        /// 峰值过载红色
        public static let peakOverload = Color.critical
        /// 声波峰值描边
        public static let waveCrest = Color.rail
        /// 微孔 LED 外圈金属包边
        public static let ledBezel = SteelAlloy.knurledRim
    }
    public typealias Console = AcousticMaster

    // MARK: - 5. 母带控制台推子规格 (ConsoleFader & Detents)
    public enum ConsoleFader {
        public static let trackWidth: CGFloat = 6
        public static let trackHeight: CGFloat = 160
        public static let thumbWidth: CGFloat = 24
        public static let thumbHeight: CGFloat = 36
        public static let detentNotchCount: Int = 4
        public static let calibratedDetent: Double = 1.0
    }

    public enum Palette {
        public static let canvas = Color.canvas
        public static let content = Color.field
        public static let primaryText: SwiftUI.Color = .primary
        public static let secondaryText: SwiftUI.Color = .secondary
        public static let separator: SwiftUI.Color = Chassis.border

        public static let railSignal = Color.rail
        public static let voiceAccent = Color.voice
        public static let titanium = Color.titanium
        public static let healthy = Color.ready
        public static let attention = Color.attention
        public static let critical = Color.critical
        public static let information = Color.info

        // Source-compatibility aliases for compiled legacy surfaces.
        public static let groupedCanvas = content
        public static let tint = railSignal
        public static let success = healthy
        public static let warning = attention
    }

    public enum Surface {
        public static let hairlineStroke = Chassis.border
        public static let contentStroke = Chassis.borderStrong
        public static let selectedFill = Color.rail.opacity(0.16)
        public static let selectedFillStrong = Color.rail.opacity(0.22)
        public static let voiceSelectedFill = Console.tubeAmber.opacity(0.16)
        public static let voiceBadgeFill = Color.voice.opacity(0.20)
        public static let focusRing = Color.focusRing
        public static let controlFill = Color.field
        public static let navigationFill = SwiftUI.Color.clear
        public static let panelFill = Color.field
        public static let inspectorFill = Color.field
        public static let fieldHighlight = SwiftUI.Color.clear
        public static let fieldHighlightDark = SwiftUI.Color.clear
        public static let statusChipFillOpacity: Double = 0.16
        public static let surfaceRaised = panelFill
        public static let border = Color.separator
        public static let borderStrong = Color.separator
        public static let divider = Color.separator
        public static let disabledFill = Color.quaternaryFill.opacity(0.20)
        /// Only window-level floating layers cast a shadow (§5.2).
        public static let elevatedShadow = SwiftUI.Color.black.opacity(0.18)
        public static let interactionHover = Color.quaternaryFill.opacity(Interaction.hoverFillOpacity * 6)
        public static let interactionPressed = Color.quaternaryFill.opacity(Interaction.pressedFillOpacity * 6)

        // MARK: - Logo 物理微雕与光学反光 Token (Crafted from App Icon)

        /// Logo 顶光高光微倒角（Specular Chamfer Highlight，还原 Logo 2px 微光切削边缘）
        public static let specularChamfer = SwiftUI.Color.clear
        /// Static surfaces no longer cast shadows; the window handles elevation.
        public static let ambientShadow = SwiftUI.Color.clear
        /// 精密钛金属卡片边框描边
        public static let cardStroke = Chassis.borderStrong
        /// 声轨冷青微发光
        public static let railGlow = SwiftUI.Color.clear
    }

    public enum Navigation {
        /// Custom rows and the page editors share one focus ring: the system
        /// focus indicator, so focus never changes color between pages (§9).
        public static let focusRing = Color.focusRing
        /// Sonic Rail cyan foreground for the selected icon/accent in custom navigation
        public static let selectedForeground = TrackRail.railGleam
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

    fileprivate var cornerRadius: CGFloat {
        switch self {
        case .window:
            SpeechRailDesignTokens.Corner.window
        case .navigation, .inspector:
            SpeechRailDesignTokens.Corner.surface
        case .control, .panel:
            SpeechRailDesignTokens.Corner.row
        case .elevated:
            SpeechRailDesignTokens.Corner.control
        }
    }
}

@available(*, deprecated, message: "Retired in the v2 redesign: speechRailSurface(_:) renders a system panel surface now.")
public struct SpeechRailSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    private let level: SpeechRailSurfaceLevel

    public init(level: SpeechRailSurfaceLevel) {
        self.level = level
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        switch level {
        case .window:
            content
                .background(SpeechRailDesignTokens.Color.canvas)
        case .navigation:
            content
                .background(SpeechRailDesignTokens.Surface.navigationFill)
        case .control:
            content
                .background(
                    SpeechRailDesignTokens.Surface.controlFill,
                    in: .rect(cornerRadius: level.cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: level.cornerRadius, style: .continuous)
                        .stroke(
                            SpeechRailDesignTokens.Surface.border,
                            lineWidth: SpeechRailDesignTokens.Stroke.standard
                        )
                }
                .overlay(alignment: .top) {
                    if colorScheme == .dark {
                        RoundedRectangle(cornerRadius: level.cornerRadius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    stops: [
                                        .init(color: SpeechRailDesignTokens.Surface.specularChamfer, location: 0.0),
                                        .init(color: SpeechRailDesignTokens.Surface.specularChamfer.opacity(0.15), location: 0.15),
                                        .init(color: .clear, location: 0.35)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: SpeechRailDesignTokens.Stroke.hairline
                            )
                    }
                }
                .shadow(
                    color: SpeechRailDesignTokens.Surface.ambientShadow,
                    radius: 2,
                    x: 0,
                    y: 1
                )
        case .inspector:
            content
                .background(
                    SpeechRailDesignTokens.Surface.inspectorFill,
                    in: .rect(cornerRadius: level.cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: level.cornerRadius, style: .continuous)
                        .stroke(
                            SpeechRailDesignTokens.Surface.border,
                            lineWidth: SpeechRailDesignTokens.Stroke.standard
                        )
                }
        case .panel:
            content
                .background(
                    SpeechRailDesignTokens.Surface.panelFill,
                    in: .rect(cornerRadius: level.cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: level.cornerRadius, style: .continuous)
                        .stroke(
                            SpeechRailDesignTokens.Surface.border,
                            lineWidth: SpeechRailDesignTokens.Stroke.standard
                        )
                }
                .overlay(alignment: .top) {
                    if colorScheme == .dark {
                        RoundedRectangle(cornerRadius: level.cornerRadius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    stops: [
                                        .init(color: SpeechRailDesignTokens.Surface.specularChamfer, location: 0.0),
                                        .init(color: SpeechRailDesignTokens.Surface.specularChamfer.opacity(0.15), location: 0.15),
                                        .init(color: .clear, location: 0.35)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: SpeechRailDesignTokens.Stroke.hairline
                            )
                    }
                }
                .shadow(
                    color: SpeechRailDesignTokens.Surface.ambientShadow,
                    radius: 3,
                    x: 0,
                    y: 1.5
                )
        case .elevated:
            content
                .background(
                    SpeechRailDesignTokens.Surface.surfaceRaised,
                    in: .rect(cornerRadius: level.cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: level.cornerRadius, style: .continuous)
                        .stroke(
                            SpeechRailDesignTokens.Surface.borderStrong,
                            lineWidth: SpeechRailDesignTokens.Stroke.standard
                        )
                }
                .shadow(
                    color: SpeechRailDesignTokens.Surface.elevatedShadow,
                    radius: SpeechRailDesignTokens.Shadow.elevatedRadius,
                    y: SpeechRailDesignTokens.Shadow.elevatedYOffset
                )
        }
    }
}

@available(*, deprecated, message: "Retired in the v2 redesign: speechRailRecessedSlot() renders a system input slot now.")
public struct SpeechRailFieldModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.field, style: .continuous)
                    .fill(SpeechRailDesignTokens.Chassis.recessed)
            }
            .overlay {
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.field, style: .continuous)
                    .strokeBorder(
                        SpeechRailDesignTokens.Chassis.border,
                        lineWidth: SpeechRailDesignTokens.Stroke.hairline
                    )
            }
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.field, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(
                                    color: colorScheme == .dark
                                        ? Color.black.opacity(0.50)
                                        : Color.black.opacity(0.10),
                                    location: 0.0
                                ),
                                .init(color: .clear, location: 0.22)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1.5
                    )
            }
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.field, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.85),
                                .init(
                                    color: colorScheme == .dark
                                        ? SpeechRailDesignTokens.Steel.specular.opacity(0.18)
                                        : SwiftUI.Color.white.opacity(0.65),
                                    location: 1.0
                                )
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
            }
    }
}

@available(*, deprecated, message: "Retired in the v2 redesign: speechRailContentSurface() renders a system panel surface now.")
public struct SpeechRailContentSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.field, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(
                                    color: colorScheme == .dark
                                        ? Color(red: 0x22 / 255.0, green: 0x24 / 255.0, blue: 0x28 / 255.0)
                                        : Color(red: 0xF7 / 255.0, green: 0xF8 / 255.0, blue: 0xFA / 255.0),
                                    location: 0.0
                                ),
                                .init(
                                    color: colorScheme == .dark
                                        ? Color(red: 0x1A / 255.0, green: 0x1B / 255.0, blue: 0x1E / 255.0)
                                        : Color(red: 0xEC / 255.0, green: 0xEF / 255.0, blue: 0xF2 / 255.0),
                                    location: 1.0
                                )
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.field, style: .continuous)
                    .strokeBorder(
                        SpeechRailDesignTokens.Chassis.borderStrong,
                        lineWidth: SpeechRailDesignTokens.Stroke.standard
                    )
            }
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.field, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(
                                    color: colorScheme == .dark
                                        ? SpeechRailDesignTokens.Steel.specular.opacity(0.35)
                                        : SwiftUI.Color.white.opacity(0.95),
                                    location: 0.0
                                ),
                                .init(
                                    color: colorScheme == .dark
                                        ? SpeechRailDesignTokens.Steel.specular.opacity(0.08)
                                        : SwiftUI.Color.white.opacity(0.20),
                                    location: 0.12
                                ),
                                .init(color: .clear, location: 0.30)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: SpeechRailDesignTokens.Stroke.hairline
                    )
            }
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.field, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.70),
                                .init(
                                    color: colorScheme == .dark
                                        ? Color.black.opacity(0.40)
                                        : Color(red: 0x90 / 255.0, green: 0x98 / 255.0, blue: 0xA4 / 255.0).opacity(0.25),
                                    location: 1.0
                                )
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: SpeechRailDesignTokens.Stroke.hairline
                    )
            }
            .shadow(
                color: SpeechRailDesignTokens.Surface.ambientShadow,
                radius: 6,
                x: 0,
                y: 3
            )
    }
}

public struct SpeechRailSleeperDivider: View {
    public init() {}

    public var body: some View {
        Divider()
    }
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

@available(*, deprecated, message: "Retired in the v2 redesign: speechRailKnurledCapsule(selected:) renders a system chip now.")
public struct SpeechRailKnurledCapsuleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    public let selected: Bool

    public init(selected: Bool = false) {
        self.selected = selected
    }

    public func body(content: Content) -> some View {
        content
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
            .background {
                Capsule(style: .continuous)
                    .fill(
                        selected
                            ? SpeechRailDesignTokens.SteelRail.petrolCyan.opacity(0.35)
                            : SpeechRailDesignTokens.Chassis.recessedWell
                    )
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        selected
                            ? SpeechRailDesignTokens.SteelRail.railheadGleam
                            : SpeechRailDesignTokens.Chassis.milledBevel,
                        lineWidth: selected ? 1.0 : 0.5
                    )
            }
            .shadow(
                color: selected
                    ? SpeechRailDesignTokens.SteelRail.trackGlow
                    : Color.clear,
                radius: 3
            )
    }
}
