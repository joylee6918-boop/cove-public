import XCTest
@testable import Cove

final class CoveUsagePresentationTests: XCTestCase {
    func testProShowsOnlyActualWeeklyAccountLimitNotSpark() {
        let windows = [window("codex_bengalfox-primary", "GPT-5.3-Codex-Spark · 5小时额度", 0),
                       window("codex_bengalfox-secondary", "GPT-5.3-Codex-Spark · 每周额度", 0),
                       window("codex-primary", "codex · 每周额度", 65)]
        let result = CoveUsagePresentation.accountWindows(windows)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.title, "周额度")
        XCTAssertEqual(result.first?.usedPercent, 65)
        XCTAssertEqual(CoveUsagePresentation.planName("prolite"), "Pro")
    }

    func testPlusKeepsBothRealWindowsInOrder() {
        let windows = [window("codex-secondary", "codex · 每周额度", 73),
                       window("codex-primary", "codex · 5小时额度", 12)]
        let result = CoveUsagePresentation.accountWindows(windows)
        XCTAssertEqual(result.map(\.id), ["codex-5h", "codex-weekly"])
        XCTAssertEqual(result.map(\.usedPercent), [12, 73])
        XCTAssertEqual(CoveUsagePresentation.planName("plus"), "Plus")
        XCTAssertEqual(result.first?.resetsAt, windows.last?.resetsAt)
    }

    func testNewSchemaAndMissingLimitsAreNotFabricated() {
        XCTAssertEqual(CoveUsagePresentation.accountWindows([]).count, 0)
        let result = CoveUsagePresentation.accountWindows([window("codex-weekly", "周额度", 8)])
        XCTAssertEqual(result.map(\.id), ["codex-weekly"])
        XCTAssertEqual(CoveUsagePresentation.planName(nil), "未知")
    }

    private func window(_ id: String, _ title: String, _ used: Double) -> UsageWindow {
        UsageWindow(id: id, title: title, usedPercent: used, resetsAt: Date(timeIntervalSince1970: 1234))
    }
}
