import Foundation

/// Stable application-level message identifier (lowercase UUID).
/// For own messages it is also sent as the stanza `id` and XEP-0359 `origin-id`.
public struct MessageID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func generate() -> MessageID {
        MessageID(rawValue: UUID().uuidString.lowercased())
    }

    public var description: String { rawValue }
}

/// Local conversation identifier (lowercase UUID).
public struct ConversationID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func generate() -> ConversationID {
        ConversationID(rawValue: UUID().uuidString.lowercased())
    }

    public var description: String { rawValue }
}

/// Internal network address of an account or a group (an XMPP bare JID, `local@domain`).
///
/// Never shown in the normal UI. Users see display names only.
public struct AccountAddress: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    /// Validates and normalizes a bare address. Returns `nil` for anything that is not
    /// exactly `local@domain` (no resource part, no whitespace).
    public init?(_ string: String) {
        let parts = string.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let local = parts.first, let domain = parts.last,
              !local.isEmpty, !domain.isEmpty,
              !string.contains("/"),
              string.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { return nil }
        rawValue = "\(local.lowercased())@\(domain.lowercased())"
    }

    public var localPart: String { String(rawValue.split(separator: "@")[0]) }
    public var domain: String { String(rawValue.split(separator: "@")[1]) }
    public var description: String { rawValue }
}
