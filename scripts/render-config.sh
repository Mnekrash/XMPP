#!/usr/bin/env bash
# Render server configuration templates from deploy/.env into deploy/generated/ (git-ignored).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/deploy/.env}"
OUT_DIR="$ROOT/deploy/generated"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE (copy deploy/.env.example and fill it in)" >&2
  exit 1
fi

# Parse KEY=VALUE lines without evaluating them (same subset docker compose accepts).
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
  if [[ ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
    echo "Cannot parse line in $ENV_FILE: $line" >&2
    exit 1
  fi
  key="${BASH_REMATCH[1]}"
  value="${BASH_REMATCH[2]}"
  if [[ "$value" =~ ^\"(.*)\"[[:space:]]*$ || "$value" =~ ^\'(.*)\'[[:space:]]*$ ]]; then
    value="${BASH_REMATCH[1]}"
  else
    value="${value%%[[:space:]]#*}"                 # inline comment
    value="${value%"${value##*[![:space:]]}"}"      # trailing whitespace
  fi
  if [[ "$value" == *[\$\"\\]* ]]; then
    echo "$key contains \$, \" or \\ (breaks compose interpolation or YAML). Use: openssl rand -hex 32" >&2
    exit 1
  fi
  printf -v "$key" '%s' "$value"
done < "$ENV_FILE"

required=(XMPP_DOMAIN UPLOAD_DOMAIN EJABBERD_DB_NAME EJABBERD_DB_USER EJABBERD_DB_PASSWORD
          PUSH_COMPONENT_SECRET UPLOAD_MAX_BYTES UPLOAD_RETENTION_DAYS)
for var in "${required[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "Required variable $var is empty in $ENV_FILE" >&2
    exit 1
  fi
done

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

# Plain bash substitution (no envsubst dependency; safe for any characters in values).
shopt -u patsub_replacement 2>/dev/null || true   # bash 5.2: keep "&" in values literal

render() {
  local template="$1" output="$2" content var
  content="$(<"$template")"
  for var in "${required[@]}"; do
    content="${content//\$\{$var\}/${!var}}"
  done
  if [[ "$content" =~ \$\{[A-Z_]+\} ]]; then
    echo "Unsubstituted variable ${BASH_REMATCH[0]} in $template" >&2
    exit 1
  fi
  printf '%s\n' "$content" > "$output"
  chmod 644 "$output"   # read by uid 9000 inside the container; the directory is 700 on the host
  echo "Rendered $output"
}

render "$ROOT/server/ejabberd/ejabberd.yml.template" "$OUT_DIR/ejabberd.yml"
