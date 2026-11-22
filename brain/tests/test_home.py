"""Home screen: at-a-glance sections, ticking things off, pipeline moved to Status."""
from datetime import datetime, timedelta

from conftest import AUTH, TZ, event, extraction, reminder
from test_items import act, day, items, post, run_mac

J = {"X-Requested-With": "fetch"}


def test_home_sections(client, llm):
    soon = (datetime.now(TZ) + timedelta(minutes=50)).strftime("%Y-%m-%dT%H:%M")
    llm.responder = lambda p: extraction(event("Dentist appointment", soon), reminder("Pick up eggs", due=day(1)))
    post(client, text="dentist soon and eggs tomorrow")
    run_mac(client)
    llm.responder = lambda p: extraction(reminder("Call the plumber"), conf=0.4)
    post(client, event_id="imessage:2", text="maybe call the plumber")
    t = client.get("/").text
    assert "Up next" in t and "Dentist appointment" in t and "in 4" in t or "in 5" in t   # countdown
    assert "Needs you" in t and "maybe call the plumber" in t
    assert "Coming up" in t and "Pick up eggs" in t
    assert "Just now" in t and "Added" in t
    assert "Everything's running" in t or "Something needs attention" in t
    # pipeline + KPIs live on Status now; no test-lab button at the top of Home
    assert 'data-node="mac"' not in t and "Test a message" not in t
    s = client.get("/system").text
    assert 'data-node="mac"' in s and "Last 14 days" in s and 'href="/lab"' in s


def test_tick_off_from_home(client, llm, alerter):
    llm.responder = lambda p: extraction(reminder("Pay water bill", due=day(0)))
    post(client, text="pay the water bill today")
    run_mac(client)
    llm.json_responder = lambda name, m: RuntimeError("use scores")
    client.post("/api/today/repick", headers=J)
    run_mac(client)
    iid = items(client)[0]["item_id"]
    assert f'data-id="{iid}"' in client.get("/").text
    r = client.post(f"/api/items/{iid}/done", headers=J, json={"done": True}).json()
    assert r == {"ok": True, "status": "completed"}
    cmd = run_mac(client)[0]
    assert cmd["op"] == "update_item" and cmd["payload"]["changes"] == {"completed": True}
    t = client.get("/").text
    assert "0 of 1 left" in t and "All three done" not in t or "Anything else today is a bonus" in t
    # untick
    client.post(f"/api/items/{iid}/done", headers=J, json={"done": False})
    assert run_mac(client)[0]["payload"]["changes"] == {"completed": False}
    assert items(client)[0]["status"] == "active"
    assert client.post("/api/items/nope/done", headers=J, json={"done": True}).status_code == 404


def test_problem_banner_only_when_broken(client):
    t = client.get("/").text
    assert "connected yet" in t
    client.post("/api/agent/heartbeat", headers=AUTH, json={"agent_version": "0.5.0", "fda_ok": True,
                                                            "reminders_ok": True, "calendar_ok": True})
    assert "connected yet" not in client.get("/").text


def test_followups_and_late_promises_need_you(client, llm):
    llm.responder = lambda p: extraction(act("waiting_on", title="Deck quote from Bob", person="Bob", due_date=day(0)))
    post(client, text="Bob will send the deck quote today")
    llm.responder = lambda p: extraction(act("track_promise", title="Send Wife the photos", due_date=day(0)))
    post(client, event_id="imessage:2", text="I'll send you the photos today", is_from_me=True)
    run_mac(client)
    client.app_state.db.execute("UPDATE items SET state = json_set(state, '$.due', ?) WHERE category='promise'", (day(-2),))
    t = client.get("/").text
    assert "Follow up with Bob" in t and "You promised Wife" in t


def test_quick_capture_goes_through_notes_to_self(client, llm):
    seen = {}

    def responder(p):
        seen["p"] = p
        return extraction(reminder("Renew car registration"), act("save_to_collection", collection="someday",
                                                                  title="Garage shelves"))
    llm.responder = responder
    r = client.post("/api/capture", headers=J, json={"text": "renew registration; idea: garage shelves", "sync": True}).json()
    assert r["ok"] and r["result"] == "queued" and r["event_id"].startswith("capture:")
    assert "New note I wrote to MYSELF" in seen["p"]
    cmds = run_mac(client)
    assert cmds[0]["payload"]["notes"].startswith("📝 Note to self") and cmds[0]["payload"]["tags"] == []
    assert items(client)[0]["chat_key"] == "capture"
    assert client.post("/api/capture", headers=J, json={"text": "  "}).status_code == 422
    assert 'class="capture-btn"' in client.get("/").text


def _snap(client, events=None, reminders=None):
    return client.post("/api/agent/snapshot", headers=AUTH, json={"generated_at": datetime.now(TZ).isoformat(),
                                                                   "events": events, "reminders": reminders})


def test_full_picture_includes_my_own_icloud_items(client, llm):
    now = datetime.now(TZ)
    soon = now + timedelta(minutes=40)
    r = _snap(client, events=[
        {"id": "E1", "title": "Team standup", "start": soon.isoformat(), "end": (soon + timedelta(minutes=30)).isoformat(),
         "calendar": "Work", "calendar_color": "#34C759"},
        {"id": "E2", "title": "Made by brain", "start": soon.isoformat(), "end": soon.isoformat(), "ours": True},
        {"id": "E3", "title": "Thanksgiving", "start": (now + timedelta(days=2)).replace(hour=0, minute=0).isoformat(),
         "end": (now + timedelta(days=3)).replace(hour=0, minute=0).isoformat(), "all_day": True, "calendar": "Holidays"},
    ], reminders=[
        {"id": "R1", "title": "Renew passport", "list": "Personal", "due": day(-2)},
        {"id": "R2", "title": "Take out recycling", "list": "Home", "due": day(1)},
        {"id": "R3", "title": "Ours", "list": "Household", "due": day(0), "ours": True},
    ]).json()
    assert r == {"ok": True, "events": 3, "reminders": 3}
    t = client.get("/").text
    assert "Team standup" in t and "Up next" in t                 # my own calendar drives "Up next"
    assert "Renew passport" in t and "Late" in t                   # overdue reminder of mine
    assert "Take out recycling" in t and "Thanksgiving" in t
    assert "Made by brain" not in t and ">Ours<" not in t         # Second Brain's own are not doubled
    assert 'data-ext="R2"' in t
    # null = that kind wasn't readable this time: keep the previous data
    _snap(client, events=None, reminders=[])
    t = client.get("/").text
    assert "Team standup" in t and "Renew passport" not in t


def test_tick_off_my_own_reminder(client):
    _snap(client, events=[], reminders=[{"id": "R9", "title": "Call grandma", "list": "Personal", "due": day(0)}])
    r = client.post("/api/external/R9/done", headers=J).json()
    assert r["ok"]
    cmd = run_mac(client)[0]
    assert cmd["op"] == "update_item" and cmd["payload"] == {"apple_item_id": "R9", "tag": None, "kind": "reminder",
                                                            "changes": {"completed": True}, "notes_append": None}
    assert "Call grandma" not in client.get("/").text


def test_morning_briefing_mentions_my_calendar(client, llm, alerter):
    later = datetime.now(TZ).replace(hour=23, minute=0)
    _snap(client, events=[{"id": "E5", "title": "Book club", "start": later.isoformat(),
                           "end": (later + timedelta(minutes=30)).isoformat(), "calendar": "Personal"}], reminders=[])
    llm.json_responder = lambda name, m: RuntimeError("scores")
    client.post("/api/today/repick", headers=J)
    assert "📅 Also today: Book club" in alerter.sent[-1][1]
