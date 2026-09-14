import SwiftUI
import PhotosUI
import UniformTypeIdentifiers


public struct CoveRootView: View {
    @EnvironmentObject private var store: CoveStore
    @State private var keyboardVisible = false
    @State private var wallpaperFrame = CGRect.zero

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            if store.previewMode {
                HStack(spacing: 8) {
                    Image(systemName: "eye")
                    Text("示例预览 · 数据不会上传").font(.caption)
                    Spacer()
                    Button("退出") { store.exitPreview() }.font(.caption.weight(.semibold)).frame(minHeight: 44)
                }
                .padding(.horizontal, 16)
            }
            TabView(selection: $store.selectedTab) {
                NavigationStack { HomeView().navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar) }.tabItem { Label("家", systemImage: "house").accessibilityIdentifier("tab.home") }.tag(0)
                NavigationStack { PulseView().navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar) }.tabItem { Label("心跳", systemImage: "heart").accessibilityIdentifier("tab.pulse") }.tag(1)
                NavigationStack { ChatView().toolbar(.hidden, for: .tabBar) }.tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right").accessibilityIdentifier("tab.chat") }.tag(2)
                NavigationStack { HealthView().navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar) }.tabItem { Label("健康", systemImage: "heart.text.square").accessibilityIdentifier("tab.health") }.tag(3)
                NavigationStack { SettingsView().navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar) }.tabItem { Label("设置", systemImage: "gearshape").accessibilityIdentifier("tab.settings") }.tag(4)
            }
            .toolbar(.hidden, for: .tabBar)
            if !keyboardVisible {
                CoveCompactTabBar(selection: $store.selectedTab)
                    .padding(.horizontal, 36)
                    .padding(.top, 4)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity)
            }
        }
        .background {
            if store.selectedTab == 2 {
                CoveChatWallpaperView()
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { wallpaperFrame = $0 }
                    .ignoresSafeArea()
            } else {
                CoveStyle.card.ignoresSafeArea()
            }
        }
        .environment(\.coveWallpaperFrame, wallpaperFrame)
        .foregroundStyle(CoveStyle.text)
        .tint(CoveStyle.teal)
        .toolbarBackground(CoveStyle.card, for: .navigationBar, .tabBar)
        .toolbarBackground(.visible, for: .navigationBar, .tabBar)
        .preferredColorScheme(store.appearance == "dark" ? .dark : store.appearance == "light" ? .light : nil)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
    }
}

private struct Avatar: View {
    let name: String
    var size: CGFloat = 44
    var body: some View {
        Text(name == "助手" ? "C" : "我")
            .font(.system(size: size * 0.40, weight: .medium, design: .rounded))
            .foregroundStyle(CoveStyle.teal)
            .frame(width: size, height: size)
            .background(CoveStyle.teal.opacity(0.12), in: Circle())
            .accessibilityLabel(name + "的头像")
    }
}

private struct HomeView: View {
    @EnvironmentObject private var store: CoveStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Avatar(name: "用户", size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("用户与 助手").font(.title3.weight(.semibold))
                        Text("把日常留在这里。").font(.subheadline).foregroundStyle(CoveStyle.secondaryText)
                    }
                    Spacer(minLength: 0)
                    Avatar(name: "助手", size: 40)
                }.padding(.vertical, 8)

                Button { store.selectedTab = 2 } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("接着说", systemImage: "bubble.left").font(.headline)
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.subheadline)
                        }.foregroundStyle(CoveStyle.teal)
                        if let last = store.messages.last {
                            Text(last.role == "user" ? "用户" : "助手").font(.caption).foregroundStyle(CoveStyle.secondaryText)
                            Text(last.status == "streaming" ? "正在回复…" : (last.text.isEmpty ? (last.attachments?.first?.filename ?? "一个附件") : last.text)).font(.body).lineLimit(3).foregroundStyle(CoveStyle.text)
                            Text(last.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(CoveStyle.secondaryText)
                        } else {
                            Text("还没有对话。想说的话，慢慢说。").font(.body).foregroundStyle(CoveStyle.secondaryText)
                        }
                    }.coveCard()
                }.buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 12) {
                    Text("我的近况").font(.headline)
                    Button { store.selectedTab = 1 } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "heart").foregroundStyle(CoveStyle.teal).frame(width: 24)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(store.pulse?.summary ?? "还没有读到心跳记录。").foregroundStyle(CoveStyle.text).lineLimit(4)
                                if let pulse = store.pulse { SnapshotTime(date: pulse.updatedAt) }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(CoveStyle.secondaryText)
                        }.coveCard()
                    }.buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("你的近况").font(.headline)
                    Button { store.selectedTab = 3 } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            if let health = store.health, !health.metrics.isEmpty {
                                ForEach(Array(health.metrics.prefix(3))) { metric in
                                    HStack {
                                        Text(metric.title).foregroundStyle(CoveStyle.text)
                                        Spacer()
                                        Text(metric.value, format: .number.precision(.fractionLength(0...1))).fontWeight(.medium)
                                        Text(metric.unit).font(.caption).foregroundStyle(CoveStyle.secondaryText)
                                    }
                                }
                                SnapshotTime(date: health.capturedAt)
                            } else {
                                Label("健康数据还没有同步", systemImage: "heart.text.square").foregroundStyle(CoveStyle.secondaryText)
                                Text("你可以在健康页选择分享。").font(.subheadline).foregroundStyle(CoveStyle.secondaryText)
                            }
                        }.coveCard()
                    }.buttonStyle(.plain)
                }
            }.padding(20).frame(maxWidth: 680)
        }
        .frame(maxWidth: .infinity).background(CoveStyle.background)
        .navigationTitle("家").navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
    }
}

