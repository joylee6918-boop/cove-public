import Foundation

/// Presentation only: keep all stored messages. Like CCC, start with 30 eager
/// rows and expand only on explicit history navigation. The default tail stays
/// bounded even after hours of sends; browsing pins stable boundary IDs so an
/// incoming message cannot evict a row the user is reading.
struct CoveChatRenderWindow {
    static let pageSize = 30
    private(set) var conversationID: String?
    private(set) var firstID: String?
    private(set) var lastID: String? // nil follows the live tail

    func range(in messages: [ChatMessage], conversationID: String) -> Range<Int> {
        guard self.conversationID == conversationID, let firstID,
              let first = messages.firstIndex(where: { $0.id == firstID }) else {
            return max(0, messages.count - Self.pageSize)..<messages.count
        }
        let end = lastID.flatMap { id in messages.firstIndex(where: { $0.id == id }).map { $0 + 1 } } ?? messages.count
        return first..<max(first, end)
    }

    mutating func prepare(_ messages: [ChatMessage], conversationID: String) {
        if self.conversationID != conversationID || (firstID != nil && !messages.contains(where: { $0.id == firstID })) {
            firstID = nil
            lastID = nil
        }
        self.conversationID = conversationID
    }

    mutating func pinForReading(_ messages: [ChatMessage], conversationID: String) {
        prepare(messages, conversationID: conversationID)
        let range = range(in: messages, conversationID: conversationID)
        firstID = range.isEmpty ? nil : messages[range.lowerBound].id
    }

    mutating func earlier(_ messages: [ChatMessage], conversationID: String) {
        prepare(messages, conversationID: conversationID)
        let range = range(in: messages, conversationID: conversationID)
        guard !messages.isEmpty else { return }
        firstID = messages[max(0, range.lowerBound - Self.pageSize)].id
    }

    mutating func later(_ messages: [ChatMessage], conversationID: String) {
        prepare(messages, conversationID: conversationID)
        let end = min(messages.count, range(in: messages, conversationID: conversationID).upperBound + Self.pageSize)
        lastID = end == messages.count ? nil : messages[end - 1].id
    }

    mutating func locate(_ id: String, in messages: [ChatMessage], conversationID: String) {
        pinForReading(messages, conversationID: conversationID)
        guard let index = messages.firstIndex(where: { $0.id == id }),
              !range(in: messages, conversationID: conversationID).contains(index) else { return }
        firstID = messages[max(0, index - Self.pageSize / 2)].id
        let end = min(messages.count, index + Self.pageSize / 2 + 1)
        lastID = end == messages.count ? nil : messages[end - 1].id
    }

    mutating func latest(_ messages: [ChatMessage], conversationID: String) {
        // Do not collapse expanded live history on send/keyboard/scroll-bottom.
        // Only an explicit return from a bounded search window changes windows.
        if self.conversationID != conversationID || lastID != nil { self = Self() }
        prepare(messages, conversationID: conversationID)
    }
}

struct ChatMessage: Identifiable, Codable, Equatable {
    var id: String
    var conversationID: String
    var role: String
    var text: String
    var createdAt: Date
    var status: String
    var replyTo: String? = nil
    var attachmentURL: String? = nil
    var error: String? = nil
    var attachments: [ChatAttachment]? = nil
    var readAt: Date? = nil
    var isLiked: Bool? = nil
    var revision: Int? = nil
    var stickerID: String? = nil
    var travelSceneID: String? = nil
    var weatherAttribution: CoveWeatherAttribution? = nil
    /// Public Codex summary, independent from the reply body and previews.
    var thinkingSummary: String? = nil
    /// Deliberately authored public aside, not private reasoning.
    var littleThoughts: String? = nil

    /// Compact surfaces cannot carry the required official mark/legal footer.
    /// Keep full weather prose in the attributed bubble, never infer from words.
    func previewText(emptyFallback: String = "附件") -> String {
        if role == "assistant", weatherAttribution?.isValidForPreview == true {
            return "北京天气消息，打开查看"
        }
        return text.isEmpty ? (attachments?.first?.filename ?? emptyFallback) : text
    }

    /// A final message needs visible content. Keep streaming and failure rows so
    /// progress/errors remain legible, but never draw a completed whitespace-only
    /// bubble if an older server revision leaks one into the local cache.
    var isVisibleInChat: Bool {
        guard status == "complete" else { return true }
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachment = attachments?.isEmpty == false || attachmentURL != nil
        return hasText || hasAttachment
    }

