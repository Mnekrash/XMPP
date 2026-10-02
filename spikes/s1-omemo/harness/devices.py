"""Device wrappers for the S1 OMEMO 2 interop harness.

PyDevice   — independent OMEMO 2 implementation: python-omemo 2.1.0 + python-twomemo 2.1.0 (Syndace),
             driven through slixmpp-omemo 2.2.0's session manager (PEP bundles/device lists).
             slixmpp-omemo has no SCE support for urn:xmpp:omemo:2, so the harness wraps/unwraps the SCE
             envelope itself (plain XML, no cryptography).
SwiftDevice — our Swift OMEMOKit prototype (omemo-cli, JSON-lines RPC in a container). The harness owns its
             XMPP connection and PEP publishing; all crypto, X3DH, ratchet and <encrypted> serialization
             happen in Swift.

Both connect to the real ejabberd over direct TLS with CA validation.
"""
from __future__ import annotations

import asyncio
import base64
import json
import os
import secrets
import time
import xml.etree.ElementTree as ET
from typing import Any, Dict, FrozenSet, List, Optional

import omemo
import slixmpp
import twomemo
import twomemo.etree
from omemo.storage import Just, Maybe, Nothing, Storage
from omemo.types import DeviceInformation, JSONType
from slixmpp.plugins import register_plugin
from slixmpp_omemo import TrustLevel, XEP_0384
from slixmpp_omemo.xep_0384 import _publish_item_and_configure_node

NS_OMEMO = "urn:xmpp:omemo:2"
NS_SCE = "urn:xmpp:sce:1"
DEVICES_NODE = "urn:xmpp:omemo:2:devices"
BUNDLES_NODE = "urn:xmpp:omemo:2:bundles"
HOST = os.environ.get("XMPP_HOST", "127.0.0.1")
PORT = int(os.environ.get("XMPP_PORT", "5223"))
CA = os.environ.get("XMPP_CA", "/tmp/claude-0/caddy-root.crt")

TIMINGS: Dict[str, List[float]] = {}


def timed(label: str, seconds: float) -> None:
    TIMINGS.setdefault(label, []).append(seconds)


# --------------------------------------------------------------------------------------------- SCE

def build_sce(body: str, from_jid: str, to_jid: Optional[str] = None) -> bytes:
    env = ET.Element(f"{{{NS_SCE}}}envelope")
    content = ET.SubElement(env, f"{{{NS_SCE}}}content")
    ET.SubElement(content, "{jabber:client}body").text = body
    ET.SubElement(env, f"{{{NS_SCE}}}rpad").text = base64.b64encode(secrets.token_bytes(secrets.randbelow(150))).decode()
    ET.SubElement(env, f"{{{NS_SCE}}}from", jid=from_jid)
    if to_jid:
        ET.SubElement(env, f"{{{NS_SCE}}}to", jid=to_jid)
    return ET.tostring(env)


def parse_sce(data: bytes) -> Dict[str, Optional[str]]:
    env = ET.fromstring(data)
    body = env.find(f"{{{NS_SCE}}}content/{{jabber:client}}body")
    frm = env.find(f"{{{NS_SCE}}}from")
    to = env.find(f"{{{NS_SCE}}}to")
    return {"body": None if body is None else body.text, "from": None if frm is None else frm.get("jid"),
            "to": None if to is None else to.get("jid")}


# ------------------------------------------------------------------------------------ common client

class Received:
    def __init__(self, stanza: slixmpp.Message, sender_bare: str, encrypted_xml: str):
        self.stanza = stanza
        self.sender_bare = sender_bare
        self.encrypted_xml = encrypted_xml
        self.mtype = stanza["type"]
        self.delayed = stanza.xml.find("{urn:xmpp:delay}delay") is not None


