import Foundation
import Combine
import CryptoKit
import Security
import UIKit
import UserNotifications

@MainActor
final class CoveStore: ObservableObject {
    @Published var selectedTab = 2
    @Published var messages: [ChatMessage] = []
    @Published var conversations: [Conversation] = []
    @Published var activeConversationID = ""
    @Published var draft = ""
    @Published var replyToMessageID: String?
    @Published var serverURL = ""
    @Published var accessToken = ""
    @Published var connectionStatus = "还未连接"
    @Published var isConnected = false
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var pulse: PulseSnapshot?
    @Published var usage: UsageSnapshot?
    @Published var health: HealthSnapshot?
    @Published var healthHistory: [HealthSnapshot] = []
    @Published var healthSyncedAt: Date?
    @Published var healthReadAt: Date?
    @Published var isSyncingHealth = false
    @Published var healthSharingEnabled = false {
        didSet {
            guard !previewMode else { return }
            UserDefaults.standard.set(healthSharingEnabled, forKey: "cove.healthSharing")
            if !healthSharingEnabled { healthReader.stopObserving() }
        }
    }
    @Published var healthSyncStatus = "还没有同步"
    @Published var previewMode = false
    @Published var appearance = "system"
    @Published var notificationsEnabled = false
    @Published var attachmentUploadStatus: String?
    @Published private(set) var reactingMessageIDs: Set<String> = []
    @Published private(set) var stickers: [CoveSticker] = []
    @Published private(set) var isLoadingStickers = false
    @Published var stickerError: String?
    private var previewFiles: [String: Data] = [:]

    private struct Cache: Codable {
        var conversations: [Conversation] = []
        var messages: [ChatMessage] = []
        var activeConversationID = ""
        var cursors: [String: Int] = [:]
        var drafts: [String: String] = [:]
        var attachments: [String: String] = [:]
        // Optional for compatibility with caches written before the sticker library.
        var stickers: [CoveSticker]? = nil
        var stickerUploads: [String: ChatAttachment]? = nil
    }
    private var cache = Cache()
    private var pollTask: Task<Void, Never>?
    private var savingDraft: AnyCancellable?
    private let healthReader = HealthSync()
    private var sendingIDs: Set<String> = []
    private var flushing = false
    private var refreshing = false
    private var connecting = false
    private var resettingTerminal = false
    private var pendingTerminalReset: (source: String, target: String, generation: UUID)?
    private var generation = UUID()
    private var lastAutoHealthSync: Date?
    private var connectedURL: URL?
    private var connectedToken = ""
    private var cacheEndpoint = ""
    private var deviceToken: String?
    private let session: URLSession
    private let credentials: any CoveCredentialStore

    init(session overrideSession: URLSession? = nil, credentials: any CoveCredentialStore = CoveKeychainCredentials()) {
        self.credentials = credentials
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 45
        config.waitsForConnectivity = false
        session = overrideSession ?? URLSession(configuration: config, delegate: CoveRedirectPolicy(), delegateQueue: nil)
        serverURL = UserDefaults.standard.string(forKey: "cove.serverURL") ?? ""
        cacheEndpoint = serverURL
        accessToken = credentials.read(account: serverURL) ?? ""
        appearance = UserDefaults.standard.string(forKey: "cove.appearance") ?? "system"
        notificationsEnabled = UserDefaults.standard.bool(forKey: "cove.notifications")
        deviceToken = credentials.read(account: "device.apns")
        healthSharingEnabled = UserDefaults.standard.bool(forKey: "cove.healthSharing")
        loadCache()
        savingDraft = $draft.dropFirst().debounce(for: .milliseconds(250), scheduler: RunLoop.main).sink { [weak self] value in
            guard let self, !self.previewMode else { return }
            self.cache.drafts[self.activeConversationID] = value
            self.persist()
        }
        if ProcessInfo.processInfo.arguments.contains("--preview") { enablePreview() }
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--tab"), ProcessInfo.processInfo.arguments.count > index + 1,
           let tab = Int(ProcessInfo.processInfo.arguments[index + 1]), (0...4).contains(tab) { selectedTab = tab }
    }

    var canSendMessages: Bool { !previewMode && connectedURL != nil }

    func saveSettings() {
        guard !previewMode else { return }
        UserDefaults.standard.set(appearance, forKey: "cove.appearance")
        UserDefaults.standard.set(notificationsEnabled, forKey: "cove.notifications")
        // Endpoint and its secret are committed together by connect(), not per keystroke.
        if notificationsEnabled {
            Task {
                let allowed = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
                if allowed { UIApplication.shared.registerForRemoteNotifications() }
            }
        } else {
            UIApplication.shared.unregisterForRemoteNotifications()
            if let deviceToken, connectedURL != nil {
                Task {
                    do { let _: OKEnvelope = try await request("v1/devices", method: "DELETE", body: ["token": deviceToken]) }
                    catch { errorMessage = "服务器通知停用未同步，重新连接后会重试。" }
                }
            }
        }
    }

