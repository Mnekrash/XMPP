#!/usr/bin/env bash
# CI only: runs a throw-away ejabberd (Homebrew) on the macOS runner with its own CA, trusted by the system,
# so the Martin-based transport is tested against a real server with normal certificate validation.
set -euo pipefail

DOMAIN=chat.it.test
WORK="$RUNNER_TEMP/ejabberd-it"
mkdir -p "$WORK"
PREFIX="$(brew --prefix)"
CTL="$PREFIX/sbin/ejabberdctl"
CONF="$PREFIX/etc/ejabberd/ejabberd.yml"

# CA + server certificate for the test domain; trust the CA system-wide.
# OpenSSL 3 from Homebrew: the runner's /usr/bin/openssl is LibreSSL, whose -addext produced an extension
# macOS rejects ("Unknown critical cert extension"). Extensions come from explicit config sections.
OPENSSL="$(brew --prefix openssl@3 2>/dev/null)/bin/openssl"
[[ -x "$OPENSSL" ]] || { brew install openssl@3 >/dev/null; OPENSSL="$(brew --prefix openssl@3)/bin/openssl"; }
cat > "$WORK/ext.cnf" <<CNF
[req]
distinguished_name = dn
[dn]
[ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
[server]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:$DOMAIN
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
CNF
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=Messenger CI CA" -config "$WORK/ext.cnf" \
  -extensions ca -keyout "$WORK/ca.key" -out "$WORK/ca.crt"
"$OPENSSL" req -newkey rsa:2048 -nodes -subj "/CN=$DOMAIN" -config "$WORK/ext.cnf" \
  -keyout "$WORK/server.key" -out "$WORK/server.csr"
"$OPENSSL" x509 -req -in "$WORK/server.csr" -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" -CAcreateserial -days 2 \
  -extfile "$WORK/ext.cnf" -extensions server -out "$WORK/server.crt"
cat "$WORK/server.key" "$WORK/server.crt" "$WORK/ca.crt" > "$WORK/server.pem"
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$WORK/ca.crt"
# Fail early if the system does not accept the server certificate (SSL server policy for the domain).
security verify-cert -c "$WORK/server.crt" -p ssl -s "$DOMAIN"

cat > "$CONF" <<YML
hosts: ["$DOMAIN"]
loglevel: info
acme:
  auto: false
certfiles: ["$WORK/server.pem"]
auth_method: [internal]
auth_password_format: scram
auth_scram_hash: sha256
s2s_access: none
listen:
  - port: 5223
    ip: "127.0.0.1"
    module: ejabberd_c2s
    tls: true
acl:
  local:
    user_regexp: ""
access_rules:
  local:
    allow: local
api_permissions:
  "console commands":
    from: ejabberd_ctl
    who: all
    what: "*"
modules:
  mod_admin_extra: {}
  mod_caps: {}
  mod_disco: {}
  mod_last: {}           # ban_account reads the last-activity record
  mod_ping: {}
  mod_private: {}
  mod_roster: {}
  mod_stream_mgmt: {}
  mod_vcard: {}
  mod_register:
    access: none
    access_remove: none
    password_strength: 40
YML

"$CTL" start
for _ in $(seq 1 60); do "$CTL" status >/dev/null 2>&1 && break; sleep 1; done
"$CTL" status

PASSWORD="it-$(openssl rand -hex 8)-Temp"
PASSWORD2="it-$(openssl rand -hex 8)-Restore"
"$CTL" register it_ok "$DOMAIN" "$PASSWORD"
"$CTL" set_vcard it_ok "$DOMAIN" FN "Integration User"
"$CTL" private_set it_ok "$DOMAIN" "<account xmlns='urn:x-messenger:account' must-change-password='true'/>"
"$CTL" register it_banned "$DOMAIN" "it-$(openssl rand -hex 8)"
"$CTL" ban_account it_banned "$DOMAIN" "integration test"
"$CTL" register it_restore "$DOMAIN" "$PASSWORD2"

{
  echo "IT_XMPP_DOMAIN=$DOMAIN"
  echo "IT_XMPP_HOST=127.0.0.1"
  echo "IT_PASSWORD=$PASSWORD"
  echo "IT_PASSWORD2=$PASSWORD2"
} >> "$GITHUB_ENV"
echo "::add-mask::$PASSWORD"
echo "::add-mask::$PASSWORD2"
