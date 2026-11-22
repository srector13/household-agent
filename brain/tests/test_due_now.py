"""A to-do with no time of day is due right now (not at the 4 pm default)."""
from datetime import datetime, timedelta

from conftest import TZ, extraction, make_cfg, reminder
from app.planner import plan
from app.schemas import Event, Extraction

NOW = datetime(2026, 11, 22, 7, 42, 30, tzinfo=TZ)


def run(cfg, *actions):
    ev = Event(event_id="imessage:1", sender_handle="+17855550000", sender_label="Wife", received_at=NOW,
               text="pack a bag for the kids")
    return plan(cfg, ev, Extraction.model_validate(extraction(*actions)), NOW)


def test_no_date_no_time_is_due_now(tmp_path):
    cfg = make_cfg(tmp_path)
    cfg.rules.no_time_due_now = True
    c = run(cfg, reminder("Pack a bag for the kids")).commands[0].payload
    assert (c["due"], c["due_time"]) == ("2026-11-22", "07:43")
    assert c["alert"].startswith("2026-11-22T07:43")


def test_today_without_time_is_due_now_but_tonight_keeps_its_time(tmp_path):
    cfg = make_cfg(tmp_path)
    cfg.rules.no_time_due_now = True
    p = run(cfg, reminder("Pack a bag", due="2026-11-22"), reminder("Take the bins out", due="2026-11-22", time="18:00"))
    a, b = (c.payload for c in p.commands)
    assert a["due_time"] == "07:43" and b["due_time"] == "18:00"
    assert not p.review_reasons


def test_later_days_keep_the_default_time(tmp_path):
    cfg = make_cfg(tmp_path)
    cfg.rules.no_time_due_now = True
    c = run(cfg, reminder("Grab eggs", due="2026-11-23")).commands[0].payload
    assert c["due_time"] is None and c["alert"].startswith("2026-11-23T16:00")


def test_switch_off_keeps_undated(tmp_path):
    cfg = make_cfg(tmp_path)
    c = run(cfg, reminder("Pack a bag for the kids")).commands[0].payload
    assert c["due"] is None and c["alert"] is None


def test_on_by_default():
    from app.config import RulesConfig
    assert RulesConfig().no_time_due_now is True
