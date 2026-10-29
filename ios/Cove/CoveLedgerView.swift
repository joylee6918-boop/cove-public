import SwiftUI

@MainActor
final class CoveLedgerModel: ObservableObject {
    static let live = CoveLedgerModel(repository: CoveLedgerRepository())
    let repository: CoveLedgerRepository
    let calendar: Calendar
    let isPreview: Bool
    @Published private(set) var snapshot: CoveLedgerSnapshot?
    @Published private(set) var error: String?

    init(repository: CoveLedgerRepository, calendar: Calendar = .current) {
        self.repository = repository; self.calendar = calendar; self.isPreview = false
        reload()
    }

    private init(previewCalendar: Calendar) {
        repository = CoveLedgerRepository(directoryURL: nil)
        calendar = previewCalendar; isPreview = true
        reload()
    }

    /// A clearly labelled, empty sandbox; it never opens the live archive, even in Xcode previews.
    static func preview(calendar: Calendar = .current) -> CoveLedgerModel {
        CoveLedgerModel(previewCalendar: calendar)
    }

    func reload() {
        do { snapshot = try repository.load(); error = nil }
        catch { snapshot = nil; self.error = "账本读取失败：\(error.localizedDescription)" }
    }

    func ensurePreferredCreditAccounts() {
        guard snapshot != nil else { return }
        do {
            _ = try repository.ensurePreferredCreditAccounts()
            reload()
        } catch {
            self.error = "信用卡选项准备失败：\(error.localizedDescription)"
        }
    }

    func append(_ event: CoveLedgerEvent) throws {
        guard snapshot != nil else { throw CoveLedgerError.invalidArchive }
        _ = try repository.append(event)
        // The write has been acknowledged. A later read failure must not turn it into a retryable save.
        reload()
    }

    @discardableResult
    func perform(_ action: () throws -> Void) -> Bool {
        guard snapshot != nil else { return false }
        do {
            try action()
            snapshot = try repository.load(); error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

struct CoveLedgerHomeCard: View {
    @ObservedObject private var model: CoveLedgerModel
    private let onPrepareAssistantSummary: ((String) -> Void)?
    private let assistantAccessStatus: String?
    @State private var showing = false
    @Environment(\.scenePhase) private var scenePhase

    init(model: CoveLedgerModel? = nil, onPrepareAssistantSummary: ((String) -> Void)? = nil,
         assistantAccessStatus: String? = nil) {
        self.model = model ?? .live; self.onPrepareAssistantSummary = onPrepareAssistantSummary
        self.assistantAccessStatus = assistantAccessStatus
    }
    init(repository: CoveLedgerRepository, calendar: Calendar = .current,
         onPrepareAssistantSummary: ((String) -> Void)? = nil, assistantAccessStatus: String? = nil) {
        self.model = CoveLedgerModel(repository: repository, calendar: calendar)
        self.onPrepareAssistantSummary = onPrepareAssistantSummary
        self.assistantAccessStatus = assistantAccessStatus
    }

    var body: some View {
        Button { showing = true } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("账本", systemImage: "book.closed").font(.headline).foregroundStyle(CoveStyle.accentText)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption)
                }
                if model.isPreview { Text("示例预览 · 仅内存").font(.caption) }
                if let snapshot = model.snapshot,
                   let summary = try? snapshot.summary(containing: Date(), calendar: model.calendar) {
                    if let overview = try? snapshot.financeOverview(asOf: Date(), calendar: model.calendar),
                       let due = overview.nearestOutstanding {
                        Text("\(due.status.title) · \(CoveLedgerMoney.display(due.remainingFen))").font(.subheadline.monospacedDigit())
                        Text(due.statement.dueDate, format: .dateTime.month().day()).font(.caption)
                    } else if let overview = try? snapshot.financeOverview(asOf: Date(), calendar: model.calendar),
                              overview.liquid.accountCount > 0, let liquid = overview.liquid.totalFen {
                        Text("流动资金 \(CoveLedgerMoney.display(liquid))").font(.subheadline.monospacedDigit())
                        Text("基于余额核对与已记流水").font(.caption)
                    } else {
                        Text("本月支出 \(CoveLedgerMoney.display(summary.expenseFen))").font(.subheadline.monospacedDigit())
                        Text(summary.availableBudgetFen.map { "预算余量 \(CoveLedgerMoney.display($0))" } ?? "预算尚未设置")
                            .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                    }
                } else {
                    Text("账本暂不可读 · 点开重试").font(.subheadline)
                }
                Text(assistantAccessStatus ?? "本机手动记录")
                    .font(.caption2).foregroundStyle(CoveStyle.pearlSecondary).lineLimit(2)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            .padding(18).foregroundStyle(CoveStyle.pearlInk).covePearlCard()
        }
        .buttonStyle(.plain).accessibilityIdentifier("home.personalLedger")
        .sheet(isPresented: $showing) {
            NavigationStack {
                if let onPrepareAssistantSummary {
                    CoveLedgerPage(model: model, onPrepareAssistantSummary: { text in
                        showing = false
                        onPrepareAssistantSummary(text)
                    }, assistantAccessStatus: assistantAccessStatus)
                } else { CoveLedgerPage(model: model, assistantAccessStatus: assistantAccessStatus) }
            }
        }
        .environment(\.calendar, model.calendar).environment(\.timeZone, model.calendar.timeZone)
        .onAppear { model.reload() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.reload() } }
    }
}

/// Embed in a NavigationStack (push destination or sheet); no tab/navigation shell is installed here.
struct CoveLedgerPage: View {
    @ObservedObject private var model: CoveLedgerModel
    @State private var month = Date()
    @State private var showEntry = false
    @State private var showBudget = false
    @State private var showReconciliation = false
    @State private var showStatement = false
    @State private var showRepayment = false
    @State private var showInstallment = false
    @State private var updatingInstallment: CoveLedgerInstallment?
    @State private var correctingStatement: CoveLedgerStatement?
    @State private var sharing: CoveLedgerShareText?
    @State private var shareError: String?
    private let onPrepareAssistantSummary: ((String) -> Void)?
    private let assistantAccessStatus: String?
    @Environment(\.dismiss) private var dismiss

    init(model: CoveLedgerModel? = nil, onPrepareAssistantSummary: ((String) -> Void)? = nil,
         assistantAccessStatus: String? = nil) {
        self.model = model ?? .live; self.onPrepareAssistantSummary = onPrepareAssistantSummary
        self.assistantAccessStatus = assistantAccessStatus
    }
    init(repository: CoveLedgerRepository, calendar: Calendar = .current,
         onPrepareAssistantSummary: ((String) -> Void)? = nil, assistantAccessStatus: String? = nil) {
        self.model = CoveLedgerModel(repository: repository, calendar: calendar)
        self.onPrepareAssistantSummary = onPrepareAssistantSummary
        self.assistantAccessStatus = assistantAccessStatus
    }

    private var overview: CoveLedgerFinanceOverview? {
        try? model.snapshot?.financeOverview(asOf: Date(), calendar: model.calendar)
    }

