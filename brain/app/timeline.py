"""Today as one timeline: your events and reminders together, Second Brain's and your own.

Placement rules (see docs/API.md, GET /api/v1/timeline):
- events sit at their start; all-day events go in `all_day`; ended events are `past` (the app fades them)
- reminders sit at their due time; on today, open reminders that are already due (earlier days, an
  earlier time, or today with no time) are `carried` up to the now line
- reminders on another day with no time go last, as `all_day` entries ("Anytime")
- Second Brain's items come from the item registry (`ours`), everything else from the Mac's snapshot,
  limited to the calendars and lists switched on in "Show on Today"
"""
from __future__ import annotations

import json
from datetime import date, datetime, time, timedelta, timezone
from typing import Any

from .config import Config
from .models import DB

OPEN = ("planned", "active")


def _dt(s: str | None, tz) -> datetime | None:
    if not s:
        return None
    d = datetime.fromisoformat(s)
    return (d if d.tzinfo else d.replace(tzinfo=tz)).astimezone(tz)


def _hhmm(s: str | None) -> time | None:
    if not s:
        return None
    h, m = s.split(":")[:2]
    return time(int(h), int(m))


class Timeline:
    def __init__(self, cfg: Config, db: DB, items, external, people):
        self.cfg = cfg
        self.db = db
        self.items = items
        self.external = external
        self.people = people

    # ---- people ----------------------------------------------------------------------------------
    def _people_index(self) -> dict[str, dict[str, Any]]:
        out = {}
        for p in self.people.roster():
            out.setdefault(p["label"], {"key": p["key"], "label": p["label"], "photo": p.get("photo")})
        return out

    def _source_times(self, event_ids: set[str]) -> dict[str, str]:
        ids = [e for e in event_ids if e]
        if not ids:
            return {}
        rows = self.db.all(f"SELECT event_id, received_at FROM events WHERE event_id IN ({','.join('?' * len(ids))})",
                           tuple(ids))
        return {r["event_id"]: r["received_at"] for r in rows}

    # ---- entries ---------------------------------------------------------------------------------
    @staticmethod
    def _entry(**kw: Any) -> dict[str, Any]:
        base = {"id": "", "kind": "reminder", "title": "", "at": None, "start": None, "end": None, "due": None,
                "due_time": None, "all_day": False, "done": False, "late": False, "carried": False, "past": False,
                "ours": False, "item_id": None, "apple_id": None, "color": None, "calendar": None,
                "location": None, "category": None, "person": None, "origin_event_id": None, "source_at": None}
        base.update(kw)
        return base

    def _place_reminder(self, day: date, today: date, now: datetime, due: date | None, due_time: time | None,
                        done: bool) -> dict[str, Any] | None:
        """Where a reminder goes on `day`'s timeline (None = not on this day)."""
        tz = self.cfg.tz
        if due is None:
            return None
        at = datetime.combine(due, due_time, tz) if due_time else None
        if not done and day == today and due <= today and (due < today or at is None or at < now):
            return {"at": now, "carried": True, "late": due < today or (at is not None and at < now), "all_day": False}
        if due != day:
            return None
        if at is None:
            return {"at": datetime.combine(day, time(23, 59), tz), "carried": False, "late": False, "all_day": True}
        return {"at": at, "carried": False, "late": False, "all_day": False}

    def _ours(self, day: date, today: date, now: datetime, people: dict) -> list[dict[str, Any]]:
        tz = self.cfg.tz
        start_of_day = datetime.combine(day, time(0), tz)
        rows = self.db.all("""SELECT * FROM items WHERE collection IS NULL AND (status IN ('planned','active')
                              OR (status='completed' AND completed_at >= ?))""",
                           ((start_of_day - timedelta(days=1)).astimezone(timezone.utc).isoformat(),))
        out = []
        for it in rows:
            st = json.loads(it["state"]) if isinstance(it["state"], str) else (it["state"] or {})
            person = people.get(it.get("person")) if it.get("person") not in (None, "Me") else None
            common = dict(id=f"item:{it['item_id']}", title=it["title"], ours=True, item_id=it["item_id"],
                          apple_id=it.get("apple_item_id"), location=st.get("location"),
                          category=it.get("category") or ("event" if it["kind"] == "event" else "todo"),
                          person=person, origin_event_id=it.get("origin_event_id"))
            done = it["status"] == "completed"
            if it["kind"] == "event":
                s, e = _dt(st.get("start"), tz), _dt(st.get("end"), tz)
                if not s:
                    continue
                e = e or s + timedelta(hours=1)
                if st.get("all_day"):
                    last = (e - timedelta(seconds=1)).date() if e > s else s.date()
                    if not (s.date() <= day <= max(last, s.date())):
                        continue
                elif s.date() != day:
                    continue
                cal = st.get("calendar") or st.get("list")
                out.append(self._entry(**{**common, "category": "event"}, kind="event", at=s.isoformat(),
                                       start=s.isoformat(), end=e.isoformat(), all_day=bool(st.get("all_day")),
                                       past=e <= now, calendar=cal, color=self.external.color_of("event", cal)))
                continue
            if done:
                c = _dt(it.get("completed_at"), tz)
                if not c or c.date() != day:
                    continue
            try:
                due = date.fromisoformat(st["due"]) if st.get("due") else None
                due_time = _hhmm(st.get("due_time"))
            except ValueError:
                continue
            if done:
                at = datetime.combine(day, due_time, tz) if (due == day and due_time) else _dt(it.get("completed_at"), tz)
                place = {"at": at, "carried": False, "late": False, "all_day": False}
            else:
                place = self._place_reminder(day, today, now, due, due_time, False)
            if not place:
                continue
            lst = st.get("list")
            out.append(self._entry(**common, kind="reminder", at=place["at"].isoformat(), due=st.get("due"),
                                   due_time=st.get("due_time"), all_day=place["all_day"], done=done,
                                   late=place["late"], carried=place["carried"], calendar=lst,
                                   color=self.external.color_of("reminder", lst)))
        return out

    def _theirs(self, day: date, today: date, now: datetime) -> list[dict[str, Any]]:
        tz = self.cfg.tz
        out = []
        for e in self.external.events():
            if not self.external.shown("calendar", e.get("calendar")):
                continue
            s = _dt(e["start"], tz)
            en = _dt(e.get("end"), tz) or s + timedelta(hours=1)
            if e.get("all_day"):
                last = (en - timedelta(seconds=1)).date() if en > s else s.date()
                if not (s.date() <= day <= max(last, s.date())):
                    continue
            elif s.date() != day:
                continue
            out.append(self._entry(id=f"apple:{e['id']}", kind="event", title=e.get("title") or "", at=s.isoformat(),
                                   start=s.isoformat(), end=en.isoformat(), all_day=bool(e.get("all_day")),
                                   past=en <= now, apple_id=e["id"], color=e.get("calendar_color"),
                                   calendar=e.get("calendar"), location=e.get("location"), category="event"))
        done_ids = self.external.done_ids()
        for r in self.external.all_reminders():
            if not self.external.shown("list", r.get("list")):
                continue
            try:
                due = date.fromisoformat(r["due"]) if r.get("due") else None
                due_time = _hhmm(r.get("due_time"))
            except ValueError:
                continue
            done = r["id"] in done_ids
            place = self._place_reminder(day, today, now, due, due_time, done)
            if not place:
                continue
            out.append(self._entry(id=f"apple:{r['id']}", kind="reminder", title=r.get("title") or "",
                                   at=place["at"].isoformat(), due=r.get("due"), due_time=r.get("due_time"),
                                   all_day=place["all_day"], done=done, late=place["late"], carried=place["carried"],
                                   apple_id=r["id"], color=r.get("list_color"), calendar=r.get("list"),
                                   category="todo"))
        return out

    def day(self, day: date, now: datetime, today: date, *, people: dict | None = None) -> dict[str, list]:
        people = self._people_index() if people is None else people
        rows = self._ours(day, today, now, people) + self._theirs(day, today, now)
        times = self._source_times({r["origin_event_id"] for r in rows if r["origin_event_id"]})
        for r in rows:
            r["source_at"] = times.get(r["origin_event_id"]) if r["origin_event_id"] else None
        all_day = sorted((r for r in rows if r["kind"] == "event" and r["all_day"]), key=lambda r: r["title"].lower())
        entries = [r for r in rows if not (r["kind"] == "event" and r["all_day"])]
        # events before reminders at the same minute; carried items in the order they were due
        entries.sort(key=lambda r: (r["at"] or "", 0 if r["kind"] == "event" else 1,
                                    (r["due"] or "") + (r["due_time"] or ""), r["title"].lower()))
        return {"all_day": all_day, "entries": entries}

    def build(self, day: date, now: datetime, today: date) -> dict[str, Any]:
        people = self._people_index()
        got = self.day(day, now, today, people=people)
        sunday = day - timedelta(days=(day.weekday() + 1) % 7)
        week = []
        for i in range(7):
            d = sunday + timedelta(days=i)
            g = got if d == day else self.day(d, now, today, people=people)
            n = len(g["all_day"]) + sum(1 for r in g["entries"] if not r["carried"])
            week.append({"date": d.isoformat(), "count": n})
        start = datetime.combine(today, time(0), self.cfg.tz)
        added = self.db.one("""SELECT COUNT(*) n FROM items WHERE created_at >= ? AND
                               status IN ('proposed','planned','active','completed')""",
                            (start.astimezone(timezone.utc).isoformat(),))["n"]
        return {"date": day.isoformat(), "today": today.isoformat(), "now": now.isoformat(), "week": week,
                "added_today": added, "all_day": got["all_day"], "entries": got["entries"]}
