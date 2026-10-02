import Foundation
import SyncCore

// JSON-lines RPC for the S4 harness. The store is reopened from the same DB file after a process restart.
nonisolated(unsafe) var store: SyncStore?

func reply(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func handle(_ req: [String: Any]) throws -> [String: Any] {
    switch req["cmd"] as? String ?? "" {
    case "open":
        store = try SyncStore(path: req["path"] as! String, ownJid: req["ownJid"] as! String)
        return [:]
    case "ingest":
        let e = SyncStore.Envelope(
            source: SyncStore.Source(rawValue: req["source"] as! String)!, archiveJid: req["archiveJid"] as! String,
            stanzaId: req["stanzaId"] as? String, originId: req["originId"] as? String,
            fromBare: req["from"] as! String, toBare: req["to"] as! String, body: req["body"] as? String,
            serverTime: (req["serverTime"] as? Double).map { Date(timeIntervalSince1970: $0) })
        let r = try store!.ingest(e)
        return ["action": r.action.rawValue, "appId": r.appId ?? NSNull(), "localId": r.localId ?? NSNull()]
    case "createOutgoing":
        return ["appId": try store!.createOutgoing(to: req["to"] as! String, body: req["body"] as! String)]
    case "acked":
        try store!.markAcked(req["appId"] as! String)
        return [:]
    case "outbox":
        return ["pending": try store!.pendingOutbox().map { ["appId": $0.appId, "to": $0.peer, "body": $0.body] }]
    case "cursor":
        return ["stanzaId": try store!.cursor(for: req["archive"] as! String) ?? NSNull()]
    case "setCursor":
        try store!.setCursor(req["stanzaId"] as! String, for: req["archive"] as! String)
        return [:]
    case "messages":
        let rows = try store!.messages(peer: req["peer"] as! String)
        return ["messages": rows.map { ["localId": $0.localId, "appId": $0.appId, "sender": $0.sender, "body": $0.body ?? NSNull(),
                                        "sortKey": $0.sortKey, "status": $0.status, "source": $0.source] }]
    case "stats":
        var actions: [String: Int] = [:]
        for (k, v) in store!.actions { actions[k.rawValue] = v }
        return ["decryptCalls": store!.decryptCalls, "actions": actions, "duplicates": try store!.duplicateLogicalMessages()]
    case "serverIds":
        return ["count": try store!.serverIdCount(localId: Int64(req["localId"] as! Int))]
    default:
        throw NSError(domain: "sync-cli", code: 1, userInfo: [NSLocalizedDescriptionKey: "unknown command"])
    }
}

while let line = readLine() {
    guard let req = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
        reply(["ok": false, "error": "bad request"]); continue
    }
    do { var out = try handle(req); out["ok"] = true; reply(out) } catch { reply(["ok": false, "error": "\(error)"]) }
}
