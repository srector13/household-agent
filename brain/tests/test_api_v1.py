"""JSON API for the iPhone app: every screen's data, in stable shapes.

Run with WRITE_FIXTURES=1 to refresh the sample responses the Swift tests decode
(ios/SecondBrainKit/Tests/SecondBrainKitTests/Fixtures).
"""
import base64
import json
import os
from pathlib import Path

from conftest import AUTH, extraction, reminder
from test_items import act, day, items, post, run_mac

J = {"X-Requested-With": "fetch"}
FIXTURES = Path(__file__).resolve().parents[2] / "ios/SecondBrainKit/Tests/SecondBrainKitTests/Fixtures"


def save(name, data):
    if os.environ.get("WRITE_FIXTURES"):
        FIXTURES.mkdir(parents=True, exist_ok=True)
        (FIXTURES / f"{name}.json").write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def seed(client, llm):
    jpeg = b"\xff\xd8\xff\xe0" + b"\x00" * 100 + b"\xff\xd9"
    client.post("/api/agent/avatars", headers=AUTH, json={"people": [
        {"handle": "+17855550000", "name": "Sarah Smith", "image": base64.b64encode(jpeg).decode(), "image_hash": "abc"}]})
    llm.responder = lambda p: extraction(reminder("Call the plumber", due=day(0), time="15:00"),
                                         act("track_promise", title="Send Wife the photos", due_date=day(1)))
    post(client, event_id="imessage:1", text="call the plumber at 3 today, and send me the photos")
    llm.responder = lambda p: extraction(act("save_to_collection", collection="gift_ideas", title="Kindle",
                                             url="https://example.com/k"))
    post(client, event_id="imessage:2", text="I'd love a kindle")
    run_mac(client)
    llm.responder = lambda p: extraction(reminder("Maybe paint the fence", due=day(-2)))
    post(client, event_id="imessage:3", text="we should paint the fence sometime")  # past date → review
    client.post("/api/agent/snapshot", headers=AUTH, json={"events": [
        {"id": "E1/2026", "title": "Dentist", "start": f"{day(1)}T09:00:00-06:00", "end": f"{day(1)}T10:00:00-06:00",
         "calendar": "Home", "calendar_color": "#34C759", "location": "Main St"}], "reminders": [
        {"id": "R1", "title": "Renew passport", "list": "Personal", "due": day(2)}]})
    by = {i["title"]: i for i in items(client)}
    d = client.app_state.daily
    d.save_plan(d.today(), {"picks": [{"item_id": by["Call the plumber"]["item_id"], "title": "Call the plumber",
                                       "why": "due today", "first_step": "Find the card"}]})
    return by


