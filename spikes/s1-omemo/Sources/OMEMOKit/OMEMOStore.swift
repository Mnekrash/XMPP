import Foundation
import SwiftProtobuf

/// OMEMO 2 protocol/state layer: X3DH session building, per-device key encryption, payload encryption,
/// `<encrypted>` element serialization. Single-threaded by design (the app wraps it in an actor).
public struct OMEMOStore: Codable, Sendable {
    public struct DeviceAddress: Hashable, Codable, Sendable, CustomStringConvertible {
        public var jid: String
        public var deviceId: UInt32
        public init(jid: String, deviceId: UInt32) { self.jid = jid; self.deviceId = deviceId }
        public var description: String { "\(jid)/\(deviceId)" }
    }

    struct KeyExchangeParams: Codable, Sendable, Equatable {
        var preKeyId: UInt32
        var signedPreKeyId: UInt32
        var identityKey: Data
        var ephemeralKey: Data
    }

    struct Session: Codable, Sendable {
        enum Initiation: String, Codable { case active, passive }
        var initiation: Initiation
        var keyExchange: KeyExchangeParams
        var confirmed: Bool
        var associatedData: Data
        var ratchet: DoubleRatchet
        var peerIdentityKey: Data
    }

    public struct EncryptResult: Sendable {
        public var xml: String
        public var recipients: [DeviceAddress]
        public var keyExchangeRecipients: [DeviceAddress]
        public var missingBundles: [DeviceAddress]
    }

    public struct DecryptResult: Sendable {
        public var sender: DeviceAddress
        /// nil for an empty OMEMO message (no payload, e.g. a heartbeat).
        public var plaintext: Data?
        public var wasKeyExchange: Bool
        public var newSessionBuilt: Bool
        public var consumedPreKeyId: UInt32?
        public var bundleNeedsRepublish: Bool
        public var identityKeyChanged: Bool
    }

    static let x3dhInfo = Data("OMEMO X3DH".utf8)
    static let payloadInfo = Data("OMEMO Payload".utf8)

    public private(set) var own: OwnDevice
    var sessions: [String: Session] = [:]
    public private(set) var deviceLists: [String: [UInt32]] = [:]
    public private(set) var bundles: [String: Bundle] = [:]
    /// First identity key seen per device (TOFU/BTBV record).
    public private(set) var knownIdentityKeys: [String: Data] = [:]

    public init(own: OwnDevice) { self.own = own }

    private static func key(_ a: DeviceAddress) -> String { "\(a.jid)/\(a.deviceId)" }

    // MARK: Peer data (fed from PEP)

    public mutating func setDeviceList(jid: String, deviceIds: [UInt32]) {
        deviceLists[jid] = deviceIds
    }

    public mutating func setBundle(_ bundle: Bundle, for address: DeviceAddress) {
        bundles[Self.key(address)] = bundle
    }

    public func hasSession(with address: DeviceAddress) -> Bool { sessions[Self.key(address)] != nil }
    public func isConfirmed(_ address: DeviceAddress) -> Bool { sessions[Self.key(address)]?.confirmed ?? false }

    public mutating func deleteSession(with address: DeviceAddress) { sessions[Self.key(address)] = nil }

    public mutating func rotateSignedPreKey() throws { try own.rotateSignedPreKey() }

    public var skippedKeyCount: Int { sessions.values.reduce(0) { $0 + $1.ratchet.skipped.count } }

    // MARK: X3DH

    private mutating func buildActiveSession(with address: DeviceAddress, bundle: Bundle) throws -> Session {
        guard Primitives.ed25519Verify(publicKey: bundle.identityKey, signature: bundle.signedPreKeySignature,
                                       message: bundle.signedPreKey)
        else { throw OMEMOError.badSignedPreKeySignature }
        guard let (preKeyId, preKey) = bundle.preKeys.randomElement() else { throw OMEMOError.invalidBundle("no pre keys") }

        let ephemeral = Primitives.x25519PrivateKey()
        let ownIK = try own.identityX25519Private
        let otherIK = try Primitives.ed25519PublicKeyToX25519(bundle.identityKey)
        let dh1 = try Primitives.x25519(privateKey: ownIK, publicKey: bundle.signedPreKey)
        let dh2 = try Primitives.x25519(privateKey: ephemeral, publicKey: otherIK)
        let dh3 = try Primitives.x25519(privateKey: ephemeral, publicKey: bundle.signedPreKey)
        let dh4 = try Primitives.x25519(privateKey: ephemeral, publicKey: preKey)
        let secret = Primitives.hkdf(inputKeyMaterial: Data(repeating: 0xFF, count: 32) + dh1 + dh2 + dh3 + dh4,
                                     salt: Data(count: 32), info: Self.x3dhInfo, outputByteCount: 32)
        let ad = own.identityKey + bundle.identityKey
        let ratchet = try DoubleRatchet.active(sharedSecret: secret, recipientRatchetPub: bundle.signedPreKey)
        recordIdentity(bundle.identityKey, for: address)
        return Session(
            initiation: .active,
            keyExchange: KeyExchangeParams(preKeyId: preKeyId, signedPreKeyId: bundle.signedPreKeyId,
                                           identityKey: own.identityKey,
                                           ephemeralKey: try Primitives.x25519PublicKey(privateKey: ephemeral)),
            confirmed: false, associatedData: ad, ratchet: ratchet, peerIdentityKey: bundle.identityKey)
    }

