"""Daily rhythm: a few things for today each morning, a shutdown recap each evening.

ADHD-friendly by design: only `count` items are surfaced (the rest stay out of sight), each with a
tiny first step; unfinished picks are quietly moved back off Today instead of piling up as overdue.
"""
from __future__ import annotations

import json
import logging
import re
from datetime import date, datetime, time, timedelta, timezone
from typing import Any

from .commands import Bus, CommandQueue
from .config import Config
from .heartbeat import Alerter
from .items import Items
from .models import DB

log = logging.getLogger("brain.daily")

PICK_SCHEMA = {
    "type": "object", "additionalProperties": False, "required": ["picks", "note"],
    "properties": {
        "picks": {"type": "array", "maxItems": 7, "items": {
            "type": "object", "additionalProperties": False, "required": ["n", "why", "first_step"],
            "properties": {"n": {"type": "integer"}, "why": {"type": "string"},
                           "first_step": {"type": ["string", "null"]}}}},
        "note": {"type": "string"},
    },
}
BREAKDOWN_SCHEMA = {
    "type": "object", "additionalProperties": False, "required": ["first_step", "steps"],
    "properties": {"first_step": {"type": "string"},
                   "steps": {"type": "array", "maxItems": 5, "items": {"type": "string"}}},
}


def _first_step_from_notes(notes: str | None) -> str | None:
    m = re.search(r"^👉 Start: (.+)$", notes or "", re.M)
    return m.group(1).strip() if m else None


