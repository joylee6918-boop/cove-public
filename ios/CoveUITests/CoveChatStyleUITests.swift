import XCTest

@MainActor
final class CoveChatStyleUITests: XCTestCase {
    func testOutgoingBubbleSwipeRepliesAndPreservesDraft() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--chat-send-qa"]
        app.launch()

        let input = app.textFields["chat.input"]
        let bubble = app.otherElements["chat.bubble.p4"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        XCTAssertTrue(bubble.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("原来的草稿")

        // Start on the bubble's non-text edge so the Markdown text selection
        // and long-press context menu cannot consume the horizontal swipe.
        let start = bubble.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -110, dy: 0)))

        let cancelReply = app.buttons["取消引用"]
        XCTAssertTrue(cancelReply.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["回复 用户"].exists)
        XCTAssertEqual(input.value as? String, "原来的草稿", "Swiping to reply must not replace an existing draft.")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Completing a reply swipe should focus the composer.")
        cancelReply.tap()
        XCTAssertTrue(cancelReply.waitForNonExistence(timeout: 2))
        XCTAssertEqual(input.value as? String, "原来的草稿")
    }

    func testShortBubbleSwipeDoesNotBeginReply() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--chat-send-qa"]
        app.launch()

        let bubble = app.otherElements["chat.bubble.p4"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 15))
        let start = bubble.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -20, dy: 0)))
        XCTAssertFalse(app.buttons["取消引用"].exists, "A short horizontal movement must cancel without selecting a reply.")
        XCTAssertFalse(app.staticTexts["回复 用户"].exists)
        XCTAssertTrue(bubble.isHittable, "Cancelling the gesture must leave the message interactive.")
    }

    func testComposerStopsAtSixLinesAndCollapsesAfterDeletion() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--chat-send-qa"]
        app.launch()

        let input = app.textFields["chat.input"]
        let send = app.buttons["chat.send"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        let collapsedHeight = input.frame.height
        let twelveLines = (1...12).map { "第\($0)行" }.joined(separator: "\n")
        input.typeText(twelveLines)

        let expandedHeight = input.frame.height
        XCTAssertGreaterThan(expandedHeight, collapsedHeight)
        XCTAssertLessThan(expandedHeight, collapsedHeight * 7,
                          "The composer must scroll internally rather than growing beyond its six-line cap.")
        XCTAssertTrue(send.isHittable)
        XCTAssertGreaterThanOrEqual(send.frame.width, 44)
        XCTAssertGreaterThanOrEqual(send.frame.height, 44)

        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: twelveLines.count))
        let collapsed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "frame.size.height <= %f", collapsedHeight + 1), object: input)
        XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 3), .completed)
    }

    func testLongHistoryRemainsVisibleAcrossLocalSends() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--stress", "--chat-send-qa"]
        app.launch()
        XCTAssertTrue(app.staticTexts["示例预览 · 数据不会上传"].waitForExistence(timeout: 15))
        let input = app.textFields["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        for index in 1...3 {
            let marker = "Local layout check \(index)"
            input.typeText(marker)
            let send = app.buttons["chat.send"]
            XCTAssertTrue(send.isEnabled)
            send.tap()
            XCTAssertFalse(app.staticTexts["正在回复 · 可以继续发消息"].exists,
                           "Continuous send must not add a second status row above the composer")
            XCTAssertTrue(input.isHittable, "Submitting must not replace the chat screen")
            XCTAssertTrue(app.keyboards.firstMatch.exists)
            let reply = app.staticTexts["本地模拟回复：" + marker]
            XCTAssertTrue(reply.waitForExistence(timeout: 4))
            XCTAssertTrue(reply.isHittable, "Bottom anchoring must leave a rendered message in the viewport")
            XCTAssertFalse(app.buttons["chat.jumpLatest"].exists)
        }
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "chat-long-history-after-local-sends"
        capture.lifetime = .keepAlways
        add(capture)
    }

    func testRichCompletionKeepsChatVisibleAcrossSendsAndKeyboardChanges() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--stress-markdown", "--chat-send-qa", "--chat-rich-reply-qa"]
        app.launch()
        let input = app.textFields["chat.input"]
        let history = app.scrollViews["chat.history"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        for index in 1...4 {
            let marker = "Rich check \(index)"
            input.typeText(marker)
            app.buttons["chat.send"].tap()
            // Check DURING the placeholder/completion transition, not only a
            // final element that is allowed to appear four seconds later.
            for _ in 0..<8 {
                // One coherent snapshot: querying old row indices individually
                // while a new reply is appended can miss that reply entirely.
                let tree = try app.snapshot()
                let nodes = snapshotNodes(tree)
                let viewport = try XCTUnwrap(nodes.first { $0.identifier == "chat.history" }).frame
                XCTAssertTrue(nodes.contains { row in
                    row.identifier.hasPrefix("chat.bubble.") && row.frame.width > 0
                        && row.frame.intersection(viewport).height > 8
                }, "There must be a message frame in the viewport throughout the sampled transition")
                XCTAssertTrue(input.isHittable)
                Thread.sleep(forTimeInterval: 0.1)
            }
            let end = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "完成标记：" + marker)).firstMatch
            XCTAssertTrue(end.waitForExistence(timeout: 2))
            XCTAssertTrue(end.isHittable)
            let capture = XCTAttachment(screenshot: app.screenshot())
            capture.name = "rich-complete-\(index)"
            capture.lifetime = .keepAlways
            add(capture)
            history.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.4)).tap()
            XCTAssertTrue(end.isHittable, "Closing the keyboard must retain the reply")
            input.tap()
            XCTAssertTrue(end.isHittable, "Opening the keyboard must retain the reply")
        }
    }

    private func snapshotNodes(_ root: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
        [root] + root.children.flatMap { snapshotNodes($0) }
    }

    func testHistoryWindowExpandsAndSurvivesSending() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--stress", "--chat-send-qa"]
        app.launch()
        let history = app.scrollViews["chat.history"]
        XCTAssertTrue(history.waitForExistence(timeout: 15))
        let older = app.buttons["chat.loadEarlier"]
        for _ in 0..<15 {
            if older.isHittable { break }
            history.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(older.isHittable)
        older.tap()
        // Expanded window is 60 messages; records outside it remain stored but
        // do not instantiate native views. Appending must not reset it to 30.
        XCTAssertTrue(app.otherElements["chat.bubble.stress-540"].exists)
        let input = app.textFields["chat.input"]
        input.tap(); input.typeText("Keep expanded history")
        app.buttons["chat.send"].tap()
        let reply = app.staticTexts["本地模拟回复：Keep expanded history"]
        XCTAssertTrue(reply.waitForExistence(timeout: 3))
        XCTAssertTrue(reply.isHittable)
        XCTAssertTrue(app.otherElements["chat.bubble.stress-540"].exists)
        history.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.4)).tap()
        let home = app.buttons["tab.home"]
        XCTAssertTrue(home.waitForExistence(timeout: 3))
        home.tap()
        XCTAssertTrue(app.staticTexts["用户与 Assistant"].waitForExistence(timeout: 3))
        app.buttons["tab.chat"].tap()
        XCTAssertTrue(reply.waitForExistence(timeout: 3))
        XCTAssertTrue(reply.isHittable, "Re-entry must re-anchor the compacted window")
        XCTAssertFalse(app.otherElements["chat.bubble.stress-540"].exists)
    }

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
        XCTAssertLessThan(input.frame.maxY, app.tabBars.firstMatch.frame.minY)
        input.tap()
        input.typeText("还没写完的草稿")
        stickerButton.tap()
        let owner = app.segmentedControls["stickers.owner"]
        let stickerSheet = app.descendants(matching: .any).matching(identifier: "stickers.sheet").firstMatch
        XCTAssertTrue(owner.waitForExistence(timeout: 5))
        XCTAssertTrue(stickerSheet.waitForExistence(timeout: 5), "Stickers must use the stable native sheet path.")
        let mine = app.buttons["stickers.send.preview-user"]
        XCTAssertTrue(mine.exists)
        XCTAssertFalse(mine.isEnabled, "Preview stickers must never send a real message.")
        let snapshot = XCTAttachment(screenshot: app.screenshot())
        snapshot.name = "sticker-picker-my-library"
        snapshot.lifetime = .keepAlways
        add(snapshot)
        owner.buttons["Assistant 的"].tap()
        XCTAssertTrue(app.buttons["stickers.send.preview-assistant"].exists)
        XCTAssertFalse(app.buttons["stickers.send.preview-assistant"].isEnabled)

        for cycle in 1...3 {
            let keyboardButton = app.buttons["stickers.keyboard"]
            XCTAssertTrue(keyboardButton.waitForExistence(timeout: 5))
            XCTAssertTrue(keyboardButton.isHittable)
            // Native navigation toolbar AX bounds describe the symbol, not
            // its surrounding system hit target (verified in the screenshot).
            // Keep the custom composer button's 44pt checks above; exercise
            // this system control by actually returning to the keyboard.
            keyboardButton.tap()
            let keyboard = app.keyboards.firstMatch
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "Cycle \(cycle) must restore the native keyboard.")
            XCTAssertTrue(stickerSheet.waitForNonExistence(timeout: 5), "Cycle \(cycle) must dismiss the sticker sheet.")
            assertInputAttachedAbove(input, inputSurface: keyboard, name: "keyboard", cycle: cycle)
            let tabBarHidden = NSPredicate(format: "hittable == false")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: tabBarHidden, object: app.tabBars.firstMatch)], timeout: 2), .completed,
                "The app tab bar must stay hidden while the native keyboard is visible.")
            XCTAssertEqual(input.value as? String, "还没写完的草稿")
            XCTAssertLessThan(app.staticTexts["chat.message.p4"].frame.maxY, input.frame.minY,
                              "The keyboard must push the latest message above the composer on cycle \(cycle).")

            stickerButton.tap()
            XCTAssertTrue(owner.waitForExistence(timeout: 5), "Cycle \(cycle) must restore the sticker sheet.")
            XCTAssertTrue(stickerSheet.waitForExistence(timeout: 5))
            XCTAssertFalse(app.keyboards.firstMatch.exists)
            XCTAssertEqual(input.value as? String, "还没写完的草稿")
        }

        app.buttons["stickers.keyboard"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "还没写完的草稿")
        XCTAssertTrue(input.isHittable)
        XCTAssertFalse(app.buttons["chat.jumpToLatest"].exists)
    }

    func testStickerPickerOpensFromColdComposerWithoutOpeningKeyboardFirst() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview"]
        app.launch()

        let input = app.textFields["chat.input"]
        let stickerButton = app.buttons["chat.stickers"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertTrue(stickerButton.isHittable)
        XCTAssertGreaterThanOrEqual(stickerButton.frame.width, 44)
        XCTAssertGreaterThanOrEqual(stickerButton.frame.height, 44)
        let untouchedDraft = input.value as? String
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Cold launch must not pre-open the system keyboard.")

        stickerButton.tap()

        XCTAssertTrue(app.segmentedControls["stickers.owner"].waitForExistence(timeout: 5))
        let stickerSheet = app.descendants(matching: .any).matching(identifier: "stickers.sheet").firstMatch
        XCTAssertTrue(stickerSheet.waitForExistence(timeout: 5), "A direct sticker tap must present the native sticker sheet.")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "A direct sticker tap must open the sheet without flashing the system keyboard.")
        XCTAssertEqual(input.value as? String, untouchedDraft, "Opening stickers from an untouched composer must preserve its draft.")
        let keyboardButton = app.buttons["stickers.keyboard"]
        XCTAssertTrue(keyboardButton.isHittable)
        XCTAssertGreaterThanOrEqual(keyboardButton.frame.width, 44)
        XCTAssertGreaterThanOrEqual(keyboardButton.frame.height, 44)
        keyboardButton.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertTrue(stickerSheet.waitForNonExistence(timeout: 5))
        assertInputAttachedAbove(input, inputSurface: keyboard, name: "keyboard")
        XCTAssertEqual(input.value as? String, untouchedDraft)
        XCTAssertTrue(input.isHittable)
        XCTAssertFalse(app.buttons["chat.jumpToLatest"].exists)
    }

    private func assertInputAttachedAbove(_ input: XCUIElement, inputSurface: XCUIElement, name: String,
                                          cycle: Int? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let suffix = cycle.map { " on cycle \($0)" } ?? ""
        let gap = inputSurface.frame.minY - input.frame.maxY
        XCTAssertGreaterThanOrEqual(gap, -1, "The composer must remain above the \(name)\(suffix).", file: file, line: line)
        // XCUI's Keyboard frame excludes the roughly 45pt Chinese candidate
        // strip visible in the device screenshot; allow that plus the normal
        // composer inset while still rejecting a genuinely floating composer.
        XCTAssertLessThanOrEqual(gap, 77, "The composer must stay attached to the \(name), not float above it\(suffix).", file: file, line: line)
    }

    func testComposerReopensKeyboardAfterDismissal() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview"]
        app.launch()

        let input = app.textFields["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        input.typeText("first")
        XCTAssertEqual(input.value as? String, "first")

        let history = app.scrollViews["chat.history"]
        XCTAssertTrue(history.exists && history.isHittable)
        history.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.35)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "A wallpaper gutter tap must dismiss the keyboard.")
        XCTAssertEqual(input.value as? String, "first")

        input.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "The same composer must reopen the keyboard after dismissal.")
        assertInputAttachedAbove(input, inputSurface: keyboard, name: "keyboard")
        XCTAssertEqual(input.value as? String, "first", "Reopening the keyboard must preserve the existing draft before editing resumes.")
        // A native TextField restores focus without promising where a generic
        // centre tap places the caret. Tap the text's trailing edge explicitly.
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        input.typeText(" second")
        XCTAssertEqual(input.value as? String, "first second", "Refocusing must preserve and extend the draft.")
        XCTAssertLessThan(app.staticTexts["chat.message.p4"].frame.maxY, input.frame.minY,
                          "Reopened keyboard must keep the latest message above the composer.")
    }

    func testTimestampOutsideCompactBubbleAndTerminalEntry() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview"]
        app.launch()
        let message = app.staticTexts["chat.message.p4"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertEqual(message.label, "就叫 Cove 吧。")
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

@MainActor
final class CoveComposerControlUITests: XCTestCase {
    func testNativeSendDragCancellationAndReducedMotion() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--composer-control-qa"]
        app.launch()
        let fixture = app.otherElements["composer.qa.fixture"]
        let button = fixture.buttons["chat.send"]
        let count = app.staticTexts["composer.qa.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 15))
        XCTAssertEqual(count.label, "0")
        XCTAssertTrue(button.isHittable)
        XCTAssertGreaterThanOrEqual(button.frame.width, 44)
        XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        let origin = button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.15, thenDragTo: origin.withOffset(CGVector(dx: -90, dy: -70)))
        XCTAssertEqual(count.label, "0", "Dragging out must cancel, not commit on release.")
        button.tap()
        XCTAssertEqual(count.label, "1")
        setSwitch(fixture.switches["composer.qa.disabled"], to: true)
        let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [disabled], timeout: 5), .completed)
        XCTAssertFalse(button.isEnabled)
        setSwitch(fixture.switches["composer.qa.disabled"], to: false)
        setSwitch(fixture.switches["composer.qa.reduced"], to: true)
        button.tap()
        XCTAssertEqual(count.label, "2")
        let sendFrame = button.frame
        setSwitch(fixture.switches["composer.qa.busy"], to: true)
        let stop = fixture.buttons["chat.stop"]
        XCTAssertTrue(stop.isHittable)
        XCTAssertEqual(stop.frame, sendFrame)
        stop.tap()
        XCTAssertEqual(count.label, "3")
    }
    private func setSwitch(_ toggle: XCUIElement, to enabled: Bool) {
        XCTAssertTrue(toggle.exists && toggle.isHittable)
        let expected = enabled ? "1" : "0"
        if toggle.value as? String != expected {
            // SwiftUI exposes the whole labelled row as the switch. Tap its
            // trailing native knob rather than the empty centre of the row.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        XCTAssertEqual(toggle.value as? String, expected)
    }

}

