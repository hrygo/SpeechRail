import AppKit
import SwiftUI

public enum SpeechRailDesignTokens {
    public enum Spacing {
        public static let hairline: CGFloat = 1
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
        public static let sidebarMinimumWidth: CGFloat = 200
        public static let sidebarIdealWidth: CGFloat = 240
        public static let sidebarMaximumWidth: CGFloat = 280
        public static let inspectorMinimumWidth: CGFloat = 280
        public static let inspectorIdealWidth: CGFloat = 320
        public static let inspectorMaximumWidth: CGFloat = 400
        public static let contentMaximumWidth: CGFloat = 1_240
        public static let windowMinimumWidth: CGFloat = 1_120
        public static let windowMinimumHeight: CGFloat = 720
        public static let creatorComposerMinimumHeight: CGFloat = 180
        public static let creatorReferenceMinimumHeight: CGFloat = 72
        public static let creatorVoicePickerWidth: CGFloat = 180
        public static let creatorVoiceNameWidth: CGFloat = 220
        public static let creatorVoiceControlWidth: CGFloat = 240
        public static let creatorSpeedSliderWidth: CGFloat = 120
        public static let creatorSpeedValueWidth: CGFloat = 32
        public static let creatorSlotBadgeSize: CGFloat = 32
        public static let creatorWaveformWidth: CGFloat = 72
        public static let creatorWaveformHeight: CGFloat = 20
        public static let creatorListRowMinimumHeight: CGFloat = 72
        public static let emptyStateMinimumHeight: CGFloat = 240
        public static let modelEmptyStateMinimumHeight: CGFloat = 180
        public static let modelArtifactEmptyStateMinimumHeight: CGFloat = 130
        public static let modelFactMinimumWidth: CGFloat = 100
        public static let diagnosticsEmptyListMinimumHeight: CGFloat = 180
        public static let diagnosticsEmptyDetailMinimumHeight: CGFloat = 300
        public static let monitoringEmptyMinimumHeight: CGFloat = 220
        public static let monitoringChartHeight: CGFloat = 240
        public static let compactDividerHeight: CGFloat = 42
        public static let controlMenuMinimumWidth: CGFloat = 280
        public static let settingsWindowMinimumWidth: CGFloat = 560
        public static let settingsWindowMinimumHeight: CGFloat = 360
        public static let diagnosticsSummaryHeight: CGFloat = 84
        public static let diagnosticsListWidth: CGFloat = 320
        public static let diagnosticsDetailMinimumWidth: CGFloat = 460
        public static let diagnosticsRowHeight: CGFloat = 44
        public static let diagnosticsBodyMinimumHeight: CGFloat = 360
        public static let monitoringCapabilityMinimumWidth: CGFloat = 280
        public static let monitoringCapabilityIdealWidth: CGFloat = 320
        public static let monitoringCapabilityRowHeight: CGFloat = 58
        public static let monitoringWorkerRowHeight: CGFloat = 42
        public static let monitoringStatusColumnWidth: CGFloat = 64
        public static let metricMinimumWidth: CGFloat = 112
        public static let metricColumnCount: Int = 4
    }

    public enum Control {
        public static let compactHeight: CGFloat = 28
        public static let regularHeight: CGFloat = 34
        public static let prominentHeight: CGFloat = 40

        public static let minimumHitTarget: CGFloat = 44
        public static let iconSize: CGFloat = 16
        public static let toolbarIconSize: CGFloat = 18
        public static let iconButtonSize: CGFloat = 28
        public static let statusIndicatorDiameter: CGFloat = 7
        public static let statusIconSize: CGFloat = 17
        public static let sidebarRowHeight: CGFloat = 44
        public static let sidebarIconFrame: CGFloat = 20
        public static let sidebarIconSize: CGFloat = 15
        public static let workspaceTitleHeight: CGFloat = 30
        public static let purposeIndicatorWidth: CGFloat = 3
        public static let purposeIndicatorHeight: CGFloat = 14
        public static let waveformBarSpacing: CGFloat = 3
        public static let waveformBarWidth: CGFloat = 3
        public static let waveformBarRadius: CGFloat = 2
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
        public static let itemSpacing: CGFloat = 8
    }

