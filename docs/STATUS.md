# Project Status

Updated: 2026-10-02 · Stage: **technical spikes** (no product feature work; blocked by the owner's rule until S1 and S4 are PASS).

## Spikes

| Spike | Verdict | Evidence | What is missing |
|-------|---------|----------|-----------------|
| S1 OMEMO 2 / library | **PARTIAL**: OMEMO part PASS, transport part open | [S1 report](spikes/S1-omemo-library.md): 13/13 interop scenarios × 3 runs, 8 unit tests | macOS run of `spikes/s1-martin-probe`; Tigase licence terms |
| S4 MAM / reconnect / dedup | **PASS** | [S4 report](spikes/S4-mam-reconnect-dedup.md): 14 scenarios × 3 runs, 6 unit tests | re-run with the final transport (D3 exit criterion) |
| S2 one-to-one push | **pending device run** (server side 11/11) | [S2 report](spikes/S2-push.md) | owner: device runbook D1–D15 (Mac, iPhone, `.p8`) |
| S3 group push | **pending device run** (server side 9/9 × 2) | [S3 report](spikes/S3-muc-push.md) | owner: device runbook G1–G7 |

## Verified in this environment (Linux container)

- Server stack (ejabberd 26.09, PostgreSQL 17, Caddy, push gateway × 2): `scripts/dev-smoke.sh` 14/14 from fresh volumes.
- OMEMOKit (Swift 6.2): builds, 8 unit tests, live interop with python-omemo/twomemo through ejabberd.
- SyncCore (Swift 6.2, GRDB 7.11.1): builds, 6 unit tests, 14 live fault-injection scenarios.
- Push gateway (Go 1.25): vet + tests; real XEP-0114 link to ejabberd; server-side push suites S2/S3.
- NotificationEnvelope (Swift): opens Go-sealed envelopes; fallback rules.
- MessengerKit Domain/Networking: builds, 37 test cases (Task 2).

## Verified in GitHub Actions (CI run #1, 2026-10-02, all 4 jobs green)

- iOS (macos-15): MessengerKit `swift test`, XcodeGen project generation, unsigned simulator build of the app + NSE.
- Server smoke test (ubuntu): full stack from fresh volumes incl. the push gateway built from `push/Dockerfile`.
- Push gateway: gofmt, vet, tests, build. Shell scripts: shellcheck.

## Not verified yet (needs the owner's Mac / devices)

- `spikes/s2-push/ios` spike app and `spikes/s1-martin-probe` (not part of CI).
- Real APNs delivery (APNs endpoints unreachable from the cloud environment).

## Not implemented (explicit)

| Item | Where marked | Planned |
|------|--------------|---------|
| Product login / XMPP connection / services | `// SKELETON` in `ios/` | after the D3 gate |
| OMEMO production hardening (encryption at rest, trust UI, heartbeats, actor wrapper) | S1 report "Not in the prototype" | Phase 5 |
| Backups, monitoring beyond healthchecks | deploy/README.md | Phase 11 |
| `ITSAppUsesNonExemptEncryption` / export compliance | `ios/project.yml` comment | Phase 11 |

## Known issues

- Dev-only certificate warnings in ejabberd logs (local CA, 12 h leaf; service subdomains without certificates).
- `ghcr.io` image pulls are blocked in this environment; the stack uses `ejabberd/ecs:26.09` from Docker Hub.
