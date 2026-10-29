import Foundation

enum CoveSystemCapability: String, Codable, CaseIterable, Identifiable {
    case reminders, calendar, alarms
    var id: String { rawValue }
    var title: String {
        switch self { case .reminders: return "提醒事项"; case .calendar: return "日历"; case .alarms: return "闹钟" }
    }
    var symbol: String {
        switch self { case .reminders: return "checklist"; case .calendar: return "calendar"; case .alarms: return "alarm" }
    }
}

enum CoveCapabilityStatus: String {
    case unknown, notDetermined, authorized, denied, restricted, writeOnly, unavailable, preview
    var title: String {
        switch self {
        case .unknown: return "待查询"
        case .notDetermined: return "未申请"
        case .authorized: return "已允许"
        case .denied: return "已拒绝"
        case .restricted: return "系统限制"
        case .writeOnly: return "仅写入"
        case .unavailable: return "不可用"
        case .preview: return "预览 · 不访问设备"
        }
    }
}

/// Typed bridge contract. Dates use ISO 8601; never infer time zones from model text.
struct CoveDeviceAction: Codable, Equatable, Identifiable {
    enum Operation: String, Codable, CaseIterable {
        case listReminders, createReminder, completeReminder, deleteReminder
        case listEvents, createEvent, deleteEvent
        case listAlarms, scheduleAlarm, cancelAlarm
        var capability: CoveSystemCapability {
            switch self {
            case .listReminders, .createReminder, .completeReminder, .deleteReminder: return .reminders
            case .listEvents, .createEvent, .deleteEvent: return .calendar
            case .listAlarms, .scheduleAlarm, .cancelAlarm: return .alarms
            }
        }
        var isMutation: Bool { ![Self.listReminders, .listEvents, .listAlarms].contains(self) }
    }
    let id: UUID
    let expiresAt: Date
    let operation: Operation
    var title: String?
    var start: Date?
    var end: Date?
    var targetID: String?

    func validate(now: Date = Date()) throws {
        guard expiresAt > now, expiresAt.timeIntervalSince(now) <= 300 else { throw CoveDeviceActionError.invalid("指令已过期或有效期超过五分钟") }
        if [.createReminder, .createEvent, .scheduleAlarm].contains(operation) {
            guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 200 else {
                throw CoveDeviceActionError.invalid("标题必须为 1–200 字")
            }
        }
        if [.listEvents, .createEvent].contains(operation) {
            guard let start, let end, end > start, end.timeIntervalSince(start) <= 31 * 86_400 else {
                throw CoveDeviceActionError.invalid("日历范围必须有效且不超过 31 天")
            }
        }
        if operation == .scheduleAlarm {
            guard let start, start > now else { throw CoveDeviceActionError.invalid("闹钟时间必须在未来") }
        }
        if [.completeReminder, .deleteReminder, .deleteEvent, .cancelAlarm].contains(operation) {
            guard let targetID, !targetID.isEmpty, targetID.count <= 1024 else { throw CoveDeviceActionError.invalid("缺少有效的目标 ID") }
            if operation == .cancelAlarm, UUID(uuidString: targetID) == nil { throw CoveDeviceActionError.invalid("闹钟 ID 无效") }
        }
    }
}

struct CoveDeviceRecord: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    var start: Date?
    var end: Date?
    var completed: Bool?
    /// Local presentation only. Never extend the strict device-action wire contract.
    var dateOnly: Bool = false

    enum CodingKeys: String, CodingKey { case id, title, start, end, completed }

    // Receipt reconciliation compares the wire payload, not ephemeral UI hints.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.start == rhs.start && lhs.end == rhs.end && lhs.completed == rhs.completed
    }
}

struct CoveDeviceActionResult: Codable, Equatable {
    let actionID: UUID
    let records: [CoveDeviceRecord]
    let message: String
}

enum CoveDeviceActionError: LocalizedError {
    case invalid(String), permission, confirmation, preview, duplicate
    var errorDescription: String? {
        switch self {
        case .invalid(let text): return text
        case .permission: return "请先在系统能力中允许该项完整访问"
        case .confirmation: return "修改前需要你确认具体操作"
        case .preview: return "预览模式不读取或修改系统数据"
        case .duplicate: return "此操作已提交过；请先查看系统中的实际结果，不会自动重试"
        }
    }
}

@MainActor
protocol CoveDeviceActionBackend {
    func status(_ capability: CoveSystemCapability) -> CoveCapabilityStatus
    func request(_ capability: CoveSystemCapability) async throws
    func execute(_ action: CoveDeviceAction) async throws -> CoveDeviceActionResult
    func resolveTarget(_ action: CoveDeviceAction) throws -> CoveDeviceRecord?
}

extension CoveDeviceActionBackend {
    func resolveTarget(_ action: CoveDeviceAction) throws -> CoveDeviceRecord? { nil }
}

/// Explicit approval is supplied only by a local user confirmation UI, never by remote JSON.
@MainActor
final class CoveDeviceActionExecutor {
    private let backend: any CoveDeviceActionBackend
    private let defaults: UserDefaults
    private var running = Set<UUID>()
    private var results: [UUID: (CoveDeviceAction, CoveDeviceActionResult)] = [:]
    init(backend: any CoveDeviceActionBackend, defaults: UserDefaults = .standard) {
        self.backend = backend
        self.defaults = defaults
    }

    func execute(_ action: CoveDeviceAction, userConfirmed: Bool, preview: Bool = false, now: Date = Date()) async throws -> CoveDeviceActionResult {
        guard !preview else { throw CoveDeviceActionError.preview }
        try action.validate(now: now)
        guard !action.operation.isMutation || userConfirmed else { throw CoveDeviceActionError.confirmation }
        guard backend.status(action.operation.capability) == .authorized else { throw CoveDeviceActionError.permission }
        if let (original, result) = results[action.id] {
            guard original == action else { throw CoveDeviceActionError.invalid("指令 ID 已被另一项操作使用") }
            return result
        }
        let key = "cove.deviceAction.attempted.\(action.id.uuidString)"
        guard !running.contains(action.id), !defaults.bool(forKey: key) else { throw CoveDeviceActionError.duplicate }
        running.insert(action.id)
        // Before the write: an uncertain/crashed write cannot silently replay after relaunch.
        if action.operation.isMutation { defaults.set(true, forKey: key) }
        defer { running.remove(action.id) }
        let result = try await backend.execute(action)
        results[action.id] = (action, result)
        return result
    }
}
