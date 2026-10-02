"""S2 server-side push tests: ejabberd (mod_push) → push gateway (XEP-0114) → APNs-compatible endpoint.

Everything except the final hop is real: ejabberd 26.09, the Go gateway, PostgreSQL, XEP-0050 registration,
XEP-0357 enable/disable. The APNs endpoint is the dev-only `apns-mock` (verifies the ES256 JWT, records
payloads) because Apple's endpoints are unreachable from the spike environment. Device delivery is covered by
the device runbook (docs/spikes/S2-push.md).

Run: python server_tests.py
"""
from __future__ import annotations

import asyncio
import base64
import json
import logging
import os
import secrets
import subprocess
import sys
import time
import traceback
import xml.etree.ElementTree as ET
from typing import Any, Dict, List, Optional

import slixmpp
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

DOMAIN = "chat.messenger.test"
PUSH_JID = f"push.{DOMAIN}"
CA = os.environ.get("XMPP_CA", "/tmp/claude-0/caddy-root.crt")
RECORDS = os.environ.get("MOCK_RECORDS", "/tmp/claude-0/s2/mock/records.jsonl")
EJABBERD = "messenger-dev-ejabberd-1"
GATEWAY = "messenger-dev-push-gateway-1"
GATEWAYS = ["messenger-dev-push-gateway-1", "messenger-dev-push-gateway-2"]  # compose runs 2 replicas
POSTGRES = "messenger-dev-postgres-1"
NS_CMD = "http://jabber.org/protocol/commands"
NS_DATA = "jabber:x:data"
NS_PUSH = "urn:xmpp:push:0"
GOOD_TOKEN = "aa" * 32
NEW_TOKEN = "bb" * 32
DEAD_TOKEN = "dd" * 32

logging.basicConfig(level=logging.ERROR)


def ctl(*a: str) -> str:
    return subprocess.run(["docker", "exec", EJABBERD, "ejabberdctl", *a], capture_output=True, text=True).stdout


def sql(q: str) -> str:
    return subprocess.run(["docker", "exec", POSTGRES, "psql", "-U", "pushgw", "-d", "pushgw", "-tAc", q],
                          capture_output=True, text=True).stdout.strip()


def records() -> List[Dict[str, Any]]:
    with open(RECORDS) as f:
        return [json.loads(line) for line in f if line.strip()]


def jid(u: str) -> str:
    return f"{u}@{DOMAIN}"


class C(slixmpp.ClientXMPP):
    def __init__(self, user: str, res: str):
        super().__init__(f"{jid(user)}/{res}", f"pw-{user}-s2")
        self.enable_starttls, self.enable_direct_tls, self.enable_plaintext = False, True, False
        self.ca_certs = CA
        for p in ("xep_0030", "xep_0198", "xep_0199"):
            self.register_plugin(p)
        self.plugin["xep_0198"].allow_resume = True
        self.ready = asyncio.Event()
        self.inbox: asyncio.Queue = asyncio.Queue()
        self.add_event_handler("session_start", self._start)
        self.add_event_handler("session_resumed", lambda _: self.ready.set())
        self.add_event_handler("message", lambda m: self.inbox.put_nowait(m) if m["body"] else None)

    async def _start(self, _: Any) -> None:
        self.send_presence()
        await self.get_roster()
        self.ready.set()

    async def online(self) -> None:
        self.ready.clear()
        self.connect("127.0.0.1", 5223)
        await asyncio.wait_for(self.ready.wait(), 30)

    def abort(self) -> None:
        self.transport.abort()  # app suspended / killed: socket dies, server hibernates the session

    async def quit(self) -> None:
        self.plugin["xep_0198"].allow_resume = False
        self.disconnect()
        await asyncio.wait_for(self.disconnected, 10)

    async def command(self, node: str, fields: Dict[str, str]) -> Dict[str, str]:
        iq = self.make_iq_set(ito=PUSH_JID)
        cmd = ET.SubElement(iq.xml, f"{{{NS_CMD}}}command", node=node, action="execute")
        x = ET.SubElement(cmd, f"{{{NS_DATA}}}x", type="submit")
        for k, v in fields.items():
            f = ET.SubElement(x, f"{{{NS_DATA}}}field", var=k)
            ET.SubElement(f, f"{{{NS_DATA}}}value").text = v
        res = await iq.send(timeout=15)
        out: Dict[str, str] = {}
        for f in res.xml.iter(f"{{{NS_DATA}}}field"):
            v = f.find(f"{{{NS_DATA}}}value")
            out[f.get("var")] = v.text if v is not None else ""
        return out

    async def register(self, token: str, key: bytes) -> Dict[str, str]:
        return await self.command("register-push-apns", {"token": token, "environment": "sandbox",
                                                         "device-key": base64.b64encode(key).decode()})

    async def enable(self, node: str, secret: str) -> None:
        iq = self.make_iq_set()
        en = ET.SubElement(iq.xml, f"{{{NS_PUSH}}}enable", jid=PUSH_JID, node=node)
        x = ET.SubElement(en, f"{{{NS_DATA}}}x", type="submit")
        for var, val in (("FORM_TYPE", "http://jabber.org/protocol/pubsub#publish-options"), ("secret", secret)):
            f = ET.SubElement(x, f"{{{NS_DATA}}}field", var=var)
            ET.SubElement(f, f"{{{NS_DATA}}}value").text = val
        await iq.send(timeout=15)

    async def disable(self, node: str) -> None:
        iq = self.make_iq_set()
        ET.SubElement(iq.xml, f"{{{NS_PUSH}}}disable", jid=PUSH_JID, node=node)
        await iq.send(timeout=15)

    def say(self, to: str, body: str) -> None:
        self.send_message(mto=to, mbody=body, mtype="chat")


