import SwiftUI

struct CoveTerminalView: View {
    @EnvironmentObject private var store: CoveStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var terminal = CoveTerminalViewModel()
    @State private var showModels = false
    @State private var selectedApproval: CoveTerminalApproval?
    @State private var followsTail = true
    @State private var userScrolling = false
    @State private var unseenEvents = 0
    @State private var showClearConfirmation = false
    @State private var jumpToTail = 0
    @FocusState private var inputFocused: Bool

    private var activityKey: String { "\(store.activeConversationID)|\(scenePhase == .active)|\(store.previewMode)" }
    private var isLocalScrollFixture: Bool {
        #if DEBUG
        store.previewMode && ProcessInfo.processInfo.arguments.contains("--terminal-scroll-qa")
        #else
        false
        #endif
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                Divider()
                eventLog
                if let error = terminal.error ?? terminal.connectionError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(CoveStyle.error).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .accessibilityIdentifier("terminal.error")
                }
                if !terminal.approvals.isEmpty {
                    Button { selectedApproval = terminal.approvals.first } label: {
                        HStack {
                            Label("有 \(terminal.approvals.count) 项操作等待你审核", systemImage: "hand.raised")
                            Spacer()
                            Image(systemName: "chevron.right")
                        }.font(.subheadline).padding(12).frame(minHeight: 44)
                    }.tint(CoveStyle.accentText).background(CoveStyle.softAccent)
                        .accessibilityIdentifier("terminal.approvals")
                }
                composer
            }.background(CoveStyle.terminalBackground)
                .foregroundStyle(CoveStyle.terminalText)
                .tint(CoveStyle.terminalAccent)
                .navigationTitle("会话控制台").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() }.accessibilityIdentifier("terminal.close") }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { showModels = true } label: { Image(systemName: "cpu").frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("切换模型").accessibilityIdentifier("terminal.models")
                            .disabled(store.previewMode || !terminal.isPolling)
                        Menu {
                            Button("复制日志", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = terminal.events.map { "[\($0.kind)] \($0.text)" }.joined(separator: "\n")
                            }.disabled(terminal.events.isEmpty)
                            Button("刷新", systemImage: "arrow.clockwise") { Task { await terminal.refresh() } }.disabled(store.previewMode)
                        } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("控制台选项")
                    }
                }
        }
        .task(id: activityKey) {
            guard scenePhase == .active else { return }
            #if DEBUG
            if isLocalScrollFixture { terminal.loadLocalScrollFixture(); return }
            #endif
            await terminal.run(service: CoveStoreTerminalService(store: store), conversationID: store.activeConversationID, preview: store.previewMode)
        }
        .alert("开启新对话，旧记录保留", isPresented: $showClearConfirmation) {
            Button("取消", role: .cancel) {}
            Button("开启新对话") { Task { await terminal.clearContext() } }
        } message: {
            Text("当前回复会停止，新对话会使用当前模型设置。")
        }
        .onChange(of: store.activeConversationID) {
            followsTail = true; userScrolling = false; unseenEvents = 0
            selectedApproval = nil; showModels = false
        }
        .sheet(isPresented: $showModels) { CoveTerminalModelPicker(terminal: terminal) }
        .sheet(item: $selectedApproval) { approval in CoveTerminalApprovalView(terminal: terminal, approval: approval) }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle().fill(terminal.connected ? CoveStyle.terminalAccent : CoveStyle.secondaryText).frame(width: 7, height: 7)
                Text(store.previewMode ? "示例模式 · 不连接控制台" : terminal.connected ? (terminal.busy ? "当前会话正在运行" : "运行时已连接") : "运行时尚未连接")
                    .font(.caption.weight(.medium))
                Spacer()
                if terminal.isPolling { Image(systemName: "antenna.radiowaves.left.and.right").font(.caption).foregroundStyle(CoveStyle.secondaryText) }
            }
            Text("同一个 Codex app-server 会话：实时显示思考状态、计划、工具、命令和输出。").font(.caption).foregroundStyle(CoveStyle.secondaryText)
            #if DEBUG
            if isLocalScrollFixture {
                HStack {
                    Text("合成日志 · 不联网").font(.caption)
                    Spacer()
                    Button("追加") { terminal.appendLocalScrollFixture() }
                        .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("terminal.qa.append")
                    Button("扩展") { terminal.appendLocalScrollFixture(growingLastEvent: true) }
                        .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("terminal.qa.grow")
                }
            }
            #endif
            if let model = terminal.model {
                Text("下一次回复：\(model)\(terminal.effort.map { " · " + $0 } ?? "")")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(CoveStyle.terminalAccent).lineLimit(2)
            }
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var eventLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if terminal.events.isEmpty {
                        Text(store.previewMode ? "控制台只显示真实会话。退出示例预览后连接服务即可使用。" : "等待当前会话的日志。可输入 /help 查看可用指令。")
                            .font(.system(.subheadline, design: .monospaced)).foregroundStyle(CoveStyle.secondaryText)
                            .padding(.vertical, 24)
                    }
                    ForEach(terminal.events) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(event.createdAt, format: .dateTime.hour().minute().second())
                                Text(event.kind)
                            }.font(.system(.caption2, design: .monospaced)).foregroundStyle(CoveStyle.secondaryText)
                            Text(event.text).font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(event.kind == "error" ? CoveStyle.error : event.kind == "input" ? CoveStyle.terminalAccent : CoveStyle.terminalText)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.accessibilityIdentifier("terminal.event.\(event.id)")
                    }
                    if let notice = terminal.notice {
                        Text(notice).font(.system(.caption, design: .monospaced)).foregroundStyle(CoveStyle.terminalAccent)
                    }
                    if isLocalScrollFixture {
                        Text("本地日志末尾 \(terminal.events.last?.id ?? 0)").font(.caption)
                            .accessibilityIdentifier("terminal.qa.tail").id("terminal-bottom")
                    } else {
                        Color.clear.frame(height: 1).id("terminal-bottom")
                    }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("terminal.log")
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(followsTail ? .bottom : nil, for: .sizeChanges)
            .onScrollPhaseChange { previous, phase, context in
                // A tap/selection can track without actually scrolling. Only a
                // real drag/deceleration opts out of following live output.
                userScrolling = phase == .interacting || phase == .decelerating
                if phase == .idle && (previous == .interacting || previous == .decelerating) {
                    followsTail = context.geometry.contentSize.height - context.geometry.visibleRect.maxY < 80
                    if followsTail { unseenEvents = 0; scrollToTail(proxy) }
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY < 80
            } action: { _, value in
                if value { followsTail = true; unseenEvents = 0 }
                else if userScrolling { followsTail = false }
            }
            .onScrollGeometryChange(for: CGSize.self) { geometry in
                // React after lazy rows have actually grown/wrapped, not only
                // before layout when a new event ID arrives.
                CGSize(width: geometry.visibleRect.height.rounded(), height: geometry.contentSize.height.rounded())
            } action: { _, _ in
                if followsTail { scrollToTail(proxy) }
            }
            .onChange(of: terminal.events) { previous, _ in
                if followsTail { scrollToTail(proxy) }
                else { unseenEvents += terminal.events.filter { $0.id > (previous.last?.id ?? 0) }.count }
            }
            .onChange(of: terminal.notice) {
                if followsTail { scrollToTail(proxy) }
            }
            .onChange(of: inputFocused) {
                if followsTail { scrollToTail(proxy) }
            }
            .onChange(of: jumpToTail) {
                userScrolling = false; followsTail = true; unseenEvents = 0; scrollToTail(proxy)
            }
            .overlay(alignment: .bottomTrailing) {
                if !followsTail {
                    Button { jumpToTail += 1 } label: {
                        Label(unseenEvents > 0 ? "\(unseenEvents) 条新日志" : "回到底部", systemImage: "arrow.down").font(.caption).padding(12)
                            .background(.regularMaterial, in: Capsule())
                    }.foregroundStyle(CoveStyle.terminalAccent).padding(12)
                        .accessibilityIdentifier("terminal.latest")
                }
            }
        }
    }

    private func scrollToTail(_ proxy: ScrollViewProxy) {
        let conversation = store.activeConversationID
        Task { @MainActor in
            await Task.yield()
            guard followsTail, !userScrolling, conversation == store.activeConversationID else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo("terminal-bottom", anchor: .bottom) }
        }
    }

    private var shortcuts: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                shortcut("model", label: "切换模型", id: "model") { showModels = true }
                shortcut("clear", label: "开启新对话，旧记录保留", id: "clear") { showClearConfirmation = true }
                Button { escape() } label: {
                    HStack(spacing: 5) {
                        if terminal.isStopping { ProgressView().controlSize(.small) }
                        Text("Esc · 停止")
                    }.font(.system(.caption, design: .monospaced).weight(.medium))
                        .padding(.horizontal, 12).frame(minHeight: 44)
                        .background(CoveStyle.softAccent, in: Capsule())
                }.buttonStyle(.plain).accessibilityLabel(terminal.isStopping ? "正在停止当前回复" : "停止当前回复")
                    .accessibilityIdentifier("terminal.shortcut.esc")
                    .disabled(store.previewMode || !terminal.isPolling || terminal.isStopping)
                shortcut("help", label: "查看控制台帮助", id: "help") { Task { await terminal.showHelp() } }
                Button { jumpToTail += 1 } label: {
                    Image(systemName: "arrow.down.to.line").frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("回到底部").accessibilityIdentifier("terminal.shortcut.bottom")
                Button {
                    inputFocused = false
                    // The multiline native field can retain first responder in
                    // a sheet even after the SwiftUI focus binding clears.
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down").frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("收起键盘").accessibilityIdentifier("terminal.shortcut.keyboard")
            }.padding(.horizontal, 14).padding(.vertical, 4)
                .foregroundStyle(CoveStyle.terminalAccent)
        }.accessibilityIdentifier("terminal.shortcuts")
    }

    private func shortcut(_ title: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(.caption, design: .monospaced).weight(.medium))
                .padding(.horizontal, 12).frame(minHeight: 44)
                .background(CoveStyle.softAccent, in: Capsule())
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityIdentifier("terminal.shortcut.\(id)")
            .disabled(store.previewMode || !terminal.isPolling || terminal.isSubmitting)
    }

    private func escape() {
        if selectedApproval != nil { selectedApproval = nil }
        else if showModels { showModels = false }
        else { Task { await terminal.stopCurrentReply() } }
    }

    private func submitDraft() {
        switch terminal.draft.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "/model": terminal.draft = ""; showModels = true
        case "/clear": showClearConfirmation = true
        case "/esc": terminal.draft = ""; escape()
        default: Task { await terminal.submit() }
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            Divider()
            shortcuts
            HStack(alignment: .bottom, spacing: 8) {
                Text(">").font(.system(.body, design: .monospaced)).foregroundStyle(CoveStyle.terminalAccent).frame(height: 44)
                TextField("给当前会话发指令，或 /help", text: $terminal.draft, axis: .vertical)
                    .font(.system(.subheadline, design: .monospaced)).lineLimit(1...5)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().focused($inputFocused)
                    .padding(.vertical, 12).accessibilityIdentifier("terminal.input")
                Button {
                    submitDraft()
                } label: {
                    Group {
                        if terminal.isSubmitting { ProgressView() }
                        else { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    }.frame(width: 44, height: 44)
                }.disabled(store.previewMode || !terminal.isPolling || terminal.isSubmitting || terminal.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("提交指令").accessibilityIdentifier("terminal.send")
            }.padding(.horizontal, 14).padding(.vertical, 4)
        }
    }
}

