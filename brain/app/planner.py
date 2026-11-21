"""Extraction → mac-agent commands. Applies config rules/defaults and decides on review."""
from __future__ import annotations

import math
import re
from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta

from .config import Config
from .items import state_from_payload
from .schemas import CREATE_TYPES, ITEM_TYPES, Action, Event, Extraction, PlannedCommand


@dataclass
class Plan:
    commands: list[PlannedCommand] = field(default_factory=list)
    review_reasons: list[str] = field(default_factory=list)
    skipped: list[str] = field(default_factory=list)  # actions dropped on purpose (shown in the trace)

    @property
    def needs_review(self) -> bool:
        return bool(self.review_reasons)


def item_tag(event_id: str, seq: int) -> str:
    return f"[ha:{event_id}]" if seq == 0 else f"[ha:{event_id}#{seq}]"


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


def person_tag(name: str | None) -> str | None:
    """Reminders tags are single words: "Family group" → "FamilyGroup"."""
    if not name:
        return None
    words = re.findall(r"[^\W_]+", name, flags=re.UNICODE)
    tag = "".join(w[:1].upper() + w[1:] for w in words)[:40]
    return tag or None


def _organize(cfg: Config, payload: dict, person: str | None, *, section: bool) -> dict:
    """Section (column) + #tag for a person, with a plain-title fallback for when the Mac can't do it."""
    tag = person_tag(person) if cfg.rules.person_tags else None
    sec = person if (section and person) else None
    payload["section"] = sec
    payload["tags"] = [tag] if tag else []
    payload["title_fallback"] = (f"{person} · {payload['title']}" if (sec or tag) and person
                                 and not payload["title"].endswith(f"· {person}") else None)
    return payload


def _snippet(text: str, n: int = 240) -> str:
    t = " ".join(text.strip().split())
    return t if len(t) <= n else t[: n - 1] + "…"


def person_of(ev: Event) -> str:
    return ev.sender_label or ev.sender_handle or "someone"


def _notes(cfg: Config, ev: Event, action: Action, tag: str, person: str) -> str:
    """Reminders shows the first notes line under the title, so it leads with who it's from."""
    when = ev.received_at.astimezone(cfg.tz).strftime("%a %b %-d")
    via = " · email" if ev.source == "mail" else ""
    lines = [f"👤 {person} · {when}{via}"]
    if action.summary and action.summary.strip():
        lines.append(action.summary.strip())
    quote = _snippet(ev.text, 300)
    lines.append(f"{'You' if ev.is_from_me else person}: “{quote}”" if not ev.subject
                 else f"“{ev.subject}”: {quote}")
    if action.notes and action.notes.strip():
        lines.append(action.notes.strip())
    if action.url:
        lines.append(action.url.strip())
    lines.append(tag)
    return "\n".join(lines)


def _reminder_when(cfg: Config, due: date | None, due_time: time | None, now: datetime,
                   title: str, reasons: list[str]) -> str | None:
    """Alert time for a reminder (ISO) and past-date checks."""
    if not due:
        return None
    if due < now.date():
        reasons.append(f"{title}: due date {due} is in the past")
    at = due_time or _parse_hhmm(cfg.rules.default_alert_time)
    alert_dt = datetime.combine(due, at, cfg.tz)
    if alert_dt < now and due == now.date():
        alert_dt = _soon(now)
    return alert_dt.isoformat()


def _event_times(cfg: Config, a_start: str, a_end: str | None, all_day_flag: bool, now: datetime, title: str,
                 reasons: list[str], keep_duration: timedelta | None = None) -> tuple[datetime, datetime, bool]:
    start, date_only = _parse_local_dt(a_start, cfg)
    end = _parse_local_dt(a_end, cfg)[0] if a_end else None
    all_day = all_day_flag or date_only
    if all_day:
        start = datetime.combine(start.date(), time(0), cfg.tz)
        end = datetime.combine((end or start).date(), time(0), cfg.tz)
        if end < start:
            end = start
        if start.date() < now.date():
            reasons.append(f"{title}: date {start.date()} is in the past")
    else:
        if end is None or end <= start:
            end = start + (keep_duration or timedelta(minutes=cfg.rules.calendars.default_duration_min))
        if start < now:
            reasons.append(f"{title}: start {start:%Y-%m-%d %H:%M} is in the past")
    return start, end, all_day


