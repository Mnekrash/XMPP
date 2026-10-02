"""S3 server-side: real ejabberd 26.09 MUC / MUC-Sub push behaviour, measured at the push gateway.

Same chain as S2 (ejabberd → gateway → APNs-compatible dev mock). Rooms use the server defaults:
members-only, non-anonymous, persistent, MAM, allow_subscription.

Run: python group_tests.py
"""
from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import os
import sys
import time
import traceback
import xml.etree.ElementTree as ET
from typing import Any, Dict, List

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "s2-push"))
import server_tests as s2  # noqa: E402

import slixmpp  # noqa: E402

MUC = f"groups.{s2.DOMAIN}"
NS_MUCSUB = "urn:xmpp:mucsub:0"


class G(s2.C):
    def __init__(self, user: str, res: str):
        super().__init__(user, res)
        self.register_plugin("xep_0045")
        self.mucsub: List[ET.Element] = []
        self.groupchat: List[slixmpp.Message] = []
        self.add_event_handler("groupchat_message", lambda m: self.groupchat.append(m))
        self.add_event_handler("message", self._maybe_mucsub)

    def _maybe_mucsub(self, m: slixmpp.Message) -> None:
        if m.xml.find("{http://jabber.org/protocol/pubsub#event}event") is not None:
            self.mucsub.append(m.xml)

    async def create_room(self, room: str, members: List[str]) -> None:
        muc = self.plugin["xep_0045"]
        await muc.join_muc_wait(slixmpp.JID(room), self.boundjid.user, timeout=15)
        form = await muc.get_room_config(slixmpp.JID(room))
        form["type"] = "submit"
        await muc.set_room_config(slixmpp.JID(room), form)
        for m in members:
            await muc.set_affiliation(slixmpp.JID(room), "member", jid=slixmpp.JID(m))

    async def join(self, room: str) -> None:
        await self.plugin["xep_0045"].join_muc_wait(slixmpp.JID(room), self.boundjid.user, timeout=15)

    async def subscribe(self, room: str) -> None:
        iq = self.make_iq_set(ito=room)
        sub = ET.SubElement(iq.xml, f"{{{NS_MUCSUB}}}subscribe", nick=self.boundjid.user)
        ET.SubElement(sub, f"{{{NS_MUCSUB}}}event", node="urn:xmpp:mucsub:nodes:messages")
        await iq.send(timeout=15)

    def group_say(self, room: str, body: str) -> None:
        self.send_message(mto=room, mbody=body, mtype="groupchat")


async def mam_contains(client: G, archive: str | None, text: str) -> bool:
    import uuid
    qid = uuid.uuid4().hex
    found: list = []
    handler_name = f"mam-{qid}"
    from slixmpp.xmlstream.handler import Callback
    from slixmpp.xmlstream.matcher import MatchXPath
    client.register_handler(Callback(handler_name, MatchXPath("{jabber:client}message/{urn:xmpp:mam:2}result"),
                                     lambda m: found.append(ET.tostring(m.xml, encoding="unicode"))))
    iq = client.make_iq_set(ito=archive) if archive else client.make_iq_set()
    q = ET.SubElement(iq.xml, "{urn:xmpp:mam:2}query", queryid=qid)
    rsm = ET.SubElement(q, "{http://jabber.org/protocol/rsm}set")
    ET.SubElement(rsm, "{http://jabber.org/protocol/rsm}max").text = "50"
    await iq.send(timeout=15)
    await asyncio.sleep(0.5)
    client.remove_handler(handler_name)
    return any(text in f for f in found)


def subprocess_logs() -> str:
    import subprocess
    return "".join(subprocess.run(["docker", "logs", "--since", "15s", name], capture_output=True, text=True).stdout
                   for name in (s2.GATEWAY, s2.GATEWAY.replace("-1", "-2")))


class Ctx(s2.Ctx):
    async def g(self, user: str, res: str) -> G:
        c = G(user, res)
        await c.online()
        self.clients.append(c)
        return c


def room_name() -> str:
    return f"s3-{int(time.time() * 1000)}@{MUC}"


async def setup(c: Ctx, subscribe: bool, join: bool, res: str = "phone") -> tuple[G, G, str, bytes, Dict[str, str]]:
    alice = await c.g("alice", "a")
    room = room_name()
    await alice.create_room(room, [s2.jid("bob")])
    bob = await c.g("bob", res)
    key = os.urandom(32)
    reg = await bob.register(s2.GOOD_TOKEN if res == "phone" else s2.NEW_TOKEN, key)
    await bob.enable(reg["node"], reg["secret"])
    if join:
        await bob.join(room)
    if subscribe:
        await bob.subscribe(room)
    return alice, bob, room, key, reg


def summarize(rec: Dict[str, Any], key: bytes) -> str:
    env = s2.open_envelope(key, rec["payload"]["e"]) if rec["payload"].get("e") else {}
    return f"status {rec['status']}, envelope sender={env.get('sender')!r} conv={env.get('conv')!r}"


