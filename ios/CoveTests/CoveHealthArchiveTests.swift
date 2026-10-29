import XCTest
@testable import Cove

final class CoveHealthArchiveTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cove-health-archive-test-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func testDiskRoundTripRetainsOlderReadsAndSharingStates() throws {
        let entries = (0..<60).map { index in
            CoveHealthArchiveEntry(snapshot: .init(capturedAt: Date(timeIntervalSince1970: Double(index) * 86400), metrics: []),
                recordedAt: Date(timeIntervalSince1970: Double(index) * 86400), origin: .manual)
        }
        try CoveHealthArchive(directoryURL: directory).save(entries)
        let restored = try CoveHealthArchive(directoryURL: directory).load()
        XCTAssertEqual(restored.count, 60, "History must not silently truncate to seven days.")
        XCTAssertEqual(restored.first?.id, entries.last?.id)
        XCTAssertEqual(restored.last?.id, entries.first?.id)
        XCTAssertTrue(restored.allSatisfy { $0.sharingState == .localOnly })
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testCompleteFileProtectionAttribute() throws {
        try CoveHealthArchive(directoryURL: directory).save([])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("history.json").path)
        let value = attributes[.protectionKey]
        #if targetEnvironment(simulator)
        if value == nil { throw XCTSkip("Simulator does not expose file-protection metadata; real-device protection remains unverified.") }
        #endif
        let raw = (value as? FileProtectionType)?.rawValue ?? (value as? String)
        XCTAssertEqual(raw, FileProtectionType.complete.rawValue)
    }

    func testCorruptArchiveThrowsInsteadOfPretendingHistoryIsEmpty() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("history.json"))
        XCTAssertThrowsError(try CoveHealthArchive(directoryURL: directory).load())
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("history.json"), encoding: .utf8), "not json")
    }

    func testSharingStateRoundTripDoesNotTurnUnknownIntoSuccess() throws {
        let entry = CoveHealthArchiveEntry(snapshot: .init(capturedAt: Date(), metrics: []), origin: .request,
            sharingState: .deliveryUnknown, serviceID: "synthetic-service", conversationID: "synthetic-conversation", requestID: "synthetic-request")
        try CoveHealthArchive(directoryURL: directory).save([entry])
        let restored = try XCTUnwrap(CoveHealthArchive(directoryURL: directory).load().first)
        XCTAssertEqual(restored.sharingState, .deliveryUnknown)
        XCTAssertEqual(restored.requestID, entry.requestID)
        XCTAssertTrue(restored.sharingStatusText.contains("未确认"))
    }

    func testHistoryIndexHandlesEmptyAndNewestMonthFallback() {
        let empty = CoveHealthHistoryIndex(entries: [])
        XCTAssertEqual(empty.months, [])
        XCTAssertEqual(empty.activeMonth(selectedMonth: "2026-09"), "")
        XCTAssertTrue(empty.days(in: "").isEmpty)

        let entries = [entry(2026, 8, 31, 23), entry(2026, 9, 1, 0)]
        let index = CoveHealthHistoryIndex(entries: entries)
        XCTAssertEqual(index.months, ["2026-09", "2026-08"])
        XCTAssertEqual(index.activeMonth(selectedMonth: "missing"), "2026-09")
        XCTAssertEqual(index.activeMonth(selectedMonth: "2026-08"), "2026-08")
    }

    func testHistoryIndexGroupsAcrossMonthsAndRetainsSameDayReadingOrder() {
        let first = entry(2026, 9, 2, 9)
        let second = entry(2026, 9, 2, 8)
        let index = CoveHealthHistoryIndex(entries: [first, second, entry(2026, 9, 1, 22), entry(2026, 8, 31, 23)])
        let september = index.days(in: "2026-09")
        XCTAssertEqual(september.map(\.day), ["2026-09-02", "2026-09-01"])
        XCTAssertEqual(september[0].entries.map(\.id), [first.id, second.id])
        XCTAssertEqual(index.entryCount(in: "2026-09"), 3)
        XCTAssertEqual(index.entryCount(in: "2026-08"), 1)
    }

    func testHistoryIndexRebuildReflectsRefreshedArchiveWithoutMutatingOldIndex() {
        let original = [entry(2026, 9, 1, 8)]
        let before = CoveHealthHistoryIndex(entries: original)
        let after = CoveHealthHistoryIndex(entries: original + [entry(2026, 9, 2, 8), entry(2026, 10, 1, 8)])
        XCTAssertEqual(before.entryCount(in: "2026-09"), 1)
        XCTAssertEqual(after.entryCount(in: "2026-09"), 2)
        XCTAssertEqual(after.months, ["2026-10", "2026-09"])
        XCTAssertEqual(after.activeMonth(selectedMonth: "2026-09"), "2026-09")
    }

    func testLargeHistoryDerivesMonthAndDayExactlyOncePerEntry() {
        final class Counter { var months = 0; var days = 0 }
        let count = 20_000
        let entries = (0..<count).map { index in
            CoveHealthArchiveEntry(snapshot: .init(capturedAt: Date(timeIntervalSince1970: Double(index)), metrics: []),
                recordedAt: Date(timeIntervalSince1970: Double(index) * 3_601), origin: .manual)
        }
        let counter = Counter()
        let index = CoveHealthHistoryIndex(entries: entries, monthKey: { date in
            counter.months += 1
            return CoveHomeDates.month(date)
        }, dayKey: { date in
            counter.days += 1
            return CoveHomeDates.day(date)
        })
        XCTAssertEqual(counter.months, count)
        XCTAssertEqual(counter.days, count)
        XCTAssertEqual(index.months.reduce(0) { $0 + index.entryCount(in: $1) }, count)
        XCTAssertEqual(counter.months, count, "Reading grouped results must not rescan the archive.")
        XCTAssertEqual(counter.days, count, "Reading grouped results must not rederive day keys.")
    }

    private func entry(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> CoveHealthArchiveEntry {
        let date = CoveHomeDates.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        return CoveHealthArchiveEntry(snapshot: .init(capturedAt: date, metrics: []), recordedAt: date, origin: .manual)
    }
}

