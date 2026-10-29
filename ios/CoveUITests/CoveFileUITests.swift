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

    func testPhotoEntryOpensSystemPickerWithoutIntermediatePanel() {
        app.terminate()
        app.launchArguments = ["--preview", "--test-native-photo-picker"]
        app.launch()
        let entry = app.buttons["chat.attachments"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        let photoAction = app.buttons["chat.attachments.photos"]
        XCTAssertTrue(photoAction.waitForExistence(timeout: 3))
        photoAction.tap()
        let photos = app.navigationBars["Photos"]
        let chinesePhotos = app.navigationBars["照片"]
        XCTAssertTrue(photos.waitForExistence(timeout: 8) || chinesePhotos.exists)
        XCTAssertFalse(app.otherElements["attachments.panel"].exists)
        XCTAssertFalse(app.buttons["attachments.camera"].exists)
        screenshot("native-photos-direct")
        attachHierarchy("native-photos-direct")
        let cancel = app.buttons.matching(NSPredicate(format: "label == 'Cancel' OR label == '取消' OR label == 'Close' OR label == '关闭'")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        cancel.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["attachments.panel"].exists,
                       "Cancelling Photos must return to chat, never an empty second sheet")
    }

    func testAttachmentMenuOpensNativeFilesAndCancelReturnsToChat() {
        app.terminate()
        app.launchArguments = ["--preview", "--test-native-file-picker"]
        app.launch()
        let entry = app.buttons["chat.attachments"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["chat.files"].exists, "Composer must have only one attachment entry")
        screenshot("single-attachment-button")
        entry.tap()
        let files = app.buttons["chat.attachments.files"]
        XCTAssertTrue(files.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["chat.attachments.photos"].isHittable)
        screenshot("attachment-photo-file-menu")
        files.tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label == 'Cancel' OR label == '取消'")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8))
        XCTAssertFalse(app.otherElements["attachments.panel"].exists)
        XCTAssertFalse(app.navigationBars["Photos"].exists)
        screenshot("native-files-direct")
        attachHierarchy("native-files-direct")
        cancel.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["attachments.panel"].exists)
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

    func testAttachmentPanelSwitchesCategoryWithoutSending() throws {
        let input = app.textFields["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        input.tap()
        input.typeText("附件面板草稿")

        let attachments = app.buttons["chat.attachments"]
        XCTAssertTrue(attachments.isHittable)
        attachments.tap()
        app.buttons["chat.attachments.photos"].tap()
        XCTAssertTrue(app.otherElements["attachments.panel"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["界面预览 · 不读取或上传相册"].exists)
        XCTAssertTrue(app.buttons["attachments.browsePhotos"].exists)
        XCTAssertFalse(app.buttons["attachments.browsePhotos"].isEnabled, "Preview must not access the real system photo library")
        XCTAssertEqual(app.staticTexts["attachments.title"].label, "照片")
        XCTAssertFalse(app.buttons["attachments.confirmSend"].exists)
        assertAttachmentHeaderTouchesGrid()
        screenshot("attachment-panel-photos")

        let files = app.buttons["attachments.files"]
        XCTAssertTrue(files.isHittable)
        files.tap()
        XCTAssertTrue(files.isSelected)
        XCTAssertTrue(app.staticTexts["界面预览 · 不读取文件"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["attachments.browseFiles"].isEnabled)
        XCTAssertFalse(app.buttons["attachments.confirmSend"].exists)
        screenshot("attachment-panel-files")

        app.buttons["attachments.photos"].tap()
        XCTAssertTrue(app.buttons["attachments.photos"].isSelected)
        XCTAssertTrue(app.staticTexts["界面预览 · 不读取或上传相册"].waitForExistence(timeout: 3))
        app.buttons["attachments.close"].tap()
        XCTAssertTrue(app.otherElements["attachments.panel"].waitForNonExistence(timeout: 3))
        XCTAssertEqual(input.value as? String, "附件面板草稿")
        XCTAssertFalse(app.buttons["chat.send"].isEnabled)
    }

    func testAttachmentHeaderAndGridMoveTogetherAcrossSheetDetents() {
        app.buttons["chat.attachments"].tap()
        app.buttons["chat.attachments.photos"].tap()
        let panel = app.otherElements["attachments.panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        assertAttachmentHeaderTouchesGrid()
        let before = app.buttons["attachments.close"].frame.minY
        let title = app.staticTexts["attachments.title"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        title.press(forDuration: 0.05, thenDragTo: title.withOffset(CGVector(dx: 0, dy: -300)))
        expectation(for: NSPredicate { _, _ in
            self.app.buttons["attachments.close"].frame.minY < before - 60
        }, evaluatedWith: panel)
        waitForExpectations(timeout: 4)
        assertAttachmentHeaderTouchesGrid()
        app.buttons["attachments.files"].tap()
        let close = app.buttons["attachments.close"]
        let files = app.scrollViews["attachments.fileList"]
        XCTAssertTrue(files.exists)
        XCTAssertLessThanOrEqual(files.frame.minY - close.frame.maxY, 20)
        screenshot("attachment-single-surface-expanded")
    }

    private func assertAttachmentHeaderTouchesGrid(file: StaticString = #filePath, line: UInt = #line) {
        let close = app.buttons["attachments.close"]
        let grid = app.scrollViews["attachments.photoGrid"]
        let camera = app.buttons["attachments.camera"]
        XCTAssertTrue(close.waitForExistence(timeout: 3), file: file, line: line)
        XCTAssertTrue(grid.exists, file: file, line: line)
        XCTAssertFalse(camera.exists, "In-app camera entry has been removed", file: file, line: line)
        // iOS 26 inset sheets scale their entire content in screen coordinates.
        // Measure the local 44pt target, not the transformed ~42pt snapshot.
        let sheetScale = grid.frame.width / app.frame.width
        XCTAssertGreaterThanOrEqual(close.frame.height / sheetScale, 43.5, file: file, line: line)
        XCTAssertLessThan(close.frame.midX, app.frame.midX, file: file, line: line)
        XCTAssertGreaterThanOrEqual(grid.frame.minY, close.frame.maxY, file: file, line: line)
        XCTAssertLessThanOrEqual(grid.frame.minY - close.frame.maxY, 20,
                                 "Close belongs to the panel header immediately above its grid, not a separate full-screen header", file: file, line: line)
        XCTAssertTrue(app.buttons["attachments.photos"].isHittable, file: file, line: line)
        XCTAssertTrue(app.buttons["attachments.files"].isHittable, file: file, line: line)
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
