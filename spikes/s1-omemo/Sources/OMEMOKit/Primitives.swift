import Clibsodium
import Crypto
import CryptoExtras
import Foundation

/// Thin wrappers around established cryptographic libraries.
/// Nothing in this file implements a primitive; every operation delegates to swift-crypto or libsodium.
enum Primitives {
    enum Failure: Error, Equatable {
        case invalidKey
        case conversionFailed
        case authenticationFailed
    }

    static func ensureSodium() {
        _ = sodiumInit
    }

    private static let sodiumInit: Int32 = sodium_init()

    // MARK: Randomness

    static func randomBytes(_ count: Int) -> Data {
        ensureSodium()
        var bytes = [UInt8](repeating: 0, count: count)
        randombytes_buf(&bytes, count)
        return Data(bytes)
    }

    static func randomUInt32(upperBound: UInt32) -> UInt32 {
        ensureSodium()
        return randombytes_uniform(upperBound)
    }

    // MARK: HKDF / HMAC (SHA-256)

    static func hkdf(inputKeyMaterial: Data, salt: Data, info: Data, outputByteCount: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: inputKeyMaterial),
            salt: salt,
            info: info,
            outputByteCount: outputByteCount
        )
        return key.withUnsafeBytes { Data($0) }
    }

    static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// Constant-time comparison of two MACs.
    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return a.withUnsafeBytes { pa in
            b.withUnsafeBytes { pb in
                sodium_memcmp(pa.baseAddress!, pb.baseAddress!, a.count) == 0
            }
        }
    }

    // MARK: AES-256-CBC with PKCS#7 padding

    static func aesCBCEncrypt(key: Data, iv: Data, plaintext: Data) throws -> Data {
        try AES._CBC.encrypt(plaintext, using: SymmetricKey(data: key), iv: AES._CBC.IV(ivBytes: iv))
    }

    static func aesCBCDecrypt(key: Data, iv: Data, ciphertext: Data) throws -> Data {
        try AES._CBC.decrypt(ciphertext, using: SymmetricKey(data: key), iv: AES._CBC.IV(ivBytes: iv))
    }

    // MARK: X25519

    static func x25519PrivateKey() -> Data {
        Curve25519.KeyAgreement.PrivateKey().rawRepresentation
    }

    static func x25519PublicKey(privateKey: Data) throws -> Data {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey).publicKey.rawRepresentation
    }

    static func x25519(privateKey: Data, publicKey: Data) throws -> Data {
        let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        return try priv.sharedSecretFromKeyAgreement(with: pub).withUnsafeBytes { Data($0) }
    }

    // MARK: Ed25519

    static func ed25519PublicKey(seed: Data) throws -> Data {
        try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
    }

    static func ed25519Sign(seed: Data, message: Data) throws -> Data {
        try Curve25519.Signing.PrivateKey(rawRepresentation: seed).signature(for: message)
    }

    static func ed25519Verify(publicKey: Data, signature: Data, message: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: message)
    }

    // MARK: Ed25519 <-> X25519 conversion (libsodium)

    /// Converts an Ed25519 public key to its X25519 (Montgomery) form.
    static func ed25519PublicKeyToX25519(_ edPublicKey: Data) throws -> Data {
        ensureSodium()
        guard edPublicKey.count == 32 else { throw Failure.invalidKey }
        var out = [UInt8](repeating: 0, count: 32)
        let rc = edPublicKey.withUnsafeBytes { pk in
            crypto_sign_ed25519_pk_to_curve25519(&out, pk.bindMemory(to: UInt8.self).baseAddress!)
        }
        guard rc == 0 else { throw Failure.conversionFailed }
        return Data(out)
    }

    /// Derives the X25519 private scalar that corresponds to an Ed25519 seed.
    static func ed25519SeedToX25519PrivateKey(_ seed: Data) throws -> Data {
        ensureSodium()
        guard seed.count == 32 else { throw Failure.invalidKey }
        var pk = [UInt8](repeating: 0, count: 32)
        var sk = [UInt8](repeating: 0, count: 64)
        let rc1 = seed.withUnsafeBytes { s in
            crypto_sign_seed_keypair(&pk, &sk, s.bindMemory(to: UInt8.self).baseAddress!)
        }
        guard rc1 == 0 else { throw Failure.conversionFailed }
        var out = [UInt8](repeating: 0, count: 32)
        let rc2 = crypto_sign_ed25519_sk_to_curve25519(&out, sk)
        sodium_memzero(&sk, sk.count)
        guard rc2 == 0 else { throw Failure.conversionFailed }
        return Data(out)
    }
}