def open_envelope(key: bytes, e: str) -> Dict[str, Any]:
    raw = base64.b64decode(e)
    assert raw[0] == 1
    return json.loads(AESGCM(key).decrypt(raw[1:13], raw[13:], bytes([1])))


async def wait_records(n_before: int, expect_new: int, timeout: float = 8) -> List[Dict[str, Any]]:
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = records()
        if len(r) - n_before >= expect_new and expect_new > 0:
            return r[n_before:]
        await asyncio.sleep(0.3)
    return records()[n_before:]


class Ctx:
    def __init__(self) -> None:
        self.notes: List[str] = []
        self.clients: List[C] = []

    async def client(self, user: str, res: str) -> C:
        c = C(user, res)
        await c.online()
        self.clients.append(c)
        return c

    async def close(self) -> None:
        for c in self.clients:
            try:
                await c.quit()
            except Exception:
                pass


def reset() -> None:
    for u in ("alice", "bob"):
        ctl("unregister", u, DOMAIN)
        ctl("register", u, DOMAIN, f"pw-{u}-s2")
    sql("DELETE FROM registration")


async def setup_bob(c: Ctx, token: str = GOOD_TOKEN, res: str = "phone") -> tuple[C, bytes, Dict[str, str]]:
    bob = await c.client("bob", res)
    key = secrets.token_bytes(32)
    reg = await bob.register(token, key)
    assert reg.get("node") and reg.get("secret"), reg
    await bob.enable(reg["node"], reg["secret"])
    return bob, key, reg


# ------------------------------------------------------------------------------------------- tests

async def p01_foreground_no_push(c: Ctx) -> None:
    """Recipient online (app in foreground): message arrives over XMPP, no APNs request."""
    bob, _, _ = await setup_bob(c)
    alice = await c.client("alice", "a")
    n = len(records())
    alice.say(jid("bob"), "foreground message")
    m = await asyncio.wait_for(bob.inbox.get(), 10)
    assert m["body"] == "foreground message"
    new = await wait_records(n, 0, timeout=3)
    assert not new, new
    c.notes.append("delivered over the live stream; 0 APNs requests")


