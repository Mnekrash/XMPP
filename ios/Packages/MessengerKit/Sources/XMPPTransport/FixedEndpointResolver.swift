import Foundation
import Martin

/// Connection endpoint adapter for Martin 3.2.4 (docs/known-issues/martin-tls.md).
///
/// Martin's `SocketConnectorNetwork` (Network.framework) has no TLS of its own: it needs an external TLS
/// `NetworkProcessorProvider` (Tigase apps ship an OpenSSL-based one) and otherwise drops the connection at once.
/// Martin's `SocketConnector` uses the system TLS stack (CFStream) and validates the certificate against the
/// account domain with `SecPolicyCreateSSL`, which is what we want. Its endpoint type cannot be built outside
/// Martin, so the host and port reach it through this resolver: one direct-TLS record, no DNS lookup.
struct FixedEndpointResolver: DNSSrvResolver {
    let host: String
    let port: Int

    func resolve(domain: String, for jid: BareJID, completionHandler: @escaping (Result<XMPPSrvResult, DNSError>) -> Void) {
        let record = XMPPSrvRecord(port: port, weight: 0, priority: 0, target: host, directTls: true)
        completionHandler(.success(XMPPSrvResult(domain: domain, records: [record])))
    }

    func markAsInvalid(for domain: String, record: XMPPSrvRecord, for: TimeInterval) {}

    func markAsInvalid(for domain: String, host: String, port: Int, for: TimeInterval) {}
}
