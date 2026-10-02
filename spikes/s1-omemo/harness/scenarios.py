"""S1 interop scenarios: Swift OMEMOKit prototype ↔ python-omemo/twomemo 2.1.0, through the real ejabberd.

Run:  python scenarios.py            (requires the dev stack, the omemo-swift-dev image and a built omemo-cli)
Output: one PASS/FAIL line per scenario plus timings; JSON report written to $S1_REPORT (optional).
"""
from __future__ import annotations

import asyncio
import base64
import json
import logging
import os
import random
import statistics
import subprocess
import sys
import time
import traceback
import xml.etree.ElementTree as ET
from typing import Any, Awaitable, Callable, Dict, List, Optional

import slixmpp
from twomemo import twomemo_pb2

from devices import (NS_OMEMO, TIMINGS, PyDevice, Received, SwiftDevice, SwiftError)

DOMAIN = "chat.messenger.test"
SPIKE_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
STATE_DIR = os.environ.get("S1_STATE_DIR", "/tmp/claude-0/s1state")
EJABBERD = os.environ.get("EJABBERD_CONTAINER", "messenger-dev-ejabberd-1")
POSTGRES = os.environ.get("POSTGRES_CONTAINER", "messenger-dev-postgres-1")

logging.basicConfig(level=logging.ERROR)


def jid(user: str) -> str:
    return f"{user}@{DOMAIN}"


def reset_accounts() -> None:
    for u in ("alice", "bob", "carol", "dave"):
        subprocess.run(["docker", "exec", EJABBERD, "ejabberdctl", "unregister", u, DOMAIN], capture_output=True)
        subprocess.run(["docker", "exec", EJABBERD, "ejabberdctl", "register", u, DOMAIN, f"pw-{u}-s1"],
                       capture_output=True, check=True)
    os.makedirs(STATE_DIR, exist_ok=True)
    for f in os.listdir(STATE_DIR):
        os.remove(os.path.join(STATE_DIR, f))


def swift(user: str, name: str, label: str) -> SwiftDevice:
    return SwiftDevice(f"{jid(user)}/{name}", f"pw-{user}-s1", SPIKE_DIR, STATE_DIR, name, label)


def py(user: str, resource: str) -> PyDevice:
    return PyDevice(f"{jid(user)}/{resource}", f"pw-{user}-s1")


def kex_params(encrypted_xml: str, rid: int) -> Optional[Dict[str, int]]:
    """Reads pk_id/spk_id from the OMEMOKeyExchange addressed to `rid` (None if not a key exchange)."""
    for key in ET.fromstring(encrypted_xml).iter(f"{{{NS_OMEMO}}}key"):
        if key.get("rid") == str(rid) and key.get("kex") in ("true", "1"):
            kex = twomemo_pb2.OMEMOKeyExchange.FromString(base64.b64decode(key.text or ""))
            return {"pk_id": kex.pk_id, "spk_id": kex.spk_id}
    return None


def rids(encrypted_xml: str, for_jid: str) -> List[int]:
    out: List[int] = []
    for keys in ET.fromstring(encrypted_xml).iter(f"{{{NS_OMEMO}}}keys"):
        if keys.get("jid") == for_jid:
            out += [int(k.get("rid")) for k in keys.iter(f"{{{NS_OMEMO}}}key")]
    return out


async def bundle_pk_ids(observer, owner_jid: str, device_id: int) -> List[int]:
    xml = await observer.fetch_bundle_xml(owner_jid, device_id)
    return [int(pk.get("id")) for pk in ET.fromstring(xml).iter(f"{{{NS_OMEMO}}}pk")] if xml else []


async def bundle_spk_id(observer, owner_jid: str, device_id: int) -> int:
    xml = await observer.fetch_bundle_xml(owner_jid, device_id)
    return int(ET.fromstring(xml).find(f"{{{NS_OMEMO}}}spk").get("id"))


async def receive_and_decrypt(device, expect_body: Optional[str], timeout: float = 15) -> Dict[str, Any]:
    r = await device.next_message(timeout)
    d = await device.decrypt(r)
    if expect_body is not None:
        assert d.get("body") == expect_body, f"{device.kind}: expected {expect_body!r}, got {d.get('body')!r}"
    d["_received"] = r
    return d