private struct PulseView: View {
    @EnvironmentObject private var store: CoveStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Avatar(name: "助手", size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("助手").font(.headline)
                        Text("最近一次心跳记录").font(.subheadline).foregroundStyle(CoveStyle.secondaryText)
                    }
                }
                if let pulse = store.pulse {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(pulse.summary).font(.body).textSelection(.enabled)
                        SnapshotTime(date: pulse.updatedAt)
                    }.coveCard()
                    PulseGroup(title: "心里的倾向", metrics: pulse.desires)
                    PulseGroup(title: "身体与状态", metrics: pulse.physical)
                    if !pulse.senses.isEmpty {
                        DisclosureGroup("感官与细节") { PulseGroup(title: "", metrics: pulse.senses).padding(.top, 16) }
                            .font(.headline).coveCard()
                    }
                    Text("这里展示已有记录。刷新只读取数据；没有新记录，时间就保持原样。")
                        .font(.footnote).foregroundStyle(CoveStyle.secondaryText)
                } else {
                    EmptyCard(symbol: "heart", title: "心跳还没有到这里", detail: "连接私有服务后，就能看到 助手 最近写下的状态。")
                    Button("前往连接设置") { store.selectedTab = 4 }.buttonStyle(.bordered).frame(minHeight: 44)
                }
            }.padding(20).frame(maxWidth: 680)
        }
        .frame(maxWidth: .infinity).background(CoveStyle.background)
        .navigationTitle("心跳").navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }.accessibilityLabel("刷新心跳") } }
    }
}

private struct PulseGroup: View {
    let title: String
    let metrics: [PulseMetric]
    var body: some View {
        if !metrics.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                if !title.isEmpty { Text(title).font(.headline) }
                ForEach(metrics) { metric in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(metric.label).font(.subheadline.weight(.medium))
                            Spacer()
                            Text(min(max(metric.value, 0), 1), format: .percent.precision(.fractionLength(0))).font(.caption).foregroundStyle(CoveStyle.secondaryText)
                        }
                        ProgressView(value: min(max(metric.value, 0), 1)).tint(CoveStyle.teal)
                        if !metric.detail.isEmpty { Text(metric.detail).font(.subheadline).foregroundStyle(CoveStyle.secondaryText) }
                    }.accessibilityElement(children: .combine)
                }
            }.coveCard()
        }
    }
}