@MainActor
private final class ArchiveTestReader: CoveHealthReading {
    var reads = 0
    var value = HealthSnapshot(capturedAt: Date(), metrics: [.init(id: "steps", title: "合成测试步数", value: 123,
        unit: "步", sampledAt: Date(timeIntervalSince1970: 123))])
    func authorize(metrics: Set<String>) async throws {}
    func snapshot(metrics: Set<String>, startAt: Date?, endAt: Date) async throws -> HealthSnapshot { reads += 1; return value }
    func stopObserving() {}
}

private final class ArchiveTestCredentials: CoveCredentialStore {
    func read(account: String) -> String? { nil }
    func write(_ token: String, account: String) throws {}
}

@MainActor
final class CoveHealthArchiveStoreTests: XCTestCase {
    func testReadFailureDoesNotOverwriteCorruptArchiveWithNewSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cove-health-corrupt-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json")
        try Data("unreadable history".utf8).write(to: file)
        let store = CoveStore(credentials: ArchiveTestCredentials(), healthReader: ArchiveTestReader(),
                              healthArchive: CoveHealthArchive(directoryURL: directory))
        XCTAssertNotNil(store.healthArchiveError)
        await store.syncHealth()
        XCTAssertEqual(store.health?.metrics.first?.value, 123)
        XCTAssertNotNil(store.healthArchiveError, "A fresh read must not hide a failure to preserve the existing archive.")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "unreadable history")
        store.enablePreview()
        XCTAssertFalse(store.previewMode)
        XCTAssertEqual(store.healthArchiveEntries.count, 1)
    }

    func testFailedSaveBlocksPreviewUntilThePendingReadCanBeSaved() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("cove-health-write-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let blockedDirectory = parent.appendingPathComponent("archive")
        try Data("file blocks directory creation".utf8).write(to: blockedDirectory)
        let archive = CoveHealthArchive(directoryURL: blockedDirectory)
        let store = CoveStore(credentials: ArchiveTestCredentials(), healthReader: ArchiveTestReader(), healthArchive: archive)
        await store.syncHealth()
        let pendingID = try XCTUnwrap(store.healthArchiveEntries.first?.id)
        XCTAssertNotNil(store.healthArchiveError)
        store.enablePreview()
        XCTAssertFalse(store.previewMode, "A preview transition must not discard an unsaved genuine local read.")
        XCTAssertEqual(store.healthArchiveEntries.map(\.id), [pendingID])
        XCTAssertNotNil(store.errorMessage)
        // Repair only this test's synthetic filesystem obstacle; preview then
        // retries the write before it replaces visible state with sample data.
        try FileManager.default.removeItem(at: blockedDirectory)
        store.enablePreview()
        XCTAssertTrue(store.previewMode)
        XCTAssertEqual(try archive.load().map(\.id), [pendingID])
    }

    func testManualReadsRetainEachReadAndRestoreWithoutReadingHealthAgain() async throws {
        let archive = CoveHealthArchive(directoryURL: nil)
        let reader = ArchiveTestReader()
        let store = CoveStore(credentials: ArchiveTestCredentials(), healthReader: reader, healthArchive: archive)
        await store.syncHealth()
        await store.syncHealth()
        XCTAssertEqual(reader.reads, 2)
        XCTAssertEqual(store.healthArchiveEntries.count, 2, "Repeated intentional reads retain their own history entry.")
        XCTAssertEqual(store.healthHistory.count, 2)
        let restoredReader = ArchiveTestReader()
        let restored = CoveStore(credentials: ArchiveTestCredentials(), healthReader: restoredReader, healthArchive: archive)
        XCTAssertEqual(restored.healthArchiveEntries.count, 2)
        XCTAssertEqual(restored.health?.metrics.first?.value, 123)
        XCTAssertEqual(restoredReader.reads, 0)
        XCTAssertNil(restored.healthSyncedAt, "Local persistence must never pretend it uploaded.")
        XCTAssertTrue(restored.healthArchiveEntries.allSatisfy { $0.sharingState == .localOnly })
    }

    func testPreviewNeverReadsWritesOrClearsRealArchiveAndRestartRestores() async throws {
        let archive = CoveHealthArchive(directoryURL: nil)
        let entry = CoveHealthArchiveEntry(snapshot: .init(capturedAt: Date(), metrics: []), origin: .manual)
        try archive.save([entry])
        let reader = ArchiveTestReader()
        let store = CoveStore(credentials: ArchiveTestCredentials(), healthReader: reader, healthArchive: archive)
        store.enablePreview()
        await store.syncHealth()
        XCTAssertFalse(store.clearLocalHealthHistory())
        XCTAssertEqual(reader.reads, 0)
        XCTAssertTrue(store.healthArchiveEntries.isEmpty)
        XCTAssertEqual(try archive.load().map(\.id), [entry.id])
        // Avoid exitPreview's resume connection task; a fresh store represents
        // restart and must restore the exact real archive, not preview values.
        let restored = CoveStore(credentials: ArchiveTestCredentials(), healthReader: reader, healthArchive: archive)
        XCTAssertEqual(restored.healthArchiveEntries.map(\.id), [entry.id])
    }

    func testClearOnlyRemovesLocalCopyAndPersistsEmptyHistory() async throws {
        let archive = CoveHealthArchive(directoryURL: nil)
        let reader = ArchiveTestReader()
        let store = CoveStore(credentials: ArchiveTestCredentials(), healthReader: reader, healthArchive: archive)
        await store.syncHealth()
        store.isSyncingHealth = true
        XCTAssertFalse(store.clearLocalHealthHistory())
        store.isSyncingHealth = false
        XCTAssertTrue(store.clearLocalHealthHistory())
        XCTAssertTrue(try archive.load().isEmpty)
        XCTAssertNil(store.health)
        XCTAssertTrue(store.healthHistory.isEmpty)
        XCTAssertEqual(reader.reads, 1)
    }

    func testSnapshotVerificationAllowsCanonicalTitlesOrderingAndMilliseconds() {
        let captured = Date(timeIntervalSince1970: 1_800_000_000.1234)
        let first = HealthMetric(id: "steps", title: "本机标题", value: 321, unit: "步",
                                 sampledAt: captured, detail: "范围", source: "设备")
        let second = HealthMetric(id: "hrv", title: "HRV", value: 42.5, unit: "毫秒",
                                  sampledAt: captured.addingTimeInterval(-1), detail: nil, source: "设备")
        let local = HealthSnapshot(capturedAt: captured, metrics: [first, second])
        var canonicalFirst = first; canonicalFirst.title = "服务端规范标题"
        let remote = HealthSnapshot(capturedAt: Date(timeIntervalSince1970: 1_800_000_000.123),
                                    metrics: [second, canonicalFirst])
        XCTAssertTrue(CoveHealthSnapshotVerification.matches(local, remote))
        var changed = remote; changed.metrics[0].detail = "字段丢失"
        XCTAssertFalse(CoveHealthSnapshotVerification.matches(local, changed))

        var literalSentinel = local
        literalSentinel.metrics[0].detail = "<nil>"
        var missing = literalSentinel
        missing.metrics[0].detail = nil
        XCTAssertFalse(CoveHealthSnapshotVerification.matches(literalSentinel, missing))

        var separatorText = local
        separatorText.metrics[0].detail = "左\u{1f}右"
        var separatedFields = separatorText
        separatedFields.metrics[0].detail = "左"
        separatedFields.metrics[0].source = "右\u{1f}设备"
        XCTAssertFalse(CoveHealthSnapshotVerification.matches(separatorText, separatedFields))

        var duplicate = local
        duplicate.metrics.append(first)
        XCTAssertFalse(CoveHealthSnapshotVerification.matches(duplicate, local), "Duplicate samples must not collapse into a set.")
    }
}