def test_every_screen(client, llm):
    by = seed(client, llm)
    g = lambda u: client.get(u, headers=J)  # noqa: E731

    info = g("/api/v1/info").json()
    assert info["app_name"] == "Second Brain" and info["review_count"] == 1 and info["badge"] == 2
    save("info", info)

    h = g("/api/v1/home").json()
    assert h["picks"][0]["title"] == "Call the plumber" and h["picks"][0]["first_step"] == "Find the card"
    assert h["attention"]["reviews"][0]["titles"] == ["Maybe paint the fence"]
    assert h["attention"]["reviews"][0]["event"]["photo"].startswith("/avatars/")
    titles = [a["title"] for a in h["agenda"]]
    assert "Dentist" in titles and "Renew passport" in titles
    dentist = next(a for a in h["agenda"] if a["title"] == "Dentist")
    assert dentist["external"] and dentist["apple_id"] == "E1/2026" and dentist["color"] == "#34C759"
    assert h["recent"] and {"verb", "title", "at"} <= set(h["recent"][0])
    save("home", h)

    t = g("/api/v1/today").json()
    assert t["picks"][0]["status"] == "active" and isinstance(t["candidates"], list)
    save("today", t)

    pl = g("/api/v1/people").json()["people"]
    sarah = next(p for p in pl if p["contact_name"] == "Sarah Smith")
    assert sarah["photo"] and sarah["contact_name"] == "Sarah Smith"
    save("people", {"people": pl})
    pd = g(f"/api/v1/people/{sarah['key']}").json()
    assert [i["title"] for i in pd["gifts"]] == ["Kindle"] and pd["gifts"][0]["url"] == "https://example.com/k"
    assert pd["messages"][0]["text"].startswith("call the plumber")  # oldest first, like a chat
    save("person", pd)
    assert g("/api/v1/people/nope").status_code == 404

    li = g("/api/v1/items").json()
    plumber = next(i for i in li["items"] if i["title"] == "Call the plumber")
    assert plumber["due"] == day(0) and plumber["due_time"] == "15:00" and plumber["origin"]["sender"] == "Wife"
    assert plumber["log"][0]["action"] in ("planned", "proposed")
    save("items_todos", li)
    co = g("/api/v1/items?tab=collections").json()
    assert co["groups"][0]["label"].endswith("Gift ideas") and co["groups"][0]["people"][0]["items"][0]["title"] == "Kindle"
    save("items_collections", co)
    save("items_history", g("/api/v1/items?tab=history").json())

    rv = g("/api/v1/review").json()["items"]
    assert rv[0]["proposals"][0]["title"] == "Maybe paint the fence" and rv[0]["reasons"]
    save("review", {"items": rv})

    a = g("/api/v1/activity").json()
    assert len(a["events"]) == 3 and a["counts"]["needs_review"] == 1
    save("activity", a)
    assert len(g("/api/v1/activity?status=needs_review").json()["events"]) == 1

    ev = g("/api/v1/events/imessage:1").json()
    assert ev["can"]["undo"] and not ev["can"]["approve"]
    assert [t["label"] for t in ev["trace"]][:2] == ["Received", "Allowlist"]
    assert {i["title"] for i in ev["items"]} == {"Call the plumber", "Send Wife the photos"}
    assert '"actions"' in ev["extraction"]
    save("event", ev)
    evr = g("/api/v1/events/imessage:3").json()
    assert evr["can"]["approve"] and evr["reasons"]
    assert g("/api/v1/events/nope").status_code == 404

    s = g("/api/v1/system").json()
    assert "online" in s["health"]["agent"] and "funnel" in s and isinstance(s["alerts"], list)
    save("system", s)

    w = g("/api/v1/weekly").json()
    assert w["cards"] == [] and "due" in w
    save("weekly", w)

    st = g("/api/settings").json()
    assert "daily.weekly_day" in st["values"]
    save("settings", st)


def test_notifications_feed(client, llm):
    llm.responder = lambda p: extraction(reminder("Pick up eggs", due=day(1)))
    post(client, text="grab eggs tomorrow?")
    run_mac(client)
    import asyncio
    client.app_state.cfg.push.quiet_start = client.app_state.cfg.push.quiet_end = ""  # independent of the clock
    push = client.app_state.push
    asyncio.run(push.send("review", "Check this — Wife", "Maybe paint the fence", url="/review"))
    f = client.get("/api/v1/notifications", headers=J).json()
    assert f["items"][-1]["title"] == "Check this — Wife" and f["items"][-1]["url"] == "/review"
    last = f["last_id"]
    assert client.get(f"/api/v1/notifications?after={last}", headers=J).json()["items"] == []
    # switched-off kinds don't reach the app either
    client.app_state.cfg.push.review = False
    asyncio.run(push.send("review", "Nope", "x"))
    assert client.get(f"/api/v1/notifications?after={last}", headers=J).json()["items"] == []
    save("notifications", f)


def test_requires_password_when_set(client):
    client.app_state.cfg.dashboard.password = "pw"
    assert client.get("/api/v1/home").status_code == 401
    assert client.get("/api/v1/home", auth=("me", "pw")).status_code == 200
