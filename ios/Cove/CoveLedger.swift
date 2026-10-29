import Foundation

// Personal, device-local records. No service, payment, model-tool or virtual-money dependencies.
enum CoveLedgerError: LocalizedError, Equatable {
    case invalidAmount, overflow, invalidName, duplicateName, missingAccount, invalidCategory
    case sameAccount, invalidLink, operationConflict, invalidArchive, unsupportedSchema, invalidDate, textTooLong
    case invalidAccountType, invalidStatement, invalidInstallment

    var errorDescription: String? {
        switch self {
        case .invalidAccountType: return "账户类型不适用；已有余额核对、信用卡账单或分期的账户不能改成不兼容的类型。"
        case .invalidInstallment: return "请核对分期期数、本金、利息和更新关联；下期合计须大于零。"
        case .invalidStatement: return "账单金额、最低应还、日期或替代关联无效。"
        case .invalidAmount: return "请输入大于零的金额，最多两位小数。"
        case .overflow: return "金额或合计超出可记录范围。"
        case .invalidName: return "名称不能为空，最多 40 字，不能包含控制字符。"
        case .duplicateName: return "已有同名账户或分类，请换一个名称。"
        case .missingAccount: return "请选择有效账户。"
        case .invalidCategory: return "请选择与收支类型一致的分类。"
        case .sameAccount: return "转出与转入账户不能相同。"
        case .invalidLink: return "原记录不存在、已被冲销，或不是可更正的记录。"
        case .operationConflict: return "这次操作的编号已用于不同内容，未重复记账。"
        case .invalidArchive: return "本机账本无法通过校验；原文件已保留，不会用空账本覆盖。"
        case .unsupportedSchema: return "账本版本暂不支持，请使用兼容版本打开。"
        case .invalidDate: return "日期或月份无效。"
        case .textTooLong: return "备注和更正原因各自最多 2,000 字。"
        }
    }
}

enum CoveLedgerMoney {
    /// Strict, exact decimal input. Group separators, signs, exponents and rounding are not accepted.
    /// Decimal keypad separators and localized decimal digits are supported.
    static func parse(_ input: String, locale: Locale = .current, allowZero: Bool = false) throws -> Int64 {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 32 else { throw CoveLedgerError.invalidAmount }
        let separator = locale.decimalSeparator ?? "."
        let pieces = text.components(separatedBy: separator)
        guard pieces.count <= 2, !pieces[0].isEmpty,
              pieces.count == 1 || (1...2).contains(pieces[1].count) else { throw CoveLedgerError.invalidAmount }
        func digits(_ value: String) throws -> Int64 {
            var result: Int64 = 0
            for character in value {
                guard character.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }),
                      let digit = character.wholeNumberValue, (0...9).contains(digit) else {
                    throw CoveLedgerError.invalidAmount
                }
                let product = result.multipliedReportingOverflow(by: 10)
                let sum = product.partialValue.addingReportingOverflow(Int64(digit))
                guard !product.overflow, !sum.overflow else { throw CoveLedgerError.overflow }
                result = sum.partialValue
            }
            return result
        }
        let whole = try digits(pieces[0])
        let fraction = pieces.count == 2 ? try digits(pieces[1]) * (pieces[1].count == 1 ? 10 : 1) : 0
        let product = whole.multipliedReportingOverflow(by: 100)
        guard !product.overflow else { throw CoveLedgerError.overflow }
        let result = try add(product.partialValue, fraction)
        guard result > 0 || (allowZero && result == 0) else { throw CoveLedgerError.invalidAmount }
        return result
    }

    static func display(_ fen: Int64, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = "CNY"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        // Decimal is base ten; neither money nor its formatting passes through binary floating point.
        let amount = NSDecimalNumber(decimal: Decimal(fen) / Decimal(100))
        return formatter.string(from: amount) ?? "CNY \(editable(fen, locale: locale))"
    }

    static func editable(_ fen: Int64, locale: Locale = .current) -> String {
        let magnitude = fen.magnitude
        let fraction = String(magnitude % 100)
        return "\(fen < 0 ? "-" : "")\(magnitude / 100)\(locale.decimalSeparator ?? ".")\(fraction.count == 1 ? "0" : "")\(fraction)"
    }

    static func multiply(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else { throw CoveLedgerError.overflow }
        return result.partialValue
    }

    static func add(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw CoveLedgerError.overflow }
        return result.partialValue
    }
}

enum CoveLedgerKind: String, Codable, CaseIterable, Identifiable {
    case expense, income, transfer
    var id: String { rawValue }
    var title: String {
        switch self { case .expense: return "支出"; case .income: return "收入"; case .transfer: return "转账" }
    }
}

enum CoveLedgerAccountType: String, Codable, CaseIterable, Identifiable {
    case unclassified, cash, bank, eWallet, creditCard
    var id: String { rawValue }
    var isLiquid: Bool { self == .cash || self == .bank || self == .eWallet }
    var title: String {
        switch self {
        case .unclassified: return "未分类"
        case .cash: return "现金"
        case .bank: return "银行卡 / 储蓄卡"
        case .eWallet: return "电子钱包"
        case .creditCard: return "信用卡"
        }
    }
}

struct CoveLedgerAccount: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let type: CoveLedgerAccountType

    init(id: UUID, name: String, type: CoveLedgerAccountType = .unclassified) {
        self.id = id; self.name = name; self.type = type
    }

    enum CodingKeys: String, CodingKey { case id, name, type }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        // Standalone v1 accounts remain readable. A v2 archive additionally requires this key.
        type = c.contains(.type) ? try c.decode(CoveLedgerAccountType.self, forKey: .type) : .unclassified
    }
}

enum CoveLedgerPreferredCreditAccounts {
    static let templates: [(id: UUID, name: String)] = [
        (UUID(uuidString: "C0DE0000-0000-4000-8000-000000000001")!, "交通银行"),
        (UUID(uuidString: "C0DE0000-0000-4000-8000-000000000002")!, "招商银行"),
        (UUID(uuidString: "C0DE0000-0000-4000-8000-000000000003")!, "花呗")
    ]

    static func displayName(for account: CoveLedgerAccount) -> String {
        for template in templates where account.name == template.name || account.name == template.name + "信用卡" {
            return template.name
        }
        return account.name
    }
}

