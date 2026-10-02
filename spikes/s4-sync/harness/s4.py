"""S4: MAM + Stream Management + reconnect + deduplication, end-to-end against the dev ejabberd.

The Swift SyncCore engine (sync-cli) owns message identity, dedup, outbox and MAM cursors.
slixmpp (with XEP-0198) plays the transport layer; faults are injected by aborting the TCP connection,
killing the server-side session, restarting the engine process, and re-injecting stanzas.

Run: python s4.py [scenario-prefix …]
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import random
import subprocess
import sys
import time
import traceback
import uuid
import xml.etree.ElementTree as ET
from datetime import datetime
from typing import Any, Dict, List, Optional

import slixmpp
from slixmpp.xmlstream.handler import Callback
from slixmpp.xmlstream.matcher import MatchXPath

DOMAIN = "chat.messenger.test"
HOST = os.environ.get("XMPP_HOST", "127.0.0.1")
CA = os.environ.get("XMPP_CA", "/tmp/claude-0/caddy-root.crt")
SPIKE_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
STATE_DIR = os.environ.get("S4_STATE_DIR", "/tmp/claude-0/s4state")
EJABBERD = os.environ.get("EJABBERD_CONTAINER", "messenger-dev-ejabberd-1")
NS_MAM = "urn:xmpp:mam:2"
NS_SID = "urn:xmpp:sid:0"
NS_DELAY = "urn:xmpp:delay"
NS_RSM = "http://jabber.org/protocol/rsm"

logging.basicConfig(level=logging.ERROR)


def jid(u: str) -> str:
    return f"{u}@{DOMAIN}"


def ctl(*args: str) -> str:
    return subprocess.run(["docker", "exec", EJABBERD, "ejabberdctl", *args], capture_output=True, text=True).stdout


def reset() -> None:
    for u in ("alice", "bob"):
        ctl("unregister", u, DOMAIN)
        ctl("register", u, DOMAIN, f"pw-{u}-s4")
    os.makedirs(STATE_DIR, exist_ok=True)
    for f in os.listdir(STATE_DIR):
        os.remove(os.path.join(STATE_DIR, f))


def parse_stamp(s: str) -> float:
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


class Engine:
    """sync-cli process; the DB file survives restarts."""

    def __init__(self, name: str, own: str):
        self.name, self.own = name, own
        self.proc: Optional[asyncio.subprocess.Process] = None
        self.lock = asyncio.Lock()  # one request at a time, like the app's SyncEngine actor

    async def start(self) -> None:
        self.proc = await asyncio.create_subprocess_exec(
            "docker", "run", "-i", "--rm", "--network", "none", "-v", f"{SPIKE_DIR}:/src:ro", "-v", f"{STATE_DIR}:/state",
            "omemo-swift-dev", "/src/.build/debug/sync-cli", stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE)
        await self.call(cmd="open", path=f"/state/{self.name}.sqlite", ownJid=self.own)

    async def call(self, **req: Any) -> Dict[str, Any]:
        assert self.proc and self.proc.stdin and self.proc.stdout
        async with self.lock:
            self.proc.stdin.write((json.dumps(req) + "\n").encode())
            await self.proc.stdin.drain()
            resp = json.loads(await asyncio.wait_for(self.proc.stdout.readline(), 60))
        if not resp.get("ok"):
            raise RuntimeError(f"engine: {resp.get('error')}")
        return resp

    async def stop(self) -> None:
        if self.proc:
            self.proc.stdin.close()  # type: ignore[union-attr]
            await self.proc.wait()
            self.proc = None


class Client(slixmpp.ClientXMPP):
    """Transport stand-in. Live stanzas are fed into the engine; outgoing messages come from the engine outbox."""

    def __init__(self, user: str, resource: str, engine: Engine):
        super().__init__(f"{jid(user)}/{resource}", f"pw-{user}-s4")
        self.enable_starttls, self.enable_direct_tls, self.enable_plaintext = False, True, False
        self.ca_certs = CA
        for p in ("xep_0030", "xep_0198", "xep_0199", "xep_0280", "xep_0359"):
            self.register_plugin(p)
        self.plugin["xep_0198"].allow_resume = True
        self.engine = engine
        self.ready = asyncio.Event()
        self.resumed = asyncio.Event()
        self.session_kind = ""
        self.log: List[Dict[str, Any]] = []
        self.mam_results: Dict[str, List[ET.Element]] = {}
        self.suppress_ack_requests = False  # fault injection: server receives the stanza, client never gets the ack
        self.ingest_tasks: List[asyncio.Task] = []
        self.add_event_handler("session_start", self._session_start)
        self.add_event_handler("session_resumed", self._session_resumed)
        self.add_event_handler("message", self._message)
        self.add_event_handler("stanza_acked", self._acked)
        self.register_handler(Callback("mam-result", MatchXPath(f"{{jabber:client}}message/{{{NS_MAM}}}result"), self._mam_result))

    # --- session lifecycle
    async def _session_start(self, _: Any) -> None:
        self.session_kind = "new"
        self.send_presence()
        await self.get_roster()
        self.ready.set()

    def _session_resumed(self, _: Any) -> None:
        # Stanzas re-sent from the SM queue need a fresh <r/> to be acked.
        asyncio.get_event_loop().call_later(0.2, self._request_ack)
        self.session_kind = "resumed"
        self.resumed.set()
        self.ready.set()

    async def go_online(self) -> str:
        self.ready.clear()
        self.resumed.clear()
        self.connect(HOST, 5223)
        await asyncio.wait_for(self.ready.wait(), 30)
        return self.session_kind

    def abort(self) -> None:
        """Network loss: the socket dies without a closing </stream> (server hibernates the session)."""
        self.transport.abort()  # type: ignore[union-attr]

    async def wait_disconnected(self) -> None:
        await asyncio.wait_for(self.disconnected, 10)

    async def quit(self) -> None:
        self.plugin["xep_0198"].allow_resume = False
        self.disconnect()
        await asyncio.wait_for(self.disconnected, 10)

    # --- inbound
    def _message(self, msg: slixmpp.Message) -> None:
        if msg.xml.find(f"{{{NS_MAM}}}result") is not None or msg["body"] == "":
            return
        delay = msg.xml.find(f"{{{NS_DELAY}}}delay")
        self.ingest_tasks.append(asyncio.ensure_future(self.ingest(msg.xml, "offline" if delay is not None else "live")))

    async def ingest(self, xml: ET.Element, source: str, stanza_id: Optional[str] = None,
                     stamp: Optional[float] = None) -> Dict[str, Any]:
        own_bare = self.boundjid.bare
        if stanza_id is None:
            for sid in xml.findall(f"{{{NS_SID}}}stanza-id"):
                if sid.get("by") == own_bare:
                    stanza_id = sid.get("id")
        origin = xml.find(f"{{{NS_SID}}}origin-id")
        delay = xml.find(f"{{{NS_DELAY}}}delay")
        if stamp is None and delay is not None:
            stamp = parse_stamp(delay.get("stamp"))
        body = xml.find("{jabber:client}body")
        req = {"cmd": "ingest", "source": source, "archiveJid": own_bare, "stanzaId": stanza_id,
               "originId": None if origin is None else origin.get("id"),
               "from": slixmpp.JID(xml.get("from") or own_bare).bare, "to": slixmpp.JID(xml.get("to") or own_bare).bare,
               "body": None if body is None else body.text}
        if stamp is not None:
            req["serverTime"] = stamp
        r = await self.engine.call(**req)
        self.log.append({"source": source, "body": req["body"], "stanzaId": stanza_id, "action": r["action"]})
        return r

    async def settle(self, seconds: float = 1.0) -> None:
        await asyncio.sleep(seconds)
        if self.ingest_tasks:
            await asyncio.gather(*self.ingest_tasks)
            self.ingest_tasks.clear()

    # --- outbound
    def _acked(self, stanza: Any) -> None:
        if stanza.name == "message" and stanza["id"]:
            asyncio.ensure_future(self.engine.call(cmd="acked", appId=stanza["id"]))

    async def send_logical(self, to: str, body: str) -> str:
        app_id = (await self.engine.call(cmd="createOutgoing", to=to, body=body))["appId"]
        self._send_stanza(to, body, app_id)
        return app_id

    def _send_stanza(self, to: str, body: str, app_id: str) -> None:
        msg = self.make_message(mto=to, mbody=body, mtype="chat")
        msg["id"] = app_id
        msg["origin_id"]["id"] = app_id
        msg.send()
        # Request an ack once the stanza has left the send queue (an <r/> sent immediately can overtake it).
        asyncio.get_event_loop().call_later(0.2, self._request_ack)

    def _request_ack(self) -> None:
        sm = self.plugin["xep_0198"]
        if sm.enabled_out and self.transport is not None and not self.suppress_ack_requests:
            sm.request_ack()

    async def flush_outbox(self) -> int:
        pending = (await self.engine.call(cmd="outbox"))["pending"]
        for p in pending:
            self._send_stanza(p["to"], p["body"], p["appId"])
        return len(pending)

    # --- MAM catch-up from the persisted cursor
    def _mam_result(self, msg: slixmpp.Message) -> None:
        res = msg.xml.find(f"{{{NS_MAM}}}result")
        self.mam_results.setdefault(res.get("queryid"), []).append(res)

    async def mam_catch_up(self, page: int = 20, order: Optional[List[int]] = None) -> Dict[str, int]:
        archive = self.boundjid.bare
        stats = {"pages": 0, "results": 0}
        while True:
            cursor = (await self.engine.call(cmd="cursor", archive=archive))["stanzaId"]
            qid = uuid.uuid4().hex
            iq = self.make_iq_set()
            query = ET.SubElement(iq.xml, f"{{{NS_MAM}}}query", queryid=qid)
            rsm = ET.SubElement(query, f"{{{NS_RSM}}}set")
            ET.SubElement(rsm, f"{{{NS_RSM}}}max").text = str(page)
            if cursor:
                ET.SubElement(rsm, f"{{{NS_RSM}}}after").text = cursor
            result = await iq.send(timeout=20)
            fin = result.xml.find(f"{{{NS_MAM}}}fin")
            items = self.mam_results.pop(qid, [])
            stats["pages"] += 1
            stats["results"] += len(items)
            seq = list(range(len(items)))
            if order == "shuffle":  # type: ignore[comparison-overlap]
                random.Random(7).shuffle(seq)
            for i in seq:
                res = items[i]
                fwd = res.find("{urn:xmpp:forward:0}forwarded")
                inner = fwd.find("{jabber:client}message")
                stamp = parse_stamp(fwd.find(f"{{{NS_DELAY}}}delay").get("stamp"))
                await self.ingest(inner, "mam", stanza_id=res.get("id"), stamp=stamp)
            last = fin.find(f"{{{NS_RSM}}}set/{{{NS_RSM}}}last")
            if last is not None and last.text:
                await self.engine.call(cmd="setCursor", archive=archive, stanzaId=last.text)  # after the page is committed
            if fin.get("complete") == "true" or not items:
                return stats


# ---------------------------------------------------------------------------------------- helpers

class Ctx:
    def __init__(self) -> None:
        self.notes: List[str] = []
        self.clients: List[Client] = []
        self.engines: List[Engine] = []

    async def device(self, user: str, resource: str, engine_name: Optional[str] = None) -> Client:
        e = Engine(engine_name or f"{user}-{resource}", jid(user))
        await e.start()
        self.engines.append(e)
        c = Client(user, resource, e)
        self.clients.append(c)
        await c.go_online()
        return c

    async def close(self) -> None:
        for c in self.clients:
            try:
                await c.quit()
            except Exception:
                pass
        for e in self.engines:
            await e.stop()

    def note(self, s: str) -> None:
        self.notes.append(s)


async def assert_exactly_once(c: Ctx, receiver: Client, peer: str, expected: List[str], ordered: bool = True) -> Dict[str, Any]:
    rows = (await receiver.engine.call(cmd="messages", peer=peer))["messages"]
    bodies = [r["body"] for r in rows if r["sender"] == peer]
    stats = await receiver.engine.call(cmd="stats")
    assert stats["duplicates"] == [], f"duplicate visible messages: {stats['duplicates']}"
    assert sorted(bodies) == sorted(expected), f"expected {expected}, got {bodies}"
    if ordered:
        assert bodies == expected, f"order: expected {expected}, got {bodies}"
    assert stats["decryptCalls"] == stats["actions"].get("inserted", 0), stats  # decrypt only for new logical messages
    c.note(f"{receiver.boundjid.bare}: {len(bodies)} visible, decrypt calls {stats['decryptCalls']}, actions {stats['actions']}")
    return stats


async def archived_copies(client: Client, body_prefix: str) -> int:
    """Counts copies in the receiver's server archive (MAM) whose body starts with the prefix."""
    qid = uuid.uuid4().hex
    iq = client.make_iq_set()
    query = ET.SubElement(iq.xml, f"{{{NS_MAM}}}query", queryid=qid)
    rsm = ET.SubElement(query, f"{{{NS_RSM}}}set")
    ET.SubElement(rsm, f"{{{NS_RSM}}}max").text = "200"
    await iq.send(timeout=20)
    items = client.mam_results.pop(qid, [])
    n = 0
    for res in items:
        body = res.find("{urn:xmpp:forward:0}forwarded/{jabber:client}message/{jabber:client}body")
        if body is not None and (body.text or "").startswith(body_prefix):
            n += 1
    return n


