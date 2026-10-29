import XCTest
import CryptoKit
@testable import Cove

@MainActor
final class CoveConnectionRecoveryTests: XCTestCase {
    private func eventually(_ predicate: () -> Bool, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }

    func testRecoveryHintInterruptsBackoffWithoutResettingConversation() async throws {
        let fixture = RecoveryFixture(retryDelays: [5])
        defer { fixture.close() }
        fixture.scenario.handshakeFailures = 1
        await fixture.store.connect()
        fixture.store.requestImmediateRecovery()
        try await eventually({ fixture.store.isConnected }, timeout: 1)
        XCTAssertEqual(fixture.scenario.count("conversations"), 2)
    }

    func testRecoveryHintDuringHungHandshakeCannotLeaveNoPollOwner() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.close() }
        fixture.scenario.holdHandshake = true
        let first = Task { await fixture.store.connect() }
        try await eventually { fixture.scenario.count("conversations") == 1 }
        fixture.scenario.holdHandshake = false
        for _ in 0..<10 { fixture.store.requestImmediateRecovery() }
        try await eventually { fixture.store.isConnected }
        await first.value
        XCTAssertEqual(fixture.scenario.count("conversations"), 2)
    }

    func testBackgroundRecoveryHintDoesNotStartNetworking() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.close() }
        await fixture.store.connect()
        fixture.store.suspend()
        let count = fixture.scenario.count("messages")
        fixture.store.requestImmediateRecovery()
        fixture.store.receiveRemoteNotification(conversationID: "fixture-conversation", openConversation: false)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(fixture.scenario.count("messages"), count)
        await fixture.store.resume()
        XCTAssertGreaterThan(fixture.scenario.count("messages"), count)
    }

    func testCursorBacklogDrainsImmediatelyInBoundedPages() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.close() }
        fixture.scenario.paginationTarget = 850
        await fixture.store.connect()
        XCTAssertEqual(fixture.scenario.count("messages"), 4, "Each pass must be bounded")
        XCTAssertEqual(fixture.scenario.messageCursors, ["0", "200", "400", "600"])
        try await eventually { fixture.scenario.messageCursors.contains("850") }
        XCTAssertTrue(fixture.store.isConnected)
    }

    func testMismatchedMessageScopeIsNotMergedOrAcknowledged() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.close() }
        fixture.scenario.badMessageConversation = true
        await fixture.store.connect()
        XCTAssertFalse(fixture.store.isConnected)
        XCTAssertTrue(fixture.store.messages.isEmpty)
        XCTAssertEqual(fixture.scenario.messageCursors, ["0"])
    }

    func testGatewayFailureRetriesWithoutClearingDurableCursor() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.close() }
        await fixture.store.connect()
        fixture.scenario.messageStatus = 502
        try await eventually { !fixture.store.isConnected }
        fixture.scenario.messageStatus = 200
        try await eventually { fixture.store.isConnected }
        XCTAssertTrue(fixture.scenario.messageCursors.dropFirst().allSatisfy { $0 == "7" })
    }

    func testNotificationHintDoesNotStealFocusButExplicitTapDoes() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.close() }
        fixture.scenario.offerOtherConversation = true
        await fixture.store.connect()
        fixture.store.selectedTab = 0
        fixture.store.receiveRemoteNotification(conversationID: "other-conversation", openConversation: false)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(fixture.store.selectedTab, 0)
        XCTAssertEqual(fixture.store.activeConversationID, "fixture-conversation")
        fixture.store.receiveRemoteNotification(conversationID: "other-conversation", openConversation: true)
        try await eventually { fixture.store.activeConversationID == "other-conversation" }
        XCTAssertEqual(fixture.store.selectedTab, 2)
    }

    func testNotificationTapBeforeInitialHandshakeSelectsAfterServerListArrives() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.close() }
        fixture.scenario.offerOtherConversation = true
        fixture.store.receiveRemoteNotification(conversationID: "other-conversation", openConversation: true)
        await fixture.store.connect()
        XCTAssertEqual(fixture.store.activeConversationID, "other-conversation")
        XCTAssertTrue(fixture.store.isConnected)
    }

    func testFirstHandshakeTimeoutRecoversWithoutResumeOrRestart() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.close() }
        fixture.scenario.handshakeFailures = 1
        await fixture.store.connect()
        XCTAssertFalse(fixture.store.isConnected)
        try await eventually { fixture.store.isConnected }
        XCTAssertEqual(fixture.scenario.count("conversations"), 2)
        XCTAssertGreaterThanOrEqual(fixture.scenario.count("messages"), 1)
    }

    func testPollingOutageRecoversWithoutLosingCursor() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.close() }
        await fixture.store.connect()
        fixture.scenario.failMessages = true
        try await eventually { !fixture.store.isConnected }
        fixture.scenario.failMessages = false
        try await eventually { fixture.store.isConnected }
        XCTAssertTrue(fixture.scenario.messageCursors.dropFirst().allSatisfy { $0 == "7" })
        XCTAssertEqual(fixture.scenario.count("conversations"), 1)
    }

    func testHungPanelsAndDeviceBridgeDoNotBlockChat() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.close() }
        fixture.scenario.holdAuxiliary = true
        await fixture.store.connect()
        XCTAssertTrue(fixture.store.isConnected)
        try await eventually { fixture.scenario.count("messages") >= 4 }
        XCTAssertEqual(fixture.scenario.count("pulse/dashboard"), 1, "Do not accumulate hung panel tasks")
        XCTAssertEqual(fixture.scenario.count("device-actions/device"), 1, "Do not accumulate hung device tasks")
    }

    func testHeldAttachmentUploadDoesNotBlockMessagePolling() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.close() }
        fixture.scenario.holdUploads = true
        await fixture.store.connect()
        let queued = await fixture.store.sendAttachments(files: [
            .init(data: Data("synthetic file".utf8), filename: "recovery.txt", mime: "text/plain")
        ], waitForDelivery: false)
        XCTAssertTrue(queued)
        try await eventually { fixture.scenario.count("attachments") == 1 }
        let previous = fixture.scenario.count("messages")
        try await eventually { fixture.scenario.count("messages") >= previous + 3 }
        XCTAssertTrue(fixture.store.isConnected)
        XCTAssertEqual(fixture.scenario.count("attachments"), 1, "A held upload must not be replayed")
    }

    func testSuspendCancelsHandshakeAndLateReplyCannotReviveIt() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.close() }
        fixture.scenario.holdHandshake = true
        let first = Task { await fixture.store.connect() }
        try await eventually { fixture.scenario.count("conversations") == 1 }
        fixture.store.suspend()
        fixture.scenario.releaseHeld()
        await first.value
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(fixture.store.isConnected)
        XCTAssertEqual(fixture.scenario.count("messages"), 0)
        fixture.scenario.holdHandshake = false
        await fixture.store.resume()
        try await eventually { fixture.store.isConnected }
    }

    func testRepeatedResumeDoesNotReplaceActivePollOwner() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.close() }
        await fixture.store.connect()
        for _ in 0..<8 { await fixture.store.resume() }
        try await eventually { fixture.scenario.count("messages") >= 3 }
        XCTAssertEqual(fixture.scenario.count("conversations"), 1)
        fixture.store.suspend()
        let before = fixture.scenario.count("messages")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fixture.scenario.count("messages"), before)
    }

    func testAuthenticationFailureDoesNotPretendToConnectOrSpin() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.close() }
        fixture.scenario.handshakeStatus = 401
        await fixture.store.connect()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(fixture.store.isConnected)
        XCTAssertEqual(fixture.scenario.count("conversations"), 1)
        XCTAssertEqual(fixture.scenario.count("messages"), 0)
        XCTAssertTrue(fixture.store.errorMessage?.contains("密钥") == true)
    }

    func testMalformedHandshakeDoesNotCreateFalseConnectedState() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.close() }
        fixture.scenario.malformedHandshake = true
        await fixture.store.connect()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(fixture.store.isConnected)
        XCTAssertEqual(fixture.scenario.count("conversations"), 1)
        XCTAssertEqual(fixture.scenario.count("messages"), 0)
    }

    func testEmptyConversationListRequiresActualCreationAndMessageResponse() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.close() }
        fixture.scenario.emptyConversations = true
        fixture.scenario.failMessages = true
        await fixture.store.connect()
        XCTAssertFalse(fixture.store.isConnected)
        XCTAssertEqual(fixture.scenario.count("create"), 1)
        fixture.scenario.failMessages = false
        try await eventually { fixture.store.isConnected }
        XCTAssertEqual(fixture.scenario.count("create"), 1, "A failed poll must not recreate a conversation")
    }

    func testSwitchEndpointRejectsLateOldHandshake() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.close() }
        fixture.scenario.holdHandshake = true
        let first = Task { await fixture.store.connect() }
        try await eventually { fixture.scenario.count("conversations") == 1 }
        fixture.store.serverURL = fixture.endpoint + "/replacement"
        fixture.scenario.holdHandshake = false
        await fixture.store.connect()
        fixture.scenario.releaseHeld()
        await first.value
        XCTAssertTrue(fixture.store.isConnected)
        XCTAssertEqual(fixture.store.serverURL, fixture.endpoint + "/replacement")
        XCTAssertEqual(fixture.store.activeConversationID, "fixture-conversation")
    }
}