async def p02_background_push_content_free(c: Ctx) -> None:
    """Recipient socket lost (background/suspended → SM hibernation): one APNs request, no plaintext."""
    bob, key, _ = await setup_bob(c)
    alice = await c.client("alice", "laptop")
    bob.abort()
    await asyncio.sleep(1)
    n = len(records())
    secret_text = "Meet at 7, the code is 4711"
    alice.say(jid("bob"), secret_text)
    new = await wait_records(n, 1)
    assert len(new) == 1, new
    r = new[0]
    payload_text = json.dumps(r["payload"])
    for leak in (secret_text, "4711", "alice", DOMAIN):
        assert leak not in payload_text, f"payload leaks {leak!r}: {payload_text}"
    assert r["proto"] == "HTTP/2.0" and r["jwtValid"] and r["topic"] == "com.example.messenger.dev"
    assert r["pushType"] == "alert" and r["priority"] == "10" and r["token"] == GOOD_TOKEN
    aps = r["payload"]["aps"]
    assert aps["alert"] == {"title": "New message"} and aps["mutable-content"] == 1 and aps["thread-id"]
    env = open_envelope(key, r["payload"]["e"])
    assert env["sender"].startswith(jid("alice")) and env["conv"] == jid("alice"), env
    c.notes.append(f"APNs request: HTTP/2, valid ES256 JWT, push-type alert, priority 10; aps={aps}")
    c.notes.append(f"payload contains no body/JID; envelope decrypted with the device key → sender {env['sender']}")


async def p03_terminated_offline_push(c: Ctx) -> None:
    """App terminated and the hibernated session expired/killed (user fully offline): push still sent."""
    bob, key, _ = await setup_bob(c)
    alice = await c.client("alice", "a")
    bob.abort()
    await asyncio.sleep(1)
    ctl("kick_user", "bob", DOMAIN)
    await asyncio.sleep(1)
    n = len(records())
    alice.say(jid("bob"), "while fully offline")
    new = await wait_records(n, 1)
    assert len(new) == 1 and new[0]["status"] == 200, new
    c.notes.append("no session at all (offline storage): ejabberd mod_push still published → 1 APNs request")


async def p04_gateway_restart(c: Ctx) -> None:
    """Complete gateway outage (all instances) while the user is in background.
    Characterises ejabberd's behaviour (a publish that fails during the outage makes mod_push DISABLE the node)
    and verifies the mitigation (client re-enables push whenever its session starts or resumes)."""
    bob, key, reg = await setup_bob(c)
    alice = await c.client("alice", "a")
    bob.abort()
    await asyncio.sleep(1)
    subprocess.run(["docker", "stop", *GATEWAYS], capture_output=True)  # complete gateway outage
    alice.say(jid("bob"), "while gateway down")
    await asyncio.sleep(2)
    subprocess.run(["docker", "start", *GATEWAYS], capture_output=True)
    for _ in range(30):
        h = subprocess.run(["docker", "exec", GATEWAY, "wget", "-qO-", "http://127.0.0.1:8080/healthz"],
                           capture_output=True, text=True).stdout
        if '"component":true' in h:
            break
        await asyncio.sleep(1)
    disabled = "disabling push" in subprocess.run(["docker", "logs", "--since", "15s", EJABBERD],
                                                  capture_output=True, text=True).stdout
    n = len(records())
    alice.say(jid("bob"), "after restart, before client re-enable")
    lost = len(await wait_records(n, 0, timeout=4)) == 0
    c.notes.append(f"FINDING: outage → ejabberd logged 'disabling push' = {disabled}; "
                   f"next message without client action produced an APNs request = {not lost}")
    assert disabled and lost, "behaviour changed: re-check the mitigation"
    # Mitigation: the app resumes (e.g. user opens it) and re-enables push on every session start/resume.
    await bob.online()
    await bob.enable(reg["node"], reg["secret"])
    bob.abort()
    await asyncio.sleep(1)
    n = len(records())
    alice.say(jid("bob"), "after client re-enable")
    assert len(await wait_records(n, 1)) == 1
    c.notes.append("mitigation verified: after resume + re-enable, pushes are delivered again")


