import XCTest
@testable import Cove

@MainActor
final class CoveLaunchPresentationTests: XCTestCase {
    func testColdLaunchCompletesOnlyOnce() {
        let presentation = CoveLaunchPresentation()
        XCTAssertTrue(presentation.isVisible)
        presentation.dismiss(reason: "completed")
        presentation.dismiss(reason: "backgrounded")
        XCTAssertFalse(presentation.isVisible)
        XCTAssertEqual(presentation.dismissalReason, "completed")
    }

    func testPreviewOrNotificationLaunchCanStartHidden() {
        let presentation = CoveLaunchPresentation(isVisible: false)
        XCTAssertFalse(presentation.isVisible)
        presentation.dismiss(reason: "completed")
        XCTAssertNil(presentation.dismissalReason)
    }

    func testBackgroundCancellationPermanentlyRemovesOverlay() {
        let presentation = CoveLaunchPresentation()
        presentation.dismiss(reason: "backgrounded")
        XCTAssertFalse(presentation.isVisible)
        XCTAssertEqual(presentation.dismissalReason, "backgrounded")
    }
}
