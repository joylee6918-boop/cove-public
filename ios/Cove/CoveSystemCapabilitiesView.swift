import SwiftUI

struct CoveSystemCapabilitiesView: View {
    @StateObject private var model: CoveSystemCapabilities
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var selected = CoveSystemCapability.reminders
    @State private var title = ""
    @State private var date = Date().addingTimeInterval(3600)
    @State private var duration = 60
    @State private var pending: CoveDeviceAction?
    @State private var confirmationText = ""
    @State private var showingConfirmation = false
    @State private var showingPermission = false
    @State private var permissionTarget = CoveSystemCapability.reminders

    init(preview: Bool) { _model = StateObject(wrappedValue: CoveSystemCapabilities(preview: preview)) }

    var body: some View {
        Form {
            Section {
                ForEach(CoveSystemCapability.allCases) { capability in
                    HStack {
                        Label(capability.title, systemImage: capability.symbol)
                        Spacer()
                        let status = model.statuses[capability] ?? .unknown
                        Text(status.title).font(.subheadline).foregroundStyle(.secondary)
                        if status == .notDetermined || status == .writeOnly {
                            Button("允许") { permissionTarget = capability; showingPermission = true }
                                .buttonStyle(.bordered).disabled(model.requesting != nil || model.busy)
                                .accessibilityLabel("允许\(capability.title)完整访问")
                        } else if status == .denied || status == .restricted {
                            Button("设置") { openSettings() }.buttonStyle(.bordered)
                                .accessibilityLabel("在系统设置中管理\(capability.title)权限")
                        }
                        if model.requesting == capability { ProgressView() }
                    }.frame(minHeight: 44).accessibilityIdentifier("capability.\(capability.rawValue)")
                }
            } header: { Text("系统能力") } footer: {
                Text("点允许后才申请系统权限。提醒事项与日历为完整读写；数据不会因开启权限自动上传。闹钟由 Cove 管理，不会读取或改动苹果时钟 App 的闹钟。")
            }
            Section {
                LabeledContent("麦克风", value: model.microphone.title)
                LabeledContent("通知", value: model.notifications.title)
                Button("打开 Cove 系统设置") { openSettings() }.disabled(model.preview)
            } header: { Text("语音与通知") } footer: {
                Text("麦克风仍在录音或通话时按需申请；通知仍由设置页的原有开关开启。这里的权限状态不代表实时通话已接通。")
            }
            Section {
                Picker("操作对象", selection: $selected) {
                    ForEach(CoveSystemCapability.allCases) { Text($0.title).tag($0) }
                }.disabled(model.busy)
                Button(selected == .calendar ? "读取未来 7 天日程" : selected == .reminders ? "读取未完成提醒事项" : "读取 Cove 闹钟") {
                    let operation: CoveDeviceAction.Operation = selected == .calendar ? .listEvents : selected == .reminders ? .listReminders : .listAlarms
                    let now = Date()
                    let action = CoveDeviceAction(id: UUID(), expiresAt: now.addingTimeInterval(120), operation: operation,
                                                  start: operation == .listEvents ? now : nil,
                                                  end: operation == .listEvents ? now.addingTimeInterval(7 * 86_400) : nil)
                    Task { await model.execute(action, userConfirmed: false) }
                }.disabled(!canOperate)
                TextField("标题", text: $title)
                DatePicker(selected == .calendar ? "开始" : "提醒时间", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                if selected == .calendar { Stepper("时长 \(duration) 分钟", value: $duration, in: 5...1440, step: 5) }
                Button("\(selected == .alarms ? "设置闹钟" : selected == .calendar ? "添加日程" : "添加提醒事项")…") {
                    let operation: CoveDeviceAction.Operation = selected == .alarms ? .scheduleAlarm : selected == .calendar ? .createEvent : .createReminder
                    let action = CoveDeviceAction(id: UUID(), expiresAt: Date().addingTimeInterval(120), operation: operation,
                                                  title: title.trimmingCharacters(in: .whitespacesAndNewlines), start: date,
                                                  end: operation == .createEvent ? date.addingTimeInterval(Double(duration) * 60) : nil)
                    confirm(action, description: "\(action.title ?? "")\n\(date.formatted(date: .abbreviated, time: .shortened))\(action.end.map { " — " + $0.formatted(date: .omitted, time: .shortened) } ?? "")\n将写入系统默认列表/日历，或设置 Cove 闹钟。")
                }.disabled(!canOperate || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.busy { ProgressView("正在访问设备…") }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
            } header: { Text("本机操作") } footer: {
                Text("这些按钮直接在本机执行，结果只显示在这里。连接服务并保持 App 在前台时，聊天可读取权限状态；持续读取授权开启后可读取系统记录。聊天中的创建、修改、删除和取消都需你在请求卡上确认。")
            }
            if let result = model.result {
                Section(result.message) {
                    if result.records.isEmpty { Text("没有返回记录").foregroundStyle(.secondary) }
                    ForEach(Array(result.records.enumerated()), id: \.offset) { _, record in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(record.title)
                            if let start = record.start { Text(start.formatted(date: .abbreviated, time: .shortened)).font(.footnote).foregroundStyle(.secondary) }
                            HStack {
                                if selected == .reminders && record.completed != true {
                                    Button("完成…") { recordAction(.completeReminder, record: record) }.buttonStyle(.bordered)
                                }
                                Button(selected == .alarms ? "取消闹钟…" : "删除…", role: .destructive) {
                                    recordAction(selected == .alarms ? .cancelAlarm : selected == .calendar ? .deleteEvent : .deleteReminder, record: record)
                                }.buttonStyle(.bordered)
                            }.disabled(model.busy || model.preview)
                        }.padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("系统能力")
        .task { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await model.refresh() } } }
        .onChange(of: selected) { _, _ in model.clearResult() }
        .alert("允许\(permissionTarget.title)？", isPresented: $showingPermission) {
            Button("取消", role: .cancel) {}
            Button("继续授权") { Task { await model.request(permissionTarget) } }
        } message: {
            Text(permissionTarget == .alarms ? "用于设置和取消你在 Cove 创建的闹钟。下一步由 iOS 请求授权。" : "用于读取、创建、修改和删除\(permissionTarget.title)。下一步由 iOS 请求完整访问；不会自动上传已有记录。")
        }
        .alert("确认本机操作", isPresented: $showingConfirmation) {
            Button("取消", role: .cancel) { pending = nil }
            Button("确认执行") {
                if let action = pending { Task { await model.execute(action, userConfirmed: true) } }
                pending = nil
            }
        } message: { Text(confirmationText) }
    }

    private var canOperate: Bool { !model.preview && !model.busy && model.requesting == nil && model.statuses[selected] == .authorized }
    private func openSettings() { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
    private func confirm(_ action: CoveDeviceAction, description: String) {
        pending = action; confirmationText = description; showingConfirmation = true
    }
    private func recordAction(_ operation: CoveDeviceAction.Operation, record: CoveDeviceRecord) {
        let action = CoveDeviceAction(id: UUID(), expiresAt: Date().addingTimeInterval(120), operation: operation, targetID: record.id)
        let verb = operation == .completeReminder ? "标记完成" : operation == .cancelAlarm ? "取消闹钟" : "删除"
        confirm(action, description: "\(verb)：\(record.title)\(record.start.map { "\n" + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")\n\(operation == .deleteEvent ? "仅删除这一次日程。" : "")")
    }
}