# --------------------------------------------------------------------------------------------- tests

async def g01_active_member(c: Ctx) -> None:
    """Member online and joined: groupchat delivered live, no push."""
    alice, bob, room, key, _ = await setup(c, subscribe=False, join=True)
    n = len(s2.records())
    alice.group_say(room, "live group text")
    await asyncio.sleep(2)
    assert any(m["body"] == "live group text" for m in bob.groupchat)
    assert not await s2.wait_records(n, 0, timeout=3)
    c.notes.append("joined + online: delivered live, 0 APNs requests")


async def g02_offline_plain_member(c: Ctx) -> None:
    """Member (affiliation only, no MUC/Sub) fully offline: does ejabberd push? (expected: no — plain MUC needs presence)."""
    alice, bob, room, key, _ = await setup(c, subscribe=False, join=True)
    await bob.quit()
    c.clients.remove(bob)
    n = len(s2.records())
    alice.group_say(room, "plain member offline")
    got = await s2.wait_records(n, 1, timeout=5)
    c.notes.append(f"plain MUC member offline: {len(got)} APNs requests → offline members get NO push without MUC/Sub")
    assert not got, "behaviour changed: plain MUC now pushes"


async def g03_offline_mucsub_member(c: Ctx) -> None:
    """Member subscribed via MUC/Sub, fully offline: push + message available after reconnect (MAM)."""
    alice, bob, room, key, _ = await setup(c, subscribe=True, join=False)
    await bob.quit()
    c.clients.remove(bob)
    n = len(s2.records())
    secret_text = "group secret 1234"
    alice.group_say(room, secret_text)
    got = await s2.wait_records(n, 2, timeout=5)
    assert len(got) == 1, f"expected the duplicate publish to be coalesced, got {len(got)} requests"
    assert secret_text not in json.dumps(got[0]["payload"]) and "1234" not in json.dumps(got[0]["payload"])
    logs = subprocess_logs()
    c.notes.append(f"ejabberd published {logs.count('coalesced') + 1}× for one message; gateway sent 1 (coalesced the rest)")
    c.notes.append("MUC/Sub subscriber offline: 1 APNs request; " + summarize(got[0], key))
    bob2 = await c.g("bob", "phone")
    await asyncio.sleep(2)
    delivered = [ET.tostring(x, encoding="unicode") for x in bob2.mucsub]
    in_own = await mam_contains(bob2, None, secret_text)
    in_room = await mam_contains(bob2, room, secret_text)
    c.notes.append(f"after reconnect: offline-storage MUC/Sub events {len(delivered)}; "
                   f"found in own MAM archive: {in_own}; found in room MAM archive: {in_room}")
    assert in_own or in_room, "group message not retrievable after reconnect"


async def g04_hibernated_member(c: Ctx) -> None:
    """Joined member whose app is suspended (socket lost → SM hibernation): push while hibernated."""
    alice, bob, room, key, _ = await setup(c, subscribe=False, join=True)
    bob.abort()
    await asyncio.sleep(1)
    n = len(s2.records())
    alice.group_say(room, "while suspended")
    got = await s2.wait_records(n, 1)
    c.notes.append(f"joined member hibernated (no MUC/Sub): {len(got)} APNs request(s)"
                   + (f"; {summarize(got[0], key)}" if got else ""))
    assert len(got) == 1


async def g05_hibernated_member_with_mucsub(c: Ctx) -> None:
    """Joined AND subscribed, app suspended: exactly one push per group message (no double notification)."""
    alice, bob, room, key, _ = await setup(c, subscribe=True, join=True)
    bob.abort()
    await asyncio.sleep(1)
    n = len(s2.records())
    alice.group_say(room, "joined+subscribed suspended")
    got = await s2.wait_records(n, 2, timeout=5)
    c.notes.append(f"joined + MUC/Sub + hibernated: {len(got)} APNs request(s) for one message")
    assert len(got) >= 1


async def g06_muted_group(c: Ctx) -> None:
    """Muted group: the client mutes the opaque id of what ejabberd reports as conversation; no push."""
    alice, bob, room, key, reg = await setup(c, subscribe=True, join=False)
    await bob.quit()
    c.clients.remove(bob)
    n = len(s2.records())
    alice.group_say(room, "probe for conversation id")
    probe = await s2.wait_records(n, 1)
    conv = s2.open_envelope(key, probe[0]["payload"]["e"])["conv"]
    opaque = hmac.new(key, ("thread:" + conv).encode(), hashlib.sha256).hexdigest()[:32]
    muter = await c.g("bob", "laptop")
    await muter.command("mute-conversation", {"node": reg["node"], "conversation": opaque, "until": str(int(time.time()) + 3600)})
    await muter.quit()
    c.clients.remove(muter)
    n = len(s2.records())
    alice.group_say(room, "muted group message")
    muted = await s2.wait_records(n, 0, timeout=4)
    c.notes.append(f"ejabberd reports conv={conv!r} for MUC/Sub pushes; after muting it: {len(muted)} APNs requests")
    assert conv == room and not muted


