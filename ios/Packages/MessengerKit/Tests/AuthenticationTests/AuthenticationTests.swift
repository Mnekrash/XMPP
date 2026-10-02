import AppSecurity
@testable import Authentication
import Domain
import Testing
import XMPPTransport

struct AuthenticationTests {
    @Test(arguments: [("test1", "test1"), ("  Test1 ", "test1"), ("test1@anything.example", "test1"), ("", "")])
    func usernameNormalisation(input: String, expected: String) {
        #expect(XMPPAuthService.normalize(input) == expected)
    }

    @Test func transportErrorsMapToUserFacingErrors() {
        #expect(XMPPAuthService.userError(TransportError.notAuthorized) == .invalidCredentials)
        #expect(XMPPAuthService.userError(TransportError.accountDisabled) == .accountDisabled)
        #expect(XMPPAuthService.userError(TransportError.unreachable) == .cannotConnect)
        #expect(XMPPAuthService.userError(TransportError.certificate) == .cannotConnect)
        #expect(XMPPAuthService.userError(TransportError.weakPassword) == .weakPassword)
        #expect(XMPPAuthService.userError(TransportError.failed("x")) == .unknown)
    }

    @Test func memoryCredentialStoreRoundTrip() throws {
        let store = MemoryCredentialStore()
        try store.save(StoredCredentials(username: "u", password: "p"))
        #expect(store.load() == StoredCredentials(username: "u", password: "p"))
        store.delete()
        #expect(store.load() == nil)
    }
}
