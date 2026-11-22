"""Web Push: keys, subscriptions, what gets sent when, quiet hours, coalescing, badge, real encryption."""
import base64
import json
import os
import threading
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from conftest import AUTH, TZ, FakeAlerter, FakeLLM, event, extraction, make_cfg, reminder
from test_items import act, day, items, post, run_mac

J = {"X-Requested-With": "fetch"}


def b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def fake_sub(n=1):
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    pub = ec.generate_private_key(ec.SECP256R1()).public_key().public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    return {"endpoint": f"https://web.push.apple.com/abc{n}", "keys": {"p256dh": b64(pub), "auth": b64(os.urandom(16))}}


@pytest.fixture
def sent():
    return []


@pytest.fixture
def pclient(tmp_path, sent):
    """App whose push deliveries are captured instead of sent. Quiet hours off."""
    cfg = make_cfg(tmp_path, push={"quiet_start": "", "quiet_end": ""})

    def sender(sub, payload, pem, claims):
        sent.append({"endpoint": sub["endpoint"], **json.loads(payload), "claims": claims})
        return 410 if "gone" in sub["endpoint"] else 201

    llm, alerter = FakeLLM(), FakeAlerter()
    app = create_app(cfg, llm=llm, alerter=alerter, background=False, push_sender=sender)
    with TestClient(app) as c:
        c.app_state, c.llm, c.alerter = app.state, llm, alerter
        c.post("/api/push/subscribe", headers=J, json={"subscription": fake_sub()})
        yield c


def test_keys_are_stable_and_subscribe_validates(client):
    k1 = client.get("/api/push/key").json()["public_key"]
    assert len(base64.urlsafe_b64decode(k1 + "==")) == 65  # uncompressed P-256 point
    assert client.get("/api/push/key").json()["public_key"] == k1
    assert client.post("/api/push/subscribe", headers=J, json={"subscription": {"endpoint": "x"}}).status_code == 422
    assert client.post("/api/push/subscribe", headers=J, json={"subscription": fake_sub()}).json()["devices"] == 1
    assert client.post("/api/push/subscribe", headers=J, json={"subscription": fake_sub()}).json()["devices"] == 1  # same endpoint
    assert client.post("/api/push/unsubscribe", headers=J, json={}).json()["devices"] == 0


def test_test_push_and_gone_devices_are_removed(pclient, sent):
    pclient.post("/api/push/subscribe", headers=J, json={"subscription": {**fake_sub(2), "endpoint": "https://x/gone"}})
    r = pclient.post("/api/push/test", headers=J).json()
    assert r["sent"] == 1 and {s["endpoint"] for s in sent} == {"https://web.push.apple.com/abc1", "https://x/gone"}
    assert sent[0]["title"] == "Second Brain" and sent[0]["claims"]["sub"].startswith("mailto:")
    assert pclient.get("/api/push/key").json()["devices"] == 1  # 410 → dropped


def test_new_items_coalesce_into_one_notification(pclient, sent):
    import time
    pclient.llm.responder = lambda p: extraction(reminder("Pick up milk"), reminder("Pick up bread"))
    post(pclient, text="milk and bread please")
    run_mac(pclient)
    pclient.portal.call(lambda: __import__("asyncio").sleep(3.3))
    added = [s for s in sent if s["tag"].startswith("added:")]
    assert len(added) == 1 and added[0]["title"] == "Added 2 things"
    assert "☑️ Pick up milk · Wife" in added[0]["body"] and "Pick up bread" in added[0]["body"]
    assert added[0]["url"] == "/events/imessage:1"


def test_single_event_and_gift(pclient, sent):
    soon = (datetime.now(TZ) + timedelta(days=2)).replace(hour=15, minute=0).strftime("%Y-%m-%dT%H:%M")
    pclient.llm.responder = lambda p: extraction(event("Dentist", soon))
    post(pclient, text="dentist thursday 3")
    run_mac(pclient)
    pclient.llm.responder = lambda p: extraction(act("save_to_collection", collection="gift_ideas", title="Kindle"))
    post(pclient, event_id="imessage:2", text="I'd love a kindle")
    run_mac(pclient)
    pclient.portal.call(lambda: __import__("asyncio").sleep(3.3))
    titles = {s["title"]: s["body"] for s in sent if s["tag"].startswith("added:")}
    assert titles["Added to Calendar"].startswith("📅 Dentist · ")
    assert titles["Saved to Gift ideas"].startswith("🎁 Kindle")


