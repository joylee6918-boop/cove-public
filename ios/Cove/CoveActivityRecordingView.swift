import SwiftUI

struct CoveActivityRecordingView: View {
    @StateObject private var recorder = CoveActivityRecorder.shared
    @State private var editing: ActivityRecipient?
    @State private var confirmDiscard = false
    var body: some View {
        Form {
            Section {
                Toggle("自动记录与同步", isOn: Binding(get: { recorder.state.enabled }, set: recorder.setEnabled))
                Text("快捷指令只调用「记录 App 活动」。记录先存手机，联网失败会保留待传，不因网络故障弹出快捷指令错误。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let error = recorder.error { Text(error).font(.footnote).foregroundStyle(.red) }
            } footer: {
                Text("关闭后停止新记录和后续上传，待传记录保留；已发出的请求可能已经被接收。手机重启后须先解锁一次。")
            }
            ForEach(ActivityRecipient.allCases) { recipient in
                Section(recipient.title) {
                    let destination = recorder.state.destinations.first { $0.id == recipient }
                    if let destination {
                        Text(destination.baseURL).font(.caption).textSelection(.enabled)
                        LabeledContent("同步", value: destination.enabled ? "已开启" : "已暂停")
                        LabeledContent("待确认", value: "\(recorder.state.pending(recipient)) 条")
                        if let date = destination.lastReceivedAt {
                            LabeledContent("最近收到回执") { Text(date, format: .dateTime.month().day().hour().minute()) }
                        }
                        if let error = destination.blocked {
                            Text(error).font(.footnote).foregroundStyle(.red)
                        } else if let error = recorder.state.events.compactMap({ $0.deliveries[recipient.rawValue]?.error }).first {
                            Text(error).font(.footnote).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("尚未配置，不会向这里发送记录。仅保存配置不代表服务器已经接通。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button(destination == nil ? "配置接收端" : "修改接收端") { editing = recipient }
                }
            }
            Section {
                Button("重试待传") { recorder.retry() }
                    .disabled(!recorder.state.enabled || recorder.state.events.isEmpty)
                Button("放弃全部待传记录", role: .destructive) { confirmDiscard = true }
                    .disabled(recorder.state.events.isEmpty)
            } footer: {
                Text("两边分别确认，一边失败不影响另一边。最多补传 7 天内、服务器配置后发生的记录；超过期限或被拒绝的记录保留并标明失败。后台由 iOS 调度，不保证实时；打开 Cove 或下次自动化会继续同步。")
            }
            Section("配置自动化") {
                Text("每个 App 分别设置「打开」和「关闭」触发器，各放一个 Cove 的「记录 App 活动」动作，并明确选定对应 App 与活动。不要把多个 App 合在一个触发器后，把动作固定成同一个名称。")
                Text("选「立即运行」，正常记录不需要「显示结果」。旧的联网自动化保持停用，避免重复记录。只统计已配置且实际触发的事件，不是系统全量屏幕使用时间。")
                Text("接收地址与密钥独立于聊天连接。更换聊天服务器不会自动改投待传记录；这里只使用两边各自的写入专用密钥。")
            }.font(.footnote)
        }
        .navigationTitle("App 活动自动记录")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { recipient in
            NavigationStack { ActivityDestinationEditor(recipient: recipient, recorder: recorder) }
        }
        .confirmationDialog("放弃全部尚未确认的记录？", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("放弃手机待传记录", role: .destructive) { recorder.discardPending() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("只清除手机待传队列，不会删除服务器历史。已经送达但回执丢失的记录可能仍在服务器上。")
        }
        .task { recorder.refresh(); await recorder.schedule() }
    }
}

private struct ActivityDestinationEditor: View {
    let recipient: ActivityRecipient
    @ObservedObject var recorder: CoveActivityRecorder
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL = ""
    @State private var token = ""
    @State private var enabled = true
    @State private var error: String?
    var body: some View {
        Form {
            Section("服务基址") {
                TextField("https://你的服务地址/路径", text: $baseURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Text("保留原有 /cove 或 /ccc 前缀，不要附加 app-events 接口。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("独立上报密钥") {
                SecureField("上报专用密钥；留空保留已保存的密钥", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                Text("密钥只进钥匙串，不进入快捷指令或待传文件。不要填写聊天连接密钥。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Toggle("向这个接收端同步", isOn: $enabled)
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            } footer: {
                Text("开启后，新的活动会发到上方地址；已有待传只继续发给原接收端。暂停会保留待传。")
            }
        }
        .navigationTitle(recipient.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    do {
                        try recorder.save(recipient: recipient, baseURL: baseURL, token: token, enabled: enabled)
                        token = ""; dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
        .onAppear {
            if let old = recorder.state.destinations.first(where: { $0.id == recipient }) {
                baseURL = old.baseURL; enabled = old.enabled
            } else if recipient == .cove {
                baseURL = UserDefaults.standard.string(forKey: "cove.serverURL") ?? ""
            }
        }
    }
}
