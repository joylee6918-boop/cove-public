import XCTest
@testable import Cove

final class CoveCollarTests: XCTestCase {
    private let scope = CoveCollarScope(conversationID: "current", isConnected: true, previewMode: false)

    func testPermissionsDecodeExplicitFalseWithoutInventingGrants() throws {
        let data = Data("""
        {"conversationID":"current","readSummary":false,"requestMeasurement":false,
         "configured":false,"updatedAt":null,"recentActions":[]}
        """.utf8)
        let value = try CoveJSON.decoder().decode(CoveCollarPermissions.self, from: data)
        XCTAssertFalse(value.readSummary)
        XCTAssertFalse(value.requestMeasurement)
        XCTAssertFalse(value.configured)
        XCTAssertNil(value.updatedAt)
        XCTAssertTrue(value.recentActions.isEmpty)
    }

    func testMissingOrNonBooleanFlagsRejectResponse() throws {
        let valid: [String: Any] = ["conversationID": "current", "readSummary": false,
                                    "requestMeasurement": false, "configured": false, "recentActions": []]
        for field in ["readSummary", "requestMeasurement", "configured"] {
            var missing = valid
            missing.removeValue(forKey: field)
            XCTAssertThrowsError(try CoveJSON.decoder().decode(CoveCollarPermissions.self,
                from: JSONSerialization.data(withJSONObject: missing)), field)
            var invalid = valid
            invalid[field] = "true"
            XCTAssertThrowsError(try CoveJSON.decoder().decode(CoveCollarPermissions.self,
                from: JSONSerialization.data(withJSONObject: invalid)), field)
        }
    }

    func testActionDecodesMetadataAndFractionalDate() throws {
        let data = Data("""
        {"id":"audit-1","action":"read_summary","status":"complete","createdAt":"2026-09-15T12:00:00.123Z"}
        """.utf8)
        let action = try CoveJSON.decoder().decode(CoveCollarAction.self, from: data)
        XCTAssertEqual(action.title, "查看健康摘要")
        XCTAssertEqual(action.statusLabel, "摘要已交付工具")
    }

    func testMeasurementReceiptsNeverClaimMeasurementSuccess() {
        XCTAssertEqual(action("pending").statusLabel, "请求待处理，尚未确认完成")
        XCTAssertEqual(action("seen").statusLabel, "手表已接收，尚未确认完成")
        XCTAssertEqual(action("done").statusLabel, "已收到测量回执")
        XCTAssertEqual(action("expired").statusLabel, "请求已过期")
        XCTAssertEqual(action("unknown").statusLabel, "结果未确认")
        XCTAssertEqual(action("new-server-status").statusLabel, "结果未确认")
        XCTAssertEqual(action("failed").statusLabel, "未成功")
    }

    func testPreviewDisconnectedAndMissingConversationNeverStartNetworkOperations() {
        var state = CoveCollarPanelState()
        for scope in [
            CoveCollarScope(conversationID: "current", isConnected: true, previewMode: true),
            CoveCollarScope(conversationID: "current", isConnected: false, previewMode: false),
            CoveCollarScope(conversationID: "  ", isConnected: true, previewMode: false)
        ] {
            XCTAssertNil(state.begin(.loading, in: scope))
            XCTAssertNil(state.begin(.saving, in: scope))
            XCTAssertNil(state.permissions)
            XCTAssertFalse(state.canChange(.readSummary, in: scope))
        }
    }

    func testSaveDoesNotOptimisticallyGrantAndDisablesChanges() throws {
        var state = try loadedState(value())
        let token = try XCTUnwrap(state.begin(.saving, in: scope))
        XCTAssertEqual(state.permissions?.readSummary, false)
        XCTAssertFalse(state.canChange(.readSummary, in: scope))
        XCTAssertNil(state.begin(.loading, in: scope))
        state.receive(value(read: true), token: token, in: scope)
        XCTAssertEqual(state.permissions?.readSummary, true)
        XCTAssertTrue(state.canChange(.readSummary, in: scope))
    }

