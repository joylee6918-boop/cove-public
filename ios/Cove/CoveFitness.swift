import Foundation

// Local fitness data is deliberately independent of HealthKit, chat and uploads.
enum CoveFitnessKind: String, Codable, CaseIterable, Identifiable {
    case strength, activity
    var id: String { rawValue }
    var title: String { self == .strength ? "力量训练" : "一般活动" }
}

enum CoveFitnessEffort: String, Codable, CaseIterable, Identifiable {
    case easy, normal, hard
    var id: String { rawValue }
    var title: String {
        switch self { case .easy: return "轻松"; case .normal: return "正常"; case .hard: return "吃力" }
    }
}

struct CoveFitnessSet: Codable, Equatable, Identifiable {
    let id: UUID
    var weightKG: Double
    var reps: Int
    var completed: Bool
    init(id: UUID = UUID(), weightKG: Double = 0, reps: Int = 8, completed: Bool = false) {
        self.id = id; self.weightKG = weightKG; self.reps = reps; self.completed = completed
    }
}

struct CoveFitnessExercise: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var sets: [CoveFitnessSet]
    init(id: UUID = UUID(), name: String, sets: [CoveFitnessSet] = []) {
        self.id = id; self.name = name; self.sets = sets
    }
}

struct CoveFitnessActivity: Codable, Equatable {
    var kind: String
    /// nil while timing means use the actual start/end interval at completion.
    var durationSeconds: Double?
    var distanceKM: Double?
    var energyKCAL: Double?
    init(kind: String, durationSeconds: Double? = nil, distanceKM: Double? = nil, energyKCAL: Double? = nil) {
        self.kind = kind; self.durationSeconds = durationSeconds
        self.distanceKM = distanceKM; self.energyKCAL = energyKCAL
    }
}

struct CoveFitnessDraft: Codable, Equatable, Identifiable {
    let id: UUID
    fileprivate(set) var revision: Int = 0
    var name: String
    var kind: CoveFitnessKind
    var startedAt: Date
    var exercises: [CoveFitnessExercise]
    var activity: CoveFitnessActivity?
    var effort: CoveFitnessEffort?
    var note: String
    init(id: UUID = UUID(), name: String, kind: CoveFitnessKind, startedAt: Date = Date(),
         exercises: [CoveFitnessExercise] = [], activity: CoveFitnessActivity? = nil,
         effort: CoveFitnessEffort? = nil, note: String = "") {
        self.id = id; self.name = name; self.kind = kind; self.startedAt = startedAt
        self.exercises = exercises; self.activity = activity; self.effort = effort; self.note = note
    }
}

/// Value snapshot: no repository API can edit or delete an accepted record.
struct CoveFitnessSession: Codable, Equatable, Identifiable {
    let workout: CoveFitnessDraft
    let endedAt: Date
    var id: UUID { workout.id }
    var durationSeconds: Double { workout.activity?.durationSeconds ?? endedAt.timeIntervalSince(workout.startedAt) }
    var completedSetCount: Int { workout.exercises.reduce(0) { $0 + $1.sets.filter(\.completed).count } }
}

enum CoveFitnessError: LocalizedError, Equatable {
    case invalid(String), conflict, immutable, unsupportedArchive
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .conflict: return "草稿已变更，请重新载入后再试。"
        case .immutable: return "已完成或放弃的训练不能覆盖，请新建训练。"
        case .unsupportedArchive: return "健身记录版本无法读取，原文件已保留。"
        }
    }
}

