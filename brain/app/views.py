"""Read-only queries that feed the dashboard (overview, activity, system)."""
from __future__ import annotations

import json
import os
from datetime import date, datetime, time, timedelta, timezone
from typing import Any

from . import models as m
from .config import Config
from .models import DB

GATE_REASONS = ("from_me", "empty", "tapback", "emoji_only", "too_short", "filler")


def _since(hours: float) -> str:
    return (datetime.now(timezone.utc) - timedelta(hours=hours)).isoformat()


def _local_midnight_utc(cfg: Config, d: date) -> str:
    return datetime.combine(d, time(0), cfg.tz).astimezone(timezone.utc).isoformat()


def funnel(db: DB, hours: float = 24) -> dict[str, int]:
    """How messages flowed through the pipeline stages in the window."""
    rows = db.all("SELECT status, reason, actionable FROM events WHERE created_at >= ?", (_since(hours),))
    f = {"received": len(rows), "gated": 0, "to_llm": 0, "actionable": 0, "created": 0,
         "review": 0, "failed": 0, "pending": 0}
    for r in rows:
        if r["status"] == m.SKIPPED and r["reason"] in GATE_REASONS:
            f["gated"] += 1
            continue
        if r["actionable"] is not None:
            f["to_llm"] += 1
            f["actionable"] += r["actionable"]
        if r["status"] == m.DONE:
            f["created"] += 1
        elif r["status"] == m.NEEDS_REVIEW:
            f["review"] += 1
        elif r["status"] == m.FAILED:
            f["failed"] += 1
        elif r["status"] in (m.RECEIVED, m.QUEUED):
            f["pending"] += 1
    return f


def daily(db: DB, cfg: Config, days: int = 14) -> list[dict[str, Any]]:
    today = datetime.now(cfg.tz).date()
    start = today - timedelta(days=days - 1)
    buckets = {(start + timedelta(days=i)).isoformat(): {"messages": 0, "actionable": 0, "created": 0}
               for i in range(days)}
    for r in db.all("SELECT created_at, actionable FROM events WHERE created_at >= ?",
                    (_local_midnight_utc(cfg, start),)):
        d = datetime.fromisoformat(r["created_at"]).astimezone(cfg.tz).date().isoformat()
        if d in buckets:
            buckets[d]["messages"] += 1
            buckets[d]["actionable"] += r["actionable"] or 0
    for r in db.all("""SELECT completed_at FROM commands WHERE op != 'delete_item' AND status='done'
                       AND undo_of IS NULL AND completed_at >= ?""", (_local_midnight_utc(cfg, start),)):
        d = datetime.fromisoformat(r["completed_at"]).astimezone(cfg.tz).date().isoformat()
        if d in buckets:
            buckets[d]["created"] += 1
    return [{"date": d, **v} for d, v in buckets.items()]


