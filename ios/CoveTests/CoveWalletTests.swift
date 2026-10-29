import XCTest
#if canImport(Cove)
@testable import Cove
#endif

final class CoveWalletTests: XCTestCase {
    private var fixture: [String: Any] {
        ["wallet": "assistant", "currency": "CNY", "virtual": true, "day": "2026-10-22",
         "updatedAt": "2026-10-22T00:00:00Z", "balanceFen": 601, "reservedFen": 100,
         "availableFen": 501, "todayIncomeFen": 601, "todaySpendingFen": 0,
         "dailyAllowanceFen": 500, "allowancePending": false,
         "activity": [["id": "owner:reward", "amountFen": 101, "category": "coding",
                       "reason": "测试数据：已完成代码", "day": "2026-10-22", "createdAt": "2026-10-22T00:00:00Z"]],
         "earnings": [["category": "daily", "amountFen": 500], ["category": "coding", "amountFen": 101]],
         "purchases": [["id": "purchase", "amountFen": 100, "reason": "测试数据：书", "status": "requested",
                        "createdAt": "2026-10-22T00:00:00Z", "updatedAt": "2026-10-22T00:00:00Z"]]]
    }

    private func decode(_ json: [String: Any]) throws -> CoveWalletSnapshot {
        try JSONDecoder().decode(CoveWalletSnapshot.self, from: JSONSerialization.data(withJSONObject: json)).validated()
    }

    func testExactDecimalParsingAndFormatting() {
        for (text, fen) in [("0.01", 1), ("1", 100), ("3.5", 350), ("1.01", 101), ("1000000.00", 100_000_000)] {
            XCTAssertEqual(CoveWalletMoney.parse(text), fen)
        }
        for invalid in ["0", "-1", "1.001", "1e3", "NaN", "1,00", "１", "1000000.01", "99999999999999999999", ".5"] {
            XCTAssertNil(CoveWalletMoney.parse(invalid), invalid)
        }
        XCTAssertEqual(CoveWalletMoney.parse("-0.01", signed: true), -1)
        XCTAssertEqual(CoveWalletMoney.display(101), "¥1.01")
        XCTAssertEqual(CoveWalletMoney.display(-101), "−¥1.01")
        XCTAssertEqual(CoveWalletMoney.display(0), "¥0.00")
    }

    func testSnapshotDecodesIntegerFenAndReservations() throws {
        let snapshot = try decode(fixture)
        XCTAssertEqual(snapshot.balanceFen, 601)
        XCTAssertEqual(snapshot.availableFen, 501)
        XCTAssertEqual(snapshot.purchases[0].statusTitle, "待审核 · 已预留")
        XCTAssertEqual(snapshot.activity[0].amountFen, 101)
        XCTAssertNil(snapshot.activity[0].purchaseID)
    }

    func testWrongWalletAndInconsistentResponseFailClosed() throws {
        for (key, value): (String, Any) in [("wallet", "ian"), ("virtual", false), ("currency", "USD"),
                                           ("availableFen", 601), ("reservedFen", -1), ("dailyAllowanceFen", 501),
                                           ("balanceFen", 1.5), ("balanceFen", true)] {
            var invalid = fixture; invalid[key] = value
            XCTAssertThrowsError(try decode(invalid), key)
        }
        var missing = fixture; missing.removeValue(forKey: "balanceFen")
        XCTAssertThrowsError(try decode(missing))
        var reservations = fixture; reservations["purchases"] = []
        XCTAssertThrowsError(try decode(reservations))
    }

    func testPendingCountIncludesOnlyRequestedPurchases() throws {
        XCTAssertEqual(try decode(fixture).pendingApprovalCount, 1)
        XCTAssertEqual(try decode(fixture).pendingApprovalTitle, "1项待审批")
        var mixed = fixture
        let original = (fixture["purchases"] as! [[String: Any]])[0]
        mixed["purchases"] = [original] + ["approved", "fulfilled", "denied", "cancelled"].map { status in
            var purchase = original; purchase["id"] = status; purchase["status"] = status
            return purchase
        }
        XCTAssertEqual(try decode(mixed).pendingApprovalCount, 1)
        mixed["purchases"] = []; mixed["reservedFen"] = 0; mixed["availableFen"] = 601
        XCTAssertEqual(try decode(mixed).pendingApprovalTitle, "0项待审批")
    }

    func testFrozenIntentRoundTripKeepsIDAndOnlyOwnerPayload() throws {
        let command = CoveWalletCommand(id: "fixed-retry", operation: "credit", amountFen: 101,
                                        category: "coding", reason: "测试：完成工作")
        let restored = try JSONDecoder().decode(CoveWalletCommand.self, from: JSONEncoder().encode(command))
        XCTAssertEqual(restored.id, "fixed-retry")
        XCTAssertEqual(restored.amountFen, 101)
        XCTAssertEqual(Set(restored.body.keys), Set(["id", "amountFen", "category", "reason"]))
        let review = CoveWalletCommand(id: "review", operation: "review", purchaseID: "purchase", decision: "approve")
        XCTAssertEqual(Set(review.body.keys), Set(["id", "purchaseID", "decision"]))
        XCTAssertFalse(CoveWalletCategory.owner.contains("affection"))
        XCTAssertFalse(CoveWalletCategory.owner.contains("sex"))
    }

    func testRealTemporaryServerSnapshotDecodingWhenSupplied() throws {
        guard let path = ProcessInfo.processInfo.environment["COVE_WALLET_TEST_FIXTURE"] else { return }
        let snapshot = try JSONDecoder().decode(CoveWalletSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: path))).validated()
        XCTAssertEqual(snapshot.wallet, "assistant")
        XCTAssertEqual(snapshot.balanceFen, 601)
        XCTAssertEqual(snapshot.reservedFen, 100)
    }
}
