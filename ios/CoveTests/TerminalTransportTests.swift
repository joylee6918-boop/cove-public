import XCTest
import CryptoKit
@testable import Cove

/// Exercise the real Store adapter: closure-only Shell tests missed its allowlist.
@MainActor
final class TerminalTransportTests: XCTestCase {
    func testShellAndRealtimeReachAuthenticatedTransportAndUnknownRoutesDoNot() async throws {
        let previous = UserDefaults.standard.string(forKey: "cove.serverURL")
        UserDefaults.standard.removeObject(forKey: "cove.serverURL")
        let endpoint = "https://terminal-transport-\(UUID().uuidString).invalid/cove"
        let scenario = TransportScenario()
        TransportProtocol.handler = scenario.reply
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TransportProtocol.self]
        let session = URLSession(configuration: config)
        let store = CoveStore(session: session, credentials: TransportCredentials())
        defer {
            store.suspend(); session.invalidateAndCancel(); TransportProtocol.handler = nil
            if let previous { UserDefaults.standard.set(previous, forKey: "cove.serverURL") }
            else { UserDefaults.standard.removeObject(forKey: "cove.serverURL") }
            let hash = SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cove")
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(hash + ".json"))
        }
        store.serverURL = endpoint
        store.accessToken = "isolated-transport-fixture"
        await store.connect()
        XCTAssertTrue(store.isConnected)

        let shell = store.shellAPI(conversationID: "fixture-conversation")
        let opened = try await shell.start(30, 100)
        XCTAssertEqual(opened.id, "fixture-shell")
        let polled = try await shell.poll(opened.id, 7)
        XCTAssertEqual(polled.cursor, 8)
        try await shell.write(opened.id, Data("printf fixture\n".utf8).base64EncodedString(), false)
        try await shell.resize(opened.id, 40, 120)
        try await shell.terminate(opened.id)

        // Synthetic transport only: no microphone, model turn or paid voice call.
        let started: CoveRealtimeAck = try await store.terminalRequest("v1/realtime/start", method: "POST", body: ["conversationID": "fixture-conversation"])
        XCTAssertEqual(started.sessionID, "fixture-voice")
        let events: CoveRealtimeEvents = try await store.terminalRequest("v1/realtime/events", query: [
            URLQueryItem(name: "conversationID", value: "fixture-conversation"),
            URLQueryItem(name: "sessionID", value: "fixture-voice"), URLQueryItem(name: "after", value: "0")])
        XCTAssertFalse(events.closed)
        let audio: CoveRealtimeAck = try await store.terminalRequest("v1/realtime/audio", method: "POST", body: [
            "conversationID": "fixture-conversation", "sessionID": "fixture-voice", "audio": ["data": "AAAA"]])
        XCTAssertTrue(audio.ok)
        let stopped: CoveRealtimeAck = try await store.terminalRequest("v1/realtime/stop", method: "POST", body: [
            "conversationID": "fixture-conversation", "sessionID": "fixture-voice"])
        XCTAssertTrue(stopped.ok)

        XCTAssertEqual(scenario.controlPaths, ["shell/start", "shell/events", "shell/write", "shell/resize", "shell/terminate",
            "realtime/start", "realtime/events", "realtime/audio", "realtime/stop"].map { "/cove/v1/" + $0 })
        for (path, method) in [("v1/shell/not-allowed", "POST"), ("v1/shell/start", "GET"),
                               ("v1/realtime/start/extra", "POST"), ("v1/shell/../messages", "GET")] {
            do {
                let _: CoveRealtimeAck = try await store.terminalRequest(path, method: method)
                XCTFail("Unknown route/method must be rejected locally")
            } catch {
                XCTAssertEqual(error.localizedDescription, "终端接口无效。")
            }
        }
        XCTAssertEqual(scenario.controlPaths.count, 9)

        // Independent App events use owner authentication for reads only.
        let activity = try await store.loadAppActivity(day: "2026-09-22", timeZone: "Asia/Shanghai")
        XCTAssertEqual(activity.eventCount, 2)
        XCTAssertEqual(activity.apps.first?.name, "合成样例 App")
        XCTAssertEqual(activity.totalSeconds, 120)
        XCTAssertEqual(scenario.controlPaths.last, "/cove/v1/app-events")
        store.previewMode = true
        do {
            _ = try await store.loadAppActivity(day: "2026-09-22", timeZone: "Asia/Shanghai")
            XCTFail("Preview must not read authenticated App records")
        } catch { }
        XCTAssertEqual(scenario.controlPaths.count, 10)
        // A retained Shell view must not send to a replacement service scope.
        store.suspend()
        do {
            try await shell.write(opened.id, Data("MUST NOT SEND\n".utf8).base64EncodedString(), false)
            XCTFail("Old Shell adapter must be fenced after disconnect")
        } catch is CancellationError { }
        catch { XCTFail("Expected local scope cancellation, got \(error)") }
        XCTAssertEqual(scenario.controlPaths.count, 10)
    }

    func testAppActivityRejectsWrongDayAndInvalidDurations() throws {
        func summary(day: String = "2026-09-22", seconds: Double = 60, total: Double = 60) -> CoveAppActivitySummary {
            CoveAppActivitySummary(day: day, timeZone: "Asia/Shanghai", source: "cove-shortcuts", totalSeconds: total,
                apps: [.init(name: "示例", seconds: seconds)], eventCount: 2, incomplete: false, configured: true, startedAt: nil)
        }
        XCTAssertNoThrow(try summary().validated(day: "2026-09-22", timeZone: "Asia/Shanghai"))
        XCTAssertThrowsError(try summary(day: "2026-09-21").validated(day: "2026-09-22", timeZone: "Asia/Shanghai"))
        XCTAssertThrowsError(try summary(seconds: -1).validated(day: "2026-09-22", timeZone: "Asia/Shanghai"))
        XCTAssertThrowsError(try summary(total: 0).validated(day: "2026-09-22", timeZone: "Asia/Shanghai"))
        XCTAssertThrowsError(try summary().validated(day: "2026-09-22", timeZone: "UTC"))
        let instant = ISO8601DateFormatter().date(from: "2026-09-21T17:00:00Z")!
        XCTAssertEqual(CoveAppActivitySummary.dayString(instant, timeZone: TimeZone(identifier: "Asia/Shanghai")!), "2026-09-22")
    }
}

