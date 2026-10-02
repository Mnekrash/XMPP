#if os(iOS)
import AppSecurity
import Foundation
import Testing

/// Runs inside the app on the iOS simulator (the Keychain needs a signed host app; a bare package test bundle
/// gets errSecMissingEntitlement -34018).
struct KeychainCredentialStoreTests {
    @Test func saveLoadReplaceDelete() throws {
        let store = KeychainCredentialStore(service: "tests.\(UUID().uuidString)")
        #expect(store.load() == nil)
        try store.save(StoredCredentials(username: "test1", password: "first"))
        #expect(store.load() == StoredCredentials(username: "test1", password: "first"))
        try store.save(StoredCredentials(username: "test1", password: "second"))   // replace, no duplicate error
        #expect(store.load()?.password == "second")
        store.delete()
        #expect(store.load() == nil)
    }

    @Test func servicesAreIsolated() throws {
        let a = KeychainCredentialStore(service: "tests.a.\(UUID().uuidString)")
        let b = KeychainCredentialStore(service: "tests.b.\(UUID().uuidString)")
        try a.save(StoredCredentials(username: "a", password: "1"))
        #expect(b.load() == nil)
        a.delete()
    }
}
#endif
