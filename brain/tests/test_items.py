"""Context-aware edits: cancel / complete / reschedule earlier items, my replies, collections, undo."""
from datetime import datetime, timedelta

from conftest import AUTH, TZ, extraction, msg, reminder

J = {"X-Requested-With": "fetch"}


def act(type_, ref=None, **kw):
    base = {k: None for k in ["collection", "person", "due_date", "due_time", "start", "end", "location", "url",
                              "notes", "summary", "calendar", "list"]}
    return {**base, "type": type_, "ref": ref, "title": kw.pop("title", ""), "all_day": False,
            "source_quote": kw.pop("source_quote", "x"), **kw}


def day(n):
    return (datetime.now(TZ).date() + timedelta(days=n)).isoformat()


def post(client, **kw):
    return client.post("/api/events?sync=true", json=msg(**kw), headers=AUTH).json()


def run_mac(client, apple_prefix="A"):
    """Pretend to be the Mac: execute everything queued, return the commands."""
    cmds = client.get("/api/agent/commands?wait=0", headers=AUTH).json()["commands"]
    for i, c in enumerate(cmds):
        client.post(f"/api/agent/commands/{c['command_id']}/result", headers=AUTH,
                    json={"status": "done", "apple_item_id": c["payload"].get("apple_item_id") or f"{apple_prefix}{i}"})
    return cmds


def items(client):
    return client.app_state.pipeline.items.listing(statuses=("proposed", "planned", "active", "completed",
                                                            "cancelled", "undone", "rejected"))


def test_never_mind_cancels_the_earlier_reminder(client, llm):
    llm.responder = lambda p: extraction(reminder("Pick up eggs", due=day(1)))
    post(client, event_id="imessage:1", text="Can you grab eggs tomorrow?")
    run_mac(client)

    seen = {}

    def responder(prompt):
        seen["prompt"] = prompt
        return extraction(act("cancel_item", 1, title="Pick up eggs", source_quote="never mind about the eggs"))

    llm.responder = responder
    res = post(client, event_id="imessage:2", text="Never mind about the eggs, Mom is bringing some")
    assert res["result"] == "queued"
    assert "1. To-do: “Pick up eggs” — due" in seen["prompt"]
    cmd = run_mac(client)[0]
    assert cmd["op"] == "delete_item" and cmd["payload"]["apple_item_id"] == "A0" and cmd["payload"]["tag"] == "[ha:imessage:1]"
    it = items(client)[0]
    assert it["status"] == "cancelled"
    assert [h["action"] for h in client.app_state.pipeline.items.history(it["item_id"])][-1] == "cancelled"
    assert client.get("/api/events/imessage:2").json()["event"]["status"] == "done"
    # cancelled items are no longer offered to the model
    llm.responder = responder
    post(client, event_id="imessage:3", text="also forget the bread")
    assert "(none)" in seen["prompt"].split("Open items")[1].split("Recent")[0]


def test_my_reply_adds_the_date(client, llm):
    llm.responder = lambda p: extraction(reminder("Call the plumber"))
    post(client, event_id="imessage:1", text="Can you call the plumber about the sink?")
    run_mac(client)

    seen = {}

    def responder(prompt):
        seen["prompt"] = prompt
        return extraction(act("update_item", 1, due_date=day(1), summary="You said you'd call tomorrow."))

    llm.responder = responder
    res = post(client, event_id="imessage:2", text="I'll do it tomorrow", is_from_me=True)
    assert res["result"] == "queued"
    assert "New message from ME (the user) to Wife" in seen["prompt"]
    cmd = run_mac(client)[0]
    p = cmd["payload"]
    assert cmd["op"] == "update_item" and p["apple_item_id"] == "A0"
    assert p["changes"]["due"] == day(1) and p["changes"]["alert"].startswith(day(1) + "T16:00")
    assert "You: “I'll do it tomorrow”" in p["notes_append"]
    it = items(client)[0]
    assert it["state"]["due"] == day(1) and it["status"] == "active"


def test_my_messages_ignored_without_open_items(client, llm):
    res = post(client, event_id="imessage:9", text="I'll do it tomorrow", is_from_me=True)
    assert res["result"] == "skipped" and llm.calls == []