private final class TransportCredentials: CoveCredentialStore {
    func read(account: String) -> String? { nil }
    func write(_ token: String, account: String) throws { }
}

private final class TransportProtocol: URLProtocol {
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

private final class TransportScenario: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    var controlPaths: [String] { lock.lock(); defer { lock.unlock() }; return paths }

    func reply(_ request: URLRequest) throws -> (Int, Data) {
        let path = request.url!.path
        let result: [String: Any]
        if path == "/cove/v1/conversations" {
            result = ["conversations": [["id": "fixture-conversation", "title": "Fixture", "createdAt": "2026-09-13T00:00:00Z"]], "activeConversationID": "fixture-conversation"]
        } else if path == "/cove/v1/messages" {
            result = ["messages": [], "cursor": 0, "busy": false]
        } else if path == "/cove/v1/app-events" {
            lock.lock(); paths.append(path); lock.unlock()
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer isolated-transport-fixture")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first(where: { $0.name == "day" })?.value, "2026-09-22")
            XCTAssertEqual(query.first(where: { $0.name == "timeZone" })?.value, "Asia/Shanghai")
            result = ["day": "2026-09-22", "timeZone": "Asia/Shanghai", "source": "cove-shortcuts",
                      "totalSeconds": 120, "apps": [["name": "合成样例 App", "seconds": 120]],
                      "eventCount": 2, "incomplete": false, "configured": true]
        } else if path.hasPrefix("/cove/v1/shell/") || path.hasPrefix("/cove/v1/realtime/") {
            lock.lock(); paths.append(path); lock.unlock()
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer isolated-transport-fixture")
            let isEvents = path.hasSuffix("/events")
            XCTAssertEqual(request.httpMethod, isEvents ? "GET" : "POST")
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
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func field(_ name: String) -> String? {
                isEvents ? query.first(where: { $0.name == name })?.value : body[name] as? String
            }
            XCTAssertEqual(field("conversationID"), "fixture-conversation")
            if !path.hasSuffix("/start") {
                XCTAssertEqual(field("sessionID"), path.contains("/shell/") ? "fixture-shell" : "fixture-voice")
            }
            switch path {
            case "/cove/v1/shell/start", "/cove/v1/shell/events":
                if isEvents { XCTAssertEqual(field("after"), "7") }
                else { XCTAssertEqual(body["rows"] as? Int, 30); XCTAssertEqual(body["cols"] as? Int, 100) }
                result = ["id": "fixture-shell", "state": "running", "events": [], "cursor": 8, "ansi": "plain"]
            case "/cove/v1/shell/write":
                XCTAssertEqual(body["dataBase64"] as? String, Data("printf fixture\n".utf8).base64EncodedString())
                XCTAssertEqual(body["closeStdin"] as? Bool, false)
                result = ["ok": true]
            case "/cove/v1/shell/resize":
                XCTAssertEqual(body["rows"] as? Int, 40); XCTAssertEqual(body["cols"] as? Int, 120)
                result = ["ok": true]
            case "/cove/v1/realtime/events": result = ["events": [], "cursor": 0, "closed": false]
            default: result = ["ok": true, "sessionID": "fixture-voice"]
            }
        } else { return (503, Data("{}".utf8)) }
        return (200, try JSONSerialization.data(withJSONObject: result))
    }
}
