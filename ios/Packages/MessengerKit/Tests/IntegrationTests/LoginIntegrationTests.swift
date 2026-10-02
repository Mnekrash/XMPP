import AppSecurity
import Authentication
import Domain
import Foundation
import Networking
import Testing
import XMPPTransport

/// Real login through Martin against a running ejabberd (CI job `ios-integration`, or locally against the dev stack).
/// Enabled only when IT_XMPP_DOMAIN is set; accounts are prepared by .github/scripts/ejabberd-macos.sh:
///   it_ok (password IT_PASSWORD, vCard FN "Integration User", must-change flag set), it_banned (banned).
struct LoginIntegrationTests {
    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["IT_XMPP_DOMAIN"] != nil

    private func service(_ store: CredentialStore = MemoryCredentialStore()) throws -> XMPPAuthService {
        let domain = Self.env["IT_XMPP_DOMAIN"]!
        let config = try ServerConfig(infoDictionary: [
            "MessengerXMPPDomain": domain, "MessengerXMPPHost": Self.env["IT_XMPP_HOST"] ?? domain,
            "MessengerXMPPPort": "5223", "MessengerMUCDomain": "groups." + domain,
            "MessengerPushComponentJID": "push." + domain, "MessengerAppGroup": "group.test",
        ])
        return XMPPAuthService(connection: AccountConnection(config: config, resource: "it-\(UUID().uuidString.prefix(6))"),
                               credentials: store, appVersion: "it")
    }

    /// Transport only: TLS (system trust, server policy) + SASL with the right password. Prints the diagnostics on failure.
    @Test(.enabled(if: enabled)) func transportConnectsAndAuthenticates() async throws {
        let domain = Self.env["IT_XMPP_DOMAIN"]!
        let config = try ServerConfig(infoDictionary: [
            "MessengerXMPPDomain": domain, "MessengerXMPPHost": Self.env["IT_XMPP_HOST"] ?? domain,
            "MessengerXMPPPort": "5223", "MessengerMUCDomain": "groups." + domain,
            "MessengerPushComponentJID": "push." + domain, "MessengerAppGroup": "group.test",
        ])
        let connection = AccountConnection(config: config, resource: "it-transport")
        do {
            try await connection.connect(username: "it_restore", password: Self.env["IT_PASSWORD2"]!)
        } catch {
            Issue.record("connect failed: \(error) · \(connection.diagnostics().map { "\($0.0)=\($0.1)" }.joined(separator: " · "))")
        }
        await connection.disconnect()
    }

    @Test(.enabled(if: enabled)) func wrongPasswordIsInvalidCredentials() async throws {
        let auth = try service()
        await #expect(throws: UserFacingError.invalidCredentials) { try await auth.logIn(username: "it_ok", password: "wrong-password") }
    }

    @Test(.enabled(if: enabled)) func bannedAccountIsReportedAsDisabled() async throws {
        let auth = try service()   // regression for the Martin SASL failure defect (workaround in XMPPTransport)
        await #expect(throws: UserFacingError.accountDisabled) { try await auth.logIn(username: "it_banned", password: "irrelevant-1") }
    }

    @Test(.enabled(if: enabled)) func unreachableServerIsCannotConnect() async throws {
        let config = try ServerConfig(infoDictionary: [
            "MessengerXMPPDomain": "unreachable.invalid", "MessengerXMPPHost": "127.0.0.1", "MessengerXMPPPort": "5999",
            "MessengerMUCDomain": "groups.unreachable.invalid", "MessengerPushComponentJID": "push.unreachable.invalid",
            "MessengerAppGroup": "group.test",
        ])
        let auth = XMPPAuthService(connection: AccountConnection(config: config, resource: "it"),
                                   credentials: MemoryCredentialStore(), appVersion: "it")
        await #expect(throws: UserFacingError.cannotConnect) { try await auth.logIn(username: "it_ok", password: "x") }
    }

    /// Full first-login flow: temporary password → flag → weak rejected → change → relogin → flag cleared → logout.
    @Test(.enabled(if: enabled)) func temporaryPasswordFlow() async throws {
        let store = MemoryCredentialStore()
        let auth = try service(store)
        let temp = Self.env["IT_PASSWORD"]!
        let account = try await auth.logIn(username: "it_ok", password: temp)
        #expect(account.mustChangePassword)
        #expect(account.displayName == "Integration User")
        #expect(store.load() == StoredCredentials(username: "it_ok", password: temp))

        await #expect(throws: UserFacingError.weakPassword) { try await auth.changePassword(to: "short") }
        let newPassword = "Integration-New-Pass-2026!"
        try await auth.changePassword(to: newPassword)
        #expect(store.load()?.password == newPassword)
        await auth.logOut()
        #expect(store.load() == nil)

        let again = try service()
        await #expect(throws: UserFacingError.invalidCredentials) { try await again.logIn(username: "it_ok", password: temp) }
        let relogin = try await again.logIn(username: "it_ok", password: newPassword)
        #expect(!relogin.mustChangePassword)
        await again.logOut()
    }

    @Test(.enabled(if: enabled)) func restoreSessionUsesSavedCredentials() async throws {
        let store = MemoryCredentialStore()
        let password = Self.env["IT_PASSWORD2"]!
        try store.save(StoredCredentials(username: "it_restore", password: password))
        let auth = try service(store)
        let account = await auth.restoreSession()
        #expect(account?.username == "it_restore")
        await auth.logOut()
    }
}
