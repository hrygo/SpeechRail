import Foundation

/// Human-readable presentation only. Protocol, storage and subtitle formats stay separate.
public enum SpeechRailDisplayFormat {
    public enum MissingValue: Sendable {
        case notLoaded, notProvided, unknown, noSamples, notEvaluated, notApplicable, compact, timecode

        public var text: String {
            switch self {
            case .notLoaded: "未读取"
            case .notProvided: "未提供"
            case .unknown: "未知"
            case .noSamples: "样本不足"
            case .notEvaluated: "未评估"
            case .notApplicable: "不适用"
            case .compact: "—"
            case .timecode: "--:--"
            }
        }
    }

    public enum DurationStyle: Sendable {
        /// Audio facts retain subsecond precision; longer clips use hours/minutes/seconds.
        case audio
        /// Live elapsed time never rounds ahead of the clock.
        case elapsed
        /// Coverage and uptime choose seconds, minutes, hours or days.
        case span
    }

    public enum ByteContext: Sendable {
        case file, memory
    }

    public static func value(_ value: String?, missing: MissingValue = .notProvided) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return missing.text
        }
        return value
    }

    public static func timecode(
        _ seconds: TimeInterval,
        rounding: FloatingPointRoundingRule = .down
    ) -> String {
        guard let total = wholeSeconds(seconds, rounding: rounding) else { return MissingValue.unknown.text }
        if total >= 3600 {
            return "\(total / 3600):" + String(format: "%02d:%02d", total / 60 % 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    public static func duration(_ seconds: TimeInterval, style: DurationStyle = .audio) -> String {
        guard let total = wholeSeconds(seconds), seconds >= 0 else { return MissingValue.unknown.text }
        if style == .span {
            if seconds >= 86400 { return decimal(seconds / 86400) + " 天" }
            if seconds >= 3600 { return decimal(seconds / 3600) + " 小时" }
            if seconds >= 60 { return decimal(seconds / 60) + " 分钟" }
        }
        if style == .audio, seconds > 0, seconds < 60 {
            if seconds < 0.01 { return "小于 0.01 秒" }
            // Do not emit "60 秒" just below the minute boundary.
            let places = seconds < 1 ? 2 : 1
            let scale = pow(10.0, Double(places))
            let display = min((seconds * scale).rounded() / scale, 60 - 1 / scale)
            return decimal(display, places: places) + " 秒"
        }
        var parts: [String] = []
        if total >= 3600 { parts.append("\(total / 3600) 小时") }
        if total / 60 % 60 > 0 { parts.append("\(total / 60 % 60) 分") }
        if total % 60 > 0 || parts.isEmpty { parts.append("\(total % 60) 秒") }
        return parts.joined(separator: " ")
    }

    public static func playbackRate(_ rate: Double) -> String {
        guard rate.isFinite, rate > 0, rate < Double(Int.max) else { return MissingValue.unknown.text }
        return decimal(rate, places: 2) + "×"
    }

    /// Completion comes from the workflow, never inferred from transferred bytes or fraction alone.
    public static func progress(_ fraction: Double, isComplete: Bool = false) -> String {
        guard let value = progressValue(fraction, isComplete: isComplete) else { return MissingValue.unknown.text }
        return "\(Int((value * 100).rounded()))%"
    }

    /// The bar and its spoken/visible label must agree, including while awaiting commit.
    public static func progressValue(_ fraction: Double, isComplete: Bool = false) -> Double? {
        if isComplete { return 1 }
        guard fraction.isFinite else { return nil }
        // Remove one-ULP multiplication noise (0.29 * 100 can be 28.999999999999996).
        let percent = (min(1, max(0, fraction)) * 100).nextUp.rounded(.down)
        return min(99, percent) / 100
    }

    /// Measurements (e.g. transcript match) can legitimately round to 100% without a task state.
    public static func percentage(_ fraction: Double, decimalPlaces: Int = 0) -> String {
        guard fraction.isFinite else { return MissingValue.unknown.text }
        return decimal(min(1, max(0, fraction)) * 100, places: min(2, max(0, decimalPlaces))) + "%"
    }

    public static func bytes(_ bytes: Int64, context: ByteContext) -> String {
        guard bytes >= 0 else { return MissingValue.unknown.text }
        let base = context == .file ? 1000.0 : 1024.0
        let units = context == .file
            ? ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
            : ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]
        var value = Double(bytes)
        var index = 0
        while value >= base, index < units.count - 1 {
            value /= base
            index += 1
        }
        // Promote if rounding would otherwise show e.g. "1000 MB".
        if (value * 10).rounded() / 10 >= base, index < units.count - 1 {
            value /= base
            index += 1
        }
        return decimal(value, places: index == 0 ? 0 : 1) + " " + units[index]
    }

    public static func voiceMode(_ mode: String?) -> String {
        guard let mode, !mode.isEmpty else { return MissingValue.notProvided.text }
        switch mode {
        case "system": return "系统音色"
        case "clone": return "复刻音色"
        case "design": return "设计音色"
        default: return "未知类型"
        }
    }

    public static func relativeAge(since date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds.isFinite else { return MissingValue.unknown.text }
        return duration(max(0, seconds), style: .span) + "前"
    }

    private static func wholeSeconds(
        _ seconds: Double,
        rounding: FloatingPointRoundingRule = .down
    ) -> Int? {
        guard seconds.isFinite else { return nil }
        let rounded = max(0, seconds).rounded(rounding)
        guard rounded < Double(Int.max) else { return nil }
        return Int(rounded)
    }

    private static func decimal(_ value: Double, places: Int = 1) -> String {
        var result = String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), places, value)
        if result.contains(".") {
            while result.hasSuffix("0") { result.removeLast() }
            if result.hasSuffix(".") { result.removeLast() }
        }
        return result
    }
}

public enum SpeechRailDateFormat {
    public enum Style: Sendable {
        case dateTime, dateTimeWithSeconds, date, time, timeWithSeconds, monthDay

        fileprivate var pattern: String {
            switch self {
            case .dateTime: "yyyy/MM/dd HH:mm"
            case .dateTimeWithSeconds: "yyyy/MM/dd HH:mm:ss"
            case .date: "yyyy/MM/dd"
            case .time: "HH:mm"
            case .timeWithSeconds: "HH:mm:ss"
            case .monthDay: "MM/dd"
            }
        }
    }
}

extension Date {
    /// Uses the local time zone by default, independent of system language and calendar.
    public func speechRailFormatted(
        _ style: SpeechRailDateFormat.Style = .dateTime,
        timeZone: TimeZone = .current
    ) -> String {
        guard timeIntervalSince1970.isFinite else { return SpeechRailDisplayFormat.MissingValue.unknown.text }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = style.pattern
        return formatter.string(from: self)
    }
}
