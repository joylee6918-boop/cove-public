import XCTest

@MainActor
final class CoveFileUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--preview", "--rich-preview"]
        app.launch()
        XCTAssertTrue(app.scrollViews["chat.history"].waitForExistence(timeout: 10))
    }

    override func tearDownWithError() throws {
        if let testRun, testRun.failureCount > 0 {
            screenshot("attachment-failure")
            attachHierarchy("attachment-failure-hierarchy")
        }
    }

    func testLocalHTMLInteractionSourceAndShare() throws {
        try openAttachment("file-preview-html")
        XCTAssertTrue(app.staticTexts["本地网页 · 外部资源不会加载"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["attachment.htmlReady"].waitForExistence(timeout: 15), "The web view must finish navigation before it accepts interaction.")
        let increment = app.webViews.buttons["点击回应"]
        XCTAssertTrue(increment.waitForExistence(timeout: 10), "The local HTML document must render its native web controls.")
        XCTAssertTrue(increment.isHittable)
        attachHierarchy("html-before-single-tap")
        increment.tap()
        attachHierarchy("html-after-single-tap")
        XCTAssertTrue(app.webViews.buttons["按钮已响应"].waitForExistence(timeout: 3), "Inline local JavaScript must work in the isolated preview.")
        screenshot("html-rendered")
        app.buttons["attachment.source"].tap()
        attachHierarchy("html-after-source-single-tap")
        let source = app.staticTexts["attachment.htmlSource"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue(source.label.contains("<button"), "Source mode should show the original file rather than a generated summary.")
        XCTAssertTrue(app.buttons["attachment.share"].isHittable)
        screenshot("html-source")
        app.buttons["attachment.share"].tap()
        XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 3) || app.buttons["拷贝"].exists || app.buttons["存储到“文件”"].exists || app.otherElements["ActivityListView"].exists,
                      "Sharing must open the native activity sheet.")
        screenshot("html-share")
    }

    func testImagePreviewAndPDFUseNativePresentation() throws {
        try openAttachment("file-preview-image")
        XCTAssertTrue(app.buttons["attachment.share"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.scrollViews["图片预览，可双指缩放或双击放大"].exists)
        screenshot("image-preview")
        app.buttons["attachment.done"].tap()
        try openAttachment("file-preview-pdf")
        XCTAssertTrue(app.buttons["attachment.share"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["暂不支持直接预览"].exists)
        // A Quick Look toolbar can appear before its remote PDF renderer loads.
        // Wait for actual fixture text, never the filename or an empty container.
        let pdfBody = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", "这是一份用于验证预览和分享的文件"
        )).firstMatch
        XCTAssertTrue(pdfBody.waitForExistence(timeout: 20), "Quick Look must load the PDF's actual body before the preview is considered ready.")
        screenshot("pdf-preview")
        attachHierarchy("pdf-loaded-hierarchy")
        app.buttons["attachment.done"].tap()
        XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 3))
    }

    func testPreviewNeverEnablesAttachmentSending() throws {
        XCTAssertTrue(app.buttons["chat.attachments"].exists)
        XCTAssertFalse(app.buttons["chat.attachments"].isEnabled)
        XCTAssertFalse(app.buttons["chat.send"].isEnabled)
    }

    private func openAttachment(_ id: String) throws {
        let card = app.buttons["chat.attachment.\(id)"]
        let history = app.scrollViews["chat.history"]
        for _ in 0..<12 {
            if card.exists && card.isHittable { break }
            history.swipeDown(velocity: .slow)
        }
        XCTAssertTrue(card.waitForExistence(timeout: 8), "Missing rich-preview attachment \(id).")
        XCTAssertTrue(card.isHittable)
        let ready = NSPredicate(format: "enabled == true")
        expectation(for: ready, evaluatedWith: card)
        waitForExpectations(timeout: 10)
        card.tap()
    }

    private func screenshot(_ name: String) {
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
