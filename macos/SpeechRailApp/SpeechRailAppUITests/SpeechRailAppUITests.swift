import XCTest

@MainActor
final class SpeechRailAppUITests: XCTestCase {
    func testControlCenterSeparatesCreatorAndServiceNavigation() {
        let app = launchSpeechRail()
        openControlCenter(in: app)

        XCTAssertTrue(app.staticTexts["服务状态"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["音色创作"].exists)
        XCTAssertTrue(app.buttons["运行监控"].exists)
        XCTAssertTrue(app.buttons["模型"].exists)
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
        XCTAssertTrue(app.buttons["服务状态"].exists)
        XCTAssertTrue(app.buttons["模型"].exists)
        XCTAssertTrue(app.staticTexts["服务状态"].exists)
        XCTAssertTrue(app.staticTexts["确认本机语音服务能否使用"].exists)
        XCTAssertTrue(app.staticTexts["能力"].exists)
        XCTAssertTrue(app.buttons["运行预检"].exists)

        app.buttons["模型"].tap()
        XCTAssertTrue(app.staticTexts["模型"].waitForExistence(timeout: 2))
    }

    func testModelDownloadRequiresExplicitConfirmation() {
        let app = launchSpeechRail()
        openControlCenter(in: app)
        app.buttons["模型"].tap()

        let downloadButton = app.buttons["下载并校验"]
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 5))
        downloadButton.tap()

        XCTAssertTrue(
            app.staticTexts["确认下载并校验 quality 档位模型？"].waitForExistence(timeout: 2)
        )
        let dialog = app.windows["SpeechRail 管理控制台"].sheets.firstMatch
        XCTAssertTrue(dialog.buttons["取消"].waitForExistence(timeout: 2))
        dialog.buttons["取消"].tap()
    }

    func testMonitoringExplainsMissingMetrics() {
        let app = launchSpeechRail(arguments: ["--ui-test", "--ui-test-open-control-center", "--ui-test-metrics-unavailable"])
        openControlCenter(in: app)
        app.buttons["运行监控"].tap()

        XCTAssertTrue(app.staticTexts["等待监控样本"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["运行监控"].exists)
    }

    func testModelRecoveryRestoresInterruptedOperationAndRetryAction() {
        let app = launchSpeechRail(arguments: ["--ui-test", "--ui-test-open-control-center", "--ui-test-model-recovery"])
        openControlCenter(in: app)
        app.buttons["模型"].tap()

        XCTAssertTrue(app.staticTexts["上次准备被中断"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["重新下载并校验"].exists)
        XCTAssertFalse(app.buttons["停止下载"].exists)
    }

    func testModelUnsupportedStateExplainsVersionMismatch() {
        let app = launchSpeechRail(
            arguments: ["--ui-test", "--ui-test-open-control-center", "--ui-test-model-unsupported"]
        )
        openControlCenter(in: app)
        app.buttons["模型"].tap()

        XCTAssertTrue(
            app.staticTexts["模型管理暂不可用：服务组件版本不匹配"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["打开诊断"].exists)
    }

    func testSettingsContainAppPreferencesOnly() {
        let app = launchSpeechRail(arguments: ["--ui-test", "--ui-test-open-settings"])
        let statusItem = app.menuBars.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()

        XCTAssertTrue(app.staticTexts["关于 SpeechRail"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["最低系统"].exists)
        XCTAssertFalse(app.staticTexts["服务状态"].exists)
    }

    func testVoiceDesignAcousticChipsAndCandidateRack() {
        let app = launchSpeechRail()
        openControlCenter(in: app)
        app.buttons["音色创作"].click()

        XCTAssertTrue(app.staticTexts["从一句话开始"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["声学特征胶囊 (点击插入)"].exists)
        XCTAssertTrue(app.buttons["插入声学特征：磁性胸腔"].exists)
        app.buttons["插入声学特征：磁性胸腔"].click()

        XCTAssertTrue(app.staticTexts["候选试听机架 (A/B/C/D 候选池)"].exists)
        XCTAssertTrue(app.staticTexts["A"].exists)
        XCTAssertTrue(app.staticTexts["B"].exists)
        XCTAssertTrue(app.buttons["A 槽位试听：播放"].exists)
        app.buttons["A 槽位试听：播放"].click()
        XCTAssertTrue(app.buttons["A 槽位试听：暂停"].waitForExistence(timeout: 2))
    }

    func testWorksViewExposesFullPromptAndPrivacyDecoupledInspector() {
        let app = launchSpeechRail()
        openControlCenter(in: app)
        app.buttons["我的作品"].click()

        XCTAssertTrue(app.staticTexts["创作历史与文稿回溯"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["《流浪地球》旁白选段"].exists)
        XCTAssertTrue(app.staticTexts["起初，没有人在意这一场灾难。这不过是一场山火，一次旱灾，一个物种的灭绝，一座城市的消失。直到这场灾难和每个人息息相关。"].exists)

        let window = app.windows["SpeechRail 管理控制台"]
        let auditButton = window.buttons["脱敏技术详情"].firstMatch
        XCTAssertTrue(auditButton.waitForExistence(timeout: 5))
        auditButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(app.staticTexts["开发者审计 (隐私脱敏)"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["请求 ID"].exists)
        XCTAssertTrue(app.staticTexts["req_7f2b918a"].exists)
        XCTAssertTrue(app.staticTexts["分人标识"].exists)
        XCTAssertTrue(app.staticTexts["speaker_0"].exists)
    }

    private func launchSpeechRail(arguments: [String] = ["--ui-test", "--ui-test-open-control-center"]) -> XCUIApplication {
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
        XCTAssertTrue(app.windows["SpeechRail 管理控制台"].waitForExistence(timeout: 5))
    }
}