private struct ChatView: View {
    @EnvironmentObject private var store: CoveStore
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var composerFocused: Bool
    @State private var nearBottom = true
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var showingPhotos = false
    @State private var showingFiles = false
    @State private var showingStickers = false
    @State private var uploadCount = 0
    @State private var isUploading = false
    @State private var showingConversations = false
    @State private var showingTerminal = false
    @State private var attachmentError: String?
    @State private var keyboardShown = false
    @State private var historyInteracting = false
    @State private var keyboardTransitioning = false
    @State private var keyboardFollowBottom = false
    private var changeKey: String {
        guard let last = store.messages.last else { return "empty" }
        return "\(store.messages.count)-\(last.id)-\(last.text.count)-\(last.status)"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ChatHistoryRows(messages: store.messages, isConnected: store.isConnected, reactingMessageIDs: store.reactingMessageIDs,
                                onConnect: { store.selectedTab = 4 },
                                onReply: { store.replyToMessageID = $0 },
                                onRetry: { store.retry($0) },
                                onLike: { message, liked in Task { await store.setMessageLiked(message, liked: liked) } })
                    .equatable()
                    .padding(.horizontal, 10).padding(.bottom, 8)
                    .frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("chat.history")
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // Telegram updates history insets with the input-panel layout.
            // SwiftUI's size-change anchor performs the corresponding viewport
            // adjustment; an old-history reader keeps their existing offset.
            .defaultScrollAnchor((keyboardTransitioning ? keyboardFollowBottom : nearBottom) ? .bottom : nil, for: .sizeChanges)
            .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
            .onScrollPhaseChange { _, phase in
                // A wallpaper tap can enter tracking without scrolling. Only an
                // actual drag cancels the previously captured bottom alignment.
                historyInteracting = phase == .interacting || phase == .decelerating
                if historyInteracting { keyboardFollowBottom = false }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY < 90
            } action: { _, bottom in
                // A shrinking viewport is not a user scroll. Preserve the
                // pre-keyboard decision until its final layout notification.
                guard !keyboardTransitioning || historyInteracting else { return }
                if nearBottom != bottom { nearBottom = bottom }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.visibleRect.height.rounded()
            } action: { previousHeight, height in
                guard previousHeight > 0, height != previousHeight,
                      !historyInteracting,
                      keyboardTransitioning ? keyboardFollowBottom : nearBottom else { return }
                // Like Telegram's inset transaction, respond to actual history
                // layout, not a timer or a keyboard notification's guessed frame.
                alignLatest(proxy)
            }
            .onChange(of: composerFocused) { _, focused in
                if focused {
                    keyboardFollowBottom = nearBottom
                    keyboardTransitioning = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                guard composerFocused else { return }
                keyboardTransitioning = true
                if !keyboardShown { keyboardShown = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                guard composerFocused else { return }
                if !keyboardShown { keyboardShown = true }
                keyboardTransitioning = false
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardTransitioning = keyboardShown
                if keyboardShown { keyboardShown = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                keyboardTransitioning = false
                keyboardFollowBottom = false
            }
            .onChange(of: changeKey) {
                if nearBottom {
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            }
            .onChange(of: store.activeConversationID) {
                nearBottom = true
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer(proxy: proxy) }
        }
        // Paint behind both native navigation and the composer, using the same
        // wallpaper coordinates as the root's separate, non-overlapping tab row.
        .background { CoveChatWallpaperView().ignoresSafeArea() }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text("助手").font(.subheadline.weight(.semibold))
                    Text(store.isBusy ? "正在回复…" : store.connectionStatus)
                        .font(.caption2).foregroundStyle(CoveStyle.secondaryText).lineLimit(1)
                }.accessibilityElement(children: .combine)
            }
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .topBarTrailing) { terminalButton }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) { conversationButton }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .topBarTrailing) { terminalButton }
                ToolbarItem(placement: .topBarTrailing) { conversationButton }
            }
        }
        .sheet(isPresented: $showingConversations) { ConversationSheet() }
        .sheet(isPresented: $showingTerminal) { CoveTerminalView() }
        .sheet(isPresented: $showingStickers) { CoveStickerPicker(onSend: { nearBottom = true }) }
        .photosPicker(isPresented: $showingPhotos, selection: $pickedPhotos, maxSelectionCount: 10, matching: .images)
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                guard !urls.isEmpty else { return }
                Task { await sendSelectedFiles(urls) }
            case .failure(let error): attachmentError = "文件读取失败：\(error.localizedDescription)"
            }
        }
        .onChange(of: pickedPhotos) {
            guard !pickedPhotos.isEmpty else { return }
            let selection = pickedPhotos
            Task {
                isUploading = true
                uploadCount = selection.count
                defer { isUploading = false; pickedPhotos = [] }
                do {
                    var files: [CoveOutgoingFile] = []
                    for (index, photo) in selection.enumerated() {
                        guard let data = try await photo.loadTransferable(type: Data.self) else {
                            throw CoveAttachmentError.unreadable
                        }
                        guard data.count <= CoveAttachmentFiles.maximumBytes else { throw CoveAttachmentError.tooLarge }
                        let type = photo.supportedContentTypes.first(where: { $0.conforms(to: .image) }) ?? .jpeg
                        files.append(CoveOutgoingFile(data: data, filename: "照片-\(index + 1).\(type.preferredFilenameExtension ?? "jpg")", mime: type.preferredMIMEType ?? "image/jpeg"))
                    }
                    nearBottom = true
                    await store.sendAttachments(files: files)
                } catch { attachmentError = error.localizedDescription }
            }
        }
        .alert("附件未发送", isPresented: Binding(get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } })) {
            Button("好") { attachmentError = nil }
        } message: { Text(attachmentError ?? "") }
    }

    private func alignLatest(_ proxy: ScrollViewProxy) {
        nearBottom = true
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo("chat-bottom", anchor: .bottom)
        }
    }

    // Native bar buttons provide the hit area; 44pt label frames get additional
    // glass padding on iOS 26 and squeeze the centered principal title.
    private var terminalButton: some View {
        Button { composerFocused = false; showingTerminal = true } label: {
            Image(systemName: "terminal").font(.body)
        }.accessibilityLabel("终端").accessibilityIdentifier("chat.terminal")
    }

    private var conversationButton: some View {
        Button { showingConversations = true } label: {
            Image(systemName: "ellipsis").font(.body)
        }.accessibilityLabel("会话管理").accessibilityIdentifier("chat.conversations")
    }

    private func sendSelectedFiles(_ urls: [URL]) async {
        guard urls.count <= 10 else { attachmentError = "一次最多发送 10 个附件。"; return }
        isUploading = true
        uploadCount = urls.count
        defer { isUploading = false }
        do {
            let files = try await CoveAttachmentFiles.readSelected(urls)
            nearBottom = true
            await store.sendAttachments(files: files)
        } catch { attachmentError = error.localizedDescription }
    }

    @ViewBuilder private func composer(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            if let messageID = store.replyToMessageID, let message = store.messages.first(where: { $0.id == messageID }) {
                HStack(spacing: 10) {
                    Rectangle().fill(CoveStyle.teal).frame(width: 3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("回复 \(message.role == "user" ? "用户" : "助手")").font(.caption.weight(.semibold)).foregroundStyle(CoveStyle.teal)
                        Text(message.text.isEmpty ? (message.attachments?.first?.filename ?? "附件") : message.text).font(.caption).foregroundStyle(CoveStyle.secondaryText).lineLimit(1)
                    }
                    Spacer()
                    Button { store.replyToMessageID = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("取消引用")
                }.frame(height: 44).padding(.leading, 12)
            }
            if let error = store.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.top, 8)
            }
            if isUploading || store.attachmentUploadStatus != nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(store.attachmentUploadStatus ?? "正在读取并发送 \(uploadCount) 个附件…").font(.caption).foregroundStyle(CoveStyle.secondaryText)
                    Spacer()
                }.padding(.horizontal, 16).padding(.top, 8).accessibilityIdentifier("chat.attachmentProgress")
            }
            HStack(alignment: .bottom, spacing: 6) {
                Menu {
                    Button("照片", systemImage: "photo.on.rectangle") { composerFocused = false; showingPhotos = true }
                        .accessibilityIdentifier("chat.attachPhotos")
                    Button("文件", systemImage: "folder") { composerFocused = false; showingFiles = true }
                        .accessibilityIdentifier("chat.attachFiles")
                } label: {
                    if isUploading { ProgressView().frame(width: 44, height: 44) }
                    else { Image(systemName: "paperclip").font(.title3).frame(width: 44, height: 44) }
                }.disabled(isUploading || !store.canSendMessages || store.previewMode)
                    .accessibilityLabel("添加附件").accessibilityIdentifier("chat.attachments")
                TextField("说给 助手 听…", text: $store.draft, axis: .vertical)
                    .lineLimit(1...6).font(.body).focused($composerFocused)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(CoveStyle.incoming, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(CoveStyle.border.opacity(0.45), lineWidth: 0.5))
                    .accessibilityLabel("消息输入")
                    .accessibilityIdentifier("chat.input")
                Button { composerFocused = false; showingStickers = true } label: {
                    Image(systemName: "face.smiling").font(.title3).frame(width: 44, height: 44)
                }.accessibilityLabel("表情包").accessibilityIdentifier("chat.stickers")
                if store.isBusy {
                    Button { Task { await store.interrupt() } } label: { Image(systemName: "stop.fill").font(.body).frame(width: 44, height: 44) }.accessibilityLabel("停止回复")
                } else {
                    Button {
                        nearBottom = true
                        store.send()
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    } label: {
                        Image(systemName: "arrow.up").font(.body.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: 30, height: 30).background(CoveStyle.teal, in: Circle()).frame(width: 44, height: 44)
                    }.disabled(isUploading || store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.canSendMessages || store.previewMode).accessibilityLabel("发送消息").accessibilityIdentifier("chat.send")
                }
            }.padding(.horizontal, 4).padding(.vertical, 3)
        }
        .background(.ultraThinMaterial.opacity(0.55))
    }
}