class BaseClient(slixmpp.ClientXMPP):
    def __init__(self, jid: str, password: str):
        super().__init__(jid, password)
        self.enable_starttls = False
        self.enable_direct_tls = True
        self.enable_plaintext = False
        self.ca_certs = CA
        for p in ("xep_0030", "xep_0045", "xep_0060", "xep_0163", "xep_0199", "xep_0334"):
            self.register_plugin(p)
        self.inbox: asyncio.Queue[Received] = asyncio.Queue()
        self.ready = asyncio.Event()
        self.add_event_handler("session_start", self._start)
        self.add_event_handler("message", self._message)
        self.add_event_handler("groupchat_message", self._groupchat)

    async def _start(self, _: Any) -> None:
        self.send_presence()
        await self.get_roster()
        self.ready.set()

    def _encrypted(self, msg: slixmpp.Message) -> Optional[str]:
        elt = msg.xml.find(f"{{{NS_OMEMO}}}encrypted")
        return None if elt is None else ET.tostring(elt, encoding="unicode")

    def _message(self, msg: slixmpp.Message) -> None:
        if msg["type"] == "groupchat":
            return
        xml = self._encrypted(msg)
        if xml is not None:
            self.inbox.put_nowait(Received(msg, msg["from"].bare, xml))

    def _groupchat(self, msg: slixmpp.Message) -> None:
        xml = self._encrypted(msg)
        if xml is None:
            return
        room = msg["from"].bare
        nick = msg["from"].resource
        real = self.plugin["xep_0045"].get_jid_property(slixmpp.JID(room), nick, "jid")
        if not real or slixmpp.JID(real).bare == self.boundjid.bare:
            return  # own reflection
        self.inbox.put_nowait(Received(msg, slixmpp.JID(real).bare, xml))

    async def start(self) -> None:
        self.connect(HOST, PORT)
        await asyncio.wait_for(self.ready.wait(), 30)

    async def stop(self) -> None:
        self.disconnect()
        await asyncio.wait_for(self.disconnected, 10)

    async def next_message(self, timeout: float = 15) -> Received:
        return await asyncio.wait_for(self.inbox.get(), timeout)

    def send_encrypted(self, to: str, mtype: str, encrypted_xml: str, msg_id: Optional[str] = None) -> str:
        msg = self.make_message(mto=to, mtype=mtype, mbody="This message is encrypted (OMEMO 2).")
        msg["id"] = msg_id or secrets.token_hex(8)
        msg.append(ET.fromstring(encrypted_xml))
        msg.xml.append(ET.Element("{urn:xmpp:hints}store"))
        msg.send()
        return msg["id"]

    async def fetch_device_list(self, jid: str) -> List[int]:
        try:
            iq = await self.plugin["xep_0060"].get_items(slixmpp.JID(jid), DEVICES_NODE, max_items=1)
        except slixmpp.exceptions.IqError:
            return []
        for item in iq["pubsub"]["items"]:
            return [int(d.get("id")) for d in item["payload"].iter(f"{{{NS_OMEMO}}}device")]
        return []

    async def fetch_device_list_xml(self, jid: str) -> Optional[ET.Element]:
        try:
            iq = await self.plugin["xep_0060"].get_items(slixmpp.JID(jid), DEVICES_NODE, max_items=1)
        except slixmpp.exceptions.IqError:
            return None
        for item in iq["pubsub"]["items"]:
            return item["payload"]
        return None

    async def fetch_bundle_xml(self, jid: str, device_id: int) -> Optional[str]:
        try:
            iq = await self.plugin["xep_0060"].get_items(slixmpp.JID(jid), BUNDLES_NODE, item_ids=[str(device_id)])
        except slixmpp.exceptions.IqError:
            return None
        for item in iq["pubsub"]["items"]:
            return ET.tostring(item["payload"], encoding="unicode")
        return None

    async def publish_device_list(self, devices_elt: ET.Element) -> None:
        await _publish_item_and_configure_node(self.plugin["xep_0060"], self.boundjid.bare, DEVICES_NODE, devices_elt,
                                               "current", {"pubsub#access_model": "open", "pubsub#persist_items": "true",
                                                           "pubsub#max_items": "1"})


# ------------------------------------------------------------------------------- python reference

class MemoryStorage(Storage):
    def __init__(self) -> None:
        super().__init__()
        self.data: Dict[str, JSONType] = {}

    async def _load(self, key: str) -> Maybe[JSONType]:
        return Just(self.data[key]) if key in self.data else Nothing()

    async def _store(self, key: str, value: JSONType) -> None:
        self.data[key] = value

    async def _delete(self, key: str) -> None:
        self.data.pop(key, None)