def test_my_message_cannot_create(client, llm):
    llm.responder = lambda p: extraction(reminder("Call the plumber"))
    post(client, event_id="imessage:1", text="call the plumber?")
    run_mac(client)
    llm.responder = lambda p: extraction(reminder("Buy a sink"))
    res = post(client, event_id="imessage:2", text="I'll also buy a new sink", is_from_me=True)
    assert res["result"] == "skipped" and "can only change existing items" in res["reason"]


def test_complete_and_undo_complete(client, llm):
    llm.responder = lambda p: extraction(reminder("Pick up eggs"))
    post(client, event_id="imessage:1", text="grab eggs please")
    run_mac(client)
    llm.responder = lambda p: extraction(act("complete_item", 1))
    post(client, event_id="imessage:2", text="Got the eggs!", is_from_me=True)
    cmd = run_mac(client)[0]
    assert cmd["payload"]["changes"] == {"completed": True}
    assert items(client)[0]["status"] == "completed"

    client.post("/actions/undo/imessage:2", headers=J)
    cmd = run_mac(client)[0]
    assert cmd["op"] == "update_item" and cmd["payload"]["changes"] == {"completed": False}
    assert items(client)[0]["status"] == "active"
    assert client.get("/api/events/imessage:2").json()["event"]["status"] == "undone"


def test_undo_reschedule_restores_previous_date(client, llm):
    llm.responder = lambda p: extraction(reminder("Pay water bill", due=day(1)))
    post(client, event_id="imessage:1", text="pay the water bill tomorrow")
    run_mac(client)
    llm.responder = lambda p: extraction(act("update_item", 1, due_date=day(3)))
    post(client, event_id="imessage:2", text="actually it's not due till " + day(3))
    run_mac(client)
    assert items(client)[0]["state"]["due"] == day(3)
    client.post("/actions/undo/imessage:2", headers=J)
    cmd = run_mac(client)[0]
    assert cmd["payload"]["changes"]["due"] == day(1)
    assert items(client)[0]["state"]["due"] == day(1)


def test_undo_cancel_recreates_item(client, llm):
    llm.responder = lambda p: extraction(reminder("Pick up eggs"))
    post(client, event_id="imessage:1", text="grab eggs please")
    run_mac(client)
    llm.responder = lambda p: extraction(act("cancel_item", 1))
    post(client, event_id="imessage:2", text="never mind")
    run_mac(client)
    client.post("/actions/undo/imessage:2", headers=J)
    cmd = run_mac(client, apple_prefix="NEW")[0]
    assert cmd["op"] == "create_reminder" and cmd["payload"]["title"] == "Pick up eggs"
    assert cmd["payload"]["tag"] == "[ha:imessage:1]"
    it = items(client)[0]
    assert it["status"] == "active" and it["apple_item_id"] == "NEW0"


def test_unknown_ref_goes_to_review(client, llm):
    llm.responder = lambda p: extraction(act("cancel_item", 4))
    res = post(client, text="never mind about that")
    assert res["result"] == "needs_review" and "can't find" in res["reason"]


def test_update_before_create_reported_back(client, llm):
    llm.responder = lambda p: extraction(reminder("Pick up eggs"))
    post(client, event_id="imessage:1", text="grab eggs")
    create = client.get("/api/agent/commands?wait=0", headers=AUTH).json()["commands"][0]  # sent, no result yet
    llm.responder = lambda p: extraction(act("update_item", 1, due_date=day(2)))
    post(client, event_id="imessage:2", text="no rush, by " + day(2))
    client.post(f"/api/agent/commands/{create['command_id']}/result", headers=AUTH,
                json={"status": "done", "apple_item_id": "LATE"})
    upd = client.get("/api/agent/commands?wait=0", headers=AUTH).json()["commands"][0]
    assert upd["op"] == "update_item" and upd["payload"]["apple_item_id"] == "LATE"


def test_cancel_item_waiting_for_review_never_reaches_mac(client, llm):
    llm.responder = lambda p: extraction(reminder("Call the plumber"), conf=0.4)
    assert post(client, event_id="imessage:1", text="maybe call the plumber")["result"] == "needs_review"
    llm.responder = lambda p: extraction(act("cancel_item", 1))
    res = post(client, event_id="imessage:2", text="never mind, it's fixed")
    assert res["result"] == "done"
    assert client.get("/api/agent/commands?wait=0", headers=AUTH).json()["commands"] == []
    assert client.get("/api/events/imessage:1").json()["event"]["status"] == "skipped"
    assert items(client)[0]["status"] == "cancelled"


