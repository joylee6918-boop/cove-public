import Foundation
import Combine

struct CoveTerminalEvent: Decodable, Identifiable, Equatable {
    let id: Int
    let kind: String
    let text: String
    let createdAt: Date
    let threadID: String?
    let turnID: String?
    let itemID: String?
}

struct CoveTerminalApproval: Decodable, Identifiable, Equatable {
    let id: String
    let kind: String
    let command: String?
    let cwd: String?
    let reason: String?
    let details: String?
    let createdAt: Date
    let expiresAt: Date
    let threadID: String
    let turnID: String
    let itemID: String
    let decisions: [String]
}

struct CoveTerminalSnapshot: Decodable {
    let conversationID: String
    let cursor: Int
    let events: [CoveTerminalEvent]
    let busy: Bool
    let connected: Bool
    let threadID: String?
    let turnID: String?
    let model: String?
    let effort: String?
    let pendingApprovals: [CoveTerminalApproval]
}

struct CoveTerminalModelOption: Decodable, Identifiable, Equatable {
    let id: String
    let model: String
    let displayName: String
    let supportedEfforts: [String]
    let defaultEffort: String
}

struct CoveTerminalModelList: Decodable {
    let models: [CoveTerminalModelOption]
    let updatedAt: Date
}

struct CoveTerminalActionResult: Decodable {
    let ok: Bool
    let kind: String?
    let model: String?
    let effort: String?
    let text: String?
}

@MainActor
protocol CoveTerminalService {
    func snapshot(conversationID: String, after: Int, tail: Bool) async throws -> CoveTerminalSnapshot
    func models() async throws -> CoveTerminalModelList
    func input(id: String, conversationID: String, text: String) async throws -> CoveTerminalActionResult
    func setModel(conversationID: String, model: String, effort: String) async throws -> CoveTerminalActionResult
    func approve(conversationID: String, approval: CoveTerminalApproval, decision: String) async throws -> CoveTerminalActionResult
    func newContext(model: String?, effort: String?) async throws -> String
}

@MainActor
struct CoveStoreTerminalService: CoveTerminalService {
    let store: CoveStore
    func snapshot(conversationID: String, after: Int, tail: Bool) async throws -> CoveTerminalSnapshot {
        try await store.terminalRequest("v1/terminal", query: [URLQueryItem(name: "conversationID", value: conversationID), URLQueryItem(name: "after", value: String(tail ? 0 : after)), URLQueryItem(name: "tail", value: tail ? "1" : "0")])
    }
    func models() async throws -> CoveTerminalModelList { try await store.terminalRequest("v1/terminal/models") }
    func input(id: String, conversationID: String, text: String) async throws -> CoveTerminalActionResult {
        try await store.terminalRequest("v1/terminal/input", method: "POST", body: ["id": id, "conversationID": conversationID, "text": text])
    }
    func setModel(conversationID: String, model: String, effort: String) async throws -> CoveTerminalActionResult {
        try await store.terminalRequest("v1/terminal/model", method: "POST", body: ["conversationID": conversationID, "model": model, "effort": effort])
    }
    func approve(conversationID: String, approval: CoveTerminalApproval, decision: String) async throws -> CoveTerminalActionResult {
        try await store.terminalRequest("v1/terminal/approval", method: "POST", body: ["conversationID": conversationID, "approvalID": approval.id, "threadID": approval.threadID, "turnID": approval.turnID, "decision": decision])
    }
    func newContext(model: String?, effort: String?) async throws -> String {
        try await store.terminalNewConversation(inheritingModel: model, effort: effort)
    }
}

@MainActor
final class CoveTerminalViewModel: ObservableObject {
    @Published private(set) var events: [CoveTerminalEvent] = []
    @Published private(set) var approvals: [CoveTerminalApproval] = []
    @Published private(set) var models: [CoveTerminalModelOption] = []
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var isPolling = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var isStopping = false
    @Published private(set) var isChangingModel = false
    @Published private(set) var approvalInFlight: String?
    @Published private(set) var model: String?
    @Published private(set) var effort: String?
    @Published private(set) var error: String?
    @Published private(set) var modelError: String?
    @Published private(set) var connectionError: String?
    @Published private(set) var notice: String?
    @Published var draft = ""
    private(set) var cursor = 0
    private(set) var conversationID = ""
    private var service: (any CoveTerminalService)?
    private var runID = UUID()
    private var pendingInput: (id: String, text: String)?
    private var pendingControl: (id: String, text: String)?
    private var pendingStop: (id: String, text: String)?
    private var needsTail = true

