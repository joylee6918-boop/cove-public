import XCTest
#if canImport(Cove)
@testable import Cove
#endif

final class CoveLedgerTests: XCTestCase {
    private var repository: CoveLedgerRepository!
    private var account: CoveLedgerAccount!
    private var destination: CoveLedgerAccount!
    private var expense: CoveLedgerCategory!
    private var income: CoveLedgerCategory!
    private let locale = Locale(identifier: "en_US")
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    private var october: Date { date("2026-10-15T00:00:00Z") }

    override func setUpWithError() throws {
        repository = CoveLedgerRepository(directoryURL: nil)
        account = try repository.saveAccount(name: "测试账户 A")
        destination = try repository.saveAccount(name: "测试账户 B")
        expense = try repository.saveCategory(name: "测试餐饮", kind: .expense)
        income = try repository.saveCategory(name: "测试工资", kind: .income)
    }

    private func transaction(_ kind: CoveLedgerKind = .expense, amount: Int64 = 100,
                             occurredAt: Date? = nil, accountID: UUID? = nil,
                             destinationID: UUID? = nil, categoryID: UUID? = nil) -> CoveLedgerTransaction {
        .init(kind: kind, amountFen: amount, accountID: accountID ?? account.id,
              destinationAccountID: kind == .transfer ? (destinationID ?? destination.id) : destinationID,
              categoryID: categoryID ?? (kind == .transfer ? nil : kind == .expense ? expense.id : income.id),
              note: "合成测试，不是真实账目", occurredAt: occurredAt ?? october)
    }
    private func event(_ transaction: CoveLedgerTransaction? = nil, id: UUID = UUID(),
                       reversesID: UUID? = nil, createdAt: Date? = nil) -> CoveLedgerEvent {
        .init(id: id, transaction: transaction, reversesID: reversesID,
              reason: reversesID == nil ? "" : "合成测试更正原因", createdAt: createdAt ?? october)
    }
    private func summary(_ at: Date? = nil, calendar override: Calendar? = nil) throws -> CoveLedgerSummary {
        try repository.load().summary(containing: at ?? october, calendar: override ?? calendar)
    }

    func testExactIntegerFenParsingAndLocaleInput() throws {
        for (text, fen): (String, Int64) in [("0.01", 1), ("1", 100), ("12.3", 1230), (" 12.34 ", 1234),
                                           ("92233720368547758.07", Int64.max), ("００１.０２", 102)] {
            XCTAssertEqual(try CoveLedgerMoney.parse(text, locale: locale), fen)
        }
        XCTAssertEqual(try CoveLedgerMoney.parse("12,34", locale: Locale(identifier: "de_DE")), 1234)
        XCTAssertEqual(try CoveLedgerMoney.parse("١٢٫٣٤", locale: Locale(identifier: "ar_EG")), 1234)
        XCTAssertEqual(try CoveLedgerMoney.parse("0", locale: locale, allowZero: true), 0)
    }

    func testParsingRejectsAmbiguousOrInvalidAmounts() {
        for invalid in ["", " ", "0", "0.00", "-1", "+1", "1.001", "1e3", "NaN", "1,000", "1 000", ".5", "1.",
                        "1.2.3", "²", "92233720368547758.08", "999999999999999999999999999999999999"] {
            XCTAssertThrowsError(try CoveLedgerMoney.parse(invalid, locale: locale), invalid)
        }
        XCTAssertThrowsError(try CoveLedgerMoney.parse("1.23", locale: Locale(identifier: "de_DE")))
    }

    func testExactLocalizedDisplayIncludingIntegerExtremes() {
        XCTAssertEqual(CoveLedgerMoney.editable(Int64.max, locale: locale), "92233720368547758.07")
        XCTAssertEqual(CoveLedgerMoney.editable(Int64.min, locale: locale), "-92233720368547758.08")
        XCTAssertEqual(CoveLedgerMoney.editable(101, locale: Locale(identifier: "de_DE")), "1,01")
        XCTAssertTrue(CoveLedgerMoney.display(101, locale: locale).contains("1.01"))
        XCTAssertTrue(CoveLedgerMoney.display(-101, locale: locale).contains("-"))
        XCTAssertTrue(CoveLedgerMoney.display(Int64.max, locale: locale).hasSuffix("758.07"))
        XCTAssertTrue(CoveLedgerMoney.display(Int64.min, locale: locale).hasSuffix("758.08"))
        XCTAssertTrue(CoveLedgerMoney.display(101, locale: Locale(identifier: "de_DE")).contains("1,01"))
    }

    func testExpenseIncomeAndTransferAccounting() throws {
        try repository.append(event(transaction(.income, amount: 50_000)))
        try repository.append(event(transaction(.expense, amount: 12_345)))
        try repository.append(event(transaction(.transfer, amount: 10_000)))
        let result = try summary()
        XCTAssertEqual(result.expenseFen, 12_345)
        XCTAssertEqual(result.incomeFen, 50_000)
        XCTAssertEqual(result.categories.map(\.amountFen), [12_345])
        let movements = try repository.load().accountMovements()
        XCTAssertEqual(movements[account.id], 27_655)
        XCTAssertEqual(movements[destination.id], 10_000)
        XCTAssertEqual(try movements.values.reduce(Int64(0), CoveLedgerMoney.add), 37_655)
    }

    func testTransferIsOneAtomicBalancedEventAndNeverUsesBudget() throws {
        let transfer = event(transaction(.transfer, amount: Int64.max))
        try repository.append(transfer)
        let snapshot = try repository.load()
        XCTAssertEqual(snapshot.events.count, 1)
        let postings = try snapshot.postings(for: transfer)
        XCTAssertEqual(postings.count, 2)
        XCTAssertEqual(postings.map(\.amountFen), [-Int64.max, Int64.max])
        XCTAssertEqual(try postings.reduce(Int64(0)) { try CoveLedgerMoney.add($0, $1.amountFen) }, 0)
        XCTAssertEqual(try summary().expenseFen, 0)
        XCTAssertEqual(try summary().incomeFen, 0)
        XCTAssertTrue(try summary().categories.isEmpty)
    }

    func testAbsentBudgetIsUnknownAndConfiguredZeroIsNotUnknown() throws {
        XCTAssertNil(try summary().budgetFen)
        XCTAssertNil(try summary().availableBudgetFen)
        let month = try CoveLedgerMonth(containing: october, calendar: calendar)
        try repository.setBudget(.init(month: month, overallFen: 0, categoryFen: [:]))
        XCTAssertEqual(try summary().availableBudgetFen, 0)
        try repository.append(event(transaction(amount: 100)))
        XCTAssertEqual(try summary().availableBudgetFen, -100)
        try repository.setBudget(.init(month: month, overallFen: nil, categoryFen: [:]))
        XCTAssertNil(try summary().budgetFen)
        XCTAssertTrue(try repository.load().budgets.isEmpty)
    }

    func testOverallAndCategoryBudgetsAreIndependent() throws {
        let month = try CoveLedgerMonth(containing: october, calendar: calendar)
        try repository.setBudget(.init(month: month, overallFen: 10_000, categoryFen: [expense.id: 2_000]))
        try repository.append(event(transaction(amount: 2_500)))
        XCTAssertEqual(try summary().availableBudgetFen, 7_500)
        XCTAssertEqual(try summary().categories.first?.budgetFen, 2_000)
        try repository.setBudget(.init(month: month, overallFen: nil, categoryFen: [expense.id: 0]))
        XCTAssertNil(try summary().availableBudgetFen)
        XCTAssertEqual(try summary().categories.first?.budgetFen, 0)
    }

    func testBudgetCategoryWithoutSpendingAppearsWithZeroRecordedExpense() throws {
        try repository.setBudget(.init(month: CoveLedgerMonth(containing: october, calendar: calendar),
                                       overallFen: nil, categoryFen: [expense.id: 500]))
        XCTAssertEqual(try summary().categories.first?.amountFen, 0)
        XCTAssertEqual(try summary().categories.first?.budgetFen, 500)
    }

    func testMonthBoundariesAreStartInclusiveEndExclusiveInSelectedZone() throws {
        try repository.append(event(transaction(amount: 1, occurredAt: date("2026-09-30T15:59:59Z"))))
        try repository.append(event(transaction(amount: 2, occurredAt: date("2026-09-30T16:00:00Z"))))
        try repository.append(event(transaction(amount: 4, occurredAt: date("2026-10-31T15:59:59Z"))))
        try repository.append(event(transaction(amount: 8, occurredAt: date("2026-10-31T16:00:00Z"))))
        XCTAssertEqual(try summary().expenseFen, 6)
        var utc = calendar; utc.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(try summary(calendar: utc).expenseFen, 12)
        XCTAssertEqual(try summary(date("2026-11-15T00:00:00Z")).expenseFen, 8)
    }

