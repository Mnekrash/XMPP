import AppSecurity
import Domain
import Foundation
import XMPPTransport

public actor XMPPAuthService: AuthService, DiagnosticsProviding {
    private let connection: AccountConnection
    private let credentials: CredentialStore
    private let appVersion: String
    private var current: StoredCredentials?
    private var reconnectTask: Task<Void, Never>?
    private var wantsConnection = false
    private var watchTask: Task<Void, Never>?

    public init(connection: AccountConnection, credentials: CredentialStore, appVersion: String) {
        self.connection = connection
        self.credentials = credentials
        self.appVersion = appVersion
    }

    // MARK: AuthService

    public func logIn(username: String, password: String) async throws(UserFacingError) -> AccountInfo {
        let user = Self.normalize(username)
        guard !user.isEmpty, !password.isEmpty else { throw .invalidCredentials }
        do {
            try await connection.connect(username: user, password: password)
        } catch {
            throw Self.userError(error)
        }
        let creds = StoredCredentials(username: user, password: password)
        try? credentials.save(creds)
        current = creds
        startWatching()
        return await accountInfo(username: user)
    }

    public func restoreSession() async -> AccountInfo? {
        guard let saved = credentials.load() else { return nil }
        do {
            try await connection.connect(username: saved.username, password: saved.password)
        } catch TransportError.notAuthorized, TransportError.accountDisabled {
            credentials.delete()   // password changed or account disabled elsewhere → back to login
            return nil
        } catch {
            // Offline at launch: open the app with the saved account and keep trying in the background.
            current = saved
            startWatching()
            scheduleReconnect()
            return AccountInfo(username: saved.username, displayName: nil, mustChangePassword: false)
        }
        current = saved
        startWatching()
        return await accountInfo(username: saved.username)
    }

    public func changePassword(to newPassword: String) async throws(UserFacingError) {
        guard newPassword.count >= 10 else { throw .weakPassword }
        do {
            try await connection.changePassword(newPassword)
        } catch TransportError.weakPassword {
            throw .weakPassword
        } catch {
            throw Self.userError(error)
        }
        if let user = current?.username {
            let updated = StoredCredentials(username: user, password: newPassword)
            try? credentials.save(updated)
            current = updated
        }
        await connection.clearMustChangePassword()
    }

    public func logOut() async {
        wantsConnection = false
        reconnectTask?.cancel()
        watchTask?.cancel()
        credentials.delete()
        current = nil
        await connection.disconnect()
    }

    public func connectionStates() async -> AsyncStream<ConnectionState> {
        let source = connection.states()
        return AsyncStream { continuation in
            let task = Task {
                for await state in source {
                    switch state {
                    case .connected: continuation.yield(.online)
                    case .connecting: continuation.yield(.connecting)
                    case .disconnected: continuation.yield(.offline)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func resume() async {
        guard current != nil, connection.state == .disconnected else { return }
        await reconnectNow()
    }

    // MARK: Reconnect (simple backoff; full connection management comes with the S1/S4 transport work)

    private func startWatching() {
        wantsConnection = true
        watchTask?.cancel()
        let states = connection.states()
        watchTask = Task { [weak self] in
            for await state in states where state == .disconnected {
                await self?.scheduleReconnect()
            }
        }
    }

    private func scheduleReconnect() {
        guard wantsConnection, reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            var delay: UInt64 = 2
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                guard let self, await self.shouldReconnect() else { break }
                if await self.reconnectNow() { break }
                delay = min(delay * 2, 60)
            }
            await self?.reconnectFinished()
        }
    }

    private func shouldReconnect() -> Bool { wantsConnection && connection.state == .disconnected }
    private func reconnectFinished() { reconnectTask = nil }

    @discardableResult
    private func reconnectNow() async -> Bool {
        guard let creds = current else { return false }
        do {
            try await connection.connect(username: creds.username, password: creds.password)
            return true
        } catch TransportError.notAuthorized, TransportError.accountDisabled {
            wantsConnection = false   // the password no longer works; the UI shows the login screen on next launch
            credentials.delete()
            return true
        } catch {
            return false
        }
    }

    // MARK: Helpers

    private func accountInfo(username: String) async -> AccountInfo {
        AccountInfo(username: username, displayName: await connection.displayName(),
                    mustChangePassword: await connection.mustChangePassword())
    }

    /// Users type just their login; "login@anything" is accepted and reduced to the login.
    static func normalize(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return String(trimmed.split(separator: "@", maxSplits: 1).first ?? "")
    }

    static func userError(_ error: Error) -> UserFacingError {
        switch error as? TransportError {
        case .notAuthorized: .invalidCredentials
        case .accountDisabled: .accountDisabled
        case .unreachable, .certificate: .cannotConnect
        case .weakPassword: .weakPassword
        default: .unknown
        }
    }

    // MARK: Diagnostics

    public func diagnostics() async -> [DiagnosticsEntry] {
        var entries = connection.diagnostics().map { DiagnosticsEntry($0.0, $0.1) }
        entries.append(DiagnosticsEntry("Authenticated", connection.state == .connected ? "yes" : "no"))
        entries.append(DiagnosticsEntry("Push token", "not registered (S2)"))
        entries.append(DiagnosticsEntry("OMEMO device ID", "not created (Phase 5)"))
        entries.append(DiagnosticsEntry("App version", appVersion))
        return entries
    }
}
