import AppKit
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

/// One visual row rendered by the stage, mapped back to its source segment.
/// The UTF-16 range includes hard line-break characters; `text` omits trailing
/// line-break characters so each SwiftUI row remains exactly one line.
public struct TeleprompterStageDisplayLine: Equatable, Identifiable, Sendable {
    public let segmentID: String
    public let segmentIndex: Int
    public let utf16Start: Int
    public let utf16End: Int
    public let text: String

    public var id: String { "\(segmentID)-\(utf16Start)" }

    public var position: TeleprompterAligner.Position {
        TeleprompterAligner.Position(segmentIndex: segmentIndex, utf16Offset: utf16Start)
    }

    fileprivate init(
        segmentID: String,
        segmentIndex: Int,
        utf16Start: Int,
        utf16End: Int,
        text: String
    ) {
        self.segmentID = segmentID
        self.segmentIndex = segmentIndex
        self.utf16Start = utf16Start
        self.utf16End = utf16End
        self.text = text
    }
}

/// Uses AppKit's text layout to split each source segment into visual rows.
/// Keep this result cached by the view until the source, font or width changes.
@MainActor
public enum TeleprompterStageLineLayout {
    public static func layout(
        segments: [TeleprompterSegment],
        pointSize: CGFloat,
        availableWidth: CGFloat
    ) -> [TeleprompterStageDisplayLine] {
        let safeWidth = availableWidth.isFinite ? max(1, availableWidth) : 1
        let safePointSize = pointSize.isFinite ? max(1, pointSize) : 1
        let font = NSFont.systemFont(ofSize: safePointSize)

        return segments.enumerated().flatMap { segmentIndex, segment in
            layout(
                segment: segment,
                segmentIndex: segmentIndex,
                font: font,
                width: safeWidth
            )
        }
    }

    private static func layout(
        segment: TeleprompterSegment,
        segmentIndex: Int,
        font: NSFont,
        width: CGFloat
    ) -> [TeleprompterStageDisplayLine] {
        let source = segment.text
        let sourceNSString = source as NSString
        let sourceLength = sourceNSString.length
        guard sourceLength > 0 else { return [] }

        let attributedText = NSAttributedString(
            string: source,
            attributes: [.font: font]
        )
        let storage = NSTextStorage(attributedString: attributedText)
        let layoutManager = NSLayoutManager()
        layoutManager.usesFontLeading = true
        let container = NSTextContainer(
            size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)

        var rows: [TeleprompterStageDisplayLine] = []
        var glyphIndex = 0
        var nextUTF16Start = 0

        while glyphIndex < layoutManager.numberOfGlyphs {
            var glyphRange = NSRange(location: 0, length: 0)
            _ = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &glyphRange
            )
            guard glyphRange.length > 0 else { break }

            var actualGlyphRange = NSRange(location: 0, length: 0)
            let characterRange = layoutManager.characterRange(
                forGlyphRange: glyphRange,
                actualGlyphRange: &actualGlyphRange
            )
            let rowEnd = min(sourceLength, NSMaxRange(characterRange))
            let rowStart = min(max(nextUTF16Start, characterRange.location), rowEnd)

            if rowEnd > rowStart {
                let sourceRange = NSRange(location: rowStart, length: rowEnd - rowStart)
                let displayRange = displayRange(for: sourceRange, in: sourceNSString)
                let displayText = sourceNSString.substring(with: displayRange)
                rows.append(
                    TeleprompterStageDisplayLine(
                        segmentID: segment.id,
                        segmentIndex: segmentIndex,
                        utf16Start: rowStart,
                        utf16End: rowEnd,
                        text: displayText
                    )
                )
                nextUTF16Start = rowEnd
            }

            glyphIndex = NSMaxRange(glyphRange)
        }