    var readyForDisplay: ChatMessage {
        guard role == "assistant", status == "streaming" else { return self }
        var pending = self
        pending.text = ""
        pending.attachments = nil
        pending.attachmentURL = nil
        pending.stickerID = nil
        pending.revision = nil
        pending.weatherAttribution = nil
        pending.littleThoughts = nil
        return pending
    }

    func mergingServerUpdate(_ incoming: ChatMessage) -> ChatMessage {
        guard incoming.id == id, incoming.conversationID == conversationID else { return self }
        if let currentRevision = revision, let nextRevision = incoming.revision, nextRevision < currentRevision { return self }
        var updated = incoming
        // The optimistic user row already owns a stable position. A delayed
        // upload ACK/server clock must not move it past later local sends.
        if role == "user" {
            updated.createdAt = createdAt
            if updated.travelSceneID == nil { updated.travelSceneID = travelSceneID }
        }
        // Read receipts are monotonic even when connecting to an older server.
        if updated.readAt == nil { updated.readAt = readAt }
        return updated
    }
}

struct ChatAttachment: Identifiable, Codable, Equatable {
    var id: String
    var filename: String
    var mime: String
    var size: Int
    var url: String
}

struct CoveOutgoingFile {
    var data: Data
    var filename: String
    var mime: String
}

struct CoveSticker: Identifiable, Codable, Equatable {
    var id: String
    var owner: String
    var label: String
    var createdAt: Date
    var attachment: ChatAttachment
}

struct Conversation: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var createdAt: Date
}

/// One hit from GET v1/messages/search. Snippets are server-trimmed context.
struct CoveMessageSearchResult: Decodable, Identifiable, Equatable {
    var conversationID: String
    var conversationTitle: String
    var messageID: String
    var role: String
    var snippet: String
    var createdAt: Date
    var id: String { messageID }
}

/// A one-shot request for ChatView to reveal a located message. The UUID makes
/// repeated locates of the same message observable again.
struct CoveScrollRequest: Equatable {
    let id = UUID()
    let messageID: String
}

struct PulseMetric: Identifiable, Codable {
    var id: String
    var label: String
    var value: Double
    var detail: String
}

struct PulseSnapshot: Codable {
    var updatedAt: Date
    var summary: String
    var desires: [PulseMetric]
    var physical: [PulseMetric]
    var senses: [PulseMetric]
}

struct PulseVitals: Codable, Equatable {
    var heartRate: Double
    var temperature: Double
    var breathingRate: Double
    var breathingDepth: String
    var chord: String
    var activity: String
    var emotion: String
    var source: String
}

struct PulseHeartbeat: Codable, Equatable {
    var lastTickAt: Date?
    var lastWakeAt: Date?
    var intervalSeconds: Int
    var quiet: Bool
    var nextTickAt: Date?
}

struct PulseEnvironment: Codable, Equatable {
    var timeOfDay: String
    var weather: String?
    var temperature: Double?
    var source: String
    var updatedAt: Date?
}

struct PulseDashboardSnapshot: Codable {
    var updatedAt: Date
    var summary: String
    var physical: [PulseMetric]
    var senses: [PulseMetric]
    var desires: [PulseMetric]
    var vitals: PulseVitals?
    var heartbeat: PulseHeartbeat?
    var environment: PulseEnvironment?

    var legacySnapshot: PulseSnapshot {
        .init(updatedAt: updatedAt, summary: summary, desires: desires, physical: physical, senses: senses)
    }
}

struct PulseHistoryPoint: Codable, Identifiable, Equatable {
    var id: String
    var at: Date
    var heartRate: Double
    var temperature: Double
    var breathingRate: Double
}

struct PulseAction: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var status: String
    var detail: String?
}

struct PulseWakeEvent: Codable, Identifiable, Equatable {
    var id: String
    var createdAt: Date
    var completedAt: Date?
    var reason: String
    var status: String
    var thoughtSummary: String?
    var actions: [PulseAction]
    var resultSummary: String?
    var conversationID: String?
    var messageID: String?
}

struct PulseMurmur: Codable, Identifiable, Equatable {
    var id: String
    var createdAt: Date
    var text: String
    var source: String
}

