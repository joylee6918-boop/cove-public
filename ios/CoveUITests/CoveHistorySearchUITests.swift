import XCTest

final class CoveHistorySearchUITests: XCTestCase {
    func testFarHistoryResultMaterializesThenCanReturnToLatest() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--stress", "--chat-send-qa"]
        app.launch()
        XCTAssertTrue(app.buttons["chat.search"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.otherElements["chat.bubble.stress-100"].exists)
        app.buttons["chat.search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("历史示例 101\n")
        app.swipeUp()
        let result = app.buttons["chat.search.result.stress-100"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()
        let target = app.otherElements["chat.bubble.stress-100"]
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        XCTAssertTrue(target.isHittable)
        XCTAssertTrue(app.buttons["chat.search.clearHighlight"].isHittable)
        let latest = app.buttons["chat.returnFromSearch"]
        XCTAssertTrue(latest.isHittable)
        latest.tap()
        XCTAssertTrue(app.otherElements["chat.bubble.stress-599"].isHittable)
        let input = app.textFields["chat.input"]
        input.tap(); input.typeText("After search")
        app.buttons["chat.send"].tap()
        let reply = app.staticTexts["本地模拟回复：After search"]
        XCTAssertTrue(reply.waitForExistence(timeout: 3))
        XCTAssertTrue(reply.isHittable)
    }

    func testClearDateAndKeywordTogetherAndExitSearch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview"]
        app.launch()
        XCTAssertTrue(app.buttons["chat.search"].waitForExistence(timeout: 10))
        app.buttons["chat.search"].tap()
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        let key = formatter.string(from: Date().addingTimeInterval(-60))
        let day = app.buttons["chat.search.date." + key]
        XCTAssertTrue(day.waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: day)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        day.tap()
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("Cove\n")
        app.swipeUp()
        let clear = app.buttons["chat.search.query.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        XCTAssertFalse(app.buttons["chat.search.date.clear"].exists)
        XCTAssertFalse(app.buttons["chat.search.result.p4"].exists)
        XCTAssertFalse(clear.exists)
        let back = app.buttons["chat.search.returnToCurrent"]
        XCTAssertTrue(back.isHittable)
        back.tap()
        XCTAssertTrue(app.buttons["chat.search"].waitForExistence(timeout: 5))
        XCTAssertFalse(back.exists)
    }

    func testCalendarIsVisibleWithoutAQueryAndDateOpensHistory() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview"]
        app.launch()
        XCTAssertTrue(app.buttons["chat.search"].waitForExistence(timeout: 10))
        app.buttons["chat.search"].tap()
        XCTAssertTrue(app.buttons["chat.search.month.previous"].waitForExistence(timeout: 10))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        let key = formatter.string(from: Date().addingTimeInterval(-60))
        let day = app.buttons["chat.search.date." + key]
        XCTAssertTrue(day.waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: day)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        day.tap()
        XCTAssertTrue(app.buttons["chat.search.date.clear"].waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertTrue(app.buttons["chat.search.result.p4"].waitForExistence(timeout: 5))
    }

    func testKeywordResultLocatesOriginalAndCanClearHighlight() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview"]
        app.launch()
        XCTAssertTrue(app.buttons["chat.search"].waitForExistence(timeout: 10))
        app.buttons["chat.search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Cove\n")
        app.swipeUp()
        let result = app.buttons["chat.search.result.p4"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()
        let clear = app.buttons["chat.search.clearHighlight"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        XCTAssertFalse(clear.exists)
        XCTAssertTrue(app.buttons["chat.returnFromSearch"].exists, "Clearing highlight must not remove the escape route")
        app.buttons["chat.returnFromSearch"].tap()
        XCTAssertFalse(app.buttons["chat.returnFromSearch"].exists)
    }
}
