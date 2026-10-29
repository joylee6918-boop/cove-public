import XCTest

@MainActor
final class CoveVoiceNoteUITests: XCTestCase {
    func testWholeInputVoiceModePreservesDraftAndCannotRecordInPreview() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview"]
        app.launch()
        let input = app.textFields["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertEqual(app.tabBars.firstMatch.buttons.count, 5)
        let toggle = app.buttons["chat.voiceMode"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(toggle.frame.width, 44)
        XCTAssertGreaterThanOrEqual(toggle.frame.height, 44)
        XCTAssertFalse(app.buttons["chat.voice"].exists, "No independent microphone remains in the composer.")
        input.tap()
        input.typeText("尚未发送的草稿")
        XCTAssertTrue(app.buttons["chat.send"].waitForExistence(timeout: 3))
        toggle.tap()
        let hold = app.buttons["chat.voiceHold"]
        XCTAssertTrue(hold.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(hold.frame.width, 160)
        XCTAssertGreaterThanOrEqual(hold.frame.height, 44)
        XCTAssertFalse(hold.isEnabled, "Preview must not open the real microphone or upload audio.")
        XCTAssertFalse(input.exists)
        XCTAssertFalse(app.buttons["chat.send"].exists, "The whole voice field is the hold/release target, not a separate Send button.")
        hold.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(app.buttons["voice.start"].exists, "A preview tap must not open the real recorder.")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "cove-whole-input-voice-mode-preview"
        shot.lifetime = .keepAlways
        add(shot)
        toggle.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        XCTAssertEqual(input.value as? String, "尚未发送的草稿")
        XCTAssertFalse(hold.exists)
    }
}