struct PulseDashboard: Codable {
    var generatedAt: Date
    var snapshot: PulseDashboardSnapshot
    var history: [PulseHistoryPoint]
    var events: [PulseWakeEvent]
    var murmurs: [PulseMurmur]
    var warnings: [String]
}

struct UsageWindow: Identifiable, Codable {
    var id: String
    var title: String
    var usedPercent: Double
    var resetsAt: Date?
}

struct UsageSnapshot: Codable {
    var plan: String?
    var updatedAt: Date
    var windows: [UsageWindow]
    var error: String?
}

struct HealthMetric: Identifiable, Codable {
    var id: String
    var title: String
    var value: Double
    var unit: String
    var sampledAt: Date
    var detail: String? = nil
    var source: String? = nil
}

struct CoveSleepSegment: Codable, Identifiable {
    var stageID: String
    var startAt: Date
    var endAt: Date
    var source: String? = nil
    var id: String { "\(stageID)|\(startAt.timeIntervalSinceReferenceDate)|\(endAt.timeIntervalSinceReferenceDate)|\(source ?? "")" }
}

struct CoveWorkout: Codable, Identifiable {
    var id: String
    var type: String
    var startAt: Date
    var endAt: Date
    var durationSeconds: Double
    var energyKcal: Double? = nil
    var distanceMeters: Double? = nil
    var source: String? = nil
}

struct HealthSnapshot: Codable {
    var capturedAt: Date
    var metrics: [HealthMetric]
    /// Optional for backward-compatible decoding of snapshots saved by older builds.
    var sleepSegments: [CoveSleepSegment]? = nil
    var workouts: [CoveWorkout]? = nil
}

/// Read-only summaries supported by the local reader and the one-time consent card.
/// A request still names an exact subset; this is not blanket consent or an automatic read.
enum CoveHealthScope {
    static let metricIDs: Set<String> = [
        "sleep", "sleepAwake", "sleepCore", "sleepDeep", "sleepREM", "sleepUnspecified",
        "restingHeartRate", "heartRate", "walkingHeartRate", "heartRateRecovery", "hrv",
        "oxygenSaturation", "respiratoryRate", "vo2Max", "bodyMass", "height", "bodyMassIndex",
        "bodyFatPercentage", "bloodPressureSystolic", "bloodPressureDiastolic", "bloodGlucose",
        "bodyTemperature", "sleepingWristTemperature", "dietaryWater", "steps", "activeEnergy", "basalEnergy", "exerciseTime",
        "standTime", "walkingRunningDistance", "cyclingDistance", "flightsClimbed",
        "workoutCount", "workoutDuration"
    ]
    static func title(_ id: String) -> String {
        switch id {
        case "sleep": "睡眠"
        case "sleepAwake": "清醒"
        case "sleepCore": "核心睡眠"
        case "sleepDeep": "深度睡眠"
        case "sleepREM": "快速眼动睡眠"
        case "sleepUnspecified": "未分类睡眠"
        case "restingHeartRate": "静息心率"
        case "heartRate": "最近一次心率"
        case "walkingHeartRate": "步行平均心率"
        case "heartRateRecovery": "心率恢复"
        case "steps": "步数"
        case "hrv": "HRV"
        case "oxygenSaturation": "血氧饱和度"
        case "respiratoryRate": "呼吸频率"
        case "vo2Max": "最大摄氧量"
        case "bodyMass": "体重"
        case "height": "身高"
        case "bodyMassIndex": "BMI"
        case "bodyFatPercentage": "体脂率"
        case "bloodPressureSystolic": "收缩压"
        case "bloodPressureDiastolic": "舒张压"
        case "bloodGlucose": "血糖"
        case "bodyTemperature": "体温"
        case "sleepingWristTemperature": "睡眠腕温"
        case "dietaryWater": "饮水量"
        case "activeEnergy": "活动能量"
        case "basalEnergy": "静息能量"
        case "exerciseTime": "锻炼时间"
        case "standTime": "站立时间"
        case "walkingRunningDistance": "步行与跑步距离"
        case "cyclingDistance": "骑行距离"
        case "flightsClimbed": "已爬楼层"
        case "workoutCount": "健身次数"
        case "workoutDuration": "健身时长"
        default: "不支持的指标"
        }
    }
}

