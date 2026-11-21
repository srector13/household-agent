"""Promises, waiting-on, notes-to-self, first steps, completion sync, and the daily rhythm."""
from datetime import datetime, timedelta, timezone

from conftest import AUTH, TZ, extraction, msg, reminder
from test_items import act, day, items, post, run_mac

J = {"X-Requested-With": "fetch"}


def test_my_promise_becomes_a_todo(client, llm):
    llm.responder = lambda p: extraction(act("track_promise", title="Send Wife the photos", due_date=day(0),
                                             due_time="20:00", summary="You told Wife you'd send them tonight."))
    res = post(client, text="I'll send you the photos tonight", is_from_me=True)
    assert res["result"] == "queued"
    p = run_mac(client)[0]["payload"]
    assert p["list"] == "Household" and p["title"] == "Send Wife the photos"
    assert p["notes"].startswith("🤝 You promised Wife · ") and p["tags"] == ["Wife"]
    it = items(client)[0]
    assert it["category"] == "promise"
    # keeping the promise later closes it
    seen = {}
    llm.responder = lambda prompt: seen.setdefault("p", prompt) and extraction(act("complete_item", 1))
    post(client, event_id="imessage:2", text="here you go! (photos)", is_from_me=True)
    assert "1. My promise to Wife: “Send Wife the photos”" in seen["p"]
    run_mac(client)
    assert items(client)[0]["status"] == "completed"


def test_promise_from_them_is_just_a_todo(client, llm):
    llm.responder = lambda p: extraction(act("track_promise", title="Call the bank"))
    post(client, text="can you call the bank")
    assert items(client)[0]["category"] == "todo"


def test_waiting_on_with_and_without_a_date(client, llm):
    llm.responder = lambda p: extraction(act("waiting_on", title="Babysitter answer from Wife", due_date=day(3)))
    post(client, event_id="imessage:1", text="I'll find out about the babysitter and get back to you")
    p = run_mac(client)[0]["payload"]
    assert p["list"] == "⏳ Waiting on" and p["section"] == "Wife" and p["due"] == day(3)
    assert p["notes"].startswith("⏳ Waiting on Wife") and p["alert"].startswith(day(3) + "T16:00")
    llm.responder = lambda p: extraction(act("waiting_on", title="Deck quote from Bob", person="Bob"))
    post(client, event_id="imessage:2", text="Bob said he'll send the deck quote")
    p = run_mac(client)[0]["payload"]
    assert p["section"] == "Bob" and p["due"] == day(3)  # default follow-up = 3 days


def test_notes_to_self_thread(client, llm):
    allow = client.get("/api/settings").json()["values"]["watch.imessage.allow"]
    allow.append({"handle": "+1 555 123 4567", "label": "Me"})  # label "Me" → is_me automatically
    client.patch("/api/settings", json={"watch": {"imessage": {"allow": allow}}})
    assert client.app_state.cfg.watch.imessage.allow[-1].is_me
    seen = {}

    def responder(prompt):
        seen["p"] = prompt
        return extraction(reminder("Renew car registration"), act("save_to_collection", collection="someday",
                                                                 title="Garage shelves"))
    llm.responder = responder
    body = msg(event_id="imessage:s1", handle="+15551234567", text="renew registration, also idea: garage shelves",
               is_from_me=True)
    res = client.post("/api/events?sync=true", json=body, headers=AUTH).json()
    assert res["result"] == "queued"  # allow_self_notes is off, but this is the notes-to-self thread
    assert "New note I wrote to MYSELF" in seen["p"]
    cmds = run_mac(client)
    assert cmds[0]["payload"]["notes"].startswith("📝 Note to self") and cmds[0]["payload"]["tags"] == []
    assert cmds[1]["payload"]["section"] is None
    # the received echo of the same text is skipped
    echo = msg(event_id="imessage:s2", handle="+15551234567", text="renew registration, also idea: garage shelves")
    assert client.post("/api/events?sync=true", json=echo, headers=AUTH).json()["reason"] == "duplicate"