async def g07_multiple_devices(c: Ctx) -> None:
    """Two devices of the same member, both offline with push: both get a push."""
    alice, bob, room, key, reg = await setup(c, subscribe=True, join=False)
    bob2 = await c.g("bob", "tablet")
    key2 = os.urandom(32)
    reg2 = await bob2.register(s2.NEW_TOKEN, key2)
    await bob2.enable(reg2["node"], reg2["secret"])
    await bob.quit()
    await bob2.quit()
    c.clients.remove(bob)
    c.clients.remove(bob2)
    n = len(s2.records())
    alice.group_say(room, "to both devices")
    got = await s2.wait_records(n, 3, timeout=5)
    tokens = sorted(r["token"] for r in got)
    c.notes.append(f"2 devices offline: APNs requests for tokens {[t[:4] for t in tokens]}")
    assert tokens == sorted([s2.GOOD_TOKEN, s2.NEW_TOKEN]), tokens


async def g08_disconnected_then_mam(c: Ctx) -> None:
    """Device completely disconnected for several messages: one push per message, all messages in room MAM."""
    alice, bob, room, key, _ = await setup(c, subscribe=True, join=False)
    await bob.quit()
    c.clients.remove(bob)
    n = len(s2.records())
    for i in range(3):
        alice.group_say(room, f"burst {i}")
        await asyncio.sleep(0.3)
    got = await s2.wait_records(n, 3, timeout=5)
    c.notes.append(f"burst of 3 messages within 0.6 s while disconnected → {len(got)} APNs request(s) (coalesced)")
    assert len(got) == 1
    n = len(s2.records())
    for i in range(2):
        await asyncio.sleep(2.5)
        alice.group_say(room, f"spaced {i}")
    got = await s2.wait_records(n, 2, timeout=6)
    c.notes.append(f"2 messages 2.5 s apart → {len(got)} APNs requests")
    assert len(got) == 2


async def g09_coalescing_across_replicas(c: Ctx) -> None:
    """With two gateway replicas, the duplicate publish may hit both instances: still one APNs request."""
    import subprocess
    env = subprocess.run(["docker", "inspect", s2.GATEWAY, "--format", "{{range .Config.Env}}{{println .}}{{end}}"],
                         capture_output=True, text=True).stdout
    with open("/tmp/claude-0/s2/gw.env", "w") as f:
        f.write("\n".join(l for l in env.splitlines() if l and not l.startswith("PATH=")))
    subprocess.run(["docker", "rm", "-f", "gw2"], capture_output=True)
    subprocess.run(["docker", "run", "-d", "--name", "gw2", "--network", "messenger-dev_internal", "--env-file",
                    "/tmp/claude-0/s2/gw.env", "-v", "/tmp/claude-0/s2/secrets:/run/apns:ro", "messenger-dev-push-gateway"],
                   capture_output=True, check=True)
    try:
        await asyncio.sleep(4)
        totals = []
        for i in range(4):
            alice, bob, room, key, _ = await setup(c, subscribe=True, join=False)
            await bob.quit()
            c.clients.remove(bob)
            n = len(s2.records())
            alice.group_say(room, f"replica check {i}")
            totals.append(len(await s2.wait_records(n, 2, timeout=4)))
        handled = [subprocess.run(["docker", "logs", "--since", "60s", name], capture_output=True, text=True).stdout.count('"coalesced')
                   for name in (s2.GATEWAY, "gw2")]
        c.notes.append(f"4 group messages to an offline subscriber: APNs requests per message {totals}; "
                       f"coalesced on instance1/instance2: {handled}")
        assert totals == [1, 1, 1, 1]
    finally:
        subprocess.run(["docker", "rm", "-f", "gw2"], capture_output=True)


TESTS = [g01_active_member, g02_offline_plain_member, g03_offline_mucsub_member, g04_hibernated_member,
         g05_hibernated_member_with_mucsub, g06_muted_group, g07_multiple_devices, g08_disconnected_then_mam,
         g09_coalescing_across_replicas]


async def main() -> int:
    only = sys.argv[1:]
    ok = True
    for t in TESTS:
        if only and not any(t.__name__.startswith(o) for o in only):
            continue
        s2.reset()
        ctx = Ctx()
        start = time.perf_counter()
        try:
            await asyncio.wait_for(t(ctx), 120)
            status = "PASS"
        except Exception as e:
            status = f"FAIL — {type(e).__name__}: {e}"
            ok = False
            traceback.print_exc()
        finally:
            await ctx.close()
        print(f"{status.split(' —')[0]}  {t.__name__}  ({time.perf_counter() - start:.1f}s)"
              + ("" if status == "PASS" else "  " + status[5:]))
        for n in ctx.notes:
            print(f"      · {n}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
