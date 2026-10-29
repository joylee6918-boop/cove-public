import Foundation
import Combine

/// Home reads are local, read-only and independent of the remote action queue.
/// No permissions, mutations, uploads or defaults writes originate here.
@MainActor
final class CoveHomeLifeModel: ObservableObject {
    enum State {
        case waiting, loading, permission(CoveCapabilityStatus), failed(String)
        case ready([CoveDeviceRecord], Date)
    }

    @Published private(set) var states: [CoveSystemCapability: State] = [:]
    private let backend: any CoveDeviceActionBackend
    private var generation = 0

    init(backend: any CoveDeviceActionBackend) { self.backend = backend }

    func invalidate() {
        generation += 1
        states = [:]
    }

    func refresh(preview: Bool, now: Date = Date(), calendar: Calendar = .current) async {
        generation += 1
        let stamp = generation
        states = [:]
        guard !preview else {
            for capability in CoveSystemCapability.allCases { states[capability] = .permission(.preview) }
            return
        }
        // Check all permissions before any suspension so revocation clears old content immediately.
        for capability in CoveSystemCapability.allCases {
            let status = backend.status(capability)
            states[capability] = status == .authorized ? .loading : .permission(status)
        }
        for capability in [CoveSystemCapability.calendar, .reminders, .alarms] {
            guard !Task.isCancelled, generation == stamp else { return }
            let currentStatus = backend.status(capability)
            guard currentStatus == .authorized else { states[capability] = .permission(currentStatus); continue }
            let operation: CoveDeviceAction.Operation = capability == .calendar ? .listEvents : capability == .reminders ? .listReminders : .listAlarms
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(7 * 86_400)
            let action = CoveDeviceAction(id: UUID(), expiresAt: Date().addingTimeInterval(120), operation: operation,
                                          start: capability == .calendar ? start : nil, end: capability == .calendar ? end : nil)
            do {
                let result = try await backend.execute(action)
                guard !Task.isCancelled, generation == stamp else { return }
                let status = backend.status(capability)
                guard status == .authorized else { states[capability] = .permission(status); continue }
                states[capability] = .ready(Self.sorted(result.records), Date())
            } catch {
                guard !Task.isCancelled, generation == stamp else { return }
                let status = backend.status(capability)
                states[capability] = status == .authorized ? .failed(error.localizedDescription) : .permission(status)
            }
        }
    }

    static func sorted(_ records: [CoveDeviceRecord]) -> [CoveDeviceRecord] {
        records.sorted {
            if $0.start != $1.start { return ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    static func featured(_ records: [CoveDeviceRecord], capability: CoveSystemCapability, now: Date) -> CoveDeviceRecord? {
        let ordered = sorted(records)
        if capability == .calendar {
            // Prefer ongoing/next events; today's finished events remain visible in details.
            return ordered.first { ($0.end ?? $0.start ?? .distantPast) > now }
        }
        if capability == .alarms {
            return ordered.first { ($0.start ?? .distantPast) > now } ?? ordered.first
        }
        return ordered.first
    }

    static func dateLabel(_ record: CoveDeviceRecord, capability: CoveSystemCapability, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date = record.start else { return capability == .reminders ? "没有截止日期" : "时间由系统管理" }
        let day = calendar.isDate(date, inSameDayAs: now) ? "今天" : date.formatted(.dateTime.month().day())
        if record.dateOnly { return "\(day) · \(capability == .calendar ? "全天" : "当天到期")" }
        return "\(day) · \(date.formatted(date: .omitted, time: .shortened))"
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds == 0 { return "0 分钟" }
        if seconds < 60 { return "不足 1 分钟" }
        let minutes = Int(min(seconds / 60, Double(Int.max / 2)))
        return minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分钟" : "\(minutes) 分钟"
    }
}
