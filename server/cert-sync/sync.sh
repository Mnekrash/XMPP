#!/bin/sh
# Copies the certificate Caddy manages for $XMPP_DOMAIN into the volume ejabberd reads
# (owned by ejabberd's uid 9000). Invoked by scripts/sync-certs.sh.
set -eu

crt="$(find /caddy-data/caddy/certificates -type f -path "*/${XMPP_DOMAIN}/${XMPP_DOMAIN}.crt" | head -n 1)"
if [ -z "$crt" ]; then
  echo "No certificate for ${XMPP_DOMAIN} in Caddy storage yet" >&2
  exit 1
fi
key="${crt%.crt}.key"

if [ -f "/ejabberd-certs/${XMPP_DOMAIN}.crt" ] && cmp -s "$crt" "/ejabberd-certs/${XMPP_DOMAIN}.crt"; then
  echo "unchanged"
  exit 0
fi

install -m 0644 -o 9000 -g 9000 "$crt" "/ejabberd-certs/${XMPP_DOMAIN}.crt"
install -m 0600 -o 9000 -g 9000 "$key" "/ejabberd-certs/${XMPP_DOMAIN}.key"
echo "updated"
