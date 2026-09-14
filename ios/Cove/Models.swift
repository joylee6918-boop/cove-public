import Foundation

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

    var readyForDisplay: ChatMessage {
        guard role == "assistant", status == "streaming" else { return self }
        var pending = self
        pending.text = ""
        pending.attachments = nil
        pending.attachmentURL = nil
        pending.stickerID = nil
        pending.revision = nil
        return pending
    }

    func mergingServerUpdate(_ incoming: ChatMessage) -> ChatMessage {
        guard incoming.id == id, incoming.conversationID == conversationID else { return self }
        if let currentRevision = revision, let nextRevision = incoming.revision, nextRevision < currentRevision { return self }
        var updated = incoming
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
}

struct HealthSnapshot: Codable {
    var capturedAt: Date
    var metrics: [HealthMetric]
}

enum CoveJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let box = try value.singleValueContainer()
            let raw = try box.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: raw) { return date }
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