    /// Component-level button dimensions. The visual glyph may be smaller than the
    /// hit target; the hit target is never smaller than the macOS control baseline.
    public enum Button {
        public static let standardHeight: CGFloat = 34
        public static let prominentHeight: CGFloat = 40
        public static let iconHitTarget: CGFloat = 44
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
        public static let workspaceContext: Font = .system(.caption, design: .default, weight: .medium)
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
            lightHex: 0xF6F8F9,
            darkHex: 0x13171A,
            hcLightHex: 0xFFFFFF,
            hcDarkHex: 0x000000
        )
        public static let field = dynamicColor(
            named: "Field",
            lightHex: 0xFFFFFF,
            darkHex: 0x1C2227,
            hcLightHex: 0xFFFFFF,
            hcDarkHex: 0x161B1E
        )
        /// 声轨信号色：提取自 Logo 纵深延伸的双高速导轨（Sonic Rail Cyan 冷青铁轨钢光）
        public static let rail = dynamicColor(
            named: "RailSignal",
            lightHex: 0x23687D,
            darkHex: 0x4FA4BA,
            hcLightHex: 0x144959,
            hcDarkHex: 0x7FD3E6
        )
        /// 航天冷钛金属色：提取自 Logo 核心 'S' Crest 微雕质感与频谱微光
        public static let titanium = dynamicColor(
            named: "Titanium",
            lightHex: 0x4D5358,
            darkHex: 0xCCD1D0,
            hcLightHex: 0x24282B,
            hcDarkHex: 0xFAFAFA
        )
        public static let voice = dynamicColor(
            named: "VoiceAccent",
            lightHex: 0xC26743,
            darkHex: 0xE88F6D,
            hcLightHex: 0x9E4928,
            hcDarkHex: 0xFFAE90
        )
        public static let ready = dynamicColor(
            named: "SignalReady",
            lightHex: 0x26856C,
            darkHex: 0x52BFA1,
            hcLightHex: 0x175C4A,
            hcDarkHex: 0x6FE0C0
        )
        public static let attention = dynamicColor(
            named: "SignalAttention",
            lightHex: 0x9E6E1C,
            darkHex: 0xD9AB43,
            hcLightHex: 0x78510E,
            hcDarkHex: 0xF0C45C
        )
        public static let critical = dynamicColor(
            named: "SignalCritical",
            lightHex: 0xBA3539,
            darkHex: 0xE87074,
            hcLightHex: 0x8E1E22,
            hcDarkHex: 0xFF9296
        )
        public static let info = dynamicColor(
            named: "SignalInfo",
            lightHex: 0x39729E,
            darkHex: 0x6EA9D6,
            hcLightHex: 0x254E6D,
            hcDarkHex: 0x8DC0EA
        )
        public static let waveformInactive = Color.inkSecondary.opacity(0.35)
    }

    public enum Palette {
        public static let canvas = Color.canvas
        public static let content = Color.field
        public static let primaryText: SwiftUI.Color = .primary
        public static let secondaryText: SwiftUI.Color = .secondary
        public static let separator: SwiftUI.Color = SwiftUI.Color(nsColor: .separatorColor)

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
        public static let hairlineStroke = Color.inkSecondary.opacity(0.16)
        public static let contentStroke = hairlineStroke
        public static let selectedFill = Color.rail.opacity(0.14)
        public static let selectedFillStrong = Color.rail.opacity(0.18)
        public static let voiceSelectedFill = Color.voice.opacity(0.12)
        public static let voiceBadgeFill = Color.voice.opacity(0.15)
        public static let focusRing = Color.rail.opacity(0.72)
        public static let controlFill = Color.field.opacity(0.88)
        public static let navigationFill = Color.canvas.opacity(0.98)
        public static let panelFill = Color.field.opacity(0.96)
        public static let inspectorFill = Color.field.opacity(0.98)
        public static let fieldHighlight = SwiftUI.Color.white.opacity(0.34)
        public static let fieldHighlightDark = SwiftUI.Color.white.opacity(0.04)
        public static let statusChipFillOpacity: Double = 0.12
        public static let surfaceRaised = panelFill
        public static let border = Color.inkSecondary.opacity(0.16)
        public static let borderStrong = Color.inkSecondary.opacity(0.28)
        public static let divider = Color.inkSecondary.opacity(0.14)
        public static let disabledFill = Color.inkSecondary.opacity(0.08)
        public static let elevatedShadow = SwiftUI.Color.black.opacity(0.12)
        public static let interactionHover = Color.rail.opacity(Interaction.hoverFillOpacity)
        public static let interactionPressed = Color.rail.opacity(Interaction.pressedFillOpacity)

        // MARK: - Logo 物理微雕与光学反光 Token (Crafted from App Icon)

        /// Logo 顶光高光微倒角（Specular Chamfer Highlight，还原 Logo 2px 微光切削边缘）
        public static let specularChamfer = SwiftUI.Color.white.opacity(0.12)
        /// Logo 环境闭塞微投影（Ambient Occlusion，赋予控件真实物理沉降感）
        public static let ambientShadow = SwiftUI.Color.black.opacity(0.18)
        /// 精密钛金属卡片边框描边
        public static let cardStroke = SwiftUI.Color.primary.opacity(0.08)
        /// 声轨冷青微发光
        public static let railGlow = Color.rail.opacity(0.15)
    }

    public enum Navigation {
        public static let selectedFill = Surface.selectedFillStrong
        public static let focusRing = Color.rail.opacity(0.72)
        public static let selectedForeground = Color.onRail
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
    public init() {}

    public func body(content: Content) -> some View {
        content
            .background(
                SpeechRailDesignTokens.Surface.controlFill,
                in: .rect(cornerRadius: SpeechRailDesignTokens.Corner.field, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.field, style: .continuous)
                    .strokeBorder(
                        SpeechRailDesignTokens.Surface.border,
                        lineWidth: SpeechRailDesignTokens.Stroke.standard
                    )
            }
    }
}

public struct SpeechRailContentSurfaceModifier: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .background(
                SpeechRailDesignTokens.Surface.panelFill,
                in: .rect(cornerRadius: SpeechRailDesignTokens.Corner.field, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.field, style: .continuous)
                    .strokeBorder(
                        SpeechRailDesignTokens.Surface.borderStrong,
                        lineWidth: SpeechRailDesignTokens.Stroke.standard
                    )
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
}