    func testDSTMonthUsesCalendarRatherThanFixedDaySeconds() throws {
        var losAngeles = calendar; losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let march = date("2026-03-15T00:00:00Z")
        let month = try CoveLedgerMonth(containing: march, calendar: losAngeles)
        XCTAssertEqual(month.start, date("2026-03-01T08:00:00Z"))
        XCTAssertEqual(month.end, date("2026-04-01T07:00:00Z"))
        try repository.append(event(transaction(amount: 1, occurredAt: month.start)))
        try repository.append(event(transaction(amount: 2, occurredAt: month.end)))
        XCTAssertEqual(try summary(march, calendar: losAngeles).expenseFen, 1)
    }

    func testNonGregorianCalendarAndBudgetScopeAreDeterministic() throws {
        var chinese = Calendar(identifier: .chinese); chinese.timeZone = calendar.timeZone
        let month = try CoveLedgerMonth(containing: october, calendar: chinese)
        try repository.setBudget(.init(month: month, overallFen: 500, categoryFen: [:]))
        try repository.append(event(transaction(amount: 100, occurredAt: month.start)))
        XCTAssertEqual(try summary(calendar: chinese).expenseFen, 100)
        XCTAssertEqual(try summary(calendar: chinese).availableBudgetFen, 400)
        XCTAssertNil(try summary().budgetFen, "Budget is scoped to calendar and time zone, not a guessed YYYY-MM.")
        var utc = chinese; utc.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertNil(try summary(calendar: utc).budgetFen)
    }

    func testIdempotentAppendReturnsSameEventAndConflictingPayloadIsRejected() throws {
        let original = event(transaction())
        XCTAssertEqual(try repository.append(original), original)
        XCTAssertEqual(try repository.append(original), original)
        XCTAssertEqual(try repository.load().events, [original])
        let conflict = event(transaction(amount: 101), id: original.id)
        XCTAssertThrowsError(try repository.append(conflict)) { XCTAssertEqual($0 as? CoveLedgerError, .operationConflict) }
        XCTAssertEqual(try summary().expenseFen, 100)
    }

    func testCorrectionIsLinkedAtomicAndRestatesOriginalMonth() throws {
        let original = event(transaction(amount: 100))
        try repository.append(original)
        let november = date("2026-11-15T00:00:00Z")
        let correction = event(transaction(amount: 80), reversesID: original.id, createdAt: november)
        try repository.append(correction)
        let snapshot = try repository.load()
        XCTAssertEqual(snapshot.events, [original, correction], "Accepted original must be byte-for-byte unchanged.")
        XCTAssertEqual(try snapshot.postings(for: correction).map(\.amountFen), [100, -80])
        XCTAssertEqual(try summary().expenseFen, 80)
        XCTAssertEqual(try summary(november).expenseFen, 0)
        XCTAssertEqual(try summary().recentEntries.first, correction)
        XCTAssertEqual(snapshot.reversal(of: original.id), correction)
        XCTAssertEqual(snapshot.effectiveEntries, [correction])
    }

    func testCorrectionCanMoveMonthAndCategoryWithoutRewritingHistory() throws {
        let original = event(transaction(amount: 100))
        try repository.append(original)
        let november = date("2026-11-15T00:00:00Z")
        let correction = event(transaction(.income, amount: 90, occurredAt: november), reversesID: original.id)
        try repository.append(correction)
        XCTAssertEqual(try summary().expenseFen, 0)
        XCTAssertEqual(try summary(november).incomeFen, 90)
        XCTAssertTrue(try summary().recentEntries.contains(correction), "The source month must expose its correction too.")
        XCTAssertTrue(try summary(november).recentEntries.contains(correction))
    }

    func testVoidOfCorrectionLeavesFullChainAndReversesReplacement() throws {
        let original = event(transaction(amount: 100)); try repository.append(original)
        let correction = event(transaction(amount: 80), reversesID: original.id); try repository.append(correction)
        let void = event(nil, reversesID: correction.id); try repository.append(void)
        XCTAssertEqual(try repository.append(void), void, "Retry is idempotent even though its target is now reversed.")
        XCTAssertEqual(try repository.load().events.count, 3)
        XCTAssertEqual(try repository.load().postings(for: void).map(\.amountFen), [80])
        XCTAssertEqual(try summary().expenseFen, 0)
        XCTAssertEqual(try repository.load().accountMovements()[account.id], 0)
        XCTAssertThrowsError(try repository.append(event(nil, reversesID: void.id)))
    }

    func testTransferVoidBalancesBothAccounts() throws {
        let original = event(transaction(.transfer, amount: 234)); try repository.append(original)
        let void = event(nil, reversesID: original.id); try repository.append(void)
        XCTAssertEqual(try repository.load().postings(for: void).map(\.amountFen), [234, -234])
        XCTAssertEqual(try repository.load().accountMovements()[account.id], 0)
        XCTAssertEqual(try repository.load().accountMovements()[destination.id], 0)
        XCTAssertEqual(try summary().expenseFen, 0)
    }

    func testInvalidLinkMissingReasonSelfLinkAndDoubleVoidAreRejected() throws {
        XCTAssertThrowsError(try repository.append(event(nil)))
        XCTAssertThrowsError(try repository.append(event(nil, reversesID: UUID())))
        let id = UUID()
        XCTAssertThrowsError(try repository.append(event(transaction(), id: id, reversesID: id)))
        let original = event(transaction()); try repository.append(original)
        XCTAssertThrowsError(try repository.append(.init(id: UUID(), transaction: nil, reversesID: original.id, reason: " \n", createdAt: october)))
        try repository.append(event(nil, reversesID: original.id))
        XCTAssertThrowsError(try repository.append(event(nil, reversesID: original.id)))
        XCTAssertThrowsError(try repository.append(event(transaction(), reversesID: original.id)))
        XCTAssertEqual(try repository.load().events.count, 2)
    }

    func testInvalidTransferAndReferencesLeaveNoPartialPosting() throws {
        let invalid = [transaction(.transfer, destinationID: account.id),
                       transaction(.transfer, destinationID: UUID()),
                       transaction(.transfer, categoryID: expense.id),
                       transaction(accountID: UUID()), transaction(categoryID: income.id),
                       transaction(destinationID: destination.id)]
        for transaction in invalid { XCTAssertThrowsError(try repository.append(event(transaction))) }
        XCTAssertTrue(try repository.load().events.isEmpty)
        XCTAssertEqual(try repository.load().accountMovements()[account.id], 0)
    }

    func testZeroNegativeAndInt64MinimumAreRejectedWithoutTrap() throws {
        for amount: Int64 in [0, -1, Int64.min] {
            let value = transaction(amount: amount)
            XCTAssertTrue(value.postings.isEmpty)
            XCTAssertThrowsError(try repository.append(event(value)))
        }
        XCTAssertTrue(try repository.load().events.isEmpty)
    }

    func testOverflowRejectsWholeEventAndPreservesOriginalState() throws {
        try repository.append(event(transaction(.income, amount: Int64.max)))
        let before = try repository.load()
        XCTAssertThrowsError(try repository.append(event(transaction(.income, amount: 1)))) {
            XCTAssertEqual($0 as? CoveLedgerError, .overflow)
        }
        XCTAssertEqual(try repository.load(), before)
        XCTAssertEqual(try summary().incomeFen, Int64.max)
    }

    func testTransferAccountOverflowIsAtomic() throws {
        try repository.append(event(transaction(.income, amount: Int64.max, accountID: destination.id)))
        let before = try repository.load()
        XCTAssertThrowsError(try repository.append(event(transaction(.transfer, amount: 1))))
        XCTAssertEqual(try repository.load(), before)
    }

    func testInvalidReplacementDoesNotVoidOriginal() throws {
        let original = event(transaction()); try repository.append(original)
        XCTAssertThrowsError(try repository.append(event(transaction(amount: -1), reversesID: original.id)))
        XCTAssertEqual(try summary().expenseFen, 100)
        XCTAssertNil(try repository.load().reversal(of: original.id))
    }

    func testAccountCategoryNamesAndStableRenameValidation() throws {
        for invalid in ["", " \n ", String(repeating: "字", count: 41), "控\u{0000}制"] {
            XCTAssertThrowsError(try repository.saveAccount(name: invalid))
            XCTAssertThrowsError(try repository.saveCategory(name: invalid, kind: .expense))
        }
        XCTAssertThrowsError(try repository.saveAccount(name: account.name))
        XCTAssertThrowsError(try repository.saveCategory(name: expense.name, kind: .expense))
        XCTAssertThrowsError(try repository.saveCategory(name: "转账不应分类", kind: .transfer))
        XCTAssertThrowsError(try repository.saveCategory(id: expense.id, name: expense.name, kind: .income))
        let trimmed = try repository.saveAccount(name: "  合成账户  ")
        XCTAssertEqual(trimmed.name, "合成账户")
        let original = event(transaction()); try repository.append(original)
        try repository.saveAccount(id: account.id, name: "改名后的测试账户")
        try repository.saveCategory(id: expense.id, name: "改名后的测试分类", kind: .expense)
        XCTAssertEqual(try repository.load().events.first, original)
        XCTAssertEqual(try summary().expenseFen, 100)
    }

