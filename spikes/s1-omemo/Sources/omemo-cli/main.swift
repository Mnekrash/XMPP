import Foundation
import OMEMOKit

// JSON-lines RPC used by the interop harness: one request object per stdin line, one response per stdout line.
// State is persisted to `statePath` after every command, so a restarted process continues the same device.

nonisolated(unsafe) var store: OMEMOStore?
nonisolated(unsafe) var statePath: URL?

func save() throws {
    guard let store, let statePath else { return }
    try JSONEncoder().encode(store).write(to: statePath, options: .atomic)
}

func reply(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func addresses(_ list: [OMEMOStore.DeviceAddress]) -> [[String: Any]] {
    list.map { ["jid": $0.jid, "deviceId": Int($0.deviceId)] }
}

func handle(_ req: [String: Any]) throws -> [String: Any] {
    let cmd = req["cmd"] as? String ?? ""
    if cmd == "init" {
        let path = URL(fileURLWithPath: req["statePath"] as! String)
        statePath = path
        if let data = try? Data(contentsOf: path) {
            store = try JSONDecoder().decode(OMEMOStore.self, from: data)
        } else {
            let id = (req["deviceId"] as? Int).map { UInt32($0) }
            store = OMEMOStore(own: try OwnDevice(jid: req["jid"] as! String, deviceId: id, label: req["label"] as? String))
            try save()
        }
        return ["deviceId": Int(store!.own.deviceId), "identityKey": store!.own.identityKey.base64EncodedString()]
    }
    guard var s = store else { throw OMEMOError.malformedXML("not initialised") }
    defer { store = s; try? save() }

    switch cmd {
    case "bundle":
        return ["deviceId": Int(s.own.deviceId), "bundleXML": try s.own.bundle().xml(),
                "deviceXML": try s.own.deviceElementXML(), "preKeyIds": s.own.preKeyIds.map(Int.init),
                "signedPreKeyId": Int(s.own.signedPreKey.id)]
    case "setDeviceList":
        s.setDeviceList(jid: req["jid"] as! String, deviceIds: (req["deviceIds"] as! [Int]).map(UInt32.init))
        return [:]
    case "setBundle":
        let address = OMEMOStore.DeviceAddress(jid: req["jid"] as! String, deviceId: UInt32(req["deviceId"] as! Int))
        s.setBundle(try Bundle.parse(req["bundleXML"] as! String), for: address)
        return [:]
    case "verifyLabel":
        let ok = OwnDevice.verifyLabel(req["label"] as! String, signature: Data(base64Encoded: req["labelsig"] as! String)!,
                                       identityKey: Data(base64Encoded: req["identityKey"] as! String)!)
        return ["valid": ok]
    case "encrypt":
        let envelope = SCEEnvelope(body: req["body"] as! String, from: s.own.jid, to: req["to"] as? String)
        let r = try s.encrypt(Data(envelope.serialize().utf8), for: req["recipients"] as! [String])
        return ["xml": r.xml, "recipients": addresses(r.recipients), "kex": addresses(r.keyExchangeRecipients),
                "missingBundles": addresses(r.missingBundles)]
    case "encryptEmpty":
        let r = try s.encryptEmpty(for: req["recipients"] as! [String])
        return ["xml": r.xml, "recipients": addresses(r.recipients), "kex": addresses(r.keyExchangeRecipients)]
    case "decrypt":
        let from = req["from"] as! String
        let r = try s.decrypt(req["xml"] as! String, from: from)
        var out: [String: Any] = ["senderDeviceId": Int(r.sender.deviceId), "kex": r.wasKeyExchange,
                                  "newSession": r.newSessionBuilt, "republish": r.bundleNeedsRepublish,
                                  "identityChanged": r.identityKeyChanged]
        if let id = r.consumedPreKeyId { out["consumedPreKeyId"] = Int(id) }
        if let plaintext = r.plaintext {
            let envelope = try SCEEnvelope.parse(String(decoding: plaintext, as: UTF8.self))
            // OMEMO 2 / SCE: the <from> affix must match the sender's bare JID.
            guard envelope.from == from else { throw OMEMOError.sceAffixMismatch(expected: from, found: envelope.from) }
            out["body"] = envelope.body
            out["to"] = envelope.to ?? NSNull()
        }
        return out
    case "rotateSignedPreKey":
        try s.rotateSignedPreKey()
        return ["signedPreKeyId": Int(s.own.signedPreKey.id)]
    case "deleteSession":
        s.deleteSession(with: .init(jid: req["jid"] as! String, deviceId: UInt32(req["deviceId"] as! Int)))
        return [:]
    case "status":
        let jid = req["jid"] as? String
        let id = (req["deviceId"] as? Int).map(UInt32.init)
        var out: [String: Any] = ["preKeyCount": s.own.preKeyIds.count, "skippedKeys": s.skippedKeyCount]
        if let jid, let id {
            out["hasSession"] = s.hasSession(with: .init(jid: jid, deviceId: id))
            out["confirmed"] = s.isConfirmed(.init(jid: jid, deviceId: id))
        }
        return out
    default:
        throw OMEMOError.malformedXML("unknown command \(cmd)")
    }
}

while let line = readLine() {
    guard let data = line.data(using: .utf8),
          let req = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        reply(["ok": false, "error": "bad request"])
        continue
    }
    do {
        var out = try handle(req)
        out["ok"] = true
        reply(out)
    } catch {
        reply(["ok": false, "error": String(describing: error)])
    }
}
