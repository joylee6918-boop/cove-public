import XCTest
@testable import Cove

@MainActor
final class CoveShellTests: XCTestCase {
    func testEnterStartsAndLeavingDoesNotKillOrReplay() async {
        let fake = ShellFake(); let controller = CoveShellController(api: fake.api)
        await controller.enterView()
        XCTAssertEqual(controller.state, "running")
        await controller.leaveView()
        XCTAssertTrue(fake.terminations.isEmpty)
        XCTAssertTrue(fake.writes.isEmpty)
        await controller.enterView()
        XCTAssertEqual(controller.sessionID, "session-1")
        XCTAssertEqual(fake.starts, 2) // second start is an owner-scoped attach
        await controller.closeSession()
        XCTAssertEqual(fake.terminations, ["session-1"])
    }

    func testLateStartAfterLeavingDoesNotKillAnAttachedSharedSession() async {
        let fake = ShellFake(); fake.delayStart = true
        let controller = CoveShellController(api: fake.api)
        let starting = Task { await controller.enterView() }
        for _ in 0..<100 where fake.startContinuation == nil { await Task.yield() }
        await controller.leaveView(); fake.finishStart(); await starting.value
        XCTAssertEqual(controller.sessionID, "session-1")
        XCTAssertTrue(fake.terminations.isEmpty)
        XCTAssertEqual(fake.polls, 0)
        await controller.closeSession()
    }

    func testBackgroundKeepsSessionAndForegroundAttachesWithoutReplay() async {
        let fake = ShellFake(); let controller = CoveShellController(api: fake.api)
        await controller.enterView(); await controller.background()
        XCTAssertTrue(fake.terminations.isEmpty)
        await controller.resumeIfNeeded()
        XCTAssertEqual(fake.starts, 2)
        XCTAssertEqual(controller.sessionID, "session-1")
        XCTAssertTrue(fake.writes.isEmpty)
        await controller.closeSession()
    }

    func testLateStartInBackgroundDoesNotStartPolling() async {
        let fake = ShellFake(); fake.delayStart = true
        let controller = CoveShellController(api: fake.api)
        let starting = Task { await controller.enterView() }
        for _ in 0..<100 where fake.startContinuation == nil { await Task.yield() }
        await controller.background(); fake.finishStart(); await starting.value
        XCTAssertEqual(fake.polls, 0)
        XCTAssertTrue(fake.terminations.isEmpty)
        await controller.closeSession()
    }

    func testStalePollCannotLeakOutputIntoReplacementSession() async {
        let fake = ShellFake(); fake.pollSnapshot = ShellFake.snapshot(id: "other", text: "MUST NOT LEAK")
        let controller = CoveShellController(api: fake.api)
        await controller.enterView()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(controller.output.contains("MUST NOT LEAK"))
        await controller.closeSession()
    }

    func testFailedRestartWithOldSessionDoesNotRemainConnecting() async {
        let fake = ShellFake(); let controller = CoveShellController(api: fake.api)
        await controller.enterView(); await controller.terminate()
        fake.failNextStart = true
        await controller.start()
        XCTAssertEqual(controller.state, "failed")
        XCTAssertFalse(controller.isStarting)
    }

    func testDoubleSubmitWhileAwaitingAckDoesNotSendTwice() async {
        let fake = ShellFake(); fake.delayWrite = true
        let controller = CoveShellController(api: fake.api)
        await controller.enterView()
        let first = Task { await controller.sendLine("printf synthetic") }
        for _ in 0..<100 where fake.writeContinuation == nil { await Task.yield() }
        XCTAssertTrue(controller.isWriting)
        let duplicate = await controller.sendLine("printf synthetic")
        XCTAssertFalse(duplicate)
        XCTAssertEqual(fake.writes.count, 1)
        fake.finishWrite()
        let success = await first.value
        XCTAssertTrue(success)
        XCTAssertFalse(controller.isWriting)
        await controller.closeSession()
    }

    func testLateWriteCannotClearDraftAfterExplicitTermination() async {
        let fake = ShellFake(); fake.delayWrite = true
        let controller = CoveShellController(api: fake.api)
        await controller.enterView()
        let first = Task { await controller.sendLine("printf synthetic") }
        for _ in 0..<100 where fake.writeContinuation == nil { await Task.yield() }
        await controller.closeSession()
        fake.finishWrite()
        let success = await first.value
        XCTAssertFalse(success)
        XCTAssertEqual(controller.state, "terminated")
        XCTAssertFalse(controller.isWriting)
    }

    func testUnknownTerminateCannotBeDisplayedAsConfirmedClosed() async {
        let fake = ShellFake(); fake.failTerminate = true
        let controller = CoveShellController(api: fake.api)
        await controller.enterView(); await controller.closeSession()
        XCTAssertEqual(controller.state, "unknown")
        XCTAssertNotNil(controller.sessionID)
        XCTAssertNotNil(controller.errorMessage)
        fake.failTerminate = false
        await controller.enterView()
        XCTAssertEqual(controller.sessionID, "session-1")
        XCTAssertEqual(controller.state, "running")
        await controller.closeSession()
    }

}

@MainActor
private final class ShellFake {
    var starts = 0
    var polls = 0
    var currentSession = 1
    var delayWrite = false
    var failTerminate = false
    var writeContinuation: CheckedContinuation<Void, Never>?
    var terminations: [String] = []
    var writes: [String] = []
    var delayStart = false
    var failNextStart = false
    var startContinuation: CheckedContinuation<CoveShellSnapshot, Never>?
    var pollSnapshot: CoveShellSnapshot?

    lazy var api = CoveShellAPI(
        start: { [weak self] _, _ in
            guard let self else { throw CancellationError() }
            self.starts += 1; let value = Self.snapshot(id: "session-\(self.currentSession)")
            if self.failNextStart { self.failNextStart = false; throw URLError(.cannotConnectToHost) }
            if self.delayStart { return await withCheckedContinuation { self.startContinuation = $0 } }
            return value
        },
        poll: { [weak self] id, after in
            self?.polls += 1
            if let value = self?.pollSnapshot { self?.pollSnapshot = nil; return value }
            return Self.snapshot(id: id, cursor: after)
        },
        write: { [weak self] id, _, _ in
            guard let self else { throw CancellationError() }
            self.writes.append(id)
            if self.delayWrite { await withCheckedContinuation { self.writeContinuation = $0 } }
        },
        resize: { _, _, _ in },
        terminate: { [weak self] id in
            if self?.failTerminate == true { throw URLError(.timedOut) }
            self?.terminations.append(id); self?.currentSession += 1
        }
    )

    func finishWrite() { writeContinuation?.resume(); writeContinuation = nil }

    func finishStart() {
        startContinuation?.resume(returning: Self.snapshot(id: "session-1")); startContinuation = nil
    }

    static func snapshot(id: String, cursor: Int = 0, text: String? = nil) -> CoveShellSnapshot {
        let events = text.map { [CoveShellEvent(id: cursor + 1, stream: "stdout", dataBase64: Data($0.utf8).base64EncodedString(), capReached: false)] } ?? []
        return CoveShellSnapshot(id: id, state: "running", exitCode: nil, events: events,
                                 cursor: events.last?.id ?? cursor, ansi: "basic-uninterpreted")
    }
}