    private var summary: CoveLedgerSummary? {
        guard let snapshot = model.snapshot else { return nil }
        return try? snapshot.summary(containing: month, calendar: model.calendar)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if model.isPreview { Text("示例预览 · 所有操作仅保留在内存").font(.footnote) }
                if let assistantAccessStatus {
                    Label(assistantAccessStatus, systemImage: "person.crop.circle.badge.checkmark")
                        .font(.footnote).foregroundStyle(CoveStyle.pearlSecondary)
                        .accessibilityIdentifier("ledger.assistantAccess")
                }
                monthControl
                if let message = model.error { CoveLedgerErrorNotice(message: message) }
                if let snapshot = model.snapshot, let summary {
                    hero(summary)
                    Button { showEntry = true } label: {
                        Label("记一笔", systemImage: "plus").font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                        .accessibilityIdentifier("ledger.add")
                    VStack(spacing: 8) {
                        Button { showReconciliation = true } label: {
                            Text("核对余额").frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.bordered)
                        Button { showStatement = true } label: {
                            Text("录入信用卡账单").frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.bordered)
                        Button { showInstallment = true } label: {
                            Text("记录分期").frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.bordered).accessibilityIdentifier("ledger.installment.add")
                        Button { showRepayment = true } label: {
                            Text("信用卡还款 · 记转账").frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.bordered)
                        if onPrepareAssistantSummary != nil {
                            Button {
                                do {
                                    sharing = .init(text: try snapshot.assistantSummary(asOf: Date(), calendar: model.calendar))
                                    shareError = nil
                                } catch { shareError = error.localizedDescription }
                            } label: {
                                Text("预览给 Assistant 的摘要").frame(maxWidth: .infinity, minHeight: 44)
                            }.buttonStyle(.bordered)
                        }
                        if let shareError { CoveLedgerErrorNotice(message: shareError) }
                    }
                    if let overview {
                        finances(overview, snapshot: snapshot)
                        installments(overview.installments, snapshot: snapshot)
                    } else {
                        CoveLedgerErrorNotice(message: "资产与账单暂时无法计算，可能已超出金额范围；不会显示为零。")
                    }
                    categoryBreakdown(summary, snapshot: snapshot)
                    recent(summary, snapshot: snapshot)
                    Text("当前资产按余额核对与之后的流水推算，不是银行实时数据。未核对不是零；未分类账户不计资产合计。账单待还不等于全部欠款。转账不计收支，更正保留原记录。")
                        .font(.footnote).foregroundStyle(CoveStyle.pearlSecondary)
                } else {
                    ContentUnavailableView("暂时无法打开账本", systemImage: "book.closed", description: Text("不会显示虚构余额，也不会覆盖原文件。"))
                    Button("重新读取") { model.reload() }.buttonStyle(.bordered)
                }
            }.padding(20)
        }
        .background(CoveStyle.pearlCanvas).foregroundStyle(CoveStyle.pearlInk)
        .tint(CoveStyle.accent).navigationTitle("账本")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    NavigationLink("全部流水") { CoveLedgerHistory(model: model) }
                    NavigationLink("账户与分类") { CoveLedgerManagement(model: model) }
                    Button("月度预算") { showBudget = true }
                } label: { Label("管理账本", systemImage: "ellipsis.circle") }
                .disabled(model.snapshot == nil)
            }
            ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
        }
        .sheet(isPresented: $showEntry) { NavigationStack { CoveLedgerEntrySheet(model: model) } }
        .sheet(isPresented: $showBudget) { NavigationStack { CoveLedgerBudgetSheet(model: model, date: month) } }
        .sheet(isPresented: $showReconciliation) { NavigationStack { CoveLedgerReconciliationSheet(model: model) } }
        .sheet(isPresented: $showStatement) { NavigationStack { CoveLedgerStatementSheet(model: model) } }
        .sheet(item: $correctingStatement) { statement in
            NavigationStack { CoveLedgerStatementSheet(model: model, correcting: statement) }
        }
        .sheet(isPresented: $showInstallment) { NavigationStack { CoveLedgerInstallmentSheet(model: model) } }
        .sheet(item: $updatingInstallment) { plan in
            NavigationStack { CoveLedgerInstallmentSheet(model: model, updating: plan) }
        }
        .sheet(isPresented: $showRepayment) { NavigationStack { CoveLedgerEntrySheet(model: model, repayment: true) } }
        .sheet(item: $sharing) { value in
            NavigationStack {
                CoveLedgerSharePreview(text: value.text, isPreview: model.isPreview) { text in
                    onPrepareAssistantSummary?(text)
                }
            }
        }
        .environment(\.calendar, model.calendar).environment(\.timeZone, model.calendar.timeZone)
        .onAppear { model.ensurePreferredCreditAccounts() }
    }

    private var monthControl: some View {
        HStack {
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .accessibilityLabel("上个月")
            Spacer()
            Text(month, format: .dateTime.year().month()).font(.headline)
            Spacer()
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .accessibilityLabel("下个月")
        }
    }

    private func shiftMonth(_ value: Int) {
        if let start = model.calendar.dateInterval(of: .month, for: month)?.start,
           let next = model.calendar.date(byAdding: .month, value: value, to: start) { month = next }
    }

    private func recordedDebt(_ overview: CoveLedgerFinanceOverview) -> (fen: Int64, unknownPlans: Int)? {
        guard let fen = try? CoveLedgerMoney.add(overview.recordedOutstandingFen,
                                                  overview.installments.projection.knownSubtotalFen) else { return nil }
        return (fen, overview.installments.projection.unknownPlanCount)
    }

    private func hero(_ summary: CoveLedgerSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let overview, let debt = recordedDebt(overview), debt.fen > 0 {
                let outstanding = overview.statements.filter { $0.remainingFen > 0 }
                let urgent = overview.nearestOutstanding
                Text(urgent?.status == .overdue ? "有账单已逾期" : urgent?.status == .dueSoon ? "账单快到期了" : "当前已录入总欠款")
                    .font(.subheadline)
                Text((debt.unknownPlans > 0 ? "至少 " : "") + CoveLedgerMoney.display(debt.fen))
                    .font(.largeTitle.monospacedDigit()).bold()
                    .foregroundStyle(urgent?.status == .overdue ? CoveStyle.error : CoveStyle.pearlInk)
                Text("账单待还 \(CoveLedgerMoney.display(overview.recordedOutstandingFen)) + 未出账分期已知部分 \(CoveLedgerMoney.display(overview.installments.projection.knownSubtotalFen))")
                    .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                if debt.unknownPlans > 0 {
                    Text("另有 \(debt.unknownPlans) 个分期的未来利息尚未知，不会乱猜。")
                        .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                } else if !outstanding.isEmpty {
                    Text("\(outstanding.count) 张账单已自动相加，不需要重复录入当前欠款。")
                        .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                }
                if let urgent {
                    Text("最近：\(model.snapshot?.accountName(urgent.statement.accountID) ?? "信用卡") · \(CoveLedgerMoney.display(urgent.remainingFen))")
                    Text(urgent.statement.dueDate, format: .dateTime.year().month().day()).font(.subheadline)
                }
                if let after = overview.liquidAfterRecordedDuesFen, after < 0 {
                    Text("已知流动资金还差 \(CoveLedgerMoney.display(-after))")
                        .font(.subheadline.bold()).foregroundStyle(CoveStyle.error)
                }
            } else if let overview, overview.liquid.accountCount > 0, let total = overview.liquid.totalFen {
                Text("当前流动资金").font(.subheadline)
                Text(CoveLedgerMoney.display(total)).font(.largeTitle.monospacedDigit()).bold()
                Text("基于手动核对；并非实时银行余额").font(.caption)
            } else {
                Text("还没有待还账单").font(.headline)
                Text("本月已记支出 \(CoveLedgerMoney.display(summary.expenseFen))")
                    .font(.title2.monospacedDigit()).bold()
                Text("账户余额尚未核对，不影响录入账单后的自动合计。")
                    .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
            }
            if let budget = summary.budgetFen {
                CoveLedgerMeter(value: summary.expenseFen, total: budget)
                Text("月预算 \(CoveLedgerMoney.display(budget))").font(.caption)
            } else {
                Button("设置本月预算") { showBudget = true }.font(.subheadline)
            }
            ViewThatFits(in: .horizontal) {
                HStack { metric("收入", summary.incomeFen); Spacer(); metric("支出", summary.expenseFen) }
                VStack(alignment: .leading, spacing: 8) { metric("收入", summary.incomeFen); metric("支出", summary.expenseFen) }
            }
            if summary.budgetFen != nil { Button("调整预算") { showBudget = true }.font(.caption) }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading).covePearlCard(emphasized: true)
    }

    private func finances(_ overview: CoveLedgerFinanceOverview, snapshot: CoveLedgerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("账单、资产与欠款").font(.headline)
            if let debt = recordedDebt(overview) {
                VStack(alignment: .leading, spacing: 5) {
                    LabeledContent("当前已录入总欠款", value: (debt.unknownPlans > 0 ? "至少 " : "") + CoveLedgerMoney.display(debt.fen))
                        .font(.headline.monospacedDigit())
                    Text("账单待还 \(CoveLedgerMoney.display(overview.recordedOutstandingFen)) + 未出账分期已知部分 \(CoveLedgerMoney.display(overview.installments.projection.knownSubtotalFen))")
                        .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                    if debt.unknownPlans > 0 {
                        Text("未来利息有未知部分，因此这里只显示不会少于的金额。")
                            .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                    }
                }.padding(10).background(CoveStyle.pearlIce.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
            } else { CoveLedgerErrorNotice(message: "总欠款超出可计算范围") }
            DisclosureGroup("银行实时余额核对（可选）") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("不核对也不影响上面的账单与分期自动合计。")
                        .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                    totalRow("流动资金", overview.liquid)
                    totalRow("银行显示的信用卡当前欠款", overview.cardDebt, unknownText: "未核对（可选）")
                    if overview.unclassifiedAccountCount > 0 {
                        Text("\(overview.unclassifiedAccountCount) 个未分类账户未计入余额合计。")
                            .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                    }
                    ForEach(snapshot.accounts) { account in
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent(account.name, value: CoveLedgerBalanceText(account: account, balance: overview.balances[account.id]))
                            Text(account.type.title).font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                        }
                    }
                }.padding(.top, 8)
            }
            Divider()
            Text("信用卡账单").font(.headline)
            Text("本期账单待还 \(CoveLedgerMoney.display(overview.recordedOutstandingFen))；这里不包含尚未出账的未来分期。")
                .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
            if overview.statements.isEmpty { Text("尚无已录入账单，不代表没有待还。") }
            ForEach(overview.statements) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(snapshot.accountName(item.statement.accountID)) · \(item.status.title)").font(.subheadline.bold())
                    Text(item.statement.dueDate, format: .dateTime.year().month().day()).font(.subheadline)
                    Text("账单 \(CoveLedgerMoney.display(item.statement.amountFen)) · 已还 \(CoveLedgerMoney.display(item.paidFen)) · 剩余 \(CoveLedgerMoney.display(item.remainingFen))")
                        .font(.subheadline.monospacedDigit())
                    if let minimum = item.statement.minimumDueFen {
                        Text("原账单最低应还 \(CoveLedgerMoney.display(minimum))（不代表全额结清）").font(.caption)
                    }
                    Button { correctingStatement = item.statement } label: {
                        Text("更正账单（保留原件）").frame(minHeight: 44)
                    }
                }
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).covePearlCard()
    }

    private func installments(_ overview: CoveLedgerInstallmentOverview, snapshot: CoveLedgerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("未出账分期").font(.headline)
            Text("照着银行抄本金和利息，Cove 帮你相加。未出账分期的已知部分会加入上方总欠款，但不会混进本期账单、收支或还款。")
                .font(.footnote).foregroundStyle(CoveStyle.pearlSecondary)
            if overview.plans.isEmpty { Text("尚无有效分期记录，不代表银行没有分期。") }
            else {
                Text("已录分期下期合计 \(CoveLedgerMoney.display(overview.nextTotalFen))")
                    .monospacedDigit()
                installmentTotal("剩余本金", overview.remainingPrincipal)
                installmentTotal("全部剩余预测", overview.projection)
                if let nearest = overview.nearest {
                    Text("最近下期到期：\(Text(nearest.nextDueDate, format: .dateTime.year().month().day()))")
                        .font(.subheadline)
                }
            }
            ForEach(overview.plans) { plan in
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    CoveLedgerInstallmentFigures(plan: plan, cardName: snapshot.accountName(plan.accountID))
                    Button { updatingInstallment = plan } label: {
                        Text("更新 / 关闭分期（保留历史）").frame(minHeight: 44)
                    }
                }
            }
            Text("某一期出现在实际账单后，以账单为当前应还来源，再按银行最新数字更新这里的剩余期数和金额。不要把预测另记成支出或还款；关闭分期也不代表付款。")
                .font(.footnote).foregroundStyle(CoveStyle.pearlSecondary)
            NavigationLink { CoveLedgerInstallmentHistory(model: model) } label: {
                Text("分期历史（含已关闭）").frame(minHeight: 44)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).covePearlCard()
    }

    private func installmentTotal(_ title: String, _ total: CoveLedgerInstallmentTotal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title)：\(total.totalFen.map { CoveLedgerMoney.display($0) } ?? "未知")")
            if total.unknownPlanCount > 0 {
                Text("已知小计 \(CoveLedgerMoney.display(total.knownSubtotalFen)) · \(total.unknownPlanCount) 个分期未知")
                    .font(.caption)
            }
        }.foregroundStyle(CoveStyle.pearlInk)
    }

    private func totalRow(_ title: String, _ total: CoveLedgerKnownTotal, unknownText: String = "未核对齐") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title, value: total.totalFen.map { CoveLedgerMoney.display($0) } ?? (total.accountCount == 0 ? "未添加账户" : unknownText))
            if total.unknownAccountCount > 0 {
                Text("已知小计 \(CoveLedgerMoney.display(total.knownSubtotalFen)) · \(total.unknownAccountCount) 个账户未知")
                    .font(.caption)
            }
        }.padding(10).background(CoveStyle.pearlIce.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
    }

    private func metric(_ title: String, _ fen: Int64) -> some View {
        Label("\(title) \(CoveLedgerMoney.display(fen))", systemImage: title == "收入" ? "arrow.down.left" : "arrow.up.right")
            .font(.subheadline.monospacedDigit()).foregroundStyle(CoveStyle.pearlSecondary)
    }

    private func categoryBreakdown(_ summary: CoveLedgerSummary, snapshot: CoveLedgerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本月去向").font(.headline)
            VStack(alignment: .leading, spacing: 16) {
                if summary.categories.isEmpty { Text("这个月还没有支出记录。").foregroundStyle(CoveStyle.pearlSecondary) }
                ForEach(summary.categories) { category in
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent(snapshot.categoryName(category.id), value: CoveLedgerMoney.display(category.amountFen))
                            .font(.subheadline.monospacedDigit())
                        CoveLedgerMeter(value: category.amountFen, total: category.budgetFen ?? summary.expenseFen)
                        if let budget = category.budgetFen {
                            Text("分类预算 \(CoveLedgerMoney.display(budget)) · \(category.amountFen > budget ? "已超出" : "剩余") \(CoveLedgerMoney.display(category.amountFen > budget ? category.amountFen - budget : budget - category.amountFen))")
                                .font(.caption).foregroundStyle(category.amountFen > budget ? CoveStyle.error : CoveStyle.pearlSecondary)
                        }
                    }
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).covePearlCard()
        }
    }

    private func recent(_ summary: CoveLedgerSummary, snapshot: CoveLedgerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近流水").font(.headline)
                Spacer()
                NavigationLink("全部") { CoveLedgerHistory(model: model) }.font(.subheadline)
            }
            VStack(alignment: .leading, spacing: 12) {
                if summary.recentEntries.isEmpty { Text("从第一笔开始，慢慢记清楚。").foregroundStyle(CoveStyle.pearlSecondary) }
                ForEach(summary.recentEntries) { event in
                    NavigationLink { CoveLedgerDetail(model: model, eventID: event.id) } label: {
                        CoveLedgerEventRow(event: event, snapshot: snapshot)
                    }.buttonStyle(.plain)
                    if event.id != summary.recentEntries.last?.id { Divider() }
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).covePearlCard()
        }
    }
}

