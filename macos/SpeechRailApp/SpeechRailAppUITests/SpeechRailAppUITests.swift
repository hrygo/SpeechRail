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
        // 2026-09-19：落地页从「服务状态」改成「语音助手」，所以这一页要自己走过去。
        app.buttons["服务状态"].clickWhenReady()
        // 2026-09-19：这一行的文案从「本地控制通道已就绪」改成「可以在这里管理服务」——
        // 首屏要说的是"能不能在这里管服务"，不是"哪条通道起来了"（SESSIONS-SPEC §12.1.8.1）。
        XCTAssertTrue(app.staticTexts["可以在这里管理服务"].exists)

        app.buttons["音色创作"].clickWhenReady()
        let workspaceTitle = app.descendants(matching: .any)["workspace-title"]
        XCTAssertTrue(workspaceTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(
            workspaceTitle.label.contains("音色创作"),
            "workspace-title label was: \(workspaceTitle.label)"
        )
        // 头部契约（REDESIGN-SPEC §6.2 / §11.6 第四十九轮）：页面身份只在工具栏，
        // 创作页没有「更多操作」这类通用动作容器；重新读取走 View ▸ ⌘R
        // （由页面声明的 `reloadPageCommand` 提供，菜单栏断言容易受系统语言影响，
        // 这里只钉住「头部不再有通用菜单」这一条）。
        XCTAssertFalse(app.menuButtons["更多操作"].exists)

        app.buttons["模型"].clickWhenReady()
        let modelsTitle = app.descendants(matching: .any)["workspace-title"]
        XCTAssertTrue(modelsTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(
            modelsTitle.label.contains("模型"),
            "workspace-title label was: \(modelsTitle.label)"
        )
    }

    func testControlSurfaceShowsServiceAndProfiles() {
        let app = launchSpeechRail()
        openControlCenter(in: app)

        // REDESIGN-SPEC §6.1 / §11.6 第四十九轮：侧边栏是「创作」「引擎」两组，
        // 服务那条线整体改名为「引擎」（`AppRouteGroup.service.title`）。
        XCTAssertTrue(app.staticTexts["创作"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["引擎"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["服务状态"].exists)
        XCTAssertTrue(app.buttons["模型"].exists)
        // 2026-09-19：落地页改成「语音助手」；这一页的断言要先自己切过来
        // （SESSIONS-SPEC §13 D15）。
        app.buttons["服务状态"].clickWhenReady()
        // 页首那一句话取自 `AppRoute.overview.pageSubtitle`，与稿逐字一致；
        // 旧文案「确认本机语音服务能否使用」只留在 `purpose`（侧栏行的帮助值）。
        XCTAssertTrue(
            app.staticTexts["本机语音引擎的当前结论与运行事实。"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["能力"].exists)
        XCTAssertTrue(app.staticTexts["运行信息"].exists)
        // REDESIGN-SPEC §7.5：服务状态页只有「结论 + 能力 + 运行信息」。
        XCTAssertFalse(app.staticTexts["预检"].exists)

        app.buttons["模型"].clickWhenReady()
        XCTAssertEqual(identifierElement("workspace-title", in: app).label, "模型")
    }

    func testDiagnosticsUsesCompactSummaryAndSelectedDetail() {
        let app = launchSpeechRail()
        openControlCenter(in: app)
        app.buttons["诊断"].clickWhenReady()

        // REDESIGN-SPEC §7.8 / §11.6 第六十四轮：预检全通过时整页先退化成
        // 「未发现问题」结论面板，两栏清单（结论 + 清单 + 详情）由主动作展开，
        // 展开可逆（清单头留「只看结论」）。UI 测试的 fixture 只有一项且通过，
        // 所以这里走的就是用户真实路径，而不是绕开结论直接断言清单。
        let expandCheckList = app.buttons["查看检查明细"]
        XCTAssertTrue(expandCheckList.waitForExistence(timeout: 20))
        expandCheckList.clickWhenReady()

        XCTAssertTrue(identifierElement("diagnostics-summary", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(identifierElement("diagnostics-check-list", in: app).exists)
        XCTAssertTrue(identifierElement("diagnostics-check-detail", in: app).exists)
        XCTAssertTrue(identifierElement("diagnostics-run", in: app).exists)
    }

    func testModelDownloadRequiresExplicitConfirmation() throws {
        let app = launchSpeechRail()
        openControlCenter(in: app)
        app.buttons["模型"].clickWhenReady()

        let downloadButton = app.buttons["下载并校验"]
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 20))
        try skipUnlessWorkspacePaneFits(app)
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
        XCTAssertEqual(identifierElement("workspace-title", in: app).label, "模型")
        XCTAssertTrue(app.buttons["打开诊断"].exists)
    }

    func testSettingsContainAppPreferencesOnly() {
        let app = launchSpeechRail(arguments: ["--ui-test", "--ui-test-open-settings"])
        let statusItem = app.menuBars.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()

        // 菜单项与 REDESIGN-SPEC §7.9 一致：`打开 SpeechRail`（⌘O）。
        XCTAssertTrue(app.menuItems["打开 SpeechRail"].waitForExistence(timeout: 5))
        // 设置窗口在重设计后是「通用 / 创作 / 服务」三个页签，不再有「关于 SpeechRail」。
        XCTAssertTrue(app.staticTexts["通用"].waitForExistence(timeout: 5))
        // 默认页签是「通用」，它只放 App 自己的偏好（「启动与窗口」「开发者」两节）；
        // 「产品定位 / 最低系统 / 版本」已经搬进未选中的「服务」页签（§7.10），
        // 所以这里断言通用页签自己的小节，而不是那一页的内容。
        XCTAssertTrue(app.staticTexts["启动与窗口"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["服务状态"].exists)
    }

    func testVoiceDesignAcousticChipsAndCandidateRack() throws {
        let app = launchSpeechRail()
        openControlCenter(in: app)
        app.buttons["音色创作"].clickWhenReady()

        // 页头副行取自 AppRoute.voiceDesign.pageSubtitle，与稿逐字一致。
        XCTAssertTrue(
            app.staticTexts["用一句话描述你想要的音色，从真实预览里挑一个保存进音色库。"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["快速加入声学特征"].exists)
        XCTAssertTrue(app.buttons["插入声学特征：磁性胸腔"].exists)
        app.buttons["插入声学特征：磁性胸腔"].clickWhenReady()

        XCTAssertTrue(app.staticTexts["候选试听"].exists)
        let generateButton = app.buttons["根据当前描述生成 4 组候选音色"]
        XCTAssertTrue(generateButton.waitForExistence(timeout: 20))
        try skipUnlessWorkspacePaneFits(app)
        generateButton.clickWhenReady()
        // 候选槽位是 "1"…"4"，按钮标签由卡片给出（VoiceCandidateCard）。
        let playButton = app.buttons["候选 1 试听：播放"]
        XCTAssertTrue(playButton.waitForExistence(timeout: 20))
        playButton.clickWhenReady()
        XCTAssertTrue(app.buttons["候选 1 试听：停止"].waitForExistence(timeout: 20))
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

        XCTAssertTrue(
            app.staticTexts["管理系统音色，以及用参考音频复刻出来的音色。"]
                .waitForExistence(timeout: 5)
        )
        let previewButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "试听")
        ).firstMatch
        XCTAssertTrue(previewButton.waitForExistence(timeout: 5))
        // 行进中试听时，行内按钮的标签是「取消 <音色名> 的试听」。
        let cancelControl = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "取消")
        ).firstMatch

        previewButton.clickWhenReady()
        XCTAssertTrue(cancelControl.waitForExistence(timeout: 10))
        cancelControl.clickWhenReady()
        XCTAssertTrue(previewButton.waitForExistence(timeout: 10))
    }

    func testWorksViewExposesSelectionAndExportActions() throws {
        let app = launchSpeechRail()
        openControlCenter(in: app)
        app.buttons["我的作品"].clickWhenReady()

        XCTAssertTrue(
            app.staticTexts["本机生成过的音频都留在这里，可随时播放、导出或删除。"]
                .waitForExistence(timeout: 10)
        )
        try skipUnlessWorkspacePaneFits(app)

        let workRow = app.descendants(matching: .any)
            .matching(identifier: "work-row")
            .firstMatch
        XCTAssertTrue(workRow.waitForExistence(timeout: 20))
        workRow.clickWhenReady()

        let window = app.windows["SpeechRail 管理控制台"]
        // 头部不再重复「只对选中行生效」的那批命令；作品的动作挂在行上
        // （行内「⋯」+ 右键菜单），导出另有 ⌘E（REDESIGN-SPEC §6.2 / §6.4）。
        XCTAssertFalse(window.menuButtons["更多操作"].exists)
        let rowActions = window.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "更多操作：")
        ).firstMatch
        XCTAssertTrue(rowActions.waitForExistence(timeout: 10))
        rowActions.clickWhenReady()
        XCTAssertTrue(app.menuItems["导出…"].waitForExistence(timeout: 10))
        app.typeKey(.escape, modifierFlags: [])
    }

    func testHeaderKeepsOneCreateEntryPointOnTheVoiceLibrary() {
        let app = launchSpeechRail()
        openControlCenter(in: app)
        app.buttons["音色库"].clickWhenReady()

        XCTAssertTrue(identifierElement("workspace-title", in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(identifierElement("workspace-title", in: app).label, "音色库")
        // 「新建音色」在整页只有一处入口：页脚的重复按钮已去掉（§6.4 唯一性）。
        let createEntries = app.buttons.matching(
            NSPredicate(format: "label == %@", "新建音色")
        )
        XCTAssertEqual(createEntries.count, 1, "新建音色 应只有工具栏一处入口")
        XCTAssertFalse(app.menuButtons["更多操作"].exists)
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

    /// A workspace pane needs roughly 900pt of window height. The CI runner only
    /// exposes a 1024x768 display, so the lower controls and rows of a pane stay
    /// below the fold there, and macOS has no XCUITest scroll API
    /// (`scrollByDeltaX:deltaY:` is iOS/macCatalyst only). Checks that need the
    /// whole pane visible therefore run only on a window tall enough to show it;
    /// the assertions above each skip still execute.
    private func skipUnlessWorkspacePaneFits(_ app: XCUIApplication) throws {
        let height = app.windows["SpeechRail 管理控制台"].frame.height
        try XCTSkipUnless(
            height >= 900,
            "window is \(Int(height))pt tall; a workspace pane needs about 900pt"
        )
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
