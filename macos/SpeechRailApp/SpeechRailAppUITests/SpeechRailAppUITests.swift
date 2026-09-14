import XCTest

@MainActor
final class SpeechRailAppUITests: XCTestCase {
    func testControlCenterSeparatesCreatorAndServiceNavigation() {
        let app = launchSpeechRail()
        openControlCenter(in: app)

        XCTAssertTrue(app.buttons["服务状态"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["音色创作"].exists)
        XCTAssertTrue(app.buttons["运行监控"].exists)
        XCTAssertTrue(app.buttons["模型"].exists)
        XCTAssertTrue(app.staticTexts["本地控制通道已就绪"].exists)

        app.buttons["音色创作"].click()
        let workspaceTitle = app.descendants(matching: .any)["workspace-title"]
        XCTAssertTrue(workspaceTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(
            workspaceTitle.label.contains("音色创作"),
            "workspace-title label was: \(workspaceTitle.label)"
        )
        let actionsMenu = app.menuButtons["更多操作"]
        XCTAssertTrue(actionsMenu.waitForExistence(timeout: 5))
        actionsMenu.click()
        XCTAssertTrue(app.menuItems["刷新服务状态"].waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])

        app.buttons["模型"].click()
        let modelsTitle = app.descendants(matching: .any)["workspace-title"]
        XCTAssertTrue(modelsTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(
            modelsTitle.label.contains("模型管理"),
            "workspace-title label was: \(modelsTitle.label)"
        )
    }

    func testControlSurfaceShowsServiceAndProfiles() {
        let app = launchSpeechRail()
        openControlCenter(in: app)

        XCTAssertTrue(app.staticTexts["创作"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["服务"].exists)
        XCTAssertTrue(app.buttons["服务状态"].exists)
        XCTAssertTrue(app.buttons["模型"].exists)
        XCTAssertTrue(app.staticTexts["确认本机语音服务能否使用"].exists)
        XCTAssertTrue(app.staticTexts["能力"].exists)
        XCTAssertTrue(app.buttons["运行预检"].exists)

        app.buttons["模型"].tap()
        XCTAssertTrue(app.staticTexts["模型"].waitForExistence(timeout: 2))
    }

    func testDiagnosticsUsesCompactSummaryAndSelectedDetail() {
        let app = launchSpeechRail()
        openControlCenter(in: app)
        app.buttons["诊断"].tap()

        XCTAssertTrue(app.otherElements["diagnostics-summary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["diagnostics-check-list"].exists)
        XCTAssertTrue(app.otherElements["diagnostics-check-detail"].exists)
        XCTAssertTrue(app.buttons["重新运行诊断"].exists)
    }

    func testModelDownloadRequiresExplicitConfirmation() {
        let app = launchSpeechRail()
        openControlCenter(in: app)
        app.buttons["模型"].tap()

        let downloadButton = app.buttons["下载并校验"]
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 5))
        downloadButton.tap()

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

        XCTAssertTrue(app.staticTexts["上次模型准备被中断"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.staticTexts["快速加入声学特征"].exists)
        XCTAssertTrue(app.buttons["插入声学特征：磁性胸腔"].exists)
        app.buttons["插入声学特征：磁性胸腔"].click()

        XCTAssertTrue(app.staticTexts["候选试听"].exists)
        let generateButton = app.buttons["生成候选音色"]
        XCTAssertTrue(generateButton.waitForExistence(timeout: 2))
        generateButton.click()
        XCTAssertTrue(app.buttons["A 槽位试听：播放"].waitForExistence(timeout: 5))
        app.buttons["A 槽位试听：播放"].click()
        XCTAssertTrue(app.buttons["A 槽位试听：暂停"].waitForExistence(timeout: 2))
    }

    func testVoiceLibraryCanCancelAnInFlightPreview() {
        let app = launchSpeechRail(
            arguments: [
                "--ui-test",
                "--ui-test-open-control-center",
                "--ui-test-slow-voice-preview",
            ]
        )
        openControlCenter(in: app)
        app.buttons["音色库"].click()

        XCTAssertTrue(app.staticTexts["系统音色与创作资产"].waitForExistence(timeout: 5))
        let previewButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "试听")
        ).firstMatch
        XCTAssertTrue(previewButton.waitForExistence(timeout: 5))
        previewButton.click()

        let cancelButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "取消试听")
        ).firstMatch
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 2))
        cancelButton.click()
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "试听"))
                .firstMatch
                .waitForExistence(timeout: 2)
        )
    }

    func testWorksViewExposesEmptyStateAndSafeActions() {
        let app = launchSpeechRail()
        openControlCenter(in: app)
        app.buttons["我的作品"].click()

        XCTAssertTrue(app.staticTexts["创作历史与文稿回溯"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["还没有作品"].exists)
        XCTAssertTrue(app.buttons["去配音台"].exists)

        let window = app.windows["SpeechRail 管理控制台"]
        let actionMenu = window.menuButtons["更多操作"].firstMatch
        XCTAssertTrue(actionMenu.waitForExistence(timeout: 5))
        actionMenu.click()
        XCTAssertTrue(app.menuItems["导出选中作品"].waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
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
        let controlCenter = app.windows["SpeechRail 管理控制台"]
        XCTAssertTrue(controlCenter.waitForExistence(timeout: 5))
        // Opening the window from MenuBarExtra can leave its popover as the
        // active event target, which makes controls in the new window appear
        // present but not hittable to XCUITest.
        app.typeKey(.escape, modifierFlags: [])
        // MenuBarExtra can leave the newly opened window behind its popover on
        // macOS runners. Activate the app after the window exists so the
        // following controls are tested through their normal hit targets.
        app.activate()
        XCTAssertTrue(controlCenter.waitForExistence(timeout: 5))
    }

}
