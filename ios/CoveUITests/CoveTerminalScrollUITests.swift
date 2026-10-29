import XCTest

@MainActor
final class CoveTerminalScrollUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--preview", "--terminal-scroll-qa"]
        app.launch()
        let open = app.buttons["chat.terminal"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        XCTAssertTrue(app.buttons["terminal.qa.append"].waitForExistence(timeout: 5))
    }

    private func assertTailVisible(file: StaticString = #filePath, line: UInt = #line) {
        let tail = app.staticTexts["terminal.qa.tail"]
        let log = app.scrollViews["terminal.log"]
        let visible = NSPredicate { _, _ in
            tail.exists && log.exists && tail.frame.minY >= log.frame.minY - 2
                && tail.frame.maxY <= log.frame.maxY + 2 && tail.isHittable
        }
        let wait = XCTNSPredicateExpectation(predicate: visible, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 5), .completed, file: file, line: line)
    }

    func testNewEventsGrowingSameEventAndKeyboardKeepLatestVisible() {
        assertTailVisible()
        app.buttons["terminal.qa.append"].tap()
        XCTAssertEqual(app.staticTexts["terminal.qa.tail"].label, "本地日志末尾 121")
        assertTailVisible()
        app.buttons["terminal.qa.grow"].tap()
        XCTAssertEqual(app.staticTexts["terminal.qa.tail"].label, "本地日志末尾 121")
        assertTailVisible()
        app.textFields["terminal.input"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        assertTailVisible()
        let keyboard = app.buttons["terminal.shortcut.keyboard"]
        if !keyboard.isHittable { app.scrollViews["terminal.shortcuts"].swipeLeft() }
        keyboard.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 5)
        assertTailVisible()
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "terminal-auto-follow-local-fixture"; attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testReadingHistoryPausesUntilReturnToLatestThenAutoFollowsAgain() {
        assertTailVisible()
        app.scrollViews["terminal.log"].swipeDown()
        let latest = app.buttons["terminal.latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 3))
        app.buttons["terminal.qa.append"].tap()
        XCTAssertTrue(latest.exists)
        XCTAssertTrue(latest.label.contains("1 条新日志"))
        XCTAssertFalse(app.staticTexts["terminal.qa.tail"].isHittable)
        latest.tap()
        assertTailVisible()
        XCTAssertFalse(latest.exists)
        app.buttons["terminal.qa.append"].tap()
        assertTailVisible()
        XCTAssertEqual(app.staticTexts["terminal.qa.tail"].label, "本地日志末尾 122")
    }
}
