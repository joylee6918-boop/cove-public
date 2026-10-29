import XCTest
@testable import Cove

@MainActor
final class CoveHomeLifeTests: XCTestCase {
    final class Backend: CoveDeviceActionBackend {
        var permissions: [CoveSystemCapability: CoveCapabilityStatus] = [:]
        var calls: [CoveDeviceAction] = []
        var requests = 0
        var failed: CoveSystemCapability?
        var afterRead: (() -> Void)?
        var records: [CoveDeviceRecord] = []
        func status(_ capability: CoveSystemCapability) -> CoveCapabilityStatus { permissions[capability] ?? .authorized }
        func request(_ capability: CoveSystemCapability) async throws { requests += 1 }
        func execute(_ action: CoveDeviceAction) async throws -> CoveDeviceActionResult {
            calls.append(action)
            afterRead?()
            if failed == action.operation.capability { throw CoveDeviceActionError.invalid("fixture read failure") }
            return .init(actionID: action.id, records: records, message: "test only")
        }
    }

    func testPreviewDoesNotRequestOrReadAnything() async {
        let backend = Backend()
        let subject = CoveHomeLifeModel(backend: backend)
        await subject.refresh(preview: true)
        XCTAssertEqual(backend.requests, 0)
        XCTAssertTrue(backend.calls.isEmpty)
        for capability in CoveSystemCapability.allCases {
            guard case .permission(.preview) = subject.states[capability] else { return XCTFail("preview must stay explicit") }
        }
    }

    func testPermissionStatesNeverPromptAndNeverBecomeEmptyLists() async {
        for status in [CoveCapabilityStatus.notDetermined, .denied, .restricted, .writeOnly, .unavailable, .unknown] {
            let backend = Backend()
            backend.permissions = Dictionary(uniqueKeysWithValues: CoveSystemCapability.allCases.map { ($0, status) })
            let model = CoveHomeLifeModel(backend: backend)
            await model.refresh(preview: false)
            XCTAssertTrue(backend.calls.isEmpty)
            XCTAssertEqual(backend.requests, 0)
            for capability in CoveSystemCapability.allCases {
                guard case .permission(let actual) = model.states[capability] else { return XCTFail("not an empty result") }
                XCTAssertEqual(actual, status)
            }
        }
    }

    func testOnlyThreeReadOperationsAndCalendarDayWindow() async {
        let backend = Backend()
        let model = CoveHomeLifeModel(backend: backend)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 14))!
        await model.refresh(preview: false, now: now, calendar: calendar)
        XCTAssertEqual(backend.calls.map(\.operation), [.listEvents, .listReminders, .listAlarms])
        XCTAssertTrue(backend.calls.allSatisfy { !$0.operation.isMutation })
        XCTAssertEqual(backend.requests, 0)
        let events = backend.calls[0]
        XCTAssertEqual(events.start, calendar.startOfDay(for: now))
        XCTAssertEqual(events.end, calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: now)))
        XCTAssertEqual(events.end!.timeIntervalSince(events.start!), 7 * 86_400 - 3600) // DST, not seven fixed 24h days.
    }

    func testFailureIsSeparateAndOtherCapabilitiesStillLoad() async {
        let backend = Backend(); backend.failed = .calendar
        let model = CoveHomeLifeModel(backend: backend)
        await model.refresh(preview: false)
        guard case .failed = model.states[.calendar] else { return XCTFail("failure cannot mean no events") }
        for capability in [CoveSystemCapability.reminders, .alarms] {
            guard case .ready(let records, _) = model.states[capability] else { return XCTFail("independent capability must load") }
            XCTAssertTrue(records.isEmpty)
        }
    }

    func testRevocationDuringReadDiscardsReturnedPrivateContent() async {
        let backend = Backend()
        backend.records = [.init(id: "private", title: "fixture")]
        backend.afterRead = { backend.permissions[.calendar] = .denied }
        let model = CoveHomeLifeModel(backend: backend)
        await model.refresh(preview: false)
        guard case .permission(.denied) = model.states[.calendar] else { return XCTFail("late record must not display") }
    }

    func testInvalidateRejectsLateReadAndStopsRemainingReads() async {
        let backend = Backend()
        let model = CoveHomeLifeModel(backend: backend)
        backend.afterRead = { model.invalidate() }
        await model.refresh(preview: false)
        XCTAssertTrue(model.states.isEmpty)
        XCTAssertEqual(backend.calls.count, 1)
    }

    func testCanceledRefreshDoesNotRead() async {
        let backend = Backend()
        let model = CoveHomeLifeModel(backend: backend)
        let task = Task { await model.refresh(preview: false) }
        task.cancel()
        await task.value
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testUpcomingPrefersOngoingNotFinishedAndRetainsRepeatingOccurrences() {
        let now = Date()
        let records: [CoveDeviceRecord] = [
            .init(id: "repeating", title: "future", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(7200)),
            .init(id: "finished", title: "finished", start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600)),
            .init(id: "repeating", title: "ongoing", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(600))
        ]
        XCTAssertEqual(CoveHomeLifeModel.sorted(records).count, 3)
        XCTAssertEqual(CoveHomeLifeModel.featured(records, capability: .calendar, now: now)?.title, "ongoing")
        XCTAssertNil(CoveHomeLifeModel.featured([records[1]], capability: .calendar, now: now))
        XCTAssertEqual(CoveHomeLifeModel.featured(records, capability: .alarms, now: now)?.title, "future")
    }

    func testRemindersSortDatedBeforeUndatedWithoutDiscardingOverdue() {
        let now = Date()
        let records: [CoveDeviceRecord] = [.init(id: "none", title: "undated"), .init(id: "due", title: "overdue", start: now.addingTimeInterval(-100))]
        XCTAssertEqual(CoveHomeLifeModel.sorted(records).map(\.id), ["due", "none"])
        XCTAssertEqual(CoveHomeLifeModel.featured(records, capability: .reminders, now: now)?.id, "due")
        XCTAssertEqual(CoveHomeLifeModel.dateLabel(records[0], capability: .reminders), "没有截止日期")
    }

    func testDateOnlyLabelsDoNotInventMidnightTimes() {
        let now = Date()
        let record = CoveDeviceRecord(id: "all-day", title: "fixture", start: now, dateOnly: true)
        XCTAssertEqual(CoveHomeLifeModel.dateLabel(record, capability: .calendar, now: now), "今天 · 全天")
        XCTAssertEqual(CoveHomeLifeModel.dateLabel(record, capability: .reminders, now: now), "今天 · 当天到期")
    }

    func testDatePrecisionIsNotEncodedOrUsedInReceiptReconciliation() throws {
        let original = CoveDeviceRecord(id: "all-day", title: "fixture", start: Date(), dateOnly: true)
        let data = try JSONEncoder().encode(original)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["dateOnly"])
        let decoded = try JSONDecoder().decode(CoveDeviceRecord.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertFalse(decoded.dateOnly)
    }

    func testDurationDoesNotMisrepresentSubMinuteOrInvalidData() {
        XCTAssertEqual(CoveHomeLifeModel.duration(0), "0 分钟")
        XCTAssertEqual(CoveHomeLifeModel.duration(30), "不足 1 分钟")
        XCTAssertEqual(CoveHomeLifeModel.duration(60), "1 分钟")
        XCTAssertEqual(CoveHomeLifeModel.duration(3660), "1 小时 1 分钟")
        XCTAssertEqual(CoveHomeLifeModel.duration(.infinity), "—")
        XCTAssertEqual(CoveHomeLifeModel.duration(-1), "—")
    }
}
