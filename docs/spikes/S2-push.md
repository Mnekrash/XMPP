# S2 — One-to-one APNs push

**Verdict: NOT YET DETERMINED. Waiting for the device run (§5).** This is not marked PASS, and it is not
PARTIAL for convenience. The final hop (APNs → physical iPhone → NSE) has to be executed on the owner's Mac and
iPhone, because the spike environment cannot run it. Evidence:
- it is a Linux container (no Xcode, no device);
- `curl https://api.sandbox.push.apple.com` → connection refused by the egress policy (HTTP 000);
- the owner's `.p8` key is not available to it.

Everything up to APNs is implemented and verified here against the real ejabberd (§3: 11/11 PASS).

**Date:** 2026-10-02 · **Code:** `push/` (gateway), `spikes/s2-push/` (server tests, NotificationEnvelope, iOS spike app)

## 1. Objective

ejabberd → push gateway → APNs → iPhone → Notification Service Extension. MVP policy:
- **preferred:** title `<sender display name>`, body "New message";
- **fallback:** "New message";
- **never:** plaintext content in the payload; no OMEMO decryption in the NSE.

## 2. What was built

| Component | Implementation |
|-----------|----------------|
| Push gateway (`push/`) | Go 1.25. XEP-0114 component; XEP-0050 commands `register-push-apns`, `unregister-push`, `mute-conversation`; XEP-0357 publish handler with constant-time secret check; APNs HTTP/2 client with ES256 provider token (Go stdlib crypto); 410/BadDeviceToken → registration deleted + `item-not-found` back to ejabberd; PostgreSQL store (pgx 5.11) with only the **hash** of the publish secret; `/healthz`. No JIDs or tokens in info logs (hashed ids) |
| Payload | `aps.alert.title = "New message"`, `mutable-content: 1`, `thread-id` = per-device HMAC of the conversation, `e` = base64(v1 ‖ nonce ‖ AES-256-GCM(deviceKey, {sender, conv, count})). The body is never forwarded (ejabberd `include_body: false`; the gateway ignores `last-message-body` even if present) |
| NotificationEnvelope (Swift package) | Opens `e` (CryptoKit/swift-crypto AES-GCM), computes the same opaque thread id, decides title/body with fallback rules |
| iOS spike app (`spikes/s2-push/ios`) | XcodeGen app + NSE. Martin 3.2.4 for XMPP (spike-only; AGPL, never distributed). Flow: login → APNs token → register → enable → background: close socket → foreground: reconnect + re-enable. Token-change handling, logout cleanup, NSE failure injection (timeout/crash), shared log export. **Not compiled here** |
| Admin | `scripts/admin.sh disable|delete` also deletes the account's push registrations |

## 3. Server-side results (executed here, ejabberd 26.09 + gateway + PostgreSQL)

The APNs hop is the development-only `apns-mock` (`push/cmd/apns-mock`). It speaks HTTP/2 over TLS, **verifies
the ES256 JWT** against the public key of the test `.p8`, records each request, and returns 410 for a configured
dead token. The gateway rejects endpoint overrides in production. Script: `spikes/s2-push/server_tests.py`.

| # | Test | Result | Observed |
|---|------|--------|----------|
| p01 | Foreground (live session) | PASS | message over XMPP, **0** APNs requests |
| p02 | Background (socket lost → SM hibernation) | PASS | 1 request: HTTP/2, valid JWT, `apns-push-type: alert`, priority 10, topic = bundle id; payload `{"aps":{"alert":{"title":"New message"},"mutable-content":1,"sound":"default","thread-id":"…"},"e":"…"}`; **no body, no JID**; `e` opens with the device key → sender |
| p03 | Terminated (no session at all) | PASS | offline message still produced 1 request |
| p04 | Complete gateway outage (all instances) | PASS (finding) | **A failed publish during the outage makes ejabberd disable push** (`disabling push` in its log); the next message produced no push until the client re-enabled after resume → mitigations p10 + re-enable on every session start/resume |
| p05 | Invalid token (410) | PASS | registration deleted; `item-not-found` to ejabberd; next message: 0 requests (node disabled) |
| p06 | Token refresh | PASS (finding) | only the new token gets pushes. **ejabberd allows one push node per session** (`push_session` PK = host, user, session timestamp): disable the old node **before** enabling the new one, otherwise "Database failure" |
| p07 | Logout cleanup | PASS | disable + unregister → 0 registrations, 0 requests |
| p08 | Mute | PASS | muted conversation: 0 requests; unmute restores. The mute key is an opaque per-device HMAC, so the gateway never stores the conversation JID |
| p09 | Admin disables the account | PASS | `admin.sh disable` bans the account and deletes its registrations |
| p10 | Two gateway instances | PASS | ejabberd load-balances the component; instance 1 stopped → 3/3 pushes by instance 2, no `disabling push` |
| p11 | Clean stream close | PASS | `</stream>` without disabling push → offline messages still push |