private struct ChatHistoryRows: View, Equatable {
    let messages: [ChatMessage]
    let isConnected: Bool
    let reactingMessageIDs: Set<String>
    var onConnect: () -> Void
    var onReply: (String) -> Void
    var onRetry: (ChatMessage) -> Void
    var onLike: (ChatMessage, Bool) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.messages == rhs.messages && lhs.isConnected == rhs.isConnected
            && lhs.reactingMessageIDs == rhs.reactingMessageIDs
    }

    var body: some View {
        let byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        LazyVStack(alignment: .leading, spacing: 4) {
            if messages.isEmpty {
                VStack(spacing: 10) {
                    Avatar(name: "助手", size: 44)
                    Text("想说什么，就从这里开始。").font(.subheadline.weight(.medium))
                    Text(isConnected ? "消息会保存在你的私有服务。" : "先连接服务，再继续我们的对话。")
                        .font(.caption).foregroundStyle(CoveStyle.secondaryText)
                    if !isConnected { Button("连接 助手", action: onConnect).buttonStyle(.bordered).frame(minHeight: 44) }
                }.frame(maxWidth: .infinity).padding(.vertical, 48)
            }
            ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                let previous = index > 0 ? messages[index - 1] : nil
                let next = index + 1 < messages.count ? messages[index + 1] : nil
                let firstInGroup = previous.map { !CoveChatPresentation.joinsGroup($0, message) } ?? true
                let lastInGroup = next.map { !CoveChatPresentation.joinsGroup(message, $0) } ?? true
                if previous == nil || !Calendar.current.isDate(previous!.createdAt, inSameDayAs: message.createdAt) {
                    Text(message.createdAt, format: .dateTime.month().day().weekday())
                        .font(.caption2.weight(.medium)).foregroundStyle(CoveStyle.dateText)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(CoveStyle.dateBackground, in: Capsule())
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                ChatBubble(message: message,
                           quote: CoveChatPresentation.displayedQuote(message, messagesByID: byID),
                           showName: firstInGroup, isLastInGroup: lastInGroup,
                           isReacting: reactingMessageIDs.contains(message.id),
                           onReply: onReply, onRetry: onRetry, onLike: onLike)
                    .id(message.id)
            }
            Color.clear.frame(height: 1).id("chat-bottom")
        }
    }
}

enum CoveChatPresentation {
    static func joinsGroup(_ first: ChatMessage, _ second: ChatMessage) -> Bool {
        first.role == second.role && second.createdAt.timeIntervalSince(first.createdAt) >= 0
            && second.createdAt.timeIntervalSince(first.createdAt) <= 120
            && Calendar.current.isDate(first.createdAt, inSameDayAs: second.createdAt)
    }

