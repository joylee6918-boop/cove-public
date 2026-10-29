import XCTest

@MainActor
final class CoveHomeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testHomeLifeDashboardIsVisibleAndHonestInPreview() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--tab", "0"]
        app.launch()

        let calendar = app.buttons["home.life.calendar"]
        for _ in 0..<8 where !(calendar.exists && calendar.isHittable) {
            app.swipeUp(velocity: .slow)
        }

        XCTAssertTrue(calendar.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home.life.reminders"].exists)
        XCTAssertTrue(app.buttons["home.life.alarms"].exists)
        XCTAssertTrue(app.staticTexts["日历与提醒留在本机 · 闹钟仅显示 Cove 创建的"].exists)

        let activity = app.buttons["home.appActivity"]
        for _ in 0..<6 where !(activity.exists && activity.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(activity.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["来自 Cove 快捷指令，不是系统屏幕使用时间。"].exists)

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "home-life-dashboard-preview"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testPearlLivingShelfOpensFitnessAndPersonalLedgerInIsolatedPreview() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--tab", "0"]
        app.launch()

        let fitness = app.buttons["home.fitness"]
        let ledger = app.buttons["home.personalLedger"]
        for _ in 0..<12 where !(fitness.exists && fitness.isHittable && ledger.exists && ledger.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(fitness.waitForExistence(timeout: 5))
        XCTAssertTrue(ledger.waitForExistence(timeout: 5))

        fitness.tap()
        XCTAssertTrue(app.navigationBars["健身"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["开始 / 补记活动"].exists)
        XCTAssertTrue(app.staticTexts["预览 · 示例空间，不写入本机记录"].exists)
        attachScreenshot(app, name: "pearl-fitness-empty-preview")
        app.buttons["关闭"].tap()

        XCTAssertTrue(ledger.waitForExistence(timeout: 5))
        ledger.tap()
        XCTAssertTrue(app.navigationBars["账本"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["ledger.add"].exists)
        XCTAssertTrue(app.staticTexts["示例预览 · 所有操作仅保留在内存"].exists)
        attachScreenshot(app, name: "pearl-ledger-empty-preview")
        app.buttons["ledger.add"].tap()
        XCTAssertTrue(app.textFields["ledger.amount"].waitForExistence(timeout: 3))
        attachScreenshot(app, name: "pearl-ledger-entry-preview")
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testAppActivityExplainsIndependentPreview() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--tab", "3"]
        app.launch()
        let heading = app.staticTexts["App 使用 · Cove 独立记录"]
        let explanation = app.staticTexts["示例预览不会读取 App 使用记录。"]
        for _ in 0..<6 {
            if explanation.exists && explanation.isHittable && explanation.frame.maxY < app.frame.maxY - 160 { break }
            app.swipeUp()
        }
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        XCTAssertTrue(explanation.exists)
        XCTAssertFalse(app.buttons["appActivity.refresh"].isEnabled)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "cove-independent-app-activity-preview"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testAnniversaryAndMemoryCalendarAreExplicitLocalPreview() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--tab", "0"]
        app.launch()
        XCTAssertTrue(app.staticTexts["home.togetherDays"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["2026.08.20 · 表明心意的那一天"].exists)
        XCTAssertTrue(app.staticTexts["示例日历 · 合成数据，不连接 OB"].exists)
        let month = app.staticTexts["home.memory.month"]
        XCTAssertTrue(month.exists)
        let initial = month.label
        let previous = app.buttons["home.memory.previous"]
        XCTAssertGreaterThanOrEqual(previous.frame.width, 44)
        XCTAssertGreaterThanOrEqual(previous.frame.height, 44)
        previous.tap()
        XCTAssertNotEqual(month.label, initial)
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.memory.day.")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        expectation(for: NSPredicate(format: "enabled == true AND hittable == true"), evaluatedWith: first)
        waitForExpectations(timeout: 5)
        XCTAssertGreaterThanOrEqual(first.frame.width, 44)
        XCTAssertGreaterThanOrEqual(first.frame.height, 44)
        first.tap()
        XCTAssertTrue(app.staticTexts["home.memory.selection"].waitForExistence(timeout: 3))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["home.memory.selection"].waitForExistence(timeout: 3))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "home-memory-calendar-local-fixture"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testHealthPageHidesRecordDetailsAndSeparatesDeletionScopes() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--health-history-qa", "--tab", "3"]
        app.launch()
        let explanation = app.staticTexts["health.storageExplanation"]
        for _ in 0..<7 {
            if explanation.exists && explanation.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(explanation.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["留在本机的健康记录"].exists)
        XCTAssertFalse(app.staticTexts["合成示例 · 未读取真实健康数据"].exists)
        XCTAssertTrue(app.buttons["清除本机健康历史"].exists)
        XCTAssertTrue(app.buttons["删除服务器已分享的健康数据"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "health-controls-without-history"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertFalse(app.buttons["清除本机健康历史"].isEnabled)
    }
}
