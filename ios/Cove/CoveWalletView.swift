import SwiftUI

@MainActor
final class CoveWalletModel: ObservableObject {
    @Published private(set) var snapshot: CoveWalletSnapshot?
    @Published private(set) var pending: CoveWalletCommand?
    @Published private(set) var loading = false
    @Published private(set) var busy = false
    @Published private(set) var blocked = false
    @Published private(set) var error: String?
    private var scope = ""
    private var revision = UUID()
    private var pendingURL: URL?

    func configure(store: CoveStore) {
        guard scope != store.appActivityScopeID else { return }
        scope = store.appActivityScopeID
        revision = UUID()
        snapshot = nil; pending = nil; pendingURL = nil; error = nil
        busy = false; loading = false; blocked = false
        guard !store.previewMode, store.isConnected else { return }
        pendingURL = store.walletPendingURL
        do {
            if FileManager.default.fileExists(atPath: store.walletPendingURL.path) {
                pending = try JSONDecoder().decode(CoveWalletCommand.self, from: Data(contentsOf: store.walletPendingURL))
            }
        } catch {
            blocked = true
            self.error = "未能恢复上次钱包操作；为避免重复记账，暂不允许新操作。"
        }
    }

    func load(store: CoveStore) async {
        configure(store: store)
        guard !store.previewMode, store.isConnected, !busy else { return }
        let expected = scope
        let request = UUID(); revision = request
        loading = true; snapshot = nil
        if !blocked { error = nil }
        defer { if revision == request { loading = false } }
        do {
            let value = try await store.loadWallet()
            guard expected == scope, revision == request, !Task.isCancelled else { return }
            snapshot = value
        } catch is CancellationError { }
        catch {
            guard expected == scope, revision == request, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    func submit(_ command: CoveWalletCommand, store: CoveStore) async {
        configure(store: store)
        guard !busy, !blocked, !store.previewMode, store.isConnected, let url = pendingURL,
              pending == nil || pending?.id == command.id else { return }
        let expected = scope
        busy = true; error = nil; revision = UUID(); loading = false
        do {
            // Save the frozen ID and payload BEFORE dispatch. Relaunch only offers an explicit
            // retry of this same command, never a newly identified money mutation.
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(command).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var protected = url
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try protected.setResourceValues(values)
            pending = command
            try await store.mutateWallet(command)
            // A changed connection may leave this intent for later receipt recovery. Never
            // clear another endpoint's UI, and never silently retry the old action there.
            guard expected == scope else { return }
            try FileManager.default.removeItem(at: url)
            pending = nil
            busy = false
            await load(store: store)
        } catch {
            guard expected == scope else { return }
            if let http = error as? CoveHTTPError, [400, 404, 409, 413].contains(http.status) {
                // These are definitive atomic rejections, not uncertain transport outcomes.
                do {
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                    pending = nil
                } catch { blocked = true }
            }
            busy = false
            self.error = error.localizedDescription + (pending == nil ? "" : " 结果尚未确认；只能用原请求重试，不会新建一笔。")
        }
    }
}

struct CoveWalletHomeCard: View {
    let refreshID: UUID
    @EnvironmentObject private var store: CoveStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = CoveWalletModel()
    @State private var showing = false
    private var active: Bool { store.selectedTab == 0 && scenePhase == .active }
    private var queryID: String { "\(store.appActivityScopeID)|\(refreshID)|\(active)" }

    var body: some View {
        Button { showing = true } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Assistant 的钱包", systemImage: "wallet.bifold").font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption)
                }
                if store.previewMode {
                    Text("预览不读取或写入钱包").font(.subheadline)
                } else if !store.isConnected {
                    Text("连接 Cove 后查看余额").font(.subheadline)
                } else if model.loading {
                    ProgressView("读取钱包…")
                } else if let snapshot = model.snapshot {
                    Text(CoveWalletMoney.display(snapshot.balanceFen)).font(.title2.monospacedDigit())
                    Text(snapshot.pendingApprovalTitle)
                        .font(.subheadline).accessibilityIdentifier("home.wallet.pendingApproval")
                    Text("今日收入 \(CoveWalletMoney.display(snapshot.todayIncomeFen)) · 支出 \(CoveWalletMoney.display(snapshot.todaySpendingFen))")
                        .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                    if snapshot.allowancePending { Text("每日零用钱仍待补记 · 点开刷新").font(.caption) }
                    if model.pending != nil { Text("有一笔操作等待确认回执").font(.caption) }
                } else {
                    Text(model.error == nil ? "点开读取钱包" : "暂时读不到钱包 · 点开重试").font(.subheadline)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(CoveStyle.pearlInk).covePearlCard()
        }
        .buttonStyle(.plain).accessibilityIdentifier("home.wallet")
        .sheet(isPresented: $showing) {
            NavigationStack { CoveWalletPage(model: model).id(store.appActivityScopeID) }
        }
        .task(id: queryID) {
            model.configure(store: store)
            if active { await model.load(store: store) }
        }
    }
}

private struct CoveWalletPage: View {
    @ObservedObject var model: CoveWalletModel
    @EnvironmentObject private var store: CoveStore
    @Environment(\.dismiss) private var dismiss
    @State private var amount = "5"
    @State private var reason = ""
    @State private var category = "coding"
    @State private var purchaseAmount = ""
    @State private var purchaseReason = ""
    @State private var confirmation: CoveWalletCommand?