    static func displayedQuote(_ message: ChatMessage, messagesByID: [String: ChatMessage]) -> ChatMessage? {
        // The service links an assistant response to its originating message.
        // Explicit user quote replies are the only quotes shown in the bubble.
        guard message.role == "user", let replyID = message.replyTo else { return nil }
        return messagesByID[replyID]
    }
}

private struct CoveBubbleWidth: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = min(proposal.width ?? 420, 420)
        return child.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                             proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

private struct CoveBubbleBackground: View {
    let outgoing: Bool
    let firstInGroup: Bool
    let lastInGroup: Bool
    let fill: Color

    var body: some View {
        fill.mask {
            Canvas { context, size in
                context.clip(to: Path(CGRect(origin: .zero, size: size)))
                // Geometry follows TelegramPresentationData's
                // ChatMessageBubbleImages.messageBubbleImage: a 33pt source
                // corner, a 6pt extension, and the lower ellipse minus the
                // upper ellipse. Only the group-ending message has a tail.
                // Neighbor corners use the theme's 16pt / 8pt radii.
                if !outgoing {
                    context.translateBy(x: size.width, y: 0)
                    context.scaleBy(x: -1, y: 1)
                }
                let radius = min(CGFloat(16), size.height / 2)
                let joined = min(CGFloat(8), size.height / 2)
                let tail: CGFloat = lastInGroup ? 6 : 0
                let bodyRect = CGRect(x: 0, y: 0, width: max(0, size.width - tail), height: size.height)
                let body = UnevenRoundedRectangle(
                    topLeadingRadius: radius,
                    bottomLeadingRadius: radius,
                    bottomTrailingRadius: lastInGroup ? radius : joined,
                    topTrailingRadius: firstInGroup ? radius : joined,
                    style: .circular
                ).path(in: bodyRect)
                context.drawLayer { layer in
                    layer.fill(body, with: .color(.white))
                    guard lastInGroup else { return }
                    let origin = CGPoint(x: bodyRect.maxX - 33, y: size.height - 33)
                    let lower = CGRect(x: origin.x + 24, y: origin.y + 16, width: 27, height: 17)
                    var tailPath = Path()
                    tailPath.move(to: CGPoint(x: lower.minX, y: lower.midY))
                    tailPath.addQuadCurve(to: CGPoint(x: lower.midX, y: lower.maxY),
                                          control: CGPoint(x: lower.minX, y: lower.maxY))
                    tailPath.addQuadCurve(to: CGPoint(x: lower.maxX, y: lower.midY),
                                          control: CGPoint(x: lower.maxX, y: lower.maxY))
                    tailPath.closeSubpath()
                    layer.fill(tailPath, with: .color(.white))
                    // Telegram fills this bridge before subtracting the upper
                    // ellipse; without it the rounded body exposes a notch at
                    // the tail's root instead of one continuous contour.
                    layer.fill(Path(CGRect(x: origin.x + 16.5, y: origin.y + 16,
                                           width: 16.5, height: 9)), with: .color(.white))
                    layer.blendMode = .destinationOut
                    layer.fill(Path(ellipseIn: CGRect(x: origin.x + 33, y: origin.y + 14,
                                                     width: 23, height: 21)), with: .color(.white))
                }
            }
        }.allowsHitTesting(false)
    }
}