# --------------------------------------------------------------------------------------- scenarios

async def t01_normal_delivery(c: Ctx) -> None:
    """Normal live delivery + MAM identity check (MAM result id == live stanza-id)."""
    a = await c.device("alice", "a1")
    b = await c.device("bob", "b1")
    for i in range(5):
        await a.send_logical(jid("bob"), f"n{i}")
    await b.settle(2)
    live_ids = {e["body"]: e["stanzaId"] for e in b.log if e["source"] == "live"}
    await b.mam_catch_up()
    mam_ids = {e["body"]: e["stanzaId"] for e in b.log if e["source"] == "mam"}
    assert live_ids == mam_ids, (live_ids, mam_ids)
    c.note("MAM <result id> equals the live <stanza-id by=bob> for all 5 messages")
    await assert_exactly_once(c, b, jid("alice"), [f"n{i}" for i in range(5)])


async def t02_drop_before_ack(c: Ctx) -> None:
    """Sender loses the connection right after sending, before the server ack; (a) resume, (b) failed resume + outbox resend."""
    a = await c.device("alice", "a1")
    b = await c.device("bob", "b1")
    a.suppress_ack_requests = True
    await a.send_logical(jid("bob"), "before-ack-a")
    await asyncio.sleep(0.8)  # stanza reaches the server; no ack is requested
    assert (await a.engine.call(cmd="outbox"))["pending"], "message unexpectedly acked"
    a.abort()
    await a.wait_disconnected()
    a.suppress_ack_requests = False
    kind = await a.go_online()
    await asyncio.sleep(1)
    pending = (await a.engine.call(cmd="outbox"))["pending"]
    c.note(f"(a) sender reconnect: session {kind}; <resumed h> acknowledged the in-flight message; outbox pending {len(pending)}")
    assert kind == "resumed" and not pending

    a.suppress_ack_requests = True
    await a.send_logical(jid("bob"), "before-ack-b")
    await asyncio.sleep(0.8)
    a.abort()
    await a.wait_disconnected()
    ctl("kick_user", "alice", DOMAIN)  # server forgets the hibernated session → resume must fail
    await asyncio.sleep(1)
    a.suppress_ack_requests = False
    kind = await a.go_online()
    resent = await a.flush_outbox()
    c.note(f"(b) sender reconnect: session {kind}; outbox re-sent {resent} message(s) with the same app id/origin-id")
    assert kind == "new" and resent == 1
    await b.settle(2)
    await b.mam_catch_up()
    copies = await archived_copies(b, "before-ack-b")
    c.note(f"(b) server archive holds {copies} copies of 'before-ack-b' (different stanza-ids, same origin-id)")
    assert copies == 2, copies
    await assert_exactly_once(c, b, jid("alice"), ["before-ack-a", "before-ack-b"])


