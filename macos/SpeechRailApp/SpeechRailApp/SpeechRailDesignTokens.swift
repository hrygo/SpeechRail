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
        public static let creatorVoicePickerWidth: CGFloat = 180
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
        public static let hairlineStroke = SwiftUI.Color.primary.opacity(0.07)
        public static let contentStroke = hairlineStroke
        public static let selectedFill = Color.rail.opacity(0.10)
        public static let voiceSelectedFill = Color.voice.opacity(0.12)
        public static let focusRing = Color.rail.opacity(0.40)
        public static let controlFill = Color.field.opacity(0.72)
        public static let inspectorFill = Color.field.opacity(0.92)

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

    public enum Motion {
        public static let standardDuration: Double = 0.2
        public static let reducedDuration: Double = 0
        public static let springTransition = Animation.spring(response: 0.28, dampingFraction: 0.82)
        public static let selectionFeedback = Animation.easeOut(duration: 0.14)
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
        case .window, .navigation:
            content.glassEffect(.regular, in: .rect(cornerRadius: level.cornerRadius, style: .continuous))
        case .control:
            content
                .background(.thinMaterial, in: .rect(cornerRadius: level.cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: level.cornerRadius, style: .continuous)
                        .stroke(SpeechRailDesignTokens.Surface.contentStroke, lineWidth: 0.5)
                }
        case .inspector, .panel, .elevated:
            content
        }
    }
}

public struct SpeechRailFieldModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public func body(content: Content) -> some View {
        content
            .background(
                SpeechRailDesignTokens.Color.field,
                in: .rect(cornerRadius: SpeechRailDesignTokens.Corner.field, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.field, style: .continuous)
                    .stroke(SpeechRailDesignTokens.Surface.hairlineStroke, lineWidth: 0.5)
            }
    }
}

public struct SpeechRailContentSurfaceModifier: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .background(
                SpeechRailDesignTokens.Color.field,
                in: .rect(cornerRadius: SpeechRailDesignTokens.Corner.field, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.field, style: .continuous)
                    .stroke(SpeechRailDesignTokens.Surface.hairlineStroke, lineWidth: 0.5)
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
