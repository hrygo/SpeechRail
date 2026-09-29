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

    /// 行数在稿尾与稿首都必须留空，越界那个位置不能显示成别的段落；
    /// 请求的行数还要被夹进设计区间，0 行与超大请求都落到同一组槽位。
    ///
    /// 注意这里断言的是**具体槽位数组**而不是「等于某个入参的结果」：
    /// `visibleLineSlots` 的 `switch` 对任何 ≥3 的入参都走 `default` 返回 3 槽，
    /// 所以 `stageMaximumVisibleLineCount` 这个上限从本函数**不可观测**，
    /// 拿「99 的结果等于 3 的结果」去断言等于什么都没断言，见 §2 第 29 条。
    @Test("two-row mode still leaves the trailing slot empty and row counts stay clamped")
    func displayLineSlotsClampRowsAndEmptyTheTrailingSlot() {
        #expect(TeleprompterStagePresentation.visibleLineSlots(currentIndex: 9, visibleCount: 2, totalCount: 10) == [9, nil])
        #expect(TeleprompterStagePresentation.visibleLineSlots(currentIndex: 0, visibleCount: 2, totalCount: 10) == [0, 1])

        let single = [4]
        let triple = [3, 4, 5]
        #expect(TeleprompterStagePresentation.visibleLineSlots(currentIndex: 4, visibleCount: 0, totalCount: 10) == single)
        #expect(TeleprompterStagePresentation.visibleLineSlots(currentIndex: 4, visibleCount: 99, totalCount: 10) == triple)
        #expect(TeleprompterStagePresentation.visibleLineSlots(currentIndex: 4, visibleCount: -3, totalCount: 10) == single)
        #expect(TeleprompterStagePresentation.visibleLineSlots(currentIndex: 4, visibleCount: 3, totalCount: 0) == [])
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

    @Test("content column width clamps to its own range and persists")
    func contentWidthClampsAndPersists() throws {
        let suiteName = "SpeechRail.TeleprompterStageSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tokens = SpeechRailDesignTokens.Teleprompter.self
        let settings = TeleprompterStageSettings(defaults: defaults)
        #expect(settings.contentWidth == Double(tokens.stageDefaultContentWidth))

        settings.contentWidth = 1
        #expect(settings.contentWidth == Double(tokens.stageMinimumContentWidth))
        settings.contentWidth = 9_999
        #expect(settings.contentWidth == Double(tokens.stageMaximumContentWidth))
        #expect(
            defaults.double(forKey: "speechrail.teleprompter.stage.contentWidth")
                == Double(tokens.stageMaximumContentWidth)
        )
    }

    @Test("scene presets apply token display values and persist the selection")
    func displayPresetsApplyAndPersist() throws {
        let suiteName = "SpeechRail.TeleprompterStageSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tokens = SpeechRailDesignTokens.Teleprompter.self
        let settings = TeleprompterStageSettings(defaults: defaults)
        #expect(settings.preset == .camera)
        #expect(settings.contentWidth == Double(tokens.stageCameraContentWidth))
        #expect(settings.fontScale == tokens.stageCameraFontScale)

        settings.opacity = 0.5
        settings.lineSpacing = 12
        let windowWidth = settings.width

        settings.apply(.podium)
        #expect(settings.preset == .podium)
        #expect(settings.contentWidth == Double(tokens.stagePodiumContentWidth))
        #expect(settings.fontScale == tokens.stagePodiumFontScale)
        #expect(settings.visibleLineCount == tokens.stagePodiumVisibleLineCount)
        // A scene preset only tunes the reading surface: window geometry,
        // transparency and line spacing stay exactly as the user left them.
        #expect(settings.width == windowWidth)
        #expect(settings.opacity == 0.5)
        #expect(settings.lineSpacing == 12)

        let reloaded = TeleprompterStageSettings(defaults: defaults)
        #expect(reloaded.preset == .podium)
        #expect(reloaded.contentWidth == Double(tokens.stagePodiumContentWidth))
        #expect(reloaded.fontScale == tokens.stagePodiumFontScale)
        #expect(reloaded.visibleLineCount == tokens.stagePodiumVisibleLineCount)

        settings.apply(.camera)
        #expect(settings.preset == .camera)
        #expect(settings.contentWidth == Double(tokens.stageCameraContentWidth))
        #expect(settings.fontScale == tokens.stageCameraFontScale)
        #expect(settings.visibleLineCount == tokens.stageDefaultVisibleLineCount)
    }

    @Test("manual display edits fall back to the custom preset")
    func manualDisplayEditsSelectCustomPreset() throws {
        let suiteName = "SpeechRail.TeleprompterStageSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = TeleprompterStageSettings(defaults: defaults)

        settings.apply(.camera)
        #expect(settings.preset == .camera)
        settings.increaseFontScale()
        #expect(settings.preset == .custom)

        settings.apply(.podium)
        #expect(settings.preset == .podium)
        settings.contentWidth += 40
        #expect(settings.preset == .custom)

        settings.apply(.camera)
        settings.visibleLineCount = 1
        #expect(settings.preset == .custom)

        // Re-selecting custom never rewrites the values the user already tuned.
        let tunedWidth = settings.contentWidth
        settings.apply(.custom)
        #expect(settings.preset == .custom)
        #expect(settings.contentWidth == tunedWidth)
        #expect(TeleprompterStageSettings(defaults: defaults).preset == .custom)
    }

    @Test("the content column never outgrows the stage window")
    func contentColumnStaysWithinWindowBounds() {
        let tokens = SpeechRailDesignTokens.Teleprompter.self

        // Ultrawide windows keep the requested reading measure.
        #expect(
            TeleprompterStageLayoutPolicy.contentLayoutWidth(
                windowContentWidth: 3_000,
                requestedContentWidth: tokens.stageCameraContentWidth
            ) == tokens.stageCameraContentWidth
        )
        // A narrower window wins over the requested column.
        #expect(
            TeleprompterStageLayoutPolicy.contentLayoutWidth(
                windowContentWidth: 420,
                requestedContentWidth: tokens.stagePodiumContentWidth
            ) == 420
        )
        // A window narrower than the minimum column still fits its own text.
        #expect(
            TeleprompterStageLayoutPolicy.contentLayoutWidth(
                windowContentWidth: 200,
                requestedContentWidth: tokens.stageCameraContentWidth
            ) == 200
        )
        // An extreme request clamps to the token maximum instead of the window.
        #expect(
            TeleprompterStageLayoutPolicy.contentLayoutWidth(
                windowContentWidth: 4_000,
                requestedContentWidth: 9_999
            ) == tokens.stageMaximumContentWidth
        )
        // Non-finite geometry degrades to a drawable width instead of NaN.
        #expect(
            TeleprompterStageLayoutPolicy.contentLayoutWidth(
                windowContentWidth: .nan,
                requestedContentWidth: tokens.stageCameraContentWidth
            ) == 1
        )
    }

    @Test("switching scene presets keeps the reading position on the same text")
    func columnWidthChangesPreserveReadingPosition() {
        let tokens = SpeechRailDesignTokens.Teleprompter.self
        let source = "欢迎来到今天的发布会现场，接下来介绍本次升级的重点内容与节奏安排。"
        let segment = TeleprompterSegment(
            id: "preset-source",
            ordinal: 0,
            sourceRange: TeleprompterSourceRange(start: 0, end: source.utf16.count),
            text: source
        )
        let position = TeleprompterAligner.Position(segmentIndex: 0, utf16Offset: 12)

        let cameraLines = TeleprompterStageLineLayout.layout(
            segments: [segment],
            pointSize: tokens.stageScriptPointSize * tokens.stageCameraFontScale,
            availableWidth: tokens.stageCameraContentWidth
        )
        let podiumLines = TeleprompterStageLineLayout.layout(
            segments: [segment],
            pointSize: tokens.stageScriptPointSize * tokens.stagePodiumFontScale,
            availableWidth: tokens.stagePodiumContentWidth
        )

        #expect(cameraLines.map(\.text).joined() == source)
        #expect(podiumLines.map(\.text).joined() == source)
        for lines in [cameraLines, podiumLines] {
            let index = TeleprompterStagePresentation.displayLineIndex(for: position, lines: lines)
            let line = index.flatMap { lines[$0] }
            #expect(line?.utf16Start ?? Int.max <= position.utf16Offset)
            #expect(line?.utf16End ?? Int.min >= position.utf16Offset)
        }
    }

    /// 验收第 3 条要的是「字号、列宽**变化**保持位置」，不是「切换两个预设
    /// 保持位置」。既有那条只钉了 camera 与 podium 两个取值——两个点能过，
    /// 不等于整条范围都成立。快捷缩放按钮和列宽滑杆给的是**连续值域**，
    /// 读者随时可以停在中间任何一格，所以这条扫全值域。
    ///
    /// 同时钉住「重排不许丢字」：位置保持的首要前提是每个字符都还在，
    /// 一旦 layout 在某个宽度／字号下吞掉或重复了字符，位置断言会假绿。
    @Test("reading position and text survive every font scale and column width in range")
    func fontScaleAndColumnWidthSweepPreservesPositionAndText() {
        let tokens = SpeechRailDesignTokens.Teleprompter.self
        // 混排：中文（无空格，靠字断行）、ASCII 单词、代理对 emoji。
        // 三者的 UTF-16 长度不同，只用纯中文会让这条回归漏掉一半风险。
        let sources = [
            "欢迎来到今天的发布会现场，接下来介绍本次升级的重点内容与节奏安排。",
            "Model 3 的延迟降到 240ms，error rate 稳定在 0.8% 以内。",
            "第一段落含 emoji 🎯 与代理对 😀，第二段落保持独立。",
            // 连续结尾换行。**不要**指望这一段能触到 layout 的尾行兜底分支：
            // 探针量过——12 段候选文本 × 3 档列宽 × 3 档字号共 108 组，
            // 每组行区间都连续覆盖到 sourceLength，那条分支一次都没进。
            // 它防的是「TextKit 省掉尾部空行片段」，本机复现不出来。
            // 留这一段是为了让区间覆盖断言带上真实会遇到的结尾形态。
            "最后一段以换行结尾，\n\n",
        ]
        let segments = sources.enumerated().map { index, source in
            TeleprompterSegment(
                id: "sweep-\(index)",
                ordinal: index,
                sourceRange: TeleprompterSourceRange(start: 0, end: source.utf16.count),
                text: source
            )
        }
        // 每段取三个位置：段首、正中、段尾前一字。
        var positions: [TeleprompterAligner.Position] = []
        for (index, source) in sources.enumerated() {
            for offset in [0, source.utf16.count / 2, max(0, source.utf16.count - 1)] {
                positions.append(
                    TeleprompterAligner.Position(segmentIndex: index, utf16Offset: offset)
                )
            }
        }

        let scales = stride(
            from: tokens.stageMinimumFontScale,
            through: tokens.stageMaximumFontScale,
            by: 0.05
        )
        let widths = stride(
            from: tokens.stageMinimumContentWidth,
            through: tokens.stageMaximumContentWidth,
            by: 40
        )

        var checked = 0
        for scale in scales {
            for width in widths {
                let lines = TeleprompterStageLineLayout.layout(
                    segments: segments,
                    pointSize: tokens.stageScriptPointSize * scale,
                    availableWidth: width
                )
                // 「不丢字」的正确不变量是**区间并集覆盖全文**，不是显示文本
                // 逐字相等。第一版这里写的是 `lines.map(\.text).joined() ==
                // sources.joined()`，加上结尾换行那段就红了——查下来不是产品
                // 缺陷：行的区间是 [0, 11) 正确覆盖了换行符，而 `text` 是
                // **显示文本**，`displayRange` 刻意不渲染控制字符，少的那一个
                // 单位正是 U+000A。断言写错，不是代码写错。
                for (index, source) in sources.enumerated() {
                    let rows = lines.filter { $0.segmentIndex == index }
                        .sorted { $0.utf16Start < $1.utf16Start }
                    var cursor = 0
                    for row in rows {
                        #expect(
                            row.utf16Start == cursor,
                            "字号 \(scale)、列宽 \(width) 下第 \(index) 段在 \(cursor) 处断了"
                        )
                        #expect(
                            row.utf16End > row.utf16Start,
                            "字号 \(scale)、列宽 \(width) 下第 \(index) 段出现空行"
                        )
                        cursor = row.utf16End
                    }
                    #expect(
                        cursor == source.utf16.count,
                        "字号 \(scale)、列宽 \(width) 下第 \(index) 段只覆盖了 \(cursor)/\(source.utf16.count)"
                    )
                }
                // 不含换行的三段可以更强：显示文本必须逐字还原。
                #expect(
                    lines.filter { $0.segmentIndex < 3 }.map(\.text).joined()
                        == sources.prefix(3).joined(),
                    "字号 \(scale)、列宽 \(width) 下重排改了字"
                )
                for position in positions {
                    let index = TeleprompterStagePresentation.displayLineIndex(
                        for: position,
                        lines: lines
                    )
                    let line = index.flatMap { lines.indices.contains($0) ? lines[$0] : nil }
                    #expect(line != nil, "字号 \(scale)、列宽 \(width) 下位置 \(position) 丢了")
                    #expect(
                        line?.utf16Start ?? Int.max <= position.utf16Offset
                            && line?.utf16End ?? Int.min >= position.utf16Offset,
                        "字号 \(scale)、列宽 \(width) 下位置 \(position) 漂到了别的文字上"
                    )
                }
                checked += 1
            }
        }
        #expect(checked > 100, "值域扫得太少，这条回归没有说服力：只跑了 \(checked) 组")
    }

    /// 换字号或列宽会重排行，旧的偏移可能落到新布局的段尾之外。此时必须
    /// 落到该段最后一行，而不是返回 nil 把阅读位置整个丢掉。
    @Test("an offset past the end of a segment still resolves to that segment's last row")
    @MainActor
    func displayLineIndexClampsOffsetsPastTheSegmentEnd() throws {
        let tokens = SpeechRailDesignTokens.Teleprompter.self
        let source = "换行之后偏移会落到新布局的段尾之外，必须落到最后一行。"
        let segment = TeleprompterSegment(
            id: "segment-0",
            ordinal: 0,
            sourceRange: TeleprompterSourceRange(start: 0, end: source.utf16.count),
            text: source
        )
        let lines = TeleprompterStageLineLayout.layout(
            segments: [segment],
            pointSize: tokens.stageScriptPointSize * tokens.stageCameraFontScale,
            availableWidth: tokens.stageCameraContentWidth
        )
        let lastRow = try #require(lines.last)

        let beyond = TeleprompterAligner.Position(
            segmentIndex: 0,
            utf16Offset: source.utf16.count + 500
        )
        #expect(
            TeleprompterStagePresentation.displayLineIndex(for: beyond, lines: lines)
                == lines.indices.last,
            "超出段尾的偏移必须落到该段最后一行"
        )
        #expect(
            TeleprompterStagePresentation.positionByMovingLine(
                by: 1, from: beyond, lines: lines
            ) == nil,
            "已经在最后一行时向下移动必须原地不动"
        )
        #expect(lastRow.utf16End <= source.utf16.count)
    }

    @Test("the quick recovery action appears only after leaving the reading position")
    func quickRecoveryOnlyAppearsWhileBrowsing() {
        #expect(TeleprompterStageRecoveryPresentation.shouldOfferRecovery(isBrowsingAll: true, isFollowing: false))
        #expect(!TeleprompterStageRecoveryPresentation.shouldOfferRecovery(isBrowsingAll: false, isFollowing: false))
        #expect(!TeleprompterStageRecoveryPresentation.shouldOfferRecovery(isBrowsingAll: true, isFollowing: true))
        #expect(!TeleprompterStageRecoveryPresentation.shouldOfferRecovery(isBrowsingAll: false, isFollowing: true))
        #expect(!TeleprompterStageRecoveryPresentation.recoveryTitle.isEmpty)
        #expect(!TeleprompterStageRecoveryPresentation.recoveryHelp.isEmpty)
    }

    @Test("Reduce Motion removes the stage scrolling animation")
    func reduceMotionRemovesScrollAnimation() {
        #expect(TeleprompterStageMotionPolicy.scrollAnimation(reduceMotion: true) == nil)
        #expect(TeleprompterStageMotionPolicy.scrollAnimation(reduceMotion: false) != nil)
    }

    // MARK: - 边界与退化输入（变异覆盖补齐，第六十六轮）
    //
    // 上面 33 条用例覆盖的是「典型值下的行为」。本轮把定向变异落到这个文件
    // 上，23 条里 12 条存活——存活的几乎全是**边界**：非有限输入、恰好等于
    // 末行末尾、刚开口的第一段、以及「差一点点就不该报」的那几道死区。

    /// 窗口在 macOS 上被拖到极端尺寸、或 Stage 在首次布局时拿到 0 宽，都可能
    /// 交出非有限的排版参数。`max(1, .nan)` 在 Swift 里返回 `.nan` 而不是 1
    /// （`max` 实现是 `y < x ? x : y`，而 `nan < 1` 为假），所以这道守卫是
    /// 唯一让退化输入退回 1 的地方。
    @Test("a non-finite layout width still produces a complete tiling of the text")
    func nonFiniteLayoutWidthStillTilesTheSource() {
        let source = "开场😀欢迎来到SpeechRail提词器，今天介绍快捷翻行。"
        let segment = TeleprompterSegment(
            id: "degenerate-width",
            ordinal: 0,
            sourceRange: TeleprompterSourceRange(start: 0, end: source.utf16.count),
            text: source
        )

        for width in [CGFloat.nan, .infinity] {
            let lines = TeleprompterStageLineLayout.layout(
                segments: [segment],
                pointSize: 20,
                availableWidth: width
            )
            // 退化宽度必须按 1 处理。只断言「拼得回原文」区分不出来——排版器
            // 在 NaN 宽度下同样能把整段塞进一行，那三条断言照样成立。
            let fallback = TeleprompterStageLineLayout.layout(
                segments: [segment],
                pointSize: 20,
                availableWidth: 1
            )
            #expect(
                lines.count == fallback.count,
                "宽度 \(width) 必须退回按 1 排版，而不是被当成无限宽"
            )
            #expect(lines.first?.utf16Start == 0, "宽度 \(width) 下必须仍从 0 开始")
            #expect(lines.last?.utf16End == source.utf16.count, "宽度 \(width) 下必须仍盖到末尾")
            #expect(lines.map(\.text).joined() == source, "宽度 \(width) 下不得丢字")
        }
    }

    /// 同一道退化输入，字号侧的守卫是独立的：字号退化会先影响 `NSFont`，
    /// 症状与宽度侧完全不同（宽度侧表现为整段挤成一行或排版循环不收敛）。
    @Test("a non-finite point size still produces a complete tiling of the text")
    func nonFinitePointSizeStillTilesTheSource() {
        let source = "开场😀欢迎来到SpeechRail提词器，今天介绍快捷翻行。"
        let segment = TeleprompterSegment(
            id: "degenerate-point-size",
            ordinal: 0,
            sourceRange: TeleprompterSourceRange(start: 0, end: source.utf16.count),
            text: source
        )

        // 同样必须按字号 1 处理，而不是把退化值交给 `NSFont.systemFont`。
        // 宽度侧的用例已经证明 NaN 在 `max` 里会原样传下去，字号侧必须单独立
        // 一条：无穷大字号若真被采纳，整段会挤成一行，与按 1 排版的结果不同。
        let fallback = TeleprompterStageLineLayout.layout(
            segments: [segment],
            pointSize: 1,
            availableWidth: 82
        )
        for pointSize in [CGFloat.nan, .infinity] {
            let lines = TeleprompterStageLineLayout.layout(
                segments: [segment],
                pointSize: pointSize,
                availableWidth: 82
            )
            #expect(
                lines.count == fallback.count,
                "字号 \(pointSize) 必须退回按 1 排版"
            )
            #expect(lines.first?.utf16Start == 0)
            #expect(lines.last?.utf16End == source.utf16.count)
            #expect(lines.map(\.text).joined() == source)
        }
    }

    /// 跟随器给出的偏移**恰好等于**末行末尾时（最后一段读完、但还没切段），
    /// 舞台必须停在末行而不是「找不到对应行」。既有那条「offset past the end」
    /// 的用例用的是严格越过末尾的值，`>=` 改成 `>` 照样通过。
    @Test("a reading offset exactly at the last row end still resolves to that row")
    func offsetExactlyAtLastRowEndResolvesToIt() throws {
        let source = "第一行内容比较长一些用于触发换行，第二行短。"
        let segment = TeleprompterSegment(
            id: "exact-end",
            ordinal: 0,
            sourceRange: TeleprompterSourceRange(start: 0, end: source.utf16.count),
            text: source
        )
        let lines = TeleprompterStageLineLayout.layout(
            segments: [segment],
            pointSize: 20,
            availableWidth: 120
        )
        let last = try #require(lines.last)

        #expect(
            TeleprompterStagePresentation.displayLineIndex(
                for: TeleprompterAligner.Position(
                    segmentIndex: 0,
                    utf16Offset: last.utf16End
                ),
                lines: lines
            ) == lines.count - 1
        )
    }

    /// 刚开口时（1 段 / 100 段）不该报「跟得上」。`progressRatio > 0` 会让它
    /// 直接进入偏差比较，而此时时间比必然远大于进度比，于是**刚开口就报偏慢**。
    @Test("a session that just started still reports establishing")
    func justStartedSessionReportsEstablishing() {
        #expect(
            TeleprompterStagePresentation.paceStatus(
                currentIndex: 0,
                totalCount: 100,
                elapsedSeconds: 300,
                targetSeconds: 600
            ) == .establishing
        )
    }

    /// 同理，配速差值在进度 1% 时不该给出「落后 54 秒」这种读数。
    @Test("pace delta stays silent while progress is still negligible")
    func paceDeltaStaysSilentAtNegligibleProgress() {
        #expect(
            TeleprompterStagePresentation.paceDeltaSeconds(
                currentIndex: 0,
                totalCount: 100,
                elapsedSeconds: 60,
                targetSeconds: 600
            ) == nil
        )
    }

    /// 「需要校准」是一条**死区**而不是「可校准就建议」：实测倍率与当前倍率
    /// 完全一致时不该反复提示读者去改一个已经正确的设置。
    @Test("calibration is not suggested when the measured factor already matches")
    func calibrationIsNotSuggestedWhenItAlreadyMatches() {
        let segments = [
            TeleprompterSegment(
                id: "cal-1",
                ordinal: 0,
                sourceRange: TeleprompterSourceRange(start: 0, end: 30),
                text: "欢迎大家来到今天的发布会现场，非常高兴能够与各位相聚。"
            ),
            TeleprompterSegment(
                id: "cal-2",
                ordinal: 1,
                sourceRange: TeleprompterSourceRange(start: 30, end: 60),
                text: "今天我们将正式带来全新的产品架构与全栈本地化能力演进。"
            ),
            TeleprompterSegment(
                id: "cal-3",
                ordinal: 2,
                sourceRange: TeleprompterSourceRange(start: 60, end: 90),
                text: "在过去的一年里，我们的团队攻克了数十项技术难关，力求完美。"
            ),
            TeleprompterSegment(
                id: "cal-4",
                ordinal: 3,
                sourceRange: TeleprompterSourceRange(start: 90, end: 120),
                text: "接下来让我们深入了解各个核心子系统的突破与实际体验细节。"
            )
        ]
        let first = TeleprompterStagePresentation.computeSummary(
            segments: segments,
            currentSegmentIndex: 3,
            elapsedSeconds: 32,
            targetSeconds: 35,
            pace: .natural,
            currentCalibrationFactor: 1.0
        )
        #expect(first.canCalibrate)
        #expect(first.needsCalibration)

        // 差值 0.01——落在 0.02 的死区里。**不能取 0**：`abs(0) > 0.02` 与
        // `abs(0) > 0` 同为 false，那样的夹具改不掉这道死区。
        let matched = TeleprompterStagePresentation.computeSummary(
            segments: segments,
            currentSegmentIndex: 3,
            elapsedSeconds: 32,
            targetSeconds: 35,
            pace: .natural,
            currentCalibrationFactor: first.suggestedCalibrationFactor - 0.01
        )
        #expect(matched.canCalibrate)
        #expect(
            abs(matched.suggestedCalibrationFactor - first.suggestedCalibrationFactor) < 0.0001,
            "前提：两次实测的倍率必须一致，否则下面证明的不是死区"
        )
        #expect(
            matched.needsCalibration == false,
            "倍率已经一致时不得再提示读者调整"
        )
    }

    /// 未读满 30 秒就**不允许**给出校准建议——样本太少，测出来的倍率没有意义。
    /// 既有那条「Accidental start」用例之所以绿，是因为它只读了第 1 段
    /// （29 个单元），`totalUnits >= 50` 这条已经先把它挡住了；本条用**读得够多
    /// 但时间不够**的素材，才真正咬住 30 秒这道门。
    @Test("calibration stays unavailable before thirty seconds even with enough text")
    func calibrationStaysUnavailableBeforeThirtySeconds() {
        let segments = (0..<4).map { index in
            TeleprompterSegment(
                id: "early-\(index)",
                ordinal: index,
                sourceRange: TeleprompterSourceRange(start: index * 30, end: index * 30 + 30),
                text: [
                    "欢迎大家来到今天的发布会现场，非常高兴能够与各位相聚。",
                    "今天我们将正式带来全新的产品架构与全栈本地化能力演进。",
                    "在过去的一年里，我们的团队攻克了数十项技术难关，力求完美。",
                    "接下来让我们深入了解各个核心子系统的突破与实际体验细节。"
                ][index]
            )
        }

        // 时间不够（20 秒 < 30 秒），但读到的单元数已经过 50。
        let tooEarly = TeleprompterStagePresentation.computeSummary(
            segments: segments,
            currentSegmentIndex: 2,
            elapsedSeconds: 20,
            targetSeconds: 60,
            pace: .natural,
            currentCalibrationFactor: 1.0
        )
        #expect(tooEarly.totalSpokenUnits >= 50, "本条的前提是单元数已经够")
        #expect(tooEarly.canCalibrate == false, "未满 30 秒不得允许校准")
        #expect(tooEarly.needsCalibration == false)

        // 同样的素材、过 30 秒后应当可以校准——否则上面的断言可能因为别的原因通过。
        let soonEnough = TeleprompterStagePresentation.computeSummary(
            segments: segments,
            currentSegmentIndex: 2,
            elapsedSeconds: 32,
            targetSeconds: 60,
            pace: .natural,
            currentCalibrationFactor: 1.0
        )
        #expect(soonEnough.canCalibrate, "过 30 秒后应当可以校准")
    }

    /// 阅读位置被外部改到总段数之外时，「已完成 N 段」不能跟着越界——
    /// 界面上的「已完成 8 / 共 4 段」与逐段高亮都会跟着错。
    @Test("a reading position past the last segment still reports a completed count in range")
    func completedSegmentCountStaysInRange() {
        let segments = [
            TeleprompterSegment(
                id: "only",
                ordinal: 0,
                sourceRange: TeleprompterSourceRange(start: 0, end: 12),
                text: "只有一段稿子。"
            )
        ]
        let summary = TeleprompterStagePresentation.computeSummary(
            segments: segments,
            currentSegmentIndex: 99,
            elapsedSeconds: 30,
            targetSeconds: 60,
            pace: .natural,
            currentCalibrationFactor: 1.0
        )
        #expect(summary.completedSegments == summary.totalSegments)
        #expect(summary.completedSegments == 1)
    }

    /// 脚本文号的下界夹取是承重的：`38 × 0.67 = 25.46`，低于 28 的设计下限。
    /// 读者把字号拉到最小时应当停在 28pt，而不是拿到一个越界的 25.46pt。
    /// （上界 60 与 `38 × 1.52 = 57.76` 之间有余量，那半边是冗余的。）
    @Test("the script point size stops at the design minimum at the smallest font scale")
    func scriptPointSizeStopsAtTheDesignMinimum() throws {
        let suiteName = "SpeechRail.TeleprompterStageSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = TeleprompterStageSettings(defaults: defaults)

        settings.fontScale = SpeechRailDesignTokens.Teleprompter.stageMinimumFontScale
        #expect(
            settings.scriptPointSize == SpeechRailDesignTokens.Teleprompter.stageScriptMinimumPointSize,
            "最小字号时脚本文号必须停在设计下限"
        )

        settings.fontScale = SpeechRailDesignTokens.Teleprompter.stageMaximumFontScale
        #expect(settings.scriptPointSize <= SpeechRailDesignTokens.Teleprompter.stageScriptMaximumPointSize)
    }
}
