"""Round 2: Today as a timeline, "Show on Today", your own reminders, people from Contacts,
routing to your lists and skipping duplicates."""
import base64

from conftest import AUTH, event, extraction, reminder
from test_api_v1 import save
from test_items import act, day, items, post, run_mac

J = {"X-Requested-With": "fetch"}
JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 100 + b"\xff\xd9"

CATALOG = [
    {"title": "Family", "color": "#FF9500", "kind": "event", "account": "iCloud"},
    {"title": "Personal", "color": "#0A7AFF", "kind": "event", "account": "iCloud"},
    {"title": "Work", "color": "#34C759", "kind": "event", "account": "Exchange"},
    {"title": "Birthdays", "color": "#8E8E93", "kind": "event", "account": None},
    {"title": "Household", "color": "#0A7AFF", "kind": "reminder", "account": "iCloud"},
    {"title": "⏳ Waiting on", "color": "#0E8C96", "kind": "reminder", "account": "iCloud"},
    {"title": "Groceries", "color": "#FF9500", "kind": "reminder", "account": "iCloud"},
    {"title": "Work", "color": "#8E8E93", "kind": "reminder", "account": "iCloud"},
]


def snapshot(client, **over):
    body = {
        "events": [
            {"id": "E-coffee", "title": "Coffee with Jen", "start": f"{day(-1)}T09:00:00-06:00",
             "end": f"{day(-1)}T09:45:00-06:00", "calendar": "Personal", "calendar_color": "#0A7AFF"},
            {"id": "E-book/1", "title": "Book club", "start": f"{day(1)}T19:00:00-06:00",
             "end": f"{day(1)}T21:00:00-06:00", "calendar": "Personal", "calendar_color": "#0A7AFF",
             "location": "Library"},
            {"id": "E-standup", "title": "Standup", "start": f"{day(1)}T08:30:00-06:00",
             "end": f"{day(1)}T08:45:00-06:00", "calendar": "Work", "calendar_color": "#34C759"},
            {"id": "E-pic", "title": "Emma's picture day", "start": f"{day(1)}T00:00:00-06:00",
             "end": f"{day(2)}T00:00:00-06:00", "all_day": True, "calendar": "Family", "calendar_color": "#FF9500"},
        ],
        "reminders": [
            {"id": "R-reg", "title": "Renew car registration", "list": "Work", "list_color": "#8E8E93",
             "due": day(1), "due_time": "13:00"},
            {"id": "R-late", "title": "Return library books", "list": "Groceries", "due": day(-2)},
            {"id": "R-milk", "title": "Milk", "list": "Groceries", "list_color": "#FF9500"},
            {"id": "R-eggs", "title": "Eggs", "list": "Groceries", "list_color": "#FF9500"},
        ],
        "calendars": CATALOG,
    }
    body.update(over)
    r = client.post("/api/agent/snapshot", headers=AUTH, json=body)
    assert r.status_code == 200, r.text
    return r.json()


def g(client, url):
    r = client.get(url, headers=J)
    assert r.status_code == 200, r.text
    return r.json()


def test_snapshot_keeps_catalog_and_undated(client):
    assert snapshot(client)["reminders"] == 4
    # a later snapshot without the catalog (older Mac) keeps the one we had
    client.post("/api/agent/snapshot", headers=AUTH, json={"events": [], "reminders": []})
    s = g(client, "/api/v1/sources")
    assert [c["name"] for c in s["calendars"]][0] == "Family"  # ours first
    assert {c["name"] for c in s["calendars"]} == {"Family", "Personal", "Work", "Birthdays"}