async def t03_drop_after_send(c: Ctx) -> None:
    """Connection drops after the server acked: nothing is re-sent, message appears once."""
    a = await c.device("alice", "a1")
    b = await c.device("bob", "b1")
    await a.send_logical(jid("bob"), "after-ack")
    a.plugin["xep_0198"].request_ack()
    await asyncio.sleep(1)
    assert not (await a.engine.call(cmd="outbox"))["pending"]
    a.abort()
    await a.wait_disconnected()
    ctl("kick_user", "alice", DOMAIN)
    await a.go_online()
    assert await a.flush_outbox() == 0
    await b.settle(1)
    await b.mam_catch_up()
    await assert_exactly_once(c, b, jid("alice"), ["after-ack"])


async def t04_sm_resume(c: Ctx) -> None:
    """Receiver loses the socket; messages queued in the hibernated session are replayed on resume."""
    a = await c.device("alice", "a1")
    b = await c.device("bob", "b1")
    await a.send_logical(jid("bob"), "r0")
    await b.settle(1)
    b.abort()
    await b.wait_disconnected()
    for i in range(1, 4):
        await a.send_logical(jid("bob"), f"r{i}")
    await asyncio.sleep(1)
    kind = await b.go_online()
    assert kind == "resumed", kind
    await b.settle(2)
    await b.mam_catch_up()
    c.note("receiver resumed; queued stanzas replayed; MAM catch-up afterwards added nothing")
    await assert_exactly_once(c, b, jid("alice"), ["r0", "r1", "r2", "r3"])