@MainActor
final class CoveHealthRequestCardUITests: XCTestCase {
    func testLocalRequestScopeConsentAndExpiration() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--health-request-qa"]
        app.launch()
        let fixture = app.scrollViews["health.qa.fixture"]
        XCTAssertTrue(fixture.waitForExistence(timeout: 15))
        // Actual AX hierarchy inherits the card identifier onto its children;
        // use semantic labels within the uniquely scoped local fixture.
        let allow = fixture.buttons["允许这次"]
        let deny = fixture.buttons["拒绝"]
        XCTAssertTrue(allow.waitForExistence(timeout: 15))
        XCTAssertTrue(allow.isHittable && deny.isHittable)
        XCTAssertTrue(allow.isEnabled && deny.isEnabled)
        XCTAssertTrue(fixture.staticTexts["睡眠 · 静息心率 · 最近一次心率 · 步数 · HRV"].exists)
        XCTAssertTrue(fixture.staticTexts["模拟请求：查看昨晚与今天的健康近况"].exists)
        let range = fixture.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", " — ")).firstMatch
        XCTAssertTrue(range.exists && range.isHittable)
        XCTAssertTrue(range.label.contains(" — "))
        XCTAssertFalse(fixture.staticTexts["这次摘要已被对方读取"].exists)
        deny.tap()
        XCTAssertFalse(fixture.staticTexts["Assistant 请求读取健康"].exists, "A denied card must leave the conversation")
        XCTAssertTrue(allow.waitForNonExistence(timeout: 2))
        fixture.buttons["重置模拟请求"].tap()
        XCTAssertTrue(allow.waitForExistence(timeout: 3))
        fixture.buttons["模拟过期"].tap()
        XCTAssertTrue(allow.waitForNonExistence(timeout: 2))
        XCTAssertFalse(fixture.staticTexts["Assistant 请求读取健康"].exists, "An expired card must not take up chat space")
        fixture.buttons["重置模拟请求"].tap()
        XCTAssertTrue(allow.waitForExistence(timeout: 3))
        allow.tap()
        XCTAssertFalse(fixture.staticTexts["Assistant 请求读取健康"].exists, "An allowed card must disappear while continuation proceeds")
        XCTAssertTrue(allow.waitForNonExistence(timeout: 2))
        XCTAssertTrue(deny.waitForNonExistence(timeout: 2))
        XCTAssertFalse(fixture.staticTexts["这次摘要已被对方读取"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "health-request-local-fixture"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
