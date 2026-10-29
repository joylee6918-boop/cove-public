import XCTest
import SwiftUI
import CryptoKit
import Combine
@testable import Cove

@MainActor
final class CoveHistorySearchTests: XCTestCase {
    func testComposerKeystrokesDoNotPublishWholeStore() {
        let store = CoveStore()
        var storeChanges = 0
        var composerChanges = 0
        let storeToken = store.objectWillChange.sink { storeChanges += 1 }
        let composerToken = store.composerDraft.objectWillChange.sink { composerChanges += 1 }

        store.draft = "a"
        store.draft = "ab"

        XCTAssertEqual(storeChanges, 0)
        XCTAssertEqual(composerChanges, 2)
        XCTAssertEqual(store.draft, "ab")
        withExtendedLifetime((storeToken, composerToken)) {}
    }

    func testComposerConversationActivationKeepsDraftOwnershipExplicit() {
        let state = CoveComposerDraftState(text: "first", conversationID: "one")
        state.activate(conversationID: "two", text: "second")
        XCTAssertEqual(state.conversationID, "two")
        XCTAssertEqual(state.text, "second")
    }

    func testConfirmedLocalSummaryPreservesDraftAndOnlyOpensComposer() {
        let store = CoveStore()
        store.selectedTab = 0
        store.draft = "原来的草稿"
        let messages = store.messages

        store.placeInComposerDraft("已确认的账本摘要")

        XCTAssertEqual(store.draft, "原来的草稿\n\n已确认的账本摘要")
        XCTAssertEqual(store.selectedTab, 2)
        XCTAssertEqual(store.messages, messages, "Preparing a draft must never send or synthesize a message.")
    }

    func testDraftSidecarCannotResurrectDraftAfterDurableSend() throws {
        let stale = CoveDraftSnapshot(revision: 4, drafts: ["chat": "already sent"])
        XCTAssertEqual(stale.restoring(over: ["chat": ""], cacheRevision: 5)["chat"], "")
        XCTAssertEqual(stale.restoring(over: ["chat": ""], cacheRevision: 4)["chat"], "")
        XCTAssertEqual(stale.restoring(over: [:], cacheRevision: 0)["chat"], "already sent")
    }

