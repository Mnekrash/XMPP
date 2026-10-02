import Crypto
import Foundation

/// Decrypted content of the APNs field `e` (sealed by the push gateway with the per-device key).
public struct Envelope: Codable, Equatable, Sendable {
    public var v: Int
    public var sender: String?
    public var conv: String?
    public var count: Int?
}

public enum EnvelopeError: Error, Equatable {
    case malformed
    case unsupportedVersion(UInt8)
    case authenticationFailed
}

public enum NotificationEnvelope {
    public static let version: UInt8 = 1

    /// base64(version ‖ nonce(12) ‖ AES-256-GCM ciphertext ‖ tag(16)), AAD = version byte.
    public static func open(_ base64: String, deviceKey: Data) throws -> Envelope {
        guard let raw = Data(base64Encoded: base64), raw.count >= 1 + 12 + 16 else { throw EnvelopeError.malformed }
        guard raw[raw.startIndex] == version else { throw EnvelopeError.unsupportedVersion(raw[raw.startIndex]) }
        let body = raw.dropFirst()
        do {
            let box = try AES.GCM.SealedBox(combined: body)
            let plain = try AES.GCM.open(box, using: SymmetricKey(data: deviceKey), authenticating: Data([version]))
            return try JSONDecoder().decode(Envelope.self, from: plain)
        } catch is DecodingError {
            throw EnvelopeError.malformed
        } catch {
            throw EnvelopeError.authenticationFailed
        }
    }

    /// Per-device opaque conversation id (APNs thread-id and the gateway mute key). Same formula as the gateway.
    public static func opaqueID(deviceKey: Data, conversation: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("thread:\(conversation)".utf8), using: SymmetricKey(data: deviceKey))
        return Data(mac).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// What the NSE shows. Rules (docs/04 §2.2): any failure → the generic fallback; never message text.
public struct NotificationText: Equatable, Sendable {
    public static let fallbackTitle = "New message"
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }

    public static let fallback = NotificationText(title: fallbackTitle, body: "")

    /// - Parameters:
    ///   - userInfo: the APNs payload as delivered to the extension
    ///   - deviceKey: from the shared Keychain; nil if unavailable (e.g. before first unlock)
    ///   - displayName: lookup into the shared contact cache (bare JID → name); nil if unknown
    ///   - groupTitle: lookup for group conversations (room JID → title)
    public static func decide(userInfo: [AnyHashable: Any], deviceKey: Data?,
                              displayName: (String) -> String?, groupTitle: (String) -> String?) -> NotificationText {
        guard let e = userInfo["e"] as? String, let deviceKey,
              let envelope = try? NotificationEnvelope.open(e, deviceKey: deviceKey),
              let conv = envelope.conv
        else { return .fallback }
        if let room = groupTitle(conv) {
            // Group: sender is room/nick (MUC/Sub); show "Group" with the nick if present.
            let nick = envelope.sender.flatMap { $0.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) }
            return NotificationText(title: room, body: nick.map { "\($0): \(fallbackTitle)" } ?? fallbackTitle)
        }
        guard let name = displayName(conv) else { return .fallback }
        return NotificationText(title: name, body: fallbackTitle)
    }
}
