# Private Messenger — Architecture Documentation

Status: **DRAFT FOR APPROVAL** (Task 1 of the project brief). No application code exists yet.
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
| D3 | iOS XMPP layer | **Own minimal Swift client (`XMPPCore`)** on Network.framework + libxml2 push parser | Martin (Tigase) | Martin is **AGPL-3.0** and its OMEMO module is legacy OMEMO; XMPPFramework is Obj-C and has little active maintenance. One server and one client means the protocol surface is small and fully under our control |
| D4 | OMEMO | **Own OMEMO 2 (`urn:xmpp:omemo:2`, XEP-0384 v0.9.x)** on CryptoKit + CommonCrypto + libsodium | libomemo-c (GPL-3.0) | Licence compatibility with App Store distribution. Uses only reviewed primitives; tested against `python-omemo`/`twomemo` as a reference oracle; **external audit is mandatory before production** |
| D5 | Local DB | **SQLite via GRDB** + FTS5 | SwiftData / Core Data | FTS5 search, explicit tested migrations, keyset pagination, safe multi-process access (Notification Service Extension) |
| D6 | Push gateway | **Own small Go service**, XEP-0114 component → APNs | Conversations' `p2` (Java) | Privacy control over the payload (encrypted sender), minimal surface, replaceable |
| D7 | Groups | **MUC (XEP-0045)**, members-only + non-anonymous, plus **ejabberd MUC/Sub** for offline delivery | MIX (XEP-0369) | MIX is not production-ready in servers or clients; plain MUC loses offline push |
| D8 | Attachments | **AES-256-GCM on device**, metadata as XEP-0448 inside the OMEMO SCE envelope | XEP-0454 `aesgcm://` URL | Keeps the key, hash and thumbnail inside the encrypted envelope; no plaintext preview leaves the device |
| D9 | iOS target | **iOS 18.0**, Swift 6 language mode | iOS 17 | Same device coverage as iOS 17 (iPhone XS and newer) with better SwiftUI scroll APIs |
| D10 | Xcode project | **XcodeGen** (`project.yml`) + local SwiftPM package | Committed `.xcodeproj` | Text-based and reviewable, no merge conflicts, and can be authored outside Xcode |
| D11 | Device trust | **BTBV** (Blind Trust Before Verification) | Strict manual trust | Zero friction by default; becomes strict per contact after verification |
| D12 | Admin | **`scripts/admin.sh`** wrapping `ejabberdctl` over SSH | Web admin panel | No admin API exposed to the Internet; enough for the MVP |
| D13 | Reverse proxy / TLS | **Caddy** (ACME) in front of HTTP services; ejabberd terminates XMPP TLS itself using Caddy's certs | nginx + certbot | One ACME client, automatic renewal, simple config |

## Decisions that need the owner's explicit approval

1. **D3/D4 — writing our own XMPP client layer and OMEMO 2 implementation.** This is the biggest
   cost and risk item. The only shortcut (Martin + MartinOMEMO) would require
   releasing the entire app under AGPL-3.0 (or buying a commercial licence from Tigase) and
   would give legacy OMEMO instead of OMEMO 2. Please confirm: own implementation, or contact Tigase
   for a commercial licence.
2. **External cryptographic audit** of the OMEMO module before the production (Unlisted) release.
3. **No interoperability with third-party XMPP clients** is a goal. The service is closed. Third-party
   OMEMO 2 clients may work, but are not supported.
4. **History on a new device starts when that device is added.** This is an inherent OMEMO
   property: old messages were never encrypted for the new device. A future encrypted-backup or
   device-to-device history transfer can address it.
5. **Push notification text** = "New message from <Name>". The name is resolved on the device. APNs
   and Apple never see plaintext or the sender's name. See [04-push.md](04-push.md).
6. **Jurisdiction / legal.** Operating an end-to-end encrypted messenger has regulatory implications
   in some countries (e.g. obligations for messaging service operators, export-control
   classification of encryption for App Store submission). This must be checked for the
   countries where the operator and the users are located. It is outside the scope of this
   document.
