import XCTest
import SwiftUI
import UIKit
@testable import Cove

final class CoveChatRenderWindowTests: XCTestCase {
    private func messages(_ range: Range<Int>) -> [ChatMessage] {
        range.map { .init(id: "m\($0)", conversationID: "a", role: "assistant", text: "**Message \($0)**",
                         createdAt: Date(timeIntervalSince1970: Double($0)), status: "complete") }
    }

    func testInitialWindowIsThirtyWithoutDeletingHistory() {
        let all = messages(0..<600)
        var window = CoveChatRenderWindow()
        window.prepare(all, conversationID: "a")
        XCTAssertEqual(window.range(in: all, conversationID: "a"), 570..<600)
        XCTAssertEqual(all.count, 600)
    }

    func testLiveTailRemainsBoundedAndCompletionKeepsStableRows() {
        var all = messages(0..<600)
        var window = CoveChatRenderWindow()
        window.prepare(all, conversationID: "a")
        all += messages(600..<602)
        all[601].status = "streaming"
        window.prepare(all, conversationID: "a")
        XCTAssertEqual(window.range(in: all, conversationID: "a"), 572..<602)
        all[601].text = String(repeating: "**Long reply**\n\n", count: 100)
        all[601].status = "complete"
        window.latest(all, conversationID: "a")
        XCTAssertEqual(window.range(in: all, conversationID: "a"), 572..<602)
        all += messages(602..<2000)
        window.prepare(all, conversationID: "a")
        XCTAssertEqual(window.range(in: all, conversationID: "a").count, 30)
    }

    func testIncomingPreservesTheWindowWhileReadingHistory() {
        var all = messages(0..<600)
        var window = CoveChatRenderWindow()
        window.pinForReading(all, conversationID: "a")
        all += messages(600..<604)
        window.prepare(all, conversationID: "a")
        XCTAssertEqual(window.range(in: all, conversationID: "a"), 570..<604)
    }

    func testExpandedHistoryNeverShrinksOnSendOrReturnToBottom() {
        var all = messages(0..<600)
        var window = CoveChatRenderWindow()
        window.earlier(all, conversationID: "a")
        XCTAssertEqual(window.range(in: all, conversationID: "a"), 540..<600)
        all += messages(600..<604)
        window.latest(all, conversationID: "a")
        XCTAssertEqual(window.range(in: all, conversationID: "a"), 540..<604)
        window = CoveChatRenderWindow() // only after leaving the view
        XCTAssertEqual(window.range(in: all, conversationID: "a"), 574..<604)
    }

    func testFarSearchUsesBoundedWindowAndIncomingDoesNotPullItToTail() {
        var all = messages(0..<600)
        var window = CoveChatRenderWindow()
        window.locate("m100", in: all, conversationID: "a")
        XCTAssertEqual(window.range(in: all, conversationID: "a"), 85..<116)
        all += messages(600..<602)
        window.prepare(all, conversationID: "a")
        XCTAssertEqual(window.range(in: all, conversationID: "a"), 85..<116)
        window.earlier(all, conversationID: "a")
        window.later(all, conversationID: "a")
        XCTAssertEqual(window.range(in: all, conversationID: "a"), 55..<146)
        window.latest(all, conversationID: "a")
        XCTAssertEqual(window.range(in: all, conversationID: "a"), 572..<602)
    }

    func testBoundaryIDsSurvivePrependingAndConversationChangeResets() {
        var all = messages(100..<600)
        var window = CoveChatRenderWindow()
        window.prepare(all, conversationID: "a")
        all = messages(0..<100) + all
        XCTAssertEqual(Array(all[window.range(in: all, conversationID: "a")]).first?.id, "m570")
        window.locate("m0", in: all, conversationID: "a")
        XCTAssertEqual(window.range(in: all, conversationID: "a"), 0..<16)
        window.prepare(all, conversationID: "b")
        XCTAssertEqual(window.range(in: all, conversationID: "b"), 570..<600)
        XCTAssertNil(window.lastID)
    }

    func testEmptyThenLoadedAndMissingTargetAreSafe() {
        var window = CoveChatRenderWindow()
        window.earlier([], conversationID: "a")
        window.later([], conversationID: "a")
        XCTAssertEqual(window.range(in: [], conversationID: "a"), 0..<0)
        let all = messages(0..<2)
        window.prepare(all, conversationID: "a")
        window.locate("absent", in: all, conversationID: "a")
        XCTAssertEqual(window.range(in: all, conversationID: "a"), 0..<2)
    }
}

final class CoveChatPresentationTests: XCTestCase {
    func testServiceAssistantReplyDoesNotCreateVisibleQuote() {
        let original = message(id: "user", role: "user")
        let reply = message(id: "assistant", role: "assistant", replyTo: original.id)
        XCTAssertNil(CoveChatPresentation.displayedQuote(reply, messagesByID: [original.id: original]))
    }

