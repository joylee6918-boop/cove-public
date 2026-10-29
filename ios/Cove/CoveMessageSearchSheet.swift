import SwiftUI

struct MessageSearchSheet: View {
    @EnvironmentObject private var store: CoveStore
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var displayedMonth = Self.startOfMonth(Date())
    @State private var selectedDate: String?
    @State private var calendarData: CoveMessageCalendar?
    @State private var firstMonth: String?
    @State private var lastMonth: String?
    @State private var results: [CoveMessageSearchResult] = []
    @State private var nextCursor: String?
    @State private var loadingCalendar = false
    @State private var loadingResults = false
    @State private var loadingMore = false
    @State private var errorText: String?
    @State private var generation = 0
    @State private var refreshTask: Task<Void, Never>?

    private let timeZone = TimeZone.current.identifier
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var monthKey: String { Self.monthFormatter.string(from: displayedMonth) }
    private var shouldShowResults: Bool { selectedDate != nil || !trimmedQuery.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Text("可按日期浏览，也可以搜索所有对话；历史会话不会因切换对话而消失。")
                        .font(.caption).foregroundStyle(CoveStyle.secondaryText)
                    calendarCard
                    if shouldShowResults { resultsSection }
                }
                .padding(16)
            }
            .background(CoveStyle.background)
            .navigationTitle("聊天记录")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索全部聊天记录")
            .onChange(of: query) { scheduleRefresh() }
            .onSubmit(of: .search) { scheduleRefresh(immediate: true) }
            .task { scheduleRefresh(immediate: true) }
            .onDisappear { generation += 1; refreshTask?.cancel() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("返回当前聊天") {
                        resetSearch()
                        dismiss()
                        Task { await store.returnFromMessageSearch() }
                    }
                    .disabled(store.isLocatingMessage)
                    .accessibilityIdentifier("chat.search.returnToCurrent")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.frame(minHeight: 44)
                }
            }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("chat.search.sheet")
    }

    private var calendarCard: some View {
        VStack(spacing: 12) {
            HStack {
                Button { changeMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .disabled(!canMoveBackward).accessibilityIdentifier("chat.search.month.previous")
                Spacer()
                Text(displayedMonth, format: .dateTime.year().month(.wide)).font(.headline)
                Spacer()
                Button { changeMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .disabled(!canMoveForward).accessibilityIdentifier("chat.search.month.next")
            }
            weekdayHeader
            monthGrid
            if loadingCalendar { ProgressView("正在读取月份…").font(.caption) }
            if !loadingCalendar, errorText == nil, let calendarData,
               calendarData.month == monthKey, calendarData.query == trimmedQuery {
                let total = calendarData.days.reduce(0) { $0 + $1.count }
                Text(trimmedQuery.isEmpty ? "本月 \(total) 条消息" : "本月 \(total) 条匹配消息")
                    .font(.caption).foregroundStyle(CoveStyle.secondaryText)
                    .accessibilityIdentifier("chat.search.month.count")
            }
            if let errorText {
                VStack(alignment: .leading, spacing: 6) {
                    Text(errorText).font(.footnote).foregroundStyle(CoveStyle.error)
                    Button("重试") { scheduleRefresh(immediate: true) }
                        .frame(minHeight: 44).accessibilityIdentifier("chat.search.calendar.retry")
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else if !loadingCalendar, (calendarData?.days.isEmpty ?? false), let lastMonth, lastMonth != monthKey {
                Button("前往最近聊天月份") { move(toMonth: lastMonth) }
                    .frame(minHeight: 44).accessibilityIdentifier("chat.search.calendar.latest")
            } else if !loadingCalendar, calendarData != nil, calendarData?.days.isEmpty == true {
                Text(trimmedQuery.isEmpty ? "这个月还没有可见的聊天记录。" : "这个月没有匹配关键词的记录。")
                    .font(.caption).foregroundStyle(CoveStyle.secondaryText)
            }
            if let selectedDate {
                HStack {
                    Text("已选择 \(selectedDate)").font(.caption).foregroundStyle(CoveStyle.secondaryText)
                    Spacer()
                    Button("清除日期") { self.selectedDate = nil; scheduleRefresh(immediate: true) }
                        .font(.caption).frame(minHeight: 44).accessibilityIdentifier("chat.search.date.clear")
                }
            }
        }
        .padding(8)
        .background(CoveStyle.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private var weekdayHeader: some View {
        let names = ["一", "二", "三", "四", "五", "六", "日"]
        return LazyVGrid(columns: Self.calendarColumns, spacing: 2) {
            ForEach(names, id: \.self) { Text($0).font(.caption2).foregroundStyle(CoveStyle.secondaryText) }
        }
    }

    private var monthGrid: some View {
        let cells = Self.days(for: displayedMonth)
        let counts = Dictionary((calendarData?.days ?? []).map { ($0.date, $0.count) }, uniquingKeysWith: +)
        return LazyVGrid(columns: Self.calendarColumns, spacing: 2) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                if let day {
                    let date = Self.dayFormatter.string(from: day)
                    let count = counts[date] ?? 0
                    Button { selectedDate = date; scheduleRefresh(immediate: true) } label: {
                        VStack(spacing: 2) {
                            Text(day, format: .dateTime.day()).font(.subheadline.weight(selectedDate == date ? .bold : .regular))
                            if count > 0 {
                                Text(String(count)).font(.system(size: 9, weight: .semibold))
                                    .lineLimit(1).minimumScaleFactor(0.65)
                            } else {
                                Circle().fill(.clear).frame(width: 3, height: 3)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(selectedDate == date ? Color.white : CoveStyle.text)
                        .background(selectedDate == date ? CoveStyle.accent : (count > 0 ? CoveStyle.softAccent : Color.clear), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain).disabled(count == 0)
                    .accessibilityLabel("\(date)，\(count) 条记录")
                    .accessibilityIdentifier("chat.search.date.\(date)")
                } else {
                    Color.clear.frame(minHeight: 44)
                }
            }
        }
    }

    @ViewBuilder private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(selectedDate == nil ? "搜索结果" : "当天记录").font(.headline)
                Spacer()
                if shouldShowResults {
                    Button("清除筛选") { resetSearch(); scheduleRefresh(immediate: true) }
                        .font(.caption).frame(minHeight: 44).accessibilityIdentifier("chat.search.query.clear")
                }
                if loadingResults { ProgressView().controlSize(.small) }
            }
            if errorText == nil, results.isEmpty, !loadingResults {
                Text(trimmedQuery.isEmpty ? "这一天没有可见消息。" : "没有找到符合日期和关键词的消息。")
                    .font(.subheadline).foregroundStyle(CoveStyle.secondaryText).padding(.vertical, 12)
            }
            ForEach(results) { item in resultRow(item) }
            if nextCursor != nil {
                Button { Task { await loadMore() } } label: {
                    HStack { Spacer(); if loadingMore { ProgressView() } else { Text("加载更多") }; Spacer() }
                        .frame(minHeight: 44)
                }.disabled(loadingMore).accessibilityIdentifier("chat.search.loadMore")
            }
        }
        .padding(14)
        .background(CoveStyle.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func resultRow(_ item: CoveMessageSearchResult) -> some View {
        Button {
            let highlight = trimmedQuery
            dismiss()
            Task { await store.locateMessage(conversationID: item.conversationID, messageID: item.messageID, highlightQuery: highlight) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(item.conversationTitle.isEmpty ? "与 Assistant 的对话" : item.conversationTitle)
                        .font(.caption.weight(.semibold)).foregroundStyle(CoveStyle.accentText).lineLimit(1)
                    Spacer()
                    Text(item.createdAt, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption2).foregroundStyle(CoveStyle.secondaryText)
                }
                Text(CoveSearchHighlight.text(item.snippet, query: trimmedQuery))
                    .font(.subheadline).foregroundStyle(CoveStyle.text).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(item.role == "user" ? "用户" : "Assistant").font(.caption2).foregroundStyle(CoveStyle.secondaryText)
            }.padding(.vertical, 7)
                // A short snippet leaves the center of this full-width plain
                // button empty; the whole result row must still accept taps.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).frame(minHeight: 44)
        .accessibilityIdentifier("chat.search.result.\(item.messageID)")
    }

    private var canMoveBackward: Bool {
        guard !loadingCalendar else { return false }
        guard let firstMonth else { return true }
        return monthKey > firstMonth
    }
    private var canMoveForward: Bool {
        guard !loadingCalendar else { return false }
        guard let lastMonth else { return monthKey < Self.monthFormatter.string(from: Self.startOfMonth(Date())) }
        return monthKey < lastMonth
    }

    private func changeMonth(_ offset: Int) {
        guard let value = Self.gregorian.date(byAdding: .month, value: offset, to: displayedMonth) else { return }
        displayedMonth = value
        scheduleRefresh(immediate: true)
    }

    private func move(toMonth key: String) {
        guard let value = Self.monthFormatter.date(from: key) else { return }
        displayedMonth = value
        scheduleRefresh(immediate: true)
    }

    /// Invalidate pending results as well as both filters; a late page must not
    /// repopulate the list after the user has cleared it.
    private func resetSearch() {
        generation += 1
        refreshTask?.cancel()
        query = ""
        selectedDate = nil
        results = []
        nextCursor = nil
        errorText = nil
        loadingCalendar = false
        loadingResults = false
        loadingMore = false
        store.clearMessageHighlight()
    }

    private func scheduleRefresh(immediate: Bool = false) {
        refreshTask?.cancel()
        generation += 1
        let token = generation
        results = []
        nextCursor = nil
        calendarData = nil
        loadingMore = false
        errorText = nil
        loadingCalendar = true
        loadingResults = shouldShowResults
        refreshTask = Task {
            if !immediate { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled, token == generation else { return }
            await refresh(token: token)
        }
    }

    private func refresh(token: Int) async {
        loadingCalendar = true
        loadingResults = shouldShowResults
        errorText = nil
        if !shouldShowResults { results = []; nextCursor = nil }
        do {
            async let calendar = store.messageCalendar(month: monthKey, query: trimmedQuery, timeZone: timeZone)
            if shouldShowResults {
                async let search = store.searchMessages(query: trimmedQuery, before: nil, date: selectedDate, timeZone: timeZone)
                let (loadedCalendar, loadedSearch) = try await (calendar, search)
                guard token == generation, !Task.isCancelled else { return }
                calendarData = loadedCalendar
                firstMonth = loadedCalendar.firstMonth
                lastMonth = loadedCalendar.lastMonth
                results = loadedSearch.results
                nextCursor = loadedSearch.nextCursor
            } else {
                let loadedCalendar = try await calendar
                guard token == generation, !Task.isCancelled else { return }
                calendarData = loadedCalendar
                firstMonth = loadedCalendar.firstMonth
                lastMonth = loadedCalendar.lastMonth
            }
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            errorText = error.localizedDescription
        }
        guard token == generation else { return }
        loadingCalendar = false; loadingResults = false
    }

    private func loadMore() async {
        guard let cursor = nextCursor, !loadingMore else { return }
        let token = generation
        let expectedQuery = trimmedQuery, expectedDate = selectedDate
        loadingMore = true
        defer { if token == generation { loadingMore = false } }
        do {
            let page = try await store.searchMessages(query: expectedQuery, before: cursor, date: expectedDate, timeZone: timeZone)
            guard token == generation, expectedQuery == trimmedQuery, expectedDate == selectedDate else { return }
            let known = Set(results.map(\.messageID))
            results += page.results.filter { !known.contains($0.messageID) }
            nextCursor = page.nextCursor
        } catch {
            guard token == generation else { return }
            errorText = error.localizedDescription
        }
    }

    private static var gregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = 2
        return calendar
    }
    private static let calendarColumns = Array(repeating: GridItem(.flexible(minimum: 44), spacing: 1), count: 7)
    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = gregorian; formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM"; return formatter
    }()
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = gregorian; formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"; return formatter
    }()
    private static func startOfMonth(_ date: Date) -> Date {
        gregorian.date(from: gregorian.dateComponents([.year, .month], from: date)) ?? date
    }
    private static func days(for month: Date) -> [Date?] {
        guard let range = gregorian.range(of: .day, in: .month, for: month),
              let first = gregorian.date(from: gregorian.dateComponents([.year, .month], from: month)) else { return [] }
        let weekday = gregorian.component(.weekday, from: first)
        let leading = (weekday - gregorian.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading) + range.compactMap { gregorian.date(byAdding: .day, value: $0 - 1, to: first) }.map(Optional.some)
    }
}
