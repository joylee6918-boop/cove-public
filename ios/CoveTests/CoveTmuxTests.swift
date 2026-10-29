import XCTest
import SwiftUI
import UIKit
@testable import Cove

@MainActor
final class CoveTmuxTests: XCTestCase {
    private func snapshot(_ conversation: String = "c1", _ session: String = "s1", _ state: String = "running", _ revision: Int = 1) -> CoveTmuxSnapshot {
        CoveTmuxSnapshot(sessionID: session, conversationID: conversation, threadID: "t1", state: state,
                         output: "real capture", revision: revision, inputAvailable: true,
                         allowedKeys: ["Enter", "C-c", "Escape", "BS", "Tab", "Up", "Down", "Left", "Right"])
    }

    func testSyntheticTerminalRendersLightAndDarkAtPhoneSize() async {
        let output = "MOCK TERMINAL — SYNTHETIC ONLY\n\n› codex\n• 示例任务正在处理\n  已检查 3 个合成文件\n\n$ " +
                     String(repeating: "long-column-", count: 12)
        await attachSyntheticRender(name: "合成终端-浅色-输入禁用", output: output,
                                    inputAvailable: false, style: .light)
        await attachSyntheticRender(name: "合成终端-深色-输入禁用", output: output,
                                    inputAvailable: false, style: .dark)
        await attachSyntheticRender(name: "合成终端-浅色-输入可用", output: output,
                                    inputAvailable: true, style: .light)
    }

    func testSyntheticColdTerminatedSessionRendersExplicitRecovery() async {
        await attachSyntheticRender(
            name: "合成终端-冷启动已终止-显式恢复",
            output: "MOCK TERMINAL — SYNTHETIC ONLY\n旧会话已终止，原线程可继续。",
            inputAvailable: false, style: .light, state: "terminated", recoverEnabled: true
        )
    }