    private func passiveSharedSecret(_ kex: KeyExchangeParams) throws -> (secret: Data, ad: Data, spk: SignedPreKey, preKey: Data) {
        guard let spk = own.signedPreKey(id: kex.signedPreKeyId) else { throw OMEMOError.unknownSignedPreKey(kex.signedPreKeyId) }
        guard let preKey = own.preKeys[kex.preKeyId] else { throw OMEMOError.unknownPreKey(kex.preKeyId) }
        let ownIK = try own.identityX25519Private
        let otherIK = try Primitives.ed25519PublicKeyToX25519(kex.identityKey)
        let dh1 = try Primitives.x25519(privateKey: spk.privateKey, publicKey: otherIK)
        let dh2 = try Primitives.x25519(privateKey: ownIK, publicKey: kex.ephemeralKey)
        let dh3 = try Primitives.x25519(privateKey: spk.privateKey, publicKey: kex.ephemeralKey)
        let dh4 = try Primitives.x25519(privateKey: preKey, publicKey: kex.ephemeralKey)
        let secret = Primitives.hkdf(inputKeyMaterial: Data(repeating: 0xFF, count: 32) + dh1 + dh2 + dh3 + dh4,
                                     salt: Data(count: 32), info: Self.x3dhInfo, outputByteCount: 32)
        return (secret, kex.identityKey + own.identityKey, spk, preKey)
    }

    @discardableResult
    private mutating func recordIdentity(_ identityKey: Data, for address: DeviceAddress) -> Bool {
        let k = Self.key(address)
        if let known = knownIdentityKeys[k] { return known != identityKey }
        knownIdentityKeys[k] = identityKey
        return false
    }

    // MARK: Encrypt

    /// Encrypts `plaintext` (an SCE envelope) for every known device of `recipientJids` and every other own device.
    public mutating func encrypt(_ plaintext: Data, for recipientJids: [String]) throws -> EncryptResult {
        let key = Primitives.randomBytes(32)
        let derived = Primitives.hkdf(inputKeyMaterial: key, salt: Data(count: 32), info: Self.payloadInfo, outputByteCount: 80)
        let ciphertext = try Primitives.aesCBCEncrypt(key: derived.subdata(in: 0..<32), iv: derived.subdata(in: 64..<80), plaintext: plaintext)
        let tag = Primitives.hmac(key: derived.subdata(in: 32..<64), data: ciphertext).prefix(16)
        return try encryptKeyMaterial(key + tag, payload: ciphertext, for: recipientJids)
    }

    /// Empty OMEMO message (no payload): advances/confirms sessions without content.
    public mutating func encryptEmpty(for recipientJids: [String]) throws -> EncryptResult {
        try encryptKeyMaterial(Data(count: 32), payload: nil, for: recipientJids)
    }

    private mutating func encryptKeyMaterial(_ keyMaterial: Data, payload: Data?, for recipientJids: [String]) throws -> EncryptResult {
        var targets: [DeviceAddress] = []
        for jid in Set(recipientJids + [own.jid]) {
            let ids = (deviceLists[jid] ?? []).filter { !(jid == own.jid && $0 == own.deviceId) }
            if ids.isEmpty && jid != own.jid { throw OMEMOError.noRecipientDevices(jid) }
            targets += ids.map { DeviceAddress(jid: jid, deviceId: $0) }
        }

        var keysByJid: [String: [String]] = [:]
        var result = EncryptResult(xml: "", recipients: [], keyExchangeRecipients: [], missingBundles: [])
        for target in targets.sorted(by: { ($0.jid, $0.deviceId) < ($1.jid, $1.deviceId) }) {
            let k = Self.key(target)
            if sessions[k] == nil {
                guard let bundle = bundles[k] else { result.missingBundles.append(target); continue }
                sessions[k] = try buildActiveSession(with: target, bundle: bundle)
            }
            var session = sessions[k]!
            let authMessage = try session.ratchet.encrypt(keyMaterial, associatedData: session.associatedData)
            sessions[k] = session
            var element: String
            if session.initiation == .active && !session.confirmed {
                var kex = Twomemo_OMEMOKeyExchange()
                kex.pkID = session.keyExchange.preKeyId
                kex.spkID = session.keyExchange.signedPreKeyId
                kex.ik = session.keyExchange.identityKey
                kex.ek = session.keyExchange.ephemeralKey
                kex.message = try Twomemo_OMEMOAuthenticatedMessage(serializedBytes: authMessage)
                let bytes: Data = try kex.serializedBytes()
                element = "<key rid='\(target.deviceId)' kex='true'>\(bytes.base64EncodedString())</key>"
                result.keyExchangeRecipients.append(target)
            } else {
                element = "<key rid='\(target.deviceId)'>\(authMessage.base64EncodedString())</key>"
            }
            keysByJid[target.jid, default: []].append(element)
            result.recipients.append(target)
        }

        var xml = "<encrypted xmlns='\(Bundle.namespace)'><header sid='\(own.deviceId)'>"
        for (jid, keys) in keysByJid.sorted(by: { $0.key < $1.key }) {
            xml += "<keys jid='\(XMLEscape.attribute(jid))'>\(keys.joined())</keys>"
        }
        xml += "</header>"
        if let payload { xml += "<payload>\(payload.base64EncodedString())</payload>" }
        result.xml = xml + "</encrypted>"
        return result
    }

