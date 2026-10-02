import Foundation
import GRDB

/// Canonical message identity and ingest pipeline (docs/03 §1, §3.2), spike version.
///
/// Identifiers:
/// - `app_id`      application message ID. Generated once by the sending client (lowercase UUID) and sent
///                 as the stanza `id` and XEP-0359 `<origin-id>`. Stable across retries, devices and archives.
///                 Replies, edits and reactions reference it. Foreign messages without origin-id get
///                 `sid:<archive>/<stanza-id>`.
/// - `origin-id`   wire carrier of `app_id` (XEP-0359). Dedup key for re-sends: a re-sent copy gets a new
///                 server stanza-id but keeps its origin-id.
/// - `stanza-id`   server-assigned per archived copy (XEP-0359 `by=` archive). Dedup key for the same
///                 archived copy arriving via live / SM replay / offline / carbons / MAM. One logical message can
///                 own several (one per stored copy) → table `message_server_id`.
/// - MAM result id `<result id>`; equal to the archived copy's stanza-id on ejabberd (verified in S4).
///                 Used only as the RSM paging cursor.
/// - `local_id`    SQLite rowid (INTEGER PRIMARY KEY). Local only, never sent anywhere. Used for joins/FTS.
public final class SyncStore: @unchecked Sendable {
    public enum Source: String, Codable, Sendable { case live, carbon, mam, offline, resumed, injected }
    public enum Direction: Int, Codable, Sendable { case incoming = 0, outgoing = 1 }
    public enum Status: Int, Codable, Sendable { case failed = -1, sending = 0, sent = 1, delivered = 2, read = 3 }

    public struct Envelope: Codable, Sendable {
        public var source: Source
        public var archiveJid: String         // whose archive assigned stanzaId (own bare JID for 1:1)
        public var stanzaId: String?          // <stanza-id by=archiveJid>
        public var originId: String?          // <origin-id>
        public var fromBare: String
        public var toBare: String
        public var body: String?
        public var serverTime: Date?          // <delay stamp> (offline / MAM)
        public init(source: Source, archiveJid: String, stanzaId: String?, originId: String?, fromBare: String,
                    toBare: String, body: String?, serverTime: Date?) {
            self.source = source; self.archiveJid = archiveJid; self.stanzaId = stanzaId; self.originId = originId
            self.fromBare = fromBare; self.toBare = toBare; self.body = body; self.serverTime = serverTime
        }
    }

    public enum Action: String, Codable, Sendable {
        case inserted               // new logical message (the only case that decrypts)
        case duplicateServerId      // this archived copy was already ingested
        case mergedByOriginId       // another copy of a known logical message (new server id recorded)
        case ignored                // no body, no identity
    }

    public struct IngestResult: Codable, Sendable {
        public var action: Action
        public var appId: String?
        public var localId: Int64?
    }

    public struct MessageRow: Codable, Sendable, FetchableRecord {
        public var localId: Int64
        public var appId: String
        public var peer: String
        public var sender: String
        public var direction: Int
        public var body: String?
        public var sortKey: Double
        public var status: Int
        public var source: String
    }

    private let db: DatabaseQueue
    public let ownJid: String
    /// Counts calls of the (simulated) OMEMO decrypt step: must equal the number of inserted messages.
    public private(set) var decryptCalls = 0
    public private(set) var actions: [Action: Int] = [:]

