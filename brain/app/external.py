"""Everything in your iCloud calendars and reminders — not just what Second Brain created.

The Mac agent posts a snapshot (next 7 days of events, due reminders) so Home's "Up next" and
"Coming up" and the morning briefing show the full picture. Items Second Brain made (ours=True)
are skipped here because the item registry already has them.
"""
from __future__ import annotations

import re
import unicodedata
from datetime import date, datetime, time, timedelta, timezone
from typing import Any, Literal

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


class SnapCalendar(BaseModel):
    title: str
    color: str | None = None
    kind: Literal["event", "reminder"]
    account: str | None = None


class Snapshot(BaseModel):
    generated_at: datetime | None = None
    range_days: int = 7
    events: list[SnapEvent] | None = Field(default=None, max_length=1000)
    reminders: list[SnapReminder] | None = Field(default=None, max_length=1000)
    calendars: list[SnapCalendar] | None = Field(default=None, max_length=300)  # every calendar + list, even empty


def _canon(s: str) -> str:
    return unicodedata.normalize("NFC", (s or "").strip()).casefold()


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
            still_open = {r.id for r in snap.reminders}
            done = [i for i in (self.db.kv_get("ext_done", []) or []) if i in still_open]
            self.db.kv_set("ext_done", done)  # ticks the Mac has applied drop out of the snapshot
        if snap.calendars is not None:
            cur["calendars"] = [c.model_dump(mode="json") for c in snap.calendars]
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
        done = self.done_ids()
        return [r for r in self._snap().get("reminders", []) if not r.get("ours") and r["id"] not in done]

    def all_reminders(self) -> list[dict[str, Any]]:
        """Every non-ours reminder in the snapshot, including ones ticked in the app (see done_ids)."""
        return [r for r in self._snap().get("reminders", []) if not r.get("ours")]

    def done_ids(self) -> set[str]:
        return set(self.db.kv_get("ext_done", []) or [])

    def mark_done(self, apple_id: str, done: bool = True) -> None:
        ids = [i for i in (self.db.kv_get("ext_done", []) or []) if i != apple_id][-200:]
        if done:
            ids.append(apple_id)
        self.db.kv_set("ext_done", ids)

    def reminder(self, apple_id: str) -> dict[str, Any] | None:
        return next((r for r in self._snap().get("reminders", []) if r["id"] == apple_id), None)

    def patch_reminder(self, apple_id: str, **changes: Any) -> bool:
        """Move a reminder in the stored copy right away (the Mac's next snapshot confirms it)."""
        cur = self._snap()
        for r in cur.get("reminders", []):
            if r["id"] == apple_id:
                r.update(changes)
                self.db.kv_set("snapshot", cur)
                return True
        return False

    # ---- calendars & lists ("Show on Today") ----------------------------------------------------
    def catalog(self) -> list[dict[str, Any]]:
        """Every calendar and reminder list the Mac sees; derived from the items when no catalog yet."""
        snap = self._snap()
        if snap.get("calendars") is not None:
            return list(snap["calendars"])
        out: dict[tuple[str, str], dict] = {}
        for e in snap.get("events", []):
            if e.get("calendar"):
                out.setdefault(("event", e["calendar"]), {"title": e["calendar"], "color": e.get("calendar_color"),
                                                         "kind": "event", "account": None})
        for r in snap.get("reminders", []):
            if r.get("list"):
                out.setdefault(("reminder", r["list"]), {"title": r["list"], "color": r.get("list_color"),
                                                        "kind": "reminder", "account": None})
        return list(out.values())

    def color_of(self, kind: str, name: str | None) -> str | None:
        if not name:
            return None
        want = _canon(name)
        return next((c.get("color") for c in self.catalog() if c["kind"] == kind and _canon(c["title"]) == want), None)

    def our_calendars(self) -> set[str]:
        return {_canon(self.cfg.rules.calendars.default)}

    def is_our_list(self, name: str) -> bool:
        n = _canon(name)
        if n in (_canon(self.cfg.rules.reminder_list), _canon(self.cfg.rules.waiting_list)):
            return True
        for c in self.cfg.collections:
            pat = "^" + ".+".join(re.escape(_canon(part)) for part in c.list.split("{person}")) + "$"
            if re.match(pat, n):
                return True
        return False

    def is_ours(self, kind: str, name: str) -> bool:
        return _canon(name) in self.our_calendars() if kind == "calendar" else self.is_our_list(name)

    def _hidden(self) -> dict[str, list[str]]:
        h = self.db.kv_get("sources_hidden", {}) or {}
        return {"calendars": list(h.get("calendars", [])), "lists": list(h.get("lists", []))}

    def shown(self, kind: str, name: str | None) -> bool:
        """kind: "calendar" | "list". Second Brain's own calendars and lists are always shown."""
        if not name or self.is_ours(kind, name):
            return True
        return _canon(name) not in {_canon(x) for x in self._hidden()["calendars" if kind == "calendar" else "lists"]}

    def set_shown(self, kind: str, name: str, shown: bool) -> None:
        if kind not in ("calendar", "list"):
            raise ValueError("kind must be calendar or list")
        h = self._hidden()
        key = "calendars" if kind == "calendar" else "lists"
        rest = [x for x in h[key] if _canon(x) != _canon(name)]
        h[key] = rest if shown else rest + [name]
        self.db.kv_set("sources_hidden", h)

    def sources(self) -> dict[str, list[dict[str, Any]]]:
        snap = self._snap()
        ev_count: dict[str, int] = {}
        for e in snap.get("events", []):
            ev_count[_canon(e.get("calendar") or "")] = ev_count.get(_canon(e.get("calendar") or ""), 0) + 1
        done = self.done_ids()
        rem_count: dict[str, int] = {}
        for r in snap.get("reminders", []):
            if r["id"] not in done:
                rem_count[_canon(r.get("list") or "")] = rem_count.get(_canon(r.get("list") or ""), 0) + 1
        cal = [c for c in self.catalog() if c["kind"] == "event"]
        lists = [c for c in self.catalog() if c["kind"] == "reminder"]
        have_cal = {_canon(c["title"]) for c in cal}
        if _canon(self.cfg.rules.calendars.default) not in have_cal:
            cal.append({"title": self.cfg.rules.calendars.default, "color": None, "kind": "event", "account": None})
        have_lists = {_canon(c["title"]) for c in lists}
        for name in (self.cfg.rules.reminder_list, self.cfg.rules.waiting_list):
            if _canon(name) not in have_lists:
                lists.append({"title": name, "color": None, "kind": "reminder", "account": None})

        def row(c: dict, kind: str, counts: dict[str, int]) -> dict[str, Any]:
            ours = self.is_ours(kind, c["title"])
            return {"name": c["title"], "color": c.get("color"), "ours": ours, "shown": self.shown(kind, c["title"]),
                    "account": c.get("account"), "count": counts.get(_canon(c["title"]), 0)}

        def order(rows: list[dict]) -> list[dict]:
            return sorted(rows, key=lambda r: (not r["ours"], r["name"].lower()))

        return {"calendars": order([row(c, "calendar", ev_count) for c in cal]),
                "lists": order([row(c, "list", rem_count) for c in lists])}

    def world(self) -> dict[str, Any]:
        """What the planner checks before creating: your own lists, open reminders and events."""
        lists = [c["title"] for c in self.catalog() if c["kind"] == "reminder" and not self.is_our_list(c["title"])]
        return {"lists": lists[:30], "reminders": self.reminders(), "events": self.events()}

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
