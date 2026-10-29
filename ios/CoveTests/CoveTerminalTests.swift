import XCTest
@testable import Cove

@MainActor
final class CoveTerminalTests: XCTestCase {
    func testFailedInputRetryReusesIDAndKeepsDraftUntilAcknowledged() async throws {
        let service = FakeTerminalService()
        let terminal = CoveTerminalViewModel()
        let running = try await start(terminal, service: service)
        defer { running.cancel() }
        service.failNextInput = true
        terminal.draft = "检查当前项目的构建状态"
        await terminal.submit()
        XCTAssertEqual(terminal.draft, "检查当前项目的构建状态")
        XCTAssertNotNil(terminal.error)
        await terminal.submit()
        XCTAssertEqual(service.inputIDs.count, 2)
        XCTAssertEqual(service.inputIDs[0], service.inputIDs[1])
        XCTAssertEqual(terminal.draft, "")
        XCTAssertEqual(service.inputConversations, ["current", "current"])
    }

    func testSnapshotCannotMixConversationsAndDeduplicatesEvents() async throws {
        let service = FakeTerminalService()
        let terminal = CoveTerminalViewModel()
        let running = try await start(terminal, service: service)
        defer { running.cancel() }
        terminal.apply(FakeTerminalService.makeSnapshot(conversationID: "other", cursor: 999, events: [FakeTerminalService.event(999)]))
        XCTAssertEqual(terminal.cursor, 1)
        XCTAssertEqual(terminal.events.map(\.id), [1])
        terminal.apply(FakeTerminalService.makeSnapshot(cursor: 2, events: [FakeTerminalService.event(1), FakeTerminalService.event(2)]))
        XCTAssertEqual(terminal.events.map(\.id), [1, 2])
        XCTAssertEqual(terminal.cursor, 2)
    }

    func testExpiredApprovalIsNeverSubmitted() async throws {
        let service = FakeTerminalService()
        let terminal = CoveTerminalViewModel()
        let running = try await start(terminal, service: service)
        defer { running.cancel() }
        let approval = CoveTerminalApproval(id: "expired", kind: "command", command: "pwd", cwd: nil, reason: nil, details: nil,
                                            createdAt: .distantPast, expiresAt: .distantPast, threadID: "thread", turnID: "turn", itemID: "item", decisions: ["accept", "decline"])
        terminal.apply(FakeTerminalService.makeSnapshot(approvals: [approval]))
        let accepted = await terminal.decide(approval, allow: true)
        XCTAssertFalse(accepted)
        XCTAssertEqual(service.approvalRequests, 0)
        XCTAssertTrue(terminal.error?.contains("过期") == true)
    }

    func testPreviewDoesNotPollOrLoadModels() async {
        let service = FakeTerminalService()
        let terminal = CoveTerminalViewModel()
        await terminal.run(service: service, conversationID: "current", preview: true)
        XCTAssertEqual(service.snapshotRequests, 0)
        XCTAssertEqual(service.modelRequests, 0)
        XCTAssertFalse(terminal.isPolling)
    }

    func testOpeningLoadsLatestPageInsteadOfWalkingOldHistory() async throws {
        let service = FakeTerminalService()
        service.snapshots = [FakeTerminalService.makeSnapshot(cursor: 999, events: (800...999).map(FakeTerminalService.event))]
        let terminal = CoveTerminalViewModel()
        let running = try await start(terminal, service: service, expectedCursor: 999)
        defer { running.cancel() }
        XCTAssertEqual(service.snapshotQueries.first?.after, 0)
        XCTAssertEqual(service.snapshotQueries.first?.tail, true)
        XCTAssertEqual(terminal.events.first?.id, 800)
        XCTAssertEqual(terminal.events.last?.id, 999)
        XCTAssertFalse(service.snapshotQueries.dropFirst().contains { $0.tail })
    }

