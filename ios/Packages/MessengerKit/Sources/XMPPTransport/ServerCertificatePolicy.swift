import Foundation
import Security

/// Server certificate check used instead of Martin's default (docs/known-issues/martin-tls.md).
///
/// Martin 3.2.4 evaluates the server's certificate with `SecPolicyCreateSSL(false, domain)`, the *client* SSL
/// policy, so a certificate that is only valid for server authentication (extended key usage `serverAuth`
/// alone, as issued by Let's Encrypt since 2026) is rejected. We evaluate with the server policy against the
/// account domain and the system trust store; nothing else is relaxed.
enum ServerCertificatePolicy {
    static func isTrusted(_ trust: SecTrust, domain: String) -> Bool {
        guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, domain as CFString)) == errSecSuccess else { return false }
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }
}
