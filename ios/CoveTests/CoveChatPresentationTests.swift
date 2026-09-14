import XCTest
@testable import Cove

final class CoveChatPresentationTests: XCTestCase {
    func testServiceAssistantReplyDoesNotCreateVisibleQuote() {
        let original = message(id: "user", role: "user")
        let reply = message(id: "assistant", role: "assistant", replyTo: original.id)
        XCTAssertNil(CoveChatPresentation.displayedQuote(reply, messagesByID: [original.id: original]))
    }

    func testExplicitUserQuoteRemainsVisible() {
        let original = message(id: "assistant", role: "assistant")
        let quote = message(id: "quoted-user", role: "user", replyTo: original.id)
        XCTAssertEqual(CoveChatPresentation.displayedQuote(quote, messagesByID: [original.id: original]), original)
        XCTAssertNil(CoveChatPresentation.displayedQuote(quote, messagesByID: [:]))
    }

    private func message(id: String, role: String, replyTo: String? = nil) -> ChatMessage {
        ChatMessage(id: id, conversationID: "preview", role: role, text: "引用正文", createdAt: Date(timeIntervalSince1970: 0), status: "complete", replyTo: replyTo)
    }
}