async def t05_failed_resume(c: Ctx) -> None:
    """Receiver's hibernated session is killed: resume fails, unacked stanzas come back via offline storage and MAM."""
    a = await c.device("alice", "a1")
    b = await c.device("bob", "b1")
    await a.send_logical(jid("bob"), "f0")
    await b.settle(1)
    b.abort()
    await b.wait_disconnected()
    for i in range(1, 4):
        await a.send_logical(jid("bob"), f"f{i}")
    await asyncio.sleep(1)
    ctl("kick_user", "bob", DOMAIN)
    await asyncio.sleep(1)
    kind = await b.go_online()
    assert kind == "new", kind
    await b.settle(2)
    offline = sum(1 for e in b.log if e["source"] == "offline")
    await b.mam_catch_up()
    dup = sum(1 for e in b.log if e["action"] in ("duplicateServerId", "mergedByOriginId"))
    c.note(f"resume failed → new session; {offline} offline deliveries; {dup} duplicate copies absorbed")
    await assert_exactly_once(c, b, jid("alice"), ["f0", "f1", "f2", "f3"])


async def t06_mam_catch_up(c: Ctx) -> None:
    """Receiver offline (no session); 25 messages; reconnect: offline delivery + paged MAM catch-up from the cursor."""
    a = await c.device("alice", "a1")
    b = await c.device("bob", "b1")
    await a.send_logical(jid("bob"), "c00")
    await b.settle(1)
    await b.mam_catch_up()
    await b.quit()
    expected = ["c00"] + [f"c{i:02d}" for i in range(1, 26)]
    for body in expected[1:]:
        await a.send_logical(jid("bob"), body)
    await asyncio.sleep(1)
    b.plugin["xep_0198"].allow_resume = True
    kind = await b.go_online()
    await b.settle(2)
    stats = await b.mam_catch_up(page=10)
    c.note(f"session {kind}; MAM catch-up: {stats['pages']} pages, {stats['results']} results after the cursor")
    await assert_exactly_once(c, b, jid("alice"), expected)


