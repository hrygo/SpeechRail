import AppKit
import SwiftUI

public enum SpeechRailDesignTokens {
    public enum Spacing {
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let sm: CGFloat = 12
        public static let md: CGFloat = 16
        public static let lg: CGFloat = 24
        public static let xl: CGFloat = 32
        public static let xxl: CGFloat = 40
    }

    public enum Corner {
        public static let control: CGFloat = 8
        public static let panel: CGFloat = 12
        public static let window: CGFloat = 16
        public static let pill: CGFloat = 999
    }

    public enum Layout {
        public static let sidebarMinimumWidth: CGFloat = 208
        public static let sidebarIdealWidth: CGFloat = 236
        public static let sidebarMaximumWidth: CGFloat = 300
        public static let contentMaximumWidth: CGFloat = 1_200
        public static let windowMinimumWidth: CGFloat = 980
        public static let windowMinimumHeight: CGFloat = 680
        public static let creatorComposerMinimumHeight: CGFloat = 180
        public static let emptyStateMinimumHeight: CGFloat = 240
    }

    public enum Control {
        public static let compactHeight: CGFloat = 28
        public static let regularHeight: CGFloat = 34
        public static let prominentHeight: CGFloat = 40
        public static let iconSize: CGFloat = 16
        public static let iconButtonSize: CGFloat = 28
        public static let minimumHitTarget: CGFloat = 44
    }

    public enum Typography {
        public static let pageTitle: Font = .system(.title, design: .default, weight: .semibold)
        public static let sectionTitle: Font = .system(.title3, design: .default, weight: .semibold)
        public static let panelTitle: Font = .system(.headline, design: .default, weight: .semibold)
        public static let body: Font = .body
        public static let secondary: Font = .callout
        public static let caption: Font = .caption
        public static let technical: Font = .system(.caption2, design: .monospaced)
    }

    public enum Palette {
        public static let canvas: Color = Color(nsColor: .windowBackgroundColor)
        public static let groupedCanvas: Color = Color(nsColor: .underPageBackgroundColor)
        public static let primaryText: Color = .primary
        public static let secondaryText: Color = .secondary
        public static let separator: Color = Color(nsColor: .separatorColor)
        public static let tint: Color = .accentColor
        public static let success: Color = .green
        public static let warning: Color = .orange
        public static let critical: Color = .red
        public static let information: Color = .blue
    }

    public enum Motion {
        public static let standardDuration: Double = 0.2
        public static let reducedDuration: Double = 0
    }
}

public enum SpeechRailSurfaceLevel: Sendable {
    case window
    case navigation
    case panel
    case elevated

    fileprivate var cornerRadius: CGFloat {
        switch self {
        case .window:
            SpeechRailDesignTokens.Corner.window
        case .navigation, .panel:
            SpeechRailDesignTokens.Corner.panel
        case .elevated:
            SpeechRailDesignTokens.Corner.control
        }
    }

    fileprivate var glass: Glass {
        switch self {
        case .window, .navigation:
            .regular
        case .panel:
            .regular.tint(SpeechRailDesignTokens.Palette.tint.opacity(0.08))
        case .elevated:
            .clear
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
        content.glassEffect(level.glass, in: .rect(cornerRadius: level.cornerRadius))
    }
}

public extension View {
    func speechRailSurface(_ level: SpeechRailSurfaceLevel = .panel) -> some View {
        modifier(SpeechRailSurfaceModifier(level: level))
    }
}
