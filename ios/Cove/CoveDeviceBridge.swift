import Foundation
import SwiftUI

struct CoveDeviceRequest: Codable, Equatable, Identifiable {
    let id: String
    let conversationID: String
    let deviceID: String
    let action: CoveDeviceAction
    let status: String
    let createdAt: Date
    var result: CoveDeviceActionResult?
    var error: String?

    /// Only retire an acknowledged outcome; a tap/claim is not completion.
    var showsInChat: Bool {
        switch status {
        case "succeeded": return result?.actionID != action.id
        case "denied", "expired": return false
        default: return true // Pending, failed and uncertain outcomes remain visible.
        }
    }

    func validate(conversation: String, device: String, now: Date = Date()) throws {
        guard conversationID == conversation, deviceID == device, UUID(uuidString: id) == action.id,
              status == "pending" else { throw CoveDeviceActionError.invalid("设备请求不属于当前对话，或已处理") }
        try action.validate(now: now)
    }
}

struct CoveDeviceRequestsEnvelope: Decodable { let requests: [CoveDeviceRequest] }
struct CoveDeviceRequestEnvelope: Decodable { let ok: Bool; let request: CoveDeviceRequest }

/// A durable receipt is retried; the corresponding Apple operation is never retried.
struct CoveDeviceReceipt: Codable {
    let scope: String
    let request: CoveDeviceRequest
    let status: String
    let result: CoveDeviceActionResult?
    let error: String?
    var readAuthorizationRevision: UUID? = nil

    func matchesTerminal(_ recorded: CoveDeviceRequest) -> Bool {
        recorded.id == request.id && recorded.conversationID == request.conversationID
            && recorded.deviceID == request.deviceID && recorded.action == request.action
            && ["succeeded", "failed", "denied", "expired"].contains(recorded.status)
            && (recorded.status != "succeeded" || recorded.result?.actionID == request.action.id)
    }
}

final class CoveDeviceReceiptJournal {
    private let directory: URL
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cove/device-receipts", isDirectory: true)) { self.directory = directory }
    func save(_ receipt: CoveDeviceReceipt) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(receipt)
        try data.write(to: file(receipt.request.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func load(scope: String, conversation: String) throws -> [CoveDeviceReceipt] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.compactMap { url in
                let receipt = try JSONDecoder().decode(CoveDeviceReceipt.self, from: Data(contentsOf: url))
                return receipt.scope == scope && receipt.request.conversationID == conversation ? receipt : nil
            }
    }
    func remove(_ receipt: CoveDeviceReceipt) throws { try FileManager.default.removeItem(at: file(receipt.request.id)) }
    private func file(_ id: String) -> URL {
        // Remote identifiers never become arbitrary paths.
        directory.appendingPathComponent((UUID(uuidString: id)?.uuidString ?? "invalid") + ".json")
    }
}

extension CoveDeviceAction.Operation {
    var displayTitle: String {
        switch self {
        case .listReminders: return "读取提醒事项"
        case .createReminder: return "创建提醒事项"
        case .completeReminder: return "完成提醒事项"
        case .deleteReminder: return "删除提醒事项"
        case .listEvents: return "读取日历"
        case .createEvent: return "添加日程"
        case .deleteEvent: return "删除这一次日程"
        case .listAlarms: return "读取 Cove 闹钟"
        case .scheduleAlarm: return "设置 Cove 闹钟"
        case .cancelAlarm: return "取消 Cove 闹钟"
        }
    }
}

struct CoveDeviceRequestCard: View {
    @EnvironmentObject private var store: CoveStore
    let item: CoveDeviceRequest
    @State private var confirming = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let expired = item.action.expiresAt <= context.date
            let busy = store.respondingDeviceRequestIDs.contains(item.id)
            VStack(alignment: .leading, spacing: 8) {
                Label(item.action.operation.displayTitle, systemImage: item.action.operation.capability.symbol)
                    .font(.headline)
                Text(details).font(.subheadline).textSelection(.enabled)
                Text("有效至 \(item.action.expiresAt.formatted(date: .omitted, time: .standard)) · \(TimeZone.current.identifier)")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = store.deviceRequestErrors[item.id] { Text(error).font(.caption).foregroundStyle(.red) }
                if let error = item.error { Text(error).font(.caption).foregroundStyle(.red) }
                if item.status == "pending", !expired {
                    HStack {
                        Button("拒绝", role: .cancel) { Task { await store.respondToDeviceRequest(item, allow: false) } }.frame(minWidth: 44, minHeight: 44)
                        Spacer()
                        if item.action.operation.isMutation {
                            Button("核对并确认…") { confirming = true }.frame(minHeight: 44)
                                .disabled(item.action.targetID != nil && store.deviceRequestTargets[item.id] == nil)
                        } else { Text("等待持续读取授权或本机处理").font(.caption) }
                        if busy { ProgressView() }
                    }.disabled(busy || !store.isConnected)
                } else {
                    Text(expired && item.status == "pending" ? "已过期，没有执行" : statusText)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(14).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .confirmationDialog(item.action.operation.displayTitle, isPresented: $confirming, titleVisibility: .visible) {
                    Button("确认执行", role: [.deleteReminder, .deleteEvent, .cancelAlarm].contains(item.action.operation) ? .destructive : nil) {
                        Task { await store.respondToDeviceRequest(item, allow: true) }
                    }
                    Button("取消", role: .cancel) {}
                } message: { Text(details + "\n只执行此项操作；不会自动重试。") }
                .accessibilityIdentifier("device.request.\(item.id)")
        }
    }
    private var details: String {
        let target = store.deviceRequestTargets[item.id]
        var lines: [String] = []
        if let title = target?.title ?? item.action.title { lines.append(title) }
        if let start = target?.start ?? item.action.start { lines.append("时间：" + start.formatted(date: .complete, time: .standard)) }
        if let end = target?.end ?? item.action.end { lines.append("结束：" + end.formatted(date: .complete, time: .standard)) }
        if item.action.operation == .createReminder, item.action.start == nil { lines.append("不设提醒时间") }
        if let id = item.action.targetID { lines.append("目标 ID：" + id) }
        return lines.joined(separator: "\n")
    }
    private var statusText: String {
        switch item.status {
        case "succeeded": return item.result?.message ?? "本机已完成"
        case "failed": return "未完成；请查看错误，不会自动重试"
        case "denied": return "已拒绝，没有执行"
        case "claimed": return "已领取；等待本机回执，结果不确定时不会重复执行"
        default: return "请求已结束：\(item.status)"
        }
    }
}