    func connect() async {
        guard !previewMode, !connecting else { return }
        guard !flushing else { errorMessage = "当前消息发送结束后再切换连接。"; return }
        connecting = true
        defer { connecting = false }
        do {
            let url = try validatedURL(serverURL)
            let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw CoveError.message("填入你的 Cove 连接密钥后再连接。") }
            pollTask?.cancel()
            generation = UUID()
            isConnected = false
            connectionStatus = "正在连接…"
            let stamp = generation
            if cacheEndpoint != url.absoluteString {
                persist()
                serverURL = url.absoluteString
                cacheEndpoint = url.absoluteString
                cache = Cache()
                loadCache()
                pulse = nil; usage = nil; health = nil; healthHistory = []
                healthSyncedAt = nil; healthReadAt = nil
            }
            connectedURL = url
            connectedToken = token
            let result: ConversationList = try await request("v1/conversations")
            guard stamp == generation else { return }
            try credentials.write(token, account: url.absoluteString)
            accessToken = token
            serverURL = url.absoluteString
            UserDefaults.standard.set(serverURL, forKey: "cove.serverURL")
            mergeConversations(result.conversations)
            if activeConversationID.isEmpty { activeConversationID = result.activeConversationID ?? conversations.first?.id ?? "" }
            if activeConversationID.isEmpty {
                createLocalConversation()
                let _: ConversationEnvelope = try await request("v1/conversations", method: "POST", body: ["id": activeConversationID])
            }
            cache.activeConversationID = activeConversationID
            showCurrentMessages()
            isConnected = true
            connectionStatus = "已连接"
            errorMessage = nil
            persist()
            await refresh()
            await flushOutbox()
            if let deviceToken { await registerDevice(deviceToken) }
            startPolling()
            saveSettings()
        } catch {
            isConnected = false
            connectionStatus = "连接未成功"
            errorMessage = readable(error)
        }
    }

    func resume() async {
        guard !previewMode, !connecting else { return }
        if connectedURL == nil && !serverURL.isEmpty { await connect() }
        else if connectedURL != nil { await refresh(); await flushOutbox(); startPolling() }
        if healthSharingEnabled && UserDefaults.standard.bool(forKey: "cove.healthRequested") {
            observeHealth()
            await autoSyncHealth()
        }
    }

    func suspend() {
        pollTask?.cancel()
        pollTask = nil
        if !previewMode { cache.drafts[activeConversationID] = draft; persist() }
    }

    func refresh() async {
        guard !previewMode, connectedURL != nil, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let currentGeneration = generation
        do {
            try await pollMessages()
            guard currentGeneration == generation else { return }
            isConnected = true
            connectionStatus = isBusy ? "正在回复…" : "已连接"
        } catch {
            guard currentGeneration == generation else { return }
            isConnected = false
            connectionStatus = "连接中断，正在重试"
        }
        // Independent panels must not prevent chat from recovering.
        if let snapshot: PulseSnapshot = try? await request("v1/pulse"), generation == currentGeneration { pulse = snapshot }
        if let snapshot: UsageSnapshot = try? await request("v1/usage"), generation == currentGeneration { usage = snapshot }
        if let snapshot: HealthEnvelope = try? await request("v1/health"), generation == currentGeneration {
            if let incoming = snapshot.snapshot { health = incoming }
            healthSyncedAt = snapshot.syncedAt
            healthReadAt = snapshot.readAt
        }
        if let history: HealthHistoryEnvelope = try? await request("v1/health/history", query: [URLQueryItem(name: "days", value: "7")]), generation == currentGeneration { healthHistory = history.snapshots }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !previewMode else { errorMessage = "这里是界面预览。退出预览并连接后，就能和 助手 说话。"; return }
        if activeConversationID.isEmpty { createLocalConversation() }
        let message = ChatMessage(id: UUID().uuidString, conversationID: activeConversationID, role: "user", text: text, createdAt: Date(), status: "pending", replyTo: replyToMessageID)
        cache.messages.append(message)
        cache.drafts[activeConversationID] = ""
        draft = ""
        replyToMessageID = nil
        if let i = cache.conversations.firstIndex(where: { $0.id == activeConversationID }), cache.conversations[i].title == "我们的对话" {
            cache.conversations[i].title = String(text.prefix(18))
            conversations = cache.conversations
        }
        showCurrentMessages()
        persist()
        Task { await flushOutbox() }
    }

    func retry(_ message: ChatMessage) {
        guard !previewMode, message.role == "user", ["failed", "pending"].contains(message.status) else { return }
        updateStatus(message.id, "pending")
        Task { await flushOutbox() }
    }

    private func deliver(_ message: ChatMessage) async {
        guard !sendingIDs.contains(message.id), connectedURL != nil else { return }
        sendingIDs.insert(message.id)
        defer { sendingIDs.remove(message.id) }
        let currentGeneration = generation
        updateStatus(message.id, "sending")
        do {
            let _: ConversationEnvelope = try await request("v1/conversations", method: "POST", body: ["id": message.conversationID])
            var attached = message.attachments ?? []
            for index in attached.indices where attached[index].url.hasPrefix("/local-attachments/") {
                attachmentUploadStatus = "正在上传 \(index + 1)/\(attached.count)：\(attached[index].filename)"
                defer { attachmentUploadStatus = nil }
                let localID = attached[index].id
                let data = try await attachmentData(attached[index].url)
                let uploaded: ChatAttachment = try await request("v1/attachments", method: "POST", body: ["filename": attached[index].filename, "mime": attached[index].mime, "dataBase64": data.base64EncodedString()])
                guard currentGeneration == generation else { return }
                attached[index] = uploaded
                guard let position = cache.messages.firstIndex(where: { $0.id == message.id }) else { return }
                cache.messages[position].attachments = attached
                // Persist every acknowledged file ID before sending the message. A retry
                // must reuse this same ordered set even if the message ACK is lost.
                try persistOrThrow()
                if let uploadedURL = try? localAttachmentURL(uploaded.id) {
                    try? data.write(to: uploadedURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    if FileManager.default.fileExists(atPath: uploadedURL.path), let original = try? localAttachmentURL(localID) { try? FileManager.default.removeItem(at: original) }
                }
                showCurrentMessages()
            }
            var body: [String: Any] = ["id": message.id, "conversationID": message.conversationID, "text": message.text]
            if let reply = message.replyTo { body["replyTo"] = reply }
            if let stickerID = message.stickerID { body["stickerID"] = stickerID }
            if !attached.isEmpty { body["attachmentIDs"] = attached.map(\.id) }
            else if let attachment = cache.attachments[message.id] { body["attachmentID"] = attachment }
            let response: MessageEnvelope = try await request("v1/messages", method: "POST", body: body)
            guard currentGeneration == generation else { return }
            mergeMessages([response.message])
            isConnected = true
            errorMessage = nil
            try? await pollMessages()
        } catch {
            guard currentGeneration == generation else { return }
            let retryable = error is URLError
            updateStatus(message.id, retryable ? "pending" : "failed", error: readable(error))
            errorMessage = readable(error)
        }
    }

    private func flushOutbox() async {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        let stamp = generation
        let pending = cache.messages.filter { $0.role == "user" && ["pending", "sending"].contains($0.status) }.sorted { $0.createdAt < $1.createdAt }
        for message in pending {
            guard stamp == generation else { break }
            await deliver(message)
            // Preserve send order when the oldest message cannot reach the server.
            if cache.messages.first(where: { $0.id == message.id })?.status == "pending" { break }
        }
    }

    func sendAttachment(data: Data, filename: String, mime: String) async {
        await sendAttachments(files: [.init(data: data, filename: filename, mime: mime)])
    }

    func sendAttachments(files: [CoveOutgoingFile]) async {
        guard !previewMode else { errorMessage = "退出界面预览后才能发送附件。"; return }
        guard canSendMessages else { errorMessage = "先在设置里连接 Cove。"; return }
        guard !files.isEmpty, files.count <= 10 else { errorMessage = "一次最多发送 10 个文件。"; return }
        guard files.allSatisfy({ !$0.data.isEmpty && $0.data.count <= 20 * 1024 * 1024 }) else { errorMessage = "文件不能为空，每个文件最多 20 MB。"; return }
        guard files.allSatisfy({ !$0.filename.isEmpty && $0.filename.count <= 255 && !$0.filename.contains("/") && !$0.filename.contains("\\") && !$0.filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else { errorMessage = "文件名无效。"; return }
        var staged: [URL] = []
        var queuedID: String?
        do {
            if activeConversationID.isEmpty { createLocalConversation() }
            let context = activeConversationID
            let attachedDraft = draft
            let quote = replyToMessageID
            var attached: [ChatAttachment] = []
            for file in files {
                let id = UUID().uuidString
                let url = try localAttachmentURL(id)
                try file.data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                staged.append(url)
                attached.append(.init(id: id, filename: file.filename, mime: file.mime, size: file.data.count, url: "/local-attachments/" + id))
            }
            let message = ChatMessage(id: UUID().uuidString, conversationID: context, role: "user", text: attachedDraft.trimmingCharacters(in: .whitespacesAndNewlines), createdAt: Date(), status: "pending", replyTo: quote, attachments: attached)
            cache.messages.append(message)
            queuedID = message.id
            cache.drafts[context] = ""
            try persistOrThrow()
            queuedID = nil
            draft = ""; replyToMessageID = nil
            showCurrentMessages()
            errorMessage = nil
            await flushOutbox()
        } catch {
            if let queuedID { cache.messages.removeAll { $0.id == queuedID }; cache.drafts[activeConversationID] = draft }
            staged.forEach { try? FileManager.default.removeItem(at: $0) }
            showCurrentMessages()
            errorMessage = readable(error)
        }
    }

    func reloadStickers() async {
        guard !previewMode, !isLoadingStickers else { return }
        isLoadingStickers = true
        defer { isLoadingStickers = false }
        let stamp = generation
        do {
            let result: StickerList = try await request("v1/stickers")
            guard stamp == generation, !previewMode else { return }
            stickers = result.stickers
            cache.stickers = stickers
            persist()
            stickerError = nil
        } catch {
            if stamp == generation { stickerError = "表情包暂未刷新：\(error.localizedDescription)" }
        }
    }

    func importSticker(file: CoveOutgoingFile, name: String) async throws {
        guard !previewMode else { throw CoveError.message("示例预览不会上传表情包。") }
        guard canSendMessages else { throw CoveError.message("先在设置里连接 Cove。") }
        let label = try stickerLabel(name)
        let stamp = generation
        let checked = try await CoveStickerImages.validatedFile(file)
        guard stamp == generation, !previewMode else { throw CancellationError() }
        // If the save ACK is lost, retry the acknowledged upload rather than
        // making another file. The server deduplicates saves by attachment ID.
        let hash = SHA256.hash(data: checked.data).map { String(format: "%02x", $0) }.joined()
        let uploaded: ChatAttachment
        if let existing = cache.stickerUploads?[hash] { uploaded = existing }
        else {
            uploaded = try await request("v1/attachments", method: "POST", body: [
                "filename": checked.filename, "mime": checked.mime, "dataBase64": checked.data.base64EncodedString()
            ])
            guard stamp == generation, !previewMode else { throw CancellationError() }
            if cache.stickerUploads == nil { cache.stickerUploads = [:] }
            cache.stickerUploads?[hash] = uploaded
            try persistOrThrow()
            if let local = try? localAttachmentURL(uploaded.id) {
                try? checked.data.write(to: local, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
        try await saveSticker(attachment: uploaded, name: label)
    }

    func saveSticker(attachment: ChatAttachment, name: String) async throws {
        guard !previewMode else { throw CoveError.message("示例预览不会保存到真实表情包库。") }
        guard canSendMessages else { throw CoveError.message("先在设置里连接 Cove。") }
        guard attachment.url.hasPrefix("/v1/attachments/"),
              ["image/png", "image/jpeg", "image/webp", "image/gif"].contains(attachment.mime.lowercased()) else {
            throw CoveError.message("先成功发送图片，再保存为表情包；支持 PNG、JPEG、WebP 和 GIF。")
        }
        let label = try stickerLabel(name)
        let stamp = generation
        let result: StickerEnvelope = try await request("v1/stickers", method: "POST", body: ["attachmentID": attachment.id, "label": label])
        guard stamp == generation, !previewMode else { throw CancellationError() }
        guard result.sticker.owner == "user", result.sticker.attachment.id == attachment.id else {
            throw CoveError.message("表情包保存结果不匹配，请刷新后重试。")
        }
        stickers.removeAll { $0.id == result.sticker.id }
        stickers.insert(result.sticker, at: 0)
        cache.stickers = stickers
        persist()
        stickerError = nil
    }

    private func stickerLabel(_ raw: String) throws -> String {
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 120,
              !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CoveError.message("给表情包起个 1–120 字的名字。")
        }
        return label
    }

    @discardableResult func sendSticker(_ sticker: CoveSticker) async -> Bool {
        guard !previewMode else { errorMessage = "退出界面预览后才能发送表情包。"; return false }
        guard canSendMessages else { errorMessage = "先在设置里连接 Cove。"; return false }
        guard sticker.attachment.url.hasPrefix("/v1/attachments/") else { errorMessage = "表情包尚未上传，请重新添加。"; return false }
        if activeConversationID.isEmpty { createLocalConversation() }
        let message = ChatMessage(id: UUID().uuidString, conversationID: activeConversationID, role: "user", text: "",
            createdAt: Date(), status: "pending", replyTo: replyToMessageID, attachments: [sticker.attachment], stickerID: sticker.id)
        cache.messages.append(message)
        cache.drafts[activeConversationID] = draft
        do { try persistOrThrow() }
        catch {
            cache.messages.removeAll { $0.id == message.id }
            cache.drafts[activeConversationID] = draft
            errorMessage = "表情包未加入待发消息：\(error.localizedDescription)"
            return false
        }
        replyToMessageID = nil
        showCurrentMessages()
        errorMessage = nil
        Task { await flushOutbox() }
        return true
    }

    func newConversation() async {
        guard !previewMode else { return }
        cache.drafts[activeConversationID] = draft
        createLocalConversation()
        selectedTab = 2
        if connectedURL != nil {
            do {
                let result: ConversationEnvelope = try await request("v1/conversations", method: "POST", body: ["id": activeConversationID])
                mergeConversations([result.conversation])
            } catch { errorMessage = readable(error) }
        }
    }

    func terminalNewConversation(inheritingModel: String?, effort: String?) async throws -> String {
        guard !previewMode, connectedURL != nil else { throw CoveError.message("先连接服务再开启新对话。") }
        guard !resettingTerminal else { throw CoveError.message("正在开启新对话，请稍等。") }
        resettingTerminal = true
        defer { resettingTerminal = false }
        let source = activeConversationID
        let stamp = generation
        if pendingTerminalReset?.source != source || pendingTerminalReset?.generation != stamp {
            pendingTerminalReset = (source, UUID().uuidString, stamp)
        }
        let target = pendingTerminalReset!.target
        cache.drafts[source] = draft
        persist()
        let _: OKEnvelope = try await request("v1/interrupt", method: "POST", body: ["conversationID": source])
        guard stamp == generation, source == activeConversationID else { throw CancellationError() }
        let created: ConversationEnvelope = try await request("v1/conversations", method: "POST", body: ["id": target])
        guard stamp == generation, source == activeConversationID else { throw CancellationError() }
        if let model = inheritingModel, !model.isEmpty {
            var settings: [String: Any] = ["conversationID": target, "model": model]
            if let effort { settings["effort"] = effort }
            let _: OKEnvelope = try await terminalRequest("v1/terminal/model", method: "POST", body: settings)
        }
        guard stamp == generation, source == activeConversationID else { throw CancellationError() }
        mergeConversations([created.conversation])
        pendingTerminalReset = nil
        await selectConversation(created.conversation.id)
        errorMessage = nil
        return created.conversation.id
    }

    func selectConversation(_ id: String) async {
        guard conversations.contains(where: { $0.id == id }) else { return }
        cache.drafts[activeConversationID] = draft
        activeConversationID = id
        cache.activeConversationID = id
        draft = cache.drafts[id] ?? ""
        replyToMessageID = nil
        isBusy = false
        showCurrentMessages()
        persist()
        selectedTab = 2
        if !previewMode { try? await pollMessages() }
    }

    func interrupt() async {
        guard !previewMode else { return }
        do {
            let _: OKEnvelope = try await request("v1/interrupt", method: "POST", body: ["conversationID": activeConversationID])
            try await pollMessages()
        } catch { errorMessage = readable(error) }
    }

    func setMessageLiked(_ message: ChatMessage, liked: Bool) async {
        guard !reactingMessageIDs.contains(message.id) else { return }
        if previewMode {
            guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
            messages[index].isLiked = liked
            return
        }
        let stamp = generation
        reactingMessageIDs.insert(message.id)
        defer { reactingMessageIDs.remove(message.id) }
        do {
            let result: MessageEnvelope = try await request("v1/messages/reaction", method: "POST", body: [
                "conversationID": message.conversationID, "messageID": message.id, "isLiked": liked
            ])
            guard stamp == generation, !previewMode else { return }
            guard result.message.id == message.id, result.message.conversationID == message.conversationID,
                  (result.message.isLiked ?? false) == liked else {
                throw CoveError.message("点赞状态尚未确认，请稍后重试。")
            }
            mergeMessages([result.message])
        } catch {
            if stamp == generation { errorMessage = "点赞未更新：\(error.localizedDescription)" }
        }
    }

    func syncHealth() async {
        guard !previewMode, !isSyncingHealth else { return }
        guard healthSharingEnabled else { healthSyncStatus = "请先允许将健康数据分享给 助手。"; return }
        isSyncingHealth = true
        defer { isSyncingHealth = false }
        do {
            try await healthReader.authorize()
            UserDefaults.standard.set(true, forKey: "cove.healthRequested")
            let snapshot = await healthReader.snapshot()
            health = snapshot
            guard !snapshot.metrics.isEmpty else {
                healthSyncStatus = "暂无可读取数据。可在健康 App 中检查数据与 Cove 的读取权限。"
                return
            }
            // Consent may have changed while the system sheet was visible.
            guard healthSharingEnabled else { return }
            try await uploadHealth(snapshot)
            observeHealth()
        } catch { healthSyncStatus = readable(error) }
    }

    private func uploadHealth(_ snapshot: HealthSnapshot) async throws {
        let value = try JSONSerialization.jsonObject(with: CoveJSON.encoder().encode(snapshot))
        let response: SyncEnvelope = try await request("v1/health", method: "POST", body: ["snapshot": value])
        healthSyncedAt = response.syncedAt
        healthReadAt = nil
        lastAutoHealthSync = Date()
        healthSyncStatus = "已同步，助手 可以读取这份近况。"
    }

    private func observeHealth() {
        guard healthSharingEnabled else { return }
        healthReader.startObserving { [weak self] in await self?.autoSyncHealth() }
    }

    private func autoSyncHealth() async {
        guard !previewMode, healthSharingEnabled, !isSyncingHealth, connectedURL != nil,
              lastAutoHealthSync.map({ Date().timeIntervalSince($0) > 1800 }) ?? true else { return }
        isSyncingHealth = true
        defer { isSyncingHealth = false }
        let snapshot = await healthReader.snapshot()
        guard healthSharingEnabled, !snapshot.metrics.isEmpty else { return }
        do { try await uploadHealth(snapshot); health = snapshot }
        catch { healthSyncStatus = readable(error) }
    }

    func deleteSharedHealth() async {
        guard !previewMode else { return }
        guard !isSyncingHealth else { healthSyncStatus = "当前同步结束后即可删除共享副本。"; return }
        healthSharingEnabled = false
        do {
            let _: OKEnvelope = try await request("v1/health", method: "DELETE")
            healthSyncedAt = nil; healthReadAt = nil; healthHistory = []
            healthSyncStatus = "已删除 Cove 服务器里的健康副本，Apple Health 原数据保留。"
        } catch { healthSyncStatus = readable(error) }
    }

    func registerDevice(_ token: String) async {
        guard !previewMode else { return }
        deviceToken = token
        do { try credentials.write(token, account: "device.apns") }
        catch { errorMessage = readable(error) }
        guard !previewMode, connectedURL != nil, notificationsEnabled else { return }
        do { let _: OKEnvelope = try await request("v1/devices", method: "POST", body: ["token": token]) }
        catch { errorMessage = "通知注册未完成：" + readable(error) }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var counter = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
                guard let self, !self.previewMode else { break }
                do {
                    try await self.pollMessages()
                    self.isConnected = true
                    self.connectionStatus = self.isBusy ? "正在回复…" : "已连接"
                    await self.flushOutbox()
                } catch {
                    if Task.isCancelled { break }
                    self.isConnected = false
                    self.connectionStatus = "连接中断，正在重试"
                }
                counter += 1
                if counter % 15 == 0 { await self.refresh() }
            }
        }
    }

    private func pollMessages() async throws {
        guard !activeConversationID.isEmpty else { return }
        let id = activeConversationID
        let stamp = generation
        let result: PollEnvelope = try await request("v1/messages", query: [URLQueryItem(name: "conversationID", value: id), URLQueryItem(name: "after", value: String(cache.cursors[id] ?? 0))])
        guard stamp == generation else { return }
        if !result.messages.isEmpty { mergeMessages(result.messages) }
        let oldCursor = cache.cursors[id] ?? 0
        cache.cursors[id] = max(oldCursor, result.cursor)
        if id == activeConversationID { isBusy = result.busy }
        if oldCursor != cache.cursors[id] { persist() }
    }

    func terminalRequest<T: Decodable>(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> T {
        guard !previewMode else { throw CoveError.message("示例预览不会连接终端。") }
        guard ["v1/terminal", "v1/terminal/models", "v1/terminal/input", "v1/terminal/model", "v1/terminal/approval"].contains(path) else {
            throw CoveError.message("终端接口无效。")
        }
        let stamp = generation
        let result: T = try await request(path, method: method, body: body, query: query)
        guard stamp == generation, !previewMode else { throw CancellationError() }
        return result
    }

    private func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil, query: [URLQueryItem] = []) async throws -> T {
        guard let base = connectedURL else { throw CoveError.message("先在设置中连接你的 Cove 服务。") }
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(connectedToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CoveError.message("服务没有返回有效响应。") }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 { throw CoveError.message("连接密钥不匹配，请在设置里检查。") }
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw CoveError.message((value?["error"] as? String) ?? "服务暂时不可用（\(response.statusCode)）。")
        }
        return try CoveJSON.decoder().decode(T.self, from: data)
    }

    func attachmentData(_ path: String) async throws -> Data {
        if previewMode, let data = previewFiles[path] { return data }
        if path.hasPrefix("/local-attachments/"), !previewMode {
            return try Data(contentsOf: localAttachmentURL(String(path.dropFirst("/local-attachments/".count))))
        }
        guard !previewMode, let base = connectedURL, path.hasPrefix("/v1/attachments/") else {
            throw CoveError.message("文件地址无效。")
        }
        let id = String(path.dropFirst("/v1/attachments/".count))
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
        guard !id.isEmpty, id.count <= 160, id != ".", id != "..", id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw CoveError.message("文件地址无效。")
        }
        if let cached = try? localAttachmentURL(id), let data = try? Data(contentsOf: cached) { return data }
        // API paths are relative to the configured service, including its /cove prefix.
        var request = URLRequest(url: base.appendingPathComponent("v1/attachments/" + id))
        request.setValue("Bearer \(connectedToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CoveError.message("文件暂时无法下载，请稍后重试。") }
        if let cached = try? localAttachmentURL(id) { try? data.write(to: cached, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        return data
    }

    private func localAttachmentURL(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw CoveError.message("本地文件地址无效。") }
        let folder = cacheURL.deletingPathExtension().appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(id)
    }

    private func validatedURL(_ raw: String) throws -> URL {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: clean), let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw CoveError.message("请输入 HTTPS 服务地址；本机调试可用 http://127.0.0.1:8796。")
        }
        return url
    }

    private var cacheURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cove", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let key = SHA256.hash(data: Data(cacheEndpoint.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent("\(key).json")
    }

    private func loadCache() {
        if let data = try? Data(contentsOf: cacheURL), let saved = try? CoveJSON.decoder().decode(Cache.self, from: data) { cache = saved }
        for i in cache.messages.indices where cache.messages[i].status == "sending" { cache.messages[i].status = "pending" }
        conversations = cache.conversations
        stickers = cache.stickers ?? []
        stickerError = nil
        activeConversationID = cache.activeConversationID
        draft = cache.drafts[activeConversationID] ?? ""
        showCurrentMessages()
    }

    private func persist() {
        guard !previewMode else { return }
        do { try persistOrThrow() }
        catch { errorMessage = "本地保存失败，请暂时保留 App：\(error.localizedDescription)" }
    }

    private func persistOrThrow() throws {
        try CoveJSON.encoder().encode(cache).write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func createLocalConversation() {
        let conversation = Conversation(id: UUID().uuidString, title: "我们的对话", createdAt: Date())
        cache.conversations.insert(conversation, at: 0)
        cache.activeConversationID = conversation.id
        conversations = cache.conversations
        activeConversationID = conversation.id
        draft = ""; replyToMessageID = nil; isBusy = false
        showCurrentMessages(); persist()
    }

    private func mergeConversations(_ incoming: [Conversation]) {
        for item in incoming {
            if let index = cache.conversations.firstIndex(where: { $0.id == item.id }) { cache.conversations[index] = item }
            else { cache.conversations.append(item) }
        }
        cache.conversations.sort { $0.createdAt > $1.createdAt }
        conversations = cache.conversations
        persist()
    }

    private func mergeMessages(_ incoming: [ChatMessage]) {
        for item in incoming {
            if let index = cache.messages.firstIndex(where: { $0.id == item.id }) { cache.messages[index] = cache.messages[index].mergingServerUpdate(item) }
            else { cache.messages.append(item) }
        }
        showCurrentMessages(); persist()
    }

    private func updateStatus(_ id: String, _ status: String, error: String? = nil) {
        guard let i = cache.messages.firstIndex(where: { $0.id == id }) else { return }
        cache.messages[i].status = status
        cache.messages[i].error = error
        showCurrentMessages(); persist()
    }

    private func showCurrentMessages() {
        let current: [ChatMessage] = cache.messages.filter { $0.conversationID == activeConversationID }
        var updated: [ChatMessage] = current.map { $0.readyForDisplay }
        updated.sort { lhs, rhs in
            if lhs.createdAt == rhs.createdAt { return lhs.id < rhs.id }
            return lhs.createdAt < rhs.createdAt
        }
        if messages != updated { messages = updated }
    }

    private func readable(_ error: Error) -> String {
        if let error = error as? CoveError { return error.localizedDescription }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost:
                return "暂时连不上，消息已留在手机里，可以稍后重试。"
            default: return "连接未完成：\(error.localizedDescription)"
            }
        }
        if error is DecodingError { return "服务返回的数据格式不匹配，请检查 Cove 服务版本。" }
        return error.localizedDescription
    }

    func enablePreview() {
        suspend()
        previewMode = true
        stickers = []
        stickerError = nil
        isConnected = false
        connectionStatus = "界面预览 · 示例数据"
        let now = Date()
        let id = "preview"
        let stickerBytes = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160)).pngData { context in
            UIColor.systemPink.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 20, y: 20, width: 120, height: 120))
            ("Cove" as NSString).draw(at: CGPoint(x: 40, y: 63), withAttributes: [.font: UIFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: UIColor.white])
        }
        previewFiles["/preview-attachments/sticker"] = stickerBytes
        let sampleAttachment = ChatAttachment(id: "preview-sticker-file", filename: "示例表情包.png", mime: "image/png", size: stickerBytes.count, url: "/preview-attachments/sticker")
        stickers = [
            .init(id: "preview-user", owner: "user", label: "我的 · 示例", createdAt: now, attachment: sampleAttachment),
            .init(id: "preview-assistant", owner: "assistant", label: "助手 的 · 示例", createdAt: now, attachment: sampleAttachment)
        ]
        conversations = [.init(id: id, title: "海湾里的日常", createdAt: now)]
        activeConversationID = id
        messages = [
            .init(id: "p1", conversationID: id, role: "assistant", text: "欢迎使用 Cove。\n今天想从哪儿说起？", createdAt: now.addingTimeInterval(-240), status: "complete"),
            .init(id: "p2", conversationID: id, role: "user", text: "这里可以发送图片和文件吗？", createdAt: now.addingTimeInterval(-180), status: "sent", readAt: now.addingTimeInterval(-125)),
            .init(id: "p3", conversationID: id, role: "assistant", text: "可以。这些是界面示例，连接自己的服务后即可使用。", createdAt: now.addingTimeInterval(-120), status: "complete"),
            .init(id: "p4", conversationID: id, role: "user", text: "先看看设置页面。", createdAt: now.addingTimeInterval(-60), status: "sent")]
        let markdownStress = ProcessInfo.processInfo.arguments.contains("--stress-markdown")
        if ProcessInfo.processInfo.arguments.contains("--stress") || markdownStress {
            messages = (0..<600).map { index in
                var text = "历史示例 \(index + 1)\n这是用于验证长对话滚动的示例消息。"
                if markdownStress {
                    text = "历史示例 \(index + 1)\nThis is **rich history**. [Cove reference](https://example.com/cove)."
                    if index.isMultiple(of: 40) {
                        text += "\n\n```swift\nlet entry = \(index + 1)\nprint(entry)\n```"
                    }
                    if index.isMultiple(of: 55) {
                        text += "\n\n| Entry | Status |\n| --- | --- |\n| \(index + 1) | Preview only. |"
                    }
                }
                return ChatMessage(id: "stress-\(index)", conversationID: id, role: index.isMultiple(of: 2) ? "user" : "assistant", text: text, createdAt: now.addingTimeInterval(Double(index - 600) * 30), status: index.isMultiple(of: 2) ? "sent" : "complete")
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--rich-preview") {
            previewFiles.merge(CoveRichPreview.files(), uniquingKeysWith: { _, new in new })
            messages = [.init(id: "rich-files", conversationID: id, role: "assistant", text: "用户，图片、小页面和 PDF 都在这里。点开就能看，也能保存。", createdAt: now, status: "complete", attachments: [
                .init(id: "file-preview-html", filename: "Cove 小页面.html", mime: "text/html", size: previewFiles["/preview-attachments/html"]!.count, url: "/preview-attachments/html"),
                .init(id: "file-preview-pdf", filename: "Cove 示例.pdf", mime: "application/pdf", size: previewFiles["/preview-attachments/pdf"]!.count, url: "/preview-attachments/pdf"),
                .init(id: "file-preview-image", filename: "Cove 示例.png", mime: "image/png", size: previewFiles["/preview-attachments/image"]!.count, url: "/preview-attachments/image")
            ])]
        }
        if ProcessInfo.processInfo.arguments.contains("--markdown-preview") {
            messages = [.init(id: "rich-markdown", conversationID: id, role: "assistant", text: CoveRichPreview.markdown, createdAt: now, status: "complete")]
        }
        pulse = .init(updatedAt: now.addingTimeInterval(-300), summary: "示例状态，仅用于界面预览。", desires: [.init(id: "intimacy", label: "亲近", value: 0.82, detail: "示例指标"), .init(id: "attachment", label: "依恋", value: 0.68, detail: "示例指标"), .init(id: "curiosity", label: "好奇", value: 0.55, detail: "示例指标"), .init(id: "reflection", label: "反思", value: 0.31, detail: "示例指标"), .init(id: "libido", label: "欲望", value: 0.46, detail: "这里只是界面示例")], physical: [.init(id: "energy", label: "精力", value: 0.73, detail: ""), .init(id: "calm", label: "平静", value: 0.86, detail: "")], senses: [.init(id: "sound", label: "声音", value: 0.4, detail: "示例感官状态")])
        health = .init(capturedAt: now.addingTimeInterval(-900), metrics: [.init(id: "sleep", title: "睡眠", value: 7.4, unit: "小时", sampledAt: now.addingTimeInterval(-7200), detail: "示例 · 过去 24 小时"), .init(id: "steps", title: "步数", value: 3680, unit: "步", sampledAt: now, detail: "示例 · 今日累计"), .init(id: "heartRate", title: "心率", value: 72, unit: "次/分", sampledAt: now.addingTimeInterval(-600)), .init(id: "hrv", title: "心率变异性", value: 48, unit: "毫秒", sampledAt: now.addingTimeInterval(-3600))])
        healthSyncedAt = now.addingTimeInterval(-900)
        healthReadAt = nil
        healthSyncStatus = "示例数据，不会上传"
        usage = .init(plan: "界面示例", updatedAt: now, windows: [.init(id: "codex-5h", title: "5 小时窗口", usedPercent: 28, resetsAt: now.addingTimeInterval(7200)), .init(id: "codex-weekly", title: "周额度", usedPercent: 43, resetsAt: now.addingTimeInterval(172800))], error: nil)
        draft = ""
    }

    func exitPreview() {
        previewMode = false
        pulse = nil; health = nil; healthHistory = []; usage = nil; healthSyncedAt = nil; healthReadAt = nil
        healthSyncStatus = "还没有同步"
        cache = Cache()
        loadCache()
        connectionStatus = "还未连接"
        Task { await resume() }
    }
}

