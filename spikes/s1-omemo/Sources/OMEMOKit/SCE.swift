import Foundation

/// Stanza Content Encryption envelope (XEP-0420) as profiled by OMEMO 2:
/// `<content>` with the protected elements, random `<rpad>`, `<from>` affix, and `<to>` affix for group chats.
public struct SCEEnvelope: Sendable, Equatable {
    public static let namespace = "urn:xmpp:sce:1"

    public var body: String
    public var from: String
    public var to: String?

    public init(body: String, from: String, to: String? = nil) {
        self.body = body
        self.from = from
        self.to = to
    }

    public func serialize() -> String {
        // Random padding of 0–199 characters hides the content length (base64 alphabet, from libsodium RNG).
        let padLength = Int(Primitives.randomUInt32(upperBound: 200))
        let pad = Primitives.randomBytes(padLength).base64EncodedString().prefix(padLength)
        var xml = "<envelope xmlns='\(Self.namespace)'><content>"
        xml += "<body xmlns='jabber:client'>\(XMLEscape.text(body))</body>"
        xml += "</content><rpad>\(pad)</rpad><from jid='\(XMLEscape.attribute(from))'/>"
        if let to { xml += "<to jid='\(XMLEscape.attribute(to))'/>" }
        xml += "</envelope>"
        return xml
    }

    public static func parse(_ xml: String) throws -> SCEEnvelope {
        let root = try XMLNode.parse(xml)
        guard root.localName == "envelope",
              let from = root.child("from")?.attributes["jid"],
              let body = root.child("content")?.child("body")?.text
        else { throw OMEMOError.malformedXML("SCE envelope") }
        return SCEEnvelope(body: body, from: from, to: root.child("to")?.attributes["jid"])
    }
}
