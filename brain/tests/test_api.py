from datetime import date, datetime, timedelta

from conftest import AUTH, TZ, event, extraction, msg, reminder


def post(client, body, sync=True):
    r = client.post(f"/api/events?sync={'true' if sync else 'false'}", json=body, headers=AUTH)
    assert r.status_code == 200, r.text
    return r.json()


def tomorrow():
    return (datetime.now(TZ).date() + timedelta(days=1)).isoformat()


def test_auth_required(client):
    assert client.post("/api/events", json=msg()).status_code == 401
    assert client.get("/api/agent/commands?wait=0", headers={"Authorization": "Bearer nope"}).status_code == 401


def test_eggs_end_to_end(client, llm):
    llm.responder = lambda p: extraction(reminder("Pick up eggs", due=tomorrow(), quote="grab eggs tomorrow"))
    res = post(client, msg())
    assert res["result"] == "queued"

    cmds = client.get("/api/agent/commands?wait=0", headers=AUTH).json()["commands"]
    assert len(cmds) == 1
    c = cmds[0]
    assert c["op"] == "create_reminder"
    p = c["payload"]
    assert p["title"] == "Pick up eggs" and p["list"] == "Household" and p["due"] == tomorrow()
    assert p["alert"].startswith(f"{tomorrow()}T16:00:00")
    assert p["tag"] == "[ha:imessage:1]" and p["notes"].endswith("[ha:imessage:1]")
    assert p["notes"].startswith("👤 Wife · ") and "Wife: “Can you grab eggs tomorrow?" in p["notes"]

    # leased: not redelivered immediately
    assert client.get("/api/agent/commands?wait=0", headers=AUTH).json()["commands"] == []

    r = client.post(f"/api/agent/commands/{c['command_id']}/result", headers=AUTH,
                    json={"status": "done", "apple_item_id": "APPLE-1", "error": None})
    assert r.status_code == 200
    ev = client.get("/api/events/imessage:1").json()
    assert ev["event"]["status"] == "done"
    steps = [t["step"] for t in ev["trace"]]
    for s in ["ingest", "allowlist", "gate", "extract", "plan", "queue", "command_sent", "command_result"]:
        assert s in steps
    extract_step = next(t for t in ev["trace"] if t["step"] == "extract")
    assert extract_step["data"]["prompt"][0]["role"] == "system"
    assert ev["event"]["prompt_version"] == "extract-v4"

    # Undo → delete_item queued → done → undone
    r = client.post("/actions/undo/imessage:1", follow_redirects=False)
    assert r.status_code == 303
    cmds = client.get("/api/agent/commands?wait=0", headers=AUTH).json()["commands"]
    assert cmds[0]["op"] == "delete_item"
    assert cmds[0]["payload"] == {"apple_item_id": "APPLE-1", "kind": "reminder", "tag": "[ha:imessage:1]"}
    client.post(f"/api/agent/commands/{cmds[0]['command_id']}/result", headers=AUTH, json={"status": "done"})
    assert client.get("/api/events/imessage:1").json()["event"]["status"] == "undone"


def test_duplicate_and_not_allowlisted(client, llm):
    llm.responder = lambda p: extraction(reminder("Pick up eggs", due=tomorrow()))
    assert post(client, msg())["status"] == "accepted"
    assert post(client, msg())["status"] == "duplicate"
    assert len(llm.calls) == 1

    res = post(client, msg(event_id="imessage:2", handle="+15550001111"))
    assert res["status"] == "ignored"
    assert client.get("/api/events/imessage:2").status_code == 404
    db = client.app_state.db
    assert db.one("SELECT COUNT(*) n FROM events")["n"] == 1
    assert db.one("SELECT COUNT(*) n FROM trace WHERE event_id='imessage:2'")["n"] == 0


def test_allowlist_by_handle_formats(client, llm):
    # config has "+1 (785) 555-0000"; agent might send 7855550000
    assert post(client, msg(event_id="imessage:3", handle="7855550000"))["status"] == "accepted"