    #if DEBUG
    // Explicit synthetic UI fixture. No service is assigned and no polling or
    // production control action is enabled by this path.
    func loadLocalScrollFixture() {
        guard service == nil else { return }
        conversationID = "terminal-local-scroll-fixture"
        events = (1...120).map { id in
            CoveTerminalEvent(id: id, kind: "local-fixture", text: "合成日志 \(id)\n本地滚动测试，不是实际执行结果。",
                              createdAt: Date(timeIntervalSince1970: Double(id)), threadID: nil, turnID: nil, itemID: nil)
        }
        cursor = 120
    }

    func appendLocalScrollFixture(growingLastEvent: Bool = false) {
        guard service == nil, conversationID == "terminal-local-scroll-fixture", let last = events.last else { return }
        if growingLastEvent {
            events[events.count - 1] = CoveTerminalEvent(id: last.id, kind: last.kind,
                text: last.text + String(repeating: "\n同一条示例日志继续输出，内容变高。", count: 12),
                createdAt: last.createdAt, threadID: nil, turnID: nil, itemID: nil)
        } else {
            let id = last.id + 1
            events.append(CoveTerminalEvent(id: id, kind: "local-fixture", text: "合成新增日志 \(id)\n新内容应自动跟随，无需手动拖动。",
                createdAt: Date(timeIntervalSince1970: Double(id)), threadID: nil, turnID: nil, itemID: nil))
            cursor = id
        }
    }
    #endif

    // The SwiftUI sheet owns this task, so closing/backgrounding cancels polling.
    func run(service: any CoveTerminalService, conversationID: String, preview: Bool) async {
        guard !preview, !conversationID.isEmpty else { return }
        let token = UUID()
        runID = token
        if self.conversationID != conversationID {
            self.conversationID = conversationID
            events = []; approvals = []; cursor = 0; draft = ""; pendingInput = nil; pendingControl = nil; pendingStop = nil
            connected = false; busy = false; model = nil; effort = nil; notice = nil
        }
        self.service = service
        needsTail = true
        isPolling = true
        defer { if runID == token { isPolling = false } }
        await refresh()
        await refreshModels()
        while !Task.isCancelled && runID == token {
            await refresh()
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    func refresh() async {
        guard let service, !conversationID.isEmpty else { return }
        let context = conversationID
        let token = runID
        do {
            // Initial/opening loads the latest page in one response. Subsequent pages
            // advance immediately, preserving all incremental events without a one-second page delay.
            for _ in 0..<10 {
                let tail = needsTail
                let previous = cursor
                let snapshot = try await service.snapshot(conversationID: context, after: tail ? 0 : cursor, tail: tail)
                try Task.checkCancellation()
                guard context == conversationID, token == runID else { return }
                apply(snapshot, replacing: tail)
                needsTail = false
                if tail || snapshot.events.count < 200 || cursor <= previous { break }
            }
            connectionError = nil
        } catch is CancellationError { return }
        catch { if token == runID { connected = false; connectionError = connectionMessage(for: error) } }
    }

    // The response cursor belongs to one conversation; never mix another thread's events.
    func apply(_ snapshot: CoveTerminalSnapshot, replacing: Bool = false) {
        guard snapshot.conversationID == conversationID else { return }
        var merged = Dictionary(uniqueKeysWithValues: (replacing ? [] : events).map { ($0.id, $0) })
        for event in snapshot.events { merged[event.id] = event }
        events = Array(merged.values.sorted { $0.id < $1.id }.suffix(2_000))
        cursor = replacing ? snapshot.cursor : max(cursor, snapshot.cursor)
        approvals = snapshot.pendingApprovals
        connected = snapshot.connected
        busy = snapshot.busy
        model = snapshot.model
        effort = snapshot.effort
    }

    func refreshModels() async {
        guard let service else { return }
        let token = runID
        do {
            let result = try await service.models()
            try Task.checkCancellation()
            guard token == runID else { return }
            models = result.models
            modelError = nil
        } catch is CancellationError { return }
        catch { if token == runID { modelError = error.localizedDescription } }
    }

    func submit() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let service, !text.isEmpty, !isSubmitting, isPolling else { return }
        if text == "/clear" { await clearContext(); return }
        if pendingInput?.text != text { pendingInput = (UUID().uuidString, text) }
        guard let request = pendingInput else { return }
        let context = conversationID
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let result = try await service.input(id: request.id, conversationID: context, text: text)
            guard result.ok else { throw TerminalError.unconfirmed }
            guard context == conversationID else { return }
            if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
            pendingInput = nil
            error = nil
            switch result.kind {
            case "stop": notice = "已提交停止请求。"
            case "model": notice = "模型设置已保存，下一次回复生效。"
            case "help": notice = result.text
            default: notice = "指令已进入当前会话队列。"
            }
            await refresh()
        } catch {
            if context == conversationID { self.error = error.localizedDescription + "；输入已保留，可再次提交确认。" }
        }
    }