async def drain(device, seconds: float = 1.5) -> int:
    """Decrypts any pending automatic (empty) messages, e.g. python-omemo handshake completions."""
    n = 0
    while True:
        try:
            r = await device.next_message(seconds)
        except asyncio.TimeoutError:
            return n
        await device.decrypt(r)
        n += 1


class Ctx:
    def __init__(self) -> None:
        self.devices: List[Any] = []
        self.notes: List[str] = []

    async def start(self, device, **kw):
        await device.start(**kw)
        self.devices.append(device)
        return device

    async def stop_all(self) -> None:
        for d in reversed(self.devices):
            try:
                await d.stop()
            except Exception:
                pass
        self.devices.clear()

    def note(self, text: str) -> None:
        self.notes.append(text)


# ----------------------------------------------------------------------------------------- scenarios

async def s01_initial_x3dh(c: Ctx) -> None:
    """Initial X3DH session in both directions (python→Swift and Swift→python)."""
    b = await c.start(swift("bob", "b1", "Bob iPhone"))
    a = await c.start(py("alice", "a1"))
    await a.send_text(jid("bob"), "x3dh py→swift")
    d = await receive_and_decrypt(b, "x3dh py→swift")
    assert d["kex"] and d["newSession"], d
    c.note(f"py→swift: key exchange accepted, Swift consumed pre-key {d['consumedPreKeyId']}")

    carol = await c.start(py("carol", "c1"))
    await b.refresh(jid("carol"))
    r = await b.send_text(jid("carol"), "x3dh swift→py")
    assert len(r["kex"]) == 1, r
    d2 = await receive_and_decrypt(carol, "x3dh swift→py")
    assert d2["kex"], d2
    c.note("swift→py: python built a passive session from the Swift key exchange")


async def s02_prekey_consumption(c: Ctx) -> None:
    """Consumed pre-keys are removed from the published bundle on both implementations."""
    b = await c.start(swift("bob", "b1", "Bob iPhone"))
    a = await c.start(py("alice", "a1"))
    before = await bundle_pk_ids(a, jid("bob"), b.device_id)
    xml = await a.send_text(jid("bob"), "consume")
    used = kex_params(xml, b.device_id)["pk_id"]
    d = await receive_and_decrypt(b, "consume")
    after = await bundle_pk_ids(a, jid("bob"), b.device_id)
    assert used in before and used not in after and d["consumedPreKeyId"] == used, (used, before[:5], after[:5])
    assert len(after) >= 90, len(after)
    c.note(f"Swift: pk {used} removed from published bundle, {len(after)} pre-keys published after refill")

    carol = await c.start(py("carol", "c1"))
    await b.refresh(jid("carol"))
    r = await b.send_text(jid("carol"), "consume2")
    used2 = kex_params(r["xml"], carol.device_id)["pk_id"]
    before2 = await bundle_pk_ids(b, jid("carol"), carol.device_id)
    await receive_and_decrypt(carol, "consume2")
    await asyncio.sleep(1)
    after2 = await bundle_pk_ids(b, jid("carol"), carol.device_id)
    assert used2 in before2 and used2 not in after2, (used2, after2[:5])
    c.note(f"python: pk {used2} removed from its published bundle after the Swift key exchange")


async def s03_regular_ratchet(c: Ctx) -> None:
    """After the handshake both sides send normal (non-kex) Double Ratchet messages."""
    b = await c.start(swift("bob", "b1", "Bob iPhone"))
    a = await c.start(py("alice", "a1"))
    await a.send_text(jid("bob"), "m0")
    await receive_and_decrypt(b, "m0")
    await b.refresh(jid("alice"))
    r = await b.send_text(jid("alice"), "m1")
    assert r["kex"] == [], r
    d = await receive_and_decrypt(a, "m1")
    assert not d["kex"]
    await drain(b)
    xml = await a.send_text(jid("bob"), "m2")
    assert kex_params(xml, b.device_id) is None, "python still sends key exchange after confirmation"
    d = await receive_and_decrypt(b, "m2")
    assert not d["kex"]
    c.note("both directions use plain OMEMOAuthenticatedMessage after confirmation")


