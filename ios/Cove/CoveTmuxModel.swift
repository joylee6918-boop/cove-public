import Foundation

/// The existing CLI runtime's persistent tmux pane, not an independent shell.
struct CoveTmuxSnapshot: Codable, Equatable {
    let sessionID: String
    let conversationID: String
    let threadID: String
    let state: String // running, unavailable, terminated
    let output: String // complete plain-text capture, not an event delta or ANSI terminal
    let revision: Int
    let inputAvailable: Bool?
    let allowedKeys: [String]?

    init(sessionID: String, conversationID: String, threadID: String, state: String,
         output: String, revision: Int, inputAvailable: Bool? = nil,
         allowedKeys: [String]? = nil) {
        self.sessionID = sessionID
        self.conversationID = conversationID
        self.threadID = threadID
        self.state = state
        self.output = output
        self.revision = revision
        self.inputAvailable = inputAvailable
        self.allowedKeys = allowedKeys
    }
}

struct CoveTmuxAPI {
    let attach: () async throws -> CoveTmuxSnapshot
    let capture: (_ sessionID: String) async throws -> CoveTmuxSnapshot
    let input: (_ sessionID: String, _ text: String, _ requestID: UUID) async throws -> Void
    let key: (_ sessionID: String, _ key: String, _ requestID: UUID) async throws -> Void
    let terminate: (_ sessionID: String, _ requestID: UUID) async throws -> Void
    let recover: ((_ sessionID: String, _ requestID: UUID) async throws -> CoveTmuxSnapshot)?

    init(attach: @escaping () async throws -> CoveTmuxSnapshot,
         capture: @escaping (_ sessionID: String) async throws -> CoveTmuxSnapshot,
         input: @escaping (_ sessionID: String, _ text: String, _ requestID: UUID) async throws -> Void,
         key: @escaping (_ sessionID: String, _ key: String, _ requestID: UUID) async throws -> Void,
         terminate: @escaping (_ sessionID: String, _ requestID: UUID) async throws -> Void,
         recover: ((_ sessionID: String, _ requestID: UUID) async throws -> CoveTmuxSnapshot)? = nil) {
        self.attach = attach
        self.capture = capture
        self.input = input
        self.key = key
        self.terminate = terminate
        self.recover = recover
    }
}

@MainActor
final class CoveTmuxModel: ObservableObject {
    @Published private(set) var snapshot: CoveTmuxSnapshot?
    @Published private(set) var isAttaching = false
    @Published private(set) var isWriting = false
    @Published private(set) var isWatching = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var uncertainWriteMessage: String?

    private let api: CoveTmuxAPI
    private var conversationID: String
    private var generation = UUID()
    private var polling: Task<Void, Never>?
    private var active = false
    private var writeToken: UUID?
    private var recoveryNeedsReattach = false
    private static let allowedKeys: Set<String> = ["Enter", "C-c", "Escape", "BS", "Tab", "Up", "Down", "Left", "Right"]

    var capturedLineCount: Int {
        guard let output = snapshot?.output, !output.isEmpty else { return 0 }
        let lines = output.components(separatedBy: "\n")
        return lines.count - (output.hasSuffix("\n") ? 1 : 0)
    }

    var canSendText: Bool {
        active && !isWriting && snapshot?.state == "running" && snapshot?.inputAvailable == true
    }

    var canRecover: Bool {
        active && !isWriting && !recoveryNeedsReattach && api.recover != nil && snapshot?.state == "terminated"
            && snapshot?.conversationID == conversationID
            && snapshot?.sessionID.isEmpty == false && snapshot?.threadID.isEmpty == false
    }

    func canSendKey(_ key: String) -> Bool {
        guard Self.allowedKeys.contains(key), active, !isWriting,
              snapshot?.state == "running", snapshot?.allowedKeys?.contains(key) == true else { return false }
        // C-c interrupts the known active turn. Every other key requires the
        // still-unimplemented native input/turn ownership synchronizer.
        return key == "C-c" || snapshot?.inputAvailable == true
    }

