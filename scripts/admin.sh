#!/usr/bin/env bash
# Minimal account administration (MVP). Run on the server host over SSH.
# Wraps ejabberdctl inside the ejabberd container; no admin API is exposed to the network.
#
#   admin.sh init                              create the shared contact group (run once)
#   admin.sh create <username> "<Display Name>"
#   admin.sh disable <username> "<reason>"
#   admin.sh enable <username>
#   admin.sh delete <username>
#   admin.sh reset-password <username>
#   admin.sh list
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/deploy/.env}"
TEAM_GROUP="team"

die() { echo "error: $*" >&2; exit 1; }

[[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE"
DOMAIN="$(grep -E '^XMPP_DOMAIN=' "$ENV_FILE" | tail -n 1 | cut -d= -f2- | sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//')"
[[ -n "$DOMAIN" ]] || die "XMPP_DOMAIN is not set in $ENV_FILE"

ctl() {
  docker compose -f "$ROOT/deploy/docker-compose.yml" --env-file "$ENV_FILE" \
    exec -T ejabberd ejabberdctl "$@"
}

valid_username() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9._-]{1,31}$ ]] || die "username must be 2-32 chars: a-z 0-9 . _ - (lowercase)"
}

new_password() {
  # 20 alphanumeric characters (~119 bits); printed once, never stored by this script.
  openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-20
}

push_cleanup() {
  # SKELETON: the push gateway does not store registrations yet (see docs/04-push.md).
  echo "note: push registration cleanup is not implemented yet (push gateway skeleton)" >&2
}

cmd="${1:-}"; shift || true
case "$cmd" in
  init)
    if ctl srg_list "$DOMAIN" | grep -qx "$TEAM_GROUP"; then
      echo "Shared contact group '$TEAM_GROUP' already exists."
      exit 0
    fi
    ctl srg_create "$TEAM_GROUP" "$DOMAIN" "Team" "All accounts on this server" "$TEAM_GROUP"
    ctl srg_user_add "@all@" "$DOMAIN" "$TEAM_GROUP" "$DOMAIN"
    echo "Shared contact group '$TEAM_GROUP' created: every account sees every other account."
    ;;
  create)
    [[ $# -eq 2 ]] || die "usage: create <username> \"<Display Name>\""
    valid_username "$1"
    password="$(new_password)"
    ctl register "$1" "$DOMAIN" "$password"
    ctl set_vcard "$1" "$DOMAIN" FN "$2"
    ctl set_nickname "$1" "$DOMAIN" "$2"
    echo "Created '$1' ($2)."
    echo "Initial password (shown once): $password"
    ;;
  disable)
    [[ $# -eq 2 ]] || die "usage: disable <username> \"<reason>\""
    valid_username "$1"
    ctl ban_account "$1" "$DOMAIN" "$2"
    push_cleanup
    echo "Disabled '$1': sessions closed, login blocked."
    ;;
  enable)
    [[ $# -eq 1 ]] || die "usage: enable <username>"
    valid_username "$1"
    ctl unban_account "$1" "$DOMAIN"
    echo "Enabled '$1'."
    ;;
  delete)
    [[ $# -eq 1 ]] || die "usage: delete <username>"
    valid_username "$1"
    read -r -p "Delete account '$1' and its server-side data permanently? Type the username to confirm: " answer
    [[ "$answer" == "$1" ]] || die "not confirmed"
    ctl kick_user "$1" "$DOMAIN" >/dev/null || true
    ctl unregister "$1" "$DOMAIN"
    push_cleanup
    echo "Deleted '$1'."
    ;;
  reset-password)
    [[ $# -eq 1 ]] || die "usage: reset-password <username>"
    valid_username "$1"
    password="$(new_password)"
    ctl change_password "$1" "$DOMAIN" "$password"
    ctl kick_user "$1" "$DOMAIN" >/dev/null || true
    echo "New password for '$1' (shown once): $password"
    ;;
  list)
    echo "Accounts:"; ctl registered_users "$DOMAIN"
    echo "Disabled:"; ctl list_banned "$DOMAIN" || true
    ;;
  *)
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
