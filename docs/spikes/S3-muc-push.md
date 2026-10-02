# S3 — MUC / group push

**Verdict: NOT YET DETERMINED. Waiting for the device run (§5),** for the same reason as S2 (no iPhone or APNs
access from the spike environment). The ejabberd MUC/MUC-Sub behaviour behind group push is **measured** here
(9/9 checks, 2 consecutive runs). Those measurements changed the gateway and the client design (§4).

**Date:** 2026-10-02 · **Code:** `spikes/s3-muc-push/group_tests.py`, gateway changes in `push/`

## 1. Objective

Measure real ejabberd behaviour for group push instead of assuming that one-to-one push behaviour applies. Cases:
active member, offline member, muted group, multiple devices, suspended app, completely disconnected device.

## 2. Environment

As S2: ejabberd 26.09 with the Task 2 room defaults (members-only, non-anonymous, persistent, MAM,
`allow_subscription: true`), `mod_mam` with `user_mucsub_from_muc_archive: true`, `mod_push`
(`include_body: false`, `include_sender: true`), two push-gateway replicas, PostgreSQL 17, dev-only APNs mock.
Clients: slixmpp 1.17 (raw MUC/Sub `urn:xmpp:mucsub:0` subscribe IQ).

## 3. Results (identical in 2 runs)

| # | Case | Result | Observed |
|---|------|--------|----------|
| g01 | Active member (joined, online) | PASS | delivered live, **0** APNs requests |
| g02 | Offline member, affiliation only (no MUC/Sub) | PASS (finding) | **0** APNs requests: a plain MUC member who is offline gets **no push** |
| g03 | Offline member with MUC/Sub | PASS (finding) | APNs request sent. ejabberd **published twice for one message** (2 ms apart, identical); the gateway now coalesces to 1. After reconnect, **nothing arrives from offline storage**; the message is in the user's own MAM archive **and** the room's MAM archive |
| g04 | Joined member, app suspended (socket lost → SM hibernation), no MUC/Sub | PASS | 1 APNs request while hibernated. After the hibernation timeout the member leaves the room → g02 applies |
| g05 | Joined + MUC/Sub, suspended | PASS | 1 APNs request per message (no double notification) |
| g06 | Muted group | PASS | ejabberd reports the **room JID** as sender/conversation (no nick); muting its opaque per-device id → **0** requests |
| g07 | Multiple devices of one member, both offline | PASS | one request per device token (2), duplicates coalesced per device |
| g08 | Device completely disconnected, several messages | PASS | burst of 3 messages within 0.6 s → **1** request (coalesced); 2 messages 2.5 s apart → 2 requests. `message-count` is not provided for MUC/Sub pushes |
| g09 | Coalescing with two gateway replicas | PASS | 4 messages → 1 request each; the duplicate publish landed on either replica and was suppressed via the shared PostgreSQL claim |

No group message text reached any APNs payload (payload audit across S2+S3: 0 leaks).

## 4. Consequences (applied)

1. **MUC/Sub is mandatory for group push** (g02). Group membership in the app = MUC affiliation **plus** a MUC/Sub
   subscription to `urn:xmpp:mucsub:nodes:messages`. The MUC/Sub decision (D7) is confirmed by measurement.
2. **Duplicate publishes** (g03): the gateway coalesces pushes per (device, conversation) within 2 s
   (`PUSH_COALESCE_WINDOW`). The claim is an atomic `INSERT … ON CONFLICT … WHERE … RETURNING` in PostgreSQL,
   so it also works across replicas (g09). Side effect: rapid bursts give one notification per conversation, which is
   the intended UX (the app fetches content on open).
3. **Group messages are not delivered from offline storage** (g03): on reconnect the SyncEngine must run MAM catch-up for
   the own archive (it contains MUC/Sub messages) and/or each room archive. docs/03 §3.4 already does both. The
   S4 dedup rules then apply: the same message can appear in both archives with **different** stanza-ids (`by=` own
   JID vs `by=` room), so the origin-id rule is what deduplicates it (still to verify in the MUC dedup run, §6).
4. **Push sender for groups is the room JID without the nick** (g04/g06). The NSE can show the group title, not the
   author. Showing "Bob in Project Team" would need the nick in the push; ejabberd's MUC/Sub summary does not
   provide it. This is accepted for the MVP (the title is the group name, the body "New message").
5. `message-count` is absent for MUC/Sub pushes. The NSE does not rely on it.

## 5. Device runbook (owner)

Prerequisite: S2 device run D1–D4 passed (same spike app, same staging server).

| # | Step | Expected |
|---|------|----------|
| G1 | Create a room from alice (any client) on `groups.<domain>`, affiliate bob as member. Bob's spike app: subscribe via MUC/Sub (`spikes/s3-muc-push` helper or any client logged in as bob) | room shows bob as member |
| G2 | Active member: bob's app in foreground, alice sends to the room | no APNs banner (live delivery) |
| G3 | Offline member: bob's app terminated, alice sends | **one** banner with title = group name (names list: `room@groups…=Project Team`), body "New message" |
| G4 | Muted group: mute the room (gateway `mute-conversation` with the opaque id), alice sends | no banner |
| G5 | Multiple devices: second device (simulator cannot receive APNs; use a second iPhone if available) | a banner on each device |
| G6 | Suspended app (background > 1 min), alice sends | one banner |
| G7 | Completely disconnected device (Airplane mode), alice sends 3 messages, then disable Airplane mode | at most one banner per 2 s burst once the device is back online (APNs stores the last notification per device) |

S3 = **PASS** if G1–G7 match. **FAIL** otherwise, with the failing row and logs attached here.

## 6. Unresolved

| Item | Plan |
|------|------|
| Device run G1–G7 | owner |
| MUC dedup between own-archive and room-archive copies (different stanza-ids, same origin-id) | extend the S4 harness with a MUC/Sub case before Phase 8 |
| Author nick in group notifications | out of MVP scope; would need a custom ejabberd hook or a gateway lookup |
