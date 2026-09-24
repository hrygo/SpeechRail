import Foundation
import Testing

#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

@MainActor
struct TeleprompterStageSettingsTests {
    @Test("visible line count changes without recursive setter")
    func visibleLineCountChangeDoesNotRecurse() throws {
        let suiteName = "SpeechRail.TeleprompterStageSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = TeleprompterStageSettings(defaults: defaults)
        #expect(settings.visibleLineCount == 3)
        settings.visibleLineCount = 3

        #expect(settings.visibleLineCount == 3)
        #expect(defaults.integer(forKey: "speechrail.teleprompter.stage.visibleSegmentCount") == 3)

        defaults.removeObject(forKey: "speechrail.teleprompter.stage.visibleSegmentCount")
        settings.visibleLineCount = 3
        #expect(defaults.integer(forKey: "speechrail.teleprompter.stage.visibleSegmentCount") == 3)
    }

    @Test("stage settings clamp and persist their supported ranges")
    func stageSettingsClampAndPersist() throws {
        let suiteName = "SpeechRail.TeleprompterStageSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = TeleprompterStageSettings(defaults: defaults)

        settings.width = 1
        #expect(settings.width == Double(SpeechRailDesignTokens.Teleprompter.stageMinimumWidth))
        settings.width = 10_000
        #expect(settings.width == Double(SpeechRailDesignTokens.Teleprompter.stageMaximumWidth))

        settings.fontScale = 0
        #expect(settings.fontScale == SpeechRailDesignTokens.Teleprompter.stageMinimumFontScale)
        settings.fontScale = 10
        #expect(settings.fontScale == SpeechRailDesignTokens.Teleprompter.stageMaximumFontScale)

        settings.opacity = 0
        #expect(settings.opacity == SpeechRailDesignTokens.Teleprompter.stageMinimumOpacity)
        settings.opacity = 10
        #expect(settings.opacity == SpeechRailDesignTokens.Teleprompter.stageMaximumOpacity)

        settings.lineSpacing = -1
        #expect(settings.lineSpacing == SpeechRailDesignTokens.Teleprompter.stageMinimumLineSpacing)
        settings.lineSpacing = 100
        #expect(settings.lineSpacing == SpeechRailDesignTokens.Teleprompter.stageMaximumLineSpacing)

        settings.visibleLineCount = 1
        #expect(settings.visibleLineCount == SpeechRailDesignTokens.Teleprompter.stageMinimumVisibleLineCount)
        settings.visibleLineCount = 4
        #expect(settings.visibleLineCount == 3)
        #expect(defaults.integer(forKey: "speechrail.teleprompter.stage.visibleSegmentCount") == 3)
    }

    @Test("stage visibility preferences default off and persist independently")
    func stageVisibilityPreferencesPersist() throws {
        let suiteName = "SpeechRail.TeleprompterStageSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = TeleprompterStageSettings(defaults: defaults)
        #expect(!settings.alwaysShowControls)
        #expect(!settings.showClockAndProgress)

        settings.alwaysShowControls = true
        settings.showClockAndProgress = true
        #expect(defaults.bool(forKey: "speechrail.teleprompter.stage.alwaysShowControls"))
        #expect(defaults.bool(forKey: "speechrail.teleprompter.stage.showClockAndProgress"))

        let reloaded = TeleprompterStageSettings(defaults: defaults)
        #expect(reloaded.alwaysShowControls)
        #expect(reloaded.showClockAndProgress)
    }

    @Test("background transparency increases as the stage becomes more see-through")
    func backgroundTransparencyUsesUserFacingDirection() throws {
        let suiteName = "SpeechRail.TeleprompterStageSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = TeleprompterStageSettings(defaults: defaults)
        settings.backgroundTransparency = 0.40

        #expect(abs(settings.opacity - 0.60) < 0.001)
        #expect(abs(settings.backgroundTransparency - 0.40) < 0.001)
        #expect(abs(defaults.double(forKey: "speechrail.teleprompter.stage.opacity") - 0.60) < 0.001)

        settings.backgroundTransparency = 1
        #expect(settings.opacity == 0)
        #expect(settings.backgroundTransparency == 1)
        #expect(defaults.double(forKey: "speechrail.teleprompter.stage.opacity") == 0)
        #expect(TeleprompterStageSettings(defaults: defaults).backgroundTransparency == 1)
    }