async def s04_bidirectional(c: Ctx) -> None:
    """60 messages in random bursts in both directions (many DH ratchet steps)."""
    b = await c.start(swift("bob", "b1", "Bob iPhone"))
    a = await c.start(py("alice", "a1"))
    await a.send_text(jid("bob"), "start")
    await receive_and_decrypt(b, "start")
    await b.refresh(jid("alice"))
    rng = random.Random(42)
    sent = 0
    while sent < 60:
        burst = rng.randint(1, 4)
        if rng.random() < 0.5:
            for i in range(burst):
                await b.send_text(jid("alice"), f"s{sent + i}")
            for i in range(burst):
                await receive_and_decrypt(a, f"s{sent + i}")
        else:
            for i in range(burst):
                await a.send_text(jid("bob"), f"p{sent + i}")
            for i in range(burst):
                await receive_and_decrypt(b, f"p{sent + i}")
        sent += burst
        await drain(b, 0.2)
        await drain(a, 0.2)
    c.note(f"{sent} messages, random bursts, all decrypted on both sides")


async def s05_multiple_recipient_devices(c: Ctx) -> None:
    """One message encrypted for several devices of the recipient, both directions."""
    a1 = await c.start(py("alice", "a1"))
    a2 = await c.start(py("alice", "a2"))
    b1 = await c.start(swift("bob", "b1", "Bob iPhone"))
    b2 = await c.start(swift("bob", "b2", "Bob iPad"))
    await b1.refresh(jid("alice"))
    await b1.refresh(jid("bob"))
    r = await b1.send_text(jid("alice"), "to all alice devices")
    alice_rids = sorted(x["deviceId"] for x in r["recipients"] if x["jid"] == jid("alice"))
    assert alice_rids == sorted([a1.device_id, a2.device_id]), (alice_rids, a1.device_id, a2.device_id)
    assert any(x["jid"] == jid("bob") and x["deviceId"] == b2.device_id for x in r["recipients"]), "own-device copy missing"
    await receive_and_decrypt(a1, "to all alice devices")
    await receive_and_decrypt(a2, "to all alice devices")
    c.note("Swift→python: one <encrypted> with keys for 2 alice devices + own other device")

    xml = await a1.send_text(jid("bob"), "to all bob devices")
    assert sorted(rids(xml, jid("bob"))) == sorted([b1.device_id, b2.device_id]), rids(xml, jid("bob"))
    await receive_and_decrypt(b1, "to all bob devices")
    await receive_and_decrypt(b2, "to all bob devices")
    c.note("python→Swift: keys for 2 Swift devices, both decrypt")


async def s06_new_sender_device(c: Ctx) -> None:
    """A device that appears later (new python device, new Swift device) is handled without manual steps."""
    a1 = await c.start(py("alice", "a1"))
    b1 = await c.start(swift("bob", "b1", "Bob iPhone"))
    await a1.send_text(jid("bob"), "hello")
    await receive_and_decrypt(b1, "hello")

    a3 = await c.start(py("alice", "a3"))
    await a3.send_text(jid("bob"), "from new python device")
    d = await receive_and_decrypt(b1, "from new python device")
    assert d["newSession"] and d["senderDeviceId"] == a3.device_id, d
    await b1.refresh(jid("alice"))
    r = await b1.send_text(jid("alice"), "reply to all")
    assert a3.device_id in [x["deviceId"] for x in r["recipients"]]
    await receive_and_decrypt(a3, "reply to all")
    await receive_and_decrypt(a1, "reply to all")
    c.note("new python device: Swift built a passive session on first message and includes it after refresh")

    b2 = await c.start(swift("bob", "b2", "Bob new iPhone"))
    await b2.refresh(jid("alice"))
    await b2.send_text(jid("alice"), "from new swift device")
    d2 = await receive_and_decrypt(a1, "from new swift device")
    assert d2["senderDeviceId"] == b2.device_id
    c.note("new Swift device: python accepted its key exchange")


