import Foundation
@testable import OMEMOKit
import Testing

/// Swift ↔ Swift self-consistency. Cross-implementation interop lives in harness/ (python-twomemo).
struct OMEMOKitTests {
    private func pair() throws -> (OMEMOStore, OMEMOStore) {
        var a = OMEMOStore(own: try OwnDevice(jid: "a@x.test", deviceId: 1))
        var b = OMEMOStore(own: try OwnDevice(jid: "b@x.test", deviceId: 2))
        a.setDeviceList(jid: "b@x.test", deviceIds: [2]); b.setDeviceList(jid: "a@x.test", deviceIds: [1])
        a.setBundle(try b.own.bundle(), for: .init(jid: "b@x.test", deviceId: 2))
        b.setBundle(try a.own.bundle(), for: .init(jid: "a@x.test", deviceId: 1))
        return (a, b)
    }

    @Test func bundleRoundTripsThroughXML() throws {
        let device = try OwnDevice(jid: "a@x.test", deviceId: 7, label: "iPhone")
        let bundle = try device.bundle()
        #expect(try Bundle.parse(bundle.xml()) == bundle)
        #expect(bundle.preKeys.count == OwnDevice.preKeyCount)
    }

    @Test func keyExchangeThenRatchetBothWays() throws {
        var (a, b) = try pair()
        let m1 = try a.encrypt(Data("hello".utf8), for: ["b@x.test"])
        #expect(m1.keyExchangeRecipients.count == 1)
        let r1 = try b.decrypt(m1.xml, from: "a@x.test")
        #expect(r1.plaintext == Data("hello".utf8) && r1.newSessionBuilt && r1.consumedPreKeyId != nil)
        let m2 = try b.encrypt(Data("hi".utf8), for: ["a@x.test"])
        #expect(m2.keyExchangeRecipients.isEmpty)
        #expect(try a.decrypt(m2.xml, from: "b@x.test").plaintext == Data("hi".utf8))
        let m3 = try a.encrypt(Data("after confirm".utf8), for: ["b@x.test"])
        #expect(m3.keyExchangeRecipients.isEmpty) // confirmed by the reply
        #expect(try b.decrypt(m3.xml, from: "a@x.test").plaintext == Data("after confirm".utf8))
    }

    @Test func outOfOrderAndDuplicate() throws {
        var (a, b) = try pair()
        let msgs = try (0..<5).map { try a.encrypt(Data("m\($0)".utf8), for: ["b@x.test"]) }
        for i in [0, 4, 2, 1, 3] {
            #expect(try b.decrypt(msgs[i].xml, from: "a@x.test").plaintext == Data("m\(i)".utf8))
        }
        #expect(throws: (any Error).self) { try b.decrypt(msgs[2].xml, from: "a@x.test") }
    }

    @Test func tamperedPayloadIsRejected() throws {
        var (a, b) = try pair()
        let m = try a.encrypt(Data("secret".utf8), for: ["b@x.test"])
        let tampered = m.xml.replacingOccurrences(of: "<payload>", with: "<payload>AAAA")
        #expect(throws: (any Error).self) { try b.decrypt(tampered, from: "a@x.test") }
        // The failed attempt must not have consumed state: the original still decrypts.
        #expect(try b.decrypt(m.xml, from: "a@x.test").plaintext == Data("secret".utf8))
    }

    @Test func sceAffixes() throws {
        let env = SCEEnvelope(body: "a < b & c", from: "a@x.test", to: "room@groups.x.test")
        #expect(try SCEEnvelope.parse(env.serialize()) == env)
    }
}

struct StalePreKeyTests {
    @Test func signedPreKeyRotatedTwiceIsRejected() throws {
        var a = OMEMOStore(own: try OwnDevice(jid: "a@x.test", deviceId: 1))
        var b = OMEMOStore(own: try OwnDevice(jid: "b@x.test", deviceId: 2))
        a.setDeviceList(jid: "b@x.test", deviceIds: [2])
        a.setBundle(try b.own.bundle(), for: .init(jid: "b@x.test", deviceId: 2))   // cached, SPK 1
        try b.rotateSignedPreKey()                                                // SPK 2, keeps 1
        try b.rotateSignedPreKey()                                                // SPK 3, keeps 2
        let m = try a.encrypt(Data("stale".utf8), for: ["b@x.test"])
        #expect(throws: OMEMOError.unknownSignedPreKey(1)) { try b.decrypt(m.xml, from: "a@x.test") }
    }

    @Test func signedPreKeyRotatedOnceStillAccepted() throws {
        var a = OMEMOStore(own: try OwnDevice(jid: "a@x.test", deviceId: 1))
        var b = OMEMOStore(own: try OwnDevice(jid: "b@x.test", deviceId: 2))
        a.setDeviceList(jid: "b@x.test", deviceIds: [2])
        a.setBundle(try b.own.bundle(), for: .init(jid: "b@x.test", deviceId: 2))
        try b.rotateSignedPreKey()
        let m = try a.encrypt(Data("grace".utf8), for: ["b@x.test"])
        #expect(try b.decrypt(m.xml, from: "a@x.test").plaintext == Data("grace".utf8))
    }

    @Test func consumedPreKeyIsRejected() throws {
        var a = OMEMOStore(own: try OwnDevice(jid: "a@x.test", deviceId: 1))
        var b = OMEMOStore(own: try OwnDevice(jid: "b@x.test", deviceId: 2))
        let bundle = try b.own.bundle()
        let only = bundle.preKeys.first!
        var single = bundle
        single.preKeys = [only.key: only.value]
        a.setDeviceList(jid: "b@x.test", deviceIds: [2])
        a.setBundle(single, for: .init(jid: "b@x.test", deviceId: 2))
        _ = try b.decrypt(try a.encrypt(Data("1".utf8), for: ["b@x.test"]).xml, from: "a@x.test")
        a.deleteSession(with: .init(jid: "b@x.test", deviceId: 2))
        let again = try a.encrypt(Data("2".utf8), for: ["b@x.test"])
        #expect(throws: OMEMOError.unknownPreKey(only.key)) { try b.decrypt(again.xml, from: "a@x.test") }
    }
}
