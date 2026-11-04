import Foundation
import Darwin

// Pure Foundation journal. App Intents and foreground UI share the same durable state.
// No credentials, chat content, or inferred activity are stored here.
enum ActivityApp: String, Codable, CaseIterable, Identifiable, Sendable {
    case wechat = "微信", douyin = "抖音", taobao = "淘宝", chatGPT = "ChatGPT"
    case cove = "Cove", ccc = "CCC", safari = "Safari", rednote = "小红书"
    var id: String { rawValue }
}
enum ActivityAction: String, Codable, CaseIterable, Sendable { case open, close }
enum ActivityRecipient: String, Codable, CaseIterable, Identifiable {
    case cove, ccc
    var id: String { rawValue }
    var title: String { self == .cove ? "Cove · Assistant" : "CCC · another assistant" }
    var route: String { self == .cove ? "v1/app-events/queued" : "integrations/app-events/queued" }
}
struct ActivityReceiptEvent: Codable, Equatable {
    let id: String
    let app: String
    let action: String
    let timestamp: String
    init(app: ActivityApp, action: ActivityAction, at date: Date = Date()) {
        id = UUID().uuidString.lowercased()
        self.app = app.rawValue
        self.action = action.rawValue
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        timestamp = formatter.string(from: date)
    }
}
struct ActivityDestination: Codable, Equatable, Identifiable {
    let id: ActivityRecipient
    var baseURL: String
    var credentialAccount: String
    var enabled: Bool
    var revision = UUID().uuidString
    var blocked: String?
    var lastReceivedAt: Date?
    var endpoint: URL { URL(string: baseURL)!.appendingPathComponent(id.route) }
}
struct ActivityDelivery: Codable, Equatable {
    var attempts = 0
    var nextAttempt = Date.distantPast
    var error: String?
    var blocked = false
}
struct ActivityPendingEvent: Codable, Equatable, Identifiable {
    let event: ActivityReceiptEvent
    var deliveries: [String: ActivityDelivery]
    var id: String { event.id }
}
struct ActivityQueueState: Codable {
    var version = 1
    var enabled = false
    var epoch = UUID().uuidString
    var destinations: [ActivityDestination] = []
    var events: [ActivityPendingEvent] = []
    func pending(_ recipient: ActivityRecipient) -> Int {
        events.filter { $0.deliveries[recipient.rawValue] != nil }.count
    }
}
struct ActivityUploadIdentity: Codable, Equatable {
    let eventID: String
    let recipient: ActivityRecipient
    let epoch: String
    let revision: String
    var encoded: String? { try? String(data: JSONEncoder().encode(self), encoding: .utf8) }
    init(eventID: String, recipient: ActivityRecipient, epoch: String, revision: String) {
        self.eventID = eventID; self.recipient = recipient; self.epoch = epoch; self.revision = revision
    }
    init?(_ description: String?) {
        guard let data = description?.data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = value
    }
    func isCurrent(in state: ActivityQueueState) -> Bool {
        state.enabled && state.epoch == epoch && state.destinations.contains {
            $0.id == recipient && $0.enabled && $0.revision == revision
        } && state.events.contains { $0.id == eventID && $0.deliveries[recipient.rawValue] != nil }
    }
}
enum ActivityUploadOutcome: Equatable {
    case received
    case retry(String)
    case blockEvent(String)
    case blockDestination(String)

    static func classify(status: Int?, data: Data, expectedID: String, transportFailed: Bool) -> Self {
        if transportFailed || status == nil { return .retry("网络尚未送达，已保留待补传。") }
        if status == 200 {
            struct Receipt: Decodable { let ok: Bool; let id: String; let duplicate: Bool }
            guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
                  receipt.ok, receipt.id == expectedID else {
                return .blockDestination("服务器回执不匹配，记录已保留；请检查上报地址与后端版本。")
            }
            return .received
        }
        if [401, 403].contains(status!) { return .blockDestination("上报密钥无效或已撤销，请重新配置。") }
        if [404, 405].contains(status!) { return .blockDestination("服务器尚未接入原生补传入口，请先更新后端。") }
        if status == 400 || status == 409 || status == 413 || status == 422 {
            return .blockEvent("服务器拒绝这条记录（HTTP \(status!)），已保留，未计为成功。")
        }
        if status == 408 || status == 429 || status! >= 500 { return .retry("服务器暂未接收（HTTP \(status!)），稍后补传。") }
        return .blockDestination("上报未获确认（HTTP \(status!)），请检查配置。")
    }
}
enum ActivityQueueError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}