    func testFailedSaveIsUncertainUntilExplicitRefresh() throws {
        var state = try loadedState(value(read: true))
        let saveToken = try XCTUnwrap(state.begin(.saving, in: scope))
        state.fail(token: saveToken, in: scope)
        XCTAssertNil(state.permissions)
        XCTAssertTrue(state.error?.contains("服务器上的权限可能已经改变") == true)
        XCTAssertTrue(state.error?.contains("不会自动重发") == true)
        XCTAssertNil(state.begin(.saving, in: scope))
        XCTAssertFalse(state.canChange(.readSummary, in: scope))
        let refreshToken = try XCTUnwrap(state.begin(.loading, in: scope))
        state.receive(value(read: false), token: refreshToken, in: scope)
        XCTAssertEqual(state.permissions?.readSummary, false)
        XCTAssertNil(state.error)
    }

    func testLoadFailureDoesNotClaimRemoteRevocation() throws {
        var state = try loadedState(value(read: true))
        let token = try XCTUnwrap(state.begin(.loading, in: scope))
        XCTAssertNil(state.permissions)
        state.fail(token: token, in: scope)
        XCTAssertNil(state.permissions)
        XCTAssertTrue(state.error?.contains("不代表服务器权限已关闭") == true)
    }

    func testNewConversationRejectsOldLoadAndSaveCompletions() throws {
        for operation in [CoveCollarPanelState.Operation.loading, .saving] {
            var state = try loadedState(value())
            let oldToken = try XCTUnwrap(state.begin(operation, in: scope))
            let next = CoveCollarScope(conversationID: "next", isConnected: true, previewMode: false)
            state.reset(to: next)
            state.receive(value(read: true), token: oldToken, in: scope)
            state.fail(token: oldToken, in: scope)
            XCTAssertNil(state.permissions)
            XCTAssertNil(state.error)
            XCTAssertEqual(state.scope, next)
        }
    }

    func testDisconnectAndReconnectRejectsEarlierSameConversationResponse() throws {
        var state = CoveCollarPanelState()
        let oldToken = try XCTUnwrap(state.begin(.loading, in: scope))
        state.reset(to: CoveCollarScope(conversationID: "current", isConnected: false, previewMode: false))
        let newToken = try XCTUnwrap(state.begin(.loading, in: scope))
        state.receive(value(read: true), token: oldToken, in: scope)
        XCTAssertNil(state.permissions)
        state.receive(value(), token: newToken, in: scope)
        XCTAssertEqual(state.permissions?.readSummary, false)
    }

    func testWrongConversationResponseFailsClosed() throws {
        var state = CoveCollarPanelState()
        let token = try XCTUnwrap(state.begin(.loading, in: scope))
        let wrong = CoveCollarPermissions(conversationID: "other", readSummary: true,
            requestMeasurement: true, updatedAt: nil, configured: true, recentActions: [])
        state.receive(wrong, token: token, in: scope)
        XCTAssertNil(state.permissions)
        XCTAssertNotNil(state.error)
    }

    func testUnconfiguredServiceStillAllowsRevokingEachExistingGrant() throws {
        let readState = try loadedState(value(read: true, configured: false))
        XCTAssertTrue(readState.canChange(.readSummary, in: scope))
        XCTAssertFalse(readState.canChange(.requestMeasurement, in: scope))
        let measureState = try loadedState(value(measure: true, configured: false))
        XCTAssertFalse(measureState.canChange(.readSummary, in: scope))
        XCTAssertTrue(measureState.canChange(.requestMeasurement, in: scope))
    }

    private func loadedState(_ value: CoveCollarPermissions) throws -> CoveCollarPanelState {
        var state = CoveCollarPanelState()
        let token = try XCTUnwrap(state.begin(.loading, in: scope))
        state.receive(value, token: token, in: scope)
        return state
    }

    private func value(read: Bool = false, measure: Bool = false, configured: Bool = true) -> CoveCollarPermissions {
        CoveCollarPermissions(conversationID: "current", readSummary: read,
            requestMeasurement: measure, updatedAt: nil, configured: configured, recentActions: [])
    }

    private func action(_ status: String) -> CoveCollarAction {
        CoveCollarAction(id: "audit", action: "request_measurement", status: status,
            createdAt: Date(timeIntervalSince1970: 1))
    }
}
