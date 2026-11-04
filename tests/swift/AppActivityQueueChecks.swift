import Foundation

@main
struct QueueTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1
        }
        func rejects(_ block: () throws -> Void) {
            do { try block(); fatalError("Expected rejection") } catch { checks += 1 }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("activity-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = AppActivityQueue(directory: root)
        check(try queue.snapshot().enabled == false, "default off")
        check(try queue.enqueue(app: .wechat, action: .open) == nil, "pause does not collect")
        rejects { try queue.setEnabled(true) }
        for url in ["http://example.com", "https://user:secret@example.com", "https://example.com?a=1",
                    "https://example.com#secret", "https://example.com/v1/app-events", "file:///private/tmp"] {
            rejects { _ = try AppActivityQueue.validatedBaseURL(url) }
        }
        check(try AppActivityQueue.validatedBaseURL("https://EXAMPLE.com/cove/") == "https://example.com/cove", "normalize base")
        let cove = ActivityDestination(id: .cove, baseURL: "https://example.com/cove", credentialAccount: "fixture.cove", enabled: true)
        let ccc = ActivityDestination(id: .ccc, baseURL: "https://example.net/ccc", credentialAccount: "fixture.ccc", enabled: true)
        check(cove.endpoint.path == "/cove/v1/app-events/queued", "preserve Cove prefix")
        check(ccc.endpoint.path == "/ccc/integrations/app-events/queued", "preserve CCC prefix")
        try queue.configure(cove); try queue.configure(ccc); try queue.setEnabled(true)
        let date = Date(timeIntervalSince1970: 1800000000.123)
        let event = try queue.enqueue(app: .wechat, action: .open, at: date)!
        let restarted = AppActivityQueue(directory: root)
        let initial = try restarted.snapshot()
        check(initial.events.first?.event == event, "commit survives reconstruction")
        check(initial.pending(.cove) == 1 && initial.pending(.ccc) == 1, "independent recipients")
        check(event.timestamp == "2027-01-15T08:00:00.123Z", "fixed timezone and fractions")
        let body = try JSONSerialization.jsonObject(with: Data(contentsOf: queue.payloadFile(for: event))) as! [String: Any]
        check(Set(body.keys) == ["id", "app", "action", "timestamp"], "only event fields on wire")
        check(body["app"] as? String == "微信", "canonical App name")
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("journal.json").path)
        check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private journal")
        func identity(_ state: ActivityQueueState, _ recipient: ActivityRecipient, _ id: String = event.id) -> ActivityUploadIdentity {
            let dest = state.destinations.first { $0.id == recipient }!
            return ActivityUploadIdentity(eventID: id, recipient: recipient, epoch: state.epoch, revision: dest.revision)
        }
        let coveID = identity(initial, .cove), cccID = identity(initial, .ccc)
        check(ActivityUploadIdentity(coveID.encoded) == coveID, "background task metadata roundtrip")
        try queue.apply(.received, identity: coveID, at: date)
        try queue.apply(.retry("offline"), identity: cccID, at: date)
        let offline = try queue.snapshot()
        check(offline.pending(.cove) == 0 && offline.pending(.ccc) == 1, "one failed receiver cannot undo the other ACK")
        check(offline.events.first?.event == event, "retry preserves immutable ID and capture time")
        check(offline.events.first?.deliveries["ccc"]?.nextAttempt == date.addingTimeInterval(30), "bounded persisted backoff")
        rejects { try queue.validateDestinationChange(.ccc, baseURL: "https://another.example") }
        var redirected = ccc; redirected.baseURL = "https://another.example"
        rejects { try queue.configure(redirected) }
        try queue.setEnabled(false)
        try queue.apply(.received, identity: cccID)
        check(try queue.snapshot().pending(.ccc) == 1, "late callback after pause does not claim delivery")
        try queue.setEnabled(true)
        try queue.apply(.received, identity: cccID)
        check(try queue.snapshot().pending(.ccc) == 1, "old epoch rejected after resume")
        let resumed = try queue.snapshot()
        try queue.apply(.received, identity: identity(resumed, .ccc))
        check(try queue.snapshot().events.isEmpty, "remove only after both receivers ACK")
        check(try queue.snapshot().destinations.allSatisfy { $0.lastReceivedAt != nil }, "receipt times are independent")
        try queue.cleanPayloads(keeping: [])
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent(event.id + ".json").path), "clean only completed payloads")
        let badAck = Data("{\"ok\":true,\"id\":\"wrong\",\"duplicate\":false}".utf8)
        check(ActivityUploadOutcome.classify(status: 200, data: badAck, expectedID: event.id, transportFailed: false) != .received, "mismatched ACK is not success")
        for duplicate in [true, false] {
            let data = try JSONSerialization.data(withJSONObject: ["ok": true, "id": event.id, "duplicate": duplicate])
            check(ActivityUploadOutcome.classify(status: 200, data: data, expectedID: event.id, transportFailed: false) == .received, "new and duplicate ACKs accepted")
        }
        let missing = Data("{\"ok\":true,\"id\":\"\(event.id)\"}".utf8)
        check(ActivityUploadOutcome.classify(status: 200, data: missing, expectedID: event.id, transportFailed: false) != .received, "partial ACK rejected")
        for status in [400, 401, 404, 409, 429, 503] {
            check(ActivityUploadOutcome.classify(status: status, data: Data(), expectedID: event.id, transportFailed: false) != .received, "HTTP error retained")
        }
        var disabledCCC = ccc; disabledCCC.enabled = false
        try queue.configure(disabledCCC)
        let second = try queue.enqueue(app: .safari, action: .close)!
        let selected = try queue.snapshot()
        check(selected.pending(.ccc) == 0 && selected.pending(.cove) == 1, "disabled recipient receives no new records")
        try queue.configure(ccc)
        check(try queue.snapshot().pending(.ccc) == 0, "enabling recipient does not import old records")
        let oldIdentity = identity(try queue.snapshot(), .cove, second.id)
        try queue.configure(cove)
        try queue.apply(.received, identity: oldIdentity)
        check(try queue.snapshot().pending(.cove) == 1, "changed credentials/config fence old callbacks")
        let liveIdentity = identity(try queue.snapshot(), .cove, second.id)
        try queue.apply(.blockDestination("invalid token"), identity: liveIdentity)
        check(try queue.snapshot().destinations.first { $0.id == .cove }?.blocked != nil, "auth failures pause destination")
        try queue.retry()
        check(try queue.snapshot().destinations.allSatisfy { $0.blocked == nil }, "explicit retry unblocks")
        try queue.discardPending()
        check(try queue.snapshot().events.isEmpty, "explicit local discard")
        let concurrent = AppActivityQueue(directory: root)
        DispatchQueue.concurrentPerform(iterations: 30) { index in
            _ = try! (index % 2 == 0 ? queue : concurrent).enqueue(app: .ccc, action: .open)
        }
        check(try queue.snapshot().events.count == 30, "journal lock prevents lost concurrent events")
        let raw = try Data(contentsOf: root.appendingPathComponent("journal.json"))
        check(!String(decoding: raw, as: UTF8.self).contains("Bearer"), "no credentials in journal")
        let smallRoot = root.appendingPathComponent("small")
        let small = AppActivityQueue(directory: smallRoot, capacity: 1)
        try small.configure(cove); try small.setEnabled(true)
        _ = try small.enqueue(app: .rednote, action: .open)
        rejects { _ = try small.enqueue(app: .rednote, action: .close) }
        check(try small.snapshot().events.count == 1, "full queue never drops older data")
        try Data("broken".utf8).write(to: smallRoot.appendingPathComponent("journal.json"))
        rejects { _ = try small.enqueue(app: .cove, action: .open) }
        check(try String(contentsOf: smallRoot.appendingPathComponent("journal.json"), encoding: .utf8) == "broken", "corruption fails closed")
        print("App activity queue: \(checks) checks passed; isolated files, no network or personal events.")
    }
}
