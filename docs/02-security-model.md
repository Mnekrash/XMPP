# 02 — Security Model

## 1. Assets

| Asset | Where it lives | Protection |
|-------|----------------|------------|
| Message plaintext | Device memory, local SQLite | iOS Data Protection; never sent to the server in plaintext |
| Attachment plaintext | Device cache (`Library/Caches/Media`, app container) | Data Protection; ciphertext only on the server |
| OMEMO identity private key | iOS Keychain | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronized, not backed up |
| OMEMO ratchet sessions, pre-key privates, skipped keys, attachment keys | SQLite columns **encrypted with AES-256-GCM** under a *state key* | State key in Keychain (`AfterFirstUnlockThisDeviceOnly`) |
| Account credential | Keychain | MVP: password. Phase 12: FAST token (XEP-0484) per device, revocable |
| Push payload key (per device) | Keychain, shared access group with the NSE | `AfterFirstUnlockThisDeviceOnly` |
| Metadata (who talks to whom, when) | Server (ejabberd DB, MAM) | TLS in transit, minimal retention, no analytics |

## 2. Threat model

In scope:

1. **Network attacker.** Mitigated by TLS 1.2+/1.3 with certificate validation (system trust store).
   Optional certificate pinning (SPKI, primary + backup pin) in Phase 12. There is no plaintext XMPP: the client uses direct TLS
   (XEP-0368) on 5223, and the server sets `starttls_required: true` on 5222.
2. **Compromised or curious server operator / storage.** The server stores only OMEMO ciphertext
   (MAM), encrypted attachments (HTTP Upload), and metadata. It cannot read content. It *can*
   inject a fake device into a device list. This is mitigated by trust state + new-device notices + optional verification.
3. **Lost or stolen phone.** iOS passcode + Data Protection. Optional Face ID app lock. Remote
   revocation from another device (removal from the OMEMO device list) and account disabling by the admin.
4. **Push provider (Apple).** Sees only device token, timing, and an encrypted blob. No names, no text.
5. **Brute force on login.** ejabberd rate limiting (`max_fsm_queue`, `shaper`, failed-auth
   ban via `mod_fail2ban`), strong passwords set by the admin.

Out of scope (documented, not mitigated in the MVP): a compromised iOS device (jailbreak or malware),
traffic analysis by the server operator, metadata hiding from the server.

## 3. Security rules (enforced in code review)

- No custom cryptographic primitives. Allowed primitives: CryptoKit (X25519, Ed25519, AES-GCM,
  HKDF, HMAC, SHA-2), CommonCrypto (AES-256-CBC, required by OMEMO 2), libsodium (only for
  Ed25519 → X25519 public-key conversion), `SecRandomCopyBytes` / CryptoKit for randomness.
- Logging: `os.Logger` only, all dynamic values `privacy: .private` by default. A lint rule forbids
  `print(` and string-interpolated message bodies, keys, and passwords. Release builds compile out
  debug-level logs.
- Never store secrets in `UserDefaults`, plist, the normal DB (unencrypted), or files.
- The DB and media folders are marked `isExcludedFromBackup`. Keychain items are `ThisDeviceOnly`.
  A backup restored on a new phone would hold a DB without keys, so we exclude both consistently.
- An app-switcher snapshot privacy overlay is shown when the app lock is enabled.
- Face ID (LocalAuthentication, `.deviceOwnerAuthentication` with passcode fallback) is a local
  UI gate only. It is not used to derive keys in the MVP.

## 4. Authentication

- The user enters username + password. The client builds `username@<xmppDomain>` from `ServerConfig`.
- SASL `SCRAM-SHA-256` over TLS (ejabberd: `auth_password_format: scram`,
  `auth_scram_hash: sha256`). `PLAIN` is disabled server-side.
- MVP: the password is stored in the Keychain to allow silent reconnect.
- Phase 12: SASL2 (XEP-0388) + FAST (XEP-0484, ejabberd `mod_auth_fast`) issue a per-device token,
  so the password no longer needs to be stored, and an individual device's login can be revoked.
