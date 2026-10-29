import Foundation

/// Server-authored metadata from a verified WeatherKit call, never inferred from prose.
struct CoveWeatherAttribution: Codable, Equatable {
    let required: Bool
    let serviceName: String
    let markLightURL: String
    let markDarkURL: String
    let markLightData: String
    let markDarkData: String
    let legalURLs: [String]
    let sourceValidAt: String
    let fetchedAt: String
    let expiresAt: String
    let timezone: String

    static func appleURL(_ raw: String) -> URL? {
        guard raw.count <= 2048, !raw.contains("\\"), !raw.contains(where: { $0.isWhitespace }),
              let url = URL(string: raw), url.scheme == "https",
              url.host?.lowercased() == "weatherkit.apple.com", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return nil }
        return url
    }

    var safeLegalURLs: [URL] {
        guard (1...4).contains(legalURLs.count) else { return [] }
        return Array(Set(legalURLs.compactMap { raw in
            ["https://developer.apple.com/weatherkit/data-source-attribution/",
             "https://weatherkit.apple.com/legal-attribution.html"].contains(raw) ? URL(string: raw) : nil
        })).sorted { $0.absoluteString < $1.absoluteString }
    }

    func markData(dark: Bool) -> Data? {
        let raw = dark ? markDarkData : markLightData
        guard raw.utf8.count <= 350_000, let data = Data(base64Encoded: raw),
              (33...262_144).contains(data.count),
              data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]),
              data[8..<16] == Data([0, 0, 0, 13, 73, 72, 68, 82]) else { return nil }
        let width = data[16..<20].reduce(0) { $0 * 256 + Int($1) }
        let height = data[20..<24].reduce(0) { $0 * 256 + Int($1) }
        return (1...2048).contains(width) && (1...1024).contains(height) ? data : nil
    }

    var sourceDate: Date? {
        Self.date(sourceValidAt)
    }

    static func date(_ value: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    /// This is provenance validation, not a claim that old weather is still live.
    var isValidForPreview: Bool {
        required && !serviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && timezone == "Asia/Shanghai" && (1...4).contains(legalURLs.count)
            && legalURLs.allSatisfy { raw in safeLegalURLs.contains(where: { $0.absoluteString == raw }) }
            && Self.appleURL(markLightURL) != nil && Self.appleURL(markDarkURL) != nil
            && markData(dark: false) != nil && markData(dark: true) != nil
            && sourceDate != nil && Self.date(fetchedAt) != nil && Self.date(expiresAt) != nil
    }

    static func beijingTime(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "zh_CN")
        format.timeZone = TimeZone(identifier: "Asia/Shanghai")
        format.dateFormat = "MM-dd HH:mm"
        return format.string(from: date) + "（北京时间）"
    }
}
