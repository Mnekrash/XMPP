import Foundation
@testable import SyncCore
import Testing

struct SyncCoreTests {
    private func store(_ own: String = "bob@x.test") throws -> SyncStore {
        try SyncStore(path: NSTemporaryDirectory() + UUID().uuidString + ".sqlite", ownJid: own)
    }

    private func env(_ source: SyncStore.Source, sid: String?, origin: String?, body: String = "hi",
                     from: String = "alice@x.test", to: String = "bob@x.test", time: Double? = nil) -> SyncStore.Envelope {
        .init(source: source, archiveJid: "bob@x.test", stanzaId: sid, originId: origin, fromBare: from, toBare: to,
              body: body, serverTime: time.map { Date(timeIntervalSince1970: $0) })
    }

    @Test func sameArchivedCopyViaLiveOfflineAndMAMIsOneMessage() throws {
        let s = try store()
        #expect(try s.ingest(env(.live, sid: "S1", origin: "o1")).action == .inserted)
        #expect(try s.ingest(env(.offline, sid: "S1", origin: "o1")).action == .duplicateServerId)
        #expect(try s.ingest(env(.mam, sid: "S1", origin: "o1")).action == .duplicateServerId)
        #expect(try s.messages(peer: "alice@x.test").count == 1)
        #expect(s.decryptCalls == 1)
    }

    @Test func resentCopyWithNewStanzaIdIsMergedByOriginId() throws {
        let s = try store()
        let first = try s.ingest(env(.live, sid: "S1", origin: "o1"))
        #expect(try s.ingest(env(.offline, sid: "S2", origin: "o1")).action == .mergedByOriginId)
        #expect(try s.ingest(env(.mam, sid: "S2", origin: "o1")).action == .duplicateServerId)
        #expect(try s.serverIdCount(localId: first.localId!) == 2)
        #expect(try s.messages(peer: "alice@x.test").count == 1 && s.decryptCalls == 1)
    }

    @Test func foreignMessageWithoutOriginIdUsesStanzaId() throws {
        let s = try store()
        #expect(try s.ingest(env(.live, sid: "S9", origin: nil)).action == .inserted)
        #expect(try s.ingest(env(.mam, sid: "S9", origin: nil)).action == .duplicateServerId)
        #expect(try s.messages(peer: "alice@x.test").first?.appId == "sid:bob@x.test/S9")
    }

    @Test func ownOutgoingMessageReflectedByMAMMergesAndMarksSent() throws {
        let s = try store("alice@x.test")
        let appId = try s.createOutgoing(to: "bob@x.test", body: "mine")
        let reflected = SyncStore.Envelope(source: .mam, archiveJid: "alice@x.test", stanzaId: "A1", originId: appId,
                                           fromBare: "alice@x.test", toBare: "bob@x.test", body: "mine", serverTime: nil)
        #expect(try s.ingest(reflected).action == .mergedByOriginId)
        let rows = try s.messages(peer: "bob@x.test")
        #expect(rows.count == 1 && rows[0].status == SyncStore.Status.sent.rawValue)
        #expect(s.decryptCalls == 0)
    }

    @Test func outboxKeepsTheSameAppIdUntilAcked() throws {
        let s = try store("alice@x.test")
        let appId = try s.createOutgoing(to: "bob@x.test", body: "retry me")
        #expect(try s.pendingOutbox().map(\.appId) == [appId])
        #expect(try s.pendingOutbox().map(\.appId) == [appId])
        try s.markAcked(appId)
        #expect(try s.pendingOutbox().isEmpty)
    }

    @Test func orderingUsesServerTimeNotArrivalOrder() throws {
        let s = try store()
        _ = try s.ingest(env(.mam, sid: "S3", origin: "o3", body: "third", time: 300))
        _ = try s.ingest(env(.mam, sid: "S1", origin: "o1", body: "first", time: 100))
        _ = try s.ingest(env(.mam, sid: "S2", origin: "o2", body: "second", time: 200))
        #expect(try s.messages(peer: "alice@x.test").map(\.body) == ["first", "second", "third"])
    }
}