enum CoveFitnessValidation {
    static let maximumDuration: TimeInterval = 7 * 24 * 60 * 60
    static func name(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 120,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CoveFitnessError.invalid("名称需为 1–120 个字符，不能留空或换行。")
        }
    }
    static func number(_ value: Double, maximum: Double, label: String) throws {
        guard value.isFinite, value >= 0, value <= maximum else {
            throw CoveFitnessError.invalid("\(label)需为有效的非负数，且不超过 \(maximum.formatted())。")
        }
    }
    static func date(_ value: Date) throws {
        let seconds = value.timeIntervalSince1970
        guard seconds.isFinite, (0...253_402_300_799).contains(seconds) else {
            throw CoveFitnessError.invalid("日期无效。")
        }
    }
    static func draft(_ value: CoveFitnessDraft, now: Date? = nil) throws {
        try name(value.name); try date(value.startedAt)
        guard value.revision >= 0, value.revision < Int.max, value.note.count <= 4_000 else {
            throw CoveFitnessError.invalid("草稿版本无效或备注超过 4000 字。")
        }
        if let now {
            try date(now)
            guard value.startedAt <= now else { throw CoveFitnessError.invalid("开始时间不能在未来。") }
        }
        guard value.exercises.count <= 100, Set(value.exercises.map(\.id)).count == value.exercises.count else {
            throw CoveFitnessError.invalid("动作重复或超过 100 项。")
        }
        var setIDs = Set<UUID>()
        for exercise in value.exercises {
            try name(exercise.name)
            guard exercise.sets.count <= 100 else { throw CoveFitnessError.invalid("每个动作最多 100 组。") }
            for set in exercise.sets {
                guard setIDs.insert(set.id).inserted else { throw CoveFitnessError.invalid("组编号重复。") }
                try number(set.weightKG, maximum: 2_000, label: "重量")
                guard (1...1_000).contains(set.reps) else { throw CoveFitnessError.invalid("每组次数需为 1–1000，重量和次数必须完整。") }
            }
        }
        switch value.kind {
        case .strength:
            guard value.activity == nil else { throw CoveFitnessError.invalid("力量训练不能混入活动字段。") }
        case .activity:
            guard value.exercises.isEmpty, let activity = value.activity else {
                throw CoveFitnessError.invalid("请填写活动类型。")
            }
            try name(activity.kind)
            if let duration = activity.durationSeconds {
                try number(duration, maximum: maximumDuration, label: "活动时长")
                guard duration > 0 else { throw CoveFitnessError.invalid("活动时长需大于零。") }
            }
            if let distance = activity.distanceKM { try number(distance, maximum: 10_000, label: "距离") }
            if let energy = activity.energyKCAL { try number(energy, maximum: 100_000, label: "热量") }
        }
    }
    static func session(_ value: CoveFitnessSession, now: Date? = nil) throws {
        try draft(value.workout, now: now); try date(value.endedAt)
        let elapsed = value.endedAt.timeIntervalSince(value.workout.startedAt)
        guard elapsed > 0, elapsed <= maximumDuration, now.map({ value.endedAt <= $0 }) ?? true else {
            throw CoveFitnessError.invalid("结束时间需晚于开始时间且不在未来，单次最长 7 天。")
        }
        guard value.durationSeconds > 0, value.durationSeconds <= elapsed else {
            throw CoveFitnessError.invalid("活动时长不能超过开始至结束的时间。")
        }
        if value.workout.kind == .strength, value.completedSetCount == 0 {
            throw CoveFitnessError.invalid("至少完成一组后才能保存训练。")
        }
    }
}

struct CoveFitnessArchive: Codable, Equatable {
    var version = 1
    var draft: CoveFitnessDraft?
    var sessions: [CoveFitnessSession] = []
    /// Tombstones prevent a stale editor from resurrecting an explicitly discarded draft.
    var discardedIDs: Set<UUID> = []

    func validate() throws {
        guard version == 1 else { throw CoveFitnessError.unsupportedArchive }
        let ids = Set(sessions.map(\.id))
        guard ids.count == sessions.count, ids.isDisjoint(with: discardedIDs) else {
            throw CoveFitnessError.invalid("健身记录编号冲突，原文件已保留。")
        }
        for session in sessions { try CoveFitnessValidation.session(session) }
        if let draft {
            try CoveFitnessValidation.draft(draft)
            guard !ids.contains(draft.id), !discardedIDs.contains(draft.id) else { throw CoveFitnessError.immutable }
        }
    }
}

/// Synchronous, process-serialized local transactions. Writes publish only after atomic
/// replacement succeeds. Separate repository instances reread disk under the same lock.
/// Inject nil for an entirely in-memory repository; never silently fall back to memory.
final class CoveFitnessRepository {
    static let live = CoveFitnessRepository()
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CoveFitness", isDirectory: true)
    }
    private static let lock = NSLock()
    let directoryURL: URL?
    private var memory = CoveFitnessArchive()
    init(directoryURL: URL? = CoveFitnessRepository.defaultDirectory) { self.directoryURL = directoryURL }

    func snapshot() throws -> CoveFitnessArchive {
        try locked { try load() }
    }

    @discardableResult
    func saveDraft(_ draft: CoveFitnessDraft, now: Date = Date()) throws -> CoveFitnessDraft {
        try locked {
            var archive = try load()
            try CoveFitnessValidation.draft(draft, now: now)
            guard !archive.sessions.contains(where: { $0.id == draft.id }), !archive.discardedIDs.contains(draft.id) else {
                throw CoveFitnessError.immutable
            }
            if let previous = archive.draft {
                var retry = draft; retry.revision = previous.revision
                // Also accept the exact request whose committed revision was not received.
                if retry == previous, draft.revision == previous.revision || draft.revision == previous.revision - 1 {
                    return previous
                }
                guard previous.id == draft.id, previous.revision == draft.revision else { throw CoveFitnessError.conflict }
            } else if draft.revision != 0 { throw CoveFitnessError.conflict }
            var accepted = draft; accepted.revision += 1
            archive.draft = accepted
            try persist(archive)
            return accepted
        }
    }

    @discardableResult
    func complete(_ draft: CoveFitnessDraft, endedAt: Date, now: Date = Date()) throws -> CoveFitnessSession {
        try locked {
            var archive = try load()
            let record = CoveFitnessSession(workout: draft, endedAt: endedAt)
            if let existing = archive.sessions.first(where: { $0.id == draft.id }) {
                guard existing == record else { throw CoveFitnessError.immutable }
                return existing
            }
            guard archive.draft == draft else { throw CoveFitnessError.conflict }
            try CoveFitnessValidation.session(record, now: now)
            archive.sessions.append(record); archive.draft = nil
            try persist(archive) // History append and draft removal are ONE atomic transaction.
            return record
        }
    }

    func discard(_ draft: CoveFitnessDraft) throws {
        try locked {
            var archive = try load()
            if archive.discardedIDs.contains(draft.id) { return }
            guard archive.draft == draft else { throw CoveFitnessError.conflict }
            archive.draft = nil; archive.discardedIDs.insert(draft.id)
            try persist(archive)
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try body()
    }
    private func load() throws -> CoveFitnessArchive {
        guard let directoryURL else { return memory }
        let url = directoryURL.appendingPathComponent("fitness-v1.json")
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return CoveFitnessArchive()
        }
        let archive = try JSONDecoder().decode(CoveFitnessArchive.self, from: data)
        try archive.validate()
        return archive
    }
    private func persist(_ archive: CoveFitnessArchive) throws {
        try archive.validate()
        guard var directoryURL else { memory = archive; return }
        let manager = FileManager.default
        try manager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directoryURL.setResourceValues(values)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(archive)
        #if os(iOS)
        try manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directoryURL.path)
        try data.write(to: directoryURL.appendingPathComponent("fitness-v1.json"), options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: directoryURL.appendingPathComponent("fitness-v1.json"), options: [.atomic])
        #endif
    }
}

