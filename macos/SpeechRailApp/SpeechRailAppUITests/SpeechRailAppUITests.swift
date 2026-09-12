import XCTest

@MainActor
final class SpeechRailAppUITests: XCTestCase {
    func testControlSurfaceShowsServiceAndProfiles() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test"]
        app.launch()
        app.activate()
        app.typeKey(",", modifierFlags: .command)

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
}
