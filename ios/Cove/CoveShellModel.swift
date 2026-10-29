import Foundation

struct CoveShellEvent: Codable, Identifiable, Equatable {
    let id: Int
    let stream: String
    let dataBase64: String
    let capReached: Bool
}

struct CoveShellSnapshot: Codable {
    let id: String
    let state: String
    let exitCode: Int?
    let events: [CoveShellEvent]
    let cursor: Int
    let ansi: String
}

struct CoveShellAPI {
    let start: (_ rows: Int, _ cols: Int) async throws -> CoveShellSnapshot
    let poll: (_ sessionID: String, _ after: Int) async throws -> CoveShellSnapshot
    let write: (_ sessionID: String, _ dataBase64: String, _ closeStdin: Bool) async throws -> Void
    let resize: (_ sessionID: String, _ rows: Int, _ cols: Int) async throws -> Void
    let terminate: (_ sessionID: String) async throws -> Void
}

@MainActor
final class CoveShellController: ObservableObject {
    @Published private(set) var sessionID: String?
    @Published private(set) var state = "idle"
    @Published private(set) var output = ""
    @Published private(set) var cursor = 0
    @Published private(set) var isStarting = false
    @Published private(set) var isWriting = false
    @Published var errorMessage: String?
    private let api: CoveShellAPI
    private var polling: Task<Void, Never>?
    private var generation = UUID()
    private var wantsConnection = false
    private var isForeground = true
    private let maximumCharacters = 200_000
    private var pendingUTF8 = Data()

    init(api: CoveShellAPI) { self.api = api }
    deinit { polling?.cancel() }

    /// Start is also an owner-scoped attach on the server. No command is replayed.
    func start() async {
        guard !isStarting, !isWriting, state != "stopping" else { return }
        isStarting = true; errorMessage = nil
        if sessionID == nil { state = "connecting" }
        let current = UUID(); generation = current
        defer { if generation == current { isStarting = false } }
        do {
            let snapshot = try await api.start(30, 100)
            guard generation == current else { return }
            if sessionID != snapshot.id {
                output = ""; pendingUTF8.removeAll(keepingCapacity: true); cursor = 0
            }
            sessionID = snapshot.id; apply(snapshot)
            if wantsConnection, isForeground, state == "running" { beginPolling(snapshot.id) }
        } catch {
            guard generation == current else { return }
            errorMessage = error.localizedDescription; state = "failed"
        }
    }

    private func beginPolling(_ id: String) {
        polling?.cancel()
        let current = generation
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let owner = self, owner.wantsConnection, owner.isForeground, owner.generation == current,
                      owner.sessionID == id, owner.state == "running" else { return }
                let after = owner.cursor
                do {
                    let update = try await owner.api.poll(id, after)
                    guard !Task.isCancelled, owner.wantsConnection, owner.isForeground, owner.generation == current,
                          owner.sessionID == id else { return }
                    owner.apply(update)
                } catch {
                    guard !Task.isCancelled, owner.generation == current, owner.wantsConnection else { return }
                    owner.errorMessage = error.localizedDescription
                }
                // Do not hold a view/controller through an unbounded poll lifetime.
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func enterView() async {
        wantsConnection = true; isForeground = true
        if isWriting, let sessionID { beginPolling(sessionID) }
        else if !isStarting { await start() }
    }

    func resumeIfNeeded() async {
        isForeground = true
        guard wantsConnection, !isStarting else { return }
        if isWriting, let sessionID { beginPolling(sessionID) } else { await start() }
    }

    func sendLine(_ line: String) async -> Bool {
        guard let sessionID, state == "running", !isStarting, !isWriting else { return false }
        guard let bytes = (line + "\n").data(using: .utf8), bytes.count <= 64 * 1024 else {
            errorMessage = "单次输入最多 64 KiB。"; return false
        }
        let current = generation
        isWriting = true
        defer { if generation == current { isWriting = false } }
        do {
            try await api.write(sessionID, bytes.base64EncodedString(), false)
            return generation == current && self.sessionID == sessionID && state == "running"
        } catch {
            if generation == current { errorMessage = "输入结果未确认，未自动重发。\(error.localizedDescription)" }
            return false
        }
    }

    func sendControl(_ byte: UInt8) async {
        guard let sessionID, state == "running", !isStarting, !isWriting else { return }
        let current = generation
        isWriting = true
        defer { if generation == current { isWriting = false } }
        do { try await api.write(sessionID, Data([byte]).base64EncodedString(), false) }
        catch { if generation == current { errorMessage = error.localizedDescription } }
    }

    func terminate() async {
        // Only the explicit confirmed End action comes here; leave/background
        // detach instead. Do not claim termination when its ACK is unknown.
        guard !isStarting else { return }
        let current = UUID(); generation = current; isWriting = false
        polling?.cancel(); polling = nil
        guard let sessionID else { state = "idle"; return }
        state = "stopping"
        do {
            try await api.terminate(sessionID)
            guard generation == current else { return }
            state = "terminated"
        } catch {
            guard generation == current else { return }
            state = "unknown"; errorMessage = "结束结果未确认，请重新连接查看。\(error.localizedDescription)"
        }
    }

    func leaveView() async {
        wantsConnection = false
        polling?.cancel(); polling = nil
    }

    func background() async {
        // Keep the server PTY; its existing idle/lifetime limits still apply.
        isForeground = false
        polling?.cancel(); polling = nil
    }

    func closeSession() async {
        wantsConnection = false
        await terminate()
    }

    private func apply(_ snapshot: CoveShellSnapshot) {
        guard sessionID == nil || snapshot.id == sessionID else { return }
        for event in snapshot.events where event.id > cursor {
            guard let data = Data(base64Encoded: event.dataBase64) else { continue }
            pendingUTF8.append(data)
            let safe = completeUTF8PrefixLength(pendingUTF8)
            if safe > 0 {
                output += String(decoding: pendingUTF8.prefix(safe), as: UTF8.self)
                pendingUTF8.removeFirst(safe)
            }
            if event.capReached { output += "\n[输出已达服务端上限]\n" }
        }
        if output.count > maximumCharacters { output.removeFirst(output.count - maximumCharacters) }
        cursor = max(cursor, snapshot.cursor); state = snapshot.state
        if snapshot.state != "running" {
            if !pendingUTF8.isEmpty { output += String(decoding: pendingUTF8, as: UTF8.self); pendingUTF8.removeAll() }
            if let code = snapshot.exitCode { output += "\n[exit \(code)]\n" }
        }
    }

    /// Keeps only a potentially incomplete trailing UTF-8 scalar for the next
    /// PTY chunk. Invalid complete bytes are rendered lossily rather than held.
    private func completeUTF8PrefixLength(_ data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        let bytes = [UInt8](data), end = bytes.count
        var lead = end - 1
        var continuations = 0
        while lead > 0, bytes[lead] & 0xC0 == 0x80, continuations < 3 { continuations += 1; lead -= 1 }
        let first = bytes[lead]
        let expected: Int
        if first < 0x80 { expected = 1 }
        else if first & 0xE0 == 0xC0 { expected = 2 }
        else if first & 0xF0 == 0xE0 { expected = 3 }
        else if first & 0xF8 == 0xF0 { expected = 4 }
        else { return end }
        return end - lead < expected ? lead : end
    }
}
