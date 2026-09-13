import XCTest

@MainActor
final class SpeechRailAppUITests: XCTestCase {
    func testControlSurfaceShowsServiceAndProfiles() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test"]
        app.launch()
        app.activate()

        // Open Settings through the status-item menu, not synthetic keyboard input.
        let statusItem = app.menuBars.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()
        let settingsMenuItem = statusItem.menus.firstMatch.menuItems["打开设置"]
        XCTAssertTrue(settingsMenuItem.waitForExistence(timeout: 2))
        settingsMenuItem.click()

        XCTAssertTrue(app.staticTexts["SpeechRail"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["服务状态"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["启动"].exists)
        XCTAssertTrue(app.buttons["停止"].exists)
        XCTAssertTrue(app.staticTexts["模型档位"].exists)
        XCTAssertTrue(app.buttons["应用档位"].exists)

        app.buttons["应用档位"].tap()
        let confirmation = app.sheets.firstMatch
        XCTAssertTrue(confirmation.buttons["确认切换"].waitForExistence(timeout: 2))
        confirmation.buttons["取消"].tap()
    }

    func testProfileApplyFailureShowsActionableMessage() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test", "--ui-test-profile-failure"]
        app.launch()
        app.activate()

        let statusItem = app.menuBars.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()
        let settingsMenuItem = statusItem.menus.firstMatch.menuItems["打开设置"]
        XCTAssertTrue(settingsMenuItem.waitForExistence(timeout: 2))
        settingsMenuItem.click()

        let applyButton = app.buttons["应用档位"]
        XCTAssertTrue(applyButton.waitForExistence(timeout: 5))
        applyButton.tap()
        let confirmation = app.sheets.firstMatch
        XCTAssertTrue(confirmation.buttons["确认切换"].waitForExistence(timeout: 2))
        confirmation.buttons["确认切换"].tap()

        XCTAssertTrue(app.staticTexts["profile preparation failed"].waitForExistence(timeout: 5))
    }
}