class HarnessOMEMO(XEP_0384):
    default_config = {"fallback_message": "This message is encrypted (OMEMO 2).", "storage_obj": None}

    @property
    def storage(self) -> Storage:
        return self.storage_obj  # type: ignore[attr-defined]

    @property
    def _btbv_enabled(self) -> bool:
        return True

    async def _devices_blindly_trusted(self, blindly_trusted: FrozenSet[DeviceInformation], identifier: Optional[str]) -> None:
        pass

    async def _prompt_manual_trust(self, manually_trusted: FrozenSet[DeviceInformation], identifier: Optional[str]) -> None:
        sm = await self.get_session_manager()
        for d in manually_trusted:
            await sm.set_trust(d.bare_jid, d.identity_key, TrustLevel.TRUSTED.value)


register_plugin(HarnessOMEMO)


class PyDevice(BaseClient):
    kind = "python-twomemo"

    def __init__(self, jid: str, password: str, storage: Optional[MemoryStorage] = None):
        super().__init__(jid, password)
        self.storage = storage or MemoryStorage()
        self.register_plugin("xep_0280")
        self.register_plugin("xep_0384", {"storage_obj": self.storage})
        self.sm: Optional[omemo.SessionManager] = None

    async def start(self) -> None:
        await super().start()
        self.sm = await self.plugin["xep_0384"].get_session_manager()

    @property
    def device_id(self) -> int:
        return self.sm._SessionManager__own_device_id  # type: ignore[union-attr]

    def backend(self) -> twomemo.Twomemo:
        return next(b for b in self.sm._SessionManager__backends if b.namespace == NS_OMEMO)  # type: ignore[union-attr]

    async def refresh(self, jid: str) -> None:
        await self.sm.refresh_device_lists(jid)  # type: ignore[union-attr]

    async def encrypt(self, recipients: List[str], body: str, room: Optional[str] = None,
                      refresh: bool = True) -> str:
        if refresh:
            for jid in recipients:
                await self.refresh(jid)
        t = time.perf_counter()
        messages, errors = await self.sm.encrypt(frozenset(recipients), {NS_OMEMO: build_sce(body, self.boundjid.bare, room)},
                                                 [NS_OMEMO])
        timed("py.encrypt", time.perf_counter() - t)
        if errors:
            raise RuntimeError(f"python encrypt errors: {errors}")
        message = next(m for m in messages if m.namespace == NS_OMEMO)
        return ET.tostring(twomemo.etree.serialize_message(message), encoding="unicode")

    async def send_text(self, to: str, body: str, mtype: str = "chat", recipients: Optional[List[str]] = None) -> str:
        xml = await self.encrypt(recipients or [to], body, to if mtype == "groupchat" else None)
        self.send_encrypted(to, mtype, xml)
        return xml

    async def decrypt(self, received: Received) -> Dict[str, Any]:
        message = twomemo.etree.parse_message(ET.fromstring(received.encrypted_xml), received.sender_bare)
        t = time.perf_counter()
        plaintext, device_info, _ = await self.sm.decrypt(message)
        timed("py.decrypt", time.perf_counter() - t)
        root = ET.fromstring(received.encrypted_xml)
        own_key = next((k for k in root.iter(f"{{{NS_OMEMO}}}key")
                        if k.get("rid") == str(self.device_id)), None)
        out: Dict[str, Any] = {"senderDeviceId": device_info.device_id,
                               "kex": own_key is not None and own_key.get("kex") in ("true", "1")}
        if plaintext is not None:
            sce = parse_sce(plaintext)
            if sce["from"] != received.sender_bare:
                raise RuntimeError(f"SCE from affix mismatch: {sce['from']} != {received.sender_bare}")
            out.update(sce)
        return out

    async def rotate_signed_pre_key(self) -> None:
        backend = self.backend()
        await backend.rotate_signed_pre_key()
        await self.sm._upload_bundle(await backend.get_bundle(self.boundjid.bare, self.device_id))  # type: ignore[union-attr]

    async def own_bundle_pre_key_ids(self) -> List[int]:
        xml = await self.fetch_bundle_xml(self.boundjid.bare, self.device_id)
        return [int(pk.get("id")) for pk in ET.fromstring(xml).iter(f"{{{NS_OMEMO}}}pk")] if xml else []


# ------------------------------------------------------------------------------------ swift device

