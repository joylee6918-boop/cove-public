import SwiftUI

enum CoveHomeMemoryError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { if case .unavailable(let message) = self { return message }; return nil }
}

enum CoveHomeDates {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        value.locale = Locale(identifier: "zh_CN")
        value.firstWeekday = 2
        return value
    }
    static let anniversary = calendar.date(from: DateComponents(year: 2026, month: 8, day: 20))!
    static func togetherDay(on date: Date) -> Int {
        max(0, (calendar.dateComponents([.day], from: anniversary, to: calendar.startOfDay(for: date)).day ?? -1) + 1)
    }
    static func month(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year!, parts.month!)
    }
    static func day(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    static func date(_ month: String) -> Date? {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, (1900...9998).contains(parts[0]), (1...12).contains(parts[1]),
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)),
              self.month(date) == month else { return nil }
        return date
    }
    static func days(in month: String) -> [String] {
        guard let first = date(month), let range = calendar.range(of: .day, in: .month, for: first) else { return [] }
        return range.map { String(format: "%@-%02d", month, $0) }
    }
    static func leadingBlanks(in month: String) -> Int {
        guard let first = date(month) else { return 0 }
        return (calendar.component(.weekday, from: first) + 5) % 7
    }
    static func timestamp(_ date: Date, includeDate: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = includeDate ? "yyyy-MM-dd HH:mm" : "HH:mm"
        return formatter.string(from: date)
    }
}

struct CoveMemoryCalendarEnvelope: Decodable {
    struct Day: Decodable, Identifiable {
        let date: String
        let count: Int
        var id: String { date }
    }
    let month: String
    let timezone: String
    let source: String
    let metric: String
    let days: [Day]
    let updatedAt: Date
    let total: Int

    func validated(for month: String) throws -> Self {
        let expected = Set(CoveHomeDates.days(in: month))
        guard self.month == month, timezone == "Asia/Shanghai", source == "ombre", metric == "created",
              !expected.isEmpty, days.count == expected.count, Set(days.map(\.date)) == expected,
              days.allSatisfy({ (0...10_000_000).contains($0.count) }), total == days.reduce(0, { $0 + $1.count }) else {
            throw CoveHomeMemoryError.unavailable("OB 日历数据不完整，暂时无法显示密度。")
        }
        return self
    }
    static func preview(month: String) -> Self {
        let days = CoveHomeDates.days(in: month).enumerated().map { index, date in
            Day(date: date, count: index % 4 == 0 ? 3 : index % 3 == 0 ? 1 : 0)
        }
        return Self(month: month, timezone: "Asia/Shanghai", source: "ombre", metric: "created", days: days, updatedAt: Date(), total: days.reduce(0, { $0 + $1.count }))
    }
}

