import XCTest
import CryptoKit
@testable import Cove

private final class ContinuousSendProtocol: URLProtocol {
    static var scenario: ContinuousSendScenario?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let scenario = Self.scenario else { throw URLError(.cancelled) }
            let (code, data) = try scenario.reply(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class ContinuousSendCredentials: CoveCredentialStore {
    private var values: [String: String] = [:]
    func read(account: String) -> String? { values[account] }
    func write(_ token: String, account: String) throws { values[account] = token }
}

private final class ContinuousSendScenario: @unchecked Sendable {
    let firstMessageEntered = DispatchSemaphore(value: 0)
    let releaseFirstMessage = DispatchSemaphore(value: 0)
    let secondMessageEntered = DispatchSemaphore(value: 0)
    let releaseSecondMessage = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var shouldBlockFirst = true
    private var messageOrdinal = 0
    private(set) var sentTexts: [String] = []
    private(set) var sentAttachmentCounts: [Int] = []
    private let date = "2026-09-21T00:00:00Z"

    func sentSnapshot() -> (texts: [String], attachmentCounts: [Int]) {
        lock.lock(); defer { lock.unlock() }
        return (sentTexts, sentAttachmentCounts)
    }

    func reply(_ request: URLRequest) throws -> (Int, Data) {
        let path = request.url!.path
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(buffer, count: count)
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
        var result: [String: Any]
        switch (request.httpMethod ?? "GET", path) {
        case ("GET", "/cove/v1/conversations"):
            result = ["conversations": [["id":"continuous", "title":"测试", "createdAt":date]], "activeConversationID":"continuous"]
        case ("POST", "/cove/v1/conversations"):
            result = ["conversation":["id":"continuous", "title":"测试", "createdAt":date]]
        case ("GET", "/cove/v1/messages"):
            result = ["messages":[], "cursor":0, "busy":false]
        case ("POST", "/cove/v1/messages"):
            lock.lock()
            let block = shouldBlockFirst
            if block { shouldBlockFirst = false }
            messageOrdinal += 1
            let ordinal = messageOrdinal
            lock.unlock()
            if block {
                firstMessageEntered.signal()
                guard releaseFirstMessage.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
            }
            if ordinal == 2 {
                secondMessageEntered.signal()
                guard releaseSecondMessage.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
            }
            let text = body["text"] as? String ?? ""
            let attachments = body["attachmentIDs"] as? [String] ?? []
            lock.lock(); sentTexts.append(text); sentAttachmentCounts.append(attachments.count); lock.unlock()
            result = ["message":["id":body["id"]!, "conversationID":"continuous", "role":"user", "text":text,
                                 "createdAt":ordinal == 1 ? "2099-09-21T00:10:00Z" : date, "status":"sent", "attachments":attachments.map { ["id":$0,"filename":"queued.txt","mime":"text/plain","size":4,"url":"/v1/attachments/\($0)"] }]]
        case ("POST", "/cove/v1/attachments"):
            result = ["id":"uploaded-file", "filename":"queued.txt", "mime":"text/plain", "size":bytes.count, "url":"/v1/attachments/uploaded-file"]
        default:
            // Optional refresh endpoints are allowed to be unavailable in this focused fixture.
            return (404, try JSONSerialization.data(withJSONObject: ["error":"fixture unavailable"]))
        }
        return (200, try JSONSerialization.data(withJSONObject: result))
    }
}

@MainActor
final class CoveContinuousSendTests: XCTestCase {
    private func wait(_ semaphore: DispatchSemaphore, seconds: Double = 2) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: semaphore.wait(timeout: .now() + seconds)) }
        }
    }

    func testSecondTextAndAttachmentQueueWhileFirstRequestIsAwaitingThenDrainInOrder() async throws {
        let endpoint = "https://continuous-\(UUID().uuidString.lowercased()).invalid/cove"
        let previous = UserDefaults.standard.string(forKey: "cove.serverURL")
        UserDefaults.standard.removeObject(forKey: "cove.serverURL")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ContinuousSendProtocol.self]
        let session = URLSession(configuration: config)
        let scenario = ContinuousSendScenario()
        ContinuousSendProtocol.scenario = scenario
        let store = CoveStore(session: session, credentials: ContinuousSendCredentials())
        defer {
            scenario.releaseFirstMessage.signal(); scenario.releaseSecondMessage.signal(); store.suspend(); session.invalidateAndCancel()
            ContinuousSendProtocol.scenario = nil
            if let previous { UserDefaults.standard.set(previous, forKey: "cove.serverURL") }
            else { UserDefaults.standard.removeObject(forKey: "cove.serverURL") }
            let hash = SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cove")
            try? FileManager.default.removeItem(at: root.appendingPathComponent(hash + ".json"))
            try? FileManager.default.removeItem(at: root.appendingPathComponent(hash))
        }
        store.serverURL = endpoint
        store.accessToken = "synthetic-continuous-send-token"
        await store.connect()
        XCTAssertTrue(store.isConnected)

        store.draft = "first"
        store.send()
        let firstEntered = await wait(scenario.firstMessageEntered)
        XCTAssertEqual(firstEntered, .success)
        store.draft = "second"
        store.send()
        let attachmentQueued = await store.sendAttachments(files: [
            .init(data: Data("file".utf8), filename: "queued.txt", mime: "text/plain")
        ], caption: "attachment", waitForDelivery: false)
        XCTAssertTrue(attachmentQueued)
        XCTAssertEqual(store.messages.filter { $0.role == "user" }.count, 3)

        scenario.releaseFirstMessage.signal()
        let secondEntered = await wait(scenario.secondMessageEntered)
        XCTAssertEqual(secondEntered, .success)
        XCTAssertEqual(store.messages.filter { $0.role == "user" }.map(\.text), ["first", "second", "attachment"],
                       "A delayed first ACK must not reorder newer locally queued messages.")
        scenario.releaseSecondMessage.signal()
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline && scenario.sentSnapshot().texts.count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        let sent = scenario.sentSnapshot()
        XCTAssertEqual(sent.texts, ["first", "second", "attachment"])
        XCTAssertEqual(sent.attachmentCounts, [0, 0, 1])
        XCTAssertEqual(store.messages.filter { $0.role == "user" }.map(\.text), ["first", "second", "attachment"])
        XCTAssertEqual(store.messages.filter { $0.role == "user" }.map(\.status), ["sent", "sent", "sent"])
    }

    func testConversationMismatchPreservesAttachmentDraft() async {
        let endpoint = "https://mismatch-\(UUID().uuidString.lowercased()).invalid/cove"
        let previous = UserDefaults.standard.string(forKey: "cove.serverURL")
        UserDefaults.standard.removeObject(forKey: "cove.serverURL")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ContinuousSendProtocol.self]
        let session = URLSession(configuration: config)
        ContinuousSendProtocol.scenario = ContinuousSendScenario()
        let store = CoveStore(session: session, credentials: ContinuousSendCredentials())
        defer {
            store.suspend(); session.invalidateAndCancel(); ContinuousSendProtocol.scenario = nil
            if let previous { UserDefaults.standard.set(previous, forKey: "cove.serverURL") }
            else { UserDefaults.standard.removeObject(forKey: "cove.serverURL") }
            let hash = SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cove")
            try? FileManager.default.removeItem(at: root.appendingPathComponent(hash + ".json"))
            try? FileManager.default.removeItem(at: root.appendingPathComponent(hash))
        }
        store.serverURL = endpoint
        store.accessToken = "synthetic-mismatch-token"
        await store.connect()
        XCTAssertTrue(store.isConnected)
        store.draft = "must survive"
        let userCount = store.messages.filter { $0.role == "user" }.count
        let sent = await store.sendAttachments(files: [
            .init(data: Data("file".utf8), filename: "draft.txt", mime: "text/plain")
        ], expectedConversationID: "a-conversation-that-is-not-active", waitForDelivery: false)
        XCTAssertFalse(sent)
        XCTAssertEqual(store.draft, "must survive")
        XCTAssertEqual(store.messages.filter { $0.role == "user" }.count, userCount)
    }
    func testWidgetUsesExistingOutboxPreservesDraftAndDoesNotDuplicate() async throws {
        let endpoint = "https://widget-\(UUID().uuidString.lowercased()).invalid/cove"
        let previous = UserDefaults.standard.string(forKey: "cove.serverURL")
        UserDefaults.standard.removeObject(forKey: "cove.serverURL")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ContinuousSendProtocol.self]
        let session = URLSession(configuration: config)
        let scenario = ContinuousSendScenario()
        ContinuousSendProtocol.scenario = scenario
        let store = CoveStore(session: session, credentials: ContinuousSendCredentials())
        defer {
            scenario.releaseFirstMessage.signal(); scenario.releaseSecondMessage.signal()
            store.suspend(); session.invalidateAndCancel(); ContinuousSendProtocol.scenario = nil
            if let previous { UserDefaults.standard.set(previous, forKey: "cove.serverURL") }
            else { UserDefaults.standard.removeObject(forKey: "cove.serverURL") }
        }
        store.serverURL = endpoint; store.accessToken = "synthetic-widget-token"
        await store.connect()
        XCTAssertTrue(store.isConnected)
        let source = ChatMessage(id: "widget-source", conversationID: store.activeConversationID, role: "assistant", text: "synthetic widget", createdAt: Date(), status: "complete")
        store.messages.append(source)
        store.draft = "existing composer draft"; store.replyToMessageID = "other-quote"
        XCTAssertTrue(scenario.sentSnapshot().texts.isEmpty)
        try store.sendWidget("我选读书", source: source, widgetKey: "plan:hash")
        XCTAssertEqual(store.draft, "existing composer draft")
        XCTAssertEqual(store.replyToMessageID, "other-quote")
        XCTAssertEqual(store.messages.filter { $0.role == "user" }.count, 1)
        XCTAssertEqual(store.messages.first { $0.role == "user" }?.replyTo, source.id)
        let entered = await wait(scenario.firstMessageEntered)
        XCTAssertEqual(entered, .success)
        store.messages.append(source) // mock GET intentionally has no assistant history
        XCTAssertThrowsError(try store.sendWidget("changed attempt", source: source, widgetKey: "plan:hash"))
        scenario.releaseFirstMessage.signal()
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline && scenario.sentSnapshot().texts.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(scenario.sentSnapshot().texts, ["我选读书"])
        XCTAssertEqual(store.messages.first { $0.role == "user" }?.status, "sent")
        store.messages.append(source)
        store.activeConversationID = "another-conversation"
        XCTAssertThrowsError(try store.sendWidget("stale", source: source, widgetKey: "another:hash"))
        XCTAssertEqual(scenario.sentSnapshot().texts.count, 1)
    }

}
