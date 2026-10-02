import Foundation
import Security

/// Server certificate check used instead of Martin's default (docs/known-issues/martin-tls.md).
///
/// Martin 3.2.4 evaluates the server's certificate with `SecPolicyCreateSSL(false, domain)`, the *client* SSL
/// policy, so a certificate that is only valid for server authentication (extended key usage `serverAuth`
/// alone, as issued by Let's Encrypt since 2026) is rejected. We evaluate with the server policy against the
/// account domain and the system trust store; nothing else is relaxed.
enum ServerCertificatePolicy {
    /// nil = trusted; otherwise the system's reason (diagnostics only, never shown to the user).
    static func failure(_ trust: SecTrust, domain: String) -> String? {
        let status = SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, domain as CFString))
        guard status == errSecSuccess else { return "SecTrustSetPolicies \(status)" }
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { return nil }
        return error.map { CFErrorCopyDescription($0) as String } ?? "not trusted"
    }

    static func isTrusted(_ trust: SecTrust, domain: String) -> Bool {
        failure(trust, domain: domain) == nil
    }
}