    init(api: CoveTmuxAPI, conversationID: String) {
        self.api = api
        self.conversationID = conversationID
    }

    deinit { polling?.cancel() }

    func enter() async {
        guard !active else { return }
        active = true
        let token = UUID()
        generation = token
        isAttaching = true
        errorMessage = nil
        // attach MUST only find the runtime-owned existing session; it must not create one.
        do {
            let received = try await api.attach()
            guard active, generation == token else { return }
            if accept(received, attaching: true) {
                if recoveryNeedsReattach {
                    recoveryNeedsReattach = false
                    uncertainWriteMessage = nil
                }
                isAttaching = false
                startPolling(token: token)
            } else {
                active = false
                isAttaching = false
            }
        } catch {
            guard active, generation == token else { return }
            active = false // A later explicit reconnect may try attach again.
            isAttaching = false
            errorMessage = "附着失败：\(error.localizedDescription)"
        }
    }

    /// Leaving, backgrounding and deallocation never kill the tmux session.
    func detach() {
        active = false
        generation = UUID()
        polling?.cancel()
        polling = nil
        isWatching = false
        isAttaching = false
    }

    func switchConversation(to id: String) {
        guard id != conversationID else { return }
        detach()
        conversationID = id
        snapshot = nil
        errorMessage = nil
        uncertainWriteMessage = nil
        recoveryNeedsReattach = false
    }

    func captureNow() async {
        guard active, let current = snapshot,
              current.state == "running" || current.state == "unavailable" else { return }
        let token = generation
        do {
            let received = try await api.capture(current.sessionID)
            guard active, generation == token else { return }
            _ = accept(received, attaching: false)
        } catch {
            guard active, generation == token else { return }
            errorMessage = "画面更新失败：\(error.localizedDescription)"
        }
    }