    func testDraftIOLeavesHistoryUntouchedAndKeepsNewestWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = directory.appendingPathComponent("history.json")
        let drafts = directory.appendingPathComponent("drafts.json")
        let original = Data("synthetic history".utf8)
        try original.write(to: history)
        let io = CoveChatCacheIO()
        for revision in 1...20 {
            io.write(CoveDraftSnapshot(revision: UInt64(revision), drafts: ["chat": "draft-\(revision)"]), to: drafts) { error in
                XCTAssertNil(error)
            }
        }
        io.flush()
        XCTAssertEqual(try Data(contentsOf: history), original)
        let saved = try JSONDecoder().decode(CoveDraftSnapshot.self, from: XCTUnwrap(io.read(drafts)))
        XCTAssertEqual(saved.revision, 20)
        XCTAssertEqual(saved.drafts["chat"], "draft-20")
    }

    func testLiteralUnicodeHighlightPreservesSourceAndMatchesEveryOccurrence() {
        let source = "用户👨‍👩‍👧‍👦 Alpha %_ alpha 用户"
        XCTAssertEqual(CoveSearchHighlight.ranges(in: source, query: "用户").map { String(source[$0]) }, ["用户", "用户"])
        XCTAssertEqual(CoveSearchHighlight.ranges(in: source, query: "ALPHA").count, 2)
        XCTAssertEqual(CoveSearchHighlight.ranges(in: source, query: "%_").count, 1)
        XCTAssertTrue(CoveSearchHighlight.ranges(in: source, query: ".*").isEmpty)
        XCTAssertTrue(CoveSearchHighlight.ranges(in: source, query: "  ").isEmpty)
        XCTAssertEqual(String(CoveSearchHighlight.text(source, query: "Alpha").characters), source)
        XCTAssertEqual(CoveSearchHighlight.text(source, query: "Alpha").runs.filter { $0.backgroundColor != nil }.count, 2)
    }

    func testCalendarStrictDatesAndLocalDayBoundary() {
        XCTAssertTrue(CoveChatCalendarDates.valid("2028-02-29", pattern: "yyyy-MM-dd", timeZone: "Asia/Shanghai"))
        for value in ["2026-02-29", "2026-2-01", "2026-09-32", "not-a-date"] {
            XCTAssertFalse(CoveChatCalendarDates.valid(value, pattern: "yyyy-MM-dd", timeZone: "Asia/Shanghai"))
        }
        XCTAssertFalse(CoveChatCalendarDates.valid("2026-09", pattern: "yyyy-MM", timeZone: "invalid-time-zone"))
        let stamp = ISO8601DateFormatter().date(from: "2026-09-21T16:00:00Z")!
        XCTAssertEqual(CoveChatCalendarDates.formatter("yyyy-MM-dd", timeZone: "Asia/Shanghai").string(from: stamp), "2026-09-22")
    }

    func testActualStoreCalendarDateSearchAndLocatedHighlight() async throws {
        let previous = UserDefaults.standard.string(forKey: "cove.serverURL")
        UserDefaults.standard.removeObject(forKey: "cove.serverURL")
        let endpoint = "https://history-\(UUID().uuidString).invalid/cove"
        let scenario = HistoryScenario()
        HistoryProtocol.handler = scenario.reply
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HistoryProtocol.self]
        let session = URLSession(configuration: config)
        let store = CoveStore(session: session, credentials: HistoryCredentials())
        defer {
            store.suspend(); session.invalidateAndCancel(); HistoryProtocol.handler = nil
            if let previous { UserDefaults.standard.set(previous, forKey: "cove.serverURL") }
            else { UserDefaults.standard.removeObject(forKey: "cove.serverURL") }
            let hash = SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cove")
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(hash + ".json"))
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(hash + ".drafts.json"))
        }
        store.serverURL = endpoint; store.accessToken = "isolated-history-fixture"
        await store.connect()
        XCTAssertTrue(store.isConnected)
        store.draft = "draft must survive"
        let calendar = try await store.messageCalendar(month: "2026-09", query: "用户", timeZone: "Asia/Shanghai")
        XCTAssertEqual(calendar.days.first?.date, "2026-09-22")
        XCTAssertEqual(calendar.days.first?.count, 2)
        let page = try await store.searchMessages(query: "", before: nil, date: "2026-09-22", timeZone: "Asia/Shanghai")
        XCTAssertEqual(page.results.first?.messageID, "fixture-message")
        await store.locateMessage(conversationID: "fixture-conversation", messageID: "fixture-message", highlightQuery: "用户")
        XCTAssertEqual(store.messageHighlight?.query, "用户")
        XCTAssertEqual(store.scrollRequest?.messageID, "fixture-message")
        XCTAssertEqual(store.draft, "draft must survive")
        XCTAssertEqual(store.searchReturnConversationID, "fixture-conversation")
        let completed = try XCTUnwrap(store.scrollRequest)
        store.completeScrollRequest(completed)
        XCTAssertNil(store.scrollRequest, "Completed locate must not replay on re-entry")
        XCTAssertNil(store.locateInFlightMessageID)
        store.clearMessageHighlight()
        XCTAssertNil(store.messageHighlight)
        XCTAssertNotNil(store.searchReturnConversationID, "Clearing highlight must retain the return route")
        await store.returnFromMessageSearch()
        XCTAssertNil(store.searchReturnConversationID)
        XCTAssertEqual(store.draft, "draft must survive")

        scenario.currentConversationID = "current-conversation"
        await store.connect()
        await store.selectConversation("current-conversation")
        store.draft = "today draft"
        await store.locateMessage(conversationID: "fixture-conversation", messageID: "fixture-message")
        XCTAssertEqual(store.activeConversationID, "fixture-conversation")
        XCTAssertEqual(store.searchReturnConversationID, "current-conversation")
        XCTAssertEqual(store.draft, "draft must survive")
        // A second search must not replace the original return destination.
        await store.locateMessage(conversationID: "fixture-conversation", messageID: "fixture-message")
        XCTAssertEqual(store.searchReturnConversationID, "current-conversation")
        await store.returnFromMessageSearch()
        XCTAssertEqual(store.activeConversationID, "current-conversation")
        XCTAssertEqual(store.draft, "today draft")
        XCTAssertNil(store.scrollRequest)
        XCTAssertNil(store.messageHighlight)
        XCTAssertNil(store.locateInFlightMessageID)
        XCTAssertNil(store.searchReturnConversationID)
        // Reconnect must not erase the search return route or strand the old view.
        await store.locateMessage(conversationID: "fixture-conversation", messageID: "fixture-message")
        await store.connect()
        XCTAssertEqual(store.searchReturnConversationID, "current-conversation")
        XCTAssertTrue(store.canReturnToCurrentChat)
        store.suspend()
        let restored = CoveStore(session: session, credentials: HistoryCredentials())
        restored.accessToken = "isolated-history-fixture"
        XCTAssertEqual(restored.activeConversationID, "fixture-conversation")
        XCTAssertEqual(restored.searchReturnConversationID, "current-conversation")
        await restored.connect()
        await restored.returnFromMessageSearch()
        XCTAssertEqual(restored.activeConversationID, "current-conversation")
        XCTAssertEqual(restored.draft, "today draft")
        XCTAssertNotNil(restored.latestMessageRequest)
        XCTAssertFalse(restored.canReturnToCurrentChat)
        // Simulate upgrading an old app cache: viewed history is persisted but
        // there is no saved return route or canonical current conversation.
        await restored.selectConversation("fixture-conversation")
        restored.suspend()
        let hash = SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cove").appendingPathComponent(hash + ".json")
        var oldCache = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        oldCache.removeValue(forKey: "searchReturnConversationID")
        oldCache.removeValue(forKey: "currentConversationID")
        try JSONSerialization.data(withJSONObject: oldCache).write(to: url, options: .atomic)
        let upgraded = CoveStore(session: session, credentials: HistoryCredentials())
        upgraded.accessToken = "isolated-history-fixture"
        XCTAssertNil(upgraded.searchReturnConversationID)
        await upgraded.connect()
        XCTAssertEqual(upgraded.activeConversationID, "fixture-conversation", "Don't silently switch the reading position")
        XCTAssertTrue(upgraded.canReturnToCurrentChat, "Old caches must still expose a return button")
        await upgraded.returnFromMessageSearch()
        XCTAssertEqual(upgraded.activeConversationID, "current-conversation")
        XCTAssertEqual(upgraded.draft, "today draft")
        XCTAssertNotNil(upgraded.latestMessageRequest)
        upgraded.suspend()
        // Empty keyword without a date remains invalid, never an accidental dump.
        do { _ = try await store.searchMessages(query: "", before: nil); XCTFail("Expected validation") } catch { }
        // Preview calendar is synthetic only; it must not leak the connected cache.
        store.enablePreview()
        let preview = try await store.messageCalendar(month: "2026-09", query: "PRIVATE_FIXTURE", timeZone: "Asia/Shanghai")
        XCTAssertTrue(preview.days.isEmpty)
    }
}

