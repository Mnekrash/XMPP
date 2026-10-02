@testable import Domain
import Testing

struct AccountAddressTests {
    @Test func normalizesCase() throws {
        let address = try #require(AccountAddress("Alice@Chat.Example.com"))
        #expect(address.rawValue == "alice@chat.example.com")
        #expect(address.localPart == "alice")
        #expect(address.domain == "chat.example.com")
    }

    @Test(arguments: ["", "alice", "@chat.example.com", "alice@", "a@b@c", "alice@chat.example.com/phone", "al ice@chat.example.com"])
    func rejectsInvalid(_ input: String) {
        #expect(AccountAddress(input) == nil)
    }
}

struct UserFacingErrorTests {
    @Test(arguments: [UserFacingError.cannotConnect, .invalidCredentials, .accountDisabled, .sendFailed,
                      .attachmentTooLarge, .storageFull, .unknown])
    func messagesHideProtocolDetails(_ error: UserFacingError) {
        let message = error.message.lowercased()
        for term in ["xmpp", "jid", "stanza", "omemo", "sasl", "tls"] {
            #expect(!message.contains(term), "'\(term)' leaks into: \(error.message)")
        }
        #expect(!message.isEmpty)
    }
}
