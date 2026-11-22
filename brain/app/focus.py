"""Focus mode: one task, full screen, its first step, an optional timer, and a nudge when time's up.

The timer runs on the brain, not the phone: iOS freezes a PWA in the background, so the "time's up"
nudge comes as a push notification that opens straight back into focus mode.
"""
from __future__ import annotations

import asyncio
import logging
import re
from datetime import datetime, timedelta, timezone
from typing import Any

from .models import utcnow

log = logging.getLogger(__name__)
MAX_MINUTES = 90


def parse_notes(notes: str | None) -> dict[str, Any]:
    """Pull the first step, steps and a context line out of a reminder's notes."""
    notes = notes or ""
    first = None
    m = None
    for m in re.finditer(r"^👉 Start: (.+)$", notes, re.M):
        pass
    if m:
        first = m.group(1).strip()  # the newest one (break it down appends)
    steps = [s.strip() for s in re.findall(r"^☐ (.+)$", notes, re.M)]
    context = None
    for line in notes.splitlines()[1:]:
        line = line.strip()
        if line and not line.startswith(("👉", "☐", "Steps:", "[ha:", "http", "✅", "✏️", "↩︎")):
            context = line
            break
    return {"first_step": first, "steps": list(dict.fromkeys(steps))[-5:], "context": context}


class Focus:
    def __init__(self, cfg, db, items, daily, push):
        self.cfg, self.db, self.items, self.daily, self.push = cfg, db, items, daily, push
        self._task: asyncio.Task | None = None

    # ---- what to show ---------------------------------------------------------------------------
    def details(self, item_id: str) -> dict[str, Any]:
        it = self.items.get(item_id)
        if not it:
            raise ValueError("unknown item")
        st = it["state"]
        parsed = parse_notes(st.get("notes"))
        first = st.get("first_step") or parsed["first_step"] or next(
            (p.get("first_step") for p in self.daily.plan(self.daily.today()).get("picks", [])
             if p["item_id"] == item_id and p.get("first_step")), None)
        steps = st.get("steps") or parsed["steps"]
        timer = self.timer()
        return {
            "item_id": it["item_id"], "title": it["title"], "kind": it["kind"], "status": it["status"],
            "category": it["category"], "person": it["person"] if it["person"] not in (None, "Me") else None,
            "first_step": first, "steps": steps, "context": parsed["context"],
            "due": st.get("due"), "url": st.get("url"),
            "timer": timer if timer and timer["item_id"] == item_id else None,
            "next": self.next_up(exclude=item_id),
        }

    def next_up(self, exclude: str | None = None) -> dict[str, Any] | None:
        """What to do after this: the next unfinished pick for today, else the best candidate."""
        day = self.daily.today()
        for p in self.daily.plan(day).get("picks", []):
            if p["item_id"] == exclude or p.get("snoozed_to"):
                continue
            it = self.items.get(p["item_id"])
            if it and it["status"] in ("planned", "active") and it["kind"] == "reminder":
                return {"item_id": it["item_id"], "title": it["title"], "why": "next of today's three"}
        for c in self.daily.candidates(datetime.now(timezone.utc), limit=5):
            if c["item_id"] != exclude and c.get("kind", "reminder") == "reminder":
                return {"item_id": c["item_id"], "title": c["title"], "why": c.get("why") or "up next"}
        return None

    # ---- timer ------------------------------------------------------------------------------------
    def timer(self) -> dict[str, Any] | None:
        t = self.db.kv_get("focus_timer")
        if not t:
            return None
        if datetime.fromisoformat(t["ends_at"]) < datetime.now(timezone.utc) - timedelta(minutes=30):
            return None
        return t

    def start(self, item_id: str, minutes: int) -> dict[str, Any]:
        it = self.items.get(item_id)
        if not it:
            raise ValueError("unknown item")
        minutes = max(1, min(int(minutes), MAX_MINUTES))
        ends = datetime.now(timezone.utc) + timedelta(minutes=minutes)
        t = {"item_id": item_id, "title": it["title"], "minutes": minutes, "ends_at": ends.isoformat(),
             "started_at": utcnow()}
        self.db.kv_set("focus_timer", t)
        self.items.log(item_id, None, "focus", {"minutes": minutes})
        self._schedule(t)
        return t

    def stop(self) -> None:
        self.db.kv_set("focus_timer", None)
        if self._task:
            self._task.cancel()
            self._task = None

    def resume(self) -> None:
        """After a restart: re-arm a timer that hasn't fired yet."""
        t = self.db.kv_get("focus_timer")
        if t and datetime.fromisoformat(t["ends_at"]) > datetime.now(timezone.utc):
            self._schedule(t)

    def _schedule(self, t: dict[str, Any]) -> None:
        if self._task:
            self._task.cancel()
        try:
            self._task = asyncio.get_running_loop().create_task(self._fire(t))
        except RuntimeError:  # no loop (sync tests): the client-side timer still runs
            self._task = None

    async def _fire(self, t: dict[str, Any]) -> None:
        delay = (datetime.fromisoformat(t["ends_at"]) - datetime.now(timezone.utc)).total_seconds()
        await asyncio.sleep(max(0, delay))
        await self.times_up(t)

    async def times_up(self, t: dict[str, Any]) -> int:
        cur = self.db.kv_get("focus_timer")
        if not cur or cur.get("ends_at") != t["ends_at"]:
            return 0  # stopped or replaced
        it = self.items.get(t["item_id"])
        if not it or it["status"] not in ("planned", "active"):
            return 0  # already done
        if not self.push:
            return 0
        return await self.push.send("focus", f"⏰ {t['minutes']} minutes — nice work",
                                    f"“{it['title']}”. Done, or keep going?",
                                    url=f"/?focus={it['item_id']}", tag="focus")
