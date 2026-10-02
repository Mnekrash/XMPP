import AppSecurity
import Authentication
import Domain
import Networking
import SwiftUI
import UI
import XMPPTransport

@main
struct MessengerApp: App {
    private let model: AppModel?

    init() {
        guard let config = try? ServerConfig(infoDictionary: Bundle.main.infoDictionary ?? [:]) else {
            model = nil
            return
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "messenger"
        let connection = AccountConnection(config: config, resource: Self.installResource())
        let auth = XMPPAuthService(connection: connection,
                                   credentials: KeychainCredentialStore(service: bundleID + ".credentials"),
                                   appVersion: Self.version)
        #if DEMO_MODE
        // DemoMode (Development only): "demo"/"demo" opens sample chats without any server access.
        model = AppModel(auth: DemoModeAuthService(inner: auth), diagnostics: auth)
        #else
        model = AppModel(auth: auth, diagnostics: auth)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            if let model {
                #if DEMO_MODE
                DemoModeRoot(model: model)
                #else
                RootView(model: model)
                #endif
            } else {
                ContentUnavailableView(
                    "Не удалось запустить",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Сборка настроена неверно. Установите последнюю версию приложения.")
                )
            }
        }
    }

    /// Stable, random per-install connection label (not shown to users, not secret).
    private static func installResource() -> String {
        let key = "connectionResource"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let value = "ios-" + UUID().uuidString.prefix(8).lowercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }
}