    func testBudgetsValidateNegativeUnknownAndIncomeCategory() throws {
        let month = try CoveLedgerMonth(containing: october, calendar: calendar)
        for budget in [CoveLedgerBudget(month: month, overallFen: -1, categoryFen: [:]),
                       .init(month: month, overallFen: 10, categoryFen: [expense.id: -1]),
                       .init(month: month, overallFen: 10, categoryFen: [UUID(): 10]),
                       .init(month: month, overallFen: 10, categoryFen: [income.id: 10])] {
            XCTAssertThrowsError(try repository.setBudget(budget))
        }
        XCTAssertTrue(try repository.load().budgets.isEmpty)
    }

    func testDeterministicTieOrderingAndRecentLimit() throws {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        try repository.append(event(transaction(), id: secondID))
        try repository.append(event(transaction(), id: firstID))
        let snapshot = try repository.load()
        XCTAssertEqual(try snapshot.summary(containing: october, calendar: calendar).recentEntries.map(\.id), [firstID, secondID])
        XCTAssertEqual(try snapshot.summary(containing: october, calendar: calendar, recentLimit: 1).recentEntries.map(\.id), [firstID])
        XCTAssertTrue(try snapshot.summary(containing: october, calendar: calendar, recentLimit: -1).recentEntries.isEmpty)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CoveLedgerTests-\(UUID().uuidString)", isDirectory: true)
    }
    private func seed(_ disk: CoveLedgerRepository) throws {
        try disk.saveAccount(id: account.id, name: account.name)
        try disk.saveAccount(id: destination.id, name: destination.name)
        try disk.saveCategory(id: expense.id, name: expense.name, kind: .expense)
        try disk.saveCategory(id: income.id, name: income.name, kind: .income)
    }