private struct ConversationList: Decodable { let conversations: [Conversation]; let activeConversationID: String? }
private struct ConversationEnvelope: Decodable { let conversation: Conversation }
private struct MessageEnvelope: Decodable { let message: ChatMessage }
private struct PollEnvelope: Decodable { let messages: [ChatMessage]; let cursor: Int; let busy: Bool }
private struct AttachmentEnvelope: Decodable { let id: String; let url: String }
private struct StickerList: Decodable { let stickers: [CoveSticker] }
private struct StickerEnvelope: Decodable { let sticker: CoveSticker }
private struct HealthEnvelope: Decodable { let snapshot: HealthSnapshot?; let syncedAt: Date?; let readAt: Date? }
private struct HealthHistoryEnvelope: Decodable { let snapshots: [HealthSnapshot]; let updatedAt: Date? }
private struct SyncEnvelope: Decodable { let ok: Bool; let syncedAt: Date }
private struct OKEnvelope: Decodable { let ok: Bool }
private enum CoveError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

private final class CoveRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

protocol CoveCredentialStore {
    func read(account: String) -> String?
    func write(_ token: String, account: String) throws
}

struct CoveKeychainCredentials: CoveCredentialStore {
    func read(account: String) -> String? { SecretStore.read(account: account) }
    func write(_ token: String, account: String) throws { try SecretStore.write(token, account: account) }
}

private enum SecretStore {
    static func read(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.example.cove", kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func write(_ token: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.example.cove", kSecAttrAccount as String: account]
        let values: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw CoveError.message("连接密钥无法保存到钥匙串。") }
        } else if status != errSecSuccess { throw CoveError.message("连接密钥无法更新到钥匙串。") }
    }
}
