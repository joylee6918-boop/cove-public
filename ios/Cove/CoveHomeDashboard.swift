import SwiftUI
import EventKit

/// A quiet shelf in our home, not a second settings page.
struct CoveHomeDashboard: View {
    let refreshID: UUID
    @EnvironmentObject private var store: CoveStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicType
    @StateObject private var life = CoveHomeLifeModel(backend: CoveAppleDeviceBackend())
    @StateObject private var fitness: CoveFitnessModel
    @StateObject private var ledger: CoveLedgerModel
    @State private var selected: CoveSystemCapability?
    @State private var localRefreshID = UUID()
    @State private var now = Date()
    @State private var usage: CoveAppActivitySummary?
    @State private var usageError: String?
    @State private var usageLoading = false
    @State private var usageLoadedAt: Date?

    init(refreshID: UUID, previewMode: Bool) {
        self.refreshID = refreshID
        _fitness = StateObject(wrappedValue: previewMode ? .preview() : .live)
        _ledger = StateObject(wrappedValue: previewMode ? .preview() : .live)
    }

    private var active: Bool { store.selectedTab == 0 && scenePhase == .active }
    private var day: String { CoveAppActivitySummary.dayString(now, timeZone: .current) }
    private var localQueryID: String { "\(active)|\(store.previewMode)|\(day)|\(TimeZone.current.identifier)|\(refreshID)|\(localRefreshID)" }
    private var usageQueryID: String { "\(localQueryID)|\(store.appActivityScopeID)" }

    var body: some View {
        VStack(spacing: CovePearlLayout.sectionSpacing) {
            lifeCard
            livingShelf
        }
        .sheet(item: $selected, onDismiss: { localRefreshID = UUID() }) { capability in
            NavigationStack {
                CoveHomeLifeDetail(capability: capability, model: life, preview: store.previewMode)
            }
        }
        .task(id: localQueryID) {
            life.invalidate()
            guard active else { return }
            await life.refresh(preview: store.previewMode)
        }
        .task(id: usageQueryID) { await loadUsage() }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            if active { localRefreshID = UUID() }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { date in
            // Updates featured event and crosses midnight without re-reading every minute.
            if active { now = date }
        }
        .onChange(of: active) { _, value in if value { now = Date() } }
        .onReceive(NotificationCenter.default.publisher(for: .covePersonalLedgerDidChange)
            .receive(on: RunLoop.main)) { _ in
            if !ledger.isPreview { ledger.reload() }
        }
    }