    func testIncrementalFullPageImmediatelyReadsNextPageWithoutDroppingEvents() async throws {
        let service = FakeTerminalService()
        let terminal = CoveTerminalViewModel()
        let running = try await start(terminal, service: service)
        defer { running.cancel() }
        service.snapshots = [FakeTerminalService.makeSnapshot(cursor: 201, events: (2...201).map(FakeTerminalService.event)),
                             FakeTerminalService.makeSnapshot(cursor: 202, events: [FakeTerminalService.event(202)])]
        let before = service.snapshotQueries.count
        await terminal.refresh()
        XCTAssertEqual(terminal.events.map(\.id), Array(1...202))
        let queries = Array(service.snapshotQueries.dropFirst(before))
        XCTAssertEqual(queries.map(\.after), [1, 201])
        XCTAssertEqual(queries.map(\.tail), [false, false])
    }

    func testClearCreatesRealNewContextWithModelAndNeverSendsSlashAsMessage() async throws {
        let service = FakeTerminalService()
        let terminal = CoveTerminalViewModel()
        let running = try await start(terminal, service: service)
        defer { running.cancel() }
        terminal.apply(FakeTerminalService.makeSnapshot(model: "chosen-model", effort: "high"))
        terminal.draft = "/clear"
        service.failNextContext = true
        await terminal.submit()
        XCTAssertEqual(terminal.conversationID, "current")
        XCTAssertEqual(terminal.events.map(\.id), [1])
        XCTAssertEqual(terminal.draft, "/clear")
        XCTAssertNotNil(terminal.error)
        await terminal.submit()
        XCTAssertEqual(terminal.conversationID, "new-context")
        XCTAssertEqual(service.contextModels, ["chosen-model", "chosen-model"])
        XCTAssertEqual(service.contextEfforts, ["high", "high"])
        XCTAssertEqual(service.inputIDs.count, 0)
        XCTAssertEqual(terminal.draft, "")
    }

    func testEscapeMapsToStopAndHelpPreservesUnsentDraft() async throws {
        let service = FakeTerminalService()
        let terminal = CoveTerminalViewModel()
        let running = try await start(terminal, service: service)
        defer { running.cancel() }
        terminal.draft = "尚未发送的指令"
        service.failNextInput = true
        await terminal.stopCurrentReply()
        await terminal.stopCurrentReply()
        XCTAssertEqual(service.inputIDs[0], service.inputIDs[1])
        await terminal.showHelp()
        XCTAssertEqual(service.inputTexts, ["/stop", "/stop", "/help"])
        XCTAssertEqual(service.inputConversations, ["current", "current", "current"])
        XCTAssertEqual(terminal.draft, "尚未发送的指令")
        XCTAssertFalse(service.inputTexts.contains("Escape"))
    }

    func testStopRemainsAvailableWhileOrdinarySubmitIsStalled() async throws {
        let service = FakeTerminalService()
        service.stallOrdinaryInput = true
        let terminal = CoveTerminalViewModel()
        let running = try await start(terminal, service: service)
        defer { running.cancel() }
        terminal.draft = "slow request"

        let submit = Task { await terminal.submit() }
        for _ in 0..<20 where !service.inputTexts.contains("slow request") { await Task.yield() }
        XCTAssertTrue(service.inputTexts.contains("slow request"))
        await terminal.stopCurrentReply()

        XCTAssertTrue(service.inputTexts.contains("/stop"))
        XCTAssertEqual(terminal.notice, "已提交停止当前回复的请求。")
        service.releaseOrdinaryInput()
        await submit.value
    }

    private func start(_ terminal: CoveTerminalViewModel, service: FakeTerminalService, expectedCursor: Int = 1) async throws -> Task<Void, Never> {
        let loaded = expectation(description: "Initial snapshot requested")
        service.onSnapshot = { loaded.fulfill() }
        let running = Task { await terminal.run(service: service, conversationID: "current", preview: false) }
        await fulfillment(of: [loaded], timeout: 3)
        await Task.yield()
        XCTAssertEqual(terminal.cursor, expectedCursor)
        return running
    }
}

