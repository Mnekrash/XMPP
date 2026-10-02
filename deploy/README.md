# Server deployment (Docker Compose)

Services: `postgres`, `ejabberd`, `caddy`, `push-gateway` (stub). Architecture: [docs/05-server.md](../docs/05-server.md).

## Requirements

- Linux host with Docker Engine + Compose v2, `bash`, `openssl`, `python3` (smoke test only).
- DNS A/AAAA records for `XMPP_DOMAIN` and `UPLOAD_DOMAIN` (staging/production).
- Open ports: 80, 443 (Caddy), 5222, 5223 (XMPP). Nothing else.

## First start

```bash
cp deploy/.env.example deploy/.env      # fill in; secrets: openssl rand -hex 32
scripts/render-config.sh                # → deploy/generated/ejabberd.yml (git-ignored)
docker compose -f deploy/docker-compose.yml --env-file deploy/.env up -d --build --wait
scripts/sync-certs.sh                   # copy the XMPP certificate from Caddy to ejabberd
scripts/admin.sh init                   # shared contact group (once)
scripts/admin.sh create alice "Alice Smith"
```

Cron (host):

```
17 * * * *  cd /opt/messenger && scripts/sync-certs.sh >/dev/null
```

## Development check

```bash
scripts/dev-smoke.sh    # ENVIRONMENT=development only; creates and removes two temporary accounts
```

In development `TLS_MODE=internal`: Caddy issues certificates from its local CA. To trust it on a simulator,
export it with `docker compose … cp caddy:/data/caddy/pki/authorities/local/root.crt .` and install it.

## Notes

- The ejabberd image is `ejabberd/ecs` (ProcessOne, Docker Hub). `ghcr.io/processone/ejabberd` is the
  newer official image with a different file layout (`/opt/ejabberd`). Switching requires adjusting the
  volume paths in `docker-compose.yml`.
- `deploy/.env` values must not contain `$`, `"` or `\` (`render-config.sh` rejects them).
- Never set `loglevel: debug` in production: it logs full stanzas.
- Backups (`pg_dump` + upload volume, encrypted) are planned for Phase 11 and are not implemented yet.
