import XCTest

@MainActor
final class CoveLaunchHugUITests: XCTestCase {
    private func app() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--rich-preview", "--launch-hug-preview"]
        return app
    }

    func testColdLaunchOverlayLeavesRootInteractive() {
        let app = app()
        app.launch()
        let overlay = app.otherElements["launchHug.overlay"]
        _ = overlay.waitForExistence(timeout: 1)
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 4))
        XCTAssertTrue(app.scrollViews["chat.history"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.textFields["chat.input"].isHittable)
    }

    func testBackgroundReturnDoesNotReplayOverlay() {
        let app = app()
        app.launch()
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.otherElements["launchHug.overlay"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.scrollViews["chat.history"].waitForExistence(timeout: 3))
    }
}
