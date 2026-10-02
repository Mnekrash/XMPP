# 08 — Development Phases and Main Technical Risks

## 1. Phases (vertical slices)

Every phase ends with: the project compiles, tests pass, and `docs/STATUS.md` is updated ("works / not
implemented / known issues"). Mocks are allowed only in tests or if they are explicitly marked `// MOCK:` and listed in STATUS.

| Phase | Scope | Exit criteria (verifiable) |
|-------|-------|----------------------------|
| 0 | **Skeleton** (Task 2): repo layout, XcodeGen project, SwiftPM modules with protocols only, Docker Compose (ejabberd + Postgres + Caddy + gateway stub), `.env.example`, `admin.sh`, CI | App builds on macOS CI; `docker compose up` gives a working ejabberd; `admin.sh create` makes an account a reference client can log into |
| S | **Spikes S1–S4** (§3) → **library decision gate D3/D4** | Every spike has a report in `docs/spikes/` with PASS / FAIL / PARTIAL; D3/D4 recorded in `docs/README.md`. No feature phase starts before this gate |
| 1 | Local DB: GRDB schema v1, repositories, `ValueObservation`, chat list from DB, FTS | Unit + migration tests; chat list renders 10 k seeded messages smoothly |
| 2 | XMPP auth + connection on the library chosen at the gate: direct TLS, SCRAM-SHA-256, SM + resume, backoff, path monitoring, lifecycle | Integration test: login, kill the socket → resume; Wi-Fi ↔ cellular on a device; bad password → user-friendly error |
| 3 | 1:1 **plaintext** messaging (dev builds only, feature-flagged) + outbox + carbons + `origin-id` | Two simulators exchange messages; outbox survives app kill. *Plaintext path is compiled out of Release after Phase 5* |
| 4 | MAM sync, dedup pipeline, receipts, markers, typing | Tests: reconnect / duplicate / out-of-order / multi-device scenarios produce zero duplicates |
| 5 | **OMEMO 2** productionised on the implementation chosen at the gate: keys, bundles, device lists, sessions, BTBV trust, Devices screen, revocation | S1 interop suite green in CI; two devices + second own device exchange encrypted messages; plaintext path removed from Release |
| 6 | Push: gateway, registration, NSE name resolution, mute, keepalive | App suspended / force-quit → notification "New message from X" within seconds on real devices; token rotation handled |
| 7 | Encrypted attachments: photos, video, files; viewer, cache policy | Server volume inspection shows ciphertext only; hashes verified; resume after app suspension |
| 8 | Groups: MUC + MUC/Sub, members, admins, invites, removal, group OMEMO, group media | 3 devices in an encrypted group; removed member's devices no longer receive keys; offline member gets push |
| 9 | Voice messages | Record/cancel/send/play with waveform; encrypted |
| 10 | UI polish: replies/edit/delete/reactions/forward UI, swipe actions, context menus, search UI, profile, settings, Face ID lock, accessibility, Dynamic Type | Accessibility audit (VoiceOver labels, Dynamic Type XXL); Instruments: no hitches in a 10 k-message chat |
| 11 | TestFlight: signing, App Group/Keychain entitlements, push entitlement, staging server, export compliance answers, demo account for Beta App Review, public link | External testers install via public link and pass the 15 success criteria on staging |
| 12 | Hardening + Unlisted prep: FAST tokens, optional cert pinning, **external security review (mandatory, gates production)**, rate limits, backups/restore drill, privacy policy, App Privacy labels, Unlisted request | Audit findings fixed; restore drill done; Unlisted distribution approved |

The success flow (two iPhones: install → login → encrypted chat → push → sync → media → group →
network recovery → no duplicates) is reachable after Phase 8 on staging and is the only priority until then.
Phases 9–10 do not start until it is reliable.

## 2. Main technical risks

| # | Risk | Impact | Likelihood | Mitigation |
|---|------|--------|------------|------------|
| R1 | **OMEMO 2 implementation defect** (library or own protocol layer) | Critical | Medium | S1 interop spike before implementation; primitives only from established libraries; oracle interop tests in CI; **external security review gates production** |
| R1a | **XEP-0384 is Experimental**: the wire format can change | Medium | Medium | Pin the implemented version (0.9.x); track XSF changes; namespace-versioned code paths |
| R2 | **Licence** of the chosen libraries (AGPL/GPL) vs App Store distribution | High | Medium | Obtain Tigase commercial terms as an S1 input; licence check of every dependency in CI |
| R3 | **Scope explosion**: writing our own XMPP transport *and* OMEMO layer at the same time | High | Low (gated) | Not allowed without a failed S1 for the library route; even then, at most one of the two is written in-house per phase |
| R4 | Group push depends on ejabberd-specific MUC/Sub | Medium | Low | Phase 8 spike first; isolated in `GroupService`; fallback = long SM hibernation + `wake_on_timeout` |
| R5 | Ratchet state corruption (crash mid-update, two processes) | High | Low | Decrypt + store in one DB transaction; NSE never touches OMEMO in the MVP; per-device serialization |
| R6 | Duplicate / lost messages across SM resume, MAM, carbons | High | Medium | Single ingest pipeline; dedup before decrypt; unique indexes; scenario test suite (Phase 4) |
| R7 | iOS background limits / push throttling delay messages | Medium | Medium | Alert pushes (not silent pushes) for messages; `mod_push_keepalive`; no reliance on background execution |
| R8 | New device cannot read older history (OMEMO property) | Medium (UX) | Certain | Set expectations in onboarding copy; future encrypted history transfer between own devices |
| R9 | MAM retention / upload expiry makes old content unavailable | Low | Certain | Configurable retention; auto-download of small media; clear "no longer available" placeholders |
| R10 | App Review / Unlisted approval (login-only app, encryption export compliance) | Medium | Medium | Demo account for reviewers; export-compliance documentation for standard encryption; privacy policy; account-deletion path via admin/in-app request |
| R11 | Server metadata exposure (who/when) | Medium | Certain | Minimal retention, no federation, debug logging forbidden in production, hashed IDs in gateway logs |
| R12 | Single-VPS outage | Medium | Low–Medium | Encrypted off-host backups, tested restore, uptime monitoring; HA later if usage justifies |
| R13 | Regulatory requirements for E2EE messengers in the operator's/users' jurisdiction | Potentially high | Depends | Legal check before the production launch (outside engineering scope) |
| R14 | Development machine constraint: iOS builds require macOS/Xcode | Medium | Certain | CI on macOS runners for iOS; server/gateway/oracle buildable on Linux |

## 3. Mandatory technical spikes

Run immediately after the skeleton, before any feature phase. Spike code lives in `/spikes` (throwaway, not
shipped). Each spike produces `docs/spikes/S<n>-<name>.md` from [docs/spikes/TEMPLATE.md](spikes/TEMPLATE.md):
verdict **PASS / FAIL / PARTIAL**, environment (versions, devices, network), the actual observed behaviour per
check, logs/evidence, and unresolved limitations. "Not tested" is reported as such, never as PASS.

### S1 — OMEMO 2 + library evaluation (blocking for D3/D4)

Candidates compared: Martin (transport), Martin-OMEMO (licence, OMEMO version, limitations), custom transport,
custom OMEMO 2 protocol/state layer on established primitives. Peer: at least one independent OMEMO 2 implementation
(`python-twomemo` + `slixmpp`, plus a second client where practical). The server is the Phase-0 ejabberd.

Checks:

1. 1:1 initial session establishment (key exchange via a pre-key) in both directions.
2. Multiple devices on both sides (≥ 2 + 2), own-device copies readable.
3. Pre-key consumption: the used pre-key is removed and the bundle is republished; refill below the threshold.
4. Session recreation after a deliberately corrupted or lost session.
5. Device removal: the removed device no longer receives keys; its messages are handled per the trust rules.
6. Device-list / identity changes are detected and surfaced (BTBV behaviour).
7. Reconnect in the middle of a conversation (with and without SM resume), with no lost or re-decrypted messages.
8. Group encryption in a members-only, non-anonymous MUC with ≥ 3 members.
9. Out-of-order and missing messages (skipped keys).

Output: the D3/D4 recommendation with evidence, licence terms, and estimated integration effort.

### S2 — One-to-one push (APNs + NSE)

Real devices; app suspended, force-quit, after reboot (before and after first unlock). Gateway stub → APNs
sandbox. Checks: notification arrives; level-1 sender name shown by the NSE; fallback "New message" when the NSE
fails (forced failure, timeout, missing key); token rotation; 410 cleanup; `mod_push_keepalive` wake.

### S3 — MUC / group push

Members-only MUC with MUC/Sub. Checks: an offline subscriber gets a push for an OMEMO group message; the message
is in their MAM on reconnect; removed members stop receiving pushes; behaviour after an ejabberd restart.

### S4 — MAM + Stream Management + reconnect + deduplication

Scripted and manual scenarios on real devices:

1. Send messages → disable the network → send more (both sides) → restore.
2. Wi-Fi ↔ cellular transition mid-conversation.
3. App suspension; app termination; relaunch.
4. Successful stream resume; **failed** resume (server restarted / resume timeout) → MAM catch-up.
5. MAM catch-up overlapping with live and carbon delivery.
6. Out-of-order arrival; injected duplicate stanza delivery (same `origin-id`, same `stanza-id`).

Pass condition: **every application-level message appears exactly once** in the UI/DB, none is lost,
states only move forward, and no OMEMO message is decrypted twice.
