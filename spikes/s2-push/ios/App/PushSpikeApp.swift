import SwiftUI
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var onToken: ((Data) -> Void)?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        SharedStore.log("launched (remote notification: \(launchOptions?[.remoteNotification] != nil))", source: "app")
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        SharedStore.log("APNs token \(hex.prefix(8))… (\(deviceToken.count) bytes)", source: "app")
        Self.onToken?(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        SharedStore.log("APNs registration failed: \(error)", source: "app")
    }

    // Foreground presentation: log it (expected: no push while the XMPP session is live) and show a banner.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        SharedStore.log("push presented in FOREGROUND: title=\(notification.request.content.title)", source: "app")
        return [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        SharedStore.log("notification tapped", source: "app")
    }
}

@main
struct PushSpikeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase
    @State private var model = SpikeModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .onChange(of: phase) { _, newPhase in
            Task { await model.scenePhaseChanged(newPhase) }
        }
    }
}
