import AppKit
import SwiftUI

public enum SpeechRailDesignTokens {
    public enum Spacing {
        public static let micro: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let sm: CGFloat = 12
        public static let md: CGFloat = 16
        public static let lg: CGFloat = 24
        public static let xl: CGFloat = 32

        // Source-compatibility aliases for compiled legacy surfaces.
        public static let xxs = micro
        public static let xxl: CGFloat = 40
    }

    public enum Corner {
        public static let control: CGFloat = 6
        public static let row: CGFloat = 8
        public static let surface: CGFloat = 12

        // Source-compatibility aliases for compiled legacy surfaces.
        public static let panel = surface
        public static let window: CGFloat = 16
        public static let pill: CGFloat = 999
    }

    public enum Layout {
        public static let sidebarMinimumWidth: CGFloat = 220
        public static let sidebarIdealWidth: CGFloat = 248
        public static let sidebarMaximumWidth: CGFloat = 288
        public static let inspectorMinimumWidth: CGFloat = 280
        public static let inspectorIdealWidth: CGFloat = 336
        public static let contentMaximumWidth: CGFloat = 1_240
        public static let windowMinimumWidth: CGFloat = 1_120
        public static let windowMinimumHeight: CGFloat = 720
        public static let creatorComposerMinimumHeight: CGFloat = 180
        public static let emptyStateMinimumHeight: CGFloat = 240
    }

    public enum Control {
        public static let minimumHitTarget: CGFloat = 44
        public static let iconSize: CGFloat = 16
        public static let toolbarIconSize: CGFloat = 18
        public static let iconButtonSize: CGFloat = 28

        // Kept for surfaces that still use an explicit control size.
        public static let compactHeight: CGFloat = 28
        public static let regularHeight: CGFloat = 34
        public static let prominentHeight: CGFloat = 40
    }

    public enum Typography {
        public static let windowTitle: Font = .system(.title2, design: .default, weight: .semibold)
        public static let sectionTitle: Font = .headline
        public static let body: Font = .body
        public static let secondary: Font = .subheadline
        public static let caption: Font = .caption
        public static let technical: Font = .system(.caption2, design: .monospaced)

        // Source-compatibility aliases for compiled legacy surfaces.
        public static let pageTitle = windowTitle
        public static let panelTitle = sectionTitle
    }

    public enum Palette {
        public static let canvas: Color = Color(nsColor: .windowBackgroundColor)
        public static let content: Color = Color(nsColor: .underPageBackgroundColor)
        public static let primaryText: Color = .primary
        public static let secondaryText: Color = .secondary
        public static let separator: Color = Color(nsColor: .separatorColor)

        // Rail signal uses the user-selected system accent and remains adaptive.
        public static let railSignal: Color = .accentColor
        // VoiceDesign is the only surface allowed to use this product accent.
        public static let voiceAccent: Color = .purple
        public static let healthy: Color = Color(nsColor: .systemGreen)
        public static let attention: Color = Color(nsColor: .systemOrange)
        public static let critical: Color = Color(nsColor: .systemRed)
        public static let information: Color = Color(nsColor: .systemBlue)

        // Source-compatibility aliases for compiled legacy surfaces.
        public static let groupedCanvas = content
        public static let tint = railSignal
        public static let success = healthy
        public static let warning = attention
    }

    public enum Surface {
        public static let contentStroke = Palette.separator.opacity(0.45)
        public static let selectedFill = Palette.railSignal.opacity(0.12)
        public static let controlFill = Palette.content.opacity(0.72)
        public static let inspectorFill = Palette.content.opacity(0.92)
    }

    public enum Motion {
        public static let standardDuration: Double = 0.2
        public static let reducedDuration: Double = 0
    }
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
            content.glassEffect(.regular, in: .rect(cornerRadius: level.cornerRadius))
        case .control:
            content
                .background(.thinMaterial, in: .rect(cornerRadius: level.cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: level.cornerRadius)
                        .stroke(SpeechRailDesignTokens.Surface.contentStroke, lineWidth: 0.5)
                }
        case .inspector, .panel, .elevated:
            content
        }
    }
}

public struct SpeechRailContentSurfaceModifier: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .background(
                SpeechRailDesignTokens.Surface.controlFill,
                in: .rect(cornerRadius: SpeechRailDesignTokens.Corner.surface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.surface)
                    .stroke(SpeechRailDesignTokens.Surface.contentStroke, lineWidth: 0.5)
            }
    }
}

public extension View {
    func speechRailSurface(_ level: SpeechRailSurfaceLevel = .control) -> some View {
        modifier(SpeechRailSurfaceModifier(level: level))
    }

    func speechRailContentSurface() -> some View {
        modifier(SpeechRailContentSurfaceModifier())
    }
}
