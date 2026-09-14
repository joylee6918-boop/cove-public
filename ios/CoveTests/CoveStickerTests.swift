import XCTest
import CryptoKit
import ImageIO
import UIKit
@testable import Cove

private final class StickerProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.cancelled) }
            let (status, data) = try handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class CoveStickerTests: XCTestCase {
    func testGIFOriginalBytesAndFrameTimingSurviveImportDecode() async throws {
        let gif = try makeGIF()
        let file = try await CoveStickerImages.validatedFile(.init(data: gif, filename: "抱抱.gif", mime: "application/octet-stream"))
        XCTAssertEqual(file.data, gif)
        XCTAssertEqual(file.mime, "image/gif")
        let still = try await CoveStickerImages.decode(gif, animate: false)
        XCTAssertNil(still.images)
        let animated = try await CoveStickerImages.decode(gif, animate: true)
        XCTAssertGreaterThan(animated.images?.count ?? 0, 1)
        XCTAssertEqual(animated.duration, 0.3, accuracy: 0.025)
    }

    func testStickerRetryReusesReferenceAndMessageIdentityWhilePreservingDraft() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        await fixture.store.connect()
        await fixture.store.reloadStickers()
        let sticker = try XCTUnwrap(fixture.store.stickers.first)
        fixture.store.draft = "还没写完的草稿"
        fixture.store.replyToMessageID = "quoted-message"
        let queued = await fixture.store.sendSticker(sticker)
        XCTAssertTrue(queued)
        XCTAssertEqual(fixture.store.draft, "还没写完的草稿")
        XCTAssertNil(fixture.store.replyToMessageID)
        for _ in 0..<100 {
            if fixture.scenario.messageIDs.count == 1, fixture.store.messages.first?.status == "pending" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        fixture.store.suspend()
        let id = try XCTUnwrap(fixture.store.messages.first?.id)
        XCTAssertEqual(fixture.store.messages.first?.stickerID, "saved-sticker")
        XCTAssertEqual(fixture.store.messages.first?.text, "")
        let restored = CoveStore(session: fixture.session, credentials: fixture.credentials)
        fixture.restored = restored
        XCTAssertEqual(restored.draft, "还没写完的草稿")
        XCTAssertEqual(restored.stickers.first?.id, "saved-sticker")
        await restored.connect()
        XCTAssertEqual(restored.messages.first?.status, "sent", restored.errorMessage ?? "")
        XCTAssertEqual(fixture.scenario.messageIDs, [id, id])
        XCTAssertEqual(fixture.scenario.lastBody?["stickerID"] as? String, "saved-sticker")
        XCTAssertEqual(fixture.scenario.lastBody?["attachmentIDs"] as? [String], [fixture.scenario.attachmentID])
        XCTAssertEqual(fixture.scenario.lastBody?["text"] as? String, "")
        XCTAssertEqual(fixture.scenario.uploads, 0)
        XCTAssertEqual(restored.draft, "还没写完的草稿")
    }

    func testSaveLostACKRetryUsesAcknowledgedOriginalUploadAfterRelaunch() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        await fixture.store.connect()
        let gif = try makeGIF()
        let file = CoveOutgoingFile(data: gif, filename: "抱抱.gif", mime: "image/gif")
        fixture.scenario.failFirstSave = true
        do { try await fixture.store.importSticker(file: file, name: "抱抱"); XCTFail("Lost save ACK must be visible") }
        catch { }
        XCTAssertEqual(fixture.scenario.uploads, 1)
        fixture.store.suspend()
        let restored = CoveStore(session: fixture.session, credentials: fixture.credentials)
        fixture.restored = restored
        await restored.connect()
        try await restored.importSticker(file: file, name: "抱抱")
        XCTAssertEqual(fixture.scenario.uploads, 1)
        XCTAssertEqual(fixture.scenario.savedIDs, [fixture.scenario.attachmentID, fixture.scenario.attachmentID])
        XCTAssertEqual(fixture.scenario.uploadedBytes, gif)
        XCTAssertEqual(restored.stickers.first?.owner, "user")
        XCTAssertEqual(restored.stickers.first?.label, "抱抱")
    }

    func testPreviewLibraryDoesNotAccessNetworkOrSend() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        fixture.store.enablePreview()
        await fixture.store.reloadStickers()
        XCTAssertEqual(Set(fixture.store.stickers.map(\.owner)), Set(["user", "assistant"]))
        let sticker = try XCTUnwrap(fixture.store.stickers.first)
        let bytes = try await fixture.store.attachmentData(sticker.attachment.url)
        XCTAssertFalse(bytes.isEmpty)
        let sent = await fixture.store.sendSticker(sticker)
        XCTAssertFalse(sent)
        do { try await fixture.store.importSticker(file: .init(data: bytes, filename: "sample.png", mime: "image/png"), name: "sample"); XCTFail("Preview must reject uploads") }
        catch { }
        XCTAssertEqual(fixture.scenario.requests, 0)
    }

    private func makeGIF() throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, 2, nil))
        for index in 0..<2 {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
                (index == 0 ? UIColor.systemPink : UIColor.systemTeal).setFill()
                context.fill(CGRect(x: 4, y: 4, width: 24, height: 24))
            }
            CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: index == 0 ? 0.1 : 0.2]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