private struct CoveTerminalModelPicker: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var terminal: CoveTerminalViewModel
    @State private var selectedModel = ""
    @State private var selectedEffort = ""
    private var selected: CoveTerminalModelOption? { terminal.models.first { $0.model == selectedModel } }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if terminal.models.isEmpty {
                        Text(terminal.modelError ?? "正在读取服务端模型列表…").foregroundStyle(CoveStyle.secondaryText)
                    } else {
                        Picker("模型", selection: $selectedModel) {
                            Text("请选择").tag("")
                            ForEach(terminal.models) { model in Text(model.displayName).tag(model.model) }
                        }
                        if let selected {
                            Picker("推理强度", selection: $selectedEffort) {
                                ForEach(selected.supportedEfforts, id: \.self) { effort in Text(effort).tag(effort) }
                            }
                        }
                    }
                    Button("刷新模型列表") { Task { await terminal.refreshModels() } }
                } footer: { Text("从当前服务读取可用模型。保存后，下一次回复生效。") }
                if let error = terminal.modelError ?? terminal.error { Text(error).foregroundStyle(CoveStyle.error).font(.footnote) }
                Button {
                    guard let selected else { return }
                    Task { if await terminal.changeModel(selected, effort: selectedEffort) { dismiss() } }
                } label: {
                    HStack { Text("保存模型"); if terminal.isChangingModel { Spacer(); ProgressView() } }
                }.disabled(selected == nil || selectedEffort.isEmpty || terminal.isChangingModel)
            }.scrollContentBackground(.hidden).background(CoveStyle.terminalBackground)
                .tint(CoveStyle.terminalAccent)
                .navigationTitle("切换模型").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } } }
                .onAppear { selectedModel = terminal.model ?? ""; resetEffort() }
                .onChange(of: selectedModel) { resetEffort() }
                .onChange(of: terminal.models) { resetEffort() }
        }
    }
    private func resetEffort() {
        guard let selected else { selectedEffort = ""; return }
        selectedEffort = selected.supportedEfforts.contains(terminal.effort ?? "") ? (terminal.effort ?? selected.defaultEffort) : selected.defaultEffort
    }
}