private struct ChatBubble: View {
    @State private var savingSticker: ChatAttachment?
    @Environment(\.colorScheme) private var colorScheme
    let message: ChatMessage
    let quote: ChatMessage?
    let showName: Bool
    let isLastInGroup: Bool
    let isReacting: Bool
    var onReply: (String) -> Void
    var onRetry: (ChatMessage) -> Void
    var onLike: (ChatMessage, Bool) -> Void
    private var own: Bool { message.role == "user" }
    private var stickerOnly: Bool { message.stickerID != nil && message.text.isEmpty && quote == nil }
    private var saveableImages: [ChatAttachment] {
        (message.attachments ?? []).filter { ["image/png", "image/jpeg", "image/gif", "image/webp"].contains($0.mime.lowercased()) }
    }
    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if own { Spacer(minLength: 44) }
            VStack(alignment: own ? .trailing : .leading, spacing: 3) {
                CoveBubbleWidth {
                    VStack(alignment: .leading, spacing: 5) {
                        if let quote {
                            HStack(spacing: 7) {
                                RoundedRectangle(cornerRadius: 2).fill(CoveStyle.teal).frame(width: 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(quote.role == "user" ? "用户" : "助手").font(.caption2.weight(.semibold)).foregroundStyle(CoveStyle.teal)
                                    Text(quote.text.isEmpty ? (quote.attachments?.first?.filename ?? "附件") : quote.text)
                                        .font(.caption).foregroundStyle(CoveStyle.secondaryText).lineLimit(2)
                                }
                            }.padding(6).background(CoveStyle.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                                .accessibilityIdentifier("chat.quote.\(message.id)")
                        }
                        if let attachments = message.attachments, !attachments.isEmpty {
                            ForEach(attachments) { attachment in
                                if message.stickerID != nil { CoveStickerView(attachment: attachment) }
                                else { CoveAttachmentView(attachment: attachment) }
                            }
                        } else if let path = message.attachmentURL {
                            CoveAttachmentView(attachment: ChatAttachment(id: message.id + "-legacy", filename: "图片.jpg", mime: "image/jpeg", size: 0, url: path))
                        }
                        if !message.text.isEmpty {
                            MarkdownMessageView(text: message.text, id: message.id)
                                .foregroundStyle(CoveStyle.text).tint(CoveStyle.teal)
                                .accessibilityIdentifier("chat.message.\(message.id)")
                        } else if message.status == "streaming" {
                            Text("正在回复…").font(.subheadline).foregroundStyle(CoveStyle.secondaryText)
                        }
                        if message.status == "failed" && !own {
                            Text(message.error ?? "这次回复未完成。")
                                .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                                .accessibilityIdentifier("chat.error.\(message.id)")
                        }
                    }
                    .padding(.leading, isLastInGroup && !own ? 17 : 11)
                    .padding(.trailing, isLastInGroup && own ? 17 : 11)
                    .padding(.vertical, 7)
                    .background {
                        if !stickerOnly {
                            CoveBubbleBackground(outgoing: own, firstInGroup: showName, lastInGroup: isLastInGroup,
                                                 fill: own ? CoveStyle.outgoing(colorScheme == .dark) : CoveStyle.incoming)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("chat.bubble.\(message.id)")
                    .contentShape(Rectangle())
                    .contextMenu {
                        if !message.text.isEmpty {
                            Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
                        }
                        ForEach(saveableImages) { attachment in
                            Button(saveableImages.count == 1 ? "收藏为表情包" : "收藏：\(attachment.filename)", systemImage: "face.smiling") {
                                savingSticker = attachment
                            }
                        }
                        Button("引用回复", systemImage: "arrowshape.turn.up.left") { onReply(message.id) }
                        Button(message.isLiked == true ? "取消点赞" : "点赞",
                               systemImage: message.isLiked == true ? "hand.thumbsup.fill" : "hand.thumbsup") {
                            onLike(message, message.isLiked != true)
                        }.disabled(isReacting).accessibilityIdentifier("chat.like.\(message.id)")
                        if own && message.status == "failed" { Button("重试", systemImage: "arrow.clockwise") { onRetry(message) } }
                    }
                }
                HStack(spacing: 3) {
                    Text(message.createdAt, format: .dateTime.hour().minute())
                        .accessibilityIdentifier("chat.timestamp.\(message.id)")
                    if own && message.status != "failed" { CoveDeliveryStatusView(message: message) }
                    if message.status == "interrupted" { Text("已停止") }
                    if own && message.status == "failed" {
                        Button { onRetry(message) } label: {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).frame(width: 44, height: 44)
                        }.accessibilityLabel("消息发送失败，点击重试")
                    }
                }.font(.caption2).foregroundStyle(CoveStyle.dateText)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                if message.isLiked == true {
                    Button { onLike(message, false) } label: {
                        HStack(spacing: 4) {
                            Text("👍").font(.subheadline)
                            Text("1").font(.caption.weight(.semibold))
                        }.foregroundStyle(CoveStyle.accentText)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(CoveStyle.card, in: Capsule())
                            .overlay { Capsule().stroke(CoveStyle.teal.opacity(0.35), lineWidth: 1) }
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(isReacting)
                        .accessibilityLabel("已点赞，1个点赞；点击取消")
                        .accessibilityIdentifier("chat.reaction.\(message.id)")
                }
            }
            if !own { Spacer(minLength: 44) }
        }.padding(.top, showName ? 5 : 0)
        .sheet(item: $savingSticker) { attachment in CoveSaveStickerSheet(attachment: attachment) }
    }
}

private struct CoveDeliveryStatusView: View {
    let message: ChatMessage
    @ScaledMetric(relativeTo: .caption2) private var markHeight: CGFloat = 9

    private var accepted: Bool { message.status == "sent" || message.status == "complete" }
    private var read: Bool { accepted && message.readAt != nil }
    private var statusLabel: String { accepted ? (read ? "已读" : "已发送") : "正在发送" }