/// Owner-observed signed balance, not an income/expense. Never updated in place.
struct CoveLedgerReconciliation: Codable, Equatable, Identifiable {
    let id: UUID
    let accountID: UUID
    let balanceFen: Int64 // Liquid >= 0; credit-card debt <= 0. Zero is an explicit observation.
    let capturedAt: Date
    let createdAt: Date
}

struct CoveLedgerStatement: Codable, Equatable, Identifiable {
    let id: UUID
    let accountID: UUID
    let statementDate: Date
    let dueDate: Date
    let amountFen: Int64
    let minimumDueFen: Int64?
    let createdAt: Date
    let supersedesID: UUID?
}

/// An observation, never a posting. planID identifies one immutable revision chain.
struct CoveLedgerInstallment: Codable, Equatable, Identifiable {
    let id: UUID
    let planID: UUID
    let accountID: UUID
    let label: String?
    let remainingPeriods: Int64
    let remainingPrincipalFen: Int64?
    let nextPrincipalFen: Int64
    let nextInterestFen: Int64
    let nextDueDate: Date
    let amountsRepeat: Bool
    let supersedesID: UUID?
    let createdAt: Date
    let isClosed: Bool

    init(id: UUID, planID: UUID? = nil, accountID: UUID, label: String? = nil,
         remainingPeriods: Int64, remainingPrincipalFen: Int64? = nil,
         nextPrincipalFen: Int64, nextInterestFen: Int64, nextDueDate: Date,
         amountsRepeat: Bool = false, supersedesID: UUID? = nil, createdAt: Date, isClosed: Bool = false) {
        self.id = id; self.planID = planID ?? id; self.accountID = accountID; self.label = label
        self.remainingPeriods = remainingPeriods; self.remainingPrincipalFen = remainingPrincipalFen
        self.nextPrincipalFen = nextPrincipalFen; self.nextInterestFen = nextInterestFen
        self.nextDueDate = nextDueDate; self.amountsRepeat = amountsRepeat
        self.supersedesID = supersedesID; self.createdAt = createdAt; self.isClosed = isClosed
    }

    func nextTotalFen() throws -> Int64 { try CoveLedgerMoney.add(nextPrincipalFen, nextInterestFen) }

    func projectedTotalFen() throws -> Int64? {
        guard !isClosed, amountsRepeat else { return nil }
        let principal = try remainingPrincipalFen ?? CoveLedgerMoney.multiply(nextPrincipalFen, remainingPeriods)
        return try CoveLedgerMoney.add(principal, CoveLedgerMoney.multiply(nextInterestFen, remainingPeriods))
    }

    /// Close is an explicit tombstone, not a claim that a payment happened.
    func closing(id: UUID, createdAt: Date) -> Self {
        .init(id: id, planID: planID, accountID: accountID, label: label, remainingPeriods: 0,
              nextPrincipalFen: 0, nextInterestFen: 0, nextDueDate: nextDueDate,
              supersedesID: self.id, createdAt: createdAt, isClosed: true)
    }
}

struct CoveLedgerInstallmentTotal: Equatable {
    let knownSubtotalFen: Int64
    let unknownPlanCount: Int
    var totalFen: Int64? { unknownPlanCount == 0 ? knownSubtotalFen : nil }
}

struct CoveLedgerInstallmentOverview {
    let plans: [CoveLedgerInstallment]
    let nextTotalFen: Int64
    let remainingPrincipal: CoveLedgerInstallmentTotal
    let projection: CoveLedgerInstallmentTotal
    var nearest: CoveLedgerInstallment? { plans.first }
}

enum CoveLedgerDueStatus: String {
    case overdue, dueSoon, upcoming, paid
    var title: String {
        switch self {
        case .overdue: return "已逾期"
        case .dueSoon: return "即将到期"
        case .upcoming: return "待还"
        case .paid: return "已还清"
        }
    }
}

struct CoveLedgerStatementStatus: Identifiable, Equatable {
    let statement: CoveLedgerStatement
    let paidFen: Int64 // Applied to this bill, capped at its amount; excess is not another bill's payment.
    let remainingFen: Int64
    let status: CoveLedgerDueStatus
    var id: UUID { statement.id }
}

struct CoveLedgerKnownTotal: Equatable {
    let knownSubtotalFen: Int64
    let unknownAccountCount: Int
    let accountCount: Int
    var totalFen: Int64? { accountCount > 0 && unknownAccountCount == 0 ? knownSubtotalFen : nil }
}

struct CoveLedgerFinanceOverview {
    let asOf: Date
    let balances: [UUID: Int64] // Missing key = unknown, never inferred from net movement.
    let liquid: CoveLedgerKnownTotal
    let cardDebt: CoveLedgerKnownTotal
    let unclassifiedAccountCount: Int
    let statements: [CoveLedgerStatementStatus]
    let recordedOutstandingFen: Int64
    let liquidAfterRecordedDuesFen: Int64?
    let installments: CoveLedgerInstallmentOverview
    var nearestOutstanding: CoveLedgerStatementStatus? { statements.first { $0.remainingFen > 0 } }
}

struct CoveLedgerCategory: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let kind: CoveLedgerKind
}

struct CoveLedgerTransaction: Codable, Equatable {
    let kind: CoveLedgerKind
    let amountFen: Int64 // Positive magnitude. The postings below carry signed integer fen.
    let accountID: UUID
    let destinationAccountID: UUID?
    let categoryID: UUID?
    let note: String
    let occurredAt: Date
    var statementID: UUID? = nil // Legacy entries decode nil; only an explicitly linked card transfer pays a bill.

    var postings: [CoveLedgerPosting] {
        guard amountFen > 0 else { return [] } // Invalid decoded drafts must not trap on Int64.min.
        switch kind {
        case .expense: return [.init(accountID: accountID, amountFen: -amountFen)]
        case .income: return [.init(accountID: accountID, amountFen: amountFen)]
        case .transfer:
            guard let destinationAccountID else { return [] }
            return [.init(accountID: accountID, amountFen: -amountFen),
                    .init(accountID: destinationAccountID, amountFen: amountFen)]
        }
    }
}

struct CoveLedgerPosting: Equatable {
    let accountID: UUID
    let amountFen: Int64
}

/// One accepted operation: an original entry, a linked void, or an atomic reversal + replacement.
/// Corrections restate the original occurrence month, not the month in which the button was tapped.
/// createdAt preserves when the correction actually happened. Accepted events are never edited.
struct CoveLedgerEvent: Codable, Equatable, Identifiable {
    let id: UUID // Stable operation ID; callers retain it across retry.
    let transaction: CoveLedgerTransaction?
    let reversesID: UUID?
    let reason: String
    let createdAt: Date