@MainActor
private final class FakeTerminalService: CoveTerminalService {
    var snapshotRequests = 0
    var modelRequests = 0
    var approvalRequests = 0
    var inputIDs: [String] = []
    var inputConversations: [String] = []
    var inputTexts: [String] = []
    var snapshotQueries: [(after: Int, tail: Bool)] = []
    var snapshots: [CoveTerminalSnapshot] = []
    var contextModels: [String?] = []
    var contextEfforts: [String?] = []
    var lastCursor = 1
    var failNextContext = false
    var failNextInput = false
    var stallOrdinaryInput = false
    private var ordinaryContinuation: CheckedContinuation<Void, Never>?
    var onSnapshot: (() -> Void)?
    func snapshot(conversationID: String, after: Int, tail: Bool) async throws -> CoveTerminalSnapshot {
        snapshotRequests += 1
        snapshotQueries.append((after, tail))
        onSnapshot?()
        onSnapshot = nil
        if !snapshots.isEmpty {
            let snapshot = snapshots.removeFirst()
            lastCursor = snapshot.cursor
            return snapshot
        }
        return Self.makeSnapshot(conversationID: conversationID, cursor: max(lastCursor, after), events: after == 0 && conversationID == "current" ? [Self.event(1)] : [])
    }
    func models() async throws -> CoveTerminalModelList {
        modelRequests += 1
        return CoveTerminalModelList(models: [], updatedAt: Date())
    }
    func input(id: String, conversationID: String, text: String) async throws -> CoveTerminalActionResult {
        inputIDs.append(id)
        inputConversations.append(conversationID)
        inputTexts.append(text)
        if stallOrdinaryInput && !text.hasPrefix("/") {
            await withCheckedContinuation { ordinaryContinuation = $0 }
        }
        if failNextInput { failNextInput = false; throw URLError(.networkConnectionLost) }
        return CoveTerminalActionResult(ok: true, kind: text == "/stop" ? "stop" : text == "/help" ? "help" : "message", model: nil, effort: nil, text: text == "/help" ? "控制台帮助" : nil)
    }
    func releaseOrdinaryInput() {
        stallOrdinaryInput = false
        ordinaryContinuation?.resume()
        ordinaryContinuation = nil
    }
    func setModel(conversationID: String, model: String, effort: String) async throws -> CoveTerminalActionResult {
        CoveTerminalActionResult(ok: true, kind: "model", model: model, effort: effort, text: nil)
    }
    func approve(conversationID: String, approval: CoveTerminalApproval, decision: String) async throws -> CoveTerminalActionResult {
        approvalRequests += 1
        return CoveTerminalActionResult(ok: true, kind: nil, model: nil, effort: nil, text: nil)
    }
    func newContext(model: String?, effort: String?) async throws -> String {
        contextModels.append(model); contextEfforts.append(effort)
        if failNextContext { failNextContext = false; throw URLError(.networkConnectionLost) }
        lastCursor = 0
        return "new-context"
    }
    static func event(_ id: Int) -> CoveTerminalEvent {
        CoveTerminalEvent(id: id, kind: "output", text: "真实事件的测试替身", createdAt: Date(), threadID: nil, turnID: nil, itemID: nil)
    }
    static func makeSnapshot(conversationID: String = "current", cursor: Int = 1, events: [CoveTerminalEvent]? = nil, approvals: [CoveTerminalApproval] = [], model: String? = nil, effort: String? = nil) -> CoveTerminalSnapshot {
        CoveTerminalSnapshot(conversationID: conversationID, cursor: cursor, events: events ?? [event(1)], busy: false, connected: true, threadID: "thread", turnID: nil, model: model, effort: effort, pendingApprovals: approvals)
    }
}
