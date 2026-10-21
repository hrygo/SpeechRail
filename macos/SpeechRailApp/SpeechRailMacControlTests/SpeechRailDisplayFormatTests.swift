import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

struct SpeechRailDisplayFormatTests {
    @Test(arguments: [
        (0.0, "00:00"), (-1, "00:00"), (0.9, "00:00"),
        (59.99, "00:59"), (60, "01:00"), (3599.99, "59:59"),
        (3600, "1:00:00"), (3725, "1:02:05"), (90061, "25:01:01")
    ])
    func timecodesNeverAdvanceBeforeTheAudio(_ seconds: Double, _ expected: String) {
        #expect(SpeechRailDisplayFormat.timecode(seconds) == expected)
    }

    @Test func historicalEvidenceCanKeepNearestSecondPrecision() {
        #expect(SpeechRailDisplayFormat.timecode(3.5, rounding: .toNearestOrAwayFromZero) == "00:04")
        #expect(SpeechRailDisplayFormat.timecode(59.6, rounding: .toNearestOrAwayFromZero) == "01:00")
    }

    @Test(arguments: [
        (0.0, "0 秒"), (0.004, "小于 0.01 秒"), (0.12, "0.12 秒"),
        (26.9, "26.9 秒"), (60, "1 分"), (61.9, "1 分 1 秒"),
        (3601, "1 小时 1 秒"), (90061, "25 小时 1 分 1 秒")
    ])
    func audioDurationsChooseReadableUnits(_ seconds: Double, _ expected: String) {
        #expect(SpeechRailDisplayFormat.duration(seconds) == expected)
    }

    @Test func durationStylesKeepTheirMeaning() {
        #expect(SpeechRailDisplayFormat.duration(0, style: .elapsed) == "0 秒")
        #expect(SpeechRailDisplayFormat.duration(59.99, style: .elapsed) == "59 秒")
        #expect(SpeechRailDisplayFormat.duration(5400, style: .span) == "1.5 小时")
        #expect(SpeechRailDisplayFormat.duration(172800, style: .span) == "2 天")
    }

    @Test(arguments: [(0.75, "0.75×"), (1, "1×"), (1.25, "1.25×"), (1.5, "1.5×"), (2, "2×")])
    func ratesKeepTwoSignificantDecimalPlaces(_ rate: Double, _ expected: String) {
        #expect(SpeechRailDisplayFormat.playbackRate(rate) == expected)
    }

    @Test func progressDoesNotClaimCompletionBeforeCommit() {
        #expect(SpeechRailDisplayFormat.progress(0.129) == "12%")
        #expect(SpeechRailDisplayFormat.progress(0.29) == "29%")
        #expect(SpeechRailDisplayFormat.progress(0.99999) == "99%")
        #expect(SpeechRailDisplayFormat.progress(1) == "99%")
        #expect(SpeechRailDisplayFormat.progress(2) == "99%")
        #expect(SpeechRailDisplayFormat.progress(-1) == "0%")
        #expect(SpeechRailDisplayFormat.progress(0.99, isComplete: true) == "100%")
        #expect(SpeechRailDisplayFormat.progressValue(1) == 0.99)
        #expect(SpeechRailDisplayFormat.progressValue(0.129) == 0.12)
        #expect(SpeechRailDisplayFormat.progressValue(1, isComplete: true) == 1)
        #expect(SpeechRailDisplayFormat.progressValue(.nan) == nil)
        // A measurement is not task progress: a measured match can legitimately be 100%.
        #expect(SpeechRailDisplayFormat.percentage(0.99999) == "100%")
        #expect(SpeechRailDisplayFormat.percentage(0.126, decimalPlaces: 1) == "12.6%")
    }

    @Test func bytesUseTheScenarioAndDoNotRoundSmallFilesToZeroGiB() {
        #expect(SpeechRailDisplayFormat.bytes(0, context: .file) == "0 B")
        #expect(SpeechRailDisplayFormat.bytes(512, context: .file) == "512 B")
        #expect(SpeechRailDisplayFormat.bytes(42_000_000, context: .file) == "42 MB")
        #expect(SpeechRailDisplayFormat.bytes(1_073_741_824, context: .memory) == "1 GiB")
        #expect(SpeechRailDisplayFormat.bytes(1_073_741_824, context: .file) == "1.1 GB")
        #expect(SpeechRailDisplayFormat.bytes(1_048_576, context: .memory) == "1 MiB")
    }

    @Test func missingValuesAreNotZeroAndUnknownModesAreNotKnownModes() {
        #expect(SpeechRailDisplayFormat.value(nil) == "未提供")
        #expect(SpeechRailDisplayFormat.value("  ", missing: .notLoaded) == "未读取")
        #expect(SpeechRailDisplayFormat.value("0") == "0")
        #expect(SpeechRailDisplayFormat.MissingValue.noSamples.text == "样本不足")
        #expect(SpeechRailDisplayFormat.voiceMode("system") == "系统音色")
        #expect(SpeechRailDisplayFormat.voiceMode("clone") == "复刻音色")
        #expect(SpeechRailDisplayFormat.voiceMode("design") == "设计音色")
        #expect(SpeechRailDisplayFormat.voiceMode("future_mode") == "未知类型")
        #expect(SpeechRailDisplayFormat.voiceMode(nil) == "未提供")
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude])
    func invalidNumbersDoNotCrashOrMasqueradeAsZero(_ number: Double) {
        #expect(SpeechRailDisplayFormat.timecode(number) == "未知")
        #expect(SpeechRailDisplayFormat.duration(number) == "未知")
        #expect(SpeechRailDisplayFormat.playbackRate(number) == "未知")
    }

    @Test func unknownProgressAndInvalidCapacityHaveExplicitFallbacks() {
        #expect(SpeechRailDisplayFormat.progress(.nan) == "未知")
        #expect(SpeechRailDisplayFormat.percentage(.infinity) == "未知")
        #expect(SpeechRailDisplayFormat.bytes(-1, context: .file) == "未知")
        #expect(SpeechRailDisplayFormat.bytes(Int64.max, context: .memory).hasSuffix(" EiB"))
    }

    @Test func relativeAgesChooseTheScaleAndClampFutureClockSkew() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(SpeechRailDisplayFormat.relativeAge(since: start, now: start.addingTimeInterval(5400)) == "1.5 小时前")
        #expect(SpeechRailDisplayFormat.relativeAge(since: start.addingTimeInterval(5), now: start) == "0 秒前")
    }

    @Test func datesUseGregorianCalendarAndTheChosenTimeZone() throws {
        let china = try #require(TimeZone(secondsFromGMT: 28800))
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let date = Date(timeIntervalSince1970: 1792048260)
        #expect(date.speechRailFormatted(timeZone: china) == "2026/10/15 15:11")
        #expect(date.speechRailFormatted(timeZone: utc) == "2026/10/15 07:11")
        #expect(date.speechRailFormatted(.date, timeZone: china) == "2026/10/15")
        #expect(date.speechRailFormatted(.time, timeZone: china) == "15:11")
        #expect(date.speechRailFormatted(.timeWithSeconds, timeZone: china) == "15:11:00")
        #expect(date.speechRailFormatted(.monthDay, timeZone: china) == "10/15")
        let rollover = try #require(ISO8601DateFormatter().date(from: "2026-12-31T18:05:09Z"))
        #expect(rollover.speechRailFormatted(.dateTimeWithSeconds, timeZone: china) == "2027/01/01 02:05:09")
    }
}
