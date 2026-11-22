"""Quick actions on items from the app: snooze, reschedule, delete (with undo).

Each one changes the item in the registry right away (so the app updates instantly) and queues the
matching command for the Mac. The Mac's result confirms it; completion sync corrects any drift.
"""
from __future__ import annotations

from datetime import date, datetime, time, timedelta, timezone
from typing import Any

from .items import create_payload
from .models import utcnow

OPEN = ("planned", "active")


def _hhmm(s: str | None) -> time | None:
    if not s:
        return None
    h, m = s.split(":")
    return time(int(h), int(m))


def _fmt_time(t: time) -> str:
    return datetime.combine(date.today(), t).strftime("%-I:%M %p")


class Quick:
    def __init__(self, daily):
        self.daily = daily
        self.cfg, self.db, self.items = daily.cfg, daily.db, daily.items

    # ---- snooze presets -----------------------------------------------------------------------
    def snooze_options(self, now: datetime | None = None, item: dict | None = None) -> list[dict[str, Any]]:
        """iOS-style presets, computed in local time. Each is {key, label, sub, due, due_time}."""
        now = (now or datetime.now(timezone.utc)).astimezone(self.cfg.tz)
        today = now.date()
        keep = _hhmm((item or {}).get("state", {}).get("due_time")) if item else None
        morning = keep or _hhmm(self.cfg.daily.morning_time) or time(8, 0)
        opts: list[dict[str, Any]] = []
        later = (now + timedelta(hours=3)).replace(second=0, microsecond=0)
        later = later.replace(minute=0 if later.minute < 30 else 30)
        if later.date() == today and later.hour < 22:
            opts.append(self._opt("later", "Later today", today, later.time()))
        if now.time() < time(17, 30):
            opts.append(self._opt("tonight", "This evening", today, time(19, 0)))
        opts.append(self._opt("tomorrow", "Tomorrow", today + timedelta(days=1), morning))
        sat = today + timedelta(days=(5 - today.weekday()) % 7 or 7)
        if sat > today + timedelta(days=1):
            opts.append(self._opt("weekend", "This weekend", sat, morning))
        mon = today + timedelta(days=(7 - today.weekday()) % 7 or 7)
        opts.append(self._opt("nextweek", "Next week", mon, morning))
        return opts

    def _opt(self, key: str, label: str, day: date, at: time) -> dict[str, Any]:
        today = self.daily.today()
        when = "Today" if day == today else "Tomorrow" if day == today + timedelta(days=1) else day.strftime("%a %b %-d")
        return {"key": key, "label": label, "sub": f"{when}, {_fmt_time(at)}" if key != "tomorrow" else _fmt_time(at),
                "due": day.isoformat(), "due_time": at.strftime("%H:%M")}

    # ---- actions -----------------------------------------------------------------------------------
    def _open(self, item_id: str) -> dict[str, Any]:
        it = self.items.get(item_id)
        if not it:
            raise ValueError("unknown item")
        if it["status"] not in OPEN:
            raise ValueError(f"this item is {it['status']}")
        return it

    def snooze(self, item_id: str, key: str, now: datetime | None = None) -> dict[str, Any]:
        it = self._open(item_id)
        opt = next((o for o in self.snooze_options(now, it) if o["key"] == key), None)
        if not opt:
            raise ValueError("that snooze option isn't available right now")
        return self.reschedule(item_id, opt["due"], opt["due_time"], why=f"snoozed: {opt['label'].lower()}")

    def reschedule(self, item_id: str, due: str | None, due_time: str | None = None, *, why: str = "rescheduled",
                   start: str | None = None) -> dict[str, Any]:
        it = self._open(item_id)
        st = it["state"]
        if it["kind"] == "event":
            return self._move_event(it, start or due, why)
        try:
            d = date.fromisoformat(due) if due else None
            t = _hhmm(due_time) if due_time else None
        except ValueError as e:
            raise ValueError(f"bad date or time ({e})") from None
        if t and not d:
            d = self.daily.today()
        alert = None
        if d:
            alert = datetime.combine(d, t or _hhmm(self.cfg.rules.default_alert_time), self.cfg.tz).isoformat()
        changes = {"due": d.isoformat() if d else None, "due_time": t.strftime("%H:%M") if t else None, "alert": alert}
        previous = {k: st.get(k) for k in changes}
        self._queue(it, "update_item", {"changes": changes, "notes_append": None}, "update",
                    {"previous": previous, "why": why, "title": it["title"], "applied": True})
        self.items.update(it["item_id"], state={**st, **changes})
        self.items.log(it["item_id"], None, "snoozed" if why.startswith("snoozed") else "rescheduled",
                       {"via": "app", "changes": changes})
        self._unpick(it["item_id"], d)
        self._done()
        return {"due": changes["due"], "due_time": changes["due_time"], "label": self._describe(d, t)}

    def _move_event(self, it: dict, start: str | None, why: str) -> dict[str, Any]:
        st = it["state"]
        if not start:
            raise ValueError("pick a new start time")
        try:
            new_start = datetime.fromisoformat(start)
        except ValueError as e:
            raise ValueError(f"bad start ({e})") from None
        if new_start.tzinfo is None:
            new_start = new_start.replace(tzinfo=self.cfg.tz)
        old_s, old_e = datetime.fromisoformat(st["start"]), datetime.fromisoformat(st["end"])
        changes = {"start": new_start.isoformat(), "end": (new_start + (old_e - old_s)).isoformat()}
        self._queue(it, "update_item", {"changes": changes, "notes_append": None}, "update",
                    {"previous": {k: st.get(k) for k in changes}, "why": why, "title": it["title"], "applied": True})
        self.items.update(it["item_id"], state={**st, **changes})
        self.items.log(it["item_id"], None, "rescheduled", {"via": "app", "changes": changes})
        self._done()
        return {"start": changes["start"], "label": new_start.strftime("%a %b %-d, %-I:%M %p")}

    def delete(self, item_id: str) -> dict[str, Any]:
        it = self._open(item_id)
        pending = self.db.one("""SELECT command_id FROM commands WHERE item_id=? AND status IN ('pending','held')
                                 AND op IN ('create_reminder','create_event')""", (item_id,))
        if pending:  # never reached the Mac: just don't send it
            self.db.update_command(pending["command_id"], status="cancelled", completed_at=utcnow())
        else:
            self._queue(it, "delete_item", {}, "cancel", {"why": "deleted in the app", "title": it["title"], "applied": True})
        self.items.update(item_id, status="cancelled")
        self.items.log(item_id, None, "cancelled", {"via": "app"})
        self._done()
        return {"status": "cancelled"}

    def restore(self, item_id: str) -> dict[str, Any]:
        """Undo a delete from the app (the toast's Undo button)."""
        it = self.items.get(item_id)
        if not it or it["status"] != "cancelled":
            raise ValueError("nothing to restore")
        op, payload = create_payload(it)
        self.db.insert_command(self._eid(), op, payload, "pending", item_id=item_id, purpose="undo",
                               meta={"why": "restored in the app", "title": it["title"], "applied": True})
        self.items.update(item_id, status="active" if it.get("apple_item_id") else "planned")
        self.items.log(item_id, None, "restored", {"via": "app"})
        self._done()
        return {"status": "active"}

    # ---- helpers -------------------------------------------------------------------------------------
    def _eid(self) -> str:
        return f"app:{self.daily.today().isoformat()}"

    def _queue(self, it: dict, op: str, extra: dict, purpose: str, meta: dict) -> str:
        payload = {"apple_item_id": it.get("apple_item_id"), "tag": it["tag"], "kind": it["kind"], **extra}
        return self.db.insert_command(self._eid(), op, payload, "pending", item_id=it["item_id"], purpose=purpose,
                                      meta=meta)

    def _unpick(self, item_id: str, new_due: date | None) -> None:
        """Snoozed past today → it leaves today's three (and isn't moved back tonight)."""
        day = self.daily.today()
        plan = self.daily.plan(day)
        changed = False
        for p in plan.get("picks", []):
            if p["item_id"] == item_id and (new_due is None or new_due > day):
                p["snoozed_to"] = new_due.isoformat() if new_due else "someday"
                changed = True
        if item_id in (plan.get("moved") or {}):
            plan["moved"].pop(item_id)
            changed = True
        if changed:
            self.daily.save_plan(day, plan)

    def _describe(self, d: date | None, t: time | None) -> str:
        if not d:
            return "No date"
        today = self.daily.today()
        day = "Today" if d == today else "Tomorrow" if d == today + timedelta(days=1) else d.strftime("%a %b %-d")
        return f"{day}, {_fmt_time(t)}" if t else day

    def _done(self) -> None:
        self.daily.bus.publish({"type": "items"})

    async def wake(self) -> None:
        await self.daily.queue.wake()
