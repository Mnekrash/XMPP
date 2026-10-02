import Combine
import Foundation
import Martin
import Networking

public enum TransportState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
}

public enum TransportError: Error, Sendable, Equatable {
    case notAuthorized
    /// <account-disabled/> (e.g. `admin.sh disable`); recovered via SaslFailureWorkaround.
    case accountDisabled
    case unreachable
    case certificate
    case weakPassword
    case failed(String)
}

/// One XMPP account connection (login, state, small account IQs). Thread-safe via a lock;
/// Martin does its own internal dispatching.
public final class AccountConnection: @unchecked Sendable {
    private let config: ServerConfig
    private let resource: String
    private let lock = NSLock()
    private var client: XMPPClient?
    private var stateCancellable: AnyCancellable?
    private var observers: [UUID: AsyncStream<TransportState>.Continuation] = [:]
    private var _state: TransportState = .disconnected
    private var lastDisconnect: String = "—"
    private let saslObserver = SaslFailureObserver()   // Martin defect workaround (SaslFailureWorkaround.swift)

    private static let flagNamespace = "urn:x-messenger:account"

    public init(config: ServerConfig, resource: String) {
        self.config = config
        self.resource = resource
    }

    public var state: TransportState { lock.withLock { _state } }

    public func states() -> AsyncStream<TransportState> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.withLock {
                observers[id] = continuation
                continuation.yield(_state)
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.observers.removeValue(forKey: id) }
            }
        }
    }

    private func publish(_ new: TransportState) {
        let targets: [AsyncStream<TransportState>.Continuation] = lock.withLock {
            guard _state != new else { return [] }
            _state = new
            return Array(observers.values)
        }
        targets.forEach { $0.yield(new) }
    }

    // MARK: Login

    public func connect(username: String, password: String) async throws {
        await disconnect()
        let c = XMPPClient()
        c.connectionConfiguration.userJid = BareJID(localPart: username, domain: config.xmppDomain)
        c.connectionConfiguration.resource = resource
        c.connectionConfiguration.credentials = .password(password: password, authenticationName: nil, cache: nil)
        var options = SocketConnectorNetwork.Options()
        options.connectionDetails = .init(proto: .XMPPS, host: config.xmppHost, port: Int(config.xmppPort))
        options.connectionTimeout = 15
        c.connectionConfiguration.connectorOptions = options
        _ = c.modulesManager.register(StreamFeaturesModule())
        _ = c.modulesManager.register(SaslModule())
        _ = c.modulesManager.register(AuthModule())
        _ = c.modulesManager.register(ResourceBinderModule())
        _ = c.modulesManager.register(SessionEstablishmentModule())
        _ = c.modulesManager.register(StreamManagementModule())
        _ = c.modulesManager.register(DiscoveryModule())
        _ = c.modulesManager.register(PresenceModule())

        saslObserver.reset()
        c.streamLogger = saslObserver   // workaround hook; Martin keeps a weak reference, we own the observer
        lock.withLock { client = c }
        stateCancellable = c.$state.sink { [weak self] state in
            guard let self else { return }
            switch state {
            case .connecting, .disconnecting:
                self.publish(.connecting)
            case .connected:
                self.publish(.connected)
            case .disconnected(let reason):
                self.lock.withLock { self.lastDisconnect = "\(reason)" }
                self.publish(.disconnected)
            }
        }
        publish(.connecting)
        do {
            try await c.loginAndWait()
        } catch {
            throw Self.map(error, saslCondition: saslObserver.lastCondition)
        }
    }

    public func disconnect() async {
        let c: XMPPClient? = lock.withLock { client }
        try? await c?.disconnect(force: false)
        stateCancellable = nil
        lock.withLock { client = nil }
        publish(.disconnected)
    }

    static func map(_ error: Error, saslCondition: SaslFailureCondition? = nil) -> TransportError {
        if let reason = error as? XMPPClient.State.DisconnectionReason {
            switch reason {
            case .authenticationFailure:
                return saslCondition == .accountDisabled ? .accountDisabled : .notAuthorized
            case .sslCertError:
                return .certificate
            case .timeout, .noRouteToServer:
                return .unreachable
            default:
                return .failed("\(reason)")
            }
        }
        return .failed("\(error)")
    }

    // MARK: Account data

    private func connectedClient() throws -> XMPPClient {
        guard let c = lock.withLock({ client }), state == .connected else { throw TransportError.unreachable }
        return c
    }

    /// FN from the account's vCard (set by the administrator), if any.
    public func displayName() async -> String? {
        guard let c = try? connectedClient() else { return nil }
        let iq = Iq()
        iq.type = .get
        iq.addChild(Element(name: "vCard", xmlns: "vcard-temp"))
        guard let response = try? await c.writer.write(iq: iq) else { return nil }
        let name = response.findChild(name: "vCard", xmlns: "vcard-temp")?.findChild(name: "FN")?.value
        return name?.isEmpty == false ? name : nil
    }

    /// Reads the administrator's "must change password" flag from private XML storage (XEP-0049).
    public func mustChangePassword() async -> Bool {
        guard let c = try? connectedClient() else { return false }
        let iq = Iq()
        iq.type = .get
        let query = Element(name: "query", xmlns: "jabber:iq:private")
        query.addChild(Element(name: "account", xmlns: Self.flagNamespace))
        iq.addChild(query)
        guard let response = try? await c.writer.write(iq: iq) else { return false }
        let flag = response.findChild(name: "query", xmlns: "jabber:iq:private")?
            .findChild(name: "account", xmlns: Self.flagNamespace)?.attributes["must-change-password"]
        return flag == "true"
    }

    /// In-band password change of the logged-in account (XEP-0077); registration itself is closed server-side.
    public func changePassword(_ newPassword: String) async throws {
        let c = try connectedClient()
        let iq = Iq()
        iq.type = .set
        iq.to = JID(config.xmppDomain)
        let query = Element(name: "query", xmlns: "jabber:iq:register")
        query.addChild(Element(name: "username", cdata: c.connectionConfiguration.userJid.localPart ?? ""))
        query.addChild(Element(name: "password", cdata: newPassword))
        iq.addChild(query)
        do {
            _ = try await c.writer.write(iq: iq)
        } catch {
            let text = "\(error)"
            throw text.contains("not_acceptable") || text.contains("not-acceptable") ? TransportError.weakPassword
                                                                                       : TransportError.failed(text)
        }
    }

    public func clearMustChangePassword() async {
        guard let c = try? connectedClient() else { return }
        let iq = Iq()
        iq.type = .set
        let query = Element(name: "query", xmlns: "jabber:iq:private")
        let flag = Element(name: "account", xmlns: Self.flagNamespace)
        flag.setAttribute("must-change-password", value: "false")
        query.addChild(flag)
        iq.addChild(query)
        _ = try? await c.writer.write(iq: iq)
    }

    // MARK: Diagnostics (developer screen only)

    public func diagnostics() -> [(String, String)] {
        let c = lock.withLock { client }
        let sm = c?.modulesManager.moduleOrNil(.streamManagement)
        return [
            ("XMPP domain", config.xmppDomain),
            ("Host", "\(config.xmppHost):\(config.xmppPort) (direct TLS)"),
            ("Account", c.map { "\($0.connectionConfiguration.userJid)/\(resource)" } ?? "—"),
            ("Transport state", "\(state)"),
            ("Stream Management", sm.map { "resumption \($0.resumptionEnabled ? "enabled" : "disabled")" } ?? "—"),
            ("Last disconnect reason", lock.withLock { lastDisconnect }),
        ]
    }
}
