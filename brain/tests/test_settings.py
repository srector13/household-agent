"""Dashboard-editable settings: validation, live apply, persistence, agent sync, safety."""
from fastapi.testclient import TestClient

from app.main import create_app
from conftest import AUTH, extraction, make_cfg, msg, reminder

J = {"X-Requested-With": "fetch"}


def test_add_recipient_takes_effect_immediately(client, llm):
    # not allowlisted yet → ignored
    body = msg(event_id="imessage:50", handle="+1 785 555 1234")
    assert client.post("/api/events", json=body, headers=AUTH).json()["status"] == "ignored"

    allow = client.get("/api/settings").json()["values"]["watch.imessage.allow"]
    allow.append({"handle": "(785) 555-1234", "label": "Mom"})
    r = client.patch("/api/settings", json={"watch": {"imessage": {"allow": allow}}}, headers=J)
    assert r.status_code == 200 and r.json()["changed"] == ["watch.imessage"]

    llm.responder = lambda p: extraction(reminder("Call the vet"))
    res = client.post("/api/events?sync=true", json=body, headers=AUTH).json()
    assert res["status"] == "accepted"
    assert client.get("/api/events/imessage:50").json()["event"]["sender_label"] == "Mom"


def test_pause_recipient(client):
    allow = client.get("/api/settings").json()["values"]["watch.imessage.allow"]
    allow[0]["enabled"] = False
    client.patch("/api/settings", json={"watch": {"imessage": {"allow": allow}}})
    assert client.post("/api/events", json=msg(), headers=AUTH).json()["status"] == "ignored"


def test_agent_config_and_version(client):
    v0 = client.post("/api/agent/heartbeat", json={}, headers=AUTH).json()["settings_version"]
    cfg = client.get("/api/agent/config", headers=AUTH).json()
    assert cfg["allow"]["handles"] == ["+17855550000"] and cfg["settings_version"] == v0
    client.patch("/api/settings", json={"watch": {"imessage": {"allow": [
        {"handle": "Her@iCloud.com", "label": "Wife"}, {"chat_id": "iMessage;+;chat99", "label": "Family"},
        {"handle": "+15551112222", "label": "Paused", "enabled": False}]}}})
    cfg = client.get("/api/agent/config", headers=AUTH).json()
    assert cfg["allow"] == {"handles": ["her@icloud.com"], "chat_ids": ["iMessage;+;chat99"]}
    assert cfg["settings_version"] == v0 + 1
    assert client.post("/api/agent/heartbeat", json={}, headers=AUTH).json()["settings_version"] == v0 + 1
    assert client.get("/api/agent/config").status_code == 401  # agent token required


def test_single_reminder_list_setting(client, llm):
    client.patch("/api/settings", json={"rules": {"reminder_list": "Family To-dos", "default_alert_time": "09:15"}})
    llm.responder = lambda p: extraction(reminder("Pick up eggs", due="2099-01-02"))
    client.post("/api/events?sync=true", json=msg(), headers=AUTH)
    p = client.get("/api/agent/commands?wait=0", headers=AUTH).json()["commands"][0]["payload"]
    assert p["list"] == "Family To-dos" and p["alert"].startswith("2099-01-02T09:15")


def test_validation_errors_change_nothing(client):
    before = client.get("/api/settings").json()
    for patch in [
        {"rules": {"default_alert_time": "25:99"}},
        {"rules": {"review_threshold": 3}},
        {"timezone": "Mars/Olympus"},
        {"watch": {"imessage": {"allow": [{"label": "nobody"}]}}},
        {"watch": {"imessage": {"allow": [{"handle": "12", "label": "x"}]}}},
        {"security": {"agent_token": "pwned"}},
        {"storage": {"db_path": "/tmp/x"}},
    ]:
        r = client.patch("/api/settings", json=patch)
        assert r.status_code == 422, patch
        assert r.json()["error"]
    after = client.get("/api/settings").json()
    assert after["values"] == before["values"] and after["version"] == before["version"]


def test_secrets_are_masked_and_write_only(client):
    client.patch("/api/settings", json={"alerts": {"discord_webhook_url": "https://discord.com/api/webhooks/1/s3cr3tTOKEN"}})
    v = client.get("/api/settings").json()["values"]
    assert v["alerts.discord_webhook_url"] == "••••"
    assert "s3cr3tTOKEN" not in client.get("/settings").text
    assert "s3cr3tTOKEN" not in client.get("/system").text
    hist = client.app_state.settings.history()
    assert hist[0]["after"] == "••••"
    # sending the mask back doesn't overwrite it
    client.patch("/api/settings", json={"alerts": {"discord_webhook_url": "••••"}})
    assert client.app_state.cfg.alerts.discord_webhook_url.endswith("/s3cr3tTOKEN")


def test_reset_to_file_value(client):
    client.patch("/api/settings", json={"rules": {"reminder_list": "Other"}})
    assert client.get("/api/settings").json()["sources"]["rules.reminder_list"] == "dashboard"
    client.post("/api/settings/reset", json={"path": "rules.reminder_list"})
    s = client.get("/api/settings").json()
    assert s["values"]["rules.reminder_list"] == "Household" and s["sources"]["rules.reminder_list"] != "dashboard"


