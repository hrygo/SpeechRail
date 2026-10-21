import Foundation

enum SessionActivityPolicy {
    static func shouldTick(active: Bool, visible: Bool, foreground: Bool) -> Bool { active && visible && foreground }
    static func displayDate(now: Date, stoppedAt: Date?) -> Date { stoppedAt ?? now }
    static func levelDescription(_ value: Double, active: Bool) -> String {
        guard active else { return "未采集声音" }
        let bounded = value.isFinite ? max(0, min(1, value)) : 0
        return "输入电平 \(SpeechRailDisplayFormat.percentage(bounded))"
    }
}
