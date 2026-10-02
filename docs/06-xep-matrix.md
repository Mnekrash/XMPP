# 06 — XEP Capability Matrix

Legend: **MVP** = required for the first usable version; **Opt** = optional / nice-to-have; **Fut** = future.
Server/Client columns show where the work lives (✔ = implementation needed or module enabled, — = not involved).

| XEP / RFC | Name | Priority | Phase | Server (ejabberd) | Client | Purpose / notes |
|-----------|------|----------|-------|-------------------|--------|-----------------|
| RFC 6120/6121 | XMPP Core / IM | MVP | 2 | ✔ core | ✔ `XMPPCore` | TLS, SASL SCRAM-SHA-256, resource binding, roster |
| XEP-0368 | SRV records for XMPP over TLS (direct TLS) | MVP | 2 | ✔ listener 5223 | ✔ | No plaintext phase at all; host/port come from config, not SRV lookup |
| XEP-0030 | Service Discovery | MVP | 2 | ✔ `mod_disco` | ✔ | Find upload service, MUC, push support |
| XEP-0115 | Entity Capabilities | MVP | 2 | ✔ `mod_caps` | ✔ | Required for PEP `+notify` (device list updates) |
| XEP-0198 | Stream Management | MVP | 2 | ✔ `mod_stream_mgmt` | ✔ | Acks = "sent" state; resume = no gap |
| XEP-0199 | XMPP Ping | Opt | 2 | ✔ `mod_ping` | ✔ | SM `<r/>` is the primary liveness check |
| XEP-0359 | Unique and Stable Stanza IDs | MVP | 3 | ✔ (with MAM) | ✔ | `origin-id` + `stanza-id`: the backbone of dedup |
| XEP-0280 | Message Carbons | MVP | 3 | ✔ `mod_carboncopy` | ✔ | Multi-device consistency |
| XEP-0184 | Message Delivery Receipts | MVP | 4 | — | ✔ | "delivered" (1:1) |
| XEP-0333 | Chat Markers (`displayed`) | MVP | 4 | — | ✔ | "read" |
| XEP-0085 | Chat State Notifications | MVP | 4 | — | ✔ | Typing indicator |
| XEP-0334 | Message Processing Hints | MVP | 4 | ✔ honoured | ✔ | `<store/>` for encrypted messages, `<no-store/>` for chat states |
| XEP-0313 | Message Archive Management | MVP | 4 | ✔ `mod_mam` (+ MUC) | ✔ `SyncEngine` | History sync, catch-up, multi-device |
| XEP-0059 | Result Set Management | MVP | 4 | ✔ | ✔ | MAM paging |
| XEP-0163 | Personal Eventing Protocol | MVP | 5 | ✔ `mod_pep` | ✔ | OMEMO device lists/bundles, avatars, nick |
| XEP-0222/0223 | PEP publish-options (public / private data) | MVP | 5 | ✔ | ✔ | OMEMO nodes `access_model=open`, `max_items` |
| XEP-0060 | Publish-Subscribe | MVP | 5 | ✔ `mod_pubsub` | ✔ (PEP subset) | Base of PEP and push |
| XEP-0384 | OMEMO Encryption (`urn:xmpp:omemo:2`, v0.9.x) | MVP | 5 | — (PEP only) | ✔ `OMEMO` | Mandatory E2EE |
| XEP-0420 | Stanza Content Encryption | MVP | 5 | — | ✔ | Envelope as profiled by OMEMO 2 (content, rpad, from, to) |
| XEP-0380 | Explicit Message Encryption | MVP | 5 | — | ✔ | Marks encrypted messages + fallback body |
| XEP-0357 | Push Notifications | MVP | 6 | ✔ `mod_push`, `mod_push_keepalive` | ✔ enable/disable | App server = our gateway |
| XEP-0114 | Jabber Component Protocol | MVP | 6 | ✔ `ejabberd_service` | — (gateway) | Push gateway connection |
| XEP-0050 | Ad-Hoc Commands | MVP | 6 | — | ✔ (to gateway) | Push registration with the gateway |
| XEP-0363 | HTTP File Upload | MVP | 7 | ✔ `mod_http_upload` (+quota) | ✔ `Attachments` | Ciphertext upload only |
| XEP-0447 | Stateless File Sharing | MVP | 7 | — | ✔ | File metadata (inside the OMEMO envelope) |
| XEP-0448 | Encryption for Stateless File Sharing | MVP | 7 | — | ✔ | Key/nonce/cipher (AES-256-GCM) inside the OMEMO envelope |
| XEP-0045 | Multi-User Chat | MVP | 8 | ✔ `mod_muc` | ✔ | Private, members-only, non-anonymous groups |
| MUC/Sub (ejabberd) | Presence-less MUC subscription | MVP | 8 | ✔ `allow_subscription` | ✔ | Offline delivery + push for groups (ejabberd-specific, see 04 §3) |
| XEP-0249 | Direct MUC Invitations | MVP | 8 | — | ✔ | Invite member (+ affiliation set by owner) |
| XEP-0421 | Occupant identifiers | Opt | 8 | ✔ | ✔ | Stable sender identity in groups |
| XEP-0461 | Message Replies | MVP | 10* | — | ✔ | *Basic wire support earlier, UI polish in 10 |
| XEP-0308 | Last Message Correction | MVP | 10* | — | ✔ | Edit (inside the envelope) |
| XEP-0424 | Message Retraction | MVP | 10* | ✔ (MAM tombstone) | ✔ | Delete for everyone (best effort) |
| XEP-0444 | Message Reactions | MVP | 10* | — | ✔ | Inside the envelope |
| XEP-0084 | User Avatar | MVP | 10 | ✔ PEP | ✔ | Not E2E encrypted (server can see avatars) — documented |
| XEP-0172 | User Nickname | MVP | 10 | ✔ PEP | ✔ | Display name; admin sets it via `set_nickname` |
| XEP-0054 | vcard-temp | Opt | 8 | ✔ `mod_vcard` | ✔ | Group avatar (MUC vCard), admin-set FN |
| XEP-0388 / XEP-0484 | SASL2 / FAST | Opt | 12 | ✔ `mod_auth_fast` | ✔ | Per-device revocable token instead of a stored password |
| XEP-0490 | Message Displayed Synchronization | Opt | 10 | ✔ PEP | ✔ | Cross-device read state |
| XEP-0191 | Blocking Command | Fut | — | ✔ | ✔ | Closed service: admin disables accounts instead |
| XEP-0425 | Moderated Message Retraction | Fut | — | ✔ | ✔ | Group admin deletes others' messages |
| XEP-0369 | MIX | Fut | — | ✗ (not used) | — | Revisit only if server support matures |
| XEP-0166/0167 | Jingle (calls) | Fut | — | — | — | Calls are explicitly out of the MVP |
| XEP-0045 public rooms, XEP-0433 search | — | ✗ | — | disabled | — | No public discovery by product rule |

Compatibility policy: compatibility with third-party XMPP clients is **not** a product requirement. Standards compliance
**is** required where practical: it gives testability against independent implementations and avoids proprietary
protocol behaviour. Deviations (e.g. ejabberd MUC/Sub) are listed explicitly and isolated behind domain services.

Explicitly **not** used: legacy OMEMO (`eu.siacs.conversations.axolotl`), XEP-0454 (`aesgcm://` URL
media sharing), in-band registration (XEP-0077), server-to-server federation.

Implementation order is driven by the vertical slices in [08-phases-and-risks.md](08-phases-and-risks.md),
not by this table.
