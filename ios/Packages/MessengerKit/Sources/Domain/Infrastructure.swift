import Foundation

// Infrastructure boundaries (docs/01-system-architecture.md §2).
// DRAFT: the full surface of `MessagingTransport` and `EncryptionService` is defined at the
// D3/D4 decision gate, after spikes S1–S4. No implementation exists in the skeleton.

public protocol MessagingTransport: Sendable {
    var connectionStates: AsyncStream<ConnectionState> { get }
    func connect() async
    /// Background: close the socket but keep the server-side session resumable (XEP-0198),
    /// so the server starts sending pushes. Logout: end the session.
    func disconnect(keepingSessionResumable: Bool) async
}

public protocol EncryptionService: Sendable {
    /// Encrypts for all trusted devices of `recipients` and all other own devices.
    func encrypt(_ plaintext: Data, for recipients: [AccountAddress]) async throws -> Data
    func decrypt(_ ciphertext: Data, from sender: AccountAddress) async throws -> Data
}

public protocol PushService: Sendable {
    func register(deviceToken: Data) async throws
    func unregister() async throws
    func setMuted(until date: Date?, for conversation: ConversationID) async throws
}

public protocol AttachmentService: Sendable {
    /// Encrypts the file on the device, uploads the ciphertext, and returns the metadata
    /// that travels inside the encrypted message envelope.
    func upload(fileAt url: URL, mediaType: String) async throws -> Data
    func download(_ encryptedMetadata: Data) async throws -> URL
}

public protocol PersistenceService: Sendable {
    /// Removes all local data (logout).
    func eraseAll() async throws
}
