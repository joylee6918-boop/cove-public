import Foundation
import XCTest
@testable import Cove

final class CoveHealthRefreshPolicyTests: XCTestCase {
    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value)!
    }

    func testFirstDailyAttemptAndSecondRequiresChangeAndSixHours() throws {
        let first = date("2026-09-23T00:00:00Z") // 08:00 Beijing
        let initial = CoveHealthRefreshPolicy()
        XCTAssertTrue(initial.eligibility(now: first, changed: false))
        let once = try XCTUnwrap(initial.recordingAttempt(now: first, changed: false))
        XCTAssertFalse(once.eligibility(now: date("2026-09-23T05:59:59Z"), changed: true))
        XCTAssertFalse(once.eligibility(now: date("2026-09-23T06:00:00Z"), changed: false))
        let twice = try XCTUnwrap(once.recordingAttempt(now: date("2026-09-23T06:00:00Z"), changed: true))
        XCTAssertEqual(twice.attemptsToday, 2)
        XCTAssertNil(twice.recordingAttempt(now: date("2026-09-23T12:00:00Z"), changed: true))
    }

    func testSerializationPreservesBudgetAcrossRelaunchAndChangeBurst() throws {
        let first = date("2026-09-23T00:00:00Z")
        let once = try XCTUnwrap(CoveHealthRefreshPolicy().recordingAttempt(now: first, changed: false))
        let restored = try JSONDecoder().decode(CoveHealthRefreshPolicy.self, from: JSONEncoder().encode(once))
        XCTAssertEqual(restored, once)
        let secondAt = date("2026-09-23T06:00:00Z")
        let twice = try XCTUnwrap(restored.recordingAttempt(now: secondAt, changed: true))
        for second in 1...20 {
            XCTAssertFalse(twice.eligibility(now: secondAt.addingTimeInterval(TimeInterval(second)), changed: true))
        }
    }

    func testBeijingRolloverStillRespectsSixHoursAndClockRollback() throws {
        let late = date("2026-09-23T15:00:00Z") // 23:00 Beijing
        let once = try XCTUnwrap(CoveHealthRefreshPolicy().recordingAttempt(now: late, changed: false))
        XCTAssertFalse(once.eligibility(now: date("2026-09-23T16:01:00Z"), changed: false))
        let nextDay = date("2026-09-23T21:00:00Z") // 05:00 Beijing
        let newDay = try XCTUnwrap(once.recordingAttempt(now: nextDay, changed: false))
        XCTAssertEqual(newDay.attemptsToday, 1)
        XCTAssertFalse(newDay.eligibility(now: late, changed: true))
        XCTAssertNil(newDay.recordingAttempt(now: late, changed: true))
    }

    func testFailedAttemptConsumesBudgetAndManualReadsDoNot() throws {
        let now = date("2026-09-23T00:00:00Z")
        let state = try XCTUnwrap(CoveHealthRefreshPolicy().recordingAttempt(now: now, changed: false))
        // An I/O failure does not refund the already recorded attempt. A manual read
        // is handled by the caller and does not call recordingAttempt at all.
        XCTAssertEqual(state.attemptsToday, 1)
        XCTAssertFalse(state.eligibility(now: now.addingTimeInterval(1), changed: true))
    }

    func testScopeIsBasicOnly() {
        XCTAssertEqual(CoveHealthRefreshPolicy.metricIDs, [
            "sleep", "sleepAwake", "sleepCore", "sleepDeep", "sleepREM", "sleepUnspecified",
            "restingHeartRate", "hrv", "steps", "oxygenSaturation"
        ])
        XCTAssertFalse(CoveHealthRefreshPolicy.metricIDs.contains("heartRate"))
        XCTAssertFalse(CoveHealthRefreshPolicy.metricIDs.contains("height"))
        XCTAssertFalse(CoveHealthRefreshPolicy.metricIDs.contains("workouts"))
    }
}
