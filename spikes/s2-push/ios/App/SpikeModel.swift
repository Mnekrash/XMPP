import CryptoKit
import Foundation
import Martin
import SwiftUI
import UIKit
import UserNotifications

/// Spike flow (docs/spikes/S2-push.md, device runbook):
/// login → APNs token → XEP-0050 register at the gateway → XEP-0357 enable → background: close the socket →
/// pushes arrive → foreground: reconnect + re-enable (S2 finding p04).
@MainActor @Observable
final class SpikeModel {
    var host = "chat.staging.example.com"
    var jid = ""
    var password = ""
    var gatewayJid = "push.chat.staging.example.com"
    var namesText = "alice@chat.staging.example.com=Alice Smith"
    var status = "disconnected"
    var log: [String] = []
    var nseMode = SharedStore.nseFailureMode

    private var client: XMPPClient?
    private var token: String?

    func append(_ s: String) {
        log.append("\(Date().formatted(date: .omitted, time: .standard)) \(s)")
        SharedStore.log(s, source: "app")
    }

    // MARK: Connect + push setup

    func connect() async {
        saveNames()
        let c = XMPPClient()
        c.connectionConfiguration.userJid = BareJID(jid)
        c.connectionConfiguration.credentials = .password(password: password, authenticationName: nil, cache: nil)
        var options = SocketConnectorNetwork.Options()
        options.connectionDetails = .init(proto: .XMPPS, host: host, port: 5223)
        c.connectionConfiguration.connectorOptions = options
        for m: XmppModule in [StreamFeaturesModule(), SaslModule(), AuthModule(), ResourceBinderModule(),
                              SessionEstablishmentModule(), StreamManagementModule(), DiscoveryModule(), PresenceModule(),
                              InboxModule(onMessage: { [weak self] body in Task { @MainActor in self?.append("XMPP message (foreground): \(body.prefix(20))…") } })] {
            _ = c.modulesManager.register(m)
        }
        client = c
        status = "connecting"
        do {
            try await c.loginAndWait()
            status = "online"
            append("XMPP session established")
        } catch {
            status = "failed"
            append("login failed: \(error)")
            return
        }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        append("notification permission: \(granted)")
        AppDelegate.onToken = { [weak self] data in Task { @MainActor in await self?.tokenReceived(data) } }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func tokenReceived(_ data: Data) async {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let previous = SharedStore.keychainGet("apnsToken").map { String(decoding: $0, as: UTF8.self) }
        token = hex
        if previous == hex, SharedStore.keychainGet("node") != nil {
            append("token unchanged → re-enable existing node")
            await enableStoredNode()
            return
        }
        append(previous == nil ? "first token → register" : "TOKEN CHANGED → register new, disable + unregister old")
        let oldNode = SharedStore.keychainGet("node").map { String(decoding: $0, as: UTF8.self) }
        if SharedStore.keychainGet("deviceKey") == nil {
            SharedStore.keychainSet(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }, account: "deviceKey")
        }
        guard let key = SharedStore.keychainGet("deviceKey") else { return append("no device key") }
        do {
            let result = try await command("register-push-apns", ["token": hex, "environment": "sandbox",
                                                                    "device-key": key.base64EncodedString()])
            guard let node = result["node"], let secret = result["secret"] else { return append("gateway returned no node") }
            if let oldNode { try? await pushIQ(enable: false, node: oldNode, secret: nil) }   // one node per session (S2 p06)
            SharedStore.keychainSet(Data(node.utf8), account: "node")
            SharedStore.keychainSet(Data(secret.utf8), account: "secret")
            SharedStore.keychainSet(Data(hex.utf8), account: "apnsToken")
            try await pushIQ(enable: true, node: node, secret: secret)
            if let oldNode { _ = try? await command("unregister-push", ["node": oldNode]) }
            append("push enabled (node \(node.prefix(6))…)")
        } catch {
            append("push setup failed: \(error)")
        }
    }

    private func enableStoredNode() async {
        guard let node = SharedStore.keychainGet("node").map({ String(decoding: $0, as: UTF8.self) }),
              let secret = SharedStore.keychainGet("secret").map({ String(decoding: $0, as: UTF8.self) }) else { return }
        do {
            try await pushIQ(enable: true, node: node, secret: secret)
            append("push re-enabled")
        } catch { append("re-enable failed: \(error)") }
    }

