import XCTest
@testable import Cove

@MainActor
final class CoveWidgetViewTests: XCTestCase {
    func testSameIdentityReusesLocalDraftAndDoesNotReinitialize() {
        let key = UUID().uuidString
        let first = CoveWidgetSession.session(key: key, initial: ["answer": .string("")])
        first.state["answer"] = .string("本地草稿")
        let reappeared = CoveWidgetSession.session(key: key, initial: ["answer": .string("替换初始值")])
        XCTAssertTrue(first === reappeared)
        XCTAssertEqual(reappeared.state["answer"], .string("本地草稿"))
    }

    func testConversationMessageBlockAndSourceAreIsolated() {
        let prefix = UUID().uuidString
        let keys = ["chat-a/message-a/block-a/source-a", "chat-b/message-a/block-a/source-a",
                    "chat-a/message-b/block-a/source-a", "chat-a/message-a/block-b/source-a",
                    "chat-a/message-a/block-a/source-b"]
        let sessions = keys.map { CoveWidgetSession.session(key: prefix + $0, initial: ["value": .number(0)]) }
        sessions[0].state["value"] = .number(42)
        for session in sessions.dropFirst() {
            XCTAssertFalse(session === sessions[0])
            XCTAssertEqual(session.state["value"], .number(0))
        }
    }

    func testAcceptedSubmissionSurvivesRemountButNotOtherIdentity() {
        let key = UUID().uuidString
        let first = CoveWidgetSession.session(key: key, initial: [:])
        first.submitted = true
        XCTAssertTrue(CoveWidgetSession.session(key: key, initial: [:]).submitted)
        XCTAssertFalse(CoveWidgetSession.session(key: key + "other-source", initial: [:]).submitted)
    }

    func testCacheIsBoundedAndEvictedDraftIsNotClaimedPersistent() {
        let prefix = UUID().uuidString
        let old = CoveWidgetSession.session(key: prefix + "old", initial: ["n": .number(0)])
        old.state["n"] = .number(7)
        for index in 0..<128 { _ = CoveWidgetSession.session(key: prefix + String(index), initial: [:]) }
        let fresh = CoveWidgetSession.session(key: prefix + "old", initial: ["n": .number(0)])
        XCTAssertFalse(old === fresh)
        XCTAssertEqual(fresh.state["n"], .number(0))
    }

    func testRemoteMediaURLGuardWithoutPerformingNetworkRequests() throws {
        XCTAssertTrue(WidgetMediaHostPolicy.permitsURL(try XCTUnwrap(URL(string: "https://example.com/media.mp3"))))
        for raw in ["http://example.com/image.png", "file:///tmp/image.png", "https://localhost/image.png",
                    "https://a.local/image.png", "https://a.internal/image.png", "https://a.localhost/image.png",
                    "https://127.0.0.1/image.png", "https://192.168.1.1/image.png", "https://[::1]/image.png",
                    "https://user:password@example.com/image.png", "https://example.com:8443/image.png"] {
            XCTAssertFalse(WidgetMediaHostPolicy.permitsURL(try XCTUnwrap(URL(string: raw))), raw)
        }
    }
}
