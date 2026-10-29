import Foundation
import Combine
import CryptoKit
import Security
import UIKit
import UserNotifications

/// The live composer is deliberately not part of `CoveStore.objectWillChange`.
/// A keystroke should update the input row, not invalidate every screen that
/// observes the app-wide store. CoveStore still owns persistence and sending.
@MainActor
final class CoveComposerDraftState: ObservableObject {
    @Published var text: String
    private(set) var conversationID: String

    init(text: String = "", conversationID: String = "") {
        self.text = text
        self.conversationID = conversationID
    }

    func activate(conversationID: String, text: String) {
        self.conversationID = conversationID
        if self.text != text { self.text = text }
    }
}

@MainActor
final class CoveStore: ObservableObject {
    let travel = CoveTravelModel()
    @Published var selectedTab = 2
    @Published var messages: [ChatMessage] = []
    @Published var conversations: [Conversation] = []
    @Published var activeConversationID = ""
    let composerDraft = CoveComposerDraftState()
    var draft: String {
        get { composerDraft.text }
        set { composerDraft.text = newValue }
    }
    @Published var replyToMessageID: String?
    @Published var serverURL = ""
    @Published var accessToken = ""
    @Published var connectionStatus = "还未连接"
    @Published var isConnected = false
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var pulse: PulseSnapshot?
    @Published private(set) var pulseDashboard: PulseDashboard?
    @Published private(set) var pulseError: String?
    @Published private(set) var pulseLastReceivedAt: Date?
    @Published private(set) var isRefreshingPulse = false
    @Published var usage: UsageSnapshot?
    @Published private(set) var sessionContext: CoveSessionContext?
    @Published private(set) var sessionContextError: String?
    @Published private(set) var sessionHandoff: CoveSessionHandoff?
    @Published private(set) var handoffError: String?
    @Published private(set) var handoffRequestPending = false
    private var refreshingSession = false
    @Published var health: HealthSnapshot?
    @Published var healthHistory: [HealthSnapshot] = []
    @Published private(set) var healthArchiveEntries: [CoveHealthArchiveEntry] = []
    @Published private(set) var healthArchiveError: String?
    private let healthArchive: CoveHealthArchive
    private var healthArchiveLoaded = false
    private var healthArchiveHasUnsavedChanges = false
    @Published var healthSyncedAt: Date?
    @Published var healthReadAt: Date?
    @Published var isSyncingHealth = false
    // Authoritative service grant, not the obsolete device-only preference.
    @Published private(set) var healthSharingEnabled = false
    @Published private(set) var healthDataAccessKnown = false
    @Published private(set) var isUpdatingHealthDataAccess = false
    @Published private(set) var healthDataAccessStatus = "尚未读取持续授权状态"
    @Published private(set) var personalLedgerSyncStatus = "Assistant 账本读取尚未同步"
    @Published private(set) var personalLedgerLastSyncedAt: Date?
    private var personalLedgerSyncedSnapshot: CoveLedgerSnapshot?
    private var personalLedgerVerifiedAt: Date?
    private var personalLedgerSyncTask: Task<Void, Never>?
    private var personalLedgerObserver: AnyCancellable?
    private var personalLedgerSyncRequested = true
    private var personalLedgerRetryAfter = Date.distantPast
    private var personalLedgerFailures = 0
    private var personalLedgerCommandsCheckedAt = Date.distantPast
    private var healthAccessRevision = UUID()
    private var healthUploadsPaused = false
    private var healthForegroundActive = true
    private let healthRefreshDefaults: UserDefaults
    private var healthHasPendingChange = false
    private var automaticHealthTask: Task<Void, Never>?
    private var automaticHealthTaskID = UUID()
    private var healthChangeTask: Task<Void, Never>?
    @Published var healthSyncStatus = "尚未在本机读取"
    @Published private(set) var healthRequests: [CoveHealthRequest] = []
    @Published private(set) var respondingHealthRequestIDs: Set<String> = []
    @Published private(set) var readingHealthRequestIDs: Set<String> = []
    private var cancelledHealthRequestIDs: Set<String> = []
    @Published private(set) var healthRequestErrors: [String: String] = [:]
    @Published private(set) var healthRequestsStatus = ""
    @Published private(set) var collarPermissionRevision = UUID()
    @Published private(set) var deviceRequests: [CoveDeviceRequest] = []
    @Published private(set) var deviceRequestErrors: [String: String] = [:]
    @Published private(set) var deviceRequestTargets: [String: CoveDeviceRecord] = [:]
    @Published private(set) var respondingDeviceRequestIDs: Set<String> = []
    private let deviceBackend: any CoveDeviceActionBackend
    private let deviceExecutor: CoveDeviceActionExecutor
    private let deviceReceiptJournal = CoveDeviceReceiptJournal()
    private let bridgeDeviceID: String
    private var deviceBridgeEpoch = UUID()
    private var refreshingDeviceRequests = false
    private var deviceBridgeStatuses: [String: String] = [:]
    private var claimedDeviceRequests: Set<String> = []
    @Published var previewMode = false
    @Published var appearance = "system"
    @Published var notificationsEnabled = false
    @Published var notificationPreviewMode = "generic"
    @Published private(set) var notificationSyncError: String?
    @Published var attachmentUploadStatus: String?
    @Published private(set) var reactingMessageIDs: Set<String> = []
    @Published private(set) var stickers: [CoveSticker] = []
    @Published private(set) var isLoadingStickers = false
    @Published var stickerError: String?
    @Published private(set) var scrollRequest: CoveScrollRequest?
    @Published private(set) var messageHighlight: CoveMessageHighlight?
    @Published private(set) var searchReturnConversationID: String? {
        didSet { cache.searchReturnConversationID = searchReturnConversationID }
    }
    @Published private(set) var currentConversationID: String? {
        didSet { cache.currentConversationID = currentConversationID }
    }
    @Published private(set) var latestMessageRequest: UUID?
    private var historyNavigationID = UUID()