    var title: String {
        reversesID == nil ? (transaction?.kind.title ?? "无效记录") : (transaction == nil ? "作废冲销" : "更正")
    }
}

struct CoveLedgerMonth: Codable, Hashable {
    let start: Date
    let end: Date
    let calendarIdentifier: String
    let timeZoneIdentifier: String

    init(containing date: Date, calendar: Calendar) throws {
        guard Self.isValidDate(date),
              let interval = calendar.dateInterval(of: .month, for: date), interval.duration > 0 else {
            throw CoveLedgerError.invalidDate
        }
        start = interval.start; end = interval.end
        calendarIdentifier = String(describing: calendar.identifier)
        timeZoneIdentifier = calendar.timeZone.identifier
    }

    func contains(_ date: Date) -> Bool { date >= start && date < end }

    fileprivate static func isValidDate(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite && date >= .distantPast && date <= .distantFuture
    }

    fileprivate func validate() throws {
        let identifiers: [Calendar.Identifier] = [.gregorian, .buddhist, .chinese, .coptic, .ethiopicAmeteMihret,
            .ethiopicAmeteAlem, .hebrew, .iso8601, .indian, .islamic, .islamicCivil, .japanese, .persian,
            .republicOfChina, .islamicTabular, .islamicUmmAlQura]
        guard let identifier = identifiers.first(where: { String(describing: $0) == calendarIdentifier }),
              let zone = TimeZone(identifier: timeZoneIdentifier) else { throw CoveLedgerError.invalidDate }
        var calendar = Calendar(identifier: identifier); calendar.timeZone = zone
        guard try CoveLedgerMonth(containing: start, calendar: calendar) == self else { throw CoveLedgerError.invalidDate }
    }
}

struct CoveLedgerBudget: Codable, Equatable {
    let month: CoveLedgerMonth
    let overallFen: Int64? // nil is unconfigured; a deliberately configured zero is valid.
    let categoryFen: [UUID: Int64]
}

struct CoveLedgerCategoryTotal: Identifiable, Equatable {
    let id: UUID
    let amountFen: Int64
    let budgetFen: Int64?
}

struct CoveLedgerSummary {
    let month: CoveLedgerMonth
    let expenseFen: Int64
    let incomeFen: Int64
    let budgetFen: Int64?
    let availableBudgetFen: Int64?
    let categories: [CoveLedgerCategoryTotal]
    let recentEntries: [CoveLedgerEvent]
}

struct CoveLedgerSnapshot: Codable, Equatable {
    static let currentSchemaVersion = 2
    var schemaVersion = currentSchemaVersion
    var accounts: [CoveLedgerAccount] = []
    var categories: [CoveLedgerCategory] = []
    var events: [CoveLedgerEvent] = []
    var budgets: [CoveLedgerBudget] = []
    var reconciliations: [CoveLedgerReconciliation] = []
    var statements: [CoveLedgerStatement] = []
    var installments: [CoveLedgerInstallment] = []

    enum CodingKeys: String, CodingKey {
        case schemaVersion, accounts, categories, events, budgets, reconciliations, statements, installments
    }

