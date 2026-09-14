import SwiftUI
import UserNotifications

@main
struct CoveApp: App {
    @UIApplicationDelegateAdaptor(CoveAppDelegate.self) private var appDelegate
    @StateObject private var store = CoveStore()
    @Environment(\.scenePhase) private var phase
    init() {
        let inactive = UIColor(CoveStyle.secondaryText)
        let selected = UIColor(CoveStyle.accent)
        let appearance = UITabBarAppearance()
        for item in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            item.normal.iconColor = inactive
            item.normal.titleTextAttributes = [.foregroundColor: inactive]
            item.selected.iconColor = selected
            item.selected.titleTextAttributes = [.foregroundColor: selected]
        }
        UITabBar.appearance().unselectedItemTintColor = inactive
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
    var body: some Scene {
        WindowGroup {
            CoveRootView()
                .environmentObject(store)
                .preferredColorScheme(store.appearance == "dark" ? .dark : store.appearance == "light" ? .light : nil)
                .task { appDelegate.store = store; await store.resume() }
                .onChange(of: phase) { _, state in
                    if state == .active { Task { await store.resume() } }
                    else if state == .background { store.suspend() }
                }
                .onChange(of: store.appearance) { _, _ in store.saveSettings() }
                .onChange(of: store.notificationsEnabled) { _, _ in store.saveSettings() }
        }
    }
}

final class CoveAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var store: CoveStore?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
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
        await MainActor.run { store?.selectedTab = 2 }
        if let id { await store?.selectConversation(id) }
        await store?.refresh()
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        return [.banner, .sound]
    }
}