struct CoveFitnessDay: Identifiable, Equatable {
    let date: Date
    let count: Int
    var id: Date { date }
}
struct CoveFitnessSummary: Equatable {
    let periodTitle: String
    let interval: DateInterval
    let sessionCount: Int
    let activeDays: Int
    let durationSeconds: Double
    let completedSets: Int
    let distanceKM: Double?
    let energyKCAL: Double?
    var conclusion: String { sessionCount == 0 ? "\(periodTitle)，从一次开始" : "\(periodTitle)已动了 \(sessionCount) 次" }
}
struct CoveFitnessMonth: Identifiable {
    let date: Date
    let sessions: [CoveFitnessSession]
    var id: Date { date }
}
struct CoveFitnessPerformance: Equatable {
    let sessionID: UUID
    let date: Date
    let sets: [CoveFitnessSet]
}

enum CoveFitnessSummaries {
    /// Sessions belong to their START day. Whole-session totals are not split at midnight.
    /// The supplied calendar controls time zone, week start and minimum days in week.
    static func summary(_ sessions: [CoveFitnessSession], containing date: Date,
                        component: Calendar.Component = .weekOfYear, calendar: Calendar = .current) -> CoveFitnessSummary? {
        guard let interval = calendar.dateInterval(of: component, for: date) else { return nil }
        let selected = ordered(sessions).filter { $0.workout.startedAt >= interval.start && $0.workout.startedAt < interval.end }
        let distances = selected.compactMap { $0.workout.activity?.distanceKM }
        let energy = selected.compactMap { $0.workout.activity?.energyKCAL }
        return .init(periodTitle: component == .month ? "本月" : "这周", interval: interval, sessionCount: selected.count,
                     activeDays: Set(selected.map { calendar.startOfDay(for: $0.workout.startedAt) }).count,
                     durationSeconds: selected.reduce(0) { $0 + $1.durationSeconds },
                     completedSets: selected.reduce(0) { $0 + $1.completedSetCount },
                     distanceKM: distances.isEmpty ? nil : distances.reduce(0, +),
                     energyKCAL: energy.isEmpty ? nil : energy.reduce(0, +))
    }
    static func weekRhythm(_ sessions: [CoveFitnessSession], containing date: Date, calendar: Calendar = .current) -> [CoveFitnessDay] {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: date) else { return [] }
        let counts = Dictionary(grouping: sessions, by: { calendar.startOfDay(for: $0.workout.startedAt) }).mapValues(\.count)
        return (0..<7).compactMap { index in
            guard let day = calendar.date(byAdding: .day, value: index, to: week.start) else { return nil }
            return CoveFitnessDay(date: day, count: counts[day] ?? 0)
        }
    }
    static func months(_ sessions: [CoveFitnessSession], calendar: Calendar = .current) -> [CoveFitnessMonth] {
        let grouped = Dictionary(grouping: ordered(sessions), by: { calendar.dateInterval(of: .month, for: $0.workout.startedAt)?.start ?? $0.workout.startedAt })
        return grouped.keys.sorted(by: >).map { CoveFitnessMonth(date: $0, sessions: grouped[$0] ?? []) }
    }
    static func previousPerformance(named name: String, before date: Date, sessions: [CoveFitnessSession]) -> CoveFitnessPerformance? {
        let key = normalized(name)
        for session in ordered(sessions) where session.endedAt <= date && session.workout.startedAt < date {
            let sets = session.workout.exercises.filter { normalized($0.name) == key }.flatMap(\.sets).filter(\.completed)
            if !sets.isEmpty { return .init(sessionID: session.id, date: session.workout.startedAt, sets: sets) }
        }
        return nil
    }
    static func ordered(_ sessions: [CoveFitnessSession]) -> [CoveFitnessSession] {
        sessions.sorted {
            if $0.workout.startedAt != $1.workout.startedAt { return $0.workout.startedAt > $1.workout.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