@MainActor
private final class RecoveryFixture {
    let scenario = RecoveryScenario()
    let session: URLSession
    let store: CoveStore
    let endpoint = "https://connection-recovery-\(UUID().uuidString).invalid/cove"
    let previous = UserDefaults.standard.string(forKey: "cove.serverURL")
    init(retryDelays: [TimeInterval] = [0.03, 0.05]) {
        UserDefaults.standard.removeObject(forKey: "cove.serverURL")
        RecoveryProtocol.scenario = scenario
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryProtocol.self]
        session = URLSession(configuration: config)
        store = CoveStore(session: session, credentials: RecoveryCredentials(),
                          connectionPollInterval: 0.04, connectionRetryDelays: retryDelays)
        store.serverURL = endpoint
        store.accessToken = "synthetic-connection-recovery-token"
    }
    func close() {
        store.suspend(); session.invalidateAndCancel(); scenario.releaseHeld()
        RecoveryProtocol.scenario = nil
        if let previous { UserDefaults.standard.set(previous, forKey: "cove.serverURL") }
        else { UserDefaults.standard.removeObject(forKey: "cove.serverURL") }
        for url in [endpoint, endpoint + "/replacement"] {
            let hash = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cove")
            try? FileManager.default.removeItem(at: root.appendingPathComponent(hash + ".json"))
            try? FileManager.default.removeItem(at: root.appendingPathComponent(hash))
        }
    }
}