def test_gate_skips_without_llm(client, llm):
    for i, text in enumerate(["Loved “Can you grab eggs”", "👍", "ok", "lol", "k", "Haha!", "❤️❤️"]):
        res = post(client, msg(event_id=f"imessage:g{i}", text=text))
        assert res["result"] == "skipped", text
    res = post(client, msg(event_id="imessage:me", text="Remember to buy milk", is_from_me=True))
    assert res["result"] == "skipped"
    assert llm.calls == []


def test_not_actionable_is_skipped(client, llm):
    res = post(client, msg(text="I'm leaving work now"))
    assert res["result"] == "skipped" and res["reason"] == "not actionable"


def test_low_confidence_needs_review_then_approve(client, llm, alerter):
    llm.responder = lambda p: extraction(reminder("Call the plumber", due=tomorrow()), conf=0.5)
    res = post(client, msg(text="maybe we should get the plumber out"))
    assert res["result"] == "needs_review"
    assert alerter.sent and alerter.sent[-1][0] == "needs_review"
    assert "http://brain:8080/events/imessage:1" in alerter.sent[-1][1]
    assert client.get("/api/agent/commands?wait=0", headers=AUTH).json()["commands"] == []

    page = client.get("/events/imessage:1")
    assert page.status_code == 200 and "Approve" in page.text

    client.post("/actions/approve/imessage:1")
    cmds = client.get("/api/agent/commands?wait=0", headers=AUTH).json()["commands"]
    assert len(cmds) == 1 and cmds[0]["payload"]["list"] == "Household"


def test_reject(client, llm):
    llm.responder = lambda p: extraction(reminder("Call the plumber"), conf=0.4)
    post(client, msg(text="maybe we should get the plumber out"))
    client.post("/actions/reject/imessage:1")
    assert client.get("/api/events/imessage:1").json()["event"]["status"] == "rejected"
    assert client.get("/api/agent/commands?wait=0", headers=AUTH).json()["commands"] == []


def test_calendar_event(client, llm):
    start = (datetime.now(TZ) + timedelta(days=3)).replace(hour=15, minute=30).strftime("%Y-%m-%dT%H:%M")
    llm.responder = lambda p: extraction(event("Dentist appointment", start))
    post(client, msg(text="dentist moved to Tuesday at 3:30"))
    c = client.get("/api/agent/commands?wait=0", headers=AUTH).json()["commands"][0]
    assert c["op"] == "create_event"
    p = c["payload"]
    assert p["calendar"] == "Family" and p["all_day"] is False
    s, e = datetime.fromisoformat(p["start"]), datetime.fromisoformat(p["end"])
    assert (e - s) == timedelta(minutes=60) and s.hour == 15 and s.minute == 30
    assert p["alert_minutes_before"] == 30


def test_multi_item_and_failure(client, llm):
    llm.responder = lambda p: extraction(reminder("Pick up milk"), reminder("Pick up bread"))
    post(client, msg(text="need milk and bread"))
    cmds = client.get("/api/agent/commands?wait=0", headers=AUTH).json()["commands"]
    assert [c["payload"]["tag"] for c in cmds] == ["[ha:imessage:1]", "[ha:imessage:1#1]"]
    client.post(f"/api/agent/commands/{cmds[0]['command_id']}/result", headers=AUTH, json={"status": "done", "apple_item_id": "A"})
    assert client.get("/api/events/imessage:1").json()["event"]["status"] == "queued"
    client.post(f"/api/agent/commands/{cmds[1]['command_id']}/result", headers=AUTH, json={"status": "failed", "error": "list missing"})
    ev = client.get("/api/events/imessage:1").json()["event"]
    assert ev["status"] == "failed" and "list missing" in ev["reason"]


