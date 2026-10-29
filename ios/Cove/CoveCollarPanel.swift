import SwiftUI

struct CoveCollarPermissions: Codable, Equatable {
    let conversationID: String
    let readSummary: Bool
    let requestMeasurement: Bool
    let updatedAt: Date?
    let configured: Bool
    let recentActions: [CoveCollarAction]
}

struct CoveCollarAction: Codable, Equatable, Identifiable {
    let id: String
    let action: String
    let status: String
    let createdAt: Date

    var title: String {
        switch action {
        case "read_summary": return "查看健康摘要"
        case "request_measurement": return "请求一次测量"
        case "read_measurement": return "查看测量回执"
        case "permission_update": return "更新权限"
        default: return "Collar 操作"
        }
    }

    var statusLabel: String {
        switch status {
        case "complete":
            if action == "read_summary" { return "摘要已交付工具" }
            if action == "permission_update" { return "权限已保存" }
            return "操作已完成，不代表测量完成"
        case "pending": return "请求待处理，尚未确认完成"
        case "seen": return "手表已接收，尚未确认完成"
        case "done": return "已收到测量回执"
        case "expired": return "请求已过期"
        case "failed", "error": return "未成功"
        case "denied", "forbidden": return "未获授权"
        case "unavailable", "not_configured": return "暂不可用"
        default: return "结果未确认"
        }
    }
}

struct CoveCollarScope: Equatable, Hashable {
    let conversationID: String
    let isConnected: Bool
    let previewMode: Bool

