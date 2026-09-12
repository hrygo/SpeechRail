import XCTest

final class SpeechRailAppUITests: XCTestCase {
    func testControlSurfaceShowsServiceAndProfiles() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test"]
        app.launch()

        XCTAssertTrue(app.staticTexts["SpeechRail"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["启动"].exists || app.buttons["启动服务"].exists)
        XCTAssertTrue(app.staticTexts["模型档位"].exists)
    }
}
