import Foundation
import UIKit
import Combine
import BackgroundTasks

private final class ActivityResponseBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int: Data] = [:]
    func append(_ data: Data, id: Int) {
        lock.lock(); defer { lock.unlock() }
        var value = values[id] ?? Data()
        // Never retain arbitrary server error pages or credentials in a response log.
        value.append(data.prefix(max(0, 16384 - value.count)))
        values[id] = value
    }
    func take(_ id: Int) -> Data {
        lock.lock(); defer { lock.unlock() }
        return values.removeValue(forKey: id) ?? Data()
    }
}

@MainActor
final class CoveActivityRecorder: NSObject, ObservableObject {
    static let sessionID = "com.example.cove.app-activity.upload"
    static let taskID = "com.example.cove.app-activity.retry"
    private static var instance: CoveActivityRecorder?
    static var shared: CoveActivityRecorder {
        if let instance { return instance }
        let value = CoveActivityRecorder(); instance = value; return value
    }
    static func configure(preview: Bool = ProcessInfo.processInfo.arguments.contains("--preview")) {
        if preview {
            instance?.previewPaused = true
            instance?.session.getAllTasks { $0.forEach { $0.cancel() } }
            return
        }
        let recorder = shared
        recorder.previewPaused = false
        Task { await recorder.schedule() }
    }
    static func registerBackgroundTask() {
        guard !ProcessInfo.processInfo.arguments.contains("--preview") else { return }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: .main) { task in
            Task { @MainActor in
                let work = Task { await Self.shared.schedule() }
                task.expirationHandler = { work.cancel() }
                await work.value
                task.setTaskCompleted(success: !work.isCancelled)
            }
        }
    }

    @Published private(set) var state = ActivityQueueState()
    @Published private(set) var error: String?
    private let queue: AppActivityQueue
    private let credentials = CoveKeychainCredentials()
    private var pumping = false
    private var pumpAgain = false
    private var previewPaused = false
    private var backgroundCompletion: (() -> Void)?
    private let responses = ActivityResponseBuffer()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        configuration.isDiscretionary = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 24 * 3600
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    private override init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        queue = AppActivityQueue(directory: root.appendingPathComponent("CoveAppActivity", isDirectory: true))
        super.init()
        refresh()
    }
    func refresh() {
        guard !previewPaused else { return }
        do { state = try queue.snapshot(); error = nil }
        catch { self.error = "本机记录暂时不可用，已保留旧文件。请解锁并重新打开 Cove。" }
    }
    func setEnabled(_ enabled: Bool) {
        do { try queue.setEnabled(enabled); refresh(); Task { await schedule() } }
        catch { self.error = error.localizedDescription }
    }
    func save(recipient: ActivityRecipient, baseURL: String, token: String, enabled: Bool) throws {
        let base = try AppActivityQueue.validatedBaseURL(baseURL)
        try queue.validateDestinationChange(recipient, baseURL: base)
        let old = try queue.snapshot().destinations.first { $0.id == recipient }
        let account = "app-activity.\(recipient.rawValue).\(UUID().uuidString)"
        let secret: String
        if token.isEmpty, let old, old.baseURL == base, let value = credentials.read(account: old.credentialAccount) {
            secret = value
        } else { secret = token.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard (32...256).contains(secret.utf8.count), secret.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else {
            throw ActivityQueueError.message("请提供这个接收端独立的上报密钥，不是聊天连接密钥。")
        }
        // Store in Keychain before committing the reference. A failed journal write never loses the old config.
        try credentials.write(secret, account: account)
        try queue.configure(ActivityDestination(id: recipient, baseURL: base, credentialAccount: account, enabled: enabled))
        refresh()
        Task { await schedule() }
    }
    func record(app: ActivityApp, action: ActivityAction) async throws {
        guard !previewPaused, !ProcessInfo.processInfo.arguments.contains("--preview") else { return }
        _ = try queue.enqueue(app: app, action: action)
        refresh()
        // Wait only for local URLSession task scheduling, never for a network response.
        await schedule()
    }
    func retry() {
        do { try queue.retry(); refresh(); Task { await schedule() } }
        catch { self.error = error.localizedDescription }
    }
    func discardPending() {
        do { try queue.discardPending(); refresh(); Task { await schedule() } }
        catch { self.error = error.localizedDescription }
    }
    func handleBackgroundEvents(completion: @escaping () -> Void) {
        backgroundCompletion = completion
        _ = session // Reattach the same background session after an OS relaunch.
    }
    func schedule() async {
        guard !previewPaused else { return }
        if pumping { pumpAgain = true; return }
        pumping = true
        defer {
            pumping = false
            if pumpAgain { pumpAgain = false; Task { await schedule() } }
        }
        do {
            let tasks = await session.allTasks
            guard !previewPaused, !Task.isCancelled else { return }
            let current = try queue.snapshot()
            var occupied = Set<ActivityRecipient>()
            var payloadIDs = Set(current.events.map(\.id))
            for task in tasks {
                guard let identity = ActivityUploadIdentity(task.taskDescription), identity.isCurrent(in: current) else {
                    task.cancel(); continue
                }
                occupied.insert(identity.recipient)
                payloadIDs.insert(identity.eventID)
            }
            guard current.enabled else {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID)
                try queue.cleanPayloads(keeping: payloadIDs)
                refresh(); return
            }
            for destination in current.destinations where destination.enabled && destination.blocked == nil {
                guard !occupied.contains(destination.id),
                      let pending = current.events.first(where: {
                          guard let delivery = $0.deliveries[destination.id.rawValue] else { return false }
                          return !delivery.blocked && delivery.nextAttempt <= Date()
                      }) else { continue }
                let identity = ActivityUploadIdentity(eventID: pending.id, recipient: destination.id,
                                                      epoch: current.epoch, revision: destination.revision)
                guard let secret = credentials.read(account: destination.credentialAccount), !secret.isEmpty else {
                    try queue.apply(.blockDestination("上报密钥暂时不可读，请解锁并检查配置。"), identity: identity)
                    continue
                }
                let file = try queue.payloadFile(for: pending.event)
                var request = URLRequest(url: destination.endpoint)
                request.httpMethod = "POST"
                request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let task = session.uploadTask(with: request, fromFile: file)
                task.taskDescription = identity.encoded
                task.resume()
            }
            refresh()
            try queue.cleanPayloads(keeping: payloadIDs)
            scheduleRetry()
        } catch {
            self.error = "暂时无法安排上传，未将任何记录标为成功。打开 Cove 后会再次尝试。"
        }
    }
    private func scheduleRetry() {
        let dates = state.events.flatMap { event in
            event.deliveries.compactMap { key, delivery -> Date? in
                guard !delivery.blocked, state.destinations.contains(where: {
                    $0.id.rawValue == key && $0.enabled && $0.blocked == nil
                }) else { return nil }
                return delivery.nextAttempt
            }
        }
        guard state.enabled, let next = dates.min() else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID); return
        }
        let earliest = max(next, Date().addingTimeInterval(30))
        let identifier = Self.taskID
        // iOS chooses the actual wake time. Foreground/next Intent also resumes this queue.
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        DispatchQueue.global(qos: .utility).async {
            let request = BGProcessingTaskRequest(identifier: identifier)
            request.requiresNetworkConnectivity = true
            request.earliestBeginDate = earliest
            BGTaskScheduler.shared.submitTaskRequest(request) { _ in
                // Pending remains durable even if iOS declines a background request.
            }
        }
    }
    private func completed(identity: ActivityUploadIdentity, status: Int?, data: Data, failed: Bool, finalURL: URL?) async {
        guard !previewPaused else { return }
        do {
            let target = try queue.snapshot().destinations.first { $0.id == identity.recipient }
            let outcome: ActivityUploadOutcome
            if !failed, let finalURL, let target, finalURL != target.endpoint {
                outcome = .blockDestination("服务器发生跳转，回执未被采纳。请核对接收地址。")
            } else {
                outcome = ActivityUploadOutcome.classify(status: status, data: data, expectedID: identity.eventID,
                                                         transportFailed: failed)
            }
            try queue.apply(outcome, identity: identity)
            refresh()
            await schedule()
        } catch { self.error = "回执暂时未能存入手机；原事件 ID 已保留，不会生成新事件重传。" }
    }
}

extension CoveActivityRecorder: URLSessionDataDelegate {
    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responses.append(data, id: dataTask.taskIdentifier)
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let data = responses.take(task.taskIdentifier)
        guard let identity = ActivityUploadIdentity(task.taskDescription) else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let failed = error != nil
        let finalURL = task.response?.url
        Task { @MainActor in await completed(identity: identity, status: status, data: data, failed: failed, finalURL: finalURL) }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                               completionHandler: @escaping (URLRequest?) -> Void) {
        // Refuse when URLSession exposes the redirect. Background transfers can follow
        // redirects internally, so completed() also rejects a changed final URL.
        completionHandler(nil)
    }
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            await schedule()
            let completion = backgroundCompletion; backgroundCompletion = nil
            completion?()
        }
    }
}