        // TextKit may omit a trailing empty line fragment after a terminal
        // line break, but the source break still belongs to the final row.
        if nextUTF16Start < sourceLength {
            let sourceRange = NSRange(
                location: nextUTF16Start,
                length: sourceLength - nextUTF16Start
            )
            let displayRange = displayRange(for: sourceRange, in: sourceNSString)
            rows.append(
                TeleprompterStageDisplayLine(
                    segmentID: segment.id,
                    segmentIndex: segmentIndex,
                    utf16Start: nextUTF16Start,
                    utf16End: sourceLength,
                    text: sourceNSString.substring(with: displayRange)
                )
            )
        }

        return rows
    }

    private static func displayRange(for sourceRange: NSRange, in source: NSString) -> NSRange {
        var displayEnd = NSMaxRange(sourceRange)
        while displayEnd > sourceRange.location {
            let codeUnit = source.character(at: displayEnd - 1)
            guard codeUnit == 0x000A || codeUnit == 0x000D || codeUnit == 0x2028 || codeUnit == 0x2029 else {
                break
            }
            displayEnd -= 1
        }
        return NSRange(location: sourceRange.location, length: displayEnd - sourceRange.location)
    }
}

/// Stable position and line-slot rules for the stage reading surface.
public enum TeleprompterStagePresentation {
    /// Returns stable context slots around the current visual line. Missing
    /// neighbors remain empty so three-line mode keeps the current row centered.
    public static func visibleLineSlots(
        currentIndex: Int,
        visibleCount: Int,
        totalCount: Int
    ) -> [Int?] {
        guard totalCount > 0 else { return [] }

        let current = min(max(currentIndex, 0), totalCount - 1)
        let count = min(
            max(visibleCount, SpeechRailDesignTokens.Teleprompter.stageMinimumVisibleLineCount),
            SpeechRailDesignTokens.Teleprompter.stageMaximumVisibleLineCount
        )
        switch count {
        case 1:
            return [current]
        case 2:
            return [current, current + 1 < totalCount ? current + 1 : nil]
        default:
            return [
                current > 0 ? current - 1 : nil,
                current,
                current + 1 < totalCount ? current + 1 : nil,
            ]
        }
    }

    public static func displayLineIndex(
        for position: TeleprompterAligner.Position,
        lines: [TeleprompterStageDisplayLine]
    ) -> Int? {
        let segmentLines = lines.indices.filter { lines[$0].segmentIndex == position.segmentIndex }
        guard let firstIndex = segmentLines.first, let lastIndex = segmentLines.last else {
            return nil
        }

        if let exactStart = segmentLines.first(where: { lines[$0].utf16Start == position.utf16Offset }) {
            return exactStart
        }
        if let containing = segmentLines.first(where: {
            lines[$0].utf16Start <= position.utf16Offset && position.utf16Offset < lines[$0].utf16End
        }) {
            return containing
        }
        if position.utf16Offset >= lines[lastIndex].utf16End {
            return lastIndex
        }
        if position.utf16Offset < lines[firstIndex].utf16Start {
            return firstIndex
        }
        return nil
    }