async def t07_app_restart(c: Ctx) -> None:
    """Engine process + XMPP session restarted (DB persisted); catch-up continues from the persisted cursor."""
    a = await c.device("alice", "a1")
    b = await c.device("bob", "b1")
    for i in range(3):
        await a.send_logical(jid("bob"), f"pre{i}")
    await b.settle(1)
    await b.mam_catch_up()
    await b.quit()
    await b.engine.stop()
    for i in range(3):
        await a.send_logical(jid("bob"), f"post{i}")
    await asyncio.sleep(1)
    e2 = Engine("bob-b1", jid("bob"))
    await e2.start()
    c.engines.append(e2)
    b2 = Client("bob", "b1", e2)
    c.clients.append(b2)
    await b2.go_online()
    await b2.settle(2)
    stats = await b2.mam_catch_up()
    c.note(f"after restart: MAM returned {stats['results']} results after the persisted cursor")
    await assert_exactly_once(c, b2, jid("alice"), [f"pre{i}" for i in range(3)] + [f"post{i}" for i in range(3)])


async def t08_wifi_interruption(c: Ctx) -> None:
    """Short outage mid-burst (Wi-Fi-like): 20 messages, receiver drops for ~2 s and resumes."""
    a = await c.device("alice", "a1")
    b = await c.device("bob", "b1")
    expected = [f"w{i:02d}" for i in range(20)]

    async def sender() -> None:
        for body in expected:
            await a.send_logical(jid("bob"), body)
            await asyncio.sleep(0.15)

    task = asyncio.ensure_future(sender())
    await asyncio.sleep(0.8)
    b.abort()
    await b.wait_disconnected()
    await asyncio.sleep(2)
    kind = await b.go_online()
    await task
    await b.settle(2)
    await b.mam_catch_up()
    c.note(f"receiver session after outage: {kind}")
    await assert_exactly_once(c, b, jid("alice"), expected)