    var body: some View {
        Group {
            if accepted {
                // Telegram generateCheckImage is 11 × 9pt with a 0.99pt
                // stroke; DateAndStatusNode places the partial check 6pt
                // after the full check. Keep its actual painted width here.
                Canvas { context, size in
                    let scale = size.height / 9
                    context.scaleBy(x: scale, y: scale)
                    var marks = Path()
                    marks.move(to: CGPoint(x: 1, y: 5))
                    marks.addLine(to: CGPoint(x: 3.95157047, y: 7.95157047))
                    marks.addCurve(to: CGPoint(x: 4.04490857, y: 7.95157047),
                                   control1: CGPoint(x: 3.97734507, y: 7.97734507),
                                   control2: CGPoint(x: 4.01913396, y: 7.97734507))
                    marks.addLine(to: CGPoint(x: 10.5, y: 1))
                    if read {
                        marks.move(to: CGPoint(x: 7.5, y: 8))
                        marks.addLine(to: CGPoint(x: 14, y: 1))
                    }
                    context.stroke(marks, with: .color(read ? CoveStyle.accentText : CoveStyle.dateText),
                                   style: StrokeStyle(lineWidth: 0.99, lineCap: .round, lineJoin: .round))
                }.frame(width: markHeight * (read ? 15.0 / 9 : 11.0 / 9), height: markHeight)
            } else {
                Image(systemName: "clock").font(.caption2)
            }
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(statusLabel)
            .accessibilityIdentifier("chat.delivery.\(message.id)")
    }
}

private struct ConversationSheet: View {
    @EnvironmentObject private var store: CoveStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Button { Task { await store.newConversation(); dismiss() } } label: { Label("新对话", systemImage: "square.and.pencil") }.disabled(!store.isConnected || store.previewMode)
                ForEach(store.conversations) { conversation in
                    Button {
                        Task { await store.selectConversation(conversation.id); dismiss() }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(conversation.title.isEmpty ? "与 助手 的对话" : conversation.title).foregroundStyle(CoveStyle.text)
                                Text(conversation.createdAt, format: .dateTime.month().day()).font(.caption).foregroundStyle(CoveStyle.secondaryText)
                            }
                            Spacer()
                            if conversation.id == store.activeConversationID { Image(systemName: "checkmark").foregroundStyle(CoveStyle.teal) }
                        }.padding(.vertical, 4)
                    }
                }
            }.navigationTitle("对话").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}

private struct HealthView: View {
    @EnvironmentObject private var store: CoveStore
    @State private var confirmDelete = false
    private var dailyHistory: [HealthSnapshot] {
        store.healthHistory.sorted { $0.capturedAt > $1.capturedAt }.reduce(into: []) { result, snapshot in
            if result.count < 7 && !result.contains(where: { Calendar.current.isDate($0.capturedAt, inSameDayAs: snapshot.capturedAt) }) {
                result.append(snapshot)
            }
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("Apple 健康", systemImage: "heart.fill").font(.headline)
                        Spacer()
                        if store.isSyncingHealth { ProgressView() }
                    }
                    Toggle("将健康近况分享给 助手", isOn: $store.healthSharingEnabled)
                    Text("读取睡眠、步数、心率、静息心率、HRV、活动能量与运动时长，上传到你的私有服务。")
                        .font(.footnote).foregroundStyle(CoveStyle.secondaryText)
                    Button { Task { await store.syncHealth() } } label: { Label(store.isSyncingHealth ? "正在同步…" : "立即读取并同步", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(.borderedProminent).frame(minHeight: 44)
                        .disabled(store.isSyncingHealth || !store.healthSharingEnabled || store.previewMode)
                    if !store.healthSyncStatus.isEmpty { Text(store.healthSyncStatus).font(.footnote).foregroundStyle(CoveStyle.secondaryText) }
                }.coveCard()

                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("上次同步"); Spacer(); dateOrEmpty(store.healthSyncedAt, empty: "尚未同步") }
                    HStack { Text("助手 已读取"); Spacer(); dateOrEmpty(store.healthReadAt, empty: "尚未读取") }
                }.font(.caption).foregroundStyle(CoveStyle.secondaryText).padding(.horizontal, 4)

