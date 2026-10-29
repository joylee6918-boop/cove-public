import XCTest
import CryptoKit
@testable import Cove

private final class AttachmentProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (code, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class AttachmentOutboxTests: XCTestCase {
    func testPartialUploadSurvivesRelaunchWithoutResendingAcknowledgedFile() async throws {
        let endpoint = "https://cove-test-\(UUID().uuidString.lowercased()).invalid/cove"
        let previous = UserDefaults.standard.string(forKey: "cove.serverURL")
        UserDefaults.standard.removeObject(forKey: "cove.serverURL")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AttachmentProtocol.self]
        let session = URLSession(configuration: config)
        let state = UploadScenario()
        let credentials = TestCredentials()
        AttachmentProtocol.handler = { request in try state.reply(request) }
        let store = CoveStore(session: session, credentials: credentials)
        var restored: CoveStore?
        defer {
            store.suspend(); restored?.suspend()
            session.invalidateAndCancel(); AttachmentProtocol.handler = nil
            if let previous { UserDefaults.standard.set(previous, forKey: "cove.serverURL") }
            else { UserDefaults.standard.removeObject(forKey: "cove.serverURL") }
            let hash = SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cove")
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(hash + ".json"))
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(hash))
        }
        store.serverURL = endpoint
        store.accessToken = "isolated-test-token-not-a-real-account"
        await store.connect()
        XCTAssertTrue(store.isConnected, store.errorMessage ?? store.connectionStatus)
        store.draft = "两个文件一起发"
        await store.sendAttachments(files: [
            .init(data: Data("first".utf8), filename: "first.md", mime: "text/markdown"),
            .init(data: Data("<h1>second</h1>".utf8), filename: "second.html", mime: "text/html")
        ])
        let pending = try XCTUnwrap(store.messages.first)
        XCTAssertEqual(pending.status, "pending")
        XCTAssertEqual(pending.attachments?.count, 2)
        XCTAssertTrue(pending.attachments![0].url.hasPrefix("/v1/attachments/"))
        XCTAssertTrue(pending.attachments![1].url.hasPrefix("/local-attachments/"))
        XCTAssertEqual(state.messagePosts, 0)
        store.suspend()

        let reloaded = CoveStore(session: session, credentials: credentials)
        restored = reloaded
        XCTAssertEqual(reloaded.messages.first?.id, pending.id)
        await reloaded.connect()
        // Reconnection must not wait behind uploads; wait for the independent
        // idempotent outbox drain rather than treating connect() as a send ACK.
        let deadline = Date().addingTimeInterval(4)
        while reloaded.messages.first?.status != "sent", Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(reloaded.messages.first?.status, "sent")
        XCTAssertEqual(state.uploadNames, ["first.md", "second.html", "second.html"])
        XCTAssertEqual(state.messagePosts, 1)
        XCTAssertEqual(state.sentFileIDs, [state.firstID, state.secondID])
        XCTAssertEqual(state.sentMessageID, pending.id)
        let firstData = try await reloaded.attachmentData("/v1/attachments/" + state.firstID)
        XCTAssertEqual(firstData, Data("first".utf8))
        XCTAssertEqual(state.downloads, 0, "An uploaded file remains viewable from the endpoint-isolated cache.")
    }
}

private final class TestCredentials: CoveCredentialStore {
    private var saved: [String: String] = [:]
    func read(account: String) -> String? { saved[account] }
    func write(_ token: String, account: String) throws { saved[account] = token }
}

private final class UploadScenario: @unchecked Sendable {
    let firstID = UUID().uuidString
    let secondID = UUID().uuidString
    var uploadNames: [String] = []
    var messagePosts = 0
    var sentFileIDs: [String] = []
    var sentMessageID = ""
    var downloads = 0
    private let lock = NSLock()
    private let date = "2026-09-13T00:00:00Z"

    func reply(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path
        guard path.hasPrefix("/cove/v1/") else { throw URLError(.badURL) }
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
            result = ["conversations": [["id": "test-conversation", "title": "测试", "createdAt": date]], "activeConversationID": "test-conversation"]
        case ("POST", "/cove/v1/conversations"):
            result = ["conversation": ["id": "test-conversation", "title": "测试", "createdAt": date]]
        case ("GET", "/cove/v1/messages"):
            result = ["messages": [], "cursor": 0, "busy": false]
        case ("POST", "/cove/v1/attachments"):
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let name = items.first(where: { $0.name == "filename" })?.value ?? ""
            let mime = items.first(where: { $0.name == "mime" })?.value ?? ""
            guard request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream",
                  bytes == Data(name == "first.md" ? "first".utf8 : "<h1>second</h1>".utf8) else {
                throw URLError(.cannotParseResponse)
            }
            uploadNames.append(name)
            if uploadNames.count == 2 { throw URLError(.notConnectedToInternet) }
            let id = name == "first.md" ? firstID : secondID
            result = metadata(id, name, mime)
        case ("POST", "/cove/v1/messages"):
            messagePosts += 1
            sentFileIDs = body["attachmentIDs"] as! [String]
            sentMessageID = body["id"] as! String
            result = ["message": ["id": sentMessageID, "conversationID": "test-conversation", "role": "user", "text": body["text"]!, "createdAt": date, "status": "sent", "attachments": [metadata(firstID, "first.md", "text/markdown"), metadata(secondID, "second.html", "text/html")]]]
        case ("GET", "/cove/v1/health"):
            result = ["snapshot": NSNull(), "syncedAt": NSNull(), "readAt": NSNull()]
        case ("GET", "/cove/v1/health/history"):
            result = ["snapshots": [], "updatedAt": NSNull()]
        default:
            if path.contains("/attachments/") { downloads += 1 }
            return (503, Data("{}".utf8))
        }
        return (200, try JSONSerialization.data(withJSONObject: result))
    }

    private func metadata(_ id: String, _ filename: String, _ mime: String) -> [String: Any] {
        ["id": id, "filename": filename, "mime": mime, "size": 5, "url": "/v1/attachments/" + id]
    }
}