    @Test("stage appearance values preserve fractional slider movement")
    func stageAppearanceSettingsAcceptFractionalValues() throws {
        let suiteName = "SpeechRail.TeleprompterStageSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = TeleprompterStageSettings(defaults: defaults)
        settings.fontScale = 1.013
        settings.backgroundTransparency = 0.2837

        #expect(abs(settings.fontScale - 1.013) < 0.0001)
        #expect(abs(settings.backgroundTransparency - 0.2837) < 0.0001)
    }

    @Test("workbench title field uses the shared regular single-line geometry")
    func workbenchTitleGeometryIsReadable() {
        #expect(SpeechRailDesignTokens.Teleprompter.workbenchDocumentTitleMinimumWidth >= 200)
        #expect(SpeechRailSingleLineInputSize.regular.height == SpeechRailDesignTokens.Control.regularHeight)
        #expect(SpeechRailSingleLineInputSize.regular.horizontalInset == SpeechRailDesignTokens.Spacing.sm)
        #expect(SpeechRailSingleLineInputSize.compact.height == SpeechRailDesignTokens.Control.compactHeight)
    }

    @Test("transparency readout distinguishes nearby continuous values")
    func transparencyReadoutShowsFineMovement() {
        #expect(TeleprompterStageTransparencyPresentation.valueLabel(for: 0.283) == "28%")
        #expect(TeleprompterStageTransparencyPresentation.valueLabel(for: 0.284) == "28%")
        #expect(TeleprompterStageTransparencyPresentation.valueLabel(for: 1) == "100%")
    }

    @Test("source editor keeps a bounded preparation-page height")
    func sourceEditorHeightRangeIsOrdered() {
        #expect(SpeechRailDesignTokens.Teleprompter.sourceEditorMinimumHeight <= SpeechRailDesignTokens.Teleprompter.sourceEditorIdealHeight)
        #expect(SpeechRailDesignTokens.Teleprompter.sourceEditorIdealHeight <= SpeechRailDesignTokens.Teleprompter.sourceEditorMaximumHeight)
    }

    @Test("stage preview shows one, two, or three actual display lines")
    func stagePreviewUsesRequestedDisplayLineWindow() {
        let centered: [Int?] = [3, 4, 5]
        let atStart: [Int?] = [nil, 0, 1]
        let atEnd: [Int?] = [8, 9, nil]

        #expect(TeleprompterStagePresentation.visibleLineSlots(currentIndex: 4, visibleCount: 1, totalCount: 10) == [4])
        #expect(TeleprompterStagePresentation.visibleLineSlots(currentIndex: 4, visibleCount: 2, totalCount: 10) == [4, 5])
        #expect(TeleprompterStagePresentation.visibleLineSlots(currentIndex: 4, visibleCount: 3, totalCount: 10) == centered)
        #expect(TeleprompterStagePresentation.visibleLineSlots(currentIndex: 0, visibleCount: 3, totalCount: 10) == atStart)
        #expect(TeleprompterStagePresentation.visibleLineSlots(currentIndex: 9, visibleCount: 3, totalCount: 10) == atEnd)
        #expect(TeleprompterStagePresentation.visibleLineSlots(currentIndex: -1, visibleCount: 2, totalCount: 3) == [0, 1])
        #expect(TeleprompterStagePresentation.visibleLineSlots(currentIndex: 0, visibleCount: 3, totalCount: 0).isEmpty)
    }

