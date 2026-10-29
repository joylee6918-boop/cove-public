import XCTest
@testable import Cove

@MainActor
final class CoveDeviceActionTests: XCTestCase {
    final class Backend: CoveDeviceActionBackend {
        var permission = CoveCapabilityStatus.authorized
        var calls = 0
        var requests = 0
        var fail = false
        func status(_ capability: CoveSystemCapability) -> CoveCapabilityStatus { permission }
        func request(_ capability: CoveSystemCapability) async throws { requests += 1 }
        func execute(_ action: CoveDeviceAction) async throws -> CoveDeviceActionResult {
            calls += 1
            if fail { throw CoveDeviceActionError.invalid("模拟不确定写入失败") }
            return .init(actionID: action.id, records: [], message: "mock only")
        }
    }
    private func makeAction(_ operation: CoveDeviceAction.Operation = .createReminder) -> CoveDeviceAction {
        .init(id: UUID(), expiresAt: Date().addingTimeInterval(120), operation: operation,
              title: "测试提醒", start: Date().addingTimeInterval(3600), end: Date().addingTimeInterval(7200))
    }
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "CoveDeviceActionTests.\(UUID())")! }

    func testUnknownOperationCannotDecode() async {
        let data = Data("{\"id\":\"\(UUID())\",\"operation\":\"executeShell\",\"expiresAt\":0}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(CoveDeviceAction.self, from: data))
    }
    func testValidationRejectsExpiredAndExcessiveLifetime() async {
        for offset in [-1.0, 600] {
            let action = CoveDeviceAction(id: UUID(), expiresAt: Date().addingTimeInterval(offset), operation: .listAlarms)
            XCTAssertThrowsError(try action.validate())
        }
    }
    func testValidationRejectsBadTitleRangeAlarmAndID() async {
        var blank = makeAction(); blank.title = "  "
        XCTAssertThrowsError(try blank.validate())
        var range = makeAction(.listEvents); range.end = range.start!.addingTimeInterval(32 * 86_400)
        XCTAssertThrowsError(try range.validate())
        var alarm = makeAction(.scheduleAlarm); alarm.start = .distantPast
        XCTAssertThrowsError(try alarm.validate())
        var cancel = makeAction(.cancelAlarm); cancel.targetID = "not-a-uuid"
        XCTAssertThrowsError(try cancel.validate())
    }
    func testMutationNeedsExplicitConfirmation() async {
        let backend = Backend()
        let executor = CoveDeviceActionExecutor(backend: backend, defaults: defaults())
        do { _ = try await executor.execute(makeAction(), userConfirmed: false); XCTFail("must require confirmation") }
        catch { XCTAssertEqual(error.localizedDescription, CoveDeviceActionError.confirmation.localizedDescription) }
        XCTAssertEqual(backend.calls, 0)
        XCTAssertEqual(backend.requests, 0)
    }
    func testPreviewNeverExecutes() async {
        let backend = Backend()
        let executor = CoveDeviceActionExecutor(backend: backend, defaults: defaults())
        do { _ = try await executor.execute(makeAction(), userConfirmed: true, preview: true); XCTFail("must block preview") }
        catch { XCTAssertEqual(error.localizedDescription, CoveDeviceActionError.preview.localizedDescription) }
        XCTAssertEqual(backend.calls, 0)
    }
    func testMissingFullPermissionDoesNotPromptOrExecute() async {
        for permission in [CoveCapabilityStatus.denied, .notDetermined, .writeOnly, .restricted] {
            let backend = Backend(); backend.permission = permission
            let executor = CoveDeviceActionExecutor(backend: backend, defaults: defaults())
            do { _ = try await executor.execute(makeAction(), userConfirmed: true); XCTFail("must require full access") } catch {}
            XCTAssertEqual(backend.requests, 0)
            XCTAssertEqual(backend.calls, 0)
        }
    }
    func testSuccessfulReplayReturnsReceiptWithoutSecondWrite() async throws {
        let backend = Backend()
        let executor = CoveDeviceActionExecutor(backend: backend, defaults: defaults())
        let action = makeAction()
        let result = try await executor.execute(action, userConfirmed: true)
        let replay = try await executor.execute(action, userConfirmed: true)
        XCTAssertEqual(result, replay)
        XCTAssertEqual(backend.calls, 1)
    }
    func testUncertainWriteCannotReplayAfterExecutorRelaunch() async {
        let backend = Backend(); backend.fail = true
        let storage = defaults()
        let action = makeAction()
        let first = CoveDeviceActionExecutor(backend: backend, defaults: storage)
        do { _ = try await first.execute(action, userConfirmed: true); XCTFail("fake failure") } catch {}
        backend.fail = false
        let relaunched = CoveDeviceActionExecutor(backend: backend, defaults: storage)
        do { _ = try await relaunched.execute(action, userConfirmed: true); XCTFail("must not replay uncertain write") }
        catch { XCTAssertEqual(error.localizedDescription, CoveDeviceActionError.duplicate.localizedDescription) }
        XCTAssertEqual(backend.calls, 1)
    }
    func testReusedIDCannotSubstitutePayload() async throws {
        let backend = Backend()
        let executor = CoveDeviceActionExecutor(backend: backend, defaults: defaults())
        let action = makeAction()
        _ = try await executor.execute(action, userConfirmed: true)
        var substituted = action; substituted.title = "不同的操作"
        do { _ = try await executor.execute(substituted, userConfirmed: true); XCTFail("must reject substitution") } catch {}
        XCTAssertEqual(backend.calls, 1)
    }
    func testReadDoesNotRequireMutationConfirmation() async throws {
        let backend = Backend()
        let executor = CoveDeviceActionExecutor(backend: backend, defaults: defaults())
        _ = try await executor.execute(makeAction(.listReminders), userConfirmed: false)
        XCTAssertEqual(backend.calls, 1)
    }
    func testBridgeRequestRejectsOtherConversationDeviceAndReplacedAction() throws {
        let action = makeAction()
        let request = CoveDeviceRequest(id: action.id.uuidString.lowercased(), conversationID: "conversation", deviceID: "phone",
                                        action: action, status: "pending", createdAt: Date())
        XCTAssertNoThrow(try request.validate(conversation: "conversation", device: "phone"))
        XCTAssertThrowsError(try request.validate(conversation: "other", device: "phone"))
        XCTAssertThrowsError(try request.validate(conversation: "conversation", device: "other"))
        let replacement = CoveDeviceRequest(id: UUID().uuidString, conversationID: "conversation", deviceID: "phone",
                                            action: action, status: "pending", createdAt: Date())
        XCTAssertThrowsError(try replacement.validate(conversation: "conversation", device: "phone"))
        let claimed = CoveDeviceRequest(id: action.id.uuidString, conversationID: "conversation", deviceID: "phone",
                                        action: action, status: "claimed", createdAt: Date())
        XCTAssertThrowsError(try claimed.validate(conversation: "conversation", device: "phone"))
    }

    func testReceiptJournalPreservesFractionalDatesAndScopesAcrossRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CoveBridgeTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let action = makeAction()
        let request = CoveDeviceRequest(id: action.id.uuidString, conversationID: "conversation", deviceID: "phone",
                                        action: action, status: "pending", createdAt: Date())
        let result = CoveDeviceActionResult(actionID: action.id, records: [], message: "mock only")
        let receipt = CoveDeviceReceipt(scope: "service", request: request, status: "succeeded", result: result, error: nil)
        try CoveDeviceReceiptJournal(directory: directory).save(receipt)
        let relaunched = CoveDeviceReceiptJournal(directory: directory)
        let loaded = try relaunched.load(scope: "service", conversation: "conversation")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.request, request)
        XCTAssertEqual(loaded.first?.result, result)
        XCTAssertTrue(try relaunched.load(scope: "other", conversation: "conversation").isEmpty)
        XCTAssertTrue(try relaunched.load(scope: "service", conversation: "other").isEmpty)
        try relaunched.remove(receipt)
        XCTAssertTrue(try relaunched.load(scope: "service", conversation: "conversation").isEmpty)
    }

    func testLostACKTerminalReconciliationRequiresSameActionAndOwnership() {
        let action = makeAction()
        let request = CoveDeviceRequest(id: action.id.uuidString, conversationID: "conversation", deviceID: "phone",
                                        action: action, status: "pending", createdAt: Date())
        let result = CoveDeviceActionResult(actionID: action.id, records: [], message: "mock only")
        let receipt = CoveDeviceReceipt(scope: "service", request: request, status: "succeeded", result: result, error: nil)
        let recorded = CoveDeviceRequest(id: request.id, conversationID: request.conversationID, deviceID: request.deviceID,
                                         action: action, status: "succeeded", createdAt: request.createdAt, result: result)
        XCTAssertTrue(receipt.matchesTerminal(recorded))
        XCTAssertFalse(receipt.matchesTerminal(request))
        let missingResult = CoveDeviceRequest(id: request.id, conversationID: request.conversationID, deviceID: request.deviceID,
                                             action: action, status: "succeeded", createdAt: request.createdAt)
        XCTAssertFalse(receipt.matchesTerminal(missingResult))
        let otherPhone = CoveDeviceRequest(id: request.id, conversationID: request.conversationID, deviceID: "other",
                                          action: action, status: "succeeded", createdAt: request.createdAt, result: result)
        XCTAssertFalse(receipt.matchesTerminal(otherPhone))
        var substituted = action; substituted.title = "substitution"
        let otherAction = CoveDeviceRequest(id: request.id, conversationID: request.conversationID, deviceID: request.deviceID,
                                           action: substituted, status: "succeeded", createdAt: request.createdAt, result: result)
        XCTAssertFalse(receipt.matchesTerminal(otherAction))
        let expired = CoveDeviceRequest(id: request.id, conversationID: request.conversationID, deviceID: request.deviceID,
                                        action: action, status: "expired", createdAt: request.createdAt)
        XCTAssertTrue(receipt.matchesTerminal(expired)) // stop ACK retries, not proof of local success
    }

    func testCompletedDeviceCardsRetireForEveryCapabilityWithoutDeletingRequests() {
        for operation in CoveDeviceAction.Operation.allCases {
            let action = makeAction(operation)
            let result = CoveDeviceActionResult(actionID: action.id, records: [], message: "mock only")
            let requests = ["pending", "claimed", "succeeded", "denied", "expired", "failed", "unknown"].map {
                CoveDeviceRequest(id: action.id.uuidString, conversationID: "conversation", deviceID: "phone",
                                  action: action, status: $0, createdAt: Date(), result: $0 == "succeeded" ? result : nil)
            }
            XCTAssertEqual(requests.filter(\.showsInChat).map(\.status), ["pending", "claimed", "failed", "unknown"])
            XCTAssertEqual(requests.count, 7) // Presentation never removes durable history.
        }
    }

    func testSuccessCardRequiresMatchingPhoneReceiptBeforeHiding() {
        let action = makeAction(.scheduleAlarm)
        var request = CoveDeviceRequest(id: action.id.uuidString, conversationID: "conversation", deviceID: "phone",
                                        action: action, status: "succeeded", createdAt: Date())
        XCTAssertTrue(request.showsInChat)
        request.result = .init(actionID: UUID(), records: [], message: "wrong receipt")
        XCTAssertTrue(request.showsInChat)
        request.result = .init(actionID: action.id, records: [], message: "confirmed")
        XCTAssertFalse(request.showsInChat)
    }

}