def test_sources_and_hiding(client):
    snapshot(client)
    s = g(client, "/api/v1/sources")
    fam = next(c for c in s["calendars"] if c["name"] == "Family")
    assert fam["ours"] and fam["shown"] and fam["color"] == "#FF9500" and fam["account"] == "iCloud"
    lists = {c["name"]: c for c in s["lists"]}
    assert lists["Household"]["ours"] and lists["⏳ Waiting on"]["ours"]
    assert not lists["Groceries"]["ours"] and lists["Groceries"]["count"] == 3
    assert [c["name"] for c in s["lists"]][:2] == ["Household", "⏳ Waiting on"]

    t = g(client, f"/api/v1/timeline?day={day(1)}")
    assert "Standup" in [e["title"] for e in t["entries"]]
    s = client.post("/api/v1/sources", headers=J, json={"kind": "calendar", "name": "Work", "shown": False}).json()
    assert not next(c for c in s["calendars"] if c["name"] == "Work")["shown"]
    t = g(client, f"/api/v1/timeline?day={day(1)}")
    titles = [e["title"] for e in t["entries"]]
    assert "Standup" not in titles and "Renew car registration" in titles  # the Work *list* is separate
    # ours can't be hidden
    s = client.post("/api/v1/sources", headers=J, json={"kind": "list", "name": "Household", "shown": False}).json()
    assert next(c for c in s["lists"] if c["name"] == "Household")["shown"]
    assert client.post("/api/v1/sources", headers=J, json={"kind": "nope", "name": "x", "shown": True}).status_code == 422
    client.post("/api/v1/sources", headers=J, json={"kind": "calendar", "name": "Work", "shown": True})
    assert "Standup" in [e["title"] for e in g(client, f"/api/v1/timeline?day={day(1)}")["entries"]]


def test_timeline_places_events_and_reminders(client, llm):
    snapshot(client)
    llm.responder = lambda p: extraction(event("Soccer practice", f"{day(1)}T10:00", f"{day(1)}T11:00"),
                                         reminder("Pack a bag for the kids", due=day(1), time="07:30"),
                                         act("track_promise", title="Send Wife the photos", due_date=day(1)),
                                         reminder("Paint the fence", due=day(1)))
    post(client, event_id="imessage:1", text="soccer at 10 tomorrow, pack a bag", is_from_me=False)
    run_mac(client)
    fence = next(i for i in items(client) if i["title"].startswith("Paint the fence"))
    client.app_state.db.execute("UPDATE items SET state=json_set(state, '$.due', ?) WHERE item_id=?",
                                (day(-3), fence["item_id"]))
    t = g(client, f"/api/v1/timeline?day={day(1)}")
    assert t["date"] == day(1) and len(t["week"]) == 7 and t["added_today"] >= 3
    by = {e["title"]: e for e in t["entries"]}
    assert any(k.startswith("Soccer") for k in by), (list(by), client.get("/api/events/imessage:1").json()["event"])
    soccer = by["Soccer practice · Wife"] if "Soccer practice · Wife" in by else by["Soccer practice"]
    assert soccer["kind"] == "event" and soccer["ours"] and soccer["id"].startswith("item:")
    assert soccer["color"] == "#FF9500" and soccer["calendar"] == "Family" and not soccer["past"]
    assert soccer["person"]["label"] == "Wife" and soccer["source_at"]
    book = by["Book club"]
    assert not book["ours"] and book["id"] == "apple:E-book/1" and book["location"] == "Library"
    assert [e["title"] for e in t["all_day"]] == ["Emma's picture day"]
    # in time order, events before reminders at the same minute
    ats = [e["at"] for e in t["entries"]]
    assert ats == sorted(ats)
    photos = next(e for e in t["entries"] if e["title"].startswith("Send Wife the photos"))
    assert photos["all_day"] and photos["ours"] and photos["kind"] == "reminder"  # no time on another day → "Anytime", at the end
    assert t["entries"][-1]["all_day"]
    # week strip counts that day
    wk = {w["date"]: w["count"] for w in t["week"]}
    assert wk[day(1)] == len(t["entries"]) + len(t["all_day"])

    today = g(client, "/api/v1/timeline")
    carried = {e["title"]: e for e in today["entries"] if e["carried"]}
    assert carried["Return library books"]["late"] and carried["Return library books"]["at"] == today["now"]
    assert any(k.startswith("Paint the fence") for k in carried)
    # past days: everything has ended
    y = g(client, f"/api/v1/timeline?day={day(-1)}")
    coffee = next(e for e in y["entries"] if e["title"] == "Coffee with Jen")
    assert coffee["past"] and not any(e["carried"] for e in y["entries"])


