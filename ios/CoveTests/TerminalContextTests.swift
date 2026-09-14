import XCTest
import CryptoKit
@testable import Cove

@MainActor
final class TerminalContextTests: XCTestCase {
    func testClearWaitsForAcknowledgementRetainsHistoryAndReusesIDAfterFailure() async throws {
        let previous = UserDefaults.standard.string(forKey: "cove.serverURL")
        UserDefaults.standard.removeObject(forKey: "cove.serverURL")
        let endpoint = "https://terminal-context-\(UUID().uuidString).invalid/cove"
        let scenario = ContextScenario()
        ContextProtocol.handler = scenario.reply
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ContextProtocol.self]
        let session = URLSession(configuration: config)
        let store = CoveStore(session: session, credentials: ContextCredentials())
        defer {
            store.suspend(); session.invalidateAndCancel(); ContextProtocol.handler = nil
            if let previous { UserDefaults.standard.set(previous, forKey: "cove.serverURL") }
            else { UserDefaults.standard.removeObject(forKey: "cove.serverURL") }
            let hash = SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cove")
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(hash + ".json"))
        }
        store.serverURL = endpoint
        store.accessToken = "isolated-context-fixture"
        await store.connect()
        XCTAssertTrue(store.isConnected)
        XCTAssertEqual(store.messages.first?.text, "保留的旧记录")
        store.draft = "保留的旧草稿"
        scenario.failModelOnce = true
        do {
            _ = try await store.terminalNewConversation(inheritingModel: "fixture-model", effort: "medium")
            XCTFail("The failed model ACK must not report a successful context reset")
        } catch { }
        XCTAssertEqual(store.activeConversationID, "old")
        XCTAssertEqual(store.draft, "保留的旧草稿")
        let created = try await store.terminalNewConversation(inheritingModel: "fixture-model", effort: "medium")
        XCTAssertNotEqual(created, "old")
        XCTAssertEqual(scenario.createdIDs, [created, created])
        XCTAssertEqual(scenario.interruptedIDs, ["old", "old"])
        XCTAssertEqual(scenario.modelIDs, [created, created])
        XCTAssertEqual(store.activeConversationID, created)
        XCTAssertTrue(store.messages.isEmpty)
        await store.selectConversation("old")
        XCTAssertEqual(store.messages.first?.text, "保留的旧记录")
        XCTAssertEqual(store.draft, "保留的旧草稿")
    }
}

private final class ContextCredentials: CoveCredentialStore {
    func read(account: String) -> String? { nil }
    func write(_ token: String, account: String) throws { }
}

private final class ContextProtocol: URLProtocol {
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

private final class ContextScenario: @unchecked Sendable {
    var createdIDs: [String] = []
    var interruptedIDs: [String] = []
    var modelIDs: [String] = []
    var failModelOnce = false
    private let date = "2026-09-13T00:00:00Z"
    func reply(_ request: URLRequest) throws -> (Int, Data) {
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
        let path = request.url!.path
        let result: [String: Any]
        switch (request.httpMethod ?? "GET", path) {
        case ("GET", "/cove/v1/conversations"):
            result = ["conversations": [["id": "old", "title": "旧对话", "createdAt": date]], "activeConversationID": "old"]
        case ("GET", "/cove/v1/messages"):
            let old = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "conversationID" })?.value == "old"
            result = ["messages": old ? [["id": "old-message", "conversationID": "old", "role": "user", "text": "保留的旧记录", "createdAt": date, "status": "sent"]] : [], "cursor": 1, "busy": false]
        case ("POST", "/cove/v1/interrupt"):
            interruptedIDs.append(body["conversationID"] as! String)
            result = ["ok": true]
        case ("POST", "/cove/v1/conversations"):
            let id = body["id"] as! String
            createdIDs.append(id)
            result = ["conversation": ["id": id, "title": "新对话", "createdAt": date]]
        case ("POST", "/cove/v1/terminal/model"):
            modelIDs.append(body["conversationID"] as! String)
            if failModelOnce { failModelOnce = false; throw URLError(.networkConnectionLost) }
            guard body["model"] as? String == "fixture-model", body["effort"] as? String == "medium" else { throw URLError(.badServerResponse) }
            result = ["ok": true]
        default: return (503, Data("{}".utf8))
        }
        return (200, try JSONSerialization.data(withJSONObject: result))
    }
}
