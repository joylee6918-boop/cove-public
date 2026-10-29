import AlarmKit
import EventKit
import SwiftUI
import AVFAudio
import UserNotifications

@MainActor
final class CoveAppleDeviceBackend: CoveDeviceActionBackend {
    private lazy var eventStore = EKEventStore()

    func status(_ capability: CoveSystemCapability) -> CoveCapabilityStatus {
        if capability == .alarms {
            guard #available(iOS 26.0, *) else { return .unavailable }
            switch AlarmManager.shared.authorizationState {
            case .notDetermined: return .notDetermined
            case .authorized: return .authorized
            case .denied: return .denied
            @unknown default: return .unknown
            }
        }
        switch EKEventStore.authorizationStatus(for: capability == .calendar ? .event : .reminder) {
        case .notDetermined: return .notDetermined
        case .fullAccess: return .authorized
        case .writeOnly: return .writeOnly
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }

    func request(_ capability: CoveSystemCapability) async throws {
        switch capability {
        case .reminders: _ = try await eventStore.requestFullAccessToReminders()
        case .calendar: _ = try await eventStore.requestFullAccessToEvents()
        case .alarms:
            guard #available(iOS 26.0, *) else { throw CoveDeviceActionError.invalid("闹钟需要 iOS 26 或更高版本") }
            _ = try await AlarmManager.shared.requestAuthorization()
        }
    }

    /// Read the actual local target, rather than trusting a model-supplied label.
    func resolveTarget(_ action: CoveDeviceAction) throws -> CoveDeviceRecord? {
        guard let id = action.targetID else { return nil }
        guard status(action.operation.capability) == .authorized else { throw CoveDeviceActionError.permission }
        switch action.operation {
        case .completeReminder, .deleteReminder:
            guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
                throw CoveDeviceActionError.invalid("提醒事项已不存在")
            }
            return reminderRecord(reminder)
        case .deleteEvent:
            guard let event = eventStore.event(withIdentifier: id) else { throw CoveDeviceActionError.invalid("日程已不存在") }
            guard !event.hasRecurrenceRules, !event.isDetached else {
                throw CoveDeviceActionError.invalid("重复日程或其单次例外请在系统日历中处理，避免选错日期")
            }
            return eventRecord(event)
        case .cancelAlarm:
            guard #available(iOS 26.0, *), let alarmID = UUID(uuidString: id),
                  let alarm = try AlarmManager.shared.alarms.first(where: { $0.id == alarmID }) else {
                throw CoveDeviceActionError.invalid("Cove 中已没有这个闹钟")
            }
            var date: Date?
            if case .fixed(let fixed) = alarm.schedule { date = fixed }
            return .init(id: id, title: "Cove 闹钟", start: date)
        default: return nil
        }
    }

