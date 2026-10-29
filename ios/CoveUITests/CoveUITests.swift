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
        XCTAssertEqual(app.tabBars.firstMatch.buttons.count, 5)
        XCTAssertLessThanOrEqual(app.tabBars.firstMatch.frame.width, app.frame.width)
        XCTAssertFalse(app.otherElements["cove.tabBar"].exists, "Do not render a second custom bar.")
        for button in app.tabBars.firstMatch.buttons.allElementsBoundByIndex {
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
        for (identifier, label, filename) in tabs {
            try tapTab(identifier, label: label)
            switch identifier {
            case "tab.home":
                XCTAssertTrue(app.staticTexts["用户与 Assistant"].waitForExistence(timeout: 3))
                XCTAssertTrue(app.staticTexts["接着说"].exists)
            case "tab.pulse":
                XCTAssertTrue(app.staticTexts["最近一次心跳记录"].waitForExistence(timeout: 3))
                app.segmentedControls.buttons["感受"].tap()
                XCTAssertTrue(app.staticTexts["心里的倾向"].exists)
            case "tab.chat":
                XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 3))
                XCTAssertTrue(app.textFields["chat.input"].isHittable)
                XCTAssertLessThan(app.textFields["chat.input"].frame.maxY,
                                  app.tabBars.firstMatch.frame.minY)
                let send = app.buttons["chat.send"]
                XCTAssertFalse(send.exists && send.isEnabled, "Preview must never expose an enabled real-message send action.")
            case "tab.health":
                XCTAssertTrue(app.staticTexts["Apple 健康"].waitForExistence(timeout: 3))
                XCTAssertTrue(app.staticTexts["health.storageExplanation"].exists)
                XCTAssertFalse(app.staticTexts["留在本机的健康记录"].exists)
            default:
                XCTAssertTrue(app.textFields["settings.url"].waitForExistence(timeout: 3))
                XCTAssertTrue(app.secureTextFields["settings.token"].exists)
                XCTAssertFalse(app.buttons["settings.connect"].isEnabled)
            }
            attachScreenshot(filename)
            XCTAssertTrue(app.tabBars.firstMatch.isHittable, "The system tab bar must own navigation.")
        }
        attachHierarchy("five-tabs-hierarchy")
    }

    func testBluetoothConnectionPageNeverScansInPreview() throws {
        try tapTab("tab.settings", label: "设置")
        let link = app.buttons["settings.bluetooth"]
        for _ in 0..<6 where !link.isHittable { app.swipeUp() }
        XCTAssertTrue(link.isHittable)
        link.tap()
        XCTAssertTrue(app.staticTexts["bluetooth.status"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["bluetooth.status"].label, "示例预览，不使用真实蓝牙")
        XCTAssertTrue(app.buttons["toy.scan"].exists)
        XCTAssertFalse(app.buttons["toy.scan"].isEnabled)
        XCTAssertFalse(app.buttons["toy.grant"].exists)
        XCTAssertFalse(app.buttons["bluetooth.disconnect"].exists)
        XCTAssertEqual(app.tabBars.firstMatch.buttons.count, 5)
        attachScreenshot("bluetooth-connection-only-preview")
    }

    func testNativeGlassNavigationInLightAndDark() throws {
        for appearance in ["light", "dark"] {
            app.terminate()
            app.launchArguments = ["--preview", "-cove.appearance", appearance]
            app.launch()
            let input = app.textFields["chat.input"]
            XCTAssertTrue(input.waitForExistence(timeout: 10))
            let tabBar = app.tabBars.firstMatch
            XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
            XCTAssertEqual(tabBar.buttons.count, 5)
            XCTAssertTrue(tabBar.buttons["对话"].isSelected)
            XCTAssertFalse(app.otherElements["cove.tabBar"].exists)
            XCTAssertLessThan(input.frame.maxY, tabBar.frame.minY)
            for identifier in ["chat.search", "chat.terminal", "chat.conversations"] {
                XCTAssertTrue(app.buttons[identifier].isHittable)
            }
            attachScreenshot("ios27-native-chat-\(appearance)")
            try tapTab("tab.settings", label: "设置")
            XCTAssertTrue(app.textFields["settings.url"].waitForExistence(timeout: 3))
            attachScreenshot("ios27-native-settings-\(appearance)")
        }
    }

    func testPulseDashboardLocalFixture() throws {
        app.terminate()
        app.launchArguments = ["--preview", "--pulse-qa", "--tab", "1"]
        app.launch()
        XCTAssertTrue(app.staticTexts["数字身体模型"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["已记录的模型采样"].exists)
        XCTAssertTrue(app.staticTexts["72"].exists)
        attachScreenshot("pulse-v3-current")

        app.buttons["醒来记录"].tap()
        XCTAssertTrue(app.staticTexts["性欲推动了主动靠近"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["性欲把我叫醒了，想主动靠近你。"].exists)
        XCTAssertTrue(app.staticTexts["安静完成"].exists)
        XCTAssertFalse(app.staticTexts["libido_crossed_threshold"].exists)
        XCTAssertFalse(app.staticTexts["quiet"].exists)
        attachScreenshot("pulse-v3-wakes")

        app.buttons["感受"].tap()
        XCTAssertTrue(app.staticTexts["心里的倾向"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["环境"].exists)
        XCTAssertTrue(app.staticTexts["雨声让整个海湾安静下来。"].exists)
        attachScreenshot("pulse-v3-feelings")
    }

    func testQuoteReplyComposerAndKeyboard() throws {
        let message = app.staticTexts["就叫 Cove 吧。"]
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
        XCTAssertFalse(app.tabBars.firstMatch.isHittable, "The keyboard should hide the tab bar.")
        attachScreenshot("quote-keyboard")

        let history = app.scrollViews["chat.history"]
        XCTAssertTrue(history.exists)
        history.swipeDown(velocity: .slow)
        if app.keyboards.firstMatch.exists { history.swipeDown(velocity: .slow) }
        let keyboardGone = NSPredicate(format: "exists == false")
        expectation(for: keyboardGone, evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 4)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 4))
        XCTAssertTrue(app.tabBars.firstMatch.isHittable)
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
        XCTAssertLessThan(input.frame.maxY, app.tabBars.firstMatch.frame.minY)
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
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
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
        XCTAssertTrue(app.tabBars.firstMatch.isHittable)
        XCTAssertFalse(app.buttons["chat.jumpToLatest"].exists && app.buttons["chat.jumpToLatest"].isHittable)
        attachScreenshot("latest-after-keyboard")
        attachHierarchy("latest-keyboard-hierarchy")
    }

    func testLatestMessageFollowsKeyboardAfterManualScrollRoundTrip() throws {
        app.terminate()
        app.launchArguments = ["--preview", "--stress-markdown"]
        app.launch()
        let history = app.scrollViews["chat.history"]
        let latest = app.otherElements["chat.bubble.stress-599"].staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "历史示例 600")).firstMatch
        let timestamp = app.staticTexts["chat.timestamp.stress-599"]
        let input = app.textFields["chat.input"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        XCTAssertTrue(latest.waitForExistence(timeout: 10))
        waitForLatestAboveComposer(latest, timestamp: timestamp, input: input)

        history.swipeDown(velocity: .slow)
        history.swipeDown(velocity: .slow)
        XCTAssertFalse(latest.exists && latest.isHittable)
        for _ in 0..<12 {
            if latest.exists && latest.isHittable { break }
            history.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(latest.waitForExistence(timeout: 8))
        history.swipeUp(velocity: .fast)
        waitForLatestAboveComposer(latest, timestamp: timestamp, input: input)

        for cycle in 1...2 {
            let bottomBeforeKeyboard = latest.frame.maxY
            input.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
            waitForLatestAboveComposer(latest, timestamp: timestamp, input: input)
            XCTAssertLessThan(latest.frame.maxY, bottomBeforeKeyboard - 80,
                              "Keyboard cycle \(cycle) must move the latest message upward by more than 80 points.")

            history.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.3)).tap()
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
            waitForExpectations(timeout: 5)
            waitForLatestAboveComposer(latest, timestamp: timestamp, input: input)
        }
    }

    func testJumpToLatestAppearsOnlyAfterMeaningfulHistoryScroll() {
        app.terminate()
        app.launchArguments = ["--preview", "--stress-markdown"]
        app.launch()
        let history = app.scrollViews["chat.history"]
        let jump = app.buttons["chat.jumpToLatest"]
        let latest = app.otherElements["chat.bubble.stress-599"].staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "历史示例 600")).firstMatch
        let timestamp = app.staticTexts["chat.timestamp.stress-599"]
        let input = app.textFields["chat.input"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        XCTAssertTrue(latest.waitForExistence(timeout: 10))
        waitForLatestAboveComposer(latest, timestamp: timestamp, input: input)
        XCTAssertFalse(jump.exists)

        let start = history.coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 65)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertFalse(jump.exists, "A small nudge must not reveal an obstructing overlay.")
        history.swipeDown(velocity: .slow)
        history.swipeDown(velocity: .slow)
        XCTAssertTrue(jump.waitForExistence(timeout: 4))
        XCTAssertTrue(jump.isHittable)
        XCTAssertGreaterThanOrEqual(jump.frame.width, 44)
        XCTAssertGreaterThanOrEqual(jump.frame.height, 44)
        XCTAssertLessThan(jump.frame.maxY, input.frame.minY)
        attachScreenshot("jump-to-latest-visible-0916")
        jump.tap()
        waitForLatestAboveComposer(latest, timestamp: timestamp, input: input)
        XCTAssertTrue(jump.waitForNonExistence(timeout: 4))
        attachScreenshot("jump-to-latest-hidden-0916")

        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
        waitForLatestAboveComposer(latest, timestamp: timestamp, input: input)
        XCTAssertFalse(jump.exists, "Returning to latest must restore keyboard following without a stray arrow.")
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
        XCTAssertTrue(returnToLatest.waitForExistence(timeout: 4))
        XCTAssertTrue(returnToLatest.isHittable)
        attachScreenshot("\(screenshotPrefix)-reading-history")

        let input = app.textFields["chat.input"]
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
        XCTAssertTrue(input.isHittable)
        XCTAssertTrue(navigation.isHittable, "The keyboard must preserve navigation access.")
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        attachScreenshot("\(screenshotPrefix)-history-keyboard")
        history.swipeDown(velocity: .slow)
        if app.keyboards.firstMatch.exists { history.swipeDown(velocity: .slow) }
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 4)
        XCTAssertFalse(newest.exists && newest.isHittable, "Dismissing the keyboard must preserve the older-history position.")
        XCTAssertTrue(returnToLatest.isHittable)
        returnToLatest.tap()
        XCTAssertTrue(newest.waitForExistence(timeout: 8))
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: newest)
        waitForExpectations(timeout: 8)
        XCTAssertLessThan(newest.frame.maxY, input.frame.minY, "Returning to latest must reveal the entire newest paragraph above the composer.")
        XCTAssertFalse(returnToLatest.exists && returnToLatest.isHittable)
        XCTAssertTrue(app.tabBars.firstMatch.isHittable)
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
        let identified = app.tabBars.firstMatch.buttons[identifier]
        let tab = identified.exists ? identified : app.tabBars.firstMatch.buttons[label]
        guard tab.waitForExistence(timeout: 3) else {
            attachHierarchy("missing-\(identifier)")
            XCTFail("Missing native tab \(label)")
            throw NSError(domain: "CoveUITests", code: 1)
        }
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: tab)
        waitForExpectations(timeout: 3)
        // Exercise the system tab item, not a custom replacement button.
        tab.tap()
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
