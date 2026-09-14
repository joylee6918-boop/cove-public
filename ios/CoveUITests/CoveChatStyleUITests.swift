import XCTest

@MainActor
final class CoveChatStyleUITests: XCTestCase {
    func testStickerPickerKeepsComposerAndPreviewSafe() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview"]
        app.launch()
        let input = app.textFields["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        let stickerButton = app.buttons["chat.stickers"]
        XCTAssertTrue(stickerButton.isHittable)
        XCTAssertGreaterThanOrEqual(stickerButton.frame.width, 44)
        XCTAssertGreaterThanOrEqual(stickerButton.frame.height, 44)
        XCTAssertLessThanOrEqual(input.frame.maxX, stickerButton.frame.minX)
        XCTAssertLessThan(input.frame.maxY, app.otherElements["cove.tabBar"].frame.minY)
        input.tap()
        input.typeText("还没写完的草稿")
        stickerButton.tap()
        let owner = app.segmentedControls["stickers.owner"]
        XCTAssertTrue(owner.waitForExistence(timeout: 5))
        let mine = app.buttons["stickers.send.preview-user"]
        XCTAssertTrue(mine.exists)
        XCTAssertFalse(mine.isEnabled, "Preview stickers must never send a real message.")
        let snapshot = XCTAttachment(screenshot: app.screenshot())
        snapshot.name = "sticker-picker-my-library"
        snapshot.lifetime = .keepAlways
        add(snapshot)
        owner.buttons["助手 的"].tap()
        XCTAssertTrue(app.buttons["stickers.send.preview-assistant"].exists)
        XCTAssertFalse(app.buttons["stickers.send.preview-assistant"].isEnabled)
        app.buttons["完成"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "还没写完的草稿")
        XCTAssertTrue(input.isHittable)
        XCTAssertFalse(app.buttons["chat.jumpToLatest"].exists)
    }

    func testTimestampOutsideCompactBubbleAndTerminalEntry() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview"]
        app.launch()
        let message = app.staticTexts["chat.message.p4"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertEqual(message.label, "先看看设置页面。")
        let bubble = app.otherElements["chat.bubble.p4"]
        let timestamp = app.staticTexts["chat.timestamp.p4"]
        XCTAssertTrue(bubble.exists)
        XCTAssertTrue(timestamp.exists && timestamp.isHittable)
        XCTAssertGreaterThanOrEqual(timestamp.frame.minY, bubble.frame.maxY,
                                    "The timestamp must sit outside and below the bubble background.")
        XCTAssertLessThan(bubble.frame.width, app.frame.width - 44,
                          "A short message must not occupy the entire chat width.")
        XCTAssertTrue(app.buttons["chat.terminal"].isHittable)
        XCTAssertTrue(app.buttons["chat.conversations"].isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "compact-chat-timestamp"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.buttons["chat.terminal"].tap()
        XCTAssertTrue(app.textFields["terminal.input"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["示例模式 · 不连接控制台"].exists)
        XCTAssertTrue(app.staticTexts["控制台只显示真实会话。退出示例预览后连接服务即可使用。"].exists)
        XCTAssertFalse(app.buttons["terminal.send"].isEnabled)
        XCTAssertFalse(app.buttons["terminal.models"].isEnabled)
        app.buttons["terminal.close"].tap()
        XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chat.terminal"].isHittable)
    }

    func testSentAndReadChecksUseConfirmedStatus() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview"]
        app.launch()
        let sent = app.descendants(matching: .any).matching(identifier: "chat.delivery.p4").firstMatch
        let read = app.descendants(matching: .any).matching(identifier: "chat.delivery.p2").firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 10))
        XCTAssertTrue(read.exists && read.isHittable)
        XCTAssertEqual(sent.label, "已发送", "Server acceptance must show the single-check state, not infer read.")
        XCTAssertEqual(read.label, "已读", "Only confirmed readAt may show the double-check state.")
        XCTAssertGreaterThan(read.frame.width, sent.frame.width, "The read state must contain the additional check stroke.")
        let timestamp = app.staticTexts["chat.timestamp.p4"]
        XCTAssertGreaterThanOrEqual(timestamp.frame.minY, app.otherElements["chat.bubble.p4"].frame.maxY)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "confirmed-single-and-double-checks"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testLikeContextMenuAndReactionToggle() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview"]
        app.launch()
        let body = app.staticTexts["chat.message.p3"]
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        let originalText = body.label
        let input = app.textFields["chat.input"]
        let originalDraft = input.value as? String
        let reaction = app.buttons["chat.reaction.p3"]
        XCTAssertFalse(reaction.exists)
        body.press(forDuration: 0.8)
        let like = app.buttons["点赞"]
        XCTAssertTrue(like.waitForExistence(timeout: 3))
        like.tap()
        XCTAssertTrue(reaction.waitForExistence(timeout: 3))
        XCTAssertTrue(reaction.isHittable)
        XCTAssertEqual(reaction.label, "已点赞，1个点赞；点击取消")
        XCTAssertEqual(body.label, originalText)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "message-reaction-selected"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        reaction.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: reaction)
        waitForExpectations(timeout: 3)
        body.press(forDuration: 0.8)
        XCTAssertTrue(like.waitForExistence(timeout: 3))
        like.tap()
        XCTAssertTrue(reaction.waitForExistence(timeout: 3))
        body.press(forDuration: 0.8)
        let unlike = app.buttons["取消点赞"]
        XCTAssertTrue(unlike.waitForExistence(timeout: 3))
        unlike.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: reaction)
        waitForExpectations(timeout: 3)
        XCTAssertEqual(body.label, originalText, "Reacting must preserve the actual message body.")
        XCTAssertEqual(input.value as? String, originalDraft, "Reacting must not alter the composer draft.")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "chat.quote.p3").firstMatch.exists)
    }

}