private struct CoveLedgerMeter: View {
    let value: Int64
    let total: Int64
    private var basisPoints: Int {
        guard total > 0 else { return value > 0 ? 10_000 : 0 }
        return NSDecimalNumber(decimal: min(Decimal(1), Decimal(max(0, value)) / Decimal(total)) * Decimal(10_000)).intValue
    }
    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(CoveStyle.pearlLilac.opacity(0.22))
                .overlay(alignment: .leading) {
                    Capsule().fill(CoveStyle.pearlIce)
                        .frame(width: geometry.size.width * CGFloat(basisPoints) / 10_000)
                }
        }.frame(height: 7)
            .accessibilityElement().accessibilityLabel("已用 \(CoveLedgerMoney.display(value))，总额 \(CoveLedgerMoney.display(total))")
    }
}

private struct CoveLedgerErrorNotice: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.footnote).foregroundStyle(CoveStyle.error).accessibilityIdentifier("ledger.error")
    }
}

private struct CoveLedgerEventRow: View {
    let event: CoveLedgerEvent
    let snapshot: CoveLedgerSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(event.transaction.map { $0.note.isEmpty ? snapshot.categoryName($0.categoryID) : $0.note } ?? "作废冲销")
                    .lineLimit(2)
                Spacer(minLength: 8)
                if let transaction = event.transaction {
                    Text(CoveLedgerMoney.display(transaction.kind == .expense ? -transaction.amountFen : transaction.amountFen))
                        .monospacedDigit().layoutPriority(1)
                } else { Text("已冲销").font(.subheadline) }
            }
            Text("\(event.title)\(snapshot.reversal(of: event.id) == nil ? "" : " · 已被冲销")")
                .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
            if let transaction = event.transaction {
                Text(transaction.occurredAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
            }
        }.foregroundStyle(CoveStyle.pearlInk).accessibilityElement(children: .combine)
    }
}

