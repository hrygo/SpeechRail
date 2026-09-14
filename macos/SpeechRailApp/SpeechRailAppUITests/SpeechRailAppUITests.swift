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

        app.buttons["音色创作"].clickWhenReady()
        let workspaceTitle = app.descendants(matching: .any)["workspace-title"]
        XCTAssertTrue(workspaceTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(
            workspaceTitle.label.contains("音色创作"),
            "workspace-title label was: \(workspaceTitle.label)"
        )
        let actionsMenu = app.menuButtons["更多操作"]
        XCTAssertTrue(actionsMenu.waitForExistence(timeout: 5))
        actionsMenu.clickWhenReady()
        XCTAssertTrue(app.menuItems["刷新状态"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])

        app.buttons["模型"].clickWhenReady()
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

        app.buttons["模型"].clickWhenReady()
        XCTAssertEqual(identifierElement("workspace-title", in: app).label, "模型管理")
    }

    func testDiagnosticsUsesCompactSummaryAndSelectedDetail() {
        let app = launchSpeechRail()
        openControlCenter(in: app)
        app.buttons["诊断"].clickWhenReady()

        XCTAssertTrue(identifierElement("diagnostics-summary", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(identifierElement("diagnostics-check-list", in: app).exists)
        XCTAssertTrue(identifierElement("diagnostics-check-detail", in: app).exists)
        XCTAssertTrue(app.buttons["重新运行诊断"].exists)
    }

    func testModelDownloadRequiresExplicitConfirmation() {
        let app = launchSpeechRail()
        openControlCenter(in: app)
        app.buttons["模型"].clickWhenReady()

        let downloadButton = app.buttons["下载并校验"]
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 20))
        downloadButton.clickWhenReady()

        let dialog = app.sheets.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 20))
        dialog.buttons["取消"].clickWhenReady()
    }

    func testMonitoringExplainsMissingMetrics() {
        let app = launchSpeechRail(arguments: ["--ui-test", "--ui-test-open-control-center", "--ui-test-metrics-unavailable"])
        openControlCenter(in: app)
        app.buttons["运行监控"].clickWhenReady()

        XCTAssertTrue(app.staticTexts["运行数据已过期"].waitForExistence(timeout: 5))
        XCTAssertEqual(identifierElement("workspace-title", in: app).label, "运行监控")
    }

    func testModelRecoveryRestoresInterruptedOperationAndRetryAction() {
        let app = launchSpeechRail(arguments: ["--ui-test", "--ui-test-open-control-center", "--ui-test-model-recovery"])
        openControlCenter(in: app)
        app.buttons["模型"].clickWhenReady()

        XCTAssertTrue(app.staticTexts["上次模型准备被中断"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["重新下载并校验"].exists)
        XCTAssertFalse(app.buttons["停止下载"].exists)
    }

    func testModelUnsupportedStateExplainsVersionMismatch() {
        let app = launchSpeechRail(
            arguments: ["--ui-test", "--ui-test-open-control-center", "--ui-test-model-unsupported"]
        )
        openControlCenter(in: app)
        app.buttons["模型"].clickWhenReady()

        XCTAssertTrue(app.staticTexts["模型管理暂不可用"].waitForExistence(timeout: 5))
        XCTAssertEqual(identifierElement("workspace-title", in: app).label, "模型管理")
        XCTAssertTrue(app.buttons["打开诊断"].exists)
    }

    func testSettingsContainAppPreferencesOnly() {
        let app = launchSpeechRail(arguments: ["--ui-test", "--ui-test-open-settings"])
        let statusItem = app.menuBars.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()

        XCTAssertTrue(app.menuItems["打开管理控制台"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["关于 SpeechRail"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["最低系统"].exists)
        XCTAssertFalse(app.staticTexts["服务状态"].exists)
    }

    func testVoiceDesignAcousticChipsAndCandidateRack() {
        let app = launchSpeechRail()
        openControlCenter(in: app)
        app.buttons["音色创作"].clickWhenReady()

        XCTAssertTrue(app.staticTexts["从一句话开始"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["快速加入声学特征"].exists)
        XCTAssertTrue(app.buttons["插入声学特征：磁性胸腔"].exists)
        app.buttons["插入声学特征：磁性胸腔"].clickWhenReady()

        XCTAssertTrue(app.staticTexts["候选试听"].exists)
        let generateButton = app.buttons["根据当前描述生成 4 组候选音色"]
        XCTAssertTrue(generateButton.waitForExistence(timeout: 20))
        generateButton.clickWhenReady()
        let playButton = app.buttons["A 槽位试听：播放"]
        XCTAssertTrue(playButton.waitForExistence(timeout: 20))
        playButton.clickWhenReady()
        XCTAssertTrue(app.buttons["A 槽位试听：暂停"].waitForExistence(timeout: 20))
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
        app.buttons["音色库"].clickWhenReady()

        XCTAssertTrue(app.staticTexts["系统音色与创作资产"].waitForExistence(timeout: 5))
        let previewButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "试听")
        ).firstMatch
        XCTAssertTrue(previewButton.waitForExistence(timeout: 5))
        let cancelControl = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "取消试听")
        ).firstMatch

        previewButton.clickWhenReady()
        XCTAssertTrue(cancelControl.waitForExistence(timeout: 10))
        cancelControl.clickWhenReady()
        XCTAssertTrue(previewButton.waitForExistence(timeout: 10))
    }

    func testWorksViewExposesSelectionAndExportActions() {
        let app = launchSpeechRail()
        openControlCenter(in: app)
        app.buttons["我的作品"].clickWhenReady()

        XCTAssertTrue(app.staticTexts["回看 SpeechRail 创作的作品"].waitForExistence(timeout: 10))
        let workRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "选择作品：")).firstMatch
        XCTAssertTrue(workRow.waitForExistence(timeout: 20))

        let window = app.windows["SpeechRail 管理控制台"]
        let actionMenu = window.menuButtons["更多操作"].firstMatch
        XCTAssertTrue(actionMenu.waitForExistence(timeout: 10))
        actionMenu.clickWhenReady()
        XCTAssertTrue(app.menuItems["导出选中作品"].waitForExistence(timeout: 10))
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
        let controlCenter = app.windows["SpeechRail 管理控制台"]
        XCTAssertTrue(controlCenter.waitForExistence(timeout: 10))
        app.activate()
        XCTAssertTrue(controlCenter.waitForExistence(timeout: 5))
    }

    private func identifierElement(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }



}

private extension XCUIElement {
    /// macOS SwiftUI hosts list rows and toolbar menus in AppKit containers, so
    /// XCUITest finds the control but reports it as not hittable; a synthesized
    /// center click still drives it. Waiting for `isEnabled` matters because the
    /// panes gate their primary actions on asynchronously loaded state, and a
    /// click on a disabled control is silently dropped. Probing `isHittable` is
    /// avoided on purpose: on the CI runner that single query spends ~14s in
    /// hit-point retries, which outlives short-lived states such as an in-flight
    /// voice preview.
    func clickWhenReady(timeout: TimeInterval = 20) {
        XCTAssertTrue(waitForExistence(timeout: timeout))
        let deadline = Date().addingTimeInterval(timeout)
        while !isEnabled, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(isEnabled)
        coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }
}
