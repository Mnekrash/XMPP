import Foundation

/// Server endpoints from the build configuration (Config/*.xcconfig → Info.plist).
/// No host name is hardcoded in Swift source.
public struct ServerConfig: Sendable, Equatable {
    public let xmppDomain: String
    public let xmppHost: String
    public let xmppPort: UInt16
    public let mucDomain: String
    public let pushComponentJID: String
    public let appGroupID: String

    public enum LoadError: Error, Equatable {
        case missing(key: String)
        case invalid(key: String)
    }

    enum Key {
        static let xmppDomain = "MessengerXMPPDomain"
        static let xmppHost = "MessengerXMPPHost"
        static let xmppPort = "MessengerXMPPPort"
        static let mucDomain = "MessengerMUCDomain"
        static let pushComponentJID = "MessengerPushComponentJID"
        static let appGroupID = "MessengerAppGroup"
    }

    public init(infoDictionary: [String: Any]) throws(LoadError) {
        func hostName(_ key: String) throws(LoadError) -> String {
            guard let raw = infoDictionary[key] as? String else { throw .missing(key: key) }
            let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
            guard !value.isEmpty,
                  value.contains("."),
                  value.unicodeScalars.allSatisfy(allowed.contains),
                  !value.hasPrefix("."), !value.hasSuffix(".")
            else { throw .invalid(key: key) }
            return value
        }

        xmppDomain = try hostName(Key.xmppDomain)
        xmppHost = try hostName(Key.xmppHost)
        mucDomain = try hostName(Key.mucDomain)
        pushComponentJID = try hostName(Key.pushComponentJID)

        // App Group identifiers are case-sensitive: validate, do not normalize.
        guard let group = infoDictionary[Key.appGroupID] as? String else { throw .missing(key: Key.appGroupID) }
        guard group.hasPrefix("group."), group.count > "group.".count,
              group.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { throw .invalid(key: Key.appGroupID) }
        appGroupID = group

        guard let portString = infoDictionary[Key.xmppPort] as? String else { throw .missing(key: Key.xmppPort) }
        guard let port = UInt16(portString), port > 0 else { throw .invalid(key: Key.xmppPort) }
        xmppPort = port
    }
}