private struct CoveLedgerEntrySheet: View {
    @ObservedObject var model: CoveLedgerModel
    var correcting: CoveLedgerEvent? = nil
    var repayment = false
    @Environment(\.dismiss) private var dismiss
    @State private var kind: CoveLedgerKind = .expense
    @State private var amount = ""
    @State private var accountID: UUID?
    @State private var destinationID: UUID?
    @State private var statementID: UUID?
    @State private var categoryID: UUID?
    @State private var date = Date()
    @State private var note = ""
    @State private var reason = ""
    @State private var initialized = false
    @State private var localError: String?
    // Freeze the complete event for any ambiguous local write/read failure; never invent a new ID on retry.
    @State private var pending: CoveLedgerEvent?
    @FocusState private var amountFocused: Bool

    var body: some View {
        Form {
            if model.isPreview { Section { Text("示例预览 · 不保存到设备") } }
            Section {
                if repayment {
                    Text("信用卡还款是转账，不是又花了一笔钱。这里只记账，不会实际付款。")
                        .font(.footnote)
                } else {
                    Picker("类型", selection: $kind) {
                        ForEach(CoveLedgerKind.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("¥").font(.title)
                    TextField("0.00", text: $amount).font(.largeTitle.monospacedDigit())
                        .keyboardType(.decimalPad).focused($amountFocused)
                        .accessibilityLabel("金额，人民币元").accessibilityIdentifier("ledger.amount")
                }.padding(.vertical, 16)
            }.listRowBackground(CoveStyle.pearlCard).disabled(pending != nil)
            Section("明细") {
                if kind != .transfer {
                    Picker("分类", selection: $categoryID) {
                        Text("请选择").tag(nil as UUID?)
                        ForEach((model.snapshot?.categories ?? []).filter { $0.kind == kind }) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Picker(kind == .transfer ? "转出账户" : "账户", selection: $accountID) {
                    Text("请选择").tag(nil as UUID?)
                    ForEach((model.snapshot?.accounts ?? []).filter { !repayment || $0.type.isLiquid }) {
                        Text($0.name).tag(Optional($0.id))
                    }
                }
                if kind == .transfer {
                    Picker("转入账户", selection: $destinationID) {
                        Text("请选择").tag(nil as UUID?)
                        ForEach((model.snapshot?.accounts ?? []).filter { !repayment || $0.type == .creditCard }) {
                            Text($0.type == .creditCard ? CoveLedgerPreferredCreditAccounts.displayName(for: $0) : $0.name)
                                .tag(Optional($0.id))
                        }
                    }
                    if model.snapshot?.accounts.first(where: { $0.id == destinationID })?.type == .creditCard {
                        Picker("关联账单（可选）", selection: $statementID) {
                            Text("不关联 · 只减少欠款").tag(nil as UUID?)
                            ForEach((model.snapshot?.effectiveStatements ?? []).filter { $0.accountID == destinationID }) { statement in
                                Text("\(Text(statement.dueDate, format: .dateTime.year().month().day())) · \(CoveLedgerMoney.display(statement.amountFen))")
                                    .tag(Optional(statement.id))
                            }
                            if let statementID, let old = model.snapshot?.statements.first(where: { $0.id == statementID }),
                               model.snapshot?.effectiveStatements.contains(where: { $0.id == statementID }) == false {
                                Text("原关联账单（已更正，归入替代账单）").tag(Optional(old.id))
                            }
                        }
                        Text("只有明确关联的有效还款才减少这张账单待还；未关联不自动标记已还。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("只记录账户间移动，不计收入、支出或预算。").font(.caption).foregroundStyle(.secondary)
                }
                DatePicker("发生日期", selection: $date)
                TextField("备注（可选）", text: $note, axis: .vertical).lineLimit(2...5)
                NavigationLink("管理账户与分类") { CoveLedgerManagement(model: model) }
            }.disabled(pending != nil)
            if correcting != nil {
                Section("更正说明") {
                    TextField("为什么更正（必填）", text: $reason, axis: .vertical)
                    Text("保存会追加一条冲销与替代事件，不改写原记录。原发生月份将重新统计；新记录按上方日期归属月份。")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(pending != nil)
            }
            if let message = localError ?? model.error { Section { CoveLedgerErrorNotice(message: message) } }
            Section {
                Button(pending == nil ? (correcting == nil ? "保存这笔\(kind.title)" : "追加更正") : "用原操作重试保存") { save() }
                    .font(.headline).frame(maxWidth: .infinity).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("ledger.save")
            }
        }
        .scrollContentBackground(.hidden).background(CoveStyle.pearlCanvas).tint(CoveStyle.accent)
        .navigationTitle(correcting == nil ? (repayment ? "信用卡还款" : "记一笔") : "更正记录").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { amountFocused = false } }
        }
        .onAppear {
            guard !initialized else { return }; initialized = true
            if repayment { kind = .transfer }
            if let transaction = correcting?.transaction {
                kind = transaction.kind; amount = CoveLedgerMoney.editable(transaction.amountFen)
                accountID = transaction.accountID; destinationID = transaction.destinationAccountID
                categoryID = transaction.categoryID; date = transaction.occurredAt; note = transaction.note
                statementID = transaction.statementID
            }
        }
        .onChange(of: destinationID) { _, newID in
            if let statementID, model.snapshot?.statements.first(where: { $0.id == statementID })?.accountID != newID {
                self.statementID = nil
            }
        }
        .onChange(of: kind) { _, newKind in
            if newKind != .transfer { statementID = nil }
            if model.snapshot?.categories.contains(where: { $0.id == categoryID && $0.kind == newKind }) != true {
                categoryID = nil
            }
        }
        // Frozen intent is retried exactly. Closing still leaves any accepted event in history.
        .safeAreaInset(edge: .bottom) {
            if pending != nil { Text("重试将使用首次保存的内容，请勿重复新建。")
                .font(.caption).padding().background(CoveStyle.pearlCard) }
        }
        .environment(\.calendar, model.calendar).environment(\.timeZone, model.calendar.timeZone)
    }

    private func save() {
        do {
            if pending == nil {
                guard let accountID else { throw CoveLedgerError.missingAccount }
                if repayment {
                    let latest = try model.repository.load()
                    guard latest.accounts.first(where: { $0.id == accountID })?.type.isLiquid == true,
                          latest.accounts.first(where: { $0.id == destinationID })?.type == .creditCard else {
                        throw CoveLedgerError.invalidAccountType
                    }
                }
                let transaction = CoveLedgerTransaction(kind: kind, amountFen: try CoveLedgerMoney.parse(amount),
                    accountID: accountID, destinationAccountID: kind == .transfer ? destinationID : nil,
                    categoryID: kind == .transfer ? nil : categoryID, note: note, occurredAt: date,
                    statementID: kind == .transfer ? statementID : nil)
                let event = CoveLedgerEvent(id: UUID(), transaction: transaction, reversesID: correcting?.id,
                                            reason: reason, createdAt: Date())
                // Reject editable validation errors before freezing the operation; append revalidates.
                try model.repository.validate(event)
                pending = event
            }
            guard let event = pending else { return }
            try model.append(event)
            dismiss()
        } catch let error as CoveLedgerError {
            pending = nil // A domain failure is a definitive pre-write rejection.
            localError = error.localizedDescription
        } catch {
            localError = error.localizedDescription // IO failure: keep exact intent for explicit retry.
        }
    }
}

private struct CoveLedgerHistory: View {
    @ObservedObject var model: CoveLedgerModel
    private var days: [(date: Date, entries: [CoveLedgerEvent])] {
        guard let snapshot = model.snapshot else { return [] }
        let groups = Dictionary(grouping: snapshot.events) { event in
            let occurred = event.transaction?.occurredAt
                ?? snapshot.events.first(where: { $0.id == event.reversesID })?.transaction?.occurredAt
                ?? event.createdAt
            return model.calendar.startOfDay(for: occurred)
        }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!.sorted(by: CoveLedgerSnapshot.newestFirst)) }
    }
    var body: some View {
        List {
            Section { Text("按发生日期归组，保留全部原记录和更正。已冲销记录不再计入收支。")
                .font(.footnote).foregroundStyle(.secondary) }
            if let snapshot = model.snapshot {
                if snapshot.events.isEmpty { ContentUnavailableView("还没有流水", systemImage: "list.bullet.rectangle") }
                ForEach(days, id: \.date) { day in
                    Section {
                        ForEach(day.entries) { event in
                            NavigationLink { CoveLedgerDetail(model: model, eventID: event.id) } label: {
                                CoveLedgerEventRow(event: event, snapshot: snapshot)
                            }
                        }
                    } header: { Text(day.date, format: .dateTime.year().month().day()) }
                }
            }
            if let error = model.error { CoveLedgerErrorNotice(message: error) }
        }.navigationTitle("全部流水").tint(CoveStyle.accent)
            .environment(\.calendar, model.calendar).environment(\.timeZone, model.calendar.timeZone)
    }
}

private struct CoveLedgerDetail: View {
    @ObservedObject var model: CoveLedgerModel
    let eventID: UUID
    @State private var showingCorrection = false
    @State private var showingVoid = false
    @State private var reason = ""
    @State private var pendingVoid: CoveLedgerEvent?
    @State private var voidError: String?
    var body: some View {
        List {
            if let snapshot = model.snapshot, let event = snapshot.events.first(where: { $0.id == eventID }) {
                Section(event.title) {
                    if let transaction = event.transaction {
                        LabeledContent("金额", value: CoveLedgerMoney.display(transaction.amountFen))
                        LabeledContent("类型", value: transaction.kind.title)
                        LabeledContent("账户", value: snapshot.accountName(transaction.accountID))
                        if let destination = transaction.destinationAccountID {
                            LabeledContent("转入账户", value: snapshot.accountName(destination))
                        }
                        if let category = transaction.categoryID { LabeledContent("分类", value: snapshot.categoryName(category)) }
                        if let statementID = transaction.statementID,
                           let statement = snapshot.statements.first(where: { $0.id == statementID }) {
                            LabeledContent("关联账单到期日") { Text(statement.dueDate, format: .dateTime.year().month().day()) }
                            Text("还款是转账，不计支出；账单更正后继续归入同一账单链。").font(.caption)
                        }
                        LabeledContent("发生时间") { Text(transaction.occurredAt, format: .dateTime.year().month().day().hour().minute()) }
                        if !transaction.note.isEmpty { Text(transaction.note).textSelection(.enabled) }
                    }
                    LabeledContent("记录时间") { Text(event.createdAt, format: .dateTime.year().month().day().hour().minute()) }
                    if !event.reason.isEmpty { LabeledContent("原因", value: event.reason) }
                    Text("操作编号：\(event.id.uuidString)").font(.caption2).textSelection(.enabled)
                }
                Section("更正链") {
                    if let original = event.reversesID {
                        NavigationLink("查看被冲销的原记录") { CoveLedgerDetail(model: model, eventID: original) }
                        Text("冲销按原发生日期重算；更正中的替代记录按其发生日期统计。").font(.caption).foregroundStyle(.secondary)
                    }
                    if let reversal = snapshot.reversal(of: event.id) {
                        NavigationLink(reversal.transaction == nil ? "已作废 · 查看冲销事件" : "已更正 · 查看替代事件") {
                            CoveLedgerDetail(model: model, eventID: reversal.id)
                        }
                    } else if event.transaction != nil {
                        Button("更正这笔记录") { showingCorrection = true }
                        TextField("作废原因（必填）", text: $reason, axis: .vertical).disabled(pendingVoid != nil)
                        Button(pendingVoid == nil ? "作废并追加冲销…" : "用原操作重试作废…", role: .destructive) { showingVoid = true }
                            .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else { Text("这是冲销事件，不可再次冲销。") }
                }
                .sheet(isPresented: $showingCorrection) {
                    NavigationStack { CoveLedgerEntrySheet(model: model, correcting: event) }
                }
                .confirmationDialog("作废后保留原记录，并追加冲销。确定继续？", isPresented: $showingVoid, titleVisibility: .visible) {
                    Button("确认作废", role: .destructive) {
                        let operation = pendingVoid ?? CoveLedgerEvent(id: UUID(), transaction: nil, reversesID: event.id,
                                                                       reason: reason, createdAt: Date())
                        do {
                            try model.repository.validate(operation)
                            pendingVoid = operation
                            try model.append(operation)
                            pendingVoid = nil; voidError = nil
                        } catch let error as CoveLedgerError {
                            pendingVoid = nil; voidError = error.localizedDescription
                        } catch { voidError = error.localizedDescription }
                    }
                }
            }
            if let error = voidError ?? model.error { CoveLedgerErrorNotice(message: error) }
        }.navigationTitle("流水详情").navigationBarTitleDisplayMode(.inline).tint(CoveStyle.accent)
    }
}

private struct CoveLedgerManagement: View {
    @ObservedObject var model: CoveLedgerModel
    @State private var editing: NameEditorTarget?
    private struct NameEditorTarget: Identifiable {
        let id: UUID
        let name: String
        let kind: CoveLedgerKind? // nil means account
    }
    var body: some View {
        List {
            Section("账户") {
                Text("先选账户类型，再核对余额。旧账户不会自动分类。已有核对值或账单时不能改成不兼容类型；历史始终保留。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let snapshot = model.snapshot {
                    let balances = try? snapshot.balances(asOf: Date())
                    ForEach(snapshot.accounts) { account in
                        Button { editing = .init(id: account.id, name: account.name, kind: nil) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                LabeledContent(account.name, value: CoveLedgerBalanceText(account: account, balance: balances?[account.id]))
                                Text(account.type.title).font(.caption).foregroundStyle(.secondary)
                            }.frame(minHeight: 44)
                        }
                    }
                }
                Button("添加账户", systemImage: "plus") { editing = .init(id: UUID(), name: "", kind: nil) }
            }
            ForEach([CoveLedgerKind.expense, .income]) { kind in
                Section("\(kind.title)分类") {
                    ForEach((model.snapshot?.categories ?? []).filter { $0.kind == kind }) { category in
                        Button(category.name) { editing = .init(id: category.id, name: category.name, kind: kind) }
                    }
                    Button("添加\(kind.title)分类", systemImage: "plus") { editing = .init(id: UUID(), name: "", kind: kind) }
                }
            }
            if let error = model.error { CoveLedgerErrorNotice(message: error) }
        }.navigationTitle("账户与分类").tint(CoveStyle.accent)
            .sheet(item: $editing) { target in
                NavigationStack { CoveLedgerNameSheet(model: model, id: target.id, initialName: target.name, kind: target.kind) }
            }
    }
}

private struct CoveLedgerNameSheet: View {
    @ObservedObject var model: CoveLedgerModel
    let id: UUID
    let initialName: String
    let kind: CoveLedgerKind?
    @State private var name = ""
    @State private var accountType: CoveLedgerAccountType = .unclassified
    @State private var initialized = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            TextField("名称", text: $name)
            if kind == nil {
                Picker("账户类型", selection: $accountType) {
                    ForEach(CoveLedgerAccountType.allCases) { Text($0.title).tag($0) }
                }
                Text("未分类账户不计入资产或欠款总计；请按实际用途选择。信用卡账单不能随改名变成储蓄账户。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error = model.error { CoveLedgerErrorNotice(message: error) }
        }.navigationTitle(kind == nil ? "账户名称" : "分类名称").navigationBarTitleDisplayMode(.inline)
            .tint(CoveStyle.accent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if model.perform({
                            if let kind { try model.repository.saveCategory(id: id, name: name, kind: kind) }
                            else { try model.repository.saveAccount(id: id, name: name, type: accountType) }
                        }) { dismiss() }
                    }
                }
            }.onAppear {
                guard !initialized else { return }; initialized = true
                name = initialName
                accountType = model.snapshot?.accounts.first(where: { $0.id == id })?.type ?? .unclassified
            }
    }
}

private struct CoveLedgerBudgetSheet: View {
    @ObservedObject var model: CoveLedgerModel
    let date: Date
    @State private var overall = ""
    @State private var categoryAmounts: [UUID: String] = [:]
    @State private var initialized = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var month: CoveLedgerMonth? { try? CoveLedgerMonth(containing: date, calendar: model.calendar) }
    var body: some View {
        Form {
            Section {
                Text(date, format: .dateTime.year().month())
                Text("预算按当前日历与时区保存：\(model.calendar.timeZone.identifier)。留空表示未设置；填写 0 表示明确的零预算。")
                    .font(.footnote).foregroundStyle(.secondary)
                TextField("月度总预算（元）", text: $overall).keyboardType(.decimalPad)
            }
            Section("分类预算 · 可选") {
                ForEach((model.snapshot?.categories ?? []).filter { $0.kind == .expense }) { category in
                    LabeledContent(category.name) {
                        TextField("未设置", text: Binding(get: { categoryAmounts[category.id] ?? "" }, set: { categoryAmounts[category.id] = $0 }))
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .accessibilityLabel("\(category.name)预算，人民币元")
                    }
                }
                Text("分类预算独立提醒，不与总预算相加，也不会自动拆分总预算。").font(.caption).foregroundStyle(.secondary)
            }
            if let message = error ?? model.error { CoveLedgerErrorNotice(message: message) }
        }.navigationTitle("月度预算").navigationBarTitleDisplayMode(.inline).tint(CoveStyle.accent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }.onAppear {
                guard !initialized else { return }; initialized = true
                if let budget = model.snapshot?.budgets.first(where: { $0.month == month }) {
                    overall = budget.overallFen.map { CoveLedgerMoney.editable($0) } ?? ""
                    categoryAmounts = budget.categoryFen.mapValues { CoveLedgerMoney.editable($0) }
                }
            }
            .environment(\.calendar, model.calendar).environment(\.timeZone, model.calendar.timeZone)
    }
    private func save() {
        do {
            guard let month else { throw CoveLedgerError.invalidDate }
            func parseOptional(_ text: String) throws -> Int64? {
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : try CoveLedgerMoney.parse(text, allowZero: true)
            }
            var categories: [UUID: Int64] = [:]
            for (id, value) in categoryAmounts { if let amount = try parseOptional(value) { categories[id] = amount } }
            let budget = CoveLedgerBudget(month: month, overallFen: try parseOptional(overall), categoryFen: categories)
            if model.perform({ try model.repository.setBudget(budget) }) { dismiss() }
        } catch { self.error = error.localizedDescription }
    }
}

private func CoveLedgerBalanceText(account: CoveLedgerAccount, balance: Int64?) -> String {
    guard let balance else { return "未核对 · 未知" }
    if account.type == .creditCard {
        guard balance != Int64.min else { return "金额超出范围" }
        return balance < 0 ? "欠款 \(CoveLedgerMoney.display(-balance))" : "溢缴款 \(CoveLedgerMoney.display(balance))"
    }
    return CoveLedgerMoney.display(balance)
}

private struct CoveLedgerReconciliationSheet: View {
    @ObservedObject var model: CoveLedgerModel
    @Environment(\.dismiss) private var dismiss
    @State private var accountID: UUID?
    @State private var amount = ""
    @State private var capturedAt = Date()
    @State private var pending: CoveLedgerReconciliation?
    @State private var error: String?
    private var account: CoveLedgerAccount? { model.snapshot?.accounts.first { $0.id == accountID } }
    var body: some View {
        Form {
            if model.isPreview { Text("示例预览 · 仅内存，不保存到设备") }
            Section(account?.type == .creditCard ? "当前欠款（填写正数，元）" : "当前可用余额（元）") {
                TextField("0.00", text: $amount).font(.largeTitle.monospacedDigit()).keyboardType(.decimalPad)
                Picker("账户", selection: $accountID) {
                    Text("请选择").tag(nil as UUID?)
                    ForEach((model.snapshot?.accounts ?? []).filter { $0.type != .unclassified }) { account in
                        Text("\(account.type == .creditCard ? CoveLedgerPreferredCreditAccounts.displayName(for: account) : account.name) · \(account.type.title)")
                            .tag(Optional(account.id))
                    }
                }
                DatePicker("核对时间", selection: $capturedAt, in: ...Date())
                Text("填写此时亲自查到的余额或信用卡欠款，0 表示确认没有余额或欠款，不是未知。信用卡溢缴款暂不支持手动核对。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("每次核对追加保存。以最新核对时间为准，仅之后发生的有效流水改变余额；补记更早的流水不会改变这次观察值。核对不是收入或支出。")
                    .font(.footnote).foregroundStyle(.secondary)
                NavigationLink("添加或分类账户") { CoveLedgerManagement(model: model) }
            }.disabled(pending != nil)
            if let error { CoveLedgerErrorNotice(message: error) }
            Button { save() } label: {
                Text(pending == nil ? "保存余额核对" : "用原操作重试保存").frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.borderedProminent)
            if let snapshot = model.snapshot, let accountID {
                Section("核对历史 · 原记录保留") {
                    ForEach(snapshot.reconciliations.filter { $0.accountID == accountID }.sorted {
                        if $0.capturedAt != $1.capturedAt { return $0.capturedAt > $1.capturedAt }
                        if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                        return $0.id.uuidString > $1.id.uuidString
                    }) { anchor in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(anchor.capturedAt, format: .dateTime.year().month().day().hour().minute().second())
                            if let account { Text(CoveLedgerBalanceText(account: account, balance: anchor.balanceFen)) }
                            LabeledContent("记录于") { Text(anchor.createdAt, format: .dateTime.year().month().day().hour().minute()) }
                                .font(.caption)
                        }
                    }
                }
            }
        }.navigationTitle("核对余额").navigationBarTitleDisplayMode(.inline).tint(CoveStyle.accent)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .environment(\.calendar, model.calendar).environment(\.timeZone, model.calendar.timeZone)
    }
    private func save() {
        do {
            if pending == nil {
                guard let account else { throw CoveLedgerError.missingAccount }
                let value = try CoveLedgerMoney.parse(amount, allowZero: true)
                pending = .init(id: UUID(), accountID: account.id, balanceFen: account.type == .creditCard ? -value : value,
                                capturedAt: capturedAt, createdAt: Date())
            }
            guard let pending else { return }
            try model.repository.appendReconciliation(pending)
            model.reload(); dismiss()
        } catch let error as CoveLedgerError {
            pending = nil; self.error = error.localizedDescription
        } catch { self.error = error.localizedDescription }
    }
}

private struct CoveLedgerStatementSheet: View {
    @ObservedObject var model: CoveLedgerModel
    var correcting: CoveLedgerStatement? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var accountID: UUID?
    @State private var amount = ""
    @State private var minimum = ""
    @State private var statementDate = Date()
    @State private var dueDate = Date()
    @State private var pending: CoveLedgerStatement?
    @State private var initialized = false
    @State private var error: String?
    var body: some View {
        Form {
            if model.isPreview { Text("示例预览 · 仅内存，不保存到设备") }
            Section("账单应还金额（元）") {
                TextField("0.00", text: $amount).font(.largeTitle.monospacedDigit()).keyboardType(.decimalPad)
                Picker("信用卡", selection: $accountID) {
                    Text("请选择").tag(nil as UUID?)
                    ForEach((model.snapshot?.accounts ?? []).filter { $0.type == .creditCard }) {
                        Text(CoveLedgerPreferredCreditAccounts.displayName(for: $0)).tag(Optional($0.id))
                    }
                }.disabled(correcting != nil)
                DatePicker("账单日期", selection: $statementDate, in: ...Date(), displayedComponents: .date)
                DatePicker("还款到期日", selection: $dueDate, in: statementDate..., displayedComponents: .date)
                TextField("最低应还（可选，元）", text: $minimum).keyboardType(.decimalPad)
                Text("账单金额不等于当前欠款，也不会新增支出或改变余额。到期日当天不算逾期；未来 7 天内显示即将到期。这里只记录，不会付款或安排通知。")
                    .font(.footnote).foregroundStyle(.secondary)
                if correcting != nil {
                    Text("更正将追加替代账单，原件与关联还款保留；原账单链上的有效还款自动归入替代账单，不会重复扣减。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                NavigationLink("管理信用卡账户") { CoveLedgerManagement(model: model) }
            }.disabled(pending != nil)
            if let error { CoveLedgerErrorNotice(message: error) }
            Button { save() } label: {
                Text(pending == nil ? (correcting == nil ? "保存账单" : "追加更正账单") : "用原操作重试保存")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.borderedProminent)
            if let correcting {
                Section("原账单 · 不会覆盖") {
                    Text("金额 \(CoveLedgerMoney.display(correcting.amountFen))")
                    LabeledContent("账单日") { Text(correcting.statementDate, format: .dateTime.year().month().day()) }
                    LabeledContent("到期日") { Text(correcting.dueDate, format: .dateTime.year().month().day()) }
                    Text("编号 \(correcting.id.uuidString)").font(.caption)
                }
            }
            if let snapshot = model.snapshot, let accountID {
                Section("账单历史 · 包含已替代原件") {
                    ForEach(snapshot.statements.filter { $0.accountID == accountID }.sorted {
                        $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
                    }) { statement in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(CoveLedgerMoney.display(statement.amountFen)) · \(snapshot.effectiveStatements.contains(where: { $0.id == statement.id }) ? "有效" : "已被替代")")
                            Text(statement.dueDate, format: .dateTime.year().month().day())
                            if statement.supersedesID != nil { Text("关联更正账单").font(.caption) }
                        }
                    }
                }
            }
        }.navigationTitle(correcting == nil ? "录入信用卡账单" : "更正信用卡账单")
            .navigationBarTitleDisplayMode(.inline).tint(CoveStyle.accent)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .onAppear {
                guard !initialized else { return }; initialized = true
                if let correcting {
                    accountID = correcting.accountID; amount = CoveLedgerMoney.editable(correcting.amountFen)
                    minimum = correcting.minimumDueFen.map { CoveLedgerMoney.editable($0) } ?? ""
                    statementDate = correcting.statementDate; dueDate = correcting.dueDate
                } else {
                    statementDate = model.calendar.startOfDay(for: Date()); dueDate = statementDate
                }
            }
            .environment(\.calendar, model.calendar).environment(\.timeZone, model.calendar.timeZone)
    }
    private func save() {
        do {
            if pending == nil {
                guard let accountID else { throw CoveLedgerError.missingAccount }
                let minDue = minimum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : try CoveLedgerMoney.parse(minimum, allowZero: true)
                pending = .init(id: UUID(), accountID: accountID,
                                statementDate: model.calendar.startOfDay(for: statementDate),
                                dueDate: model.calendar.startOfDay(for: dueDate),
                                amountFen: try CoveLedgerMoney.parse(amount, allowZero: true), minimumDueFen: minDue,
                                createdAt: Date(), supersedesID: correcting?.id)
            }
            guard let pending else { return }
            try model.repository.appendStatement(pending)
            model.reload(); dismiss()
        } catch let error as CoveLedgerError {
            pending = nil; self.error = error.localizedDescription
        } catch { self.error = error.localizedDescription }
    }
}

private struct CoveLedgerInstallmentFigures: View {
    let plan: CoveLedgerInstallment
    let cardName: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(plan.label ?? "分期") · \(cardName)").font(.subheadline.bold())
            if plan.isClosed { Text("已关闭 · 不代表付款") }
            else {
                Text("剩余 \(plan.remainingPeriods) 期")
                Text("下期本金 \(CoveLedgerMoney.display(plan.nextPrincipalFen))")
                Text("下期利息 / 手续费 \(CoveLedgerMoney.display(plan.nextInterestFen))")
                if let next = try? plan.nextTotalFen() {
                    Text("下期合计 \(CoveLedgerMoney.display(next))").monospacedDigit()
                } else { CoveLedgerErrorNotice(message: "下期合计超出金额范围") }
                Text("下期到期：\(Text(plan.nextDueDate, format: .dateTime.year().month().day()))")
                Text("剩余本金：\(plan.remainingPrincipalFen.map { CoveLedgerMoney.display($0) } ?? "银行未提供 / 未录入")")
                if plan.amountsRepeat {
                    if let projected = try? plan.projectedTotalFen() {
                        Text("全部剩余预测 \(CoveLedgerMoney.display(projected))（不是当前账单）")
                    } else { CoveLedgerErrorNotice(message: "预测合计超出金额范围") }
                } else { Text("后续金额未确认相同 · 全部剩余预测未知").font(.caption) }
            }
        }.accessibilityElement(children: .combine)
    }
}

