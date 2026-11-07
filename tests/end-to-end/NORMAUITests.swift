import XCTest
final class NORMAUITests: XCTestCase {
    @MainActor func testNavigationAndTheme() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let toggle = app.buttons["theme.toggle"]
        XCTAssertTrue(toggle.exists)
        let before = app.windows.firstMatch.frame
        toggle.click(); toggle.click()
        XCTAssertEqual(app.windows.firstMatch.frame, before)
        app.buttons["nav.workspace"].click()
        app.buttons["inspector.toggle"].click()
        app.buttons["inspector.toggle"].click()
        app.terminate()
    }
}
