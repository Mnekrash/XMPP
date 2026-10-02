# Private Messenger (working title)

A private iPhone messenger for small closed groups. It uses XMPP as an invisible transport and OMEMO 2 for end-to-end encryption.

Status: **architecture approved with changes; project skeleton in place.** See [docs/STATUS.md](docs/STATUS.md).
Next: technical spikes S1–S4 before any feature work.

Start here: [docs/README.md](docs/README.md)

Layout:

| Path | Contents |
|------|----------|
| `ios/` | XcodeGen project, app + Notification Service Extension, `MessengerKit` Swift package |
| `server/` | ejabberd config template, PostgreSQL init, certificate sync |
| `push/` | APNs push gateway (Go) |
| `deploy/` | Docker Compose stack, Caddyfile, `.env.example`, [runbook](deploy/README.md) |
| `scripts/` | config rendering, account admin, cert sync, dev smoke test |
| `tools/smoke/` | XMPP server smoke test (Python) |
| `docs/` | architecture, decisions, status, spike reports |