def test_banner_and_fixtures(client, llm):
    client.post("/api/agent/avatars", headers=AUTH, json={"people": [
        {"handle": "+17855550000", "name": "Sarah Smith", "image": base64.b64encode(JPEG).decode(), "image_hash": "abc"}]})
    snapshot(client)
    llm.responder = lambda p: extraction(reminder("Pick up the dry cleaning", due=day(1), time="09:00"),
                                         reminder("Return the package", due=day(1)))
    post(client, event_id="imessage:1", text="dry cleaning tomorrow and the package")
    run_mac(client)
    pkg = next(i for i in items(client) if i["title"].startswith("Return the package"))
    client.app_state.db.execute("UPDATE items SET state=json_set(state, '$.due', ?) WHERE item_id=?",
                                (day(-1), pkg["item_id"]))  # it's late now
    assert g(client, "/api/v1/timeline")["banner"] is None
    llm.responder = lambda p: extraction(reminder("Call the plumber", due=day(1)), conf=0.5)
    post(client, event_id="imessage:2", text="maybe get the plumber to look at the sink")
    t = g(client, "/api/v1/timeline")
    b = t["banner"]
    assert b["count"] == 1 and b["entry"]["event"]["text"].startswith("maybe get the plumber")
    assert b["entry"]["proposals"][0]["title"].startswith("Call the plumber") and b["entry"]["reasons"]
    assert b["entry"]["event"]["photo"].startswith("/avatars/")
    p = next(e for e in t["entries"] if e["title"].startswith("Return the package"))
    assert p["person"]["photo"].startswith("/avatars/") and p["carried"]
    save("timeline", t)
    save("sources", g(client, "/api/v1/sources"))


def test_tick_and_move_your_own_reminder(client):
    snapshot(client)
    r = client.post("/api/v1/apple/R-reg/done", headers=J, json={"done": True}).json()
    assert r == {"ok": True, "status": "completed"}
    cmd = run_mac(client)[0]
    assert cmd["op"] == "update_item" and cmd["payload"]["apple_item_id"] == "R-reg"
    assert cmd["payload"]["changes"] == {"completed": True}
    reg = next(e for e in g(client, f"/api/v1/timeline?day={day(1)}")["entries"] if e["apple_id"] == "R-reg")
    assert reg["done"]
    client.post("/api/v1/apple/R-reg/done", headers=J, json={"done": False})
    assert run_mac(client)[0]["payload"]["changes"] == {"completed": False}
    reg = next(e for e in g(client, f"/api/v1/timeline?day={day(1)}")["entries"] if e["apple_id"] == "R-reg")
    assert not reg["done"]

    r = client.post("/api/v1/apple/R-reg/move", headers=J, json={"due": day(2), "due_time": "15:30"}).json()
    assert r["ok"] and "3:30 PM" in r["label"]
    c = run_mac(client)[0]["payload"]["changes"]
    assert c["due"] == day(2) and c["due_time"] == "15:30" and c["alert"].startswith(f"{day(2)}T15:30")
    moved = next(e for e in g(client, f"/api/v1/timeline?day={day(2)}")["entries"] if e["apple_id"] == "R-reg")
    assert moved["due_time"] == "15:30"
    assert client.post("/api/v1/apple/R-reg/move", headers=J, json={"due": "soon"}).status_code == 422
    # the next real snapshot replaces the optimistic copy; ticks it applied drop out of ext_done
    client.post("/api/v1/apple/R-milk/done", headers=J, json={})
    snapshot(client, reminders=[{"id": "R-eggs", "title": "Eggs", "list": "Groceries"}])
    assert client.app_state.db.kv_get("ext_done") == []
    # the old endpoint still works
    assert client.post("/api/external/R-eggs/done", headers=J).json()["ok"]


