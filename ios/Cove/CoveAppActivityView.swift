import SwiftUI

struct CoveAppActivitySummary: Decodable {
    struct AppUsage: Decodable, Identifiable {
        let name: String
        let seconds: Double
        var id: String { name }
    }
    let day: String
    let timeZone: String
    let source: String
    let totalSeconds: Double
    let apps: [AppUsage]
    let eventCount: Int
    let incomplete: Bool
    let configured: Bool
    let startedAt: String?

    func validated(day: String, timeZone: String) throws -> Self {
        guard self.day == day, self.timeZone == timeZone, source == "cove-shortcuts",
              totalSeconds.isFinite, totalSeconds >= 0, eventCount >= 0, apps.count <= 10000,
              totalSeconds <= 172800 * Double(apps.count),
              Set(apps.map(\.name)).count == apps.count,
              apps.allSatisfy({ !$0.name.isEmpty && $0.seconds.isFinite && $0.seconds >= 0 && $0.seconds <= 172800 }),
              abs(apps.reduce(0) { $0 + $1.seconds } - totalSeconds) < 0.01 else {
            throw CoveError.message("App 记录响应无效，不会作为零时长显示。")
        }
        return self
    }

    static func dayString(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct CoveAppActivityView: View {
    @EnvironmentObject private var store: CoveStore
    @State private var date = Date()
    @State private var summary: CoveAppActivitySummary?
    @State private var error: String?
    @State private var loading = false
    @State private var refreshID = UUID()
    @State private var showingRecording = false
    private var zone: TimeZone { .current }
    private var day: String { CoveAppActivitySummary.dayString(date, timeZone: zone) }
    private var queryID: String { "\(day)|\(zone.identifier)|\(refreshID)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("App 使用 · Cove 独立记录", systemImage: "apps.iphone").font(.headline)
            Text("统计自动化实际送达 Cove 的打开／离开事件，不是系统全量屏幕使用时间。不读取 Seen 或 another assistant 的历史。")
                .font(.caption).foregroundStyle(CoveStyle.secondaryText)
            DatePicker("记录日期", selection: $date, in: ...Date(), displayedComponents: .date)
                .accessibilityIdentifier("appActivity.date")
            Text("时区：\(zone.identifier)").font(.caption).foregroundStyle(CoveStyle.secondaryText)
            if store.previewMode {
                Text("示例预览不会读取 App 使用记录。").font(.footnote)
            } else if !store.isConnected {
                Text("先在设置中连接 Cove，再查看独立记录。").font(.footnote)
            } else if loading {
                ProgressView("读取 Cove 记录…")
            } else if let error {
                Text(error).font(.footnote).foregroundStyle(CoveStyle.error)
            } else if let summary {
                if !summary.configured {
                    Text("Cove 的独立快捷指令入口尚未启用。配置完成后才会开始接收，不会导入 Seen 历史。")
                        .font(.footnote).accessibilityIdentifier("appActivity.unconfigured")
                }
                if summary.eventCount == 0 && summary.apps.isEmpty {
                    Text("这天没有收到记录，不代表没有使用手机。").font(.subheadline)
                } else {
                    Text("已配对时长 \(duration(summary.totalSeconds)) · \(summary.eventCount) 条当日事件")
                        .font(.subheadline.weight(.medium))
                    ForEach(summary.apps) { app in
                        HStack {
                            Text(app.name)
                            Spacer()
                            Text(duration(app.seconds)).foregroundStyle(CoveStyle.secondaryText)
                        }.font(.subheadline)
                    }
                }
                if summary.incomplete {
                    Text("部分打开／离开事件缺失或尚未配对；只显示已确认的时长，不猜测缺失部分。")
                        .font(.caption).foregroundStyle(CoveStyle.secondaryText)
                }
            }
            Button { refreshID = UUID() } label: { Label("刷新记录", systemImage: "arrow.clockwise") }
                .frame(minHeight: 44).disabled(loading || store.previewMode || !store.isConnected)
                .accessibilityIdentifier("appActivity.refresh")
            Button { showingRecording = true } label: {
                Label("自动记录与双端同步", systemImage: "arrow.triangle.2.circlepath")
            }.disabled(store.previewMode)
            Text("原生动作先存手机，再独立补传给已配置的接收端；旧的联网自动化保持停用。")
                .font(.caption).foregroundStyle(CoveStyle.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(CoveStyle.card, in: RoundedRectangle(cornerRadius: 14))
        .task(id: queryID) { await load() }
        .sheet(isPresented: $showingRecording) {
            if !store.previewMode {
                NavigationStack { CoveActivityRecordingView() }
            }
        }
    }

    private func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分钟" : "\(minutes) 分钟"
    }

    @MainActor private func load() async {
        let expected = queryID
        summary = nil
        error = nil
        guard !store.previewMode, store.isConnected else { return }
        loading = true
        defer { if queryID == expected { loading = false } }
        do {
            let result = try await store.loadAppActivity(day: day, timeZone: zone.identifier)
            guard !Task.isCancelled, queryID == expected else { return }
            summary = result
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, queryID == expected else { return }
            self.error = error.localizedDescription
        }
    }
}
