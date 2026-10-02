import Foundation

// Product-level services used by the UI. The UI never sees XMPP or OMEMO details.
// Signatures are a first draft; they are refined in the phase that implements each service.

/// The signed-in account as the UI sees it (no network addresses).
public struct AccountInfo: Sendable, Equatable {
    public var username: String
    public var displayName: String?
    /// The administrator issued a temporary password; the app asks for a new one before continuing.
    public var mustChangePassword: Bool

    public init(username: String, displayName: String?, mustChangePassword: Bool) {
        self.username = username
        self.displayName = displayName
        self.mustChangePassword = mustChangePassword
    }
}

public protocol AuthService: Sendable {
    /// Logs in with the username only; the server comes from the build configuration.
    func logIn(username: String, password: String) async throws(UserFacingError) -> AccountInfo
    /// Signs in with credentials saved on this device. nil = no saved session or they were rejected.
    func restoreSession() async -> AccountInfo?
    /// Replaces the current password (e.g. the administrator's temporary one) and clears the change requirement.
    func changePassword(to newPassword: String) async throws(UserFacingError)
    func logOut() async
    /// Connection state for the UI, emitted on every change (new stream per caller).
    func connectionStates() async -> AsyncStream<ConnectionState>
    /// Reconnect if needed (app returned to the foreground).
    func resume() async
}

/// Developer-only diagnostics (hidden screen). Never shown in the normal UI.
public protocol DiagnosticsProviding: Sendable {
    func diagnostics() async -> [DiagnosticsEntry]
}

public struct DiagnosticsEntry: Sendable, Hashable, Identifiable {
    public var id: String { key }
    public var key: String
    public var value: String

    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }
}

public protocol ConversationService: Sendable {
    /// Chat list, ordered for display, emitted again on every local database change.
    func conversations() -> AsyncStream<[Conversation]>
    /// Keyset pagination: `before == nil` returns the newest page.
    func messages(in conversation: ConversationID, before: MessageID?, limit: Int) async throws -> [Message]
    func setPinned(_ pinned: Bool, for conversation: ConversationID) async throws
    func setMuted(until date: Date?, for conversation: ConversationID) async throws
    func saveDraft(_ text: String?, for conversation: ConversationID) async throws
    func hide(_ conversation: ConversationID) async throws
}

public protocol ChatService: Sendable {
    @discardableResult
    func sendText(_ text: String, in conversation: ConversationID, replyTo: MessageID?) async throws -> MessageID
    func edit(_ message: MessageID, newText: String) async throws
    func delete(_ message: MessageID, forEveryone: Bool) async throws
    /// Replaces this user's reactions on the message (empty set removes them).
    func setReactions(_ emojis: Set<String>, on message: MessageID) async throws
    func markRead(upTo message: MessageID, in conversation: ConversationID) async
}
