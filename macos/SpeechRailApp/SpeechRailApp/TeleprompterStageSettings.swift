import Foundation
import Observation

/// The stage is a reading surface, not a miniature editor. Keep the visible
/// window semantic (current segment plus a small look-ahead) instead of
/// exposing the alignment slices used by the follow controller.
public enum TeleprompterStagePaceStatus: String, Codable, Equatable, Sendable {
    case establishing
    case steady
    case brisk
    case slow

    public var title: String {
        switch self {
        case .establishing: "分析节奏中"
        case .steady: "节奏与计划契合"
        case .brisk: "用时超前 (偏快)"
        case .slow: "用时滞后 (偏缓)"
        }
    }

    public var advice: String {
        switch self {
        case .establishing: "正在采样开讲语速以评估时长进度…"
        case .steady: "当前用时与计划高度同步，保持当前语速即可准时完稿"
        case .brisk: "当前进度超前于预定时长，建议多做段落留白与从容展开"
        case .slow: "当前用时超出计划节奏，建议适当加快语速或精简表达"
        }
    }
}

public struct TeleprompterStageSummary: Equatable, Sendable {
    public let completedSegments: Int
    public let totalSegments: Int
    public let elapsedSeconds: TimeInterval
    public let targetSeconds: TimeInterval
    public let totalSpokenUnits: Int
    public let actualWPM: Int
    public let suggestedCalibrationFactor: Double
    public let canCalibrate: Bool
    public let needsCalibration: Bool
    public let paceStatus: TeleprompterStagePaceStatus

    public init(
        completedSegments: Int,
        totalSegments: Int,
        elapsedSeconds: TimeInterval,
        targetSeconds: TimeInterval,
        totalSpokenUnits: Int,
        actualWPM: Int,
        suggestedCalibrationFactor: Double,
        canCalibrate: Bool,
        needsCalibration: Bool,
        paceStatus: TeleprompterStagePaceStatus
    ) {
        self.completedSegments = completedSegments
        self.totalSegments = totalSegments
        self.elapsedSeconds = elapsedSeconds
        self.targetSeconds = targetSeconds
        self.totalSpokenUnits = totalSpokenUnits
        self.actualWPM = actualWPM
        self.suggestedCalibrationFactor = suggestedCalibrationFactor
        self.canCalibrate = canCalibrate
        self.needsCalibration = needsCalibration
        self.paceStatus = paceStatus
    }
}

/// The stage is a reading surface, not a miniature editor. Keep the visible
/// window semantic (current segment plus a small look-ahead) instead of
/// exposing the alignment slices used by the follow controller.
public enum TeleprompterStagePresentation {
    public static func visibleSegmentIndices(
        currentIndex: Int,
        visibleCount: Int,
        totalCount: Int,
        isBrowsingAll: Bool = false
    ) -> [Int] {
        guard totalCount > 0 else { return [] }
        if isBrowsingAll {
            return Array(0..<totalCount)
        }
        let clampedCurrent = min(max(currentIndex, 0), totalCount - 1)
        let count = min(max(visibleCount, 1), totalCount - clampedCurrent)
        return Array(clampedCurrent..<(clampedCurrent + count))
    }

    public static func paceStatus(
        currentIndex: Int,
        totalCount: Int,
        elapsedSeconds: TimeInterval,
        targetSeconds: TimeInterval
    ) -> TeleprompterStagePaceStatus {
        guard totalCount > 0, elapsedSeconds >= 10 else {
            return .establishing
        }
        let progressRatio = Double(currentIndex + 1) / Double(totalCount)
        guard progressRatio > 0.05 else {
            return .establishing
        }
        if targetSeconds > 0 {
            let timeRatio = elapsedSeconds / targetSeconds
            let delta = progressRatio - timeRatio
            if delta > 0.12 {
                return .brisk
            } else if delta < -0.12 {
                return .slow
            } else {
                return .steady
            }
        } else {
            return .steady
        }
    }

    public static func paceDeltaSeconds(
        currentIndex: Int,
        totalCount: Int,
        elapsedSeconds: TimeInterval,
        targetSeconds: TimeInterval
    ) -> TimeInterval? {
        guard totalCount > 0, targetSeconds > 0, elapsedSeconds >= 5 else {
            return nil
        }
        let progressRatio = Double(currentIndex + 1) / Double(totalCount)
        guard progressRatio > 0.02 else { return nil }
        let expectedElapsed = targetSeconds * progressRatio
        return expectedElapsed - elapsedSeconds
    }