    private func attachSyntheticRender(name: String, output: String, inputAvailable: Bool,
                                       style: UIUserInterfaceStyle,
                                       state: String = "running", recoverEnabled: Bool = false) async {
        let value = CoveTmuxSnapshot(
            sessionID: "synthetic-session", conversationID: "synthetic-conversation",
            threadID: "synthetic-thread", state: state, output: output, revision: 1,
            inputAvailable: inputAvailable,
            allowedKeys: inputAvailable
                ? ["Enter", "C-c", "Escape", "BS", "Tab", "Up", "Down", "Left", "Right"]
                : ["C-c"]
        )
        let api = CoveTmuxAPI(
            attach: { value }, capture: { _ in value },
            input: { _, _, _ in }, key: { _, _, _ in }, terminate: { _, _ in },
            recover: recoverEnabled ? { _, _ in value } : nil
        )
        let model = CoveTmuxModel(api: api, conversationID: value.conversationID)
        await model.enter()
        XCTAssertEqual(model.snapshot, value)
        if recoverEnabled { XCTAssertTrue(model.canRecover) }
        let host = UIHostingController(
            rootView: CoveTmuxView(model: model)
                .environment(\.scenePhase, .active)
        )
        let frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let foregroundScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let window = foregroundScene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        window.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        // The model is already attached; wait only for SwiftUI's initial layout.
        try? await Task.sleep(for: .milliseconds(100))
        host.view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(size: window.bounds.size)
        var didDraw = false
        let image = renderer.image { context in
            didDraw = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(didDraw)
        XCTAssertEqual(model.snapshot, value)
        XCTAssertEqual(host.view.bounds.size, CGSize(width: 393, height: 852))
        XCTAssertTrue(window.rootViewController === host)
        XCTAssertNotNil(image.cgImage)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        window.isHidden = true
    }

    func testCapturedLineCountUsesActualPlainTextAndIgnoresFinalNewline() async {
        let value = CoveTmuxSnapshot(sessionID: "s1", conversationID: "c1", threadID: "t1",
                                     state: "running", output: "first\n\nthird\n", revision: 1,
                                     inputAvailable: false, allowedKeys: ["C-c"])
        let api = CoveTmuxAPI(
            attach: { value }, capture: { _ in value },
            input: { _, _, _ in }, key: { _, _, _ in }, terminate: { _, _ in }
        )
        let model = CoveTmuxModel(api: api, conversationID: "c1")
        XCTAssertEqual(model.capturedLineCount, 0)
        await model.enter()
        XCTAssertEqual(model.capturedLineCount, 3)
        model.detach()
    }

    func testExplicitRecoveryKeepsConversationAndThreadButMayChangeSession() async {
        let calls = RecoveryLog()
        let old = snapshot("c1", "old", "running")
        let renewed = CoveTmuxSnapshot(sessionID: "new", conversationID: "c1", threadID: "t1",
                                       state: "running", output: "resumed native thread", revision: 0,
                                       inputAvailable: false, allowedKeys: ["C-c"])
        let api = CoveTmuxAPI(
            attach: { old }, capture: { _ in renewed },
            input: { _, _, _ in }, key: { _, _, _ in }, terminate: { _, _ in },
            recover: { session, requestID in
                await calls.record(session: session, requestID: requestID)
                return renewed
            }
        )
        let model = CoveTmuxModel(api: api, conversationID: "c1")
        await model.enter()
        XCTAssertFalse(model.canRecover)
        await model.forceTerminate(expectedSessionID: "old")
        XCTAssertEqual(model.snapshot?.state, "terminated")
        XCTAssertTrue(model.canRecover)
        let before = await calls.count()
        XCTAssertEqual(before, 0)
        await model.recover(expectedSessionID: "old", expectedThreadID: "t1")
        let count = await calls.count()
        let session = await calls.session()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(session, "old")
        XCTAssertEqual(model.snapshot, renewed)
        XCTAssertTrue(model.isWatching)
        model.detach()
    }

    func testRecoveryRefusesChangedConfirmationOrWrongThreadResponse() async {
        let calls = RecoveryLog()
        let old = snapshot("c1", "old", "terminated")
        let wrong = CoveTmuxSnapshot(sessionID: "new", conversationID: "c1", threadID: "other",
                                     state: "running", output: "not ours", revision: 0)
        let api = CoveTmuxAPI(
            attach: { old }, capture: { _ in old },
            input: { _, _, _ in }, key: { _, _, _ in }, terminate: { _, _ in },
            recover: { session, requestID in
                await calls.record(session: session, requestID: requestID)
                return wrong
            }
        )
        let model = CoveTmuxModel(api: api, conversationID: "c1")
        await model.enter()
        await model.recover(expectedSessionID: "other", expectedThreadID: "t1")
        let before = await calls.count()
        XCTAssertEqual(before, 0)
        await model.recover(expectedSessionID: "old", expectedThreadID: "t1")
        let count = await calls.count()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(model.snapshot, old)
        XCTAssertNotNil(model.uncertainWriteMessage)
        model.detach()
    }

    func testUnknownRecoveryDoesNotRetryAndLateResultCannotAdoptAfterDetach() async {
        let calls = RecoveryLog()
        let gate = AttachGate()
        let old = snapshot("c1", "old", "terminated")
        let renewed = CoveTmuxSnapshot(sessionID: "new", conversationID: "c1", threadID: "t1",
                                       state: "running", output: "renewed", revision: 0)
        let api = CoveTmuxAPI(
            attach: { old }, capture: { _ in old },
            input: { _, _, _ in }, key: { _, _, _ in }, terminate: { _, _ in },
            recover: { session, requestID in
                await calls.record(session: session, requestID: requestID)
                return await gate.wait()
            }
        )
        let model = CoveTmuxModel(api: api, conversationID: "c1")
        await model.enter()
        let pending = Task { await model.recover(expectedSessionID: "old", expectedThreadID: "t1") }
        while !model.isWriting { await Task.yield() }
        model.detach()
        await gate.release(renewed)
        await pending.value
        let count = await calls.count()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(model.snapshot, old)
        XCTAssertFalse(model.isWriting)
        // A later explicit reattach is how an uncertain result is discovered.
        await model.enter()
        XCTAssertEqual(model.snapshot, old)
        let after = await calls.count()
        XCTAssertEqual(after, 1)
        model.detach()
    }

    func testRecoveryErrorNeedsExplicitReattachBeforeAnotherAttempt() async {
        let calls = RecoveryLog()
        let old = snapshot("c1", "old", "terminated")
        let api = CoveTmuxAPI(
            attach: { old }, capture: { _ in old },
            input: { _, _, _ in }, key: { _, _, _ in }, terminate: { _, _ in },
            recover: { session, requestID in
                await calls.record(session: session, requestID: requestID)
                throw TestError.failed
            }
        )
        let model = CoveTmuxModel(api: api, conversationID: "c1")
        await model.enter()
        await model.recover(expectedSessionID: "old", expectedThreadID: "t1")
        XCTAssertNotNil(model.uncertainWriteMessage)
        XCTAssertFalse(model.canRecover)
        await model.recover(expectedSessionID: "old", expectedThreadID: "t1")
        let count = await calls.count()
        XCTAssertEqual(count, 1)
        model.detach()
        await model.enter() // Explicitly query the authoritative current binding.
        XCTAssertTrue(model.canRecover)
        XCTAssertNil(model.uncertainWriteMessage)
        model.detach()
    }

    func testLateAttachAfterDetachCannotAdoptOrTerminate() async {
        let gate = AttachGate()
        let value = snapshot()
        let calls = CallLog()
        let api = CoveTmuxAPI(
            attach: { await gate.wait() },
            capture: { _ in value },
            input: { _, _, _ in }, key: { _, _, _ in },
            terminate: { _, _ in await calls.recordTerminate() }
        )
        let model = CoveTmuxModel(api: api, conversationID: "c1")
        let entering = Task { await model.enter() }
        while !model.isAttaching { await Task.yield() }
        model.detach()
        await gate.release(snapshot())
        await entering.value
        XCTAssertNil(model.snapshot)
        let actual_terminates = await calls.terminates()
        XCTAssertEqual(actual_terminates, 0)
    }

    func testDetachAndBackgroundNeverKillAndReenterAttachesAgain() async {
        let calls = CallLog()
        let value = snapshot()
        let api = CoveTmuxAPI(
            attach: { await calls.recordAttach(); return value },
            capture: { _ in value },
            input: { _, _, _ in }, key: { _, _, _ in },
            terminate: { _, _ in await calls.recordTerminate() }
        )
        let model = CoveTmuxModel(api: api, conversationID: "c1")
        await model.enter()
        model.detach() // same method used on view disappearance and scene background
        await model.enter()
        let actual_attaches = await calls.attaches()
        XCTAssertEqual(actual_attaches, 2)
        let actual_terminates = await calls.terminates()
        XCTAssertEqual(actual_terminates, 0)
        model.detach()
    }

    func testTerminateIsOnlyExplicitAndUsesOneRequest() async {
        let calls = CallLog()
        let value = snapshot()
        let api = CoveTmuxAPI(
            attach: { value }, capture: { _ in value },
            input: { _, _, _ in }, key: { _, _, _ in },
            terminate: { id, requestID in await calls.recordTerminate(id, requestID) }
        )
        let model = CoveTmuxModel(api: api, conversationID: "c1")
        await model.enter()
        let actual_terminates = await calls.terminates()
        XCTAssertEqual(actual_terminates, 0)
        await model.forceTerminate()
        let final_terminates = await calls.terminates()
        XCTAssertEqual(final_terminates, 1)
        let actual_lastTerminatedSession = await calls.lastTerminatedSession()
        XCTAssertEqual(actual_lastTerminatedSession, "s1")
        model.detach()
    }

    func testCrossConversationAttachRejectedBeforeDisplayingOrWriting() async {
        let calls = CallLog()
        let other = snapshot("other")
        let api = CoveTmuxAPI(
            attach: { other }, capture: { _ in other },
            input: { _, _, _ in await calls.recordInput() },
            key: { _, _, _ in }, terminate: { _, _ in await calls.recordTerminate() }
        )
        let model = CoveTmuxModel(api: api, conversationID: "c1")
        await model.enter()
        XCTAssertNil(model.snapshot)
        await model.sendText("hi")
        let actual_inputs = await calls.inputs()
        XCTAssertEqual(actual_inputs, 0)
        let actual_terminates = await calls.terminates()
        XCTAssertEqual(actual_terminates, 0)
        model.detach()
    }

    func testPollFailureNeverReplaysUncertainInput() async {
        let calls = CallLog()
        let value = snapshot()
        let api = CoveTmuxAPI(
            attach: { value },
            capture: { _ in throw TestError.failed },
            input: { _, _, _ in await calls.recordInput(); throw TestError.failed },
            key: { _, _, _ in }, terminate: { _, _ in }
        )
        let model = CoveTmuxModel(api: api, conversationID: "c1")
        await model.enter()
        await model.sendText("literal text")
        await model.captureNow()
        let actual_inputs = await calls.inputs()
        XCTAssertEqual(actual_inputs, 1)
        XCTAssertNotNil(model.uncertainWriteMessage)
        model.detach()
    }

    func testOnlyWhitelistedKeyAndNoImplicitEnter() async {
        let calls = CallLog()
        let value = snapshot()
        let api = CoveTmuxAPI(
            attach: { value }, capture: { _ in value },
            input: { _, text, _ in await calls.recordText(text) },
            key: { _, key, _ in await calls.recordKey(key) }, terminate: { _, _ in }
        )
        let model = CoveTmuxModel(api: api, conversationID: "c1")
        await model.enter()
        await model.sendText("abc")
        await model.sendKey("not-a-key")
        let actual_texts = await calls.texts()
        XCTAssertEqual(actual_texts, ["abc"])
        let actual_keys = await calls.keys()
        XCTAssertEqual(actual_keys, [])
        await model.sendKey("Enter")
        let final_keys = await calls.keys()
        XCTAssertEqual(final_keys, ["Enter"])
        model.detach()
    }

    func testUnavailableCanCaptureAndForceTerminateButNotInput() async {
        let calls = CallLog()
        let unavailable = snapshot("c1", "s1", "unavailable")
        let api = CoveTmuxAPI(
            attach: { unavailable },
            capture: { _ in await calls.recordCapture(); return unavailable },
            input: { _, _, _ in await calls.recordInput() },
            key: { _, _, _ in },
            terminate: { id, requestID in await calls.recordTerminate(id, requestID) }
        )
        let model = CoveTmuxModel(api: api, conversationID: "c1")
        await model.enter()
        await model.captureNow()
        await model.sendText("no")
        await model.forceTerminate()
        let captures = await calls.captures()
        let inputs = await calls.inputs()
        let terminations = await calls.terminates()
        XCTAssertGreaterThanOrEqual(captures, 1)
        XCTAssertEqual(inputs, 0)
        XCTAssertEqual(terminations, 1)
        model.detach()
    }

    func testDetachedInflightWriteReleasesGateWithoutChangingNewSession() async {
        let gate = WriteGate()
        let calls = CallLog()
        let first = snapshot("c1", "old")
        let second = CoveTmuxSnapshot(sessionID: "new", conversationID: "c1", threadID: "t2", state: "running", output: "new capture", revision: 1)
        let api = CoveTmuxAPI(
            attach: { await calls.recordAttach(); return await calls.attaches() == 1 ? first : second },
            capture: { id in id == "old" ? first : second },
            input: { _, _, _ in await gate.wait() },
            key: { _, _, _ in }, terminate: { _, _ in }
        )
        let model = CoveTmuxModel(api: api, conversationID: "c1")
        await model.enter()
        let pending = Task { await model.sendText("one") }
        while !model.isWriting { await Task.yield() }
        model.detach()
        await model.enter()
        XCTAssertEqual(model.snapshot?.sessionID, "new")
        await model.sendKey("Enter") // blocked while old write is unresolved
        XCTAssertTrue(model.isWriting)
        await gate.release()
        await pending.value
        XCTAssertFalse(model.isWriting)
        XCTAssertEqual(model.snapshot?.sessionID, "new")
        XCTAssertNil(model.uncertainWriteMessage)
        model.detach()
    }

    func testAttachFailureCanRetry() async {
        let calls = CallLog()
        let value = snapshot()
        let api = CoveTmuxAPI(
            attach: {
                await calls.recordAttach()
                if await calls.attaches() == 1 { throw TestError.failed }
                return value
            },
            capture: { _ in value },
            input: { _, _, _ in }, key: { _, _, _ in }, terminate: { _, _ in }
        )
        let model = CoveTmuxModel(api: api, conversationID: "c1")
        await model.enter()
        XCTAssertNotNil(model.errorMessage)
        await model.enter()
        XCTAssertEqual(model.snapshot?.sessionID, "s1")
        let attaches = await calls.attaches()
        XCTAssertEqual(attaches, 2)
        model.detach()
    }

    func testLiteralInputRejectsControlCharacters() async {
        let calls = CallLog()
        let value = snapshot()
        let api = CoveTmuxAPI(
            attach: { value }, capture: { _ in value },
            input: { _, _, _ in await calls.recordInput() },
            key: { _, _, _ in }, terminate: { _, _ in }
        )
        let model = CoveTmuxModel(api: api, conversationID: "c1")
        await model.enter()
        await model.sendText("line\nnext")
        await model.sendText("tab\tname")
        await model.sendText("\u{001B}")
        let inputs = await calls.inputs()
        XCTAssertEqual(inputs, 0)
        model.detach()
    }

    func testTerminateAcknowledgementStopsPollingDespiteCaptureFailure() async {
        let calls = CallLog()
        let value = snapshot()
        let api = CoveTmuxAPI(
            attach: { value },
            capture: { _ in await calls.recordCapture(); throw TestError.failed },
            input: { _, _, _ in }, key: { _, _, _ in },
            terminate: { id, requestID in await calls.recordTerminate(id, requestID) }
        )
        let model = CoveTmuxModel(api: api, conversationID: "c1")
        await model.enter()
        await model.forceTerminate()
        XCTAssertEqual(model.snapshot?.state, "terminated")
        XCTAssertFalse(model.isWatching)
        let captures = await calls.captures()
        XCTAssertEqual(captures, 0) // no post-ACK capture can undo acknowledged termination
        let terminations = await calls.terminates()
        XCTAssertEqual(terminations, 1)
        model.detach()
    }

    func testConfirmationSessionChangeRefusesTermination() async {
        let calls = CallLog()
        let first = snapshot("c1", "old")
        let second = CoveTmuxSnapshot(sessionID: "new", conversationID: "c1", threadID: "t2", state: "running", output: "new", revision: 1)
        let api = CoveTmuxAPI(
            attach: { await calls.recordAttach(); return await calls.attaches() == 1 ? first : second },
            capture: { _ in second },
            input: { _, _, _ in }, key: { _, _, _ in },
            terminate: { id, requestID in await calls.recordTerminate(id, requestID) }
        )
        let model = CoveTmuxModel(api: api, conversationID: "c1")
        await model.enter()
        let confirmedID = model.snapshot!.sessionID
        model.detach()
        await model.enter()
        await model.forceTerminate(expectedSessionID: confirmedID)
        let terminations = await calls.terminates()
        XCTAssertEqual(terminations, 0)
        XCTAssertEqual(model.snapshot?.sessionID, "new")
        XCTAssertNotNil(model.errorMessage)
        model.detach()
    }

    func testLateCaptureCannotReviveAcknowledgedTermination() async {
        let gate = AttachGate()
        let value = snapshot()
        let api = CoveTmuxAPI(
            attach: { value }, capture: { _ in await gate.wait() },
            input: { _, _, _ in }, key: { _, _, _ in }, terminate: { _, _ in }
        )
        let model = CoveTmuxModel(api: api, conversationID: "c1")
        await model.enter()
        let capture = Task { await model.captureNow() }
        while !(await gate.hasWaiter()) { await Task.yield() }
        await model.forceTerminate()
        await gate.release(snapshot("c1", "s1", "running", 2))
        await capture.value
        XCTAssertEqual(model.snapshot?.state, "terminated")
        model.detach()
    }

    func testUnavailableInputCapabilityBlocksTextAndEnterButAllowsInterruptAndTerminate() async {
        let calls = CallLog()
        let limited = CoveTmuxSnapshot(sessionID: "s1", conversationID: "c1", threadID: "t1",
                                       state: "running", output: "capture", revision: 1,
                                       inputAvailable: false, allowedKeys: ["C-c"])
        let api = CoveTmuxAPI(
            attach: { limited }, capture: { _ in limited },
            input: { _, _, _ in await calls.recordInput() },
            key: { _, key, _ in await calls.recordKey(key) },
            terminate: { id, requestID in await calls.recordTerminate(id, requestID) }
        )
        let model = CoveTmuxModel(api: api, conversationID: "c1")
        await model.enter()
        XCTAssertFalse(model.canSendText)
        XCTAssertFalse(model.canSendKey("Enter"))
        XCTAssertTrue(model.canSendKey("C-c"))
        await model.sendText("unsafe new turn")
        await model.sendKey("Enter")
        await model.sendKey("Tab")
        await model.sendKey("C-c")
        let inputs = await calls.inputs()
        let keys = await calls.keys()
        XCTAssertEqual(inputs, 0)
        XCTAssertEqual(keys, ["C-c"])
        await model.forceTerminate()
        let terminations = await calls.terminates()
        XCTAssertEqual(terminations, 1)
        model.detach()
    }

    func testMissingInputCapabilityFailsClosed() async {
        let calls = CallLog()
        let legacy = CoveTmuxSnapshot(sessionID: "s1", conversationID: "c1", threadID: "t1",
                                      state: "running", output: "capture", revision: 1)
        let api = CoveTmuxAPI(
            attach: { legacy }, capture: { _ in legacy },
            input: { _, _, _ in await calls.recordInput() },
            key: { _, key, _ in await calls.recordKey(key) }, terminate: { _, _ in }
        )
        let model = CoveTmuxModel(api: api, conversationID: "c1")
        await model.enter()
        await model.sendText("no")
        await model.sendKey("Enter")
        await model.sendKey("C-c")
        let inputs = await calls.inputs()
        let keys = await calls.keys()
        XCTAssertEqual(inputs, 0)
        XCTAssertTrue(keys.isEmpty)
        model.detach()
    }
}

private enum TestError: Error { case failed }

private actor RecoveryLog {
    private var callCount = 0
    private var lastSession: String?
    private var requestIDs: [UUID] = []
    func record(session: String, requestID: UUID) {
        callCount += 1
        lastSession = session
        requestIDs.append(requestID)
    }
    func count() -> Int { callCount }
    func session() -> String? { lastSession }
}

private actor AttachGate {
    private var continuation: CheckedContinuation<CoveTmuxSnapshot, Never>?
    private var ready: CoveTmuxSnapshot?
    func wait() async -> CoveTmuxSnapshot {
        if let ready { return ready }
        return await withCheckedContinuation { continuation = $0 }
    }
    func release(_ value: CoveTmuxSnapshot) {
        if let continuation { continuation.resume(returning: value); self.continuation = nil }
        else { ready = value }
    }
    func hasWaiter() -> Bool { continuation != nil }
}

private actor CallLog {
    private var attachCount = 0
    private var inputCount = 0
    private var terminateCount = 0
    private var captureCount = 0
    private var terminatedSession: String?
    private var sentTexts: [String] = []
    private var sentKeys: [String] = []
    func recordAttach() { attachCount += 1 }
    func recordCapture() { captureCount += 1 }
    func recordInput() { inputCount += 1 }
    func recordText(_ text: String) { inputCount += 1; sentTexts.append(text) }
    func recordKey(_ key: String) { sentKeys.append(key) }
    func recordTerminate(_ session: String = "s1", _ requestID: UUID = UUID()) {
        terminateCount += 1; terminatedSession = session
    }
    func attaches() -> Int { attachCount }
    func inputs() -> Int { inputCount }
    func terminates() -> Int { terminateCount }
    func captures() -> Int { captureCount }
    func lastTerminatedSession() -> String? { terminatedSession }
    func texts() -> [String] { sentTexts }
    func keys() -> [String] { sentKeys }
}

private actor WriteGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
