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
        #expect(defaults.integer(forKey: "speechrail.teleprompter.stage.visibleSegmentCount") == 3)
    }
}