async def p05_invalid_token(c: Ctx) -> None:
    """APNs answers 410 for a dead token: registration deleted, ejabberd disables the node, no further requests."""
    bob, key, reg = await setup_bob(c, token=DEAD_TOKEN)
    alice = await c.client("alice", "a")
    bob.abort()
    await asyncio.sleep(1)
    n = len(records())
    alice.say(jid("bob"), "to dead token 1")
    first = await wait_records(n, 1)
    assert len(first) == 1 and first[0]["status"] == 410, first
    await asyncio.sleep(1)
    assert sql(f"SELECT count(*) FROM registration WHERE node = '{reg['node']}'") == "0"
    n2 = len(records())
    alice.say(jid("bob"), "to dead token 2")
    later = await wait_records(n2, 0, timeout=4)
    assert not later, later
    logs = subprocess.run(["docker", "logs", "--since", "20s", GATEWAY], capture_output=True, text=True).stdout
    c.notes.append("410 → registration deleted; next message: 0 APNs requests"
                   + ("; gateway saw a publish for the unknown node (ejabberd retried once)" if "unknown node" in logs
                      else "; ejabberd did not publish again (node disabled)"))


async def p06_token_refresh(c: Ctx) -> None:
    """Token rotates: client registers the new token, enables the new node, disables + unregisters the old one."""
    bob, key, old = await setup_bob(c, token=GOOD_TOKEN)
    new_key = secrets.token_bytes(32)
    new = await bob.register(NEW_TOKEN, new_key)
    # ejabberd stores ONE push node per session (push_session PK = host, user, session timestamp):
    # disable the old node first, then enable the new one.
    await bob.disable(old["node"])
    await bob.enable(new["node"], new["secret"])
    await bob.command("unregister-push", {"node": old["node"]})
    alice = await c.client("alice", "a")
    bob.abort()
    await asyncio.sleep(1)
    n = len(records())
    alice.say(jid("bob"), "after token refresh")
    got = await wait_records(n, 1)
    tokens = [r["token"] for r in got]
    assert tokens == [NEW_TOKEN], tokens
    assert open_envelope(new_key, got[0]["payload"]["e"])["conv"] == jid("alice")
    c.notes.append("only the new token receives pushes; old registration removed")


async def p07_logout_cleanup(c: Ctx) -> None:
    """Logout: disable on the server + unregister at the gateway → no pushes, no stored registration."""
    bob, key, reg = await setup_bob(c)
    await bob.disable(reg["node"])
    await bob.command("unregister-push", {"node": reg["node"]})
    assert sql("SELECT count(*) FROM registration") == "0"
    await bob.quit()
    c.clients.remove(bob)
    alice = await c.client("alice", "a")
    n = len(records())
    alice.say(jid("bob"), "after logout")
    assert not await wait_records(n, 0, timeout=4)
    c.notes.append("after logout: 0 registrations, 0 APNs requests")


async def p08_mute(c: Ctx) -> None:
    """Muted conversation: gateway suppresses the push; unmute restores it."""
    import hashlib
    import hmac
    bob, key, reg = await setup_bob(c)
    alice = await c.client("alice", "a")
    opaque = hmac.new(key, ("thread:" + jid("alice")).encode(), hashlib.sha256).hexdigest()[:32]
    await bob.command("mute-conversation", {"node": reg["node"], "conversation": opaque,
                                            "until": str(int(time.time()) + 3600)})
    bob.abort()
    await asyncio.sleep(1)
    n = len(records())
    alice.say(jid("bob"), "muted")
    assert not await wait_records(n, 0, timeout=4)
    bob2 = await c.client("bob", "phone2")
    await bob2.command("mute-conversation", {"node": reg["node"], "conversation": opaque, "until": "0"})
    await bob2.quit()
    c.clients.remove(bob2)
    n = len(records())
    alice.say(jid("bob"), "unmuted")
    assert len(await wait_records(n, 1)) == 1
    c.notes.append("muted: 0 requests; after unmute: 1 request (mute key is an opaque per-device HMAC)")


async def p09_account_disable_cleanup(c: Ctx) -> None:
    """Admin disables the account: admin.sh removes its push registrations."""
    bob, key, reg = await setup_bob(c)
    assert sql("SELECT count(*) FROM registration") == "1"
    out = subprocess.run(["/home/user/XMPP/scripts/admin.sh", "disable", "bob", "s2 test"], capture_output=True, text=True,
                         env={**os.environ, "ENV_FILE": os.environ.get("ENV_FILE", "")})
    remaining = sql("SELECT count(*) FROM registration")
    ctl("unban_account", "bob", DOMAIN)
    assert remaining == "0", (remaining, out.stdout, out.stderr)
    c.notes.append("admin.sh disable: account banned and its push registrations deleted")


