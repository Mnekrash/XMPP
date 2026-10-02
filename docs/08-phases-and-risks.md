# 08 — Development Phases and Main Technical Risks

## 1. Phases (vertical slices)

Every phase ends with: the project compiles, tests pass, and `docs/STATUS.md` is updated ("works / not
implemented / known issues"). Mocks are allowed only in tests or if they are explicitly marked `// MOCK:` and listed in STATUS.

| Phase | Scope | Exit criteria (verifiable) |
|-------|-------|----------------------------|
| 0 | **Skeleton** (Task 2): repo layout, XcodeGen project, SwiftPM modules with protocols, Docker Compose (ejabberd + Postgres + Caddy), `.env.example`, `admin.sh`, CI (macOS: build + unit tests; Linux: compose config check, Go build) | App launches to an empty login screen; `docker compose up` gives a working ejabberd; `admin.sh create` makes an account a reference client can log into |
| 1 | Local DB: GRDB schema v1, repositories, `ValueObservation`, chat list from DB, FTS | Unit + migration tests; chat list renders 10 k seeded messages smoothly |
| 2 | XMPP auth + connection: direct TLS, SCRAM-SHA-256, bind, SM + resume, backoff, path monitoring, lifecycle | Integration test: login, kill the socket → resume; Wi-Fi ↔ cellular on a device; bad password → user-friendly error |
| 3 | 1:1 **plaintext** messaging (dev builds only, feature-flagged) + outbox + carbons + `origin-id` | Two simulators exchange messages; outbox survives app kill. *Plaintext path is compiled out of Release after Phase 5* |
| 4 | MAM sync, dedup pipeline, receipts, markers, typing | Tests: reconnect / duplicate / out-of-order / multi-device scenarios produce zero duplicates |
| 5 | **OMEMO 2**: keys, bundles, device lists, sessions, BTBV trust, Devices screen, revocation | Oracle interop tests green; two devices + second own device exchange encrypted messages; plaintext path removed from Release |
| 6 | Push: gateway, registration, NSE name resolution, mute, keepalive | App suspended / force-quit → notification "New message from X" within seconds on real devices; token rotation handled |
| 7 | Encrypted attachments: photos, video, files; viewer, cache policy | Server volume inspection shows ciphertext only; hashes verified; resume after app suspension |
| 8 | Groups: MUC + MUC/Sub, members, admins, invites, removal, group OMEMO, group media | 3 devices in an encrypted group; removed member's devices no longer receive keys; offline member gets push |
| 9 | Voice messages | Record/cancel/send/play with waveform; encrypted |
| 10 | UI polish: replies/edit/delete/reactions/forward UI, swipe actions, context menus, search UI, profile, settings, Face ID lock, accessibility, Dynamic Type | Accessibility audit (VoiceOver labels, Dynamic Type XXL); Instruments: no hitches in a 10 k-message chat |
| 11 | TestFlight: signing, App Group/Keychain entitlements, push entitlement, staging server, export compliance answers, demo account for Beta App Review, public link | External testers install via public link and pass the 15 success criteria on staging |
| 12 | Hardening + Unlisted prep: FAST tokens, optional cert pinning, **external OMEMO audit**, rate limits, backups/restore drill, privacy policy, App Privacy labels, Unlisted request | Audit findings fixed; restore drill done; Unlisted distribution approved |

The success flow (two iPhones: install → login → encrypted chat → push → sync → media → group →
network recovery → no duplicates) is reachable after Phase 8 on staging and is the only priority until then.
Phases 9–10 do not start until it is reliable.

## 2. Main technical risks

| # | Risk | Impact | Likelihood | Mitigation |
|---|------|--------|------------|------------|
| R1 | **Own OMEMO 2 implementation has a cryptographic bug** | Critical | Medium | Strict spec following; only reviewed primitives; oracle interop tests vs `python-twomemo`; fuzzing; **external audit as a release gate** |
| R2 | **Licence** (AGPL/GPL libraries) incompatible with App Store distribution | High | Avoided by D3/D4 | Own XMPP + OMEMO layers; dependency licence check in CI |
| R3 | Own XMPP client layer takes longer than estimated | Medium | Medium | Strict XEP scope; one pinned server; transcript-based tests; option to license Martin commercially as plan B |
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

## 3. Spikes to run before committing to each phase

1. **OMEMO 2 spike (before Phase 5, can start in parallel at Phase 2):** Swift X3DH + one ratchet step
   decrypts a message produced by `python-twomemo`. Validates libsodium conversion + CBC/HMAC layout.
2. **MUC/Sub + mod_push spike (before Phase 8):** offline subscriber receives a push for an OMEMO
   group message, and the message is in their own MAM.
3. **NSE spike (Phase 6):** NSE reads the shared DB while the device is locked (after first unlock)
   and decrypts the sender within the time/memory budget.