    init(schemaVersion: Int = currentSchemaVersion) { self.schemaVersion = schemaVersion }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 || version == Self.currentSchemaVersion else { throw CoveLedgerError.unsupportedSchema }
        schemaVersion = Self.currentSchemaVersion
        categories = try c.decode([CoveLedgerCategory].self, forKey: .categories)
        events = try c.decode([CoveLedgerEvent].self, forKey: .events)
        budgets = try c.decode([CoveLedgerBudget].self, forKey: .budgets)
        if version == 1 {
            // v1 has no v2 data. Refuse a mislabelled archive rather than silently dropping liabilities.
            guard !c.contains(.reconciliations), !c.contains(.statements), !c.contains(.installments),
                  events.allSatisfy({ $0.transaction?.statementID == nil }) else { throw CoveLedgerError.invalidArchive }
            var accountValues = try c.nestedUnkeyedContainer(forKey: .accounts)
            while !accountValues.isAtEnd {
                let decoder = try accountValues.superDecoder()
                let fields = try decoder.container(keyedBy: CoveLedgerAccount.CodingKeys.self)
                guard !fields.contains(.type) else { throw CoveLedgerError.invalidArchive }
                accounts.append(try CoveLedgerAccount(from: decoder))
            }
        } else {
            var accountValues = try c.nestedUnkeyedContainer(forKey: .accounts)
            while !accountValues.isAtEnd {
                let decoder = try accountValues.superDecoder()
                let fields = try decoder.container(keyedBy: CoveLedgerAccount.CodingKeys.self)
                guard fields.contains(.type) else { throw CoveLedgerError.invalidArchive }
                accounts.append(try CoveLedgerAccount(from: decoder))
            }
            reconciliations = try c.decode([CoveLedgerReconciliation].self, forKey: .reconciliations)
            statements = try c.decode([CoveLedgerStatement].self, forKey: .statements)
            // Only absence is legacy compatibility; null/malformed collections still fail closed.
            installments = c.contains(.installments) ? try c.decode([CoveLedgerInstallment].self, forKey: .installments) : []
        }
        self = try validated()
    }

    func accountName(_ id: UUID) -> String { accounts.first { $0.id == id }?.name ?? "未知账户" }
    func categoryName(_ id: UUID?) -> String { categories.first { $0.id == id }?.name ?? "转账" }
    func reversal(of id: UUID) -> CoveLedgerEvent? { events.first { $0.reversesID == id } }

    var effectiveEntries: [CoveLedgerEvent] {
        let reversed = Set(events.compactMap(\.reversesID))
        return events.filter { $0.transaction != nil && !reversed.contains($0.id) }
    }

    func postings(for event: CoveLedgerEvent) throws -> [CoveLedgerPosting] {
        var result: [CoveLedgerPosting] = []
        if let target = event.reversesID {
            guard let original = events.first(where: { $0.id == target })?.transaction else {
                throw CoveLedgerError.invalidLink
            }
            result += original.postings.map { .init(accountID: $0.accountID, amountFen: -$0.amountFen) }
        }
        result += event.transaction?.postings ?? []
        return result
    }

    /// Recorded net movement, NOT a bank balance (there is no imported/opening balance).
    func accountMovements() throws -> [UUID: Int64] {
        var result = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, Int64(0)) })
        for event in effectiveEntries {
            for posting in event.transaction?.postings ?? [] {
                result[posting.accountID] = try CoveLedgerMoney.add(result[posting.accountID] ?? 0, posting.amountFen)
            }
        }
        return result
    }

    func summary(containing date: Date, calendar: Calendar, recentLimit: Int = 5) throws -> CoveLedgerSummary {
        let month = try CoveLedgerMonth(containing: date, calendar: calendar)
        let budget = budgets.first { $0.month == month }
        var expense: Int64 = 0, income: Int64 = 0
        var totals: [UUID: Int64] = [:]
        for event in effectiveEntries {
            guard let transaction = event.transaction, month.contains(transaction.occurredAt) else { continue }
            switch transaction.kind {
            case .expense:
                expense = try CoveLedgerMoney.add(expense, transaction.amountFen)
                if let id = transaction.categoryID {
                    totals[id] = try CoveLedgerMoney.add(totals[id] ?? 0, transaction.amountFen)
                }
            case .income: income = try CoveLedgerMoney.add(income, transaction.amountFen)
            case .transfer: break
            }
        }
        for id in budget?.categoryFen.keys.map({ $0 }) ?? [] { if totals[id] == nil { totals[id] = 0 } }
        var categoryTotals: [CoveLedgerCategoryTotal] = []
        for (id, amount) in totals {
            categoryTotals.append(CoveLedgerCategoryTotal(id: id, amountFen: amount, budgetFen: budget?.categoryFen[id]))
        }
        categoryTotals.sort {
            if $0.amountFen == $1.amountFen { return $0.id.uuidString < $1.id.uuidString }
            return $0.amountFen > $1.amountFen
        }
        let recent = events.filter { event in
            if let transaction = event.transaction, month.contains(transaction.occurredAt) { return true }
            if let target = event.reversesID, let original = events.first(where: { $0.id == target })?.transaction {
                return month.contains(original.occurredAt)
            }
            return false
        }.sorted(by: Self.newestFirst)
        return CoveLedgerSummary(month: month, expenseFen: expense, incomeFen: income,
            budgetFen: budget?.overallFen, availableBudgetFen: try budget?.overallFen.map { try CoveLedgerMoney.add($0, -expense) },
            categories: categoryTotals, recentEntries: Array(recent.prefix(max(0, recentLimit))))
    }

    static func newestFirst(_ lhs: CoveLedgerEvent, _ rhs: CoveLedgerEvent) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    fileprivate static func name(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 40,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CoveLedgerError.invalidName
        }
        return value
    }

    fileprivate func validateTransaction(_ transaction: CoveLedgerTransaction) throws {
        guard transaction.amountFen > 0 else { throw CoveLedgerError.invalidAmount }
        guard CoveLedgerMonth.isValidDate(transaction.occurredAt) else { throw CoveLedgerError.invalidDate }
        guard transaction.note.count <= 2_000 else { throw CoveLedgerError.textTooLong }
        guard accounts.contains(where: { $0.id == transaction.accountID }) else { throw CoveLedgerError.missingAccount }
        if let statementID = transaction.statementID {
            guard transaction.kind == .transfer,
                  let statement = statements.first(where: { $0.id == statementID }),
                  transaction.destinationAccountID == statement.accountID,
                  accounts.first(where: { $0.id == statement.accountID })?.type == .creditCard,
                  transaction.occurredAt >= statement.statementDate else { throw CoveLedgerError.invalidStatement }
        }
        if transaction.kind == .transfer {
            guard let destination = transaction.destinationAccountID,
                  accounts.contains(where: { $0.id == destination }) else { throw CoveLedgerError.missingAccount }
            guard destination != transaction.accountID else { throw CoveLedgerError.sameAccount }
            guard transaction.categoryID == nil else { throw CoveLedgerError.invalidCategory }
        } else {
            guard transaction.destinationAccountID == nil,
                  categories.contains(where: { $0.id == transaction.categoryID && $0.kind == transaction.kind }) else {
                throw CoveLedgerError.invalidCategory
            }
        }
    }

    fileprivate func validateNewEvent(_ event: CoveLedgerEvent) throws {
        guard !reconciliations.contains(where: { $0.id == event.id }),
              !statements.contains(where: { $0.id == event.id }),
              !installments.contains(where: { $0.id == event.id }) else { throw CoveLedgerError.operationConflict }
        guard CoveLedgerMonth.isValidDate(event.createdAt) else { throw CoveLedgerError.invalidDate }
        guard event.reason.count <= 2_000 else { throw CoveLedgerError.textTooLong }
        if let target = event.reversesID {
            guard target != event.id, let original = events.first(where: { $0.id == target }),
                  original.transaction != nil, reversal(of: target) == nil,
                  !event.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CoveLedgerError.invalidLink
            }
        } else if event.transaction == nil { throw CoveLedgerError.invalidLink }
        if let transaction = event.transaction { try validateTransaction(transaction) }
    }

    fileprivate func validateTotals() throws {
        _ = try accountMovements()
        // Derived values are checked, never allowed to wrap or trap at signed boundaries.
        _ = try financeOverview(asOf: .distantFuture, calendar: Calendar(identifier: .gregorian))
        // Bound gross effective income and expense as well as individual account movements.
        // This ensures any calendar/time-zone subset can be summarized without overflow.
        for kind in [CoveLedgerKind.expense, .income] {
            var sum: Int64 = 0
            for event in effectiveEntries where event.transaction?.kind == kind {
                sum = try CoveLedgerMoney.add(sum, event.transaction!.amountFen)
            }
        }
    }

    fileprivate func validated() throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion else { throw CoveLedgerError.unsupportedSchema }
        guard Set(accounts.map(\.id)).count == accounts.count,
              Set(categories.map(\.id)).count == categories.count,
              Set(events.map(\.id)).count == events.count,
              Set(budgets.map(\.month)).count == budgets.count,
              Set(events.map(\.id) + reconciliations.map(\.id) + statements.map(\.id) + installments.map(\.id)).count
                == events.count + reconciliations.count + statements.count + installments.count else { throw CoveLedgerError.invalidArchive }
        var accountNames = Set<String>(), categoryNames = Set<String>()
        for account in accounts {
            let name = try Self.name(account.name)
            guard name == account.name, accountNames.insert(name.lowercased()).inserted else { throw CoveLedgerError.duplicateName }
        }
        for category in categories {
            let name = try Self.name(category.name)
            guard category.kind != .transfer, name == category.name,
                  categoryNames.insert(category.kind.rawValue + ":" + name.lowercased()).inserted else {
                throw CoveLedgerError.invalidCategory
            }
        }
        for reconciliation in reconciliations { try validateReconciliation(reconciliation) }
        var statementReplay = self; statementReplay.statements = []
        for statement in statements {
            try statementReplay.validateStatement(statement)
            statementReplay.statements.append(statement)
        }
        var installmentReplay = self; installmentReplay.installments = []
        for installment in installments {
            try installmentReplay.validateInstallment(installment)
            installmentReplay.installments.append(installment)
        }
        var replay = self; replay.events = []
        for event in events { try replay.validateNewEvent(event); replay.events.append(event) }
        try validateTotals()
        for budget in budgets { try validateBudget(budget) }
        return self
    }

    fileprivate func validateBudget(_ budget: CoveLedgerBudget) throws {
        try budget.month.validate()
        guard budget.overallFen.map({ $0 >= 0 }) ?? true,
              budget.categoryFen.values.allSatisfy({ $0 >= 0 }) else { throw CoveLedgerError.invalidAmount }
        for id in budget.categoryFen.keys {
            guard categories.contains(where: { $0.id == id && $0.kind == .expense }) else { throw CoveLedgerError.invalidCategory }
        }
    }
}