def plan(cfg: Config, ev: Event, ex: Extraction, now: datetime, *, force: bool = False,
         open_items: list[dict] | None = None) -> Plan:
    """Build commands. `force=True` (human-edited extraction) skips the confidence check.

    `open_items` are the conversation's editable items in the order shown to the model (ref 1 = index 0).
    """
    now = now.astimezone(cfg.tz)
    refs = {i + 1: it for i, it in enumerate(open_items or [])}
    p = Plan()
    if not ex.actionable or not ex.actions:
        return p
    if not force and ex.confidence < cfg.rules.review_threshold:
        p.review_reasons.append(f"confidence {ex.confidence:.2f} < {cfg.rules.review_threshold}")
    if len(ex.actions) > 8:
        p.review_reasons.append(f"{len(ex.actions)} actions in one message")
    person = person_of(ev)

    for seq, a in enumerate(ex.actions):
        title = (a.title or "").strip() or "(untitled)"
        if ev.is_from_me and a.type in CREATE_TYPES and not cfg.watch.imessage.allow_self_notes:
            p.skipped.append(f"{title}: my own message can only change existing items")
            continue
        if ev.is_from_me and a.type in ITEM_TYPES and not cfg.rules.self_updates:
            p.skipped.append(f"{title}: updates from my replies are turned off")
            continue
        if a.type in ITEM_TYPES:
            _plan_item_change(cfg, ev, a, refs, now, p, person)
            continue

        tag = item_tag(ev.event_id, seq)
        if a.type == "create_reminder":
            try:
                due = _parse_date(a.due_date)
                due_time = _parse_hhmm(a.due_time)
            except ValueError as e:
                p.review_reasons.append(f"{title}: invalid date/time ({e})")
                due, due_time = None, None
            alert = _reminder_when(cfg, due, due_time, now, title, p.review_reasons)
            shown = f"{title} · {person}" if cfg.rules.person_in_title else title
            payload = _organize(cfg, {
                "title": shown, "list": cfg.rules.reminder_list,
                "create_list_if_missing": cfg.rules.create_missing_lists,
                "due": due.isoformat() if due else None,
                "due_time": due_time.strftime("%H:%M") if (due and due_time) else None,
                "alert": alert, "url": a.url, "notes": _notes(cfg, ev, a, tag, person), "tag": tag,
            }, person, section=False)
            p.commands.append(PlannedCommand(op="create_reminder", payload=payload, new_item={
                "seq": seq, "kind": "reminder", "collection": None, "person": person, "title": shown,
                "state": state_from_payload("create_reminder", payload), "tag": tag}))
        elif a.type == "save_to_collection":
            col = cfg.collection(a.collection)
            if not col:
                p.review_reasons.append(f"{title}: unknown or disabled collection {a.collection!r}")
                continue
            about = (a.person or "").strip() or person
            payload = _organize(cfg, {
                "title": title, "list": col.list.format(person=about), "create_list_if_missing": True,
                "due": None, "due_time": None, "alert": None, "url": a.url,
                "notes": _notes(cfg, ev, a, tag, person), "tag": tag,
            }, about, section=col.group_by_person)
            p.commands.append(PlannedCommand(op="create_reminder", payload=payload, meta={"collection": col.key},
                                             new_item={"seq": seq, "kind": "reminder", "collection": col.key,
                                                       "person": about, "title": title,
                                                       "state": state_from_payload("create_reminder", payload),
                                                       "tag": tag}))
        elif a.type == "create_event":
            if not a.start:
                p.review_reasons.append(f"{title}: event has no start")
                continue
            try:
                start, end, all_day = _event_times(cfg, a.start, a.end, a.all_day, now, title, p.review_reasons)
            except ValueError as e:
                p.review_reasons.append(f"{title}: invalid start/end ({e})")
                continue
            shown = f"{title} · {person}" if cfg.rules.person_in_title else title
            payload = {
                "title": shown,
                "calendar": cfg.rules.calendars.default if not a.calendar else _calendar(cfg, a.calendar),
                "start": start.isoformat(), "end": end.isoformat(), "all_day": all_day, "location": a.location,
                "alert_minutes_before": None if all_day else cfg.rules.calendars.alert_minutes_before,
                "url": a.url, "notes": _notes(cfg, ev, a, tag, person), "tag": tag,
            }
            p.commands.append(PlannedCommand(op="create_event", payload=payload, new_item={
                "seq": seq, "kind": "event", "collection": None, "person": person, "title": shown,
                "state": state_from_payload("create_event", payload), "tag": tag}))
    return p


