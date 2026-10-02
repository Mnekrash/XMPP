import Foundation
import Security
import Testing
@testable import XMPPTransport

/// Regression tests for the certificate policy (docs/known-issues/martin-tls.md).
/// Fixture: a test CA and a leaf for chat.it.test with extended key usage serverAuth only
/// (like current Let's Encrypt certificates). Leaf valid 2026-10-02 … 2027-10-02 (Apple rejects TLS server
/// certificates valid for more than 825 days); evaluated at a fixed date.
struct ServerCertificatePolicyTests {
    static let caDER = "MIIDKTCCAhGgAwIBAgIUcEFfnWdZsTJLGh/6cvAkMtp4OV0wDQYJKoZIhvcNAQELBQAwHDEaMBgGA1UEAwwRTWVzc2VuZ2VyIFRlc3QgQ0EwHhcNMjYxMDAyMjA1NDE4WhcNNDYwOTI3MjA1NDE4WjAcMRowGAYDVQQDDBFNZXNzZW5nZXIgVGVzdCBDQTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAMBlyWz6eeMfUBRSWp3/9MZ0kecDMaQMbr4eEXDAN8dsUo59Fbn4Ja8LPYbvW4AuNjoB4B9wJE6k/j3arTmpVIjqPYQlp8eZZQ8b+z6EyeBBS9eYdojVDHZRXKU8yMSh9PwGgpCEGQ+aLAO2Pjltht8BOTPWWwMixdEvS6uPgLJ5nizctum1dBg5TIDluFmb5n9ZTnlh6CB+7ikQyJ9gLfO0hJqqofjg4f+1FgtFiMTm0mUgvXwHxCHe+fwjORVkgkXpqi5ugrfOOAyDzmnVygDgYv9RY0iofMGBWi8aQlL6Zo2CzfWJtUMbd7EJ//sZTOZzEgffh/SI1qtlXrbqjYMCAwEAAaNjMGEwHQYDVR0OBBYEFCpmEyjgvbbAvE2GUHShYTA8bk2nMB8GA1UdIwQYMBaAFCpmEyjgvbbAvE2GUHShYTA8bk2nMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMA0GCSqGSIb3DQEBCwUAA4IBAQCSwDqUzTluh47/taZr8Xw2aj8lFjDuAl16AiYEz1r6u1JGZnSIh0ruk8f6fQPTs0tCxlis+ZyUq15E5DeTBpIEyJKnuFIf415CKJhHLo9tfZ2/Kv9juiwxkuwixuGdicgAonVKZOeBX3XlSB7lS4dTyIvMAdK6b2evd5GEwAJp8m3WtzA+sIfVAINs6GcQV4KCOLpizQ+k2tvPaI2jsfwyppRlH3pgf+eGi17KBFbK00tPTudDNMtlGbBlbkaDeuZ5TZLrKHr2F4vlMMDZNxIe6UszKcnrzRHnEHnurwX5hfHQtZ/HBPeHhO/S82ZSiRmK0GL9+tQetLAQMw0/MoBB"
    static let leafDER = "MIIDUTCCAjmgAwIBAgIUOOEeQP0CMQUyuz+3HqqpHzecfdMwDQYJKoZIhvcNAQELBQAwHDEaMBgGA1UEAwwRTWVzc2VuZ2VyIFRlc3QgQ0EwHhcNMjYxMDAyMjA1ODU5WhcNMjcxMDAyMjA1ODU5WjAXMRUwEwYDVQQDDAxjaGF0Lml0LnRlc3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDFvIyYPdFS0hmErxlIuEf2JyZCnd7XtZqWGgW0KMz3aQcVwleI34jnPw3hfDfXUjRUhqUeJ7ZNCZKiUXHxf2PYuDj6XvPTkdDhFNtGEXd1TzRMd1Vi95lwSN/AvfODEu2iYOCCIqO90XOJP3bfFHmOrEOJ4k1x2OJTMVCmb84k1TiV3aY3ItlDUimi/xPnRFakQVOGFWHISlaJuTMhBHvX3/Ze2KfCMeeXPrbJ6wE6L6TV9Gv2H5Y7j+JhIRikvQMuGususzqa0jTOjhexUcf8FU6q679PNSBizAY9rW8vsbs4ng53hxvwqgQwSTtZ/wlN+18yGwaLMc7nVaLkJZFJAgMBAAGjgY8wgYwwFwYDVR0RBBAwDoIMY2hhdC5pdC50ZXN0MBMGA1UdJQQMMAoGCCsGAQUFBwMBMA4GA1UdDwEB/wQEAwIFoDAMBgNVHRMBAf8EAjAAMB0GA1UdDgQWBBS1yfwrhR3Z1isKbZniIDVibdcJcTAfBgNVHSMEGDAWgBQqZhMo4L22wLxNhlB0oWEwPG5NpzANBgkqhkiG9w0BAQsFAAOCAQEAW1OwVSjrvSg12bU9k5YXZNynqalZwwp3rPQ/mBOo7WSukY30bLDddoh77gPZn2w84FAAKuFiYDB7M97369Jktcder7gOqY2lB32LyX2PlKZGLdXr9AmNcAYf5EHkfZ8NOr7rkYzo4jhSKK+Jue2smMNgxRpwxZfvMXs+BsNQh3zTEVOyj1FDuwErGEDAbOzQYjC2/jSBbQcQ3YUwB2s5ehEN2ySKXJxPv7NdqIS4Dm323oqGB+XDiEFl1Yra5dXT8HZxV+tI460b61ADmzi8JU17tRqrkBe9BTDdtZ4c4eX+IG/YlQ7vBM0MBNgwwzTl4P6IL0Htn7SKxyA7EdCHSQ=="

    private func trust() throws -> SecTrust {
        let ca = try #require(SecCertificateCreateWithData(nil, Data(base64Encoded: Self.caDER)! as CFData))
        let leaf = try #require(SecCertificateCreateWithData(nil, Data(base64Encoded: Self.leafDER)! as CFData))
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates([leaf, ca] as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
        let t = try #require(trust)
        SecTrustSetAnchorCertificates(t, [ca] as CFArray)
        SecTrustSetAnchorCertificatesOnly(t, true)
        SecTrustSetVerifyDate(t, Date(timeIntervalSince1970: 1_791_590_400) as CFDate)   // 2026-10-10
        return t
    }

    @Test func serverOnlyCertificateIsTrustedForItsDomain() throws {
        let failure = ServerCertificatePolicy.failure(try trust(), domain: "chat.it.test")
        #expect(failure == nil, "\(failure ?? "")")
    }

    @Test func otherDomainIsRejected() throws {
        #expect(!ServerCertificatePolicy.isTrusted(try trust(), domain: "chat.other.test"))
    }

    /// Canary for the Martin default: the client policy rejects a serverAuth-only certificate.
    /// If this starts failing, the platform behaviour changed; re-check the workaround.
    @Test func canaryClientPolicyRejectsServerOnlyCertificate() throws {
        let t = try trust()
        SecTrustSetPolicies(t, SecPolicyCreateSSL(false, "chat.it.test" as CFString))
        var error: CFError?
        #expect(!SecTrustEvaluateWithError(t, &error))
    }
}
