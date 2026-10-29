import SwiftUI
import UserNotifications

@main
struct CoveApp: App {
    @UIApplicationDelegateAdaptor(CoveAppDelegate.self) private var appDelegate
    @StateObject private var store = CoveStore()
    @StateObject private var bluetooth = CoveBluetoothConnection(previewMode: ProcessInfo.processInfo.arguments.contains("--preview"))
    @StateObject private var toyControl = CoveToyControl()
    @StateObject private var launchPresentation: CoveLaunchPresentation
    @Environment(\.scenePhase) private var phase
    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let preview = arguments.contains("--preview")
        let explicitLaunchTest = arguments.contains("--launch-hug-preview")
        _launchPresentation = StateObject(wrappedValue: CoveLaunchPresentation(
            isVisible: (!preview || explicitLaunchTest) && !CoveAppDelegate.launchedFromNotification
        ))
        // Let the current SDK own tab-bar materials, accessibility and contrast.
        // Cove's accent is supplied through SwiftUI tint, not a global appearance.
    }
    var body: some Scene {
        WindowGroup {
            CoveRootView()
                .environmentObject(store)
                .environmentObject(bluetooth)
                .environmentObject(toyControl)
                .overlay {
                    if launchPresentation.isVisible {
                        CoveLaunchHugAnimation(replayID: 0, onFinished: {
                            launchPresentation.dismiss(reason: "completed")
                        }) { EmptyView() }
                        .transition(.identity)
                        .accessibilityIdentifier("launchHug.overlay")
                    }
                }
                .preferredColorScheme(store.appearance == "dark" ? .dark : store.appearance == "light" ? .light : nil)
                .task {
                    toyControl.bind(store: store, bluetooth: bluetooth)
                    appDelegate.store = store
                    appDelegate.launchPresentation = launchPresentation
                    if CoveAppDelegate.launchedFromNotification {
                        launchPresentation.dismiss(reason: "notificationLaunch")
                    }
                    await store.resume()
                }
                .onChange(of: phase) { _, state in
                    if state == .active { Task { await store.resume() } }
                    else if state == .background {
                        toyControl.enteredBackground()
                        launchPresentation.dismiss(reason: "backgrounded")
                        store.suspend()
                    }
                }
                .onChange(of: store.appearance) { _, _ in store.saveSettings() }
                .onChange(of: store.previewMode) { _, enabled in bluetooth.setPreviewMode(enabled) }
                .onChange(of: store.notificationsEnabled) { _, _ in store.saveSettings() }
                .onChange(of: store.notificationPreviewMode) { _, _ in store.saveSettings() }
                .onOpenURL { _ in launchPresentation.dismiss(reason: "deepLink") }
        }
    }
}

final class CoveAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var foregroundPresentationOptions: UNNotificationPresentationOptions { [] }
    static var launchedFromNotification = false
    @MainActor weak var store: CoveStore? {
        didSet {
            if pendingNotificationWake, let store {
                store.receiveRemoteNotification(conversationID: pendingNotificationConversationID,
                                                openConversation: pendingNotificationFocus)
                pendingNotificationWake = false
                pendingNotificationConversationID = nil
                pendingNotificationFocus = false
            }
        }
    }
    @MainActor private(set) var pendingNotificationConversationID: String?
    @MainActor private var pendingNotificationWake = false
    @MainActor private var pendingNotificationFocus = false
    weak var launchPresentation: CoveLaunchPresentation?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Self.launchedFromNotification = launchOptions?[.remoteNotification] != nil
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in await store?.registerDevice(token) }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in store?.errorMessage = "系统通知尚未接通：\(error.localizedDescription)" }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.content.userInfo["conversationID"] as? String
        await MainActor.run {
            launchPresentation?.dismiss(reason: "notificationResponse")
            receiveNotification(conversationID: id, openConversation: true)
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // APNs is a sync hint, not message delivery. A foreground hint can repair
        // a delayed poll but must not steal focus or show a duplicate banner.
        let id = notification.request.content.userInfo["conversationID"] as? String
        await MainActor.run { receiveNotification(conversationID: id, openConversation: false) }
        return Self.foregroundPresentationOptions
    }

    @MainActor func receiveNotification(conversationID: String?, openConversation: Bool) {
        if let store {
            store.receiveRemoteNotification(conversationID: conversationID, openConversation: openConversation)
        } else {
            // Notification callbacks may arrive before SwiftUI installs Store.
            // A foreground hint must not overwrite a queued explicit tap.
            pendingNotificationWake = true
            if openConversation {
                pendingNotificationConversationID = conversationID
                pendingNotificationFocus = true
            }
        }
    }
}
