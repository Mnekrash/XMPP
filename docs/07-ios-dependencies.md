# 07 — iOS Platform and Swift Dependency Evaluation

## 1. Platform baseline

- **Deployment target: iOS 18.0.** Same hardware coverage as iOS 17 (iPhone XS / XR and newer),
  plus iOS 18 SwiftUI scroll APIs (`onScrollGeometryChange`, improved `scrollPosition`).
  - Alternative: iOS 17. It gains no extra devices and loses APIs.
  - Alternative: iOS 26. Rejected because it drops iPhone XS/XR with no API we need.
- Build with the current Xcode / iOS SDK required by App Store Connect at submission time.
- Swift 6 language mode, strict concurrency, async/await, actors.
- Targets: app, `NotificationServiceExtension`. Shared App Group container (DB) and Keychain access group.

## 2. Native frameworks used

| Need | Framework |
|------|-----------|
| UI | SwiftUI; UIKit for the chat list/composer (`UICollectionView`, `UITextView`) |
| Socket + TLS | Network.framework (`NWConnection`, `NWProtocolTLS`), `NWPathMonitor` |
| XML streaming | libxml2 push parser (`xmlCreatePushParserCtxt`, part of the iOS SDK) |
| HTTP upload/download | URLSession (background sessions) |
| Crypto | CryptoKit (X25519, Ed25519, AES-GCM, HKDF, HMAC, SHA-2), CommonCrypto (AES-CBC) |
| Secrets | Security.framework (Keychain) |
| App lock | LocalAuthentication |
| Push | UserNotifications + `UNNotificationServiceExtension` |
| Media | PhotosUI (`PhotosPicker`), ImageIO (downsampling, thumbnails, EXIF stripping), AVFoundation (voice record/play, video export), AVKit, QuickLook |
| Logging | `os.Logger` (privacy-aware) |
| Tests | Swift Testing + XCTest |

## 3. Third-party candidates

### 3.1 XMPP client library

| Option | Language / licence | Maintenance | OMEMO | Verdict |
|--------|--------------------|-------------|-------|---------|
| **Martin** (Tigase) | Swift / **AGPL-3.0** (commercial licence on request) | Active | MartinOMEMO: legacy OMEMO via libsignal-protocol-c | Rejected by default: AGPL would force the whole app under AGPL. Legacy OMEMO only |
| XMPPFramework | Obj-C / BSD | Low activity | Legacy OMEMO module, outdated | Rejected: Obj-C, delegate-based, aging |
| xmpp-rs (tokio-xmpp) via UniFFI | Rust / MPL-2.0 | Active | No OMEMO 2 | Rejected: adds a Rust toolchain + FFI for little gain |
| **Own `XMPPCore`** | Swift / ours | — | — | **Chosen** |

Why our own client layer is acceptable here:

- Closed system: one server (ejabberd, pinned version), one client. We implement exactly the XEPs in
  [06-xep-matrix.md](06-xep-matrix.md), not the whole ecosystem.
- Estimated scope ~6–9 k lines: stream + SASL SCRAM + bind + SM + disco/caps + roster + messages +
  carbons + MAM + PEP/pubsub subset + MUC/MUC-Sub + upload slot + push enable + ad-hoc command.
- Hidden behind `MessagingTransport`. If Tigase licensing is negotiated later, swapping is contained.
- Testing: scripted server-transcript tests (no network) + integration tests against dockerized ejabberd.

### 3.2 OMEMO / Signal-protocol crypto

| Option | Licence | Protocol | Verdict |
|--------|---------|----------|---------|
| libsignal (Signal) Swift bindings | **AGPL-3.0** | Signal Protocol (PQXDH etc.), **not** OMEMO 2 wire-compatible | Rejected |
| libsignal-protocol-c | GPL-3.0, deprecated | Legacy OMEMO only | Rejected |
| libomemo-c | **GPL-3.0** | OMEMO 2 + legacy | Rejected for licence (OK only if the owner accepts GPL for the app) |
| vodozemac (Matrix) | Apache-2.0 | Olm/Megolm, not OMEMO | Rejected: wrong protocol |
| **Own `OMEMO` module** on CryptoKit + CommonCrypto + libsodium | ours | OMEMO 2 v0.9.x | **Chosen**; audited before production |

This is a *protocol implementation on top of reviewed primitives*, not custom cryptography. Reference
and test oracle: `python-omemo` / `python-twomemo` (MIT, by the XEP-0384 author), run in CI from
`/tools/omemo-oracle`.

### 3.3 Accepted dependencies (minimal set)

| Package | Licence | Why | Alternative |
|---------|---------|-----|-------------|
| **GRDB.swift** | MIT | SQLite with FTS5, migrations, `ValueObservation`, `DatabasePool` (WAL, multi-process safe) | SwiftData: no FTS, weak migration control, cross-process concerns. Core Data: no FTS5, heavier, harder to test migrations |
| **swift-sodium** (libsodium) | ISC | Ed25519 → X25519 public-key conversion (`crypto_sign_ed25519_pk_to_curve25519`), not available in CryptoKit | Hand-written field arithmetic: rejected (custom crypto) |
| **swift-protobuf** (Apple) | Apache-2.0 | OMEMO 2 messages are protobuf (`OMEMOMessage`, `OMEMOAuthenticatedMessage`, `OMEMOKeyExchange`) | Hand-rolled protobuf encoding: small but risky for a security parser |
| **XcodeGen** (build tool only, not shipped) | MIT | Generate `.xcodeproj` from `project.yml` | Committed `.xcodeproj` (merge conflicts), Tuist (heavier) |

Not used: analytics/ads/crash SDKs that see content, UI component frameworks, Firebase. A crash
reporter is optional later (Apple's built-in crash reports via Xcode Organizer / TestFlight are enough
for the MVP).

All dependencies are pinned to exact versions in `Package.resolved`. Updates go through a dedicated PR.

## 4. Server-side and tooling stack

| Component | Choice | Licence |
|-----------|--------|---------|
| XMPP server | ejabberd (official image, pinned) | GPL-2.0, server-side, not distributed in the app: OK |
| Database | PostgreSQL 17 | PostgreSQL |
| Reverse proxy | Caddy 2 | Apache-2.0 |
| Push gateway | Go 1.2x, `sideshow/apns2` (MIT), `mellium.im/xmpp` or a minimal XEP-0114 implementation | ours |
| OMEMO oracle (tests only) | Python 3, `twomemo`, `omemo`, `slixmpp` | MIT |
