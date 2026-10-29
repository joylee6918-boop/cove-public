import Foundation

struct CoveSessionContext: Codable {
    let conversationID: String
    let threadID: String?
    let usedTokens: Int?
    let contextWindow: Int?
    let switchAtTokens: Int
    let updatedAt: Date?
    let source: String?
    let error: String?
    var handoffAvailable: Bool? = nil
    var handoffError: String? = nil
    var compactionCount: Int? = nil
    var lastCompactedAt: Date? = nil
    var compactionError: String? = nil

    var compactionReminder: String? {
        guard let compactionCount, compactionCount >= 2 else { return nil }
        return "本窗口已压缩 \(compactionCount) 次，可在话题结束后准备交接换窗。不会自动切换。"
    }

    var recommendsSwitch: Bool { (usedTokens ?? -1) >= switchAtTokens }
    var progress: Double? {
        guard let usedTokens, usedTokens >= 0, switchAtTokens > 0 else { return nil }
        return min(Double(usedTokens) / Double(switchAtTokens), 1)
    }
}

struct CoveSessionHandoff: Codable {
    let id: String
    let sourceConversationID: String
    let targetConversationID: String?
    let status: String
    let error: String?
    let createdAt: Date
    let updatedAt: Date

    var isRunning: Bool { status == "saving" || status == "restoring" }
    var statusText: String {
        switch status {
        case "saving": return "正在保存交接与待记事项…"
        case "restoring": return "正在新窗接续最近 20 轮与未完事项…"
        case "complete": return "上下文已接上"
        case "failed": return "换窗未完成，旧对话仍保留"
        default: return "正在确认换窗进度…"
        }
    }
}