    public init(path: String, ownJid: String) throws {
        db = try DatabaseQueue(path: path)
        self.ownJid = ownJid
        try Self.migrator.migrate(db)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE message (
                    local_id   INTEGER PRIMARY KEY,
                    app_id     TEXT NOT NULL,
                    peer       TEXT NOT NULL,
                    sender     TEXT NOT NULL,
                    direction  INTEGER NOT NULL,
                    body       TEXT,
                    sort_key   REAL NOT NULL,
                    received_at REAL NOT NULL,
                    status     INTEGER NOT NULL,
                    source     TEXT NOT NULL,
                    origin_id  TEXT
                );
                CREATE UNIQUE INDEX message_app_id ON message(peer, sender, app_id);
                CREATE INDEX message_page ON message(peer, sort_key DESC, local_id DESC);
                CREATE TABLE message_server_id (
                    archive_jid TEXT NOT NULL,
                    stanza_id   TEXT NOT NULL,
                    local_id    INTEGER NOT NULL REFERENCES message(local_id) ON DELETE CASCADE,
                    PRIMARY KEY (archive_jid, stanza_id)
                );
                CREATE TABLE outbox (
                    app_id   TEXT PRIMARY KEY,
                    local_id INTEGER NOT NULL REFERENCES message(local_id) ON DELETE CASCADE,
                    attempts INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE sync_state (
                    archive_jid TEXT PRIMARY KEY,
                    last_stanza_id TEXT NOT NULL,
                    updated_at REAL NOT NULL
                );
                """)
        }
        return m
    }

    // MARK: Ingest (one write transaction per stanza; dedup before decrypt)

    public func ingest(_ e: Envelope) throws -> IngestResult {
        guard e.body != nil else { return note(IngestResult(action: .ignored)) }
        let direction: Direction = e.fromBare == ownJid ? .outgoing : .incoming
        let peer = direction == .outgoing ? e.toBare : e.fromBare
        let result: IngestResult = try db.write { db in
            // 1. Same archived copy already ingested?
            if let sid = e.stanzaId,
               let localId = try Int64.fetchOne(db, sql: "SELECT local_id FROM message_server_id WHERE archive_jid = ? AND stanza_id = ?",
                                                arguments: [e.archiveJid, sid]) {
                let appId = try String.fetchOne(db, sql: "SELECT app_id FROM message WHERE local_id = ?", arguments: [localId])
                return IngestResult(action: .duplicateServerId, appId: appId, localId: localId)
            }
            // 2. Another copy of a known logical message (re-send, carbon, own reflection)?
            if let origin = e.originId,
               let localId = try Int64.fetchOne(db, sql: "SELECT local_id FROM message WHERE peer = ? AND sender = ? AND app_id = ?",
                                                arguments: [peer, e.fromBare, origin]) {
                if let sid = e.stanzaId {
                    try db.execute(sql: "INSERT OR IGNORE INTO message_server_id VALUES (?, ?, ?)", arguments: [e.archiveJid, sid, localId])
                }
                // A server copy of our own outgoing message proves the server accepted it.
                try db.execute(sql: "UPDATE message SET status = ? WHERE local_id = ? AND status = ?",
                               arguments: [Status.sent.rawValue, localId, Status.sending.rawValue])
                return IngestResult(action: .mergedByOriginId, appId: origin, localId: localId)
            }
            // 3. New logical message: decrypt exactly once, insert.
            self.decryptCalls += 1
            let appId = e.originId ?? "sid:\(e.archiveJid)/\(e.stanzaId ?? UUID().uuidString)"
            let now = Date().timeIntervalSince1970
            try db.execute(sql: """
                INSERT INTO message (app_id, peer, sender, direction, body, sort_key, received_at, status, source, origin_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [appId, peer, e.fromBare, direction.rawValue, e.body,
                                 e.serverTime?.timeIntervalSince1970 ?? now, now,
                                 direction == .outgoing ? Status.sent.rawValue : Status.delivered.rawValue,
                                 e.source.rawValue, e.originId])
            let localId = db.lastInsertedRowID
            if let sid = e.stanzaId {
                try db.execute(sql: "INSERT INTO message_server_id VALUES (?, ?, ?)", arguments: [e.archiveJid, sid, localId])
            }
            return IngestResult(action: .inserted, appId: appId, localId: localId)
        }
        return note(result)
    }

    private func note(_ r: IngestResult) -> IngestResult {
        actions[r.action, default: 0] += 1
        return r
    }

    // MARK: Outgoing (UI → DB → outbox; same app_id on every retry)

    public func createOutgoing(to peer: String, body: String) throws -> String {
        let appId = UUID().uuidString.lowercased()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO message (app_id, peer, sender, direction, body, sort_key, received_at, status, source, origin_id)
                VALUES (?, ?, ?, 1, ?, ?, ?, ?, 'local', ?)
                """, arguments: [appId, peer, ownJid, body, Date().timeIntervalSince1970, Date().timeIntervalSince1970,
                                 Status.sending.rawValue, appId])
            try db.execute(sql: "INSERT INTO outbox (app_id, local_id) VALUES (?, ?)", arguments: [appId, db.lastInsertedRowID])
        }
        return appId
    }

    /// XEP-0198 ack received for the stanza carrying `appId`.
    public func markAcked(_ appId: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE message SET status = ? WHERE app_id = ? AND sender = ? AND status = ?",
                           arguments: [Status.sent.rawValue, appId, ownJid, Status.sending.rawValue])
            try db.execute(sql: "DELETE FROM outbox WHERE app_id = ?", arguments: [appId])
        }
    }

    public func pendingOutbox() throws -> [(appId: String, peer: String, body: String)] {
        try db.write { db in
            try db.execute(sql: "UPDATE outbox SET attempts = attempts + 1")
            return try Row.fetchAll(db, sql: """
                SELECT o.app_id, m.peer, m.body FROM outbox o JOIN message m ON m.local_id = o.local_id ORDER BY m.local_id
                """).map { ($0["app_id"], $0["peer"], $0["body"]) }
        }
    }

    // MARK: MAM cursor (advanced only after the page is committed)

    public func cursor(for archive: String) throws -> String? {
        try db.read { try String.fetchOne($0, sql: "SELECT last_stanza_id FROM sync_state WHERE archive_jid = ?", arguments: [archive]) }
    }

    public func setCursor(_ stanzaId: String, for archive: String) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO sync_state VALUES (?, ?, ?)", arguments: [archive, stanzaId, Date().timeIntervalSince1970])
        }
    }

    // MARK: Inspection

    public func messages(peer: String) throws -> [MessageRow] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM message WHERE peer = ? ORDER BY sort_key, local_id", arguments: [peer]).map {
                MessageRow(localId: $0["local_id"], appId: $0["app_id"], peer: $0["peer"], sender: $0["sender"],
                           direction: $0["direction"], body: $0["body"], sortKey: $0["sort_key"], status: $0["status"],
                           source: $0["source"])
            }
        }
    }

    /// Logical messages visible more than once (must always be empty).
    public func duplicateLogicalMessages() throws -> [String] {
        try db.read { db in
            try String.fetchAll(db, sql: "SELECT body FROM message GROUP BY peer, sender, body HAVING count(*) > 1")
        }
    }

    public func serverIdCount(localId: Int64) throws -> Int {
        try db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message_server_id WHERE local_id = ?", arguments: [localId]) ?? 0 }
    }
}
