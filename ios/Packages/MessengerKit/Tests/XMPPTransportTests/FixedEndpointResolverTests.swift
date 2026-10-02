import Martin
import Testing
@testable import XMPPTransport

/// Regression tests for the connector choice (docs/known-issues/martin-tls.md).
struct FixedEndpointResolverTests {
    @Test func resolvesToTheConfiguredDirectTLSEndpoint() {
        let resolver = FixedEndpointResolver(host: "192.168.1.20", port: 5223)
        var resolved: XMPPSrvRecord?
        resolver.resolve(domain: "chat.example.com", for: BareJID(localPart: "test1", domain: "chat.example.com")) { result in
            resolved = try? result.get().record()
        }
        // The record's fields are internal to Martin; its description lists them.
        let text = resolved?.description ?? ""
        #expect(text.contains("port: 5223"))
        #expect(text.contains("target: 192.168.1.20"))
        #expect(text.contains("directTls: true"))
    }

    /// Canary: Martin's Network.framework connector still brings no TLS of its own. If this starts failing,
    /// Martin gained built-in TLS and the switch to SocketConnector can be revisited.
    @Test func canaryNetworkConnectorHasNoBuiltInTLS() {
        #expect(SocketConnectorNetwork.Options().networkProcessorProviders.isEmpty)
    }
}
