import Foundation

/// Delivery state of an outgoing message. See docs/03-messaging-and-sync.md §2.1.
public enum MessageStatus: Int, Sendable, Codable, CaseIterable {
    case failed = -1
    case sending = 0
    case sent = 1
    case delivered = 2
    case read = 3

    /// Returns the status after an event reporting `new`.
    ///
    /// States only move forward (`read` never regresses to `delivered`), so events that arrive
    /// out of order are harmless. `failed` can only replace `sending`. From `failed`, a retry
    /// (`sending`) or a late server acknowledgement moves the message forward again.
    public func applying(_ new: MessageStatus) -> MessageStatus {
        switch (self, new) {
        case (.sending, .failed):
            return .failed
        case (_, .failed):
            return self
        case (.failed, _):
            return new
        default:
            return new.rawValue > rawValue ? new : self
        }
    }
}

public enum MessageDirection: Int, Sendable, Codable {
    case incoming = 0
    case outgoing = 1
}

public enum MessageKind: Int, Sendable, Codable {
    case text = 0
    case image = 1
    case video = 2
    case file = 3
    case voice = 4
    case system = 5
}

public struct Message: Identifiable, Hashable, Sendable {
    public let id: MessageID
    public let conversationID: ConversationID
    public let sender: AccountAddress
    public let direction: MessageDirection
    public let kind: MessageKind
    public var body: String?
    public var replyTo: MessageID?
    public let sentAt: Date
    public var editedAt: Date?
    public var isRetracted: Bool
    public var status: MessageStatus

    public init(
        id: MessageID,
        conversationID: ConversationID,
        sender: AccountAddress,
        direction: MessageDirection,
        kind: MessageKind,
        body: String?,
        replyTo: MessageID? = nil,
        sentAt: Date,
        editedAt: Date? = nil,
        isRetracted: Bool = false,
        status: MessageStatus
    ) {
        self.id = id
        self.conversationID = conversationID
        self.sender = sender
        self.direction = direction
        self.kind = kind
        self.body = body
        self.replyTo = replyTo
        self.sentAt = sentAt
        self.editedAt = editedAt
        self.isRetracted = isRetracted
        self.status = status
    }
}

public enum ConversationKind: Int, Sendable, Codable {
    case direct = 0
    case group = 1
}

/// One row of the chat list (denormalized summary, read from the local database).
public struct Conversation: Identifiable, Hashable, Sendable {
    public let id: ConversationID
    public let kind: ConversationKind
    public var title: String
    public var lastMessagePreview: String?
    public var lastActivityAt: Date?
    public var unreadCount: Int
    public var isPinned: Bool
    public var mutedUntil: Date?
    public var draft: String?

    public init(
        id: ConversationID,
        kind: ConversationKind,
        title: String,
        lastMessagePreview: String? = nil,
        lastActivityAt: Date? = nil,
        unreadCount: Int = 0,
        isPinned: Bool = false,
        mutedUntil: Date? = nil,
        draft: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.lastMessagePreview = lastMessagePreview
        self.lastActivityAt = lastActivityAt
        self.unreadCount = unreadCount
        self.isPinned = isPinned
        self.mutedUntil = mutedUntil
        self.draft = draft
    }

    public func isMuted(at date: Date) -> Bool {
        guard let mutedUntil else { return false }
        return mutedUntil > date
    }
}

public struct Contact: Identifiable, Hashable, Sendable {
    public var id: AccountAddress { address }
    public let address: AccountAddress
    public var displayName: String

    public init(address: AccountAddress, displayName: String) {
        self.address = address
        self.displayName = displayName
    }
}

/// Connection state as shown to the user ("Connecting…", "Updating…").
public enum ConnectionState: Sendable, Equatable {
    case offline
    case connecting
    case updating
    case online
}