extension CoveLedgerSnapshot {
    var effectiveInstallments: [CoveLedgerInstallment] {
        let replaced = Set(installments.compactMap(\.supersedesID))
        return installments.filter { !$0.isClosed && !replaced.contains($0.id) }.sorted {
            $0.nextDueDate == $1.nextDueDate ? $0.id.uuidString < $1.id.uuidString : $0.nextDueDate < $1.nextDueDate
        }
    }

    fileprivate func validateInstallment(_ value: CoveLedgerInstallment) throws {
        guard accounts.first(where: { $0.id == value.accountID })?.type == .creditCard else {
            throw CoveLedgerError.invalidAccountType
        }
        guard !events.contains(where: { $0.id == value.id }),
              !reconciliations.contains(where: { $0.id == value.id }),
              !statements.contains(where: { $0.id == value.id }),
              !installments.contains(where: { $0.id == value.id }) else { throw CoveLedgerError.operationConflict }
        if let label = value.label {
            guard try Self.name(label) == label else { throw CoveLedgerError.invalidName }
        }
        guard CoveLedgerMonth.isValidDate(value.nextDueDate), CoveLedgerMonth.isValidDate(value.createdAt) else {
            throw CoveLedgerError.invalidDate
        }
        if let target = value.supersedesID {
            guard let old = effectiveInstallments.first(where: { $0.id == target }),
                  old.accountID == value.accountID, old.planID == value.planID,
                  value.createdAt >= old.createdAt else { throw CoveLedgerError.invalidInstallment }
            if value.isClosed {
                guard value == old.closing(id: value.id, createdAt: value.createdAt) else { throw CoveLedgerError.invalidInstallment }
                return
            }
        } else {
            guard !value.isClosed, value.planID == value.id,
                  !installments.contains(where: { $0.planID == value.planID }) else { throw CoveLedgerError.invalidInstallment }
        }
        guard value.remainingPeriods > 0, value.nextPrincipalFen >= 0, value.nextInterestFen >= 0,
              value.remainingPrincipalFen.map({ $0 >= 0 }) ?? true,
              try value.nextTotalFen() > 0 else { throw CoveLedgerError.invalidInstallment }
        _ = try value.projectedTotalFen()
    }

    /// Current effective observations, not a reconstruction of historical revisions or a billing schedule.
    func installmentOverview() throws -> CoveLedgerInstallmentOverview {
        let plans = effectiveInstallments
        var next: Int64 = 0, principal: Int64 = 0, projected: Int64 = 0
        var unknownPrincipal = 0, unknownProjection = 0
        for plan in plans {
            next = try CoveLedgerMoney.add(next, plan.nextTotalFen())
            if let value = plan.remainingPrincipalFen { principal = try CoveLedgerMoney.add(principal, value) }
            else { unknownPrincipal += 1 }
            if let value = try plan.projectedTotalFen() {
                projected = try CoveLedgerMoney.add(projected, value)
            } else {
                // Variable future interest stays unknown, but do not hide the amount already known.
                // Remaining principal includes the next principal; when absent, only the next term is known.
                let knownPrincipal = plan.remainingPrincipalFen ?? plan.nextPrincipalFen
                projected = try CoveLedgerMoney.add(projected,
                    CoveLedgerMoney.add(knownPrincipal, plan.nextInterestFen))
                unknownProjection += 1
            }
        }
        return .init(plans: plans, nextTotalFen: next,
                     remainingPrincipal: .init(knownSubtotalFen: principal, unknownPlanCount: unknownPrincipal),
                     projection: .init(knownSubtotalFen: projected, unknownPlanCount: unknownProjection))
    }