    func logout() async {
        if let node = SharedStore.keychainGet("node").map({ String(decoding: $0, as: UTF8.self) }) {
            try? await pushIQ(enable: false, node: node, secret: nil)
            _ = try? await command("unregister-push", ["node": node])
        }
        for k in ["node", "secret", "apnsToken", "deviceKey"] { SharedStore.keychainDelete(k) }
        UIApplication.shared.unregisterForRemoteNotifications()
        try? await client?.disconnect(force: false)
        status = "logged out"
        append("logout: push disabled, gateway registration removed, keys deleted")
    }

    // MARK: Lifecycle

    func scenePhaseChanged(_ phase: ScenePhase) async {
        switch phase {
        case .background:
            append("background → closing XMPP connection (server hibernates/stores; pushes start)")
            try? await client?.disconnect(force: false)
            status = "background"
        case .active where status == "background":
            append("foreground → reconnect + re-enable push")
            do {
                try await client?.loginAndWait()
                status = "online"
                await enableStoredNode()
            } catch { append("reconnect failed: \(error)") }
        default:
            break
        }
    }

    // MARK: Spike helpers

    func saveNames() {
        var names: [String: String] = [:]
        for line in namesText.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { names[parts[0]] = parts[1] }
        }
        SharedStore.saveNames(names)
    }

    func setNSEMode(_ mode: String) {
        SharedStore.nseFailureMode = mode
        nseMode = mode
        append("NSE failure mode = \(mode)")
    }

    private func command(_ node: String, _ fields: [String: String]) async throws -> [String: String] {
        guard let client else { throw SpikeError.notConnected }
        let iq = Iq()
        iq.type = .set
        iq.to = JID(gatewayJid)
        let x = Element(name: "x", xmlns: "jabber:x:data")
        x.setAttribute("type", value: "submit")
        for (k, v) in fields {
            let field = Element(name: "field")
            field.setAttribute("var", value: k)
            field.addChild(Element(name: "value", cdata: v))
            x.addChild(field)
        }
        let cmd = Element(name: "command", xmlns: "http://jabber.org/protocol/commands", children: [x])
        cmd.setAttribute("node", value: node)
        cmd.setAttribute("action", value: "execute")
        iq.addChild(cmd)
        let response = try await client.writer.write(iq: iq)
        var out: [String: String] = [:]
        for f in response.findChild(name: "command")?.findChild(name: "x")?.getChildren(name: "field") ?? [] {
            if let k = f.attributes["var"] { out[k] = f.findChild(name: "value")?.value ?? "" }
        }
        return out
    }

    private func pushIQ(enable: Bool, node: String, secret: String?) async throws {
        guard let client else { return }
        let iq = Iq()
        iq.type = .set
        let el = Element(name: enable ? "enable" : "disable", xmlns: "urn:xmpp:push:0")
        el.setAttribute("jid", value: gatewayJid)
        el.setAttribute("node", value: node)
        if enable, let secret {
            let x = Element(name: "x", xmlns: "jabber:x:data")
            x.setAttribute("type", value: "submit")
            for (k, v) in [("FORM_TYPE", "http://jabber.org/protocol/pubsub#publish-options"), ("secret", secret)] {
                let field = Element(name: "field")
                field.setAttribute("var", value: k)
                field.addChild(Element(name: "value", cdata: v))
                x.addChild(field)
            }
            el.addChild(x)
        }
        iq.addChild(el)
        _ = try await client.writer.write(iq: iq)
    }
}

enum SpikeError: Error { case notConnected }

/// Logs incoming chat message bodies while the app is in the foreground (no push expected then).
final class InboxModule: XmppModuleBase, XmppModule {
    static let ID = "pushspike-inbox"
    let criteria = Criteria.name("message", types: [.chat, .normal])
    let features: [String] = []
    private let onMessage: (String) -> Void

    init(onMessage: @escaping (String) -> Void) {
        self.onMessage = onMessage
        super.init()
    }

    func process(stanza: Stanza) throws {
        if let body = (stanza as? Message)?.body { onMessage(body) }
    }
}
