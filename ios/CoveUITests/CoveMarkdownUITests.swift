import XCTest
import UIKit

@MainActor
final class CoveMarkdownUITests: XCTestCase {
    func testStructuredMarkdownCodeCopyAndBoundedHorizontalContent() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "--markdown-preview"]
        app.launch()
        defer {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "markdown-final-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            attach(app, name: "markdown-final-state")
        }
        let history = app.scrollViews["chat.history"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        // Horizontal SwiftUI scroll views can be exported as an accessibility
        // container. Select its explicit ID and still test its visible bounds.
        let code = app.descendants(matching: .any).matching(identifier: "markdown.code.scroll").firstMatch
        let input = app.textFields["chat.input"]
        for _ in 0..<12 {
            if code.exists && code.isHittable && code.frame.maxY < input.frame.minY { break }
            if code.exists && code.frame.maxY >= input.frame.minY {
                scrollHistory(history, towardOlder: false)
            } else {
                scrollHistory(history, towardOlder: true)
            }
        }
        XCTAssertTrue(code.exists && code.isHittable, "The native code block must be reachable in the long Markdown bubble.")
        XCTAssertLessThan(code.frame.maxY, input.frame.minY, "Code must be fully above the composer before horizontal scrolling.")
        XCTAssertLessThanOrEqual(code.frame.width, history.frame.width, "A long code line must not widen its chat bubble.")
        code.swipeLeft(velocity: .slow)
        let copy = app.buttons["markdown.code.copy"]
        XCTAssertTrue(copy.isHittable)
        copy.tap()
        XCTAssertTrue(copy.label.contains("已复制"))
        // Paste through Cove's native edit menu. Reading UIPasteboard in the
        // separate test runner triggers cross-app privacy authorization.
        let expectedCode = #"""
        let place = "Cove"
        func hello(_ name: String) {
            print("Hello, \(name). This is a deliberately long line for checking horizontal code scrolling without widening the chat bubble.")
        }
        hello("用户")
        """#
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
        input.press(forDuration: 1.1)
        let paste = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label IN %@", ["Paste", "粘贴"]))
            .firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 4), "The empty native composer must offer Paste after copying code.")
        paste.tap()
        expectation(for: NSPredicate(format: "value == %@", expectedCode), evaluatedWith: input)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(input.value as? String, expectedCode, "Paste must preserve every code character, indentation and newline without Markdown fences.")
        XCTAssertFalse(app.buttons["chat.send"].isEnabled, "Pasting code in preview must never enable network sending.")
        attach(app, name: "markdown-code-scrolled-copied-and-pasted")
        scrollHistory(history, towardOlder: true)
        if app.keyboards.firstMatch.exists { scrollHistory(history, towardOlder: true) }
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 4)
        XCTAssertEqual(input.value as? String, expectedCode, "Dismissing the keyboard must preserve the pasted original code.")

        let table = app.descendants(matching: .any).matching(identifier: "markdown.table").firstMatch
        for _ in 0..<8 {
            if table.exists && table.isHittable && table.frame.maxY < input.frame.minY { break }
            scrollHistory(history, towardOlder: false)
        }
        XCTAssertTrue(table.exists && table.isHittable)
        XCTAssertLessThanOrEqual(table.frame.width, history.frame.width)
        XCTAssertEqual(app.webViews.count, 0, "Raw HTML in a Markdown message must not create a web view.")
        attach(app, name: "markdown-table-and-literal-html")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "markdown-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private func scrollHistory(_ history: XCUIElement, towardOlder: Bool) {
        // Keep vertical gestures in the text body's left gutter; a center swipe
        // can be captured by a nested code/table horizontal scroll view.
        let upper = history.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.28))
        let lower = history.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.62))
        if towardOlder { upper.press(forDuration: 0.05, thenDragTo: lower) }
        else { lower.press(forDuration: 0.05, thenDragTo: upper) }
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