def _plan_item_change(cfg: Config, ev: Event, a: Action, refs: dict[int, dict], now: datetime, p: Plan,
                      person: str) -> None:
    item = refs.get(a.ref) if a.ref is not None else None
    label = (a.title or "").strip() or f"item #{a.ref}"
    if not item:
        p.review_reasons.append(f"{label}: refers to an item I can't find (#{a.ref})")
        return
    title = item["title"]
    who = "You" if ev.is_from_me else person
    stamp = ev.received_at.astimezone(cfg.tz).strftime("%a %b %-d %-I:%M %p")
    quote = f"{who}: “{_snippet(ev.text, 160)}”"
    base = {"apple_item_id": item.get("apple_item_id"), "tag": item["tag"], "kind": item["kind"]}

    if a.type == "cancel_item":
        p.commands.append(PlannedCommand(op="delete_item", payload=base, purpose="cancel", item_id=item["item_id"],
                                         meta={"why": quote, "title": title}))
        return
    if a.type == "complete_item":
        if item["kind"] != "reminder":
            p.skipped.append(f"{title}: calendar events can't be marked done")
            return
        p.commands.append(PlannedCommand(
            op="update_item", purpose="complete", item_id=item["item_id"],
            payload={**base, "changes": {"completed": True}, "notes_append": f"✅ Done · {stamp} — {quote}"},
            meta={"previous": {"completed": False}, "why": quote, "title": title}))
        return

    # update_item
    st = item["state"]
    changes: dict = {}
    reasons: list[str] = []
    new_title = (a.title or "").strip()
    if new_title and new_title.lower() != title.lower() and new_title.lower() not in title.lower():
        changes["title"] = new_title
    if item["kind"] == "reminder":
        if a.due_date or a.due_time:
            try:
                due = _parse_date(a.due_date) or _parse_date(st.get("due")) or now.date()
                due_time = _parse_hhmm(a.due_time) if a.due_time else (
                    _parse_hhmm(st.get("due_time")) if not a.due_date or st.get("due_time") else None)
            except ValueError as e:
                p.review_reasons.append(f"{title}: invalid date/time ({e})")
                return
            new = {"due": due.isoformat(), "due_time": due_time.strftime("%H:%M") if due_time else None,
                   "alert": _reminder_when(cfg, due, due_time, now, title, reasons)}
            changes.update({k: v for k, v in new.items() if v != st.get(k)})
    else:
        if a.start:
            try:
                old_dur = None
                if st.get("start") and st.get("end"):
                    old_dur = datetime.fromisoformat(st["end"]) - datetime.fromisoformat(st["start"])
                start, end, all_day = _event_times(cfg, a.start, a.end, a.all_day, now, title, reasons, old_dur)
            except ValueError as e:
                p.review_reasons.append(f"{title}: invalid start/end ({e})")
                return
            new = {"start": start.isoformat(), "end": end.isoformat(), "all_day": all_day}
            changes.update({k: v for k, v in new.items() if v != st.get(k)})
        if a.location and a.location != st.get("location"):
            changes["location"] = a.location
    if a.url and a.url != st.get("url"):
        changes["url"] = a.url
    if not changes:
        p.skipped.append(f"{title}: nothing to change")
        return
    p.review_reasons.extend(reasons)
    previous = {k: (title if k == "title" else st.get(k)) for k in changes}
    summary = ", ".join(_describe(cfg, k, v) for k, v in changes.items() if k not in ("alert", "due_time"))
    p.commands.append(PlannedCommand(
        op="update_item", purpose="update", item_id=item["item_id"],
        payload={**base, "changes": changes, "notes_append": f"✏️ Updated · {stamp} — {quote}"},
        meta={"previous": previous, "why": quote, "title": title, "summary": summary}))


def _describe(cfg: Config, key: str, value) -> str:
    if key == "due" and value:
        return "due " + date.fromisoformat(value).strftime("%a %b %-d")
    if key == "start" and value:
        return "starts " + datetime.fromisoformat(value).astimezone(cfg.tz).strftime("%a %b %-d %-I:%M %p")
    return f"{key.replace('_', ' ')} → {value}"


def _calendar(cfg: Config, name: str) -> str:
    # Only the configured calendars are allowed; unknown names fall back to the default.
    known = [cfg.rules.calendars.default]
    for k in known:
        if k.lower() == name.strip().lower():
            return k
    return cfg.rules.calendars.default