Payload audit: every recorded APNs request was checked; **0** contained message text or a JID.
Gateway unit tests: 4 packages, all green (payload leak checks, secret check, 410 handling, mute, forbidden
senders, JWT verified by an HTTP/2 test server). Swift `NotificationEnvelope`: 5 tests (8 cases); it opens envelopes
**sealed by the Go gateway** (cross-implementation vectors), rejects wrong keys/tampering, and falls back in every
failure case.

## 4. Consequences already applied

- `deploy/docker-compose.yml`: push-gateway runs **2 replicas** (p04/p10).
- The gateway coalesces pushes per device + conversation within 2 s (atomic in PostgreSQL across replicas). This
  was added after S3 found duplicate publishes; see the S3 report. Final S2 run: 11/11 with coalescing enabled.
- Client rules (docs/04): re-enable push after every new session **and** every resume; on token change:
  register new → disable old → enable new → unregister old (p06).
- App background strategy: closing the socket (aborted or clean) is fine for push (p02, p11). Keeping SM state
  allows instant resume.

## 5. Device runbook (owner: Mac with Xcode 26, a physical iPhone, Apple Developer account, `.p8` key)

**Preparation**
1. Staging server with a public certificate. `deploy/.env` must have:
   - `APNS_SECRETS_DIR` = host directory holding `AuthKey_<KEYID>.p8`;
   - `APNS_KEY_FILE=/run/apns/AuthKey_<KEYID>.p8`, plus `APNS_KEY_ID`, `APNS_TEAM_ID`;
   - `APNS_TOPIC` = the spike bundle id;
   - **no** `APNS_SANDBOX_URL` / `APNS_CA_FILE`.

   Then `docker compose up -d`.
2. `/healthz` of both gateway replicas: `{"component":true,"apns":true,…}`.
3. Accounts: `scripts/admin.sh create alice "Alice Smith"` and the same for `bob`.
4. `cd spikes/s2-push/ios`. Create `Local.xcconfig` with `DEVELOPMENT_TEAM` and `SPIKE_BUNDLE_ID` (must equal
   `APNS_TOPIC`). Run `xcodegen generate`, open the project, build to the iPhone (Debug → APNs **sandbox**).
5. In the app, enter host / bob's JID / password / gateway JID and `alice@…=Alice Smith`. Tap
   "Connect + enable push". The log must show: session established → permission true → token → push enabled.

**Checks.** Send from alice with any XMPP client, or `tools/smoke` / `spikes/s2-push/server_tests.py` helpers.
Record each result in the table below.

| # | Step | Expected |
|---|------|----------|
| D1 | APNs authentication with the real `.p8` | gateway log `delivered` with an `apns_id` (no 403 `InvalidProviderToken`) |
| D2 | Registration of the real iPhone | app log: token (32 bytes) → push enabled; `registration` row in PostgreSQL |
| D3 | Foreground | message appears in the app log as "XMPP message (foreground)"; no banner from APNs |
| D4 | Background (Home button, app still in the app switcher) | banner **"Alice Smith" / "New message"** within a few seconds |
| D5 | Suspended (background > 1 min) | same as D4 |
| D6 | Terminated (swipe away in the app switcher) | same as D4 (NSE runs even if the app is not running) |
| D7 | Token refresh (delete app → reinstall → connect) | new token registered, old node disabled/unregistered; old token later returns 410 → gateway deletes it |
| D8 | Invalid token | gateway log `token invalid, registration removed` for the old token after D7 |
| D9 | Logout | tap Logout; next message: no banner; no registration row |
| D10 | Gateway restart | `docker compose restart push-gateway` (rolling) while app in background → push still arrives |
| D11 | NSE executed | spike log (Copy full log) contains `[NSE] decided title=name` |
| D12 | NSE failure → fallback | set injection to `timeout`, background, send → banner **"New message"** after ≤ 30 s, log `time will expire`. Set to `crash` → banner "New message" |
| D13 | Sender-name decryption | D4 shows the display name, which exists only on the device |
| D14 | Generic fallback | remove alice from the names list → banner "New message" |
| D15 | No plaintext in the APNs payload | gateway is the only producer; payload format of §3/p02 (optionally log payload size only) — and the iPhone shows no text |

S2 = **PASS** if D1–D15 match. **FAIL** otherwise, with the failing row and the log attached here.

## 6. Unresolved

| Item | Owner |
|------|-------|
| Device run D1–D15 | owner (Mac + iPhone) |
| iOS spike app compile (written against Martin 3.2.4 sources, not compiled) | owner, first step of the device run |
| NotificationEnvelope on iOS uses swift-crypto's CryptoKit re-export (not built for iOS here) | owner |
