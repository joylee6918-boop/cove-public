import SwiftUI
import UIKit

struct CoveShellView: View {
    @EnvironmentObject private var store: CoveStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var shell: CoveShellController
    @State private var input = ""
    @State private var confirmingEnd = false
    @State private var endingSessionID: String?

    init(controller: CoveShellController) { shell = controller }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("交互服务器 Shell · 只读 · 无网络\n当前 Codex 任务过程在「Codex 日志」").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 8)
                    Text(statusLabel).font(.caption.monospaced()).foregroundStyle(.secondary).fixedSize()
                }
                HStack(spacing: 10) {
                    if shell.state != "running" {
                        Button(shell.isStarting ? "正在连接…" : "连接 Shell") { Task { await connectIfAllowed() } }
                            .buttonStyle(.borderedProminent).frame(minHeight: 44)
                            .disabled(shell.isStarting || shell.state == "stopping" || !canConnect).accessibilityIdentifier("shell.connect")
                    } else {
                        Button("结束 Shell", role: .destructive) {
                            endingSessionID = shell.sessionID; confirmingEnd = true
                        }.frame(minHeight: 44).disabled(shell.isStarting)
                    }
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel("关闭页面，保留 Shell")
                }
                if let error = shell.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        .accessibilityIdentifier("shell.error")
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Text(shell.output.isEmpty ? emptyMessage : shell.output)
                        .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
                    Color.clear.frame(height: 1).id("shell-end")
                }
                .onChange(of: shell.output) { _, _ in proxy.scrollTo("shell-end", anchor: .bottom) }
            }.frame(maxHeight: .infinity)
            Divider()
            HStack(spacing: 8) {
                Button("Ctrl-C") { Task { await shell.sendControl(0x03) } }.frame(minWidth: 44, minHeight: 44).disabled(shell.state != "running")
                Button("Esc") { Task { await shell.sendControl(0x1b) } }.frame(minWidth: 44, minHeight: 44).disabled(shell.state != "running")
                TextField("输入 Shell 命令", text: $input)
                    .font(.system(.body, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { submit() }.disabled(shell.state != "running")
                Button(shell.isWriting ? "发送中…" : "发送") { submit() }.frame(minWidth: 44, minHeight: 44)
                    .disabled(shell.state != "running" || shell.isStarting || shell.isWriting || input.isEmpty)
            }.padding(10)
        }
        .task { if canConnect { await shell.enterView() } }
        .onDisappear { Task { await shell.leaveView() } }
        .confirmationDialog("结束这个 Shell？", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("结束 Shell", role: .destructive) {
                let expectedSession = endingSessionID
                Task {
                    guard let expectedSession, shell.sessionID == expectedSession else { return }
                    await shell.closeSession()
                }
            }
            Button("取消", role: .cancel) { }
        } message: { Text("会停止这个独立 Shell 中的命令，不会结束聊天。只想收起页面，请点右上角关闭。") }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in Task { await shell.background() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if canConnect { Task { await shell.resumeIfNeeded() } }
        }
    }

    private var canConnect: Bool { store.isConnected && !store.previewMode }
    private func connectIfAllowed() async { if canConnect { await shell.enterView() } }
    private var statusLabel: String {
        if shell.isStarting { return "连接中" }
        switch shell.state {
        case "running": return "已连接"
        case "terminated", "exited": return "已结束"
        case "stopping": return "正在结束"
        case "unknown": return "状态待确认"
        case "failed": return "连接失败"
        default: return "未连接"
        }
    }
    private var emptyMessage: String {
        if store.previewMode { return "示例模式不会连接或启动真实 Shell。" }
        if !store.isConnected { return "请先连接 Cove 服务，再启动 Shell。" }
        if shell.isStarting { return "正在连接真实 PTY…" }
        if shell.state == "running" { return "Shell 已连接，正在等待交互提示符…" }
        if shell.errorMessage != nil { return "Shell 连接失败。可点上方“连接 Shell”重试。" }
        return "尚未连接 Shell。进入此页会自动连接，也可点上方按钮重试。"
    }

    private func submit() {
        let line = input; guard !line.isEmpty else { return }
        Task { if await shell.sendLine(line), input == line { input = "" } }
    }
}

enum CoveTerminalDisplayMode: String, CaseIterable { case codex = "Codex 日志"; case shell = "Shell" }

struct CoveTerminalModeContainer<CodexContent: View>: View {
    @State private var mode: CoveTerminalDisplayMode = .codex
    @StateObject private var shell: CoveShellController
    let codexContent: () -> CodexContent

    init(shellAPI: CoveShellAPI, @ViewBuilder codexContent: @escaping () -> CodexContent) {
        _shell = StateObject(wrappedValue: CoveShellController(api: shellAPI))
        self.codexContent = codexContent
    }
    var body: some View {
        VStack(spacing: 0) {
            Picker("终端模式", selection: $mode) {
                ForEach(CoveTerminalDisplayMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
            if mode == .codex { codexContent() } else { CoveShellView(controller: shell) }
        }
    }
}
