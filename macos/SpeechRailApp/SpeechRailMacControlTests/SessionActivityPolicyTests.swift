import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

@Suite(.timeLimit(.minutes(1)))
struct SessionActivityPolicyTests {
    @Test func testElapsedClockStopsWhenInactiveOrHidden() {
        for active in [false, true] {
            for visible in [false, true] {
                for foreground in [false, true] {
                    #expect(SessionActivityPolicy.shouldTick(active: active, visible: visible, foreground: foreground) == (active && visible && foreground))
                }
            }
        }
    }
    @Test func testLevelStatusTextDoesNotDependOnAnimation() {
        #expect(SessionActivityPolicy.levelDescription(0.7, active: true) == "输入电平 70%")
        #expect(SessionActivityPolicy.levelDescription(.nan, active: true) == "输入电平 0%")
        #expect(SessionActivityPolicy.levelDescription(1, active: false) == "未采集声音")
    }
    @Test func testStoppedClockKeepsTheTerminalTimestamp() {
        let stop = Date(timeIntervalSince1970: 10), now = Date(timeIntervalSince1970: 100)
        #expect(SessionActivityPolicy.displayDate(now: now, stoppedAt: stop) == stop)
        #expect(SessionActivityPolicy.displayDate(now: now, stoppedAt: nil) == now)
    }
}
