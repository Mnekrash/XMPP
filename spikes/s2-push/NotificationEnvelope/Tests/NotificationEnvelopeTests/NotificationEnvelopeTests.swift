import Foundation
import NotificationEnvelope
import Testing

struct Vector: Decodable {
    var key: String
    var e: String
    var envelope: Envelope
    var thread: String
}

private func vectors() throws -> [Vector] {
    let url = try #require(Bundle.module.url(forResource: "gateway-vectors", withExtension: "json"))
    return try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
}

struct CrossImplementationTests {
    @Test func opensEnvelopesSealedByTheGoGateway() throws {
        for v in try vectors() {
            let key = Data(base64Encoded: v.key)!
            #expect(try NotificationEnvelope.open(v.e, deviceKey: key) == v.envelope)
            #expect(NotificationEnvelope.opaqueID(deviceKey: key, conversation: v.envelope.conv!) == v.thread)
        }
    }

    @Test func wrongKeyOrTamperingIsRejected() throws {
        let v = try vectors()[0]
        #expect(throws: EnvelopeError.authenticationFailed) { try NotificationEnvelope.open(v.e, deviceKey: Data(count: 32)) }
        var raw = Data(base64Encoded: v.e)!
        raw[raw.count - 1] ^= 1
        #expect(throws: EnvelopeError.authenticationFailed) {
            try NotificationEnvelope.open(raw.base64EncodedString(), deviceKey: Data(base64Encoded: v.key)!)
        }
    }
}

struct DecisionTests {
    let names = ["alice@chat.example.com": "Alice Smith"]
    let groups = ["team@groups.chat.example.com": "Project Team"]

    @Test func knownSenderShowsNameAndGenericBody() throws {
        let v = try vectors()[0]
        let t = NotificationText.decide(userInfo: ["e": v.e], deviceKey: Data(base64Encoded: v.key),
                                        displayName: { names[$0] }, groupTitle: { groups[$0] })
        #expect(t == NotificationText(title: "Alice Smith", body: "New message"))
    }

    @Test func groupShowsTitleAndNick() throws {
        let v = try vectors()[1]
        let t = NotificationText.decide(userInfo: ["e": v.e], deviceKey: Data(base64Encoded: v.key),
                                        displayName: { names[$0] }, groupTitle: { groups[$0] })
        #expect(t == NotificationText(title: "Project Team", body: "Bob: New message"))
    }

    @Test(arguments: ["missing-key", "no-e", "garbage", "unknown-sender"])
    func everyFailureFallsBack(_ failure: String) throws {
        let v = try vectors()[0]
        var info: [AnyHashable: Any] = ["e": v.e]
        var key: Data? = Data(base64Encoded: v.key)
        var lookup: (String) -> String? = { names[$0] }
        switch failure {
        case "missing-key": key = nil
        case "no-e": info = [:]
        case "garbage": info = ["e": "AQ=="]
        default: lookup = { _ in nil }
        }
        #expect(NotificationText.decide(userInfo: info, deviceKey: key, displayName: lookup, groupTitle: { _ in nil }) == .fallback)
    }
}
