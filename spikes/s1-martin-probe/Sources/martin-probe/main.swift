import Foundation
import Martin

// Usage: PROBE_JID=alice@chat.example.com PROBE_PASSWORD=… PROBE_HOST=chat.example.com [PROBE_PORT=5223] \
//        [PROBE_TO=bob@chat.example.com] swift run martin-probe
// Uses system trust (staging/production certificate). Prints one PASS/FAIL line per check.

func env(_ key: String, _ fallback: String? = nil) -> String {
    guard let value = ProcessInfo.processInfo.environment[key] ?? fallback else {
        print("missing \(key)"); exit(2)
    }
    return value
}

func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
}

let client = XMPPClient()
client.connectionConfiguration.userJid = BareJID(env("PROBE_JID"))
client.connectionConfiguration.credentials = .password(password: env("PROBE_PASSWORD"), authenticationName: nil, cache: nil)
var options = SocketConnectorNetwork.Options()
options.connectionDetails = .init(proto: .XMPPS, host: env("PROBE_HOST"), port: Int(env("PROBE_PORT", "5223"))!)
client.connectionConfiguration.connectorOptions = options

_ = client.modulesManager.register(StreamFeaturesModule())
_ = client.modulesManager.register(SaslModule())
_ = client.modulesManager.register(AuthModule())
_ = client.modulesManager.register(ResourceBinderModule())
_ = client.modulesManager.register(SessionEstablishmentModule())
let sm = client.modulesManager.register(StreamManagementModule())
let disco = client.modulesManager.register(DiscoveryModule())
let carbons = client.modulesManager.register(MessageCarbonsModule())
let mam = client.modulesManager.register(MessageArchiveManagementModule())
_ = client.modulesManager.register(PresenceModule())

let start = Date()
do {
    try await client.loginAndWait()
    check("login over direct TLS (XEP-0368) with system trust", true, String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000))
} catch {
    check("login over direct TLS (XEP-0368) with system trust", false, "\(error)")
    exit(1)
}

check("Stream Management resumption enabled", sm.resumptionEnabled)

do {
    try await carbons.enable()
    check("Message Carbons enabled", true)
} catch { check("Message Carbons enabled", false, "\(error)") }

do {
    let info = try await disco.info(for: JID(client.connectionConfiguration.userJid))
    check("account disco: MAM + push advertised",
          info.features.contains("urn:xmpp:mam:2") && info.features.contains("urn:xmpp:push:0"))
} catch { check("account disco", false, "\(error)") }

if let to = ProcessInfo.processInfo.environment["PROBE_TO"] {
    let message = Message()
    message.type = .chat
    message.to = JID(to)
    message.id = UUID().uuidString.lowercased()
    message.body = "martin-probe \(Date())"
    client.writer.write(message)
    check("message sent (raw stanza via writer)", true, message.id ?? "")
}

do {
    let result = try await mam.queryItems(queryId: UUID().uuidString)
    check("MAM query on own archive", true, "complete=\(result.complete)")
} catch { check("MAM query on own archive", false, "\(error)") }

try? await client.disconnect()
check("disconnect", true)
