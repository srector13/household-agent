#!/usr/bin/env python3
"""A real brain with a fake model and a fake Mac, seeded with a believable day — for the iOS
screenshot tests in CI (and for trying the app locally without your real data).

    pip install -e brain && python3 ios/ci/devhost.py            # serves http://127.0.0.1:8080

The model is a tiny keyword matcher on 127.0.0.1:8001; the "Mac" marks every command done and
reports a healthy heartbeat. Dates are relative to today, so screenshots always look current.
"""
from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from datetime import date, datetime, timedelta
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from zoneinfo import ZoneInfo

import httpx

TZ = ZoneInfo("America/Chicago")
PORT = int(os.environ.get("PORT", "8080"))
TOKEN = "ci-token"
BASE = f"http://127.0.0.1:{PORT}"
ROOT = Path(__file__).resolve().parents[2]
SARAH = "+17855550000"
FAMILY = "iMessage;+;chat5512"


def day(n: int) -> str:
    return (datetime.now(TZ).date() + timedelta(days=n)).isoformat()


# ---- fake model ----------------------------------------------------------------------------------
def act(type_, title="", **kw):
    base = {"type": type_, "ref": None, "collection": None, "person": None, "title": title, "due_date": None,
            "due_time": None, "start": None, "end": None, "all_day": False, "location": None, "url": None,
            "notes": None, "summary": None, "first_step": None, "steps": [], "source_quote": title}
    base.update(kw)
    return base


def rules():
    return [
        ("photos", [act("track_promise", "Send Sarah the photos", due_date=day(0), summary="You told Sarah you'd send them tonight.")], .92),
        ("babysitter", [act("waiting_on", "Babysitter answer", due_date=day(2), summary="Sarah is checking with the babysitter.")], .9),
        ("taxes", [act("create_reminder", "Do our taxes", due_date=day(6), first_step="Find last year's return",
                       steps=["Gather the W-2s", "Download the 1099s", "Book the accountant"])], .9),
        ("kindle", [act("save_to_collection", "Kindle Paperwhite", collection="gift_ideas",
                        url="https://example.com/kindle", summary="Sarah would love one for her birthday.")], .9),
        ("ring size", [act("save_to_collection", "Ring size 6", collection="about_person")], .9),
        ("taco", [act("save_to_collection", "Taqueria El Sol on Main St", collection="places", summary="Sarah wants to try it.")], .88),
        ("eggs", [act("create_reminder", "Pick up eggs", due_date=day(1))], .94),
        ("milk and bread", [act("create_reminder", "Pick up milk"), act("create_reminder", "Pick up bread")], .92),
        ("dentist", [act("create_event", "Dentist", start=f"{day(2)}T15:30", location="Main St Dental")], .91),
        ("pick up emma", [act("create_event", "Pick up Emma from school", start=f"{day(1)}T15:15")], .9),
        ("water bill", [act("create_reminder", "Pay the water bill", due_date=day(0), due_time="17:00")], .93),
        ("plumber", [act("create_reminder", "Call the plumber about the sink")], .55),  # low confidence → review
        ("gutters", [act("create_reminder", "Clean the gutters")], .9),
    ]