async def p10_two_gateway_instances(c: Ctx) -> None:
    """Mitigation for the p04 finding: two gateway instances on the same component domain (ejabberd load-balances).
    Stopping one instance does not interrupt delivery and ejabberd does not disable push."""
    env = subprocess.run(["docker", "inspect", GATEWAY, "--format", "{{range .Config.Env}}{{println .}}{{end}}"],
                         capture_output=True, text=True).stdout
    envfile = "/tmp/claude-0/s2/gw.env"
    with open(envfile, "w") as f:
        f.write("\n".join(l for l in env.splitlines() if l and not l.startswith("PATH=")))
    subprocess.run(["docker", "rm", "-f", "gw2"], capture_output=True)
    subprocess.run(["docker", "run", "-d", "--name", "gw2", "--network", "messenger-dev_internal", "--env-file", envfile,
                    "-v", "/tmp/claude-0/s2/secrets:/run/apns:ro", "messenger-dev-push-gateway"], capture_output=True, check=True)
    try:
        await asyncio.sleep(4)
        bob, key, reg = await setup_bob(c)
        alice = await c.client("alice", "a")
        bob.abort()
        await asyncio.sleep(1)
        subprocess.run(["docker", "stop", GATEWAY], capture_output=True)
        delivered = []
        for i in range(3):
            await asyncio.sleep(2.5)  # beyond the gateway's 2 s coalescing window
            n = len(records())
            alice.say(jid("bob"), f"ha{i}")
            delivered.append(len(await wait_records(n, 1)))
        disabled = "disabling push" in subprocess.run(["docker", "logs", "--since", "20s", EJABBERD],
                                                      capture_output=True, text=True).stdout
        assert delivered == [1, 1, 1] and not disabled, (delivered, disabled)
        c.notes.append("instance 1 stopped: 3/3 pushes delivered by instance 2; ejabberd did not disable push")
    finally:
        subprocess.run(["docker", "start", GATEWAY], capture_output=True)
        subprocess.run(["docker", "rm", "-f", "gw2"], capture_output=True)


async def p11_clean_close_keeps_push(c: Ctx) -> None:
    """App closes its stream cleanly (</stream>, no resume) without disabling push: offline messages still push."""
    bob, key, reg = await setup_bob(c)
    await bob.quit()
    c.clients.remove(bob)
    alice = await c.client("alice", "a")
    n = len(records())
    alice.say(jid("bob"), "after clean close")
    got = await wait_records(n, 1)
    assert len(got) == 1, got
    c.notes.append("clean stream close keeps the push registration: offline message → 1 APNs request")


TESTS = [p01_foreground_no_push, p02_background_push_content_free, p03_terminated_offline_push, p04_gateway_restart,
         p05_invalid_token, p06_token_refresh, p07_logout_cleanup, p08_mute, p09_account_disable_cleanup,
         p10_two_gateway_instances, p11_clean_close_keeps_push]


async def main() -> int:
    only = sys.argv[1:]
    ok = True
    for t in TESTS:
        if only and not any(t.__name__.startswith(o) for o in only):
            continue
        reset()
        ctx = Ctx()
        start = time.perf_counter()
        try:
            await asyncio.wait_for(t(ctx), 120)
            status = "PASS"
        except Exception as e:
            status = f"FAIL  — {type(e).__name__}: {e}"
            ok = False
            traceback.print_exc()
        finally:
            await ctx.close()
        print(f"{status.split('  —')[0]}  {t.__name__}  ({time.perf_counter() - start:.1f}s){status[4:] if status != 'PASS' else ''}")
        for n in ctx.notes:
            print(f"      · {n}")
    all_payloads = "\n".join(json.dumps(r["payload"]) for r in records())
    print(f"payload audit: {len(records())} APNs requests recorded; "
          f"bodies leaked: {sum(1 for w in ('Meet at 7', '4711', 'foreground message', 'after token refresh') if w in all_payloads)}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