    public static func formattedPaceDelta(
        deltaSeconds: TimeInterval
    ) -> (label: String, isAhead: Bool, isBehind: Bool, isSync: Bool) {
        let absSeconds = Int(round(abs(deltaSeconds)))
        if absSeconds <= 3 {
            return ("节拍吻合", false, false, true)
        } else if deltaSeconds > 0 {
            let mins = absSeconds / 60
            let secs = absSeconds % 60
            let timeStr = mins > 0 ? String(format: "+%d:%02d", mins, secs) : String(format: "+%ds", secs)
            return ("超前 \(timeStr)", true, false, false)
        } else {
            let mins = absSeconds / 60
            let secs = absSeconds % 60
            let timeStr = mins > 0 ? String(format: "-%d:%02d", mins, secs) : String(format: "-%ds", secs)
            return ("滞后 \(timeStr)", false, true, false)
        }
    }

    public static func computeSummary(
        segments: [TeleprompterSegment],
        currentSegmentIndex: Int,
        elapsedSeconds: TimeInterval,
        targetSeconds: TimeInterval,
        pace: TeleprompterPace,
        currentCalibrationFactor: Double
    ) -> TeleprompterStageSummary {
        let totalCount = segments.count
        let completed = min(max(currentSegmentIndex + 1, 0), totalCount)
        let spokenText = segments.prefix(completed).map(\.text).joined(separator: "")
        let metrics = TeleprompterTimingPolicy.countMetrics(in: spokenText)
        let totalUnits = metrics.totalUnits
        let minutes = max(0.1, elapsedSeconds / 60.0)
        let actualWPM = elapsedSeconds > 5 ? Int(round(Double(totalUnits) / minutes)) : 0

        let baseEst = TeleprompterTimingPolicy.estimateDuration(
            metrics: metrics,
            pace: pace,
            calibrationFactor: 1.0
        ).pointSeconds ?? max(1, Double(totalUnits) / (pace.cjkUnitsPerMinute / 60.0))

        let rawK = elapsedSeconds / max(1, baseEst)
        let clampedK = min(
            max(rawK, TeleprompterTimingPolicy.minimumCalibrationFactor),
            TeleprompterTimingPolicy.maximumCalibrationFactor
        )
        let canCalibrate = elapsedSeconds >= 30 && totalUnits >= 50
            && (TeleprompterTimingPolicy.minimumCalibrationFactor...TeleprompterTimingPolicy.maximumCalibrationFactor).contains(rawK)
        let needsCalibration = canCalibrate && abs(clampedK - currentCalibrationFactor) > 0.02

        let status = paceStatus(
            currentIndex: currentSegmentIndex,
            totalCount: totalCount,
            elapsedSeconds: elapsedSeconds,
            targetSeconds: targetSeconds
        )

        return TeleprompterStageSummary(
            completedSegments: completed,
            totalSegments: totalCount,
            elapsedSeconds: elapsedSeconds,
            targetSeconds: targetSeconds,
            totalSpokenUnits: totalUnits,
            actualWPM: actualWPM,
            suggestedCalibrationFactor: clampedK,
            canCalibrate: canCalibrate,
            needsCalibration: needsCalibration,
            paceStatus: status
        )
    }
}

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

    public func increaseFontScale() {
        fontScale += SpeechRailDesignTokens.Teleprompter.stageQuickFontScaleStep
    }

    public func decreaseFontScale() {
        fontScale -= SpeechRailDesignTokens.Teleprompter.stageQuickFontScaleStep
    }

    public func resetFontScale() {
        fontScale = 1.0
    }

    public func increaseOpacity() {
        opacity += SpeechRailDesignTokens.Teleprompter.stageQuickOpacityStep
    }

    public func decreaseOpacity() {
        opacity -= SpeechRailDesignTokens.Teleprompter.stageQuickOpacityStep
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

    /// User-facing direction: a higher value means more see-through background.
    /// The persisted/rendered value remains opacity so existing settings stay intact.
    public var backgroundTransparency: Double {
        get { 1 - opacity }
        set { opacity = 1 - newValue }
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

enum TeleprompterStageTransparencyPresentation {
    static func valueLabel(for transparency: Double) -> String {
        String(format: "%.2f%%", locale: Locale(identifier: "en_US_POSIX"), transparency * 100)
    }
}