    @Test("display-line layout wraps at the requested width and preserves UTF-16 source ranges")
    func displayLineLayoutWrapsWithoutLosingUnicodeText() throws {
        let source = "开场😀欢迎来到SpeechRail提词器，今天介绍快捷翻行。"
        let segment = TeleprompterSegment(
            id: "display-line-source",
            ordinal: 0,
            sourceRange: TeleprompterSourceRange(start: 0, end: source.utf16.count),
            text: source
        )
        let lines = TeleprompterStageLineLayout.layout(
            segments: [segment],
            pointSize: 20,
            availableWidth: 82
        )

        #expect(lines.count > 1)
        #expect(lines.first?.utf16Start == 0)
        #expect(lines.last?.utf16End == source.utf16.count)
        #expect(lines.map(\.text).joined() == source)
        for (index, line) in lines.enumerated() {
            #expect(line.segmentIndex == 0)
            #expect(line.id == "display-line-source-\(line.utf16Start)")
            #expect(line.utf16End - line.utf16Start == line.text.utf16.count)
            #expect(Range(NSRange(location: line.utf16Start, length: line.text.utf16.count), in: source) != nil)
            if index > 0 {
                #expect(lines[index - 1].utf16End == line.utf16Start)
            }
        }
    }

    @Test("display-line ranges preserve hard breaks and segment boundaries")
    func displayLineRangesCoverHardBreaksAndSegments() throws {
        let firstText = "甲😀乙\n丙丁"
        let secondText = "下一段"
        let segments = [
            TeleprompterSegment(
                id: "first",
                ordinal: 0,
                sourceRange: TeleprompterSourceRange(start: 0, end: firstText.utf16.count),
                text: firstText
            ),
            TeleprompterSegment(
                id: "second",
                ordinal: 1,
                sourceRange: TeleprompterSourceRange(start: 0, end: secondText.utf16.count),
                text: secondText
            ),
        ]

        let lines = TeleprompterStageLineLayout.layout(
            segments: segments,
            pointSize: 18,
            availableWidth: 400
        )
        let firstLines = lines.filter { $0.segmentIndex == 0 }
        let secondLines = lines.filter { $0.segmentIndex == 1 }

        #expect(firstLines.count == 2)
        #expect(firstLines.first?.utf16Start == 0)
        #expect(firstLines.last?.utf16End == firstText.utf16.count)
        #expect(firstLines[0].utf16End == firstLines[1].utf16Start)
        #expect(firstLines.map(\.text).joined() == "甲😀乙丙丁")
        #expect(secondLines.count == 1)
        #expect(secondLines[0].utf16Start == 0)
        #expect(secondLines[0].utf16End == secondText.utf16.count)
        #expect(secondLines[0].text == secondText)
    }

    @Test("reading position resolves and steps across display lines without wrapping")
    func readingPositionStepsAcrossDisplayLines() throws {
        let source = "第一行内容第二行内容第三行内容"
        let segment = TeleprompterSegment(
            id: "step-source",
            ordinal: 0,
            sourceRange: TeleprompterSourceRange(start: 0, end: source.utf16.count),
            text: source
        )
        let lines = TeleprompterStageLineLayout.layout(
            segments: [segment],
            pointSize: 20,
            availableWidth: 70
        )
        #expect(lines.count > 1)

        let firstPosition = TeleprompterAligner.Position(segmentIndex: 0, utf16Offset: lines[0].utf16Start)
        let secondPosition = TeleprompterStagePresentation.positionByMovingLine(by: 1, from: firstPosition, lines: lines)
        #expect(secondPosition == TeleprompterAligner.Position(segmentIndex: 0, utf16Offset: lines[1].utf16Start))
        #expect(TeleprompterStagePresentation.positionByMovingLine(by: -1, from: firstPosition, lines: lines) == nil)

        let lastPosition = TeleprompterAligner.Position(segmentIndex: 0, utf16Offset: lines.last!.utf16Start)
        #expect(TeleprompterStagePresentation.positionByMovingLine(by: 1, from: lastPosition, lines: lines) == nil)
    }