    // MARK: Decrypt

    public mutating func decrypt(_ encryptedXML: String, from senderJid: String) throws -> DecryptResult {
        let root = try XMLNode.parse(encryptedXML)
        guard root.localName == "encrypted", let header = root.child("header"),
              let sid = header.attributes["sid"].flatMap(UInt32.init)
        else { throw OMEMOError.malformedXML("encrypted") }
        let sender = DeviceAddress(jid: senderJid, deviceId: sid)

        guard let keyNode = header.children("keys").first(where: { $0.attributes["jid"] == own.jid })?
                .children("key").first(where: { $0.attributes["rid"].flatMap(UInt32.init) == own.deviceId }),
              let keyData = Data(base64Encoded: keyNode.text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw OMEMOError.notEncryptedForThisDevice }
        let isKex = ["true", "1"].contains(keyNode.attributes["kex"] ?? "false")

        var result = DecryptResult(sender: sender, plaintext: nil, wasKeyExchange: isKex, newSessionBuilt: false,
                                   consumedPreKeyId: nil, bundleNeedsRepublish: false, identityKeyChanged: false)
        let k = Self.key(sender)
        let keyMaterial: Data
        // Nothing is committed until the payload has been authenticated (transactional decrypt).
        var pendingSession: Session
        var consumedPreKey: UInt32?

        if isKex {
            let kexMessage: Twomemo_OMEMOKeyExchange
            do { kexMessage = try Twomemo_OMEMOKeyExchange(serializedBytes: keyData) } catch {
                throw OMEMOError.malformedXML("OMEMOKeyExchange")
            }
            let params = KeyExchangeParams(preKeyId: kexMessage.pkID, signedPreKeyId: kexMessage.spkID,
                                           identityKey: kexMessage.ik, ephemeralKey: kexMessage.ek)
            let inner: Data = try kexMessage.message.serializedBytes()
            if var existing = sessions[k], existing.keyExchange == params {
                // Same key exchange as the existing session: a repeated kex wrapper → normal message.
                keyMaterial = try existing.ratchet.decrypt(inner, associatedData: existing.associatedData)
                pendingSession = existing
            } else {
                let x3dh = try passiveSharedSecret(params)
                let innerMessage = try Twomemo_OMEMOMessage(serializedBytes: kexMessage.message.message)
                var ratchet = try DoubleRatchet.passive(sharedSecret: x3dh.secret, ownRatchetPriv: x3dh.spk.privateKey,
                                                        otherRatchetPub: innerMessage.dhPub)
                keyMaterial = try ratchet.decrypt(inner, associatedData: x3dh.ad)
                pendingSession = Session(initiation: .passive, keyExchange: params, confirmed: true,
                                         associatedData: x3dh.ad, ratchet: ratchet, peerIdentityKey: params.identityKey)
                consumedPreKey = params.preKeyId
            }
        } else {
            guard var session = sessions[k] else { throw OMEMOError.noSession(jid: senderJid, deviceId: sid) }
            keyMaterial = try session.ratchet.decrypt(keyData, associatedData: session.associatedData)
            session.confirmed = true
            pendingSession = session
        }

        guard keyMaterial.count == 48 || keyMaterial.count == 32 else { throw OMEMOError.malformedXML("key material") }
        if let payloadNode = root.child("payload") {
            guard keyMaterial.count == 48,
                  let payload = Data(base64Encoded: payloadNode.text.trimmingCharacters(in: .whitespacesAndNewlines))
            else { throw OMEMOError.malformedXML("payload") }
            let derived = Primitives.hkdf(inputKeyMaterial: keyMaterial.prefix(32), salt: Data(count: 32),
                                          info: Self.payloadInfo, outputByteCount: 80)
            let tag = Primitives.hmac(key: derived.subdata(in: 32..<64), data: payload).prefix(16)
            guard Primitives.constantTimeEqual(Data(tag), Data(keyMaterial.suffix(16))) else {
                throw OMEMOError.payloadAuthenticationFailed
            }
            result.plaintext = try Primitives.aesCBCDecrypt(key: derived.subdata(in: 0..<32),
                                                            iv: derived.subdata(in: 64..<80), ciphertext: payload)
        }

        // Commit.
        sessions[k] = pendingSession
        if let consumedPreKey {
            result.identityKeyChanged = recordIdentity(pendingSession.peerIdentityKey, for: sender)
            own.consumePreKey(consumedPreKey)
            own.refillPreKeys()
            result.consumedPreKeyId = consumedPreKey
            result.newSessionBuilt = true
            result.bundleNeedsRepublish = true
        }
        return result
    }
}
