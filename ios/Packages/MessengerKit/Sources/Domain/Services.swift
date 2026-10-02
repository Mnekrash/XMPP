import Foundation

// Product-level services used by the UI. The UI never sees XMPP or OMEMO details.
// Signatures are a first draft; they are refined in the phase that implements each service.

public protocol AuthService: Sendable {
    /// Logs in with the username only; the server domain comes from the build configuration.
    func logIn(username: String, password: String) async throws(UserFacingError)
    func logOut() async
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
