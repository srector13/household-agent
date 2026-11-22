"""Focus mode: details, timer, the time's-up nudge."""
import asyncio

from conftest import extraction, reminder
from test_items import day, items, post, run_mac
from test_push import pclient, sent  # noqa: F401 — fixtures

J = {"X-Requested-With": "fetch"}


def test_parse_notes():
    from app.focus import parse_notes
    n = ("👤 Sarah · Sat Nov 21\n👉 Start: open the toolbox\nCall about the sink leak\nSarah: “the sink leaks”\n"
         "Steps:\n☐ find the number\n☐ call\n[ha:imessage:1]\n👉 Start: find the plumber's card\nSteps:\n☐ find the number\n☐ book")
    p = parse_notes(n)
    assert p["first_step"] == "find the plumber's card"
    assert p["steps"] == ["find the number", "call", "book"]
    assert p["context"] == "Call about the sink leak"


def test_focus_details_and_next(client, llm):
    llm.responder = lambda p: extraction(reminder("Call the plumber", due=day(0)), reminder("Buy stamps"))
    post(client, text="call the plumber today, and we need stamps")
    run_mac(client)
    a, b = sorted((i for i in items(client)), key=lambda i: i["title"])[::-1][:2]  # Call…, Buy…
    d = client.get(f"/api/focus/{a['item_id']}", headers=J).json()
    assert d["ok"] and d["title"] == "Call the plumber" and d["person"] == "Wife" and d["timer"] is None
    assert d["next"]["item_id"] == b["item_id"]
    assert client.get("/api/focus/nope", headers=J).status_code == 404


def test_timer_and_times_up_push(pclient, sent):
    client, llm = pclient, pclient.llm
    llm.responder = lambda p: extraction(reminder("Call the plumber"))
    post(client, text="call the plumber")
    run_mac(client)
    it = items(client)[0]
    t = client.post("/api/focus/timer", headers=J, json={"item_id": it["item_id"], "minutes": 500}).json()["timer"]
    assert t["minutes"] == 90  # capped
    assert client.get(f"/api/focus/{it['item_id']}", headers=J).json()["timer"]["ends_at"] == t["ends_at"]
    f = client.app_state.focus
    n = asyncio.run(f.times_up(t))
    assert n == 1 and "Done, or keep going?" in sent[-1]["body"] and sent[-1]["url"] == f"/?focus={it['item_id']}"
    # a replaced/stopped timer doesn't nudge
    client.post("/api/focus/timer", headers=J, json={"stop": True})
    assert asyncio.run(f.times_up(t)) == 0
    # finishing the task stops its timer
    client.post("/api/focus/timer", headers=J, json={"item_id": it["item_id"], "minutes": 10})
    client.post(f"/api/items/{it['item_id']}/done", headers=J, json={"done": True})
    assert f.timer() is None
    assert "focus" in [h["action"] for h in client.app_state.pipeline.items.history(it["item_id"])]


def test_home_offers_focus(client, llm):
    llm.responder = lambda p: extraction(reminder("Call the plumber", due=day(0)))
    post(client, text="call the plumber today")
    run_mac(client)
    it = items(client)[0]
    d = client.app_state.daily
    d.save_plan(d.today(), {"picks": [{"item_id": it["item_id"], "title": it["title"]}]})
    t = client.get("/").text
    assert f'data-focus="{it["item_id"]}"' in t and "focusFirst()" in t and "/static/focus.js" in t
