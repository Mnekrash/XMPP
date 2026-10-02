# 05 — Server Architecture

## 1. Prosody vs ejabberd

Both are mature, TLS-only capable, and support everything OMEMO needs on the server side (PEP with
publish-options and `max_items`). OMEMO itself is purely client-side, so the comparison is about everything else.

| Criterion | Prosody 13.x | ejabberd 26.x (latest tag 26.09) |
|-----------|--------------|-------------------------|
| OMEMO prerequisites (PEP, publish-options, access model) | Yes | Yes |
| MAM 1:1 + MUC | `mod_mam`, `mod_muc_mam` | `mod_mam` (incl. MUC, MUC/Sub archive integration) |
| MUC | Solid; offline group delivery needs community modules | Solid; **MUC/Sub** delivers room messages to offline members (push-capable) |
| HTTP Upload | `mod_http_file_share` (built-in) | `mod_http_upload` + `mod_http_upload_quota` (built-in) |
| Push (XEP-0357) | `mod_cloud_notify` (+ community extensions) | `mod_push`, `mod_push_keepalive` (built-in; `include_body`/`include_sender` options) |
| SASL2 / FAST tokens | Community modules | Built-in (`mod_auth_fast`) |
| Administration | `prosodyctl`, admin shell | `ejabberdctl` + the same commands over `mod_http_api`: `register`, `unregister`, `change_password`, `ban_account`, `unban_account`, `registered_users`, `set_vcard`, `set_nickname`, `srg_*`, `kick_session` |
| Server-managed contacts | `mod_groups` (file-based) | `mod_shared_roster` (SQL-backed, managed via commands) |
| PostgreSQL | Generic key-value storage via LuaDBI | Native relational schema, first-class |
| Scalability | Single node, very efficient; enough for thousands of users | Erlang clustering; proven at very large scale |
| Maintainability | Small Lua codebase; many features live in community modules of varying maturity | Larger, but features are in core and released together; official container image |
| Deployment simplicity | Very simple config | Single YAML config; official Docker image; slightly heavier |

**Decision: ejabberd.**

- Why: the features this product depends on most are in core. Offline group push (MUC/Sub), push
  keepalive, FAST tokens, a SQL-backed shared roster, and a complete admin command set mean
  the MVP admin tool is a thin script and no custom server modules are needed. PostgreSQL support is native.
- Alternative: Prosody. It is simpler and lighter, but several required pieces (offline MUC push, SASL2/FAST,
  iOS-specific push tweaks) come from community modules that we would have to vet and pin.
- Cost accepted: ejabberd is heavier and Erlang is less approachable than Lua. Mitigation: we use
  stock modules only, with no custom Erlang code.

## 2. Topology (MVP: one VPS, Docker Compose)

```
Internet
  │ 80, 443 ─────────► caddy ──► ejabberd:5443 (HTTP Upload, internal)
  │                       └────► (ACME certificates for chat., upload.)  → shared volume (read-only for ejabberd)
  │ 5222 (STARTTLS req.) ┐
  │ 5223 (direct TLS)    ┴──► ejabberd ──► postgres:5432 (internal)
  │                           └─ component port 5347 (internal) ◄── push-gateway ──► api.push.apple.com:443
  └ SSH (keys only) for admin
```

Certificates: Caddy is the only ACME client. ejabberd reads the issued certs from Caddy's volume (read-only),
and a daily job runs `ejabberdctl reload_config` so renewed certificates are picked up.

Containers: `caddy`, `ejabberd` (official image, pinned version), `postgres:17`, `push-gateway`,
plus a `backup` job (cron, `pg_dump` + upload volume snapshot, encrypted with `age`).

Domains (all configured from `.env`, never hardcoded):

| Name | Purpose |
|------|---------|
| `chat.example.com` | XMPP domain + client endpoint (JIDs `user@chat.example.com`) |
| `groups.chat.example.com` | MUC service (internal name; not exposed to users) |
| `upload.example.com` | HTTP Upload (public HTTPS via Caddy) |
| `push.chat.example.com` | push gateway component JID (no DNS needed; internal component) |

Environments: `development` (docker-compose.dev.yml, local CA, APNs sandbox), `staging`, `production`.
Each is a separate host + `.env`. The iOS build configuration points to the matching domain.