    func testExplicitUserQuoteRemainsVisible() {
        let original = message(id: "assistant", role: "assistant")
        let quote = message(id: "quoted-user", role: "user", replyTo: original.id)
        XCTAssertEqual(CoveChatPresentation.displayedQuote(quote, messagesByID: [original.id: original]), original)
        XCTAssertNil(CoveChatPresentation.displayedQuote(quote, messagesByID: [:]))
    }

    private func message(id: String, role: String, replyTo: String? = nil) -> ChatMessage {
        ChatMessage(id: id, conversationID: "preview", role: role, text: "引用正文", createdAt: Date(timeIntervalSince1970: 0), status: "complete", replyTo: replyTo)
    }
}

@MainActor
final class CoveNativeChatInputRegressionTests: XCTestCase {
    func testStickerInputViewKeepsNonzeroHeightAcrossModeChanges() throws {
        let coordinator = CoveChatTextInput.Coordinator(
            text: .constant("fixture"),
            onFocusChange: { _ in },
            onCompositionChange: { _ in }
        )
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        let panel = AnyView(Text("Sticker fixture"))

        coordinator.updatePanel(panel, enabled: true, for: textView)

        let firstInputView = try XCTUnwrap(textView.inputView)
        XCTAssertGreaterThanOrEqual(firstInputView.frame.height, 160)
        XCTAssertGreaterThanOrEqual(
            firstInputView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height,
            160,
            "The custom input view must advertise a usable height before UIKit lays it out."
        )

        coordinator.updatePanel(panel, enabled: false, for: textView)
        XCTAssertNil(textView.inputView, "Keyboard mode must restore the native system input view.")

        coordinator.updatePanel(panel, enabled: true, for: textView)

        let restoredInputView = try XCTUnwrap(textView.inputView)
        XCTAssertTrue(restoredInputView === firstInputView, "Mode switching must reuse the existing sticker input view.")
        XCTAssertGreaterThanOrEqual(restoredInputView.frame.height, 160)
        XCTAssertGreaterThanOrEqual(
            restoredInputView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height,
            160,
            "Reusing the custom input view must not lose its fitting height."
        )
    }

    func testInputModeButtonKeepsNativeHitSizeAndReportsRequestedMode() {
        let button = CoveInputModeButton.Control(frame: .zero)

        XCTAssertEqual(button.intrinsicContentSize, CGSize(width: 44, height: 44))

        button.configure(stickerMode: false, reduced: true)
        XCTAssertEqual(button.accessibilityLabel, "表情包")
        XCTAssertEqual(button.accessibilityValue as? String, "keyboard")

        button.configure(stickerMode: true, reduced: true)
        XCTAssertEqual(button.accessibilityLabel, "切回键盘")
        XCTAssertEqual(button.accessibilityValue as? String, "sticker")
        XCTAssertEqual(button.intrinsicContentSize, CGSize(width: 44, height: 44))
    }
}

final class CoveHealthScopeTests: XCTestCase {
    func testChatPromptOnlyRemainsForPendingConsent() {
        var item = request()
        XCTAssertTrue(item.canRespond(conversationID: "ours", now: now))
        for status in ["allowed", "denied", "expired"] {
            item.status = status
            XCTAssertFalse(item.canRespond(conversationID: "ours", now: now))
        }
        item.status = "pending"
        XCTAssertFalse(item.canRespond(conversationID: "ours", now: item.expiresAt))
        item.status = "allowed"
        item.continuationStatus = "running"
        XCTAssertFalse(item.canRespond(conversationID: "ours", now: now), "Automatic continuation must not pin the card")
    }