def test_first_step_in_notes(client, llm):
    llm.responder = lambda p: extraction(reminder("Do taxes") | {
        "first_step": "Find last year's return", "steps": ["Gather W-2s", "Book the accountant"]})
    post(client, text="we really need to do our taxes")
    notes = run_mac(client)[0]["payload"]["notes"].splitlines()
    assert notes[1] == "👉 Start: Find last year's return"
    assert "☐ Gather W-2s" in notes and "☐ Book the accountant" in notes
    client.patch("/api/settings", json={"rules": {"breakdown": False}})
    post(client, event_id="imessage:2", text="and the car insurance thing")
    assert "👉" not in run_mac(client)[0]["payload"]["notes"]


def test_breakdown_on_demand(client, llm):
    llm.responder = lambda p: extraction(reminder("Clean the garage"))
    post(client, text="the garage is a disaster")
    run_mac(client)
    iid = items(client)[0]["item_id"]
    llm.json_responder = lambda name, m: {"first_step": "Fill one trash bag", "steps": ["Sort the shelf"]}
    r = client.post(f"/api/items/{iid}/breakdown", headers=J).json()
    assert r["ok"] and r["first_step"] == "Fill one trash bag"
    cmd = run_mac(client)[0]
    assert cmd["op"] == "update_item" and cmd["payload"]["changes"] == {}
    assert cmd["payload"]["notes_append"].startswith("👉 Start: Fill one trash bag")
    assert items(client)[0]["state"]["first_step"] == "Fill one trash bag"


# ---- completion sync -----------------------------------------------------------------------------
def _sync(client, rows):
    return client.post("/api/agent/item-status", headers=AUTH, json={"items": rows}).json()


def test_completion_sync(client, llm):
    llm.responder = lambda p: extraction(reminder("Pick up eggs", due=day(1)))
    post(client, text="grab eggs tomorrow")
    run_mac(client)
    tracked = client.get("/api/agent/tracked", headers=AUTH).json()
    assert tracked["items"] == [{"apple_item_id": "A0", "kind": "reminder", "tag": "[ha:imessage:1]"}]
    assert _sync(client, [{"apple_item_id": "A0", "completed": True,
                           "completed_at": datetime.now(timezone.utc).isoformat()}])["updated"] == 1
    it = items(client)[0]
    assert it["status"] == "completed" and it["completed_at"]
    _sync(client, [{"apple_item_id": "A0", "completed": False}])
    assert items(client)[0]["status"] == "active"
    # edited in Reminders
    _sync(client, [{"apple_item_id": "A0", "completed": False, "title": "Pick up 2 dozen eggs", "due": day(2)}])
    it = items(client)[0]
    assert it["title"] == "Pick up 2 dozen eggs" and it["state"]["due"] == day(2)
    # moved (found by tag under a new id)
    _sync(client, [{"apple_item_id": "A0", "found_id": "A0-new", "completed": False}])
    assert items(client)[0]["apple_item_id"] == "A0-new"


def test_deleted_needs_two_reports_and_mass_missing_ignored(client, llm):
    llm.responder = lambda p: extraction(*[reminder(f"Thing {i}") for i in range(6)])
    post(client, text="lots of things to do")
    run_mac(client)
    ids = [f"A{i}" for i in range(6)]
    _sync(client, [{"apple_item_id": i, "exists": False} for i in ids])  # all gone at once → glitch
    assert all(it["status"] == "active" for it in items(client))
    _sync(client, [{"apple_item_id": "A0", "exists": False}])
    assert next(it for it in items(client) if it["apple_item_id"] == "A0")["status"] == "active"
    _sync(client, [{"apple_item_id": "A0", "exists": False}])
    assert next(it for it in items(client) if it["apple_item_id"] == "A0")["status"] == "deleted"
    assert "Thing 0" in client.get("/items?tab=history").text


# ---- daily rhythm --------------------------------------------------------------------------------
def _seed(client, llm):
    llm.responder = lambda p: extraction(reminder("Pay water bill", due=day(0)), reminder("Fix the sink"),
                                         reminder("Plan Emma's party", due=day(10)), reminder("Call the vet"))
    post(client, text="bill today, sink, party planning, vet")
    run_mac(client)
    llm.responder = lambda p: extraction(act("track_promise", title="Send Wife the photos"))
    post(client, event_id="imessage:2", text="I'll send you the photos", is_from_me=True)
    run_mac(client, apple_prefix="P")


def test_candidates_scoring(client, llm):
    _seed(client, llm)
    d = client.app_state.daily
    c = d.candidates(datetime.now(timezone.utc))
    assert c[0]["title"] == "Pay water bill" and "due today" in c[0]["why"]
    assert c[1]["title"] == "Send Wife the photos" and "you promised Wife" in c[1]["why"]