def test_overrides_persist_across_restart(tmp_path, llm, alerter):
    cfg = make_cfg(tmp_path)
    with TestClient(create_app(cfg, llm=llm, alerter=alerter, background=False)) as c:
        c.patch("/api/settings", json={"rules": {"reminder_list": "Persisted"}, "llm": {"model": "qwen-x"}})
    cfg2 = make_cfg(tmp_path)  # fresh config from "file" (same db path)
    with TestClient(create_app(cfg2, llm=llm, alerter=alerter, background=False)) as c:
        assert cfg2.rules.reminder_list == "Persisted" and cfg2.llm.model == "qwen-x"
        assert c.get("/api/settings").json()["sources"]["llm.model"] == "dashboard"


def test_llm_client_follows_settings_live(tmp_path, alerter):
    import json
    import httpx
    from app.extract import VLLMClient
    seen = []

    def handler(request):
        seen.append((str(request.url), json.loads(request.content)["model"] if request.content else None))
        return httpx.Response(200, json={"choices": [{"message": {"content": json.dumps(extraction())}}], "data": [{"id": "m2"}]})

    cfg = make_cfg(tmp_path)
    app = create_app(cfg, alerter=alerter, background=False)
    vc: VLLMClient = app.state.pipeline.llm
    vc.http = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    with TestClient(app) as c:
        c.post("/api/events?sync=true", json=msg(event_id="imessage:a", text="buy milk please"), headers=AUTH)
        c.patch("/api/settings", json={"llm": {"base_url": "http://other:9000/v1", "model": "m2"}})
        c.post("/api/events?sync=true", json=msg(event_id="imessage:b", text="buy bread please"), headers=AUTH)
        r = c.post("/api/settings/test-llm", json={}).json()
    assert seen[0] == ("http://localhost:8000/v1/chat/completions", "qwen")
    assert seen[1] == ("http://other:9000/v1/chat/completions", "m2")
    assert r["ok"] and r["models"] == ["m2"] and r["model_found"]


def test_cross_site_writes_blocked(client):
    r = client.patch("/api/settings", json={"rules": {"reminder_list": "x"}}, headers={"Origin": "http://evil.example"})
    assert r.status_code == 403
    r = client.post("/actions/undo/imessage:1", headers={"Sec-Fetch-Site": "cross-site"})
    assert r.status_code == 403
    # same-origin is fine; agent API unaffected by Origin checks
    assert client.patch("/api/settings", json={}, headers={"Origin": "http://testserver"}).status_code == 200
    assert client.post("/api/agent/heartbeat", json={}, headers={**AUTH, "Origin": "http://evil.example"}).status_code == 200


def test_json_actions(client, llm):
    llm.responder = lambda p: extraction(reminder("Call the plumber"), conf=0.3)
    client.post("/api/events?sync=true", json=msg(text="maybe call the plumber"), headers=AUTH)
    r = client.post("/actions/approve/imessage:1", headers=J)
    assert r.status_code == 200 and r.json() == {"ok": True, "error": None, "status": "queued"}
    r = client.post("/actions/approve/imessage:1", headers=J)
    assert r.status_code == 409 and "not needs_review" in r.json()["error"]


def test_overview_and_items(client, llm):
    llm.responder = lambda p: extraction(reminder("Pick up eggs", due="2099-01-01"))
    client.post("/api/events?sync=true", json=msg(), headers=AUTH)
    c = client.get("/api/agent/commands?wait=0", headers=AUTH).json()["commands"][0]
    client.post(f"/api/agent/commands/{c['command_id']}/result", headers=AUTH, json={"status": "done", "apple_item_id": "A1"})
    o = client.get("/api/overview").json()
    assert o["today"] == {"messages": 1, "created": 1} and o["funnel"]["created"] == 1
    assert "Pick up eggs" in client.get("/items").text
    client.post("/actions/undo/imessage:1", headers=J)
    d = client.get("/api/agent/commands?wait=0", headers=AUTH).json()["commands"][0]
    client.post(f"/api/agent/commands/{d['command_id']}/result", headers=AUTH, json={"status": "done"})
    assert "Pick up eggs" not in client.get("/items").text
    assert "Pick up eggs" in client.get("/items?tab=history").text


def test_settings_page_shows_people(client):
    t = client.get("/settings").text
    assert "+1 (785) 555-0000" in t and "People & chats" in t and "Reminders list" in t


def test_approve_uses_current_reminder_list(client, llm):
    llm.responder = lambda p: extraction(reminder("Call the plumber"), conf=0.3)
    client.post("/api/events?sync=true", json=msg(text="maybe call the plumber"), headers=AUTH)
    client.patch("/api/settings", json={"rules": {"reminder_list": "Family To-dos"}})
    client.post("/actions/approve/imessage:1", headers=J)
    p = client.get("/api/agent/commands?wait=0", headers=AUTH).json()["commands"][0]["payload"]
    assert p["list"] == "Family To-dos"


def test_friendly_time_error(client):
    r = client.patch("/api/settings", json={"rules": {"default_alert_time": ""}})
    assert r.status_code == 422 and "24-hour time" in r.json()["error"]
