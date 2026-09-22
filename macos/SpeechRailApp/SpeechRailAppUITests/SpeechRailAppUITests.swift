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
        app.buttons["overview"].clickWhenReady()
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

    func testAllNavigationRoutesAreDiscoverable() {
        let app = launchSpeechRail()
        openControlCenter(in: app)

        let routeTitles = [
            "配音台", "音色创作", "音色克隆", "音色库", "我的作品",
            "语音助手", "会议助手", "实时字幕", "AI 提词器",
            "服务状态", "运行监控", "模型", "诊断", "开发者文档"
        ]

        for title in routeTitles {
            XCTAssertTrue(
                app.buttons[title].waitForExistence(timeout: 5),
                "missing route: \(title)"
            )
        }
    }

    func testControlCenterHonorsRequestedWindowSizes() {
        // The matrix uses nominal outer-window requests. macOS titlebar space
        // raises the 720pt workspace floor to a 760pt NSWindow frame; the
        // largest request is capped by the screen's visible frame.
        let sizes = [
            (1120, 720, 1120, 760),
            (1280, 800, 1280, 800),
            (1440, 900, 1440, 900),
            (1920, 1080, 0, 0),
        ]
        let representativeRoutes = [
            ("语音助手", "开麦对讲"),
            ("会议助手", "开始会议"),
            ("实时字幕", "开始字幕"),
            ("AI 提词器", "新建空白稿"),
            ("模型", "下载并校验"),
            ("诊断", "查看检查明细"),
        ]

        for (requestedWidth, requestedHeight, expectedWidth, expectedHeight) in sizes {
            let app = launchSpeechRail(
                arguments: [
                    "--ui-test",
                    "--ui-test-open-control-center",
                    "--ui-test-responsive-layout",
                ],
                windowSize: CGSize(width: requestedWidth, height: requestedHeight)
            )
            openControlCenter(in: app)

            let window = app.windows["SpeechRail 管理控制台"]
            if expectedWidth == 0 {
                XCTAssertLessThanOrEqual(window.frame.width, CGFloat(requestedWidth))
                XCTAssertGreaterThan(window.frame.width, CGFloat(requestedWidth - 300))
            } else {
                XCTAssertEqual(window.frame.width, CGFloat(expectedWidth), accuracy: 2)
            }
            if expectedHeight == 0 {
                XCTAssertLessThanOrEqual(window.frame.height, CGFloat(requestedHeight))
                XCTAssertGreaterThanOrEqual(window.frame.height, CGFloat(requestedHeight - 100))
            } else {
                XCTAssertEqual(window.frame.height, CGFloat(expectedHeight), accuracy: 2)
            }
            let frameAttachment = XCTAttachment(
                string: "requested=\(requestedWidth)×\(requestedHeight), actual=\(window.frame)"
            )
            frameAttachment.name = "Window frame \(requestedWidth)×\(requestedHeight)"
            XCTContext.runActivity(named: "Measured window frame") { activity in
                activity.add(frameAttachment)
            }

            let sidebarToggle = window.buttons.matching(
                NSPredicate(format: "label CONTAINS %@", "Sidebar")
            ).firstMatch
            XCTAssertTrue(sidebarToggle.waitForExistence(timeout: 5))
            let originalSidebarLabel = sidebarToggle.label
            sidebarToggle.clickWhenReady()
            let toggledSidebar = window.buttons.matching(
                NSPredicate(
                    format: "label CONTAINS %@ AND label != %@",
                    "Sidebar",
                    originalSidebarLabel
                )
            ).firstMatch
            XCTAssertTrue(toggledSidebar.waitForExistence(timeout: 5))
            toggledSidebar.clickWhenReady()
            XCTAssertTrue(window.buttons[originalSidebarLabel].waitForExistence(timeout: 5))

            // Re-open the sidebar only when the responsive policy collapsed it,
            // so each representative route is reached through normal navigation.
            if sidebarToggle.label.localizedCaseInsensitiveContains("show") {
                sidebarToggle.clickWhenReady()
            }
            XCTAssertTrue(app.buttons["语音助手"].waitForExistence(timeout: 5))
            app.buttons["语音助手"].clickWhenReady()

            let panelToggle = identifierElement("session-panel-toggle", in: app)
            XCTAssertTrue(panelToggle.waitForExistence(timeout: 5))
            let originalPanelValue = panelToggle.value as? String
            XCTAssertTrue(originalPanelValue == "已展开" || originalPanelValue == "已收起")
            panelToggle.clickWhenReady()
            let changedPanelValue = originalPanelValue == "已展开" ? "已收起" : "已展开"
            let panelValueExpectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", changedPanelValue),
                object: panelToggle
            )
            XCTAssertEqual(XCTWaiter.wait(for: [panelValueExpectation], timeout: 5), .completed)
            panelToggle.clickWhenReady()
            let restoredPanelExpectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", originalPanelValue ?? ""),
                object: panelToggle
            )
            XCTAssertEqual(XCTWaiter.wait(for: [restoredPanelExpectation], timeout: 5), .completed)

            for (routeTitle, primaryAction) in representativeRoutes {
                let routeButton = app.buttons[routeTitle]
                XCTAssertTrue(routeButton.waitForExistence(timeout: 10), "missing route: \(routeTitle)")
                routeButton.clickWhenReady()

                let title = identifierElement("workspace-title", in: app)
                XCTAssertTrue(title.waitForExistence(timeout: 5))
                XCTAssertEqual(title.label, routeTitle)

                let action = app.buttons[primaryAction]
                XCTAssertTrue(
                    action.waitForExistence(timeout: 10),
                    "missing primary action on \(routeTitle): \(primaryAction)"
                )
                XCTAssertTrue(
                    window.frame.insetBy(dx: -2, dy: -2).contains(action.frame),
                    "primary action on \(routeTitle) is outside the window: \(action.frame)"
                )
            }
            app.terminate()
        }
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
        app.buttons["overview"].clickWhenReady()
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
        let app = launchSpeechRail(windowSize: CGSize(width: 1280, height: 960))
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
        // Dismiss the status-item menu before interacting with the separate
        // Settings window; the first click outside an open menu only dismisses it.
        app.typeKey(.escape, modifierFlags: [])
        // 设置窗口现在是面向普通用户的「通用 / 创作 / 助手 / 服务」四个页签。
        XCTAssertTrue(settingsTab("通用", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(settingsTab("创作", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(settingsTab("助手", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(settingsTab("服务", in: app).waitForExistence(timeout: 5))
        // Settings remembers the last selected tab across launches. Select the
        // page under test instead of relying on the app's first-run default.
        settingsTab("通用", in: app).clickWhenReady()
        XCTAssertFalse(app.staticTexts["会话"].exists)
        // 「通用」只放 App 自己的偏好（「启动与窗口」「开发者」两节）；
        // 「产品定位 / 最低系统 / 版本」已经搬进「服务」页签（§7.10）。
        XCTAssertTrue(app.staticTexts["启动与窗口"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["服务状态"].exists)
    }

    func testVoiceDesignAcousticChipsAndCandidateRack() throws {
        let app = launchSpeechRail(windowSize: CGSize(width: 1280, height: 960))
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

    func testWorksEmptyFixtureOffersSafeNavigationWithoutStoredWorks() {
        let app = launchSpeechRail(arguments: [
            "--ui-test", "--ui-test-open-control-center", "--ui-test-empty-works"
        ])
        openControlCenter(in: app)
        app.buttons["我的作品"].clickWhenReady()
        XCTAssertTrue(app.staticTexts["还没有作品"].waitForExistence(timeout: 10))
        XCTAssertFalse(identifierElement("work-row", in: app).exists)
        app.buttons["去配音台"].clickWhenReady()
        let title = identifierElement("workspace-title", in: app)
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let navigated = NSPredicate(format: "label == %@", "配音台")
        expectation(for: navigated, evaluatedWith: title)
        waitForExpectations(timeout: 10)
        app.buttons["我的作品"].clickWhenReady()
        XCTAssertTrue(app.staticTexts["还没有作品"].waitForExistence(timeout: 10))
        XCTAssertFalse(identifierElement("work-row", in: app).exists)
    }

    func testWorksViewExposesSelectionAndExportActions() throws {
        let app = launchSpeechRail(windowSize: CGSize(width: 1280, height: 960))
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
            NSPredicate(format: "title BEGINSWITH %@", "更多操作：")
        ).firstMatch
        XCTAssertTrue(rowActions.waitForExistence(timeout: 10))
        XCTAssertTrue(window.buttons["导出 测试作品"].exists)
        XCTAssertTrue(window.buttons["导出…"].exists)

        let selectedWorkExportCommand = app.menuItems.matching(
            NSPredicate(format: "title BEGINSWITH %@", "导出“测试作品”")
        ).firstMatch
        XCTAssertTrue(selectedWorkExportCommand.waitForExistence(timeout: 10))
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

    private func launchSpeechRail(
        arguments: [String] = ["--ui-test", "--ui-test-open-control-center"],
        windowSize: CGSize? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        if let windowSize {
            app.launchArguments.append(
                "--ui-test-window-size=\(Int(windowSize.width))x\(Int(windowSize.height))"
            )
        }
        app.launch()
        app.activate()
        return app
    }

    private func openControlCenter(in app: XCUIApplication) {
        // SpeechRail is a menu-bar-first app. Launching/activating it does not
        // guarantee that SwiftUI restores the single-window scene, so use the
        // same visible entry point as a user instead of assuming it auto-opens.
        let statusItem = app.menuBars.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()
        app.menuItems["打开 SpeechRail"].clickWhenReady()

        let controlCenter = app.windows["SpeechRail 管理控制台"]
        XCTAssertTrue(controlCenter.waitForExistence(timeout: 10))
        app.activate()
        XCTAssertTrue(controlCenter.waitForExistence(timeout: 5))
    }

    private func identifierElement(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Native macOS `Tab` exposes the selected label as a text descendant and
    /// unselected labels as button descendants. Keep the assertion about the
    /// user-visible tab name, not the platform-specific AX element type.
    private func settingsTab(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", title)
        ).firstMatch
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
