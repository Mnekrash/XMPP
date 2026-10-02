import Foundation

public enum OMEMOError: Error, Equatable, Sendable {
    case malformedXML(String)
    case invalidBundle(String)
    case badSignedPreKeySignature
    case unknownSignedPreKey(UInt32)
    case unknownPreKey(UInt32)
    case noSession(jid: String, deviceId: UInt32)
    case notEncryptedForThisDevice
    case payloadAuthenticationFailed
    case sceAffixMismatch(expected: String, found: String)
    case noRecipientDevices(String)
}

public struct SignedPreKey: Codable, Sendable, Equatable {
    public var id: UInt32
    public var privateKey: Data
    public var publicKey: Data
    public var signature: Data
    public var createdAt: Date
}

/// Public bundle of a device (XEP-0384 §"Bundle").
public struct Bundle: Codable, Sendable, Equatable {
    public var identityKey: Data          // Ed25519 public key
    public var signedPreKeyId: UInt32
    public var signedPreKey: Data         // X25519 public key
    public var signedPreKeySignature: Data
    public var preKeys: [UInt32: Data]    // id → X25519 public key

    public static let namespace = "urn:xmpp:omemo:2"

    public func xml() -> String {
        var xml = "<bundle xmlns='\(Self.namespace)'>"
        xml += "<spk id='\(signedPreKeyId)'>\(signedPreKey.base64EncodedString())</spk>"
        xml += "<spks>\(signedPreKeySignature.base64EncodedString())</spks>"
        xml += "<ik>\(identityKey.base64EncodedString())</ik><prekeys>"
        for (id, key) in preKeys.sorted(by: { $0.key < $1.key }) {
            xml += "<pk id='\(id)'>\(key.base64EncodedString())</pk>"
        }
        return xml + "</prekeys></bundle>"
    }

    public static func parse(_ xml: String) throws -> Bundle {
        let root = try XMLNode.parse(xml)
        func b64(_ node: XMLNode?) throws -> Data {
            guard let node, let data = Data(base64Encoded: node.text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw OMEMOError.invalidBundle("base64")
            }
            return data
        }
        guard root.localName == "bundle", let spk = root.child("spk"),
              let spkId = spk.attributes["id"].flatMap(UInt32.init)
        else { throw OMEMOError.invalidBundle("structure") }
        var preKeys: [UInt32: Data] = [:]
        for pk in root.child("prekeys")?.children("pk") ?? [] {
            guard let id = pk.attributes["id"].flatMap(UInt32.init) else { throw OMEMOError.invalidBundle("pk id") }
            preKeys[id] = try b64(pk)
        }
        return Bundle(identityKey: try b64(root.child("ik")), signedPreKeyId: spkId, signedPreKey: try b64(spk),
                      signedPreKeySignature: try b64(root.child("spks")), preKeys: preKeys)
    }
}

/// Own device key material. In the app the identity seed lives in the Keychain and the rest is
/// encrypted at rest (docs/02 §5.1); the spike keeps everything in one JSON file.
public struct OwnDevice: Codable, Sendable {
    public static let preKeyCount = 100
    public static let preKeyRefillThreshold = 90

    public let jid: String
    public let deviceId: UInt32
    public var label: String?
    let identitySeed: Data
    public private(set) var signedPreKey: SignedPreKey
    public private(set) var oldSignedPreKey: SignedPreKey?
    var preKeys: [UInt32: Data]          // id → X25519 private key
    var nextPreKeyId: UInt32 = 1

    public init(jid: String, deviceId: UInt32? = nil, label: String? = nil) throws {
        self.jid = jid
        // OMEMO 2 device ids: 1 … 2^31 − 1
        self.deviceId = deviceId ?? (Primitives.randomUInt32(upperBound: 0x7FFF_FFFE) + 1)
        self.label = label
        identitySeed = Primitives.randomBytes(32)
        signedPreKey = try Self.makeSignedPreKey(id: 1, seed: identitySeed)
        oldSignedPreKey = nil
        preKeys = [:]
        refillPreKeys()
    }

    public var identityKey: Data { (try? Primitives.ed25519PublicKey(seed: identitySeed)) ?? Data() }
    var identityX25519Private: Data { get throws { try Primitives.ed25519SeedToX25519PrivateKey(identitySeed) } }
    public var preKeyIds: [UInt32] { preKeys.keys.sorted() }

    static func makeSignedPreKey(id: UInt32, seed: Data) throws -> SignedPreKey {
        let priv = Primitives.x25519PrivateKey()
        let pub = try Primitives.x25519PublicKey(privateKey: priv)
        return SignedPreKey(id: id, privateKey: priv, publicKey: pub,
                            signature: try Primitives.ed25519Sign(seed: seed, message: pub), createdAt: Date())
    }

    /// Keeps the previous signed pre key for one more rotation period (reference behaviour).
    public mutating func rotateSignedPreKey() throws {
        oldSignedPreKey = signedPreKey
        signedPreKey = try Self.makeSignedPreKey(id: signedPreKey.id + 1, seed: identitySeed)
    }

    /// Returns true if pre keys were generated (bundle must be republished).
    @discardableResult
    public mutating func refillPreKeys() -> Bool {
        guard preKeys.count < Self.preKeyRefillThreshold || preKeys.isEmpty else { return false }
        while preKeys.count < Self.preKeyCount {
            preKeys[nextPreKeyId] = Primitives.x25519PrivateKey()
            nextPreKeyId += 1
        }
        return true
    }

    mutating func consumePreKey(_ id: UInt32) { preKeys[id] = nil }

    func signedPreKey(id: UInt32) -> SignedPreKey? {
        if signedPreKey.id == id { return signedPreKey }
        if oldSignedPreKey?.id == id { return oldSignedPreKey }
        return nil
    }

    public func bundle() throws -> Bundle {
        Bundle(identityKey: identityKey, signedPreKeyId: signedPreKey.id, signedPreKey: signedPreKey.publicKey,
               signedPreKeySignature: signedPreKey.signature,
               preKeys: try preKeys.mapValues { try Primitives.x25519PublicKey(privateKey: $0) })
    }

    /// `<device id=… label=… labelsig=…/>` for the device list node.
    public func deviceElementXML() throws -> String {
        guard let label else { return "<device id='\(deviceId)'/>" }
        let sig = try Primitives.ed25519Sign(seed: identitySeed, message: Data(label.utf8))
        return "<device id='\(deviceId)' label='\(XMLEscape.attribute(label))' labelsig='\(sig.base64EncodedString())'/>"
    }

    public static func verifyLabel(_ label: String, signature: Data, identityKey: Data) -> Bool {
        Primitives.ed25519Verify(publicKey: identityKey, signature: signature, message: Data(label.utf8))
    }
}