    private var lifeCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("今天，放在家里").font(.system(.headline, design: .serif))
                    Text(now.formatted(.dateTime.month().day().weekday(.wide)))
                        .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                }
                Spacer(minLength: 0)
                Button { now = Date(); localRefreshID = UUID() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                }
                .accessibilityLabel("刷新家里的日程、提醒和 App 记录")
                .accessibilityIdentifier("home.life.refresh")
            }.padding(.bottom, 12)
            ForEach([CoveSystemCapability.calendar, .reminders, .alarms]) { capability in
                if capability != .calendar { Divider().overlay(CoveStyle.pearlBorderStrong.opacity(0.2)) }
                Button { selected = capability } label: { lifeRow(capability) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.life.\(capability.rawValue)")
                    .accessibilityHint("查看\(capability.title)列表，或管理系统权限")
            }
            Text("日历与提醒留在本机 · 闹钟仅显示 Cove 创建的")
                .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(CoveStyle.pearlInk).covePearlCard()
    }

    private func lifeRow(_ capability: CoveSystemCapability) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: capability.symbol).font(.title3.weight(.light))
                .foregroundStyle(CoveStyle.accentText).frame(width: 26, height: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(capability == .alarms ? "Cove 闹钟" : capability.title)
                    .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                switch life.states[capability] ?? .waiting {
                case .waiting, .loading:
                    Text("正在读取…").font(.subheadline)
                case .permission(let status):
                    Text(permissionText(status)).font(.subheadline)
                case .failed:
                    Text("暂时读不到 · 点开重试").font(.subheadline)
                case .ready(let records, _):
                    if let record = CoveHomeLifeModel.featured(records, capability: capability, now: now) {
                        Text(record.title).font(.subheadline.weight(.medium)).lineLimit(2)
                        Text(CoveHomeLifeModel.dateLabel(record, capability: capability, now: now))
                            .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                        if records.count > 1 {
                            Text(capability == .reminders ? "\(records.count == 50 ? "至少 " : "")\(records.count) 项未完成" : "查看\(records.count == 50 ? "前 " : "")\(records.count) 项")
                                .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                        }
                    } else {
                        Text(records.count == 50 ? "已读取前 50 项 · 点开查看" : emptyText(capability)).font(.subheadline)
                    }
                }
            }.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(CoveStyle.pearlSecondary).padding(.top, 7)
        }
        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.vertical, 14).contentShape(Rectangle())
    }

    private var livingShelf: some View {
        VStack(alignment: .leading, spacing: CovePearlLayout.contentSpacing) {
            VStack(alignment: .leading, spacing: 5) {
                CovePearlSectionTitle("生活")
                Text("真实记录，分别保存在它们自己的空间")
                    .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
            }
            LazyVGrid(columns: livingColumns, alignment: .leading, spacing: 12) {
                healthCard
                usageEntry
                CoveFitnessHomeCard(model: fitness)
                CoveLedgerHomeCard(model: ledger, assistantAccessStatus: store.personalLedgerSyncStatus)
            }
        }
    }

    private var livingColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
              count: dynamicType.isAccessibilitySize ? 1 : 2)
    }

    private var healthCard: some View {
        Button { store.selectedTab = 3 } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("健康", systemImage: "heart.text.square").font(.headline)
                        .foregroundStyle(CoveStyle.dataBlue)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.caption)
                }
                if let metric = store.health?.metrics.first {
                    Text("\(metric.title) \(metric.value.formatted(.number.precision(.fractionLength(0...1)))) \(metric.unit)")
                        .font(.subheadline).lineLimit(2)
                    Text("采样于 \(metric.sampledAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                } else {
                    Text(store.previewMode ? "预览不读取真实健康数据" : "还没有本机健康记录")
                        .font(.subheadline)
                    Text("读取后留在本机")
                        .font(.caption).foregroundStyle(CoveStyle.pearlSecondary)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            .padding(18).foregroundStyle(CoveStyle.pearlInk).covePearlCard()
        }
        .buttonStyle(.plain).accessibilityIdentifier("home.health")
        .accessibilityHint("打开健康页")
    }

    private var usageEntry: some View {
        NavigationLink {
            ScrollView { CoveAppActivityView().padding(20) }
                .navigationTitle("App 使用记录").navigationBarTitleDisplayMode(.inline)
        } label: { usageCard }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.appActivity")
        .accessibilityHint("查看完整 App 使用记录和其他日期")
    }

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("App 使用", systemImage: "apps.iphone").font(.headline)
                    .foregroundStyle(CoveStyle.dataLilac)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption)
            }
            if store.previewMode {
                usageNote("预览不读取使用记录", detail: "连接后显示已配对时长")
            } else if !store.isConnected {
                usageNote("等待连接 Cove", detail: "连接后显示快捷指令记录")
            } else if usageLoading {
                ProgressView("读取记录…").font(.subheadline)
            } else if usageError != nil {
                usageNote("暂时读不到记录", detail: "点开查看或重试")
            } else if let usage {
                if !usage.configured {
                    usageNote("快捷指令尚未接入", detail: "接入后才开始记录")
                } else if usage.eventCount == 0 && usage.apps.isEmpty {
                    usageNote("今天还没有收到记录", detail: "这不代表没有使用手机")
                } else {
                    Text(CoveHomeLifeModel.duration(usage.totalSeconds))
                        .font(.system(.title3, design: .rounded).weight(.medium)).monospacedDigit()
                    Text(usage.apps.first.map { "最多 · \($0.name)" } ?? "\(usage.eventCount) 条当日事件")
                        .font(.caption).foregroundStyle(CoveStyle.pearlSecondary).lineLimit(1)
                }
            } else {
                Text("等待读取记录").font(.subheadline)
            }
            Text("来自 Cove 快捷指令，不是系统屏幕使用时间。")
                .font(.caption2).foregroundStyle(CoveStyle.pearlSecondary).lineLimit(2)
        }
        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        .padding(18).foregroundStyle(CoveStyle.pearlInk).covePearlCard().contentShape(Rectangle())
    }

    private func usageNote(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.medium)).lineLimit(2)
            Text(detail).font(.caption).foregroundStyle(CoveStyle.pearlSecondary).lineLimit(2)
        }
    }

    @MainActor private func loadUsage() async {
        let expected = usageQueryID
        usage = nil; usageError = nil; usageLoadedAt = nil; usageLoading = false
        guard active, !store.previewMode, store.isConnected else { return }
        usageLoading = true
        defer { if usageQueryID == expected { usageLoading = false } }
        do {
            let result = try await store.loadAppActivity(day: day, timeZone: TimeZone.current.identifier)
            guard !Task.isCancelled, expected == usageQueryID else { return }
            usage = result; usageLoadedAt = Date()
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, expected == usageQueryID else { return }
            usageError = error.localizedDescription
        }
    }
}