class Daily:
    def __init__(self, cfg: Config, db: DB, items: Items, queue: CommandQueue, llm, alerter: Alerter, bus: Bus):
        self.cfg, self.db, self.items, self.queue, self.llm, self.alerter, self.bus = (
            cfg, db, items, queue, llm, alerter, bus)
        self.push = None  # set by the app

    # ---- state ------------------------------------------------------------------------------
    def plan(self, day: date) -> dict[str, Any]:
        return self.db.kv_get(f"daily:{day.isoformat()}", {}) or {}

    def save_plan(self, day: date, plan: dict[str, Any]) -> None:
        self.db.kv_set(f"daily:{day.isoformat()}", plan)
        self.bus.publish({"type": "daily", "date": day.isoformat()})

    def today(self, now: datetime | None = None) -> date:
        return (now or datetime.now(timezone.utc)).astimezone(self.cfg.tz).date()

    # ---- candidates -------------------------------------------------------------------------------
    def candidates(self, now: datetime, limit: int = 12) -> list[dict[str, Any]]:
        today = self.today(now)
        rows = self.db.all("""SELECT * FROM items WHERE status IN ('planned','active') AND kind='reminder'
                              AND category IN ('todo','promise','waiting')""")
        carried = {p["item_id"] for p in self.plan(today - timedelta(days=1)).get("picks", [])}
        out = []
        for r in rows:
            it = self.items._decode(r)
            st = it["state"]
            due = date.fromisoformat(st["due"]) if st.get("due") else None
            if it["category"] == "waiting" and (not due or due > today):
                continue  # only surface a follow-up once it's due
            score, why = 0.0, []
            if due:
                d = (due - today).days
                if d < 0:
                    score += 100 + min(-d, 14) * 2
                    why.append(f"{-d} day{'s' if d != -1 else ''} late")
                elif d == 0:
                    score += 80
                    why.append("due today")
                elif d == 1:
                    score += 40
                    why.append("due tomorrow")
                elif d <= 7:
                    score += 20 - d
                    why.append(f"due {due:%a}")
            age = (datetime.now(timezone.utc) - datetime.fromisoformat(it["created_at"])).days
            if not due:
                score += min(age, 30)
                if age >= 3:
                    why.append(f"waiting {age} days")
            if it["category"] == "promise":
                score += 25
                why.insert(0, f"you promised {it['person']}")
            if it["category"] == "waiting":
                score += 30
                why.insert(0, f"follow up with {it['person']}")
            if it["item_id"] in carried:
                score += 15
                why.append("carried over")
            it["score"], it["why"] = score, ", ".join(why) or "open"
            it["first_step"] = st.get("first_step") or _first_step_from_notes(st.get("notes"))
            out.append(it)
        out.sort(key=lambda x: -x["score"])
        return out[:limit]

    external = None  # set by the app: your own iCloud calendars (external.External)

    def events_on(self, day: date) -> list[dict[str, Any]]:
        out = list(self.external.events_on(day)) if self.external else []
        for r in self.db.all("SELECT * FROM items WHERE status IN ('planned','active') AND kind='event'"):
            it = self.items._decode(r)
            st = it["state"]
            if st.get("start") and datetime.fromisoformat(st["start"]).astimezone(self.cfg.tz).date() == day:
                out.append(it)
        out.sort(key=lambda x: x["state"]["start"])
        return out

    # ---- picking -------------------------------------------------------------------------------------
    async def choose(self, now: datetime, count: int | None = None,
                     preselected: list[str] | None = None) -> tuple[list[dict[str, Any]], str]:
        count = count or self.cfg.daily.count
        cands = self.candidates(now)
        chosen: list[dict[str, Any]] = []
        for iid in preselected or []:
            c = next((x for x in cands if x["item_id"] == iid), None) or self._open_item(iid)
            if c and len(chosen) < count:
                chosen.append(c)
        rest = [c for c in cands if c["item_id"] not in {x["item_id"] for x in chosen}]
        note = ""
        need = count - len(chosen)
        if need > 0 and len(rest) > need and hasattr(self.llm, "complete_json"):
            try:
                got = await self._llm_pick(now, rest, need)
                chosen += got["picks"]
                note = got["note"]
                need = 0
            except Exception as e:  # noqa: BLE001 — fall back to the score order
                log.warning("daily pick via LLM failed, using scores: %r", e)
        if need > 0:
            chosen += rest[:need]
        return chosen, note

    def _open_item(self, item_id: str) -> dict[str, Any] | None:
        it = self.items.get(item_id)
        if not it or it["status"] not in ("planned", "active"):
            return None
        it["why"], it["first_step"] = "you picked it", it["state"].get("first_step") or _first_step_from_notes(
            it["state"].get("notes"))
        return it

    async def _llm_pick(self, now: datetime, cands: list[dict[str, Any]], need: int) -> dict[str, Any]:
        local = now.astimezone(self.cfg.tz)
        lines = [f"{i}. {c['title']} — {c['why']}" + (f" (from {c['person']})" if c.get("person") else "")
                 for i, c in enumerate(cands, 1)]
        events = [f"- {e['title']} {datetime.fromisoformat(e['state']['start']).astimezone(self.cfg.tz):%-I:%M %p}"
                  for e in self.events_on(local.date())]
        messages = [
            {"role": "system", "content": (
                "You help someone with ADHD plan their day. From the numbered open tasks, choose exactly "
                f"{need} for today: prioritize anything late or due today and promises to people, then include "
                "one quick win if possible. Keep the day realistic around the calendar. For each pick give `why` "
                "(≤8 words, kind, no guilt) and `first_step`: one tiny concrete action that takes ≤10 minutes, "
                "or null if the task is already tiny. `note`: one short encouraging sentence. JSON only.")},
            {"role": "user", "content": f"Today is {local:%A %b %-d}.\nCalendar today:\n"
                                        + ("\n".join(events) or "(nothing)") + "\n\nOpen tasks:\n" + "\n".join(lines)},
        ]
        data = json.loads(await self.llm.complete_json(messages, PICK_SCHEMA, "daily_pick"))
        picks, seen = [], set()
        for p in data.get("picks", []):
            n = p.get("n")
            if isinstance(n, int) and 1 <= n <= len(cands) and n not in seen and len(picks) < need:
                seen.add(n)
                c = dict(cands[n - 1])
                c["why"] = p.get("why") or c["why"]
                c["first_step"] = c.get("first_step") or p.get("first_step")
                picks.append(c)
        if len(picks) < need:  # model returned too few: top up by score
            picks += [c for i, c in enumerate(cands, 1) if i not in seen][: need - len(picks)]
        return {"picks": picks, "note": (data.get("note") or "").strip()}

    # ---- Reminders "Today" view ------------------------------------------------------------------------
    def _queue_update(self, day: date, it: dict, changes: dict, previous: dict, why: str) -> str:
        payload = {"apple_item_id": it.get("apple_item_id"), "tag": it["tag"], "kind": "reminder",
                   "changes": changes, "notes_append": None}
        return self.db.insert_command(f"daily:{day.isoformat()}", "update_item", payload, "pending",
                                      item_id=it["item_id"], purpose="update",
                                      meta={"previous": previous, "why": why, "title": it["title"], "daily": True})

    def apply_today_view(self, day: date, picks: list[dict]) -> dict[str, dict]:
        """Make picks due today so they show in Reminders' Today list; remember what they were."""
        moved: dict[str, dict] = {}
        if not self.cfg.daily.today_view:
            return moved
        for p in picks:
            it = self.items.get(p["item_id"])
            if not it:
                continue
            st = it["state"]
            due = date.fromisoformat(st["due"]) if st.get("due") else None
            if due and due <= day:
                continue  # already due (or late) — it's in Today
            prev = {"due": st.get("due"), "due_time": st.get("due_time"), "alert": st.get("alert")}
            self._queue_update(day, it, {"due": day.isoformat(), "due_time": None, "alert": None}, prev,
                               "today's pick")
            moved[it["item_id"]] = prev
        return moved

    def restore(self, day: date, moved: dict[str, dict]) -> list[str]:
        """Put unfinished picks back where they were (no overdue pile)."""
        restored = []
        for iid, prev in moved.items():
            it = self.items.get(iid)
            if not it or it["status"] != "active" or it["state"].get("due") != day.isoformat():
                continue  # done, gone, or rescheduled by hand since
            self._queue_update(day, it, prev, {"due": day.isoformat(), "due_time": None, "alert": None},
                               "back off Today")
            restored.append(it["title"])
        return restored

    # ---- morning / evening -------------------------------------------------------------------------------
    async def morning(self, now: datetime | None = None, *, force: bool = False) -> dict[str, Any]:
        now = now or datetime.now(timezone.utc)
        day = self.today(now)
        plan = self.plan(day)
        if plan.get("picks") and not force:
            return plan
        if force and plan.get("moved"):
            self.restore(day, plan["moved"])
        picks, note = await self.choose(now, preselected=plan.get("preselected"))
        moved = self.apply_today_view(day, picks)
        plan.update(picks=[{"item_id": p["item_id"], "title": p["title"], "why": p.get("why"),
                            "first_step": p.get("first_step"), "person": p.get("person"),
                            "category": p.get("category")} for p in picks],
                    note=note, moved=moved, morning_at=now.isoformat())
        self.save_plan(day, plan)
        await self.queue.wake()
        if self.cfg.daily.discord and (self.cfg.push.discord_too or not self.push):
            await self.alerter.send("daily", self.morning_text(day, plan))
        if self.push:
            lines = [f"{i}. {p['title']}" for i, p in enumerate(plan["picks"], 1)] or ["Nothing open — enjoy the day."]
            picked = {p["item_id"] for p in plan["picks"]}
            follow = [f for f in self.followups_due(day) if f["item_id"] not in picked] if self.cfg.push.followups else []
            if follow:
                lines.append("⏳ Follow up: " + ", ".join(f"{f['person']} ({f['title']})" for f in follow[:3]))
            await self.push.send("daily", f"Today's {len(plan['picks'])}" if plan["picks"] else "Good morning",
                                 "\n".join(lines), url="/", tag=f"morning:{day.isoformat()}")
        return plan

    def followups_due(self, day: date) -> list[dict[str, Any]]:
        out = []
        for r in self.db.all("SELECT * FROM items WHERE status IN ('planned','active') AND category='waiting'"):
            it = self.items._decode(r)
            due = it["state"].get("due")
            if due and date.fromisoformat(due) <= day:
                out.append(it)
        return out

    def morning_text(self, day: date, plan: dict[str, Any]) -> str:
        n = len(plan["picks"])
        lines = [f"☀️ **Today's {n}** — {day:%a %b %-d}"]
        for i, p in enumerate(plan["picks"], 1):
            lines.append(f"{i}. {p['title']}" + (f" — {p['why']}" if p.get("why") else ""))
            if p.get("first_step"):
                lines.append(f"   👉 Start: {p['first_step']}")
        if not plan["picks"]:
            lines.append("Nothing open — enjoy the day. ✨")
        evs = self.events_on(day)
        if evs:
            lines.append("📅 Also today: " + ", ".join(
                f"{e['title']} {datetime.fromisoformat(e['state']['start']).astimezone(self.cfg.tz):%-I:%M %p}"
                + ("" if not e["state"].get("all_day") else "") for e in evs))
        if plan.get("note"):
            lines.append(plan["note"])
        lines.append(f"Everything else can wait. {self.cfg.dashboard.public_url.rstrip('/')}/today")
        return "\n".join(lines)

    def done_on(self, day: date) -> list[dict[str, Any]]:
        start = datetime.combine(day, time(0), self.cfg.tz).astimezone(timezone.utc).isoformat()
        end = datetime.combine(day + timedelta(days=1), time(0), self.cfg.tz).astimezone(timezone.utc).isoformat()
        return [self.items._decode(r) for r in self.db.all(
            "SELECT * FROM items WHERE status='completed' AND completed_at >= ? AND completed_at < ? "
            "ORDER BY completed_at", (start, end))]

    async def evening(self, now: datetime | None = None, *, force: bool = False) -> dict[str, Any]:
        now = now or datetime.now(timezone.utc)
        day = self.today(now)
        plan = self.plan(day)
        if plan.get("evening_at") and not force:
            return plan
        done = self.done_on(day)
        rolled = self.restore(day, plan.get("moved", {}))
        tomorrow = day + timedelta(days=1)
        nxt = self.plan(tomorrow)
        if not nxt.get("preselected"):
            suggest = [c for c in self.candidates(now + timedelta(days=1))][: self.cfg.daily.count]
            nxt["suggested"] = [{"item_id": c["item_id"], "title": c["title"], "why": c["why"]} for c in suggest]
            self.save_plan(tomorrow, nxt)
        plan.update(evening_at=now.isoformat(), done=[d["title"] for d in done], rolled=rolled)
        self.save_plan(day, plan)
        await self.queue.wake()
        if self.cfg.daily.discord and (self.cfg.push.discord_too or not self.push):
            await self.alerter.send("daily", self.evening_text(day, plan, nxt))
        if self.push:
            body = (f"✅ {len(done)} done" if done else "Nothing ticked off — that's okay.") + (
                f" · ↪️ {len(rolled)} moved off Today" if rolled else "") + "\nTap to pick tomorrow's three."
            await self.push.send("daily", "Wrapping up", body, url="/today", tag=f"evening:{day.isoformat()}")
        return plan

    def evening_text(self, day: date, plan: dict[str, Any], nxt: dict[str, Any]) -> str:
        lines = [f"🌙 **Wrapping up** — {day:%a %b %-d}"]
        done = plan.get("done", [])
        lines.append(f"✅ Done ({len(done)}): " + ", ".join(done) if done else "✅ Nothing ticked off today — that's okay.")
        if plan.get("rolled"):
            lines.append("↪️ Moved back off Today (no overdue pile): " + ", ".join(plan["rolled"]))
        tomorrow = nxt.get("preselected_titles") or [s["title"] for s in nxt.get("suggested", [])]
        if tomorrow:
            lines.append("Tomorrow I'd suggest: " + "; ".join(f"{i}. {t}" for i, t in enumerate(tomorrow, 1)))
        lines.append(f"Change tomorrow's picks: {self.cfg.dashboard.public_url.rstrip('/')}/today")
        return "\n".join(lines)

    def preselect(self, day: date, item_ids: list[str]) -> None:
        plan = self.plan(day)
        plan["preselected"] = item_ids[: self.cfg.daily.count]
        plan["preselected_titles"] = [(self.items.get(i) or {}).get("title", "?") for i in plan["preselected"]]
        self.save_plan(day, plan)

    # ---- scheduler -------------------------------------------------------------------------------------------
    async def tick(self, now: datetime | None = None) -> None:
        if not self.cfg.daily.enabled:
            return
        now = now or datetime.now(timezone.utc)
        local = now.astimezone(self.cfg.tz)
        hm = local.strftime("%H:%M")
        plan = self.plan(local.date())
        if self.cfg.daily.morning_time <= hm < self.cfg.daily.evening_time and not plan.get("picks"):
            await self.morning(now)
        elif hm >= self.cfg.daily.evening_time and plan.get("picks") and not plan.get("evening_at"):
            await self.evening(now)

    # ---- tick off from the app ------------------------------------------------------------------------------
    async def set_done(self, item_id: str, done: bool) -> dict[str, Any]:
        it = self.items.get(item_id)
        if not it or it["kind"] != "reminder":
            raise ValueError("unknown item")
        if done and it["status"] not in ("planned", "active"):
            return {"status": it["status"]}
        if not done and it["status"] != "completed":
            return {"status": it["status"]}
        purpose = "complete" if done else "update"
        self.db.insert_command(f"app:{self.today().isoformat()}", "update_item",
                               {"apple_item_id": it.get("apple_item_id"), "tag": it["tag"], "kind": "reminder",
                                "changes": {"completed": done}, "notes_append": None},
                               "pending", item_id=item_id, purpose=purpose,
                               meta={"previous": {"completed": not done}, "why": "ticked in the app", "title": it["title"],
                                     "applied": True})
        # Show it right away; the Mac's result confirms it (completion sync would correct a failure).
        fields: dict[str, Any] = {"status": "completed" if done else "active"}
        if done:
            fields["completed_at"] = datetime.now(timezone.utc).isoformat()
        self.items.update(item_id, **fields)
        self.items.log(item_id, None, "completed" if done else "reopened", {"via": "app"})
        await self.queue.wake()
        self.bus.publish({"type": "items"})
        return {"status": fields["status"]}

    # ---- breakdown on demand ---------------------------------------------------------------------------------
    async def breakdown(self, item_id: str) -> dict[str, Any]:
        it = self.items.get(item_id)
        if not it:
            raise ValueError("unknown item")
        if not hasattr(self.llm, "complete_json"):
            raise ValueError("the model client doesn't support this")
        messages = [
            {"role": "system", "content": (
                "Break a task into a tiny first step (≤10 minutes, concrete, physical if possible) and up to 4 "
                "next steps, for someone with ADHD who struggles to start. Plain, short, no fluff. JSON only.")},
            {"role": "user", "content": f"Task: {it['title']}\nContext: {(it['state'].get('notes') or '')[:600]}"},
        ]
        data = json.loads(await self.llm.complete_json(messages, BREAKDOWN_SCHEMA, "breakdown"))
        first = (data.get("first_step") or "").strip()
        steps = [s.strip() for s in data.get("steps", []) if s and s.strip()][:5]
        text = f"👉 Start: {first}" + ("\nSteps:\n" + "\n".join(f"☐ {s}" for s in steps) if steps else "")
        self.items.update(item_id, state={**it["state"], "first_step": first, "steps": steps})
        self.items.log(item_id, None, "broken down", {"first_step": first, "steps": steps})
        if it.get("apple_item_id") or it["status"] in ("planned", "active"):
            self.db.insert_command(f"assist:{item_id}", "update_item",
                                   {"apple_item_id": it.get("apple_item_id"), "tag": it["tag"], "kind": it["kind"],
                                    "changes": {}, "notes_append": text},
                                   "pending", item_id=item_id, purpose="update",
                                   meta={"previous": {}, "why": "break it down", "title": it["title"]})
            await self.queue.wake()
        return {"first_step": first, "steps": steps}