private struct CoveLedgerInstallmentHistory: View {
    @ObservedObject var model: CoveLedgerModel
    var body: some View {
        List {
            Text("每次更新与关闭都追加保存，旧数字不改写，也不重复计入当前预测。")
                .font(.footnote)
            if let snapshot = model.snapshot {
                ForEach(snapshot.installments.sorted {
                    $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
                }) { plan in
                    VStack(alignment: .leading, spacing: 8) {
                        CoveLedgerInstallmentFigures(plan: plan, cardName: snapshot.accountName(plan.accountID))
                        Text(snapshot.effectiveInstallments.contains(where: { $0.id == plan.id }) ? "当前有效" : "历史记录")
                            .font(.caption)
                        Text(plan.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                            .font(.caption)
                        Text("修订编号 \(plan.id.uuidString)").font(.caption2).textSelection(.enabled)
                        if let parent = plan.supersedesID {
                            Text("替代编号 \(parent.uuidString)").font(.caption2).textSelection(.enabled)
                        }
                    }
                }
            }
        }.navigationTitle("分期历史").tint(CoveStyle.accent)
    }
}

private struct CoveLedgerInstallmentSheet: View {
    @ObservedObject var model: CoveLedgerModel
    var updating: CoveLedgerInstallment? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var accountID: UUID?
    @State private var label = ""
    @State private var periods = ""
    @State private var remainingPrincipal = ""
    @State private var principal = ""
    @State private var interest = "0"
    @State private var dueDate = Date()
    @State private var amountsRepeat = false
    @State private var initialized = false
    @State private var confirmClose = false
    @State private var pending: CoveLedgerInstallment?
    @State private var error: String?