async def s07_removed_device(c: Ctx) -> None:
    """A device removed from the device list no longer receives keys (both implementations)."""
    a1 = await c.start(py("alice", "a1"))
    a2 = await c.start(py("alice", "a2"))
    b1 = await c.start(swift("bob", "b1", "Bob iPhone"))
    b2 = await c.start(swift("bob", "b2", "Bob old iPad"))
    await b1.refresh(jid("alice"))
    r = await b1.send_text(jid("alice"), "before removal")
    assert a2.device_id in [x["deviceId"] for x in r["recipients"]]
    await receive_and_decrypt(a1, "before removal")
    await receive_and_decrypt(a2, "before removal")

    # Remove a2: stop it, then publish alice's list without it.
    await a2.stop()
    c.devices.remove(a2)
    devices = await a1.fetch_device_list_xml(jid("alice"))
    for d in list(devices):
        if d.get("id") == str(a2.device_id):
            devices.remove(d)
    await a1.publish_device_list(devices)
    await b1.refresh(jid("alice"))
    r = await b1.send_text(jid("alice"), "after removal")
    assert a2.device_id not in [x["deviceId"] for x in r["recipients"]], r["recipients"]
    await receive_and_decrypt(a1, "after removal")
    c.note("Swift stops encrypting for a device removed from the device list")

    # Remove b2 from bob's list; python must stop encrypting for it.
    await b2.stop()
    c.devices.remove(b2)
    devices = await b1.fetch_device_list_xml(jid("bob"))
    for d in list(devices):
        if d.get("id") == str(b2.device_id):
            devices.remove(d)
    await b1.publish_device_list(devices)
    await asyncio.sleep(1)
    xml = await a1.send_text(jid("bob"), "python after removal")
    assert b2.device_id not in rids(xml, jid("bob")), rids(xml, jid("bob"))
    await receive_and_decrypt(b1, "python after removal")
    c.note("python stops encrypting for a Swift device removed from the device list")


async def s08_bundle_refresh(c: Ctx) -> None:
    """Signed pre-key rotation + bundle republish; new sessions use the new SPK (both directions)."""
    b1 = await c.start(swift("bob", "b1", "Bob iPhone"))
    observer = await c.start(py("alice", "a1"))
    old = await bundle_spk_id(observer, jid("bob"), b1.device_id)
    await b1.cli.call(cmd="rotateSignedPreKey")
    await b1.publish()
    new = await bundle_spk_id(observer, jid("bob"), b1.device_id)
    assert new == old + 1, (old, new)
    dave = await c.start(py("dave", "d1"))
    xml = await dave.send_text(jid("bob"), "uses new spk")
    assert kex_params(xml, b1.device_id)["spk_id"] == new
    await receive_and_decrypt(b1, "uses new spk")
    c.note(f"Swift SPK rotated {old}→{new}; python built its session against the new SPK")

    carol = await c.start(py("carol", "c1"))
    spk_before = await bundle_spk_id(b1, jid("carol"), carol.device_id)
    await carol.rotate_signed_pre_key()
    spk_after = await bundle_spk_id(b1, jid("carol"), carol.device_id)
    assert spk_after != spk_before
    await b1.refresh(jid("carol"))
    r = await b1.send_text(jid("carol"), "uses carol's new spk")
    assert kex_params(r["xml"], carol.device_id)["spk_id"] == spk_after
    await receive_and_decrypt(carol, "uses carol's new spk")
    c.note(f"python SPK rotated {spk_before}→{spk_after}; Swift fetched the refreshed bundle and used it")