    var effectiveStatements: [CoveLedgerStatement] {
        let replaced = Set(statements.compactMap(\.supersedesID))
        return statements.filter { !replaced.contains($0.id) }.sorted {
            if $0.dueDate != $1.dueDate { return $0.dueDate < $1.dueDate }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    fileprivate func validateReconciliation(_ value: CoveLedgerReconciliation) throws {
        guard let account = accounts.first(where: { $0.id == value.accountID }) else { throw CoveLedgerError.missingAccount }
        guard (account.type.isLiquid && value.balanceFen >= 0)
                || (account.type == .creditCard && value.balanceFen <= 0 && value.balanceFen != Int64.min) else {
            throw CoveLedgerError.invalidAccountType
        }
        guard CoveLedgerMonth.isValidDate(value.capturedAt), CoveLedgerMonth.isValidDate(value.createdAt),
              value.capturedAt <= value.createdAt else { throw CoveLedgerError.invalidDate }
    }

    fileprivate func validateStatement(_ value: CoveLedgerStatement) throws {
        guard accounts.first(where: { $0.id == value.accountID })?.type == .creditCard else {
            throw CoveLedgerError.invalidAccountType
        }
        guard value.amountFen >= 0,
              value.minimumDueFen.map({ $0 >= 0 && $0 <= value.amountFen }) ?? true else {
            throw CoveLedgerError.invalidStatement
        }
        guard CoveLedgerMonth.isValidDate(value.statementDate), CoveLedgerMonth.isValidDate(value.dueDate),
              CoveLedgerMonth.isValidDate(value.createdAt), value.dueDate >= value.statementDate,
              value.createdAt >= value.statementDate else { throw CoveLedgerError.invalidDate }
        if let target = value.supersedesID {
            guard target != value.id, let old = effectiveStatements.first(where: { $0.id == target }),
                  old.accountID == value.accountID, value.createdAt >= old.createdAt else {
                throw CoveLedgerError.invalidStatement
            }
            // Preserve the meaning of already-linked payments when correcting the statement date.
            let family = statementFamily(endingAt: old)
            guard events.allSatisfy({ event in
                guard let t = event.transaction, let link = t.statementID, family.contains(link) else { return true }
                return t.occurredAt >= value.statementDate
            }) else { throw CoveLedgerError.invalidStatement }
        }
    }

    private func statementFamily(endingAt statement: CoveLedgerStatement) -> Set<UUID> {
        var ids: Set<UUID> = [statement.id]
        var next = statement.supersedesID
        while let id = next, ids.insert(id).inserted {
            next = statements.first(where: { $0.id == id })?.supersedesID
        }
        return ids
    }

    /// The latest captured observation wins. Capture ties use createdAt then UUID, never array order.
    /// Postings exactly at capture are treated as already reflected in the observation.
    func balances(asOf: Date) throws -> [UUID: Int64] {
        guard CoveLedgerMonth.isValidDate(asOf) else { throw CoveLedgerError.invalidDate }
        var result: [UUID: Int64] = [:]
        let entries = effectiveEntries.sorted {
            let lhs = $0.transaction!.occurredAt, rhs = $1.transaction!.occurredAt
            return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs < rhs
        }
        for account in accounts {
            let anchor = reconciliations.filter {
                $0.accountID == account.id && $0.capturedAt <= asOf && $0.createdAt <= asOf
            }.max {
                if $0.capturedAt != $1.capturedAt { return $0.capturedAt < $1.capturedAt }
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            guard let anchor else { continue }
            var balance = anchor.balanceFen
            for event in entries {
                guard let t = event.transaction, t.occurredAt > anchor.capturedAt, t.occurredAt <= asOf else { continue }
                for p in t.postings where p.accountID == account.id { balance = try CoveLedgerMoney.add(balance, p.amountFen) }
            }
            result[account.id] = balance
        }
        return result
    }

    /// As-of applies to occurrence/capture and statement dates; corrections restate history using
    /// the currently accepted effective records, just like the existing monthly ledger summary.
    /// Due today is not overdue. Due soon includes today through seven calendar days ahead.
    func financeOverview(asOf: Date, calendar: Calendar) throws -> CoveLedgerFinanceOverview {
        let balances = try balances(asOf: asOf)
        func total(_ predicate: (CoveLedgerAccount) -> Bool, debt: Bool) throws -> CoveLedgerKnownTotal {
            let included = accounts.filter(predicate)
            var subtotal: Int64 = 0, unknown = 0
            for account in included {
                guard let balance = balances[account.id] else { unknown += 1; continue }
                let amount: Int64
                if debt && balance < 0 {
                    guard balance != Int64.min else { throw CoveLedgerError.overflow }
                    amount = -balance
                } else { amount = debt ? 0 : balance }
                subtotal = try CoveLedgerMoney.add(subtotal, amount)
            }
            return .init(knownSubtotalFen: subtotal, unknownAccountCount: unknown, accountCount: included.count)
        }
        let liquid = try total({ $0.type.isLiquid }, debt: false)
        let debt = try total({ $0.type == .creditCard }, debt: true)
        let today = calendar.startOfDay(for: asOf)
        let soon = calendar.date(byAdding: .day, value: 7, to: today) ?? today
        var statuses: [CoveLedgerStatementStatus] = []
        var outstanding: Int64 = 0
        for statement in effectiveStatements where statement.statementDate <= asOf {
            let family = statementFamily(endingAt: statement)
            var paid: Int64 = 0
            for event in effectiveEntries {
                guard let t = event.transaction, let link = t.statementID, family.contains(link),
                      t.occurredAt <= asOf else { continue }
                paid = try CoveLedgerMoney.add(paid, t.amountFen)
            }
            let applied = min(statement.amountFen, paid)
            let remaining = statement.amountFen - applied
            outstanding = try CoveLedgerMoney.add(outstanding, remaining)
            let dueDay = calendar.startOfDay(for: statement.dueDate)
            let status: CoveLedgerDueStatus = remaining == 0 ? .paid : dueDay < today ? .overdue : dueDay <= soon ? .dueSoon : .upcoming
            statuses.append(.init(statement: statement, paidFen: applied, remainingFen: remaining, status: status))
        }
        statuses.sort {
            if ($0.remainingFen == 0) != ($1.remainingFen == 0) { return $0.remainingFen > 0 }
            if $0.statement.dueDate != $1.statement.dueDate { return $0.statement.dueDate < $1.statement.dueDate }
            return $0.id.uuidString < $1.id.uuidString
        }
        return .init(asOf: asOf, balances: balances, liquid: liquid, cardDebt: debt,
                     unclassifiedAccountCount: accounts.filter { $0.type == .unclassified }.count,
                     statements: statuses, recordedOutstandingFen: outstanding,
                     liquidAfterRecordedDuesFen: try liquid.totalFen.map { try CoveLedgerMoney.add($0, -outstanding) },
                     installments: try installmentOverview())
    }

    /// Privacy-reduced, deterministic text only. No notes, merchant names, raw transactions or IO.
    func assistantSummary(asOf: Date, calendar: Calendar) throws -> String {
        let overview = try financeOverview(asOf: asOf, calendar: calendar)
        let month = try summary(containing: asOf, calendar: calendar)
        let iso = ISO8601DateFormatter(); iso.timeZone = calendar.timeZone
        let day = DateFormatter(); day.calendar = calendar; day.timeZone = calendar.timeZone
        day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
        func money(_ value: Int64) -> String { "¥" + CoveLedgerMoney.editable(value, locale: Locale(identifier: "en_US_POSIX")) }
        func total(_ value: CoveLedgerKnownTotal) -> String {
            if value.accountCount == 0 { return "未添加账户（总额未知）" }
            return value.totalFen.map(money) ?? "未知（已知小计 \(money(value.knownSubtotalFen))，\(value.unknownAccountCount) 个账户未核对）"
        }
        var lines = ["给 Assistant 的个人账本摘要（仅手动记录，非银行数据）",
                     "截至：\(iso.string(from: asOf)) · \(calendar.timeZone.identifier)",
                     "流动资金：\(total(overview.liquid))；信用卡欠款：\(total(overview.cardDebt))",
                     "未知余额账户：流动 \(overview.liquid.unknownAccountCount)，信用卡 \(overview.cardDebt.unknownAccountCount)；未分类 \(overview.unclassifiedAccountCount)（不计入合计）"]
        // Stable anonymous labels avoid leaking account names that could themselves contain private notes.
        for (index, account) in accounts.sorted(by: { $0.id.uuidString < $1.id.uuidString }).enumerated() {
            let label = "账户 \(index + 1)（\(account.type.title)）"
            if let balance = overview.balances[account.id] {
                if account.type == .creditCard && balance < 0 {
                    guard balance != Int64.min else { throw CoveLedgerError.overflow }
                    lines.append("\(label)：欠款 \(money(-balance))")
                } else { lines.append("\(label)：\(account.type == .creditCard ? "溢缴款" : "余额") \(money(balance))") }
            } else { lines.append("\(label)：余额未知") }
        }
        let orderedAccounts = accounts.sorted { $0.id.uuidString < $1.id.uuidString }
        for item in overview.statements where item.remainingFen > 0 {
            let index = (orderedAccounts.firstIndex { $0.id == item.statement.accountID } ?? 0) + 1
            lines.append("账户 \(index) 账单 \(day.string(from: item.statement.statementDate))：\(item.status.title)，到期 \(day.string(from: item.statement.dueDate))，已还 \(money(item.paidFen))，剩余 \(money(item.remainingFen))")
        }
        lines.append("已录入账单待还合计：\(money(overview.recordedOutstandingFen))（不是全部债务，未关联转账不计已还）")
        lines.append("流动资金减已录入待还：\(overview.liquidAfterRecordedDuesFen.map(money) ?? "未知")")
        let installment = overview.installments
        func planTotal(_ value: CoveLedgerInstallmentTotal) -> String {
            value.totalFen.map(money) ?? "未知（已知小计 \(money(value.knownSubtotalFen))，\(value.unknownPlanCount) 个分期未知）"
        }
        lines.append("未出账分期（独立预测，不计入当前账单或欠款）：下期合计 \(money(installment.nextTotalFen))；剩余本金 \(planTotal(installment.remainingPrincipal))；全部剩余预测 \(planTotal(installment.projection))")
        for (index, plan) in installment.plans.enumerated() {
            let card = (orderedAccounts.firstIndex { $0.id == plan.accountID } ?? 0) + 1
            lines.append("分期 \(index + 1) · 账户 \(card)：剩余 \(plan.remainingPeriods) 期，下期本金 \(money(plan.nextPrincipalFen))，利息/手续费 \(money(plan.nextInterestFen))，合计 \(money(try plan.nextTotalFen()))，到期 \(day.string(from: plan.nextDueDate))，剩余本金 \(plan.remainingPrincipalFen.map(money) ?? "未知")，后续同额 \(plan.amountsRepeat ? "是" : "否")，全部剩余预测 \(try plan.projectedTotalFen().map(money) ?? "未知")")
        }
        lines.append("本月（\(day.string(from: month.month.start)) 起，\(month.month.calendarIdentifier)）收入 \(money(month.incomeFen))，支出 \(money(month.expenseFen))，预算 \(month.budgetFen.map(money) ?? "未设置")")
        return lines.joined(separator: "\n")
    }
}

/// Synchronous serialized local archive. Mutations re-read disk inside the shared lock so two
/// repositories in the same app cannot overwrite each other's accepted events. Share one model
/// across integration surfaces for immediate UI updates. Not a multi-process/app-group database.
extension Notification.Name {
    static let covePersonalLedgerDidChange = Notification.Name("CovePersonalLedgerDidChange")
}

final class CoveLedgerRepository {
    private static let lock = NSRecursiveLock()
    static var liveDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CovePersonalLedger", isDirectory: true)
    }
    let directoryURL: URL?
    var isInMemory: Bool { directoryURL == nil }
    private var memory = CoveLedgerSnapshot()
    private var fileURL: URL? { directoryURL?.appendingPathComponent("ledger-v1.json") }

    init(directoryURL: URL? = CoveLedgerRepository.liveDirectory) { self.directoryURL = directoryURL }

    func load() throws -> CoveLedgerSnapshot {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try readUnlocked()
    }

    private func readUnlocked() throws -> CoveLedgerSnapshot {
        guard let fileURL else { return memory }
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return CoveLedgerSnapshot()
        }
        // Permission/protection failures are not absence. Corrupt/newer archives are never replaced.
        return try JSONDecoder().decode(CoveLedgerSnapshot.self, from: data).validated()
    }

    private func change<T>(_ mutation: (inout CoveLedgerSnapshot) throws -> T) throws -> T {
        var committed = false
        Self.lock.lock()
        defer {
            Self.lock.unlock()
            // Notify only after a successful durable live write, never for previews or test archives.
            if committed, directoryURL == Self.liveDirectory {
                NotificationCenter.default.post(name: .covePersonalLedgerDidChange, object: nil)
            }
        }
        var snapshot = try readUnlocked()
        let before = snapshot
        let result = try mutation(&snapshot)
        guard snapshot != before else { return result }
        _ = try snapshot.validated()
        if let fileURL, let directoryURL {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            #if os(iOS)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: fileURL, options: .atomic)
            #endif
        } else { memory = snapshot }
        committed = true
        return result // Accepted only after a successful atomic write.
    }

    @discardableResult
    func saveAccount(id: UUID = UUID(), name: String, type: CoveLedgerAccountType? = nil) throws -> CoveLedgerAccount {
        let name = try CoveLedgerSnapshot.name(name)
        return try change { snapshot in
            let old = snapshot.accounts.first { $0.id == id }
            let value = CoveLedgerAccount(id: id, name: name, type: type ?? old?.type ?? .unclassified)
            if let old, old.type != value.type, snapshot.reconciliations.contains(where: { $0.accountID == id }),
               !(old.type.isLiquid && value.type.isLiquid) { throw CoveLedgerError.invalidAccountType }
            if (snapshot.statements.contains(where: { $0.accountID == id })
                || snapshot.installments.contains(where: { $0.accountID == id })), value.type != .creditCard {
                throw CoveLedgerError.invalidAccountType
            }
            guard !snapshot.accounts.contains(where: { $0.id != id && $0.name.lowercased() == value.name.lowercased() }) else {
                throw CoveLedgerError.duplicateName
            }
            if let index = snapshot.accounts.firstIndex(where: { $0.id == id }) { snapshot.accounts[index] = value }
            else { snapshot.accounts.append(value) }
            return value
        }
    }

    /// Installs the owner's requested card choices without inventing balances or debt.
    /// A legacy unclassified account with an exact requested name is classified by this
    /// explicit choice; a liquid account keeps its meaning and gets a separate card entry.
    @discardableResult
    func ensurePreferredCreditAccounts() throws -> [CoveLedgerAccount] {
        try change { snapshot in
            for template in CoveLedgerPreferredCreditAccounts.templates {
                if let index = snapshot.accounts.firstIndex(where: {
                    $0.name.compare(template.name, options: .caseInsensitive) == .orderedSame
                }) {
                    let existing = snapshot.accounts[index]
                    if existing.type == .unclassified {
                        snapshot.accounts[index] = .init(id: existing.id, name: existing.name, type: .creditCard)
                        continue
                    }
                    if existing.type == .creditCard { continue }
                }

                let exactNameExists = snapshot.accounts.contains(where: {
                    $0.name.compare(template.name, options: .caseInsensitive) == .orderedSame
                })
                let storedName = exactNameExists ? template.name + "信用卡" : template.name
                if snapshot.accounts.contains(where: {
                    $0.name.compare(storedName, options: .caseInsensitive) == .orderedSame && $0.type == .creditCard
                }) { continue }
                guard !snapshot.accounts.contains(where: { $0.id == template.id }),
                      !snapshot.accounts.contains(where: {
                          $0.name.compare(storedName, options: .caseInsensitive) == .orderedSame
                      }) else { throw CoveLedgerError.duplicateName }
                snapshot.accounts.append(.init(id: template.id, name: storedName, type: .creditCard))
            }
            return snapshot.accounts.filter { $0.type == .creditCard }
        }
    }

    @discardableResult
    func saveCategory(id: UUID = UUID(), name: String, kind: CoveLedgerKind) throws -> CoveLedgerCategory {
        guard kind != .transfer else { throw CoveLedgerError.invalidCategory }
        let value = CoveLedgerCategory(id: id, name: try CoveLedgerSnapshot.name(name), kind: kind)
        return try change { snapshot in
            guard !snapshot.categories.contains(where: { $0.id != id && $0.kind == kind && $0.name.lowercased() == value.name.lowercased() }) else {
                throw CoveLedgerError.duplicateName
            }
            if let index = snapshot.categories.firstIndex(where: { $0.id == id }) {
                guard snapshot.categories[index].kind == kind else { throw CoveLedgerError.invalidCategory }
                snapshot.categories[index] = value
            } else { snapshot.categories.append(value) }
            return value
        }
    }

    /// Dry-run the same domain rules before a UI freezes an intent. append rechecks under its lock.
    func validate(_ event: CoveLedgerEvent) throws {
        var snapshot = try load()
        if let existing = snapshot.events.first(where: { $0.id == event.id }) {
            guard existing == event else { throw CoveLedgerError.operationConflict }
            return
        }
        try snapshot.validateNewEvent(event)
        snapshot.events.append(event)
        try snapshot.validateTotals()
    }

    @discardableResult
    func append(_ event: CoveLedgerEvent) throws -> CoveLedgerEvent {
        try change { snapshot in
            if let existing = snapshot.events.first(where: { $0.id == event.id }) {
                guard existing == event else { throw CoveLedgerError.operationConflict }
                return existing
            }
            try snapshot.validateNewEvent(event)
            snapshot.events.append(event)
            return event
        }
    }

    @discardableResult
    func appendReconciliation(_ value: CoveLedgerReconciliation) throws -> CoveLedgerReconciliation {
        try change { snapshot in
            if let old = snapshot.reconciliations.first(where: { $0.id == value.id }) {
                guard old == value else { throw CoveLedgerError.operationConflict }; return old
            }
            guard !snapshot.events.contains(where: { $0.id == value.id }),
                  !snapshot.statements.contains(where: { $0.id == value.id }),
                  !snapshot.installments.contains(where: { $0.id == value.id }) else { throw CoveLedgerError.operationConflict }
            try snapshot.validateReconciliation(value)
            snapshot.reconciliations.append(value)
            return value
        }
    }

    @discardableResult
    func appendStatement(_ value: CoveLedgerStatement) throws -> CoveLedgerStatement {
        try change { snapshot in
            if let old = snapshot.statements.first(where: { $0.id == value.id }) {
                guard old == value else { throw CoveLedgerError.operationConflict }; return old
            }
            guard !snapshot.events.contains(where: { $0.id == value.id }),
                  !snapshot.reconciliations.contains(where: { $0.id == value.id }),
                  !snapshot.installments.contains(where: { $0.id == value.id }) else { throw CoveLedgerError.operationConflict }
            try snapshot.validateStatement(value)
            snapshot.statements.append(value)
            return value
        }
    }

    /// New plan, replacement and canonical close all use the same serialized append path.
    @discardableResult
    func appendInstallment(_ value: CoveLedgerInstallment) throws -> CoveLedgerInstallment {
        try change { snapshot in
            if let old = snapshot.installments.first(where: { $0.id == value.id }) {
                guard old == value else { throw CoveLedgerError.operationConflict }
                return old
            }
            try snapshot.validateInstallment(value)
            snapshot.installments.append(value)
            return value
        }
    }

    func setBudget(_ budget: CoveLedgerBudget) throws {
        try change { snapshot in
            try snapshot.validateBudget(budget)
            snapshot.budgets.removeAll { $0.month == budget.month }
            // Clearing every field genuinely removes configuration rather than creating a zero budget.
            if budget.overallFen != nil || !budget.categoryFen.isEmpty { snapshot.budgets.append(budget) }
        }
    }
}