    private func figures(id: UUID, at: Date) throws -> CoveLedgerInstallment {
        guard let accountID else { throw CoveLedgerError.missingAccount }
        guard let count = Int64(periods.trimmingCharacters(in: .whitespacesAndNewlines)), count > 0 else {
            throw CoveLedgerError.invalidInstallment
        }
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let remaining = remainingPrincipal.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = CoveLedgerInstallment(id: id, planID: updating?.planID, accountID: accountID,
            label: name.isEmpty ? nil : name, remainingPeriods: count,
            remainingPrincipalFen: remaining.isEmpty ? nil : try CoveLedgerMoney.parse(remaining, allowZero: true),
            nextPrincipalFen: try CoveLedgerMoney.parse(principal, allowZero: true),
            nextInterestFen: try CoveLedgerMoney.parse(interest, allowZero: true),
            nextDueDate: model.calendar.startOfDay(for: dueDate), amountsRepeat: amountsRepeat,
            supersedesID: updating?.id, createdAt: at)
        guard try value.nextTotalFen() > 0 else { throw CoveLedgerError.invalidInstallment }
        _ = try value.projectedTotalFen()
        return value
    }

    // Independent of card selection and remaining-period entry: addition is live as soon as both amounts exist.
    private var nextLine: String {
        do {
            let p = try CoveLedgerMoney.parse(principal, allowZero: true)
            let i = try CoveLedgerMoney.parse(interest, allowZero: true)
            return "下期合计 = 本金 + 利息/手续费：\(CoveLedgerMoney.display(try CoveLedgerMoney.add(p, i))) = \(CoveLedgerMoney.display(p)) + \(CoveLedgerMoney.display(i))"
        } catch { return "下期合计 = 本金 + 利息/手续费：\(error.localizedDescription)" }
    }

