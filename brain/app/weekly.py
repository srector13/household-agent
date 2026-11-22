"""Weekly reset: a 2-minute swipe through what's gone stale — keep it, schedule it, finish it or drop it.

Stale = late, or undated and sitting there for a week, or untouched for two. Anything you "keep" is left
alone for the next six days so the same things don't come back every week.
"""
from __future__ import annotations

from datetime import date, datetime, timedelta, timezone
from typing import Any

from .models import utcnow

DAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
MAX = 20


class Weekly:
    def __init__(self, cfg, db, items, daily, push):
        self.cfg, self.db, self.items, self.daily, self.push = cfg, db, items, daily, push

    def stale(self, now: datetime | None = None) -> list[dict[str, Any]]:
        now = now or datetime.now(timezone.utc)
        today = now.astimezone(self.cfg.tz).date()
        week_ago = (now - timedelta(days=7)).isoformat()
        fortnight = (now - timedelta(days=14)).isoformat()
        recently_kept = (now - timedelta(days=6)).isoformat()
        rows = self.db.all(
            """SELECT * FROM items WHERE status IN ('planned','active') AND collection IS NULL AND kind='reminder'
               AND item_id NOT IN (SELECT item_id FROM item_log WHERE action='reviewed' AND at >= ?)
               ORDER BY created_at""", (recently_kept,))
        out = []
        for r in rows:
            it = self.items._decode(r)
            st = it["state"]
            due = date.fromisoformat(st["due"]) if st.get("due") else None
            age = (now - datetime.fromisoformat(it["created_at"])).days
            if due and due < today:
                late = (today - due).days
                why, rank = f"{late} day{'s' if late != 1 else ''} late", 0
            elif not due and it["created_at"] < week_ago:
                why, rank = f"no date · added {age} days ago", 1
            elif it["updated_at"] < fortnight:
                why, rank = f"untouched for {(now - datetime.fromisoformat(it['updated_at'])).days} days", 2
            else:
                continue
            origin = self.db.get_event(it["origin_event_id"]) or {}
            out.append({
                "item_id": it["item_id"], "title": it["title"], "kind": it["kind"], "category": it["category"],
                "person": it["person"] if it["person"] not in (None, "Me") else None, "why": why, "rank": rank,
                "due": st.get("due"), "age": age,
                "quote": (origin.get("text") or "")[:160] or None,
                "from_me": bool(origin.get("is_from_me")),
            })
        out.sort(key=lambda x: (x["rank"], -x["age"]))
        return out[:MAX]

    def keep(self, item_id: str) -> None:
        if not self.items.get(item_id):
            raise ValueError("unknown item")
        self.items.log(item_id, None, "reviewed", {"via": "weekly reset"})

    def finish(self, counts: dict[str, int]) -> dict[str, Any]:
        rec = {"at": utcnow(), "counts": {k: int(v) for k, v in (counts or {}).items()
                                          if k in ("keep", "schedule", "done", "drop")}}
        self.db.kv_set("weekly_last", rec)
        return rec

    def last(self) -> dict[str, Any] | None:
        return self.db.kv_get("weekly_last")

    def due(self, now: datetime | None = None) -> bool:
        """Show the Home card: it's reset day (or later in the week and you skipped it) and there's something stale."""
        now = now or datetime.now(timezone.utc)
        local = now.astimezone(self.cfg.tz)
        last = self.last()
        if last and now - datetime.fromisoformat(last["at"]) < timedelta(days=5):
            return False
        reset_day = DAYS.index(self.cfg.daily.weekly_day)
        since = (local.weekday() - reset_day) % 7  # days since the most recent reset day
        if since == 0 and local.strftime("%H:%M") < self.cfg.daily.weekly_time:
            return False
        return since <= 2  # reset day and the two days after it

    async def tick(self, now: datetime | None = None) -> int:
        """Send the nudge once on reset day at the configured time."""
        now = now or datetime.now(timezone.utc)
        local = now.astimezone(self.cfg.tz)
        if DAYS[local.weekday()] != self.cfg.daily.weekly_day or local.strftime("%H:%M") < self.cfg.daily.weekly_time:
            return 0
        key = local.date().isoformat()
        if self.db.kv_get("weekly_nudged") == key:
            return 0
        self.db.kv_set("weekly_nudged", key)
        n = len(self.stale(now))
        if not n or not self.push:
            return 0
        return await self.push.send("weekly", "🧹 Weekly reset",
                                    f"{n} thing{'s' if n != 1 else ''} gone stale — keep, schedule or drop. Takes 2 minutes.",
                                    url="/weekly", tag="weekly")