    func testConsentContinuationDoesNotAskForAnotherUserMessageOrInventReadReceipt() {
        var item = request()
        item.status = "allowed"
        item.continuationStatus = "queued"
        XCTAssertEqual(item.responseStatusText, "已允许，我会读取后直接回复。")
        XCTAssertNil(item.readAt)
        item.continuationStatus = "running"
        XCTAssertEqual(item.responseStatusText, "正在读取并回复…")
        item.readAt = now
        XCTAssertEqual(item.responseStatusText, "已读取，正在回复…")
        item.continuationStatus = "failed"
        XCTAssertTrue(item.responseStatusText.contains("续答未完成"))
        item.continuationStatus = nil
        item.readAt = nil
        XCTAssertEqual(item.responseStatusText, "已允许，等待对方读取。")
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func request() -> CoveHealthRequest {
        .init(id: "request-1", conversationID: "ours", metrics: ["sleep", "hrv"], startAt: now.addingTimeInterval(-86400), endAt: now, createdAt: now, expiresAt: now.addingTimeInterval(600), status: "pending", reason: "昨晚睡得好吗", respondedAt: nil, readAt: nil)
    }
    func testExpandedScopeIncludesStagesVitalsActivityAndFitness() {
        XCTAssertTrue(CoveHealthScope.metricIDs.isSuperset(of: ["sleepDeep", "sleepREM", "oxygenSaturation", "restingHeartRate", "bloodPressureSystolic", "bloodGlucose", "bodyTemperature", "sleepingWristTemperature", "dietaryWater", "height", "steps", "activeEnergy", "workoutDuration"]))
    }
    func testRequestRequiresCurrentConversationPendingAndUnexpired() {
        var item = request()
        XCTAssertTrue(item.canRespond(conversationID: "ours", now: now))
        XCTAssertFalse(item.canRespond(conversationID: "another", now: now))
        XCTAssertFalse(item.canRespond(conversationID: "ours", now: now.addingTimeInterval(600)))
        item.status = "allowed"
        XCTAssertFalse(item.canRespond(conversationID: "ours", now: now))
    }
    func testInvalidMetricDuplicateAndTooWideRequestFailClosed() {
        var item = request()
        item.metrics = ["clinicalRecord"]
        XCTAssertFalse(item.canRespond(conversationID: "ours", now: now))
        item.metrics = ["sleep", "sleep"]
        XCTAssertFalse(item.canRespond(conversationID: "ours", now: now))
        item.metrics = ["sleep"]
        item.startAt = now.addingTimeInterval(-8 * 86400)
        XCTAssertFalse(item.canRespond(conversationID: "ours", now: now))
    }
    func testOnlyRequestedFiniteSamplesInsideVisibleBounds() {
        let item = request()
        var snapshot = HealthSnapshot(capturedAt: now, metrics: [.init(id: "hrv", title: "HRV", value: 40, unit: "毫秒", sampledAt: now)])
        XCTAssertTrue(item.permits(snapshot))
        snapshot.metrics[0].sampledAt = now.addingTimeInterval(-86401)
        XCTAssertFalse(item.permits(snapshot))
        snapshot.metrics[0].sampledAt = now
        snapshot.metrics[0].value = .nan
        XCTAssertFalse(item.permits(snapshot))
        snapshot.metrics[0].value = 40
        snapshot.metrics[0].id = "heartRate"
        XCTAssertFalse(item.permits(snapshot))
        snapshot.metrics = []
        XCTAssertTrue(item.permits(snapshot), "No readable samples are not fabricated zeroes")
    }
    func testOldSnapshotsDecodeWithoutSource() throws {
        let json = Data(#"{"capturedAt":"2026-09-14T00:00:00Z","metrics":[{"id":"steps","title":"步数","value":12,"unit":"步","sampledAt":"2026-09-14T00:00:00Z"}]}"#.utf8)
        let snapshot = try CoveJSON.decoder().decode(HealthSnapshot.self, from: json)
        XCTAssertNil(snapshot.metrics.first?.source)
        XCTAssertNil(snapshot.sleepSegments)
        XCTAssertNil(snapshot.workouts)
    }
    func testHealthDetailArraysStayInsideExactConsent() {
        var item = request()
        item.metrics = ["sleepDeep", "workoutDuration"]
        var snapshot = HealthSnapshot(capturedAt: now, metrics: [], sleepSegments: [
            .init(stageID: "sleepDeep", startAt: now.addingTimeInterval(-3600), endAt: now)
        ], workouts: [
            .init(id: "w", type: "跑步", startAt: now.addingTimeInterval(-1800), endAt: now, durationSeconds: 1800)
        ])
        XCTAssertTrue(item.permits(snapshot))
        snapshot.sleepSegments?[0].stageID = "sleepREM"
        XCTAssertFalse(item.permits(snapshot))
        snapshot.sleepSegments = nil
        snapshot.workouts?[0].endAt = now.addingTimeInterval(1)
        XCTAssertFalse(item.permits(snapshot))
    }
}

private final class HealthMockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.cancelled) }
            let (status, bytes) = try handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
private final class HealthMockReader: CoveHealthReading {
    var authorized: [Set<String>] = []
    var ranges: [(Set<String>, Date?, Date)] = []
    var snapshotValue = HealthSnapshot(capturedAt: Date(), metrics: [])
    var afterAuthorization: (() -> Void)?
    var observedMetrics: Set<String> = []
    var onHealthChange: (() -> Void)?
    var beforeSnapshot: (() async -> Void)?
    func startObserving(metrics: Set<String>, onChange: @escaping @MainActor () -> Void) {
        observedMetrics = metrics; onHealthChange = onChange
    }
    func authorize(metrics: Set<String>) async throws { authorized.append(metrics); afterAuthorization?() }
    func snapshot(metrics: Set<String>, startAt: Date?, endAt: Date) async throws -> HealthSnapshot {
        ranges.append((metrics, startAt, endAt)); await beforeSnapshot?(); return snapshotValue
    }
    func stopObserving() {}
}