@MainActor
private final class Fixture {
    let endpoint = "https://cove-sticker-\(UUID().uuidString.lowercased()).invalid/cove"
    let previous = UserDefaults.standard.string(forKey: "cove.serverURL")
    let session: URLSession
    let credentials = StickerCredentials()
    let scenario = StickerScenario()
    let store: CoveStore
    var restored: CoveStore?
    init() {
        UserDefaults.standard.removeObject(forKey: "cove.serverURL")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StickerProtocol.self]
        session = URLSession(configuration: config)
        let scenario = scenario
        StickerProtocol.handler = { try scenario.reply($0) }
        store = CoveStore(session: session, credentials: credentials)
        store.serverURL = endpoint
        store.accessToken = "fixture-not-a-real-token"
    }
    func clean() {
        store.suspend(); restored?.suspend(); session.invalidateAndCancel(); StickerProtocol.handler = nil
        if let previous { UserDefaults.standard.set(previous, forKey: "cove.serverURL") }
        else { UserDefaults.standard.removeObject(forKey: "cove.serverURL") }
        let hash = SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cove")
        try? FileManager.default.removeItem(at: root.appendingPathComponent(hash + ".json"))
        try? FileManager.default.removeItem(at: root.appendingPathComponent(hash))
    }
}

private final class StickerCredentials: CoveCredentialStore {
    private var values: [String: String] = [:]
    func read(account: String) -> String? { values[account] }
    func write(_ token: String, account: String) throws { values[account] = token }
}

private final class StickerScenario: @unchecked Sendable {
    let attachmentID = UUID().uuidString
    var requests = 0
    var uploads = 0
    var uploadedBytes: Data?
    var messageIDs: [String] = []
    var savedIDs: [String] = []
    var failFirstSave = false
    var lastBody: [String: Any]?
    private let lock = NSLock()
    private let date = "2026-09-14T00:00:00Z"
    func reply(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        requests += 1
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let length = stream.read(&buffer, maxLength: buffer.count)
                if length <= 0 { break }; bytes.append(buffer, count: length)
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
        let attachment: [String: Any] = ["id": attachmentID, "filename": "抱抱.gif", "mime": "image/gif", "size": 100, "url": "/v1/attachments/" + attachmentID]
        let sticker: [String: Any] = ["id": "saved-sticker", "owner": "user", "label": "抱抱", "createdAt": date, "attachment": attachment]
        var result: [String: Any]
        switch (request.httpMethod ?? "GET", request.url!.path) {
        case ("GET", "/cove/v1/conversations"):
            result = ["conversations": [["id": "sticker-chat", "title": "Test", "createdAt": date]], "activeConversationID": "sticker-chat"]
        case ("POST", "/cove/v1/conversations"):
            result = ["conversation": ["id": "sticker-chat", "title": "Test", "createdAt": date]]
        case ("GET", "/cove/v1/messages"):
            result = ["messages": [], "cursor": 0, "busy": false]
        case ("GET", "/cove/v1/stickers"):
            result = ["stickers": [sticker]]
        case ("POST", "/cove/v1/attachments"):
            uploads += 1; uploadedBytes = Data(base64Encoded: body["dataBase64"] as! String); result = attachment
        case ("POST", "/cove/v1/stickers"):
            savedIDs.append(body["attachmentID"] as! String)
            if failFirstSave && savedIDs.count == 1 { throw URLError(.networkConnectionLost) }
            result = ["sticker": sticker]
        case ("POST", "/cove/v1/messages"):
            messageIDs.append(body["id"] as! String); lastBody = body
            if messageIDs.count == 1 { throw URLError(.networkConnectionLost) }
            result = ["message": ["id": body["id"]!, "conversationID": "sticker-chat", "text": body["text"]!, "role": "user", "status": "sent", "createdAt": date, "stickerID": "saved-sticker", "attachments": [attachment]]]
        case ("GET", "/cove/v1/health"):
            result = ["snapshot": NSNull(), "syncedAt": NSNull(), "readAt": NSNull()]
        case ("GET", "/cove/v1/health/history"):
            result = ["snapshots": []]
        default: return (503, Data("{}".utf8))
        }
        return (200, try JSONSerialization.data(withJSONObject: result))
    }
}