def latency(db: DB, hours: float = 24 * 7) -> dict[str, int | None]:
    lat = sorted(r["extract_ms"] for r in db.all(
        "SELECT extract_ms FROM events WHERE extract_ms IS NOT NULL AND created_at >= ?", (_since(hours),)))
    if not lat:
        return {"avg": None, "p50": None, "p90": None, "n": 0}
    return {"avg": round(sum(lat) / len(lat)), "p50": lat[len(lat) // 2], "p90": lat[int(len(lat) * 0.9)],
            "n": len(lat)}


def live_items(db: DB) -> list[dict[str, Any]]:
    """Items the agent created that have not been undone (newest first)."""
    rows = db.all("""
        SELECT c.*, e.sender_label, e.text FROM commands c JOIN events e ON e.event_id = c.event_id
        WHERE c.op IN ('create_reminder','create_event') AND c.status='done' AND c.generation = e.generation
          AND NOT EXISTS (SELECT 1 FROM commands d WHERE d.undo_of = c.command_id AND d.status IN ('done','pending','sent'))
        ORDER BY c.rowid DESC LIMIT 300""")
    for r in rows:
        r["payload"] = json.loads(r["payload"])
    return rows


def upcoming(db: DB, cfg: Config, days: int = 7) -> list[dict[str, Any]]:
    today = datetime.now(cfg.tz).date()
    horizon = today + timedelta(days=days)
    out = []
    for c in live_items(db):
        p = c["payload"]
        if c["op"] == "create_reminder":
            if not p.get("due"):
                continue
            when = datetime.combine(date.fromisoformat(p["due"]),
                                    time.fromisoformat(p["due_time"]) if p.get("due_time") else time(23, 59), cfg.tz)
            all_day = not p.get("due_time")
        else:
            when = datetime.fromisoformat(p["start"]).astimezone(cfg.tz)
            all_day = p.get("all_day", False)
        if today <= when.date() <= horizon:
            out.append({"kind": "reminder" if c["op"] == "create_reminder" else "event", "title": p["title"],
                        "when": when, "all_day": all_day, "event_id": c["event_id"],
                        "where": p.get("list") or p.get("calendar"), "who": c["sender_label"]})
    out.sort(key=lambda x: x["when"])
    return out


def open_commands(db: DB) -> list[dict[str, Any]]:
    rows = db.all("""SELECT c.*, e.sender_label FROM commands c LEFT JOIN events e ON e.event_id=c.event_id
                     WHERE c.status IN ('pending','sent','held') ORDER BY c.rowid""")
    for r in rows:
        r["payload"] = json.loads(r["payload"])
    return rows


def search_events(db: DB, *, q: str | None, status: str | None, source: str | None,
                  limit: int = 100) -> list[dict[str, Any]]:
    where, params = [], []
    if status:
        where.append("status = ?")
        params.append(status)
    if source:
        where.append("source = ?")
        params.append(source)
    if q:
        where.append("(text LIKE ? OR subject LIKE ? OR sender_label LIKE ? OR extraction LIKE ?)")
        params += [f"%{q}%"] * 4
    sql = "SELECT * FROM events" + (" WHERE " + " AND ".join(where) if where else "") + " ORDER BY id DESC LIMIT ?"
    rows = db.all(sql, (*params, limit))
    for r in rows:
        r["recent_context"] = json.loads(r["recent_context"] or "[]")
        r["extraction"] = json.loads(r["extraction"]) if r["extraction"] else None
    return rows


def status_counts(db: DB) -> dict[str, int]:
    return {r["status"]: r["n"] for r in db.all("SELECT status, COUNT(*) n FROM events GROUP BY status")}


def db_info(db: DB) -> dict[str, Any]:
    size = None
    if db.path != ":memory:" and os.path.exists(db.path):
        size = os.path.getsize(db.path) + (os.path.getsize(db.path + "-wal") if os.path.exists(db.path + "-wal") else 0)
    counts = {t: db.one(f"SELECT COUNT(*) n FROM {t}")["n"] for t in ("events", "trace", "commands", "alerts")}
    return {"path": db.path, "size_bytes": size, "counts": counts}


def overview(db: DB, cfg: Config, health_snapshot: dict[str, Any]) -> dict[str, Any]:
    today_start = _local_midnight_utc(cfg, datetime.now(cfg.tz).date())
    today_msgs = db.one("SELECT COUNT(*) n FROM events WHERE created_at >= ?", (today_start,))["n"]
    today_items = db.one("""SELECT COUNT(*) n FROM commands WHERE op != 'delete_item' AND undo_of IS NULL
                            AND status='done' AND completed_at >= ?""", (today_start,))["n"]
    counts = status_counts(db)
    return {
        "health": health_snapshot,
        "today": {"messages": today_msgs, "created": today_items},
        "review": counts.get(m.NEEDS_REVIEW, 0),
        "failed_24h": db.one("SELECT COUNT(*) n FROM events WHERE status=? AND updated_at >= ?",
                             (m.FAILED, _since(24)))["n"],
        "funnel": funnel(db, 24),
        "latency": latency(db),
        "daily": daily(db, cfg, 14),
        "last_alert": db.one("SELECT * FROM alerts ORDER BY id DESC LIMIT 1"),
    }