async def s09_stale_prekeys(c: Ctx) -> None:
    """Key exchange with an already-consumed pre-key / a signed pre-key rotated twice is rejected,
    and the initiator recovers by refreshing the bundle."""
    b1 = await c.start(swift("bob", "b1", "Bob iPhone"))
    carol = await c.start(py("carol", "c1"))
    await b1.refresh(jid("carol"))
    stale_bundle = await b1.fetch_bundle_xml(jid("carol"), carol.device_id)

    # (a) consumed pre-key: first session uses pk X; then force a second session with a bundle that only offers X.
    r = await b1.send_text(jid("carol"), "first")
    x = kex_params(r["xml"], carol.device_id)["pk_id"]
    await receive_and_decrypt(carol, "first")
    await drain(b1)
    root = ET.fromstring(stale_bundle)
    prekeys = root.find(f"{{{NS_OMEMO}}}prekeys")
    for pk in list(prekeys):
        if pk.get("id") != str(x):
            prekeys.remove(pk)
    await b1.cli.call(cmd="deleteSession", jid=jid("carol"), deviceId=carol.device_id)
    await b1.cli.call(cmd="setBundle", jid=jid("carol"), deviceId=carol.device_id,
                      bundleXML=ET.tostring(root, encoding="unicode"))
    await b1.send_text(jid("carol"), "stale pk")
    try:
        await receive_and_decrypt(carol, None)
        raise AssertionError("python accepted a key exchange with an already consumed pre-key")
    except AssertionError:
        raise
    except Exception as e:
        c.note(f"(a) consumed pre-key rejected by python: {type(e).__name__}")
    await b1.cli.call(cmd="deleteSession", jid=jid("carol"), deviceId=carol.device_id)
    await b1.refresh(jid("carol"))
    await b1.send_text(jid("carol"), "recovered a")
    await receive_and_decrypt(carol, "recovered a")
    c.note("(a) recovery: Swift refreshed the bundle, new key exchange accepted")

    # (b) SPK rotated twice (python keeps only one previous SPK).
    await drain(b1)
    cached = await b1.fetch_bundle_xml(jid("carol"), carol.device_id)
    await carol.rotate_signed_pre_key()
    await carol.rotate_signed_pre_key()
    await b1.cli.call(cmd="deleteSession", jid=jid("carol"), deviceId=carol.device_id)
    await b1.cli.call(cmd="setBundle", jid=jid("carol"), deviceId=carol.device_id, bundleXML=cached)
    await b1.send_text(jid("carol"), "stale spk")
    try:
        await receive_and_decrypt(carol, None)
        raise AssertionError("python accepted a key exchange with an expired signed pre-key")
    except AssertionError:
        raise
    except Exception as e:
        c.note(f"(b) expired SPK rejected by python: {type(e).__name__}")
    await b1.cli.call(cmd="deleteSession", jid=jid("carol"), deviceId=carol.device_id)
    await b1.refresh(jid("carol"))
    await b1.send_text(jid("carol"), "recovered b")
    await receive_and_decrypt(carol, "recovered b")
    c.note("(b) recovery after refresh accepted")

    c.note("(c) Swift as receiver of an expired-SPK key exchange: unit test signedPreKeyRotatedTwiceIsRejected "
           "(python-omemo always re-downloads bundles, so it cannot be made to send one)")


async def s10_session_recreation(c: Ctx) -> None:
    """Lost session state on either side is healed by a new key exchange."""
    a1 = await c.start(py("alice", "a1"))
    b1 = await c.start(swift("bob", "b1", "Bob iPhone"))
    await a1.send_text(jid("bob"), "established")
    await receive_and_decrypt(b1, "established")
    await b1.refresh(jid("alice"))
    await b1.send_text(jid("alice"), "ack")
    await receive_and_decrypt(a1, "ack")
    await drain(b1)

    # Swift loses its session (e.g. restored without crypto state).
    await b1.cli.call(cmd="deleteSession", jid=jid("alice"), deviceId=a1.device_id)
    await a1.send_text(jid("bob"), "after swift lost state")
    try:
        await receive_and_decrypt(b1, None)
        raise AssertionError("decrypted without a session")
    except SwiftError as e:
        c.note(f"Swift without session: {e} (expected)")
    await b1.refresh(jid("alice"))
    r = await b1.send_text(jid("alice"), "new session from swift")
    assert len(r["kex"]) == 1
    await receive_and_decrypt(a1, "new session from swift")
    await drain(a1)
    await a1.send_text(jid("bob"), "python uses replaced session")
    await receive_and_decrypt(b1, "python uses replaced session")
    c.note("Swift re-initiated; python replaced its session and continued")

    # Python loses/replaces its session (python-omemo API: replace_sessions).
    await drain(b1)
    info = next(d for d in await a1.sm.get_device_information(jid("bob")) if d.device_id == b1.device_id)
    await a1.sm.replace_sessions(info)
    await asyncio.sleep(1)
    await drain(b1)  # replace_sessions sends an empty key-exchange message
    xml = await a1.send_text(jid("bob"), "after python replaced session")
    await receive_and_decrypt(b1, "after python replaced session")
    c.note(f"python replace_sessions → Swift accepted the new key exchange (kex in next message: {kex_params(xml, b1.device_id) is not None})")