private struct CoveTerminalApprovalView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var terminal: CoveTerminalViewModel
    let approval: CoveTerminalApproval
    private var isCurrent: Bool { terminal.approvals.contains { $0.id == approval.id && $0.turnID == approval.turnID } }
    var body: some View {
        NavigationStack {
            Form {
                Section("待审核操作") {
                    Text(approval.reason ?? "当前会话请求执行以下操作。").textSelection(.enabled)
                    if let command = approval.command {
                        ScrollView(.horizontal) { Text(command).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled) }
                    }
                    if let cwd = approval.cwd { LabeledContent("目录", value: cwd).font(.caption) }
                    if let details = approval.details { Text(details).font(.footnote).textSelection(.enabled) }
                    Text("有效至 \(approval.expiresAt.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(CoveStyle.secondaryText)
                }
                if let error = terminal.error { Text(error).font(.footnote).foregroundStyle(CoveStyle.error) }
                if !isCurrent { Text("这项审核已结束，请返回查看最新日志。").foregroundStyle(CoveStyle.secondaryText) }
                Section {
                    Button("允许这一次") { decide(true) }
                        .disabled(!isCurrent || approval.expiresAt <= Date() || !approval.decisions.contains("accept") || terminal.approvalInFlight != nil)
                    Button("拒绝", role: .destructive) { decide(false) }
                        .disabled(!isCurrent || !approval.decisions.contains("decline") || terminal.approvalInFlight != nil)
                    if terminal.approvalInFlight == approval.id { ProgressView("正在提交审核…") }
                }
            }.scrollContentBackground(.hidden).background(CoveStyle.terminalBackground)
                .tint(CoveStyle.terminalAccent)
                .navigationTitle("操作审核").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("返回") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("esc") { dismiss() }
                            .accessibilityLabel("关闭审核查看，保留待审批操作")
                            .accessibilityIdentifier("terminal.approval.esc")
                    }
                }
        }
    }
    private func decide(_ allow: Bool) { Task { if await terminal.decide(approval, allow: allow) { dismiss() } } }
}