private func permissionText(_ status: CoveCapabilityStatus) -> String {
    switch status {
    case .preview: return "预览 · 不读取本机内容"
    case .notDetermined: return "未授权 · 点开去允许"
    case .writeOnly: return "仅允许写入 · 还不能读取"
    case .denied, .restricted: return "\(status.title) · 点开查看权限"
    default: return "\(status.title) · 点开查看"
    }
}

private func emptyText(_ capability: CoveSystemCapability) -> String {
    switch capability {
    case .calendar: return "未来 7 天暂没有接下来的日程"
    case .reminders: return "没有未完成的提醒事项"
    case .alarms: return "还没有 Cove 闹钟"
    }
}

private struct CoveHomeLifeDetail: View {
    let capability: CoveSystemCapability
    @ObservedObject var model: CoveHomeLifeModel
    let preview: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                switch model.states[capability] ?? .waiting {
                case .waiting, .loading: ProgressView("读取本机内容…")
                case .permission(let status): Text(permissionText(status))
                case .failed(let message):
                    Label("读取失败，不代表没有记录", systemImage: "exclamationmark.circle")
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                case .ready(let records, let date):
                    if records.isEmpty { Text(emptyText(capability)).foregroundStyle(.secondary) }
                    // Repeating events can share the EventKit ID; offsets preserve each occurrence.
                    ForEach(Array(records.enumerated()), id: \.offset) { _, record in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record.title).font(.body)
                            Text(CoveHomeLifeModel.dateLabel(record, capability: capability)).font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 5)
                    }
                    Text("读取于 \(date.formatted(date: .omitted, time: .shortened))\(records.count == 50 ? " · 最多显示前 50 项" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text(capability == .calendar ? "今天起 7 天" : capability == .reminders ? "未完成提醒" : "Cove 管理的闹钟") }
            Section {
                NavigationLink { CoveSystemCapabilitiesView(preview: preview) } label: {
                    Label("权限与本机操作", systemImage: "slider.horizontal.3").frame(minHeight: 44)
                }
            } footer: {
                Text(capability == .alarms ? "这里不读取苹果时钟 App 的闹钟。创建或取消 Cove 闹钟仍需你明确确认。" : "仅显示本机已授权内容，不会因打开家页上传，也不会自动修改日程或提醒事项。")
            }
        }
        .navigationTitle(capability == .alarms ? "Cove 闹钟" : capability.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() }.frame(minHeight: 44) }
        }
        .task { await model.refresh(preview: preview) }
        .refreshable { await model.refresh(preview: preview) }
    }
}