async def s11_out_of_order(c: Ctx) -> None:
    """Messages decrypted in a different order than sent (skipped message keys), both directions."""
    a1 = await c.start(py("alice", "a1"))
    b1 = await c.start(swift("bob", "b1", "Bob iPhone"))
    await a1.send_text(jid("bob"), "sync")
    await receive_and_decrypt(b1, "sync")
    await b1.refresh(jid("alice"))
    await b1.send_text(jid("alice"), "sync2")
    await receive_and_decrypt(a1, "sync2")
    await drain(b1)

    for i in range(6):
        await a1.send_text(jid("bob"), f"py{i}")
    py_batch = [await b1.next_message() for _ in range(6)]
    for i in [0, 5, 2, 1, 4, 3]:
        d = await b1.decrypt(py_batch[i])
        assert d["body"] == f"py{i}", d
    c.note("python→Swift order 0,5,2,1,4,3 decrypted")
    try:
        await b1.decrypt(py_batch[2])
        raise AssertionError("Swift decrypted the same message twice")
    except SwiftError as e:
        c.note(f"re-delivery of an already decrypted message rejected by Swift: {e}")

    for i in range(6):
        await b1.send_text(jid("alice"), f"sw{i}")
    got = [await a1.next_message() for _ in range(6)]
    for i in [3, 0, 5, 1, 2, 4]:
        d = await a1.decrypt(got[i])
        assert d["body"] == f"sw{i}", d
    c.note("Swift→python order 3,0,5,1,2,4 decrypted")


async def s12_delayed(c: Ctx) -> None:
    """(a) messages stored offline/MAM while the Swift device is offline, decrypted after an app restart;
    (b) a message held back across several DH ratchet steps."""
    a1 = await c.start(py("alice", "a1"))
    b1 = await c.start(swift("bob", "b1", "Bob iPhone"))
    await a1.send_text(jid("bob"), "online")
    await receive_and_decrypt(b1, "online")
    await b1.refresh(jid("alice"))
    await b1.send_text(jid("alice"), "online ack")
    await receive_and_decrypt(a1, "online ack")
    await drain(b1)

    await b1.stop()
    c.devices.remove(b1)
    for i in range(3):
        await a1.send_text(jid("bob"), f"offline{i}")
    await asyncio.sleep(1)
    b1r = await c.start(swift("bob", "b1", "Bob iPhone"), publish=False)  # same state file = app restart
    for i in range(3):
        d = await receive_and_decrypt(b1r, f"offline{i}")
        assert d["_received"].delayed, "expected a delayed (offline storage) delivery"
    c.note("3 messages stored by ejabberd while offline, delivered with <delay>, decrypted after process restart")

    await a1.send_text(jid("bob"), "late")
    late = await b1r.next_message()
    for round_ in range(3):
        await b1r.send_text(jid("alice"), f"r{round_}")
        await receive_and_decrypt(a1, f"r{round_}")
        await a1.send_text(jid("bob"), f"q{round_}")
        await receive_and_decrypt(b1r, f"q{round_}")
    d = await b1r.decrypt(late)
    assert d["body"] == "late"
    c.note("message held back across 3 DH ratchet rounds decrypted via skipped keys of the old chain")


