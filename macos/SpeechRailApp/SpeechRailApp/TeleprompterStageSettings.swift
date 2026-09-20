import Foundation
import Observation

@MainActor
@Observable
public final class TeleprompterStageSettings {
    private let defaults: UserDefaults

    public var width: Double {
        didSet {
            width = min(
                max(width, Double(SpeechRailDesignTokens.Teleprompter.stageMinimumWidth)),
                Double(SpeechRailDesignTokens.Teleprompter.stageMaximumWidth)
            )
            defaults.set(width, forKey: Key.width)
        }
    }

    public var fontScale: Double {
        didSet {
            fontScale = min(
                max(fontScale, SpeechRailDesignTokens.Teleprompter.stageMinimumFontScale),
                SpeechRailDesignTokens.Teleprompter.stageMaximumFontScale
            )
            defaults.set(fontScale, forKey: Key.fontScale)
        }
    }

    public var opacity: Double {
        didSet {
            opacity = min(
                max(opacity, SpeechRailDesignTokens.Teleprompter.stageMinimumOpacity),
                SpeechRailDesignTokens.Teleprompter.stageMaximumOpacity
            )
            defaults.set(opacity, forKey: Key.opacity)
        }
    }

    public var lineSpacing: Double {
        didSet {
            lineSpacing = min(
                max(lineSpacing, SpeechRailDesignTokens.Teleprompter.stageMinimumLineSpacing),
                SpeechRailDesignTokens.Teleprompter.stageMaximumLineSpacing
            )
            defaults.set(lineSpacing, forKey: Key.lineSpacing)
        }
    }

    public var visibleSegmentCount: Int {
        didSet {
            visibleSegmentCount = min(
                max(visibleSegmentCount, SpeechRailDesignTokens.Teleprompter.stageMinimumVisibleSegmentCount),
                SpeechRailDesignTokens.Teleprompter.stageMaximumVisibleSegmentCount
            )
            defaults.set(visibleSegmentCount, forKey: Key.visibleSegmentCount)
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
        self.width = defaults.object(forKey: Key.width) as? Double
            ?? Double(SpeechRailDesignTokens.Teleprompter.stageDefaultWidth)
        self.fontScale = defaults.object(forKey: Key.fontScale) as? Double ?? 1
        self.opacity = defaults.object(forKey: Key.opacity) as? Double
            ?? SpeechRailDesignTokens.Teleprompter.stageDefaultOpacity
        self.lineSpacing = defaults.object(forKey: Key.lineSpacing) as? Double
            ?? Double(SpeechRailDesignTokens.Teleprompter.stageLineSpacing)
        self.visibleSegmentCount = defaults.object(forKey: Key.visibleSegmentCount) as? Int ?? 3
    }

    private enum Key {
        static let width = "speechrail.teleprompter.stage.width"
        static let fontScale = "speechrail.teleprompter.stage.fontScale"
        static let opacity = "speechrail.teleprompter.stage.opacity"
        static let lineSpacing = "speechrail.teleprompter.stage.lineSpacing"
        static let visibleSegmentCount = "speechrail.teleprompter.stage.visibleSegmentCount"
    }
}
