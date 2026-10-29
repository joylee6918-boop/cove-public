import SwiftUI

struct CoveHealthHistoryIndex {
    struct DayGroup: Identifiable {
        let day: String
        let entries: [CoveHealthArchiveEntry]
        var id: String { day }
    }

    let months: [String]
    private let daysByMonth: [String: [DayGroup]]
    private let entryCountsByMonth: [String: Int]

    init(entries: [CoveHealthArchiveEntry],
         monthKey: (Date) -> String = CoveHomeDates.month,
         dayKey: (Date) -> String = CoveHomeDates.day) {
        var grouped: [String: [String: [CoveHealthArchiveEntry]]] = [:]
        var counts: [String: Int] = [:]
        for entry in entries {
            let month = monthKey(entry.recordedAt)
            let day = dayKey(entry.recordedAt)
            grouped[month, default: [:]][day, default: []].append(entry)
            counts[month, default: 0] += 1
        }
        months = grouped.keys.sorted(by: >)
        daysByMonth = grouped.mapValues { days in
            days.keys.sorted(by: >).map { DayGroup(day: $0, entries: days[$0] ?? []) }
        }
        entryCountsByMonth = counts
    }

    func activeMonth(selectedMonth: String) -> String {
        months.contains(selectedMonth) ? selectedMonth : (months.first ?? "")
    }

    func days(in month: String) -> [DayGroup] { daysByMonth[month] ?? [] }
    func entryCount(in month: String) -> Int { entryCountsByMonth[month] ?? 0 }
}

struct CoveHealthHistoryView: View {
    @EnvironmentObject private var store: CoveStore
    @State private var selectedMonth = ""
    var body: some View {
        let index = CoveHealthHistoryIndex(entries: store.healthArchiveEntries)
        let activeMonth = index.activeMonth(selectedMonth: selectedMonth)
        let days = index.days(in: activeMonth)
        VStack(alignment: .leading, spacing: 14) {
            Label("留在本机的健康记录", systemImage: "clock.arrow.circlepath").font(.headline)
            if store.previewMode { Text("合成示例 · 未读取真实健康数据").font(.caption).foregroundStyle(CoveStyle.accentText) }
            Text("每次读取分别保存，不会被下一次覆盖。按北京时间归档；不会自动上传，也不进入 iCloud 备份。")
                .font(.caption).foregroundStyle(CoveStyle.secondaryText)
            if let error = store.healthArchiveError {
                Text(error).font(.footnote).foregroundStyle(CoveStyle.error)
            }
            if index.months.isEmpty {
                Text(store.previewMode ? "示例预览不会读取或保存真实健康历史。" : "还没有保存的读取记录。从这次更新起，读取后会留在这里；过去未保存的本机快照无法恢复。")
                    .font(.subheadline).foregroundStyle(CoveStyle.secondaryText)
                    .accessibilityIdentifier("health.history.empty")
            } else {
                Picker("记录月份", selection: Binding(get: { activeMonth }, set: { selectedMonth = $0 })) {
                    ForEach(index.months, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu).frame(minHeight: 44).accessibilityIdentifier("health.history.month")
                Text("本月 \(days.count) 天 · \(index.entryCount(in: activeMonth)) 次读取")
                    .font(.subheadline).accessibilityIdentifier("health.history.count")
                ForEach(days) { group in
                    DisclosureGroup("\(group.day) · \(group.entries.count) 次") {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(group.entries) { entry in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(CoveHomeDates.timestamp(entry.recordedAt, includeDate: false))
                                        .font(.subheadline.weight(.semibold))
                                    Text(entry.origin == .manual ? "手动在本机读取" : entry.origin == .standing ? "持续授权下读取" : "为一次健康请求读取")
                                        .font(.caption).foregroundStyle(CoveStyle.secondaryText)
                                    Text(entry.sharingStatusText).font(.caption).foregroundStyle(CoveStyle.secondaryText)
                                    if entry.snapshot.metrics.isEmpty {
                                        Text("本次没有可读取的指标，不代表数值为零。").font(.footnote)
                                    }
                                    ForEach(entry.snapshot.metrics) { metric in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("\(metric.title)：\(metric.value.formatted(.number.precision(.fractionLength(0...1)))) \(metric.unit)")
                                                .font(.subheadline)
                                            Text("采样 \(CoveHomeDates.timestamp(metric.sampledAt))")
                                                .font(.caption).foregroundStyle(CoveStyle.secondaryText)
                                            if let detail = metric.detail, !detail.isEmpty {
                                                Text(detail).font(.caption).foregroundStyle(CoveStyle.secondaryText)
                                            }
                                            if let source = metric.source, !source.isEmpty {
                                                Text("来源：\(source)").font(.caption2).foregroundStyle(CoveStyle.secondaryText)
                                            }
                                        }
                                    }
                                    if let segments = entry.snapshot.sleepSegments, !segments.isEmpty {
                                        Text("睡眠阶段").font(.subheadline.weight(.semibold)).padding(.top, 4)
                                        ForEach(segments) { segment in
                                            HStack(alignment: .firstTextBaseline) {
                                                Text(CoveHealthScope.title(segment.stageID))
                                                Spacer()
                                                Text("\(CoveHomeDates.timestamp(segment.startAt, includeDate: false))–\(CoveHomeDates.timestamp(segment.endAt, includeDate: false))")
                                                    .foregroundStyle(CoveStyle.secondaryText)
                                            }.font(.caption)
                                        }
                                    }
                                    if let workouts = entry.snapshot.workouts, !workouts.isEmpty {
                                        Text("健身记录").font(.subheadline.weight(.semibold)).padding(.top, 4)
                                        ForEach(workouts) { workout in
                                            VStack(alignment: .leading, spacing: 3) {
                                                HStack {
                                                    Text(workout.type).font(.subheadline.weight(.medium))
                                                    Spacer()
                                                    Text((workout.durationSeconds / 60).formatted(.number.precision(.fractionLength(0...1))) + " 分钟")
                                                        .font(.caption).foregroundStyle(CoveStyle.secondaryText)
                                                }
                                                Text("\(CoveHomeDates.timestamp(workout.startAt))–\(CoveHomeDates.timestamp(workout.endAt, includeDate: false))")
                                                    .font(.caption).foregroundStyle(CoveStyle.secondaryText)
                                                let facts = [
                                                    workout.energyKcal.map { $0.formatted(.number.precision(.fractionLength(0...1))) + " 千卡" },
                                                    workout.distanceMeters.map { ($0 / 1000).formatted(.number.precision(.fractionLength(0...2))) + " 公里" }
                                                ].compactMap { $0 }
                                                if !facts.isEmpty { Text(facts.joined(separator: " · ")).font(.caption).foregroundStyle(CoveStyle.secondaryText) }
                                            }
                                        }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if entry.id != group.entries.last?.id { Divider() }
                            }
                        }.padding(.vertical, 10)
                    }.font(.subheadline).frame(minHeight: 44)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(CoveStyle.card, in: RoundedRectangle(cornerRadius: 14))
    }
}
