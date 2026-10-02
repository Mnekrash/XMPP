# Martin 3.2.4: TLS connector and certificate policy

**Status:** worked around in `XMPPTransport` (no change to Martin). Found by the macOS CI integration run, 2026-10-02.

## Defect

`SocketConnectorNetwork` (Martin's Network.framework connector) opens a plain TCP connection and expects TLS from an
external `NetworkProcessorProvider` in `Options.networkProcessorProviders` (empty by default; Tigase's own apps
ship an OpenSSL-based provider). Without one, `initTLSStack()` ends the connection immediately with
`.disconnected(.none)`. Every login then failed in 17 ms as an "unknown" error, even against an unreachable host.

## Defect 2: client SSL policy for the server certificate

Martin validates the server certificate with `SecPolicyCreateSSL(false, domain)`, i.e. the **client** SSL policy.
A certificate whose extended key usage is `serverAuth` only (the CI certificate; Let's Encrypt has issued
serverAuth-only certificates since 2026) fails that check, and the login ends as "no connection". Tigase fixed
the same issue in BeagleIM (tigase/beagle-im PR 168, "Validate server certificates with the server SSL policy").

## Workaround

- `AccountConnection` uses Martin's other connector, `SocketConnector` (CFStream).
  - It uses the **system TLS stack**.
  - It validates the server certificate against the **account domain** (`SecPolicyCreateSSL` + `SecTrustEvaluate`).
  - An unreachable server ends as `.timeout`, which maps to "no connection".
- The certificate is checked by `ServerCertificatePolicy` (Martin's `.customValidator` hook):
  `SecPolicyCreateSSL(true, domain)` + `SecTrustEvaluateWithError`, system trust store, nothing relaxed.
- `SocketConnector.Endpoint` cannot be created outside Martin. The configured host and port therefore reach it
  through `FixedEndpointResolver`: one direct-TLS record, no DNS lookup.
- Connecting by IP address (local server, docs/09 option B) still validates the certificate against the domain.

## Tests

- `Tests/XMPPTransportTests/FixedEndpointResolverTests.swift`:
  - the resolver returns the configured direct-TLS endpoint;
  - a canary fails if Martin's Network.framework options gain a default TLS provider.
- `Tests/XMPPTransportTests/ServerCertificatePolicyTests.swift` (fixed serverAuth-only fixture, fixed date):
  accepted for its domain, rejected for another domain; a canary shows that the client policy rejects it.
- `Tests/IntegrationTests` (macOS CI, real ejabberd behind a CI-only CA): login, wrong password, disabled account,
  unreachable server, temporary-password flow.

## Removal

Touches only `FixedEndpointResolver.swift`, `ServerCertificatePolicy.swift` and the connector options in `AccountConnection.connect`.
Authentication and UI are unaffected. Revisit together with D3: either Martin gains built-in TLS, or we adopt a
reviewed TLS provider for `SocketConnectorNetwork` (Network.framework, TLS 1.3).