private final class HealthMockCredentials: CoveCredentialStore {
    func read(account: String) -> String? { nil }
    func write(_ token: String, account: String) throws {}
}

@MainActor
final class CoveHealthConsentTests: XCTestCase {
    private var store: CoveStore!
    private var reader: HealthMockReader!
    private var session: URLSession!
    private var previousURL: String?
    private var requestItem: CoveHealthRequest!
    private var previousSharing: Any?

    override func setUp() async throws {
        previousSharing = UserDefaults.standard.object(forKey: "cove.healthSharing")
        previousURL = UserDefaults.standard.string(forKey: "cove.serverURL")
        UserDefaults.standard.removeObject(forKey: "cove.serverURL")
        reader = HealthMockReader()
        let now = Date().addingTimeInterval(-1)
        requestItem = .init(id: "health-one", conversationID: "ours", metrics: ["hrv"], startAt: now.addingTimeInterval(-86400), endAt: now, createdAt: now, expiresAt: now.addingTimeInterval(600), status: "pending", reason: "仅测试", respondedAt: nil, readAt: nil)
        // Keep the synthetic sample clearly inside the serialized request bound;
        // JSON millisecond precision must not turn this into an endpoint overrun.
        reader.snapshotValue = .init(capturedAt: Date(), metrics: [.init(id: "hrv", title: "HRV", value: 40, unit: "毫秒", sampledAt: now.addingTimeInterval(-2), detail: "本机说明", source: "测试来源")])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HealthMockProtocol.self]
        session = URLSession(configuration: config)
        store = CoveStore(session: session, credentials: HealthMockCredentials(), healthReader: reader,
                          healthArchive: CoveHealthArchive(directoryURL: nil))
        store.serverURL = "https://cove-health-unit-\(UUID().uuidString.lowercased()).invalid"
        store.accessToken = "fake-unit-test"
        let scenario = HealthConsentScenario(request: requestItem)
        scenarioBox = scenario
        HealthMockProtocol.handler = { try scenario.reply($0) }
    }
    private var scenarioBox: HealthConsentScenario!
    override func tearDown() async throws {
        store.suspend(); session.invalidateAndCancel(); HealthMockProtocol.handler = nil
        if let previousSharing { UserDefaults.standard.set(previousSharing, forKey: "cove.healthSharing") }
        else { UserDefaults.standard.removeObject(forKey: "cove.healthSharing") }
        if let previousURL { UserDefaults.standard.set(previousURL, forKey: "cove.serverURL") }
        else { UserDefaults.standard.removeObject(forKey: "cove.serverURL") }
    }
    func testManualReadNeverUploadsEvenWithLegacySharingEnabled() async {
        UserDefaults.standard.set(true, forKey: "cove.healthSharing")
        await store.syncHealth()
        XCTAssertEqual(reader.authorized, [CoveHealthScope.metricIDs])
        XCTAssertEqual(store.health?.metrics.first?.value, 40)
        XCTAssertEqual(scenarioBox.postCount, 0)
        XCTAssertEqual(scenarioBox.requestCount, 0)
        XCTAssertEqual(store.healthArchiveEntries.count, 1)
        XCTAssertEqual(store.healthArchiveEntries.first?.sharingState, .localOnly)
    }
    func testStandingGrantOnConnectReadsAndUploadsWithoutConsentCard() async {
        scenarioBox.standingEnabled = true
        await store.connect()
        await settleAutomaticHealth()
        XCTAssertTrue(store.healthSharingEnabled)
        XCTAssertTrue(store.healthDataAccessKnown)
        XCTAssertEqual(reader.authorized, [CoveHealthRefreshPolicy.metricIDs])
        XCTAssertEqual(scenarioBox.standingUploads, 1)
        XCTAssertEqual(scenarioBox.postCount, 0, "No one-time request response should be fabricated.")
        XCTAssertTrue(store.healthArchiveEntries.isEmpty, "Exact server readback should drain the local pending queue.")
        XCTAssertNotNil(store.healthSyncedAt)
        await store.refresh()
        XCTAssertEqual(scenarioBox.standingUploads, 1, "Routine polling should not upload duplicate reads every few seconds.")
    }

    func testStandingGrantAutomaticallyFulfillsScopedHealthRequest() async {
        scenarioBox.standingEnabled = true
        scenarioBox.presentPendingWhileStanding = true
        await store.connect()
        for _ in 0..<200 {
            if scenarioBox.postCount == 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(scenarioBox.postCount, 1, store.healthRequestErrors[requestItem.id] ?? "no recorded error")
        XCTAssertEqual(scenarioBox.lastBody?["decision"] as? String, "allow")
        XCTAssertTrue(reader.authorized.contains(["hrv"]))
        XCTAssertTrue(reader.ranges.contains {
            guard $0.0 == ["hrv"], let startAt = $0.1 else { return false }
            return abs(startAt.timeIntervalSince(requestItem.startAt)) < 1
                && abs($0.2.timeIntervalSince(requestItem.endAt)) < 1
        })
        XCTAssertEqual(store.healthRequests.first?.status, "allowed")
    }

    func testStandingGrantUploadsExistingLocalHistory() async {
        await store.syncHealth()
        XCTAssertEqual(store.healthArchiveEntries.first?.sharingState, .localOnly)
        scenarioBox.standingEnabled = true
        await store.connect()
        await settleAutomaticHealth(minimumAuthorizations: 2)
        XCTAssertEqual(scenarioBox.standingUploads, 2)
        XCTAssertTrue(store.healthArchiveEntries.isEmpty)
    }

    func testStandingPostUnknownStillDrainsAfterExactReadback() async {
        scenarioBox.standingEnabled = true
        scenarioBox.standingPostUnknown = true
        await store.connect()
        await settleAutomaticHealth()
        XCTAssertEqual(scenarioBox.standingUploads, 1)
        XCTAssertTrue(store.healthArchiveEntries.isEmpty)
        XCTAssertNotNil(store.healthSyncedAt)
    }

    func testOldStandingPostACKCannotCommitAfterPreviewRevokesGeneration() async {
        scenarioBox.standingEnabled = true
        scenarioBox.standingPostDelay = 0.15
        await store.connect()
        for _ in 0..<200 {
            if scenarioBox.standingUploads == 1 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        store.enablePreview()
        let previewSyncedAt = store.healthSyncedAt
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(store.healthSyncedAt, previewSyncedAt,
                       "An ACK from the prior service generation must not replace current preview state.")
        XCTAssertEqual(scenarioBox.uploadReadbacks, 0)
    }

    func testStandingReadbackMismatchOr404KeepsPendingCopy() async {
        scenarioBox.standingEnabled = true
        scenarioBox.mutateUploadReadback = true
        await store.connect()
        await settleAutomaticHealth()
        XCTAssertEqual(store.healthArchiveEntries.count, 1)
        XCTAssertEqual(store.healthArchiveEntries.first?.sharingState, .deliveryUnknown)

        scenarioBox.mutateUploadReadback = false
        scenarioBox.uploadReadbackStatus = 404
        await store.refresh()
        XCTAssertEqual(store.healthArchiveEntries.count, 1)
    }

    func testReconnectFlushesPendingWithoutAnotherHealthKitReadOrBudgetAttempt() async {
        scenarioBox.standingEnabled = true
        scenarioBox.uploadReadbackStatus = 404
        await store.connect()
        await settleAutomaticHealth()
        XCTAssertEqual(reader.ranges.count, 1)
        XCTAssertEqual(store.healthArchiveEntries.count, 1)

        scenarioBox.uploadReadbackStatus = 200
        await store.refresh()
        XCTAssertEqual(reader.ranges.count, 1, "Queue retry must not trigger another HealthKit read or consume budget.")
        XCTAssertTrue(store.healthArchiveEntries.isEmpty)
    }

    func testArchiveWriteFailureKeepsConfirmedSnapshotInMemory() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("cove-health-primary-write-\(UUID().uuidString)")
        try Data("blocks-directory".utf8).write(to: parent)
        defer { try? FileManager.default.removeItem(at: parent) }
        let blockedArchive = CoveHealthArchive(directoryURL: parent.appendingPathComponent("archive"))
        let blockedStore = CoveStore(session: session, credentials: HealthMockCredentials(), healthReader: reader,
                                     healthArchive: blockedArchive, healthRefreshDefaults: UserDefaults.standard)
        blockedStore.serverURL = store.serverURL; blockedStore.accessToken = "fake-unit-test"
        scenarioBox.standingEnabled = true
        await blockedStore.connect()
        for _ in 0..<200 {
            if !reader.authorized.isEmpty && !blockedStore.isSyncingHealth { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(blockedStore.healthArchiveEntries.count, 1,
                       "Memory must not drop the entry before the atomically persisted removal succeeds.")
        XCTAssertNotNil(blockedStore.healthArchiveError)
        blockedStore.suspend()
    }

    func testConfirmedRevokeStopsAutomaticReadAndUpload() async {
        scenarioBox.standingEnabled = true
        await store.connect()
        await settleAutomaticHealth()
        await store.setHealthDataAccess(enabled: false)
        XCTAssertFalse(store.healthSharingEnabled)
        let reads = reader.ranges.count, uploads = scenarioBox.standingUploads
        await store.resume()
        XCTAssertEqual(reader.ranges.count, reads)
        XCTAssertEqual(scenarioBox.standingUploads, uploads)
    }

    func testFailedRevokeIsNotShownAsSuccessAndPausesUploads() async {
        scenarioBox.standingEnabled = true
        await store.connect()
        await settleAutomaticHealth()
        scenarioBox.failDataAccessUpdate = true
        await store.setHealthDataAccess(enabled: false)
        XCTAssertTrue(store.healthSharingEnabled, "Do not pretend a failed server revoke succeeded.")
        XCTAssertTrue(store.healthDataAccessStatus.contains("关闭未确认"))
        let reads = reader.ranges.count
        await store.resume()
        XCTAssertEqual(reader.ranges.count, reads)
    }

    func testPreviewDuringStandingAuthorizationPreventsReadAndUpload() async {
        scenarioBox.standingEnabled = true
        reader.afterAuthorization = { [weak store] in store?.enablePreview() }
        await store.connect()
        await settleAutomaticHealth()
        XCTAssertTrue(reader.ranges.isEmpty)
        XCTAssertEqual(scenarioBox.standingUploads, 0)
        XCTAssertFalse(store.healthSharingEnabled)
    }

    private func settleAutomaticHealth(minimumAuthorizations: Int = 1) async {
        for _ in 0..<200 {
            if reader.authorized.count >= minimumAuthorizations && !store.isSyncingHealth { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Scheduled automatic health task did not settle")
    }

    func testReconnectAndObserverBurstDoNotResetAutomaticBudget() async {
        scenarioBox.standingEnabled = true
        await store.connect()
        await settleAutomaticHealth()
        XCTAssertEqual(reader.observedMetrics, CoveHealthRefreshPolicy.metricIDs)
        XCTAssertEqual(reader.ranges.count, 1)
        for _ in 0..<5 { reader.onHealthChange?() }
        await store.connect()
        await store.refresh()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reader.ranges.count, 1, "Reconnect must use the persisted budget, not reset a 60-second timer.")
        XCTAssertEqual(scenarioBox.standingUploads, 1)
        await store.syncHealth()
        XCTAssertEqual(reader.ranges.count, 2, "Explicit on-demand reads remain available.")
        XCTAssertEqual(reader.ranges.last?.0, CoveHealthScope.metricIDs)
    }

    func testChatConnectReturnsWhileHealthReadIsStillPending() async {
        scenarioBox.standingEnabled = true
        var releaseRead: CheckedContinuation<Void, Never>?
        reader.beforeSnapshot = { await withCheckedContinuation { releaseRead = $0 } }
        await store.connect()
        for _ in 0..<200 {
            if releaseRead != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(store.isConnected, "Chat must be usable without waiting for HealthKit.")
        XCTAssertTrue(store.canSendMessages)
        XCTAssertNotNil(releaseRead)
        XCTAssertTrue(store.isSyncingHealth)
        XCTAssertEqual(scenarioBox.standingUploads, 0)
        store.suspend()
        releaseRead?.resume()
        for _ in 0..<200 {
            if !store.isSyncingHealth { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(scenarioBox.standingUploads, 0, "Background/cancelled read must not upload after it returns.")
        XCTAssertTrue(store.healthArchiveEntries.isEmpty)
    }

    func testRelaunchUsesPersistedAutomaticBudget() async {
        scenarioBox.standingEnabled = true
        await store.connect()
        await settleAutomaticHealth()
        let endpoint = store.serverURL
        store.suspend()
        let nextReader = HealthMockReader()
        let next = CoveStore(session: session, credentials: HealthMockCredentials(), healthReader: nextReader,
                             healthArchive: CoveHealthArchive(directoryURL: nil))
        next.serverURL = endpoint; next.accessToken = "fake-unit-test"
        await next.connect()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(nextReader.ranges.isEmpty, "Relaunch must not reread unchanged health data.")
        next.suspend()
    }

    func testDenyDoesNotAuthorizeOrReadHealth() async {
        await store.connect()
        await store.respondToHealthRequest(requestItem, allow: false)
        XCTAssertTrue(reader.authorized.isEmpty)
        XCTAssertTrue(reader.ranges.isEmpty)
        XCTAssertEqual(scenarioBox.lastBody?["decision"] as? String, "deny")
        XCTAssertNil(scenarioBox.lastBody?["snapshot"])
        XCTAssertEqual(store.healthRequests.first?.status, "denied")
        XCTAssertTrue(store.healthArchiveEntries.isEmpty)
    }
    func testAllowReadsOnlyDisplayedScopeAndStripsLocalDetail() async throws {
        await store.connect()
        await store.respondToHealthRequest(requestItem, allow: true)
        XCTAssertEqual(reader.authorized, [["hrv"]])
        XCTAssertEqual(reader.ranges.first?.1, requestItem.startAt)
        XCTAssertEqual(reader.ranges.first?.2, requestItem.endAt)
        let snapshot = try XCTUnwrap(scenarioBox.lastBody?["snapshot"] as? [String: Any])
        let metrics = try XCTUnwrap(snapshot["metrics"] as? [[String: Any]])
        XCTAssertEqual(metrics.map { $0["id"] as? String }, ["hrv"])
        XCTAssertNil(metrics.first?["detail"])
        XCTAssertNil(store.healthRequests.first?.readAt)
        XCTAssertEqual(store.healthArchiveEntries.count, 1)
        XCTAssertEqual(store.healthArchiveEntries.first?.origin, .request)
        XCTAssertEqual(store.healthArchiveEntries.first?.requestStartAt, requestItem.startAt)
        XCTAssertEqual(store.healthArchiveEntries.first?.requestEndAt, requestItem.endAt)
        XCTAssertEqual(store.healthArchiveEntries.first?.sharingState, .shared)
    }
    func testSwitchConversationDuringAuthorizationNeverUploads() async {
        await store.connect()
        reader.afterAuthorization = { [weak store] in store?.activeConversationID = "different" }
        await store.respondToHealthRequest(requestItem, allow: true)
        XCTAssertEqual(scenarioBox.postCount, 0)
        XCTAssertTrue(reader.ranges.isEmpty, "Changing conversation during authorization must prevent even starting the query.")
        XCTAssertTrue(store.healthArchiveEntries.isEmpty)
    }
    func testWithdrawWhileAuthorizingNeverUploads() async {
        await store.connect()
        let id = requestItem.id
        reader.afterAuthorization = { [weak store] in store?.cancelHealthRequestRead(id) }
        await store.respondToHealthRequest(requestItem, allow: true)
        XCTAssertEqual(scenarioBox.postCount, 0)
        XCTAssertTrue(reader.ranges.isEmpty, "Withdrawing during authorization must prevent even starting the query.")
        XCTAssertTrue(store.healthArchiveEntries.isEmpty)
    }
    func testLostACKDoesNotAutomaticallyResendHealth() async {
        await store.connect()
        scenarioBox.failResponse = true
        await store.respondToHealthRequest(requestItem, allow: true)
        await store.refreshHealthRequests()
        XCTAssertEqual(scenarioBox.postCount, 1)
        XCTAssertEqual(store.healthRequests.first?.status, "allowed")
        XCTAssertNotNil(store.healthRequestErrors[requestItem.id])
        XCTAssertEqual(store.healthArchiveEntries.first?.sharingState, .deliveryUnknown,
                       "Status-only GET cannot prove this local snapshot was the one accepted, even for the same request.")
    }

    func testAnotherDeviceAllowedRequestButLocalPOSTConflictRemainsUnknown() async {
        await store.connect()
        scenarioBox.conflictResponse = true
        await store.respondToHealthRequest(requestItem, allow: true)
        await store.refreshHealthRequests()
        XCTAssertEqual(scenarioBox.postCount, 1)
        XCTAssertEqual(store.healthRequests.first?.status, "allowed")
        XCTAssertEqual(store.healthArchiveEntries.count, 1)
        XCTAssertEqual(store.healthArchiveEntries.first?.sharingState, .deliveryUnknown,
                       "Another device's allowed snapshot must not be attributed to this rejected local attempt.")
    }

    func testEnteringPreviewDuringManualAuthorizationPreventsHealthQuery() async {
        reader.afterAuthorization = { [weak store] in store?.enablePreview() }
        await store.syncHealth()
        XCTAssertTrue(reader.ranges.isEmpty)
        XCTAssertTrue(store.healthArchiveEntries.isEmpty)
        XCTAssertEqual(scenarioBox.requestCount, 0)
    }

    func testEnteringPreviewDuringRequestAuthorizationPreventsHealthQuery() async {
        await store.connect()
        reader.afterAuthorization = { [weak store] in store?.enablePreview() }
        await store.respondToHealthRequest(requestItem, allow: true)
        XCTAssertTrue(reader.ranges.isEmpty)
        XCTAssertTrue(store.healthArchiveEntries.isEmpty)
        XCTAssertEqual(scenarioBox.postCount, 0)
    }

    func testLostACKStaysUnknownWhenStatusUnavailableAndOtherServiceCannotConfirmIt() async {
        await store.connect()
        scenarioBox.failResponse = true
        scenarioBox.failHealthRefresh = true
        await store.respondToHealthRequest(requestItem, allow: true)
        XCTAssertEqual(store.healthArchiveEntries.first?.sharingState, .deliveryUnknown)
        XCTAssertEqual(scenarioBox.postCount, 1)
        scenarioBox.failHealthRefresh = false
        store.serverURL = "https://cove-health-other-\(UUID().uuidString.lowercased()).invalid"
        store.accessToken = "another-fake-token"
        await store.connect()
        XCTAssertEqual(store.healthRequests.first?.status, "allowed")
        XCTAssertEqual(store.healthArchiveEntries.first?.sharingState, .deliveryUnknown,
                       "An identical request ID on another service must not confirm this archive's sharing status.")
        XCTAssertEqual(scenarioBox.postCount, 1)
    }

    func testDeletingServerCopiesDoesNotDeleteLocalHistory() async {
        await store.connect()
        await store.respondToHealthRequest(requestItem, allow: true)
        await store.deleteSharedHealth()
        XCTAssertEqual(store.healthArchiveEntries.count, 1)
        XCTAssertEqual(store.healthArchiveEntries.first?.sharingState, .removedFromServer)
        XCTAssertEqual(store.healthHistory.count, 1)
        XCTAssertEqual(store.health?.metrics.first?.value, 40)
    }
}

private final class HealthConsentScenario: @unchecked Sendable {
    private var item: CoveHealthRequest
    private let lock = NSLock()
    var postCount = 0
    var requestCount = 0
    var lastBody: [String: Any]?
    var failResponse = false
    var conflictResponse = false
    var failHealthRefresh = false
    var standingEnabled = false
    var presentPendingWhileStanding = false
    var standingUploads = 0
    var failDataAccessUpdate = false
    var standingPostUnknown = false
    var standingPostDelay: TimeInterval = 0
    var uploadReadbackStatus = 200
    var mutateUploadReadback = false
    var uploadReadbacks = 0
    private var uploadedSnapshot: HealthSnapshot?
    init(request: CoveHealthRequest) { item = request }
    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
    func reply(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        requestCount += 1
        let path = request.url!.path
        if path == "/v1/data-access" {
            if request.httpMethod == "POST" {
                if failDataAccessUpdate { throw URLError(.networkConnectionLost) }
                let data = Self.body(request)
                standingEnabled = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["enabled"] as? Bool ?? false
            }
            return (200, try JSONSerialization.data(withJSONObject: ["enabled": standingEnabled]))
        }
        if path == "/v1/health", request.httpMethod == "POST" {
            let body = try JSONSerialization.jsonObject(with: Self.body(request)) as? [String: Any]
            guard standingEnabled, body?["standingAccess"] as? Bool == true, body?["snapshot"] != nil else {
                return (403, Data(#"{"error":"standing access disabled"}"#.utf8))
            }
            uploadedSnapshot = try CoveJSON.decoder().decode(HealthSnapshot.self,
                from: JSONSerialization.data(withJSONObject: body!["snapshot"]!))
            standingUploads += 1
            if standingPostDelay > 0 { Thread.sleep(forTimeInterval: standingPostDelay) }
            if standingPostUnknown { throw URLError(.networkConnectionLost) }
            return (200, Data(#"{"ok":true,"syncedAt":"2026-09-22T00:00:00Z"}"#.utf8))
        }
        if path == "/v1/health/uploads", request.httpMethod == "GET" {
            uploadReadbacks += 1
            guard uploadReadbackStatus == 200, var snapshot = uploadedSnapshot else {
                return (uploadReadbackStatus, Data(#"{"error":"not found"}"#.utf8))
            }
            if mutateUploadReadback, !snapshot.metrics.isEmpty { snapshot.metrics[0].source = "different-source" }
            return (200, try JSONSerialization.data(withJSONObject: [
                "snapshot": JSONSerialization.jsonObject(with: CoveJSON.encoder().encode(snapshot)),
                "syncedAt": "2026-09-22T00:00:00Z"
            ]))
        }
        if request.httpMethod == "POST", path.hasSuffix("/response") {
            postCount += 1
            var bytes = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; bytes.append(buffer, count: count)
                }
            }
            lastBody = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            item.status = lastBody?["decision"] as? String == "allow" ? "allowed" : "denied"
            if conflictResponse { return (409, Data(#"{"error":"already answered on another device"}"#.utf8)) }
            if failResponse { throw URLError(.networkConnectionLost) }
            return (200, try JSONSerialization.data(withJSONObject: ["ok": true, "request": JSONSerialization.jsonObject(with: CoveJSON.encoder().encode(item))]))
        }
        if path.hasSuffix("/health-requests") {
            if failHealthRefresh { throw URLError(.networkConnectionLost) }
            let requests: [Any] = standingEnabled && !presentPendingWhileStanding
                ? []
                : [try JSONSerialization.jsonObject(with: CoveJSON.encoder().encode(item))]
            return (200, try JSONSerialization.data(withJSONObject: ["requests": requests]))
        }
        if path == "/v1/health", request.httpMethod == "DELETE" { return (200, Data(#"{"ok":true}"#.utf8)) }
        if path == "/v1/conversations" { return (200, Data(#"{"conversations":[{"id":"ours","title":"Unit","createdAt":"2026-09-14T00:00:00Z"}],"activeConversationID":"ours"}"#.utf8)) }
        if path == "/v1/messages" { return (200, Data(#"{"messages":[],"cursor":0,"busy":false}"#.utf8)) }
        return (404, Data("{}".utf8))
    }
}
