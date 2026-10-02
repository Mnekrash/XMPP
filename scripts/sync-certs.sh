#!/usr/bin/env bash
# Copy the XMPP domain certificate from Caddy to ejabberd and reload ejabberd if it changed.
# Run after the first "up" and then from cron (hourly is enough; Caddy renews well before expiry).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
compose() { docker compose -f "$ROOT/deploy/docker-compose.yml" --env-file "${ENV_FILE:-$ROOT/deploy/.env}" "$@"; }

result="$(compose run --rm -T cert-sync)"
echo "$result"
if [[ "$result" == *updated* ]]; then
  compose exec -T ejabberd ejabberdctl reload_config
  echo "ejabberd configuration reloaded"
fi