    // Both the shortcut and typed /clear reach this after the view confirms intent.
    // The service creates a real context and retains the previous conversation.
    func clearContext() async {
        guard let service, !isSubmitting, isPolling else { return }
        let context = conversationID
        let token = runID
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let next = try await service.newContext(model: model, effort: effort)
            guard context == conversationID, token == runID else { return }
            conversationID = next
            events = []; approvals = []; cursor = 0; draft = ""; pendingInput = nil; pendingControl = nil; pendingStop = nil
            needsTail = true; busy = false
            notice = "已开启新对话，旧记录保留。"; error = nil
            await refresh()
        } catch {
            if context == conversationID, token == runID { self.error = error.localizedDescription }
        }
    }

    // Cancellation must not wait behind a stalled ordinary input request.
    func stopCurrentReply() async {
        guard let service, !isStopping, isPolling else { return }
        let context = conversationID
        if pendingStop == nil { pendingStop = (UUID().uuidString, "/stop") }
        guard let request = pendingStop else { return }
        isStopping = true
        defer { isStopping = false }
        do {
            let result = try await service.input(id: request.id, conversationID: context, text: request.text)
            guard result.ok else { throw TerminalError.unconfirmed }
            guard context == conversationID else { return }
            pendingStop = nil
            notice = "已提交停止当前回复的请求。"
            error = nil
            await refresh()
        } catch {
            if context == conversationID {
                self.error = error.localizedDescription + "；停止请求未确认，可再点一次。"
            }
        }
    }
    func showHelp() async { await control("/help") }

    private func control(_ text: String) async {
        guard let service, !isSubmitting, isPolling else { return }
        let context = conversationID
        if pendingControl?.text != text { pendingControl = (UUID().uuidString, text) }
        guard let request = pendingControl else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let result = try await service.input(id: request.id, conversationID: context, text: text)
            guard result.ok else { throw TerminalError.unconfirmed }
            guard context == conversationID else { return }
            pendingControl = nil
            notice = result.kind == "help" ? result.text : "已提交停止当前回复的请求。"
            error = nil
            await refresh()
        } catch {
            if context == conversationID { self.error = error.localizedDescription }
        }
    }

    func changeModel(_ selected: CoveTerminalModelOption, effort selectedEffort: String) async -> Bool {
        guard let service, !isChangingModel, selected.supportedEfforts.contains(selectedEffort) else { return false }
        let context = conversationID
        isChangingModel = true
        defer { isChangingModel = false }
        do {
            let result = try await service.setModel(conversationID: context, model: selected.model, effort: selectedEffort)
            guard result.ok else { throw TerminalError.unconfirmed }
            guard context == conversationID else { return false }
            model = result.model ?? selected.model
            effort = result.effort ?? selectedEffort
            notice = "模型设置已保存，下一次回复生效。"
            error = nil
            return true
        } catch { if context == conversationID { self.error = error.localizedDescription }; return false }
    }

    func decide(_ approval: CoveTerminalApproval, allow: Bool) async -> Bool {
        let decision = allow ? "accept" : "decline"
        guard let service, approvalInFlight == nil, approval.decisions.contains(decision) else { return false }
        guard approval.expiresAt > Date(), approvals.contains(where: { $0.id == approval.id && $0.turnID == approval.turnID }) else {
            error = "这项审核已结束或过期，请等待列表刷新。"; return false
        }
        let context = conversationID
        approvalInFlight = approval.id
        defer { approvalInFlight = nil }
        do {
            let result = try await service.approve(conversationID: context, approval: approval, decision: decision)
            guard result.ok else { throw TerminalError.unconfirmed }
            guard context == conversationID else { return false }
            approvals.removeAll { $0.id == approval.id }
            notice = allow ? "已允许这一次操作。" : "已拒绝这一次操作。"
            error = nil
            await refresh()
            return true
        } catch { if context == conversationID { self.error = error.localizedDescription }; await refresh(); return false }
    }

    private enum TerminalError: LocalizedError {
        case unconfirmed
        var errorDescription: String? { "服务没有确认这次操作" }
    }

    private func connectionMessage(for error: Error) -> String {
        let value = error as NSError
        guard value.domain == NSURLErrorDomain else {
            return error.localizedDescription + "；请检查 Cove 服务状态后点“刷新”。"
        }
        switch URLError.Code(rawValue: value.code) {
        case .timedOut:
            return "连接 Cove 服务超时。可先点“Esc · 停止”，再检查网络或服务状态。"
        case .notConnectedToInternet, .networkConnectionLost:
            return "当前网络不可用或已中断；恢复后点“刷新”。"
        case .cannotFindHost, .cannotConnectToHost:
            return "无法连接 Cove 服务地址；请核对设置中的服务地址和服务状态。"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot:
            return "Cove 服务的 HTTPS 连接未通过安全校验；请检查证书和系统时间。"
        default:
            return error.localizedDescription + "；请检查网络和 Cove 服务状态后点“刷新”。"
        }
    }
}
