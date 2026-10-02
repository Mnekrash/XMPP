import Domain
import Foundation
import Observation

/// UI state of the whole app. Talks only to domain services (no XMPP details).
@MainActor @Observable
public final class AppModel {
    public enum Phase: Equatable {
        case launching
        case loggedOut
        case mustChangePassword(AccountInfo)
        case loggedIn(AccountInfo)
    }

    public private(set) var phase: Phase = .launching
    public private(set) var connection: ConnectionState = .offline

    private let auth: any AuthService
    private let diagnosticsProvider: (any DiagnosticsProviding)?
    private var statesTask: Task<Void, Never>?

    public init(auth: any AuthService, diagnostics: (any DiagnosticsProviding)?) {
        self.auth = auth
        self.diagnosticsProvider = diagnostics
    }

    public func start() async {
        guard phase == .launching else { return }
        observeConnection()
        if let account = await auth.restoreSession() {
            route(account)
        } else {
            phase = .loggedOut
        }
    }

    public func logIn(username: String, password: String) async throws(UserFacingError) {
        let account = try await auth.logIn(username: username, password: password)
        route(account)
    }

    public func changePassword(_ new: String) async throws(UserFacingError) {
        try await auth.changePassword(to: new)
        if case .mustChangePassword(var account) = phase {
            account.mustChangePassword = false
            phase = .loggedIn(account)
        }
    }

    public func logOut() async {
        await auth.logOut()
        phase = .loggedOut
    }

    public func appBecameActive() async {
        await auth.resume()
    }

    public func diagnostics() async -> [DiagnosticsEntry] {
        await diagnosticsProvider?.diagnostics() ?? []
    }

    private func route(_ account: AccountInfo) {
        phase = account.mustChangePassword ? .mustChangePassword(account) : .loggedIn(account)
    }

    private func observeConnection() {
        statesTask = Task { [weak self] in
            guard let self else { return }
            for await state in await self.auth.connectionStates() {
                self.connection = state
            }
        }
    }
}
