# S1 — OMEMO 2 / XMPP library decision

**Verdict: PARTIAL**
- OMEMO 2 part (D4): **PASS**. 13/13 interop scenarios passed in 3 consecutive runs against an
  independent implementation, through the real ejabberd.
- Transport part (D3): **not decided**. Martin's compilation and real-session behaviour can only be measured
  on macOS, and this environment is Linux. The probe is ready ([spikes/s1-martin-probe](../../spikes/s1-martin-probe)).
  Martin's commercial licence terms are also still missing.

**Date:** 2026-10-02 · **Code:** `spikes/s1-omemo/`, `spikes/s1-martin-probe/`

## Objective

Choose the XMPP transport library and the OMEMO 2 implementation from measured results:

1. Martin as transport only.
2. Martin + Martin-OMEMO.
3. Custom XMPP transport.
4. Martin transport + our own OMEMO 2 protocol layer.
5. Fully custom XMPP + OMEMO (only if 1–4 are demonstrably unsuitable).

## Environment

| Item | Value |
|------|-------|
| Host | Linux x86_64 container, Docker 29.6 (no macOS, no Xcode) |
| Server | ejabberd 26.09 (`ejabberd/ecs:26.09`), PostgreSQL 17, Caddy 2 (local CA), the Task 2 dev stack |
| Swift | Swift 6.2.4 (`swift:6.2` image + libsodium 1.0.18, protoc 3.21.12) |
| Swift dependencies | swift-crypto 5.0.0 (`Crypto`, `CryptoExtras`), swift-protobuf 1.38.1, system libsodium 1.0.18 |
| Independent OMEMO 2 implementation | python-omemo 2.1.0 + python-twomemo 2.1.0 + DoubleRatchet 1.3.0 + X3DH 1.3.0 + XEdDSA 1.2.0 (all by the XEP-0384 author), driven by slixmpp-omemo 2.2.0 on slixmpp 1.17.0 |
| Spec | XEP-0384 v0.9.1 (2026-04-06), namespace `urn:xmpp:omemo:2`, status **Experimental** |

## Options — measured facts

| | 1. Martin transport | 2. Martin + Martin-OMEMO | 3. Custom transport | 4. Martin + own OMEMO 2 layer | 5. Fully custom |
|---|---|---|---|---|---|
| Library / version | Martin 3.2.4 (tag 2023-03-07; master +8 commits, last 2026-09-14) | + MartinOMEMO 2.2.3 (tag 2023-03-09; last commit 2024-07-30) + tigase/libsignal 1.0.0 | — | Martin 3.2.4 + OMEMOKit prototype | — |
| Licence | **AGPL-3.0**, "other licensing options available upon request" (README) | Martin AGPL-3.0; MartinOMEMO **GPL-3.0**; libsignal fork of libsignal-protocol-c (GPL-3.0) | ours | Martin AGPL/commercial; OMEMO layer ours; deps Apache-2.0 / ISC | ours |
| OMEMO namespace | — | **legacy only**: `eu.siacs.conversations.axolotl` (6 occurrences in sources); **no `urn:xmpp:omemo:2`** | — | **`urn:xmpp:omemo:2`** (v0.9.1), verified by interop | — |
| XEP coverage (by namespace in source) | SM, MAM, Carbons, Push (XEP-0357), HTTP Upload, stanza-id, receipts, markers, MUC, PubSub/PEP, disco. **Missing:** MUC/Sub, SCE, SASL2/FAST, reactions/replies/retraction, MDS | as 1 + legacy OMEMO | to be written: core, SASL SCRAM, SM, MAM, carbons, PEP, MUC(+Sub), upload, push | as 1. SCE, reactions, replies and retraction live **inside** the encrypted envelope, so they are ours anyway | everything |
| Swift 6 compatibility | `swift-tools-version:5.6`, Swift 5 language mode; 248 async/actor/Sendable occurrences (partial adoption). Strict Swift 6 mode not verified | same | native Swift 6 | OMEMOKit: Swift 6.2 tools, Swift 6 mode, **0 warnings** | native |
| Concurrency model | Combine (41 files import Combine) + callbacks + async wrappers | same | our choice (actors / async) | Martin: Combine; OMEMOKit: value types, caller wraps in an actor | ours |
| Maintenance | releases stale since 2023; 2 commits since 2025-01-01 | no commit since 2024-07 | ours | Martin as 1 | ours |
| Custom code estimate | adapter 1.5–2.5k LOC + MUC/Sub module ~0.3k | adapter + legacy OMEMO glue (rejected anyway) | 6–9k LOC (Martin itself: 32.5k LOC) | option 1 + OMEMO layer: prototype **686 LOC** (+226 generated); production estimate 2–3k with persistence, encryption at rest, trust, device management | 8–12k |
| Compiles | **Linux: NO**, measured: `no such module 'Combine'` (212 errors). Apple platforms: **not measured** (probe ready) | not attempted (rejected on namespace) | n/a | OMEMOKit: **YES** (Linux, Swift 6.2). Martin part: as 1 | n/a |
| Real XMPP session | **not measured** (needs macOS) | — | n/a | OMEMOKit used real sessions through ejabberd (harness transport) | n/a |
| Known limitations | AGPL; no MUC/Sub; stale releases; Combine-based API must be wrapped | **fails the OMEMO 2 requirement** | highest effort and risk | Martin part as 1. OMEMO layer: prototype only (see "Not in the prototype") | rejected unless 1–4 fail |

