import XCTest
@testable import Cove

final class MessageDisplayTests: XCTestCase {
    func testStreamingMarkdownIsHeldUntilCompletionWithoutLosingSource() {
        let attachment = ChatAttachment(id: "file", filename: "demo.html", mime: "text/html", size: 42, url: "/v1/attachments/file")
        var source = ChatMessage(id: "reply", conversationID: "chat", role: "assistant", text: "```swift\nlet x =", createdAt: Date(), status: "streaming", attachments: [attachment])
        XCTAssertTrue(source.readyForDisplay.text.isEmpty)
        XCTAssertNil(source.readyForDisplay.attachments)
        XCTAssertEqual(source.text, "```swift\nlet x =", "The durable partial response remains intact")
        source.text += " 1\n```"
        source.status = "complete"
        XCTAssertEqual(source.readyForDisplay.text, "```swift\nlet x = 1\n```")
        XCTAssertEqual(source.readyForDisplay.attachments, [attachment])
    }

    func testInterruptedAndFailedResponsesKeepPartialContentVisible() {
        for status in ["interrupted", "failed"] {
            let source = ChatMessage(id: "reply", conversationID: "chat", role: "assistant", text: "已经收到的部分", createdAt: Date(), status: status)
            XCTAssertEqual(source.readyForDisplay.text, source.text)
            XCTAssertEqual(source.readyForDisplay.status, status)
        }
    }

    func testLegacyCachedMessageHasNoInventedReadOrReaction() throws {
        let bytes = Data(#"{"id":"old","conversationID":"chat","role":"user","text":"hello","createdAt":"2026-09-13T00:00:00Z","status":"sent"}"#.utf8)
        let message = try CoveJSON.decoder().decode(ChatMessage.self, from: bytes)
        XCTAssertNil(message.readAt)
        XCTAssertFalse(message.isLiked ?? false)
    }

    func testLateAckCannotUndoReadReceiptOrReaction() {
        let read = Date(timeIntervalSince1970: 100)
        let latest = ChatMessage(id: "message", conversationID: "chat", role: "user", text: "hello", createdAt: read, status: "sent", readAt: read, isLiked: true, revision: 20)
        var stale = latest
        stale.readAt = nil; stale.isLiked = false; stale.revision = 18
        XCTAssertEqual(latest.mergingServerUpdate(stale), latest)
        var cancelled = latest
        cancelled.isLiked = false; cancelled.revision = 21
        XCTAssertEqual(latest.mergingServerUpdate(cancelled).isLiked, false)
        stale.revision = nil
        XCTAssertEqual(latest.mergingServerUpdate(stale).readAt, read)
    }

    func testHiddenStreamingRevisionsDoNotInvalidateDisplayedMarkdown() {
        var first = ChatMessage(id: "reply", conversationID: "chat", role: "assistant", text: "```", createdAt: .distantPast, status: "streaming", revision: 1)
        let display = first.readyForDisplay
        first.text += "swift\nlet x = 1"; first.revision = 2
        XCTAssertEqual(display, first.readyForDisplay)
    }
}