private final class HistoryCredentials: CoveCredentialStore {
    func read(account: String) -> String? { nil }
    func write(_ token: String, account: String) throws { }
}

private final class HistoryProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

private final class HistoryScenario: @unchecked Sendable {
    var currentConversationID = "fixture-conversation"
    func reply(_ request: URLRequest) throws -> (Int, Data) {
        let path = request.url!.path
        let query = Dictionary((URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer isolated-history-fixture")
        let result: [String: Any]
        switch path {
        case "/cove/v1/conversations":
            result = ["conversations": [["id": "fixture-conversation", "title": "Fixture", "createdAt": "2026-09-22T00:00:00Z"], ["id": "current-conversation", "title": "Current", "createdAt": "2026-10-10T00:00:00Z"]], "activeConversationID": currentConversationID]
        case "/cove/v1/messages" where query["conversationID"] == "current-conversation":
            result = ["messages": [], "cursor": 0, "busy": false]
        case "/cove/v1/messages":
            result = ["messages": [["id": "fixture-message", "conversationID": "fixture-conversation", "role": "assistant", "text": "用户 PRIVATE_FIXTURE", "createdAt": "2026-09-22T00:00:00Z", "status": "complete"]], "cursor": 1, "busy": false]
        case "/cove/v1/messages/calendar":
            XCTAssertEqual(query["month"], "2026-09"); XCTAssertEqual(query["timeZone"], "Asia/Shanghai"); XCTAssertEqual(query["q"], "用户")
            result = ["month": "2026-09", "timeZone": "Asia/Shanghai", "query": "用户", "firstMonth": "2026-08", "lastMonth": "2026-09", "days": [["date": "2026-09-22", "count": 2]]]
        case "/cove/v1/messages/search":
            XCTAssertEqual(query["q"], ""); XCTAssertEqual(query["date"], "2026-09-22"); XCTAssertEqual(query["timeZone"], "Asia/Shanghai")
            result = ["query": "", "date": "2026-09-22", "timeZone": "Asia/Shanghai", "results": [["conversationID": "fixture-conversation", "conversationTitle": "Fixture", "messageID": "fixture-message", "role": "assistant", "snippet": "用户", "createdAt": "2026-09-22T00:00:00Z"]]]
        default: return (503, Data("{}".utf8))
        }
        return (200, try JSONSerialization.data(withJSONObject: result))
    }
}
