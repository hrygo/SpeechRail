import XCTest

@MainActor
final class SpeechRailAppUITests: XCTestCase {
    func testControlCenterSeparatesCreatorAndServiceNavigation() {
        let app = launchSpeechRail()

        let statusItem = app.menuBars.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()
        let controlCenterMenuItem = statusItem.menus.firstMatch.menuItems["打开管理控制台"]
        XCTAssertTrue(controlCenterMenuItem.waitForExistence(timeout: 2))
        controlCenterMenuItem.click()

        XCTAssertTrue(app.staticTexts["本机服务总览"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["音色创作"].exists)
        XCTAssertTrue(app.buttons["运行监控"].exists)
        XCTAssertTrue(app.buttons["模型管理"].exists)
        XCTAssertTrue(app.staticTexts["服务状态"].exists)
        XCTAssertTrue(app.staticTexts["本地控制通道已就绪"].exists)

        app.buttons["音色创作"].click()
        XCTAssertTrue(app.staticTexts["音色创作"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["从一句话开始"].exists)
    }

    func testControlSurfaceShowsServiceAndProfiles() {
        let app = launchSpeechRail()
        openControlCenter(in: app)

        XCTAssertTrue(app.staticTexts["创作"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["服务"].exists)
        XCTAssertTrue(app.buttons["本机服务总览"].exists)
        XCTAssertTrue(app.buttons["模型管理"].exists)
        XCTAssertTrue(app.staticTexts["服务状态"].exists)

        app.buttons["模型管理"].tap()
        XCTAssertTrue(app.staticTexts["模型管理"].waitForExistence(timeout: 2))
    }

    func testModelDownloadRequiresExplicitConfirmation() {
        let app = launchSpeechRail()
        openControlCenter(in: app)
        app.buttons["模型管理"].tap()

        let downloadButton = app.buttons["下载并校验"]
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 5))
        downloadButton.tap()

        XCTAssertTrue(
            app.staticTexts["确认下载并校验 quality 档位模型？"].waitForExistence(timeout: 2)
        )
        app.buttons["取消"].tap()
    }

    func testMonitoringExplainsMissingMetrics() {
        let app = launchSpeechRail(arguments: ["--ui-test", "--ui-test-metrics-unavailable"])
        openControlCenter(in: app)
        app.buttons["运行监控"].tap()

        XCTAssertTrue(app.staticTexts["等待监控样本"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["运行监控"].exists)
    }

    func testModelRecoveryRestoresInterruptedOperationAndRetryAction() {
        let app = launchSpeechRail(arguments: ["--ui-test", "--ui-test-model-recovery"])
        openControlCenter(in: app)
        app.buttons["模型管理"].tap()

        XCTAssertTrue(app.staticTexts["上次准备被中断"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["重新下载并校验"].exists)
        XCTAssertFalse(app.buttons["停止下载"].exists)
    }

    func testSettingsContainAppPreferencesOnly() {
        let app = launchSpeechRail()
        let statusItem = app.menuBars.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()
        let settingsMenuItem = statusItem.menus.firstMatch.menuItems["打开设置"]
        XCTAssertTrue(settingsMenuItem.waitForExistence(timeout: 2))
        settingsMenuItem.click()

        XCTAssertTrue(app.staticTexts["关于 SpeechRail"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["最低系统"].exists)
        XCTAssertFalse(app.staticTexts["服务状态"].exists)
    }

    private func launchSpeechRail(arguments: [String] = ["--ui-test"]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        app.activate()
        return app
    }

    private func openControlCenter(in app: XCUIApplication) {
        let statusItem = app.menuBars.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()
        let controlCenterMenuItem = statusItem.menus.firstMatch.menuItems["打开管理控制台"]
        XCTAssertTrue(controlCenterMenuItem.waitForExistence(timeout: 2))
        controlCenterMenuItem.click()
    }
}