private final class RecoveryCredentials: CoveCredentialStore {
    func read(account: String) -> String? { nil }
    func write(_ token: String, account: String) throws { }
}

private final class RecoveryProtocol: URLProtocol {
    static var scenario: RecoveryScenario?
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.scenario?.receive(self) }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
    func reply(status: Int = 200, body: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    func fail() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
    }
}

private final class RecoveryScenario: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var counts: [String: Int] = [:]
    private var held: [RecoveryProtocol] = []
    private var cursors: [String] = []
    // Mutations happen between awaited Store operations; synchronize both reads
    // and writes because URLProtocol callbacks run on Foundation's transport queue.
    private var options: [String: Int] = [:]
    private func get(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return options[key, default: 0] }
    private func set(_ key: String, _ value: Int) { lock.lock(); defer { lock.unlock() }; options[key] = value }
    var handshakeFailures: Int { get { get("failures") } set { set("failures", newValue) } }
    var handshakeStatus: Int { get { get("status") == 0 ? 200 : get("status") } set { set("status", newValue) } }
    var failMessages: Bool { get { get("messages") == 1 } set { set("messages", newValue ? 1 : 0) } }
    var holdHandshake: Bool { get { get("hold") == 1 } set { set("hold", newValue ? 1 : 0) } }
    var holdAuxiliary: Bool { get { get("aux") == 1 } set { set("aux", newValue ? 1 : 0) } }
    var holdUploads: Bool { get { get("uploads") == 1 } set { set("uploads", newValue ? 1 : 0) } }
    var malformedHandshake: Bool { get { get("malformed") == 1 } set { set("malformed", newValue ? 1 : 0) } }
    var emptyConversations: Bool { get { get("empty") == 1 } set { set("empty", newValue ? 1 : 0) } }
    var paginationTarget: Int { get { get("target") } set { set("target", newValue) } }
    var messageStatus: Int { get { get("messageStatus") == 0 ? 200 : get("messageStatus") } set { set("messageStatus", newValue) } }
    var badMessageConversation: Bool { get { get("badScope") == 1 } set { set("badScope", newValue ? 1 : 0) } }
    var offerOtherConversation: Bool { get { get("other") == 1 } set { set("other", newValue ? 1 : 0) } }
    var messageCursors: [String] { lock.lock(); defer { lock.unlock() }; return cursors }
    func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[key, default: 0] }
    private var conversation: [String: Any] { ["id": "fixture-conversation", "title": "Fixture", "createdAt": "2026-09-13T00:00:00Z"] }
    func receive(_ transport: RecoveryProtocol) {
        lock.lock(); defer { lock.unlock() }
        let request = transport.request
        let path = request.url!.path.components(separatedBy: "/v1/").last!
        if path == "conversations", request.httpMethod == "POST" {
            counts["create", default: 0] += 1
            transport.reply(body: ["conversation": conversation]); return
        }
        counts[path, default: 0] += 1
        if path == "conversations" {
            if holdHandshake { held.append(transport); return }
            if handshakeFailures > 0 { handshakeFailures -= 1; transport.fail(); return }
            if handshakeStatus != 200 { transport.reply(status: handshakeStatus, body: ["error": "synthetic"]); return }
            if malformedHandshake { transport.reply(body: ["conversations": "invalid"]); return }
            let offered = offerOtherConversation ? [conversation, ["id": "other-conversation", "title": "Other", "createdAt": "2026-09-13T00:00:00Z"]] : [conversation]
            transport.reply(body: ["conversations": emptyConversations ? [] : offered,
                                   "activeConversationID": emptyConversations ? "" : "fixture-conversation"])
        } else if path == "messages" {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            cursors.append(query?.first(where: { $0.name == "after" })?.value ?? "")
            if failMessages { transport.fail() }
            else if messageStatus != 200 { transport.reply(status: messageStatus, body: ["error": "synthetic gateway failure"]) }
            else if badMessageConversation {
                transport.reply(body: ["messages": [["id": "wrong-scope", "conversationID": "wrong-conversation", "role": "assistant", "text": "synthetic", "createdAt": "2026-09-13T00:00:00Z", "status": "complete", "revision": 7]], "cursor": 7, "busy": false])
            } else {
                let after = Int(cursors.last ?? "0") ?? 0
                let cursor = paginationTarget > 0 ? min(after + 200, paginationTarget) : 7
                transport.reply(body: ["messages": [], "cursor": cursor, "busy": false])
            }
        } else if holdAuxiliary || (path == "attachments" && holdUploads) { held.append(transport) }
        else { transport.reply(status: 503, body: ["error": "synthetic auxiliary unavailable"]) }
    }
    func releaseHeld() {
        lock.lock(); let pending = held; held = []; lock.unlock()
        for item in pending { item.reply(body: ["conversations": [conversation], "activeConversationID": "stale-conversation"]) }
    }
}