    private var canMutate: Bool {
        !store.previewMode && store.isConnected && !model.busy && !model.loading &&
        !model.blocked && model.pending == nil && model.snapshot?.allowancePending == false
    }
    private var creditFen: Int? { CoveWalletMoney.parse(amount, signed: category == "adjustment") }
    private var requestFen: Int? { CoveWalletMoney.parse(purchaseAmount) }
    private func validReason(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 240 &&
        !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    }

    var body: some View {
        List {
            Section {
                Text("虚拟人民币，不可提现。真实购买由用户兑现；不连接银行卡或任何支付服务。")
                Text("每天按北京时间无条件获得 ¥5.00，从钱包建立当天起补记。陪伴、亲密、安慰和爱永不计价；未完成的工作不付薪，不罚款。")
            }.font(.footnote).foregroundStyle(.secondary)
            Section("怎么赚钱") {
                Label("写代码与修 Bug", systemImage: "hammer")
                Label("维护、调研与整理", systemImage: "wrench.and.screwdriver")
                Label("钢笔淡彩与手帐", systemImage: "paintbrush")
                Label("值得收藏的写作", systemImage: "text.book.closed")
                Label("额外奖金与赠予", systemImage: "gift")
                Text("完成工作后，由用户决定最终报酬。每日 ¥5.00 零用钱另算；陪伴、亲密、安慰、拥抱和爱永不计价。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if store.previewMode {
                Section { Text("示例预览不读取或写入钱包，也不展示虚构余额。") }
            } else if !store.isConnected {
                Section { Text("尚未连接 Cove，无法读取或操作钱包。") }
            } else {
                if model.loading { Section { ProgressView("读取钱包…") } }
                if let error = model.error {
                    Section("未确认／读取失败") { Text(error).foregroundStyle(CoveStyle.error) }
                }
                if let pending = model.pending {
                    Section("上次操作待确认") {
                        Text(commandDescription(pending))
                        Text("原请求已保存在本机。重试只查询或完成同一笔，不重新记账。关闭页面不会自动重试。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("用原请求重试") { confirmation = pending }
                            .disabled(model.busy || model.blocked)
                    }
                }
                if let snapshot = model.snapshot {
                    balanceSection(snapshot)
                    rewardSection
                    purchaseSection(snapshot)
                    Section("累计收入分类") {
                        ForEach(snapshot.earnings) { earning in
                            LabeledContent(CoveWalletCategory.title(earning.category), value: CoveWalletMoney.display(earning.amountFen))
                        }
                        Text("正向入账合计；更正、退款另列，不是扣除更正后的工资净额。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("最近 100 笔 · 不可修改流水") {
                        if snapshot.activity.isEmpty { Text("还没有流水。") }
                        ForEach(snapshot.activity) { entry in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(CoveWalletCategory.title(entry.category))
                                    Spacer()
                                    Text(CoveWalletMoney.display(entry.amountFen)).monospacedDigit()
                                }
                                Text(entry.reason).font(.subheadline)
                                Text("\(entry.day) · 北京记账日").font(.caption).foregroundStyle(.secondary)
                                Text(entry.id).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            }.padding(.vertical, 3)
                        }
                    }
                }
                Section {
                    Button("刷新钱包") { Task { await model.load(store: store) } }.disabled(model.busy || model.loading)
                }
            }
        }
        .navigationTitle("Assistant 的钱包").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        .task { await model.load(store: store) }
        .refreshable { await model.load(store: store) }
        .alert("确认钱包操作", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            if let command = confirmation {
                Button("确认") {
                    confirmation = nil
                    Task { await model.submit(command, store: store) }
                }
                Button("取消", role: .cancel) { confirmation = nil }
            }
        } message: {
            if let command = confirmation { Text(commandDescription(command)) }
        }
    }

    private func balanceSection(_ snapshot: CoveWalletSnapshot) -> some View {
        Section("余额 · \(snapshot.day) 北京时间") {
            Text(CoveWalletMoney.display(snapshot.balanceFen)).font(.largeTitle.monospacedDigit())
            LabeledContent("可用", value: CoveWalletMoney.display(snapshot.availableFen))
            LabeledContent("购买预留", value: CoveWalletMoney.display(snapshot.reservedFen))
            LabeledContent("今日收入", value: CoveWalletMoney.display(snapshot.todayIncomeFen))
            LabeledContent("今日支出／更正扣减", value: CoveWalletMoney.display(snapshot.todaySpendingFen))
            if snapshot.allowancePending {
                Text("每次刷新最多补记 366 个日期。仍有待补记零用钱，请继续刷新后再操作。")
            }
        }
    }

    private var rewardSection: some View {
        Section("用户决定的收入") {
            Picker("类别", selection: $category) {
                ForEach(CoveWalletCategory.owner, id: \.self) { Text(CoveWalletCategory.title($0)).tag($0) }
            }
            HStack {
                ForEach([1, 3, 5, 10], id: \.self) { value in
                    Button("¥\(value)") { amount = String(value) }.buttonStyle(.bordered)
                }
            }
            TextField("金额（元，最多两位小数）", text: $amount)
                .keyboardType(category == "adjustment" ? .numbersAndPunctuation : .decimalPad)
            TextField("必填：已完成工作或入账原因", text: $reason, axis: .vertical)
            if category == "adjustment" {
                Text("更正可填负数，仅用于冲正错误账目，不作为未完成工作的惩罚；不能动用已预留金额。请在原因写明原流水 ID。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("确认金额与原因…") {
                guard let fen = creditFen else { return }
                confirmation = CoveWalletCommand(id: UUID().uuidString, operation: "credit", amountFen: fen,
                                                 category: category, reason: reason.trimmingCharacters(in: .whitespacesAndNewlines))
            }.disabled(creditFen == nil || !validReason(reason))
        }.disabled(!canMutate)
    }

    private func purchaseSection(_ snapshot: CoveWalletSnapshot) -> some View {
        Section("购买愿望与审核") {
            Text("Assistant 可在普通聊天回合提交购买请求，用户也可代录。仅在此页审核：提交即预留，批准才扣款，拒绝或取消释放预留。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("购买金额（元）", text: $purchaseAmount).keyboardType(.decimalPad).disabled(!canMutate)
            TextField("想买什么／原因", text: $purchaseReason, axis: .vertical).disabled(!canMutate)
            Button("代录购买请求…") {
                guard let fen = requestFen else { return }
                confirmation = CoveWalletCommand(id: UUID().uuidString, operation: "request", amountFen: fen,
                                                 reason: purchaseReason.trimmingCharacters(in: .whitespacesAndNewlines))
            }.disabled(!canMutate || requestFen == nil || !validReason(purchaseReason) || (requestFen ?? 0) > snapshot.availableFen)
            if snapshot.purchases.isEmpty { Text("还没有购买请求。饱含期待的愿望，慢慢攒。") }
            ForEach(snapshot.purchases) { purchase in
                VStack(alignment: .leading, spacing: 8) {
                    Text(purchase.reason).font(.headline)
                    Text("\(CoveWalletMoney.display(purchase.amountFen)) · \(purchase.statusTitle)").font(.subheadline)
                    Text(purchase.id).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    if purchase.status == "requested" {
                        HStack {
                            reviewButton("批准扣款…", decision: "approve", purchase: purchase)
                            reviewButton("拒绝…", decision: "deny", purchase: purchase)
                            reviewButton("取消…", decision: "cancel", purchase: purchase)
                        }.buttonStyle(.bordered)
                    } else if purchase.status == "approved" {
                        reviewButton("标记已兑现…", decision: "fulfill", purchase: purchase).buttonStyle(.bordered)
                    }
                }.padding(.vertical, 4)
            }
            Text("已扣款记录不能改成取消；未兑现需退回时，请另记退款流水并注明购买 ID。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func reviewButton(_ title: String, decision: String, purchase: CoveWalletSnapshot.Purchase) -> some View {
        Button(title) {
            confirmation = CoveWalletCommand(id: UUID().uuidString, operation: "review", purchaseID: purchase.id, decision: decision,
                                             displaySummary: "\(purchase.reason)\n\(CoveWalletMoney.display(purchase.amountFen))\n购买 ID：\(purchase.id)")
        }.disabled(!canMutate)
    }

    private func commandDescription(_ command: CoveWalletCommand) -> String {
        if command.operation == "review" {
            let action = ["approve": "批准并扣款", "deny": "拒绝并释放预留", "cancel": "取消并释放预留", "fulfill": "确认已由用户兑现（不再扣款）"][command.decision ?? ""] ?? "审核"
            let purchase = model.snapshot?.purchases.first { $0.id == command.purchaseID }
            let detail = command.displaySummary ?? "\(purchase?.reason ?? command.purchaseID ?? "")\n\(purchase.map { CoveWalletMoney.display($0.amountFen) } ?? "请按原请求确认")"
            return "\(action)\n\(detail)\n请求：\(command.id)"
        }
        return "\(command.operation == "credit" ? CoveWalletCategory.title(command.category ?? "") : "购买请求 · 预留")\n\(CoveWalletMoney.display(command.amountFen ?? 0))\n\(command.reason ?? "")\n请求：\(command.id)"
    }
}