- Admin "disable account" = `ejabberdctl ban_account`. This kicks sessions and blocks login.
  The client maps the resulting auth failure to "Your account is disabled. Contact your administrator."

## 5. OMEMO key and device model

Target: **XEP-0384 OMEMO Encryption v0.9.x, namespace `urn:xmpp:omemo:2`** (latest revision
0.9.1, 2026-04-06). Status of the XEP: **Experimental**, so the wire format may still change. We pin the
version we implement and track spec revisions. Legacy `eu.siacs.conversations.axolotl` is not a target.
Which implementation is used (library or our own protocol layer) is decided by spike S1.

### 5.1 Per-device key material

| Item | Type | Storage | Lifetime |
|------|------|---------|----------|
| Device ID | random 31-bit int (1 … 2³¹−1), unique within the account's device list | DB (plain) | Lifetime of the install |
| Identity key (IK) | Ed25519 key pair; X25519 form derived for DH | Keychain | Lifetime of the device |
| Signed pre-key (SPK) | X25519, signed by IK (Ed25519 signature) | DB, encrypted | Rotated every 7–30 days; previous one kept for a grace period |
| Pre-keys (OPK) | X25519, 100 published | DB, encrypted | One-time; consumed keys deleted after the session is established; refill when < 25 |
| Sessions | Double Ratchet state per (peer JID, device ID) | DB, encrypted | Until the device is removed |
| Skipped message keys | per session, max 1000 total / 200 per session, TTL 30 days | DB, encrypted | Bounded |

Published via PEP (XEP-0163) with publish-options (XEP-0222/0223, `pubsub#access_model=open`):

- `urn:xmpp:omemo:2:devices`: the device list, with a `label` + `labelsig` per device
  (e.g. "iPhone 16 Pro"). The label is signed with the device's IK, and receivers ignore unsigned labels.
- `urn:xmpp:omemo:2:bundles`: one item per device ID (IK pub, SPK pub + sig + id, OPKs).

### 5.2 Encryption

- Content uses SCE (XEP-0420) as profiled by OMEMO 2: an `<envelope>` with `<content>` (body,
  reply, reaction, correction, retraction, file-sharing metadata), `<rpad/>`, `<from/>`, and `<to/>` for
  groups. Optional `<time/>` is not used.
- The payload is encrypted once (AES-256-CBC + HMAC-SHA-256 truncated to 16 bytes, keys via HKDF
  "OMEMO Payload"). The payload key + HMAC are then encrypted per recipient device with the Double Ratchet.
- Recipients = all **trusted** devices of every recipient + all *other* own devices.
- Elements that must stay readable by the server stay **outside** the envelope:
  receipts (XEP-0184), markers (XEP-0333), chat states (XEP-0085), `origin-id` (XEP-0359),
  `<store/>` hints (XEP-0334), and the push-relevant `<body>` fallback
  ("This message is encrypted…").

### 5.3 Device lifecycle

```
install → generate IK, SPK, 100 OPK → pick device ID → publish bundle → add self to device list
          (on login, if the device list already contains other devices: show "New device added" on them)
normal  → refill OPKs, rotate SPK, refresh peer device lists on PEP +notify events
revoke  → from Settings ▸ Devices on any own device: remove the target ID from the device list,
          delete its bundle item; contacts stop encrypting to it (+ Phase 12: revoke its FAST token)
logout  → disable push, remove own ID from the device list, delete the bundle, wipe Keychain + DB
stale   → device with no traffic for 90 days: shown as "inactive"; not removed automatically
```

### 5.4 Trust model: BTBV (Blind Trust Before Verification)

- Chosen: BTBV. While no device of a contact has been verified, every new device of that contact
  is trusted automatically (TOFU), and a non-blocking notice appears in the chat:
  "Security code of John changed / John added a device".
- After the user verifies any device of a contact (QR or security-code comparison, Phase 10+),
  new devices of that contact become *undecided* and are excluded until approved.
- Alternative: strict manual trust of every device. Rejected because it creates friction that
  normal users click through anyway.
- Alternative: pure TOFU with no notices. Rejected because a server-injected device would go
  unnoticed.
