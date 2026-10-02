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
| XML streaming | provided by the chosen XMPP library (libxml2 push parser only if we end up writing our own transport) |
| HTTP upload/download | URLSession (background sessions) |
| Crypto | CryptoKit (X25519, Ed25519, AES-GCM, HKDF, HMAC, SHA-2), CommonCrypto (AES-CBC) |
| Secrets | Security.framework (Keychain) |
| App lock | LocalAuthentication |
| Push | UserNotifications + `UNNotificationServiceExtension` |
| Media | PhotosUI (`PhotosPicker`), ImageIO (downsampling, thumbnails, EXIF stripping), AVFoundation (voice record/play, video export), AVKit, QuickLook |
| Logging | `os.Logger` (privacy-aware) |
| Tests | Swift Testing + XCTest |

## 3. Third-party candidates

### 3.1 XMPP transport — OPEN, decided by spike S1

Preference: **use an existing transport library behind `MessagingTransport`.** We write our own only if
the spike shows it is necessary.

| Option | Language / licence | What must be confirmed in S1 |
|--------|--------------------|------------------------------|
| **Martin** (Tigase) — primary candidate | Swift; AGPL-3.0 **or commercial licence from Tigase** | Commercial licence terms and price; Swift 6 / strict-concurrency compatibility; SM resume, MAM paging, carbons, MUC, MUC/Sub (ejabberd), XEP-0357 enable with publish-options, HTTP Upload; behaviour on network-path change; how much its Combine-based API leaks through our adapter |
| XMPPFramework | Obj-C / BSD | Fallback only: low maintenance activity, Obj-C delegates |
| xmpp-rs via UniFFI | Rust / MPL-2.0 | Only if both of the above fail: adds a Rust toolchain + FFI |
| Own minimal transport | Swift / ours | Only if the candidates fail on licence or on reliability scenarios from S4. Scope would be limited to the XEP matrix |

Rule regardless of the choice: no library type crosses the `MessagingTransport` boundary. The adapter
module (`XMPPTransport`) is the only code that imports the library.

### 3.2 OMEMO 2 — OPEN, decided by spike S1

| Option | Licence | What must be confirmed in S1 |
|--------|---------|------------------------------|
| **Martin-OMEMO** (Tigase) | AGPL-3.0 / commercial | Does it implement `urn:xmpp:omemo:2` (XEP-0384 v0.8+) or only legacy `eu.siacs.conversations.axolotl`? Which crypto backend? Licence terms |
| libomemo-c | GPL-3.0 | Implements OMEMO 2 + legacy (C). Usable only if the GPL is acceptable for the app or a different licence can be obtained |
| libsignal (Signal) | AGPL-3.0 | Signal Protocol variant (PQXDH); **not** OMEMO 2 wire-compatible → not a candidate as is |
| vodozemac | Apache-2.0 | Olm/Megolm → not a candidate |
| **Own XEP-0384 protocol/state layer** on established libraries | ours | Last resort. Primitives only from reviewed libraries (below); our code = bundle/device-list handling, X3DH + Double Ratchet *state machine* per spec, SCE envelope, session store |

Primitive requirements (fixed by XEP-0384 v0.9.1, `urn:xmpp:omemo:2`):

| Primitive | Required by OMEMO 2 for | Source library (if we implement the protocol layer) |
|-----------|--------------------------|------------------------------------------------------|
| X25519 | X3DH, ratchet DH | CryptoKit `Curve25519.KeyAgreement` |
| Ed25519 | identity key, SPK signature, label signature | CryptoKit `Curve25519.Signing` |
| Ed25519 → X25519 conversion | DH with the identity key | libsodium `crypto_sign_ed25519_pk_to_curve25519` / `…_sk_to_curve25519` |
| HKDF-SHA-256, HMAC-SHA-256 | KDF chains, payload/message keys | CryptoKit |
| **AES-256-CBC** + HMAC-SHA-256 (truncated to 16 bytes) | message and payload encryption — **not AES-GCM** (per spec) | CommonCrypto `CCCrypt` |
| Protobuf | OMEMO wire messages | swift-protobuf |

AES-256-GCM is used for **attachments** (D8), not inside OMEMO 2.

Interoperability oracles (independent implementations) for S1:

- `python-omemo` + `python-twomemo` (MIT, by the XEP-0384 author) + `slixmpp`: scriptable in CI.
- A second independent OMEMO 2 client where practical (e.g. one based on QXmpp/libomemo-c). Its OMEMO 2
  support must be verified before relying on it.

### 3.3 Accepted dependencies (minimal set)

| Package | Licence | Why | Alternative |
|---------|---------|-----|-------------|
| **GRDB.swift** | MIT | SQLite with FTS5, migrations, `ValueObservation`, `DatabasePool` (WAL, multi-process safe) | SwiftData: no FTS, weak migration control, cross-process concerns. Core Data: no FTS5, heavier, harder to test migrations |
| swift-sodium (libsodium) — *only if we implement the OMEMO protocol layer* | ISC | Ed25519 → X25519 conversion, not available in CryptoKit | Hand-written field arithmetic: forbidden (custom crypto) |
| swift-protobuf (Apple) — *only if we implement the OMEMO protocol layer* | Apache-2.0 | OMEMO 2 messages are protobuf (`OMEMOMessage`, `OMEMOAuthenticatedMessage`, `OMEMOKeyExchange`) | Hand-rolled protobuf encoding: small but risky for a security parser |
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
