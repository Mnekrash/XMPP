import Foundation
import SwiftProtobuf

/// Double Ratchet state machine as profiled by XEP-0384 v0.9.x (urn:xmpp:omemo:2).
///
/// Building blocks (all from Primitives):
///   - root chain:    HKDF-SHA-256(ikm: DH output, salt: root key, info: "OMEMO Root Chain") → 64 bytes
///   - message chain: message key = HMAC(ck, 0x01), next chain key = HMAC(ck, 0x02)
///   - AEAD:          HKDF(mk, salt 0^32, "OMEMO Message Key Material") → 80 bytes → AES-256-CBC + HMAC-SHA-256/16
struct DoubleRatchet: Codable, Sendable, Equatable {
    enum Failure: Error, Equatable {
        case malformedMessage
        case tooManySkippedKeys
        case duplicateMessage
        case authenticationFailed
        case noReceivingChain
    }

    struct SkippedKey: Codable, Sendable, Equatable {
        var ratchetPub: Data
        var n: UInt32
        var messageKey: Data
    }

    static let rootInfo = Data("OMEMO Root Chain".utf8)
    static let messageKeyInfo = Data("OMEMO Message Key Material".utf8)
    static let tagLength = 16

    /// Python reference defaults (python-twomemo 2.1.0).
    static let maxSkippedPerMessage = 1000
    static let maxSkippedPerSession = 1000

    private(set) var rootKey: Data
    private(set) var ownRatchetPriv: Data
    private(set) var otherRatchetPub: Data
    private(set) var sendingChainKey: Data?
    private(set) var sendingN: UInt32 = 0
    private(set) var previousSendingN: UInt32?
    private(set) var receivingChainKey: Data?
    private(set) var receivingN: UInt32 = 0
    private(set) var skipped: [SkippedKey] = []

    // MARK: Initialisation

    /// Active party: the recipient's signed pre key is the first remote ratchet key.
    static func active(sharedSecret: Data, recipientRatchetPub: Data) throws -> DoubleRatchet {
        var dr = DoubleRatchet(
            rootKey: sharedSecret,
            ownRatchetPriv: Primitives.x25519PrivateKey(),
            otherRatchetPub: recipientRatchetPub
        )
        try dr.replaceSendingChain()
        return dr
    }

    /// Passive party: the own signed pre key is the first own ratchet key.
    static func passive(sharedSecret: Data, ownRatchetPriv: Data, otherRatchetPub: Data) throws -> DoubleRatchet {
        var dr = DoubleRatchet(rootKey: sharedSecret, ownRatchetPriv: ownRatchetPriv, otherRatchetPub: otherRatchetPub)
        try dr.replaceReceivingChain()
        dr.ownRatchetPriv = Primitives.x25519PrivateKey()
        try dr.replaceSendingChain()
        return dr
    }

    private init(rootKey: Data, ownRatchetPriv: Data, otherRatchetPub: Data) {
        self.rootKey = rootKey
        self.ownRatchetPriv = ownRatchetPriv
        self.otherRatchetPub = otherRatchetPub
    }

    // MARK: Chains

    private mutating func rootStep() throws -> Data {
        let dh = try Primitives.x25519(privateKey: ownRatchetPriv, publicKey: otherRatchetPub)
        let out = Primitives.hkdf(inputKeyMaterial: dh, salt: rootKey, info: Self.rootInfo, outputByteCount: 64)
        rootKey = out.prefix(32)
        return out.suffix(32)
    }

    private mutating func replaceSendingChain() throws {
        previousSendingN = sendingChainKey == nil ? nil : sendingN
        sendingChainKey = try rootStep()
        sendingN = 0
    }

    private mutating func replaceReceivingChain() throws {
        receivingChainKey = try rootStep()
        receivingN = 0
    }

    private static func chainStep(_ chainKey: Data) -> (next: Data, messageKey: Data) {
        (Primitives.hmac(key: chainKey, data: Data([0x02])), Primitives.hmac(key: chainKey, data: Data([0x01])))
    }

    private mutating func nextReceivingKey() throws -> Data {
        guard let ck = receivingChainKey else { throw Failure.noReceivingChain }
        let step = Self.chainStep(ck)
        receivingChainKey = step.next
        receivingN += 1
        return step.messageKey
    }

    // MARK: Encrypt / decrypt (returns/accepts serialized OMEMOAuthenticatedMessage)

    mutating func encrypt(_ plaintext: Data, associatedData: Data) throws -> Data {
        guard let ck = sendingChainKey else { throw Failure.malformedMessage }
        let header = (dhPub: try Primitives.x25519PublicKey(privateKey: ownRatchetPriv), pn: previousSendingN ?? 0, n: sendingN)
        let step = Self.chainStep(ck)
        sendingChainKey = step.next
        sendingN += 1
        return try Self.aeadEncrypt(plaintext, messageKey: step.messageKey, associatedData: associatedData, dhPub: header.dhPub, pn: header.pn, n: header.n)
    }

