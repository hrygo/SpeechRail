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
        public static let inspectorWidth: CGFloat = 360
        public static let inspectorMinimumWidth: CGFloat = inspectorWidth
        public static let inspectorIdealWidth: CGFloat = inspectorWidth
        public static let inspectorMaximumWidth: CGFloat = inspectorWidth
        public static let contentMaximumWidth: CGFloat = 1_240
        public static let windowMinimumWidth: CGFloat = 1_120
        public static let windowMinimumHeight: CGFloat = 720
        public static let creatorComposerMinimumHeight: CGFloat = 180
        public static let creatorReferenceMinimumHeight: CGFloat = 72
        public static let creatorVoiceInstructionMinimumHeight: CGFloat = 120
        public static let creatorVoicePickerWidth: CGFloat = 180
        public static let creatorVoiceNameWidth: CGFloat = 220
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
        public static let selectionCornerRadius: CGFloat = Corner.row
        public static let dividerInset: CGFloat = Spacing.lg
        public static let disclosureContentInset: CGFloat = Spacing.lg
    }

    /// Developer-facing metadata is deliberately denser than page content, but
    /// its width and text rules are fixed so an implementation detail can never
    /// resize the main workspace or push the navigation column.
    public enum Inspector {
        public static let width: CGFloat = Layout.inspectorWidth
        public static let contentPadding: CGFloat = Spacing.md
        public static let contentWidth: CGFloat = width - contentPadding * 2
        public static let sectionSpacing: CGFloat = Spacing.md
        public static let rowSpacing: CGFloat = Spacing.sm
        public static let labelValueSpacing: CGFloat = Spacing.micro
        public static let rowVerticalPadding: CGFloat = Spacing.xs
        public static let titleMaximumLines: Int = 1
        public static let valueMaximumLines: Int = 3
        public static let bodyMaximumLines: Int = 4
        public static let actionColumnMinimumWidth: CGFloat = 120
        public static let actionGridSpacing: CGFloat = Spacing.sm
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
        public static let cornerRadius: CGFloat = Corner.control
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
        public static let pressedScale: CGFloat = 0.985
        public static let focusRingInset: CGFloat = 1
        public static let hoverFillOpacity: Double = 0.07
        public static let pressedFillOpacity: Double = 0.12
        public static let disabledOpacity: Double = 0.45
        public static let focusLineWidth: CGFloat = 2
    }

    public enum Typography {
        public static let display: Font = .system(.title, design: .default, weight: .bold)
        public static let windowTitle: Font = .system(.title2, design: .default, weight: .semibold)
        public static let sectionTitle: Font = .system(.headline, design: .default, weight: .semibold)
        public static let section = sectionTitle
        public static let body: Font = .body
        public static let secondary: Font = .subheadline
        public static let label: Font = .system(.callout, design: .default, weight: .medium)
        public static let caption: Font = .caption
        public static let technical: Font = .system(.caption2, design: .monospaced)
        public static let metricValue: Font = .system(.title3, design: .rounded, weight: .semibold).monospacedDigit()
        public static let metric = metricValue
        public static let statusTitle: Font = .system(.title3, design: .default, weight: .semibold)
        public static let workspaceTitle: Font = .system(.headline, design: .default, weight: .semibold)
        public static let toolbarTitle: Font = .system(.headline, design: .default, weight: .semibold)
        public static let diagnosticsSummary: Font = .system(.title3, design: .default, weight: .semibold)
        public static let diagnosticsDetail: Font = .system(.callout, design: .default, weight: .medium)
        public static let statusIcon: Font = .system(size: Control.statusIconSize, weight: .semibold)
        public static let statusGlyph: Font = .system(.title2, design: .default, weight: .semibold)
        public static let emptyStateGlyph: Font = .system(size: 30, weight: .medium)

        // Source-compatibility aliases for compiled legacy surfaces.
        public static let pageTitle = windowTitle
        public static let panelTitle = sectionTitle
    }

    public enum Color {
        public static let ink = dynamicColor(
            named: "Ink",
            lightHex: 0x111822,
            darkHex: 0xF0F4F8,
            hcLightHex: 0x000000,
            hcDarkHex: 0xFFFFFF
        )
        public static let inkSecondary = dynamicColor(
            named: "InkSecondary",
            lightHex: 0x586374,
            darkHex: 0x8C9AA9,
            hcLightHex: 0x222222,
            hcDarkHex: 0xE0E0E0
        )
        public static let inkTertiary = dynamicColor(
            named: "InkTertiary",
            lightHex: 0x77818E,
            darkHex: 0x73808C,
            hcLightHex: 0x333333,
            hcDarkHex: 0xD6D6D6
        )
        public static let onRail = dynamicColor(
            named: "OnRail",
            lightHex: 0xFFFFFF,
            darkHex: 0x07151A,
            hcLightHex: 0xFFFFFF,
            hcDarkHex: 0x07151A
        )
        public static let canvas = dynamicColor(
            named: "Canvas",
            lightHex: 0xE5E8EC,
            darkHex: 0x15171A,
            hcLightHex: 0xFFFFFF,
            hcDarkHex: 0x000000
        )
        public static let field = dynamicColor(
            named: "Field",
            lightHex: 0xEDF0F3,
            darkHex: 0x1D1E21,
            hcLightHex: 0xFFFFFF,
            hcDarkHex: 0x141518
        )
        /// 声轨信号色：提取自 Logo 纵深延伸的双高速导轨（Sonic Rail Cyan 冷青铁轨钢光与道床）
        public static let rail = dynamicColor(
            named: "RailSignal",
            lightHex: 0x2A4E57,
            darkHex: 0x4FA4BA,
            hcLightHex: 0x1B363D,
            hcDarkHex: 0x7FD3E6
        )
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
        public static let ready = dynamicColor(
            named: "SignalReady",
            lightHex: 0x059669,
            darkHex: 0x10B981,
            hcLightHex: 0x047857,
            hcDarkHex: 0x34D399
        )
        public static let attention = dynamicColor(
            named: "SignalAttention",
            lightHex: 0xD97706,
            darkHex: 0xF59E0B,
            hcLightHex: 0xB45309,
            hcDarkHex: 0xFBBF24
        )
        public static let critical = dynamicColor(
            named: "SignalCritical",
            lightHex: 0xDC2626,
            darkHex: 0xEF4444,
            hcLightHex: 0xB91C1C,
            hcDarkHex: 0xF87171
        )
        public static let info = dynamicColor(
            named: "SignalInfo",
            lightHex: 0x2563EB,
            darkHex: 0x38BDF8,
            hcLightHex: 0x1D4ED8,
            hcDarkHex: 0x7DD3FC
        )
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
        public static let recessedWell = dynamicColor(
            named: "RecessedSlot",
            lightHex: 0xDFE2E6,
            darkHex: 0x101113,
            hcLightHex: 0xD0D4DA,
            hcDarkHex: 0x0A0B0C
        )
        public static let recessed = recessedWell
        /// 机架切削边界描边
        public static let milledBevel = dynamicColor(
            named: "ChassisBorder",
            lightHex: 0xCBD0D8,
            darkHex: 0x2E3238,
            hcLightHex: 0x9AA2B0,
            hcDarkHex: 0x464C54
        )
        public static let border = milledBevel
        /// 强化铣削边框（外边缘）
        public static let grooveStroke = dynamicColor(
            named: "ChassisBorderStrong",
            lightHex: 0xB0B8C4,
            darkHex: 0x3A3F46,
            hcLightHex: 0x7E8898,
            hcDarkHex: 0x58606B
        )
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
        public static let selectedFill = TrackRail.railGleam.opacity(0.14)
        public static let selectedFillStrong = TrackRail.railGleam.opacity(0.20)
        public static let voiceSelectedFill = Console.tubeAmber.opacity(0.14)
        public static let voiceBadgeFill = Console.tubeAmber.opacity(0.18)
        public static let focusRing = TrackRail.railGleam.opacity(0.80)
        public static let controlFill = Chassis.machined
        public static let navigationFill = Chassis.obsidian
        public static let panelFill = Chassis.machined
        public static let inspectorFill = Chassis.machined
        public static let fieldHighlight = Steel.specular.opacity(0.35)
        public static let fieldHighlightDark = Steel.specular.opacity(0.08)
        public static let statusChipFillOpacity: Double = 0.16
        public static let surfaceRaised = panelFill
        public static let border = Chassis.border
        public static let borderStrong = Chassis.borderStrong
        public static let divider = Chassis.border
        public static let disabledFill = Chassis.border.opacity(0.2)
        public static let elevatedShadow = SwiftUI.Color.black.opacity(0.22)
        public static let interactionHover = TrackRail.railGleam.opacity(Interaction.hoverFillOpacity)
        public static let interactionPressed = TrackRail.railGleam.opacity(Interaction.pressedFillOpacity)

        // MARK: - Logo 物理微雕与光学反光 Token (Crafted from App Icon)

        /// Logo 顶光高光微倒角（Specular Chamfer Highlight，还原 Logo 2px 微光切削边缘）
        public static let specularChamfer = Steel.specular.opacity(0.16)
        /// Logo 环境闭塞微投影（Ambient Occlusion，赋予控件真实物理沉降感）
        public static let ambientShadow = SwiftUI.Color.black.opacity(0.25)
        /// 精密钛金属卡片边框描边
        public static let cardStroke = Chassis.borderStrong
        /// 声轨冷青微发光
        public static let railGlow = TrackRail.trackGlow
    }

    public enum Navigation {
        public static let selectedFill = Surface.selectedFillStrong
        public static let focusRing = TrackRail.railGleam.opacity(0.72)
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
        public static let springTransition = Animation.spring(response: 0.28, dampingFraction: 0.82)
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
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
            Rectangle()
                .fill(SpeechRailDesignTokens.Chassis.border)
                .frame(height: 1)
            Circle()
                .fill(SpeechRailDesignTokens.TrackRail.railGleam.opacity(0.6))
                .frame(width: 3, height: 3)
            Rectangle()
                .fill(SpeechRailDesignTokens.Chassis.border)
                .frame(height: 1)
        }
    }
}

public extension View {
    func speechRailSurface(_ level: SpeechRailSurfaceLevel = .control) -> some View {
        modifier(SpeechRailSurfaceModifier(level: level))
    }

    func speechRailField() -> some View {
        modifier(SpeechRailFieldModifier())
    }

    func speechRailContentSurface() -> some View {
        modifier(SpeechRailContentSurfaceModifier())
    }

    func speechRailConsoleChassis() -> some View {
        modifier(SpeechRailContentSurfaceModifier())
    }

    func speechRailRecessedSlot() -> some View {
        modifier(SpeechRailFieldModifier())
    }

    func speechRailKnurledCapsule(selected: Bool = false) -> some View {
        modifier(SpeechRailKnurledCapsuleModifier(selected: selected))
    }
}

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
