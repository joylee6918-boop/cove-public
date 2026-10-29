import SwiftUI

/// A plain-text view of the conversation's existing CLI tmux pane, not a TUI emulator.
struct CoveTmuxView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: CoveTmuxModel
    @State private var draft = ""
    @State private var confirmTerminate = false
    @State private var pendingTerminationSessionID: String?
    @State private var confirmRecover = false
    @State private var pendingRecoverySessionID: String?
    @State private var pendingRecoveryThreadID: String?
    @State private var followsTail = true
    @State private var userScrolling = false
    @State private var scrollToTopRequest = 0
    @ScaledMetric(relativeTo: .body) private var terminalFontSize: CGFloat = 14
    private let preview: Bool

    init(api: CoveTmuxAPI, conversationID: String, preview: Bool = false) {
        _model = StateObject(wrappedValue: CoveTmuxModel(api: api, conversationID: conversationID))
        self.preview = preview
    }

    /// Allows a synthetic, pre-attached model to be rendered in tests without
    /// changing the normal attach/detach lifecycle used by the app.
    init(model: CoveTmuxModel) {
        _model = StateObject(wrappedValue: model)
        self.preview = false
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            sessionBar
            Divider()
            terminalOutput
            notices
            if !preview { controls }
        }
        .background(CoveStyle.terminalBackground)
        .foregroundStyle(CoveStyle.terminalText)
        .tint(CoveStyle.terminalAccent)
        .task(id: scenePhase) {
            if preview { return }
            if scenePhase == .active { await model.enter() }
            else { model.detach() }
        }
        .onDisappear { model.detach() }
        .alert("强制退出当前会话？", isPresented: $confirmTerminate) {
            Button("取消", role: .cancel) {}
            Button("强制退出", role: .destructive) {
                guard let id = pendingTerminationSessionID else { return }
                Task { await model.forceTerminate(expectedSessionID: id) }
            }
        } message: {
            Text("只请求停止当前 tmux 会话 \(pendingTerminationSessionID ?? "未知")。不保证所有子进程都已停止；离开页面或进入后台不会执行此操作。")
        }
        .confirmationDialog("恢复当前对话？", isPresented: $confirmRecover, titleVisibility: .visible) {
            Button("恢复原线程") {
                guard let session = pendingRecoverySessionID,
                      let thread = pendingRecoveryThreadID else { return }
                Task { await model.recover(expectedSessionID: session, expectedThreadID: thread) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只为已终止会话 \(pendingRecoverySessionID ?? "未知") 重新启动原对话线程，不重发任何旧消息。结果不确定时请重新附着查看，不要重复点击恢复。")
        }
    }

    private var header: some View {
        HStack {
            Text("终端")
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                model.detach()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(CoveStyle.softAccent, in: Circle())
            }
            .accessibilityLabel("关闭终端画面，保持会话运行")
            .accessibilityIdentifier("tmux.close")
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var sessionBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Circle().fill(.orange).frame(width: 8, height: 8)
                Circle().fill(.green).frame(width: 8, height: 8)
            }
            .accessibilityHidden(true)
            Text("Codex")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(CoveStyle.softAccent, in: Capsule())
                .accessibilityLabel("Codex，\(statusLabel)")
            Spacer(minLength: 4)
            Text("\(model.capturedLineCount) 行")
                .font(.caption.monospacedDigit())
                .foregroundStyle(CoveStyle.secondaryText)
                .accessibilityLabel("画面 \(model.capturedLineCount) 行")
            Button { Task { await model.captureNow() } } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("刷新终端画面")
            .accessibilityIdentifier("tmux.refresh")
            .disabled(!canCapture)
            Menu {
                Button("重新附着", systemImage: "arrow.triangle.2.circlepath") {
                    model.detach()
                    Task { await model.enter() }
                }
                .disabled(model.isAttaching || preview)
                Button("中断当前回合 (Ctrl-C)", systemImage: "stop.circle") {
                    Task { await model.sendKey("C-c") }
                }
                .disabled(preview || !model.canSendKey("C-c"))
                if model.snapshot?.state == "terminated" {
                    Button("恢复当前对话", systemImage: "arrow.counterclockwise") {
                        askRecover()
                    }
                    .disabled(preview || !model.canRecover)
                }
                Divider()
                Button("强制退出当前会话", systemImage: "xmark.circle", role: .destructive) {
                    pendingTerminationSessionID = model.snapshot?.sessionID
                    confirmTerminate = true
                }
                .disabled(!canTerminate)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("终端选项")
            .accessibilityIdentifier("tmux.options")
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .frame(minHeight: 48)
    }

    private var terminalOutput: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(width: 1, height: 1).id("start")
                    Text(model.snapshot?.output.isEmpty == false ? model.snapshot!.output : emptyMessage)
                        .font(.system(size: terminalFontSize, design: .monospaced))
                        .foregroundStyle(CoveStyle.terminalText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                    Color.clear.frame(width: 1, height: 1).id("end")
                }
            }
            .defaultScrollAnchor(.topLeading)
            .accessibilityIdentifier("tmux.output")
            .onScrollPhaseChange { previous, phase, context in
                userScrolling = phase == .interacting || phase == .decelerating
                if phase == .idle && (previous == .interacting || previous == .decelerating) {
                    followsTail = context.geometry.contentSize.height - context.geometry.visibleRect.maxY < 80
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY < 80
            } action: { _, atBottom in
                if atBottom { followsTail = true }
                else if userScrolling { followsTail = false }
            }
            .onChange(of: model.snapshot?.revision) { _, _ in
                guard followsTail, !userScrolling else { return }
                withTransaction(Transaction(animation: nil)) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: scrollToTopRequest) { _, _ in
                followsTail = false
                userScrolling = false
                proxy.scrollTo("start", anchor: .top)
            }
            .overlay(alignment: .bottomTrailing) {
                if !followsTail {
                    Button("回到底部", systemImage: "arrow.down") {
                        userScrolling = false
                        followsTail = true
                        proxy.scrollTo("end", anchor: .bottom)
                    }
                    .font(.caption)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(12)
                    .accessibilityIdentifier("tmux.latest")
                }
            }
        }
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !preview && model.snapshot?.state == "running" && model.snapshot?.inputAvailable != true {
                Label(model.canSendKey("C-c")
                      ? "自由输入的回合同步尚未接完，当前可中断或强退。"
                      : "自由输入的回合同步尚未接完，当前仅可显式强退。",
                      systemImage: "info.circle")
                    .foregroundStyle(CoveStyle.secondaryText)
            }
            if model.snapshot?.state == "unavailable" {
                Label("终端暂不可用，可刷新或强退。", systemImage: "wifi.slash")
                    .foregroundStyle(CoveStyle.secondaryText)
            }
            if model.snapshot?.state == "terminated" {
                Label("会话已终止。", systemImage: "stop.circle")
                    .foregroundStyle(CoveStyle.secondaryText)
                if model.canRecover {
                    Button("恢复当前对话") { askRecover() }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("tmux.recover")
                }
            }
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(CoveStyle.error)
            }
            if let message = model.uncertainWriteMessage {
                Label(message, systemImage: "questionmark.circle")
                    .foregroundStyle(CoveStyle.error)
            }
        }
        .font(.caption)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
        .accessibilityIdentifier("tmux.notice")
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    keyButton("Esc", value: "Escape")
                    keyButton("↑", value: "Up")
                    Button("↑↑") { scrollToTopRequest += 1 }
                        .accessibilityLabel("回到终端画面顶部，仅本地滚动")
                        .accessibilityIdentifier("tmux.scrollTop")
                        .modifier(TerminalShortcutStyle())
                    keyButton("↓", value: "Down")
                    keyButton("Enter", value: "Enter")
                        .frame(minWidth: 60)
                    Button("清输入") { draft = "" }
                        .accessibilityHint("只清空本地输入框，不清屏或清除对话")
                        .accessibilityIdentifier("tmux.clearDraft")
                        .disabled(draft.isEmpty)
                        .modifier(TerminalShortcutStyle())
                        .frame(minWidth: 62)
                }
                .padding(.horizontal, 18)
            }
            HStack(spacing: 8) {
                Text("$")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .accessibilityHidden(true)
                TextField("命令（不会自动回车）", text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(!model.canSendText)
                    .accessibilityLabel("终端文字输入，不会自动回车")
                    .accessibilityIdentifier("tmux.input")
                Button("输入") {
                    // Preserve the draft even when the write acknowledgement is uncertain.
                    let literal = draft
                    Task { await model.sendText(literal) }
                }
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .disabled(!model.canSendText || draft.isEmpty)
                .accessibilityIdentifier("tmux.sendText")
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .frame(minHeight: 48)
            .background(CoveStyle.softAccent, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 18)
        }
        .padding(.vertical, 8)
        .background(CoveStyle.terminalBackground)
    }

    private var canCapture: Bool {
        !preview && (model.snapshot?.state == "running" || model.snapshot?.state == "unavailable")
    }

    private var canTerminate: Bool {
        canCapture && !model.isWriting && model.snapshot?.sessionID.isEmpty == false
    }

    private var emptyMessage: String {
        if preview { return "示例预览不连接真实任务会话。" }
        if model.isAttaching { return "正在附着当前对话已有的终端会话…" }
        return "当前没有可显示的终端画面。这里不会创建新的 Shell。"
    }

    private var statusLabel: String {
        switch model.snapshot?.state {
        case "running": "终端已连接"
        case "unavailable": "终端暂不可用"
        case "terminated": "会话已终止"
        default: model.isAttaching ? "正在连接" : "未连接"
        }
    }

    private func keyButton(_ label: String, value: String) -> some View {
        Button(label) { Task { await model.sendKey(value) } }
            .accessibilityLabel(value == "Enter" ? "发送回车" : value)
            .accessibilityIdentifier(value == "Enter" ? "tmux.enter" : "tmux.key.\(value)")
            .disabled(preview || !model.canSendKey(value))
            .modifier(TerminalShortcutStyle())
    }

    private func askRecover() {
        pendingRecoverySessionID = model.snapshot?.sessionID
        pendingRecoveryThreadID = model.snapshot?.threadID
        confirmRecover = true
    }
}

private struct TerminalShortcutStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(.subheadline, design: .monospaced).weight(.medium))
            .frame(minWidth: 44, minHeight: 44)
            .background(CoveStyle.softAccent, in: RoundedRectangle(cornerRadius: 10))
    }
}

#Preview("终端 · 合成画面") {
    let sample = CoveTmuxSnapshot(
        sessionID: "mock-session", conversationID: "mock-conversation",
        threadID: "mock-thread", state: "running",
        output: "› Codex\n\n• 正在处理合成示例任务\n  已检查 3 个文件\n  下一步：等待确认\n\n$",
        revision: 1, inputAvailable: false, allowedKeys: ["C-c"]
    )
    CoveTmuxView(
        api: CoveTmuxAPI(
            attach: { sample }, capture: { _ in sample },
            input: { _, _, _ in }, key: { _, _, _ in },
            terminate: { _, _ in }
        ),
        conversationID: "mock-conversation"
    )
}