def test_llm_down_stays_received_and_alerts(client, llm, alerter):
    from app.extract import LLMUnavailable
    llm.responder = lambda p: LLMUnavailable("connection refused")
    for i in range(3):
        res = post(client, msg(event_id=f"imessage:d{i}", text=f"please buy milk {i}"))
        assert res["result"] == "received"
    assert any(k == "llm_down" for k, _ in alerter.sent)
    llm.responder = lambda p: extraction(reminder("Pick up milk"))
    client.portal.call(client.app_state.pipeline.retry_received)  # too recent → nothing yet
    db = client.app_state.db
    db.execute("UPDATE events SET updated_at='2000-01-01'")
    client.portal.call(client.app_state.pipeline.retry_received)
    assert db.one("SELECT COUNT(*) n FROM events WHERE status='queued'")["n"] == 3
    assert any(k == "llm_up" for k, _ in alerter.sent)


def test_bad_model_output_fails_with_trace(client, llm):
    llm.responder = lambda p: "this is not json"
    res = post(client, msg(text="please buy milk"))
    assert res["result"] == "failed"
    tr = client.get("/api/events/imessage:1").json()["trace"]
    err = next(t for t in tr if t["step"] == "extract_error")
    assert err["data"]["raw"] == "this is not json"


def test_think_tags_and_fences_are_tolerated(client, llm):
    import json
    llm.responder = lambda p: "<think>hmm</think>\n```json\n" + json.dumps(extraction(reminder("Pick up milk"))) + "\n```"
    assert post(client, msg(text="please buy milk"))["result"] == "queued"


def test_reprocess_with_edits_deletes_old_items_first(client, llm):
    import json
    llm.responder = lambda p: extraction(reminder("Pick up eggs", due=tomorrow()))
    post(client, msg())
    c = client.get("/api/agent/commands?wait=0", headers=AUTH).json()["commands"][0]
    client.post(f"/api/agent/commands/{c['command_id']}/result", headers=AUTH, json={"status": "done", "apple_item_id": "OLD"})

    edited = extraction(reminder("Pick up 2 dozen eggs", due=tomorrow()), conf=0.3)  # low conf ignored when edited
    r = client.post("/actions/reprocess/imessage:1", data={"extraction": json.dumps(edited)}, follow_redirects=False)
    assert r.status_code == 303 and "err=" not in r.headers["location"]
    cmds = client.get("/api/agent/commands?wait=0", headers=AUTH).json()["commands"]
    assert [c["op"] for c in cmds] == ["delete_item", "create_reminder"]
    assert cmds[0]["payload"]["apple_item_id"] == "OLD"
    assert cmds[1]["payload"]["title"] == "Pick up 2 dozen eggs"
    for c in cmds:
        client.post(f"/api/agent/commands/{c['command_id']}/result", headers=AUTH, json={"status": "done", "apple_item_id": "NEW"})
    ev = client.get("/api/events/imessage:1").json()["event"]
    assert ev["status"] == "done" and ev["generation"] == 1

    # Undo now removes only the new item
    client.post("/actions/undo/imessage:1")
    cmds = client.get("/api/agent/commands?wait=0", headers=AUTH).json()["commands"]
    assert len(cmds) == 1 and cmds[0]["payload"]["apple_item_id"] == "NEW"


def test_reprocess_rejects_invalid_json(client):
    post(client, msg(text="hello there friend"))
    r = client.post("/actions/reprocess/imessage:1", data={"extraction": "{"}, follow_redirects=False)
    assert "err=" in r.headers["location"]


def test_retry(client, llm):
    llm.responder = lambda p: "garbage"
    post(client, msg(text="please buy milk"))
    llm.responder = lambda p: extraction(reminder("Pick up milk"))
    client.post("/actions/retry/imessage:1")
    assert client.get("/api/events/imessage:1").json()["event"]["status"] == "queued"


