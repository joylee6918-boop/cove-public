import XCTest

@MainActor final class CoveWidgetUITests: XCTestCase {
    func testLocalEditsStepsCancelAndExplicitSend() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--widget-preview", "--chat-send-qa"]
        app.launch()
        defer { let hierarchy = XCTAttachment(string: app.debugDescription); hierarchy.name = "widget-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy) }
        let history = app.scrollViews["chat.history"]
        XCTAssertTrue(history.waitForExistence(timeout: 12))
        let read = app.buttons["widget.choice.读书"]
        reveal(read, in: history, older: true)
        XCTAssertTrue(read.isHittable)
        read.tap()
        let input = app.textFields["chat.input"]
        input.tap(); input.typeText("draft stays")
        let next = app.buttons["widget.button.next"]
        reveal(next, in: history, older: false)
        next.tap()
        XCTAssertTrue(app.staticTexts["选择：读书；备注："].waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["我想读书 20 分钟。"].exists, "Local changes must not create chat messages")
        let send = app.buttons["widget.button.submit"]
        reveal(send, in: history, older: false)
        send.tap()
        XCTAssertTrue(app.staticTexts["widget.send.preview"].waitForExistence(timeout: 4))
        XCTAssertEqual(app.staticTexts["widget.send.preview"].label, "我想读书 20 分钟。")
        app.buttons["widget.send.cancel"].tap()
        XCTAssertFalse(app.staticTexts["widget.submitted"].exists)
        send.tap()
        app.buttons["widget.send.confirm"].tap()
        XCTAssertTrue(app.staticTexts["我想读书 20 分钟。"].waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "draft stays")
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "widget-local-sent"; image.lifetime = .keepAlways; add(image)
    }

    func testNativeControlsAndNoPrematureSend() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--widget-preview"]
        app.launch()
        let history = app.scrollViews["chat.history"]
        XCTAssertTrue(history.waitForExistence(timeout: 12))
        let slider = app.sliders["widget.slider.minutes"]
        reveal(slider, in: history, older: true)
        XCTAssertTrue(slider.exists)
        slider.adjust(toNormalizedSliderPosition: 0.7)
        let note = app.textFields["widget.input.note"]
        reveal(note, in: history, older: true)
        note.tap(); note.typeText("local note")
        XCTAssertEqual(note.value as? String, "local note")
        XCTAssertFalse(app.staticTexts["widget.submitted"].exists)
        XCTAssertFalse(app.buttons["widget.send.confirm"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "widget-native-controls"; shot.lifetime = .keepAlways; add(shot)
    }

    func testLargeTextDarkModeRemainsScrollableAndBounded() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--widget-preview", "-cove.appearance", "dark",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let history = app.scrollViews["chat.history"]
        XCTAssertTrue(history.waitForExistence(timeout: 12))
        let next = app.buttons["widget.button.next"]
        reveal(next, in: history, older: true)
        XCTAssertTrue(next.isHittable)
        XCTAssertLessThanOrEqual(next.frame.width, history.frame.width)
        XCTAssertGreaterThanOrEqual(next.frame.height, 44)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "widget-dark-accessibility"; shot.lifetime = .keepAlways; add(shot)
        next.tap()
        let send = app.buttons["widget.button.submit"]
        reveal(send, in: history, older: false)
        XCTAssertTrue(send.isHittable)
    }

    private func reveal(_ element: XCUIElement, in history: XCUIElement, older: Bool) {
        for _ in 0..<8 {
            if element.isHittable { return }
            let start = history.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: older ? 0.25 : 0.75))
            let end = history.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: older ? 0.75 : 0.25))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }
}
