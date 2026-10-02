# Private Messenger — Architecture Documentation

Status: **APPROVED WITH CHANGES** (owner review 2026-10-02, see below). D3/D4 remain open until spike S1.
Date: 2026-10-02.

This folder holds the architecture for a private iPhone messenger. It uses XMPP as an
invisible transport and OMEMO 2 for end-to-end encryption. The skeleton
(Task 2) starts only after this architecture is approved.

## Documents

| # | Brief item | Document |
|---|------------|----------|
| 1 | System architecture | [01-system-architecture.md](01-system-architecture.md) |
| 2 | Component diagram | [01-system-architecture.md#2-component-diagram](01-system-architecture.md#2-component-diagram) |
| 3 | Data-flow diagram | [01-system-architecture.md#3-data-flow](01-system-architecture.md#3-data-flow) |
| 4 | Security model | [02-security-model.md](02-security-model.md) |
| 5 | OMEMO key / device model | [02-security-model.md#5-omemo-key-and-device-model](02-security-model.md#5-omemo-key-and-device-model) |
| 6 | Push architecture | [04-push.md](04-push.md) |
| 7 | Message synchronization model | [03-messaging-and-sync.md](03-messaging-and-sync.md) |
| 8 | Local database schema | [03-messaging-and-sync.md#5-local-database-schema](03-messaging-and-sync.md#5-local-database-schema) |
| 9 | Server architecture | [05-server.md](05-server.md) |
| 10 | Required XEP matrix | [06-xep-matrix.md](06-xep-matrix.md) |
| 11 | Swift dependency evaluation | [07-ios-dependencies.md](07-ios-dependencies.md) |
| 12 | Prosody vs ejabberd | [05-server.md#1-prosody-vs-ejabberd](05-server.md#1-prosody-vs-ejabberd) |
| 13 | Repository structure | [01-system-architecture.md#5-repository-structure](01-system-architecture.md#5-repository-structure) |
| 14 | Development phases | [08-phases-and-risks.md](08-phases-and-risks.md) |
| 15 | Main technical risks | [08-phases-and-risks.md#2-main-technical-risks](08-phases-and-risks.md#2-main-technical-risks) |

## Decision log (summary)

Each decision states the chosen approach, the main alternative, and why. The linked document gives the full reasoning.

| ID | Decision | Chosen | Main alternative | Why chosen |
|----|----------|--------|------------------|------------|
| D1 | XMPP server | **ejabberd 26.x** | Prosody 13.x | Native PostgreSQL schema; built-in `mod_push` + `mod_push_keepalive`; MUC/Sub for offline group delivery; full admin command set (`ban_account`, `srg_*`, `set_vcard`) for a CLI without custom code |
| D2 | Server DB | **PostgreSQL 17** | SQLite / Mnesia | Production-grade, backups, supported by ejabberd SQL backend |
| D3 | iOS XMPP transport | **OPEN. Measured in S1; waiting on the macOS probe run + Tigase licence terms.** Exit criterion also includes re-running the S4 harness with the chosen transport. Preferred: an existing library behind `MessagingTransport` (Martin is the primary candidate) | Own minimal transport | Avoid writing an XMPP stack from scratch unless a spike proves it necessary. Martin is AGPL-3.0 **or** commercially licensed by Tigase; the licence terms must be obtained, not assumed |
| D4 | OMEMO 2 | **DECIDED by S1 (2026-10-02): own XEP-0384 protocol/state layer** on swift-crypto/CryptoKit + libsodium + swift-protobuf; 13/13 interop scenarios vs python-twomemo, 3 runs. Martin-OMEMO excluded (legacy namespace only). Was: OPEN — Candidates: Martin-OMEMO (if it supports OMEMO 2 and the licence fits), another existing implementation, or our own **protocol/state layer only** on established crypto libraries | Own crypto primitives (forbidden) | Never implement primitives ourselves. If we implement anything, it is the XEP-0384 state machine on top of reviewed libraries |
| D5 | Local DB | **SQLite via GRDB** + FTS5 | SwiftData / Core Data | FTS5 search, explicit tested migrations, keyset pagination, safe multi-process access (Notification Service Extension) |
| D6 | Push gateway | **Own small Go service**, XEP-0114 component → APNs | Conversations' `p2` (Java) | Privacy control over the payload (encrypted sender), minimal surface, replaceable |
| D7 | Groups | **MUC (XEP-0045)**, members-only + non-anonymous, plus **ejabberd MUC/Sub** for offline delivery | MIX (XEP-0369) | MIX is not production-ready in servers or clients; plain MUC loses offline push |
| D8 | Attachments | **AES-256-GCM on device**, metadata as XEP-0448 inside the OMEMO SCE envelope | XEP-0454 `aesgcm://` URL | Keeps the key, hash and thumbnail inside the encrypted envelope; no plaintext preview leaves the device |
| D9 | iOS target | **iOS 18.0**, Swift 6 language mode | iOS 17 | Same device coverage as iOS 17 (iPhone XS and newer) with better SwiftUI scroll APIs |
| D10 | Xcode project | **XcodeGen** (`project.yml`) + local SwiftPM package | Committed `.xcodeproj` | Text-based and reviewable, no merge conflicts, and can be authored outside Xcode |
| D11 | Device trust | **BTBV** (Blind Trust Before Verification) | Strict manual trust | Zero friction by default; becomes strict per contact after verification |
| D12 | Admin | **`scripts/admin.sh`** wrapping `ejabberdctl` over SSH | Web admin panel | No admin API exposed to the Internet; enough for the MVP |
| D13 | Reverse proxy / TLS | **Caddy** (ACME) in front of HTTP services; ejabberd terminates XMPP TLS itself using Caddy's certs | nginx + certbot | One ACME client, automatic renewal, simple config |

## Owner review — 2026-10-02

Approved: D1, D2, D5, D6, D8, D9, D10 (UIKit only for the message timeline), D11, D12, D13.
Changed or added by the owner:

1. **D3/D4 are not approved.** The library architecture is fixed only after spike S1, which compares
   Martin (transport), Martin-OMEMO (licence + OMEMO version + limitations), a custom transport, and a custom
   OMEMO 2 protocol layer. Preference order: existing transport library → existing OMEMO implementation →
   our own XEP-0384 protocol/state layer on established primitives. Crypto primitives are never ours.
2. **OMEMO 2 interoperability is a blocking spike (S1)** before full implementation. See
   [08-phases-and-risks.md §3](08-phases-and-risks.md#3-mandatory-technical-spikes).
3. **Notification previews**: encrypted push envelope → `UNNotificationServiceExtension` → local
   decryption → sender (and, where possible, preview). The fallback is always a generic "New message". The app must not depend
   on the NSE succeeding. See [04-push.md](04-push.md).
4. **Attachments**: no plaintext thumbnail, filename, preview or original file outside the encrypted envelope,
   unless it is explicitly classified as non-sensitive metadata ([03 §4.1](03-messaging-and-sync.md#41-metadata-classification)).
5. **Fourth mandatory spike (S4): MAM + Stream Management + reconnect + deduplication.**
6. **New-device history**: the MVP behaviour is "history from the moment the device became an OMEMO recipient".
   This is **not** an architectural limit. The design keeps room for a future secure device-to-device
   history/key transfer ([02 §5.6](02-security-model.md#56-future-secure-history-transfer-not-in-mvp)).
7. **Third-party client compatibility is not a requirement, but standards compliance is** (where
   practical): it gives testability and avoids proprietary protocol behaviour.
8. **An external security review is mandatory before the production release.** It does not block Task 2.

Spike status (2026-10-02): S1 PARTIAL (OMEMO PASS; transport pending), S4 PASS,
S2 and S3 server side measured and passing; their device runs are pending (owner). See `docs/spikes/`.

Next milestone after the skeleton (Task 2): the four spikes S1–S4. Each spike report is recorded in `docs/spikes/`
as PASS / FAIL / PARTIAL with observed behaviour and unresolved limitations.

Still open for the owner:

- Licence terms from Tigase for Martin / Martin-OMEMO (needed as input to S1).
- Jurisdiction / legal review of operating an E2EE messenger (outside engineering scope).
