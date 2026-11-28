"""Weekly reset: what counts as stale, keep/finish, the Home card and the nudge."""
import asyncio
from datetime import datetime, timedelta, timezone

from conftest import extraction, reminder
from test_items import day, items, post, run_mac
from test_push import pclient, sent  # noqa: F401 — fixtures

J = {"X-Requested-With": "fetch"}


def seed(client, llm):
    llm.responder = lambda p: extraction(reminder("Call the plumber", due=day(1)), reminder("Fix the fence"),
                                         reminder("Buy stamps"), reminder("Book dentist", due=day(5)))
    post(client, text="lots of stuff")
    run_mac(client)
    by = {i["title"]: i for i in items(client)}
    old = (datetime.now(timezone.utc) - timedelta(days=10)).isoformat()
    ancient = (datetime.now(timezone.utc) - timedelta(days=20)).isoformat()
    db = client.app_state.db
    db.execute("UPDATE items SET state=json_set(state, '$.due', ?) WHERE item_id=?", (day(-3), by["Call the plumber"]["item_id"]))
    db.execute("UPDATE items SET created_at=? WHERE item_id=?", (old, by["Fix the fence"]["item_id"]))
    db.execute("UPDATE items SET created_at=?, updated_at=? WHERE item_id=?", (ancient, ancient, by["Book dentist"]["item_id"]))
    return by


def test_what_is_stale(client, llm):
    by = seed(client, llm)
    w = client.app_state.weekly
    s = w.stale()
    assert [c["title"] for c in s] == ["Call the plumber", "Fix the fence", "Book dentist"]  # late first; stamps is fresh
    assert s[0]["why"] == "3 days late" and s[0]["rank"] == 0
    assert s[1]["why"].startswith("no date · added 10 days ago")
    assert s[2]["why"].startswith("untouched for 20 days")
    # keep → left alone for a while
    assert client.post(f"/api/weekly/{by['Fix the fence']['item_id']}/keep", headers=J).json()["ok"]
    assert "Fix the fence" not in [c["title"] for c in w.stale()]
    assert client.post("/api/weekly/nope/keep", headers=J).status_code == 404


def test_page_and_finish(client, llm):
    seed(client, llm)
    t = client.get("/weekly").text
    assert "3 things gone stale" in t and "Call the plumber" in t and 'data-act="schedule"' in t
    r = client.post("/api/weekly/finish", headers=J, json={"counts": {"keep": 1, "drop": 2, "bogus": 9}}).json()
    assert r["counts"] == {"keep": 1, "drop": 2}
    assert client.app_state.weekly.last()["counts"]["drop"] == 2


def test_due_window(client):
    w = client.app_state.weekly
    cfg = client.app_state.cfg
    tz = cfg.tz
    sun_early = datetime(2026, 11, 22, 9, 0, tzinfo=tz)   # Sunday, before 17:00
    sun_late = datetime(2026, 11, 22, 18, 0, tzinfo=tz)
    tue = datetime(2026, 11, 24, 12, 0, tzinfo=tz)
    wed = datetime(2026, 11, 25, 12, 0, tzinfo=tz)
    assert not w.due(sun_early) and w.due(sun_late) and w.due(tue) and not w.due(wed)
    w.finish({"keep": 1})
    assert not w.due(datetime.now(timezone.utc))


def test_home_card(client, llm):
    seed(client, llm)
    w = client.app_state.weekly
    w.due = lambda now=None: True
    assert "Weekly reset" in client.get("/").text and "3 things gone stale" in client.get("/").text
    w.due = lambda now=None: False
    assert 'class="weeklycard"' not in client.get("/").text


def test_nudge_once_on_reset_day(pclient, sent):
    client, llm = pclient, pclient.llm
    seed(client, llm)
    w = client.app_state.weekly
    tz = client.app_state.cfg.tz
    today = datetime.now(tz).date()
    sun = today + timedelta(days=(6 - today.weekday()) % 7)  # the coming reset day, so ages match the seed
    at = lambda h, m: datetime(sun.year, sun.month, sun.day, h, m, tzinfo=tz)  # noqa: E731
    assert asyncio.run(w.tick(at(16, 0))) == 0  # too early
    assert asyncio.run(w.tick(at(17, 1))) == 1
    assert sent[-1]["url"] == "/weekly" and "3 things gone stale" in sent[-1]["body"]
    assert asyncio.run(w.tick(at(18, 0))) == 0  # once
    assert asyncio.run(w.tick(datetime(2026, 11, 23, 17, 30, tzinfo=tz))) == 0  # Monday


def test_weekly_settings(client):
    r = client.patch("/api/settings", headers=J, json={"daily": {"weekly_day": "fri", "weekly_time": "9:15"}})
    assert r.status_code == 200, r.text
    assert client.app_state.cfg.daily.weekly_day == "fri" and client.app_state.cfg.daily.weekly_time == "09:15"
    assert client.patch("/api/settings", headers=J, json={"daily": {"weekly_day": "someday"}}).status_code == 422
    assert 'data-path="daily.weekly_day"' in client.get("/settings").text