    /// Sends literal bytes only. In particular, this does not append Enter.
    func sendText(_ text: String) async {
        guard canSendText else {
            errorMessage = "自由输入的回合同步尚未接完；当前不可发送文字。"
            return
        }
        guard !text.isEmpty, text.utf8.count <= 64 * 1024 else {
            errorMessage = "输入不能为空，且单次最多 64 KiB。"
            return
        }
        guard !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            errorMessage = "输入只能包含普通文字；换行和控制键请使用单独按键。"
            return
        }
        _ = await write(allowUnavailable: false) { api, id, requestID in try await api.input(id, text, requestID) }
    }

    func sendKey(_ key: String) async {
        guard canSendKey(key) else {
            errorMessage = "当前会话不允许这个按键；可用操作以服务端能力为准。"
            return
        }
        _ = await write(allowUnavailable: false) { api, id, requestID in try await api.key(id, key, requestID) }
    }

    /// Call only from the View's native destructive confirmation action.
    func forceTerminate(expectedSessionID: String? = nil) async {
        if let expectedSessionID, snapshot?.sessionID != expectedSessionID {
            errorMessage = "当前会话已变化，请重新确认强制退出。"
            return
        }
        _ = await write(allowUnavailable: true, terminateOnAck: true) { api, id, requestID in
            try await api.terminate(id, requestID)
        }
    }

    /// Explicitly resumes the same native thread in a fresh runtime-owned pane.
    /// The old message is never resent, and an unknown result is never retried.
    func recover(expectedSessionID: String, expectedThreadID: String) async {
        guard snapshot?.sessionID == expectedSessionID,
              snapshot?.threadID == expectedThreadID else {
            errorMessage = "当前会话已变化，请重新确认恢复。"
            return
        }
        guard canRecover, let current = snapshot, let operation = api.recover else {
            errorMessage = "当前对话没有可恢复的已终止会话。"
            return
        }
        let token = generation
        let requestID = UUID()
        writeToken = requestID
        isWriting = true
        errorMessage = nil
        do {
            let received = try await operation(current.sessionID, requestID)
            if writeToken == requestID { writeToken = nil; isWriting = false }
            guard active, generation == token else { return }
            guard snapshot?.sessionID == current.sessionID, snapshot?.state == "terminated",
                  received.conversationID == current.conversationID,
                  received.threadID == current.threadID,
                  !received.sessionID.isEmpty, received.revision >= 0,
                  received.state == "running" || received.state == "unavailable" else {
                recoveryNeedsReattach = true
                uncertainWriteMessage = "恢复结果无法验证（请求 \(requestID.uuidString)）。请重新附着查看，勿自动重试。"
                return
            }
            snapshot = received
            errorMessage = nil
            uncertainWriteMessage = nil
            recoveryNeedsReattach = false
            startPolling(token: token)
        } catch {
            if writeToken == requestID { writeToken = nil; isWriting = false }
            guard active, generation == token else { return }
            recoveryNeedsReattach = true
            uncertainWriteMessage = "恢复结果不确定（请求 \(requestID.uuidString)）。请重新附着查看，勿自动重试。\(error.localizedDescription)"
        }
    }

    @discardableResult
    private func write(allowUnavailable: Bool, terminateOnAck: Bool = false,
                       _ operation: (CoveTmuxAPI, String, UUID) async throws -> Void) async -> Bool {
        guard active, !isWriting, let current = snapshot,
              current.state == "running" || (allowUnavailable && current.state == "unavailable"),
              current.conversationID == conversationID, !current.sessionID.isEmpty else {
            errorMessage = "当前对话没有可操作的运行中会话。"
            return false
        }
        let token = generation
        let requestID = UUID()
        writeToken = requestID
        isWriting = true
        errorMessage = nil
        do {
            // At most one invocation: never retry a non-idempotent write on timeout/error.
            try await operation(api, current.sessionID, requestID)
            if writeToken == requestID { writeToken = nil; isWriting = false }
            guard generation == token else { return false }
            if terminateOnAck {
                // The terminate ACK is authoritative even if the next capture fails.
                // It confirms this tmux session request, not every descendant process.
                if let latest = snapshot, latest.sessionID == current.sessionID,
                   latest.conversationID == current.conversationID {
                    snapshot = CoveTmuxSnapshot(sessionID: latest.sessionID,
                                                conversationID: latest.conversationID,
                                                threadID: latest.threadID,
                                                state: "terminated", output: latest.output,
                                                revision: latest.revision,
                                                inputAvailable: false, allowedKeys: [])
                    polling?.cancel()
                    polling = nil
                    isWatching = false
                }
            } else {
                await captureNow()
            }
            return true
        } catch {
            if writeToken == requestID { writeToken = nil; isWriting = false }
            guard generation == token else { return false }
            uncertainWriteMessage = "操作结果不确定（请求 \(requestID.uuidString)）。先查看画面，勿自动重发。\(error.localizedDescription)"
            return false
        }
    }

    private func accept(_ incoming: CoveTmuxSnapshot, attaching: Bool) -> Bool {
        guard incoming.conversationID == conversationID else {
            errorMessage = "服务端返回了其他对话的会话，已拒绝显示和操作。"
            return false
        }
        guard ["running", "unavailable", "terminated"].contains(incoming.state),
              incoming.revision >= 0 else {
            errorMessage = "会话状态无效。"
            return false
        }
        if incoming.state == "running" && (incoming.sessionID.isEmpty || incoming.threadID.isEmpty) {
            errorMessage = "运行中会话缺少标识。"
            return false
        }
        if !attaching, let current = snapshot {
            guard incoming.sessionID == current.sessionID,
                  incoming.threadID == current.threadID,
                  incoming.revision >= current.revision,
                  current.state != "terminated" || incoming.state == "terminated" else { return false }
        }
        snapshot = incoming
        errorMessage = nil
        return true
    }

    private func startPolling(token: UUID) {
        polling?.cancel()
        guard snapshot?.state == "running" || snapshot?.state == "unavailable" else { isWatching = false; return }
        isWatching = true
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.active, self.generation == token else { return }
                await self.captureNow()
                guard self.snapshot?.state == "running" || self.snapshot?.state == "unavailable" else {
                    self.isWatching = false; return
                }
            }
        }
    }
}