    func testPersistenceRoundTripSchemaAndDurableIdempotency() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let disk = CoveLedgerRepository(directoryURL: directory); try seed(disk)
        let original = event(transaction(.transfer, amount: 12_345)); try disk.append(original)
        let correction = event(transaction(amount: 123), reversesID: original.id); try disk.append(correction)
        try disk.setBudget(.init(month: CoveLedgerMonth(containing: october, calendar: calendar), overallFen: 1000, categoryFen: [expense.id: 500]))
        let reopened = CoveLedgerRepository(directoryURL: directory)
        XCTAssertEqual(try disk.load(), try reopened.load())
        XCTAssertEqual(try reopened.load().schemaVersion, 2)
        XCTAssertEqual(try reopened.append(correction), correction)
        XCTAssertEqual(try reopened.load().events.count, 2)
        XCTAssertEqual(try reopened.load().summary(containing: october, calendar: calendar).expenseFen, 123)
    }

    func testTwoRepositoryInstancesDoNotLoseEachOthersWrites() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let first = CoveLedgerRepository(directoryURL: directory); try seed(first)
        let second = CoveLedgerRepository(directoryURL: directory)
        _ = try second.load()
        let one = event(transaction(amount: 1)), two = event(transaction(amount: 2))
        try first.append(one); try second.append(two)
        XCTAssertEqual(try first.load().events, [one, two])
    }

    func testCorruptAndFutureArchivesNeverGetSilentlyOverwritten() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("ledger-v1.json")
        let disk = CoveLedgerRepository(directoryURL: directory)
        for bytes in [Data("not JSON".utf8), try JSONEncoder().encode(CoveLedgerSnapshot(schemaVersion: 99))] {
            try bytes.write(to: file)
            XCTAssertThrowsError(try disk.load())
            XCTAssertThrowsError(try disk.saveAccount(name: "不能覆盖损坏数据"))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testArchiveReplayRejectsForgedLinkAndInvalidMoney() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("ledger-v1.json")
        let disk = CoveLedgerRepository(directoryURL: directory)
        var snapshot = try repository.load()
        for invalid in [event(transaction(amount: -1)), event(transaction(), reversesID: UUID())] {
            snapshot.events = [invalid]
            let data = try JSONEncoder().encode(snapshot); try data.write(to: file)
            XCTAssertThrowsError(try disk.load())
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }

    func testFailedWriteDoesNotAcceptAnEventInMemory() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let obstacle = directory.appendingPathComponent("not-a-directory")
        try Data("synthetic obstacle".utf8).write(to: obstacle)
        let disk = CoveLedgerRepository(directoryURL: obstacle)
        XCTAssertThrowsError(try disk.saveAccount(name: "无法保存"))
        XCTAssertThrowsError(try disk.load(), "An inaccessible path must not masquerade as an empty ledger.")
        XCTAssertEqual(try String(contentsOf: obstacle, encoding: .utf8), "synthetic obstacle")
        try FileManager.default.removeItem(at: obstacle)
        XCTAssertTrue(try disk.load().accounts.isEmpty, "No rejected operation is retained for later automatic saving.")
    }

    func testInMemoryRepositoryDoesNotCreateLiveArchive() throws {
        XCTAssertTrue(repository.isInMemory)
        XCTAssertNil(repository.directoryURL)
        try repository.append(event(transaction()))
        XCTAssertEqual(try repository.load().events.count, 1)
        XCTAssertTrue(try CoveLedgerRepository(directoryURL: nil).load().events.isEmpty)
    }

    func testDryRunDoesNotWriteAndUsesSameValidation() throws {
        let entry = event(transaction()); try repository.validate(entry)
        XCTAssertTrue(try repository.load().events.isEmpty)
        XCTAssertThrowsError(try repository.validate(event(transaction(.transfer, destinationID: account.id))))
        try repository.append(entry)
        XCTAssertNoThrow(try repository.validate(entry))
        XCTAssertThrowsError(try repository.validate(event(transaction(amount: 101), id: entry.id)))
    }

    func testConcurrentDuplicateAppendsAreAcceptedExactlyOnce() throws {
        let entry = event(transaction())
        let lock = NSLock()
        var failures: [String] = []
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            do { _ = try repository.append(entry) }
            catch { lock.lock(); failures.append(error.localizedDescription); lock.unlock() }
        }
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(try repository.load().events, [entry])
    }

    func testOutOfRangeDatesAndLongNotesAreRejected() throws {
        let invalidDate = Date(timeIntervalSinceReferenceDate: .infinity)
        XCTAssertThrowsError(try repository.append(event(transaction(occurredAt: invalidDate))))
        XCTAssertThrowsError(try repository.append(event(transaction(), createdAt: invalidDate)))
        XCTAssertThrowsError(try CoveLedgerMonth(containing: invalidDate, calendar: calendar))
        XCTAssertThrowsError(try CoveLedgerMonth(containing: Date(timeIntervalSinceReferenceDate: 1e30), calendar: calendar))
        let longNote = CoveLedgerTransaction(kind: .expense, amountFen: 100, accountID: account.id,
            destinationAccountID: nil, categoryID: expense.id, note: String(repeating: "字", count: 2_001), occurredAt: october)
        XCTAssertThrowsError(try repository.append(event(longNote))) { XCTAssertEqual($0 as? CoveLedgerError, .textTooLong) }
        XCTAssertTrue(try repository.load().events.isEmpty)
    }

    func testRejectedDiskMutationLeavesArchiveBytesUnchanged() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let disk = CoveLedgerRepository(directoryURL: directory); try seed(disk)
        let original = event(transaction()); try disk.append(original)
        let file = directory.appendingPathComponent("ledger-v1.json")
        let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try disk.append(event(transaction(amount: -1), reversesID: original.id)))
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try disk.load().events, [original])
    }

    func testDuplicateEventIDsInArchiveFailClosed() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = event(transaction())
        var snapshot = try repository.load(); snapshot.events = [original, original]
        let file = directory.appendingPathComponent("ledger-v1.json")
        try JSONEncoder().encode(snapshot).write(to: file)
        XCTAssertThrowsError(try CoveLedgerRepository(directoryURL: directory).load())
    }

    // MARK: v2 assets / liabilities (synthetic records only)

    private func typedAccounts() throws -> (CoveLedgerAccount, CoveLedgerAccount) {
        let liquid = try repository.saveAccount(id: account.id, name: account.name, type: .bank)
        let card = try repository.saveAccount(id: destination.id, name: destination.name, type: .creditCard)
        return (liquid, card)
    }

    @discardableResult
    private func anchor(_ id: UUID, _ value: Int64, at: Date? = nil, operationID: UUID = UUID()) throws -> CoveLedgerReconciliation {
        let value = CoveLedgerReconciliation(id: operationID, accountID: id, balanceFen: value,
                                            capturedAt: at ?? october, createdAt: at ?? october)
        return try repository.appendReconciliation(value)
    }

    private func statement(_ card: UUID, amount: Int64 = 1_000, due: Date? = nil, minimum: Int64? = nil,
                           id: UUID = UUID(), supersedes: UUID? = nil) -> CoveLedgerStatement {
        .init(id: id, accountID: card, statementDate: date("2026-10-01T00:00:00Z"),
              dueDate: due ?? date("2026-10-20T00:00:00Z"), amountFen: amount, minimumDueFen: minimum,
              createdAt: october, supersedesID: supersedes)
    }

    private func repayment(_ card: UUID, amount: Int64, statementID: UUID? = nil, at: Date? = nil) -> CoveLedgerTransaction {
        .init(kind: .transfer, amountFen: amount, accountID: account.id, destinationAccountID: card,
              categoryID: nil, note: "秘密商户和私人备注绝不能分享", occurredAt: at ?? date("2026-10-16T00:00:00Z"),
              statementID: statementID)
    }

    private func overview(_ at: Date? = nil, zone: Calendar? = nil) throws -> CoveLedgerFinanceOverview {
        try repository.load().financeOverview(asOf: at ?? date("2026-10-17T00:00:00Z"), calendar: zone ?? calendar)
    }

    func testV1DecodeLosslessMigrationAndSameFilenameWriteV2() throws {
        let original = event(transaction()); try repository.append(original)
        let corrected = event(transaction(amount: 80), reversesID: original.id); try repository.append(corrected)
        try repository.setBudget(.init(month: CoveLedgerMonth(containing: october, calendar: calendar), overallFen: 100, categoryFen: [:]))
        let before = try repository.load()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(before)) as? [String: Any])
        json["schemaVersion"] = 1; json.removeValue(forKey: "reconciliations"); json.removeValue(forKey: "statements")
        json.removeValue(forKey: "installments")
        json["accounts"] = before.accounts.map { ["id": $0.id.uuidString, "name": $0.name] }
        let legacy = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("ledger-v1.json"); try legacy.write(to: file)
        let disk = CoveLedgerRepository(directoryURL: directory)
        let migrated = try disk.load()
        XCTAssertEqual(migrated.schemaVersion, 2)
        XCTAssertEqual(migrated.events, before.events); XCTAssertEqual(migrated.budgets, before.budgets)
        XCTAssertEqual(migrated.categories, before.categories); XCTAssertEqual(migrated.accounts, before.accounts)
        XCTAssertTrue(migrated.installments.isEmpty, "V1 migration must never invent plans.")
        XCTAssertTrue(migrated.accounts.allSatisfy { $0.type == .unclassified })
        XCTAssertTrue(migrated.events.allSatisfy { $0.transaction?.statementID == nil })
        XCTAssertEqual(try Data(contentsOf: file), legacy, "Read migration never rewrites a file.")
        try disk.saveAccount(id: account.id, name: account.name, type: .bank)
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(written["schemaVersion"] as? Int, 2)
        XCTAssertNotNil(written["reconciliations"]); XCTAssertNotNil(written["statements"])
        XCTAssertEqual(try disk.load().events, before.events)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ledger-v2.json").path))
    }

    func testV2RoundtripWithAnchorsStatementCorrectionAndPayment() throws {
        let (liquid, card) = try typedAccounts()
        try anchor(liquid.id, 10_000); try anchor(card.id, -2_000)
        let bill = statement(card.id); try repository.appendStatement(bill)
        try repository.append(event(repayment(card.id, amount: 300, statementID: bill.id)))
        try repository.appendStatement(statement(card.id, amount: 900, supersedes: bill.id))
        let snapshot = try repository.load()
        let decoded = try JSONDecoder().decode(CoveLedgerSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(try decoded.financeOverview(asOf: date("2026-10-17T00:00:00Z"), calendar: calendar).recordedOutstandingFen, 600)
    }

    func testUnanchoredIsUnknownEvenWithTransactionsAndExplicitZeroIsKnown() throws {
        let (liquid, card) = try typedAccounts()
        try repository.append(event(transaction(.income, amount: 100)))
        XCTAssertNil(try overview().balances[liquid.id]); XCTAssertNil(try overview().liquid.totalFen)
        XCTAssertEqual(try overview().liquid.unknownAccountCount, 1)
        XCTAssertNil(try overview().cardDebt.totalFen)
        try anchor(liquid.id, 0); try anchor(card.id, 0)
        XCTAssertEqual(try overview().liquid.totalFen, 0)
        XCTAssertEqual(try overview().cardDebt.totalFen, 0)
        XCTAssertEqual(try overview().balances[liquid.id], 0, "Posting at capture is already reflected.")
    }

    func testSignedLiquidAndCardBalancesBackfillAndLatestAnchor() throws {
        let (liquid, card) = try typedAccounts()
        try anchor(liquid.id, 10_000); try anchor(card.id, -2_000)
        try repository.append(event(transaction(amount: 9_000, occurredAt: date("2026-10-14T00:00:00Z"))))
        try repository.append(event(repayment(card.id, amount: 500)))
        try repository.append(event(transaction(amount: 100, occurredAt: date("2026-10-16T01:00:00Z"), accountID: card.id)))
        XCTAssertEqual(try overview().balances[liquid.id], 9_500)
        XCTAssertEqual(try overview().balances[card.id], -1_600)
        XCTAssertEqual(try overview().cardDebt.totalFen, 1_600)
        try anchor(liquid.id, 20_000, at: date("2026-10-16T12:00:00Z"))
        try anchor(liquid.id, 5, at: date("2026-10-13T00:00:00Z"))
        XCTAssertEqual(try overview().balances[liquid.id], 20_000, "An appended older observation must not replace the latest capture.")
        XCTAssertNil(try overview(date("2026-10-12T00:00:00Z")).balances[liquid.id])
    }

    func testReconciliationTiesAreStableAndRetainAllObservations() throws {
        let (liquid, _) = try typedAccounts()
        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let high = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        try anchor(liquid.id, 12, operationID: high); try anchor(liquid.id, 11, operationID: low)
        XCTAssertEqual(try overview().balances[liquid.id], 12)
        XCTAssertEqual(try repository.load().reconciliations.count, 2)
    }

    func testReconciliationWrongTypeSignDateAndAccountRejected() throws {
        XCTAssertThrowsError(try anchor(account.id, 1), "Unclassified is not guessed as an asset.")
        let (liquid, card) = try typedAccounts()
        XCTAssertThrowsError(try anchor(liquid.id, -1)); XCTAssertThrowsError(try anchor(card.id, 1))
        XCTAssertThrowsError(try anchor(card.id, Int64.min)); XCTAssertThrowsError(try anchor(UUID(), 1))
        XCTAssertThrowsError(try repository.appendReconciliation(.init(id: UUID(), accountID: liquid.id, balanceFen: 0,
            capturedAt: october.addingTimeInterval(1), createdAt: october)))
        XCTAssertThrowsError(try anchor(liquid.id, 1, at: Date(timeIntervalSinceReferenceDate: .infinity)))
        XCTAssertTrue(try repository.load().reconciliations.isEmpty)
    }

    func testClassificationAndRenameCannotInvalidateAnchorsOrStatements() throws {
        let (liquid, card) = try typedAccounts()
        try anchor(liquid.id, 100); try repository.appendStatement(statement(card.id))
        XCTAssertThrowsError(try repository.saveAccount(id: liquid.id, name: liquid.name, type: .creditCard))
        XCTAssertThrowsError(try repository.saveAccount(id: card.id, name: card.name, type: .bank))
        try repository.saveAccount(id: liquid.id, name: "新的名称", type: .eWallet)
        try repository.saveAccount(id: card.id, name: "仅改名")
        XCTAssertEqual(try repository.load().accounts.first(where: { $0.id == card.id })?.type, .creditCard)
        XCTAssertEqual(try overview().liquid.totalFen, 100)
    }

    func testStatementInvalidValuesTypesDatesAndCorrectionBranches() throws {
        let (liquid, card) = try typedAccounts()
        for invalid in [statement(liquid.id), statement(UUID()), statement(card.id, amount: -1),
                        statement(card.id, minimum: -1), statement(card.id, minimum: 1_001),
                        statement(card.id, due: date("2026-09-30T00:00:00Z")), statement(card.id, supersedes: UUID())] {
            XCTAssertThrowsError(try repository.appendStatement(invalid))
        }
        let bill = statement(card.id, minimum: 100); try repository.appendStatement(bill)
        let replacement = statement(card.id, amount: 800, supersedes: bill.id)
        try repository.appendStatement(replacement)
        XCTAssertThrowsError(try repository.appendStatement(statement(card.id, supersedes: bill.id)))
        let another = try repository.saveAccount(name: "另一张合成信用卡", type: .creditCard)
        XCTAssertThrowsError(try repository.appendStatement(statement(another.id, supersedes: replacement.id)))
        XCTAssertEqual(try repository.load().statements, [bill, replacement])
        XCTAssertEqual(try repository.load().effectiveStatements, [replacement])
        let nan = CoveLedgerStatement(id: UUID(), accountID: card.id, statementDate: Date(timeIntervalSinceReferenceDate: .nan),
            dueDate: october, amountFen: 1, minimumDueFen: nil, createdAt: october, supersedesID: nil)
        XCTAssertThrowsError(try repository.appendStatement(nan))
    }

    func testLinkedUnlinkedRepaymentsDoNotDoubleCountExpensesOrSilentlyPayStatement() throws {
        let (liquid, card) = try typedAccounts()
        try anchor(liquid.id, 10_000); try anchor(card.id, -2_000)
        let bill = statement(card.id); try repository.appendStatement(bill)
        try repository.append(event(repayment(card.id, amount: 200)))
        XCTAssertEqual(try overview().recordedOutstandingFen, 1_000)
        try repository.append(event(repayment(card.id, amount: 300, statementID: bill.id)))
        XCTAssertEqual(try overview().recordedOutstandingFen, 700)
        XCTAssertEqual(try overview().statements.first?.paidFen, 300)
        XCTAssertEqual(try overview().cardDebt.totalFen, 1_500)
        XCTAssertEqual(try overview().liquidAfterRecordedDuesFen, 8_800)
        XCTAssertEqual(try summary().expenseFen, 0); XCTAssertEqual(try summary().incomeFen, 0)
    }

    func testReplacementCarriesPaymentChainAndTransactionVoidRestoresDue() throws {
        let (_, card) = try typedAccounts()
        let bill = statement(card.id); try repository.appendStatement(bill)
        let payment = event(repayment(card.id, amount: 400, statementID: bill.id)); try repository.append(payment)
        let corrected = statement(card.id, amount: 500, supersedes: bill.id); try repository.appendStatement(corrected)
        XCTAssertEqual(try overview().statements.first?.remainingFen, 100)
        let correctedPayment = event(repayment(card.id, amount: 300, statementID: corrected.id), reversesID: payment.id)
        try repository.append(correctedPayment)
        XCTAssertEqual(try overview().statements.first?.remainingFen, 200)
        try repository.append(event(nil, reversesID: correctedPayment.id))
        XCTAssertEqual(try overview().statements.first?.remainingFen, 500)
        XCTAssertEqual(try repository.load().statements, [bill, corrected])
    }

    func testWrongRepaymentLinksAreRejectedAtomically() throws {
        let (liquid, card) = try typedAccounts()
        let bill = statement(card.id); try repository.appendStatement(bill)
        var invalidExpense = transaction(); invalidExpense.statementID = bill.id
        for invalid in [invalidExpense, repayment(liquid.id, amount: 100, statementID: bill.id),
                        repayment(card.id, amount: 100, statementID: UUID()),
                        repayment(card.id, amount: 100, statementID: bill.id, at: date("2026-09-30T00:00:00Z"))] {
            XCTAssertThrowsError(try repository.append(event(invalid)))
        }
        XCTAssertTrue(try repository.load().events.isEmpty)
    }

    func testOverpaymentIsCappedAndDoesNotPayAnotherBill() throws {
        let (_, card) = try typedAccounts()
        let first = statement(card.id, amount: 100); try repository.appendStatement(first)
        let second = statement(card.id, amount: 200); try repository.appendStatement(second)
        try anchor(card.id, -100)
        try repository.append(event(repayment(card.id, amount: 150, statementID: first.id)))
        let result = try overview()
        XCTAssertEqual(result.statements.first(where: { $0.id == first.id })?.paidFen, 100)
        XCTAssertEqual(result.statements.first(where: { $0.id == first.id })?.status, .paid)
        XCTAssertEqual(result.statements.first(where: { $0.id == second.id })?.remainingFen, 200)
        XCTAssertEqual(result.balances[card.id], 50)
        XCTAssertEqual(result.cardDebt.totalFen, 0, "A card credit is not negative debt or liquid funds.")
    }

    func testDueBoundariesUseInjectedTimezoneAndCalendarDays() throws {
        let (_, card) = try typedAccounts()
        let bill = statement(card.id, due: date("2026-10-20T00:00:00Z")); try repository.appendStatement(bill)
        XCTAssertEqual(try overview(date("2026-10-12T16:00:00Z")).statements.first?.status, .dueSoon)
        XCTAssertEqual(try overview(date("2026-10-12T15:59:59Z")).statements.first?.status, .upcoming)
        XCTAssertEqual(try overview(date("2026-10-20T15:59:59Z")).statements.first?.status, .dueSoon)
        XCTAssertEqual(try overview(date("2026-10-20T16:00:00Z")).statements.first?.status, .overdue)
        var utc = calendar; utc.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(try overview(date("2026-10-20T16:00:00Z"), zone: utc).statements.first?.status, .dueSoon)
    }

    func testOutstandingOrderingNearestAndPaidLast() throws {
        let (_, card) = try typedAccounts()
        let overdue = statement(card.id, due: date("2026-10-10T00:00:00Z"))
        let soon = statement(card.id, due: date("2026-10-20T00:00:00Z"))
        let later = statement(card.id, due: date("2026-10-30T00:00:00Z"))
        let paid = statement(card.id, amount: 0, due: date("2026-10-02T00:00:00Z"))
        for bill in [later, paid, soon, overdue] { try repository.appendStatement(bill) }
        XCTAssertEqual(try overview().statements.map(\.id), [overdue.id, soon.id, later.id, paid.id])
        XCTAssertEqual(try overview().nearestOutstanding?.id, overdue.id)
        XCTAssertEqual(try overview().statements.map(\.status), [.overdue, .dueSoon, .upcoming, .paid])
    }

    func testPartialKnownTotalsAndUnclassifiedExclusionAreHonest() throws {
        let (liquid, card) = try typedAccounts()
        try repository.saveAccount(name: "尚未核对的现金", type: .cash)
        try repository.saveAccount(name: "尚未核对的卡", type: .creditCard)
        try repository.saveAccount(name: "旧账户")
        try anchor(liquid.id, 500); try anchor(card.id, -100)
        try repository.appendStatement(statement(card.id, amount: 1_000))
        let result = try overview()
        XCTAssertNil(result.liquid.totalFen); XCTAssertEqual(result.liquid.knownSubtotalFen, 500)
        XCTAssertEqual(result.liquid.unknownAccountCount, 1)
        XCTAssertNil(result.cardDebt.totalFen); XCTAssertEqual(result.cardDebt.knownSubtotalFen, 100)
        XCTAssertEqual(result.cardDebt.unknownAccountCount, 1)
        XCTAssertEqual(result.unclassifiedAccountCount, 1); XCTAssertNil(result.liquidAfterRecordedDuesFen)
        XCTAssertEqual(result.recordedOutstandingFen, 1_000)
    }

    func testBalanceAndAggregateOverflowRejectWholeMutationWithoutTrap() throws {
        let (liquid, card) = try typedAccounts()
        try anchor(liquid.id, Int64.max)
        let before = try repository.load()
        XCTAssertThrowsError(try repository.append(event(transaction(.income, amount: 1, occurredAt: date("2026-10-16T00:00:00Z")))))
        XCTAssertEqual(try repository.load(), before)
        let cash = try repository.saveAccount(name: "合成现金", type: .cash)
        XCTAssertThrowsError(try anchor(cash.id, 1))
        try anchor(card.id, -Int64.max)
        XCTAssertThrowsError(try repository.append(event(transaction(amount: 1, occurredAt: date("2026-10-16T00:00:00Z"), accountID: card.id))))
        XCTAssertEqual(try overview().cardDebt.totalFen, Int64.max)
        try repository.appendStatement(statement(card.id, amount: Int64.max))
        XCTAssertThrowsError(try repository.appendStatement(statement(card.id, amount: 1)))
        XCTAssertEqual(try repository.load().statements.count, 1)
    }

    func testAnchorStatementIdempotencyConflictAndCrossKindIDs() throws {
        let (liquid, card) = try typedAccounts()
        let observed = try anchor(liquid.id, 100)
        XCTAssertEqual(try repository.appendReconciliation(observed), observed)
        XCTAssertThrowsError(try anchor(liquid.id, 101, operationID: observed.id))
        let bill = statement(card.id); try repository.appendStatement(bill)
        XCTAssertEqual(try repository.appendStatement(bill), bill)
        XCTAssertThrowsError(try repository.appendStatement(statement(card.id, amount: 999, id: bill.id)))
        XCTAssertThrowsError(try anchor(liquid.id, 100, operationID: bill.id))
        XCTAssertThrowsError(try repository.append(event(transaction(), id: observed.id)))
        XCTAssertThrowsError(try repository.appendStatement(statement(card.id, id: observed.id)))
        XCTAssertEqual(try repository.load().reconciliations.count, 1)
        XCTAssertEqual(try repository.load().statements.count, 1)
    }

    func testConcurrentRepositoriesAnchorStatementAndPaymentPersistence() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let first = CoveLedgerRepository(directoryURL: directory); try seed(first)
        try first.saveAccount(id: account.id, name: account.name, type: .bank)
        try first.saveAccount(id: destination.id, name: destination.name, type: .creditCard)
        let second = CoveLedgerRepository(directoryURL: directory)
        let bill = statement(destination.id)
        let observed = CoveLedgerReconciliation(id: UUID(), accountID: account.id, balanceFen: 1_000,
                                                capturedAt: october, createdAt: october)
        let lock = NSLock(); var failures: [String] = []
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            do {
                if index % 2 == 0 { try first.appendReconciliation(observed) }
                else { try second.appendStatement(bill) }
            } catch { lock.lock(); failures.append(error.localizedDescription); lock.unlock() }
        }
        XCTAssertTrue(failures.isEmpty)
        try first.append(event(repayment(destination.id, amount: 100, statementID: bill.id)))
        XCTAssertEqual(try first.load(), try second.load())
        XCTAssertEqual(try second.load().reconciliations, [observed])
        XCTAssertEqual(try second.load().statements, [bill])
        XCTAssertEqual(try second.load().financeOverview(asOf: date("2026-10-17T00:00:00Z"), calendar: calendar).recordedOutstandingFen, 900)
    }

    func testPrivacySummaryIsDeterministicTimestampedAndExcludesNamesNotesAndTransactions() throws {
        let (liquid, card) = try typedAccounts()
        try repository.saveAccount(id: liquid.id, name: "不应分享的私人账户名称")
        try anchor(liquid.id, 2_000); try anchor(card.id, -1_000)
        let bill = statement(card.id); try repository.appendStatement(bill)
        try repository.append(event(repayment(card.id, amount: 200, statementID: bill.id)))
        try repository.setBudget(.init(month: CoveLedgerMonth(containing: october, calendar: calendar), overallFen: 5_000, categoryFen: [:]))
        let snapshot = try repository.load(), now = date("2026-10-17T00:00:00Z")
        let text = try snapshot.assistantSummary(asOf: now, calendar: calendar)
        XCTAssertEqual(text, try snapshot.assistantSummary(asOf: now, calendar: calendar))
        XCTAssertTrue(text.contains("2026-10-17T08:00:00+08:00")); XCTAssertTrue(text.contains("Asia/Shanghai"))
        XCTAssertTrue(text.contains("2026-10-20")); XCTAssertTrue(text.contains("剩余 ¥8.00"))
        XCTAssertTrue(text.contains("未知余额账户")); XCTAssertTrue(text.contains("预算 ¥50.00"))
        XCTAssertTrue(text.contains("收入 ¥0.00，支出 ¥0.00"))
        XCTAssertFalse(text.contains("秘密商户")); XCTAssertFalse(text.contains("私人备注"))
        XCTAssertFalse(text.contains("不应分享")); XCTAssertFalse(text.contains("合成测试"))
        XCTAssertFalse(text.contains(bill.id.uuidString))
    }

    func testMalformedV2MissingFieldsAndFutureArchiveStayFailClosed() throws {
        let (_, card) = try typedAccounts(); try repository.appendStatement(statement(card.id))
        let snapshot = try repository.load()
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        for key in ["reconciliations", "statements"] {
            var broken = base; broken.removeValue(forKey: key)
            XCTAssertThrowsError(try JSONDecoder().decode(CoveLedgerSnapshot.self, from: JSONSerialization.data(withJSONObject: broken)))
        }
        var broken = base
        broken["accounts"] = snapshot.accounts.map { ["id": $0.id.uuidString, "name": $0.name, "type": "futureType"] }
        XCTAssertThrowsError(try JSONDecoder().decode(CoveLedgerSnapshot.self, from: JSONSerialization.data(withJSONObject: broken)))
    }

    func testEmptyTotalsAndStandaloneLegacyAccountDecodeDoNotInventZero() throws {
        let empty = try CoveLedgerSnapshot().financeOverview(asOf: october, calendar: calendar)
        XCTAssertNil(empty.liquid.totalFen); XCTAssertNil(empty.cardDebt.totalFen)
        XCTAssertNil(empty.liquidAfterRecordedDuesFen)
        let json = try JSONSerialization.data(withJSONObject: ["id": account.id.uuidString, "name": account.name])
        let decoded = try JSONDecoder().decode(CoveLedgerAccount.self, from: json)
        XCTAssertEqual(decoded.type, .unclassified); XCTAssertEqual(decoded.id, account.id)
        let snapshot = try repository.load()
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        archive["accounts"] = snapshot.accounts.map { ["id": $0.id.uuidString, "name": $0.name] }
        XCTAssertThrowsError(try JSONDecoder().decode(CoveLedgerSnapshot.self, from: JSONSerialization.data(withJSONObject: archive)),
                             "A v2 account must have an explicit type even though standalone v1 accounts remain readable.")
    }

    func testDueSoonAcrossDSTIsSevenCalendarDaysNot168Hours() throws {
        let (_, card) = try typedAccounts()
        var la = calendar; la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let bill = CoveLedgerStatement(id: UUID(), accountID: card.id,
            statementDate: date("2026-03-01T08:00:00Z"), dueDate: date("2026-03-09T07:00:00Z"),
            amountFen: 100, minimumDueFen: nil, createdAt: date("2026-03-01T08:00:00Z"), supersedesID: nil)
        try repository.appendStatement(bill)
        XCTAssertEqual(try overview(date("2026-03-02T07:59:59Z"), zone: la).statements.first?.status, .upcoming)
        XCTAssertEqual(try overview(date("2026-03-02T08:00:00Z"), zone: la).statements.first?.status, .dueSoon)
        XCTAssertEqual(try overview(date("2026-03-10T06:59:59Z"), zone: la).statements.first?.status, .dueSoon)
        XCTAssertEqual(try overview(date("2026-03-10T07:00:00Z"), zone: la).statements.first?.status, .overdue)
    }

    func testConcurrentStatementCorrectionsCannotForkEffectiveBill() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let first = CoveLedgerRepository(directoryURL: directory); try seed(first)
        try first.saveAccount(id: destination.id, name: destination.name, type: .creditCard)
        let second = CoveLedgerRepository(directoryURL: directory)
        let bill = statement(destination.id); try first.appendStatement(bill)
        let candidates = [statement(destination.id, amount: 900, supersedes: bill.id),
                          statement(destination.id, amount: 800, supersedes: bill.id)]
        let lock = NSLock(); var accepted: [UUID] = [], rejected: [CoveLedgerError] = []
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                try (index == 0 ? first : second).appendStatement(candidates[index])
                lock.lock(); accepted.append(candidates[index].id); lock.unlock()
            } catch {
                lock.lock(); if let error = error as? CoveLedgerError { rejected.append(error) }; lock.unlock()
            }
        }
        XCTAssertEqual(accepted.count, 1); XCTAssertEqual(rejected, [.invalidStatement])
        XCTAssertEqual(try first.load().effectiveStatements.map(\.id), accepted)
        XCTAssertEqual(try second.load().statements.count, 2)
    }

    func testInt64MinimumDerivedLiquidCanBeDisplayedButCannotSubtractAnotherFen() throws {
        let (liquid, card) = try typedAccounts()
        let other = try repository.saveAccount(name: "另一个合成转入账户")
        try anchor(liquid.id, 0)
        try repository.append(event(repayment(card.id, amount: Int64.max)))
        try repository.append(event(repayment(other.id, amount: 1)))
        let result = try overview()
        XCTAssertEqual(result.liquid.totalFen, Int64.min)
        XCTAssertEqual(result.liquidAfterRecordedDuesFen, Int64.min)
        let text = try repository.load().assistantSummary(asOf: date("2026-10-17T00:00:00Z"), calendar: calendar)
        XCTAssertTrue(text.contains("-92233720368547758.08"))
        let before = try repository.load()
        XCTAssertThrowsError(try repository.appendStatement(statement(card.id, amount: 1))) {
            XCTAssertEqual($0 as? CoveLedgerError, .overflow)
        }
        XCTAssertEqual(try repository.load(), before)
    }

    func testCorrectionDateCannotReinterpretEarlierLinkedPayment() throws {
        let (_, card) = try typedAccounts()
        let bill = statement(card.id); try repository.appendStatement(bill)
        try repository.append(event(repayment(card.id, amount: 100, statementID: bill.id)))
        let invalid = CoveLedgerStatement(id: UUID(), accountID: card.id,
            statementDate: date("2026-10-17T00:00:00Z"), dueDate: date("2026-10-20T00:00:00Z"),
            amountFen: 1_000, minimumDueFen: nil, createdAt: date("2026-10-17T00:00:00Z"), supersedesID: bill.id)
        XCTAssertThrowsError(try repository.appendStatement(invalid))
        XCTAssertEqual(try repository.load().effectiveStatements, [bill])
        let futureCreated = CoveLedgerStatement(id: UUID(), accountID: card.id, statementDate: october,
            dueDate: october, amountFen: 100, minimumDueFen: nil, createdAt: october.addingTimeInterval(-1), supersedesID: nil)
        XCTAssertThrowsError(try repository.appendStatement(futureCreated))
    }

    // MARK: Installments — all data below is synthetic, never shared.

    private func plan(_ card: UUID, id: UUID = UUID(), replacing old: CoveLedgerInstallment? = nil,
                      periods: Int64 = 3, remaining: Int64? = nil, principal: Int64 = 10_001,
                      interest: Int64 = 99, repeats: Bool = false, due: Date? = nil,
                      created: Date? = nil, label: String? = "私密分期商户名称") -> CoveLedgerInstallment {
        .init(id: id, planID: old?.planID, accountID: card, label: label, remainingPeriods: periods,
              remainingPrincipalFen: remaining, nextPrincipalFen: principal, nextInterestFen: interest,
              nextDueDate: due ?? date("2026-10-20T00:00:00Z"), amountsRepeat: repeats,
              supersedesID: old?.id, createdAt: created ?? october)
    }

    func testInstallmentExactAdditionAndZeroInterest() throws {
        let (_, card) = try typedAccounts()
        let first = plan(card.id)
        XCTAssertFalse(first.amountsRepeat)
        XCTAssertEqual(try first.nextTotalFen(), 10_100)
        try repository.appendInstallment(first)
        let zeroInterest = plan(card.id, principal: 1, interest: 0)
        try repository.appendInstallment(zeroInterest)
        let feeOnly = plan(card.id, principal: 0, interest: 1)
        try repository.appendInstallment(feeOnly)
        XCTAssertEqual(try overview().installments.nextTotalFen, 10_102)
        XCTAssertEqual(try zeroInterest.nextTotalFen(), 1)
    }

    func testInstallmentUnknownPrincipalIsNotZeroEvenWhenProjectionIsKnown() throws {
        let (_, card) = try typedAccounts()
        let unknown = plan(card.id, remaining: nil, repeats: true)
        let zero = plan(card.id, remaining: 0, principal: 0, repeats: true)
        try repository.appendInstallment(unknown); try repository.appendInstallment(zero)
        let result = try overview().installments
        XCTAssertNil(result.remainingPrincipal.totalFen)
        XCTAssertEqual(result.remainingPrincipal.unknownPlanCount, 1)
        XCTAssertEqual(result.remainingPrincipal.knownSubtotalFen, 0)
        XCTAssertEqual(try unknown.projectedTotalFen(), 30_300)
        XCTAssertEqual(try zero.projectedTotalFen(), 297)
        XCTAssertEqual(result.projection.totalFen, 30_597)
        let snapshot = try repository.load()
        XCTAssertEqual(try JSONDecoder().decode(CoveLedgerSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
    }

    func testInstallmentFixedProjectionUsesProvidedPrincipalInsteadOfMultiplyingIt() throws {
        let (_, card) = try typedAccounts()
        let fixed = plan(card.id, periods: 5, remaining: 42_003, principal: 10_000, interest: 123, repeats: true)
        try repository.appendInstallment(fixed)
        XCTAssertEqual(try fixed.projectedTotalFen(), 42_618)
        XCTAssertEqual(try overview().installments.remainingPrincipal.totalFen, 42_003)
        XCTAssertEqual(try overview().installments.projection.totalFen, 42_618)
        // Multiplication of next principal would overflow, but it is not used when the bank supplied a total.
        let known = plan(card.id, periods: Int64.max, remaining: 1, principal: Int64.max, interest: 0, repeats: true)
        XCTAssertEqual(try known.projectedTotalFen(), 1)
    }

    func testInstallmentVariableAmountsExposeOnlyKnownSubtotals() throws {
        let (_, card) = try typedAccounts()
        let variable = plan(card.id, remaining: 20_000)
        let fixed = plan(card.id, periods: 2, remaining: 5_000, repeats: true)
        try repository.appendInstallment(variable); try repository.appendInstallment(fixed)
        XCTAssertNil(try variable.projectedTotalFen())
        let result = try overview().installments
        XCTAssertNil(result.projection.totalFen)
        XCTAssertEqual(result.projection.knownSubtotalFen, 5_198)
        XCTAssertEqual(result.projection.unknownPlanCount, 1)
        XCTAssertEqual(result.remainingPrincipal.totalFen, 25_000)
    }

    func testInstallmentNeverChangesDebtStatementDueOrLiquidAfterDues() throws {
        let (liquid, card) = try typedAccounts()
        try anchor(liquid.id, 100_000); try anchor(card.id, -20_000)
        let bill = statement(card.id, amount: 10_000); try repository.appendStatement(bill)
        try repository.append(event(repayment(card.id, amount: 3_000, statementID: bill.id)))
        let before = try overview()
        let installment = plan(card.id, repeats: true); try repository.appendInstallment(installment)
        let after = try overview()
        XCTAssertEqual(after.balances, before.balances)
        XCTAssertEqual(after.cardDebt, before.cardDebt)
        XCTAssertEqual(after.statements, before.statements)
        XCTAssertEqual(after.recordedOutstandingFen, 7_000)
        XCTAssertEqual(after.liquidAfterRecordedDuesFen, before.liquidAfterRecordedDuesFen)
        XCTAssertEqual(try summary().expenseFen, 0)
        try repository.appendInstallment(installment.closing(id: UUID(), createdAt: october))
        XCTAssertEqual(try overview().recordedOutstandingFen, 7_000)
        XCTAssertEqual(try overview().cardDebt, before.cardDebt)
    }

    func testInstallmentUpdateCloseAndRetriesPreserveAllRevisions() throws {
        let (_, card) = try typedAccounts()
        let original = plan(card.id); try repository.appendInstallment(original)
        let updated = plan(card.id, replacing: original, periods: 2, remaining: 15_000)
        try repository.appendInstallment(updated)
        XCTAssertEqual(try repository.load().effectiveInstallments, [updated])
        XCTAssertEqual(try repository.appendInstallment(original), original, "Old identical retry remains idempotent.")
        let closed = updated.closing(id: UUID(), createdAt: october)
        try repository.appendInstallment(closed)
        XCTAssertEqual(try repository.appendInstallment(closed), closed)
        XCTAssertEqual(try repository.appendInstallment(updated), updated)
        let snapshot = try repository.load()
        XCTAssertEqual(snapshot.installments, [original, updated, closed])
        XCTAssertTrue(snapshot.effectiveInstallments.isEmpty)
        XCTAssertEqual(try snapshot.installmentOverview().nextTotalFen, 0)
        XCTAssertThrowsError(try repository.appendInstallment(plan(card.id, replacing: closed)))
        XCTAssertThrowsError(try repository.appendInstallment(plan(card.id, replacing: original)))
        XCTAssertThrowsError(try repository.appendInstallment(plan(card.id, id: updated.id, replacing: original, periods: 1))) {
            XCTAssertEqual($0 as? CoveLedgerError, .operationConflict)
        }
    }

    func testInstallmentWrongAccountsAndIncompatibleReclassificationRejected() throws {
        XCTAssertThrowsError(try repository.appendInstallment(plan(account.id)))
        let (liquid, card) = try typedAccounts()
        for id in [liquid.id, UUID()] { XCTAssertThrowsError(try repository.appendInstallment(plan(id))) }
        let original = plan(card.id); try repository.appendInstallment(original)
        XCTAssertThrowsError(try repository.saveAccount(id: card.id, name: card.name, type: .bank))
        try repository.saveAccount(id: card.id, name: "只改名称")
        let other = try repository.saveAccount(name: "其他信用卡", type: .creditCard)
        XCTAssertThrowsError(try repository.appendInstallment(plan(other.id, replacing: original)))
        try repository.appendInstallment(original.closing(id: UUID(), createdAt: october))
        XCTAssertThrowsError(try repository.saveAccount(id: card.id, name: card.name, type: .bank),
                             "Like statements, immutable card history also constrains reclassification.")
    }

    func testInstallmentRejectsInvalidMoneyPeriodsNamesDatesAndLinks() throws {
        let (_, card) = try typedAccounts()
        let invalid = [plan(card.id, periods: 0), plan(card.id, periods: -1), plan(card.id, remaining: -1),
                       plan(card.id, principal: -1), plan(card.id, interest: -1), plan(card.id, principal: 0, interest: 0),
                       plan(card.id, principal: Int64.min), plan(card.id, label: ""), plan(card.id, label: " bad "),
                       plan(card.id, label: String(repeating: "字", count: 41)), plan(card.id, label: "a\u{0000}b"),
                       plan(card.id, due: Date(timeIntervalSinceReferenceDate: .infinity)),
                       plan(card.id, created: Date(timeIntervalSinceReferenceDate: .nan))]
        for item in invalid { XCTAssertThrowsError(try repository.appendInstallment(item)) }
        let missing = plan(card.id)
        XCTAssertThrowsError(try repository.appendInstallment(plan(card.id, replacing: missing)))
        XCTAssertThrowsError(try repository.appendInstallment(missing.closing(id: UUID(), createdAt: october)))
        XCTAssertTrue(try repository.load().installments.isEmpty)
        try repository.appendInstallment(missing)
        XCTAssertThrowsError(try repository.appendInstallment(plan(card.id, replacing: missing, created: october.addingTimeInterval(-1))))
        let wrongFamily = CoveLedgerInstallment(id: UUID(), planID: UUID(), accountID: card.id,
            remainingPeriods: 2, nextPrincipalFen: 1, nextInterestFen: 0, nextDueDate: october,
            supersedesID: missing.id, createdAt: october)
        XCTAssertThrowsError(try repository.appendInstallment(wrongFamily))
        // A past due date is a valid bank observation, never silently rolled into a future month.
        XCTAssertNoThrow(try repository.appendInstallment(plan(card.id, due: october.addingTimeInterval(-86_400))))
    }

    func testInstallmentOverflowChecksAdditionPrincipalInterestAndProjectionSum() throws {
        let (_, card) = try typedAccounts()
        let before = try repository.load()
        for item in [plan(card.id, principal: Int64.max, interest: 1),
                     plan(card.id, periods: 2, principal: Int64.max, interest: 0, repeats: true),
                     plan(card.id, periods: 2, principal: 0, interest: Int64.max, repeats: true),
                     plan(card.id, periods: 1, remaining: Int64.max, principal: 0, interest: 1, repeats: true)] {
            XCTAssertThrowsError(try repository.appendInstallment(item)) { XCTAssertEqual($0 as? CoveLedgerError, .overflow) }
            XCTAssertEqual(try repository.load(), before)
        }
        // Variable plans never perform a guessed multiplication, even at extreme period counts.
        try repository.appendInstallment(plan(card.id, periods: Int64.max, principal: Int64.max, interest: 0))
        let accepted = try repository.load()
        XCTAssertThrowsError(try repository.appendInstallment(plan(card.id, principal: 1, interest: 0)))
        XCTAssertEqual(try repository.load(), accepted, "Aggregate next-due overflow must be atomic.")
    }

    func testInstallmentAggregatePrincipalAndProjectionOverflowAreAtomic() throws {
        let (_, card) = try typedAccounts()
        let first = plan(card.id, remaining: Int64.max, principal: 1, interest: 0, repeats: true)
        try repository.appendInstallment(first)
        let before = try repository.load()
        XCTAssertThrowsError(try repository.appendInstallment(plan(card.id, remaining: 1, principal: 1, interest: 0)))
        XCTAssertThrowsError(try repository.appendInstallment(plan(card.id, periods: 1, principal: 1, interest: 0, repeats: true)))
        XCTAssertEqual(try repository.load(), before)
    }

    func testInstallmentIDsCannotCollideWithOtherRecordKindsInEitherDirection() throws {
        let (liquid, card) = try typedAccounts()
        let original = plan(card.id); try repository.appendInstallment(original)
        XCTAssertThrowsError(try anchor(liquid.id, 0, operationID: original.id))
        XCTAssertThrowsError(try repository.appendStatement(statement(card.id, id: original.id)))
        XCTAssertThrowsError(try repository.append(event(transaction(), id: original.id)))
        let observed = try anchor(liquid.id, 0)
        let bill = statement(card.id); try repository.appendStatement(bill)
        let entry = event(transaction()); try repository.append(entry)
        for id in [observed.id, bill.id, entry.id] {
            XCTAssertThrowsError(try repository.appendInstallment(plan(card.id, id: id))) {
                XCTAssertEqual($0 as? CoveLedgerError, .operationConflict)
            }
        }
    }

    func testExistingSchema2WithoutInstallmentKeyDecodesEmptyAndNullFailsClosed() throws {
        let (_, card) = try typedAccounts(); try repository.appendStatement(statement(card.id))
        let snapshot = try repository.load()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        json.removeValue(forKey: "installments")
        let decoded = try JSONDecoder().decode(CoveLedgerSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded, snapshot); XCTAssertTrue(decoded.installments.isEmpty)
        for invalid: Any in [NSNull(), "invalid", [:]] {
            json["installments"] = invalid
            XCTAssertThrowsError(try JSONDecoder().decode(CoveLedgerSnapshot.self, from: JSONSerialization.data(withJSONObject: json)))
        }
    }

    func testForgedInstallmentArchiveCannotOverwriteDisk() throws {
        let (_, card) = try typedAccounts()
        let original = plan(card.id); try repository.appendInstallment(original)
        let updated = plan(card.id, replacing: original)
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("ledger-v1.json")
        for revisions in [[original, original], [updated, original],
                          [original, updated, plan(card.id, replacing: original)],
                          [original.closing(id: UUID(), createdAt: october)]] {
            var snapshot = try repository.load(); snapshot.installments = revisions
            let bytes = try JSONEncoder().encode(snapshot); try bytes.write(to: file)
            let disk = CoveLedgerRepository(directoryURL: directory)
            XCTAssertThrowsError(try disk.load())
            XCTAssertThrowsError(try disk.appendInstallment(plan(card.id)))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testInstallmentSortingAndDateFormattingAreDeterministic() throws {
        let (_, card) = try typedAccounts()
        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let high = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let due = date("2026-10-19T16:00:00Z")
        let one = plan(card.id, id: low, due: due), two = plan(card.id, id: high, due: due)
        let later = plan(card.id, due: due.addingTimeInterval(1))
        for item in [later, two, one] { try repository.appendInstallment(item) }
        let snapshot = try repository.load()
        XCTAssertEqual(try snapshot.installmentOverview().plans, [one, two, later])
        XCTAssertEqual(try snapshot.installmentOverview().nearest, one)
        var reversed = snapshot; reversed.installments.reverse()
        XCTAssertEqual(try snapshot.assistantSummary(asOf: october, calendar: calendar),
                       try reversed.assistantSummary(asOf: october, calendar: calendar))
        XCTAssertTrue(try snapshot.assistantSummary(asOf: october, calendar: calendar).contains("到期 2026-10-20"))
        var utc = calendar; utc.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertTrue(try snapshot.assistantSummary(asOf: october, calendar: utc).contains("到期 2026-10-19"))
    }

    func testInstallmentPrivacySummaryIncludesSplitNumbersButNoLabelOrHistory() throws {
        let (_, card) = try typedAccounts()
        let old = plan(card.id, principal: 87_654_321); try repository.appendInstallment(old)
        let current = plan(card.id, replacing: old, periods: 2, remaining: 20_000, principal: 10_000,
                           interest: 123, repeats: true)
        try repository.appendInstallment(current)
        try repository.appendInstallment(plan(card.id, remaining: nil))
        let text = try repository.load().assistantSummary(asOf: october, calendar: calendar)
        for expected in ["下期本金 ¥100.00", "利息/手续费 ¥1.23", "合计 ¥101.23", "全部剩余预测 ¥202.46",
                         "剩余 2 期", "1 个分期未知", "不计入当前账单或欠款"] { XCTAssertTrue(text.contains(expected), expected) }
        for excluded in ["私密分期", "商户", "876543.21", old.id.uuidString, current.id.uuidString, card.name] {
            XCTAssertFalse(text.contains(excluded), excluded)
        }
    }

    func testInstallmentConcurrentDiskRetriesAndCompetingUpdatesCannotFork() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let first = CoveLedgerRepository(directoryURL: directory)
        let card = try first.saveAccount(name: "合成信用卡", type: .creditCard)
        let second = CoveLedgerRepository(directoryURL: directory)
        let original = plan(card.id)
        let lock = NSLock(); var failures: [String] = []
        DispatchQueue.concurrentPerform(iterations: 20) { i in
            do { try (i % 2 == 0 ? first : second).appendInstallment(original) }
            catch { lock.lock(); failures.append(error.localizedDescription); lock.unlock() }
        }
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(try second.load().installments, [original])
        let candidates = [plan(card.id, replacing: original, periods: 2), original.closing(id: UUID(), createdAt: october)]
        var accepted: [UUID] = [], rejected: [CoveLedgerError] = []
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            do {
                try (i == 0 ? first : second).appendInstallment(candidates[i])
                lock.lock(); accepted.append(candidates[i].id); lock.unlock()
            } catch {
                lock.lock(); if let error = error as? CoveLedgerError { rejected.append(error) }; lock.unlock()
            }
        }
        XCTAssertEqual(accepted.count, 1); XCTAssertEqual(rejected, [.invalidInstallment])
        let result = try CoveLedgerRepository(directoryURL: directory).load()
        XCTAssertEqual(result.installments.count, 2); XCTAssertEqual(result.installments.first, original)
        let winner = try XCTUnwrap(candidates.first { $0.id == accepted.first })
        XCTAssertEqual(try second.appendInstallment(winner), winner)
        XCTAssertEqual(try second.load(), result)
    }

    #if os(iOS)
    func testCompleteFileProtection() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let disk = CoveLedgerRepository(directoryURL: directory); try seed(disk)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("ledger-v1.json").path)
        let protection = attributes[.protectionKey]
        #if targetEnvironment(simulator)
        if protection == nil { throw XCTSkip("Simulator lacks file-protection metadata; device protection is not accepted by this test.") }
        #endif
        XCTAssertEqual((protection as? FileProtectionType)?.rawValue ?? protection as? String, FileProtectionType.complete.rawValue)
    }
    #endif
}

#if os(iOS)
@MainActor
final class CoveLedgerModelTests: XCTestCase {
    func testPreviewIsExplicitlyLabelledAndAlwaysInMemory() throws {
        let model = CoveLedgerModel.preview()
        XCTAssertTrue(model.isPreview)
        XCTAssertTrue(model.repository.isInMemory)
        XCTAssertTrue(model.perform { try model.repository.saveAccount(name: "预览示例账户") })
        XCTAssertEqual(model.snapshot?.accounts.count, 1)
        XCTAssertTrue(CoveLedgerModel.preview().snapshot?.accounts.isEmpty == true)
    }

    func testReadFailureDoesNotPresentZeroSnapshotOrAllowMutation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CoveLedgerModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ledger-v1.json")
        try Data("corrupt".utf8).write(to: file)
        let model = CoveLedgerModel(repository: CoveLedgerRepository(directoryURL: directory))
        XCTAssertNil(model.snapshot)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.perform { try model.repository.saveAccount(name: "不可覆盖") })
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "corrupt")
    }
}
#endif