struct CoveTogetherCard: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 10) {
                Label("我们在一起", systemImage: "heart").font(.headline).foregroundStyle(CoveStyle.accentText)
                Text("第 \(CoveHomeDates.togetherDay(on: context.date)) 天")
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .accessibilityIdentifier("home.togetherDays")
                Text("2026.08.20 · 表明心意的那一天")
                    .font(.subheadline).foregroundStyle(CoveStyle.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(CoveStyle.card, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct CoveMemoryCalendarCard: View {
    var usesHomeSurface = false
    @EnvironmentObject private var store: CoveStore
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var month = CoveHomeDates.month(Date())
    @State private var selectedDay: String?
    @State private var value: CoveMemoryCalendarEnvelope?
    @State private var error: String?
    @State private var loading = false
    @State private var refreshID = 0
    private var scope: String { "\(store.collarScopeID)|\(store.isConnected)|\(store.previewMode)|\(month)|\(refreshID)" }
    private var counts: [String: Int] { Dictionary(uniqueKeysWithValues: (value?.days ?? []).map { ($0.date, $0.count) }) }
    private var today: String { CoveHomeDates.day(Date()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("记忆密度", systemImage: "calendar").font(.headline)
                Spacer()
                if loading { ProgressView().accessibilityLabel("正在读取 OB 日历") }
                Button { refreshID += 1 } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                }.disabled(loading).accessibilityLabel("刷新记忆日历")
            }
            Text(store.previewMode ? "示例日历 · 合成数据，不连接 OB" : "来自 OB · 按现存记忆的初次存入日期统计")
                .font(.caption).foregroundStyle(CoveStyle.secondaryText)
            HStack {
                Button { moveMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .accessibilityLabel("上个月").accessibilityIdentifier("home.memory.previous")
                Spacer(minLength: 0)
                Text(month.replacingOccurrences(of: "-", with: " 年 ") + " 月").font(.headline).monospacedDigit()
                    .accessibilityIdentifier("home.memory.month")
                Spacer(minLength: 0)
                Button { moveMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .disabled(month >= CoveHomeDates.month(Date()))
                    .accessibilityLabel("下个月").accessibilityIdentifier("home.memory.next")
            }
            if dynamicType.isAccessibilitySize {
                dateList
            } else {
                ViewThatFits(in: .horizontal) {
                    grid.frame(minWidth: 308)
                    dateList
                }
            }
            if let value {
                Text("本月 \(value.total) 条").font(.subheadline.weight(.medium))
                    .accessibilityIdentifier("home.memory.total")
                if let selectedDay, let count = counts[selectedDay] {
                    Text("\(selectedDay) · \(count) 条记忆")
                        .font(.subheadline).accessibilityIdentifier("home.memory.selection")
                }
                HStack(spacing: 5) {
                    Text("少")
                    ForEach([0, 1, 3, 6, 10], id: \.self) { count in
                        RoundedRectangle(cornerRadius: 3).fill(density(count)).frame(width: 15, height: 12)
                    }
                    Text("多").padding(.trailing, 4)
                    Text("点日期查看条数")
                }.font(.caption).foregroundStyle(CoveStyle.secondaryText).accessibilityHidden(true)
                Text("更新于 \(CoveHomeDates.timestamp(value.updatedAt)) · 北京时间")
                    .font(.caption).foregroundStyle(CoveStyle.secondaryText)
            } else if let error {
                Text(error).font(.footnote).foregroundStyle(CoveStyle.secondaryText)
                    .accessibilityIdentifier("home.memory.error")
            }
            Text("深浅表示记忆条数，不代表感情的多少。含已归档记录；已删除或合并掉的记忆不计入，无法还原过去全部写入次数。读取不会改写 OB。")
                .font(.caption).foregroundStyle(CoveStyle.secondaryText)
        }
        .foregroundStyle(CoveStyle.text).tint(CoveStyle.accentText)
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CoveHomeModuleSurface(enabled: usesHomeSurface))
        .task(id: scope) { await load() }
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 44), spacing: 0), count: 7), spacing: 4) {
            ForEach(Array(["一", "二", "三", "四", "五", "六", "日"].enumerated()), id: \.offset) { _, day in
                Text(day).font(.caption).foregroundStyle(CoveStyle.secondaryText).frame(height: 24).accessibilityHidden(true)
            }
            ForEach(0..<CoveHomeDates.leadingBlanks(in: month), id: \.self) { _ in Color.clear.frame(height: 44).accessibilityHidden(true) }
            ForEach(CoveHomeDates.days(in: month), id: \.self) { date in
                Button { selectedDay = date } label: {
                    VStack(spacing: 3) {
                        Text(String(Int(date.suffix(2))!)).font(.subheadline.monospacedDigit())
                        RoundedRectangle(cornerRadius: 2).fill(density(counts[date])).frame(width: 22, height: 5)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(selectedDay == date ? CoveStyle.softAccent : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(date == today ? CoveStyle.accentText : .clear, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(date > today || value == nil)
                .opacity(date > today ? 0.35 : 1)
                .accessibilityLabel("\(date)，\(counts[date].map { "\($0) 条记忆" } ?? "尚未读取")")
                .accessibilityIdentifier("home.memory.day.\(date)")
            }
        }
    }
    private var dateList: some View {
        VStack(spacing: 4) {
            ForEach(CoveHomeDates.days(in: month).filter { $0 <= today }, id: \.self) { date in
                Button { selectedDay = date } label: {
                    HStack {
                        Text(date)
                        Spacer()
                        Text(counts[date].map { "\($0) 条" } ?? "未读取")
                    }.font(.body).frame(minHeight: 44)
                }.disabled(value == nil)
            }
        }
    }
    private func density(_ count: Int?) -> Color {
        guard let count, count > 0 else { return CoveStyle.border.opacity(0.45) }
        return CoveStyle.accent.opacity(count >= 10 ? 1 : count >= 6 ? 0.8 : count >= 3 ? 0.6 : 0.3)
    }
    private func moveMonth(_ offset: Int) {
        guard let current = CoveHomeDates.date(month), let next = CoveHomeDates.calendar.date(byAdding: .month, value: offset, to: current) else { return }
        month = CoveHomeDates.month(next); value = nil; selectedDay = nil; error = nil
    }
    private func load() async {
        let stamp = scope, requestedMonth = month
        value = nil; error = nil; loading = true
        defer { if stamp == scope { loading = false } }
        do {
            let result: CoveMemoryCalendarEnvelope
            if store.previewMode {
                result = .preview(month: requestedMonth)
            } else {
                guard store.isConnected else { throw CoveHomeMemoryError.unavailable("连接 Cove 后读取 OB 记忆日历；未连接不等于没有记忆。") }
                result = try await store.loadMemoryCalendar(month: requestedMonth)
            }
            guard !Task.isCancelled, stamp == scope else { return }
            value = try result.validated(for: requestedMonth)
            if requestedMonth == CoveHomeDates.month(Date()) { selectedDay = today }
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled, stamp == scope else { return }
            self.error = error.localizedDescription
        }
    }
}