async def s13_muc(c: Ctx) -> None:
    """Encrypted message in a members-only, non-anonymous MUC (Swift and python members)."""
    a1 = await c.start(py("alice", "a1"))
    b1 = await c.start(swift("bob", "b1", "Bob iPhone"))
    carol = await c.start(py("carol", "c1"))
    room = f"s1-{int(time.time())}@groups.{DOMAIN}"
    muc = a1.plugin["xep_0045"]
    await muc.join_muc_wait(slixmpp.JID(room), "alice", timeout=15)
    form = await muc.get_room_config(slixmpp.JID(room))
    form["type"] = "submit"
    await muc.set_room_config(slixmpp.JID(room), form)
    for u in ("bob", "carol"):
        await muc.set_affiliation(slixmpp.JID(room), "member", jid=slixmpp.JID(jid(u)))
    await b1.plugin["xep_0045"].join_muc_wait(slixmpp.JID(room), "bob", timeout=15)
    await carol.plugin["xep_0045"].join_muc_wait(slixmpp.JID(room), "carol", timeout=15)
    await asyncio.sleep(1)
    info = await a1.plugin["xep_0030"].get_info(jid=slixmpp.JID(room))
    features = set(info["disco_info"]["features"])
    assert {"muc_membersonly", "muc_nonanonymous", "muc_persistent"} <= features, features
    c.note("room disco: muc_membersonly, muc_nonanonymous, muc_persistent")

    for j in ("alice", "carol", "bob"):
        await b1.refresh(jid(j))
    r = await b1.send_text(room, "group secret from swift", mtype="groupchat", recipients=[jid("alice"), jid("carol")])
    for dev in (a1, carol):
        d = await receive_and_decrypt(dev, "group secret from swift")
        assert d["to"] == room, d
    c.note(f"Swift groupchat: keys for {len(r['recipients'])} devices, both python members decrypt, SCE <to/> = room")

    await drain(b1)
    await a1.send_text(room, "group secret from python", mtype="groupchat", recipients=[jid("bob"), jid("carol")])
    d = await receive_and_decrypt(b1, "group secret from python")
    assert d["to"] == room
    await receive_and_decrypt(carol, "group secret from python")
    c.note("python groupchat decrypted by Swift and python members")

    await asyncio.sleep(1)
    out = subprocess.run(["docker", "exec", POSTGRES, "psql", "-U", "ejabberd", "-d", "ejabberd", "-tAc",
                          "select count(*) filter (where xml like '%group secret%'), count(*) "
                          f"from archive where username = '{room}'"],
                         capture_output=True, text=True)
    leaked, total = (int(x) for x in out.stdout.strip().split("|"))
    assert total >= 2 and leaked == 0, out.stdout
    c.note(f"room MAM archive: {total} messages stored, 0 contain plaintext")


SCENARIOS: List[Callable[[Ctx], Awaitable[None]]] = [
    s01_initial_x3dh, s02_prekey_consumption, s03_regular_ratchet, s04_bidirectional,
    s05_multiple_recipient_devices, s06_new_sender_device, s07_removed_device, s08_bundle_refresh,
    s09_stale_prekeys, s10_session_recreation, s11_out_of_order, s12_delayed, s13_muc,
]


async def main() -> int:
    only = sys.argv[1:]
    results = []
    for scenario in SCENARIOS:
        if only and not any(scenario.__name__.startswith(o) for o in only):
            continue
        reset_accounts()
        ctx = Ctx()
        t = time.perf_counter()
        try:
            await asyncio.wait_for(scenario(ctx), 240)
            status, error = "PASS", None
        except Exception as e:
            status, error = "FAIL", f"{type(e).__name__}: {e}"
            traceback.print_exc()
        finally:
            await ctx.stop_all()
        elapsed = time.perf_counter() - t
        results.append({"scenario": scenario.__name__, "doc": (scenario.__doc__ or "").strip(), "status": status,
                        "error": error, "notes": ctx.notes, "seconds": round(elapsed, 1)})
        print(f"{status}  {scenario.__name__}  ({elapsed:.1f}s)" + (f"  — {error}" if error else ""))
        for n in ctx.notes:
            print(f"      · {n}")
    timings = {k: {"n": len(v), "median_ms": round(statistics.median(v) * 1000, 1),
                   "p95_ms": round(sorted(v)[int(len(v) * 0.95) - 1 if len(v) > 1 else 0] * 1000, 1)}
               for k, v in sorted(TIMINGS.items())}
    print(json.dumps(timings, indent=1))
    if os.environ.get("S1_REPORT"):
        with open(os.environ["S1_REPORT"], "w") as f:
            json.dump({"results": results, "timings": timings}, f, indent=1)
    return 0 if all(r["status"] == "PASS" for r in results) else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
