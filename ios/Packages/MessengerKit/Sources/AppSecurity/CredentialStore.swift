import Foundation
#if canImport(Security)
import Security
#endif

/// Saved login of this device. MVP: the password is kept in the Keychain to reconnect silently
/// (docs/02 §4). Later replaced by a per-device FAST token.
public struct StoredCredentials: Codable, Sendable, Equatable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

public protocol CredentialStore: Sendable {
    func load() -> StoredCredentials?
    func save(_ credentials: StoredCredentials) throws
    func delete()
}

#if canImport(Security)
/// Keychain-backed store: generic password, this device only, available after the first unlock
/// (needed for reconnects in the background), never synchronised to iCloud.
public struct KeychainCredentialStore: CredentialStore {
    public enum Failure: Error, Equatable { case keychain(OSStatus) }

    private let service: String
    private let account = "primary"

    public init(service: String) {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() -> StoredCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(StoredCredentials.self, from: data)
    }

    public func save(_ credentials: StoredCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    public func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
#endif

/// In-memory store for tests and previews.
public final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: StoredCredentials?

    public init(_ value: StoredCredentials? = nil) {
        self.value = value
    }

    public func load() -> StoredCredentials? { lock.withLock { value } }
    public func save(_ credentials: StoredCredentials) throws { lock.withLock { value = credentials } }
    public func delete() { lock.withLock { value = nil } }
}