def test_lease_redelivery(client, llm):
    llm.responder = lambda p: extraction(reminder("Pick up milk"))
    post(client, msg(text="please buy milk"))
    c = client.get("/api/agent/commands?wait=0", headers=AUTH).json()["commands"][0]
    client.app_state.db.execute("UPDATE commands SET sent_at='2000-01-01T00:00:00+00:00'")
    again = client.get("/api/agent/commands?wait=0", headers=AUTH).json()["commands"]
    assert again[0]["command_id"] == c["command_id"]


def test_long_poll_wakes_on_new_command(client, llm):
    import threading, time
    llm.responder = lambda p: extraction(reminder("Pick up milk"))
    result = {}

    def poll():
        t = time.time()
        result["cmds"] = client.get("/api/agent/commands?wait=10", headers=AUTH).json()["commands"]
        result["dt"] = time.time() - t

    th = threading.Thread(target=poll)
    th.start()
    time.sleep(0.5)
    post(client, msg(text="please buy milk"))
    th.join(15)
    assert len(result["cmds"]) == 1 and result["dt"] < 5


def test_unknown_command_result_404(client):
    r = client.post("/api/agent/commands/cmd_nope/result", headers=AUTH, json={"status": "done"})
    assert r.status_code == 404


def test_heartbeat_and_watchdog(client, alerter):
    import time
    health = client.app_state.health
    hb = {"agent_version": "0.1.0", "last_rowid": 5, "fda_ok": True, "reminders_ok": True,
          "calendar_ok": True, "uptime_s": 10}
    assert client.post("/api/agent/heartbeat", json=hb, headers=AUTH).status_code == 200
    client.portal.call(health.check_agent)
    assert not any(k == "agent_offline" for k, _ in alerter.sent)

    st = client.app_state.db.kv_get("agent")
    st["received_at"] = time.time() - 400
    client.app_state.db.kv_set("agent", st)
    client.portal.call(health.check_agent)
    client.portal.call(health.check_agent)  # only once
    assert [k for k, _ in alerter.sent].count("agent_offline") == 1

    client.post("/api/agent/heartbeat", json={**hb, "reminders_ok": False}, headers=AUTH)
    kinds = [k for k, _ in alerter.sent]
    assert "agent_online" in kinds and "permission" in kinds
    assert client.get("/api/health").json()["agent"]["online"] is True


def test_dashboard_pages_render(client, llm):
    llm.responder = lambda p: extraction(reminder("Pick up eggs", due=tomorrow()))
    post(client, msg())
    post(client, msg(event_id="imessage:2", text="lol"))
    for path in ["/", "/activity", "/activity?status=skipped", "/activity?q=eggs&source=imessage", "/review",
                 "/items", "/system", "/settings", "/lab", "/events/imessage:1", "/partials/row/imessage:1",
                 "/events/imessage:2", "/health", "/stats", "/playground"]:
        r = client.get(path)
        assert r.status_code == 200, path
    assert "Pick up eggs" in client.get("/").text
    r = client.post("/lab", data={"text": "grab eggs tomorrow", "sender": "Wife", "context": "", "now": ""})
    assert r.status_code == 200 and "create_reminder" in r.text
    assert client.app_state.db.one("SELECT COUNT(*) n FROM events")["n"] == 2  # playground stores nothing


def test_dashboard_password(tmp_path, llm, alerter):
    from fastapi.testclient import TestClient
    from app.main import create_app
    from conftest import make_cfg
    cfg = make_cfg(tmp_path, dashboard={"password": "pw", "public_url": "x"})
    with TestClient(create_app(cfg, llm=llm, alerter=alerter, background=False)) as c:
        assert c.get("/").status_code == 401
        assert c.get("/", auth=("admin", "pw")).status_code == 200
        # agent API uses the bearer token, not the dashboard password
        assert c.post("/api/agent/heartbeat", json={}, headers=AUTH).status_code == 200


def test_backup(client, cfg):
    from app.backup import backup_if_due
    path = client.portal.call(lambda: backup_if_due(cfg, client.app_state.db, force=True))
    import sqlite3
    assert sqlite3.connect(path).execute("SELECT COUNT(*) FROM events").fetchone()[0] == 0