    private var projectionLine: String {
        do {
            let value = try figures(id: UUID(), at: Date())
            return "全部剩余预测：\(CoveLedgerMoney.display(try value.projectedTotalFen()!))（不是当前账单）"
        } catch { return "预测暂不可计算：\(error.localizedDescription)" }
    }

    var body: some View {
        Form {
            if model.isPreview { Text("示例预览 · 仅内存，不保存到设备") }
            Section("照着银行抄，Cove 帮你相加") {
                Picker("信用卡", selection: $accountID) {
                    Text("请选择").tag(nil as UUID?)
                    ForEach((model.snapshot?.accounts ?? []).filter { $0.type == .creditCard }) {
                        Text(CoveLedgerPreferredCreditAccounts.displayName(for: $0)).tag(Optional($0.id))
                    }
                }.disabled(updating != nil)
                TextField("分期名称（可选，仅本机）", text: $label)
                TextField("剩余期数", text: $periods).keyboardType(.numberPad)
                TextField("剩余本金（可选，元）", text: $remainingPrincipal).keyboardType(.decimalPad)
                Text("剩余本金留空表示银行未提供 / 未录入；填 0 才是明确的零。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("下期本金（元）", text: $principal).keyboardType(.decimalPad)
                TextField("下期利息 / 手续费（元，可填 0）", text: $interest).keyboardType(.decimalPad)
                DatePicker("下期到期日", selection: $dueDate, displayedComponents: .date)
                Toggle("后续每期金额相同", isOn: $amountsRepeat)
                NavigationLink("管理信用卡账户") { CoveLedgerManagement(model: model) }
            }.disabled(pending != nil)
            Section("自动计算") {
                Text(nextLine).monospacedDigit().accessibilityIdentifier("ledger.installment.nextTotal")
                if amountsRepeat {
                    Text(projectionLine).monospacedDigit()
                    Text("预测 = 剩余本金（未提供时用下期本金 × 剩余期数）+ 下期利息/手续费 × 剩余期数。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("后续金额未确认相同：Cove 不会拿一期金额相乘，假装知道全部未来利息。")
                        .font(.footnote)
                }
                Text("不改变当前欠款和账单待还。某期正式出账后，以实际账单为准，再按银行最新数字更新分期，不另记一笔支出或还款。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error { CoveLedgerErrorNotice(message: error) }
            Button { save(close: false) } label: {
                Text(pending == nil ? (updating == nil ? "保存分期" : "追加更新（保留原记录）") : "用原操作重试保存")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.borderedProminent)
            if updating != nil {
                Button(role: .destructive) { confirmClose = true } label: {
                    Text("关闭分期（保留历史）").frame(minHeight: 44)
                }.disabled(pending != nil)
            }
            if pending != nil {
                Text("保存结果未确认，重试只使用原操作与原内容；请勿重复新建。")
                    .font(.caption)
            }
        }.scrollContentBackground(.hidden).background(CoveStyle.pearlCanvas)
            .navigationTitle(updating == nil ? "记录分期" : "更新分期")
            .navigationBarTitleDisplayMode(.inline).tint(CoveStyle.accent)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .confirmationDialog("关闭只移出预测，不代表还款；所有历史保留。确定关闭？", isPresented: $confirmClose, titleVisibility: .visible) {
                Button("确认追加关闭记录", role: .destructive) { save(close: true) }
            }
            .onAppear {
                guard !initialized else { return }; initialized = true
                if let updating {
                    accountID = updating.accountID; label = updating.label ?? ""
                    periods = String(updating.remainingPeriods)
                    remainingPrincipal = updating.remainingPrincipalFen.map { CoveLedgerMoney.editable($0) } ?? ""
                    principal = CoveLedgerMoney.editable(updating.nextPrincipalFen)
                    interest = CoveLedgerMoney.editable(updating.nextInterestFen)
                    dueDate = updating.nextDueDate; amountsRepeat = updating.amountsRepeat
                }
            }
            .environment(\.calendar, model.calendar).environment(\.timeZone, model.calendar.timeZone)
    }

    private func save(close: Bool) {
        do {
            if pending == nil {
                if close, let updating { pending = updating.closing(id: UUID(), createdAt: Date()) }
                else { pending = try figures(id: UUID(), at: Date()) }
            }
            guard let pending else { return }
            try model.repository.appendInstallment(pending)
            model.reload(); dismiss()
        } catch let error as CoveLedgerError {
            pending = nil; self.error = error.localizedDescription
        } catch { self.error = error.localizedDescription }
    }
}

private struct CoveLedgerShareText: Identifiable { let id = UUID(); let text: String }

private struct CoveLedgerSharePreview: View {
    let text: String // Frozen exact text; never regenerated after consent.
    let isPreview: Bool
    let onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmed = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(isPreview ? "示例预览 · 仅内存，不可分享到对话" : "以下是将放入输入框的全部内容。只准备草稿，不会自动发送。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("省略账户及分期名称、交易列表、备注和历史；只含匿名账户余额、账单待还、分期数字预测与月度汇总。预览仅在内存保留。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    guard !confirmed, !isPreview else { return }
                    confirmed = true; onConfirm(text); dismiss()
                } label: {
                    Text("放到对话输入框").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent)
                    .disabled(isPreview || confirmed)
            }.padding(20)
        }.navigationTitle("给 Assistant 的摘要预览").navigationBarTitleDisplayMode(.inline).tint(CoveStyle.accent)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
    }
}

#Preview("个人账本 · 空白示例，不持久化") {
    NavigationStack { CoveLedgerPage(model: .preview()) }
}