## 3. ejabberd configuration highlights

```yaml
hosts: ["${XMPP_DOMAIN}"]
sql_type: pgsql
default_db: sql
new_sql_schema: true            # multi-host schema
update_sql_schema: true
auth_method: sql
auth_password_format: scram
auth_scram_hash: sha256
s2s_access: none                # federation disabled: closed service
listen:
  - {port: 5222, module: ejabberd_c2s, starttls_required: true, max_stanza_size: 262144, shaper: c2s_shaper}
  - {port: 5223, module: ejabberd_c2s, tls: true, max_stanza_size: 262144, shaper: c2s_shaper}
  - {port: 5443, ip: "::", module: ejabberd_http, tls: false, request_handlers: {/upload: mod_http_upload}}  # internal, behind Caddy
  - {port: 5347, ip: "<internal>", module: ejabberd_service, hosts: {"push.${XMPP_DOMAIN}": {password: "${COMPONENT_SECRET}"}}}
modules:
  mod_disco: {}
  mod_caps: {}
  mod_pubsub: {plugins: [flat, pep]}   # PEP for OMEMO, avatars, nick
  mod_pep: {}
  mod_carboncopy: {}
  mod_stream_mgmt: {resend_on_timeout: if_offline}
  mod_mam: {default: always, assume_mam_usage: true, user_mucsub_from_muc_archive: true}
  mod_muc: {host: "groups.${XMPP_DOMAIN}", access_create: local, default_room_options:
            {members_only: true, anonymous: false, persistent: true, mam: true, allow_subscription: true,
             public: false, public_list: false, allow_user_invites: false}}
  mod_http_upload: {put_url: "https://${UPLOAD_DOMAIN}/upload", max_size: 104857600}
  mod_http_upload_quota: {max_days: 90}
  mod_push: {include_body: false, include_sender: true, notify_on: messages}
  mod_push_keepalive: {resume_timeout: 72h, wake_on_timeout: true}
  mod_shared_roster: {db_type: sql}
  mod_vcard: {}
  mod_avatar: {}
  mod_fail2ban: {c2s_auth_ban_lifetime: 1h, c2s_max_auth_failures: 10}
  mod_ping: {}
  mod_register: false            # no in-band registration
```

(Illustrative. Exact option names are validated against the pinned ejabberd version when the skeleton is built.)

## 4. Administration (MVP)

`scripts/admin.sh` (run over SSH on the host) wraps `docker compose exec ejabberd ejabberdctl`:

| Command | ejabberd commands |
|---------|-------------------|
| `create <username> "<Display Name>"` | `register` (random strong password printed once) → `set_vcard FN` / `set_nickname` → `srg_user_add` to the team group |
| `disable <username> "<reason>"` | `ban_account` (kicks sessions, blocks login) + purge push registrations |
| `enable <username>` | `unban_account` |
| `delete <username>` | `unregister` + purge push registrations + remove from shared roster |
| `reset-password <username>` | `change_password` (new random password printed once) + `kick_session` |
| `list` | `registered_users` + `list_banned` |

Contacts: one shared roster group per team (`srg_create`, `srg_add_displayed`), so team members see
each other automatically. Users never add contacts by JID.

## 5. Observability

- All containers log to stdout (JSON where supported) → `docker logs` / journald with rotation.
- ejabberd log level `info`: connection failures and auth failures (no stanza bodies at this level).
  **Never** set `debug` in production: it logs full stanzas (ciphertext, but also metadata).
- Push gateway: APNs results, cleanup counts, latencies.
- Caddy: access logs for upload (no query strings, upload paths are random UUIDs).
- Health: Docker healthchecks (`ejabberdctl status`, `pg_isready`, gateway `/healthz`); external uptime
  probe on 5223 and `upload.` 443; disk-usage alert (upload volume, Postgres).
- Optional (Phase 12): Prometheus node exporter + postgres exporter; no message-level metrics.

## 6. Backup and recovery

- Nightly `pg_dump` (ejabberd + gateway DBs) and an upload-volume snapshot, encrypted with `age`, copied off-host.
- Restore runbook in `docs/runbooks/restore.md` (Phase 11). Tested on staging before production launch.
- Note: the backups contain only ciphertext messages + metadata. Losing the server never exposes content.
