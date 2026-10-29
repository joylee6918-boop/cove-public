import SwiftUI

enum CoveSearchHighlight {
    /// Literal matching only; user input is never interpreted as a regex/markup.
    static func ranges(in source: String, query: String) -> [Range<String.Index>] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var start = source.startIndex
        while start < source.endIndex,
              let range = source.range(of: needle, options: [.caseInsensitive], range: start..<source.endIndex) {
            ranges.append(range)
            start = range.upperBound
        }
        return ranges
    }

    static func text(_ source: String, query: String) -> AttributedString {
        var result = AttributedString()
        var start = source.startIndex
        for range in ranges(in: source, query: query) {
            result += AttributedString(String(source[start..<range.lowerBound]))
            var match = AttributedString(String(source[range]))
            match.backgroundColor = Color.yellow.opacity(0.8)
            match.foregroundColor = Color.black
            result += match
            start = range.upperBound
        }
        result += AttributedString(String(source[start...]))
        return result
    }
}

struct CoveMessageCalendar: Decodable {
    let month: String
    let timeZone: String
    let query: String
    let firstMonth: String?
    let lastMonth: String?
    let days: [CoveMessageCalendarDay]
}

struct CoveMessageCalendarDay: Decodable, Identifiable {
    let date: String
    let count: Int
    var id: String { date }
}

struct CoveMessageHighlight: Equatable {
    let conversationID: String
    let messageID: String
    let query: String
}

enum CoveChatCalendarDates {
    static func formatter(_ pattern: String, timeZone: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: timeZone)
        formatter.dateFormat = pattern
        formatter.isLenient = false
        return formatter
    }

    static func valid(_ value: String, pattern: String, timeZone: String) -> Bool {
        guard TimeZone(identifier: timeZone) != nil else { return false }
        let formatter = formatter(pattern, timeZone: timeZone)
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }
}