class SwiftCLI:
    """omemo-cli process (built for Linux in the omemo-swift-dev image)."""

    def __init__(self, spike_dir: str, state_dir: str, name: str):
        self.spike_dir, self.state_dir, self.name = spike_dir, state_dir, name
        self.proc: Optional[asyncio.subprocess.Process] = None

    async def start(self) -> None:
        self.proc = await asyncio.create_subprocess_exec(
            "docker", "run", "-i", "--rm", "--network", "none", "-v", f"{self.spike_dir}:/src:ro",
            "-v", f"{self.state_dir}:/state", "omemo-swift-dev", "/src/.build/debug/omemo-cli",
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE)

    async def call(self, **req: Any) -> Dict[str, Any]:
        assert self.proc and self.proc.stdin and self.proc.stdout
        t = time.perf_counter()
        self.proc.stdin.write((json.dumps(req) + "\n").encode())
        await self.proc.stdin.drain()
        line = await asyncio.wait_for(self.proc.stdout.readline(), 60)
        timed(f"swift.{req['cmd']}", time.perf_counter() - t)
        resp = json.loads(line)
        if not resp.get("ok"):
            raise SwiftError(resp.get("error", "?"))
        return resp

    async def stop(self) -> None:
        if self.proc:
            self.proc.stdin.close()  # type: ignore[union-attr]
            await self.proc.wait()
            self.proc = None


class SwiftError(Exception):
    pass


class SwiftDevice(BaseClient):
    kind = "swift-omemokit"

    def __init__(self, jid: str, password: str, spike_dir: str, state_dir: str, name: str, label: str,
                 device_id: Optional[int] = None):
        super().__init__(jid, password)
        self.cli = SwiftCLI(spike_dir, state_dir, name)
        self.state_file = f"/state/{name}.json"
        self.label = label
        self.requested_id = device_id
        self.device_id = 0

    async def start(self, publish: bool = True) -> None:
        await self.cli.start()
        resp = await self.cli.call(cmd="init", jid=self.boundjid.bare, statePath=self.state_file, label=self.label,
                                   **({"deviceId": self.requested_id} if self.requested_id else {}))
        self.device_id = resp["deviceId"]
        await super().start()
        if publish:
            await self.publish()

    async def stop(self) -> None:
        await super().stop()
        await self.cli.stop()

    async def publish(self) -> Dict[str, Any]:
        b = await self.cli.call(cmd="bundle")
        await _publish_item_and_configure_node(self.plugin["xep_0060"], self.boundjid.bare, BUNDLES_NODE,
                                               ET.fromstring(b["bundleXML"]), str(self.device_id),
                                               {"pubsub#access_model": "open", "pubsub#persist_items": "true",
                                                "pubsub#max_items": "max"})
        current = await self.fetch_device_list_xml(self.boundjid.bare)
        devices = ET.Element(f"{{{NS_OMEMO}}}devices")
        if current is not None:
            for d in current.iter(f"{{{NS_OMEMO}}}device"):
                if int(d.get("id")) != self.device_id:
                    devices.append(d)
        devices.append(ET.fromstring(b["deviceXML"].replace("<device ", f"<device xmlns='{NS_OMEMO}' ", 1)))
        await self.publish_device_list(devices)
        return b

    async def refresh(self, jid: str, bundles: bool = True) -> List[int]:
        ids = await self.fetch_device_list(jid)
        await self.cli.call(cmd="setDeviceList", jid=jid, deviceIds=ids)
        if bundles:
            for i in ids:
                if jid == self.boundjid.bare and i == self.device_id:
                    continue
                xml = await self.fetch_bundle_xml(jid, i)
                if xml:
                    await self.cli.call(cmd="setBundle", jid=jid, deviceId=i, bundleXML=xml)
        return ids

    async def encrypt(self, recipients: List[str], body: str, room: Optional[str] = None) -> Dict[str, Any]:
        args: Dict[str, Any] = {"cmd": "encrypt", "recipients": recipients, "body": body}
        if room:
            args["to"] = room
        r = await self.cli.call(**args)
        if r["missingBundles"]:
            raise SwiftError(f"missing bundles: {r['missingBundles']}")
        return r

    async def send_text(self, to: str, body: str, mtype: str = "chat", recipients: Optional[List[str]] = None) -> Dict[str, Any]:
        r = await self.encrypt(recipients or [to], body, to if mtype == "groupchat" else None)
        self.send_encrypted(to, mtype, r["xml"])
        return r

    async def decrypt(self, received: Received) -> Dict[str, Any]:
        r = await self.cli.call(cmd="decrypt", xml=received.encrypted_xml, **{"from": received.sender_bare})
        if r.get("republish"):
            await self.publish()
        return r
