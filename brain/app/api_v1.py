"""JSON API for the native iPhone app (/api/v1/...).

The web dashboard renders HTML on the server; the app needs the same screens as data. Every
endpoint returns small, flat, stable shapes (no internal rows), so the Swift side can decode them
strictly. Actions reuse the existing endpoints (/api/items/..., /actions/..., /api/today/...).
"""
from __future__ import annotations

import json
from datetime import date, datetime, time, timedelta, timezone
from typing import Any, Callable

import base64
import hashlib

from fastapi import APIRouter, Body, Depends, HTTPException
from pydantic import BaseModel, Field

from .gate import normalize_handle
from .people import AvatarIn, AvatarReport
from .settings import SettingsError
from .timeline import Timeline

from . import __version__
from . import models as m
from . import views
from .home import home as build_home


class SourceToggle(BaseModel):
    kind: str = Field(pattern="^(calendar|list)$")
    name: str = Field(min_length=1, max_length=200)
    shown: bool


class AppleDone(BaseModel):
    done: bool = True


class AppleMove(BaseModel):
    due: str = Field(pattern=r"^\d{4}-\d{2}-\d{2}$")
    due_time: str | None = Field(default=None, pattern=r"^\d{1,2}:\d{2}$")


class NewPerson(BaseModel):
    name: str | None = Field(default=None, max_length=120)
    label: str = Field(min_length=1, max_length=60)
    handle: str = Field(min_length=3, max_length=120)
    photo: str | None = Field(default=None, max_length=400_000)   # base64 JPEG
    is_me: bool = False

STATUS_LABEL = {
    m.DONE: "Done", m.QUEUED: "Queued", m.RECEIVED: "Processing", m.SKIPPED: "Skipped",
    m.NEEDS_REVIEW: "Needs review", m.FAILED: "Failed", m.REJECTED: "Rejected", m.UNDOING: "Undoing",
    m.UNDONE: "Undone",
}
STEP_LABEL = {
    "ingest": "Received", "allowlist": "Allowlist", "gate": "Gate", "extract": "LLM extraction",
    "extract_error": "LLM error", "plan": "Planner", "queue": "Queued for Mac", "command_sent": "Sent to Mac",
    "command_result": "Mac result", "review": "Review", "undo": "Undo", "retry": "Retry", "edit": "Edited",
}


def _iso(v: Any) -> str | None:
    if v is None:
        return None
    if isinstance(v, datetime):
        return v.isoformat()
    return str(v)


def _plain(v: Any) -> Any:
    """Round-trip through JSON so datetimes etc. become strings."""
    return json.loads(json.dumps(v, default=str))


