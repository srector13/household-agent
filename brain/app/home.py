"""The Home screen: what matters right now, for an app opened several times a day."""
from __future__ import annotations

import json
from datetime import date, datetime, time, timedelta, timezone
from typing import Any

from . import models as m
from . import views
from .config import Config
from .daily import Daily
from .items import Items
from .models import DB


def _greeting(now: datetime) -> str:
    h = now.hour
    return "Good morning" if 4 <= h < 12 else "Good afternoon" if h < 17 else "Good evening"


def _now_card(db: DB, cfg: Config, now: datetime) -> dict[str, Any] | None:
    """The next thing with a clock time today: an event (or one in progress), else a timed reminder."""
    best = None
    end_of_day = datetime.combine(now.date() + timedelta(days=1), time(0), cfg.tz)
    for r in db.all("SELECT * FROM items WHERE status IN ('planned','active') AND collection IS NULL"):
        st = json.loads(r["state"])
        if r["kind"] == "event" and st.get("start") and not st.get("all_day"):
            start = datetime.fromisoformat(st["start"]).astimezone(cfg.tz)
            end = datetime.fromisoformat(st["end"]).astimezone(cfg.tz) if st.get("end") else start + timedelta(hours=1)
            if end <= now or start >= end_of_day:
                continue
            cand = {"kind": "event", "title": r["title"], "at": start, "end": end, "ongoing": start <= now,
                    "where": st.get("location") or st.get("calendar"), "event_id": r["origin_event_id"],
                    "item_id": r["item_id"]}
        elif r["kind"] == "reminder" and st.get("due") and st.get("due_time"):
            at = datetime.combine(date.fromisoformat(st["due"]), time.fromisoformat(st["due_time"]), cfg.tz)
            if at < now - timedelta(hours=2) or at >= end_of_day:
                continue
            cand = {"kind": "reminder", "title": r["title"], "at": at, "end": None, "ongoing": False,
                    "where": st.get("list"), "event_id": r["origin_event_id"], "item_id": r["item_id"]}
        else:
            continue
        if best is None or cand["at"] < best["at"]:
            best = cand
    if best:
        mins = int((best["at"] - now).total_seconds() // 60)
        best["in"] = ("now" if best["ongoing"] or -5 <= mins <= 0
                      else f"{-mins} min ago" if mins < 0
                      else f"in {mins} min" if mins < 60
                      else f"in {mins // 60} h {mins % 60:02d} min" if mins < 240 else best["at"].strftime("at %-I:%M %p"))
    return best


def _attention(db: DB, items: Items, cfg: Config, now: datetime) -> dict[str, Any]:
    reviews = []
    for e in db.recent_events(limit=20, status=m.NEEDS_REVIEW):
        cmds = [c for c in db.commands_for_event(e["event_id"]) if c["generation"] == e["generation"] and c["status"] == "held"]
        reviews.append({"e": e, "titles": [c["payload"].get("title") or (c["meta"] or {}).get("title", "item") for c in cmds]})
    today = now.date()
    followups, late = [], []
    for r in db.all("""SELECT * FROM items WHERE status IN ('planned','active') AND category IN ('waiting','promise')"""):
        it = items._decode(r)
        due = date.fromisoformat(it["state"]["due"]) if it["state"].get("due") else None
        if it["category"] == "waiting" and due and due <= today:
            followups.append(it)
        elif it["category"] == "promise" and due and due < today:
            late.append(it)
    failed = db.one("SELECT COUNT(*) n FROM events WHERE status=? AND updated_at >= ?",
                    (m.FAILED, (datetime.now(timezone.utc) - timedelta(days=2)).isoformat()))["n"]
    return {"reviews": reviews, "followups": followups, "late": late, "failed": failed,
            "count": len(reviews) + len(followups) + len(late) + (1 if failed else 0)}


def _recent(db: DB, cfg: Config, limit: int = 6) -> list[dict[str, Any]]:
    """What the brain did lately, in words (from the item history)."""
    rows = db.all("""SELECT l.*, i.title, i.kind, i.category, i.collection, i.person, i.origin_event_id
                     FROM item_log l JOIN items i ON i.item_id = l.item_id
                     WHERE l.action IN ('planned','created','updated','completed','cancelled','deleted','undone')
                     ORDER BY l.id DESC LIMIT 40""")
    out, seen = [], set()
    for r in rows:
        key = (r["item_id"], r["action"] if r["action"] != "planned" else "created")
        if key in seen or (r["item_id"], "created") in seen and r["action"] == "planned":
            continue
        seen.add(key)
        detail = json.loads(r["detail"]) if r["detail"] else {}
        via = (detail or {}).get("via")
        verb = {"planned": "Added", "created": "Added", "updated": "Changed", "completed": "Done",
                "cancelled": "Cancelled", "deleted": "Deleted", "undone": "Undid"}[r["action"]]
        out.append({"verb": verb, "title": r["title"], "person": r["person"], "kind": r["kind"],
                    "category": r["category"], "collection": r["collection"], "at": r["at"], "via": via,
                    "event_id": r["origin_event_id"], "action": r["action"]})
        if len(out) >= limit:
            break
    return out


def home(db: DB, cfg: Config, daily: Daily, items: Items, health_snapshot: dict[str, Any]) -> dict[str, Any]:
    now = datetime.now(cfg.tz)
    plan = daily.plan(now.date())
    picks = []
    for p in plan.get("picks", []):
        it = items.get(p["item_id"])
        picks.append({**p, "status": it["status"] if it else "gone", "kind": (it or {}).get("kind", "reminder")})
    picked_ids = {p["item_id"] for p in picks}
    nxt = _now_card(db, cfg, now)
    waiting = {r["item_id"] for r in db.all("SELECT item_id FROM items WHERE category='waiting'")}
    waiting.add((nxt or {}).get("item_id"))  # already shown big at the top
    agenda = [u for u in views.upcoming(db, cfg, days=3)
              if u.get("item_id") not in picked_ids and u.get("item_id") not in waiting][:6]  # follow-ups live in "Needs you"
    problems = []
    a, llm = health_snapshot["agent"], health_snapshot["llm"]
    if not a.get("online"):
        problems.append("Your Mac isn't connected — new texts will be picked up when it's back."
                        if a.get("agent_version") else "The Mac agent hasn't connected yet.")
    elif a.get("agent_version") and not (a.get("reminders_ok") and a.get("calendar_ok") and a.get("fda_ok")):
        problems.append("The Mac agent is missing a permission — see Status.")
    if llm.get("fail_streak", 0) >= 3:
        problems.append("The model on the Spark isn't answering — messages will wait until it's back.")
    hm = now.strftime("%H:%M")
    return {
        "now": now, "greeting": _greeting(now), "plan": plan, "picks": picks,
        "picks_left": sum(1 for p in picks if p["status"] in ("planned", "active")),
        "next": nxt, "attention": _attention(db, items, cfg, now), "agenda": agenda,
        "recent": _recent(db, cfg), "done_today": len(daily.done_on(now.date())), "problems": problems,
        "evening": cfg.daily.enabled and hm >= cfg.daily.evening_time,
        "before_morning": cfg.daily.enabled and hm < cfg.daily.morning_time,
    }
