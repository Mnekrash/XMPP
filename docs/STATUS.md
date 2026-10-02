# Project Status

Updated: 2026-10-02 · Stage: **minimal login path, waiting for the owner's device check** (docs/09). No further
product features until the owner has installed the app and confirmed login, temporary-password change, Chats, logout
and re-login on the iPhone.

## Spikes

| Spike | Verdict | Evidence | What is missing |
|-------|---------|----------|-----------------|
| S1 OMEMO 2 / library | **PARTIAL**: OMEMO part PASS, transport part open | [S1 report](spikes/S1-omemo-library.md): 13/13 interop scenarios × 3 runs, 8 unit tests | macOS run of `spikes/s1-martin-probe`; Tigase licence terms |
| S4 MAM / reconnect / dedup | **PASS** | [S4 report](spikes/S4-mam-reconnect-dedup.md): 14 scenarios × 3 runs, 6 unit tests | re-run with the final transport (D3 exit criterion) |
| S2 one-to-one push | **pending device run** (server side 11/11) | [S2 report](spikes/S2-push.md) | owner: device runbook D1–D15 (Mac, iPhone, `.p8`) |
| S3 group push | **pending device run** (server side 9/9 × 2) | [S3 report](spikes/S3-muc-push.md) | owner: device runbook G1–G7 |

## Minimal app (login path) — built and tested in CI, device check pending

Splash, login (loading, wrong password, no connection, disabled account), forced change of the temporary password,
"Чаты" with connection status and the empty state, Settings, logout, hidden diagnostics (5 taps on "Версия").
Real authentication through Martin 3.2.4 against ejabberd; no mocks in the app, no sample chats.

- `must-change-password` is a **client-enforced** flag in private storage (docs/09 §2), not a server restriction.
- Martin defects found and isolated in `XMPPTransport` (Martin itself unchanged):
  [SASL failure condition](known-issues/martin-sasl-failure.md),
  [TLS connector and certificate policy](known-issues/martin-tls.md).
- Install guide for the owner: [09-device-validation.md](09-device-validation.md).

## Verified in this environment (Linux container)

- Server stack (ejabberd 26.09, PostgreSQL 17, Caddy, push gateway × 2): `scripts/dev-smoke.sh` 14/14 from fresh volumes.
- OMEMOKit (Swift 6.2): builds, 8 unit tests, live interop with python-omemo/twomemo through ejabberd.
- SyncCore (Swift 6.2, GRDB 7.11.1): builds, 6 unit tests, 14 live fault-injection scenarios.
- Push gateway (Go 1.25): vet + tests; real XEP-0114 link to ejabberd; server-side push suites S2/S3.
- NotificationEnvelope (Swift): opens Go-sealed envelopes; fallback rules.
- MessengerKit Domain/Networking: builds, 37 test cases (Task 2).

## Verified in GitHub Actions (CI run #9, 2026-10-02, all 5 jobs green)

- iOS (macos-15): MessengerKit unit tests on the iOS simulator; XcodeGen project generation; app + NSE built ad-hoc
  signed for the simulator with the NSE embedded; app-hosted Keychain tests; unsigned build for a physical iPhone.
- Martin transport against a real ejabberd (macos-15, CI-only CA trusted by the system): 18 tests — login, wrong
  password, disabled account, unreachable server, temporary-password flow (too-short password rejected by the client, change, re-login
  with the new password, old one rejected, flag cleared), session restore, certificate policy, SASL workaround.
- Server smoke test (ubuntu): full stack from fresh volumes incl. the push gateway built from `push/Dockerfile`.
- Push gateway: gofmt, vet, tests, build. Shell scripts: shellcheck.

## Not verified yet (needs the owner's Mac / devices)

- `spikes/s2-push/ios` spike app and `spikes/s1-martin-probe` (not part of CI).
- Real APNs delivery (APNs endpoints unreachable from the cloud environment).

## Not implemented (explicit)

| Item | Where marked | Planned |
|------|--------------|---------|
| Messages, groups, media, OMEMO in the app, push registration | — | after the owner's device check |
| OMEMO production hardening (encryption at rest, trust UI, heartbeats, actor wrapper) | S1 report "Not in the prototype" | Phase 5 |
| Backups, monitoring beyond healthchecks | deploy/README.md | Phase 11 |
| `ITSAppUsesNonExemptEncryption` / export compliance | `ios/project.yml` comment | Phase 11 |

## Known issues

- Dev-only certificate warnings in ejabberd logs (local CA, 12 h leaf; service subdomains without certificates).
- `ghcr.io` image pulls are blocked in this environment; the stack uses `ejabberd/ecs:26.09` from Docker Hub.
