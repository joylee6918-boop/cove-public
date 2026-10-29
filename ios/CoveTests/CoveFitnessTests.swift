import XCTest
@testable import Cove

final class CoveFitnessTests: XCTestCase {
    private var directory: URL!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var end: Date { start.addingTimeInterval(3_600) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cove-fitness-test-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    private func strength() -> CoveFitnessDraft {
        .init(name: "合成测试 · 下肢", kind: .strength, startedAt: start,
              exercises: [.init(name: "深蹲", sets: [.init(weightKG: 25.5, reps: 8, completed: true), .init(weightKG: 30, reps: 6)])],
              effort: .normal, note: "仅用于自动测试")
    }
    private func activity() -> CoveFitnessDraft {
        .init(name: "合成测试 · 快走", kind: .activity, startedAt: start,
              activity: .init(kind: "快走", durationSeconds: 1_800, distanceKM: 2.5, energyKCAL: 120), effort: .easy)
    }
    private func calendar(_ zone: String, firstWeekday: Int = 2) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        value.firstWeekday = firstWeekday; value.minimumDaysInFirstWeek = 4
        return value
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func record(_ startedAt: Date, duration: Double = 600, id: UUID = UUID()) -> CoveFitnessSession {
        .init(workout: .init(id: id, name: "合成测试活动", kind: .activity, startedAt: startedAt, activity: .init(kind: "快走")),
              endedAt: startedAt.addingTimeInterval(duration))
    }

    func testStrengthPersistenceRoundTripRetainsIDsPlansAndNotes() throws {
        let repository = CoveFitnessRepository(directoryURL: directory)
        let original = strength()
        let draft = try repository.saveDraft(original, now: end)
        let record = try repository.complete(draft, endedAt: end, now: end)
        let restored = try CoveFitnessRepository(directoryURL: directory).snapshot()
        XCTAssertNil(restored.draft)
        XCTAssertEqual(restored.sessions, [record])
        XCTAssertEqual(record.id, original.id)
        XCTAssertEqual(record.workout.exercises[0].sets.map(\.id), original.exercises[0].sets.map(\.id))
        XCTAssertEqual(record.completedSetCount, 1, "Unfinished plans are retained, not counted as performance.")
        XCTAssertEqual(record.durationSeconds, 3_600)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testGeneralActivityPersistenceRoundTrip() throws {
        let repository = CoveFitnessRepository(directoryURL: directory)
        let draft = try repository.saveDraft(activity(), now: end)
        let record = try repository.complete(draft, endedAt: end, now: end)
        let restored = try CoveFitnessRepository(directoryURL: directory).snapshot()
        XCTAssertEqual(restored.sessions, [record])
        XCTAssertEqual(record.durationSeconds, 1_800)
        XCTAssertEqual(record.workout.activity?.distanceKM, 2.5)
        XCTAssertEqual(record.workout.activity?.energyKCAL, 120)
        XCTAssertEqual(record.workout.effort, .easy)
    }

    func testDraftRecoveryAndExplicitDiscardAreDurable() throws {
        let repository = CoveFitnessRepository(directoryURL: directory)
        let draft = try repository.saveDraft(strength(), now: end)
        let reopened = CoveFitnessRepository(directoryURL: directory)
        XCTAssertEqual(try reopened.snapshot().draft, draft)
        try reopened.discard(draft)
        try reopened.discard(draft) // Idempotent discard.
        XCTAssertNil(try repository.snapshot().draft)
        XCTAssertTrue(try repository.snapshot().sessions.isEmpty)
        XCTAssertThrowsError(try repository.saveDraft(draft, now: end))
        XCTAssertThrowsError(try repository.complete(draft, endedAt: end, now: end))
    }

    func testCompletionIsImmutableAndIdempotentAcrossRelaunch() throws {
        let repository = CoveFitnessRepository(directoryURL: directory)
        let draft = try repository.saveDraft(strength(), now: end)
        let completed = try repository.complete(draft, endedAt: end, now: end)
        let reopened = CoveFitnessRepository(directoryURL: directory)
        XCTAssertEqual(try reopened.complete(draft, endedAt: end, now: end), completed)
        XCTAssertEqual(try reopened.snapshot().sessions.count, 1)
        XCTAssertThrowsError(try reopened.complete(draft, endedAt: end.addingTimeInterval(1), now: end.addingTimeInterval(1)))
        var changed = draft; changed.note = "不能覆盖原始记录"
        XCTAssertThrowsError(try reopened.saveDraft(changed, now: end))
        XCTAssertThrowsError(try reopened.complete(changed, endedAt: end, now: end))
        XCTAssertThrowsError(try reopened.discard(draft))
        XCTAssertEqual(try reopened.snapshot().sessions, [completed])
    }

    func testIdenticalSaveDoesNotRewriteFileOrIncrementRevision() throws {
        let repository = CoveFitnessRepository(directoryURL: directory)
        let request = strength()
        let accepted = try repository.saveDraft(request, now: end)
        let file = directory.appendingPathComponent("fitness-v1.json")
        let data = try Data(contentsOf: file)
        let sentinel = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: file.path)
        XCTAssertEqual(try repository.saveDraft(accepted, now: end), accepted)
        XCTAssertEqual(try repository.saveDraft(request, now: end), accepted, "An exact request retry after lost ACK is idempotent too.")
        XCTAssertEqual(try Data(contentsOf: file), data)
        let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        XCTAssertEqual(modified, sentinel)
    }

    func testStaleEditorAndSecondDraftCannotOverwriteCurrentDraft() throws {
        let first = CoveFitnessRepository(directoryURL: directory)
        let second = CoveFitnessRepository(directoryURL: directory)
        let draft = try first.saveDraft(strength(), now: end)
        var edit = draft; edit.note = "第一位编辑者"
        let accepted = try first.saveDraft(edit, now: end)
        var stale = draft; stale.note = "过期编辑者"
        XCTAssertThrowsError(try second.saveDraft(stale, now: end))
        XCTAssertThrowsError(try second.saveDraft(activity(), now: end))
        XCTAssertThrowsError(try second.discard(draft))
        XCTAssertThrowsError(try second.complete(draft, endedAt: end, now: end))
        XCTAssertEqual(try second.snapshot().draft, accepted)
    }

    func testInMemoryRepositoryIsIsolatedAndStartsEmpty() throws {
        let repository = CoveFitnessRepository(directoryURL: nil)
        XCTAssertTrue(try repository.snapshot().sessions.isEmpty)
        let draft = try repository.saveDraft(activity(), now: end)
        XCTAssertEqual(try repository.snapshot().draft, draft)
        XCTAssertNil(try CoveFitnessRepository(directoryURL: nil).snapshot().draft)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testCorruptArchiveFailsClosedAndNeverOverwrites() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("fitness-v1.json")
        let corrupt = Data("not a fitness archive".utf8)
        try corrupt.write(to: file)
        let repository = CoveFitnessRepository(directoryURL: directory)
        XCTAssertThrowsError(try repository.snapshot())
        XCTAssertThrowsError(try repository.saveDraft(strength(), now: end))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    func testUnsupportedOrSemanticallyInvalidArchiveFailsClosed() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("fitness-v1.json")
        var archive = CoveFitnessArchive(); archive.version = 99
        try JSONEncoder().encode(archive).write(to: file)
        let repository = CoveFitnessRepository(directoryURL: directory)
        XCTAssertThrowsError(try repository.snapshot())
        archive.version = 1
        let value = record(start)
        archive.sessions = [value, value]
        try JSONEncoder().encode(archive).write(to: file)
        XCTAssertThrowsError(try repository.snapshot())
        archive.sessions = [value]; archive.draft = value.workout
        XCTAssertThrowsError(try archive.validate())
    }

    func testFailedWriteDoesNotPretendDraftWasSaved() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("fitness-v1.json")
        // A directory occupying the file path is an explicit I/O failure, not empty history.
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let repository = CoveFitnessRepository(directoryURL: directory)
        XCTAssertThrowsError(try repository.saveDraft(strength(), now: end))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testEmptyStrengthDraftAllowedButEmptyCompletionRejected() throws {
        let repository = CoveFitnessRepository(directoryURL: nil)
        let draft = try repository.saveDraft(.init(name: "自由训练", kind: .strength, startedAt: start), now: end)
        XCTAssertThrowsError(try repository.complete(draft, endedAt: end, now: end))
        XCTAssertEqual(try repository.snapshot().draft, draft)
        XCTAssertTrue(try repository.snapshot().sessions.isEmpty)
    }

    func testNonFiniteNegativeAndOutOfRangeNumbersRejected() throws {
        for number in [Double.nan, Double.infinity, -Double.infinity, -0.1, 2_001] {
            var draft = strength(); draft.exercises[0].sets[0].weightKG = number
            XCTAssertThrowsError(try CoveFitnessValidation.draft(draft))
        }
        for reps in [0, -1, 1_001] {
            var draft = strength(); draft.exercises[0].sets[0].reps = reps
            XCTAssertThrowsError(try CoveFitnessValidation.draft(draft))
        }
        for number in [Double.nan, Double.infinity, -Double.infinity, -1] {
            var draft = activity(); draft.activity?.distanceKM = number
            XCTAssertThrowsError(try CoveFitnessValidation.draft(draft))
            draft = activity(); draft.activity?.energyKCAL = number
            XCTAssertThrowsError(try CoveFitnessValidation.draft(draft))
            draft = activity(); draft.activity?.durationSeconds = number
            XCTAssertThrowsError(try CoveFitnessValidation.draft(draft))
        }
        var bodyweight = strength(); bodyweight.exercises[0].sets[0].weightKG = 0
        XCTAssertNoThrow(try CoveFitnessValidation.draft(bodyweight))
    }

    func testBlankNamesWrongPayloadAndDuplicateIDsRejected() throws {
        for name in ["", "  \n", "换\n行", String(repeating: "名", count: 121)] {
            var draft = strength(); draft.name = name
            XCTAssertThrowsError(try CoveFitnessValidation.draft(draft))
            draft = strength(); draft.exercises[0].name = name
            XCTAssertThrowsError(try CoveFitnessValidation.draft(draft))
            draft = activity(); draft.activity?.kind = name
            XCTAssertThrowsError(try CoveFitnessValidation.draft(draft))
        }
        var draft = strength(); draft.activity = .init(kind: "跑步")
        XCTAssertThrowsError(try CoveFitnessValidation.draft(draft))
        draft = activity(); draft.activity = nil
        XCTAssertThrowsError(try CoveFitnessValidation.draft(draft))
        draft = strength(); draft.exercises.append(draft.exercises[0])
        XCTAssertThrowsError(try CoveFitnessValidation.draft(draft))
        draft = strength(); draft.exercises[0].sets.append(draft.exercises[0].sets[0])
        XCTAssertThrowsError(try CoveFitnessValidation.draft(draft))
    }

    func testPartialStrengthSetsCannotDecodeOrComplete() throws {
        let id = UUID().uuidString
        for json in ["{\"id\":\"\(id)\",\"reps\":8,\"completed\":true}",
                     "{\"id\":\"\(id)\",\"weightKG\":10,\"completed\":true}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(CoveFitnessSet.self, from: Data(json.utf8)))
        }
        var draft = strength(); draft.exercises[0].sets[0].reps = 0
        XCTAssertThrowsError(try CoveFitnessValidation.session(.init(workout: draft, endedAt: end)))
    }

    func testImpossibleDatesFutureAndDurationMismatchRejected() throws {
        for date in [Date(timeIntervalSince1970: -.infinity), Date(timeIntervalSince1970: .nan),
                     Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: -1)] {
            var draft = strength(); draft.startedAt = date
            XCTAssertThrowsError(try CoveFitnessValidation.draft(draft))
        }
        var future = strength(); future.startedAt = end.addingTimeInterval(1)
        XCTAssertThrowsError(try CoveFitnessValidation.draft(future, now: end))
        for endedAt in [start, start.addingTimeInterval(-1), end.addingTimeInterval(1)] {
            XCTAssertThrowsError(try CoveFitnessValidation.session(.init(workout: strength(), endedAt: endedAt), now: end))
        }
        XCTAssertThrowsError(try CoveFitnessValidation.session(.init(workout: strength(), endedAt: start.addingTimeInterval(604_801))))
        var draft = activity(); draft.activity?.durationSeconds = 3_601
        XCTAssertThrowsError(try CoveFitnessValidation.session(.init(workout: draft, endedAt: end)))
        draft.activity?.durationSeconds = 0
        XCTAssertThrowsError(try CoveFitnessValidation.draft(draft))
    }

