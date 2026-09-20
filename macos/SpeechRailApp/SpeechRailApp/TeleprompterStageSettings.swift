import Foundation
import Observation

@MainActor
@Observable
public final class TeleprompterStageSettings {
    private let defaults: UserDefaults
    private var widthStorage: Double
    private var fontScaleStorage: Double
    private var opacityStorage: Double
    private var lineSpacingStorage: Double
    private var visibleSegmentCountStorage: Int

    public var width: Double {
        get { widthStorage }
        set {
            let clamped = min(
                max(newValue, Double(SpeechRailDesignTokens.Teleprompter.stageMinimumWidth)),
                Double(SpeechRailDesignTokens.Teleprompter.stageMaximumWidth)
            )
            if widthStorage != clamped {
                widthStorage = clamped
            }
            defaults.set(clamped, forKey: Key.width)
        }
    }

    public var fontScale: Double {
        get { fontScaleStorage }
        set {
            let clamped = min(
                max(newValue, SpeechRailDesignTokens.Teleprompter.stageMinimumFontScale),
                SpeechRailDesignTokens.Teleprompter.stageMaximumFontScale
            )
            if fontScaleStorage != clamped {
                fontScaleStorage = clamped
            }
            defaults.set(clamped, forKey: Key.fontScale)
        }
    }

    public var opacity: Double {
        get { opacityStorage }
        set {
            let clamped = min(
                max(newValue, SpeechRailDesignTokens.Teleprompter.stageMinimumOpacity),
                SpeechRailDesignTokens.Teleprompter.stageMaximumOpacity
            )
            if opacityStorage != clamped {
                opacityStorage = clamped
            }
            defaults.set(clamped, forKey: Key.opacity)
        }
    }

    public var lineSpacing: Double {
        get { lineSpacingStorage }
        set {
            let clamped = min(
                max(newValue, SpeechRailDesignTokens.Teleprompter.stageMinimumLineSpacing),
                SpeechRailDesignTokens.Teleprompter.stageMaximumLineSpacing
            )
            if lineSpacingStorage != clamped {
                lineSpacingStorage = clamped
            }
            defaults.set(clamped, forKey: Key.lineSpacing)
        }
    }

    public var visibleSegmentCount: Int {
        get { visibleSegmentCountStorage }
        set {
            let clamped = min(
                max(newValue, SpeechRailDesignTokens.Teleprompter.stageMinimumVisibleSegmentCount),
                SpeechRailDesignTokens.Teleprompter.stageMaximumVisibleSegmentCount
            )
            if visibleSegmentCountStorage != clamped {
                visibleSegmentCountStorage = clamped
            }
            defaults.set(clamped, forKey: Key.visibleSegmentCount)
        }
    }

    public var scriptPointSize: CGFloat {
        let value = SpeechRailDesignTokens.Teleprompter.stageScriptPointSize * fontScale
        return min(
            max(value, SpeechRailDesignTokens.Teleprompter.stageScriptMinimumPointSize),
            SpeechRailDesignTokens.Teleprompter.stageScriptMaximumPointSize
        )
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.widthStorage = min(
            max(
                defaults.object(forKey: Key.width) as? Double
                    ?? Double(SpeechRailDesignTokens.Teleprompter.stageDefaultWidth),
                Double(SpeechRailDesignTokens.Teleprompter.stageMinimumWidth)
            ),
            Double(SpeechRailDesignTokens.Teleprompter.stageMaximumWidth)
        )
        self.fontScaleStorage = min(
            max(
                defaults.object(forKey: Key.fontScale) as? Double ?? 1,
                SpeechRailDesignTokens.Teleprompter.stageMinimumFontScale
            ),
            SpeechRailDesignTokens.Teleprompter.stageMaximumFontScale
        )
        self.opacityStorage = min(
            max(
                defaults.object(forKey: Key.opacity) as? Double
                    ?? SpeechRailDesignTokens.Teleprompter.stageDefaultOpacity,
                SpeechRailDesignTokens.Teleprompter.stageMinimumOpacity
            ),
            SpeechRailDesignTokens.Teleprompter.stageMaximumOpacity
        )
        self.lineSpacingStorage = min(
            max(
                defaults.object(forKey: Key.lineSpacing) as? Double
                    ?? Double(SpeechRailDesignTokens.Teleprompter.stageLineSpacing),
                SpeechRailDesignTokens.Teleprompter.stageMinimumLineSpacing
            ),
            SpeechRailDesignTokens.Teleprompter.stageMaximumLineSpacing
        )
        self.visibleSegmentCountStorage = min(
            max(
                defaults.object(forKey: Key.visibleSegmentCount) as? Int ?? 3,
                SpeechRailDesignTokens.Teleprompter.stageMinimumVisibleSegmentCount
            ),
            SpeechRailDesignTokens.Teleprompter.stageMaximumVisibleSegmentCount
        )
    }

    private enum Key {
        static let width = "speechrail.teleprompter.stage.width"
        static let fontScale = "speechrail.teleprompter.stage.fontScale"
        static let opacity = "speechrail.teleprompter.stage.opacity"
        static let lineSpacing = "speechrail.teleprompter.stage.lineSpacing"
        static let visibleSegmentCount = "speechrail.teleprompter.stage.visibleSegmentCount"
    }
}
