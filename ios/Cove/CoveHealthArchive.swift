import Foundation

struct CoveHealthArchiveEntry: Identifiable, Codable {
    enum Origin: String, Codable { case manual, request, standing }
    enum SharingState: String, Codable { case localOnly, deliveryUnknown, shared, removedFromServer }
    var id: UUID = UUID()
    var snapshot: HealthSnapshot
    var recordedAt: Date = Date()
    var origin: Origin
    var sharingState: SharingState = .localOnly
    var serviceID: String? = nil
    var conversationID: String? = nil
    var requestID: String? = nil
    var requestStartAt: Date? = nil
    var requestEndAt: Date? = nil

    var sharingStatusText: String {
        switch sharingState {
        case .localOnly: "仅存本机，未分享"
        case .deliveryUnknown: origin == .standing ? "同步结果未确认；持续授权下可幂等重试" : "分享结果未确认；未获持续授权时不会自动重发"
        case .shared: "服务端已确认接收；不代表对方已读"
        case .removedFromServer: "服务端副本已删除；本机仍保留"
        }
    }
}

/// Separate from chat/server caches. Only an explicit persistent service grant
/// permits automatic archive upload; one-time reads retain their existing scope.
/// nil directory is explicitly in-memory, for isolated synthetic tests.
final class CoveHealthArchive {
    private let directoryURL: URL?
    private var memory: [CoveHealthArchiveEntry] = []
    private struct Document: Codable {
        var version = 1
        var entries: [CoveHealthArchiveEntry]
    }

    init(directoryURL: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CoveHealth", isDirectory: true)) {
        self.directoryURL = directoryURL
    }

    func load() throws -> [CoveHealthArchiveEntry] {
        guard let directoryURL else { return memory }
        let file = directoryURL.appendingPathComponent("history.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let document = try CoveJSON.decoder().decode(Document.self, from: Data(contentsOf: file))
        guard document.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return document.entries.sorted { $0.recordedAt > $1.recordedAt }
    }

    func save(_ entries: [CoveHealthArchiveEntry]) throws {
        guard var directoryURL else { memory = entries; return }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try directoryURL.setResourceValues(resourceValues)
        let file = directoryURL.appendingPathComponent("history.json")
        try CoveJSON.encoder().encode(Document(entries: entries)).write(to: file, options: [.atomic, .completeFileProtection])
    }
}

enum CoveHealthSnapshotVerification {
    private struct MetricKey: Hashable {
        let id: String, unit: String
        let value: Double
        let sampledAt: Int64
        let detail: String?, source: String?
    }
    private struct SleepKey: Hashable {
        let stageID: String
        let startAt: Int64, endAt: Int64
        let source: String?
    }
    private struct WorkoutKey: Hashable {
        let id: String, type: String
        let startAt: Int64, endAt: Int64
        let durationSeconds: Double
        let energyKcal: Double?, distanceMeters: Double?
        let source: String?
    }

    static func matches(_ local: HealthSnapshot, _ remote: HealthSnapshot) -> Bool {
        guard millisecond(local.capturedAt) == millisecond(remote.capturedAt),
              counts(local.metrics.map(metricKey)) == counts(remote.metrics.map(metricKey)),
              optionalCounts(local.sleepSegments?.map(sleepKey)) == optionalCounts(remote.sleepSegments?.map(sleepKey)),
              optionalCounts(local.workouts?.map(workoutKey)) == optionalCounts(remote.workouts?.map(workoutKey)) else { return false }
        return true
    }

    private static func millisecond(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func counts<Key: Hashable>(_ values: [Key]) -> [Key: Int] {
        values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    private static func optionalCounts<Key: Hashable>(_ values: [Key]?) -> [Key: Int]? {
        values.map(counts)
    }

    // The service may canonicalize display titles and array order. Typed keys
    // keep nil distinct from every legal string and retain duplicate counts.
    private static func metricKey(_ metric: HealthMetric) -> MetricKey {
        .init(id: metric.id, unit: metric.unit, value: metric.value, sampledAt: millisecond(metric.sampledAt),
              detail: metric.detail, source: metric.source)
    }

    private static func sleepKey(_ segment: CoveSleepSegment) -> SleepKey {
        .init(stageID: segment.stageID, startAt: millisecond(segment.startAt), endAt: millisecond(segment.endAt),
              source: segment.source)
    }

    private static func workoutKey(_ workout: CoveWorkout) -> WorkoutKey {
        .init(id: workout.id, type: workout.type, startAt: millisecond(workout.startAt),
              endAt: millisecond(workout.endAt), durationSeconds: workout.durationSeconds,
              energyKcal: workout.energyKcal, distanceMeters: workout.distanceMeters, source: workout.source)
    }
}
