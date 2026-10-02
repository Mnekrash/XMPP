#!/usr/bin/env bash
# End-to-end check of a DEVELOPMENT server stack (also run by CI):
# render config → start stack → sync certificate → two temporary accounts → smoke test → remove accounts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export ENV_FILE="${ENV_FILE:-$ROOT/deploy/.env}"
compose() { docker compose -f "$ROOT/deploy/docker-compose.yml" --env-file "$ENV_FILE" "$@"; }

grep -qE '^ENVIRONMENT=development([[:space:]]|$)' "$ENV_FILE" || { echo "dev-smoke.sh runs only against ENVIRONMENT=development" >&2; exit 1; }
DOMAIN="$(grep -E '^XMPP_DOMAIN=' "$ENV_FILE" | cut -d= -f2- | sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//')"

"$ROOT/scripts/render-config.sh"
compose up -d --build --wait

for attempt in $(seq 1 15); do
  if "$ROOT/scripts/sync-certs.sh"; then break; fi
  [[ $attempt -eq 15 ]] && { echo "certificate not available" >&2; exit 1; }
  sleep 2
done
# Give ejabberd a moment after a possible reload.
sleep 3

WORK="$(mktemp -d)"
suffix="$(openssl rand -hex 3)"
user_a="smoke-a-$suffix"; user_b="smoke-b-$suffix"
cleanup() {
  for u in "$user_a" "$user_b"; do compose exec -T ejabberd ejabberdctl unregister "$u" "$DOMAIN" >/dev/null 2>&1 || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

compose cp caddy:/data/caddy/pki/authorities/local/root.crt "$WORK/ca.crt" >/dev/null
"$ROOT/scripts/admin.sh" init
pass_a="$("$ROOT/scripts/admin.sh" create "$user_a" "Smoke A" | sed -n 's/^Initial password (shown once): //p')"
pass_b="$("$ROOT/scripts/admin.sh" create "$user_b" "Smoke B" | sed -n 's/^Initial password (shown once): //p')"

VENV="$ROOT/tools/smoke/.venv"
if [[ ! -x "$VENV/bin/python" ]]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q -r "$ROOT/tools/smoke/requirements.txt"
fi

SMOKE_PASSWORD_A="$pass_a" SMOKE_PASSWORD_B="$pass_b" "$VENV/bin/python" "$ROOT/tools/smoke/xmpp_smoke.py" \
  --host 127.0.0.1 --port 5223 --ca "$WORK/ca.crt" "$user_a@$DOMAIN" "$user_b@$DOMAIN"