    func testTimerActivityUsesActualIntervalWithoutInventingDistanceOrEnergy() throws {
        var draft = activity(); draft.activity = .init(kind: "瑜伽")
        let session = CoveFitnessSession(workout: draft, endedAt: end)
        try CoveFitnessValidation.session(session)
        XCTAssertEqual(session.durationSeconds, 3_600)
        let summary = try XCTUnwrap(CoveFitnessSummaries.summary([session], containing: start, calendar: calendar("UTC")))
        XCTAssertNil(summary.distanceKM); XCTAssertNil(summary.energyKCAL)
    }

    func testWeeklyBoundaryIsHalfOpenAndHonorsTimeZone() throws {
        let monday = date("2026-10-19T00:00:00Z")
        let sessions = [record(monday.addingTimeInterval(-1)), record(monday), record(monday.addingTimeInterval(604_800))]
        let utc = try XCTUnwrap(CoveFitnessSummaries.summary(sessions, containing: monday, calendar: calendar("UTC")))
        XCTAssertEqual(utc.sessionCount, 1)
        XCTAssertEqual(utc.interval.start, monday)
        let la = try XCTUnwrap(CoveFitnessSummaries.summary(sessions, containing: monday, calendar: calendar("America/Los_Angeles")))
        XCTAssertEqual(la.sessionCount, 2, "UTC Monday still belongs to the previous local week in Los Angeles.")
        XCTAssertNotEqual(la.interval, utc.interval)
        let sundayFirst = try XCTUnwrap(CoveFitnessSummaries.summary([], containing: monday, calendar: calendar("UTC", firstWeekday: 1)))
        XCTAssertEqual(sundayFirst.interval.start, date("2026-10-18T00:00:00Z"))
    }

