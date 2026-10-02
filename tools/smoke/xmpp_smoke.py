#!/usr/bin/env python3
"""Server smoke test for a freshly deployed stack (not a client test suite).

Logs in two accounts over direct TLS (XEP-0368) with certificate validation and checks
SCRAM-SHA-256, Stream Management, the shared roster, the server features the app relies on,
HTTP Upload discovery, and a message round trip with a server-assigned stanza-id (XEP-0359).

Usage:
  xmpp_smoke.py --host 127.0.0.1 --port 5223 --ca root.crt alice@chat.example.com bob@chat.example.com
Passwords are read from the environment: SMOKE_PASSWORD_A, SMOKE_PASSWORD_B.
"""
import argparse
import asyncio
import os
import sys
import uuid

import slixmpp

REQUIRED_SERVER_FEATURES = {
    "urn:xmpp:carbons:2": "Carbons (XEP-0280)",
}
# Advertised on the account (bare JID), per the respective XEPs.
REQUIRED_ACCOUNT_FEATURES = {
    "urn:xmpp:mam:2": "MAM (XEP-0313)",
    "urn:xmpp:push:0": "Push (XEP-0357)",
    "urn:xmpp:sid:0": "Stanza IDs (XEP-0359)",
    "http://jabber.org/protocol/pubsub#publish-options": "PEP publish-options (OMEMO)",
}

results: list[tuple[str, bool, str]] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    results.append((name, ok, detail))
    print(f"{'PASS' if ok else 'FAIL'}  {name}{'  — ' + detail if detail else ''}")


class Client(slixmpp.ClientXMPP):
    def __init__(self, jid: str, password: str, ca: str):
        super().__init__(jid, password)
        self.enable_starttls = False
        self.enable_direct_tls = True
        self.enable_plaintext = False
        self.ca_certs = ca
        for plugin in ("xep_0030", "xep_0198", "xep_0199", "xep_0359"):
            self.register_plugin(plugin)
        self.ready = asyncio.Event()
        self.received: asyncio.Queue = asyncio.Queue()
        self.mechanism = None
        self.offered: list[str] = []
        self.add_event_handler("session_start", self._on_start)
        self.add_event_handler("message", lambda msg: self.received.put_nowait(msg))
        self.add_event_handler("auth_success", self._on_auth)
        self.add_event_handler("failed_auth", lambda _: self.ready.set())

    def _on_auth(self, _):
        mech = getattr(self.plugin["feature_mechanisms"], "mech", None)
        self.mechanism = getattr(mech, "name", None)
        self.offered = sorted(getattr(self.plugin["feature_mechanisms"], "mech_list", []))

    async def _on_start(self, _):
        await self.get_roster()
        self.send_presence()
        self.ready.set()


async def run(args) -> int:
    a = Client(args.jid_a, os.environ["SMOKE_PASSWORD_A"], args.ca)
    b = Client(args.jid_b, os.environ["SMOKE_PASSWORD_B"], args.ca)
    for c in (a, b):
        c.connect(args.host, args.port)
    try:
        await asyncio.wait_for(asyncio.gather(a.ready.wait(), b.ready.wait()), 20)
    except asyncio.TimeoutError:
        check("login both accounts", False, "timeout")
        return 1
    check("login both accounts over direct TLS with CA validation", a.authenticated and b.authenticated)
    if not (a.authenticated and b.authenticated):
        return 1

    check("SASL mechanism is SCRAM-SHA-256", a.mechanism == "SCRAM-SHA-256", str(a.mechanism))
    check("PLAIN not offered", "PLAIN" not in a.offered, ", ".join(a.offered))
    check("Stream Management enabled", bool(a.plugin["xep_0198"].sm_id), "resumable session id assigned")

    roster_b = a.client_roster.has_jid(b.boundjid.bare)
    check("shared roster: A sees B without adding contacts", roster_b)

    disco = a.plugin["xep_0030"]
    info = await disco.get_info(jid=a.boundjid.host)
    features = set(info["disco_info"]["features"])
    for ns, name in REQUIRED_SERVER_FEATURES.items():
        check(f"server feature {name}", ns in features)
    info = await disco.get_info(jid=a.boundjid.bare)
    features = set(info["disco_info"]["features"])
    for ns, name in REQUIRED_ACCOUNT_FEATURES.items():
        check(f"account feature {name}", ns in features)

    items = await disco.get_items(jid=a.boundjid.host)
    upload_found = False
    for jid, _node, _name in items["disco_items"]["items"]:
        sub = await disco.get_info(jid=jid)
        if "urn:xmpp:http:upload:0" in sub["disco_info"]["features"]:
            upload_found = True
    check("HTTP Upload service discoverable (XEP-0363)", upload_found)

    origin = str(uuid.uuid4())
    msg = a.make_message(mto=b.boundjid.bare, mbody="smoke-test", mtype="chat")
    msg["id"] = origin
    msg["origin_id"]["id"] = origin
    msg.send()
    try:
        got = await asyncio.wait_for(b.received.get(), 10)
        check("message A → B delivered", got["body"] == "smoke-test")
        check("origin-id preserved", got["origin_id"]["id"] == origin)
        check("server stanza-id assigned (archive id)", bool(got["stanza_id"]["id"]))
    except asyncio.TimeoutError:
        check("message A → B delivered", False, "timeout")

    for c in (a, b):
        c.disconnect()
    return 0 if all(ok for _, ok, _ in results) else 1


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--host", required=True)
    p.add_argument("--port", type=int, default=5223)
    p.add_argument("--ca", required=True, help="CA certificate used to validate the server")
    p.add_argument("jid_a")
    p.add_argument("jid_b")
    sys.exit(asyncio.run(run(p.parse_args())))


if __name__ == "__main__":
    main()
