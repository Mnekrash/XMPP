#if DEMO_MODE
// DemoMode — Development builds only. Visual preview of the app without a server:
// login "demo" / "demo" opens sample chats. No XMPP, no Keychain, no push; nothing is stored.
// Staging/Production exclude every DemoMode*.swift file (project.yml) and CI checks the Production binary.

import Domain
import Foundation
import Observation
import SwiftUI

enum DemoMode {
    static let username = "demo"
    static let password = "demo"
    static let account = AccountInfo(username: "demo", displayName: "Демо Пользователь", mustChangePassword: false)

    static func matches(username: String, password: String) -> Bool {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == Self.username && password == Self.password
    }
}

enum DemoModeAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Системная"
        case .light: "Светлая"
        case .dark: "Тёмная"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// DemoMode state, in memory only (lost on app restart).
@MainActor @Observable
final class DemoModeSession {
    static let shared = DemoModeSession()

    private(set) var isActive = false
    var appearance: DemoModeAppearance = .system
    var chats: [DemoModeChat] = []

    var totalUnread: Int { chats.filter { !$0.muted }.reduce(0) { $0 + $1.unread } }

    func activate() {
        chats = DemoModeSampleData.chats()
        appearance = .system
        isActive = true
    }

    func deactivate() {
        isActive = false
        appearance = .system
        chats = []
    }
}

/// DemoMode: wraps the real AuthService. "demo"/"demo" never reaches it; everything else is passed through unchanged.
struct DemoModeAuthService: AuthService {
    let inner: any AuthService

    private func demoActive() async -> Bool {
        await MainActor.run { DemoModeSession.shared.isActive }
    }

    func logIn(username: String, password: String) async throws(UserFacingError) -> AccountInfo {
        if DemoMode.matches(username: username, password: password) {
            await MainActor.run { DemoModeSession.shared.activate() }
            return DemoMode.account
        }
        return try await inner.logIn(username: username, password: password)
    }

    func restoreSession() async -> AccountInfo? {
        await inner.restoreSession()   // DemoMode is never restored: it is not saved anywhere
    }

    func changePassword(to newPassword: String) async throws(UserFacingError) {
        if await demoActive() { return }
        try await inner.changePassword(to: newPassword)
    }

    func logOut() async {
        if await demoActive() {
            await MainActor.run { DemoModeSession.shared.deactivate() }
            return
        }
        await inner.logOut()
    }

    func connectionStates() async -> AsyncStream<ConnectionState> {
        await inner.connectionStates()
    }

    func resume() async {
        if await demoActive() { return }
        await inner.resume()
    }
}
#endif