final class AppActivityQueue {
    let directory: URL
    private let file: URL
    private let capacity: Int
    init(directory: URL, capacity: Int = 10000) {
        self.directory = directory; file = directory.appendingPathComponent("journal.json"); self.capacity = capacity
    }
    static func validatedBaseURL(_ value: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var url = URLComponents(string: text), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, !url.path.contains(".."),
              !url.path.contains("%"), !url.path.contains("\\"), text.count <= 2048 else {
            throw ActivityQueueError.message("请填写 HTTPS 服务基址，不含密钥、查询参数或接口路径。")
        }
        url.scheme = "https"; url.host = host.lowercased()
        while url.path.hasSuffix("/") { url.path.removeLast() }
        guard !url.path.hasSuffix("app-events"), !url.path.hasSuffix("queued"), url.url != nil, let result = url.string else {
            throw ActivityQueueError.message("这里填服务基址；App 会自动添加上报接口路径。")
        }
        return result
    }
    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                             ofItemAtPath: directory.path)
        #endif
        var excluded = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        try prepareDirectory()
        let descriptor = open(directory.appendingPathComponent("journal.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw ActivityQueueError.message("本机记录暂时不可写，请解锁后打开 Cove。") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw ActivityQueueError.message("无法锁定本机记录，请稍后再试。") }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
    private func readUnlocked() throws -> ActivityQueueState {
        guard FileManager.default.fileExists(atPath: file.path) else { return ActivityQueueState() }
        let state = try JSONDecoder().decode(ActivityQueueState.self, from: Data(contentsOf: file))
        guard state.version == 1, state.events.count <= capacity,
              Set(state.events.map(\.id)).count == state.events.count,
              Set(state.destinations.map(\.id)).count == state.destinations.count,
              state.destinations.allSatisfy({ (try? Self.validatedBaseURL($0.baseURL)) == $0.baseURL }) else {
            throw ActivityQueueError.message("本机记录格式异常，已停止写入，没有清空旧记录。")
        }
        return state
    }
    private func writeUnlocked(_ state: ActivityQueueState) throws {
        let data = try JSONEncoder().encode(state)
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func snapshot() throws -> ActivityQueueState { try locked { try readUnlocked() } }
    private func change<T>(_ edit: (inout ActivityQueueState) throws -> T) throws -> T {
        try locked {
            var state = try readUnlocked()
            let result = try edit(&state)
            try writeUnlocked(state)
            return result
        }
    }
    func setEnabled(_ enabled: Bool) throws {
        try change { state in
            if enabled && !state.destinations.contains(where: \.enabled) {
                throw ActivityQueueError.message("请先配置至少一个接收端，再开启自动记录。")
            }
            state.enabled = enabled; state.epoch = UUID().uuidString
        }
    }
    func validateDestinationChange(_ recipient: ActivityRecipient, baseURL: String) throws {
        let state = try snapshot()
        if let old = state.destinations.first(where: { $0.id == recipient }),
           old.baseURL != baseURL, state.pending(recipient) > 0 {
            throw ActivityQueueError.message("这个接收端仍有待传记录。请先完成同步或明确放弃待传，再更换地址。")
        }
    }
    func configure(_ destination: ActivityDestination) throws {
        let normalized = try Self.validatedBaseURL(destination.baseURL)
        try change { state in
            if let old = state.destinations.first(where: { $0.id == destination.id }),
               old.baseURL != normalized, state.pending(destination.id) > 0 {
                throw ActivityQueueError.message("待传记录不能改投另一地址。")
            }
            var target = destination; target.baseURL = normalized
            target.revision = UUID().uuidString; target.blocked = nil
            target.lastReceivedAt = state.destinations.first { $0.id == target.id }?.lastReceivedAt
            state.destinations.removeAll { $0.id == target.id }; state.destinations.append(target)
            for i in state.events.indices where state.events[i].deliveries[target.id.rawValue] != nil {
                state.events[i].deliveries[target.id.rawValue]?.nextAttempt = .distantPast
            }
        }
    }
    @discardableResult func enqueue(app: ActivityApp, action: ActivityAction, at date: Date = Date()) throws -> ActivityReceiptEvent? {
        try change { state in
            guard state.enabled else { return nil } // Explicit pause is a quiet no-op, not fabricated activity.
            let recipients = state.destinations.filter(\.enabled)
            guard !recipients.isEmpty else { return nil }
            guard state.events.count < capacity else {
                throw ActivityQueueError.message("本机待传队列已满，旧记录未删除。请打开 Cove 处理同步。")
            }
            let event = ActivityReceiptEvent(app: app, action: action, at: date)
            state.events.append(ActivityPendingEvent(event: event, deliveries:
                Dictionary(uniqueKeysWithValues: recipients.map { ($0.id.rawValue, ActivityDelivery()) })))
            return event
        }
    }
    func apply(_ outcome: ActivityUploadOutcome, identity: ActivityUploadIdentity, at date: Date = Date()) throws {
        try change { state in
            guard identity.isCurrent(in: state),
                  let eventIndex = state.events.firstIndex(where: { $0.id == identity.eventID }),
                  let targetIndex = state.destinations.firstIndex(where: { $0.id == identity.recipient }),
                  var delivery = state.events[eventIndex].deliveries[identity.recipient.rawValue] else { return }
            switch outcome {
            case .received:
                state.events[eventIndex].deliveries.removeValue(forKey: identity.recipient.rawValue)
                state.destinations[targetIndex].lastReceivedAt = date
                state.events.removeAll { $0.deliveries.isEmpty }
                return
            case .retry(let reason):
                delivery.attempts += 1; delivery.error = reason
                let delays: [TimeInterval] = [30, 120, 600, 1800, 3600]
                delivery.nextAttempt = date.addingTimeInterval(delays[min(delivery.attempts - 1, delays.count - 1)])
            case .blockEvent(let reason): delivery.blocked = true; delivery.error = reason
            case .blockDestination(let reason): state.destinations[targetIndex].blocked = reason; delivery.error = reason
            }
            state.events[eventIndex].deliveries[identity.recipient.rawValue] = delivery
        }
    }
    func retry() throws {
        try change { state in
            state.epoch = UUID().uuidString
            for i in state.destinations.indices { state.destinations[i].blocked = nil }
            for i in state.events.indices {
                for key in Array(state.events[i].deliveries.keys) {
                    state.events[i].deliveries[key]?.blocked = false
                    state.events[i].deliveries[key]?.nextAttempt = .distantPast
                }
            }
        }
    }
    func discardPending() throws {
        try change { state in state.epoch = UUID().uuidString; state.events.removeAll() }
    }
    func payloadFile(for event: ActivityReceiptEvent) throws -> URL {
        try locked {
            guard UUID(uuidString: event.id) != nil else { throw ActivityQueueError.message("记录 ID 无效。") }
            let url = directory.appendingPathComponent(event.id + ".json")
            let data = try JSONEncoder().encode(event)
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        }
    }
    func cleanPayloads(keeping ids: Set<String>) throws {
        try locked {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let id = url.deletingPathExtension().lastPathComponent
                if url.pathExtension == "json", UUID(uuidString: id) != nil, !ids.contains(id) {
                    try FileManager.default.removeItem(at: url)
                }
            }
        }
    }
}