    func execute(_ action: CoveDeviceAction) async throws -> CoveDeviceActionResult {
        // Defense in depth for future callers: permissions are never requested during execution.
        try action.validate()
        guard status(action.operation.capability) == .authorized else { throw CoveDeviceActionError.permission }
        var records: [CoveDeviceRecord] = []
        var message = "已读取，最多显示 50 项"
        switch action.operation {
        case .listReminders:
            let predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            let reminders: [EKReminder] = try await withCheckedThrowingContinuation { continuation in
                eventStore.fetchReminders(matching: predicate) {
                    guard let reminders = $0 else {
                        continuation.resume(throwing: CoveDeviceActionError.invalid("系统未能返回提醒事项；这不代表列表为空"))
                        return
                    }
                    continuation.resume(returning: reminders)
                }
            }
            records = reminders.sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }
                .prefix(50).map { reminderRecord($0) }
        case .createReminder:
            guard let calendar = eventStore.defaultCalendarForNewReminders(), calendar.allowsContentModifications else {
                throw CoveDeviceActionError.invalid("系统没有可写的默认提醒事项列表；请先在提醒事项 App 中创建列表")
            }
            let reminder = EKReminder(eventStore: eventStore)
            reminder.title = action.title!
            reminder.calendar = calendar
            if let date = action.start {
                var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                components.timeZone = .current
                reminder.dueDateComponents = components
                reminder.addAlarm(EKAlarm(absoluteDate: date))
            }
            try eventStore.save(reminder, commit: true)
            records = [reminderRecord(reminder)]
            message = "已创建提醒事项"
        case .completeReminder, .deleteReminder:
            guard let reminder = eventStore.calendarItem(withIdentifier: action.targetID!) as? EKReminder,
                  reminder.calendar.allowsContentModifications else { throw CoveDeviceActionError.invalid("提醒事项已不存在或不可修改") }
            if action.operation == .completeReminder {
                reminder.isCompleted = true
                try eventStore.save(reminder, commit: true)
                records = [reminderRecord(reminder)]
                message = "已标记完成"
            } else {
                try eventStore.remove(reminder, commit: true)
                message = "已删除提醒事项"
            }
        case .listEvents:
            let predicate = eventStore.predicateForEvents(withStart: action.start!, end: action.end!, calendars: nil)
            records = eventStore.events(matching: predicate).sorted { $0.startDate < $1.startDate }.prefix(50).map { eventRecord($0) }
        case .createEvent:
            guard let calendar = eventStore.defaultCalendarForNewEvents, calendar.allowsContentModifications else {
                throw CoveDeviceActionError.invalid("系统没有可写的默认日历")
            }
            let event = EKEvent(eventStore: eventStore)
            event.title = action.title!
            event.calendar = calendar
            event.startDate = action.start!
            event.endDate = action.end!
            try eventStore.save(event, span: .thisEvent, commit: true)
            records = [eventRecord(event)]
            message = "已添加日程"
        case .deleteEvent:
            guard let event = eventStore.event(withIdentifier: action.targetID!), event.calendar.allowsContentModifications else {
                throw CoveDeviceActionError.invalid("日程已不存在或不可修改")
            }
            // Identifier lookup may select the first occurrence; refuse ambiguous recurring targets.
            guard !event.hasRecurrenceRules, !event.isDetached else {
                throw CoveDeviceActionError.invalid("重复日程或其单次例外请在系统日历中处理，避免选错日期")
            }
            try eventStore.remove(event, span: .thisEvent, commit: true)
            message = "已删除这一次日程"
        case .listAlarms, .scheduleAlarm, .cancelAlarm:
            guard #available(iOS 26.0, *) else { throw CoveDeviceActionError.invalid("闹钟需要 iOS 26 或更高版本") }
            return try await executeAlarm(action)
        }
        return .init(actionID: action.id, records: records, message: message)
    }

    private func reminderRecord(_ reminder: EKReminder) -> CoveDeviceRecord {
        var components = reminder.dueDateComponents
        components?.calendar = .current
        return .init(id: reminder.calendarItemIdentifier, title: reminder.title ?? "提醒事项", start: components?.date, completed: reminder.isCompleted,
                     dateOnly: components != nil && components?.hour == nil)
    }
    private func eventRecord(_ event: EKEvent) -> CoveDeviceRecord {
        .init(id: event.eventIdentifier, title: event.title ?? "日程", start: event.startDate, end: event.endDate, dateOnly: event.isAllDay)
    }

    @available(iOS 26.0, *)
    private struct Metadata: AlarmMetadata { let title: String }

    @available(iOS 26.0, *)
    private func executeAlarm(_ action: CoveDeviceAction) async throws -> CoveDeviceActionResult {
        let manager = AlarmManager.shared
        switch action.operation {
        case .scheduleAlarm:
            let title = action.title!
            let alert: AlarmPresentation.Alert
            if #available(iOS 26.1, *) { alert = .init(title: LocalizedStringResource(stringLiteral: title)) }
            else { alert = .init(title: LocalizedStringResource(stringLiteral: title), stopButton: .init(text: "停止", textColor: .white, systemImageName: "stop.fill")) }
            let attributes = AlarmAttributes(presentation: .init(alert: alert), metadata: Metadata(title: title), tintColor: Color.accentColor)
            let configuration = AlarmManager.AlarmConfiguration.alarm(schedule: .fixed(action.start!), attributes: attributes)
            let alarm = try await manager.schedule(id: action.id, configuration: configuration)
            return .init(actionID: action.id, records: [.init(id: alarm.id.uuidString, title: title, start: action.start)], message: "已设置 Cove 闹钟")
        case .cancelAlarm:
            let id = UUID(uuidString: action.targetID!)!
            guard try manager.alarms.contains(where: { $0.id == id }) else { throw CoveDeviceActionError.invalid("Cove 中已没有这个闹钟") }
            try manager.cancel(id: id)
            return .init(actionID: action.id, records: [], message: "已取消 Cove 闹钟")
        default:
            // AlarmKit lists this app's alarms, not Apple's Clock app.
            let records = try manager.alarms.prefix(50).map { alarm in
                var date: Date?
                if case .fixed(let fixed) = alarm.schedule { date = fixed }
                return CoveDeviceRecord(id: alarm.id.uuidString, title: "Cove 闹钟 · \(alarm.state)", start: date)
            }
            return .init(actionID: action.id, records: records, message: "已读取 Cove 管理的闹钟")
        }
    }
}

@MainActor
final class CoveSystemCapabilities: ObservableObject {
    @Published private(set) var statuses: [CoveSystemCapability: CoveCapabilityStatus] = [:]
    @Published private(set) var microphone: CoveCapabilityStatus = .unknown
    @Published private(set) var notifications: CoveCapabilityStatus = .unknown
    @Published private(set) var requesting: CoveSystemCapability?
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var result: CoveDeviceActionResult?
    let preview: Bool
    private let backend: any CoveDeviceActionBackend
    private let executor: CoveDeviceActionExecutor
    init(preview: Bool = false, backend: (any CoveDeviceActionBackend)? = nil, defaults: UserDefaults = .standard) {
        self.preview = preview
        let backend = backend ?? CoveAppleDeviceBackend()
        self.backend = backend
        executor = CoveDeviceActionExecutor(backend: backend, defaults: defaults)
    }

    func refresh() async {
        guard !preview else {
            statuses = Dictionary(uniqueKeysWithValues: CoveSystemCapability.allCases.map { ($0, .preview) })
            microphone = .preview; notifications = .preview
            return
        }
        statuses = Dictionary(uniqueKeysWithValues: CoveSystemCapability.allCases.map { ($0, backend.status($0)) })
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined: microphone = .notDetermined
        case .granted: microphone = .authorized
        case .denied: microphone = .denied
        @unknown default: microphone = .unknown
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: notifications = .notDetermined
        case .denied: notifications = .denied
        case .authorized, .provisional, .ephemeral: notifications = .authorized
        @unknown default: notifications = .unknown
        }
    }

    func request(_ capability: CoveSystemCapability) async {
        guard !preview, requesting == nil else { return }
        requesting = capability; error = nil
        defer { requesting = nil }
        do { try await backend.request(capability) } catch { self.error = error.localizedDescription }
        await refresh()
    }

    func execute(_ action: CoveDeviceAction, userConfirmed: Bool) async {
        guard !busy else { return }
        busy = true; error = nil; result = nil
        defer { busy = false }
        do { result = try await executor.execute(action, userConfirmed: userConfirmed, preview: preview) }
        catch { self.error = error.localizedDescription }
        await refresh()
    }

    func clearResult() { result = nil; error = nil }
}