    var canContactServer: Bool {
        isConnected && !previewMode && !conversationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Only acknowledged server responses can change the displayed global grants.
/// Conversation IDs still fence stale responses and scope the visible audit rows.
struct CoveCollarPanelState {
    enum Operation { case loading, saving }

    private(set) var scope: CoveCollarScope?
    private(set) var permissions: CoveCollarPermissions?
    private(set) var operation: Operation?
    private(set) var error: String?
    private var generation = UUID()

    mutating func reset(to scope: CoveCollarScope) {
        self.scope = scope
        permissions = nil
        operation = nil
        error = nil
        generation = UUID()
    }

    mutating func begin(_ operation: Operation, in scope: CoveCollarScope) -> UUID? {
        guard scope.canContactServer else { reset(to: scope); return nil }
        if self.scope != scope { reset(to: scope) }
        guard self.operation == nil else { return nil }
        if operation == .saving && permissions == nil { return nil }
        generation = UUID()
        self.operation = operation
        error = nil
        if operation == .loading { permissions = nil }
        return generation
    }

    mutating func receive(_ value: CoveCollarPermissions, token: UUID, in scope: CoveCollarScope) {
        guard self.scope == scope, generation == token, operation != nil else { return }
        guard value.conversationID == scope.conversationID else {
            fail(token: token, in: scope)
            return
        }
        permissions = value
        operation = nil
        error = nil
    }

    mutating func fail(token: UUID, in scope: CoveCollarScope) {
        guard self.scope == scope, generation == token, operation != nil else { return }
        error = operation == .saving
            ? "未能确认保存结果，服务器上的权限可能已经改变。请点「刷新权限」核实；不会自动重发。"
            : "无法确认服务器上的权限状态。这里未显示为已授权，不代表服务器权限已关闭；请刷新核实。"
        permissions = nil
        operation = nil
    }

    func canChange(_ capability: CoveCollarCapability, in scope: CoveCollarScope) -> Bool {
        guard self.scope == scope, scope.canContactServer, operation == nil, let permissions else { return false }
        // Even a currently unconfigured backend must allow an existing grant to be revoked.
        return permissions.configured || capability.isGranted(in: permissions)
    }
}

enum CoveCollarCapability {
    case readSummary, requestMeasurement

    var title: String {
        self == .readSummary ? "查看健康摘要" : "请求一次测量"
    }

    var detail: String {
        self == .readSummary
            ? "Assistant 可跨对话读取所选过去时段的摘要，每次最多 48 小时。"
            : "Assistant 可在你与他的普通对话中按需请求一次 30 秒心率测量；手表可能需要打开 Collar。"
    }

    func isGranted(in permissions: CoveCollarPermissions) -> Bool {
        self == .readSummary ? permissions.readSummary : permissions.requestMeasurement
    }
}

struct CoveCollarPanel: View {
    let conversationID: String
    let isConnected: Bool
    let previewMode: Bool
    let load: () async throws -> CoveCollarPermissions
    let save: (Bool, Bool) async throws -> CoveCollarPermissions

    @State private var state = CoveCollarPanelState()
    @State private var pendingGrant: CoveCollarCapability?
    @State private var confirmingGrant = false

    private var scope: CoveCollarScope {
        CoveCollarScope(conversationID: conversationID, isConnected: isConnected, previewMode: previewMode)
    }

    private var currentPermissions: CoveCollarPermissions? {
        state.scope == scope && scope.canContactServer ? state.permissions : nil
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("只给 Assistant · 跨对话长期有效")
                    .font(.subheadline.weight(.medium))
                Text("打开后由服务器持久保存，新窗口和重启都继承，直到你主动关闭。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let permissions = currentPermissions {
                    capabilityRow(.readSummary, permissions: permissions)
                    Divider()
                    capabilityRow(.requestMeasurement, permissions: permissions)
                    if !permissions.configured {
                        Label("Collar 接口尚未配置，不能新增授权；已有授权仍可关闭。", systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(unavailableMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if state.scope == scope, let error = state.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("collar.error")
                }

                Text("主动测量仍只能在你发起的普通对话中按需请求，不供心跳或系统自动任务启动。不持续测量、不后台轮询。关闭不撤回已进入对话的数据／已发出的指令。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if scope.canContactServer {
                    if state.scope == scope, let operation = state.operation {
                        ProgressView(operation == .saving ? "正在保存，以服务器确认为准…" : "正在确认权限…")
                            .font(.footnote)
                            .frame(minHeight: 44)
                    } else {
                        Button {
                            Task { await reload() }
                        } label: {
                            Label("刷新权限", systemImage: "arrow.clockwise")
                                .frame(minHeight: 44)
                        }
                        .disabled(confirmingGrant)
                        .accessibilityIdentifier("collar.refresh")
                    }
                }

                if let permissions = currentPermissions {
                    if let date = permissions.updatedAt {
                        Text("权限更新时间：\(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !permissions.recentActions.isEmpty {
                        Divider()
                        Text("近期操作记录").font(.subheadline.weight(.medium))
                        ForEach(Array(permissions.recentActions.prefix(3))) { action in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(action.title) · \(action.statusLabel)").font(.footnote)
                                Text(action.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Collar · 给 Assistant 的权限", systemImage: "applewatch")
        }
        .accessibilityIdentifier("collar.panel")
        .task(id: scope) {
            state.reset(to: scope)
            confirmingGrant = false
            pendingGrant = nil
            await reload()
        }
        .onDisappear {
            state.reset(to: scope)
            confirmingGrant = false
            pendingGrant = nil
        }
        .confirmationDialog("长期授权给 Assistant？", isPresented: $confirmingGrant, titleVisibility: .visible, presenting: pendingGrant) { capability in
            Button("允许「\(capability.title)」，直到我关闭") {
                change(capability, granted: true)
            }
            Button("暂不开启", role: .cancel) {}
        } message: { capability in
            Text("\(capability.detail)\n跨对话与重启持续有效，不逐次询问，直到你主动关闭。关闭不会撤回已读取的数据或已发出的指令。")
        }
    }

    private var unavailableMessage: String {
        if previewMode { return "预览模式：不会读取或更改真实 Collar 权限。" }
        if !isConnected { return "连接 Cove 后，才能确认或更改 Collar 权限。离线不代表已撤销授权。" }
        if !scope.canContactServer { return "先选择一个对话，再设置给 Assistant 的权限。" }
        return "查看健康摘要与请求测量：权限状态尚未确认。"
    }

    private func capabilityRow(_ capability: CoveCollarCapability, permissions: CoveCollarPermissions) -> some View {
        Toggle(isOn: Binding(
            get: { capability.isGranted(in: currentPermissions ?? permissions) },
            set: { granted in
                guard state.canChange(capability, in: scope) else { return }
                if granted {
                    pendingGrant = capability
                    confirmingGrant = true
                } else {
                    change(capability, granted: false)
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                Text(capability.title).font(.subheadline)
                Text(capability.detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 44)
        .disabled(!state.canChange(capability, in: scope) || confirmingGrant)
        .accessibilityHint("更改跨对话持久授权。以服务器保存结果为准。")
        .accessibilityIdentifier(capability == .readSummary ? "collar.readSummary" : "collar.requestMeasurement")
    }

    @MainActor private func reload() async {
        let requestedScope = scope
        guard let token = state.begin(.loading, in: requestedScope) else { return }
        do {
            let value = try await load()
            guard !Task.isCancelled else { return }
            state.receive(value, token: token, in: requestedScope)
        } catch {
            guard !Task.isCancelled else { return }
            state.fail(token: token, in: requestedScope)
        }
    }

    @MainActor private func change(_ capability: CoveCollarCapability, granted: Bool) {
        let requestedScope = scope
        guard state.canChange(capability, in: requestedScope), let permissions = currentPermissions,
              capability.isGranted(in: permissions) != granted,
              let token = state.begin(.saving, in: requestedScope) else { return }
        let read = capability == .readSummary ? granted : permissions.readSummary
        let measure = capability == .requestMeasurement ? granted : permissions.requestMeasurement
        Task {
            do {
                let value = try await save(read, measure)
                state.receive(value, token: token, in: requestedScope)
            } catch {
                state.fail(token: token, in: requestedScope)
            }
        }
    }
}