def test_add_and_remove_person_from_contacts(client, llm):
    body = {"name": "Grandma Jones", "label": "Grandma", "handle": "+1 (312) 555-0199",
            "photo": base64.b64encode(JPEG).decode()}
    r = client.post("/api/v1/people", headers=J, json=body)
    assert r.status_code == 200, r.text
    p = r.json()["person"]
    assert p["label"] == "Grandma" and p["photo"].startswith("/avatars/") and p["contact_name"] == "Grandma Jones"
    cfg = client.app_state.cfg
    assert any(a.label == "Grandma" and a.enabled for a in cfg.watch.imessage.allow)
    # watched right away: the Mac's allowlist has it
    assert "+13125550199" in client.get("/api/agent/config", headers=AUTH).json()["allow"]["handles"]
    assert client.post("/api/v1/people", headers=J, json=body).status_code == 409
    assert client.post("/api/v1/people", headers=J, json={**body, "handle": "1234"}).status_code == 400
    # texts from them are read now
    llm.responder = lambda prompt: extraction(reminder("Bring the pie", due=day(1)))
    assert post(client, event_id="imessage:9", text="bring the pie tomorrow", handle="+13125550199")["result"] == "queued"
    assert client.delete(f"/api/v1/people/{p['key']}", headers=J).json()["ok"]
    assert not any(a.label == "Grandma" for a in cfg.watch.imessage.allow)
    assert client.delete("/api/v1/people/nope", headers=J).status_code == 404


def test_route_to_your_list(client, llm):
    cfg = client.app_state.cfg
    cfg.rules.route_to_lists = True
    snapshot(client)
    seen = {}

    def responder(prompt):
        seen["p"] = prompt
        return extraction(reminder("Pick up bread", due=day(1), lst="groceries"),
                          reminder("Call the vet", due=day(1), lst="Made Up List"))

    llm.responder = responder
    post(client, text="bread and call the vet tomorrow")
    sys = llm.calls[-1][0]["content"]
    assert "“Groceries”" in sys and "“Work”" in sys and "“Household”" not in sys
    cmds = {c["payload"]["title"]: c["payload"] for c in run_mac(client)}
    bread = next(v for k, v in cmds.items() if k.startswith("Pick up bread"))
    vet = next(v for k, v in cmds.items() if k.startswith("Call the vet"))
    assert bread["list"] == "Groceries" and not bread["create_list_if_missing"]
    assert vet["list"] == "Household"
    cfg.rules.route_to_lists = False
    llm.responder = lambda p: extraction(reminder("Pick up butter", due=day(1), lst="Groceries"))
    post(client, event_id="imessage:2", text="butter")
    assert run_mac(client)[0]["payload"]["list"] == "Household"


def test_skip_duplicates(client, llm):
    client.app_state.cfg.rules.skip_duplicates = True
    snapshot(client)
    llm.responder = lambda p: extraction(reminder("Grab some milk", due=day(1)), reminder("Buy eggs"),
                                         reminder("Pick up bananas", due=day(1)),
                                         event("Book club", f"{day(1)}T19:15", f"{day(1)}T21:00"))
    post(client, text="milk eggs bananas and book club")
    trace = next(t for t in client.app_state.db.get_trace("imessage:1") if t["step"] == "plan")["data"]
    assert "Grab some milk: already on Groceries" in trace["skipped"]
    assert "Buy eggs: already on Groceries" in trace["skipped"]
    assert "Book club: already on Personal" in trace["skipped"]
    made = [c["payload"]["title"] for c in run_mac(client)]
    assert len(made) == 1 and made[0].startswith("Pick up bananas")
    # our own open to-dos count too (from another conversation)
    llm.responder = lambda p: extraction(reminder("Get bananas", due=day(2)), event("Book club meeting", f"{day(1)}T23:00"))
    post(client, event_id="imessage:2", text="bananas again")
    made = [c["payload"]["title"] for c in run_mac(client)]
    assert made and made[0].startswith("Book club meeting")  # 4 hours later = a different event
    assert not any(t.startswith("Get bananas") for t in made)
    # everything skipped → the message is marked skipped, with the reason
    llm.responder = lambda p: extraction(reminder("Milk"))
    post(client, event_id="imessage:3", text="milk")
    ev = client.get("/api/events/imessage:3").json()["event"]
    assert ev["status"] == "skipped" and "already on Groceries" in ev["reason"]
    assert len([i for i in items(client) if i["title"].startswith("Milk")]) == 0