    func testRhythmUsesCalendarDaysAcrossDaylightSaving() throws {
        let reference = date("2026-03-08T18:00:00Z")
        let cal = calendar("America/Los_Angeles", firstWeekday: 1)
        let sessions = [record(date("2026-03-08T08:30:00Z")), record(date("2026-03-09T06:30:00Z"))]
        let rhythm = CoveFitnessSummaries.weekRhythm(sessions, containing: reference, calendar: cal)
        XCTAssertEqual(rhythm.count, 7)
        XCTAssertEqual(rhythm[0].count, 2)
        XCTAssertEqual(rhythm[1].date.timeIntervalSince(rhythm[0].date), 23 * 3_600)
        XCTAssertTrue(rhythm.allSatisfy { cal.component(.hour, from: $0.date) == 0 })
    }

    func testMonthlyGroupingUsesLocalStartDayAndCalendar() throws {
        let boundary = date("2026-11-01T00:30:00Z")
        let sessions = [record(boundary), record(date("2026-11-02T08:00:00Z"))]
        let utc = CoveFitnessSummaries.months(sessions, calendar: calendar("UTC"))
        let la = CoveFitnessSummaries.months(sessions, calendar: calendar("America/Los_Angeles"))
        XCTAssertEqual(utc.count, 1); XCTAssertEqual(la.count, 2)
        XCTAssertEqual(la[1].sessions.first?.id, sessions[0].id)
        let october = try XCTUnwrap(CoveFitnessSummaries.summary(sessions, containing: boundary, component: .month, calendar: calendar("America/Los_Angeles")))
        XCTAssertEqual(october.sessionCount, 1)
    }

