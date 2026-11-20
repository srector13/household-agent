from datetime import datetime

import pytest

from app.gate import gate, normalize_handle
from app.planner import plan, route_list
from app.schemas import Action, Event, Extraction
from conftest import TZ, event, extraction, make_cfg, reminder

NOW = datetime(2026, 11, 19, 16, 52, tzinfo=TZ)  # Thu


def ev(text="x", **kw):
    return Event(event_id="imessage:9", sender_handle="+17855550000", sender_label="Wife",
                 received_at=NOW, text=text, **kw)


@pytest.fixture
def cfg(tmp_path):
    return make_cfg(tmp_path)


def run(cfg, *actions, conf=0.95, now=NOW):
    return plan(cfg, ev("Can you grab eggs tomorrow?"), Extraction.model_validate(extraction(*actions, conf=conf)), now)


def test_default_alert_time(cfg):
    p = run(cfg, reminder("Pick up eggs", due="2026-11-20"))
    assert p.commands[0].payload["alert"] == "2026-11-20T16:00:00-06:00"
    assert p.commands[0].payload["due_time"] is None


def test_explicit_time(cfg):
    p = run(cfg, reminder("Call the vet", due="2026-11-20", time="09:30"))
    pl = p.commands[0].payload
    assert pl["alert"] == "2026-11-20T09:30:00-06:00" and pl["due_time"] == "09:30" and pl["list"] == "Household"


def test_today_after_default_time_alerts_soon(cfg):
    p = run(cfg, reminder("Pick up milk", due="2026-11-19"))
    alert = datetime.fromisoformat(p.commands[0].payload["alert"])
    assert alert > NOW and (alert - NOW).total_seconds() <= 15 * 60
    assert not p.needs_review


def test_no_due_no_alert(cfg):
    pl = run(cfg, reminder("Pick up eggs")).commands[0].payload
    assert pl["due"] is None and pl["alert"] is None


def test_past_due_needs_review(cfg):
    assert run(cfg, reminder("Pick up eggs", due="2026-11-18")).needs_review


def test_low_confidence_review(cfg):
    p = run(cfg, reminder("Pick up eggs"), conf=0.6)
    assert p.needs_review and "confidence" in p.review_reasons[0]
    assert len(p.commands) == 1  # still planned, held for approval


def test_list_routing(cfg):
    a = Action(type="create_reminder", title="Get paper towels", list="groceries", source_quote="")
    assert route_list(cfg, a) == "Groceries"  # model's list, canonicalized
    a = Action(type="create_reminder", title="Get paper towels", list="Costco", source_quote="")
    assert route_list(cfg, a) == "Household"  # unknown list -> default
    a = Action(type="create_reminder", title="Pick up eggs", list=None, source_quote="")
    assert route_list(cfg, a) == "Groceries"  # keyword


def test_event_default_duration_and_all_day(cfg):
    p = run(cfg, event("Dentist appointment", "2026-11-24T15:30"))
    pl = p.commands[0].payload
    assert pl["start"] == "2026-11-24T15:30:00-06:00" and pl["end"] == "2026-11-24T16:30:00-06:00"
    p = run(cfg, event("Picture day", "2026-11-24"))
    pl = p.commands[0].payload
    assert pl["all_day"] is True and pl["start"] == "2026-11-24T00:00:00-06:00" and pl["alert_minutes_before"] is None


def test_event_in_past_and_missing_start(cfg):
    assert run(cfg, event("Dinner", "2026-11-19T12:00")).needs_review
    p = run(cfg, event("Dinner", None))
    assert p.needs_review and not p.commands


def test_not_actionable(cfg):
    p = run(cfg)
    assert not p.commands and not p.needs_review


def test_dst_offset(cfg):
    pl = run(cfg, event("Brunch", "2027-03-20T10:00"), now=NOW).commands[0].payload
    assert pl["start"].endswith("-05:00")  # CDT


@pytest.mark.parametrize("text,reason", [
    ("Loved “grab eggs”", "tapback"), ("Laughed at “lol”", "tapback"), ("Reacted 😂 to “nice”", "tapback"),
    ("👍", "emoji_only"), ("😂😂😂", "emoji_only"), ("👨‍👩‍👧", "emoji_only"),
    ("ok", "too_short"), ("Okay!", "filler"), ("sounds good", "filler"), ("", "empty"),
    ("Can you grab eggs", None), ("Pick up Emma at 3", None), ("milk?", None),
])
def test_gate(cfg, text, reason):
    assert gate(cfg, ev(text)) == reason


def test_gate_self(cfg):
    assert gate(cfg, ev("buy milk", is_from_me=True)) == "from_me"
    cfg.watch.imessage.allow_self_notes = True
    assert gate(cfg, ev("buy milk", is_from_me=True)) is None


def test_normalize_handle():
    assert normalize_handle("(785) 555-0000") == "+17855550000"
    assert normalize_handle("+1 785 555 0000") == "+17855550000"
    assert normalize_handle("Wife <Her@Example.com>") == "her@example.com"