    public static func positionByMovingLine(
        by delta: Int,
        from position: TeleprompterAligner.Position,
        lines: [TeleprompterStageDisplayLine]
    ) -> TeleprompterAligner.Position? {
        guard delta != 0,
              let currentIndex = displayLineIndex(for: position, lines: lines)
        else {
            return nil
        }

        let lastIndex = lines.count - 1
        let boundedDelta = min(max(delta, -currentIndex), lastIndex - currentIndex)
        guard boundedDelta != 0 else { return nil }
        return lines[currentIndex + boundedDelta].position
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
    private var visibleLineCountStorage: Int
    public var alwaysShowControls: Bool {
        didSet { defaults.set(alwaysShowControls, forKey: Key.alwaysShowControls) }
    }

    public var showClockAndProgress: Bool {
        didSet { defaults.set(showClockAndProgress, forKey: Key.showClockAndProgress) }
    }

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

    public var visibleLineCount: Int {
        get { visibleLineCountStorage }
        set {
            let clamped = min(
                max(newValue, SpeechRailDesignTokens.Teleprompter.stageMinimumVisibleLineCount),
                SpeechRailDesignTokens.Teleprompter.stageMaximumVisibleLineCount
            )
            if visibleLineCountStorage != clamped {
                visibleLineCountStorage = clamped
            }
            defaults.set(clamped, forKey: Key.visibleLineCount)
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
        self.visibleLineCountStorage = min(
            max(
                defaults.object(forKey: Key.visibleLineCount) as? Int
                    ?? SpeechRailDesignTokens.Teleprompter.stageDefaultVisibleLineCount,
                SpeechRailDesignTokens.Teleprompter.stageMinimumVisibleLineCount
            ),
            SpeechRailDesignTokens.Teleprompter.stageMaximumVisibleLineCount
        )
        self.alwaysShowControls = defaults.bool(forKey: Key.alwaysShowControls)
        self.showClockAndProgress = defaults.bool(forKey: Key.showClockAndProgress)
    }

    private enum Key {
        static let width = "speechrail.teleprompter.stage.width"
        static let fontScale = "speechrail.teleprompter.stage.fontScale"
        static let opacity = "speechrail.teleprompter.stage.opacity"
        static let lineSpacing = "speechrail.teleprompter.stage.lineSpacing"
        // Retain the existing key so users keep their selected 1/2/3 count.
        static let visibleLineCount = "speechrail.teleprompter.stage.visibleSegmentCount"
        static let alwaysShowControls = "speechrail.teleprompter.stage.alwaysShowControls"
        static let showClockAndProgress = "speechrail.teleprompter.stage.showClockAndProgress"
    }
}

enum TeleprompterStageTransparencyPresentation {
    static func valueLabel(for transparency: Double) -> String {
        "\(Int((transparency * 100).rounded()))%"
    }
}

enum TeleprompterStageGeometryPolicy {
    static func preferredContentHeight(
        visibleLineCount: Int,
        scriptPointSize: CGFloat,
        lineSpacing: CGFloat,
        showsAuxiliaryStatus: Bool
    ) -> CGFloat {
        let tokens = SpeechRailDesignTokens.Teleprompter.self
        let count = min(
            max(visibleLineCount, tokens.stageMinimumVisibleLineCount),
            tokens.stageMaximumVisibleLineCount
        )
        let rowHeight = scriptPointSize + 2 * SpeechRailDesignTokens.Spacing.xs
        let rowSpacing = CGFloat(max(0, count - 1)) * max(
            tokens.stageSegmentSpacing,
            lineSpacing
        )
        let auxiliaryHeight = showsAuxiliaryStatus ? tokens.stageAuxiliaryBarHeight + tokens.stageSegmentSpacing : 0
        let requested = 2 * tokens.stagePadding
            + CGFloat(count) * rowHeight
            + rowSpacing
            + auxiliaryHeight
            + tokens.stageControlAreaHeight
        return min(max(requested, tokens.stageMinimumHeight), tokens.stageMaximumHeight)
    }

    static func standardFrame(defaultFrame: CGRect, visibleFrame: CGRect) -> CGRect {
        let maximumHeight = min(
            SpeechRailDesignTokens.Teleprompter.stageMaximumHeight,
            visibleFrame.height
        )
        let minimumHeight = min(
            SpeechRailDesignTokens.Teleprompter.stageMinimumHeight,
            maximumHeight
        )
        let height = min(max(defaultFrame.height, minimumHeight), maximumHeight)
        return CGRect(
            x: visibleFrame.minX,
            y: visibleFrame.maxY - height,
            width: visibleFrame.width,
            height: height
        )
    }

    static func cappedWindowFrameHeight(
        _ requestedHeight: CGFloat,
        visibleFrameHeight: CGFloat
    ) -> CGFloat {
        max(
            0,
            min(
                requestedHeight,
                min(SpeechRailDesignTokens.Teleprompter.stageMaximumHeight, visibleFrameHeight)
            )
        )
    }
}