def test_review_push_and_badge(pclient, sent):
    pclient.llm.responder = lambda p: extraction(reminder("Call the plumber"), conf=0.3)
    post(pclient, text="maybe the plumber")
    rv = [s for s in sent if s["tag"].startswith("review:")]
    assert rv and rv[0]["url"] == "/review" and "Call the plumber" in rv[0]["body"] and rv[0]["badge"] == 1
    assert pclient.get("/api/badge").json() == {"count": 1}


def test_morning_push_lists_picks_and_followups(pclient, sent):
    pclient.llm.responder = lambda p: extraction(reminder("Pay water bill", due=day(0)))
    post(pclient, text="pay the bill today")
    pclient.llm.responder = lambda p: extraction(act("waiting_on", title="Deck quote from Bob", person="Bob", due_date=day(0)))
    post(pclient, event_id="imessage:2", text="Bob will send the deck quote today")
    run_mac(pclient)
    pclient.llm.json_responder = lambda name, m: RuntimeError("scores")
    pclient.post("/api/today/repick", headers=J)
    m = [s for s in sent if s["tag"].startswith("morning:")][-1]
    # the due follow-up is picked for today, so it's listed once (not again as a follow-up line)
    assert m["title"] == "Today's 2" and "Pay water bill" in m["body"] and "Deck quote from Bob" in m["body"]
    assert "⏳ Follow up" not in m["body"] and m["badge"] == 2
    pclient.post("/api/today/evening", headers=J)
    e = [s for s in sent if s["tag"].startswith("evening:")][-1]
    assert e["title"] == "Wrapping up" and e["url"] == "/today"


def test_toggles_and_quiet_hours(pclient, sent):
    pclient.patch("/api/settings", json={"push": {"review": False}})
    pclient.llm.responder = lambda p: extraction(reminder("Call the plumber"), conf=0.3)
    post(pclient, text="maybe the plumber")
    assert not [s for s in sent if s["tag"].startswith("review:")]
    now = datetime.now(TZ)
    pclient.patch("/api/settings", json={"push": {"quiet_start": (now - timedelta(hours=1)).strftime("%H:%M"),
                                                  "quiet_end": (now + timedelta(hours=1)).strftime("%H:%M")}})
    n = len(sent)
    pclient.post("/api/today/repick", headers=J)
    assert len(sent) == n  # quiet hours: daily push held back
    pclient.portal.call(lambda: pclient.alerter.push.send("system", "Second Brain", "Mac offline"))
    assert sent[-1]["body"] == "Mac offline"  # problems still come through
    log = pclient.app_state.push.recent_log()
    assert any(r["skipped"] == "quiet hours" for r in log)


def test_system_alert_also_pushes(tmp_path):
    import asyncio
    from app.heartbeat import Alerter
    from app.models import DB
    cfg = make_cfg(tmp_path)
    got = []

    class P:
        async def send(self, kind, title, body, **kw):
            got.append((kind, body, kw.get("url")))
            return 1

    a = Alerter(cfg, DB(str(tmp_path / "a.db")))
    a.push = P()
    asyncio.run(a.send("agent_offline", "🔴 Mac agent offline — no heartbeat since Sat 09:00."))
    asyncio.run(a.send("needs_review", "not a system alert"))
    assert got == [("system", "Mac agent offline — no heartbeat since Sat 09:00.", "/system")]


def test_real_webpush_encryption_against_local_server(tmp_path):
    """The actual pywebpush call: VAPID-signed, aes128gcm-encrypted POST to the endpoint."""
    got = {}

    class H(BaseHTTPRequestHandler):
        def do_POST(self):
            got["headers"] = dict(self.headers)
            got["body"] = self.rfile.read(int(self.headers["Content-Length"]))
            self.send_response(201); self.end_headers()

        def log_message(self, *a):
            pass

    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        from app.models import DB
        from app.push import Push
        cfg = make_cfg(tmp_path, push={"quiet_start": "", "quiet_end": ""})
        p = Push(cfg, DB(str(tmp_path / "p.db")))
        sub = fake_sub()
        sub["endpoint"] = f"http://127.0.0.1:{srv.server_port}/push/abc"
        p.subscribe(sub, "test")
        import asyncio
        assert asyncio.run(p.send("test", "Hi", "there")) == 1
        h = {k.lower(): v for k, v in got["headers"].items()}
        assert h["content-encoding"] == "aes128gcm" and h["authorization"].startswith("vapid t=")
        assert p.public_key in h["authorization"] and b"there" not in got["body"]  # encrypted
    finally:
        srv.shutdown()
