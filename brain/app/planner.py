"""Extraction → mac-agent commands. Applies config rules/defaults and decides on review."""
from __future__ import annotations

import math
import re
from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta

from .config import Config
from .schemas import Action, Event, Extraction, PlannedCommand


@dataclass
class Plan:
    commands: list[PlannedCommand] = field(default_factory=list)
    review_reasons: list[str] = field(default_factory=list)

    @property
    def needs_review(self) -> bool:
        return bool(self.review_reasons)


def item_tag(event_id: str, seq: int) -> str:
    return f"[ha:{event_id}]" if seq == 0 else f"[ha:{event_id}#{seq}]"


def route_list(cfg: Config, action: Action) -> str:
    haystack = f"{action.title} {action.source_quote}".lower()
    for route in cfg.rules.lists.routes:
        for word in route.match:
            if re.search(rf"\b{re.escape(word.lower())}(s|es)?\b", haystack):
                return route.list
    if action.list:
        for name in cfg.known_lists():
            if name.lower() == action.list.strip().lower():
                return name
    return cfg.rules.lists.default


def _parse_date(s: str | None) -> date | None:
    if not s:
        return None
    return date.fromisoformat(s.strip()[:10])


def _parse_hhmm(s: str | None) -> time | None:
    if not s:
        return None
    m = re.match(r"^\s*(\d{1,2}):(\d{2})", s)
    if not m:
        raise ValueError(f"bad time {s!r}")
    return time(int(m.group(1)), int(m.group(2)))


def _parse_local_dt(s: str, cfg: Config) -> tuple[datetime, bool]:
    """Returns (aware datetime, is_date_only)."""
    s = s.strip()
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", s):
        return datetime.combine(date.fromisoformat(s), time(0), cfg.tz), True
    dt = datetime.fromisoformat(s.replace("Z", "+00:00").replace(" ", "T"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=cfg.tz)
    return dt.astimezone(cfg.tz), False


def _soon(now: datetime) -> datetime:
    """~10 minutes from now, rounded up to 5 minutes."""
    t = now + timedelta(minutes=10)
    minute = int(math.ceil(t.minute / 5) * 5)
    return t.replace(second=0, microsecond=0, minute=0) + timedelta(minutes=minute)


def _notes(ev: Event, action: Action, tag: str) -> str:
    who = ev.sender_label or ev.sender_handle or "unknown"
    snippet = ev.text.strip().replace("\n", " ")
    if len(snippet) > 300:
        snippet = snippet[:297] + "…"
    origin = f"From {who}"
    if ev.source == "mail" and ev.subject:
        origin += f" (email “{ev.subject}”)"
    lines = [f'{origin}: "{snippet}"']
    if action.notes:
        lines.append(action.notes.strip())
    lines.append(tag)
    return "\n".join(lines)


def plan(cfg: Config, ev: Event, ex: Extraction, now: datetime, *, force: bool = False) -> Plan:
    """Build commands. `force=True` (human-edited extraction) skips the confidence check."""
    now = now.astimezone(cfg.tz)
    today = now.date()
    p = Plan()
    if not ex.actionable or not ex.actions:
        return p
    if not force and ex.confidence < cfg.rules.review_threshold:
        p.review_reasons.append(f"confidence {ex.confidence:.2f} < {cfg.rules.review_threshold}")
    if len(ex.actions) > 8:
        p.review_reasons.append(f"{len(ex.actions)} actions in one message")

    for seq, a in enumerate(ex.actions):
        tag = item_tag(ev.event_id, seq)
        title = (a.title or "").strip() or "(untitled)"
        if a.type == "create_reminder":
            try:
                due = _parse_date(a.due_date)
                due_time = _parse_hhmm(a.due_time)
            except ValueError as e:
                p.review_reasons.append(f"{title}: invalid date/time ({e})")
                due, due_time = None, None
            alert = None
            if due:
                if due < today:
                    p.review_reasons.append(f"{title}: due date {due} is in the past")
                at = due_time or _parse_hhmm(cfg.rules.default_alert_time)
                alert_dt = datetime.combine(due, at, cfg.tz)
                if alert_dt < now and due == today:
                    alert_dt = _soon(now)
                alert = alert_dt.isoformat()
            p.commands.append(PlannedCommand(op="create_reminder", payload={
                "title": title,
                "list": route_list(cfg, a),
                "create_list_if_missing": cfg.rules.create_missing_lists,
                "due": due.isoformat() if due else None,
                "due_time": due_time.strftime("%H:%M") if (due and due_time) else None,
                "alert": alert,
                "notes": _notes(ev, a, tag),
                "tag": tag,
            }))
        elif a.type == "create_event":
            if not a.start:
                p.review_reasons.append(f"{title}: event has no start")
                continue
            try:
                start, date_only = _parse_local_dt(a.start, cfg)
                end = _parse_local_dt(a.end, cfg)[0] if a.end else None
            except ValueError as e:
                p.review_reasons.append(f"{title}: invalid start/end ({e})")
                continue
            all_day = a.all_day or date_only
            if all_day:
                start = datetime.combine(start.date(), time(0), cfg.tz)
                end = datetime.combine((end or start).date(), time(0), cfg.tz)
                if end < start:
                    end = start
                if start.date() < today:
                    p.review_reasons.append(f"{title}: date {start.date()} is in the past")
            else:
                if end is None or end <= start:
                    end = start + timedelta(minutes=cfg.rules.calendars.default_duration_min)
                if start < now:
                    p.review_reasons.append(f"{title}: start {start:%Y-%m-%d %H:%M} is in the past")
            p.commands.append(PlannedCommand(op="create_event", payload={
                "title": title,
                "calendar": cfg.rules.calendars.default if not a.calendar else _calendar(cfg, a.calendar),
                "start": start.isoformat(),
                "end": end.isoformat(),
                "all_day": all_day,
                "location": a.location,
                "alert_minutes_before": None if all_day else cfg.rules.calendars.alert_minutes_before,
                "notes": _notes(ev, a, tag),
                "tag": tag,
            }))
    return p


def _calendar(cfg: Config, name: str) -> str:
    # Only the configured calendars are allowed; unknown names fall back to the default.
    known = [cfg.rules.calendars.default]
    for k in known:
        if k.lower() == name.strip().lower():
            return k
    return cfg.rules.calendars.default
