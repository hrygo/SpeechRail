import Foundation
import Testing

#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

@MainActor
struct TeleprompterStageSettingsTests {
    @Test("visible segment count changes without recursive setter")
    func visibleSegmentCountChangeDoesNotRecurse() throws {
        let suiteName = "SpeechRail.TeleprompterStageSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = TeleprompterStageSettings(defaults: defaults)
        settings.visibleSegmentCount = 2

        #expect(settings.visibleSegmentCount == 2)
        #expect(defaults.integer(forKey: "speechrail.teleprompter.stage.visibleSegmentCount") == 2)

        defaults.removeObject(forKey: "speechrail.teleprompter.stage.visibleSegmentCount")
        settings.visibleSegmentCount = 2
        #expect(defaults.integer(forKey: "speechrail.teleprompter.stage.visibleSegmentCount") == 2)
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

        settings.visibleSegmentCount = 1
        #expect(settings.visibleSegmentCount == SpeechRailDesignTokens.Teleprompter.stageMinimumVisibleSegmentCount)
        settings.visibleSegmentCount = 4
        #expect(settings.visibleSegmentCount == SpeechRailDesignTokens.Teleprompter.stageMaximumVisibleSegmentCount)
        #expect(defaults.integer(forKey: "speechrail.teleprompter.stage.visibleSegmentCount") == 2)
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
        #expect(settings.opacity == SpeechRailDesignTokens.Teleprompter.stageMinimumOpacity)
        #expect(abs(settings.backgroundTransparency - 0.65) < 0.001)
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
        #expect(TeleprompterStageTransparencyPresentation.valueLabel(for: 0.283) == "28.30%")
        #expect(TeleprompterStageTransparencyPresentation.valueLabel(for: 0.284) == "28.40%")
    }

    @Test("source editor keeps a bounded preparation-page height")
    func sourceEditorHeightRangeIsOrdered() {
        #expect(SpeechRailDesignTokens.Teleprompter.sourceEditorMinimumHeight <= SpeechRailDesignTokens.Teleprompter.sourceEditorIdealHeight)
        #expect(SpeechRailDesignTokens.Teleprompter.sourceEditorIdealHeight <= SpeechRailDesignTokens.Teleprompter.sourceEditorMaximumHeight)
    }

    @Test("stage preview keeps the current and next semantic segments only")
    func stagePreviewUsesSemanticSegmentWindow() {
        #expect(
            TeleprompterStagePresentation.visibleSegmentIndices(
                currentIndex: 1,
                visibleCount: 2,
                totalCount: 107
            ) == [1, 2]
        )
        #expect(
            TeleprompterStagePresentation.visibleSegmentIndices(
                currentIndex: 106,
                visibleCount: 2,
                totalCount: 107
            ) == [106]
        )
        #expect(
            TeleprompterStagePresentation.visibleSegmentIndices(
                currentIndex: -1,
                visibleCount: 2,
                totalCount: 3
            ) == [0, 1]
        )
    }

    @Test("stage defaults favor a compact reading surface")
    func stageDefaultsFavorCompactReadingSurface() {
        #expect(SpeechRailDesignTokens.Teleprompter.stageDefaultWidth < 960)
        #expect(SpeechRailDesignTokens.Teleprompter.stageDefaultHeight < 620)
        #expect(SpeechRailDesignTokens.Teleprompter.stageMinimumVisibleSegmentCount == 1)
        #expect(SpeechRailDesignTokens.Teleprompter.stageMaximumVisibleSegmentCount == 2)
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

    @Test("stage preview supports browsing all segments when requested")
    func stagePreviewSupportsBrowsingAllSegments() {
        let indices = TeleprompterStagePresentation.visibleSegmentIndices(
            currentIndex: 2,
            visibleCount: 2,
            totalCount: 5,
            isBrowsingAll: true
        )
        #expect(indices == [0, 1, 2, 3, 4])

        let empty = TeleprompterStagePresentation.visibleSegmentIndices(
            currentIndex: 0,
            visibleCount: 2,
            totalCount: 0,
            isBrowsingAll: true
        )
        #expect(empty.isEmpty)
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
