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

# CA + server certificate for the test domain; trust the CA system-wide (Network.framework uses it).
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=Messenger CI CA" \
  -keyout "$WORK/ca.key" -out "$WORK/ca.crt" -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"
openssl req -newkey rsa:2048 -nodes -subj "/CN=$DOMAIN" -keyout "$WORK/server.key" -out "$WORK/server.csr"
printf "subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n" "$DOMAIN" > "$WORK/ext.cnf"
openssl x509 -req -in "$WORK/server.csr" -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" -CAcreateserial -days 2 \
  -extfile "$WORK/ext.cnf" -out "$WORK/server.crt"
cat "$WORK/server.key" "$WORK/server.crt" "$WORK/ca.crt" > "$WORK/server.pem"
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$WORK/ca.crt"

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
