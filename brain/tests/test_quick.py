"""Quick actions from the app: snooze, pick a date, delete + undo, and the swipe markup."""
from datetime import datetime, timedelta, timezone

from conftest import extraction, reminder
from test_items import day, items, post, run_mac

J = {"X-Requested-With": "fetch"}


def make(client, llm, title="Call the plumber", **kw):
    llm.responder = lambda p: extraction(reminder(title, **kw))
    post(client, text=f"can you {title.lower()}?")
    run_mac(client)
    return next(i for i in items(client) if i["title"] == title)


def test_snooze_options_are_sensible(client):
    q = client.app_state.quick
    tz = client.app_state.cfg.tz
    # Wednesday 10:10 local
    now = datetime(2026, 11, 18, 10, 10, tzinfo=tz)
    o = {x["key"]: x for x in q.snooze_options(now)}
    assert list(o) == ["later", "tonight", "tomorrow", "weekend", "nextweek"]
    assert (o["later"]["due"], o["later"]["due_time"]) == ("2026-11-18", "13:00")
    assert o["tonight"]["due_time"] == "19:00"
    assert o["tomorrow"]["due"] == "2026-11-19"
    assert o["weekend"]["due"] == "2026-11-21" and o["nextweek"]["due"] == "2026-11-23"
    # late Friday evening: no "later today"/"this evening", weekend is tomorrow so it's skipped
    late = {x["key"] for x in q.snooze_options(datetime(2026, 11, 20, 21, 30, tzinfo=tz))}
    assert late == {"tomorrow", "nextweek"}
    # Sunday: next week is tomorrow (Monday)
    sun = {x["key"]: x for x in q.snooze_options(datetime(2026, 11, 22, 9, 0, tzinfo=tz))}
    assert sun["nextweek"]["due"] == "2026-11-23" and sun["weekend"]["due"] == "2026-11-28"


def test_snooze_queues_update_and_logs_once(client, llm):
    it = make(client, llm, due=day(0))
    o = client.get(f"/api/items/{it['item_id']}/snooze-options", headers=J).json()
    assert o["kind"] == "reminder" and o["options"]
    r = client.post(f"/api/items/{it['item_id']}/snooze", headers=J, json={"key": "tomorrow"}).json()
    assert r["ok"] and r["due"] == day(1) and r["label"].startswith("Tomorrow")
    cmd = run_mac(client)[0]
    assert cmd["op"] == "update_item" and cmd["payload"]["changes"]["due"] == day(1)
    assert cmd["payload"]["changes"]["alert"].startswith(day(1))
    got = client.app_state.pipeline.items.get(it["item_id"])
    assert got["state"]["due"] == day(1) and got["status"] == "active"
    actions = [h["action"] for h in client.app_state.pipeline.items.history(it["item_id"])]
    assert actions.count("snoozed") == 1 and "updated" not in actions
    bad = client.post(f"/api/items/{it['item_id']}/snooze", headers=J, json={"key": "nope"})
    assert bad.status_code == 422


def test_pick_date_and_clear(client, llm):
    it = make(client, llm)
    r = client.post(f"/api/items/{it['item_id']}/reschedule", headers=J, json={"due": day(3), "due_time": "08:15"}).json()
    assert r["ok"] and r["due_time"] == "08:15"
    cmd = run_mac(client)[0]
    assert cmd["payload"]["changes"]["alert"].startswith(day(3) + "T08:15")
    r = client.post(f"/api/items/{it['item_id']}/reschedule", headers=J, json={"due": None}).json()
    assert r["label"] == "No date"
    assert run_mac(client)[0]["payload"]["changes"] == {"due": None, "due_time": None, "alert": None}
    assert client.post(f"/api/items/{it['item_id']}/reschedule", headers=J, json={"due": "soon"}).status_code == 422


def test_move_event_keeps_length(client, llm):
    from conftest import event as ev_action
    llm.responder = lambda p: extraction(ev_action("Dentist", f"{day(2)}T10:00", f"{day(2)}T11:30"))
    post(client, text="dentist thursday at 10")
    run_mac(client)
    it = next(i for i in items(client) if i["title"] == "Dentist")
    r = client.post(f"/api/items/{it['item_id']}/reschedule", headers=J, json={"start": f"{day(3)}T14:00"}).json()
    assert r["ok"]
    ch = run_mac(client)[0]["payload"]["changes"]
    assert ch["start"].startswith(f"{day(3)}T14:00") and ch["end"].startswith(f"{day(3)}T15:30")


def test_delete_and_undo(client, llm):
    it = make(client, llm)
    assert client.post(f"/api/items/{it['item_id']}/delete", headers=J).json()["status"] == "cancelled"
    cmd = run_mac(client)[0]
    assert cmd["op"] == "delete_item" and cmd["payload"]["apple_item_id"] == it["apple_item_id"]
    assert client.app_state.pipeline.items.get(it["item_id"])["status"] == "cancelled"
    assert client.post(f"/api/items/{it['item_id']}/delete", headers=J).status_code == 422
    assert client.post(f"/api/items/{it['item_id']}/restore", headers=J).json()["ok"]
    cmd = run_mac(client)[0]
    assert cmd["op"] == "create_reminder" and cmd["payload"]["title"] == "Call the plumber"
    assert client.app_state.pipeline.items.get(it["item_id"])["status"] == "active"


def test_delete_before_it_reaches_the_mac(client, llm):
    llm.responder = lambda p: extraction(reminder("Buy stamps"))
    post(client, text="we need stamps")
    it = next(i for i in items(client) if i["title"] == "Buy stamps")
    client.post(f"/api/items/{it['item_id']}/delete", headers=J)
    assert run_mac(client) == []  # never sent


def test_snoozed_pick_leaves_today(client, llm):
    it = make(client, llm, due=day(0))
    d = client.app_state.daily
    today = d.today()
    d.save_plan(today, {"picks": [{"item_id": it["item_id"], "title": it["title"]}], "moved": {it["item_id"]: {"due": None}}})
    client.post(f"/api/items/{it['item_id']}/snooze", headers=J, json={"key": "nextweek"})
    plan = d.plan(today)
    assert plan["picks"][0]["snoozed_to"] and it["item_id"] not in plan["moved"]
    page = client.get("/").text
    assert "Moved to" in page and "0 of 1 left" in page


def test_rows_are_swipeable(client, llm):
    it = make(client, llm)
    t = client.get("/items").text
    assert f'data-swipe data-id="{it["item_id"]}" data-kind="reminder"' in t and "data-item-menu" in t
    js = client.get("/static/app.js").text
    assert "HA.swipeInit" in js and "/snooze-options" in js and "/restore" in js