struct CoveHealthRequest: Codable, Identifiable, Equatable {
    var id: String
    var conversationID: String
    var metrics: [String]
    var startAt: Date
    var endAt: Date
    var createdAt: Date
    var expiresAt: Date
    var status: String
    var reason: String
    var respondedAt: Date?
    var readAt: Date?
    var continuationStatus: String? = nil
    var continuationMessageID: String? = nil

    var responseStatusText: String {
        switch status {
        case "allowed":
            switch continuationStatus {
            case "failed": return "已允许，但续答未完成；不会自动重复发送。"
            case "interrupted": return "已允许，续答已停止。"
            case "queued": return readAt == nil ? "已允许，我会读取后直接回复。" : "已读取，正在准备回复。"
            case "running": return readAt == nil ? "正在读取并回复…" : "已读取，正在回复…"
            case "complete", "skipped": return readAt == nil ? "这次请求已处理。" : "这次摘要已被对方读取"
            default: return readAt == nil ? "已允许，等待对方读取。" : "这次摘要已被对方读取"
            }
        case "denied": return "已拒绝；未分享健康数据"
        case "expired": return "请求已过期；需要对方重新提出"
        default: return "请求已过期或范围无效；未分享健康数据"
        }
    }

    func canRespond(conversationID: String, now: Date = Date()) -> Bool {
        self.conversationID == conversationID && status == "pending" && now < expiresAt
            && !metrics.isEmpty && Set(metrics).count == metrics.count
            && Set(metrics).isSubset(of: CoveHealthScope.metricIDs)
            && endAt > startAt && endAt.timeIntervalSince(startAt) <= 7 * 86400
            && endAt <= now && createdAt <= now && expiresAt > createdAt
            && expiresAt.timeIntervalSince(createdAt) <= 600.01
    }

    func permits(_ snapshot: HealthSnapshot) -> Bool {
        let metricsValid = Set(snapshot.metrics.map(\.id)).count == snapshot.metrics.count
            && snapshot.metrics.allSatisfy {
                metrics.contains($0.id) && $0.value.isFinite && $0.value >= 0
                    && $0.sampledAt >= startAt && $0.sampledAt <= endAt
            }
        let sleepIDs = Set(["sleep", "sleepAwake", "sleepCore", "sleepDeep", "sleepREM", "sleepUnspecified"])
        let sleepValid = (snapshot.sleepSegments ?? []).count <= 5000 && (snapshot.sleepSegments ?? []).allSatisfy {
            sleepIDs.contains($0.stageID) && (metrics.contains("sleep") || metrics.contains($0.stageID))
                && $0.endAt > $0.startAt && $0.startAt >= startAt && $0.endAt <= endAt
                && ($0.source.map { $0.count <= 120 && !$0.unicodeScalars.contains(where: { $0.value < 32 }) } ?? true)
        }
        let workoutAllowed = metrics.contains("workoutCount") || metrics.contains("workoutDuration")
        let workoutIDs = (snapshot.workouts ?? []).map(\.id)
        let workoutsValid = Set(workoutIDs).count == workoutIDs.count && (snapshot.workouts ?? []).count <= 200 && (snapshot.workouts ?? []).allSatisfy {
            workoutAllowed && !$0.id.isEmpty && $0.id.count <= 128 && !$0.type.isEmpty && $0.type.count <= 80
                && !$0.type.unicodeScalars.contains(where: { $0.value < 32 })
                && $0.endAt > $0.startAt && $0.startAt >= startAt && $0.endAt <= endAt
                && $0.durationSeconds.isFinite && $0.durationSeconds >= 0
                && $0.durationSeconds <= $0.endAt.timeIntervalSince($0.startAt) + 1
                && ($0.energyKcal.map { $0.isFinite && $0 >= 0 } ?? true)
                && ($0.distanceMeters.map { $0.isFinite && $0 >= 0 } ?? true)
                && ($0.source.map { $0.count <= 120 && !$0.unicodeScalars.contains(where: { $0.value < 32 }) } ?? true)
        }
        return metricsValid && sleepValid && workoutsValid
    }
}

enum CoveJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let box = try value.singleValueContainer()
            let raw = try box.decode(String.self)
            // FormatStyle uses Foundation's cached parser. Constructing and
            // reconfiguring ISO8601DateFormatter for every stored timestamp
            // blocked launch for seconds as the local health archive grew.
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw) { return date }
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(raw) { return date }
            throw DecodingError.dataCorruptedError(in: box, debugDescription: "Invalid date")
        }
        return decoder
    }
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
