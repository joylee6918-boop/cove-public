import XCTest
import CryptoKit
@testable import Cove

@MainActor
final class SessionHandoffTests: XCTestCase {
    func testCompactionFieldsAreOptionalAndReminderStartsAtTwo() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = Data(#"{"conversationID":"old","switchAtTokens":200000}"#.utf8)
        let unknown = try decoder.decode(CoveSessionContext.self, from: legacy)
        XCTAssertNil(unknown.compactionCount)
        XCTAssertNil(unknown.compactionReminder)
        for count in [0, 1, 2, 12] {
            let body = "{\"conversationID\":\"old\",\"switchAtTokens\":200000,\"compactionCount\":\(count),\"lastCompactedAt\":\"2026-10-10T02:00:00Z\"}"
            let context = try decoder.decode(CoveSessionContext.self, from: Data(body.utf8))
            XCTAssertEqual(context.compactionCount, count)
            XCTAssertEqual(context.compactionReminder != nil, count >= 2)
            XCTAssertNotNil(context.lastCompactedAt)
        }
    }

    func testUsageUnknownIsNotZeroAndThresholdIsContextNotLifetime() throws {
        let unknown = CoveSessionContext(conversationID: "old", threadID: nil, usedTokens: nil,
            contextWindow: nil, switchAtTokens: 200_000, updatedAt: nil, source: nil, error: nil)
        XCTAssertNil(unknown.progress)
        XCTAssertFalse(unknown.recommendsSwitch)
        let context = CoveSessionContext(conversationID: "old", threadID: "thread", usedTokens: 201_000,
            contextWindow: 1_000_000, switchAtTokens: 200_000, updatedAt: Date(), source: "codex.last.totalTokens", error: nil)
        XCTAssertEqual(context.progress, 1)
        XCTAssertTrue(context.recommendsSwitch)
    }

    func testHandoffTimeoutReusesIDAndWaitsForCompleteWithoutLosingDraft() async throws {
        try await withStore { store, scenario in
            store.draft = "旧窗草稿不能丢"
            scenario.loseFirstResponse = true
            await store.beginSessionHandoff()
            XCTAssertEqual(store.activeConversationID, "old")
            XCTAssertTrue(store.isSwitchingSession)
            XCTAssertNotNil(store.handoffError)
            await store.beginSessionHandoff()
            XCTAssertEqual(scenario.postedIDs.count, 2)
            XCTAssertEqual(scenario.postedIDs.first, scenario.postedIDs.last)
            XCTAssertEqual(store.activeConversationID, "old")
            XCTAssertEqual(store.draft, "旧窗草稿不能丢")
            XCTAssertFalse(store.canSendMessages)
            scenario.phase = "restoring"
            await store.refreshSessionContext()
            XCTAssertEqual(store.activeConversationID, "old")
            scenario.phase = "complete"
            await store.refreshSessionContext()
            XCTAssertEqual(store.activeConversationID, "new")
            XCTAssertEqual(store.sessionContext?.conversationID, "new")
            await store.selectConversation("old")
            XCTAssertEqual(store.draft, "旧窗草稿不能丢")
            XCTAssertEqual(store.activeConversationID, "old", "Completed historical handoff must not force another switch")
        }
    }

    func testFailedMemoryReceiptLeavesOldWindowAndAllowsDeliberateRetry() async throws {
        try await withStore { store, scenario in
            await store.beginSessionHandoff()
            scenario.phase = "failed"
            await store.refreshSessionContext()
            XCTAssertEqual(store.activeConversationID, "old")
            XCTAssertFalse(store.isSwitchingSession)
            XCTAssertNotNil(store.handoffError)
            scenario.phase = "saving"
            await store.beginSessionHandoff()
            XCTAssertEqual(scenario.postedIDs.count, 2)
            XCTAssertNotEqual(scenario.postedIDs.first, scenario.postedIDs.last)
        }
    }

    func testExplicitBusyRejectionDoesNotLockComposer() async throws {
        try await withStore { store, scenario in
            scenario.reject = true
            await store.beginSessionHandoff()
            XCTAssertEqual(store.activeConversationID, "old")
            XCTAssertFalse(store.isSwitchingSession)
            XCTAssertTrue(store.canSendMessages)
        }
    }

    private func withStore(_ work: (CoveStore, HandoffScenario) async throws -> Void) async throws {
        let keys = ["cove.serverURL", "cove.notifications"]
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        let endpoint = "https://handoff-\(UUID().uuidString).invalid/cove"
        let scenario = HandoffScenario()
        HandoffProtocol.handler = scenario.reply
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HandoffProtocol.self]
        let session = URLSession(configuration: config)
        let store = CoveStore(session: session, credentials: HandoffCredentials())
        defer {
            store.suspend(); session.invalidateAndCancel(); HandoffProtocol.handler = nil
            for (index, key) in keys.enumerated() {
                if let value = previous[index] { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            let hash = SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cove")
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(hash + ".json"))
        }
        store.serverURL = endpoint; store.accessToken = "synthetic-handoff-test"
        await store.connect()
        store.suspend()
        XCTAssertTrue(store.isConnected)
        XCTAssertEqual(store.sessionContext?.usedTokens, 199_000)
        try await work(store, scenario)
    }
}

private final class HandoffCredentials: CoveCredentialStore {
    func read(account: String) -> String? { nil }
    func write(_ token: String, account: String) throws { }
}
private final class HandoffProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
private final class HandoffScenario: @unchecked Sendable {
    var phase = "saving"
    var postedIDs: [String] = []
    var loseFirstResponse = false
    var reject = false
    private let date = "2026-09-16T00:00:00Z"
    func reply(_ request: URLRequest) throws -> (Int, Data) {
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
        let path = request.url!.path
        var value: [String: Any] = [:]
        if path.hasSuffix("/conversations") {
            value = ["conversations": [["id": "old", "title": "旧", "createdAt": date], ["id": "new", "title": "新", "createdAt": date]], "activeConversationID": "old"]
        } else if path.hasSuffix("/messages") {
            value = ["messages": [], "cursor": 0, "busy": false]
        } else if path.hasSuffix("/context") {
            value = ["conversationID": path.contains("/old/") ? "old" : "new", "usedTokens": 199_000, "switchAtTokens": 200_000, "updatedAt": date, "handoffAvailable": true]
        } else if path.hasSuffix("/handoff") {
            if request.httpMethod == "POST" {
                if reject { return (409, Data("{\"error\":\"busy\"}".utf8)) }
                postedIDs.append(body["id"] as! String)
                if loseFirstResponse { loseFirstResponse = false; throw URLError(.networkConnectionLost) }
            }
            guard let id = postedIDs.last, path.contains("/old/") else { return (200, Data("null".utf8)) }
            value = ["id": id, "sourceConversationID": "old", "targetConversationID": "new", "status": phase, "createdAt": date, "updatedAt": date]
            if phase == "failed" { value["error"] = "未确认记忆回执" }
        } else { return (503, Data("{}".utf8)) }
        return (200, try JSONSerialization.data(withJSONObject: value))
    }
}
