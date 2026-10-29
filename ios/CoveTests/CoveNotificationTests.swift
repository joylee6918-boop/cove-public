import XCTest
import UserNotifications
import CryptoKit
@testable import Cove

@MainActor
final class CoveNotificationTests: XCTestCase {
    func testColdLaunchTapIsRetainedUntilStoreExistsAndNotOverwrittenByHint() {
        let delegate = CoveAppDelegate()
        delegate.receiveNotification(conversationID: "tapped-conversation", openConversation: true)
        delegate.receiveNotification(conversationID: "foreground-hint", openConversation: false)
        XCTAssertEqual(delegate.pendingNotificationConversationID, "tapped-conversation")
    }

    func testForegroundPresentationHasNoBannerSoundBadgeOrList() {
        XCTAssertEqual(CoveAppDelegate.foregroundPresentationOptions, [])
    }

    func testLatestPrivacyChoiceIsSerializedAfterAnInFlightContentRegistration() async throws {
        let endpoint = "https://notification-test-\(UUID().uuidString.lowercased()).invalid/cove"
        let keys = ["cove.serverURL", "cove.notifications", "cove.notificationPreviewMode"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        UserDefaults.standard.removeObject(forKey: keys[0])
        UserDefaults.standard.set(false, forKey: keys[1])
        UserDefaults.standard.set("unknown-future-mode", forKey: keys[2])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NotificationProtocol.self]
        let session = URLSession(configuration: configuration)
        let scenario = NotificationScenario()
        NotificationProtocol.scenario = scenario
        let store = CoveStore(session: session, credentials: NotificationCredentials())
        defer {
            store.suspend(); session.invalidateAndCancel(); NotificationProtocol.scenario = nil
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            let hash = SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cove")
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(hash + ".json"))
        }
        XCTAssertEqual(store.notificationPreviewMode, "generic", "Unknown saved values must fail private.")
        store.serverURL = endpoint
        store.accessToken = "synthetic-notification-token-not-a-real-account"
        await store.connect()
        XCTAssertTrue(store.isConnected)
        store.notificationsEnabled = true
        store.notificationPreviewMode = "content"
        let started = expectation(description: "First content request in flight")
        scenario.firstRegistration = { started.fulfill() }
        let first = Task { await store.registerDevice(String(repeating: "a", count: 64)) }
        await fulfillment(of: [started], timeout: 3)
        store.notificationPreviewMode = "generic"
        await store.registerDevice(String(repeating: "a", count: 64))
        await first.value
        XCTAssertEqual(scenario.modes, ["content", "generic"])
        XCTAssertEqual(scenario.methods, ["POST", "POST"])
        XCTAssertNil(store.notificationSyncError)

        scenario.failRegistration = true
        await store.registerDevice(String(repeating: "a", count: 64))
        XCTAssertNotNil(store.notificationSyncError, "A failed privacy update must not claim success.")
        scenario.failRegistration = false
        store.notificationsEnabled = false
        await store.registerDevice(String(repeating: "a", count: 64))
        XCTAssertEqual(scenario.methods.last, "DELETE")
        XCTAssertNil(store.notificationSyncError)
    }
}

private final class NotificationCredentials: CoveCredentialStore {
    private var values: [String: String] = [:]
    func read(account: String) -> String? { values[account] }
    func write(_ token: String, account: String) throws { values[account] = token }
}

private final class NotificationProtocol: URLProtocol {
    static var scenario: NotificationScenario?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let scenario = Self.scenario else { return }
        let (code, body, delay) = scenario.response(request)
        let deliver = { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if delay { DispatchQueue.global().asyncAfter(deadline: .now() + 0.15, execute: deliver) }
        else { deliver() }
    }
    override func stopLoading() {}
}

private final class NotificationScenario: @unchecked Sendable {
    private let lock = NSLock()
    var firstRegistration: (() -> Void)?
    var failRegistration = false
    private(set) var modes: [String] = []
    private(set) var methods: [String] = []

    func response(_ request: URLRequest) -> (Int, Data, Bool) {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path
        if path.hasSuffix("/devices") {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 2048)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
            }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            modes.append(body?["previewMode"] as? String ?? "MISSING")
            methods.append(request.httpMethod ?? "MISSING")
            let first = modes.count == 1
            if first { firstRegistration?() }
            return (failRegistration ? 503 : 200, Data((failRegistration ? "{\"error\":\"synthetic failure\"}" : "{\"ok\":true}").utf8), first)
        }
        if path.hasSuffix("/conversations") {
            return (200, Data("{\"conversations\":[{\"id\":\"notification-fixture\",\"title\":\"测试\",\"createdAt\":\"2026-09-16T00:00:00Z\"}],\"activeConversationID\":\"notification-fixture\"}".utf8), false)
        }
        if path.hasSuffix("/messages") { return (200, Data("{\"messages\":[],\"cursor\":0,\"busy\":false}".utf8), false) }
        return (503, Data("{\"error\":\"synthetic optional panel unavailable\"}".utf8), false)
    }
}