def test_gift_idea_goes_to_persons_list_with_link(client, llm):
    url = "https://example.com/kindle"
    llm.responder = lambda p: extraction(act(
        "save_to_collection", collection="gift_ideas", title="Kindle Paperwhite", url=url,
        summary="Wife mentioned she'd love one for her birthday."))
    post(client, event_id="imessage:1", text=f"I'd love one of these someday {url}")
    p = run_mac(client)[0]["payload"]
    assert p["list"] == "🎁 Gifts for Wife" and p["url"] == url and p["create_list_if_missing"] is True
    assert p["due"] is None and p["alert"] is None
    assert p["notes"].splitlines()[1] == "Wife mentioned she'd love one for her birthday."
    it = items(client)[0]
    assert it["collection"] == "gift_ideas" and it["person"] == "Wife"
    assert "Kindle Paperwhite" in client.get("/items?tab=collections").text

    llm.responder = lambda p: extraction(act("save_to_collection", collection="gift_ideas", title="Bread maker",
                                             person="Mom"))
    post(client, event_id="imessage:2", text="Mom said she wants a bread maker")
    assert run_mac(client)[0]["payload"]["list"] == "🎁 Gifts for Mom"


def test_disabled_or_unknown_collection_needs_review(client, llm):
    cols = client.get("/api/settings").json()["values"]["collections"]
    for c in cols:
        if c["key"] == "places":
            c["enabled"] = False
    client.patch("/api/settings", json={"collections": cols})
    llm.responder = lambda p: extraction(act("save_to_collection", collection="places", title="Sushi Zen"))
    res = post(client, text="we should try Sushi Zen")
    assert res["result"] == "needs_review"


def test_collection_settings_reach_the_prompt(client, llm):
    cols = client.get("/api/settings").json()["values"]["collections"]
    cols.append({"key": "wine", "label": "Wines", "description": "Wines someone liked", "list": "🍷 Wines",
                 "enabled": True})
    assert client.patch("/api/settings", json={"collections": cols}).status_code == 200
    bad = cols + [{"key": "Bad Key!", "label": "x", "description": "xyz", "list": "x"}]
    assert client.patch("/api/settings", json={"collections": bad}).status_code == 422
    bad = cols[:-1] + [{**cols[-1], "list": "{name} list"}]
    assert client.patch("/api/settings", json={"collections": bad}).status_code == 422
    seen = {}
    llm.responder = lambda p: seen.setdefault("p", p) and extraction()
    post(client, text="that pinot was amazing")
    system = llm.calls[-1][0]["content"]
    assert "`wine`: Wines someone liked" in system


def test_person_in_title_and_summary(client, llm):
    client.patch("/api/settings", json={"rules": {"person_in_title": True}})
    llm.responder = lambda p: extraction(reminder("Pick up eggs") | {"summary": "You're out of eggs."})
    post(client, text="grab eggs?")
    p = run_mac(client)[0]["payload"]
    assert p["title"] == "Pick up eggs · Wife"
    assert p["notes"].splitlines()[:2][1] == "You're out of eggs."


def test_backfill_existing_items(tmp_path, llm, alerter):
    """A v0.2 database (no item registry) gets its live reminders registered on upgrade."""
    import json
    from fastapi.testclient import TestClient
    from app.main import create_app
    from app.models import DB
    from conftest import make_cfg
    cfg = make_cfg(tmp_path)
    db = DB(cfg.storage.db_path)
    db.insert_event({"event_id": "imessage:old", "source": "imessage", "sender_handle": "+17855550000",
                     "sender_label": "Wife", "chat_id": None, "received_at": "2026-11-01T10:00:00-05:00",
                     "text": "old"}, "done")
    cid = db.insert_command("imessage:old", "create_reminder", {"title": "Old thing", "tag": "[ha:imessage:old]",
                                                                "list": "Household"}, "done")
    db.update_command(cid, apple_item_id="OLD1", item_id=None)
    db.conn.close()
    with TestClient(create_app(make_cfg(tmp_path), llm=llm, alerter=alerter, background=False)) as c:
        reg = c.app.state.pipeline.items
        it = reg.listing()[0]
        assert it["title"] == "Old thing" and it["apple_item_id"] == "OLD1" and it["status"] == "active"
        assert it["chat_key"] == "+17855550000"
        assert c.app.state.db.get_command(cid)["item_id"] == it["item_id"]
        assert reg.backfill() == 0  # only once