                if let health = store.health, !health.metrics.isEmpty {
                    ForEach(health.metrics) { metric in
                        VStack(alignment: .leading, spacing: 12) {
                            Label(metric.title, systemImage: healthSymbol(metric.id)).font(.subheadline.weight(.medium)).foregroundStyle(CoveStyle.teal)
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(metric.value, format: .number.precision(.fractionLength(0...1))).font(.system(.title, design: .rounded).weight(.semibold))
                                Text(metric.unit).font(.subheadline).foregroundStyle(CoveStyle.secondaryText)
                            }
                            if let detail = metric.detail, !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(CoveStyle.secondaryText) }
                            Text("采样 \(metric.sampledAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(CoveStyle.secondaryText)
                        }.frame(maxWidth: .infinity, alignment: .leading).coveCard()
                    }
                } else { EmptyCard(symbol: "heart.text.square", title: "暂无可读取数据", detail: "首次同步会打开系统健康权限。未读取到的项目不会记作零。") }
                if !dailyHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("最近的每日记录").font(.headline)
                        Text("保留已有的最近 \(dailyHistory.count) 天摘要；同一天显示最新一次记录。")
                            .font(.caption).foregroundStyle(CoveStyle.secondaryText)
                        ForEach(dailyHistory, id: \.capturedAt) { snapshot in
                            DisclosureGroup(snapshot.capturedAt.formatted(date: .abbreviated, time: .omitted)) {
                                VStack(alignment: .leading, spacing: 14) {
                                    ForEach(snapshot.metrics) { metric in
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                Text(metric.title).font(.subheadline)
                                                Spacer()
                                                Text("\(metric.value.formatted(.number.precision(.fractionLength(0...1)))) \(metric.unit)").font(.subheadline.weight(.medium))
                                            }
                                            Text("采样 \(metric.sampledAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(CoveStyle.secondaryText)
                                        }
                                    }
                                }.padding(.top, 12)
                            }.font(.subheadline)
                        }
                    }.coveCard()
                }
                Text("同步与读取分开记录。这里不会修改 Apple 健康里的原始记录。")
                    .font(.footnote).foregroundStyle(CoveStyle.secondaryText)
                Button("删除已分享的健康数据", role: .destructive) { confirmDelete = true }.frame(minHeight: 44).disabled(store.previewMode || !store.isConnected || store.isSyncingHealth)
            }.padding(20).frame(maxWidth: 680)
        }.frame(maxWidth: .infinity).background(CoveStyle.background)
            .navigationTitle("健康").navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh() }
            .confirmationDialog("删除私有服务中已分享的健康数据？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除已分享数据", role: .destructive) { Task { await store.deleteSharedHealth() } }
            } message: { Text("Apple 健康中的原始记录会保留。") }
    }
    @ViewBuilder private func dateOrEmpty(_ date: Date?, empty: String) -> some View {
        if let date { Text(date, format: .dateTime.month().day().hour().minute()) }
        else { Text(empty) }
    }
    private func healthSymbol(_ id: String) -> String {
        switch id {
        case "sleep": "bed.double"
        case "steps": "figure.walk"
        case "activeEnergy": "flame"
        case "exercise": "figure.run"
        case "hrv": "waveform.path.ecg"
        default: "heart"
        }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var store: CoveStore
    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Avatar(name: "助手")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cove").font(.headline)
                        Text("用户与 助手 的日常").font(.subheadline).foregroundStyle(CoveStyle.secondaryText)
                    }
                }.padding(.vertical, 4)
            }
            Section("外观") {
                NavigationLink("聊天壁纸") { CoveWallpaperSettingsView() }
                    .accessibilityIdentifier("settings.wallpaper")
            }
            Section("连接") {
                TextField("服务地址 https://…", text: $store.serverURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("助手 服务地址").accessibilityIdentifier("settings.url")
                SecureField("配对密钥", text: $store.accessToken).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("配对密钥").accessibilityIdentifier("settings.token")
                HStack { Text("状态"); Spacer(); Text(store.connectionStatus).foregroundStyle(CoveStyle.secondaryText).multilineTextAlignment(.trailing) }
                Button { Task { await store.connect() } } label: { Label("保存并连接", systemImage: "link") }.disabled(store.previewMode).accessibilityIdentifier("settings.connect")
                if let error = store.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            Section {
                if let usage = store.usage {
                    HStack { Text("订阅"); Spacer(); Text(CoveUsagePresentation.planName(usage.plan)).foregroundStyle(CoveStyle.secondaryText) }
                    ForEach(CoveUsagePresentation.accountWindows(usage.windows)) { window in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text(window.title); Spacer(); Text("已用 \(Int(min(max(window.usedPercent, 0), 100)))%").font(.caption).foregroundStyle(CoveStyle.secondaryText) }
                            ProgressView(value: min(max(window.usedPercent, 0), 100), total: 100)
                            if let reset = window.resetsAt { Text("重置 \(reset.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(CoveStyle.secondaryText) }
                        }.padding(.vertical, 4)
                    }
                    if CoveUsagePresentation.accountWindows(usage.windows).isEmpty && usage.error == nil {
                        Text("账号暂未返回 5 小时或周额度窗口。")
                            .font(.footnote).foregroundStyle(CoveStyle.secondaryText)
                    }
                    SnapshotTime(date: usage.updatedAt)
                    if let error = usage.error { Text(error).font(.footnote).foregroundStyle(CoveStyle.secondaryText) }
                } else {
                    Text("订阅与额度未知").foregroundStyle(CoveStyle.secondaryText)
                    Text("连接后读取账号的实际额度窗口。暂时无法获取时会保留更新时间。").font(.footnote).foregroundStyle(CoveStyle.secondaryText)
                }
                Button { Task { await store.refresh() } } label: { Label("刷新订阅信息", systemImage: "arrow.clockwise") }.disabled(!store.isConnected || store.previewMode)
            } header: { Text("订阅用量") }
            Section("偏好") {
                Picker("外观", selection: $store.appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                Toggle("新回复通知", isOn: $store.notificationsEnabled)
            }
            Section {
                Text("对话经私有服务保存。健康数据只在你开启分享后上传；同步成功与 助手 读取分别记录。")
                    .font(.footnote).foregroundStyle(CoveStyle.secondaryText)
                LabeledContent("版本", value: "0.1.0 · 首版")
                if !store.previewMode { Button("查看示例预览") { store.enablePreview() } }
            } header: { Text("数据与关于") } footer: { Text("示例预览使用明确标注的样例，不会发送消息或上传健康数据。") }
        }
        .scrollContentBackground(.hidden)
        .background(CoveStyle.background)
        .listRowBackground(CoveStyle.card)
        .toolbarBackground(CoveStyle.card, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
    }
}

private struct SnapshotTime: View {
    let date: Date
    var body: some View {
        Text("记录于 \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(CoveStyle.secondaryText)
    }
}

private struct EmptyCard: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(CoveStyle.teal).accessibilityHidden(true)
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(CoveStyle.secondaryText)
        }.frame(maxWidth: .infinity, alignment: .leading).coveCard()
    }
}

private extension View {
    func coveCard() -> some View {
        padding(16).background(CoveStyle.card, in: RoundedRectangle(cornerRadius: 14))
    }
}
