import XCTest
@testable import Cove

final class HomeMemoriesTests: XCTestCase {
    func testAnniversaryCountsFirstDayAndShanghaiMidnight() throws {
        let formatter = ISO8601DateFormatter()
        XCTAssertEqual(CoveHomeDates.togetherDay(on: formatter.date(from: "2026-08-19T15:59:59Z")!), 0)
        XCTAssertEqual(CoveHomeDates.togetherDay(on: formatter.date(from: "2026-08-19T16:00:00Z")!), 1)
        XCTAssertEqual(CoveHomeDates.togetherDay(on: formatter.date(from: "2026-09-15T16:00:00Z")!), 28)
        XCTAssertEqual(CoveHomeDates.togetherDay(on: formatter.date(from: "2027-08-19T16:00:00Z")!), 366)
        XCTAssertEqual(CoveHomeDates.timestamp(formatter.date(from: "2026-09-15T16:30:00Z")!), "2026-09-16 00:30")
    }

    func testCalendarHandlesLeapYearMondayFirstAndYearBoundary() {
        XCTAssertEqual(CoveHomeDates.days(in: "2028-02").count, 29)
        XCTAssertEqual(CoveHomeDates.days(in: "2026-02").count, 28)
        XCTAssertEqual(CoveHomeDates.leadingBlanks(in: "2026-09"), 1)
        XCTAssertEqual(CoveHomeDates.leadingBlanks(in: "2026-06"), 0)
        XCTAssertNil(CoveHomeDates.date("2026-13"))
        XCTAssertNil(CoveHomeDates.date("2026-2"))
        XCTAssertNil(CoveHomeDates.date("not-a-month"))
        let next = CoveHomeDates.calendar.date(byAdding: .month, value: 1, to: CoveHomeDates.date("2026-12")!)!
        XCTAssertEqual(CoveHomeDates.month(next), "2027-01")
    }

    func testCompleteCalendarNotPartialZeroOrAnotherMonth() throws {
        let value = CoveMemoryCalendarEnvelope.preview(month: "2026-09")
        XCTAssertEqual(try value.validated(for: "2026-09").days.count, 30)
        XCTAssertThrowsError(try value.validated(for: "2026-08"))
        let incomplete = CoveMemoryCalendarEnvelope(month: value.month, timezone: value.timezone, source: value.source,
            metric: value.metric, days: Array(value.days.dropFirst()), updatedAt: value.updatedAt, total: value.total)
        XCTAssertThrowsError(try incomplete.validated(for: "2026-09"))
        let duplicated = CoveMemoryCalendarEnvelope(month: value.month, timezone: value.timezone, source: value.source,
            metric: value.metric, days: Array(repeating: value.days[0], count: 30), updatedAt: value.updatedAt, total: 90)
        XCTAssertThrowsError(try duplicated.validated(for: "2026-09"))
    }

    func testZeroIsValidOnlyFromCompleteSuccessfulResponse() throws {
        let days = CoveHomeDates.days(in: "2026-09").map { CoveMemoryCalendarEnvelope.Day(date: $0, count: 0) }
        let zero = CoveMemoryCalendarEnvelope(month: "2026-09", timezone: "Asia/Shanghai", source: "ombre",
            metric: "created", days: days, updatedAt: Date(), total: 0)
        XCTAssertEqual(try zero.validated(for: "2026-09").total, 0)
        let mismatch = CoveMemoryCalendarEnvelope(month: zero.month, timezone: zero.timezone, source: zero.source,
            metric: zero.metric, days: zero.days, updatedAt: zero.updatedAt, total: 1)
        XCTAssertThrowsError(try mismatch.validated(for: "2026-09"))
    }
}
