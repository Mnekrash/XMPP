# Project Status

Updated: 2026-10-02 · Stage: **Task 2 — project skeleton** (no feature implementation).
Next milestone: spikes S1–S4 ([08 §3](08-phases-and-risks.md#3-mandatory-technical-spikes)).

## Verified (executed in a Linux container)

| Area | What was run | Result |
|------|--------------|--------|
| Server stack | `scripts/dev-smoke.sh` on **fresh volumes**: render config → `compose up --wait` → cert sync → two temporary accounts → smoke test → cleanup | PASS (all 14 checks) |
| Smoke checks | direct TLS on 5223 with CA validation; SCRAM-SHA-256 and PLAIN not offered; Stream Management; shared roster; Carbons; MAM, Push, Stanza-ID, PEP publish-options on the account; HTTP Upload discovery; message delivery with `origin-id` and server `stanza-id` | PASS |
| Plaintext | 5222 announces `<starttls><required/>` | PASS |
| HTTP Upload | slot request → PUT through Caddy (201) → GET returns identical bytes | PASS (manual) |
| Admin | `admin.sh init / create / list / disable / enable`; a disabled account cannot log in; username validation | PASS (manual) |
| PostgreSQL | init script creates separate roles/DBs; ejabberd creates its schema (32 tables) | PASS |
| Config rendering | values with `&` and `/` render correctly; `$`, `"`, `\` are rejected | PASS |
| Push gateway | `go vet`, `go test` (config), Docker build, `/healthz` healthcheck | PASS |
| Shell scripts | `shellcheck` | clean |
| Swift (Domain, Networking + placeholder modules) | Swift 6.2 on Linux, Swift 6 mode, `-warnings-as-errors`; 37 test cases | PASS |

## Not verified here (needs macOS / Xcode — runs in CI job `ios`)

- `ios/project.yml` (XcodeGen), app target, NotificationService target, entitlements, xcconfigs.
- `UI` module (SwiftUI) and `MessengerApp.swift`.
- `.github/workflows/ci.yml`: the YAML syntax is valid; the workflow itself has not run yet.

## Exists (skeleton)

- `ios/`: XcodeGen project (app + NSE, iOS 18, Swift 6), three environments via xcconfig, `MessengerKit`
  package with module boundaries per docs/01 §2, domain models and protocols, `ServerConfig` loading,
  login screen.
- `server/`, `deploy/`, `scripts/`: ejabberd 26.09 + PostgreSQL 17 + Caddy stack, config rendering,
  certificate sync, account administration, smoke test.
- `push/`: Go gateway with configuration loading and health endpoint.
- `docs/spikes/TEMPLATE.md` for spike reports.

## Not implemented (explicitly)

| Item | Where it is marked | Planned |
|------|--------------------|---------|
| Login / XMPP connection (`LoginView` shows "not available in this build") | `// SKELETON:` in `LoginView.swift`, `MessengerApp.swift` | Phase 2, after the D3 gate |
| All service implementations (Messaging, SyncEngine, Persistence/GRDB, OMEMO, Attachments, Push, Authentication, AppSecurity) | module files say "Intentionally empty" | Phases 1–9 |
| XMPP library and OMEMO implementation | open decisions D3/D4 | after spike S1 |
| NSE beyond level 0 (passes the generic alert through unchanged) | `// SKELETON` doc comment | after spike S2 |
| Push gateway: XEP-0114 component, registration, APNs, cleanup on account disable/delete | `/healthz` reports `"component": "not_implemented"`; `admin.sh` prints a note | after spike S2 |
| Backups, monitoring beyond healthchecks | deploy/README.md | Phase 11 |
| `ITSAppUsesNonExemptEncryption` / export compliance | comment in `project.yml` | Phase 11 (legal input) |

## Known issues / limitations

- In development, ejabberd logs warnings about the 12 h local-CA leaf certificate and about service subdomains
  (`groups.`, `upload.`, `pubsub.`) without certificates. Clients only connect to the XMPP domain, so this is harmless.
- `ghcr.io` image downloads are blocked in the build environment, so the stack uses `ejabberd/ecs` from Docker Hub.