    var canReturnToCurrentChat: Bool {
        searchReturnConversationID != nil || messageHighlight != nil
            || (currentConversationID != nil && currentConversationID != activeConversationID)
    }
    @Published private(set) var isLocatingMessage = false
    /// Set while a search locate is in flight so ChatView does not align the
    /// conversation switch to the bottom instead of the located message.
    private(set) var locateInFlightMessageID: String?
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
        var pendingHandoffs: [String: String]? = nil
        var persistenceRevision: UInt64? = nil
        var searchReturnConversationID: String? = nil
        var currentConversationID: String? = nil
    }
    private var cache = Cache()
    private let chatCacheIO = CoveChatCacheIO()
    private var pollTask: Task<Void, Never>?
    private var pollTaskID = UUID()
    private var handshakeComplete = false
    private var panelRefreshTask: Task<Void, Never>?
    private var deviceRefreshTask: Task<Void, Never>?
    private var outboxTask: Task<Void, Never>?
    private var recoveryWakeTask: Task<Void, Never>?
    private var recoveryWakeTaskID = UUID()
    private var pendingNotificationConversationID: String?
    private let networkRecoveryMonitor: CoveNetworkRecoveryMonitor?
    private let connectionPollInterval: TimeInterval
    private let connectionRetryDelays: [TimeInterval]
    private var savingDraft: AnyCancellable?
    private let healthReader: any CoveHealthReading
    private var sendingIDs: Set<String> = []
    private var flushing = false
    private var refreshing = false
    private var pulseRefreshing = false
    private var connecting = false
    private var resettingTerminal = false
    private var pendingTerminalReset: (source: String, target: String, generation: UUID)?
    private var generation = UUID()
    private var connectedURL: URL?
    private var connectedToken = ""
    private var cacheEndpoint = ""
    private var deviceToken: String?
    private var syncingNotificationPreference = false
    private var notificationPreferenceRevision = 0
    private let session: URLSession
    private let uploadSession: URLSession
    private let credentials: any CoveCredentialStore

    init(session overrideSession: URLSession? = nil, credentials: any CoveCredentialStore = CoveKeychainCredentials(), healthReader: (any CoveHealthReading)? = nil,
         healthArchive: CoveHealthArchive = CoveHealthArchive(), healthRefreshDefaults: UserDefaults = .standard,
         deviceBackend: (any CoveDeviceActionBackend)? = nil,
         connectionPollInterval: TimeInterval = 2, connectionRetryDelays: [TimeInterval] = [1, 2, 4, 8, 15]) {
        self.connectionPollInterval = max(0.01, connectionPollInterval)
        self.connectionRetryDelays = connectionRetryDelays.isEmpty ? [15] : connectionRetryDelays.map { max(0.01, $0) }
        // Injected transports are deterministic tests, not real network paths.
        self.networkRecoveryMonitor = overrideSession == nil ? CoveNetworkRecoveryMonitor() : nil
        let appleBackend = deviceBackend ?? CoveAppleDeviceBackend()
        self.deviceBackend = appleBackend
        self.deviceExecutor = CoveDeviceActionExecutor(backend: appleBackend, defaults: healthRefreshDefaults)
        let deviceKey = "cove.deviceBridge.deviceID"
        if let saved = healthRefreshDefaults.string(forKey: deviceKey), let uuid = UUID(uuidString: saved) {
            bridgeDeviceID = uuid.uuidString.lowercased()
            healthRefreshDefaults.set(bridgeDeviceID, forKey: deviceKey)
        }
        else {
            let id = UUID().uuidString.lowercased()
            bridgeDeviceID = id
            healthRefreshDefaults.set(id, forKey: deviceKey)
        }
        self.healthReader = healthReader ?? HealthSync()
        self.healthArchive = healthArchive
        self.healthRefreshDefaults = healthRefreshDefaults
        self.credentials = credentials
        if let overrideSession {
            session = overrideSession
            uploadSession = overrideSession
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 25
            config.timeoutIntervalForResource = 45
            config.waitsForConnectivity = false
            session = URLSession(configuration: config, delegate: CoveRedirectPolicy(), delegateQueue: nil)

            // Keep ordinary API calls fail-fast, but do not cancel a healthy
            // raw attachment upload on a slower mobile/iCloud connection.
            let uploadConfig = URLSessionConfiguration.default
            uploadConfig.timeoutIntervalForRequest = 180
            uploadConfig.timeoutIntervalForResource = 300
            uploadConfig.waitsForConnectivity = true
            uploadSession = URLSession(configuration: uploadConfig, delegate: CoveRedirectPolicy(), delegateQueue: nil)
        }
        serverURL = UserDefaults.standard.string(forKey: "cove.serverURL") ?? ""
        cacheEndpoint = serverURL
        accessToken = credentials.read(account: serverURL) ?? ""
        appearance = UserDefaults.standard.string(forKey: "cove.appearance") ?? "system"
        notificationsEnabled = UserDefaults.standard.bool(forKey: "cove.notifications")
        notificationPreviewMode = UserDefaults.standard.string(forKey: "cove.notificationPreviewMode") == "content" ? "content" : "generic"
        deviceToken = credentials.read(account: "device.apns")
        // Never treat the legacy local preference as a service grant.
        loadCache()
        savingDraft = composerDraft.$text.dropFirst().map { [weak self] value -> (String, String, String)? in
            guard let self, !self.previewMode, !self.activeConversationID.isEmpty else { return nil }
            // Capture the destination and text at the edit, not 250 ms later
            // when the user may already have selected another conversation.
            return (self.cacheEndpoint, self.composerDraft.conversationID, value)
        }.debounce(for: .milliseconds(250), scheduler: RunLoop.main).sink { [weak self] update in
            guard let self, let (endpoint, conversationID, value) = update,
                  endpoint == self.cacheEndpoint, !conversationID.isEmpty, !self.previewMode else { return }
            self.cache.drafts[conversationID] = value
            self.cache.persistenceRevision = (self.cache.persistenceRevision ?? 0) + 1
            let url = self.draftCacheURL
            let snapshot = CoveDraftSnapshot(revision: self.cache.persistenceRevision!, drafts: self.cache.drafts)
            self.chatCacheIO.write(snapshot, to: url) { [weak self] error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.draftCacheURL == url, !self.previewMode else { return }
                    self.errorMessage = "草稿保存失败，请暂时保留 App：\(error.localizedDescription)"
                }
            }
        }
        personalLedgerObserver = NotificationCenter.default.publisher(for: .covePersonalLedgerDidChange)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self, !self.previewMode else { return }
                self.personalLedgerSyncRequested = true
                self.personalLedgerSyncStatus = "本机已保存，等待自动同步" + self.personalLedgerLastSyncLabel
                self.schedulePersonalLedgerSync()
            }
        if ProcessInfo.processInfo.arguments.contains("--preview") { enablePreview() }
        else { restoreLocalHealthHistory() }
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--tab"), ProcessInfo.processInfo.arguments.count > index + 1,
           let tab = Int(ProcessInfo.processInfo.arguments[index + 1]), (0...4).contains(tab) { selectedTab = tab }
    }

    var isSwitchingSession: Bool {
        handoffRequestPending || sessionHandoff?.isRunning == true || cache.pendingHandoffs?[activeConversationID] != nil
    }
    var canSendMessages: Bool { !previewMode && connectedURL != nil && !isSwitchingSession }

    /// Places explicitly confirmed local content in the active composer without sending it.
    /// Existing text is preserved verbatim so another feature can never erase a draft.
    func placeInComposerDraft(_ text: String) {
        guard !previewMode, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = draft.isEmpty ? text : draft + "\n\n" + text
        selectedTab = 2
    }

    var canStartSessionHandoff: Bool {
        canSendMessages && isConnected && !isBusy && !flushing && !activeConversationID.isEmpty &&
        sessionContext?.conversationID == activeConversationID && sessionContext?.handoffAvailable == true &&
        !messages.contains { $0.role == "user" && ["pending", "sending"].contains($0.status) }
    }

    var isLocalSendQA: Bool {
        #if DEBUG
        return previewMode && ProcessInfo.processInfo.arguments.contains("--chat-send-qa")
        #else
        return false
        #endif
    }

    func saveSettings() {
        guard !previewMode else { return }
        UserDefaults.standard.set(appearance, forKey: "cove.appearance")
        UserDefaults.standard.set(notificationsEnabled, forKey: "cove.notifications")
        UserDefaults.standard.set(notificationPreviewMode, forKey: "cove.notificationPreviewMode")
        // Endpoint and its secret are committed together by connect(), not per keystroke.
        if notificationsEnabled {
            Task { await syncNotificationPreference() }
            Task {
                let allowed = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
                if allowed && notificationsEnabled {
                    UIApplication.shared.registerForRemoteNotifications()
                    if let deviceToken { await registerDevice(deviceToken) }
                }
            }
        } else {
            UIApplication.shared.unregisterForRemoteNotifications()
            Task { await syncNotificationPreference() }
        }
    }

    func connect() async {
        guard !previewMode else { return }
        guard !flushing else { errorMessage = "当前消息发送结束后再切换连接。"; return }
        do {
            let url = try validatedURL(serverURL)
            let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw CoveError.message("填入你的 Cove 连接密钥后再连接。") }
            if let previousURL = connectedURL, previousURL != url { pendingNotificationConversationID = nil }
            stopConnectionWork()
            generation = UUID()
            let stamp = generation
            connecting = true
            healthForegroundActive = true
            defer { if stamp == generation { connecting = false } }
            handshakeComplete = false
            deviceRequests = []; deviceRequestErrors = [:]; deviceRequestTargets = [:]
            resetStandingHealthAccess()
            messageHighlight = nil; scrollRequest = nil; locateInFlightMessageID = nil
            sessionContext = nil; sessionHandoff = nil; sessionContextError = nil; handoffError = nil
            pulseDashboard = nil; pulseError = nil; pulseLastReceivedAt = nil
            healthRequests = []; healthRequestErrors = [:]
            isConnected = false
            connectionStatus = "正在连接…"
            if cacheEndpoint != url.absoluteString {
                if !activeConversationID.isEmpty { cache.drafts[activeConversationID] = draft }
                persist()
                serverURL = url.absoluteString
                cacheEndpoint = url.absoluteString
                cache = Cache()
                loadCache()
                pulse = nil; usage = nil
                healthSyncedAt = nil; healthReadAt = nil
            }
            connectedURL = url
            connectedToken = token
            // Await only the first chat attempt, never auxiliary panels/uploads.
            await startPolling()
        } catch {
            errorMessage = readable(error)
            if !isConnected { connectionStatus = "连接未成功" }
        }
    }

    func resume() async {
        guard !previewMode else { return }
        healthForegroundActive = true
        guard !connecting else { return }
        if connectedURL == nil && !serverURL.isEmpty { await connect() }
        else if connectedURL != nil { await startPolling() }
    }

    private func stopConnectionWork() {
        networkRecoveryMonitor?.stop()
        recoveryWakeTaskID = UUID()
        recoveryWakeTask?.cancel(); recoveryWakeTask = nil
        pollTaskID = UUID()
        pollTask?.cancel(); pollTask = nil
        // Retain auxiliary task handles until their own defers finish: a native
        // health/device operation may not cooperate with cancellation immediately.
        panelRefreshTask?.cancel()
        deviceRefreshTask?.cancel()
        outboxTask?.cancel()
        personalLedgerSyncTask?.cancel()
        personalLedgerSyncRequested = true
        personalLedgerVerifiedAt = nil
        personalLedgerRetryAfter = .distantPast
    }

    /// APNs and Wi-Fi/cellular changes only wake the durable cursor sync. They
    /// never synthesize a message, reset a cursor, or mark the transport connected.
    func requestImmediateRecovery() {
        guard healthForegroundActive, !previewMode, recoveryWakeTask == nil else { return }
        let stamp = generation, id = UUID()
        recoveryWakeTaskID = id
        recoveryWakeTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.recoveryWakeTaskID == id { self.recoveryWakeTask = nil } }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard stamp == self.generation, self.healthForegroundActive, !Task.isCancelled else { return }
            self.pollTaskID = UUID()
            self.pollTask?.cancel(); self.pollTask = nil
            if self.connectedURL != nil { await self.startPolling() }
            else { await self.resume() }
        }
    }

    func receiveRemoteNotification(conversationID: String?, openConversation: Bool) {
        guard !previewMode else { return }
        if openConversation {
            selectedTab = 2
            pendingNotificationConversationID = conversationID
        }
        requestImmediateRecovery()
    }

    private func resolveNotificationFocus() async throws {
        guard let id = pendingNotificationConversationID else { return }
        if !conversations.contains(where: { $0.id == id }) {
            let result: ConversationList = try await request("v1/conversations")
            mergeConversations(result.conversations)
            currentConversationID = result.activeConversationID
        }
        guard pendingNotificationConversationID == id else { return }
        pendingNotificationConversationID = nil
        _ = activateConversation(id)
    }

    func suspend() {
        generation = UUID()
        connecting = false
        deviceBridgeEpoch = UUID()
        healthForegroundActive = false
        stopConnectionWork()
        automaticHealthTask?.cancel()
        automaticHealthTask = nil
        automaticHealthTaskID = UUID()
        healthReader.stopObserving()
        healthChangeTask?.cancel()
        healthChangeTask = nil
        if !previewMode { cache.drafts[activeConversationID] = draft; persist(); chatCacheIO.flush() }
    }

    func refresh() async {
        guard !previewMode, healthForegroundActive, connectedURL != nil, !refreshing else { return }
        if !handshakeComplete || pollTask == nil { await startPolling(); return }
        refreshing = true
        defer { refreshing = false }
        let stamp = generation
        do {
            try await pollMessages()
            guard stamp == generation, healthForegroundActive, !Task.isCancelled else { return }
            isConnected = true
            connectionStatus = isBusy ? "正在回复…" : "已连接"
        } catch {
            guard stamp == generation, healthForegroundActive, !Task.isCancelled else { return }
            isConnected = false
            connectionStatus = "连接中断，正在重试"
        }
        scheduleConnectionExtras(includePanels: true, includeHealthRequests: true)
        // Explicit pull-to-refresh keeps its panel-completion semantics. The
        // recovery owner never calls this method or waits for these panels.
        if let panelRefreshTask { await panelRefreshTask.value }
    }

    private func refreshPanels() async {
        let stamp = generation
        func current() -> Bool { stamp == generation && healthForegroundActive && !previewMode && !Task.isCancelled }
        guard current() else { return }
        await refreshPulseDashboard()
        guard current() else { return }
        if let snapshot: UsageSnapshot = try? await request("v1/usage"), current() { usage = snapshot }
        guard current() else { return }
        await refreshSessionContext()
        guard current() else { return }
        await refreshHealthDataAccess()
        guard current() else { return }
        await flushPendingStandingHealthIfPossible()
        guard current() else { return }
        scheduleStandingHealthSync()
    }

    /// Read-only status recovery; this never creates a model turn.
    func refreshSessionContext() async {
        guard !previewMode, connectedURL != nil, !activeConversationID.isEmpty, !refreshingSession else { return }
        refreshingSession = true
        defer { refreshingSession = false }
        let source = activeConversationID
        let stamp = generation
        do {
            let context: CoveSessionContext = try await request("v1/conversations/\(source)/context")
            guard stamp == generation, source == activeConversationID, !previewMode else { return }
            guard context.conversationID == source else { throw CoveError.message("上下文所属会话不匹配。") }
            sessionContext = context
            sessionContextError = context.error
        } catch {
            guard stamp == generation, source == activeConversationID, !previewMode else { return }
            sessionContextError = "上下文用量暂未更新，请稍后刷新。"
        }
        do {
            let pending = cache.pendingHandoffs?[source]
            let query = pending.map { [URLQueryItem(name: "id", value: $0)] } ?? []
            let handoff: CoveSessionHandoff? = try await request("v1/conversations/\(source)/handoff", query: query)
            guard stamp == generation, source == activeConversationID, !previewMode else { return }
            if let handoff {
                try await receiveHandoff(handoff, source: source, stamp: stamp)
            } else if pending != nil {
                handoffError = "服务器尚未确认这次换窗。再次确认会复用同一个请求，不会重复新建。"
            }
        } catch {
            if stamp == generation, source == activeConversationID, cache.pendingHandoffs?[source] != nil {
                handoffError = "换窗进度暂未确认。旧对话保留，可重新查询或用原请求重试。"
            }
        }
        if stamp == generation, source != activeConversationID, !previewMode {
            refreshingSession = false
            await refreshSessionContext()
        }
    }

    func beginSessionHandoff() async {
        guard !previewMode, connectedURL != nil, !handoffRequestPending else { return }
        let source = activeConversationID
        let stamp = generation
        let pending = cache.pendingHandoffs?[source]
        guard pending != nil || canStartSessionHandoff else {
            handoffError = "请等当前回复和待发送消息完成后再换窗。"
            return
        }
        handoffRequestPending = true
        defer { handoffRequestPending = false }
        handoffError = nil
        let id = pending ?? UUID().uuidString
        if cache.pendingHandoffs == nil { cache.pendingHandoffs = [:] }
        cache.pendingHandoffs?[source] = id
        cache.drafts[source] = draft
        do {
            // Commit the idempotency key before dispatch; reconnects reuse it.
            try persistOrThrow()
            let result: CoveSessionHandoff = try await request("v1/conversations/\(source)/handoff", method: "POST", body: ["id": id])
            guard stamp == generation, source == activeConversationID, !previewMode else { return }
            try await receiveHandoff(result, source: source, stamp: stamp)
        } catch {
            guard stamp == generation, source == activeConversationID, !previewMode else { return }
            if let rejection = error as? CoveHTTPError, [400, 404, 409, 413].contains(rejection.status), pending == nil {
                cache.pendingHandoffs?.removeValue(forKey: source)
                persist()
                handoffError = "换窗未开始：" + rejection.message
            } else {
                handoffError = "换窗尚未确认：\(error.localizedDescription)。旧窗和草稿已保留，重试会复用本次请求。"
            }
        }
    }

    private func receiveHandoff(_ result: CoveSessionHandoff, source: String, stamp: UUID) async throws {
        guard result.sourceConversationID == source,
              cache.pendingHandoffs?[source] == nil || cache.pendingHandoffs?[source] == result.id else {
            throw CoveError.message("换窗回执不匹配，未切换对话。")
        }
        sessionHandoff = result
        handoffError = result.error
        if result.isRunning {
            if cache.pendingHandoffs == nil { cache.pendingHandoffs = [:] }
            cache.pendingHandoffs?[source] = result.id
            persist()
        } else if result.status == "failed" {
            cache.pendingHandoffs?.removeValue(forKey: source)
            persist()
        } else if result.status == "complete", cache.pendingHandoffs?[source] == result.id {
            guard let target = result.targetConversationID, target != source else {
                throw CoveError.message("新会话尚未确认，未切换对话。")
            }
            let list: ConversationList = try await request("v1/conversations")
            guard stamp == generation, source == activeConversationID, !previewMode else { return }
            guard list.conversations.contains(where: { $0.id == target }) else {
                throw CoveError.message("新会话尚未同步，请稍后刷新。")
            }
            mergeConversations(list.conversations)
            currentConversationID = list.activeConversationID
            cache.pendingHandoffs?.removeValue(forKey: source)
            persist()
            await selectConversation(target)
        }
    }

    var pulseIsStale: Bool {
        if previewMode { return false }
        guard let received = pulseLastReceivedAt else { return pulse != nil }
        let ageLimit = pulseDashboard?.snapshot.vitals == nil ? 600.0 : 60.0
        let sourceStale = pulse.map { Date().timeIntervalSince($0.updatedAt) > ageLimit } ?? true
        return Date().timeIntervalSince(received) > 15 || sourceStale
    }

    /// Read-only. It never causes a heartbeat or model turn.
    func refreshPulseDashboard() async {
        guard !previewMode, connectedURL != nil, !pulseRefreshing else { return }
        pulseRefreshing = true
        isRefreshingPulse = true
        defer { pulseRefreshing = false; isRefreshingPulse = false }
        let stamp = generation
        do {
            let dashboard: PulseDashboard = try await request("v1/pulse/dashboard")
            guard stamp == generation else { return }
            pulseDashboard = dashboard
            pulse = dashboard.snapshot.legacySnapshot
            pulseLastReceivedAt = Date()
            pulseError = nil
        } catch {
            if pulseDashboard != nil {
                // A transient dashboard failure must not replace a richer last-known
                // dashboard with the legacy endpoint's single snapshot.
                guard stamp == generation else { return }
                pulseError = "心跳更新失败：" + readable(error)
                return
            }
            // Older Cove servers only expose the single snapshot. Keep that useful
            // fallback honest: it contains no history or wake records.
            do {
                let snapshot: PulseSnapshot = try await request("v1/pulse")
                guard stamp == generation else { return }
                pulse = snapshot
                pulseDashboard = nil
                pulseLastReceivedAt = Date()
                pulseError = "当前服务仅提供最近一次记录，暂无 24 小时历史和唤醒记录。"
            } catch {
                guard stamp == generation else { return }
                pulseError = "心跳更新失败：" + readable(error)
            }
        }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        #if DEBUG
        if isLocalSendQA {
            // Explicit preview fixture: exercise the real composer/list without a network or cache write.
            let id = UUID().uuidString
            messages.append(.init(id: id, conversationID: "preview", role: "user", text: text,
                                  createdAt: Date(), status: "sent"))
            draft = ""
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard let self, self.isLocalSendQA else { return }
                if ProcessInfo.processInfo.arguments.contains("--chat-rich-reply-qa") {
                    // Explicit synthetic fixture: exercise the same stable-ID
                    // pending -> complete height change as production, never upload.
                    self.messages.append(.init(id: "reply-" + id, conversationID: "preview", role: "assistant",
                        text: "", createdAt: Date(), status: "streaming"))
                    try? await Task.sleep(for: .milliseconds(350))
                    guard self.isLocalSendQA,
                          let index = self.messages.firstIndex(where: { $0.id == "reply-" + id }) else { return }
                    let paragraphs = (1...8).map { "段落 \($0)：这是 **本地富文本测试**，验证消息高度变化后，列表仍然可见。" }.joined(separator: "\n\n")
                    self.messages[index].text = "## 本地模拟回复\n\n" + paragraphs
                        + "\n\n```swift\nlet value = 42\nprint(value)\n```\n\n| 项目 | 状态 |\n| --- | --- |\n| 布局 | 示例 |\n\n完成标记：" + text
                    self.messages[index].status = "complete"
                    return
                }
                self.messages.append(.init(id: "reply-" + id, conversationID: "preview", role: "assistant",
                                           text: "本地模拟回复：" + text, createdAt: Date(), status: "complete"))
            }
            return
        }
        #endif
        guard !previewMode else { errorMessage = "这里是界面预览。退出预览并连接后，就能和 Assistant 说话。"; return }
        guard !isSwitchingSession else { errorMessage = "正在接续对话，请等换窗完成后再发送。"; return }
        if activeConversationID.isEmpty { createLocalConversation() }
        do { try enqueueChatText(text, id: UUID().uuidString, replyTo: replyToMessageID, consumeDraft: true) }
        catch { errorMessage = "消息未保存，输入已保留：" + readable(error) }
    }

    /// Uses the same durable outbox as the composer; no alternate model request.
    /// A deterministic ID makes re-render/relaunch/repeated confirmation idempotent.
    func sendWidget(_ text: String, source: ChatMessage, widgetKey: String) throws {
        guard !isSwitchingSession, activeConversationID == source.conversationID,
              source.role == "assistant", source.status == "complete",
              messages.contains(where: { $0.id == source.id && $0.conversationID == source.conversationID && $0.text == source.text && $0.status == "complete" }) else {
            throw CoveError.message("卡片所属对话或消息已经变化，请回到原对话。")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 8000 else {
            throw CoveError.message("发送内容为空或超过 8000 字符。")
        }
        let messageID = "widget-" + CoveWidgetMarkdownIndex.digest(source.conversationID + ":" + source.id + ":" + widgetKey)
        #if DEBUG
        if isLocalSendQA {
            if messages.contains(where: { $0.id == messageID }) { throw CoveError.message("此卡片已提交，请在对话中查看原消息。") }
            messages.append(.init(id: messageID, conversationID: source.conversationID, role: "user", text: text, createdAt: Date(), status: "sent", replyTo: source.id))
            return
        }
        #endif
        guard !previewMode, connectedURL != nil else { throw CoveError.message("预览不会发送；请先连接 Cove。") }
        guard !cache.messages.contains(where: { $0.id == messageID }) else {
            throw CoveError.message("此卡片已提交，请在对话中查看或重试原消息。")
        }
        try enqueueChatText(text, id: messageID, replyTo: source.id, consumeDraft: false)
    }

    private func enqueueChatText(_ text: String, id: String, replyTo: String?, consumeDraft: Bool) throws {
        let message = ChatMessage(id: id, conversationID: activeConversationID, role: "user", text: text, createdAt: Date(), status: "pending", replyTo: replyTo, travelSceneID: travel.sceneID(conversation: activeConversationID))
        let previousDraft = cache.drafts[activeConversationID]
        cache.messages.append(message)
        cache.drafts[activeConversationID] = consumeDraft ? "" : draft
        do { try persistOrThrow() }
        catch {
            cache.messages.removeAll { $0.id == message.id }
            cache.drafts[activeConversationID] = previousDraft
            throw error
        }
        if consumeDraft { draft = ""; replyToMessageID = nil }
        if let i = cache.conversations.firstIndex(where: { $0.id == activeConversationID }), cache.conversations[i].title == "我们的对话" {
            cache.conversations[i].title = String(text.prefix(18))
            conversations = cache.conversations
        }
        showCurrentMessages()
        persist()
        Task { await flushOutbox() }
    }

    func retry(_ message: ChatMessage) {
        guard !previewMode, !isSwitchingSession, message.role == "user", ["failed", "pending"].contains(message.status) else { return }
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
                let uploaded = try await uploadAttachment(
                    filename: attached[index].filename,
                    mime: attached[index].mime,
                    data: data
                )
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
            if let sceneID = message.travelSceneID { body["travelSceneID"] = sceneID }
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
        guard !flushing, !isSwitchingSession, healthForegroundActive, !Task.isCancelled else { return }
        flushing = true
        defer { flushing = false }
        let stamp = generation
        // Re-read after each ACK: sends made while an upload is awaiting the
        // network must join this drain, not be stranded in a captured array.
        while stamp == generation, !isSwitchingSession, connectedURL != nil, healthForegroundActive, !Task.isCancelled,
              let message = cache.messages.first(where: {
                  $0.role == "user" && ["pending", "sending"].contains($0.status)
              }) {
            await deliver(message)
            // A failed/uncertain transfer must not spin or reorder later sends.
            if let status = cache.messages.first(where: { $0.id == message.id })?.status,
               ["pending", "sending", "failed"].contains(status) { break }
        }
    }

    func sendAttachment(data: Data, filename: String, mime: String) async {
        await sendAttachments(files: [.init(data: data, filename: filename, mime: mime)])
    }

    @discardableResult
    func sendAttachments(files: [CoveOutgoingFile], caption: String? = nil, expectedConversationID: String? = nil, waitForDelivery: Bool = true) async -> Bool {
        guard !previewMode else { errorMessage = "退出界面预览后才能发送附件。"; return false }
        guard canSendMessages else { errorMessage = "先在设置里连接 Cove。"; return false }
        guard expectedConversationID == nil || expectedConversationID == activeConversationID else {
            errorMessage = "对话已经切换，附件未发送。请回到原对话再发送。"
            return false
        }
        guard !files.isEmpty, files.count <= 10 else { errorMessage = "一次最多发送 10 个文件。"; return false }
        guard files.allSatisfy({ !$0.data.isEmpty && $0.data.count <= 20 * 1024 * 1024 }) else { errorMessage = "文件不能为空，每个文件最多 20 MB。"; return false }
        guard files.allSatisfy({ !$0.filename.isEmpty && $0.filename.count <= 255 && !$0.filename.contains("/") && !$0.filename.contains("\\") && !$0.filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else { errorMessage = "文件名无效。"; return false }
        var staged: [URL] = []
        var queuedID: String?
        do {
            if activeConversationID.isEmpty { createLocalConversation() }
            let context = activeConversationID
            let attachedDraft = caption ?? draft
            let quote = replyToMessageID
            var attached: [ChatAttachment] = []
            for file in files {
                let id = UUID().uuidString
                let url = try localAttachmentURL(id)
                try file.data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                staged.append(url)
                attached.append(.init(id: id, filename: file.filename, mime: file.mime, size: file.data.count, url: "/local-attachments/" + id))
            }
            let message = ChatMessage(id: UUID().uuidString, conversationID: context, role: "user", text: attachedDraft.trimmingCharacters(in: .whitespacesAndNewlines), createdAt: Date(), status: "pending", replyTo: quote, attachments: attached, travelSceneID: travel.sceneID(conversation: context))
            cache.messages.append(message)
            queuedID = message.id
            cache.drafts[context] = ""
            try persistOrThrow()
            queuedID = nil
            draft = ""; replyToMessageID = nil
            showCurrentMessages()
            errorMessage = nil
            if waitForDelivery { await flushOutbox() }
            else { Task { await flushOutbox() } }
            return true // Committed to the durable outbox; delivery may still be pending.
        } catch {
            if let queuedID { cache.messages.removeAll { $0.id == queuedID }; cache.drafts[activeConversationID] = draft }
            staged.forEach { try? FileManager.default.removeItem(at: $0) }
            showCurrentMessages()
            errorMessage = readable(error)
            return false
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
            uploaded = try await uploadAttachment(filename: checked.filename, mime: checked.mime, data: checked.data)
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
            createdAt: Date(), status: "pending", replyTo: replyToMessageID, attachments: [sticker.attachment], stickerID: sticker.id, travelSceneID: travel.sceneID(conversation: activeConversationID))
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
        guard !previewMode, !isSwitchingSession else { return }
        cache.drafts[activeConversationID] = draft
        createLocalConversation()
        selectedTab = 2
        if connectedURL != nil {
            do {
                let result: ConversationEnvelope = try await request("v1/conversations", method: "POST", body: ["id": activeConversationID])
                mergeConversations([result.conversation])
                currentConversationID = result.conversation.id
                await refreshSessionContext()
            } catch { errorMessage = readable(error) }
        }
    }

    func terminalNewConversation(inheritingModel: String?, effort: String?) async throws -> String {
        guard !previewMode, connectedURL != nil else { throw CoveError.message("先连接服务再开启新对话。") }
        guard !isSwitchingSession else { throw CoveError.message("正在接续对话，请等待换窗完成。") }
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
        currentConversationID = created.conversation.id
        pendingTerminalReset = nil
        await selectConversation(created.conversation.id)
        errorMessage = nil
        return created.conversation.id
    }

    func selectConversation(_ id: String) async {
        historyNavigationID = UUID()
        searchReturnConversationID = nil
        scrollRequest = nil
        locateInFlightMessageID = nil
        guard activateConversation(id) else { return }
        if !previewMode { try? await pollMessages(); await refreshSessionContext() }
    }

    @discardableResult
    private func activateConversation(_ id: String) -> Bool {
        guard conversations.contains(where: { $0.id == id }) else { return false }
        messageHighlight = nil
        cache.drafts[activeConversationID] = draft
        activeConversationID = id
        sessionContext = nil; sessionHandoff = nil; sessionContextError = nil; handoffError = nil
        cache.activeConversationID = id
        composerDraft.activate(conversationID: id, text: cache.drafts[id] ?? "")
        replyToMessageID = nil
        isBusy = false
        showCurrentMessages()
        persist()
        selectedTab = 2
        return true
    }

    /// Read-only full-history search. Pagination cursors are opaque and reused verbatim.
    func searchMessages(query raw: String, before: String?, date: String? = nil, timeZone: String = TimeZone.current.identifier) async throws -> (results: [CoveMessageSearchResult], nextCursor: String?) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count <= 200, !query.contains("\0"), !query.isEmpty || date != nil else { throw CoveError.message("输入关键词或选择聊天日期。") }
        if let date, !CoveChatCalendarDates.valid(date, pattern: "yyyy-MM-dd", timeZone: timeZone) {
            throw CoveError.message("聊天日期或时区无效。")
        }
        if previewMode {
            let dayFormat = CoveChatCalendarDates.formatter("yyyy-MM-dd", timeZone: timeZone)
            let matched = messages.filter {
                ["user", "assistant"].contains($0.role)
                && (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query))
                && (date == nil || dayFormat.string(from: $0.createdAt) == date)
            }.sorted { $0.createdAt > $1.createdAt }
            return (matched.map { item in
                CoveMessageSearchResult(conversationID: item.conversationID,
                    conversationTitle: conversations.first(where: { $0.id == item.conversationID })?.title ?? "示例对话",
                    messageID: item.id, role: item.role, snippet: item.text.isEmpty ? "[附件]" : item.text, createdAt: item.createdAt)
            }, nil)
        }
        let stamp = generation
        var items = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "20")]
        if let date { items += [URLQueryItem(name: "date", value: date), URLQueryItem(name: "timeZone", value: timeZone)] }
        if let before, !before.isEmpty { items.append(URLQueryItem(name: "before", value: before)) }
        let envelope: MessageSearchEnvelope = try await request("v1/messages/search", query: items)
        guard stamp == generation, !previewMode else { throw CancellationError() }
        guard envelope.query == query, date == nil || (envelope.date == date && envelope.timeZone == timeZone) else {
            throw CoveError.message("搜索结果与关键词或日期不匹配，请重试。")
        }
        return (envelope.results, envelope.nextCursor)
    }

    func messageCalendar(month: String, query raw: String, timeZone: String) async throws -> CoveMessageCalendar {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count <= 200, !query.contains("\0"), CoveChatCalendarDates.valid(month, pattern: "yyyy-MM", timeZone: timeZone) else {
            throw CoveError.message("聊天月份、关键词或时区无效。")
        }
        if previewMode {
            let formatter = CoveChatCalendarDates.formatter("yyyy-MM-dd", timeZone: timeZone)
            let matched = messages.filter { ["user", "assistant"].contains($0.role) && (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query)) }
            let grouped = Dictionary(grouping: matched) { formatter.string(from: $0.createdAt) }
            let dates = grouped.keys.sorted()
            return CoveMessageCalendar(month: month, timeZone: timeZone, query: query,
                firstMonth: dates.first.map { String($0.prefix(7)) }, lastMonth: dates.last.map { String($0.prefix(7)) },
                days: dates.filter { $0.hasPrefix(month + "-") }.map { CoveMessageCalendarDay(date: $0, count: grouped[$0]!.count) })
        }
        let stamp = generation
        let result: CoveMessageCalendar = try await request("v1/messages/calendar", query: [
            URLQueryItem(name: "month", value: month), URLQueryItem(name: "timeZone", value: timeZone), URLQueryItem(name: "q", value: query)])
        guard stamp == generation, !previewMode else { throw CancellationError() }
        guard result.month == month, result.timeZone == timeZone, result.query == query else {
            throw CoveError.message("聊天日历响应不匹配，请重试。")
        }
        guard Set(result.days.map(\.date)).count == result.days.count,
              result.days.allSatisfy({ $0.count > 0 && $0.date.hasPrefix(month + "-") && CoveChatCalendarDates.valid($0.date, pattern: "yyyy-MM-dd", timeZone: timeZone) }),
              [result.firstMonth, result.lastMonth].compactMap({ $0 }).allSatisfy({ CoveChatCalendarDates.valid($0, pattern: "yyyy-MM", timeZone: timeZone) }) else {
            throw CoveError.message("聊天日历数据不完整，请重试。")
        }
        return result
    }

    func clearMessageHighlight() { messageHighlight = nil }

    func returnFromMessageSearch() async {
        let destination = currentConversationID ?? searchReturnConversationID ?? activeConversationID
        guard conversations.contains(where: { $0.id == destination }) else {
            errorMessage = "当前聊天尚未同步，请先重新连接。"
            return
        }
        messageHighlight = nil
        scrollRequest = nil
        locateInFlightMessageID = nil
        historyNavigationID = UUID()
        let navigationID = historyNavigationID, stamp = generation
        searchReturnConversationID = nil
        guard activateConversation(destination) else { return }
        // Return to the cached tail immediately; auxiliary session refresh must
        // not hold navigation hostage on a slow/offline connection.
        latestMessageRequest = UUID()
        if !previewMode {
            do { try await pollMessages() }
            catch {
                guard navigationID == historyNavigationID, stamp == generation else { return }
                errorMessage = "已返回本机缓存的当前聊天，最新消息暂未同步：" + readable(error)
            }
            guard navigationID == historyNavigationID, stamp == generation,
                  activeConversationID == destination else { return }
            await refreshSessionContext()
        }
    }

    /// Switch to the result's conversation (drafts stay per-conversation) and reveal
    /// the exact message. Older history is pulled by revision until the message is
    /// found or the server has no more; failure is reported, never faked.
    func locateMessage(conversationID: String, messageID: String, highlightQuery: String = "") async {
        guard !isLocatingMessage else { return }
        historyNavigationID = UUID()
        if previewMode {
            guard conversationID == activeConversationID else { return }
            if messages.contains(where: { $0.id == messageID }) {
                searchReturnConversationID = searchReturnConversationID ?? activeConversationID
                messageHighlight = CoveMessageHighlight(conversationID: conversationID, messageID: messageID, query: highlightQuery)
                scrollRequest = CoveScrollRequest(messageID: messageID)
            }
            return
        }
        guard conversations.contains(where: { $0.id == conversationID }) else {
            errorMessage = "没有找到那条消息所属的对话。"
            return
        }
        let returnConversation = searchReturnConversationID ?? currentConversationID ?? activeConversationID
        searchReturnConversationID = returnConversation
        persist()
        isLocatingMessage = true
        locateInFlightMessageID = messageID
        scrollRequest = nil
        defer {
            isLocatingMessage = false
            // A successful locate keeps the in-flight marker until ChatView has
            // actually scrolled; every failure path clears it here.
            if scrollRequest?.messageID != messageID { locateInFlightMessageID = nil }
        }
        let stamp = generation
        let navigationID = historyNavigationID
        if conversationID != activeConversationID {
            // Preserve the locate marker across the switch; ordinary selection clears search state.
            if activateConversation(conversationID) {
                try? await pollMessages()
                await refreshSessionContext()
            }
        }
        guard stamp == generation, navigationID == historyNavigationID, activeConversationID == conversationID, !previewMode else { return }
        do {
            var after = 0
            var steps = 0
            while !cache.messages.contains(where: { $0.id == messageID && $0.conversationID == conversationID }) {
                let result: PollEnvelope = try await request("v1/messages", query: [
                    URLQueryItem(name: "conversationID", value: conversationID),
                    URLQueryItem(name: "after", value: String(after))
                ])
                guard stamp == generation, navigationID == historyNavigationID, activeConversationID == conversationID, !previewMode else { return }
                if !result.messages.isEmpty { mergeMessages(result.messages) }
                let advanced = max(after, result.cursor)
                steps += 1
                if advanced == after || steps >= 50 { break }
                after = advanced
            }
            guard cache.messages.contains(where: { $0.id == messageID && $0.conversationID == conversationID }) else {
                errorMessage = "没有找到那条消息，可能已被删除。"
                return
            }
            searchReturnConversationID = returnConversation
            messageHighlight = CoveMessageHighlight(conversationID: conversationID, messageID: messageID, query: highlightQuery)
            scrollRequest = CoveScrollRequest(messageID: messageID)
        } catch {
            guard stamp == generation, navigationID == historyNavigationID else { return }
            errorMessage = "还没有定位到那条消息：" + readable(error)
        }
    }

    func completeScrollRequest(_ request: CoveScrollRequest) {
        if scrollRequest?.id == request.id {
            locateInFlightMessageID = nil
            scrollRequest = nil
        }
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

    private func resetStandingHealthAccess() {
        healthAccessRevision = UUID()
        personalLedgerSyncTask?.cancel()
        personalLedgerSyncedSnapshot = nil
        personalLedgerLastSyncedAt = nil
        personalLedgerVerifiedAt = nil
        personalLedgerSyncRequested = true
        personalLedgerRetryAfter = .distantPast
        personalLedgerFailures = 0
        personalLedgerCommandsCheckedAt = .distantPast
        personalLedgerSyncStatus = "Assistant 账本读取尚未同步"
        healthReader.stopObserving()
        healthChangeTask?.cancel()
        healthChangeTask = nil
        healthSharingEnabled = false
        healthDataAccessKnown = false
        healthUploadsPaused = false
        automaticHealthTask?.cancel()
        automaticHealthTask = nil
        automaticHealthTaskID = UUID()
        healthHasPendingChange = false
        healthDataAccessStatus = "尚未读取持续授权状态"
    }

    func refreshHealthDataAccess() async {
        guard !previewMode, isConnected, !isUpdatingHealthDataAccess else { return }
        let stamp = generation, revision = healthAccessRevision
        do {
            let result: DataAccessEnvelope = try await request("v1/data-access")
            guard stamp == generation, revision == healthAccessRevision, !previewMode else { return }
            applyHealthDataAccess(result.enabled)
        } catch {
            guard stamp == generation, revision == healthAccessRevision, !previewMode else { return }
            healthDataAccessKnown = false
            healthReader.stopObserving()
            healthDataAccessStatus = "持续授权状态未能刷新：\(readable(error))"
        }
    }

    private func applyHealthDataAccess(_ enabled: Bool) {
        if enabled != healthSharingEnabled { healthAccessRevision = UUID() }
        healthSharingEnabled = enabled
        healthDataAccessKnown = true
        if !enabled { healthReader.stopObserving(); healthChangeTask?.cancel() }
        healthDataAccessStatus = enabled
            ? "已持续授权 Assistant 读取；跨对话有效，不再逐次询问。"
            : "持续读取已关闭；仍可单独回应对话里的健康请求。"
        if !enabled {
            personalLedgerSyncTask?.cancel()
            personalLedgerSyncedSnapshot = nil
            personalLedgerVerifiedAt = nil
            personalLedgerSyncStatus = "账本同步已关闭 · 本机记录保留" + personalLedgerLastSyncLabel
        } else {
            schedulePersonalLedgerSync()
        }
        if enabled && healthUploadsPaused {
            healthDataAccessStatus = "服务器仍显示已授权，本机上传已暂停。上次关闭未确认，请重试关闭。"
        }
    }

    func setHealthDataAccess(enabled: Bool) async {
        guard !previewMode, isConnected, !isUpdatingHealthDataAccess else { return }
        isUpdatingHealthDataAccess = true
        healthAccessRevision = UUID()
        let stamp = generation, revision = healthAccessRevision
        if !enabled {
            healthUploadsPaused = true
            personalLedgerSyncTask?.cancel()
            personalLedgerSyncStatus = "本机已暂停账本同步，正在关闭授权" + personalLedgerLastSyncLabel
            healthReader.stopObserving()
            healthChangeTask?.cancel()
        }
        defer { isUpdatingHealthDataAccess = false }
        do {
            let result: DataAccessEnvelope = try await request("v1/data-access", method: "POST", body: ["enabled": enabled])
            guard stamp == generation, revision == healthAccessRevision, !previewMode else { return }
            guard result.enabled == enabled else { throw CoveError.message("服务器返回的授权状态与设置不一致。") }
            healthUploadsPaused = false
            applyHealthDataAccess(result.enabled)
            if enabled {
                await syncStandingHealthIfNeeded()
                await refreshHealthRequests()
            }
        } catch {
            guard stamp == generation, !previewMode else { return }
            healthDataAccessStatus = enabled
                ? "持续授权未确认：\(readable(error))"
                : "关闭未确认，本机已暂停上传；服务器可能仍可读取既有副本。请重试。\(readable(error))"
        }
    }

    private var personalLedgerLastSyncLabel: String {
        personalLedgerLastSyncedAt.map {
            " · 上次成功 \($0.formatted(date: .abbreviated, time: .standard))"
        } ?? " · 尚未成功同步"
    }

    private func requirePersonalLedgerAccess(stamp: UUID, revision: UUID) throws {
        guard !isUpdatingHealthDataAccess, standingHealthAllowed(stamp: stamp, revision: revision) else {
            throw CancellationError()
        }
    }

    /// Store-owned foreground worker, independent of the Home view. The durable local
    /// archive is the outbox: relaunch/connection recovery always re-reads it, never a stale UI snapshot.
    private func schedulePersonalLedgerSync() {
        guard !previewMode, healthForegroundActive, isConnected, !healthUploadsPaused,
              !isUpdatingHealthDataAccess, personalLedgerSyncTask == nil,
              Date() >= personalLedgerRetryAfter else { return }
        guard !healthDataAccessKnown || healthSharingEnabled else { return }
        if !personalLedgerSyncRequested, let verified = personalLedgerVerifiedAt,
           Date().timeIntervalSince(verified) < 30,
           Date().timeIntervalSince(personalLedgerCommandsCheckedAt) < 6 { return }
        let stamp = generation
        personalLedgerSyncTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.personalLedgerSyncTask = nil
                if self.personalLedgerSyncRequested { self.schedulePersonalLedgerSync() }
            }
            guard stamp == self.generation, !Task.isCancelled else { return }
            if self.personalLedgerLastSyncedAt == nil {
                self.personalLedgerLastSyncedAt = self.healthRefreshDefaults.object(
                    forKey: "cove.personalLedger.lastSync." + self.healthServiceID) as? Date
            }
            if !self.healthDataAccessKnown { await self.refreshHealthDataAccess() }
            let revision = self.healthAccessRevision
            guard self.healthDataAccessKnown, self.healthSharingEnabled,
                  self.standingHealthAllowed(stamp: stamp, revision: revision) else {
                self.personalLedgerRetryAfter = Date().addingTimeInterval(5)
                return
            }
            self.personalLedgerSyncRequested = false
            do {
                try await self.syncPersonalLedger(stamp: stamp, revision: revision)
                if Date().timeIntervalSince(self.personalLedgerCommandsCheckedAt) >= 6 {
                    try await self.refreshPersonalLedgerCommands(stamp: stamp, revision: revision)
                    self.personalLedgerCommandsCheckedAt = Date()
                }
                try await self.syncPersonalLedger(stamp: stamp, revision: revision)
                try self.requirePersonalLedgerAccess(stamp: stamp, revision: revision)
                self.personalLedgerFailures = 0
                self.personalLedgerRetryAfter = .distantPast
                self.personalLedgerSyncStatus = "账本已同步给 Assistant" + self.personalLedgerLastSyncLabel
            } catch {
                guard stamp == self.generation, revision == self.healthAccessRevision,
                      !Task.isCancelled, !self.previewMode else { return }
                let delays: [TimeInterval] = [2, 5, 15, 30]
                let delay = delays[min(self.personalLedgerFailures, delays.count - 1)]
                self.personalLedgerFailures = min(self.personalLedgerFailures + 1, delays.count - 1)
                self.personalLedgerRetryAfter = Date().addingTimeInterval(delay)
                self.personalLedgerSyncRequested = true
                self.personalLedgerSyncStatus = "本机记录保留；同步未完成，前台将在 \(Int(delay)) 秒后自动重试：\(self.readable(error))"
                    + self.personalLedgerLastSyncLabel
            }
        }
    }

    private func syncPersonalLedger(stamp: UUID, revision: UUID) async throws {
        let repository = CoveLedgerRepository()
        while true {
            try requirePersonalLedgerAccess(stamp: stamp, revision: revision)
            let snapshot = try repository.load()
            if snapshot == personalLedgerSyncedSnapshot,
               let verified = personalLedgerVerifiedAt, Date().timeIntervalSince(verified) < 30 { return }
            personalLedgerSyncStatus = "正在同步账本，本机记录已保存" + personalLedgerLastSyncLabel
            let encoder = CoveJSON.encoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(snapshot)
            // Match the actual wire precision; do not compare Swift/Python JSON byte hashes.
            let wireSnapshot = try CoveJSON.decoder().decode(CoveLedgerSnapshot.self, from: data)
            let archive = try JSONSerialization.jsonObject(with: data)
            let remote: PersonalLedgerReadEnvelope = try await request("v1/personal-ledger")
            try requirePersonalLedgerAccess(stamp: stamp, revision: revision)
            // A save during GET is coalesced, not discarded or replaced by the old UI copy.
            guard try repository.load() == snapshot else { continue }
            let receipt: PersonalLedgerSyncEnvelope
            if let latest = remote.latest, latest.snapshot == wireSnapshot {
                receipt = latest // Recovers a lost POST ACK without a duplicate upload revision.
            } else {
                if let old = remote.latest?.snapshot {
                    guard Set(old.events.map(\.id)).isSubset(of: Set(snapshot.events.map(\.id))),
                          Set(old.statements.map(\.id)).isSubset(of: Set(snapshot.statements.map(\.id))),
                          Set(old.installments.map(\.id)).isSubset(of: Set(snapshot.installments.map(\.id))),
                          Set(old.reconciliations.map(\.id)).isSubset(of: Set(snapshot.reconciliations.map(\.id))) else {
                        throw CoveError.message("服务器含有本机尚未恢复的记录，未用旧副本覆盖。")
                    }
                }
                let (next, overflow) = (remote.latest?.revision ?? 0).addingReportingOverflow(1)
                guard !overflow else { throw CoveLedgerError.overflow }
                receipt = try await request("v1/personal-ledger", method: "POST",
                    body: ["revision": next, "snapshot": archive])
                try requirePersonalLedgerAccess(stamp: stamp, revision: revision)
                guard receipt.revision == next, receipt.snapshot == wireSnapshot else {
                    throw CoveError.message("账本同步回执内容不匹配，保留本机数据等待重试。")
                }
            }
            personalLedgerSyncedSnapshot = snapshot
            personalLedgerVerifiedAt = Date()
            personalLedgerLastSyncedAt = receipt.syncedAt
            healthRefreshDefaults.set(receipt.syncedAt, forKey: "cove.personalLedger.lastSync." + healthServiceID)
            // Re-read after POST too: edits made during upload get their own next upload.
            if try repository.load() == snapshot { return }
        }
    }

    private func refreshPersonalLedgerCommands(stamp: UUID, revision: UUID) async throws {
        try requirePersonalLedgerAccess(stamp: stamp, revision: revision)
        let envelope: PersonalLedgerCommandsEnvelope = try await request("v1/personal-ledger/commands")
        try requirePersonalLedgerAccess(stamp: stamp, revision: revision)
        let repository = CoveLedgerRepository()
        let journal = CoveLedgerRepository.liveDirectory.appendingPathComponent("command-receipts-" + healthServiceID + ".json")
        var receipts: [String: PersonalLedgerCommandReceipt]
        do { receipts = try JSONDecoder().decode([String: PersonalLedgerCommandReceipt].self, from: Data(contentsOf: journal)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { receipts = [:] }
        for command in envelope.commands where command.status == "pending" {
            try requirePersonalLedgerAccess(stamp: stamp, revision: revision)
            let key = command.id.uuidString
            let receipt: PersonalLedgerCommandReceipt
            if let saved = receipts[key] {
                guard saved.recordID == command.recordID else { throw CoveLedgerError.operationConflict }
                receipt = saved
            } else {
                do {
                    // Repeated delivery recovers the identical append-only record by recordID.
                    try applyPersonalLedgerCommand(command, repository: repository)
                    receipt = .init(recordID: command.recordID, status: "applied", error: nil)
                } catch let error as CoveLedgerError where error != .invalidArchive && error != .unsupportedSchema {
                    receipt = .init(recordID: command.recordID, status: "failed", error: error.localizedDescription)
                }
                // IO/protection/uncertain commit failures are NOT definitive failed ACKs.
                receipts[key] = receipt
                try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(receipts).write(to: journal, options: [.atomic, .completeFileProtection])
            }
            try await syncPersonalLedger(stamp: stamp, revision: revision)
            try requirePersonalLedgerAccess(stamp: stamp, revision: revision)
            var body: [String: Any] = ["status": receipt.status]
            if let error = receipt.error { body["error"] = error }
            let result: PersonalLedgerCommandEnvelope = try await request(
                "v1/personal-ledger/commands/\(command.id.uuidString.lowercased())/ack", method: "POST", body: body)
            try requirePersonalLedgerAccess(stamp: stamp, revision: revision)
            guard result.command.id == command.id, result.command.recordID == command.recordID,
                  result.command.status == receipt.status else { throw CoveLedgerError.operationConflict }
        }
    }

    private func applyPersonalLedgerCommand(_ command: PersonalLedgerCommand,
                                            repository: CoveLedgerRepository) throws {
        let action = command.action
        switch action.action {
        case .expense, .income:
            guard let accountID = action.accountID, let categoryID = action.categoryID,
                  let amount = action.amountFen, let occurredAt = action.occurredAt else {
                throw CoveLedgerError.invalidArchive
            }
            let kind: CoveLedgerKind = action.action == .expense ? .expense : .income
            let transaction = CoveLedgerTransaction(kind: kind, amountFen: amount, accountID: accountID,
                destinationAccountID: nil, categoryID: categoryID, note: action.note ?? "", occurredAt: occurredAt)
            _ = try repository.append(.init(id: command.recordID, transaction: transaction,
                                             reversesID: nil, reason: "", createdAt: command.createdAt))
        case .statement, .correctStatement:
            guard let accountID = action.accountID, let statementDate = action.statementDate,
                  let dueDate = action.dueDate, let amount = action.amountFen else {
                throw CoveLedgerError.invalidArchive
            }
            _ = try repository.appendStatement(.init(id: command.recordID, accountID: accountID,
                statementDate: statementDate, dueDate: dueDate, amountFen: amount,
                minimumDueFen: action.minimumDueFen, createdAt: command.createdAt,
                supersedesID: action.action == .correctStatement ? action.targetID : nil))
        case .installment, .updateInstallment:
            guard let accountID = action.accountID, let periods = action.remainingPeriods,
                  let principal = action.nextPrincipalFen, let interest = action.nextInterestFen,
                  let dueDate = action.nextDueDate, let repeats = action.amountsRepeat else {
                throw CoveLedgerError.invalidArchive
            }
            let history = try repository.load().installments
            let old = action.targetID.flatMap { id in history.first(where: { $0.id == id }) }
            _ = try repository.appendInstallment(.init(id: command.recordID, planID: old?.planID,
                accountID: accountID, label: action.label, remainingPeriods: periods,
                remainingPrincipalFen: action.remainingPrincipalFen, nextPrincipalFen: principal,
                nextInterestFen: interest, nextDueDate: dueDate, amountsRepeat: repeats,
                supersedesID: action.action == .updateInstallment ? action.targetID : nil,
                createdAt: command.createdAt))
        case .closeInstallment:
            guard let targetID = action.targetID,
                  let old = try repository.load().installments.first(where: { $0.id == targetID }) else {
                throw CoveLedgerError.invalidInstallment
            }
            _ = try repository.appendInstallment(old.closing(id: command.recordID, createdAt: command.createdAt))
        case .reconciliation:
            guard let accountID = action.accountID, let balance = action.balanceFen,
                  let capturedAt = action.capturedAt else { throw CoveLedgerError.invalidArchive }
            _ = try repository.appendReconciliation(.init(id: command.recordID, accountID: accountID,
                balanceFen: balance, capturedAt: capturedAt, createdAt: command.createdAt))
        case .repayment:
            guard let accountID = action.accountID, let destination = action.destinationAccountID,
                  let statementID = action.statementID, let amount = action.amountFen,
                  let occurredAt = action.occurredAt else { throw CoveLedgerError.invalidArchive }
            let transaction = CoveLedgerTransaction(kind: .transfer, amountFen: amount,
                accountID: accountID, destinationAccountID: destination, categoryID: nil,
                note: action.note ?? "", occurredAt: occurredAt, statementID: statementID)
            _ = try repository.append(.init(id: command.recordID, transaction: transaction,
                                             reversesID: nil, reason: "", createdAt: command.createdAt))
        case .voidTransaction:
            guard let targetID = action.targetID, let reason = action.reason else {
                throw CoveLedgerError.invalidArchive
            }
            _ = try repository.append(.init(id: command.recordID, transaction: nil,
                                             reversesID: targetID, reason: reason,
                                             createdAt: command.createdAt))
        }
    }

    private func personalLedgerPayload(snapshot: CoveLedgerSnapshot, archive: Any, digest: String) throws -> [String: Any] {
        let asOf = Date(), calendar = Calendar.current
        let overview = try snapshot.financeOverview(asOf: asOf, calendar: calendar)
        let month = try snapshot.summary(containing: asOf, calendar: calendar)
        func knownTotal(_ value: CoveLedgerKnownTotal) -> [String: Any] {
            var result: [String: Any] = [
                "knownSubtotalFen": value.knownSubtotalFen,
                "unknownAccountCount": value.unknownAccountCount,
                "accountCount": value.accountCount
            ]
            if let total = value.totalFen { result["totalFen"] = total }
            return result
        }
        func installmentTotal(_ value: CoveLedgerInstallmentTotal) -> [String: Any] {
            var result: [String: Any] = [
                "knownSubtotalFen": value.knownSubtotalFen,
                "unknownPlanCount": value.unknownPlanCount
            ]
            if let total = value.totalFen { result["totalFen"] = total }
            return result
        }
        let accounts: [[String: Any]] = snapshot.accounts.map { account in
            var value: [String: Any] = ["id": account.id.uuidString, "name": account.name,
                                        "type": account.type.rawValue, "balanceKnown": overview.balances[account.id] != nil]
            if let balance = overview.balances[account.id] { value["balanceFen"] = balance }
            return value
        }
        let statements: [[String: Any]] = overview.statements.map { item in
            ["id": item.statement.id.uuidString,
             "accountID": item.statement.accountID.uuidString,
             "accountName": snapshot.accountName(item.statement.accountID),
             "statementDate": item.statement.statementDate.ISO8601Format(),
             "dueDate": item.statement.dueDate.ISO8601Format(),
             "amountFen": item.statement.amountFen,
             "paidFen": item.paidFen,
             "remainingFen": item.remainingFen,
             "status": item.status.rawValue]
        }
        let installments: [[String: Any]] = try overview.installments.plans.map { plan in
            var value: [String: Any] = [
                "id": plan.id.uuidString, "planID": plan.planID.uuidString,
                "accountID": plan.accountID.uuidString, "accountName": snapshot.accountName(plan.accountID),
                "remainingPeriods": plan.remainingPeriods, "nextPrincipalFen": plan.nextPrincipalFen,
                "nextInterestFen": plan.nextInterestFen, "nextTotalFen": try plan.nextTotalFen(),
                "nextDueDate": plan.nextDueDate.ISO8601Format(), "amountsRepeat": plan.amountsRepeat
            ]
            if let label = plan.label { value["label"] = label }
            if let principal = plan.remainingPrincipalFen { value["remainingPrincipalFen"] = principal }
            if let projected = try plan.projectedTotalFen() { value["projectedTotalFen"] = projected }
            return value
        }
        let knownDebt = try CoveLedgerMoney.add(overview.recordedOutstandingFen,
                                                 overview.installments.projection.knownSubtotalFen)
        var current: [String: Any] = [
            "asOf": asOf.ISO8601Format(), "timeZone": calendar.timeZone.identifier,
            "accounts": accounts, "liquid": knownTotal(overview.liquid),
            "observedCardDebt": knownTotal(overview.cardDebt),
            "unclassifiedAccountCount": overview.unclassifiedAccountCount,
            "statements": statements, "recordedStatementOutstandingFen": overview.recordedOutstandingFen,
            "installments": installments, "nextInstallmentsFen": overview.installments.nextTotalFen,
            "remainingInstallmentPrincipal": installmentTotal(overview.installments.remainingPrincipal),
            "installmentProjection": installmentTotal(overview.installments.projection),
            "recordedDebtKnownFen": knownDebt,
            "recordedDebtHasUnknownFutureInterest": overview.installments.projection.unknownPlanCount > 0,
            "month": ["start": month.month.start.ISO8601Format(),
                      "calendar": month.month.calendarIdentifier,
                      "incomeFen": month.incomeFen, "expenseFen": month.expenseFen]
        ]
        if let after = overview.liquidAfterRecordedDuesFen { current["liquidAfterRecordedStatementsFen"] = after }
        if let budget = month.budgetFen { current["monthlyBudgetFen"] = budget }
        return ["formatVersion": 1, "generatedAt": asOf.ISO8601Format(),
                "timeZone": calendar.timeZone.identifier, "archiveDigest": digest,
                "archive": archive, "current": current]
    }

    private func standingHealthAllowed(stamp: UUID, revision: UUID) -> Bool {
        !Task.isCancelled && !previewMode && healthForegroundActive && isConnected && stamp == generation && revision == healthAccessRevision &&
            healthSharingEnabled && healthDataAccessKnown && !healthUploadsPaused
    }

    private func observeStandingHealth() {
        guard healthSharingEnabled, healthDataAccessKnown, healthForegroundActive, !healthUploadsPaused, !previewMode else { return }
        healthReader.startObserving(metrics: CoveHealthRefreshPolicy.metricIDs) { [weak self] in
            guard let self else { return }
            self.healthHasPendingChange = true
            self.healthChangeTask?.cancel()
            self.healthChangeTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                await self.refreshHealthDataAccess()
                await self.syncStandingHealthIfNeeded()
            }
        }
    }

    private func scheduleStandingHealthSync() {
        guard automaticHealthTask == nil, !previewMode else { return }
        let taskID = UUID(), stamp = generation
        automaticHealthTaskID = taskID
        automaticHealthTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.automaticHealthTaskID == taskID { self.automaticHealthTask = nil } }
            guard !Task.isCancelled, self.generation == stamp else { return }
            await self.syncStandingHealthIfNeeded()
        }
    }

    private func syncStandingHealthIfNeeded() async {
        guard !isSyncingHealth, standingHealthAllowed(stamp: generation, revision: healthAccessRevision) else { return }
        observeStandingHealth()
        await flushPendingStandingHealthIfPossible()
        guard !isSyncingHealth, standingHealthAllowed(stamp: generation, revision: healthAccessRevision) else { return }
        let key = "cove.healthRefresh.v1." + healthServiceID
        let policy = healthRefreshDefaults.data(forKey: key).flatMap {
            try? JSONDecoder().decode(CoveHealthRefreshPolicy.self, from: $0)
        } ?? CoveHealthRefreshPolicy()
        guard let next = policy.recordingAttempt(now: Date(), changed: healthHasPendingChange) else { return }
        do {
            // Persist before awaiting HealthKit: reconnects/relaunches and
            // observer bursts must not bypass the daily attempt budget.
            healthRefreshDefaults.set(try JSONEncoder().encode(next), forKey: key)
        } catch {
            healthSyncStatus = "自动读取次数未能保存，本次未读取。"
            return
        }
        healthHasPendingChange = false
        await readHealth(metrics: CoveHealthRefreshPolicy.metricIDs, automatic: true)
    }

    /// Manual reads remain local with sharing off; an existing service grant is sufficient
    /// for foreground reads and uploads, without creating another consent card or chat turn.
    func syncHealth() async {
        await readHealth(metrics: CoveHealthScope.metricIDs, automatic: false)
    }

    private func readHealth(metrics: Set<String>, automatic: Bool) async {
        guard !previewMode, !isSyncingHealth else { return }
        isSyncingHealth = true
        let stamp = generation, revision = healthAccessRevision
        let share = standingHealthAllowed(stamp: stamp, revision: revision)
        defer { isSyncingHealth = false }
        do {
            try await healthReader.authorize(metrics: metrics)
            guard !previewMode, stamp == generation else { return }
            if share && !standingHealthAllowed(stamp: stamp, revision: revision) { return }
            let snapshot = try await healthReader.snapshot(metrics: metrics, startAt: nil, endAt: Date())
            guard !previewMode, stamp == generation else { return }
            if share && !standingHealthAllowed(stamp: stamp, revision: revision) { return }
            appendHealthArchive(.init(snapshot: snapshot, origin: share ? .standing : .manual))
            healthSyncStatus = snapshot.metrics.isEmpty
                ? "暂无可读取数据：可能没有记录，也可能未授权；缺项保持未知。"
                : "已在本机读取，未上传。"
            if share {
                try await uploadStandingHealthArchive(stamp: stamp, revision: revision)
                guard standingHealthAllowed(stamp: stamp, revision: revision) else { return }
                healthSyncStatus = snapshot.metrics.isEmpty
                    ? "已同步可用状态；当前没有可读取样本，不代表各项为零。"
                    : (automatic ? "已同步睡眠、静息心率、HRV、步数与血氧；每天自动最多两次，不是实时测量。" : "本次按需读取已同步给 Assistant；不是实时测量。")
                observeStandingHealth()
            }
        } catch {
            if stamp == generation, !previewMode { healthSyncStatus = readable(error) }
        }
    }

    private func uploadStandingHealthArchive(stamp: UUID, revision: UUID) async throws {
        let serviceID = healthServiceID
        // Stable capturedAt and snapshot body make retries idempotent on the service.
        // An existing archive is real device data, not a new reading or a chat message.
        let entries = healthArchiveEntries.sorted { $0.snapshot.capturedAt > $1.snapshot.capturedAt }
        for entry in entries {
            guard standingHealthAllowed(stamp: stamp, revision: revision) else { return }
            var snapshot = entry.snapshot
            if entry.origin == .request {
                let scope: String
                if let start = entry.requestStartAt, let end = entry.requestEndAt {
                    scope = "原健康请求范围：\(start.ISO8601Format()) 至 \(end.ISO8601Format())；累计值仅表示该时段。"
                } else {
                    scope = "原健康请求摘要；请求起止时间未保存在本机，累计值不能按今日解读。"
                }
                for index in snapshot.metrics.indices {
                    snapshot.metrics[index].detail = scope
                }
            }
            let transmittedData = try CoveJSON.encoder().encode(snapshot)
            // Verify the representation that actually crossed the wire. The
            // shared encoder may canonicalize dates (for example to whole UTC
            // seconds); this is not evidence of server-side field loss.
            let transmittedSnapshot = try CoveJSON.decoder().decode(HealthSnapshot.self, from: transmittedData)
            let body = try JSONSerialization.jsonObject(with: transmittedData)
            if let index = healthArchiveEntries.firstIndex(where: { $0.id == entry.id }) {
                healthArchiveEntries[index].serviceID = serviceID
                healthArchiveEntries[index].sharingState = .deliveryUnknown
                saveLocalHealthHistory()
            }
            var postError: Error?
            do {
                let result: SyncEnvelope = try await request("v1/health", method: "POST", body: ["snapshot": body, "standingAccess": true])
                guard result.ok else { throw CoveError.message("健康记录尚未确认接收。") }
                guard standingHealthAllowed(stamp: stamp, revision: revision) else { return }
                healthSyncedAt = result.syncedAt
            } catch {
                postError = error
            }
            guard standingHealthAllowed(stamp: stamp, revision: revision) else { return }
            do {
                let confirmed: HealthUploadEnvelope = try await request("v1/health/uploads", query: [
                    URLQueryItem(name: "capturedAt", value: Self.healthUploadTimestamp(transmittedSnapshot.capturedAt))
                ])
                guard standingHealthAllowed(stamp: stamp, revision: revision) else { return }
                guard CoveHealthSnapshotVerification.matches(transmittedSnapshot, confirmed.snapshot) else {
                    throw CoveError.message("服务器回读与本机健康记录不一致，已保留本机副本。")
                }
                try removeConfirmedLocalHealthEntry(entry.id)
                healthSyncedAt = confirmed.syncedAt
            } catch {
                if let postError { throw postError }
                throw error
            }
        }
    }

    private func flushPendingStandingHealthIfPossible() async {
        let stamp = generation, revision = healthAccessRevision
        guard !healthArchiveEntries.isEmpty, !isSyncingHealth,
              standingHealthAllowed(stamp: stamp, revision: revision) else { return }
        isSyncingHealth = true
        defer { isSyncingHealth = false }
        do { try await uploadStandingHealthArchive(stamp: stamp, revision: revision) }
        catch {
            if stamp == generation, !previewMode { healthSyncStatus = readable(error) }
        }
    }

    private func removeConfirmedLocalHealthEntry(_ id: UUID) throws {
        guard healthArchiveLoaded, healthArchiveEntries.contains(where: { $0.id == id }) else { return }
        let retained = healthArchiveEntries.filter { $0.id != id }
        try healthArchive.save(retained)
        healthArchiveEntries = retained
        healthArchiveHasUnsavedChanges = false
        healthArchiveError = nil
        updateLocalHealthPresentation()
    }

    private static func healthUploadTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000))
    }

    private var healthServiceID: String {
        SHA256.hash(data: Data((cacheEndpoint + "\n" + connectedToken).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func restoreLocalHealthHistory() {
        guard !previewMode else { return }
        do {
            healthArchiveEntries = try healthArchive.load()
            healthArchiveLoaded = true
            healthArchiveHasUnsavedChanges = false
            healthArchiveError = nil
            updateLocalHealthPresentation()
            healthSyncStatus = health == nil ? "尚未在本机读取" : "已恢复本机保存的读取记录；没有重新读取或上传。"
        } catch {
            healthArchiveLoaded = false
            healthArchiveError = "本机健康历史未能读取，原文件未覆盖：\(readable(error))"
        }
    }

    private func updateLocalHealthPresentation() {
        healthArchiveEntries.sort { $0.recordedAt > $1.recordedAt }
        healthHistory = healthArchiveEntries.map(\.snapshot)
        health = healthArchiveEntries.first?.snapshot
    }

    private func saveLocalHealthHistory() {
        guard !previewMode else { return }
        healthArchiveHasUnsavedChanges = true
        guard healthArchiveLoaded else { return }
        do {
            try healthArchive.save(healthArchiveEntries)
            healthArchiveHasUnsavedChanges = false
            healthArchiveError = nil
        }
        catch { healthArchiveError = "本次读取尚未保存到本机，请暂时保留 App：\(readable(error))" }
    }

    private func appendHealthArchive(_ entry: CoveHealthArchiveEntry) {
        guard !previewMode else { return }
        // Keep each intentional read, even when its values are unchanged.
        healthArchiveEntries.insert(entry, at: 0)
        updateLocalHealthPresentation()
        saveLocalHealthHistory()
    }

    /// UI must confirm this separately from deleting the service-side copies.
    @discardableResult func clearLocalHealthHistory() -> Bool {
        guard !previewMode, !isSyncingHealth, respondingHealthRequestIDs.isEmpty else { return false }
        do {
            try healthArchive.save([])
            healthArchiveLoaded = true
            healthArchiveHasUnsavedChanges = false
            healthArchiveEntries = []; healthHistory = []; health = nil
            healthArchiveError = nil
            healthSyncStatus = "已清除 Cove 本机健康历史；Apple 健康和已分享的服务端副本未改动。"
            return true
        } catch {
            healthArchiveError = "本机历史未清除：\(readable(error))"
            return false
        }
    }

    var collarScopeID: String { generation.uuidString + ":" + activeConversationID + ":" + collarPermissionRevision.uuidString }

    func loadCollarPermissions() async throws -> CoveCollarPermissions {
        try await collarPermissionsRequest()
    }

    func saveCollarPermissions(readSummary: Bool, requestMeasurement: Bool) async throws -> CoveCollarPermissions {
        try await collarPermissionsRequest(body: ["readSummary": readSummary, "requestMeasurement": requestMeasurement])
    }

    private func collarPermissionsRequest(body: [String: Any]? = nil) async throws -> CoveCollarPermissions {
        guard !previewMode, isConnected, connectedURL != nil, !activeConversationID.isEmpty else {
            throw CoveError.message("先连接 Cove 并选择对话；预览模式不会读写权限。")
        }
        let stamp = generation
        let conversation = activeConversationID
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
        guard conversation.count <= 160, conversation.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw CoveError.message("对话标识无效。")
        }
        let value: CoveCollarPermissions = try await request("v1/conversations/\(conversation)/collar", method: body == nil ? "GET" : "POST", body: body)
        guard stamp == generation, conversation == activeConversationID, value.conversationID == conversation, !previewMode, isConnected else {
            throw CoveError.message("连接或对话已变化，请重新确认 Collar 权限。")
        }
        return value
    }

    func refreshHealthRequests(automaticallyRespond: Bool = true) async {
        guard !previewMode, connectedURL != nil, !activeConversationID.isEmpty else { return }
        let conversationID = activeConversationID
        let stamp = generation
        do {
            let result: HealthRequestsEnvelope = try await request("v1/conversations/\(conversationID)/health-requests")
            guard stamp == generation, conversationID == activeConversationID, !previewMode else { return }
            healthRequests = result.requests.filter { $0.conversationID == conversationID }
            // GET status cannot identify the accepted snapshot: another device
            // may have answered this request. Unknown local attempts stay unknown.
            healthRequestsStatus = ""
            if automaticallyRespond, healthSharingEnabled, healthDataAccessKnown,
               let pending = healthRequests.reversed().first(where: {
                   $0.canRespond(conversationID: conversationID)
                   && !respondingHealthRequestIDs.contains($0.id)
                   && healthRequestErrors[$0.id] == nil
               }) {
                await respondToHealthRequest(pending, allow: true, automatic: true)
            }
        } catch {
            guard stamp == generation, conversationID == activeConversationID else { return }
            healthRequestsStatus = "健康请求暂不可用；服务可能尚未升级或连接中断。"
        }
    }

    func cancelHealthRequestRead(_ id: String) {
        guard readingHealthRequestIDs.contains(id) else { return }
        cancelledHealthRequestIDs.insert(id)
    }

    func respondToHealthRequest(_ item: CoveHealthRequest, allow: Bool, automatic: Bool = false) async {
        guard !previewMode, isConnected, item.canRespond(conversationID: activeConversationID),
              healthRequests.first(where: { $0.id == item.id })?.canRespond(conversationID: activeConversationID) == true,
              !respondingHealthRequestIDs.contains(item.id) else { return }
        let stamp = generation
        let serviceID = healthServiceID
        var archiveID: UUID?
        respondingHealthRequestIDs.insert(item.id)
        cancelledHealthRequestIDs.remove(item.id)
        healthRequestErrors[item.id] = nil
        defer {
            respondingHealthRequestIDs.remove(item.id)
            readingHealthRequestIDs.remove(item.id)
            cancelledHealthRequestIDs.remove(item.id)
        }
        do {
            var body: [String: Any] = ["decision": allow ? "allow" : "deny"]
            if allow {
                readingHealthRequestIDs.insert(item.id)
                // Under standing access this is an automatic scoped refresh; otherwise
                // the explicit card action is one-time consent. HealthKit is the OS gate.
                try await healthReader.authorize(metrics: Set(item.metrics))
                guard stamp == generation, !previewMode, isConnected,
                      !cancelledHealthRequestIDs.contains(item.id),
                      item.canRespond(conversationID: activeConversationID),
                      healthRequests.first(where: { $0.id == item.id })?.canRespond(conversationID: activeConversationID) == true else {
                    throw CoveError.message("授权期间会话或请求状态已变化；未开始读取，请重新确认。")
                }
                var snapshot = try await healthReader.snapshot(metrics: Set(item.metrics), startAt: item.startAt, endAt: item.endAt)
                for index in snapshot.metrics.indices {
                    snapshot.metrics[index].detail = nil
                    if let source = snapshot.metrics[index].source {
                        snapshot.metrics[index].source = String(String.UnicodeScalarView(source.unicodeScalars.filter { $0.value >= 32 })).prefix(120).description
                    }
                }
                guard item.permits(snapshot) else { throw CoveError.message("读取结果超出请求范围，未发送。") }
                if !previewMode {
                    let entry = CoveHealthArchiveEntry(snapshot: snapshot, origin: .request, serviceID: serviceID,
                        conversationID: item.conversationID, requestID: item.id, requestStartAt: item.startAt, requestEndAt: item.endAt)
                    archiveID = entry.id
                    appendHealthArchive(entry)
                }
                body["snapshot"] = try JSONSerialization.jsonObject(with: CoveJSON.encoder().encode(snapshot))
            }
            // The user may switch conversation/account while HealthKit is awaiting authorization.
            guard stamp == generation, !previewMode, isConnected,
                  !cancelledHealthRequestIDs.contains(item.id),
                  item.canRespond(conversationID: activeConversationID),
                  healthRequests.first(where: { $0.id == item.id })?.canRespond(conversationID: activeConversationID) == true else {
                throw CoveError.message("会话已切换、连接中断或请求已过期；未发送，请返回原会话重新确认。")
            }
            readingHealthRequestIDs.remove(item.id)
            if let archiveID, let index = healthArchiveEntries.firstIndex(where: { $0.id == archiveID }) {
                healthArchiveEntries[index].sharingState = .deliveryUnknown
                saveLocalHealthHistory()
            }
            let result: HealthRequestResponse = try await request("v1/conversations/\(item.conversationID)/health-requests/\(item.id)/response", method: "POST", body: body)
            guard result.ok, result.request.id == item.id, result.request.conversationID == item.conversationID,
                  result.request.status == (allow ? "allowed" : "denied") else {
                throw CoveError.message("健康分享确认与请求不匹配。")
            }
            guard stamp == generation, item.conversationID == activeConversationID, !previewMode else { return }
            if allow, let archiveID, let index = healthArchiveEntries.firstIndex(where: { $0.id == archiveID }) {
                // Only this POST's successful, matching ACK confirms this exact
                // locally archived attempt. Polling must never infer delivery.
                healthArchiveEntries[index].sharingState = .shared
                saveLocalHealthHistory()
            }
            if let index = healthRequests.firstIndex(where: { $0.id == item.id }) { healthRequests[index] = result.request }
            await refreshHealthRequests(automaticallyRespond: false)
        } catch {
            if stamp == generation, item.conversationID == activeConversationID {
                healthRequestErrors[item.id] = automatic
                    ? "长期授权下的自动读取结果尚未确认；先刷新核对状态，不盲目重发。\(readable(error))"
                    : "尚未确认处理结果。不会自动重发健康数据；刷新查看状态后再决定。\(readable(error))"
                await refreshHealthRequests(automaticallyRespond: false)
            }
        }
    }

    func deleteSharedHealth() async {
        guard !previewMode else { return }
        guard !isSyncingHealth, respondingHealthRequestIDs.isEmpty else { healthSyncStatus = "当前读取或分享结束后即可删除共享副本。"; return }
        let stamp = generation
        let serviceID = healthServiceID
        healthAccessRevision = UUID()
        healthUploadsPaused = true
        healthReader.stopObserving()
        do {
            let _: OKEnvelope = try await request("v1/health", method: "DELETE")
            guard stamp == generation, !previewMode else { return }
            applyHealthDataAccess(false)
            healthUploadsPaused = false
            healthSyncedAt = nil; healthReadAt = nil
            for index in healthArchiveEntries.indices where healthArchiveEntries[index].serviceID == serviceID {
                if healthArchiveEntries[index].sharingState != .localOnly {
                    healthArchiveEntries[index].sharingState = .removedFromServer
                }
            }
            saveLocalHealthHistory()
            healthRequests = []; healthRequestErrors = [:]
            collarPermissionRevision = UUID()
            healthSyncStatus = "已删除服务端健康副本并撤销 Collar 授权；本机历史、Apple 健康与 Collar 源记录保留。"
        } catch { healthSyncStatus = readable(error) }
    }

    func registerDevice(_ token: String) async {
        guard !previewMode else { return }
        deviceToken = token
        do { try credentials.write(token, account: "device.apns") }
        catch { errorMessage = readable(error) }
        await syncNotificationPreference()
    }

    private func syncNotificationPreference() async {
        notificationPreferenceRevision += 1
        guard !syncingNotificationPreference else { return }
        syncingNotificationPreference = true
        defer { syncingNotificationPreference = false }
        while !previewMode, let token = deviceToken, connectedURL != nil {
            let revision = notificationPreferenceRevision
            let stamp = generation
            let enabled = notificationsEnabled
            let mode = notificationPreviewMode == "content" ? "content" : "generic"
            do {
                let _: OKEnvelope = try await request("v1/devices", method: enabled ? "POST" : "DELETE",
                    body: ["token": token, "previewMode": mode])
                guard stamp == generation else { continue }
                if revision == notificationPreferenceRevision { notificationSyncError = nil; return }
            } catch {
                guard stamp == generation else { continue }
                if revision != notificationPreferenceRevision { continue }
                notificationSyncError = "通知设置未同步，服务器仍可能使用之前的设置。请重新连接后重试。"
                errorMessage = notificationSyncError
                return
            }
        }
    }

    /// One foreground owner retries the handshake as well as subsequent polls.
    /// The caller waits for the first attempt only; transient failures keep retrying
    /// with a capped delay, while authentication/protocol errors require attention.
    private func startPolling() async {
        guard pollTask == nil, healthForegroundActive, !previewMode, connectedURL != nil else { return }
        networkRecoveryMonitor?.start { [weak self] in self?.requestImmediateRecovery() }
        let taskID = UUID(), stamp = generation
        pollTaskID = taskID
        await withCheckedContinuation { firstAttempt in
            pollTask = Task { [weak self] in
                var first: CheckedContinuation<Void, Never>? = firstAttempt
                defer { first?.resume() }
                guard let self else { return }
                defer { if self.pollTaskID == taskID { self.pollTask = nil } }
                var failures = 0, counter = 0
                while self.connectionWorkIsCurrent(stamp: stamp, taskID: taskID) {
                    var delay = self.connectionPollInterval
                    var shouldRetry = true
                    do {
                        if !self.handshakeComplete { try await self.completeHandshake() }
                        try await self.resolveNotificationFocus()
                        try await self.pollMessages()
                        guard self.connectionWorkIsCurrent(stamp: stamp, taskID: taskID) else { break }
                        if !self.isConnected { self.isConnected = true }
                        let status = self.isBusy ? "正在回复…" : "已连接"
                        if self.connectionStatus != status { self.connectionStatus = status }
                        // Do not clear unrelated upload/health errors on every poll.
                        if failures > 0 || counter == 0 { self.errorMessage = nil }
                        failures = 0
                        self.scheduleConnectionExtras(includePanels: counter % 15 == 0,
                                                      includeHealthRequests: counter % 3 == 0)
                        counter += 1
                    } catch {
                        guard self.connectionWorkIsCurrent(stamp: stamp, taskID: taskID) else { break }
                        if self.isConnected { self.isConnected = false }
                        shouldRetry = self.isRetryableConnectionError(error)
                        let status = shouldRetry ? "连接中断，正在重试" : "连接未成功"
                        if self.connectionStatus != status { self.connectionStatus = status }
                        let message = self.readable(error)
                        if self.errorMessage != message { self.errorMessage = message }
                        delay = self.connectionRetryDelays[min(failures, self.connectionRetryDelays.count - 1)]
                        failures = min(failures + 1, self.connectionRetryDelays.count - 1)
                    }
                    first?.resume(); first = nil
                    guard shouldRetry else { break }
                    do { try await Task.sleep(for: .seconds(delay)) } catch { break }
                }
            }
        }
    }

    private func connectionWorkIsCurrent(stamp: UUID, taskID: UUID) -> Bool {
        stamp == generation && taskID == pollTaskID && healthForegroundActive && !previewMode && !Task.isCancelled
    }

    private func isRetryableConnectionError(_ error: Error) -> Bool {
        if let error = error as? URLError {
            return [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                    .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                    .internationalRoamingOff, .dataNotAllowed, .callIsActive].contains(error.code)
        }
        if let error = error as? CoveHTTPError { return error.status == 408 || error.status == 429 || error.status >= 500 }
        return false
    }

    private func completeHandshake() async throws {
        let result: ConversationList = try await request("v1/conversations")
        guard let url = connectedURL else { throw CancellationError() }
        try credentials.write(connectedToken, account: url.absoluteString)
        accessToken = connectedToken
        serverURL = url.absoluteString
        UserDefaults.standard.set(serverURL, forKey: "cove.serverURL")
        mergeConversations(result.conversations)
        currentConversationID = result.activeConversationID
        if activeConversationID.isEmpty { activeConversationID = result.activeConversationID ?? conversations.first?.id ?? "" }
        if activeConversationID.isEmpty { createLocalConversation() }
        if !result.conversations.contains(where: { $0.id == activeConversationID }) {
            // Retry the same local conversation ID if its creation ACK was lost.
            let _: ConversationEnvelope = try await request("v1/conversations", method: "POST", body: ["id": activeConversationID])
        }
        cache.activeConversationID = activeConversationID
        showCurrentMessages()
        persist()
        handshakeComplete = true
        saveSettings()
    }

    private func scheduleConnectionExtras(includePanels: Bool, includeHealthRequests: Bool) {
        guard healthForegroundActive, !previewMode, isConnected else { return }
        schedulePersonalLedgerSync()
        let stamp = generation
        if panelRefreshTask == nil, includePanels {
            panelRefreshTask = Task { [weak self] in
                guard let self else { return }
                defer { self.panelRefreshTask = nil }
                guard stamp == self.generation, !Task.isCancelled else { return }
                await self.refreshPanels()
            }
        }
        if deviceRefreshTask == nil {
            deviceRefreshTask = Task { [weak self] in
                guard let self else { return }
                defer { self.deviceRefreshTask = nil }
                guard stamp == self.generation, !Task.isCancelled else { return }
                await self.refreshDeviceRequests()
                guard stamp == self.generation, self.healthForegroundActive, !Task.isCancelled else { return }
                if self.isSwitchingSession { await self.refreshSessionContext() }
                guard stamp == self.generation, self.healthForegroundActive, !Task.isCancelled else { return }
                if includeHealthRequests { await self.refreshHealthRequests() }
            }
        }
        if outboxTask == nil, !flushing {
            outboxTask = Task { [weak self] in
                guard let self else { return }
                defer { self.outboxTask = nil }
                guard stamp == self.generation, !Task.isCancelled else { return }
                await self.flushOutbox()
            }
        }
    }

    private func pollMessages() async throws {
        guard !activeConversationID.isEmpty else { throw CoveError.message("尚未恢复对话，请重新连接。") }
        let id = activeConversationID, stamp = generation
        // Existing servers return at most 200 revisions, including hidden rows.
        // Drain progress immediately, but bound each pass to avoid monopolizing
        // the connection during a large history catch-up or a streaming reply.
        for _ in 0..<4 {
            let after = cache.cursors[id] ?? 0
            let result: PollEnvelope = try await request("v1/messages", query: [URLQueryItem(name: "conversationID", value: id), URLQueryItem(name: "after", value: String(after))])
            guard stamp == generation, !Task.isCancelled else { throw CancellationError() }
            guard result.cursor >= after, result.messages.allSatisfy({
                $0.conversationID == id && ($0.revision.map { $0 > after && $0 <= result.cursor } ?? true)
            }) else { throw CoveError.message("消息同步回执不匹配，已保留本地消息与同步位置。请重新连接。") }
            if !result.messages.isEmpty { mergeMessages(result.messages) }
            let oldCursor = cache.cursors[id] ?? 0
            cache.cursors[id] = max(oldCursor, result.cursor)
            if id == activeConversationID, isBusy != result.busy { isBusy = result.busy }
            if oldCursor != cache.cursors[id] { persist() }
            if result.cursor == after || id != activeConversationID { break }
        }
    }

    func shellAPI(conversationID: String) -> CoveShellAPI {
        let scope = appActivityScopeID
        func checkScope() throws {
            guard scope == self.appActivityScopeID, !self.previewMode,
                  conversationID == self.activeConversationID else { throw CancellationError() }
        }
        return CoveShellAPI(
            start: { rows, cols in
                try checkScope()
                return try await self.terminalRequest("v1/shell/start", method: "POST", body: ["conversationID": conversationID, "rows": rows, "cols": cols])
            }, poll: { session, after in
                try checkScope()
                return try await self.terminalRequest("v1/shell/events", query: [URLQueryItem(name: "conversationID", value: conversationID),
                    URLQueryItem(name: "sessionID", value: session), URLQueryItem(name: "after", value: String(after))])
            }, write: { session, bytes, close in
                try checkScope()
                let _: OKEnvelope = try await self.terminalRequest("v1/shell/write", method: "POST", body: ["conversationID": conversationID,
                    "sessionID": session, "dataBase64": bytes, "closeStdin": close])
            }, resize: { session, rows, cols in
                try checkScope()
                let _: OKEnvelope = try await self.terminalRequest("v1/shell/resize", method: "POST", body: ["conversationID": conversationID,
                    "sessionID": session, "rows": rows, "cols": cols])
            }, terminate: { session in
                try checkScope()
                let _: OKEnvelope = try await self.terminalRequest("v1/shell/terminate", method: "POST", body: ["conversationID": conversationID, "sessionID": session])
            })
    }

    func tmuxAPI(conversationID: String) -> CoveTmuxAPI {
        let scope = appActivityScopeID
        func checkScope() throws {
            guard scope == self.appActivityScopeID, !self.previewMode,
                  conversationID == self.activeConversationID else { throw CancellationError() }
        }
        return CoveTmuxAPI(attach: {
            try checkScope()
            return try await self.terminalRequest("v1/tmux/attach", method: "POST", body: ["conversationID": conversationID])
        }, capture: { session in
            try checkScope()
            return try await self.terminalRequest("v1/tmux/capture", query: [
                URLQueryItem(name: "conversationID", value: conversationID),
                URLQueryItem(name: "sessionID", value: session)])
        }, input: { session, text, requestID in
            try checkScope()
            let _: OKEnvelope = try await self.terminalRequest("v1/tmux/input", method: "POST", body: [
                "conversationID": conversationID, "sessionID": session,
                "requestID": requestID.uuidString.lowercased(), "text": text])
        }, key: { session, key, requestID in
            try checkScope()
            let _: OKEnvelope = try await self.terminalRequest("v1/tmux/key", method: "POST", body: [
                "conversationID": conversationID, "sessionID": session,
                "requestID": requestID.uuidString.lowercased(), "key": key])
        }, terminate: { session, requestID in
            try checkScope()
            let _: OKEnvelope = try await self.terminalRequest("v1/tmux/terminate", method: "POST", body: [
                "conversationID": conversationID, "sessionID": session,
                "requestID": requestID.uuidString.lowercased()])
        }, recover: { session, requestID in
            try checkScope()
            // This exact new route is scoped here rather than widening the shared
            // terminalRequest allowlist outside tmuxAPI.
            let recovered: CoveTmuxSnapshot = try await self.request("v1/tmux/recover", method: "POST", body: [
                "conversationID": conversationID, "sessionID": session,
                "requestID": requestID.uuidString.lowercased()])
            try checkScope()
            return recovered
        })
    }

    func terminalRequest<T: Decodable>(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> T {
        guard !previewMode else { throw CoveError.message("示例预览不会连接终端。") }
        // All three clients share this transport. Keep exact routes/methods rather
        // than accepting a prefix (or accidentally excluding Shell and voice).
        let allowedMethods = [
            "v1/terminal": "GET", "v1/terminal/models": "GET",
            "v1/terminal/input": "POST", "v1/terminal/model": "POST", "v1/terminal/approval": "POST",
            "v1/shell/start": "POST", "v1/shell/events": "GET", "v1/shell/write": "POST",
            "v1/shell/resize": "POST", "v1/shell/terminate": "POST",
            "v1/tmux/attach": "POST", "v1/tmux/capture": "GET", "v1/tmux/input": "POST",
            "v1/tmux/key": "POST", "v1/tmux/terminate": "POST",
            "v1/realtime/start": "POST", "v1/realtime/events": "GET",
            "v1/realtime/audio": "POST", "v1/realtime/stop": "POST"
        ]
        guard allowedMethods[path] == method else {
            throw CoveError.message("终端接口无效。")
        }
        let stamp = generation
        let result: T = try await request(path, method: method, body: body, query: query)
        guard stamp == generation, !previewMode else { throw CancellationError() }
        return result
    }

    var appActivityScopeID: String { "\(generation)|\(previewMode)|\(isConnected)" }

    // Wallet intents are durable and isolated by the connected service + owner credential.
    // Neither the token nor any wallet control is supplied to the model runtime.
    var walletPendingURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CoveWallet", isDirectory: true)
            .appendingPathComponent(healthServiceID + ".json")
    }

    func loadWallet() async throws -> CoveWalletSnapshot {
        guard !previewMode, isConnected else { throw CoveError.message("请先连接 Cove；预览不读取钱包。") }
        let stamp = generation
        let result: CoveWalletSnapshot = try await request("v1/wallet")
        guard stamp == generation, !previewMode, isConnected else { throw CancellationError() }
        return try result.validated()
    }

    func mutateWallet(_ command: CoveWalletCommand) async throws {
        guard !previewMode, isConnected, ["credit", "request", "review"].contains(command.operation) else {
            throw CoveError.message("钱包当前不可操作。")
        }
        let stamp = generation
        let receipt: CoveWalletReceipt = try await request("v1/wallet/" + command.operation, method: "POST", body: command.body)
        guard stamp == generation, !previewMode, isConnected else { throw CancellationError() }
        guard receipt.id == command.id, receipt.operation == command.operation else { throw CoveWalletError.invalidResponse }
    }

    func loadAppActivity(day: String, timeZone: String) async throws -> CoveAppActivitySummary {
        guard !previewMode, isConnected else { throw CoveError.message("请先连接 Cove；示例预览不读取 App 记录。") }
        guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              TimeZone(identifier: timeZone) != nil else { throw CoveError.message("记录日期或时区无效。") }
        let stamp = generation
        let result: CoveAppActivitySummary = try await request("v1/app-events", query: [
            URLQueryItem(name: "day", value: day), URLQueryItem(name: "timeZone", value: timeZone)
        ])
        guard stamp == generation, !previewMode, isConnected else { throw CancellationError() }
        return try result.validated(day: day, timeZone: timeZone)
    }

    func loadMemoryCalendar(month: String) async throws -> CoveMemoryCalendarEnvelope {
        guard !previewMode else { throw CoveError.message("示例预览不会连接 OB。") }
        guard CoveHomeDates.date(month) != nil else { throw CoveError.message("日历月份无效。") }
        let stamp = generation
        let result: CoveMemoryCalendarEnvelope = try await request("v1/memory/calendar", query: [URLQueryItem(name: "month", value: month)])
        guard stamp == generation, !previewMode else { throw CancellationError() }
        return try result.validated(for: month)
    }

    func grantToyControl(device: CoveToyKind) async throws -> CoveToySessionEnvelope {
        guard !previewMode, isConnected else { throw CoveError.message("请先连接 Cove 服务。") }
        return try await request("v1/toy/session", method: "POST", body: [
            "mode": "untilRevoked", "device": device.rawValue,
        ])
    }

    func pollToyCommands(sessionID: String, after: Int) async throws -> CoveToyCommandsEnvelope {
        guard !previewMode, isConnected else { throw CoveError.message("Cove 服务未连接。") }
        return try await request("v1/toy/commands", query: [
            URLQueryItem(name: "sessionID", value: sessionID),
            URLQueryItem(name: "after", value: String(after))
        ])
    }

    func acknowledgeToyCommand(sessionID: String, commandID: String, status: String,
                               startedAt: Date?, stopAt: Date?, error: String?) async throws {
        var body: [String: Any] = ["sessionID": sessionID, "status": status]
        if let startedAt { body["startedAt"] = startedAt.ISO8601Format() }
        if let stopAt { body["stopAt"] = stopAt.ISO8601Format() }
        if let error { body["error"] = String(error.prefix(500)) }
        let _: OKEnvelope = try await request("v1/toy/commands/\(commandID)/ack", method: "POST", body: body)
    }

    func revokeToyControl(sessionID: String) async throws {
        let _: OKEnvelope = try await request("v1/toy/session/\(sessionID)", method: "DELETE")
    }

    func travelRequest(conversation: String, path: String = "v1/travel", body: [String: String]? = nil) async throws -> CoveTravelSnapshot {
        let stamp = generation
        guard healthForegroundActive, isConnected, !previewMode, activeConversationID == conversation else { throw CancellationError() }
        let result: CoveTravelSnapshot = try await request(path, method: body == nil ? "GET" : "POST", body: body,
            query: body == nil ? [URLQueryItem(name: "conversationID", value: conversation)] : [])
        guard stamp == generation, healthForegroundActive, isConnected, !previewMode, activeConversationID == conversation else { throw CancellationError() }
        return result
    }

    func travelAlbum(conversation: String, journeyID: String, after: Int = 0) async throws -> CoveTravelAlbum {
        let stamp = generation
        guard healthForegroundActive, isConnected, !previewMode, activeConversationID == conversation,
              UUID(uuidString: journeyID) != nil, after >= 0 else { throw CancellationError() }
        let album: CoveTravelAlbum = try await request("v1/travel/journeys/\(journeyID)", query: [
            URLQueryItem(name: "conversationID", value: conversation), URLQueryItem(name: "after", value: String(after))])
        guard stamp == generation, healthForegroundActive, isConnected, !previewMode, activeConversationID == conversation,
              album.journey.id == journeyID, album.journey.conversationID == conversation else { throw CancellationError() }
        return album
    }

    func travelAlbumCover(conversation: String, journeyID: String, photoID: String, requestID: String) async throws -> CoveTravelSnapshot {
        try await travelRequest(conversation: conversation, path: "v1/travel/cover", body: [
            "conversationID": conversation, "journeyID": journeyID, "photoID": photoID, "requestID": requestID])
    }

    private func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil, query: [URLQueryItem] = []) async throws -> T {
        try Task.checkCancellation()
        let requestGeneration = generation
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
        let isTravelMutation = path.hasPrefix("v1/travel/") && method == "POST"
        if isTravelMutation { request.timeoutInterval = 95 }
        let transport = path == "v1/attachments" || isTravelMutation ? uploadSession : session
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        guard requestGeneration == generation else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse else { throw CoveError.message("服务没有返回有效响应。") }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 { throw CoveHTTPError(status: 401, message: "连接密钥不匹配，请在设置里检查。") }
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw CoveHTTPError(status: response.statusCode, message: (value?["error"] as? String) ?? "服务暂时不可用（\(response.statusCode)）。")
        }
        return try CoveJSON.decoder().decode(T.self, from: data)
    }

    /// Match CCC's proven upload path: exact file bytes in the request body,
    /// with metadata in the URL. This avoids Base64's 33% expansion and keeps
    /// large mobile uploads on the dedicated long-lived transport.
    private func uploadAttachment(filename: String, mime: String, data: Data) async throws -> ChatAttachment {
        guard let base = connectedURL else { throw CoveError.message("先在设置中连接你的 Cove 服务。") }
        var components = URLComponents(url: base.appendingPathComponent("v1/attachments"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "filename", value: filename),
            URLQueryItem(name: "mime", value: mime)
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(connectedToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        let (responseData, response) = try await uploadSession.upload(for: request, from: data)
        guard let response = response as? HTTPURLResponse else { throw CoveError.message("服务没有返回有效响应。") }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 { throw CoveError.message("连接密钥不匹配，请在设置里检查。") }
            let value = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
            throw CoveHTTPError(status: response.statusCode, message: (value?["error"] as? String) ?? "附件上传失败（\(response.statusCode)）。")
        }
        return try CoveJSON.decoder().decode(ChatAttachment.self, from: responseData)
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
        // Directory creation belongs to the IO worker, never the edit path.
        let key = SHA256.hash(data: Data(cacheEndpoint.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent("\(key).json")
    }

    private var draftCacheURL: URL { cacheURL.deletingPathExtension().appendingPathExtension("drafts.json") }

    private func loadCache() {
        if let data = chatCacheIO.read(cacheURL), let saved = try? CoveJSON.decoder().decode(Cache.self, from: data) { cache = saved }
        if let data = chatCacheIO.read(draftCacheURL), let saved = try? JSONDecoder().decode(CoveDraftSnapshot.self, from: data) {
            cache.drafts = saved.restoring(over: cache.drafts, cacheRevision: cache.persistenceRevision ?? 0)
            cache.persistenceRevision = max(cache.persistenceRevision ?? 0, saved.revision)
        }
        for i in cache.messages.indices where cache.messages[i].status == "sending" { cache.messages[i].status = "pending" }
        conversations = cache.conversations
        stickers = cache.stickers ?? []
        stickerError = nil
        activeConversationID = cache.activeConversationID
        searchReturnConversationID = cache.searchReturnConversationID
        currentConversationID = cache.currentConversationID
        composerDraft.activate(conversationID: activeConversationID, text: cache.drafts[activeConversationID] ?? "")
        showCurrentMessages()
    }

    private func persist() {
        guard !previewMode else { return }
        cache.persistenceRevision = (cache.persistenceRevision ?? 0) + 1
        let snapshot = cache, url = cacheURL
        chatCacheIO.write(snapshot, to: url) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                guard let self, self.cacheURL == url, !self.previewMode else { return }
                self.errorMessage = "本地保存失败，请暂时保留 App：\(error.localizedDescription)"
            }
        }
    }

    private func persistOrThrow() throws {
        cache.persistenceRevision = (cache.persistenceRevision ?? 0) + 1
        try chatCacheIO.writeSynchronously(cache, to: cacheURL)
    }

    private func createLocalConversation() {
        let conversation = Conversation(id: UUID().uuidString, title: "我们的对话", createdAt: Date())
        cache.conversations.insert(conversation, at: 0)
        cache.activeConversationID = conversation.id
        conversations = cache.conversations
        activeConversationID = conversation.id
        sessionContext = nil; sessionHandoff = nil; sessionContextError = nil; handoffError = nil
        composerDraft.activate(conversationID: activeConversationID, text: "")
        replyToMessageID = nil; isBusy = false
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
        var updated: [ChatMessage] = current.map { $0.readyForDisplay }.filter(\.isVisibleInChat)
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
        if !previewMode && healthArchiveHasUnsavedChanges {
            saveLocalHealthHistory()
            guard !healthArchiveHasUnsavedChanges else {
                errorMessage = "本机健康历史尚未保存，暂不进入预览，以免丢失。请保留 App 并稍后重试。"
                return
            }
        }
        suspend()
        previewMode = true
        resetStandingHealthAccess()
        messageHighlight = nil; scrollRequest = nil; searchReturnConversationID = nil
        currentConversationID = nil
        sessionContext = nil; sessionHandoff = nil; handoffError = nil; sessionContextError = nil
        pulseDashboard = nil
        pulseError = nil
        pulseLastReceivedAt = nil
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
            .init(id: "preview-assistant", owner: "assistant", label: "Assistant 的 · 示例", createdAt: now, attachment: sampleAttachment)
        ]
        conversations = [.init(id: id, title: "海湾里的日常", createdAt: now)]
        activeConversationID = id
        composerDraft.activate(conversationID: id, text: "")
        messages = [
            .init(id: "p1", conversationID: id, role: "assistant", text: "用户，回来了。\n今天想从哪儿说起？", createdAt: now.addingTimeInterval(-240), status: "complete"),
            .init(id: "p2", conversationID: id, role: "user", text: "想有个随时能找到你的地方。", createdAt: now.addingTimeInterval(-180), status: "sent", readAt: now.addingTimeInterval(-125)),
            .init(id: "p3", conversationID: id, role: "assistant", text: "那就慢慢把这里住满。\n你的琐事、我的回应，都好好留着。", createdAt: now.addingTimeInterval(-120), status: "complete"),
            .init(id: "p4", conversationID: id, role: "user", text: "就叫 Cove 吧。", createdAt: now.addingTimeInterval(-60), status: "sent")]
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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--widget-preview") {
            messages = [.init(id: "widget-preview", conversationID: id, role: "assistant", text: CoveWidgetPreview.text, createdAt: now, status: "complete")]
        }
        #endif
        pulse = .init(updatedAt: now.addingTimeInterval(-300), summary: "想靠近一点，也想听你说说今天。", desires: [.init(id: "intimacy", label: "亲近", value: 0.82, detail: "想与你待一会儿"), .init(id: "attachment", label: "依恋", value: 0.68, detail: "还惦记着刚才的话"), .init(id: "curiosity", label: "好奇", value: 0.55, detail: "想知道你今天的小事"), .init(id: "reflection", label: "反思", value: 0.31, detail: "把值得记住的留下"), .init(id: "libido", label: "欲望", value: 0.46, detail: "这里只是界面示例")], physical: [.init(id: "energy", label: "精力", value: 0.73, detail: ""), .init(id: "calm", label: "平静", value: 0.86, detail: "")], senses: [.init(id: "sound", label: "声音", value: 0.4, detail: "你的声音，离我很近。")])
        if ProcessInfo.processInfo.arguments.contains("--pulse-qa"), let pulse {
            let vitals = PulseVitals(heartRate: 72, temperature: 36.4, breathingRate: 14.5,
                breathingDepth: "平稳", chord: "Cmaj7", activity: "安静", emotion: "平静", source: "digital_model")
            let heartbeat = PulseHeartbeat(lastTickAt: now.addingTimeInterval(-60), lastWakeAt: now.addingTimeInterval(-240),
                intervalSeconds: 300, quiet: false, nextTickAt: now.addingTimeInterval(240))
            let environment = PulseEnvironment(timeOfDay: "夜晚", weather: "小雨", temperature: 22.3,
                source: "私有环境记录", updatedAt: now.addingTimeInterval(-120))
            let snapshot = PulseDashboardSnapshot(updatedAt: pulse.updatedAt, summary: pulse.summary,
                physical: pulse.physical, senses: pulse.senses, desires: pulse.desires,
                vitals: vitals, heartbeat: heartbeat, environment: environment)
            let history: [PulseHistoryPoint] = (0..<12).map { index -> PulseHistoryPoint in
                let timestamp = now.addingTimeInterval(Double(index - 11) * 600)
                return PulseHistoryPoint(id: "qa-history-\(index)", at: timestamp,
                    heartRate: 68 + Double(index % 5), temperature: 36.2, breathingRate: 14)
            }
            let completedAction = PulseAction(id: "qa-action", title: "查看待处理的对话", status: "complete", detail: "没有发送新消息")
            let quietWake = PulseWakeEvent(id: "qa-wake-success", createdAt: now.addingTimeInterval(-240),
                completedAt: now.addingTimeInterval(-225), reason: "libido_crossed_threshold", status: "quiet",
                thoughtSummary: "这是合成的主动唤醒摘要，用于预览卡片。", actions: [completedAction],
                resultSummary: "安静地醒来，没有打扰你。", conversationID: id, messageID: nil)
            let failedAction = PulseAction(id: "qa-failed-action", title: "读取待办", status: "failed", detail: "连接超时")
            let failedWake = PulseWakeEvent(id: "qa-wake-failure", createdAt: now.addingTimeInterval(-1800),
                completedAt: now.addingTimeInterval(-1780), reason: "scheduled_heartbeat", status: "failed",
                thoughtSummary: nil, actions: [failedAction], resultSummary: nil, conversationID: nil, messageID: nil)
            let murmur = PulseMurmur(id: "qa-murmur", createdAt: now.addingTimeInterval(-300),
                text: "雨声让整个海湾安静下来。", source: "pulse")
            pulseDashboard = PulseDashboard(generatedAt: now, snapshot: snapshot, history: history,
                events: [quietWake, failedWake], murmurs: [murmur], warnings: [])
            pulseLastReceivedAt = now
        }
        health = .init(capturedAt: now.addingTimeInterval(-900), metrics: [.init(id: "sleep", title: "睡眠", value: 7.4, unit: "小时", sampledAt: now.addingTimeInterval(-7200), detail: "示例 · 过去 24 小时"), .init(id: "steps", title: "步数", value: 3680, unit: "步", sampledAt: now, detail: "示例 · 今日累计"), .init(id: "heartRate", title: "心率", value: 72, unit: "次/分", sampledAt: now.addingTimeInterval(-600)), .init(id: "hrv", title: "心率变异性", value: 48, unit: "毫秒", sampledAt: now.addingTimeInterval(-3600))])
        healthSyncedAt = now.addingTimeInterval(-900)
        healthArchiveEntries = []; healthHistory = []; healthArchiveError = nil
        healthReadAt = nil
        healthSyncStatus = "示例数据，不会上传"
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview"),
           ProcessInfo.processInfo.arguments.contains("--health-history-qa") {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            let today = calendar.startOfDay(for: now)
            let times = [now, max(today, now.addingTimeInterval(-1800)), today.addingTimeInterval(-12 * 3600)]
            let states: [CoveHealthArchiveEntry.SharingState] = [.localOnly, .shared, .deliveryUnknown]
            healthArchiveEntries = times.enumerated().map { index, at in
                let snapshot = HealthSnapshot(capturedAt: at, metrics: [
                    .init(id: "steps", title: "示例步数", value: Double(1200 + index * 300), unit: "步",
                          sampledAt: at.addingTimeInterval(-60), detail: "合成示例 · 不是真实健康读数", source: "Cove 本地 QA 示例")
                ])
                return CoveHealthArchiveEntry(snapshot: snapshot, recordedAt: at,
                    origin: index == 0 ? .manual : .request, sharingState: states[index],
                    serviceID: index == 0 ? nil : "synthetic-health-history-service",
                    conversationID: index == 0 ? nil : "synthetic-health-history-conversation",
                    requestID: index == 0 ? nil : "synthetic-health-history-\(index)")
            }
            healthHistory = healthArchiveEntries.map(\.snapshot)
            health = healthArchiveEntries.first?.snapshot
            healthSyncStatus = "合成健康历史示例 · 2 天 3 次；不会读取、保存或上传真实健康数据。"
        }
        #endif
        usage = .init(plan: "界面示例", updatedAt: now, windows: [.init(id: "codex-5h", title: "5 小时窗口", usedPercent: 28, resetsAt: now.addingTimeInterval(7200)), .init(id: "codex-weekly", title: "周额度", usedPercent: 43, resetsAt: now.addingTimeInterval(172800))], error: nil)
        composerDraft.activate(conversationID: id, text: "")
    }

    func exitPreview() {
        previewMode = false
        pulse = nil; pulseDashboard = nil; pulseError = nil; pulseLastReceivedAt = nil
        sessionContext = nil; sessionHandoff = nil; handoffError = nil; sessionContextError = nil
        health = nil; healthHistory = []; usage = nil; healthSyncedAt = nil; healthReadAt = nil
        healthSyncStatus = "还没有同步"
        restoreLocalHealthHistory()
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
private struct MessageSearchEnvelope: Decodable { let query: String; let results: [CoveMessageSearchResult]; let nextCursor: String?; let date: String?; let timeZone: String? }
private struct AttachmentEnvelope: Decodable { let id: String; let url: String }
private struct StickerList: Decodable { let stickers: [CoveSticker] }
private struct StickerEnvelope: Decodable { let sticker: CoveSticker }
private struct HealthRequestsEnvelope: Decodable { let requests: [CoveHealthRequest] }
private struct HealthRequestResponse: Decodable { let ok: Bool; let request: CoveHealthRequest }
private struct DataAccessEnvelope: Decodable { let enabled: Bool }
private struct PersonalLedgerSyncEnvelope: Decodable {
    let revision: Int
    let snapshot: CoveLedgerSnapshot
    let syncedAt: Date
}
private struct PersonalLedgerReadEnvelope: Decodable { let latest: PersonalLedgerSyncEnvelope? }
private struct PersonalLedgerCommandReceipt: Codable {
    let recordID: UUID
    let status: String
    let error: String?
}
private struct PersonalLedgerCommandsEnvelope: Decodable { let commands: [PersonalLedgerCommand] }
private struct PersonalLedgerCommandEnvelope: Decodable { let command: PersonalLedgerCommand }
private struct PersonalLedgerCommand: Decodable {
    let id: UUID
    let recordID: UUID
    let action: PersonalLedgerRemoteAction
    let status: String
    let createdAt: Date
}
private struct PersonalLedgerRemoteAction: Decodable {
    enum Kind: String, Decodable {
        case expense, income, statement, correctStatement, installment, updateInstallment
        case closeInstallment, reconciliation, repayment, voidTransaction
    }
    let action: Kind
    let accountID: UUID?
    let destinationAccountID: UUID?
    let categoryID: UUID?
    let statementID: UUID?
    let targetID: UUID?
    let amountFen: Int64?
    let minimumDueFen: Int64?
    let balanceFen: Int64?
    let remainingPeriods: Int64?
    let remainingPrincipalFen: Int64?
    let nextPrincipalFen: Int64?
    let nextInterestFen: Int64?
    let statementDate: Date?
    let dueDate: Date?
    let nextDueDate: Date?
    let capturedAt: Date?
    let occurredAt: Date?
    let amountsRepeat: Bool?
    let label: String?
    let note: String?
    let reason: String?
}
private struct HealthEnvelope: Decodable { let snapshot: HealthSnapshot?; let syncedAt: Date?; let readAt: Date? }
private struct HealthHistoryEnvelope: Decodable { let snapshots: [HealthSnapshot]; let updatedAt: Date? }
private struct SyncEnvelope: Decodable { let ok: Bool; let syncedAt: Date }
private struct HealthUploadEnvelope: Decodable { let snapshot: HealthSnapshot; let syncedAt: Date }
private struct OKEnvelope: Decodable { let ok: Bool }
struct CoveHTTPError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

enum CoveError: LocalizedError {
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

// MARK: Foreground, device-scoped EventKit / AlarmKit bridge
extension CoveStore {
    private func deviceBridgeAllowed(stamp: UUID, epoch: UUID, conversation: String) -> Bool {
        !Task.isCancelled && !previewMode && healthForegroundActive && isConnected && connectedURL != nil
            && stamp == generation && epoch == deviceBridgeEpoch && conversation == activeConversationID
            && !conversation.isEmpty && !isSwitchingSession
    }

    func refreshDeviceRequests() async {
        let stamp = generation, epoch = deviceBridgeEpoch, conversation = activeConversationID
        guard !refreshingDeviceRequests, deviceBridgeAllowed(stamp: stamp, epoch: epoch, conversation: conversation) else { return }
        refreshingDeviceRequests = true
        defer { refreshingDeviceRequests = false }
        do {
            let statuses = Dictionary(uniqueKeysWithValues: CoveSystemCapability.allCases.map { ($0.rawValue, deviceBackend.status($0).rawValue) })
            let _: OKEnvelope = try await request("v1/device-actions/device", method: "POST", body: ["deviceID": bridgeDeviceID, "statuses": statuses])
            guard deviceBridgeAllowed(stamp: stamp, epoch: epoch, conversation: conversation) else { return }
            if statuses != deviceBridgeStatuses {
                deviceBridgeStatuses = statuses
                deviceRequestErrors = deviceRequestErrors.filter { claimedDeviceRequests.contains($0.key) }
            }
            let envelope: CoveDeviceRequestsEnvelope = try await request("v1/conversations/\(conversation)/device-actions", query: [.init(name: "deviceID", value: bridgeDeviceID)])
            guard deviceBridgeAllowed(stamp: stamp, epoch: epoch, conversation: conversation) else { return }
            deviceRequests = envelope.requests.filter { $0.conversationID == conversation && $0.deviceID == bridgeDeviceID && UUID(uuidString: $0.id) == $0.action.id }
            await refreshHealthDataAccess()
            guard deviceBridgeAllowed(stamp: stamp, epoch: epoch, conversation: conversation) else { return }
            // Fetch authoritative states first: the server may already have committed a lost ACK.
            // Every receipt is isolated; a stale/conflicting one must not block newer requests.
            let receipts: [CoveDeviceReceipt]
            do { receipts = try deviceReceiptJournal.load(scope: healthServiceID, conversation: conversation) }
            catch { receipts = [] }
            for receipt in receipts.prefix(20) {
                guard deviceBridgeAllowed(stamp: stamp, epoch: epoch, conversation: conversation) else { return }
                do {
                    if let recorded = deviceRequests.first(where: { receipt.matchesTerminal($0) }) {
                        try deviceReceiptJournal.remove(receipt)
                        deviceRequestErrors[receipt.request.id] = recorded.status == receipt.status ? nil
                            : "服务记录为「\(recorded.status)」，本机回执为「\(receipt.status)」；状态不同，没有重复执行。"
                    } else { try await postDeviceReceipt(receipt) }
                } catch { deviceRequestErrors[receipt.request.id] = "回执尚未确认，不会重复执行：\(error.localizedDescription)" }
            }
            guard deviceBridgeAllowed(stamp: stamp, epoch: epoch, conversation: conversation) else { return }
            for item in deviceRequests where item.status == "pending" && item.action.expiresAt > Date() {
                guard deviceBridgeAllowed(stamp: stamp, epoch: epoch, conversation: conversation) else { return }
                if item.action.targetID != nil, deviceRequestTargets[item.id] == nil {
                    // A destructive confirmation includes the real device record, not remote text.
                    do { deviceRequestTargets[item.id] = try deviceBackend.resolveTarget(item.action) }
                    catch { deviceRequestErrors[item.id] = error.localizedDescription }
                }
                if !item.action.operation.isMutation, healthSharingEnabled, healthDataAccessKnown, !healthUploadsPaused,
                   !isUpdatingHealthDataAccess, deviceRequestErrors[item.id] == nil {
                    await respondToDeviceRequest(item, allow: true)
                }
            }
        } catch {
            // An old backend or unreachable phone bridge must not disconnect chat.
            // Specific request failures remain visible on their confirmation cards.
        }
    }

    func respondToDeviceRequest(_ item: CoveDeviceRequest, allow: Bool) async {
        let stamp = generation, epoch = deviceBridgeEpoch, conversation = activeConversationID
        let revision = healthAccessRevision, scope = healthServiceID
        guard deviceBridgeAllowed(stamp: stamp, epoch: epoch, conversation: conversation),
              !respondingDeviceRequestIDs.contains(item.id),
              deviceRequests.contains(where: { $0 == item && $0.status == "pending" }) else { return }
        respondingDeviceRequestIDs.insert(item.id)
        defer { respondingDeviceRequestIDs.remove(item.id) }
        deviceRequestErrors[item.id] = nil
        var receipt: CoveDeviceReceipt?
        do {
            try item.validate(conversation: conversation, device: bridgeDeviceID)
            if allow {
                guard !claimedDeviceRequests.contains(item.id) else { throw CoveDeviceActionError.duplicate }
                if !item.action.operation.isMutation {
                    guard healthSharingEnabled, healthDataAccessKnown, !healthUploadsPaused, !isUpdatingHealthDataAccess else {
                        throw CoveDeviceActionError.invalid("持续读取授权未开启")
                    }
                }
                guard deviceBackend.status(item.action.operation.capability) == .authorized else { throw CoveDeviceActionError.permission }
                if item.action.targetID != nil {
                    let actual = try deviceBackend.resolveTarget(item.action)
                    guard actual != nil, actual == deviceRequestTargets[item.id] else {
                        deviceRequestTargets[item.id] = actual
                        throw CoveDeviceActionError.invalid("系统中的目标已变化，请重新核对后确认")
                    }
                }
                // Local intent before network dispatch: uncertain claim responses cannot trigger writes.
                claimedDeviceRequests.insert(item.id)
                let claim: CoveDeviceRequestEnvelope = try await request("v1/conversations/\(conversation)/device-actions/\(item.id)/claim", method: "POST", body: ["deviceID": bridgeDeviceID])
                guard deviceBridgeAllowed(stamp: stamp, epoch: epoch, conversation: conversation), claim.ok,
                      claim.request.id == item.id, claim.request.action == item.action,
                      claim.request.deviceID == bridgeDeviceID, claim.request.conversationID == conversation,
                      claim.request.status == "claimed" else { throw CoveDeviceActionError.invalid("领取结果未确认；没有执行，不会自动重试") }
                if !item.action.operation.isMutation {
                    guard revision == healthAccessRevision, healthSharingEnabled, healthDataAccessKnown,
                          !healthUploadsPaused, !isUpdatingHealthDataAccess else { throw CoveDeviceActionError.invalid("读取授权已变化，没有执行") }
                }
                // No suspension point exists between the last scope check and entering the executor.
                do {
                    if item.action.targetID != nil {
                        guard try deviceBackend.resolveTarget(item.action) == deviceRequestTargets[item.id] else {
                            throw CoveDeviceActionError.invalid("目标在领取时发生变化，没有执行；请发起新请求")
                        }
                    }
                    let result = try await deviceExecutor.execute(item.action, userConfirmed: item.action.operation.isMutation)
                    if !item.action.operation.isMutation && !deviceBridgeAllowed(stamp: stamp, epoch: epoch, conversation: conversation) {
                        receipt = .init(scope: scope, request: item, status: "failed", result: nil,
                                        error: "读取期间前台状态或对话连接发生变化；未分享读取记录")
                    } else {
                        receipt = .init(scope: scope, request: item, status: "succeeded", result: result, error: nil,
                                        readAuthorizationRevision: item.action.operation.isMutation ? nil : revision)
                    }
                } catch {
                    receipt = .init(scope: scope, request: item, status: "failed", result: nil, error: error.localizedDescription)
                }
            } else {
                receipt = .init(scope: scope, request: item, status: "denied", result: nil, error: nil)
            }
            guard let originalReceipt = receipt else { return }
            let safeReceipt = safeDeviceReceipt(originalReceipt)
            receipt = safeReceipt
            // Save the framework result before ACK; even a context switch must not lose it.
            try deviceReceiptJournal.save(safeReceipt)
            guard deviceBridgeAllowed(stamp: stamp, epoch: epoch, conversation: conversation) else { return }
            try await postDeviceReceipt(safeReceipt)
        } catch {
            if stamp == generation, conversation == activeConversationID {
                deviceRequestErrors[item.id] = receipt == nil ? error.localizedDescription : "本机已处理，但回执尚未确认。不会重复执行：\(error.localizedDescription)"
            }
        }
    }

    private func safeDeviceReceipt(_ receipt: CoveDeviceReceipt) -> CoveDeviceReceipt {
        if !receipt.request.action.operation.isMutation && receipt.result != nil &&
            (receipt.readAuthorizationRevision != healthAccessRevision || !healthSharingEnabled || !healthDataAccessKnown || healthUploadsPaused || isUpdatingHealthDataAccess) {
            return .init(scope: receipt.scope, request: receipt.request, status: "failed", result: nil,
                         error: "读取授权已变化或设备已重启；未分享此前读取的记录")
        }
        return receipt
    }

    private func postDeviceReceipt(_ originalReceipt: CoveDeviceReceipt) async throws {
        // A revoked/unknown grant (including relaunch) permanently drops sensitive read results.
        let receipt = safeDeviceReceipt(originalReceipt)
        try deviceReceiptJournal.save(receipt)
        let stamp = generation, epoch = deviceBridgeEpoch, conversation = activeConversationID
        guard receipt.scope == healthServiceID, receipt.request.deviceID == bridgeDeviceID,
              deviceBridgeAllowed(stamp: stamp, epoch: epoch, conversation: receipt.request.conversationID) else { return }
        var body: [String: Any] = ["deviceID": bridgeDeviceID, "status": receipt.status]
        if let result = receipt.result { body["result"] = try JSONSerialization.jsonObject(with: CoveJSON.encoder().encode(result)) }
        if let error = receipt.error { body["error"] = error }
        let response: CoveDeviceRequestEnvelope = try await request("v1/conversations/\(receipt.request.conversationID)/device-actions/\(receipt.request.id)/response", method: "POST", body: body)
        guard response.ok, response.request.id == receipt.request.id, response.request.deviceID == bridgeDeviceID,
              response.request.conversationID == receipt.request.conversationID, response.request.action == receipt.request.action,
              response.request.status == receipt.status else { throw CoveDeviceActionError.invalid("服务尚未确认本机回执") }
        try deviceReceiptJournal.remove(receipt)
        if deviceBridgeAllowed(stamp: stamp, epoch: epoch, conversation: conversation),
           let index = deviceRequests.firstIndex(where: { $0.id == receipt.request.id }) {
            deviceRequests[index] = response.request
            deviceRequestErrors[receipt.request.id] = nil
        }
    }
}