    @Test("line slots preserve a centered current row at script boundaries")
    func displayLineSlotsStayCenteredAtBoundaries() {
        let atStart: [Int?] = [nil, 0, 1]
        let atMiddle: [Int?] = [3, 4, 5]
        let atEnd: [Int?] = [8, 9, nil]

        #expect(TeleprompterStagePresentation.visibleLineSlots(currentIndex: 0, visibleCount: 3, totalCount: 10) == atStart)
        #expect(TeleprompterStagePresentation.visibleLineSlots(currentIndex: 4, visibleCount: 3, totalCount: 10) == atMiddle)
        #expect(TeleprompterStagePresentation.visibleLineSlots(currentIndex: 9, visibleCount: 3, totalCount: 10) == atEnd)
        #expect(TeleprompterStagePresentation.visibleLineSlots(currentIndex: 4, visibleCount: 2, totalCount: 10) == [4, 5])
        #expect(TeleprompterStagePresentation.visibleLineSlots(currentIndex: 4, visibleCount: 1, totalCount: 10) == [4])
    }

    @Test("stage preferred height grows with configured context and stays bounded")
    func preferredHeightTracksVisibleRows() {
        let one = TeleprompterStageGeometryPolicy.preferredContentHeight(
            visibleLineCount: 1,
            scriptPointSize: 38,
            lineSpacing: 6,
            showsAuxiliaryStatus: false
        )
        let two = TeleprompterStageGeometryPolicy.preferredContentHeight(
            visibleLineCount: 2,
            scriptPointSize: 38,
            lineSpacing: 6,
            showsAuxiliaryStatus: false
        )
        let three = TeleprompterStageGeometryPolicy.preferredContentHeight(
            visibleLineCount: 3,
            scriptPointSize: 38,
            lineSpacing: 6,
            showsAuxiliaryStatus: true
        )

        #expect(one < two)
        #expect(two < three)
        #expect(three <= SpeechRailDesignTokens.Teleprompter.stageMaximumHeight)
        #expect(
            TeleprompterStageGeometryPolicy.preferredContentHeight(
                visibleLineCount: 3,
                scriptPointSize: 60,
                lineSpacing: 24,
                showsAuxiliaryStatus: true
            ) == SpeechRailDesignTokens.Teleprompter.stageMaximumHeight
        )
    }

    @Test("standard zoom frame fills only the available width and caps height")
    func standardZoomFrameFillsWidthAndCapsHeight() {
        let visible = CGRect(x: 24, y: 40, width: 1_720, height: 1_040)
        let frame = TeleprompterStageGeometryPolicy.standardFrame(
            defaultFrame: CGRect(x: 0, y: 0, width: 1_720, height: 900),
            visibleFrame: visible
        )

        #expect(frame.minX == visible.minX)
        #expect(frame.width == visible.width)
        #expect(frame.maxY == visible.maxY)
        #expect(frame.height == SpeechRailDesignTokens.Teleprompter.stageMaximumHeight)
    }

    @Test("preferred window frame includes titlebar height within the stage cap")
    func preferredWindowFrameIncludesTitlebarWithinStageCap() {
        let maximum = SpeechRailDesignTokens.Teleprompter.stageMaximumHeight

        #expect(
            TeleprompterStageGeometryPolicy.cappedWindowFrameHeight(
                388,
                visibleFrameHeight: 1_040
            ) == maximum
        )
        #expect(
            TeleprompterStageGeometryPolicy.cappedWindowFrameHeight(
                320,
                visibleFrameHeight: 280
            ) == 280
        )
        #expect(
            TeleprompterStageGeometryPolicy.cappedWindowFrameHeight(
                320,
                visibleFrameHeight: 1_040
            ) == 320
        )
    }

    @Test("stage defaults favor a compact reading surface")
    func stageDefaultsFavorCompactReadingSurface() {
        #expect(SpeechRailDesignTokens.Teleprompter.stageDefaultWidth < 960)
        #expect(SpeechRailDesignTokens.Teleprompter.stageDefaultHeight < 620)
        #expect(SpeechRailDesignTokens.Teleprompter.stageMinimumVisibleLineCount == 1)
        #expect(SpeechRailDesignTokens.Teleprompter.stageMaximumVisibleLineCount == 3)
        #expect(SpeechRailDesignTokens.Teleprompter.stageDefaultVisibleLineCount == 3)
        #expect(SpeechRailDesignTokens.Teleprompter.stageDefaultOpacity < 0.8)
    }

    @Test("stage settings quick zoom methods change font scale within bounds")
    func quickZoomMethodsChangeFontScale() throws {
        let suiteName = "SpeechRail.TeleprompterStageSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = TeleprompterStageSettings(defaults: defaults)
        let initialScale = settings.fontScale
        settings.increaseFontScale()
        #expect(settings.fontScale > initialScale)

        settings.decreaseFontScale()
        #expect(abs(settings.fontScale - initialScale) < 0.001)

        for _ in 0..<30 { settings.increaseFontScale() }
        #expect(settings.fontScale == SpeechRailDesignTokens.Teleprompter.stageMaximumFontScale)

        for _ in 0..<50 { settings.decreaseFontScale() }
        #expect(settings.fontScale == SpeechRailDesignTokens.Teleprompter.stageMinimumFontScale)
    }

    @Test("stage settings quick opacity methods change opacity within bounds")
    func quickOpacityMethodsChangeOpacity() throws {
        let suiteName = "SpeechRail.TeleprompterStageSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = TeleprompterStageSettings(defaults: defaults)
        let initial = settings.opacity

        settings.increaseOpacity()
        #expect(settings.opacity > initial)

        for _ in 0..<50 { settings.increaseOpacity() }
        #expect(settings.opacity == SpeechRailDesignTokens.Teleprompter.stageMaximumOpacity)

        for _ in 0..<50 { settings.decreaseOpacity() }
        #expect(settings.opacity == SpeechRailDesignTokens.Teleprompter.stageMinimumOpacity)
    }

    @Test("pace status calculates steady, brisk, slow, and establishing states")
    func paceStatusCalculatesStates() {
        // Less than 10 seconds: establishing
        #expect(
            TeleprompterStagePresentation.paceStatus(
                currentIndex: 0,
                totalCount: 10,
                elapsedSeconds: 5,
                targetSeconds: 600
            ) == .establishing
        )

        // On schedule: progress 50% vs time 50% -> steady
        #expect(
            TeleprompterStagePresentation.paceStatus(
                currentIndex: 4,
                totalCount: 10,
                elapsedSeconds: 300,
                targetSeconds: 600
            ) == .steady
        )

        // Ahead of schedule: progress 60% vs time 30% (delta +0.3) -> brisk
        #expect(
            TeleprompterStagePresentation.paceStatus(
                currentIndex: 5,
                totalCount: 10,
                elapsedSeconds: 180,
                targetSeconds: 600
            ) == .brisk
        )

        // Behind schedule: progress 20% vs time 50% (delta -0.3) -> slow
        #expect(
            TeleprompterStagePresentation.paceStatus(
                currentIndex: 1,
                totalCount: 10,
                elapsedSeconds: 300,
                targetSeconds: 600
            ) == .slow
        )

        // No target seconds -> steady after 10s
        #expect(
            TeleprompterStagePresentation.paceStatus(
                currentIndex: 3,
                totalCount: 10,
                elapsedSeconds: 60,
                targetSeconds: 0
            ) == .steady
        )
    }

    @Test("stage summary computes speech review metrics and calibration")
    func stageSummaryComputesMetricsAndCalibration() {
        let segments = [
            TeleprompterSegment(
                id: "seg-1",
                ordinal: 0,
                sourceRange: TeleprompterSourceRange(start: 0, end: 30),
                text: "欢迎大家来到今天的发布会现场，非常高兴能够与各位相聚。"
            ),
            TeleprompterSegment(
                id: "seg-2",
                ordinal: 1,
                sourceRange: TeleprompterSourceRange(start: 30, end: 60),
                text: "今天我们将正式带来全新的产品架构与全栈本地化能力演进。"
            ),
            TeleprompterSegment(
                id: "seg-3",
                ordinal: 2,
                sourceRange: TeleprompterSourceRange(start: 60, end: 90),
                text: "在过去的一年里，我们的团队攻克了数十项技术难关，力求完美。"
            ),
            TeleprompterSegment(
                id: "seg-4",
                ordinal: 3,
                sourceRange: TeleprompterSourceRange(start: 90, end: 120),
                text: "接下来让我们深入了解各个核心子系统的突破与实际体验细节。"
            )
        ]

        let summary = TeleprompterStagePresentation.computeSummary(
            segments: segments,
            currentSegmentIndex: 3,
            elapsedSeconds: 32,
            targetSeconds: 35,
            pace: .natural,
            currentCalibrationFactor: 1.0
        )

        #expect(summary.completedSegments == 4)
        #expect(summary.totalSegments == 4)
        #expect(summary.elapsedSeconds == 32)
        #expect(summary.totalSpokenUnits > 100)
        #expect(summary.actualWPM > 0)
        #expect(summary.paceStatus == .steady)
        #expect(summary.canCalibrate == true)
        #expect(summary.needsCalibration == true)
        #expect(summary.suggestedCalibrationFactor > 0.5 && summary.suggestedCalibrationFactor < 2.0)

        // Accidental start (under 30s) -> canCalibrate is false
        let shortSummary = TeleprompterStagePresentation.computeSummary(
            segments: segments,
            currentSegmentIndex: 0,
            elapsedSeconds: 8,
            targetSeconds: 60,
            pace: .natural,
            currentCalibrationFactor: 1.0
        )
        #expect(shortSummary.canCalibrate == false)
        #expect(shortSummary.needsCalibration == false)
    }

    @Test("pace delta calculates quantitative difference and formatted badge")
    func paceDeltaCalculatesDifferenceAndBadge() {
        // Less than 5s -> nil
        #expect(
            TeleprompterStagePresentation.paceDeltaSeconds(
                currentIndex: 0,
                totalCount: 10,
                elapsedSeconds: 3,
                targetSeconds: 600
            ) == nil
        )

        // Progress 50% (5 of 10) in 600s budget: expected is 300s.
        // Actual elapsed is 260s: delta is +40s (ahead)
        let aheadDelta = TeleprompterStagePresentation.paceDeltaSeconds(
            currentIndex: 4,
            totalCount: 10,
            elapsedSeconds: 260,
            targetSeconds: 600
        )
        #expect(aheadDelta == 40)
        let aheadBadge = TeleprompterStagePresentation.formattedPaceDelta(deltaSeconds: 40)
        #expect(aheadBadge.isAhead == true)
        #expect(aheadBadge.isBehind == false)
        #expect(aheadBadge.label == "超前 +40s")

        // Actual elapsed is 340s: delta is -40s (behind)
        let behindDelta = TeleprompterStagePresentation.paceDeltaSeconds(
            currentIndex: 4,
            totalCount: 10,
            elapsedSeconds: 340,
            targetSeconds: 600
        )
        #expect(behindDelta == -40)
        let behindBadge = TeleprompterStagePresentation.formattedPaceDelta(deltaSeconds: -40)
        #expect(behindBadge.isAhead == false)
        #expect(behindBadge.isBehind == true)
        #expect(behindBadge.label == "滞后 -40s")

        // Actual elapsed is 298s: delta is +2s (within 3s sync)
        let syncBadge = TeleprompterStagePresentation.formattedPaceDelta(deltaSeconds: 2)
        #expect(syncBadge.isSync == true)
        #expect(syncBadge.label == "节拍吻合")
    }

    @Test("stage settings reset font scale restores default scale")
    func resetFontScaleRestoresDefaultScale() throws {
        let suiteName = "SpeechRail.TeleprompterStageSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = TeleprompterStageSettings(defaults: defaults)
        settings.increaseFontScale()
        settings.increaseFontScale()
        #expect(settings.fontScale > 1.0)

        settings.resetFontScale()
        #expect(settings.fontScale == 1.0)
    }
}