async def t09_cellular_reconnect(c: Ctx) -> None:
    """Both sides drop (network switch), 8 s gap, new TCP connections; resume on both."""
    a = await c.device("alice", "a1")
    b = await c.device("bob", "b1")
    await a.send_logical(jid("bob"), "cell0")
    await b.settle(1)
    b.abort()
    await b.wait_disconnected()
    await a.send_logical(jid("bob"), "cell1")
    a.abort()
    await a.wait_disconnected()
    await asyncio.sleep(8)
    ka = await a.go_online()
    await a.send_logical(jid("bob"), "cell2")
    kb = await b.go_online()
    await b.settle(2)
    await b.mam_catch_up()
    c.note(f"sender session {ka}, receiver session {kb} after 8 s on new TCP connections")
    await assert_exactly_once(c, b, jid("alice"), ["cell0", "cell1", "cell2"])


async def t10_duplicate_stanza(c: Ctx) -> None:
    """The same received stanza is delivered to the engine 3 more times (live re-delivery + carbon-like copy)."""
    a = await c.device("alice", "a1")
    b = await c.device("bob", "b1")
    await a.send_logical(jid("bob"), "dup")
    await b.settle(1)
    first = b.log[-1]
    raw = next(e for e in b.log if e["body"] == "dup")
    for _ in range(3):
        msg = ET.Element("{jabber:client}message", {"from": f"{jid('alice')}/a1", "to": jid("bob"), "type": "chat"})
        ET.SubElement(msg, "{jabber:client}body").text = "dup"
        ET.SubElement(msg, f"{{{NS_SID}}}stanza-id", {"by": jid("bob"), "id": raw["stanzaId"]})
        await b.ingest(msg, "injected")
    c.note(f"first ingest: {first['action']}; 3 injected copies → {[e['action'] for e in b.log[-3:]]}")
    await assert_exactly_once(c, b, jid("alice"), ["dup"])


async def t11_live_and_mam(c: Ctx) -> None:
    """Every message arrives live and again through MAM."""
    a = await c.device("alice", "a1")
    b = await c.device("bob", "b1")
    expected = [f"lm{i}" for i in range(8)]
    for body in expected:
        await a.send_logical(jid("bob"), body)
    await b.settle(2)
    stats = await b.mam_catch_up()
    mam_dups = sum(1 for e in b.log if e["source"] == "mam" and e["action"] == "duplicateServerId")
    c.note(f"MAM returned {stats['results']} results, {mam_dups} recognised as already-ingested copies")
    assert mam_dups == len(expected)
    await assert_exactly_once(c, b, jid("alice"), expected)


async def t12_out_of_order(c: Ctx) -> None:
    """MAM results ingested in shuffled order, interleaved with live traffic; display order = server time."""
    a = await c.device("alice", "a1")
    b = await c.device("bob", "b1")
    await b.quit()
    expected = [f"o{i}" for i in range(10)]
    for body in expected:
        await a.send_logical(jid("bob"), body)
        await asyncio.sleep(0.05)
    b.plugin["xep_0198"].allow_resume = True
    # Ingest MAM first, shuffled, before offline delivery is processed.
    await b.go_online()
    await b.mam_catch_up(order="shuffle")  # type: ignore[arg-type]
    await a.send_logical(jid("bob"), "o10")
    expected.append("o10")
    await b.settle(2)
    c.note("10 MAM results ingested in shuffled order + offline copies + 1 live message")
    await assert_exactly_once(c, b, jid("alice"), expected, ordered=True)


