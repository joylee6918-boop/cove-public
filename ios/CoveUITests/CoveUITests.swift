import XCTest

@MainActor
final class CoveUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--preview"]
        app.launch()
        XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 10), "Cold launch must open the center dialogue tab.")
        XCTAssertTrue(app.staticTexts["示例预览 · 数据不会上传"].exists)
    }

    func testFiveTabsAndHonestPreview() throws {
        let tabs: [(String, String, String)] = [
            ("tab.home", "家", "home"),
            ("tab.pulse", "心跳", "pulse"),
            ("tab.chat", "对话", "chat"),
            ("tab.health", "健康", "health"),
            ("tab.settings", "设置", "settings")
        ]
        XCTAssertEqual(app.otherElements["cove.tabBar"].buttons.count, 5)
        XCTAssertLessThanOrEqual(app.otherElements["cove.tabBar"].frame.width, 321)
        for button in app.otherElements["cove.tabBar"].buttons.allElementsBoundByIndex {
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
        for (identifier, label, filename) in tabs {
            try tapTab(identifier, label: label)
            switch identifier {
            case "tab.home":
                XCTAssertTrue(app.staticTexts["用户与 助手"].waitForExistence(timeout: 3))
                XCTAssertTrue(app.staticTexts["接着说"].exists)
            case "tab.pulse":
                XCTAssertTrue(app.staticTexts["最近一次心跳记录"].waitForExistence(timeout: 3))
                XCTAssertTrue(app.staticTexts["心里的倾向"].exists)
            case "tab.chat":
                XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 3))
                XCTAssertTrue(app.textFields["chat.input"].isHittable)
                XCTAssertLessThan(app.textFields["chat.input"].frame.maxY,
                                  app.otherElements["cove.tabBar"].frame.minY)
                XCTAssertFalse(app.buttons["chat.send"].isEnabled, "Preview must never send a real message.")
            case "tab.health":
                XCTAssertTrue(app.staticTexts["Apple 健康"].waitForExistence(timeout: 3))
                XCTAssertTrue(app.staticTexts["助手 已读取"].exists)
                XCTAssertTrue(app.staticTexts["尚未读取"].exists, "Sync must not claim the model read the snapshot.")
            default:
                XCTAssertTrue(app.textFields["settings.url"].waitForExistence(timeout: 3))
                XCTAssertTrue(app.secureTextFields["settings.token"].exists)
                XCTAssertFalse(app.buttons["settings.connect"].isEnabled)
            }
            attachScreenshot(filename)
            XCTAssertFalse(app.tabBars.firstMatch.isHittable, "The custom bar must be the only visible tab bar.")
        }
        attachHierarchy("five-tabs-hierarchy")
    }

    func testQuoteReplyComposerAndKeyboard() throws {
        let message = app.staticTexts["先看看设置页面。"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        // The selectable Markdown text has its own Copy/Share menu. Press the
        // bubble's visible padding to exercise the message actions explicitly.
        let bubble = app.otherElements["chat.bubble.p4"]
        XCTAssertTrue(bubble.isHittable)
        bubble.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 5, dy: 0)).press(forDuration: 1.1)
        let reply = app.buttons["引用回复"]
        XCTAssertTrue(reply.waitForExistence(timeout: 3), "Long pressing a message must expose quote reply.")
        reply.tap()
        XCTAssertTrue(app.staticTexts["回复 用户"].waitForExistence(timeout: 3))
        let input = app.textFields["chat.input"]
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        // XCTest's bulk Unicode injection can drop characters while the native
        // keyboard completes its focus/layout transition. Keep real keyboard
        // entry, and require every committed prefix before the next character.
        var prefix = ""
        for character in "引用预览测试" {
            input.typeText(String(character))
            prefix.append(character)
            let committed = NSPredicate(format: "value == %@", prefix)
            expectation(for: committed, evaluatedWith: input)
            waitForExpectations(timeout: 4)
        }
        XCTAssertEqual(input.value as? String, "引用预览测试")
        XCTAssertFalse(app.buttons["chat.send"].isEnabled, "Typing in preview must not enable network sending.")
        XCTAssertFalse(app.otherElements["cove.tabBar"].isHittable, "The keyboard should hide the tab bar.")
        attachScreenshot("quote-keyboard")

        let history = app.scrollViews["chat.history"]
        XCTAssertTrue(history.exists)
        history.swipeDown(velocity: .slow)
        if app.keyboards.firstMatch.exists { history.swipeDown(velocity: .slow) }
        let keyboardGone = NSPredicate(format: "exists == false")
        expectation(for: keyboardGone, evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 4)
        XCTAssertTrue(app.otherElements["cove.tabBar"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.otherElements["cove.tabBar"].isHittable)
        app.buttons["取消引用"].tap()
        XCTAssertFalse(app.staticTexts["回复 用户"].exists)
        XCTAssertEqual(input.value as? String, "引用预览测试", "Cancelling the quote must preserve the draft.")
        try tapTab("tab.home", label: "家")
        try tapTab("tab.chat", label: "对话")
        XCTAssertEqual(app.textFields["chat.input"].value as? String, "引用预览测试", "Switching tabs must preserve the draft.")
        attachScreenshot("quote-dismissed")
        attachHierarchy("quote-hierarchy")
    }

    func testStressHistoryScrollAndReturnToLatest() throws {
        try verifyStressHistory(markdown: false)
    }

    func testStressMarkdownHistoryScrollAndReturnToLatest() throws {
        try verifyStressHistory(markdown: true)
    }

    func testLatestMultilineMessageStaysAboveKeyboard() throws {
        app.terminate()
        app.launchArguments = ["--preview", "--stress-markdown"]
        app.launch()
        let history = app.scrollViews["chat.history"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        let latest = app.otherElements["chat.bubble.stress-599"].staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "历史示例 600")).firstMatch
        let timestamp = app.staticTexts["chat.timestamp.stress-599"]
        let input = app.textFields["chat.input"]
        XCTAssertTrue(latest.waitForExistence(timeout: 10))
        waitForLatestAboveComposer(latest, timestamp: timestamp, input: input)
        XCTAssertTrue(input.isHittable)
        XCTAssertLessThan(input.frame.maxY, app.otherElements["cove.tabBar"].frame.minY)
        let originalLabel = latest.label
        XCTAssertTrue(originalLabel.contains("This is rich history. Cove reference."))
        XCTAssertGreaterThan(latest.frame.height, input.frame.height,
                             "The last fixture must be a real multiline message, not a one-line placeholder.")
        let originalBottom = latest.frame.maxY
        attachScreenshot("latest-before-keyboard")

        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
        waitForLatestAboveComposer(latest, timestamp: timestamp, input: input)
        XCTAssertEqual(latest.label, originalLabel)
        XCTAssertLessThan(latest.frame.maxY, originalBottom - 80,
                          "The newest multiline message must actually move upward with the keyboard.")
        XCTAssertLessThanOrEqual(input.frame.maxY, app.keyboards.firstMatch.frame.minY)
        XCTAssertFalse(app.otherElements["cove.tabBar"].isHittable)
        let keyboardBottom = latest.frame.maxY
        attachScreenshot("latest-above-keyboard")

        // A tap in the wallpaper gutter dismisses the keyboard without a drag
        // toward older history, so this verifies the bottom-position case.
        history.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.3)).tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 5)
        waitForLatestAboveComposer(latest, timestamp: timestamp, input: input)
        XCTAssertEqual(latest.label, originalLabel)
        XCTAssertGreaterThan(latest.frame.maxY, keyboardBottom + 80,
                             "Closing the keyboard must return the latest message to the expanded viewport's bottom.")
        XCTAssertTrue(app.otherElements["cove.tabBar"].isHittable)
        XCTAssertFalse(app.buttons["chat.jumpToLatest"].exists && app.buttons["chat.jumpToLatest"].isHittable)
        attachScreenshot("latest-after-keyboard")
        attachHierarchy("latest-keyboard-hierarchy")
    }

    private func waitForLatestAboveComposer(_ latest: XCUIElement, timestamp: XCUIElement, input: XCUIElement) {
        let unobscured = NSPredicate { _, _ in
            latest.exists && timestamp.exists && latest.isHittable && timestamp.isHittable
                && latest.frame.maxY < input.frame.minY && timestamp.frame.maxY < input.frame.minY
        }
        expectation(for: unobscured, evaluatedWith: latest)
        waitForExpectations(timeout: 6)
        XCTAssertLessThan(latest.frame.maxY, input.frame.minY, "The entire latest body must remain above the composer.")
        XCTAssertLessThan(timestamp.frame.maxY, input.frame.minY, "The timestamp outside the bubble must also remain visible.")
    }

    private func verifyStressHistory(markdown: Bool) throws {
        app.terminate()
        app.launchArguments = ["--preview", markdown ? "--stress-markdown" : "--stress"]
        app.launch()
        let screenshotPrefix = markdown ? "stress-markdown" : "stress"
        defer {
            attachScreenshot("\(screenshotPrefix)-final-state")
            attachHierarchy("\(screenshotPrefix)-final-hierarchy")
        }
        let history = app.scrollViews["chat.history"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        // SwiftUI merges the Markdown container into the accessible bubble.
        // Query its actual paragraph, never the bubble's parent container.
        let newest: XCUIElement
        if markdown {
            newest = app.otherElements["chat.bubble.stress-599"].staticTexts
                .matching(NSPredicate(format: "label BEGINSWITH %@", "历史示例 600")).firstMatch
        } else {
            newest = app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@",
                                                          "chat.message.stress-599", "历史示例 600")).firstMatch
        }
        XCTAssertTrue(newest.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: newest)
        waitForExpectations(timeout: 8)
        XCTAssertTrue(newest.isHittable, "The 600-message preview must initially open at its newest message.")
        XCTAssertLessThan(newest.frame.maxY, app.textFields["chat.input"].frame.minY,
                          "The newest message body must be above the composer, not behind it.")
        XCTAssertTrue(newest.label.hasPrefix("历史示例 600"))
        if markdown {
            XCTAssertTrue(newest.label.contains("This is rich history."), "The newest row must expose rendered rich text, not only a container ID.")
            XCTAssertTrue(newest.label.contains("Cove reference"))
            XCTAssertFalse(newest.label.contains("**"))
        }
        let navigation = app.buttons["chat.conversations"]
        XCTAssertTrue(navigation.isHittable)
        XCTAssertGreaterThanOrEqual(navigation.frame.minY, app.staticTexts["示例预览 · 数据不会上传"].frame.maxY,
                                    "The preview banner must not cover the native navigation header.")
        attachScreenshot("\(screenshotPrefix)-latest")

        history.swipeDown(velocity: .slow)
        history.swipeDown(velocity: .slow)
        XCTAssertFalse(newest.exists && newest.isHittable, "Scrolling toward old history must move away from the newest message.")
        let returnToLatest = app.buttons["chat.jumpToLatest"]
        XCTAssertFalse(returnToLatest.exists, "The removed latest-message overlay must stay absent while reading history.")
        attachScreenshot("\(screenshotPrefix)-reading-history")

        let input = app.textFields["chat.input"]
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
        XCTAssertTrue(input.isHittable)
        XCTAssertTrue(navigation.isHittable, "The keyboard must preserve navigation access.")
        XCTAssertFalse(app.otherElements["cove.tabBar"].isHittable)
        attachScreenshot("\(screenshotPrefix)-history-keyboard")
        history.swipeDown(velocity: .slow)
        if app.keyboards.firstMatch.exists { history.swipeDown(velocity: .slow) }
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 4)
        XCTAssertFalse(newest.exists && newest.isHittable, "Dismissing the keyboard must preserve the older-history position.")
        for _ in 0..<12 {
            if newest.exists && newest.isHittable { break }
            history.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(newest.waitForExistence(timeout: 8))
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: newest)
        waitForExpectations(timeout: 8)
        XCTAssertLessThan(newest.frame.maxY, input.frame.minY, "Returning to latest must reveal the entire newest paragraph above the composer.")
        XCTAssertFalse(returnToLatest.exists && returnToLatest.isHittable)
        XCTAssertTrue(app.otherElements["cove.tabBar"].isHittable)
        attachScreenshot("\(screenshotPrefix)-returned-latest")
        attachHierarchy("\(screenshotPrefix)-hierarchy")
    }

    func testWallpaperPreviewCancelAndApply() throws {
        try tapTab("tab.settings", label: "设置")
        let entry = app.buttons["settings.wallpaper"]
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.tap()
        XCTAssertTrue(app.buttons["wallpaper.cancel"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["把日常留在 Cove。"].exists)
        XCTAssertTrue(app.staticTexts["这里是我们的小天地。"].exists)
        let selected = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND selected == true", "wallpaper.choice.")).firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 3))
        let originalID = selected.identifier
        let targetID = originalID == "wallpaper.choice.cream" ? "wallpaper.choice.rose" : "wallpaper.choice.cream"
        let target = wallpaperChoice(targetID)
        target.tap()
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: target)
        waitForExpectations(timeout: 3)
        attachScreenshot("wallpaper-draft-preview")
        app.buttons["wallpaper.cancel"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.tap()
        XCTAssertTrue(app.buttons["wallpaper.cancel"].waitForExistence(timeout: 3))
        let original = wallpaperChoice(originalID)
        XCTAssertTrue(original.isSelected, "Cancel must preserve the previously applied wallpaper.")
        XCTAssertFalse(app.buttons[targetID].isSelected, "A canceled draft must not become the applied selection.")
        let applied = wallpaperChoice(targetID)
        applied.tap()
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: applied)
        waitForExpectations(timeout: 3)
        app.buttons["wallpaper.apply"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(app.buttons["wallpaper.cancel"].waitForExistence(timeout: 3))
        XCTAssertTrue(wallpaperChoice(targetID).isSelected, "Apply must persist the wallpaper when reopening settings.")
        attachScreenshot("wallpaper-applied-preview")
        // Restore the user's previous selection, including an existing photo.
        wallpaperChoice(originalID).tap()
        app.buttons["wallpaper.apply"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        try tapTab("tab.chat", label: "对话")
        XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 3))
    }

    private func wallpaperChoice(_ identifier: String) -> XCUIElement {
        let choice = app.buttons[identifier]
        // Wallpaper settings is a ScrollView with a LazyVGrid. Locate the real
        // button before tapping; photo and later rows need not be onscreen.
        for _ in 0..<3 {
            if choice.exists && choice.isHittable { break }
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(choice.exists && choice.isHittable, "Wallpaper choice must be visible and tappable: \(identifier)")
        return choice
    }

    private func tapTab(_ identifier: String, label: String) throws {
        // Native tab bars may expose SwiftUI labels instead of their identifiers.
        // Query only the actual tab-bar subtree and inspect its emitted hierarchy.
        let identified = app.otherElements["cove.tabBar"].buttons[identifier]
        let tab = identified.exists ? identified : app.otherElements["cove.tabBar"].buttons[label]
        guard tab.waitForExistence(timeout: 3) else {
            attachHierarchy("missing-\(identifier)")
            XCTFail("Missing native tab \(label)")
            throw NSError(domain: "CoveUITests", code: 1)
        }
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: tab)
        waitForExpectations(timeout: 3)
        // A real finger stays down longer than XCUI's default tap. iOS 26's
        // native tab-selection animation must commit before inspecting content.
        tab.press(forDuration: 0.1)
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: tab)
        waitForExpectations(timeout: 3)
        XCTAssertTrue(tab.isSelected, "The native tab must confirm selection before page assertions.")
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachHierarchy(_ name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