def build_router(*, cfg, db, pipeline, daily, health, queue, external, people, weekly, focus, quick,
                 settings, push, dash_auth: Callable, badge_count: Callable[[], int],
                 wake: Callable | None = None, bus=None) -> APIRouter:
    r = APIRouter(prefix="/api/v1", dependencies=[Depends(dash_auth)])
    items = pipeline.items
    timeline_builder = Timeline(cfg, db, items, external, people)

    def collection_label(key: str | None) -> str | None:
        if not key:
            return None
        c = next((c for c in cfg.collections if c.key == key), None)
        return c.label if c else key

    # ---- shapes ---------------------------------------------------------------------------------
    def item_dto(it: dict[str, Any] | None, *, with_log: bool = False, with_origin: bool = False) -> dict | None:
        if not it:
            return None
        st = it.get("state") or {}
        if isinstance(st, str):
            st = json.loads(st)
        out = {
            "id": it["item_id"], "title": it["title"], "kind": it["kind"],
            "category": it.get("category") or ("collection" if it.get("collection") else it["kind"] == "event" and "event" or "todo"),
            "collection": it.get("collection"), "collection_label": collection_label(it.get("collection")),
            "person": it.get("person") if it.get("person") not in ("Me",) else None,
            "status": it["status"],
            "due": st.get("due"), "due_time": st.get("due_time"),
            "start": st.get("start"), "end": st.get("end"), "all_day": bool(st.get("all_day")),
            "location": st.get("location"), "list": st.get("list") or st.get("calendar"),
            "section": st.get("section"), "tags": st.get("tags") or [], "url": st.get("url"),
            "first_step": st.get("first_step"), "steps": st.get("steps") or [],
            "notes": st.get("notes"),
            "origin_event_id": it.get("origin_event_id"),
            "created_at": it.get("created_at"), "updated_at": it.get("updated_at"),
            "completed_at": it.get("completed_at"),
        }
        if with_origin:
            ev = db.one("SELECT text, sender_label, received_at, is_from_me FROM events WHERE event_id=?",
                        (it.get("origin_event_id"),))
            out["origin"] = {"text": ev["text"], "sender": ev["sender_label"], "from_me": bool(ev["is_from_me"]),
                             "at": ev["received_at"]} if ev else None
        if with_log:
            out["log"] = [{"action": h["action"], "at": h["at"], "event_id": h["event_id"],
                           "detail": _describe_log(h["detail"])} for h in items.history(it["item_id"])]
        return out

    def _describe_log(detail: Any) -> str | None:
        if not detail:
            return None
        if isinstance(detail, dict):
            if detail.get("changes"):
                return ", ".join(f"{k}: {v}" for k, v in detail["changes"].items() if k != "alert")
            if detail.get("via"):
                return f"via {detail['via']}"
            if detail.get("error"):
                return str(detail["error"])
            if detail.get("minutes"):
                return f"{detail['minutes']} min"
        return None

    def event_dto(e: dict[str, Any]) -> dict[str, Any]:
        ex = e.get("extraction")
        if isinstance(ex, str):
            ex = json.loads(ex) if ex else None
        actions = [{"type": a.get("type"), "title": a.get("title") or ""} for a in (ex or {}).get("actions", [])]
        return {
            "id": e["event_id"], "source": e["source"], "sender": e.get("sender_label") or e.get("sender_handle"),
            "sender_handle": e.get("sender_handle"), "from_me": bool(e.get("is_from_me")),
            "text": e["text"], "subject": e.get("subject"), "received_at": e["received_at"],
            "status": e["status"], "status_label": STATUS_LABEL.get(e["status"], e["status"]),
            "reason": e.get("reason"), "confidence": e.get("confidence"), "actions": actions,
            "photo": people.avatar_url(e.get("sender_handle")) or people.photo_for_label(e.get("sender_label")),
        }

    def agenda_dto(u: dict[str, Any]) -> dict[str, Any]:
        return {"title": u["title"], "when": _iso(u["when"]), "all_day": bool(u.get("all_day")),
                "kind": u.get("kind", "reminder"), "where": u.get("where"), "who": u.get("who"),
                "location": u.get("location"), "item_id": u.get("item_id"), "event_id": u.get("event_id"),
                "external": bool(u.get("external")), "apple_id": u.get("apple_id"), "color": u.get("color"),
                "late": bool(u.get("late"))}

    def person_dto(p: dict[str, Any]) -> dict[str, Any]:
        return {"key": p["key"], "label": p["label"], "handle": p.get("handle"), "group": bool(p.get("group")),
                "photo": p.get("photo"), "contact_name": p.get("contact_name"), "mentioned": bool(p.get("mentioned")),
                "last": p.get("last"), "promises": p.get("promises", 0), "waiting": p.get("waiting", 0),
                "gifts": p.get("gifts", 0), "facts": p.get("facts", 0), "todos": p.get("todos", 0)}

    def proposals(e: dict[str, Any]) -> list[dict[str, Any]]:
        out = []
        for c in db.commands_for_event(e["event_id"]):
            if c["generation"] != e["generation"] or c["status"] != "held":
                continue
            p, meta = c["payload"], c["meta"] or {}
            out.append({"command_id": c["command_id"], "op": c["op"],
                        "title": p.get("title") or meta.get("title") or "item",
                        "due": p.get("due"), "due_time": p.get("due_time"), "start": p.get("start"),
                        "all_day": bool(p.get("all_day")), "list": p.get("list") or p.get("calendar"),
                        "collection": collection_label(meta.get("collection")), "person": meta.get("person"),
                        "summary": meta.get("summary")})
        return out

    def review_reasons(e: dict[str, Any]) -> list[str]:
        for t in reversed(db.get_trace(e["event_id"])):
            if t["step"] == "plan" and t["data"]:
                return list(t["data"].get("review_reasons") or [])
        return [e["reason"]] if e.get("reason") else []

    # ---- endpoints ------------------------------------------------------------------------------
    @r.get("/info")
    async def info():
        snap = health.snapshot(queue.depth())
        return {"app_name": cfg.dashboard.app_name, "version": __version__, "timezone": cfg.timezone,
                "now": datetime.now(cfg.tz).isoformat(), "badge": badge_count(),
                "review_count": db.one("SELECT COUNT(*) n FROM events WHERE status=?", (m.NEEDS_REVIEW,))["n"],
                "agent_online": bool(snap["agent"].get("online")), "llm_ok": bool(snap["llm"].get("reachable")),
                "public_url": cfg.dashboard.public_url or None,
                "morning_time": cfg.daily.morning_time, "evening_time": cfg.daily.evening_time}

    @r.get("/home")
    async def home():
        h = build_home(db, cfg, daily, items, health.snapshot(queue.depth()), external)
        att = h["attention"]
        nxt = h["next"]
        picks = []
        for p in h["picks"]:
            it = items.get(p["item_id"])
            picks.append({"item_id": p["item_id"], "title": (it or {}).get("title") or p.get("title", ""),
                          "why": p.get("why"), "first_step": p.get("first_step"), "status": p["status"],
                          "kind": p["kind"], "category": (it or {}).get("category"),
                          "snoozed_to": p.get("snoozed_to")})
        return {
            "greeting": h["greeting"], "now": h["now"].isoformat(), "done_today": h["done_today"],
            "problems": h["problems"],
            "next": {"kind": nxt["kind"], "title": nxt["title"], "at": _iso(nxt["at"]), "end": _iso(nxt.get("end")),
                     "ongoing": nxt["ongoing"], "in": nxt["in"], "where": nxt.get("where"),
                     "event_id": nxt.get("event_id"), "item_id": nxt.get("item_id"), "color": nxt.get("color")}
            if nxt else None,
            "picks": picks, "picks_left": h["picks_left"],
            "before_morning": h["before_morning"], "evening": h["evening"], "morning_time": cfg.daily.morning_time,
            "attention": {
                "reviews": [{"event": event_dto(x["e"]), "titles": x["titles"]} for x in att["reviews"]],
                "followups": [item_dto(i) for i in att["followups"]],
                "late": [item_dto(i) for i in att["late"]],
                "failed": att["failed"], "count": att["count"],
            },
            "agenda": [agenda_dto(u) for u in h["agenda"]],
            "recent": [{"verb": x["verb"], "title": x["title"], "person": x["person"] if x["person"] != "Me" else None,
                        "kind": x["kind"], "category": x["category"], "collection": x["collection"],
                        "at": x["at"], "via": x["via"], "event_id": x["event_id"]} for x in h["recent"]],
            "weekly_count": len(weekly.stale()) if weekly.due() else 0,
        }

    @r.get("/today")
    async def today():
        day = daily.today()
        plan = daily.plan(day)
        picks = []
        for p in plan.get("picks", []):
            it = items.get(p["item_id"])
            picks.append({"item_id": p["item_id"], "title": (it or {}).get("title") or p.get("title", ""),
                          "why": p.get("why"), "first_step": p.get("first_step"),
                          "status": it["status"] if it else "gone", "kind": (it or {}).get("kind", "reminder"),
                          "category": (it or {}).get("category"), "snoozed_to": p.get("snoozed_to")})
        tomorrow = daily.plan(day + timedelta(days=1))
        chosen = tomorrow.get("preselected") or [s["item_id"] for s in tomorrow.get("suggested", [])]
        events = []
        for e in daily.events_on(day):
            st = e.get("state") or {}
            events.append({"title": e.get("title"), "start": st.get("start"), "end": st.get("end"),
                           "all_day": bool(st.get("all_day")), "where": st.get("location") or st.get("calendar"),
                           "external": not e.get("item_id") or bool(e.get("external"))})
        cands = []
        for c in daily.candidates(datetime.now(cfg.tz), limit=15):
            d = item_dto(c)
            d.update(why=c.get("why"), first_step=c.get("first_step") or d["first_step"])
            cands.append(d)
        return {"date": day.isoformat(), "summary": plan.get("summary"), "picks": picks,
                "done": [item_dto(i) for i in daily.done_on(day)], "events": events, "candidates": cands,
                "tomorrow_chosen": chosen, "tomorrow_locked": bool(tomorrow.get("preselected")),
                "morning_time": cfg.daily.morning_time, "evening_time": cfg.daily.evening_time,
                "evening_done": bool(plan.get("evening_at"))}

    @r.get("/weekly")
    async def weekly_cards():
        return {"cards": weekly.stale(), "last": weekly.last(), "due": weekly.due()}

    @r.get("/people")
    async def people_list():
        return {"people": [person_dto(p) for p in people.roster()]}

    @r.get("/people/{key}")
    async def person(key: str):
        p = people.find(key)
        if not p:
            raise HTTPException(404, "unknown person")
        d = people.detail(p, items)
        return {"person": person_dto(p),
                **{k: [item_dto(i) for i in d[k]] for k in ("promises", "waiting", "todos", "gifts", "facts", "other", "done")},
                "messages": [{"event_id": x["event_id"], "text": x["text"], "from_me": bool(x["is_from_me"]),
                              "at": x["received_at"], "status": x["status"]} for x in reversed(d["messages"])]}

    @r.get("/items")
    async def items_list(tab: str = "todos"):
        counts = {
            "todos": len(items.listing(statuses=("proposed", "planned", "active"), collection=None)),
            "collections": len(items.listing(statuses=("planned", "active"), collection=True)),
            "history": len(items.listing(statuses=("completed", "cancelled", "undone", "rejected", "failed", "deleted"))),
        }
        groups: list[dict[str, Any]] = []
        rows: list[dict] = []
        if tab == "collections":
            by: dict[str, dict[str, list]] = {}
            for it in items.listing(statuses=("planned", "active"), collection=True):
                by.setdefault(it["collection"], {}).setdefault(it["person"] or "Unassigned", []).append(
                    item_dto(it, with_origin=True))
            groups = [{"key": k, "label": collection_label(k), "people": [{"person": p, "items": v} for p, v in ps.items()]}
                      for k, ps in by.items()]
        elif tab == "history":
            rows = [item_dto(i, with_log=True, with_origin=True) for i in items.listing(
                statuses=("completed", "cancelled", "undone", "rejected", "failed", "deleted"), limit=200)]
        else:
            tab = "todos"
            rows = [item_dto(i, with_log=True, with_origin=True)
                    for i in items.listing(statuses=("proposed", "planned", "active"), collection=None)]
        return {"tab": tab, "counts": counts, "items": rows, "groups": groups,
                "upcoming": [agenda_dto(u) for u in views.upcoming(db, cfg, 14)]}

    @r.get("/review")
    async def review():
        out = []
        for e in db.recent_events(limit=200, status=m.NEEDS_REVIEW):
            out.append({"event": event_dto(e), "proposals": proposals(e), "reasons": review_reasons(e)})
        return {"items": out}

    @r.get("/activity")
    async def activity(q: str | None = None, status: str | None = None, source: str | None = None, limit: int = 150):
        evs = views.search_events(db, q=q, status=status or None, source=source or None, limit=min(limit, 500))
        return {"events": [event_dto(e) for e in evs], "counts": views.status_counts(db),
                "statuses": [{"key": k, "label": v} for k, v in STATUS_LABEL.items()]}

    @r.get("/events/{event_id:path}")
    async def event_detail(event_id: str):
        ev = db.get_event(event_id)
        if not ev:
            raise HTTPException(404, "unknown event")
        cmds = db.commands_for_event(event_id)
        gen = [c for c in cmds if c["generation"] == ev["generation"]]
        can = {
            "approve": ev["status"] == m.NEEDS_REVIEW and any(c["status"] == "held" for c in gen),
            "reject": ev["status"] == m.NEEDS_REVIEW,
            "undo": any(c["status"] == "done" and not c["undo_of"] for c in gen) and ev["status"] not in (m.UNDONE, m.UNDOING),
            "retry": ev["status"] not in (m.UNDOING,),
        }
        trace = [{"step": t["step"], "label": STEP_LABEL.get(t["step"], t["step"]), "summary": _trace_summary(t["step"], t["data"]),
                  "duration_ms": t["duration_ms"], "at": t["created_at"]} for t in db.get_trace(event_id)]
        commands = [{"command_id": c["command_id"], "op": c["op"], "status": c["status"], "purpose": c.get("purpose"),
                     "title": c["payload"].get("title") or (c["meta"] or {}).get("title"), "error": c["error"],
                     "undo": bool(c["undo_of"]), "generation": c["generation"], "item_id": c.get("item_id")}
                    for c in cmds]
        its = [item_dto(i) for i in db.all("SELECT * FROM items WHERE origin_event_id=? ORDER BY seq", (event_id,))
               for i in [items._decode(i)]]
        ex = ev["extraction"]
        return {"event": event_dto(ev), "context": ev["recent_context"], "can": can, "trace": trace,
                "commands": commands, "items": its, "proposals": proposals(ev), "reasons": review_reasons(ev)
                if ev["status"] == m.NEEDS_REVIEW else [],
                "reasoning": (ex or {}).get("reasoning_brief"), "prompt_version": ev.get("prompt_version"),
                "extraction": json.dumps(ex or {"actionable": True, "actions": [], "confidence": 1.0,
                                                 "reasoning_brief": "added manually"}, indent=2, ensure_ascii=False),
                "last_error": ev.get("last_error")}

    @r.get("/system")
    async def system():
        snap = health.snapshot(queue.depth())
        ov = views.overview(db, cfg, snap)
        return _plain({
            "version": __version__, "health": snap, "today": ov["today"], "review": ov["review"],
            "failed_24h": ov["failed_24h"], "funnel": ov["funnel"], "latency": ov["latency"], "daily": ov["daily"],
            "alerts": db.all("SELECT kind, message, delivered, created_at FROM alerts ORDER BY id DESC LIMIT 30"),
            "commands": [{"command_id": c["command_id"], "op": c["op"], "status": c["status"],
                          "title": c["payload"].get("title"), "sender": c.get("sender_label"), "created_at": c["created_at"]}
                         for c in views.open_commands(db)],
            "last_backup": db.kv_get("last_backup"), "db": views.db_info(db), "settings_version": settings.version,
            "push_devices": len(push.devices()),
        })

    @r.get("/notifications")
    async def notifications(after: int = 0, limit: int = 30):
        """What the brain would notify about (the same feed web push uses), for the app's local notifications."""
        rows = db.all("""SELECT id, kind, title, body, url, at FROM push_log WHERE id > ?
                         AND (skipped IS NULL OR skipped = 'no devices') ORDER BY id DESC LIMIT ?""",
                      (after, max(1, min(limit, 100))))
        last = db.one("SELECT MAX(id) n FROM push_log")["n"] or 0
        return {"items": list(reversed(rows)), "last_id": last, "badge": badge_count()}

    # ---- timeline (Today) ---------------------------------------------------------------------
    @r.get("/timeline")
    async def timeline(day: str | None = None):
        today = daily.today()
        try:
            d = date.fromisoformat(day) if day else today
        except ValueError:
            raise HTTPException(400, "day must be YYYY-MM-DD") from None
        out = timeline_builder.build(d, datetime.now(cfg.tz), today)
        first = db.recent_events(limit=200, status=m.NEEDS_REVIEW)
        out["banner"] = ({"count": len(first), "entry": {"event": event_dto(first[0]), "proposals": proposals(first[0]),
                                                          "reasons": review_reasons(first[0])}}
                         if first else None)
        return _plain(out)

    # ---- calendars & lists shown on Today ---------------------------------------------------------
    @r.get("/sources")
    async def sources():
        return external.sources()

    @r.post("/sources")
    async def set_source(body: SourceToggle):
        external.set_shown(body.kind, body.name, body.shown)
        if bus:
            bus.publish({"type": "snapshot"})
        return external.sources()

    # ---- your own reminders (not made by Second Brain) ----------------------------------------
    async def _queue_apple(apple_id: str, changes: dict, purpose: str, why: str) -> None:
        db.insert_command(f"app:{daily.today().isoformat()}", "update_item",
                          {"apple_item_id": apple_id, "tag": None, "kind": "reminder", "changes": changes,
                           "notes_append": None},
                          "pending", purpose=purpose, meta={"why": why, "external": True})
        if wake:
            await wake()
        if bus:
            bus.publish({"type": "snapshot"})

    @r.post("/apple/{apple_id:path}/done")
    async def apple_done(apple_id: str, body: AppleDone = Body(default_factory=AppleDone)):
        await _queue_apple(apple_id, {"completed": body.done}, "complete" if body.done else "update",
                           "ticked in the app" if body.done else "unticked in the app")
        external.mark_done(apple_id, body.done)
        return {"ok": True, "status": "completed" if body.done else "open"}

    @r.post("/apple/{apple_id:path}/move")
    async def apple_move(apple_id: str, body: AppleMove):
        try:
            d = date.fromisoformat(body.due)
            hh, mm = (int(x) for x in body.due_time.split(":")) if body.due_time else (None, None)
            t = time(hh, mm) if body.due_time else None
        except ValueError:
            raise HTTPException(400, "bad date or time") from None
        due_time = t.strftime("%H:%M") if t else None
        alert = datetime.combine(d, t or time.fromisoformat(cfg.rules.default_alert_time), cfg.tz).isoformat()
        await _queue_apple(apple_id, {"due": d.isoformat(), "due_time": due_time, "alert": alert}, "update",
                           "moved in the app")
        external.patch_reminder(apple_id, due=d.isoformat(), due_time=due_time)
        label = d.strftime("%a %b %-d") + (f", {t.strftime('%-I:%M %p')}" if t else "")
        return {"ok": True, "status": "moved", "label": label}

    # ---- people from Contacts --------------------------------------------------------------------
    def _allow_rows() -> list[dict]:
        return [a.model_dump(mode="json") for a in cfg.watch.imessage.allow]

    @r.post("/people")
    async def add_person(body: NewPerson):
        h = normalize_handle(body.handle)
        rows = _allow_rows()
        hit = next((a for a in rows if a.get("handle") and normalize_handle(a["handle"]) == h), None)
        if hit and hit.get("enabled", True):
            raise HTTPException(409, "already watching")
        if hit:
            hit.update(enabled=True, label=body.label.strip(), is_me=body.is_me)
        else:
            rows.append({"handle": body.handle.strip(), "chat_id": None, "label": body.label.strip(),
                         "enabled": True, "is_me": body.is_me})
        try:
            settings.update({"watch": {"imessage": {"allow": rows}}})
        except SettingsError as e:
            raise HTTPException(400, str(e)) from None
        photo = None
        if body.photo:
            try:
                raw = base64.b64decode(body.photo, validate=True)
                photo = (body.photo, hashlib.sha1(raw).hexdigest()[:16])
            except ValueError:
                photo = None
        people.store_avatars(AvatarReport(people=[AvatarIn(
            handle=body.handle, name=(body.name or "").strip() or None,
            image=photo[0] if photo else None, image_hash=photo[1] if photo else None)]))
        p = next((p for p in people.roster() if p.get("handle") and normalize_handle(p["handle"]) == h), None)
        if not p:  # "me" isn't in the roster; describe it anyway
            p = {"key": "h-me", "label": body.label, "handle": body.handle, "group": False,
                 "photo": people.avatar_url(body.handle), "contact_name": body.name}
        return {"person": person_dto(p)}

    @r.delete("/people/{key}")
    async def remove_person(key: str):
        p = people.find(key)
        if not p or not (p.get("handle") or p.get("chat_id")):
            raise HTTPException(404, "not someone you watch")
        rows = [a for a in _allow_rows()
                if not ((p.get("handle") and a.get("handle") and normalize_handle(a["handle"]) == normalize_handle(p["handle"]))
                        or (p.get("chat_id") and a.get("chat_id") == p["chat_id"]))]
        try:
            settings.update({"watch": {"imessage": {"allow": rows}}})
        except SettingsError as e:
            raise HTTPException(400, str(e)) from None
        return {"ok": True, "status": "removed"}

    return r