def test_morning_picks_move_into_today_and_evening_restores(client, llm, alerter):
    _seed(client, llm)
    llm.json_responder = lambda name, m: {"picks": [{"n": 1, "why": "due today", "first_step": None},
                                                    {"n": 2, "why": "you promised", "first_step": "Open Photos"},
                                                    {"n": 4, "why": "quick win", "first_step": None}],
                                          "note": "You've got this."}
    r = client.post("/api/today/repick", headers=J).json()
    titles = [p["title"] for p in r["picks"]]
    assert len(titles) == 3 and titles[0] == "Pay water bill" and "Send Wife the photos" in titles
    cmds = run_mac(client)
    # only picks not already due today were moved into Today
    moved = {c["payload"]["tag"] for c in cmds}
    assert all(c["op"] == "update_item" and c["payload"]["changes"]["due"] == day(0) for c in cmds)
    assert len(cmds) == 2
    text = alerter.sent[-1][1]
    assert text.startswith("☀️ **Today's 3**") and "👉 Start: Open Photos" in text and "You've got this." in text
    assert "Pay water bill" in client.get("/today").text

    # one pick gets done on the phone
    pid = next(p["item_id"] for p in r["picks"] if p["title"] == "Send Wife the photos")
    apple = client.app_state.pipeline.items.get(pid)["apple_item_id"]
    _sync(client, [{"apple_item_id": apple, "completed": True, "completed_at": datetime.now(timezone.utc).isoformat()}])
    client.post("/api/today/evening", headers=J)
    restore = run_mac(client)
    assert len(restore) == 1
    fourth = next(p for p in r["picks"] if p["title"] not in ("Pay water bill", "Send Wife the photos"))
    original = {"Fix the sink": None, "Call the vet": None, "Plan Emma's party": day(10)}[fourth["title"]]
    assert restore[0]["payload"]["changes"]["due"] == original  # back to its old date, not overdue
    recap = alerter.sent[-1][1]
    assert "✅ Done (1): Send Wife the photos" in recap and "Moved back off Today" in recap
    assert "Tomorrow I'd suggest" in recap


def test_llm_failure_falls_back_to_scores(client, llm):
    _seed(client, llm)
    llm.json_responder = lambda name, m: RuntimeError("model down")
    r = client.post("/api/today/repick", headers=J).json()
    assert [p["title"] for p in r["picks"]][:2] == ["Pay water bill", "Send Wife the photos"]


def test_preselected_tomorrow_is_used(client, llm):
    _seed(client, llm)
    d = client.app_state.daily
    sink = next(it for it in items(client) if it["title"] == "Fix the sink")
    tomorrow = d.today() + timedelta(days=1)
    client.post("/api/today/tomorrow", headers=J, json={"item_ids": [sink["item_id"]]})
    llm.json_responder = lambda name, m: {"picks": [{"n": 1, "why": "x", "first_step": None},
                                                    {"n": 2, "why": "y", "first_step": None}], "note": ""}
    import asyncio
    now = datetime.combine(tomorrow, datetime.min.time(), TZ).replace(hour=8)
    plan = client.portal.call(lambda: d.morning(now))
    assert plan["picks"][0]["title"] == "Fix the sink" and len(plan["picks"]) == 3


def test_tick_schedule(client, llm, alerter):
    _seed(client, llm)
    d = client.app_state.daily
    llm.json_responder = lambda name, m: RuntimeError("use scores")
    base = datetime.now(TZ).replace(hour=6, minute=0)
    client.portal.call(lambda: d.tick(base))
    assert not d.plan(base.date()).get("picks")          # before morning time
    client.portal.call(lambda: d.tick(base.replace(hour=7, minute=45)))
    assert d.plan(base.date()).get("picks")
    n = len(alerter.sent)
    client.portal.call(lambda: d.tick(base.replace(hour=12)))
    assert len(alerter.sent) == n                        # once only
    client.portal.call(lambda: d.tick(base.replace(hour=21)))
    assert d.plan(base.date()).get("evening_at") and "Wrapping up" in alerter.sent[-1][1]


def test_pages_render(client, llm):
    _seed(client, llm)
    for path in ["/today", "/", "/items", "/items?tab=history", "/settings"]:
        assert client.get(path).status_code == 200, path