- Data model: `omemo_device.trust ∈ {undecided, blindTrusted, verified, distrusted}`.
- Own devices follow the same rules. A new own device triggers a prominent notice on all other own devices.

### 5.5 Groups

- MUC rooms are created **members-only and non-anonymous** (required by OMEMO: room members' real
  JIDs must be visible to fetch their device lists).
- The sender encrypts per device for all affiliated members (owner/admin/member). The member list is
  fetched by affiliation query and kept in `group_member`. For the target group size (≤ 50 members,
  ~3 devices each) this means ≤ 150 key encryptions per message, which is acceptable.
- Removing a member: future messages are no longer encrypted to their devices. Past messages remain
  readable by them (inherent).

### 5.6 Future: secure history transfer (not in MVP)

MVP behaviour: a new device sees history from the moment it became an OMEMO recipient. This is an
MVP behaviour, **not** an architectural limit. The design keeps these properties so that a later
transfer such as *old iPhone → QR / confirmation → encrypted transfer → new iPhone* fits without redesign:

- Messages are stored **decrypted** locally, keyed by application IDs (`message.id`, `originId`,
  `stanzaId`). They never depend on ratchet state after ingest. History can therefore be exported
  without the OMEMO session state.
- `message.source` records where a row came from (`live`, `carbon`, `mam`, `transfer`). Imported rows
  pass through the same dedup pipeline (§3.2 in 03) as any other source.
- Attachment rows hold their own key (wrapped by the local state key), so media references can be transferred
  together with the messages.
- The transfer is device-to-device and end-to-end encrypted. Expected shape: a session authenticated by QR code or a security
  code between two own, trusted devices, a fresh ephemeral X25519 key agreement, and an AES-GCM stream
  of a versioned export format. The server sees only ciphertext if it relays the data. OMEMO identity keys are
  **not** transferred: the new device keeps its own identity.
- `EncryptionService` and `PersistenceService` stay separate, so an exporter/importer can be added as a
  new service without touching the ratchet code.

### 5.7 Verification requirements (any OMEMO implementation we ship)

Spike S1 decides which implementation is used (see [07 §3.2](07-ios-dependencies.md#32-omemo-2--open-decided-by-spike-s1)).
Whatever is chosen must pass:

1. Interop tests against at least one independent OMEMO 2 implementation (`python-twomemo` as a
   scriptable oracle in CI; a second independent client where practical): initial session, multi-device,
   pre-key consumption, session rebuild, device removal, device-list changes, reconnect, group messages,
   out-of-order and lost messages.
2. If we implement the protocol/state layer ourselves: per-step unit tests (X3DH, KDF chains,
   Double Ratchet steps, skipped keys, payload encryption) and fuzzing of protobuf/XML parsers.
   Cryptographic primitives always come from established libraries.
3. **Independent external security review before the production release.** It is mandatory and gates
   production. It does not block the skeleton or the spikes.

## 6. Attachment encryption (summary; details in 03 §4)

The client generates a random 256-bit key and 96-bit nonce and encrypts with AES-256-GCM. It then uploads the
ciphertext via HTTP Upload and sends URL + key + nonce + SHA-256 (of ciphertext and plaintext) +
size + MIME + name + a ≤ 3 KB thumbnail **inside the OMEMO envelope**. The server never receives
plaintext bytes or a plaintext thumbnail. Upload filenames are random (UUID); the original name
is sent only inside the envelope.

## 7. Server hardening (MVP baseline)

- Only ports 80 (ACME), 443 (HTTPS), 5222 (STARTTLS required), and 5223 (direct TLS) are public.
  Server-to-server federation is **disabled** (closed service). The component port, ejabberd
  API, and PostgreSQL bind to the internal Docker network only.
- Admin access only via SSH with key auth. `scripts/admin.sh` runs `ejabberdctl` inside the container.
- `mod_fail2ban` for failed authentication; per-IP connection shapers.
- In-band registration (`mod_register`) disabled.
- MAM retention policy configurable (default 365 days). HTTP Upload expiry (default 90 days).