    /// Decrypts on a copy of the state; the state is only updated if authentication succeeds.
    mutating func decrypt(_ authenticatedMessage: Data, associatedData: Data) throws -> Data {
        let auth: Twomemo_OMEMOAuthenticatedMessage
        let message: Twomemo_OMEMOMessage
        do {
            auth = try Twomemo_OMEMOAuthenticatedMessage(serializedBytes: authenticatedMessage)
            message = try Twomemo_OMEMOMessage(serializedBytes: auth.message)
        } catch {
            throw Failure.malformedMessage
        }

        if let index = skipped.firstIndex(where: { $0.ratchetPub == message.dhPub && $0.n == message.n }) {
            let plaintext = try Self.aeadDecrypt(auth: auth, message: message, messageKey: skipped[index].messageKey, associatedData: associatedData)
            skipped.remove(at: index)
            return plaintext
        }

        var next = self
        var newSkipped: [SkippedKey] = []
        if message.dhPub != next.otherRatchetPub {
            if next.receivingChainKey != nil {
                let count = Int(message.pn) - Int(next.receivingN)
                if count > Self.maxSkippedPerMessage {
                    // Reference behaviour: warn and do not compute keys of the abandoned chain.
                } else if count > 0 {
                    for _ in 0..<count {
                        let n = next.receivingN
                        newSkipped.append(SkippedKey(ratchetPub: next.otherRatchetPub, n: n, messageKey: try next.nextReceivingKey()))
                    }
                }
            }
            next.otherRatchetPub = message.dhPub
            try next.replaceReceivingChain()
            next.ownRatchetPriv = Primitives.x25519PrivateKey()
            try next.replaceSendingChain()
        }
        let count = Int(message.n) - Int(next.receivingN)
        if count > Self.maxSkippedPerMessage { throw Failure.tooManySkippedKeys }
        if count > 0 {
            for _ in 0..<count {
                let n = next.receivingN
                newSkipped.append(SkippedKey(ratchetPub: next.otherRatchetPub, n: n, messageKey: try next.nextReceivingKey()))
            }
        }
        if message.n < next.receivingN { throw Failure.duplicateMessage }
        let messageKey = try next.nextReceivingKey()

        let plaintext = try Self.aeadDecrypt(auth: auth, message: message, messageKey: messageKey, associatedData: associatedData)
        next.skipped.append(contentsOf: newSkipped)
        if next.skipped.count > Self.maxSkippedPerSession {
            next.skipped.removeFirst(next.skipped.count - Self.maxSkippedPerSession)
        }
        self = next
        return plaintext
    }

    // MARK: AEAD (XEP-0384 §"Message Encryption")

    private static func deriveAEADKeys(_ messageKey: Data) -> (enc: Data, auth: Data, iv: Data) {
        let out = Primitives.hkdf(inputKeyMaterial: messageKey, salt: Data(count: 32), info: messageKeyInfo, outputByteCount: 80)
        return (out.subdata(in: 0..<32), out.subdata(in: 32..<64), out.subdata(in: 64..<80))
    }

    private static func aeadEncrypt(_ plaintext: Data, messageKey: Data, associatedData: Data, dhPub: Data, pn: UInt32, n: UInt32) throws -> Data {
        let keys = deriveAEADKeys(messageKey)
        var message = Twomemo_OMEMOMessage()
        message.n = n
        message.pn = pn
        message.dhPub = dhPub
        message.ciphertext = try Primitives.aesCBCEncrypt(key: keys.enc, iv: keys.iv, plaintext: plaintext)
        let messageBytes: Data = try message.serializedBytes()
        var auth = Twomemo_OMEMOAuthenticatedMessage()
        auth.mac = Primitives.hmac(key: keys.auth, data: associatedData + messageBytes).prefix(tagLength)
        auth.message = messageBytes
        return try auth.serializedBytes()
    }

    private static func aeadDecrypt(auth: Twomemo_OMEMOAuthenticatedMessage, message: Twomemo_OMEMOMessage, messageKey: Data, associatedData: Data) throws -> Data {
        let keys = deriveAEADKeys(messageKey)
        let mac = Primitives.hmac(key: keys.auth, data: associatedData + auth.message).prefix(tagLength)
        guard Primitives.constantTimeEqual(Data(mac), auth.mac) else { throw Failure.authenticationFailed }
        do {
            return try Primitives.aesCBCDecrypt(key: keys.enc, iv: keys.iv, ciphertext: message.ciphertext)
        } catch {
            throw Failure.authenticationFailed
        }
    }
}