class FakeModel(BaseHTTPRequestHandler):
    def _send(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):  # /v1/models
        self._send({"data": [{"id": "Qwen/Qwen3-32B"}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        name = body.get("response_format", {}).get("json_schema", {}).get("name")
        if name == "daily_pick":
            return self._send({"choices": [{"message": {"content": json.dumps({
                "picks": [{"n": 1, "why": "due today", "first_step": "Open the water company's app"},
                          {"n": 2, "why": "you promised Sarah", "first_step": "Open Photos, pick 5 favorites"},
                          {"n": 3, "why": "a quick win", "first_step": None}],
                "note": "Three things. That's a full day."})}}]})
        if name == "breakdown":
            return self._send({"choices": [{"message": {"content": json.dumps({
                "first_step": "Put the ladder by the garage", "steps": ["Get gloves and a bucket", "Start at the front"]})}}]})
        msg = body["messages"][-1]["content"]
        if '"""' in msg:
            msg = msg.split('"""')[-2]
        out = {"actionable": False, "actions": [], "confidence": .9, "reasoning_brief": "Chit-chat."}
        for key, acts, conf in rules():
            if key in msg.lower():
                out = {"actionable": True, "actions": acts, "confidence": conf, "reasoning_brief": "Clear request."}
                break
        self._send({"choices": [{"message": {"content": json.dumps(out)}}]})

    def log_message(self, *a):
        pass


# ---- seeding ---------------------------------------------------------------------------------------
AUTH = {"Authorization": f"Bearer {TOKEN}"}


def heartbeat(c: httpx.Client):
    c.post("/api/agent/heartbeat", headers=AUTH, json={
        "agent_version": "0.6.0", "fda_ok": True, "reminders_ok": True, "calendar_ok": True,
        "contacts_ok": True, "reminderkit_ok": True, "uptime_s": 3600, "buffered_events": 0})


def run_mac(c: httpx.Client):
    cmds = c.get("/api/agent/commands?wait=0", headers=AUTH).json()["commands"]
    for i, cmd in enumerate(cmds):
        c.post(f"/api/agent/commands/{cmd['command_id']}/result", headers=AUTH,
               json={"status": "done", "apple_item_id": cmd["payload"].get("apple_item_id") or f"x-apple-{cmd['command_id']}"})


def seed(db_path: str):
    c = httpx.Client(base_url=BASE, timeout=30)
    heartbeat(c)
    now = datetime.now(TZ)
    msgs = [
        (SARAH, None, False, "We need milk and bread"),
        (SARAH, None, False, "Can you grab eggs tomorrow?"),
        (SARAH, None, False, "Don't forget the water bill is due today"),
        (SARAH, None, True, "I'll send you the photos tonight"),
        (SARAH, None, False, "I'll check with the babysitter and get back to you"),
        (SARAH, None, False, "I'd love a kindle for my birthday! Also my ring size is 6 btw"),
        (SARAH, None, False, "We should try the new taco place on Main"),
        (SARAH, None, False, "Dentist moved to Thursday 3:30"),
        (None, FAMILY, False, "Can someone pick up Emma tomorrow at 3:15?"),
        (SARAH, None, False, "maybe get the plumber to look at the sink"),
        (SARAH, None, False, "we should do our taxes before the end of the month"),
        (SARAH, None, False, "The gutters are overflowing again"),
    ]
    for i, (handle, chat, mine, text) in enumerate(msgs):
        r = c.post("/api/events?sync=true", headers=AUTH, json={
            "event_id": f"imessage:{1000 + i}", "source": "imessage", "sender_handle": handle or "+17855550001",
            "sender_label": "Sarah" if handle else "Dad", "chat_id": chat, "is_from_me": mine,
            "received_at": (now - timedelta(minutes=5 * (len(msgs) - i))).isoformat(), "text": text})
        r.raise_for_status()
    run_mac(c)
    soon = (now + timedelta(minutes=90)).replace(second=0, microsecond=0)
    soon = soon.replace(minute=0 if soon.minute < 30 else 30)

    def at(n, h, m):
        return datetime.combine(now.date() + timedelta(days=n), datetime.min.time(), TZ).replace(hour=h, minute=m).isoformat()

    c.post("/api/agent/snapshot", headers=AUTH, json={
        "events": [
            {"id": "ext-1", "title": "Soccer practice", "start": soon.isoformat(), "end": (soon + timedelta(hours=1)).isoformat(),
             "calendar": "Family", "calendar_color": "#34C759", "location": "Riverside Park"},
            {"id": "ext-2", "title": "Book club", "start": at(3, 19, 30), "end": at(3, 21, 0),
             "calendar": "Personal", "calendar_color": "#FF9500"}],
        "reminders": [{"id": "rem-1", "title": "Renew passport", "list": "Personal", "due": day(2), "list_color": "#007AFF"}]})
    c.post("/api/today/repick")
    run_mac(c)
    # one stale item for the weekly reset
    con = sqlite3.connect(db_path)
    old = (datetime.now(TZ) - timedelta(days=12)).astimezone(ZoneInfo("UTC")).isoformat()
    con.execute("UPDATE items SET created_at=?, updated_at=? WHERE title='Clean the gutters'", (old, old))
    con.commit()
    con.close()
    return c


def main():
    tmp = Path(os.environ.get("DEVHOST_DIR") or tempfile.mkdtemp(prefix="secondbrain-"))
    tmp.mkdir(parents=True, exist_ok=True)
    db = tmp / "brain.db"
    for f in tmp.glob("brain.db*"):
        f.unlink()
    cfg = tmp / "config.yaml"
    cfg.write_text(f"""
timezone: America/Chicago
llm: {{base_url: "http://127.0.0.1:8001/v1", model: "Qwen/Qwen3-32B"}}
watch:
  imessage:
    allow_self_notes: true
    allow:
      - {{handle: "{SARAH}", label: "Sarah"}}
      - {{chat_id: "{FAMILY}", label: "Family group"}}
rules: {{reminder_list: Household}}
security: {{agent_token: {TOKEN}}}
storage: {{db_path: {db}, backup_dir: {tmp / 'backups'}}}
dashboard: {{public_url: "http://127.0.0.1:{PORT}"}}
push: {{quiet_start: "", quiet_end: ""}}
""")
    threading.Thread(target=HTTPServer(("127.0.0.1", 8001), FakeModel).serve_forever, daemon=True).start()
    env = {**os.environ, "HA_CONFIG": str(cfg)}
    server = subprocess.Popen([sys.executable, "-m", "uvicorn", "app.main:factory", "--factory", "--host", "127.0.0.1",
                               "--port", str(PORT), "--log-level", "warning"], cwd=ROOT / "brain", env=env)
    for _ in range(60):
        try:
            if httpx.get(f"{BASE}/api/v1/info", timeout=1).status_code == 200:
                break
        except httpx.HTTPError:
            time.sleep(0.5)
    else:
        server.kill()
        sys.exit("brain did not start")
    c = seed(str(db))
    print(f"devhost ready on {BASE} (data in {tmp})", flush=True)
    try:
        while server.poll() is None:
            time.sleep(60)
            heartbeat(c)
            run_mac(c)
    except KeyboardInterrupt:
        pass
    finally:
        server.terminate()


if __name__ == "__main__":
    main()