## OMEMO 2 prototype (option 4, OMEMO part)

What is ours: X3DH session building, the Double Ratchet *state machine*, key exchange handling, payload encryption
framing, `<encrypted>`/bundle/device-list XML, SCE envelope, pre-key lifecycle. **About 690 lines of Swift.**

What is not ours (established implementations only):

| Primitive | Library |
|-----------|---------|
| X25519, Ed25519, HKDF-SHA-256, HMAC-SHA-256 | swift-crypto 5.0.0 (`Crypto`; CryptoKit API, CryptoKit itself on Apple platforms) |
| AES-256-CBC (PKCS#7) | swift-crypto 5.0.0 `CryptoExtras.AES._CBC` |
| Ed25519 → X25519 conversion, RNG, constant-time compare | libsodium 1.0.18 |
| Protobuf wire format | swift-protobuf 1.38.1 (generated from the XEP-0384 schema) |

Spec parameters, cross-checked against the reference implementation: X3DH info "OMEMO X3DH", 32×0xFF prefix,
zero salt. Root chain HKDF info "OMEMO Root Chain". Message chain: HMAC 0x01 = message key, HMAC 0x02 = next
chain key. AEAD HKDF info "OMEMO Message Key Material" (80 bytes → AES key, HMAC key, IV). Payload HKDF info
"OMEMO Payload". Tags truncated to 16 bytes. AD = IK_initiator ‖ IK_responder (Ed25519 form). Max 1000 skipped keys.

### Test procedure

- Unit tests (Swift ↔ Swift, `swift test`): 8 tests. Bundle XML round-trip, handshake + both directions,
  out-of-order + duplicate, tampered payload, SCE affixes, SPK rotated once (accepted) / twice (rejected),
  consumed pre-key rejected.
- Interop (`harness/scenarios.py`): every scenario resets the accounts. Python devices = independent
  implementation. Swift devices = `omemo-cli` (OMEMOKit) driven over JSON-RPC. The harness only moves XML
  between the device and the XMPP connection. All stanzas, PEP bundles and device lists go through ejabberd
  over direct TLS with certificate validation.

### Results (3 consecutive full runs, 39/39 executions PASS)

| # | Scenario | Result | Observed |
|---|----------|--------|----------|
| 1 | Initial X3DH session | PASS | python→Swift and Swift→python key exchanges accepted; passive sessions built on both sides |
| 2 | Pre-key consumption | PASS | Swift removed the used pre-key from its published bundle and refilled (99 published); python removed the pk used by Swift from its bundle |
| 3 | Regular Double Ratchet message | PASS | after confirmation, neither side sends `kex='true'` |
| 4 | Bidirectional | PASS | 60 messages in random bursts, many DH ratchet steps, all decrypted |
| 5 | Multiple recipient devices | PASS | Swift: one `<encrypted>` for 2 alice devices + own other device; python: keys for 2 Swift devices, both decrypt |
| 6 | New sender device | PASS | new python device → Swift built a passive session on first message; new Swift device → python accepted |
| 7 | Removed device | PASS | after a device-list update without the device, neither implementation encrypts for it |
| 8 | Bundle refresh | PASS | SPK rotated on each side and republished; the other side built new sessions against the new SPK id |
| 9 | Expired/rotated pre-key | PASS | (a) consumed pre-key and (b) SPK rotated twice → python raises `KeyExchangeFailed`; Swift recovers by refreshing the bundle. (c) Swift-side rejection: unit test (python always re-downloads bundles, so it cannot be made to send a stale key exchange) |
| 10 | Session recreation | PASS | Swift lost its session → `noSession` → re-initiated → python replaced the session and continued; python `replace_sessions` → Swift accepted the new key exchange |
| 11 | Out-of-order | PASS | python→Swift order 0,5,2,1,4,3 and Swift→python order 3,0,5,1,2,4 decrypted; re-delivery of a decrypted message rejected (`duplicateMessage`) |
| 12 | Delayed | PASS | 3 messages stored by ejabberd while the Swift device was offline, delivered with `<delay>` after a process restart, decrypted. A message held back across 3 DH rounds decrypted via skipped keys |
| 13 | Encrypted MUC | PASS | room `muc_membersonly` + `muc_nonanonymous`; Swift groupchat decrypted by 2 python members, python groupchat decrypted by Swift; SCE `<to/>` = room; **room MAM: 2 messages, 0 contain plaintext** (checked in PostgreSQL) |

Measured timings (debug build; includes container IPC and JSON; median / p95):
Swift encrypt 4.1 / 11.2 ms, Swift decrypt 4.6 / 9.4 ms, bundle generation 20.5 / 30.9 ms.
python-omemo encrypt 1.6 / 95.6 ms, decrypt 1.4 / 276.8 ms (p95 includes PEP fetches).

### Defects found and fixed during the spike

1. **Non-transactional decrypt (Swift prototype).** The ratchet state was committed after the key material
   decrypted but before the payload was authenticated. A tampered payload therefore burned the message key, and
   the genuine copy became undecryptable ("duplicate"). Found by unit test `tamperedPayloadIsRejected`.
   Fixed: session state and pre-key consumption are committed only after payload authentication.
2. Harness issues only (method name clash with slixmpp, MAM query key), not protocol issues.

### Observations about the ecosystem

- **slixmpp-omemo 2.2.0 has no SCE support for `urn:xmpp:omemo:2`**: its source says "IF I HAD ONE!!!" and raises
  `NotImplementedError` when decrypting. Python-based OMEMO 2 messaging therefore needs a custom SCE layer,
  as in this harness. The SCE wrapper on both sides of the test is plain XML, so it is not independently verified.
- python-omemo sends automatic empty messages (handshake completion, heartbeats, healing). OMEMOKit handles
  them; the production client should send them too.
- A second independent OMEMO 2 implementation (e.g. QXmpp/libomemo-c) was **not** tested.

### Not in the prototype (needed for production)

Encryption at rest of session/pre-key state (docs/02 §1) and the Keychain-held identity key; trust management
(BTBV UI, verification); automatic heartbeat/staleness messages; skipped-key TTL; signed-pre-key rotation
schedule; device-list label verification on receive; concurrency (actor wrapper); persistence in GRDB within the
message transaction (docs/03 §3.2); fuzzing; the external security review.

## Recommendation

Based on the measured results:

1. **OMEMO (D4): our own OMEMO 2 protocol/state layer on swift-crypto + libsodium + swift-protobuf.**
   - Option 2 is excluded by evidence: Martin-OMEMO implements only legacy OMEMO, and its last commit is from 2024-07.
   - The prototype interoperates with the reference implementation in all 13 required scenarios, 3 runs out of 3.
   - Production hardening (list above) and the external review remain mandatory.
2. **Transport (D3): Martin as transport only (option 4 = option 1 + item 1), conditional on two open checks:**
   - (a) `spikes/s1-martin-probe` builds and passes on macOS against staging;
   - (b) Tigase's commercial licence terms are acceptable (AGPL is not acceptable for a closed App Store app).

   If either fails, fall back to **option 3** (custom transport, scoped to the XEP matrix). Martin's measured
   value: it already covers SM, MAM, carbons, push, upload, MUC and PEP. Its measured costs: AGPL, stale releases,
   Combine-based API, and no MUC/Sub.
3. Option 5 is not needed: the OMEMO layer is already separable from the transport (`EncryptionService`).

## Unresolved

| Item | Needed from | Blocks |
|------|-------------|--------|
| Run `spikes/s1-martin-probe` on macOS (Xcode 26) against staging: build log + run log | owner (Mac) | D3 |
| Tigase commercial licence terms for Martin | owner | D3 |
| OMEMOKit build + tests on macOS/iOS (CryptoKit backend, swift-sodium instead of system libsodium) | macOS CI | D4 production work |
| Second independent OMEMO 2 implementation interop (optional) | — | — |

## Architectural consequence

- D4 decided: OMEMO 2 protocol layer in-house (`OMEMO` module), primitives from swift-crypto/CryptoKit +
  libsodium. The decrypt-then-commit rule (defect 1) becomes a design rule in docs/03 §3.2.
- D3 stays open until the probe result and the licence terms arrive. Per the owner's rule, product features
  do not start until S1 is PASS.
- New dependency for iOS: libsodium via swift-sodium (ISC), used only for the Ed25519 → X25519 conversion.
