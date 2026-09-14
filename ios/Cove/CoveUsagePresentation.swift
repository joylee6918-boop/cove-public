import Foundation

enum CoveUsagePresentation {
    static func planName(_ raw: String?) -> String {
        switch raw?.lowercased() {
        case "pro", "prolite": return "Pro"
        case "plus": return "Plus"
        case .some(let value): return value
        case .none: return "未知"
        }
    }

    // Also normalize the previous backend response during a staged upgrade.
    // Model-specific Spark buckets must never stand in for account limits.
    static func accountWindows(_ windows: [UsageWindow]) -> [UsageWindow] {
        var selected: [String: UsageWindow] = [:]
        for var window in windows {
            let kind: String
            switch window.id {
            case "codex-5h": kind = "5h"
            case "codex-weekly": kind = "weekly"
            case "codex-primary", "codex-secondary":
                let title = window.title.replacingOccurrences(of: " ", with: "")
                if title.contains("5小时") { kind = "5h" }
                else if title.contains("每周") || title.contains("周额度") { kind = "weekly" }
                else { continue }
            default: continue
            }
            guard window.usedPercent.isFinite else { continue }
            window.id = "codex-" + kind
            window.title = kind == "5h" ? "5 小时窗口" : "周额度"
            selected[kind] = window
        }
        return ["5h", "weekly"].compactMap { selected[$0] }
    }
}