    func testSummariesAreDeterministicAndExcludeUnfinishedSets() throws {
        let strengthSession = CoveFitnessSession(workout: strength(), endedAt: end)
        let activitySession = CoveFitnessSession(workout: activity(), endedAt: end)
        let cal = calendar("UTC")
        let first = try XCTUnwrap(CoveFitnessSummaries.summary([strengthSession, activitySession], containing: start, calendar: cal))
        let second = CoveFitnessSummaries.summary([activitySession, strengthSession], containing: start, calendar: cal)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.sessionCount, 2); XCTAssertEqual(first.activeDays, 1)
        XCTAssertEqual(first.durationSeconds, 5_400); XCTAssertEqual(first.completedSets, 1)
        XCTAssertEqual(first.distanceKM, 2.5); XCTAssertEqual(first.energyKCAL, 120)
        let ordered = CoveFitnessSummaries.ordered([strengthSession, activitySession])
        XCTAssertEqual(ordered, CoveFitnessSummaries.ordered([activitySession, strengthSession]))
    }

    func testPreviousPerformanceUsesLatestFinishedMatchingExerciseOnly() throws {
        let early = CoveFitnessSession(workout: strength(), endedAt: end)
        var laterDraft = strength(); laterDraft.startedAt = end.addingTimeInterval(3_600)
        laterDraft.exercises[0].sets[0].weightKG = 40
        let later = CoveFitnessSession(workout: laterDraft, endedAt: end.addingTimeInterval(7_200))
        let cutoff = later.endedAt.addingTimeInterval(1)
        let previous = try XCTUnwrap(CoveFitnessSummaries.previousPerformance(named: " 深蹲 ", before: cutoff, sessions: [early, later]))
        XCTAssertEqual(previous.sessionID, later.id)
        XCTAssertEqual(previous.sets.count, 1)
        XCTAssertEqual(previous.sets[0].weightKG, 40)
        XCTAssertEqual(CoveFitnessSummaries.previousPerformance(named: "深蹲", before: later.workout.startedAt, sessions: [later, early])?.sessionID, early.id)
        XCTAssertNil(CoveFitnessSummaries.previousPerformance(named: "卧推", before: cutoff, sessions: [early, later]))
        XCTAssertNil(CoveFitnessSummaries.previousPerformance(named: "深蹲", before: start, sessions: [early]))
    }

    func testDraftDoesNotDisappearWhenCompletionValidationFails() throws {
        let repository = CoveFitnessRepository(directoryURL: directory)
        let draft = try repository.saveDraft(activity(), now: end)
        XCTAssertThrowsError(try repository.complete(draft, endedAt: start.addingTimeInterval(30), now: end))
        XCTAssertEqual(try CoveFitnessRepository(directoryURL: directory).snapshot().draft, draft)
        XCTAssertTrue(try repository.snapshot().sessions.isEmpty)
    }

    func testCompletedRecordSnapshotCannotMutateRepository() throws {
        let repository = CoveFitnessRepository(directoryURL: nil)
        let draft = try repository.saveDraft(strength(), now: end)
        let original = try repository.complete(draft, endedAt: end, now: end)
        var snapshot = try repository.snapshot()
        snapshot.sessions.removeAll()
        XCTAssertEqual(try repository.snapshot().sessions, [original])
    }

    #if os(iOS)
    func testCompleteFileProtectionAttribute() throws {
        let repository = CoveFitnessRepository(directoryURL: directory)
        try repository.saveDraft(strength(), now: end)
        let file = directory.appendingPathComponent("fitness-v1.json")
        let attribute = try FileManager.default.attributesOfItem(atPath: file.path)[.protectionKey]
        #if targetEnvironment(simulator)
        if attribute == nil { throw XCTSkip("Simulator does not expose file protection; device protection is not verified.") }
        #endif
        let value = (attribute as? FileProtectionType)?.rawValue ?? (attribute as? String)
        XCTAssertEqual(value, FileProtectionType.complete.rawValue)
    }
    #endif
}