async def t13_delayed(c: Ctx) -> None:
    """Offline (<delay>) messages are ordered by server time, before later live messages."""
    a = await c.device("alice", "a1")
    b = await c.device("bob", "b1")
    await b.quit()
    await a.send_logical(jid("bob"), "d0")
    await asyncio.sleep(1.2)
    await a.send_logical(jid("bob"), "d1")
    await asyncio.sleep(1.2)
    b.plugin["xep_0198"].allow_resume = True
    await b.go_online()
    await a.send_logical(jid("bob"), "d2-live")
    await b.settle(2)
    delayed = [e for e in b.log if e["source"] == "offline"]
    rows = (await b.engine.call(cmd="messages", peer=jid("alice")))["messages"]
    gap = rows[1]["sortKey"] - rows[0]["sortKey"]
    c.note(f"{len(delayed)} delayed deliveries; sort keys from <delay> (gap d0→d1 {gap:.2f} s, sender gap 1.2 s)")
    assert 1.0 < gap < 1.6, gap
    await assert_exactly_once(c, b, jid("alice"), ["d0", "d1", "d2-live"])


async def t14_own_messages(c: Ctx) -> None:
    """Sender's own messages returned by its own MAM / carbons merge into the outgoing rows (no own duplicates)."""
    a = await c.device("alice", "a1")
    a2 = await c.device("alice", "a2")
    b = await c.device("bob", "b1")
    await a.plugin["xep_0280"].enable()
    await a2.plugin["xep_0280"].enable()
    for i in range(3):
        await a.send_logical(jid("bob"), f"own{i}")
    await asyncio.sleep(1)
    await a.mam_catch_up()
    rows = (await a.engine.call(cmd="messages", peer=jid("bob")))["messages"]
    assert [r["body"] for r in rows] == ["own0", "own1", "own2"] and all(r["status"] >= 1 for r in rows), rows
    merged = sum(1 for e in a.log if e["action"] == "mergedByOriginId")
    c.note(f"sender: MAM copies of own messages merged into outgoing rows ({merged} merges), status sent")
    await a2.settle(1)
    await a2.mam_catch_up()
    rows2 = (await a2.engine.call(cmd="messages", peer=jid("bob")))["messages"]
    assert [r["body"] for r in rows2] == ["own0", "own1", "own2"], rows2
    c.note("second own device: own messages visible exactly once (carbons + MAM)")
    await b.settle(1)
    await assert_exactly_once(c, b, jid("alice"), ["own0", "own1", "own2"])


SCENARIOS = [t01_normal_delivery, t02_drop_before_ack, t03_drop_after_send, t04_sm_resume, t05_failed_resume,
             t06_mam_catch_up, t07_app_restart, t08_wifi_interruption, t09_cellular_reconnect, t10_duplicate_stanza,
             t11_live_and_mam, t12_out_of_order, t13_delayed, t14_own_messages]


async def main() -> int:
    only = sys.argv[1:]
    results = []
    for s in SCENARIOS:
        if only and not any(s.__name__.startswith(o) for o in only):
            continue
        reset()
        ctx = Ctx()
        t = time.perf_counter()
        try:
            await asyncio.wait_for(s(ctx), 180)
            status, err = "PASS", None
        except Exception as e:
            status, err = "FAIL", f"{type(e).__name__}: {e}"
            traceback.print_exc()
        finally:
            await ctx.close()
        dt = time.perf_counter() - t
        results.append({"scenario": s.__name__, "doc": (s.__doc__ or "").strip(), "status": status, "error": err,
                        "notes": ctx.notes, "seconds": round(dt, 1)})
        print(f"{status}  {s.__name__}  ({dt:.1f}s)" + (f"  — {err}" if err else ""))
        for n in ctx.notes:
            print(f"      · {n}")
    if os.environ.get("S4_REPORT"):
        with open(os.environ["S4_REPORT"], "w") as f:
            json.dump(results, f, indent=1)
    return 0 if all(r["status"] == "PASS" for r in results) else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
