"""Everything in your iCloud calendars and reminders — not just what Second Brain created.

The Mac agent posts a snapshot (next 7 days of events, due reminders) so Home's "Up next" and
"Coming up" and the morning briefing show the full picture. Items Second Brain made (ours=True)
are skipped here because the item registry already has them.
"""
from __future__ import annotations

from datetime import date, datetime, time, timedelta, timezone
from typing import Any

from pydantic import BaseModel, Field

from .config import Config
from .models import DB


class SnapEvent(BaseModel):
    id: str
    title: str = ""
    start: datetime
    end: datetime | None = None
    all_day: bool = False
    calendar: str | None = None
    calendar_color: str | None = None
    location: str | None = None
    ours: bool = False


class SnapReminder(BaseModel):
    id: str
    title: str = ""
    list: str | None = None
    list_color: str | None = None
    due: str | None = None
    due_time: str | None = None
    priority: int = 0
    ours: bool = False


class Snapshot(BaseModel):
    generated_at: datetime | None = None
    range_days: int = 7
    events: list[SnapEvent] | None = Field(default=None, max_length=1000)
    reminders: list[SnapReminder] | None = Field(default=None, max_length=1000)


class External:
    def __init__(self, cfg: Config, db: DB):
        self.cfg = cfg
        self.db = db

    def store(self, snap: Snapshot) -> dict[str, int]:
        cur = self.db.kv_get("snapshot", {}) or {}
        if snap.events is not None:  # null = that kind wasn't readable; keep what we had
            cur["events"] = [e.model_dump(mode="json") for e in snap.events]
        if snap.reminders is not None:
            cur["reminders"] = [r.model_dump(mode="json") for r in snap.reminders]
        cur["received_at"] = datetime.now(timezone.utc).isoformat()
        self.db.kv_set("snapshot", cur)
        return {"events": len(cur.get("events", [])), "reminders": len(cur.get("reminders", []))}

    def _snap(self) -> dict[str, Any]:
        return self.db.kv_get("snapshot", {}) or {}

    @property
    def received_at(self) -> str | None:
        return self._snap().get("received_at")

    def events(self) -> list[dict[str, Any]]:
        return [e for e in self._snap().get("events", []) if not e.get("ours")]

    def reminders(self) -> list[dict[str, Any]]:
        done = set(self.db.kv_get("ext_done", []) or [])
        return [r for r in self._snap().get("reminders", []) if not r.get("ours") and r["id"] not in done]

    def mark_done(self, apple_id: str) -> None:
        done = list(self.db.kv_get("ext_done", []) or [])[-200:]
        done.append(apple_id)
        self.db.kv_set("ext_done", done)

    # ---- views ------------------------------------------------------------------------------
    def agenda(self, now: datetime, days: int) -> list[dict[str, Any]]:
        """External items for 'Coming up', in the same shape as views.upcoming()."""
        tz = self.cfg.tz
        today = now.date()
        horizon = today + timedelta(days=days)
        out = []
        for e in self.events():
            start = datetime.fromisoformat(e["start"]).astimezone(tz)
            end = datetime.fromisoformat(e["end"]).astimezone(tz) if e.get("end") else start + timedelta(hours=1)
            if end < now or start.date() > horizon:
                continue
            out.append({"kind": "event", "title": e["title"], "when": max(start, datetime.combine(today, time(0), tz))
                        if e.get("all_day") and start.date() < today else start, "all_day": e.get("all_day", False),
                        "where": e.get("calendar"), "who": None, "event_id": None, "external": True,
                        "apple_id": e["id"], "color": e.get("calendar_color"), "location": e.get("location")})
        for r in self.reminders():
            if not r.get("due"):
                continue
            due = date.fromisoformat(r["due"])
            if due > horizon:
                continue
            late = due < today
            at = time.fromisoformat(r["due_time"]) if r.get("due_time") else time(23, 59)
            when = datetime.combine(today if late else due, time(0) if late else at, tz)
            out.append({"kind": "reminder", "title": r["title"], "when": when, "all_day": not r.get("due_time") or late,
                        "where": r.get("list"), "who": None, "event_id": None, "external": True, "late": late,
                        "apple_id": r["id"], "color": r.get("list_color")})
        return out

    def next_candidates(self, now: datetime) -> list[dict[str, Any]]:
        tz = self.cfg.tz
        end_of_day = datetime.combine(now.date() + timedelta(days=1), time(0), tz)
        out = []
        for e in self.events():
            if e.get("all_day"):
                continue
            start = datetime.fromisoformat(e["start"]).astimezone(tz)
            end = datetime.fromisoformat(e["end"]).astimezone(tz) if e.get("end") else start + timedelta(hours=1)
            if end <= now or start >= end_of_day:
                continue
            out.append({"kind": "event", "title": e["title"], "at": start, "end": end, "ongoing": start <= now,
                        "where": e.get("location") or e.get("calendar"), "event_id": None, "item_id": None,
                        "external": True, "color": e.get("calendar_color")})
        for r in self.reminders():
            if not (r.get("due") and r.get("due_time")):
                continue
            at = datetime.combine(date.fromisoformat(r["due"]), time.fromisoformat(r["due_time"]), tz)
            if at < now - timedelta(hours=2) or at >= end_of_day:
                continue
            out.append({"kind": "reminder", "title": r["title"], "at": at, "end": None, "ongoing": False,
                        "where": r.get("list"), "event_id": None, "item_id": None, "external": True,
                        "apple_id": r["id"], "color": r.get("list_color")})
        return out

    def events_on(self, day: date) -> list[dict[str, Any]]:
        tz = self.cfg.tz
        out = []
        for e in self.events():
            start = datetime.fromisoformat(e["start"]).astimezone(tz)
            if start.date() == day:
                out.append({"title": e["title"], "state": {"start": start.isoformat(), "all_day": e.get("all_day"),
                                                           "calendar": e.get("calendar"), "location": e.get("location")},
                            "external": True, "origin_event_id": None})
        return out