#if os(iOS)
@MainActor
final class CoveFitnessModelTests: XCTestCase {
    func testPreviewNeverReadsOrWritesInjectedRealRepository() throws {
        let repository = CoveFitnessRepository(directoryURL: nil)
        let draft = try repository.saveDraft(.init(name: "真实草稿", kind: .strength))
        let preview = CoveFitnessModel(repository: repository, isPreview: true)
        XCTAssertTrue(preview.isPreview); XCTAssertNil(preview.draft)
        XCTAssertTrue(preview.start(.init(name: "明确标记的预览", kind: .strength)))
        XCTAssertEqual(try repository.snapshot().draft, draft)
    }

    func testFailedEditRemainsVisibleAndCanBeCorrectedWithoutChangingPersistedDraft() throws {
        let repository = CoveFitnessRepository(directoryURL: nil)
        let model = CoveFitnessModel(repository: repository)
        XCTAssertTrue(model.start(.init(name: "合成测试", kind: .strength)))
        let persisted = try repository.snapshot().draft
        model.update { $0.name = "" }
        XCTAssertTrue(model.hasUnsavedChanges); XCTAssertNotNil(model.error)
        XCTAssertEqual(model.draft?.name, "")
        XCTAssertEqual(try repository.snapshot().draft, persisted)
        model.update { $0.name = "修正后的合成测试" }
        XCTAssertFalse(model.hasUnsavedChanges); XCTAssertNil(model.error)
        XCTAssertEqual(try repository.snapshot().draft?.name, "修正后的合成测试")
    }

    func testDiscardUnsavedEditUsesPersistedRevision() throws {
        let repository = CoveFitnessRepository(directoryURL: nil)
        let model = CoveFitnessModel(repository: repository)
        XCTAssertTrue(model.start(.init(name: "合成测试", kind: .strength)))
        model.update { $0.note = String(repeating: "字", count: 4_001) }
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertTrue(model.discard())
        XCTAssertNil(model.draft); XCTAssertNil(try repository.snapshot().draft)
    }
}
#endif