def _trace_summary(step: str, d: Any) -> str | None:
    d = d or {}
    try:
        if step == "gate":
            return "passed" if d.get("decision") == "pass" else str(d.get("reason", "")).replace("_", " ")
        if step == "extract":
            p = d.get("parsed") or {}
            n = len(p.get("actions") or [])
            s = f"{n} action{'s' if n != 1 else ''} · {round((p.get('confidence') or 0) * 100)}%"
            if d.get("open_items"):
                s += f" · saw {len(d['open_items'])} open item{'s' if len(d['open_items']) != 1 else ''}"
            return s
        if step == "plan":
            n = len(d.get("commands") or [])
            s = f"{n} command{'s' if n != 1 else ''}"
            if d.get("review_reasons"):
                s += " · review: " + "; ".join(d["review_reasons"])
            if d.get("skipped"):
                s += f" · {len(d['skipped'])} skipped"
            return s
        if step in ("command_sent", "command_result"):
            s = str(d.get("op", "")).replace("_", " ")
            if d.get("status"):
                s += f" · {d['status']}"
            if d.get("error"):
                s += f" · {d['error']}"
            return s
        if step == "allowlist":
            return d.get("label")
        if step == "review":
            return d.get("decision")
        if step == "extract_error":
            return str(d.get("error") or "")[:200]
    except Exception:  # noqa: BLE001 — a summary must never break the page
        return None
    return None
